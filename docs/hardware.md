# Razer hardware control

← [README](../README.md)

English · [繁體中文](zh-Hant/hardware.md) · [简体中文](zh-Hans/hardware.md)

## Protocol

The Seiren V3 Pro's light ring is implemented. Getting there took a capture of
Synapse driving the device on Windows — polling the same feature report every
three milliseconds while the lighting was changed — and everything that came
out of it, along with the manufacturer's own figures for the Barracuda and two
conclusions that measurement later overturned, is written up in
**[DEVICES.md](../DEVICES.md)**.

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

