#include <metal_stdlib>
using namespace metal;

// Layouts are shared with TerrainRenderer.swift. float3 is 16-byte aligned.
struct RidgeVertex { float3 position; float3 normal; float2 uv; };
struct RidgeUniforms {
    float4x4 viewProjection;
    float4 textureRect;
    float4 color;
    float4 style;             // material: terrain=0, solid=1, marker=2, selection=3, shadow=4
    float4 cameraRight;
    float4 cameraUp;
    float4 contextRect;
    float4 clearRect;         // primary and nearby terrain stay clear
    float4 atmosphere;        // primary world width/depth, outer-edge fade, haze distance
    float4 daylight;
};
struct RidgeVarying {
    float4 position [[position]];
    float3 normal;
    float2 uv;
    float height;
    float markerKind;
};

// A single triangle, no sky textures or extra terrain. The same geographic sky
// colour is used by haze so the distant edge blends into daylight as we orbit.
float3 ridgeSkyColor(float2 pixel, constant RidgeUniforms &u) {
    float2 viewport = max(u.daylight.xy, float2(1));
    float2 ndc = pixel / viewport * 2 - 1;
    float3 right = u.cameraRight.xyz, up = u.cameraUp.xyz;
    float3 ray = normalize(-cross(right, up) + right * ndc.x * viewport.x / viewport.y * u.daylight.z - up * ndc.y * u.daylight.z);
    float blue = smoothstep(0.0, 0.55, max(0.0, ray.y));
    float3 sky = mix(float3(0.80, 0.90, 0.96), float3(0.25, 0.56, 0.88), blue);
    float sunshine = pow(max(0.0, dot(ray, normalize(float3(-0.45, 0.85, -0.4)))), 24.0);
    return mix(sky, float3(1.0, 0.97, 0.86), sunshine * 0.45);
}

vertex float4 ridgeSkyVertex(uint id [[vertex_id]]) {
    const float2 corners[] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    return float4(corners[id], 1, 1);
}

fragment float4 ridgeSkyFragment(float4 position [[position]], constant RidgeUniforms &u [[buffer(1)]]) {
    return float4(ridgeSkyColor(position.xy, u), 1);
}

vertex RidgeVarying ridgeVertex(uint id [[vertex_id]], const device RidgeVertex *vertices [[buffer(0)]], constant RidgeUniforms &u [[buffer(1)]]) {
    RidgeVertex input = vertices[id];
    float3 position = input.position;
    if (u.style.x == 2 || u.style.x == 3) {
        position += (u.cameraRight.xyz * input.uv.x + u.cameraUp.xyz * input.uv.y) * u.style.y;
        // A small camera-facing offset keeps the complete circle readable while
        // retaining its exact screen anchor and terrain occlusion behind ridges.
        position += cross(u.cameraRight.xyz, u.cameraUp.xyz) * u.style.y * 2.4;
    }
    RidgeVarying out;
    out.position = u.viewProjection * float4(position, 1);
    out.normal = input.normal;
    out.uv = input.uv;
    out.height = input.position.y;
    out.markerKind = input.normal.x;
    return out;
}

float4 ridgeShade(RidgeVarying in, constant RidgeUniforms &u, float3 mapColor) {
    if (u.style.x == 4) {
        float2 q = abs(in.uv * 2 - 1);
        float shadow = (1 - smoothstep(0.73, 1.0, q.x)) * (1 - smoothstep(0.73, 1.0, q.y));
        return float4(0.09, 0.14, 0.11, 0.16 * shadow);
    }
    if (u.style.x == 2 || u.style.x == 3) {
        float radius = length(in.uv);
        float aa = max(fwidth(radius), 0.02);
        if (radius > 1) discard_fragment();
        float alpha = 1 - smoothstep(1 - aa, 1, radius);
        if (u.style.x == 3) {
            if (radius < 0.66) discard_fragment();
            return float4(u.color.rgb, alpha);
        }
        float3 ink = in.markerKind < 0.5 ? float3(0.026, 0.12, 0.078) : u.color.rgb;
        float border = smoothstep(0.67 - aa, 0.67 + aa, radius);
        float3 color = mix(ink, float3(0.98, 0.965, 0.92), border);
        color = mix(float3(0.99, 0.98, 0.95), color, smoothstep(0.14, 0.23, radius));
        return float4(color, alpha);
    }
    if (u.style.x == 1) {
        float light = u.style.z > 0 ? 0.77 + 0.23 * max(0.0, dot(normalize(in.normal), normalize(float3(-0.4, 0.8, -0.35)))) : 1;
        return float4(u.color.rgb * light, u.color.a);
    }
    float3 n = normalize(in.normal);
    float sunlight = max(0.0, dot(n, normalize(float3(-0.45, 0.85, -0.4))));
    float light = 0.86 + 0.16 * sunlight;
    float3 color = mapColor;
    color *= light;
    color *= mix(float3(1), float3(1.015, 1.005, 0.985), sunlight);
    float alpha = 1;
    if (u.atmosphere.z > 0) {
        float3 background = ridgeSkyColor(in.position.xy, u);
        float2 outside = max(max(u.clearRect.xy - in.uv, in.uv - u.clearRect.xy - u.clearRect.zw), float2(0)) * u.atmosphere.xy;
        // Cartography has one material across every terrain resolution. Haze
        // depends only on geographic distance, with no tint at a mesh seam.
        float haze = smoothstep(0.0, u.atmosphere.w, length(outside));
        color = mix(color, background, haze * 0.65);
        // A broad fade hides the finite source edge. Clamp each side's fade to
        // its available surroundings so it never washes out the planning area.
        float2 nearEdge = (in.uv - u.contextRect.xy) * u.atmosphere.xy;
        float2 farEdge = (u.contextRect.xy + u.contextRect.zw - in.uv) * u.atmosphere.xy;
        float2 nearWidth = min(float2(u.atmosphere.z), max(-u.contextRect.xy * u.atmosphere.xy, float2(0)));
        float2 farWidth = min(float2(u.atmosphere.z), max((u.contextRect.xy + u.contextRect.zw - 1) * u.atmosphere.xy, float2(0)));
        float2 nearFade = select(float2(1), smoothstep(float2(0), max(nearWidth, float2(1e-6)), nearEdge), nearWidth > 1e-6);
        float2 farFade = select(float2(1), smoothstep(float2(0), max(farWidth, float2(1e-6)), farEdge), farWidth > 1e-6);
        alpha = min(min(nearFade.x, nearFade.y), min(farFade.x, farFade.y));
    }
    return float4(color, alpha);
}


fragment float4 ridgeFragment(RidgeVarying in [[stage_in]], constant RidgeUniforms &u [[buffer(1)]],
                              texture2d<float> cartography [[texture(0)]], sampler mapSampler [[sampler(0)]]) {
    float3 color = float3(1);
    if (u.style.x == 0) color = cartography.sample(mapSampler, (in.uv - u.textureRect.xy) / u.textureRect.zw).rgb;
    return ridgeShade(in, u, color);
}

struct CartographyUniforms {
    uint4 grid; // columns, rows, reserved
    float4 sampling; // native core ratio and gutter, preview core ratio and gutter
    float4 mediumSampling; // medium core ratio and gutter, reserved
};

uint ridgeMapCell(const device float *edges, uint count, float coordinate) {
    uint low = 0, high = count;
    while (low + 1 < high) {
        uint middle = (low + high) / 2;
        if (edges[middle] <= coordinate) low = middle; else high = middle;
    }
    return min(count - 1, low);
}

fragment float4 ridgeAtlasFragment(RidgeVarying in [[stage_in]], constant RidgeUniforms &u [[buffer(1)]],
                                   constant CartographyUniforms &atlas [[buffer(2)]],
                                   const device float *longitudeEdges [[buffer(3)]],
                                   const device float *latitudeEdges [[buffer(4)]],
                                   const device uint4 *pages [[buffer(5)]],
                                   texture2d<float> preview [[texture(1)]],
                                   texture2d_array<float> native [[texture(3)]],
                                   texture2d_array<float> medium [[texture(4)]],
                                   sampler mapSampler [[sampler(0)]]) {
    float3 color = float3(1);
    // Derivatives are taken before cell lookup; discontinuities in local tile
    // coordinates must never force a blurry mip at a geographic map seam.
    float2 gradientX = dfdx(in.uv), gradientY = dfdy(in.uv);
    if (u.style.x == 0) {
        uint column = ridgeMapCell(longitudeEdges, atlas.grid.x, in.uv.x);
        uint row = ridgeMapCell(latitudeEdges, atlas.grid.y, in.uv.y);
        uint tile = row * atlas.grid.x + column;
        float2 origin = float2(longitudeEdges[column], latitudeEdges[row]);
        float2 span = float2(longitudeEdges[column + 1], latitudeEdges[row + 1]) - origin;
        float2 local = clamp((in.uv - origin) / span, float2(0), float2(1));
        float2 dx = gradientX / span, dy = gradientY / span;
        float2 previewSpan = float2(atlas.grid.xy);
        float2 previewUV = (float2(column, row) + local) / previewSpan;
        gradient2d previewGradient(dx / previewSpan, dy / previewSpan);
        color = preview.sample(mapSampler, previewUV, previewGradient).rgb;
        uint4 page = pages[tile];
        float2 detailUV = local * atlas.sampling.x + atlas.sampling.y;
        gradient2d detailGradient(dx * atlas.sampling.x, dy * atlas.sampling.x);
        if (page.z > 0) {
            float2 mediumUV = local * atlas.mediumSampling.x + atlas.mediumSampling.y;
            gradient2d mediumGradient(dx * atlas.mediumSampling.x, dy * atlas.mediumSampling.x);
            float3 detail = medium.sample(mapSampler, mediumUV, page.z - 1, mediumGradient).rgb;
            color = mix(color, detail, as_type<float>(page.w));
        }
        if (page.x > 0) {
            float3 detail = native.sample(mapSampler, detailUV, page.x - 1, detailGradient).rgb;
            color = mix(color, detail, as_type<float>(page.y));
        }
    }
    return ridgeShade(in, u, color);
}
