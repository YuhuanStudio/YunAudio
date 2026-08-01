# Capabilities

Every capability, with the measurement supporting it. The README summarises
these by area; this page is the complete list.

← [README](../README.md)

English · [繁體中文](zh-Hant/features.md) · [简体中文](zh-Hans/features.md)

## The complete list

**The signal path is provably bit-exact.** Not "we don't think anything
resamples it" — measured. `yunaudio-cli selftest` sends a 24-bit pseudorandom
sequence through the whole path, reads it back off the loopback, recovers the
delay from the data and compares every sample:

```
bit-exact: 261400/261400 samples identical, delay 872 frames
clock lock held at 0.999986 throughout
```

The method is written up in **[MEASUREMENT.md](../MEASUREMENT.md)** — the
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

The performance is aligned against the reference before it is measured. Banded
dynamic time warping over one lyric line at a time — a few hundred samples
against a corridor of a hundred, so tens of thousands of cells per line rather
than the nine hundred million an unbanded five-minute song would cost. What that
buys is a distinction the moment-to-moment comparison could not make: a phrase
entered a third of a second late scores as *late* rather than as four semitones
flat, and lateness and steadiness are reported separately from pitch. Being
consistently behind the file is phrasing, and plenty of published `.lrc` is that
far out on its own; being late, then early, then late is the thing people mean
by off the beat, and it is the only part of timing worth scoring.

A small on-device model on the Neural Engine picks the voice out when the
accompaniment is louder than it. Measured through the whole pipeline rather than
per frame, by running the suite with and without it: at the singer's own level
it is worth nothing, which is correct — the rule is already right there and the
model defers to it — and at one and a half, two and three times it is worth
three, six and thirteen points. At four times both collapse, so this extends the
range where scoring works rather than removing the limit. It costs 0.24 ms a
frame at a four-hertz cadence and is switchable, because a claim about what
something is worth needs the same pipeline measured without it.

The stage is a window of its own, and the panel in the main window is built from
the same controls — the transport, the queue, the words controls, the scoring
switch and the key suggestion are one construction each, so a control added to
either reaches both. Words sweep a syllable at a time where the source carries
word timing, with pronunciation above the line and conversion between the two
Chinese scripts; the offset is remembered per song, for the files that carry no
lead-in. The queue puts songs on the end, 插播 next, and stops at the end rather
than starting the evening again — and it survives quitting, which for the one
feature whose purpose is not walking back to the machine between songs is the
difference between having it and not.

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

