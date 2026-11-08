# Star Wars: Holo Table

A proof of concept holo table for displaying entity positions and other information on the map.

## Installation

Clone this repository into a folder in your addons folder.

## Dependencies

- [Venator Model Pack](https://steamcommunity.com/sharedfiles/filedetails/?id=1251088550) by King Pommes
- [NikNaks](https://github.com/Nak2/NikNaks) by Nak

Optional:

- [GShader Library](https://steamcommunity.com/sharedfiles/filedetails/?id=3542644649)
  by Akabenko: enables the projector volume and contact lighting effects
  (see below). Everything else works without it.

The compiled shaders the table uses ship with the addon in `shaders/fxc/`;
nothing else needs installing.

## Table controls

New tables start powered on and already fitted to the current map. Press `E`
to enter or leave interactive control mode. Press `H` while controlling the
table, or look at it and press `Shift+E`, to toggle its power. Power is also an
editable per-table property. The console command `holo_table_power` toggles the
controlled, aimed-at, or nearest table; pass `0` or `1` to set it explicitly.

- `holo_table_sound 0/1` — server-side master switch for startup, shutdown,
  and spatial ambient-hum sounds (default `1`).
- `holo_table_sound_volume 0..1` — server-side master sound volume (default
  `0.35`).
- `holo_table_effect_sequence_time 0..5` — startup/shutdown visual transition
  duration (default `1.1` seconds). `holo_table_effect_replay` replays startup
  without changing the table's authoritative power state.

## Performance and effect controls

- `holo_table_stencil_batch 0/1` — batch stencil clears across visible tables
  (default `1`).
- `holo_table_radar_lod 0/1/2` — full radar models, cheap markers, or radar
  disabled (default `0`).
- `holo_table_radar_model_lod 0..8` — authored LOD forced on vehicle mirrors
  (default `8`, the lowest available authored detail).
- `holo_table_radar_model_proxy 0/1` — automatically replace a vehicle whose
  lowest authored LOD is still excessively dense with a cached, rotatable 3D
  proxy (default `1`). `holo_table_radar_proxy_vertex_threshold` controls the
  trigger (default `60000` vertices) and `holo_table_radar_proxy_triangles`
  controls the generated target (default `8000` triangles). Results are shared
  by all tables and persisted under the client `data/holo_table/radar_proxies`
  folder when `holo_table_radar_proxy_disk_cache 1`.
- `holo_table_shader_clip 0/1` — clip the shared world bake to the table on
  the GPU instead of rebuilding clipped geometry on the CPU (default `1`).
- `holo_table_atlas 0/1` — draw the world, brush entities and zoomed-out static
  props from texture atlas pages, cutting thousands of draw calls to a few
  hundred on dense maps (default `1`; uses up to 128 MB of VRAM, 64 MB on
  gm_gmall_2). `holo_table_atlas_status` prints its usage.
- `holo_table_prop_bake_budget_mb` — approximate RAM budget for baked
  static-prop cells shared by all tables (default `256`); least recently drawn
  cells are freed above it. `holo_table_prop_cells_status` prints usage.
- `holo_table_effects 0/1` — experimental map and baked-prop hologram styling
  (tint, scanlines, scan band, contours, rim light, noise, glitch, and
  opacity; default `0`). Individual `holo_table_effect_*` cvars tune it.
- `holo_table_effect_props 0/1` — include baked static and stable dynamic
  props in the stylized effect (default `1`).
- `holo_table_effect_brushes 0/1` — include live BSP brush entities such as
  doors and lifts in the stylized effect (default `1`).
- `holo_table_effect_contacts 0/1` — add tactical styling to radar contacts:
  filled team-colored scanline/rim materials, pulsing ground rings, locator
  beams, and glow caps (default `1` when the master effect is enabled).
- `holo_table_effect_contact_models 0/1` and
  `holo_table_effect_contact_markers 0/1` — independently toggle contact
  model overlays or pulsing ground rings. `holo_table_effect_contact_beacons`
  optionally restores the vertical locator lines and glow caps (default `0`).
  `holo_table_effect_contact_opacity`
  and `holo_table_effect_contact_speed` tune their presentation.
- `holo_table_effect_contact_brightness` — self-lit body brightness for the
  lightweight player/vehicle shader (default `1.2`). This is independent of
  opacity and halo strength; dark source textures retain detail without making
  contacts disappear. Neutral bodies, including the local player, use the map
  tint. The local-player ring also follows the map's blue marker palette.
- `holo_table_effect_contact_materialize_time` controls the fade/flicker time
  for newly detected ships (default `0.42` seconds), while
  `holo_table_effect_contact_stagger` controls how widely contacts are spread
  across the latter half of the table startup animation (default `0.28`).
- `holo_table_effect_contact_full_shader 0/1` — opt back into the expensive
  full map shader for native contact models. The default `0` uses the dedicated
  contact shader with scan slices, Fresnel edges, signal breakup, and a bright
  materialization frontier. Generated vehicle proxies use the same shader.
- `holo_table_effect_contact_halo 0/1` — draw the contact silhouette a second
  time with a screen-space-stable soft edge. `*_halo_width` controls pixel width
  and `*_halo_strength` controls brightness.
- `holo_table_effect_contact_bloom 0/1` — blur visible contact pixels into a
  soft outer glow (default `1`). `*_bloom_strength` controls intensity (default
  `0.55`) and `*_bloom_blur` controls spread (default `4`). This adds screen-copy
  and blur work, but no additional model draws, and does not require GShader.
- `holo_table_effect_contact_occlusion 0/1` — soften contact/map depth
  intersections and add a narrow emissive edge on the visible side. The
  `*_occlusion_softness` and `*_intersection_strength` cvars tune its width and
  brightness. This uses GMod's built-in depth copy and does not require GShader.
- `holo_table_effect_contact_lighting 0/1` — let contacts illuminate nearby
  opaque surfaces through GShader. `*_lighting_strength` controls intensity and
  `*_lighting_max` caps the number of scissored light pools per table (default
  `4`). The effect is omitted when GShader depth reconstruction is unavailable.
- `holo_table_effect_contact_trails 0/1`,
  `holo_table_effect_contact_pings 0/1`, and
  `holo_table_effect_contact_labels 0/1` — independently toggle vehicle
  movement histories, new-contact acquisition rings, and close-view tactical
  labels. Their duration/zoom thresholds have matching `*_time` and
  `*_scale` cvars. Trails default to `0` to keep the display visually clean.
- `holo_table_effect_atmosphere 0/1` — add a depth-aware volumetric projector
  glow when GShader is installed and its reconstruction pass is enabled.
  `holo_table_effect_atmosphere_strength` controls intensity and
  `holo_table_effect_sweep_speed` adjusts its pulse rate.
  `holo_table_effect_cone_softness 0..1` controls whether the cone boundary is
  defined or broadly hazy (default `0.72`). There is no billboard fallback when
  GShader is unavailable. The pass includes segmented emitter hotspots and
  normal-aware light spill over nearby opaque table surfaces.
  Each table also exposes a `Projector Radius` slider in its editable
  Properties (`60`–`100`, default `86`); it moves the emitter ring and cone
  base together without recompiling or restarting.
- `holo_table_render 0/1` — disable/enable hologram content for profiling.
- `holo_table_benchmark 5` — run six A/B phases with a five-second sample per
  phase; the command restores the previous cvar values when it finishes.

When using GShader's HBAO addon, set `pp_hbao_translucent 1`. This runs its AO
pass before translucent holograms instead of multiplying world shadows over
the completed holotable image.

The projector volume and contact lighting require GShader with `r_shaderlib 1`
and `r_shaderlib_depthbuffer 1`. The map/material hologram and contact
intersection edge remain available without GShader; only the decorative volume
and reconstructed light pools are omitted.

After replacing a compiled file in `shaders/fxc/`, restart Garry's Mod before
judging that shader change; Source caches a shader name for the process.
