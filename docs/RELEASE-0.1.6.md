# YunAudio 0.1.6

## The application can tell you when it is old

YunAudio now checks for updates itself. The status menu and About settings both
offer **Check for Updates…**; Sparkle asks on the second ordinary launch whether
daily automatic checks are wanted and remembers the answer. Render, screenshot,
bundle and flow evidence start zero updater owners and make no network request.

This is not a link wrapped around a version number. The update feed is signed,
the archive has its own Ed25519 signature, and extraction is refused until that
signature has been checked. The acceptance gate runs the assembled application
against the real feed twice: the signed document is accepted; the same-length
document with one changed byte is rejected by Sparkle itself.

Installing an update still follows YunAudio's ordinary Quit path. Any running
route, recorder, player, script and control socket therefore reaches its existing
bounded teardown fence before Sparkle may replace and relaunch the application.

## Installation is one command now

The public `YuhuanStudio/homebrew-tap` carries a tested cask:

```bash
brew install --cask yuhuanstudio/tap/yunaudio
```

and later:

```bash
brew upgrade --cask yunaudio
```

The cask moves only the application into Applications. It does not ask for
administrator access, install the optional virtual device or restart system
audio. The driver remains embedded in the app; About settings installs or
removes it only after an explicit action and the standard administrator prompt.

The DMG remains available. An app running from a read-only image, App
Translocation, Downloads or another folder says why it should be moved to
Applications before an in-place update.

## A useful problem report starts with identity, not private data

About settings now opens a GitHub issue prefilled with the YunAudio version,
build and macOS build. Device names, routes, microphone state, song titles and
diagnostics are deliberately absent; the person filing the report decides what
else belongs there.

## The limit imposed by having no paid Apple account

This release is still ad-hoc signed and not notarised. The first launch can still
require **Open Anyway**, and replacing the binary can make macOS ask for
microphone or Automation access again because an ad-hoc code requirement is the
binary's changing hash rather than a stable developer identity.

Sparkle is independently authenticated with the public Ed25519 key sealed into
the app. An ad-hoc host has no Apple Team ID for Library Validation to compare
with the separately signed Sparkle framework, so the app carries
`disable-library-validation`. That security exception, its reason and the
condition for removing it are asserted in the suite and recorded in
`docs/limits.md`; it is not presented as equivalent to Developer ID signing.

## Upgrading

Replace the application, or use the Homebrew command above. The virtual audio
device is unchanged and does not need reinstalling.

## Release evidence

`./App/verify.sh --full` on the release candidate:

    build…                          ok
    strict formatting…              ok
    tests…                          ok
    strings…                        ok
    app bundle…                     ok
    signed update feed…             ok
    settings entry…                 ok
    offscreen render…               ok
    photograph the real window…     ok
    installed driver matches release…ok
    audio can start at all…         ok
    the path is bit-exact, release… ok
    flow check…                     ok

The signed-feed gate runs Sparkle itself against two documents served by a
loopback HTTP server. The real feed returns `ok`; replacing one byte while
keeping its length unchanged returns `SUSparkleErrorDomain` and “EdDSA signature
does not match”. Independently, CryptoKit verifies the feed's 64-byte signature
over its exact signed byte count using the public key embedded in Info.plist.

The app bundle was then moved away from `.build`, its nested signature was
verified with `codesign --deep --strict`, and an ordinary production launch
loaded Sparkle successfully under the declared Library Validation exception.

`./App/verify.sh --fresh` also passed: a clean clone resolved Sparkle 2.9.6,
built the app and test bundle with no access to this working tree's artifact
cache, and completed every deterministic test and bundle check.

The final 0.1.6 Homebrew cask passed `brew style`, `brew audit`, `brew fetch`
and `brew livecheck`. It was installed into a temporary application directory,
reported version 0.1.6 build 7, carried both Sparkle and the embedded driver,
passed deep code-signature verification, and was uninstalled without touching
`/Applications/YunAudio.app`.
