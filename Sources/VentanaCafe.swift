import AppKit
import Combine
import SwiftUI

// La ventanita de "Invítame un café ☕", desde donde se compra. La compra no puede salir del panel
// de la barra de menú: el panel se cierra en cuanto pierde el foco, y la confirmación de Apple se
// quedaba sin ventana, sin terminar nunca (y la app, trabada con la compra a medias). Esta es una
// ventana normal que se queda abierta, y la confirmación se pega a ella.
@MainActor
final class VentanaCafe: NSObject, NSWindowDelegate {
    /// Solo una a la vez; se suelta al cerrarla.
    private static var abierta: VentanaCafe?

    static func mostrar(tienda: Tienda) {
        let ventana = abierta ?? VentanaCafe(tienda: tienda)
        abierta = ventana
        // La app no tiene icono en el Dock: sin activarla, la ventana sale detrás de las demás.
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        ventana.ventana.makeKeyAndOrderFront(nil)
    }

    private let ventana: NSWindow
    private var observaciones: [AnyCancellable] = []

    private init(tienda: Tienda) {
        ventana = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        ventana.title = "Invítame un café ☕"
        ventana.isReleasedWhenClosed = false
        ventana.delegate = self
        // Con el controlador, la ventana toma el tamaño de la vista y lo ajusta cuando cambia.
        ventana.contentViewController = NSHostingController(rootView: CafeView(tienda: tienda) { [weak self] in
            guard let self else { return }
            Task { await tienda.comprar(en: self.ventana) }
        })
        ventana.center()
        // Mientras se compra no se puede cerrar: la confirmación de Apple está pegada a ella.
        tienda.$ocupada
            .sink { [weak self] ocupada in
                self?.ventana.standardWindowButton(.closeButton)?.isEnabled = !ocupada
            }
            .store(in: &observaciones)
    }

    func windowWillClose(_ notification: Notification) {
        Self.abierta = nil
    }
}

private struct CafeView: View {
    @ObservedObject var tienda: Tienda
    let comprar: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("☕").font(.system(size: 40))
            if tienda.desbloqueado {
                Text("Gracias por el café ☕")
                    .font(.headline)
                Text("Ya puedes elegir la animación de la barra en las opciones del panel.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            } else {
                Text("Si Letras te gusta, invítame un café. Con él puedes elegir cómo cambia la línea en la barra de menú; todo lo demás es gratis.")
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: comprar) {
                    if let producto = tienda.producto {
                        Text("Invitar un café (\(producto.displayPrice))")
                    } else {
                        Text("Invitar un café")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
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
            }
            if let mensaje = tienda.mensaje {
                Text(mensaje)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(width: 320)
    }
}
