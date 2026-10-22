import AppKit

// Dibuja el icono de la app: una nota musical y renglones de letra, con la línea que se canta
// resaltada, sobre un fondo morado, con la forma de los iconos de macOS. Se corre una sola vez y
// el .icns resultante se guarda en el repo:
//   swiftc tools/make-icon.swift -o build/make-icon && build/make-icon build/AppIcon.iconset
//   iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

let destino = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset"
try FileManager.default.createDirectory(atPath: destino, withIntermediateDirectories: true)

func dibujar(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024

    // La retícula de iconos de macOS: un cuadro de 824 de 1024, con esquinas de unos 185.
    let caja = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let forma = NSBezierPath(roundedRect: caja, xRadius: 185 * s, yRadius: 185 * s)
    let claro = NSColor(srgbRed: 0.98, green: 0.36, blue: 0.55, alpha: 1)
    let oscuro = NSColor(srgbRed: 0.40, green: 0.18, blue: 0.75, alpha: 1)
    NSGradient(starting: claro, ending: oscuro)!.draw(in: forma, angle: -90)

    // Tres renglones de letra; el de en medio, el que se canta, más ancho y blanco del todo.
    let renglones: [(y: CGFloat, ancho: CGFloat, alfa: CGFloat)] = [(600, 420, 0.45), (480, 560, 1), (360, 360, 0.45)]
    for renglon in renglones {
        NSColor.white.withAlphaComponent(renglon.alfa).setFill()
        let barra = NSRect(x: 230 * s, y: renglon.y * s, width: renglon.ancho * s, height: 64 * s)
        NSBezierPath(roundedRect: barra, xRadius: 32 * s, yRadius: 32 * s).fill()
    }

    // La nota, arriba a la derecha, sin tapar los renglones.
    let nota = NSAttributedString(string: "♪", attributes: [
        .font: NSFont.systemFont(ofSize: 300 * s, weight: .bold),
        .foregroundColor: NSColor.white,
    ])
    let tam = nota.size()
    nota.draw(at: NSPoint(x: 820 * s - tam.width / 2, y: 690 * s - tam.height / 2))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// Los tamaños que pide iconutil: cada uno a 1x y a 2x.
for base in [16, 32, 128, 256, 512] {
    for escala in [1, 2] {
        let nombre = escala == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try dibujar(base * escala).write(to: URL(fileURLWithPath: destino).appendingPathComponent(nombre))
    }
}
print(destino)
