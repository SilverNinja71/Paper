// Selection masks, flood-fill application, clearing, flipping and committing transforms.

enum SelectionShader: ShaderModule {
    static let moduleName = "selection"
    static let source = """
    struct RegionParams { uint2 origin; uint width; uint pad; };

    /// 8-bit coverage from the CPU (lasso rasteriser, flood fill) → r16Float mask.
    kernel void importGray8(texture2d<float, access::write> dst [[texture(0)]],
                            device const uchar* inp [[buffer(0)]],
                            constant RegionParams& p [[buffer(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
        uint2 pix = p.origin + gid;
        if (pix.x >= dst.get_width() || pix.y >= dst.get_height()) return;
        dst.write(float4(float(inp[gid.y * p.width + gid.x]) / 255.0), pix);
    }

    /// dst = combine(dst, src): 0 replace, 1 add (max), 2 subtract, 3 intersect (min).
    kernel void combineMasks(texture2d<float, access::read_write> dst [[texture(0)]],
                             texture2d<float, access::read> src [[texture(1)]],
                             constant uint& mode [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (outside(gid, dst)) return;
        float a = dst.read(gid).r, b = src.read(gid).r;
        float r = mode == 0 ? b : mode == 1 ? max(a, b) : mode == 2 ? a * (1.0 - b) : min(a, b);
        dst.write(float4(r), gid);
    }

    kernel void invertMask(texture2d<float, access::read_write> m [[texture(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
        if (outside(gid, m)) return;
        m.write(float4(1.0 - m.read(gid).r), gid);
    }

    struct FillMaskParams { float4 color; uint2 origin; uint alphaLock; uint hasSelection; };

    /// Paints `color` (straight rgb, a = opacity) over the layer where `coverage` says, within the selection.
    kernel void fillWithMask(texture2d<float, access::read_write> layer [[texture(0)]],
                             texture2d<float, access::read> coverage [[texture(1)]],
                             texture2d<float, access::read> selection [[texture(2)]],
                             constant FillMaskParams& p [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
        uint2 pix = p.origin + gid;
        if (outside(pix, layer)) return;
        float a = saturate(coverage.read(pix).r) * p.color.a;
        if (p.hasSelection != 0) a *= saturate(selection.read(pix).r);
        if (a <= 0.0) return;
        float4 cur = layer.read(pix);
        if (p.alphaLock != 0) {
            layer.write(float4(mix(cur.rgb, p.color.rgb * cur.a, a), cur.a), pix);
        } else {
            layer.write(float4(p.color.rgb * a, a) + cur * (1.0 - a), pix);
        }
    }

    struct ClearParams { uint2 origin; uint hasSelection; uint isMask; float maskValue; uint pad0; uint pad1; uint pad2; };

    /// Deletes pixels inside the selection (or everything without one). Masks are set to `maskValue`.
    kernel void clearSelected(texture2d<float, access::read_write> layer [[texture(0)]],
                              texture2d<float, access::read> selection [[texture(1)]],
                              constant ClearParams& p [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
        uint2 pix = p.origin + gid;
        if (outside(pix, layer)) return;
        float s = p.hasSelection != 0 ? saturate(selection.read(pix).r) : 1.0;
        float4 cur = layer.read(pix);
        if (p.isMask != 0) layer.write(float4(mix(cur.r, p.maskValue, s)), pix);
        else layer.write(cur * (1.0 - s), pix);
    }

    struct TransformParams {
        float4 xform0;   // inverse affine rows (canvas → source)
        float4 xform1;
        float2 canvasSize;
        uint selectionOnly;
        uint pad;
    };

    /// Bakes a move/scale/rotate (bilinear resampling) into a new texture.
    kernel void transformLayer(texture2d<float, access::sample> src [[texture(0)]],
                               texture2d<float, access::write> dst [[texture(1)]],
                               texture2d<float, access::sample> selection [[texture(2)]],
                               sampler s [[sampler(0)]],
                               constant TransformParams& P [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 p = float2(gid) + 0.5;
        float2 q = float2(dot(P.xform0.xy, p) + P.xform0.z, dot(P.xform1.xy, p) + P.xform1.z);
        float4 moved = src.sample(s, q / P.canvasSize, level(0));
        if (P.selectionOnly == 0) { dst.write(moved, gid); return; }
        float selHere = selection.sample(s, p / P.canvasSize, level(0)).r;
        float selThere = selection.sample(s, q / P.canvasSize, level(0)).r;
        float4 stay = src.read(gid) * (1.0 - selHere);
        float4 pasted = moved * selThere;
        dst.write(pasted + stay * (1.0 - pasted.a), gid);
    }
    """
}

struct RegionParams {
    var origin: SIMD2<UInt32>
    var width: UInt32
    var pad: UInt32 = 0
}

struct FillMaskParams {
    var color: SIMD4<Float>
    var origin: SIMD2<UInt32>
    var alphaLock: UInt32
    var hasSelection: UInt32
}

struct ClearParams {
    var origin: SIMD2<UInt32>
    var hasSelection: UInt32
    var isMask: UInt32
    var maskValue: Float
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
    var pad2: UInt32 = 0
}

struct TransformParams {
    var xform0: SIMD4<Float>
    var xform1: SIMD4<Float>
    var canvasSize: SIMD2<Float>
    var selectionOnly: UInt32
    var pad: UInt32 = 0
}
