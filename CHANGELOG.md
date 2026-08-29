# Changelog

All notable changes to Lexicon are documented here.

## Unreleased

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
