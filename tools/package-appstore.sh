#!/bin/sh
# Arma dist/Letras-<versión>-AppStore.pkg para la Mac App Store: la app con sandbox, el perfil
# de aprovisionamiento adentro, firmada con Apple Distribution, en un instalador firmado con
# Mac Installer Distribution. Se sube con la app Transporter.
# Cada subida necesita un CFBundleVersion nuevo en Info.plist, aunque la versión no cambie.
# Es la única versión con la compra del café (TIENDA=1).
set -e
cd "$(dirname "$0")/.."
# El perfil de la App Store, con el nombre que traiga al descargarlo o con el de la guía.
PERFIL="${PERFIL:-signing/Letras_AppStore.provisionprofile}"
if [ ! -f "$PERFIL" ] && [ -f signing/Letras.provisionprofile ]; then
    PERFIL="signing/Letras.provisionprofile"
fi
if [ ! -f "$PERFIL" ]; then
    echo "Falta $PERFIL: descárgalo de developer.apple.com > Profiles (tipo Mac App Store, para com.msucedo.letras)." >&2
    exit 1
fi
tools/check.sh
TIENDA=1 SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Distribution: Mario Saucedo (M6JLQVH4Y7)}" \
ENTITLEMENTS=signing/AppStore.entitlements PROVISIONING_PROFILE="$PERFIL" tools/build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
PKG="dist/Letras-$VERSION-AppStore.pkg"
mkdir -p dist
productbuild --component build/Letras.app /Applications \
    --sign "${INSTALLER_IDENTITY:-3rd Party Mac Developer Installer: Mario Saucedo (M6JLQVH4Y7)}" "$PKG"
pkgutil --check-signature "$PKG"
echo "$PKG"
