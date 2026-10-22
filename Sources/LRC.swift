import Foundation

/// Una línea de la letra con el segundo en que empieza a cantarse.
struct Linea: Codable, Equatable {
    var tiempo: Double
    var texto: String
}

/// La letra de una canción: sincronizada (cada línea con su tiempo) o solo el texto.
enum Letra: Codable, Equatable {
    case sincronizada([Linea])
    case simple([String])
    case instrumental

    var lineas: [String] {
        switch self {
        case .sincronizada(let lineas): return lineas.map(\.texto)
        case .simple(let lineas): return lineas
        case .instrumental: return []
        }
    }
}

// Lee el formato LRC: cada línea empieza con una o varias marcas [mm:ss.xx]. Las marcas que no
// son de tiempo ([ar:…], [ti:…], [offset:…]) son datos de la canción; solo se usa offset.
enum LRC {
    static func leer(_ texto: String) -> [Linea] {
        var lineas: [Linea] = []
        var desfase = 0.0
        for renglon in texto.components(separatedBy: .newlines) {
            var resto = Substring(renglon.trimmingCharacters(in: .whitespaces))
            var tiempos: [Double] = []
            // Una línea que se repite puede venir con varias marcas: [00:12.00][01:30.50]Coro
            while resto.hasPrefix("["), let cierre = resto.firstIndex(of: "]") {
                let marca = resto[resto.index(after: resto.startIndex)..<cierre]
                if let tiempo = segundos(marca) {
                    tiempos.append(tiempo)
                } else if marca.lowercased().hasPrefix("offset:"),
                          let ms = Double(marca.dropFirst("offset:".count).trimmingCharacters(in: .whitespaces)) {
                    // En LRC, un offset positivo adelanta la letra.
                    desfase = -ms / 1000
                }
                resto = resto[resto.index(after: cierre)...]
            }
            let texto = resto.trimmingCharacters(in: .whitespaces)
            for tiempo in tiempos {
                lineas.append(Linea(tiempo: tiempo, texto: texto))
            }
        }
        if desfase != 0 {
            lineas = lineas.map { Linea(tiempo: max(0, $0.tiempo + desfase), texto: $0.texto) }
        }
        // sort no es estable, y dos líneas con el mismo tiempo deben quedar en el orden del archivo.
        return lineas.enumerated()
            .sorted { ($0.element.tiempo, $0.offset) < ($1.element.tiempo, $1.offset) }
            .map(\.element)
    }

    /// "mm:ss", "mm:ss.xx" o "mm:ss:xx" a segundos; nil si no es una marca de tiempo.
    static func segundos<S: StringProtocol>(_ marca: S) -> Double? {
        let partes = marca.split(separator: ":", omittingEmptySubsequences: false)
        guard partes.count == 2 || partes.count == 3,
              let minutos = Int(partes[0]), minutos >= 0 else { return nil }
        var segundosTexto = String(partes[1])
        if partes.count == 3 { segundosTexto += "." + partes[2] }
        guard let segundos = Double(segundosTexto), segundos >= 0, segundos < 60 else { return nil }
        return Double(minutos) * 60 + segundos
    }

    /// El índice de la línea que se está cantando en ese segundo, o nil si todavía no empieza la
    /// primera. Búsqueda binaria: se llama varias veces por segundo.
    static func indice(en tiempo: Double, de lineas: [Linea]) -> Int? {
        var bajo = 0
        var alto = lineas.count
        while bajo < alto {
            let medio = (bajo + alto) / 2
            if lineas[medio].tiempo <= tiempo {
                bajo = medio + 1
            } else {
                alto = medio
            }
        }
        return bajo == 0 ? nil : bajo - 1
    }
}
