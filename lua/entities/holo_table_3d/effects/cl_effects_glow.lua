-- Contact-only bloom reuses visible hull pixels; no second model submission.

local Effects = ENT.HoloEffects
local cvars = Effects.cvars
local BLOOM_BIT = 128
local TABLE_MASK = 127
local copyMaterial = Material('pp/copy')
local addMaterial = CreateMaterial('holo_table_contact_bloom_add', 'UnlitGeneric', {
    ['$basetexture'] = 'models/debug/debugwhite',
    ['$additive'] = '1',
    ['$ignorez'] = '1',
})
local bloomColor = Vector(1, 1, 1)
local pendingFrame
local warned

--- @return boolean enabled
function Effects.AreContactBloomEnabled()
    return Effects.AreContactModelsEnabled() and cvars.contactBloom:GetBool()
        and cvars.contactBloomStrength:GetFloat() > 0
end

--- Marks only shader-visible hull fragments, retaining the table's low bits.
--- @param selfTbl table Cached table render state.
--- @return boolean marked
function Effects.BeginContactBloom(selfTbl)
    local reference = selfTbl._holoStencilReference
    if not Effects.AreContactBloomEnabled() or not reference
        or reference > TABLE_MASK or render.GetRenderTarget() then return false end

    render.SetStencilTestMask(TABLE_MASK)
    render.SetStencilWriteMask(BLOOM_BIT)
    render.SetStencilReferenceValue(reference + BLOOM_BIT)
    render.SetStencilCompareFunction(STENCIL_EQUAL)
    render.SetStencilPassOperation(STENCIL_REPLACE)
    render.SetStencilFailOperation(STENCIL_KEEP)
    render.SetStencilZFailOperation(STENCIL_KEEP)
    pendingFrame = FrameNumber()
    return true
end

--- Restores the read-only cylinder stencil after a contact draw.
--- @param selfTbl table Cached table render state.
function Effects.EndContactBloom(selfTbl)
    render.SetStencilWriteMask(0)
    render.SetStencilTestMask(TABLE_MASK)
    render.SetStencilReferenceValue(selfTbl._holoStencilReference)
    render.SetStencilPassOperation(STENCIL_KEEP)
end

local function extractAndBlur(blurTexture)
    render.Clear(0, 0, 0, 255, false, false)
    render.SetStencilEnable(true)
    render.SetStencilWriteMask(0)
    render.SetStencilTestMask(BLOOM_BIT)
    render.SetStencilReferenceValue(BLOOM_BIT)
    render.SetStencilCompareFunction(STENCIL_EQUAL)
    render.SetStencilPassOperation(STENCIL_KEEP)
    render.SetMaterial(copyMaterial)
    render.DrawScreenQuad()
    render.SetStencilEnable(false)
    render.CopyRenderTargetToTexture(blurTexture)
    local blur = cvars.contactBloomBlur:GetFloat()
    render.BlurRenderTarget(blurTexture, blur, blur, 1)
end

--- Extracts and blurs all contacts in the current stencil batch once.
--- @return boolean drawn
function Effects.DrawContactBloom()
    if pendingFrame ~= FrameNumber() then return false end
    pendingFrame = nil
    if not Effects.AreContactBloomEnabled() then return false end

    local sceneTarget = render.GetRenderTarget()
    local sceneTexture = render.GetScreenEffectTexture(0)
    local blurTexture = render.GetScreenEffectTexture(1)
    render.CopyRenderTargetToTexture(sceneTexture)
    copyMaterial:SetTexture('$basetexture', sceneTexture)
    copyMaterial:SetString('$color', '1 1 1')
    copyMaterial:SetFloat('$alpha', 1)
    local ok, err = pcall(extractAndBlur, blurTexture)

    -- Always restore the original image, even if extraction/blur fails.
    render.SetRenderTarget(sceneTarget)
    render.SetStencilEnable(false)
    render.SetMaterial(copyMaterial)
    render.DrawScreenQuad()
    if ok then
        local strength = cvars.contactBloomStrength:GetFloat()
        bloomColor:SetUnpacked(strength, strength, strength)
        addMaterial:SetVector('$color', bloomColor)
        addMaterial:SetTexture('$basetexture', blurTexture)
        -- Spread light outside the hull; do not bleach its already-lit fill.
        render.SetStencilEnable(true)
        render.SetStencilTestMask(BLOOM_BIT)
        render.SetStencilReferenceValue(BLOOM_BIT)
        render.SetStencilCompareFunction(STENCIL_NOTEQUAL)
        render.SetMaterial(addMaterial)
        render.DrawScreenQuad()
        render.SetStencilEnable(false)
    elseif not warned then
        warned = true
        ErrorNoHaltWithStack('[holo_table] contact bloom skipped: ' .. tostring(err))
    end
    render.SetStencilWriteMask(255)
    render.SetStencilTestMask(255)
    return ok
end
