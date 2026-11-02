#!/bin/sh
# Host test for tools/build-store.sh and package/NEMESIS.data: the store zip is the bare package
# from the install zip, and its descriptor follows format 1.1 as the NEMESIS Package Store reads
# it (hmg_nemesis 04-Packages.md and 07-Submit-a-Package.md).
# usage: sh tests/store/run.sh   (needs dist/hkg-climate-page.zip from tools/build-package.sh)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FAILS=0
check() {
    _name=$1; shift
    if "$@" > /dev/null 2>&1; then echo "ok   $_name"; else echo "FAIL $_name"; FAILS=$((FAILS + 1)); fi
}

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
sh "$ROOT/tools/build-store.sh" "$T/store.zip" > /dev/null || { echo "FAIL build-store.sh"; exit 1; }
mkdir "$T/pkg" "$T/store"
(cd "$T/pkg" && unzip -q "$ROOT/dist/hkg-climate-page.zip")
(cd "$T/store" && unzip -q "$T/store.zip")
D=$T/store/NEMESIS.data

# value of <key> in [nemesis], without the surrounding quotes; empty when missing
get() {
    sed -n '/^\[nemesis\]$/,/^\[/p' "$D" | sed -n "s/^$1=//p" | sed 's/^"\(.*\)"$/\1/'
}
has() { sed -n '/^\[nemesis\]$/,/^\[/p' "$D" | grep -q "^$1="; }
dotted() { echo "$1" | grep -qE '^[0-9]+(\.[0-9]+)*$'; }
shorter() { [ "$(printf %s "$1" | wc -c)" -le "$2" ]; }
in_zip() { [ -f "$T/store/$1" ]; }

check "store zip is the package from the install zip" cmp -s "$T/store.zip" "$T/pkg/packages/hkg.climate.page.zip"
check "descriptor at the root is package/NEMESIS.data" cmp -s "$D" "$ROOT/package/NEMESIS.data"
check "descriptor format is 1.1"          test "$(get version)" = 1.1
check "id is hkg.climate.page"            test "$(get id)" = hkg.climate.page
check "name is set"                       test -n "$(get name)"
check "type is application"               test "$(get type)" = application
check "package-version is dotted numbers" dotted "$(get package-version)"
_ver=$(sed -n 's/.*android:versionName="\([^"]*\)".*/\1/p' "$ROOT/app/AndroidManifest.xml")
check "package-version is the app's versionName" test "$(get package-version)" = "$_ver"
check "short-desc is set"                 test -n "$(get short-desc)"
check "short-desc is at most 64 characters" shorter "$(get short-desc)" 64
check "detailed-desc is at most 256 characters" shorter "$(get detailed-desc)" 256
check "os is the 2023 US Ioniq 5 on 260507" test "$(get os)" = 'NEEV23.USA.*.260507'
check "models is set"                     test -n "$(get models)"
check "depends is there"                  has depends
check "no N/A placeholders"               sh -c '! grep -q "=N/A$" "$1"' sh "$D"
for _k in preinstall postinstall preuninstall; do
    check "$_k script is in the zip"      in_zip "$(get $_k)"
done
_apk=$(sed -n '/^\[app\.[0-9]*\]$/,/^\[/p' "$D" | sed -n 's/^path=//p')
check "the app's apk is in the zip"       in_zip "$_apk"
sh "$ROOT/tools/build-store.sh" "$T/store2.zip" > /dev/null
check "same inputs give the same zip"     cmp -s "$T/store.zip" "$T/store2.zip"

if [ $FAILS -ne 0 ]; then echo "$FAILS check(s) failed"; exit 1; fi
echo "all checks passed"
