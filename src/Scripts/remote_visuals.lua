local findObject = require('object_lookup')
-- Server-accepted peer cosmetics. Engine attachment inherits native mesh
-- smoothing; player discovery is slower than animation/equipment updates.
local M={}
local Appearance=require('appearance')
local Animation=require('animation_state')
local Emotes=require('emotes')
local Equipment=require('equipment')
local Config=require('config')
local records,wanted,parts,failures={},{},{},{}
local options,frame,lastError,lastMembership=nil,0,nil,nil
local function valid(o)local ok,v=pcall(function()return o:IsValid()end);return ok and v==true end
local function path(o)return o:GetFullName():gsub('^%S+ ','')end
local function optional(fn)local ok,v=pcall(fn);if ok then return v end end
local function resolve(id)if not id then return end;local o=findObject(id);if valid(o)then return o end end
local function vec(v)return {X=v.X,Y=v.Y,Z=v.Z}end
local function rot(v)return {Pitch=v.Pitch,Yaw=v.Yaw,Roll=v.Roll}end
local function signature(v)return v.coat..':'..v.eyes..':'..v.paws end
local function positive(v)return type(v)=='number'and v==v and v>0 and v<math.huge end
local function changed(a,b)return not a or math.abs(a.X-b.X)+math.abs(a.Y-b.Y)+math.abs(a.Z-b.Z)>.0001 end
local function remove(id)
 local s=records[id];if not s then return end
 local p=resolve(id)
 pcall(Equipment.cleanup,s.equipment,p)
 for component,flags in pairs(s.hidden)do
  local c=resolve(component)
  if valid(c)then pcall(function()c:SetVisibility(flags.visible,false);c:SetHiddenInGame(flags.hidden,false);c.VisibilityBasedAnimTickOption=flags.tick end)end
 end
 local fox=resolve(s.visual);if valid(fox)then pcall(function()fox:K2_DestroyComponent(p)end)end
 records[id]=nil
end
local function capture(s,c,primary)
 local id=path(c)
 if id~=s.visual and (primary or(not id:find('.NODE_Add',1,true)and not c:GetFullName():match('^MaterialSwapSkeletalMeshComponent ')))and not s.hidden[id]then
  s.hidden[id]={visible=c.bVisible,hidden=c.bHiddenInGame,tick=c.VisibilityBasedAnimTickOption}
 end
end
local function create(p)
 local identity={Rotation={X=0,Y=0,Z=0,W=1},Translation={X=0,Y=0,Z=0},Scale3D={X=1,Y=1,Z=1}}
 local fox=p:AddComponentByClass(options.load('/Script/Engine.SkeletalMeshComponent'),false,identity,false)
 assert(valid(fox),'Could not create peer fox visual')
 local s={visual=path(fox),hidden={},equipment={},memory={},montages={},emoteMemory={},view={rearView=true},ticks=0}
 records[path(p)]=s
 capture(s,p.Mesh,true)
 for _,id in ipairs(parts[path(p)]or{})do local c=resolve(id);if valid(c)then capture(s,c)end end
 fox:SetIsReplicated(false);fox:SetCollisionEnabled(0);fox:SetGenerateOverlapEvents(false)
 fox:SetOwnerNoSee(false);fox:SetOnlyOwnerSee(false);fox.VisibilityBasedAnimTickOption=0
 fox:SetSkeletalMeshAsset(options.load(Appearance.mesh));fox:SetHiddenInGame(false,false);fox:SetVisibility(true,false)
 options.log('Peer fox visual created.')
 return s,fox
end
local function bind(p,s,fox,forceBase)
 local native=p.Mesh;local mesh=path(native)
 if mesh~=s.mesh then
  capture(s,native,true);s.mesh=mesh;s.position=nil;s.scale=nil;s.rotation=nil
  forceBase=true
 end
 if forceBase or s.ticks%5==0 then
  s.base=optional(function()return rot(p:GetBaseRotationOffsetRotator())end)
  -- Unusual/non-yaw mesh bases retain the previous root-relative fallback.
  s.smooth=s.base and math.abs(s.base.Pitch)<.01 and math.abs(s.base.Roll)<.01
 end
 local parent=s.smooth and native or p.RootComponent
 if valid(parent)and s.parent~=path(parent)then
  assert(fox:K2_AttachToComponent(parent,FName('None'),0,0,0,false),'Peer mesh attachment rejected')
  s.parent=path(parent)
 elseif not valid(parent)and s.parent then error('Peer fallback root unavailable')
 end
 local scale=s.smooth and native:K2_GetComponentScale()or p:GetActorScale3D()
 assert(positive(scale.X)and positive(scale.Y)and positive(scale.Z),'Invalid peer scale')
 local size={X=.8/scale.X,Y=.8/scale.Y,Z=.8/scale.Z}
 if changed(s.scale,size)then fox:SetRelativeScale3D(size);s.scale=size end
 local position=s.smooth and {X=0,Y=0,Z=0}or vec(native.RelativeLocation)
 if changed(s.position,position)then fox:K2_SetRelativeLocation(position,false,{},true);s.position=position end
end
local function update(p,choice)
 local id=path(p);local s=records[id];local fox=s and resolve(s.visual)
 if not s or not valid(fox)then if s then remove(id)end;s,fox=create(p)end
 if s.look~=signature(choice)then Appearance.apply(fox,choice,options.load);s.look=signature(choice)end
 local now=p:GetGameTimeSinceCreation();local velocity=p:GetVelocity()
 local speed=math.sqrt(velocity.X^2+velocity.Y^2)
 local emote=Emotes.active(p)
 local mode=p.IsDead==true and 'dead'or p.IsSleeping==true and 'sleep'or p.IsSittingInSeat==true and 'seat'or emote and 'emote'or nil
 bind(p,s,fox,mode~=s.mode)
 if mode~=s.mode then
  s.memory,s.montages,s.emoteMemory={},{},{};s.view.nativeAction=nil;s.action=nil;s.actionToken=nil;s.mode=mode
 end
 local key,rate,token
 local r=s.smooth and {Pitch=0,Yaw=0,Roll=0}or rot(p.Mesh.RelativeRotation)
 if mode=='dead'then key,rate='death',1
 elseif mode=='sleep'then key,rate='sleep',1
 elseif mode=='seat'or mode=='emote'then key,rate,token=Emotes.select(p,mode,now,s.emoteMemory)
 else
  r={Pitch=0,Yaw=-90-(s.smooth and s.base.Yaw or 0),Roll=0}
  s.action,s.actionToken=nil,nil
  for component in pairs(s.hidden)do
   local c=resolve(component);local instance=valid(c)and c:GetAnimInstance()
   local montage=valid(instance)and instance:GetCurrentActiveMontage()
   if valid(montage)then
    local action,serial=Animation.observeMontage(s.montages,component,path(montage),instance:Montage_GetPosition(montage),instance:Montage_IsPlaying(montage),now)
    if action then s.action,s.actionToken=action,serial end
   else s.montages[component]=nil end
  end
  local movement=p.CharacterMovement
  key,rate=Animation.select({time=now,speed=speed,verticalSpeed=velocity.Z,falling=movement.MovementMode==3,
   swimming=movement.MovementMode==4,crouched=p.bIsCrouched==true,action=s.action},s.memory)
  token=s.actionToken;s.view.nativeAction=s.action
 end
 if key=='sit'or Animation.clips[key].seated then r.Yaw=r.Yaw-90 end
 local rotation={X=r.Pitch,Y=r.Yaw,Z=r.Roll}
 if changed(s.rotation,rotation)then fox:K2_SetRelativeRotation(r,false,{},true);s.rotation=rotation end
 if key~=s.animation or token~=s.token then
  local clip=Animation.clips[key];fox:PlayAnimation(options.load(clip.path),clip.loop);s.animation,s.token=key,token
 end
 if rate~=s.rate then fox:SetPlayRate(rate or 1);s.rate=rate end
 for component in pairs(s.hidden)do
  local c=resolve(component)
  if valid(c)then
   if c.bVisible then c:SetVisibility(false,false)end
   if not c.bHiddenInGame then c:SetHiddenInGame(true,false)end
   if c.VisibilityBasedAnimTickOption~=0 then c.VisibilityBasedAnimTickOption=0 end
  end
 end
 s.ticks=s.ticks+1
 if mode then Equipment.suspend(s.equipment,p)else Equipment.update(s.equipment,p,nil,fox,s.view,Config,s.ticks%4==0)end
end
local function discover(states)
 local own,nextWanted={},{ }
 for _,c in ipairs(FindAllOf('PlayerController')or{})do
  if valid(c)and c:IsLocalPlayerController()and valid(c.PlayerState)then own[path(c.PlayerState)]=true end
 end
 for _,p in ipairs(FindAllOf('Abiotic_PlayerCharacter_C')or{})do
  if valid(p)and valid(p.PlayerState)and not own[path(p.PlayerState)]and valid(p.Mesh)then
   local choice=states[path(p.PlayerState)]
   if choice and choice.enabled then nextWanted[path(p)]=path(p.PlayerState)end
  end
 end
 wanted=nextWanted;parts={}
 if next(wanted)then
  for id,s in pairs(records)do
   for c in pairs(s.hidden)do if not valid(resolve(c))then s.hidden[c]=nil;s.montages[c]=nil end end
  end
  for _,c in ipairs(FindAllOf('SkeletalMeshComponent')or{})do
   if valid(c)and valid(c:GetOwner())then
    local id=path(c:GetOwner());local s=records[id]
    if wanted[id]then
     local p=resolve(id);local fp,tp=p.CurrentFPItemMesh,p.TP_ItemInHand
     if(not valid(fp)or path(fp)~=path(c))and(not valid(tp)or path(tp)~=path(c))then
      parts[id]=parts[id]or{};parts[id][#parts[id]+1]=path(c)
      if s then capture(s,c)end
     end
    end
   end
  end
 end
end
local function tick()
 frame=frame+1
 local ok,err=pcall(function()
  local states=options.states();local ids={}
  for id,v in pairs(states)do if v.enabled then ids[#ids+1]=id end end
  if #ids==0 then M.clear();return end
  table.sort(ids);local membership=table.concat(ids,'\n')
  if frame%5==1 or membership~=lastMembership then discover(states);lastMembership=membership end
  for id in pairs(records)do if not wanted[id]then remove(id)end end
  for id,ps in pairs(wanted)do
   local p=resolve(id);local choice=states[ps]
   if not valid(p)or not valid(p.PlayerState)or path(p.PlayerState)~=ps or not valid(p.Mesh)or not choice or not choice.enabled then
    remove(id);wanted[id]=nil;failures[id]=nil
   else
    local now=optional(function()return p:GetGameTimeSinceCreation()end)or frame*.05
    local key=signature(choice)..'|'..path(p.Mesh);local failed=failures[id]
    if not failed or failed.key~=key or now<failed.time or now>=failed.retry then
     local good,why=pcall(update,p,choice)
     if good then failures[id]=nil else
      remove(id);failures[id]={key=key,time=now,retry=now+2}
      if not failed or failed.error~=tostring(why)then options.log('Peer fox update failed: '..tostring(why))end
      failures[id].error=tostring(why)
     end
    end
   end
  end
  for id in pairs(failures)do if not wanted[id]then failures[id]=nil end end
 end)
 if not ok then
  M.clear()
  if tostring(err)~=lastError then lastError=tostring(err);options.log('Peer renderer: '..tostring(err))end
 end
end
function M.clear()for id in pairs(records)do remove(id)end;wanted={};parts={};failures={};frame=0;lastMembership=nil end
function M.start(opts)options=opts;LoopInGameThreadWithDelay(50,tick)end
return M
