# YunAudio 0.1.4

## The one that mattered

**Echo cancellation and any single effect could not run together**, and what
happened when somebody tried was worse than a refusal: the route failed, the
teardown timed out on top of it, and repeating it left the machine unable to
open an aggregate device *at all* — for every application, not just this one,
until the audio server was restarted. That is the report that said this
application degraded a machine until it needed a reboot.

It was ours. The route took a graph admission to publish the effect chain and
released it with a `defer` at the end of the whole start, so it was still
outstanding when the canceller was asked to start — and starting the canceller
goes through the sole disposer, which refuses while any graph admission is. Two
seconds of waiting on our own bound, then failure.

Either half alone was always fine, which is why it looked like Core Audio's
fault. Measured on a freshly booted machine, before and after:

| | before | after |
|---|---|---|
| effects, no echo | 1310 cycles | 1243 cycles |
| echo, no effects | 1214 cycles | 1225 cycles |
| **echo + one effect** | **failed** | **1187 cycles, no missed deadlines** |

The start path went from 2002 ms and never reaching the IOProc, to 56 ms with
the IOProc created in 1 ms and started in 6.

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
  `fidelity`, `cycles`, `echo`, and the `aec-instantiate` / `aec-layers` probes
  that peel a cancelling start apart a layer at a time; `route` takes `--echo`
  and `--effects`; `diagnose` reports process identifiers and aggregates
  without clients.
- `YUNAUDIO_TIMING` announces each start stage *before* it runs. It only
  printed after, so a stage that never returned never appeared and the trace of
  a hung start ended at the last stage that worked. That one change is what
  found the fault above.

## Upgrading

Nothing to do beyond replacing the application. The virtual device is unchanged
and does not need reinstalling.

If a machine has been left in the state the fault above produced — routes that
will not start, and `yunaudio-cli health` reporting that an aggregate device was
built and would not open — restarting the audio server clears it, and needs an
administrator:

    sudo killall coreaudiod

Audio returns on its own a second or two later. This should be the last time it
is needed for this reason.

## Release evidence

`./App/verify.sh --full` on the shipping commit:

    build…                          ok
    strict formatting…              ok
    tests…                          ok
    strings…                        ok
    app bundle…                     ok
    settings entry…                 ok
    offscreen render…               ok
    photograph the real window…     ok
    installed driver matches release…ok
    audio can start at all…         ok
    the path is bit-exact, release… ok
    flow check…                     ok

    everything asked for passed.

and `./App/verify.sh --fresh`, which is the one check that catches what only
works because this working tree is here:

    builds from a fresh clone…      ok

2164 tests in 368 suites. The interface is verified four ways — a flow check
against the live application, an offscreen render of all 67 panels, a
photograph of the real window, and a scan that every user-facing literal goes
through `loc()` — because each is blind to what the others catch.

Two of those steps had been failing before this release and neither was a
regression:

- `the transpose reports what it is holding` asserted a latency the unit does
  not have. Measured with an impulse rendered offline: it emerges at frame 0 at
  unity and at +200 cents alike. The check asserts zero now, and keeps the
  claim so a unit that *does* hold a window is noticed.
- `and the sweep follows the playback clock` allowed half a publication of the
  lyric sweep, which publishes every 100 ms against a clock read this instant.
  Over a one-second line that is a coin toss, and it failed on the middle of
  three lines while the other two passed. The tolerance is derived from the
  cadence now rather than chosen.
