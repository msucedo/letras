import Foundation

// Qué texto va en la barra de menú y durante qué parte de la canción. La ventana de tiempo
// (inicio y fin) le dice a la marquesina a qué velocidad deslizar el texto si no cabe.
struct Segmento: Equatable {
    var texto: String
    var inicio: Double
    var fin: Double

    /// Segundos en que se muestran título y artista al empezar, aunque la letra empiece antes.
    static let presentacion = 5.0
    /// La ventana del título cuando no hay letra sincronizada: se desliza una vez y se queda.
    static let ventanaTitulo = 8.0

    static func titulo(_ cancion: Cancion) -> String {
        cancion.artista.isEmpty ? cancion.titulo : "\(cancion.titulo) — \(cancion.artista)"
    }

    /// El segmento en el segundo `posicion` (ya con el desfase de los ajustes). nil si solo va el icono.
    static func actual(cancion: Cancion?, letra: EstadoLetra, indice: Int?, posicion: Double) -> Segmento? {
        guard let cancion else { return nil }
        guard case .lista(.sincronizada(let lineas)) = letra, !lineas.isEmpty else {
            return Segmento(texto: titulo(cancion), inicio: 0, fin: ventanaTitulo)
        }
        guard let indice, posicion >= presentacion else {
            return Segmento(texto: titulo(cancion), inicio: 0, fin: max(lineas[0].tiempo, presentacion))
        }
        let linea = lineas[indice]
        guard !linea.texto.isEmpty else { return nil }
        let inicio = max(linea.tiempo, presentacion)
        let fin = indice + 1 < lineas.count ? lineas[indice + 1].tiempo : inicio + ventanaTitulo
        return Segmento(texto: linea.texto, inicio: inicio, fin: max(fin, inicio))
    }
}
