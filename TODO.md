# What is left to do

One list, so that a person and an agent picking this up a month apart are
working from the same picture. `AGENTS.md` says how to work here; this says what
is worth working on and what has already been settled.

Two kinds of thing are collected below and they are kept apart on purpose:
**proposals**, which came from the person whose project this is, and **findings**,
which came from a competitive research pass. A proposal does not need
justifying. A finding does, and its evidence is written down beside it — because
the pass that produced them died partway through on a search quota, one of its
four streams fabricated roughly half its citations before catching itself, and
two streams never reported at all. Anything recovered from it is marked with how
much it can be trusted.

## Reading the marks

Confidence, carried over from the research:

- **[V]** — verified: a source was actually opened and said this.
- **[M]** — from a stream that was not independently re-checked, but internally
  consistent with things that were.
- **[?]** — plausible, unverified. A lead, not a fact.
- **[proposal]** — asked for directly. Needs no evidence.

Effort is the researcher's estimate unless this project has since measured it.

---

## Done, so nobody does it twice

The short version. `README.md` says what each of these actually is.

Bit-exact clock-locked path · loudness to BS.1770-4 · 24-band spectrum ·
automatic levelling gated by Apple's sound classifier · direct monitoring at
2.7 ms · formant-shifting voice changer with presets · six-band tone EQ ·
compressor with a reduction meter · gate · pitch · character · reverb · echo ·
limiter · third-party AUv3 hosting · per-application process taps, one tap per
application · per-source stem recording · WAV/FLAC/AAC · push to talk ·
ducking · ten-second all-speak calibration · JSON device profiles ·
Razer Seiren V3 Pro light ring · voice isolation · echo cancellation ·
our own virtual device with a working volume control · tabbed inspector ·
switchable visual style · live transcription attributed per source ·
fall-back and auto-restore when a device is unplugged · URL remote control.

---

## Known problems

### Two ordinary devices cannot be used together [V, measured here]

The Razer Barracuda publishes **44.1 kHz out (16 k and 44.1 k available)** and
**16 kHz in, and nothing else**. The Seiren V3 Pro publishes **48 k and 96 k**.
They share no sample rate, so the router refuses the pair outright: *"the
selected devices share no sample rate"*.

Refusing is wrong. The path to a Bluetooth headset is not bit-exact whatever
happens, and the aggregate can already resample a member — that is what drift
compensation is. The rule should be: take the best rate each end can do, let the
HAL reconcile them, and say the path is resampled.

Related, and visible in the same probe: the Barracuda's input is the system
default at 16 kHz. That is the HFP downgrade, happening now.

### A display's audio endpoint refuses to start, slowly [V, measured here]

Routing to `PG32UCDM` fails with `AudioDeviceStart failed with 'stop'` after
about twelve seconds. Nothing is wrong with the code; the endpoint will not
start. Worth knowing because twelve seconds of nothing looks like a hang, and
because it is a good argument for the fall-back to treat "will not start" the
same as "not here".

### Changing one effect restarts the whole route [V, measured here]

Enabling or disabling a single stage tears the aggregate down and builds it
back. Measured end to end it costs about **five seconds**, of which the engine
is only 0.8: aligning sample rates 56 ms, creating the aggregate 33 ms,
`AudioDeviceStart` **639 ms**, restoring rates on the way out 87 ms. The rest
is above the engine — the model's stop-then-start hop, `refreshApps()` at the
top of every start, and instantiating the chain's audio units.

Five seconds of dropout for one switch is a poor experience, and it is also
what makes the interface flow check take five minutes: one section walks all
eleven stages and costs **200 of the 298 seconds**.

The fix is that a change to the effect chain should rebuild the chain, not the
route. The graph is already published rather than mutated, so the machinery for
swapping something in under a running IOProc exists — it is used for the routing
matrix already.

### Six English words are doing two jobs each [V, measured here]

Deduplicating the string tables after a merge turned up eighteen keys written
twice, and six of them with *different* translations — the last one silently
wins, so one of the two meanings was showing the other's word:

`Pitch` is both the effect stage and the musical quantity. `None` is both "no
voice preset" and "nothing". `Record`, `off`, `High-pass` and `none captured`
are the same shape of problem.

Duplicates are now a failure in `check-strings.sh`, so no more can accumulate.
What is left is disambiguating the six at their call sites — which means
deciding what each one is actually naming, and that is a translation question
rather than a code one.

### The interface has outgrown its own layout [proposal]

Named directly: it is untidy now that there are enough features to be untidy.

- Noise reduction and the voice changer are one region and should be two.
- The scene presets barely change anything.
- The application list says how many are held back but cannot expand to them,
  and is often empty when it should not be.
- The menu bar panel has not kept up with the window at all, and shows no
  settings.
- The preferences window is thin — no language, no theme, no colour, while
  YunUI has all of that to draw on.
- The bottom status bar should be a row of pills, which is also the natural
  place to meet Apple's liquid-glass look.

### Two Razer devices are only half supported [proposal]

The Seiren **V2 X** and the **Barracuda** both need what the V3 Pro already has:
a device profile naming their channels, and whatever their own controls turn out
to be. The V2 X publishes a settable hardware gain where the V3 Pro does not,
which is already known and not yet used.

## Known problems (from the research)

Things believed to be wrong now. Each needs measuring before it needs fixing.

### The AirPods idle teardown [?] [suspected live bug]

The router holds a permanent aggregate device. A Bluetooth device inside one may
never be allowed to go idle, and opening a microphone on AirPods drags the whole
device into HFP — 16 kHz, both directions. **Not yet measured here.** The first
job is to find out whether this project actually has the problem, with AirPods
in the aggregate and a level meter on the output, rather than assuming it from
the shape of the code.

Related and worth knowing: SoundSource 6.1's release notes say *"unnecessary
drift correction is no longer applied to Bluetooth devices"* [V]. That is a
specific, cheap thing to check in our own aggregate construction.

### Media keys do not reach an aggregate device [V, general] [?, here]

`proxy-audio-device` has 1,055 stars for a driver that does only this, and
`MultiSoundChanger` has 328 and exists because *"native sound volume controller
can't change volume of aggregate devices"* [V]. Our own virtual device
publishes a volume control and it works. What is untested is whether F10–F12
move it while the aggregate is the default output.

Intercepting the media keys needs a `CGEventTap` and Accessibility permission.
Shipping this **without** requiring that permission would itself be worth
something.

---

## Next up

Ordered by what this project would gain, not by size.

### 1. AutoEq headphone correction [V] [effort: low]

Five vendors converged on this independently — SoundSource (*"powered by the
well-known AutoEq project… thousands of models"*, with JSON profile import and
per-app application), eqMac, Boom 3D, Sound Control, FineTune. A FineTune issue
about it reads *"would render other apps obsolete."* [V] The researcher called
it the highest ratio of demand to effort on the whole list.

The plan here is **documents, not a database**: parse AutoEq's own
`ParametricEQ.txt` export, the file people already download for their
headphones. Same argument as device profiles — a profile describes hardware, it
does not execute, and shipping thousands of them is a licensing and update
problem for a feature that works better when somebody drops in the file for
their exact unit.

Open question that has to be answered first, and it is the real work: **where in
the graph does it go?** Correction belongs on what *you* hear, not on what the
far end hears. The monitor path is currently routes with a gain and no
processing, so this needs either a per-route effect chain or an output-side
chain. Neither exists. Do not start the parser before this is decided.

### 2. Excluded applications [V] [effort: low]

SoundSource, FineTune and OnlyEQ all shipped an exclusion list *after* breakage
reports — Steam games, DAWs, Krisp, Roon, Bitwig [V]. Pure support-cost
reduction: its absence generates "your app broke Logic" tickets.

Note this project captures by inclusion — you pick the applications to tap —
which is already most of the protection. What is missing is a way to say "never
touch this one" that survives somebody selecting it by accident.

### 3. Quick Configs — one snapshot of the whole audio setup [V] [effort: low–medium]

Headline feature of SoundSource's paid 6.0 upgrade, promoted to its own menu bar
icon in 6.1 within eight months, which is a strong signal that people use it [V].

Distinct from the scene presets already here: those capture how to route, this
captures system-wide *device* state — what is default in and out, what the
per-application assignments are — so one click puts the whole machine back the
way it was for a podcast, a game, or a call.

### 4. Per-output latency trim [V via VoiceMeeter] [effort: low]

VoiceMeeter Banana publishes *"Gain/Delay per channel"* on every output bus [V].
Anybody running speakers and an interface at once has two paths that do not
arrive together, and there is nothing here to line them up.

The measurement already exists — the self-test recovers loopback delay from the
data — so the hard half is done.

### 5. MIDI learn [V via VoiceMeeter] [effort: medium]

VoiceMeeter maps *"Gain faders, Mute, Solo, M.C."* by a learn process [V]. This
project already has solo, which the same source calls out as worth mapping.

A Stream Deck is served by the URL scheme already shipped; MIDI is for anybody
with a physical fader, and a fader is a different thing from a button.

### 6. Named A/B buses [V via VoiceMeeter] [effort: low, mostly presentation]

The load-bearing idea in VoiceMeeter, and the general form of Elgato's "monitor
mix vs stream mix" [V]:

- **A buses are physical outputs** — what you hear.
- **B buses are virtual outputs** — what other applications capture when they
  open this as a microphone.

Every source carries independent assignment to every bus. Game audio to your
headphones but not to the stream; a co-host's return to the stream but not back
to themselves.

The routing matrix here can already express this. What is missing is the
*idiom*: named buses, each typed as a monitor path or a capture path, is far
more legible to a streamer than an abstract matrix. Our virtual driver gives us
the B-bus half for free, and it is the half that BlackHole-based setups make
painful.

### 7. A scripting surface [M] [effort: medium]

Audio Hijack's JavaScript API is the feature reviewers single out — Federico
Viticci called the Scripting tab *"the most important addition to Audio Hijack
4"*, Jason Snell *"the biggest new feature of all"* [M]. And the open goal:
**Loopback has no scripting, no AppleScript and no Shortcuts support at all**
[M].

`JavaScriptCore` ships with macOS, so the interpreter is free. The work is
designing a stable object model and event dispatch — and that is a promise about
compatibility, which is why this sits below the cheaper items rather than above
them.

### 8. Homebrew cask [V] [effort: low, but blocked]

FineTune's single highest-reacted issue is *"Add Homebrew Cask support"*, filed
two days after launch [V]. Blocked on the same thing distribution is blocked on:
the driver is ad-hoc signed and a cask wants something notarised.

### 9. KTV, further [proposal]

The singing side is started and not finished. What is missing: a connection to
Apple Music and to Spotify, and lyrics — the two obvious ones, and both are
their own frameworks rather than audio work.

### 10. Publish the bit-exactness result — **done**

`MEASUREMENT.md`: the method, the sequence, why it is 24 bits, how the delay is
recovered from the data, what the numbers beside it mean, and what the
measurement does not prove.

---

## Worth exploring first

Not ready to be planned. Each needs a spike that answers one question.

### Does macOS expose the AirPods high-quality recording option? [?]

macOS 26 has `AVAudioSessionCategoryOptions.bluetoothHighQualityRecording`, but
`AVAudioSession` is an iOS framework and **whether there is a CoreAudio
equivalent is unverified** [V that the iOS API exists; ? for macOS]. Half an
hour with the headers settles it.

If there is none, there is still a structural answer nobody packages well: the
aggregate can hold AirPods for output while a *different* device supplies the
microphone, so the codec never downgrades. SoundSource 6.0 shipped exactly that
[V]. The demand signal is the strongest the research found anywhere — a Show HN
for an app that does *only* this got 223 points and 309 comments, and at least
five projects exist for nothing else [V].

### Per-source and per-bus processing [V via VoiceMeeter]

VoiceMeeter publishes a full parametric EQ *per bus*, so the stream mix can be
EQ'd differently from the headphone mix [V]. Everything in this project's effect
chain is the microphone's voice chain by design.

This is the same architectural question as AutoEq above, and answering it once
unlocks both. It is a real change to the realtime path: today one chain runs
ahead of the routing matrix, and this needs chains hanging off routes or buses.
Worth a design pass on its own before any of it is built.

### A tap-only mode, with the driver as an opt-in [M]

Rogue Amoeba's ARK migration means Audio Hijack's capture now needs *"no need to
adjust your Mac's security settings, install anything, nor even enter your
administrator password"* [M]. Installing our driver restarts `coreaudiod` and
needs an admin password, which has gone from neutral to a liability.

Much of what this application does — taps, effects, recording, transcription,
monitoring — needs no driver at all. Whether that subset can be a first-class
mode, with the driver offered as the upgrade that buys the bit-exact clock-
locked path, is a product question as much as a technical one.

### VBAN network audio [V]

VB-Audio's own UDP protocol: eight input and eight output streams, an open
documented spec, unlike Dante, with an existing iOS remote app speaking it [V].
If network audio is ever interesting, this is the tractable target.

### Whether Elgato Wave Link 2.0 shipped on macOS [open]

The single highest-value unanswered question from the research: it decides
whether the dual-mix idiom in item 6 is already occupied on this platform or is
an open niche. Elgato's site blocked every automated fetch — 403 on the help
centre, 404 on the product page — so this needs a human with a browser.

---

## Settled — do not retry without new evidence

Each of these cost real time. The reasons are written up in `README.md`; this is
the index.

- **`AUAudioMix`** (macOS 26's graded speech/ambience separator, and on paper the
  most differentiating thing available on this platform) cannot run live. It
  refuses mono and stereo input, wants five channels out, and needs
  `kAUAudioMixProperty_SpatialAudioMixMetadata` — capture-time metadata a camera
  writes into a Cinematic asset and a microphone cannot provide. All three
  constraints are asserted in the tests, so a future macOS relaxing any of them
  will be noticed. It may still be worth having as an **offline** pass over
  recorded stems, which is the one use the measurements do not rule out.
- **MLX** cannot build its Metal shaders under SwiftPM, and does not fall back to
  the CPU — it fails to load its metallib and takes the process down. Separately,
  a 2048-point transform is a size where launch and synchronisation cost more
  than the arithmetic. MLX earns its place when there is a trained model to run.
- **App Intents** compile and run and never appear anywhere: the entries in a
  Shortcuts library are discovered from metadata Xcode's own build phase
  extracts, and an application assembled by a shell script around a SwiftPM
  binary produces none. The URL scheme is the answer until the build system
  changes.
- **`onOpenURL` and `application(_:open:)`** never fire in a menu bar accessory
  with no window, and `open` still reports success. The Apple Event handler
  underneath both is what works.
- **Real-time neural voice conversion** (fish-speech, RVC) needs well over a
  hundred milliseconds against a 2.7 ms deadline. Every real-time voice changer
  that ships does what this one does; this one says so.

---

## The competitive picture, as of the research

Kept because it is the reason several items above are ranked where they are.

**The clock is running faster than it looks [V].** SoundSource 6.0 shipped
3 Dec 2025 and 6.1 on 21 Jul 2026. Between them: Output Groups, Quick Configs,
Preferred Device Order, per-app Headphone EQ, Timed Mute, Balance & Pan, cough
buttons, Recent Noise Indicator, forced software volume control, "Prevent Sound
Quality Issues with AirPods and Other Bluetooth Devices", and no drift
correction on Bluetooth. That list is most of what the research was going to
recommend, shipped in eight months.

**FineTune** launched Jan 2026, free and GPLv3, 8,317 stars and 142 open issues
[V]. **SoundPipe** undercuts Loopback tenfold at $10 [V].

**Pricing, from their own buy pages [V]:** Audio Hijack $69 + Loopback $99 +
SoundSource $49 + Airfoil $35 + Farrago $55 = **$307**. This project already
covers pieces of three. The loudest complaint found was the cost of the *stack*,
not of any single one.

**Coverage gap, stated rather than papered over:** the streamer cluster (Elgato
Wave Link, RØDE Connect/UNIFY, VoiceMeeter) and the OBS/Krisp/REAPER cluster
never reported. What is here on those came from single searches and is thinner
than the rest.
