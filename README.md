<div align="center">

# YunAudio

**A menu bar audio router for macOS, with a virtual device of its own —
and a signal path you can prove is bit-exact.**

[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white)](#requirements)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Licence MIT](https://img.shields.io/badge/licence-MIT-blue)](LICENSE)
[![672 tests](https://img.shields.io/badge/tests-672-brightgreen)](#verify-it-yourself)
[![no dependencies](https://img.shields.io/badge/dependencies-none-lightgrey)](#requirements)

English · [繁體中文](README.zh-Hant.md) · [简体中文](README.zh-Hans.md)

</div>

<img src="docs/images/window.png" alt="The YunAudio window: devices, patchbay, analysis and the processing inspector" width="100%">

## Why it exists

Discord's WebRTC engine reaches down to the HAL and fights high-end USB
microphones for control of the device, producing a crackle once per second.
Routing the microphone into a virtual device that Discord opens instead makes the
problem go away.

Along the way it turned out macOS has several capabilities in this area that
nothing else exposes, so the project grew.

## What is different about it

<table>
<tr><td width="50%" valign="top">

### The path is provably bit-exact

Not "we don't think anything resamples it" — measured, by you, on your own
hardware:

```
bit-exact: 261400/261400 samples identical
delay 872 frames
clock lock held at 0.999986 throughout
```

That last number is your microphone's crystal: 14 parts per million slow, which
is 50 ms of drift per hour if nobody corrects it.

</td><td width="50%" valign="top">

### Because the driver is ours

A CoreAudio driver defines its own clock through `GetZeroTimeStamp()`. This one
derives its sample clock from the microphone the app is actually capturing, so
the two devices advance together, the HAL's drift correction can be switched
off, and nothing on the path resamples.

A third-party loopback device cannot do this — it has no idea which microphone
you care about.

</td></tr>
</table>

**It tells you the truth about the path.** Bit-exact, resampled or processed;
measured round-trip latency; whether the clock lock is holding. Switch on voice
isolation and it says so and stops claiming bit-exactness, because processing the
signal is the opposite of leaving it alone.

**Loudness to the broadcast standard.** A peak meter answers "will this clip". It
does not answer "am I as loud as everyone else" — Discord normalises to about
−18 LUFS, YouTube to −14, broadcast to −23. YunAudio measures to ITU-R
BS.1770-4: K-weighting, 400 ms blocks at 75% overlap, and the two-pass gate that
stops pauses counting. Then it says how far you are from the platform you picked,
and which way to move.

**Every source is a source.** One process tap per application rather than one
mixdown of all of them, so Discord and Spotify can have different volumes,
different roles and different treatment when somebody talks. Two microphones are
two strips with two faders — which is also what makes a duet two measured
performances rather than two voices guessed out of one mix.

**Two mixes, not one.** What the far end hears and what you hear are different
questions. Each source has its own send on each bus, and each bus has its own
tone control and headphone correction.

**Karaoke that does not assume Chinese music has no words.** Music's own lyrics
and local `.lrc` files first, then LRCLIB, QQ Music, NetEase Cloud Music and
lyrics.ovh, asked concurrently; a validated timeline wins and cancels the slower
requests. Scoring says what its reference is — an exact MIDI melody, captured
original vocals, or key and timing alone — because an accompaniment does not
contain the vocal line, and scoring against one anyway would be inventing a
number.

**Direct monitoring that is actually direct.** Hearing yourself through a
conferencing application is thirty milliseconds behind, which is late enough to
stumble over. Monitoring here is a second destination on the same aggregate: one
buffer, measured and displayed.

**A spectrum you can read frequencies off.** Logarithmic, so an octave is the
same width everywhere, with the grid at 100 Hz, 1 kHz and 10 kHz — and the
equaliser's bands sit at the frequencies the analyser draws, so what you can see
you can reach.

**It levels itself, and it knows what it is listening to.** Automatic gain moves
the trim only while Apple's own sound classifier hears speech, so pauses and
typing do not wind the level up. The same classifier is what stops a cough
ducking the music.

**Transcription that knows who said what.** Each source is written down under its
own name, on-device, because each source is already its own route with its own
ring. No speaker diarisation, because there is nothing to guess.

**Application audio with no extra driver.** `AudioHardwareCreateProcessTap` has
existed since macOS 14.2 and almost nothing uses it. A captured application
survives quitting and reopening, which is OBS's issue #9144 — open since June
2023, and answered here by one argument.

**The realtime path allocates nothing.** Asserted in release builds by a hook
that sits in front of every allocation the process makes. The one exception is
named rather than hidden: Apple's voice isolation model allocates about 0.3 times
per cycle from inside itself.

There are twenty-one of these in all, each with the measurement behind it, in
**[docs/features.md](docs/features.md)**.

## Screens

<table>
<tr>
<td width="33%" valign="top"><img src="docs/images/tab-sound.png" alt="Processing inspector"><br><b>Sound</b><br>Clean up, change the voice, tone and space — grouped by what a stage is <i>for</i> rather than by where it sits in the signal.</td>
<td width="33%" valign="top"><img src="docs/images/tab-singing.png" alt="Singing"><br><b>Sing</b><br>Timed lyrics from five sources, key detection with a suggested transpose, and a score per microphone.</td>
<td width="33%" valign="top"><img src="docs/images/tab-recording.png" alt="Recording"><br><b>Record</b><br>WAV, FLAC or AAC, with a file per source alongside the mix. Stems are taken before the fader.</td>
</tr>
<tr>
<td valign="top"><img src="docs/images/tab-plugins.png" alt="Plug-ins"><br><b>Plug-ins</b><br>Third-party Audio Units in the chain. One that will not load is named, with the step that refused it.</td>
<td valign="top"><img src="docs/images/tab-scripting.png" alt="Scripting"><br><b>Script</b><br>JavaScript that stays loaded and reacts to events — muted, recording started, a device appeared.</td>
<td valign="top"><img src="docs/images/tab-hardware.png" alt="Hardware"><br><b>Device</b><br>Setups, per-bus tone, headphone correction, output alignment and the microphone's light ring.</td>
</tr>
</table>

<table>
<tr>
<td width="30%" valign="top"><img src="docs/images/panel.png" alt="The menu bar panel"><br><b>The menu bar panel</b><br>Everything most sessions need, without opening the window.</td>
<td width="70%" valign="top">
<img src="docs/images/prefs-diagnostics.png" alt="Diagnostics: the integrity check"><br>
<b>Diagnostics.</b> The integrity check is a button, not only a CLI flag. It sends
a 24-bit pseudorandom sequence through your own path, reads it back off the
loopback, recovers the delay from the data and compares every sample. On a path
that is not clock-locked it reports what is actually true — resampled, with the
recovered delay and the size of the conversion — rather than pass or fail.
</td>
</tr>
</table>

## Requirements

- **macOS 26 or later.** Live transcription needs macOS 27; on 26 it is shown as
  unavailable with the reason, and everything else works.
- **No third-party dependencies.** `Package.swift` has an empty `dependencies`
  array, and the checks keep it that way.
- Building needs an Xcode carrying the **macOS 27 SDK**, because live
  transcription uses `AnalyzerInputConverter`. The scripts find one themselves; a
  hand-run `swift build` may need `source ./App/toolchain.sh` first, otherwise the
  error is `cannot find type 'AnalyzerInputConverter' in scope`, which reads like
  a typo rather than like an SDK a year old.

## Install

There are two ways in, and the difference between them is one dialog.

**A disk image.** `./package.sh` builds `build/YunAudio-<version>.dmg`, carrying
the application, the virtual device, and a script each for installing and
removing it. macOS will refuse to open the application the first time and say the
developer cannot be verified — that is what it says about anything that has not
been through Apple's paid notarisation service, which this project has no account
for. Privacy & Security in System Settings has an **Open Anyway** beside it, and
once is enough. The image says so in a `READ ME FIRST.txt` you see before you see
anything else, because a refusal with no explanation next to it is where most
people stop.

**Or build it yourself.** A binary you built carries no quarantine flag, so none
of the above applies.

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

**The virtual device is optional.** Capturing other applications, the effect
chain, recording, transcription, monitoring, OBS, MIDI and scripting all need
nothing installed. What the device buys is the other half: other applications
being able to choose YunAudio as their microphone, over a path that is bit-exact.

## Verify it yourself

One command runs everything, and says what it did **not** run.

```bash
./App/verify.sh --list                        # the ladder, with what each step costs
./App/verify.sh                               # everything that does not need the audio hardware
./App/verify.sh --full                        # and the flow check, which takes the hardware
./App/verify.sh --fresh                       # and a clone into a directory of its own
./App/verify.sh --only=build,tests            # 10 s
./App/verify.sh --flow="more than one input"  # one section of the flow check, 44 s
```

The steps are deliberately blind to each other: 672 unit tests, a string-table
comparison across three languages, an offscreen render of every panel, a
photograph of the real window the window server drew, an assertion that nobody
else holds the audio devices, a release-build bit-exactness measurement, and a
flow check that drives the whole interface against live hardware. Each catches
what the others cannot — a whole feature once shipped with no tab at all, and only
the photograph found it.

Then look at `build/screenshots`. The gate can tell you a photograph was taken; it
cannot tell you the layout in it is wrong.

Every rung, and every probe underneath it — the soak test, the echo-cancellation
seam, the far-end ring — is in **[docs/verification.md](docs/verification.md)**.
The method behind the bit-exactness figure is written up in
**[MEASUREMENT.md](MEASUREMENT.md)** — the sequence, why it is 24 bits, how the
delay is recovered from the data, and, just as importantly, what the measurement
does not prove.

## Drive it from something else

| Interface | For |
|---|---|
| `yunaudio-cli` | Scripting the running application from a terminal or a keyboard macro |
| A Unix socket, `chmod 600` | The transport underneath the CLI, if you would rather speak to it directly |
| `yunaudio-mcp` | An agent driving the application over MCP |
| Resident JavaScript | Reacting to events inside the app: muted, recording started, a device appeared |
| obs-websocket v5 | Mirroring mute into OBS, and handing OBS the sync offset it cannot work out itself |
| CoreMIDI | A physical fader, with soft takeover so picking one up cannot slam the signal |

One vocabulary underneath all of them — `Sources/YunAudioControl` defines it once.
The details are in **[docs/automation.md](docs/automation.md)**.

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
App/                bundle assembly, the icon, and verify.sh
```

## Known limits

- The driver is ad-hoc signed. Distribution without a first-launch dialog needs a
  Developer ID identity and notarisation.
- Voice isolation makes `AudioUnitRender` allocate on the IO thread — about 0.3
  allocations per cycle, from inside Apple's model rather than from this code. The
  bypass path stays at exactly zero. It has not caused a dropout in testing, but
  the realtime contract is broken while it is on.
- A driver fault takes `coreaudiod` down with all system audio attached. Keep the
  uninstall command above to hand.
- The virtual device's input level control is implemented but has only been
  verified by inspection; moving it through System Settings has not been tried
  on-device, because installing a driver restarts `coreaudiod`.
- Echo cancellation costs the clock lock and bit-exactness, and adds a buffer of
  latency in each direction. Not a defect to be fixed later: the canceller has to
  own the microphone and the speaker together, so the microphone leaves the
  router's aggregate and the clock master becomes the destination. Worth it on
  laptop speakers, worth nothing on headphones, so it is off by default and the
  interface says what it costs before it is switched on.

More, including everything that was tried and does not work, in
**[docs/limits.md](docs/limits.md)**.

## Documentation

An index in all three languages is at **[docs/](docs/README.md)**.

| | |
|---|---|
| [MEASUREMENT.md](MEASUREMENT.md) | How the bit-exactness figure is obtained, and what it does not prove |
| [docs/verification.md](docs/verification.md) | The gate, every probe under it, and what each cannot tell you |
| [docs/features.md](docs/features.md) | Every claim at length, with the measurement behind each |
| [docs/automation.md](docs/automation.md) | CLI, control socket, MCP, scripting, OBS, MIDI |
| [docs/hardware.md](docs/hardware.md) | Razer HID control, and how the protocol was established |
| [docs/limits.md](docs/limits.md) | What does not work, and what has been ruled out |
| [DEVICES.md](DEVICES.md) | What each piece of hardware here actually is, and how each fact was checked |
| [AGENTS.md](AGENTS.md) | The working agreement for changing this project |
| [TODO.md](TODO.md) | What is worth doing next, with the evidence each item deserves |
| [RESEARCH.md](RESEARCH.md) | The competitive and API research behind the decisions |

## Licence

MIT — see [LICENSE](LICENSE).

The virtual device is written from scratch against
`<CoreAudio/AudioServerPlugIn.h>`. It shares no code with BlackHole, which is
GPL-3.0.

## Contributing

**[AGENTS.md](AGENTS.md)** is the working agreement, and it is worth reading
before changing anything: what the invariants are, what needs a human, how the
four interface checks differ, and which dead ends have already been measured.

The short version — assert a number rather than a belief, verify the interface
four ways because each is blind to what the others catch, and remember that the
realtime path allocates nothing.

```bash
swift build && swift test
"$(xcrun --find swift-format)" lint --recursive Sources Tests
"$(xcrun --find swift-format)" format --in-place --recursive Sources Tests
```

`swift-format` lives in the Xcode toolchain rather than on `PATH`, which is why
the invocation goes through `xcrun`.
