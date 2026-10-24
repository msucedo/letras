#!/bin/sh
# Busca en Sources/ los textos de la interfaz (Text, Button, Toggle, Picker, .help, mensaje y
# String(localized:)) y avisa de los que no tienen traducción en en.lproj/Localizable.strings.
# Las interpolaciones \(…) se cuentan como %@, igual que hace SwiftUI con un String.
set -e
cd "$(dirname "$0")/.."
TRADUCCIONES=Resources/en.lproj/Localizable.strings
plutil -lint -s Resources/*.lproj/*.strings
CLAVES=$(plutil -convert json -o - "$TRADUCCIONES")
FALTAN=$(perl -CSD -ne '
    while (/(?:\bText|\bButton|\bToggle|\bPicker|\.help|\bmensaje|String\(localized:)\(?\s*"((?:[^"\\]|\\\((?:[^()]|\([^()]*\))*\))*)"/g) {
        my $t = $1;
        $t =~ s/\\\((?:[^()]|\([^()]*\))*\)/%@/g;
        print "$t\n" if $t =~ /\p{L}/;
    }' Sources/*.swift | sort -u | while IFS= read -r texto; do
        printf "%s" "$CLAVES" | TEXTO="$texto" perl -MJSON::PP -0777 -ne '
            exit(exists JSON::PP->new->decode($_)->{$ENV{TEXTO}} ? 0 : 1)' || echo "$texto"
    done)
# Nombres propios que no se traducen.
FALTAN=$(printf "%s\n" "$FALTAN" | grep -vx -e 'Letras' -e '' || true)
if [ -n "$FALTAN" ]; then
    echo "Textos sin traducción en $TRADUCCIONES:" >&2
    printf "%s\n" "$FALTAN" >&2
    exit 1
fi
echo "Traducciones: completas"
