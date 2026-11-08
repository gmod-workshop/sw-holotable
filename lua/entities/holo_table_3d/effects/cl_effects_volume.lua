-- Optional depth-aware projector volume powered by GShader's world-position RT.
-- There is intentionally no geometry fallback: a camera-facing beam is more
-- distracting than omitting this decorative layer.

local Effects = ENT.HoloEffects
local cvars = Effects.cvars

local HOOK_NAME = 'holo_table_3d.ProjectorVolume'
local MATERIAL_NAME = 'holo_table_projector_volume_gshader'
local CONTACT_LIGHT_MATERIAL_NAME = 'holo_table_contact_light_gshader_v2'
local PROJECTOR_BASE_HEIGHT = 27.8
local PROJECTOR_HEIGHT = 58
local DEFAULT_PROJECTOR_RADIUS = 86
local PROJECTOR_RADIUS_MIN = 60
local PROJECTOR_RADIUS_MAX = 100
local PROJECTOR_TOP_SCALE = 1.22

local volumeMaterial
local materialFailed = false
local warnedMaterial = false
local contactLightMaterial
local contactLightMaterialFailed = false
local warnedContactLightMaterial = false
local CENTER = Vector()
local CONTACT_POSITION = Vector()
local contactCandidates = {}

local function tablePowered(ent)
    return not ent.GetPowered or ent:GetPowered()
end

-- Neutralize the removed beam implementation during Lua auto-refresh. The
-- next full load no longer calls this compatibility stub.
Effects.DrawAtmosphere = function() end

local function isGShaderReady()
    if not shaderlib or not shaderlib.rt_WPDepth
        or not isfunction(shaderlib.DrawScreenQuad) then
        return false
    end

    local enabled = GetConVar('r_shaderlib')
    local depthEnabled = GetConVar('r_shaderlib_depthbuffer')
    return (not enabled or enabled:GetBool())
        and (not depthEnabled or depthEnabled:GetBool())
end

local function getVolumeMaterial()
    if materialFailed then return nil end
    if volumeMaterial and not volumeMaterial:IsError() then
        return volumeMaterial
    end

    volumeMaterial = CreateMaterial(MATERIAL_NAME, 'screenspace_general', {
        ['$pixshader'] = 'holotable_volume_ps30',
        ['$vertexshader'] = 'pp_vs30',
        ['$basetexture'] = '_rt_WPDepth',
        ['$ignorez'] = '1',
        ['$vertextransform'] = '1',
        ['$translucent'] = '1',
        ['$additive'] = '1',
        ['$nofog'] = '1',
        ['$pointsample'] = '1',
        ['$linearwrite'] = '1',
        ['$no_fullbright'] = '1',
        ['$c0_x'] = '0', ['$c0_y'] = '0',
        ['$c0_z'] = '0', ['$c0_w'] = '0',
        ['$c1_x'] = '0', ['$c1_y'] = '0',
        ['$c1_z'] = '0', ['$c1_w'] = '0',
        ['$c2_x'] = '0', ['$c2_y'] = '0',
        ['$c2_z'] = '1', ['$c2_w'] = '0.72',
        ['$c3_x'] = '0.4', ['$c3_y'] = '0.62',
        ['$c3_z'] = '1', ['$c3_w'] = tostring(DEFAULT_PROJECTOR_RADIUS),
    })

    if volumeMaterial and not volumeMaterial:IsError() then
        return volumeMaterial
    end

    materialFailed = true
    if not warnedMaterial then
        warnedMaterial = true
        ErrorNoHalt('[holo_table] projector-volume shader unavailable; '
            .. 'restart Garry\'s Mod after installing the compiled shader.\n')
    end
    return nil
end

local function getContactLightMaterial()
    if contactLightMaterialFailed then return nil end
    if contactLightMaterial and not contactLightMaterial:IsError() then
        return contactLightMaterial
    end

    contactLightMaterial = CreateMaterial(CONTACT_LIGHT_MATERIAL_NAME,
        'screenspace_general', {
            ['$pixshader'] = 'holotable_contactlight2_ps30',
            ['$vertexshader'] = 'pp_vs30',
            ['$basetexture'] = '_rt_WPDepth',
            ['$ignorez'] = '1',
            ['$vertextransform'] = '1',
            ['$translucent'] = '1',
            ['$additive'] = '1',
            ['$nofog'] = '1',
            ['$pointsample'] = '1',
            ['$linearwrite'] = '1',
            ['$no_fullbright'] = '1',
            ['$c0_x'] = '0', ['$c0_y'] = '0',
            ['$c0_z'] = '0', ['$c0_w'] = '0',
            ['$c1_x'] = '0', ['$c1_y'] = '0',
            ['$c1_z'] = '0', ['$c1_w'] = '16',
            ['$c2_x'] = '0.4', ['$c2_y'] = '0.62',
            ['$c2_z'] = '1', ['$c2_w'] = '0.3',
            ['$c3_x'] = '0', ['$c3_y'] = '0',
            ['$c3_z'] = '1', ['$c3_w'] = '1.5',
        })
    if contactLightMaterial and not contactLightMaterial:IsError() then
        return contactLightMaterial
    end

    contactLightMaterialFailed = true
    if not warnedContactLightMaterial then
        warnedContactLightMaterial = true
        ErrorNoHalt('[holo_table] contact-light shader unavailable; '
            .. 'restart Garry\'s Mod after installing the compiled shader.\n')
    end
    return nil
end

--- Records the contacts drawn this frame for the next reconstruction pass.
--- Positions are copied because radar projection functions return scratch vectors.
function Effects.RegisterContactLight(selfTbl, pos, color, radius, visibility)
    if not Effects.AreContactLightsEnabled() then return end
    local frame = FrameNumber()
    local state = selfTbl._holoContactLights
    if not state then
        state = { frame = frame, count = 0, items = {} }
        selfTbl._holoContactLights = state
    elseif state.frame ~= frame then
        state.frame = frame
        state.count = 0
    end

    local index = state.count + 1
    if index > 32 then return end
    state.count = index
    local item = state.items[index] or {}
    state.items[index] = item
    item.x, item.y, item.z = pos.x, pos.y, pos.z
    item.r = (color.r or 255) / 255
    item.g = (color.g or 255) / 255
    item.b = (color.b or 255) / 255
    item.range = math.Clamp((radius or 2) * 2.5, 5, 18)
    item.visibility = math.Clamp(visibility or 1, 0, 1)
end

local function getContactScreenBounds(item, eyePosition, viewForward)
    CONTACT_POSITION:SetUnpacked(item.x, item.y, item.z)
    local dx = item.x - eyePosition.x
    local dy = item.y - eyePosition.y
    local dz = item.z - eyePosition.z
    local depth = dx * viewForward.x + dy * viewForward.y + dz * viewForward.z
    local radius = item.range
    if depth <= -radius then return end

    local width, height = ScrW(), ScrH()
    if depth <= radius then return 0, 0, width, height end
    local screen = CONTACT_POSITION:ToScreen()
    local pixelRadius = math.max(width, height) * radius
        / math.max(depth - radius, 1)
    local x0 = math.max(0, math.floor(screen.x - pixelRadius))
    local y0 = math.max(0, math.floor(screen.y - pixelRadius))
    local x1 = math.min(width, math.ceil(screen.x + pixelRadius))
    local y1 = math.min(height, math.ceil(screen.y + pixelRadius))
    if x1 <= x0 or y1 <= y0 then return end
    return x0, y0, x1, y1
end

local function drawContactLight(item, selfTbl, material, viewSetup, viewForward,
        tableReveal)
    local x0, y0, x1, y1 = getContactScreenBounds(item, viewSetup.origin,
        viewForward)
    if not x0 then return end
    local strength = cvars.contactLightingStrength:GetFloat()
        * item.visibility * tableReveal
    if strength <= 0.001 then return end

    material:SetTexture('$basetexture', shaderlib.rt_WPDepth)
    material:SetFloat('$c0_x', viewSetup.origin.x)
    material:SetFloat('$c0_y', viewSetup.origin.y)
    material:SetFloat('$c0_z', viewSetup.origin.z)
    material:SetFloat('$c0_w', CurTime())
    material:SetFloat('$c1_x', item.x)
    material:SetFloat('$c1_y', item.y)
    material:SetFloat('$c1_z', item.z)
    material:SetFloat('$c1_w', item.range)
    material:SetFloat('$c2_x', item.r)
    material:SetFloat('$c2_y', item.g)
    material:SetFloat('$c2_z', item.b)
    material:SetFloat('$c2_w', strength)
    material:SetFloat('$c3_x', selfTbl._holoUx)
    material:SetFloat('$c3_y', selfTbl._holoUy)
    material:SetFloat('$c3_z', selfTbl._holoUz)
    material:SetFloat('$c3_w', math.min(item.range * 0.12, 2.5))

    render.SetScissorRect(x0, y0, x1, y1, true)
    render.OverrideDepthEnable(true, false)
    render.SetMaterial(material)
    shaderlib.DrawScreenQuad()
    render.OverrideDepthEnable(false, false)
    render.SetScissorRect(0, 0, 0, 0, false)
end

local function drawContactLightsForTable(ent, material, viewSetup, viewForward)
    if not IsValid(ent) or not ent.UpdateHologramTransform then return end
    ent:UpdateHologramTransform(ent:GetScale(), ent:GetHeight(),
        ent:GetPanX(), ent:GetPanY())
    local selfTbl = ent:GetTable()
    local state = selfTbl._holoContactLights
    if not state or state.count <= 0
        or state.frame < FrameNumber() - 2 then return end

    local reveal = Effects.UpdateSequence(selfTbl, tablePowered(ent))
    if reveal <= 0.001 then return end
    local count = math.min(state.count, #state.items)
    for i = 1, count do
        local item = state.items[i]
        local dx = item.x - viewSetup.origin.x
        local dy = item.y - viewSetup.origin.y
        local dz = item.z - viewSetup.origin.z
        item._lightScore = item.range * item.range * 4096
            - (dx * dx + dy * dy + dz * dz) * 0.0001
        contactCandidates[i] = item
    end
    for i = count + 1, #contactCandidates do contactCandidates[i] = nil end
    table.sort(contactCandidates, function(a, b)
        return a._lightScore > b._lightScore
    end)

    local maximum = math.min(cvars.contactLightingMax:GetInt(), count)
    for i = 1, maximum do
        drawContactLight(contactCandidates[i], selfTbl, material, viewSetup,
            viewForward, reveal)
    end
end

--- Returns a conservative pixel rectangle for the volume's bounding sphere.
--- @return number? x0
--- @return number? y0
--- @return number? x1
--- @return number? y1
local function getScreenBounds(baseX, baseY, baseZ, upX, upY, upZ,
        projectorRadius, eyePosition, viewForward)
    local maxRadius = projectorRadius * PROJECTOR_TOP_SCALE
    local boundRadius = math.sqrt(maxRadius * maxRadius
        + PROJECTOR_HEIGHT * PROJECTOR_HEIGHT * 0.25)
    CENTER:SetUnpacked(baseX + upX * PROJECTOR_HEIGHT * 0.5,
        baseY + upY * PROJECTOR_HEIGHT * 0.5,
        baseZ + upZ * PROJECTOR_HEIGHT * 0.5)

    local dx = CENTER.x - eyePosition.x
    local dy = CENTER.y - eyePosition.y
    local dz = CENTER.z - eyePosition.z
    local depth = dx * viewForward.x + dy * viewForward.y + dz * viewForward.z
    if depth <= -boundRadius then return end

    local width, height = ScrW(), ScrH()
    if depth <= boundRadius then
        return 0, 0, width, height
    end

    local screen = CENTER:ToScreen()
    -- Deliberately oversized so tilted and near-camera volumes never clip.
    local pixelRadius = math.max(width, height) * boundRadius
        / math.max(depth - boundRadius, 1)
    local x0 = math.max(0, math.floor(screen.x - pixelRadius))
    local y0 = math.max(0, math.floor(screen.y - pixelRadius))
    local x1 = math.min(width, math.ceil(screen.x + pixelRadius))
    local y1 = math.min(height, math.ceil(screen.y + pixelRadius))
    if x1 <= x0 or y1 <= y0 then return end
    return x0, y0, x1, y1
end

local function pushMaterialConstants(material, eyePosition, baseX, baseY, baseZ,
        upX, upY, upZ, projectorRadius, strength)
    material:SetTexture('$basetexture', shaderlib.rt_WPDepth)

    material:SetFloat('$c0_x', eyePosition.x)
    material:SetFloat('$c0_y', eyePosition.y)
    material:SetFloat('$c0_z', eyePosition.z)
    local animationRate = math.max(0.05, 1 + cvars.sweepSpeed:GetFloat())
    material:SetFloat('$c0_w', CurTime() * animationRate)

    material:SetFloat('$c1_x', baseX)
    material:SetFloat('$c1_y', baseY)
    material:SetFloat('$c1_z', baseZ)
    material:SetFloat('$c1_w', strength)

    material:SetFloat('$c2_x', upX)
    material:SetFloat('$c2_y', upY)
    material:SetFloat('$c2_z', upZ)
    material:SetFloat('$c2_w', cvars.coneSoftness:GetFloat())

    material:SetFloat('$c3_x', cvars.red:GetFloat() / 255)
    material:SetFloat('$c3_y', cvars.green:GetFloat() / 255)
    material:SetFloat('$c3_z', cvars.blue:GetFloat() / 255)
    material:SetFloat('$c3_w', projectorRadius)
end

local function drawVolumeForTable(ent, material, viewSetup, viewForward)
    if not IsValid(ent) or not ent.UpdateHologramTransform then return end

    ent:UpdateHologramTransform(ent:GetScale(), ent:GetHeight(),
        ent:GetPanX(), ent:GetPanY())
    local selfTbl = ent:GetTable()
    local reveal = Effects.UpdateSequence(selfTbl, tablePowered(ent))
    local strength = cvars.atmosphereStrength:GetFloat() * reveal
    if strength <= 0.001 then return end

    local tablePosition = selfTbl._holoTablePos
    local upX, upY, upZ = selfTbl._holoUx, selfTbl._holoUy, selfTbl._holoUz
    local projectorRadius = ent.GetProjectorRadius and ent:GetProjectorRadius()
        or DEFAULT_PROJECTOR_RADIUS
    if projectorRadius <= 0 then projectorRadius = DEFAULT_PROJECTOR_RADIUS end
    projectorRadius = math.Clamp(projectorRadius,
        PROJECTOR_RADIUS_MIN, PROJECTOR_RADIUS_MAX)
    local baseX = tablePosition.x + upX * PROJECTOR_BASE_HEIGHT
    local baseY = tablePosition.y + upY * PROJECTOR_BASE_HEIGHT
    local baseZ = tablePosition.z + upZ * PROJECTOR_BASE_HEIGHT
    local x0, y0, x1, y1 = getScreenBounds(baseX, baseY, baseZ,
        upX, upY, upZ, projectorRadius, viewSetup.origin, viewForward)
    if not x0 then return end

    pushMaterialConstants(material, viewSetup.origin, baseX, baseY, baseZ,
        upX, upY, upZ, projectorRadius, strength)

    render.SetScissorRect(x0, y0, x1, y1, true)
    render.OverrideDepthEnable(true, false)
    render.SetMaterial(material)
    shaderlib.DrawScreenQuad()
    render.OverrideDepthEnable(false, false)
    render.SetScissorRect(0, 0, 0, 0, false)
end

local function drawProjectorVolumes(viewSetup)
    local drawVolume = Effects.IsAtmosphereEnabled()
    local drawContactLights = Effects.AreContactLightsEnabled()
    if not (drawVolume or drawContactLights) or not isGShaderReady() then return end

    local renderEnabled = GetConVar('holo_table_render')
    if renderEnabled and not renderEnabled:GetBool() then return end
    if render.GetRenderTarget() then return end

    local material = drawVolume and getVolumeMaterial() or nil
    local lightMaterial = drawContactLights and getContactLightMaterial() or nil
    if not material and not lightMaterial then return end

    viewSetup = viewSetup or render.GetViewSetup(false)
    if not viewSetup or not viewSetup.origin or not viewSetup.angles then return end
    local viewForward = viewSetup.angles:Forward()

    for _, ent in ipairs(ents.FindByClass('holo_table_3d')) do
        if material then
            drawVolumeForTable(ent, material, viewSetup, viewForward)
        end
        if lightMaterial then
            drawContactLightsForTable(ent, lightMaterial, viewSetup, viewForward)
        end
    end
end

hook.Remove('PostDrawReconstructionEffects', HOOK_NAME)
hook.Add('PostDrawReconstructionEffects', HOOK_NAME, drawProjectorVolumes)

--- Exposed for diagnostics and settings UI without making GShader mandatory.
function Effects.IsProjectorVolumeAvailable()
    return isGShaderReady() and getVolumeMaterial() ~= nil
end

function Effects.IsContactLightingAvailable()
    return isGShaderReady() and getContactLightMaterial() ~= nil
end
