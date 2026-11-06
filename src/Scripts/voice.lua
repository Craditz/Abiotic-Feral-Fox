-- Local cosmetic RiME voice. Never changes health, inventory, replication or game audio settings.
local M={}
local Catalog=require('voice_catalog')
local pools={idle={},hurt={},combat={}}
for _,clip in ipairs(Catalog) do
    if clip.category=='idle' then pools.idle[#pools.idle+1]=clip end
    if clip.name=='fox_whine_b' or clip.name:match('^fox_bark_near_00[123]$') then pools.hurt[#pools.hurt+1]=clip end
    if clip.name:match('^fox_bark_single_00[123]$') then pools.combat[#pools.combat+1]=clip end
end
local function valid(o)
    if o==nil then return false end
    local ok,v=pcall(function()return o:IsValid()end);return ok and v==true
end
local function resolve(p) return p and StaticFindObject(p) or nil end
local function path(o) return o:GetFullName():gsub('^%S+ ','') end
local muted={}
local hooksReady=false
local function muteNative(s,pawn)
    local native=pawn.CharacterVoiceAudio
    if valid(native) then
        local id=path(native)
        if s.native and s.native~=id then
            muted[s.native]=nil
            local previous=resolve(s.native)
            if valid(previous) then previous:SetVolumeMultiplier(s.nativeVolume or 1) end
            s.native=nil
        end
        if not s.native then
            s.native=id;s.nativeVolume=native.VolumeMultiplier
            native:Stop()
            s.log('Scientist voice muted on local fox component only: '..id)
        end
        muted[id]=true
        if native.VolumeMultiplier~=0 then native:SetVolumeMultiplier(0) end
        -- The native cue may be assigned after spawning. Inherit its class when available.
        if not s.soundClass then
            local sound=native.Sound
            local soundClass=native.SoundClassOverride
            if not valid(soundClass) and valid(sound) then soundClass=sound.SoundClassObject end
            if valid(soundClass) then s.soundClass=path(soundClass);s.log('Fox voice sound class: '..s.soundClass) end
        end
    end
end
local function prepareHooks(log)
    if hooksReady then return end
    hooksReady=true
    for _,name in ipairs({'Play','FadeIn','AdjustVolume','SetVolumeMultiplier'}) do
        local ok,err=pcall(RegisterHook,'/Script/Engine.AudioComponent:'..name,function(context,...)
            local c=context:get()
            if not valid(c) or not muted[path(c)] then return end
            if name=='SetVolumeMultiplier' then
                local value=...;value:set(0)
            else c:SetVolumeMultiplier(0) end
        end)
        if not ok then log('Voice mute hook unavailable ('..name..'): '..tostring(err)) end
    end
end
local function number(c,key,default,low,high)
    local v=c[key];if type(v)~='number' or v~=v then v=default end
    return math.max(low,math.min(high,v))
end
local function settings(c)
    local low=number(c,'fox_voice_idle_min_seconds',90,30,3600)
    return {volume=number(c,'fox_voice_volume',2.0,0,2),idleMin=low,
        idleMax=math.max(low,number(c,'fox_voice_idle_max_seconds',180,30,7200)),
        hurtCooldown=number(c,'fox_voice_hurt_cooldown_seconds',3,1,60),
        combatCooldown=number(c,'fox_voice_combat_cooldown_seconds',12,4,120),
        combatChance=number(c,'fox_voice_combat_chance',0.15,0,1)}
end
local function nextIdle(s,now) s.nextIdle=now+s.options.idleMin+math.random()*(s.options.idleMax-s.options.idleMin) end
local function stop(s)
    local component=resolve(s.component)
    if valid(component) then
        pcall(function()component:Stop()end)
        pcall(function()component:K2_DestroyComponent(nil)end)
    end
    s.component=nil;s.busyUntil=nil
end
function M.cleanup(s)
    if not s then return end
    stop(s)
    if s.native then
        muted[s.native]=nil
        local native=resolve(s.native)
        if valid(native) then
            local ok=pcall(function()native:SetVolumeMultiplier(s.nativeVolume or 1)end)
            if ok then s.log('Scientist voice restored on former fox component; volume '..tostring(native.VolumeMultiplier)..'.') end
        end
        s.native=nil
    end
end

-- Metadata is diagnostic only, bounded to the local pawn's class hierarchy.
function M.describe(pawn,log)
    local class=pawn:GetClass()
    for _=1,5 do
        if not valid(class) then break end
        class:ForEachProperty(function(p)
            local key=p:GetFName():ToString()
            if key:lower():find('voice',1,true) or key:lower():find('audio',1,true) then
                local ok,v=pcall(function()return pawn[key]end)
                if ok then log('Voice metadata '..key..' = '..(valid(v) and v:GetFullName() or tostring(v))) end
            end
        end)
        class:ForEachFunction(function(fn)
            if fn:GetFName():ToString():lower():find('voice',1,true) then
                log('Voice function '..fn:GetFullName())
                fn:ForEachProperty(function(p)log('Voice param '..p:GetFullName())end)
            end
        end)
        class=class:GetSuperStruct()
    end
end

function M.init(pawn,config,load,log)
    if config.fox_voice==false then return nil end
    local library=resolve('/Script/Engine.Default__GameplayStatics')
    assert(valid(library),'Audio gameplay library unavailable')
    for _,fn in ipairs({'GameplayStatics:CreateSound2D','AudioComponent:Play','AudioComponent:Stop','AudioComponent:SetUISound'}) do
        assert(valid(resolve('/Script/Engine.'..fn)),'Voice API unavailable: '..fn)
    end
    -- Resolve the small pool once. Store paths rather than UObject handles across ticks.
    local available=pcall(function()
    for _,pool in pairs(pools) do for _,clip in ipairs(pool) do
        local asset=load(clip.path)
        assert(asset:IsA('/Script/Engine.SoundWave'),'Not a SoundWave: '..clip.name)
    end end
    end)
    if not available then log('Optional local voice assets unavailable; native scientist voice retained.');return nil end
    local now=pawn:GetGameTimeSinceCreation()
    local s={options=settings(config),load=load,log=log,lastHealth=pawn.TotalCombinedHealth,
        lastTime=now,nextPoll=now,lastHurt=-1000,lastCombat=-1000,lastPick={},library=path(library)}
    s.replaceScientist=config.fox_voice_replace_scientist~=false
    if s.replaceScientist then prepareHooks(log);muteNative(s,pawn) end
    nextIdle(s,now)
    log('RiME voice ready: quiet local reactions; idle '..s.options.idleMin..'-'..s.options.idleMax..'s; automatic howl OFF.')
    if config.voice_trace==true then pcall(M.describe,pawn,log) end
    return s
end

function M.play(s,pawn,kind,now,preview)
    if not s or s.failed or s.options.volume==0 then return false end
    local pool=pools[kind];if not pool or #pool==0 then return false end
    if not preview then
        if kind=='hurt' and now-s.lastHurt<s.options.hurtCooldown then return false end
        if kind=='combat' and now-s.lastCombat<s.options.combatCooldown then return false end
        if kind~='hurt' and s.busyUntil and now<s.busyUntil then return false end
    end
    stop(s)
    local pick=math.random(#pool)
    if #pool>1 and pick==s.lastPick[kind] then pick=pick%#pool+1 end
    local clip=pool[pick]
    local gain=s.options.volume*clip.gain*(kind=='idle' and 0.35 or (kind=='combat' and 0.55 or 0.85))
    local asset=s.load(clip.path)
    if s.soundClass and valid(resolve(s.soundClass)) then asset.SoundClassObject=resolve(s.soundClass) end
    local component=resolve(s.library):CreateSound2D(pawn,asset,gain,1,0,nil,false,true)
    assert(valid(component),'Could not create fox voice audio component')
    component:SetUISound(false)
    s.component=path(component)
    component:Play(0)
    s.busyUntil=now+clip.duration+0.15;s.lastPick[kind]=pick
    if kind=='hurt' then s.lastHurt=now end
    if kind=='combat' then s.lastCombat=now end
    nextIdle(s,now)
    s.log('Voice '..(preview and 'AUDITION ' or '')..kind..': '..clip.name..'; gain '..string.format('%.3f',gain)..'.')
    return true
end

function M.update(s,pawn,mode,action,speed)
    if not s or s.failed then return end
    local ok,err=pcall(function()
        local now=pawn:GetGameTimeSinceCreation()
        if now<s.lastTime then
            stop(s);s.lastHealth=pawn.TotalCombinedHealth;s.lastHurt=-1000;s.lastCombat=-1000;s.nextPoll=now;nextIdle(s,now)
        end
        s.lastTime=now
        if now<s.nextPoll then return end
        s.nextPoll=now+0.2
        if s.replaceScientist then muteNative(s,pawn) end
        local health=pawn.TotalCombinedHealth
        local hurt=type(health)=='number' and type(s.lastHealth)=='number' and health<s.lastHealth-0.01
        s.lastHealth=health
        if mode=='respawn' or mode=='sleep' then stop(s);nextIdle(s,now);s.lastAction=action;return end
        if hurt then M.play(s,pawn,'hurt',now,false) end
        if mode=='dead' then return end
        if action=='bite' and s.lastAction~='bite' and now-s.lastCombat>=s.options.combatCooldown
            and math.random()<s.options.combatChance then M.play(s,pawn,'combat',now,false) end
        s.lastAction=action
        if now>=s.nextIdle then
            -- A moving, eating, swimming or emoting fox should not add idle chatter.
            if not mode and not action and speed<15 and pawn.CharacterMovement.MovementMode==1 then M.play(s,pawn,'idle',now,false) end
            nextIdle(s,now)
        end
        if s.busyUntil and now>s.busyUntil then stop(s) end
    end)
    if not ok then M.cleanup(s);s.failed=true;s.log('Voice disabled for this pawn after audio error: '..tostring(err)) end
end
return M
