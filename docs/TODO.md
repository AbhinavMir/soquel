# Feature tracker

Working list of what is built, what is next, and what has been deliberately ruled out.
Update this in the same commit as the change it describes.

Status: `done` · `next` · `later` · `wont`

## Shipped, 0.1 through 1.0.1

| Feature | Notes |
| --- | --- |
| Panes (up to 4), tabs per pane | `⌘1`–`⌘4` to focus, `⌘T` for a tab; nested splits shipped later and are their own row below |
| List view with sortable columns | Name, size, kind, date; folders-first toggle |
| Sort by name / size / kind / date | `⌃⌘1`–`⌃⌘4`, column header click, or palette |
| Navigation | Breadcrumbs, editable path, history, Git root, sidebar |
| Create / rename / duplicate / copy / move / trash / delete | Per-file error reporting, no silent partial failure |
| Conflict handling | Keep both, replace, skip, cancel; sizes and dates shown |
| Undo | Rename, create, duplicate, trash, move |
| Copy path, 6 formats | Absolute, file URL, filename, no-extension, parent, shell-escaped |
| Command palette | Fuzzy match over every command, `⌘K` |
| In-folder filter, hidden files, Quick Look, drag and drop | `/`, `⇧⌘.`, `Space` |
| Terminal and editor integration | `⌃⌘T`, `⌃⌘E` |
| Session restore | Panes, tabs, and active tab per pane |
| Theme | Deep-teal accent, designed light and dark palettes, monospaced figures — `Theme.swift` |
| Customisable colours | Seven slots, light and dark, from Settings → Appearance or `theme.json` |
| Background image | Any image behind the file list, with opacity and five fit modes — Settings → Appearance |
| Folder merge on conflict | Merge, apply-to-all, skip-identical; a merge is deliberately not undoable |
| Cut / paste in the context menu | Plus Copy Path directly, with other formats one level down |
| New File templates | Text, Markdown, JSON, Swift, Python, Shell, HTML, CSV — created where you are standing |
| Folder sizes | Opt-in background column; counts a hard-linked inode once, never follows symlinks |
| Up button | Visible control beside the breadcrumbs |
| Sidebar groups | User-named sections; create, rename, remove, collapse |
| Pin to sidebar | Drag a folder in, or Go → Add to Favourites; reorder by dragging within and between groups |
| Column view | `⌥⌘3` — a pane per level, folders marked with a chevron |
| Archive browsing | Look inside zip, tar, 7z, rar without unpacking; extract on demand |
| Metadata columns | Dimensions, resolution, duration, codec, bit rate, colour space, camera — in any folder |
| Named workspaces | Save and reopen a pane and tab arrangement; stored as readable JSON |
| Batch rename | Find/replace, regex, numbering, case, extension, trim, file-date insertion, with a live preview |
| Transfer queue | `⌥⌘J` — throughput, coarse ETA, pause, resume, cancel per job; a failed file does not abandon the rest |
| Editable path bar | Click the breadcrumbs to type or paste a path; quotes and newlines are stripped |
| Auto-sized columns | Widths fit the longest value in the folder, measured over every row — `⌥⌘=` |
| Folder tree | Expandable hierarchy in the sidebar, lazy-loaded, follows the active pane — `⇧⌘T` |
| Custom sidebar icons | Any emoji or SF Symbol per shortcut, plus rename-without-renaming |
| Terminal and editor picker | Detects installed terminals and editors by bundle ID; choice remembered, and every one is listed in File and the context menu |
| Settings window | `⌘,` — Appearance and Keyboard panes |
| Remappable shortcuts | Every command, recorded in place, with conflict detection — Settings → Keyboard |
| Icon view | `⌥⌘2`, adjustable tile size; list is `⌥⌘1` |
| Multi-column sorting | Name, extension, size, kind, modified, created; shift-click a header to add a tiebreaker; up to 4 keys |
| Git status | Status column and badges from `git status`, folders marked when anything inside changed |
| Search | Modal panel: name or contents, contains/regex/glob, folder/home/everywhere, case, hidden, bundles, depth |
| Search reporting | Says what it skipped — too large, not text, unreadable folders, result cap — so "nothing" differs from "did not look" |
| Search ranking | Name matches outrank content matches; exact name outranks prefix outranks substring |
| Pane toolbar | Filter field on top, customisable button bar under it; right-click to choose buttons |
| View-mode pill | List, icon and column draw as one segmented control with the selected segment filled |
| Preview and details panel | `⌥⌘I` — Quick Look over kind, size, dates, permissions, owner, symlink target, extended attributes, media metadata, and SHA-256 on demand |
| Ready-made palettes | Settings → Appearance. Four of them, constants in `ThemePresets.swift` that write into `theme.json`; which one is in force is derived by comparing colours, never stored. Applying one keeps the background image. There is no theme file to keep, name, export or install — see the note under Known gaps |
| Settings as one JSON file | `settings.json` beside `theme.json`; hot-reloaded when edited outside the app |
| Open With, and set the default | Every registered application for the file, plus changing the system-wide handler for its type |
| Folder comparison and sync | `⇧⌘K` — left only / right only / differs / same, by size and date or by checksum, copied one direction over the ticked rows |
| Thumbnails in icon view | Generated by Quick Look off the main thread, cached by path, size and modification date |
| Rename in every view | List edits in place; icon and column use a sheet |
| `.gitignore`-aware search | Optional; nested ignore files, negation and anchoring all honoured, and the count skipped is reported |
| Logging | Every notable action to one dated file in `~/Library/Logs/Soquel/`; **Copy Recent Logs** in the palette puts the last 3 minutes on the clipboard; files older than 24 hours are removed |
| Disk map | `⇧⌘U` — a sunburst of where the space went, with the biggest items beside it; click to descend, right-click to reveal or trash. Scans one folder; whole-disk scanning and the collector are #5 |
| Workspaces keep their arrangement | A nested layout reopens nested; a pane whose folder has gone leaves a gap the arrangement closes |
| Connect to Server | `⌃⌘K` — SMB, AFP, NFS, WebDAV and FTP through the system's own mounter; the mount is an ordinary path, so everything else works on it unchanged |
| Nested pane splits | Vertical and horizontal mix; `⌘D` and `⇧⌘D` split only the focused pane, `⌥⌘D` rotates the split holding it |
| Selection shelf | `⌃⌘A` adds, `⌃⌘B` opens; files gathered from anywhere, delivered to the focused pane through the ordinary transfer engine |
| Saved searches | Named queries in the sidebar; every option survives, and a search whose folder is gone runs in the current one |
| Search by meaning | `⌃⌘F` — passages embedded with macOS's own sentence model and compared locally; finds a document by what it is about rather than the words it contains |
| Keyboard-first preset | `j k h l`, `g g`, `G`, `⌃d`/`⌃u`, handled in the file list so text fields are untouched |

## Demand-ranked backlog

[docs/RESEARCH-finder-wishlist.md](RESEARCH-finder-wishlist.md) ranks 47 wants by how often people
ask and how badly Finder fails, with sources.

The strongly-evidenced set is now built in full: cut/paste in the context menu, the folder tree,
search that walks the filesystem and hides nothing, folder merge, New File with templates, column
view, archive browsing, metadata columns, named workspaces, batch rename, thumbnails and folder
comparison. Nothing from that tier is outstanding. What is left in the research file is the long
tail, and it is not ranked above the two issues below.

## Next

- [ ] **Shortcut import and export** — remapping works; sharing a keymap does not.

## Known gaps

- A theme sets the seven colour slots and the background. Fonts, metrics and icon sets are not themeable.
- There is one theme and it lives in `theme.json`. Themes cannot be kept side by side, named, switched between, exported or installed — the `.soquel-theme` format that did that was deleted during the bug sweep, because two systems both claiming to own the colours is how the theme kept reverting. Issue #3 asks for named theme files again and contradicts this; the two have to be reconciled before it can start.
- Git integration is display-only by design: no staging, diffing, or committing.
- Content search reads UTF-8 text only and skips files over 8 MB; both are reported rather than silent.
- `.gitignore` support covers ignore files inside the repository. `core.excludesFile`, `.git/info/exclude` and `$XDG_CONFIG_HOME/git/ignore` are not read.
- Column set is fixed at name, extension, size, kind, dates and Git status. Owner, group, permissions and tags are shown in the preview panel rather than as columns.
- Queued transfers reorder only by cancelling and redoing; there is no drag to reprioritise, and no retry button for a failed file.
- Click-to-edit on the path bar is wired but has not been exercised interactively.
- View settings are global, not per folder.
- `sftp://` needs macFUSE and sshfs installed; macOS cannot mount it alone, and a kernel extension cannot ship inside an app bundle. The app uses sshfs when present and names the install when not. A File Provider extension is the route that removes the dependency — issue #4. S3 is not supported at all.
- FTP mounts read-only, which is a macOS limitation rather than a choice here.
- The Mac App Store is closed to this app as built: the sandbox forbids browsing outside user-granted folders, running `git`/`unzip`/`tar`, mounting servers, and whole-disk scanning. [Distribution](DISTRIBUTION.md) has the audit.

## Tracked as issues

These are the whole open list. Every issue from the adversarial bug sweep — 38 of them,
data loss first, then wrong result, then UI — is closed.

- [#3 Frutiger Aero base theme, and an icon set for ricing](https://github.com/AbhinavMir/soquel/issues/3)
  — blocked: it asks for the named theme files the sweep deleted. See Known gaps.
- [#4 SFTP without macFUSE: a File Provider extension](https://github.com/AbhinavMir/soquel/issues/4)
- [#5 Disk map: become an actual DaisyDisk replacement](https://github.com/AbhinavMir/soquel/issues/5)
- [#43 Preview .sqlite, .db, .csv and .sql without a client](https://github.com/AbhinavMir/soquel/issues/43)

## Ruled out

Intel Macs · AI assistant · cloud sync or accounts · plugin marketplace · built-in terminal emulator ·
photo library replacement · automatic file organisation · mobile app · replacing Finder at the
system level.

`scripts/build-app.sh` builds for the host, so the disk image is arm64 and the landing page
says Apple silicon. A universal binary is not planned.

Remote filesystems were on this list and came off it in part: SMB, AFP, NFS, WebDAV and read-only
FTP all mount through Connect to Server. SFTP is issue #4. S3 stays ruled out.

## How to add an entry

State the user-visible behaviour, not the implementation. If it is a bug, add a failing test first —
`Tests/SoquelCoreTests/RegressionTests.swift` has one test per defect found so far, each naming the
exact sequence that used to misbehave.
