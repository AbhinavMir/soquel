# trysoquel.com

The landing page. One static HTML file and its assets, served by GitHub Pages.

## Deploying

Push to `main`. `.github/workflows/site.yml` runs on any push touching `site/`, uploads this
directory as the Pages artefact and deploys it. There is nothing to run by hand;
`workflow_dispatch` is there to redeploy without a change.

The custom domain is `trysoquel.com`, registered on Porkbun and pointed at GitHub Pages. The
workflow writes `CNAME` into the artefact because Pages reads the domain from there, not from
the repository setting.

Railway is no longer involved.

## The download link

`index.html` links straight at the disk image on the GitHub release. Change the single
`<a id="download">` when a new version is cut, and the version in the `.note` line under it.
Nothing else references either.

The disk image itself is built by `../scripts/make-dmg.sh` and is not committed — it is a build
artefact, and a 2.4 MB binary in git history is one that never leaves.

`scripts/build-app.sh` runs `swift build -c release`, which builds for the host architecture
only, so the image is arm64 and the page says Apple silicon. A universal binary is not planned.

## When a deploy does not happen

The workflow triggers on a push touching `site/`. GitHub occasionally does not queue a run for
one, and `gh workflow run site.yml --ref main` can answer 500 or sit queued. A fresh commit
touching this directory is the reliable way to force it.

## Assets

`logo.png` and `favicon.png`, both generated from the application icon:

```sh
magick ../Support/icon/icon-1024.png -resize 256x256 assets/logo.png
magick ../Support/icon/icon-1024.png -resize 64x64  assets/favicon.png
```

Both are content-hashed in their filenames, so a changed image is a changed URL and no cache
has to be persuaded to let go of the old one.
