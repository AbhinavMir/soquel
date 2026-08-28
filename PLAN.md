# Working state

Branch: `main`. Soquel 1.7.0 is the current stable production release.

## Current release

- **1.7.0** promotes local AI first and requires hosted-data approval, including a BAA for PHI.
- **1.6.0** introduced the visible one-step Undo result for Clean This Folder.
- The 1.7.0 DMG is signed, notarised and stapled. Gatekeeper reports `accepted`, GitHub Latest is `v1.7.0`, trysoquel.com serves `Soquel-1.7.0.dmg`, and `/Applications/Soquel.app` is 1.7.0.
- 931 tests pass, with 1 skipped.

## Clean This Folder

- `⌃⌘L` or the ✦ toolbar button reads the current folder and proposes moves for review.
- Providers: Ollama, LM Studio, llama.cpp, OpenRouter, Anthropic, OpenAI, GLM, DeepSeek, Groq, Together and custom Anthropic/OpenAI-compatible endpoints.
- Local servers are detected and queried for their model lists. Local AI is the default and recommendation; Ollama is selected initially.
- Hosted providers require an explicit confirmation that the provider is approved for the files and that an executed BAA covers any PHI before an API key can be added or used.
- Hidden files are skipped, known secret-bearing files are never opened, key-shaped text is removed, and **Show What Would Be Sent** displays the exact request.
- Credentials are separate from settings in `~/Library/Application Support/Soquel/credentials.json`, created mode 0600. The feature does not use Keychain and does not cause update-time password prompts.
- Plans may move files only inside the current folder or into marked global folders. Folder context can describe a folder to the model.
- A clean is one undo-stack entry. The result reports files and folders affected and offers **Undo** beside **Done**; `⌘Z` works later.
- 1.5.0–1.5.2 remain on the advisory list because their Clean panel could wedge. 1.5.3 fixed the panel; 1.6.0 includes that fix.

## Open

- **#5 Disk map as a real DaisyDisk replacement.** Whole-disk scanning and the collector remain.
- **#4 SFTP without macFUSE,** as a File Provider extension.
- **#43 Preview `.sqlite`, `.db`, `.csv` and `.sql** without executing file contents.
- Shortcut import and export (#44).
- The Show HN draft on the Desktop predates the current release.

## Release conventions

- `X.0.0`: major release.
- `1.x.0`: finished sequential release for stable users.
- `1.x.y`: nightly or patch release.
- Apple silicon only; `scripts/build-app.sh` builds for the host.
- Read Finder `.DS_Store` files but never write them.
- `theme.json` is the only persisted theme format.
