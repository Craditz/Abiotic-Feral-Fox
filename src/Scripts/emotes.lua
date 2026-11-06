-- Native emote lifecycle owns start/stop and gameplay. Only choose fox cosmetics.
local M={}
local function valid(o)local ok,v=pcall(function()return o:IsValid()end);return ok and v==true end
local function optional(fn)local ok,v=pcall(fn);if ok then return v end end
function M.active(pawn)
    return pawn.EmoteShouldHideFP==true or optional(function()return pawn:IsPerformingEmote()end)==true
end
function M.row(pawn)
    return optional(function()return pawn.CurrentPerformingEmote.RowName:ToString()end) or ''
end
function M.classify(row,montage,seated)
    local name=(row or ''):lower();local asset=(montage or ''):lower()
    -- A cached previous montage must never override a newer native row.
    if name=='greet' then return seated and 'emote_wave_seated' or 'emote_wave' end
    if name=='cheer' then return seated and 'emote_cheer_seated' or 'emote_cheer' end
    if name=='dance_gate' then return 'emote_dance' end
    if name=='sit' or name=='sit_mage' then return 'sit' end
    if name~='' and name~='none' then return end
    if asset:find('_wave_',1,true) then return seated and 'emote_wave_seated' or 'emote_wave' end
    if asset:find('_cheer_',1,true) then return seated and 'emote_cheer_seated' or 'emote_cheer' end
    if asset:find('_dance_gate_',1,true) then return 'emote_dance' end
    if asset:find('_sit_floor_',1,true) then return 'sit' end
end
function M.select(pawn,mode,now,memory,serial)
    local active=M.active(pawn)
    local row=active and M.row(pawn) or ''
    local montage=active and optional(function()return pawn.LastKnownLoadedEmote end)
    local asset=valid(montage) and montage:GetFullName() or ''
    local seated=mode=='seat'
    local key=active and M.classify(row,asset,seated)
    if not key then return seated and 'sit' or 'idle',1 end
    local identity=((row~='' and row~='None') and row or asset)..'|'..tostring(serial or 0)
    if memory.identity~=identity or not memory.start or now<memory.start then
        memory.identity,memory.start=identity,now
    end
    local rate=1
    local finite=key:find('emote_',1,true) and key~='emote_dance'
    if finite then
        local duration=optional(function()return montage:GetPlayLength()end)
        if type(duration)=='number' and duration>.1 then rate=math.max(.35,math.min(2.5,3/duration)) end
        if (now-memory.start)*rate>=3 then return seated and 'sit' or 'idle',1 end
    end
    return key,rate,identity
end
return M
