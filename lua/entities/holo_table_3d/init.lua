AddCSLuaFile('shared.lua')
AddCSLuaFile('cl_init.lua')
AddCSLuaFile('sh_controls.lua')
AddCSLuaFile('sh_power.lua')
AddCSLuaFile('cl_effects.lua')
AddCSLuaFile('cl_radar.lua')
AddCSLuaFile('cl_map.lua')

for _, f in ipairs(file.Find('entities/holo_table_3d/effects/*.lua', 'LUA')) do
    AddCSLuaFile('effects/' .. f)
end

for _, f in ipairs(file.Find('entities/holo_table_3d/map/*.lua', 'LUA')) do
    AddCSLuaFile('map/' .. f)
end

for _, f in ipairs(file.Find('entities/holo_table_3d/radar/*.lua', 'LUA')) do
    AddCSLuaFile('radar/' .. f)
end

include('shared.lua')
include('sh_power.lua')
include('sh_controls.lua')

--- Server spawn: model + physics, hands off to the controls subsystem,
--- seeds default view params.
function ENT:Initialize()
    self:SetModel('models/kingpommes/starwars/venator/galaxy_holo_1.mdl')
    self:PhysicsInit(SOLID_VPHYSICS)

    self:InitializePower()
    self:InitializeControls()

    self:SetMap(true)
    self:SetEntities(true)
    self:SetProjectorRadius(86)

    local world = game.GetWorld()
    local mins, maxs = world:GetModelBounds()
    local scale, panX, panY, height = self:ComputeMapFitFromBounds(mins, maxs)
    self:SetScale(scale)
    self:SetPanX(panX)
    self:SetPanY(panY)
    self:SetHeight(height)
    self:SetTablePowered(true)
end

function ENT:OnRemove()
    self:CleanupControls()
    self:CleanupPower()
end
