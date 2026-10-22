#!/bin/sh
# Arma dist/Letras-<versión>.dmg para GitHub Releases: la app firmada con Developer ID y un
# acceso a Aplicaciones para instalarla arrastrando. Luego lo manda a notarizar con Apple y le
# engrapa el ticket, para que se abra con doble clic, sin avisos de Gatekeeper.
# La primera vez guarda las credenciales en el Llavero (ver appstore/PUBLICAR.md):
#   xcrun notarytool store-credentials letras-notary --apple-id <correo> --team-id M6JLQVH4Y7
set -e
cd "$(dirname "$0")/.."
IDENTIDAD="${SIGN_IDENTITY:-Developer ID Application: Mario Saucedo (M6JLQVH4Y7)}"
PERFIL_NOTARIO="${NOTARY_PROFILE:-letras-notary}"
tools/check.sh
# Con hardened runtime, mandar Apple Events a Spotify y Música necesita su entitlement.
SIGN_IDENTITY="$IDENTIDAD" ENTITLEMENTS="${ENTITLEMENTS:-signing/DeveloperID.entitlements}" tools/build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
DMG="dist/Letras-$VERSION.dmg"
STAGE="build/dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE" dist
# ditto conserva la firma y los atributos del bundle tal cual.
ditto build/Letras.app "$STAGE/Letras.app"
ln -s /Applications "$STAGE/Aplicaciones"
hdiutil create -volname "Letras" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null
codesign --force --timestamp --sign "$IDENTIDAD" "$DMG"
# Apple revisa el DMG y la app de adentro; --wait espera el veredicto (unos minutos).
xcrun notarytool submit "$DMG" --keychain-profile "$PERFIL_NOTARIO" --wait
xcrun stapler staple "$DMG"
# Lo mismo que hará Gatekeeper en la Mac de quien lo descargue.
spctl -a -t open --context context:primary-signature -vv "$DMG"
echo "$DMG"
