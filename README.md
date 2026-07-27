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

**Loudness to the broadcast standard.** A peak meter answers "will this clip".
It does not answer the question anybody streaming or recording actually has,
which is "am I as loud as everyone else" — Discord normalises to about −18 LUFS,
YouTube to −14, broadcast to −23. YunAudio measures loudness to ITU-R BS.1770-4,
the same standard those platforms use: K-weighting, 400 ms blocks at 75% overlap,
and the two-pass gate that stops pauses counting. It reads momentary, short-term
and integrated, and then says the useful part in a sentence — how far you are
from the platform you picked, and which way to move.

The arithmetic is checked against the standard rather than against itself: a
1 kHz sine reads its own RMS level in LUFS, doubling the amplitude adds exactly
6.02, the reading is the same at 48 and 96 kHz, and silence between passages does
not drag it down. Nothing else in this category on macOS measures loudness at all.

**A spectrum you can read frequencies off.** Twenty-four log-spaced bands with a
frequency axis, so the display says *what* rather than merely how much: hum at
60 Hz, a desk knock under 100, sibilance piled up at 7 kHz. Calibrated, not
merely ordered — a tone of known amplitude comes back at its own level in
decibels, which is the assertion that caught a real transform bug here.

**It levels itself, and it knows what it is listening to.** Automatic gain
control has the reputation it has for one reason: an envelope follower cannot
tell a voice from a fan, so it spends every pause winding the gain up into the
room noise and then ducking when you speak again. What is wrong with it is the
measurement, not the loop.

YunAudio measures loudness to the broadcast standard and runs Apple's on-device
sound classifier — the three-hundred class model that ships with macOS — over
the signal at the same time. The leveller moves only while the model reports
speech, at 1.5 dB per second, inside a dead zone, bounded to 15 dB. Pauses,
keyboards and air conditioning are not evidence about how loud anybody is, so it
holds still through them. The interface shows what the model hears, so it is a
diagnosis rather than a black box: *typing* under your voice is a reason to turn
the gate on.

The control loop is a value type with no dependencies and thirteen tests, because
a leveller that has only ever been tried by talking into a microphone has not
been tested — it has to converge, not overshoot, not hunt, and refuse to act on
silence. The classifier is checked against real synthesised speech rather than
only against its own label table.

**Direct monitoring that is actually direct.** Hearing yourself through a
conferencing app is thirty milliseconds behind, which is late enough to stumble
over. Monitoring here is a second destination on the same aggregate, so it is one
IO cycle plus the output device — measured at 11.2 ms into a display's audio, and
2.7 ms into anything with a sane driver. It is exempt from the master fader,
because the master is the level going to the far end and muting that must not
stop you hearing your own voice; the input trim and mute do reach it, because
muting the microphone should stop you hearing it. Both rules are asserted against
the realtime callback directly.

**A voice changer that changes the voice, not just the pitch.** Pitch shifting
moves the whole spectrum — the fundamental and the resonances of the throat and
mouth sitting on top of it — and the ear reads that as a smaller head rather
than a different person. That is why every pitch shifter makes a chipmunk. A
tall man and a small woman can sing the same note; what differs is where their
formants sit.

So the formants shift independently, which nothing on macOS provides and is
written out here: the spectral envelope is estimated from the low-quefrency part
of the log spectrum, stretched along the frequency axis, and divided back in,
leaving the harmonics — and therefore the pitch — exactly where they were. The
tests assert both halves of that, because a test that only checked the
resonances moved would pass for a plain pitch shifter. Alongside it, a character
stage built on ring modulation, decimation and soft clipping: robot, radio,
monster, bitcrush, alien.

**Third-party Audio Units.** This is what a plugin means in audio, and it is the
one place where loading somebody else's code is the right answer rather than an
elaborate way to avoid a configuration file: the format exists, the system vets
and sandboxes it, and thousands are already installed. They go in one place, and
it is not arbitrary — after everything this application shapes and before the
limiter, because the limiter's whole job is that nothing downstream sees a
sample it has to clip. Anything running after it can put the signal back over
full scale, so a plugin cannot be allowed there whatever the user drags around.

A unit that has to run in its own process makes every render an XPC round trip,
which is fine in a mixing session and not fine inside a callback with a 2.7 ms
deadline. That is said before it goes in the path rather than discovered
afterwards.

**Devices are described by documents, not by code.** CoreAudio says a microphone
has three input channels and nothing about what is on them. Knowing that the
Seiren V3 Pro's three are the processed capsule, the dry capsule and the output
of the microphone's own expander took taking the thing apart — and that
knowledge used to be compiled in, so every new microphone was a code change and
a release for a table of strings. It is a JSON file now, and anything dropped in
`~/Library/Application Support/YunAudio/Devices` is loaded on top. Deliberately
data and not plugins: a profile describes hardware, it does not execute, and
loading code from a folder would mean signing, versioning, a stable ABI and a
way for a bad one to take the audio system down with it.

**Voice isolation from Apple's own model.** `AUSoundIsolation` is the model
behind FaceTime's Voice Isolation, on-device and free, and no other router in
this category exposes it as a general microphone processor. Measured here: 56 ms
of added latency, under a quarter of the IO deadline in CPU.

**Two gain stages, in the right order.** The microphone's own gain happens in
the hardware before its converter, so raising it costs no headroom; a digital
trim afterwards can only amplify what the converter already decided, noise
included. Both are here and the hardware one is first, which is the order that
matters and the one nothing else on macOS puts in front of you.

It appears only where the device publishes a settable gain, and that turned out
to be worth checking rather than assuming: the Seiren **V2 X** publishes one
through CoreAudio and the **V3 Pro does not**, even though its own firmware
carries 0 to +36 dB on feature unit 7. macOS's UAC2 driver does not expose it,
so on that device the trim is what there is.

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
swift run -c release yunaudio-cli light walk          # map the ring
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

The ring is driven from the application, not just the CLI. Because the device
renders nothing itself, the twelve LEDs are a display this project already has
something to put on: **the ring shows the input level and turns red the moment
you mute.** Index 0 is at six o'clock and they run clockwise, which is why the
level fills by height rather than by index — filling by index sweeps round like
a chase, filling by height rises up both sides at once the way a meter should.
That geometry could not be read off the device; it came from `light walk`
lighting them one at a time.

The same capture established
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
