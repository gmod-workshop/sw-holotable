#include "common_vs_fxc.h"

struct VS_INPUT {
    float4 position : POSITION;
    float2 uv       : TEXCOORD0;
    float3 normal   : NORMAL0;
};

struct VS_OUTPUT {
    float4 projected    : POSITION;
    float3 worldPos     : TEXCOORD0;
    float3 worldNormal  : TEXCOORD1;
    float3 tint         : TEXCOORD2;
    float3 axis         : TEXCOORD3;
    float3 haloParams   : TEXCOORD4;
    float2 uv           : TEXCOORD5;
};

VS_OUTPUT main(VS_INPUT vert) {
    float3 worldPos;
    float3 worldNormal;
    SkinPositionAndNormal(0, vert.position, vert.normal, 0, 0,
        worldPos, worldNormal);

    float4 projected = mul(float4(worldPos, 1), cViewProj);
    float4 normalPoint = mul(float4(worldPos + normalize(worldNormal), 1),
        cViewProj);
    float2 ndc = projected.xy / max(abs(projected.w), 0.0001);
    float2 normalNdc = normalPoint.xy / max(abs(normalPoint.w), 0.0001);
    float2 inverseViewport = cAmbientCubeX[0].xy;
    float2 pixelDirection = (normalNdc - ndc)
        / max(inverseViewport, float2(0.000001, 0.000001));
    float pixelLength = max(length(pixelDirection), 0.0001);
    pixelDirection /= pixelLength;
    projected.xy += pixelDirection * inverseViewport
        * cAmbientCubeX[0].z * projected.w;

    VS_OUTPUT output = (VS_OUTPUT)0;
    output.projected = projected;
    output.worldPos = worldPos;
    output.worldNormal = worldNormal;
    output.tint = cAmbientCubeX[1];
    output.axis = cAmbientCubeY[0];
    output.haloParams = cAmbientCubeY[1];
    output.uv = vert.uv;
    return output;
}
