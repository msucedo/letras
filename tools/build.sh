#!/bin/sh
# Compila la app Universal (Apple Silicon + Intel) y la envuelve en build/Letras.app.
# Sin nada más la firma ad hoc, así que no hace falta certificado para compilarla.
#   SIGN_IDENTITY="Developer ID Application: …"  firma con esa identidad y hardened runtime
#   ENTITLEMENTS=signing/…entitlements           agrega esos entitlements a la firma
#   tools/build.sh --sandbox                      firma con Apple Development y sandbox, para
#                                                 probar en esta Mac lo que verá la App Store
set -e
cd "$(dirname "$0")/.."
if [ "$1" = "--sandbox" ]; then
    SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Development}"
    ENTITLEMENTS="${ENTITLEMENTS:-signing/Sandbox-dev.entitlements}"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
mkdir -p build
# swiftc directo: SwiftPM necesita Xcode, y con las command line tools basta para esto.
# Se compila una vez por arquitectura y lipo junta las dos en un solo ejecutable.
for ARCH in arm64 x86_64; do
    swiftc -O -parse-as-library -target "$ARCH-apple-macos13" Sources/*.swift -o "build/Letras-$ARCH"
done
lipo -create build/Letras-arm64 build/Letras-x86_64 -output build/Letras
APP="build/Letras.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/Letras "$APP/Contents/MacOS/Letras"
cp Resources/AppIcon.icns Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/Info.plist"
# La App Store rechaza el paquete si algún archivo trae atributos extendidos. El perfil de
# aprovisionamiento viene del navegador con com.apple.quarantine y com.apple.macl, y macOS se los
# pasa a sus copias aunque sean con cp -X (y macl no se puede borrar): con cat sale un archivo
# nuevo, sin ninguno. A lo demás se le quitan con xattr por si acaso.
if [ -n "$PROVISIONING_PROFILE" ]; then
    cat "$PROVISIONING_PROFILE" > "$APP/Contents/embedded.provisionprofile"
fi
xattr -cr "$APP"
if [ -n "$(xattr -r "$APP")" ]; then
    echo "Hay archivos con atributos extendidos dentro de $APP:" >&2
    xattr -r "$APP" >&2
    exit 1
fi
if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign --force --sign - "$APP"
else
    # Hardened runtime y sello de tiempo: los dos los pide la notarización.
    codesign --force --options runtime --timestamp \
        ${ENTITLEMENTS:+--entitlements "$ENTITLEMENTS"} --sign "$SIGN_IDENTITY" "$APP"
fi
echo "$APP"
