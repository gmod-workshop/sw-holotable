#include "common_vs_fxc.h"

// Atlas variant of holotable_clip_vs2x, SM 3.0 to pair with the ps30 pixel
// shader. Also passes the vertex's atlas tile origin (TEXCOORD1, page UV
// space) through to the pixel shader.

struct VS_INPUT {
    float4 position : POSITION;
    float2 uv       : TEXCOORD0;
    float2 tile     : TEXCOORD1;
};

struct VS_OUTPUT {
    float4 projected : POSITION;
    float2 uv        : TEXCOORD0;
    float3 worldPos  : TEXCOORD1;
    float3 center    : TEXCOORD2;
    float3 axis      : TEXCOORD3;
    float3 clipData  : TEXCOORD4;
    float2 tile      : TEXCOORD5;
};

VS_OUTPUT main(VS_INPUT vert) {
    float3 worldPos;
    SkinPosition(0, vert.position, 0, 0, worldPos);

    VS_OUTPUT output = (VS_OUTPUT)0;
    output.projected = mul(float4(worldPos, 1), cViewProj);
    output.uv = vert.uv;
    output.worldPos = worldPos;

    // Same per-table constants as the clip shader, staged by GLua through
    // render.SetModelLighting: +X = cylinder centre, -X = axis,
    // +Y = radius squared / floor plane / top plane.
    output.center = cAmbientCubeX[0];
    output.axis = cAmbientCubeX[1];
    output.clipData = cAmbientCubeY[0];
    output.tile = vert.tile;
    return output;
}
