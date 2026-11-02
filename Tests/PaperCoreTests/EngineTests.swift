import Testing
import Foundation
import simd
@testable import PaperCore

// GPU-backed checks of the paint engine, compositor, layers, undo, files and input mapping.
// They render off-screen only (no windows).

@MainActor
func pixel(_ doc: CanvasDocument, _ x: Int, _ y: Int) -> SIMD4<Float> {
    doc.gpu.readPixels(doc.compositor.output, region: IntRect(x: x, y: y, width: 1, height: 1))[0]
}

@MainActor
func layerPixel(_ doc: CanvasDocument, _ id: UUID, _ x: Int, _ y: Int) -> SIMD4<Float> {
    doc.gpu.readPixels(doc.content[id]!, region: IntRect(x: x, y: y, width: 1, height: 1))[0]
}

func close(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ tol: Float = 0.01) -> Bool {
    simd_reduce_max(simd_abs(a - b)) <= tol
}

func line(from a: SIMD2<Float>, to b: SIMD2<Float>, steps: Int = 30, pressure: Float = 1) -> [StrokeSample] {
    (0...steps).map { i in
        let t = Float(i) / Float(steps)
        return StrokeSample(position: a + (b - a) * t, pressure: pressure, timestamp: Double(i) / 120)
    }
}

@Suite("Shaders")
struct ShaderTests {
    @Test func everyModuleCompiles() throws {
        let gpu = PaperGPU.shared
        _ = try gpu.library(UtilityShader.self)
        _ = try gpu.library(StrokeShader.self)
        _ = try gpu.library(CompositeShader.self)
        _ = try gpu.library(SelectionShader.self)
        for f in ["stampDabs", "applyStroke", "smudgeDab"] { _ = try gpu.pipeline(f, in: StrokeShader.self) }
        for f in ["compositeLayer", "flatten"] { _ = try gpu.pipeline(f, in: CompositeShader.self) }
        for f in ["importGray8", "combineMasks", "invertMask", "fillWithMask", "clearSelected", "transformLayer"] {
            _ = try gpu.pipeline(f, in: SelectionShader.self)
        }
    }

    @Test func halfFloatRoundTrip() throws {
        let gpu = PaperGPU.shared
        let t = try gpu.makeTexture(width: 4, height: 2, label: "t")
        let px = (0..<8).map { i in SIMD4<Float>(Float(i) / 8, 0.25, 0.5, 1) }
        gpu.writePixels(px, to: t)
        let data = gpu.readHalfData(t)
        #expect(data.count == 8 * 8)
        let t2 = try gpu.makeTexture(width: 4, height: 2, label: "t2")
        #expect(gpu.writeHalfData(data, to: t2))
        let back = gpu.readPixels(t2)
        for i in 0..<8 { #expect(close(back[i], px[i], 0.002)) }
    }
}

@Suite("Blend modes")
@MainActor
struct BlendModeTests {
    /// Background `b` (opaque) with a full layer of colour `s` in `mode` → composite pixel.
    func blend(_ mode: BlendMode, b: SIMD3<Float>, s: SIMD3<Float>, opacity: Float = 1) throws -> SIMD3<Float> {
        let doc = try CanvasDocument(width: 16, height: 16, background: b)
        doc.color = s
        doc.fillSelection()
        let id = doc.activeLayerID!
        doc.setBlendMode(id, mode)
        if opacity < 1 { doc.setOpacity(id, opacity) }
        let p = pixel(doc, 8, 8)
        return SIMD3(p.x, p.y, p.z)
    }

    @Test func separableModesMatchFormulas() throws {
        let b = SIMD3<Float>(0.8, 0.5, 0.2), s = SIMD3<Float>(0.3, 0.5, 0.9)
        let cases: [(BlendMode, SIMD3<Float>)] = [
            (.normal, s),
            (.multiply, b * s),
            (.screen, b + s - b * s),
            (.darken, simd_min(b, s)),
            (.lighten, simd_max(b, s)),
            (.difference, simd_abs(b - s)),
            (.exclusion, b + s - 2 * b * s),
            (.subtract, simd_max(b - s, .zero)),
            (.linearBurn, simd_max(b + s - 1, .zero)),
            (.linearDodge, b + s),
            (.hardMix, SIMD3(1, 1, 1)),   // b + s ≥ 1 in every channel here
        ]
        for (mode, expected) in cases {
            let got = try blend(mode, b: b, s: s)
            #expect(simd_reduce_max(simd_abs(got - expected)) < 0.004, "\(mode): got \(got) expected \(expected)")
        }
    }

    @Test func overlayAndSoftLight() throws {
        let b = SIMD3<Float>(0.25, 0.75, 0.5), s = SIMD3<Float>(0.5, 0.5, 0.8)
        let overlay = try blend(.overlay, b: b, s: s)
        // Overlay = HardLight with roles swapped.
        let expected = SIMD3<Float>(2 * 0.25 * 0.5, 1 - 2 * 0.25 * 0.5, 1 - 2 * 0.5 * 0.2)
        #expect(simd_reduce_max(simd_abs(overlay - expected)) < 0.004)
        let soft = try blend(.softLight, b: SIMD3(0.5, 0.5, 0.5), s: SIMD3(0.5, 0.5, 0.5))
        #expect(simd_reduce_max(simd_abs(soft - SIMD3(0.5, 0.5, 0.5))) < 0.004)
    }

    @Test func nonSeparableModesKeepLuminosityOrHue() throws {
        let grey = SIMD3<Float>(0.5, 0.5, 0.5), red = SIMD3<Float>(1, 0, 0)
        // Luminosity of grey over red keeps red's hue but grey's luminance (0.3·R + 0.59·G + 0.11·B).
        let lum = try blend(.luminosity, b: red, s: grey)
        #expect(abs(simd_dot(lum, SIMD3(0.3, 0.59, 0.11)) - 0.5) < 0.01)
        #expect(lum.x > lum.y && lum.x > lum.z)
        // Color of red over grey → reddish with grey's luminance.
        let color = try blend(.color, b: grey, s: red)
        #expect(abs(simd_dot(color, SIMD3(0.3, 0.59, 0.11)) - 0.5) < 0.01)
        #expect(color.x > color.y)
        // Saturation from grey (0) → desaturates.
        let sat = try blend(.saturation, b: red, s: grey)
        #expect(abs(sat.x - sat.y) < 0.01 && abs(sat.y - sat.z) < 0.01)
    }

    @Test func allModesProduceSaneValues() throws {
        for mode in BlendMode.allCases where mode != .passThrough {
            let got = try blend(mode, b: SIMD3(0.6, 0.3, 0.1), s: SIMD3(0.2, 0.7, 0.4), opacity: 0.7)
            #expect(got.x.isFinite && got.y.isFinite && got.z.isFinite, "\(mode)")
            #expect(simd_reduce_min(got) >= -0.001 && simd_reduce_max(got) <= 1.4, "\(mode): \(got)")
        }
    }

    @Test func opacityMixes() throws {
        let got = try blend(.normal, b: SIMD3(1, 1, 1), s: SIMD3(0, 0, 0), opacity: 0.25)
        #expect(abs(got.x - 0.75) < 0.004)
    }
}

@Suite("Painting")
@MainActor
struct PaintingTests {
    @Test func strokeDepositsPaintAndUndoes() throws {
        let doc = try CanvasDocument(width: 128, height: 128)
        doc.color = SIMD3(1, 0, 0)
        doc.sizes[.brush] = 12
        doc.paintStroke(line(from: SIMD2(20, 64), to: SIMD2(108, 64)))
        #expect(close(pixel(doc, 64, 64), SIMD4(1, 0, 0, 1), 0.02))
        #expect(close(pixel(doc, 64, 20), SIMD4(1, 1, 1, 1)))
        #expect(doc.canUndo)
        doc.undo()
        #expect(close(pixel(doc, 64, 64), SIMD4(1, 1, 1, 1)))
        doc.redo()
        #expect(close(pixel(doc, 64, 64), SIMD4(1, 0, 0, 1), 0.02))
    }

    @Test func eraserRemovesPaint() throws {
        let doc = try CanvasDocument(width: 64, height: 64, background: nil)
        doc.color = SIMD3(0, 0, 1)
        doc.fillSelection()
        doc.tool = .eraser
        doc.sizes[.eraser] = 20
        doc.paintStroke(line(from: SIMD2(10, 32), to: SIMD2(54, 32)))
        #expect(pixel(doc, 32, 32).w < 0.02)
        #expect(pixel(doc, 32, 5).w > 0.98)
    }

    @Test func alphaLockKeepsShape() throws {
        let doc = try CanvasDocument(width: 64, height: 64, background: nil)
        let id = doc.activeLayerID!
        doc.color = SIMD3(0, 1, 0)
        doc.paintStroke(line(from: SIMD2(10, 32), to: SIMD2(54, 32)))
        doc.setAlphaLocked(id, true)
        doc.color = SIMD3(1, 0, 1)
        doc.sizes[.brush] = 60
        doc.paintStroke(line(from: SIMD2(5, 32), to: SIMD2(60, 32)))
        #expect(layerPixel(doc, id, 32, 5).w < 0.01)          // still empty above the line
        let p = layerPixel(doc, id, 32, 32)
        #expect(p.x > 0.9 && p.y < 0.1)                         // recoloured where paint was
    }

    @Test func pressureChangesWidth() throws {
        let doc = try CanvasDocument(width: 200, height: 100, background: nil)
        doc.sizes[.brush] = 30
        doc.paintStroke(line(from: SIMD2(20, 30), to: SIMD2(180, 30), pressure: 0.15))
        doc.paintStroke(line(from: SIMD2(20, 70), to: SIMD2(180, 70), pressure: 1))
        func width(atY y: Int) -> Int {
            (0..<15).filter { d in pixel(doc, 100, y + d).w > 0.5 }.count
        }
        #expect(width(atY: 70) > width(atY: 30))
    }

    @Test func smudgeMovesColour() throws {
        let doc = try CanvasDocument(width: 96, height: 64, background: nil)
        doc.color = SIMD3(1, 0, 0)
        doc.selectAll()
        doc.fillSelection()
        doc.deselect()
        // Fill the right part blue, then smudge from red into blue.
        doc.beginLasso(at: SIMD2(50, 0))
        for p in [SIMD2<Float>(96, 0), SIMD2(96, 64), SIMD2(50, 64)] { doc.extendLasso(to: p) }
        doc.endLasso()
        doc.color = SIMD3(0, 0, 1)
        doc.fillSelection()
        doc.deselect()
        let before = pixel(doc, 56, 32)
        doc.tool = .smudge
        doc.sizes[.smudge] = 30
        doc.paintStroke(line(from: SIMD2(20, 32), to: SIMD2(60, 32)))
        let after = pixel(doc, 56, 32)
        #expect(after.x > before.x + 0.1)   // red dragged into the blue area
    }

    @Test func dabSpacingIsEven() {
        var brush = BrushPreset(name: "t", category: "t")
        brush.spacing = 0.25
        brush.streamline = 0
        brush.pressureSize = 0
        var gen = DabGenerator(brush: brush, size: 20, color: .zero, seed: 1)
        var dabs: [Dab] = []
        for s in line(from: SIMD2(0, 0), to: SIMD2(100, 0), steps: 10) { dabs += gen.add(s) }
        dabs += gen.finish()
        // 100 px at 5 px spacing → ~21 dabs.
        #expect(abs(dabs.count - 21) <= 2)
        for i in 1..<dabs.count {
            #expect(abs(simd_distance(dabs[i].center, dabs[i - 1].center) - 5) < 0.6)
        }
    }
}

@Suite("Layers")
@MainActor
struct LayerTests {
    @Test func clippingMaskOnlyShowsOverBase() throws {
        let doc = try CanvasDocument(width: 64, height: 64, background: nil)
        // Base: a horizontal band.
        doc.color = SIMD3(0, 0, 0)
        doc.sizes[.brush] = 16
        doc.paintStroke(line(from: SIMD2(0, 32), to: SIMD2(64, 32)))
        doc.addLayer()
        let top = doc.activeLayerID!
        doc.color = SIMD3(1, 0, 0)
        doc.fillSelection()
        doc.setClipping(top, true)
        #expect(pixel(doc, 32, 5).w < 0.01)          // nothing outside the band
        let inBand = pixel(doc, 32, 32)
        #expect(inBand.x > 0.95 && inBand.w > 0.95)   // red inside it
    }

    @Test func maskHidesAndUndoes() throws {
        let doc = try CanvasDocument(width: 64, height: 64, background: nil)
        let id = doc.activeLayerID!
        doc.color = SIMD3(0, 1, 0)
        doc.fillSelection()
        doc.addMask(id)
        #expect(doc.editingMask)
        doc.color = SIMD3(0, 0, 0)           // painting black on a mask hides
        doc.sizes[.brush] = 20
        doc.paintStroke(line(from: SIMD2(0, 32), to: SIMD2(64, 32)))
        #expect(pixel(doc, 32, 32).w < 0.02)
        #expect(pixel(doc, 32, 5).w > 0.98)
        doc.setMaskEnabled(id, false)
        #expect(pixel(doc, 32, 32).w > 0.98)
        doc.undo()
        #expect(pixel(doc, 32, 32).w < 0.02)
    }

    @Test func mergeDownCombinesAndUndoes() throws {
        let doc = try CanvasDocument(width: 32, height: 32, background: nil)
        let bottom = doc.activeLayerID!
        doc.color = SIMD3(1, 0, 0)
        doc.fillSelection()
        doc.addLayer()
        let top = doc.activeLayerID!
        doc.color = SIMD3(0, 0, 1)
        doc.paintStroke(line(from: SIMD2(0, 16), to: SIMD2(32, 16)))
        doc.setBlendMode(top, .screen)
        let before = pixel(doc, 16, 16)
        doc.mergeDown(top)
        #expect(doc.layers.count == 1)
        #expect(doc.activeLayerID == bottom)
        #expect(close(pixel(doc, 16, 16), before, 0.004))
        doc.undo()
        #expect(doc.layers.count == 2)
    }

    @Test func groupsAndPassThrough() throws {
        let doc = try CanvasDocument(width: 32, height: 32, background: SIMD3(0.5, 0.5, 0.5))
        doc.color = SIMD3(1, 1, 1)
        doc.fillSelection()
        let id = doc.activeLayerID!
        doc.setBlendMode(id, .multiply)
        doc.groupActiveLayer()
        let group = doc.activeLayerID!
        #expect(doc.layers.node(group)?.isGroup == true)
        // An isolated group: multiply against transparency inside the group → plain white over grey.
        #expect(close(pixel(doc, 4, 4), SIMD4(1, 1, 1, 1), 0.004))
        // Pass Through: multiply reaches the background → grey stays grey.
        doc.setBlendMode(group, .passThrough)
        #expect(close(pixel(doc, 4, 4), SIMD4(0.5, 0.5, 0.5, 1), 0.004))
    }

    @Test func stackEditing() {
        var s = LayerStack(nodes: [LayerNode(name: "A"), LayerNode(name: "B"), LayerNode(name: "C")])
        let a = s.nodes[0].id, c = s.nodes[2].id
        s.move(a, above: c)
        #expect(s.nodes.map(\.name) == ["B", "C", "A"])
        let g = s.group([c, a], name: "G")!
        #expect(s.nodes.map(\.name) == ["B", "G"])
        #expect(s.node(g)?.children.map(\.name) == ["C", "A"])
        #expect(s.parentID(of: a) == g)
        s.ungroup(g)
        #expect(s.nodes.map(\.name) == ["B", "C", "A"])
    }
}

@Suite("Selection & fill")
@MainActor
struct SelectionTests {
    @Test func lassoLimitsPainting() throws {
        let doc = try CanvasDocument(width: 64, height: 64, background: nil)
        doc.beginLasso(at: SIMD2(0, 0))
        for p in [SIMD2<Float>(32, 0), SIMD2(32, 64), SIMD2(0, 64)] { doc.extendLasso(to: p) }
        doc.endLasso()
        #expect(doc.hasSelection)
        doc.sizes[.brush] = 30
        doc.paintStroke(line(from: SIMD2(5, 32), to: SIMD2(60, 32)))
        #expect(pixel(doc, 16, 32).w > 0.9)
        #expect(pixel(doc, 48, 32).w < 0.01)
    }

    @Test func floodFillStopsAtLines() {
        // 5×5: a vertical wall at x = 2.
        var px = [SIMD4<Float>](repeating: .zero, count: 25)
        for y in 0..<5 { px[y * 5 + 2] = SIMD4(0, 0, 0, 1) }
        let r = FloodFill.coverage(pixels: px, width: 5, height: 5, seedX: 0, seedY: 0, tolerance: 0.1)!
        // Region x 0…1 plus a one-pixel grow onto the wall.
        #expect(r.bounds == IntRect(x: 0, y: 0, width: 3, height: 5))
        #expect(r.bytes.allSatisfy { $0 == 255 })
    }

    @Test func fillUsesReferenceLayer() throws {
        let doc = try CanvasDocument(width: 64, height: 64, background: nil)
        let lineArt = doc.activeLayerID!
        doc.color = SIMD3(0, 0, 0)
        doc.sizes[.brush] = 4
        // Start and end off-canvas so the pen's taper can't leave a gap.
        doc.paintStroke(line(from: SIMD2(32, -40), to: SIMD2(32, 104)))
        doc.setReference(lineArt, true)
        doc.addLayer()
        let colours = doc.activeLayerID!
        doc.color = SIMD3(1, 1, 0)
        doc.fill(at: SIMD2(10, 10))
        #expect(layerPixel(doc, colours, 10, 10).w > 0.99)
        #expect(layerPixel(doc, colours, 50, 10).w < 0.01)
    }

    @Test func moveTransformCommits() throws {
        let doc = try CanvasDocument(width: 64, height: 64, background: nil)
        let id = doc.activeLayerID!
        doc.sizes[.brush] = 10
        doc.paintStroke(line(from: SIMD2(10, 10), to: SIMD2(20, 10)))
        doc.tool = .move
        doc.beginTransform()
        doc.updateTransform { $0.translation = SIMD2(30, 30) }
        doc.commitTransform()
        #expect(layerPixel(doc, id, 15, 10).w < 0.05)
        #expect(layerPixel(doc, id, 45, 40).w > 0.9)
        doc.undo()
        #expect(layerPixel(doc, id, 15, 10).w > 0.9)
    }
}

@Suite("Files")
@MainActor
struct FileTests {
    @Test func saveOpenRoundTripAndDeltaSaves() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("paper-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Art.paper")
        let doc = try CanvasDocument(width: 64, height: 48, name: "Art")
        doc.color = SIMD3(0.2, 0.4, 0.9)
        doc.paintStroke(line(from: SIMD2(5, 24), to: SIMD2(60, 24)))
        doc.addLayer()
        doc.addMask()
        doc.addAdjustmentLayer(.toneCurve)
        let firstWrite = try doc.save(to: url)
        #expect(firstWrite.contains("manifest.json"))
        #expect(firstWrite.filter { $0.hasPrefix("layers/") }.count == 2)
        #expect(firstWrite.filter { $0.hasPrefix("masks/") }.count == 1)
        // Nothing changed → only thumbnail + manifest are rewritten.
        let second = try doc.save(to: url)
        #expect(second.filter { $0.hasPrefix("layers/") || $0.hasPrefix("masks/") }.isEmpty)

        let reopened = try CanvasDocument.open(url)
        #expect(reopened.width == 64 && reopened.height == 48)
        #expect(reopened.layers == doc.layers)
        #expect(close(pixel(reopened, 30, 24), pixel(doc, 30, 24), 0.004))
        #expect(CanvasDocument.peek(url)?.thumbnail != nil)
    }
}

@Suite("Brushes")
@MainActor
struct BrushLibraryTests {
    @Test func builtInsAreFreeAndStable() {
        let store = FreeBrushStore(directory: nil)
        #expect(store.brushes.count >= 28)
        #expect(Set(store.brushes.map(\.id)).count == store.brushes.count)
        #expect(FreeBrushStore.stableID("HB Pencil") == FreeBrushStore.stableID("HB Pencil"))
        for b in FreeBrushStore.builtInBrushes {
            if case .builtin(let name) = b.tip { #expect(BrushTextureLibrary.generate(name) != nil, "\(name)") }
        }
    }

    @Test func paperBrushRoundTrip() throws {
        let store = FreeBrushStore(directory: nil)
        let b = FreeBrushStore.builtInBrushes[3]
        let data = try FreeBrushStore.exportData(b)
        let imported = try store.importData(data, fileExtension: "paperbrush", suggestedName: "x")
        #expect(imported.count == 1)
        #expect(imported[0].id != b.id)
        #expect(imported[0].spacing == b.spacing && imported[0].tip == b.tip)
    }

    @Test func packBits() {
        #expect(ABRImporter.packBitsDecode([0x02, 1, 2, 3, 0xFE, 9], expected: 6) == [1, 2, 3, 9, 9, 9])
    }

    @Test func abrVersion1SampledBrush() throws {
        // Hand-built v1 file: one 8×8 sampled tip, 30 % spacing, uncompressed.
        var body = Data()
        func u16(_ v: Int, _ d: inout Data) { d.append(contentsOf: [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
        func u32(_ v: Int, _ d: inout Data) {
            d.append(contentsOf: [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
        }
        u32(0, &body); u16(30, &body); body.append(1)          // misc, spacing, anti-alias
        for _ in 0..<4 { u16(0, &body) }                        // short bounds
        u32(0, &body); u32(0, &body); u32(8, &body); u32(8, &body)  // top, left, bottom, right
        u16(8, &body); body.append(0)                            // depth, uncompressed
        for y in 0..<8 { for x in 0..<8 { body.append((x - 4) * (x - 4) + (y - 4) * (y - 4) < 9 ? 255 : 0) } }
        var d = Data()
        u16(1, &d); u16(1, &d); u16(2, &d); u32(body.count, &d)
        d.append(body)
        let tips = try ABRImporter.parse(d)
        #expect(tips.count == 1)
        #expect(tips[0].width == 8 && tips[0].height == 8)
        #expect(abs((tips[0].spacing ?? 0) - 0.3) < 1e-6)
        let brushes = try ABRImporter.brushes(from: d, packName: "Test")
        #expect(brushes.count == 1)
        if case .image = brushes[0].tip {} else { Issue.record("expected an image tip") }
    }
}

@Suite("Input")
struct InputTests {
    @Test func shortcuts() {
        #expect(PaperKeymap.resolve(KeyStroke("b")) == .tool(.brush))
        #expect(PaperKeymap.resolve(KeyStroke("e")) == .tool(.eraser))
        #expect(PaperKeymap.resolve(KeyStroke("s")) == .tool(.smudge))
        #expect(PaperKeymap.resolve(KeyStroke("l")) == .tool(.lasso))
        #expect(PaperKeymap.resolve(KeyStroke("v")) == .tool(.move))
        #expect(PaperKeymap.resolve(KeyStroke("g")) == .tool(.fill))
        #expect(PaperKeymap.resolve(KeyStroke("[")) == .brushSmaller)
        #expect(PaperKeymap.resolve(KeyStroke("]")) == .brushLarger)
        #expect(PaperKeymap.resolve(KeyStroke("[", shift: true)) == .brushSofter)
        #expect(PaperKeymap.resolve(KeyStroke("{", shift: true)) == .brushSofter)
        #expect(PaperKeymap.resolve(KeyStroke("z", command: true)) == .undo)
        #expect(PaperKeymap.resolve(KeyStroke("z", command: true, shift: true)) == .redo)
        #expect(PaperKeymap.resolve(KeyStroke("j", command: true)) == .duplicateLayer)
        #expect(PaperKeymap.resolve(KeyStroke("e", command: true)) == .mergeDown)
        #expect(PaperKeymap.resolve(KeyStroke("0", command: true, option: true)) == .fitToScreen)
    }

    @Test func curvesStayMonotone() {
        let c = ResponseCurve(points: [SIMD2(0, 0), SIMD2(0.2, 0.6), SIMD2(0.25, 0.62), SIMD2(1, 1)])
        var last: Float = -1
        for v in c.lut(count: 200) {
            #expect(v >= last - 1e-5)
            last = v
        }
        #expect(ResponseCurve.linear.isIdentity)
        #expect(abs(ResponseCurve.linear.value(at: 0.37) - 0.37) < 1e-5)
    }
}
