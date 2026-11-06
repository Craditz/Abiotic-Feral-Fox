-- Read only: no world save modification or actor-name/level-name fallback.
local M={}
local networkResolver
function M.setNetworkResolver(fn)networkResolver=fn end
local function valid(o)local ok,v=pcall(function()return o:IsValid()end);return ok and v==true end
local function stringValue(v)
    if type(v)~='string' then local ok,s=pcall(function()return v:ToString()end);if not ok then return end;v=s end
    if v~='' and #v<=512 and not v:find('[%z\r\n]') then return v end
end
function M.world()
    for _,gi in ipairs(FindAllOf('Abiotic_GameInstance_C') or {}) do
        if valid(gi) then local ok,v=pcall(function()return stringValue(gi.ActiveWorldSaveName)end);if ok and v then return v end end
    end
end
function M.resolve(controller,pawn)
    if not valid(controller) or not controller:IsLocalPlayerController() or not valid(pawn) or not valid(controller.PlayerState) then return end
    local library=StaticFindObject('/Script/Engine.Default__KismetSystemLibrary')
    if not valid(library)then return end
    if not library:IsStandalone(pawn)then
        if networkResolver then return networkResolver(controller,pawn)end
        return
    end
    local world=M.world();if not world then return end
    local player=controller.PlayerState
    local id=stringValue(player.PlayerSaveID);local account=stringValue(player.UniquePlayerID)
    if not id or not account then return end
    local level=pawn:GetWorld():GetFullName();local matched=false
    for _,gs in ipairs(FindAllOf('Abiotic_Survival_GameState_C') or {}) do
        if valid(gs) and gs:GetWorld():GetFullName()==level and stringValue(gs.WorldSaveName)==world then matched=true;break end
    end
    if not matched then return end
    local key='local-v1:'..#account..':'..account..':'..#world..':'..world..':'..#id..':'..id
    return key,world..' / '..account:sub(-6),world
end
return M
