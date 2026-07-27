# trysoquel.com

The landing page. One static HTML file, its assets, and nginx.

## Deploying

```sh
railway up --service soquel-web --detach
```

Railway project `soquel`, service `soquel-web`, port 8080. The domain is on Porkbun.

## The download link

`index.html` links to the GitHub releases page rather than serving the disk image from here.
Change the single `<a id="download">` when the release moves. Nothing else references it.

The disk image itself is built by `../scripts/make-dmg.sh` and is not committed — it is a build
artefact, and a 2.4 MB binary in git history is one that never leaves.

## Assets

`logo.png` and `favicon.png`, both generated from the application icon:

```sh
magick ../Support/icon/icon-1024.png -resize 256x256 assets/logo.png
magick ../Support/icon/icon-1024.png -resize 64x64  assets/favicon.png
```
