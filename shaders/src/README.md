# Holo-table shader prototype

## Building

Compile with the toolchain from
[meetric1/gmod_shader_guide](https://github.com/meetric1/gmod_shader_guide):
it bundles the standalone `ShaderCompile.exe` and GMod-adjusted Valve headers,
whose `common_ps_fxc.h` defines `cEyePos` for pixel shaders. Copy the kit's
`*.h` and this folder's `*.hlsl` / `*.h` into one directory, run
`ShaderCompile.exe /O 3 -ver 20b -shaderpath <dir> <name>_ps2x.hlsl` (`-ver 30`
for `_ps30` / `_vs30` sources) from it, and copy the resulting
`shaders/fxc/*.vcs` into `../fxc`. A ps30 must pair with a vs30. Stock Source SDK 2013
headers do not, so `holotable_effect_ps2x.hlsl` fails to compile against them.
This toolchain reproduces the committed `.vcs` files byte for byte.

`holotable_clip_vs2x.hlsl` and `holotable_clip_ps2x.hlsl` are compiled as
Shader Model 2.0b programs for GMod's `screenspace_general` material shader.
They require Valve's `common_vs_fxc.h`, `common_ps_fxc.h`, and their normal
Source shader include dependencies when compiling.

The runtime binaries belong in `shaders/fxc/` as:

- `holotable_clip_vs20.vcs`
- `holotable_clip_ps20b.vcs`
- `holotable_effect_vs20.vcs`
- `holotable_effect_ps20b.vcs`
- `holotable_volume_ps30.vcs`
- `holotable_contactdepth2_vs20.vcs`
- `holotable_contactradiance_ps20b.vcs`
- `holotable_contacthalo_vs20.vcs`
- `holotable_contactglow_ps20b.vcs`
- `holotable_contactlight2_ps30.vcs`
- `holotable_atlasclip_vs30.vcs`
- `holotable_atlasclip_ps30.vcs`
- `holotable_atlaseffect_vs30.vcs`
- `holotable_atlaseffect_ps30.vcs`

It clips the shared world bake (`map/cl_map_world.lua`) to the table's
cylinder and floor for partial views; `holo_table_shader_clip` (default 1)
controls it. All-in views keep the plain draw, and missing/failed shaders fall
back to the software clip builder. The third clip plane is an upper cap; the
runtime passes an effectively infinite value because the hologram world is
open at the top.

`holotable_atlasclip_vs30.hlsl` / `holotable_atlasclip_ps30.hlsl` are the clip
shader for meshes baked against texture-atlas pages (`map/cl_map_atlas.lua`):
each vertex carries its texture's tile origin in a second texcoord, and the
pixel shader wraps the original UV inside the tile. `holotable_atlaseffect_*`
is the same for the effect shader, generated from `holotable_effect_*` (keep
them in sync; the tile origin rides in `TEXCOORD0.zw`). The tile origin's U
also carries the texture's alpha class (opaque / alpha-tested / translucent).
Both sample through `holotable_atlas_common.h`, which must match the page
layout in Lua: every tile stores 64/32/16/8 px levels and the level is picked
per pixel from screen derivatives, hence Shader Model 3.0 (a ps30 needs a vs30
partner).

`holotable_effect_vs2x.hlsl` / `holotable_effect_ps2x.hlsl` add the optional
worldspawn, baked-prop, and BSP brush-entity styling pass. Enable it with
`holo_table_effects 1`; `holo_table_effect_props` controls baked static /
stable dynamic props, `holo_table_effect_brushes` controls live brushes, and
the `holo_table_effect_*` client cvars control tint, texture mix, opacity,
scanlines/band, contours, rim light, noise, glitch, and line spacing. It is
also disabled by default and falls back to the ordinary map renderer if its
material cannot be created or drawn.

The effect shader also consumes a per-table reveal value for the noisy
bottom-up power sequence. `holo_table_effect_power 0/1` changes its target,
`holo_table_effect_sequence_time` controls the transition duration, and
`holo_table_effect_replay` restarts materialization. Recompiling any shader
program under the same name requires a Garry's Mod restart before testing.

`holotable_volume_ps30.hlsl` is the optional GShader projector-volume pass. It
uses GShader's mounted `pp_vs30` vertex shader and samples reciprocal world
position from `_rt_WPDepth`. The runtime supplies one table's projector base,
axis, size, tint, strength, eye position, and time through `screenspace_general`
pixel constants. Six fixed samples integrate a tapered, depth-clamped volume;
Lua scissors each draw to the projected bounding sphere. Screen derivatives of
the reconstructed position supply format-independent opaque normals for local
emitter spill. The source ring uses eight fixed angular lobes, while rare short
height-band interruptions keep the projection from looking perfectly static.
The ordinary effect pixel shader adds matching lower-edge illumination to the
hologram content. No GShader binary is vendored, and the pass simply remains
inactive when GShader reconstruction is unavailable.

`holotable_contactdepth2_vs2x` / `holotable_contactradiance_ps2x` is the cheaper
contact-specific material pair. It
keeps team tint and source alpha while adding slice materialization, a bright
leading edge, scanlines, Fresnel separation, and restrained dropout. It also
samples the built-in full-frame depth texture's alpha channel for a soft
contact/map intersection frontier. A self-lit fill floor and the independent
`holo_table_effect_contact_brightness` control keep dark source textures from
making player/vehicle bodies too dim. `holotable_contacthalo_vs2x` /
`holotable_contactglow_ps2x` expands the
optimized contact geometry by a fixed screen-pixel width and draws only a soft
Fresnel shell. The shell uses straight alpha, applying its intensity only once
rather than multiplying both RGB and alpha. Previous contact pixel programs
remain as reference; the runtime wrappers use the names listed above.

`holotable_contactlight2_ps30.hlsl` is the optional GShader contact-light pass.
Each invocation reconstructs opaque world position, rejects empty/invalid depth
samples, and adds a normal-aware light pool beneath one contact. Lua selects at
most the configured number of contacts and scissors every invocation to that
contact's projected influence sphere.
