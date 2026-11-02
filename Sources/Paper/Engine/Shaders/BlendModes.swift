// Layer compositing: the 27 Photoshop blend modes (+ Pass Through for groups), layer masks,
// clipping (source-atop), live stroke preview and live move/transform preview.
//
// Blend formulas follow the W3C Compositing & Blending spec (which documents Photoshop's modes),
// plus Photoshop's Linear Burn / Linear Light / Vivid Light / Pin Light / Hard Mix / Subtract /
// Divide / Darker Color / Lighter Color. With premultiplied source s and backdrop b:
//     co = cs·(1 − ab) + cb·(1 − as) + as·ab·B(Cb, Cs)      ao = as + ab − as·ab
// and for a clipped layer (source-atop):
//     co = cb·(1 − as) + as·ab·B(Cb, Cs)                     ao = ab

enum CompositeShader: ShaderModule {
    static let moduleName = "composite"
    static let source = StrokeShader.applyFunctions + """

    // Indices match BlendMode.allCases.
    constant uint BM_NORMAL = 0, BM_DISSOLVE = 1,
        BM_DARKEN = 2, BM_MULTIPLY = 3, BM_COLORBURN = 4, BM_LINEARBURN = 5, BM_DARKERCOLOR = 6,
        BM_LIGHTEN = 7, BM_SCREEN = 8, BM_COLORDODGE = 9, BM_LINEARDODGE = 10, BM_LIGHTERCOLOR = 11,
        BM_OVERLAY = 12, BM_SOFTLIGHT = 13, BM_HARDLIGHT = 14, BM_VIVIDLIGHT = 15, BM_LINEARLIGHT = 16,
        BM_PINLIGHT = 17, BM_HARDMIX = 18,
        BM_DIFFERENCE = 19, BM_EXCLUSION = 20, BM_SUBTRACT = 21, BM_DIVIDE = 22,
        BM_HUE = 23, BM_SATURATION = 24, BM_COLOR = 25, BM_LUMINOSITY = 26, BM_PASSTHROUGH = 27;

    inline float burn(float b, float s) {
        if (b >= 1.0) return 1.0;
        if (s <= 0.0) return 0.0;
        return 1.0 - min(1.0, (1.0 - b) / s);
    }
    inline float dodge(float b, float s) {
        if (b <= 0.0) return 0.0;
        if (s >= 1.0) return 1.0;
        return min(1.0, b / (1.0 - s));
    }
    inline float hardLightC(float b, float s) {
        return s <= 0.5 ? b * 2.0 * s : 1.0 - (1.0 - b) * (1.0 - (2.0 * s - 1.0));
    }
    inline float softLightC(float b, float s) {
        if (s <= 0.5) return b - (1.0 - 2.0 * s) * b * (1.0 - b);
        float d = b <= 0.25 ? ((16.0 * b - 12.0) * b + 4.0) * b : sqrt(b);
        return b + (2.0 * s - 1.0) * (d - b);
    }
    inline float vividC(float b, float s) {
        return s <= 0.5 ? burn(b, 2.0 * s) : dodge(b, 2.0 * (s - 0.5));
    }
    inline float pinC(float b, float s) {
        return s <= 0.5 ? min(b, 2.0 * s) : max(b, 2.0 * s - 1.0);
    }
    inline float divideC(float b, float s) {
        if (s <= 0.0) return b <= 0.0 ? 0.0 : 1.0;
        return min(1.0, b / s);
    }

    // Non-separable helpers (PDF / W3C definitions).
    inline float lumW(float3 c) { return dot(c, float3(0.3, 0.59, 0.11)); }
    inline float3 clipColor(float3 c) {
        float l = lumW(c);
        float n = min(c.r, min(c.g, c.b));
        float x = max(c.r, max(c.g, c.b));
        if (n < 0.0) c = l + (c - l) * l / max(l - n, 1.0e-6);
        if (x > 1.0) c = l + (c - l) * (1.0 - l) / max(x - l, 1.0e-6);
        return c;
    }
    inline float3 setLum(float3 c, float l) { return clipColor(c + (l - lumW(c))); }
    inline float satW(float3 c) { return max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b)); }
    inline float3 setSat(float3 c, float s) {
        float mx = max(c.r, max(c.g, c.b));
        float mn = min(c.r, min(c.g, c.b));
        float range = mx - mn;
        if (range <= 1.0e-6) return float3(0.0);
        return (c - mn) * s / range;
    }

    /// B(Cb, Cs) on straight colours.
    inline float3 blendColor(float3 b, float3 s, uint mode) {
        switch (mode) {
        case BM_DARKEN: return min(b, s);
        case BM_MULTIPLY: return b * s;
        case BM_COLORBURN: return float3(burn(b.r, s.r), burn(b.g, s.g), burn(b.b, s.b));
        case BM_LINEARBURN: return max(b + s - 1.0, 0.0);
        case BM_DARKERCOLOR: return (s.r + s.g + s.b) < (b.r + b.g + b.b) ? s : b;
        case BM_LIGHTEN: return max(b, s);
        case BM_SCREEN: return b + s - b * s;
        case BM_COLORDODGE: return float3(dodge(b.r, s.r), dodge(b.g, s.g), dodge(b.b, s.b));
        case BM_LINEARDODGE: return b + s;
        case BM_LIGHTERCOLOR: return (s.r + s.g + s.b) > (b.r + b.g + b.b) ? s : b;
        case BM_OVERLAY: return float3(hardLightC(s.r, b.r), hardLightC(s.g, b.g), hardLightC(s.b, b.b));
        case BM_SOFTLIGHT: return float3(softLightC(b.r, s.r), softLightC(b.g, s.g), softLightC(b.b, s.b));
        case BM_HARDLIGHT: return float3(hardLightC(b.r, s.r), hardLightC(b.g, s.g), hardLightC(b.b, s.b));
        case BM_VIVIDLIGHT: return float3(vividC(b.r, s.r), vividC(b.g, s.g), vividC(b.b, s.b));
        case BM_LINEARLIGHT: return clamp(b + 2.0 * s - 1.0, 0.0, 1.0);
        case BM_PINLIGHT: return float3(pinC(b.r, s.r), pinC(b.g, s.g), pinC(b.b, s.b));
        case BM_HARDMIX: return step(1.0, b + s);
        case BM_DIFFERENCE: return abs(b - s);
        case BM_EXCLUSION: return b + s - 2.0 * b * s;
        case BM_SUBTRACT: return max(b - s, 0.0);
        case BM_DIVIDE: return float3(divideC(b.r, s.r), divideC(b.g, s.g), divideC(b.b, s.b));
        case BM_HUE: return setLum(setSat(s, satW(b)), lumW(b));
        case BM_SATURATION: return setLum(setSat(b, satW(s)), lumW(b));
        case BM_COLOR: return setLum(s, lumW(b));
        case BM_LUMINOSITY: return setLum(b, lumW(s));
        default: return s;
        }
    }

    /// Composites premultiplied `src` over premultiplied `dst`.
    inline float4 compositePixel(float4 dst, float4 src, uint mode, bool atop, float2 pixel) {
        float as = src.a;
        if (mode == BM_DISSOLVE) {
            as = hash12(pixel) < as ? 1.0 : 0.0;
            src = as > 0.0 ? float4(src.rgb / max(src.a, 1.0e-5), 1.0) : float4(0.0);
        }
        if (as <= 0.0) return dst;
        float ab = dst.a;
        float3 Cs = src.rgb / as;
        float3 Cb = ab > 1.0e-5 ? dst.rgb / ab : float3(0.0);
        float3 B = (mode == BM_NORMAL || mode == BM_DISSOLVE || mode == BM_PASSTHROUGH) ? Cs : blendColor(Cb, Cs, mode);
        float3 mixed = as * ab * B;
        if (atop) {
            return float4(dst.rgb * (1.0 - as) + mixed, ab);
        }
        return float4(src.rgb * (1.0 - ab) + dst.rgb * (1.0 - as) + mixed, as + ab - as * ab);
    }

    struct CompositeParams {
        uint2 origin;
        uint blendMode;
        float opacity;
        uint hasMask;
        uint atop;            // clipped layer: source-atop
        uint strokeActive;    // preview the live stroke on this layer
        uint hasTransform;    // preview a move/transform of this layer
        uint transformSelectionOnly;
        uint hasSelection;
        float4 xform0;        // inverse affine (canvas → source pixel): x' = a·x + b·y + c
        float4 xform1;        //                                         y' = d·x + e·y + f
        float2 canvasSize;
        float2 pad;
    };

    inline float4 sampleLayer(texture2d<float, access::sample> src, texture2d<float, access::sample> selection,
                              sampler s, constant CompositeParams& P, float2 p, uint2 pix) {
        if (P.hasTransform == 0) return src.read(pix);
        float2 q = float2(dot(P.xform0.xy, p) + P.xform0.z, dot(P.xform1.xy, p) + P.xform1.z);
        float4 moved = src.sample(s, q / P.canvasSize, level(0));
        if (P.transformSelectionOnly == 0) return moved;
        // Only the selected pixels move: cut them out of the original, paste them at the new spot.
        float selHere = selection.sample(s, p / P.canvasSize, level(0)).r;
        float selThere = selection.sample(s, q / P.canvasSize, level(0)).r;
        float4 stay = src.read(pix) * (1.0 - selHere);
        float4 pasted = moved * selThere;
        return pasted + stay * (1.0 - pasted.a);
    }

    kernel void compositeLayer(texture2d<float, access::sample> src [[texture(0)]],
                               texture2d<float, access::read_write> dst [[texture(1)]],
                               texture2d<float, access::read> mask [[texture(2)]],
                               texture2d<float, access::read> stroke [[texture(3)]],
                               texture2d<float, access::sample> selection [[texture(4)]],
                               sampler s [[sampler(0)]],
                               constant CompositeParams& P [[buffer(0)]],
                               constant ApplyParams& A [[buffer(1)]],
                               uint2 gid [[thread_position_in_grid]]) {
        uint2 pix = P.origin + gid;
        if (outside(pix, dst)) return;
        float2 p = float2(pix) + 0.5;
        float4 c = sampleLayer(src, selection, s, P, p, pix);
        float m = P.hasMask != 0 ? saturate(mask.read(pix).r) : 1.0;
        if (P.strokeActive != 0) {
            float4 st = stroke.read(pix);
            if (st.a > 0.0) {
                float sel = A.hasSelection != 0 ? saturate(selection.read(pix).r) : 1.0;
                if (A.target == 1) m = strokeOntoMask(m, st, sel, A);
                else c = strokeOntoContent(c, st, sel, A);
            }
        }
        c *= P.opacity * m;
        dst.write(compositePixel(dst.read(pix), c, P.blendMode, P.atop != 0, float2(pix)), pix);
    }

    /// Final pass for exports and thumbnails: optional opaque background under the composite.
    struct FlattenParams { float4 background; uint hasBackground; uint pad0; uint pad1; uint pad2; };
    kernel void flatten(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant FlattenParams& P [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float4 c = src.read(gid);
        if (P.hasBackground != 0) c = c + P.background * (1.0 - c.a);
        dst.write(c, gid);
    }
    """
}

struct CompositeParams {
    var origin: SIMD2<UInt32> = .zero
    var blendMode: UInt32 = 0
    var opacity: Float = 1
    var hasMask: UInt32 = 0
    var atop: UInt32 = 0
    var strokeActive: UInt32 = 0
    var hasTransform: UInt32 = 0
    var transformSelectionOnly: UInt32 = 0
    var hasSelection: UInt32 = 0
    var xform0: SIMD4<Float> = SIMD4(1, 0, 0, 0)
    var xform1: SIMD4<Float> = SIMD4(0, 1, 0, 0)
    var canvasSize: SIMD2<Float> = .zero
    var pad: SIMD2<Float> = .zero
}

struct FlattenParams {
    var background: SIMD4<Float>
    var hasBackground: UInt32
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
    var pad2: UInt32 = 0
}
