import Foundation
import simd

/// The kinds of non-destructive adjustment layer Paper offers.
public enum AdjustmentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Lightroom "Basic" panel: exposure, contrast, highlights/shadows, whites/blacks, white balance,
    /// vibrance/saturation, clarity and dehaze.
    case develop
    /// Composite + per-channel RGB curves and a luminance curve, evaluated in 32-bit float.
    case toneCurve
    /// Per-hue-band hue / saturation / luminance (8 bands, Lightroom style).
    case hsl
    /// Shadows / midtones / highlights / global colour wheels.
    case colorGrading
    case gradientMap
    case selectiveColor

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .develop: return "Light & Color"
        case .toneCurve: return "Tone Curve"
        case .hsl: return "HSL"
        case .colorGrading: return "Color Grading"
        case .gradientMap: return "Gradient Map"
        case .selectiveColor: return "Selective Color"
        }
    }
}

/// All parameters of one adjustment layer. Only the block matching `kind` is used; the others keep
/// their defaults so switching kinds never loses data.
public struct AdjustmentSettings: Codable, Equatable, Sendable {
    public var kind: AdjustmentKind
    public var develop = DevelopSettings()
    public var curves = ToneCurveSettings()
    public var hsl = HSLSettings()
    public var grading = ColorGradingSettings()
    public var gradientMap = GradientMapSettings()
    public var selectiveColor = SelectiveColorSettings()

    public init(kind: AdjustmentKind) { self.kind = kind }
}

/// Lightroom-style Basic panel. Sliders use Lightroom's ranges: exposure in stops (−5…+5), everything
/// else −100…+100 with 0 meaning "no change".
public struct DevelopSettings: Codable, Equatable, Sendable {
    public var exposure: Float = 0
    public var contrast: Float = 0
    public var highlights: Float = 0
    public var shadows: Float = 0
    public var whites: Float = 0
    public var blacks: Float = 0
    public var temperature: Float = 0
    public var tint: Float = 0
    public var vibrance: Float = 0
    public var saturation: Float = 0
    public var clarity: Float = 0
    public var dehaze: Float = 0
    public init() {}
}

public struct ToneCurveSettings: Codable, Equatable, Sendable {
    /// Applied to R, G and B together.
    public var master: ResponseCurve = .linear
    public var red: ResponseCurve = .linear
    public var green: ResponseCurve = .linear
    public var blue: ResponseCurve = .linear
    /// Applied to luminance only (hue and saturation kept).
    public var luminance: ResponseCurve = .linear
    public init() {}
}

/// Lightroom's eight HSL hue bands.
public enum HueBand: Int, Codable, CaseIterable, Identifiable, Sendable {
    case red, orange, yellow, green, aqua, blue, purple, magenta
    public var id: Int { rawValue }
    /// Band centre on the hue circle, in degrees.
    public var centerDegrees: Float { [0, 30, 60, 120, 180, 225, 270, 315][rawValue] }
    public var displayName: String { ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"][rawValue] }
}

public struct HSLSettings: Codable, Equatable, Sendable {
    /// Per band, −100…+100. Hue shifts up to ±30° at the extremes.
    public var hue: [Float] = Array(repeating: 0, count: 8)
    public var saturation: [Float] = Array(repeating: 0, count: 8)
    public var luminance: [Float] = Array(repeating: 0, count: 8)
    public init() {}
}

public struct ColorWheel: Codable, Equatable, Sendable {
    /// 0…360°.
    public var hue: Float = 0
    /// 0…100.
    public var saturation: Float = 0
    /// −100…+100.
    public var luminance: Float = 0
    public init(hue: Float = 0, saturation: Float = 0, luminance: Float = 0) {
        self.hue = hue; self.saturation = saturation; self.luminance = luminance
    }
}

public struct ColorGradingSettings: Codable, Equatable, Sendable {
    public var shadows = ColorWheel()
    public var midtones = ColorWheel()
    public var highlights = ColorWheel()
    public var global = ColorWheel()
    /// How much the three tonal ranges overlap, 0…100 (Lightroom default 50).
    public var blending: Float = 50
    /// Shifts the shadow/highlight split, −100…+100.
    public var balance: Float = 0
    public init() {}
}

public struct GradientStop: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    /// 0…1 along the gradient.
    public var location: Float
    /// Straight (not premultiplied) RGBA, gamma-encoded Display P3.
    public var color: SIMD4<Float>
    public init(location: Float, color: SIMD4<Float>) { self.location = location; self.color = color }
}

public struct GradientMapSettings: Codable, Equatable, Sendable {
    public var stops: [GradientStop] = [
        GradientStop(location: 0, color: SIMD4(0.05, 0.02, 0.15, 1)),
        GradientStop(location: 0.5, color: SIMD4(0.85, 0.25, 0.3, 1)),
        GradientStop(location: 1, color: SIMD4(1, 0.95, 0.75, 1)),
    ]
    public var reversed = false
    public init() {}
}

/// Photoshop's Selective Color colour ranges.
public enum SelectiveColorRange: Int, Codable, CaseIterable, Identifiable, Sendable {
    case reds, yellows, greens, cyans, blues, magentas, whites, neutrals, blacks
    public var id: Int { rawValue }
    public var displayName: String {
        ["Reds", "Yellows", "Greens", "Cyans", "Blues", "Magentas", "Whites", "Neutrals", "Blacks"][rawValue]
    }
}

/// Cyan / magenta / yellow / black adjustments for one range, each −100…+100.
public struct CMYKAdjustment: Codable, Equatable, Sendable {
    public var cyan: Float = 0
    public var magenta: Float = 0
    public var yellow: Float = 0
    public var black: Float = 0
    public init() {}
}

public struct SelectiveColorSettings: Codable, Equatable, Sendable {
    /// Indexed by `SelectiveColorRange.rawValue`.
    public var ranges: [CMYKAdjustment] = Array(repeating: CMYKAdjustment(), count: 9)
    /// Photoshop's "Relative" (true) vs "Absolute" method.
    public var relative = true
    public init() {}
}
