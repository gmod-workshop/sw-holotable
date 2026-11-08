#include "common_ps_fxc.h"

sampler BASETEXTURE : register(s0);
sampler SCENEDEPTH  : register(s1);

float4 C0 : register(c0); // rim, opacity, texture mix, scan strength
float4 C1 : register(c1); // band strength, noise, glitch, alpha threshold
float4 C2 : register(c2); // source alpha, reveal edge, signal rate, brightness
float4 C3 : register(c3); // depth UV scale, edge width, edge strength

struct PS_INPUT {
    float4 uvScreen     : TEXCOORD0;
    float3 worldPos     : TEXCOORD1;
    float4 centerDepth  : TEXCOORD2;
    float3 axis         : TEXCOORD3;
    float4 clipData     : TEXCOORD4;
    float3 worldNormal  : TEXCOORD5;
    float4 tintStrength : TEXCOORD6;
    float4 effectParams : TEXCOORD7;
};

float hash21(float2 p) {
    p = frac(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return frac(p.x * p.y);
}

float4 main(PS_INPUT frag) : COLOR {
    float3 axis = normalize(frag.axis);
    float3 offset = frag.worldPos - frag.centerDepth.xyz;
    float along = dot(offset, axis);
    float3 radial = offset - axis * along;
    float worldAlong = dot(frag.worldPos, axis);

    clip(frag.clipData.x - dot(radial, radial));
    clip(worldAlong - frag.clipData.y);

    float time = frag.effectParams.x;
    float reveal = saturate(frag.effectParams.w);
    float visibility = saturate(frag.effectParams.z);
    float cellNoise = hash21(floor(frag.worldPos.xy * 0.45));
    float slicePattern = frac(along * 0.19 + cellNoise * 0.22);
    float revealThreshold = 0.015 + slicePattern * 0.97;
    clip(reveal - revealThreshold);
    float revealEdge = (1 - saturate(abs(reveal - revealThreshold) * 22))
        * (1 - smoothstep(0.96, 1, reveal));

    float sliceNoise = hash21(float2(floor(along * 0.55), floor(time * 15)));
    float glitchGate = step(0.88, hash21(float2(floor(time * C2.z),
        floor(along * 0.22))));
    float2 uv = frag.uvScreen.xy;
    uv.x += (sliceNoise - 0.5) * 0.025 * C1.z * glitchGate;
    float4 base = tex2D(BASETEXTURE, uv);
    clip(base.a - C1.w);

    float scanPhase = frac(along * frag.effectParams.y + time * -0.42);
    float scanline = pow(saturate(1 - abs(scanPhase - 0.5) * 2), 24);
    float bandPhase = frac(along * 0.045 - time * 0.11);
    float scanBand = pow(saturate(1 - abs(bandPhase - 0.5) * 2), 5);

    float3 normal = normalize(frag.worldNormal);
    float3 viewDir = normalize(cEyePos - frag.worldPos);
    float rim = pow(1 - saturate(abs(dot(normal, viewDir))), 2.25);
    float signalNoise = hash21(floor(frag.worldPos.xy * 2.2) + floor(time * 19));

    float luminance = dot(base.rgb, float3(0.299, 0.587, 0.114));
    float3 tint = frag.tintStrength.rgb;
    float textureMix = saturate(C0.z);
    // Self-lit fill: retain texture detail without letting a black uniform or
    // hull paint turn off the projector. Native models and proxies share tint.
    float3 hologram = tint * (0.45 + luminance * 0.35);
    float3 textured = base.rgb * lerp(tint, float3(1, 1, 1), 0.25);
    float3 color = lerp(hologram, textured, textureMix);
    color += tint * (rim * C0.x + scanline * C0.w
        + scanBand * C1.x) * 0.48;
    color += tint * revealEdge * C2.y;
    color *= lerp(1 - C1.y, 1 + C1.y, signalNoise);
    color *= lerp(1, 0.62 + sliceNoise * 0.25, glitchGate * C1.z);

    // Lua copies map depth just before radar contacts draw. The legacy depth
    // texture keeps scene RGB and writes depth to alpha on PC.
    float clipW = max(abs(frag.clipData.w), 0.0001);
    float2 depthUv = float2(
        frag.uvScreen.z / clipW * 0.5 + 0.5,
        0.5 - frag.uvScreen.w / clipW * 0.5) * C3.xy;
    float sceneDepth = tex2D(SCENEDEPTH, saturate(depthUv)).a;
    float contactDepth = frag.centerDepth.w / clipW;
    float depthGap = max(sceneDepth - contactDepth, 0);
    float edgeEnabled = step(0.000001, C3.z);
    float edgeWidth = max(C3.z, 0.000001);
    float hasSurface = step(contactDepth + 0.000001, sceneDepth)
        * (1 - step(0.9999, sceneDepth));
    float intersection = (1 - smoothstep(edgeWidth * 0.12, edgeWidth, depthGap))
        * edgeEnabled * hasSurface;
    color += tint * intersection * C3.w
        * (0.72 + scanline * 0.28);
    color *= visibility * C2.w;

    float alpha = lerp(1, base.a, C2.x) * C0.y * visibility;
    alpha *= saturate(0.82 + scanline * 0.12 + rim * 0.16);
    float surfaceFade = smoothstep(0, edgeWidth * 0.55, depthGap);
    alpha *= lerp(1, 0.48 + surfaceFade * 0.52,
        edgeEnabled * hasSurface);
    alpha = max(alpha, intersection * C0.y * visibility * 0.72);
    return FinalOutput(float4(color, alpha), 0, PIXEL_FOG_TYPE_NONE,
        TONEMAP_SCALE_LINEAR);
}
