# Working state

Branch: `bug-sweep` (off `main` at 48cdf79). No PR yet. 495 tests pass.

**20 of 38 fixed and closed.** 18 open: 11 Wrong Result, 7 UI.

## What this is

Fixing the open issues on AbhinavMir/soquel, found by an adversarial bug sweep.
Order is data loss first, then wrong result, then UI.

Labels: `data loss`, `Wrong Result`, `UI`. Nothing else.

## Done — all 7 data-loss issues are closed

- **#6 #7 #8 #22 — theme state** (`c6fa729`)
  ThemeConfig now redirects to a temp directory under test, so `swift test` no
  longer rewrites the real theme.json. "Reveal theme.json" writes the colours in
  force and keeps the background instead of writing the shipped palette and
  clearing the image.
- **#10 #11 #12 — destructive file operations** (`7c896de`)
  Stage-then-swap keeps the existing item until the swap has happened, so a
  failed move no longer loses both copies. A replaced folder goes to the Trash
  under its own name. Folder compare will not put a file where a folder is —
  excluded from the plan, refused by apply(), unticked by default. The conflict
  prompt warns whenever the destination is a folder, not only when both sides
  are.
- **#9 #21 #38 — closed by deletion** (`3dface9`)
  The `.soquel-theme` format is gone. See the decision below.
- Batch rename no longer stamps the current time into a filename when the
  file's own date cannot be read; the entry is reported and skipped.

- **#13 #14 #15 #17 #18 #33 #35 #36 — semantic index** (`a260895`)
  Nested roots no longer duplicate and double passages per rebuild. The
  incremental keep is linear rather than quadratic. Folder scoping compares
  paths, not string prefixes, so ~/Notes-archive is not inside ~/Notes. The
  query vector's width is checked before sgemv reads it. Every entry is
  blended, so there are no longer two score scales in one array. Text with no
  blank line and no ". " is cut on character count instead of becoming one
  8 MB passage. No empty passages. The index loads off the main thread.

## Next

Clusters worth doing together:
- **Threading:** #16 fileWatcher raced, #26 unsynchronized cancellation flag,
  #19 cancelled scan resurrected
- **Disk map / scanning:** #20 unreadable counted as zero, #25 volumes walked
  twice, #31 trashing restarts the scan, #37 "smaller items" sentinel,
  #39 depth off by one
- **Transfers:** #29 staging in the system temp dir breaks cross-volume
  overwrites, #30 failed copies counted as copied
- **Settings:** #23 lost write, #24 bytes recorded before the write
- **Leftovers:** #27 reveal selection, #28 recycled object addresses as keys,
  #32 hidden panes cannot resize, #34 literalScore matches substrings,
  #40 silent matcher failure, #41 breadcrumb hidden too early

Feature issues #3 #4 #5 are out of scope for this sweep.

## Decisions taken

- **One theme system.** theme.json is the only file that stores colours. The
  ready-made palettes are constants in `ThemePresets.swift` that write into it;
  which one is in use is derived by comparing colours, never stored. Applying
  one keeps the background image. `ThemeLibrary`, `Theme_File`, the
  `.soquel-theme` format, the Themes folder and the import/export around them
  are deleted.
- **No useless fallbacks.** Scanned all 108 `??` sites. Most are honest defaults
  ("—" placeholders, enum defaults, UI metrics) and were left. The one real
  offender was the rename date rule. `parentDirectoryURL(of:) ?? url` was left:
  the root's parent being the root is a correct answer, not a substitution.

## Traps hit

- `?? .none` in an optional context is `Optional.none`, i.e. nil, so it silently
  does nothing. That was the cause of #21, and I reintroduced it in the first
  attempt at the fix. Write `BackgroundConfig.none`.
- `String.map` shadows `Optional.map`, so `read(url)?.name.map { $0 == x }`
  compiles as a character-by-character map.

## Environment notes

- The user's theme is pink with a sakura background, set by hand in
  `~/Library/Application Support/Soquel/theme.json`, image at `sakura.png`
  beside it. Do not let tests or fixtures write to that file — check its md5 is
  unchanged after any test run (currently `30c16bfa25ddc2a4e6ce5b904a9ddada`).
- Do not launch the app. Build and test only.
