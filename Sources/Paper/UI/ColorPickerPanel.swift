import SwiftUI
import simd

extension Color {
    /// A SwiftUI colour from straight Display P3 components.
    public init(p3 c: SIMD3<Float>, opacity: Double = 1) {
        self.init(.displayP3, red: Double(c.x), green: Double(c.y), blue: Double(c.z), opacity: opacity)
    }

    /// Display P3 components of this colour (nil for dynamic system colours).
    public var p3Components: SIMD3<Float>? {
        guard let cg = cgColor, let p3 = CGColorSpace(name: CGColorSpace.displayP3),
              let converted = cg.converted(to: p3, intent: .defaultIntent, options: nil),
              let comps = converted.components, comps.count >= 3 else { return nil }
        return SIMD3(Float(comps[0]), Float(comps[1]), Float(comps[2]))
    }
}

/// Procreate-style colour panel: saturation/brightness square, hue strip, hex entry, the system
/// picker, recent colours and a default palette. Works in Display P3.
public struct ColorPickerPanel: View {
    @Binding var color: SIMD3<Float>
    var recent: [SIMD3<Float>]
    @State private var hsb = SIMD3<Float>(0, 0, 0)
    @State private var hexText = ""

    public init(color: Binding<SIMD3<Float>>, recent: [SIMD3<Float>]) {
        _color = color
        self.recent = recent
    }

    static let palette: [SIMD3<Float>] = [
        SIMD3(0, 0, 0), SIMD3(0.25, 0.25, 0.27), SIMD3(0.5, 0.5, 0.52), SIMD3(0.78, 0.78, 0.8), SIMD3(1, 1, 1),
        SIMD3(0.9, 0.16, 0.2), SIMD3(0.98, 0.5, 0.13), SIMD3(0.99, 0.82, 0.2), SIMD3(0.36, 0.75, 0.3), SIMD3(0.13, 0.6, 0.55),
        SIMD3(0.2, 0.55, 0.95), SIMD3(0.3, 0.3, 0.8), SIMD3(0.58, 0.32, 0.85), SIMD3(0.92, 0.4, 0.68), SIMD3(0.55, 0.36, 0.22),
        SIMD3(0.96, 0.85, 0.72), SIMD3(0.85, 0.65, 0.5), SIMD3(0.6, 0.42, 0.32), SIMD3(0.35, 0.22, 0.17), SIMD3(0.12, 0.18, 0.3),
    ]

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            saturationSquare
                .frame(height: 190)
            hueStrip
                .frame(height: 18)
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(p3: color))
                    .frame(width: 44, height: 32)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.4)))
                TextField("Hex", text: $hexText)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .onSubmit { if let c = ColorMath.fromHex(hexText) { setColor(c) } }
                ColorPicker("", selection: Binding(
                    get: { Color(p3: color) },
                    set: { if let c = $0.p3Components { setColor(simd_clamp(c, .zero, SIMD3(repeating: 1))) } }),
                    supportsOpacity: false)
                    .labelsHidden()
            }
            if !recent.isEmpty {
                Text("Recent").font(.caption).foregroundStyle(.secondary)
                swatches(recent)
            }
            Text("Palette").font(.caption).foregroundStyle(.secondary)
            swatches(Self.palette)
        }
        .onAppear { syncFromColor() }
        .onChange(of: color) { _, _ in
            if simd_distance(ColorMath.hsbToRGB(hsb), color) > 0.002 { syncFromColor() }
            hexText = ColorMath.hex(color)
        }
    }

    private func syncFromColor() {
        let h = ColorMath.rgbToHSB(color)
        // Keep the hue when the colour is grey so the square doesn't jump.
        hsb = SIMD3(h.y < 0.001 ? hsb.x : h.x, h.y, h.z)
        hexText = ColorMath.hex(color)
    }

    private func setColor(_ c: SIMD3<Float>) {
        color = c
        syncFromColor()
    }

    private var saturationSquare: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle().fill(Color(p3: ColorMath.hsbToRGB(SIMD3(hsb.x, 1, 1))))
                Rectangle().fill(LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing))
                Rectangle().fill(LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom))
                Circle()
                    .stroke(.white, lineWidth: 2)
                    .shadow(radius: 1)
                    .frame(width: 16, height: 16)
                    .position(x: CGFloat(hsb.y) * geo.size.width, y: CGFloat(1 - hsb.z) * geo.size.height)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let s = Float(min(max(v.location.x / geo.size.width, 0), 1))
                let b = Float(min(max(1 - v.location.y / geo.size.height, 0), 1))
                hsb = SIMD3(hsb.x, s, b)
                color = ColorMath.hsbToRGB(hsb)
            })
        }
    }

    private var hueStrip: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(colors: (0...6).map { Color(p3: ColorMath.hsbToRGB(SIMD3(Float($0) / 6, 1, 1))) },
                                              startPoint: .leading, endPoint: .trailing))
                Circle()
                    .fill(Color(p3: ColorMath.hsbToRGB(SIMD3(hsb.x, 1, 1))))
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .frame(width: 18, height: 18)
                    .offset(x: CGFloat(hsb.x) * (geo.size.width - 18))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                hsb.x = Float(min(max(v.location.x / geo.size.width, 0), 0.9999))
                color = ColorMath.hsbToRGB(hsb)
            })
        }
    }

    private func swatches(_ colors: [SIMD3<Float>]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 6), count: 10), alignment: .leading, spacing: 6) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, c in
                Button { setColor(c) } label: {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(p3: c))
                        .frame(width: 24, height: 24)
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .stroke(simd_distance(c, color) < 0.003 ? Color.accentColor : .secondary.opacity(0.3),
                                    lineWidth: simd_distance(c, color) < 0.003 ? 2 : 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
