# Limitations

← [README](../README.md)

English · [繁體中文](zh-Hant/limits.md) · [简体中文](zh-Hans/limits.md)

## Rejected approaches

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

**Using `kAudioSubDeviceInputChannelsKey` to keep a Bluetooth microphone out of
an aggregate.** The key was measured as descriptive rather than selective: a
three-input device requested as one still exposed three inputs, and a one-input
device requested as zero still exposed one. The test remains so a future HAL
change is detected. macOS also has no counterpart to iOS's
`AVAudioSessionCategoryOptionBluetoothHighQualityRecording`; that option is
explicitly unavailable on macOS. A high-quality Bluetooth output therefore has
to be paired with a microphone on another device, then verified on the actual
headset.

**AVFoundation as the clean monitoring output.** The macOS 27 SDK exposes the
spatial rendering machinery through AVFAudio, not as a Core Audio device
property. Using `AVAudioEngine` and `AVAudioEnvironmentNode` would replace the
output path, add a separately measured latency and end the bit-exact claim by
definition. It may make sense for an explicitly processed, output-only bus; it
is not a substitute for the router's monitoring path.

**MediaRemote for broad now-playing control.** On the measured host the private
framework and its expected symbols loaded, but every query returned an empty
dictionary while the same player answered Apple Events. A private API which
fails silent is not a supported fallback. Player scripting dictionaries remain
the bounded integration surface until a public API supplies the missing data.

**App Intents in the current shell-assembled SwiftPM bundle.** Intent code can
compile and run, but the present packaging path does not generate the metadata
which lets Shortcuts and system experiences discover it. The remote-command
vocabulary remains the implementation to reuse after the application build is
migrated to an App Intents-capable packaging path; duplicating the commands now
would create an undiscoverable second interface.

**Replacing the interleaved routing loop with a strided vDSP call.** At two
routes and 512 frames the measured loop cost was 954 ns versus 1,501 ns for the
vDSP form, with identical arithmetic. Interleaved audio makes this access
strided, where call and fallback overhead cost more than the short scalar loop.

**Realtime neural voice conversion.** The deadline at 48 kHz and 128 frames is
2.67 ms. Current RVC/fish-speech-class pipelines require well over 100 ms, even
before scheduling and device latency. They can be offered only as offline or
explicitly high-latency processing until a complete measured pipeline fits the
realtime admission budget; moving a model onto a faster accelerator does not
waive that end-to-end number.

## Current limitations

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
