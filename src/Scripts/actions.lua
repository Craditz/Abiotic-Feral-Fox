local findObject = require('object_lookup')
-- Local cosmetic observers. No gameplay calls, input synthesis or replicated state.
local M={}
local active,hooked=nil,{}
local durations={hit=.7,bite=.8333333,pickup=1.05,door=.85}
local priority={hit=100,heal=90,bite=80,eat=70,drink=70,door=60,pickup=50,craft=40}
function M.rank(key) return priority[key] or 0 end
local doorFields={}
local function valid(o)
    if o==nil then return false end
    local ok,v=pcall(function()return o:IsValid()end);return ok and v==true
end
local function path(o) return o:GetFullName():gsub('^%S+ ','') end
local function optional(fn) local ok,v=pcall(fn);if ok then return v end end

function M.emit(s,key,now)
    if key=='craft' then
        -- Receipt is not progress. Suppress the accompanying item-pickup pose,
        -- but let the native crafting panel own the work loop's lifetime.
        s.last.craft=now;s.pulses.pickup=nil
        return
    end
    if not durations[key] then return end
    -- Multiple native receipt callbacks and health/RPC notifications can describe
    -- the same action. Genuine repeated swings/pickups still get a fresh serial.
    local gap=key=='hit' and .25 or .12
    if s.last[key] and now>=s.last[key] and now-s.last[key]<gap then return end
    s.last[key]=now;s.serial=s.serial+1
    s.pulses[key]={untilTime=now+durations[key],serial=s.serial}
    if key=='pickup' and s.last.craft and now-s.last.craft<.2 then s.pulses.pickup=nil end
    s.log('Action event: '..key)
end

local function crafting(s,pawn,now)
    local function owns(widget)
        return valid(widget) and optional(function()
            return valid(widget.CraftingPlayerCharacter) and path(widget.CraftingPlayerCharacter)==s.pawn and
                valid(widget:GetOwningPlayerPawn()) and path(widget:GetOwningPlayerPawn())==s.pawn and
                type(widget.IsCrafting)=='boolean'
        end)==true
    end
    -- Keep no widget handles or full-name lookup in the per-frame path. The
    -- narrow class query also excludes expired panels after world/owner changes.
    local widget
    for _,candidate in ipairs(optional(function()return FindAllOf('W_Inventory_CraftingArea_C')end) or {}) do
        if owns(candidate) then widget=candidate;break end
    end
    local working=widget~=nil and widget.IsCrafting==true
    if working~=s.crafting then
        if working then
            s.serial=s.serial+1;s.craftSerial=s.serial
            s.log('Crafting progress: started.')
        elseif s.crafting then s.log('Crafting progress: stopped.') end
        s.crafting=working
    end
    return working
end

local function doorState(target)
    if not valid(target) then return end
    local class=target:GetClass()
    if not path(class):match('^/Game/Blueprints/Doors/') then return end
    local classPath=path(class)
    local names=doorFields[classPath]
    local fields={}
    -- Door subclasses expose different enums. Discover readable state fields;
    -- a missing capability simply leaves that door without a cosmetic push.
    if not names then
    names={}
    for _=1,3 do
        if not valid(class) then break end
        class:ForEachProperty(function(prop)
            local key=prop:GetFName():ToString();local lower=key:lower()
            if lower:find('state',1,true) or lower=='isdooropen' then
                local v=optional(function()return target[key]end)
                if type(v)=='number' or type(v)=='boolean' then names[#names+1]=key end
            end
        end)
        class=class:GetSuperStruct()
    end
    doorFields[classPath]=names
    end
    for _,key in ipairs(names) do
        local v=optional(function()return target[key]end)
        if type(v)=='number' or type(v)=='boolean' then fields[#fields+1]=key..'='..tostring(v) end
    end
    if #fields==0 then return end
    table.sort(fields);return table.concat(fields,';')
end

function M.beginDoor(s,id,signature,now)
    local previous=s.doors[id]
    if not previous or now-previous.time>.25 or not signature then return end
    s.pendingDoor={id=id,before=previous.signature,untilTime=now+.7}
    if signature~=previous.signature then M.emit(s,'door',now);s.pendingDoor=nil end
end

local function prepareHooks(log)
    if type(RegisterHook)~='function' then return end
    local prefix='/Game/Blueprints/Characters/Abiotic_PlayerCharacter.Abiotic_PlayerCharacter_C:'
    for _,entry in ipairs({{'Client_TakeDamage','hit'},{'Local_DoMeleeAttack_Event','bite'},
        {'Client_DisplayNewItemPickup','pickup'},{'Client_ItemCrafted','craft'},
        {'Local_Try_StartInteraction','interaction'},{'Local_BeginPlayEmote','emote'}}) do
        local name,key=entry[1],entry[2]
        if not hooked[name] and valid(findObject(prefix..name)) then
            local ok,err=pcall(RegisterHook,prefix..name,function(context,...)
                local s=active
                if not s or (s.blocked and key~='emote') then return end
                local args={...}
                local success,why=pcall(function()
                    local pawn=context:get()
                    if not valid(pawn) or path(pawn)~=s.pawn then return end
                    local now=pawn:GetGameTimeSinceCreation()
                    if key=='emote' then
                        s.emoteSerial=(s.emoteSerial or 0)+1
                    elseif key=='interaction' then
                        local isA=args[1]:get()==true
                        local target=pawn[isA and 'BestInteractable_InteractA' or 'BestInteractable_InteractB']
                        local signature=doorState(target)
                        if signature then M.beginDoor(s,path(target),signature,now) end
                    else M.emit(s,key,now) end
                end)
                if not success and not s.warned[name] then s.warned[name]=true;s.log('Optional action observer '..name..': '..tostring(why)) end
            end)
            hooked[name]=ok
            if ok then log('Action observer ready: '..name)
            else log('Optional action observer unavailable: '..name..'; '..tostring(err)) end
        end
    end
end

function M.attach(pawn,log)
    local s={pawn=path(pawn),log=log,last={},pulses={},serial=0,doors={},warned={}}
    active=s;prepareHooks(log);return s
end
function M.detach(s) if active==s then active=nil end end

function M.update(s,pawn,mode,montage,token,speed)
    if not s then return end
    local now=pawn:GetGameTimeSinceCreation()
    local health=optional(function()return pawn.TotalCombinedHealth end)
    if mode or (s.time and now<s.time) then
        if s.crafting then s.log('Crafting progress: interrupted by '..tostring(mode or 'actor clock reset')..'.') end
        s.pulses={};s.last={};s.pendingDoor=nil;s.doors={};s.montageToken=nil
        s.crafting=false;s.craftSerial=nil
        s.health=health;s.time=now;s.blocked=mode~=nil;return
    end
    s.blocked=false;s.time=now
    local working=crafting(s,pawn,now)
    if type(health)=='number' then
        if type(s.health)=='number' and health<s.health-.01 then M.emit(s,'hit',now) end
        s.health=health
    end
    -- Only explicit medical use montages select heal; passive regeneration does not.
    if montage=='bite' and token~=s.montageToken then
        if not s.last.bite or now-s.last.bite>.25 then M.emit(s,'bite',now) end
    end
    s.montageToken=token
    if s.pendingDoor then
        local pending=s.pendingDoor
        local target=findObject(pending.id)
        local signature=optional(function()return doorState(target)end)
        if now>pending.untilTime or not signature then s.pendingDoor=nil
        elseif signature~=pending.before then M.emit(s,'door',now);s.pendingDoor=nil end
    end
    -- Cache only the currently highlighted target, never UObject handles.
    local doors={}
    for _,key in ipairs({'BestInteractable_InteractA','BestInteractable_InteractB'}) do
        optional(function()
            local target=pawn[key]
            if valid(target) then
                local signature=doorState(target)
                if signature then doors[path(target)]={signature=signature,time=now} end
            end
        end)
    end
    s.doors=doors
    if speed>=15 then s.pulses={};return end
    local action,serial
    if working then action,serial='craft',s.craftSerial end
    if montage=='heal' or montage=='eat' or montage=='drink' then action=montage end
    for key,pulse in pairs(s.pulses) do
        if now>=pulse.untilTime then s.pulses[key]=nil
        elseif not action or priority[key]>priority[action] then action,serial=key,pulse.serial end
    end
    return action,serial
end
return M
