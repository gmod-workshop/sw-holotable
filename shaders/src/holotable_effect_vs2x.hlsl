#include "common_vs_fxc.h"

struct VS_INPUT {
    float4 position : POSITION;
    float2 uv       : TEXCOORD0;
    float3 normal   : NORMAL0;
};

struct VS_OUTPUT {
    float4 projected    : POSITION;
    float2 uv           : TEXCOORD0;
    float3 worldPos     : TEXCOORD1;
    float3 center       : TEXCOORD2;
    float3 axis         : TEXCOORD3;
    float3 clipData     : TEXCOORD4;
    float3 worldNormal  : TEXCOORD5;
    float4 tintStrength : TEXCOORD6;
    float4 effectParams : TEXCOORD7;
};

VS_OUTPUT main(VS_INPUT vert) {
    float3 worldPos;
    float3 worldNormal;
    SkinPositionAndNormal(0, vert.position, vert.normal, 0, 0, worldPos, worldNormal);

    VS_OUTPUT output = (VS_OUTPUT)0;
    output.projected = mul(float4(worldPos, 1), cViewProj);
    output.uv = vert.uv;
    output.worldPos = worldPos;
    output.worldNormal = worldNormal;

    // Populated once per table by effects/cl_effects_shared.lua.
    output.center = cAmbientCubeX[0];
    output.axis = cAmbientCubeX[1];
    output.clipData = cAmbientCubeY[0];
    output.tintStrength = float4(cAmbientCubeY[1], cAmbientCubeZ[0].y);
    output.effectParams = float4(
        cAmbientCubeZ[0].x,
        cAmbientCubeZ[0].z,
        cAmbientCubeZ[1].x,
        cAmbientCubeZ[1].y);
    return output;
}
