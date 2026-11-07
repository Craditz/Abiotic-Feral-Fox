-- Resolve exact paths through the engine and cache serial-checked weak pointers.
-- The class-filtered search is only for bootstrapping the native library.
local libraryName = 'Default__KismetSystemLibrary'
local libraryPath = '/Script/Engine.' .. libraryName
local destroyed = 0x00008000 | 0x00010000
local classDefaultObject = 0x00000010
local libraryReference
local cache, cacheKeys = {}, {}
local cacheLimit, nextSlot = 2048, 1

local function matches(object, objectPath)
    return object and object:IsValid() and object:GetFullName():gsub('^%S+ ', '') == objectPath
end

local function getLibrary()
    local library = libraryReference and libraryReference:Get()
    if library and library:IsValid() then return library end
    for _, object in ipairs(FindObjects(1, 'KismetSystemLibrary', libraryName, classDefaultObject, destroyed, true) or {}) do
        if matches(object, libraryPath) then
            libraryReference = object:Conv_ObjectToSoftObjectReference(object):GetWeakPtr()
            return object
        end
    end
end

return function(objectPath)
    if type(objectPath) ~= 'string' then return nil end
    if objectPath == libraryPath then return getLibrary() end

    local reference = cache[objectPath]
    if reference then
        local object = reference:Get()
        if matches(object, objectPath) then return object end
    end

    local library = getLibrary()
    if not library then return nil end
    local softPath = library:MakeSoftObjectPath(objectPath)
    local softReference = library:Conv_SoftObjPathToSoftObjRef(softPath)
    local object = library:Conv_SoftObjectReferenceToObject(softReference)
    if not matches(object, objectPath) then return nil end

    if not reference then
        local evicted = cacheKeys[nextSlot]
        if evicted then cache[evicted] = nil end
        cacheKeys[nextSlot] = objectPath
        nextSlot = nextSlot % cacheLimit + 1
    end
    cache[objectPath] = library:Conv_ObjectToSoftObjectReference(object):GetWeakPtr()
    return object
end
