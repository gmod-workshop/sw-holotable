// Texture-atlas sampling shared by the holotable_atlas* shaders. The page
// layout must match map/cl_map_atlas.lua: every tile stores four levels
// (64, 32, 16 and 8 px), each surrounded by 2 px of wrapped padding, at
// these offsets (texels) from the level-0 inner origin:
//   level 0 (0, 0), level 1 (68, 0), level 2 (68, 36), level 3 (88, 36).
// Pages have no hardware mips: the level is picked per pixel from the
// screen derivatives of the unwrapped UV (so frac() seams do not spike it)
// and two levels are blended, i.e. manual trilinear filtering.

// The tile origin's U also carries the texture's alpha class (Lua adds
// 2 * class; the origin itself is always in [0, 1)): 0 opaque, 1 alpha-
// tested, 2 translucent.
#define ATLAS_ALPHA_TEST 1.0
#define ATLAS_ALPHA_BLEND 2.0

#define ATLAS_PAGE_SIZE 2048.0
#define ATLAS_TILE_SIZE 64.0
#define ATLAS_MAX_LEVEL 3.0

// Strips the alpha class from tile and returns it.
float AtlasDecodeTile(inout float2 tile) {
    float alphaClass = floor(tile.x * 0.5);
    tile.x -= alphaClass * 2.0;
    return alphaClass;
}

// Clip threshold for an alpha class; opaque falls back to the material's.
float AtlasAlphaThreshold(float alphaClass, float opaqueThreshold) {
    return alphaClass >= ATLAS_ALPHA_BLEND ? (1.0 / 255.0)
        : (alphaClass >= ATLAS_ALPHA_TEST ? 0.5 : opaqueThreshold);
}

float2 AtlasLevelOffset(float level) {
    return float2(level >= 1.0 ? (level >= 3.0 ? 88.0 : 68.0) : 0.0,
                  level >= 2.0 ? 36.0 : 0.0) / ATLAS_PAGE_SIZE;
}

float4 AtlasSampleLevel(sampler page, float2 tile, float2 wrapped, float level) {
    float size = ATLAS_TILE_SIZE / ATLAS_PAGE_SIZE * exp2(-level);
    return tex2Dlod(page, float4(tile + AtlasLevelOffset(level) + wrapped * size, 0, 0));
}

// tile:  level-0 inner origin of the texture's tile, in page UV.
// uv:    source UV to sample (may repeat).
// lodUV: UV whose screen footprint picks the level (uv without effects).
float4 AtlasSample(sampler page, float2 tile, float2 uv, float2 lodUV) {
    float2 dx = ddx(lodUV) * ATLAS_TILE_SIZE;
    float2 dy = ddy(lodUV) * ATLAS_TILE_SIZE;
    float rho2 = max(dot(dx, dx), dot(dy, dy));
    float lod = clamp(0.5 * log2(max(rho2, 1e-8)), 0.0, ATLAS_MAX_LEVEL);
    float lo = floor(lod);
    float2 wrapped = frac(uv);
    float4 a = AtlasSampleLevel(page, tile, wrapped, lo);
    float4 b = AtlasSampleLevel(page, tile, wrapped, min(lo + 1.0, ATLAS_MAX_LEVEL));
    return lerp(a, b, lod - lo);
}
