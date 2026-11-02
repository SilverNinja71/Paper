import SwiftUI
import CoreGraphics
import simd

// MARK: - Public views

/// A compact grading panel (made for a ~300 pt sidebar) for one adjustment layer. It shows the controls that
/// belong to `settings.kind`: light/colour/effects sliders, the tone-curve editor, HSL tabs, colour-grading
/// wheels, the gradient-map editor or selective colour.
public struct LightroomAdjustmentsView: View {
    @Binding private var settings: AdjustmentSettings

    public init(settings: Binding<AdjustmentSettings>) {
        _settings = settings
    }

    /// The panel does not scroll or pad itself: put it in a `ScrollView` / `.padding` of your own
    /// (it lays out comfortably in about 270 pt of width). Its cards use system materials.
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(settings.kind.displayName).font(.headline)
                Spacer()
                Button("Reset", action: resetAll)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(isDefault)
            }
            panel
        }
    }

    @ViewBuilder private var panel: some View {
        switch settings.kind {
        case .develop: AdjDevelopPanel(settings: $settings.develop)
        case .toneCurve: AdjToneCurvePanel(settings: $settings.curves)
        case .hsl: AdjHSLPanel(settings: $settings.hsl)
        case .colorGrading: AdjColorGradingPanel(settings: $settings.grading)
        case .gradientMap: AdjGradientMapPanel(settings: $settings.gradientMap)
        case .selectiveColor: AdjSelectiveColorPanel(settings: $settings.selectiveColor)
        }
    }

    private var isDefault: Bool {
        switch settings.kind {
        case .develop: return settings.develop == DevelopSettings()
        case .toneCurve: return settings.curves == ToneCurveSettings()
        case .hsl: return settings.hsl == HSLSettings()
        case .colorGrading: return settings.grading == ColorGradingSettings()
        case .gradientMap: return false
        case .selectiveColor: return settings.selectiveColor == SelectiveColorSettings()
        }
    }

    private func resetAll() {
        switch settings.kind {
        case .develop: settings.develop = DevelopSettings()
        case .toneCurve: settings.curves = ToneCurveSettings()
        case .hsl: settings.hsl = HSLSettings()
        case .colorGrading: settings.grading = ColorGradingSettings()
        case .gradientMap: settings.gradientMap = GradientMapSettings()
        case .selectiveColor: settings.selectiveColor = SelectiveColorSettings()
        }
    }
}

/// A curve editor on the unit square. Drag a point to move it, click empty space to add one, drag an inner
/// point far outside the box (or double-click it) to delete it. Reusable for any `ResponseCurve`
/// (tone curves, Apple Pencil pressure and tilt response, …).
public struct CurveEditorView: View {
    @Binding private var curve: ResponseCurve
    private let tint: Color
    @State private var active: Int?
    @State private var started = false

    private static let inset: CGFloat = 9
    private static let hitRadius: CGFloat = 14
    private static let deleteDistance: CGFloat = 36
    private static let maxPoints = 16

    public init(curve: Binding<ResponseCurve>, tint: Color = .primary) {
        _curve = curve
        self.tint = tint
    }

    public var body: some View {
        GeometryReader { geo in
            let side = max(40, min(geo.size.width, geo.size.height))
            let plot = CGRect(x: Self.inset, y: Self.inset, width: side - 2 * Self.inset, height: side - 2 * Self.inset)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in draw(context, plot: plot) }
                if let i = active, curve.points.indices.contains(i) {
                    let p = curve.points[i]
                    Text("\(Int((p.x * 255).rounded())) \u{2192} \(Int((p.y * 255).rounded()))")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.thinMaterial, in: Capsule())
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: side, height: side)
            .contentShape(Rectangle())
            .gesture(dragGesture(plot: plot))
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { removeNearest(to: $0.location, plot: plot) })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Curve editor")
        .accessibilityValue("\(curve.points.count) points")
    }

    // MARK: Drawing

    private func viewPoint(_ p: SIMD2<Float>, _ plot: CGRect) -> CGPoint {
        CGPoint(x: plot.minX + CGFloat(p.x) * plot.width, y: plot.maxY - CGFloat(p.y) * plot.height)
    }

    private func unitPoint(_ p: CGPoint, _ plot: CGRect) -> SIMD2<Float> {
        SIMD2(Float((p.x - plot.minX) / plot.width), Float((plot.maxY - p.y) / plot.height))
    }

    private func draw(_ context: GraphicsContext, plot: CGRect) {
        let frame = Path(roundedRect: plot.insetBy(dx: -Self.inset / 2, dy: -Self.inset / 2), cornerRadius: 6)
        context.fill(frame, with: .color(.primary.opacity(0.06)))
        context.stroke(frame, with: .color(.primary.opacity(0.15)), lineWidth: 1)

        var grid = Path()
        for i in 1..<4 {
            let t = CGFloat(i) / 4
            grid.move(to: CGPoint(x: plot.minX + t * plot.width, y: plot.minY))
            grid.addLine(to: CGPoint(x: plot.minX + t * plot.width, y: plot.maxY))
            grid.move(to: CGPoint(x: plot.minX, y: plot.minY + t * plot.height))
            grid.addLine(to: CGPoint(x: plot.maxX, y: plot.minY + t * plot.height))
        }
        context.stroke(grid, with: .color(.primary.opacity(0.10)), lineWidth: 0.5)

        var diagonal = Path()
        diagonal.move(to: CGPoint(x: plot.minX, y: plot.maxY))
        diagonal.addLine(to: CGPoint(x: plot.maxX, y: plot.minY))
        context.stroke(diagonal, with: .color(.primary.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

        let samples = curve.lut(count: 129)
        var line = Path()
        for (i, y) in samples.enumerated() {
            let p = viewPoint(SIMD2(Float(i) / 128, y), plot)
            if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
        }
        context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

        for (i, point) in curve.points.enumerated() {
            let c = viewPoint(point, plot)
            let r: CGFloat = (i == active) ? 6.5 : 5
            let dot = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            context.fill(dot, with: .color(tint))
            context.stroke(dot, with: .color(.white), lineWidth: 1.5)
        }
    }

    // MARK: Editing

    private func dragGesture(plot: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if !started {
                    started = true
                    begin(at: g.startLocation, plot: plot)
                }
                if let i = active { move(i, to: g.location, plot: plot) }
            }
            .onEnded { _ in
                started = false
                active = nil
            }
    }

    private func nearestIndex(to location: CGPoint, plot: CGRect) -> Int? {
        let hits = curve.points.enumerated().map { ($0.offset, hypot(viewPoint($0.element, plot).x - location.x,
                                                                       viewPoint($0.element, plot).y - location.y)) }
        guard let best = hits.min(by: { $0.1 < $1.1 }), best.1 <= Self.hitRadius else { return nil }
        return best.0
    }

    private func begin(at location: CGPoint, plot: CGRect) {
        if let i = nearestIndex(to: location, plot: plot) { active = i; return }
        guard curve.points.count < Self.maxPoints, plot.insetBy(dx: -Self.inset, dy: -Self.inset).contains(location) else { return }
        active = curve.addPoint(unitPoint(location, plot))
    }

    private func move(_ index: Int, to location: CGPoint, plot: CGRect) {
        guard curve.points.indices.contains(index) else { active = nil; return }
        let interior = index > 0 && index < curve.points.count - 1
        let far = Self.deleteDistance
        let outside = location.x < plot.minX - far || location.x > plot.maxX + far
            || location.y < plot.minY - far || location.y > plot.maxY + far
        if interior && outside {
            curve.removePoint(at: index)
            active = nil
            return
        }
        curve.movePoint(at: index, to: unitPoint(location, plot))
    }

    private func removeNearest(to location: CGPoint, plot: CGRect) {
        guard let i = nearestIndex(to: location, plot: plot), i > 0, i < curve.points.count - 1 else { return }
        curve.removePoint(at: i)
        active = nil
    }
}

// MARK: - Shared building blocks

private let adjMinusSign = "\u{2212}"

private func adjFormatted(_ v: Float, decimals: Int, signed: Bool) -> String {
    let rounded = (v * pow(10, Float(decimals))).rounded() / pow(10, Float(decimals))
    if rounded == 0 { return decimals == 0 ? "0" : String(format: "%.\(decimals)f", 0) }
    let body = String(format: "%.\(decimals)f", abs(rounded))
    if rounded < 0 { return adjMinusSign + body }
    return signed ? "+" + body : body
}

/// An HSB colour (sRGB) used for swatches and slider tracks.
private func adjHSB(_ degrees: Float, _ s: Double = 1, _ b: Double = 1) -> Color {
    let h = (Double(degrees).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
    return Color(hue: h, saturation: s, brightness: b)
}

/// A labelled slider with a value read-out. Double-click (double-tap) resets to `neutral`.
/// With `track` colours the bar is a gradient (white-balance, HSL, …); otherwise it fills from `neutral` to the value.
private struct AdjSliderRow: View {
    let title: String
    @Binding var value: Float
    var range: ClosedRange<Float> = -100...100
    var neutral: Float = 0
    var step: Float = 1
    var decimals = 0
    var track: [Color]?
    var tint: Color = .accentColor
    var signed = true
    var suffix = ""

    init(_ title: String, _ value: Binding<Float>, range: ClosedRange<Float> = -100...100, neutral: Float = 0,
         step: Float = 1, decimals: Int = 0, track: [Color]? = nil, tint: Color = .accentColor,
         signed: Bool = true, suffix: String = "") {
        self.title = title; _value = value; self.range = range; self.neutral = neutral; self.step = step
        self.decimals = decimals; self.track = track; self.tint = tint; self.signed = signed; self.suffix = suffix
    }

    private var fraction: CGFloat {
        CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound)).adjClamped(to: 0...1)
    }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Text(adjFormatted(value, decimals: decimals, signed: signed) + suffix)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(value == neutral ? .secondary : .primary)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { value = neutral }

            GeometryReader { geo in
                let r: CGFloat = 7
                let usable = max(1, geo.size.width - 2 * r)
                let x = r + fraction * usable
                let neutralX = r + CGFloat((neutral - range.lowerBound) / (range.upperBound - range.lowerBound)).adjClamped(to: 0...1) * usable
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12)).frame(height: 4)
                    if let track {
                        Capsule().fill(LinearGradient(colors: track, startPoint: .leading, endPoint: .trailing))
                            .frame(height: 4)
                    } else {
                        Capsule().fill(tint.opacity(0.85))
                            .frame(width: abs(x - neutralX), height: 4)
                            .offset(x: min(x, neutralX))
                    }
                    Circle()
                        .fill(.background)
                        .overlay(Circle().stroke(Color.primary.opacity(0.45), lineWidth: 1))
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                        .frame(width: 2 * r, height: 2 * r)
                        .offset(x: x - r)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    let f = Float(((g.location.x - r) / usable).adjClamped(to: 0...1))
                    set(range.lowerBound + f * (range.upperBound - range.lowerBound))
                })
                .simultaneousGesture(TapGesture(count: 2).onEnded { value = neutral })
            }
            .frame(height: 16)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(adjFormatted(value, decimals: decimals, signed: false) + suffix)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: set(value + max(step, (range.upperBound - range.lowerBound) / 50))
            case .decrement: set(value - max(step, (range.upperBound - range.lowerBound) / 50))
            @unknown default: break
            }
        }
    }

    private func set(_ raw: Float) {
        let snapped = (raw / step).rounded() * step
        let clamped = min(max(snapped, range.lowerBound), range.upperBound)
        if clamped != value { value = clamped }
    }
}

private extension CGFloat {
    func adjClamped(to r: ClosedRange<CGFloat>) -> CGFloat { Swift.min(Swift.max(self, r.lowerBound), r.upperBound) }
}

/// A collapsible titled card on a system material.
private struct AdjGroupCard<Content: View>: View {
    let title: String
    @State private var expanded = true
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Text(title).font(.caption.weight(.semibold)).textCase(.uppercase).foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded { VStack(spacing: 7) { content() } }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A segmented picker without a visible label.
private struct AdjSegmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options.indices, id: \.self) { Text(options[$0].1).tag(options[$0].0) }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .labelsHidden()
    }
}

// MARK: - Light & Color

private struct AdjDevelopPanel: View {
    @Binding var settings: DevelopSettings

    var body: some View {
        VStack(spacing: 8) {
            AdjGroupCard("Light") {
                AdjSliderRow("Exposure", $settings.exposure, range: -5...5, step: 0.01, decimals: 2, suffix: " EV")
                AdjSliderRow("Contrast", $settings.contrast)
                AdjSliderRow("Highlights", $settings.highlights)
                AdjSliderRow("Shadows", $settings.shadows)
                AdjSliderRow("Whites", $settings.whites)
                AdjSliderRow("Blacks", $settings.blacks)
            }
            AdjGroupCard("Color") {
                AdjSliderRow("Temperature", $settings.temperature,
                          track: [Color(red: 0.25, green: 0.52, blue: 1), Color(white: 0.92), Color(red: 1, green: 0.78, blue: 0.2)])
                AdjSliderRow("Tint", $settings.tint,
                          track: [Color(red: 0.2, green: 0.78, blue: 0.35), Color(white: 0.92), Color(red: 0.95, green: 0.25, blue: 0.75)])
                AdjSliderRow("Vibrance", $settings.vibrance,
                          track: [Color(white: 0.55), Color(red: 0.95, green: 0.35, blue: 0.3), Color(red: 1, green: 0.8, blue: 0.2)])
                AdjSliderRow("Saturation", $settings.saturation,
                          track: [Color(white: 0.55), Color(red: 0.95, green: 0.35, blue: 0.3), Color(red: 0.2, green: 0.6, blue: 1)])
            }
            AdjGroupCard("Effects") {
                AdjSliderRow("Clarity", $settings.clarity)
                AdjSliderRow("Dehaze", $settings.dehaze)
            }
        }
    }
}

// MARK: - Tone curve

private enum AdjCurveChannel: String, CaseIterable, Identifiable {
    case master, red, green, blue, luminance
    var id: String { rawValue }
    var title: String {
        switch self {
        case .master: return "RGB"
        case .red: return "R"
        case .green: return "G"
        case .blue: return "B"
        case .luminance: return "Luma"
        }
    }
    var tint: Color {
        switch self {
        case .master: return .primary
        case .red: return Color(red: 1, green: 0.3, blue: 0.28)
        case .green: return Color(red: 0.25, green: 0.8, blue: 0.35)
        case .blue: return Color(red: 0.3, green: 0.5, blue: 1)
        case .luminance: return .orange
        }
    }
    var keyPath: WritableKeyPath<ToneCurveSettings, ResponseCurve> {
        switch self {
        case .master: return \.master
        case .red: return \.red
        case .green: return \.green
        case .blue: return \.blue
        case .luminance: return \.luminance
        }
    }
}

private struct AdjToneCurvePanel: View {
    @Binding var settings: ToneCurveSettings
    @State private var channel: AdjCurveChannel = .master

    var body: some View {
        VStack(spacing: 8) {
            AdjGroupCard("Curve") {
                AdjSegmented(selection: $channel, options: AdjCurveChannel.allCases.map { ($0, $0.title) })
                CurveEditorView(curve: curveBinding, tint: channel.tint)
                    .frame(maxWidth: 300)
                    .id(channel)
                HStack {
                    Text(hint).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset curve") { settings[keyPath: channel.keyPath] = .linear }
                        .buttonStyle(.borderless).font(.caption)
                        .disabled(settings[keyPath: channel.keyPath].isIdentity)
                }
            }
        }
    }

    private var curveBinding: Binding<ResponseCurve> {
        Binding(get: { settings[keyPath: channel.keyPath] }, set: { settings[keyPath: channel.keyPath] = $0 })
    }

    private var hint: String {
        channel == .luminance ? "Changes brightness, keeps hue" : "Click to add, drag out to delete"
    }
}

// MARK: - HSL

private enum AdjHSLTab: String, CaseIterable {
    case hue = "Hue", saturation = "Saturation", luminance = "Luminance"
}

private struct AdjHSLPanel: View {
    @Binding var settings: HSLSettings
    @State private var tab: AdjHSLTab = .hue

    var body: some View {
        AdjGroupCard("HSL") {
            AdjSegmented(selection: $tab, options: AdjHSLTab.allCases.map { ($0, $0.rawValue) })
            ForEach(HueBand.allCases) { band in
                AdjSliderRow(band.displayName, binding(band), neutral: 0, track: track(band))
            }
            HStack {
                Spacer()
                Button("Reset \(tab.rawValue)") { clear(tab) }
                    .buttonStyle(.borderless).font(.caption)
                    .disabled(values(tab).allSatisfy { $0 == 0 })
            }
        }
    }

    private func keyPath(_ tab: AdjHSLTab) -> WritableKeyPath<HSLSettings, [Float]> {
        switch tab {
        case .hue: return \.hue
        case .saturation: return \.saturation
        case .luminance: return \.luminance
        }
    }

    private func values(_ tab: AdjHSLTab) -> [Float] { settings[keyPath: keyPath(tab)] }

    private func clear(_ tab: AdjHSLTab) { settings[keyPath: keyPath(tab)] = Array(repeating: 0, count: 8) }

    private func binding(_ band: HueBand) -> Binding<Float> {
        let kp = keyPath(tab), i = band.rawValue
        return Binding(
            get: { settings[keyPath: kp].indices.contains(i) ? settings[keyPath: kp][i] : 0 },
            set: { v in
                var a = settings[keyPath: kp]
                if a.count < 8 { a += Array(repeating: 0, count: 8 - a.count) }
                a[i] = v
                settings[keyPath: kp] = a
            })
    }

    /// Slider tracks show what the slider does to that band's colour.
    private func track(_ band: HueBand) -> [Color] {
        let c = band.centerDegrees
        switch tab {
        case .hue: return [adjHSB(c - 30), adjHSB(c), adjHSB(c + 30)]
        case .saturation: return [Color(white: 0.55), adjHSB(c)]
        case .luminance: return [adjHSB(c, 1, 0.25), adjHSB(c), adjHSB(c, 0.35, 1)]
        }
    }
}

// MARK: - Colour grading

private enum AdjGradingZone: String, CaseIterable, Identifiable {
    case shadows, midtones, highlights, global
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var keyPath: WritableKeyPath<ColorGradingSettings, ColorWheel> {
        switch self {
        case .shadows: return \.shadows
        case .midtones: return \.midtones
        case .highlights: return \.highlights
        case .global: return \.global
        }
    }
}

private struct AdjColorGradingPanel: View {
    @Binding var settings: ColorGradingSettings
    @State private var zone: AdjGradingZone = .shadows

    var body: some View {
        VStack(spacing: 8) {
            AdjGroupCard("Color Wheels") {
                AdjSegmented(selection: $zone, options: AdjGradingZone.allCases.map { ($0, $0.title) })
                AdjGradingWheel(wheel: wheelBinding)
                    .frame(maxWidth: 220)
                    .frame(maxWidth: .infinity)
                AdjSliderRow("Luminance", Binding(get: { wheelBinding.wrappedValue.luminance },
                                               set: { wheelBinding.wrappedValue.luminance = $0 }),
                          track: [Color(white: 0.1), Color(white: 0.55), Color(white: 0.97)])
            }
            AdjGroupCard("Balance") {
                AdjSliderRow("Blending", $settings.blending, range: 0...100, neutral: 50, signed: false)
                AdjSliderRow("Balance", $settings.balance)
            }
        }
    }

    private var wheelBinding: Binding<ColorWheel> {
        Binding(get: { settings[keyPath: zone.keyPath] }, set: { settings[keyPath: zone.keyPath] = $0 })
    }
}

/// A hue/saturation wheel: the puck's angle is the hue, its distance from the centre the saturation.
private struct AdjGradingWheel: View {
    @Binding var wheel: ColorWheel

    private static let hues = (0...12).map { Color(hue: Double($0) / 12, saturation: 1, brightness: 1) }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let radius = side / 2 - 8
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let angle = Double(wheel.hue) * .pi / 180
            let distance = radius * CGFloat(max(0, min(100, wheel.saturation)) / 100)
            let puck = CGPoint(x: center.x + distance * CGFloat(cos(angle)), y: center.y + distance * CGFloat(sin(angle)))
            ZStack {
                Circle()
                    .fill(AngularGradient(colors: Self.hues, center: .center))
                    .frame(width: 2 * radius, height: 2 * radius)
                    .overlay(Circle().fill(RadialGradient(colors: [Color(white: 0.5), Color(white: 0.5).opacity(0)],
                                                          center: .center, startRadius: 0, endRadius: radius)))
                    .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1))
                    .position(center)
                Circle()
                    .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                    .frame(width: radius, height: radius)
                    .position(center)
                Circle()
                    .fill(puckColor)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.45), radius: 2)
                    .frame(width: 18, height: 18)
                    .position(puck)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let dx = g.location.x - center.x, dy = g.location.y - center.y
                var degrees = atan2(dy, dx) * 180 / .pi
                if degrees < 0 { degrees += 360 }
                let r = min(1, hypot(dx, dy) / max(1, radius))
                if r > 0.04 { wheel.hue = Float((degrees * 2).rounded() / 2) }
                wheel.saturation = Float((r * 100).rounded())
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded { wheel.hue = 0; wheel.saturation = 0 })
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Color wheel")
        .accessibilityValue("Hue \(Int(wheel.hue)) degrees, saturation \(Int(wheel.saturation))")
        .overlay(alignment: .bottom) {
            Text("H \(Int(wheel.hue))\u{00B0}  S \(Int(wheel.saturation))")
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .offset(y: 14)
        }
        .padding(.bottom, 14)
    }

    private var puckColor: Color {
        wheel.saturation <= 0 ? Color(white: 0.5) : adjHSB(wheel.hue, Double(wheel.saturation) / 100, 1)
    }
}

// MARK: - Gradient map

private enum AdjustmentColorBridge {
    private static let p3 = CGColorSpace(name: CGColorSpace.displayP3)!

    /// Straight RGBA in Display P3 from whatever colour space a `ColorPicker` hands back.
    static func p3Components(_ color: Color) -> SIMD4<Float> {
        let cg = color.resolve(in: EnvironmentValues()).cgColor
        let converted = cg.converted(to: p3, intent: .defaultIntent, options: nil) ?? cg
        let c = converted.components ?? []
        guard c.count >= 3 else { return SIMD4(0, 0, 0, 1) }
        return SIMD4(Float(c[0]), Float(c[1]), Float(c[2]), c.count > 3 ? Float(c[3]) : 1)
    }

    static func color(_ c: SIMD4<Float>) -> Color {
        Color(.displayP3, red: Double(c.x), green: Double(c.y), blue: Double(c.z), opacity: Double(c.w))
    }
}

private struct AdjGradientMapPanel: View {
    @Binding var settings: GradientMapSettings
    @State private var selection: UUID?

    private static let presets: [(String, [(Float, SIMD4<Float>)])] = [
        ("Black & White", [(0, SIMD4(0, 0, 0, 1)), (1, SIMD4(1, 1, 1, 1))]),
        ("Sepia", [(0, SIMD4(0.1, 0.06, 0.03, 1)), (0.55, SIMD4(0.68, 0.5, 0.33, 1)), (1, SIMD4(1, 0.95, 0.84, 1))]),
        ("Duotone Blue / Orange", [(0, SIMD4(0.04, 0.1, 0.35, 1)), (0.5, SIMD4(0.55, 0.45, 0.55, 1)), (1, SIMD4(1, 0.72, 0.3, 1))]),
        ("Sunset", [(0, SIMD4(0.08, 0.02, 0.2, 1)), (0.4, SIMD4(0.75, 0.15, 0.35, 1)), (0.75, SIMD4(1, 0.55, 0.2, 1)), (1, SIMD4(1, 0.93, 0.7, 1))]),
        ("Infrared", [(0, SIMD4(0.05, 0, 0.12, 1)), (0.5, SIMD4(0.9, 0.2, 0.45, 1)), (1, SIMD4(1, 0.95, 0.9, 1))]),
        ("Cyanotype", [(0, SIMD4(0.0, 0.05, 0.2, 1)), (0.6, SIMD4(0.2, 0.5, 0.75, 1)), (1, SIMD4(0.93, 0.97, 1, 1))]),
    ]

    var body: some View {
        VStack(spacing: 8) {
            AdjGroupCard("Gradient") {
                AdjGradientBar(settings: $settings, selection: $selection)
                HStack {
                    Toggle("Reverse", isOn: $settings.reversed).toggleStyle(.switch).controlSize(.small).font(.caption)
                    Spacer()
                    Menu("Presets") {
                        ForEach(Self.presets.indices, id: \.self) { i in
                            Button(Self.presets[i].0) { apply(Self.presets[i].1) }
                        }
                    }
                    .menuStyle(.borderlessButton).font(.caption).fixedSize()
                }
            }
            if let stop = selectedStop {
                AdjGroupCard("Selected Stop") {
                    HStack {
                        Text("Color").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        ColorPicker("Stop color", selection: colorBinding(stop.id), supportsOpacity: true).labelsHidden()
                    }
                    AdjSliderRow("Location", locationBinding(stop.id), range: 0...100, step: 1, signed: false, suffix: " %")
                    HStack {
                        Button("Add stop") { add(after: stop) }.buttonStyle(.borderless).font(.caption)
                        Spacer()
                        Button("Delete stop", role: .destructive) { remove(stop.id) }
                            .buttonStyle(.borderless).font(.caption).disabled(settings.stops.count <= 2)
                    }
                }
            }
        }
        .onAppear { if selection == nil { selection = settings.stops.first?.id } }
        .onChange(of: settings.stops.map(\.id)) { _, ids in
            if let s = selection, !ids.contains(s) { selection = ids.first }
        }
    }

    private var selectedStop: GradientStop? {
        settings.stops.first { $0.id == selection } ?? settings.stops.first
    }

    private func index(_ id: UUID) -> Int? { settings.stops.firstIndex { $0.id == id } }

    private func colorBinding(_ id: UUID) -> Binding<Color> {
        Binding(
            get: { AdjustmentColorBridge.color(index(id).map { settings.stops[$0].color } ?? SIMD4(0, 0, 0, 1)) },
            set: { if let i = index(id) { settings.stops[i].color = AdjustmentColorBridge.p3Components($0) } })
    }

    private func locationBinding(_ id: UUID) -> Binding<Float> {
        Binding(
            get: { (index(id).map { settings.stops[$0].location } ?? 0) * 100 },
            set: { if let i = index(id) { settings.stops[i].location = max(0, min(1, $0 / 100)) } })
    }

    private func add(after stop: GradientStop) {
        let sorted = settings.stops.sorted { $0.location < $1.location }
        let i = sorted.firstIndex { $0.id == stop.id } ?? 0
        let next = i + 1 < sorted.count ? sorted[i + 1].location : max(0, stop.location - 0.2)
        let t = (stop.location + next) / 2
        let new = GradientStop(location: t, color: AdjGradientBar.color(at: t, in: settings.stops))
        settings.stops.append(new)
        selection = new.id
    }

    private func remove(_ id: UUID) {
        guard settings.stops.count > 2, let i = index(id) else { return }
        settings.stops.remove(at: i)
        selection = settings.stops.first?.id
    }

    private func apply(_ stops: [(Float, SIMD4<Float>)]) {
        settings.stops = stops.map { GradientStop(location: $0.0, color: $0.1) }
        selection = settings.stops.first?.id
    }
}

/// The gradient preview with draggable stop markers underneath. Click the bar to add a stop; drag a marker
/// sideways to move it, or far below the bar to delete it.
private struct AdjGradientBar: View {
    @Binding var settings: GradientMapSettings
    @Binding var selection: UUID?

    private let barHeight: CGFloat = 34
    private let markerHeight: CGFloat = 24

    static func color(at t: Float, in stops: [GradientStop]) -> SIMD4<Float> {
        let s = stops.sorted { $0.location < $1.location }
        guard let first = s.first, let last = s.last else { return SIMD4(t, t, t, 1) }
        if t <= first.location { return first.color }
        if t >= last.location { return last.color }
        for k in 0..<(s.count - 1) where t <= s[k + 1].location {
            let span = s[k + 1].location - s[k].location
            let u = span > 1e-6 ? (t - s[k].location) / span : 1
            return s[k].color + (s[k + 1].color - s[k].color) * u
        }
        return last.color
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    // checkerboard under the gradient so stop opacity is visible
                    let cell: CGFloat = 6
                    let bar = CGRect(x: 0, y: 0, width: size.width, height: barHeight)
                    context.clip(to: Path(roundedRect: bar, cornerRadius: 6))
                    for row in 0..<Int(ceil(barHeight / cell)) {
                        for col in 0..<Int(ceil(size.width / cell)) where (row + col) % 2 == 0 {
                            context.fill(Path(CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                                         with: .color(.primary.opacity(0.12)))
                        }
                    }
                    context.fill(Path(bar), with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
                }
                .frame(height: barHeight)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.25), lineWidth: 1))
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { tap in
                    guard w > 0 else { return }
                    let t = Float((tap.location.x / w).adjClamped(to: 0...1))
                    let display = settings.reversed ? 1 - t : t
                    let new = GradientStop(location: display, color: Self.color(at: display, in: settings.stops))
                    settings.stops.append(new)
                    selection = new.id
                })

                ForEach(settings.stops) { stop in
                    marker(stop, width: w)
                }
            }
            .coordinateSpace(name: "gradientBar")
        }
        .frame(height: barHeight + markerHeight + 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Gradient, \(settings.stops.count) stops")
    }

    private func displayX(_ stop: GradientStop, _ w: CGFloat) -> CGFloat {
        CGFloat(settings.reversed ? 1 - stop.location : stop.location) * w
    }

    private func marker(_ stop: GradientStop, width w: CGFloat) -> some View {
        let selected = stop.id == selection
        return ZStack {
            AdjTriangle().fill(selected ? Color.accentColor : Color.primary.opacity(0.55)).frame(width: 12, height: 7).offset(y: -9)
            RoundedRectangle(cornerRadius: 3)
                .fill(AdjustmentColorBridge.color(SIMD4(stop.color.x, stop.color.y, stop.color.z, 1)))
                .frame(width: 14, height: 14)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(selected ? Color.accentColor : Color.white, lineWidth: selected ? 2 : 1.5))
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                .offset(y: 3)
        }
        .frame(width: 28, height: markerHeight)
        .contentShape(Rectangle())
        .position(x: displayX(stop, w), y: barHeight + markerHeight / 2 + 2)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("gradientBar"))
                .onChanged { g in
                    selection = stop.id
                    guard w > 0, let i = settings.stops.firstIndex(where: { $0.id == stop.id }) else { return }
                    if g.location.y > barHeight + 70 || g.location.y < -50, settings.stops.count > 2 {
                        settings.stops.remove(at: i)
                        selection = settings.stops.first?.id
                        return
                    }
                    let t = Float((g.location.x / w).adjClamped(to: 0...1))
                    settings.stops[i].location = settings.reversed ? 1 - t : t
                })
        .accessibilityLabel("Gradient stop at \(Int(stop.location * 100)) percent")
    }

    /// The preview gradient (respecting `reversed`). Stops sit at their location; the ends extend flat.
    private var gradient: Gradient {
        let sorted = settings.stops.sorted { $0.location < $1.location }
        guard !sorted.isEmpty else { return Gradient(colors: [.black, .white]) }
        var stops = sorted.map { Gradient.Stop(color: AdjustmentColorBridge.color($0.color), location: CGFloat(settings.reversed ? 1 - $0.location : $0.location)) }
        if settings.reversed { stops.reverse() }
        return Gradient(stops: stops)
    }
}

private struct AdjTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Selective colour

private extension SelectiveColorRange {
    var adjSwatch: Color {
        switch self {
        case .reds: return adjHSB(0)
        case .yellows: return adjHSB(60)
        case .greens: return adjHSB(120)
        case .cyans: return adjHSB(180)
        case .blues: return adjHSB(240)
        case .magentas: return adjHSB(300)
        case .whites: return Color(white: 0.96)
        case .neutrals: return Color(white: 0.5)
        case .blacks: return Color(white: 0.08)
        }
    }
}

private struct AdjSelectiveColorPanel: View {
    @Binding var settings: SelectiveColorSettings
    @State private var range: SelectiveColorRange = .reds

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 3)

    var body: some View {
        VStack(spacing: 8) {
            AdjGroupCard("Colors") {
                LazyVGrid(columns: columns, spacing: 5) {
                    ForEach(SelectiveColorRange.allCases) { r in chip(r) }
                }
            }
            AdjGroupCard("Adjust \(range.displayName)") {
                AdjSliderRow("Cyan", binding(\.cyan), track: [Color(red: 1, green: 0.35, blue: 0.3), Color(white: 0.9), Color(red: 0, green: 0.85, blue: 0.95)])
                AdjSliderRow("Magenta", binding(\.magenta), track: [Color(red: 0.2, green: 0.85, blue: 0.35), Color(white: 0.9), Color(red: 0.95, green: 0.2, blue: 0.75)])
                AdjSliderRow("Yellow", binding(\.yellow), track: [Color(red: 0.25, green: 0.4, blue: 1), Color(white: 0.9), Color(red: 1, green: 0.88, blue: 0.1)])
                AdjSliderRow("Black", binding(\.black), track: [Color(white: 0.95), Color(white: 0.5), Color(white: 0.05)])
                AdjSegmented(selection: $settings.relative, options: [(true, "Relative"), (false, "Absolute")])
                HStack {
                    Text(settings.relative ? "Percent of the ink already there" : "Adds or removes whole percent")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset range") { setAdjustment(CMYKAdjustment(), for: range) }
                        .buttonStyle(.borderless).font(.caption)
                        .disabled(adjustment(for: range) == CMYKAdjustment())
                }
            }
        }
    }

    private func adjustment(for r: SelectiveColorRange) -> CMYKAdjustment {
        settings.ranges.indices.contains(r.rawValue) ? settings.ranges[r.rawValue] : CMYKAdjustment()
    }

    private func setAdjustment(_ a: CMYKAdjustment, for r: SelectiveColorRange) {
        if settings.ranges.count < 9 { settings.ranges += Array(repeating: CMYKAdjustment(), count: 9 - settings.ranges.count) }
        settings.ranges[r.rawValue] = a
    }

    private func binding(_ kp: WritableKeyPath<CMYKAdjustment, Float>) -> Binding<Float> {
        let r = range
        return Binding(get: { adjustment(for: r)[keyPath: kp] },
                       set: { v in var a = adjustment(for: r); a[keyPath: kp] = v; setAdjustment(a, for: r) })
    }

    private func chip(_ r: SelectiveColorRange) -> some View {
        let selected = r == range
        let edited = adjustment(for: r) != CMYKAdjustment()
        return Button { range = r } label: {
            HStack(spacing: 4) {
                Circle().fill(r.adjSwatch).overlay(Circle().stroke(Color.primary.opacity(0.35), lineWidth: 0.5)).frame(width: 9, height: 9)
                Text(r.displayName).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
                if edited { Circle().fill(Color.accentColor).frame(width: 4, height: 4) }
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(selected ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(r.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
