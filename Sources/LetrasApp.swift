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
            PanelView(monitor: delegado.monitor, store: delegado.store)
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
    lazy var marquesina = Marquesina(monitor: monitor, store: store)
    private var flotante: VentanaFlotante?
    private var observaciones: [AnyCancellable] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.$ajustes
            .map(\.ajuste)
            .removeDuplicates()
            .sink { [monitor] in monitor.ajuste = $0 }
            .store(in: &observaciones)
        flotante = VentanaFlotante(monitor: monitor, store: store)
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
    @State private var abierto = false
    // Si la app abre al iniciar sesión lo sabe el sistema, no los ajustes, así que se le pregunta
    // a SMAppService en vez de guardarlo aparte.
    @State private var alIniciarSesion = SMAppService.mainApp.status == .enabled
    @State private var errorDeInicio: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            encabezado
            LetraView(monitor: monitor)
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
                    .rotationEffect(.degrees(abierto ? 180 : 0))
                    .animation(.easeInOut(duration: 0.2), value: abierto)
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
        // Salir sigue funcionando con ⌘Q aunque el botón esté oculto.
        .background(Button("") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q").hidden())
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
        }
        .toggleStyle(.switch)
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

/// La letra completa, con la línea que se canta resaltada y siempre a la vista.
struct LetraView: View {
    @ObservedObject var monitor: Monitor

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

    private func sincronizada(_ lineas: [Linea]) -> some View {
        ScrollViewReader { scroll in
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
                            .id(i)
                    }
                }
                // Aire arriba y abajo para que la primera y la última línea también puedan quedar al centro.
                .padding(.vertical, 150)
            }
            .onAppear { centrar(scroll, animado: false) }
            .onChange(of: monitor.indice) { _ in centrar(scroll, animado: true) }
        }
    }

    private func centrar(_ scroll: ScrollViewProxy, animado: Bool) {
        let destino = monitor.indice ?? 0
        if animado {
            withAnimation(.easeInOut(duration: 0.3)) { scroll.scrollTo(destino, anchor: .center) }
        } else {
            scroll.scrollTo(destino, anchor: .center)
        }
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
