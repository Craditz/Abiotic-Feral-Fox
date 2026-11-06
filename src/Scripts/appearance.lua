-- Independent atlas regions, using stable IDs from the supplied source files.
local Catalog=require('appearance_catalog')
local M={catalog=Catalog,mesh='/Game/FeralFox/SK_FeralFoxCustom.SK_FeralFoxCustom'}
local function allowed(rows,id)
    for _,row in ipairs(rows) do if row.id==id then return true end end
    return false
end
function M.normalize(value)
    value=value or {}
    return {coat=allowed(Catalog.coats,value.coat) and value.coat or 0,
        eyes=allowed(Catalog.eyes,value.eyes) and value.eyes or 0,
        paws=allowed(Catalog.paws,value.paws) and value.paws or 0}
end
local function material(name,load)
    return load('/Game/FeralFox/'..name..'.'..name)
end
function M.apply(component,value,load)
    local look=M.normalize(value)
    local coat='MI_Fox_coat_'..string.format('%02d',look.coat)
    local names={coat,'MI_Fox_Coat','MI_Fox_Teeth','MI_Fox_Crease',coat,
        look.eyes==0 and 'MI_Fox_Coat' or 'MI_Fox_eye_'..string.format('%02d',look.eyes),
        look.paws==0 and coat or 'MI_Fox_sock_'..string.format('%02d_%02d',look.coat,look.paws),
        'MI_Fox_lip_'..string.format('%02d',look.coat),coat}
    -- Resolve the whole selection before changing any visible material.
    local materials={}
    for index,name in ipairs(names) do
        local asset=material(name,load)
        assert(asset and asset:IsValid(),'Appearance material missing: '..name)
        materials[index]=asset
    end
    for index,asset in ipairs(materials) do component:SetMaterial(index-1,asset) end
end
return M
