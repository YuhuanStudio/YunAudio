# Contributing

Thank you for looking. Two things are worth knowing before you spend time on a
change, because they are unusual and they decide whether a patch can be merged.

## A change is done when something measures it

Nearly every real defect in this project was already shipping and already looked
fine. A signal path that resamples silently, a knob that moves a number and not
the audio, a screenshot that had never shown the branch a user actually sees —
none of those are visible by reading. So a change needs evidence of the kind the
change is about: a test for logic, a number for performance, a photograph for
layout, a flow-check section for anything that touches real devices.

"It compiles" and "it looks right on my machine" are the two claims this
project has been wrong about most often.

## Some things need a human

Installing the virtual device restarts `coreaudiod` and stops all system audio;
writing to a microphone's light ring speaks to real hardware over HID. Nothing
automated does either. If your change needs one, print the command and say why —
do not run it for somebody.

## Getting set up

```bash
source ./App/toolchain.sh     # or the build fails with a confusing SDK error
swift build && swift test
```

`toolchain.sh` matters: the default Xcode may carry an older SDK, and the error
that produces reads like a typo rather than a missing toolchain.

## Before opening a pull request

```bash
./App/verify.sh                       # everything that needs no audio hardware
./App/verify.sh --full                # and the flow check, which takes the devices
"$(xcrun --find swift-format)" lint --recursive Sources Tests
"$(xcrun --find swift-format)" format --in-place --recursive Sources Tests
```

`swift-format` ships inside the Xcode toolchain rather than on `PATH`, hence
`xcrun`. A run that skips a step says so in its summary; read what it skipped
before trusting a green line.

There is no CI. `verify.sh` is what a hosted runner would have been, except it
has the SDK and real audio devices, which a hosted runner does not.

## House style

- **Comments say why**, not what. The code already says what.
- **Prose is British English.** Code, comments and commit messages included.
- **Numbers, not adjectives.** "0.42% of one core, measured over six minutes"
  rather than "fast".
- Commit messages are a sentence about what was wrong and what the evidence was.
  `git log` is the design record; please add to it rather than writing "fix bug".

## The longer version

**[AGENTS.md](AGENTS.md)** is the full working agreement: the invariants that
must not be broken, why the four interface checks are each blind to what the
others catch, and the approaches already measured and rejected — worth reading
before proposing one of them again.

**[TODO.md](TODO.md)** is what to do next, with the evidence behind each item,
and **[docs/limits.md](docs/limits.md)** is what does not work and why.
