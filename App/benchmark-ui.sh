#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."
source ./App/toolchain.sh

APP=./build/YunAudio.app/Contents/MacOS/YunAudioApp
if [[ ! -x "$APP" ]]; then
    print -u2 'build/YunAudio.app is missing; run ./App/build-app.sh first'
    exit 1
fi

SECONDS_TO_MEASURE=${1:-4}
STYLE_TO_MEASURE=${2:-current}
VARIANT_TO_MEASURE=${3:-full}
SCENARIO_TO_MEASURE=${4:-all}

# A benchmark from an old app is worse than no benchmark: it prints plausible
# numbers for a state the current source may no longer build. This happened
# while concurrent SwiftPM work left the bundle older than the new scenario.
NEWER_SOURCE=$(
    /usr/bin/find Sources -type f -newer "$APP" -print -quit
)
if [[ -n "$NEWER_SOURCE" || Package.swift -nt "$APP" ]]; then
    print -u2 "build/YunAudio.app is older than ${NEWER_SOURCE:-Package.swift}; rebuild it"
    exit 1
fi
case "$SCENARIO_TO_MEASURE" in
all | standard | app-open | panel-closed | window-movement | section-69 | ktv-stage) ;;
*)
    print -u2 \
        'scenario must be all, standard, app-open, panel-closed, window-movement, section-69, or ktv-stage'
    exit 1
    ;;
esac
if ! /usr/bin/strings "$APP" | /usr/bin/grep -F \
    'UI benchmark MainActor distribution' >/dev/null
then
    print -u2 'build/YunAudio.app does not contain the MainActor distribution gate; rebuild it'
    exit 1
fi

# These hashes are exported once and copied verbatim into each fresh process's
# manifest. The final process will refuse to aggregate if even one field moved.
GIT_HEAD=$(/usr/bin/git rev-parse HEAD)
SOURCE_TREE_SHA=$(
    /usr/bin/git ls-files --cached --others --exclude-standard \
        | LC_ALL=C /usr/bin/sort \
        | while IFS= read -r SOURCE_PATH; do
            [[ -f "$SOURCE_PATH" ]] || continue
            /usr/bin/shasum -a 256 "$SOURCE_PATH"
        done \
        | /usr/bin/shasum -a 256 \
        | /usr/bin/awk '{print $1}'
)
DIRTY_STATE=$(/usr/bin/git status --porcelain=v1 --untracked-files=all)
DIRTY_DIGEST=$(
    {
        print -rn -- "$DIRTY_STATE"
        print -rn -- "\n$SOURCE_TREE_SHA\n"
    } | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
)
BINARY_SHA=$(/usr/bin/shasum -a 256 "$APP" | /usr/bin/awk '{print $1}')
TOOLCHAIN_SHA=$(
    {
        xcrun --find swift
        xcrun swift --version
        xcodebuild -version
        xcrun --sdk macosx --show-sdk-version
    } | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
)
OS_BUILD=$(/usr/bin/sw_vers -buildVersion)
FIXTURE_REVISION=mainactor-four-scenario-v1
THRESHOLD_REVISION=p50-0.5-p99-2-max-8-containment-100-cadence-1-coverage-99-v1
RUN_GROUP_ID=${YUNAUDIO_UI_BENCHMARK_RUN_GROUP:-$(/usr/bin/uuidgen)}
if [[ ! "$RUN_GROUP_ID" =~ '^[A-Za-z0-9._-]+$' ]]; then
    print -u2 'YUNAUDIO_UI_BENCHMARK_RUN_GROUP contains an unsafe path character'
    exit 1
fi
MANIFEST_DIRECTORY="$PWD/build/ui-benchmark-manifests/$RUN_GROUP_ID"
if [[ -e "$MANIFEST_DIRECTORY" ]]; then
    print -u2 "UI benchmark run group already exists: $MANIFEST_DIRECTORY"
    exit 1
fi
/bin/mkdir -p "$MANIFEST_DIRECTORY"

print "UI benchmark run group $RUN_GROUP_ID"
print "UI benchmark source SHA-256 $SOURCE_TREE_SHA"
print "UI benchmark binary SHA-256 $BINARY_SHA"

REQUESTED_WHOLE=${SECONDS_TO_MEASURE%%.*}
if [[ ! "$REQUESTED_WHOLE" =~ '^[0-9]+$' ]]; then
    REQUESTED_WHOLE=4
fi
if [[ "$REQUESTED_WHOLE" -lt 4 ]]; then
    REQUESTED_WHOLE=4
elif [[ "$REQUESTED_WHOLE" -gt 60 ]]; then
    REQUESTED_WHOLE=60
fi

run_scenario() {
    local scenario=$1
    local static_seconds=4
    if [[ "$scenario" == "section-69" && "$REQUESTED_WHOLE" -gt 10 ]]; then
        static_seconds=$REQUESTED_WHOLE
    elif [[ "$scenario" == "section-69" ]]; then
        static_seconds=10
    fi
    local passes=4
    if [[ "$scenario" == "app-open" || "$scenario" == "panel-closed" \
        || "$scenario" == "window-movement" ]]; then
        passes=1
        static_seconds=0
    fi
    local deadline_seconds=$((static_seconds + REQUESTED_WHOLE * passes + 20))

    # YUNAUDIO_SCREENSHOT suppresses the first-launch permission guide and claims
    # a verification instance. The no-audio flag is checked again in-process.
    YUNAUDIO_UI_BENCHMARK=1 \
    YUNAUDIO_UI_BENCHMARK_SECONDS="$SECONDS_TO_MEASURE" \
    YUNAUDIO_UI_BENCHMARK_STYLE="$STYLE_TO_MEASURE" \
    YUNAUDIO_UI_BENCHMARK_VARIANT="$VARIANT_TO_MEASURE" \
    YUNAUDIO_UI_BENCHMARK_SCENARIO="$scenario" \
    YUNAUDIO_UI_BENCHMARK_RUN_GROUP="$RUN_GROUP_ID" \
    YUNAUDIO_UI_BENCHMARK_GIT_HEAD="$GIT_HEAD" \
    YUNAUDIO_UI_BENCHMARK_DIRTY_DIGEST="$DIRTY_DIGEST" \
    YUNAUDIO_UI_BENCHMARK_SOURCE_SHA256="$SOURCE_TREE_SHA" \
    YUNAUDIO_UI_BENCHMARK_BINARY_SHA256="$BINARY_SHA" \
    YUNAUDIO_UI_BENCHMARK_TOOLCHAIN_SHA256="$TOOLCHAIN_SHA" \
    YUNAUDIO_UI_BENCHMARK_OS_BUILD="$OS_BUILD" \
    YUNAUDIO_UI_BENCHMARK_FIXTURE_REVISION="$FIXTURE_REVISION" \
    YUNAUDIO_UI_BENCHMARK_THRESHOLD_REVISION="$THRESHOLD_REVISION" \
    YUNAUDIO_UI_BENCHMARK_MANIFEST_DIR="$MANIFEST_DIRECTORY" \
    YUNAUDIO_SCREENSHOT=ui-benchmark \
    YUNAUDIO_SCREENSHOT_NO_AUDIO=1 \
    "$APP" &
    local benchmark_pid=$!

    # A layout storm can starve the benchmark's MainActor task, which is itself
    # the failure under test. The outside watchdog is containment only; the
    # in-process 0.5/2/8 ms distribution remains the acceptance gate.
    local waited_seconds=0
    while kill -0 "$benchmark_pid" 2>/dev/null \
        && [[ "$waited_seconds" -lt "$deadline_seconds" ]]
    do
        sleep 1
        waited_seconds=$((waited_seconds + 1))
    done

    if kill -0 "$benchmark_pid" 2>/dev/null; then
        kill "$benchmark_pid" 2>/dev/null || true
        local stopping_seconds=0
        while kill -0 "$benchmark_pid" 2>/dev/null \
            && [[ "$stopping_seconds" -lt 5 ]]
        do
            sleep 1
            stopping_seconds=$((stopping_seconds + 1))
        done
        if kill -0 "$benchmark_pid" 2>/dev/null; then
            kill -KILL "$benchmark_pid" 2>/dev/null || true
        fi
        wait "$benchmark_pid" 2>/dev/null || true
        print -u2 \
            "UI benchmark $scenario exceeded its ${deadline_seconds}s no-audio deadline"
        return 1
    fi

    local benchmark_status=0
    wait "$benchmark_pid" || benchmark_status=$?
    return "$benchmark_status"
}

if [[ "$SCENARIO_TO_MEASURE" == "all" ]]; then
    SCENARIOS=(app-open panel-closed section-69 ktv-stage)
else
    SCENARIOS=("$SCENARIO_TO_MEASURE")
fi
for scenario in "${SCENARIOS[@]}"; do
    run_scenario "$scenario"
done

if [[ "$SCENARIO_TO_MEASURE" == "all" ]]; then
    AGGREGATE="$MANIFEST_DIRECTORY/aggregate.json"
    if [[ ! -f "$AGGREGATE" ]]; then
        print -u2 'UI benchmark did not produce its four-scenario canonical aggregate'
        exit 1
    fi
    /usr/bin/plutil -lint "$AGGREGATE"
    print "UI benchmark canonical aggregate $AGGREGATE"
else
    print "UI benchmark evidence directory $MANIFEST_DIRECTORY"
fi
