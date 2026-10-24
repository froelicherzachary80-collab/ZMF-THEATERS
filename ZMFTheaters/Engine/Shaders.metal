#include <metal_stdlib>
using namespace metal;

// ZMF Cinema Engine — forward renderer.
// Physically based shading (Lambert diffuse + GGX specular with Schlick
// Fresnel), windowed inverse-square point lights, a screen-sized area light
// whose colour is the live average of the movie frame, exponential fog and
// ACES filmic tone mapping. The drawable is sRGB so all maths is linear.

struct VertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float2 uv       [[attribute(2)]];
    float4 color    [[attribute(3)]];
};

struct FrameUniforms {
    float4x4 viewProj;
    float4 cameraPos;     // xyz, w = time
    float4 ambient;       // rgb
    float4 fog;           // rgb, w = density
    float4 screenCenter;  // xyz, w = 1 when the active screen emits light
    float4 screenNormal;  // xyz, w = intensity
    float4 screenRight;   // xyz, w = half width
    float4 screenUp;      // xyz, w = half height
    float4 lightInfo;     // x = light count, y = exposure
};
// Lights arrive in buffer(4) as pairs: [position.xyz, range], [color.rgb, intensity].

struct DrawUniforms {
    float4x4 model;
    float4 baseColor;
    float4 emissive;      // w = emissive strength
    float4 params;        // x roughness, y metallic, z mode, w textured
};

struct VOut {
    float4 position [[position]];
    float3 worldPos;
    float3 normal;
    float2 uv;
    float4 color;
};

vertex VOut cinema_vertex(VertexIn in [[stage_in]],
                          constant FrameUniforms &f [[buffer(1)]],
                          constant DrawUniforms &d [[buffer(2)]]) {
    VOut o;
    float4 wp = d.model * float4(in.position, 1.0);
    o.position = f.viewProj * wp;
    o.worldPos = wp.xyz;
    o.normal = (d.model * float4(in.normal, 0.0)).xyz;
    o.uv = in.uv;
    o.color = in.color;
    return o;
}

static float3 aces(float3 x) {
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
}

static float ggx(float NoH, float rough) {
    float a = rough * rough;
    float a2 = a * a;
    float k = NoH * NoH * (a2 - 1.0) + 1.0;
    return a2 / (M_PI_F * k * k + 1e-4);
}

static float3 applyFog(float3 c, float3 worldPos, constant FrameUniforms &f) {
    float dist = length(f.cameraPos.xyz - worldPos);
    float k = 1.0 - exp(-f.fog.w * dist);
    return mix(c, f.fog.rgb, k);
}

fragment float4 cinema_fragment(VOut in [[stage_in]],
                                constant FrameUniforms &f [[buffer(1)]],
                                constant DrawUniforms &d [[buffer(2)]],
                                constant float4 *screenAvg [[buffer(3)]],
                                constant float4 *lights [[buffer(4)]],
                                texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge, max_anisotropy(4));
    float4 base = in.color * d.baseColor;
    int mode = int(d.params.z + 0.5);
    float exposure = f.lightInfo.y;

    // Movie screen: the decoded frame is shown unlit and letterboxed or
    // pillarboxed to its true aspect ratio (emissive.x = content aspect,
    // emissive.y = screen aspect).
    if (mode == 2) {
        float2 uv = in.uv;
        float contentAspect = d.emissive.x;
        float screenAspect = d.emissive.y;
        if (contentAspect > 0.01) {
            if (contentAspect > screenAspect) {
                uv.y = (uv.y - 0.5) * (contentAspect / screenAspect) + 0.5;
            } else {
                uv.x = (uv.x - 0.5) * (screenAspect / contentAspect) + 0.5;
            }
        }
        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
            return float4(0.0, 0.0, 0.0, 1.0);
        }
        float3 c = tex.sample(s, uv).rgb * d.emissive.w * 1.6;
        return float4(aces(c), 1.0);
    }
    if (d.params.w > 0.5) {
        base *= tex.sample(s, in.uv);
    }
    // Emissive surfaces (lamps, neon, light boxes, signage).
    if (mode == 3 || mode == 6) {
        float3 c = base.rgb * d.emissive.w;
        return float4(aces(applyFog(c, in.worldPos, f) * exposure), 1.0);
    }

    float3 N = normalize(in.normal);
    float3 V = normalize(f.cameraPos.xyz - in.worldPos);
    if (dot(N, V) < 0.0) N = -N; // geometry is two-sided
    float rough = clamp(d.params.x, 0.05, 1.0);
    float metallic = d.params.y;

    if (mode == 4) {
        // Woven carpet: subtle diamond pattern in world space.
        float2 p = in.worldPos.xz * 3.0;
        float pat = abs(fract(p.x + p.y) - 0.5) + abs(fract(p.x - p.y) - 0.5);
        base.rgb *= 0.8 + 0.35 * smoothstep(0.3, 0.7, pat);
    } else if (mode == 5) {
        // Polished marble tiles.
        float2 cell = floor(in.worldPos.xz / 1.5);
        float chk = fmod(abs(cell.x + cell.y), 2.0);
        base.rgb *= 0.85 + 0.3 * chk;
    }

    float3 F0 = mix(float3(0.04), base.rgb, metallic);
    float3 diffuse = base.rgb * (1.0 - metallic);
    float3 color = f.ambient.rgb * (diffuse + F0 * 0.5);

    int count = int(f.lightInfo.x);
    for (int i = 0; i < count; i++) {
        float3 Lv = lights[2 * i].xyz - in.worldPos;
        float dist = length(Lv);
        float range = lights[2 * i].w;
        if (dist > range) continue;
        float3 L = Lv / max(dist, 1e-3);
        float NoL = saturate(dot(N, L));
        if (NoL <= 0.0) continue;
        float r = dist / range;
        float window = saturate(1.0 - r * r * r * r);
        float att = window * window / (dist * dist + 1.0);
        float3 H = normalize(L + V);
        float NoH = saturate(dot(N, H));
        float VoH = saturate(dot(V, H));
        float3 F = F0 + (1.0 - F0) * pow(1.0 - VoH, 5.0);
        float3 spec = F * ggx(NoH, rough) * 0.25;
        float3 radiance = lights[2 * i + 1].rgb * lights[2 * i + 1].w * att;
        color += radiance * NoL * (diffuse / M_PI_F * 3.0 + spec);
    }

    // Light spilled from the movie screen onto seats, walls and the audience.
    if (f.screenCenter.w > 0.5) {
        float3 rel = in.worldPos - f.screenCenter.xyz;
        float u = clamp(dot(rel, f.screenRight.xyz), -f.screenRight.w, f.screenRight.w);
        float v = clamp(dot(rel, f.screenUp.xyz), -f.screenUp.w, f.screenUp.w);
        float3 P = f.screenCenter.xyz + f.screenRight.xyz * u + f.screenUp.xyz * v;
        float3 Lv = P - in.worldPos;
        float dist = length(Lv);
        float3 L = Lv / max(dist, 1e-3);
        float facing = saturate(dot(f.screenNormal.xyz, -L));
        float NoL = saturate(dot(N, L));
        float att = f.screenNormal.w * 30.0 / (dist * dist + 6.0);
        color += screenAvg[0].rgb * att * NoL * facing * (diffuse + F0);
    }

    color = applyFog(color, in.worldPos, f);
    return float4(aces(color * exposure), 1.0);
}

// Average colour of the current screen image (8x8 taps, one threadgroup),
// temporally smoothed so the room glow does not flicker on cuts.
kernel void screen_average(texture2d<float> tex [[texture(0)]],
                           device float4 *out [[buffer(0)]],
                           uint tid [[thread_index_in_threadgroup]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    threadgroup float4 shared[64];
    float2 uv = (float2(float(tid % 8), float(tid / 8)) + 0.5) / 8.0;
    shared[tid] = tex.sample(s, uv, level(0));
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint stride = 32; stride > 0; stride >>= 1) {
        if (tid < stride) shared[tid] += shared[tid + stride];
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (tid == 0) {
        float4 avg = shared[0] / 64.0;
        out[0] = mix(out[0], avg, 0.2);
    }
}
