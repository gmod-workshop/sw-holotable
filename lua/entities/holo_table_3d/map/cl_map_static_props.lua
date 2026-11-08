local MapCache = ENT.MapCache
local SysTime = SysTime
local Material = Material
local math_atan2 = math.atan2
local math_sqrt = math.sqrt
local math_pi = math.pi
local coroutine_create = coroutine.create
local coroutine_yield = coroutine.yield
local coroutine_resume = coroutine.resume
local coroutine_status = coroutine.status
local hook_Add = hook.Add
local hook_Remove = hook.Remove
local render_SetMaterial = render.SetMaterial
local HoloEffects = ENT.HoloEffects
local filter = MapCache.filter
local staticPropBakeCvar = MapCache.staticPropBakeCvar
local staticPropBakeModeCvar = MapCache.staticPropBakeModeCvar
local PROP_SUBPIXEL_THRESHOLD = MapCache.PROP_SUBPIXEL_THRESHOLD
local CACHE_GENERATION = MapCache.CACHE_GENERATION
local getPropBounds = MapCache.getPropBounds
local getPropDrawEnt = MapCache.getPropDrawEnt
local peekPropBounds = MapCache.peekPropBounds
local peekPropDrawEnt = MapCache.peekPropDrawEnt
local buildMeshFromFlatTriangles = MapCache.buildMeshFromFlatTriangles
local FLAT_VERTEX_STRIDE = MapCache.FLAT_VERTEX_STRIDE
local PROP_DRAW_SCRATCH_POS = MapCache.PROP_DRAW_SCRATCH_POS
local PROP_DRAW_SCRATCH_ANG = MapCache.PROP_DRAW_SCRATCH_ANG
local atan2 = math_atan2
local sqrt = math_sqrt
local RAD2DEG = 180 / math_pi
local STATIC_PROP_PER_PROP_BAKE_HOOK = 'holo_table_3d.static_prop_per_prop_bake'
local STATIC_PROP_BAKE_FRAME_BUDGET = 0.006
-- Verts per baked IMesh. IMeshes take up to 65532 verts (16-bit indices);
-- 30000 keeps a single unyieldable mesh.Begin under ~15 ms while cutting
-- draw calls, which bound the steady-state cost on dense maps.
local STATIC_PROP_BAKE_MAX_VERTS = 30000
local STATIC_PROP_BAKE_PER_VERT_SEC = 0.5e-6
-- Per-frame budget for cache-missing model loads in the legacy draw path.
local LEGACY_PROP_LOAD_FRAME_BUDGET = 0.003
--- Model LOD used for prop bakes at a given table scale. At scale 36 a
--- 100-unit prop is ~3 holo units across, so LOD0 is wasted geometry: on
--- gm_gmall_2 the LOD0 static bake heads for ~15M+ vertices. GetModelMeshes
--- clamps an out-of-range LOD to the model's lowest, so 8 means "lowest".
--- Bakes are rebuilt when the table zooms in past the scale they were
--- built for, so a closer view picks up the finer LOD.
--- @param scale number
--- @return number lod
local function propBakeLodForScale(scale)
    if scale >= 12 then return 8 end
    if scale >= 4 then return 2 end
    if scale >= 2 then return 1 end
    return 0
end
MapCache.propBakeLodForScale = propBakeLodForScale
MapCache.staticPropPerPropBake = nil

function MapCache.destroyStaticPropPerPropBake()
    hook_Remove('Think', STATIC_PROP_PER_PROP_BAKE_HOOK)
    if MapCache.staticPropPerPropBake and MapCache.staticPropPerPropBake.props then
        for _, rec in ipairs(MapCache.staticPropPerPropBake.props) do
            MapCache.destroyMeshList(rec.meshes)
        end
    end
    if MapCache.staticPropPerPropBake and MapCache.staticPropPerPropBake.pendingProps then
        for _, rec in ipairs(MapCache.staticPropPerPropBake.pendingProps) do
            MapCache.destroyMeshList(rec.meshes)
        end
    end
    if MapCache.staticPropPerPropBake then
        MapCache.destroyMeshList(MapCache.staticPropPerPropBake.pendingMeshes)
    end
    MapCache.staticPropPerPropBake = nil
end

--- Resolves a static-prop mesh material; returns nil for filtered or error mats.
--- @param path string Material path.
--- @return IMaterial? mat
--- @return string? matKey Group key (basetexture name when present).
local function staticPropBakeMaterial(path)
    if not path or path == '' then return nil, nil end
    local mat = Material(path)
    if not mat or mat:IsError() then return nil, nil end
    local btn = mat:GetTexture('$basetexture')
    if btn and filter[btn:GetName()] then return nil, nil end
    return mat, btn and btn:GetName() or mat:GetName()
end

--- Transforms a model-local vert into BSP space and appends packed
--- px,py,pz,nx,ny,nz,u,v values to out.
--- @param out number[] Vertex buffer to append to.
--- @param vert table { pos: Vector, normal?: Vector, u: number, v: number }
--- @param origin Vector World origin of the prop.
--- @param fx number @param fy number @param fz number Forward basis.
--- @param rx number @param ry number @param rz number Right basis.
--- @param ux number @param uy number @param uz number Up basis.
local function addStaticPropBakeVert(out, vert, origin, fx, fy, fz, rx, ry, rz, ux, uy, uz)
    local pos = vert.pos
    local px, py, pz = pos.x, pos.y, pos.z
    local normal = vert.normal or vector_up
    local nx, ny, nz = normal.x, normal.y, normal.z
    local outNX = fx * nx - rx * ny + ux * nz
    local outNY = fy * nx - ry * ny + uy * nz
    local outNZ = fz * nx - rz * ny + uz * nz
    local normalLength = math_sqrt(outNX * outNX + outNY * outNY + outNZ * outNZ)
    if normalLength > 0 then
        local invLength = 1 / normalLength
        outNX, outNY, outNZ = outNX * invLength, outNY * invLength, outNZ * invLength
    end
    local i = #out
    out[i + 1] = origin.x + fx * px - rx * py + ux * pz
    out[i + 2] = origin.y + fy * px - ry * py + uy * pz
    out[i + 3] = origin.z + fz * px - rz * py + uz * pz
    out[i + 4] = outNX
    out[i + 5] = outNY
    out[i + 6] = outNZ
    out[i + 7] = vert.u or 0
    out[i + 8] = vert.v or 0
end
MapCache.addStaticPropBakeVert = addStaticPropBakeVert

local propOrderCache = setmetatable({}, { __mode = 'k' })

--- Returns prop indices sorted by model|skin so a bake can fetch each
--- model's mesh data once and drop it after its last instance, instead of
--- holding util.GetModelMeshes output for every unique model at once.
--- Cached per props table (weak keys).
--- @param props table[] Records with .model and optional .skin.
--- @return number[] order
--- @return table<number, string> keys index -> model|skin
local function propOrderByModel(props)
    local cached = propOrderCache[props]
    if cached then return cached.order, cached.keys end
    local order, keys = {}, {}
    for i = 1, #props do
        local p = props[i]
        if p and p.model then
            order[#order + 1] = i
            keys[i] = p.model .. '|' .. (p.skin or 0)
        end
    end
    table.sort(order, function(a, b)
        local ka, kb = keys[a], keys[b]
        if ka ~= kb then return ka < kb end
        return a < b
    end)
    propOrderCache[props] = { order = order, keys = keys }
    return order, keys
end
MapCache.propOrderByModel = propOrderByModel

--- True when the global static-prop bake applies to this view: always in
--- mode 3, only for horizontally all-in views in mode 1.
---
--- Dense maps must NOT be routed to the legacy renderer for partial views:
--- it synchronously loads every in-view model (util.GetModelInfo +
--- ClientsideModel) and issues one SetupBones/DrawModel per prop per frame,
--- which froze gm_mall2 for minutes on spawn.
--- @param ent Entity
--- @param scale number
--- @return boolean
function MapCache.canUseGlobalStaticPropBake(ent, scale)
    local mode = staticPropBakeModeCvar:GetInt()
    if mode == 3 then return true end
    if mode ~= 1 then return false end
    return ent:CylinderHorizContainsMap(scale, ent:GetPanX(), ent:GetPanY())
end

--- Per-prop variant of startStaticPropBake. Each prop becomes its own
--- {center, radius, meshes} record so the draw path can sphere-cull
--- before issuing each prop's mesh draws.
--- @param scale number
--- @see MapCache.startStaticPropBake
function MapCache.startStaticPropPerPropBake(scale)
    if not staticPropBakeCvar:GetBool() then return end
    local bsp = bsp2 and bsp2.GetCurrent()
    if not bsp or not bsp.props or #bsp.props == 0 then return end
    scale = tonumber(scale) or 0
    if scale <= 0 then return end
    if MapCache.staticPropPerPropBake and MapCache.staticPropPerPropBake.gen == CACHE_GENERATION
        and (MapCache.staticPropPerPropBake.scale or math.huge) <= scale + 0.01
        and (MapCache.staticPropPerPropBake.state == 'building' or MapCache.staticPropPerPropBake.state == 'ready') then
        return
    end

    MapCache.destroyStaticPropPerPropBake()
    local minRadius = PROP_SUBPIXEL_THRESHOLD / (2 / scale)
    MapCache.staticPropPerPropBake = {
        gen = CACHE_GENERATION,
        state = 'building',
        scale = scale,
        minRadius = minRadius,
        propsTotal = #bsp.props,
        props = {},
        pendingProps = {},
        pendingMeshes = {},
        bakedProps = 0,
        outputVerts = 0,
    }

    MapCache.staticPropPerPropBake.co = coroutine_create(function()
        local props = bsp.props
        local deadline = SysTime() + STATIC_PROP_BAKE_FRAME_BUDGET

        local function bumpDeadline()
            deadline = SysTime() + STATIC_PROP_BAKE_FRAME_BUDGET
        end

        local function budgetYield()
            if SysTime() <= deadline then return end
            coroutine_yield()
            bumpDeadline()
        end

        local function flushGroup(group, meshes)
            local verts = group.verts
            local valueCount = #verts
            if valueCount == 0 then return end
            local vertCount = valueCount / FLAT_VERTEX_STRIDE
            if SysTime() + vertCount * STATIC_PROP_BAKE_PER_VERT_SEC > deadline then
                coroutine_yield()
                bumpDeadline()
            end
            local msh = buildMeshFromFlatTriangles(verts)
            local item = { mat = group.mat, mesh = msh }
            meshes[#meshes + 1] = item
            MapCache.staticPropPerPropBake.pendingMeshes[#MapCache.staticPropPerPropBake.pendingMeshes + 1] = item
            MapCache.staticPropPerPropBake.outputVerts = MapCache.staticPropPerPropBake.outputVerts + vertCount
            group.verts = {}
            budgetYield()
        end

        local function groupFor(groups, mat, matKey)
            local group = groups[matKey]
            if not group then
                group = { mat = mat, verts = {} }
                groups[matKey] = group
            end
            return group
        end

        local order, keys = propOrderByModel(props)
        local currentModelKey, modelMeshes = nil, false
        local bakeLod = propBakeLodForScale(scale)
        for oi = 1, #order do
            budgetYield()
            local i = order[oi]
            local prop = props[i]
            local model = prop.model

            local bounds = getPropBounds(model)
            local radius = bounds.radius
            if radius == 0 or radius < minRadius then continue end

            local modelKey = keys[i]
            if modelKey ~= currentModelKey then
                currentModelKey = modelKey
                modelMeshes = false
                budgetYield()
                modelMeshes = util.GetModelMeshes(model, bakeLod, 0, prop.skin or 0) or false
            end
            if not modelMeshes then continue end

            local origin = prop.origin
            if not origin then continue end

            local fx, fy, fz, rx, ry, rz, ux, uy, uz
            if prop.angles then
                local f = prop.angles:Forward()
                local r = prop.angles:Right()
                local u = prop.angles:Up()
                fx, fy, fz = f.x, f.y, f.z
                rx, ry, rz = r.x, r.y, r.z
                ux, uy, uz = u.x, u.y, u.z
            else
                fx, fy, fz = 1, 0, 0
                rx, ry, rz = 0, -1, 0
                ux, uy, uz = 0, 0, 1
            end

            local bc = bounds.center
            local bcx, bcy, bcz = bc.x, bc.y, bc.z
            local cx = origin.x + fx * bcx - rx * bcy + ux * bcz
            local cy = origin.y + fy * bcx - ry * bcy + uy * bcz
            local cz = origin.z + fz * bcx - rz * bcy + uz * bcz
            local groups = {}
            local meshes = {}

            for _, meshData in ipairs(modelMeshes) do
                local mat, matKey = staticPropBakeMaterial(meshData.material)
                local tris = meshData.triangles
                if not (mat and tris) then continue end

                local group = groupFor(groups, mat, matKey)
                local out = group.verts
                for vi = 1, #tris do
                    addStaticPropBakeVert(out, tris[vi], origin, fx, fy, fz, rx, ry, rz, ux, uy, uz)
                    if #out >= STATIC_PROP_BAKE_MAX_VERTS * FLAT_VERTEX_STRIDE then
                        flushGroup(group, meshes)
                        out = group.verts
                    elseif vi % 768 == 0 then
                        budgetYield()
                    end
                end
            end

            for _, group in pairs(groups) do
                flushGroup(group, meshes)
            end

            if #meshes > 0 then
                local rec = {
                    cx = cx, cy = cy, cz = cz,
                    radius = radius,
                    meshes = meshes,
                }
                MapCache.staticPropPerPropBake.pendingProps[#MapCache.staticPropPerPropBake.pendingProps + 1] = rec
                MapCache.staticPropPerPropBake.bakedProps = MapCache.staticPropPerPropBake.bakedProps + 1
            end
        end

        MapCache.staticPropPerPropBake.state = 'ready'
    end)

    hook_Add('Think', STATIC_PROP_PER_PROP_BAKE_HOOK, function()
        if not MapCache.staticPropPerPropBake or MapCache.staticPropPerPropBake.gen ~= CACHE_GENERATION then
            MapCache.destroyStaticPropPerPropBake()
            return
        end
        if MapCache.staticPropPerPropBake.state ~= 'building' then
            hook_Remove('Think', STATIC_PROP_PER_PROP_BAKE_HOOK)
            return
        end
        if MapCache.anyClipCoroutineActive() then return end
        if not MapCache.claimBackgroundSlot('static_per_prop_bake') then return end

        local ok, err = coroutine_resume(MapCache.staticPropPerPropBake.co)
        if not ok then
            ErrorNoHaltWithStack(err)
            MapCache.destroyStaticPropPerPropBake()
            return
        end
        if coroutine_status(MapCache.staticPropPerPropBake.co) == 'dead' then
            MapCache.staticPropPerPropBake.co = nil
            MapCache.staticPropPerPropBake.props = MapCache.staticPropPerPropBake.pendingProps or {}
            MapCache.staticPropPerPropBake.pendingProps = nil
            MapCache.staticPropPerPropBake.pendingMeshes = nil
            if MapCache.staticPropPerPropBake.state == 'building' then MapCache.staticPropPerPropBake.state = 'ready' end
            hook_Remove('Think', STATIC_PROP_PER_PROP_BAKE_HOOK)
            MsgC(Color(120, 200, 255), string.format(
                '[holo_table] Static prop per-prop bake ready: props=%d/%d scale=%.1f verts=%d\n',
                MapCache.staticPropPerPropBake.bakedProps or 0,
                MapCache.staticPropPerPropBake.propsTotal or 0,
                MapCache.staticPropPerPropBake.scale or 0,
                MapCache.staticPropPerPropBake.outputVerts or 0))
        end
    end)
end

local function drawStaticBakeMeshes(meshes)
    local lastMat
    for i = 1, #meshes do
        local item = meshes[i]
        if item.mesh then
            local mat = item.mat
            if mat ~= lastMat then
                render_SetMaterial(mat)
                lastMat = mat
            end
            item.mesh:Draw()
        end
    end
end

local function drawCulledStaticBake(props, axisX, axisY, axisZ,
    panX, panY, panZ, cylRadius, floorOffset)
    for i = 1, #props do
        local rec = props[i]
        local cx, cy, cz = rec.cx, rec.cy, rec.cz
        local radius = rec.radius
        local along = cx * axisX + cy * axisY + cz * axisZ
        local hx = cx - axisX * along - panX
        local hy = cy - axisY * along - panY
        local hz = cz - axisZ * along - panZ
        local bound = cylRadius + radius
        if hx * hx + hy * hy + hz * hz > bound * bound then continue end
        if along + radius < floorOffset then continue end
        drawStaticBakeMeshes(rec.meshes)
    end
end

local function drawEffectCulledStaticBake(props, axisX, axisY, axisZ,
    panX, panY, panZ, cylRadius, floorOffset)
    for i = 1, #props do
        local rec = props[i]
        local cx, cy, cz = rec.cx, rec.cy, rec.cz
        local radius = rec.radius
        local along = cx * axisX + cy * axisY + cz * axisZ
        local hx = cx - axisX * along - panX
        local hy = cy - axisY * along - panY
        local hz = cz - axisZ * along - panZ
        local bound = cylRadius + radius
        if hx * hx + hy * hy + hz * hz > bound * bound then continue end
        if along + radius < floorOffset then continue end
        HoloEffects.DrawMeshList(rec.meshes)
    end
end


--- Draws baked static props for the given holo table: tiered, lazily baked
--- cells in modes 1/3 (see cl_map_prop_cells.lua), per-prop bake in mode 2.
--- Returns true whenever the baked path owns the layer, including while
--- cells are still baking. Returns false only when the bake is disabled /
--- not applicable, and the caller falls back to ENT:DrawStaticProps.
--- @return boolean handled
--- @see ENT:DrawStaticProps
function ENT:DrawBakedStaticProps()
    if not staticPropBakeCvar:GetBool() then return false end
    if not self:GetMap() then return false end
    local selfTbl = self:GetTable()
    local mode = staticPropBakeModeCvar:GetInt()
    if mode == 0 then return false end
    local scale = self:GetScale()
    if mode == 2 then
        if not MapCache.staticPropPerPropBake or MapCache.staticPropPerPropBake.gen ~= CACHE_GENERATION
            or (MapCache.staticPropPerPropBake.scale or math.huge) > scale + 0.01 then
            MapCache.startStaticPropPerPropBake(scale)
            return MapCache.staticPropPerPropBake ~= nil
        end
        if MapCache.staticPropPerPropBake.state ~= 'ready' or not MapCache.staticPropPerPropBake.props then return true end

        local axisX, axisY, axisZ = selfTbl._holoAxis:Unpack()
        local panX,  panY,  panZ  = selfTbl._holoPanHoriz:Unpack()
        local cylRadius           = selfTbl._holoCylRadius
        local floorOffset         = selfTbl._holoFloorOffset

        if HoloEffects.ArePropsEnabled() and HoloEffects.BeginDraw(selfTbl, true) then
            local effectOk, effectErr = pcall(drawEffectCulledStaticBake,
                MapCache.staticPropPerPropBake.props,
                axisX, axisY, axisZ, panX, panY, panZ, cylRadius, floorOffset)
            if HoloEffects.EndDraw(effectOk, effectErr) then return true end
        end

        render.SuppressEngineLighting(true)
        local ok, err = pcall(drawCulledStaticBake,
            MapCache.staticPropPerPropBake.props,
            axisX, axisY, axisZ, panX, panY, panZ, cylRadius, floorOffset)
        render.SuppressEngineLighting(false)

        if not ok then
            ErrorNoHaltWithStack('[holo_table] DrawBakedStaticProps per-prop aborted: ' .. tostring(err))
            MapCache.destroyStaticPropPerPropBake()
            return false
        end
        return true
    end

    if not MapCache.canUseGlobalStaticPropBake(self, scale) then return false end
    return MapCache.drawPropCells(selfTbl, scale)
end

--- Legacy fallback: per-prop ClientsideModel draws in world space, sphere-
--- culled against the table cylinder. Used when bake is disabled / not
--- ready. Allocation-free hot loop -- props cache scalar bases / cull centers.
--- @see ENT:DrawBakedStaticProps
function ENT:DrawStaticProps()
    local bsp = bsp2 and bsp2.GetCurrent()
    if not bsp or not bsp.props then return end
    local selfTbl = self:GetTable()

    local axisX, axisY, axisZ = selfTbl._holoAxis:Unpack()
    local panX,  panY,  panZ  = selfTbl._holoPanHoriz:Unpack()
    local cylRadius   = selfTbl._holoCylRadius
    local floorOffset = selfTbl._holoFloorOffset

    -- World-space transform mirrors m2: world = origin + R(tableAng) * (p_bsp / scale).
    -- Pan is already folded into _holoOrigin.
    local tableAng    = selfTbl._holoAngles
    local tableOrigin = selfTbl._holoOrigin
    local invScale    = selfTbl._holoInvScale

    local subpxRadiusBSP = PROP_SUBPIXEL_THRESHOLD / (2 * invScale)

    local cylRadiusPlus = cylRadius
    local props = bsp.props
    local scratchPos = PROP_DRAW_SCRATCH_POS
    local scratchAng = PROP_DRAW_SCRATCH_ANG

    local tF = tableAng:Forward()
    local tR = tableAng:Right()
    local tU = tableAng:Up()
    local tFx, tFy, tFz = tF.x, tF.y, tF.z
    local tRx, tRy, tRz = tR.x, tR.y, tR.z
    local tUx, tUy, tUz = tU.x, tU.y, tU.z
    local toX, toY, toZ = tableOrigin.x, tableOrigin.y, tableOrigin.z

    -- util.GetModelInfo / ClientsideModel are synchronous model loads;
    -- spread first-time loads over frames instead of all in the first one.
    local loadDeadline = SysTime() + LEGACY_PROP_LOAD_FRAME_BUDGET

    render.SuppressEngineLighting(true)
    for i = 1, #props do
        local prop = props[i]
        local model = prop.model
        if not model then continue end

        local b = peekPropBounds(model)
        if not b then
            if SysTime() > loadDeadline then continue end
            b = getPropBounds(model)
        end
        local radius = b.radius
        if radius == 0 then continue end
        if radius < subpxRadiusBSP then continue end

        -- Lazily cached scalar cull center + prop basis. Both are
        -- invariant since prop.origin/angles never change at runtime.
        local cx, cy, cz = prop._holoCullCx, prop._holoCullCy, prop._holoCullCz
        if not cx then
            local origin = prop.origin
            local bc = b.center
            local bcx, bcy, bcz = bc.x, bc.y, bc.z
            if prop.angles then
                local pf = prop.angles:Forward()
                local pr = prop.angles:Right()
                local pu = prop.angles:Up()
                prop._holoFx, prop._holoFy, prop._holoFz = pf.x, pf.y, pf.z
                prop._holoRx, prop._holoRy, prop._holoRz = pr.x, pr.y, pr.z
                prop._holoUx, prop._holoUy, prop._holoUz = pu.x, pu.y, pu.z
                cx = origin.x + pf.x * bcx - pr.x * bcy + pu.x * bcz
                cy = origin.y + pf.y * bcx - pr.y * bcy + pu.y * bcz
                cz = origin.z + pf.z * bcx - pr.z * bcy + pu.z * bcz
            else
                cx = origin.x + bcx
                cy = origin.y + bcy
                cz = origin.z + bcz
            end
            prop._holoCullCx, prop._holoCullCy, prop._holoCullCz = cx, cy, cz
        elseif prop.angles and not prop._holoFx then
            local pf = prop.angles:Forward()
            local pr = prop.angles:Right()
            local pu = prop.angles:Up()
            prop._holoFx, prop._holoFy, prop._holoFz = pf.x, pf.y, pf.z
            prop._holoRx, prop._holoRy, prop._holoRz = pr.x, pr.y, pr.z
            prop._holoUx, prop._holoUy, prop._holoUz = pu.x, pu.y, pu.z
        end

        local along = cx * axisX + cy * axisY + cz * axisZ
        local hx = cx - axisX * along - panX
        local hy = cy - axisY * along - panY
        local hz = cz - axisZ * along - panZ
        local bound = cylRadiusPlus + radius
        if hx * hx + hy * hy + hz * hz > bound * bound then continue end
        if along + radius < floorOffset then continue end

        local cs = peekPropDrawEnt(model)
        if not cs then
            if SysTime() > loadDeadline then continue end
            cs = getPropDrawEnt(model)
            if not IsValid(cs) then continue end
        end

        local origin = prop.origin
        local lx = origin.x * invScale
        local ly = origin.y * invScale
        local lz = origin.z * invScale
        scratchPos:SetUnpacked(
            toX + tFx * lx - tRx * ly + tUx * lz,
            toY + tFy * lx - tRy * ly + tUy * lz,
            toZ + tFz * lx - tRz * ly + tUz * lz)
        cs:SetPos(scratchPos)
        if prop.angles then
            -- Compose the world-space basis manually and derive Euler.
            local pfx, pfy, pfz = prop._holoFx, prop._holoFy, prop._holoFz
            local prx, pry, prz = prop._holoRx, prop._holoRy, prop._holoRz
            local pux, puy, puz = prop._holoUx, prop._holoUy, prop._holoUz
            local wFx = tFx * pfx - tRx * pfy + tUx * pfz
            local wFy = tFy * pfx - tRy * pfy + tUy * pfz
            local wFz = tFz * pfx - tRz * pfy + tUz * pfz
            local wRz = tFz * prx - tRz * pry + tUz * prz
            local wUz = tFz * pux - tRz * puy + tUz * puz
            local pitch = atan2(-wFz, sqrt(wFx * wFx + wFy * wFy)) * RAD2DEG
            local yaw   = atan2(wFy, wFx) * RAD2DEG
            local roll  = atan2(-wRz, wUz) * RAD2DEG
            scratchAng:SetUnpacked(pitch, yaw, roll)
            cs:SetAngles(scratchAng)
        else
            cs:SetAngles(tableAng)
        end
        cs:SetModelScale(invScale, 0)
        cs:SetupBones()
        if not HoloEffects.DrawPropModel(selfTbl, cs, i * 0.17) then
            cs:DrawModel()
        end
    end
    render.SuppressEngineLighting(false)
end


MapCache.staticPropBakeMaterial = staticPropBakeMaterial
