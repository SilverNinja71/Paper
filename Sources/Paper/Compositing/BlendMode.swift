import Foundation

/// The 27 Photoshop layer blend modes plus Pass Through for groups — 28 in all.
///
/// Case order is the shader's numbering (`shaderIndex`); `CompositeShader` switches on it, so only
/// append new cases at the end.
public enum BlendMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case normal, dissolve
    case darken, multiply, colorBurn, linearBurn, darkerColor
    case lighten, screen, colorDodge, linearDodge, lighterColor
    case overlay, softLight, hardLight, vividLight, linearLight, pinLight, hardMix
    case difference, exclusion, subtract, divide
    case hue, saturation, color, luminosity
    case passThrough

    public var id: String { rawValue }

    public var shaderIndex: UInt32 { UInt32(Self.allCases.firstIndex(of: self)!) }

    public var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .dissolve: return "Dissolve"
        case .darken: return "Darken"
        case .multiply: return "Multiply"
        case .colorBurn: return "Color Burn"
        case .linearBurn: return "Linear Burn"
        case .darkerColor: return "Darker Color"
        case .lighten: return "Lighten"
        case .screen: return "Screen"
        case .colorDodge: return "Color Dodge"
        case .linearDodge: return "Linear Dodge (Add)"
        case .lighterColor: return "Lighter Color"
        case .overlay: return "Overlay"
        case .softLight: return "Soft Light"
        case .hardLight: return "Hard Light"
        case .vividLight: return "Vivid Light"
        case .linearLight: return "Linear Light"
        case .pinLight: return "Pin Light"
        case .hardMix: return "Hard Mix"
        case .difference: return "Difference"
        case .exclusion: return "Exclusion"
        case .subtract: return "Subtract"
        case .divide: return "Divide"
        case .hue: return "Hue"
        case .saturation: return "Saturation"
        case .color: return "Color"
        case .luminosity: return "Luminosity"
        case .passThrough: return "Pass Through"
        }
    }

    /// Modes grouped the way Photoshop's menu separates them (Pass Through is offered for groups only).
    public static let menuGroups: [[BlendMode]] = [
        [.normal, .dissolve],
        [.darken, .multiply, .colorBurn, .linearBurn, .darkerColor],
        [.lighten, .screen, .colorDodge, .linearDodge, .lighterColor],
        [.overlay, .softLight, .hardLight, .vividLight, .linearLight, .pinLight, .hardMix],
        [.difference, .exclusion, .subtract, .divide],
        [.hue, .saturation, .color, .luminosity],
    ]
}
