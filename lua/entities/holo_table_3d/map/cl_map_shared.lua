-- Shared state for the map subsystem. Inter-file state lives on ENT.MapCache.

local previousCleanup = _G.HOLO_TABLE_3D_CL_MAP_CLEANUP
if type(previousCleanup) == 'function' then
    local ok, err = pcall(previousCleanup)
    if not ok then ErrorNoHaltWithStack(err) end
end
_G.HOLO_TABLE_3D_CL_MAP_CLEANUP = nil

ENT.MapCache = {}
local MapCache = ENT.MapCache
local MapCacheEntity = ENT

-- Whole-generation scratch reused by every prop draw path.
MapCache.PROP_DRAW_SCRATCH_POS = Vector()
MapCache.PROP_DRAW_SCRATCH_ANG = Angle()

--- Destroys a single mesh-bearing item, swallowing IMesh:Destroy errors.
--- @param item table?
function ENT:_SafeDestroyMesh(item)
    if not item or not item.mesh then return end
    pcall(item.mesh.Destroy, item.mesh)
    item.mesh = nil
end

--- Destroys every mesh in a list of {mat=..., mesh=IMesh} records.
--- @param list table[]?
function MapCache.destroyMeshList(list)
    if not list then return end
    for _, item in ipairs(list) do
        MapCacheEntity._SafeDestroyMesh(MapCacheEntity, item)
    end
end

--- Builds an IMesh from a flat triangle vertex list. Vertices are
--- {pos=Vector, normal?=Vector, u?=number, v?=number, color?=Color}.
--- @param verts table[]
--- @return IMesh? mesh nil if fewer than 3 vertices.
function MapCache.buildMeshFromTriangles(verts)
    local vertCount = #verts
    if vertCount < 3 then return nil end
    vertCount = vertCount - (vertCount % 3)

    local msh = Mesh()
    mesh.Begin(msh, MATERIAL_TRIANGLES, vertCount / 3)
    for i = 1, vertCount do
        local v = verts[i]
        mesh.Position(v.pos)
        if v.normal then mesh.Normal(v.normal) end
        mesh.TexCoord(0, v.u or 0, v.v or 0)
        if v.color then
            local c = v.color
            mesh.Color(c.r or 255, c.g or 255, c.b or 255, c.a or 255)
        end
        mesh.AdvanceVertex()
    end
    mesh.End()

    return msh
end

local FLAT_VERTEX_STRIDE = 8
local FLAT_MESH_POS = Vector()
local FLAT_MESH_NORMAL = Vector()

--- Builds an IMesh from packed px,py,pz,nx,ny,nz,u,v values. Prop bakes
--- use this to avoid allocating a table plus two Vectors for every vertex.
--- @param verts number[]
--- @return IMesh? mesh
function MapCache.buildMeshFromFlatTriangles(verts)
    local vertCount = math.floor(#verts / FLAT_VERTEX_STRIDE)
    vertCount = vertCount - (vertCount % 3)
    if vertCount < 3 then return nil end

    local msh = Mesh()
    mesh.Begin(msh, MATERIAL_TRIANGLES, vertCount / 3)
    local offset = 1
    for _ = 1, vertCount do
        FLAT_MESH_POS:SetUnpacked(verts[offset], verts[offset + 1], verts[offset + 2])
        FLAT_MESH_NORMAL:SetUnpacked(verts[offset + 3], verts[offset + 4], verts[offset + 5])
        mesh.Position(FLAT_MESH_POS)
        mesh.Normal(FLAT_MESH_NORMAL)
        mesh.TexCoord(0, verts[offset + 6] or 0, verts[offset + 7] or 0)
        mesh.AdvanceVertex()
        offset = offset + FLAT_VERTEX_STRIDE
    end
    mesh.End()

    return msh
end

MapCache.FLAT_VERTEX_STRIDE = FLAT_VERTEX_STRIDE

--- Reorders a {mat, mesh} list in place so items sharing a material are
--- adjacent (stable, first-appearance order). Draw loops then skip the
--- redundant render.SetMaterial calls; bakes append a group's meshes at
--- different times, so the raw order interleaves materials.
--- @param list table[]
function MapCache.sortMeshListByMaterial(list)
    if not list or #list < 2 then return end
    local buckets, order = {}, {}
    for i = 1, #list do
        local item = list[i]
        local bucket = buckets[item.mat]
        if not bucket then
            bucket = {}
            buckets[item.mat] = bucket
            order[#order + 1] = bucket
        end
        bucket[#bucket + 1] = item
    end
    local n = 0
    for b = 1, #order do
        local bucket = order[b]
        for j = 1, #bucket do
            n = n + 1
            list[n] = bucket[j]
        end
    end
end
