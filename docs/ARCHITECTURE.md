# Architecture

## Targets

`SoquelCore` holds every type. `Soquel` is a six-line executable that installs the app delegate.
The split exists so tests can reach the code; SwiftPM cannot link a test target against an
executable without duplicate-symbol trouble.

## Ownership

```
AppDelegate
└── MainWindowController          one per window; owns the menu command routing
    ├── SidebarViewController     favourites and mounted volumes
    └── PaneViewController × 1–4  one per visible pane
        └── FileListViewController × n   one per tab; only the active one is in the view tree
```

A window holds panes in a single `NSSplitView`. Splitting sets that split view's orientation, so
every pane in a window shares one direction; nested splits are a 0.2 item.

## Command routing

Menu items use `target: nil`, so actions travel the responder chain. `FileListViewController` sits
in the chain whenever the file list has focus, and `MainWindowController` sits behind the window.

Two consequences shaped the design:

- Commands that should follow focus (`copy:`, `cut:`, `paste:`, `selectAll:`, `undo:`) use the
  **standard AppKit selectors**. A focused text field's field editor handles them first, so ⌘C
  copies text while typing and copies files when the list has focus. Using custom selectors here
  broke text editing in every field.
- Commands that always mean the same thing (`menuSplitVertically:`, `menuGoUp:`) use custom
  selectors implemented only on `MainWindowController`, which forwards to the focused pane.

`CommandPalette` calls the same `MainWindowController` methods, so a palette entry and its menu
item can never drift apart in behaviour.

## Directory loading

`DirectoryLoader` enumerates on a background queue and carries a generation counter; when a pane
navigates away, the in-flight load's completion is dropped rather than applied to the new folder.

`DirectoryWatcher` wraps a `DispatchSource` file-system source. Events are coalesced over 150 ms.
A refresh that lands while a rename editor is open is rescheduled, never dropped.

`FileListViewController.reload()` returns early when the view is not loaded. Background tabs from a
restored session have no table view yet, and global commands like Toggle Hidden Files iterate every
tab in every pane.

## File operations

Everything that writes goes through `OperationEngine` on a background queue, reporting per-file
failures rather than aborting the batch. `resolveConflict` is called back on the main thread.

Two safety rules are load-bearing:

1. **Never treat a file's own path as a conflict.** Copying or moving an item onto itself is a
   no-op. Comparison resolves symlinks, so `/tmp/x` and `/private/tmp/x` are one file. Without
   this, "Replace" deleted the destination — which was the source — and the file was gone.
2. **Stage, then swap.** "Replace" copies or moves the incoming item to a temporary sibling name
   first, then removes the destination and moves the staged item into place. A failure at any point
   leaves the existing file intact. Removing the destination first meant a failed copy destroyed
   both files.

Copying a directory into its own subtree is rejected outright; it would otherwise walk the tree it
is writing into.

`UndoStack` holds closures that reverse a completed operation, built from what actually succeeded —
trash records the real in-Trash URLs, move records the real destinations. Operations that cannot be
reversed are never pushed.

## Paths

`parentDirectoryURL(of:)` is the only way to walk upward. `URL.deletingLastPathComponent()` appends
`..` once it reaches `/` instead of stopping, so a naive loop never terminates — this hung the app
at launch, in the breadcrumb builder.

## Theme

`Theme.swift` holds every colour, font, and metric. Colours are built with
`NSColor(name:dynamicProvider:)`, so light and dark are two designed palettes rather than one
inverted — each is chosen against its own ground.

**Selection is opaque, and its text inverts.** This started as a translucent tint of the accent,
which looked considered and read terribly: a wash over a light row still leaves dark text on a light
background, so a selected file was harder to read than an unselected one. The fix is the one
Windows 95 shipped — fill the row with a solid dark colour and turn the text white. `FileCellView`
carries a `restingTextColor` and flips to white while the row is filled, because cells that set an
explicit colour do not get AppKit's automatic inversion.

The accent is a deep navy (`#002780` light, `#669CFF` dark). Colour is spent in one place — focus and
selection — and everything else is neutral.

Selection and alternating rows are drawn by `FileRowView`, an `NSTableRowView` subclass, because the
system slab highlight cannot be tinted. An unfocused pane fills with solid grey and leaves its text
alone, so the two states differ by weight rather than by hue.

`isEmphasized` goes false whenever the table stops being first responder, including while a menu or
sheet is open, which turned a live selection grey mid-interaction. Focus is judged by whether the
window is key and the first responder sits inside that table.

Type carries the density: filenames use the system face, while sizes, dates, paths, and the status
bar use monospaced faces with tabular figures so digits align down the column.

## Testing

`swift test` runs 48 tests covering path handling, colour parsing, sorting, fuzzy matching, conflict resolution,
undo, and every regression above. `MenuTests` walks the whole menu and fails on duplicate shortcuts,
which is how ⇧⌘W being bound to both Close Window and Close Pane would now be caught.

## Customising colours

Seven slots — accent, selection fill, inactive selection fill, alternating row, chrome, hairline,
and danger — can be overridden per appearance from
`~/Library/Application Support/Soquel/theme.json`:

```json
{
  "light": { "accent": "#B3541E", "selectionFill": "#B3541E24" },
  "dark":  { "accent": "#E8A87C" }
}
```

`#RGB`, `#RRGGBB`, and `#RRGGBBAA` are accepted, with or without the hash. A slot that is absent —
or whose value does not parse — falls back to the designed default rather than to some other colour
that happens to be nearby; a wrong-but-present colour is worse than the built-in one.

View → Edit Colours… writes a template containing every slot at its current value, so the format is
discoverable by opening it. Reload Colours (`⌃⌘Y`) re-reads the file and posts
`.soquelThemeChanged`. The dynamic providers in `Theme` read the current config at draw time, so
most of the interface updates without rebuilding a view; layer-backed chrome caches a resolved
`CGColor` and refreshes in `PaneViewController.applyTheme()`, which also runs when the system
switches between light and dark.
