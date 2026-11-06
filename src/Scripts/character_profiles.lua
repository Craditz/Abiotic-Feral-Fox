-- Installation-local records keyed by the native standalone world/player save identity.
-- Two checksummed generations preserve a readable previous file after interrupted writes.
local M={}
local Appearance=require('appearance')
local function copy(v)
    local look=Appearance.normalize(v)
    return {enabled=v and v.enabled==true,confirmed=v and v.confirmed==true,
        eye=v and (v.eye==34 or v.eye==40) and v.eye or 46,coat=look.coat,eyes=look.eyes,paws=look.paws}
end
M.copy=copy
local function hex(s)return (s:gsub('.',function(c)return string.format('%02x',c:byte())end))end
local function unhex(s)
    if #s%2~=0 or s:find('[^0-9a-f]') then return end
    return (s:gsub('..',function(c)return string.char(tonumber(c,16))end))
end
local function checksum(s)
    local a,b=1,0
    for i=1,#s do a=(a+s:byte(i))%65521;b=(b+a)%65521 end
    return string.format('%08x',b*65536+a)
end
local function read(filename)
    local f=io.open(filename,'rb');if not f then return end
    local text=f:read(524289);f:close()
    if not text or #text>524288 then return false end
    local body,hash=text:match('^(.*\n)checksum=([0-9a-f]+)\n$')
    if not body or checksum(body)~=hash then return false end
    local revision,used=body:match('^fox_profiles=1\nrevision=(%d+)\nlegacy_used=([01])\n')
    revision=tonumber(revision)
    if not revision or revision>1000000000 then return false end
    local result={revision=revision,legacyUsed=used=='1',records={}}
    local count=0
    for line in body:gmatch('[^\n]+') do
        if line:sub(1,2)=='P|' then
            local key,label,on,eye,coat,eyes,paws,confirmed=line:match('^P|([0-9a-f]+)|([0-9a-f]+)|([01])|(%d+)|(%d+)|(%d+)|(%d+)|([01])$')
            key,label=key and unhex(key),label and unhex(label)
            if not key or not label or #key>2048 or #label>1024 or result.records[key] then return false end
            result.records[key]={label=label,choice=copy({enabled=on=='1',eye=tonumber(eye),coat=tonumber(coat),eyes=tonumber(eyes),paws=tonumber(paws),confirmed=confirmed=='1'})}
            count=count+1;if count>1000 then return false end
        elseif not line:match('^fox_profiles=1$') and not line:match('^revision=%d+$') and not line:match('^legacy_used=[01]$') then return false end
    end
    return result
end
function M.open(folder,log)
    local a,b=read(folder..'character-options-a.txt'),read(folder..'character-options-b.txt')
    local s=(a and b and (a.revision>=b.revision and a or b)) or a or b or {revision=0,legacyUsed=false,records={}}
    s.folder,s.log=folder,log or function()end
    s.slot=(a and s==a) and 'a' or 'b'
    s.blocked=(a==false or b==false) and not a and not b
    if s.blocked then s.log('Character profile files unreadable; preserving them and retaining native Human.') end
    return s
end
local function write(s,records,used)
    if s.blocked then return false,'Character profile files need recovery; originals preserved.' end
    local revision=s.revision+1
    local lines={'fox_profiles=1','revision='..revision,'legacy_used='..(used and '1' or '0')}
    local keys={};for key in pairs(records) do keys[#keys+1]=key end;table.sort(keys)
    if #keys>1000 then return false,'Character profile limit reached.' end
    for _,key in ipairs(keys) do
        local row=records[key];local c=copy(row.choice)
        lines[#lines+1]=table.concat({'P',hex(key),hex(row.label),c.enabled and 1 or 0,c.eye,c.coat,c.eyes,c.paws,c.confirmed and 1 or 0},'|')
    end
    local body=table.concat(lines,'\n')..'\n';local payload=body..'checksum='..checksum(body)..'\n'
    if #payload>524288 then return false,'Character profile file limit reached.' end
    local slot=s.slot=='a' and 'b' or 'a'
    local filename=s.folder..'character-options-'..slot..'.txt'
    local f,err=io.open(filename,'wb');if not f then return false,err end
    local ok,why=f:write(payload);local closed,closeError=f:close()
    if not ok or closed==nil then return false,why or closeError or 'Profile write failed.' end
    local check=read(filename)
    if not check or check.revision~=revision then return false,'Profile read-back verification failed.' end
    s.records,s.legacyUsed,s.revision,s.slot=records,used,revision,slot
    return true
end
function M.save(s,key,label,choice)
    if type(key)~='string' or key=='' or #key>2048 or type(label)~='string' or label=='' or #label>1024 then return false,'Character identity unavailable.' end
    local existing=s.records[key];local c=copy(choice)
    if existing and existing.label==label then
        local equal=true
        for _,field in ipairs({'enabled','confirmed','eye','coat','eyes','paws'}) do
            if existing.choice[field]~=c[field] then equal=false;break end
        end
        if equal then return true end
    end
    local rows={};for k,v in pairs(s.records) do rows[k]=v end
    rows[key]={label=label,choice=c}
    return write(s,rows,true)
end
function M.get(s,key) local row=s.records[key];return row and copy(row.choice) end
function M.bind(s,key,label,legacy)
    local pendingKey='pending-v1:'..key
    local pending=pendingKey and M.get(s,pendingKey)
    local existing=M.get(s,key)
    if existing and not pending then
        if s.records[key].label~=label then
            local ok,err=M.save(s,key,label,existing)
            if not ok then return nil,err end
        end
        return existing
    end
    local choice=pending or (not s.legacyUsed and legacy) or {enabled=false,confirmed=true}
    choice=copy(choice)
    local rows={};for k,v in pairs(s.records) do rows[k]=v end
    rows[key]={label=label,choice=choice};if pendingKey then rows[pendingKey]=nil end
    local ok,err=write(s,rows,true)
    if not ok then return nil,err end
    s.log('Character profile bound: '..label..'; '..(choice.enabled and 'Fox' or 'Human'))
    return copy(choice)
end
function M.stageCreation(s,identity,choice)
    if type(identity)~='string' or not (identity:sub(1,9)=='local-v1:'or identity:sub(1,11)=='network-v1:') then return false,'Waiting for the native character save identity.' end
    return M.save(s,'pending-v1:'..identity,identity,choice)
end
function M.list(s)
    local rows={}
    for key,row in pairs(s.records) do
        if key:sub(1,9)=='local-v1:'or key:sub(1,11)=='network-v1:'then rows[#rows+1]={id=key,label=row.label} end
    end
    table.sort(rows,function(a,b)if a.label==b.label then return a.id<b.id end;return a.label<b.label end)
    return rows
end
return M
