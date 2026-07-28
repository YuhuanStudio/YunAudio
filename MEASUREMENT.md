# Measuring a bit-exact audio path on macOS

Every audio router says it does not touch your signal. This one measures it,
and this is the method — written out so the claim can be checked rather than
believed, and so anybody can run the same check against their own path.

Nothing else in this category on macOS measures this at all. That is not a
boast about the code; it is the reason this document exists, because a claim
nobody can test is worth about as much as no claim.

## What "bit-exact" has to mean

It has to mean that the samples arriving at the destination are the same
numbers that left the source. Not "we did not intend to alter them" — the
same numbers.

That distinction is the whole problem, because on macOS a path can be altered
by things nobody wrote down:

- The two devices have separate crystals. One runs a few parts per million
  faster than the other, and something has to reconcile them. That something
  is a sample rate converter, and it runs whether or not anyone asked.
- An aggregate device applies drift correction to its members by default,
  which is that converter.
- A device can be at a different nominal rate from the one you think you set,
  because setting a rate is a request and not all hardware honours it.
- A volume control anywhere on the path — the device's own, the system's, the
  application's — attenuates, and attenuation of a float sample is a multiply
  that does not round-trip.

Any one of those produces audio that sounds perfect and is not the same
numbers.

## The method

`yunaudio-cli selftest` sends a known sequence through the real path and reads
it back off the loopback.

**The sequence.** A 64-bit mix function of the frame index, truncated to
**24 random bits**, mapped into [−1, 1) by an exact power-of-two divide:

```swift
var x = frame &* 0x9E37_79B9_7F4A_7C15
x ^= x >> 30
x = x &* 0xBF58_476D_1CE4_E5B9
x ^= x >> 27
x = x &* 0x94D0_49BB_1331_11EB
x ^= x >> 31
let bits = UInt32(truncatingIfNeeded: x) >> 8   // 24 bits
return (Float(bits) - 8_388_608.0) / 8_388_608.0
```

Three properties, each of which matters:

- **Deterministic from the frame index**, so the expected value at any point
  can be recomputed rather than stored, and the comparison needs no reference
  recording.
- **Exactly representable in float32.** Twenty-four bits divided by a power of
  two round-trips with no rounding at all. A signal that could not be
  represented exactly would fail the comparison for reasons that have nothing
  to do with the audio path, and the whole point is to assert equality.
- **Pseudorandom rather than periodic.** A sine or a ramp can be resampled and
  still match at a lot of sample positions by coincidence. A 24-bit
  pseudorandom sequence cannot: an exact match over a quarter of a million
  samples cannot happen by accident.

**The path.** The sequence is written into one destination channel from inside
the IOProc, at the same point ordinary audio is written — after the routing
matrix, after the master, exactly where a real sample goes. It comes back on
the loopback device's input, into the same IO cycle.

**The alignment.** The round trip has a delay, and the delay is not known in
advance — it depends on the device, its buffer size and the driver. So it is
**recovered from the data**: the captured run is slid against the generated
sequence and the offset that minimises error is taken. That number is
reported, which is itself useful (it is the path's true round-trip latency in
frames, measured rather than summed from published latencies that hardware
routinely misreports).

**The comparison.** Every captured sample against the sequence value for its
recovered frame index. Not a correlation, not an RMS error — equality.

## What it reports

```
bit-exact: 261400/261400 samples identical, delay 872 frames
clock lock held at 0.999986 throughout
```

On a path that is *not* clean it says what is actually true rather than
failing:

```
resampled: 258113/261400 within 1 LSB, delay 869 frames, largest error 3.2e-05
```

That second form is deliberate. "Fail" is not a useful answer to somebody
whose path is resampled; the useful answer is *how far off*, because that
tells them whether the converter is doing a good job or a bad one.

## The number beside it

`0.999986` is the microphone's crystal, measured against the destination's:
**fourteen parts per million slow**. That is 50 ms of drift per hour if
nothing corrects it, and it is the reason drift correction exists.

It is also the reason this project ships its own virtual device rather than
borrowing one. A CoreAudio driver defines its own clock through
`GetZeroTimeStamp()`. This one derives its sample clock from the microphone
the application is actually capturing, so the two devices advance together,
the HAL's drift correction can be switched off, and nothing on the path
resamples. A third-party loopback device cannot do this — it has no idea
which microphone you care about.

## Running it yourself

```bash
swift run -c release yunaudio-cli selftest
```

It is also in the application, under Preferences → Diagnostics, because a
measurement only the author can run is not evidence. Press the button and it
sends the sequence through your own path and grades what comes back.

## What it does not prove

Worth being explicit, because a measurement oversold is worse than none.

- It proves the path **at the moment it ran**. A device change, an
  application opening the microphone at a different rate, or a sample rate
  somebody moved in Audio MIDI Setup can each break it afterwards. That is
  why the application reports path quality continuously rather than once.
- It proves the path **through the loopback**, which is the path to a virtual
  device. Routing to a physical output has no return path to read back from,
  so there the report falls back to what can be established by inspection:
  nothing is being drift-corrected, nothing is processing, and where the lock
  is required it is confirmed to be holding. That is weaker and is labelled
  as such.
- It says nothing about **quality** beyond identity. Bit-exact is a statement
  about arithmetic, not about whether the microphone is any good.
- Switching on voice isolation, echo cancellation or any effect makes it
  false immediately and the application says so, because processing the
  signal is the opposite of leaving it alone.

## The related measurements

The same harness produces the rest of the numbers this project claims, and
they are worth listing in one place because each was a separate piece of
work:

| What | How it is measured | Result |
|---|---|---|
| Realtime allocations | Allocator hook counting on the IO thread, release build | 0 over thousands of cycles |
| Processor cost | Six-minute run, stereo route at 128 frames | 0.40% of one core |
| Memory | Same run | 4.7 MB resident, +4 kB/min (allocator noise; it ends below its own midpoint) |
| Cycle rate | Same run | 375.0/s, worst deviation 0.1 — 48000/128 exactly |
| Monitor latency | One IO cycle plus the output device | 2.7 ms into a sane driver, 11.2 ms into a display |
| Voice isolation cost | `yunaudio-cli dsp` | 56 ms added latency, under a quarter of the IO deadline in CPU |
| Loudness | 1 kHz sine of known amplitude | reads its own RMS in LUFS; doubling amplitude adds exactly 6.02 |
| Spectrum | Tone of known amplitude | comes back at its own level in dB — the assertion that caught a real transform bug |
| Headphone correction | Sine through the real IOProc | a 6 dB filter lifts its own frequency by 6.0 dB |
| Echo canceller ring | `yunaudio-cli far-end` | 388,096 frames at 48 kHz, none dropped, −128 frames of drift |

Every one of those is an assertion in the test suite or a check in
`yunaudio-cli`, not a figure somebody wrote down once.
