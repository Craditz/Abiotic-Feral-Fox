-- Search by leaf name and match the full path only on those candidates.
-- A full-path StaticFindObject miss can walk unrelated Outer chains in UE4SS 1176.
local destroyed = 0x00008000 | 0x00010000 -- RF_BeginDestroyed | RF_FinishDestroyed

return function(objectPath)
    if type(objectPath) ~= 'string' then return nil end
    local name = objectPath:match('([^/.:]+)$')
    if not name then return nil end

    for _, object in ipairs(FindObjects(0, nil, name, 0, destroyed) or {}) do
        if object:IsValid() and object:GetFullName():gsub('^%S+ ', '') == objectPath then
            return object
        end
    end
end
