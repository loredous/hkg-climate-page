#!/bin/sh
# Host check of the app build: builds the signed APK and asserts its manifest facts, its v1
# signature, a few calls its code must make, that no stock stub class is packaged, and that the
# only send-path references are the approved calls: the seat, steering-wheel and eco setters inside
# UsmSeatCalls and setFrontClimateControl inside DatcClimateCalls, reached only through
# CheckedSeatSender.send (seats) or CheckedCabinSender and StockCabinCalls (presets), and
# CheckedCabinSender's own sending methods reached only from PresetRunner.
# usage: sh tests/app/check-app.sh   (prints one line per check; exit 1 if any check fails)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
eval "$("$ROOT/tools/toolchain.sh" env)"
cd "$ROOT"
FAILS=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# fails <command...>: succeeds when the command fails
fails() { ! "$@"; }

check() {
    _name=$1; shift
    if "$@" > /dev/null 2>&1; then echo "ok   $_name"; else echo "FAIL $_name"; FAILS=$((FAILS + 1)); fi
}

APK=build/app/hkgclimate.apk
rm -f "$APK"
check "build-app.sh builds the apk" sh tools/build-app.sh
check "apk exists" [ -s "$APK" ]

if [ -s "$APK" ]; then
    "$BUILD_TOOLS/aapt" dump badging "$APK" > "$TMP/badging" 2>&1
    "$BUILD_TOOLS/aapt" dump xmltree "$APK" AndroidManifest.xml > "$TMP/manifest.txt" 2>&1
    unzip -p "$APK" classes.dex > "$TMP/classes.dex" 2> /dev/null
    "$BUILD_TOOLS/dexdump" "$TMP/classes.dex" > "$TMP/dex.txt" 2>&1
    # -d lists the code, which is where references to other classes show up
    "$BUILD_TOOLS/dexdump" -d "$TMP/classes.dex" > "$TMP/dexcode.txt" 2>&1
    unzip -Z1 "$APK" > "$TMP/entries" 2>&1
fi
: >> "$TMP/manifest.txt"; : >> "$TMP/badging"; : >> "$TMP/dex.txt"; : >> "$TMP/dexcode.txt"; : >> "$TMP/entries"

# has_ref <dexdump -d output> <class>: the code refers to the class, e.g. Lcom/hkmc/usm/
has_ref() { grep -q "$2" "$1"; }
# method_has_ref <dexdump -d output> <class.method:> <ref>: that method's code refers to <ref>
method_has_ref() {
    awk -v m="$2" 'index($0, "] " m) { on = 1; next } on && /\|\[/ { on = 0 } on' "$1" | grep -q "$3"
}
method_lacks_ref() { ! method_has_ref "$@"; }

# usm_refs_ok <dexdump -d output>: every Lcom/hkmc/usm/ reference is inside
# hkgclimate.app.UsmSeatCalls (in the code of its methods, or its own declarations such as the
# cached manager field), names no stock class but USMManager, and every USMManager member it names
# is one of the approved ones: the constructor, the two seat setters, the steering-wheel and eco
# setters and their two getters. Prints the offending lines; status 1 when there are any.
usm_refs_ok() {
    awk -v cls_ok="'Lhkgclimate/app/UsmSeatCalls;'" -v meth_ok="hkgclimate.app.UsmSeatCalls." '
        /Class descriptor/ { incls = index($0, cls_ok) > 0; meth = ""; next }
        /\|\[[0-9a-f]+\] / { m = $0; sub(/.*\|\[[0-9a-f]+\] /, "", m); meth = m }
        !index($0, "Lcom/hkmc/usm/") { next }
        {
            bad = !incls
            # a code line: it must be in one of UsmSeatCalls own methods
            if (index($0, "|") && index(meth, meth_ok) != 1) bad = 1
            rest = $0
            while ((i = index(rest, "Lcom/hkmc/usm/")) > 0) {
                rest = substr(rest, i)
                j = index(rest, ";")
                if (j == 0) { bad = 1; break }
                if (substr(rest, 1, j) != "Lcom/hkmc/usm/USMManager;") bad = 1
                rest = substr(rest, j + 1)
                if (substr(rest, 1, 1) == ".") {
                    member = rest; sub(/[ ,].*/, "", member)
                    if (member != ".<init>:(Landroid/content/Context;)V" \
                        && member != ".setFrontSeatHeatDrvStep:(I)V" \
                        && member != ".setFrontSeatHeatAstStep:(I)V" \
                        && member != ".setSWRC_SteeringwheelWarmerSet:(I)V" \
                        && member != ".getSWRC_SteeringwheelHeatIndStep2:()I" \
                        && member != ".setClimateControlECOMode:(I)V" \
                        && member != ".getClimateControlECOMode:()I") bad = 1
                }
            }
            if (bad) { print; n++ }
        }
        END { exit n > 0 }' "$1"
}
# usm_new_only_in <dexdump -d output> <class.method:>: USMManager is constructed somewhere, and
# only in the code of that one method
usm_new_only_in() {
    awk -v want="$2" '
        /Class descriptor/ { meth = "" }
        /\|\[[0-9a-f]+\] / { m = $0; sub(/.*\|\[[0-9a-f]+\] /, "", m); meth = m }
        index($0, "Lcom/hkmc/usm/USMManager;.<init>") { n++; if (index(meth, want) != 1) { print; bad++ } }
        END { exit !(n > 0 && bad == 0) }' "$1"
}
# no_typed_catch_in <dexdump -d output> <class descriptor>: the class's code catches no exception
# type (a finally block, listed as <any>, rethrows and is allowed)
no_typed_catch_in() {
    awk -v cls="'$2'" '
        /Class descriptor/ { incls = index($0, cls) > 0; next }
        incls && /^ +L[^ ]*; -> 0x/ { print; n++ }
        END { exit n > 0 }' "$1"
}
# seat_calls_only_in <dexdump -d output> <class.method:>: the code calls the seat setters
# (UsmCalls.driver/passenger, or UsmSeatCalls.driver/passenger directly) somewhere, and only in
# the code of that one method. Prints the offending lines.
seat_calls_only_in() {
    awk -v want="$2" '
        /Class descriptor/ { meth = "" }
        /\|\[[0-9a-f]+\] / { m = $0; sub(/.*\|\[[0-9a-f]+\] /, "", m); meth = m }
        index($0, "Lhkgclimate/core/UsmCalls;.driver:") || index($0, "Lhkgclimate/core/UsmCalls;.passenger:") \
            || index($0, "Lhkgclimate/app/UsmSeatCalls;.driver:") || index($0, "Lhkgclimate/app/UsmSeatCalls;.passenger:") {
            n++; if (index(meth, want) != 1) { print; bad++ }
        }
        END { exit !(n > 0 && bad == 0) }' "$1"
}
# refs_only_in <dexdump -d output> <method prefix[|method prefix...]> <ref>...: the code refers to at least one of
# the refs, and every reference is in the code of a method whose name starts with the prefix (a
# whole class "pkg.Class." or one method "pkg.Class.method:"). Prints the offending lines.
refs_only_in() {
    _f=$1; _want=$2; shift 2
    awk -v want="$_want" -v refs="$*" '
        BEGIN { nr = split(refs, r, " "); nw = split(want, w, "|") }
        /Class descriptor/ { meth = "" }
        /\|\[[0-9a-f]+\] / { m = $0; sub(/.*\|\[[0-9a-f]+\] /, "", m); meth = m }
        {
            hit = 0
            for (i = 1; i <= nr; i++) if (index($0, r[i])) hit = 1
            if (hit) {
                n++; ok = 0
                for (j = 1; j <= nw; j++) if (index(meth, w[j]) == 1) ok = 1
                if (!ok) { print; bad++ }
            }
        }
        END { exit !(n > 0 && bad == 0) }' "$_f"
}
# code_lacks_ref <dexdump -d output> <method prefix> <ref>: the listing has code in methods whose
# name starts with the prefix, and none of that code refers to <ref>. Prints the offending lines.
code_lacks_ref() {
    awk -v want="$2" -v ref="$3" '
        /Class descriptor/ { meth = "" }
        /\|\[[0-9a-f]+\] / { m = $0; sub(/.*\|\[[0-9a-f]+\] /, "", m); meth = m; if (index(meth, want) == 1) seen++; next }
        index(meth, want) == 1 && index($0, ref) { print; bad++ }
        END { exit !(seen > 0 && bad == 0) }' "$1"
}
# datc_refs_ok <dexdump -d output>: every Lcom/hkmc/datc/DATCManager; member the code names is one
# of addTemperatureListener, removeTemperatureListener, getTemperatureUnit, getVRClimateStatus,
# getDriverOnlyValue and setFrontClimateControl (no constructor, no field, nothing else). Prints
# the offending lines; status 1 when there are any.
datc_refs_ok() {
    awk '
        !index($0, "Lcom/hkmc/datc/DATCManager;.") { next }
        {
            rest = $0; bad = 0
            while ((i = index(rest, "Lcom/hkmc/datc/DATCManager;.")) > 0) {
                rest = substr(rest, i + length("Lcom/hkmc/datc/DATCManager;."))
                member = rest; sub(/:.*/, "", member)
                if (member != "addTemperatureListener" && member != "removeTemperatureListener" \
                    && member != "getTemperatureUnit" && member != "getVRClimateStatus" \
                    && member != "getDriverOnlyValue" && member != "setFrontClimateControl") bad = 1
            }
            if (bad) { print; n++ }
        }
        END { exit n > 0 }' "$1"
}
# the preset fences (refs_only_in): the cabin calls, reached only through CheckedCabinSender
CABIN_REFS='Lhkgclimate/core/CabinCalls;.climate: Lhkgclimate/core/CabinCalls;.wheel: Lhkgclimate/core/CabinCalls;.eco: Lhkgclimate/app/StockCabinCalls;.climate: Lhkgclimate/app/StockCabinCalls;.wheel: Lhkgclimate/app/StockCabinCalls;.eco:'
CABIN_FROM='hkgclimate.core.CheckedCabinSender.'
# CheckedCabinSender's three sending methods, reached only from the PresetRunner
SENDER_REFS='Lhkgclimate/core/CheckedCabinSender;.climate: Lhkgclimate/core/CheckedCabinSender;.eco: Lhkgclimate/core/CheckedCabinSender;.wheelPress:'
SENDER_FROM='hkgclimate.core.PresetRunner.'
# the two stock-call classes' cabin setters, reached only through StockCabinCalls
STOCK_REFS='Lhkgclimate/app/DatcClimateCalls;.send: Lhkgclimate/app/UsmSeatCalls;.wheel: Lhkgclimate/app/UsmSeatCalls;.eco:'
STOCK_FROM='hkgclimate.app.StockCabinCalls.'
# dex_has_string <classes.dex> <string>: the dex string table holds exactly this string
dex_has_string() {
    "$PY" -I - "$1" "$2" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
if d[:4] != b"dex\n":
    sys.exit(2)
size, off = struct.unpack_from("<II", d, 0x38)
for i in range(size):
    (p,) = struct.unpack_from("<I", d, off + 4 * i)
    while d[p] & 0x80:
        p += 1
    p += 1
    if d[p:d.index(b"\0", p)].decode("utf-8", "replace") == sys.argv[2]:
        sys.exit(0)
sys.exit(1)
PY
}
# dex_lacks_string <classes.dex> <string>: the table lacks it (a dex that cannot be read fails too)
dex_lacks_string() { dex_has_string "$@"; [ $? -eq 1 ]; }
# usm_strings_ok <classes.dex>: no string in the dex names the stock seat service other than the
# one allowed type descriptor Lcom/hkmc/usm/USMManager; (a service looked up by name, or a class
# loaded by name, would otherwise pass the code checks)
usm_strings_ok() {
    "$PY" -I - "$1" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
if d[:4] != b"dex\n":
    sys.exit(1)
size, off = struct.unpack_from("<II", d, 0x38)
bad = 0
for i in range(size):
    (p,) = struct.unpack_from("<I", d, off + 4 * i)
    while d[p] & 0x80:
        p += 1
    p += 1
    s = d[p:d.index(b"\0", p)].decode("utf-8", "replace")
    low = s.lower()
    if any(k in low for k in ("hkmc/usm", "hkmc.usm", "micom/usm", "micom.usm")) \
            and s != "Lcom/hkmc/usm/USMManager;":
        print(s)
        bad += 1
sys.exit(1 if bad else 0)
PY
}

# self-tests of has_ref, usm_refs_ok and the other code checks on throwaway dexes. The scratch sources (a com.hkmc.usm
# USMManager with one extra member, and a com.hkmc.usm.Seat) live only in $TMP; they are never in
# the repo or the APK.
ST=$TMP/st
mkdir -p "$ST/s/com/hkmc/usm" "$ST/s/com/hkmc/datc" "$ST/so"
cat > "$ST/s/com/hkmc/usm/Seat.java" <<'JAVA'
package com.hkmc.usm;
public class Seat { public void send(int v) { } }
JAVA
cat > "$ST/s/com/hkmc/usm/USMManager.java" <<'JAVA'
package com.hkmc.usm;
public class USMManager {
    public USMManager(android.content.Context c) { }
    public void setFrontSeatHeatDrvStep(int v) { }
    public void setFrontSeatHeatAstStep(int v) { }
    public void setSWRC_SteeringwheelWarmerSet(int v) { }
    public int getSWRC_SteeringwheelHeatIndStep2() { return 0; }
    public void setClimateControlECOMode(int v) { }
    public int getClimateControlECOMode() { return 0; }
    public void setOther(int v) { }
}
JAVA
# a scratch DATCManager with the allowed members, a constructor and two members we never name
cat > "$ST/s/com/hkmc/datc/DATCManager.java" <<'JAVA'
package com.hkmc.datc;
public class DATCManager {
    public DATCManager(android.content.Context c) { }
    public void setFrontClimateControl(int flag, int value) { }
    public float getVRClimateStatus(int flag) { return 0; }
    public int getDriverOnlyValue() { return 0; }
    public int getTemperatureUnit() { return 0; }
    public void setVRClimateStatus(int flag, int value) { }
    public int getClimateInfo(int i) { return 0; }
}
JAVA
javac --release 8 -cp "$ANDROID_JAR" -d "$ST/so" "$ST/s/com/hkmc/usm/Seat.java" \
    "$ST/s/com/hkmc/usm/USMManager.java" "$ST/s/com/hkmc/datc/DATCManager.java" > /dev/null 2>&1
# scratch copies of our own core types for the version 1.2 fences (seat off), compiled next to
# the stubs so a scratch hkgclimate.app class can name them; never in the repo or the APK
mkdir -p "$ST/s/hkgclimate/core"
cat > "$ST/s/hkgclimate/core/SeatCommander.java" <<'JAVA'
package hkgclimate.core;
public interface SeatCommander { void set(Object seat, int value); }
JAVA
cat > "$ST/s/hkgclimate/core/CheckedSeatSender.java" <<'JAVA'
package hkgclimate.core;
public class CheckedSeatSender implements SeatCommander { public void set(Object seat, int value) { } }
JAVA
cat > "$ST/s/hkgclimate/core/ClimateCore.java" <<'JAVA'
package hkgclimate.core;
public class ClimateCore { public boolean onSeatOff(Object seat, long id) { return false; } }
JAVA
javac --release 8 -d "$ST/so" "$ST/s/hkgclimate/core/SeatCommander.java" \
    "$ST/s/hkgclimate/core/CheckedSeatSender.java" "$ST/s/hkgclimate/core/ClimateCore.java" > /dev/null 2>&1
# scratch_dex <name> <file base name> <java source>: compiles one source against the scratch
# stubs, dexes it and writes its dexdump -d listing to $ST/<name>/code.txt (empty on any failure)
scratch_dex() {
    _d=$ST/$1; mkdir -p "$_d/src" "$_d/o"
    _f=$_d/src/$2.java
    echo "$3" > "$_f"
    # shellcheck disable=SC2046 # one path per word; none contain spaces
    if javac -source 8 -target 8 -Xlint:-options -bootclasspath "$ANDROID_JAR" -cp "$ST/so" \
            -d "$_d/o" "$_f" > /dev/null 2>&1 \
        && "$BUILD_TOOLS/d8" --min-api 19 --lib "$ANDROID_JAR" --classpath "$ST/so" --output "$_d" \
            $(find "$_d/o" -name '*.class') > /dev/null 2>&1 \
        && "$BUILD_TOOLS/dexdump" -d "$_d/classes.dex" > "$_d/code.txt" 2>&1; then
        :
    else
        : > "$_d/code.txt"
    fi
}
scratch_dex caller Caller 'public class Caller { void go() { new com.hkmc.usm.Seat().send(3); } }'
scratch_dex other Other 'public class Other { void go(android.content.Context c) { new com.hkmc.usm.USMManager(c).setFrontSeatHeatDrvStep(3); } }'
scratch_dex good UsmSeatCalls 'package hkgclimate.app; class UsmSeatCalls { com.hkmc.usm.USMManager m; void go(android.content.Context c) { if (m == null) m = new com.hkmc.usm.USMManager(c); m.setFrontSeatHeatDrvStep(3); m.setFrontSeatHeatAstStep(3); } }'
scratch_dex extra UsmSeatCalls 'package hkgclimate.app; class UsmSeatCalls { void go(android.content.Context c) { new com.hkmc.usm.USMManager(c).setOther(3); } }'
scratch_dex seat UsmSeatCalls 'package hkgclimate.app; class UsmSeatCalls { void go() { new com.hkmc.usm.Seat().send(3); } }'
scratch_dex eager UsmSeatCalls 'package hkgclimate.app; class UsmSeatCalls { com.hkmc.usm.USMManager m; UsmSeatCalls(android.content.Context c) { m = new com.hkmc.usm.USMManager(c); } com.hkmc.usm.USMManager manager() { return m; } }'
scratch_dex name UsmSeatCalls 'package hkgclimate.app; class UsmSeatCalls { Object go() throws Exception { return Class.forName("android.os.ServiceManager").getMethod("getService", String.class).invoke(null, "com.hkmc.micom.usm"); } }'
scratch_dex fin UsmSeatCalls 'package hkgclimate.app; class UsmSeatCalls { com.hkmc.usm.USMManager m; void go() { boolean ok = false; try { m.setFrontSeatHeatDrvStep(3); ok = true; } finally { if (!ok) m = null; } } }'
scratch_dex catcher UsmSeatCalls 'package hkgclimate.app; class UsmSeatCalls { void go(com.hkmc.usm.USMManager m) { try { m.setFrontSeatHeatDrvStep(3); } catch (RuntimeException e) { } } }'
# the seat setters: CheckedSeatSender.send is the one allowed caller (UsmCalls is a scratch copy
# of our own interface, declared next to its callers)
SEND_IFACE='package hkgclimate.core; public interface UsmCalls { void driver(int v) throws Exception; void passenger(int v) throws Exception; }'
scratch_dex sendok UsmCalls "$SEND_IFACE class CheckedSeatSender { UsmCalls c; void send(int v) throws Exception { c.driver(v); c.passenger(v); } }"
scratch_dex sendother UsmCalls "$SEND_IFACE class CheckedSeatSender { UsmCalls c; void send(int v) throws Exception { c.driver(v); } } class Other { void go(UsmCalls c) throws Exception { c.driver(3); } }"
scratch_dex sendset UsmCalls "$SEND_IFACE class CheckedSeatSender { UsmCalls c; void send(int v) throws Exception { c.driver(v); } void set(int v) throws Exception { c.passenger(v); } }"
scratch_dex sendapp Other 'package hkgclimate.app; class UsmSeatCalls { void driver(int v) { } void passenger(int v) { } } public class Other { void go(UsmSeatCalls c) { c.passenger(3); } }'
# the preset fences: DATC members, the DATC and USM cabin setters, and the cabin call chain
scratch_dex usmcabin UsmSeatCalls 'package hkgclimate.app; class UsmSeatCalls { com.hkmc.usm.USMManager m; void wheel(int v) { m.setSWRC_SteeringwheelWarmerSet(v); } void eco(int v) { m.setClimateControlECOMode(v); } int read() { return m.getSWRC_SteeringwheelHeatIndStep2() + m.getClimateControlECOMode(); } }'
scratch_dex usmwheel UsmSeatCalls 'package hkgclimate.app; class UsmSeatCalls { com.hkmc.usm.USMManager m; void wheel(int v) { m.setSWRC_SteeringwheelWarmerSet(v); } void eco(int v) { m.setSWRC_SteeringwheelWarmerSet(0); } }'
scratch_dex datcok DatcClimateCalls 'package hkgclimate.app; class DatcClimateCalls { com.hkmc.datc.DATCManager m; void send(int f, int v) { m.setFrontClimateControl(f, v); } float read() { return m.getVRClimateStatus(2) + m.getDriverOnlyValue() + m.getTemperatureUnit(); } }'
scratch_dex datcvr Other 'package hkgclimate.app; public class Other { void go(com.hkmc.datc.DATCManager m) { m.setVRClimateStatus(9, 1); } }'
scratch_dex datcout Other 'package hkgclimate.app; class DatcClimateCalls { void send(com.hkmc.datc.DATCManager m) { m.setFrontClimateControl(9, 1); } } public class Other { void go(com.hkmc.datc.DATCManager m) { m.setFrontClimateControl(9, 1); } }'
scratch_dex datcextra DatcClimateCalls 'package hkgclimate.app; class DatcClimateCalls { int send(com.hkmc.datc.DATCManager m) { return m.getClimateInfo(24); } }'
scratch_dex datcnew DatcClimateCalls 'package hkgclimate.app; class DatcClimateCalls { void send(android.content.Context c, int f, int v) { new com.hkmc.datc.DATCManager(c).setFrontClimateControl(f, v); } }'
CABIN_IFACE='package hkgclimate.core; public interface CabinCalls { void climate(int f, int v) throws Exception; void wheel(int v) throws Exception; void eco(int v) throws Exception; }'
scratch_dex cabinok CabinCalls "$CABIN_IFACE class CheckedCabinSender { CabinCalls c; void climate(int f, int v) throws Exception { c.climate(f, v); } void eco(int v) throws Exception { c.eco(v); } private void release() throws Exception { c.wheel(0); } }"
scratch_dex cabinout CabinCalls "$CABIN_IFACE class CheckedCabinSender { CabinCalls c; void eco(int v) throws Exception { c.eco(v); } } class Other { void go(CabinCalls c) throws Exception { c.wheel(1); } }"
scratch_dex cabinstock Other 'package hkgclimate.app; class StockCabinCalls { public void climate(int f, int v) { } } public class Other { void go(StockCabinCalls s) { s.climate(51, 1); } }'
STOCK_CLASSES='package hkgclimate.app; class DatcClimateCalls { void send(int f, int v) { } } class UsmSeatCalls { void wheel(int v) { } void eco(int v) { } } class StockCabinCalls { DatcClimateCalls d; UsmSeatCalls u; void climate(int f, int v) { d.send(f, v); } void wheel(int v) { u.wheel(v); } void eco(int v) { u.eco(v); } }'
# CheckedCabinSender's sending methods: PresetRunner is the one allowed caller (a scratch copy of
# the sender; wheelPending is not a sending method)
SENDER_CLASS='package hkgclimate.core; public class CheckedCabinSender { public boolean climate(int f, int v) { return true; } public boolean eco(int v) { return true; } public boolean wheelPress(Object s) { return true; } public boolean wheelPending() { return false; } }'
scratch_dex runnerok CheckedCabinSender "$SENDER_CLASS class PresetRunner { CheckedCabinSender s; void go() { s.climate(8, 1); s.eco(2); s.wheelPress(null); s.wheelPending(); } }"
scratch_dex runnerother CheckedCabinSender "$SENDER_CLASS class PresetRunner { CheckedCabinSender s; void go() { s.climate(8, 1); } } class Other { void go(CheckedCabinSender s) { s.wheelPress(null); } }"
scratch_dex runnerstray CheckedCabinSender "$SENDER_CLASS class PresetRunner { CheckedCabinSender s; void go() { s.climate(8, 1); } } class ClimateCore { void tap(CheckedCabinSender s) { s.eco(2); } }"
scratch_dex stockok StockCabinCalls "$STOCK_CLASSES"
scratch_dex stockwheel StockCabinCalls "$STOCK_CLASSES class Other { void go(UsmSeatCalls u) { u.wheel(1); } }"
scratch_dex stocksend StockCabinCalls "$STOCK_CLASSES class Other { void go(DatcClimateCalls d) { d.send(8, 1); } }"
# only_flags / only_passes <listing> <grep ref> <method prefix> <ref>...: the listing has <grep ref>
# (so the scratch build worked) and refs_only_in fails / passes on it
only_flags() { _l=$1; _g=$2; shift 2; grep -q "$_g" "$_l" && ! refs_only_in "$_l" "$@"; }
only_passes() { _l=$1; _g=$2; shift 2; grep -q "$_g" "$_l" && refs_only_in "$_l" "$@"; }
# datc_flags / datc_passes <listing> <ref>: the listing has <ref> and datc_refs_ok fails / passes
datc_flags() { grep -q "$2" "$1" && ! datc_refs_ok "$1"; }
datc_passes() { grep -q "$2" "$1" && datc_refs_ok "$1"; }
# new_flags <listing> <method prefix>: DATCManager is constructed there and code_lacks_ref fails
new_flags() { grep -q 'DATCManager;\.<init>' "$1" && ! code_lacks_ref "$1" "$2" 'Lcom/hkmc/datc/DATCManager;.<init>'; }
# vr_flags <scratch dir>: the scratch code calls setVRClimateStatus and the dex string check fails
vr_flags() { grep -q 'DATCManager;\.setVRClimateStatus' "$1/code.txt" && ! dex_lacks_string "$1/classes.dex" setVRClimateStatus; }
# usm_flags / usm_passes <listing> <ref>: the listing has <ref> (so the scratch build worked) and
# usm_refs_ok fails / passes on it
usm_flags() { grep -q "$2" "$1" && ! usm_refs_ok "$1"; }
usm_passes() { grep -q "$2" "$1" && usm_refs_ok "$1"; }
# lazy_flags <listing> <method>: USMManager is constructed there, and not only in <method>
lazy_flags() { grep -q 'USMManager;\.<init>' "$1" && ! usm_new_only_in "$1" "$2"; }
# strings_pass / strings_flag <scratch dir> [<string>]: the scratch dex was built (and has the
# string) and usm_strings_ok passes / fails on it
strings_pass() { [ -s "$1/code.txt" ] && grep -q 'Lcom/hkmc/usm/USMManager;' "$1/code.txt" && usm_strings_ok "$1/classes.dex"; }
strings_flag() { grep -q "const-string.*\"$2\"" "$1/code.txt" && ! usm_strings_ok "$1/classes.dex"; }
# catch_flags <listing> <class>: the listing has a typed catch and no_typed_catch_in fails on it
catch_flags() { grep -q 'Ljava/lang/RuntimeException; -> 0x' "$1" && ! no_typed_catch_in "$1" "$2"; }
# catch_passes <listing> <class>: the listing has a finally block (so the scratch build worked)
# and no_typed_catch_in passes on it
catch_passes() { grep -q '<any> -> 0x' "$1" && no_typed_catch_in "$1" "$2"; }
# send_flags <listing> <ref>: the listing has <ref> and seat_calls_only_in fails on it
send_flags() { grep -q "$2" "$1" && ! seat_calls_only_in "$1" 'hkgclimate.core.CheckedSeatSender.send:'; }
# send_none_fails <listing>: the listing has code but no seat call, and seat_calls_only_in fails
send_none_fails() { grep -q '|\[' "$1" && ! seat_calls_only_in "$1" 'hkgclimate.core.CheckedSeatSender.send:'; }
# editor_not_exported <aapt xmltree of the manifest>: the PresetEditorActivity element exists, is
# not exported (no android:exported=true) and has no intent-filter
editor_not_exported() {
    awk '
        function flush() {
            if (blk != "" && blk ~ /android:name\([^)]*\)="hkgclimate.app.PresetEditorActivity"/) {
                found = 1
                if (blk ~ /E: intent-filter/ || blk ~ /android:exported[^\n]*0xffffffff/) bad = 1
            }
            blk = ""
        }
        /^ *E: / {
            ind = match($0, /E: /)
            if (inact && ind <= ai) { flush(); inact = 0 }
            if ($0 ~ /E: activity /) { flush(); inact = 1; ai = ind }
        }
        inact { blk = blk $0 "\n" }
        END { flush(); exit !(found && !bad) }' "$1"
}
# dialog_only_in_settings <dexdump -d output>: every Landroid/app/AlertDialog reference is in the
# code of a hkgclimate.app.SettingsActivity method (the delete question) or of the editor's choice
# list, hkgclimate.app.ChoiceSpinner (and the listing has at least one)
dialog_only_in_settings() {
    awk '
        /Class descriptor/ { meth = "" }
        /\|\[[0-9a-f]+\] / { m = $0; sub(/.*\|\[[0-9a-f]+\] /, "", m); meth = m }
        index($0, "Landroid/app/AlertDialog") && index($0, "|") {
            n++
            if (index(meth, "hkgclimate.app.SettingsActivity.") != 1 && index(meth, "hkgclimate.app.ChoiceSpinner.") != 1) { print; bad++ }
        }
        END { exit !(n > 0 && bad == 0) }' "$1"
}
scratch_dex dialog Other 'package hkgclimate.app; public class Other { void go(android.content.Context c) { new android.app.AlertDialog.Builder(c).setTitle("x").show(); } }'
scratch_dex dialog_choice ChoiceSpinner 'package hkgclimate.app; class ChoiceSpinner { void go(android.content.Context c) { new android.app.AlertDialog.Builder(c).setTitle("x").show(); } }'
scratch_dex dialog_editor PresetEditorActivity 'package hkgclimate.app; class PresetEditorActivity { void go(android.content.Context c) { new android.app.AlertDialog.Builder(c).setTitle("x").show(); } }'
scratch_dex dialog_lookalike ChoiceSpinnerTwo 'package hkgclimate.app; class ChoiceSpinnerTwo { void go(android.content.Context c) { new android.app.AlertDialog.Builder(c).setTitle("x").show(); } }'
check "self-test: the reference check finds a scratch com.hkmc.usm call" has_ref "$ST/caller/code.txt" 'Lcom/hkmc/usm/'
check "self-test: usm check flags a com.hkmc.usm call from another class" \
    usm_flags "$ST/caller/code.txt" 'Lcom/hkmc/usm/Seat;\.send'
check "self-test: usm check flags an approved USMManager call from another class" \
    usm_flags "$ST/other/code.txt" 'USMManager;\.setFrontSeatHeatDrvStep'
check "self-test: usm check passes UsmSeatCalls making the approved calls" \
    usm_passes "$ST/good/code.txt" 'USMManager;\.setFrontSeatHeatAstStep'
check "self-test: usm check flags UsmSeatCalls calling another USMManager member" \
    usm_flags "$ST/extra/code.txt" 'USMManager;\.setOther'
check "self-test: usm check flags UsmSeatCalls calling another com.hkmc.usm class" \
    usm_flags "$ST/seat/code.txt" 'Lcom/hkmc/usm/Seat;\.send'
check "self-test: the lazy check passes a USMManager made only in manager()" \
    usm_new_only_in "$ST/good/code.txt" 'hkgclimate.app.UsmSeatCalls.go:'
check "self-test: the lazy check flags a USMManager made in the constructor" \
    lazy_flags "$ST/eager/code.txt" 'hkgclimate.app.UsmSeatCalls.manager:'
check "self-test: the string check passes the allowed USMManager descriptor" \
    strings_pass "$ST/good"
check "self-test: the string check flags a service looked up by the name com.hkmc.micom.usm" \
    strings_flag "$ST/name" 'com.hkmc.micom.usm'
check "self-test: the catch check passes UsmSeatCalls with a finally block" \
    catch_passes "$ST/fin/code.txt" 'Lhkgclimate/app/UsmSeatCalls;'
check "self-test: the catch check flags UsmSeatCalls catching an exception" \
    catch_flags "$ST/catcher/code.txt" 'Lhkgclimate/app/UsmSeatCalls;'
check "self-test: the seat-call check passes calls made only in CheckedSeatSender.send" \
    seat_calls_only_in "$ST/sendok/code.txt" 'hkgclimate.core.CheckedSeatSender.send:'
check "self-test: the seat-call check flags another class calling UsmCalls.driver" \
    send_flags "$ST/sendother/code.txt" 'hkgclimate.core.Other.go:'
check "self-test: the seat-call check flags another CheckedSeatSender method calling UsmCalls.passenger" \
    send_flags "$ST/sendset/code.txt" 'UsmCalls;\.passenger:'
check "self-test: the seat-call check flags another class calling UsmSeatCalls.passenger" \
    send_flags "$ST/sendapp/code.txt" 'UsmSeatCalls;\.passenger:'
check "self-test: the seat-call check fails a listing with no seat call" \
    send_none_fails "$ST/caller/code.txt"

check "self-test: usm check passes UsmSeatCalls making the steering-wheel and eco calls" \
    usm_passes "$ST/usmcabin/code.txt" 'USMManager;\.getClimateControlECOMode'
check "self-test: the wheel-setter check flags setSWRC_SteeringwheelWarmerSet outside UsmSeatCalls.wheel" \
    only_flags "$ST/usmwheel/code.txt" 'setSWRC_SteeringwheelWarmerSet' 'hkgclimate.app.UsmSeatCalls.wheel:' 'Lcom/hkmc/usm/USMManager;.setSWRC_SteeringwheelWarmerSet:'
check "self-test: the wheel-setter check passes it inside UsmSeatCalls.wheel only" \
    only_passes "$ST/usmcabin/code.txt" 'setSWRC_SteeringwheelWarmerSet' 'hkgclimate.app.UsmSeatCalls.wheel:' 'Lcom/hkmc/usm/USMManager;.setSWRC_SteeringwheelWarmerSet:'
check "self-test: the DATC member check passes DatcClimateCalls using allowed members" \
    datc_passes "$ST/datcok/code.txt" 'DATCManager;\.getDriverOnlyValue'
check "self-test: the DATC member check flags a setVRClimateStatus call" \
    datc_flags "$ST/datcvr/code.txt" 'DATCManager;\.setVRClimateStatus'
check "self-test: the dex string check flags a setVRClimateStatus call" vr_flags "$ST/datcvr"
check "self-test: the DATC member check flags an extra DATCManager member" \
    datc_flags "$ST/datcextra/code.txt" 'DATCManager;\.getClimateInfo'
check "self-test: the DATC member check flags a DATCManager constructor" \
    datc_flags "$ST/datcnew/code.txt" 'DATCManager;\.<init>'
check "self-test: the climate-setter check passes setFrontClimateControl in DatcClimateCalls.send" \
    only_passes "$ST/datcok/code.txt" 'setFrontClimateControl' 'hkgclimate.app.DatcClimateCalls.send:' 'Lcom/hkmc/datc/DATCManager;.setFrontClimateControl:'
check "self-test: the climate-setter check flags setFrontClimateControl outside DatcClimateCalls" \
    only_flags "$ST/datcout/code.txt" 'Other.go' 'hkgclimate.app.DatcClimateCalls.send:' 'Lcom/hkmc/datc/DATCManager;.setFrontClimateControl:'
check "self-test: the no-constructor check passes DatcClimateCalls without one" \
    code_lacks_ref "$ST/datcok/code.txt" 'hkgclimate.app.DatcClimateCalls.' 'Lcom/hkmc/datc/DATCManager;.<init>'
check "self-test: the no-constructor check flags DatcClimateCalls making a DATCManager" \
    new_flags "$ST/datcnew/code.txt" 'hkgclimate.app.DatcClimateCalls.'
check "self-test: the no-constructor check fails a listing without the class" \
    fails code_lacks_ref "$ST/caller/code.txt" 'hkgclimate.app.DatcClimateCalls.' 'Lcom/hkmc/datc/DATCManager;.<init>'
# shellcheck disable=SC2086 # the ref lists are one ref per word
check "self-test: the cabin-call check passes calls made only in CheckedCabinSender" \
    only_passes "$ST/cabinok/code.txt" 'CabinCalls;\.wheel:' "$CABIN_FROM" $CABIN_REFS
# shellcheck disable=SC2086
check "self-test: the cabin-call check flags another class calling CabinCalls.wheel" \
    only_flags "$ST/cabinout/code.txt" 'hkgclimate.core.Other.go:' "$CABIN_FROM" $CABIN_REFS
# shellcheck disable=SC2086
check "self-test: the cabin-call check flags a direct StockCabinCalls.climate call" \
    only_flags "$ST/cabinstock/code.txt" 'StockCabinCalls;\.climate:' "$CABIN_FROM" $CABIN_REFS
# shellcheck disable=SC2086
check "self-test: the cabin-call check fails a listing with no cabin call" \
    fails refs_only_in "$ST/caller/code.txt" "$CABIN_FROM" $CABIN_REFS
# shellcheck disable=SC2086
check "self-test: the sender-call check passes calls made only in PresetRunner" \
    only_passes "$ST/runnerok/code.txt" 'CheckedCabinSender;\.wheelPress:' "$SENDER_FROM" $SENDER_REFS
# shellcheck disable=SC2086
check "self-test: the sender-call check flags another class calling wheelPress" \
    only_flags "$ST/runnerother/code.txt" 'hkgclimate.core.Other.go:' "$SENDER_FROM" $SENDER_REFS
# shellcheck disable=SC2086
check "self-test: the sender-call check flags ClimateCore calling eco" \
    only_flags "$ST/runnerstray/code.txt" 'hkgclimate.core.ClimateCore.tap:' "$SENDER_FROM" $SENDER_REFS
# shellcheck disable=SC2086
check "self-test: the sender-call check fails a listing with no sender call" \
    fails refs_only_in "$ST/caller/code.txt" "$SENDER_FROM" $SENDER_REFS
# shellcheck disable=SC2086
check "self-test: the stock-setter check passes calls made only in StockCabinCalls" \
    only_passes "$ST/stockok/code.txt" 'UsmSeatCalls;\.eco:' "$STOCK_FROM" $STOCK_REFS
# shellcheck disable=SC2086
check "self-test: the stock-setter check flags another class calling UsmSeatCalls.wheel" \
    only_flags "$ST/stockwheel/code.txt" 'hkgclimate.app.Other.go:' "$STOCK_FROM" $STOCK_REFS
# shellcheck disable=SC2086
check "self-test: the stock-setter check flags another class calling DatcClimateCalls.send" \
    only_flags "$ST/stocksend/code.txt" 'hkgclimate.app.Other.go:' "$STOCK_FROM" $STOCK_REFS

check "package is hkgclimate.app" grep -q "^package: name='hkgclimate.app'" "$TMP/badging"
check "versionName is 1.2.1" grep -q "versionName='1.2.1'" "$TMP/badging"
check "versionCode is 7" grep -q "versionCode='7'" "$TMP/badging"
# the approval flow is gone: no commander class, no dialog, no preference key
check "dex has no TestModeCommander class" sh -c "! grep -q 'Lhkgclimate/app/TestModeCommander;' $TMP/dex.txt"
# the one dialog is the settings screen's "Delete preset?" confirm; nothing else shows one
check "AlertDialog is referenced only by SettingsActivity (the delete confirm) and ChoiceSpinner (the choice lists)" \
    dialog_only_in_settings "$TMP/dexcode.txt"
check "self-test: dialog_only_in_settings flags a reference from another class" \
    fails dialog_only_in_settings "$ST/dialog/code.txt"
check "self-test: dialog_only_in_settings passes a reference from ChoiceSpinner" \
    dialog_only_in_settings "$ST/dialog_choice/code.txt"
check "self-test: dialog_only_in_settings flags a reference from the editor itself" \
    fails dialog_only_in_settings "$ST/dialog_editor/code.txt"
check "self-test: dialog_only_in_settings flags a reference from a class whose name only starts with ChoiceSpinner" \
    fails dialog_only_in_settings "$ST/dialog_lookalike/code.txt"
check "dex strings have no seat_command_approved key" dex_lacks_string "$TMP/classes.dex" seat_command_approved
check "self-test: dex_has_string finds a string the dex holds" dex_has_string "$TMP/classes.dex" switch_temp_f
check "sdkVersion is 19" grep -q "^sdkVersion:'19'" "$TMP/badging"
check "automotive library is not required" grep -q "^uses-library-not-required:'automotive'" "$TMP/badging"
check "WRITE_SETTINGS is requested" grep -q "uses-permission: name='android.permission.WRITE_SETTINGS'" "$TMP/badging"
check "GET_TASKS is requested" grep -q "uses-permission: name='android.permission.GET_TASKS'" "$TMP/badging"
check "launcher activity is SettingsActivity" grep -q "launchable-activity: name='hkgclimate.app.SettingsActivity'" "$TMP/badging"
check "apk has classes.dex" grep -qx 'classes.dex' "$TMP/entries"
check "apk signature verifies (v1, min sdk 19)" "$BUILD_TOOLS/apksigner" verify --min-sdk-version 19 "$APK"
check "apk is zip aligned" "$BUILD_TOOLS/zipalign" -c 4 "$APK"
check "dex has our ClimateService" grep -q "Lhkgclimate/app/ClimateService;" "$TMP/dex.txt"
check "dex has PageLink" grep -q "Lhkgclimate/link/PageLink;" "$TMP/dex.txt"
check "dex has core classes" grep -q "Lhkgclimate/core/ClimateCore;" "$TMP/dex.txt"
check "dex lists classes" grep -q "Class descriptor" "$TMP/dex.txt"
check "dex has no class under Lcom/hkmc/" sh -c "! grep -q \"Class descriptor *: *'Lcom/hkmc/\" $TMP/dex.txt"
check "dex code listing contains our code" grep -q 'hkgclimate.app.SettingsActivity.onCreate' "$TMP/dexcode.txt"
# the stock services we read: referenced from code, the service name as a real field read (a
# constant would have been inlined by javac), and the DATC manager never constructed directly
check "code calls DATCManager.addTemperatureListener" has_ref "$TMP/dexcode.txt" 'Lcom/hkmc/datc/DATCManager;\.addTemperatureListener'
check "code calls BCMManager.getDrvSeatHeatState" has_ref "$TMP/dexcode.txt" 'Lcom/hkmc/bcm/BCMManager;\.getDrvSeatHeatState'
check "code reads the field VehicleInfoManager.DATC_SERVICE (sget-object)" has_ref "$TMP/dexcode.txt" 'sget-object.*Lcom/hkmc/VehicleInfoManager;\.DATC_SERVICE'
check "code never constructs DATCManager" sh -c "! grep -q 'Lcom/hkmc/datc/DATCManager;\.<init>' $TMP/dexcode.txt"
# the service starts itself so it outlives the page's binds (START_STICKY only holds for a started service)
check "ClimateService calls startService" has_ref "$TMP/dexcode.txt" 'Lhkgclimate/app/ClimateService;\.startService:'
# the Android docs: unbind even when bindService returned false
check "SettingsActivity.onStart can unbind (a failed bind)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.SettingsActivity.onStart:' '\.unbindService:'
# self-test of method_has_ref: it sees onStart's own bind, and stops at the next method (onStop,
# listed later, calls disconnect; onStart does not)
check "self-test: method_has_ref sees onStart's bindService" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.SettingsActivity.onStart:' '\.bindService:'
check "self-test: method_has_ref stops at the end of onStart" \
    method_lacks_ref "$TMP/dexcode.txt" 'hkgclimate.app.SettingsActivity.onStart:' 'SettingsActivity;\.disconnect:'
check "dex has PageListKeeper" grep -q "Lhkgclimate/app/PageListKeeper;" "$TMP/dex.txt"
check "code registers a content observer on the settings" has_ref "$TMP/dexcode.txt" 'Landroid/content/ContentResolver;\.registerContentObserver'
check "code writes the page lists with Settings.System.putString" has_ref "$TMP/dexcode.txt" 'Landroid/provider/Settings\$System;\.putString'
check "dex has the page list changed action" grep -q "com.android.settings.splitscreen_settings.changed" "$TMP/dex.txt"
# the seat command: only UsmSeatCalls touches the stock seat service, with the three approved members
check "every Lcom/hkmc/usm/ reference is an approved USMManager call in UsmSeatCalls" usm_refs_ok "$TMP/dexcode.txt"
check "UsmSeatCalls.driver calls setFrontSeatHeatDrvStep" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.UsmSeatCalls.driver:' 'Lcom/hkmc/usm/USMManager;\.setFrontSeatHeatDrvStep:(I)V'
check "UsmSeatCalls.passenger calls setFrontSeatHeatAstStep" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.UsmSeatCalls.passenger:' 'Lcom/hkmc/usm/USMManager;\.setFrontSeatHeatAstStep:(I)V'
check "UsmSeatCalls constructs USMManager" has_ref "$TMP/dexcode.txt" 'Lcom/hkmc/usm/USMManager;\.<init>:(Landroid/content/Context;)V'
# lazy: the manager is made on the first send, never when the service builds the adapter
check "dex has UsmSeatCalls.<init>" grep -q '\] hkgclimate.app.UsmSeatCalls.<init>:' "$TMP/dexcode.txt"
check "UsmSeatCalls.<init> does not construct USMManager" \
    method_lacks_ref "$TMP/dexcode.txt" 'hkgclimate.app.UsmSeatCalls.<init>:' 'Lcom/hkmc/usm/USMManager;\.<init>'
check "USMManager is constructed only in UsmSeatCalls.manager" \
    usm_new_only_in "$TMP/dexcode.txt" 'hkgclimate.app.UsmSeatCalls.manager:'
check "UsmSeatCalls.<init> does not call manager()" \
    method_lacks_ref "$TMP/dexcode.txt" 'hkgclimate.app.UsmSeatCalls.<init>:' 'UsmSeatCalls;\.manager:'
check "no dex string names the seat service except the USMManager type" usm_strings_ok "$TMP/classes.dex"
# a failed setter drops the cached manager (a finally, not a catch), so the next tap makes a new one
check "UsmSeatCalls.driver can clear the cached manager" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.UsmSeatCalls.driver:' 'iput-object.*UsmSeatCalls;\.usm:'
check "UsmSeatCalls.passenger can clear the cached manager" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.UsmSeatCalls.passenger:' 'iput-object.*UsmSeatCalls;\.usm:'
check "UsmSeatCalls catches no exception (CheckedSeatSender does)" \
    no_typed_catch_in "$TMP/dexcode.txt" 'Lhkgclimate/app/UsmSeatCalls;'
# the one place the seat setters are called: the checked sender, after its value check
check "the seat setters are called only from CheckedSeatSender.send" \
    seat_calls_only_in "$TMP/dexcode.txt" 'hkgclimate.core.CheckedSeatSender.send:'
check "ClimateService builds the CheckedSeatSender" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.ClimateService.onCreate:' 'Lhkgclimate/core/CheckedSeatSender;\.<init>'
check "ClimateService builds the UsmSeatCalls" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.ClimateService.onCreate:' 'Lhkgclimate/app/UsmSeatCalls;\.<init>'

# presets (plan 5): stored in the preferences, loaded into the core, served to the page
check "the editor activity is in the manifest, not exported, with no intent filter" \
    editor_not_exported "$TMP/manifest.txt"
sed 's/(type 0x12)0x0$/(type 0x12)0xffffffff/' "$TMP/manifest.txt" > "$TMP/manifest-bad.txt"
check "self-test: editor_not_exported fails on an exported editor" fails editor_not_exported "$TMP/manifest-bad.txt"
sed 's/PresetEditorActivity/OtherActivity/' "$TMP/manifest.txt" > "$TMP/manifest-none.txt"
check "self-test: editor_not_exported fails when there is no editor" fails editor_not_exported "$TMP/manifest-none.txt"
check "dex has PresetEditorActivity" grep -q "Lhkgclimate/app/PresetEditorActivity;" "$TMP/dex.txt"
check "PageLinkBinder serves a preset tap (ClimateCore.onPresetTap)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.PageLinkBinder.presetTap:' 'Lhkgclimate/core/ClimateCore;\.onPresetTap'
check "PageLinkBinder.presetTap runs the send bookkeeping (sent) and so does the seat tap" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.PageLinkBinder.presetTap:' 'PageLinkBinder;\.sent:'
check "PageLinkBinder.tap runs the same send bookkeeping" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.PageLinkBinder.tap:' 'PageLinkBinder;\.sent:'
check "PageLinkBinder.sent runs the afterSend callback" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.PageLinkBinder.sent:' 'iget-object.*PageLinkBinder;\.afterSend'
check "ClimateService loads the presets into the core" \
    has_ref "$TMP/dexcode.txt" 'Lhkgclimate/core/ClimateCore;\.setPresets'
check "PageStates puts the preset keys" dex_has_string "$TMP/classes.dex" presetEnabled
check "the editor checks a preset with Preset.check before storing it" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.PresetEditorActivity.save:' 'Lhkgclimate/core/Preset;\.check'
check "the editor builds its seat choices with SeatChoices" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.PresetEditorActivity.seatSpinner:' 'Lhkgclimate/core/SeatChoices;\.offered'
check "the editor labels a seat's choices with SeatChoices.label" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.PresetEditorActivity.seatSpinner:' 'Lhkgclimate/core/SeatChoices;\.label'
check "the editor builds its temperature choices with the car's unit (PresetChoices.temperatureChoices)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.PresetEditorActivity.buildViews:' 'Lhkgclimate/core/PresetChoices;\.temperatureChoices'
check "the editor greys its spinners by climate mode (PresetChoices.greyed)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.PresetEditorActivity.applyGreying:' 'Lhkgclimate/core/PresetChoices;\.greyed'
check "the editor shows each item as a Spinner (a ChoiceSpinner, given an adapter)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.PresetEditorActivity.itemSpinner:' 'Landroid/widget/Spinner;\.setAdapter:'
check "the editor gives each spinner its own fixed view id" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.PresetEditorActivity.itemSpinner:' '\.setId:(I)V'
check "the editor saves the whole preset (the 12-argument Preset constructor)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.PresetEditorActivity.save:' 'Lhkgclimate/core/Preset;\.<init>:(Ljava/lang/String;IIIIIIIIIII)V'
check "the editor checks the whole preset (Preset.check(Preset))" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.PresetEditorActivity.save:' 'Lhkgclimate/core/Preset;\.check:(Lhkgclimate/core/Preset;)'
check "the editor uses no RadioGroup or RadioButton" \
    code_lacks_ref "$TMP/dexcode.txt" 'hkgclimate.app.PresetEditorActivity.' 'Landroid/widget/Radio'
scratch_dex radio PresetEditorActivity 'package hkgclimate.app; class PresetEditorActivity { void go(android.content.Context c) { new android.widget.RadioGroup(c).addView(new android.widget.RadioButton(c)); } }'
scratch_dex noradio PresetEditorActivity 'package hkgclimate.app; class PresetEditorActivity { void go(android.content.Context c) { new android.widget.Spinner(c); } }'
check "self-test: the radio check flags an editor that uses a RadioGroup" \
    fails code_lacks_ref "$ST/radio/code.txt" 'hkgclimate.app.PresetEditorActivity.' 'Landroid/widget/Radio'
check "self-test: the radio check passes an editor that uses a Spinner" \
    code_lacks_ref "$ST/noradio/code.txt" 'hkgclimate.app.PresetEditorActivity.' 'Landroid/widget/Radio'
check "self-test: the radio check fails a listing with no editor code" \
    fails code_lacks_ref "$ST/caller/code.txt" 'hkgclimate.app.PresetEditorActivity.' 'Landroid/widget/Radio'
check "Prefs.setPresets writes with commit()" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.Prefs.setPresets:' 'Landroid/content/SharedPreferences\$Editor;\.commit:'
check "Prefs.setPresets does not use apply()" \
    method_lacks_ref "$TMP/dexcode.txt" 'hkgclimate.app.Prefs.setPresets:' 'Landroid/content/SharedPreferences\$Editor;\.apply:'
check "self-test: method_has_ref sees apply() in Prefs.setSwitchTempF (the apply check above can see one)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.Prefs.setSwitchTempF:' 'Landroid/content/SharedPreferences\$Editor;\.apply:'
check "the editor stores through Prefs.setPresets and reads back its result (a boolean)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.PresetEditorActivity.save:' 'Lhkgclimate/app/Prefs;\.setPresets:(Ljava/util/List;)Z'
check "the editor says when the settings write was refused" \
    dex_has_string "$TMP/classes.dex" "could not save: the settings write was refused"
check "the editor shows a save exception in full (could not save: class and message)" \
    dex_has_string "$TMP/classes.dex" "could not save: "
check "the editor logs a save exception with its stack trace (Log.w with a Throwable)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.PresetEditorActivity.fail:' 'Landroid/util/Log;\.w:(Ljava/lang/String;Ljava/lang/String;Ljava/lang/Throwable;)I'
check "the settings list uses PresetSummary" \
    has_ref "$TMP/dexcode.txt" 'Lhkgclimate/core/PresetSummary;\.of'
check "ClimateService checks every overdue send (SendWatch.allOverdue)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.ClimateService.checkWatch:' 'Lhkgclimate/core/SendWatch;\.allOverdue'
check "ClimateService.afterSend picks the worst result of the tap" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.ClimateService.afterSend:' 'Lhkgclimate/core/SendSummary;\.worst'
check "the settings screen stores presets through PresetList" \
    has_ref "$TMP/dexcode.txt" 'Lhkgclimate/core/PresetList;\.moveUp'
check "preset sends go through the core and CheckedSeatSender only (no new send path)" \
    method_lacks_ref "$TMP/dexcode.txt" 'hkgclimate.app.PageLinkBinder.presetTap:' 'UsmSeatCalls'

# presets (plan 6): the climate, steering-wheel and eco commands, each through its fenced class
check "every DATCManager member the code names is one of the six allowed" datc_refs_ok "$TMP/dexcode.txt"
check "setFrontClimateControl is called only from DatcClimateCalls.send" \
    refs_only_in "$TMP/dexcode.txt" 'hkgclimate.app.DatcClimateCalls.send:' 'Lcom/hkmc/datc/DATCManager;.setFrontClimateControl:'
check "no setVRClimateStatus in the dex strings" dex_lacks_string "$TMP/classes.dex" setVRClimateStatus
check "no setVRClimateStatus in the code" sh -c "! grep -q 'setVRClimateStatus' $TMP/dexcode.txt"
check "DatcClimateCalls constructs no DATCManager" \
    code_lacks_ref "$TMP/dexcode.txt" 'hkgclimate.app.DatcClimateCalls.' 'Lcom/hkmc/datc/DATCManager;.<init>'
check "DatcClimateCalls.send gets the manager from VehicleInfoManager.getService" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.DatcClimateCalls.send:' 'Lcom/hkmc/VehicleInfoManager;\.getService:'
check "DatcClimateCalls.send reads the field VehicleInfoManager.DATC_SERVICE" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.DatcClimateCalls.send:' 'sget-object.*Lcom/hkmc/VehicleInfoManager;\.DATC_SERVICE'
check "DatcClimateCalls catches no exception (CheckedCabinSender does)" \
    no_typed_catch_in "$TMP/dexcode.txt" 'Lhkgclimate/app/DatcClimateCalls;'
check "StockCabinCalls catches no exception (CheckedCabinSender does)" \
    no_typed_catch_in "$TMP/dexcode.txt" 'Lhkgclimate/app/StockCabinCalls;'
check "setSWRC_SteeringwheelWarmerSet is called only from UsmSeatCalls.wheel" \
    refs_only_in "$TMP/dexcode.txt" 'hkgclimate.app.UsmSeatCalls.wheel:' 'Lcom/hkmc/usm/USMManager;.setSWRC_SteeringwheelWarmerSet:'
check "setClimateControlECOMode is called only from UsmSeatCalls.eco" \
    refs_only_in "$TMP/dexcode.txt" 'hkgclimate.app.UsmSeatCalls.eco:' 'Lcom/hkmc/usm/USMManager;.setClimateControlECOMode:'
check "UsmSeatCalls.wheel can clear the cached manager" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.UsmSeatCalls.wheel:' 'iput-object.*UsmSeatCalls;\.usm:'
check "UsmSeatCalls.eco can clear the cached manager" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.UsmSeatCalls.eco:' 'iput-object.*UsmSeatCalls;\.usm:'
# shellcheck disable=SC2086
check "CabinCalls.climate/wheel/eco are called only from CheckedCabinSender" \
    refs_only_in "$TMP/dexcode.txt" "$CABIN_FROM" $CABIN_REFS
# shellcheck disable=SC2086
check "CheckedCabinSender.climate/eco/wheelPress are called only from PresetRunner" \
    refs_only_in "$TMP/dexcode.txt" "$SENDER_FROM" $SENDER_REFS
# shellcheck disable=SC2086
check "DatcClimateCalls.send and UsmSeatCalls.wheel/eco are called only from StockCabinCalls" \
    refs_only_in "$TMP/dexcode.txt" "$STOCK_FROM" $STOCK_REFS
# start(Preset) calls start(Preset, long) inside the runner, so that method may name it too
check "a preset run starts only from ClimateCore.onPresetTap" \
    refs_only_in "$TMP/dexcode.txt" 'hkgclimate.core.ClimateCore.onPresetTap:|hkgclimate.core.PresetRunner.start:(Lhkgclimate/core/Preset;)Z' 'Lhkgclimate/core/PresetRunner;.start:'
check "ClimateService builds the CheckedCabinSender" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.ClimateService.onCreate:' 'Lhkgclimate/core/CheckedCabinSender;\.<init>'
check "ClimateService builds the StockCabinCalls" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.ClimateService.onCreate:' 'Lhkgclimate/app/StockCabinCalls;\.<init>'
check "ClimateService builds the PresetRunner" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.ClimateService.onCreate:' 'Lhkgclimate/core/PresetRunner;\.<init>'
check "ClimateService builds the CabinStateReader" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.ClimateService.onCreate:' 'Lhkgclimate/app/CabinStateReader;\.<init>'
check "ClimateService passes the runner and a clock to the ClimateCore (the 4-argument constructor)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.ClimateService.onCreate:' 'Lhkgclimate/core/ClimateCore;\.<init>:(Lhkgclimate/core/SeatCommander;ILhkgclimate/core/PresetRunner;Lhkgclimate/core/Clock;)V'
check "the runner's scheduler posts to the main looper's Handler (postDelayed, never inline)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.ClimateService$MainScheduler.after:' 'Landroid/os/Handler;\.postDelayed:'
check "the scheduler never runs the task itself" \
    method_lacks_ref "$TMP/dexcode.txt" 'hkgclimate.app.ClimateService$MainScheduler.after:' 'Ljava/lang/Runnable;\.run:'
check "CabinStateReader reads getVRClimateStatus" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.CabinStateReader.' 'Lcom/hkmc/datc/DATCManager;\.getVRClimateStatus:'
check "CabinStateReader gets the DATC manager from VehicleInfoManager.getService" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.CabinStateReader.' 'Lcom/hkmc/VehicleInfoManager;\.getService:'
check 'the settings screen calls its command line "Last command"' dex_has_string "$TMP/classes.dex" "Last command: "
check "the ClimateService notes a preset whose seats were not ready" dex_has_string "$TMP/classes.dex" "seats not ready"
check "a preset tap that sent nothing goes to the seats-not-ready note (PageLinkBinder.notSent)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.PageLinkBinder.presetTap:' 'PageLinkBinder;\.notSent:'
check "PageLinkBinder.notSent calls AfterSend.presetNotSent" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.PageLinkBinder.notSent:' 'PageLinkBinder\$AfterSend;\.presetNotSent:'
check "ClimateService.presetNotSent checks the seat readiness and updates the screen" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.ClimateService.presetNotSent:' 'ClimateService;\.debugChanged:'
check "ClimateService.presetNotSent schedules no watch check" \
    method_lacks_ref "$TMP/dexcode.txt" 'hkgclimate.app.ClimateService.presetNotSent:' 'Landroid/os/Handler;\.postDelayed:'
check "ClimateService.presetNotSent leaves the seat result (lastSend) alone" \
    method_lacks_ref "$TMP/dexcode.txt" 'hkgclimate.app.ClimateService.presetNotSent:' 'iput-object.*ClimateService;\.lastSend:'
check "ClimateService.presetNotSent sends nothing (no core, sender or runner start)" \
    method_lacks_ref "$TMP/dexcode.txt" 'hkgclimate.app.ClimateService.presetNotSent:' 'CheckedSeatSender\|CheckedCabinSender\|PresetRunner;\.start:\|ClimateCore;\.on'
check "self-test: method_has_ref sees afterSend's postDelayed (the lacks-checks above can see one)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.ClimateService.afterSend:' 'Landroid/os/Handler;\.postDelayed:'
check "self-test: method_has_ref sees afterSend writing lastSend" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.ClimateService.afterSend:' 'iput-object.*ClimateService;\.lastSend:'
check "preset taps reach no stock-call class directly" \
    method_lacks_ref "$TMP/dexcode.txt" 'hkgclimate.app.PageLinkBinder.presetTap:' 'CabinCalls\|DatcClimateCalls\|CheckedCabinSender'

# version 1.2: seat swap and off from the page, the applied-preset highlight
check "PageLinkBinder serves seat off through ClimateCore.onSeatOff" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.PageLinkBinder.offTap:' 'Lhkgclimate/core/ClimateCore;\.onSeatOff:'
check "PageLinkBinder.offTap runs the send bookkeeping (sent), like a seat tap" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.PageLinkBinder.offTap:' 'PageLinkBinder;\.sent:'
check "PageLinkBinder serves swap through ClimateCore.onSeatSwap" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.PageLinkBinder.swapTap:' 'Lhkgclimate/core/ClimateCore;\.onSeatSwap:'
check "PageLinkBinder.swapTap runs no send bookkeeping (a swap sends nothing)" \
    method_lacks_ref "$TMP/dexcode.txt" 'hkgclimate.app.PageLinkBinder.swapTap:' 'PageLinkBinder;\.sent:'
check "seat off and swap reach no sender or stock-call class directly" \
    sh -c "! awk -v a='] hkgclimate.app.PageLinkBinder.offTap:' -v b='] hkgclimate.app.PageLinkBinder.swapTap:' 'index(\$0, a) || index(\$0, b) { on = 1; next } on && /\\|\\[/ { on = 0 } on' $TMP/dexcode.txt | grep -q 'SeatCommander\|CheckedSeatSender\|UsmSeatCalls\|UsmCalls\|CabinCalls\|DatcClimateCalls\|CheckedCabinSender'"
check "ClimateCore.onSeatOff is called only from PageLinkBinder.offTap" \
    refs_only_in "$TMP/dexcode.txt" 'hkgclimate.app.PageLinkBinder.offTap:' 'Lhkgclimate/core/ClimateCore;.onSeatOff:'
check "SeatCommander.set is called only from ClimateCore (seat tap, seat off, a preset's seats)" \
    refs_only_in "$TMP/dexcode.txt" 'hkgclimate.core.ClimateCore.' 'Lhkgclimate/core/SeatCommander;.set:'
check "CheckedSeatSender.set is called only from the ClimateService's SeatCommander" \
    refs_only_in "$TMP/dexcode.txt" 'hkgclimate.app.ClimateService$' 'Lhkgclimate/core/CheckedSeatSender;.set:'
scratch_dex offok PageLinkBinder 'package hkgclimate.app; class PageLinkBinder { hkgclimate.core.ClimateCore c; void offTap() { c.onSeatOff(null, 1L); } }'
scratch_dex offout PageLinkBinder 'package hkgclimate.app; class PageLinkBinder { hkgclimate.core.ClimateCore c; void offTap() { c.onSeatOff(null, 1L); } } class Other { void go(hkgclimate.core.ClimateCore c) { c.onSeatOff(null, 2L); } }'
scratch_dex cmdok ClimateCore 'package hkgclimate.core; class ClimateCore { SeatCommander c; boolean onSeatOff(Object s, long id) { c.set(s, 2); return true; } }'
scratch_dex cmdout PageLinkBinder 'package hkgclimate.app; class PageLinkBinder { void offTap(hkgclimate.core.SeatCommander c) { c.set(null, 2); } }'
scratch_dex senderok ClimateService 'package hkgclimate.app; class ClimateService { hkgclimate.core.CheckedSeatSender s; Object c = new Object() { void set() { s.set(null, 2); } }; }'
scratch_dex senderout ClimateService 'package hkgclimate.app; class ClimateService { hkgclimate.core.CheckedSeatSender s; Object c = new Object() { void set() { s.set(null, 2); } }; } class PageLinkBinder { void offTap(hkgclimate.core.CheckedSeatSender s) { s.set(null, 2); } }'
check "self-test: the seat-off check passes onSeatOff called only from PageLinkBinder.offTap" \
    only_passes "$ST/offok/code.txt" 'ClimateCore;\.onSeatOff:' 'hkgclimate.app.PageLinkBinder.offTap:' 'Lhkgclimate/core/ClimateCore;.onSeatOff:'
check "self-test: the seat-off check flags another class calling onSeatOff" \
    only_flags "$ST/offout/code.txt" 'ClimateCore;\.onSeatOff:' 'hkgclimate.app.PageLinkBinder.offTap:' 'Lhkgclimate/core/ClimateCore;.onSeatOff:'
check "self-test: the commander check passes SeatCommander.set called from ClimateCore" \
    only_passes "$ST/cmdok/code.txt" 'SeatCommander;\.set:' 'hkgclimate.core.ClimateCore.' 'Lhkgclimate/core/SeatCommander;.set:'
check "self-test: the commander check flags PageLinkBinder calling SeatCommander.set" \
    only_flags "$ST/cmdout/code.txt" 'SeatCommander;\.set:' 'hkgclimate.core.ClimateCore.' 'Lhkgclimate/core/SeatCommander;.set:'
check "self-test: the sender check passes CheckedSeatSender.set called from a ClimateService inner class" \
    only_passes "$ST/senderok/code.txt" 'CheckedSeatSender;\.set:' 'hkgclimate.app.ClimateService$' 'Lhkgclimate/core/CheckedSeatSender;.set:'
check "self-test: the sender check flags PageLinkBinder calling CheckedSeatSender.set" \
    only_flags "$ST/senderout/code.txt" 'CheckedSeatSender;\.set:' 'hkgclimate.app.ClimateService$' 'Lhkgclimate/core/CheckedSeatSender;.set:'
check "PageStates puts the highlight key (presetActive)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.PageStates.toBundle:' '"presetActive"'
check "PageStates puts the swap key (seatSwap)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.PageStates.toBundle:' '"seatSwap"'
check "PageStates puts the off key (seatOff)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.PageStates.toBundle:' '"seatOff"'
check "the highlight check reads the cabin through CabinStateReader" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.ClimateService.highlightCheck:' 'Lhkgclimate/app/CabinStateReader;\.read:'
check "the highlight check gives the reading to ClimateCore.onHighlightCheck" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.ClimateService.highlightCheck:' 'Lhkgclimate/core/ClimateCore;\.onHighlightCheck:'
check "the highlight check uses the core's clock (SystemClock.elapsedRealtime)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.ClimateService.highlightCheck:' 'Landroid/os/SystemClock;\.elapsedRealtime:'
check "the highlight check sends nothing (no sender, runner start or tap)" \
    method_lacks_ref "$TMP/dexcode.txt" 'hkgclimate.app.ClimateService.highlightCheck:' 'CheckedSeatSender\|CheckedCabinSender\|SeatCommander\|PresetRunner;\.start:\|ClimateCore;\.onTap\|ClimateCore;\.onPresetTap\|ClimateCore;\.onSeatOff\|ClimateCore;\.onSeatSwap'
check "a page that subscribes gets one highlight check at once (onBinderChange calls highlightCheck)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.ClimateService.onBinderChange:' 'ClimateService;\.highlightCheck:'
check "that check follows the subscriber list (onBinderChange reads PageLinkBinder.hasSubscribers)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.ClimateService.onBinderChange:' 'PageLinkBinder;\.hasSubscribers:'
check "onBinderChange still keeps the poll going (updateHighlightPoll)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.ClimateService.onBinderChange:' 'ClimateService;\.updateHighlightPoll:'
check "the highlight poll runs only with a page subscribed (PageLinkBinder.hasSubscribers)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.ClimateService.updateHighlightPoll:' 'PageLinkBinder;\.hasSubscribers:'
check "the highlight poll runs only with a preset active (ClimateCore.activePreset)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.ClimateService.updateHighlightPoll:' 'Lhkgclimate/core/ClimateCore;\.activePreset:'
check "the highlight poll is posted to the main looper's Handler" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.ClimateService.updateHighlightPoll:' 'Landroid/os/Handler;\.postDelayed:'
check "the highlight poll is removed when it is not wanted" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.ClimateService.updateHighlightPoll:' 'Landroid/os/Handler;\.removeCallbacks:'
check "onDestroy removes the highlight poll" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.ClimateService.onDestroy:' 'iget-object.*ClimateService;\.highlightTick:'
check "self-test: method_has_ref sees onDestroy removing the watch check (the poll check above can see one)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.ClimateService.onDestroy:' 'iget-object.*ClimateService;\.watchCheck:'

# the settings and editor screens fit beside the side panel; dialog-mode dropdowns; both
# temperatures; Save never crashes on finish()
# method_ref_count_ge <dexdump -d output> <class.method:> <ref> <n>: that method's code refers to <ref> on at least <n> lines
method_ref_count_ge() {
    [ "$(awk -v m="$2" 'index($0, "] " m) { on = 1; next } on && /\|\[/ { on = 0 } on' "$1" | grep -c "$3")" -ge "$4" ]
}
# finish_guarded <dexdump -d output> <class.method:> <text>: the method calls finish(), and every
# call is inside a try range whose handler (the 64 code units after it starts) sets the text <text>
finish_guarded() {
    awk -v want="$2" -v str="$3" '
        function hex(s,   i, n) {
            sub(/^0x/, "", s); n = 0
            for (i = 1; i <= length(s); i++) n = n * 16 + index("0123456789abcdef", substr(s, i, 1)) - 1
            return n
        }
        BEGIN { nf = 0; ns = 0; nr = 0 }
        /Class descriptor/ { meth = "" }
        /\|\[[0-9a-f]+\] / { m = $0; sub(/.*\|\[[0-9a-f]+\] /, "", m); meth = m; next }
        index(meth, want) != 1 { next }
        match($0, /\|[0-9a-f]+: /) {
            addr = hex(substr($0, RSTART + 1, RLENGTH - 3))
            if (index($0, "invoke-") && index($0, ".finish:()V")) fin[nf++] = addr
            if (index($0, "const-string") && index($0, "\"" str "\"")) saved[ns++] = addr
            next
        }
        /^ +0x[0-9a-f]+ - 0x[0-9a-f]+$/ { lo = hex($1); hi = hex($3); next }
        /-> 0x[0-9a-f]+/ { h = $0; sub(/.*-> /, "", h); rl[nr] = lo; rh[nr] = hi; rt[nr] = hex(h); nr++ }
        END {
            if (nf == 0) exit 1
            for (i = 0; i < nf; i++) {
                ok = 0
                for (j = 0; j < nr; j++) {
                    if (fin[i] < rl[j] || fin[i] >= rh[j]) continue
                    for (k = 0; k < ns; k++) if (saved[k] >= rt[j] && saved[k] < rt[j] + 64) ok = 1
                }
                if (!ok) exit 1
            }
            exit 0
        }' "$1"
}
# closes_guarded <dexdump -d output> <class>: the class and its inner classes call finish() or
# Activity.onBackPressed() at least once, and every such call is inside a try range of its own method
closes_guarded() {
    awk -v cls="$2" '
        function hex(s,   i, n) {
            sub(/^0x/, "", s); n = 0
            for (i = 1; i <= length(s); i++) n = n * 16 + index("0123456789abcdef", substr(s, i, 1)) - 1
            return n
        }
        BEGIN { nf = 0; nr = 0 }
        /Class descriptor/ { meth = "" }
        /\|\[[0-9a-f]+\] / { m = $0; sub(/.*\|\[[0-9a-f]+\] /, "", m); meth = m; next }
        index(meth, cls ".") != 1 && index(meth, cls "$") != 1 { next }
        match($0, /\|[0-9a-f]+: /) {
            if (index($0, "invoke-") && ($0 ~ /;\.finish[A-Za-z]*:\(/ || $0 ~ /Landroid\/app\/Activity;\.onBackPressed:\(/)) {
                fm[nf] = meth; fa[nf] = hex(substr($0, RSTART + 1, RLENGTH - 3)); nf++
            }
            next
        }
        /^ +0x[0-9a-f]+ - 0x[0-9a-f]+$/ { lo = hex($1); hi = hex($3); next }
        /-> 0x[0-9a-f]+/ { rm[nr] = meth; rl[nr] = lo; rh[nr] = hi; nr++ }
        END {
            if (nf == 0) exit 1
            for (i = 0; i < nf; i++) {
                ok = 0
                for (j = 0; j < nr; j++) if (rm[j] == fm[i] && fa[i] >= rl[j] && fa[i] < rh[j]) ok = 1
                if (!ok) exit 1
            }
            exit 0
        }' "$1"
}
scratch_dex spin1 PresetEditorActivity 'package hkgclimate.app; class PresetEditorActivity { void go(android.content.Context c) { new android.widget.Spinner(c); } }'
scratch_dex spin2 PresetEditorActivity 'package hkgclimate.app; class PresetEditorActivity { void go(android.content.Context c) { new android.widget.Spinner(c, android.widget.Spinner.MODE_DIALOG); } }'
scratch_dex spin3 PresetEditorActivity 'package hkgclimate.app; class PresetEditorActivity { void go(android.content.Context c) { new android.widget.TextView(c); } }'
scratch_dex cs_ok ChoiceSpinner 'package hkgclimate.app; class ChoiceSpinner extends android.widget.Spinner { ChoiceSpinner(android.content.Context c) { super(c, android.widget.Spinner.MODE_DIALOG); } @Override public boolean performClick() { if (!isEnabled()) return false; new android.app.AlertDialog.Builder(getContext()).setSingleChoiceItems(new String[0], 0, null).create().show(); return true; } }'
scratch_dex cs_bad ChoiceSpinner 'package hkgclimate.app; class ChoiceSpinner extends android.widget.Spinner { ChoiceSpinner(android.content.Context c) { super(c); } @Override public boolean performClick() { return super.performClick(); } }'
scratch_dex fin_ok PresetEditorActivity 'package hkgclimate.app; class PresetEditorActivity extends android.app.Activity { android.widget.TextView error; void save() { try { finish(); } catch (Throwable t) { error.setText("Saved"); } } }'
scratch_dex fin_bare PresetEditorActivity 'package hkgclimate.app; class PresetEditorActivity extends android.app.Activity { android.widget.TextView error; void save() { error.setText("Saved"); finish(); } }'
scratch_dex fin_quiet PresetEditorActivity 'package hkgclimate.app; class PresetEditorActivity extends android.app.Activity { android.widget.TextView error; void save() { error.setText("Saved"); try { finish(); } catch (Throwable t) { error.setText("failed"); } } }'
scratch_dex fin_none PresetEditorActivity 'package hkgclimate.app; class PresetEditorActivity extends android.app.Activity { android.widget.TextView error; void save() { try { error.setText("x"); } catch (Throwable t) { error.setText("Saved"); } } }'
scratch_dex cl_ok PresetEditorActivity 'package hkgclimate.app; class PresetEditorActivity extends android.app.Activity { void close() { try { finish(); } catch (Throwable t) { } } @Override public void onBackPressed() { try { super.onBackPressed(); } catch (Throwable t) { } } class Cancel { void go() { close(); } } }'
scratch_dex cl_finish PresetEditorActivity 'package hkgclimate.app; class PresetEditorActivity extends android.app.Activity { void close() { try { finish(); } catch (Throwable t) { } } void onCancel() { finish(); } @Override public void onBackPressed() { try { super.onBackPressed(); } catch (Throwable t) { } } }'
scratch_dex cl_back PresetEditorActivity 'package hkgclimate.app; class PresetEditorActivity extends android.app.Activity { void close() { try { finish(); } catch (Throwable t) { } } @Override public void onBackPressed() { super.onBackPressed(); } }'
scratch_dex cl_inner PresetEditorActivity 'package hkgclimate.app; class PresetEditorActivity extends android.app.Activity { void close() { try { finish(); } catch (Throwable t) { } } class Cancel implements Runnable { public void run() { PresetEditorActivity.this.finish(); } } }'
scratch_dex cl_none PresetEditorActivity 'package hkgclimate.app; class PresetEditorActivity extends android.app.Activity { void go() { try { setTitle("x"); } catch (Throwable t) { } } }'
scratch_dex cl_set SettingsActivity 'package hkgclimate.app; class SettingsActivity extends android.app.Activity { @Override public void onBackPressed() { try { super.onBackPressed(); } catch (Throwable t) { } } }'
scratch_dex cl_setbad SettingsActivity 'package hkgclimate.app; class SettingsActivity extends android.app.Activity { @Override public void onBackPressed() { super.onBackPressed(); } }'
scratch_dex lis1 PresetEditorActivity 'package hkgclimate.app; class PresetEditorActivity { void save(android.widget.Spinner a, android.widget.Spinner b, android.widget.AdapterView.OnItemSelectedListener l) { a.setOnItemSelectedListener(l); } }'
scratch_dex lis2 PresetEditorActivity 'package hkgclimate.app; class PresetEditorActivity { void save(android.widget.Spinner a, android.widget.Spinner b, android.widget.AdapterView.OnItemSelectedListener l) { a.setOnItemSelectedListener(l); b.setOnItemSelectedListener(l); } }'

check "the editor builds each dropdown as a ChoiceSpinner" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.PresetEditorActivity.itemSpinner:' 'Lhkgclimate/app/ChoiceSpinner;\.<init>:(Landroid/content/Context;Ljava/lang/String;\[Ljava/lang/String;)V'
check "the editor never builds a platform Spinner itself (any constructor)" \
    code_lacks_ref "$TMP/dexcode.txt" 'hkgclimate.app.PresetEditorActivity' 'Landroid/widget/Spinner;.<init>'
check "self-test: the no-platform-Spinner check flags a one-argument Spinner in the editor" \
    fails code_lacks_ref "$ST/spin1/code.txt" 'hkgclimate.app.PresetEditorActivity' 'Landroid/widget/Spinner;.<init>'
check "self-test: the no-platform-Spinner check flags a dialog-mode Spinner in the editor" \
    fails code_lacks_ref "$ST/spin2/code.txt" 'hkgclimate.app.PresetEditorActivity' 'Landroid/widget/Spinner;.<init>'
check "self-test: the no-platform-Spinner check passes an editor without one" \
    code_lacks_ref "$ST/spin3/code.txt" 'hkgclimate.app.PresetEditorActivity' 'Landroid/widget/Spinner;.<init>'
check "ChoiceSpinner is a Spinner that falls back to dialog mode (Spinner(Context, int))" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.ChoiceSpinner.<init>:' 'Landroid/widget/Spinner;\.<init>:(Landroid/content/Context;I)V'
check "ChoiceSpinner never uses the drop-down mode constructor" \
    code_lacks_ref "$TMP/dexcode.txt" 'hkgclimate.app.ChoiceSpinner' 'Landroid/widget/Spinner;.<init>:(Landroid/content/Context;)V'
check "ChoiceSpinner opens a single-choice list in our own AlertDialog (scrollable)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.ChoiceSpinner.performClick:' 'AlertDialog\$Builder;\.setSingleChoiceItems:'
check "ChoiceSpinner shows the dialog" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.ChoiceSpinner.performClick:' 'AlertDialog;\.show:()V'
check "ChoiceSpinner places the dialog in the column (Column.place)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.ChoiceSpinner.performClick:' 'Lhkgclimate/app/Column;\.place:'
check "ChoiceSpinner opens nothing when disabled (isEnabled is read in performClick)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.ChoiceSpinner.performClick:' '\.isEnabled:()Z'
check "ChoiceSpinner does not fall back to the platform popup (no Spinner.performClick call)" \
    method_lacks_ref "$TMP/dexcode.txt" 'hkgclimate.app.ChoiceSpinner.performClick:' 'Landroid/widget/Spinner;\.performClick'
check "ChoiceSpinner closes its dialog when the view leaves the window" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.ChoiceSpinner.onDetachedFromWindow:' 'ChoiceSpinner;\.dismissDialog:'
check "ChoiceSpinner.dismissDialog dismisses the dialog" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.ChoiceSpinner.dismissDialog:' '\.dismiss:()V'
check "self-test: the dialog-mode constructor check passes the good scratch class" \
    method_has_ref "$ST/cs_ok/code.txt" 'hkgclimate.app.ChoiceSpinner.<init>:' 'Landroid/widget/Spinner;\.<init>:(Landroid/content/Context;I)V'
check "self-test: the list check passes the good scratch class" \
    method_has_ref "$ST/cs_ok/code.txt" 'hkgclimate.app.ChoiceSpinner.performClick:' 'AlertDialog\$Builder;\.setSingleChoiceItems:'
check "self-test: the show check passes the good scratch class" \
    method_has_ref "$ST/cs_ok/code.txt" 'hkgclimate.app.ChoiceSpinner.performClick:' 'AlertDialog;\.show:()V'
check "self-test: the disabled check passes the good scratch class" \
    method_has_ref "$ST/cs_ok/code.txt" 'hkgclimate.app.ChoiceSpinner.performClick:' '\.isEnabled:()Z'
check "self-test: the disabled check fails the bad scratch class" \
    fails method_has_ref "$ST/cs_bad/code.txt" 'hkgclimate.app.ChoiceSpinner.performClick:' '\.isEnabled:()Z'
check "self-test: the drop-down constructor check passes the good scratch class" \
    code_lacks_ref "$ST/cs_ok/code.txt" 'hkgclimate.app.ChoiceSpinner' 'Landroid/widget/Spinner;.<init>:(Landroid/content/Context;)V'
check "self-test: the dialog-mode constructor check fails the bad scratch class" \
    fails method_has_ref "$ST/cs_bad/code.txt" 'hkgclimate.app.ChoiceSpinner.<init>:' 'Landroid/widget/Spinner;\.<init>:(Landroid/content/Context;I)V'
check "self-test: the drop-down constructor check flags the bad scratch class" \
    fails code_lacks_ref "$ST/cs_bad/code.txt" 'hkgclimate.app.ChoiceSpinner' 'Landroid/widget/Spinner;.<init>:(Landroid/content/Context;)V'
check "self-test: the list check fails the bad scratch class (no AlertDialog list)" \
    fails method_has_ref "$ST/cs_bad/code.txt" 'hkgclimate.app.ChoiceSpinner.performClick:' 'AlertDialog\$Builder;\.setSingleChoiceItems:'
check "self-test: the platform-popup check flags the bad scratch class (it calls Spinner.performClick)" \
    fails method_lacks_ref "$ST/cs_bad/code.txt" 'hkgclimate.app.ChoiceSpinner.performClick:' 'Landroid/widget/Spinner;\.performClick'

check "the editor has a driver temperature dropdown (item name for the greying)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.PresetEditorActivity.buildViews:' 'const-string.*"driverTemp"'
check "the editor has a passenger temperature dropdown (item name for the greying)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.PresetEditorActivity.buildViews:' 'const-string.*"passengerTemp"'
check "the editor titles the driver temperature" dex_has_string "$TMP/classes.dex" "Driver temperature"
check "the editor titles the passenger temperature" dex_has_string "$TMP/classes.dex" "Passenger temperature"
check "the editor greys by climate and by sync (PresetChoices.greyed takes the item, climate and sync)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.PresetEditorActivity.applyGreying:' 'PresetChoices;\.greyed:(Ljava/lang/String;II)Z'
check "the editor re-applies the greying when the climate or the sync changes (two listeners set)" \
    method_ref_count_ge "$TMP/dexcode.txt" 'hkgclimate.app.PresetEditorActivity.buildViews:' 'Spinner;\.setOnItemSelectedListener' 2
check "the greying listener calls back into the editor (the accessor of the private applyGreying)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.PresetEditorActivity$1.onItemSelected:' 'PresetEditorActivity;\.access\$000:'
check "that accessor reaches applyGreying" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.PresetEditorActivity.access$000:' 'PresetEditorActivity;\.applyGreying:'
check "self-test: the listener count passes two listeners" \
    method_ref_count_ge "$ST/lis2/code.txt" 'hkgclimate.app.PresetEditorActivity.save:' 'Spinner;\.setOnItemSelectedListener' 2
check "self-test: the listener count fails on one listener" \
    fails method_ref_count_ge "$ST/lis1/code.txt" 'hkgclimate.app.PresetEditorActivity.save:' 'Spinner;\.setOnItemSelectedListener' 2

check "Save: finish() is inside a try whose handler sets the text Saved" \
    finish_guarded "$TMP/dexcode.txt" 'hkgclimate.app.PresetEditorActivity.save:' Saved
check "Save: the finish handler logs the error (Log.w with a Throwable)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.PresetEditorActivity.save:' 'Landroid/util/Log;\.w:(Ljava/lang/String;Ljava/lang/String;Ljava/lang/Throwable;)I'
check "self-test: finish_guarded passes a guarded finish with a Saved handler" \
    finish_guarded "$ST/fin_ok/code.txt" 'hkgclimate.app.PresetEditorActivity.save:' Saved
check "self-test: finish_guarded fails an unguarded finish" \
    fails finish_guarded "$ST/fin_bare/code.txt" 'hkgclimate.app.PresetEditorActivity.save:' Saved
check "self-test: finish_guarded fails a guarded finish whose handler does not say Saved" \
    fails finish_guarded "$ST/fin_quiet/code.txt" 'hkgclimate.app.PresetEditorActivity.save:' Saved
check "self-test: finish_guarded fails a method with no finish at all" \
    fails finish_guarded "$ST/fin_none/code.txt" 'hkgclimate.app.PresetEditorActivity.save:' Saved
check "self-test: finish_guarded fails a listing with no such method" \
    fails finish_guarded "$ST/fin_ok/code.txt" 'hkgclimate.app.PresetEditorActivity.nothere:' Saved

check "the editor closes only inside a try (every finish() and Back call, inner classes too)" \
    closes_guarded "$TMP/dexcode.txt" hkgclimate.app.PresetEditorActivity
check "the editor overrides Back (onBackPressed calls the Activity's, guarded above)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.PresetEditorActivity.onBackPressed:' 'Landroid/app/Activity;\.onBackPressed:'
check "the settings screen's Back is inside a try (every finish() and Back call)" \
    closes_guarded "$TMP/dexcode.txt" hkgclimate.app.SettingsActivity
check "the settings screen overrides Back (onBackPressed calls the Activity's)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.SettingsActivity.onBackPressed:' 'Landroid/app/Activity;\.onBackPressed:'
check "self-test: closes_guarded passes guarded finish, Back and an inner class closing through the helper" \
    closes_guarded "$ST/cl_ok/code.txt" hkgclimate.app.PresetEditorActivity
check "self-test: closes_guarded fails an unguarded finish() in another method" \
    fails closes_guarded "$ST/cl_finish/code.txt" hkgclimate.app.PresetEditorActivity
check "self-test: closes_guarded fails an unguarded Back" \
    fails closes_guarded "$ST/cl_back/code.txt" hkgclimate.app.PresetEditorActivity
check "self-test: closes_guarded fails an unguarded finish() in an inner class" \
    fails closes_guarded "$ST/cl_inner/code.txt" hkgclimate.app.PresetEditorActivity
check "self-test: closes_guarded fails a class with no close call at all" \
    fails closes_guarded "$ST/cl_none/code.txt" hkgclimate.app.PresetEditorActivity
check "self-test: closes_guarded passes a guarded settings Back" \
    closes_guarded "$ST/cl_set/code.txt" hkgclimate.app.SettingsActivity
check "self-test: closes_guarded fails an unguarded settings Back" \
    fails closes_guarded "$ST/cl_setbad/code.txt" hkgclimate.app.SettingsActivity

check "the settings screen goes through the narrow column (Column.wrap)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.SettingsActivity.buildViews:' 'Lhkgclimate/app/Column;\.wrap:'
check "the editor goes through the narrow column (Column.wrap)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.PresetEditorActivity.buildViews:' 'Lhkgclimate/app/Column;\.wrap:'
check "the column is left-aligned (layout params with a gravity in the scroll view)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.Column.wrap:' 'FrameLayout\$LayoutParams;\.<init>:(III)V'
check "the column is never wider than the screen (Math.min in widthPx)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.Column.widthPx:' 'Ljava/lang/Math;\.min:(II)I'
check "the preset buttons share the row's width (weighted LinearLayout.LayoutParams)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.SettingsActivity.addToRow:' 'LinearLayout\$LayoutParams;\.<init>:(IIF)V'
check "dialogs are sized by Window.setLayout in Column.place" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.Column.place:' 'Landroid/view/Window;\.setLayout:(II)V'
check "dialogs are put at the left edge (Window.setGravity in Column.place)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.Column.place:' 'Landroid/view/Window;\.setGravity:(I)V'
check "a dialog's width comes from the column (Column.place uses widthPx)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.Column.place:' 'Lhkgclimate/app/Column;\.widthPx:'
check "the delete confirm places its dialog in the column (Column.place)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.SettingsActivity.confirmDelete:' 'Lhkgclimate/app/Column;\.place:'
check "Add preset is limited at six (refreshPresets compares the list size with 6)" \
    method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.SettingsActivity.refreshPresets:' '#int 6 '
check "self-test: the limit check does not see a 7 in refreshPresets" \
    fails method_has_ref "$TMP/dexcode.txt" 'hkgclimate.app.SettingsActivity.refreshPresets:' '#int 7 '

if [ "$FAILS" -ne 0 ]; then echo "$FAILS check(s) failed"; exit 1; fi
echo "all checks passed"
