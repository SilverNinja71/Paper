# Paper

A Mac + iPad art and photo studio in the spirit of Procreate, Photoshop and Lightroom. Usable now on Mac.

Cloud sync (Google Drive, Dropbox, OneDrive, iCloud Drive, local folders and drives) comes from **CommonKit**, this
repo's own copy of the sync engine.

The full brief is in [`docs/SPEC.md`](docs/SPEC.md).

## Build & run (Mac)

Needs macOS 14+ and the Swift 6 toolchain (Xcode or just the Command Line Tools).

```bash
Scripts/build-paper-app.sh       # builds Paper.app in this folder — double-click to run
swift test                          # unit + GPU tests (headless)
swift build -c release --product PaperSnapshots && .build/release/PaperSnapshots /tmp/paper-check
```

`PaperSnapshots` paints a demo artwork through the real engine, renders every brush, times the hot paths,
saves and reopens a file and screenshots every screen — without opening a window.

## Features

**Brush engine (Metal compute).** Pen input is stabilised (StreamLine "pulled string" + moving-average
stabilisation), interpolated with centripetal Catmull-Rom splines, resampled at the brush spacing, and
each dab gets its own size/opacity/flow/angle/roundness/colour from Apple Pencil pressure and tilt
(editable response curves), speed, taper and jitter. A compute kernel stamps batches of dabs into a stroke
buffer (each pixel composites its dabs in order, so there are no GPU race conditions), with analytic
anti-aliased round tips or texture tips, grain (moving or texturised), Photoshop-style dual brush, wet
edges and wet-mix colour pick-up. Smudge drags pixels along the path. Strokes merge into the layer on
pen-up, honouring opacity, selection, alpha lock and layer masks.

**31 free brushes** across Sketching, Inking, Painting, Watercolor, Charcoals, Airbrushing, Textures,
Halftones, FX, Concept and Smudge — all shapes and grains are generated procedurally, so nothing is
bundled and nothing is paywalled. **Brush Studio** edits every setting with a live preview.
Import/export `.paperbrush` (one brush, JSON), `.paperbrushset` (a pack) and Photoshop `.abr`
(sampled tips, v1/v2 and v6+).

**Community brushes.** Add any feed URL or shared folder; Paper lists its packs and installs them with
one click. A feed is just JSON anyone can host (GitHub, a website, a shared Dropbox/Drive folder):

```json
{ "name": "My Brushes",
  "packs": [ { "id": "inks-1", "name": "Ink Pack", "author": "Sam", "category": "Inking",
               "description": "Five inking pens", "url": "ink-pack.paperbrushset", "license": "CC0-1.0" } ] }
```

**Layers (Photoshop-grade).** Unlimited layers (bounded by memory), nested groups with Pass Through,
clipping masks, greyscale layer masks (paint white to show, black to hide), all 27 Photoshop blend modes
plus Pass Through (28), opacity, alpha lock, lock, Reference layer for fills, merge down, duplicate,
flatten group, drag-to-reorder. Layers are 16-bit float, wide-gamut Display P3, HDR-ready.

**Tools.** Brush, Smudge, Eraser, Lasso select (add with ⇧, subtract with ⌥), Move/Transform (move, scale,
rotate, flip; moves just the selection if there is one), Fill (flood fill that reads boundaries from the
Reference layer, with tolerance), Eyedropper (or hold ⌥ / right-click).

**Files.** Artworks are `.paper` packages in a gallery folder and save themselves a few seconds after you
stop. Saves are deltas: only layers whose pixels changed are rewritten, and `manifest.json` is written
last as the commit point. Export PNG (8/16-bit), JPEG, TIFF (16-bit), HEIC; import photos (incl. camera
RAW) as layers or open them as a new artwork for Lightroom-style editing.

### Shortcuts

| Key | Action | Key | Action |
|---|---|---|---|
| B | Brush | E | Eraser |
| S | Smudge | L | Lasso |
| V | Move / Transform | G | Fill |
| I or hold ⌥ | Eyedropper | `[` / `]` | Brush size |
| ⇧`[` / ⇧`]` | Brush softness | ⌘Z / ⇧⌘Z | Undo / Redo |
| ⌘J | Duplicate layer | ⌘E | Merge down |
| ⇧⌘N | New layer | ⌘G | Group layer |
| ⌘A / ⌘D / ⇧⌘I | Select all / Deselect / Invert | ⌫ | Clear selected pixels |
| Space + drag | Pan | ⌘⌥0 | Fit to screen |
| ⌘1 | Actual pixels | ⌘= / ⌘− | Zoom |
| Return / Esc | Commit / cancel transform | `\` | Paint on mask on/off |

Trackpad: two-finger scroll pans, pinch zooms, rotate rotates. iPad: Pencil paints, fingers pinch/rotate/
pan, two-finger tap undoes, three-finger tap redoes.

## Cloud sync (CommonKit)

Artworks are always saved locally first; sync runs in the background (10 s after you stop drawing, or
immediately when you switch apps). Only changed files upload, `manifest.json` goes last as the commit
point, and when two devices edit the same artwork both versions are kept
(`Name (Conflicted Copy 2026-10-26 14.30.05).paper`). Open **Cloud** in the gallery toolbar.

**No setup needed:** on a Mac with the Google Drive, OneDrive or Dropbox desktop app (or iCloud Drive), pick
that folder under *Locations* in the gallery — those apps sync the files themselves.

**Direct connections (needed on iPad):** each service requires a free "app registration" from you. Click
**Set Up Keys…** in the Cloud panel to create `~/Library/Application Support/Paper/CloudKeys.plist`,
then fill in:

| Service | Where to register | Put in CloudKeys.plist | Redirect URI to register |
|---|---|---|---|
| Google Drive | console.cloud.google.com → enable Drive API → OAuth client of type **iOS** with bundle ID `com.silverninja71.paper` | `googleDrive > clientID` | (automatic) `com.googleusercontent.apps.<id>:/oauth2redirect` |
| Dropbox | dropbox.com/developers/apps → Scoped access, `files.metadata.read/write` + `files.content.read/write` | `dropbox > clientID` (the app key) | `db-<APP_KEY>://2/token` |
| OneDrive | entra.microsoft.com → App registrations → any directory + personal accounts, *Mobile and desktop*, permission `Files.ReadWrite` | `oneDrive > clientID` | `msauth.com.silverninja71.paper://auth` |
| iCloud Drive | nothing (a signed app with the iCloud capability uses its own container; otherwise your iCloud Drive folder) | — | — |

Tokens are kept in the Keychain, sign-in uses PKCE (no secrets in the app), and requests retry with backoff.

## What's verified (2026-10-26)

- 202 automated tests pass: 69 Paper (painting, smudge, eraser, pressure, alpha lock, masks, clipping,
  groups/pass-through, merge, blend-mode maths, selection, fill, transform, files, brushes, `.abr`,
  shortcuts, every adjustment, photo import/export incl. a real DNG) and 133 cloud sync (all offline,
  against mocks and local folders). One of these now fails on this Mac, `bookmarkRoundTripResolvesTheSameFolder`, which
  depends on the machine rather than on the code.
- `PaperSnapshots` passes all checks, including Paper → local "cloud" folder → reopen end to end.
  Stroke updates ≈ 0.4 ms and a full 8-layer 2732×2048 recomposite ≈ 6 ms on the AMD Radeon Pro 5300.
- **Not yet verified:** hands-on use of the live app window (real mouse/tablet/trackpad input, menus,
  dialogs), real sign-in to Google/Dropbox/OneDrive (needs your keys), real iCloud, and running on an iPad
  (the code compiles for iPad with full Xcode, nothing more). Photoshop `.abr` v6+ parsing follows GIMP's documented layout but was only tested
  with a hand-built v1 file.

## iPad

To build for iPad: in Xcode, create an iOS App project (iPadOS 17+), add this folder as a local package, link
`PaperCore`, and use [`iPad/PaperiPadApp.swift`](iPad/PaperiPadApp.swift) as the app file. The iPad-specific code
(`#if os(iOS)` in `Input/PointerInput.swift` and `UI/PaperCanvasView.swift`) handles Pencil pressure and tilt, touch,
hover and gestures.

## Licence

Mozilla Public License 2.0 — see [`LICENSE`](LICENSE).
