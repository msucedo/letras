import AppKit
import Combine

// La etiqueta de la barra de menú: el icono y el texto (título y artista al empezar, luego la línea
// que se canta), dibujados en una sola imagen.
//
// Es una imagen y no un Text porque la etiqueta de un MenuBarExtra ignora .frame y el recorte, y una
// línea larga empujaría a los demás iconos. Si el texto no cabe en el ancho máximo, la imagen se
// queda de ese ancho y el texto se desliza adentro, como marquesina: espera un momento, avanza
// hasta el final y termina un poco antes de que toque el siguiente. El título del principio, en
// cambio, va y viene mientras se muestra, para que dé tiempo de leerlo.
//
// Al cambiar de texto se anima como se haya elegido en los ajustes (AnimacionBarra): deslizar,
// rodillo, revelado, fundido o ninguna. También al aparecer el texto donde solo estaba el icono, y
// al quitarse. En todas menos la última, el ancho de la imagen pasa poco a poco de uno al otro para
// que los demás iconos se deslicen en lugar de brincar.
//
// Si la app de enfrente tiene muchos menús, macOS esconde los iconos de la barra que no caben. Al
// notarlo, la marquesina se encoge: primero a un texto más corto y luego solo al icono. Vuelve a
// intentar el ancho completo cada vez que cambia la app de enfrente.
@MainActor
final class Marquesina: ObservableObject {
    @Published private(set) var imagen: NSImage

    /// Cuánto texto cabe en la barra. Baja de nivel cuando macOS esconde el icono por falta de espacio.
    enum Nivel: CaseIterable {
        case completo, corto, icono

        /// Lo más que ocupa el texto, en puntos.
        var anchoMaximo: CGFloat {
            switch self {
            case .completo: return 260
            case .corto: return 140
            case .icono: return 0
            }
        }

        var siguiente: Nivel? {
            switch self {
            case .completo: return .corto
            case .corto: return .icono
            case .icono: return nil
            }
        }
    }

    /// Segundos quieto al empezar un texto, para leer el principio.
    static let espera = 1.0
    /// Segundos antes de que acabe su turno en que ya debe verse el final.
    static let margenFinal = 1.0
    /// Puntos por segundo, como mínimo, aunque el texto dure mucho.
    static let velocidadMinima = 30.0
    /// Puntos por segundo del título cuando va y viene: despacio, para leerlo.
    static let velocidadTitulo = 40.0
    /// Deslizar: el hueco entre el texto que sale y el que entra, para que nunca se encimen.
    static let hueco: CGFloat = 16
    /// Revelado: parte de la transición en que el texto anterior termina de desvanecerse.
    static let finSalida = 0.4
    /// Revelado: parte de la transición en que el texto nuevo empieza a descubrirse.
    static let inicioRevelado = 0.25
    /// Revelado: lo ancho de la orilla difuminada, en puntos.
    static let orilla: CGFloat = 24
    static let cuadrosPorSegundo = 30.0
    static let separacion: CGFloat = 5

    private let monitor: Monitor
    private let store: AjustesStore
    private let tienda: Tienda
    private var segmento: Segmento?
    private var texto: NSAttributedString?
    private var desplazamiento: CGFloat = 0
    /// El texto que va de salida mientras dura la transición, con el desplazamiento que tenía.
    private var saliente: (texto: NSAttributedString, desplazamiento: CGFloat)?
    /// La transición en curso: cuándo empezó, con qué animación (si se cambia en los ajustes a la
    /// mitad, esta termina como empezó) y el ancho que se veía en ese momento.
    private var transicion: (inicio: TimeInterval, animacion: AnimacionBarra, anchoDesde: CGFloat)?
    /// El ancho después del icono en el último cuadro dibujado.
    private var anchoMostrado: CGFloat = 0
    /// El último cuadro que se dibujó (texto, desplazamiento y ancho), para no volver a generar la
    /// misma imagen 30 veces por segundo mientras el texto espera quieto.
    private var ultimoCuadro: (texto: NSAttributedString?, desplazamiento: CGFloat, ancho: CGFloat)?
    private var nivel = Nivel.completo
    private var anchoMaximo: CGFloat { nivel.anchoMaximo }
    private var timer: Timer?
    private var observaciones: [AnyCancellable] = []

    /// El símbolo ya pasado a mapa de bits (a 2x), una sola vez: dibujar el símbolo desde cero en
    /// cada cuadro de la marquesina costaba más que el texto.
    private static let icono: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let simbolo = NSImage(systemSymbolName: "music.quarternote.3", accessibilityDescription: "Letras")!
            .withSymbolConfiguration(config)!
        let escala: CGFloat = 2
        let mapa = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(simbolo.size.width * escala)),
                                    pixelsHigh: Int(ceil(simbolo.size.height * escala)), bitsPerSample: 8,
                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        mapa.size = simbolo.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: mapa)
        simbolo.draw(in: NSRect(origin: .zero, size: simbolo.size))
        NSGraphicsContext.restoreGraphicsState()
        let imagen = NSImage(size: simbolo.size)
        imagen.addRepresentation(mapa)
        return imagen
    }()

    init(monitor: Monitor, store: AjustesStore, tienda: Tienda) {
        self.monitor = monitor
        self.store = store
        self.tienda = tienda
        imagen = Self.dibujar(entrante: nil, desplazamientoEntrante: 0, saliente: nil, progreso: 1, extra: 0,
                              animacion: nil, anchoMaximo: Nivel.completo.anchoMaximo)
        // Cambia la canción, la línea, la letra, se pausa o se reanuda, o se apaga el texto en la barra.
        // receive(on:) lo deja para la siguiente vuelta del run loop: @Published avisa antes de
        // guardar el valor nuevo, y aquí se lee del monitor.
        Publishers.CombineLatest4(monitor.$indice, monitor.$letra, monitor.$estado,
                                  store.$ajustes.map(\.lineaEnLaBarra))
            .combineLatest(monitor.$cancion)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.actualizar() }
            .store(in: &observaciones)
        vigilarEspacio()
    }

    private var ahora: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var posicion: Double { monitor.posicion + monitor.ajuste }

    /// Decide qué texto toca, empieza la transición si cambió y dibuja el cuadro. Lo llaman los
    /// cambios del monitor y, mientras algo se mueve, el reloj.
    private func actualizar() {
        let nuevo = store.ajustes.lineaEnLaBarra && nivel != .icono
            ? Segmento.actual(cancion: monitor.cancion, letra: monitor.letra, indice: monitor.indice, posicion: posicion)
            : nil
        if nuevo?.texto != segmento?.texto {
            // Si ya iba una transición, la que estaba saliendo desaparece y sale la que entraba.
            // Elegir la animación es lo que desbloquea el café; sin él, siempre fundido.
            let animacion = tienda.desbloqueado ? store.ajustes.animacionBarra : .fundido
            if animacion == .ninguna {
                transicion = nil
                saliente = nil
            } else {
                transicion = (ahora, animacion, anchoMostrado)
                saliente = texto.map { ($0, desplazamiento) }
            }
            texto = nuevo.map { NSAttributedString(string: $0.texto, attributes: [.font: NSFont.menuBarFont(ofSize: 0)]) }
            desplazamiento = 0
        }
        segmento = nuevo
        dibujarCuadro()
    }

    private func dibujarCuadro() {
        var progreso = 1.0
        if let transicion {
            progreso = min(1, (ahora - transicion.inicio) / transicion.animacion.duracion)
            if progreso >= 1 {
                self.transicion = nil
                saliente = nil
            }
        }

        let recorrido = max(0, (texto?.size().width ?? 0) - anchoMaximo)
        var tituloMoviendose = false
        if let segmento, segmento.esTitulo, recorrido > 0 {
            let vaiven = Segmento.vaivenTitulo(transcurrido: posicion - segmento.inicio, recorrido: Double(recorrido),
                                               ventana: segmento.fin - segmento.inicio,
                                               espera: Self.espera, velocidad: Self.velocidadTitulo)
            desplazamiento = CGFloat(vaiven.desplazamiento)
            tituloMoviendose = vaiven.moviendo
        } else {
            desplazamiento = recorrido > 0 ? desplazamientoActual(recorrido: recorrido) : 0
        }

        // El ancho después del icono: la separación más el texto, recortado al máximo. Durante la
        // transición va del que se veía al empezar al del texto nuevo.
        let anchoFinal = texto.map { Self.separacion + min($0.size().width, anchoMaximo) } ?? 0
        if let transicion {
            anchoMostrado = transicion.anchoDesde + (anchoFinal - transicion.anchoDesde) * CGFloat(Self.suavizar(progreso))
        } else {
            anchoMostrado = anchoFinal
        }
        // Si el cuadro sale igual al anterior (el texto espera al principio o ya llegó al final), no
        // se vuelve a dibujar.
        let repetido = transicion == nil && ultimoCuadro.map {
            $0.texto === texto && $0.desplazamiento == desplazamiento && $0.ancho == anchoMostrado
        } == true
        if !repetido {
            imagen = Self.dibujar(entrante: texto, desplazamientoEntrante: desplazamiento,
                                  saliente: saliente, progreso: progreso, extra: anchoMostrado,
                                  animacion: transicion?.animacion, anchoMaximo: anchoMaximo)
        }
        ultimoCuadro = transicion == nil ? (texto, desplazamiento, anchoMostrado) : nil

        let sonando = monitor.estado == .reproduciendo
        let enMovimiento = transicion != nil
            || (sonando && segmento?.esTitulo != true && recorrido > 0 && desplazamiento < recorrido)
            || (sonando && tituloMoviendose)
            // Mientras va el título de los primeros segundos, para notar cuándo le toca a la letra.
            || (sonando && monitor.cancion != nil && posicion < Segmento.presentacion)
        if enMovimiento, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1 / Self.cuadrosPorSegundo, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.actualizar() }
            }
            timer?.tolerance = 0.01
        } else if !enMovimiento {
            timer?.invalidate()
            timer = nil
        }
    }

    // MARK: - Espacio en la barra

    /// Cuánto esperar antes de confirmar que macOS escondió el icono, y entre un nivel y el siguiente.
    static let esperaEspacio = 0.35
    private var revisionPendiente = false

    /// Escucha cuándo macOS esconde o vuelve a mostrar la ventana del icono, y cuándo cambia la app
    /// de enfrente (que es cuando cambian los menús que ocupan la barra).
    private func vigilarEspacio() {
        NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)
            .filter { [weak self] aviso in (aviso.object as? NSWindow) === self?.ventanaDelIcono }
            .sink { [weak self] _ in self?.revisarEspacio() }
            .store(in: &observaciones)
        // Con otra app de enfrente u otra pantalla, a lo mejor ya cabe completo: se intenta de nuevo.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reintentarCompleto() }
            .store(in: &observaciones)
    }

    /// La ventana en la que macOS pone el icono de la barra. SwiftUI no la da: es la única de la app
    /// de la clase NSStatusBarWindow.
    private var ventanaDelIcono: NSWindow? {
        NSApp.windows.first { $0.className.contains("NSStatusBarWindow") }
    }

    private func reintentarCompleto() {
        guard nivel != .completo else { return }
        nivel = .completo
        actualizar()
        revisarEspacio()
    }

    /// Si el icono está escondido por falta de espacio, baja un nivel. Espera un momento antes de
    /// decidir, para no confundirse con un cambio pasajero, y vuelve a revisar después de encogerse.
    /// Con la barra de menú oculta (apps en pantalla completa) no hace nada: ahí nada se ve.
    private func revisarEspacio() {
        guard !revisionPendiente else { return }
        revisionPendiente = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.esperaEspacio) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.revisionPendiente = false
                guard let ventana = self.ventanaDelIcono, !ventana.occlusionState.contains(.visible),
                      NSMenu.menuBarVisible(), self.texto != nil, let siguiente = self.nivel.siguiente else { return }
                self.nivel = siguiente
                self.actualizar()
                self.revisarEspacio()
            }
        }
    }

    /// Cuántos puntos se ha recorrido el texto, según el segundo de la canción: así sigue el ritmo
    /// aunque se adelante, se regrese o se pause.
    private func desplazamientoActual(recorrido: CGFloat) -> CGFloat {
        guard let segmento else { return 0 }
        let transcurrido = posicion - segmento.inicio - Self.espera
        let disponible = segmento.fin - segmento.inicio - Self.espera - Self.margenFinal
        let velocidad = disponible > 0 ? max(Double(recorrido) / disponible, Self.velocidadMinima) : Self.velocidadMinima
        return min(recorrido, max(0, CGFloat(transcurrido * velocidad)))
    }

    /// Empieza y termina despacio, como el easeInOut de SwiftUI.
    private static func suavizar(_ t: Double) -> Double {
        t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }

    /// El icono y, a su derecha, el texto recortado y corrido a la izquierda lo que se haya
    /// desplazado; durante la transición, el saliente y el entrante según la animación. Es una
    /// imagen plantilla (isTemplate): macOS la pinta del color de la barra, clara u oscura, y
    /// respeta la transparencia.
    private static func dibujar(entrante: NSAttributedString?, desplazamientoEntrante: CGFloat,
                                saliente: (texto: NSAttributedString, desplazamiento: CGFloat)?,
                                progreso: Double, extra: CGFloat, animacion: AnimacionBarra?,
                                anchoMaximo: CGFloat) -> NSImage {
        let alto = NSStatusBar.system.thickness
        let ancho = icono.size.width + max(0, extra)

        let imagen = NSImage(size: NSSize(width: ceil(ancho), height: alto), flipped: false) { _ in
            icono.draw(at: NSPoint(x: 0, y: (alto - icono.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
            let zona = NSRect(x: icono.size.width + separacion, y: 0, width: max(0, extra - separacion), height: alto)
            guard zona.width > 0, let contexto = NSGraphicsContext.current?.cgContext else { return true }
            NSBezierPath(rect: zona).setClip()

            /// Un texto en la zona: corrido a la izquierda lo desplazado, más el movimiento de la
            /// animación, y con la opacidad dada.
            func poner(_ texto: NSAttributedString, desplazamiento: CGFloat,
                       dx: CGFloat = 0, dy: CGFloat = 0, opacidad: CGFloat = 1) {
                guard opacidad > 0 else { return }
                contexto.saveGState()
                contexto.setAlpha(opacidad)
                texto.draw(at: NSPoint(x: zona.minX - desplazamiento + dx, y: (alto - texto.size().height) / 2 + dy))
                contexto.restoreGState()
            }
            // Sin transición en curso, solo el texto actual en su lugar.
            guard let animacion else {
                if let entrante { poner(entrante, desplazamiento: desplazamientoEntrante) }
                return true
            }
            // Si no hay saliente (aparece el texto donde solo estaba el icono), solo entra el nuevo;
            // si no hay entrante (se quita el texto), solo sale el anterior.
            let p = CGFloat(suavizar(progreso))
            switch animacion {
            case .deslizar:
                // Los dos se recorren juntos a la izquierda: lo más ancho de los dos más el hueco,
                // así el saliente acaba fuera de la zona y el entrante empieza fuera de ella.
                let visible = { (texto: NSAttributedString?) in min(texto?.size().width ?? 0, anchoMaximo) }
                let distancia = max(visible(saliente?.texto), visible(entrante)) + hueco
                if let saliente {
                    poner(saliente.texto, desplazamiento: saliente.desplazamiento, dx: -p * distancia)
                }
                if let entrante {
                    poner(entrante, desplazamiento: desplazamientoEntrante, dx: (1 - p) * distancia)
                }
            case .rodillo:
                if let saliente {
                    poner(saliente.texto, desplazamiento: saliente.desplazamiento, dy: p * alto, opacidad: 1 - p)
                }
                if let entrante {
                    poner(entrante, desplazamiento: desplazamientoEntrante, dy: (p - 1) * alto, opacidad: p)
                }
            case .fundido:
                if let saliente {
                    poner(saliente.texto, desplazamiento: saliente.desplazamiento, opacidad: 1 - p)
                }
                if let entrante {
                    poner(entrante, desplazamiento: desplazamientoEntrante, opacidad: p)
                }
            case .revelado:
                let salida = CGFloat(1 - suavizar(min(1, progreso / finSalida)))
                if let saliente {
                    poner(saliente.texto, desplazamiento: saliente.desplazamiento, opacidad: salida)
                }
                guard let entrante else { break }
                let revelado = CGFloat(suavizar(min(1, max(0, (progreso - inicioRevelado) / (1 - inicioRevelado)))))
                guard revelado > 0 else { break }
                // El texto en su propia capa y, encima, un degradado que deja solo lo que está antes
                // del frente (destinationIn conserva el texto donde el degradado es opaco). El frente
                // va de la orilla izquierda hasta pasar la derecha, con la orilla difuminada delante.
                let frente = zona.minX + revelado * (min(entrante.size().width, anchoMaximo) + orilla)
                contexto.beginTransparencyLayer(auxiliaryInfo: nil)
                poner(entrante, desplazamiento: desplazamientoEntrante)
                contexto.setBlendMode(.destinationIn)
                let colores = [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)] as CFArray
                let degradado = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colores, locations: [0, 1])!
                contexto.drawLinearGradient(degradado, start: CGPoint(x: frente - orilla, y: 0), end: CGPoint(x: frente, y: 0),
                                            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                contexto.endTransparencyLayer()
            case .ninguna:
                if let entrante { poner(entrante, desplazamiento: desplazamientoEntrante) }
            }
            return true
        }
        imagen.isTemplate = true
        return imagen
    }
}
