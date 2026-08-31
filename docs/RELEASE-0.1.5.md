# YunAudio 0.1.5

## The player is installed; the permission question never came back

On macOS 27 build 26A5421a, asking
`AEDeterminePermissionToAutomateTarget` about a running Spotify 1.2.98.301
never returned. YunAudio put that permission preflight in two places: the scan
which decided whether Music and Spotify were installed, and every current-song
poll. One stuck answer therefore produced both visible symptoms: the settings
panel claimed neither player was installed, and synchronised words stopped
following Spotify.

Installation discovery no longer asks TCC anything. It has a measured ceiling
of ten system calls for eight candidates, down from eighteen, and publishes the
applications it found without waiting for an unrelated permission answer.
Current-song reads send the real Apple event and interpret its real error; an
explicit permission request sends the smallest real event the feature uses.

Measured on the affected machine, the candidate build found the running
Spotify, read the track, artwork, duration and position, and drew synchronised
words on the KTV stage. A sample of both worker queues contained repeated real
`NSAppleScript` reads and zero calls to the preflight which had occupied both
queues indefinitely.

## What else changed

**Closing the window leaves the route alone.** YunAudio is a menu-bar utility,
but SwiftUI's default terminated it when its last window closed. The process,
route and status item now remain, and the same window can be opened again.

**A route recovers after sleep.** The model records the cycle counter before
sleep and reads it two seconds after wake. A route whose counter moved is left
alone; one whose counter stopped is rebuilt after the device list refreshes.

**Faults are visible while the window is closed.** A stopped route, repeated
missed deadlines or a start which Core Audio never answers now leaves one
Notification Centre item per fault and route session. Delivery is recorded only
after the centre accepts it, and a late answer from an old route cannot silence
the new one.

**NetEase's timestamp suffix is understood.** Files using stamps such as
`[00:00.00-1]` retain their timing. Credit-only responses no longer become a
song's words, stale cached responses pass through the same filter as fresh
network answers, stanza breaks survive, `[Verse]` headings survive, and an
ordinary line beginning with “Open” is no longer mistaken for an `OP` credit.
Music's own lyrics field goes through the same cleanup.

**The window controls are in front of the window again.** The full-size SwiftUI
hosting view could cover the three AppKit traffic-light buttons. Their title-bar
container is now raised after SwiftUI has settled the hierarchy, and the live
flow check asserts the frames and stacking order.

**Two published contracts now match the code.** MCP scripts have a 250 ms
execution limit, not two seconds, and the virtual device supports rates through
96 kHz, not 192 kHz. Tests hold both statements to their implementations.

## Upgrading

Replace the application. The virtual audio device is unchanged and does not
need reinstalling.

This release is signed ad-hoc rather than notarised. On another Mac, Gatekeeper
may refuse the first launch; `READ ME FIRST.txt` in the disk image gives the
System Settings steps for opening it.

## Still under observation

The fixes for long-session route loss, KTV dropout and audio-server degradation
remain under real-use observation in issues #9–#11. Intermittent Bluetooth
silence remains open as #14. This release does not claim those reports are all
closed; it ships the fixes and measurements already established rather than
holding the current-player repair behind them.

## Release evidence

To be recorded on the tagged shipping commit.
