# Releasing

A release is a tag, a disk image built from that tag, and a page saying what
changed. There is no build server: GitHub's macOS runners do not carry the
macOS 27 SDK this project needs, so the image is built on a machine that has
one, and that is stated here rather than pretended away.

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
