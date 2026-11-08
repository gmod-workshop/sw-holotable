#include "common_ps_fxc.h"

sampler BASETEXTURE : register(s0);

// Static style controls set when a cached material is first used after a
// related cvar changes. Per-table/time controls arrive through the VS.
float4 C0 : register(c0); // rim, opacity, texture mix, contours
float4 C1 : register(c1); // scan strength/speed, band strength/speed
float4 C2 : register(c2); // noise scale/strength, glitch period/length
float4 C3 : register(c3); // glitch, alpha threshold, source alpha, projector rate

struct PS_INPUT {
    float2 uv           : TEXCOORD0;
    float3 worldPos     : TEXCOORD1;
    float3 center       : TEXCOORD2;
    float3 axis         : TEXCOORD3;
    float3 clipData     : TEXCOORD4;
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
    float3 offset = frag.worldPos - frag.center;
    float along = dot(offset, axis);
    float3 radial = offset - axis * along;
    float worldAlong = dot(frag.worldPos, axis);

    clip(frag.clipData.x - dot(radial, radial));
    clip(worldAlong - frag.clipData.y);

    float time = frag.effectParams.x;
    float strength = frag.tintStrength.w;
    float reveal = saturate(frag.effectParams.w);
    float revealHeight = saturate((worldAlong - frag.clipData.z) / 100);
    float revealNoise = hash21(floor(frag.worldPos.xy * 0.18));
    float revealPattern = saturate(revealHeight * 0.72 + revealNoise * 0.28);
    float revealThreshold = 0.001 + revealPattern * 0.998;
    clip(reveal - revealThreshold);
    float revealEdge = (1 - saturate(abs(reveal - revealThreshold) * 20))
        * (1 - smoothstep(0.94, 1, reveal));
    float glitchAge = fmod(max(time, 0), max(C2.z, 0.01));
    float glitchGate = 1 - saturate(glitchAge / max(C2.w, 0.001));
    float sliceNoise = hash21(float2(floor(along * 0.35), floor(time * 12)));

    float2 uv = frag.uv;
    uv.x += (sliceNoise - 0.5) * 0.035 * C3.x * glitchGate * strength;
    float4 base = tex2D(BASETEXTURE, uv);
    clip(base.a - C3.y);

    float scanPhase = frac(along * frag.effectParams.y + time * C1.y);
    float scanline = pow(saturate(1 - abs(scanPhase - 0.5) * 2), 28);
    float bandPhase = frac(along * 0.0125 + time * C1.w);
    float scanBand = pow(saturate(1 - abs(bandPhase - 0.5) * 2), 6);

    float contourPhase = frac(along * frag.effectParams.z);
    float contour = pow(saturate(1 - abs(contourPhase - 0.5) * 2), 20);

    float3 normal = normalize(frag.worldNormal);
    float3 viewDir = normalize(cEyePos - frag.worldPos);
    float rim = pow(1 - saturate(abs(dot(normal, viewDir))), 2);

    float signalNoise = hash21(floor(frag.worldPos.xy * C2.x) + floor(time * 18));
    float luminance = dot(base.rgb, float3(0.299, 0.587, 0.114));
    float3 tint = frag.tintStrength.rgb;
    float textureMix = saturate(C0.z);
    float3 hologram = tint * (0.12 + luminance * 0.65);
    float3 textured = base.rgb * lerp(tint, float3(1, 1, 1), textureMix);
    float3 color = lerp(hologram, textured, textureMix);

    // Tie the projected object back to the physical emitter. This narrow
    // lower-edge illumination shares the volume pulse but remains part of the
    // hologram material, so translucent content can composite over the volume.
    float projectorHeight = worldAlong - dot(frag.center, axis) - 27.8;
    float sourceGlow = smoothstep(-5, 0, projectorHeight)
        * (1 - smoothstep(0, 18, projectorHeight));
    float sourcePulse = 0.88 + 0.12 * sin(time * C3.w * 3.1);
    color += tint * strength * sourceGlow * sourcePulse * (0.32 + rim * 0.18);

    color += tint * strength * 0.35 * (
        scanline * C1.x
        + scanBand * C1.z
        + contour * C0.w
        + rim * C0.x);
    color += tint * revealEdge * strength * 0.9;
    color *= lerp(1 - C2.y, 1 + C2.y, signalNoise);
    color *= lerp(1, 0.55 + sliceNoise, glitchGate * C3.x * 0.35 * strength);

    float alpha = lerp(1, base.a, C3.z) * C0.y;
    alpha *= saturate(0.72 + scanline * 0.2 + rim * 0.18);
    alpha *= 1 + sourceGlow * 0.12;
    return FinalOutput(float4(color, alpha), 0, PIXEL_FOG_TYPE_NONE, TONEMAP_SCALE_LINEAR);
}
