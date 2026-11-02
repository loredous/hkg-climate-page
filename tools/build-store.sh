#!/bin/sh
# Build the zip for the NEMESIS Package Store: the bare package (NEMESIS.data at the root,
# descriptor format 1.1), the same bytes as packages/hkg.climate.page.zip inside the USB install
# zip. Upload it at portal.xwtk.cloud/nemesis, or install it with `nemesis install <zip>`.
# usage: tools/build-store.sh [output zip]   (default: dist/hkg-climate-page-store.zip)
# Needs dist/hkg-climate-page.zip (tools/build-package.sh).
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$ROOT/dist/hkg-climate-page-store.zip}
case "$OUT" in /*) ;; *) OUT=$(pwd)/$OUT ;; esac
PKG=$ROOT/dist/hkg-climate-page.zip
[ -s "$PKG" ] || { echo "build-store: missing $PKG (run tools/build-package.sh)" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")" && rm -f "$OUT"
unzip -p "$PKG" packages/hkg.climate.page.zip > "$OUT"
[ -s "$OUT" ] || { echo "build-store: no packages/hkg.climate.page.zip in $PKG" >&2; rm -f "$OUT"; exit 1; }
echo "$OUT"
