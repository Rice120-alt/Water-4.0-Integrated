-- Read-only, synchronous, game-thread adapter. It returns primitives only.
local Reader = {}
Reader.__index = Reader
local module_directory = assert(debug.getinfo(1, "S").source:match("^@(.+[/\\])"))
local Registry = dofile(module_directory .. "tfw_retained_item_registry.lua")
local HUB = "/Game/LevelDesign/HUB_World/HUB_V6_WP"

local function valid(o)
    if o == nil then return false end
    local ok, value = pcall(function() return o:IsValid() end)
    return ok and value == true
end

local function identity(o)
    if not valid(o) then return nil end
    local ok, value = pcall(function() return o:GetFullName() end)
    if not ok or type(value) ~= "string" or value:find("Default__",1,true) then return nil end
    return value
end

local function field(o, name)
    -- Reflected properties already return their value. A struct's missing
    -- get/Get member invokes native property-error handling before pcall can
    -- recover (v0.0.42 crash: ContainerItem.Get -> luaL_traceback).
    return o[name]
end

local function array_each(array, cap, visit)
    if array == nil then error("array_unavailable") end
    local seen = 0
    -- ForEach is the already used UE4SS array boundary. An exception at the
    -- cap aborts traversal, so a truncated scan can never become authoritative.
    array:ForEach(function(index, raw)
        seen = seen + 1
        if seen > cap then error("array_cap_exceeded") end
        -- ForEach documents a parameter wrapper here. Unwrap it once, only
        -- at this boundary; never probe get() on the resulting native value.
        visit(raw:get(), index)
    end)
    return seen
end

function Reader.new(options)
    options = options or {}
    return setmetatable({ find_all = options.find_all or FindAllOf,
        find_static = options.find_static or StaticFindObject,
        log = options.log or function() end, traced = {},
        targets = options.targets or {Registry.new():resolve("vodka")},
        max_containers = 32, max_slots = 512 }, Reader)
end

function Reader:stage(name)
    if self.traced[name] then return end
    self.traced[name] = true
    self.log("INVENTORY READ STAGE stage=" .. name .. " mutation=none retained_uobject=false")
end

function Reader:read(controller_override, targets)
    local ok, result = pcall(function()
        targets = targets or self.targets
        local wanted, items, storage, item_storage = {}, {}, {}, {}
        for _, target in ipairs(targets) do
            assert(target.storage=="container" or target.storage=="dangly", "unsupported_inventory_storage")
            local key=target.data_table..":"..target.row_name
            assert(not wanted[key] and not items[target.canonical_item_id], "duplicate_inventory_target")
            wanted[key]=target.canonical_item_id
            items[target.canonical_item_id]={complete=true,total=0,brought_in=0}
            storage[target.storage]=true
            item_storage[target.canonical_item_id]=target.storage
        end
        if #targets==0 then return {complete=false,reason="no_inventory_targets"} end
        self:stage("local_controller")
        local controller, matches = nil, 0
        local objects = controller_override and { controller_override } or self.find_all("PlayerController")
        if type(objects) ~= "table" then return { complete=false, reason="controllers_unavailable" } end
        local scanned = 0
        for _, candidate in pairs(objects) do
            scanned = scanned + 1
            if scanned > 32 then error("controller_cap_exceeded") end
            if identity(candidate) and candidate:IsPlayerController() == true
                and candidate:IsLocalPlayerController() == true then
                controller, matches = candidate, matches + 1
            end
        end
        if matches ~= 1 then return { complete=false, reason="local_controller_count_"..matches } end
        self:stage("controller_pawn")
        local pawn = field(controller, "Pawn")
        local owner = identity(pawn)
        if not owner then return { complete=false, reason="pawn_unavailable" } end
        local pawn_class = identity(pawn:GetClass())
        if not pawn_class or not pawn_class:find("/Game/FW/Player/",1,true) then
            return { complete=false, reason="wrong_pawn_family" }
        end
        self:stage("pawn_backpack_rig")
        local rig = field(pawn, "BackpackRig")
        local rig_id = identity(rig)
        if not rig_id then return { complete=false, reason="rig_unavailable" } end
        self:stage("rig_ownership")
        if identity(field(rig, "OwningPlayerCharacter")) ~= owner then
            return { complete=false, reason="rig_owner_mismatch" }
        end
        self:stage("rig_containers")
        local active_slots, slots = 0, 0
        local seen, rows = {}, {}
        local function account(id, count, flag, source, index)
            if type(count)~="number" or count<1 or count>1000000 or count~=math.floor(count)
                or type(flag)~="boolean" then error("invalid_retained_item_record:"..id) end
            local item=items[id]
            item.total=item.total+count
            if item.total>1000000 then error("quantity_cap_exceeded") end
            if flag then item.brought_in=item.brought_in+count end
            rows[#rows+1]={canonical_item_id=id,container=source,slot=index,quantity=count,brought_in=flag}
        end
        local containers = 0
        if storage.container then
        containers = array_each(field(rig,"Containers"), self.max_containers, function(container)
            local id = identity(container)
            if not id then error("invalid_container") end
            if seen[id] then error("duplicate_container") end
            seen[id] = true
            self:stage("container_player")
            if identity(field(container,"Player")) ~= owner then error("container_owner_mismatch") end
            self:stage("container_items_stored")
            array_each(field(container,"ItemsStored"), self.max_slots, function(item, index)
                slots = slots + 1
                if slots > self.max_slots then error("total_slot_cap_exceeded") end
                self:stage("slot_is_in_use")
                local in_use = field(item,"IsInUse")
                if type(in_use) ~= "boolean" then error("invalid_in_use") end
                if not in_use then return end
                active_slots = active_slots + 1
                self:stage("slot_exact_row_handle")
                local handle = field(item,"ItemRowHandle")
                local data_table = identity(field(handle,"DataTable"))
                local row = field(handle,"RowName"):ToString()
                if not data_table or type(row) ~= "string" then error("invalid_item_handle") end
                local id = wanted[data_table..":"..row]
                if not id or item_storage[id]~="container" then return end
                self:stage("item_quantity_and_brought_in")
                local count, flag = field(item,"Quantity"), field(item,"ItemBroughtIn")
                account(id,count,flag,identity(container),index)
            end)
        end)
        if containers == 0 then return { complete=false, reason="containers_not_ready" } end
        end
        local danglies, multi_slots, large_slots, seen_danglies = 0, 0, 0, {}
        if storage.dangly then
            local dangly_class=self.find_static("/Script/FWInventory.FWDanglyComponent")
            if not valid(dangly_class) then error("dangly_component_class_unavailable") end
            -- Both membership paths are game-owned rig properties. Never count
            -- world actors or an attachment owned by another rig.
            local function visit_dangly(dangly, index)
                large_slots=large_slots+1
                if large_slots>self.max_slots then error("total_dangly_slot_cap_exceeded") end
                local id=identity(dangly)
                if not id then return end -- empty native object slot
                if seen_danglies[id] then return end -- shared rig-list alias
                seen_danglies[id]=true
                danglies=danglies+1
                if danglies>self.max_slots then error("dangly_cap_exceeded") end
                local component_owner=identity(field(dangly,"OwningBackpackRig"))
                if component_owner~=rig_id then error("dangly_owner_mismatch:component="..id
                    ..":actual="..tostring(component_owner)..":expected="..rig_id) end
                local destroyed=field(dangly,"DanglyDestroyed")
                if type(destroyed)~="boolean" then error("invalid_dangly_destroyed") end
                if destroyed then return end
                local handle=field(dangly,"DanglyDetailsRow")
                local data_table=identity(field(handle,"DataTable"))
                local row=field(handle,"RowName"):ToString()
                if not data_table or type(row)~="string" then error("invalid_dangly_handle") end
                local item_id=wanted[data_table..":"..row]
                if item_id and item_storage[item_id]=="dangly" then
                    account(item_id,1,field(dangly,"ItemBroughtIn"),id,index)
                end
            end
            self:stage("rig_dangle_slots")
            array_each(field(rig,"DangleSlots"),self.max_slots,function(actor,index)
                local actor_id=identity(actor)
                if not actor_id then return visit_dangly(nil,index) end
                -- The cooked rig adds Actors here, while the multi-slot
                -- struct below holds components directly. Resolve only actors.
                self:stage("dangly_actor_component")
                local component=actor:GetComponentByClass(dangly_class)
                if not identity(component) then error("dangly_component_unavailable:"..actor_id) end
                visit_dangly(component,index)
            end)
            self:stage("rig_multi_dangly_slots")
            local seen_racks={}
            multi_slots=array_each(field(rig,"MultiRigDanglySlots"),self.max_containers,function(rack)
                local id=identity(rack)
                if not id then error("invalid_dangly_rack") end
                if seen_racks[id] then error("duplicate_dangly_rack") end
                seen_racks[id]=true
                array_each(field(rack,"Danglies"),self.max_slots,function(slot,index)
                    visit_dangly(field(slot,"Dangly"),index)
                end)
            end)
        end
        local result={complete=true,owner=owner,rig=rig_id,in_hub=owner:find(HUB,1,true)~=nil,
            items=items,containers=containers,slots=slots,active_slots=active_slots,
            danglies=danglies,multi_slots=multi_slots,rows=rows}
        if #targets==1 then
            local item=items[targets[1].canonical_item_id]
            result.total,result.brought_in=item.total,item.brought_in
            result.native_raid_flag_total=item.total-item.brought_in
        end
        return result
    end)
    if not ok then return { complete=false, reason="read_error:"..tostring(result), terminal_error=true } end
    return result
end

function Reader.verify_shapes(find_static, log, targets)
    find_static, log = find_static or StaticFindObject, log or function() end
    local container, dangly = targets==nil, false
    for _, target in ipairs(targets or {}) do
        container=container or target.storage=="container"
        dangly=dangly or target.storage=="dangly"
    end
    local shapes = {
        {"/Script/Engine.Controller", {Pawn="ObjectProperty"}},
        {"/Script/ForeverWinter.FWGamePlayerCharacter", {BackpackRig="ObjectProperty"}},
        {"/Script/ForeverWinter.SBackpackRig", {OwningPlayerCharacter="ObjectProperty"}},
    }
    if container then
        shapes[3][2].Containers="ArrayProperty"
        shapes[#shapes+1]={"/Script/FWInventory.FWRigContainersComponent",{Player="ObjectProperty",ItemsStored="ArrayProperty"}}
        shapes[#shapes+1]={"/Script/FWInventory.ContainerItem",{IsInUse="BoolProperty",ItemBroughtIn="BoolProperty",ItemRowHandle="StructProperty",Quantity="IntProperty"}}
    end
    if dangly then
        shapes[3][2].DangleSlots,shapes[3][2].MultiRigDanglySlots="ArrayProperty","ArrayProperty"
        shapes[#shapes+1]={"/Script/FWInventory.FWDanglyComponent",{OwningBackpackRig="ObjectProperty",DanglyDetailsRow="StructProperty",ItemBroughtIn="BoolProperty",DanglyDestroyed="BoolProperty"}}
        shapes[#shapes+1]={"/Script/FWInventory.FWMultiRigDanglySlot",{Danglies="ArrayProperty"}}
        shapes[#shapes+1]={"/Script/FWInventory.MultiRigDangly",{Dangly="ObjectProperty"}}
    end
    local ok, err = pcall(function()
        for _, shape in ipairs(shapes) do
            local object = find_static(shape[1])
            if not valid(object) then error("schema_unavailable:"..shape[1]) end
            local observed = {}
            object:ForEachProperty(function(property)
                local full = property:GetFullName()
                local name = full:match(":([^:]+)$")
                if name and shape[2][name] then observed[name] = full:match("^(%S+)") end
            end)
            for name, kind in pairs(shape[2]) do
                if observed[name] ~= kind then error("schema_mismatch:"..shape[1]..":"..name) end
            end
        end
    end)
    log("RETAINED INVENTORY SCHEMA accepted="..tostring(ok).." detail="..tostring(err or "retained_item_fields").." container="..tostring(container).." dangly="..tostring(dangly))
    return ok, err
end
return Reader
