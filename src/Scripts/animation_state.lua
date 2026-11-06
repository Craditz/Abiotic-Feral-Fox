-- Pure state selection: all times come from the game's actor clock, not CPU time.
local M = {}
M.clips = {
    idle={asset='Idle',loop=true}, walk={asset='Walk',loop=true}, run={asset='Run',loop=true},
    takeoff={asset='Jump_Takeoff',loop=false,duration=0.1},
    air={asset='Jump_Air',loop=true}, fall={asset='Jump_Fall',loop=true},
    land={asset='Jump_Land',loop=false,duration=0.4166667},
    crouch_idle={asset='Crouch_Idle',loop=true}, crouch_walk={asset='Crouch_Walk',loop=true},
    swim={asset='Swim',loop=true}, ladder_idle={asset='Ladder_Idle',loop=true},
    ladder_left={asset='Ladder_Step_Left',loop=false,duration=1},
    ladder_right={asset='Ladder_Step_Right',loop=false,duration=1},
    death={asset='Death',loop=false,duration=1.0416667}, hit={asset='Hit',loop=false,duration=0.7},
    emote_wave={asset='Emote_Wave',loop=false,duration=3},
    emote_cheer={asset='Emote_Cheer',loop=false,duration=3},
    emote_wave_seated={asset='Emote_Wave_Seated',loop=false,duration=3,seated=true},
    emote_cheer_seated={asset='Emote_Cheer_Seated',loop=false,duration=3,seated=true},
    emote_dance={asset='Emote_Cheer',loop=true},
    sit={asset='Sit',loop=true}, sleep={asset='Sleep',loop=true},
    pickup={asset='Pickup',loop=false,duration=1.05}, eat={asset='Eat',loop=true},
    drink={asset='Drink',loop=true}, heal={asset='Heal',loop=true}, craft={asset='Craft_Work',loop=true},
    door={asset='Door_Open',loop=false,duration=0.85}, bite={asset='Bite',loop=false,duration=0.8333333}
}
M.preview = {'takeoff','air','fall','land','crouch_idle','crouch_walk','swim','ladder_idle',
    'ladder_left','ladder_right','hit','death','pickup','eat','drink','heal','craft','door','bite','sit','sleep','emote_wave','emote_cheer','emote_wave_seated','emote_cheer_seated','emote_dance'}
M.restPreview={'sit','sleep'}
for _, clip in pairs(M.clips) do clip.path='/Game/FeralFox/AN_Fox_'..clip.asset..'.AN_Fox_'..clip.asset end

function M.classifyMontage(path)
    -- Match full asset-name tokens, not 'eat' inside unrelated words such as 'create'.
    local name=path:match('([^/]+)$'):lower()
    if name:find('_eat_',1,true) then return 'eat' end
    if name:find('_drink_',1,true) then return 'drink' end
    if name:find('_bandage_use_',1,true) or name:find('_bandageothers_',1,true) or
        name:find('_syringe_use_',1,true) or name:find('_glue_use_',1,true) then return 'heal' end
    if name:find('_fists_punch_',1,true) then return 'bite' end
end

-- Hidden native meshes can retain a stopped/frozen montage reference. Only
-- follow a playing montage while its native playback position is progressing.
function M.observeMontage(memory,key,montage,position,playing,now)
    local action=montage and M.classifyMontage(montage)
    if not action or not playing or type(position)~='number' then memory[key]=nil;return end
    local previous=memory[key]
    if not previous or previous.montage~=montage or now<previous.changed or math.abs(position-previous.position)>0.0001 then
        local started=previous and previous.montage==montage and now>=previous.changed and position>=previous.position-.02 and previous.started or now
        previous={montage=montage,position=position,changed=now,started=started};memory[key]=previous
    end
    if now-previous.changed<=0.5 then return action,montage..'@'..tostring(previous.started) end
end

function M.special(mode,emote)
    if mode=='seat' or (mode=='emote' and (emote or ''):lower():find('_sit_floor_',1,true)) then return 'sit' end
    if mode=='sleep' then return 'sleep' end
    if mode=='dead' then return 'death' end
    if mode=='respawn' then return 'crouch_idle' end
    return 'idle'
end

function M.select(s, memory)
    local now, speed = s.time, s.speed
    if memory.lastTime and now < memory.lastTime then
        -- A changed/restarted actor clock must not keep an old landing lock alive.
        memory.airStart, memory.landStart, memory.wasFalling = nil, nil, false
    end
    memory.lastTime=now
    if s.falling then
        if not memory.wasFalling then
            memory.airStart=now
            memory.startedRising=s.verticalSpeed>80
        end
        memory.landStart=nil
    elseif memory.wasFalling then
        if now-(memory.airStart or now)>0.08 then memory.landStart=now end
    end
    memory.wasFalling=s.falling
    if s.preview and speed<15 and not s.falling and not s.swimming then return s.preview,1 end
    if s.swimming then memory.landStart=nil; return 'swim',math.max(0.6,math.min(1.8,speed/180)) end
    if s.falling then
        if memory.startedRising and now-memory.airStart<0.1 then return 'takeoff',1 end
        return s.verticalSpeed>=0 and 'air' or 'fall',1
    end
    if memory.landStart then
        local elapsed=now-memory.landStart
        if elapsed<0.4166667 and (speed<15 or elapsed<0.12) then return 'land',1 end
        memory.landStart=nil
    end
    -- Whole-body action clips are cosmetic. Moving, falling and swimming must
    -- remain responsive; never let an action plant the feet during locomotion.
    if speed<15 and s.action and M.clips[s.action] then return s.action,1 end
    if s.crouched then
        if speed>15 then return 'crouch_walk',math.max(0.5,math.min(2,speed/140)) end
        return 'crouch_idle',1
    end
    if speed>430 then return 'run',math.max(0.7,math.min(2,speed/420)) end
    if speed>15 then return 'walk',math.max(0.5,math.min(2.5,speed/180)) end
    return 'idle',1
end
return M
