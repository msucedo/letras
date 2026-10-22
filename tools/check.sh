#!/bin/sh
# Compila y corre las pruebas que no necesitan interfaz ni internet: LRC, elegir resultados de
# LRCLIB, limpiar títulos y la clave del guardado.
set -e
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -parse-as-library tests/letra-check.swift Sources/LRC.swift Sources/LRCLIB.swift Sources/Reproductor.swift -o build/letra-check
build/letra-check
