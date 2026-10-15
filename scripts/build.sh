#!/usr/bin/env bash
# Builds ShotKeys.app (universal: arm64 + x86_64) into ./build and code-signs it.
#
#   scripts/build.sh          build release
#   scripts/build.sh --run    build, quit any running copy, and launch
#
# Signing identity, in order of preference:
#   1. $SHOTKEYS_SIGN_IDENTITY
#   2. an "Apple Development" identity in your keychain
#   3. the self-signed "ShotKeys Local Signing" identity (scripts/create_signing_cert.sh)
#   4. ad-hoc ("-"): works, but macOS forgets Input Monitoring access after every rebuild
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/ShotKeys.app"
BUNDLE_ID="com.milanrayat.ShotKeys"
cd "$ROOT"

if ! ls Resources/Sounds/*.wav >/dev/null 2>&1; then
  echo "==> No sounds found, generating placeholders"
  python3 scripts/generate_sounds.py
fi

echo "==> Compiling (arm64 + x86_64)"
BINARIES=()
for ARCH in arm64 x86_64; do
  swift build -c release --triple "$ARCH-apple-macosx13.0" --scratch-path "$ROOT/.build/$ARCH" >/dev/null
  BINARIES+=("$ROOT/.build/$ARCH/$ARCH-apple-macosx/release/ShotKeys")
done

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Sounds"
lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/ShotKeys"
cp Resources/Info.plist "$APP/Contents/Info.plist"
find Resources/Sounds -maxdepth 1 -type f \( -iname '*.wav' -o -iname '*.aif' -o -iname '*.aiff' \
  -o -iname '*.caf' -o -iname '*.mp3' -o -iname '*.m4a' -o -name 'LICENSES.md' \) \
  -exec cp {} "$APP/Contents/Resources/Sounds/" \;

IDENTITY="${SHOTKEYS_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)"
fi
if [[ -z "$IDENTITY" ]] && security find-certificate -c "ShotKeys Local Signing" >/dev/null 2>&1; then
  IDENTITY="ShotKeys Local Signing"
fi
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="-"
  echo "!! No stable signing identity found; signing ad-hoc."
  echo "!! macOS will ask for Input Monitoring again after each rebuild."
  echo "!! Run scripts/create_signing_cert.sh once to fix this (see README)."
fi

echo "==> Signing with: $IDENTITY"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "==> Built $APP ($(lipo -archs "$APP/Contents/MacOS/ShotKeys"))"

if [[ "${1:-}" == "--run" ]]; then
  pkill -x ShotKeys 2>/dev/null && sleep 0.5 || true
  open "$APP"
  echo "==> Launched. Look for the icon in the menu bar."
fi
