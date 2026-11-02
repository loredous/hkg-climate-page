#!/bin/sh
# Build the signed app APK: compile core/src, link/src and app/src (against the stock-name stubs,
# which are never packaged), dex them, package with the manifest, zipalign and sign (v1 only).
# usage: tools/build-app.sh           writes build/app/hkgclimate.apk and prints its path
# environment: VERSION_NAME (default 1.2.1), VERSION_CODE (default 7). aapt only fills these in
# when the manifest has none; app/AndroidManifest.xml sets both, so keep the two in step.
# The signing key is private/keys/hkgclimate.jks (alias hkgclimate), created on the first run with
# a random password in private/keys/password. Keep the key: an update must be signed with it.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
eval "$("$ROOT/tools/toolchain.sh" env)"
cd "$ROOT"
VERSION_NAME=${VERSION_NAME:-1.2.1}
VERSION_CODE=${VERSION_CODE:-7}

OUT=build/app
rm -rf "$OUT" build/stubs
mkdir -p "$OUT/classes" build/stubs

# the stubs declare the stock class names we call; javac class path only
# shellcheck disable=SC2046 # one path per word; none contain spaces
javac -encoding UTF-8 --release 8 -Xlint:-options -cp "$ANDROID_JAR" -d build/stubs \
    $(find stubs/hkmc/src -name '*.java' | sort)

# shellcheck disable=SC2046
javac -encoding UTF-8 -source 8 -target 8 -Xlint:-options -bootclasspath "$ANDROID_JAR" \
    -cp build/stubs -d "$OUT/classes" \
    $(find core/src link/src app/src -name '*.java' | sort)

# dex only our own classes (never build/stubs)
# shellcheck disable=SC2046
"$BUILD_TOOLS/d8" --min-api 19 --lib "$ANDROID_JAR" --classpath build/stubs --output "$OUT" \
    $(find "$OUT/classes" -name '*.class' | sort)

"$BUILD_TOOLS/aapt" package -f -M app/AndroidManifest.xml -I "$ANDROID_JAR" \
    --version-name "$VERSION_NAME" --version-code "$VERSION_CODE" -F "$OUT/unsigned.apk"
(cd "$OUT" && "$BUILD_TOOLS/aapt" add -k unsigned.apk classes.dex > /dev/null)
"$BUILD_TOOLS/zipalign" -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

# first run (both files missing): make the signing key, with a random password nobody has to see.
# The key can't be replaced, so one file without the other is an error and nothing is touched.
KEYS=private/keys
if [ -f "$KEYS/hkgclimate.jks" ] && [ ! -f "$KEYS/password" ]; then
    echo "error: $KEYS/password is missing. The existing key $KEYS/hkgclimate.jks was left alone." >&2
    echo "Restore the password file (the key can't be replaced; updates need it)." >&2
    exit 1
fi
if [ ! -f "$KEYS/hkgclimate.jks" ] && [ -f "$KEYS/password" ]; then
    echo "error: $KEYS/hkgclimate.jks is missing. The existing $KEYS/password was left alone." >&2
    echo "Restore the key file (the key can't be replaced; updates need it)." >&2
    exit 1
fi
if [ ! -f "$KEYS/hkgclimate.jks" ]; then
    (umask 077 && mkdir -p "$KEYS" \
        && { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | dd bs=32 count=1 2> /dev/null; echo; } > "$KEYS/password")
    if ! keytool -genkeypair -keystore "$KEYS/hkgclimate.jks" -storetype JKS -alias hkgclimate \
        -keyalg RSA -keysize 2048 -validity 10950 -dname "CN=hkg-climate-page" \
        -storepass:file "$KEYS/password" > "$OUT/keytool.log" 2>&1; then
        cat "$OUT/keytool.log" >&2
        echo "error: keytool failed; removing the half-made $KEYS/password" >&2
        rm -f "$KEYS/password" "$KEYS/hkgclimate.jks"
        exit 1
    fi
    rm -f "$OUT/keytool.log"
fi
chmod 600 "$KEYS/hkgclimate.jks" "$KEYS/password"

"$BUILD_TOOLS/apksigner" sign --ks "$KEYS/hkgclimate.jks" --ks-key-alias hkgclimate \
    --ks-pass "file:$KEYS/password" \
    --v1-signing-enabled true --v2-signing-enabled false --min-sdk-version 19 \
    --out "$OUT/hkgclimate.apk" "$OUT/aligned.apk"
rm -f "$OUT/unsigned.apk" "$OUT/aligned.apk" "$OUT/hkgclimate.apk.idsig"
echo "$OUT/hkgclimate.apk"
