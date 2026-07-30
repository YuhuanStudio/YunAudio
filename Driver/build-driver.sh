#!/bin/bash
#
# Builds YunAudioDriver.driver, an AudioServerPlugIn bundle.
#
# Building never touches the system. Installing does, and is deliberately a
# separate opt-in step: it copies into /Library/Audio/Plug-Ins/HAL and restarts
# coreaudiod, which momentarily drops audio for every running application.
#
#   ./build-driver.sh            build only
#   ./build-driver.sh --install  build, then install (asks for admin rights)
#
set -euo pipefail

cd "$(dirname "$0")"

BUNDLE_NAME="YunAudioDriver.driver"
BUILD_DIR="build"
BUNDLE="${BUILD_DIR}/${BUNDLE_NAME}"
INSTALL_DIR="/Library/Audio/Plug-Ins/HAL"

rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS"
cp Info.plist "${BUNDLE}/Contents/Info.plist"

echo "compiling…"
clang \
	-bundle \
	-O2 \
	-fvisibility=hidden \
	-Wall -Wextra \
	-Werror=implicit-function-declaration \
	-mmacosx-version-min=13.0 \
	-framework CoreFoundation \
	-framework CoreAudio \
	-o "${BUNDLE}/Contents/MacOS/YunAudioDriver" \
	Sources/YunAudioDriver.c

echo "testing…"
clang \
	-O2 \
	-Wall -Wextra \
	-Werror=implicit-function-declaration \
	-mmacosx-version-min=13.0 \
	-framework CoreFoundation \
	-framework CoreAudio \
	-o "${BUILD_DIR}/DriverCoreTests" \
	Tests/DriverCoreTests.c
"${BUILD_DIR}/DriverCoreTests"
./check-realtime.sh

# The factory is looked up by name through CFPlugIn, so it has to stay visible
# even though everything else is hidden.
echo "signing…"
codesign --force --sign - --timestamp=none "${BUNDLE}"

echo "built ${BUNDLE}"
echo
echo "loaded objects:"
nm -gU "${BUNDLE}/Contents/MacOS/YunAudioDriver" | grep -i factory || {
	echo "  ERROR: YunAudioDriverFactory is not exported — CFPlugIn cannot find it."
	exit 1
}

if [[ "${1:-}" == "--install" ]]; then
	echo
	echo "Installing to ${INSTALL_DIR}."
	echo "This restarts coreaudiod: all audio stops for a moment."
	sudo mkdir -p "${INSTALL_DIR}"
	sudo rm -rf "${INSTALL_DIR:?}/${BUNDLE_NAME}"
	sudo cp -R "${BUNDLE}" "${INSTALL_DIR}/"
	sudo killall coreaudiod
	echo "installed. give coreaudiod a second, then run: swift run yunaudio-cli"
fi
