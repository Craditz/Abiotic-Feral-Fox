local findObject = require('object_lookup')
-- Native UMG integration candidate. Offline tested; native layout/hook validation pending.
-- Cross-tick state contains object paths, never retained UObject handles.
local Appearance=require('appearance')
local Preview=require('customization_preview')
local M={}
local options,sessions,timer,serial=nil,{},nil,0
local failures,creationSeen={},{}
local pending,hooked,committed,committing={}, {}, {}, nil
local CUSTOM='/Game/Blueprints/Widgets/MenuSystem/W_MainMenu_CustomizeCharacter.W_MainMenu_CustomizeCharacter_C'
local TRAITS='/Game/Blueprints/Widgets/TraitSelect/W_Character_Trait_Selection.W_Character_Trait_Selection_C'
local categories={'Head','Hair','HairColor','Beard','Top','Shirts','Fabric','Accessory','Bottom','Belt','Shoes','IDCard','Voice','Wristwatch','FannyPack'}
local function log(s) print('[FeralFoxUI] '..s..'\n') end
local function valid(o)
    if not o then return false end
    local ok,result=pcall(function() return o:IsValid() end)
    return ok and result==true
end
local function path(o) return valid(o) and o:GetFullName():match('^[^ ]+ (.+)$') or nil end
local function resolve(p) return p and findObject(p) or nil end
local function field(o,key) local ok,value=pcall(function()return o[key]end);if ok then return value end end
local function is(o,class) return valid(o) and o:IsA(class) end
local function visible(widget)
    if not valid(widget) then return false end
    local child=widget
    for _=1,64 do
        if not child:IsVisible() then return false end
        local parent=child:GetParent()
        if valid(parent) then
            if is(parent,'/Script/UMG.WidgetSwitcher') and path(parent:GetActiveWidget())~=path(child) then return false end
            child=parent
        else
            if is(child,'/Script/UMG.UserWidget') and child:IsInViewport() then return true end
            local owner=child:GetOuter()
            if is(owner,'/Script/UMG.WidgetTree') then owner=owner:GetOuter() end
            if not is(owner,'/Script/UMG.UserWidget') or path(owner)==path(child) then return false end
            child=owner
        end
    end
    return false
end
function M.context(widget)
    if not valid(widget) or (committing~=path(widget) and not visible(widget)) then return nil end
    local p=path(widget)
    if not p or p:find('/Game/Blueprints/',1,true) then return nil end
    if is(widget,CUSTOM) then return 'customization' end
    if is(widget,TRAITS) and field(widget,'IsJobChange')~=true then return 'creation' end
end
function M.isCreating()
    for _,widget in ipairs(FindAllOf('W_Character_Trait_Selection_C') or {}) do
        if M.context(widget)=='creation' and not committed[path(widget)] then return true end
    end
    return false
end
function M.isCommittingCreation(widget)
    return committing==path(widget) and M.context(widget)=='creation'
end
local function make(kind,outer)
    serial=serial+1
    local widget=StaticConstructObject(findObject('/Script/UMG.'..kind),outer,FName('FeralFox_'..kind..'_'..serial))
    assert(valid(widget),'Could not construct '..kind)
    return widget
end
local function text(outer,label,template)
    local widget=make('TextBlock',outer)
    if valid(template) then widget:SetFont(template.Font) end
    -- Explicit color/font avoid the inherited black popup text seen in creation.
    if not valid(template) then
        local font=widget.Font
        font.Size=20
        widget:SetFont(font)
    end
    widget:SetColorAndOpacity({SpecifiedColor={R=.92,G=.98,B=1,A=1},ColorUseRule=0})
    widget:SetText(FText(label))
    widget:SetAutoWrapText(true)
    return widget
end
local function canvasInParents(child)
    for _=1,64 do
        if not valid(child) then break end
        if is(child,'/Script/UMG.CanvasPanel') then return child end
        child=child:GetParent()
    end
end
local function rootCanvas(widget,mode,state)
    -- An absent UE4SS property can be a truthy invalid UObject/function wrapper.
    -- Pick the known property for this screen and validate it explicitly.
    local start=field(widget,mode=='customization' and 'UGrid_Categories' or 'Button_Finish')
    local canvas=canvasInParents(start) or canvasInParents(widget)
    if valid(canvas) then return canvas end
    local tree=field(widget,'WidgetTree')
    local root=valid(tree) and field(tree,'RootWidget')
    if is(root,'/Script/UMG.CanvasPanel') then return root end
    if is(root,'/Script/UMG.ContentWidget') then
        -- Traits can use a BackgroundBlur/ScaleBox root instead of a Canvas.
        -- Preserve that native content in an overlay and add our own canvas.
        local native=root:GetContent()
        assert(valid(native),'Native creation root has no content yet')
        local overlay=make('Overlay',tree)
        canvas=make('CanvasPanel',tree)
        state.wrappedRoot,state.originalRootContent,state.rootOverlay=path(root),path(native),path(overlay)
        root:SetContent(overlay)
        overlay:AddChildToOverlay(native)
        local slot=overlay:AddChildToOverlay(canvas)
        slot:SetHorizontalAlignment(0);slot:SetVerticalAlignment(0)
        return canvas
    end
    error('Native menu layout is not ready: no Canvas or ContentWidget root; anchor='..
        (valid(start) and start:GetFullName() or '<invalid>')..'; root='..
        (valid(root) and root:GetFullName() or '<invalid>'))
end
local function combo(outer,box,label,rows,id,template)
    box:AddChildToVerticalBox(text(outer,label))
    local widget=make('ComboBoxString',outer)
    if valid(template) then
        widget.WidgetStyle=template.WidgetStyle
        widget.ItemStyle=template.ItemStyle
    end
    local styled,styleError=pcall(function()
        local white=findObject('/Engine/EngineResources/WhiteSquareTexture.WhiteSquareTexture')
        if not valid(white) then white=LoadAsset('/Engine/EngineResources/WhiteSquareTexture.WhiteSquareTexture') end
        assert(valid(white),'Native white UI texture unavailable')
        local function opaque(brush,color)
            brush.DrawAs=3 -- Image, using a plain white resource rather than a dark themed image.
            brush.ResourceObject=white
            brush.TintColor={SpecifiedColor=color,ColorUseRule=0}
        end
        local style=widget.WidgetStyle
        local brush=style.ComboButtonStyle.MenuBorderBrush
        opaque(brush,{R=.82,G=.87,B=.88,A=1})
        widget.WidgetStyle=style
        local rows=widget.ItemStyle
        for _,name in ipairs({'EvenRowBackgroundBrush','OddRowBackgroundBrush'}) do
            opaque(rows[name],{R=.82,G=.87,B=.88,A=1})
        end
        for _,name in ipairs({'EvenRowBackgroundHoveredBrush','OddRowBackgroundHoveredBrush','ActiveBrush','ActiveHoveredBrush','InactiveBrush','InactiveHoveredBrush'}) do
            opaque(rows[name],{R=.35,G=.8,B=.87,A=1})
        end
        local dark={SpecifiedColor={R=.015,G=.025,B=.03,A=1},ColorUseRule=0}
        rows.TextColor=dark;rows.SelectedTextColor=dark
        widget.ItemStyle=rows
    end)
    -- Cosmetic styling must never prevent either species selector from loading.
    if not styled then log('Using native dropdown style: '..tostring(styleError)) end
    local selected=0
    for index,row in ipairs(rows) do
        widget:AddOption(row.label)
        if row.id==id then selected=index-1 end
    end
    widget:SetSelectedIndex(selected)
    widget.MaxListHeight=260
    widget.Font.Size=20
    widget.ForegroundColor={SpecifiedColor={R=.02,G=.035,B=.04,A=1},ColorUseRule=0}
    widget.ContentPadding={Left=12,Top=7,Right=12,Bottom=7}
    local size=make('SizeBox',outer)
    size:SetMinDesiredWidth(360)
    size:SetMinDesiredHeight(48)
    size:SetContent(widget)
    box:AddChildToVerticalBox(size)
    return path(widget)
end
local function readCombo(p,rows)
    local widget=resolve(p)
    if not valid(widget) then return nil end
    local row=rows[widget:GetSelectedIndex()+1]
    return row and row.id
end
local function setCombo(p,rows,id)
    local widget=resolve(p);if not valid(widget) then return end
    for i,row in ipairs(rows) do if row.id==id then widget:SetSelectedIndex(i-1);return end end
end
local function coatThumbnails(outer,panel,look)
    local grid=make('UniformGridPanel',outer)
    local scroll=make('ScrollBox',outer);scroll:AddChild(grid)
    local viewport=make('SizeBox',outer);viewport:SetHeightOverride(210);viewport:SetContent(scroll)
    local thumbs={}
    for i,row in ipairs(Appearance.catalog.coats) do
        local image=make('Image',outer)
        image:SetBrushFromTexture(options.load('/Game/FeralFox/T_FoxThumb_Coat_'..string.format('%02d',row.id)..'.T_FoxThumb_Coat_'..string.format('%02d',row.id)),false)
        local size=make('SizeBox',outer);size:SetWidthOverride(96);size:SetHeightOverride(72);size:SetContent(image)
        local border=make('Border',outer);border:SetPadding({Left=3,Top=3,Right=3,Bottom=3});border:SetContent(size)
        local check=make('CheckBox',outer);check:SetContent(border);check:SetToolTipText(FText(row.label));check:SetIsChecked(row.id==look.coat)
        grid:AddChildToUniformGrid(check,math.floor((i-1)/3),(i-1)%3)
        thumbs[#thumbs+1]={id=row.id,check=path(check),border=path(border)}
    end
    panel:AddChildToVerticalBox(viewport)
    return thumbs
end
local function syncThumbnails(s)
    if not s.thumbs or (not s.active and s.thumbCoat~=nil) then return end
    local selected=readCombo(s.coat,Appearance.catalog.coats)
    if s.thumbCoat==selected then
        for _,row in ipairs(s.thumbs) do
            local check=resolve(row.check)
            if valid(check) and check:IsChecked() and row.id~=selected then
                selected=row.id;setCombo(s.coat,Appearance.catalog.coats,selected);break
            end
        end
    end
    local changed=selected~=s.thumbCoat
    for _,row in ipairs(s.thumbs) do
        local check,border=resolve(row.check),resolve(row.border)
        if valid(check) and check:IsChecked()~=(row.id==selected) then check:SetIsChecked(row.id==selected) end
        if changed and valid(border) then border:SetBrushColor(row.id==selected and {R=.15,G=.85,B=.9,A=1} or {R=.025,G=.065,B=.075,A=1}) end
    end
    s.thumbCoat=selected
end
local function selectProfile(s,key)
    local c=options.getProfileChoice(key)
    if not c then return end
    s.profileKey=key
    setCombo(s.species,{{id=0},{id=1}},c.enabled and 1 or 0)
    for _,kind in ipairs({'coat','eyes','paws'}) do setCombo(s[kind],Appearance.catalog[kind=='coat' and 'coats' or kind],c[kind]) end
    s.thumbCoat=nil;syncThumbnails(s)
    local status=resolve(s.status);if valid(status)then status:SetText(FText(''))end
end
local function sample(s)
    local species=readCombo(s.species,{{id=0},{id=1}})
    local look=Appearance.normalize({coat=readCombo(s.coat,Appearance.catalog.coats),
        eyes=readCombo(s.eyes,Appearance.catalog.eyes),paws=readCombo(s.paws,Appearance.catalog.paws)})
    return species==1,look
end
local function setNative(s,show)
    for p,value in pairs(s.hidden or {}) do
        local widget=resolve(p)
        if valid(widget) then widget:SetVisibility(show and value or 1) end
    end
    local title=resolve(s.title)
    if valid(title) and (not show or title:GetText():ToString()=='FOX') then
        title:SetText(FText(show and s.titleText or 'FOX'))
    end
end
local function selectTab(s,active)
    s.active=active
    local panel=resolve(s.panel)
    if valid(panel) then panel:SetVisibility(active and 0 or 1) end
    setNative(s,not active)
    local widget=resolve(s.widget)
    if active and valid(widget) then
        for _,name in ipairs(categories) do
            local native=field(widget,'Button_'..name)
            local checkbox=valid(native) and field(native,'CustomizationCheckbox')
            if valid(checkbox) then checkbox:SetIsChecked(false) end
        end
    end
end
local function destroy(s)
    Preview.clear(s)
    if s.mode=='customization' then setNative(s,true) end
    for _,p in ipairs({s.panel,s.tab}) do
        local widget=resolve(p)
        if valid(widget) then widget:RemoveFromParent() end
    end
    local root=resolve(s.wrappedRoot)
    local native=resolve(s.originalRootContent)
    if valid(root) and valid(native) and path(root:GetContent())==s.rootOverlay then
        root:SetContent(native)
    end
end
local function build(widget,mode)
    local outer=widget.WidgetTree
    local s={widget=path(widget),mode=mode,hidden={},active=mode=='creation'}
    sessions[s.widget]=s
    local panel=make('VerticalBox',outer)
    local background=make('Border',outer)
    s.panel=path(background)
    background:SetBrushColor({R=.015,G=.045,B=.055,A=1})
    background:SetPadding({Left=18,Top=14,Right=18,Bottom=14})
    background:SetContent(panel)
    local canvas=rootCanvas(widget,mode,s)
    local slot=canvas:AddChildToCanvas(background)
    -- Proportional anchor; native DPI scaling remains in effect.
    if mode=='creation' then
        -- Free lower area marked by the owner: independent of the expandable
        -- Character Summary and clear of Change Job / Finish at either side.
        slot:SetAnchors({Minimum={X=.35,Y=1},Maximum={X=.35,Y=1}})
        slot:SetAlignment({X=.5,Y=1})
        slot:SetPosition({X=0,Y=-70})
        slot:SetSize({X=440,Y=140})
        slot:SetAutoSize(true)
    elseif mode~='creation' then
        slot:SetAnchors({Minimum={X=1,Y=0},Maximum={X=1,Y=0}})
        slot:SetPosition({X=-500,Y=180})
        slot:SetSize({X=450,Y=790})
    end
    slot:SetZOrder(25)
    local enabled=mode=='customization' and options.getChoice() or false
    local look=Appearance.normalize(options.getAppearance())
    local template=field(widget,'ComboBoxString_0')
    if mode=='customization' and options.getProfiles then
        s.profileRows=options.getProfiles();s.profileKey=options.getSelectedProfile()
        local c=options.getProfileChoice(s.profileKey)
        if c then enabled=c.enabled;look=Appearance.normalize(c) end
        s.profile=combo(outer,panel,'Character',s.profileRows,s.profileKey,template)
    end
    s.species=combo(outer,panel,'Species',{{id=0,label='Human'},{id=1,label='Fox'}},enabled and 1 or 0,template)
    if mode=='customization' then
        s.coat=combo(outer,panel,'Coat',Appearance.catalog.coats,look.coat,template)
        if options.load then
            local ok,thumbs=pcall(coatThumbnails,outer,panel,look)
            if ok then s.thumbs=thumbs;s.thumbCoat=nil;syncThumbnails(s)
            else log('Coat thumbnails unavailable; dropdown retained: '..tostring(thumbs)) end
        end
        s.eyes=combo(outer,panel,'Eyes',Appearance.catalog.eyes,look.eyes,template)
        s.paws=combo(outer,panel,'Paws',Appearance.catalog.paws,look.paws,template)
        panel:AddChildToVerticalBox(text(outer,s.profile and 'Save Changes applies to the selected character. New characters choose species at creation.' or 'Saved with Save Changes. Hidden equipment keeps its normal effects.'))
        s.title=path(widget.CategoryText)
        s.titleText=widget.CategoryText:GetText():ToString()
        for _,name in ipairs({'UGrid_CategoryOptions','HBox_SkinTone'}) do
            local native=field(widget,name)
            if valid(native) then s.hidden[path(native)]=native:GetVisibility() end
        end
        local tab=make('CheckBox',outer)
        s.tab=path(tab)
        local native=field(widget,'Button_Head')
        local checkbox=valid(native) and field(native,'CustomizationCheckbox')
        -- SetWidgetStyle is C++-only in UE 5.4; assign the reflected property
        -- before attaching the new checkbox to its Slate parent.
        if valid(checkbox) then tab.WidgetStyle=checkbox.WidgetStyle end
        tab:SetContent(text(outer,'FOX',widget.CategoryText))
        widget.UGrid_Categories:AddChildToUniformGrid(tab,3,1)
        selectTab(s,false)
    else
        s.initial=look
        panel:AddChildToVerticalBox(text(outer,'Colors: Fox tab in Customization.'))
    end
    s.status=path(text(outer,''))
    panel:AddChildToVerticalBox(resolve(s.status))
    log('Prepared '..mode..' selector.')
    return s
end
local function commit(widget)
    local p=path(widget)
    local s=sessions[p] or pending[p]
    if not s then log('Confirmation had no captured selection: '..tostring(p));return end
    local enabled,look
    if sessions[p] then enabled,look=sample(s) else enabled,look=s.enabled,s.look end
    if s.mode=='creation' then look=s.initial end
    committing=p
    local called,ok,err=pcall(options.select,enabled,look,widget,s.profileKey)
    committing=nil
    if not called then err=ok;ok=false end
    if ok then
        committed[p]=true
        log('Committed '..s.mode..' selection: '..(enabled and 'Fox' or 'Human'))
    end
    if not ok then
        local status=resolve(s.status)
        if valid(status) then status:SetText(FText('Fox choice could not save: '..tostring(err))) end
        log('Choice not saved: '..tostring(err))
    end
end
local function installHooks(widget,mode)
    local class=mode=='creation' and TRAITS or CUSTOM
    local names=mode=='creation' and {'CompleteTraitSelection','YesClicked',
        'BndEvt__Button_Finish_K2Node_ComponentBoundEvent_0_ButtonPressed__DelegateSignature'} or
        {'BackAndSaveCustomization','BndEvt__W_MainMenuButton_BackAndSave_K2Node_ComponentBoundEvent_0_ButtonPressed__DelegateSignature'}
    for _,name in ipairs(names) do
        local full=class..':'..name
        if not hooked[full] and valid(findObject(full)) then
            local ok,err=pcall(RegisterHook,full,function(context)
                local current=context:get()
                if is(current,class) then commit(current) end
            end)
            if ok then hooked[full]=true;log('Confirmation hook ready: '..name)
            else log('Confirmation hook unavailable: '..name..' '..tostring(err)) end
        end
    end
end
local function poll()
    for p,s in pairs(sessions) do
        local widget=resolve(p)
        if s.profile then
            local key=readCombo(s.profile,s.profileRows)
            if key and key~=s.profileKey then selectProfile(s,key) end
        end
        syncThumbnails(s)
        local enabled,look=sample(s)
        pending[p]={widget=p,mode=s.mode,enabled=enabled,look=look,initial=s.initial,profileKey=s.profileKey}
        if not M.context(widget) then destroy(s);sessions[p]=nil
        elseif s.mode=='customization' then
            local tab=resolve(s.tab)
            local checked=valid(tab) and tab:IsChecked()
            if checked and not s.active then selectTab(s,true)
            elseif not checked and s.active then selectTab(s,false) end
            if s.active then
                for _,name in ipairs(categories) do
                    local native=field(widget,'Button_'..name)
                    local checkbox=valid(native) and field(native,'CustomizationCheckbox')
                    if valid(checkbox) and checkbox:IsChecked() then
                        tab:SetIsChecked(false);selectTab(s,false);break
                    end
                end
            end
            if s.active then
                local enabled,look=sample(s)
                if not s.previewFailed then
                    local ok,err=pcall(Preview.update,s,widget,enabled,look,options)
                    if not ok then
                        pcall(Preview.clear,s)
                        s.previewFailed=true
                        local status=resolve(s.status)
                        if valid(status) then status:SetText(FText('Preview unavailable. Your selection can still be saved.')) end
                        log('Preview failed; selection retained: '..tostring(err))
                    end
                end
            else Preview.clear(s) end
        end
    end
    for _,class in ipairs({'W_MainMenu_CustomizeCharacter_C','W_Character_Trait_Selection_C'}) do
        for _,widget in ipairs(FindAllOf(class) or {}) do
            local mode=M.context(widget)
            if mode and not sessions[path(widget)] then
                local p=path(widget)
                if mode=='creation' and not creationSeen[p] then
                    creationSeen[p]=true
                    if options.creationStarted then options.creationStarted(widget) end
                end
                local failure=failures[p]
                -- Retry a not-yet-constructed tree; isolate failures by screen.
                if not failure or failure.wait<=0 then
                    local ok,err=pcall(build,widget,mode)
                    if not ok then
                        local s=sessions[p]
                        if s then pcall(destroy,s);sessions[p]=nil end
                        local count=failure and failure.count+1 or 1
                        failures[p]={count=count,wait=50}
                        if count==1 then log(mode..' attachment pending: '..tostring(err)) end
                    else
                        failures[p]=nil
                        installHooks(widget,mode)
                    end
                else
                    failure.wait=failure.wait-1
                end
            end
        end
    end
end
function M.cleanup()
    for _,s in pairs(sessions) do pcall(destroy,s) end
    sessions={};failures={};creationSeen={};pending={};committed={}
end
function M.start(callbacks)
    assert(not timer,'Customization already started')
    options=callbacks
    RegisterCustomEvent('BackAndSaveCustomization',function(context)
        local widget=context:get()
        if is(widget,CUSTOM) then commit(widget) end
    end)
    RegisterCustomEvent('YesClicked',function(context)
        local widget=context:get()
        if is(widget,TRAITS) then commit(widget) end
    end)
    for _,name in ipairs({'CompleteTraitSelection','BndEvt__Button_Finish_K2Node_ComponentBoundEvent_0_ButtonPressed__DelegateSignature'}) do
        RegisterCustomEvent(name,function(context)
            local widget=context:get()
            if is(widget,TRAITS) then commit(widget) end
        end)
    end
    RegisterCustomEvent('BndEvt__W_MainMenuButton_BackAndSave_K2Node_ComponentBoundEvent_0_ButtonPressed__DelegateSignature',function(context)
        local widget=context:get()
        if is(widget,CUSTOM) then commit(widget) end
    end)
    timer=LoopInGameThreadWithDelay(100,function()
        local ok,err=pcall(poll)
        if not ok then
            -- No permanent global shutdown because one menu failed to build.
            M.cleanup()
            log('Menu poll recovered after error: '..tostring(err))
        end
    end)
end
return M
