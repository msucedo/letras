import Foundation

/// Cómo cambia de una línea a otra el texto de la barra de menú.
enum AnimacionBarra: String, Codable, CaseIterable, Identifiable {
    /// La anterior sale por la izquierda y la nueva entra por la derecha.
    case deslizar
    /// La anterior sube y se desvanece, la nueva entra desde abajo.
    case rodillo
    /// La anterior se desvanece y la nueva se descubre de izquierda a derecha.
    case revelado
    /// Una se desvanece mientras la otra aparece, las dos en su lugar.
    case fundido
    /// Cambio inmediato.
    case ninguna

    var id: Self { self }

    var nombre: String {
        switch self {
        case .deslizar: return "Deslizar"
        case .rodillo: return "Rodillo"
        case .revelado: return "Revelado"
        case .fundido: return "Fundido"
        case .ninguna: return "Ninguna"
        }
    }

    /// Segundos que dura la transición.
    var duracion: Double {
        switch self {
        case .deslizar: return 0.4
        case .rodillo: return 0.35
        case .revelado: return 0.5
        case .fundido: return 0.3
        case .ninguna: return 0
        }
    }
}

struct Ajustes: Codable, Equatable {
    /// La línea que se canta, junto al icono en la barra de menú.
    var lineaEnLaBarra = true
    /// La ventanita flotante con la línea anterior, la actual y la siguiente.
    var flotante = false
    /// Segundos que se adelanta (positivo) o se atrasa (negativo) la letra, para las que vienen desfasadas.
    var ajuste = 0.0
    var animacionBarra = AnimacionBarra.fundido

    init() {}

    // Campo por campo y con valor por omisión, para que una versión nueva con más ajustes pueda
    // leer lo que guardó una anterior.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = Ajustes()
        lineaEnLaBarra = try c.decodeIfPresent(Bool.self, forKey: .lineaEnLaBarra) ?? base.lineaEnLaBarra
        flotante = try c.decodeIfPresent(Bool.self, forKey: .flotante) ?? base.flotante
        ajuste = try c.decodeIfPresent(Double.self, forKey: .ajuste) ?? base.ajuste
        // try?: una animación que esta versión no conoce no debe tirar los demás ajustes.
        animacionBarra = (try? c.decodeIfPresent(AnimacionBarra.self, forKey: .animacionBarra)) ?? base.animacionBarra
    }
}

// Guarda los ajustes en UserDefaults, como texto JSON, cada vez que cambian.
// Se pueden ver desde la terminal con: defaults read com.msucedo.letras ajustes
final class AjustesStore: ObservableObject {
    static let clave = "ajustes"

    @Published var ajustes: Ajustes {
        didSet { guardar() }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let texto = defaults.string(forKey: Self.clave),
           let ajustes = try? JSONDecoder().decode(Ajustes.self, from: Data(texto.utf8)) {
            self.ajustes = ajustes
        } else {
            self.ajustes = Ajustes()
        }
    }

    private func guardar() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let datos = try? encoder.encode(ajustes) else { return }
        defaults.set(String(decoding: datos, as: UTF8.self), forKey: Self.clave)
    }
}
