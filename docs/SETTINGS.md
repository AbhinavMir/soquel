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
| `credentials.json` | API keys for Clean This Folder, one per provider. Mode 0600, never printed, never opened by the application |

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

## Clean This Folder

**Off by default.** Settings › Clean turns it on. With it off there is no
`⌃⌘L`, no menu item, no toolbar button and nothing in the command palette, and
no key is asked for. Turning it on adds a ✦ button you can put in the toolbar
by right-clicking the bar.

`⌃⌘L` is the only feature that sends the contents of files anywhere. It reads
one folder — names, and the first 4 KB of each text file — and asks Anthropic's
API how the folder should be arranged. Nothing moves until the plan is on
screen and the rows are ticked.

Three things are true of it and are worth stating plainly:

### Where the question goes

Any service, or nothing at all. Two wire formats cover the field: Anthropic's
own `/v1/messages`, and the `/chat/completions` shape OpenAI defined, which
Ollama, LM Studio, llama.cpp, OpenRouter, GLM, DeepSeek, Groq and Together all
answer to. Anything speaking either can be typed in as a custom provider.

| Preset | Wire | Key |
| --- | --- | --- |
| Ollama, LM Studio, llama.cpp | chat | none — runs here |
| OpenRouter | chat | one key, many models |
| Anthropic | anthropic | yes |
| OpenAI, GLM, DeepSeek, Groq, Together | chat | yes |
| Anything else | either, your choice | your choice |

**The default is Ollama**, because a model on this machine sends nothing over a
network at all, which for a feature that reads your files is the best answer
available. Settings › Clean probes the local ports and says which of them is
actually running, and asks a server for its model list so a name can be picked
rather than remembered.

A plan is read from a tool call in either wire, and — for small local models
that ignore the tool and write JSON into their reply — from the first complete
JSON object in the text.

- **The API key is in `credentials.json`, mode 0600, not in `settings.json`.**
  One key per provider, so switching between them does not mean pasting a key
  again. Not the Keychain: a Keychain item's access control trusts the one
  binary that wrote it, and every update is a different binary, so every update
  asked for a login password to reach a key the user had already given. A
  password prompt on each update is worse than the thing it protected against. That file is
  plain text, meant to be edited by hand, and is what somebody pastes into a
  bug report. Settings › Clean sets and removes the key.
- **Some files are never opened.** `.env` and anything ending `.pem`, `.key`,
  `.p12` and the rest of the list in `CleanSanitiser.neverRead` are listed by
  name and not read. Hidden files are not gathered at all.
- **Anything that looks like a key, token or password is replaced with
  `[removed]` before the request is made, and your files on disk are never
  changed by any of it.** "Show What Would Be Sent" prints the exact text.

`globalFolders` are folders that files may be filed into from anywhere. A file
in `~/test1` can be moved to `~/test2/abc` when that folder is global, with
nothing written about it — the mark is the instruction. A plan may never put a
file anywhere except the folder being cleaned or one of these.

`folderContext` is a sentence per folder saying what it is for. It is given to
the model when that folder is cleaned and when it is a candidate destination.

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
| `cleanFolder` | bool | `false` |
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
| `cleanProvider` | string, provider id | `"ollama"` |
| `cleanEndpoint` | string | preset's own |
| `cleanWire` | `"anthropic"`, `"openai"` | `"openai"` |
| `cleanModel` | string | preset's suggestion |
| `folderContext` | object, path → sentence | `{}` |
| `globalFolders` | array of paths | `[]` |
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
`diskMap`, `shelf`, `compare`, and `clean` while that beta is on. The three view modes draw as one segmented pill
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
