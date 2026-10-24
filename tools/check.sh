#!/bin/sh
# Compila y corre las pruebas que no necesitan interfaz ni internet: LRC, elegir resultados de
# LRCLIB, limpiar títulos, la clave del guardado y qué va en la barra de menú. Al final revisa que
# todos los textos de la interfaz tengan traducción al inglés.
set -e
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -parse-as-library tests/letra-check.swift Sources/LRC.swift Sources/LRCLIB.swift Sources/Reproductor.swift Sources/Monitor.swift Sources/Segmento.swift Sources/Ajustes.swift -o build/letra-check
build/letra-check
tools/check-traducciones.sh
