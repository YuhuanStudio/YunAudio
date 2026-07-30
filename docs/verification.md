# Verifying

The gate and every probe underneath it, at length. The README has the ladder;
this is what each rung actually does and what it cannot tell you.

← [README](../README.md) · [MEASUREMENT.md](../MEASUREMENT.md)

English · [繁體中文](zh-Hant/verification.md) · [简体中文](zh-Hans/verification.md)

## Verifying

One command runs everything, and says what it did **not** run:

```bash
./App/verify.sh                 # everything that does not need the audio hardware
./App/verify.sh --full          # and the flow check, which takes it for about two minutes
./App/verify.sh --fresh         # and a clone into a directory of its own, built from nothing
```

It compiles, runs the tests, checks every user-facing string goes through a
translator, assembles the bundle, renders every panel offscreen, photographs the
real window in every tab, and — with `--full` — proves the path is bit-exact and
the realtime thread allocates nothing, in a release build. A run that skipped
something says so in as many words, because a green summary that quietly omitted
the only check touching real hardware is worse than a red one.

Then look at `build/screenshots`. The gate can tell you a photograph was taken;
it cannot tell you the layout in it is wrong.

The individual tools, when you want one of them on its own:

```bash
swift run -c release yunaudio-cli                     # probe every device
swift run -c release yunaudio-cli selftest            # prove bit-exactness
swift run -c release yunaudio-cli route "Mic" "YunAudio" 5
swift run -c release yunaudio-cli dsp                 # measure voice isolation
swift run -c release yunaudio-cli apps                # list tappable processes
swift run -c release yunaudio-cli tap Discord         # route an app's audio
swift run -c release yunaudio-cli tap-restore Spotify # does a capture survive a relaunch
swift run -c release yunaudio-cli tone 12 &           # a tappable noise source
swift run -c release yunaudio-cli far-end <pid> 6     # prove the AEC reference
swift run -c release yunaudio-cli aec-route           # route through the canceller
swift run -c release yunaudio-cli volume 0.5         # move the device's own level
swift run -c release yunaudio-cli soak 30            # hold a route for half an hour
swift run -c release yunaudio-cli capture 10         # write the routed signal to a file
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

