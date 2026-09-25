#!/usr/bin/env bash
#
# Package the device build into an IPA.
#
# The same steps the project Makefile's `iphoneos` target runs, with one
# correction: the bundle now contains a nested widget extension, and signing
# only the outer app leaves the extension with an invalid signature — which is
# exactly what makes a sideloaded app install without its Live Activity.
# Extensions are signed first, then the app.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

NAME="BatSign"
STAGE="${TMPDIR:-/tmp}/BatSign-device"
IPS="${1:-build/BatSign.ipa}"

echo "==> clean"
rm -rf _build
# packages/LicensePlist is vendored on purpose: its binary artifact used to be
# downloaded from a GitHub release whose asset is gone (HTTP 404), which is
# exactly the build-time network dependency this script no longer has. The
# directory is preserved here and never fetched.
mkdir -p packages

echo "==> resolve dependencies (TLS material for the install server)"
if [ -f deps/server.crt ] && [ -f deps/server.pem ] && [ -f deps/commonName.txt ]; then
  echo "    deps/ already present"
else
  echo "    fetching from backloop.dev"
  rm -rf deps && mkdir -p deps
  curl -fsSL "https://backloop.dev/pack.json" -o /tmp/batsign-cert.json
  jq -r '.cert' /tmp/batsign-cert.json > deps/server.crt
  jq -r '{key1, key2} | .key1, .key2' /tmp/batsign-cert.json > deps/server.pem
  jq -r '.info.domains.commonName' /tmp/batsign-cert.json > deps/commonName.txt
fi

echo "==> build (Release, device, unsigned)"
xcodebuild \
  -project Feather.xcodeproj \
  -scheme Feather \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$STAGE" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=NO \
  build

APP="_build/Applications/${NAME}.app"
if [ ! -d "$APP" ]; then
  echo "!! expected $APP to exist" >&2
  exit 1
fi

# The TLS material and the signature go on the build product itself, not on a
# copy of it: the app at this path is the deliverable that gets run, and an
# unsigned bundle without the server's certificate cannot start the install
# server that hands a signed app to the system.
echo "==> embed install-server TLS material"
cp deps/server.crt deps/server.pem deps/commonName.txt "$APP/"

echo "==> sign (extensions first, then the app)"
while IFS= read -r -d '' nested; do
  codesign --force --sign - --timestamp=none "$nested"
  echo "    signed $nested"
done < <(find "$APP/PlugIns" "$APP/Frameworks" -mindepth 1 -maxdepth 1 -print0 2>/dev/null || true)

codesign --force --sign - --timestamp=none "$APP"

echo "==> stage payload"
mkdir -p _build/Payload
rm -rf "_build/Payload/${NAME}.app"
ditto "$APP" "_build/Payload/${NAME}.app"
chmod -R 0755 "_build/Payload/${NAME}.app"
PAYLOAD="_build/Payload/${NAME}.app"

echo "==> package"
mkdir -p "$(dirname "$IPS")"
rm -f "$IPS"
ditto -c -k --sequesterRsrc --keepParent "_build/Payload" "$IPS"

echo "==> verify"
unzip -t "$IPS" >/dev/null && echo "    archive OK"
codesign --verify --deep "$APP" 2>&1 && echo "    deliverable signature OK"
ls "$APP/server.crt" "$APP/server.pem" "$APP/commonName.txt" >/dev/null && echo "    deliverable has install-server TLS material"
plutil -p "$PAYLOAD/Info.plist" | grep -E "CFBundleIdentifier|CFBundleShortVersionString|CFBundleDisplayName" | sed 's/^/    /'
ls -la "$IPS"
shasum -a 256 "$IPS"
