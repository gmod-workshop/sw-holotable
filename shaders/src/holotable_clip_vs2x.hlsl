#include "common_vs_fxc.h"

struct VS_INPUT {
    float4 position : POSITION;
    float2 uv       : TEXCOORD0;
};

struct VS_OUTPUT {
    float4 projected : POSITION;
    float2 uv        : TEXCOORD0;
    float3 worldPos  : TEXCOORD1;
    float3 center    : TEXCOORD2;
    float3 axis      : TEXCOORD3;
    float3 clipData  : TEXCOORD4;
};

VS_OUTPUT main(VS_INPUT vert) {
    float3 worldPos;
    SkinPosition(0, vert.position, 0, 0, worldPos);

    VS_OUTPUT output = (VS_OUTPUT)0;
    output.projected = mul(float4(worldPos, 1), cViewProj);
    output.uv = vert.uv;
    output.worldPos = worldPos;

    // GLua supplies these through render.SetModelLighting once per table:
    // +X = physical cylinder centre, -X = axis, +Y = radius/floor/top.
    output.center = cAmbientCubeX[0];
    output.axis = cAmbientCubeX[1];
    output.clipData = cAmbientCubeY[0];
    return output;
}
