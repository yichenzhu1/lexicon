# Changelog

All notable changes to Lexicon are documented here.

## Unreleased

- Raised the deployment target and app bundle minimum to macOS 27, with
  Swift 6.4 and the macOS 27 SDK. Packaging uses the selected SDK, rejects
  older SDKs, and resolves SwiftPM's binary output directory dynamically.
- Fixed the release-only Swift concurrency error in the search regression
  recorder that failed GitHub CI. CI now uses the macOS 27 / Xcode 27 runner,
  checks debug and release builds explicitly, and runs translation regressions.
- Fixed an out-of-bounds read in LZO decompression on truncated extended
  lengths. Malformed MDX key blocks now reject partial keys and entry-count
  mismatches, and large numeric MDD filenames no longer overflow during sorting.
- Nested dictionary CSS now imports parent-relative fonts and images while
  keeping resource paths inside the dictionary package.
- SQLite bindings preserve embedded NUL characters and empty blobs, report
  binding failures, and keep connections alive for prepared statements.
- Entry links now distinguish encoded `#` and `?` characters in headwords from
  URL fragments and queries. Tabs rebuild their current page if WebKit's
  content process terminates.
- Dictionary resource responses enforce the content network policy, closing
  an offline-mode bypass through imported HTML child documents.
- Translation source extraction preserves sentences beginning with
  “Translate…” before Chinese instructions. DeepL uses HTML annotation
  protection for the dictionary's `n` and `o` markers.
- Fixed delayed tab-focus requests overriding outside clicks. Initial search
  focus now uses a SwiftUI lifecycle task, and native clicks handle focus
  transfer without a window-wide mouse monitor. Added real-scene regressions
  for activation, selection, dismissal races, and marked-text composition.
- Simplified tab and search state around one location per tab. New queries
  immediately clear stale results, Return keeps the keyboard-selected result,
  and dictionary changes refresh searches. Repeated navigation preserves scroll.
- Page construction and dictionary audio loading now run off the main actor.
  Superseded pages and old-document bridge messages cannot update a new location.
- Dictionary files open on demand, resource prefix lookups use index ranges,
  and binary resources avoid unnecessary full-text decoding. Imports publish
  the final folder and index in one transaction, with atomic record-cache updates.
- Reduced parser allocations and repeated HTML processing; added repeatable
  performance benchmarks and regressions for cancellation, Unicode, resource
  volumes, import visibility, and page lifecycle.
- Fixed late translation tests overwriting newer status, preserved Keychain
  access errors, and clarified history trimming when restoring default settings.
- Translation settings now own their preferences and cancellable test state;
  dictionary translations run independently and report errors in their passage.
  Cloud providers share one request pipeline, and fetch/WebSocket adapters share
  one cleanup path for completion, cancellation, timeout, and page navigation.
- Apple Translation uses a separate installed-language session per request,
  with missing or unsupported languages reported by the translation operation.
  Settings shows availability and download instructions inline, refreshes when
  returning from System Settings, and opens Translation Languages directly
  from its manage button. Removed automatic setup alerts and the availability
  check before each translation; no in-app download session is created.
- Removed the hidden SwiftUI translation host and continuation queue, so local
  translations no longer depend on a window remaining open.
- Fixed multi-line source extraction, incomplete model responses being accepted
  as translations, and translation requests continuing after cancellation or
  page navigation. Added offline provider, Apple service, and WebKit regressions.

## 0.3.0 — 2026-08-31

- Search now uses an indexed trigram path for substring and typo candidates,
  recognizes adjacent-letter transpositions, catches mistakes at the start of
  a word, cancels obsolete work, and avoids repeating the prefix query between
  incremental phases. Existing libraries upgrade their search index in place.
- Added OpenAI, DeepSeek, Google Gemini, and Anthropic Claude as live
  translation providers alongside Alibaba DashScope. Each provider has an
  editable model name and its own API key stored in macOS Keychain.
- Google Cloud Translation credentials are now sent in the recommended
  `x-goog-api-key` header instead of being embedded in request URLs.
- Fixed Oxford `OX` controls colliding across dictionary frames, including
  entries from multiple dictionaries, while preserving per-frame scrolling,
  anchors, and native translation compatibility.
- Toolbar controls no longer initiate accidental window dragging, the search
  row has more usable width, and duplicate focus changes on scene activation
  have been removed.
- Updated the app icon.
- Sidebar section changes now use one consistent, direction-aware horizontal
  transition: the Lexicon/History/Starred thumb glides while each section's
  status row and list travel together as one pane, without vertical jumping.
- The toolbar controls now sit 2pt lower (was 1pt), which equalizes the
  visible gaps around the search field: the space above it to the window's
  top edge and the space below it to the tab pill are now both ~7pt, instead
  of the field reading closer to the top.
- The sidebar toggle now shares the toolbar row's optical vertical correction;
  it sat 1pt higher than the back/forward and trailing toolbar buttons, so the
  window's top row of controls reads as one aligned row.
- Unified every divider on one spec: a 1pt rule in the system separator color
  at full strength. The sidebar/content divider was effectively invisible
  (drawn at 38% strength over a same-tone material seam) and now reads as a
  real line; the entry page's CSS hairlines (jump-bar edges, dictionary
  section separators) share the same color via `--lexicon-hairline` instead of
  three different hard-coded grays.
- Liquid Glass across the chrome layer on macOS 26: the toolbar's back,
  forward, bookmark, dictionaries, and new-tab buttons and the sidebar toggle
  are interactive glass grouped in GlassEffectContainers (neighbors merge and
  separate as a unit), the Lexicon/History/Starred thumb is a glass segment
  that morphs between sections, and the zoom HUD and library notice banner
  float as glass overlays. The dictionary manager's Import, Done, and
  import-cancel buttons use the system glass button styles, with Done
  prominent.
- Release packaging now validates the bundle signature, supports Developer ID
  notarization and ticket stapling, and emits a SHA-256 checksum alongside the
  archive.

## 0.2.0 — 2026-08-17

- Live translation for compatible OED/ODE/Longman repacks, with Apple
  Translation (on-device, default), Google Cloud, DeepL, and Alibaba DashScope
  providers; dictionary-bundled credentials are intercepted before they can
  leave the page, and keys are stored in macOS Keychain.
- Sentence text-to-speech for compatible ODE/OALD repacks using system voices
  (default) or Google Cloud Chirp 3 HD voices.
- Reworked Settings with new Speech and Translation sections.
- Faster dictionary import.
- Fixed dictionary frames constantly resizing themselves: the height
  measurement no longer reads viewport-bound values, and sub-2px changes are
  ignored so a frame's own resize cannot retrigger itself — this removes both
  the oversized blank tail below entries and the constant up-down twitching
  of the lower dictionary sections.
- Safari-pattern chrome: capsuled toolbar button groups, a separate
  full-width tab row with Liquid Glass tabs and a Liquid Glass lookup field
  on macOS 26 (flat fills on older systems), and the new-tab button in the
  toolbar's trailing capsule.
- The Lexicon/History/Starred control animates its selection thumb gliding
  between segments (list content no longer slides), and the control now
  shares the tab row's height and the list rows' insets.
- The sidebar divider is back, drawn above both columns exactly on the
  boundary; the back arrow, tab row, dictionary chips, and entry content
  share one left inset, and the trailing buttons share one right inset.
- The lookup field now matches the toolbar capsules' 32pt height and grows
  wider (up to 560pt).
- Minimalist entry page: flat dictionary sections separated by hairlines
  instead of rounded cards, under a translucent sticky jump bar with an
  expand/collapse-all control; no redundant headword banner.
- Sidebar: Starred gains a count line like History, and idle sections show
  guidance text.
- Search results restore the previously browsed section when the field is
  cleared, and Escape clears the search.
- Tabs can be reordered by dragging, closed with a middle click, and managed
  from a context menu (Close Other Tabs, Close Tabs to the Right); ⌘1–⌘9
  switch tabs by position.
- Sidebar width, visibility, and section are remembered across launches;
  double-clicking the divider resets the width; zoom changes show a brief
  percentage indicator; starring a word animates the bookmark.

## 0.1.0 — 2026-08-08

Initial public preview.

- Search all enabled MDX dictionaries from one field.
- Browser-style windows, tabs, and per-tab back/forward navigation.
- Collapsible, dynamically sized dictionary entries with working resources,
  cross-references, and pronunciation audio.
- Dedicated Lexicon, History, and Starred sidebar views.
- Configurable entry text size, double-click lookup, and history limit.
- Dictionary import, enable/disable, reorder, rename, and removal controls.
- Native macOS app icon, dark interface, keyboard shortcuts, and Settings.
- Apache License 2.0 distribution with preserved third-party MIT notices.
