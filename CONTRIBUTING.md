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
./ci/no-hardware.sh build && ./ci/no-hardware.sh test
```

`toolchain.sh` matters: the default Xcode may carry an older SDK, and the error
that produces reads like a typo rather than a missing toolchain.

The wrapper excludes eight reviewed live-HAL tests. Raw `swift test` is also
safe by default: those cases remain visible but are disabled unless
`YUNAUDIO_LIVE_HAL_TESTS=1` explicitly puts the machine's audio state in scope.

## Before opening a pull request

```bash
./ci/no-hardware.sh all               # deterministic checks, no live HAL
./App/verify.sh                        # UI gate, no live HAL
./App/verify.sh --full                 # adds eight live-HAL tests and real routing
"$(xcrun --find swift-format)" lint --strict --recursive Sources Tests
"$(xcrun --find swift-format)" format --in-place --recursive Sources Tests
```

`swift-format` ships inside the Xcode toolchain rather than on `PATH`, hence
`xcrun`. A run that skips a step says so in its summary; read what it skipped
before trusting a green line.

The [no-hardware CI](docs/ci.md) repeats the deterministic checks on explicitly
labelled self-hosted macOS 26, macOS 27 and next-beta runners. It deliberately
does not start routes or own audio devices. `verify.sh --full` and the lifecycle
matrix still require a human-authorised isolated machine; a green CI run is not
evidence that system audio recovered.

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

The issue tracker is what to do next. **[docs/limits.md](docs/limits.md)** is
what does not work and why — including the approaches already measured and
rejected, so that a good idea is not proposed for the third time.
