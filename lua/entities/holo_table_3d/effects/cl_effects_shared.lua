-- Shared state and per-table shader constants for optional visual effects.

ENT.HoloEffects = ENT.HoloEffects or {}
local Effects = ENT.HoloEffects

local styleCvars = {
    enabled = CreateClientConVar('holo_table_effects', '0', true, false,
        'Enable the experimental stylized hologram shader.'),
    props = CreateClientConVar('holo_table_effect_props', '1', true, false,
        'Apply the stylized hologram shader to baked map props.'),
    brushes = CreateClientConVar('holo_table_effect_brushes', '1', true, false,
        'Apply the stylized hologram shader to live BSP brush entities.'),
    contacts = CreateClientConVar('holo_table_effect_contacts', '1', true, false,
        'Add filled hologram materials and locator pulses to radar contacts.'),
    contactModels = CreateClientConVar('holo_table_effect_contact_models', '1', true, false,
        'Render 3D radar contact models.'),
    contactFullShader = CreateClientConVar('holo_table_effect_contact_full_shader', '0', true, false,
        'Use the expensive full map shader on contact models instead of the lightweight hologram material.'),
    contactMarkers = CreateClientConVar('holo_table_effect_contact_markers', '1', true, false,
        'Add pulsing ground rings to radar contacts.'),
    contactBeacons = CreateClientConVar('holo_table_effect_contact_beacons', '0', true, false,
        'Add vertical locator beams and glow caps above radar contacts.'),
    contactOpacity = CreateClientConVar('holo_table_effect_contact_opacity', '0.78', true, false,
        'Opacity of tactical radar-contact overlays.', 0, 1),
    contactBrightness = CreateClientConVar('holo_table_effect_contact_brightness', '1.2', true, false,
        'Emissive brightness of the lightweight player/vehicle hologram bodies.', 0, 3),
    contactBloom = CreateClientConVar('holo_table_effect_contact_bloom', '1', true, false,
        'Add a soft screen-space glow from visible player/vehicle holograms.'),
    contactBloomStrength = CreateClientConVar('holo_table_effect_contact_bloom_strength', '0.55', true, false,
        'Intensity of the contact-only soft glow.', 0, 2),
    contactBloomBlur = CreateClientConVar('holo_table_effect_contact_bloom_blur', '4', true, false,
        'Blur radius of the contact-only soft glow.', 1, 12),
    contactSpeed = CreateClientConVar('holo_table_effect_contact_speed', '2.2', true, false,
        'Animation speed of tactical radar-contact pulses.', 0, 8),
    contactTrails = CreateClientConVar('holo_table_effect_contact_trails', '0', true, false,
        'Draw fading movement trails behind vehicle contacts.'),
    contactTrailTime = CreateClientConVar('holo_table_effect_contact_trail_time', '1.6', true, false,
        'Seconds of contact movement retained in a trail.', 0.25, 5),
    contactPings = CreateClientConVar('holo_table_effect_contact_pings', '1', true, false,
        'Draw an expanding acquisition ping around newly seen contacts.'),
    contactPingTime = CreateClientConVar('holo_table_effect_contact_ping_time', '1.4', true, false,
        'Duration of a new-contact acquisition ping.', 0.25, 4),
    contactMaterializeTime = CreateClientConVar('holo_table_effect_contact_materialize_time', '0.42', true, false,
        'Seconds used to materialize a newly detected radar contact.', 0, 2),
    contactStagger = CreateClientConVar('holo_table_effect_contact_stagger', '0.28', true, false,
        'Amount of per-contact staggering during the table startup reveal.', 0, 0.5),
    contactHalo = CreateClientConVar('holo_table_effect_contact_halo', '1', true, false,
        'Draw a screen-space-width silhouette glow around 3D radar contacts.'),
    contactHaloWidth = CreateClientConVar('holo_table_effect_contact_halo_width', '1.8', true, false,
        'Width of the contact silhouette glow in screen pixels.', 0.25, 6),
    contactHaloStrength = CreateClientConVar('holo_table_effect_contact_halo_strength', '0.16', true, false,
        'Brightness of the contact silhouette glow.', 0, 1.5),
    contactOcclusion = CreateClientConVar('holo_table_effect_contact_occlusion', '1', true, false,
        'Fade contacts into projected geometry and add an intersection edge.'),
    contactOcclusionSoftness = CreateClientConVar('holo_table_effect_contact_occlusion_softness', '0.00045', true, false,
        'Screen-depth width of the contact intersection transition.', 0.00005, 0.02),
    contactIntersectionStrength = CreateClientConVar('holo_table_effect_contact_intersection_strength', '0.8', true, false,
        'Brightness of contact edges where they meet projected geometry.', 0, 2),
    contactLighting = CreateClientConVar('holo_table_effect_contact_lighting', '1', true, false,
        'Project depth-aware contact light onto nearby opaque surfaces when GShader is available.'),
    contactLightingStrength = CreateClientConVar('holo_table_effect_contact_lighting_strength', '0.32', true, false,
        'Brightness of depth-aware contact light pools.', 0, 2),
    contactLightingMax = CreateClientConVar('holo_table_effect_contact_lighting_max', '4', true, false,
        'Maximum contact light pools drawn per visible table.', 0, 12),
    contactLabels = CreateClientConVar('holo_table_effect_contact_labels', '1', true, false,
        'Draw tactical labels in close table views.'),
    contactLabelScale = CreateClientConVar('holo_table_effect_contact_label_scale', '24', true, false,
        'Largest table scale at which tactical labels are shown.', 4, 128),
    atmosphere = CreateClientConVar('holo_table_effect_atmosphere', '1', true, false,
        'Draw the depth-aware GShader projector volume when available.'),
    atmosphereStrength = CreateClientConVar('holo_table_effect_atmosphere_strength', '0.28', true, false,
        'Intensity of the depth-aware projector volume.', 0, 1),
    coneSoftness = CreateClientConVar('holo_table_effect_cone_softness', '0.72', true, false,
        'Softness of the volumetric cone boundary.', 0, 1),
    sweepSpeed = CreateClientConVar('holo_table_effect_sweep_speed', '0.12', true, false,
        'Projector pulse-rate adjustment.', -2, 2),
    sequenceTime = CreateClientConVar('holo_table_effect_sequence_time', '1.1', true, false,
        'Seconds used by the hologram startup/shutdown sequence.', 0, 5),
    strength = CreateClientConVar('holo_table_effect_strength', '1', true, false,
        'Overall stylized hologram effect strength.', 0, 2),
    red = CreateClientConVar('holo_table_effect_color_r', '102', true, false,
        'Hologram tint red channel.', 0, 255),
    green = CreateClientConVar('holo_table_effect_color_g', '159', true, false,
        'Hologram tint green channel.', 0, 255),
    blue = CreateClientConVar('holo_table_effect_color_b', '255', true, false,
        'Hologram tint blue channel.', 0, 255),
    opacity = CreateClientConVar('holo_table_effect_opacity', '0.78', true, false,
        'Stylized hologram opacity.', 0.05, 1),
    textureMix = CreateClientConVar('holo_table_effect_texture_mix', '0.35', true, false,
        'Amount of the original map texture retained by the stylized shader.', 0, 1),
    rim = CreateClientConVar('holo_table_effect_rim', '1.5', true, false,
        'Fresnel rim-light strength.', 0, 4),
    scan = CreateClientConVar('holo_table_effect_scanlines', '0.55', true, false,
        'Thin scanline strength.', 0, 2),
    band = CreateClientConVar('holo_table_effect_scan_band', '0.45', true, false,
        'Broad scrolling scan-band strength.', 0, 2),
    contours = CreateClientConVar('holo_table_effect_contours', '0.35', true, false,
        'Height-contour strength.', 0, 2),
    noise = CreateClientConVar('holo_table_effect_noise', '0.12', true, false,
        'Procedural signal-noise strength.', 0, 1),
    glitch = CreateClientConVar('holo_table_effect_glitch', '0.55', true, false,
        'Intermittent horizontal glitch strength.', 0, 2),
    scanSpacing = CreateClientConVar('holo_table_effect_scan_spacing', '2.5', true, false,
        'Distance in holo units between scanlines.', 0.25, 32),
    contourSpacing = CreateClientConVar('holo_table_effect_contour_spacing', '8', true, false,
        'Distance in holo units between height contours.', 1, 128),
}

--- Produces a reusable neutral-contact color from the current map tint.
--- The contact pass has less source-texture variation than the map, so a
--- slightly softened tint keeps markers and hulls in the same visual family.
function Effects.GetHologramColor(target, alpha)
    target = target or Color(255, 255, 255, alpha or 255)
    local r = styleCvars.red:GetFloat()
    local g = styleCvars.green:GetFloat()
    local b = styleCvars.blue:GetFloat()
    local luminance = r * 0.2126 + g * 0.7152 + b * 0.0722
    local neutral = luminance * 0.93
    local saturation = 0.46
    target.r = math.Clamp(math.floor(neutral + (r - luminance)
        * saturation + 0.5), 0, 255)
    target.g = math.Clamp(math.floor(neutral + (g - luminance)
        * saturation + 0.5), 0, 255)
    target.b = math.Clamp(math.floor(neutral + (b - luminance)
        * saturation + 0.5), 0, 255)
    target.a = alpha or target.a or 255
    return target
end

--- Returns the unmodified map-shader tint for a neutral contact's filled
--- geometry. Marker lines deliberately use the softer color above, while the
--- shader needs the real map tint to survive alpha compositing at small sizes.
function Effects.GetHologramFillColor(target, alpha)
    target = target or Color(255, 255, 255, alpha or 255)
    target.r = math.Clamp(math.floor(styleCvars.red:GetFloat() + 0.5), 0, 255)
    target.g = math.Clamp(math.floor(styleCvars.green:GetFloat() + 0.5), 0, 255)
    target.b = math.Clamp(math.floor(styleCvars.blue:GetFloat() + 0.5), 0, 255)
    target.a = alpha or target.a or 255
    return target
end

Effects.cvars = styleCvars
Effects.settingsVersion = (Effects.settingsVersion or 0) + 1
Effects.ready = nil
Effects.warned = nil
Effects.contactModelsFailed = nil
Effects.propModelsFailed = nil

local metadataModel = Effects.metadataModel

--- Forces Source to upload values staged by render.SetModelLighting.
--- Bare IMesh draws do not commit the ambient-cube constants themselves.
--- @return boolean uploaded
function Effects.CommitConstants()
    if not IsValid(metadataModel) then
        metadataModel = ClientsideModel('models/hunter/blocks/cube025x025x025.mdl')
        if not IsValid(metadataModel) then return false end
        metadataModel:SetNoDraw(true)
        metadataModel:SetModelScale(0)
        Effects.metadataModel = metadataModel
    end

    metadataModel:DrawModel()
    return true
end

local callbackId = 'holo_table_3d.effects'
for _, cvar in pairs(styleCvars) do
    cvars.AddChangeCallback(cvar:GetName(), function()
        Effects.settingsVersion = Effects.settingsVersion + 1
    end, callbackId)
end

--- Returns whether the optional stylized material path is enabled.
--- @return boolean
function Effects.IsEnabled()
    return styleCvars.enabled:GetBool() and Effects.ready ~= false
end

local function evaluateSequence(state, now)
    if state.value == state.target then return end
    local duration = state.duration
    if duration <= 0 then
        state.value = state.target
        return
    end

    local t = math.Clamp((now - state.started) / duration, 0, 1)
    local eased = t * t * (3 - 2 * t)
    state.value = Lerp(eased, state.from, state.target)
    if t >= 1 then state.value = state.target end
end

--- Advances one table's materialization state and caches it for this frame.
--- @param selfTbl table Cached holo-table entity table.
--- @param powered boolean Authoritative per-table power state.
--- @return number reveal Zero is powered off; one is fully materialized.
function Effects.UpdateSequence(selfTbl, powered)
    local now = CurTime()
    powered = powered ~= false
    selfTbl._holoPowered = powered
    local state = selfTbl._holoEffectSequence
    if not state then
        state = { master = false, value = 0, target = 0, from = 0,
            started = now, duration = 0 }
        selfTbl._holoEffectSequence = state
    end

    evaluateSequence(state, now)
    local enabled = Effects.IsEnabled()
    local target = powered and 1 or 0
    if not enabled then
        state.master = false
        state.value = target
        state.target = target
        selfTbl._holoEffectReveal = target
        return target
    end

    if not state.master then
        state.master = true
        state.value = 0
        state.from = 0
        state.target = target
        state.started = now
        state.duration = styleCvars.sequenceTime:GetFloat()
    elseif target ~= state.target then
        state.from = state.value
        state.target = target
        state.started = now
        state.duration = styleCvars.sequenceTime:GetFloat()
    end

    evaluateSequence(state, now)
    selfTbl._holoEffectReveal = math.Clamp(state.value, 0, 1)
    return selfTbl._holoEffectReveal
end

--- @param selfTbl table Cached holo-table entity table.
--- @return number reveal
function Effects.GetReveal(selfTbl)
    if selfTbl._holoEffectReveal == nil then
        return Effects.UpdateSequence(selfTbl, selfTbl._holoPowered)
    end
    return selfTbl._holoEffectReveal
end

local function smoothStep01(value)
    value = math.Clamp(value, 0, 1)
    return value * value * (3 - 2 * value)
end

--- Returns a stable per-contact materialization amount. Contacts wait for the
--- map reveal, enter in a deterministic stagger, and also fade in when first
--- acquired after the table is already running.
--- @param selfTbl table Cached holo-table entity table.
--- @param phase number? Stable contact-specific seed.
--- @param detectedAt number? CurTime when this contact was first observed.
--- @return number visibility Zero is hidden; one is fully materialized.
function Effects.GetContactReveal(selfTbl, phase, detectedAt)
    if not Effects.AreContactsEnabled() then return 1 end

    local reveal = Effects.GetReveal(selfTbl)
    local seed = phase or 0
    local staggerSeed = math.abs(math.sin(seed * 12.9898) * 43758.5453) % 1
    local start = 0.34 + staggerSeed * styleCvars.contactStagger:GetFloat()
    local finish = 0.94
    local tableReveal = smoothStep01((reveal - start)
        / math.max(finish - start, 0.05))

    local acquisition = 1
    if detectedAt then
        local duration = styleCvars.contactMaterializeTime:GetFloat()
        if duration > 0 then
            acquisition = smoothStep01((CurTime() - detectedAt) / duration)
        end
    end
    return math.min(tableReveal, acquisition)
end

--- @param selfTbl table Cached holo-table entity table.
--- @return boolean hidden
function Effects.IsPoweredOff(selfTbl)
    return selfTbl._holoPowered == false and Effects.GetReveal(selfTbl) <= 0.001
end

--- Returns whether baked static and stable dynamic props use the effect.
--- @return boolean
function Effects.ArePropsEnabled()
    return Effects.IsEnabled() and styleCvars.props:GetBool()
end

--- Returns whether live BSP brush entities use the effect.
--- @return boolean
function Effects.AreBrushesEnabled()
    return Effects.IsEnabled() and styleCvars.brushes:GetBool()
end

--- Returns whether tactical styling is enabled for radar contacts.
--- @return boolean
function Effects.AreContactsEnabled()
    return Effects.IsEnabled() and styleCvars.contacts:GetBool()
end

--- Returns whether full-detail contacts use the filled hologram shader.
--- @return boolean
function Effects.AreContactModelsEnabled()
    return Effects.AreContactsEnabled() and styleCvars.contactModels:GetBool()
        and not Effects.contactModelsFailed
end

--- Returns whether contacts get rings and vertical locator beams.
--- @return boolean
function Effects.AreContactMarkersEnabled()
    return Effects.AreContactsEnabled() and styleCvars.contactMarkers:GetBool()
end

function Effects.AreContactBeaconsEnabled()
    return Effects.AreContactMarkersEnabled()
        and styleCvars.contactBeacons:GetBool()
end

function Effects.AreContactTrailsEnabled()
    return Effects.AreContactsEnabled() and styleCvars.contactTrails:GetBool()
end

function Effects.AreContactPingsEnabled()
    return Effects.AreContactsEnabled() and styleCvars.contactPings:GetBool()
end

function Effects.AreContactHalosEnabled()
    return Effects.AreContactModelsEnabled() and styleCvars.contactHalo:GetBool()
        and styleCvars.contactHaloStrength:GetFloat() > 0
end

function Effects.AreContactOcclusionEnabled()
    return Effects.AreContactModelsEnabled()
        and not styleCvars.contactFullShader:GetBool()
        and styleCvars.contactOcclusion:GetBool()
        and styleCvars.contactOcclusionSoftness:GetFloat() > 0
end

--- Copies the depth buffer after map geometry and immediately before radar
--- models. The dedicated contact shader samples this to soften intersections.
function Effects.PrepareContactDepth()
    Effects.contactDepthReadyFrame = nil
    if not Effects.AreContactOcclusionEnabled()
        or not render.UpdateFullScreenDepthTexture
        or not render.GetFullScreenDepthTexture then return false end

    local ok = pcall(render.UpdateFullScreenDepthTexture)
    if not ok then return false end
    local texture = render.GetFullScreenDepthTexture()
    if not texture or texture:IsError() then return false end
    Effects.contactDepthTexture = texture
    Effects.contactDepthReadyFrame = FrameNumber()
    return true
end

function Effects.AreContactLightsEnabled()
    return Effects.AreContactsEnabled() and styleCvars.contactLighting:GetBool()
        and styleCvars.contactLightingStrength:GetFloat() > 0
        and styleCvars.contactLightingMax:GetInt() > 0
end

function Effects.AreContactLabelsEnabled(selfTbl)
    if not (Effects.AreContactsEnabled() and styleCvars.contactLabels:GetBool()) then
        return false
    end
    return selfTbl._holoInvScale >= 1 / styleCvars.contactLabelScale:GetFloat()
end

function Effects.IsAtmosphereEnabled()
    return Effects.IsEnabled() and styleCvars.atmosphere:GetBool()
end

--- Disables the effect path after a material/draw failure until Lua reload.
--- @param err any
function Effects.MarkFailed(err)
    Effects.ready = false
    if Effects.warned then return end
    Effects.warned = true
    ErrorNoHaltWithStack('[holo_table] stylized effect fallback: ' .. tostring(err))
end

--- Uploads per-table values through the ambient-cube vertex constants.
--- Software-clipped meshes bypass shader clipping; an all-in cache needs it.
--- @param selfTbl table Cached holo-table entity table.
--- @param exactClip boolean Apply the physical cylinder and floor planes.
--- @param color Color? Optional per-contact tint override.
--- @param timeOffset number? Stable animation phase offset.
--- @param revealOverride number? Contact-specific materialization amount.
--- @param contactVisibility number? Contact intensity; replaces contour spacing.
function Effects.PushConstants(selfTbl, exactClip, color, timeOffset,
        revealOverride, contactVisibility)
    local tablePos = selfTbl._holoTablePos
    local axis = selfTbl._holoAxis
    local tableAlong = tablePos.x * axis.x + tablePos.y * axis.y + tablePos.z * axis.z
    local radiusSq = exactClip and (90 * 90) or 1e12
    local floorAlong = exactClip and (tableAlong + axis.z * 25) or -1e9

    render.SetModelLighting(0, tablePos.x, tablePos.y, tablePos.z)
    render.SetModelLighting(1, axis.x, axis.y, axis.z)
    -- Worldspawn is intentionally open at the top; only the table floor clips.
    -- Z carries the real table floor for the reveal even when Y disables
    -- shader clipping for an already software-clipped mesh.
    render.SetModelLighting(2, radiusSq, floorAlong, tableAlong + axis.z * 25)
    render.SetModelLighting(3,
        color and color.r / 255 or styleCvars.red:GetFloat() / 255,
        color and color.g / 255 or styleCvars.green:GetFloat() / 255,
        color and color.b / 255 or styleCvars.blue:GetFloat() / 255)
    render.SetModelLighting(4,
        CurTime() + (timeOffset or 0), styleCvars.strength:GetFloat(),
        1 / styleCvars.scanSpacing:GetFloat())
    render.SetModelLighting(5,
        contactVisibility or (1 / styleCvars.contourSpacing:GetFloat()),
        revealOverride == nil and Effects.GetReveal(selfTbl) or revealOverride, 0)
    return Effects.CommitConstants()
end

--- Uploads the compact constants used by the contact silhouette shader.
--- @param selfTbl table Cached holo-table entity table.
--- @param color Color Contact tint.
--- @param visibility number Per-contact reveal/flicker intensity.
function Effects.PushContactHaloConstants(selfTbl, color, visibility)
    local axis = selfTbl._holoAxis
    render.SetModelLighting(0, 2 / math.max(ScrW(), 1),
        2 / math.max(ScrH(), 1), styleCvars.contactHaloWidth:GetFloat())
    render.SetModelLighting(1, (color.r or 255) / 255,
        (color.g or 255) / 255, (color.b or 255) / 255)
    render.SetModelLighting(2, axis.x, axis.y, axis.z)
    render.SetModelLighting(3,
        styleCvars.contactHaloStrength:GetFloat()
            * math.Clamp(visibility or 1, 0, 1),
        CurTime(), 1 / styleCvars.scanSpacing:GetFloat())
    return Effects.CommitConstants()
end

--- Restores model-lighting constants after a custom effect draw.
function Effects.PopConstants()
    render.ResetModelLighting(1, 1, 1)
end

concommand.Remove('holo_table_effect_replay')
concommand.Add('holo_table_effect_replay', function()
    local now = CurTime()
    for _, ent in ipairs(ents.FindByClass('holo_table_3d')) do
        local selfTbl = ent:GetTable()
        selfTbl._holoEffectSequence = {
            master = Effects.IsEnabled(),
            value = 0,
            target = selfTbl._holoPowered == false and 0 or 1,
            from = 0,
            started = now,
            duration = styleCvars.sequenceTime:GetFloat(),
        }
        selfTbl._holoEffectReveal = 0
    end
end)
