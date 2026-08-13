#!/bin/bash
#
# Allocation tripwires cannot see Swift reference counting. Inspect the three
# optimised Swift callback bodies and admit only the reviewed direct edges. The
# C ring implementations have their own tests; this check is deliberately not
# a transitive proof about their object code.
set -euo pipefail

cd "$(dirname "$0")/.."

die() {
    echo "error: $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
usage: ./ci/check-aec-callback-arc.sh [--object PATH] [--source PATH]

Without --object, the newest current-architecture Release object is selected.
Pass --object in CI so the check is tied to the object produced by that build.
EOF
}

object=""
source_file="Sources/YunAudioEngine/EchoCancellationBridge.swift"
while [[ "$#" -gt 0 ]]; do
    case "$1" in
    --object)
        [[ "$#" -ge 2 ]] || die "--object requires a path"
        object="$2"
        shift 2
        ;;
    --source)
        [[ "$#" -ge 2 ]] || die "--source requires a path"
        source_file="$2"
        shift 2
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *) die "unknown argument: $1" ;;
    esac
done

host_arch="$(uname -m)"
[[ "${host_arch}" == "arm64" ]] ||
    die "AEC callback object inspection currently supports only an arm64 host"

if [[ -n "${YUNAUDIO_AEC_GATE_OBJDUMP:-}" ]]; then
    [[ "${YUNAUDIO_AEC_GATE_TESTING:-}" == "1" ]] ||
        die "the objdump override is available only to the gate fixture test"
    objdump="${YUNAUDIO_AEC_GATE_OBJDUMP}"
else
    [[ -z "${YUNAUDIO_AEC_GATE_TESTING:-}" ]] ||
        die "gate fixture mode requires an explicit objdump override"
    objdump="$(xcrun --find llvm-objdump)"
fi
[[ -x "${objdump}" ]] || die "llvm-objdump is not executable: ${objdump}"

object_arch() {
    local candidate="$1"
    "${objdump}" --private-headers "${candidate}" |
        awk '
          /file format mach-o / { count += 1; architecture = $NF }
          END { if (count == 1) print architecture; else exit 1 }
        '
}

newest() {
    local newest_path=""
    local newest_time=-1
    local candidate candidate_time
    while IFS= read -r candidate; do
        [[ -n "${candidate}" ]] || continue
        [[ "$(object_arch "${candidate}")" == "${host_arch}" ]] || continue
        candidate_time="$(stat -f '%m' "${candidate}")"
        if [[ "${candidate_time}" -gt "${newest_time}" ]]; then
            newest_path="${candidate}"
            newest_time="${candidate_time}"
        fi
    done
    printf '%s\n' "${newest_path}"
}

if [[ -z "${object}" ]]; then
    swiftpm_candidates="$({
        find .build -type f \
            -path '*/release/YunAudioEngine.build/EchoCancellationBridge.swift.o' \
            -print
    })"
    xcode_candidates="$({
        find .build -type f \
            -path "*/Release/YunAudioEngine-t.build/Objects-normal/${host_arch}/EchoCancellationBridge.o" \
            -print
    })"
    swiftpm_object="$(printf '%s\n' "${swiftpm_candidates}" | newest)"
    xcode_object="$(printf '%s\n' "${xcode_candidates}" | newest)"
    if [[ -n "${swiftpm_object}" && -n "${xcode_object}" ]]; then
        die "both SwiftPM and Xcode Release objects exist; pass --object explicitly"
    fi
    object="${swiftpm_object:-${xcode_object}}"
fi

[[ -n "${object}" && -f "${object}" ]] ||
    die "the Release EchoCancellationBridge object was not built"
[[ -f "${source_file}" ]] || die "callback source does not exist: ${source_file}"

object="$(cd "$(dirname "${object}")" && pwd -P)/$(basename "${object}")"
source_file="$(cd "$(dirname "${source_file}")" && pwd -P)/$(basename "${source_file}")"
case "${object}" in
*/release/YunAudioEngine.build/EchoCancellationBridge.swift.o) ;;
*/Release/YunAudioEngine-t.build/Objects-normal/arm64/EchoCancellationBridge.o) ;;
*) die "object is not in a recognised arm64 Release build layout: ${object}" ;;
esac

architecture="$(object_arch "${object}")"
[[ "${architecture}" == "arm64" ]] ||
    die "expected a Mach-O arm64 object, found ${architecture:-an unknown format}"
[[ "$(stat -f '%m' "${object}")" -ge "$(stat -f '%m' "${source_file}")" ]] ||
    die "Release callback object is older than EchoCancellationBridge.swift"

symbols="$("${objdump}" --syms "${object}")"

unique_symbol() {
    local label="$1"
    local pattern="$2"
    local matches count
    matches="$(printf '%s\n' "${symbols}" | awk -v pattern="${pattern}" \
        '$0 ~ pattern && $0 ~ / F __TEXT,__text / { print $NF }')"
    count="$(printf '%s\n' "${matches}" | awk 'NF { count += 1 } END { print count + 0 }')"
    [[ "${count}" == "1" ]] ||
        die "expected one ${label} Release symbol, found ${count}"
    printf '%s\n' "${matches}"
}

capture_symbol="$(unique_symbol capture-handler 'captureHandler.*_To$')"
far_end_symbol="$(unique_symbol far-end-provider 'farEndProvider.*cfU_$')"
far_end_thunk_symbol="$(unique_symbol far-end-thunk 'farEndProvider.*cfU_To$')"

verify_function() {
    local label="$1"
    local symbol="$2"
    local expected_edge="$3"
    local dump_file status
    dump_file="$(mktemp -t yunaudio-aec-object.XXXXXX)"
    if ! "${objdump}" --disassemble-symbols="${symbol}" --reloc "${object}" >"${dump_file}"; then
        rm -f "${dump_file}"
        die "llvm-objdump could not disassemble ${label}"
    fi

    set +e
    /usr/bin/ruby - "${dump_file}" "${label}" "${symbol}" "${expected_edge}" <<'RUBY'
path, label, symbol, expected_edge = ARGV
lines = File.readlines(path, chomp: true)

headers = lines.each_with_object([]) do |line, result|
  match = line.match(/^([0-9a-fA-F]+) <(.+)>:$/)
  result << [match[1].to_i(16), match[2]] if match
end
abort "#{label}: objdump did not isolate exactly the requested symbol" unless headers == [[headers.dig(0, 0), symbol]]

instructions = {}
relocations = Hash.new { |hash, key| hash[key] = [] }
lines.each do |line|
  if (match = line.match(/^\s*([0-9a-fA-F]+):\s+([0-9a-fA-F]{8})\s+(\S+)(?:\s+(.*))?$/))
    address = match[1].to_i(16)
    abort "#{label}: duplicate instruction at 0x#{address.to_s(16)}" if instructions.key?(address)
    instructions[address] = [match[3], match[4].to_s]
  elsif (match = line.match(/^\s*([0-9a-fA-F]+):\s+(ARM64_RELOC_\S+)\s+(\S+)\s*$/))
    relocations[match[1].to_i(16)] << [match[2], match[3]]
  end
end

abort "#{label}: objdump emitted no instructions" if instructions.empty?
start_address = headers.fetch(0).fetch(0)
addresses = instructions.keys.sort
abort "#{label}: first instruction does not start at the symbol" unless addresses.first == start_address
addresses.each_cons(2) do |left, right|
  abort "#{label}: non-contiguous arm64 instructions" unless right == left + 4
end
end_address = addresses.last + 4

relocations.each_key do |address|
  abort "#{label}: relocation does not identify an instruction" unless instructions.key?(address)
end

external_edges = []
direct_opcodes = /\A(?:b|bl|b\.[a-z0-9.]+|bc\.[a-z0-9.]+|cbz|cbnz|tbz|tbnz)\z/
indirect_opcodes = /\A(?:br|blr|braa|brab|braaz|brabz|blraa|blrab|blraaz|blrabz)(?:\.[a-z0-9.]+)?\z/
instructions.each do |address, (opcode, operands)|
  abort "#{label}: indirect branch or call at 0x#{address.to_s(16)}" if opcode.match?(indirect_opcodes)
  if %w[svc hvc smc eret drps].include?(opcode)
    abort "#{label}: privileged or exception transfer at 0x#{address.to_s(16)}"
  end
  if opcode == "ret" && !operands.empty? && operands != "x30"
    abort "#{label}: return uses an unreviewed register at 0x#{address.to_s(16)}"
  end
  branches = opcode.match?(direct_opcodes)
  site_relocations = relocations.fetch(address, [])
  unless branches
    abort "#{label}: relocation attached to a non-branch instruction" unless site_relocations.empty?
    next
  end

  unless site_relocations.empty?
    abort "#{label}: external edge is not a plain b/bl" unless %w[b bl].include?(opcode)
    abort "#{label}: branch has more than one relocation" unless site_relocations.length == 1
    type, target = site_relocations.fetch(0)
    abort "#{label}: unrecognised branch relocation #{type}" unless type == "ARM64_RELOC_BRANCH26"
    external_edges << target
    next
  end

  target_match = operands.match(/\b0x([0-9a-fA-F]+)\b/)
  abort "#{label}: direct branch target could not be parsed" unless target_match
  target = target_match[1].to_i(16)
  unless (start_address...end_address).cover?(target)
    abort "#{label}: unrelocated branch leaves the callback body at 0x#{address.to_s(16)}"
  end
end

unless external_edges == [expected_edge]
  actual = external_edges.empty? ? "<none>" : external_edges.join(", ")
  abort "#{label}: external edge set changed: #{actual}"
end
RUBY
    status="$?"
    set -e
    if [[ "${status}" -ne 0 ]]; then
        cat "${dump_file}" >&2
        rm -f "${dump_file}"
        die "${label} Release object inspection failed"
    fi
    rm -f "${dump_file}"
}

verify_function capture-handler "${capture_symbol}" _yun_rt_ring_write
verify_function far-end-provider "${far_end_symbol}" _yun_rt_ring_read
verify_function far-end-thunk "${far_end_thunk_symbol}" "${far_end_symbol}"

echo "AEC Release Swift callback bodies: 3 verified; only reviewed ring/thunk edges (not transitive callees)"
