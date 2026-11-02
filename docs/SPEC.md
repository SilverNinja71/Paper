# Master brief: "Paper" (Procreate / Photoshop / Lightroom studio)

The user's original brief (2026-10-26), kept for reference. Renamed since: "Papyrus" → **Paper** (files `.paper`).
The brief covered two apps. Part 1, about the CAD app Forge, is kept in Forge's own repo, and Parts 3–5 are unchanged, so
they still mention it.

Two professional Apple-platform apps (macOS 14+ and iPadOS 17+) in Swift, SwiftUI, Metal and
Accelerate/C++, sharing a decentralised **Universal Cloud Sync Engine** for Google Drive, Dropbox,
Microsoft OneDrive and iCloud Drive.

---

## Part 2 — Paper: digital art & image studio (Procreate / Photoshop / Lightroom)

### 2.1 Philosophy
- Raster drawing, advanced layer compositing and photographic colour science in one app.
- **100 % free brushes**: no paywalls; an industrial Brush Studio and a built-in community brush exchange.
- Identical engine and shortcuts on Mac and iPad.

### 2.2 Engine
1. **Brush engine & free exchange**: dual-brush blending, custom shape and grain textures, stroke jitter,
   StreamLine/stabilisation, wet edges, colour dynamics (pressure-linked hue/saturation jitter), Pencil
   tilt/pressure response curves. Import/export `.paperbrush`, brush packs and Photoshop `.abr`.
   Built-in decentralised library to browse, test and download community brushes (pencils, inks, oils,
   charcoals, halftones, FX, concept) onto categorised shelves with one tap.
2. **Photoshop-grade layers**: unlimited layers (bounded by RAM), nested groups with pass-through,
   non-destructive clipping masks and greyscale layer masks, 28 blend modes, alpha lock, reference layer
   for threshold colour-drop fills, layer lock.
3. **Lightroom-grade colour**: non-destructive adjustment layers — 32-bit tone curve (RGB + luminance),
   HSL / colour wheels, exposure, shadows/highlights, clarity, dehaze, vibrance, gradient maps, selective
   colour. Live HDR and wide-gamut (Display P3) canvas.
4. **Shortcuts**: B brush · E eraser · S smudge · L lasso · V move/transform · G fill · `[` `]` size ·
   Shift+`[` `]` softness · ⌘Z undo · ⇧⌘Z redo · ⌘J duplicate layer · ⌘E merge down · Space-drag pan ·
   ⌘⌥0 fit to screen.

---

## Part 3 — Universal Cloud Folder Sync Engine (shared)

1. **Providers**: Google Drive (REST v3, OAuth2 PKCE), Dropbox (API v2), Microsoft OneDrive (Graph /
   MSAL), iCloud Drive (`url(forUbiquityContainerIdentifier:)`), local file system and external drives
   (macOS volumes, iPadOS security-scoped bookmarks).
2. **Mechanics**: map any local or cloud folder (e.g. `Google Drive/Forge Projects/`); projects are
   self-contained packages (`.forge`, `.paper`: manifest JSON, binary buffers, thumbnails) saved as
   atomic deltas; on a timestamp conflict the engine branches `[Name] (Conflicted Copy [Date])` so nothing
   is lost; silent background upload after 10 s idle or when the app is suspended.

---

## Part 4 — Source layout (as briefed)

```
Workspace/
├── Common/
│   ├── CloudSync/  UniversalSyncEngine, GoogleDriveProvider, DropboxProvider, OneDriveProvider,
│   │               ICloudDriveProvider, ConflictResolver
│   └── Math/       Matrix4x4, Vector3
├── Forge/
│   ├── Model/      CadDocument (units), FeatureTree, Sketch2D, ConstraintSolver (Newton-Raphson), BRepMesh
│   ├── Operations/ ExtrudeOp, RevolveOp, FilletOp, AssemblyJointOp
│   ├── Viewport/   CadRenderer, TechnicalShaders.metal, CadInteractionController
│   └── UI/         TimelineBarView, DimensionInputBox, CadToolbar
└── Paper/
    ├── Engine/     PaintEngine, BrushStudio, FreeBrushStore, Shaders/StrokeShader.metal, Shaders/BlendModes.metal
    ├── Compositing/ LayerStack, AdjustmentPipeline
    └── UI/         PaperCanvasView, LayerManagerSheet, BrushPickerPopover, LightroomAdjustmentsView
```

## Part 5 — Implementation instructions
1. Complete, production-ready Swift — no pseudocode or placeholders.
2. Real algorithms for the constraint solver (collinear, perpendicular, tangent, dimensions), the Metal
   compute brush pipeline with Pencil pressure/tilt interpolation, and the multi-provider sync interface with
   secure token handling.
3. Compiles with Xcode 15/16 and Swift 6, with `#if os(macOS)` / `#if os(iOS)` where needed.
