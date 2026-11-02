// Brush rasterisation on the GPU.
//
// A stroke is painted in two stages, like Photoshop and Procreate:
//  1. `stampDabs` accumulates dabs into a separate *stroke buffer* (premultiplied colour). Flow builds
//     up within the stroke; each dab also carries an opacity cap (pressure → opacity).
//  2. The stroke buffer is shown live on top of its layer by the compositor, and merged into the layer
//     by `applyStroke` when the pen lifts — scaled by the stroke opacity, clipped by the selection,
//     honouring alpha lock, or erasing. Painting on a layer mask uses the same buffers.
// Smudge is different: `smudgeDab` drags existing layer pixels along, dab by dab.

enum StrokeShader: ShaderModule {
    static let moduleName = "stroke"

    /// Dab shape + stroke-merge maths, shared with the compositor (which previews strokes live).
    static let applyFunctions = """
    struct ApplyParams {
        uint2 origin;
        uint mode;          // 0 paint, 1 erase
        float opacity;      // the stroke's opacity slider
        uint alphaLock;
        uint hasSelection;
        uint target;        // 0 layer content, 1 layer mask
        uint pad;
    };

    inline float4 strokeOntoContent(float4 src, float4 s, float sel, constant ApplyParams& P) {
        float a = s.a * P.opacity * sel;
        if (a <= 0.0) return src;
        if (P.mode == 1) return P.alphaLock != 0 ? src : src * (1.0 - a);
        float3 c = s.rgb / max(s.a, 1.0e-5);
        if (P.alphaLock != 0) return float4(mix(src.rgb, c * src.a, a), src.a);
        return float4(c * a, a) + src * (1.0 - a);
    }

    inline float strokeOntoMask(float m, float4 s, float sel, constant ApplyParams& P) {
        float a = s.a * P.opacity * sel;
        float target = P.mode == 1 ? 0.0 : saturate(luma(s.rgb / max(s.a, 1.0e-5)));
        return mix(m, target, a);
    }
    """

    static let source = applyFunctions + """

    struct Dab {
        float4 color;        // straight rgb, a = opacity cap
        float2 center;
        float2 grainOffset;
        float2 dualOffset;
        float radius;
        float angle;
        float roundness;
        float flow;
        float dualAngle;
        float flip;
    };

    struct StrokeParams {
        uint2 origin;
        uint dabCount;
        uint tipKind;        // 0 analytic round, 1 texture
        float hardness;
        uint grainMode;      // 0 none, 1 moving, 2 texturized
        float grainScale;    // canvas pixels per grain texel
        float grainDepth;
        uint dualMode;       // 0 none, 1 multiply, 2 darken, 3 subtract, 4 height
        float dualScale;
        float dualDepth;
        float wetEdges;
        float wetMix;
        float tipTexSize;
        float grainTexSize;
        float dualTexSize;
    };

    inline float tipAlpha(texture2d<float, access::sample> tip, sampler s, float2 uv, float radius,
                          uint kind, float hardness, float texSize) {
        if (kind == 0) {
            float r = length(uv);
            float aa = 1.0 / max(radius, 0.5);
            float h = clamp(hardness, 0.0, 1.0) * (1.0 - aa);
            float t = saturate((r - h) / max(1.0 - h, aa));
            return 1.0 - t * t * (3.0 - 2.0 * t);
        }
        if (abs(uv.x) > 1.0 || abs(uv.y) > 1.0) return 0.0;
        float lod = max(0.0, log2(texSize / max(2.0 * radius, 1.0)));
        return tip.sample(s, uv * 0.5 + 0.5, level(lod)).r;
    }

    /// Coverage (0…1) of dab `d` at canvas point `p`, before flow.
    inline float dabCoverage(Dab d, float2 p, constant StrokeParams& P,
                             texture2d<float, access::sample> tip,
                             texture2d<float, access::sample> grain,
                             texture2d<float, access::sample> dual,
                             sampler clampS, sampler repeatS) {
        float2 q = rotate2(p - d.center, -d.angle);
        q.x *= d.flip;
        q.y /= max(d.roundness, 0.02);
        float2 uv = q / d.radius;
        float a = tipAlpha(tip, clampS, uv, d.radius, P.tipKind, P.hardness, P.tipTexSize);
        if (a <= 0.0) return 0.0;

        if (P.dualMode != 0) {
            float2 duv = rotate2(uv, d.dualAngle) / max(P.dualScale, 0.05) + d.dualOffset;
            float lod = max(0.0, log2(P.dualTexSize * max(P.dualScale, 0.05) / max(2.0 * d.radius, 1.0)));
            float dv = dual.sample(repeatS, duv * 0.5 + 0.5, level(lod)).r;
            float b = a;
            if (P.dualMode == 1) b = a * dv;
            else if (P.dualMode == 2) b = min(a, dv);
            else if (P.dualMode == 3) b = saturate(a - (1.0 - dv));
            else b = saturate((a + dv - 1.0) * 2.0);
            a = mix(a, b, P.dualDepth);
        }

        if (P.grainMode != 0) {
            float cell = max(P.grainScale, 0.05) * P.grainTexSize;
            float2 guv = P.grainMode == 2 ? p / cell : q / cell + d.grainOffset;
            float lod = max(0.0, log2(1.0 / max(P.grainScale, 0.05)));
            float g = grain.sample(repeatS, guv, level(lod)).r;
            a *= mix(1.0, g, P.grainDepth);
        }

        if (P.wetEdges > 0.0) {
            a = a * (1.0 - 0.5 * P.wetEdges) + P.wetEdges * 1.2 * a * (1.0 - a);
        }
        return saturate(a);
    }

    kernel void stampDabs(texture2d<float, access::read_write> stroke [[texture(0)]],
                          texture2d<float, access::sample> tip [[texture(1)]],
                          texture2d<float, access::sample> grain [[texture(2)]],
                          texture2d<float, access::sample> dual [[texture(3)]],
                          texture2d<float, access::sample> layer [[texture(4)]],
                          sampler clampS [[sampler(0)]],
                          sampler repeatS [[sampler(1)]],
                          constant StrokeParams& P [[buffer(0)]],
                          device const Dab* dabs [[buffer(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
        uint2 pix = P.origin + gid;
        if (outside(pix, stroke)) return;
        float2 p = float2(pix) + 0.5;
        float4 acc = stroke.read(pix);
        bool touched = false;
        float2 layerSize = float2(layer.get_width(), layer.get_height());
        for (uint i = 0; i < P.dabCount; i++) {
            Dab d = dabs[i];
            float2 v = p - d.center;
            float reach = d.radius + 1.5;
            if (abs(v.x) > reach || abs(v.y) > reach) continue;
            float k = dabCoverage(d, p, P, tip, grain, dual, clampS, repeatS) * d.flow;
            if (k <= 0.0) continue;
            float3 color = d.color.rgb;
            if (P.wetMix > 0.0) {
                // Pick up the paint already under the brush centre (averaged over a small cross).
                float2 o = float2(d.radius * 0.35, 0.0);
                float4 pick = layer.sample(clampS, d.center / layerSize, level(0));
                pick += layer.sample(clampS, (d.center + o) / layerSize, level(0));
                pick += layer.sample(clampS, (d.center - o) / layerSize, level(0));
                pick += layer.sample(clampS, (d.center + o.yx) / layerSize, level(0));
                pick += layer.sample(clampS, (d.center - o.yx) / layerSize, level(0));
                pick = unpremultiply(pick / 5.0);
                color = mix(color, pick.rgb, P.wetMix * pick.a);
            }
            float cap = d.color.a;
            if (acc.a < cap) {
                acc = mix(acc, float4(color * cap, cap), k);
            } else {
                acc.rgb = mix(acc.rgb, color * acc.a, k);
            }
            touched = true;
        }
        if (touched) stroke.write(acc, pix);
    }

    /// Merges the finished stroke into the layer content or mask.
    kernel void applyStroke(texture2d<float, access::read_write> target [[texture(0)]],
                            texture2d<float, access::read> stroke [[texture(1)]],
                            texture2d<float, access::read> selection [[texture(2)]],
                            constant ApplyParams& P [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
        uint2 pix = P.origin + gid;
        if (outside(pix, target)) return;
        float4 s = stroke.read(pix);
        if (s.a <= 0.0) return;
        float sel = P.hasSelection != 0 ? saturate(selection.read(pix).r) : 1.0;
        float4 cur = target.read(pix);
        if (P.target == 1) {
            target.write(float4(strokeOntoMask(cur.r, s, sel, P)), pix);
        } else {
            target.write(strokeOntoContent(cur, s, sel, P), pix);
        }
    }

    struct SmudgeParams {
        float2 delta;        // brush movement since the previous dab
        float strength;
        uint alphaLock;
        uint hasSelection;
        uint pad;
    };

    /// Drags pixels along the brush path. `snapshot` is a copy of the layer taken just before this dab.
    kernel void smudgeDab(texture2d<float, access::read_write> layer [[texture(0)]],
                          texture2d<float, access::sample> snapshot [[texture(1)]],
                          texture2d<float, access::sample> tip [[texture(2)]],
                          texture2d<float, access::sample> grain [[texture(3)]],
                          texture2d<float, access::sample> dual [[texture(4)]],
                          texture2d<float, access::read> selection [[texture(5)]],
                          sampler clampS [[sampler(0)]],
                          sampler repeatS [[sampler(1)]],
                          constant StrokeParams& P [[buffer(0)]],
                          constant Dab& d [[buffer(1)]],
                          constant SmudgeParams& M [[buffer(2)]],
                          uint2 gid [[thread_position_in_grid]]) {
        uint2 pix = P.origin + gid;
        if (outside(pix, layer)) return;
        float2 p = float2(pix) + 0.5;
        float k = dabCoverage(d, p, P, tip, grain, dual, clampS, repeatS) * M.strength;
        if (M.hasSelection != 0) k *= saturate(selection.read(pix).r);
        if (k <= 0.0) return;
        float2 size = float2(snapshot.get_width(), snapshot.get_height());
        float4 pulled = snapshot.sample(clampS, (p - M.delta) / size, level(0));
        float4 cur = snapshot.read(pix);
        float4 outC = mix(cur, pulled, k);
        if (M.alphaLock != 0) outC = float4(unpremultiply(outC).rgb * cur.a, cur.a);
        layer.write(outC, pix);
    }
    """
}

// MARK: - Swift mirrors (field order and types must match the MSL structs exactly)

struct ApplyParams {
    var origin: SIMD2<UInt32>
    var mode: UInt32
    var opacity: Float
    var alphaLock: UInt32
    var hasSelection: UInt32
    var target: UInt32
    var pad: UInt32 = 0
}

struct StrokeParams {
    var origin: SIMD2<UInt32> = .zero
    var dabCount: UInt32 = 0
    var tipKind: UInt32 = 0
    var hardness: Float = 1
    var grainMode: UInt32 = 0
    var grainScale: Float = 1
    var grainDepth: Float = 0
    var dualMode: UInt32 = 0
    var dualScale: Float = 1
    var dualDepth: Float = 0
    var wetEdges: Float = 0
    var wetMix: Float = 0
    var tipTexSize: Float = 256
    var grainTexSize: Float = 256
    var dualTexSize: Float = 256
}

struct SmudgeParams {
    var delta: SIMD2<Float>
    var strength: Float
    var alphaLock: UInt32
    var hasSelection: UInt32
    var pad: UInt32 = 0
}
