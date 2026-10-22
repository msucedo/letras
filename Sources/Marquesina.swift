import AppKit
import Combine

// La etiqueta de la barra de menú: el icono y el texto (título y artista al empezar, luego la línea
// que se canta), dibujados en una sola imagen.
//
// Es una imagen y no un Text porque la etiqueta de un MenuBarExtra ignora .frame y el recorte, y una
// línea larga empujaría a los demás iconos. Si el texto no cabe en el ancho máximo, la imagen se
// queda de ese ancho y el texto se desliza adentro, como marquesina: espera un momento, avanza
// hasta el final y termina un poco antes de que toque el siguiente.
//
// Al cambiar de texto se anima como se haya elegido en los ajustes (AnimacionBarra): deslizar,
// rodillo, revelado, fundido o ninguna. En todas menos la última, el ancho de la imagen pasa poco a
// poco de uno al otro para que los demás iconos se deslicen en lugar de brincar.
@MainActor
final class Marquesina: ObservableObject {
    @Published private(set) var imagen: NSImage

    /// Lo más que ocupa el texto en la barra, en puntos.
    static let anchoMaximo: CGFloat = 260
    /// Segundos quieto al empezar un texto, para leer el principio.
    static let espera = 1.0
    /// Segundos antes de que acabe su turno en que ya debe verse el final.
    static let margenFinal = 1.0
    /// Puntos por segundo, como mínimo, aunque el texto dure mucho.
    static let velocidadMinima = 30.0
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
    private var segmento: Segmento?
    private var texto: NSAttributedString?
    private var desplazamiento: CGFloat = 0
    /// El texto que va de salida mientras dura la transición, con el desplazamiento que tenía.
    private var saliente: (texto: NSAttributedString, desplazamiento: CGFloat)?
    private var inicioTransicion: TimeInterval = 0
    /// La animación de la transición en curso; si se cambia en los ajustes a media transición,
    /// esa termina como empezó.
    private var animacion = AnimacionBarra.deslizar
    private var timer: Timer?
    private var observaciones: [AnyCancellable] = []

    private static let icono: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        return NSImage(systemSymbolName: "music.quarternote.3", accessibilityDescription: "Letras")!
            .withSymbolConfiguration(config)!
    }()

    init(monitor: Monitor, store: AjustesStore) {
        self.monitor = monitor
        self.store = store
        imagen = Self.dibujar(entrante: nil, desplazamientoEntrante: 0, saliente: nil, progreso: 1, extra: 0,
                              animacion: .ninguna)
        // Cambia la canción, la línea, la letra, se pausa o se reanuda, o se apaga el texto en la barra.
        // receive(on:) lo deja para la siguiente vuelta del run loop: @Published avisa antes de
        // guardar el valor nuevo, y aquí se lee del monitor.
        Publishers.CombineLatest4(monitor.$indice, monitor.$letra, monitor.$estado,
                                  store.$ajustes.map(\.lineaEnLaBarra))
            .combineLatest(monitor.$cancion)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.actualizar() }
            .store(in: &observaciones)
    }

    private var ahora: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var posicion: Double { monitor.posicion + monitor.ajuste }

    /// Decide qué texto toca, empieza la transición si cambió y dibuja el cuadro. Lo llaman los
    /// cambios del monitor y, mientras algo se mueve, el reloj.
    private func actualizar() {
        let nuevo = store.ajustes.lineaEnLaBarra
            ? Segmento.actual(cancion: monitor.cancion, letra: monitor.letra, indice: monitor.indice, posicion: posicion)
            : nil
        if nuevo?.texto != segmento?.texto {
            // Si ya iba una transición, la que estaba saliendo desaparece y sale la que entraba.
            animacion = store.ajustes.animacionBarra
            saliente = animacion == .ninguna ? nil : texto.map { ($0, desplazamiento) }
            inicioTransicion = ahora
            texto = nuevo.map { NSAttributedString(string: $0.texto, attributes: [.font: NSFont.menuBarFont(ofSize: 0)]) }
            desplazamiento = 0
        }
        segmento = nuevo
        dibujarCuadro()
    }

    private func dibujarCuadro() {
        var progreso = 1.0
        if saliente != nil {
            progreso = min(1, (ahora - inicioTransicion) / animacion.duracion)
            if progreso >= 1 { saliente = nil }
        }
        let suave = Self.suavizar(progreso)

        let recorrido = max(0, (texto?.size().width ?? 0) - Self.anchoMaximo)
        desplazamiento = recorrido > 0 ? desplazamientoActual(recorrido: recorrido) : 0

        // El ancho después del icono: la separación más el texto, recortado al máximo.
        func extra(_ texto: NSAttributedString?) -> CGFloat {
            texto.map { Self.separacion + min($0.size().width, Self.anchoMaximo) } ?? 0
        }
        let anchoFinal = extra(texto)
        let anchoInicial = saliente.map { extra($0.texto) } ?? anchoFinal
        imagen = Self.dibujar(entrante: texto, desplazamientoEntrante: desplazamiento,
                              saliente: saliente, progreso: progreso,
                              extra: anchoInicial + (anchoFinal - anchoInicial) * CGFloat(suave),
                              animacion: animacion)

        let sonando = monitor.estado == .reproduciendo
        let enMovimiento = saliente != nil
            || (sonando && recorrido > 0 && desplazamiento < recorrido)
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
                                progreso: Double, extra: CGFloat, animacion: AnimacionBarra) -> NSImage {
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
            guard let saliente else {
                if let entrante { poner(entrante, desplazamiento: desplazamientoEntrante) }
                return true
            }
            let p = CGFloat(suavizar(progreso))
            switch animacion {
            case .deslizar:
                // Los dos se recorren juntos a la izquierda: lo más ancho de los dos más el hueco,
                // así el saliente acaba fuera de la zona y el entrante empieza fuera de ella.
                let visible = { (texto: NSAttributedString?) in min(texto?.size().width ?? 0, anchoMaximo) }
                let distancia = max(visible(saliente.texto), visible(entrante)) + hueco
                poner(saliente.texto, desplazamiento: saliente.desplazamiento, dx: -p * distancia)
                if let entrante {
                    poner(entrante, desplazamiento: desplazamientoEntrante, dx: (1 - p) * distancia)
                }
            case .rodillo:
                poner(saliente.texto, desplazamiento: saliente.desplazamiento, dy: p * alto, opacidad: 1 - p)
                if let entrante {
                    poner(entrante, desplazamiento: desplazamientoEntrante, dy: (p - 1) * alto, opacidad: p)
                }
            case .fundido:
                poner(saliente.texto, desplazamiento: saliente.desplazamiento, opacidad: 1 - p)
                if let entrante {
                    poner(entrante, desplazamiento: desplazamientoEntrante, opacidad: p)
                }
            case .revelado:
                let salida = CGFloat(1 - suavizar(min(1, progreso / finSalida)))
                poner(saliente.texto, desplazamiento: saliente.desplazamiento, opacidad: salida)
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
