# Code review and macOS 27 migration

Reviewed on September 15, 2026, starting from `10a8f38`.

## Scope

Reviewed the dictionary parser and decompressor, SQLite and import/resource
paths, search and tab state, WebKit page lifecycle and native bridges,
translation, speech and credential handling, tests, and build/release scripts.
Changes address reproduced defects and update the supported platform.

## Confirmed findings and fixes

| Area | Problem | Fix and regression coverage |
| --- | --- | --- |
| LZO decompression | A truncated extended-length sequence read past its input buffer. AddressSanitizer reproduced a heap-buffer-overflow. | Bound the scan before dereferencing input; use remaining-byte checks. Tests cover truncated instruction variants and a valid extended literal. |
| CI release build | An escaping Combine callback shared a mutable local search snapshot array across suspension points. The optimized compiler rejected it. | Store observations in an explicitly main-actor-isolated recorder. Compile optimized app-core sources with warnings as errors. |
| WebKit network policy | Imported HTML child documents could make network requests in offline mode because only generated pages had a Content Security Policy. | Apply the policy to dictionary resource responses, including imported documents. Exercise the real scheme handler with a child-frame network probe. |
| WebKit recovery | A terminated content process left a blank page whose identity prevented an ordinary reload. | Force reconstruction from the tab's current destination, including a navigation that SwiftUI has not delivered yet. |
| Dictionary links | Decoding before splitting a URL confused an encoded `#` in a headword with a fragment. | Separate encoded URL components first; test encoded `#`, encoded `?`, and queries followed by fragments. |
| CSS companions | Nested CSS references such as `../fonts/body.woff2` were rejected before resolution against the stylesheet directory. | Resolve relative and package-root paths before checking the package boundary; test successful imports and blocked traversal. |
| MDD volumes | Adding one to an untrusted numeric filename suffix overflowed for `Int.max`. | Sort using a separate base-volume rank and an unsigned part number. |
| MDX key blocks | Partial trailing keys and per-block entry-count mismatches could be silently accepted. | Consume the entire block and verify its declared count; test both direct lookup and import indexing. |
| SQLite values | Text containing NUL was truncated, empty blobs could become NULL, and binding failures were ignored. | Bind/read explicit byte lengths, preserve empty blobs, and report SQLite binding errors. |
| SQLite statement lifetime | A prepared statement could outlive its unowned connection and trap while reporting an error. | Retain the connection until statement finalization; test an error after the caller releases its connection variable. |
| Translation source | An English sentence beginning “Translate…” could displace the dictionary's Chinese instruction boundary. | Prefer the Chinese boundary and retain the English source sentence; verified with a regression that failed before the change. |
| DeepL annotations | The request used XML-only `ignore_tags` while selecting HTML processing. | Protect dictionary annotations with HTML `translate="no"` and restore the bare dictionary markers in the response. |
| App packaging | A hard-coded `.build/release` path does not match Swift 6.4's default build output. | Ask SwiftPM for `--show-bin-path` with the same configuration and SDK used for compilation. |

## macOS 27 migration

- `Package.swift` now requires Swift tools 6.4 and macOS 27.0.
- The app bundle advertises the same macOS 27.0 minimum.
- Packaging uses the selected SDK, honors `SDKROOT`, and rejects SDKs older
  than macOS 27. It no longer forces the installed SDK 26.
- CI uses GitHub's `xcode-27` arm64 runner and its default complete Xcode
  toolchain. Both the host OS and SDK are checked before building.
- CI builds debug and release configurations with warnings as errors, runs
  parser and tab-state tests in both configurations, and includes translation
  tests, WebKit checks, and bundle validation.
- The checkout action uses its Node 24 generation. Historical macOS 26 release
  notes and the existing screenshot retain their original version labels.

The failed hosted run was
[CI 34697557084](https://github.com/yichenzhu1/lexicon/actions/runs/34697557084).
Its debug build and tests passed; the production compile failed at the
`snapshots.append` Combine callback in `TabStateTests.swift`.

GitHub currently supplies macOS 27 through the public-preview
[`xcode-27` runner](https://github.blog/changelog/2026-09-10-xcode-27-runner-image-now-runs-on-macos-27/).
The inspected [runner manifest](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)
lists macOS 27 and Xcode 27 with SDK 27 as the default toolchain.

## Validation and remaining limits

Local validation uses macOS 27.0, Apple Swift 6.4, and SDK 27.0.

- All 72 parser/storage tests passed in both debug and release with warnings
  treated as errors. The local Command Line Tools emitted linker warnings
  about absent developer search directories; no Swift diagnostics failed.
- All 70 translation tests passed against the actual sources: 42 cloud-service,
  13 Apple-service, and 15 model tests. Network requests were intercepted.
- The actual app-core sources, including `EntryWebView.swift` and
  `TabStateTests.swift`, compiled with `-O -whole-module-optimization`, Swift 6
  language mode, and warnings as errors. Tab-state tests and six page-loading
  checks passed.
- Both offline security checks passed in real WebKit using the actual
  `DictSchemeHandler` and imported root/child HTML documents. The existing
  `RenderSmokeTest` also passed: three isolated dictionary frames rendered
  from basic, encrypted, and UTF-16 fixtures with their stylesheet resources.
- AddressSanitizer reproduced the original LZO failure. The corrected decoder
  rejected that input cleanly and passed 100,000 malformed inputs plus 1,000
  compression/decompression round trips under AddressSanitizer.
- Packaging checks with substituted compiler/signing tools passed for default
  SDK selection, an explicit SDK path containing spaces, dynamic binary output,
  and rejection of SDK 26 without deleting an existing bundle. Real SDK 26.5
  selection was also rejected with the expected diagnostic.
- Shell/Perl syntax, workflow YAML parsing, and `git diff --check` passed.

The installed standalone Command Line Tools lacks the `SwiftUIMacros` plugin
required by SDK 27's SwiftUI `@State`. Consequently a complete GUI build,
foreground search-focus test, and signed app-bundle validation cannot be
completed on this installation. The app-core and translation checks use
standalone harnesses with the real source files, excluding the views that
require the missing plugin. Use complete Xcode 27 for the full commands in the
README.

Changes are local. A new hosted GitHub Actions run has not been executed, so
the remote workflow's green status remains to be confirmed after pushing.
