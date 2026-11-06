-- Menu-only preview. Never creates or moves a gameplay actor.
local Appearance=require('appearance')
local M={}
local function valid(o)
    if not o then return false end
    local ok,value=pcall(function()return o:IsValid()end)
    return ok and value==true
end
local function path(o) return valid(o) and o:GetFullName():match('^[^ ]+ (.+)$') end
local function resolve(p) return p and StaticFindObject(p) end
local function vector(v) return {X=v.X,Y=v.Y,Z=v.Z} end
local function rotation(v) return {Pitch=v.Pitch,Yaw=v.Yaw,Roll=v.Roll} end
function M.clear(state)
    local camera=resolve(state.previewCamera)
    local controller=resolve(state.previewController)
    local previous=resolve(state.previewPreviousTarget)
    if valid(camera) and valid(controller) and valid(previous) and path(controller:GetViewTarget())==path(camera) then
        controller:SetViewTargetWithBlend(previous,0,0,0,false)
    end
    if valid(camera) then camera:K2_DestroyActor() end
    state.previewCamera=nil;state.previewController=nil;state.previewPreviousTarget=nil
    local component=resolve(state.preview)
    if valid(component) then component:K2_DestroyComponent(component:GetOwner()) end
    state.preview=nil;state.previewLook=nil;state.previewYawOffset=nil
    for p,flags in pairs(state.previewHidden or {}) do
        local native=resolve(p)
        if valid(native) then
            native:SetVisibility(flags.visible,false)
            native:SetHiddenInGame(flags.hidden,false)
        end
    end
    state.previewHidden=nil
end
function M.update(state,widget,enabled,look,options)
    if not enabled then M.clear(state);return end
    local component=resolve(state.preview)
    if not valid(component) then
        -- GetCharacter is the native Customization Blueprint function. Refuse
        -- every actor outside the main-menu map, including possessed players.
        -- Blueprint output pins are explicit out parameters in UE4SS.
        local result={}
        widget:GetCharacter(result)
        local character=result.Character
        if not valid(character) or not path(character):find('/Game/Maps/MainMenu.',1,true) then return end
        local native=character.Mesh
        if not valid(native) then return end
        local identity={Rotation={X=0,Y=0,Z=0,W=1},Translation={X=0,Y=0,Z=0},Scale3D={X=1,Y=1,Z=1}}
        local mesh=options.load(options.mesh)
        local idle=options.load(options.idle)
        component=character:AddComponentByClass(StaticFindObject('/Script/Engine.SkeletalMeshComponent'),false,identity,false)
        assert(valid(component),'Menu preview component creation failed')
        state.preview=path(component)
        state.previewNativeMesh=path(native)
        state.previewYawOffset=nil
        component:SetIsReplicated(false)
        component:SetCollisionEnabled(0)
        component:SetGenerateOverlapEvents(false)
        component:SetSkeletalMeshAsset(mesh)
        component:K2_SetRelativeLocation(vector(native.RelativeLocation),false,{},true)
        component:K2_SetRelativeRotation(rotation(native.RelativeRotation),false,{},true)
        component:SetRelativeScale3D({X=options.scale,Y=options.scale,Z=options.scale})
        component:PlayAnimation(idle,true)
        component:SetVisibility(true,false)
        component:SetHiddenInGame(false,false)
        state.previewHidden={}
        for _,kind in ipairs({'SkeletalMeshComponent','StaticMeshComponent'}) do
        for _,other in ipairs(FindAllOf(kind) or {}) do
            if valid(other) and path(other)~=state.preview and path(other:GetOwner())==path(character) then
                state.previewHidden[path(other)]={visible=other.bVisible,hidden=other.bHiddenInGame}
                other:SetVisibility(false,false)
                other:SetHiddenInGame(true,false)
            end
        end
        end
    end
    local key=look.coat..':'..look.eyes..':'..look.paws
    local native=resolve(state.previewNativeMesh)
    if valid(native) then
        local facing=rotation(native.RelativeRotation)
        facing.Yaw=facing.Yaw+(state.previewYawOffset or 0)
        component:K2_SetRelativeRotation(facing,false,{},true)
    end
    if key~=state.previewLook then Appearance.apply(component,look,options.load);state.previewLook=key end
    local camera=resolve(state.previewCamera)
    if not valid(camera) then
        for _,controller in ipairs(FindAllOf('PlayerController') or {}) do
            if valid(controller) and controller:IsLocalPlayerController() and
                path(controller:GetWorld())==path(component:GetWorld()) then
                local previous=controller:GetViewTarget()
                if valid(previous) then
                    local floor=component:K2_GetComponentLocation()
                    local origin=previous:K2_GetActorLocation()
                    local dx,dy=origin.X-floor.X,origin.Y-floor.Y
                    local length=math.sqrt(dx*dx+dy*dy)
                    if length<1 then dx,dy,length=1,0,1 end
                    local location={X=floor.X+dx/length*230,Y=floor.Y+dy/length*230,Z=floor.Z+100}
                    local target={X=floor.X,Y=floor.Y,Z=floor.Z+40}
                    local mathLibrary=StaticFindObject('/Script/Engine.Default__KismetMathLibrary')
                    local viewRotation=mathLibrary:FindLookAtRotation(location,target)
                    camera=component:GetWorld():SpawnActor(StaticFindObject('/Script/Engine.CameraActor'),location,{Pitch=0,Yaw=0,Roll=0})
                    assert(valid(camera),'Could not create fox menu camera')
                    -- Apply a reflected Rotator setter after spawning. Do not
                    -- depend on the Lua SpawnActor helper's rotation conversion.
                    camera:K2_SetActorLocationAndRotation(location,rotation(viewRotation),false,{},true)
                    local observed=camera:K2_GetActorRotation()
                    print(string.format('[FeralFoxUI] Preview camera Z %.1f -> target Z %.1f; actual pitch %.1f, yaw %.1f.\n',
                        location.Z,target.Z,observed.Pitch,observed.Yaw))
                    state.previewCamera=path(camera);state.previewController=path(controller);state.previewPreviousTarget=path(previous)
                    camera:SetActorEnableCollision(false)
                    camera:SetReplicates(false)
                    camera.CameraComponent:SetFieldOfView(60)
                    controller:SetViewTargetWithBlend(camera,0,0,0,false)
                    break
                end
            end
        end
    end
    if valid(camera) and valid(native) and state.previewYawOffset==nil then
        -- Calibrate only the fox component against the menu camera. A front
        -- three-quarter view exposes the face and coat; native arrows retain
        -- their usual rotation because this becomes a constant local offset.
        local origin=component:K2_GetComponentLocation()
        local head=component:GetSocketLocation(FName('Head'))
        local dx,dy=head.X-origin.X,head.Y-origin.Y
        if dx*dx+dy*dy>1 then
            local library=StaticFindObject('/Script/Engine.Default__KismetMathLibrary')
            local current=library:FindLookAtRotation(origin,head)
            local view=camera:K2_GetActorRotation()
            state.previewYawOffset=(view.Yaw+135-current.Yaw+180)%360-180
            local facing=rotation(native.RelativeRotation)
            facing.Yaw=facing.Yaw+state.previewYawOffset
            component:K2_SetRelativeRotation(facing,false,{},true)
        end
    end
end
return M
