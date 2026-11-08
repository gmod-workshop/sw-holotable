-- Shared radar-model LOD/proxy cache. Authored low LODs stay as normal model
-- draws; exceptionally dense models are reduced to a static, rotatable IMesh.

local Effects = ENT.HoloEffects

if isfunction(_G.HOLO_TABLE_3D_RADAR_PROXY_CLEANUP) then
    _G.HOLO_TABLE_3D_RADAR_PROXY_CLEANUP()
end

local Proxy = {}
Effects.RadarProxy = Proxy

local cvars = {
    enabled = CreateClientConVar('holo_table_radar_model_proxy', '1', true, false,
        'Generate cached 3D proxies for radar models whose lowest authored LOD is still too dense.'),
    lod = CreateClientConVar('holo_table_radar_model_lod', '8', true, false,
        'Authored model LOD forced on full-model radar contacts.', 0, 8),
    threshold = CreateClientConVar('holo_table_radar_proxy_vertex_threshold', '60000', true, false,
        'Lowest-LOD vertex count above which a generated proxy is used.', 12000, 300000),
    triangles = CreateClientConVar('holo_table_radar_proxy_triangles', '8000', true, false,
        'Approximate triangle budget for each generated radar proxy.', 1000, 18000),
    disk = CreateClientConVar('holo_table_radar_proxy_disk_cache', '1', true, false,
        'Persist generated radar proxies in the client data folder.'),
}
Proxy.cvars = cvars

local CACHE_VERSION = 3
local CACHE_DIR = 'holo_table/radar_proxies'
local THINK_HOOK = 'holo_table_3d.radar_proxy_builder'
local FRAME_BUDGET = 0.003
local FLAT_STRIDE = 6
local MAX_MESH_VERTS = 18000 -- comfortably below IMesh's 65,535 limit

local entries = {}
local queue = {}
local active
-- Wait for a real draw; map startup can reset early material constants.
local material
local DRAW_MATRIX = Matrix()
local DRAW_SCALE = Vector(1, 1, 1)

local math_floor = math.floor
local math_sqrt = math.sqrt
local math_max = math.max
local math_min = math.min
local table_remove = table.remove

local function destroyMeshes(meshes)
    for i = 1, #(meshes or {}) do
        local msh = meshes[i]
        if msh and msh.Destroy and (not msh.IsValid or msh:IsValid()) then
            msh:Destroy()
        end
    end
end

local function cleanup()
    hook.Remove('Think', THINK_HOOK)
    for _, entry in pairs(entries) do
        destroyMeshes(entry.meshes)
    end
    entries = {}
    queue = {}
    active = nil
end
_G.HOLO_TABLE_3D_RADAR_PROXY_CLEANUP = cleanup

local function modelChecksum(model)
    local info = util.GetModelInfo(model)
    return info and tostring(info.Checksum or '') or ''
end

local function entryIdentity(model, bodyMask)
    local lod = math.Clamp(cvars.lod:GetInt(), 0, 8)
    local threshold = cvars.threshold:GetInt()
    local target = cvars.triangles:GetInt()
    local key = table.concat({
        CACHE_VERSION,
        string.lower(model),
        modelChecksum(model),
        bodyMask or 0,
        lod,
        threshold,
        target,
    }, '|')
    return key, lod, threshold, target
end

local function cachePath(key)
    return CACHE_DIR .. '/' .. util.CRC(key) .. '.dat'
end

local function saveCache(entry, payload)
    if not cvars.disk:GetBool() then return end
    payload.key = entry.key
    local json = util.TableToJSON(payload, false)
    if not json then return end
    local packed = util.Compress(json)
    if not packed then return end
    file.CreateDir(CACHE_DIR)
    file.Write(entry.path, packed)
end

local function loadCache(entry)
    if not cvars.disk:GetBool() or not file.Exists(entry.path, 'DATA') then return nil end
    local packed = file.Read(entry.path, 'DATA')
    local json = packed and util.Decompress(packed)
    local data = json and util.JSONToTable(json, true)
    if not data or data.key ~= entry.key then return nil end
    if data.kind == 'native' then return data end
    if data.kind ~= 'proxy' or not istable(data.verts)
        or #data.verts < 18 or #data.verts % 18 ~= 0 then
        return nil
    end
    return data
end

local function buildMeshes(flat, budgetYield)
    local result = {}
    local totalVerts = #flat / FLAT_STRIDE
    local first = 1
    while first <= totalVerts do
        budgetYield(true)
        local vertexCount = math_min(MAX_MESH_VERTS, totalVerts - first + 1)
        vertexCount = vertexCount - vertexCount % 3
        if vertexCount <= 0 then break end

        local msh = Mesh(material)
        mesh.Begin(msh, MATERIAL_TRIANGLES, vertexCount / 3)
        local last = first + vertexCount - 1
        for vi = first, last do
            local at = (vi - 1) * FLAT_STRIDE + 1
            mesh.Position(Vector(flat[at], flat[at + 1], flat[at + 2]))
            mesh.Normal(Vector(flat[at + 3], flat[at + 4], flat[at + 5]))
            mesh.TexCoord(0, 0, 0)
            mesh.Color(255, 255, 255, 255)
            mesh.AdvanceVertex()
        end
        mesh.End()
        result[#result + 1] = msh
        first = last + 1
    end
    return result
end

local function quantizedKey(pos, minx, miny, minz, invCell)
    -- util.GetModelMeshes exposes studio-mesh coordinates before the engine's
    -- model-space axis conversion. Entity model space is +90 degrees around Z:
    -- model X = -raw Y, model Y = raw X. Without this, generated vehicles face
    -- sideways even though their entity angle is correct.
    local x, y = -pos.y, pos.x
    return math_floor((x - minx) * invCell + 0.5) .. ','
        .. math_floor((y - miny) * invCell + 0.5) .. ','
        .. math_floor((pos.z - minz) * invCell + 0.5)
end

local function canonicalTriangleKey(a, b, c)
    if a > b then a, b = b, a end
    if b > c then b, c = c, b end
    if a > b then a, b = b, a end
    return a .. '|' .. b .. '|' .. c
end

local function countClusteredTriangles(modelMeshes, minx, miny, minz, cell,
    limit, budgetYield)
    local invCell = 1 / cell
    local seen = {}
    local count = 0
    local visited = 0
    for mi = 1, #modelMeshes do
        local tris = modelMeshes[mi].triangles or {}
        for i = 1, #tris - 2, 3 do
            local a = quantizedKey(tris[i].pos, minx, miny, minz, invCell)
            local b = quantizedKey(tris[i + 1].pos, minx, miny, minz, invCell)
            local c = quantizedKey(tris[i + 2].pos, minx, miny, minz, invCell)
            if a ~= b and b ~= c and a ~= c then
                local key = canonicalTriangleKey(a, b, c)
                if not seen[key] then
                    seen[key] = true
                    count = count + 1
                    if count >= limit then return count end
                end
            end
            visited = visited + 3
            if visited % 3072 == 0 then budgetYield() end
        end
    end
    return count
end

local function buildClusteredVertices(modelMeshes, minx, miny, minz, cell,
    budgetYield)
    local invCell = 1 / cell
    local clusters = {}
    local visited = 0

    -- Average positions and source normals inside each spatial cell. This is a
    -- vertex-clustering simplifier: topology remains genuinely 3D while tiny
    -- details collapse into a much smaller surface.
    for mi = 1, #modelMeshes do
        local tris = modelMeshes[mi].triangles or {}
        for i = 1, #tris do
            local vert = tris[i]
            local key = quantizedKey(vert.pos, minx, miny, minz, invCell)
            local cluster = clusters[key]
            if not cluster then
                cluster = { 0, 0, 0, 0, 0, 0, 0 }
                clusters[key] = cluster
            end
            local pos = vert.pos
            local normal = vert.normal
            cluster[1] = cluster[1] - pos.y
            cluster[2] = cluster[2] + pos.x
            cluster[3] = cluster[3] + pos.z
            if normal then
                cluster[4] = cluster[4] - normal.y
                cluster[5] = cluster[5] + normal.x
                cluster[6] = cluster[6] + normal.z
            end
            cluster[7] = cluster[7] + 1
            visited = visited + 1
            if visited % 3072 == 0 then budgetYield() end
        end
    end

    for _, cluster in pairs(clusters) do
        local inv = 1 / cluster[7]
        cluster[1], cluster[2], cluster[3] = cluster[1] * inv,
            cluster[2] * inv, cluster[3] * inv
        local nx, ny, nz = cluster[4], cluster[5], cluster[6]
        local len = math_sqrt(nx * nx + ny * ny + nz * nz)
        if len > 1e-6 then
            cluster[4], cluster[5], cluster[6] = nx / len, ny / len, nz / len
        end
    end
    budgetYield()

    local flat = {}
    local seen = {}
    local triangleCount = 0
    visited = 0
    local function append(cluster, fnx, fny, fnz)
        local nx, ny, nz = cluster[4], cluster[5], cluster[6]
        if nx * nx + ny * ny + nz * nz < 0.01 then nx, ny, nz = fnx, fny, fnz end
        flat[#flat + 1] = cluster[1]
        flat[#flat + 1] = cluster[2]
        flat[#flat + 1] = cluster[3]
        flat[#flat + 1] = nx
        flat[#flat + 1] = ny
        flat[#flat + 1] = nz
    end

    for mi = 1, #modelMeshes do
        local tris = modelMeshes[mi].triangles or {}
        for i = 1, #tris - 2, 3 do
            local ak = quantizedKey(tris[i].pos, minx, miny, minz, invCell)
            local bk = quantizedKey(tris[i + 1].pos, minx, miny, minz, invCell)
            local ck = quantizedKey(tris[i + 2].pos, minx, miny, minz, invCell)
            if ak ~= bk and bk ~= ck and ak ~= ck then
                local triKey = canonicalTriangleKey(ak, bk, ck)
                if not seen[triKey] then
                    local a, b, c = clusters[ak], clusters[bk], clusters[ck]
                    local abx, aby, abz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
                    local acx, acy, acz = c[1] - a[1], c[2] - a[2], c[3] - a[3]
                    local nx = aby * acz - abz * acy
                    local ny = abz * acx - abx * acz
                    local nz = abx * acy - aby * acx
                    local len = math_sqrt(nx * nx + ny * ny + nz * nz)
                    if len > 1e-5 then
                        nx, ny, nz = nx / len, ny / len, nz / len
                        seen[triKey] = true
                        append(a, nx, ny, nz)
                        append(b, nx, ny, nz)
                        append(c, nx, ny, nz)
                        triangleCount = triangleCount + 1
                    end
                end
            end
            visited = visited + 3
            if visited % 3072 == 0 then budgetYield() end
        end
    end
    return flat, triangleCount
end

local function generateProxy(entry, modelMeshes, budgetYield)
    local minx, miny, minz = math.huge, math.huge, math.huge
    local maxx, maxy, maxz = -math.huge, -math.huge, -math.huge
    local visited = 0
    for mi = 1, #modelMeshes do
        local tris = modelMeshes[mi].triangles or {}
        for i = 1, #tris do
            local pos = tris[i].pos
            local x, y = -pos.y, pos.x
            minx, miny, minz = math_min(minx, x), math_min(miny, y), math_min(minz, pos.z)
            maxx, maxy, maxz = math_max(maxx, x), math_max(maxy, y), math_max(maxz, pos.z)
            visited = visited + 1
            if visited % 4096 == 0 then budgetYield() end
        end
    end

    local extent = math_max(maxx - minx, maxy - miny, maxz - minz)
    if extent <= 0 then return nil, 0 end
    local target = entry.target
    local cell = extent / math_max(8, math_sqrt(target * 0.75))
    local count = 0
    for _ = 1, 5 do
        count = countClusteredTriangles(modelMeshes, minx, miny, minz,
            cell, target * 4 + 1, budgetYield)
        if count >= target * 0.72 and count <= target * 1.12 then break end
        local ratio = math_sqrt(math_max(count, 1) / target)
        cell = cell * math.Clamp(ratio, 0.7, 2.2)
        budgetYield()
    end

    return buildClusteredVertices(modelMeshes, minx, miny, minz, cell,
        budgetYield)
end

local function runEntry(entry)
    local deadline = SysTime() + FRAME_BUDGET
    local function budgetYield(force)
        if not force and SysTime() <= deadline then return end
        coroutine.yield()
        deadline = SysTime() + FRAME_BUDGET
    end

    local cached = loadCache(entry)
    if cached then
        entry.inputVerts = tonumber(cached.inputVerts) or 0
        if cached.kind == 'native' then
            entry.state = 'native'
            return
        end
        entry.state = 'building_proxy'
        entry.highPoly = true
        entry.outputTriangles = #cached.verts / 18
        entry.meshes = buildMeshes(cached.verts, budgetYield)
        entry.state = 'proxy'
        MsgC(Color(120, 220, 255), string.format(
            '[holo_table] loaded radar proxy: %s (%d triangles)\n',
            entry.model, entry.outputTriangles))
        return
    end

    entry.state = 'extracting'
    -- This engine call is synchronous. The queue guarantees no more than one
    -- model extraction is issued in a frame; all Lua simplification after it
    -- obeys the small per-frame budget above.
    local modelMeshes = util.GetModelMeshes(entry.model, entry.lod,
        entry.bodyMask, 0)
    if not modelMeshes then error('util.GetModelMeshes failed for ' .. entry.model) end

    local inputVerts = 0
    for i = 1, #modelMeshes do
        inputVerts = inputVerts + #(modelMeshes[i].triangles or {})
    end
    entry.inputVerts = inputVerts
    if inputVerts <= entry.threshold then
        entry.state = 'native'
        saveCache(entry, { kind = 'native', inputVerts = inputVerts })
        MsgC(Color(120, 220, 255), string.format(
            '[holo_table] using authored LOD %d: %s (%d vertices)\n',
            entry.lod, entry.model, inputVerts))
        return
    end

    entry.highPoly = true
    entry.state = 'building_proxy'
    budgetYield(true)
    local flat, triangleCount = generateProxy(entry, modelMeshes, budgetYield)
    modelMeshes = nil
    if not flat or triangleCount <= 0 then error('proxy simplification produced no triangles') end

    entry.outputTriangles = triangleCount
    entry.meshes = buildMeshes(flat, budgetYield)
    saveCache(entry, {
        kind = 'proxy',
        inputVerts = inputVerts,
        outputTriangles = triangleCount,
        verts = flat,
    })
    entry.state = 'proxy'
    MsgC(Color(120, 220, 255), string.format(
        '[holo_table] radar proxy ready: %s (%d -> %d triangles)\n',
        entry.model, math.floor(inputVerts / 3), triangleCount))
end

local function thinkBuilder()
    if not active then
        active = table_remove(queue, 1)
        if not active then
            hook.Remove('Think', THINK_HOOK)
            return
        end
        active.co = coroutine.create(function() runEntry(active) end)
    end

    local ok, err = coroutine.resume(active.co)
    if not ok then
        active.state = 'failed'
        active.error = tostring(err)
        ErrorNoHaltWithStack('[holo_table] radar proxy failed: ' .. active.error)
        active = nil
        return
    end
    if coroutine.status(active.co) == 'dead' then
        active.co = nil
        active = nil
    end
end

--- Mixed-radix bodygroup value used by studio models and GetModelMeshes.
function Proxy.GetBodygroupMask(ent)
    if not IsValid(ent) then return 0 end
    local mask, stride = 0, 1
    for id = 0, ent:GetNumBodyGroups() - 1 do
        mask = mask + ent:GetBodygroup(id) * stride
        stride = stride * math_max(ent:GetBodygroupCount(id), 1)
    end
    return mask
end

function Proxy.GetForcedLOD()
    return math.Clamp(cvars.lod:GetInt(), 0, 8)
end

--- Requests shared classification/proxy work and returns its live state.
function Proxy.Request(model, bodyMask)
    if not cvars.enabled:GetBool() or not model or model == '' then return nil end
    local key, lod, threshold, target = entryIdentity(model, bodyMask)
    local entry = entries[key]
    if entry then return entry end

    entry = {
        key = key,
        path = cachePath(key),
        model = model,
        bodyMask = bodyMask or 0,
        lod = lod,
        threshold = threshold,
        target = target,
        state = 'queued',
    }
    entries[key] = entry
    queue[#queue + 1] = entry
    hook.Add('Think', THINK_HOOK, thinkBuilder)
    return entry
end

function Proxy.ShouldUseMarker(entry)
    return entry and entry.highPoly
        and (entry.state == 'building_proxy' or entry.state == 'failed')
end

--- Draws a ready proxy at a projected contact transform.
function Proxy.Draw(entry, pos, ang, scale, color, selfTbl, opacityScale,
        revealOverride)
    if not entry or entry.state ~= 'proxy' or not entry.meshes then return false end
    material = material or Effects.GetLiteProxyMaterial()
    if not material then return false end
    local drawMaterial = Effects.GetLiteProxyMaterial()
    if not drawMaterial then return false end
    for i = 1, #entry.meshes do
        local msh = entry.meshes[i]
        if not msh or (msh.IsValid and not msh:IsValid()) then return false end
    end

    DRAW_MATRIX:Identity()
    DRAW_MATRIX:SetTranslation(pos)
    DRAW_MATRIX:SetAngles(ang)
    DRAW_SCALE:SetUnpacked(scale, scale, scale)
    DRAW_MATRIX:Scale(DRAW_SCALE)

    local reveal = revealOverride == nil and Effects.GetReveal(selfTbl)
        or revealOverride
    local visibility = opacityScale or 1
    render.SetColorModulation(1, 1, 1)

    if Effects.AreContactHalosEnabled() then
        local haloMaterial = Effects.GetContactHaloProxyMaterial()
        if haloMaterial and Effects.PushContactHaloConstants(selfTbl, color,
            visibility) then
            render.SetMaterial(haloMaterial)
            cam.PushModelMatrix(DRAW_MATRIX)
            for i = 1, #entry.meshes do entry.meshes[i]:Draw() end
            cam.PopModelMatrix()
            Effects.PopConstants()
        end
    end

    if not Effects.PushConstants(selfTbl, true, color, nil, reveal,
        visibility) then return false end
    render.SetMaterial(drawMaterial)
    local bloom = Effects.BeginContactBloom(selfTbl)
    cam.PushModelMatrix(DRAW_MATRIX)
    for i = 1, #entry.meshes do entry.meshes[i]:Draw() end
    cam.PopModelMatrix()
    if bloom then Effects.EndContactBloom(selfTbl) end
    Effects.PopConstants()
    render.SetColorModulation(1, 1, 1)
    return true
end
