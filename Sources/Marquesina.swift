import AppKit
import Combine

// La etiqueta de la barra de menú: el icono y la línea que se canta, dibujados en una sola imagen.
//
// Es una imagen y no un Text porque la etiqueta de un MenuBarExtra ignora .frame y el recorte, y una
// línea larga empujaría a los demás iconos. Si la línea no cabe en el ancho máximo, la imagen se
// queda de ese ancho y el texto se desliza adentro, como marquesina: espera un momento, avanza
// hasta el final y termina un poco antes de que empiece la siguiente línea.
@MainActor
final class Marquesina: ObservableObject {
    @Published private(set) var imagen: NSImage

    /// Lo más que ocupa el texto en la barra, en puntos.
    static let anchoMaximo: CGFloat = 260
    /// Segundos quieta al empezar la línea, para leer el principio.
    static let espera = 1.0
    /// Segundos antes de la siguiente línea en que ya debe verse el final.
    static let margenFinal = 1.0
    /// Puntos por segundo, como mínimo, aunque la línea dure mucho.
    static let velocidadMinima = 30.0
    /// Cuánto dura la última línea, que no tiene siguiente.
    static let duracionUltima = 5.0
    static let cuadrosPorSegundo = 30.0

    private let monitor: Monitor
    private let store: AjustesStore
    private var texto: NSAttributedString?
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
        imagen = Self.dibujar(texto: nil, desplazamiento: 0)
        // Cambia la línea, la letra, se pausa o se reanuda, o se apaga la línea en la barra.
        Publishers.CombineLatest4(monitor.$indice, monitor.$letra, monitor.$estado,
                                  store.$ajustes.map(\.lineaEnLaBarra))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.actualizar() }
            .store(in: &observaciones)
    }

    private func actualizar() {
        if store.ajustes.lineaEnLaBarra, let linea = monitor.lineaActual {
            if texto?.string != linea {
                texto = NSAttributedString(string: linea, attributes: [.font: NSFont.menuBarFont(ofSize: 0)])
            }
        } else {
            texto = nil
        }
        dibujarCuadro()
    }

    /// Dibuja la imagen con el texto donde toca en este momento, y deja el reloj corriendo solo
    /// mientras el texto se está moviendo.
    private func dibujarCuadro() {
        let recorrido = max(0, (texto?.size().width ?? 0) - Self.anchoMaximo)
        let desplazamiento = recorrido > 0 ? desplazamientoActual(recorrido: recorrido) : 0
        imagen = Self.dibujar(texto: texto, desplazamiento: desplazamiento)

        let enMovimiento = recorrido > 0 && monitor.estado == .reproduciendo && desplazamiento < recorrido
        if enMovimiento, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1 / Self.cuadrosPorSegundo, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.dibujarCuadro() }
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
        guard case .lista(.sincronizada(let lineas)) = monitor.letra, let i = monitor.indice else { return 0 }
        let inicio = lineas[i].tiempo
        let fin = i + 1 < lineas.count ? lineas[i + 1].tiempo : inicio + Self.duracionUltima
        let transcurrido = monitor.posicion + monitor.ajuste - inicio - Self.espera
        let disponible = fin - inicio - Self.espera - Self.margenFinal
        let velocidad = disponible > 0 ? max(Double(recorrido) / disponible, Self.velocidadMinima) : Self.velocidadMinima
        return min(recorrido, max(0, CGFloat(transcurrido * velocidad)))
    }

    /// El icono y, si hay, el texto recortado al ancho máximo y corrido a la izquierda. Es una
    /// imagen plantilla (isTemplate): macOS la pinta del color de la barra, clara u oscura.
    private static func dibujar(texto: NSAttributedString?, desplazamiento: CGFloat) -> NSImage {
        let alto = NSStatusBar.system.thickness
        let separacion: CGFloat = 5
        let tamTexto = texto?.size() ?? .zero
        let anchoTexto = min(tamTexto.width, anchoMaximo)
        let ancho = icono.size.width + (texto == nil ? 0 : separacion + anchoTexto)

        let imagen = NSImage(size: NSSize(width: ceil(ancho), height: alto), flipped: false) { _ in
            icono.draw(at: NSPoint(x: 0, y: (alto - icono.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
            if let texto {
                let zona = NSRect(x: icono.size.width + separacion, y: 0, width: anchoTexto, height: alto)
                NSBezierPath(rect: zona).setClip()
                texto.draw(at: NSPoint(x: zona.minX - desplazamiento, y: (alto - tamTexto.height) / 2))
            }
            return true
        }
        imagen.isTemplate = true
        return imagen
    }
}
