// Metal shaders, compiled at runtime so the app builds without the offline Metal toolchain.
// Struct layouts must match the Swift types in RenderTypes.swift.
let shaderSource = #"""
#include <metal_stdlib>
using namespace metal;

struct Vertex { float4 position; float4 normal; };

struct Instance {
    float4 position;   // xyz world centre, w yaw
    float4 scale;      // xyz
    float4 color;      // rgb albedo, a opacity
    float4 params;     // x emissive, y style, z edge glow, w white-hot flash
};

struct Frame {
    float4x4 viewProj;
    float4x4 lightViewProj;
    float4 cameraPos;    // w time
    float4 lightDir;     // towards the light, w intensity
    float4 accent;       // level colour, w danger (stack height 0...1)
    float4 viewport;     // xy pixels, z flash
    float4 cameraRight;
    float4 cameraUp;
};

struct Particle { float4 position; float4 color; };

enum Style { StyleBlock = 0, StyleGhost = 1, StyleFrameV = 2, StyleFrameH = 3 };

constant float PI = 3.14159265;

// MARK: - Helpers

constexpr sampler linearClamp(coord::normalized, filter::linear, address::clamp_to_edge);

float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float noise2(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash12(i), hash12(i + float2(1, 0)), u.x),
               mix(hash12(i + float2(0, 1)), hash12(i + float2(1, 1)), u.x), u.y);
}

float fbm(float2 p, int octaves) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < octaves; i++) { v += a * noise2(p); p = p * 2.03 + 17.1; a *= 0.5; }
    return v;
}

// Studio-like environment for reflections: dark room, soft key box above, rim strip, level-tinted floor bounce.
float3 environment(float3 dir, float3 accent) {
    float3 sky = mix(float3(0.010, 0.012, 0.022), float3(0.05, 0.06, 0.10), saturate(dir.y * 0.5 + 0.5));
    float softbox = smoothstep(0.80, 0.97, dot(dir, normalize(float3(-0.35, 0.85, 0.40))));
    float strip = smoothstep(0.06, 0.0, abs(dir.x - 0.75)) * smoothstep(-0.3, 0.3, dir.y) * step(0.0, dir.z);
    float bounce = saturate(-dir.y) * 0.35;
    return sky + softbox * float3(1.6, 1.55, 1.5) + strip * float3(0.6, 0.7, 0.9) + accent * bounce;
}

float distributionGGX(float NdotH, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float d = NdotH * NdotH * (a2 - 1.0) + 1.0;
    return a2 / (PI * d * d);
}

float geometrySmith(float NdotV, float NdotL, float roughness) {
    float k = (roughness + 1.0) * (roughness + 1.0) / 8.0;
    return (NdotV / (NdotV * (1.0 - k) + k)) * (NdotL / (NdotL * (1.0 - k) + k));
}

// 4x4 bilinear PCF taps (an effective 5x5-texel tent). A fixed kernel keeps penumbrae noise-free and
// temporally stable; per-pixel rotated taps crawl whenever the scene or camera moves.
float shadowFactor(float3 world, constant Frame &f, depth2d<float> shadowMap) {
    constexpr sampler cmp(coord::normalized, filter::linear, address::clamp_to_edge, compare_func::less_equal);
    float4 lp = f.lightViewProj * float4(world, 1.0);
    float3 ndc = lp.xyz / lp.w;
    float2 uv = ndc.xy * float2(0.5, -0.5) + 0.5;
    if (any(uv < 0.0) || any(uv > 1.0) || ndc.z > 1.0) return 1.0;
    float texel = 1.0 / float(shadowMap.get_width());
    float sum = 0.0;
    for (int y = 0; y < 4; y++) {
        for (int x = 0; x < 4; x++) {
            sum += shadowMap.sample_compare(cmp, uv + (float2(x, y) - 1.5) * texel, ndc.z - 0.0008);
        }
    }
    return sum / 16.0;
}

/// Specular anti-aliasing (Kaplanyan & Hoffman / Tokuyoshi): widen the GGX lobe by the screen-space normal
/// variance so highlights on thin bevels cannot sparkle from pixel to pixel as blocks move.
float specularAA(float roughness, float3 N) {
    float3 du = dfdx(N), dv = dfdy(N);
    float variance = 0.25 * (dot(du, du) + dot(dv, dv));
    float a = roughness * roughness;
    float a2 = saturate(a * a + min(2.0 * variance, 0.18));
    return sqrt(sqrt(a2));
}

float3 shadeSurface(float3 albedo, float roughness, float metallic, float3 N, float3 V, float3 world,
                    float shadow, constant Frame &f) {
    float3 L = f.lightDir.xyz;
    float3 H = normalize(L + V);
    float NdotL = saturate(dot(N, L));
    float NdotV = max(dot(N, V), 1e-3);
    float NdotH = saturate(dot(N, H));
    float3 F0 = mix(float3(0.04), albedo, metallic);
    float3 F = F0 + (1.0 - F0) * pow(1.0 - saturate(dot(H, V)), 5.0);
    float3 specular = distributionGGX(NdotH, roughness) * geometrySmith(NdotV, NdotL, roughness) * F
                      / max(4.0 * NdotV * NdotL, 1e-3);
    float3 kd = (1.0 - F) * (1.0 - metallic);
    float3 lightColor = float3(1.0, 0.96, 0.9) * f.lightDir.w;
    float3 direct = (kd * albedo / PI + specular) * lightColor * NdotL * shadow;

    // Fill light from the opposite side so shadowed faces keep their shape.
    float3 fillDir = normalize(float3(0.7, 0.2, 0.6));
    float3 fill = albedo * saturate(dot(N, fillDir)) * float3(0.25, 0.3, 0.45) * 0.35;

    float3 Fv = F0 + (1.0 - F0) * pow(1.0 - NdotV, 5.0);
    float3 R = reflect(-V, N);
    float3 reflection = environment(R, f.accent.rgb) * Fv * mix(0.8, 0.1, roughness);
    float hemi = N.y * 0.5 + 0.5;
    float3 ambient = albedo * mix(float3(0.03, 0.028, 0.04) + f.accent.rgb * 0.03, float3(0.10, 0.11, 0.15), hemi) * (1.0 - metallic * 0.8);
    return direct + fill + reflection * (0.35 + 0.65 * shadow) + ambient;
}

// MARK: - Shadow pass

struct ShadowOut { float4 position [[position]]; };

float3 instanceTransform(float3 p, Instance inst) {
    p *= inst.scale.xyz;
    float c = cos(inst.position.w), s = sin(inst.position.w);
    return float3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z) + inst.position.xyz;
}

vertex ShadowOut shadowVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                              const device Vertex *verts [[buffer(0)]],
                              const device Instance *instances [[buffer(1)]],
                              constant Frame &f [[buffer(2)]]) {
    float3 world = instanceTransform(verts[vid].position.xyz, instances[iid]);
    return { f.lightViewProj * float4(world, 1.0) };
}

// MARK: - Blocks

struct BlockOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float3 local;
    float3 localNormal;
    float4 color [[flat]];
    float4 params [[flat]];
};

vertex BlockOut blockVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                            const device Vertex *verts [[buffer(0)]],
                            const device Instance *instances [[buffer(1)]],
                            constant Frame &f [[buffer(2)]]) {
    Vertex v = verts[vid];
    Instance inst = instances[iid];
    float3 world = instanceTransform(v.position.xyz, inst);
    float3 n = v.normal.xyz / inst.scale.xyz;
    float c = cos(inst.position.w), s = sin(inst.position.w);
    n = float3(c * n.x + s * n.z, n.y, -s * n.x + c * n.z);
    BlockOut out;
    out.position = f.viewProj * float4(world, 1.0);
    out.world = world;
    out.normal = normalize(n);
    out.local = v.position.xyz;
    out.localNormal = v.normal.xyz;
    out.color = inst.color;
    out.params = inst.params;
    return out;
}

/// 0 in the middle of a face, 1 at its rim.
float faceEdge(float3 local) {
    float3 a = abs(local) / 0.47;
    float mid = max(min(a.x, a.y), min(max(a.x, a.y), a.z));
    return smoothstep(0.62, 0.92, mid);
}

fragment float4 blockFragment(BlockOut in [[stage_in]],
                              constant Frame &f [[buffer(0)]],
                              depth2d<float> shadowMap [[texture(0)]]) {
    float3 N = normalize(in.normal);
    float3 V = normalize(f.cameraPos.xyz - in.world);
    int style = int(in.params.y + 0.5);
    float time = f.cameraPos.w;

    if (style == StyleGhost) {
        float edge = faceEdge(in.local);
        float fres = pow(1.0 - saturate(dot(N, V)), 2.0);
        float pulse = 0.92 + 0.08 * sin(time * 2.5);
        float3 glow = in.color.rgb * (0.25 + edge * 2.4 + fres * 0.6) * pulse;
        float alpha = saturate(0.10 + edge * 0.7 + fres * 0.2) * in.color.a;
        return float4(glow * alpha, alpha);
    }

    float shadow = shadowFactor(in.world + N * 0.04, f, shadowMap);

    if (style == StyleFrameV || style == StyleFrameH) {
        float3 color = shadeSurface(float3(0.035, 0.04, 0.055), specularAA(0.22, N), 0.85, N, V, in.world, shadow, f);
        float across = style == StyleFrameV ? in.local.x : in.local.y;
        float front = smoothstep(0.6, 0.9, in.localNormal.z);
        float stripe = (1.0 - smoothstep(0.05, 0.11, abs(across))) * front;
        float3 accent = f.accent.rgb * (1.0 + f.accent.w * (0.5 + 0.5 * sin(time * 3.5)));
        color += accent * stripe * 5.0;
        return float4(color, 1.0);
    }

    float3 albedo = in.color.rgb;
    float edge = faceEdge(in.local);
    float3 color = shadeSurface(albedo, specularAA(0.26, N), 0.0, N, V, in.world, shadow, f);

    // Candy-glass inner glow: brighter towards grazing angles and along the inset rim.
    float fres = pow(1.0 - saturate(dot(N, V)), 3.0);
    float3 emissive = albedo * (in.params.x * (0.35 + 1.4 * edge) + in.params.z * edge + fres * 0.15);
    color += emissive;

    float flash = in.params.w;
    color = mix(color, float3(6.0, 6.2, 7.0) + albedo * 4.0, flash);
    return float4(color, in.color.a);
}

// MARK: - Environment (back panel and floor)

struct EnvOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
};

vertex EnvOut envVertex(uint vid [[vertex_id]], const device Vertex *verts [[buffer(0)]],
                        constant Frame &f [[buffer(2)]]) {
    EnvOut out;
    out.world = verts[vid].position.xyz;
    out.normal = verts[vid].normal.xyz;
    out.position = f.viewProj * float4(out.world, 1.0);
    return out;
}

/// Anti-aliased grid with lines on integer coordinates, `width` in cells (Ben Golus, "The Best Darn Grid Shader").
/// Lines never get thinner than a pixel (they fade instead) and converge to their average coverage once cells
/// shrink below a few pixels, so the grid cannot shimmer or form moiré at grazing angles.
float grid(float2 coord, float width) {
    float2 dd = fwidth(coord);
    float2 drawWidth = clamp(float2(width), dd, 0.5);
    float2 aa = dd * 1.5;
    float2 d = 1.0 - abs(fract(coord) * 2.0 - 1.0);
    float2 lines = smoothstep(drawWidth + aa, drawWidth - aa, d);
    lines *= saturate(width / drawWidth);
    lines = mix(lines, float2(width), saturate(dd * 2.0 - 1.0));
    return mix(lines.x, 1.0, lines.y);
}

fragment float4 envFragment(EnvOut in [[stage_in]],
                            constant Frame &f [[buffer(0)]],
                            constant int &kind [[buffer(1)]],
                            depth2d<float> shadowMap [[texture(0)]]) {
    float3 N = normalize(in.normal);
    float3 V = normalize(f.cameraPos.xyz - in.world);
    float shadow = shadowFactor(in.world + N * 0.02, f, shadowMap);
    float3 accent = f.accent.rgb;

    if (kind == 0) {
        // Back panel of the well: satin dark glass with a cell grid and a heat glow that rises with the stack.
        float3 color = shadeSurface(float3(0.022, 0.025, 0.04), 0.7, 0.0, N, V, in.world, shadow, f);
        float lines = grid(in.world.xy + 0.5, 0.024);
        float height = saturate((in.world.y + 10.0) / 20.0);
        float heat = exp(-height * 3.0) * 0.35 + f.accent.w * exp(-abs(height - 0.5) * 2.0) * 0.4;
        color += accent * (lines * 0.05 + heat * 0.18) * (0.4 + 0.6 * shadow);
        return float4(color, 1.0);
    }

    // Floor: glossy dark plane with a fading neon grid.
    float dist = length(in.world.xz * float2(0.8, 1.0));
    float fade = 1.0 - smoothstep(9.0, 26.0, dist);
    float3 color = shadeSurface(float3(0.012, 0.013, 0.02), 0.75, 0.0, N, V, in.world, shadow, f);
    color += accent * grid(in.world.xz, 0.04) * 0.5 * fade * (0.3 + 0.7 * shadow);
    color += accent * exp(-dist * 0.25) * 0.08;
    return float4(color * fade, fade);
}

// MARK: - Background

struct FullscreenOut { float4 position [[position]]; float2 uv; };

vertex FullscreenOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 uv = float2((vid << 1) & 2, vid & 2);
    FullscreenOut out;
    out.position = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    out.uv = uv;
    return out;
}

// Procedural deep-space backdrop. Everything lives in aspect-corrected screen space `p` (y spans one unit), so the
// composition is resolution independent; all motion is tens of seconds per noticeable change.

float2 hash22(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

/// erf via the tanh approximation (max error ~3e-4); used to box-filter star profiles over the pixel footprint.
/// The clamp matters: fast-math tanh overflows to NaN for large arguments, and erf(±3) is already ±0.99998.
float2 erfApprox(float2 x) {
    x = clamp(x, -3.0, 3.0);
    return tanh(x * (1.1283792 + 0.1009 * x * x));
}

/// Fraction of a unit-energy Gaussian (sigma in pixels) that lands in the pixel at offset `d` pixels from its centre.
/// Integrating over the pixel square instead of point-sampling keeps a star's brightness constant as it drifts
/// across pixel centres, so slow parallax never shimmers.
float pixelGaussian(float2 d, float sigma) {
    float k = 0.70710678 / sigma;
    float2 a = erfApprox((d + 0.5) * k) - erfApprox((d - 0.5) * k);
    return 0.25 * a.x * a.y;
}

/// Black-body-ish tint: warm orange → white → blue-white.
float3 starTint(float t) {
    return t < 0.35 ? mix(float3(1.0, 0.52, 0.26), float3(1.0, 0.93, 0.85), t / 0.35)
                    : mix(float3(1.0, 0.93, 0.85), float3(0.58, 0.72, 1.0), (t - 0.35) / 0.65);
}

struct StarLayer {
    float cells;       // cells per unit of screen height
    float presence;    // base probability that a cell holds a star
    float energy;      // faintest star energy (pixel-sum units at the 1600 px reference height)
    float maxEnergy;
    float drift;       // parallax drift, units per second
    float seed;
};

// Star tiers, as template parameters so each layer compiles to its own minimal, fully unrolled shader code.
constant int TierFaint = 0;   // faint texture: pixel-integrated core only
constant int TierGlow = 1;    // core + glow halo + scintillation
constant int TierLens = 2;    // + chromatic halo, diffraction spikes, anamorphic streak, colour scintillation

/// Smooth 1D value noise in [0, 1] (C1-continuous in time), one independent stream per seed.
float timeNoise(float t, float seed) {
    float i = floor(t), u = fract(t);
    u = u * u * (3.0 - 2.0 * u);
    return mix(hash12(float2(i, seed)), hash12(float2(i + 1.0, seed)), u);
}

/// Atmospheric scintillation: two octaves of smooth noise at incommensurate rates, so it reads as irregular,
/// organic twinkle rather than a periodic pulse or per-frame flicker. Mean 0.5.
float scintillation(float time, float seed) {
    return 0.65 * timeNoise(time * 1.1, seed) + 0.35 * timeNoise(time * 2.7, seed + 17.0);
}

/// Optical profile of one star at pixel offset `d`: pixel-integrated core, gaussian glow, and for the brightest a
/// chromatic halo, 4-point diffraction spikes and a faint anamorphic streak — the same lens language as the game's
/// bloom and neon.
template <int tier>
float3 starProfile(float2 d, float energy, float3 tint, float pxScale) {
    float sigma = max((0.5 + 0.2 * log2(1.0 + energy)) * pxScale, 0.6);
    float3 light = tint * energy * pxScale * pxScale * pixelGaussian(d, sigma);
    if (tier == TierFaint) return light;
    float2 a = abs(d) / pxScale;                  // offset in reference pixels
    float r2 = dot(a, a);
    light += tint * energy * 0.045 * exp(-r2 * (1.0 / (2.0 * 2.6 * 2.6)));          // soft glow around the core
    if (tier == TierGlow || energy < 1.5) return light;
    float r = sqrt(r2);
    light += tint * energy * 0.012 * exp(-r * float3(0.17, 0.2, 0.24));             // wide halo, warm outer fringe
    float lens = saturate((energy - 2.0) * 0.3);
    float len = 3.0 + 1.1 * energy;
    float spikes = exp(-a.x / len) * exp(-a.y * a.y * 1.6) + exp(-a.y / len) * exp(-a.x * a.x * 1.6);
    light += tint * spikes * lens * 0.25;
    float streak = exp(-a.x / (len * 3.0)) * exp(-a.y * a.y * 0.9);
    light += float3(0.55, 0.7, 1.0) * streak * saturate((energy - 6.0) * 0.25) * 0.025;
    return light;
}

/// Aspect-corrected screen position: y up, spanning one unit of screen height, origin at the centre.
float2 screenPosition(float2 uv, constant Frame &f) {
    return (uv - 0.5) * float2(f.viewport.x / f.viewport.y, -1.0);
}

constant float2 bandNormal = float2(-0.3871, 0.9220);   // normal of the galactic band, which runs lower-left to upper-right
constant float bandOffset = 0.17;   // passes above the well: left edge mid-height to the top-right corner
constant float bandWidth = 0.17;

/// One star layer. Stars are denser along the galactic band; `pxScale` = viewport height / 1600.
/// Glowing layers search the 2x2 cells nearest to the pixel, which covers every star within 0.65 cells, more than any
/// halo or spike reaches, so nothing is clipped at cell borders. Each star is culled by its own energy-based reach
/// before any shading work.
template <int tier>
float3 stars(float2 p, StarLayer layer, float time, float pxScale, float pixelsPerUnit, float calm) {
    float2 drift = float2(layer.drift, layer.drift * 0.35) * time;
    float2 g = (p + drift) * layer.cells;
    float2 id = floor(g);
    float2 base = id + (tier == TierFaint ? float2(0.0) : floor(fract(g) - 0.5));
    constexpr int span = tier == TierFaint ? 1 : 2;
    float3 sum = 0.0;
    for (int y = 0; y < span; y++) {
        for (int x = 0; x < span; x++) {
            float2 cell = base + float2(x, y);
            // Cheapest test first: most cells are empty. The faint layer gets denser along the galactic band.
            float presence = layer.presence;
            if (tier == TierFaint) {
                float across = (dot((cell + 0.5) / layer.cells - drift, bandNormal) - bandOffset) / bandWidth;
                presence *= 1.0 + 2.5 * exp(-across * across);
            }
            float h = hash12(cell + layer.seed);
            if (h > presence) continue;
            float2 r = hash22(cell * 1.37 + layer.seed);
            float2 d = (g - cell - (0.15 + 0.7 * r)) / layer.cells * pixelsPerUnit;   // offset in pixels
            // Power-law brightness: many faint stars, few bright ones.
            float energy = min(layer.energy * pow(r.x * r.y + 0.002, -0.67), layer.maxEnergy);
            float reach = (tier == TierFaint ? 3.0 : (tier == TierGlow || energy < 1.5 ? 10.0 : 16.0 + 5.0 * energy))
                          * pxScale + 2.0;
            if (dot(d, d) > reach * reach) continue;
            float phase = h / presence;                  // uniform in [0, 1] given that the star exists
            float3 tint = starTint(fract(phase * 7.13));
            if (tier != TierFaint) {
                float seed = phase * 613.0;
                float depth = (tier == TierLens ? 0.4 : 0.3) * mix(0.35, 1.0, calm);   // max ±40%, calmer centre
                energy *= 1.0 + depth * (scintillation(time, seed) - 0.5) * 2.0;
                // Chromatic scintillation: brief, independent colour shifts, strongest on bright stars.
                float chroma = 0.35 * saturate((energy - 0.8) * 0.25) * calm;
                if (tier == TierLens && chroma > 0.0) {
                    float3 shift = float3(scintillation(time, seed + 5.0), scintillation(time, seed + 9.0),
                                          scintillation(time, seed + 13.0)) - 0.5;
                    tint *= 1.0 + chroma * shift * 2.0;
                }
            }
            sum += starProfile<tier>(d, energy, tint, pxScale);
        }
    }
    return sum;
}

/// Low-frequency part of the backdrop (sky gradient, domain-warped nebula, galactic band, dust), rendered at quarter
/// resolution because it is smooth and changes over tens of seconds. rgb: emission, a: star transmittance.
kernel void nebulaKernel(texture2d<float, access::write> dst [[texture(0)]],
                         constant Frame &f [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float2 p = screenPosition((float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height()), f);
    float slow = f.cameraPos.w * 0.0025;

    // Domain warping (Quilez): two warp fields feed the final density and also select the colour layers.
    float2 np = p * 1.6;
    float2 q = float2(fbm(np + float2(0.0, slow), 4), fbm(np + float2(5.2, 1.3) - slow, 4));
    float density = fbm(np + 2.2 * q + float2(slow * 0.6, 0.0), 5);
    float wisps = pow(1.0 - abs(fbm(np * 2.6 + q * 2.4 - slow, 4) * 2.0 - 1.0), 12.0);  // thin ridged filaments
    float dust = smoothstep(0.5, 0.78, fbm(np * 2.2 + q * 1.8 + 11.0, 4));

    float across = (dot(p, bandNormal) - bandOffset + (q.x - 0.5) * 0.14) / bandWidth;
    float band = exp(-across * across);
    float rift = band * smoothstep(0.45, 0.7, q.y + (density - 0.5) * 0.6);   // dark lane along the band's spine

    float3 violet = float3(0.34, 0.08, 0.62);
    float3 teal = float3(0.02, 0.34, 0.42);
    float3 accent = normalize(mix(f.accent.rgb, violet, 0.3) + 0.04);
    float3 hue = mix(violet, teal, smoothstep(0.38, 0.68, q.y));
    hue = mix(hue, accent, smoothstep(0.45, 0.75, q.x) * 0.65);

    hue = mix(float3(dot(hue, float3(0.2126, 0.7152, 0.0722))), hue, 0.65);   // muted, so the stars stay the hero
    float cloud = smoothstep(0.48, 0.9, density);
    float core = pow(smoothstep(0.62, 0.95, density), 2.5);
    float3 emission = mix(accent, float3(1.0, 0.45, 0.75), 0.4);   // hot, slightly magenta cores
    float3 nebula = hue * cloud * 0.03
                  + hue * wisps * smoothstep(0.4, 0.8, density) * 0.10
                  + emission * core * 0.12;
    // Galactic band: glow of unresolved stars, clumped by the nebula field.
    nebula += mix(float3(1.0, 0.86, 0.74), hue, 0.45) * pow(band, 1.5)
            * (0.015 + 0.035 * smoothstep(0.3, 0.8, density) + 0.03 * wisps);

    float occlusion = saturate(dust * 0.5 + rift * 0.5);
    float3 color = mix(float3(0.002, 0.0025, 0.006), float3(0.008, 0.008, 0.018), smoothstep(0.6, -0.6, p.y));
    color += nebula * (1.0 - occlusion);
    dst.write(float4(color, 1.0 - saturate(occlusion * 1.1)), gid);
}

fragment float4 backgroundFragment(FullscreenOut in [[stage_in]], constant Frame &f [[buffer(0)]],
                                   texture2d<float> nebula [[texture(1)]]) {
    float time = f.cameraPos.w;
    float2 p = screenPosition(in.uv, f);
    float pixelsPerUnit = f.viewport.y;
    float pxScale = f.viewport.y / 1600.0;
    float4 sky = nebula.sample(linearClamp, in.uv);

    // Three parallax layers: dense faint dust, a mid field, and a few bright stars with halos and spikes.
    // Keep the space behind the well and title calm: dimmer, less saturated and less twinkly in the centre.
    float calm = smoothstep(0.12, 0.62, length(p * float2(1.0, 0.45)));
    StarLayer far  = { 150.0, 0.15, 0.05, 0.25, 0.00015, 1.0 };
    StarLayer mid  = { 44.0, 0.26, 0.16, 1.6, 0.00030, 17.0 };
    StarLayer near = { 11.0, 0.32, 0.50, 10.0, 0.00055, 43.0 };
    float3 starLight = stars<TierFaint>(p, far, time, pxScale, pixelsPerUnit, calm)
                     + stars<TierGlow>(p, mid, time, pxScale, pixelsPerUnit, calm)
                     + stars<TierLens>(p, near, time, pxScale, pixelsPerUnit, calm);
    float3 color = sky.rgb + starLight * sky.a;

    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    color = mix(float3(luma), color, mix(0.45, 1.0, calm)) * mix(0.4, 1.0, calm);
    return float4(color, 1.0);
}

// MARK: - Particles

struct ParticleOut {
    float4 position [[position]];
    float2 corner;
    float4 color [[flat]];
};

vertex ParticleOut particleVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                  const device Particle *particles [[buffer(1)]],
                                  constant Frame &f [[buffer(2)]]) {
    const float2 corners[6] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(-1, 1), float2(1, -1), float2(1, 1) };
    Particle p = particles[iid];
    float2 c = corners[vid];
    // Sparks can project to less than a pixel, where they flicker as they cross pixel centres. Keep the sprite
    // at least minRadius pixels wide and dim it by the area ratio so its total energy is unchanged.
    constexpr float minRadius = 3.0;
    float4 center = f.viewProj * float4(p.position.xyz, 1.0);
    float4 edge = f.viewProj * float4(p.position.xyz + f.cameraUp.xyz * p.position.w, 1.0);
    float radius = length((edge.xy / edge.w - center.xy / center.w) * f.viewport.xy * 0.5);
    float grow = max(minRadius / max(radius, 1e-4), 1.0);
    float3 world = p.position.xyz + (f.cameraRight.xyz * c.x + f.cameraUp.xyz * c.y) * p.position.w * grow;
    ParticleOut out;
    out.position = f.viewProj * float4(world, 1.0);
    out.corner = c;
    out.color = float4(p.color.rgb, p.color.a / (grow * grow));
    return out;
}

fragment float4 particleFragment(ParticleOut in [[stage_in]]) {
    float d2 = dot(in.corner, in.corner);
    float core = exp(-d2 * 9.0);
    float halo = exp(-d2 * 2.5) * 0.35;
    return float4(in.color.rgb * (core + halo) * in.color.a, 0.0);
}

// MARK: - Bloom

float karis(float3 c) { return 1.0 / (1.0 + max(c.r, max(c.g, c.b))); }

/// 13-tap downsample (Jimenez, "Next Generation Post Processing in Call of Duty: Advanced Warfare").
/// With `antiFlicker`, each of the five 2x2 boxes is Karis-weighted by its brightness, which suppresses fireflies:
/// sub-pixel specular sparkles and sparks would otherwise flash the whole bloom halo on and off frame to frame.
float3 downsample13(texture2d<float> src, float2 uv, float2 texel, bool antiFlicker) {
    float3 a = src.sample(linearClamp, uv + texel * float2(-2, -2)).rgb;
    float3 b = src.sample(linearClamp, uv + texel * float2( 0, -2)).rgb;
    float3 c = src.sample(linearClamp, uv + texel * float2( 2, -2)).rgb;
    float3 d = src.sample(linearClamp, uv + texel * float2(-2,  0)).rgb;
    float3 e = src.sample(linearClamp, uv).rgb;
    float3 g = src.sample(linearClamp, uv + texel * float2( 2,  0)).rgb;
    float3 h = src.sample(linearClamp, uv + texel * float2(-2,  2)).rgb;
    float3 i = src.sample(linearClamp, uv + texel * float2( 0,  2)).rgb;
    float3 j = src.sample(linearClamp, uv + texel * float2( 2,  2)).rgb;
    float3 k = src.sample(linearClamp, uv + texel * float2(-1, -1)).rgb;
    float3 l = src.sample(linearClamp, uv + texel * float2( 1, -1)).rgb;
    float3 m = src.sample(linearClamp, uv + texel * float2(-1,  1)).rgb;
    float3 n = src.sample(linearClamp, uv + texel * float2( 1,  1)).rgb;
    float3 boxes[5] = { (k + l + m + n) * 0.25, (a + b + d + e) * 0.25, (b + c + e + g) * 0.25,
                        (d + e + h + i) * 0.25, (e + g + i + j) * 0.25 };
    float weights[5] = { 0.5, 0.125, 0.125, 0.125, 0.125 };
    float3 sum = 0.0;
    float total = 0.0;
    for (int box = 0; box < 5; box++) {
        float w = weights[box] * (antiFlicker ? karis(boxes[box]) : 1.0);
        sum += boxes[box] * w;
        total += w;
    }
    return sum / total;
}

kernel void bloomPrefilter(texture2d<float> src [[texture(0)]],
                           texture2d<float, access::write> dst [[texture(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    float3 c = downsample13(src, uv, 1.0 / float2(src.get_width(), src.get_height()), true);
    // Soft-knee threshold so only genuinely bright pixels bloom.
    float threshold = 0.9, knee = 0.5;
    float brightness = max(c.r, max(c.g, c.b));
    float soft = clamp(brightness - threshold + knee, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee + 1e-4);
    float contribution = max(soft, brightness - threshold) / max(brightness, 1e-4);
    dst.write(float4(c * contribution, 1.0), gid);
}

kernel void bloomDownsample(texture2d<float> src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    dst.write(float4(downsample13(src, uv, 1.0 / float2(src.get_width(), src.get_height()), false), 1.0), gid);
}

kernel void bloomUpsample(texture2d<float> low [[texture(0)]],
                          texture2d<float> base [[texture(1)]],
                          texture2d<float, access::write> dst [[texture(2)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    float2 t = 1.0 / float2(low.get_width(), low.get_height());
    float3 s = low.sample(linearClamp, uv).rgb * 4.0;
    s += (low.sample(linearClamp, uv + t * float2(-1, 0)).rgb + low.sample(linearClamp, uv + t * float2(1, 0)).rgb +
          low.sample(linearClamp, uv + t * float2(0, -1)).rgb + low.sample(linearClamp, uv + t * float2(0, 1)).rgb) * 2.0;
    s += low.sample(linearClamp, uv + t * float2(-1, -1)).rgb + low.sample(linearClamp, uv + t * float2(1, -1)).rgb +
         low.sample(linearClamp, uv + t * float2(-1, 1)).rgb + low.sample(linearClamp, uv + t * float2(1, 1)).rgb;
    dst.write(float4(base.read(gid).rgb + s / 16.0, 1.0), gid);
}

// MARK: - Composite

float3 acesFilm(float3 x) {
    return saturate((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14));
}

fragment float4 compositeFragment(FullscreenOut in [[stage_in]],
                                  constant Frame &f [[buffer(0)]],
                                  texture2d<float> hdr [[texture(0)]],
                                  texture2d<float> bloom [[texture(1)]]) {
    float2 uv = in.uv;
    float3 color = hdr.sample(linearClamp, uv).rgb;
    color += bloom.sample(linearClamp, uv).rgb * 0.085;
    color += f.accent.rgb * f.viewport.z * 0.05;
    color = acesFilm(color * 1.05);

    float aspect = f.viewport.x / f.viewport.y;
    float vignette = smoothstep(1.25, 0.35, length((uv - 0.5) * float2(aspect, 1.0)));
    color *= mix(0.55, 1.0, vignette);

    // Static ±0.5 LSB dither in the encoded (sRGB) domain hides 8-bit banding in the dark gradients. It is fixed
    // per pixel (interleaved gradient noise), so unlike film grain it never animates.
    float dither = fract(52.9829189 * fract(dot(in.position.xy, float2(0.06711056, 0.00583715)))) - 0.5;
    float3 encoded = select(1.055 * pow(color, 1.0 / 2.4) - 0.055, color * 12.92, color <= 0.0031308);
    encoded = saturate(encoded + dither / 255.0);
    color = select(pow((encoded + 0.055) / 1.055, 2.4), encoded / 12.92, encoded <= 0.04045);
    return float4(color, 1.0);
}
"""#
