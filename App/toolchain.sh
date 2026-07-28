#!/bin/bash
#
# Picks a toolchain new enough to compile this project, and exports
# DEVELOPER_DIR so every swift invocation after it agrees.
#
# Source it; do not run it:
#     source "$(dirname "$0")/toolchain.sh"
#
# Why this exists. Live transcription uses AnalyzerInputConverter, which is
# macOS 27 API. A machine can be running macOS 27 and still have a selected
# Xcode carrying the macOS 26 SDK — that is the ordinary state of affairs the
# week a system ships — and the failure it produces is
#
#     error: cannot find type 'AnalyzerInputConverter' in scope
#
# which reads like a typo rather than like "your SDK is a year old". So the
# scripts look for an SDK that has it instead of leaving somebody to guess.
#
# Only the SDK version is checked, not the running system: the application still
# supports macOS 26 and reports transcription unavailable there. It is the
# compiler that needs the newer headers, not the user.

REQUIRED_SDK_MAJOR=27

# Prints the macOS SDK major version of a developer directory, or nothing.
sdk_major_of() {
	local developer="$1"
	local sdk="${developer}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
	[ -e "${sdk}" ] || return 0
	# SDKSettings.json is present in every modern SDK and needs no xcodebuild,
	# which is worth avoiding here: it is slow and it fails loudly on a
	# developer directory that is only half installed.
	local version
	version=$(/usr/bin/plutil -extract Version raw -o - \
		"${sdk}/SDKSettings.plist" 2>/dev/null) || return 0
	echo "${version%%.*}"
}

toolchain_current=$(xcode-select -p 2>/dev/null || true)
toolchain_major=$(sdk_major_of "${toolchain_current}")

if [ -z "${toolchain_major}" ] || [ "${toolchain_major}" -lt "${REQUIRED_SDK_MAJOR}" ]; then
	toolchain_found=""
	for candidate in /Applications/Xcode*.app/Contents/Developer; do
		[ -d "${candidate}" ] || continue
		candidate_major=$(sdk_major_of "${candidate}")
		[ -n "${candidate_major}" ] || continue
		if [ "${candidate_major}" -ge "${REQUIRED_SDK_MAJOR}" ]; then
			toolchain_found="${candidate}"
			break
		fi
	done

	if [ -n "${toolchain_found}" ]; then
		export DEVELOPER_DIR="${toolchain_found}"
		echo "using ${toolchain_found} (macOS ${REQUIRED_SDK_MAJOR} SDK)"
	else
		echo "error: no installed Xcode carries a macOS ${REQUIRED_SDK_MAJOR} SDK." >&2
		echo "       Live transcription needs it to compile. Install a newer" >&2
		echo "       Xcode, or select one with: sudo xcode-select -s <Xcode.app>" >&2
		exit 1
	fi
fi
