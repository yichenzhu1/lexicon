# Changelog

All notable changes to Lexicon are documented here.

## Unreleased

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
