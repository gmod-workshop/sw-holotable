local MapCache = ENT.MapCache
local SysTime = SysTime

--- Per-entity init: kicks the global tri-cache + prop prewarms, the static-
--- prop bake (mode-dependent), and the dynamic prop watcher.
function ENT:InitializeMap()
    -- The GPU world bake triangulates every face itself; the per-face tri
    -- cache is only needed by the CPU clip fallback (built lazily there).
    if MapCache.shaderClipCvar:GetBool() then
        MapCache.getWorldBake()
    else
        MapCache.startTriCachePrewarm()
    end
    MapCache.startPropPrewarm()
    local staticMode = MapCache.staticPropBakeModeCvar:GetInt()
    if staticMode == 2 then
        MapCache.startStaticPropPerPropBake(self:GetScale())
    elseif MapCache.canUseGlobalStaticPropBake(self, self:GetScale()) then
        MapCache.startStaticPropBake(self:GetScale())
    end
    MapCache.startDynamicPropBakeWatch()
end

function ENT:CleanupMap()
    self:GetTable().ClipCoroutine = nil
    self:DestroyPendingBuild()
    self:DestroyClippedMap()
    self:DestroyAllInCache()
    self:CleanupDynamicProps()

    timer.Simple(0, function()
        if ents.FindByClass('holo_table_3d')[1] then return end
        MapCache.destroyStaticPropBake()
        MapCache.destroyStaticPropPerPropBake()
        MapCache.destroyDynamicPropBake()
        MapCache.destroyWorldBake()
        MapCache.cleanupPrewarm()
    end)
end

--- Lazy async re-clip on parameter change. Stale ClippedMeshes keep
--- rendering until the new build commits. Debounces 150 ms (first build
--- is exempt) and never preempts an in-flight coroutine. See DESIGN.md
--- "Build pipeline".
--- @see ENT:StartClippedBuild
--- @see ENT:TickClippedBuild
function ENT:TickMapBuild()
    if not (bsp2 and bsp2.GetCurrent()) then return end

    local selfTbl = self:GetTable()
    local scale = self:GetScale()
    local height = self:GetHeight()
    local panX = self:GetPanX()
    local panY = self:GetPanY()

    -- GPU world path: the shared world bake (cl_map_world.lua) never
    -- rebuilds; partial views are trimmed by the exact clip shader. Falls
    -- back to the CPU clip builder below when the shader is off or failed
    -- (a failed draw sets ShaderClipReady = false) or the bake failed.
    if MapCache.shaderClipCvar:GetBool() and selfTbl.ShaderClipReady ~= false
        and (MapCache.getWorldBake() or MapCache.worldBakePending()) then
        if not selfTbl.WorldGpu then
            self:DestroyPendingBuild()
            selfTbl.ClipCoroutine = nil
            self:DestroyClippedMap()
            self:DestroyAllInCache()
            selfTbl.ClippedScale = nil
            selfTbl.WorldGpu = true
        end
        if selfTbl.WorldCheckScale ~= scale or selfTbl.WorldCheckHeight ~= height
            or selfTbl.WorldCheckPanX ~= panX or selfTbl.WorldCheckPanY ~= panY then
            selfTbl.WorldCheckScale, selfTbl.WorldCheckHeight = scale, height
            selfTbl.WorldCheckPanX, selfTbl.WorldCheckPanY = panX, panY
            selfTbl.WorldAllIn = self:CylinderContainsMap(scale, height, panX, panY)
        end
        selfTbl.ShaderClipActive = not selfTbl.WorldAllIn
        selfTbl.ShaderClipEligible = selfTbl.ShaderClipActive
        return
    end
    if selfTbl.WorldGpu then
        -- Leaving the GPU path: the CPU builder starts fresh next.
        selfTbl.WorldGpu = nil
        selfTbl.ShaderClipActive = nil
        selfTbl.ShaderClipEligible = nil
    end

    local stale = selfTbl.ClippedScale ~= scale or selfTbl.ClippedHeight ~= height
        or selfTbl.ClippedPanX ~= panX or selfTbl.ClippedPanY ~= panY

    if selfTbl.RebuildTargetScale ~= scale or selfTbl.RebuildTargetHeight ~= height
        or selfTbl.RebuildTargetPanX ~= panX or selfTbl.RebuildTargetPanY ~= panY then
        selfTbl.RebuildTargetScale = scale
        selfTbl.RebuildTargetHeight = height
        selfTbl.RebuildTargetPanX = panX
        selfTbl.RebuildTargetPanY = panY
        selfTbl.RebuildTargetTime = SysTime()
    end

    local stable = SysTime() - (selfTbl.RebuildTargetTime or 0) > 0.15
    local firstBuild = not selfTbl.ClippedMeshes
    if stale and not selfTbl.ClipCoroutine and (stable or firstBuild) then
        self:StartClippedBuild()
    end
    if selfTbl.ClipCoroutine then
        self:TickClippedBuild()
    end
end



_G.HOLO_TABLE_3D_CL_MAP_CLEANUP = function()
    MapCache.cleanupPrewarm()
    MapCache.destroyWorldBake()
    MapCache.destroyStaticPropBake()
    MapCache.destroyStaticPropPerPropBake()
    MapCache.destroyDynamicPropBake()
    MapCache.clearBrushMeshCache()
    MapCache.cleanupPropEntCache()
end
