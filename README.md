# YunAudio

A menu bar audio router for macOS, with a virtual device of its own.

It exists because Discord's WebRTC engine reaches down to the HAL and fights
high-end USB microphones for control of the device, producing a crackle once per
second. Routing the microphone into a virtual device that Discord opens instead
makes the problem go away. Along the way it turned out macOS has several
capabilities in this area that nothing else exposes, so the project grew.

Requires macOS 26 or later.

## What is different about it

**The signal path is provably bit-exact.** Not "we don't think anything
resamples it" — measured. `yunaudio-cli selftest` sends a 24-bit pseudorandom
sequence through the whole path, reads it back off the loopback, recovers the
delay from the data and compares every sample:

```
bit-exact: 261400/261400 samples identical, delay 872 frames
clock lock held at 0.999986 throughout
```

That is possible because YunAudio ships its own virtual device rather than
borrowing one. A CoreAudio driver defines its own clock through
`GetZeroTimeStamp()`, so this one derives its sample clock from the microphone
the app is actually capturing. The two devices then advance together, the HAL's
drift correction can be switched off, and nothing on the path resamples. A
third-party loopback device cannot do this — it has no idea which microphone you
care about.

The `0.999986` is your microphone's crystal, measured: 14 parts per million slow,
which is 50 ms of drift per hour if nobody corrects it.

**And you can run that check yourself.** It is in Preferences → Diagnostics, not
only in the CLI: press a button and the app sends the sequence through your own
path and grades what comes back. On a path that is not clock-locked it reports
what is actually true — resampled, with the recovered loopback delay and the
size of the conversion — rather than pass or fail.

**It tells you the truth about the path.** Bit-exact, resampled, or processed;
measured round-trip latency; whether the clock lock is actually holding. When you
enable voice isolation it says so and stops claiming bit-exactness, because
processing the signal is the opposite of leaving it alone.

**Voice isolation from Apple's own model.** `AUSoundIsolation` is the model
behind FaceTime's Voice Isolation, on-device and free, and no other router in
this category exposes it as a general microphone processor. Measured here: 56 ms
of added latency, under a quarter of the IO deadline in CPU.

**Two gain stages, in the right order.** The microphone's own gain happens in
the hardware before its converter, so raising it costs no headroom; a digital
trim afterwards can only amplify what the converter already decided, noise
included. Both are here and the hardware one is first, which is the order that
matters and the one nothing else on macOS puts in front of you. The Seiren
publishes 0 to +36 dB; the built-in microphone publishes −12 to +12.

**It knows what your microphone's channels actually are.** CoreAudio reports
that a Seiren V3 Pro has three inputs and nothing about what is on them. They
are the processed capsule, the dry capsule, and the capsule past the
microphone's own expander — which sits ahead of the converter, so it removes
room noise before anything can clip. The picker names all three and says what
each is for. That mapping came out of the device's own module dumping its
internal topology, and nothing else on macOS will tell you.

**Application audio with no extra driver.** Capture any app through
`AudioHardwareCreateProcessTap`, optionally silencing its normal output. Loopback
and its peers need their own plug-in for this; here it is a documented API.

**It costs almost nothing to run.** 0.40% of one core for a stereo route at 128
frames, 4.7 MB resident, measured over a six-minute run rather than estimated.

**The realtime path allocates nothing.** Verified rather than asserted: a hook on
the allocator counts anything allocated on the IO thread. Zero over thousands of
cycles in an optimised build. (Measure release builds — a debug build's own
bounds and exclusivity checking allocates, and says nothing about shipping code.)

## Layout

```
Sources/
  YunAudioRT/       C shim for os_workgroup and the allocation tripwire —
                    those APIs are marked unavailable from Swift
  YunAudioHAL/      device enumeration, aggregate devices, process taps,
                    stream formats, clock analysis
  YunAudioEngine/   the IOProc, routing matrix, clock anchor publisher,
                    voice isolation, self test
  YunDesign/        the YunUI design system translated to SwiftUI
  YunAudioApp/      the menu bar app
  yunaudio-cli/     verification harness
Driver/             YunAudioDriver.driver — the AudioServerPlugIn
App/                bundle assembly for YunAudio.app
```

## Building

```bash
# The virtual device. Installing restarts coreaudiod, so all audio
# stops for a moment, and it needs an administrator password.
./Driver/build-driver.sh --install

# The app.
./App/build-app.sh --run
```

To remove the driver:

```bash
sudo rm -rf /Library/Audio/Plug-Ins/HAL/YunAudioDriver.driver
sudo killall coreaudiod
```

## Verifying

```bash
swift run -c release yunaudio-cli                     # probe every device
swift run -c release yunaudio-cli selftest            # prove bit-exactness
swift run -c release yunaudio-cli route "Mic" "YunAudio" 5
swift run -c release yunaudio-cli dsp                 # measure voice isolation
swift run -c release yunaudio-cli apps                # list tappable processes
swift run -c release yunaudio-cli tap Discord         # route an app's audio
swift run -c release yunaudio-cli tone 12 &           # a tappable noise source
swift run -c release yunaudio-cli far-end <pid> 6     # prove the AEC reference
swift run -c release yunaudio-cli aec-route           # route through the canceller
swift run -c release yunaudio-cli volume 0.5         # move the device's own level
swift run -c release yunaudio-cli soak 30            # hold a route for half an hour
```

`soak` is the only check that runs long enough to see what a call actually does
to this. Everything else here measures a few seconds; a leak of a few kilobytes
a minute, a cycle rate that wanders, or a clock lock that gives up an hour in
are all invisible at that scale and all ruin the thing this is for. Measured
over six minutes against the real driver:

```
cycle rate                    375.0/s, worst deviation 0.1
memory growth                 +4.0 kB/min
allocations on the IO thread  0
processor                     0.40% of one core
path at the end               bit-exact
clock                         locked, 0.999983 – 0.999985 throughout
```

375.0 is 48000/128 exactly. The 4 kB a minute is allocator noise rather than
growth — the footprint ends lower than its own midpoint — and the whole process
sits at 4.7 MB. It fails the run if memory climbs past a megabyte an hour, if
the cycle rate wanders more than 5%, if the processor cost grows by an order of
magnitude, or if the realtime contract breaks once.

`aec-route` is the integration check. With the canceller in the path the
microphone belongs to `AUVoiceProcessingIO` rather than to the router's
aggregate, and the cancelled signal reaches the routes across a lock-free ring,
so the thing worth measuring is the seam: the ring's fill should stay flat. A
fill that climbs means the router is the slower of the two and latency is
growing; one that falls to zero means it is starving and the audio has gaps.
Measured over eight seconds: 388,096 frames at 48 kHz, none dropped, −128 frames
of drift, and zero allocations on the IO thread.

That checks the plumbing, not the depth. `aec-measure` is what measures how much
is actually removed, by running the same acoustic path twice with the canceller
active and bypassed.

`far-end` checks the thing inspection cannot: that real frames cross the ring
between the tap's IO thread and the canceller's. Against `tone`, whose amplitude
is 0.2, it should report a peak of −14.0 dBFS and an RMS of −17.0 — a sine's
RMS sits 3.01 dB below its peak, so those two numbers together say the downmix
is level-correct and the ring is not touching the samples.

`afplay` is not a usable fixture: it never appears in the HAL process list,
because it hands its audio to a system process instead of opening a client of
its own. There is nothing to tap.

Run the audio tests against a release build. Debug builds report hundreds of
allocations per IO cycle that come from Swift's own checking machinery.

The interface is verified four ways, because each is blind to what the others
catch:

```bash
./App/build-app.sh
YUNAUDIO_FLOWCHECK=1  ./build/YunAudio.app/Contents/MacOS/YunAudioApp   # behaviour
YUNAUDIO_RENDER=out   ./build/YunAudio.app/Contents/MacOS/YunAudioApp   # colour
YUNAUDIO_SCREENSHOT=out ./build/YunAudio.app/Contents/MacOS/YunAudioApp # the real window
./App/check-strings.sh                                                 # localisation
./App/build-app.sh --verify                                            # shippability
```

The flow check drives the model through every path a person can take and
asserts what came back. The renderer rasterises the view tree offscreen in both
appearances, which is the only way to catch a colour that works in one theme and
vanishes in the other. The screenshot photographs the actual window at its
minimum size, including the title bar and the traffic lights — everything the
window itself contributes, which an offscreen render structurally cannot show.
`--verify` copies the built app somewhere else, moves the build tree out of
reach and runs it. SwiftPM's `Bundle.module` falls back to the build directory,
so an app that never copied its resource bundle in works perfectly on the
machine that built it and dies on launch — `could not load resource bundle` —
on every other one. Nothing but taking the build tree away can tell the two
apart.

The string check fails on any user-facing literal that never went through
`loc()` — a wrapped literal looks exactly like an unwrapped one, so nothing but
a scanner finds them, and four survived every other check including the whole
preferences sidebar sitting in English beside Chinese content.

## Razer hardware control

The Seiren V3 Pro's light ring is implemented. Getting there took a capture of
Synapse driving the device on Windows — polling the same feature report every
three milliseconds while the lighting was changed — and the result is in
`seiren-v3-pro-reverse/`.

What that established, in order of how much time it saves anyone else:

- **The openrazer protocol does not apply.** That format is 90 bytes on report
  id 0; this device declares no 90-byte report anywhere, so the frame is echoed
  back untouched. The real channel is a **64-byte feature report on id `0x07`**
  under usage page `0xFF53`.
- **The checksum covers the transaction id.** openrazer starts its XOR one byte
  later. A port that keeps that line produces frames the device rejects, and
  nothing says why.
- **The device has no effects.** Switching Synapse to Spectrum produced 961
  distinct RGB values streamed one frame at a time along a continuous hue
  circle. The animation runs on the host. So there is no effect protocol to
  reverse: `0x0F 0x03` writes twelve LEDs, `0x0F 0x04` sets brightness with zero
  meaning off, and every effect is ours to write.

The encoder is checked against two frames taken off the device, byte for byte,
including both checksums — which is how the checksum rule was confirmed before
anything was written to the microphone.

```bash
swift run -c release yunaudio-cli light on            # brightness
swift run -c release yunaudio-cli light solid 255 0 0
swift run -c release yunaudio-cli light led 0 255 255 255   # one LED, to map the ring
swift run -c release yunaudio-cli light spectrum 6
swift run -c release yunaudio-cli light off
```

Every one of those writes to the device, so each has to be asked for by name.
Nothing sweeps or probes on its own.

The same capture settled the microphone's internal topology, which is where
the three input channels come from — `Device_Mic`, `Device_MicDry`,
`Device_MicPostExp` on pin 1 — and the volume ranges behind them: the capsule
takes 0 to +36 dB of gain, the headphone output −64 to 0 dB, both in the UAC2
1/256 dB units CoreAudio already exposes.

Still open: the physical order of the twelve LEDs, which needs `light led`
walked from 0 to 11 with the ring in view. And the same capture established
that Synapse's EQ, noise reduction, voice gate and vocal clarity are **host-side
THX processing rather than device commands** — there is nothing to send for
those, which is why this project implements its own.

## Known limits

- The driver is ad-hoc signed. Distribution needs a Developer ID identity and
  notarisation.
- Voice isolation makes `AudioUnitRender` allocate on the IO thread — roughly 0.3
  allocations per cycle, from inside Apple's model rather than from this code.
  The bypass path stays at exactly zero. It has not caused a dropout in testing,
  but the realtime contract is broken while it is on.
- A driver fault takes `coreaudiod` down with all system audio attached. Keep the
  uninstall command above to hand.
- The virtual device's input level control is implemented but has only been
  verified to compile and to be published correctly by inspection; moving it
  through System Settings has not been tried on-device, because installing a
  driver restarts `coreaudiod`.
- Echo cancellation costs the clock lock and bit-exactness, and adds a buffer of
  latency in each direction. That is not a defect to be fixed later: the
  canceller has to own the microphone and the speaker together, so the microphone
  leaves the router's aggregate and the clock master becomes the destination.
  Worth it on laptop speakers, worth nothing on headphones, so it is off by
  default and the interface says what it costs before it is switched on.

## Licence

MIT. Note that BlackHole, which this replaces, is GPL-3.0 — the driver here was
written from scratch against `<CoreAudio/AudioServerPlugIn.h>` and shares no code
with it.

## Contributing

```bash
swift build && swift test
"$(xcrun --find swift-format)" lint --recursive Sources Tests
"$(xcrun --find swift-format)" format --in-place --recursive Sources Tests
```

`swift-format` lives in the Xcode toolchain rather than on `PATH`, which is why
the invocation goes through `xcrun`. CI runs the same three commands plus a
build of the driver — a broken `AudioServerPlugIn` takes `coreaudiod` down with
all system audio, so it is worth compiling on every change even though it
cannot be loaded on a runner.
