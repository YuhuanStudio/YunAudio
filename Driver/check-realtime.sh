#!/bin/bash
#
# Static half of the driver's realtime contract. The numerical half lives in
# Tests/DriverCoreTests.c; this catches a future edit that puts a blocking or
# allocating call back into either deadline path.
set -euo pipefail

cd "$(dirname "$0")"

extract_function() {
	local name="$1"
	awk -v name="${name}" '
		$0 ~ "static (bool|void|OSStatus|UInt32|UInt64|Float32|YunClockSnapshot|YunRingWriteAdmission) " name "\\(" {
			inside = 1
		}
		inside {
			print
			line = $0
			opens = gsub(/{/, "{", line)
			line = $0
			closes = gsub(/}/, "}", line)
			depth += opens - closes
			if (opens > 0) saw_body = 1
			if (saw_body && depth == 0) exit
		}
	' Sources/YunAudioDriver.c
}

for function in \
	Float32FromBits \
	PackStereoFrame \
	UnpackStereoFrame \
	TimestampPeriodAtHostTime \
	RebasedAnchorHostTime \
	ReadPublishedClock \
	SampleTimeToFrame \
	RingSpanCanBeTagged \
	RingWriteSpanIsPublished \
	ReleaseRingWritePrefix \
	ClaimRingWriteSpan \
	PublishRingWrite \
	ReadRingSpan \
	FailSilentIO \
	Yun_GetZeroTimeStamp \
	Yun_WillDoIOOperation \
	Yun_BeginIOOperation \
	Yun_DoIOOperation \
	Yun_EndIOOperation; do
	body="$(extract_function "${function}")"
	if [[ -z "${body}" ]]; then
		echo "error: could not find ${function}" >&2
		exit 1
	fi
	if grep -Eq 'pthread_mutex|malloc\(|calloc\(|realloc\(|free\(|CF[A-Z]|dispatch_|os_log|printf|pow[f]?\(' \
		<<<"${body}"; then
		echo "error: ${function} contains blocking, allocating or logging work" >&2
		exit 1
	fi
done

if grep -Eq \
	'(AudioObject(Get|Set|Add|Remove)[A-Za-z]*|AudioDevice(Start|Stop|Create)|IOBluetooth|dispatch_source_create|pthread_create)\(' \
	Sources/YunAudioDriver.c; then
	echo "error: the driver starts work or reaches into another audio device while idle" >&2
	exit 1
fi

echo "driver realtime paths: no locks, allocations or logging"
echo "driver idle path: no worker, timer, hardware or Bluetooth calls"
