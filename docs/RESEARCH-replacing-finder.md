# Replacing Finder

Tested on macOS 15 (Darwin 25.4), SIP enabled, 20 August 2026. Every result
below was measured on a real machine, not read from documentation.

## What was assumed, and what is true

The plan was to make Soquel the default handler for `public.folder` and let
LaunchServices do the work. That does not work, and everything else follows
from it.

| Claim | Result |
| --- | --- |
| `public.folder` can be reassigned | **False.** `LSSetDefaultRoleHandlerForContentType` returns −50 for every role mask, from a signed app bundle as well as a plain binary |
| Other content types can be reassigned | True. `public.plain-text` and `public.volume` both returned 0 and took effect |
| Finder respawns whatever you do | **False.** It respawns only after an *unsuccessful* exit |
| A Finder launch can be caught | True, in 27 ms, with no permission of any kind |
| Reading what Finder is showing is free | **False.** It needs Automation permission, and blocks until the prompt is answered |

## Why the handler route fails

    public.plain-text: set(app.soquel.Soquel) -> 0
    public.volume:     set(com.apple.finder)  -> 0
    public.folder:     set(app.soquel.Soquel) -> -50

The API works. `public.folder` specifically is refused. The refusal is not
about signing or bundle identity: the same call from inside a code-signed
`.app` with its own bundle identifier returns the same −50.

Soquel already declares `CFBundleTypeRole: Viewer` over `public.folder`,
`public.directory`, `com.apple.bundle` and `public.volume` at
`LSHandlerRank: Alternate`, and already appears in the handler list that
LaunchServices reports for `public.folder`. Being listed is allowed. Being
default is not.

`public.volume` is a useful exception and is worth keeping: mounting a disk
can open Soquel, and that needs no interception at all.

## Why the launch route works

`/System/Library/LaunchAgents/com.apple.Finder.plist`:

    "RunAtLoad" => false
    "KeepAlive" => { "SuccessfulExit" => false, "AfterInitialDemand" => true }

`SuccessfulExit: false` means launchd restarts Finder only when it exits
badly. A quit AppleEvent is a clean exit. Measured: Finder quit with
`tell application "Finder" to quit` stayed dead for the full 12 seconds it was
watched, with no respawn. `killall Finder` is an unclean exit and comes back
in one second — `ThrottleInterval` is 1.

So Finder is not a process that cannot be stopped. It is a process that comes
back when something asks for it, and the asking is observable:

    1787287409.637  watcher up
    1787287411.641  FINDER LAUNCHED pid=30328
    1787287411.668  terminate() returned true
    1787287414.818  finder still running? false

27 ms from launch to termination request. `NSRunningApplication.terminate()`
does this with no Automation permission and no AppleEvent of our own.

This is the whole mechanism. The Dock's Finder tile cannot be removed — it is
not in `persistent-apps` and is drawn by the Dock itself — but the tile only
*launches Finder*, and a launch can be caught. The tile stays; what it lands
on does not have to.

## The one thing that costs a permission

Catching the launch is free. Knowing *what* Finder was asked to show is not.

A reveal from another application — `NSWorkspace.activateFileViewerSelecting`,
or `open -R` — launches Finder with a selection. Reading that selection means
asking Finder, and asking Finder means Automation permission.

The test that proved it also showed the trap. `NSAppleScript.executeAndReturnError`
called on the main thread before the permission is granted **blocks until the
prompt is answered**. The watcher logged the launch and then stopped dead:

    1787287461.776  watcher2 up
    1787287463.663  FINDER LAUNCHED pid=30609
    (nothing further — the main thread was blocked on the TCC prompt)

Every AppleEvent on the machine was blocked for as long as it hung, including
unrelated `osascript` calls from other processes.

Consequences for the implementation, all mandatory:

- The AppleScript must never run on the main thread.
- It must have a timeout, and a timeout must be treated as "not permitted".
- Permission must be asked for deliberately, from a button, not incidentally
  on the first reveal.
- `NSAppleEventsUsageDescription` must be in `Info.plist`. Soquel has none
  today, and without it the prompt does not appear at all — the call just
  fails.

## What can be offered

| Switch | Mechanism | Permission |
| --- | --- | --- |
| Open a disk in Soquel | `public.volume` default handler | none |
| Catch the Dock's Finder icon | launch observer, then terminate | none |
| Open the same folder Finder would have | launch observer, read target | Automation |
| Catch "Reveal in Finder" | launch observer, read selection | Automation |
| Hide desktop icons | `com.apple.finder CreateDesktop false` | none |

The first two need nothing and cover the common case. The middle two turn
"Finder flashed and vanished" into "Soquel opened where Finder was going",
and that is what the permission buys.

## What remains impossible

- The Dock's Finder tile. Not in `persistent-apps`, drawn by the Dock, not
  removable without disabling SIP.
- `public.folder` as a default handler, as above.
- Trash's "Put Back", which is Finder-owned metadata.

Every one of these is a presentation problem rather than a capability problem,
except Put Back, which is a real gap.

## Honest limits of this test

- Finder's death was watched for 12 seconds, not for a login session.
- The reveal path was never seen working end to end, because the permission
  prompt blocked it. What is proven is that the prompt is the only obstacle
  and where it must not be triggered from.
- Nothing was left changed. Handlers were diffed against a baseline captured
  before the first write and are identical.
