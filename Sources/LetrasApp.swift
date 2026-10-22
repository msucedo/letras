import Combine
import ServiceManagement
import SwiftUI

// Punto de entrada. MenuBarExtra pone el icono (y la línea que se canta) en la barra de menú; con
// el estilo .window el contenido se abre como un panel translúcido, igual que el Centro de Control.
@main
struct LetrasApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegado

    var body: some Scene {
        MenuBarExtra {
            PanelView(monitor: delegado.monitor, store: delegado.store, tienda: delegado.tienda)
        } label: {
            EtiquetaBarra(marquesina: delegado.marquesina)
        }
        .menuBarExtraStyle(.window)
    }
}

/// El monitor vive en el delegado y no en la App, porque tiene que empezar a escuchar a los
/// reproductores al abrir la app, aunque nunca se abra el panel.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = AjustesStore()
    let monitor = Monitor()
    let tienda = Tienda()
    lazy var marquesina = Marquesina(monitor: monitor, store: store, tienda: tienda)
    private var flotante: VentanaFlotante?
    private var observaciones: [AnyCancellable] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.$ajustes
            .map(\.ajuste)
            .removeDuplicates()
            .sink { [monitor] in monitor.ajuste = $0 }
            .store(in: &observaciones)
        flotante = VentanaFlotante(monitor: monitor, store: store)
        tienda.empezar()
    }
}

/// El icono y la línea que se canta, ya dibujados por la marquesina.
struct EtiquetaBarra: View {
    @ObservedObject var marquesina: Marquesina

    var body: some View {
        Image(nsImage: marquesina.imagen)
    }
}

struct PanelView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var store: AjustesStore
    @ObservedObject var tienda: Tienda
    /// Si están a la vista las opciones de abajo de la letra. Cada vez que se abre el panel empiezan
    /// cerradas, aunque se hayan dejado abiertas la vez anterior.
    @State private var abierto = false
    /// Se pone en true al abrirse el panel, para que el contenido aparezca con una animación.
    @State private var aparecido = false
    /// Si el panel se ve. Cerrado, la letra no se dibuja: la vista del panel sobrevive a cerrarlo y
    /// seguiría recalculándose y animándose con cada línea sin que nadie la vea.
    @State private var visible = false
    // Si la app abre al iniciar sesión lo sabe el sistema, no los ajustes, así que se le pregunta
    // a SMAppService en vez de guardarlo aparte.
    @State private var alIniciarSesion = SMAppService.mainApp.status == .enabled
    @State private var errorDeInicio: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            encabezado
            Group {
                if visible {
                    LetraView(monitor: monitor)
                } else {
                    Color.clear
                }
            }
            .frame(height: 340)
            if !monitor.sinPermiso.isEmpty {
                avisoDePermiso
            }
            Button {
                // Sin withAnimation: la ventana del MenuBarExtra no sabe cambiar de tamaño con
                // animación y, mientras lo intenta, el panel se ve negro un instante.
                abierto.toggle()
            } label: {
                Image(systemName: "chevron.down")
                    .modifier(GiroDeFlecha(abierto: abierto))
                    .frame(maxWidth: .infinity, minHeight: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(abierto ? "Ocultar opciones" : "Mostrar opciones")

            if abierto {
                opciones
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // Al abrir el panel, el contenido baja un poco mientras aparece.
        .opacity(aparecido ? 1 : 0)
        .offset(y: aparecido ? 0 : -8)
        // Salir sigue funcionando con ⌘Q aunque el botón esté oculto.
        .background(Button("") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q").hidden())
        // La vista del panel sobrevive a cerrarlo, así que las opciones se cierran y la animación de
        // entrada se reinicia al esconderse; como ya no está en pantalla, no se ve.
        .background(VigilaVentana { visible in
            self.visible = visible
            if visible {
                withAnimation(.easeOut(duration: 0.25)) { aparecido = true }
            } else {
                abierto = false
                aparecido = false
            }
        })
        .padding(16)
        .frame(width: 360)
    }

    private var encabezado: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(monitor.cancion?.titulo ?? "Letras")
                .font(.headline)
                .lineLimit(1)
            Group {
                if let cancion = monitor.cancion {
                    let pausa = monitor.estado == .enPausa ? " · en pausa" : ""
                    Text("\(cancion.artista) · \(monitor.nombreReproductor ?? "")\(pausa)")
                } else {
                    Text("Pon algo en Spotify o en Música")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private var avisoDePermiso: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Letras no tiene permiso de ver qué suena en \(monitor.sinPermiso.joined(separator: " y ")).")
                .font(.caption)
            HStack {
                Button("Abrir Ajustes del Sistema") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                }
                Button("Reintentar") { monitor.reintentar() }
            }
            .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }

    private var opciones: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Línea actual en la barra de menú", isOn: $store.ajustes.lineaEnLaBarra)
            Picker("Animación en la barra", selection: $store.ajustes.animacionBarra) {
                ForEach(AnimacionBarra.allCases) { animacion in
                    Text(animacion.nombre).tag(animacion)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(!store.ajustes.lineaEnLaBarra || !tienda.desbloqueado)
            if !tienda.desbloqueado {
                cafe
            } else if Tienda.enTienda {
                Text("Gracias por el café ☕")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Ventana flotante", isOn: $store.ajustes.flotante)
            Stepper(value: $store.ajustes.ajuste, in: -5...5, step: 0.25) {
                Text("Desfase de la letra: \(Self.formato(store.ajustes.ajuste))")
            }
            .help("Si la letra va atrasada, súbelo; si va adelantada, bájalo.")
            Divider()
            HStack {
                Toggle("Abrir al iniciar sesión", isOn: Binding(get: { alIniciarSesion }, set: cambiarInicio))
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Salir") { NSApplication.shared.terminate(nil) }
            }
            if let errorDeInicio {
                Text(errorDeInicio)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Divider()
            acercaDe
        }
        .toggleStyle(.switch)
    }

    /// La compra que desbloquea elegir la animación (solo en la versión de la Mac App Store).
    private var cafe: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                Task { await tienda.comprar() }
            } label: {
                if let producto = tienda.producto {
                    Text("☕ Invítame un café (\(producto.displayPrice)) y elige la animación")
                } else {
                    Text("☕ Invítame un café y elige la animación")
                }
            }
            .disabled(tienda.ocupada || tienda.cargando)
            HStack(spacing: 12) {
                Button("Restaurar compra") { Task { await tienda.restaurar() } }
                if tienda.producto == nil, !tienda.cargando {
                    Button("Reintentar") { Task { await tienda.cargarProducto() } }
                }
                if tienda.ocupada || tienda.cargando {
                    ProgressView().controlSize(.small)
                }
            }
            .buttonStyle(.link)
            .font(.caption)
            .disabled(tienda.ocupada)
            if let mensaje = tienda.mensaje {
                Text(mensaje)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var acercaDe: some View {
        // El gris va solo en los textos: los enlaces se quedan del color de acento, para que se vea
        // que se pueden abrir.
        HStack(spacing: 4) {
            Text("Letras \(Self.version) · by").foregroundStyle(.secondary)
            Link("@msucedo", destination: URL(string: "https://github.com/msucedo")!)
            Text("· Letras de").foregroundStyle(.secondary)
            Link("LRCLIB", destination: URL(string: "https://lrclib.net")!)
        }
        .font(.caption)
        .lineLimit(1)
        .fixedSize()
    }

    /// "0.1.0 (1)": la versión y el número de compilación del Info.plist.
    static var version: String {
        let info = Bundle.main.infoDictionary
        let corta = info?["CFBundleShortVersionString"] as? String ?? "?"
        let compilacion = info?["CFBundleVersion"] as? String ?? "?"
        return "\(corta) (\(compilacion))"
    }

    static func formato(_ segundos: Double) -> String {
        segundos == 0 ? "0 s" : String(format: "%+.2f s", segundos)
    }

    private func cambiarInicio(_ activar: Bool) {
        do {
            if activar {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorDeInicio = nil
        } catch {
            errorDeInicio = "No se pudo cambiar: \(error.localizedDescription)"
        }
        // macOS puede pedir que se apruebe en Ajustes > General > Ítems de inicio.
        if SMAppService.mainApp.status == .requiresApproval {
            errorDeInicio = "Apruébalo en Ajustes del Sistema > General > Ítems de inicio."
        }
        alIniciarSesion = SMAppService.mainApp.status == .enabled
    }
}

/// Gira la flecha de las opciones. En macOS 14+ la animación se limita al giro: con
/// .animation(_:value:) también se animaba la posición de la flecha, que al cerrar las opciones
/// subía desde abajo mientras el panel se encogía.
private struct GiroDeFlecha: ViewModifier {
    let abierto: Bool

    func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            content.animation(.easeInOut(duration: 0.2)) {
                $0.rotationEffect(.degrees(abierto ? 180 : 0))
            }
        } else {
            content
                .rotationEffect(.degrees(abierto ? 180 : 0))
                .animation(.easeInOut(duration: 0.2), value: abierto)
        }
    }
}

/// La letra completa, con la línea que se canta resaltada y siempre a la vista.
struct LetraView: View {
    @ObservedObject var monitor: Monitor
    /// Dónde queda el centro de cada línea, medido desde el principio de la letra.
    @State private var centros: [Int: CGFloat] = [:]
    @State private var scroll = RefScroll()

    var body: some View {
        switch monitor.letra {
        case .nadaSonando:
            mensaje("Nada sonando", icono: "music.note")
        case .buscando:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .sinLetra:
            mensaje("No encontré la letra de esta canción", icono: "text.badge.xmark")
        case .sinConexion:
            mensaje("No pude buscar la letra. Lo vuelvo a intentar en un momento.", icono: "wifi.slash")
        case .lista(.instrumental):
            mensaje("Instrumental", icono: "pianokeys")
        case .lista(.simple(let lineas)):
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Esta letra no está sincronizada")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 4)
                    ForEach(Array(lineas.enumerated()), id: \.offset) { _, linea in
                        Text(linea.isEmpty ? " " : linea)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .lista(.sincronizada(let lineas)):
            sincronizada(lineas)
        }
    }

    /// La letra va en un ScrollView, para poder recorrerla a mano, pero el desplazamiento a la línea
    /// actual lo hace AppKit y no SwiftUI: en macOS, el scrollTo animado de SwiftUI no arranca
    /// desde donde está la letra (la baja y luego la sube). Con la animación de AppKit se mueve
    /// directo de la posición actual a la nueva.
    private func sincronizada(_ lineas: [Linea]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(lineas.enumerated()), id: \.offset) { i, linea in
                    let actual = i == monitor.indice
                    Text(linea.texto.isEmpty ? "♪" : linea.texto)
                        // El grosor no se anima (brinca de golpe); el color y la escala sí.
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(actual ? Color.primary : Color.secondary)
                        .scaleEffect(actual ? 1.05 : 1, anchor: .leading)
                        .animation(.easeInOut(duration: 0.3), value: actual)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Espacio para lo que crece la línea actual, para que no se corte.
                        .padding(.trailing, 16)
                        .background(GeometryReader { medida in
                            Color.clear.preference(key: CentrosDeLineas.self,
                                                   value: [i: medida.frame(in: .named("letra")).midY])
                        })
                }
            }
            // Aire arriba y abajo para que la primera y la última línea también puedan quedar al centro.
            .padding(.vertical, 150)
            // Medido desde el principio de la letra: no cambia al desplazarla.
            .coordinateSpace(name: "letra")
            .background(BuscaScroll(ref: scroll))
        }
        .onPreferenceChange(CentrosDeLineas.self) { nuevos in
            let primeraVez = centros.isEmpty
            centros = nuevos
            if primeraVez { centrarAlAbrir(nuevos) }
        }
        .onChange(of: monitor.indice) { _ in centrar(animado: true) }
    }

    /// Al abrir el panel la letra se crea desde cero y, cuando llegan las medidas de las líneas,
    /// SwiftUI todavía no conecta el NSScrollView: se reintenta en las siguientes vueltas del run
    /// loop (milisegundos cada una) hasta que esté, para que abra ya en la línea actual.
    /// Ya centrada, se repite una vez en la siguiente vuelta por si AppKit todavía estaba
    /// acomodando el alto de la letra; si ya quedó bien, no se mueve.
    private func centrarAlAbrir(_ centros: [Int: CGFloat], intentos: Int = 20) {
        if centrar(animado: false, centros: centros) {
            DispatchQueue.main.async { centrar(animado: false) }
        } else if intentos > 0 {
            DispatchQueue.main.async { centrarAlAbrir(centros, intentos: intentos - 1) }
        }
    }

    /// Devuelve si pudo: falla mientras el NSScrollView no está listo.
    @discardableResult
    private func centrar(animado: Bool, centros: [Int: CGFloat]? = nil) -> Bool {
        guard let vista = scroll.vista, let documento = vista.documentView, documento.frame.height > 0,
              let centro = (centros ?? self.centros)[monitor.indice ?? 0] else { return false }
        let clip = vista.contentView
        let visible = clip.bounds.height
        let alto = documento.frame.height
        // Desde arriba de la letra, sin pasarse de las orillas.
        var y = min(max(0, centro - visible / 2), max(0, alto - visible))
        if !documento.isFlipped { y = alto - visible - y }
        let destino = NSPoint(x: clip.bounds.origin.x, y: y)
        if animado {
            NSAnimationContext.runAnimationGroup { contexto in
                contexto.duration = 0.45
                contexto.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                clip.animator().setBoundsOrigin(destino)
            }
        } else {
            clip.setBoundsOrigin(destino)
        }
        vista.reflectScrolledClipView(clip)
        return true
    }

    private func mensaje(_ texto: String, icono: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icono)
                .font(.largeTitle)
            Text(texto)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Junta el centro de cada línea de la letra, por número de línea.
private struct CentrosDeLineas: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

/// El NSScrollView de AppKit que SwiftUI usa por dentro para el ScrollView. Es una clase para que
/// guardarlo no vuelva a dibujar la vista.
final class RefScroll {
    weak var vista: NSScrollView?
}

/// Una vista invisible dentro del ScrollView que encuentra el NSScrollView que la contiene.
private struct BuscaScroll: NSViewRepresentable {
    let ref: RefScroll

    func makeNSView(context: Context) -> Vista {
        let vista = Vista()
        vista.ref = ref
        return vista
    }

    func updateNSView(_ vista: Vista, context: Context) {
        vista.ref = ref
        ref.vista = vista.enclosingScrollView
    }

    final class Vista: NSView {
        var ref: RefScroll?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            ref?.vista = enclosingScrollView
        }
    }
}

/// Avisa si la ventana que la contiene se ve en pantalla. SwiftUI no da acceso a la ventana del
/// MenuBarExtra, así que esta vista invisible la encuentra y escucha sus cambios (igual que en Altar).
private struct VigilaVentana: NSViewRepresentable {
    let alCambiar: (Bool) -> Void

    func makeNSView(context: Context) -> Vista {
        let vista = Vista()
        vista.alCambiar = alCambiar
        return vista
    }

    func updateNSView(_ vista: Vista, context: Context) {
        vista.alCambiar = alCambiar
    }

    final class Vista: NSView {
        var alCambiar: ((Bool) -> Void)?
        private var observacion: AnyCancellable?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else {
                observacion = nil
                return
            }
            observacion = NotificationCenter.default
                .publisher(for: NSWindow.didChangeOcclusionStateNotification, object: window)
                .sink { [weak self] _ in self?.avisar() }
            avisar()
        }

        private func avisar() {
            alCambiar?(window?.occlusionState.contains(.visible) ?? false)
        }
    }
}
