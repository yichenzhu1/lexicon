# Lexicon

A native macOS dictionary app that reads **MDX/MDD** dictionary files — the
format used by MDict, GoldenDict, Eudic and friends. Import your own
dictionaries (Oxford, Merriam-Webster, Collins, Longman, …) and search all of
them at once, fully offline.

Lexicon ships no dictionary content. You supply `.mdx` files (with their
`.mdd` resource companions) that you have obtained yourself.

## Install

Lexicon requires macOS 14 or later. Download the ZIP for your Mac from the
[GitHub Releases](https://github.com/yichenzhu1/lexicon/releases) page, unzip
it, and move `Lexicon.app` to `/Applications`.

Release filenames include their supported architecture. The current build is
for Apple Silicon (`arm64`).

Files whose names end in `-unsigned.zip` are ad-hoc signed and have not been
notarized by Apple. macOS will normally block the first launch. Only if you
trust the download, try opening it once and then use **System Settings →
Privacy & Security → Open Anyway**. Apple explains this process and its risks
in [Open a Mac app from an unknown developer](https://support.apple.com/guide/mac-help/mh40616/mac).

## Features

- Unified search across every enabled dictionary (case- and
  diacritic-insensitive), in tiers: exact and prefix matches first, then
  substring matches, then near misses when nothing matched literally
- One collapsible card per dictionary for each looked-up word, rendered with
  each dictionary's own CSS/images/fonts served straight out of its `.mdd`.
  Collapsed dictionaries stay collapsed, and a jump bar appears when several
  dictionaries have the word
- Text zoom (⌘+ / ⌘− / ⌘0) and look-up-on-double-click, both remembered
  between launches and customizable in Settings (⌘,)
- Cross-reference links (`entry://`, `bword://`) and `@@@LINK=` redirects
- Pronunciation audio (`sound://` links) played from `.mdd` resources
- Dictionary manager: import, enable/disable, drag to reorder, rename, remove
- Stable, unique lookup history with a configurable record limit, plus starred
  words in the sidebar
- Supports MDX format v1/v2, zlib/LZO/uncompressed blocks, encrypted keyword
  index (Encrypted=2), UTF-8/UTF-16/GB18030/Big5 encodings, multi-part MDDs

MDX v3 files (produced by MdxBuilder 4.x) are not supported; rebuild those
with MdxBuilder 3.x.

## Internal builds

Requires macOS 14+ and the Xcode Command Line Tools (full Xcode not needed).

```sh
# Fast, unoptimized developer build
scripts/make_app.sh debug
open build/Lexicon.app

# Optimized internal build
scripts/make_app.sh release
open build/Lexicon.app
```

The version is stored in `VERSION`. Local builds are ad-hoc signed and are for
development or trusted internal testing only. Override the version or build
number when needed:

```sh
LEXICON_VERSION=0.1.0 LEXICON_BUILD_NUMBER=2 scripts/make_app.sh release
```

To make a ZIP for internal testers, first commit the source so the working
tree is clean, then run:

```sh
scripts/release.sh --unsigned 0.1.0 2
```

This writes an architecture-labelled ZIP and SHA-256 checksum to `dist/`.

## Public release without Developer ID

An unsigned public preview can be published immediately, but macOS cannot
verify its developer or notarization status. Users will see the warning
described in the Install section.

1. Update `VERSION` and `CHANGELOG.md`.
2. Run `swift run MdxKitTester` and `scripts/make_app.sh release`.
3. Commit all release changes and push `main`.
4. Create the unsigned ZIP from that clean commit:

   ```sh
   scripts/release.sh --unsigned 0.1.0 1
   ```

5. Tag the exact commit and publish the ZIP plus checksum:

   ```sh
   git tag -a v0.1.0 -m "Lexicon 0.1.0"
   git push origin main
   git push origin v0.1.0
   gh auth login
   gh release create v0.1.0 \
     dist/Lexicon-0.1.0-macOS-arm64-unsigned.zip \
     dist/Lexicon-0.1.0-macOS-arm64-unsigned.zip.sha256 \
     --title "Lexicon 0.1.0" \
     --generate-notes
   ```

6. On the GitHub release page, clearly state that this preview is not
   Developer ID signed or notarized and is Apple Silicon only.

## Signed public release

Public downloads should be signed with a **Developer ID Application**
certificate and notarized by Apple. First store notarization credentials in
your login keychain (use an app-specific password, not your Apple Account
password):

```sh
xcrun notarytool store-credentials "lexicon-notary" \
  --apple-id "you@example.com" \
  --team-id "YOUR_TEAM_ID"
```

`notarytool` securely prompts for the app-specific password instead of placing
it in the command or shell history.

Update `VERSION` and `CHANGELOG.md`, commit those changes, and make sure the
working tree is clean. Then build, sign, notarize, staple, package, and
checksum the release:

```sh
export LEXICON_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export LEXICON_NOTARY_PROFILE="lexicon-notary"
scripts/release.sh 0.1.0 1
```

The finished ZIP and SHA-256 checksum are written to `dist/`. Tag the exact
commit that produced them and attach both files to GitHub:

```sh
git tag -a v0.1.0 -m "Lexicon 0.1.0"
git push origin main
git push origin v0.1.0
gh release create v0.1.0 \
  dist/Lexicon-0.1.0-macOS-arm64.zip \
  dist/Lexicon-0.1.0-macOS-arm64.zip.sha256 \
  --title "Lexicon 0.1.0" \
  --generate-notes
```

Never commit signing certificates, private keys, Apple credentials, or
notarization passwords.

## License

Lexicon is licensed under the
[Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0). See
`LICENSE` for the full terms and `THIRD-PARTY-NOTICES.txt` for bundled
MIT-licensed components and test tooling.

## Import dictionaries

Drag a `.mdx` onto the window, or click the books icon in the toolbar (or
⇧⌘I) and choose one. Any sibling files sharing its base name (`Dict.mdd`,
`Dict.1.mdd`, `Dict.css`, …) are copied along with it and indexed. Everything
lives in `~/Library/Application Support/Lexicon/`.

If the `.mdd` companions were not beside the `.mdx`, the import still
succeeds but the dictionary has no images, audio or stylesheets. Lexicon says
so when that happens, and the manager flags the dictionary.

## Theming (custom.css)

Every entry page loads an optional `custom.css` from the dictionary's folder
in `~/Library/Application Support/Lexicon/Dictionaries/<id>/`, after the
dictionary's own stylesheets — drop a file there to restyle a dictionary.
The `themes/` directory contains ready-made themes that restyle
Merriam-Webster (`mw-lm6.css`) and OALD 10 (`oald-lm6.css`) repacks to match
the Longman 6 look (palette lifted from `lm6.css`, including dark mode).

## Tests

```sh
swift run MdxKitTester
```

The Command Line Tools ship neither XCTest nor swift-testing, so tests run
through a small standalone runner. Parser tests validate against fixture
dictionaries generated by the reference
[writemdict](https://github.com/zhansliu/writemdict) library
(`python3 tools/make_fixtures.py` regenerates them).

The suite also covers two things worth knowing about:

- **Damaged files.** Dictionary files are untrusted input, so every size and
  count in a header is validated. The corrupt-file tests feed the parser
  truncated, randomly damaged and deliberately oversized headers and require
  it to throw rather than trap. A regression shows up as the test executable
  crashing mid-run — that is the intended signal.
- **Concurrent access.** The library is read from the main thread and from the
  `dict://` handler's queue while imports run on their own queue, so the
  concurrency tests hammer it from many threads and check that reads stay
  available and correct during an import.

There is also an end-to-end render check that drives a real offscreen
WKWebView, useful after touching the page builder or the scheme handler:

```sh
swift run MdxKitTester seed /tmp/lexicon-smoke
LEXICON_ROOT=/tmp/lexicon-smoke swift run -c release Lexicon --smoke-test
```

## Project layout

- `Sources/MdxKit` — MDX/MDD parser, SQLite keyword index, dictionary library.
  `DictionaryLibrary` is thread-safe; reads run on pooled SQLite connections so
  an import never blocks a search.
- `Sources/Lexicon` — SwiftUI app (search UI, WKWebView renderer, `dict://`
  scheme handler). `LibraryModel` holds the one open library shared by every
  window; `AppState` holds one window's search field, results and tabs.
- `Sources/MdxKitTester` — standalone test runner
- `tools/` — fixture generator plus the vendored writemdict library

## Acknowledgements

- MDX format documentation: [writemdict fileformat.md](https://github.com/zhansliu/writemdict/blob/master/fileformat.md)
  and [mdict-analysis](https://bitbucket.org/xwang/mdict-analysis)
- LZO1X decompression provided by the MIT-licensed
  [lzokay](https://github.com/AxioDL/lzokay) implementation
- Test fixtures generated with [zhansliu/writemdict](https://github.com/zhansliu/writemdict)
