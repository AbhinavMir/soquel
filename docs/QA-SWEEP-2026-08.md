# QA sweep, August 2026

A full review of the 1.0.7 codebase: 24,500 lines read end to end by subsystem,
plus three cross-cutting passes (wiring, hostile input, concurrency). Every
finding was verified against the code before it was accepted; refuted findings
were discarded, and reports that named the same defect twice are folded below.
All accepted findings are fixed on `main`.

This sweep is the gate for 2.0, the first alpha release.

| Severity | Found and fixed |
| --- | --- |
| data-loss | 12 |
| crash | 5 |
| broken-feature | 41 |
| wrong-behavior | 63 |
| polish | 25 |
| total | 146 |

## Findings

### data-loss

- `Archiver.swift` — Compress passes filenames where zip reads options; a dash-named file deletes other files
- `Archiver.swift` — A file named "-m" makes zip delete the other selected files
- `ColumnView.swift` — Filter applies only to the deepest column, so row indexes map to the wrong files after a descend
- `ColumnView.swift` — Deselection in a column never reaches the list, so Delete trashes a file that looks deselected
- `FileListViewController.swift` — goUp/goBack/goForward keep a stale columnSelection; Delete then trashes unseen files
- `FolderComparePanel.swift` — Stale or cancelled compare results are shown and can drive a copy into the wrong folders
- `OperationQueue.swift` — Retry of a checksum-failed copy re-copies the corrupt destination, never the source
- `OperationQueue.swift` — markStarted un-cancels a cancelled transfer
- `SFTPBrowser.swift` — Download Here silently overwrites an existing local file
- `SettingsStore.swift` — One JSON typo in settings.json destroys every setting
- `Theme.swift` — In-app theme writes destroy hand edits to theme.json
- `Workspaces.swift` — workspaces.json load and save both swallow errors — one bad entry or one failed write silently destroys all saved workspaces

### crash

- `MainWindowController.swift` — apply(workspace) re-filters the filesystem per pane and can index out of bounds
- `CommandPalette.swift` — Palette runs New Window / Cut / Copy / Paste with perform on MainWindowController and crashes
- `MainWindowController.swift` — apply(_:) re-runs survivingPanesWithIndices() per iteration against the live filesystem — index out of range if a folder disappears mid-open
- `SFTPBrowser.swift` — SFTP window is over-released on close and the app can crash
- `SemanticIndex.swift` — Shared NLEmbedding used from two threads at once; documented to deadlock

### broken-feature

- `AppDelegate.swift` — Newly saved workspaces never appear in Go > Open Workspace
- `BatchRename.swift` — Batch rename change-case rule always fails on case-insensitive volumes
- `Commands.swift` — Shortcut overrides edited in settings.json are ignored until relaunch
- `FileListViewController.swift` — Delete on a no-Trash network volume warns 'will be deleted outright' then fails to delete
- `FileListViewController.swift` — FolderSizeCalculator.onUpdate reassigned on every load; other pane's sizes never arrive
- `MainWindowController.swift` — View menu cannot switch the view in folders that carry a Finder .DS_Store style
- `Metadata.swift` — Single onUpdate closure on shared MetadataReader is stolen by the last pane
- `OperationQueue.swift` — markStarted races with finish/cancel: a cancelled transfer resumes copying, a finished job sticks at 'Copying' forever
- `OperationQueue.swift` — Retry after a checksum failure silently does nothing — failures store destination URLs, and copying them onto themselves is skipped
- `ThemeSharing.swift` — Repository parser removes every ".git" substring, mangling repo and owner names
- `AppDelegate.swift` — Saved workspaces never appear in the Go menu: .soquelWorkspacesChanged has zero observers
- `Archives.swift` — 7z listings are parsed with the bare-names parser and show garbage
- `Background.swift` — Background images render upside down in every fit mode
- `BatchRename.swift` — Change-case rule is fully blocked on case-insensitive volumes (the macOS default)
- `ColumnView.swift` — refreshDeepest collapses the whole column path to one column
- `Commands.swift` — Shortcut overrides cache never reloads after an outside settings edit
- `ConnectToServer.swift` — SFTP connections never reach Recents, and the servers-changed notification has no observer
- `Duplicates.swift` — Folder-duplicate detection silently fails for any folder that contains a hidden or empty file
- `FileListViewController.swift` — Auto-fit columns disables itself on its own programmatic resize
- `FileListViewController.swift` — Quick Look arrow keys drive the hidden table in icon and column mode
- `FileListViewController.swift` — Shared onUpdate callbacks are last-writer-wins across panes and tabs
- `FileListViewController.swift` — Git badges never refresh in icon view
- `FileListViewController.swift` — MetadataReader.shared.onUpdate stolen the same way; metadata columns stay blank in the losing pane
- `FolderComparePanel.swift` — Compare panel builds one constraint-laden NSView per entry on the main thread, hanging on large folders
- `FolderSize.swift` — Single shared onUpdate callback is clobbered by every pane and tab, so folder sizes stick at "…"
- `FolderViewSettings.swift` — Finder .DS_Store fallback ignores the per-folder off switch, so view-mode and sort commands do nothing in affected folders
- `GitStatus.swift` — Global generation token drops git status for every pane except the last one to ask
- `PackageContents.swift` — PackageContentsController is never retained; window controls all dead
- `PaneViewController.swift` — Tab switches never update the column browser or the view-mode visibility
- `RemoteLocations.swift` — sshfs mount waits for exit before draining stderr; can hang forever
- `SFTPBrowser.swift` — A non-auth connect failure still triggers a listing over a dead connection
- `Search.swift` — Cancelled search still streams stale hits into the next search's results
- `SemanticIndex.swift` — Index request during an active rebuild is silently dropped
- `SemanticIndex.swift` — Indexing a second folder while a rebuild runs silently indexes nothing
- `SettingsWindow.swift` — Menu key equivalents fire while a shortcut records
- `Sidebar.swift` — Any sidebar change collapses the whole folder tree
- `Sidebar.swift` — Expanded folders under the "/" root never restore at launch
- `ThemeSharing.swift` — '.git' is stripped from anywhere in the path, mangling repo names
- `Uninstall.swift` — UninstallPanelController is never retained; the panel is dead on arrival
- `UpdateCheck.swift` — lastChecked never persists; GitHub is contacted on every launch
- `Workspaces.swift` — soquelWorkspacesChanged is posted but never observed — a newly saved workspace does not appear in the Go menu

### wrong-behavior

- `AppDelegate.swift` — Quitting with several windows open keeps only the last window's session
- `AppDelegate.swift` — Extra Columns menu ticks go stale and other windows never learn of column changes
- `Checksum.swift` — sha256 returns a truncated-data hash as valid when a read fails mid-file
- `FileItem.swift` — addSecondary over the depth limit silently deletes the primary sort key
- `FileOperations.swift` — Verified copy pairs sources with wrong destinations after any merge — good copies reported corrupt, real corruption checked against the wrong file
- `FileOperations.swift` — Standing 'Merge' applied to a file conflict never copies the file yet records it as succeeded and merged
- `FileOperations.swift` — Cancel is swallowed when 'Skip files that are identical' is checked and the conflicting pair is identical
- `FolderPeek.swift` — Space on a folder does synchronous directory I/O on the main thread
- `FolderPeek.swift` — Unreadable folder peeks as "Empty"
- `Gitignore.swift` — IgnoreStack matches directory prefixes without a slash boundary, so sibling folders inherit rules
- `Inspector.swift` — Inspector starts a metadata read whose result can never reach it
- `Metadata.swift` — Metadata cache is never invalidated and never cleared
- `SFTPSession.swift` — SFTP quoting cannot represent newlines, so batch commands split and operations fail or mis-parse
- `VerifiedCopy.swift` — Tree verification reports 'unreadable' for any folder containing an absolute or broken symlink
- `AppDelegate.swift` — Extra Columns menu ticks never update: .soquelColumnsChanged has zero observers
- `Archives.swift` — Zip listing silently drops files named Makefile, profiles, and similar
- `Archives.swift` — Bare .gz special case is dead code; viewer shows phantom entries
- `Archives.swift` — Extraction ignores the tool's exit status; partial output reports success
- `Archives.swift` — Stale archive listing overwrites a newer one in the viewer
- `ColumnView.swift` — Column listing errors are swallowed; an unreadable folder shows as empty
- `CommandPanel.swift` — Closing the command panel with the close button does not stop the running command
- `CommandRunner.swift` — Stale termination event from a cancelled command resets UI state of the next run
- `Commands.swift` — Cmd-A while editing text selects all files, not the text
- `DiskMap.swift` — Disk-map progress reports one item's size where the panel displays a running total
- `Duplicates.swift` — File groups inside duplicate folders are not suppressed, so the panel floods with redundant pairs and double-counts reclaimable bytes
- `DuplicatesPanel.swift` — Cancelled duplicate scan checks the wrong work item and delivers stale results for a different folder
- `DuplicatesPanel.swift` — Trash failures in the duplicates panel are silently swallowed
- `DuplicatesPanel.swift` — Closing the Duplicates window with the close button never cancels the running scan
- `FileListViewController.swift` — Failed reload leaves stale tiles on screen in icon view
- `FileListViewController.swift` — Tags menu tick logic replaces the intersection instead of keeping it empty
- `FileListViewController.swift` — Back, forward, and up keep the old filter; navigate clears it but not the pane's field
- `FileListViewController.swift` — Switching icon view to list view drops the selection made in icon view
- `FolderComparePanel.swift` — Copy failure message is erased in the same runloop pass, and the copied count is always 0
- `FolderSize.swift` — Folder-size cache never invalidates for changes deeper than the folder's direct children
- `Gitignore.swift` — Gitignore rules leak onto sibling folders that share a name prefix
- `MainWindowController.swift` — Restored active tab is indexed into the filtered tab list, selecting the wrong tab when earlier tabs are missing
- `MainWindowController.swift` — Switching view mode erases a folder's remembered sort order
- `PaneToolbar.swift` — Toolbar buttons act on the focused pane, not the pane whose toolbar was clicked
- `PaneViewController.swift` — applyViewMode compares the deepest column, so any settings change destroys the drill-down
- `PaneViewController.swift` — Pane filter, list filter, and column filter fall out of sync after navigation and tab switches
- `RemoteLocations.swift` — A share path with a space is rejected with 'The address has no server name.'
- `SFTPBrowser.swift` — load() commits the new path before the listing succeeds, so a failed navigation desynchronizes everything
- `SFTPBrowser.swift` — SFTP listings race: no generation guard, entries and path can mismatch
- `SFTPSession.swift` — Any 'permission denied' in command output is reported as a bad password
- `SFTPSession.swift` — The listing parser silently drops entries it cannot match
- `Search.swift` — Everywhere scope walks the firmlinked data volume twice; every hit doubles
- `Search.swift` — Home scope in Meaning mode searches every indexed folder
- `SearchWindow.swift` — Meaning search blocked by an irrelevant regex compile error
- `SettingsStore.swift` — theme.json writes trigger app-wide reloads of every pane
- `SettingsWindow.swift` — A rejected combo silently ends the recording session
- `SettingsWindow.swift` — Appearance pane has no bottom constraint, so it cannot scroll
- `SettingsWindow.swift` — Colour swatches show stale colours after a theme change
- `Shelf.swift` — Shelved symlinks with a missing target are silently pruned
- `ShelfPanel.swift` — Shelf is cleared after a cancelled or partially failed move
- `ShelfPanel.swift` — Delivery buttons re-enable during a transfer, allowing a concurrent second delivery
- `Sidebar.swift` — Arrow-key traversal runs saved searches and mutates the tree
- `Sidebar.swift` — Restore drops pending folders while a load is still in flight
- `SidebarStore.swift` — Reveal walk always starts at "/", so volume and home roots never work
- `TabItemView.swift` — Invisible tab close button still takes clicks
- `Theme.swift` — Malformed or partial theme.json is silently ignored at launch
- `Theme.swift` — Theme.apply swallows write failure; edits revert on relaunch
- `ThemeSharing.swift` — Gist theme with relative background path clobbers user's background
- `Uninstall.swift` — Trash-failure message is immediately overwritten by the rescan

### polish

- `Archives.swift` — isArchive's bare-.gz special case is a tautology, so single compressed files get a broken archive flow
- `FileOperations.swift` — A merged folder never advances job progress — a pure-merge copy of gigabytes finishes showing '0 files, Zero KB'
- `FolderPeek.swift` — Peek tile stale-thumbnail guard compares filename only
- `Inspector.swift` — explain(mode:) tests S_IFDIR on a value that never contains it
- `MainWindowController.swift` — window.center() runs after frame autosave restore, so window position never persists
- `OperationQueue.swift` — Status lines mix per-source and per-file counts: copying a 100-file folder ends as '1 file', failures read 'N of 100 failed'
- `RemoteLocations.swift` — sshfs volname built from the typed path lets a comma inject extra mount options
- `SFTPSession.swift` — SFTP listing regex only accepts d, l and - file types, so sockets, FIFOs and devices vanish silently
- `ApplicationSettings.swift` — Duplicate app names drop rows from the Opens-with menu
- `Background.swift` — Stale image cache after reinstalling an updated repo theme
- `BatchRename.swift` — An invalid rename regex is silently treated as "no changes"
- `ColumnView.swift` — Dragging any divider after the first one jitters and applies the wrong delta
- `CommandRunner.swift` — ANSI strip leaves a stray backslash after an ST-terminated OSC sequence
- `ConnectToServer.swift` — Return in the address field re-submits while a mount is in flight
- `FileListViewController.swift` — Post-trash reselection and resetScroll only address the table in icon mode
- `FolderComparePanel.swift` — A hand-ticked type-conflict row is silently dropped from the copy
- `PaneViewController.swift` — Clicking away from the path field strands the pane with a dead editor and no breadcrumbs
- `RemoteLocations.swift` — The already-mounted fallback can report a wrong error or pick a wrong volume
- `Search.swift` — Error message points at a Settings pane that does not exist
- `Search.swift` — Meaning search runs model and disk stats on the main thread per keystroke
- `SemanticIndex.swift` — .soquelIndexChanged is posted for consumers that do not exist
- `Sidebar.swift` — Load completion re-expands a folder the user already collapsed
- `Sidebar.swift` — Stale reveal origin governs a navigation that interrupts a walk
- `ThemeSettings.swift` — Return key starts a second concurrent gist fetch
- `ThemeSettings.swift` — Preset swatch strip always shows the dark palette

## Verification of the fixes

The fixes themselves were then reviewed the same way the code was: one hostile
reviewer per fix commit, hunting for regressions the 833-test suite cannot
see. Round one found 45 secondary defects (9 of them user-visible breakage);
all were repaired with the original fix kept intact. Round two reviewed the
repairs and found 6 residual defects; all repaired. The rounds converged
45 → 6 → 0.

## Also in this pass

- Drag and drop: the icon view accepted no drops and the column view had no
  drag support at all. Both work now, in both directions.
- Double-click in icon view opened nothing (issue #42, closed).
- Invert Selection worked only in the list view.
- The docs were audited against the code: 27 wrong claims corrected across
  KEYBINDINGS.md, SETTINGS.md, README.md and the landing page.
