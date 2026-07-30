# Limits, and what does not work

← [README](../README.md)

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

