#include "common_ps_fxc.h"
#include "holotable_atlas_common.h"

// Atlas variant of holotable_clip_ps2x (SM 3.0 for screen derivatives).
// BASETEXTURE is an atlas page; each vertex carries its texture's tile
// origin, and the original (possibly repeating) UV wraps inside that tile.
// See holotable_atlas_common.h for the tile layout and level selection.

sampler BASETEXTURE : register(s0);

float4 C0 : register(c0); // z = alpha clip threshold

struct PS_INPUT {
    float2 uv       : TEXCOORD0;
    float3 worldPos : TEXCOORD1;
    float3 center   : TEXCOORD2;
    float3 axis     : TEXCOORD3;
    float3 clipData : TEXCOORD4;
    float2 tile     : TEXCOORD5;
};

float4 main(PS_INPUT frag) : COLOR {
    float3 axis = normalize(frag.axis);
    float3 offset = frag.worldPos - frag.center;
    float alongFromCenter = dot(offset, axis);
    float3 radial = offset - axis * alongFromCenter;
    float worldAlong = dot(frag.worldPos, axis);

    // clipData = radius squared, lower plane, upper plane.
    clip(frag.clipData.x - dot(radial, radial));
    clip(worldAlong - frag.clipData.y);
    clip(frag.clipData.z - worldAlong);

    float2 tile = frag.tile;
    float alphaClass = AtlasDecodeTile(tile);
    float4 color = AtlasSample(BASETEXTURE, tile, frag.uv, frag.uv);
    // Translucent variants blend with this alpha; opaque ones ignore it.
    clip(color.a - AtlasAlphaThreshold(alphaClass, C0.z));
    return FinalOutput(color, 0, PIXEL_FOG_TYPE_NONE, TONEMAP_SCALE_LINEAR);
}
