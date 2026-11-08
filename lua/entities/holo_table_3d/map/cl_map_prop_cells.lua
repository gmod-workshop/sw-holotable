-- Static-prop cells: tiered, lazily baked, memory-budgeted static-prop
-- meshes shared by every holo table. See DESIGN.md "Static prop cells".
--
-- Each zoom tier has fixed bake parameters (LOD, sub-pixel cull, vertex
-- clustering grid, cell size), so zooming inside a tier never rebuilds.
-- Props are indexed into per-tier grid cells once per map; a cell is baked
-- only when some table sees it, and cells are evicted least-recently-drawn
-- first once the total exceeds holo_table_prop_bake_budget_mb.

local MapCache = ENT.MapCache
local HoloEffects = ENT.HoloEffects
local SysTime = SysTime
local FrameNumber = FrameNumber
local math_floor = math.floor
local math_sqrt = math.sqrt
local math_max = math.max
local table_sort = table.sort
local coroutine_create = coroutine.create
local coroutine_yield = coroutine.yield
local coroutine_resume = coroutine.resume
local hook_Add = hook.Add
local hook_Remove = hook.Remove
local render_SetMaterial = render.SetMaterial
local CACHE_GENERATION = MapCache.CACHE_GENERATION
local PROP_SUBPIXEL_THRESHOLD = MapCache.PROP_SUBPIXEL_THRESHOLD
local getPropBounds = MapCache.getPropBounds
local staticPropBakeMaterial = MapCache.staticPropBakeMaterial
local buildMeshFromFlatTriangles = MapCache.buildMeshFromFlatTriangles

local WORKER_HOOK = 'holo_table_3d.static_prop_cells'
local FRAME_BUDGET = 0.006
-- IMeshes take up to 65532 verts (16-bit indices); 30000 keeps one
-- unyieldable mesh.Begin under ~15 ms.
local MAX_VERTS_PER_MESH = 30000
local PER_VERT_SEC = 0.5e-6
-- Measured on gm_gmall_2: freeing an 8.8M-vertex bake released ~630 MB of
-- process private memory (the D3D9 driver keeps a system-RAM copy of
-- static vertex buffers), i.e. ~72 bytes per baked vertex.
local BYTES_PER_VERT = 72
-- Approximate holo units per screen pixel at normal table viewing distance;
-- sets the clustering grid so collapsed detail is sub-pixel.
local HOLO_UNITS_PER_PIXEL = 0.16
-- Cells a table stops requesting are dropped from the queue after this long.
local REQUEST_TTL = 1.0
-- Cache of clustered model-local meshes (flat numbers) so a model shared by
-- many cells is parsed once per tier. ~4M numbers is ~32 MB of Lua heap.
local MODEL_CACHE_MAX_VALUES = 4000000
-- Drop that cache after this many seconds without bake work.
local MODEL_CACHE_IDLE_RELEASE = 5

local budgetCvar = CreateClientConVar('holo_table_prop_bake_budget_mb', '256', true, false,
    'Approximate RAM budget (MB) for baked static-prop cells shared by all holo tables.')

-- Zoom tiers by table scale. `ref` is the tier's finest scale; parameters
-- derive from it so the tier is correct everywhere inside it. `atlas` tiers
-- batch textures by atlas page (map/cl_map_atlas.lua): zoomed out, a
-- view holds ~1,500 prop materials and draw calls dominate, while props are
-- small enough on screen that 64 px tiles lose nothing. Closer tiers keep
-- full-resolution per-texture draws (few of them anyway).
local TIERS = {
    { minScale = 0,  ref = 1,  lod = 0, cluster = false },
    { minScale = 4,  ref = 4,  lod = 2, cluster = true },
    { minScale = 16, ref = 16, lod = 8, cluster = true, atlas = true },
    -- One cell: at scale >= 64 a view covers most of the map, so culling
    -- buys little and extra cells only split materials into more draws.
    { minScale = 64, ref = 64, lod = 8, cluster = true, single = true, atlas = true },
}
-- Atlas page groups sort after every material so the plain draw path can
-- hand the tail to the atlas shader in one go.
local ATLAS_MATID_BASE = 1e9
for i, tier in ipairs(TIERS) do
    tier.index = i
    tier.minRadius = PROP_SUBPIXEL_THRESHOLD / (2 / tier.ref)
    tier.grid = tier.cluster and HOLO_UNITS_PER_PIXEL * tier.ref or nil
    -- Half the view diameter at the tier's coarsest scale (4 * ref): a
    -- table view overlaps a handful of cells anywhere in the tier.
    tier.cellSize = tier.cellSize or math_max(512, 360 * tier.ref)
end

--- @param scale number
--- @return table tier
local function tierForScale(scale)
    for i = #TIERS, 1, -1 do
        if scale >= TIERS[i].minScale then return TIERS[i] end
    end
    return TIERS[1]
end

local state = nil

local function budgetVerts()
    return math_max(0, budgetCvar:GetFloat()) * 1048576 / BYTES_PER_VERT
end

local function destroyCellMeshes(cell)
    if cell.meshes then MapCache.destroyMeshList(cell.meshes) end
    if cell.verts and state then state.totalVerts = state.totalVerts - cell.verts end
    cell.meshes = nil
    cell.verts = nil
    cell.state = nil
    if state then state.version = state.version + 1 end
end

--- Frees every baked cell, the index, and the worker.
function MapCache.destroyStaticPropBake()
    hook_Remove('Think', WORKER_HOOK)
    if not state then return end
    if state.index then
        for _, tierIndex in ipairs(state.index) do
            for _, cell in ipairs(tierIndex.cellList) do destroyCellMeshes(cell) end
        end
    end
    if state.buildingMeshes then MapCache.destroyMeshList(state.buildingMeshes) end
    state = nil
end

--- Builds the per-map prop index: per-prop world bounds/basis and, per tier,
--- the grid cells holding props above that tier's sub-pixel cutoff (props
--- sorted by model inside each cell). Runs inside the worker coroutine.
local function buildIndex(budgetYield)
    local bsp = bsp2 and bsp2.GetCurrent()
    local props = bsp and bsp.props or {}
    local P = { n = #props, model = {}, key = {}, skin = {},
        cx = {}, cy = {}, cz = {}, r = {}, ox = {}, oy = {}, oz = {}, basis = {} }

    for i = 1, #props do
        budgetYield()
        local prop = props[i]
        local model, origin = prop and prop.model, prop and prop.origin
        if not (model and origin) then continue end
        local bounds = getPropBounds(model)
        if bounds.radius <= 0 then continue end

        local fx, fy, fz, rx, ry, rz, ux, uy, uz = 1, 0, 0, 0, -1, 0, 0, 0, 1
        if prop.angles then
            local f, r, u = prop.angles:Forward(), prop.angles:Right(), prop.angles:Up()
            fx, fy, fz, rx, ry, rz, ux, uy, uz = f.x, f.y, f.z, r.x, r.y, r.z, u.x, u.y, u.z
        end
        local bc = bounds.center
        P.model[i] = model
        P.skin[i] = prop.skin or 0
        P.key[i] = model .. '|' .. (prop.skin or 0)
        P.ox[i], P.oy[i], P.oz[i] = origin.x, origin.y, origin.z
        P.basis[i] = { fx, fy, fz, rx, ry, rz, ux, uy, uz }
        P.cx[i] = origin.x + fx * bc.x - rx * bc.y + ux * bc.z
        P.cy[i] = origin.y + fy * bc.x - ry * bc.y + uy * bc.z
        P.cz[i] = origin.z + fz * bc.x - rz * bc.y + uz * bc.z
        P.r[i] = bounds.radius
    end

    local keys = P.key
    local function byModel(a, b)
        local ka, kb = keys[a], keys[b]
        if ka ~= kb then return ka < kb end
        return a < b
    end

    local index = {}
    for ti, tier in ipairs(TIERS) do
        local cells, cellList = {}, {}
        local cs = tier.cellSize
        for i = 1, P.n do
            budgetYield()
            local r = P.r[i]
            if not r or r < tier.minRadius then continue end
            local cx, cy, cz = P.cx[i], P.cy[i], P.cz[i]
            local key = tier.single and 'all' or (math_floor(cx / cs) .. ',' .. math_floor(cy / cs))
            local cell = cells[key]
            if not cell then
                cell = { tier = tier, key = key, props = {},
                    minX = cx - r, minY = cy - r, minZ = cz - r,
                    maxX = cx + r, maxY = cy + r, maxZ = cz + r }
                cells[key] = cell
                cellList[#cellList + 1] = cell
            end
            local list = cell.props
            list[#list + 1] = i
            if cx - r < cell.minX then cell.minX = cx - r end
            if cy - r < cell.minY then cell.minY = cy - r end
            if cz - r < cell.minZ then cell.minZ = cz - r end
            if cx + r > cell.maxX then cell.maxX = cx + r end
            if cy + r > cell.maxY then cell.maxY = cy + r end
            if cz + r > cell.maxZ then cell.maxZ = cz + r end
        end
        for _, cell in ipairs(cellList) do
            budgetYield()
            table_sort(cell.props, byModel)
            local hx = (cell.maxX - cell.minX) * 0.5
            local hy = (cell.maxY - cell.minY) * 0.5
            local hz = (cell.maxZ - cell.minZ) * 0.5
            cell.cx, cell.cy, cell.cz = cell.minX + hx, cell.minY + hy, cell.minZ + hz
            cell.radius = math_sqrt(hx * hx + hy * hy + hz * hz)
        end
        index[ti] = { tier = tier, cellList = cellList }
    end

    state.props = P
    state.index = index
    local counts = {}
    for ti, tierIndex in ipairs(index) do counts[ti] = #tierIndex.cellList end
    MsgC(Color(120, 200, 255), string.format(
        '[holo_table] Static prop cells indexed: props=%d cells per tier=%s budget=%dMB\n',
        P.n, table.concat(counts, '/'), budgetCvar:GetInt()))
end

--- Clustered, model-local mesh data for (model, skin, tier), cached FIFO.
--- Vertex clustering snaps positions to a ~1 px grid for the tier and drops
--- triangles that collapse: on gm_gmall_2 it keeps ~17% of the scale-64+
--- tier's vertices and ~43% of the 16-64 tier's.
local function getModelEntry(model, skin, tier, budgetYield)
    local cacheKey = model .. '|' .. skin .. '#' .. tier.index
    local cache = state.modelCache
    local entry = cache[cacheKey]
    if entry ~= nil then return entry end

    local meshes = util.GetModelMeshes(model, tier.lod, 0, skin)
    if not meshes then
        cache[cacheKey] = false
        return false
    end

    local grid = tier.grid
    local subs, values = {}, 0
    for _, meshData in ipairs(meshes) do
        local mat, matKey = staticPropBakeMaterial(meshData.material)
        local tris = meshData.triangles
        if not (mat and tris) then continue end
        local buf, o = {}, 0
        for t = 1, #tris - 2, 3 do
            if t % 3000 == 1 then budgetYield() end
            local a, b, c = tris[t], tris[t + 1], tris[t + 2]
            local ap, bp, cp = a.pos, b.pos, c.pos
            local ax, ay, az, bx, by, bz, cx, cy, cz =
                ap.x, ap.y, ap.z, bp.x, bp.y, bp.z, cp.x, cp.y, cp.z
            if grid then
                ax, ay, az = (math_floor(ax / grid) + 0.5) * grid, (math_floor(ay / grid) + 0.5) * grid, (math_floor(az / grid) + 0.5) * grid
                bx, by, bz = (math_floor(bx / grid) + 0.5) * grid, (math_floor(by / grid) + 0.5) * grid, (math_floor(bz / grid) + 0.5) * grid
                cx, cy, cz = (math_floor(cx / grid) + 0.5) * grid, (math_floor(cy / grid) + 0.5) * grid, (math_floor(cz / grid) + 0.5) * grid
                if (ax == bx and ay == by and az == bz) or (bx == cx and by == cy and bz == cz)
                    or (cx == ax and cy == ay and cz == az) then
                    continue
                end
            end
            local an, bn, cn = a.normal or vector_up, b.normal or vector_up, c.normal or vector_up
            buf[o + 1], buf[o + 2], buf[o + 3] = ax, ay, az
            buf[o + 4], buf[o + 5], buf[o + 6] = an.x, an.y, an.z
            buf[o + 7], buf[o + 8] = a.u or 0, a.v or 0
            buf[o + 9], buf[o + 10], buf[o + 11] = bx, by, bz
            buf[o + 12], buf[o + 13], buf[o + 14] = bn.x, bn.y, bn.z
            buf[o + 15], buf[o + 16] = b.u or 0, b.v or 0
            buf[o + 17], buf[o + 18], buf[o + 19] = cx, cy, cz
            buf[o + 20], buf[o + 21], buf[o + 22] = cn.x, cn.y, cn.z
            buf[o + 23], buf[o + 24] = c.u or 0, c.v or 0
            o = o + 24
        end
        if o > 0 then
            subs[#subs + 1] = { mat = mat, matKey = matKey, buf = buf, n = o }
            values = values + o
        end
    end

    entry = { subs = subs, values = values }
    cache[cacheKey] = entry
    local fifo = state.modelFifo
    fifo[#fifo + 1] = cacheKey
    state.modelValues = state.modelValues + values
    while state.modelValues > MODEL_CACHE_MAX_VALUES and #fifo > 1 do
        local old = table.remove(fifo, 1)
        local oldEntry = cache[old]
        if oldEntry then state.modelValues = state.modelValues - oldEntry.values end
        cache[old] = nil
    end
    return entry
end

local function matIdFor(mat)
    local ids = state.matIds
    local id = ids[mat]
    if not id then
        id = state.nextMatId
        state.nextMatId = id + 1
        ids[mat] = id
    end
    return id
end

--- Frees least-recently-drawn ready cells until the total fits the budget.
--- Cells drawn in the last two frames are kept even if over budget.
local function evictCells()
    local budget = budgetVerts()
    if state.totalVerts <= budget then return end
    local frame = FrameNumber()
    local candidates = {}
    for _, tierIndex in ipairs(state.index) do
        for _, cell in ipairs(tierIndex.cellList) do
            if cell.state == 'ready' and frame - (cell.lastUsed or 0) > 2 then
                candidates[#candidates + 1] = cell
            end
        end
    end
    table_sort(candidates, function(a, b) return (a.lastUsed or 0) < (b.lastUsed or 0) end)
    for _, cell in ipairs(candidates) do
        if state.totalVerts <= budget then break end
        destroyCellMeshes(cell)
    end
end

--- Bakes one cell: transforms each prop's clustered model mesh into BSP
--- space, groups by material, and emits IMeshes. Commits atomically.
local function bakeCell(cell, budgetYield)
    local tier = cell.tier
    local P = state.props
    local groups, groupList = {}, {}
    local meshes = {}
    local vertCount = 0
    local useAtlas = tier.atlas and MapCache.atlasEnabled()
    local atlasTileFor = MapCache.atlasTileFor
    state.buildingMeshes = meshes
    cell.state = 'building'

    local function flush(group)
        local n = #group.verts
        if n == 0 then return end
        local verts = n / group.stride
        if SysTime() + verts * PER_VERT_SEC > state.deadline then
            coroutine_yield()
            state.deadline = SysTime() + FRAME_BUDGET
        end
        local msh
        if group.atlas then
            msh = MapCache.buildAtlasMesh(group.verts, group.mat)
        else
            msh = buildMeshFromFlatTriangles(group.verts)
        end
        if msh then
            meshes[#meshes + 1] = { mat = group.mat, mesh = msh, matId = group.matId, atlas = group.atlas }
            vertCount = vertCount + verts
        end
        group.verts = {}
    end

    local lastKey, entry
    for _, i in ipairs(cell.props) do
        budgetYield()
        local key = P.key[i]
        if key ~= lastKey then
            lastKey = key
            entry = getModelEntry(P.model[i], P.skin[i], tier, budgetYield)
        end
        if not entry then continue end

        local B = P.basis[i]
        local fx, fy, fz, rx, ry, rz, ux, uy, uz = B[1], B[2], B[3], B[4], B[5], B[6], B[7], B[8], B[9]
        local ox, oy, oz = P.ox[i], P.oy[i], P.oz[i]
        for _, sub in ipairs(entry.subs) do
            local atlasGroup, tu, tv, pageMat
            if useAtlas then atlasGroup, tu, tv, pageMat = atlasTileFor(sub.mat) end
            local groupKey = atlasGroup and ('#atlas' .. atlasGroup) or sub.matKey
            local group = groups[groupKey]
            if not group then
                if atlasGroup then
                    -- Group ids order the variants (see map/cl_map_atlas.lua).
                    group = { mat = pageMat, matId = ATLAS_MATID_BASE + atlasGroup, verts = {},
                        atlas = true, stride = 10 }
                else
                    group = { mat = sub.mat, matId = matIdFor(sub.mat), verts = {}, stride = 8 }
                end
                groups[groupKey] = group
                groupList[#groupList + 1] = group
            end
            local stride = group.stride
            local src, out = sub.buf, group.verts
            local o = #out
            for s = 1, sub.n, 8 do
                local px, py, pz = src[s], src[s + 1], src[s + 2]
                local nx, ny, nz = src[s + 3], src[s + 4], src[s + 5]
                local wx = fx * nx - rx * ny + ux * nz
                local wy = fy * nx - ry * ny + uy * nz
                local wz = fz * nx - rz * ny + uz * nz
                local len2 = wx * wx + wy * wy + wz * wz
                if len2 > 0 then
                    local inv = 1 / math_sqrt(len2)
                    wx, wy, wz = wx * inv, wy * inv, wz * inv
                end
                out[o + 1] = ox + fx * px - rx * py + ux * pz
                out[o + 2] = oy + fy * px - ry * py + uy * pz
                out[o + 3] = oz + fz * px - rz * py + uz * pz
                out[o + 4], out[o + 5], out[o + 6] = wx, wy, wz
                out[o + 7], out[o + 8] = src[s + 6], src[s + 7]
                if atlasGroup then out[o + 9], out[o + 10] = tu, tv end
                o = o + stride
                -- Flush only on triangle boundaries.
                if o >= MAX_VERTS_PER_MESH * stride and (o / stride) % 3 == 0 then
                    flush(group)
                    out, o = group.verts, 0
                elseif s % 6144 == 1 then
                    budgetYield()
                end
            end
        end
    end
    for _, group in ipairs(groupList) do flush(group) end

    table_sort(meshes, function(a, b) return a.matId < b.matId end)
    state.buildingMeshes = nil
    -- Tiles assigned by this bake must be drawn into their pages first.
    cell.atlasMark = useAtlas and MapCache.atlasMark() or nil
    cell.bakedAtlas = useAtlas
    cell.meshes = meshes
    cell.verts = vertCount
    cell.state = 'ready'
    cell.lastUsed = FrameNumber()
    state.totalVerts = state.totalVerts + vertCount
    state.bakedCells = state.bakedCells + 1
    state.version = state.version + 1
    state.lastBakeTime = SysTime()
    evictCells()
end

--- Most recently requested cell that still needs baking, or nil.
local function pickRequest()
    local now = SysTime()
    local best, bestTime
    for cell, t in pairs(state.requests) do
        if now - t > REQUEST_TTL or cell.state then
            state.requests[cell] = nil
        elseif not bestTime or t > bestTime then
            best, bestTime = cell, t
        end
    end
    return best
end

local function workerMain()
    local function budgetYield()
        if SysTime() <= state.deadline then return end
        coroutine_yield()
        state.deadline = SysTime() + FRAME_BUDGET
    end
    state.deadline = SysTime() + FRAME_BUDGET
    buildIndex(budgetYield)
    while true do
        local cell = pickRequest()
        if cell then
            state.requests[cell] = nil
            state.buildingCell = cell
            bakeCell(cell, budgetYield)
            state.buildingCell = nil
        else
            coroutine_yield()
            state.deadline = SysTime() + FRAME_BUDGET
        end
    end
end

--- Ensures the shared cell system exists (index build + worker). The scale
--- argument is accepted for API compatibility; cells are tier-based.
function MapCache.startStaticPropBake()
    if not MapCache.staticPropBakeCvar:GetBool() then return end
    if state and state.gen == CACHE_GENERATION then return end
    local bsp = bsp2 and bsp2.GetCurrent()
    if not bsp or not bsp.props or #bsp.props == 0 then return end

    MapCache.destroyStaticPropBake()
    state = {
        gen = CACHE_GENERATION,
        requests = {},
        totalVerts = 0,
        bakedCells = 0,
        modelCache = {},
        modelFifo = {},
        modelValues = 0,
        matIds = setmetatable({}, { __mode = 'k' }),
        nextMatId = 1,
        version = 0,
        lastBakeTime = SysTime(),
    }
    state.co = coroutine_create(workerMain)

    hook_Add('Think', WORKER_HOOK, function()
        if not state or state.gen ~= CACHE_GENERATION then
            MapCache.destroyStaticPropBake()
            return
        end
        if state.index and not state.buildingCell and not next(state.requests) then
            local now = SysTime()
            if state.modelValues > 0 and now - state.lastBakeTime > MODEL_CACHE_IDLE_RELEASE then
                state.modelCache, state.modelFifo, state.modelValues = {}, {}, 0
            end
            -- Cells used only as a fallback while a tier baked can leave the
            -- cache over budget once nothing draws them; trim when idle too.
            if now - (state.lastEvictCheck or 0) > 1 then
                state.lastEvictCheck = now
                evictCells()
            end
            return
        end
        if MapCache.anyClipCoroutineActive() then return end
        if not MapCache.claimBackgroundSlot('static_cells') then return end

        local ok, err = coroutine_resume(state.co)
        if ok then return end
        ErrorNoHaltWithStack(err)
        -- Drop the failed cell's partial meshes, never retry it, and keep
        -- serving other cells with a fresh worker.
        if state.buildingMeshes then MapCache.destroyMeshList(state.buildingMeshes) end
        state.buildingMeshes = nil
        if state.buildingCell then state.buildingCell.state = 'failed' end
        state.buildingCell = nil
        if not state.index then
            MapCache.destroyStaticPropBake()
            return
        end
        state.co = coroutine_create(workerMain)
    end)
end

-- Per-frame scratch (shared across tables; each draw consumes it at once).
local VIS_SCRATCH, visCount = {}, 0

--- Baked, and any atlas tiles it uses are drawn into their pages.
local function cellDrawable(cell)
    return cell.state == 'ready' and (not cell.atlasMark or MapCache.atlasFilled(cell.atlasMark))
end

--- Baked for the other holo_table_atlas setting (e.g. a bake that was in
--- progress when it changed).
local function cellStale(cell)
    return cell.state == 'ready' and cell.tier.atlas and cell.bakedAtlas ~= MapCache.atlasEnabled()
end

--- Collects the cells of a tier whose bounding sphere touches the table's
--- cylinder into VIS_SCRATCH. Returns the count and whether all are ready.
local function collectVisible(tierIndex, selfTbl)
    local axisX, axisY, axisZ = selfTbl._holoAxis:Unpack()
    local panX, panY, panZ = selfTbl._holoPanHoriz:Unpack()
    local cylRadius = selfTbl._holoCylRadius
    local floorOffset = selfTbl._holoFloorOffset
    local n, allReady = 0, true
    local list = tierIndex.cellList
    for i = 1, #list do
        local cell = list[i]
        local cx, cy, cz, radius = cell.cx, cell.cy, cell.cz, cell.radius
        local along = cx * axisX + cy * axisY + cz * axisZ
        local hx = cx - axisX * along - panX
        local hy = cy - axisY * along - panY
        local hz = cz - axisZ * along - panZ
        local bound = cylRadius + radius
        if hx * hx + hy * hy + hz * hz > bound * bound then continue end
        if along + radius < floorOffset then continue end
        -- Dropped here so the request logic below rebakes it.
        if cellStale(cell) then destroyCellMeshes(cell) end
        n = n + 1
        VIS_SCRATCH[n] = cell
        if cell.state ~= 'failed' and not cellDrawable(cell) then allReady = false end
    end
    for i = n + 1, visCount do VIS_SCRATCH[i] = nil end
    visCount = n
    return n, allReady
end

local function byMatId(a, b) return a.matId < b.matId end

local function drawMeshList(meshes)
    local lastMat
    for i = 1, #meshes do
        local item = meshes[i]
        -- Atlas items sort last and need the atlas shader's constants.
        if item.atlas then
            if not MapCache.drawAtlasItemsUnclipped(meshes, i) then
                error('atlas constants upload failed')
            end
            return
        end
        local mat = item.mat
        if mat ~= lastMat then
            render_SetMaterial(mat)
            lastMat = mat
        end
        item.mesh:Draw()
    end
end

--- Draws the static-prop cells visible to one table, requesting any that
--- are missing. While the table's tier is incomplete it draws the nearest
--- tier (coarser first) whose visible cells are all baked, else whatever
--- of its own tier is ready. Always returns true (the layer is handled).
--- @param selfTbl table
--- @param scale number
--- @return boolean handled
function MapCache.drawPropCells(selfTbl, scale)
    if not state or state.gen ~= CACHE_GENERATION then
        MapCache.startStaticPropBake()
        if not state then return false end
    end
    if not state.index then return true end

    local tier = tierForScale(scale)
    local now = SysTime()
    local tierIndex = state.index[tier.index]
    local n, allReady = collectVisible(tierIndex, selfTbl)
    if not allReady then
        -- Mark the wanted tier's ready cells as in use even though the
        -- fallback is what gets drawn; otherwise each newly baked cell is
        -- evicted by the next bake under budget pressure and re-requested.
        local requests, frame = state.requests, FrameNumber()
        for i = 1, n do
            local cell = VIS_SCRATCH[i]
            if not cell.state then
                requests[cell] = now
            elseif cell.state == 'ready' then
                cell.lastUsed = frame
            end
        end
        -- Fallback: nearest tier whose visible cells are all baked.
        local chosen = false
        for d = 1, #TIERS - 1 do
            for _, ti in ipairs({ tier.index + d, tier.index - d }) do
                local other = state.index[ti]
                if other then
                    local on, oReady = collectVisible(other, selfTbl)
                    if oReady and on > 0 then
                        chosen = true
                        n = on
                        break
                    end
                end
            end
            if chosen then break end
        end
        if not chosen then n = collectVisible(tierIndex, selfTbl) end
    end

    local frame = FrameNumber()
    for i = 1, n do
        local cell = VIS_SCRATCH[i]
        if cell.state == 'ready' then cell.lastUsed = frame end
    end

    -- The merged, material-sorted draw list only changes when the visible
    -- cell set or any cell's bake state changes; rebuild it only then.
    local cache = selfTbl._holoPropCellDraw
    if not cache then
        cache = { cells = {}, n = -1, list = {} }
        selfTbl._holoPropCellDraw = cache
    end
    local fill = MapCache.atlasFillProgress()
    local same = cache.version == state.version and cache.n == n and cache.fill == fill
    if same then
        local cells = cache.cells
        for i = 1, n do
            if cells[i] ~= VIS_SCRATCH[i] then same = false break end
        end
    end
    if not same then
        local cells, list, m = cache.cells, cache.list, 0
        for i = 1, n do
            local cell = VIS_SCRATCH[i]
            cells[i] = cell
            if cellDrawable(cell) then
                local meshes = cell.meshes
                for j = 1, #meshes do
                    m = m + 1
                    list[m] = meshes[j]
                end
            end
        end
        for i = n + 1, #cells do cells[i] = nil end
        for i = m + 1, #list do list[i] = nil end
        table_sort(list, byMatId)
        cache.n = n
        cache.version = state.version
        cache.fill = fill
    end
    local drawList = cache.list
    if #drawList == 0 then return true end

    if HoloEffects.ArePropsEnabled() and HoloEffects.BeginDraw(selfTbl, true) then
        local effectOk, effectErr = pcall(HoloEffects.DrawMeshList, drawList)
        if HoloEffects.EndDraw(effectOk, effectErr) then return true end
    end

    render.SuppressEngineLighting(true)
    local ok, err = pcall(drawMeshList, drawList)
    render.SuppressEngineLighting(false)
    if not ok then
        ErrorNoHaltWithStack('[holo_table] static prop cells draw aborted: ' .. tostring(err))
        MapCache.destroyStaticPropBake()
    end
    return true
end

-- Atlas tiers bake differently with the atlas on or off: drop their cells
-- so they rebake on demand.
cvars.AddChangeCallback('holo_table_atlas', function()
    if not (state and state.index) then return end
    for ti, tierIndex in ipairs(state.index) do
        if TIERS[ti].atlas then
            for _, cell in ipairs(tierIndex.cellList) do
                if cell.state == 'ready' then destroyCellMeshes(cell) end
            end
        end
    end
end, 'holo_table_3d.prop_cells')

--- Debug status for the static-prop cell cache.
--- @return table?
function MapCache.propCellStats()
    if not state then return nil end
    local perTier = {}
    if state.index then
        for ti, tierIndex in ipairs(state.index) do
            local ready, verts = 0, 0
            for _, cell in ipairs(tierIndex.cellList) do
                if cell.state == 'ready' then
                    ready = ready + 1
                    verts = verts + (cell.verts or 0)
                end
            end
            perTier[ti] = { cells = #tierIndex.cellList, ready = ready, verts = verts }
        end
    end
    return {
        indexed = state.index ~= nil,
        totalVerts = state.totalVerts,
        approxMB = state.totalVerts * BYTES_PER_VERT / 1048576,
        budgetMB = budgetCvar:GetFloat(),
        modelCacheMB = state.modelValues * 8 / 1048576,
        bakedCells = state.bakedCells,
        pending = table.Count(state.requests),
        tiers = perTier,
    }
end

concommand.Add('holo_table_prop_cells_status', function()
    local s = MapCache.propCellStats()
    if not s then
        print('[holo_table] static prop cells: not started')
        return
    end
    print(string.format('[holo_table] static prop cells: indexed=%s verts=%d (~%.0f/%.0f MB) model cache ~%.0f MB baked=%d pending=%d',
        tostring(s.indexed), s.totalVerts, s.approxMB, s.budgetMB, s.modelCacheMB, s.bakedCells, s.pending))
    for ti, t in ipairs(s.tiers) do
        local tier = TIERS[ti]
        print(string.format('  tier %d (scale >= %d, lod %d, grid %s): cells %d, baked %d, verts %d',
            ti, tier.minScale, tier.lod, tier.grid and string.format('%.2f', tier.grid) or 'none', t.cells, t.ready, t.verts))
    end
end)
