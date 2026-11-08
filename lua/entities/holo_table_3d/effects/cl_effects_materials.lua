-- Runtime material wrappers for the standalone stylized hologram shader.

local Effects = ENT.HoloEffects
local cvars = Effects.cvars
local bit_band = bit.band

local MATFLAG_ALPHATEST = 0x100
local MATFLAG_ADDITIVE = 0x80
local MATFLAG_NOCULL = 0x2000
local MATFLAG_TRANSLUCENT = 0x200000
local materials = {}
Effects.materials = materials
-- Source IMaterial -> entry. DrawMeshList resolves every cached mesh's
-- material every frame (~2,500 meshes on gm_gmall_2); the keyed lookup below
-- reads $basetexture / $flags back from the engine and concatenates a key
-- string per call, which cost ~190 KB/frame of garbage plus the C calls.
local entryBySrc = setmetatable({}, { __mode = 'k' })
local contactMaterials = {}
Effects.contactMaterials = contactMaterials
local liteContactModelMaterials = {}
local contactHaloModelMaterials = {}
local propModelMaterials = {}
Effects.propModelMaterials = propModelMaterials
local fallbackTexture = Material('models/debug/debugwhite'):GetTexture('$basetexture')
local liteProxyMaterial
local liteProxyVersion = -1
local contactHaloProxyMaterial

local function createContactMaterial(name, model, noCull)
    local params = {
        ['$pixshader'] = 'holotable_contactradiance_ps20b',
        ['$vertexshader'] = 'holotable_contactdepth2_vs20',
        ['$basetexture'] = 'models/debug/debugwhite',
        ['$texture1'] = 'models/debug/debugwhite',
        ['$linearread_texture1'] = '1',
        ['$cull'] = noCull and '0' or '1',
        ['$depthtest'] = '1',
        ['$depthwrite'] = '0',
        -- Keep the filled hull alpha-composited like the map hologram.  An
        -- additive body quickly tonemaps pale neutral contacts to white; the
        -- separate silhouette pass supplies the emissive edge.
        ['$additive'] = '0',
        ['$vertexnormal'] = '1',
        ['$alphablend'] = '1',
        ['$writealpha'] = '1',
    }
    if model then
        params['$model'] = '1'
        params['$softwareskin'] = '1'
    end
    return CreateMaterial(name, 'screenspace_general', params)
end

local function applyContactDepthSettings(mat)
    local texture = Effects.contactDepthTexture
    local ready = Effects.contactDepthReadyFrame == FrameNumber()
        and texture and not texture:IsError()
        and cvars.contactOcclusion:GetBool()
    if ready then
        mat:SetTexture('$texture1', texture)
        mat:SetFloat('$c3_x', 1)
        mat:SetFloat('$c3_y', 1)
        mat:SetFloat('$c3_z', cvars.contactOcclusionSoftness:GetFloat())
        mat:SetFloat('$c3_w', cvars.contactIntersectionStrength:GetFloat())
        return
    end
    mat:SetFloat('$c3_z', 0)
    mat:SetFloat('$c3_w', 0)
end

local function applyLiteContactSettings(mat, version, textureMix, alphaTest,
        translucent)
    applyContactDepthSettings(mat)
    if version == Effects.settingsVersion then return version end
    -- Contacts are often only a few pixels wide, where nearly every sample is
    -- a Fresnel edge. Keep those highlights below clipping so the blue body
    -- remains visible instead of collapsing into a white silhouette.
    mat:SetFloat('$c0_x', cvars.rim:GetFloat() * 0.28)
    mat:SetFloat('$c0_y', cvars.contactOpacity:GetFloat())
    mat:SetFloat('$c0_z', textureMix or 0)
    mat:SetFloat('$c0_w', cvars.scan:GetFloat() * 0.5)
    mat:SetFloat('$c1_x', cvars.band:GetFloat() * 0.42)
    mat:SetFloat('$c1_y', cvars.noise:GetFloat() * 0.72)
    mat:SetFloat('$c1_z', cvars.glitch:GetFloat() * 0.55)
    mat:SetFloat('$c1_w', alphaTest and 0.5
        or (translucent and (1 / 255) or -1))
    mat:SetFloat('$c2_x', (translucent or alphaTest) and 1 or 0)
    mat:SetFloat('$c2_y', 0.72)
    mat:SetFloat('$c2_z', math.max(1, 5
        * (1 + cvars.sweepSpeed:GetFloat())))
    mat:SetFloat('$c2_w', cvars.contactBrightness:GetFloat())
    return Effects.settingsVersion
end

--- Lightweight source-textured wrapper for native studio contacts. Preserving
--- source alpha is essential for vehicle models that contain large invisible
--- engine/glow cards alongside the actual hull.
function Effects.GetLiteContactModelMaterial(name)
    local src = Material(name)
    local baseTexture = src and not src:IsError() and src:GetTexture('$basetexture')
        or fallbackTexture
    if not baseTexture then return nil end
    local flags = src and src:GetInt('$flags') or 0
    local translucent = bit_band(flags, MATFLAG_TRANSLUCENT) ~= 0
    local alphaTest = bit_band(flags, MATFLAG_ALPHATEST) ~= 0
    local noCull = bit_band(flags, MATFLAG_NOCULL) ~= 0
    local key = baseTexture:GetName() .. (translucent and '|t' or '')
        .. (alphaTest and '|a' or '') .. (noCull and '|n' or '')
    local entry = liteContactModelMaterials[key]
    if not entry then
        local mat = createContactMaterial('holo_table_contact_model_v8_'
            .. util.CRC(key), true, noCull)
        if not mat or mat:IsError() then return nil end
        mat:SetTexture('$basetexture', baseTexture)
        entry = {
            mat = mat,
            translucent = translucent,
            alphaTest = alphaTest,
            version = -1,
        }
        liteContactModelMaterials[key] = entry
    end
    entry.version = applyLiteContactSettings(entry.mat, entry.version,
        cvars.textureMix:GetFloat() * 0.2, entry.alphaTest,
        entry.translucent)
    return entry.mat
end

--- Generated IMesh proxies use one texture-free material. Per-draw shader
--- constants provide tint/reveal because render modulation is unreliable here.
function Effects.GetLiteProxyMaterial()
    if not liteProxyMaterial then
        liteProxyMaterial = createContactMaterial(
            'holo_table_contact_proxy_lite_v8', false)
    end
    if not liteProxyMaterial or liteProxyMaterial:IsError() then return nil end
    -- Detect engine-side material initialization/reset after the Lua cache
    -- was populated; its version alone cannot detect zeroed shader constants.
    if math.abs(liteProxyMaterial:GetFloat('$c2_w')
            - cvars.contactBrightness:GetFloat()) > 0.0001
        or math.abs(liteProxyMaterial:GetFloat('$c0_y')
            - cvars.contactOpacity:GetFloat()) > 0.0001 then
        liteProxyVersion = -1
    end
    liteProxyVersion = applyLiteContactSettings(liteProxyMaterial,
        liteProxyVersion, 0)
    return liteProxyMaterial
end

local function createHaloMaterial(name, model, noCull)
    local params = {
        ['$pixshader'] = 'holotable_contactglow_ps20b',
        ['$vertexshader'] = 'holotable_contacthalo_vs20',
        ['$basetexture'] = 'models/debug/debugwhite',
        -- One shell is sufficient for the outline. Drawing both front and
        -- back faces makes dense vehicle meshes stack the glow repeatedly.
        ['$cull'] = noCull and '0' or '1',
        ['$depthtest'] = '1',
        ['$depthwrite'] = '0',
        -- Alpha compositing prevents the many overlapping faces of a tiny
        -- projected model from accumulating into an opaque white blob.
        ['$additive'] = '0',
        ['$vertexnormal'] = '1',
        ['$alphablend'] = '1',
        ['$writealpha'] = '1',
    }
    if model then
        params['$model'] = '1'
        params['$softwareskin'] = '1'
    end
    local mat = CreateMaterial(name, 'screenspace_general', params)
    if mat and not mat:IsError() then
        mat:SetFloat('$c0_x', -1)
        mat:SetFloat('$c0_y', 0)
    end
    return mat
end

function Effects.GetContactHaloProxyMaterial()
    if not contactHaloProxyMaterial then
        contactHaloProxyMaterial = createHaloMaterial(
            'holo_table_contact_halo_proxy_v5', false, false)
    end
    if contactHaloProxyMaterial:IsError() then return nil end
    return contactHaloProxyMaterial
end

function Effects.GetContactHaloModelMaterial(name)
    local src = Material(name)
    local baseTexture = src and not src:IsError() and src:GetTexture('$basetexture')
        or fallbackTexture
    if not baseTexture then return nil end
    local flags = src and src:GetInt('$flags') or 0
    local translucent = bit_band(flags, MATFLAG_TRANSLUCENT) ~= 0
    local alphaTest = bit_band(flags, MATFLAG_ALPHATEST) ~= 0
    local noCull = bit_band(flags, MATFLAG_NOCULL) ~= 0
    local key = baseTexture:GetName() .. (translucent and '|t' or '')
        .. (alphaTest and '|a' or '') .. (noCull and '|n' or '')
    local mat = contactHaloModelMaterials[key]
    if mat and not mat:IsError() then return mat end

    mat = createHaloMaterial('holo_table_contact_halo_model_v5_'
        .. util.CRC(key), true, noCull)
    if not mat or mat:IsError() then return nil end
    mat:SetTexture('$basetexture', baseTexture)
    mat:SetFloat('$c0_x', alphaTest and 0.5
        or (translucent and (1 / 255) or -1))
    mat:SetFloat('$c0_y', (translucent or alphaTest) and 1 or 0)
    contactHaloModelMaterials[key] = mat
    return mat
end

local function applySettings(entry)
    if entry.version == Effects.settingsVersion then return end

    local mat = entry.mat
    mat:SetFloat('$c0_x', cvars.rim:GetFloat())
    mat:SetFloat('$c0_y', cvars.opacity:GetFloat())
    mat:SetFloat('$c0_z', cvars.textureMix:GetFloat())
    mat:SetFloat('$c0_w', cvars.contours:GetFloat())

    mat:SetFloat('$c1_x', cvars.scan:GetFloat())
    mat:SetFloat('$c1_y', -0.35)
    mat:SetFloat('$c1_z', cvars.band:GetFloat())
    mat:SetFloat('$c1_w', -0.08)

    mat:SetFloat('$c2_x', 3)
    mat:SetFloat('$c2_y', cvars.noise:GetFloat())
    mat:SetFloat('$c2_z', 3)
    mat:SetFloat('$c2_w', 0.25)

    mat:SetFloat('$c3_x', cvars.glitch:GetFloat())
    -- Opaque base alpha commonly stores envmap/self-illum masks. It is not
    -- coverage and must neither discard pixels nor reduce output opacity.
    mat:SetFloat('$c3_y', entry.alphaTest and 0.5
        or (entry.translucent and (1 / 255) or -1))
    mat:SetFloat('$c3_z', (entry.translucent or entry.alphaTest) and 1 or 0)
    mat:SetFloat('$c3_w', math.max(0.05, 1 + cvars.sweepSpeed:GetFloat()))
    entry.version = Effects.settingsVersion
end

--- Returns a cached material preserving the source texture and alpha class.
--- @param src IMaterial
--- @return IMaterial?
--- @return boolean depthWrite False for source-translucent surfaces.
function Effects.GetMaterial(src)
    local cached = src and entryBySrc[src]
    if cached then
        applySettings(cached)
        return cached.mat, not cached.translucent
    end

    local baseTexture = src and src:GetTexture('$basetexture') or fallbackTexture
    if not baseTexture then return nil end

    local flags = src and src:GetInt('$flags') or 0
    local translucent = bit_band(flags, MATFLAG_TRANSLUCENT) ~= 0
    local alphaTest = bit_band(flags, MATFLAG_ALPHATEST) ~= 0
    local additive = bit_band(flags, MATFLAG_ADDITIVE) ~= 0
    local noCull = bit_band(flags, MATFLAG_NOCULL) ~= 0
    local textureName = baseTexture:GetName()
    local key = textureName .. (translucent and '|t' or '')
        .. (alphaTest and '|a' or '') .. (additive and '|d' or '')
        .. (noCull and '|n' or '')
    local entry = materials[key]

    if not entry then
        local mat = CreateMaterial('holo_table_effect_' .. util.CRC(key),
            'screenspace_general', {
                ['$pixshader'] = 'holotable_effect_ps20b',
                ['$vertexshader'] = 'holotable_effect_vs20',
                -- BSP adapters often expose only an ITexture, not a path that
                -- CreateMaterial can resolve. Bind the handle after creation.
                ['$basetexture'] = 'models/debug/debugwhite',
                ['$cull'] = noCull and '0' or '1',
                ['$depthtest'] = '1',
                ['$depthwrite'] = translucent and '0' or '1',
                ['$additive'] = additive and '1' or '0',
                ['$vertexnormal'] = '1',
                ['$vertexcolor'] = '1',
                ['$alphablend'] = '1',
                ['$writealpha'] = '1',
        })
        if not mat or mat:IsError() then return nil end
        mat:SetTexture('$basetexture', baseTexture)

        entry = {
            mat = mat,
            translucent = translucent,
            alphaTest = alphaTest,
            additive = additive,
            version = -1,
        }
        materials[key] = entry
    end

    if src then entryBySrc[src] = entry end
    applySettings(entry)
    return entry.mat, not entry.translucent
end

local atlasEntries = setmetatable({}, { __mode = 'k' })
-- ENT is only set while entity files load, and MapCache (map/) loads after
-- the effects; keep the table and resolve MapCache at call time.
local EntityTable = ENT

--- Stylized material for one texture-atlas page variant
--- (map/cl_map_atlas.lua). Same effect settings as the per-texture
--- materials, but the holotable_atlaseffect shader pair, which wraps each
--- vertex's UV inside its atlas tile and takes the alpha class (opaque /
--- alpha-tested / translucent) per vertex. Cull and blending follow the
--- page material's variant.
--- @param pageMat IMaterial The page's plain atlas material.
--- @return IMaterial?
--- @return boolean depthWrite
function Effects.GetAtlasMaterial(pageMat)
    local entry = atlasEntries[pageMat]
    if entry == nil then
        local variant = EntityTable.MapCache.atlasMaterialVariant(pageMat) or {}
        local pageTexture = pageMat:GetTexture('$basetexture')
        local mat = pageTexture and CreateMaterial('holo_table_effect_' .. pageMat:GetName(),
            'screenspace_general', {
                ['$pixshader'] = 'holotable_atlaseffect_ps30',
                ['$vertexshader'] = 'holotable_atlaseffect_vs30',
                ['$basetexture'] = 'models/debug/debugwhite',
                ['$cull'] = variant.noCull and '0' or '1',
                ['$depthtest'] = '1',
                ['$depthwrite'] = variant.translucent and '0' or '1',
                ['$additive'] = '0',
                ['$vertexnormal'] = '1',
                ['$tcsize0'] = '2',
                ['$tcsize1'] = '2',
                ['$alphablend'] = '1',
                ['$writealpha'] = '1',
            })
        if mat and not mat:IsError() then
            mat:SetTexture('$basetexture', pageTexture)
            entry = { mat = mat, translucent = variant.translucent == true, alphaTest = false, version = -1 }
        else
            entry = false
        end
        atlasEntries[pageMat] = entry
    end
    if not entry then return nil, true end
    applySettings(entry)
    return entry.mat, not entry.translucent
end

local function applyModelSettings(entry, opacityCvar)
    if entry.version == Effects.settingsVersion then return end

    local mat = entry.mat
    mat:SetFloat('$c0_x', cvars.rim:GetFloat())
    mat:SetFloat('$c0_y', opacityCvar:GetFloat())
    mat:SetFloat('$c0_z', cvars.textureMix:GetFloat())
    mat:SetFloat('$c0_w', cvars.contours:GetFloat())

    mat:SetFloat('$c1_x', cvars.scan:GetFloat())
    mat:SetFloat('$c1_y', -0.35)
    mat:SetFloat('$c1_z', cvars.band:GetFloat())
    mat:SetFloat('$c1_w', -0.08)

    mat:SetFloat('$c2_x', 3)
    mat:SetFloat('$c2_y', cvars.noise:GetFloat())
    mat:SetFloat('$c2_z', 3)
    mat:SetFloat('$c2_w', 0.25)

    mat:SetFloat('$c3_x', cvars.glitch:GetFloat())
    mat:SetFloat('$c3_y', entry.alphaTest and 0.5
        or (entry.translucent and (1 / 255) or -1))
    mat:SetFloat('$c3_z', (entry.translucent or entry.alphaTest) and 1 or 0)
    mat:SetFloat('$c3_w', math.max(0.05, 1 + cvars.sweepSpeed:GetFloat()))
    entry.version = Effects.settingsVersion
end

local function getModelMaterial(name, cache, prefix, opacityCvar)
    local src = Material(name)
    local baseTexture = src and not src:IsError() and src:GetTexture('$basetexture')
        or fallbackTexture
    if not baseTexture then return nil end

    local flags = src and src:GetInt('$flags') or 0
    local translucent = bit_band(flags, MATFLAG_TRANSLUCENT) ~= 0
    local alphaTest = bit_band(flags, MATFLAG_ALPHATEST) ~= 0
    local additive = bit_band(flags, MATFLAG_ADDITIVE) ~= 0
    local noCull = bit_band(flags, MATFLAG_NOCULL) ~= 0
    local textureName = baseTexture:GetName()
    local key = textureName .. (translucent and '|t' or '')
        .. (alphaTest and '|a' or '') .. (additive and '|d' or '')
        .. (noCull and '|n' or '')
    local entry = cache[key]

    if not entry then
        local mat = CreateMaterial(prefix .. util.CRC(key),
            'screenspace_general', {
                ['$pixshader'] = 'holotable_effect_ps20b',
                ['$vertexshader'] = 'holotable_effect_vs20',
                ['$basetexture'] = 'models/debug/debugwhite',
                ['$model'] = '1',
                ['$softwareskin'] = '1',
                ['$cull'] = noCull and '0' or '1',
                ['$depthtest'] = '1',
                ['$depthwrite'] = translucent and '0' or '1',
                ['$additive'] = additive and '1' or '0',
                ['$vertexnormal'] = '1',
                ['$vertexcolor'] = '1',
                ['$alphablend'] = '1',
                ['$writealpha'] = '1',
        })
        if not mat or mat:IsError() then return nil end
        mat:SetTexture('$basetexture', baseTexture)

        entry = {
            mat = mat,
            translucent = translucent,
            alphaTest = alphaTest,
            version = -1,
        }
        cache[key] = entry
    end

    applyModelSettings(entry, opacityCvar)
    return entry.mat
end

--- Returns a software-skinned contact wrapper using the map hologram shader.
--- @param name string Source model-material name.
--- @return IMaterial?
function Effects.GetContactMaterial(name)
    return getModelMaterial(name, contactMaterials, 'holo_table_contact_',
        cvars.contactOpacity)
end

--- Returns a software-skinned prop wrapper using the map hologram shader.
--- @param name string Source model-material name.
--- @return IMaterial?
function Effects.GetPropModelMaterial(name)
    return getModelMaterial(name, propModelMaterials, 'holo_table_prop_model_',
        cvars.opacity)
end
