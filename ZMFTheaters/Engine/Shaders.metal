#include <metal_stdlib>
using namespace metal;

// ZMF Cinema Engine — HDR forward renderer.
// Physically based shading (Lambert diffuse + GGX specular with Schlick
// Fresnel), windowed inverse-square point lights, a screen-sized area light
// whose colour is the live average of the movie frame, exponential fog, an
// additive dusty projector beam, then a post chain: bloom (threshold +
// separable Gaussian at quarter resolution), ACES filmic tone mapping,
// vignette and film grain. All scene maths is linear HDR (rgba16Float).

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
        return float4(c, 1.0);
    }
    if (d.params.w > 0.5) {
        base *= tex.sample(s, in.uv);
    }
    // Emissive surfaces (lamps, neon, light boxes, signage).
    if (mode == 3 || mode == 6) {
        float3 c = base.rgb * d.emissive.w;
        return float4(applyFog(c, in.worldPos, f) * exposure, 1.0);
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
    return float4(color * exposure, 1.0);
}

static float hash3(float3 p) {
    return fract(sin(dot(p, float3(12.9898, 78.233, 37.719))) * 43758.5453);
}

// Projector beam: faint haze tinted by the current picture plus drifting dust
// motes that sparkle in the light. Blended additively, no depth writes.
fragment float4 beam_fragment(VOut in [[stage_in]],
                              constant FrameUniforms &f [[buffer(1)]],
                              constant DrawUniforms &d [[buffer(2)]],
                              constant float4 *screenAvg [[buffer(3)]]) {
    float t = in.uv.x;                 // 0 at the lens, 1 at the screen
    float time = f.cameraPos.w;
    float3 p = in.worldPos * 34.0 + float3(time * 0.35, time * 0.17, time * 0.27);
    float3 cell = fract(p) - 0.5;
    float speck = smoothstep(0.22, 0.0, length(cell));          // round, sub-cell motes
    float dust = step(0.996, hash3(floor(p))) * speck;
    float twinkle = 0.6 + 0.4 * sin(time * 2.0 + hash3(floor(p) + 7.0) * 30.0);
    float haze = 0.03 * (1.0 - 0.65 * t);
    float3 tint = screenAvg[0].rgb + 0.03;
    float camFade = saturate(length(f.cameraPos.xyz - in.worldPos) / 1.8);
    float3 col = tint * (haze + dust * twinkle * 0.9) * d.emissive.w * camFade;
    return float4(col, 1.0);
}

// MARK: Post-processing

struct PostOut {
    float4 position [[position]];
    float2 uv;
};

vertex PostOut post_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    PostOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

// params: x = threshold, zw = source texel size
fragment float4 bloom_prefilter(PostOut in [[stage_in]],
                                texture2d<float> src [[texture(0)]],
                                constant float4 &params [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 o = params.zw;
    float3 c = src.sample(s, in.uv + float2(-o.x, -o.y)).rgb
             + src.sample(s, in.uv + float2( o.x, -o.y)).rgb
             + src.sample(s, in.uv + float2(-o.x,  o.y)).rgb
             + src.sample(s, in.uv + float2( o.x,  o.y)).rgb;
    c *= 0.25;
    float lum = max(c.r, max(c.g, c.b));
    float k = smoothstep(params.x, params.x + 0.8, lum);
    return float4(min(c * k, float3(16.0)), 1.0);
}

// params: xy = step (direction * texel)
fragment float4 bloom_blur(PostOut in [[stage_in]],
                           texture2d<float> src [[texture(0)]],
                           constant float4 &params [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    const float w[5] = { 0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216 };
    float3 c = src.sample(s, in.uv).rgb * w[0];
    for (int i = 1; i < 5; i++) {
        float2 off = params.xy * float(i) * 1.5;
        c += src.sample(s, in.uv + off).rgb * w[i];
        c += src.sample(s, in.uv - off).rgb * w[i];
    }
    return float4(c, 1.0);
}

// params: x = bloom strength, y = grain amount, z = time, w = vignette
static float fxHash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }

// One layer of water droplets on the viewer's "lens". Returns the refraction
// offset in xy and the droplet coverage in z.
static float3 dropLayer(float2 uv, float aspect, float scale, float t, float amount) {
    float2 p = float2(uv.x * aspect, uv.y) * scale;
    float2 id = floor(p);
    float2 f = fract(p) - 0.5;
    float h1 = fxHash(id), h2 = fxHash(id + 17.3), h3 = fxHash(id + 41.9), h4 = fxHash(id + 73.1);
    if (h4 > amount) return float3(0);
    float life = fract(t * (0.12 + h3 * 0.18) + h1);
    float fade = smoothstep(0.0, 0.04, life) * smoothstep(1.0, 0.55, life);
    float2 pos = float2(h1 - 0.5, h2 - 0.5) * 0.55 + float2(0, life * 0.22 * h3);   // slow drip
    float r = 0.1 + h2 * 0.16;
    float2 d = (f - pos) * float2(1.0, 1.15);
    float m = smoothstep(r, r * 0.55, length(d)) * fade;
    // Drip trail above the bead.
    float trail = smoothstep(0.03, 0.0, abs(f.x - pos.x)) * smoothstep(pos.y - 0.02, pos.y - 0.35, f.y) * smoothstep(-0.5, pos.y, f.y) * fade * 0.35 * step(0.6, h3);
    return float3(d * m * 2.2, saturate(m + trail));
}

fragment float4 composite(PostOut in [[stage_in]],
                          texture2d<float> hdr [[texture(0)]],
                          texture2d<float> bloom [[texture(1)]],
                          constant float4 &params [[buffer(0)]],
                          constant float4 &fx [[buffer(1)]],
                          constant float4 &fx2 [[buffer(2)]],
                          constant float4 &fx3 [[buffer(3)]],
                          constant float4 &fx4 [[buffer(4)]]) {
    // fx = (water, wind, flash, mist); fx2 = (aspect, time, shakeX, shakeY)
    // fx3 = (shockwave, embers, smoke, debris); fx4 = (hit, -, -, -)
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = in.uv + fx2.zw;
    // Explosion shockwave: a refracting ring expanding from the centre.
    if (fx3.x > 0.01) {
        float2 p = (uv - 0.5) * float2(fx2.x, 1.0);
        float d = length(p);
        float r = (1.0 - fx3.x) * 1.1;
        float ring = exp(-(d - r) * (d - r) / 0.0025);
        uv -= normalize(p + 1e-5) / float2(fx2.x, 1.0) * ring * 0.025 * fx3.x;
    }
    float3 drops = float3(0);
    if (fx.x > 0.01) {
        drops += dropLayer(uv, fx2.x, 7.0, fx2.y, fx.x);
        drops += dropLayer(uv + 0.37, fx2.x, 13.0, fx2.y * 1.3, fx.x * 0.85) * float3(0.6, 0.6, 1);
        drops.z = saturate(drops.z);
    }
    float2 suv = uv - drops.xy * 0.06;
    float3 c = hdr.sample(s, suv).rgb + bloom.sample(s, suv).rgb * params.x;
    // Wet glass: droplets refract, darken at the rim and catch a highlight.
    c = mix(c, c * 0.85 + bloom.sample(s, suv).rgb * 0.35, drops.z * 0.6);
    c += drops.z * smoothstep(0.0, 0.06, -drops.y) * 0.08;
    // Fine mist haze softens and lifts the image.
    float mist = saturate(fx.w * 0.6 + fx.x * 0.25);
    c = mix(c, bloom.sample(s, uv).rgb * 0.8 + float3(0.06, 0.07, 0.08), mist * 0.3);
    // Wind: thin streaks rushing past the edges of the view.
    if (fx.y > 0.01) {
        float row = floor(uv.y * 90.0);
        float hr = fxHash(float2(row, 3.1));
        float streak = smoothstep(0.985, 1.0, fract(uv.x * (0.6 + hr) - fx2.y * (1.4 + hr * 2.6) + hr));
        float edge = smoothstep(0.15, 0.5, abs(uv.x - 0.5) + abs(uv.y - 0.5) * 0.6);
        c += streak * edge * fx.y * 0.22 * step(0.55, hr);
    }
    // Smoke haze rolling up from the bottom after a blast.
    if (fx3.z > 0.01) {
        float n = fxHash(floor(uv * float2(24.0, 14.0) + float2(fx2.y * 0.6, fx2.y * -0.3)));
        float body = smoothstep(0.15, 1.0, uv.y) * (0.75 + 0.25 * n);
        c = mix(c, float3(0.16, 0.15, 0.14) + c * 0.2, saturate(fx3.z) * 0.4 * body);
    }
    // Embers drifting up through the view.
    if (fx3.y > 0.01) {
        float2 g = float2(uv.x * fx2.x, uv.y + fx2.y * 0.18) * 18.0;
        float2 id = floor(g), f = fract(g) - 0.5;
        float h = fxHash(id + 9.1);
        float2 off = float2(fxHash(id + 2.3) - 0.5, fxHash(id + 5.7) - 0.5) * 0.6 + float2(sin(fx2.y * 2.0 + h * 30.0) * 0.12, 0);
        float spark = smoothstep(0.09, 0.0, length(f - off)) * step(1.0 - fx3.y * 0.5, h);
        c += spark * float3(1.0, 0.45, 0.12) * 2.2 * (0.6 + 0.4 * sin(fx2.y * 9.0 + h * 40.0));
    }
    // Debris: dark fragments and hot sparks flung outward from the centre.
    if (fx3.w > 0.01) {
        float2 p = (uv - 0.5) * float2(fx2.x, 1.0);
        float ang = atan2(p.y, p.x);
        float sector = floor(ang * 9.0);
        float hs = fxHash(float2(sector, 4.0));
        float travel = fract(fx2.y * (1.2 + hs * 1.5) + hs);
        float rad = length(p);
        float chunk = smoothstep(0.03, 0.0, abs(rad - travel * 0.9)) * smoothstep(0.08, 0.0, abs(fract(ang * 9.0) - 0.5) - 0.38);
        float hot = step(0.7, hs);
        c = mix(c, mix(float3(0.05, 0.04, 0.03), float3(1.4, 0.7, 0.25), hot), chunk * saturate(fx3.w) * step(0.35, hs));
    }
    // Sharp hit: the view tightens for an instant.
    if (fx4.x > 0.01) {
        float2 dvig = in.uv - 0.5;
        c *= 1.0 - fx4.x * 0.4 * smoothstep(0.25, 0.75, length(dvig * float2(1.0, 0.8)));
    }
    c += fx.z * float3(1.0, 0.96, 0.9);
    c = aces(c);
    float2 d = in.uv - 0.5;
    c *= mix(1.0, smoothstep(0.95, 0.3, length(d * float2(1.0, 0.8))), params.w);
    float n = fract(sin(dot(in.uv * 1000.0 + params.z, float2(12.9898, 78.233))) * 43758.5453);
    c += (n - 0.5) * params.y;
    return float4(saturate(c), 1.0);
}

// 32×18 luminance grid of the film frame for real-time 4DX camera-motion
// tracking (2×2 taps per cell to limit aliasing).
kernel void motion_grid(texture2d<float> tex [[texture(0)]],
                        device float *out [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= 32 || gid.y >= 18) return;
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float l = 0.0;
    for (int j = 0; j < 2; j++) {
        for (int i = 0; i < 2; i++) {
            float2 uv = (float2(gid) + (float2(i, j) + 0.5) / 2.0) / float2(32.0, 18.0);
            l += dot(tex.sample(s, uv, level(0)).rgb, float3(0.2126, 0.7152, 0.0722));
        }
    }
    out[gid.y * 32 + gid.x] = l * 0.25;
}

// Average colour of the current screen image (8x8 taps, one threadgroup),
// temporally smoothed so the room glow does not flicker on cuts.
kernel void screen_average(texture2d<float> tex [[texture(0)]],
                           device float4 *out [[buffer(0)]],
                           uint tid [[thread_index_in_threadgroup]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    threadgroup float4 shared[64];
    float2 uv = (float2(float(tid % 8), float(tid / 8)) + 0.5) / 8.0;
    float4 tap = tex.sample(s, uv, level(0));
    shared[tid] = tap;
    out[1 + tid] = tap;                 // 8x8 grid read back by the 4DX engine
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

// ZMF DepthCinema AI — stereo synthesis + red/cyan anaglyph.
// Depth-image-based rendering: each eye samples the 2D frame displaced
// horizontally by a disparity proportional to (depth − convergence). Depth is
// dilated horizontally (max of neighbours) so foreground edges keep their
// shape instead of tearing (edge-aware artifact reduction). The left eye feeds
// the red channel, the right eye green+blue. `ghost` blends the red channel
// toward an optimised (green/blue-derived) red to reduce ghosting and retinal
// rivalry. params: x = max disparity (uv), y = convergence, z = ghost, w = depth gamma.
kernel void anaglyph_convert(texture2d<float> video [[texture(0)]],
                             texture2d<float> depth [[texture(1)]],
                             texture2d<float, access::write> outTex [[texture(2)]],
                             constant float4 &p [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
    uint w = outTex.get_width(), h = outTex.get_height();
    if (gid.x >= w || gid.y >= h) return;
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(w, h);
    float2 dx = float2(1.5 / float(depth.get_width()), 0.0);
    float d = depth.sample(s, uv).r;
    d = max(d, max(depth.sample(s, uv - dx).r, depth.sample(s, uv + dx).r));
    d = max(d, max(depth.sample(s, uv - dx * 2.0).r, depth.sample(s, uv + dx * 2.0).r) - 0.02);
    d = pow(saturate(d), p.w);
    float disparity = (d - p.y) * p.x;           // > 0: in front of the screen
    float3 L = video.sample(s, uv - float2(disparity, 0.0)).rgb;
    float3 R = video.sample(s, uv + float2(disparity, 0.0)).rgb;
    float optimisedRed = saturate(0.7 * L.g + 0.3 * L.b);
    float red = mix(L.r, optimisedRed, p.z);
    outTex.write(float4(red, R.g, R.b, 1.0), gid);
}
