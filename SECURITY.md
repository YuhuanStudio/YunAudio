# Security

## Reporting a vulnerability

Please report privately rather than in a public issue: use GitHub's **Report a
vulnerability** button under the Security tab, or email huhu11256@gmail.com.

You should get an acknowledgement within a few days. This is a project
maintained by one person, so please allow reasonable time before disclosing.

## What is worth reporting

This project has a larger blast radius than most audio software, and these are
the parts that matter:

- **The virtual audio device** is an `AudioServerPlugIn` loaded into
  `coreaudiod`, which runs outside this application and carries every other
  application's audio. A fault there takes system audio down with it. Memory
  safety, buffer handling and anything reachable from the HAL are the sharp
  edges.
- **The control socket** is `chmod 600` in the user's own directory and drives
  the router. Anything that widens who can reach it, or what can be asked
  through it, is a real finding.
- **The scripting interface** runs user JavaScript in `JavaScriptCore` with an
  execution time limit. A way out of that, or a way to reach beyond the
  documented vocabulary, is worth reporting.
- **Lyrics come from public services over the network.** A response that can
  make the application do something other than display words — a path traversal
  through a cached file name, say — counts.

## What is already known and stated

These are documented rather than accidental, and reports about them will be
closed with a pointer here:

- **The application and driver are ad-hoc signed.** macOS refuses the first
  launch and says the developer cannot be verified. Distribution without that
  dialog needs a Developer ID and notarisation, which this project does not
  have.
- **A driver fault takes `coreaudiod` down**, along with all system audio. The
  removal command is in the README for exactly this reason.
- **Voice isolation breaks the realtime contract** — Apple's model allocates on
  the IO thread, about 0.3 times per cycle. Measured, stated in
  `docs/limits.md`, and off by default.

## Scope

Only the code in this repository. Reports about macOS itself, or about
third-party Audio Units loaded into it, belong with their authors.
