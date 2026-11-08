# Holo Table Design Decisions

Notes on the non-obvious choices baked into `lua/entities/holo_table_3d/`,
including alternatives that were considered and rejected. Useful when
revisiting performance, visual quality, or architecture.

## File layout

**Decision:** Standard GMod entity-folder split, with the client side
further divided into per-subsystem files driven by entity-style
lifecycle hooks (`InitializeMap`, `ThinkRadar`, etc.) on `ENT`. This
keeps `cl_init.lua` as a thin coordinator and makes each subsystem
independently movable / replaceable.

- `lua/autorun/bsp2.lua` — NikNaks-backed adapter. The old vendored BSP
  parser has been removed, but this file preserves the narrow `bsp2`
  surface the holo table already consumes: `GetCurrent`,
  `GetModelInfo`, `bsp2_rebuild`, and `CurrentBSPReady`. It adapts
  NikNaks bmodels/faces/texinfo/static props into the existing table
  shape and creates per-texinfo `UnlitGeneric` fallback materials for
  lightmap-free holo rendering.
- `shared.lua` — `ENT.Type`/`Base`/metadata + `SetupDataTables`.
- `sh_power.lua` — server-side power audio lifecycle and sound cvars.
- `init.lua` — server spawn/model/physics setup, control lifecycle delegation,
  default view params, and `AddCSLuaFile` for every client component including
  loops over `effects/*.lua`, `map/*.lua`, and `radar/*.lua`.
- `cl_init.lua` — coordinator (~530 lines, including the benchmark harness).
  `Initialize` / `Think` / `OnRemove` delegate to per-subsystem
  hooks. `Draw` only calls `DrawModel` so `halo.Render`'s opaque
  silhouette pass works correctly; the holographic content is drawn
  from a self-installing `PostDrawTranslucentRenderables` hook into
  `ENT:DrawHologram`, which owns the stencil cylinder mask, the 5-plane
  GPU clip prism + floor plane, and the scene matrix push. It then calls
  into the subsystem draw entry points (`DrawMap`, `DrawClippedMap`,
  `DrawBrushEntities`, baked/fallback prop draw paths, `DrawRadar`).
- `cl_map.lua` — ordered include shim for the map subsystem.
- `cl_effects.lua` / `effects/*.lua` — optional visual-effect subsystem.
  Shared cvars/per-table constants and runtime material wrapping are kept out
  of the map implementation; see "Visual effects".
- `map/cl_map_*.lua` — map subsystem fragments. `cl_map_shared.lua`
  installs hot-reload cleanup and shared internals on `ENT.MapCache`;
  `cl_map_materials.lua`, `cl_map_prewarm.lua`,
  `cl_map_static_props.lua`, `cl_map_dynamic_props.lua`,
  `cl_map_clip.lua`, `cl_map_brushes.lua`, `cl_map_core.lua`, and
  `cl_map_tools.lua` own the clipper, brush-mesh cache, prop bounds /
  csent caches, static-prop and `prop_dynamic` map-dressing
  bakes/fallbacks, async build pipeline, per-frame draw entry points,
  auto-center solver, and `holo_table_profile`.
- `cl_radar.lua` — radar subsystem. Module loader, `RadarBase`
  (accessors that every per-entity instance inherits), and the four
  ENT lifecycle hooks (`InitializeRadar` / `ThinkRadar` /
  `DrawRadar` / `CleanupRadar`). See "Radar system".
- `radar/*.lua` — one file per tracked entity kind. Defines a
  `RADAR` table populated with any subset of `Initialize` / `Think` /
  `Draw` / `OnRemove`. Currently: `lvs.lua`, `other_vehicle.lua`,
  `player.lua`; `prop_dynamic` is not a radar module because map dressing is
  owned by `map/cl_map_dynamic_props.lua`. `player.lua` draws live
  player/weapon miniatures, with a clientside mirror for the local
  player. See "Radar system".
- `sh_controls.lua` — shared control layer: server ownership/net
  receivers plus client `+use`-toggled grab,
  per-frame input polling in `CreateMove`, `PlayerBindPress`
  suppression of conflicting binds, HUD overlay, throttled
  `setparams` send + immediate `setlayers` / `setpower` / `autocenter` /
  `focus_table` send, and the `holo_table_release` /
  `holo_table_autocenter` / `holo_table_focus_table` concommands.
  Its server branch owns `SIMPLE_USE`, controller/disconnect cleanup, and all
  seven control net messages. Incoming mutations are ownership-checked and
  clamped to the limits in `shared.lua`.
  See "Interactive controls".

**Decision:** Subsystem boundaries follow entity-style hook naming
(`InitializeMap` / `CleanupMap` / `DrawMap` etc.) rather than an
external module API (e.g. `holo_table.map.init(self)`). Reads as
idiomatic GMod and lets `cl_init.lua` stay declarative — every hook
call is a plain method on `self`. Sub-files attach their methods
straight onto `ENT` and add file-local helpers / caches for state
that doesn't need to live on the instance.

**Decision:** The main hologram render hook is lifecycle-gated.
`cl_init.lua` installs `holo_table_3d.DrawHologram` into
`PostDrawTranslucentRenderables` from `ENT:Initialize`, removes it after
the last table is gone, and self-removes defensively if a draw tick finds
no tables. This avoids scanning entities every frame on maps that do not
have a holo table. The active-table loop uses
`ipairs(ents.FindByClass('holo_table_3d'))`; the GMod wiki says
`FindByClass` is faster for single-class lookup, and local client
benchmarks matched that: with zero holo tables / 842 entities, 2000
calls were ~55.8 ms via `FindByClass` versus ~117.5 ms via
`ents.Iterator()` + `GetClass()`. On a busy class (`beam`, 275 ents),
`FindByClass` was still faster (~71.1 ms vs ~119.5 ms).

**Decision:** The map subsystem is split by responsibility, but it is not
loaded dynamically. `cl_map.lua` explicitly includes the fragments in
dependency order: shared → materials → prewarm → static props →
dynamic props → clip → brushes → core → tools. Shared cross-fragment
state lives on `ENT.MapCache` (`MapCache` locals inside the fragments), while
entity-facing behavior remains on `ENT`. This gives normal GMod
auto-refresh, useful stack traces, and a clear place for shared
internals without reintroducing a 2600-line file or a custom
`file.Read`/`CompileString` loader.

## Clipping volume

**Decision:** 32-sided software cylinder (Sutherland–Hodgman) for the
worldspawn mesh; 5-sided GPU clip prism + floor plane for live / fallback
content (brush entities, legacy prop fallbacks, ghosts, players). Baked
static props and baked `prop_dynamic` dressing draw as BSP-space IMeshes
inside the existing holo scene matrix.

**Rejected: GPU clip planes only for worldspawn.** The hardware budget is
6 planes, which forces a pentagonal footprint and visible flat sides at
zoom. The cylinder also needs full vertical extent — using two planes for
top/bottom of the cylinder would crop tall geometry.

**Rejected: Software cylinder for brush entities.** Brush models can
rotate (`func_door_rotating`, etc.), so each unique entity orientation
would need its own clipped mesh. That defeats the per-bmodel mesh cache.
Instead brush entities ride inside the existing GPU prism block, so
oversized geometry like hangar doors gets cropped at the rim. Cost is
visible flat sides on doors that span the rim.

**Decision:** Static BSP props default to a global baked renderer. A
shared, scale-specific IMesh cache is drawn inside the holo scene matrix
and clipped by the existing 5-plane GPU prism + floor plane. The original
V1 only used this bake for all-in views and fell back to per-prop
`ClientsideModel` draws for tight/partial views, but zoomed Venator
profiling showed that fallback was the remaining major cost. The current
default (`holo_table_staticprop_bake_mode 3`) keeps the global bake active
for zoomed views too, on every map.

**Rejected: legacy renderer for dense partial views.** A
`holo_table_staticprop_partial_bake_max_props` limit (default 1500) briefly
routed dense maps' partial views to the legacy per-prop renderer to avoid
an all-map bake. On gm_mall2 that froze the game for minutes on spawn: the
legacy path synchronously loads every in-view model (`util.GetModelInfo` +
`ClientsideModel`) on its first frame and issues one `SetupBones` +
`DrawModel` per prop per frame, and those slow frames starve every
budgeted coroutine. An all-map bake costs memory once; the legacy path
costs frame time forever. The limit was removed.

**Decision:** While a static-prop bake is building, the baked path still
owns the layer. It draws the previous ready bake (kept in
`MapCache.staticPropBakePrev` across a rescale -- bake geometry is
BSP-space, so it is valid at any scale) or nothing, never the legacy
fallback. Props pop in when the first bake completes, matching the
`prop_dynamic` bake.

### Static prop cells

**Decision:** Static props (modes 1/3) are baked as tiered, lazily built,
memory-budgeted cells shared by every table (`map/cl_map_prop_cells.lua`).

- **Fixed zoom tiers** (scale 0-4, 4-16, 16-64, 64+). Each tier has fixed
  bake parameters derived from its finest scale: model LOD, sub-pixel prop
  cutoff, vertex-clustering grid and cell size. Zooming inside a tier never
  rebuilds anything; tables at different scales share tiers.
- **Cells, baked on demand.** A one-time per-map index assigns props to
  grid cells per tier (cell edge = half the view diameter at the tier's
  coarsest scale; the 64+ tier is a single cell). A table requests only the
  cells its cylinder touches; one background worker bakes them through the
  shared background slot. While a table's tier is incomplete it draws the
  nearest fully baked tier (coarser first).
- **Vertex clustering.** Clustered tiers snap model-local positions to a
  ~1 px grid for the tier and drop collapsed triangles. Most custom props on
  dense maps have no LODs; on gm_gmall_2 clustering keeps ~17% of the 64+
  tier's vertices (10.6M -> 1.8M) and ~43% of the 16-64 tier's.
- **RAM budget.** Baked vertices cost ~72 bytes of process RAM each (the
  D3D9 driver keeps a system copy of static vertex buffers; freeing an
  8.8M-vertex bake released ~630 MB). Cells are evicted least-recently-drawn
  first above `holo_table_prop_bake_budget_mb` (default 256). The clustered
  model-mesh cache (~30 MB while baking) is dropped after 5 s idle.
  `holo_table_prop_cells_status` prints per-tier cells and memory.
- **Draw.** Visible cells are sphere-culled per table; the merged,
  material-sorted mesh list is cached per table and rebuilt only when the
  visible cell set or a cell's bake state changes. The 16-64 and 64+ tiers
  batch opaque materials by texture-atlas page (see "Texture atlas"),
  cutting a scale-150 view from ~1,600 prop draws to ~80.

Measured on gm_gmall_2: the zoomed-out tier bakes in ~12 s at ~125 MB
(the old scale-specific global bake: ~90 s, ~630 MB); zooming in to
scale 8 bakes 6 cells in under 3 s (+31 MB) instead of rebuilding a
13M-vertex bake (~930 MB); zooming back out redraws the cached tier with
no rebuild.

**Rejected: disk cache of baked vertices.** One tier of this map is
hundreds of MB of vertex data, and reading floats back through GMod's file
API is slower than rebuilding; model parsing is already cached by the
engine.

**Decision:** Background prewarm/bake coroutines share one round-robin
slot per frame instead of each spending its own ~6 ms budget.

**Trade-off:** The zoomed static-prop bake is clipped by the pentagonal
GPU prism rather than the 32-sided software cylinder. It measured far
faster than both legacy per-prop drawing and per-prop baked culling, but
visual edge cases should be checked on dense maps. If the prism edge is
not acceptable, the next design is material-grouped spatial chunks, not a
return to per-prop draws.

### Texture atlas

**Decision:** textures are packed into 2048x2048 render-target pages
(`map/cl_map_atlas.lua`; fixed RT/material names, up to 8 pages / 16 MB of
VRAM each), and the world bake, brush entities and the zoomed-out
static-prop tiers (scale >= 16) batch geometry by atlas page instead of by
texture. Each vertex carries its tile origin in a second texcoord and the
shader wraps the original UV inside the tile, so repeating UVs keep
repeating. Tiles are keyed by base texture. Additive materials, and
everything past the last page, keep per-texture meshes.
`holo_table_atlas` (default 1) toggles it.

Alpha and cull: a material's alpha class (opaque / alpha-tested /
translucent) varies per vertex: Lua adds `2 * class` to the tile origin's U
(always in [0, 1)) and the shaders decode it, clipping alpha-tested texels
at 0.5 and blending translucent ones. Cull mode and blending cannot vary
per vertex, so each page has four material variants (opaque or translucent,
single- or double-sided); a batch is one page + variant. Variant order puts
translucent batches after the opaque ones (which write depth), so glass
composites over what is behind it. The old per-texture order was arbitrary
material order, so a few overlapping translucent surfaces blend slightly
differently than before. Page fills use a `$translucent` UnlitGeneric (an
opaque one writes alpha ~0) with blending overridden to a straight copy.

Close-up prop tiers (scale < 16) stay per-texture: there a prop can cover
hundreds of pixels and a 64 px tile would visibly blur it, while those
views only issue ~20-200 prop draws anyway.

Tile layout and mipmaps: every tile cell (104x68 px, 570 per page) stores
its texture at 64, 32, 16 and 8 px, each with 2 px of wrapped padding. Pages
have no hardware mips; the pixel shader picks the level from the screen
derivatives of the unwrapped UV and blends two levels (manual trilinear),
so `frac()` at repeat seams does not spike the level. That needs
`ddx`/`ddy` and `tex2Dlod`, hence Shader Model 3: `holotable_atlasclip_*30`
and `holotable_atlaseffect_*30` (generated from the effect shaders), sharing
`shaders/src/holotable_atlas_common.h`, which must match the Lua layout.
A tile is filled with one `DrawTexturedRectUV` per level through a shared
UnlitGeneric whose `$basetexture` is swapped per tile; UVs extended past
[0, 1] let the source texture's own wrap addressing fill the padding and its
own mips do the downsampling.

Readiness: tiles fill a few dozen per frame after a bake. A bake records
`atlasMark()` (tiles assigned so far) and draws once `atlasFilled(mark)`,
so adding prop tiles never hides an already-ready world. Prop cells and
brush meshes record the atlas setting they were baked with; one baked under
the other setting (e.g. in flight when the cvar changed) is dropped and
rebaked. The plain (non-effect) path stages the atlas shader's unbounded
clip constants once per batch (the commit is a hidden model draw), not per
brush entity.

Device resets (alt-tab from exclusive fullscreen, mode changes) wipe render
targets silently. Each page keeps a 32x32 sentinel block in its unused
right strip. On focus regain or a screen-size change, each page is shrunk
into a 64x64 probe with `render.CopyRenderTargetToTexture` and the sentinel
read back (~0.6 ms per page); lost pages refill from their first slot.

Measured on gm_gmall_2 (one table, idle bakes, 6 s averages; draws are the
table's IMesh draws per frame): ~2,000 tiles in 4 pages; world meshes
984 -> 16.

| effects | scale | atlas off | atlas on |
|---|---|---|---|
| on | 150 | 2,879 draws, 118 fps (8.51 ms) | 225 draws, 186 fps (5.37 ms) |
| on | 40 | 2,682 draws, 130 fps (7.70 ms) | 318 draws, 219 fps (4.56 ms) |
| on | 8 | 593 draws, 210 fps (4.77 ms) | 288 draws, 220 fps (4.55 ms) |
| off | 150 | 2,771 draws, 106 fps (9.40 ms) | 226 draws, 220 fps (4.54 ms) |

At scale 150 the remaining draws are ~83 static-prop meshes (atlas pages
split at 30k vertices, plus additive materials), ~61 brush entities (one
per entity), 63 prop_dynamic meshes and 16 world meshes. A brush bug found
while measuring is fixed too: the late translucent brush pass used the
opaque filter, so with effects on every opaque brush mesh drew twice and
translucent brush surfaces never drew (126 -> 61 brush draws; the
effects-on scale-150 draw count includes the fix, its fps was measured
before it).

Pitfalls found while building it:
- The atlas material needs `$vertexnormal 1`: without it
  `screenspace_general` does not upload the ambient-cube registers that
  carry the per-table clip constants, so clipped draws discard everything.
- Filling a page needs `render.PushRenderTarget(rt, 0, 0, 2048, 2048)`
  plus `cam.Start2D`/`cam.End2D`; the default viewport follows the screen
  size and silently clipped every tile beyond it.
- Reading a page back: `render.CapturePixels` always captures the whole
  target (~25 ms stall for a page, viewport or not), sampling the page
  through an UnlitGeneric material reads shifted texels, and
  `render.DrawTextureToScreenRect` maps its rectangle through the screen
  size. Copying the page into a small target first is what works.
- The plain (non-effect) prop path draws atlas items through the atlas
  shader with unbounded clip constants staged; the table's clip planes and
  stencil still bound them. Atlas items sort last so this is one switch.
- Render targets keep their contents across map loads; tile layouts are
  rebuilt per generation and pages are cleared on first use.

Open: prop_dynamic bakes are not atlas-aware (~65 draws at any scale; the
bake is shared by all zoom levels, where close-ups need full-resolution
textures); animated textures freeze on the frame captured at fill time.

### World bake

**Decision:** The worldspawn is baked once per map into GPU meshes that do
not depend on scale, pan or height, shared by every table
(`map/cl_map_world.lua`), and partial views are trimmed by the exact
cylinder/floor clip shader (`holotable_clip`, or the effect shader with
`exactClip` when `holo_table_effects` is on). `holo_table_shader_clip`
(default 1) enables it; with it off, or after a shader/material failure,
tables fall back to the CPU clip builder (`ENT:BuildClippedMap`).

- Two mesh sets: one mesh per material for the whole world, and a
  1024-unit grid of cells (one mesh per material per cell). Each frame a
  table draws the visible cells when that is fewer draw calls than the
  whole set. On gm_gmall_2: 290k verts per set (~20 MB each), 984 / 2,818
  meshes, ~23 materials per cell; a scale-8 view draws ~135 meshes.
- All-in views use the plain draw (a four-table benchmark found custom
  material dispatch slower when no clipping is needed).
- The world bake runs in its own 4 ms lane rather than the shared
  background slot, and no longer blocks prop baking (the CPU clip coroutine
  used to gate every background job).
- The clip shader's third plane is an upper cap; the world is open at the
  top like the CPU clipper, so the runtime passes an effectively infinite
  cap. A table-height cap discarded nearly the whole hologram.

Measured on gm_gmall_2: world ready ~3.4 s after spawn (vs ~35 s for the
first CPU clip; the session already had the map's materials loaded), zooming
and panning never rebuild the world, and at scale 8 the GPU path ran within
~4% of the CPU clip (161 vs 168 fps; the CPU clip draws ~22 meshes).
Sources and build notes live under `shaders/src/`; compiled `.vcs` files
live under `shaders/fxc/`.

## Visual effects

**Decision:** Stylized hologram rendering is a separate, default-off client
subsystem. `cl_effects.lua` loads state/constants and material wrapping from
`effects/`; the map renderer only asks that subsystem for a replacement
material. This keeps experimental presentation code out of the clipper and
gives future effect backends—plain Source shaders or optional GShader—a clear
boundary.

The first prototype applies to the cached worldspawn mesh and baked static /
stable `prop_dynamic` IMeshes. Its Shader Model 2.0b pass combines tint,
retained source texture, thin scanlines, a broad scrolling scan band, height
contours, view-angle rim light, procedural noise, short horizontal glitches,
and adjustable opacity. Per-style values use `holo_table_effect_*` client
cvars; per-table clip volume, axis, tint, time, and spacing are uploaded once
per draw through vertex constants. Runtime materials are cached by source
texture/alpha class and updated only when a style cvar changes.

**Decision:** Custom wrappers bind the source `ITexture` after material
creation. BSP adapter texture names are not necessarily paths that
`CreateMaterial` can load directly, even though their existing runtime
texture handles are valid. Creating against `models/debug/debugwhite` and
then calling `SetTexture` avoids false error materials. The same correction
is used by the GPU clip prototype.

**Decision:** Effect draws preserve the source material's coverage class.
Opaque and alpha-tested surfaces continue writing depth; source-translucent
surfaces test depth but do not write it. This is essential for live brush
glass and shields because radar models and other hologram layers draw later.
Forcing writable depth across the entire effect batch would turn translucent
brushes into invisible occlusion walls. Additive source materials also retain
additive blending instead of becoming dense alpha-blended sheets; additive is
part of the runtime material-cache key so hot reload cannot reuse an older
wrapper with the wrong blend state. Effect-enabled brush entities are split
by coverage class: opaque / alpha-tested batches draw with other map geometry,
then translucent / additive batches composite after player and vehicle radar
models. The late pass makes their ordering explicit instead of relying solely
on Source's depth override behavior for a custom shader.

**Scope:** Worldspawn, baked map props, and live BSP brush-entity IMeshes use
the shared effect draw layer. `holo_table_effect_props 0` and
`holo_table_effect_brushes 0` can leave either group on ordinary materials
while the master effect remains active. Moving and legacy client-model prop
fallbacks use cached per-submaterial wrappers with `$model` and
`$softwareskin`, so bake eligibility no longer changes their visual style.
Radar contact styling is the separate tactical path below. A map material or
draw failure disables the relevant effect path for the session and falls back
to ordinary materials.

**Decision:** Radar contacts share a tactical presentation layer from
`effects/cl_effects_contacts.lua`. Full-detail player, weapon, and LVS mirrors
are drawn once through the same filled scanline/rim/noise/glitch shader as the
map, with `$model` and `$softwareskin` enabled so animated models retain their
poses. Per-submaterial wrappers preserve each model's diffuse texture and alpha
class; team color is supplied through the existing per-draw shader constants.
Projected contacts also get a table-oriented ground ring, vertical locator
beam, glow cap, acquisition ping, and optional close-view label. LVS and other
vehicle integrations retain bounded source-space position histories and draw
them as short fading trails. The player module uses
local/friendly/hostile/neutral colors, LVS derives the same distinction from
`AITEAM`, and marker-only vehicle integrations remain hostile red. The ring is
one shared 144-vertex IMesh transformed per contact, not 24 individual beam
draw calls. Non-shader contact additions hot-reload without restarting the
game. Contact styling follows the master effect toggle and has independent
model, marker, trail, ping, and label controls.

**Decision:** Table-wide atmosphere is a GShader-only, depth-aware projector
volume. `effects/cl_effects_volume.lua` submits a scissored screen pass after
GShader reconstructs opaque world position and before the table's translucent
hologram. Its Shader Model 3 pixel shader intersects each camera ray with a
bounded tapered volume, clamps the ray at opaque scene depth, and integrates
six fixed density samples. A narrow segmented source ring, soft cone edge,
restrained scan modulation, rare horizontal signal interruption, and slow
pulse all belong to the same volume, so no part is a camera-facing billboard.
The volume begins at `+27.8` and rises `58` units. `ProjectorRadius` is a
per-table editable NetworkVar (`60`–`100`, default `86`) shared by the opaque
emitter spill, volumetric source ring, and exact cone base. The frustum expands
to 122% of that radius at the top. Each visible table gets a conservative
screen-space scissor rectangle based on the current wider upper radius to bound
fill cost without clipping it. Radius changes therefore hot-update consistently
without recompiling a shader.

The volume height is fixed at `58` in both Lua and HLSL, freeing the final
material constant for `holo_table_effect_cone_softness`. That control widens
the radial density fade from roughly 5.5% to 32% of the cone radius and reduces
the bright boundary contribution as softness approaches one. It affects only
the suspended volume; emitter hotspots and opaque surface spill retain their
strength. Overall brightness remains under the atmosphere-strength control.

The same post pass derives opaque surface normals from world-position screen
derivatives and adds short-range light spill around the nearest point on the
emitter ring. This avoids depending on GShader's selectable normal-buffer
encoding. Eight fixed angular emitter lobes break up the otherwise perfect
ring without adding geometry. Separately, the ordinary hologram material adds
a narrow, pulse-synchronized lower-edge glow from `-5` through `+18` units
around the projection base. The three cues—physical spill, volume, and
hologram underlight—therefore share one apparent source despite rendering in
different passes.

There is intentionally no ordinary Source material fallback. Previous beam,
sprite, cylindrical shell, data-arc, column, and radar-sweep experiments all
read as obvious geometry or competed with the hologram. If GShader, its world
position target, or depth reconstruction is unavailable, this decorative
layer draws nothing. The map/material hologram remains independent and the
volume still follows the shared power reveal and atmosphere controls.

**Decision:** `Powered` is an authoritative per-entity Bool NetworkVar rather
than a client presentation cvar. Each table eases a reveal value over
`holo_table_effect_sequence_time`. The effect
shader combines height and stable spatial noise into a dissolve threshold and
adds a short bright materialization edge. CPU-side rings, labels, and trails,
plus the GShader volume, share the same reveal value, while a fully powered-off
table skips all hologram rendering and radar polling. The physical model
remains visible. `holo_table_effect_replay` restarts only the visual sequence.
Because Source caches compiled shader names, changes to the `.vcs` programs
require a game restart even though the Lua controls hot-reload.

**Decision:** Power audio is server-owned in `sh_power.lua`: a one-shot switch
sound, a one-shot shutdown sound, and a spatial `CSoundPatch` hum track the
same NetworkVar for all nearby players. `holo_table_sound` and
`holo_table_sound_volume` are archived replicated server cvars. Removal always
stops the patch, preventing orphaned looping sounds.

**Compatibility:** GShader HBAO must run before translucent content. Its own
`pp_hbao_translucent 1` setting moves HBAO from `PostBumpDraw` / the later
`PreDrawEffects` stage into `PostDrawReconstructionEffects`; the holotable's
`PostDrawTranslucentRenderables` output then cannot inherit AO belonging to
the opaque world behind it. The addon does not silently change this global
post-process preference.

## Build pipeline

**Decision:** Coroutine-based async builder with a ~4 ms per-frame budget
(`CLIP_FRAME_BUDGET`). Stale `ClippedMeshes` keep rendering until the new
build commits.

**Rejected: Synchronous rebuild on parameter change.** A full clip pass
on `rp_venator_extensive_v1_4` takes ~400–600 ms. Dragging the scale
slider would lock the client.

**Decision:** "All-in" invariance cache. When the cylinder fully contains
the worldspawn AABB (after pan), the clipped output is identical to any
other all-in scale/height. The first all-in build is cached on
`AllInMeshes` and swapped back in (~0.02 ms) on partial → all-in
transitions; same-config all-in edits short-circuit even earlier.

**Decision:** ~150 ms debounce on parameter changes before kicking off a
new build, except for the very first build (the entity has nothing to
display until the initial pass commits, so making the user wait would
look broken). Combined with a "don't preempt" policy — an in-flight
coroutine always finishes, even if its target params are already stale —
this keeps slider drags smooth without the cost of constantly
abandoning partial builds.

**Decision:** Worldspawn-only iteration (`bsp.models[1].faces`) in the
clipper. Brush-entity faces are stored in their entity's local frame and
would render at the BSP origin if included here.

**Decision:** Per-face triangulation cache on `face._holoTris`. Faces
that pass the trivial-accept test (fully inside the cylinder) only ever
need triangulating + UV-projecting once; the resulting per-vertex
`{pos, normal, u, v}` table list is invariant across scale/pan/height
and lives directly on the adapted face table for the rest of the map
load. The fast path is then "look up cache → `table.move` the tris into
the material group's vert list", with a one-shot `lastGroups`/`lastGroup`
ref to skip the per-face hash lookup. On
`rp_venator_extensive_v1_4` (~21 k faces, ~99.95 % fully-interior at
the auto-centered framing) this drops the clip phase from ~470 ms to
~100 ms steady-state.

**Decision:** `holo_table_profile` concommand runs `BuildClippedMap`
synchronously against the targeted (crosshair / nearest) holo table and
prints stage-by-stage timings (`clip` vs `imesh`), face counts
(`total / rejected / fast / clipped`), wall-plane stats
(`checked / skipped / cut`), and output (`tris / meshes`). The output
list is freed without touching the live build pipeline so profiling is
side-effect-free.

**Decision:** Static IMeshes are built through `mesh.Begin(msh,
MATERIAL_TRIANGLES, triCount)`, not `IMesh:BuildFromTriangles`. This is
centralized in `MapCache.buildMeshFromTriangles` so every map fragment
uses the same emitter and chunk-size assumptions. GMod wiki docs confirm
the `mesh.Begin(IMesh, primitiveType, primitiveCount)` form; local
profiling on the same table/map dropped warm `holo_table_profile` runs
from roughly 83-92 ms total (75-84 ms in the imesh phase) to roughly
30-32 ms total (21-22 ms imesh phase). Keep generated chunks below the
static mesh vertex limit documented for `mesh.Begin`.

**Decision:** Steady draw helpers reuse their Matrix/Vector scratch and pass
named emitters to `pcall`, rather than constructing draw closures and scene
objects each frame. In the final Venator probe, `DrawClippedMap` and
`DrawBakedDynamicProps` had no measurable Lua-heap allocation; remaining
all-in allocation was dominated by live brush-entity poses and static mesh
draw dispatch.

**Decision:** `cl_map.lua` owns an explicit hot-reload cleanup hook via
`_G.HOLO_TABLE_3D_CL_MAP_CLEANUP`. On file load it runs the previous
generation's cleanup before installing the new one, freeing shared
static/dynamic prop bakes, brush mesh caches, prewarm hooks, and cached
clientside draw entities. This keeps Lua auto-refresh from stranding
IMesh/csent resources during development without adding work to the
frame hot paths.

## Prop and brush-entity rendering

**Decision:** Static BSP props use a shared baked IMesh path. `cl_map.lua`
asynchronously builds a scale-specific mesh list from `bsp.props` using
`util.GetModelMeshes(model, 0, 0, skin)`. Vertices and normals are
transformed once into BSP space, grouped/chunked by material, and drawn
inside the existing holo matrix. The bake is scale-specific because the
legacy path already applies a sub-pixel cull based on current scale.
Toggle: `holo_table_staticprop_bake`.

**Decision:** Static prop bake mode is explicit. The cvar
`holo_table_staticprop_bake_mode` supports:
- `0` — legacy per-prop csent path.
- `1` — global bake only when the table is horizontally all-in.
- `2` — per-prop baked-cull experiment.
- `3` — default global bake clipped by the GPU prism, subject to the
  partial-view prop-count safety limit above.

Mode `3` is the measured fast path for zoomed views. In one Venator zoom,
legacy `DrawStaticProps` was ~2.86 ms/frame, per-prop baked culling was
~2.0 ms/frame because it still drew ~1,800 props / ~3,400 meshes, and
global GPU-clipped bake was ~0.085 ms/frame.

**Decision:** Prop-bake build buffers are packed numeric arrays containing
`px,py,pz,nx,ny,nz,u,v`, rather than one Lua table plus two Vectors per
vertex. The static build also sorts props by model/skin and retains only the
current model's `util.GetModelMeshes` result. On Venator, a complete
1,399,365-vertex scale-36 bake increased the Lua heap by about 211 MB while
building; the previous representation had already added about 573 MB at only
996k vertices. Bakes built for a smaller scale can serve larger-scale views,
because they contain at least the same sub-pixel-filtered props.

**Decision:** Shared static, per-prop, and dynamic bakes are destroyed after
the last holo table is removed. Per-entity stencil IMeshes are destroyed in
`ENT:OnRemove`. Shared bakes therefore do not retain hundreds of megabytes
after the feature is no longer in use.

**Decision:** Legacy static prop fallback stays. Disabled bake, mode `0`,
and rebuild windows still use per-prop `Entity:DrawModel` in world space,
with a file-level `ClientsideModel` cache keyed by model path. Bounds and
sub-pixel culling come from `util.GetModelInfo` so prewarm does not spawn
throwaway clientside entities.

**Rejected: `cam.PushModelMatrix` around `DrawModel`.** `Entity:DrawModel`
ignores the model matrix stack, so props would render at their raw BSP
positions (often far from the table). World-space `SetPos`/`SetAngles`
per prop is cheap and works.

**Decision:** `render.SuppressEngineLighting(true)` during the prop draw
loop / baked mesh draw. Static props use `VertexLitGeneric`, while the
adapter's worldspawn fallback materials are `UnlitGeneric` — without
suppression the props look noticeably darker than the surrounding mesh.

**Decision:** `prop_dynamic` map dressing belongs to the map subsystem,
not radar. Most map `prop_dynamic`s are static visual dressing, so
`cl_map.lua` owns an async baked IMesh path drawn inside the holo scene
matrix. The existing GPU clip prism crops that global bake in zoomed /
partial views, so stable props do not need per-prop `ClientsideModel`
mirrors just because the table is zoomed in. The per-table csent
fallback remains for disabled bake and individual moving props. While a
bake is queued/building, the baked path suppresses the stable-prop
fallback instead of spawning temporary mirrors. A 1-second watcher
compares
`EntIndex`, model, skin, position, and angles; added/removed/reskinned
stable props trigger an async rebuild while the previous bake keeps
drawing. Props observed moving/rotating are marked unbaked and drawn by
fallback instead of forcing a rebuild every watcher tick. Toggle:
`holo_table_dynamicprop_bake`.

**Decision:** Keep the dynamic-prop csent fallback allocation-light even
though it should be rare. The fallback uses the same scalar projection
math as `RadarBase:Project` and shared scratch `Vector` / `Angle` objects
instead of `LocalToWorld(ent:GetPos() * invScale, ent:GetAngles(), ...)`.
This reduced fallback allocation from roughly 56 KB/frame to roughly
22.6 KB/frame in a 144-mirror table-focus sample. The preferred path is
still the baked partial-view renderer, which reduced that same scene to
zero dynamic mirrors and kept `DrawDynamicProps` around 0.003 ms average.

**Rejected: leaving `prop_dynamic` in radar.** Profiling showed
the former `radar/prop_dynamic.lua:Draw` dominated the post-static-bake radar cost.
Conceptually these props are map dressing rather than tactical targets,
and baked IMeshes can draw inside the existing `m2` matrix while csent
`DrawModel` ghosts cannot.

**Decision:** Live `ent:GetPos()` / `ent:GetAngles()` once per rendered frame
for each brush entity, shared by every visible holo table through the common
brush record. `bmodel.origin` is the compile-time origin (often
`(0,0,0)`); using it would freeze doors at their closed position. Vertices
in `bmodel.faces` are stored in the entity's local frame, so the
per-entity matrix is just `T(GetPos()) * R(GetAngles())` composed on top
of the holo scene matrix via `cam.PushModelMatrix(m, true)`.

**Decision:** Per-bmodel mesh cache shared across all `holo_table_3d`
instances, cleared on the adapter's `CurrentBSPReady` hook. Brush models
are map-stable; multiple holo tables can reuse the same `IMesh`.

## Radar system

**Decision:** Tracked entities (LVS vehicles, other vehicle
frameworks, live players) are rendered
through a "radar" subsystem split across `cl_radar.lua` (registry +
base + ENT hooks) and one file per kind in
`lua/entities/holo_table_3d/radar/`. Each per-entity instance is
posed each frame to the source's live `(pos, ang)` mapped through the
hologram transform. Adding a new kind is just dropping a single file
in `radar/` — no edits to `cl_init.lua`, `cl_radar.lua`, or
`init.lua` are needed.

**Decision:** Module API. The loader walks
`entities/holo_table_3d/radar/*.lua`, sets `_G.RADAR` to a fresh
table whose metatable's `__index` chains to `RadarBase`, includes
the file, then registers the populated table. Each module defines
any subset of `RADAR:Initialize` / `RADAR:Think` / `RADAR:Draw` /
`RADAR:OnRemove`. Per-entity instances inherit
`mod -> RadarBase`, so a module's method body sees a `self` that has
the module's own state plus the base accessors:

- `self:GetEntity()` — the holo table entity
- `self:GetScale()` — the **inverse** scale (factor modules want when
  multiplying BSP-space positions). The forward direction is unused
  so far; if a module needs it, fetch via `self:GetEntity():GetScale()`.
- `self:GetOrigin()` / `self:GetAngles()` — the hologram's
  world-space frame, staged once per frame by `ENT:DrawRadar`.
- `self:Project(pos, ang)` — maps a BSP-space pose into the
  hologram's world-space slot. Only valid inside `RADAR:Draw`.

**Decision:** ENT lifecycle wiring. `ENT:InitializeRadar` builds one
instance per registered module on `self.Radars` (keyed by
`mod.Name`, defaulting to the file basename). `ENT:ThinkRadar` and
`ENT:CleanupRadar` iterate that table. `ENT:UpdateHologramTransform` stages
the shared BSP→world transform on `self._holo*` before drawing, so each
module can read it via the base accessors without recomputing.
`ThinkRadar` lazy-inits if `self.Radars` is missing so live-reloading
the file against an already-spawned entity doesn't crash.

**Decision:** Radar entries are CPU-culled against the table's BSP-space
cylinder before any mirror animation, bone setup, or model draw. The stencil
still provides the final crop, but it is no longer responsible for rejecting
entire off-view players and vehicles after their expensive work has already
run. In a Venator scale-36 view where the player was outside the selected
area, player radar fell from roughly 0.21 ms / 4 KB per pass to 0.011 ms /
0.09 KB. Visible-player bodygroup iteration also uses numeric IDs rather than
allocating `GetBodyGroups()` tables, and protected draw helpers no longer
allocate closures each pass.

**Decision:** Entity discovery that is identical for every table is shared.
The LVS and other-vehicle modules cache one source scan at the 15 Hz radar
rate; per-table LVS mirrors remain independently owned because their projected
poses differ. This prevents simultaneously spawned tables from repeating a
full `ents.Iterator()` walk on the same Think frame.

**Decision:** Radar fidelity is a client preference. The default
`holo_table_radar_lod 0` retains animated player/LVS models, mode `1` draws
small team-colored marker spheres (while preserving LVS tracers), and mode
`2` skips radar drawing. Marker mode is intended for scenes with several
simultaneously visible tables; the four-table Venator benchmark reduced
measured addon draw CPU from about 1.49 ms with full radar models to 0.91 ms.

**Decision:** Full-model LVS radar uses a hybrid authored/generated LOD path.
Mirrors force `holo_table_radar_model_lod 8` by default. A shared background
classifier reads that authored LOD once; models at or below the configurable
60,000-vertex threshold keep the normal animated model renderer. Denser models
are spatially vertex-clustered into a static, fully rotatable 3D IMesh near the
8,000-triangle target. Generated meshes are keyed by model checksum, bodygroup
mask, LOD, algorithm version, and quality settings, shared across every table,
and optionally persisted in `data/holo_table/radar_proxies`. The synchronous
`util.GetModelMeshes` extraction remains a one-time engine limitation; only one
model is extracted per frame and the Lua simplifier yields to a 3 ms budget.
Contacts use a small marker after a high-poly model has been identified and
until its proxy is ready. The proxy intentionally freezes animation in bind
pose; cheap authored LOD models retain animation.

`util.GetModelMeshes` returns the studio vertices before Source's model-space
axis conversion. Proxy generation therefore maps `(rawX, rawY, rawZ)` to
`(-rawY, rawX, rawZ)` and rotates normals identically before clustering. This
was verified against both Z-95 and Droid Tri-Fighter raw bounds versus their
entity OBBs. Omitting the conversion makes an otherwise correctly tracked proxy
face 90 degrees sideways.

**Decision:** Contacts use a dedicated alpha-composited Shader Model 2b material
rather than the full map pixel shader. Native models retain per-submaterial source
textures and coverage so alpha-tested windows/cards do not turn into opaque
planes; generated IMesh proxies use one texture-free instance. Both paths share
team tint, scan slices, a bright materialization frontier, Fresnel separation,
noise, and short signal dropout. `holo_table_effect_contact_full_shader 1`
still restores the full map shader for comparison.

An optional second draw uses `holotable_contacthalo` to expand optimized contact
geometry by a fixed screen-pixel width and shade only its Fresnel edge. This is
the sharp silhouette accent without a framebuffer blur. The duplicate geometry
is bounded by the existing authored-LOD/proxy
system and has independent width/strength controls.

The active contact pixel shader is `holotable_contactradiance`, paired with
the existing `holotable_contactdepth2` vertex shader. A raised emissive fill
floor prevents dark hull/uniform textures from dominating contact brightness;
`holo_table_effect_contact_brightness` scales emission without changing opacity.
The halo uses `holotable_contactglow` with straight-alpha RGB: its Fresnel
intensity belongs in alpha only, not both RGB and alpha, which previously
squared the low strength. It retains the existing single expanded-shell draw
and alpha compositing rather than stacking additive model faces.

`effects/cl_effects_glow.lua` adds a separately toggleable soft outer bloom.
Existing contact body draws mark stencil bit 128 only where their shader and
depth test accept fragments. The cylinder IDs use the remaining seven bits;
ordinary map/marker rendering keeps that mask read-only. At the end of a shared
stencil batch, one screen copy extracts the marked pixels, one blur spreads
their visible color, and an additive composite lights only pixels outside the
contact silhouettes. No contacts are submitted again and source-alpha/reveal
holes remain excluded. Unbatched rendering resolves bloom per table instead.
The 127-ID rollover resolves pending bloom before clearing stencil. All paths
restore the original image and stencil state, including a failed blur.

Proxy materials are now created lazily on their first draw. Their brightness
and opacity readback invalidate the Lua settings cache after an engine-side
material reset; a Lua version match alone previously left zeroed constants
untouched. Live neutral contacts were verified to upload the map tint
`102/159/255` rather than the local player's cyan marker color.

The contact vertex shader also carries clip-space position in unused varying
components. Immediately after the projected map writes depth and before radar
drawing, Lua optionally copies the current buffer into GMod's legacy full-frame
depth texture. The contact pixel shader samples its alpha channel, compares it
to the contact fragment depth, fades the visible side of close intersections,
and adds a narrow tint-colored frontier. The copy is independently toggleable
because it is a per-visible-table bandwidth cost; it does not depend on GShader.

Players use the same separated marker/body colors as LVS contacts. Non-LVS
vehicle sources now own clientside mirrors and share the authored-LOD/proxy
classifier, materialization envelope, contact shader, halo, markers, and labels
instead of always drawing a red marker sphere.
The local player's body also uses the live map tint; its ring follows the
neutral blue marker palette and the label identifies it as `LOCAL`.

LVS contacts have a lightweight materialization envelope layered over either
rendering path. During table startup they wait for the map reveal and enter in
a deterministic per-contact stagger; newly detected contacts use a short
acquisition fade. Early frames add restrained signal flicker, grow the model
from 80% scale, contract the locator ring, and extend its beam before labels
and trails become visible. The effect is Lua/material driven and adds no new
shader pass or duplicate model draw.
Generated IMesh proxies carry reveal and visibility through shader constants;
`render.SetBlend` does not affect the former additive IMesh path on tested
Source builds, even though it works for native studio-model contacts.
Movement trails and vertical locator beacons remain optional but default off;
the pulsing ground rings are the default contact accent.

**Decision:** Depth-aware contact lighting extends the existing GShader
reconstruction hook rather than installing one hook per vehicle. Contacts copy
their projected position, tint, radius, and reveal into a per-table list during
radar drawing. On the next reconstruction pass Lua selects up to four strongest
entries, scissors each draw to a small projected sphere, and reconstructs world
position/normals for a local additive light pool. Empty depth pixels are rejected
before reciprocal decoding so NaNs cannot fill the rectangular scissor region.

**Decision:** LVS tracer interception is reference-counted by live LVS radar
instances. `util.Effect` is wrapped when the first holo table initializes and
restored after the last instance is removed. The addon therefore pays no
global effect-wrapper cost while no holo table exists.

**Decision:** Module-owned tracking state. Each module decides how it
discovers source entities — `ents.FindByClass`, `ents.GetAll` filter,
`player.GetAll`, etc. — and stashes them on `self.Tracked` (or
whatever it wants). The base doesn't enforce a discovery model. csent
ghosts are created in `Initialize` / `Think` and torn down in
`OnRemove` (`SafeRemoveEntity`). The csents themselves get
`SetNoDraw(true)`, `SetSolid(SOLID_NONE)`, `MOVETYPE_NONE`, and
`PhysicsDestroy()` so they don't bump into geometry or play collision
sounds as we shove them around with `SetPos`.

**Current modules:**
- `lvs.lua` — LVS vehicles, csent mirrors with `SetPos` / `SetAngles`
  / `SetModelScale` synced per frame. Team-tinted `DrawModel` via a
  file-local `tintFor(tableTeam, entTeam)` → friendly/hostile/neutral
  `render.SetColorModulation`; neutral when either side is team 0.
  Also mirrors LVS bullet tracers on the holo by observing clientside
  `util.Effect` calls and validating them against live `LVS:GetBullet`
  entries.
- `other_vehicle.lua` — LFS / SW vehicles whose model coverage is
  patchy; just draws a red marker sphere at the mapped position via
  `self:Project(...)`.
- `player.lua` — live player/weapon miniatures. Remote players draw
  their real entity and active weapon at a temporary projected pose, then
  restore the source entity immediately. The local player uses a
  `ClientsideModel` mirror because first-person local-player drawing may
  be suppressed by the engine; its active weapon uses a separate mirror
  that is bone-merged/attached to the player mirror.
- `prop_dynamic` — deliberately absent from radar. Its map dressing lives in
  `map/cl_map_dynamic_props.lua` so it can use baked BSP-space meshes and
  share map fallback/bake lifecycle.

**Decision:** Local player animation is copied as solved bone matrices,
not as input guesses or animation layers. Polling `IN_ATTACK` /
`IN_RELOAD` would miss SWEP-specific animation events and hold-type
details; copying animation layers also does not work on the local mirror
because `Entity:SetLayerSequence` only applies to `BaseAnimatingOverlay`
entities, while `ClientsideModel` is not one. `player.lua` therefore
copies the final `LocalPlayer()` bone matrices into the projected mirror
after `SetupBones()`, including scaled bone translations and bone scale.
This preserves locomotion, weapon hold poses, firing gestures, and reload
animations. Toggle for debugging: `holo_table_player_anim_events`.

**Decision:** The local player bone-copy path uses cached bone IDs,
reusable matrices, and `Entity:CopyBoneMatrix` when available. The wiki
documents `CopyBoneMatrix` as the faster copy-into-provided-matrix form
of `GetBoneMatrix`; local comparison against the previous
`WorldToLocal`/`LocalToWorld` math matched within floating-point noise in
the sampled case. This keeps the high-fidelity local mirror while
dropping `RADAR:player:Draw` allocation from roughly 91.6 KB/frame to
about 4 KB/frame in the measured scene.

**Decision:** Player radar models use neutral model lighting instead of
map lighting. `Entity:DrawModel` in the projected holo position samples
the map's lighting there, so players can become nearly black on dark
maps. `player.lua` wraps the player/weapon radar draw in
`render.SuppressEngineLighting(true)` and `render.ResetModelLighting`.
Brightness is tunable with `holo_table_player_light` (default `1`).

**Rejected: drawing csent ghosts inside the `m2` /
`cam.PushModelMatrix` block.** `Entity:DrawModel` ignores the model
matrix stack, so ghosts would render at their raw world positions on
top of the live scene instead of inside the table. Same constraint
as static props. `ENT:DrawRadar` runs outside the `m2` block; modules
that draw csents apply the per-ghost world-space transform via
`SetPos` + `SetAngles` (computed through `self:Project`).
Marker-sphere drawers could run inside `m2` (since `render.DrawSphere`
respects the matrix) but currently also use `Project` for symmetry.

**Rejected: shared csent pool reused across source ents.** Calling
`SetPos` / `SetAngles` / `SetModelScale` / `SetupBones` between draws
of the same csent within a frame to ghost multiple source ents was
considered. `SetupBones` is the expensive bit and per-frame re-setup
would dominate. A dedicated csent per source ent costs a client-side
entity slot per ghost (cheap) and lets each csent's skin / bones
state be set once on creation.

**Rejected: returning a `radar` library table from `cl_radar.lua`.**
An earlier iteration exposed a `radar.Register` / `radar.Instance`
API and called it from a single ENT shim. The module file shape is
identical either way; the registry-as-table version was strictly more
ceremony for no extra capability. The hook-based version (modules
populate the registry as a side effect of being included) is the one
in tree.

**Decision:** LVS tracer detection is source-based, not effect-name
based. LVS and third-party LVS addons may use arbitrary tracer effect
names, so `radar/lvs.lua` wraps clientside `util.Effect`, reads the
effect data's material index, resolves it through `LVS:GetBullet(id)`,
and only records the tracer when the corresponding bullet originated
from an LVS entity and the bullet's `TracerName` matches the emitted
effect. The holo renders the result as short-lived projected beams in
the radar layer. This is intentionally clientside and opportunistic:
if an LVS weapon bypasses `util.Effect` or does not expose a bullet
entry, the table simply will not show that tracer.

**Profiling note:** In a scene with 12 active LVS ships,
`RADAR:lvs:Draw` measured about 0.082 ms average / 0.553 ms max, and the
`util.Effect` tracer wrapper averaged about 0.0385 ms per call. Large
35-68 ms real-frame drops persisted when `DrawHologram` was no-op'd and
when only the holo LVS radar was disabled, while measured holo-table work
on those slow frames was only a few milliseconds. Treat major LVS-heavy
FPS dips as likely LVS / game-side cost unless a future profile shows
the spike aligned with this addon's radar code.

## Scale pivot and pan

**Decision:** "Pinned-pivot" scaling — the table's BSP altitude (`pivotZ
= self:GetPos():Dot(self:GetUp())`) is the scale fixed point, so content
at that altitude appears at `table.z + height` regardless of scale.

**Rejected: Scaling around the BSP origin (0,0,0).** Increasing scale
visually slid the entire mesh upward (or downward, depending on the map's
relative origin), forcing the user to re-tune `height` after every scale
change.

**Decision:** Pan is a 2-component BSP-space offset (`PanX`, `PanY`) that
shifts the cylinder horizontally so the BSP point at `(panX, panY)`
appears at the table center. Cylinder wall planes get `d = radius +
panOffset:Dot(n)`, the floor plane is unchanged, and the scene matrix
subtracts the rotated pan term `(rotPan / scale)` from its translation.
The all-in containment check, prop cull, and brush-entity cull all
subtract the axis-perpendicular component of the pan from each test
position before measuring distance.

**Decision:** `holo_table_autocenter` concommand fits the worldspawn
AABB inside the cylinder: scale is `ceil(half-diagonal * 1.05 / 90)`,
pan is the AABB XY centroid, and height is solved so the BSP floor
lands ~1 unit above the table top. The result is networked to the
server which writes it back to the four view-parameter NetworkVars. New tables
use the same shared calculation at server spawn time with
`game.GetWorld():GetModelBounds()`, so Fit Map is their initial view without a
client request. The engine bounds match the parsed BSP bounds with a harmless
one-unit padding.

## Interactive controls

**Decision:** `sh_controls.lua` is a shared control module rather than
mixed into `init.lua` / `cl_init.lua`. Server-side ownership and net
receivers live in the `SERVER` branch; client input/HUD/concommands live
after the early server return. The control layer's only handles into the
rest of the entity are NetworkVar accessors, the
`ent.ComputeAutoCenter` method, and the control net messages.
`sh_controls.lua` is `include`d at the top of `cl_init.lua` before
`cl_map.lua` (which includes `map/cl_map_tools.lua`, where
`ENT:ComputeAutoCenter` lives), but references the method only from callbacks
that fire after all files load.

**Decision:** Toggle-on-`+use` grab. Pressing E on a holo table
makes the activator the controller; pressing again releases.
Pressing E on a *different* table while controlling the first
releases the first and grabs the second. Other players are locked
out for the duration.

`Shift+E` is the direct physical power switch and does not enter control mode.
While controlling, raw `H` toggles the same per-table state through the
ownership-checked `holo_table_setpower` message. The editable `Powered`
property and `holo_table_power [0/1]` command provide non-interactive paths.

**Rejected: Hold-to-grab.** Considered making control active only
while `+use` is held (like a SWEP secondary). Loses the WASD pan
because the player's `+use` hand can't simultaneously hold E and
move; also forces a timer to debounce the first release frame. The
toggle model is unambiguous and lets the user release by walking
away (`OnRemove` / `PlayerDisconnected`) without any keypress.

**Decision:** `ENT:SetUseType(SIMPLE_USE)` in `Initialize`. The
`base_anim` default is continuous-while-held, which fires `Use` every
tick the player holds E and produced a flicker between grab and
release as the toggle bounced. `SIMPLE_USE` fires exactly once per
press edge.

**Decision:** Server is the source of truth for ownership and the
final NetworkVar values. Client writes to NetworkVars optimistically
on every input event so the table reacts the same frame; the
server's snapshot replays the ordinary control input
(`holo_table_setparams`) after clamping / ownership checks within
~RTT. `holo_table_setparams` is throttled to ~30 Hz
(`SEND_INTERVAL = 0.033`) when `dirty`; `holo_table_setlayers`,
`holo_table_autocenter`, `holo_table_focus_table`, and
`holo_table_setpower` ship
immediately on the edge. `autocenter` and `focus_table` still use
client-computed params, but the server clamps them and rejects attempts
to change a table controlled by another player.

**Rejected: Server-authoritative input (write only on snapshot
arrival).** Adds RTT/2 of input lag to every pan/scroll, which is
visible at 30+ ms even on a listen server.

**Decision:** Movement is read off the cmd's button bits via
`cmd:KeyDown(IN_FORWARD/IN_BACK/IN_MOVELEFT/IN_MOVERIGHT)` and
`IN_SPEED` for the zoom modifier. This respects the player's
`+forward`/`+moveleft`/`+speed` binds (ESDF, arrow keys, etc.)
without us having to chase rebinds. The HUD displays the bound keys
via `input.LookupBinding`.

**Decision:** `+reload` is polled raw via
`input.IsKeyDown(input.GetKeyCode(input.LookupBinding('+reload')))`
rather than `cmd:KeyDown(IN_RELOAD)`. The control layer has to
suppress the `+reload` bind in `PlayerBindPress` to silence the
held-weapon reload animation/sound, and that suppression *also*
prevents the engine from setting the `IN_RELOAD` cmd bit (because
the `+reload` concommand never executes). Polling the raw key
sidesteps the loop.

**Decision:** `+duck` (default Ctrl) is the precision modifier
(`PRECISION_MUL = 0.25` for pan speed and height step;
`1 + (SCALE_FACTOR - 1) * mul` for the multiplicative scale step).
Captured into a local *before* `cmd:RemoveKey(IN_DUCK)` scrubs the
bit. Without that order, the modifier would always read false.

**Decision:** Layer toggles (T = entities, G = map) are raw-keyed
(`input.IsKeyDown(KEY_T/KEY_G)`) with edge detection. There is no
`+entities` or `+map` concommand to bind-poll, and inventing one
would require maintaining custom binds the user is unlikely to
discover. T/G also conflict with the default `messagemode`
(team chat) and `+menu_context` (sandbox tool menu) binds, which we
swallow in `PlayerBindPress` while the controller is active. Trade-
off: a player who has rebound T/G to other binds gets nothing useful
from the toggles. Acceptable — these are tertiary actions and the
HUD labels them explicitly.

**Decision:** `cmd:SetMouseWheel(0)` *and* swallow `invnext` /
`invprev` / `lastinv` in `PlayerBindPress`. The bind layer fires
before `CreateMove` sees the cmd, so zeroing the wheel alone still
let the weapon-selection HUD pop up and play its click sound on
every scroll tick.

**Decision:** `findControlTarget` (in `sh_controls.lua`) prefers
the actively-controlled table, then the entity under the crosshair,
then the nearest holo table. Used by both the
`holo_table_autocenter` concommand and the `+reload` hotkey. A
separate `findAutoCenterTarget` lives next to `holo_table_profile`
in `cl_map.lua` (crosshair → nearest, no controlled-table
preference); the duplication is ~12 lines and keeps the dev tool
decoupled from the control module. The author has flagged
`holo_table_profile` as eventually-removable debug code, so
consolidation is deliberately deferred.

**Decision:** Table-focus is a close tactical snap, not another map fit.
While controlling a table, `+speed`+`+reload` calls
`holo_table_focus_table`; the concommand is also available directly. It
sets scale `8`, pan to the physical table entity's world `x/y`, and
height `28`. The table model itself is not drawn in the holo, but this
frames nearby players around the table without repeated manual zooming,
and the slightly elevated height keeps the surrounding floor visible.

**Decision:** Cleanup paths are explicit: `ENT:ReleaseController`
clears `self.Controller` and notifies the client; `ENT:OnRemove`
calls it; `PlayerDisconnected` walks every holo table and releases
any owned by the leaver. Stale controllers would otherwise wedge
a table forever.

## BSP Adapter

**Decision:** Depend on NikNaks for BSP parsing and keep a local `bsp2`
compatibility adapter. The old vendored parser has been stripped out,
but `cl_map.lua` still talks to `bsp2.GetCurrent()` and
`bsp2.GetModelInfo()` because that surface is small and stable. The
adapter lives in `lua/autorun/bsp2.lua`, `require`s `niknaks`, maps
NikNaks bmodel `0` to `models[1]` (worldspawn), bmodels `1..N` to
`models[2..]`, adapts face edges/planes/texinfo into the old shape,
and exposes static props as `{model, origin, angles, skin}`.

**Decision:** Preserve `CurrentBSPReady` and `bsp2_rebuild`. Existing
holo-table cache invalidation is already wired to `CurrentBSPReady`
(brush mesh cache, material lookup identity, prewarm paths), so the
adapter keeps that event instead of introducing a NikNaks-specific
hook into every subsystem. `bsp2_rebuild` clears the adapter's current
map state and rebuilds the material list, which is useful while testing
parser/material changes in a live client.

**Trade-off:** The adapter is intentionally not a general replacement
for the removed parser. It only implements the parts this addon uses:
world/brush faces, model bounds/origins, static props, texinfo
projection data, and per-texinfo fallback materials. New BSP features
should either extend this narrow adapter deliberately or call NikNaks
directly from a clearly isolated subsystem.

## Material handling

**Decision:** Hybrid — adapter-generated `UnlitGeneric` materials for
faces whose original shader was `LightmappedGeneric` (which would render
black without a lightmap), original VMTs otherwise. Resolved once per
texinfo and cached in `cl_map.lua`.

**Decision:** Group draws by `$basetexture` name, falling back to
material name, so faces sharing a texture collapse into one render batch.

**Decision:** The adapter's `UnlitGeneric` fallback materials are shared
per basetexture and named `holo_bsp2_<CRC(texture)>`; consumers read the
fallback from `tinfo._holoBsp2Material`. They used to be created per
texinfo and named by the texinfo table's address. CreateMaterial names go
into a process-wide engine symbol table (16-bit, 65535 entries) that
survives map changes, so on gm_gmall_2 (14,911 texinfos) every map load
added ~15k new names and a few map changes in one session crashed with
`CUtlRBTree<CUtlSymbolTable::CStringPoolIndex> overflow`. Any runtime
material, texture or render-target name must be stable across loads
(derive it from content, e.g. a CRC), never from table addresses or time.

**Decision:** Cache the `mi.materials → matByTexinfo` lookup table at
file scope, keyed by the `mi.materials` table identity. The lookup
itself is just a `mat:GetName()` loop, but on big maps that list is
huge (rp_venator: 5934 entries) and the loop costs ~230 ms — paid on
every `BuildClippedMap` call before this was hoisted. Reusing the
cache across builds drops worldspawn clip time on Venator from
~245 ms to ~10 ms (24x). Auto-invalidates whenever the adapter swaps
the materials list, no explicit hook required.

**Decision:** `loadTexdataMaterial(name)` strips a stray leading `/`
from BSP texdata paths and re-`Material()`s. Some maps (rp_finalizer)
ship with paths like `/FIRSTORDERBANNER`; `Material()` returns the
error material on those, the resulting `error` basetexture lands in
the filter set, and the affected faces silently disappear from the
holo. The strip-and-retry is in the per-texinfo resolve so the cost
is paid at most once per material per map load.

**Decision:** `unlitWrap(src, translucent, alphaTest)` builds a runtime
`UnlitGeneric` mat keyed on `src`'s `$basetexture` name plus the alpha
mode flags (`holo_table_unlit_<crc>`). It is used when the adapter
fallback for a `LightmappedGeneric` texinfo carries an `error` /
`color/white` basetexture, and when the source material is translucent
or alpha-tested and the fallback would otherwise drop those flags.
Without this, corrected `LightmappedGeneric` materials render black in
the holo (no lightmap available), and alpha-bearing textures such as
glass, fences, grates, and foliage can become opaque.

**Decision:** `resolveMat` for `LightmappedGeneric` faces prefers the
adapter's per-texinfo `UnlitGeneric` fallback, but inspects its
`$basetexture` first — if it's in the filter set, fall back to
`unlitWrap` of the corrected `Material()` result. It also reads the
source material flags (`MATFLAG_TRANSLUCENT`, `MATFLAG_ALPHATEST`) and
requests a matching wrapper variant when needed. This combination
recovers banner / flag / dressing faces that previously rendered as the
error texture (and were filtered out entirely) and preserves common
alpha-material behavior. Same logic applied in `GetBrushModelMeshes`.

**Rejected: double-sided dressing via duplicate reversed-winding
geometry.** Map-dressing faces (banners, flags) recovered by
`unlitWrap` are sometimes embedded in walls so the BSP-defined side
points *away* from the holo camera, leaving them invisible. Tried
emitting a reversed-winding duplicate of every face that resolved to
an `unlitWrap` mat (tracked via a `holoDoubleSidedMat` set) so both
sides would render without `$nocull`'s mirrored-overlay artifact on
single-quad dressing. Two failure modes:
1. Many "thin brush" flags already have a coplanar back face in the
   BSP. The duplicate sat on top of it and z-fought into a flickering
   split appearance regardless of camera angle.
2. Pushing the duplicate by `+normal * 0.1` to dodge the back face
   z-fight (`HOLO_DUP_OFFSET`) instead caused subtle translucency
   artifacts across unrelated parts of the map mesh — likely the
   offset duplicate combined with the cylinder stencil and the
   `$vertexalpha` enabled on the wrap mat producing partial-alpha
   pixels. Removing the offset brought back the original z-fight.

The flags that motivated the experiment turned out to be inside
enclosed ship interiors and would not have been visible from outside
in the live world either — their absence in the holo is correct.
**Outcome:** all double-sided code reverted (`holoDoubleSidedMat`,
`HOLO_DUP_OFFSET`, the duplicate-emission blocks in `BuildClippedMap`
fast and slow paths, and in `GetBrushModelMeshes`). `unlitWrap`
itself is kept — it's still needed for these mats to render at all
from their primary side. Don't reintroduce the doubling without a
real per-face "is the back face already in the BSP?" check.

## Culling

**Decision:** Per-face bounding-sphere pre-cull, cached on the adapted
face table itself (`face._holoCull = {cx, cy, cz, fr}`). Survives
rebuilds within the same map load; recomputed only when the adapter
rebuilds those face tables. Stored as scalars rather than a `Vector` so
the per-face hot loop can run pure number math.

**Decision:** Skip the wall-clip pass when a face's bounding sphere is
fully inside the cylinder (`horizDist + fr <= radius`); same for the
floor plane. Saves ~32 plane clips per fully-interior face. The
trivial-accept feeds directly into the per-face triangulation cache
(see "Build pipeline").

**Decision:** Per-wall-plane sphere skip inside the slow path. After
the per-face sphere is projected into the (right, fwd) basis once
(`cR = c·right, cF = c·fwd`), each wall normal's signed distance is
just `cR*cos + cF*sin` and any plane whose half-space already contains
the sphere is skipped before invoking the Sutherland–Hodgman pass.
Typically only 2–4 of the 32 walls actually cut a given boundary face.

**Decision:** Sutherland–Hodgman trivial-accept (Common Halfspace) and
trivial-reject — when every input vertex is inside, return the input
list unchanged; when every vertex is outside, return a shared empty
table. Distance scan is hoisted out of the clip pass into a single
shared scratch table (`clipDistScratch`) so the clip loop can read the
pre-computed distances directly. This makes interior faces in the
slow path effectively free and cuts the allocation rate on faces that
genuinely cross.

**Decision:** Scalarised per-face cull math. The basis vectors
(`axis`, `right`, `fwd`) and pan offset are unpacked into `x/y/z`
locals once per build, so the per-face along/horiz tests run as bare
multiplies and adds — no temporary `Vector`s, no `:Dot` calls, no
per-face `:Length()` (squared distance is compared against
squared radii). On a 21 k-face map this eliminates ~100 k temporary
Vector allocations per build.

**Decision:** For brush entities, sphere cull on `(maxs - mins).Length()
* 0.5` around `entPos`. Cheap and conservative; the GPU prism handles the
exact crop.

**Decision:** For static props, per-prop bounding sphere derived from
`util.GetModelInfo(model).HullMin/HullMax`, cached in a file-level table.
Sphere center is rotated into world space for non-axis-aligned props
before the cylinder/floor test. A clientside draw entity is created only
when the legacy fallback actually needs to draw that model.

**Decision:** For baked static props and baked `prop_dynamic`, sub-pixel
filtering is applied before building IMeshes so bakes preserve the legacy
renderer's "don't draw tiny dressing" behaviour. Static-prop bakes record
their build scale and can be reused at larger scales; `prop_dynamic` bakes
are signature-specific and rebuilt
when the watcher sees added/removed/reskinned stable entities. Moving
`prop_dynamic`s stay on the fallback path.

## Multi-table render controls

**Decision:** Visible holo tables share a stencil session by default. With
`holo_table_stencil_batch 1`, the global draw hook clears once, assigns each
table a unique 8-bit stencil reference, and clears once after the final table.
Reference values wrap safely after 255 tables. Setting the cvar to `0` restores
the old per-table clears for visual diagnosis.

**Decision:** `holo_table_benchmark [seconds]` is the frame-level A/B harness.
It runs six phases (legacy stencil/full radar, batched stencil, marker radar,
experimental clip shader, stylized shader, and hologram rendering off), gives
each a one-second
warm-up, prints frame percentiles plus measured addon draw CPU, and restores
the caller's render/stencil/radar/shader/effect cvars on completion or cancellation.
The shader phase also reports how many tables actually used the partial-view
shader so an all-in no-op is not mistaken for a shader measurement.

## Lua allocation profile

**Current estimate:** One visible spawned table on the current test map
allocates roughly **21 KB/frame** on the Lua heap in steady state after
static and dynamic prop bakes are ready. A GC-paused wrapper probe over
240 frames measured total client Lua allocation at ~33.8 KB/frame, with
the holo table draw hook accounting for ~21.0 KB/frame.

Breakdown from that probe:
- `DrawBrushEntities` — ~15.5 KB/frame.
- `DrawBakedDynamicProps` — ~2.9 KB/frame.
- `UpdateHologramTransform` — ~1.2 KB/frame.
- `DrawClippedMap`, `DrawMap`, and `DrawRadar` — each under
  ~0.4 KB/frame.
- `DrawBakedStaticProps` — ~0.05 KB/frame.

**Decision:** Treat these as directionally useful profiling numbers, not
portable constants. They depend on the map, number of visible tables,
which bakes are ready, and what other addons are doing. The important
shape is stable: steady allocation is now dominated by live brush-entity
drawing, not static props, radar, or worldspawn. Build phases allocate
much more transient memory because they create vertex buffers and IMeshes;
that is a separate budget from frame steady state.

## Known limitations / deferred work

- **Translucent draw ordering.** Translucent / alpha-tested flags are
  now preserved on generated `UnlitGeneric` wrappers, so the old opaque
  black glass / grate issue is no longer the main failure mode. The
  build still emits a single material-batched mesh list, so blended
  surfaces may need a second `ClippedMeshes`-style list drawn after
  opaque geometry, probably with per-camera depth sorting.
- **3D skybox.** `sky_camera` lookup is plumbed but no skybox rendering
  is implemented. Maps without a 3D skybox (like the Venator) are
  unaffected.
- **Map-dressing visible from non-BSP side.** `unlitWrap`-ed banner
  and flag faces are single-sided and invisible from the side the
  BSP face normal points away from. The duplicate-reversed-winding
  experiment (see "Rejected: double-sided dressing") didn't pan out;
  a real fix needs per-face detection of whether the BSP already
  contains a coplanar opposing face before deciding to emit a
  duplicate. Low priority — most affected dressing is occluded by
  surrounding interior geometry anyway.
- **Brush-entity cost.** Static props and `prop_dynamic` map dressing
  now have baked GPU-clipped paths, so brush entities are often the next
  meaningful steady-frame cost. Recent allocation profiling showed
  `DrawBrushEntities` at ~15.5 KB/frame on a map with 118 brush-model
  entities. Cross-table pose caching removes that repeated allocation for
  the second and later tables in a frame, but each table still performs its
  own cull and draw submission. A future pass
  could identify stable brush entities (`func_brush`, stable
  `C_BaseToggle`, etc.) and bake those while leaving doors/trains/
  rotating entities live.
- **Semi all-in cache.** When the cylinder is *almost* all-in (a
  handful of faces cross the boundary), every parameter change still
  triggers a full rebuild. A split where static interior geometry is
  kept as a permanent IMesh and only boundary faces are re-clipped
  per parameter change would let "near all-in" zoomed-in views run at
  cache-hit speed. Not implemented yet; only worth doing if the
  per-face cache + scalar math doesn't get rebuild times low enough
  for tight-fit framings to feel instant.
- **Brush-entity flash on first frame.** The unclipped adapter fallback
  in `DrawMap` is mostly vestigial now because `bsp2.GetModelInfo()`
  exposes no prebuilt world meshes. If that fallback grows again, make
  sure it draws worldspawn only; brush-entity faces stacked at the BSP
  origin would otherwise flash for the few frames before the first
  clipped build commits.
- **Chunked baked-prop visibility.** When static prop mode `3` is below its
  partial-view safety limit, it draws whole material chunks and relies on the
  GPU clip prism in zoomed views. This is currently much faster than legacy
  or per-prop baked culling, but if the prism edge causes visible static props to
  poke beyond the intended cylinder, material-grouped spatial chunks or
  leaf grouping are the next design. Per-prop baked culling was measured
  and rejected for dense maps because draw-call count stayed too high.
- **Transformed AABB cull for brush entities.** Sphere cull is generous
  on long thin doors. A rotated AABB cull would reject a few more
  off-screen draws, but draw cost isn't currently measurable.
- **Stale `face._holoCull` / `face._holoTris` shape.** The cache shape
  has changed (e.g. cull went from `{vec, fr}` to `{cx, cy, cz, fr}`)
  and a defensive `not cull.cx` check rebuilds entries from a previous
  session's format. Once the format is stable across a release, the
  shape check can drop in favour of a simple version stamp.
