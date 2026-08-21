# Settings

Every setting is a plain JSON file in `~/Library/Application Support/Soquel/`.
Nothing is locked behind the interface: anything the app can set, you can set by
hand, and anything you set by hand takes effect without a restart.

| File | Holds |
| --- | --- |
| `settings.json` | Behaviour, view state, keyboard remaps, sidebar layout, toolbar contents, session |
| `theme.json` | The colours in force, and the background image |
| `workspaces.json` | Saved pane and tab layouts |
| `recents.json` | Recently opened, moved, renamed and trashed files |

## Version numbers

The three numbers say who a release is for.

| Example | Means |
| --- | --- |
| `2.0.0` | A big release. The shape of the application changed. |
| `1.2.0` | A sequential release. Finished work, for everybody. |
| `1.2.1` | A nightly. The day's work, for people who want it early. |

So the middle number moves for sequential releases and the last one moves for
nightlies. `updateChannel` picks which of the two this copy follows. On
`stable` you are offered 1.2.0, 1.3.0 and 2.0.0 and never a nightly. On
`nightly` you are offered those and 1.2.1, 1.2.2 in between.

The channel decides by the number, not by GitHub's prerelease flag: a
sequential release marked beta while it is being tried out is still
sequential, and reaches the stable channel.

## The one request that is not opt-in

`checkForBadBuilds` is on by default, and it is the only thing Soquel asks a
server without being told to. It reads `https://trysoquel.com/advisories.json`
— one static file, the same for every reader — and compares the versions in it
with this build. Nothing about the machine is sent, and no server is told what
is installed; the comparison happens here. It is on by default because a
withdrawn build can lose files, and a warning nobody switched on warns nobody.
Settings › Updates turns it off, and off is respected.

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
| `hideFromScreenSharing` | bool | `false` |
| `gitActions` | bool | `false` |
| `showHiddenFiles` | bool | `false` |
| `foldersFirst` | bool | `false` |
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
| `metadataColumns` | array of column ids | `[]` |
| `sortOrder` | object | date modified, newest first |
| `shortcutOverrides` | object, command id → shortcut | `{}` |
| `sidebarLayout` | object | favourites, locations, folders |
| `shelfPaths` | array of paths | `[]` |
| `savedSearches` | array of objects | `[]` |
| `recentServers` | array of addresses | `[]` |
| `sessionPanes`, `sessionActiveTabs` | arrays | restored on launch |
| `syncBrowsing` | bool | `false` |
| `perFolderViewSettings` | bool | `false` |
| `folderViewSettings` | object, path → view and sort | `{}` |
| `columnViewWidth` | number | `240` |
| `columnWidths` | object, column id → width | `{}` |
| `expandedTreeFolders` | array of paths | `[]` |
| `verifyTransfers` | bool | `false` |
| `checkForUpdates` | bool | `false` |
| `checkForBadBuilds` | bool | `true` |
| `updateChannel` | `"stable"`, `"nightly"` | `"stable"` |
| `autoInstallUpdates` | bool | `false` |
| `catchFinderLaunch` | bool | `false` |
| `followFinderTarget` | bool | `false` |
| `acknowledgedAdvisory` | string | unset |
| `confirmHeavyLaunches` | bool | `true` |
| `heavyApplications`, `launchWithoutAsking` | arrays of bundle ids | built-in list, `[]` |
| `applicationKinds` | object, file kind → bundle id | `{}` |
| `semanticRoots` | array of paths | `[]` |

Toolbar action ids are `back`, `forward`, `up`, `listView`, `iconView`,
`columnView`, `hidden`, `folderSizes`, `gitStatus`, `inspector`, `folderTree`,
`foldersFirst`, `find`, `findContents`, `newFolder`, `split`, `terminal`,
`editor`, `reveal`, `transfers`, `palette`, `favourite`, `copyPath`, `openWith`,
`diskMap`, `shelf`, `compare`. The three view modes draw as one segmented pill
when they sit next to each other.

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
