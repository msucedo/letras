import AppKit

struct Cancion: Equatable, Hashable {
    var titulo: String
    var artista: String
    var album: String
    /// En segundos; 0 si el reproductor no la sabe (por ejemplo, una estación de radio).
    var duracion: Double
}

enum EstadoReproduccion: Equatable {
    case reproduciendo
    case enPausa
    case detenido
}

/// Lo que dice un reproductor en un momento dado.
struct Lectura: Equatable {
    var estado: EstadoReproduccion
    var cancion: Cancion?
    /// Segundo de la canción en el que va.
    var posicion: Double
}

enum ErrorDeReproductor: Error, Equatable {
    /// El usuario no le dio permiso a Letras de controlar la app (Ajustes > Privacidad > Automatización).
    case sinPermiso
    /// macOS todavía no le ha preguntado al usuario; hay que pedirlo con `consultarPermiso`.
    case faltaPermiso
    case noAbierto
    case otro(String)
}

// Spotify y Música se leen igual: por AppleScript, que da la canción y la posición exacta, y
// con la notificación que cada uno manda a todo el sistema al cambiar de canción, pausar o
// reanudar. La notificación avisa cuándo leer; AppleScript da los datos.
@MainActor
final class Reproductor {
    let nombre: String
    let bundleID: String
    let notificacion: Notification.Name
    private let fuente: String
    private var script: NSAppleScript?
    private let fuenteRapida: String
    private var scriptRapido: NSAppleScript?

    enum Permiso { case desconocido, preguntando, concedido }
    /// Mientras no esté concedido, `leer` pregunta a macOS antes de mandar el AppleScript.
    var permiso = Permiso.desconocido

    private init(nombre: String, bundleID: String, notificacion: String, script: String) {
        self.nombre = nombre
        self.bundleID = bundleID
        self.notificacion = Notification.Name(notificacion)
        self.fuente = script
        self.fuenteRapida = Self.guionRapido(app: bundleID)
    }

    // Las dos apps entienden casi el mismo AppleScript; la diferencia está en la duración, que
    // Spotify da en milisegundos (aunque su diccionario dice segundos) y Música en segundos.
    // El timeout evita que la app de letras se congele si el reproductor no responde.
    // Se pide `name of current track` y no `set t to current track`: con sandbox, Música solo deja
    // pedir propiedades (grupo com.apple.Music.playback); la referencia al track da -10004.
    static let spotify = Reproductor(
        nombre: "Spotify", bundleID: "com.spotify.client",
        notificacion: "com.spotify.client.PlaybackStateChanged",
        script: guion(app: "com.spotify.client", duracion: "(duration of current track) / 1000"))

    static let musica = Reproductor(
        nombre: "Música", bundleID: "com.apple.Music",
        notificacion: "com.apple.Music.playerInfo",
        script: guion(app: "com.apple.Music", duracion: "duration of current track"))

    static let todos = [spotify, musica]

    /// El nombre en el idioma de la interfaz ("Música" → "Music"). `nombre` no se traduce porque
    /// también sirve para identificar al reproductor, como en `Monitor.sinPermiso`.
    static func nombreVisible(_ nombre: String) -> String {
        Bundle.main.localizedString(forKey: nombre, value: nil, table: nil)
    }

    private static func guion(app: String, duracion: String) -> String {
        """
        with timeout of 2 seconds
            tell application id "\(app)"
                set estado to player state
                if estado is stopped then return {"detenido"}
                set d to 0
                try
                    set d to \(duracion)
                end try
                if estado is playing then
                    set e to "reproduciendo"
                else
                    set e to "pausa"
                end if
                return {e, name of current track, artist of current track, album of current track, d, player position}
            end tell
        end timeout
        """
    }

    /// Solo estado, título y posición: 3 preguntas al reproductor en lugar de 7. Es lo que se lee
    /// cada segundo; el resto de la canción solo cambia con un aviso del reproductor.
    private static func guionRapido(app: String) -> String {
        """
        with timeout of 2 seconds
            tell application id "\(app)"
                set estado to player state
                if estado is stopped then return {"detenido"}
                if estado is playing then
                    set e to "reproduciendo"
                else
                    set e to "pausa"
                end if
                return {e, name of current track, player position}
            end tell
        end timeout
        """
    }

    var estaAbierto: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Pregunta al reproductor qué suena. Hay que llamarlo en el hilo principal (NSAppleScript no
    /// es seguro en otros hilos), y solo si está abierto: si no, AppleScript lo abriría.
    /// Con `cancion` (la que ya se sabe que suena) hace la lectura rápida y, si sigue siendo la
    /// misma, solo actualiza estado y posición; si cambió o se detuvo, hace la completa.
    func leer(sabiendo cancion: Cancion? = nil) -> Result<Lectura, ErrorDeReproductor> {
        guard estaAbierto else { return .failure(.noAbierto) }
        switch permiso {
        case .concedido: break
        case .preguntando: return .failure(.faltaPermiso)
        case .desconocido:
            switch Self.consultarPermiso(bundleID: bundleID, preguntar: false) {
            case noErr: permiso = .concedido
            case OSStatus(errAEEventWouldRequireUserConsent): return .failure(.faltaPermiso)
            case OSStatus(procNotFound): return .failure(.noAbierto)
            default: return .failure(.sinPermiso)
            }
        }
        let resultado = leerConScript(sabiendo: cancion)
        // Si lo quitó en Ajustes del Sistema, la próxima vez se vuelve a consultar.
        if resultado == .failure(.sinPermiso) { permiso = .desconocido }
        return resultado
    }

    /// Pregunta a macOS si Letras puede mandarle a la app los eventos de los guiones (`get`).
    /// Con `preguntar`, macOS muestra el aviso y esto espera, sin límite, a que el usuario
    /// conteste: por eso hay que llamarlo fuera del hilo principal. El aviso no puede salir de
    /// un AppleScript: con su timeout de 2 segundos, macOS lo cerraba antes de que contestaran.
    nonisolated static func consultarPermiso(bundleID: String, preguntar: Bool) -> OSStatus {
        let destino = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = destino.aeDesc else { return OSStatus(procNotFound) }
        return AEDeterminePermissionToAutomateTarget(desc, AEEventClass(kAECoreSuite), AEEventID(kAEGetData), preguntar)
    }

    private func leerConScript(sabiendo cancion: Cancion?) -> Result<Lectura, ErrorDeReproductor> {
        if let cancion {
            if scriptRapido == nil { scriptRapido = NSAppleScript(source: fuenteRapida) }
            switch Self.ejecutar(scriptRapido) {
            case .success(let lista):
                if lista.numberOfItems >= 3, lista.atIndex(2)?.stringValue == cancion.titulo {
                    return .success(Lectura(estado: lista.atIndex(1)?.stringValue == "reproduciendo" ? .reproduciendo : .enPausa,
                                            cancion: cancion, posicion: lista.atIndex(3)?.doubleValue ?? 0))
                }
            case .failure(let error):
                return .failure(error)
            }
        }
        if script == nil { script = NSAppleScript(source: fuente) }
        return Self.ejecutar(script).map(Self.interpretar)
    }

    /// Recibe el script ya compilado y no la propiedad: mientras corre, AppleScript atiende otros
    /// eventos y puede llegar un aviso que vuelva a leer; con la propiedad como inout eso era un
    /// acceso simultáneo y la app se cerraba.
    private static func ejecutar(_ script: NSAppleScript?) -> Result<NSAppleEventDescriptor, ErrorDeReproductor> {
        var error: NSDictionary?
        guard let resultado = script?.executeAndReturnError(&error) else {
            let numero = error?[NSAppleScript.errorNumber] as? Int
            switch numero {
            // -1743: macOS no dio permiso. -600: la app se cerró mientras le preguntábamos.
            case -1743: return .failure(.sinPermiso)
            case -600: return .failure(.noAbierto)
            default: return .failure(.otro(error?[NSAppleScript.errorMessage] as? String ?? "Error \(numero ?? 0)"))
            }
        }
        return .success(resultado)
    }

    private static func interpretar(_ lista: NSAppleEventDescriptor) -> Lectura {
        // Las listas de AppleScript empiezan en 1.
        func texto(_ i: Int) -> String { lista.atIndex(i)?.stringValue ?? "" }
        func numero(_ i: Int) -> Double { lista.atIndex(i)?.doubleValue ?? 0 }

        guard lista.numberOfItems >= 6 else {
            return Lectura(estado: .detenido, cancion: nil, posicion: 0)
        }
        let cancion = Cancion(titulo: texto(2), artista: texto(3), album: texto(4), duracion: numero(5))
        return Lectura(estado: texto(1) == "reproduciendo" ? .reproduciendo : .enPausa,
                       cancion: cancion.titulo.isEmpty ? nil : cancion,
                       posicion: numero(6))
    }
}
