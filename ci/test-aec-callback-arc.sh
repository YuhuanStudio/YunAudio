#!/bin/bash
#
# Deterministic object-dump fixtures for the Release callback gate. These run
# no application code and make each accepted and rejected edge shape numeric.
set -euo pipefail

fake_objdump() {
    local capture_symbol='_fixture_captureHandler_To'
    local far_end_symbol='_fixture_farEndProvider_cfU_'
    local far_end_thunk_symbol='_fixture_farEndProvider_cfU_To'
    local scenario="${YUNAUDIO_AEC_FIXTURE_SCENARIO:-safe-tail}"
    case "${1:-}" in
    --private-headers)
        if [[ "${scenario}" == "unsafe-architecture" ]]; then
            echo "${2}: file format mach-o x86-64"
        else
            echo "${2}: file format mach-o arm64"
        fi
        ;;
    --syms)
        cat <<EOF
0000000000001000  w    F __TEXT,__text .hidden ${capture_symbol}
0000000000002000  w    F __TEXT,__text .hidden ${far_end_symbol}
0000000000003000  w    F __TEXT,__text .hidden ${far_end_thunk_symbol}
EOF
        ;;
    --disassemble-symbols=*)
        local requested="${1#--disassemble-symbols=}"
        case "${requested}" in
        "${capture_symbol}")
            echo "0000000000001000 <${capture_symbol}>:"
            case "${scenario}" in
            safe-tail)
                cat <<EOF
    1000: f9400000     ldr x0, [x0]
    1004: 14000000     b 0x1004 <${capture_symbol}+0x4>
        0000000000001004: ARM64_RELOC_BRANCH26 _yun_rt_ring_write
EOF
                ;;
            safe-call-ret)
                cat <<EOF
    1000: 94000000     bl 0x1000 <${capture_symbol}>
        0000000000001000: ARM64_RELOC_BRANCH26 _yun_rt_ring_write
    1004: d65f03c0     ret
EOF
                ;;
            unsafe-local-tail)
                echo '    1000: 14000400     b 0x2000 <_unreviewed_local_helper>'
                ;;
            unsafe-indirect)
                cat <<'EOF'
    1000: d63f0100     blr x8
    1004: d65f03c0     ret
EOF
                ;;
            unsafe-extra-call)
                cat <<EOF
    1000: 94000000     bl 0x1000 <${capture_symbol}>
        0000000000001000: ARM64_RELOC_BRANCH26 _yun_rt_ring_write
    1004: 94000000     bl 0x1004 <${capture_symbol}+0x4>
        0000000000001004: ARM64_RELOC_BRANCH26 _swift_retain
    1008: d65f03c0     ret
EOF
                ;;
            *) echo "error: unknown fixture scenario: ${scenario}" >&2; exit 2 ;;
            esac
            ;;
        "${far_end_symbol}")
            cat <<EOF
0000000000002000 <${far_end_symbol}>:
    2000: 94000000     bl 0x2000 <${far_end_symbol}>
        0000000000002000: ARM64_RELOC_BRANCH26 _yun_rt_ring_read
    2004: d65f03c0     ret
EOF
            ;;
        "${far_end_thunk_symbol}")
            cat <<EOF
0000000000003000 <${far_end_thunk_symbol}>:
    3000: 14000000     b 0x3000 <${far_end_thunk_symbol}>
        0000000000003000: ARM64_RELOC_BRANCH26 ${far_end_symbol}
EOF
            ;;
        *) echo "error: unexpected fixture symbol: ${requested}" >&2; exit 2 ;;
        esac
        ;;
    *) echo "error: unexpected fixture objdump arguments: $*" >&2; exit 2 ;;
    esac
}

if [[ "$(basename "$0")" == "aec-fixture-objdump" ]]; then
    fake_objdump "$@"
    exit 0
fi

cd "$(dirname "$0")/.."
fixture_root="$(mktemp -d -t yunaudio-aec-gate.XXXXXX)"
trap 'rm -rf "${fixture_root}"' EXIT

fixture_source="${fixture_root}/EchoCancellationBridge.swift"
fixture_object="${fixture_root}/Release/YunAudioEngine-t.build/Objects-normal/arm64/EchoCancellationBridge.o"
fixture_objdump="${fixture_root}/aec-fixture-objdump"
mkdir -p "$(dirname "${fixture_object}")"
touch "${fixture_source}" "${fixture_object}"
ln -s "$(pwd)/ci/test-aec-callback-arc.sh" "${fixture_objdump}"

run_fixture() {
    local scenario="$1"
    YUNAUDIO_AEC_GATE_TESTING=1 \
        YUNAUDIO_AEC_GATE_OBJDUMP="${fixture_objdump}" \
        YUNAUDIO_AEC_FIXTURE_SCENARIO="${scenario}" \
        ./ci/check-aec-callback-arc.sh \
        --object "${fixture_object}" --source "${fixture_source}"
}

pass_count=0
reject_count=0
for scenario in safe-tail safe-call-ret; do
    run_fixture "${scenario}" >/dev/null
    pass_count=$((pass_count + 1))
done
for scenario in unsafe-local-tail unsafe-indirect unsafe-extra-call unsafe-architecture; do
    if run_fixture "${scenario}" >/dev/null 2>&1; then
        echo "error: unsafe fixture passed: ${scenario}" >&2
        exit 1
    fi
    reject_count=$((reject_count + 1))
done

[[ "${pass_count}" == "2" ]] || exit 1
[[ "${reject_count}" == "4" ]] || exit 1
echo "AEC callback gate fixtures: ${pass_count} safe shapes passed; ${reject_count} unsafe shapes rejected"
