-- Exact build-25071553 Blueprint POST receivers proven by isolated diagnostics.
local Adapter={}
local directory=assert(debug.getinfo(1,"S").source:match("^@(.+[/\\])"))
local Core=dofile(directory.."contract_raid_observations.lua")
local Cycle=dofile(directory.."tfw_contract_cycle_reader.lua")
local classes={
    player="/Game/FW/Player/BP_PlayerBase.BP_PlayerBase_C",
    radar="/Game/FW/TugOfWar/BP_TugOfWar_and_RadarManager.BP_TugOfWar_and_RadarManager_C",
    loader="/Game/FW/Quests/QuestBPobjects/BP_DataLayersLoader.BP_DataLayersLoader_C",
}
Adapter.hooks={
    {key="killed",family="player",name="Killed",n=3,
        fields={DamageEvent="StructProperty",EventInstigator="ObjectProperty",DamageCauser="ObjectProperty"}},
    {key="radar1",family="radar",name="Radar 1 Unlocked",n=1,slot=1,fields={TerminalIndex="IntProperty"}},
    {key="radar2",family="radar",name="Radar 2 Unlocked",n=1,slot=2,fields={TerminalIndex="IntProperty"}},
    {key="radar3",family="radar",name="Radar 3 unlocked",n=1,slot=3,fields={TerminalIndex="IntProperty"}},
    {key="all3",family="radar",name="3 of 3",n=0,aggregate=3},
    {key="selector",family="loader",name="Do weighting on BP",n=2,
        fields={["Weight In"]="MapProperty",["Weight Out"]="MapProperty"}},
}
for _,h in ipairs(Adapter.hooks) do h.path=classes[h.family]..":"..h.name end
local function identity(o)
    if o==nil or not o:IsValid() then return nil end
    local n=o:GetFullName()
    if type(n)=="string" and not n:find("Default__",1,true) then return n end
end
local function shape(object,expected)
    local observed={}
    object:ForEachProperty(function(p)
        local n=p:GetFullName(); observed[n:match(":([^:]+)$") or ""]=n:match("^(%S+)")
    end)
    for name,kind in pairs(expected or {}) do
        assert(observed[name]==kind,"shape:"..name..":expected="..kind..":observed="..tostring(observed[name]))
    end
end
function Adapter.start(options)
    local log=options.log or function() end
    local deps=options.deps or {}
    local find_static=deps.find_static or StaticFindObject
    local find_all=deps.find_all or FindAllOf
    local register=deps.register or RegisterHook
    local notify=deps.notify or NotifyOnNewObject
    local schedule=deps.schedule or function(ms,fn) ExecuteWithDelay(ms,function() ExecuteInGameThread(fn) end) end
    local core=Core.new({log=log,emit=options.emit,now=deps.now})
    local installed,blocked,attempts,calls={},{},{},{}
    local controller_shape=nil
    local function current_owner()
        if controller_shape==nil then
            local ok,err=pcall(function()
                local c=find_static("/Script/Engine.Controller")
                assert(identity(c),"controller_schema_unavailable"); shape(c,{Pawn="ObjectProperty"})
            end)
            controller_shape=ok
            log("CONTRACT OBSERVER CONTROLLER SCHEMA accepted="..tostring(ok).." reason="..tostring(err))
        end
        if not controller_shape then return nil end
        local objects=find_all("PlayerController")
        if type(objects)~="table" then return nil end
        local count,scanned,controller=0,0,nil
        for _,candidate in pairs(objects) do
            scanned=scanned+1; assert(scanned<=32,"controller_cap")
            if identity(candidate) and candidate:IsPlayerController()==true and candidate:IsLocalPlayerController()==true then
                count=count+1; controller=candidate
            end
        end
        if count~=1 then return nil end
        local pawn=controller.Pawn -- Returned object, never call get/Get here.
        local owner=identity(pawn)
        if not owner then return nil end
        local class=identity(pawn:GetClass())
        if not class or not class:find("/Game/FW/Player/",1,true) then return nil end
        return owner,controller
    end
    local function handle(h,context,...)
        calls[h.key]=(calls[h.key] or 0)+1
        if calls[h.key]<=8 then log("CONTRACT OBSERVATION CALLBACK hook="..h.key.." count="..calls[h.key].." boundary=blueprint_post") end
        if blocked[h.key] then return end
        assert(select("#",...)==h.n,"callback_parameter_count")
        local object=context:get() -- Documented callback wrapper, exactly once.
        local name=identity(object)
        if not name then return end
        local owner,controller=current_owner()
        if h.key=="selector" then
            local function trace(event,fields)
                log("CONTRACT CYCLE READ event="..event.." role="..tostring(fields.role)..
                    " index="..tostring(fields.index).." reason="..tostring(fields.reason))
            end
            local output=Cycle.read(select(2,...),"selected_output",trace)
            local input=Cycle.read(select(1,...),"input",trace)
            return core:selection(input,output,name,owner)
        end
        local state=options.raid_snapshot()
        if not core:owned(owner) or not state.raid_active or state.raid_sequence~=core.raid.sequence
            or state.lifecycle_epoch~=core.epoch or state.extracted_alive_seen then return end
        if h.family=="radar" then
            return core:radar(name,owner,h.slot,h.slot and select(1,...):get() or nil,h.aggregate)
        end
        if name~=owner then return end
        -- Freeze even a failed read. Do not credit post-death kills, retry a
        -- later cleanup scan, or pay here. HUB terminal settlement stays sole owner.
        core:freeze()
        local ok,snapshot=pcall(options.read_death,state.raid_sequence,controller,owner,state.raid_start_epoch)
        log("CONTRACT DEATH CAPTURE raid="..state.raid_sequence.." complete="..
            tostring(ok and type(snapshot)=="table" and snapshot.complete==true).." cached_count_substituted=false")
        core:send("player_death_inventory_captured",{source="Killed_POST"})
    end
    local function install(family,reason)
        for _,h in ipairs(Adapter.hooks) do
            if h.family==family and not installed[h.key] and not blocked[h.key] and (attempts[h.key] or 0)<8 then
                attempts[h.key]=(attempts[h.key] or 0)+1
                local object=find_static(h.path)
                if identity(object) then
                    local ok,err=pcall(function()
                        shape(object,h.fields)
                        local id=register(h.path,function(context,...)
                            local success,failure=pcall(handle,h,context,...)
                            if not success then
                                blocked[h.key]=true
                                if h.key=="selector" then core:invalidate("selector_callback_error") end
                                log("CONTRACT OBSERVATION BLOCKED hook="..h.key.." reason="..tostring(failure))
                            end
                        end)
                        assert(type(id)=="number" and id>0,"registration_id_unavailable")
                    end)
                    installed[h.key]=ok; blocked[h.key]=not ok
                    log("CONTRACT OBSERVATION REGISTRATION hook="..h.key.." accepted="..tostring(ok)..
                        " reason="..tostring(err or reason).." callback_proof=false")
                end
            end
        end
    end
    local function guarded_install(family,reason)
        local ok,err=pcall(install,family,reason)
        if not ok then log("CONTRACT OBSERVATION INSTALL ERROR family="..family.." reason="..tostring(err)) end
    end
    for family,class in pairs(classes) do
        local ok,err=pcall(notify,class,function() guarded_install(family,"synchronous_class_notify") end)
        log("CONTRACT OBSERVATION NOTIFY family="..family.." accepted="..tostring(ok).." reason="..tostring(err))
    end
    for _,ms in ipairs({1000,5000,20000}) do schedule(ms,function()
        for family in pairs(classes) do guarded_install(family,"startup_fallback") end
    end) end
    return {
        core=core,installed=installed,blocked=blocked,
        owner_identity=function() local ok,owner=pcall(current_owner);if ok then return owner end end,
        lifecycle=function(epoch) core:lifecycle(epoch) end,
        raid_started=function(event)
            local ok,owner=pcall(current_owner)
            core:raid_started(event,ok and owner or nil)
        end,
        freeze=function() core:freeze() end,
    }
end
return Adapter
