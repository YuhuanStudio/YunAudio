#!/bin/bash
# Proves that the assembled application accepts the signed feed and rejects the
# same feed after one byte changes. No audio service is admitted in this mode.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/YunAudio.app/Contents/MacOS/YunAudioApp"
[[ -x "${APP}" ]] || {
	echo "build/YunAudio.app is missing"
	exit 1
}

WORK="$(mktemp -d)"
SERVER_PID=""
cleanup() {
	if [[ -n "${SERVER_PID}" ]]; then
		kill "${SERVER_PID}" 2>/dev/null || true
		wait "${SERVER_PID}" 2>/dev/null || true
	fi
	rm -rf -- "${WORK}"
}
trap cleanup EXIT

cp updates/appcast.xml "${WORK}/appcast.xml"
PORT="$(python3 - <<'PY'
import socket
with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    print(listener.getsockname()[1])
PY
)"
python3 -m http.server "${PORT}" --bind 127.0.0.1 --directory "${WORK}" \
	>"${WORK}/server.log" 2>&1 &
SERVER_PID=$!

for _ in {1..50}; do
	if curl --fail --silent "http://127.0.0.1:${PORT}/appcast.xml" >/dev/null; then
		break
	fi
	sleep 0.1
done
curl --fail --silent "http://127.0.0.1:${PORT}/appcast.xml" >/dev/null

probe() {
	local url="$1" marker="$2" output="$3"
	YUNAUDIO_UPDATE_CHECK="${marker}" \
		"${APP}" \
		-SUFeedURL "${url}" \
		-SUEnableAutomaticChecks NO >"${output}" 2>&1 &
	local probe=$! waited=0
	while kill -0 "${probe}" 2>/dev/null && [[ ! -s "${marker}" ]] &&
		[[ "${waited}" -lt 200 ]]; do
		sleep 0.1
		waited=$((waited + 1))
	done
	if [[ ! -s "${marker}" ]]; then
		kill "${probe}" 2>/dev/null || true
		wait "${probe}" 2>/dev/null || true
		echo "the Sparkle feed check did not answer within 20 seconds"
		cat "${output}"
		return 1
	fi
	wait "${probe}"
}

VALID_MARKER="${WORK}/valid.txt"
probe \
	"http://127.0.0.1:${PORT}/appcast.xml?valid=1" \
	"${VALID_MARKER}" "${WORK}/valid.log"
[[ "$(<"${VALID_MARKER}")" == "ok" ]] || {
	cat "${VALID_MARKER}"
	return 1
}

# Same length, different byte: neither a content-length check nor the app's own
# parser can distinguish this. Only the signed-feed verification can reject it.
perl -pi -e 's/<title>YunAudio<\x2ftitle>/<title>XunAudio<\x2ftitle>/' \
	"${WORK}/appcast.xml"
TAMPERED_MARKER="${WORK}/tampered.txt"
probe \
	"http://127.0.0.1:${PORT}/appcast.xml?tampered=1" \
	"${TAMPERED_MARKER}" "${WORK}/tampered.log"
grep -q '^error: Error Domain=SUSparkleErrorDomain' "${TAMPERED_MARKER}" || {
	cat "${TAMPERED_MARKER}"
	return 1
}

echo "signed feed accepted; one-byte change refused"
