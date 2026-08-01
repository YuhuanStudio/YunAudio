#!/bin/bash
#
# Builds a distributable disk image containing the app and its virtual device.
#
# Signing and notarisation happen automatically when a Developer ID identity is
# present in the keychain. Without one the image is still built and still
# installs on this machine, but Gatekeeper will refuse it elsewhere — so the
# script says so plainly rather than producing something that looks shippable
# and is not.
#
#   ./package.sh                       build the image
#   ./package.sh --notarize            also submit for notarisation
#
# Notarisation needs credentials stored once:
#   xcrun notarytool store-credentials YunAudio \
#       --apple-id <id> --team-id <team> --password <app-specific-password>
#
set -euo pipefail
cd "$(dirname "$0")"

# Ensures the SDK is new enough; see the script for why.
source ./App/toolchain.sh

# The version, from the tag this commit carries — so a disk image can be traced
# back to a commit and two people building the same tag get the same name.
#
# It used to be written here, which meant the number in the file and the number
# on the release were kept in step by somebody remembering. Falls back to a
# description of the commit when there is no tag, because an image built from an
# untagged tree should say so rather than claiming to be the last release.
VERSION="${YUNAUDIO_VERSION:-$(git describe --tags --always --dirty 2>/dev/null || echo 0.0.0-unknown)}"
VERSION="${VERSION#v}"
STAGING="build/dmg"
IMAGE="build/YunAudio-${VERSION}.dmg"
KEYCHAIN_PROFILE="YunAudio"

NOTARIZE=0
[[ "${1:-}" == "--notarize" ]] && NOTARIZE=1

# Find a Developer ID Application identity, if there is one.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null |
	grep "Developer ID Application" | head -1 |
	sed -E 's/.*"(.*)"/\1/')" || true

if [[ -n "${IDENTITY}" ]]; then
	echo "signing identity: ${IDENTITY}"
	SIGN_ARGS=(--sign "${IDENTITY}" --timestamp --options runtime)
else
	echo "no Developer ID Application identity found — signing ad-hoc."
	# Said precisely, because the old wording — "will work on this machine
	# only" — is not what was measured. An ad-hoc signed, quarantined build
	# assesses as `rejected` by `spctl` and still launches on macOS 27; what
	# somebody actually meets is the first-launch refusal, which they get past
	# in System Settings. That is the ordinary way unnotarised open-source
	# software is distributed on this platform, not a reason not to ship.
	echo "Gatekeeper will refuse it on first launch elsewhere; READ ME FIRST.txt says how."
	SIGN_ARGS=(--sign - --options runtime)
	NOTARIZE=0
fi

echo
echo "==> building the driver"
./Driver/build-driver.sh >/dev/null

# The app is assembled by build-app.sh and copied, never rebuilt here.
#
# This script used to lay out the bundle itself, and the two copies drifted:
# when build-app.sh learned to include the SwiftPM resource bundle, the disk
# image kept shipping an app without it — one that dies on launch on any
# machine but this one. There is one place that knows how to build the app.
echo "==> building the app"
./App/build-app.sh --release >/dev/null

rm -rf "${STAGING}" "${IMAGE}"
mkdir -p "${STAGING}"

APP="${STAGING}/YunAudio.app"
cp -R build/YunAudio.app "${APP}"

codesign --force "${SIGN_ARGS[@]}" \
	--entitlements build/yunaudio.entitlements "${APP}"
codesign --verify --deep --strict "${APP}"

if [[ -n "${IDENTITY}" ]]; then
	echo "Shazam catalogue: unverified."
	echo "A Developer ID signature is not proof that the bundle's App ID has the"
	echo "ShazamKit App Service enabled; run the recognition flow before release."
else
	echo "Shazam catalogue: unavailable in this ad-hoc package."
fi

# The driver travels alongside rather than inside the app: it has to be copied
# into /Library/Audio/Plug-Ins/HAL by an administrator, so burying it in the
# bundle would only make that harder to explain.
cp -R Driver/build/YunAudioDriver.driver "${STAGING}/"
codesign --force "${SIGN_ARGS[@]}" "${STAGING}/YunAudioDriver.driver"

# The command line and the MCP server, which the disk image did not carry.
#
# `README.md` leads with `yunaudio-cli selftest` as the proof of this project's
# central claim, quotes `yunaudio-cli soak` for its performance numbers, and
# lists both binaries as interfaces. None of that was reachable by anybody who
# installed the image: they were built, tested, and then left behind — so the
# one command that demonstrates the headline needed a clone and a toolchain.
#
# Release build, because the numbers those two report are meaningless from a
# debug one: Swift's own checking machinery allocates on the realtime path and
# turns the allocation count into a catastrophe that is not there.
echo "==> building the command line and the MCP server"
swift build -c release --product yunaudio-cli >/dev/null
swift build -c release --product yunaudio-mcp >/dev/null
mkdir -p "${STAGING}/Command Line"
for tool in yunaudio-cli yunaudio-mcp; do
	cp ".build/release/${tool}" "${STAGING}/Command Line/${tool}"
	codesign --force "${SIGN_ARGS[@]}" "${STAGING}/Command Line/${tool}"
done
cat >"${STAGING}/Command Line/READ ME.txt" <<'TXT'
yunaudio-cli   the verification harness and the command line
yunaudio-mcp   a Model Context Protocol server, JSON-RPC 2.0 over stdio

Neither needs installing. Run them from here, or copy them somewhere on your
PATH:

    sudo cp yunaudio-cli yunaudio-mcp /usr/local/bin/

What the README leads with, and what these are for:

    yunaudio-cli devices
    yunaudio-cli selftest "<your microphone>" YunAudio

The second sends a 24-bit pseudorandom sequence through the whole path, reads it
back from the loopback, recovers the delay from the data and compares every
sample. It needs the virtual device installed. On a path that is not clock-locked
it reports the actual condition — resampled, or processed — rather than a pass or
a failure.

    yunaudio-cli soak

Six minutes of a bare stereo route with no interface attached, which is where
the processor and memory figures in the README come from.
TXT

# Installer for the driver half, since it needs privileges the app does not have.
cat >"${STAGING}/Install Audio Device.command" <<'SCRIPT'
#!/bin/bash
# Copies the virtual audio device into place and restarts coreaudiod.
# All audio stops for a moment while it restarts.
set -euo pipefail
cd "$(dirname "$0")"
echo "Installing the YunAudio virtual device."
echo "This restarts coreaudiod, so audio stops briefly."
sudo mkdir -p /Library/Audio/Plug-Ins/HAL
sudo rm -rf /Library/Audio/Plug-Ins/HAL/YunAudioDriver.driver
sudo cp -R YunAudioDriver.driver /Library/Audio/Plug-Ins/HAL/
sudo killall coreaudiod
echo "Done. Drag YunAudio.app to Applications and launch it."
SCRIPT
chmod +x "${STAGING}/Install Audio Device.command"

cat >"${STAGING}/Uninstall Audio Device.command" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
sudo rm -rf /Library/Audio/Plug-Ins/HAL/YunAudioDriver.driver
sudo killall coreaudiod
echo "Removed."
SCRIPT
chmod +x "${STAGING}/Uninstall Audio Device.command"

# What somebody meets before they meet the application.
#
# A disk image that opens onto four icons and a refusal is one people close
# again. The refusal is not a fault and it has a fixed remedy, so the remedy
# travels with the thing that causes it — in the window they are already
# looking at, rather than on a page they would have to go and find.
cat >"${STAGING}/READ ME FIRST.txt" <<'NOTE'
YunAudio — first launch

macOS will refuse to open this the first time, and say the developer
cannot be verified. That is expected. It is not a warning about this
application in particular: it is what macOS says about anything that has
not been through Apple's paid notarisation service, and this project has
no paid Apple developer account.

To open it anyway:

  1. Drag YunAudio.app onto the Applications folder here.
  2. Open it once. macOS refuses.
  3. Open System Settings, go to Privacy & Security, scroll to the
     bottom, and click "Open Anyway" beside YunAudio.
  4. Open it again. It will ask once more; agree.

You only do this once.

If you would rather not, build it yourself instead — it is one command
and it carries no quarantine flag, so none of the above applies. The
README in the source repository has it.

---

The virtual audio device (optional)

YunAudio does most of its work without it: capturing other applications,
the effect chain, recording, transcription, monitoring, OBS, MIDI and
scripting all need nothing installed.

What the device buys is the other half — other applications being able to
choose "YunAudio" as their microphone, over a path that is bit-exact.

To install it, run "Install Audio Device.command". It asks for your
administrator password and restarts coreaudiod, so all audio on the
machine stops for a moment.

To remove it, run "Uninstall Audio Device.command". The same applies.

---

QQ Music and NetEase song identification

YunAudio can capture these applications with its existing System Audio
Recording permission, without Accessibility or a private API. Captured audio
alone does not contain the song title, though. The public Shazam catalogue
rejects an ad-hoc build, so one cannot automatically identify the current
QQ Music or NetEase recording.

ShazamKit is an App ID service on macOS, not an entitlement that can be added
to an unsigned build. A release signed with Developer ID must use the same
explicit App ID with ShazamKit enabled in Certificates, Identifiers & Profiles,
and its catalogue lookup must still be verified at runtime. A signature by
itself is not evidence that recognition works.

Without that service, Music and Spotify metadata, hand-selected .lrc files and
the independent lyric databases still work. The application says when the
catalogue is unavailable rather than silently retrying.
NOTE

ln -s /Applications "${STAGING}/Applications"

echo "==> building the disk image"
hdiutil create -volname "YunAudio ${VERSION}" -srcfolder "${STAGING}" \
	-ov -format UDZO "${IMAGE}" >/dev/null

if [[ -n "${IDENTITY}" ]]; then
	codesign --force --sign "${IDENTITY}" --timestamp "${IMAGE}"
fi

echo "built ${IMAGE}"

# Archives beside the image, because a disk image is not the only way somebody
# wants this.
#
# A `.dmg` has to be mounted, which a script cannot do without ceremony and a
# Homebrew cask would rather avoid. The application on its own, and the two
# command-line tools on their own, cover the cases the image is clumsy for —
# and `ditto` rather than `zip` because only `ditto` preserves the bundle's
# symlinks and extended attributes, and a `.app` that loses those is a `.app`
# that will not launch.
APP_ZIP="build/YunAudio-${VERSION}-app.zip"
TOOLS_ZIP="build/yunaudio-tools-${VERSION}.zip"
rm -f "${APP_ZIP}" "${TOOLS_ZIP}"
ditto -c -k --sequesterRsrc --keepParent "${APP}" "${APP_ZIP}"
ditto -c -k --sequesterRsrc --keepParent "${STAGING}/Command Line" "${TOOLS_ZIP}"
echo "built ${APP_ZIP}"
echo "built ${TOOLS_ZIP}"

# What somebody can check the download against, since there is no notarisation
# to check it for them. An ad-hoc signature says the file has not changed since
# it was signed; it says nothing about who signed it. A digest published beside
# the file is the only integrity signal this project can offer, so it offers it.
SUMS="build/checksums-${VERSION}.txt"
( cd build && shasum -a 256 \
	"$(basename "${IMAGE}")" \
	"$(basename "${APP_ZIP}")" \
	"$(basename "${TOOLS_ZIP}")" >"$(basename "${SUMS}")" )
echo "built ${SUMS}"

if [[ "${NOTARIZE}" == "1" ]]; then
	echo "==> submitting for notarisation"
	xcrun notarytool submit "${IMAGE}" \
		--keychain-profile "${KEYCHAIN_PROFILE}" --wait
	xcrun stapler staple "${IMAGE}"
	echo "notarised and stapled"
else
	echo
	echo "Not notarised. On another Mac, Gatekeeper will refuse to open this."
	echo "Run ./package.sh --notarize once a Developer ID identity is available."
fi
