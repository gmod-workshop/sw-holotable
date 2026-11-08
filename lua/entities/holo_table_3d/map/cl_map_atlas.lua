-- Texture atlas: packs textures into a few render-target pages so the world
-- bake and the zoomed-out static-prop cells can batch by page instead of by
-- texture, collapsing thousands of draw calls into a handful. Drawn with the
-- holotable_atlasclip shader pair (holotable_atlaseffect with holo_table_effects 1),
-- which wraps each vertex's UV inside its tile and picks a mip level per
-- pixel. See DESIGN.md "Texture atlas".

local MapCache = ENT.MapCache
local HoloEffects = ENT.HoloEffects
local SysTime = SysTime
local bit_band = bit.band
local math_floor = math.floor
local CACHE_GENERATION = MapCache.CACHE_GENERATION

local atlasCvar = CreateClientConVar('holo_table_atlas', '1', true, false,
    'Draw the baked world, brush entities and zoomed-out static props from texture atlas pages (far fewer draw calls).')
MapCache.atlasCvar = atlasCvar

-- Page layout; must match shaders/src/holotable_atlas_common.h. Each tile
-- cell holds four levels (64/32/16/8 px), each with PAD px of wrapped
-- padding: level 0 on the left, levels 1-3 in a column to its right.
local PAGE_SIZE = 2048
local TILE = 64
local PAD = 2
local LEVELS = {
    { x = 0,  y = 0,  size = 64 },
    { x = 68, y = 0,  size = 32 },
    { x = 68, y = 36, size = 16 },
    { x = 88, y = 36, size = 8 },
}
local CELL_W, CELL_H = 104, 68
local PER_ROW = math_floor(PAGE_SIZE / CELL_W)
local PER_PAGE = PER_ROW * math_floor(PAGE_SIZE / CELL_H)
-- 16 MB of VRAM per page; tiles past the last page fall back to
-- per-texture draws.
local MAX_PAGES = 8
-- Unused strip right of the last cell column: a sentinel block whose loss
-- reveals a device reset that wiped the page.
local SENTINEL_X, SENTINEL_SIZE = PAGE_SIZE - 32, 32
local SENTINEL_R, SENTINEL_G, SENTINEL_B = 37, 201, 113
local PROBE_SIZE = 64

local FILL_HOOK = 'holo_table_3d.atlas_fill'
local FILL_BUDGET = 0.002
-- Also capped by count: a few hundred fill draws in one frame trip the
-- engine's "Too many vertex format changes in frame, whole world not
-- rendered" and the real world flickers out for that frame.
local FILL_MAX_TILES = 64
local MATFLAG_ADDITIVE = 0x80
local MATFLAG_ALPHATEST = 0x100
local MATFLAG_NOCULL = 0x2000
local MATFLAG_TRANSLUCENT = 0x200000
-- Clamp S/T, no mips, no LOD: tiles carry their own padding and levels.
local RT_FLAGS = bit.bor(4, 8, 256, 512)

-- Per-vertex alpha class, added as 2 * class to the tile origin's U (which
-- is always in [0, 1)); the shaders decode it (holotable_atlas_common.h).
-- Alpha-tested textures share the opaque batches: the shader clips them.
local ALPHA_OPAQUE, ALPHA_TEST, ALPHA_BLEND = 0, 1, 2

-- Material variants per page: cull mode and blending cannot vary per
-- vertex. Group ids follow this order, so translucent batches draw after
-- the opaque ones (which write depth): glass composites over what is
-- behind it and stays hidden behind what is in front. (Per-texture meshes
-- drew in arbitrary material order; drawing translucent first let opaque
-- geometry behind a translucent surface paint over it.)
local VARIANTS = {
    { suffix = 'o',  noCull = false, translucent = false },
    { suffix = 'on', noCull = true,  translucent = false },
    { suffix = 't',  noCull = false, translucent = true },
    { suffix = 'tn', noCull = true,  translucent = true },
}

-- Render targets and materials have fixed names and live for the whole
-- process; tile contents are rebuilt per map generation.
local pageRTs, pageMats = {}, {}
local variantOf = setmetatable({}, { __mode = 'k' })
local fillMat, probeRT

local atlas = nil

local function page(index)
    if not pageRTs[index] then
        pageRTs[index] = GetRenderTargetEx('holo_table_atlas_page_' .. index, PAGE_SIZE, PAGE_SIZE,
            RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, RT_FLAGS, 0, IMAGE_FORMAT_RGBA8888)
        pageMats[index] = {}
    end
    return pageRTs[index]
end

local function pageMaterial(index, variant)
    local rt = page(index)
    local mat = pageMats[index][variant]
    if mat then return mat end
    local v = VARIANTS[variant]
    -- $vertexnormal is required, not just for the format: without it
    -- screenspace_general does not upload the ambient-cube registers that
    -- carry the per-table clip constants, so the clip test reads garbage
    -- and discards everything.
    mat = CreateMaterial('holo_table_atlas_mat_' .. index .. v.suffix .. '_v4', 'screenspace_general', {
        ['$pixshader'] = 'holotable_atlasclip_ps30',
        ['$vertexshader'] = 'holotable_atlasclip_vs30',
        ['$basetexture'] = 'models/debug/debugwhite',
        ['$cull'] = v.noCull and '0' or '1',
        ['$depthtest'] = '1',
        ['$depthwrite'] = v.translucent and '0' or '1',
        ['$alphablend'] = v.translucent and '1' or '0',
        ['$vertexnormal'] = '1',
        ['$tcsize0'] = '2',
        ['$tcsize1'] = '2',
        ['$c0_z'] = '-1',
    })
    mat:SetTexture('$basetexture', rt)
    pageMats[index][variant] = mat
    variantOf[mat] = v
    return mat
end

--- Cull / blend variant of an atlas page material (for the effect path).
--- @param mat IMaterial
--- @return table? variant { noCull: boolean, translucent: boolean }
function MapCache.atlasMaterialVariant(mat)
    return variantOf[mat]
end

local function ensureAtlas()
    if atlas and atlas.gen == CACHE_GENERATION then return atlas end
    -- tiles: per base texture; byMat: per source material (tile + variant
    -- + alpha class); slots: tiles in assignment order; fillPos: next slot
    -- to draw.
    atlas = { gen = CACHE_GENERATION, tiles = {}, byMat = {}, slots = {}, count = 0, fillPos = 1,
        pagesUsed = 0, cleared = {} }
    return atlas
end

local function startFill()
    hook.Add('PreRender', FILL_HOOK, MapCache.atlasFillStep)
end

--- Whether bakes should route textures into the atlas.
--- @return boolean
function MapCache.atlasEnabled()
    return atlasCvar:GetBool()
end

--- Assigns (or returns) the atlas tile for a source material. Tiles are
--- keyed by base texture, so materials sharing one share a tile; the
--- material's alpha class is encoded in the returned U and its cull/blend
--- mode picks the page material variant. Returns nil when the material is
--- not atlas-eligible (additive, no base texture) or the atlas is full.
--- @param src IMaterial
--- @return number? groupId Unique per page and variant; batch on it.
--- @return number? originU Level-0 inner origin in page UV space, plus 2 * alpha class.
--- @return number? originV
--- @return IMaterial? pageMaterial
function MapCache.atlasTileFor(src)
    local a = ensureAtlas()
    local rec = a.byMat[src]
    if rec ~= nil then
        if not rec then return nil end
        return rec.groupId, rec.u, rec.v, rec.mat
    end
    local flags = src:GetInt('$flags') or 0
    local tex = src:GetTexture('$basetexture')
    if bit_band(flags, MATFLAG_ADDITIVE) ~= 0 or not tex or tex:IsError() then
        a.byMat[src] = false
        return nil
    end
    local texKey = tex:GetName()
    local tile = a.tiles[texKey]
    if not tile then
        local slot = a.count
        local pageIndex = math_floor(slot / PER_PAGE) + 1
        if pageIndex > MAX_PAGES then
            a.byMat[src] = false
            return nil
        end
        a.count = slot + 1
        local inPage = slot % PER_PAGE
        local x = (inPage % PER_ROW) * CELL_W
        local y = math_floor(inPage / PER_ROW) * CELL_H
        page(pageIndex)
        if pageIndex > a.pagesUsed then a.pagesUsed = pageIndex end
        tile = {
            page = pageIndex, tex = tex, x = x, y = y,
            u = (x + PAD) / PAGE_SIZE, v = (y + PAD) / PAGE_SIZE,
        }
        a.tiles[texKey] = tile
        a.slots[slot + 1] = tile
        startFill()
    end
    local translucent = bit_band(flags, MATFLAG_TRANSLUCENT) ~= 0
    local alphaClass = translucent and ALPHA_BLEND
        or (bit_band(flags, MATFLAG_ALPHATEST) ~= 0 and ALPHA_TEST or ALPHA_OPAQUE)
    local variant = (translucent and 3 or 1) + (bit_band(flags, MATFLAG_NOCULL) ~= 0 and 1 or 0)
    rec = {
        groupId = (variant - 1) * MAX_PAGES + tile.page,
        u = tile.u + 2 * alphaClass, v = tile.v,
        mat = pageMaterial(tile.page, variant),
    }
    a.byMat[src] = rec
    return rec.groupId, rec.u, rec.v, rec.mat
end

--- Number of tiles assigned so far. A bake records it when done and draws
--- once MapCache.atlasFilled(mark) holds.
--- @return number
function MapCache.atlasMark()
    return ensureAtlas().count
end

--- True once the first `mark` tiles are drawn into their pages.
--- @param mark number
--- @return boolean
function MapCache.atlasFilled(mark)
    local a = atlas
    return a ~= nil and a.gen == CACHE_GENERATION and a.fillPos > mark
end

--- Changes whenever fill progress changes (for draw-list caches).
--- @return number
function MapCache.atlasFillProgress()
    return atlas and atlas.fillPos or 0
end

local function drawTile(tile)
    -- One draw per level: UVs extended past [0,1] so the source texture's
    -- own wrap addressing fills the padding, and its mips do the
    -- downsampling for levels 1-3.
    fillMat:SetTexture('$basetexture', tile.tex)
    surface.SetMaterial(fillMat)
    for i = 1, #LEVELS do
        local level = LEVELS[i]
        local size = level.size
        local e = PAD / size
        surface.DrawTexturedRectUV(tile.x + level.x, tile.y + level.y,
            size + 2 * PAD, size + 2 * PAD, -e, -e, 1 + e, 1 + e)
    end
end

--- Draws queued tiles for up to FILL_BUDGET seconds / FILL_MAX_TILES tiles
--- (at least one).
function MapCache.atlasFillStep()
    local a = atlas
    if not a or a.gen ~= CACHE_GENERATION or a.fillPos > a.count then
        hook.Remove('PreRender', FILL_HOOK)
        return
    end
    if not fillMat then
        -- $translucent so the texture's alpha reaches the page (an opaque
        -- UnlitGeneric writes alpha ~0); OverrideBlend makes it a copy.
        fillMat = CreateMaterial('holo_table_atlas_fill_v2', 'UnlitGeneric', {
            ['$basetexture'] = 'models/debug/debugwhite',
            ['$translucent'] = '1',
        })
    end
    local deadline = SysTime() + FILL_BUDGET
    local stop = math.min(a.count, a.fillPos + FILL_MAX_TILES - 1)
    local currentPage
    render.OverrideBlend(true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD)
    surface.SetDrawColor(255, 255, 255, 255)
    repeat
        local tile = a.slots[a.fillPos]
        if tile.page ~= currentPage then
            if currentPage then
                cam.End2D()
                render.PopRenderTarget()
            end
            currentPage = tile.page
            -- Explicit full-page viewport: without it the viewport keeps
            -- the screen size and every tile beyond it is clipped. cam.Start2D
            -- then maps 2D coordinates to the page.
            render.PushRenderTarget(page(currentPage), 0, 0, PAGE_SIZE, PAGE_SIZE)
            cam.Start2D()
            if not a.cleared[currentPage] then
                a.cleared[currentPage] = true
                render.Clear(0, 0, 0, 255)
                surface.SetDrawColor(SENTINEL_R, SENTINEL_G, SENTINEL_B, 255)
                surface.DrawRect(SENTINEL_X, 0, SENTINEL_SIZE, SENTINEL_SIZE)
                surface.SetDrawColor(255, 255, 255, 255)
            end
        end
        drawTile(tile)
        a.fillPos = a.fillPos + 1
    until a.fillPos > stop or SysTime() > deadline
    if currentPage then
        cam.End2D()
        render.PopRenderTarget()
    end
    render.OverrideBlend(false)
end

--- Reads back each filled page's sentinel block and refills pages that lost
--- their contents, e.g. after a D3D device reset. The page is first shrunk
--- into a 64x64 probe on the GPU: capturing a full 2048 page stalls ~25 ms,
--- the probe ~1.5 ms. (Sampling the page through an UnlitGeneric material
--- instead reads shifted texels, so it is copied, not drawn.)
--- @return number lostPages
function MapCache.atlasCheckPages()
    local a = atlas
    if not a or a.gen ~= CACHE_GENERATION or a.pagesUsed == 0 then return 0 end
    probeRT = probeRT or GetRenderTargetEx('holo_table_atlas_probe', PROBE_SIZE, PROBE_SIZE,
        RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, RT_FLAGS, 0, IMAGE_FORMAT_RGBA8888)
    local lost, firstSlot = 0, nil
    for p = 1, a.pagesUsed do
        if not a.cleared[p] then continue end
        render.PushRenderTarget(pageRTs[p], 0, 0, PAGE_SIZE, PAGE_SIZE)
        render.CopyRenderTargetToTexture(probeRT)
        render.PopRenderTarget()
        -- At 1/32 scale probe pixel (63, 0) is the sentinel block's middle.
        render.PushRenderTarget(probeRT, 0, 0, PROBE_SIZE, PROBE_SIZE)
        render.CapturePixels()
        local r, g, b = render.ReadPixel(PROBE_SIZE - 1, 0)
        render.PopRenderTarget()
        if math.abs(r - SENTINEL_R) > 8 or math.abs(g - SENTINEL_G) > 8 or math.abs(b - SENTINEL_B) > 8 then
            lost = lost + 1
            a.cleared[p] = false
            local slot = (p - 1) * PER_PAGE + 1
            if not firstSlot or slot < firstSlot then firstSlot = slot end
        end
    end
    if firstSlot then
        -- Refill from the first lost page on. Bakes gate on atlasFilled, so
        -- affected meshes pause for the few frames this takes.
        a.fillPos = math.min(a.fillPos, firstSlot)
        startFill()
        MsgC(Color(255, 200, 120), string.format('[holo_table] Atlas: %d page(s) lost their contents; refilling\n', lost))
    end
    return lost
end

-- Device resets (alt-tab from exclusive fullscreen, mode changes) wipe
-- render targets without telling Lua. Check after the triggers that can
-- cause one; the readback stalls the GPU briefly, so not every frame.
local CHECK_HOOK = 'holo_table_3d.atlas_check'
local checkPending, hadFocus = false, true
hook.Add('Think', CHECK_HOOK, function()
    local focus = system.HasFocus()
    if focus and not hadFocus then checkPending = true end
    hadFocus = focus
end)
hook.Add('OnScreenSizeChanged', CHECK_HOOK, function() checkPending = true end)
hook.Add('PreRender', CHECK_HOOK, function()
    if not checkPending then return end
    checkPending = false
    MapCache.atlasCheckPages()
end)

--- Plain (non-effect) atlas draws still go through the atlas shader, which
--- clips against per-table constants; with nothing to clip it needs an
--- unbounded volume staged. Stage once per batch: the commit is a hidden
--- model draw. Pair with MapCache.atlasEndUnclipped.
--- @return boolean ok
function MapCache.atlasBeginUnclipped()
    render.SuppressEngineLighting(true)
    render.SetModelLighting(0, 0, 0, 0)
    render.SetModelLighting(1, 0, 0, 1)
    render.SetModelLighting(2, 1e12, -1e9, 1e9)
    if HoloEffects.CommitConstants() then return true end
    render.SuppressEngineLighting(false)
    return false
end

function MapCache.atlasEndUnclipped()
    render.ResetModelLighting(1, 1, 1)
    render.SuppressEngineLighting(false)
end

--- Draws atlas mesh items (plain path) with unbounded clip constants. The
--- caller owns the matrix, clip planes and stencil state.
--- @param meshes table[] Items with `mat` (page material) and `mesh`.
--- @param first number Index of the first atlas item.
function MapCache.drawAtlasItemsUnclipped(meshes, first)
    if not MapCache.atlasBeginUnclipped() then return false end
    local lastMat
    for i = first, #meshes do
        local item = meshes[i]
        if item.atlas then
            -- Translucent variants disable depth writes in the material.
            if item.mat ~= lastMat then
                lastMat = item.mat
                render.SetMaterial(lastMat)
            end
            item.mesh:Draw()
        end
    end
    MapCache.atlasEndUnclipped()
    return true
end

local ATLAS_POS, ATLAS_NORMAL = Vector(), Vector()

--- Mesh builder for atlas groups: flat stride-10 buffer
--- (px, py, pz, nx, ny, nz, u, v, tileU, tileV). The page material is passed
--- as the format hint so the mesh gets the atlas shader's inputs (position,
--- normal, two texcoord sets).
--- @param buf number[]
--- @param hint IMaterial
--- @return IMesh?
function MapCache.buildAtlasMesh(buf, hint)
    local vertCount = math_floor(#buf / 10)
    vertCount = vertCount - (vertCount % 3)
    if vertCount < 3 then return nil end
    local msh = Mesh(hint)
    mesh.Begin(msh, MATERIAL_TRIANGLES, vertCount / 3)
    local o = 0
    for _ = 1, vertCount do
        ATLAS_POS:SetUnpacked(buf[o + 1], buf[o + 2], buf[o + 3])
        ATLAS_NORMAL:SetUnpacked(buf[o + 4], buf[o + 5], buf[o + 6])
        mesh.Position(ATLAS_POS)
        mesh.Normal(ATLAS_NORMAL)
        mesh.TexCoord(0, buf[o + 7], buf[o + 8])
        mesh.TexCoord(1, buf[o + 9], buf[o + 10])
        mesh.AdvanceVertex()
        o = o + 10
    end
    mesh.End()
    return msh
end

--- Debug status.
--- @return table?
function MapCache.atlasStats()
    if not atlas then return nil end
    return { tiles = atlas.count, pages = atlas.pagesUsed, pending = atlas.count - atlas.fillPos + 1,
        capacity = PER_PAGE * MAX_PAGES, tileSize = TILE }
end

concommand.Add('holo_table_atlas_status', function()
    local s = MapCache.atlasStats()
    if not s then
        print('[holo_table] atlas: not started')
        return
    end
    print(string.format('[holo_table] atlas: tiles=%d/%d pages=%d (%d MB VRAM) pending=%d',
        s.tiles, s.capacity, s.pages, s.pages * PAGE_SIZE * PAGE_SIZE * 4 / 1048576, s.pending))
end)
