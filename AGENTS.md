# Working on YunAudio

This is the working agreement for anyone — person or agent — making changes
here. `README.md` says what the project is and what it can do; this file says
how to work on it without breaking the things that are hard to notice breaking.

Read this first. Most of it exists because something already went wrong.

The issue tracker is the other half: what is worth working on next, and what
has already been settled and should not be retried. Read it before deciding what
to do; read this before doing it. `docs/limits.md` carries the conclusions that
are permanent rather than merely current — the approaches that were measured and
rejected, which is the half worth knowing before proposing one of them again.

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
swift build && swift test           # the whole suite
"$(xcrun --find swift-format)" lint --strict --recursive Sources Tests
"$(xcrun --find swift-format)" format --in-place --recursive Sources Tests
```

`swift test` is safe on an everyday machine: eight live-HAL cases remain in
the inventory but are disabled by default. Only an explicitly authorised
isolated run may set `YUNAUDIO_LIVE_HAL_TESTS=1`; `App/verify.sh --full` is the
ordinary way to request that evidence.

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
  quietly cropped the header out of every design check since. It also writes
  `menu-bar-mark-*.png` and `app-icon-*.png`: neither the status item nor the
  application icon appears in any window capture, so without those the only way
  to look at them was to install the app, which meant nobody did.
- **Screenshot** photographs the actual window at its minimum size, including
  the title bar. An offscreen render structurally cannot show that.
  Writing every PNG is not completion: after the capture writes its completion
  marker, the application has five seconds to terminate normally. A process
  stuck releasing CoreAudio used to be killed and accepted because the images
  already existed — exactly the shutdown failure that can leave the system
  Sound menu spinning.
  Note what neither of them covers: `MainWindow.column` takes an `isRendering`
  branch that **skips the scroll view entirely**, so nothing the scroll view
  contributes — the fade at the bottom of a column, where the clip lands — is
  ever built offscreen, and the photographs are looked at rather than measured.
  A mask that was six per cent of the height lived there: 26 points deep at the
  window's minimum and 49 at full screen, rubbing out a whole row at the size
  people actually work at. If you add something to that branch's shadow, assert
  it directly — `ScrollFadeTests` renders the modifier itself at two heights.
- **`--verify`** copies the app elsewhere, moves the build tree out of reach and
  runs a model-free resource probe. `Bundle.module` falls back to the build
  directory, so an app that never copied its resource bundle in works perfectly
  on the machine that built it and dies on launch everywhere else. The probe
  constructs no router and touches no audio hardware; a trap restores the build
  tree after success, failure or interruption.
- **`check-strings.sh`** fails on any user-facing literal that never went
  through `loc()`. A wrapped literal looks exactly like an unwrapped one; four
  survived every other check, including the entire preferences sidebar sitting
  in English beside Chinese content.

### The icon is drawn, not stored

```bash
./App/make-icon.sh --list             # what the styles are called
./App/make-icon.sh --style paper      # build build/YunAudio.icns as that one
```

There is one piece of artwork — `Sources/YunAudioApp/Resources/Icon.png` — and
everything else is drawn from it by `YunIconBadge` and `YunAppIcon`. The icon
build asks the application to draw each `.icns` slot at its own resolution,
because the alternative is what this used to do: scale one 180-point bitmap into
all ten, so the 1024 slot was a five-fold upscale.

Settings → Appearance picks a style at runtime, and **it does not reach Finder,
by design**. iOS has `setAlternateIconName`; macOS has no equivalent, and the
only way to change a bundle's icon in place is to write a custom icon into the
bundle — which breaks the code signature. This app is signed with the microphone
entitlement, so a broken seal costs the microphone permission, not just a stale
picture. The preference therefore changes every icon the *application* draws
(About, `NSApp.applicationIconImage`, and so its alerts and notifications) and
`make-icon.sh --style` changes the one Finder shows. Say so in the interface —
it already does.

Two things to know before touching any of it:

- **Place the ink, not the file.** The mark is a portrait shape stored in a
  square PNG and it is not centred in it. Drawing the file into a square box
  put the mark 1.4 points left of centre with its tip against the top edge, in
  the menu bar and in both window headers. `YunAppIcon.draw(inkFitting:)` and
  `YunAppIcon.trimmed` exist so that mistake has one place to not be made.
  The bounds are measured from the artwork at launch rather than written down,
  so replacing the PNG is all that changing the mark takes.
- **The status item is a template.** macOS renders it in the menu bar's own
  foreground colour, which is what makes it follow light and dark mode and
  invert under an open menu — and only the alpha channel survives that. Colour
  cannot carry state there. It used to try: red for muted, green for level, none
  of which ever reached the screen as drawn. Every state is a shape now, and
  `StatusMarkTests` asserts there is not a coloured pixel in any of them.

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

### Do not join the queue

The lock makes parallel work serial rather than impossible, and for one
microphone that is the right trade — but a queue is not free. Measured on this
machine with several sessions each running an A/B comparison: **five processes
waiting on one lock**, each holding the hardware for two to four minutes. That
is twenty minutes during which the machine's audio is seized and released
continuously, every other application stutters, and the last process in the
queue has been sitting with a window open for a quarter of an hour without
having checked anything.

So the wait is now capped at five minutes and then the run gives up and says
so, loudly, with `exit 2`. Raise it with `YUNAUDIO_FLOWCHECK_WAIT=<seconds>` if
you genuinely want to wait. A run that did not happen is a fact somebody can
act on; a run that silently started fifteen minutes late is a mystery about why
the machine was unusable.

## The acceptance gate

```bash
./App/verify.sh          # everything that does not need the audio hardware
./App/verify.sh --full   # and the flow check, which takes it for four minutes
```

**Run it before you say something is done.** Not the steps individually — the
gate. It exists because the checks used to be a list in this file, and a list in
a file is a list somebody skips. Two things went wrong in one afternoon and both
were the procedure rather than the code:

- **A whole feature shipped with no interface at all.** The scripting engine had
  unit tests, a flow-check section and an offscreen render, all green, and there
  was no tab for it in the window. None of those three can see that: the render
  draws whichever tab is *selected*, so a tab missing from the row is invisible
  to it by construction. The photograph of the real window is the only thing
  that shows it, and the photograph was the step that got skipped.

- **A build failure was hidden by a grep.** `swift build 2>&1 | grep error:`
  with a pattern that did not match the driver's own failure line printed
  nothing, was read as success, and a stale binary was photographed and
  believed for three rounds. **Exit codes decide. Output is for people.** The
  gate never greps for success.

What it does, and why each is not redundant with the others:

| step | what only it can catch |
|---|---|
| `swift build` | it compiles — and nothing after this means anything without it, so a failure stops the run |
| strict `swift-format` | source and documentation comments match the repository's checked-in style contract |
| `swift test` | the arithmetic, and every rule that can be a pure function |
| `check-strings.sh` | a literal that never reaches a translator, a duplicate key, a `%@` lost in translation |
| `build-app.sh --verify` | the bundle is assembled and every resource loads with the build tree hidden |
| offscreen render | colour and spacing, in both appearances, on every panel |
| **photograph the real window** | the title bar, clipping at the minimum size, whether a control is *missing*, whether a row of six fits |
| flow check (`--full`) | real devices, real routes, real audio |

The summary at the end says what it did **not** check, every time. A green run
that quietly omitted the only check touching real hardware is worse than a red
one, so a run without `--full` says so in as many words.

And then **look at `build/screenshots`.** The gate can tell you a photograph was
taken; it cannot tell you the first two tabs came out as "…". That one was found
by opening the picture.

### A targeted run is not evidence about anything else

`check()` returns without recording when the section is outside the filter.
That is deliberate — a skimmed section has not been waited for, so what it
observes is not evidence either way — but it has a consequence worth stating
plainly: **a filtered run that ends "every flow behaved" means the named
section behaved.** It says nothing about the other seventy-seven, whose
assertions did not run at all.

Measured: a full run reports `audio kept flowing` failing in `input trim and
master`; the same binary filtered to another section reports every flow
behaved.

### First, check the machine can start audio at all

Before believing any failure that says a signal did not arrive, establish that
one could have. CoreAudio can reach a state where **nothing on the machine can
start IO** — not this application, not `afplay`, which fails with
`AudioQueueStart failed (-66681)`. Every reading is then zero, and every check
that measures a signal fails with a message about its own subject, which is how
an afternoon goes into a feature that was never broken.

```bash
.build/debug/yunaudio-cli soak      # cycle rate 0.0/s means nothing is running
```

Fixing it needs a human, because it takes the audio away from every application
on the machine for a few seconds:

```bash
sudo killall coreaudiod
```

Print that; do not run it.

### What to run instead, most of the time

The compiler is not the slow part, and it is worth knowing the numbers before
reaching for the expensive check:

| | |
|---|---|
| `swift build`, nothing changed | ~2 s |
| `swift build` after one leaf file | ~7 s |
| `swift test`, all of it | ~6 s |
| `./App/build-app.sh` after a change | ~7 s |
| the whole flow check | **~225 s, and it takes the hardware** |

A change to pure logic is answered by `swift test` in six seconds. Reach for the
flow check when the change touches the audio path, the devices or the interface
— and when you do, name the section:

```bash
YUNAUDIO_FLOWCHECK=1 YUNAUDIO_FLOWCHECK_ONLY="processing chain swapped live" \
  ./build/YunAudio.app/Contents/MacOS/YunAudioApp
```

Sections before the named one still run, because the later ones depend on the
state the earlier ones leave behind. Sections *after* it no longer do: the run
ends as soon as the last section anybody asked for has finished. Before that,
naming one section saved nothing at all — a targeted run cost the full 225 s,
of which about 140 was sections nobody was looking at, each one starting and
stopping real routes.

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
  YunAudioControl/  RemoteCommand and the command-line parser — the one
                    vocabulary the URL scheme, MIDI, scripts and the terminal
                    all speak — and the Unix socket both executables reach the
                    application through. Its own module because they are
                    separate processes and SwiftPM will not share a file
                    between two targets
  YunAudioApp/      the menu bar app; RouterModel is the single source of
                    truth and MainWindow is the tabbed inspector
  yunaudio-cli/     the verification harness, and the half that drives the
                    running application rather than the hardware
  yunaudio-mcp/     the MCP server: JSON-RPC 2.0 on stdio, stateless, forwards
                    everything over the control socket
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
