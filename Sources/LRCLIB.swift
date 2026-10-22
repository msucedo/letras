import CryptoKit
import Foundation

// Busca letras en LRCLIB (lrclib.net), una base de datos abierta y gratuita de letras
// sincronizadas, y las guarda en disco para no volver a pedirlas.
//
// Primero pide la canción exacta (título, artista, álbum y duración); si no está, busca por
// título y artista y se queda con la versión de duración más parecida, porque una letra de otra
// versión (en vivo, remasterizada) se desfasa. Si tampoco aparece, intenta con el título sin
// agregados como " - Remastered 2011" o "(feat. …)".
final class LRCLIB {
    static let servidor = URL(string: "https://lrclib.net/api")!
    /// Cuántos segundos puede diferir la duración de otra versión para usar su letra.
    static let tolerancia = 5.0
    /// Las canciones sin letra se vuelven a buscar después de una semana, por si alguien la subió.
    static let vigenciaSinLetra: TimeInterval = 7 * 24 * 3600

    private let sesion: URLSession
    private let carpeta: URL

    init(carpeta: URL = LRCLIB.carpetaPorOmision) {
        self.carpeta = carpeta
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        // LRCLIB pide que cada app se identifique.
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        config.httpAdditionalHeaders = ["User-Agent": "Letras/\(version) (https://github.com/msucedo/letras)"]
        sesion = URLSession(configuration: config)
    }

    static var carpetaPorOmision: URL {
        let soporte = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return soporte.appendingPathComponent("com.msucedo.letras/letras", isDirectory: true)
    }

    /// La letra de la canción, o nil si LRCLIB no la tiene. Lanza un error si no se pudo
    /// preguntar (sin internet, servidor ocupado): eso no se guarda, para reintentarlo luego.
    func letra(de cancion: Cancion) async throws -> Letra? {
        if let guardada = leerGuardada(cancion) {
            return guardada
        }
        let letra = try await buscar(cancion)
        guardar(letra, de: cancion)
        return letra
    }

    private func buscar(_ cancion: Cancion) async throws -> Letra? {
        if cancion.duracion > 0, let exacta = try await pedirExacta(cancion) {
            return exacta
        }
        if let letra = try await buscarParecida(titulo: cancion.titulo, cancion) {
            return letra
        }
        let limpio = Self.limpiar(cancion.titulo)
        if limpio != cancion.titulo, let letra = try await buscarParecida(titulo: limpio, cancion) {
            return letra
        }
        return nil
    }

    private func pedirExacta(_ cancion: Cancion) async throws -> Letra? {
        var url = URLComponents(url: Self.servidor.appendingPathComponent("get"), resolvingAgainstBaseURL: false)!
        url.queryItems = [
            URLQueryItem(name: "artist_name", value: cancion.artista),
            URLQueryItem(name: "track_name", value: cancion.titulo),
            URLQueryItem(name: "album_name", value: cancion.album),
            // LRCLIB acepta la versión cuya duración esté a ±2 s de esta.
            URLQueryItem(name: "duration", value: String(Int(cancion.duracion.rounded()))),
        ]
        guard let datos = try await pedir(url.url!) else { return nil }
        return Self.interpretar(try JSONDecoder().decode(Registro.self, from: datos))
    }

    private func buscarParecida(titulo: String, _ cancion: Cancion) async throws -> Letra? {
        var url = URLComponents(url: Self.servidor.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
        url.queryItems = [
            URLQueryItem(name: "track_name", value: titulo),
            URLQueryItem(name: "artist_name", value: cancion.artista),
        ]
        guard let datos = try await pedir(url.url!) else { return nil }
        let registros = try JSONDecoder().decode([Registro].self, from: datos)
        return Self.elegir(registros, duracion: cancion.duracion).flatMap(Self.interpretar)
    }

    /// Los datos de la respuesta, o nil si LRCLIB dice que no la tiene (404). Seguido contesta 503
    /// ("ocupado") y al segundo ya responde, así que antes de rendirse lo intenta dos veces más.
    private func pedir(_ url: URL) async throws -> Data? {
        for espera in [1, 2, 0] {
            let (datos, respuesta) = try await sesion.data(from: url)
            let codigo = (respuesta as? HTTPURLResponse)?.statusCode ?? 0
            if codigo == 404 { return nil }
            if codigo == 200 { return datos }
            guard codigo == 503 || codigo == 429, espera > 0 else { break }
            try await Task.sleep(nanoseconds: UInt64(espera) * 1_000_000_000)
        }
        throw URLError(.badServerResponse)
    }

    // MARK: - Elegir e interpretar

    struct Registro: Decodable {
        var duration: Double?
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?
    }

    /// De los resultados de una búsqueda, el que mejor sirve: entre los que duran casi lo mismo
    /// que la canción, uno sincronizado antes que uno simple, y el de duración más cercana.
    /// Si no se sabe la duración, cualquiera vale.
    static func elegir(_ registros: [Registro], duracion: Double) -> Registro? {
        let utiles = registros.filter { registro in
            guard interpretar(registro) != nil else { return false }
            guard duracion > 0, let d = registro.duration else { return true }
            return abs(d - duracion) <= tolerancia
        }
        return utiles.min { a, b in
            let sincA = !(a.syncedLyrics ?? "").isEmpty
            let sincB = !(b.syncedLyrics ?? "").isEmpty
            if sincA != sincB { return sincA }
            return abs((a.duration ?? 0) - duracion) < abs((b.duration ?? 0) - duracion)
        }
    }

    static func interpretar(_ registro: Registro) -> Letra? {
        if registro.instrumental == true {
            return .instrumental
        }
        if let lrc = registro.syncedLyrics {
            let lineas = LRC.leer(lrc)
            if !lineas.isEmpty { return .sincronizada(lineas) }
        }
        if let texto = registro.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !texto.isEmpty {
            return .simple(texto.components(separatedBy: .newlines))
        }
        return nil
    }

    /// El título sin lo que los servicios le agregan y que LRCLIB casi nunca tiene:
    /// "Yesterday - Remastered 2009" → "Yesterday", "Shape of You (feat. X)" → "Shape of You".
    static func limpiar(_ titulo: String) -> String {
        var limpio = titulo
        if let guion = limpio.range(of: " - ") {
            limpio = String(limpio[..<guion.lowerBound])
        }
        let agregados = ["feat", "ft.", "with ", "remaster", "live", "en vivo", "version", "versión", "mono", "stereo", "edit"]
        for (abre, cierra) in [("(", ")"), ("[", "]")] {
            while let inicio = limpio.range(of: abre, options: .backwards),
                  let fin = limpio.range(of: cierra, range: inicio.upperBound..<limpio.endIndex) {
                let dentro = limpio[inicio.upperBound..<fin.lowerBound].lowercased()
                guard agregados.contains(where: { dentro.contains($0) }) else { break }
                limpio.removeSubrange(inicio.lowerBound..<fin.upperBound)
            }
        }
        limpio = limpio.trimmingCharacters(in: .whitespaces)
        return limpio.isEmpty ? titulo : limpio
    }

    // MARK: - Guardado en disco

    private struct Guardada: Codable {
        var letra: Letra?
        var fecha: Date
    }

    /// Un nombre de archivo para la canción. La duración va redondeada a 5 s porque Spotify y
    /// Música pueden reportar la misma canción con una diferencia de un segundo.
    static func clave(_ cancion: Cancion) -> String {
        let texto = [cancion.artista, cancion.titulo, cancion.album].map { $0.lowercased() }.joined(separator: "\n")
            + "\n\(Int((cancion.duracion / 5).rounded()) * 5)"
        let resumen = SHA256.hash(data: Data(texto.utf8))
        return resumen.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func archivo(_ cancion: Cancion) -> URL {
        carpeta.appendingPathComponent(Self.clave(cancion) + ".json")
    }

    /// nil si no está guardada; .some(nil) si está guardada como "sin letra" y sigue vigente.
    private func leerGuardada(_ cancion: Cancion) -> Letra?? {
        guard let datos = try? Data(contentsOf: archivo(cancion)),
              let guardada = try? JSONDecoder().decode(Guardada.self, from: datos) else { return nil }
        if guardada.letra == nil, Date().timeIntervalSince(guardada.fecha) > Self.vigenciaSinLetra {
            return nil
        }
        return .some(guardada.letra)
    }

    private func guardar(_ letra: Letra?, de cancion: Cancion) {
        try? FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
        guard let datos = try? JSONEncoder().encode(Guardada(letra: letra, fecha: Date())) else { return }
        try? datos.write(to: archivo(cancion), options: .atomic)
    }
}
