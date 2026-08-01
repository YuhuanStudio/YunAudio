# Releasing

A release is a tag, a disk image built from that tag, and a page saying what
changed. Every step of it happens on a machine somebody owns, and that is
deliberate.

**There is no CI, and there was.** Four jobs on `macos-15` runners, which bill
at ten times a Linux minute — and they failed on every push, because a hosted
runner carries neither the Swift 6.2 toolchain nor the macOS 27 SDK this project
needs. `error: package 'yunaudio' is using Swift tools version 6.2.0 but the
installed version is 6.1.0`, three commits in a row, at macOS rates. A check
that cannot run is not a check; it is a bill.

What it was trying to do is worth keeping, and `./App/verify.sh` already does
all of it and more, on a machine with the SDK and real audio hardware — which is
the other half of the argument, because half of what matters here cannot be
tested on a runner with no devices to enumerate.

## Before

```bash
./App/verify.sh --full --fresh
```

Everything, including the flow check against real hardware and a clean clone
built from nothing. A run that skips a step says so; read what it skipped.

## The tag

The version comes from the tag, so the tag is the decision:

```bash
git tag -a v0.2.0 -m "What this release is for, in a sentence"
git push origin v0.2.0
```

`package.sh` reads it with `git describe`. Building from an untagged tree
produces `0.1.0-3-gabc1234` rather than a version that claims to be a release —
which is the point, because a disk image with no traceable commit is a disk
image nobody can debug a report against.

## The image

```bash
./package.sh              # build/YunAudio-<version>.dmg
./package.sh --notarize   # and submit it to Apple
```

Without a Developer ID identity in the keychain the image is still built and
still installs on the machine that built it, but Gatekeeper refuses it
elsewhere. The script says so plainly instead of producing something that looks
shippable and is not. `READ ME FIRST.txt` inside the image tells whoever
receives it the same thing, and how to get past it.

## The page

```bash
gh release create v0.2.0 build/YunAudio-*.dmg \
  --title "v0.2.0 — <what it is for>" --notes-file notes.md
```

What belongs in the notes, in this order: what somebody can now do that they
could not, what changed under them, and what is still broken. The last of those
is not optional — `TODO.md` and `docs/limits.md` are in this repository because
a limitation somebody discovers themselves costs more than one they were told
about.

## Afterwards

Check the download actually opens on a machine that did not build it. A locally
built binary carries no quarantine attribute and an image from the internet
does, so the first launch is a different experience from every test of it.
