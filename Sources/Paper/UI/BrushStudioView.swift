import SwiftUI
import UniformTypeIdentifiers
import simd

/// Brush Studio: every brush setting, grouped like Procreate, with a live preview stroke.
public struct BrushStudioView: View {
    @State private var brush: BrushPreset
    let store: FreeBrushStore
    var onDone: (BrushPreset?) -> Void
    @State private var section: Section = .stroke
    @State private var importingTip = false
    @State private var exportURL: URL?

    enum Section: String, CaseIterable, Identifiable {
        case stroke = "Stroke Path", stabilization = "Stabilization", taper = "Taper", shape = "Shape", grain = "Grain"
        case dual = "Dual Brush", wet = "Wet Mix", color = "Color Dynamics", dynamics = "Dynamics"
        case pencil = "Apple Pencil", properties = "Properties"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .stroke: return "scribble"
            case .stabilization: return "waveform.path"
            case .taper: return "chevron.right.2"
            case .shape: return "circle.dashed"
            case .grain: return "circle.grid.cross"
            case .dual: return "circle.circle"
            case .wet: return "drop"
            case .color: return "paintpalette"
            case .dynamics: return "sparkles"
            case .pencil: return "applepencil"
            case .properties: return "slider.horizontal.3"
            }
        }
    }

    public init(brush: BrushPreset, store: FreeBrushStore, onDone: @escaping (BrushPreset?) -> Void) {
        _brush = State(initialValue: brush)
        self.store = store
        self.onDone = onDone
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Brush name", text: $brush.name).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
                Button("Cancel") { onDone(nil) }
                Button("Export…") { exportBrush() }
                Button("Done") {
                    store.save(brush)
                    onDone(brush)
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            HStack(spacing: 0) {
                List(Section.allCases, selection: Binding(get: { section }, set: { if let s = $0 { section = s } })) { s in
                    Label(s.rawValue, systemImage: s.symbol).tag(s)
                }
                .listStyle(.sidebar)
                .frame(width: 190)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) { controls }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 320)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Drawing Pad").font(.headline)
                    if let img = BrushPreviewRenderer.shared.preview(for: brush, width: 320, height: 160) {
                        Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                    }
                    Text("The preview swells with pressure and tilts the pencil mid-stroke.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(16)
                .frame(width: 360)
            }
        }
        .frame(minWidth: 960, minHeight: 560)
        .fileImporter(isPresented: $importingTip, allowedContentTypes: [.png, .jpeg, .tiff, .image]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url), let gray = BrushTextureLibrary.decodeGray(data),
               let png = BrushTextureLibrary.pngData(gray: gray) {
                brush.tip = .image(png)
            }
        }
    }

    // MARK: Controls per section

    @ViewBuilder private var controls: some View {
        switch section {
        case .stroke:
            slider("Spacing", $brush.spacing, 0.01...2, percent: true)
            stepper("Dabs per step", $brush.count, 1...8)
            slider("Scatter", $brush.scatter, 0...2, percent: true)
            slider("Flow", $brush.flow, 0.01...1, percent: true)
        case .stabilization:
            slider("StreamLine", $brush.streamline, 0...1, percent: true)
            slider("Stabilization", $brush.stabilization, 0...1, percent: true)
            Text("StreamLine pulls the line like a string for smooth curves; Stabilization averages recent points.")
                .font(.caption).foregroundStyle(.secondary)
        case .taper:
            slider("Start taper", $brush.startTaper, 0...1, percent: true)
        case .shape:
            tipPicker("Shape source", tip: $brush.tip, allowRound: true)
            if case .round = brush.tip { slider("Hardness", $brush.hardness, 0...1, percent: true) }
            slider("Angle", $brush.angle, -180...180, unit: "°")
            slider("Roundness", $brush.roundness, 0.05...1, percent: true)
            Picker("Rotation", selection: $brush.rotationMode) {
                Text("Fixed").tag(RotationMode.fixed)
                Text("Follow stroke").tag(RotationMode.followStroke)
                Text("Follow Pencil azimuth").tag(RotationMode.followAzimuth)
            }
            slider("Angle jitter", $brush.angleJitter, 0...1, percent: true)
            Toggle("Randomly flip", isOn: $brush.randomFlip)
        case .grain:
            Toggle("Use grain", isOn: Binding(get: { brush.grain != nil },
                                               set: { brush.grain = $0 ? (brush.grain ?? GrainSettings()) : nil }))
            if brush.grain != nil {
                tipPicker("Grain source", tip: Binding(get: { brush.grain!.source }, set: { brush.grain!.source = $0 }),
                          allowRound: false, names: BrushTextureLibrary.grainNames)
                Picker("Behaviour", selection: Binding(get: { brush.grain!.mode }, set: { brush.grain!.mode = $0 })) {
                    Text("Texturized (fixed to canvas)").tag(GrainMode.texturized)
                    Text("Moving (part of the stamp)").tag(GrainMode.moving)
                }
                slider("Scale", Binding(get: { brush.grain!.scale }, set: { brush.grain!.scale = $0 }), 0.1...4, unit: "×")
                slider("Depth", Binding(get: { brush.grain!.depth }, set: { brush.grain!.depth = $0 }), 0...1, percent: true)
            }
        case .dual:
            Toggle("Dual brush", isOn: Binding(get: { brush.dual != nil },
                                               set: { brush.dual = $0 ? (brush.dual ?? DualBrushSettings()) : nil }))
            if brush.dual != nil {
                tipPicker("Second tip", tip: Binding(get: { brush.dual!.tip }, set: { brush.dual!.tip = $0 }), allowRound: false)
                Picker("Blend", selection: Binding(get: { brush.dual!.blend }, set: { brush.dual!.blend = $0 })) {
                    ForEach(DualBlend.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                slider("Scale", Binding(get: { brush.dual!.scale }, set: { brush.dual!.scale = $0 }), 0.05...2, unit: "×")
                slider("Scatter", Binding(get: { brush.dual!.scatter }, set: { brush.dual!.scatter = $0 }), 0...1, percent: true)
                slider("Depth", Binding(get: { brush.dual!.depth }, set: { brush.dual!.depth = $0 }), 0...1, percent: true)
            }
        case .wet:
            slider("Wet mix (pick-up)", $brush.wetMix, 0...1, percent: true)
            slider("Wet edges", $brush.wetEdges, 0...1, percent: true)
        case .color:
            slider("Hue jitter", $brush.hueJitter, 0...1, percent: true)
            slider("Saturation jitter", $brush.saturationJitter, 0...1, percent: true)
            slider("Brightness jitter", $brush.brightnessJitter, 0...1, percent: true)
            Divider()
            Text("Pressure-linked (light pressure shifts the colour)").font(.caption).foregroundStyle(.secondary)
            slider("Pressure → hue", $brush.pressureHue, -1...1, percent: true)
            slider("Pressure → saturation", $brush.pressureSaturation, -1...1, percent: true)
            slider("Pressure → brightness", $brush.pressureBrightness, -1...1, percent: true)
        case .dynamics:
            slider("Size jitter", $brush.sizeJitter, 0...1, percent: true)
            slider("Opacity jitter", $brush.opacityJitter, 0...1, percent: true)
            slider("Speed → size", $brush.velocitySize, -1...1, percent: true)
        case .pencil:
            Text("Pressure curve").font(.subheadline.weight(.semibold))
            CurveEditorView(curve: $brush.pressureCurve, tint: .accentColor).frame(height: 180)
            slider("Pressure → size", $brush.pressureSize, 0...1, percent: true)
            slider("Pressure → opacity", $brush.pressureOpacity, 0...1, percent: true)
            slider("Pressure → flow", $brush.pressureFlow, 0...1, percent: true)
            Divider()
            Text("Tilt curve").font(.subheadline.weight(.semibold))
            CurveEditorView(curve: $brush.tiltCurve, tint: .orange).frame(height: 140)
            slider("Tilt → size", $brush.tiltSize, 0...1, percent: true)
            slider("Tilt → opacity", $brush.tiltOpacity, 0...1, percent: true)
            slider("Tilt → flatten", $brush.tiltRoundness, 0...1, percent: true)
        case .properties:
            TextField("Category", text: $brush.category).textFieldStyle(.roundedBorder)
            TextField("Author", text: $brush.author).textFieldStyle(.roundedBorder)
            slider("Default size", $brush.defaultSize, 1...600, unit: " px")
            slider("Minimum size", $brush.minSize, 0.5...50, unit: " px")
            slider("Maximum size", $brush.maxSize, 10...2000, unit: " px")
            slider("Default opacity", $brush.defaultOpacity, 0.01...1, percent: true)
        }
    }

    private func slider(_ title: String, _ value: Binding<Float>, _ range: ClosedRange<Float>, percent: Bool = false,
                        unit: String = "") -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(percent ? "\(Int((value.wrappedValue * 100).rounded()))%"
                             : String(format: "%.1f", value.wrappedValue) + unit)
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            Slider(value: value, in: range)
        }
    }

    private func stepper(_ title: String, _ value: Binding<Int>, _ range: ClosedRange<Int>) -> some View {
        Stepper("\(title): \(value.wrappedValue)", value: value, in: range)
    }

    private func tipPicker(_ title: String, tip: Binding<BrushTip>, allowRound: Bool,
                           names: [String] = BrushTextureLibrary.tipNames) -> some View {
        HStack {
            Picker(title, selection: Binding<String>(
                get: {
                    switch tip.wrappedValue {
                    case .round: return "round"
                    case .builtin(let n): return n
                    case .image: return "custom"
                    }
                },
                set: { v in
                    if v == "round" { tip.wrappedValue = .round }
                    else if v == "custom" { importingTip = true }
                    else { tip.wrappedValue = .builtin(v) }
                })) {
                if allowRound { Text("Round (analytic)").tag("round") }
                ForEach(names + (allowRound ? [] : BrushTextureLibrary.tipNames.filter { !names.contains($0) }), id: \.self) {
                    Text($0.capitalized).tag($0)
                }
                Text("Custom image…").tag("custom")
            }
        }
    }

    private func exportBrush() {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = brush.name + ".paperbrush"
        panel.allowedContentTypes = [UTType(filenameExtension: "paperbrush") ?? .json]
        if panel.runModal() == .OK, let url = panel.url, let data = try? FreeBrushStore.exportData(brush) {
            try? data.write(to: url, options: .atomic)
        }
        #endif
    }
}
