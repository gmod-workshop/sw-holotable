-- Tactical styling shared by player and vehicle radar modules.

local Effects = ENT.HoloEffects
local cvars = Effects.cvars

local RING_MATERIAL = Material('effects/spark')
local GLOW_MATERIAL = Material('sprites/light_glow02_add')
local RING_SEGMENTS = 24
local TWO_PI = math.pi * 2

local RING_BUILD_POS = Vector()
local RING_NORMAL = Vector(0, 0, 1)
local oldRingMesh = _G.HOLO_TABLE_3D_CONTACT_RING_MESH
if oldRingMesh and oldRingMesh.Destroy
    and (not oldRingMesh.IsValid or oldRingMesh:IsValid()) then
    oldRingMesh:Destroy()
end

local function emitRingVertex(x, y, u, v)
    RING_BUILD_POS:SetUnpacked(x, y, 0)
    mesh.Position(RING_BUILD_POS)
    mesh.Normal(RING_NORMAL)
    mesh.TexCoord(0, u, v)
    mesh.Color(255, 255, 255, 255)
    mesh.AdvanceVertex()
end

local RING_MESH = Mesh(RING_MATERIAL)
mesh.Begin(RING_MESH, MATERIAL_TRIANGLES, RING_SEGMENTS * 2)
for i = 0, RING_SEGMENTS - 1 do
    local a0 = TWO_PI * i / RING_SEGMENTS
    local a1 = TWO_PI * (i + 1) / RING_SEGMENTS
    local s0, c0 = math.sin(a0), math.cos(a0)
    local s1, c1 = math.sin(a1), math.cos(a1)
    emitRingVertex(s0, c0, 0, 0)
    emitRingVertex(s1, c1, 1, 0)
    emitRingVertex(s1 * 0.88, c1 * 0.88, 1, 1)
    emitRingVertex(s0, c0, 0, 0)
    emitRingVertex(s1 * 0.88, c1 * 0.88, 1, 1)
    emitRingVertex(s0 * 0.88, c0 * 0.88, 0, 1)
end
mesh.End()
_G.HOLO_TABLE_3D_CONTACT_RING_MESH = RING_MESH

local RING_MTX = Matrix()
local RING_SCALE = Vector()
local RING_ORIGIN = Vector()
local BEAM_START = Vector()
local BEAM_END = Vector()
local RING_COLOR = Color(255, 255, 255, 255)
local CORE_COLOR = Color(255, 255, 255, 255)
local PING_COLOR = Color(255, 255, 255, 255)
local TRAIL_COLOR = Color(255, 255, 255, 255)
local TRAIL_A = Vector()
local TRAIL_B = Vector()
local LABEL_POS = Vector()

local warnedOverlay
local warnedPropModel
local warnedRing
local modelMaterialCache = setmetatable({}, { __mode = 'k' })

local function setColor(target, source, alpha)
    target.r = source.r or 255
    target.g = source.g or 255
    target.b = source.b or 255
    target.a = math.Clamp(alpha, 0, 255)
end

local function drawMesh(target)
    target:Draw()
end

local function drawRing(selfTbl, pos, color, radius, alpha)
    setColor(RING_COLOR, color, alpha)
    RING_ORIGIN:SetUnpacked(pos.x, pos.y, pos.z)
    RING_SCALE:SetUnpacked(radius, radius, radius)
    RING_MTX:Identity()
    RING_MTX:SetTranslation(RING_ORIGIN)
    RING_MTX:SetAngles(selfTbl._holoAngles)
    RING_MTX:Scale(RING_SCALE)
    render.SetColorModulation(RING_COLOR.r / 255, RING_COLOR.g / 255,
        RING_COLOR.b / 255)
    render.SetBlend(RING_COLOR.a / 255)
    cam.PushModelMatrix(RING_MTX)
        -- Read the active generation at draw time. Lua auto-refresh can leave
        -- an older closure alive for a frame after rebuilding this tiny mesh.
        local ok, err = pcall(drawMesh,
            _G.HOLO_TABLE_3D_CONTACT_RING_MESH or RING_MESH)
    cam.PopModelMatrix()
    render.SetBlend(1)
    render.SetColorModulation(1, 1, 1)
    if not ok and not warnedRing then
        warnedRing = true
        ErrorNoHaltWithStack('[holo_table] contact ring draw skipped: '
            .. tostring(err))
    end
end

local function drawModel(model)
    model:DrawModel()
end

local function getModelMaterials(model)
    local modelName = model:GetModel()
    local cached = modelMaterialCache[model]
    if cached and cached.model == modelName then return cached end

    local names = model:GetMaterials() or {}
    cached = { model = modelName, names = names }
    modelMaterialCache[model] = cached
    return cached
end

local function drawEffectModel(selfTbl, model, color, phase, materialGetter, cacheKey,
    opacityScale, revealOverride, contactVisibility)
    local cached = getModelMaterials(model)
    local names = cached.names
    if #names == 0 then return nil end

    local state = cached[cacheKey]
    if not state then
        state = { overrides = {}, version = -1 }
        cached[cacheKey] = state
    end

    local materialCount = math.min(#names, 32)
    if state.version ~= Effects.settingsVersion then
        for i = 1, materialCount do
            state.overrides[i] = materialGetter(names[i])
        end
        state.version = Effects.settingsVersion
    end

    for i = 1, materialCount do
        if not state.overrides[i] then return nil end
    end

    if not Effects.PushConstants(selfTbl, true, color, phase,
        revealOverride, contactVisibility) then return nil end

    for i = 1, materialCount do
        render.MaterialOverrideByIndex(i - 1, state.overrides[i])
    end

    render.SetBlend(opacityScale or 1)
    local bloom = (cacheKey == 'contactLite' or cacheKey == 'contact')
        and Effects.BeginContactBloom(selfTbl)
    local ok, err = pcall(drawModel, model)
    if bloom then Effects.EndContactBloom(selfTbl) end

    render.SetBlend(1)
    render.MaterialOverrideByIndex()
    Effects.PopConstants()
    return ok, err
end

local function drawContactHalo(selfTbl, model, color, visibility)
    if not Effects.AreContactHalosEnabled() then return true end
    local cached = getModelMaterials(model)
    local names = cached.names
    if #names == 0 then return true end
    local state = cached.contactHalo
    if not state then
        state = { overrides = {}, ready = false }
        cached.contactHalo = state
    end
    local materialCount = math.min(#names, 32)
    if not state.ready then
        for i = 1, materialCount do
            state.overrides[i] = Effects.GetContactHaloModelMaterial(names[i])
            if not state.overrides[i] then return true end
        end
        state.ready = true
    end
    if not Effects.PushContactHaloConstants(selfTbl, color, visibility) then
        return true
    end

    for i = 1, materialCount do
        render.MaterialOverrideByIndex(i - 1, state.overrides[i])
    end
    local ok = pcall(drawModel, model)
    render.MaterialOverrideByIndex()
    Effects.PopConstants()
    return ok
end

--- Draws one projected model through the dedicated contact hologram shader.
--- Returns false when disabled or unavailable so the caller can draw normally.
--- @param selfTbl table Cached holo-table entity table.
--- @param model Entity Projected player/vehicle mirror.
--- @param color Color Team/contact color.
--- @param phase number Stable per-contact animation offset.
--- @return boolean drawn
function Effects.DrawContactModel(selfTbl, model, color, phase, opacityScale,
        revealOverride)
    if not Effects.AreContactModelsEnabled() or not IsValid(model) then return false end
    if Effects.IsPoweredOff(selfTbl) then return true end

    revealOverride = revealOverride == nil and Effects.GetReveal(selfTbl)
        or revealOverride
    if not drawContactHalo(selfTbl, model, color, opacityScale or 1) then
        return false
    end

    local ok, err
    if cvars.contactFullShader:GetBool() then
        ok, err = drawEffectModel(selfTbl, model, color, phase,
            Effects.GetContactMaterial, 'contact', opacityScale, revealOverride)
    else
        ok, err = drawEffectModel(selfTbl, model, color, phase,
            Effects.GetLiteContactModelMaterial, 'contactLite', opacityScale,
            revealOverride, 1)
    end

    if ok == nil then return false end
    if ok then return true end
    Effects.contactModelsFailed = true
    if not warnedOverlay then
        warnedOverlay = true
        ErrorNoHaltWithStack('[holo_table] tactical contact shader fallback: ' .. tostring(err))
    end
    return false
end

--- Draws a moving/legacy prop model through the map hologram shader.
--- @param selfTbl table Cached holo-table entity table.
--- @param model Entity Projected prop mirror.
--- @param phase number? Stable animation phase offset.
--- @return boolean drawn
function Effects.DrawPropModel(selfTbl, model, phase)
    if not Effects.ArePropsEnabled() or Effects.propModelsFailed or not IsValid(model) then
        return false
    end
    if Effects.IsPoweredOff(selfTbl) then return true end

    local ok, err = drawEffectModel(selfTbl, model, nil, phase,
        Effects.GetPropModelMaterial, 'prop')
    if ok == nil then return false end
    if ok then return true end

    Effects.propModelsFailed = true
    if not warnedPropModel then
        warnedPropModel = true
        ErrorNoHaltWithStack('[holo_table] prop-model shader fallback: ' .. tostring(err))
    end
    return false
end

--- Draws an animated ground ring, locator beam, and glowing cap.
--- All dimensions are already in projected world units.
--- @param selfTbl table Cached holo-table entity table.
--- @param pos Vector Projected contact origin.
--- @param color Color Team/contact color.
--- @param radius number Ground-ring radius.
--- @param height number Locator-beam height.
--- @param phase number Stable per-contact animation offset.
function Effects.DrawContactMarker(selfTbl, pos, color, radius, height, phase,
    contactReveal)
    if Effects.RegisterContactLight then
        Effects.RegisterContactLight(selfTbl, pos, color, radius,
            contactReveal or 1)
    end
    if not Effects.AreContactMarkersEnabled() then return end

    contactReveal = contactReveal or 1
    if contactReveal <= 0.001 then return end
    local speed = cvars.contactSpeed:GetFloat()
    local pulse = 0.5 + math.sin(CurTime() * speed + (phase or 0)) * 0.5
    local opacity = cvars.contactOpacity:GetFloat() * Effects.GetReveal(selfTbl)
        * contactReveal
    local acquisitionPulse = math.sin(math.Clamp(contactReveal, 0, 1) * math.pi)
    local ringRadius = radius * (0.88 + pulse * 0.18 + acquisitionPulse * 0.42)
    local ringAlpha = 255 * opacity * (0.45 + pulse * 0.45
        + acquisitionPulse * 0.35)
    local coreAlpha = 255 * opacity * (0.3 + pulse * 0.35
        + acquisitionPulse * 0.25)
    setColor(CORE_COLOR, color, coreAlpha)

    local ux, uy, uz = selfTbl._holoUx, selfTbl._holoUy, selfTbl._holoUz
    local px = pos.x + ux * 0.12
    local py = pos.y + uy * 0.12
    local pz = pos.z + uz * 0.12

    RING_ORIGIN:SetUnpacked(px, py, pz)
    drawRing(selfTbl, RING_ORIGIN, color, ringRadius, ringAlpha)

    if not Effects.AreContactBeaconsEnabled() then return end

    BEAM_START:SetUnpacked(px, py, pz)
    local beamHeight = height * (0.25 + contactReveal * 0.75)
    BEAM_END:SetUnpacked(px + ux * beamHeight, py + uy * beamHeight,
        pz + uz * beamHeight)
    render.SetMaterial(GLOW_MATERIAL)
    render.DrawBeam(BEAM_START, BEAM_END, 0.16 + pulse * 0.18, 0, 1, CORE_COLOR)
    local spriteSize = radius * (0.42 + pulse * 0.22)
    render.DrawSprite(BEAM_END, spriteSize, spriteSize, RING_COLOR)
end

--- Draws a short expanding ring when a contact is first acquired.
--- @param selfTbl table Cached holo-table entity table.
--- @param pos Vector Projected contact origin.
--- @param color Color Team/contact color.
--- @param age number Seconds since acquisition.
--- @param radius number Contact's normal marker radius.
function Effects.DrawContactPing(selfTbl, pos, color, age, radius, contactReveal)
    if not Effects.AreContactPingsEnabled() then return end
    local duration = cvars.contactPingTime:GetFloat()
    if age < 0 or age >= duration then return end

    local progress = age / duration
    local ux, uy, uz = selfTbl._holoUx, selfTbl._holoUy, selfTbl._holoUz
    RING_ORIGIN:SetUnpacked(pos.x + ux * 0.16, pos.y + uy * 0.16, pos.z + uz * 0.16)
    setColor(PING_COLOR, color, 255 * (1 - progress)
        * cvars.contactOpacity:GetFloat() * Effects.GetReveal(selfTbl)
        * (contactReveal or 1))
    drawRing(selfTbl, RING_ORIGIN, PING_COLOR,
        radius * (1.15 + progress * 2.2), PING_COLOR.a)
end

--- Draws a projected source-space movement history as a fading beam trail.
--- @param radar table Radar instance providing Project and entityTable.
--- @param points table[] Oldest-to-newest `{ pos, time }` records.
--- @param color Color Team/contact color.
function Effects.DrawContactTrail(radar, points, color, contactReveal)
    if not Effects.AreContactTrailsEnabled() or not points or #points < 2 then return end

    local now = CurTime()
    local lifetime = cvars.contactTrailTime:GetFloat()
    local selfTbl = radar.entityTable
    local ux, uy, uz = selfTbl._holoUx, selfTbl._holoUy, selfTbl._holoUz
    render.SetMaterial(GLOW_MATERIAL)

    local projected = radar:Project(points[1].pos)
    TRAIL_A:SetUnpacked(projected.x + ux * 0.3, projected.y + uy * 0.3,
        projected.z + uz * 0.3)
    for i = 2, #points do
        local point = points[i]
        projected = radar:Project(point.pos)
        TRAIL_B:SetUnpacked(projected.x + ux * 0.3, projected.y + uy * 0.3,
            projected.z + uz * 0.3)
        local fade = math.Clamp(1 - (now - point.time) / lifetime, 0, 1)
        setColor(TRAIL_COLOR, color, 180 * fade * cvars.contactOpacity:GetFloat()
            * Effects.GetReveal(selfTbl) * (contactReveal or 1))
        render.DrawBeam(TRAIL_A, TRAIL_B, 0.18 + fade * 0.28, 0, 1, TRAIL_COLOR)
        TRAIL_A:SetUnpacked(TRAIL_B.x, TRAIL_B.y, TRAIL_B.z)
    end
end

surface.CreateFont('HoloTableContactLabel', {
    font = 'Roboto',
    size = 28,
    weight = 700,
    antialias = true,
})
surface.CreateFont('HoloTableContactStatus', {
    font = 'Roboto',
    size = 17,
    weight = 500,
    antialias = true,
})

--- Draws a compact billboard label only in close tactical views.
--- @param selfTbl table Cached holo-table entity table.
--- @param pos Vector Projected contact origin.
--- @param color Color Team/contact color.
--- @param height number Label height above the contact.
--- @param title string Primary contact name.
--- @param status string? Relationship/type caption.
function Effects.DrawContactLabel(selfTbl, pos, color, height, title, status,
    contactReveal)
    if not Effects.AreContactLabelsEnabled(selfTbl) then return end
    if Effects.GetReveal(selfTbl) < 0.65 then return end
    if (contactReveal or 1) < 0.85 then return end
    if not title or title == '' then return end

    local ux, uy, uz = selfTbl._holoUx, selfTbl._holoUy, selfTbl._holoUz
    LABEL_POS:SetUnpacked(pos.x + ux * height, pos.y + uy * height, pos.z + uz * height)
    local angle = (EyePos() - LABEL_POS):Angle()
    angle:RotateAroundAxis(angle:Up(), 90)
    angle:RotateAroundAxis(angle:Forward(), 90)

    cam.Start3D2D(LABEL_POS, angle, 0.055)
        surface.SetFont('HoloTableContactLabel')
        local titleWidth = surface.GetTextSize(title)
        surface.SetFont('HoloTableContactStatus')
        local statusWidth = status and surface.GetTextSize(status) or 0
        local width = math.max(titleWidth, statusWidth) + 26
        draw.RoundedBox(5, -width * 0.5, -32, width, status and 53 or 34,
            Color(5, 12, 22, 190))
        draw.RoundedBox(3, -width * 0.5 + 5, -27, 5, status and 43 or 24,
            Color(color.r, color.g, color.b, 235))
        draw.SimpleText(title, 'HoloTableContactLabel', 4, -31, color,
            TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
        if status then
            draw.SimpleText(status, 'HoloTableContactStatus', 4, -4,
                Color(210, 230, 255, 220), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
        end
    cam.End3D2D()
end
