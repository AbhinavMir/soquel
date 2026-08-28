# Keybindings

Every command is also in the command palette (`⇧⌘P`), which shows its shortcut.

## Panes and tabs

| Action | Shortcut |
| --- | --- |
| Split vertically | `⌘D` |
| Split horizontally | `⇧⌘D` |
| Rotate the split holding this pane | `⇧⌥⌘D` |
| Close pane | `⌃⌘W` |
| Focus pane by position | `⌘1`–`⌘4` |
| Focus next / previous pane | `⌥⌘→` / `⌥⌘←` |
| Swap panes | palette only |
| Compare focused pane with the other | `⇧⌘K` |
| New window | `⌘N` |
| New tab | `⌘T` |
| Close tab | `⌥⌘W` |
| Next / previous tab | `⌃⇥` / `⌃⇧⇥` |
| Close window | `⌘W` |
| Quit | `⇧⌘W` or `⌘Q` |
| Save workspace | `⇧⌘S` |

Splitting divides the focused pane only, so vertical and horizontal splits mix in one window — split
the right-hand pane horizontally and the left one is untouched. Splitting the same direction twice
adds a sibling rather than nesting, since a divider inside a divider running the same way changes
nothing.

`⌘W` closes the window and leaves the application running, as it does everywhere else on the Mac;
`⇧⌘W` quits. Closing a tab is `⌥⌘W`, and one tab is the minimum: closing the last tab of the last
pane keeps it and says so.

## Navigation

| Action | Shortcut |
| --- | --- |
| Open selection | `⌘↓` or `⌘O`, or double-click |
| Enclosing folder | `⌘↑`, or `⌫` with nothing selected |
| Back / forward | `⌘[` / `⌘]` |
| Home | `⇧⌘H` |
| Go to folder | `⇧⌘G` |
| Connect to Server | `⌃⌘K` |
| Git repository root | palette only |
| Add current folder to the sidebar | `⇧⌘L` |

## Files

| Action | Shortcut |
| --- | --- |
| New folder | `⇧⌘N` |
| New file | `⌃⌘N` |
| Rename | `↩` on a selected row |
| Open With, and set the default application for the type | context menu |
| Duplicate | `⌃⇧⌘D` |
| Cut / copy / paste | `⌘X` / `⌘C` / `⌘V` |
| Move to Trash | `⌘⌫` |
| Delete permanently | `⌥⌘⌫` |
| Undo | `⌘Z` |
| Select all | `⌘A` |
| Rename many | `⌃⌘R` |
| Compare two files | `⌥⌘D` |
| Look inside archive | `⇧⌘O` |
| Add to Shelf / show Shelf | `⌃⌘A` / `⌃⌘B` |

Delete permanently always asks first. Undo covers rename, create, duplicate, trash, move, and an
entire Clean This Folder operation as one step.

## Paths

| Action | Shortcut |
| --- | --- |
| Copy absolute path | `⌥⌘C` |
| Copy path relative to Git root | `⇧⌥⌘C` |
| File URL, filename, filename without extension, parent directory, shell-escaped | Path menu or palette |

## View

| Action | Shortcut |
| --- | --- |
| Command palette | `⇧⌘P` |
| Filter this folder | `/` or `⌘F` |
| Find files by name | `⌥⌘F` |
| Find in file contents | `⇧⌘F` |
| Search by meaning | `⌃⌘F` |
| As list / icons / columns | `⌥⌘1` / `⌥⌘2` / `⌥⌘3` |
| Bigger / smaller / default icons | `⌘+` / `⌘-` / `⌘0` |
| Toggle hidden files | `⇧⌘.` |
| Toggle sidebar | `⌃⌘S` |
| Show folder tree | `⇧⌘T` |
| Refresh | `⌘R` |
| Sort by name / size / kind / date / extension / created | `⌃⌘1`–`⌃⌘6` |
| Reverse sort | `⌥⌘R` |
| Fit columns to content | `⌥⌘=` |
| Quick Look | `Space` or `⌘Y` |
| Preview and details panel | `⌥⌘I` |
| Disk map | `⇧⌘U` |
| Recents | `⇧⌘Y` |
| Branches | `⇧⌘B` |
| Hide from screen sharing | `⌃⌘P` |
| Show transfers | `⌥⌘J` |
| Clean This Folder (when enabled in Settings › Clean) | `⌃⌘L` |
| Edit settings.json | palette or View menu |
| Reveal in Finder | `⇧⌘R` |
| Open in Terminal | `⌃⌘T` |
| Open in editor | `⌃⌘E` |

Rename works in every view, with an editor over the name itself: opaque, centred on its row, the
extension left out of the selection. Escape cancels; clicking elsewhere commits.

Search can skip whatever `.gitignore` excludes; it is off by default and the count skipped is
reported alongside the results.

`/` only starts filtering when the file list has keyboard focus, so it never swallows a slash you
are typing into a text field. Escape leaves the filter and clears it; Return keeps the filter and
moves focus to the results.

`⌘X`, `⌘C`, `⌘V`, `⌘A`, and `⌘Z` use the standard AppKit selectors. In a text field they edit text;
in the file list they act on files. `h`, `j`, `k` and `l` are deliberately not menu shortcuts — the
keyboard-first preset below handles them in the file list, so they never shadow typing in a field.

## Git

Reading a repository needs nothing turned on. Switching branches does: Settings › General ›
"Git actions that change the repository (beta)". With it off, git stays display-only, which is
what the rest of the application promises.

A switch is refused while there are uncommitted changes, and the files are named. Nothing here
stashes, forces or resets on your behalf.

## Keyboard-first preset

Off by default. Turn it on in Settings → General, from the command palette
(`Keyboard-First Keys`), or by setting `"keyboardFirst": true` in `settings.json`. These keys work only when the file list has focus, so
they never interfere with typing in a field.

| Keys | Action |
| --- | --- |
| `j` / `k` | Down / up |
| `J` / `K` | Extend the selection down / up |
| `g g` | First item |
| `G` | Last item |
| `⌃d` / `⌃u` | Half a page down / up |
| `h` | Enclosing folder |
| `l` | Open the selection |
| `H` / `L` | Back / forward |
| `/` | Filter this folder |

A letter with no binding still starts a type-select, so typing a filename to jump to it keeps
working. `g` on its own waits one second for a second `g` and then gives up, so a stray press
cannot change what the next key means.

## Conflicts are caught by a test

`Tests/SoquelCoreTests/CommandTests.swift` walks the whole menu and fails if two commands claim the
same shortcut. This exists because `⇧⌘W` was once assigned to both Close Window and Close Pane, and
the window quietly won — pressing it quit the app instead of closing a pane.
