#!/bin/bash
#
# Builds YunAudio.icns from App/Assets/Icon.png.
#
# The source is 180x180, so the large slots are upscaled and will look soft
# next to a native icon. Replacing Icon.png with a 1024x1024 original is the
# only real fix; this script will pick it up without changes.
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE="App/Assets/Icon.png"
SET="build/YunAudio.iconset"
rm -rf "${SET}"
mkdir -p "${SET}"

# The iconset names are fixed by iconutil; each is the pixel size it must be.
for entry in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
             "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
             "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
	size="${entry%% *}"
	name="${entry##* }"
	sips -z "${size}" "${size}" "${SOURCE}" --out "${SET}/${name}.png" >/dev/null
done

iconutil --convert icns "${SET}" --output "build/YunAudio.icns"
rm -rf "${SET}"
echo "built build/YunAudio.icns"
