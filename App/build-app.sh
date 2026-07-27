#!/bin/bash
#
# Assembles YunAudio.app around the SwiftPM executable.
#
# SwiftPM produces a bare binary; a menu bar accessory needs a bundle so that
# LSUIElement and the microphone usage strings are read, and so TCC can attribute
# the permission prompt to this app rather than to whatever launched it.
#
#   ./build-app.sh              debug build
#   ./build-app.sh --release    optimised build
#   ./build-app.sh --run        build, then launch
#
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="debug"
LAUNCH=0
for argument in "$@"; do
	case "${argument}" in
	--release) CONFIGURATION="release" ;;
	--run) LAUNCH=1 ;;
	esac
done

echo "building (${CONFIGURATION})…"
swift build -c "${CONFIGURATION}" --product YunAudioApp

BINARY=".build/${CONFIGURATION}/YunAudioApp"
BUNDLE="build/YunAudio.app"

rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
cp App/Info.plist "${BUNDLE}/Contents/Info.plist"
cp "${BINARY}" "${BUNDLE}/Contents/MacOS/YunAudioApp"

# The driver travels inside the bundle so the app can offer to install it.
if [[ -d "Driver/build/YunAudioDriver.driver" ]]; then
	cp -R Driver/build/YunAudioDriver.driver "${BUNDLE}/Contents/Resources/"
fi

# Ad-hoc signature with the audio-input entitlement. Distribution needs a real
# Developer ID identity and notarisation; this is enough for the TCC prompt to
# work locally.
cat >build/yunaudio.entitlements <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.device.audio-input</key>
	<true/>
</dict>
</plist>
PLIST

echo "signing…"
codesign --force --sign - \
	--entitlements build/yunaudio.entitlements \
	--options runtime \
	"${BUNDLE}"

echo "built ${BUNDLE}"

if [[ "${LAUNCH}" == "1" ]]; then
	# Replace any running copy so the new binary is the one under test.
	pkill -f "YunAudio.app/Contents/MacOS/YunAudioApp" 2>/dev/null || true
	open "${BUNDLE}"
	echo "launched — look for the waveform in the menu bar"
fi
