# Soquel

The last file manager you'll ever need. And it's open source!

Free and MIT licensed. No licence key, no trial, no activation — nothing checks anything.

If you found it helpful, you can send USDC, USDT or ETH to `moonforger.eth`. Well established
tokens on other chains are fine too, Solana and Bitcoin included. Shitcoins get burned.

Questions or bugs: atg271@gmail.com

<hr>

## Install

Download `Soquel.dmg` from [Releases](https://github.com/AbhinavMir/soquel/releases), open it, drag
Soquel to Applications. macOS 13 or later.

Signed and notarised, so it opens with a normal double-click.

From source:

```sh
swift build
swift test
./scripts/build-app.sh    # build/Soquel.app
```

## What it does

**Panes and tabs.** Split a window any number of ways, vertically or horizontally, each pane with
its own tabs and its own folder. `⌘1`–`⌘4` jumps between them. A layout can be saved as a workspace
and reopened later.

**Four views.** List with sortable columns, icon grid, folder tree, and column view.

**Search.** By name or contents, with contains, regex or glob. It reports what it skipped rather
than quietly returning less: too large, not text, unreadable folder, result cap. Optionally honours
`.gitignore`, including nested files and negation.

**Search by meaning** (`⌃⌘F`). Finds "financial results from the German branch" in a document that
says "the Berlin office reported strong quarterly revenue". Files are read and embedded once; after
that a query over a thousand passages takes under a millisecond. It runs on the language model macOS
already ships, on your own machine. Nothing is sent anywhere.

**Disk map** (`⇧⌘U`). Where the space went, as nested rings you can click into.

**File operations.** Create, rename, duplicate, copy, move, trash, delete. If one file fails the
rest still go, and it names the one that failed. Conflicts offer keep both, replace, skip or cancel,
with both sizes and dates shown, and folders can be merged instead of replaced. `⌘Z` undoes rename,
create, duplicate, trash and move.

**Transfer queue** (`⌥⌘J`). Throughput and progress per job, with pause, resume and cancel.

**Selection shelf** (`⌃⌘A`). Collect files from any number of folders, then deliver them all at
once.

**Batch rename.** Find and replace, regex, numbering, case, extension, trimming and file-date
insertion, with a live preview.

**Folder comparison** (`⇧⌘K`). Left only, right only, differs, same — compared by size and date or
by checksum — and sync in either direction over the rows you tick.

**Remote locations.** SMB, AFP, NFS, WebDAV and FTP, mounted through macOS itself.

**Everything is a file you can edit.** Settings, colours, shortcuts and the sidebar are JSON under
`~/Library/Application Support/Soquel/`. Edit one in another editor and the window redraws.

Full list with shortcuts: [trysoquel.com](https://trysoquel.com).

## Keyboard

`⌘K` opens the command palette, which lists every command and its shortcut. Every shortcut can be
rebound. Full reference: [docs/KEYBINDINGS.md](docs/KEYBINDINGS.md).

| Action | Shortcut |
| --- | --- |
| Command palette | `⌘K` |
| Split pane vertically / horizontally | `⌘D` / `⇧⌘D` |
| Focus pane by position | `⌘1`–`⌘4` |
| Filter the current folder | `/` |
| Search / search by meaning | `⌘F` / `⌃⌘F` |
| Go to folder | `⇧⌘G` |
| Rename / open | `↩` / `⌘↓` |
| Quick Look | `Space` |
| Move to Trash | `⌘⌫` |

## Layout

```
Sources/SoquelCore/    application code
Sources/Soquel/        executable entry point
Tests/SoquelCoreTests/ 683 tests
scripts/               build-app.sh, make-dmg.sh, install.sh
docs/                  architecture, keybindings, settings, security
```

The code is in the `SoquelCore` library rather than in the executable so that it can be tested.

## Asking things

[soquel.hamlet.so](https://soquel.hamlet.so/) is the forum: plain questions, "how do I",
"this is behaving oddly", ideas. No GitHub account needed.

[GitHub issues](https://github.com/AbhinavMir/soquel/issues) is for bug reports with steps to
reproduce, and feature requests to track against the code.

## Known gaps

There is no accessibility pass yet, and SFTP would need a File Provider extension that has not been
written.

Soquel does not replace Finder at the system level, and cannot. macOS refuses to reassign
`public.folder` to anything else — the call returns `paramErr`, and that applies to every
application, not just this one. Volumes can be reassigned, so double-clicking a disk opens it here,
and anything can be opened through Open With.

## License

MIT. See [LICENSE](LICENSE).
