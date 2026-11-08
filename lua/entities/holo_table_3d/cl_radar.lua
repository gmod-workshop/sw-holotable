-- Radar subsystem: module loader + ENT lifecycle hooks. Drop a file in
-- entities/holo_table_3d/radar/ defining RADAR:Initialize/Think/Draw/OnRemove.

local EntityDefinition = ENT
local HoloEffects = EntityDefinition.HoloEffects

--- @class RadarBase
--- @field entity Entity Owning holo_table_3d.
--- @field entityTable table Cached self:GetTable() of the owning entity.
--- Base inherited by every radar module. Per-entity instances see
--- self = inst -> mod -> RadarBase, so module bodies have these accessors.
local RadarBase = {}
RadarBase.__index = RadarBase
RadarBase.HoloEffects = EntityDefinition.HoloEffects
local radarLodCvar = CreateClientConVar('holo_table_radar_lod', '0', true, false,
    'Radar detail: 0 full models, 1 low-detail markers, 2 disabled.')

--- @return Entity table The owning holo_table_3d entity.
function RadarBase:GetEntity() return self.entity end

--- @return number invScale Inverse of the table's Scale; multiply BSP-space lengths by this.
function RadarBase:GetScale()  return self.entityTable._holoInvScale end

--- @return Vector world Hologram origin in world space (current frame).
function RadarBase:GetOrigin() return self.entityTable._holoOrigin end

--- @return Angle world Hologram angles in world space (current frame).
function RadarBase:GetAngles() return self.entityTable._holoAngles end

--- @return number lod 0 full models, 1 markers, 2 disabled.
function RadarBase:GetLOD() return math.Clamp(radarLodCvar:GetInt(), 0, 2) end

--- Conservative BSP-space sphere test against the current holo cylinder.
--- Avoids model animation/draw work that the stencil would discard anyway.
--- @param pos Vector BSP-space center.
--- @param radius number? BSP-space bounding radius.
--- @return boolean visible
function RadarBase:IsVisible(pos, radius)
    local e = self.entityTable
    radius = radius or 0
    local px, py, pz = pos.x, pos.y, pos.z
    local axisX, axisY, axisZ = e._holoAxis:Unpack()
    local panX, panY, panZ = e._holoPanHoriz:Unpack()
    local along = px * axisX + py * axisY + pz * axisZ
    local hx = px - axisX * along - panX
    local hy = py - axisY * along - panY
    local hz = pz - axisZ * along - panZ
    local bound = e._holoCylRadius + radius
    return hx * hx + hy * hy + hz * hz <= bound * bound
        and along + radius >= e._holoFloorOffset
end

local atan2, sqrt = math.atan2, math.sqrt
local cos, sin    = math.cos, math.sin
local DEG2RAD     = math.pi / 180
local RAD2DEG     = 180 / math.pi

-- Module-level scratch reused across every Project call. Lifetime contract:
-- the returned Vector/Angle are valid only until the next Project on any
-- radar instance; every consumer reads them immediately.
local PROJ_POS    = Vector()
local PROJ_ANG    = Angle()

--- Maps a BSP-space (pos, ang) into the hologram's world-space slot.
--- Only valid inside a module's Draw (the _holo* fields are staged for the
--- current frame by then). Returns shared scratch -- read immediately.
--- @param pos Vector BSP-space position.
--- @param ang Angle? BSP-space angles (optional).
--- @return Vector worldPos
--- @return Angle? worldAng
function RadarBase:Project(pos, ang)
    local e   = self.entityTable
    local s   = e._holoInvScale
    local lx, ly, lz = pos.x * s, pos.y * s, pos.z * s
    local tFx, tFy, tFz = e._holoFx, e._holoFy, e._holoFz
    local tRx, tRy, tRz = e._holoRx, e._holoRy, e._holoRz
    local tUx, tUy, tUz = e._holoUx, e._holoUy, e._holoUz
    PROJ_POS:SetUnpacked(
        e._holoOx + tFx * lx - tRx * ly + tUx * lz,
        e._holoOy + tFy * lx - tRy * ly + tUy * lz,
        e._holoOz + tFz * lx - tRz * ly + tUz * lz)
    if not ang then return PROJ_POS end

    -- Build the input angle's basis directly from cos/sin (Source mathlib).
    local sp, cp = sin(ang.p * DEG2RAD), cos(ang.p * DEG2RAD)
    local sy, cy = sin(ang.y * DEG2RAD), cos(ang.y * DEG2RAD)
    local sr, cr = sin(ang.r * DEG2RAD), cos(ang.r * DEG2RAD)
    local pFx, pFy, pFz =  cp * cy,             cp * sy,             -sp
    local pRx, pRy, pRz = -sr * sp * cy + cr * sy, -sr * sp * sy - cr * cy, -sr * cp
    local pUx, pUy, pUz =  cr * sp * cy + sr * sy,  cr * sp * sy - sr * cy,  cr * cp

    -- Compose with the table basis; only the components needed for Euler.
    local wFx = tFx * pFx - tRx * pFy + tUx * pFz
    local wFy = tFy * pFx - tRy * pFy + tUy * pFz
    local wFz = tFz * pFx - tRz * pFy + tUz * pFz
    local wRz = tFz * pRx - tRz * pRy + tUz * pRz
    local wUz = tFz * pUx - tRz * pUy + tUz * pUz
    PROJ_ANG:SetUnpacked(
        atan2(-wFz, sqrt(wFx * wFx + wFy * wFy)) * RAD2DEG,
        atan2(wFy, wFx) * RAD2DEG,
        atan2(-wRz, wUz) * RAD2DEG)
    return PROJ_POS, PROJ_ANG
end

local registry = {}

--- Walks radar/*.lua, temporarily sets _G.RADAR to a fresh per-module table
--- chained to RadarBase, includes the file, and pushes the populated module
--- onto the registry. Whatever _G.RADAR held before is restored afterwards:
--- other addons and maps use that global too (gm_gmall_2 defines
--- `RADAR = {}` and calls RADAR:Draw() every frame), so clearing it to nil
--- broke them.
local function loadModules()
    registry = {}
    local previousRadar = rawget(_G, 'RADAR')
    for _, fname in ipairs(file.Find('entities/holo_table_3d/radar/*.lua', 'LUA')) do
        local mod = setmetatable({}, RadarBase)
        mod.__index = mod
        _G.RADAR = mod
        local ok, err = pcall(include, 'entities/holo_table_3d/radar/' .. fname)
        _G.RADAR = previousRadar
        if not ok then
            MsgC(Color(255, 120, 120),
                '[holo_table] radar module ' .. fname .. ' failed to load: ' .. tostring(err) .. '\n')
            continue
        end
        mod.Name = mod.Name or string.StripExtension(fname)
        table.insert(registry, mod)
    end
end

loadModules()

--- Builds one instance per registered module on self.Radars.
--- Lookup chain is inst -> mod -> RadarBase.
function ENT:InitializeRadar()
    local selfTbl = self:GetTable()
    selfTbl.Radars = {}
    for _, mod in ipairs(registry) do
        local inst = setmetatable({ entity = self, entityTable = selfTbl }, mod)
        if isfunction(inst.Initialize) then inst:Initialize() end
        selfTbl.Radars[mod.Name] = inst
    end
end

--- Iterates every module's Think. Lazy-inits if Radars is missing so live
--- reload against an already-spawned entity doesn't crash.
function ENT:ThinkRadar()
    local selfTbl = self:GetTable()
    if not selfTbl.Radars then self:InitializeRadar() end
    for _, inst in pairs(selfTbl.Radars) do
        if isfunction(inst.Think) then inst:Think() end
    end
end

--- Iterates every module's Draw. Runs outside the m2 matrix block in
--- DrawHologram because Entity:DrawModel ignores cam matrices.
--- @see ENT:DrawHologram
--- @see RadarBase:Project
local drawFailureWarned = {}
local function drawRadar(inst)
    inst:Draw()
end

function ENT:DrawRadar()
    if radarLodCvar:GetInt() >= 2 then return end
    local selfTbl = self:GetTable()
    if HoloEffects.IsPoweredOff(selfTbl) then return end
    local radars = selfTbl.Radars
    if not radars then return end
    for name, inst in pairs(radars) do
        if not isfunction(inst.Draw) then continue end

        local ok, err = pcall(drawRadar, inst)
        if ok then continue end

        -- Keep one broken/just-reloaded module from aborting DrawHologram and
        -- leaking its outer clip planes and texture filters into the frame.
        render.MaterialOverride(nil)
        render.MaterialOverrideByIndex()
        render.SetBlend(1)
        render.SetColorModulation(1, 1, 1)
        render.SuppressEngineLighting(false)

        if drawFailureWarned[name] then continue end
        drawFailureWarned[name] = true
        ErrorNoHalt(string.format('[holo_table] Radar %s draw failed: %s\n',
            tostring(name), tostring(err)))
    end
end

function ENT:CleanupRadar()
    local selfTbl = self:GetTable()
    if not selfTbl.Radars then return end
    for _, inst in pairs(selfTbl.Radars) do
        if isfunction(inst.OnRemove) then inst:OnRemove() end
    end
    selfTbl.Radars = nil
end

concommand.Remove('holo_table_radar_reload')
concommand.Add('holo_table_radar_reload', function()
    loadModules()

    local count = 0
    for _, ent in ents.Iterator() do
        if ent:GetClass() ~= 'holo_table_3d' then continue end
        if not (ent.CleanupRadar and ent.InitializeRadar) then continue end

        -- Existing entity userdata can retain its old method table through a
        -- manual include; call this file's fresh closures explicitly.
        EntityDefinition.CleanupRadar(ent)
        EntityDefinition.InitializeRadar(ent)
        count = count + 1
    end

    print('[holo_table] reloaded radar modules for ' .. count .. ' table(s)')
end)
