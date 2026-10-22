import AppKit
import Combine
import SwiftUI

// La letra estilo karaoke, flotando sobre las demás ventanas: la línea anterior, la que se canta
// y la siguiente. Es un NSPanel de AppKit porque SwiftUI, con el SDK de macOS 13, no deja hacer
// ventanas sin borde, transparentes y en un nivel de ventana elegido.
final class VentanaFlotante {
    /// Con este nombre AppKit guarda solo la posición de la ventana en UserDefaults.
    static let nombreDePosicion = "LetraFlotante"

    private let monitor: Monitor
    private let store: AjustesStore
    private var panel: NSPanel?
    private var observaciones: [AnyCancellable] = []

    init(monitor: Monitor, store: AjustesStore) {
        self.monitor = monitor
        self.store = store
        store.$ajustes
            .map(\.flotante)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] visible in self?.mostrar(visible) }
            .store(in: &observaciones)
        // Al conectar o desconectar un monitor, o cambiar la resolución, la ventana podría quedar
        // donde ya no hay pantalla.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.asegurarVisible() }
            .store(in: &observaciones)
    }

    private func mostrar(_ visible: Bool) {
        guard visible else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? crearPanel()
        self.panel = panel
        asegurarVisible()
        panel.orderFrontRegardless()
    }

    /// Si ninguna pantalla muestra al menos un pedazo de la ventana, la regresa abajo al centro.
    private func asegurarVisible() {
        guard let panel else { return }
        let seVe = NSScreen.screens.contains { pantalla in
            let comun = pantalla.visibleFrame.intersection(panel.frame)
            return comun.width >= 60 && comun.height >= 40
        }
        if !seVe { ponerAbajo(panel) }
    }

    /// Abajo al centro de la pantalla principal, como los subtítulos.
    private func ponerAbajo(_ panel: NSPanel) {
        guard let pantalla = NSScreen.main?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: pantalla.midX - panel.frame.width / 2, y: pantalla.minY + 60))
    }

    private func crearPanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            // nonactivatingPanel: hacer clic en la letra no le quita el foco a la app en la que estás.
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // En todos los escritorios (Spaces) y también encima de las apps en pantalla completa.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let vista = VistaArrastrable(rootView: KaraokeView(monitor: monitor))
        vista.ocultar = { [weak store] in store?.ajustes.flotante = false }
        panel.contentView = vista
        panel.setContentSize(vista.fittingSize)

        // Si ya se había movido antes, AppKit la pone donde quedó; si no, abajo al centro.
        if !panel.setFrameUsingName(Self.nombreDePosicion) {
            ponerAbajo(panel)
        }
        panel.setFrameAutosaveName(Self.nombreDePosicion)
        return panel
    }
}

/// La vista que llena el panel. Como no tiene controles, cualquier clic sirve para arrastrar la
/// ventana, y el clic derecho ofrece ocultarla.
private final class VistaArrastrable<Contenido: View>: NSHostingView<Contenido> {
    var ocultar: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Ocultar ventana flotante", action: #selector(ocultarDesdeMenu), keyEquivalent: "")
            .target = self
        return menu
    }

    @objc private func ocultarDesdeMenu() {
        ocultar?()
    }
}

/// Tamaño fijo: si cambiara con cada línea, la ventana brincaría. Cabe la línea actual en dos
/// renglones, para que las largas se lean completas.
private struct KaraokeView: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        Group {
            if lineas.isEmpty {
                Text(mensaje)
                    .font(.system(size: 16, weight: .semibold))
                    .id(mensaje)
                    .transition(.opacity)
            } else {
                rodillo
            }
        }
        .animation(.easeInOut(duration: 0.35), value: monitor.indice)
        .animation(.easeInOut(duration: 0.25), value: mensaje)
        .padding(.horizontal, 20)
        .frame(width: 520, height: 124)
        // Las líneas que entran y salen se deslizan desde fuera del recuadro.
        .clipped()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// La anterior, la actual y la siguiente, identificadas por su número de línea: al avanzar,
    /// SwiftUI ve las mismas líneas en otro lugar y las anima subiendo, como un rodillo. La que
    /// sale se va por arriba y la nueva entra por abajo.
    private var rodillo: some View {
        let actual = monitor.indice ?? -1
        return VStack(spacing: 6) {
            ForEach([actual - 1, actual, actual + 1], id: \.self) { i in
                let esActual = i == actual
                Text(texto(i))
                    // La misma letra para todas: el tamaño cambia con scaleEffect, que sí se
                    // anima; un cambio de font brincaría de golpe.
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(esActual ? 2 : 1)
                    .minimumScaleFactor(esActual ? 0.85 : 1)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .scaleEffect(esActual ? 1 : 0.875)
                    .opacity(esActual ? 1 : 0.55)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                            removal: .move(edge: .top).combined(with: .opacity)))
            }
        }
    }

    private var lineas: [Linea] {
        if case .lista(.sincronizada(let lineas)) = monitor.letra { return lineas }
        return []
    }

    /// El texto de la línea i. Antes de la primera (i = -1) va una nota, mientras empieza a cantar;
    /// fuera de la letra, nada.
    private func texto(_ i: Int) -> String {
        if i == -1 { return "♪" }
        guard lineas.indices.contains(i) else { return " " }
        return lineas[i].texto.isEmpty ? "♪" : lineas[i].texto
    }

    /// Lo que se muestra cuando no hay letra sincronizada.
    private var mensaje: String {
        switch monitor.letra {
        case .lista(.sincronizada): return ""
        case .lista(.simple): return "Letra no sincronizada"
        case .lista(.instrumental): return "Instrumental"
        case .buscando: return "Buscando la letra…"
        case .sinLetra: return "Sin letra"
        case .sinConexion: return "Sin conexión"
        case .nadaSonando: return "Nada sonando"
        }
    }
}
