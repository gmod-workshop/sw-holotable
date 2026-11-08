include('shared.lua')
include('sh_controls.lua')
include('cl_effects.lua')
include('cl_map.lua')
include('cl_radar.lua')

local HoloEffects = ENT.HoloEffects
local EntityDefinition = ENT
local HOLOGRAM_HOOK = 'holo_table_3d.DrawHologram'
local hologramHookInstalled = false
local ensureHologramHook
local pruneHologramHook
local angleCos, angleSin = math.cos, math.sin
local ANGLE_DEG2RAD = math.pi / 180
local renderCvar = CreateClientConVar('holo_table_render', '1', true, false,
    'Draw holo-table holograms. Useful for profiling the complete render path.')
local stencilBatchCvar = CreateClientConVar('holo_table_stencil_batch', '1', true, false,
    'Share one stencil clear session across all visible holo tables.')
local benchmarkState

local function tablePowered(ent)
    return not ent.GetPowered or ent:GetPowered()
end

--- Sets up the stencil mask mesh and hands off to the map / radar
--- subsystems, then installs the global render hook if needed.
function ENT:Initialize()
    local meshes = util.GetModelMeshes('models/props_phx/construct/metal_plate_curve360x2.mdl')

    local selfTbl = self:GetTable()
    selfTbl.Mask = Mesh()
    selfTbl.Mask:BuildFromTriangles(meshes[1].triangles)

    self:InitializeMap()
    self:InitializeRadar()
    if ensureHologramHook then ensureHologramHook() end
end

-- Radar polling rate. Sub-frame updates aren't visible on tracked entities,
-- so throttle below the default per-frame Think.
local RADAR_THINK_HZ       = 15
local RADAR_THINK_INTERVAL = 1 / RADAR_THINK_HZ

function ENT:Think()
    if tablePowered(self) then self:ThinkRadar() end
    self:SetNextClientThink(CurTime() + RADAR_THINK_INTERVAL)
    return true
end

function ENT:OnRemove()
    local selfTbl = self:GetTable()
    if selfTbl.Mask then
        pcall(selfTbl.Mask.Destroy, selfTbl.Mask)
        selfTbl.Mask = nil
    end
    self:CleanupMap()
    self:CleanupRadar()
    if pruneHologramHook then pruneHologramHook() end
end


--- Stages the shared hologram coordinate frame on self for every subsystem
--- that draws this frame. Consumers read self._holo* instead of recomputing.
--- @param scale number
--- @param height number
--- @param panX number
--- @param panY number
--- @see ENT:DrawHologram
function ENT:UpdateHologramTransform(scale, height, panX, panY)
    local selfTbl = self:GetTable()
    local pos = self:GetPos()
    local tableAng = self:GetAngles()
    local sp, cp = angleSin(tableAng.p * ANGLE_DEG2RAD), angleCos(tableAng.p * ANGLE_DEG2RAD)
    local sy, cy = angleSin(tableAng.y * ANGLE_DEG2RAD), angleCos(tableAng.y * ANGLE_DEG2RAD)
    local sr, cr = angleSin(tableAng.r * ANGLE_DEG2RAD), angleCos(tableAng.r * ANGLE_DEG2RAD)
    local fx, fy, fz = cp * cy, cp * sy, -sp
    local rx, ry, rz = -sr * sp * cy + cr * sy, -sr * sp * sy - cr * cy, -sr * cp
    local ux, uy, uz = cr * sp * cy + sr * sy, cr * sp * sy - sr * cy, cr * cp
    local px, py, pz = pos.x, pos.y, pos.z
    local pivotZ = px * ux + py * uy + pz * uz
    local invScale = 1 / scale
    panX, panY = panX or 0, panY or 0

    local panDot = panX * ux + panY * uy
    local panHoriz = selfTbl._holoPanHoriz or Vector()
    panHoriz:SetUnpacked(panX - ux * panDot, panY - uy * panDot, -uz * panDot)
    local axis = selfTbl._holoAxis or Vector()
    axis:SetUnpacked(ux, uy, uz)
    local origin = selfTbl._holoOrigin or Vector()
    local axisOffset = height - pivotZ * invScale
    origin:SetUnpacked(
        px + ux * axisOffset - (fx * panX - rx * panY) * invScale,
        py + uy * axisOffset - (fy * panX - ry * panY) * invScale,
        pz + uz * axisOffset - (fz * panX - rz * panY) * invScale)

    selfTbl._holoTablePos    = pos
    selfTbl._holoAxis        = axis
    selfTbl._holoAngles      = tableAng
    selfTbl._holoInvScale    = invScale
    selfTbl._holoCylRadius   = scale * 90
    selfTbl._holoFloorOffset = scale * (25 - height) + pivotZ
    selfTbl._holoPanHoriz    = panHoriz
    selfTbl._holoOrigin      = origin

    -- Scalar table-space basis used by RadarBase:Project for allocation-free
    -- LocalToWorld in the per-radar-entry hot loop.
    selfTbl._holoFx, selfTbl._holoFy, selfTbl._holoFz = fx, fy, fz
    selfTbl._holoRx, selfTbl._holoRy, selfTbl._holoRz = rx, ry, rz
    selfTbl._holoUx, selfTbl._holoUy, selfTbl._holoUz = ux, uy, uz
    selfTbl._holoOx, selfTbl._holoOy, selfTbl._holoOz = origin.x, origin.y, origin.z
end


--- Opaque pass + halo silhouette. Stencil work happens in DrawHologram so
--- it doesn't corrupt this entity's halo silhouette.
--- @see ENT:DrawHologram
function ENT:Draw()
    self:DrawModel()
end


-- Module-level scratch reused across every DrawHologram call to keep the
-- stencil/prism setup allocation-free.
local STENCIL_MASK_MTX  = Matrix()
local SCENE_MTX         = Matrix()
local SCENE_SCALE_VEC   = Vector()
local STENCIL_VERT_VEC  = Vector()
local STENCIL_NORMAL_VEC = Vector()
local STENCIL_SEGMENTS  = 32
local STENCIL_RADIUS    = 90
local STENCIL_HEIGHT_OFFSET    = 26
local STENCIL_FLOOR_OFFSET     = 25
local STENCIL_MASK_HEIGHT      = 27
local STENCIL_PRISM_WALL_COUNT = 5

--- Renders the holographic content (clipped map, stencil-masked cylinder,
--- brush entities, baked / fallback props, radars) from the global
--- PostDrawTranslucentRenderables hook.
--- @see ENT:UpdateHologramTransform
--- @see ENT:DrawClippedMap
--- @see ENT:DrawMap
--- @see ENT:DrawBrushEntities
--- @see ENT:DrawRadar
function ENT:DrawHologram(stencilReference, sharedStencil)
    local selfTbl = self:GetTable()
    if not selfTbl.Mask then return end

    local reveal = HoloEffects.UpdateSequence(selfTbl, tablePowered(self))
    if reveal <= 0.001 then return end
    self:UpdateHologramTransform(self:GetScale(), self:GetHeight(),
        self:GetPanX(), self:GetPanY())

    self:TickMapBuild()
    self:DrawClippedMap()

    local contactBloom = HoloEffects.AreContactBloomEnabled()
    selfTbl._holoStencilReference = contactBloom and (stencilReference or 1) or nil
    if not sharedStencil then render.ClearStencil() end
    render.SetStencilEnable(true)
    render.SetStencilWriteMask(255)
    render.SetStencilTestMask(255)
    render.SetStencilPassOperation(STENCIL_REPLACE)
    render.SetStencilCompareFunction(STENCIL_ALWAYS)
    render.SetStencilReferenceValue(stencilReference or 1)

    -- Cache the table pose once; Entity:Get{Pos,Angles,Up} each allocate.
    local tablePos    = selfTbl._holoTablePos
    local tableAng    = selfTbl._holoAngles
    local tableUp     = selfTbl._holoAxis
    local tpx, tpy, tpz = tablePos.x, tablePos.y, tablePos.z
    local tux, tuy, tuz = tableUp.x,  tableUp.y,  tableUp.z

    -- Polygon-mask centre + basis (table top + 26 units up the table normal).
    local centerX = tpx + tux * STENCIL_HEIGHT_OFFSET
    local centerY = tpy + tuy * STENCIL_HEIGHT_OFFSET
    local centerZ = tpz + tuz * STENCIL_HEIGHT_OFFSET
    local basisAx, basisAy, basisAz = selfTbl._holoRx, selfTbl._holoRy, selfTbl._holoRz
    local basisBx, basisBy, basisBz = selfTbl._holoFx, selfTbl._holoFy, selfTbl._holoFz

    -- Stencil mask geometry: no color, no depth.
    render.OverrideColorWriteEnable(true, false)
    render.OverrideDepthEnable(true, false)

    render.SetColorMaterial()
    mesh.Begin( MATERIAL_POLYGON, STENCIL_SEGMENTS )

    local twoPi = math.pi * 2
    for i = 0, STENCIL_SEGMENTS - 1 do
        local rot = twoPi * ( i / STENCIL_SEGMENTS )
        local s = math.sin( rot ) * STENCIL_RADIUS
        local c = math.cos( rot ) * STENCIL_RADIUS
        STENCIL_VERT_VEC:SetUnpacked(
            centerX + basisAx * s + basisBx * c,
            centerY + basisAy * s + basisBy * c,
            centerZ + basisAz * s + basisBz * c)
        mesh.Position(STENCIL_VERT_VEC)
        mesh.AdvanceVertex()
    end

    mesh.End()

    -- Cylinder mask. Translation is in WORLD +Z (matches Vector(0,0,27))
    -- rather than tableUp * 27, so behaviour is unchanged for tilted tables.
    local maskMtx = STENCIL_MASK_MTX
    maskMtx:Identity()
    STENCIL_VERT_VEC:SetUnpacked(tpx, tpy, tpz + STENCIL_MASK_HEIGHT)
    maskMtx:Translate(STENCIL_VERT_VEC)
    maskMtx:SetAngles(tableAng)
    SCENE_SCALE_VEC:SetUnpacked(2, 2, 2)
    maskMtx:Scale(SCENE_SCALE_VEC)

    cam.PushModelMatrix(maskMtx)
        selfTbl.Mask:Draw()
    cam.PopModelMatrix()

    render.OverrideDepthEnable(false, false)
    render.OverrideColorWriteEnable(false, false)

    render.SetStencilCompareFunction( STENCIL_EQUAL )
    render.SetStencilTestMask(contactBloom and 127 or 255)
    render.SetStencilWriteMask(0)
    render.SetStencilPassOperation(STENCIL_KEEP)

    -- Floor clip plane keeps anything below the table top from bleeding
    -- through; offset is tableUp:Dot(tablePos + worldZ * STENCIL_FLOOR_OFFSET).
    local clip = render.EnableClipping(true)
    local floorOffset = tux * tpx + tuy * tpy + tuz * tpz + tuz * STENCIL_FLOOR_OFFSET
    render.PushCustomClipPlane(tableUp, floorOffset)

    -- Pentagonal prism circumscribing the cylinder. Combined with the floor
    -- plane this uses the engine's full 6-plane clip budget.
    local wall_count = STENCIL_PRISM_WALL_COUNT
    local wall_apothem = STENCIL_RADIUS
    for i = 0, wall_count - 1 do
        local angle = twoPi * i / wall_count
        local s, c = math.sin(angle), math.cos(angle)
        local nx = -(basisAx * s + basisBx * c)
        local ny = -(basisAy * s + basisBy * c)
        local nz = -(basisAz * s + basisBz * c)
        STENCIL_NORMAL_VEC:SetUnpacked(nx, ny, nz)
        local d = nx * centerX + ny * centerY + nz * centerZ - wall_apothem
        render.PushCustomClipPlane(STENCIL_NORMAL_VEC, d)
    end

    -- Pinned-pivot scene matrix shared with map / static-prop / radar draws
    -- via _holo* fields staged at the top of DrawHologram.
    local m2 = SCENE_MTX
    m2:Identity()
    m2:SetTranslation(selfTbl._holoOrigin)
    m2:SetAngles(selfTbl._holoAngles)
    SCENE_SCALE_VEC:SetUnpacked(selfTbl._holoInvScale, selfTbl._holoInvScale, selfTbl._holoInvScale)
    m2:Scale(SCENE_SCALE_VEC)

    render.PushFilterMag(TEXFILTER.ANISOTROPIC)
    render.PushFilterMin(TEXFILTER.ANISOTROPIC)
    render.SetLightingMode(2)

    local drewBakedStaticProps = false
    local drewBakedDynamicProps = false
    cam.PushModelMatrix(m2)
        self:DrawMap()

        -- Brush entities ride inside the m2 block so the world-space GPU clip
        -- prism crops oversized geometry the per-bmodel sphere cull misses.
        if self:GetMap() then
            self:DrawBrushEntities()
            if self.DrawBakedStaticProps then
                drewBakedStaticProps = self:DrawBakedStaticProps()
            end
            if self.DrawBakedDynamicProps then
                drewBakedDynamicProps = self:DrawBakedDynamicProps()
            end
        end

    cam.PopModelMatrix()

    -- Legacy csent prop fallbacks and radars are world-space because
    -- Entity:DrawModel ignores cam.PushModelMatrix.
    if self:GetMap() and not drewBakedStaticProps then
        self:DrawStaticProps()
    end
    if self:GetMap() and self.DrawDynamicProps then
        self:DrawDynamicProps(drewBakedDynamicProps)
    end
    if HoloEffects.PrepareContactDepth then
        HoloEffects.PrepareContactDepth()
    end
    self:DrawRadar()

    -- Transparent brush effects composite after player / vehicle radar
    -- models. Drawing them in the opaque brush pass can reject later entity
    -- draws on some custom-shader states even with depth writes overridden.
    if self:GetMap() and self.DrawBrushEntities then
        cam.PushModelMatrix(m2)
            self:DrawBrushEntities(true)
        cam.PopModelMatrix()
    end

    render.SetLightingMode(0)
    render.PopFilterMin()
    render.PopFilterMag()

    render.SetStencilEnable(false)
    render.SetStencilWriteMask(255)
    render.SetStencilTestMask(255)

    for i = 1, wall_count do
        render.PopCustomClipPlane()
    end
    render.PopCustomClipPlane()
    render.EnableClipping(clip)
    if not sharedStencil then
        HoloEffects.DrawContactBloom()
        render.ClearStencil()
    end
end


-- World-space bounding sphere covering the holographic volume. Stencil
-- cylinder is offset +26 along table-up with height 27, radius 90; ~104
-- contains it, round up to 120 for tilted tables.
local CULL_SPHERE_RADIUS = 120
local CULL_FOV_PADDING_DEG = 8

--- PostDrawTranslucentRenderables driver. Cone-vs-sphere culls each table so
--- offscreen / behind-camera tables don't pay DrawHologram's ~2 ms cost.
--- @param bDepth boolean
--- @param bSkybox boolean
--- @param b3DSkybox boolean
local function drawHolograms(bDepth, bSkybox, b3DSkybox)
    if bDepth or bSkybox or b3DSkybox then return end
    if not renderCvar:GetBool() then return end

    local tables = ents.FindByClass('holo_table_3d')
    if not tables[1] then
        hook.Remove('PostDrawTranslucentRenderables', HOLOGRAM_HOOK)
        hologramHookInstalled = false
        return
    end

    -- Skip render-target passes (point_camera / scope RTs / etc.); reproducing
    -- the hologram in a 256-512 px RT pays full cost for an unreadable speck.
    if render.GetRenderTarget() then return end

    local addonStarted = benchmarkState and benchmarkState.collecting and SysTime()
    local eyePos = EyePos()
    local eyeVec = EyeVector()
    local exV, eyV, ezV = eyePos.x, eyePos.y, eyePos.z
    local fxV, fyV, fzV = eyeVec.x, eyeVec.y, eyeVec.z
    local lp = LocalPlayer()
    local fov = (IsValid(lp) and lp:GetFOV() or 90) + CULL_FOV_PADDING_DEG
    local tanHalfFov = math.tan(math.rad(fov) * 0.5)
    local sphereR = CULL_SPHERE_RADIUS
    local negSphereR = -sphereR

    local batchStencil = stencilBatchCvar:GetBool()
    local stencilPrepared = false
    local stencilReference = 1
    local maxReference = HoloEffects.AreContactBloomEnabled() and 127 or 255

    for _, ent in ipairs(tables) do
        if not ent.DrawHologram then continue end

        local p = ent:GetPos()
        local dx, dy, dz = p.x - exV, p.y - eyV, p.z - ezV
        local fwd = dx * fxV + dy * fyV + dz * fzV
        if fwd >= negSphereR then
            local sqrLen = dx * dx + dy * dy + dz * dz
            local lateralSq = sqrLen - fwd * fwd
            local coneFwd = fwd > 0 and fwd or 0
            local maxLat = coneFwd * tanHalfFov + sphereR
            if lateralSq <= maxLat * maxLat then
                if batchStencil and not stencilPrepared then
                    render.ClearStencil()
                    stencilPrepared = true
                end

                EntityDefinition.DrawHologram(ent, stencilReference, batchStencil)

                if batchStencil then
                    stencilReference = stencilReference + 1
                    if stencilReference > maxReference then
                        HoloEffects.DrawContactBloom()
                        render.ClearStencil()
                        stencilReference = 1
                    end
                end
            end
        end
    end

    -- Leave a clean stencil buffer for render hooks that run after ours.
    if stencilPrepared then
        HoloEffects.DrawContactBloom()
        render.ClearStencil()
    end
    if addonStarted then
        benchmarkState.addonFrame = benchmarkState.addonFrame + (SysTime() - addonStarted)
    end
end

ensureHologramHook = function()
    if hologramHookInstalled then return end
    if not ents.FindByClass('holo_table_3d')[1] then return end

    hook.Add('PostDrawTranslucentRenderables', HOLOGRAM_HOOK, drawHolograms)
    hologramHookInstalled = true
end

pruneHologramHook = function()
    timer.Simple(0, function()
        if ents.FindByClass('holo_table_3d')[1] then return end

        hook.Remove('PostDrawTranslucentRenderables', HOLOGRAM_HOOK)
        hologramHookInstalled = false
    end)
end

if ents.FindByClass('holo_table_3d')[1] then
    ensureHologramHook()
else
    hook.Remove('PostDrawTranslucentRenderables', HOLOGRAM_HOOK)
    hologramHookInstalled = false
end

local BENCHMARK_HOOK = 'holo_table_3d.benchmark'
local BENCHMARK_WARMUP = 1

local function benchmarkPercentile(samples, fraction)
    if #samples == 0 then return 0 end
    return samples[math.Clamp(math.ceil(#samples * fraction), 1, #samples)]
end

local function benchmarkApply(config)
    RunConsoleCommand('holo_table_render', tostring(config.render))
    RunConsoleCommand('holo_table_stencil_batch', tostring(config.stencil))
    RunConsoleCommand('holo_table_radar_lod', tostring(config.radar))
    RunConsoleCommand('holo_table_shader_clip', tostring(config.shader))
    RunConsoleCommand('holo_table_effects', tostring(config.effect))
    -- Benchmark the steady-state material, not the startup dissolve or a
    -- recently spawned table's startup dissolve.
    if config.effect == 1 then
        local now = CurTime()
        for _, ent in ipairs(ents.FindByClass('holo_table_3d')) do
            local selfTbl = ent:GetTable()
            selfTbl._holoEffectSequence = {
                master = true, value = 1, target = 1, from = 1,
                started = now, duration = 0,
            }
            selfTbl._holoEffectReveal = 1
        end
    end
end

local function benchmarkReport(phase)
    table.sort(phase.samples)
    local count = #phase.samples
    local avg = count > 0 and phase.total / count or 0
    local addonAvg = count > 0 and phase.addonTotal / count or 0
    local shaderStatus = ''
    if phase.shader == 1 then
        local active, eligible, tables = 0, 0, 0
        for _, ent in ipairs(ents.FindByClass('holo_table_3d')) do
            if not IsValid(ent) then continue end
            tables = tables + 1
            local entTbl = ent:GetTable()
            if entTbl.ShaderClipEligible then eligible = eligible + 1 end
            if entTbl.ShaderClipActive then active = active + 1 end
        end
        shaderStatus = string.format(' shaderActive=%d/%d eligible=%d', active, tables, eligible)
    end
    MsgC(Color(120, 200, 255), string.format(
        '[holo_table] benchmark %-16s frames=%d avg=%.3fms (%.0f fps) ' ..
        'p50=%.3f p95=%.3f p99=%.3f max=%.3f addonCPU=%.3fms%s\n',
        phase.name, count, avg * 1000, avg > 0 and 1 / avg or 0,
        benchmarkPercentile(phase.samples, 0.50) * 1000,
        benchmarkPercentile(phase.samples, 0.95) * 1000,
        benchmarkPercentile(phase.samples, 0.99) * 1000,
        (phase.samples[count] or 0) * 1000, addonAvg * 1000, shaderStatus))
end

local function benchmarkStop(cancelled)
    hook.Remove('PostRender', BENCHMARK_HOOK)
    local state = benchmarkState
    benchmarkState = nil
    if not state then return end

    RunConsoleCommand('holo_table_render', state.saved.render)
    RunConsoleCommand('holo_table_stencil_batch', state.saved.stencil)
    RunConsoleCommand('holo_table_radar_lod', state.saved.radar)
    RunConsoleCommand('holo_table_shader_clip', state.saved.shader)
    RunConsoleCommand('holo_table_effects', state.saved.effect)
    MsgC(Color(120, 200, 255), cancelled
        and '[holo_table] benchmark cancelled; cvars restored.\n'
        or '[holo_table] benchmark complete; cvars restored.\n')
end

local function benchmarkBeginPhase(index)
    local state = benchmarkState
    if not state then return end
    if index > #state.phases then
        benchmarkStop(false)
        return
    end

    state.index = index
    local phase = state.phases[index]
    phase.samples = {}
    phase.total = 0
    phase.addonTotal = 0
    state.addonFrame = 0
    state.collecting = false
    benchmarkApply(phase)
    state.warmupEnd = SysTime() + BENCHMARK_WARMUP
    state.phaseEnd = state.warmupEnd + state.duration
    state.lastFrame = SysTime()
    MsgC(Color(120, 200, 255), string.format(
        '[holo_table] benchmark %d/%d: %s (%.1fs warmup + %.1fs sample)\n',
        index, #state.phases, phase.name, BENCHMARK_WARMUP, state.duration))
end

concommand.Add('holo_table_benchmark', function(_, _, args)
    if benchmarkState then
        benchmarkStop(true)
        return
    end

    local duration = math.Clamp(tonumber(args[1]) or 5, 2, 30)
    local radarLod = GetConVar('holo_table_radar_lod')
    local shaderClip = GetConVar('holo_table_shader_clip')
    local effects = GetConVar('holo_table_effects')
    benchmarkState = {
        duration = duration,
        saved = {
            render = renderCvar:GetString(),
            stencil = stencilBatchCvar:GetString(),
            radar = radarLod and radarLod:GetString() or '0',
            shader = shaderClip and shaderClip:GetString() or '0',
            effect = effects and effects:GetString() or '0',
        },
        phases = {
            { name = 'baseline',        render = 1, stencil = 0, radar = 0, shader = 0, effect = 0 },
            { name = 'batched_stencil', render = 1, stencil = 1, radar = 0, shader = 0, effect = 0 },
            { name = 'radar_markers',   render = 1, stencil = 1, radar = 1, shader = 0, effect = 0 },
            { name = 'shader_clip',     render = 1, stencil = 1, radar = 1, shader = 1, effect = 0 },
            { name = 'stylized_effect', render = 1, stencil = 1, radar = 1, shader = 0, effect = 1 },
            { name = 'render_off',      render = 0, stencil = 1, radar = 1, shader = 0, effect = 0 },
        },
    }

    hook.Add('PostRender', BENCHMARK_HOOK, function()
        local state = benchmarkState
        if not state then return end
        local now = SysTime()
        local phase = state.phases[state.index]

        if now >= state.phaseEnd then
            benchmarkReport(phase)
            benchmarkBeginPhase(state.index + 1)
            return
        end

        if now < state.warmupEnd then
            state.lastFrame = now
            state.addonFrame = 0
            return
        end

        state.collecting = true
        local dt = now - state.lastFrame
        state.lastFrame = now
        phase.samples[#phase.samples + 1] = dt
        phase.total = phase.total + dt
        phase.addonTotal = phase.addonTotal + state.addonFrame
        state.addonFrame = 0
    end)

    benchmarkBeginPhase(1)
end)
