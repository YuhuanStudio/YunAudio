# What the hardware actually is

Everything this project established about specific devices, distilled from a
Windows reverse-engineering pass, the manufacturer's own manuals, and — where
the two disagreed with reality — measurement on this machine.

It is here rather than in a folder of DLL dumps because the dumps have served
their purpose: what was worth extracting is extracted, and what remains is six
megabytes of somebody else's proprietary binaries sitting in a git history.

**Two of the conclusions below were wrong until they were measured.** Both are
marked. That is not a criticism of the work that produced them — the Windows
side genuinely says what it says. It is the reason the last column of every
table here is "checked how".

---

## Razer Seiren V3 Pro

USB `0x1532` / `0x058E`. A UAC 2.0 composite device with four interfaces: audio
control, playback, capture, and an HID interface Razer uses for lighting.

### What CoreAudio gives you, measured

| Thing | Value | How it was checked |
|---|---|---|
| Sample rates | **48 k and 96 k only — no 44.1 k** | Device descriptor and CoreAudio agree |
| Capture channels | 3 | `kAudioDevicePropertyStreamConfiguration` |
| Hardware gain | **0 to +36 dB, settable, on elements 1–3** | Control inventory |
| Play-through | **Settable** | Control inventory |
| Headphone output | −64 to 0 dB | Control inventory |
| Volume keys | Do **not** move it | It publishes no master element |

> **Corrected.** The Windows write-up concluded that macOS's UAC2 driver does
> not expose this device's gain, and that only a USB control transfer could
> reach it. This project believed that for months and shipped a digital trim
> instead. It is exposed. CoreAudio publishes controls *per element*, the
> master is element 0, and asking only for the master looks like it works
> because most devices answer there. This one answers on 1, 2 and 3 — one per
> capsule tap. Nobody had asked the right element.

### The three capture channels

`Device_Mic`, `Device_MicDry`, `Device_MicPostExp` — the processed capsule, the
dry capsule, and the capsule past the microphone's own expander. That expander
sits ahead of the converter, so it removes room noise before anything can clip.
CoreAudio reports three inputs and nothing about what is on them; the names come
from the device's own module printing its internal topology.

Their existence means the device has a hardware expander, which contradicts the
tidy summary that "all noise reduction is on the host". The *sliders* in Razer's
software are host-side; this tap is not.

### The UAC 2.0 topology

```
CLOCK_SOURCE   1    programmable, host may set the rate

capture:   INPUT_TERMINAL 6 (microphone, 3 ch)
             └ FEATURE_UNIT 7      master mute, ch1–3 volume   ← the 0…+36 dB gain
                 └ OUTPUT_TERMINAL 8 → USB

playback:  INPUT_TERMINAL 2 (USB, 3 ch)
             └ MIXER_UNIT 11
                 └ FEATURE_UNIT 3   master mute, ch1–3 volume
                     └ OUTPUT_TERMINAL 4 (speaker)

monitor:   FEATURE_UNIT 10 ← straight from INPUT_TERMINAL 6
                 └ MIXER_UNIT 11
```

**Feature Unit 10 is direct monitoring**: the microphone reaching the headphone
jack without passing through the computer. macOS surfaces it as the device's
play-through scope, which nothing else on this platform offers to move. This
application does.

Interface 2 alt 3 is a 3-channel `IEEE_FLOAT` stream — Razer's own mode for
carrying all three taps at once. `AppleUSBAudio` picks PCM alt settings, so this
is not how macOS gets the three channels, but it is why there are three.

### The lighting protocol

HID interface 3, usage page `0xFF53`, usage `0x0004`, **feature report `0x07`**,
64 bytes (1 report ID + 63 payload).

```
offset  0   status
        1   transaction id
        2–3 remaining packets (big endian)
        4   protocol type
        5   data size
        6   command class      0x0F = lighting
        7   command id         0x03 = custom frame, 0x04 = brightness
        8–60 arguments
        61  crc
        62  reserved
```

Three findings that save anybody else the same afternoon:

- **The openrazer protocol does not apply.** That format is 90 bytes on report
  id 0; this device declares no 90-byte report anywhere, so such a frame is
  echoed back untouched.
- **The CRC covers the transaction id.** openrazer starts its XOR one byte
  later. Confirmed against two captures whose only difference was the
  transaction id: `0x2E ^ 0x07 = 0x29` and `0x2E ^ 0x12 = 0x3C`, both matching
  the byte on the wire. A port that keeps openrazer's line produces frames the
  device rejects and nothing says why.
- **The device has no effects.** Switching Razer's software to Spectrum produced
  961 distinct RGB values streamed one frame at a time along a continuous hue
  circle. The animation runs on the host. `0x0F 0x03` writes twelve LEDs;
  `0x0F 0x04` sets brightness with zero meaning off.

Twelve addressable LEDs. **Index 0 is at six o'clock and they run clockwise** —
that could not be read off the device and came from lighting them one at a time.

### What Razer's software does that the device does not

EQ, ambient noise reduction, voice gate, vocal clarity, volume normalisation and
the high-pass are **host-side THX processing on Windows**, not device commands.
The device-specific module Razer loads exports no function for any of them, and
the THX module imports no USB or HID library at all. There is nothing to send,
which is why this project implements its own.

Their EQ is ten bands of floating-point gain. This project matches the band
centres — see below — so somebody moving across can copy their settings.

### Still unknown

All of these are EP0 vendor control transfers rather than HID, so a capture
would have to be of control transfers:

- `SetMode` (Basic / Advanced)
- The nine virtual mix channels: `SetMixEnable`, `SetMixLevel`
- `SetHwChannelHiddenFlags`
- Whether the hardware expander has adjustable parameters
- Whether lighting brightness is a separate command or multiplied into the RGB
  by the host. The evidence points at the latter: a "pure red" frame carried
  `C0 00 00` rather than `FF 00 00`.

---

## Razer Seiren V2 X

USB `0x1532` / `0x0543`.

| Thing | Value |
|---|---|
| Sample rates | 44.1 k and 48 k |
| Channels | 1 in, 2 out |
| Hardware gain | **−15 to +15 dB, settable, on element 0** |
| Play-through | Settable |
| Volume keys | Work |

Where the V3 Pro publishes per-channel controls and no master, this publishes a
master. Nothing about the two devices predicts that.

---

## Razer Barracuda

Three different audio devices depending on how it is connected, and this
matters: the mode decides whether the microphone is usable.

| Mode | Appears as | Microphone |
|---|---|---|
| 2.4 GHz, via the Type-C dongle | `Razer Barracuda 2.4` | Full quality |
| Bluetooth 5.2 | `Razer Barracuda (BT)` | 16 kHz, and drags the output down with it |
| 3.5 mm | no identity of its own | analogue |

**Use the dongle if you want the microphone.** Over Bluetooth the whole device
negotiates HFP, which takes the output to 16 kHz as well.

From the manufacturer's manual:

| | |
|---|---|
| Headphones | 20 Hz – 20 kHz, 32 Ω @ 1 kHz, 96 dBSPL/mW, 50 mm drivers |
| Microphone | **100 Hz – 10 kHz**, ≥ 65 dB SNR, −33 ± 3 dB @ 1 kHz, omnidirectional |
| | Two integrated ECM capsules with AI noise reduction |
| Bluetooth codecs | AAC and SBC only |
| Battery | up to 40 hours |

The microphone's 100 Hz – 10 kHz response is worth knowing, because it turns the
16 kHz input rate from something that looks like a fault into roughly what the
capsule can actually produce.

Measured here, and it varies with what the link negotiated: output 44.1 kHz on
one occasion and 48 kHz on another, input 16 kHz and only 16 kHz both times.

Razer's own EQ for this headset is **ten bands at 30, 60, 120, 250, 500 Hz and
1, 2, 4, 8, 16 kHz, ±5 dB**, with bass boost, "sound normalisation" and "voice
clarity" alongside it — all host-side, all Windows-only. This project's output
tone control uses those exact centres.

> **Corrected.** Two ordinary devices — this headset and a Seiren V3 Pro —
> share no sample rate at all, and the router used to refuse the pair outright.
> The path to a Bluetooth headset cannot be bit-exact whatever happens, so the
> only question is who resamples; the HAL does it well. Measured over 3040 IO
> cycles with zero allocations on the realtime path.

---

## How to find this out for a device this file does not cover

The flow check prints a control inventory for every device on the machine —
class, scope, element, current value and whether it can be set. That is where
both of the corrections above came from, and it takes one run:

```bash
YUNAUDIO_FLOWCHECK=1 YUNAUDIO_FLOWCHECK_ONLY="what each device" \
  ./build/YunAudio.app/Contents/MacOS/YunAudioApp
```

The interesting answer is usually the control nobody thought to look for.
