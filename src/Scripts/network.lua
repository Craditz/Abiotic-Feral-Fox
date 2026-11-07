local findObject = require('object_lookup')
-- Native owned-actor RPC transport. No chat/name/appearance-field piggybacking.
local stateClass = 'BP_FeralFoxNetworkStateV3'
local M = {
 protocol = 3,
 class = '/Game/FeralFox/' .. stateClass .. '.' .. stateClass .. '_C',
}
local stateClassName = stateClass .. '_C'
local Appearance=require('appearance')
local live,peers,options={},{},nil
local sent,accepted={},{}
local resizedPawns = {}
local scaleUnits = 1000000
local serverId,lastError
local function valid(o)local ok,v=pcall(function()return o:IsValid()end);return ok and v==true end
local function path(o)return o:GetFullName():gsub('^%S+ ','')end
local function optional(fn)local ok,v=pcall(fn);if ok then return v end end
local function text(v,limit)
 if type(v)~='string'then v=optional(function()return v:ToString()end)end
 if type(v)=='string'and #v>0 and #v<=(limit or 512)and not v:find('[%z\r\n]')then return v end
end
local function integer(v)return type(v)=='number'and v%1==0 end
function M.validate(v)
 if type(v)~='table'or type(v.enabled)~='boolean'or not integer(v.coat)or not integer(v.eyes)or not integer(v.paws)then return end
 local look=Appearance.normalize(v)
 if look.coat~=v.coat or look.eyes~=v.eyes or look.paws~=v.paws then return end
 look.enabled=v.enabled;return look
end
local function signature(v)return table.concat({v.enabled and 1 or 0,v.coat,v.eyes,v.paws},':')end
function M.states()return live end
function M.peerStates()return peers end
function M.scope(controller)
 if not valid(controller)or not valid(controller.PlayerState)then return end
 local ps=path(controller.PlayerState)
 for _,a in ipairs(optional(function()return FindAllOf(stateClassName)end)or{})do
  if valid(a)and a.Protocol==M.protocol and valid(a.SubjectPlayerState)and path(a.SubjectPlayerState)==ps and
   path(a:GetWorld())==path(controller:GetWorld())then
   local world=text(a.WorldIdentity)
   if world then return world,a end
  end
 end
end
function M.identity(controller,pawn)
 local scope,a=M.scope(controller);if not scope then return end
 -- These fields are authored by the host and replicate only to the owner.
 -- Native save/account properties on the client's PlayerState may be empty.
 local key=text(a.OwnerProfileIdentity,2048)
 if not key or key:sub(1,11)~='network-v1:'then return end
 return key,text(a.OwnerProfileLabel,1024)or('Network '..scope:sub(1,48)),scope
end
function M.context(controller,pawn)
 if not valid(controller)or not valid(controller.PlayerState)or not valid(pawn)then return end
 return path(controller.PlayerState)..'|'..path(pawn:GetWorld())
end
function M.accepted(controller,choice)
 if not valid(controller)or not valid(controller.PlayerState)then return false end
 local v=live[path(controller.PlayerState)]
 return v and signature(v)==signature(choice)or false
end
local function namespace()
 if serverId then return serverId end
 local filename=options.folder..'network-server-id.txt'
 local f=io.open(filename,'rb')
 if f then
  local v=f:read(129);f:close()
  local id=v and v:match('^fox_server_v1=([0-9a-f]+)\n$')
  assert(id and #id==32 and id~=string.rep('0',32),'Invalid network server identity; original preserved')
  serverId=id;return id
 end
 local library=findObject('/Script/Engine.Default__KismetGuidLibrary');assert(valid(library),'Native GUID library unavailable')
 local guid=library:NewGuid();local fields={}
 for _,key in ipairs({'A','B','C','D'})do fields[#fields+1]=string.format('%08x',guid[key]&0xffffffff)end
 local value=table.concat(fields)
 assert(#value==32 and value~=string.rep('0',32),'Native server GUID is invalid')
 local out=assert(io.open(filename,'wb'));local written,why=out:write('fox_server_v1='..value..'\n')
 local closed,closeError=out:close();assert(written and closed,why or closeError or 'Server identity write failed')
 local read=assert(io.open(filename,'rb'));assert(read:read('*a')=='fox_server_v1='..value..'\n');read:close()
 serverId=value;return value
end
local function closeScale(a, b)
 return math.abs(a - b) < 0.000002
end

local function uniformScale(pawn)
 local scale = pawn:GetActorScale3D()
 if scale.Z > 0 and scale.Z <= 10 and closeScale(scale.X, scale.Z) and closeScale(scale.Y, scale.Z) then
  return scale.Z
 end
end

local function packScale(scale)
 return math.floor(scale * scaleUnits + 0.5)
end

local function setScale(pawn, scale, authority, shrinking)
 local size = {X = scale, Y = scale, Z = scale}
 if authority then
  options.resize(pawn, size, shrinking)
  pawn:ForceNetUpdate()
 else
  -- The server owns the capsule center. Native movement replication and
  -- prediction correct its position after the replicated size changes.
  pawn:SetActorScale3D(size)
 end
end

local function restoreMissingPawns(active)
 for id, previous in pairs(resizedPawns) do
  if not active[id] then
   local restored, reason = pcall(function()
    local pawn = findObject(id)
    if not valid(pawn) or not valid(pawn.CapsuleComponent) then return end
    local current = uniformScale(pawn)
    if current and closeScale(current, previous.applied) then
     setScale(pawn, previous.base, previous.authority, false)
    end
   end)
   if restored then
    resizedPawns[id] = nil
   else
    options.log('Could not restore native collision: ' .. tostring(reason))
   end
  end
 end
end

local function publishCollision(actor, pawn, base, scale)
 local packedBase = base and packScale(base) or 0
 local packedScale = scale and packScale(scale) or 0
 local pawnChanged = packedScale > 0 and
  (not valid(actor.CollisionPawn) or path(actor.CollisionPawn) ~= path(pawn))
 if pawnChanged or actor.CollisionBaseScale ~= packedBase or actor.CollisionScale ~= packedScale then
  if pawnChanged then actor.CollisionPawn = pawn end
  actor.CollisionBaseScale = packedBase
  actor.CollisionScale = packedScale
  actor:ForceNetUpdate()
 end
end

local function serverCollision(actor, pawn, factor, active)
 if not factor or factor >= 1 or actor.AcceptedReady ~= true or actor.AcceptedEnabled ~= true or
    not valid(pawn) or not valid(pawn.CapsuleComponent) or pawn.ServerLevelLoaded ~= true or
    pawn.IsDead or pawn.RespawnInProgress == true or pawn.IsSleeping or pawn.IsSittingInSeat then
  publishCollision(actor)
  return
 end

 local id = path(pawn)
 local previous = resizedPawns[id]
 local movement = pawn.CharacterMovement
 -- Apply initially on a settled pawn, then retain its scale through jumps.
 if not previous and (not valid(movement) or (movement.MovementMode ~= 1 and movement.MovementMode ~= 4)) then
  publishCollision(actor)
  return
 end

 local current = uniformScale(pawn)
 if not current then
  publishCollision(actor)
  return
 end
 local base = previous and previous.base or current
 local target = packScale(base * factor) / scaleUnits
 if target <= 0 then return end
 resizedPawns[id] = {base = base, applied = target, authority = true}
 if not closeScale(current, target) then
  setScale(pawn, target, true, not previous)
 end
 active[id] = true
 publishCollision(actor, pawn, base, target)
end

local function clientCollision(actors, worldPath)
 local active = {}
 for _, actor in ipairs(actors) do
  if valid(actor) and actor.Protocol == M.protocol and actor.AcceptedReady == true and actor.AcceptedEnabled == true then
   local pawn = actor.CollisionPawn
   local scale, base = actor.CollisionScale, actor.CollisionBaseScale
   if valid(pawn) and valid(pawn.CapsuleComponent) and valid(actor.SubjectPlayerState) and valid(pawn.PlayerState) and
      path(pawn:GetWorld()) == worldPath and path(pawn.PlayerState) == path(actor.SubjectPlayerState) and
      integer(scale) and integer(base) and base <= 10 * scaleUnits and scale > 0 and scale < base and scale >= base * 0.249999 then
    local id = path(pawn)
    local target = scale / scaleUnits
    local current = uniformScale(pawn)
    if current then
     resizedPawns[id] = {base = base / scaleUnits, applied = target, authority = false}
     if not closeScale(current, target) then setScale(pawn, target, false, false) end
     active[id] = true
    end
   end
  end
 end
 restoreMissingPawns(active)
end

local function server(gs,actors,controllers)
 local world=text(gs.WorldSaveName);if not world then return end
 local scope=world..'@'..namespace()
 local byOwner={}
 for _,a in ipairs(actors)do
  local owner=a:GetOwner()
  if valid(owner)and valid(owner.PlayerState)and valid(a.SubjectPlayerState)and path(owner.PlayerState)==path(a.SubjectPlayerState)then
   local id=path(owner)
   if not byOwner[id]then byOwner[id]=a else a:K2_DestroyActor()end
  else a:K2_DestroyActor()end
 end
 local active, activeCollision = {}, {}
 local factor = options.collisionFactor()
 for _,c in ipairs(controllers)do
  if valid(c)and valid(c.PlayerState)and path(c:GetWorld())==path(gs:GetWorld())then
   local id=path(c);active[id]=true
   local a=byOwner[id]
   if not valid(a)then
    a=gs:GetWorld():SpawnActor(options.load(M.class),{X=0,Y=0,Z=0},{Pitch=0,Yaw=0,Roll=0})
    assert(valid(a),'Could not create fox network state')
    a:SetOwner(c);a.SubjectPlayerState=c.PlayerState;a.WorldIdentity=scope;a.Protocol=M.protocol
    a:ForceNetUpdate();actors[#actors+1]=a
    options.log('Network state created for a connected player.')
   end
   if text(a.WorldIdentity)~=scope then a.WorldIdentity=scope;a:ForceNetUpdate()end
   local account,id=text(c.PlayerState.UniquePlayerID),text(c.PlayerState.PlayerSaveID)
   if account and id then
    local identity='network-v1:'..#scope..':'..scope..':'..#account..':'..account..':'..#id..':'..id
    if text(a.OwnerProfileIdentity,2048)~=identity then
     a.OwnerProfileIdentity=identity;a.OwnerProfileLabel='Network '..world..' / '..account:sub(-6)
     a:ForceNetUpdate()
    end
   end
   local revision=a.RawRevision
   if integer(revision)and revision>0 and revision<=1000000000 and (accepted[path(a)]or 0)<revision then
    accepted[path(a)]=revision
    -- Ownership is fixed by the server-created actor; clients cannot select
    -- a subject player or change the durable world namespace through this RPC.
    local choice=M.validate({enabled=a.RawEnabled,coat=a.RawCoat,eyes=a.RawEyes,paws=a.RawPaws})
    if a.RawProtocol==M.protocol and choice then
     a.AcceptedEnabled=choice.enabled;a.AcceptedCoat=choice.coat;a.AcceptedEyes=choice.eyes;a.AcceptedPaws=choice.paws
     a.AcceptedRevision=revision;a.AcceptedReady=true;a:ForceNetUpdate()
     options.log('Network choice accepted: '..(choice.enabled and 'Fox' or 'Human')..'.')
    else options.log('Rejected incompatible or invalid fox network request.')end
   end
   serverCollision(a, c.Pawn, factor, activeCollision)
  end
 end
 restoreMissingPawns(activeCollision)
 for owner,a in pairs(byOwner)do if not active[owner]then a:K2_DestroyActor()end end
end
local function tick()
 live,peers={},{}
 local ok,err=pcall(function()
  local library=findObject('/Script/Engine.Default__KismetSystemLibrary')
  local gs
  for _,candidate in ipairs(FindAllOf('Abiotic_Survival_GameState_C')or{})do
   if valid(candidate)and not path(candidate:GetWorld()):lower():find('menu',1,true)then gs=candidate;break end
  end
  if not valid(gs) or not valid(library) then return end
  if library:IsStandalone(gs) then M.clear();return end
  local actors,activeActors={},{}
  for _,a in ipairs(optional(function()return FindAllOf(stateClassName)end)or{})do
   if valid(a)and path(a:GetWorld())==path(gs:GetWorld())then actors[#actors+1]=a;activeActors[path(a)]=true end
  end
  for id in pairs(sent)do if not activeActors[id]then sent[id]=nil end end
  for id in pairs(accepted)do if not activeActors[id]then accepted[id]=nil end end
  local controllers=FindAllOf('PlayerController')or{}
  if gs:HasAuthority() then
   server(gs, actors, controllers)
  else
   clientCollision(actors, path(gs:GetWorld()))
  end
  local snapshots,others,own={},{},{}
  for _,c in ipairs(controllers)do
   if valid(c)and c:IsLocalPlayerController()and valid(c.PlayerState)then own[path(c.PlayerState)]=true end
  end
  for _,a in ipairs(actors)do
   if valid(a)and valid(a.SubjectPlayerState)and a.Protocol==M.protocol and a.AcceptedReady==true then
    local value=M.validate({enabled=a.AcceptedEnabled,coat=a.AcceptedCoat,eyes=a.AcceptedEyes,paws=a.AcceptedPaws})
    if value then
     local id=path(a.SubjectPlayerState);snapshots[id]=value
     if not own[id]then others[id]=value end
    end
   end
  end
  live,peers=snapshots,others
  local choice=options.choice()
  if choice then
   for _,c in ipairs(controllers)do if valid(c)and c:IsLocalPlayerController()and valid(c.PlayerState)then
    for _,a in ipairs(actors)do if valid(a)and valid(a.SubjectPlayerState)and path(a.SubjectPlayerState)==path(c.PlayerState)and a.Protocol==M.protocol and text(a.WorldIdentity)then
     local value=M.validate(choice);assert(value,'Invalid local fox network choice')
     local id,key=path(a),signature(value);local now=gs:GetGameTimeSinceCreation();local previous=sent[id]
     local matches=snapshots[path(c.PlayerState)]and signature(snapshots[path(c.PlayerState)])==key
     if not previous or previous.key~=key or (not matches and (now<previous.time or now-previous.time>=2))then
      local revision=math.max(previous and previous.revision or 0,a.AcceptedRevision or 0)+1
      a:SubmitFoxChoice(M.protocol,value.enabled,value.coat,value.eyes,value.paws,revision)
      sent[id]={key=key,revision=revision,time=now}
     end
    end end
   end end
  end
 end)
 if ok then lastError=nil
 elseif tostring(err)~=lastError then lastError=tostring(err);options.log('Network update failed: '..tostring(err))end
end
function M.clear()
 restoreMissingPawns({})
 resizedPawns = {}
 live, peers, sent, accepted, lastError = {}, {}, {}, {}, nil
end
function M.start(opts)
 options=opts;LoopInGameThreadWithDelay(200,tick)
end
return M
