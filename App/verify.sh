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
FRESH=0
for argument in "$@"; do
	case "${argument}" in
	--full) FULL=1 ;;
	--fresh) FRESH=1 ;;
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
	# The flow check prints its failures as a list *after* the line that says how
	# many there were, so a pattern that matches only the header prints a count
	# and no names — which is what it did, and a count nobody can act on is
	# worse than silence. Everything from that line to the end comes too.
	# Errors first, and warnings only when there were none. Every build here
	# carries a handful of nullability warnings from a C header, and taking the
	# first dozen matching lines meant those crowded out the line that said what
	# actually went wrong — a gate whose failures are unreadable is a gate
	# nobody reads, which is the whole reason it exists.
	local errors
	errors=$( {
		grep -aE "error: |✘" "${WORK}/last.txt"
		sed -n '/flow(s) failed/,$p' "${WORK}/last.txt"
	} | grep -avE "^\s+(builtin-|/Applications/|cd /)" | cut -c1-200 | head -20)
	if [[ -n "${errors}" ]]; then
		diagnostics="${errors}"
	else
		diagnostics=$(grep -aE "warning: " "${WORK}/last.txt" | cut -c1-200 | head -8)
	fi
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
# The count as well as the result, because **a deleted test cannot fail.**
#
# A merge resolution took the wrong side of a hunk and removed a whole suite —
# the one asserting that every reader of the realtime graph takes the lock,
# written an hour earlier precisely because that mistake is easy to make again.
# The run stayed green and the number went down, and nothing was looking at the
# number. A floor is crude, and crude is the point: it cannot be satisfied by
# a test that quietly stopped existing.
tests_ran_and_did_not_shrink() {
	local output count floor
	output=$(swift test 2>&1) || {
		echo "${output}"
		return 1
	}
	# Only the failures and the summary; a passing run prints one line per test.
	echo "${output}" | grep -aE "✘" | head -6
	echo "${output}" | grep -aE "Test run with" | tail -1
	count=$(grep -aoE "Test run with [0-9]+ tests" <<<"${output}" | grep -oE "[0-9]+" | head -1)
	[[ -n "${count}" ]] || {
		echo "the run did not say how many tests it ran"
		return 1
	}
	floor=$(cat App/test-floor.txt 2>/dev/null || echo 0)
	if [[ "${count}" -lt "${floor}" ]]; then
		# Prefixed so the diagnostic filter keeps it. Without that the compiler's
		# own warnings, which every build has, crowd out the one line that says
		# what went wrong — which is the mistake this gate was built to stop
		# making.
		echo "error: ${count} tests ran, and there were ${floor}. Something was deleted."
		echo "error: if that was deliberate, lower App/test-floor.txt in the same commit."
		return 1
	fi
	# Raised on the way past, so the floor follows the high-water mark without
	# anybody having to remember.
	[[ "${count}" -gt "${floor}" ]] && echo "${count}" >App/test-floor.txt
	return 0
}

step "tests" tests_ran_and_did_not_shrink
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
	# Bounded, and judged by what it produced rather than by how it ended. The
	# capture asks the router to start so it can photograph a window with meters
	# in it, and on a machine where CoreAudio cannot start IO that call blocks
	# in `AudioDeviceCreateIOProcID` on a `mach_msg` to a `coreaudiod` that is
	# not answering — measured at four minutes, all of it after every photograph
	# had already been written. Waiting for a clean exit would make the gate
	# hostage to a broken audio server; the photographs are what this step is
	# for, and they are all there.
	YUNAUDIO_SCREENSHOT="${WORK}/shot" ./build/YunAudio.app/Contents/MacOS/YunAudioApp &
	local capture=$!
	local waited=0
	while kill -0 "${capture}" 2>/dev/null && [[ ${waited} -lt 90 ]]; do
		sleep 1
		waited=$((waited + 1))
	done
	if kill -0 "${capture}" 2>/dev/null; then
		kill "${capture}" 2>/dev/null
		wait "${capture}" 2>/dev/null
		echo "  (the capture had to be stopped after ${waited}s — checking what it wrote)"
	else
		wait "${capture}" 2>/dev/null
	fi
	local count
	count=$(find "${WORK}/shot" -name '*.png' | wc -l | tr -d ' ')
	# Both appearances at both sizes, plus the running state.
	[[ "${count}" -ge 6 ]] || {
		echo "only ${count} photographs taken"
		return 1
	}
	# One photograph per inspector tab, checked against the tabs the source
	# declares rather than against a number. This is the assertion that would
	# have caught a whole feature shipping with no tab at all: the count would
	# have been right, because the tab that was missing was missing from both
	# the row and the list of things to photograph.
	local tab missing=()
	while read -r tab; do
		[[ -f "${WORK}/shot/live-tab-${tab}-dark.png" ]] || missing+=("${tab}")
	done < <(sed -n '/enum Inspector: String/,/^    }/p' Sources/YunAudioApp/MainWindow.swift |
		grep -oE '^        case [a-z]+' | awk '{print $2}')
	[[ ${#missing[@]} -eq 0 ]] || {
		echo "no photograph of tab(s): ${missing[*]}"
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
# The two headline claims, together, because they are measured by the same run:
# every sample arrives unchanged, and the IO thread allocates nothing.
#
# **Release only.** A debug build allocates from Swift's own checking machinery —
# a million times in one self-test — so a debug measurement of this says nothing
# and reads as a catastrophe. It was measured by hand until now, which for the
# two claims this project is actually about is not good enough.
bit_exact_release() {
	swift build -c release --product yunaudio-cli >/dev/null 2>&1 || return 1
	local output
	output=$(.build/release/yunaudio-cli selftest "MacBook Pro" "YunAudio" 2>&1)
	echo "${output}" | tail -3
	grep -q "^bit-exact:" <<<"${output}" || return 1
	# Counted rather than pattern-matched on the happy phrasing: the failing
	# line says "ALLOCATIONS ... the no-allocation rule is broken", and a check
	# that only looked for the good sentence would pass on an empty run.
	grep -q "realtime path: 0 allocations" <<<"${output}" || return 1
	# The identical count has to be the whole count. "1/261738 identical" also
	# begins with "bit-exact:".
	local counts
	counts=$(grep -oE "[0-9]+/[0-9]+ samples identical" <<<"${output}" | head -1)
	[[ -n "${counts}" ]] || return 1
	[[ "${counts%%/*}" == "$(echo "${counts}" | sed 's|.*/||; s| .*||')" ]]
}

# Asked before anything is measured, not after it has produced a number.
#
# Two copies do not produce two results, they produce two wrong ones — and the
# wrong one looks like a defect in whatever was being measured. Seen here: the
# same self-test gave "261738/261738 identical" and, a minute later with two
# other copies running, "217/261738 (0.08%)". A bit-exactness failure is the
# most alarming thing this gate can print and it was somebody else's flow check.
nobody_else_has_the_devices() {
	# Matched on the executable name, not on a command line. `pgrep -f` matches
	# any process whose *arguments* mention the path — including a diagnostic
	# command that merely names it — so running one alongside the gate made it
	# skip every audio check and report that it had. It said so under "not
	# checked" rather than lying, which is the only reason this was noticed
	# rather than believed.
	local others
	others=$(pgrep -x YunAudioApp | wc -l | tr -d ' ')
	[[ "${others}" == "0" ]]
}

audio_can_start() {
	local rate
	rate=$(.build/debug/yunaudio-cli soak 2>/dev/null | grep "cycle rate" | grep -oE '[0-9]+\.[0-9]' | head -1)
	[[ -n "${rate}" && "${rate}" != "0.0" ]]
}

if [[ "${FULL}" == "1" ]]; then
	# Asked first, because every signal-measuring check fails with a message
	# about its own subject when CoreAudio cannot start IO — and that has cost
	# an afternoon before. See AGENTS.md.
	if ! nobody_else_has_the_devices; then
		SKIPPED+=("everything that touches audio — another copy of YunAudio is running and would be competing for the devices")
	elif step "audio can start at all" audio_can_start; then
		step "the path is bit-exact, release" bit_exact_release
		step "flow check" env YUNAUDIO_FLOWCHECK=1 ./build/YunAudio.app/Contents/MacOS/YunAudioApp
	else
		SKIPPED+=("flow check — CoreAudio cannot start IO on this machine; a human must run: sudo killall coreaudiod")
	fi
else
	SKIPPED+=("flow check — not asked for; run with --full")
fi

# ------------------------------------------------- somebody else can build it
#
# A clone into a directory of its own, built with nothing of this working tree
# to lean on. It is the only check that can catch the class of thing that works
# here and nowhere else: a file that was never added, a path that happens to
# exist, a build product that is not actually reproduced by the script.
#
# Behind a flag because it is a fresh clone and a full build. Worth running
# before anybody is told to try it — which, without a paid developer account to
# notarise anything, is the *primary* way this gets to people. A locally built
# binary carries no quarantine flag, so Gatekeeper never enters into it.
builds_from_a_fresh_clone() {
	local where
	where="${WORK}/fresh"
	rm -rf "${where}"
	git clone --quiet . "${where}" || return 1
	( cd "${where}" && source ./App/toolchain.sh >/dev/null 2>&1 && ./App/build-app.sh ) ||
		return 1
	[[ -x "${where}/build/YunAudio.app/Contents/MacOS/YunAudioApp" ]] || {
		echo "the clone built without producing a binary"
		return 1
	}
	( cd "${where}" && source ./App/toolchain.sh >/dev/null 2>&1 && swift test ) || return 1
}

if [[ "${FRESH}" == "1" ]]; then
	step "builds from a fresh clone" builds_from_a_fresh_clone
else
	SKIPPED+=("a fresh clone — not asked for; run with --fresh before telling anybody to try it")
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
