#!/bin/bash
#
# Builds YunAudio.icns by asking the application to draw itself.
#
#   ./App/make-icon.sh                    the default look
#   ./App/make-icon.sh --style paper      one of YunIconBadge.styles
#   ./App/make-icon.sh --list             what the styles are called
#
# Why the app and not sips. This script used to scale one 180-point PNG into
# all ten slots of the iconset, so the largest was a five-fold upscale — soft in
# Finder at 512 and mushy at 16, where the body's edge and its shadow are a
# pixel wide and cannot survive being resampled. The app draws each slot at its
# own resolution instead, using the same code that knows where the mark's ink
# sits inside the artwork. That code has to exist anyway for the menu bar.
#
# It also means the icon has settings rather than being an opaque file:
# `YunIconBadge.styles` in Sources/YunAudioApp/AppIcon.swift is the list, and
# adding an entry to it adds a `--style`.
set -euo pipefail
cd "$(dirname "$0")/.."

# Ensures the SDK is new enough; see the script for why.
source ./App/toolchain.sh

STYLE="${YUNAUDIO_ICON_STYLE:-graphite}"
CONFIGURATION="debug"
LIST=0
while [[ $# -gt 0 ]]; do
	case "$1" in
	--style)
		STYLE="${2:-}"
		shift 2
		;;
	--style=*)
		STYLE="${1#--style=}"
		shift
		;;
	--configuration)
		CONFIGURATION="${2:-debug}"
		shift 2
		;;
	--release)
		CONFIGURATION="release"
		shift
		;;
	--list)
		LIST=1
		shift
		;;
	*)
		echo "error: unknown argument $1" >&2
		exit 1
		;;
	esac
done

if [[ "${LIST}" == "1" ]]; then
	# Read out of the source rather than repeated here, so a style added in one
	# place cannot be missing from the other.
	grep -o 'name: "[a-z]*"' Sources/YunAudioApp/AppIcon.swift | sed 's/name: /  /;s/"//g'
	exit 0
fi

BINARY=".build/${CONFIGURATION}/YunAudioApp"
if [[ ! -x "${BINARY}" ]]; then
	swift build -c "${CONFIGURATION}" --product YunAudioApp
fi

SET="build/YunAudio.iconset"
rm -rf "${SET}"
mkdir -p "${SET}"

# A non-zero exit here means a slot could not be written. An icon build that
# half-succeeded produces an icns that iconutil accepts and Finder renders as a
# blank page, which is a much harder thing to notice later.
YUNAUDIO_ICON="${SET}" YUNAUDIO_ICON_STYLE="${STYLE}" "${BINARY}"

iconutil --convert icns "${SET}" --output "build/YunAudio.icns"
rm -rf "${SET}"
echo "built build/YunAudio.icns (${STYLE})"
