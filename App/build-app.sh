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
#   ./build-app.sh --verify     build, then prove the bundle is self-contained
#
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="debug"
LAUNCH=0
VERIFY=0
for argument in "$@"; do
	case "${argument}" in
	--release) CONFIGURATION="release" ;;
	--run) LAUNCH=1 ;;
	--verify) VERIFY=1 ;;
	esac
done

echo "building (${CONFIGURATION})…"
swift build -c "${CONFIGURATION}" --product YunAudioApp

BINARY=".build/${CONFIGURATION}/YunAudioApp"
BUNDLE="build/YunAudio.app"

rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
./App/make-icon.sh >/dev/null
cp build/YunAudio.icns "${BUNDLE}/Contents/Resources/"

# The SwiftPM resource bundle carries the icon and both string tables, and
# nothing was copying it in. `Bundle.module` falls back to the build directory
# when it cannot find the bundle beside the executable, so the app worked
# perfectly on this machine and would have shipped with no icon and no
# translations at all — a defect only visible on somebody else's Mac.
MODULE_BUNDLE=".build/${CONFIGURATION}/YunAudioKit_YunAudioApp.bundle"
if [[ ! -d "${MODULE_BUNDLE}" ]]; then
	echo "error: ${MODULE_BUNDLE} is missing — the app would ship untranslated" >&2
	exit 1
fi
cp -R "${MODULE_BUNDLE}" "${BUNDLE}/Contents/Resources/"
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

if [[ "${VERIFY}" == "1" ]]; then
	# The one check that matters for shipping, and the only one that can find
	# this class of defect: run a copy of the app with the build tree moved out
	# of reach. SwiftPM's `Bundle.module` quietly falls back to the build
	# directory, so an app missing its resource bundle entirely works on the
	# machine that built it and dies on launch everywhere else.
	echo "verifying the bundle is self-contained…"
	ISOLATED="$(mktemp -d)"
	cp -R "${BUNDLE}" "${ISOLATED}/"
	mv .build "${ISOLATED}/.build-hidden"
	set +e
	YUNAUDIO_FLOWCHECK=1 "${ISOLATED}/YunAudio.app/Contents/MacOS/YunAudioApp" \
		>"${ISOLATED}/out.txt" 2>&1
	STATUS=$?
	set -e
	mv "${ISOLATED}/.build-hidden" .build
	if [[ "${STATUS}" != "0" ]]; then
		echo "error: the app is not self-contained" >&2
		head -5 "${ISOLATED}/out.txt" >&2
		rm -rf "${ISOLATED}"
		exit 1
	fi
	grep -E "keys in each table" "${ISOLATED}/out.txt" || true
	rm -rf "${ISOLATED}"
	echo "self-contained: it runs with the build tree out of reach"
fi

if [[ "${LAUNCH}" == "1" ]]; then
	# Replace any running copy so the new binary is the one under test.
	pkill -f "YunAudio.app/Contents/MacOS/YunAudioApp" 2>/dev/null || true
	open "${BUNDLE}"
	echo "launched — look for the waveform in the menu bar"
fi
