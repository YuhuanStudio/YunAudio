#!/bin/bash
#
# The acceptance gate. One command, every check, and no way to pass by
# forgetting one.
#
# This exists because the checks were a list in a document and a list in a
# document is a list somebody skips. Two things went wrong in one afternoon and
# both were the procedure rather than the code:
#
#   1. A whole feature shipped with no interface at all. The flow check passed,
#      the unit tests passed, the offscreen render looked right — and none of
#      them can see that a tab is missing from a row, because the render draws
#      whichever tab is selected. Only the photograph of the real window shows
#      it, and the photograph was the step that got skipped.
#
#   2. A build failure was hidden by a grep. `swift build 2>&1 | grep error:`
#      with a pattern that did not match the driver's own failure line printed
#      nothing, read as success, and a stale binary was photographed and
#      believed. **Exit codes decide here. Output is for people.**
#
# Everything below is a step, every step is checked by its status, and the
# summary at the end says what ran and — the part that matters — what did not.

set -uo pipefail
cd "$(dirname "$0")/.."
source ./App/toolchain.sh

FULL=0
for argument in "$@"; do
	case "${argument}" in
	--full) FULL=1 ;;
	esac
done

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
FAILED=()
SKIPPED=()

step() {
	local name="$1"
	shift
	printf '  %-34s' "${name}…"
	if "$@" >"${WORK}/last.txt" 2>&1; then
		echo "ok"
		return 0
	fi
	echo "FAILED"
	FAILED+=("${name}")
	# Diagnostics only. A failing `swift build` prints the whole frontend
	# invocation — several thousand characters of `-Xcc` flags — and burying
	# the one line that says what is wrong under that is how a gate stops being
	# read. Falls back to the tail when nothing matched, so a failure with no
	# recognisable diagnostic still shows something.
	local diagnostics
	diagnostics=$(grep -aE "(error|warning): |✘|FAILED|failed:" "${WORK}/last.txt" |
		grep -avE "^\s+(builtin-|/Applications/|cd /)" | cut -c1-200 | head -12)
	if [[ -n "${diagnostics}" ]]; then
		sed 's/^/      /' <<<"${diagnostics}"
	else
		sed 's/^/      /' <<<"$(tail -8 "${WORK}/last.txt" | cut -c1-200)"
	fi
	return 1
}

echo "verifying YunAudio"
echo

# ---------------------------------------------------------------- it compiles
# The build first and alone: everything after it is a check against a binary,
# and running the tests against one that did not compile reports the previous
# build's results as if they were this one's.
if ! step "build" swift build; then
	echo
	echo "stopping: it does not compile, so nothing below would be measuring this change"
	exit 1
fi
step "tests" swift test
step "strings" ./App/check-strings.sh
step "app bundle" ./App/build-app.sh

# An unbuilt bundle makes every check below meaningless rather than failing, so
# stop here rather than reporting a stale binary as verified.
if [[ ${#FAILED[@]} -gt 0 ]]; then
	echo
	echo "stopping: nothing below can be trusted against a bundle that did not build"
	printf 'failed: %s\n' "${FAILED[*]}"
	exit 1
fi

# ------------------------------------------------------- it looks like itself
#
# Two different pictures, because each is blind to what the other catches.
# `PanelRenderer` rasterises a view tree offscreen: good for colour and spacing,
# structurally unable to notice the window's own title bar, where content is
# clipped at the minimum size, or that a control is missing from a row.
# `WindowCapture` photographs the real window the window server drew.
render_wrote_everything() {
	rm -rf "${WORK}/render"
	YUNAUDIO_RENDER="${WORK}/render" ./build/YunAudio.app/Contents/MacOS/YunAudioApp || return 1
	# The renderer exits non-zero when a file could not be written, but a run
	# that wrote nothing at all also exits zero, so the count is checked too.
	local count
	count=$(find "${WORK}/render" -name '*.png' | wc -l | tr -d ' ')
	[[ "${count}" -ge 20 ]] || {
		echo "only ${count} panels rendered"
		return 1
	}
}

photographed_the_real_window() {
	rm -rf "${WORK}/shot"
	YUNAUDIO_SCREENSHOT="${WORK}/shot" ./build/YunAudio.app/Contents/MacOS/YunAudioApp || return 1
	local count
	count=$(find "${WORK}/shot" -name '*.png' | wc -l | tr -d ' ')
	# Both appearances at both sizes, plus the running state.
	[[ "${count}" -ge 6 ]] || {
		echo "only ${count} photographs taken"
		return 1
	}
	# Copied out, because a picture nobody looks at is not a check. The path is
	# printed at the end.
	rm -rf build/screenshots
	cp -R "${WORK}/shot" build/screenshots
}

step "offscreen render" render_wrote_everything
step "photograph the real window" photographed_the_real_window

# ------------------------------------------------------------- it still works
#
# The flow check takes the machine's audio hardware for about four minutes, so
# it is behind a flag rather than in the way of every run. What is *not*
# negotiable is that a run without it says so: a green summary that quietly
# omitted the only check that touches real devices is worse than a red one.
audio_can_start() {
	local rate
	rate=$(.build/debug/yunaudio-cli soak 2>/dev/null | grep "cycle rate" | grep -oE '[0-9]+\.[0-9]' | head -1)
	[[ -n "${rate}" && "${rate}" != "0.0" ]]
}

if [[ "${FULL}" == "1" ]]; then
	# Asked first, because every signal-measuring check fails with a message
	# about its own subject when CoreAudio cannot start IO — and that has cost
	# an afternoon before. See AGENTS.md.
	if step "audio can start at all" audio_can_start; then
		step "flow check" env YUNAUDIO_FLOWCHECK=1 ./build/YunAudio.app/Contents/MacOS/YunAudioApp
	else
		SKIPPED+=("flow check — CoreAudio cannot start IO on this machine; a human must run: sudo killall coreaudiod")
	fi
else
	SKIPPED+=("flow check — not asked for; run with --full")
fi

# ------------------------------------------------------------------ the truth
echo
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
	echo "not checked:"
	printf '  · %s\n' "${SKIPPED[@]}"
	echo
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
	printf 'failed: %s\n' "${FAILED[*]}"
	exit 1
fi

echo "everything asked for passed."
echo "screenshots: build/screenshots — look at them."
[[ ${#SKIPPED[@]} -gt 0 ]] && echo "this is not a full verification; see above."
exit 0
