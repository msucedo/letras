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

/// Tamaño fijo: si cambiara con cada línea, la ventana brincaría.
private struct KaraokeView: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        VStack(spacing: 6) {
            Text(linea(-1))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Text(principal)
                .font(.system(size: 16, weight: .semibold))
            Text(linea(+1))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.horizontal, 20)
        .frame(width: 520, height: 96)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var lineas: [Linea] {
        if case .lista(.sincronizada(let lineas)) = monitor.letra { return lineas }
        return []
    }

    /// La línea que se canta; antes de la primera, nada (la primera ya se ve como la siguiente).
    private var principal: String {
        switch monitor.letra {
        case .lista(.sincronizada):
            guard let i = monitor.indice else { return "♪" }
            return lineas[i].texto.isEmpty ? "♪" : lineas[i].texto
        case .lista(.simple): return "Letra no sincronizada"
        case .lista(.instrumental): return "Instrumental"
        case .buscando: return "Buscando la letra…"
        case .sinLetra: return "Sin letra"
        case .sinConexion: return "Sin conexión"
        case .nadaSonando: return "Nada sonando"
        }
    }

    private func linea(_ desplazamiento: Int) -> String {
        guard !lineas.isEmpty else { return " " }
        let i = (monitor.indice ?? -1) + desplazamiento
        return lineas.indices.contains(i) ? lineas[i].texto : " "
    }
}
