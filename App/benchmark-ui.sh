#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

APP=./build/YunAudio.app/Contents/MacOS/YunAudioApp
if [[ ! -x "$APP" ]]; then
    print -u2 'build/YunAudio.app is missing; run ./App/build-app.sh first'
    exit 1
fi

# YUNAUDIO_UI_BENCHMARK_STAGE=1 opens the KTV stage as well, so the numbers
# cover the window the singing features live in. Off by default, so every
# figure recorded before it still means what it meant.
SECONDS_TO_MEASURE=${1:-4}
STYLE_TO_MEASURE=${2:-current}
VARIANT_TO_MEASURE=${3:-full}

# YUNAUDIO_SCREENSHOT suppresses the first-launch permission guide and claims a
# verification instance. UIResourceBenchmark runs before WindowCapture, so this
# path writes no images. The no-audio flag is checked again inside the process.
YUNAUDIO_UI_BENCHMARK=1 \
YUNAUDIO_UI_BENCHMARK_SECONDS="$SECONDS_TO_MEASURE" \
YUNAUDIO_UI_BENCHMARK_STYLE="$STYLE_TO_MEASURE" \
YUNAUDIO_UI_BENCHMARK_VARIANT="$VARIANT_TO_MEASURE" \
YUNAUDIO_SCREENSHOT=ui-benchmark \
YUNAUDIO_SCREENSHOT_NO_AUDIO=1 \
"$APP"
