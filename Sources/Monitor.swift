import AppKit
import Combine

enum EstadoLetra: Equatable {
    case nadaSonando
    case buscando
    case sinLetra
    /// No se pudo preguntar a LRCLIB; se reintenta sola cada cierto tiempo.
    case sinConexion
    case lista(Letra)
}

// Sabe qué suena, en qué segundo va y qué línea de la letra toca. Todo pasa en el hilo principal.
//
// Al reproductor solo se le pregunta cuando avisa de un cambio (canción, pausa, reanudar) y,
// mientras suena, una vez por segundo para corregir la posición. Entre una lectura y otra la
// posición se calcula con el reloj, 10 veces por segundo, para que las líneas cambien a tiempo.
@MainActor
final class Monitor: ObservableObject {
    @Published private(set) var cancion: Cancion?
    @Published private(set) var estado: EstadoReproduccion = .detenido
    @Published private(set) var nombreReproductor: String?
    @Published private(set) var letra: EstadoLetra = .nadaSonando
    /// La línea que se está cantando; nil antes de la primera o si la letra no es sincronizada.
    @Published private(set) var indice: Int?
    /// Los reproductores a los que macOS no deja preguntarles, por falta de permiso.
    @Published private(set) var sinPermiso: [String] = []

    /// Segundos que se adelanta la letra; viene de los ajustes.
    var ajuste = 0.0 {
        didSet { actualizarIndice() }
    }

    static let cadaLectura: TimeInterval = 1
    static let cadaTic: TimeInterval = 0.1
    static let reintentoSinConexion: TimeInterval = 30

    private let lrclib: LRCLIB
    private var activo: Reproductor?
    private var posicionBase = 0.0
    private var instanteBase = ProcessInfo.processInfo.systemUptime
    private var timerLectura: Timer?
    private var timerTic: Timer?
    private var busqueda: Task<Void, Never>?
    private var ultimaBusqueda = Date.distantPast
    private var observaciones: [NSObjectProtocol] = []

    init(lrclib: LRCLIB = LRCLIB()) {
        self.lrclib = lrclib
        for reproductor in Reproductor.todos {
            observaciones.append(DistributedNotificationCenter.default().addObserver(
                forName: reproductor.notificacion, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.revisar(reproductor) }
            })
        }
        // Si el reproductor que suena se cierra, a lo mejor el otro tiene algo.
        observaciones.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] aviso in
            let app = aviso.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let self, app?.bundleIdentifier == self.activo?.bundleID {
                    self.activo = nil
                    self.buscarReproductor()
                }
            }
        })
        buscarReproductor()
    }

    /// La posición en la canción, con la parte que pasó desde la última lectura.
    var posicion: Double {
        guard estado == .reproduciendo else { return posicionBase }
        return posicionBase + ProcessInfo.processInfo.systemUptime - instanteBase
    }

    var lineaActual: String? {
        guard case .lista(.sincronizada(let lineas)) = letra, let indice else { return nil }
        let texto = lineas[indice].texto
        return texto.isEmpty ? nil : texto
    }

    /// Vuelve a preguntar a los reproductores; sirve después de dar permiso en Ajustes del Sistema.
    func reintentar() {
        sinPermiso = []
        buscarReproductor()
    }

    // MARK: - Preguntar a los reproductores

    /// Pregunta a los reproductores abiertos y se queda con el que está sonando o, si ninguno,
    /// con el que tenga una canción en pausa.
    private func buscarReproductor() {
        var enPausa: (Reproductor, Lectura)?
        for reproductor in Reproductor.todos {
            guard let lectura = leer(reproductor), lectura.cancion != nil else { continue }
            if lectura.estado == .reproduciendo {
                aplicar(lectura, de: reproductor)
                return
            }
            if enPausa == nil { enPausa = (reproductor, lectura) }
        }
        if let (reproductor, lectura) = enPausa {
            aplicar(lectura, de: reproductor)
        } else {
            detener()
        }
    }

    /// Un reproductor avisó que algo cambió, o toca corregir la posición del que suena (`rapido`:
    /// solo estado y posición, si sigue la misma canción).
    private func revisar(_ reproductor: Reproductor, rapido: Bool = false) {
        guard let lectura = leer(reproductor, sabiendo: rapido ? cancion : nil) else {
            if reproductor === activo { buscarReproductor() }
            return
        }
        if reproductor === activo {
            // Si se detuvo, el otro reproductor puede tener algo.
            lectura.cancion == nil ? buscarReproductor() : aplicar(lectura, de: reproductor)
        } else if lectura.estado == .reproduciendo || activo == nil || estado != .reproduciendo {
            // El que empieza a sonar gana; uno en pausa no le quita el lugar al que suena.
            if lectura.cancion != nil { aplicar(lectura, de: reproductor) }
        }
    }

    private func leer(_ reproductor: Reproductor, sabiendo cancion: Cancion? = nil) -> Lectura? {
        switch reproductor.leer(sabiendo: cancion) {
        case .success(let lectura):
            sinPermiso.removeAll { $0 == reproductor.nombre }
            return lectura
        case .failure(.sinPermiso):
            if !sinPermiso.contains(reproductor.nombre) { sinPermiso.append(reproductor.nombre) }
            return nil
        case .failure:
            return nil
        }
    }

    private func aplicar(_ lectura: Lectura, de reproductor: Reproductor) {
        activo = reproductor
        nombreReproductor = reproductor.nombre
        estado = lectura.estado
        posicionBase = lectura.posicion
        instanteBase = ProcessInfo.processInfo.systemUptime
        if lectura.cancion != cancion {
            cancion = lectura.cancion
            buscarLetra()
        } else if letra == .sinConexion, Date().timeIntervalSince(ultimaBusqueda) > Self.reintentoSinConexion {
            buscarLetra()
        }
        programarTimers()
        actualizarIndice()
    }

    private func detener() {
        activo = nil
        nombreReproductor = nil
        cancion = nil
        estado = .detenido
        busqueda?.cancel()
        letra = .nadaSonando
        programarTimers()
        actualizarIndice()
    }

    // MARK: - Letra

    private func buscarLetra() {
        busqueda?.cancel()
        guard let cancion else {
            letra = .nadaSonando
            return
        }
        letra = .buscando
        ultimaBusqueda = Date()
        let lrclib = self.lrclib
        busqueda = Task { [weak self] in
            let resultado: EstadoLetra
            do {
                resultado = try await lrclib.letra(de: cancion).map(EstadoLetra.lista) ?? .sinLetra
            } catch {
                resultado = .sinConexion
            }
            // Si mientras tanto cambió la canción, esta letra ya no sirve.
            guard let self, !Task.isCancelled, self.cancion == cancion else { return }
            self.letra = resultado
            self.actualizarIndice()
        }
    }

    // MARK: - Reloj

    private func programarTimers() {
        let sonando = estado == .reproduciendo
        if sonando, timerLectura == nil {
            // Los timers corren en el run loop principal, así que ya están en el MainActor.
            timerLectura = Timer.scheduledTimer(withTimeInterval: Self.cadaLectura, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let activo = self.activo else { return }
                    self.revisar(activo, rapido: true)
                }
            }
            timerTic = Timer.scheduledTimer(withTimeInterval: Self.cadaTic, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.actualizarIndice() }
            }
            // Con tolerancia macOS agrupa los timers y gasta menos batería; 20 ms no se notan.
            timerTic?.tolerance = 0.02
            timerLectura?.tolerance = 0.2
        } else if !sonando {
            timerLectura?.invalidate()
            timerTic?.invalidate()
            timerLectura = nil
            timerTic = nil
        }
    }

    private func actualizarIndice() {
        var nuevo: Int?
        if case .lista(.sincronizada(let lineas)) = letra {
            nuevo = LRC.indice(en: posicion + ajuste, de: lineas)
        }
        // Publicar solo si cambia: cada cambio redibuja el panel y la barra de menú.
        if nuevo != indice { indice = nuevo }
    }
}
