# Lumber icon: "End grain"

A log's end grain: hand-wobbled growth rings, a drying crack and a purple
pith dot, in cream on near-black. Seen from above it's also a drumhead.

- `end_grain.py` generates the artwork (deterministic):
  `python3 docs/icon/end_grain.py docs/icon`
- `lumber-end-grain.svg` / `.png`: the app icon (full-bleed, iOS rounds the corners).
- `lumber-end-grain-mark.svg`: the transparent mark used in the app
  (`native/App/Resources/Assets.xcassets/Logo.imageset`).

PNGs were rendered with headless Chromium (the SVG uses a turbulence filter
for the printed edge), then flattened to RGB for the icon (no alpha).

Wordmark and headings: **Bricolage Grotesque** (ExtraBold for "lumber",
Bold for headings), SIL Open Font License 1.1, bundled in
`native/App/Resources/Fonts` with its licence.
