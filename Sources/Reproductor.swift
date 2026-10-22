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

    private init(nombre: String, bundleID: String, notificacion: String, script: String) {
        self.nombre = nombre
        self.bundleID = bundleID
        self.notificacion = Notification.Name(notificacion)
        self.fuente = script
    }

    // Las dos apps entienden casi el mismo AppleScript; la diferencia está en la duración, que
    // Spotify da en milisegundos (aunque su diccionario dice segundos) y Música en segundos.
    // El timeout evita que la app de letras se congele si el reproductor no responde.
    static let spotify = Reproductor(
        nombre: "Spotify", bundleID: "com.spotify.client",
        notificacion: "com.spotify.client.PlaybackStateChanged",
        script: guion(app: "com.spotify.client", duracion: "(duration of t) / 1000"))

    static let musica = Reproductor(
        nombre: "Música", bundleID: "com.apple.Music",
        notificacion: "com.apple.Music.playerInfo",
        script: guion(app: "com.apple.Music", duracion: "duration of t"))

    static let todos = [spotify, musica]

    private static func guion(app: String, duracion: String) -> String {
        """
        with timeout of 2 seconds
            tell application id "\(app)"
                set estado to player state
                if estado is stopped then return {"detenido"}
                set t to current track
                set d to 0
                try
                    set d to \(duracion)
                end try
                if estado is playing then
                    set e to "reproduciendo"
                else
                    set e to "pausa"
                end if
                return {e, name of t, artist of t, album of t, d, player position}
            end tell
        end timeout
        """
    }

    var estaAbierto: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Pregunta al reproductor qué suena. Hay que llamarlo en el hilo principal (NSAppleScript no
    /// es seguro en otros hilos), y solo si está abierto: si no, AppleScript lo abriría.
    func leer() -> Result<Lectura, ErrorDeReproductor> {
        guard estaAbierto else { return .failure(.noAbierto) }
        if script == nil {
            script = NSAppleScript(source: fuente)
        }
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
        return .success(Self.interpretar(resultado))
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
