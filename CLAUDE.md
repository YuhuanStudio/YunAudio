# CLAUDE.md

The working agreement for this project lives in **[AGENTS.md](AGENTS.md)** —
one file, so that every agent and every person is reading the same thing rather
than two copies that drift apart. Read it before changing anything.

The short version, none of which is a substitute for reading it:

- **Assert a number.** Nearly every real defect here was already shipping and
  already looked fine. A change is done when something measures it, not when it
  compiles.
- **Source `./App/toolchain.sh`** before a hand-run `swift build` / `swift test`.
  The default Xcode may carry a macOS 26 SDK, and the resulting error reads like
  a typo.
- **Verify the interface four ways** — flow check, offscreen render, real
  screenshot, string scan — plus `./App/build-app.sh --verify`. Each is blind to
  what the others catch.
- **The realtime path allocates nothing.** Measure release builds; debug builds
  allocate from Swift's own checking machinery.
- **Installing the driver and writing to the microphone's light ring need a
  human.** Print the command; do not run it.
- **Comments say why, prose is British English, reports to the user are in
  Chinese.**

`README.md` is for people evaluating or using the project; `AGENTS.md` is for
people changing it; **[TODO.md](TODO.md)** is what to change next and what has
already been ruled out.
