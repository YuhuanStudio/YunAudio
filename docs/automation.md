# Automation

Every interface below drives the same running application through the same
vocabulary. `Sources/YunAudioControl` defines it once; the window, the command
line, the MCP server and a script are four front ends onto it.

← [README](../README.md)

English · [繁體中文](zh-Hant/automation.md) · [简体中文](zh-Hans/automation.md)

## Remote control

Anything that can open a URL can drive this: Shortcuts, Stream Deck, Keyboard
Maestro, AppleScript, `open` from a terminal.

```bash
open "yunaudio://routing/start"     # also /stop and /toggle
open "yunaudio://mute/on"           # also /off, and bare for toggle
open "yunaudio://record/toggle"
open "yunaudio://transcript/start"
open "yunaudio://preset/Voice%20call"
```

A bare noun toggles, because that is what a physical button wants; anything
driven by a script should prefer the definite form, which is idempotent —
`mute/on` twice is muted, not unmuted. An unrecognised verb is refused rather
than guessed at, since the failure mode being avoided is a mistyped mute that
turns into a stop.

### From a terminal

The same verbs, with an answer coming back — which is the part a URL cannot do.
`yunaudio-cli` talks to the copy of the application that is already running
rather than opening any hardware itself.

```bash
yunaudio-cli status                  # what it is doing, one fact per line
yunaudio-cli start                   # also stop, toggle
yunaudio-cli mute on                 # also off, and bare for toggle
yunaudio-cli record off
yunaudio-cli transcribe on
yunaudio-cli preset Voice call       # no quotes needed; a name is joined
yunaudio-cli config Podcast
yunaudio-cli script "yun.mute(true); yun.log(yun.status().running)"
yunaudio-cli mute --url              # print the URL instead of sending it
```

`status` prints what a script sees through `yun.status()`, plus the scenes and
setups that exist. Naming one that does not gets the list of ones that do, which
is more use than "not found". A command that could not be carried out exits 1
and a line the tool could not parse exits 2, so a shell script can tell the
difference between "the application refused" and "you typed it wrong".

It reaches the application over the same Unix socket the MCP server uses, at
`~/Library/Application Support/YunAudio/control.sock`. That is why "YunAudio is
not running" comes back in milliseconds rather than after a timeout: nothing
listening is `connect` failing, which is an answer, not a silence to wait out.

`status` deliberately is not one of the verbs a URL or a MIDI note can send:
asking what is happening must not be able to change it. Everything else is one
vocabulary — `RemoteCommand` — with four front ends, so a verb added once is
available from a URL, a pad, a line of JavaScript and a shell.

`record` here means the application's recorder. The measuring verb that captures
a few seconds of the routed signal to a file is `capture`.

Not App Intents, and not for want of trying: the entries in a Shortcuts library
are discovered from metadata Xcode's own build phase extracts, and an
application assembled by a shell script around a SwiftPM binary produces none.
They would have compiled, run, and never appeared anywhere anybody could use
them.

## Driving it from an agent — MCP

`yunaudio-mcp` is a Model Context Protocol server: JSON-RPC 2.0 over stdio, no
dependencies, spawned by whatever client you point at it.

```bash
swift build -c release            # produces .build/release/yunaudio-mcp
claude mcp add yunaudio -- "$PWD/.build/release/yunaudio-mcp"
```

Or, for a client configured by file — Claude Desktop, Zed, anything else that
reads the same shape:

```json
{
  "mcpServers": {
    "yunaudio": { "command": "/absolute/path/to/yunaudio-mcp", "args": [] }
  }
}
```

Nine tools: `yunaudio_status`, `yunaudio_list_names`, `yunaudio_routing`,
`yunaudio_mute`, `yunaudio_record`, `yunaudio_transcribe`,
`yunaudio_apply_scene`, `yunaudio_apply_setup` and `yunaudio_run_script` — the
same vocabulary as the URL scheme, because it is the same `RemoteCommand`
underneath. Names are the user's own and some are translated, so
`yunaudio_list_names` is the one to call before applying a scene by name.

**YunAudio has to be running.** The server holds no state and knows nothing on
its own: it forwards to the application over a Unix domain socket at
`~/Library/Application Support/YunAudio/control.sock`, which the application
creates on launch, removes on quit, and leaves readable only by its owner. If
nothing is listening, every tool answers with that immediately rather than
waiting. `--socket <path>` and `$YUNAUDIO_CONTROL_SOCKET` move it.

A socket rather than the URL scheme, because a URL is one-way. `open
yunaudio://mute/on` returns as soon as Launch Services has taken the event: it
cannot say whether the microphone is now muted, whether the scene existed, or
whether anything was there to hear it. That is fine for a Stream Deck key, where
a person is looking at the result, and useless for an agent, where nobody is —
and reading the state back is half of what an agent is for.

## Talking to OBS

Settings → Streaming connects to `obs-websocket` v5, which has shipped inside
OBS since version 28. Two things go across it, and the second is the reason the
first exists.

**Muting the microphone here mutes OBS's copy of it**, if you ask it to. OBS's
own mute for the same source is a separate switch on a separate window, and the
failure that produces is the one nobody notices in time.

**The sync offset.** Everything this application produces reaches OBS later than
the picture does, by exactly as much as the effect chain adds — voice isolation
alone is 56 ms. OBS has a per-source field for that and no way of working out
what belongs in it. This does, to the frame, and until now only displayed it.
2688 frames at 48 kHz becomes −56 ms, rounded to whole milliseconds because
OBS's own dialog is a whole-millisecond spin box.

Two things worth saying plainly:

- **`obs-websocket` is switched off by default**, so the first thing most people
  meet is a refused connection. That is answered here with the menu path rather
  than with a status code: Tools → WebSocket Server Settings.
- **This has not been verified against OBS.** The authentication is checked
  against the vector in obs-websocket's protocol document, and the whole
  handshake is checked over a real socket against a stub server that answers the
  way that document describes — but OBS is not installed on the machine this was
  written on, and a stub cannot be evidence about a program it is imitating.
  `RESEARCH.md` says what running it against the real thing would take.

Not built, and it is a decision rather than a gap: no native OBS plugin
(the websocket does everything needed and a plugin binds this to OBS's build
and ABI), no browser-source overlay yet, and no six-track recording model —
`MAX_AUDIO_MIXES` is a compile-time constant in libobs, which makes six somebody
else's muxer limit rather than a shape worth copying.

### A capture that survives the application restarting

OBS's issue #9144 — "Application Capture loses audio when application reopens on
macOS" — has been open since June 2023, and OBS's answer to it is a button in the
source properties labelled "Restart capture".

macOS 26 added `CATapDescription.bundleIDs`, and this application sets it, so a
captured application that quits and comes back reattaches on its own. Measuring
that turned up something worth knowing: the neighbouring
`processRestoreEnabled` flag **defaults to true**, so it had always been on and
had always restored nothing, because there were no bundle identifiers to restore
by. Setting the flag alone would have been a change with no effect that read
exactly like a fix.

```bash
swift run -c release yunaudio-cli tap-restore Spotify           # what the HAL kept
swift run -c release yunaudio-cli tap-restore Spotify --watch   # quit it and watch
```

