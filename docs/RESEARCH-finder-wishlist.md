<!-- Generated from parallel web research across community forums, competitor
     feature sets, and reviews. 97 raw findings from four independent sweeps,
     deduplicated to 47. Every entry is grounded in a cited source. -->

# Soquel — consolidated feature demand, ranked

97 raw findings deduplicated to 47 distinct wants. Ranking is demand volume × severity of Finder's failure, ignoring build cost. Four independent researchers converged on the top tier; where only one researcher surfaced an item, that is called out.

---

## Most requested

**1. Cut with ⌘X, paste-as-move with ⌘V, plus a "Cut" item in the context menu** — *small*
All four researchers put this first. Finder lacks the binding entirely; ⌘C then ⌥⌘V is the workaround and people reject it as undiscoverable and inconsistent with every other macOS app ("in TextEdit you Cmd-X to cut text"). Switchers hit it on day one and never stop complaining.
*Evidence: very strong.* Ask Different's canonical question 212 votes / ~200k views (2011, still active); HN threads 2009, 2012, 2015, 2016, 2020, 2022, 2023, 2025; r/MacOS threads 2019, 2021, 2024, May 2026; Sindre Sorhus sells a $4 app that does only this, plus multiple free clones shipped by people who "didn't feel like paying $4"; TotalFinder sold it as one of six headline features.

**2. Persistent expandable folder-tree sidebar — tree left, contents right (Explorer / Dolphin layout)** — *medium*
The single most common reason people go looking for a Finder replacement at all. Finder's sidebar is a flat favourites list. Users explicitly reject the two standard answers: list-view disclosure triangles force you out of icon/preview view and don't persist; column view "is not a tree, it's a bunch of columns — if you have to reach a directory 10 levels down you end up with a mess."
*Evidence: very strong.* Three of four researchers; r/macapps "worthy Finder replacement" 81 comments (Aug 2024), "Finder replacement" 81 comments (Jun 2026); r/MacOS 227-comment thread (Jan 2024) "I still haven't found a tree view"; HN "Why doesn't OSX Finder have a proper tree view?" (2012) through Nov 2025 and Jul 2026.

**3. Filename search that walks the real directory tree, defaults to the current folder, and does not hide anything** — *medium*
Soquel has filename and content search; **the expectation goes materially beyond that**. Four specific sub-demands recur: (a) scan the filesystem, not the Spotlight index — "I KNOW a file exists and I KNOW EXACTLY where it is, yet it doesn't show up in any way whatsoever"; (b) default scope = current folder, not This Mac; (c) literal substring matching on names, ranked above content hits — "search 'Google Chrome' in Applications, top results are MarketingAnalytics.yaml"; (d) do not silently exclude ~/Library, hidden and system files. Windows' Everything is the named benchmark.
*Evidence: very strong.* Apple Communities thread 254081462 with **98 "Me Too"** (Aug 2022); r/MacOS "Why is Finder's search tool so useless?" 187 pts / 75 comments (Mar 2026); r/mac "Finder search is an absolute shitshow" 67 comments (Apr 2025); the identical complaint on r/mac in 2011; Ask Different "Set the default search to current folder?" 45 votes, "Searching by file name" 40 votes / 78k views; Bloom and Find Any File are both sold on exactly this premise.

**4. Folder merge as the default, with per-file conflict decisions including skip-identical and keep-newer** — *medium*
Soquel has keep-both / replace / skip. **The gap is folder-level**: Finder's Replace on a same-named folder nukes the destination tree with no Trash and no undo, Merge appears only while holding Option and only in narrow cases. People treat this as a data-loss bug, not a preference. The missing decisions beyond keep-both/replace/skip are: apply-to-all across an operation, "replace only if newer", and "skip identical".
*Evidence: very strong.* r/MacOS Jan 2025, 81 pts / 53 comments — top reply "the most dangerously idiotic default behavior in Finder" (46 pts), "you can't undo it either, you have to revert a backup" (20 pts); r/mac Feb 2025 "this destroyed 80 something PDF files"; Apple Communities 8238943 asking for `cp -iR` parity; Fileside's blog post and MacRumors "it deletes the old instead of merging".

**5. Right-click → New File, with a template list and arbitrary registered types** — *small*
Finder offers only New Folder. The highest-voted Finder question on Ask Different by a wide margin, and it keeps spawning single-purpose apps (New File Menu, Right Click App, NewFile, Easy New File). Motivation is location, not speed: you are eight folders deep and want a file *there*. Requested refinement: read the system's registered types rather than hardcoding — "I'm just as likely to want an empty HTML file as a Pages file, or a Python file or an .xlsx."
*Evidence: very strong.* Ask Different 321 votes / **612k views** (2013) and 113 votes / 146k views (2013); r/macapps Jan 2026 52 pts / 45 comments; MacPowerUsers Mar 2024; all four researchers.

**6. A real transfer engine: queue, throughput and honest ETA, pause/resume, continue-past-errors, no long pre-scan** — *medium–large*
Six separate findings collapse here, all pointing at the same thing: Finder's copy sheet is informationally bankrupt and unsafe for bulk jobs. Specifics people name: no MB/s readout ("No. There's just the progress bar." — Apple Communities Level 10 reply); a corrupt file aborts the whole copy silently; "Preparing to copy" takes 5+ minutes on 1,000–2,000 photos before any bytes move; two concurrent copies to one device thrash instead of queueing; cancelling a large transfer half-works.
*Evidence: very strong.* Apple Communities 255011539 (Jul 2023); MacRumors "most reliable way to copy large amounts of files" (2022) and "Preparing to copy photos from memory card takes very long" (Jul–Oct 2024); Ask Different "Fastest and safest way to copy massive data" 140 votes / **283k views**; HN Apr 2024 "I have to babysit the copy like it's a five year old riding a bike"; ForkLift, Commander One, Marta and CopyQueue all ship the queue.

**7. Become the de facto default — intercept "Reveal in Finder", Desktop double-click, and open/save dialogs** — *large*
The number-one reason people abandon a replacement they otherwise like. Not a Finder complaint; a **replacement-product** complaint, which makes it disproportionately important for Soquel specifically. QSpace's interception is repeatedly the deciding purchase factor: "with QSpace I never have to see Finder again." Bloom users complain the Desktop still opens Finder. Uploading a file from a browser drops you back into Finder.
*Evidence: strong.* r/macapps "Looking for 'Finder' Alternative" 64 comments (Dec 2025); r/macapps Aug 2024; r/MacOS "Finder Replacement" (Mar 2026); Ask Different "How to change Finder as the default File manager"; Rascal thread (Jun 2026) on removing Finder from the Dock. Partial coverage is achievable without SIP; full Desktop takeover is not.

**8. Editable address bar you focus with one key, paste a path into, and tab-complete** — *small*
Soquel has copy-path in six formats; this is the inverse and is not implied by it. ⇧⌘G is judged a worse substitute, not an equivalent: modal, slower, no completion, no suggestions. "If Finder added this one feature I'd be overjoyed." "Why should I need a keyboard shortcut to bring up a text box that every other decent file browser includes by default?" Pairs with fuzzy go-to-folder as WhimFiles' lead feature.
*Evidence: strong.* Ask Different 88 votes / 79k views; HN Dec 2014, Mar 2017, Dec 2021, Mar 2022, Sep 2025, Jul 2026; AnandTech "Finder, THE biggest thing I hate about OSX".

**9. Return opens the selection and plain Delete trashes it — as shipped defaults, not just as remappable keys** — *small*
Soquel has remappable shortcuts, so the mechanism exists. **The demand is that these be the defaults or a one-click switcher preset**, because people evaluate a replacement in the first five minutes and the discovery path matters: Bloom shipped "Use Return to Open Files" and users still had to ask in-thread where it was. "The one reason I run away from Finder is that it has no way to set 'Enter' to open or 'Delete' to delete files."
*Evidence: strong.* Ask Different 97 votes / 83k views and 71 votes / 49k views; HN Spacedrive thread (Oct 2023), "first-time Mac user" (Apr 2022); r/MacOS 163-comment thread (Feb 2024); XtraFinder and TotalFinder both shipped it as a headline toggle.

---

## Frequently requested

**10. Folder sizes as a real, background-computed list-view column, plus a total for a multi-selection** — *medium*
A named purchase trigger: "I bought Bloom and it's cool but doesn't calc folder sizes which is a must for me. I bought QSpace after 5 minutes of the demo." Finder's Calculate All Sizes is off by default, per-window, slow on deep trees, and reports zero or wrong values (it counts each hardlink as a separate copy and HFS+-compressed files at logical size). Get Info on ten folders opens ten windows.
*Evidence: strong.* Ask Different "combined file size of selected files" 95 votes / 50k views and "size of multiple folders" 29 votes; HN "MacOS Finder Shows Zero-Size Folders" 61 pts; eclecticlight (May 2024, Apr 2023); DaisyDisk's own FinderMismatch documentation.

**11. First-class SFTP / FTPS / WebDAV / S3 locations in the sidebar with saved credentials and SSH-agent support** — *large*
The reason a large share of the addressable market is on ForkLift rather than Finder. Finder has no sftp:// at all and read-only plain FTP (and accepts ftps:// URIs while silently using plain FTP). Currently the top blocker holding people back from the newer replacements: "No SFTP Support 😭 need ssh/sftp with ssh agent support for 1Password. Forklift does this" (9 pts); "the developer promised to significantly improve network support in v1.7 — that's the piece I miss the most" (19 pts).
*Evidence: very strong.* Ask Different 134 votes / **285k views**, still the reference answer 15 years on; r/macapps Bloom threads (Oct 2025, 219 comments; Dec 2025); an entire market — CloudMounter, Mountain Duck, ExpanDrive, Transmit, Commander One PRO.

**12. Fast SMB browsing, and network favourites that reconnect after reboot** — *large*
Benchmarked against a Windows VM on the same Mac and losing: "the window stays blank for two or three seconds"; "MacOs SMB is shit slow and buggy" (30 pts). Known contributors people name: .DS_Store being written and re-read on the share, and thumbnail generation. The cheap adjacent win is the reconnect bug — favourites survive reboot in the sidebar but refuse to connect, so you re-mount manually every time. Bloom shipped exactly that fix and announced it.
*Evidence: strong.* r/MacOS Jun 2026 44 pts / 27 comments; Feb 2026 43 comments; Jeff Geerling's benchmark post 98 pts (Apr 2024); Studio Network Solutions KB; HN 2016–2025. Honest caveat: much of the slowness is in Apple's SMB client, so a third-party app can improve listing behaviour and caching but cannot fix the transport.

**13. Browse into .zip / .7z / .rar / .tar.gz / .iso as folders, with drag-out partial extraction** — *medium*
Called table stakes for a replacement. Finder double-clicks to explode and has no RAR or 7z support at all. On one Dec 2025 launch thread "Can it browse archive files?" drew 10 pts and "Crucial function for a finder replacement, imo" drew 13; the developer shipped it in-thread.
*Evidence: strong.* Three researchers; every commander-style competitor ships it (Marta, Nimble, Commander One PRO, ForkLift, QSpace, Bloom); Cult of Mac calls it a Bloom standout.

**14. Live type-to-filter that narrows the current listing as you type, plus fuzzy find across the subtree** — *small*
Distinct from search and cheap. Finder has only type-ahead select, which jumps to the first prefix match and is itself unpredictable ("50/50 guess whether it searches the selected folder or the parent"). What people want is the ranger/fzf/Everything reflex: type "pdf", see only PDFs. A Path Finder subscriber of many years, on why he quit both: "there is no quick 'fuzzy find in a subtree' fzf-like functionality."
*Evidence: strong.* HN Show HN Jul 2026 (98 pts / 75 comments), Mar 2015, Apr 2022; AlternativeTo ForkLift and Path Finder comment threads; ForkLift "Quick Select", Marta "Quick Search".

**15. Batch rename: regex, chained rules, saved presets, live preview, sequential numbering, EXIF tokens** — *medium*
Finder has batch rename since Yosemite but it is find-and-replace / add-text / numbering, no regex, no preview, no rule chaining, and its "Name and Date" inserts the *current* timestamp rather than capture date. Two extra asks: commit-and-advance-to-next-file on one key (Windows Tab behaviour — one user scripted a four-keystroke macro to fake it), and stop live-re-sorting the list mid-edit so the file you just renamed doesn't leap out of view.
*Evidence: strong.* All four researchers; r/MacOS Apr 2026 44 comments; Apple Communities 252244975 and 253919073; A Better Finder Rename has sold into this since 2010; the single most-praised feature in ForkLift and Path Finder user reviews.

**16. Arbitrary, sortable metadata columns in any folder — dimensions, resolution, video duration/codec/bitrate, EXIF, audio tags — with inline editing** — *small–medium*
Soquel has multi-column sorting; the gap is the *set of available columns*. Finder gates media columns behind an undocumented hack: Dimensions and Resolution appear only in a folder literally named "Pictures", duration and codec only in one named "Movies". Users reject the workaround — "my video files are spread out over many folders." MacMost documents the trick and says outright he hopes Apple removes the need for it.
*Evidence: strong.* Apple Communities 255609402 with **18 "Me Too"** (May 2024), where the accepted reply confirms Finder cannot do it and points at Windows Explorer; MacMost's writeup; r/MacOS Mar 2026; MacRumors 2015; HN 2012, Mar 2025, Jul 2026. Note the Folders app developer shipped all Core Services metadata keys plus EXIF within two weeks of the 2026 thread — this is a fast, visible win.

**17. Auto-size columns to the longest filename, persistently** — *small*
An entire commercial app (Bloom) launched on this behaviour. People know the double-click-the-divider trick and reject it: "This is only temporary. OP wants this as the default." Refinement: size to names *below the fold*, not just visible ones. macOS Tahoe added a "Resize Columns to Fit Filenames" checkbox and the same thread has "4 months later and the option is gone."
*Evidence: strong.* r/MacOS Apr 2025 82 pts / 40 comments; Apple Communities 254062313 (13 "Me too"); HN 2012, Mar 2017, Jul 2026. **Related structural note: Soquel's stated views are list and icon only. Several findings here assume a column view exists — if it doesn't, that is itself an unlisted gap, since column view is the one part of Finder power users actually like.**

**18. View settings that persist per folder, inherit into subfolders, and have a real global default** — *small–medium*
Two complaints in one. (a) Finder forgets — view mode, sort order, column widths and window size all revert, and there is no supported "apply to everything". (b) Going one level deeper resets the view: this was the first substantive complaint on Bloom's launch thread and the developer shipped an "Inherit Panel View Options" setting in v1.0.4 in response. Also wanted: per-folder sort overrides ("Downloads by date modified, everything else by name").
*Evidence: strong.* MacRumors Aug 2024 "Setting one View Options for all folders system wide" — "I haven't ever been able to do that in OSX. It was possible in OS9"; Ask Different "default finder window size" 79 votes / 130k views; HN Oct 2025 "macOS not remembering Finder's window size is a never ending source of annoyance"; r/macapps Bloom launch 316 comments.

**19. List a 10k–100k-file directory instantly — stream entries, defer thumbnails and sizes to a non-blocking background pass** — *large*
Workflow-stopping for anyone with a RAID or NAS of media. "Several seconds or several minutes" on ~10,000 files over Thunderbolt; a Promise RAID takes "several minutes to populate". Adjacent and much cheaper: a **per-volume** thumbnail toggle, because Finder's ⌘J "Show icon preview" is per-window with no local-vs-network distinction — "400 30MB TIFs over the network and it grinds to a halt, unusable." One developer shipped a per-volume toggle plus an extension exclusion list in the same HN thread it was raised in.
*Evidence: strong.* MacRumors Apr–Sep 2023 (3+ pages); Apple Communities 255728472, 256205645; HN May 2025, Apr 2024, Jul 2026. This is also Soquel's clearest differentiator opportunity — it is a fundamentals problem, not a feature checkbox.

**20. Idle cheap: low RAM, no background CPU spikes, small binary** — *medium*
A well-received post exists solely about abandoning paid file managers over this: "Both QSpace and Bloom routinely use over 1 GB. They are often the most RAM-hungry apps running other than browsers." Corroborated: "Bloom idles in the background at 50 to 80% of one core"; "for something as omnipresent as a file explorer that's unacceptable, ESPECIALLY if you're paying for it." People comparison-shop on footprint and praise Nimble Commander and ForkLift for it; a recent Show HN led its title with "9 MB, no Electron".
*Evidence: strong.* r/macapps Mar 2026 64 pts / 56 comments; r/macapps Mar 2025, May 2023. Treat as a shipping constraint, not a feature.

**21. Fully offline: no account, no licence phone-home, no telemetry, no subscription** — *small*
Repeatedly the reason a technically-best-in-class app gets rejected. On QSpace: "I love it but it requires an account and a phone-home to China every month or two. I keep that connection blocked until it pops up." The principle as stated by a prospective beta tester: "As the main application that's going to have access to *all* my private files, any automatic data collection — even anonymous usage statistics — is a red flag." Path Finder's move to subscription is cited by name as why people left it: "I'm not interested in paying a subscription to view my own files."
*Evidence: strong.* r/macapps Jun 2026, Mar 2025, Oct 2023 (93 comments), Oct 2025. Cheap to honour, expensive to reverse.

**22. Saved multi-pane workspaces — reopen a named 2/3/4-pane layout of specific folders in one action** — *medium*
Soquel has multiple panes with tabs and session restore; **named, switchable, per-project layouts are a step beyond restore-what-was-open**. A stated purchase reason: "Workspace was the main reason I purchased Bloom. I did not come across any other app that can automatically open preset folder location layouts with up to a four-pane setup. If anyone knows of one, please give me a heads-up." (Asked twice, in two threads.) QSpace users ask for "at least 4 panes with customizable sizes and savable configurations."
*Evidence: strong.* r/macapps Mar 2026, Jun 2026; Fileside's entire pitch; ForkLift, QSpace and Bloom all ship it.

**23. Get Info equivalent with editable POSIX permissions, and privileged operations inside the app** — *medium*
A concrete blocker that sends replacement users back to Finder, which makes it more damaging than its raw volume suggests. "It has advanced functionality but is missing basic functionality that keeps it from being an app I can actually use instead of Finder: no native Get Info window — launches Finder instead. No way to change file permissions in app. Can't delete files that require permission to delete." Echoed a year later: "it cannot access folders that need higher privileges. When that happens it tells you to open Finder. 🙃"
*Evidence: moderate but pointed.* r/macapps Oct 2025 (219 comments), Jun 2026 (81 comments).

**24. Up-one-level toolbar button** — *small*
Trivially small, mentioned spontaneously in nearly every Finder-complaint thread, and even Finder's defenders concede it. "Just add an Up Directory button and you'll be infinitely better than Finder." ⌘↑ exists but is undiscoverable and there is no visible control.
*Evidence: moderate, but unusually consistent.* HN Apr 2024 (three separate commenters in one thread, including a Finder defender), Jul 2026.

**25. A drag shelf — park files mid-drag, navigate freely, drag off elsewhere** — *medium*
Finder lacks it entirely. The problem is real and mechanical: drag-and-drop demands you hold the button while navigating to the destination. Yoink and Dropover both have devoted followings — "As important to me as the CMD key"; "When I get a new Mac, this is the first thing I download after Chrome"; Daring Fireball covered Dropover in May 2026. Path Finder ships "Drop Stack", QSpace ships "Stash Shelf".
*Evidence: strong for the need, thinner as a *file-manager* feature* — one researcher surfaced it, and the demand currently routes to dedicated shelf apps rather than to file managers. Multi-pane plus cut/paste addresses much of the same pain.

**26. Recent folders (not recent files) as a persistent sidebar group, plus reopen-recently-closed-window** — *small*
Finder's Recents is file-oriented and the Go menu's list is short. Folder recall is how people actually navigate. Default Folder X's entire business is this; ForkLift 4.2.3 shipped a Recent Folders sidebar group (Jan 2025).
*Evidence: moderate.* One researcher; mostly vendor and competitor convergence rather than loud user threads, but the convergence is total.

---

## Recurring but narrower

**27. Verified copy — checksum source and destination, report a per-file pass/fail manifest** — *medium*
ForkLift's vendor calls checksum calculation "one of the most frequently requested features, especially by users who work with large files, backups, or remote transfers." Frame.io's workflow guide: "macOS transfers the data and assumes it worked... bits can get dropped and Finder won't catch it." A whole paid category exists (ShotPut Pro, Hedge/OffShoot, Silverstack). Narrow audience (media/post), high willingness to pay.
*Evidence: moderate, concentrated in one professional segment.*

**28. Side-by-side folder compare with one-way/two-way sync** — *large*
Finder has nothing. ForkLift's second headline feature after dual-pane, and it supports a cottage industry (DirEqual, Compare & Sync Folders, Folder Sync Pro). Users who have it complain about speed, not existence — "40 seconds to analyse 30k files".
*Evidence: moderate.* Mostly vendor feature lists and one Apple Communities thread rather than organic complaint volume. Real demand, but quieter than the vendor emphasis implies.

**29. Duplicate finder — hash-based, review-before-delete, undo, and whole-folder duplicate detection** — *medium*
Finder lacks it; the recommended workaround is hand-built Smart Folders plus Quick Look. The consistent lesson from recent tools is about the *after*, not the scan: "the real failure mode is unclear selection, risky bulk deletes, and no way to audit or undo." Unmet ask: detect duplicate *folders* and subsets, not just files.
*Evidence: moderate.* Apple Communities standing thread; HN Mar 2026, Feb 2026, Aug 2021.

**30. Disk-space treemap with correct sizes — hardlinks counted once, compressed files at physical size** — *medium*
DaisyDisk documents that Finder "wrongly counts each hard link as another copy" and counts HFS+-compressed files uncompressed; Howard Oakley has a post titled "The Finder confuses with wildly inaccurate figures for available space". DaisyDisk/GrandPerspective/OmniDiskSweeper are on essentially every "apps I install on a new Mac" list, which is the demand signal — but also means the need is already well served by free tools.
*Evidence: moderate.*

**31. Quick Look on a folder that previews its contents** — *small*
Soquel has Quick Look; folder preview is the gap. People press space on a folder and expect something. Two separate community-built plugins landed well (109 pts Nov 2025, 69 pts Oct 2024) and Sindre Sorhus's Folder Peek is the standard paid recommendation.
*Evidence: moderate.* Cheap, visible, pairs naturally with archive peeking.

**32. Sync browsing — selecting or scrolling folders in one pane live-previews contents in the other** — *small*
Disproportionately loved when it appears: "I asked if when scrolling folders in the left pane I could view their contents in the right; he added it the same day" (30 pts) → "That's Sync Browsing. Surprisingly useful." (17 pts). Cheap given panes already exist, and it delivers much of what people reach for when they ask for tree-view-plus-content-pane.
*Evidence: thin — one thread — but the cost/benefit is unusually good.*

**33. Tags: more than seven colours, whole-row colouring, and a store that survives exFAT and network volumes** — *medium*
Three failures. Only seven colours (a three-bit legacy label field). Tags silently vanish on exFAT externals and are unsearchable on network shares because Spotlight doesn't index them — a steady stream of "tags not working with external drive" threads. And a visual regression: Finder stopped highlighting the whole row, which is a named reason someone still pays for Path Finder ("which offers whole-line highlighting of tagged files").
*Evidence: moderate.* Multiple Apple Communities and MacRumors threads; eclecticlight "Solving Finder tag problems" (Dec 2024). Only meaningful for people who actually tag, which is a minority — but a vocal, workflow-dependent one.

**34. Create real POSIX symlinks, not Finder aliases** — *small*
Developers hit the asymmetry constantly: `ln -s` links behave as aliases in Finder, Finder aliases are invisible to the shell, and Finder's own Services create an alias when you wanted a symlink. SymLink Helper exists solely for this.
*Evidence: moderate, developer-segment only.* Small enough to be worth doing regardless.

**35. Column view that doesn't spawn a horizontal scrollbar over the bottom row** — *small*
Old and very high-scoring: 786 pts / 143 comments on r/apple for the specific grievance that the scrollbar appears exactly over the file you were about to click. Resurfaces in 2024 lists as "disable horizontal scrolling". Largely solved by auto-sizing columns (#17) plus overlay scrollbars, so treat it as an acceptance criterion for column view rather than a separate item.
*Evidence: strong for the score, but a single old thread.*

**36. Trash on network volumes, or an honest per-volume policy** — *medium*
Dragging to Trash on a share deletes permanently — people discover this the hard way. Also reported as regressed: "Move to Trash no longer works when the source is a macOS share point." On NAS setups the shared .Trashes gets owned by whoever deleted first and everyone else gets the delete-immediately prompt.
*Evidence: moderate.* Real data loss, low volume.

**37. Show and edit ACLs, and apply POSIX modes recursively without misrepresenting them** — *medium*
Howard Oakley states Finder "hides the complexity of permissions by intentionally misrepresenting the full permissions of an item" and reduces ACLs to "custom access". Admins prefer chmod because "Finder limits you and makes assumptions for you"; TinkerTool System is the named GUI workaround. Sysadmin-only, but consistent.
*Evidence: moderate, narrow.* Natural extension of #23.

**38. App uninstaller that finds support files, caches and preferences** — *medium*
ForkLift ships it and reviewers name Finder's lack of one as a core problem. But the evidence here is almost entirely vendor marketing and AlternativeTo comments, and the space is saturated by AppCleaner (free) and CleanMyMac. **Demand is thin as a file-manager feature.** Low priority.
*Evidence: thin.*

**39. Thumbnails and Quick Look for CR3, ARW, PSD/PSB, AI without the originating app** — *large*
Real and painful for photographers — CR3 previews became "a black rectangle" after macOS 15.4; layered 16-bit PSDs show no icon without Maximize Compatibility (which doubles file size); PSB thumbnails reportedly broken "for about ten years". But this means writing or licensing decoders for proprietary formats, which is a large effort for a segment already served by Lightroom and Photo Mechanic.
*Evidence: moderate volume, very high effort.* Recommend deferring.

**40. Audio audition — waveform in preview, arrow-key auto-play through a folder, loop, BPM/key columns** — *medium*
Producers browsing sample libraries want to key down a folder and hear each file. AudioFinder has sold into this since 2003. Genuinely niche and well served by DAW browsers.
*Evidence: thin — one KVR thread.*

**41. Discoverable, non-overloaded keyboard navigation for VoiceOver users** — *medium*
Concrete and specific: ⌘O both enters a folder in Finder and accepts the selection in open/save dialogs, so the shortcuts are "overloaded"; expand-whole-subtree exists (⌥→) but is undiscoverable. Also an active accessibility bug where folders spontaneously revert to Column view while VoiceOver announces List view.
*Evidence: thin — one AppleVis thread (May 2024).* Listed because remappable shortcuts already exist in Soquel, so honouring this is mostly a matter of default choices and documentation.

**42. Vim keybindings as an optional layer** — *small*
Rascal led with "real vim keys (hjkl, /, dd, gg)" and drew 168 pts; Marta's whole audience is this. Newer and growing, but narrower than the command palette it usually travels with — which Soquel already has.
*Evidence: thin but rising.*

---

## Already covered by Soquel

The research confirms these are real, high-volume demands that Soquel's existing description already satisfies. Listed with any caveat where the common expectation exceeds the plain reading of the description.

| Want | Status |
|---|---|
| **Dual/multi-pane with copy-move between panes** | Covered by "multiple panes with tabs". This was the loudest structural complaint in the entire corpus — all four researchers, perennial. Worth confirming panes go to 3–4, since QSpace users say "I will never go back to a file manager that only allows two panes." |
| **Command palette** | Covered. Named as a lead feature by Rascal, Marta, ForkLift, QSpace, Fileside and WhimFiles. |
| **Undo for file operations** | Covered. Caveat: the demand specifically includes undo of **moves, merges and folder replaces**, not just renames — see #4. |
| **Copy path** | Covered, and six formats exceeds the ask. Note the demand is partly about *discoverability* — put it in the plain right-click menu, not behind a modifier. The inverse (typable path bar, #8) is not covered. |
| **Open in terminal, editor integration** | Covered. Very high volume (208 votes / **412k views**) — make it visible in the context menu and respect iTerm2/Ghostty, not just Terminal.app. An embedded terminal pane synced to the current folder is a further step (Marta, Nimble, Commander One PRO ship it) that is *not* implied. |
| **Git status** | Covered. Demand is genuinely thin — ForkLift is the only competitor shipping it and no organic complaint threads surfaced. A developer-segment differentiator, not broad demand. |
| **Hidden-file toggle** | Covered. Caveat: the expectation includes the state **persisting**, unobstructed browsing of `/`, `/tmp` and `~/Library`, and hidden/system files appearing in **search results** — see #3. ⌘⇧. was still a 1,352-point TIL on r/apple in 2018. |
| **Conflict handling (keep-both/replace/skip)** | Covered at file level. The folder-level merge default, apply-to-all, keep-newer and skip-identical are not — see #4, the highest-severity item in the corpus. |
| **Filename and content search** | Covered nominally. The substance of the demand — filesystem walk instead of Spotlight, current-folder default, name matches ranked first, nothing silently excluded — is #3. |
| **Multi-column sorting** | Covered. The gap is *which* columns are available (#16), not the sorting. |
| **Quick Look** | Covered for files. Folder preview (#31) and archive peeking (#13) are separate. |
| **Remappable shortcuts** | Covered. See #9 — the ask is about defaults and discoverability, not the remapping mechanism. |
| **Session restore** | Covered. Named saved workspaces (#22) are a distinct, purchase-driving step beyond it. |
| **List and icon views, customisable colours, settings window** | Covered. **Column view is not listed** — several findings assume it exists, and it is the one Finder view power users defend. Flagging as a possible unstated gap. |

---

### Honest notes on the evidence

- **Everything in "Most requested" is corroborated by at least three of the four researchers independently**, with primary sources (vote counts, view counts, comment counts) rather than vendor copy.
- **Items 27–42 lean progressively more on vendor feature lists and single threads.** Where a want appears only in competitors' marketing (#28 folder sync, #26 recent folders, #38 uninstaller), that reflects developers guessing at demand as much as users voicing it.
- **The three cheapest high-impact items are #1 (cut/paste), #5 (new file), and #8 (path bar)** — all small, all perennial, all things Finder simply does not have.
- **The two items most likely to decide whether people actually switch are #7 (become the default) and #19/#20 (fast on huge directories, cheap at idle).** Neither is a checkbox feature; both are why users abandon replacements they otherwise liked.