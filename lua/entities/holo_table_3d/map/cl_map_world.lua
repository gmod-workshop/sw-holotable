-- World bake: the worldspawn baked once per map into GPU meshes that do not
-- depend on table scale, pan or height, shared by every holo table. Partial
-- views draw them through the exact cylinder/floor clip shader instead of
-- re-clipping geometry on the CPU. See DESIGN.md "World bake".
--
-- Two mesh sets: `all` (one mesh per material, for zoomed-out views) and
-- grid `cells` (one mesh per material per 1024-unit cell, for zoomed-in
-- views). Each frame a table draws whichever needs fewer draw calls.

local MapCache = ENT.MapCache
local SysTime = SysTime
local bit_band = bit.band
local math_floor = math.floor
local math_sqrt = math.sqrt
local table_sort = table.sort
local coroutine_create = coroutine.create
local coroutine_yield = coroutine.yield
local coroutine_resume = coroutine.resume
local coroutine_status = coroutine.status
local hook_Add = hook.Add
local hook_Remove = hook.Remove
local CACHE_GENERATION = MapCache.CACHE_GENERATION
local SURF_SKIP_MASK = MapCache.SURF_SKIP_MASK
local getMatByTexinfo = MapCache.getMatByTexinfo
local resolveMat = MapCache.resolveMat
local resolveProj = MapCache.resolveProj
local buildMeshFromFlatTriangles = MapCache.buildMeshFromFlatTriangles

local WORLD_HOOK = 'holo_table_3d.world_bake'
-- Own lane (not the shared background slot): the world is what a new table
-- shows first, so it should not wait turns behind prop work.
local FRAME_BUDGET = 0.004
-- On gm_gmall_2: 121 cells, ~23 materials each; a scale-8 view touches ~4.
local CELL_SIZE = 1024
local MAX_VERTS_PER_MESH = 30000
local PER_VERT_SEC = 0.5e-6

local world = nil

--- Frees the world bake and stops its worker.
function MapCache.destroyWorldBake()
    hook_Remove('Think', WORLD_HOOK)
    if not world then return end
    -- Every IMesh created by the bake is tracked in `owned`.
    MapCache.destroyMeshList(world.owned)
    world = nil
end

--- Appends one triangle (pos/normal/uv per corner) to a flat buffer.
local function writeTri(out, o, nx, ny, nz,
        ax, ay, az, ua, va, bx, by, bz, ub, vb, cx, cy, cz, uc, vc)
    out[o + 1], out[o + 2], out[o + 3] = ax, ay, az
    out[o + 4], out[o + 5], out[o + 6] = nx, ny, nz
    out[o + 7], out[o + 8] = ua, va
    out[o + 9], out[o + 10], out[o + 11] = bx, by, bz
    out[o + 12], out[o + 13], out[o + 14] = nx, ny, nz
    out[o + 15], out[o + 16] = ub, vb
    out[o + 17], out[o + 18], out[o + 19] = cx, cy, cz
    out[o + 20], out[o + 21], out[o + 22] = nx, ny, nz
    out[o + 23], out[o + 24] = uc, vc
end

--- Atlas variant of writeTri: stride 10, tile origin appended per vertex.
local function writeTriAtlas(out, o, tu, tv, nx, ny, nz,
        ax, ay, az, ua, va, bx, by, bz, ub, vb, cx, cy, cz, uc, vc)
    out[o + 1], out[o + 2], out[o + 3] = ax, ay, az
    out[o + 4], out[o + 5], out[o + 6] = nx, ny, nz
    out[o + 7], out[o + 8], out[o + 9], out[o + 10] = ua, va, tu, tv
    out[o + 11], out[o + 12], out[o + 13] = bx, by, bz
    out[o + 14], out[o + 15], out[o + 16] = nx, ny, nz
    out[o + 17], out[o + 18], out[o + 19], out[o + 20] = ub, vb, tu, tv
    out[o + 21], out[o + 22], out[o + 23] = cx, cy, cz
    out[o + 24], out[o + 25], out[o + 26] = nx, ny, nz
    out[o + 27], out[o + 28], out[o + 29], out[o + 30] = uc, vc, tu, tv
end

--- Whether the world should be baked into atlas pages right now.
local function wantAtlas()
    return MapCache.atlasCvar ~= nil and MapCache.atlasCvar:GetBool()
end

--- Worker body: triangulates every renderable worldspawn face (same rules
--- and winding as ENT:BuildClippedMap's fast path) into both mesh sets.
local function bakeWorld()
    local deadline = SysTime() + FRAME_BUDGET
    local function bump() deadline = SysTime() + FRAME_BUDGET end
    local function budgetYield()
        if SysTime() <= deadline then return end
        coroutine_yield()
        bump()
    end

    local matByTexinfo = getMatByTexinfo(function() return deadline end, bump) or {}
    local bsp = bsp2 and bsp2.GetCurrent()
    local faces = bsp and bsp.models and bsp.models[1] and bsp.models[1].faces or {}

    local owned = world.owned
    local matIds, nextMatId = {}, 1
    local allGroups, allGroupList, allMeshes = {}, {}, {}
    local cells, cellList = {}, {}

    local function flush(group, out)
        local n = #group.verts
        if n == 0 then return end
        local stride = group.atlas and 10 or 8
        if SysTime() + (n / stride) * PER_VERT_SEC > deadline then
            coroutine_yield()
            bump()
        end
        local msh
        if group.atlas then
            msh = MapCache.buildAtlasMesh(group.verts, group.mat)
        else
            msh = buildMeshFromFlatTriangles(group.verts)
        end
        if msh then
            local item = { mat = group.mat, mesh = msh, matId = group.matId, atlas = group.atlas }
            out[#out + 1] = item
            owned[#owned + 1] = item
            world.verts = world.verts + n / stride
        end
        group.verts = {}
    end

    local function groupIn(groups, list, key, mat, isAtlas, atlasGroup)
        local group = groups[key]
        if group then return group end
        -- Atlas batches sort after every per-texture material, translucent
        -- variants last (see map/cl_map_atlas.lua).
        local id = isAtlas and (1e9 + atlasGroup) or matIds[mat]
        if not id then
            id = nextMatId
            nextMatId = id + 1
            matIds[mat] = id
        end
        group = { mat = mat, matId = id, verts = {}, atlas = isAtlas }
        groups[key] = group
        list[#list + 1] = group
        return group
    end

    local function cellFor(cx, cy, cz, fr)
        local key = math_floor(cx / CELL_SIZE) .. ',' .. math_floor(cy / CELL_SIZE)
        local cell = cells[key]
        if not cell then
            cell = { groups = {}, groupList = {}, meshes = {},
                minX = cx - fr, minY = cy - fr, minZ = cz - fr,
                maxX = cx + fr, maxY = cy + fr, maxZ = cz + fr }
            cells[key] = cell
            cellList[#cellList + 1] = cell
            return cell
        end
        if cx - fr < cell.minX then cell.minX = cx - fr end
        if cy - fr < cell.minY then cell.minY = cy - fr end
        if cz - fr < cell.minZ then cell.minZ = cz - fr end
        if cx + fr > cell.maxX then cell.maxX = cx + fr end
        if cy + fr > cell.maxY then cell.maxY = cy + fr end
        if cz + fr > cell.maxZ then cell.maxZ = cz + fr end
        return cell
    end

    for fi = 1, #faces do
        budgetYield()
        local face = faces[fi]
        local tinfo = face.texinfo
        if not tinfo or bit_band(tinfo.flags or 0, SURF_SKIP_MASK) ~= 0 then continue end
        local edges = face.edges
        local n = edges and #edges or 0
        if n < 3 then continue end

        local mat, skip = resolveMat(tinfo, matByTexinfo)
        if skip then continue end
        local btn = mat:GetTexture('$basetexture')
        local matKey = btn and btn:GetName() or mat:GetName()

        -- Face bounding sphere: cell assignment and cell bounds.
        local sx, sy, sz = 0, 0, 0
        for ei = 1, n do
            local v = edges[ei][1]
            sx, sy, sz = sx + v.x, sy + v.y, sz + v.z
        end
        local fcx, fcy, fcz = sx / n, sy / n, sz / n
        local r2 = 0
        for ei = 1, n do
            local v = edges[ei][1]
            local dx, dy, dz = v.x - fcx, v.y - fcy, v.z - fcz
            local d2 = dx * dx + dy * dy + dz * dz
            if d2 > r2 then r2 = d2 end
        end
        local cell = cellFor(fcx, fcy, fcz, math_sqrt(r2))

        local proj = resolveProj(tinfo)
        local svx, svy, svz, sw = proj.sv.x, proj.sv.y, proj.sv.z, proj.sw
        local tvx, tvy, tvz, tw = proj.tv.x, proj.tv.y, proj.tv.z, proj.tw
        local invW, invH = proj.invW, proj.invH
        local normal = face.plane.normal
        local nx, ny, nz = normal.x, normal.y, normal.z
        if face.side and face.side ~= 0 then nx, ny, nz = -nx, -ny, -nz end

        -- Atlas mode: textures batch by atlas page (and cull/blend
        -- variant), not by texture.
        local atlasGroup, tu, tv, pageMat
        if world.atlas then atlasGroup, tu, tv, pageMat = MapCache.atlasTileFor(mat) end
        local isAtlas = atlasGroup ~= nil
        local groupKey = isAtlas and ('#atlas' .. atlasGroup) or matKey
        local groupMat = isAtlas and pageMat or mat
        local stride = isAtlas and 30 or 24

        local allGroup = groupIn(allGroups, allGroupList, groupKey, groupMat, isAtlas, atlasGroup)
        local cellGroup = groupIn(cell.groups, cell.groupList, groupKey, groupMat, isAtlas, atlasGroup)
        local outA, outC = allGroup.verts, cellGroup.verts
        local oa, oc = #outA, #outC

        local a = edges[1][1]
        local ax, ay, az = a.x, a.y, a.z
        local ua = (ax * svx + ay * svy + az * svz + sw) * invW
        local va = (ax * tvx + ay * tvy + az * tvz + tw) * invH
        for vi = 2, n - 1 do
            local b, c = edges[vi][1], edges[vi + 1][1]
            local bx, by, bz, cx, cy, cz = b.x, b.y, b.z, c.x, c.y, c.z
            local ub = (bx * svx + by * svy + bz * svz + sw) * invW
            local vb = (bx * tvx + by * tvy + bz * tvz + tw) * invH
            local uc = (cx * svx + cy * svy + cz * svz + sw) * invW
            local vc = (cx * tvx + cy * tvy + cz * tvz + tw) * invH
            if isAtlas then
                writeTriAtlas(outA, oa, tu, tv, nx, ny, nz, ax, ay, az, ua, va, bx, by, bz, ub, vb, cx, cy, cz, uc, vc)
                writeTriAtlas(outC, oc, tu, tv, nx, ny, nz, ax, ay, az, ua, va, bx, by, bz, ub, vb, cx, cy, cz, uc, vc)
            else
                writeTri(outA, oa, nx, ny, nz, ax, ay, az, ua, va, bx, by, bz, ub, vb, cx, cy, cz, uc, vc)
                writeTri(outC, oc, nx, ny, nz, ax, ay, az, ua, va, bx, by, bz, ub, vb, cx, cy, cz, uc, vc)
            end
            oa, oc = oa + stride, oc + stride
        end
        -- Faces are flushed whole, so meshes never split a triangle.
        local limit = MAX_VERTS_PER_MESH * stride / 3
        if oa >= limit then flush(allGroup, allMeshes) end
        if oc >= limit then flush(cellGroup, cell.meshes) end
    end

    for _, group in ipairs(allGroupList) do flush(group, allMeshes) end
    for _, cell in ipairs(cellList) do
        for _, group in ipairs(cell.groupList) do flush(group, cell.meshes) end
        cell.groups, cell.groupList = nil, nil
        local hx = (cell.maxX - cell.minX) * 0.5
        local hy = (cell.maxY - cell.minY) * 0.5
        local hz = (cell.maxZ - cell.minZ) * 0.5
        cell.cx, cell.cy, cell.cz = cell.minX + hx, cell.minY + hy, cell.minZ + hz
        cell.radius = math_sqrt(hx * hx + hy * hy + hz * hz)
        table_sort(cell.meshes, function(p, q) return p.matId < q.matId end)
    end
    table_sort(allMeshes, function(p, q) return p.matId < q.matId end)

    world.all = allMeshes
    world.cells = cellList
    -- Tiles this bake assigned must be drawn into their pages before use.
    if world.atlas then world.atlasMark = MapCache.atlasMark() end
    world.ready = true
    MsgC(Color(120, 200, 255), string.format(
        '[holo_table] World bake ready (%s): verts=%d all=%d meshes, cells=%d (%d meshes) in %.1fs\n',
        world.atlas and 'atlas' or 'per-texture', world.verts, #allMeshes, #cellList,
        #owned - #allMeshes, SysTime() - world.started))
end

--- Starts the shared world bake if needed. Returns the bake once ready.
--- @return table? world { all: table[], cells: table[] }
function MapCache.getWorldBake()
    if world and world.gen == CACHE_GENERATION and (world.failed or world.atlas == wantAtlas()) then
        return world.ready and world or nil
    end
    local bsp = bsp2 and bsp2.GetCurrent()
    if not bsp then return nil end

    MapCache.destroyWorldBake()
    world = { gen = CACHE_GENERATION, owned = {}, verts = 0, version = 0, started = SysTime(),
        atlas = wantAtlas() }
    world.co = coroutine_create(bakeWorld)
    hook_Add('Think', WORLD_HOOK, function()
        if not world or world.gen ~= CACHE_GENERATION then
            MapCache.destroyWorldBake()
            return
        end
        local ok, err = coroutine_resume(world.co)
        if not ok then
            ErrorNoHaltWithStack(err)
            MapCache.destroyWorldBake()
            -- Do not retry every frame; tables fall back to CPU clipping.
            world = { gen = CACHE_GENERATION, failed = true, owned = {} }
            return
        end
        if coroutine_status(world.co) == 'dead' then
            world.co = nil
            hook_Remove('Think', WORLD_HOOK)
        end
    end)
    return nil
end

--- True when the world bake is still being built (or about to be).
--- @return boolean
function MapCache.worldBakePending()
    return world ~= nil and world.gen == CACHE_GENERATION and not world.ready and not world.failed
end

--- True when the ready world bake uses atlas pages (needs the atlas shader
--- path even for all-in views).
--- @return boolean
function MapCache.worldIsAtlas()
    return world ~= nil and world.ready == true and world.atlas == true
end

local VIS_SCRATCH, visCount = {}, 0
local function byMatId(p, q) return p.matId < q.matId end

--- Mesh list for one table's world draw. All-in views get the per-material
--- set. Partial views get the visible cells' meshes when that is fewer draws
--- than the full set; the GPU clip trims both to the cylinder.
--- @param selfTbl table
--- @param allIn boolean
--- @return table[]? meshes
function MapCache.worldDrawList(selfTbl, allIn)
    local w = world
    if not (w and w.ready) then return nil end
    -- Atlas tiles fill over a few frames after the bake (and again after a
    -- device reset); draw nothing until then rather than sample empty tiles.
    if w.atlas and not MapCache.atlasFilled(w.atlasMark) then return nil end
    if allIn then return w.all end

    local axisX, axisY, axisZ = selfTbl._holoAxis:Unpack()
    local panX, panY, panZ = selfTbl._holoPanHoriz:Unpack()
    local cylRadius = selfTbl._holoCylRadius
    local floorOffset = selfTbl._holoFloorOffset
    local n, draws = 0, 0
    local list = w.cells
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
        n = n + 1
        VIS_SCRATCH[n] = cell
        draws = draws + #cell.meshes
    end
    for i = n + 1, visCount do VIS_SCRATCH[i] = nil end
    visCount = n
    if draws >= #w.all then return w.all end

    -- Cache the merged, material-sorted list per table; rebuild only when
    -- the visible cell set changes.
    local cache = selfTbl._holoWorldDraw
    if not cache or cache.world ~= w then
        cache = { world = w, cells = {}, n = -1, list = {} }
        selfTbl._holoWorldDraw = cache
    end
    local same = cache.n == n
    if same then
        local cells = cache.cells
        for i = 1, n do
            if cells[i] ~= VIS_SCRATCH[i] then same = false break end
        end
    end
    if not same then
        local cells, out, m = cache.cells, cache.list, 0
        for i = 1, n do
            local cell = VIS_SCRATCH[i]
            cells[i] = cell
            local meshes = cell.meshes
            for j = 1, #meshes do
                m = m + 1
                out[m] = meshes[j]
            end
        end
        for i = n + 1, #cells do cells[i] = nil end
        for i = m + 1, #out do out[i] = nil end
        table_sort(out, byMatId)
        cache.n = n
    end
    return cache.list
end
