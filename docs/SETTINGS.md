# Settings

Every setting is a plain JSON file in `~/Library/Application Support/Soquel/`.
Nothing is locked behind the interface: anything the app can set, you can set by
hand, and anything you set by hand takes effect without a restart.

| File | Holds |
| --- | --- |
| `settings.json` | Behaviour, view state, keyboard remaps, sidebar layout, toolbar contents, session |
| `theme.json` | The colours in force |
| `Themes/*.soquel-theme` | Saved themes: colours, background and the image itself |
| `workspaces.json` | Saved pane and tab layouts |

Open the first one with **Edit settings.json** in the View menu or the command
palette, or reveal it in Finder from the same menu.

## Live editing

The directory is watched. Save a change from any editor and the app re-reads the
file, redraws the sidebar and toolbar, and rebinds shortcuts. A file that is not
valid JSON is ignored and the running settings stay in place, so a typo mid-edit
cannot break the app.

Writes from the app are coalesced and flushed on quit, so the file is never more
than a fraction of a second behind. The **Edit settings.json** command flushes
first, and always opens a current file.

## Keys

Anything absent falls back to the default in the right-hand column.

| Key | Type | Default |
| --- | --- | --- |
| `showHiddenFiles` | bool | `false` |
| `foldersFirst` | bool | `true` |
| `viewMode` | `"list"`, `"icon"`, `"column"` | `"list"` |
| `showFolderTree` | bool | `true` |
| `showInspector` | bool | `true` |
| `showGitStatus` | bool | `true` |
| `keyboardFirst` | bool | `false` |
| `calculateFolderSizes` | bool | `false` |
| `autoFitColumns` | bool | `true` |
| `iconSize` | number | `72` |
| `favouritePaths` | array of paths | `[]` |
| `terminalBundleID` | string | first installed |
| `editorBundleID` | string | first installed |
| `toolbarActions` | array of action ids | see below |
| `visibleColumns` | array of column ids | name, size, modified |
| `sortOrder` | object | name ascending, folders first |
| `shortcutOverrides` | object, command id → shortcut | `{}` |
| `sidebarLayout` | object | favourites, locations, folders |
| `shelfPaths` | array of paths | `[]` |
| `savedSearches` | array of objects | `[]` |
| `recentServers` | array of addresses | `[]` |
| `sessionPanes`, `sessionActiveTabs` | arrays | restored on launch |

Toolbar action ids are `back`, `forward`, `up`, `listView`, `iconView`,
`columnView`, `hidden`, `folderSizes`, `gitStatus`, `inspector`, `folderTree`,
`foldersFirst`, `find`, `findContents`, `newFolder`, `split`, `terminal`,
`editor`, `reveal`, `transfers`, `palette`. The three view modes draw as one
segmented pill when they sit next to each other.

## Example

```json
{
  "showHiddenFiles" : true,
  "viewMode" : "column",
  "iconSize" : 96,
  "terminalBundleID" : "com.googlecode.iterm2",
  "toolbarActions" : ["up", "listView", "iconView", "columnView", "hidden", "inspector", "terminal"],
  "shortcutOverrides" : {
    "view.inspector" : { "key" : "i", "modifiers" : ["command"] }
  }
}
```
