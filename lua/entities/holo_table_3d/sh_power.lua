-- Authoritative per-table power state and spatial audio. Visual sequencing is
-- client-side, but every nearby player hears the same switch and hum state.

if not SERVER then return end

local soundEnabled = CreateConVar('holo_table_sound', '1',
    bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED),
    'Enable holo-table startup, shutdown, and ambient sounds.', 0, 1)
local soundVolume = CreateConVar('holo_table_sound_volume', '0.35',
    bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED),
    'Master volume for holo-table sounds.', 0, 1)

local START_SOUND = 'buttons/combine_button1.wav'
local STOP_SOUND = 'ambient/energy/power_off1.wav'
local HUM_SOUND = 'ambient/machines/combine_terminal_loop1.wav'
local SOUND_LEVEL = 64
local HUM_VOLUME_MULTIPLIER = 0.42

local function masterVolume()
    return math.Clamp(soundVolume:GetFloat(), 0, 1)
end

function ENT:StartPowerHum(fadeTime)
    if not soundEnabled:GetBool() or not self:IsTablePowered() then return end

    if not self._holoPowerHum then
        self._holoPowerHum = CreateSound(self, HUM_SOUND)
    end
    local hum = self._holoPowerHum
    if not hum then return end

    local volume = masterVolume() * HUM_VOLUME_MULTIPLIER
    hum:PlayEx(fadeTime and 0 or volume, 92)
    if fadeTime then hum:ChangeVolume(volume, fadeTime) end
end

function ENT:StopPowerHum(fadeTime)
    local hum = self._holoPowerHum
    if not hum then return end
    if fadeTime and fadeTime > 0 then
        hum:FadeOut(fadeTime)
    else
        hum:Stop()
    end
    self._holoPowerHum = nil
end

function ENT:ApplyPowerAudio(powered, silent)
    if powered then
        if not silent and soundEnabled:GetBool() then
            self:EmitSound(START_SOUND, SOUND_LEVEL, 96, masterVolume(), CHAN_STATIC)
        end
        self:StartPowerHum(silent and nil or 0.7)
        return
    end

    self:StopPowerHum(0.35)
    if not silent and soundEnabled:GetBool() then
        self:EmitSound(STOP_SOUND, SOUND_LEVEL, 102, masterVolume() * 0.8, CHAN_STATIC)
    end
end

function ENT:ObservePowerChange(powered, silent)
    if self._holoLastPowered == powered then return end
    self._holoLastPowered = powered
    self:ApplyPowerAudio(powered, silent)
end

function ENT:InitializePower()
    self._holoPowerReady = true
    self._holoLastPowered = self:IsTablePowered()
end

--- The only server-side power setter used by controls and spawn setup.
--- Direct property-editor writes still pass through NetworkVarNotify.
function ENT:SetTablePowered(powered, silent)
    if not self.SetPowered then return false end
    powered = tobool(powered)
    if powered == self:IsTablePowered() then
        if powered and not self._holoPowerHum then self:StartPowerHum() end
        return
    end

    self:SetPowered(powered)
    self:ObservePowerChange(powered, silent)
    return true
end

-- NetworkVarNotify is not guaranteed for every external property-editor path
-- on all GMod branches. This low-frequency observer keeps audio synchronized
-- even when another addon writes the generated SetPowered accessor directly.
function ENT:Think()
    if self.GetPowered then
        self:ObservePowerChange(self:GetPowered(), false)
    end
    self:NextThink(CurTime() + 0.1)
    return true
end

function ENT:CleanupPower()
    self._holoPowerReady = false
    self:StopPowerHum()
end

local callbackId = 'holo_table_3d.PowerAudio'
cvars.RemoveChangeCallback('holo_table_sound', callbackId)
cvars.AddChangeCallback('holo_table_sound', function(_, _, value)
    local enabled = tobool(value)
    for _, ent in ipairs(ents.FindByClass('holo_table_3d')) do
        if enabled and ent:IsTablePowered() then
            ent:StartPowerHum(0.25)
        else
            ent:StopPowerHum(0.15)
        end
    end
end, callbackId)

cvars.RemoveChangeCallback('holo_table_sound_volume', callbackId)
cvars.AddChangeCallback('holo_table_sound_volume', function()
    local volume = masterVolume() * HUM_VOLUME_MULTIPLIER
    for _, ent in ipairs(ents.FindByClass('holo_table_3d')) do
        if ent._holoPowerHum then ent._holoPowerHum:ChangeVolume(volume, 0.15) end
    end
end, callbackId)
