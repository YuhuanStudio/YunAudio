#!/bin/bash
#
# Assembles YunAudio.app around the SwiftPM executable.
#
# SwiftPM produces a bare binary; a menu bar accessory needs a bundle so that
# LSUIElement and the microphone usage strings are read, and so TCC can attribute
# the permission prompt to this app rather than to whatever launched it.
#
#   ./build-app.sh              optimised build
#   ./build-app.sh --debug      unoptimised diagnostic build
#   ./build-app.sh --release    explicitly select the optimised build
#   ./build-app.sh --run        build, then launch
#   ./build-app.sh --verify     build, then prove the bundle is self-contained
#
set -euo pipefail

cd "$(dirname "$0")/.."

# Ensures the SDK is new enough; see the script for why.
source ./App/toolchain.sh

CONFIGURATION="release"
LAUNCH=0
VERIFY=0
for argument in "$@"; do
	case "${argument}" in
	--debug) CONFIGURATION="debug" ;;
	--release) CONFIGURATION="release" ;;
	--run) LAUNCH=1 ;;
	--verify) VERIFY=1 ;;
	esac
done

echo "building (${CONFIGURATION})…"
swift build -c "${CONFIGURATION}" --product YunAudioApp

BINARY=".build/${CONFIGURATION}/YunAudioApp"
BUNDLE="${YUNAUDIO_APP_BUNDLE:-build/YunAudio.app}"

# Never overwrite a bundle somebody is running.
#
# **This is not tidiness, it is a crash.** A running process has its text pages
# mapped straight from the executable file; deleting and rewriting that file
# under it leaves the mapping pointing at whatever is there now, and the process
# faults on the next thing it touches. It looks nothing like a build problem:
# two reports came in reading `EXC_BAD_ACCESS at 0x1e`, one inside a `Canvas`
# draw closure and one inside a twenty-hertz timer, both in
# `swift_task_isCurrentExecutor` — a plausible-looking concurrency fault in two
# unrelated places, which is exactly what a rewritten binary looks like and is
# not what it was. The same commit ran the flow check clean twice afterwards.
#
# Refused rather than warned about, because the failure lands minutes later in
# somebody else's session and reads as a defect in the code being written.
if [[ -z "${YUNAUDIO_ALLOW_OVERWRITE_RUNNING:-}" ]] && pgrep -qx YunAudioApp; then
	cat >&2 <<'RUNNING'
YunAudio is running, and rebuilding the bundle would overwrite the executable
underneath it. That does not fail cleanly — the running copy segfaults somewhere
unrelated a minute or two later.

Quit it and build again. To build anyway (a copy running from elsewhere, say):

  YUNAUDIO_ALLOW_OVERWRITE_RUNNING=1 ./App/build-app.sh
RUNNING
	exit 1
fi

rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
# The icon is drawn by the binary that was just built, so it has to be told
# which one — asking for the debug build here during a release build would
# compile a second copy of the whole application to draw a picture.
./App/make-icon.sh --configuration "${CONFIGURATION}" >/dev/null
cp build/YunAudio.icns "${BUNDLE}/Contents/Resources/"

# The SwiftPM resource bundle carries the icon and both string tables, and
# nothing was copying it in. `Bundle.module` falls back to the build directory
# when it cannot find the bundle beside the executable, so the app worked
# perfectly on this machine and would have shipped with no icon and no
# translations at all — a defect only visible on somebody else's Mac.
# Every module bundle, not just the app's.
#
# This copied one bundle by name, which was right until a second module grew
# resources of its own — the device profiles live with the HAL now, and an app
# built by this script would have shipped without knowing anything about any
# microphone. A loop over what SwiftPM actually produced cannot go out of date
# the same way.
MODULE_BUNDLES=(.build/"${CONFIGURATION}"/*.bundle)
if [[ ! -d "${MODULE_BUNDLES[0]}" ]]; then
	echo "error: no module bundles in .build/${CONFIGURATION} — the app would ship untranslated" >&2
	exit 1
fi
for MODULE_BUNDLE in "${MODULE_BUNDLES[@]}"; do
	cp -R "${MODULE_BUNDLE}" "${BUNDLE}/Contents/Resources/"
	echo "  bundled $(basename "${MODULE_BUNDLE}")"
done
cp App/Info.plist "${BUNDLE}/Contents/Info.plist"
cp "${BINARY}" "${BUNDLE}/Contents/MacOS/YunAudioApp"
for LOCALISATION in App/Resources/*.lproj; do
	cp -R "${LOCALISATION}" "${BUNDLE}/Contents/Resources/"
done

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
	<key>com.apple.security.automation.apple-events</key>
	<true/>
</dict>
</plist>
PLIST

# Signed with a stable identity where there is one, ad-hoc where there is not.
#
# **This is why the microphone is asked for again after every build.** TCC does
# not remember an application by its bundle identifier; it remembers the code
# requirement it was granted to. For an ad-hoc signature that requirement pins
# the cdhash — which changes with every byte of the binary — so each build is a
# different program as far as the permission database is concerned, and the
# grant from the last one cannot apply. Nothing is being forgotten; the thing
# that was granted no longer exists.
#
# A self-signed certificate fixes it because the requirement becomes "this
# bundle identifier, signed by this certificate", and that survives rebuilding.
# Making one needs Keychain Access, which needs a person — see `YUNAUDIO_SIGN`
# below and the note printed when there is no identity.
SIGN_IDENTITY="${YUNAUDIO_SIGN:-}"
if [[ -z "${SIGN_IDENTITY}" ]] &&
	security find-identity -v -p codesigning 2>/dev/null | grep -q "YunAudio Dev"; then
	SIGN_IDENTITY="YunAudio Dev"
fi

echo "signing…"
codesign --force --sign "${SIGN_IDENTITY:--}" \
	--entitlements build/yunaudio.entitlements \
	--options runtime \
	"${BUNDLE}"

if [[ -z "${SIGN_IDENTITY}" ]]; then
	cat <<'ADHOC'

signed ad-hoc, so macOS will ask for the microphone again after every build.
That is not a bug in the application: an ad-hoc signature identifies a build by
its hash, and every build has a different one, so the permission granted to the
last build does not describe this one.

To stop being asked, make a self-signed certificate once — Keychain Access is
the only way, so this is yours to do:

  1. Keychain Access → Certificate Assistant → Create a Certificate…
  2. Name: YunAudio Dev   Identity Type: Self Signed Root
     Certificate Type: Code Signing        (tick "Let me override defaults"
     only if you want to change the expiry)
  3. Build again. This script picks it up by name; `YUNAUDIO_SIGN` overrides.

ADHOC
fi

echo "built ${BUNDLE}"
echo "Shazam catalogue: unavailable in this ad-hoc build."
echo "QQ Music and NetEase audio can be captured, but automatic song identification"
echo "needs a signed App ID with the ShazamKit App Service enabled and runtime verification."

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
		# The isolated run is the flow check, so a non-zero exit means either
		# the bundle is incomplete or a flow failed. Saying "not
		# self-contained" for both sent an hour chasing a missing resource
		# bundle that was present all along.
		if grep -q "flow(s) failed" "${ISOLATED}/out.txt"; then
			echo "error: the bundle is fine, but flows failed:" >&2
			sed -n '/flow(s) failed/,$p' "${ISOLATED}/out.txt" >&2
		else
			echo "error: the app is not self-contained" >&2
			head -5 "${ISOLATED}/out.txt" >&2
		fi
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
