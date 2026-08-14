# Build notes

Two independent build steps. Neither is required to just run the app (`index.html` and
`jellydinosaur-flash-player.swf` at the repo root are already built and ready to use) — these are
only needed if you're modifying the Flash player source or want to regenerate the minified bundle.

## 1. Compiling the Flash player

Source: [flash-player-src/JellyDinosaurFlashPlayer.as](flash-player-src/JellyDinosaurFlashPlayer.as)
(single file, no external assets — no `.fla` project needed).

Built with the **Apache Flex SDK** (`mxmlc`), which is fully open source (Apache License 2.0) — no
Adobe Animate or paid tooling required.

### Prerequisites

- A JRE (`java -version` should work — `brew install openjdk` if not).
- Apache Flex SDK 4.16.1 binary:
  https://archive.apache.org/dist/flex/4.16.1/binaries/apache-flex-sdk-4.16.1-bin.tar.gz
- `playerglobal.swc` for Flash Player 9.0 (Apache Flex doesn't bundle it — Adobe's own download
  page is defunct, use this community mirror of the official releases instead):
  https://raw.githubusercontent.com/nexussays/playerglobal/master/9.0/playerglobal.swc

### One-time setup

```bash
# Extract the SDK somewhere, e.g.:
tar -xzf apache-flex-sdk-4.16.1-bin.tar.gz -C flex-sdk

# Place playerglobal.swc where mxmlc expects it:
mkdir -p flex-sdk/apache-flex-sdk-4.16.1-bin/frameworks/libs/player/9.0
cp playerglobal.swc flex-sdk/apache-flex-sdk-4.16.1-bin/frameworks/libs/player/9.0/
```

### Compile

```bash
export PLAYERGLOBAL_HOME=full link to the playerglobal home

flex-sdk/apache-flex-sdk-4.16.1-bin/bin/mxmlc \
  -target-player=9.0 -swf-version=9 \
  -static-link-runtime-shared-libraries=true \
  -output jellydinosaur-flash-player.swf \
  flash-player-src/JellyDinosaurFlashPlayer.as
```

Why Flash Player 9.0: it's the lowest version that compiles this source without any API
restrictions (verified — no feature used here requires anything newer), so there's no reason to
target higher and narrow compatibility for nothing. H.264/AAC playback itself additionally
requires Flash Player 9 Update 3 (9,0,115,0) or later on the runtime side — that floor comes from
the codec, not from this SWF's declared version.

Copy the resulting `jellydinosaur-flash-player.swf` to the repo root (replacing the existing one)
and re-run the minification step below so `upload/` picks up the change too.

## 2. Minified bundle (`upload/`)

```bash
node build-minify.js
```

Regenerates `upload/index.html` (minified `index.html`) and copies `jellydinosaur-flash-player.swf`
and `hls.min.js` alongside it. Requires Node.js with internet access on first run (uses `npx` to
fetch Terser on demand for JS minification; no other network access happens).

Kept deliberately conservative to never break ES3/old-browser compatibility:
- JS is minified with Terser targeting `ecma=5` explicitly, with `arrows`/`arguments`/`typeofs`
  transforms disabled — nothing that could introduce syntax newer than what's already in the
  source (which is plain ES3 to begin with).
- CSS/HTML are only whitespace-collapsed and comment-stripped, not restructured — no aggressive
  HTML minifier that could alter markup semantics (e.g. the file relies on real spaces between
  some inline elements, like `</span> <input>`, which a naive minifier would strip and visually
  break).

Run this after any change to `index.html` or to the Flash player SWF, to keep `upload/` in sync.
