// Badge shaders. Compiled together with the game's `shaderSource`, so the emblem cubes share the block material
// (GGX, studio environment, shadow filtering, ACES) and the bloom kernels instead of duplicating them.
// Struct layouts must match `BadgeInstance` and `BadgeLook` in BadgeRenderer.swift.
let badgeShaderSource = #"""

struct BadgeInstance {
    float4x4 model;
    float4 color;      // rgb albedo
    float4 params;     // x emissive, y edge glow, z white-hot flash, w locked (dark steel)
};

struct BadgeLook {
    float4 tint;       // rgb trim and neon colour, w 1 when unlocked
    float4 plate;      // x inradius, y corner radius, z bevel radius, w neon ring inset
    float4 sweep;      // x sweep position, y sweep strength
    float4 rimDir;     // xyz towards the rim light
    float4 grid;       // xy a cell centre on the plate, z cell size
};

struct BadgeOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float3 local;
    float3 localNormal;
    float4 color [[flat]];
    float4 params [[flat]];
};

vertex BadgeOut badgeVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                            const device Vertex *verts [[buffer(0)]],
                            const device BadgeInstance *instances [[buffer(1)]],
                            constant Frame &f [[buffer(2)]]) {
    Vertex v = verts[vid];
    BadgeInstance inst = instances[iid];
    float4 world = inst.model * float4(v.position.xyz, 1.0);
    BadgeOut out;
    out.position = f.viewProj * world;
    out.world = world.xyz;
    out.normal = normalize((inst.model * float4(v.normal.xyz, 0.0)).xyz);
    out.local = v.position.xyz;
    out.localNormal = v.normal.xyz;
    out.color = inst.color;
    out.params = inst.params;
    return out;
}

vertex ShadowOut badgeShadowVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                   const device Vertex *verts [[buffer(0)]],
                                   const device BadgeInstance *instances [[buffer(1)]],
                                   constant Frame &f [[buffer(2)]]) {
    return { f.lightViewProj * (instances[iid].model * float4(verts[vid].position.xyz, 1.0)) };
}

/// Cool back light that outlines silhouettes against the dark panels.
float3 badgeRim(float3 N, float3 V, constant BadgeLook &look) {
    float rim = pow(1.0 - saturate(dot(N, V)), 2.0) * saturate(dot(N, look.rimDir.xyz));
    return rim * mix(float3(0.55, 0.65, 0.9), look.tint.rgb, 0.35) * 1.6;
}

/// A soft diagonal band of light that glides across the badge while it is animated.
float3 badgeSweep(float3 world, float3 N, float3 V, constant BadgeLook &look) {
    if (look.sweep.y <= 0.0) return 0.0;
    float along = dot(world.xy, float2(0.7071, 0.7071)) - look.sweep.x;
    float band = exp(-along * along * 2.5);
    float fres = pow(1.0 - saturate(dot(N, V)), 2.0);
    return float3(1.0, 0.97, 0.92) * band * look.sweep.y * (0.08 + 1.4 * fres);
}

fragment float4 badgeCubeFragment(BadgeOut in [[stage_in]],
                                  constant Frame &f [[buffer(0)]],
                                  constant BadgeLook &look [[buffer(1)]],
                                  depth2d<float> shadowMap [[texture(0)]]) {
    float3 N = normalize(in.normal);
    float3 V = normalize(f.cameraPos.xyz - in.world);
    float shadow = shadowFactor(in.world + N * 0.03, f, shadowMap);
    float3 albedo = in.color.rgb;
    bool locked = in.params.w > 0.5;
    float3 color;
    if (locked) {
        color = shadeSurface(albedo, specularAA(0.36, N), 0.9, N, V, in.world, shadow, f);
        color += badgeRim(N, V, look) * 0.25;
    } else {
        // The game's candy-glass block: GGX plus an inner glow along the inset rim and at grazing angles.
        float edge = faceEdge(in.local);
        float fres = pow(1.0 - saturate(dot(N, V)), 3.0);
        color = shadeSurface(albedo, specularAA(0.26, N), 0.0, N, V, in.world, shadow, f);
        color += albedo * (in.params.x * (0.35 + 1.4 * edge) + in.params.y * edge + fres * 0.15);
        color += badgeRim(N, V, look);
    }
    color += badgeSweep(in.world, N, V, look);
    color = mix(color, float3(6.0, 6.2, 7.0) + albedo * 4.0, in.params.z);
    return float4(color, 1.0);
}

/// Signed distance to the plate outline (pointy-top hexagon with rounded corners), negative inside.
float badgePlateDistance(float2 p, float4 plate) {
    const float3 k = float3(-0.866025404, 0.5, 0.577350269);
    p = abs(p.yx);
    p -= 2.0 * min(dot(k.xy, p), 0.0) * k.xy;
    float r = plate.x - plate.y;
    p -= float2(clamp(p.x, -k.z * r, k.z * r), r);
    return length(p) * sign(p.y) - plate.y;
}

fragment float4 badgePlateFragment(BadgeOut in [[stage_in]],
                                   constant Frame &f [[buffer(0)]],
                                   constant BadgeLook &look [[buffer(1)]],
                                   depth2d<float> shadowMap [[texture(0)]]) {
    float3 N = normalize(in.normal);
    float3 V = normalize(f.cameraPos.xyz - in.world);
    float shadow = shadowFactor(in.world + N * 0.03, f, shadowMap);
    bool lit = look.tint.w > 0.5;
    float d = badgePlateDistance(in.local.xy, look.plate);
    float aa = max(fwidth(d), 1e-4);
    float front = smoothstep(0.5, 0.9, in.localNormal.z);

    // Dark steel field inside a polished trim of the tier's metal (bevel and a narrow band before it).
    float trim = smoothstep(-aa, aa, d + look.plate.z + 0.16);
    float3 trimMetal = lit ? look.tint.rgb * 0.6 + 0.08 : float3(0.07, 0.072, 0.08);
    float3 albedo = mix(float3(0.045, 0.05, 0.065), trimMetal, trim);
    float3 color = shadeSurface(albedo, specularAA(mix(0.34, 0.2, trim), N), 0.9, N, V, in.world, shadow, f);

    // Faint cell grid, like the back panel of the well, aligned with the emblem's cubes.
    float2 cell = (in.local.xy - look.grid.xy) / look.grid.z + 0.5;
    float field = front * (1.0 - trim);
    float lines = grid(cell, 0.035) * field * smoothstep(0.0, -1.2, d + look.plate.w);

    // Neon ring set into the field, lit like the well frame's stripe.
    float ring = abs(d + look.plate.w);
    float stripe = (1.0 - smoothstep(0.07 - aa, 0.07 + aa, ring)) * front;
    if (lit) {
        color += look.tint.rgb * (stripe * 5.0 + exp(-ring * 7.0) * front * 0.12 + lines * 0.07);
    } else {
        color *= 1.0 - stripe * 0.75;
        color += float3(0.02) * lines;
    }
    color += badgeRim(N, V, look) * (lit ? 0.8 : 0.3);
    color += badgeSweep(in.world, N, V, look) * 0.6;
    return float4(color, 1.0);
}

struct BadgePost {
    float bloom;
    float exposure;
};

/// Resolves the 2x supersampled HDR image: tone-maps each sample, box-filters 2x2, adds bloom, and writes
/// premultiplied, sRGB-encoded colour with the badge's coverage (and its glow) as alpha.
fragment float4 badgeCompositeFragment(FullscreenOut in [[stage_in]],
                                       texture2d<float> hdr [[texture(0)]],
                                       texture2d<float> bloom [[texture(1)]],
                                       constant BadgePost &post [[buffer(0)]]) {
    uint2 base = uint2(in.position.xy) * 2;
    float4 sum = 0.0;
    for (uint y = 0; y < 2; y++) {
        for (uint x = 0; x < 2; x++) {
            float4 s = hdr.read(base + uint2(x, y));
            float3 straight = s.rgb / max(s.a, 1e-4);
            sum += float4(acesFilm(straight * post.exposure) * s.a, s.a);
        }
    }
    sum *= 0.25;
    float3 glow = 1.0 - exp(-bloom.sample(linearClamp, in.uv).rgb * post.bloom);
    float3 color = sum.rgb + glow * (1.0 - sum.rgb);
    float alpha = saturate(max(sum.a, max(glow.r, max(glow.g, glow.b))));
    color = min(color, alpha);
    float3 straight = color / max(alpha, 1e-5);
    float3 encoded = select(1.055 * pow(straight, 1.0 / 2.4) - 0.055, straight * 12.92, straight <= 0.0031308);
    return float4(encoded * alpha, alpha);
}
"""#
