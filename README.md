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

**It tells you the truth about the path.** Bit-exact, resampled, or processed;
measured round-trip latency; whether the clock lock is actually holding. When you
enable voice isolation it says so and stops claiming bit-exactness, because
processing the signal is the opposite of leaving it alone.

**Voice isolation from Apple's own model.** `AUSoundIsolation` is the model
behind FaceTime's Voice Isolation, on-device and free, and no other router in
this category exposes it as a general microphone processor. Measured here: 56 ms
of added latency, under a quarter of the IO deadline in CPU.

**Application audio with no extra driver.** Capture any app through
`AudioHardwareCreateProcessTap`, optionally silencing its normal output. Loopback
and its peers need their own plug-in for this; here it is a documented API.

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
```

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

The interface is verified three ways, because each is blind to what the others
catch:

```bash
./App/build-app.sh
YUNAUDIO_FLOWCHECK=1  ./build/YunAudio.app/Contents/MacOS/YunAudioApp   # behaviour
YUNAUDIO_RENDER=out   ./build/YunAudio.app/Contents/MacOS/YunAudioApp   # colour
YUNAUDIO_SCREENSHOT=out ./build/YunAudio.app/Contents/MacOS/YunAudioApp # the real window
```

The flow check drives the model through every path a person can take and
asserts what came back. The renderer rasterises the view tree offscreen in both
appearances, which is the only way to catch a colour that works in one theme and
vanishes in the other. The screenshot photographs the actual window at its
minimum size, including the title bar and the traffic lights — everything the
window itself contributes, which an offscreen render structurally cannot show.

## Razer hardware control

The transport for Razer's vendor HID interface is implemented and verified
against a Seiren V3 Pro. What it found is worth recording, because the obvious
starting point is wrong:

- The device's vendor usage pages are `0xFF90`, `0xFF82` and `0xFF53` — its
  *primary* page is Consumer Control, so matching on `kIOHIDPrimaryUsagePageKey`
  misses it entirely.
- **The openrazer 90-byte protocol does not apply.** Parsing the report
  descriptor shows no 90-byte report anywhere on the device. Sending one gets
  echoed back untouched, and no transaction id fixes that.
- The control channel is the device's only feature report: `0xFF53`, report id
  `0x07`, 63 bytes.

`yunaudio-cli razer` prints the descriptor and reads that report. Everything is
read-only: the command format still needs a USB capture of Synapse on Windows,
and guessing at command bytes on hardware that stores configuration is not a
reasonable substitute.

## Known limits

- The driver is ad-hoc signed. Distribution needs a Developer ID identity and
  notarisation.
- Voice isolation makes `AudioUnitRender` allocate on the IO thread — roughly 0.3
  allocations per cycle, from inside Apple's model rather than from this code.
  The bypass path stays at exactly zero. It has not caused a dropout in testing,
  but the realtime contract is broken while it is on.
- A driver fault takes `coreaudiod` down with all system audio attached. Keep the
  uninstall command above to hand.
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
