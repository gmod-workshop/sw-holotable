ENT.Type            = 'anim'
ENT.Base            = 'base_anim'

ENT.PrintName       = 'Holography Table'
ENT.Author          = 'Doctor'

ENT.Spawnable       = true
ENT.AdminSpawnable  = true
ENT.Editable        = true

--- Declares the holo table's NetworkVars (layer toggles, view params, team).
function ENT:SetupDataTables()
    self:NetworkVar('Bool', 0, 'Entities', { KeyName = 'entities', Edit = { type = 'Boolean' }})
    self:NetworkVar('Bool', 1, 'Map', { KeyName = 'map', Edit = { type = 'Boolean' }})
    self:NetworkVar('Bool', 2, 'Powered', {
        KeyName = 'powered',
        Edit = { type = 'Boolean', order = 1 }
    })

    self:NetworkVar('Float', 0, 'Height', { KeyName = 'height', Edit = { type = 'Float', min = -500, max = 500 }})
    self:NetworkVar('Float', 1, 'Scale', { KeyName = 'scale', Edit = { type = 'Float', min = 1, max = 300 } })

    -- BSP-space pan: cylinder center lands at (PanX, PanY) instead of the BSP origin.
    self:NetworkVar('Float', 2, 'PanX', { KeyName = 'pan_x', Edit = { type = 'Float', min = -16384, max = 16384 } })
    self:NetworkVar('Float', 3, 'PanY', { KeyName = 'pan_y', Edit = { type = 'Float', min = -16384, max = 16384 } })
    self:NetworkVar('Float', 4, 'ProjectorRadius', {
        KeyName = 'projector_radius',
        Edit = { type = 'Float', min = 60, max = 100, order = 5 }
    })

    -- 0 = neutral, 1 / 2 = opposing factions; compared against LVS AITEAM for ghost tinting.
    self:NetworkVar('Int', 0, 'Team', { KeyName = 'team', Edit = { type = 'Int', min = 0, max = 2 } })
end

--- Computes the standard "Fit Map" view from world-model bounds. Keeping
--- this shared lets the server seed new tables without trusting a client,
--- while the client-side fit command can use the same framing math.
--- @param mins Vector
--- @param maxs Vector
--- @return number scale
--- @return number panX
--- @return number panY
--- @return number height
function ENT:ComputeMapFitFromBounds(mins, maxs)
    local centerX = (mins.x + maxs.x) * 0.5
    local centerY = (mins.y + maxs.y) * 0.5
    local halfDX = (maxs.x - mins.x) * 0.5
    local halfDY = (maxs.y - mins.y) * 0.5
    local needRadius = math.sqrt(halfDX * halfDX + halfDY * halfDY) * 1.05
    local scale = math.Clamp(math.ceil(needRadius / 90), 1, 300)

    local axis = self:GetUp()
    local pivotZ = self:GetPos():Dot(axis)
    local minsAlong = mins:Dot(axis)
    local height = math.Clamp(26 - (minsAlong - pivotZ) / scale, -500, 500)

    return scale, centerX, centerY, height
end

--- Compatibility wrapper for entities that survived a Lua auto-refresh from
--- before the Powered NetworkVar existed. Freshly spawned entities always
--- have GetPowered; legacy live instances remain on until they are respawned.
function ENT:IsTablePowered()
    return not self.GetPowered or self:GetPowered()
end
