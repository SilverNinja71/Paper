# Paper — notes for Claude

One SwiftPM package for **Paper**, a Mac + iPad Procreate/Photoshop/Lightroom-style art & photo studio, with
**CommonKit** (Universal Cloud Sync Engine) as this repo's own copy. Forge, a separate CAD app, has its own repo and its
own copy, so a fix here doesn't reach it. The full brief is `docs/SPEC.md`; the README lists features.

## Build, test, verify

```bash
swift build
swift test                                    # Swift Testing; GPU tests render off-screen
COMMON_ONLY=1 swift test --scratch-path .build-common   # just the sync engine
swift build -c release --product PaperSnapshots && .build/release/PaperSnapshots <dir>
Scripts/build-paper-app.sh                  # Paper.app (don't `open` it while testing)
```

Plain `swift build` works with the Command Line Tools. For iPad, use Xcode 26.1.1 at `~/Downloads/Xcode.app`, which isn't
the active developer directory, so prefix commands with `DEVELOPER_DIR=$HOME/Downloads/Xcode.app/Contents/Developer`.
Then compile for iPad (no simulator installed):
`swift build --target PaperCore --triple arm64-apple-ios17.0 --sdk "$(xcrun --sdk iphoneos --show-sdk-path)" --scratch-path .build-ipad`.
`bookmarkRoundTripResolvesTheSameFolder` fails because of this Mac, not the code.

- `PaperSnapshots <dir>` paints a demo artwork, renders all brushes, times strokes/compositing, checks
  save/reopen/delta-save (prints ✓ / ✗ FAIL) and screenshots each screen via an `NSHostingView` in a window
  that is never shown. `.environment(\.paperSnapshotMode, true)` swaps the live MTKView for
  `renderCanvasSnapshot`. Look at the PNGs with Read. `--icon <png>` paints the app icon.
- Machine: Intel iMac, AMD Radeon Pro 5300 (read-write texture tier 2), the Command Line Tools are active (no
  iOS SDK, no offline `metal` compiler). Shaders are MSL strings (`ShaderModule`), compiled at runtime by
  `PaperGPU` with `ShaderCommon.source` prepended.
- `Package.swift`: tools 6.0. CommonKit uses Swift 6 language mode; PaperCore and the apps use Swift 5 mode
  (Metal objects aren't Sendable). `COMMON_ONLY=1` exposes only CommonKit targets.

## Paper architecture

- `Engine/PaperGPU` — device, queue, runtime shader cache, samplers, `IntRect`, CPU⇄GPU transfers
  (`readPixels`/`writePixels` as `SIMD4<Float>`, `readHalfData`/`writeHalfData` = on-disk layer bytes).
- Pixel convention everywhere: **premultiplied, gamma-encoded Display P3 in `rgba16Float`** (values may
  exceed 1 for HDR); masks/selections are `r16Float`. Only the present pass linearises (drawable is
  extended-linear Display P3).
- `Engine/BrushStudio` — `BrushPreset` (Codable = `.paperbrush`), `StrokeSample`, `StrokeStabilizer`
  (StreamLine + averaging), `DabGenerator` (centripetal Catmull-Rom, arc-length spacing, pressure/tilt/
  speed/jitter/colour dynamics), `Dab` (64-byte GPU struct). `Engine/PaintEngine` — stroke lifecycle:
  backup layer → `stampDabs` batches of 32 into the stroke buffer → compositor previews it live →
  `applyStroke` on pen-up → `RegionSnapshot` for undo. Smudge = per-dab blit + `smudgeDab`.
- Stroke buffer maths: each dab moves the buffer toward (colour × cap, cap) at rate coverage × flow;
  stroke opacity is applied when merging (Photoshop's opacity vs flow).
- `Compositing/Compositor` — walks the `LayerStack` (bottom→top) per dirty region: groups into isolated
  buffers (Pass Through blends straight into the backdrop, faded by opacity/mask), clipping = base into a
  buffer then clipped layers source-atop, adjustment layers filter the accumulator and `mixRegion` by
  opacity × mask. Scratch buffers are per (slot, depth). `Shaders/BlendModes` has all 28 modes.
- `Compositing/AdjustmentPipeline` + `AdjustmentModel` — Lightroom-style adjustment layers.
- `Document/CanvasDocument` (`@MainActor @Observable`) — layers, textures (`content`/`masks` dicts keyed by
  layer id), tools, colour, selection, transform, camera, undo (`UndoHistory`: closures + memory budget).
  Structural edits go through `structuralChange` (snapshots the tree + texture references; pixel-changing
  structural ops create **new** textures so old ones stay valid for undo). In-place pixel edits use
  `editPixels`/region undo. `SelectionAndTransform` adds lasso, flood fill (Reference layer aware),
  clear/fill, move/scale/rotate/flip, image import. `PaperFileFormat` — `.paper` package save/open with
  delta saves (revision counters; texture swaps bump revisions via `didSet`).
- `Document/PaperAppModel` — gallery folder, open/close, autosave (4 s idle) + `onProjectSaved` hook
  for cloud sync, import/export.
- UI: `PaperCanvasView` (MTKView + `CanvasRenderer` present shader + `CanvasController` tool logic +
  vector overlay), `PaperWorkspaceView`, `LayerManagerSheet`, `BrushPickerPopover` (+
  `BrushPreviewRenderer`, community feeds), `BrushStudioView`, `ColorPickerPanel`, `GalleryView`
  (locations incl. ~/Library/CloudStorage), `LightroomAdjustmentsView`.
- `Input/PointerInput` — NSView/UIView capture → `PointerEvent` (pressure, tilt, coalesced, hover);
  `Input/PaperKeymap` — pure shortcut table + `CanvasDocument.perform`.

## Gotchas learned

- Swift Testing: `#expect(x.mutatingCall())` doesn't compile. Assign to a `let` first.

- Names: Papyrus was renamed **Paper** on 2026-10-27 (`.paper`, `.paperbrush`). The library is **PaperCore**,
  not PaperKit, because Apple ships a framework called PaperKit.

- Swift structs mirrored in MSL must match byte-for-byte; avoid `uint3`/`float3` in MSL param structs
  (16-byte size/alignment) — use scalar padding.
- `Float16` doesn't exist on Intel macOS; convert half floats on the GPU (`exportHalf4` etc.).
- Private textures on this discrete GPU: upload through a shared `MTLBuffer` + blit, never `replace`.
- Bind `dummyColor`/`dummyMask` to unused texture slots.
- Reusing a document for previews: clear the layer **and** `recompositeAll()`, or old pixels survive
  outside the new dirty rect.
- `NSHostingView` snapshots: set `sizingOptions = []` and an explicit frame/background, or lazy grids
  collapse and backgrounds come out transparent.
- `CanvasOverlay`'s `Canvas` closure is nonisolated: read observable state into locals first.

## CommonKit (cloud sync)

`UniversalSyncManager` (actor) is the entry point; `CloudSyncController` (PaperCore, `@MainActor`) bridges
it to SwiftUI and is injected into `PaperAppModel(cloud:)` — tests/snapshots pass nil or an in-memory
token store so nothing touches the Keychain or network. `projectDidChange` after each save (10 s debounce),
`appWillSuspend` on resign-active, `syncAll` on activate; `.projectUpdated` reloads the open artwork if it
has no unsaved edits. Providers: Google Drive, Dropbox, OneDrive (REST + PKCE, keys from
`~/Library/Application Support/Paper/CloudKeys.plist`), iCloud, `LocalFolderProvider` (+ File Provider
discovery). Gotcha: FileManager enumerators return `/private/var/...` while `resolvingSymlinksInPath`
gives `/var/...` — never strip root paths as string prefixes.

## Status

README "What's verified" is the source of truth. Next: hands-on test of the live Mac app with the user, iPad Xcode
project, real-provider sign-in once the user has registered keys.
