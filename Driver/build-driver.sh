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
STRICT_WARNINGS=(
	-Wall
	-Wextra
	-Wpedantic
	-Werror
	-Wno-gnu-zero-variadic-macro-arguments
	-Wno-gnu-statement-expression-from-macro-expansion
)

rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS"
cp Info.plist "${BUNDLE}/Contents/Info.plist"

# A Mach-O UUID changes on every link, so hashing the finished binary cannot
# tell a rebuild from a different driver. Stamp the sources instead: identical
# code gets an identical identity however often or where it is compiled.
DRIVER_SOURCE_ID="$({ shasum -a 256 Sources/YunAudioDriver.c; shasum -a 256 Sources/YunAudioDriver.h; } | shasum -a 256 | awk '{print $1}')"
/usr/libexec/PlistBuddy \
	-c "Add :YunAudioSourceIdentifier string ${DRIVER_SOURCE_ID}" \
	"${BUNDLE}/Contents/Info.plist"

echo "compiling…"
clang \
	-bundle \
	-O2 \
	-fvisibility=hidden \
	"${STRICT_WARNINGS[@]}" \
	-mmacosx-version-min=13.0 \
	-framework CoreFoundation \
	-framework CoreAudio \
	-o "${BUNDLE}/Contents/MacOS/YunAudioDriver" \
	Sources/YunAudioDriver.c

echo "testing…"
clang \
	-O2 \
	-DYUNAUDIO_DRIVER_PERFORMANCE_TESTS=1 \
	"${STRICT_WARNINGS[@]}" \
	-mmacosx-version-min=13.0 \
	-framework CoreFoundation \
	-framework CoreAudio \
	-o "${BUILD_DIR}/DriverCoreTests" \
	Tests/DriverCoreTests.c
"${BUILD_DIR}/DriverCoreTests"

echo "testing with ASan and UBSan…"
clang \
	-O1 -g \
	-fsanitize=address,undefined \
	-fno-omit-frame-pointer \
	"${STRICT_WARNINGS[@]}" \
	-mmacosx-version-min=13.0 \
	-framework CoreFoundation \
	-framework CoreAudio \
	-o "${BUILD_DIR}/DriverCoreTests-asan-ubsan" \
	Tests/DriverCoreTests.c
ASAN_OPTIONS=abort_on_error=1 UBSAN_OPTIONS=halt_on_error=1 \
	"${BUILD_DIR}/DriverCoreTests-asan-ubsan"

echo "testing with TSan…"
clang \
	-O1 -g \
	-fsanitize=thread \
	-fno-omit-frame-pointer \
	"${STRICT_WARNINGS[@]}" \
	-mmacosx-version-min=13.0 \
	-framework CoreFoundation \
	-framework CoreAudio \
	-o "${BUILD_DIR}/DriverCoreTests-tsan" \
	Tests/DriverCoreTests.c
TSAN_OPTIONS=halt_on_error=1 "${BUILD_DIR}/DriverCoreTests-tsan"

echo "analysing…"
clang \
	--analyze \
	"${STRICT_WARNINGS[@]}" \
	-mmacosx-version-min=13.0 \
	-o /dev/null \
	Sources/YunAudioDriver.c
clang \
	--analyze \
	"${STRICT_WARNINGS[@]}" \
	-mmacosx-version-min=13.0 \
	-o /dev/null \
	Tests/DriverCoreTests.c
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
