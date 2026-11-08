#include "common_ps_fxc.h"

sampler BASETEXTURE : register(s0);
float4 C0 : register(c0); // alpha threshold, source alpha, reserved, reserved

struct PS_INPUT {
    float3 worldPos     : TEXCOORD0;
    float3 worldNormal  : TEXCOORD1;
    float3 tint         : TEXCOORD2;
    float3 axis         : TEXCOORD3;
    float3 haloParams   : TEXCOORD4; // intensity, time, scan frequency
    float2 uv           : TEXCOORD5;
};

float4 main(PS_INPUT frag) : COLOR {
    float3 normal = normalize(frag.worldNormal);
    float3 viewDirection = normalize(cEyePos - frag.worldPos);
    float rim = pow(1 - saturate(abs(dot(normal, viewDirection))), 2.6);
    float along = dot(frag.worldPos, normalize(frag.axis));
    float scan = 0.82 + 0.18 * pow(saturate(1 - abs(
        frac(along * frag.haloParams.z - frag.haloParams.y * 0.35)
        - 0.5) * 2), 18);
    float sourceAlpha = tex2D(BASETEXTURE, frag.uv).a;
    clip(sourceAlpha - C0.x);
    float intensity = frag.haloParams.x * rim * scan
        * lerp(1, sourceAlpha, C0.y);
    clip(intensity - 0.001);
    return FinalOutput(float4(frag.tint * intensity, intensity), 0,
        PIXEL_FOG_TYPE_NONE, TONEMAP_SCALE_LINEAR);
}
