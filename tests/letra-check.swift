import Foundation

// Comprueba lo que no necesita interfaz ni internet: leer LRC, encontrar la línea de cada
// segundo, elegir entre resultados de LRCLIB, limpiar títulos y la clave del guardado.
@main
struct LetraCheck {
    static var fallos = 0

    static func comprobar<T: Equatable>(_ nombre: String, _ obtenido: T, _ esperado: T) {
        let ok = obtenido == esperado
        print((ok ? "ok    " : "FALLA ") + nombre + (ok ? "" : ": \(obtenido) ≠ \(esperado)"))
        if !ok { fallos += 1 }
    }

    static func main() {
        // LRC
        let lrc = """
        [ar:Caifanes]
        [ti:La Negra Tomasa]
        [00:21.44] Estoy tan enamorado
        [00:27.68]Que cuando se va
        [00:12.00][01:30.5]Coro
        [00:40.00]
        [01:02:50] Con dos puntos
        sin marca, se ignora
        """
        let lineas = LRC.leer(lrc)
        comprobar("número de líneas", lineas.count, 6)
        comprobar("ordenadas por tiempo", lineas.map(\.tiempo), [12, 21.44, 27.68, 40, 62.5, 90.5])
        comprobar("texto sin espacios", lineas[1].texto, "Estoy tan enamorado")
        comprobar("línea repetida", lineas[5].texto, "Coro")
        comprobar("línea vacía se conserva", lineas[3].texto, "")
        comprobar("offset adelanta", LRC.leer("[offset:500]\n[00:10.00]a").map(\.tiempo), [9.5])
        comprobar("marca inválida", LRC.segundos("ar:Caifanes"), nil)
        comprobar("segundos ≥ 60 inválidos", LRC.segundos("01:75.00"), nil)

        // Línea en cada segundo
        comprobar("antes de la primera", LRC.indice(en: 5, de: lineas), nil)
        comprobar("justo al empezar", LRC.indice(en: 12, de: lineas), 0)
        comprobar("entre dos", LRC.indice(en: 25, de: lineas), 1)
        comprobar("después de la última", LRC.indice(en: 500, de: lineas), 5)
        comprobar("letra vacía", LRC.indice(en: 5, de: []), nil)

        // Elegir resultado de búsqueda
        let sinc = LRCLIB.Registro(duration: 230, instrumental: false, plainLyrics: "a", syncedLyrics: "[00:01.00]a")
        let simpleCerca = LRCLIB.Registro(duration: 228, instrumental: false, plainLyrics: "b", syncedLyrics: nil)
        let sincLejos = LRCLIB.Registro(duration: 300, instrumental: false, plainLyrics: "c", syncedLyrics: "[00:01.00]c")
        let vacio = LRCLIB.Registro(duration: 228, instrumental: false, plainLyrics: nil, syncedLyrics: nil)
        comprobar("prefiere sincronizada", LRCLIB.elegir([simpleCerca, sinc, sincLejos], duracion: 228)?.plainLyrics, "a")
        comprobar("descarta otra versión", LRCLIB.elegir([sincLejos], duracion: 228)?.plainLyrics, nil)
        comprobar("ignora registros vacíos", LRCLIB.elegir([vacio, simpleCerca], duracion: 228)?.plainLyrics, "b")
        comprobar("sin duración, cualquiera", LRCLIB.elegir([sincLejos], duracion: 0)?.plainLyrics, "c")
        comprobar("instrumental", LRCLIB.interpretar(LRCLIB.Registro(duration: 1, instrumental: true)), .instrumental)
        comprobar("simple en líneas", LRCLIB.interpretar(simpleCerca), .simple(["b"]))

        // Limpiar títulos
        comprobar("remaster", LRCLIB.limpiar("Yesterday - Remastered 2009"), "Yesterday")
        comprobar("feat", LRCLIB.limpiar("Shape of You (feat. Someone)"), "Shape of You")
        comprobar("en vivo", LRCLIB.limpiar("Afuera [En Vivo]"), "Afuera")
        comprobar("paréntesis propio", LRCLIB.limpiar("Hey (Nothing Else)"), "Hey (Nothing Else)")
        comprobar("sin cambios", LRCLIB.limpiar("La Negra Tomasa"), "La Negra Tomasa")

        // Clave del guardado
        let a = Cancion(titulo: "La Negra Tomasa", artista: "Caifanes", album: "Caifanes", duracion: 456.6)
        var b = a
        b.duracion = 457.4
        b.titulo = "la negra tomasa"
        comprobar("clave ignora mayúsculas y un segundo", LRCLIB.clave(a), LRCLIB.clave(b))
        b.album = "Historia"
        comprobar("clave distingue álbum", LRCLIB.clave(a) == LRCLIB.clave(b), false)

        print(fallos == 0 ? "ok" : "\(fallos) fallos")
        exit(fallos == 0 ? 0 : 1)
    }
}
