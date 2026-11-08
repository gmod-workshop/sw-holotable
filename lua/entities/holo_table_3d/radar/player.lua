-- Live player-model radar. Remote players: temporarily move the real entity
-- to the projected pose for one DrawModel call. Local player: ClientsideModel
-- mirror because first-person local-player drawing is engine-suppressed.

local HoloEffects = RADAR.HoloEffects

local mirrorState = _G.HOLO_TABLE_3D_PLAYER_RADAR_MIRRORS
if mirrorState then
    for cs in pairs(mirrorState) do
        if IsValid(cs) then SafeRemoveEntity(cs) end
    end
end
mirrorState = {}
_G.HOLO_TABLE_3D_PLAYER_RADAR_MIRRORS = mirrorState

local localBonePoseCvar = CreateClientConVar('holo_table_player_anim_events', '1', true, false,
    'Experimental: copy the local player solved bone pose to the holo-table mirror.')
local playerLightCvar = CreateClientConVar('holo_table_player_light', '1', true, false,
    'Brightness for holo-table player/weapon radar models when engine lighting is suppressed.')
local PLAYER_MARKER_LOCAL = Color(119, 145, 190, 240)
local PLAYER_MARKER_FRIENDLY = Color(100, 255, 150, 240)
local PLAYER_MARKER_HOSTILE = Color(255, 90, 90, 240)
local PLAYER_MARKER_NEUTRAL = Color(119, 145, 190, 240)
local PLAYER_MODEL_NEUTRAL = Color(102, 159, 255, 240)
local PLAYER_MARKER_RADIUS = 1.25

local function beginPlayerLighting()
    local light = math.Clamp(playerLightCvar:GetFloat(), 0, 3)
    render.SuppressEngineLighting(true)
    render.ResetModelLighting(light, light, light)
end

local function endPlayerLighting()
    render.ResetModelLighting(1, 1, 1)
    render.SuppressEngineLighting(false)
end

local function drawPlayerAndWeapon(ply, radar, modelColor, phase)
    ply:SetupBones()
    if not HoloEffects.DrawContactModel(radar.entityTable, ply, modelColor, phase) then
        ply:DrawModel()
    end

    local wep = ply:GetActiveWeapon()
    if IsValid(wep) and not HoloEffects.DrawContactModel(radar.entityTable, wep,
            modelColor, phase + 0.35) then
        wep:DrawModel()
    end
end

--- Detaches and removes a mirror record's csent.
--- @param mirror table?
local function removeMirror(mirror)
    if not mirror then return end
    local cs = mirror.csent
    if IsValid(cs) then
        mirrorState[cs] = nil
        cs:SetParent(NULL)
        SafeRemoveEntity(cs)
    end
end

local function setupMirrorEntity(cs)
    cs:SetNoDraw(true)
    cs:SetSolid(SOLID_NONE)
    cs:SetMoveType(MOVETYPE_NONE)
    cs:PhysicsDestroy()

    mirrorState[cs] = true
end

--- Builds the local player's mirror, including a GetPlayerColor proxy so
--- player-color materials sample from the source player.
--- @param ply Player
--- @param model string
--- @return table? mirror
local function makePlayerMirror(ply, model)
    local cs = ClientsideModel(model, RENDERGROUP_OTHER)
    if not IsValid(cs) then return nil end

    setupMirrorEntity(cs)

    cs.GetPlayerColor = function()
        if IsValid(ply) then return ply:GetPlayerColor() end
        return vector_origin
    end

    return { csent = cs, model = model }
end

--- @param model string
--- @return table?
local function makeWeaponMirror(model)
    local cs = ClientsideModel(model, RENDERGROUP_OTHER)
    if not IsValid(cs) then return nil end

    setupMirrorEntity(cs)

    return { csent = cs, model = model }
end

--- Returns / lazily rebuilds the local-player mirror when the player model changes.
--- @param radar table
--- @param ply Player
--- @return table?
local function getLocalMirror(radar, ply)
    local model = ply:GetModel()
    if not model or model == '' then return nil end

    local mirror = radar.LocalPlayerMirror
    if mirror and IsValid(mirror.csent) and mirror.model == model then
        return mirror
    end

    removeMirror(mirror)
    mirror = makePlayerMirror(ply, model)
    radar.LocalPlayerMirror = mirror
    return mirror
end

local STOCK_WEAPON_MODELS = {
    gmod_camera = 'models/maxofs2d/camera.mdl',
    gmod_tool = 'models/weapons/w_toolgun.mdl',
    weapon_357 = 'models/weapons/w_357.mdl',
    weapon_ar2 = 'models/weapons/w_irifle.mdl',
    weapon_crossbow = 'models/weapons/w_crossbow.mdl',
    weapon_crowbar = 'models/weapons/w_crowbar.mdl',
    weapon_frag = 'models/weapons/w_grenade.mdl',
    weapon_physcannon = 'models/weapons/w_physics.mdl',
    weapon_physgun = 'models/weapons/w_physics.mdl',
    weapon_pistol = 'models/weapons/w_pistol.mdl',
    weapon_rpg = 'models/weapons/w_rocket_launcher.mdl',
    weapon_shotgun = 'models/weapons/w_shotgun.mdl',
    weapon_slam = 'models/weapons/w_slam.mdl',
    weapon_smg1 = 'models/weapons/w_smg1.mdl',
    weapon_stunstick = 'models/weapons/w_stunbaton.mdl',
}

local function validModelName(model)
    return isstring(model) and model ~= ''
end

--- Best-effort world model lookup for a weapon: live model -> WorldModel ->
--- weapons.Get -> list.Get('Weapon') -> stock fallback -> view model -> ViewModel.
--- @param wep Weapon
--- @return string?
local function getWeaponModel(wep)
    local model = wep:GetModel()
    if validModelName(model) then return model end

    model = wep.WorldModel
    if validModelName(model) then return model end

    local class = wep:GetClass()
    local weaponData = weapons.Get(class)
    model = weaponData and weaponData.WorldModel
    if validModelName(model) then return model end
    local scriptedWeaponData = weaponData

    local weaponList = list.Get('Weapon')
    weaponData = weaponList and weaponList[class]
    model = weaponData and weaponData.WorldModel
    if validModelName(model) then return model end

    model = STOCK_WEAPON_MODELS[class]
    if validModelName(model) then return model end

    local owner = wep:GetOwner()
    local viewModel = IsValid(owner) and owner.GetViewModel and owner:GetViewModel()
    model = IsValid(viewModel) and viewModel:GetModel() or nil
    if validModelName(model) then return model end

    model = wep.ViewModel or scriptedWeaponData and scriptedWeaponData.ViewModel or weaponData and weaponData.ViewModel
    if validModelName(model) then return model end

    return nil
end

--- @param radar table
--- @param wep Weapon?
--- @return table?
local function getLocalWeaponMirror(radar, wep)
    if not IsValid(wep) then
        removeMirror(radar.LocalWeaponMirror)
        radar.LocalWeaponMirror = nil
        return nil
    end

    local model = getWeaponModel(wep)
    if not model then
        removeMirror(radar.LocalWeaponMirror)
        radar.LocalWeaponMirror = nil
        return nil
    end

    local mirror = radar.LocalWeaponMirror
    if not (mirror and IsValid(mirror.csent) and mirror.model == model) then
        removeMirror(mirror)
        mirror = makeWeaponMirror(model)
        radar.LocalWeaponMirror = mirror
    end

    if not (mirror and IsValid(mirror.csent)) then return nil end

    return mirror
end

local function syncMirrorBodygroups(ply, cs)
    cs:SetSkin(ply:GetSkin() or 0)

    for id = 0, ply:GetNumBodyGroups() - 1 do
        cs:SetBodygroup(id, ply:GetBodygroup(id))
    end
end

local function syncMirrorPoseParams(ply, cs)
    for i = 0, ply:GetNumPoseParameters() - 1 do
        local name = ply:GetPoseParameterName(i)
        if not name then continue end

        local minValue, maxValue = ply:GetPoseParameterRange(i)
        cs:SetPoseParameter(name, math.Remap(ply:GetPoseParameter(name), 0, 1, minValue, maxValue))
    end

    cs:InvalidateBoneCache()
end

local function syncMirrorMainAnimation(ply, mirror)
    local cs = mirror.csent
    local seq = ply:GetSequence()
    if cs:GetSequence() ~= seq then
        cs:SetSequence(seq)
    end
    cs:SetCycle(ply:GetCycle())
    cs:SetPlaybackRate(ply:GetPlaybackRate())
end

local SOURCE_ROOT_MTX = Matrix()
local SOURCE_ROOT_INV_MTX = Matrix()
local TARGET_ROOT_MTX = Matrix()
local SOURCE_BONE_MTX = Matrix()
local LOCAL_BONE_MTX = Matrix()
local TARGET_BONE_MTX = Matrix()
local BONE_SCALE_VEC = Vector()

--- Returns the cached list of mirror bone IDs that are valid on both
--- source and mirror; rebuilt when bone counts change.
--- @param ply Player
--- @param mirror table
--- @return number[]
local function getMirrorBoneIds(ply, mirror)
    local cs = mirror.csent
    local plyBoneCount = ply:GetBoneCount() or 0
    local mirrorBoneCount = cs:GetBoneCount() or 0

    if mirror.ValidBoneIds and mirror.ValidPlyBoneCount == plyBoneCount
        and mirror.ValidMirrorBoneCount == mirrorBoneCount then
        return mirror.ValidBoneIds
    end

    local boneCount = math.min(plyBoneCount, mirrorBoneCount)
    local ids = {}
    for boneId = 0, boneCount - 1 do
        if cs:GetBoneName(boneId) ~= '__INVALIDBONE__' then
            ids[#ids + 1] = boneId
        end
    end

    mirror.ValidBoneIds = ids
    mirror.ValidPlyBoneCount = plyBoneCount
    mirror.ValidMirrorBoneCount = mirrorBoneCount
    return ids
end

--- Copies LocalPlayer()'s solved bone matrices onto the mirror at the
--- projected root pose. Handles attack / reload animations that
--- BaseAnimating layer APIs can't drive on a ClientsideModel.
--- @param ply Player
--- @param mirror table
--- @param rootPos Vector
--- @param rootAng Angle
--- @param invScale number
--- @param sourcePos Vector
--- @param sourceAng Angle
local function copyLocalBonePose(ply, mirror, rootPos, rootAng, invScale, sourcePos, sourceAng)
    if not localBonePoseCvar:GetBool() then return end

    local cs = mirror.csent
    local boneIds = getMirrorBoneIds(ply, mirror)
    if #boneIds == 0 then return end

    ply:SetupBones()
    cs:SetupBones()

    SOURCE_ROOT_MTX:Identity()
    SOURCE_ROOT_MTX:SetTranslation(sourcePos)
    SOURCE_ROOT_MTX:SetAngles(sourceAng)
    SOURCE_ROOT_INV_MTX:Set(SOURCE_ROOT_MTX)
    SOURCE_ROOT_INV_MTX:InvertTR()

    TARGET_ROOT_MTX:Identity()
    TARGET_ROOT_MTX:SetTranslation(rootPos)
    TARGET_ROOT_MTX:SetAngles(rootAng)

    BONE_SCALE_VEC:SetUnpacked(invScale, invScale, invScale)

    for i = 1, #boneIds do
        local boneId = boneIds[i]
        if ply.CopyBoneMatrix then
            ply:CopyBoneMatrix(boneId, SOURCE_BONE_MTX)
        else
            local sourceMatrix = ply:GetBoneMatrix(boneId)
            if not sourceMatrix then continue end
            SOURCE_BONE_MTX:Set(sourceMatrix)
        end

        LOCAL_BONE_MTX:Set(SOURCE_ROOT_INV_MTX)
        LOCAL_BONE_MTX:Mul(SOURCE_BONE_MTX)
        LOCAL_BONE_MTX:ScaleTranslation(invScale)

        TARGET_BONE_MTX:Set(TARGET_ROOT_MTX)
        TARGET_BONE_MTX:Mul(LOCAL_BONE_MTX)
        TARGET_BONE_MTX:Scale(BONE_SCALE_VEC)

        cs:SetBoneMatrix(boneId, TARGET_BONE_MTX)
    end
end

local function syncLocalMirror(ply, mirror)
    local cs = mirror.csent
    cs:SetColor(ply:GetColor())
    cs:SetMaterial(ply:GetMaterial() or '')
    syncMirrorBodygroups(ply, cs)

    syncMirrorMainAnimation(ply, mirror)
    syncMirrorPoseParams(ply, cs)
end

local function syncLocalWeaponMirror(wep, weaponCs, invScale)
    weaponCs:SetColor(wep:GetColor())
    weaponCs:SetMaterial(wep:GetMaterial() or '')
    weaponCs:SetSkin(wep:GetSkin() or 0)
    weaponCs:SetModelScale(wep:GetModelScale() * invScale, 0)

    for id = 0, wep:GetNumBodyGroups() - 1 do
        weaponCs:SetBodygroup(id, wep:GetBodygroup(id))
    end
end

local function clearWeaponParent(weaponCs)
    if weaponCs:GetParent() ~= NULL then
        weaponCs:SetParent(NULL)
    end

    if EF_BONEMERGE then weaponCs:RemoveEffects(EF_BONEMERGE) end
    if EF_BONEMERGE_FASTCULL then weaponCs:RemoveEffects(EF_BONEMERGE_FASTCULL) end
    if EF_PARENT_ANIMATES then weaponCs:RemoveEffects(EF_PARENT_ANIMATES) end
    if EF_FOLLOWBONE then weaponCs:RemoveEffects(EF_FOLLOWBONE) end
end

local WEAPON_BONEMERGE_BONES = {
    'ValveBiped.Bip01_R_Hand',
    'ValveBiped.Anim_Attachment_RH',
}

local function canBoneMergeWeapon(weaponCs)
    for _, name in ipairs(WEAPON_BONEMERGE_BONES) do
        if weaponCs:LookupBone(name) then return true end
    end

    return false
end

--- Bone-merges the weapon mirror onto the player mirror, falling back to an
--- attachment when bone-merge isn't viable.
local function attachWeaponMirror(playerMirror, weaponCs)
    clearWeaponParent(weaponCs)
    weaponCs:SetPos(playerMirror:GetPos())
    weaponCs:SetAngles(playerMirror:GetAngles())

    if canBoneMergeWeapon(weaponCs) and EF_BONEMERGE then
        weaponCs:SetParent(playerMirror)
        weaponCs:AddEffects(EF_BONEMERGE)
        if EF_BONEMERGE_FASTCULL then weaponCs:AddEffects(EF_BONEMERGE_FASTCULL) end
        if EF_PARENT_ANIMATES then weaponCs:AddEffects(EF_PARENT_ANIMATES) end
        return
    end

    local attachId = playerMirror:LookupAttachment('anim_attachment_RH')
    if attachId > 0 then
        weaponCs:SetParent(playerMirror, attachId)
        if EF_PARENT_ANIMATES then weaponCs:AddEffects(EF_PARENT_ANIMATES) end
    end
end

--- @param radar table
--- @param ply Player
--- @param invScale number
--- @param sourcePos Vector
--- @param mirror table
local function drawProjectedLocalPlayerInner(radar, ply, invScale, sourcePos, mirror,
    markerColor, modelColor, phase)
    local cs = mirror.csent
    syncLocalMirror(ply, mirror)

    local sourceAng = ply:GetAngles()
    local wpos, wang = radar:Project(sourcePos, sourceAng)
    cs:SetPos(wpos)
    cs:SetAngles(wang)
    cs:SetModelScale(ply:GetModelScale() * invScale, 0)
    cs:SetupBones()
    copyLocalBonePose(ply, mirror, wpos, wang, invScale, sourcePos, sourceAng)

    if not HoloEffects.DrawContactModel(radar.entityTable, cs, modelColor, phase) then
        cs:DrawModel()
    end

    local activeWeapon = ply:GetActiveWeapon()
    local weaponMirror = getLocalWeaponMirror(radar, activeWeapon)
    local weaponCs = weaponMirror and weaponMirror.csent
    if IsValid(weaponCs) then
        syncLocalWeaponMirror(activeWeapon, weaponCs, invScale)
        if weaponMirror.attachedTo ~= cs or weaponCs:GetParent() ~= cs then
            attachWeaponMirror(cs, weaponCs)
            weaponMirror.attachedTo = cs
        end
        weaponCs:SetupBones()
        if not HoloEffects.DrawContactModel(radar.entityTable, weaponCs,
            modelColor, phase + 0.35) then
            weaponCs:DrawModel()
        end
    end
    HoloEffects.DrawContactMarker(radar.entityTable, wpos, markerColor,
        math.Clamp(28 * invScale, 0.8, 2.5),
        math.Clamp(80 * invScale, 2.5, 7), phase)
end

local function drawProjectedLocalPlayer(radar, ply, invScale, sourcePos,
    markerColor, modelColor, phase)
    local mirror = getLocalMirror(radar, ply)
    if not (mirror and IsValid(mirror.csent)) then return end

    local ok, err = pcall(drawProjectedLocalPlayerInner, radar, ply, invScale,
        sourcePos, mirror, markerColor, modelColor, phase)

    if not ok then
        ErrorNoHaltWithStack('[holo_table] local player radar draw aborted: ' .. tostring(err))
    end
end

--- Remote-player path: temporarily move the real entity to the projected
--- pose, draw, restore. wOS-style trick.
--- @param radar table
--- @param ply Player
--- @param invScale number
--- @param oldPos Vector
local function drawProjectedPlayer(radar, ply, invScale, oldPos, markerColor,
    modelColor, phase)
    local oldAng = ply:GetAngles()
    local oldScale = ply:GetModelScale()

    local wep = ply:GetActiveWeapon()
    local oldWepScale
    if IsValid(wep) then
        oldWepScale = wep:GetModelScale()
    end

    local wpos, wang = radar:Project(oldPos, oldAng)
    ply:SetPos(wpos)
    ply:SetAngles(wang)
    ply:SetModelScale(oldScale * invScale, 0)
    if IsValid(wep) then
        wep:SetModelScale(oldWepScale * invScale, 0)
    end

    local ok, err = pcall(drawPlayerAndWeapon, ply, radar, modelColor, phase)
    if ok then
        HoloEffects.DrawContactMarker(radar.entityTable, wpos, markerColor,
            math.Clamp(28 * invScale, 0.8, 2.5),
            math.Clamp(80 * invScale, 2.5, 7), phase)
    end

    if IsValid(wep) and oldWepScale then
        wep:SetModelScale(oldWepScale, 0)
    end
    ply:SetModelScale(oldScale, 0)
    ply:SetAngles(oldAng)
    ply:SetPos(oldPos)
    ply:SetupBones()

    if not ok then
        ErrorNoHaltWithStack('[holo_table] player radar draw aborted: ' .. tostring(err))
    end
end

local PLAYER_VIS_RADIUS = 96

local function playerMarkerColor(radar, ply, localPly)
    if ply == localPly then
        return HoloEffects.GetHologramColor(PLAYER_MARKER_LOCAL, 240)
    end
    local tableTeam = radar:GetEntity():GetTeam()
    local playerTeam = ply:Team()
    if tableTeam == 0 or playerTeam == 0 then
        return HoloEffects.GetHologramColor(PLAYER_MARKER_NEUTRAL, 240)
    end
    return tableTeam == playerTeam and PLAYER_MARKER_FRIENDLY or PLAYER_MARKER_HOSTILE
end

local function playerModelColor(radar, ply, localPly)
    -- Local identification stays in the label, not the hologram tint.
    if ply == localPly then
        return HoloEffects.GetHologramFillColor(PLAYER_MODEL_NEUTRAL, 240)
    end
    local tableTeam = radar:GetEntity():GetTeam()
    local playerTeam = ply:Team()
    if tableTeam == 0 or playerTeam == 0 then
        return HoloEffects.GetHologramFillColor(PLAYER_MODEL_NEUTRAL, 240)
    end
    return tableTeam == playerTeam and PLAYER_MARKER_FRIENDLY
        or PLAYER_MARKER_HOSTILE
end

local function playerContactStatus(radar, ply, localPly)
    if ply == localPly then return 'LOCAL' end
    local tableTeam = radar:GetEntity():GetTeam()
    local playerTeam = ply:Team()
    if tableTeam == 0 or playerTeam == 0 then return 'NEUTRAL' end
    return tableTeam == playerTeam and 'FRIENDLY' or 'HOSTILE'
end

local function drawPlayerMarkers(radar)
    local localPly = LocalPlayer()
    render.SetColorMaterial()
    for _, ply in player.Iterator() do
        if not (IsValid(ply) and ply:Alive()) then continue end
        local pos = ply:GetPos()
        if not radar:IsVisible(pos, PLAYER_VIS_RADIUS) then continue end
        render.DrawSphere(radar:Project(pos), PLAYER_MARKER_RADIUS, 8, 8,
            playerMarkerColor(radar, ply, localPly))
    end
end

local function drawPlayers(radar, invScale)
    local localPly = LocalPlayer()
    local now = CurTime()
    radar.Seen = radar.Seen or {}
    for _, ply in player.Iterator() do
        if not IsValid(ply) then continue end
        if not ply:Alive() then continue end
        local pos = ply:GetPos()
        if not radar:IsVisible(pos, PLAYER_VIS_RADIUS) then continue end

        local color = playerMarkerColor(radar, ply, localPly)
        local modelColor = playerModelColor(radar, ply, localPly)
        local phase = ply:EntIndex() * 0.73

        if ply == localPly then
            drawProjectedLocalPlayer(radar, ply, invScale, pos, color,
                modelColor, phase)
        else
            drawProjectedPlayer(radar, ply, invScale, pos, color,
                modelColor, phase)
        end

        local seen = radar.Seen[ply:EntIndex()]
        if not seen or seen.ent ~= ply then
            seen = { ent = ply, time = now }
            radar.Seen[ply:EntIndex()] = seen
        end
        local markerRadius = math.Clamp(28 * invScale, 0.8, 2.5)
        local markerHeight = math.Clamp(80 * invScale, 2.5, 7)
        local wpos = radar:Project(pos)
        HoloEffects.DrawContactPing(radar.entityTable, wpos, color,
            now - seen.time, markerRadius)
        HoloEffects.DrawContactLabel(radar.entityTable, wpos, color,
            markerHeight + 0.8, ply:Nick(), playerContactStatus(radar, ply, localPly))
    end
end

function RADAR:Initialize()
    self.Seen = {}
end

function RADAR:Draw()
    if self:GetLOD() == 1 then
        drawPlayerMarkers(self)
        return
    end

    local invScale = self:GetScale()
    beginPlayerLighting()

    local ok, err = pcall(drawPlayers, self, invScale)

    endPlayerLighting()

    if ok then
        self.DrawWarned = nil
    elseif not self.DrawWarned then
        self.DrawWarned = true
        ErrorNoHaltWithStack('[holo_table] player radar lighting draw aborted: ' .. tostring(err))
    end
end

function RADAR:OnRemove()
    removeMirror(self.LocalPlayerMirror)
    self.LocalPlayerMirror = nil
    removeMirror(self.LocalWeaponMirror)
    self.LocalWeaponMirror = nil
    self.Seen = nil
end
