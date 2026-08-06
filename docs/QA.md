# QA sweep

A manual test pass for Soquel. Every line is one thing to do and one thing to check.
Work top to bottom, or pick a section. Tick nothing you did not actually see happen.

**Version under test:** 1.0.5
**Platform:** Apple silicon, macOS 13 or later

## How to report

One issue per finding, at https://github.com/AbhinavMir/soquel/issues. Include:

1. The section and line number from this file.
2. What you did, in the order you did it.
3. What you expected, and what happened instead.
4. Whether it happens every time or once.
5. `grep -h "" ~/Library/Logs/Soquel/*.log | tail -40` if anything went wrong.

Reset to a clean state between sections when a test leaves the app configured oddly:
Settings → its own reset, or quit and remove `~/Library/Application Support/Soquel/settings.json`.

**Do not test destructive operations on real files.** Make a scratch folder:

```sh
mkdir -p ~/soquel-qa && cd ~/soquel-qa
mkdir -p deep/a/b/c empty "spaces in name" .hidden-folder
printf 'hello\n' > plain.txt
printf 'x,y\n1,2\n' > data.csv
printf '<h1>hi</h1>' > page.html
printf '{"a":1}' > thing.json
dd if=/dev/urandom of=big.bin bs=1m count=40 2>/dev/null
ln -sf plain.txt link.txt
ln -sf /nowhere broken-link.txt
touch .dotfile "name with 'quote'.txt" "emoji 🎉.txt"
cp plain.txt copy-of-plain.txt
```

---

## 1. Launch and window

1.1 Launch from Finder. Window appears, no crash, no blank pane.
1.2 Quit with ⌘Q, relaunch. The same panes, tabs and folders come back.
1.3 Resize the window very small. Nothing overlaps; the toolbar does not scramble.
1.4 Full screen and back. Layout survives.
1.5 Two windows (⌘N). They are independent; closing one leaves the other alone.
1.6 Close the last window, then reopen from the Dock. It comes back.
1.7 Launch with the app already running. Does not open a duplicate blank window.

## 2. Navigation

2.1 Double-click a folder. It opens.
2.2 Double-click a file. It opens in its default app.
2.3 ⌘↑ goes up. At `/` it does nothing rather than erroring.
2.4 ⌘[ and ⌘] walk back and forward through history.
2.5 The Up button beside the breadcrumbs does the same as ⌘↑.
2.6 Click a breadcrumb component. It navigates there.
2.7 Click the breadcrumbs to edit. Type `~/Downloads`, press Return. It goes there.
2.8 Paste a path with quotes around it. The quotes are stripped, not searched for.
2.9 Paste a path that does not exist. An error is shown; the view does not go blank.
2.10 Type a path with a trailing newline. Handled.
2.11 Navigate into `.hidden-folder` by typing its path while hidden files are off. It opens.
2.12 Enter a folder you cannot read (`/private/var/root`). It says so rather than showing empty.

## 3. View modes

3.1 ⌥⌘1 list, ⌥⌘2 icon, ⌥⌘3 column. All three draw.
3.2 The segmented pill matches the current mode after every switch.
3.3 Switch modes with a file selected. The selection survives.
3.4 Switch modes in an empty folder. No crash, no leftover rows.
3.5 Icon view: zoom in and out. Tiles resize; labels stay readable.
3.6 Icon zoom at both extremes. Nothing clips or overlaps.
3.7 Column view: descend four levels. Each column appears.
3.8 Column view: click a file in the first column. Deeper columns close.
3.9 Column view: drag the divider. Width changes, and stops at a sane minimum.
3.10 Column width survives a relaunch.
3.11 Per-folder view settings on (Settings). Set Downloads to list, Pictures to icon. Each remembers.
3.12 Per-folder view settings off. Both folders use the global mode again.

## 4. Selection

4.1 Click a file. One row highlights; the status bar names it.
4.2 ⌘-click three files. All three highlight; the status bar says 3 selected.
4.3 ⌘-click a selected file. It deselects, the others stay.
4.4 ⇧-click. The range between anchor and click selects.
4.5 ⇧-click above the anchor. The range still works upward.
4.6 ⌘A selects everything, in list, icon and column view.
4.7 ⌘A in an empty folder. Nothing happens; no crash.
4.8 Click empty space below the rows. Selection clears.
4.9 Arrow keys move the selection one row.
4.10 ⇧ plus arrows extends the selection.
4.11 Select all, then trash. Every file goes, the view updates.
4.12 Invert selection.

## 5. Rename — new in 1.0.5, test hard

5.1 List view: select a file, press Return. An editor appears over the name.
5.2 The editor is opaque. The old name is not visible behind the new one.
5.3 The editor sits on the row being renamed, not the one above or below.
5.4 `plain.txt`: `plain` is selected, `.txt` is not.
5.5 Type a new name, press Return. The file is renamed; the list re-sorts if it must.
5.6 Press Escape mid-edit. Nothing is renamed; the old name is intact.
5.7 Start a rename, click another file. The rename commits, and the click selects that file.
5.8 Column view: rename in the deepest column. The parent columns stay open.
5.9 Column view: rename in a middle column. Same.
5.10 Icon view: rename. The editor is centred over the label.
5.11 Rename to a name that already exists. An error, and no data lost.
5.12 Rename to an empty string. Refused, nothing renamed.
5.13 Rename to a name with `/` in it. Refused with an explanation.
5.14 Rename `.dotfile`. The whole name is selected, since there is no extension to protect.
5.15 Rename `archive.tar.gz`. `archive.tar` is selected.
5.16 Rename to a name 250 characters long. Either works or is refused cleanly.
5.17 Rename with emoji in the name.
5.18 Rename, then ⌘Z. The old name comes back.
5.19 Rename a file, then rename it again immediately. The second editor opens on the new name.
5.20 Drag a column header so Name is no longer second, then rename. Still edits the name.
5.21 Rename while a filter is active. The right file is renamed.
5.22 Rename a file that another process deletes mid-edit. An error, no crash.
5.23 Rename via the context menu. Same editor.
5.24 Rename with a very long name in a narrow column. The editor widens rather than clipping.
5.25 Rename the last file in a long folder, scrolled to the bottom. The editor is on screen.

## 6. File operations

6.1 New folder (⇧⌘N). It appears, named and ready to rename.
6.2 New file from each template. Each has the right extension and starter content.
6.3 Copy (⌘C) and paste (⌘V) in another folder.
6.4 Cut (⌘X) and paste. The original is gone.
6.5 Paste into the same folder. A "copy" name is made rather than a clobber.
6.6 Duplicate (⌘D).
6.7 Move to trash (⌘⌫). The view updates immediately.
6.8 Trash multiple files at once.
6.9 Delete permanently (⌥⌘⌫). Confirmation is asked for.
6.10 ⌘Z after a trash. The file comes back.
6.11 ⌘Z after a move. The file goes back where it was.
6.12 Copy a folder onto one with the same name. The conflict sheet offers merge.
6.13 Merge, then check nothing inside was lost.
6.14 Replace on conflict. The old one is in the Trash under its own name, not deleted.
6.15 Keep both. Two files, distinct names.
6.16 Skip. Nothing changes.
6.17 Apply-to-all on a folder of 20 conflicts. It is applied to all 20.
6.18 Copy `big.bin` to another volume. The transfer queue shows progress.
6.19 Cancel a transfer mid-way. No half file left where the app can see it.
6.20 Copy a file you have no permission to read. The failure names that file and the rest continue.
6.21 Copy a symlink. The link is copied, not the target.
6.22 Copy a broken symlink. No crash.
6.23 Verified copy on. Copy a file, and confirm it says it read back what it wrote.

## 7. Filter and search

7.1 Press `/`. The caret lands in the filter box.
7.2 Type. The list narrows as you type.
7.3 There is exactly one filter box on screen. Not two.
7.4 Escape leaves the filter and clears it.
7.5 Return in the filter box hands focus to the list with the filter still on.
7.6 Filter, then change folder. The filter clears rather than following you.
7.7 Filter in column view. Only the deepest column narrows.
7.8 Type-select: type `pl` in the list. The selection jumps to `plain.txt`.
7.9 Type-select the same letter repeatedly. It cycles through matches.
7.10 Type-select works in icon and column view too.
7.11 Type-select pauses and resets after about a second.
7.12 Search panel (⌘F). Search by name, by contents.
7.13 Search with a regex, a glob, and a plain substring.
7.14 Search reports what it skipped: too large, not text, unreadable.
7.15 Search `~` with hidden files on and off. The counts differ.
7.16 Semantic search (⌃⌘F). Ask for a concept, not a word, and get a sensible file.
7.17 Save a search. It appears in the sidebar and reruns.
7.18 A saved search whose folder is gone runs in the current folder rather than failing.

## 8. Sidebar

8.1 Click each favourite. The pane navigates.
8.2 Drag a folder into the sidebar. It is pinned.
8.3 Rename a pinned item. The folder on disk is not renamed.
8.4 Give a pinned item an emoji icon.
8.5 Reorder within a group by dragging.
8.6 Drag between groups.
8.7 Make a group, rename it, collapse it, remove it.
8.8 Folder tree (⇧⌘T). Expand three levels.
8.9 Click a tree folder. The pane follows; focus does not jump back to Favourites.
8.10 Remove a favourite whose folder was deleted. It goes cleanly.
8.11 Eject a volume from the sidebar.

## 9. Panes and tabs

9.1 ⌘T opens a tab. The tab bar is visible.
9.2 Close a tab. The remaining tabs stay; there is never zero.
9.3 Close the only tab. It stays; one tab is the minimum.
9.4 Open eight tabs. The tab bar scrolls.
9.5 Click a tab. It activates and the pane changes.
9.6 ⌘D splits vertically, ⇧⌘D horizontally, ⌥⌘D rotates.
9.7 ⌘1 to ⌘4 focus the panes.
9.8 The focused pane is visibly marked.
9.9 Drag a file from one pane to another. It copies or moves as expected.
9.10 Sync browsing on. Both panes walk together.
9.11 Save a workspace. Reopen it. The nesting is the same.
9.12 A workspace whose folder is gone opens without the gap breaking the layout.

## 10. Columns and sorting

10.1 Click a header. It sorts; the indicator shows which way.
10.2 Click again. It reverses.
10.3 ⇧-click a second header. A tiebreaker is added, up to four.
10.4 Drag a column wider and narrower. It stops at a minimum rather than vanishing.
10.5 Drag a column to reorder it. The order survives a relaunch.
10.6 ⌥⌘= auto-sizes to the longest value.
10.7 Turn on a metadata column (dimensions, duration). It fills in for the right files.
10.8 Turn on folder sizes. They compute in the background without freezing the list.
10.9 Sort by size in a folder with a mix of files and folders.
10.10 Newest first is the default in a fresh folder.
10.11 Folders are not forced to the top unless that setting is on.

## 11. Preview and details

11.1 Space opens Quick Look.
11.2 Space on a folder shows what is inside.
11.3 Space again closes it.
11.4 ⌥⌘I opens the details panel.
11.5 Kind, size, dates, owner and permissions are shown and correct.
11.6 Hover the permission string. The tooltip explains it.
11.7 A symlink shows its target.
11.8 SHA-256 on demand. It matches `shasum -a 256`.
11.9 Preview `page.html`. It renders.
11.10 Preview an image, a PDF, a video, a text file.
11.11 Preview a file with no preview available. A placeholder, not a blank panel.

## 12. Themes and appearance

12.1 Apply each built-in palette. Colours change everywhere, including the sidebar and tab bar.
12.2 Switch theme with the window scrolled. The top of the view is redrawn, not left stale.
12.3 Set a background image. Try each of the five fit modes.
12.4 Window opacity. The whole window goes translucent, not just the image.
12.5 Opacity is not offered when there is no reason for it.
12.6 Install a theme from a gist URL.
12.7 Install a theme from a git repository URL.
12.8 A repo theme that carries an image installs the image too.
12.9 A repo theme with an absolute image URL is refused.
12.10 A malformed theme URL fails with a message rather than a crash.
12.11 Air, Windows 95 and Platinum each apply cleanly.
12.12 Light and dark system appearance. Both look deliberate.
12.13 Edit `theme.json` in another editor while running. The window redraws.

## 13. Settings

13.1 ⌘, opens Settings.
13.2 Every pane is the same width; nothing jumps as you switch.
13.3 Search the settings. Typing narrows to matching rows across panes.
13.4 Search for something absent. It says nothing matched.
13.5 Remap a shortcut. It takes effect without a relaunch.
13.6 Remap to a shortcut already in use. The conflict is named.
13.7 Reset a shortcut to its default.
13.8 Turn on the keyboard-first preset. `j k h l`, `gg`, `G`, `⌃d`, `⌃u` work in the list.
13.9 With the preset on, typing in the filter box still types letters.
13.10 Choose a terminal and an editor. Both open at the current folder.
13.11 Edit `settings.json` outside the app. The change is picked up.
13.12 Turn the update check on and off.

## 14. Archives and compression

14.1 Compress a folder. A `.zip` appears.
14.2 Unzip it elsewhere and confirm there is no `.DS_Store`, no `__MACOSX`, no `._` files.
14.3 Compress a single file.
14.4 Compress a selection of several files.
14.5 Compress something with spaces and quotes in the name.
14.6 Browse into a `.zip` without extracting.
14.7 Browse a `.tar`, a `.7z`, a `.rar`.
14.8 Extract one file out of an archive.
14.9 Browse a corrupt archive. An error, no crash.

## 15. Finder interop

15.1 A folder Finder has in icon view opens in icon view here.
15.2 A folder Finder sorts by date sorts by date here.
15.3 Soquel's own per-folder setting beats Finder's.
15.4 Confirm Soquel never writes a `.DS_Store`: `find ~/soquel-qa -name .DS_Store` before and after a full session.
15.5 A folder with no `.DS_Store` uses the global default.
15.6 A corrupt `.DS_Store` (`head -c 200 /dev/urandom > f/.DS_Store`) is ignored, not fatal.

## 16. Git

16.1 Open a git repository. Changed files are badged.
16.2 A folder containing a change is badged.
16.3 The Git column shows status.
16.4 Go to Git root works.
16.5 A repository with 5,000 changed files does not freeze the list.
16.6 A folder that is not a repository shows no Git column content.

## 17. Tools

17.1 Duplicate finder. It matches by content, not name — `plain.txt` and `copy-of-plain.txt` pair up.
17.2 Batch rename: find and replace, regex, numbering, case, extension, trim, date insert.
17.3 Batch rename preview matches what actually happens.
17.4 Batch rename that would collide. It says so before doing it.
17.5 Folder compare (⇧⌘K). Left only, right only, differs, same.
17.6 Compare by checksum rather than date.
17.7 Copy one direction over the ticked rows only.
17.8 Disk map (⇧⌘U). Click to descend, right-click to reveal.
17.9 Shelf: ⌃⌘A from three folders, ⌃⌘B to deliver.
17.10 Tags: add, remove, filter by.
17.11 Make a symlink. It points where it should.
17.12 Run a Command Here.
17.13 Connect to Server with an SMB share.
17.14 Uninstaller finds an app's leftovers, including `com.acme.Thing` folders.

## 18. Edge cases and abuse

18.1 A folder with 50,000 files. It lists; scrolling is not unusable.
18.2 A file named with a newline in it.
18.3 A file whose name is 255 characters.
18.4 A folder that is a symlink loop.
18.5 Unplug a USB drive while browsing it. An error, no crash, no hang.
18.6 Delete the current folder from Terminal while it is open. The view notices.
18.7 Rename the current folder from Terminal. The view notices.
18.8 A network volume that goes away mid-copy.
18.9 Trash on a network volume. It warns rather than silently deleting.
18.10 Two Soquel windows on the same folder. A change in one shows in the other.
18.11 A file being written to while listed. Size updates rather than sticking.
18.12 Deny Full Disk Access, then open Desktop. It explains rather than showing empty.
18.13 Leave the app running while the machine sleeps. It is alive on wake.
18.14 Change system appearance while running.
18.15 Change the system accent colour while running.

## 19. Logs and diagnostics

19.1 Do a handful of operations. `~/Library/Logs/Soquel/` has one dated file.
19.2 Copy Recent Logs from the palette. The clipboard has the last few minutes.
19.3 Logs older than a day are gone.
19.4 No secret, token or full home path of another user appears in a log.

## 20. Command palette

20.1 ⌘K opens it.
20.2 Fuzzy match finds a command by an abbreviation.
20.3 Every command in the palette actually runs.
20.4 A command that needs a selection is not offered without one, or explains itself.
20.5 Escape closes it, and focus returns to the list.
