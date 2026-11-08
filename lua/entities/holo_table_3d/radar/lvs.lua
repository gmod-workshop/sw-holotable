-- LVS radar: mirror props for any ent with .LVS, AITEAM-tinted relative to
-- the table's team, plus projected LVS bullet tracers from util.Effect.

-- Friendly = same AITEAM as the table; Hostile = different non-zero;
-- Neutral = either side is team 0.
local HoloEffects = RADAR.HoloEffects
local RadarProxy = HoloEffects.RadarProxy
local TINT_FRIENDLY = { 0.45, 0.65, 1.00 }
local TINT_HOSTILE  = { 1.00, 0.45, 0.45 }
local TINT_NEUTRAL  = { 0.47, 0.57, 0.75 }
local MARKER_FRIENDLY = Color(115, 165, 255, 240)
local MARKER_HOSTILE = Color(255, 115, 115, 240)
local MARKER_NEUTRAL = Color(119, 145, 190, 240)
local MODEL_NEUTRAL = Color(102, 159, 255, 240)
local MARKER_RADIUS = 1.5

local function neutralColor()
    HoloEffects.GetHologramColor(MARKER_NEUTRAL, 240)
    TINT_NEUTRAL[1] = MARKER_NEUTRAL.r / 255
    TINT_NEUTRAL[2] = MARKER_NEUTRAL.g / 255
    TINT_NEUTRAL[3] = MARKER_NEUTRAL.b / 255
    return MARKER_NEUTRAL
end

--- @param tableTeam number
--- @param entTeam number
--- @return number[] rgb
local function tintFor(tableTeam, entTeam)
    if tableTeam == 0 or entTeam == 0 then
        neutralColor()
        return TINT_NEUTRAL
    end
    if entTeam == tableTeam then return TINT_FRIENDLY end
    return TINT_HOSTILE
end

local function markerColorFor(tableTeam, entTeam)
    if tableTeam == 0 or entTeam == 0 then return neutralColor() end
    if entTeam == tableTeam then return MARKER_FRIENDLY end
    return MARKER_HOSTILE
end

local function modelColorFor(tableTeam, entTeam)
    if tableTeam == 0 or entTeam == 0 then
        return HoloEffects.GetHologramFillColor(MODEL_NEUTRAL, 240)
    end
    if entTeam == tableTeam then return MARKER_FRIENDLY end
    return MARKER_HOSTILE
end

local function contactStatusFor(tableTeam, entTeam)
    if tableTeam == 0 or entTeam == 0 then return 'NEUTRAL' end
    if entTeam == tableTeam then return 'FRIENDLY' end
    return 'HOSTILE'
end

local function contactName(ent)
    local name = ent.PrintName
    if isstring(name) and name ~= '' then return name end
    local class = ent:GetClass()
    local phrase = language.GetPhrase(class)
    return phrase ~= class and phrase or class
end

local TRACER_MAT_BEAM  = Material('effects/spark')
local TRACER_MAT_GLOW  = Material('sprites/light_glow02_add')
local TRACER_MAX_AGE   = 2
local TRACER_MIN_WIDTH = 0.7
local TRACER_MAX_WIDTH = 3.5
local TRACER_COLORS = {
    red     = Color(255, 80, 70, 230),
    green   = Color(80, 255, 120, 230),
    blue    = Color(100, 170, 255, 230),
    yellow  = Color(255, 230, 90, 230),
    orange  = Color(255, 150, 70, 230),
    white   = Color(240, 250, 255, 230),
    proton  = Color(180, 120, 255, 230),
    default = Color(100, 220, 255, 230),
}
local TRACER_CORE_COLOR = Color(255, 255, 255, 235)
local TRACER_START = Vector()
local TRACER_END = Vector()
local SOURCE_SCAN_INTERVAL = 1 / 15
local sourceCache = {}
local sourceCacheTime = -math.huge
local TRAIL_SAMPLE_DIST_SQR = 48 * 48
local TRAIL_MAX_POINTS = 18

local function updateTrail(rec, now)
    local pos = rec.ent:GetPos()
    local trail = rec.trail
    if not trail then
        trail = {}
        rec.trail = trail
    end

    local last = trail[#trail]
    if not last or last.pos:DistToSqr(pos) >= TRAIL_SAMPLE_DIST_SQR then
        trail[#trail + 1] = { pos = Vector(pos.x, pos.y, pos.z), time = now }
    end

    local cutoff = now - HoloEffects.cvars.contactTrailTime:GetFloat()
    while trail[1] and (trail[1].time < cutoff or #trail > TRAIL_MAX_POINTS) do
        table.remove(trail, 1)
    end
end

local tracerState = _G.HOLO_TABLE_3D_LVS_TRACERS
if tracerState and isfunction(tracerState.restore) then
    tracerState.restore()
end

tracerState = {
    items = {},
    nextPurge = 0,
    activeUsers = 0,
}
_G.HOLO_TABLE_3D_LVS_TRACERS = tracerState

--- @param name string Effect name; substring-matched against known palette keys.
--- @return Color
local function tracerColor(name)
    name = string.lower(tostring(name or ''))
    if name:find('red', 1, true) then return TRACER_COLORS.red end
    if name:find('green', 1, true) then return TRACER_COLORS.green end
    if name:find('blue', 1, true) then return TRACER_COLORS.blue end
    if name:find('yellow', 1, true) then return TRACER_COLORS.yellow end
    if name:find('orange', 1, true) then return TRACER_COLORS.orange end
    if name:find('white', 1, true) then return TRACER_COLORS.white end
    if name:find('proton', 1, true) then return TRACER_COLORS.proton end
    return TRACER_COLORS.default
end

--- Records a tracer if the effect data resolves to a live LVS bullet whose
--- TracerName matches the emitted effect. Source-based, not name-based.
--- @param effectName string
--- @param data CEffectData
local function captureTracerEffect(effectName, data)
    if not (data and LVS and LVS.GetBullet) then return end

    local now = CurTime()
    if now >= tracerState.nextPurge then
        tracerState.nextPurge = now + 1
        for id, tr in pairs(tracerState.items) do
            if now - tr.born > TRACER_MAX_AGE or not LVS:GetBullet(id) then
                tracerState.items[id] = nil
            end
        end
    end

    local ok, id = pcall(data.GetMaterialIndex, data)
    if not ok or not id then return end

    local bullet = LVS:GetBullet(id)
    if not bullet then return end

    local shooter = bullet.Entity
    if not (IsValid(shooter) and shooter.LVS) then return end

    -- Filter smoke / exhaust whose material index might collide with a live bullet.
    if bullet.TracerName ~= effectName then return end

    tracerState.items[id] = {
        born = now,
        color = tracerColor(effectName),
    }
end

local function effectWrapper(effectName, data, allowOverride, filter)
    captureTracerEffect(effectName, data)
    return tracerState.oldEffect(effectName, data, allowOverride, filter)
end
tracerState.wrapper = effectWrapper

tracerState.restore = function()
    if util.Effect == tracerState.wrapper then
        util.Effect = tracerState.oldEffect
    end
    tracerState.oldEffect = nil
    tracerState.activeUsers = 0
end

local function retainEffectCapture()
    if tracerState.activeUsers == 0 then
        tracerState.oldEffect = util.Effect
        util.Effect = tracerState.wrapper
    end
    tracerState.activeUsers = tracerState.activeUsers + 1
end

local function releaseEffectCapture()
    tracerState.activeUsers = math.max(tracerState.activeUsers - 1, 0)
    if tracerState.activeUsers ~= 0 then return end
    tracerState.restore()
    tracerState.items = {}
end

--- Builds a NoDraw clientside prop used as the holo mirror for one LVS source.
--- @param model string
--- @return Entity?
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

local function syncMirror(rec)
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

--- Returns the shared LVS source list. Radar instances still own their
--- clientside mirrors, but multiple tables no longer scan every world entity
--- independently on the same 15 Hz update.
local function getLVSSources()
    local now = SysTime()
    if now - sourceCacheTime < SOURCE_SCAN_INTERVAL then return sourceCache end

    local fresh = {}
    for _, ent in ents.Iterator() do
        if ent.LVS then fresh[#fresh + 1] = ent end
    end
    sourceCache = fresh
    sourceCacheTime = now
    return sourceCache
end

--- Draws projected LVS bullet tracers in the radar layer.
--- @param radar table Owning RADAR instance (provides Project / GetScale).
local function drawTracers(radar)
    if not (LVS and LVS.GetBullet) then return end

    local now = CurTime()
    render.SetMaterial(TRACER_MAT_GLOW)
    for id, tr in pairs(tracerState.items) do
        local bullet = LVS:GetBullet(id)
        if not bullet or now - tr.born > TRACER_MAX_AGE then
            tracerState.items[id] = nil
            continue
        end
        if not (bullet.GetPos and bullet.GetDir and bullet.GetLength) then
            tracerState.items[id] = nil
            continue
        end

        local pos = bullet:GetPos()
        local dir = bullet:GetDir()
        local len = 1000 * (bullet:GetLength() or 1)
        local startPos = pos - dir * len
        local endPos = pos + dir * len * 0.1
        local wStart = radar:Project(startPos)
        TRACER_START:SetUnpacked(wStart.x, wStart.y, wStart.z)
        local wEnd = radar:Project(endPos)
        TRACER_END:SetUnpacked(wEnd.x, wEnd.y, wEnd.z)

        local width = math.Clamp(len * radar:GetScale() * 0.025, TRACER_MIN_WIDTH, TRACER_MAX_WIDTH)
        render.DrawBeam(TRACER_START, TRACER_END, width * 1.8, 1, 0, tr.color)

        render.SetMaterial(TRACER_MAT_BEAM)
        render.DrawBeam(TRACER_START, TRACER_END, width, 1, 0, tr.color)
        render.DrawBeam(TRACER_START, TRACER_END, math.max(width * 0.35, 0.25), 1, 0, TRACER_CORE_COLOR)
        render.SetMaterial(TRACER_MAT_GLOW)
    end
end

function RADAR:Initialize()
    self.Tracked = {}
    if not self.EffectCaptureRetained then
        retainEffectCapture()
        self.EffectCaptureRetained = true
    end
end

--- Single sweep: drops stale entries + their mirrors, then adds mirrors
--- for new LVS ents.
function RADAR:Think()
    local fresh = {}
    for _, v in pairs(self.Tracked) do
        if IsValid(v.ent) and v.ent:GetModel() == v.model then
            fresh[v.ent:EntIndex()] = v
        elseif v.csent then
            SafeRemoveEntity(v.csent)
        end
    end

    local sources = getLVSSources()
    for i = 1, #sources do
        local v = sources[i]
        if not IsValid(v) then continue end
        if fresh[v:EntIndex()] then continue end
        local model = v:GetModel()
        if not model or model == '' then continue end
        local cs = makeMirror(model)
        if not cs then continue end
        fresh[v:EntIndex()] = {
            ent = v,
            csent = cs,
            model = model,
            visRadius = v:BoundingRadius() + v:OBBCenter():Length(),
            detectedAt = CurTime(),
            trail = {},
        }
    end

    local now = CurTime()
    for _, rec in pairs(fresh) do
        syncMirror(rec)
        updateTrail(rec, now)
    end

    self.Tracked = fresh
end

function RADAR:Draw()
    local team = self:GetEntity():GetTeam()
    if self:GetLOD() == 1 then
        render.SetColorMaterial()
        for _, v in pairs(self.Tracked) do
            local ent = v.ent
            if not IsValid(ent) then continue end
            local entPos = ent:GetPos()
            if not self:IsVisible(entPos, v.visRadius or 64) then continue end
            local entTeam = ent.GetAITEAM and ent:GetAITEAM() or ent.AITEAM or 0
            local phase = ent:EntIndex() * 0.47
            local appearance = HoloEffects.GetContactReveal(self.entityTable,
                phase, v.detectedAt)
            render.SetBlend(appearance)
            render.DrawSphere(self:Project(entPos), MARKER_RADIUS, 8, 8,
                markerColorFor(team, entTeam))
            render.SetBlend(1)
        end
        drawTracers(self)
        return
    end

    local invScale = self:GetScale()
    render.SuppressEngineLighting(true)
    for _, v in pairs(self.Tracked) do
        local ent, csent = v.ent, v.csent
        if not (IsValid(ent) and IsValid(csent)) then continue end
        local entPos = ent:GetPos()
        local visRadius = v.visRadius
        if not visRadius then
            visRadius = ent:BoundingRadius() + ent:OBBCenter():Length()
            v.visRadius = visRadius
        end
        if not self:IsVisible(entPos, visRadius) then continue end

        local entTeam = ent.GetAITEAM and ent:GetAITEAM() or ent.AITEAM or 0
        local tint = tintFor(team, entTeam)
        local contactColor = markerColorFor(team, entTeam)
        local modelColor = modelColorFor(team, entTeam)
        local wpos, wang = self:Project(entPos, ent:GetAngles())
        csent:SetPos(wpos)
        csent:SetAngles(wang)
        csent:SetModelScale(invScale, 0)

        local phase = ent:EntIndex() * 0.47
        if v.proxy and v.proxy.state == 'proxy'
            and v.materializedProxy ~= v.proxy then
            -- A generated mesh can finish well after the source contact was
            -- detected. Give that marker-to-model transition its own envelope.
            v.materializedProxy = v.proxy
            v.materializeAt = CurTime()
        end
        local appearance = HoloEffects.GetContactReveal(self.entityTable,
            phase, v.materializeAt or v.detectedAt)
        local flicker = 1
        if appearance < 0.98 then
            flicker = 0.72 + 0.28 * (0.5
                + math.sin(CurTime() * 38 + phase * 5.3) * 0.5)
        end
        local visibility = appearance * flicker
        local projectionScale = 0.8 + appearance * 0.2
        local markerRadius = math.Clamp(visRadius * invScale * 0.35, 1.5, 7)
        local proxyDrawn = RadarProxy and RadarProxy.Draw(v.proxy, wpos, wang,
            invScale * projectionScale, modelColor, self.entityTable,
            visibility, appearance)
        if not proxyDrawn then
            if RadarProxy and RadarProxy.ShouldUseMarker(v.proxy) then
                render.SetColorMaterial()
                render.SetBlend(visibility)
                render.DrawSphere(wpos, math.max(markerRadius * 0.7, 1.2),
                    8, 8, contactColor)
                render.SetBlend(1)
            else
                csent:SetModelScale(invScale * projectionScale, 0)
                csent:SetupBones()
                if not HoloEffects.DrawContactModel(self.entityTable, csent,
                    modelColor, phase, visibility, appearance) then
                    render.SetColorModulation(tint[1], tint[2], tint[3])
                    render.SetBlend(visibility)
                    csent:DrawModel()
                    render.SetBlend(1)
                    render.SetColorModulation(1, 1, 1)
                end
            end
        end
        local markerHeight = math.Clamp(visRadius * invScale * 1.2, 4, 16)
        HoloEffects.DrawContactMarker(self.entityTable, wpos, contactColor,
            markerRadius, markerHeight, phase, appearance)
        HoloEffects.DrawContactPing(self.entityTable, wpos, contactColor,
            CurTime() - (v.detectedAt or 0), markerRadius, appearance)
        HoloEffects.DrawContactLabel(self.entityTable, wpos, contactColor,
            markerHeight + 1, contactName(ent), contactStatusFor(team, entTeam),
            appearance)
        HoloEffects.DrawContactTrail(self, v.trail, contactColor, appearance)
    end
    render.SetColorModulation(1, 1, 1)
    render.SuppressEngineLighting(false)

    drawTracers(self)
end

function RADAR:OnRemove()
    for _, v in pairs(self.Tracked) do
        if v.csent then SafeRemoveEntity(v.csent) end
    end
    self.Tracked = nil
    if self.EffectCaptureRetained then
        releaseEffectCapture()
        self.EffectCaptureRetained = nil
    end
end
