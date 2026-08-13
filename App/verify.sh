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
# Which steps to run, as a comma-separated list of substrings, and which flow
# check section.
#
# Because the whole gate is six to ten minutes and most changes touch one thing.
# Running all of it for a one-line edit is not thoroughness, it is a reason to
# stop running it — and a gate nobody runs is worse than no gate. The ladder is
# printed by `--list`; the rule is to climb it, not to start at the top.
ONLY=""
FLOW_ONLY=""
for argument in "$@"; do
	case "${argument}" in
	--full) FULL=1 ;;
	--fresh) FRESH=1 ;;
	--only=*) ONLY="${argument#*=}" ;;
	--flow=*)
		FLOW_ONLY="${argument#*=}"
		FULL=1
		;;
	--list)
		cat <<'LADDER'
verify.sh runs these, in this order. Each is a substring match for --only.

  build                          swift build                       ~1-30 s
  strict formatting             swift-format lint --strict           ~2 s
  tests                          2020 of them                         ~80 s
  strings                        both tables, and every loc()          ~1 s
  app bundle                     build and isolated resource smoke   ~50 s
  settings entry                 opens a real settings window          ~2 s
  offscreen render               every panel, no window server       ~20 s
  photograph the real window     what the window server drew         ~70 s
  --full adds:
  nobody else has the devices    refuses to contend                    ~0 s
  audio can start at all         one IO cycle                         ~3 s
  the path is bit-exact          release build, measured             ~40 s
  flow check                     the whole interface, live        ~150-230 s
  --fresh adds:
  a fresh clone                  built from nothing                  ~120 s

  ./App/verify.sh --only=build,tests
  ./App/verify.sh --only=strings
  ./App/verify.sh --flow="more than one input"    one section, ~15 s

A narrowed run says so at the end, and says what it did not check.
LADDER
		exit 0
		;;
	esac
done

# True when this step was asked for. An empty --only means all of them.
wanted() {
	[[ -z "${ONLY}" ]] && return 0
	local step="$1" piece
	local IFS=,
	for piece in ${ONLY}; do
		[[ "${step}" == *"${piece}"* ]] && return 0
	done
	return 1
}

# Checked before any `--full` unit test is allowed to inspect or alter the live
# HAL. The flow runner repeats the check immediately before its longer lease.
nobody_else_has_the_devices() {
	local others
	others=$(pgrep -x YunAudioApp | wc -l | tr -d ' ')
	[[ "${others}" == "0" ]]
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
rm -f build/verify-last-failure.log
FAILED=()
SKIPPED=()

step() {
	local name="$1"
	shift
	if ! wanted "${name}"; then
		SKIPPED+=("${name} — not in --only=${ONLY}")
		return 0
	fi
	printf '  %-34s' "${name}…"
	if "$@" >"${WORK}/last.txt" 2>&1; then
		echo "ok"
		return 0
	fi
	echo "FAILED"
	FAILED+=("${name}")
	mkdir -p build
	cp "${WORK}/last.txt" build/verify-last-failure.log
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
		tr '\r' '\n' <"${WORK}/last.txt" | grep -aE "error: |✘"
		tr '\r' '\n' <"${WORK}/last.txt" | sed -n '/flow(s) failed/,$p'
	} | grep -avE "^\s+(builtin-|/Applications/|cd /)" | cut -c1-200 | head -20)
	if [[ -n "${errors}" ]]; then
		diagnostics="${errors}"
	else
		diagnostics=$(
			tr '\r' '\n' <"${WORK}/last.txt" |
				grep -aE "warning: " |
				cut -c1-200 |
				head -8
		)
	fi
	if [[ -n "${diagnostics}" ]]; then
		sed 's/^/      /' <<<"${diagnostics}"
	else
		sed 's/^/      /' <<<"$(tail -8 "${WORK}/last.txt" | cut -c1-200)"
	fi
	echo "      full output: build/verify-last-failure.log"
	return 1
}

echo "verifying YunAudio"
echo

if [[ "${FULL}" == "1" ]] && ! nobody_else_has_the_devices; then
	echo "stopping: --full was asked for while another YunAudioApp owns the devices"
	exit 2
fi

# ---------------------------------------------------------------- it compiles
# The build first and alone: everything after it is a check against a binary,
# and running the tests against one that did not compile reports the previous
# build's results as if they were this one's.
if ! step "build" swift build; then
	echo
	echo "stopping: it does not compile, so nothing below would be measuring this change"
	exit 1
fi

strict_formatting() {
	local formatter
	formatter="$(xcrun --find swift-format)" || return 1
	"${formatter}" lint --strict --recursive Sources Tests
}

step "strict formatting" strict_formatting

# The count as well as the result, because **a deleted test cannot fail.**
#
# A merge resolution took the wrong side of a hunk and removed a whole suite —
# the one asserting that every reader of the realtime graph takes the lock,
# written an hour earlier precisely because that mistake is easy to make again.
# The run stayed green and the number went down, and nothing was looking at the
# number. A floor is crude, and crude is the point: it cannot be satisfied by
# a test that quietly stopped existing.
tests_ran_and_match_baseline() {
	local output count floor
	# Several suites deliberately fault the same process-wide allocator, Audio Unit
	# registry and device-lock seams. Serial execution keeps those measurements
	# independent instead of turning the acceptance gate into a scheduler lottery.
	local command=(env YUNAUDIO_LIVE_HAL_TESTS=0 swift test --no-parallel)
	if [[ "${FULL}" == "1" ]]; then
		command=(env YUNAUDIO_LIVE_HAL_TESTS=1 swift test --no-parallel)
	fi
	output=$("${command[@]}" 2>&1) || {
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
	# Verification is read-only. Updating this on the way past made a check
	# silently edit four tracked files, so the evidence depended on whether the
	# caller noticed and kept those edits. A larger suite is good, but the new
	# number and the three public claims are a deliberate part of that change.
	if [[ "${count}" -gt "${floor}" ]]; then
		echo "error: ${count} tests ran, but App/test-floor.txt still says ${floor}."
		echo "error: update the floor and all three README counts explicitly in this change."
		return 1
	fi
	return 0
}

step "tests" tests_ran_and_match_baseline
if [[ "${FULL}" != "1" ]] && wanted "tests"; then
	SKIPPED+=("8 live-HAL unit tests — not authorised; run with --full on an isolated machine")
fi
step "strings" ./App/check-strings.sh
APP_BUNDLE_FAILED=0
step "app bundle" ./App/build-app.sh --verify || APP_BUNDLE_FAILED=1

# An unbuilt bundle makes every check below meaningless rather than failing, so
# stop here rather than reporting a stale binary as verified.
if [[ "${APP_BUNDLE_FAILED}" == "1" ]]; then
	echo
	echo "stopping: nothing below can be trusted against a bundle that did not build"
	printf 'failed: %s\n' "${FAILED[*]}"
	exit 1
fi

settings_entry_opened() {
	local output
	output=$(
		YUNAUDIO_SETTINGS_CHECK=1 ./build/YunAudio.app/Contents/MacOS/YunAudioApp 2>&1
	) || {
		echo "${output}"
		return 1
	}
	echo "${output}"
	grep -q "settings entry: handled=1 window=1 " <<<"${output}"
}

step "settings entry" settings_entry_opened

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
	[[ "${count}" -eq 67 ]] || {
		echo "expected exactly 67 rendered panels, got ${count}"
		return 1
	}
	# Every inspector gets its own filename. `window-light.png` used to be
	# claimed as Sound after the shared model had already been moved to Hardware,
	# so Hardware was rendered twice and Sound not at all.
	local tab appearance missing=()
	while read -r tab; do
		for appearance in light dark; do
			[[ -f "${WORK}/render/window-${tab}-${appearance}.png" ]] ||
				missing+=("window-${tab}-${appearance}.png")
		done
	done < <(sed -n '/enum Inspector: String/,/^    }/p' Sources/YunAudioApp/MainWindow.swift |
		grep -oE '^        case [a-z]+' | awk '{print $2}')
	[[ ${#missing[@]} -eq 0 ]] || {
		echo "missing rendered inspector(s): ${missing[*]}"
		return 1
	}
}

# Any crash report this run produced, whatever it exited with.
#
# On 2026-07-31 the capture gate threw an uncaught AppKit exception *after*
# writing every one of its files, so it exited zero and every check passed. The
# only witness was the report macOS wrote, which nobody was reading. A gate that
# cannot tell a clean run from a run that died at the end is a gate that
# certifies crashes.
crash_reports_since() {
	local marker="$1"
	find ~/Library/Logs/DiagnosticReports -maxdepth 2 -name 'YunAudioApp-*.ips' \
		-newer "${marker}" 2>/dev/null | head -5
}

no_new_crash_report() {
	local found
	found=$(crash_reports_since "${WORK}/crash-marker")
	[[ -z "${found}" ]] || {
		echo "the run wrote a crash report — not accepted:"
		echo "${found}"
		return 1
	}
}

photographed_the_real_window() {
	rm -rf "${WORK}/shot"
	rm -f "${WORK}/capture-complete"
	touch "${WORK}/crash-marker"
	# Bounded, but a complete set of files is not enough. A capture once wrote
	# every photograph and then wedged while releasing CoreAudio; killing it and
	# accepting the files certified the exact shutdown failure that leaves the
	# system's Sound menu spinning. The process has to terminate cleanly too.
	if [[ "${FULL}" == "1" ]]; then
		YUNAUDIO_SCREENSHOT="${WORK}/shot" \
			YUNAUDIO_CAPTURE_COMPLETION="${WORK}/capture-complete" \
			./build/YunAudio.app/Contents/MacOS/YunAudioApp &
	else
		YUNAUDIO_SCREENSHOT="${WORK}/shot" YUNAUDIO_SCREENSHOT_NO_AUDIO=1 \
			YUNAUDIO_CAPTURE_COMPLETION="${WORK}/capture-complete" \
			./build/YunAudio.app/Contents/MacOS/YunAudioApp &
	fi
	local capture=$!
	local waited=0
	local completed_at=-1
	local capture_status=0
	while kill -0 "${capture}" 2>/dev/null && [[ ${waited} -lt 90 ]]; do
		sleep 1
		waited=$((waited + 1))
		if [[ "${completed_at}" -lt 0 && -f "${WORK}/capture-complete" ]]; then
			completed_at=${waited}
		fi
		if [[ "${completed_at}" -ge 0 && $((waited - completed_at)) -ge 5 ]]; then
			break
		fi
	done
	if kill -0 "${capture}" 2>/dev/null; then
		kill "${capture}" 2>/dev/null
		local stopping=0
		while kill -0 "${capture}" 2>/dev/null && [[ "${stopping}" -lt 5 ]]; do
			sleep 1
			stopping=$((stopping + 1))
		done
		if kill -0 "${capture}" 2>/dev/null; then
			kill -KILL "${capture}" 2>/dev/null || true
		fi
		wait "${capture}" 2>/dev/null || true
		if [[ "${completed_at}" -ge 0 ]]; then
			echo "the window capture did not exit within 5s of finishing its photographs"
		else
			echo "the window capture did not finish within ${waited}s"
		fi
		return 1
	else
		wait "${capture}" 2>/dev/null || capture_status=$?
	fi
	# Its exit status includes appearance, missing-file and visible-spectrum
	# assertions, and now also proves teardown reached the end of the process.
	if [[ "${capture_status}" -ne 0 ]]; then
		echo "the window capture rejected its own output (${capture_status})"
		return 1
	fi
	[[ -f "${WORK}/capture-complete" ]] || {
		echo "the window capture exited without marking its photographs complete"
		return 1
	}
	local count
	count=$(find "${WORK}/shot" -name '*.png' | wc -l | tr -d ' ')
	# Both appearances at both sizes and every tab. A full run also adds the
	# running state; the ordinary gate never reserves an input just for a photo.
	local expected=14
	[[ "${count}" -ge "${expected}" ]] || {
		echo "expected at least ${expected} photographs, got ${count}"
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
	# Last, so a run that wrote every image and then died still fails.
	no_new_crash_report || return 1
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
audio_can_start() {
	local output="${WORK}/audio-start.txt"
	.build/debug/yunaudio-cli audio-start >"${output}" 2>&1 &
	local probe=$!
	local waited=0
	while kill -0 "${probe}" 2>/dev/null && [[ "${waited}" -lt 10 ]]; do
		sleep 1
		waited=$((waited + 1))
	done
	if kill -0 "${probe}" 2>/dev/null; then
		kill "${probe}" 2>/dev/null
		wait "${probe}" 2>/dev/null
		echo "error: the CoreAudio start probe did not return within ${waited}s"
		return 1
	fi
	local status=0
	wait "${probe}" || status=$?
	cat "${output}"
	[[ "${status}" == "0" ]] || return 1
	local rate
	rate=$(grep "cycle rate" "${output}" | grep -oE '[0-9]+\.[0-9]' | head -1)
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
		step "flow check" env YUNAUDIO_FLOWCHECK=1 \
			YUNAUDIO_FLOWCHECK_ONLY="${FLOW_ONLY}" \
			./build/YunAudio.app/Contents/MacOS/YunAudioApp
		[[ -n "${FLOW_ONLY}" ]] &&
			SKIPPED+=("every flow check section except '${FLOW_ONLY}'")
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
	( cd "${where}" && source ./App/toolchain.sh >/dev/null 2>&1 && ./App/build-app.sh --verify ) ||
		return 1
	[[ -x "${where}/build/YunAudio.app/Contents/MacOS/YunAudioApp" ]] || {
		echo "the clone built without producing a binary"
		return 1
	}
    # The same process-wide allocator, Audio Unit registry and device-lock
    # seams which require serial execution in the primary gate exist in the
    # clone too. A fresh filesystem is not authority to make those global
    # fault fixtures race each other.
    ( cd "${where}" && source ./App/toolchain.sh >/dev/null 2>&1 && \
        env YUNAUDIO_LIVE_HAL_TESTS=0 swift test --no-parallel ) || return 1
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
