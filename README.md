# YunAudio

A menu bar audio router for macOS, with a virtual device of its own.

It exists because Discord's WebRTC engine reaches down to the HAL and fights
high-end USB microphones for control of the device, producing a crackle once per
second. Routing the microphone into a virtual device that Discord opens instead
makes the problem go away. Along the way it turned out macOS has several
capabilities in this area that nothing else exposes, so the project grew.

Requires macOS 26 or later. Live transcription needs macOS 27; on 26 it is
shown as unavailable with the reason, and everything else works.

## What is different about it

**The signal path is provably bit-exact.** Not "we don't think anything
resamples it" — measured. `yunaudio-cli selftest` sends a 24-bit pseudorandom
sequence through the whole path, reads it back off the loopback, recovers the
delay from the data and compares every sample:

```
bit-exact: 261400/261400 samples identical, delay 872 frames
clock lock held at 0.999986 throughout
```

The method is written up in **[MEASUREMENT.md](MEASUREMENT.md)** — the
sequence, why it is 24 bits, how the delay is recovered from the data, and,
just as importantly, what the measurement does not prove.

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

**Karaoke that does not assume Chinese music has no words.** Music's own
lyrics and local `.lrc` files come first, then LRCLIB, QQ Music, NetEase Cloud
Music and lyrics.ovh are asked concurrently. A validated timeline wins and
cancels the slower requests; simplified and traditional metadata, live
editions and television-performance labels are matched without attaching an
original recording to an accompaniment by mistake. Spotify itself exposes no
lyrics property, but a real run with 黃霄雲's *年少心動雨季* found a 265-second
timeline with more than sixty lines through the Chinese sources.

Scoring says what its reference is. A matching MIDI file is an exact melody;
captured original vocals are an automatic audio-derived reference; an
accompaniment on its own can honestly provide only key, intonation and phrase
timing because it does not contain the vocal melody. Each microphone keeps its
own pitch history and score, so a duet is two measured performances rather than
two voices guessed out of one mix. Music and Spotify supply supported
now-playing metadata through their scripting dictionaries. Other captured
players use public ShazamKit recognition when the distributed App ID has the
ShazamKit service enabled; an ad-hoc build states that signing requirement
instead of retrying a catalogue request that cannot succeed.

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

**A voice change that is a voice, not two knobs.** Pitch and formants are
separate stages because they are separate physical facts, and nobody wants to be
told that — they want to sound like somebody else, and that is a specific pair
of settings. An adult male speaking voice sits around 110 to 130 Hz and an adult
female around 200 to 220, roughly a fifth; but a fifth of pitch shift alone is
unmistakably processed, because the resonances did not move with it. Female
formants run about 15 to 20 per cent higher, from a vocal tract about that much
shorter. Shift both and the ear stops hearing an effect.

The presets are measured rather than asserted: a synthetic male voice through
the higher-voice preset comes out with its pitch up by the stated 500 cents and
its spectral centroid up with it, in the same signal, through the real chain.

What this is not is neural voice conversion. Something like fish-speech or RVC
learns a target speaker and resynthesises, which is a different and better thing
— and needs a model, a GPU pipeline and well over a hundred milliseconds. None
of that fits inside a 2.7 ms IO deadline. Every real-time voice changer that
ships today does what this does; this one says so.

**Transcription that knows who said what, without guessing.** Every product
that transcribes a conversation hedges publicly about diarization, because
working out who is speaking from the sound is a guess and it is wrong often
enough to be the thing people complain about.

This application does not have that problem, and not because it solved it. The
microphone is one source and every captured application is its own process tap,
separated before anything reaches a model. One transcriber per source, and the
speaker label is the wiring rather than an inference. `SpeechTranscriber` is
macOS's own model, designed for sustained multi-hour transcription rather than
short queries, and it runs on the device: no per-minute billing, no upload, no
key.

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

It appears only where the device publishes a settable gain, and finding out
which devices those are took two goes. The first answer here — and in the
reverse-engineering write-up, which agreed — was that the Seiren **V2 X**
publishes one and the **V3 Pro does not**, so on the V3 Pro only the digital
trim was left. That was wrong. CoreAudio publishes a device's controls per
element, the master is element 0, and asking only for the master looks like it
works because most devices answer there. The V3 Pro answers on **elements 1, 2
and 3** — one per capsule tap — each carrying the full **0 to +36 dB** its
firmware documents. Nobody had asked the right element.

**Zero-latency monitoring, done by the microphone.** The same inventory turned
up something nothing on macOS offers to move: the Seiren publishes a
play-through level, which is the device feeding its own input back to its own
headphone jack in silicon. That is what "zero-latency" on a microphone's box
actually means — the signal never reaches the computer. This application's own
monitoring is 2.7 ms, which is good and is not zero. Razer's software reaches
it through a USB request on Windows; there is no Synapse here, and until now
there was no way to move it at all.

Offered rather than switched on, because what comes back is the *unprocessed*
capsule: none of the processing here can be in it, since none of it has
happened yet.

**It knows what your microphone's channels actually are.** CoreAudio reports
that a Seiren V3 Pro has three inputs and nothing about what is on them. They
are the processed capsule, the dry capsule, and the capsule past the
microphone's own expander — which sits ahead of the converter, so it removes
room noise before anything can clip. The picker names all three and says what
each is for. That mapping came out of the device's own module dumping its
internal topology, and nothing else on macOS will tell you.

**It carries on when a device is unplugged.** A USB microphone that falls out
mid-call used to stop the router and wait. It now moves to the most recently
used microphone that is actually present, says which device it is standing in
for, and takes the original back the moment it is plugged in again — unless you
picked something else in the meantime, which ends the claim, because switching
you back then would be overriding a decision rather than undoing an accident.

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
  YunAudioControl/  the command vocabulary and the control socket, shared by
                    the application, the command line and the MCP server
  YunAudioApp/      the menu bar app
  yunaudio-cli/     verification harness, and the command line that
                    drives the running app
  yunaudio-mcp/     the MCP server, so an agent can drive the application
Driver/             YunAudioDriver.driver — the AudioServerPlugIn
App/                bundle assembly for YunAudio.app
```

## Building

There are two ways in, and the difference between them is one dialog.

**A disk image.** `./package.sh` builds `build/YunAudio-<version>.dmg`, which
carries the application, the virtual device, and a script each for installing
and removing it. macOS will refuse to open the application the first time and
say the developer cannot be verified — that is what it says about anything that
has not been through Apple's paid notarisation service, which this project has
no account for. Privacy & Security in System Settings has an "Open Anyway"
beside it, and once is enough. The image says so in a `READ ME FIRST.txt` you
see before you see anything else, because a refusal with no explanation beside
it is where most people stop.

**Or build it yourself**, below. A binary you built carries no quarantine flag,
so none of the above applies, and it is one command.

Building needs an Xcode carrying the **macOS 27 SDK**, because live
transcription uses `AnalyzerInputConverter`. The scripts find one and select it
themselves; a hand-run `swift build` may need `source ./App/toolchain.sh` first,
otherwise the error is `cannot find type 'AnalyzerInputConverter' in scope`,
which reads like a typo rather than like an SDK a year old. The application
itself still runs on macOS 26.

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

## Remote control

Anything that can open a URL can drive this: Shortcuts, Stream Deck, Keyboard
Maestro, AppleScript, `open` from a terminal.

```bash
open "yunaudio://routing/start"     # also /stop and /toggle
open "yunaudio://mute/on"           # also /off, and bare for toggle
open "yunaudio://record/toggle"
open "yunaudio://transcript/start"
open "yunaudio://preset/Voice%20call"
```

A bare noun toggles, because that is what a physical button wants; anything
driven by a script should prefer the definite form, which is idempotent —
`mute/on` twice is muted, not unmuted. An unrecognised verb is refused rather
than guessed at, since the failure mode being avoided is a mistyped mute that
turns into a stop.

### From a terminal

The same verbs, with an answer coming back — which is the part a URL cannot do.
`yunaudio-cli` talks to the copy of the application that is already running
rather than opening any hardware itself.

```bash
yunaudio-cli status                  # what it is doing, one fact per line
yunaudio-cli start                   # also stop, toggle
yunaudio-cli mute on                 # also off, and bare for toggle
yunaudio-cli record off
yunaudio-cli transcribe on
yunaudio-cli preset Voice call       # no quotes needed; a name is joined
yunaudio-cli config Podcast
yunaudio-cli script "yun.mute(true); yun.log(yun.status().running)"
yunaudio-cli mute --url              # print the URL instead of sending it
```

`status` prints what a script sees through `yun.status()`, plus the scenes and
setups that exist. Naming one that does not gets the list of ones that do, which
is more use than "not found". A command that could not be carried out exits 1
and a line the tool could not parse exits 2, so a shell script can tell the
difference between "the application refused" and "you typed it wrong".

It reaches the application over the same Unix socket the MCP server uses, at
`~/Library/Application Support/YunAudio/control.sock`. That is why "YunAudio is
not running" comes back in milliseconds rather than after a timeout: nothing
listening is `connect` failing, which is an answer, not a silence to wait out.

`status` deliberately is not one of the verbs a URL or a MIDI note can send:
asking what is happening must not be able to change it. Everything else is one
vocabulary — `RemoteCommand` — with four front ends, so a verb added once is
available from a URL, a pad, a line of JavaScript and a shell.

`record` here means the application's recorder. The measuring verb that captures
a few seconds of the routed signal to a file is `capture`.

Not App Intents, and not for want of trying: the entries in a Shortcuts library
are discovered from metadata Xcode's own build phase extracts, and an
application assembled by a shell script around a SwiftPM binary produces none.
They would have compiled, run, and never appeared anywhere anybody could use
them.

## Driving it from an agent — MCP

`yunaudio-mcp` is a Model Context Protocol server: JSON-RPC 2.0 over stdio, no
dependencies, spawned by whatever client you point at it.

```bash
swift build -c release            # produces .build/release/yunaudio-mcp
claude mcp add yunaudio -- "$PWD/.build/release/yunaudio-mcp"
```

Or, for a client configured by file — Claude Desktop, Zed, anything else that
reads the same shape:

```json
{
  "mcpServers": {
    "yunaudio": { "command": "/absolute/path/to/yunaudio-mcp", "args": [] }
  }
}
```

Nine tools: `yunaudio_status`, `yunaudio_list_names`, `yunaudio_routing`,
`yunaudio_mute`, `yunaudio_record`, `yunaudio_transcribe`,
`yunaudio_apply_scene`, `yunaudio_apply_setup` and `yunaudio_run_script` — the
same vocabulary as the URL scheme, because it is the same `RemoteCommand`
underneath. Names are the user's own and some are translated, so
`yunaudio_list_names` is the one to call before applying a scene by name.

**YunAudio has to be running.** The server holds no state and knows nothing on
its own: it forwards to the application over a Unix domain socket at
`~/Library/Application Support/YunAudio/control.sock`, which the application
creates on launch, removes on quit, and leaves readable only by its owner. If
nothing is listening, every tool answers with that immediately rather than
waiting. `--socket <path>` and `$YUNAUDIO_CONTROL_SOCKET` move it.

A socket rather than the URL scheme, because a URL is one-way. `open
yunaudio://mute/on` returns as soon as Launch Services has taken the event: it
cannot say whether the microphone is now muted, whether the scene existed, or
whether anything was there to hear it. That is fine for a Stream Deck key, where
a person is looking at the result, and useless for an agent, where nobody is —
and reading the state back is half of what an agent is for.

## Talking to OBS

Settings → Streaming connects to `obs-websocket` v5, which has shipped inside
OBS since version 28. Two things go across it, and the second is the reason the
first exists.

**Muting the microphone here mutes OBS's copy of it**, if you ask it to. OBS's
own mute for the same source is a separate switch on a separate window, and the
failure that produces is the one nobody notices in time.

**The sync offset.** Everything this application produces reaches OBS later than
the picture does, by exactly as much as the effect chain adds — voice isolation
alone is 56 ms. OBS has a per-source field for that and no way of working out
what belongs in it. This does, to the frame, and until now only displayed it.
2688 frames at 48 kHz becomes −56 ms, rounded to whole milliseconds because
OBS's own dialog is a whole-millisecond spin box.

Two things worth saying plainly:

- **`obs-websocket` is switched off by default**, so the first thing most people
  meet is a refused connection. That is answered here with the menu path rather
  than with a status code: Tools → WebSocket Server Settings.
- **This has not been verified against OBS.** The authentication is checked
  against the vector in obs-websocket's protocol document, and the whole
  handshake is checked over a real socket against a stub server that answers the
  way that document describes — but OBS is not installed on the machine this was
  written on, and a stub cannot be evidence about a program it is imitating.
  `RESEARCH.md` says what running it against the real thing would take.

Not built, and it is a decision rather than a gap: no native OBS plugin
(the websocket does everything needed and a plugin binds this to OBS's build
and ABI), no browser-source overlay yet, and no six-track recording model —
`MAX_AUDIO_MIXES` is a compile-time constant in libobs, which makes six somebody
else's muxer limit rather than a shape worth copying.

### A capture that survives the application restarting

OBS's issue #9144 — "Application Capture loses audio when application reopens on
macOS" — has been open since June 2023, and OBS's answer to it is a button in the
source properties labelled "Restart capture".

macOS 26 added `CATapDescription.bundleIDs`, and this application sets it, so a
captured application that quits and comes back reattaches on its own. Measuring
that turned up something worth knowing: the neighbouring
`processRestoreEnabled` flag **defaults to true**, so it had always been on and
had always restored nothing, because there were no bundle identifiers to restore
by. Setting the flag alone would have been a change with no effect that read
exactly like a fix.

```bash
swift run -c release yunaudio-cli tap-restore Spotify           # what the HAL kept
swift run -c release yunaudio-cli tap-restore Spotify --watch   # quit it and watch
```

## Razer hardware control

The Seiren V3 Pro's light ring is implemented. Getting there took a capture of
Synapse driving the device on Windows — polling the same feature report every
three milliseconds while the lighting was changed — and everything that came
out of it, along with the manufacturer's own figures for the Barracuda and two
conclusions that measurement later overturned, is written up in
**[DEVICES.md](DEVICES.md)**.

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

## What was tried and does not work

**`AUAudioMix`.** macOS 26 ships a graded speech/ambience separator — the
tunable successor to `AUSoundIsolation`'s on-or-off, with a Studio style that is
Apple's answer to NVIDIA Broadcast and a continuous remix amount instead of a
switch. On paper it is the most differentiating thing available on this
platform. It cannot be used live, and the reason is measured rather than
assumed: it refuses mono and stereo input outright, wants five channels out
rather than four, and even with both formats accepted it will not initialise —
because it needs `kAUAudioMixProperty_SpatialAudioMixMetadata`, the capture-time
metadata a camera writes into a Cinematic asset and a microphone has no way to
provide. It is an asset-processing unit. Encoding a mono microphone to
ambisonics would have been arithmetic; the metadata is not. The tests assert all
three constraints, so if a future macOS relaxes any of them this project finds
out rather than never looking again.

**MLX.** Tried for the pitch tracker and removed. mlx-swift's own README states
that SwiftPM on the command line cannot build its Metal shaders, and MLX does
not degrade to the CPU when the library is missing — it fails to load its
default metallib and takes the process with it, on a three-element multiply.
Beyond that, and still true with Metal working: a 2048-point transform over a
handful of frames is a size where launch and synchronisation cost more than the
arithmetic. vDSP is what Apple wrote for it. MLX earns its place when there is a
trained model to run, which is a different feature with a different build.

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

**[TODO.md](TODO.md)** is what is worth doing next, with the evidence for each
item and the confidence it deserves — and, just as usefully, the things already
measured and ruled out.

**[AGENTS.md](AGENTS.md)** is the working agreement: what the invariants are,
what needs a human, how the four interface checks differ, and which dead ends
have already been measured and are not worth retrying. Read it before changing
anything.

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
