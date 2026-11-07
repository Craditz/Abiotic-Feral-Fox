-- FeralFoxPrototype 0.16.4: scoped object lookup and host-controlled fox collision.
-- Requires FeralFoxCore_2_P.pak/.utoc/.ucas. Collision size is configured outside the game.
-- F6: fox + first person on/off. F7: optional external inspection camera.
local findObject = require('object_lookup')
local PREFIX = "[FeralFoxPrototype] "
local Appearance = require('appearance')
local MESH = Appearance.mesh
local IDLE = "/Game/FeralFox/AN_Fox_Idle.AN_Fox_Idle"
local WALK = "/Game/FeralFox/AN_Fox_Walk.AN_Fox_Walk"
local RUN = "/Game/FeralFox/AN_Fox_Run.AN_Fox_Run"
local Animation = require('animation_state')
local Actions = require('actions')
local Emotes = require('emotes')
local Equipment = require('equipment')
local Config = require('config')
local Voice = require('voice')
local function outputTrace(label)
    if require('config').trace_native_outputs==true then print('[FeralFoxNativeOutput] '..label..'\n') end
    return {}
end
local Preferences = require('preferences')
local Profiles = require('character_profiles')
local Identity = require('character_identity')
local Network = require('network')
local RemoteVisuals = require('remote_visuals')
Identity.setNetworkResolver(Network.identity)
local Customization = require('customization')
local FOX_SCALE = 0.8
local EYE_HEIGHTS = {46, 40, 34}
local EYE_FORWARD = 36 -- The imported head is about 40 cm ahead of the body pivot.
local CROUCH_EYE_RATIO = 0.7
local CAMERA_DISTANCES = {220, 150, 300, 380}
local CAMERA_PITCHES = {0, -20, 20, 40}
local state = nil -- Only plain Lua values/paths; never keep UObject handles across ticks.
local disable, enable, supervise
local retired={}
local candidate,stableCandidate,failedPawn=nil,0,nil
local scriptSource=debug.getinfo(1,'S').source
local scriptFolder=scriptSource:match('^@(.+[/\\])')
local preferenceFile=scriptFolder and (scriptFolder..'player-option.txt') or nil
local choice=Preferences.load(preferenceFile,Config.auto_enable~=false)
-- Old prototype/config "enabled" values were not a public species selection.
-- Preserve eye/colors, but never force that legacy global Fox choice in normal play.
if choice.confirmed~=true and Config.developer_controls~=true then choice.enabled=false end

choice=Profiles.copy(choice)
local template=Profiles.copy(choice)
local profiles=Profiles.open(scriptFolder or '',function(message)print(PREFIX..message.."\n")end)
local currentProfile,menuProfile=nil,nil
local pendingCreation
local function saveChoice()
    local ok,err
    if currentProfile and profiles.records[currentProfile] then
        ok,err=Profiles.save(profiles,currentProfile,profiles.records[currentProfile].label,choice)
    else
        ok,err=Preferences.save(preferenceFile,choice)
        if ok then template=Profiles.copy(choice) end
    end
    if not ok then print(PREFIX..'Could not save player option: '..tostring(err)..'\n') end
    return ok,err
end

local function log(message) print(PREFIX .. message .. "\n") end

local function valid(object)
    if object == nil then return false end
    local ok, result = pcall(function() return object:IsValid() end)
    return ok and result == true
end

local function path(object)
    assert(valid(object), "Expected a live Unreal object")
    return (object:GetFullName():gsub("^%S+ ", ""))
end

local function resolve(objectPath)
    if not objectPath then return nil end
    local object = findObject(objectPath)
    if valid(object) then return object end
    return nil
end

local function vec(value) return {X = value.X, Y = value.Y, Z = value.Z} end
local function rot(value) return {Pitch = value.Pitch, Yaw = value.Yaw, Roll = value.Roll} end
local function actorScale(pawn) return pawn:GetActorScale3D().Z end
local function footHeight(pawn)
    return pawn:K2_GetActorLocation().Z+pawn.Mesh.RelativeLocation.Z*actorScale(pawn)
end

local function setPhysicalScale(pawn, scale, floorOverride)
    local capsule=pawn.CapsuleComponent
    assert(valid(capsule), 'Player collision capsule unavailable')
    local position=vec(pawn:K2_GetActorLocation())
    local bottom=position.Z-capsule:GetScaledCapsuleHalfHeight()
    if floorOverride then bottom=floorOverride end
    pawn:SetActorScale3D(scale)
    position.Z=bottom+capsule:GetScaledCapsuleHalfHeight()
    pawn:K2_SetActorLocation(position,false,outputTrace('main.lua:78:K2_SetActorLocation'),true)
end

local function recoverSavedFloor(pawn)
    local p=pawn:K2_GetActorLocation()
    local half=pawn.CapsuleComponent:GetScaledCapsuleHalfHeight()
    local hit,color={},{R=0,G=0,B=0,A=0}
    local library=findObject('/Script/Engine.Default__KismetSystemLibrary')
    local found=library:SphereTraceSingle(pawn,{X=p.X,Y=p.Y,Z=p.Z+8},
        {X=p.X,Y=p.Y,Z=p.Z-half-8},8,0,false,{},0,hit,true,color,color,0)
    if found and hit.ImpactNormal.Z>0.65 then
        -- Native saves can contain a fox-sized capsule center. Loading it into
        -- a human capsule makes its bottom penetrate the floor. Preserve the
        -- native 2.15 cm floor gap instead of scaling that penetration deeper.
        local floor=hit.ImpactPoint.Z+2.15
        if floor>p.Z-half+4 and floor<p.Z+2 then return floor end
    end
end

local function resizeNetworkPawn(pawn, scale, firstShrink)
    if pawn.IsSleeping or pawn.IsSittingInSeat then
        -- Furniture already owns the pawn's center position.
        pawn:SetActorScale3D(scale)
    else
        setPhysicalScale(pawn, scale, firstShrink and recoverSavedFloor(pawn) or nil)
    end
end

local function updateVisualScale(pawn, visual)
    local scale = FOX_SCALE / actorScale(pawn)
    if state.visualScale ~= scale then
        visual:SetRelativeScale3D({X=scale, Y=scale, Z=scale})
        state.visualScale = scale
    end
end

local function attempt(label, action)
    local ok, result = pcall(action)
    if not ok then log("ERROR (" .. label .. "): " .. tostring(result)) end
    return ok, result
end

local function loadAsset(assetPath)
    local asset = resolve(assetPath)
    if not valid(asset) then
        asset = LoadAsset(assetPath)
        if not valid(asset) then asset = resolve(assetPath) end
    end
    if not valid(asset) then
        -- UE4SS LoadAsset consults the base AssetRegistry. New mounted packages
        -- need a direct soft-path load; do not replace the game's registry.
        local library = resolve("/Script/Engine.Default__KismetSystemLibrary")
        assert(valid(library), "Asset loading library unavailable")
        local softPath = library:MakeSoftObjectPath(assetPath)
        local reference = library:Conv_SoftObjPathToSoftObjRef(softPath)
        asset = library:LoadAsset_Blocking(reference)
        if not valid(asset) then asset = resolve(assetPath) end
    end
    assert(valid(asset), "Could not load asset: " .. assetPath)
    return asset
end

local REQUIRED_FUNCTIONS = {
    "Actor:AddComponentByClass", "Actor:K2_GetActorLocation", "Actor:K2_SetActorLocation",
    "Actor:K2_SetActorLocationAndRotation", "Actor:K2_GetActorRotation", "Actor:GetVelocity", "Actor:GetGameTimeSinceCreation", "Actor:SetReplicates",
    "Actor:SetActorEnableCollision", "Actor:SetOwner", "Actor:K2_DestroyActor",
    "ActorComponent:SetIsReplicated", "ActorComponent:K2_DestroyComponent",
    "ActorComponent:IsActive",
    "PrimitiveComponent:SetCollisionEnabled", "PrimitiveComponent:SetGenerateOverlapEvents",
    "PrimitiveComponent:SetOwnerNoSee", "PrimitiveComponent:SetOnlyOwnerSee",
    "SceneComponent:K2_SetRelativeLocation", "SceneComponent:K2_SetRelativeRotation",
    "SceneComponent:SetRelativeScale3D", "SceneComponent:SetVisibility", "SceneComponent:SetHiddenInGame",
    "SkeletalMeshComponent:SetSkeletalMeshAsset", "SkeletalMeshComponent:GetSkeletalMeshAsset",
    "SkeletalMeshComponent:PlayAnimation", "SkeletalMeshComponent:SetPlayRate",
    "SkeletalMeshComponent:GetAnimInstance", "AnimInstance:GetCurrentActiveMontage",
    "AnimInstance:Montage_IsPlaying", "AnimInstance:Montage_GetPosition",
    "Actor:GetActorScale3D", "Actor:SetActorScale3D", "CapsuleComponent:GetScaledCapsuleHalfHeight",
    "KismetSystemLibrary:IsStandalone",
    "CameraComponent:SetFieldOfView", "SceneComponent:K2_GetComponentLocation",
    "SceneComponent:K2_SetWorldLocation", "Controller:GetControlRotation", "Controller:SetControlRotation",
    "Controller:GetViewTarget", "PlayerController:SetViewTargetWithBlend",
    "KismetSystemLibrary:SphereTraceSingle", "KismetSystemLibrary:MakeSoftObjectPath",
    "KismetSystemLibrary:Conv_SoftObjPathToSoftObjRef", "KismetSystemLibrary:LoadAsset_Blocking",
    "KismetSystemLibrary:ExecuteConsoleCommand"
}
for _,name in ipairs(Equipment.required) do REQUIRED_FUNCTIONS[#REQUIRED_FUNCTIONS+1]=name end

local function preflight()
    local missing = {}
    for _, functionName in ipairs(REQUIRED_FUNCTIONS) do
        if not valid(resolve("/Script/Engine." .. functionName)) then
            missing[#missing + 1] = functionName
        end
    end
    assert(#missing == 0, "Unavailable reflected functions: " .. table.concat(missing, ", "))
    log("Engine API preflight passed (" .. #REQUIRED_FUNCTIONS .. " functions).")
end

local function localPlayer(quiet)
    for _, controller in ipairs(FindAllOf("PlayerController") or {}) do
        if valid(controller) and controller:IsLocalPlayerController() then
            local pawn = controller.Pawn
            if valid(pawn) and pawn:IsA("/Game/Blueprints/Characters/Abiotic_PlayerCharacter.Abiotic_PlayerCharacter_C") and
                controller:IsA('/Game/Blueprints/Meta/Abiotic_PlayerController.Abiotic_PlayerController_C') then
                local world=pawn:GetWorld()
                local worldName=valid(world) and path(world):lower() or ''
                if worldName~='' and not worldName:find('menu',1,true) and valid(controller.PlayerState) then
                return controller, pawn
                end
            end
        end
    end
    if not quiet then error("Waiting for your local character in a gameplay world.") end
end

local function updateFirstPerson(controller, pawn)
    local native = resolve(state.nativeCamera)
    local anchor = resolve(state.cameraAnchor)
    local visual = resolve(state.visual)
    assert(valid(native) and valid(anchor), 'Native first-person camera expired')
    local location = pawn:K2_GetActorLocation()
    local feet = footHeight(pawn)
    local scale=actorScale(pawn)
    local crouched = pawn.bIsCrouched == true or state.special=='seat'
    local eye = EYE_HEIGHTS[state.eyeIndex or 1] * (crouched and CROUCH_EYE_RATIO or 1)
    local movement = pawn.CharacterMovement
    assert(valid(movement) and type(movement.CrouchedHalfHeight)=='number', 'Crouch dimensions unavailable')
    -- The game's camera tick rewrites CameraHeadJoint from BaseEyeHeight.
    -- Change its instance inputs too, so native tick ordering cannot undo the view.
    pawn.CrouchedEyeHeight = EYE_HEIGHTS[state.eyeIndex or 1]*CROUCH_EYE_RATIO/scale-movement.CrouchedHalfHeight
    pawn.BaseEyeHeight = (feet+eye-location.Z)/scale
    if state.special=='seat' then pawn.SittingEyeHeight=pawn.BaseEyeHeight end
    local anchorLocation = anchor:K2_GetComponentLocation()
    anchor:K2_SetWorldLocation({X=anchorLocation.X, Y=anchorLocation.Y,
        Z=feet+eye}, false, outputTrace('main.lua:194:transform'), true)
    local start=anchor:K2_GetComponentLocation()
    start.Z=feet+eye
    local yaw=math.rad(controller:GetControlRotation().Yaw)
    local desired={X=start.X+math.cos(yaw)*EYE_FORWARD, Y=start.Y+math.sin(yaw)*EYE_FORWARD, Z=start.Z}
    local library=resolve('/Script/Engine.Default__KismetSystemLibrary')
    assert(valid(library), 'First-person clearance library unavailable')
    local hit, color=outputTrace('first-person clearance'), {R=0,G=0,B=0,A=0}
    local blocked=library:SphereTraceSingle(pawn,start,desired,12,0,false,{},0,hit,true,color,color,0)
    native:K2_SetWorldLocation(blocked and vec(hit.Location) or desired,false,outputTrace('main.lua:203:K2_SetWorldLocation'),true)
    if blocked~=state.headObstructed then
        if blocked then log('First-person head clearance: view pulled back from obstacle.')
        elseif state.headObstructed then log('First-person head clearance restored.') end
        state.headObstructed=blocked
    end
    -- Use the game's own view target, camera rotation, FOV and interaction code.
    -- Do not attach to an animated fox bone: head motion should not shake aiming.
    if valid(visual) and visual.bVisible then visual:SetVisibility(false, false) end
    if crouched ~= state.cameraCrouched then
        state.cameraCrouched = crouched
        log(string.format('Native first person: eye %.1f cm above feet; crouched=%s; FOV %.1f.',
            eye, tostring(crouched), native.FieldOfView))
    end
end

local function updateRearCamera(controller, pawn)
    local camera = resolve(state.camera)
    assert(valid(camera), "Preview camera is no longer valid")
    local location = pawn:K2_GetActorLocation()
    local look = controller:GetControlRotation()
    local signedPitch = (look.Pitch + 180) % 360 - 180
    local pitch = math.max(-55, math.min(55, signedPitch + (state.pitchOffset or 0))) - 8
    local pitchRadians, yawRadians = math.rad(pitch), math.rad(look.Yaw + (state.yawOffset or 0))
    local distance = CAMERA_DISTANCES[state.distanceIndex or 1]
    local feet = footHeight(pawn)
    local target = {X = location.X, Y = location.Y, Z = feet + 30}
    local desired = {
        X = target.X - math.cos(pitchRadians) * math.cos(yawRadians) * distance,
        Y = target.Y - math.cos(pitchRadians) * math.sin(yawRadians) * distance,
        Z = target.Z - math.sin(pitchRadians) * distance
    }
    -- Do not orbit below the player's current foot plane, including crouching.
    desired.Z = math.max(desired.Z, feet + 20)
    local library = resolve("/Script/Engine.Default__KismetSystemLibrary")
    assert(valid(library), "Camera collision library unavailable")
    local hit = outputTrace('rear-camera clearance')
    local color = {R = 0, G = 0, B = 0, A = 0}
    -- TraceTypeQuery1 = the Visibility query also used by the bundled LineTraceMod.
    -- A small sphere keeps the near plane outside walls; ignore the player itself.
    local blocked = library:SphereTraceSingle(pawn, target, desired, 12, 0, false,
        {}, 0, hit, true, color, color, 0.0)
    local position = blocked and vec(hit.Location) or desired
    local function cameraDistance(point)
        return math.sqrt((point.X-target.X)^2 + (point.Y-target.Y)^2 + (point.Z-target.Z)^2)
    end
    -- When a bench/wall pulls the view into the fox, try looking over it.
    if blocked and cameraDistance(position) < 80 then
        local elevated = {X = desired.X, Y = desired.Y, Z = math.max(desired.Z, target.Z+120)}
        local raisedHit = outputTrace('rear-camera raised clearance')
        local raisedBlocked = library:SphereTraceSingle(pawn, target, elevated, 12, 0, false,
            {}, 0, raisedHit, true, color, color, 0.0)
        local raisedPosition = raisedBlocked and vec(raisedHit.Location) or elevated
        if cameraDistance(raisedPosition) > cameraDistance(position)+20 then position = raisedPosition end
    end
    local hideFox = cameraDistance(position) < 80
    if hideFox ~= state.cameraHidingFox then
        local visual = resolve(state.visual)
        if valid(visual) then visual:SetVisibility(not hideFox, false) end
        if hideFox then log("Camera too close; fox hidden until the view clears.")
        elseif state.cameraHidingFox then log("Camera clearance restored; fox visible.") end
        state.cameraHidingFox = hideFox
    end
    local deltaX, deltaY, deltaZ = target.X-position.X, target.Y-position.Y, target.Z-position.Z
    local horizontal = math.sqrt(deltaX*deltaX + deltaY*deltaY)
    local viewPitch = math.deg(math.atan(deltaZ, horizontal))
    local viewYaw = horizontal > 0.01 and math.deg(math.atan(deltaY, deltaX)) or look.Yaw
    camera:K2_SetActorLocationAndRotation(position,{Pitch=viewPitch,Yaw=viewYaw,Roll=0},false,outputTrace('main.lua:270:K2_SetActorLocationAndRotation'),true)
    if blocked ~= state.cameraObstructed then
        if blocked then log("Camera obstruction detected; rear view pulled forward.")
        elseif state.cameraObstructed then log("Camera obstruction cleared.") end
        state.cameraObstructed = blocked
    end
    if look.Pitch > 180 and not state.pitchWrapLogged then
        state.pitchWrapLogged = true
        log(string.format("Wrapped camera pitch normalized: %.1f -> %.1f degrees.", look.Pitch, signedPitch))
    end
end

local function updateCamera(controller, pawn)
    if state.rearView then updateRearCamera(controller, pawn)
    else updateFirstPerson(controller, pawn) end
end

local function originalView(controller, pawn, savedState)
    -- An old pawn must never steal the new pawn's view during respawn.
    if not valid(controller) or not valid(controller.Pawn) or path(controller.Pawn)~=savedState.pawn then return end
    local target = resolve(savedState.originalView)
    if not valid(target) then target = pawn end
    if valid(controller) and valid(target) then
        controller:SetViewTargetWithBlend(target, 0, 0, 0, false)
    end
end

local function restoreNativeCamera(saved,pawn)
    attempt('restore native camera offset', function()
        local native=resolve(saved.nativeCamera)
        if valid(native) then native:K2_SetRelativeLocation(saved.nativeCameraLocation,false,outputTrace('main.lua:300:K2_SetRelativeLocation'),true) end
    end)
    attempt('restore native eye heights', function()
        if valid(pawn) and saved.eyes then
            pawn.CrouchedEyeHeight = saved.eyes.crouched
            if saved.eyes.sitting~=nil then pawn.SittingEyeHeight=saved.eyes.sitting end
            if (pawn.bIsCrouched==true)==saved.eyes.wasCrouched then pawn.BaseEyeHeight=saved.eyes.base
            else pawn.BaseEyeHeight=pawn.bIsCrouched and saved.eyes.crouched or saved.eyes.standing end
        end
    end)
    attempt('restore native camera anchor', function()
        local anchor = resolve(saved.cameraAnchor)
        if valid(anchor) then
            local restored = vec(saved.anchorLocation)
            if valid(pawn) and saved.eyes then restored.Z=restored.Z+pawn.BaseEyeHeight-saved.eyes.base end
            anchor:K2_SetRelativeLocation(restored, false, outputTrace('main.lua:315:transform'), true)
        end
    end)
end

local function cleanupState(saved,reason)
    if saved.timer then attempt("cancel timer", function() CancelDelayedAction(saved.timer) end); saved.timer=nil end
    local controller,pawn=resolve(saved.controller),resolve(saved.pawn)
    Actions.detach(saved.actions)
    attempt('stop fox voice',function() Voice.cleanup(saved.voice) end)
    attempt('restore equipment visuals',function() Equipment.cleanup(saved.equipment or {},pawn) end)
    attempt('restore physical size',function()
        if saved.originalScale and valid(pawn) then setPhysicalScale(pawn,saved.originalScale) end
    end)
    restoreNativeCamera(saved,pawn)
    attempt("restore view", function() originalView(controller, pawn, saved) end)
    for componentPath, flags in pairs(saved.hidden) do
        attempt("restore visibility", function()
            local component = resolve(componentPath)
            if valid(component) then
                component:SetHiddenInGame(flags.hidden, false)
                component:SetVisibility(flags.visible, false)
                if flags.animationTick~=nil then component.VisibilityBasedAnimTickOption=flags.animationTick end
            end
        end)
    end
    attempt("remove preview mesh", function()
        local visual = resolve(saved.visual)
        if valid(visual) then
            visual:SetHiddenInGame(true, false)
            if valid(pawn) then visual:K2_DestroyComponent(pawn) end
        end
    end)
    attempt("remove camera", function()
        local camera = resolve(saved.camera)
        if valid(camera) then camera:K2_DestroyActor() end
    end)
    log("OFF: " .. reason .. ". Original visibility and view restored where objects are still valid.")
end

disable = function(reason)
    local saved=state
    state=nil
    if saved then cleanupState(saved,reason) end
end

local function hideHuman(saved)
    for componentPath in pairs(saved.hidden) do
        local component=resolve(componentPath)
        if valid(component) then
            if component.bVisible then component:SetVisibility(false,false) end
            if not component.bHiddenInGame then component:SetHiddenInGame(true,false) end
            component.VisibilityBasedAnimTickOption=0
        end
    end
end

local function specialMode(pawn)
    if pawn.RespawnInProgress==true then return 'respawn' end
    if pawn.IsDead then return 'dead' end
    if pawn.IsSleeping then return 'sleep' end
    if pawn.IsSittingInSeat then return 'seat' end
    -- LastKnownLoadedEmote remains cached after stopping. Only the live flag
    -- establishes the native third-person emote state (verified by F8).
    if Emotes.active(pawn) then
        local velocity=pawn:GetVelocity()
        if pawn.EmoteShouldHideFP==true or velocity.X^2+velocity.Y^2<225 then return 'emote' end
    end
end

local function readyForControl(pawn)
    if pawn.ServerLevelLoaded~=true or pawn.OwningLevelLoaded~=true or pawn.Local_ReadyToControlPlayer~=true or pawn.RespawnInProgress==true then return false end
    local movement=pawn.CharacterMovement
    return valid(movement) and (movement.MovementMode==1 or movement.MovementMode==4)
end

local function updateSpecial(controller,pawn,visual,mode)
    if state.special~=mode then
        local inspect=state.rearView and mode=='emote' and pawn.EmoteShouldHideFP~=true
        if mode~='emote' then
            if state.originalScale and math.abs(actorScale(pawn)-state.originalScale.Z)>0.0001 then
                if mode=='seat' or mode=='sleep' then
                    -- Furniture has already placed the actor at a native-sized
                    -- seat/bed transform. Do not lift that authored position
                    -- again by preserving the smaller capsule bottom.
                    pawn:SetActorScale3D(state.originalScale)
                else setPhysicalScale(pawn,state.originalScale) end
                updateVisualScale(pawn, visual)
            end
        elseif state.foxPhysicalScale and math.abs(actorScale(pawn)-state.foxPhysicalScale.Z)>0.0001 then
            setPhysicalScale(pawn,state.foxPhysicalScale,recoverSavedFloor(pawn))
            updateVisualScale(pawn, visual)
        end
        if not inspect and (not state.special or state.special=='seat') then
            restoreNativeCamera(state,pawn)
            local target=controller:GetViewTarget()
            if valid(target) and path(target)==state.camera and valid(controller.Pawn) and path(controller.Pawn)==path(pawn) then
                controller:SetViewTargetWithBlend(pawn,0,0,0,false)
            end
        end
        state.special=mode
        state.rearView=inspect==true
        state.emoteMemory={}
        state.emoteForcedCamera=false
        state.previewClip=nil
        state.cameraHidingFox=nil
        state.animation=nil
        state.cameraCrouched=nil
        state.specialAnimation=nil
        log('Persistent fox: '..mode..' state; fox visuals retained, native special flow preserved.')
    end
    if mode=='emote' and pawn.EmoteShouldHideFP==true then state.emoteForcedCamera=true end
    local emote=mode=='emote' and pawn.LastKnownLoadedEmote or nil
    local clipKey=Animation.special(mode,valid(emote) and path(emote) or '')
    local rate,emoteToken=1,nil
    if mode=='emote' or mode=='seat' then
        state.emoteMemory=state.emoteMemory or {}
        clipKey,rate,emoteToken=Emotes.select(pawn,mode,pawn:GetGameTimeSinceCreation(),state.emoteMemory,state.actions and state.actions.emoteSerial)
    end
    if clipKey~=state.specialAnimation or emoteToken~=state.specialEmoteToken then
        local clip=Animation.clips[clipKey]
        visual:PlayAnimation(loadAsset(clip.path),clip.loop)
        state.specialAnimation=clipKey
        state.specialEmoteToken=emoteToken
        log('Special animation: '..clipKey..'.')
    end
    visual:SetPlayRate(rate)
    -- Native placement/facing can change while a seat or bed owns the pawn.
    visual:K2_SetRelativeLocation(vec(pawn.Mesh.RelativeLocation),false,outputTrace('main.lua:428:K2_SetRelativeLocation'),true)
    local specialRotation=rot(pawn.Mesh.RelativeRotation)
    -- Native seating uses the human mesh basis. Both fox sit and idle clips
    -- share their forward axis, so correct only this seated transform.
    if clipKey=='sit' or Animation.clips[clipKey].seated then specialRotation.Yaw=specialRotation.Yaw-90 end
    visual:K2_SetRelativeRotation(specialRotation,false,outputTrace('main.lua:433:K2_SetRelativeRotation'),true)
    local target=controller:GetViewTarget()
    local third=pawn.ThirdPersonCamera
    local external=(valid(target) and path(target)~=path(pawn)) or (valid(third) and third:IsActive())
    local inspectable=mode=='seat' or (mode=='emote' and pawn.EmoteShouldHideFP~=true)
    if inspectable and state.rearView then
        visual:SetVisibility(true,false)
        updateRearCamera(controller,pawn)
    elseif inspectable and not external then
        updateFirstPerson(controller,pawn)
    else visual:SetVisibility(external==true,false) end
    hideHuman(state)
    Equipment.suspend(state.equipment,pawn)
end

local function retireDead()
    local saved=state
    if saved.timer then CancelDelayedAction(saved.timer); saved.timer=nil end
    state=nil
    retired[saved.pawn]=saved
    log('Persistent fox: dead pawn retained as fox while waiting for possession.')
end

local function tick()
    if not state then return end
    local ok, err = pcall(function()
        local controller, pawn = resolve(state.controller), resolve(state.pawn)
        local visual = resolve(state.visual)
        if not valid(controller) or not valid(pawn) then disable('player expired; fox choice retained'); return end
        if not valid(controller.Pawn) or path(controller.Pawn)~=state.pawn then
            if pawn.IsDead and valid(visual) then updateSpecial(controller,pawn,visual,'dead'); retireDead()
            else disable('possession changed; fox choice retained') end
            return
        end
        assert(valid(visual), 'Fox visual component expired')
        updateVisualScale(pawn, visual)
        local mode=specialMode(pawn)
        local voiceVelocity=pawn:GetVelocity()
        Voice.update(state.voice,pawn,mode,state.nativeAction,math.sqrt(voiceVelocity.X^2+voiceVelocity.Y^2))
        if mode then Actions.update(state.actions,pawn,mode,nil,nil,0);updateSpecial(controller,pawn,visual,mode); return end
        if state.special then
            if not readyForControl(pawn) then updateSpecial(controller,pawn,visual,state.special);return end
            if state.foxPhysicalScale then
                setPhysicalScale(pawn,state.foxPhysicalScale,recoverSavedFloor(pawn))
                updateVisualScale(pawn, visual)
            end
            local inspect=state.special=='emote' and state.rearView and not state.emoteForcedCamera
            state.special=nil
            if state.eyes.sitting~=nil then pawn.SittingEyeHeight=state.eyes.sitting end
            state.rearView=inspect==true
            state.footOffset=nil
            state.animation=nil
            state.cameraCrouched=nil
            state.animationMemory={}
            if inspect then
                updateRearCamera(controller,pawn)
                controller:SetViewTargetWithBlend(resolve(state.camera),0,0,0,false)
            else controller:SetViewTargetWithBlend(pawn,0,0,0,false) end
            log('Persistent fox: normal camera resumed automatically.')
        end
        -- Camera updates use the original controller look direction, without changing it.
        updateCamera(controller, pawn)
        local velocity = pawn:GetVelocity()
        local speed = math.sqrt(velocity.X * velocity.X + velocity.Y * velocity.Y)
        if not state.rearView then state.facingYaw=controller:GetControlRotation().Yaw
        elseif speed > 15 then state.facingYaw = math.deg(math.atan(velocity.Y, velocity.X)) end
        if state.facingYaw then
            local actorYaw = pawn:K2_GetActorRotation().Yaw
            visual:K2_SetRelativeRotation({Pitch = 0, Yaw = state.facingYaw-actorYaw-90, Roll = 0}, false, outputTrace('main.lua:494:transform'), true)
        end
        local movement=pawn.CharacterMovement
        assert(valid(movement) and type(movement.MovementMode)=='number', 'Movement mode unavailable')
        if speed>15 and state.previewClip then
            state.previewClip=nil
            log('Inspection animation canceled by movement.')
        end
        local action,actionSerial=Actions.update(state.actions,pawn,
            (movement.MovementMode==3 or movement.MovementMode==4) and 'traversal' or nil,
            state.nativeAction,state.nativeActionToken,speed)
        local animation, rate=Animation.select({time=pawn:GetGameTimeSinceCreation(), speed=speed,
            verticalSpeed=velocity.Z, falling=movement.MovementMode==3,
            swimming=movement.MovementMode==4, crouched=pawn.bIsCrouched==true,
            action=action,
            preview=state.rearView and state.previewClip or nil}, state.animationMemory)
        local clip=Animation.clips[animation]
        if animation~=state.animation or (actionSerial and actionSerial~=state.actionSerial) then
            visual:PlayAnimation(loadAsset(clip.path), clip.loop)
            state.animation=animation
            state.actionSerial=actionSerial
            log(string.format('Animation: %s; speed %.1f cm/s; movement mode %d.', animation, speed, movement.MovementMode))
        end
        visual:SetPlayRate(rate)
        -- Capsule crouch offsets can change in one frame; do not wait for the
        -- slower visibility-maintenance pass before grounding the fox again.
        local footOffset=vec(pawn.Mesh.RelativeLocation)
        local previous=state.footOffset
        if not previous or math.abs(previous.X-footOffset.X)+math.abs(previous.Y-footOffset.Y)+math.abs(previous.Z-footOffset.Z)>0.001 then
            visual:K2_SetRelativeLocation(footOffset, false, outputTrace('main.lua:519:transform'), true)
            state.footOffset=footOffset
        end
        state.ticks = state.ticks + 1
        Equipment.update(state.equipment,pawn,controller,visual,state,Config,state.ticks%6==0)
        if state.ticks % 6 ~= 0 then return end
        local action, montagePath, actionToken, componentKey
        state.nativeMontages=state.nativeMontages or {}
        local now=pawn:GetGameTimeSinceCreation()
        for componentPath in pairs(state.hidden) do
            local component = resolve(componentPath)
            if valid(component) then
                if component.bVisible then component:SetVisibility(false, false) end
                if not component.bHiddenInGame then component:SetHiddenInGame(true, false) end
                component.VisibilityBasedAnimTickOption=0
                local instance=component:GetAnimInstance()
                if valid(instance) then
                    local montage=instance:GetCurrentActiveMontage()
                    if valid(montage) then
                        local candidate,token=Animation.observeMontage(state.nativeMontages,componentPath,path(montage),
                            instance:Montage_GetPosition(montage),instance:Montage_IsPlaying(montage),now)
                        if candidate and (not action or Actions.rank(candidate)>Actions.rank(action) or
                            (candidate==action and componentPath<(componentKey or ''))) then
                            action=candidate;montagePath=path(montage);actionToken=token;componentKey=componentPath
                        end
                    else state.nativeMontages[componentPath]=nil
                    end
                else state.nativeMontages[componentPath]=nil end
            end
        end
        state.nativeActionToken=actionToken
        if action~=state.nativeAction then
            state.nativeAction=action
            log('Native cosmetic action: '..(action or 'none')..(montagePath and '; '..montagePath or ''))
        end
    end)
    if not ok then
        log("ERROR (update): " .. tostring(err))
        failedPawn=state and state.pawn
        disable("update failed")
    end
end

enable = function()
    local controller, pawn = localPlayer()
    assert(readyForControl(pawn),'Waiting for native loading/control readiness and stable movement')
    for _, property in ipairs({'IsDead','IsSleeping','IsSittingInSeat'}) do
        assert(pawn[property]~=true, 'Wait until native '..property..' finishes before enabling the fox')
    end
    preflight()
    assert(type(LoopInGameThreadWithDelay) == "function" and type(CancelDelayedAction) == "function", "Game-thread timer API unavailable")
    local mesh, idle, walk, run = loadAsset(MESH), loadAsset(IDLE), loadAsset(WALK), loadAsset(RUN)
    assert(mesh:IsA("/Script/Engine.SkeletalMesh"), "Fox asset is not a skeletal mesh")
    for _, animation in ipairs({idle, walk, run}) do
        assert(valid(mesh.Skeleton) and valid(animation.Skeleton), "Fox skeleton references unavailable")
        assert(path(mesh.Skeleton) == path(animation.Skeleton), "Fox animation uses a different skeleton")
    end
    for _, clip in pairs(Animation.clips) do
        local asset=loadAsset(clip.path)
        assert(valid(asset.Skeleton) and path(asset.Skeleton)==path(mesh.Skeleton), 'Action clip skeleton differs: '..clip.asset)
    end
    local meshClass = resolve("/Script/Engine.SkeletalMeshComponent")
    local cameraClass = resolve("/Script/Engine.CameraActor")
    assert(valid(meshClass) and valid(cameraClass) and valid(pawn.Mesh), "Required classes/player mesh unavailable")

    -- Gather original visual flags before creating our component. Keep exact values for rollback.
    local hidden = {}
    local itemRenderers={}
    for _,key in ipairs({'CurrentFPItemMesh','TP_ItemInHand'}) do
        local renderer=pawn[key]
        if valid(renderer) then itemRenderers[path(renderer)]=true end
    end
    for _, component in ipairs(FindAllOf("SkeletalMeshComponent") or {}) do
        if valid(component) then
            local owner = component:GetOwner()
            if valid(owner) and path(owner) == path(pawn) and not itemRenderers[path(component)] and
                not path(component):find('.NODE_Add',1,true) and
                not component:GetFullName():match('^MaterialSwapSkeletalMeshComponent ') then
                assert(type(component.bVisible) == "boolean" and type(component.bHiddenInGame) == "boolean", "Cannot capture original component visibility")
                hidden[path(component)] = {visible = component.bVisible, hidden = component.bHiddenInGame,
                    animationTick=component.VisibilityBasedAnimTickOption}
            end
        end
    end
    assert(next(hidden) ~= nil, "No original player visuals found")
    local viewTarget = controller:GetViewTarget()
    local nativeCamera, anchor = pawn.FirstPersonCamera, pawn.CameraHeadJoint
    assert(valid(nativeCamera) and valid(anchor), 'Native first-person camera/head anchor unavailable')
    local anchorLocation = vec(anchor.RelativeLocation)
    local defaultPawn = pawn:GetClass():GetCDO()
    assert(valid(defaultPawn) and type(defaultPawn.BaseEyeHeight)=='number' and
        type(pawn.BaseEyeHeight)=='number' and type(pawn.CrouchedEyeHeight)=='number', 'Native eye-height defaults unavailable')
    local nativeLocation = nativeCamera:K2_GetComponentLocation()
    log(string.format('Native camera captured: eye %.1f cm; anchor relative %.1f, %.1f, %.1f; FOV %.1f.',
        nativeLocation.Z-pawn:K2_GetActorLocation().Z-pawn.Mesh.RelativeLocation.Z,
        anchorLocation.X, anchorLocation.Y, anchorLocation.Z, nativeCamera.FieldOfView))
    state = {
        pawn = path(pawn), controller = path(controller), hidden = hidden,
        originalView = valid(viewTarget) and path(viewTarget) or path(pawn),
        ticks = 0, rearView = false, animationMemory = {}, equipment = {},
        nativeCamera = path(nativeCamera), nativeCameraLocation=vec(nativeCamera.RelativeLocation),
        cameraAnchor = path(anchor), anchorLocation = anchorLocation,
        eyes = {base=pawn.BaseEyeHeight, crouched=pawn.CrouchedEyeHeight, sitting=pawn.SittingEyeHeight,
            standing=defaultPawn.BaseEyeHeight, wasCrouched=pawn.bIsCrouched==true}
    }
    state.actions=Actions.attach(pawn,log)
    for i,height in ipairs(EYE_HEIGHTS) do if height==choice.eye then state.eyeIndex=i end end
    if Config.small_collision then
        local library=resolve('/Script/Engine.Default__KismetSystemLibrary')
        if library:IsStandalone(pawn) then
            local scale=vec(pawn:GetActorScale3D())
            assert(math.abs(scale.X-scale.Y)<0.001 and math.abs(scale.X-scale.Z)<0.001 and scale.Z>0,
                'Experimental fox collision requires uniform actor scale')
            assert(type(Config.collision_scale)=='number' and Config.collision_scale>=0.25 and Config.collision_scale<=1,
                'collision_scale must be between 0.25 and 1')
            state.originalScale=scale
            local factor=Config.collision_scale
            state.foxPhysicalScale={X=scale.X*factor,Y=scale.Y*factor,Z=scale.Z*factor}
            local floor=recoverSavedFloor(pawn)
            setPhysicalScale(pawn,state.foxPhysicalScale,floor)
            if floor then log('Persistent fox: recovered saved capsule center against the floor.') end
            log('Experimental fox collision enabled. F6 restores human size; leave tight gaps before disabling, or use native Unstuck.')
        end
    end

    local identity = {
        Rotation = {X = 0, Y = 0, Z = 0, W = 1},
        Translation = {X = 0, Y = 0, Z = 0}, Scale3D = {X = 1, Y = 1, Z = 1}
    }
    local visual = pawn:AddComponentByClass(meshClass, false, identity, false)
    assert(valid(visual), "Could not create preview skeletal mesh component")
    state.visual = path(visual)
    visual:SetIsReplicated(false)
    visual:SetCollisionEnabled(0)
    visual:SetGenerateOverlapEvents(false)
    visual:SetOwnerNoSee(false)
    visual:SetOnlyOwnerSee(false)
    -- Keep the animated mouth pose current while first person hides the body.
    visual.VisibilityBasedAnimTickOption=0
    -- SetSkeletalMesh is a C++-only method in this build. Use the reflected setter.
    visual:SetSkeletalMeshAsset(mesh)
    local assignedMesh = visual:GetSkeletalMeshAsset()
    assert(valid(assignedMesh) and path(assignedMesh) == path(mesh), "Mesh setter did not assign the fox")
    Appearance.apply(visual,choice,loadAsset)
    log("Fox mesh assigned and verified: " .. path(assignedMesh))
    visual:K2_SetRelativeLocation(vec(pawn.Mesh.RelativeLocation), false, outputTrace('main.lua:653:transform'), true)
    visual:K2_SetRelativeRotation(rot(pawn.Mesh.RelativeRotation), false, outputTrace('main.lua:654:transform'), true)
    updateVisualScale(pawn, visual)
    visual:PlayAnimation(idle, true)
    state.animation = 'idle'
    visual:SetVisibility(true, false)
    visual:SetHiddenInGame(false, false)

    local camera = pawn:GetWorld():SpawnActor(cameraClass, vec(pawn:K2_GetActorLocation()), {Pitch = 0, Yaw = 0, Roll = 0})
    assert(valid(camera), "Could not create preview camera")
    state.camera = path(camera)
    camera:SetReplicates(false)
    camera:SetActorEnableCollision(false)
    camera:SetOwner(pawn)
    if valid(camera.CameraComponent) then camera.CameraComponent:SetFieldOfView(90) end
    updateCamera(controller, pawn)

    for componentPath in pairs(hidden) do
        local component = resolve(componentPath)
        if valid(component) then
            component:SetVisibility(false, false)
            component:SetHiddenInGame(true, false)
            component.VisibilityBasedAnimTickOption=0
        end
    end
    controller:SetViewTargetWithBlend(pawn, 0, 0, 0, false)
    local voiceOK,voiceState=attempt('fox voice initialization',function()return Voice.init(pawn,Config,loadAsset,log)end)
    if voiceOK then state.voice=voiceState end
    state.timer = LoopInGameThreadWithDelay(16, tick)
    log("Fox active: native first person, fox eyes and quadruped animations.")
    if Config.developer_controls==true then log("Developer controls ready: F6 toggle, F7 inspection, F8 diagnostics; F9/F10 keyboard look.") end
end

local function toggleBody()
    choice.enabled=not choice.enabled
    choice.confirmed=true
    saveChoice()
    failedPawn,candidate,stableCandidate=nil,nil,0
    if not choice.enabled then
        disable('F6: saved fox option disabled')
        for p,saved in pairs(retired) do cleanupState(saved,'saved fox option disabled'); retired[p]=nil end
        log('Fox option saved: OFF. It will stay off on reload and respawn.')
        return
    end
    local controller,pawn=localPlayer(true)
    if not valid(pawn) or specialMode(pawn) or not readyForControl(pawn) then log('Fox option saved: ON. Waiting for a playable character.'); return end
    local ok, err = pcall(enable)
    if not ok then
        log("ERROR (enable): " .. tostring(err))
        failedPawn=path(pawn)
        disable("incomplete activation rolled back")
    end
end

local function selectSpecies(enabled,appearance,context,profileKey)
    local mode=Customization.context(context)
    if not mode then return false,'Species can only be selected in character creation or Customization.' end
    local controller,pawn=localPlayer(true)
    if valid(pawn) and (mode~='creation' or (readyForControl(pawn) and not Customization.isCommittingCreation(context))) then
        return false,'Return to the main menu to change species.'
    end
    local selected=Profiles.copy(appearance)
    selected.enabled,selected.confirmed=enabled==true,true
    selected.eye=(profileKey and Profiles.get(profiles,profileKey) or template).eye
    local ok,err
    if mode=='creation' then
        local identity=Identity.resolve(controller,pawn)
        if not identity then
            local context=Network.context(controller,pawn)
            if context then
                -- Replicated owner state may arrive after the native creation
                -- menu closes. Retain this explicit choice only for this live
                -- connection; bind it durably once its server scope is known.
                pendingCreation={context=context,choice=Profiles.copy(selected)}
                ok=true
            else ok,err=false,'Waiting for the native character save identity.'end
        else ok,err=Profiles.stageCreation(profiles,identity,selected)end
        if ok then choice=selected;currentProfile=nil end
    elseif profileKey and profileKey~='default' then
        local record=profiles.records[profileKey]
        if not record then return false,'That character profile is unavailable.' end
        ok,err=Profiles.save(profiles,profileKey,record.label,selected)
        if ok then menuProfile=profileKey;if currentProfile==profileKey then choice=selected end end
    else
        ok,err=Preferences.save(preferenceFile,selected)
        if ok then template=selected;if not currentProfile then choice=selected end end
    end
    if not ok then return false,tostring(err) end
    failedPawn,candidate,stableCandidate=nil,nil,0
    log('Species saved for '..(mode=='creation' and 'new character' or (profileKey and profileKey~='default' and profiles.records[profileKey].label or 'new-character defaults'))..': '..(enabled and 'Fox' or 'Human')..'.')
    return true
end

supervise=function()
    local ok,err=pcall(function()
        for p,saved in pairs(retired) do
            local pawn=resolve(p)
            if not valid(pawn) then cleanupState(saved,'dead pawn expired'); retired[p]=nil
            else
                hideHuman(saved); Equipment.suspend(saved.equipment,pawn)
                local visual=resolve(saved.visual)
                if valid(visual) then visual:SetVisibility(true,false) end
            end
        end
        if Customization.isCreating() then candidate,stableCandidate=nil,0;return end
        local controller,pawn=localPlayer(true)
        if valid(pawn) and readyForControl(pawn) then
            local key,label=Identity.resolve(controller,pawn)
            if not key then
                return
            end
            if currentProfile~=key then
                if pendingCreation then
                    if pendingCreation.context==Network.context(controller,pawn)then
                        local staged,why=Profiles.stageCreation(profiles,key,pendingCreation.choice)
                        if not staged then log('Could not bind pending Fox choice: '..tostring(why));return end
                    end
                    pendingCreation=nil
                end
                local selected,why=Profiles.bind(profiles,key,label,template)
                if not selected then log('Character choice not applied: '..tostring(why));return end
                if state and (currentProfile or selected.enabled~=choice.enabled or selected.eye~=choice.eye or
                    selected.coat~=choice.coat or selected.eyes~=choice.eyes or selected.paws~=choice.paws) then
                    disable('Character save identity changed')
                end
                currentProfile,menuProfile,choice=key,key,selected
                failedPawn,candidate,stableCandidate=nil,nil,0
            end
        end
        if not choice.enabled or state then return end
        if not valid(pawn) then candidate,stableCandidate=nil,0; return end
        if not currentProfile then return end
        local networked=currentProfile:sub(1,11)=='network-v1:'
        if networked and not Network.accepted(controller,choice)then return end
        local p=path(pawn)
        if p~=candidate then candidate,stableCandidate=p,0 end
        if p==failedPawn then return end
        if not readyForControl(pawn) then stableCandidate=0;return end
        stableCandidate=stableCandidate+1
        if stableCandidate<2 or pawn:GetGameTimeSinceCreation()<2 or specialMode(pawn) or
            not valid(pawn.CharacterMovement) or pawn.CharacterMovement.MovementMode==0 or
            not valid(pawn.FirstPersonCamera) or not valid(pawn.CameraHeadJoint) then return end
        if retired[p] then
            state=retired[p]; retired[p]=nil
            state.timer=LoopInGameThreadWithDelay(16,tick)
            log('Persistent fox: existing pawn recovered automatically.')
        else
            local activated,errorText=pcall(enable)
            if not activated then failedPawn=p; disable('automatic activation rolled back'); log('ERROR (persistent activation): '..tostring(errorText)); return end
            log('Persistent fox: saved option applied automatically to '..p)
        end
    end)
    if not ok then
        log('ERROR (persistence supervisor): '..tostring(err))
        if candidate then failedPawn=candidate end
    end
end

local function toggleView()
    if not state then log("Inspection requires a Fox character in a loaded world.") return end
    local specialPawn=resolve(state.pawn)
    if state.special and state.special~='seat' and not (state.special=='emote' and valid(specialPawn) and specialPawn.EmoteShouldHideFP~=true) then log('Native special camera retained until normal play resumes.'); return end
    local ok, err = pcall(function()
        local controller, pawn = resolve(state.controller), resolve(state.pawn)
        assert(valid(controller) and valid(pawn), "Player expired")
        if state.rearView then
            state.rearView = false
            state.previewClip=nil
            updateFirstPerson(controller, pawn)
            controller:SetViewTargetWithBlend(pawn, 0, 0, 0, false)
            state.cameraHidingFox = false
        else
            state.rearView = true
            local visual = resolve(state.visual)
            if valid(visual) then visual:SetVisibility(true, false) end
            state.cameraHidingFox = nil
            updateRearCamera(controller, pawn)
            controller:SetViewTargetWithBlend(resolve(state.camera), 0, 0, 0, false)
        end
        log(state.rearView and "External inspection view enabled." or "Fox first-person view enabled.")
    end)
    if not ok then log("ERROR (view): " .. tostring(err)); disable("view change failed") end
end

local function previewAnimation(restOnly)
    if not state or not state.rearView then log('F3 animation previews require F7 inspection view.') return end
    if state.special then log('Leave the native seat/emote/sleep state before previewing clips.'); return end
    local ok, err=pcall(function()
        local pawn=resolve(state.pawn)
        assert(valid(pawn), 'Player expired')
        local velocity=pawn:GetVelocity()
        if math.sqrt(velocity.X^2+velocity.Y^2)>15 then log('Stop moving before previewing an animation.') return end
        local list=restOnly and Animation.restPreview or Animation.preview
        local index=restOnly and 'restPreviewIndex' or 'previewIndex'
        state[index]=((state[index] or 0)%#list)+1
        state.previewClip=list[state[index]]
        state.animation=nil -- Restart even when cycling back to the same non-looping clip.
        log('Inspection preview: '..state.previewClip..'; move or press F7 to return to gameplay states.')
    end)
    if not ok then log('ERROR (animation preview): '..tostring(err)); disable('preview failed') end
end

local function adjustCamera(setting, direction)
    if not state then log("Camera controls require a Fox character in a loaded world.") return end
    if state.special and state.special~='seat' then return end
    direction=direction or 1
    local ok, err = pcall(function()
        local controller, pawn = resolve(state.controller), resolve(state.pawn)
        assert(valid(controller) and valid(pawn), "Player expired")
        if not state.rearView then
            local look=rot(controller:GetControlRotation())
            look.Pitch=(look.Pitch+180)%360-180
            if setting=='orbit' then look.Yaw=(look.Yaw+15*direction)%360
            elseif setting=='tilt' then look.Pitch=math.max(-80,math.min(80,look.Pitch-10*direction))
            else look.Pitch=0 end
            controller:SetControlRotation(look)
            log(string.format('Native keyboard look: yaw %.1f, pitch %.1f; first person retained.',look.Yaw,look.Pitch))
            return
        end
        if setting == "orbit" then state.yawOffset = ((state.yawOffset or 0) + 45*direction) % 360
        elseif setting == "tilt" then
            state.pitchIndex = (((state.pitchIndex or 1)-1+direction) % #CAMERA_PITCHES) + 1
            state.pitchOffset = CAMERA_PITCHES[state.pitchIndex]
        elseif setting == "distance" then state.distanceIndex = ((state.distanceIndex or 1) % #CAMERA_DISTANCES) + 1 end
        updateCamera(controller, pawn)
        controller:SetViewTargetWithBlend(resolve(state.camera), 0, 0, 0, false)
        state.rearView = true
        log(string.format("Camera preset: orbit %d, tilt %d, distance %d cm.", state.yawOffset or 0,
            state.pitchOffset or 0, CAMERA_DISTANCES[state.distanceIndex or 1]))
    end)
    if not ok then log("ERROR (camera preset): " .. tostring(err)); disable("camera preset failed") end
end

local function adjustEyeHeight()
    if not state then return end
    local ok, err = pcall(function()
        state.eyeIndex = ((state.eyeIndex or 1) % #EYE_HEIGHTS) + 1
        choice.eye=EYE_HEIGHTS[state.eyeIndex]
        saveChoice()
        state.cameraCrouched = nil
        if not state.rearView and not state.special then updateFirstPerson(resolve(state.controller), resolve(state.pawn)) end
        log('Eye height preset: '..EYE_HEIGHTS[state.eyeIndex]..' cm (standing).')
    end)
    if not ok then log('ERROR (eye height): '..tostring(err)); disable('eye adjustment failed') end
end

local function capturePreview()
    if not state then log("Press F6 in a world before capturing a fox preview.") return end
    local ok, err = pcall(function()
        local controller, pawn = resolve(state.controller), resolve(state.pawn)
        assert(valid(controller) and valid(pawn), "Player expired")
        local library = resolve("/Script/Engine.Default__KismetSystemLibrary")
        library:ExecuteConsoleCommand(pawn, "HighResShot 1", controller)
        log("Screenshot requested in AbioticFactor/Saved/Screenshots/Windows.")
    end)
    if not ok then log("ERROR (screenshot): " .. tostring(err)) end
end

local function schedulePreview()
    log('F4 diagnostic capture is temporarily disabled after a UE4SS capture/respawn probe crash. Use Steam F12.')
end

local function fitMouthGrip()
    -- Bounded, standalone developer fitting aid. Changes only this session's
    -- cosmetic row override; never moves the real weapon or writes preferences.
    if not state or not state.rearView or state.special then return end
    local pawn=resolve(state.pawn)
    if not valid(pawn) or not resolve('/Script/Engine.Default__KismetSystemLibrary'):IsStandalone(pawn) or not pawn.CurrentHeldItemExists then return end
    local row=pawn.CurrentItemRow:ToString()
    local presets={{8,5},{8,2},{5,5},{5,2},{2,5},{2,2}}
    state.gripTrials=state.gripTrials or {}
    local trial=state.gripTrials[row]
    if not trial then
        local grip=(Config.mouth_grips or {})[row] or Config.mouth_grip or {}
        trial={index=0,original=grip};state.gripTrials[row]=trial
    end
    trial.index=(trial.index+1)%(#presets+1)
    Config.mouth_grips=Config.mouth_grips or {}
    if trial.index==0 then Config.mouth_grips[row]=trial.original;log('Grip fitting: '..row..' original restored.')
    else
        local preset=presets[trial.index]
        Config.mouth_grips[row]={location={X=0,Y=preset[1],Z=preset[2]},rotation=trial.original.rotation or {Pitch=0,Yaw=90,Roll=0},scale=trial.original.scale}
        log(string.format('Grip fitting: %s trial %d; Y=%g Z=%g cm (session only).',row,trial.index,preset[1],preset[2]))
    end
end

local bindings={}
-- Kept available on upgraded configs that predate this setting. Inspection is
-- independent of species selection and never enables inventory grants.
if Config.inspection_controls~=false or Config.developer_controls==true then
bindings={{key = Key.F3, action = previewAnimation}, {key = Key.F7, action = toggleView},
    {key = Key.F3, modifiers={ModifierKey.SHIFT}, action=function() previewAnimation(true) end},
    {key = Key.F9, action = function() adjustCamera("orbit") end},
    {key = Key.F10, action = function() adjustCamera("tilt") end},
    {key = Key.F9, modifiers={ModifierKey.SHIFT}, action=function() adjustCamera('orbit',-1) end},
    {key = Key.F10, modifiers={ModifierKey.SHIFT}, action=function() adjustCamera('tilt',-1) end},
    {key = Key.F2, action = function() adjustCamera("distance") end}}
end
if Config.developer_controls==true then
    for _,binding in ipairs({{key=Key.F4,action=schedulePreview},{key=Key.F5,action=adjustEyeHeight},{key=Key.F6,action=toggleBody},
        {key=Key.F5,modifiers={ModifierKey.SHIFT},action=fitMouthGrip}}) do
        bindings[#bindings+1]=binding
    end
end
for _, binding in ipairs(bindings) do
    local action = binding.action
    local conflict
    if binding.modifiers then conflict=IsKeyBindRegistered(binding.key,binding.modifiers)
    else conflict=IsKeyBindRegistered(binding.key) end
    if conflict then
        log("ERROR: fox key conflict; one prototype binding could not be registered.")
    else
        if binding.modifiers then RegisterKeyBind(binding.key,binding.modifiers,function() ExecuteInGameThread(action) end)
        else RegisterKeyBind(binding.key, function() ExecuteInGameThread(action) end) end
    end
end
if Config.developer_controls==true then
    local audition=0
    RegisterKeyBind(Key.F7,{ModifierKey.SHIFT},function() ExecuteInGameThread(function()
        if not state or not state.voice then log('Voice audition needs an active fox in a loaded world.');return end
        local pawn=resolve(state.pawn)
        if not valid(pawn) then return end
        audition=audition%3+1
        attempt('voice audition',function()Voice.play(state.voice,pawn,({'idle','hurt','combat'})[audition],pawn:GetGameTimeSinceCreation(),true)end)
    end) end)
    require('diagnostics')
    require('test_items')
end

Customization.start({getChoice=function()return choice.enabled end,getAppearance=function()return Appearance.normalize(choice)end,select=selectSpecies,
    creationStarted=function()
        -- New characters start Human, even after using Fox in another world.
        choice=Profiles.copy(template);choice.enabled=false;choice.confirmed=false
        currentProfile=nil
        pendingCreation=nil
        failedPawn,candidate,stableCandidate=nil,nil,0
        if state then disable('Character creation: waiting for an explicit species choice') end
    end,
    getProfiles=function()
        local rows={{id='default',label='New character defaults'}}
        for _,row in ipairs(Profiles.list(profiles)) do rows[#rows+1]=row end
        return rows
    end,
    getSelectedProfile=function()return menuProfile or 'default'end,
    getProfileChoice=function(key)return key=='default' and Profiles.copy(template) or Profiles.get(profiles,key)end,
    mesh=MESH,idle=IDLE,scale=FOX_SCALE,load=loadAsset})

RegisterLoadMapPreHook(function()
    RemoteVisuals.clear()
    Network.clear()
    Customization.cleanup()
    disable('map transition; character choice retained')
    currentProfile=nil
    pendingCreation=nil
    for p,saved in pairs(retired) do cleanupState(saved,'map transition'); retired[p]=nil end
    candidate,stableCandidate,failedPawn=nil,0,nil
end)
Network.start({folder=scriptFolder,load=loadAsset,log=log,resize=resizeNetworkPawn,
    collisionFactor=function()
        local factor = Config.collision_scale
        if Config.small_collision and type(factor) == 'number' and factor >= 0.25 and factor <= 1 then
            return factor
        end
    end,
    choice=function()
    if currentProfile and currentProfile:sub(1,11)=='network-v1:'then
        local controller,pawn=localPlayer(true)
        if Network.identity(controller,pawn)==currentProfile then return Profiles.copy(choice)end
    end
end})
RemoteVisuals.start({load=loadAsset,log=log,states=Network.peerStates or Network.states})
if Config.developer_controls~=true and not IsKeyBindRegistered(Key.F8)then
    RegisterKeyBind(Key.F8,function()ExecuteInGameThread(function()
        local controller,pawn=localPlayer(true)
        local lines={'Feral Fox 0.16.4 network diagnostic',
            'Local gameplay pawn: '..tostring(valid(pawn)),
            'Profile bound: '..tostring(currentProfile~=nil),
            'Selected Fox: '..tostring(choice.enabled),
            'Local fox active: '..tostring(state~=nil),
            'Pending creation choice: '..tostring(pendingCreation~=nil)}
        if valid(controller)and valid(pawn)then
            lines[#lines+1]='Network scope available: '..tostring(Network.scope(controller)~=nil)
            lines[#lines+1]='Server profile available: '..tostring(Network.identity(controller,pawn)~=nil)
            lines[#lines+1]='Server accepted selection: '..tostring(Network.accepted(controller,choice))
            lines[#lines+1]='Applied pawn scale: '..tostring(actorScale(pawn))
        end
        local count=0;for _ in pairs(Network.states())do count=count+1 end
        lines[#lines+1]='Accepted player states visible: '..count
        local report=table.concat(lines,'\n')..'\n'
        log(report)
        local f=io.open(scriptFolder..'fox-status.txt','wb');if f then f:write(report);f:close()end
    end)end)
end
log('Loaded v0.16.4 public core candidate; selected species '..(choice.enabled and 'Fox' or 'Human')..'. Species: character creation / Fox tab in Customization. Inspection controls '..(Config.inspection_controls~=false and 'ON' or 'OFF')..'; developer controls '..(Config.developer_controls==true and 'ON' or 'OFF')..'.')
LoopInGameThreadWithDelay(500,supervise)
ExecuteInGameThread(function()
    local ok = attempt("startup API preflight", preflight)
    if ok then
        attempt("fox asset check", function()
            loadAsset(MESH)
            local count=0
            for _, clip in pairs(Animation.clips) do loadAsset(clip.path); count=count+1 end
            log('Fox assets ready: skeletal mesh plus '..count..' animation clips.')
        end)
    end
end)
