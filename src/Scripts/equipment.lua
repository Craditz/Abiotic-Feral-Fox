local findObject = require('object_lookup')
-- Cosmetic mouth-held item proxies. Native item actors and gameplay stay intact.
local M={}
local function outputTrace(label)
    if require('config').trace_native_outputs==true then print('[FeralFoxNativeOutput] '..label..'\n') end
    return {}
end
M.required={
    'StaticMeshComponent:SetStaticMesh','SceneComponent:GetSocketLocation',
    'SceneComponent:K2_GetComponentRotation','SceneComponent:K2_SetWorldLocationAndRotation',
    'SceneComponent:SetWorldScale3D','PrimitiveComponent:GetNumMaterials',
    'PrimitiveComponent:GetMaterial','PrimitiveComponent:SetMaterial',
    'SkinnedMeshComponent:SetLeaderPoseComponent',
    'SceneComponent:K2_AttachToComponent','SceneComponent:K2_DetachFromComponent',
    'SceneComponent:GetSocketTransform'
}
local function valid(o) local ok,v=pcall(function() return o:IsValid() end); return ok and v==true end
local function path(o) return (o:GetFullName():gsub('^%S+ ','')) end
local function resolve(p) if not p then return nil end; local o=findObject(p); if valid(o) then return o end end
local function vec(v) return {X=v.X,Y=v.Y,Z=v.Z} end
local function log(s) print('[FeralFoxEquipment] '..s..'\n') end
local function optional(f) local ok,v=pcall(f); if ok then return v end end
local function meshAsset(component,kind)
    if kind=='static' then return component.StaticMesh end
    return component:GetSkeletalMeshAsset()
end

local function clearItem(g,pawn)
    local active={}
    local currentActor
    if valid(pawn) and pawn.CurrentHeldItemExists then
        for _,key in ipairs({'CurrentFPItemMesh','TP_ItemInHand'}) do
            local c=pawn[key]
            if valid(c) then active[path(c)]=true end
        end
        local item=pawn.ItemInHand_BP
        if valid(item) then currentActor=path(item) end
    end
    for p,flags in pairs(g.originals or {}) do
        local c=resolve(p)
        if valid(c) then
            -- Native render meshes can be pooled between hotbar selections.
            -- Restoring an inactive mesh would leave a ghost of the old item.
            local owner=c:GetOwner()
            local ownedByCurrent=valid(owner) and currentActor and path(owner)==currentActor
            if active[p] or ownedByCurrent or c.bHiddenInGame then pcall(function() c:SetVisibility(flags.visible,false) end) end
        end
    end
    local proxy=resolve(g.proxy)
    if valid(proxy) then
        proxy:SetVisibility(false,false)
        if valid(pawn) then proxy:K2_DestroyComponent(pawn) end
    end
    g.actor,g.source,g.asset,g.proxy,g.kind,g.originals,g.attached,g.rearView,g.row=nil,nil,nil,nil,nil,nil,nil,nil,nil
end

function M.cleanup(g,pawn)
    clearItem(g,pawn)
    g.observed,g.observedSince=nil,nil
    for p,flags in pairs(g.worn or {}) do
        local c=resolve(p)
        if valid(c) then pcall(function() c:SetVisibility(flags.visible,false) end) end
    end
    g.worn=nil
end

local function hideWorn(g,pawn)
    g.worn=g.worn or {}
    for _,key in ipairs({'IDCardMesh','FPSuitWindow','FannyPackMesh','BackpackMesh'}) do
        local c=optional(function() return pawn[key] end)
        if valid(c) then
            local p=path(c)
            if not g.worn[p] then g.worn[p]={visible=c.bVisible} end
            if c.bVisible then c:SetVisibility(false,false) end
        end
    end
end

function M.suspend(g,pawn)
    hideWorn(g,pawn)
    g.originals=g.originals or {}
    for _,key in ipairs({'CurrentFPItemMesh','TP_ItemInHand'}) do
        local c=pawn[key]
        if valid(c) then
            local p=path(c)
            if not g.originals[p] or c.bVisible then g.originals[p]={visible=c.bVisible} end
            c:SetVisibility(false,false)
        end
    end
    local proxy=resolve(g.proxy)
    if valid(proxy) then proxy:SetVisibility(false,false) end
end

local function refresh(g,pawn,item,rearView,row)
    local actorPath=valid(item) and path(item) or path(pawn)
    local candidates={}
    local seen={}
    local function add(component,priority)
            if valid(component) and not seen[path(component)] then
                    seen[path(component)]=true
                    local kind
                    if component:IsA('/Script/Engine.StaticMeshComponent') then kind='static'
                    elseif component:IsA('/Script/Engine.SkeletalMeshComponent') then kind='skeletal' end
                    if not kind then return end
                    local asset=meshAsset(component,kind)
                    if valid(asset) then
                        local p=path(component)
                        local saved=g.originals and g.originals[p]
                        local visible=saved and saved.visible or (not saved and component.bVisible)
                        local score=priority+((visible and not component.bHiddenInGame) and 20 or 0)
                        if component.bOnlyOwnerSee then score=score+10 end
                        if component.bOwnerNoSee then score=score-30 end
                        if kind=='skeletal' then score=score+2 end
                        candidates[#candidates+1]={component=component,asset=asset,kind=kind,score=score,p=p}
                    end
            end
    end
    -- The native player exposes its render meshes directly. The gameplay actor's
    -- World_StaticMesh is intentionally hidden and is not its first-person view.
    add(pawn.CurrentFPItemMesh,rearView and 0 or 100)
    add(pawn.TP_ItemInHand,rearView and 100 or 0)
    if #candidates==0 and valid(item) then
        add(optional(function() return item.World_StaticMesh end),-100)
        add(optional(function() return item.World_SkeletalMesh end),-90)
    end
    table.sort(candidates,function(a,b) if a.score==b.score then return a.p<b.p end; return a.score>b.score end)
    local chosen=candidates[1]
    if not chosen then clearItem(g,pawn); return end
    if g.actor~=actorPath or g.source~=chosen.p or g.asset~=path(chosen.asset) or g.rearView~=rearView or g.row~=row then
        clearItem(g,pawn)
        g.actor,g.source,g.asset,g.kind,g.originals=actorPath,chosen.p,path(chosen.asset),chosen.kind,{}
        g.rearView=rearView
        g.row=row
        -- Capture every native mesh before hiding it, including the unused view.
        for _,entry in ipairs(candidates) do g.originals[entry.p]={visible=entry.component.bVisible} end
        local class=resolve(chosen.kind=='static' and '/Script/Engine.StaticMeshComponent' or '/Script/Engine.SkeletalMeshComponent')
        assert(valid(class),'Mouth proxy component class unavailable')
        local transform={Rotation={X=0,Y=0,Z=0,W=1},Translation={X=0,Y=0,Z=0},Scale3D={X=1,Y=1,Z=1}}
        local proxy=pawn:AddComponentByClass(class,false,transform,false)
        assert(valid(proxy),'Could not create mouth item visual')
        g.proxy=path(proxy)
        -- Do not render a newly assigned mesh at the component's default origin.
        -- update positions, attaches and scales it before making it visible.
        proxy:SetVisibility(false,false)
        proxy:SetIsReplicated(false)
        proxy:SetCollisionEnabled(0)
        proxy:SetGenerateOverlapEvents(false)
        proxy:SetOwnerNoSee(false)
        proxy:SetOnlyOwnerSee(false)
        if chosen.kind=='static' then proxy:SetStaticMesh(chosen.asset)
        else
            proxy:SetSkeletalMeshAsset(chosen.asset)
            if not rearView then proxy:SetLeaderPoseComponent(chosen.component,true,false) end
            proxy.VisibilityBasedAnimTickOption=0
        end
        local assigned=meshAsset(proxy,chosen.kind)
        assert(valid(assigned) and path(assigned)==path(chosen.asset),'Mouth item mesh assignment failed')
        for index=0,math.min(chosen.component:GetNumMaterials(),32)-1 do
            local material=chosen.component:GetMaterial(index)
            if valid(material) then proxy:SetMaterial(index,material) end
        end
        proxy:SetHiddenInGame(false,false)
        log('Mouth visual: '..g.asset..'; row='..row..'; native item retained: '..actorPath)
    else
        for _,entry in ipairs(candidates) do
            if not g.originals[entry.p] then g.originals[entry.p]={visible=entry.component.bVisible} end
        end
    end
end

local function update(g,pawn,controller,fox,view,config,maintenance,identity)
    local item=pawn.ItemInHand_BP
    local row=pawn.CurrentItemRow:ToString()
    if config.mouth_items==false or pawn.CurrentHeldItemExists==false then
        if g.proxy or g.originals then clearItem(g,pawn) end
        g.observed,g.observedSince=nil,nil
        return
    end
    -- Native equip updates actor, meshes, row and item data across several
    -- frames. A stable snapshot avoids applying yesterday's grip to today's mesh.
    local delay=config.mouth_swap_delay_ms
    if type(delay)~='number' or delay<0 or delay>250 then delay=80 end
    local now=pawn:GetGameTimeSinceCreation()
    if g.observed~=identity or not g.observedSince or now<g.observedSince then
        if delay>0 then clearItem(g,pawn) end
        g.observed,g.observedSince=identity,now
    end
    if (now-g.observedSince)*1000+0.001<delay then
        M.suspend(g,pawn)
        return
    end
    local source=resolve(g.source)
    local actorPath=valid(item) and path(item) or path(pawn)
    local expected=view.rearView and pawn.TP_ItemInHand or pawn.CurrentFPItemMesh
    local expectedAsset=valid(expected) and optional(function()
        return meshAsset(expected,expected:IsA('/Script/Engine.StaticMeshComponent') and 'static' or 'skeletal')
    end)
    if not valid(source) or g.actor~=actorPath or g.row~=row or (valid(expectedAsset) and g.source~=path(expected)) or g.rearView~=view.rearView or not g.proxy then refresh(g,pawn,item,view.rearView,row) end
    source=resolve(g.source)
    local proxy=resolve(g.proxy)
    if not valid(source) or not valid(proxy) then return end
    local asset=meshAsset(source,g.kind)
    if not valid(asset) or path(asset)~=g.asset then
        refresh(g,pawn,item,view.rearView,row)
        source,proxy=resolve(g.source),resolve(g.proxy)
        if not valid(source) or not valid(proxy) then return end
    end
    if maintenance then
        -- The game can change materials on a pooled mesh without replacing it.
        for index=0,math.min(source:GetNumMaterials(),32)-1 do
            local material=source:GetMaterial(index)
            if valid(material) then proxy:SetMaterial(index,material) end
        end
    end
    for p in pairs(g.originals or {}) do
        local component=resolve(p)
        if valid(component) and component.bVisible then
            g.originals[p].visible=true
            component:SetVisibility(false,false)
        end
    end
    local position
    if view.rearView then
        if not g.attached then
            assert(proxy:K2_AttachToComponent(fox,FName('Jaw'),0,0,1,false),'Jaw attachment rejected')
            g.attached=true
        end
        -- Reapply an absolute grip, including after native component reuse and
        -- parent-scale changes. Never inherit a previous item's transform.
        -- FBX units leave Jaw at ~80 world scale on the rendered 0.8-scale fox.
        local boneScale=fox:GetSocketTransform(FName('Jaw'),0).Scale3D
        assert(math.abs(boneScale.X)>0.0001 and math.abs(boneScale.Y)>0.0001 and math.abs(boneScale.Z)>0.0001,'Invalid Jaw scale')
        local grip=(config.mouth_grips or {})[row] or config.mouth_grip or {}
        local offset=grip.location or {X=0,Y=8,Z=5}
        proxy:K2_SetRelativeLocation({X=offset.X/boneScale.X,Y=offset.Y/boneScale.Y,Z=offset.Z/boneScale.Z},false,outputTrace('equipment.lua:235:K2_SetRelativeLocation'),true)
        proxy:K2_SetRelativeRotation(grip.rotation or {Pitch=0,Yaw=90,Roll=0},false,outputTrace('equipment.lua:236:K2_SetRelativeRotation'),true)
    else
        if g.attached then proxy:K2_DetachFromComponent(1,1,1,false); g.attached=nil end
        local camera=resolve(view.nativeCamera)
        assert(valid(camera),'Native camera unavailable for mouth viewmodel')
        position=vec(camera:K2_GetComponentLocation())
        local look=camera:K2_GetComponentRotation()
        local pitch,yaw=math.rad(look.Pitch),math.rad(look.Yaw)
        local cp,sp,cy,sy=math.cos(pitch),math.sin(pitch),math.cos(yaw),math.sin(yaw)
        local offset=config.mouth_first_person_cm or {X=24,Y=8,Z=-12}
        position.X=position.X+cp*cy*offset.X-sy*offset.Y-sp*cy*offset.Z
        position.Y=position.Y+cp*sy*offset.X+cy*offset.Y-sp*sy*offset.Z
        position.Z=position.Z+sp*offset.X+cp*offset.Z
    end
    if position then
        local rotation=source:K2_GetComponentRotation()
        proxy:K2_SetWorldLocationAndRotation(position,{Pitch=rotation.Pitch,Yaw=rotation.Yaw,Roll=rotation.Roll},false,outputTrace('equipment.lua:252:K2_SetWorldLocationAndRotation'),true)
    end
    local data=pawn.CurrentHeldItemData
    local size=optional(function() return view.rearView and data.Scale_TPHeldMesh or data.Scale_FirstPersonMesh end)
    if type(size)~='number' or size<=0 or size>10 then size=1 end
    local factor=config.mouth_item_scale or 1
    assert(type(factor)=='number' and factor>0 and factor<=4,'mouth_item_scale must be greater than zero and at most 4')
    if view.rearView then
        local grip=(config.mouth_grips or {})[row] or config.mouth_grip or {}
        local rowScale=grip.scale or 1
        assert(type(rowScale)=='number' and rowScale>0 and rowScale<=4,'Mouth grip scale must be greater than zero and at most 4')
        factor=factor*rowScale
    end
    size=size*factor
    proxy:SetWorldScale3D({X=size,Y=size,Z=size})
    local consuming=view.nativeAction=='eat' or view.nativeAction=='drink'
    proxy:SetVisibility(not (view.rearView and (view.cameraHidingFox or consuming)),false)
end

function M.update(g,pawn,controller,fox,view,config,maintenance)
    -- Worn gear stays hidden even when an unsupported item uses its native
    -- fallback. Restoring worn visibility belongs to full Fox cleanup only.
    local wornOK,wornError=pcall(hideWorn,g,pawn)
    if not wornOK and g.wornError~=tostring(wornError)then log('Worn visual update: '..tostring(wornError))end
    g.wornError=not wornOK and tostring(wornError)or nil
    -- An unsupported item should fall back to its native visual, not remove the fox.
    local key=optional(function()
        local row=pawn.CurrentItemRow
        local component=view.rearView and pawn.TP_ItemInHand or pawn.CurrentFPItemMesh
        local kind=valid(component) and component:IsA('/Script/Engine.StaticMeshComponent') and 'static' or 'skeletal'
        local asset=valid(component) and meshAsset(component,kind) or nil
        local item=pawn.ItemInHand_BP
        return table.concat({row and row:ToString() or '',valid(item) and path(item) or '',
            valid(component) and path(component) or '',valid(asset) and path(asset) or '',tostring(view.rearView)},'|')
    end) or ''
    local now=optional(function()return pawn:GetGameTimeSinceCreation()end)or 0
    if g.failedKey==key and g.retryAt and now>=(g.failureTime or now)and now<g.retryAt then return end
    if g.failedKey and g.failedKey~=key then g.failedKey=nil end
    local ok,err=pcall(update,g,pawn,controller,fox,view,config,maintenance,key)
    if not ok then
        pcall(clearItem,g,pawn)
        g.observed,g.observedSince=nil,nil
        g.failedKey=key
        g.failureTime,g.retryAt=now,now+2
        if g.lastError~=tostring(err) then log('Mouth visual fallback: '..tostring(err)); g.lastError=tostring(err) end
    else g.lastError,g.failedKey,g.failureTime,g.retryAt=nil,nil,nil,nil end
end
return M
