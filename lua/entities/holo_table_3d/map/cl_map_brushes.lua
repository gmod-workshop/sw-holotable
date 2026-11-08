local MapCache = ENT.MapCache
local SysTime = SysTime
local FrameNumber = FrameNumber
local Vector = Vector
local bit_band = bit.band
local math_sqrt = math.sqrt
local hook_Add = hook.Add
local render_SetMaterial = render.SetMaterial
local HoloEffects = ENT.HoloEffects
local filter = MapCache.filter
local SURF_SKIP_MASK = MapCache.SURF_SKIP_MASK
local getMatByTexinfo = MapCache.getMatByTexinfo
local isMatByTexinfoReady = MapCache.isMatByTexinfoReady
local loadTexdataMaterial = MapCache.loadTexdataMaterial
local unlitWrap = MapCache.unlitWrap
local buildMeshFromTriangles = MapCache.buildMeshFromTriangles
local brushMeshCache = {}

--- Atlas batching for brush meshes (map/cl_map_atlas.lua loads later, so
--- resolved at call time).
local function atlasOn()
    return MapCache.atlasEnabled ~= nil and MapCache.atlasEnabled()
end

local function destroyBrushMeshes(modelIndex)
    local list = brushMeshCache[modelIndex]
    if type(list) == 'table' then
        for _, item in ipairs(list) do
            if item.mesh then item.mesh:Destroy() end
        end
    end
    brushMeshCache[modelIndex] = nil
end

local function byDrawOrder(a, b) return a.order < b.order end

function MapCache.clearBrushMeshCache()
    for _, list in pairs(brushMeshCache) do
        if type(list) == 'table' then
            for _, item in ipairs(list) do
                if item.mesh then item.mesh:Destroy() end
            end
        end
    end
    brushMeshCache = {}
    if MapCache.destroyWorldBake then MapCache.destroyWorldBake() end
    MapCache.destroyStaticPropBake()
    MapCache.destroyStaticPropPerPropBake()
    MapCache.destroyDynamicPropBake()
end

hook_Add('CurrentBSPReady', 'holo_table_3d.brushMeshCache', MapCache.clearBrushMeshCache)

--- Builds (or returns cached) per-material IMesh batches for one bmodel.
--- Vertices are kept entity-local so a single mesh serves every live brush
--- entity that references this bmodel index. With holo_table_atlas on,
--- textures batch by atlas page and variant instead, so a typical brush
--- entity is one or two draws instead of one per material.
--- @param modelIndex number 1-based bmodel index.
--- @return table[]? meshes nil if the model has no renderable faces.
function ENT:GetBrushModelMeshes(modelIndex)
    local cached = brushMeshCache[modelIndex]
    if cached ~= nil then return cached or nil end

    local bsp = bsp2 and bsp2.GetCurrent()
    local bmodel = bsp and bsp.models and bsp.models[modelIndex]
    if not bmodel or not bmodel.faces or #bmodel.faces == 0 then
        brushMeshCache[modelIndex] = false
        return nil
    end

    -- Ensures the adapter's fallback materials (tinfo._holoBsp2Material) exist.
    getMatByTexinfo()

    local useAtlas = atlasOn()
    local groups = {}
    for _, face in ipairs(bmodel.faces) do
        local tinfo = face.texinfo
        if not tinfo then continue end
        if bit_band(tinfo.flags or 0, SURF_SKIP_MASK) ~= 0 then continue end

        local edges = face.edges
        if not edges or #edges < 3 then continue end

        local mat = loadTexdataMaterial(tinfo.texdata.material)
        if mat:GetShader() == 'LightmappedGeneric' then
            -- Same logic as resolveMat: prefer the adapter fallback, wrap
            -- the corrected texture ourselves when the fallback is broken.
            local fb = tinfo._holoBsp2Material
            if fb then
                local fbBtn = fb:GetTexture('$basetexture')
                if fbBtn and filter[fbBtn:GetName()] then
                    mat = unlitWrap(mat)
                else
                    mat = fb
                end
            else
                mat = unlitWrap(mat)
            end
        end
        local btn = mat:GetTexture('$basetexture')
        if btn and filter[btn:GetName()] then continue end

        local matKey = btn and btn:GetName() or mat:GetName()
        local atlasGroup, tileU, tileV, pageMat
        if useAtlas then atlasGroup, tileU, tileV, pageMat = MapCache.atlasTileFor(mat) end
        if atlasGroup then matKey = '#atlas' .. atlasGroup end
        local g = groups[matKey]
        if not g then
            g = { mat = atlasGroup and pageMat or mat, verts = {}, atlas = atlasGroup ~= nil,
                order = atlasGroup and (1e9 + atlasGroup) or 0 }
            groups[matKey] = g
        end

        local s, t = tinfo.textureVecs.s, tinfo.textureVecs.t
        local sv, sw = Vector(s.x, s.y, s.z), s.w
        local tv, tw = Vector(t.x, t.y, t.z), t.w
        local invW = 1 / tinfo.texdata.width
        local invH = 1 / tinfo.texdata.height
        local normal = face.plane.normal
        if face.side and face.side ~= 0 then normal = -normal end

        local verts = g.verts
        local a = edges[1][1]
        local ua = (a:Dot(sv) + sw) * invW
        local va = (a:Dot(tv) + tw) * invH
        for vi = 2, #edges - 1 do
            local b, c = edges[vi][1], edges[vi + 1][1]
            local ub = (b:Dot(sv) + sw) * invW
            local vb = (b:Dot(tv) + tw) * invH
            local uc = (c:Dot(sv) + sw) * invW
            local vc = (c:Dot(tv) + tw) * invH
            verts[#verts + 1] = { pos = a, normal = normal, u = ua, v = va, tu = tileU, tv = tileV }
            verts[#verts + 1] = { pos = b, normal = normal, u = ub, v = vb, tu = tileU, tv = tileV }
            verts[#verts + 1] = { pos = c, normal = normal, u = uc, v = vc, tu = tileU, tv = tileV }
        end
    end

    local list = {}
    for _, g in pairs(groups) do
        if #g.verts > 0 then
            local msh
            if g.atlas then
                local buf, o = {}, 0
                for _, vtx in ipairs(g.verts) do
                    local p, n = vtx.pos, vtx.normal
                    buf[o + 1], buf[o + 2], buf[o + 3] = p.x, p.y, p.z
                    buf[o + 4], buf[o + 5], buf[o + 6] = n.x, n.y, n.z
                    buf[o + 7], buf[o + 8], buf[o + 9], buf[o + 10] = vtx.u, vtx.v, vtx.tu, vtx.tv
                    o = o + 10
                end
                msh = MapCache.buildAtlasMesh(buf, g.mat)
            else
                msh = buildMeshFromTriangles(g.verts)
            end
            if msh then list[#list + 1] = { mat = g.mat, mesh = msh, atlas = g.atlas, order = g.order } end
        end
    end
    if #list == 0 then
        brushMeshCache[modelIndex] = false
        return nil
    end
    table.sort(list, byDrawOrder)
    list.bakedAtlas = useAtlas
    -- Tiles this build assigned must be drawn into their pages first.
    list.atlasMark = useAtlas and MapCache.atlasMark() or nil
    brushMeshCache[modelIndex] = list
    return list
end

-- 1 Hz cached "*N" brush-entity list. ents.Iterator walks the engine's
-- existing entity table directly (no realloc per call).
local brushEntCache     = {}
local brushEntCacheTime = 0
local BRUSH_CACHE_TTL   = 1.0

--- @return { ent: Entity, idx1: number, extent: number }[]
local function getBrushEntList(bsp)
    if SysTime() - brushEntCacheTime < BRUSH_CACHE_TTL then return brushEntCache end
    local list = {}
    for _, ent in ents.Iterator() do
        local model = ent:GetModel()
        if not model or model:sub(1, 1) ~= '*' then continue end
        local idx = tonumber(model:sub(2))
        if not idx then continue end
        local bmodel = bsp.models[idx + 1]
        if not bmodel then continue end
        local mn, mx = bmodel.mins, bmodel.maxs
        local dx, dy, dz = mx.x - mn.x, mx.y - mn.y, mx.z - mn.z
        list[#list + 1] = {
            ent    = ent,
            idx1   = idx + 1,
            extent = math_sqrt(dx * dx + dy * dy + dz * dz) * 0.5,
        }
    end
    brushEntCache     = list
    brushEntCacheTime = SysTime()
    return list
end

-- Module-level scratch matrix reused for every brush-ent push.
local BRUSH_DRAW_SCRATCH_MTX = Matrix()

-- Per-frame budget for first-time bmodel mesh builds. Dense maps have
-- hundreds of brush entities; building them all on the table's first
-- frame was a multi-second hitch.
local BRUSH_BUILD_FRAME_BUDGET = 0.003

local function drawBrushMeshList(meshes)
    for i = 1, #meshes do
        local item = meshes[i]
        render_SetMaterial(item.mat)
        item.mesh:Draw()
    end
end

--- Draws every live brush entity ("*N" model) at its current world pose,
--- composed on top of the caller's pushed scene matrix. Cylinder cull is
--- BSP-space scalar against the entity origin + bmodel local extent.
--- Effect-enabled brushes use two passes: opaque before radar entities and
--- translucent/additive after them.
--- @param translucentPass boolean? Draw only the late translucent effect pass.
function ENT:DrawBrushEntities(translucentPass)
    local bsp = bsp2 and bsp2.GetCurrent()
    if not bsp or not bsp.models then return end

    translucentPass = translucentPass == true
    local selfTbl = self:GetTable()
    local axisX, axisY, axisZ = selfTbl._holoAxis:Unpack()
    local panX,  panY,  panZ  = selfTbl._holoPanHoriz:Unpack()
    local cylRadius           = selfTbl._holoCylRadius
    local floorOffset         = selfTbl._holoFloorOffset
    local mtx                 = BRUSH_DRAW_SCRATCH_MTX
    local list                = getBrushEntList(bsp)
    local frameNumber         = FrameNumber()
    local effectEnabled       = HoloEffects.AreBrushesEnabled()
    if translucentPass and not effectEnabled then return end
    local effectActive        = effectEnabled and HoloEffects.BeginDraw(selfTbl, true)
    -- Opaque pass draws depth-writing meshes, the late pass the rest. (Not
    -- `translucentPass and false or ...`: the `false` falls through, which
    -- drew opaque meshes twice and translucent ones never.)
    local depthWriteFilter    = nil
    if translucentPass then
        depthWriteFilter = false
    elseif effectActive then
        depthWriteFilter = true
    end
    local effectOk, effectErr = true
    local buildDeadline       = nil
    local wantAtlas           = atlasOn()
    -- Plain path: atlas meshes need the atlas shader's constants, staged
    -- once for the whole pass (the commit is a hidden model draw).
    local atlasStaged         = false

    for i = 1, #list do
        local rec = list[i]
        local ent = rec.ent
        if not IsValid(ent) or ent == self then continue end

        -- All tables drawing this frame can share the live pose; both entity
        -- accessors allocate even though the result cannot visibly differ.
        if rec.poseFrame ~= frameNumber then
            rec.poseFrame = frameNumber
            rec.pos = ent:GetPos()
            rec.ang = ent:GetAngles()
        end
        local entPos = rec.pos
        local px, py, pz = entPos.x, entPos.y, entPos.z
        local extent = rec.extent
        local along  = px * axisX + py * axisY + pz * axisZ
        local hx = px - axisX * along - panX
        local hy = py - axisY * along - panY
        local hz = pz - axisZ * along - panZ
        local bound = cylRadius + extent
        if hx * hx + hy * hy + hz * hz > bound * bound then continue end
        if along + extent < floorOffset then continue end

        local meshes = brushMeshCache[rec.idx1]
        -- Built for the other holo_table_atlas setting: rebuild.
        if meshes and meshes.bakedAtlas ~= wantAtlas then
            destroyBrushMeshes(rec.idx1)
            meshes = nil
        end
        if meshes == nil then
            -- Wait for the build coroutine's yieldable texinfo lookup rather
            -- than forcing the whole thing synchronously from a draw call.
            if not isMatByTexinfoReady() then continue end
            local now = SysTime()
            buildDeadline = buildDeadline or (now + BRUSH_BUILD_FRAME_BUDGET)
            if now > buildDeadline then continue end
            meshes = self:GetBrushModelMeshes(rec.idx1)
        end
        if not meshes then continue end
        if meshes.atlasMark then
            if not MapCache.atlasFilled(meshes.atlasMark) then continue end
            if not effectActive and not atlasStaged then
                atlasStaged = MapCache.atlasBeginUnclipped()
                if not atlasStaged then continue end
            end
        end

        mtx:Identity()
        mtx:SetTranslation(entPos)
        mtx:SetAngles(rec.ang)
        cam.PushModelMatrix(mtx, true)
            if effectActive then
                effectOk, effectErr = pcall(
                    HoloEffects.DrawMeshList, meshes, depthWriteFilter)
            else
                drawBrushMeshList(meshes)
            end
        cam.PopModelMatrix()

        if not effectOk then break end
    end
    if atlasStaged then MapCache.atlasEndUnclipped() end

    if effectActive and not HoloEffects.EndDraw(effectOk, effectErr) then
        -- MarkFailed disables the effect, so this retry takes the ordinary
        -- material path and leaves the map dressing visible this frame.
        if not translucentPass then self:DrawBrushEntities(false) end
    end
end
