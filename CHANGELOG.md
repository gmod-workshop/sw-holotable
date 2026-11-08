# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Split the client map subsystem into ordered `map/cl_map_*.lua`
  fragments with shared internals on `ENT._Map`.
- Added clientside LVS tracer projection on the holo display.
- Shared world bake drawn with GPU cylinder clipping, replacing per-table CPU
  re-clipping (`holo_table_shader_clip`, now on by default).
- Tiered, lazily baked static-prop cells with a shared RAM budget
  (`holo_table_prop_bake_budget_mb`, `holo_table_prop_cells_status`).
- Texture atlas for the world, brush entities and zoomed-out props, with
  per-pixel mip selection and device-reset recovery (`holo_table_atlas`,
  `holo_table_atlas_status`). Cuts a zoomed-out gm_gmall_2 view from ~2,900
  to ~225 draw calls per table.

### Fixed

- Spawning a table on dense maps (e.g. gm_gmall_2) no longer freezes the game
  while static props bake.
- BSP fallback materials are named per texture, avoiding the engine's
  `CUtlSymbolTable` overflow crash after a few map changes.
- The radar loader no longer clobbers a map's global `RADAR` table.
- With effects on, opaque brush-entity meshes were drawn twice and
  translucent brush surfaces never.

### Documented

- Current map subsystem layout, spawn-time split fixes, and steady-state
  Lua allocation estimates.

## [0.1.0]

### Added

- Initial release

[Unreleased]: https://github.com/gmod-workshop/holo-table/compare/0.1.0...HEAD
[0.1.0]: https://github.com/gmod-workshop/holo-table/releases/tag/0.1.0
