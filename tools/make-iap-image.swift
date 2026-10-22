import AppKit

// Dibuja la imagen de la compra "Invítame un café ☕" que pide App Store Connect: 1024×1024, sin
// transparencia ni esquinas redondeadas, y sin capturas. Es el icono de la app con una insignia de
// café, sobre un fondo oscuro con los colores del icono y notas alrededor. Se corre una vez:
//   swiftc tools/make-iap-image.swift -o build/make-iap-image && build/make-iap-image appstore/iap-cafe.png

let destino = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "appstore/iap-cafe.png"
guard let icono = NSImage(contentsOfFile: "Resources/AppIcon.icns") else { fatalError("no pude leer Resources/AppIcon.icns") }

let lado = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: lado, pixelsHigh: lado,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let s = CGFloat(lado)
let centro = NSPoint(x: s / 2, y: s / 2)

// Fondo oscuro con un brillo rosa-morado (los colores del icono) detrás del centro.
NSColor(srgbRed: 0.07, green: 0.05, blue: 0.10, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: s, height: s).fill()
NSGradient(starting: NSColor(srgbRed: 0.80, green: 0.30, blue: 0.65, alpha: 0.65),
           ending: NSColor(srgbRed: 0.40, green: 0.18, blue: 0.75, alpha: 0))!
    .draw(fromCenter: centro, radius: 0, toCenter: centro, radius: s * 0.6, options: [])

// Notas alrededor, tenues.
let notas: [(String, CGFloat, CGFloat, CGFloat)] = [
    ("♪", 150, 780, 150), ("♫", 860, 190, 170), ("♪", 120, 260, 110),
    ("♫", 880, 820, 120), ("♪", 520, 110, 90), ("♪", 470, 930, 80),
]
for (nota, x, y, tam) in notas {
    let texto = NSAttributedString(string: nota, attributes: [
        .font: NSFont.systemFont(ofSize: tam, weight: .bold),
        .foregroundColor: NSColor.white.withAlphaComponent(0.18),
    ])
    let t = texto.size()
    texto.draw(at: NSPoint(x: x - t.width / 2, y: y - t.height / 2))
}

// El icono al centro, con sombra. El .icns trae el margen de la retícula de macOS (100 de 1024).
let tamIcono: CGFloat = 700
let marcoIcono = NSRect(x: (s - tamIcono) / 2, y: (s - tamIcono) / 2, width: tamIcono, height: tamIcono)
NSGraphicsContext.saveGraphicsState()
let sombra = NSShadow()
sombra.shadowOffset = NSSize(width: 0, height: -18)
sombra.shadowBlurRadius = 50
sombra.shadowColor = NSColor.black.withAlphaComponent(0.5)
sombra.set()
icono.draw(in: marcoIcono, from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

// La insignia del café, abajo a la derecha del icono: un círculo crema con la taza.
let radio: CGFloat = 125
let insignia = NSPoint(x: marcoIcono.maxX - 150, y: marcoIcono.minY + 150)
NSGraphicsContext.saveGraphicsState()
let sombraInsignia = NSShadow()
sombraInsignia.shadowOffset = NSSize(width: 0, height: -10)
sombraInsignia.shadowBlurRadius = 30
sombraInsignia.shadowColor = NSColor.black.withAlphaComponent(0.45)
sombraInsignia.set()
NSColor(srgbRed: 0.07, green: 0.05, blue: 0.10, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: insignia.x - radio - 12, y: insignia.y - radio - 12,
                            width: 2 * (radio + 12), height: 2 * (radio + 12))).fill()
NSGraphicsContext.restoreGraphicsState()
let circulo = NSBezierPath(ovalIn: NSRect(x: insignia.x - radio, y: insignia.y - radio, width: 2 * radio, height: 2 * radio))
NSGradient(starting: NSColor(srgbRed: 1.00, green: 0.93, blue: 0.80, alpha: 1),
           ending: NSColor(srgbRed: 0.93, green: 0.78, blue: 0.58, alpha: 1))!.draw(in: circulo, angle: -90)
let taza = NSAttributedString(string: "☕", attributes: [.font: NSFont.systemFont(ofSize: 150)])
let tamTaza = taza.size()
taza.draw(at: NSPoint(x: insignia.x - tamTaza.width / 2, y: insignia.y - tamTaza.height / 2 + 4))

NSGraphicsContext.restoreGraphicsState()
try FileManager.default.createDirectory(atPath: (destino as NSString).deletingLastPathComponent,
                                        withIntermediateDirectories: true)
// AppKit no dibuja en un mapa de bits sin canal alfa, así que se dibujó con alfa (todo opaco) y aquí
// se copia a uno sin alfa: App Store Connect rechaza la imagen si trae transparencia.
let opaco = CGContext(data: nil, width: lado, height: lado, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
opaco.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: lado, height: lado))
try NSBitmapImageRep(cgImage: opaco.makeImage()!).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: destino))
print(destino)
