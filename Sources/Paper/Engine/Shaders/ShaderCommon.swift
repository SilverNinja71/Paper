// Metal Shading Language shared by every Paper shader module.
//
// Colour convention: textures hold *premultiplied*, gamma-encoded Display P3 colour in half floats.
// Values may exceed 1.0 (HDR / extended range). Only the final on-screen pass converts to linear light.

enum ShaderCommon {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    constant float3 kLumaP3 = float3(0.2289746, 0.6917385, 0.0792869);

    inline float luma(float3 c) { return dot(c, kLumaP3); }
    inline float4 unpremultiply(float4 c) { return c.a > 1.0e-5 ? float4(c.rgb / c.a, c.a) : float4(0.0); }
    inline float4 premultiply(float4 c) { return float4(c.rgb * c.a, c.a); }

    /// Cheap, stable per-pixel hash in [0, 1) (Dave Hoskins' hash12).
    inline float hash12(float2 p) {
        float3 p3 = fract(float3(p.xyx) * 0.1031);
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.x + p3.y) * p3.z);
    }

    inline float3 rgb2hsv(float3 c) {
        float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
        float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
        float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
        float d = q.x - min(q.w, q.y);
        float e = 1.0e-10;
        return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
    }

    inline float3 hsv2rgb(float3 c) {
        float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
        float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
        return c.z * mix(K.xxx, saturate(p - K.xxx), c.y);
    }

    inline float srgbToLinear(float x) {
        float a = abs(x);
        float y = a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4);
        return x < 0.0 ? -y : y;
    }
    inline float3 srgbToLinear(float3 c) { return float3(srgbToLinear(c.r), srgbToLinear(c.g), srgbToLinear(c.b)); }

    inline float linearToSrgb(float x) {
        float a = abs(x);
        float y = a <= 0.0031308 ? a * 12.92 : 1.055 * pow(a, 1.0 / 2.4) - 0.055;
        return x < 0.0 ? -y : y;
    }
    inline float3 linearToSrgb(float3 c) { return float3(linearToSrgb(c.r), linearToSrgb(c.g), linearToSrgb(c.b)); }

    inline float2 rotate2(float2 v, float a) {
        float s = sin(a), c = cos(a);
        return float2(c * v.x - s * v.y, s * v.x + c * v.y);
    }

    inline bool outside(uint2 pix, texture2d<float, access::read_write> t) { return pix.x >= t.get_width() || pix.y >= t.get_height(); }
    """
}

/// Small kernels for clearing, CPU transfers, mixing and thumbnails.
enum UtilityShader: ShaderModule {
    static let moduleName = "utility"
    static let source = """
    struct FillParams { uint2 origin; uint2 pad; float4 color; };
    struct TransferParams { uint2 origin; uint width; uint pad; };

    kernel void fillRegion(texture2d<float, access::write> dst [[texture(0)]],
                           constant FillParams& p [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
        uint2 pix = p.origin + gid;
        if (pix.x >= dst.get_width() || pix.y >= dst.get_height()) return;
        dst.write(p.color, pix);
    }

    kernel void exportFloat4(texture2d<float, access::read> src [[texture(0)]],
                             device float4* out [[buffer(0)]],
                             constant TransferParams& p [[buffer(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
        uint2 pix = p.origin + gid;
        float4 v = (pix.x < src.get_width() && pix.y < src.get_height()) ? src.read(pix) : float4(0.0);
        out[gid.y * p.width + gid.x] = v;
    }

    kernel void importFloat4(texture2d<float, access::write> dst [[texture(0)]],
                             device const float4* inp [[buffer(0)]],
                             constant TransferParams& p [[buffer(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
        uint2 pix = p.origin + gid;
        if (pix.x >= dst.get_width() || pix.y >= dst.get_height()) return;
        dst.write(inp[gid.y * p.width + gid.x], pix);
    }

    kernel void exportHalf4(texture2d<float, access::read> src [[texture(0)]],
                            device half4* out [[buffer(0)]],
                            constant TransferParams& p [[buffer(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
        out[gid.y * p.width + gid.x] = half4(src.read(gid));
    }

    kernel void importHalf4(texture2d<float, access::write> dst [[texture(0)]],
                            device const half4* inp [[buffer(0)]],
                            constant TransferParams& p [[buffer(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
        dst.write(float4(inp[gid.y * p.width + gid.x]), gid);
    }

    kernel void exportHalf1(texture2d<float, access::read> src [[texture(0)]],
                            device half* out [[buffer(0)]],
                            constant TransferParams& p [[buffer(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
        out[gid.y * p.width + gid.x] = half(src.read(gid).r);
    }

    kernel void importHalf1(texture2d<float, access::write> dst [[texture(0)]],
                            device const half* inp [[buffer(0)]],
                            constant TransferParams& p [[buffer(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
        dst.write(float4(float(inp[gid.y * p.width + gid.x])), gid);
    }

    /// acc = mix(acc, other, opacity × mask) over a region. Used by adjustment layers and pass-through groups.
    struct MixParams { uint2 origin; uint hasMask; float opacity; };
    kernel void mixRegion(texture2d<float, access::read_write> acc [[texture(0)]],
                          texture2d<float, access::read> other [[texture(1)]],
                          texture2d<float, access::read> mask [[texture(2)]],
                          constant MixParams& p [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
        uint2 pix = p.origin + gid;
        if (outside(pix, acc)) return;
        float m = p.hasMask != 0 ? saturate(mask.read(pix).r) : 1.0;
        acc.write(mix(acc.read(pix), other.read(pix), p.opacity * m), pix);
    }

    /// Box-filtered downscale for thumbnails: each output pixel averages a 4×4 grid of bilinear taps.
    kernel void downsample(texture2d<float, access::sample> src [[texture(0)]],
                           texture2d<float, access::write> dst [[texture(1)]],
                           sampler s [[sampler(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float2 size = float2(dst.get_width(), dst.get_height());
        float4 sum = 0.0;
        for (int j = 0; j < 4; j++) {
            for (int i = 0; i < 4; i++) {
                float2 uv = (float2(gid) + (float2(i, j) + 0.5) / 4.0) / size;
                sum += src.sample(s, uv, level(0));
            }
        }
        dst.write(sum / 16.0, gid);
    }
    """
}

/// Swift mirror of `MixParams`.
struct MixParams {
    var origin: SIMD2<UInt32>
    var hasMask: UInt32
    var opacity: Float
}
