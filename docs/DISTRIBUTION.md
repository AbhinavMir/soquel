# Shipping Soquel

Soquel is MIT licensed and free. There is no licence key, no trial, no activation, and no check of
any kind — the application never asks who you are, because it never asks anyone anything.

If it is worth money to you, there is a link to pay. If it is not, or you cannot, use it anyway.

That decision closes a question that would otherwise shape the whole product, so the rest of this
file is about the two things still worth getting right: making the download open without a fight,
and why the Mac App Store is not the channel.

## Making the download open cleanly

Done as of 1.0.1. The application is signed with a Developer ID Application certificate under
the hardened runtime, the disk image is notarised by Apple, and the ticket is stapled to it. A
first launch is an ordinary double-click: no right-click, no warning, and no network needed for
the Gatekeeper check.

- `scripts/build-app.sh` signs the bundle. It picks the identity up from the keychain, or from
  `SOQUEL_IDENTITY`.
- `scripts/notarise.sh` builds the image if it is missing, submits it, waits, staples the ticket
  and validates the result. Credentials live in a keychain profile — `xcrun notarytool
  store-credentials soquel` — so no password is ever in a file or in shell history.

**Never re-sign after copying.** `scripts/install.sh` used to run `codesign --force -s -` on the
copy in `/Applications`, which replaced the Developer ID signature with an ad-hoc one. Signing
ad-hoc over the top changes the code identity, and macOS keys the Full Disk Access grant to that
identity — so every install silently revoked the permission that Developer ID signing was adopted
to preserve. `cp -R` keeps the signature intact. Verify it, never replace it.

Still outstanding:

- **Universal binary.** `scripts/build-app.sh` runs `swift build -c release`, which builds for the
  machine it runs on, so the shipped image is arm64. Covering Intel too would need
  `swift build --arch arm64 --arch x86_64` and `lipo`. Deliberately not done — the landing page
  says Apple silicon.

## Taking money without asking for it

The download is not gated and never will be. It sits on GitHub Releases, which is free, fast, and
already where the source is. Paying is a link beside it, nothing more: it happens in a browser,
and the application knows nothing about it. No "have you paid" prompt, no supporter build, no nag
on the tenth launch.

The address is on [trysoquel.com](https://trysoquel.com). ETH, USDC or USDT on Ethereum.

## Why not the Mac App Store

Free would not change this. Every app in the store must run in the App Sandbox, and the sandbox
breaks five things Soquel is made of.

### 1. Browsing anywhere

A sandboxed app reads what the user hands it through an Open panel, and what it has kept a
security-scoped bookmark for. Nothing else.

Soquel navigates to `/` (`MainWindowController.swift:524`), searches from `/` (`Search.swift:183`),
lists `/Applications`, and walks into other users' home folders. In a sandbox each of those is a
folder the user must locate in a panel first. A file manager whose answer to "show me /usr/local"
is "please find it for me" is not the same product.

Apple publishes an escape hatch — `com.apple.security.temporary-exception.files.absolute-path.read-write`
— and its own documentation says to file a bug report justifying it. Developers report temporary
exceptions being rejected on sight.

### 2. Running other programs

| File | Runs | For |
| --- | --- | --- |
| `GitStatus.swift` | `git` | the status column and badges |
| `Archives.swift` | `unzip`, `tar` | looking inside archives |
| `RemoteLocations.swift` | `sshfs` | SFTP |

A sandboxed child inherits the sandbox, and the store's guidance is that apps are self-contained.
Commander One, which ships both a sandboxed store build and a direct one, documents its store
build as unable to start command-line apps at all.

Git and archives could be rewritten against libgit2 and libarchive, linked in. `sshfs` cannot: it
needs macFUSE, which is a kernel extension (issue #4).

### 3. Mounting servers

`RemoteLocations.swift:174` calls `NetFSMountURLSync`. Sandboxed apps fail to mount with it, and
Full Disk Access does not rescue them. Connect to Server does not survive in any form.

### 4. Seeing the whole disk

The disk map is only interesting pointed at a volume, which needs Full Disk Access — not something
a sandboxed app can meaningfully hold. Sandboxed, it measures folders already granted. Useful, but
not the feature.

### 5. Changing the default application for a file type

The Applications settings pane changes a system-wide Launch Services handler. Reaching outside
your container to change a system setting is what the sandbox exists to prevent.

### What would survive

Dual panes and nested splits · tabs · list, icon and column views · sorting and auto-sized
columns · thumbnails · the preview panel · rename, copy, move, trash, undo · the transfer queue ·
conflict handling and folder merge · batch rename · the shelf · folder compare · search and saved
searches · the command palette · every shortcut and the vi preset · theming and `settings.json` ·
workspaces · logging.

Most of the list, and not the part that makes it worth replacing Finder with. A store build would
have to be presented as a deliberately smaller thing, with its limits on the listing — not a copy
of this one with the interesting parts removed.

## Sources

- [Enabling App Sandbox](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html) — sandbox required for the store; user-selected and bookmark entitlements
- [App Sandbox Temporary Exception Entitlements](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html) — absolute-path exceptions and the duty to justify them
- [Requesting temporary entitlement exceptions](https://developer.apple.com/forums/thread/663311) — developers reporting them rejected
- [Mounting an external disk from a sandboxed app](https://developer.apple.com/forums/thread/775835) and [Issues Mounting WebDAV Shares with NetFSMountURLAsync](https://developer.apple.com/forums/thread/773701) — NetFS under the sandbox
- [Granting full-disk access to my sandboxed app not working](https://developer.apple.com/forums/thread/124895) — Full Disk Access and the sandbox
- [Mac file-manager comparison](https://tokie.is/blog/mac-file-manager-showdown-mid-2025-commander-one-forklift-path-finder-houdahspot-cyberduck-compared) — Commander One's store build; ForkLift on both channels
