-- Shared draw helpers for applying the stylized shader to cached IMeshes.

local Effects = ENT.HoloEffects
local render_SetMaterial = render.SetMaterial
local drawSkipped

--- Draws cached mesh records with their stylized replacement materials.
--- The caller owns model-matrix and effect render state.
--- @param meshes table[] Records containing `mat` and `mesh`.
--- @param depthWriteFilter boolean? Draw only opaque/alpha-tested (`true`) or
--- source-translucent (`false`) records; nil draws both.
function Effects.DrawMeshList(meshes, depthWriteFilter)
    if drawSkipped then return end
    local depthWrite = true
    local GetMaterial = Effects.GetMaterial
    local lastSrc, boundMat, mat, itemDepthWrite
    for i = 1, #meshes do
        local item = meshes[i]
        if item.mesh then
            -- Bake lists are sorted by material, so consecutive items usually
            -- share one; skip the lookup and SetMaterial when unchanged.
            local src = item.mat
            if src ~= lastSrc then
                lastSrc = src
                if item.atlas then
                    mat, itemDepthWrite = Effects.GetAtlasMaterial(src)
                else
                    mat, itemDepthWrite = GetMaterial(src)
                end
                if not mat then error('stylized effect material unavailable') end
            end
            if depthWriteFilter ~= nil and itemDepthWrite ~= depthWriteFilter then continue end
            if itemDepthWrite ~= depthWrite then
                depthWrite = itemDepthWrite
                render.OverrideDepthEnable(true, depthWrite)
            end
            if mat ~= boundMat then
                render_SetMaterial(mat)
                boundMat = mat
            end
            item.mesh:Draw()
        end
    end

    -- BeginDraw establishes writable depth for the batch. Restore that
    -- invariant so the next mesh list is not affected by a translucent tail.
    if not depthWrite then render.OverrideDepthEnable(true, true) end
end

--- Begins one stylized IMesh batch and uploads the table constants.
--- @param selfTbl table Cached holo-table entity table.
--- @param exactClip boolean Apply exact cylindrical and floor clipping.
--- @return boolean ready
function Effects.BeginDraw(selfTbl, exactClip)
    drawSkipped = Effects.IsPoweredOff(selfTbl)
    if drawSkipped then return true end

    render.SuppressEngineLighting(true)
    if not Effects.PushConstants(selfTbl, exactClip) then
        render.SuppressEngineLighting(false)
        Effects.MarkFailed('could not create metadata upload model')
        return false
    end

    render.OverrideDepthEnable(true, true)
    return true
end

--- Restores state after BeginDraw and records a guarded draw result.
--- @param ok boolean Result from pcall.
--- @param err any Error returned by pcall.
--- @return boolean drew
function Effects.EndDraw(ok, err)
    if drawSkipped then
        drawSkipped = false
        Effects.ready = true
        return true
    end

    render.OverrideDepthEnable(false, false)
    Effects.PopConstants()
    render.SuppressEngineLighting(false)

    if not ok then
        Effects.MarkFailed(err)
        return false
    end

    Effects.ready = true
    return true
end
