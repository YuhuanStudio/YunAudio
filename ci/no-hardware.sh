#!/bin/bash
#
# The complete CI surface which is safe on a machine whose audio state belongs
# to somebody else. Every stage is named explicitly so a workflow cannot turn
# a harmless build into a hardware run by forwarding an option.
set -euo pipefail

cd "$(dirname "$0")/.."

usage() {
    cat <<'EOF'
usage: ./ci/no-hardware.sh STAGE [SANITIZER]

stages: inventory policy build test lint strings driver bundle release sanitizer all
sanitizers: address thread undefined
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

stage="${1:-}"
[[ -n "${stage}" ]] || {
    usage >&2
    exit 2
}

# A runner service can inherit variables from its launch environment. Refuse
# the hardware-owning mode even if somebody accidentally configured it there;
# no command below launches the application in that mode.
[[ -z "${YUNAUDIO_FLOWCHECK:-}" ]] ||
    die "YUNAUDIO_FLOWCHECK is set; no-hardware CI refuses to continue"
[[ -z "${YUNAUDIO_LIVE_HAL_TESTS:-}" ]] ||
    die "YUNAUDIO_LIVE_HAL_TESTS is set; no-hardware CI refuses to continue"
[[ -z "${YUNAUDIO_AEC_GATE_TESTING:-}" && -z "${YUNAUDIO_AEC_GATE_OBJDUMP:-}" ]] ||
    die "AEC callback fixture overrides are not accepted by no-hardware CI"
if [[ -n "${CI:-}" && "${YUNAUDIO_CI_NO_HARDWARE:-}" != "1" ]]; then
    die "CI must opt into the no-hardware contract"
fi

if [[ -n "${YUNAUDIO_CI_DEVELOPER_DIR:-}" ]]; then
    [[ "${YUNAUDIO_CI_DEVELOPER_DIR}" == /*/Contents/Developer ]] ||
        die "YUNAUDIO_CI_DEVELOPER_DIR must end in /Contents/Developer"
    [[ -d "${YUNAUDIO_CI_DEVELOPER_DIR}" ]] ||
        die "developer directory does not exist: ${YUNAUDIO_CI_DEVELOPER_DIR}"
    export DEVELOPER_DIR="${YUNAUDIO_CI_DEVELOPER_DIR}"
fi

# Selects an installed Xcode carrying the SDK needed to compile the optional
# macOS 27 transcription surface. The macOS 26 lane still deploys to 26; only
# its compiler headers need to be newer.
source ./App/toolchain.sh

# These are the only tests allowed to inspect or mutate the live HAL. The
# inventory assertion below must pass before a test binary is executed: a
# rename cannot accidentally make a sample-rate or process-tap test eligible.
# The same reviewed manifest supplies App/verify.sh's full-suite arithmetic.
live_hal_test_manifest="ci/live-hal-tests.txt"
live_hal_test_count="$(grep -cve '^[[:space:]]*$' "${live_hal_test_manifest}")"
expected_live_hal_tests="$(LC_ALL=C sort "${live_hal_test_manifest}")"
live_hal_test_pattern="$(
    /usr/bin/ruby -e \
        'puts File.readlines(ARGV.fetch(0), chomp: true).reject(&:empty?).map { |line| Regexp.escape(line) }.join("|")' \
        "${live_hal_test_manifest}"
)"

# Every gated test carries its full Swift Testing identifier beside the trait.
# Extracting that metadata in the opposite direction closes the hole where a
# ninth live test could be disabled locally but omitted from CI's skip list.
declared_live_hal_tests="$(
    /usr/bin/ruby -e '
      source = Dir["Tests/**/*.swift"].sort.map { |path| File.read(path, encoding: "UTF-8") }.join("\n")
      abort "error: a live-HAL test bypasses TestCapabilities.liveHALTest metadata" if source.match?(/\.enabled\(\s*if:\s*TestCapabilities\.liveHAL/m)
      identifiers = source.scan(/TestCapabilities\.liveHALTest\(\s*"([^"]+)"\s*\)/m).flatten
      abort "error: duplicate live-HAL test metadata" unless identifiers.uniq.length == identifiers.length
      puts identifiers.sort
    '
)"
[[ "${declared_live_hal_tests}" == "${expected_live_hal_tests}" ]] || {
    echo "reviewed live-HAL manifest:" >&2
    echo "${expected_live_hal_tests}" >&2
    echo "source-declared live-HAL tests:" >&2
    echo "${declared_live_hal_tests:-<none>}" >&2
    die "live-HAL source metadata and exclusion manifest differ"
}

host_os_version="$(sw_vers -productVersion)"
host_os_major="${host_os_version%%.*}"
[[ "${host_os_major}" =~ ^[0-9]+$ ]] || die "host OS major is not numeric: ${host_os_major}"
test_skip_pattern="${live_hal_test_pattern}"
test_exclusion_count="${live_hal_test_count}"

inventory() {
    [[ "$(uname -s)" == "Darwin" ]] || die "this matrix requires macOS"
    local version major build sdk
    version="$(sw_vers -productVersion)"
    major="${version%%.*}"
    build="$(sw_vers -buildVersion)"
    sdk="$(xcrun --sdk macosx --show-sdk-version)"
    if [[ -n "${YUNAUDIO_CI_EXPECTED_OS_MAJOR:-}" ]]; then
        [[ "${YUNAUDIO_CI_EXPECTED_OS_MAJOR}" =~ ^[0-9]+$ ]] ||
            die "expected OS major is not numeric: ${YUNAUDIO_CI_EXPECTED_OS_MAJOR}"
        [[ "${major}" == "${YUNAUDIO_CI_EXPECTED_OS_MAJOR}" ]] ||
            die "lane expected macOS ${YUNAUDIO_CI_EXPECTED_OS_MAJOR}, found ${version}"
    fi
    echo "lane: ${YUNAUDIO_CI_LANE:-local}"
    echo "host: macOS ${version} (${build}), $(uname -m)"
    xcodebuild -version
    echo "macOS SDK: ${sdk}"
    swift --version
}

policy() {
    /usr/bin/ruby ./ci/workflow-policy.rb
    bash -n ./ci/no-hardware.sh
    bash -n ./ci/check-aec-callback-arc.sh
    bash -n ./ci/test-aec-callback-arc.sh
    ./ci/test-aec-callback-arc.sh
    /usr/bin/ruby -c ./ci/workflow-policy.rb >/dev/null
}

release_aec_object() {
    local bin_path architecture object
    architecture="$(uname -m)"
    bin_path="$(
        swift build --scratch-path "$(test_scratch_path release)" \
            --configuration release --show-bin-path
    )"
    case "${bin_path}" in
    */out/Products/Release)
        object="${bin_path%/Products/Release}/Intermediates.noindex/YunAudioKit.build/Release/YunAudioEngine-t.build/Objects-normal/${architecture}/EchoCancellationBridge.o"
        ;;
    */release)
        object="${bin_path}/YunAudioEngine.build/EchoCancellationBridge.swift.o"
        ;;
    *) die "unrecognised Swift Release build layout: ${bin_path}" ;;
    esac
    [[ -f "${object}" ]] || die "Release build did not produce the expected AEC object: ${object}"
    printf '%s\n' "${object}"
}

# Product-only app builds and `@testable` test builds use incompatible Swift
# modules under Swift 6.4. Keeping each CI family in its own build graph makes
# the result independent of whether bundle, Release or a sanitizer ran first.
test_scratch_path() {
    local configuration="$1"
    local sanitizer="${2:-}"
    local suffix="${configuration}"
    [[ -z "${sanitizer}" ]] || suffix+="-${sanitizer}"
    printf '.build/no-hardware-%s\n' "${suffix}"
}

test_count() {
    local output="$1"
    grep -aoE "Test run with [0-9]+ tests" "${output}" |
        grep -oE "[0-9]+" | tail -1
}

prepare_test_binary() {
    local configuration="$1"
    local sanitizer="${2:-}"
    local scratch ubsan_runtime
    scratch="$(test_scratch_path "${configuration}" "${sanitizer}")"
    local build=(
        swift build --scratch-path "${scratch}" --build-tests
        --configuration "${configuration}" -Xswiftc -enable-testing
    )
    local list=(
        swift test --scratch-path "${scratch}" --configuration "${configuration}"
        list --skip-build
    )
    local output status observed
    if [[ -n "${sanitizer}" ]]; then
        build+=(--sanitize "${sanitizer}")
        list=(
            swift test --scratch-path "${scratch}" --configuration "${configuration}"
            --sanitize "${sanitizer}" list --skip-build
        )
        if [[ "${sanitizer}" == "undefined" ]]; then
            # SwiftPM instruments the C realtime shim for UBSan but Xcode 27's
            # Swift driver does not add Clang's macOS UBSan runtime when it
            # links every package executable. Supplying the exact toolchain
            # runtime closes that link boundary for all products; the absolute
            # install name also lets the already-built test bundle load it.
            ubsan_runtime="$(xcrun clang --print-resource-dir)/lib/darwin/libclang_rt.ubsan_osx_dynamic.dylib"
            [[ -f "${ubsan_runtime}" ]] || die "UBSan runtime is missing: ${ubsan_runtime}"
            build+=(-Xlinker "${ubsan_runtime}")
        fi
    fi
    "${build[@]}"

    output="$(mktemp -t yunaudio-ci-test-list.XXXXXX)"
    set +e
    "${list[@]}" >"${output}" 2>&1
    status="$?"
    set -e
    if [[ "${status}" -ne 0 ]]; then
        sed -n '1,80p' "${output}" >&2
        rm -f "${output}"
        die "could not inventory the ${configuration} tests"
    fi
    observed="$(
        grep -E "^(${live_hal_test_pattern})$" "${output}" | LC_ALL=C sort || true
    )"
    [[ "${observed}" == "${expected_live_hal_tests}" ]] || {
        echo "expected live-HAL tests:" >&2
        echo "${expected_live_hal_tests}" >&2
        echo "observed live-HAL tests:" >&2
        echo "${observed:-<none>}" >&2
        rm -f "${output}"
        die "the reviewed no-hardware exclusion inventory changed"
    }
    rm -f "${output}"
    echo "test inventory: ${live_hal_test_count} reviewed live-HAL tests will not run"
}

run_complete_tests() {
    local configuration="$1"
    local output status count floor expected scratch
    scratch="$(test_scratch_path "${configuration}")"
    prepare_test_binary "${configuration}"
    output="$(mktemp -t yunaudio-ci-tests.XXXXXX)"
    local command=(
        swift test --scratch-path "${scratch}" --configuration "${configuration}"
        --skip-build --no-parallel --skip "${test_skip_pattern}"
    )

    set +e
    "${command[@]}" 2>&1 | tee "${output}"
    status="${PIPESTATUS[0]}"
    set -e
    if [[ "${status}" -ne 0 ]]; then
        rm -f "${output}"
        return "${status}"
    fi

    count="$(test_count "${output}" || true)"
    rm -f "${output}"
    [[ -n "${count}" ]] || die "the ${configuration} run reported no test count"
    floor="$(cat App/test-floor.txt)"
    [[ "${floor}" =~ ^[0-9]+$ ]] || die "App/test-floor.txt is not a number"
    [[ "${floor}" -ge "${test_exclusion_count}" ]] ||
        die "App/test-floor.txt is smaller than the CI test exclusion"
    expected=$((floor - test_exclusion_count))
    # The allocation benchmark is deliberately disabled in Debug: Swift's own
    # checks allocate on the measured path. Release must therefore execute one
    # additional test rather than sharing Debug's public floor verbatim.
    [[ "${configuration}" != "release" ]] || expected=$((expected + 1))
    [[ "${count}" == "${expected}" ]] ||
        die "${configuration} ran ${count} no-hardware tests; expected ${expected} from floor ${floor}"
    echo "${configuration}: ${count} tests; ${test_exclusion_count} reviewed exclusions"
}

run_sanitizer() {
    local sanitizer="$1"
    local filter output status count scratch
    scratch="$(test_scratch_path debug "${sanitizer}")"
    case "${sanitizer}" in
    address | undefined)
        filter="RCUHardeningTests|AtomicClockPublicationTests|CommandQueueTests|RealtimeCellTests|SampleRingTests|SignalAnalysisWorkerTests|ControlSocketTests|IOProcTests|EffectTransitionTests|EffectTransitionGraphTests|FarEndCaptureLayoutTests|OutputCorrectionBankTests|RouteProcessingPlanTests"
        ;;
    thread)
        filter="RCUHardeningTests|AtomicClockPublicationTests|CommandQueueTests|RealtimeCellTests|SampleRingTests|SignalAnalysisWorkerTests|ControlSocketTests"
        ;;
    *) die "unknown sanitizer: ${sanitizer}" ;;
    esac

    prepare_test_binary debug "${sanitizer}"
    export MallocNanoZone=0
    export YUNAUDIO_SANITIZER_RUN="${sanitizer}"
    case "${sanitizer}" in
    address) export ASAN_OPTIONS="halt_on_error=1:abort_on_error=1:detect_leaks=0" ;;
    thread) export TSAN_OPTIONS="halt_on_error=1" ;;
    undefined) export UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1" ;;
    esac

    output="$(mktemp -t yunaudio-ci-sanitizer.XXXXXX)"
    set +e
    swift test --scratch-path "${scratch}" --configuration debug \
        --sanitize "${sanitizer}" --skip-build --no-parallel \
        --filter "${filter}" 2>&1 | tee "${output}"
    status="${PIPESTATUS[0]}"
    set -e
    if [[ "${status}" -ne 0 ]]; then
        rm -f "${output}"
        return "${status}"
    fi
    count="$(test_count "${output}" || true)"
    rm -f "${output}"
    [[ -n "${count}" ]] || die "${sanitizer} reported no test count"
    [[ "${count}" -ge 20 ]] ||
        die "${sanitizer} ran only ${count} tests; its high-risk filter stopped matching"
    echo "${sanitizer}: ${count} bounded high-risk tests"
}

run_stage() {
    local requested="$1"
    case "${requested}" in
    inventory) inventory ;;
    policy) policy ;;
    build) swift build ;;
    test) run_complete_tests debug ;;
    lint)
        "$(xcrun --find swift-format)" lint --strict --recursive Sources Tests
        ;;
    strings) ./App/check-strings.sh ;;
    driver)
        # No argument is the build/test/static path. The opt-in installation
        # spelling is deliberately unavailable through this wrapper.
        ./Driver/build-driver.sh
        ;;
    bundle) ./App/build-app.sh --verify ;;
    release)
        run_complete_tests release
        ./ci/check-aec-callback-arc.sh --object "$(release_aec_object)" \
            --source Sources/YunAudioEngine/EchoCancellationBridge.swift
        ;;
    sanitizer)
        [[ "$#" == "2" ]] || die "sanitizer requires exactly one name"
        run_sanitizer "$2"
        ;;
    all)
        [[ "$#" == "1" ]] || die "all takes no further arguments"
        inventory
        policy
        swift build
        run_complete_tests debug
        "$(xcrun --find swift-format)" lint --strict --recursive Sources Tests
        ./App/check-strings.sh
        ./Driver/build-driver.sh
        ./App/build-app.sh --verify
        ;;
    *) usage >&2; exit 2 ;;
    esac
}

run_stage "$@"
