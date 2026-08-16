# Working state

Branch: `main`, clean and pushed. 833 tests pass in ~15s.

**1.0.8 is shipped.** Signed, notarised, stapled, disk image on the GitHub
release, landing page live at trysoquel.com with the 1.0.8 changelog entry.
Still beta; 2.0 is still reserved for the first alpha.

The release carries the August 2026 deep QA sweep (146 defects found by reading
every line of SoquelCore) plus 106 more found by driving the installed app
through docs/QA.md by hand — 209 in all.

Of the fixes, 48 were confirmed by re-driving the running app. The rest rest on
the build and the test suite. The last thirteen findings and the speed work have
not been driven against the shipped 1.0.8 disk image.

## Open

- **#5 Disk map as a real DaisyDisk replacement.** The sunburst that shipped is the view,
  not the product. Whole-disk scanning and the collector are the gap.
- **#4 SFTP without macFUSE,** as a File Provider extension. macFUSE is a kernel
  extension and cannot ship inside an app bundle, so this is the only route.
- **#43 Preview .sqlite, .db, .csv and .sql** without opening a client. Read-only,
  bounded reads, never execute what is in the file. Long term.

**#3 is closed, won't do.** It asked for named theme files in a `themes/` folder, which
is what the sweep deleted.

## Released since 1.0.1

- **1.0.2** — eleven features from the research backlog (folder Quick Look, sync
  browsing, duplicate finder, verified copy, symlinks, per-folder views, transfer retry,
  tags, network trash warning, uninstaller, Run a Command Here), plus an opt-in update
  check.
- **1.0.3** — the tab bar had never been visible in any build; the window extended its
  content behind an opaque title bar. Newest-first sort, no folder grouping, Copy Path on
  ⌥⌘C, Safari-style tabs, Compress without `.DS_Store`, gist and repo themes, window
  opacity, Air/Windows 95/Platinum, searchable settings.
- **1.0.5** — renaming in place, in every view. Return had been opening an editor on
  the Git column, which has no text, so it did nothing at all in list view. The editor is
  now put over the name itself: opaque, centred on its row, extension left out of the
  selection, Escape cancels, clicking elsewhere commits.
- **1.0.4** — reads Finder's `.DS_Store` (never writes one). ⌘A everywhere, ⌘/⇧-click in
  column view, draggable columns and column-view width, icon zoom, HTML previews, one
  filter box instead of two.

## Next

Smaller things, none blocking:
- Shortcut import and export. Remapping works; sharing a keymap does not (#44).
- The Show HN draft on the Desktop still describes 1.0.1.
- [docs/QA.md](docs/QA.md) is the manual sweep, 20 sections. Driving it by hand is
  what found the defects reading the code did not: a crash on Open Workspace, ⌘W
  quitting the app, five blank settings panes, and every one of the speed
  problems. Run it against a build, not against the source.
- Known and unfixed: arrow keys do nothing while Quick Look is open in column
  view. It needs a delegate hook from the pane to the deepest column table.

## Decisions taken

- **One theme system.** theme.json is the only file that stores colours. The ready-made
  palettes are constants in `ThemePresets.swift` that write into it; which one is in use
  is derived by comparing colours, never stored. Applying one keeps the background image.
  `ThemeLibrary`, `Theme_File`, the `.soquel-theme` format, the Themes folder and the
  import/export around them are deleted.
- **Read `.DS_Store`, never write one.** A folder Finder already knows should be in icon
  view should not open as a list because Soquel has never been told. Writing them would
  contradict stripping them out of the archives Compress makes. Soquel's own per-folder
  settings live in `settings.json` and outrank Finder's.
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
