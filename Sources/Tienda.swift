import AppKit
import StoreKit

// La compra única "Invítame un café ☕", con StoreKit 2: desbloquea elegir la animación de la
// barra de menú. Todo lo demás es gratis.
//
// Solo existe en la versión de la Mac App Store, que se compila con -D TIENDA (tools/build.sh con
// TIENDA=1 o --sandbox, y tools/package-appstore.sh). En el DMG no se puede cobrar con Apple, así
// que ahí todo viene desbloqueado y StoreKit ni se toca.
//
// No hay servidor: Apple firma cada transacción y StoreKit la verifica en la Mac.
@MainActor
final class Tienda: ObservableObject {
    static let idCafe = "com.msucedo.letras.cafe"

    /// Si esta es la versión de la Mac App Store, la única en la que existe la compra.
    #if TIENDA
    static let enTienda = true
    #else
    static let enTienda = false
    #endif

    #if TIENDA
    @Published private(set) var desbloqueado = false
    #else
    @Published private(set) var desbloqueado = true
    #endif
    /// nil hasta que la App Store responde.
    @Published private(set) var producto: Product?
    /// Pidiendo el producto (y su precio) a la App Store.
    @Published private(set) var cargando = false
    /// Comprando o restaurando.
    @Published private(set) var ocupada = false
    /// Avisos para mostrar junto al botón de compra.
    @Published private(set) var mensaje: String?

    private var actualizaciones: Task<Void, Never>?

    /// Al abrir: escucha compras que llegan "por fuera" (otra Mac, reembolsos), carga el producto
    /// y revisa si ya se compró. currentEntitlements funciona sin internet.
    func empezar() {
        #if TIENDA
        guard actualizaciones == nil else { return }
        actualizaciones = Task { [weak self] in
            for await resultado in Transaction.updates {
                if case .verified(let transaccion) = resultado { await transaccion.finish() }
                await self?.revisarCompra()
            }
        }
        Task {
            await cargarProducto()
            await revisarCompra()
        }
        #endif
    }

    /// Si la App Store no conoce el producto (todavía no existe en App Store Connect, o no hay
    /// cuenta) no da error: devuelve una lista vacía. Hay que avisarlo.
    func cargarProducto() async {
        cargando = true
        defer { cargando = false }
        do {
            producto = try await Product.products(for: [Self.idCafe]).first
            mensaje = producto == nil ? "La compra no está disponible por ahora." : nil
        } catch {
            mensaje = "No pude cargar la tienda: \(error.localizedDescription)"
        }
    }

    /// Solo cuentan las transacciones verificadas y sin reembolso.
    private func revisarCompra() async {
        var comprado = false
        for await resultado in Transaction.currentEntitlements {
            if case .verified(let transaccion) = resultado, transaccion.productID == Self.idCafe,
               transaccion.revocationDate == nil {
                comprado = true
            }
        }
        desbloqueado = comprado
    }

    /// `ventana` es donde se pega la confirmación de Apple (ver VentanaCafe): tiene que seguir
    /// abierta hasta que terminen. En macOS 13 a 15.1 no se puede elegir y StoreKit usa la que esté
    /// al frente, que también es esa.
    func comprar(en ventana: NSWindow?) async {
        if producto == nil {
            await cargarProducto()
        }
        guard let producto else { return }  // cargarProducto ya dejó el aviso
        ocupada = true
        mensaje = nil
        defer { ocupada = false }
        do {
            let resultado: Product.PurchaseResult
            if #available(macOS 15.2, *), let ventana {
                resultado = try await producto.purchase(confirmIn: ventana)
            } else {
                resultado = try await producto.purchase()
            }
            switch resultado {
            case .success(.verified(let transaccion)):
                await transaccion.finish()
                await revisarCompra()
            case .success(.unverified):
                mensaje = "No se pudo verificar la compra."
            case .pending:
                mensaje = "La compra está pendiente de aprobación."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            mensaje = "No se pudo completar la compra: \(error.localizedDescription)"
        }
    }

    /// Apple pide un botón para restaurar: le pregunta a la App Store por las compras de la cuenta
    /// (puede pedir la contraseña) y vuelve a revisar.
    func restaurar() async {
        ocupada = true
        mensaje = nil
        defer { ocupada = false }
        do {
            try await AppStore.sync()
            await revisarCompra()
            if !desbloqueado { mensaje = "No encontré el café en esta cuenta." }
        } catch {
            mensaje = "No se pudo restaurar: \(error.localizedDescription)"
        }
    }
}
