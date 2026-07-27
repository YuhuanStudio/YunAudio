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

VERSION="0.1.0"
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
	echo "The image will work on this machine only; Gatekeeper will block it elsewhere."
	SIGN_ARGS=(--sign - --options runtime)
	NOTARIZE=0
fi

echo
echo "==> building the app"
swift build -c release --product YunAudioApp

echo "==> building the driver"
./Driver/build-driver.sh >/dev/null

rm -rf "${STAGING}" "${IMAGE}"
mkdir -p "${STAGING}"

# The app bundle.
APP="${STAGING}/YunAudio.app"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
./App/make-icon.sh >/dev/null
cp build/YunAudio.icns "${APP}/Contents/Resources/"
cp App/Info.plist "${APP}/Contents/Info.plist"
cp .build/release/YunAudioApp "${APP}/Contents/MacOS/YunAudioApp"

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

codesign --force "${SIGN_ARGS[@]}" \
	--entitlements build/yunaudio.entitlements "${APP}"

# The driver travels alongside rather than inside the app: it has to be copied
# into /Library/Audio/Plug-Ins/HAL by an administrator, so burying it in the
# bundle would only make that harder to explain.
cp -R Driver/build/YunAudioDriver.driver "${STAGING}/"
codesign --force "${SIGN_ARGS[@]}" "${STAGING}/YunAudioDriver.driver"

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

ln -s /Applications "${STAGING}/Applications"

echo "==> building the disk image"
hdiutil create -volname "YunAudio ${VERSION}" -srcfolder "${STAGING}" \
	-ov -format UDZO "${IMAGE}" >/dev/null

if [[ -n "${IDENTITY}" ]]; then
	codesign --force --sign "${IDENTITY}" --timestamp "${IMAGE}"
fi

echo "built ${IMAGE}"

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
