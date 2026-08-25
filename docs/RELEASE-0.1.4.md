# YunAudio 0.1.4 — draft

**Not published.** The release gate has not been run on this commit: the flow
check needs a machine whose audio server is opening devices, and this one is not.
Publish after `./App/verify.sh` passes, and paste its evidence into the section
at the end.

---

YunAudio 0.1.4 is a diagnosis release. Six faults that had been reported as
"it cuts out", "it sounds wrong" or "it stops working" are now things the
application measures, names and — where it can — fixes.

## What changed

**Dropouts have a number.** Core Audio posts `kAudioDeviceProcessorOverload`
when a callback misses its deadline, which is the click somebody hears, and
nothing in this project had ever registered for it. Members and the aggregate
are counted apart, because "the Bluetooth output overran" and "our own callback
ran late" are different faults. The window says how often the audio broke up and
which device reported it; the settings pane says "none" when it has not.

**And a cure, offered rather than taken.** Three misses inside ten seconds is a
route that cannot hold its cycle — one miss is a click that happens on a healthy
machine, measured here as one in the first 1541 cycles of a cold route and none
in three runs after it. The offer is a longer IO cycle, remembered for that
output only, because a headset that cannot hold 128 frames says nothing about
the interface beside it. It is offered because applying it rebuilds the route,
and a rebuild is a gap somebody should choose.

**"Not bit-exact" stopped being one sentence for two different things.** The
integrity check now reports what the path did in the terms it is heard in: level
change, residual, waveform correlation and the octave bands. A path that is
6 dB quieter and identical otherwise used to read exactly like a path carrying a
different recording.

**A start that never comes back says why.** After twelve seconds — a start takes
under two on a wired path and a few on Bluetooth — the application asks Core
Audio whether it will open a device, and repeats the answer. Where the system
will build a device and then refuse to open it, it says so, says that waiting
does not end it, and gives the command that does.

**The echo canceller can no longer take the application with it silently.**
Constructing the voice-processing unit can reach a Core Audio call that does not
return; when it does, this process can build no further graph. That is now
reported, with a Relaunch button, instead of the application accepting Start and
reporting success for ever. On a machine already known to be in that state the
canceller is skipped and the route goes up without it.

**Words that do not line up say which of the three ways they are wrong.** Wrong
edition, uniform offset, or drift across the song — and the fixable one has a
button.

## Wider support

**macOS 14.2 instead of 15.** The floor is process taps, which have no
alternative. The two symbols above it bought no capability at all: Swift's
`Atomic` — three cells in one class, now the C11 atomics the realtime layer
already used — and `textRenderer`, which guards a benchmark control. The built
binary reports `minos 14.2`, and a test fails if the package, the plist and the
README ever stop naming the same version.

## Measured, not claimed

- Every effect at its default: five are bit-exact. Compressor −33.3 dB residual,
  equaliser −19.7, reverb −16.2, echo −10.9, character −10.1.
- Resampling: 44.1↔48 kHz at −67.0 dB, 96→48→96 at −62.8 dB, correlation
  1.000000 — an order of magnitude below any effect on the list.
- Voice isolation is tonally neutral on speech: every voice band within
  ±0.21 dB, at the cost of 933 frames and 1.75 dB.
- Pitch and formant at their defaults are bit-transparent and cost 107 ms
  between them. The application now says so.
- A Bluetooth headset here reports 273 ms of output latency. The monitor no
  longer prints that number without saying what it means.

## Housekeeping

- The formatting gate was failing on committed code, so it was not a gate.
  Clean, and the eight rules the formatter cannot apply were done by hand.
- 170 test waits were bets that a machine running 350 suites in parallel would
  answer in one second. The suite recorded ten to twelve issues per full run
  before this and now runs clean.
- `yunaudio-cli` gains `health` (is the audio server opening devices — three
  seconds, where establishing it by hand took a sampler on a hung process),
  `fidelity`, `cycles`, and `echo`; `diagnose` reports process identifiers and
  aggregates without clients.

## Release evidence

_To be filled in from `./App/verify.sh` on the shipping commit._
