# Working on YunAudio

This is the working agreement for anyone — person or agent — making changes
here. `README.md` says what the project is and what it can do; this file says
how to work on it without breaking the things that are hard to notice breaking.

Read this first. Most of it exists because something already went wrong.

`TODO.md` is the other half: what is worth working on next, what has already
been settled and should not be retried, and where each of those conclusions came
from. Read it before deciding what to do; read this before doing it.

## The one thing to understand before anything else

**Audio bugs do not look like bugs.** A router that silently resamples still
plays audio. A meter reading off corrupted memory still moves. An effect that
never got built still leaves the app looking exactly right. Nearly every defect
found in this project so far was already shipping, already "working", and only
turned up when something *measured* it.

So the rule is: a change is not done when it compiles and the interface looks
right. It is done when something asserts a number. If you cannot think of a
number, you do not yet understand what you changed.

Real examples, all of them from this repository:

- A real FFT was fed to a complex FFT. It overflowed the heap twice per frame
  for weeks. Every test passed, because they all checked *which bin* the peak
  landed in and none checked *what the number was*. The fix that found it was
  one assertion: a 0.5-amplitude sine must read −6.02 dBFS.
- `if effects.count > 1` meant that enabling exactly one effect built no chain
  at all. The gate on its own did nothing. The compressor on its own did
  nothing. Nothing in the interface said so. It was found while building a gain
  reduction meter that read zero.
- Two tests passed while device profiles were not loading from disk at all,
  because a compiled-in fallback satisfied them both.
- The flow check reported "the en table loaded" as a failure, which looked like
  a broken build script. It was reading a fixed path, and a toolchain change had
  moved resource bundles from flat to `Contents/Resources`. Fixing the check
  revealed the same assumption in `Localization.swift` — the entire Chinese
  interface had silently reverted to English in a build that was otherwise
  correct.
- The build script copied one resource bundle by name, so a second bundle was
  silently dropped and the shipped app knew nothing about any microphone.

If a test can pass for the wrong reason, it will.

## Build and verify

The toolchain is selected for you: `App/toolchain.sh` finds an Xcode carrying a
macOS 27 SDK and exports `DEVELOPER_DIR`. Live transcription uses
`AnalyzerInputConverter`, which is macOS 27 API, and the failure on an older SDK
is `cannot find type 'AnalyzerInputConverter' in scope` — which reads like a
typo rather than like "your SDK is a year old". `App/build-app.sh` and
`package.sh` source it. If you invoke `swift build` or `swift test` by hand and
get that error, do this first:

```bash
source ./App/toolchain.sh
```

Then:

```bash
swift build && swift test           # 246 tests
"$(xcrun --find swift-format)" lint --recursive Sources Tests
"$(xcrun --find swift-format)" format --in-place --recursive Sources Tests
```

`swift-format` is in the Xcode toolchain rather than on `PATH`; that is why the
invocation goes through `xcrun`. Line length 96, four spaces, and
`ValidateDocumentationComments` is on — a doc comment whose parameter list has
drifted from the signature is a lint failure, not a nit.

**Measure release builds.** A debug build allocates on the IO thread from
Swift's own bounds and exclusivity checking, so a debug measurement of the
realtime contract says nothing about shipping code.

### The interface is verified four ways

Each is blind to what the others catch. Do not substitute one for another.

```bash
./App/build-app.sh
YUNAUDIO_FLOWCHECK=1    ./build/YunAudio.app/Contents/MacOS/YunAudioApp  # behaviour
YUNAUDIO_RENDER=out     ./build/YunAudio.app/Contents/MacOS/YunAudioApp  # colour
YUNAUDIO_SCREENSHOT=out ./build/YunAudio.app/Contents/MacOS/YunAudioApp  # real window
./App/check-strings.sh                                                   # localisation
./App/build-app.sh --verify                                              # shippability
```

- **Flow check** (`Sources/YunAudioApp/UIFlowCheck.swift`) drives the model
  through every path a person can take and asserts what came back. Add to it
  whenever you add a control. It is the only check that would have caught the
  `effects.count > 1` bug.
- **Render** rasterises the view tree offscreen in both appearances. It is the
  only way to catch a colour that works in one theme and vanishes in the other.
  If you change the layout, check the render size in `PanelRenderer.swift` still
  covers the content — it was 860pt tall against taller content for a while and
  quietly cropped the header out of every design check since.
- **Screenshot** photographs the actual window at its minimum size, including
  the title bar. An offscreen render structurally cannot show that.
- **`--verify`** copies the app elsewhere, moves the build tree out of reach and
  runs it. `Bundle.module` falls back to the build directory, so an app that
  never copied its resource bundle in works perfectly on the machine that built
  it and dies on launch everywhere else.
- **`check-strings.sh`** fails on any user-facing literal that never went
  through `loc()`. A wrapped literal looks exactly like an unwrapped one; four
  survived every other check, including the entire preferences sidebar sitting
  in English beside Chinese content.

### The engine is verified from the CLI

```bash
swift run -c release yunaudio-cli selftest    # bit-exactness, end to end
swift run -c release yunaudio-cli soak 30     # half an hour of real routing
swift run -c release yunaudio-cli dsp         # voice isolation cost
```

`soak` is the only check that runs long enough to see what a call does to this.
A leak of a few kilobytes a minute, a cycle rate that wanders, or a clock lock
that gives up an hour in are all invisible in a few seconds and all ruin the
thing this is for.

## The flow check takes over the audio hardware

Worth knowing before running it on a machine somebody is using, and worth
knowing twice before running several at once.

It starts and stops real routes about fifty times, creates and destroys
aggregate devices, changes device sample rates and puts them back, takes the
microphone and the output, and — in the setups section — sets the *system's*
own default input and output. All of that is what it is testing. What it looks
like from outside is the machine's audio glitching every few seconds for two
minutes.

It takes a file lock so two copies cannot run at once, which is not politeness:
two of them do not produce two results, they produce two wrong ones. And it
puts the system defaults back at the end and asserts that it did, because
leaving somebody's default microphone somewhere they did not put it is the kind
of thing they find out about during a call.

## Things that need a human

Do not run these yourself. Print the command and let the user run it.

- **Installing the driver.** `./Driver/build-driver.sh --install` needs sudo and
  restarts `coreaudiod`, which drops audio for every running application. It is
  someone's machine and possibly someone's call.
- **Writing to the microphone's light ring.** Every `yunaudio-cli light`
  subcommand writes over HID to real hardware. Each must be asked for by name;
  nothing probes, sweeps or enumerates on its own. This is deliberate.

Building the driver never touches the system — only installing does.

## Invariants

Break one of these and the failure will not be local to your change.

**The realtime path allocates nothing.** No Swift allocation, no locks, no
Objective-C, no logging on the IO thread. There is an allocator hook that counts
it (`YunAudioRT`), and it reports zero in a release build over thousands of
cycles. Everything crossing in or out goes through the lock-free SPSC rings
(`yun_rt_ring_*`) or the RCU cell (`yun_rt_cell_*`).

**Graph changes are published, not mutated.** Build a new graph, copy across
what carries over, publish it, retire the old one. Anything the IO thread holds
a pointer to must outlive the cycle that is using it. See how the analysis ring
is *handed over* rather than replaced in `RoutingEngine.swift` — a ring whose
consumer keeps its position across a rebuild must be the same ring.

**Stems and analysis are pre-fader.** A stem is what that source produced. If it
went through the fader it is a record of this session's mix decisions rather
than of the performance.

**The limiter is last, always.** Third-party Audio Units go after everything
this application shapes and before the limiter, because the limiter's whole job
is that nothing downstream sees a sample it has to clip. A plugin after it can
put the signal back over full scale, whatever the user drags around.

**Monitoring is exempt from the master fader, and not from the input trim.** The
master is the level going to the far end; muting that must not stop you hearing
your own voice. Muting the microphone must. Both are asserted against the
realtime callback directly.

**Say when the path is no longer clean.** Voice isolation, echo cancellation and
plugins all process the signal, and processing it is the opposite of leaving it
alone. The path quality reported has to stop claiming bit-exactness the moment
that happens.

**Device changes are asynchronous.** Setting a sample rate is a request. Wait
for the device to arrive at it — `setNominalSampleRate(_:timeout:)` does — or
the app can quit leaving somebody's interface at 8 kHz.

**Availability is a feature-level answer, not a build-level one.** The
application supports macOS 26. Transcription needs 27. Older systems must show
the feature as unavailable *with a reason somebody can act on*, never a disabled
control with no explanation. A 27-only type held in a stored property forces the
whole enclosing type to 27 and then so does everything holding one of those —
see the `AnyObject` box in `Transcriber.swift` and its comment.

## How to write things here

**Comments say why, never what.** The code already says what. A comment earns
its place by recording a decision, a measurement, or a trap — something the next
reader would otherwise have to rediscover. `// increment the counter` is noise;
`// Metered before gain: a meter should show what arrived, not what the fader
did to it` is the reason the line is where it is.

**Prose is British English**, in comments, documentation and user-facing
strings: *behaviour, colour, optimised, normalise, analyser*. Type and API names
follow whatever Apple calls the thing.

**Match the surrounding density.** This codebase comments heavily at decision
points and not at all elsewhere. Write like the file you are in.

**No user-facing string outside `loc()`.** The scanner will find it, but more to
the point half the interface is Chinese and a stray English literal is a visible
defect.

**Report to the user in Chinese** (中文). Code, comments and commit messages stay
in English.

## Where things live

```
Sources/
  YunAudioRT/       C shim: os_workgroup, lock-free rings, RCU cell, the
                    allocation tripwire — those APIs are unavailable in Swift
  YunAudioHAL/      device enumeration, aggregate devices, process taps,
                    stream formats, clock analysis, JSON device profiles
  YunAudioEngine/   the IOProc and routing matrix (RTGraph, RoutingEngine),
                    the effect chain, and the analysers: loudness, spectrum,
                    pitch, sound classification, formants, transcription
  YunAudioRazer/    HID control of the Seiren V3 Pro, reverse-engineered
  YunDesign/        the YunUI design system in SwiftUI — tokens, theme,
                    controls, localisation
  YunAudioApp/      the menu bar app; RouterModel is the single source of
                    truth and MainWindow is the tabbed inspector
  yunaudio-cli/     the verification harness
Driver/             YunAudioDriver.driver — the AudioServerPlugIn
App/                bundle assembly, toolchain selection, string check
DEVICES.md          what the hardware actually is, per device, and how each
                    fact was checked
```

`RouterModel.swift` is large and is the centre of everything the interface does.
Read the section it belongs to before adding to it; it is organised by
`// MARK:` and the sections are meaningful.

## Dead ends — do not retry these without new evidence

Both are written up at length in `README.md`. In brief:

- **`AUAudioMix`** (macOS 26's graded speech/ambience separator) cannot run
  live. It refuses mono and stereo input, wants five channels out, and needs
  `kAUAudioMixProperty_SpatialAudioMixMetadata` — capture-time metadata a camera
  writes into a Cinematic asset and a microphone cannot provide. All three
  constraints are asserted in the tests, so a future macOS relaxing any of them
  will be noticed rather than never looked at again.
- **MLX** was tried for the pitch tracker and removed. SwiftPM on the command
  line cannot build its Metal shaders, and MLX does not fall back to the CPU —
  it fails to load its default metallib and takes the process down on a
  three-element multiply. Separately, a 2048-point transform is a size where
  launch and synchronisation cost more than the arithmetic. MLX earns its place
  when there is a trained model to run.

Real-time neural voice conversion (fish-speech, RVC) is in the same category for
a different reason: it needs well over a hundred milliseconds and the deadline
here is 2.7 ms. The project says so rather than pretending otherwise.

## Committing

Small commits, one idea each. The subject line is a sentence about what changed
for the user or the code, not a category prefix — look at `git log` and match
it. Do not commit unless asked; do not push to `main`.
