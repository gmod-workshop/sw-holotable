-- Model radar for non-LVS vehicles (LFS, simfphys, SW vehicles, etc.).

local HoloEffects = RADAR.HoloEffects
local RadarProxy = HoloEffects.RadarProxy
local MARKER_FRIENDLY = Color(115, 165, 255, 240)
local MARKER_HOSTILE = Color(255, 115, 115, 240)
local MARKER_NEUTRAL = Color(119, 145, 190, 240)
local MODEL_NEUTRAL = Color(102, 159, 255, 240)
local SOURCE_SCAN_INTERVAL = 1 / 15
local sourceCache = {}
local sourceCacheTime = -math.huge
local TRAIL_SAMPLE_DIST_SQR = 48 * 48
local TRAIL_MAX_POINTS = 18

local function isOtherVehicle(ent)
    return not ent.LVS and (ent.LFS or ent.IsSWVehicle or ent.IsSWVRVehicle
        or ent.IsSimfphyscar or ent.IsScar)
end

local function vehicleTeam(ent)
    if ent.GetAITEAM then return ent:GetAITEAM() or 0 end
    return ent.AITEAM or 0
end

local function markerColorFor(tableTeam, entTeam)
    if tableTeam == 0 or entTeam == 0 then
        return HoloEffects.GetHologramColor(MARKER_NEUTRAL, 240)
    end
    if tableTeam == entTeam then return MARKER_FRIENDLY end
    return MARKER_HOSTILE
end

local function modelColorFor(tableTeam, entTeam)
    if tableTeam == 0 or entTeam == 0 then
        return HoloEffects.GetHologramFillColor(MODEL_NEUTRAL, 240)
    end
    if tableTeam == entTeam then return MARKER_FRIENDLY end
    return MARKER_HOSTILE
end

local function contactStatusFor(tableTeam, entTeam)
    if tableTeam == 0 or entTeam == 0 then return 'VEHICLE' end
    if tableTeam == entTeam then return 'FRIENDLY' end
    return 'HOSTILE'
end

local function contactName(ent)
    local name = ent.PrintName
    if isstring(name) and name ~= '' then return name end
    local class = ent:GetClass()
    local phrase = language.GetPhrase(class)
    return phrase ~= class and phrase or class
end

local function getOtherVehicleSources()
    local now = SysTime()
    if now - sourceCacheTime < SOURCE_SCAN_INTERVAL then return sourceCache end

    local fresh = {}
    for _, ent in ents.Iterator() do
        if isOtherVehicle(ent) then fresh[#fresh + 1] = ent end
    end
    sourceCache = fresh
    sourceCacheTime = now
    return sourceCache
end

local function makeMirror(model)
    local cs = ents.CreateClientProp(model)
    if not IsValid(cs) then return nil end
    cs:SetNoDraw(true)
    cs:SetSolid(SOLID_NONE)
    cs:SetMoveType(MOVETYPE_NONE)
    cs:PhysicsDestroy()
    if cs.SetLOD and RadarProxy then cs:SetLOD(RadarProxy.GetForcedLOD()) end
    return cs
end

local function removeRecord(rec)
    if rec and IsValid(rec.csent) then SafeRemoveEntity(rec.csent) end
end

local function syncRecord(rec)
    local ent, cs = rec.ent, rec.csent
    if not (IsValid(ent) and IsValid(cs)) then return end

    local skin = ent:GetSkin() or 0
    if rec.skin ~= skin then
        cs:SetSkin(skin)
        rec.skin = skin
    end

    local bodyMask = RadarProxy and RadarProxy.GetBodygroupMask(ent) or 0
    if rec.bodyMask ~= bodyMask then
        for id = 0, ent:GetNumBodyGroups() - 1 do
            cs:SetBodygroup(id, ent:GetBodygroup(id))
        end
        rec.bodyMask = bodyMask
    end

    if RadarProxy then
        local lod = RadarProxy.GetForcedLOD()
        if rec.modelLOD ~= lod and cs.SetLOD then
            cs:SetLOD(lod)
            rec.modelLOD = lod
        end
        rec.proxy = RadarProxy.Request(rec.model, bodyMask)
    end
end

local function updateTrail(rec, now)
    local pos = rec.ent:GetPos()
    local trail = rec.trail
    local last = trail[#trail]
    if not last or last.pos:DistToSqr(pos) >= TRAIL_SAMPLE_DIST_SQR then
        trail[#trail + 1] = { pos = Vector(pos.x, pos.y, pos.z), time = now }
    end

    local cutoff = now - HoloEffects.cvars.contactTrailTime:GetFloat()
    while trail[1] and (trail[1].time < cutoff or #trail > TRAIL_MAX_POINTS) do
        table.remove(trail, 1)
    end
end

function RADAR:Initialize()
    self.Tracked = {}
end

function RADAR:Think()
    local old = self.Tracked or {}
    local fresh = {}
    local sources = getOtherVehicleSources()
    local now = CurTime()

    for i = 1, #sources do
        local ent = sources[i]
        if not IsValid(ent) then continue end
        local model = ent:GetModel()
        if not isstring(model) or model == '' then continue end

        local idx = ent:EntIndex()
        local rec = old[idx]
        if not rec or rec.ent ~= ent or rec.model ~= model
            or not IsValid(rec.csent) then
            removeRecord(rec)
            local cs = makeMirror(model)
            if not IsValid(cs) then continue end
            rec = {
                ent = ent,
                csent = cs,
                model = model,
                detectedAt = now,
                trail = {},
            }
        end

        rec.visRadius = ent:BoundingRadius() + ent:OBBCenter():Length()
        syncRecord(rec)
        updateTrail(rec, now)
        fresh[idx] = rec
    end

    for idx, rec in pairs(old) do
        if not fresh[idx] then removeRecord(rec) end
    end
    self.Tracked = fresh
end

function RADAR:Draw()
    local tableTeam = self:GetEntity():GetTeam()
    local invScale = self:GetScale()
    render.SuppressEngineLighting(true)

    for _, rec in pairs(self.Tracked) do
        local ent, cs = rec.ent, rec.csent
        if not (IsValid(ent) and IsValid(cs)) then continue end
        local pos = ent:GetPos()
        if not self:IsVisible(pos, rec.visRadius or 64) then continue end

        local entTeam = vehicleTeam(ent)
        local markerColor = markerColorFor(tableTeam, entTeam)
        local modelColor = modelColorFor(tableTeam, entTeam)
        local phase = ent:EntIndex() * 0.47
        local appearance = HoloEffects.GetContactReveal(self.entityTable,
            phase, rec.detectedAt)
        local markerRadius = math.Clamp((rec.visRadius or 64) * invScale
            * 0.35, 1.5, 7)
        local markerHeight = math.Clamp((rec.visRadius or 64) * invScale
            * 1.2, 4, 16)
        local wpos, wang = self:Project(pos, ent:GetAngles())

        if self:GetLOD() == 1 then
            render.SetColorMaterial()
            render.SetBlend(appearance)
            render.DrawSphere(wpos, math.max(markerRadius * 0.7, 1.2),
                8, 8, markerColor)
            render.SetBlend(1)
            continue
        end

        if rec.proxy and rec.proxy.state == 'proxy'
            and rec.materializedProxy ~= rec.proxy then
            rec.materializedProxy = rec.proxy
            rec.materializeAt = CurTime()
        end
        appearance = HoloEffects.GetContactReveal(self.entityTable, phase,
            rec.materializeAt or rec.detectedAt)
        local flicker = appearance < 0.98 and (0.86
            + math.sin(CurTime() * 38 + phase * 5.3) * 0.14) or 1
        local visibility = appearance * flicker
        local projectionScale = 0.8 + appearance * 0.2
        local proxyDrawn = RadarProxy and RadarProxy.Draw(rec.proxy, wpos,
            wang, invScale * projectionScale, modelColor, self.entityTable,
            visibility, appearance)

        if not proxyDrawn then
            if RadarProxy and RadarProxy.ShouldUseMarker(rec.proxy) then
                render.SetColorMaterial()
                render.SetBlend(visibility)
                render.DrawSphere(wpos, math.max(markerRadius * 0.7, 1.2),
                    8, 8, markerColor)
                render.SetBlend(1)
            else
                cs:SetPos(wpos)
                cs:SetAngles(wang)
                cs:SetModelScale(invScale * projectionScale, 0)
                cs:SetupBones()
                if not HoloEffects.DrawContactModel(self.entityTable, cs,
                    modelColor, phase, visibility, appearance) then
                    render.SetColorModulation(modelColor.r / 255,
                        modelColor.g / 255, modelColor.b / 255)
                    render.SetBlend(visibility)
                    cs:DrawModel()
                    render.SetBlend(1)
                    render.SetColorModulation(1, 1, 1)
                end
            end
        end

        HoloEffects.DrawContactMarker(self.entityTable, wpos, markerColor,
            markerRadius, markerHeight, phase, appearance)
        HoloEffects.DrawContactPing(self.entityTable, wpos, markerColor,
            CurTime() - rec.detectedAt, markerRadius, appearance)
        HoloEffects.DrawContactLabel(self.entityTable, wpos, markerColor,
            markerHeight + 1, contactName(ent),
            contactStatusFor(tableTeam, entTeam), appearance)
        HoloEffects.DrawContactTrail(self, rec.trail, markerColor, appearance)
    end

    render.SetBlend(1)
    render.SetColorModulation(1, 1, 1)
    render.SuppressEngineLighting(false)
end

function RADAR:OnRemove()
    for _, rec in pairs(self.Tracked or {}) do removeRecord(rec) end
    self.Tracked = nil
end
