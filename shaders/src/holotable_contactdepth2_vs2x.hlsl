#include "common_vs_fxc.h"

struct VS_INPUT {
    float4 position : POSITION;
    float2 uv       : TEXCOORD0;
    float3 normal   : NORMAL0;
};

struct VS_OUTPUT {
    float4 projected    : POSITION;
    float4 uvScreen     : TEXCOORD0; // source UV, clip-space XY
    float3 worldPos     : TEXCOORD1;
    float4 centerDepth  : TEXCOORD2; // table center, clip-space Z
    float3 axis         : TEXCOORD3;
    float4 clipData     : TEXCOORD4; // radius/floor/reveal floor, clip W
    float3 worldNormal  : TEXCOORD5;
    float4 tintStrength : TEXCOORD6;
    float4 effectParams : TEXCOORD7;
};

VS_OUTPUT main(VS_INPUT vert) {
    float3 worldPos;
    float3 worldNormal;
    SkinPositionAndNormal(0, vert.position, vert.normal, 0, 0,
        worldPos, worldNormal);

    float4 projected = mul(float4(worldPos, 1), cViewProj);
    VS_OUTPUT output = (VS_OUTPUT)0;
    output.projected = projected;
    output.uvScreen = float4(vert.uv, projected.xy);
    output.worldPos = worldPos;
    output.worldNormal = worldNormal;
    output.centerDepth = float4(cAmbientCubeX[0], projected.z);
    output.axis = cAmbientCubeX[1];
    output.clipData = float4(cAmbientCubeY[0], projected.w);
    output.tintStrength = float4(cAmbientCubeY[1], cAmbientCubeZ[0].y);
    output.effectParams = float4(
        cAmbientCubeZ[0].x,
        cAmbientCubeZ[0].z,
        cAmbientCubeZ[1].x,
        cAmbientCubeZ[1].y);
    return output;
}
