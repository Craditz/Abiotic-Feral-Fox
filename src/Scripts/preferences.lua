-- Local player choice only. Never execute the contents of the preference file.
local M={}
local Appearance=require('appearance')
function M.load(filename,defaultEnabled)
    local choice={enabled=defaultEnabled,eye=46,coat=0,eyes=0,paws=0,confirmed=false}
    if not filename then return choice end
    local file=io.open(filename,'r')
    if not file then return choice end
    local text=file:read('*a'); file:close()
    local enabled=text:match('^enabled=(%a+)\r?\n')
    if enabled=='true' or enabled=='false' then choice.enabled=enabled=='true' end
    choice.confirmed=text:match('\nselection_version=1\r?\n')~=nil
    local eye=tonumber(text:match('\neye=(%d+)'))
    if eye==34 or eye==40 or eye==46 then choice.eye=eye end
    local look=Appearance.normalize({coat=tonumber(text:match('\ncoat=(%d+)')),
        eyes=tonumber(text:match('\neyes=(%d+)')),paws=tonumber(text:match('\npaws=(%d+)'))})
    choice.coat,choice.eyes,choice.paws=look.coat,look.eyes,look.paws
    return choice
end
function M.save(filename,choice)
    if not filename then return false,'Preference path unavailable' end
    local file,err=io.open(filename,'w')
    if not file then return false,err end
    local look=Appearance.normalize(choice)
    local eye=(choice.eye==34 or choice.eye==40) and choice.eye or 46
    local ok,writeError=file:write('enabled='..tostring(choice.enabled==true)..'\neye='..eye..
        '\ncoat='..look.coat..'\neyes='..look.eyes..'\npaws='..look.paws..
        '\nselection_version='..(choice.confirmed==true and '1' or '0')..'\n')
    local closed,closeError=file:close()
    if not ok then return false,writeError end
    if closed==nil and closeError then return false,closeError end
    return true
end
return M
