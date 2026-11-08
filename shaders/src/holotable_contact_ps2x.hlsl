#include "common_ps_fxc.h"

sampler BASETEXTURE : register(s0);

float4 C0 : register(c0); // rim, opacity, texture mix, scan strength
float4 C1 : register(c1); // band strength, noise, glitch, alpha threshold
float4 C2 : register(c2); // source alpha, reveal edge, signal rate, reserved

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
    float reveal = saturate(frag.effectParams.w);
    float visibility = saturate(frag.effectParams.z);

    // Materialize as coherent horizontal slices with a little spatial breakup.
    // Unlike a simple alpha fade, the silhouette remains crisp while appearing.
    float cellNoise = hash21(floor(frag.worldPos.xy * 0.45));
    float slicePattern = frac(along * 0.19 + cellNoise * 0.22);
    float revealThreshold = 0.015 + slicePattern * 0.97;
    clip(reveal - revealThreshold);
    float revealEdge = (1 - saturate(abs(reveal - revealThreshold) * 22))
        * (1 - smoothstep(0.96, 1, reveal));

    float sliceNoise = hash21(float2(floor(along * 0.55), floor(time * 15)));
    float glitchGate = step(0.88, hash21(float2(floor(time * C2.z),
        floor(along * 0.22))));
    float2 uv = frag.uv;
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
    float3 hologram = tint * (0.16 + luminance * 0.58);
    float3 textured = base.rgb * lerp(tint, float3(1, 1, 1), 0.25);
    float3 color = lerp(hologram, textured, textureMix);
    color += tint * (rim * C0.x + scanline * C0.w
        + scanBand * C1.x) * 0.34;
    color += tint * revealEdge * C2.y;
    color *= lerp(1 - C1.y, 1 + C1.y, signalNoise);
    color *= lerp(1, 0.62 + sliceNoise * 0.25, glitchGate * C1.z);
    color *= visibility;

    float alpha = lerp(1, base.a, C2.x) * C0.y * visibility;
    alpha *= saturate(0.74 + scanline * 0.16 + rim * 0.2);
    return FinalOutput(float4(color, alpha), 0, PIXEL_FOG_TYPE_NONE,
        TONEMAP_SCALE_LINEAR);
}
