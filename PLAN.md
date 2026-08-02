# Working state

Branch: `main`, clean and pushed. 596 tests pass in 13.5s.

**1.0.1 is shipped.** Signed with a Developer ID, notarised, disk image on the GitHub
release, landing page live at trysoquel.com.

## What this is

Soquel, a file manager for macOS. The adversarial bug sweep that this file used to track
is finished: all 38 issues it raised are closed. What remains are three feature issues,
none of them started.

## Shipped

- **1.0.0 → 1.0.1.** Developer ID signing, so a granted permission survives an update.
  Notarised, so the first launch is an ordinary double-click with no right-click and no
  warning. Disk image laid out rather than left to Finder. First-launch window says what
  to grant and why.
- **The bug sweep, all 38 issues.** 7 data loss, then wrong result, then UI. The detail
  is in the commits `c6fa729`, `7c896de`, `3dface9`, `a260895`, `24ae20a` and
  `b74bd2b` ("Fix the last fifteen bugs from the sweep").
- **Landing page.** Feature subtitles and the highlights block removed — a list of names
  rather than a paragraph each.

## Open — three feature issues, nothing in progress

- **#5 Disk map as a real DaisyDisk replacement.** The sunburst that shipped is the view,
  not the product. Whole-disk scanning and the collector are the gap.
- **#4 SFTP without macFUSE,** as a File Provider extension. macFUSE is a kernel
  extension and cannot ship inside an app bundle, so this is the only route.
- **#3 Frutiger Aero base theme and a bundled icon set.** **Blocked on a contradiction —
  see below.**

## Blocked

**#3 asks for what the sweep deleted.** The issue wants named theme files in
`~/Library/Application Support/Soquel/themes/`, picked by name. The "One theme system"
decision below deleted exactly that: `ThemeLibrary`, `Theme_File`, the `.soquel-theme`
format, the Themes folder and the import/export around them. One of the two has to give
before any work starts on #3 — either rewrite the issue against the single-`theme.json`
model, or reverse the decision and say why.

## Next, once #3 is resolved either way

Smaller things, none blocking:
- Shortcut import and export. Remapping works; sharing a keymap does not.
- A universal binary. `scripts/build-app.sh` runs `swift build -c release`, so 1.0.1 is
  arm64 only. The landing page now says Apple silicon rather than claiming Intel.

## Decisions taken

- **One theme system.** theme.json is the only file that stores colours. The ready-made
  palettes are constants in `ThemePresets.swift` that write into it; which one is in use
  is derived by comparing colours, never stored. Applying one keeps the background image.
  `ThemeLibrary`, `Theme_File`, the `.soquel-theme` format, the Themes folder and the
  import/export around them are deleted.
- **No useless fallbacks.** Scanned all 108 `??` sites. Most are honest defaults ("—"
  placeholders, enum defaults, UI metrics) and were left. The one real offender was the
  rename date rule. `parentDirectoryURL(of:) ?? url` was left: the root's parent being
  the root is a correct answer, not a substitution.

## Traps hit

- `?? .none` in an optional context is `Optional.none`, i.e. nil, so it silently does
  nothing. That was the cause of #21, and I reintroduced it in the first attempt at the
  fix. Write `BackgroundConfig.none`.
- `String.map` shadows `Optional.map`, so `read(url)?.name.map { $0 == x }` compiles as a
  character-by-character map.

## Environment notes

- Do not launch the app. Build and test only.
- `~/Library/Application Support/Soquel/` currently holds only `settings.json`, last
  written 29 July. The pink theme with the sakura background that this file used to
  describe, and the `sakura.png` beside it, are not on disk. They were already gone
  before the 2 August test run — the md5 check ran first and found nothing. Cause
  unknown; not recreated.
- ThemeConfig redirects to a temp directory under test, so `swift test` does not write to
  the real theme.json. That is the mechanism the old md5 check was guarding.
