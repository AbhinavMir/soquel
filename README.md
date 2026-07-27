
# Soquel

The last file manager you'll ever need. And it's open source!

Free and MIT licensed. No licence key, no trial, no activation — nothing checks anything.

If you found it helpful, you can send USDC, USDT or ETH to `moonforger.eth`. Well established
tokens on other chains are fine too, Solana and Bitcoin included. Shitcoins get burned.

Questions or bugs: atg271@gmail.com

<hr>

## Status

Version 0.1 — the initial release scope is implemented and the app runs. See [Roadmap](#roadmap).

## Build and run

```sh
swift build            # library, executable, tests
swift test             # 26 tests
./scripts/build-app.sh # produces build/Soquel.app
open build/Soquel.app
```

Requires macOS 13 or later and a Swift 5.9+ toolchain.

## What works today

- Sidebar with home locations, mounted volumes, and your own favourites
- Up to four panes per window, split vertically or horizontally, each with its own tabs
- List view with name, size, kind, and date columns; click a header to sort, folders first by default
- Navigation by keyboard, breadcrumbs, an editable path field, history, and Git repository root
- Create, rename, duplicate, copy, move, trash, and permanent delete, all with per-file error reporting
- Conflict prompt showing both files' sizes and dates, with keep both / replace / skip / cancel
- Undo for rename, create, duplicate, trash, and move
- Copy path in six formats, plus a path relative to the Git root
- Command palette with fuzzy matching over every command
- In-folder filtering, hidden file toggle, Quick Look, drag and drop, Reveal in Finder
- Open the current folder in Terminal, or the selection in your editor
- Session restore: panes and tabs come back where you left them
- Customisable colours: View → Edit Colours… opens a JSON file; Reload Colours (`⌃⌘Y`) applies it live

## Keyboard

Press `⌘K` for the command palette, which lists every command with its shortcut.
Full reference: [docs/KEYBINDINGS.md](docs/KEYBINDINGS.md).

The essentials:

| Action | Shortcut |
| --- | --- |
| Command palette | `⌘K` |
| Split pane vertically / horizontally | `⌘D` / `⇧⌘D` |
| Close tab / close pane | `⌘W` / `⇧⌘W` |
| Focus pane by position | `⌘1`–`⌘4` |
| Filter the current folder | `/` or `⌘F` |
| Copy absolute path | `⌥⌘P` |
| Go to folder | `⇧⌘G` |
| Rename / open | `↩` / `⌘↓` |
| Quick Look | `Space` |
| Move to Trash | `⌘⌫` |

## Layout

```
Sources/SoquelCore/   application code
Sources/Soquel/       executable entry point
Tests/SoquelCoreTests/
scripts/               build-app.sh, serve-status.sh
docs/                  architecture, keybindings, security model
```

Everything lives in the `SoquelCore` library so it can be tested; the executable is six lines.

## Roadmap

Tracked in [docs/TODO.md](docs/TODO.md) — what is shipped, what is next, known gaps, and what has
been ruled out. Short version:

- 0.2 — nested pane splits, grid view, batch rename, operation queue panel, shortcut customisation
- 0.3 — folder comparison, workspaces, inspector, Git status column, saved searches
- 1.0 — column view, content search, full accessibility pass, contributor documentation

Explicit non-goals for 1.0: AI assistant, cloud sync, plugin marketplace, remote filesystems,
built-in terminal emulator, and replacing Finder at the system level.

## License

MIT. See [LICENSE](LICENSE).
