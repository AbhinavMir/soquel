# Working state

Branch: `main`, clean and pushed. 683 tests pass in 13.6s.

**1.0.1 is shipped.** Signed with a Developer ID, notarised, disk image on the GitHub
release, landing page live at trysoquel.com.

## What this is

Soquel, a file manager for macOS. The adversarial bug sweep that this file used to track
is finished: all 38 issues it raised are closed. Two feature issues remain, neither
started.

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

## Open — two feature issues, nothing in progress

- **#5 Disk map as a real DaisyDisk replacement.** The sunburst that shipped is the view,
  not the product. Whole-disk scanning and the collector are the gap.
- **#4 SFTP without macFUSE,** as a File Provider extension. macFUSE is a kernel
  extension and cannot ship inside an app bundle, so this is the only route.

**#3 is closed, won't do.** It asked for named theme files in a `themes/` folder, which
is what the sweep deleted. The theming that shipped — seven slots light and dark, a
background image, four ready-made palettes, all in `theme.json` — is enough.

## Since 1.0.1, unreleased

Eighteen changes on `main`, none of them cut into a build yet. The eight below,
plus eleven features from the research backlog — folder Quick Look, sync browsing,
duplicate finder, verified copy, symlinks, per-folder views, transfer retry and
reorder, tags, the network trash warning, the uninstaller and Run a Command Here.
docs/TODO.md lists them all.

- Clicking a favourite no longer hands the highlight to the folder tree. The tree still
  opens down to the folder; it just does not steal the selected row.
- **Show Package Contents** opens a `.app` in a window over the pane instead of
  navigating into it. `PackageContents.swift`.
- The folder tree lists files, five per folder, then a row standing in for the rest.
  Selecting a file opens its folder and selects it there rather than navigating to it.
- File kinds in Settings are no longer the fixed twenty-three: **Add Kind…** takes any
  extension macOS recognises. Open With is a toolbar button as well as a right-click.
- The hidden-files button draws `eye.slash` when hidden files are off. The view pill
  fills its selected segment with grey rather than the selection blue.
- Tabs have a close button each and a plus at the end of the bar.

## Next

Smaller things, none blocking:
- Shortcut import and export. Remapping works; sharing a keymap does not.

## Decisions taken

- **One theme system.** theme.json is the only file that stores colours. The ready-made
  palettes are constants in `ThemePresets.swift` that write into it; which one is in use
  is derived by comparing colours, never stored. Applying one keeps the background image.
  `ThemeLibrary`, `Theme_File`, the `.soquel-theme` format, the Themes folder and the
  import/export around them are deleted.
- **Apple silicon only.** `scripts/build-app.sh` runs `swift build -c release`, which
  builds for the host, so the disk image is arm64. A universal binary is deliberately not
  cut. The landing page says Apple silicon, which is true, and that is the whole of it.
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
