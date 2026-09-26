-- Pure, completion-driven board policy. Persistence must succeed before commit.
-- A batch only draws from the reserve that existed before that batch; newly
-- completed cards enter the reserve after every replacement has been selected.
local Rotation = {}
Rotation.__index = Rotation
local MAX_REVISION = 9007199254740991

local function integer(value, minimum)
    return type(value)=="number" and value>=minimum and value<=MAX_REVISION and value==math.floor(value)
end
local function identity(value)
    return type(value)=="string" and value~="" and value:match("%S")~=nil and not value:find("%c")
end
local function plain(value, label)
    assert(type(value)=="table" and getmetatable(value)==nil, label.." must be a plain table")
end
local function array(value, label)
    plain(value,label)
    local count=0
    for key in pairs(value) do
        assert(integer(key,1),label.." must be a dense array")
        count=count+1
    end
    for index=1,count do assert(value[index]~=nil,label.." must be a dense array") end
    return count
end
local function copy_array(values)
    local result={}; for index,value in ipairs(values) do result[index]=value end; return result
end
local function copy_state(state)
    local receipts={}; for receipt,id in pairs(state.receipts) do receipts[receipt]=id end
    return {schema_version=1,revision=state.revision,offered=copy_array(state.offered),
        queue=copy_array(state.queue),receipts=receipts}
end
local function equal_state(first,second)
    if first.schema_version~=second.schema_version or first.revision~=second.revision or
        #first.offered~=#second.offered or #first.queue~=#second.queue then return false end
    for index,id in ipairs(first.offered) do if second.offered[index]~=id then return false end end
    for index,id in ipairs(first.queue) do if second.queue[index]~=id then return false end end
    for receipt,id in pairs(first.receipts) do if second.receipts[receipt]~=id then return false end end
    for receipt,id in pairs(second.receipts) do if first.receipts[receipt]~=id then return false end end
    return true
end
local function validate_state(self,state)
    plain(state,"rotation state")
    local fields={schema_version=true,revision=true,offered=true,queue=true,receipts=true}
    for key in pairs(state) do assert(fields[key],"unknown rotation state field: "..tostring(key)) end
    assert(state.schema_version==1,"unsupported rotation state schema")
    assert(integer(state.revision,0),"invalid rotation revision")
    assert(array(state.offered,"offered")<=self.capacity,"offered exceeds board capacity")
    array(state.queue,"queue")
    local seen,count={},0
    for _,list in ipairs({state.offered,state.queue}) do
        for _,id in ipairs(list) do
            assert(identity(id) and self.eligible[id],"rotation contains unknown contract identity")
            assert(not seen[id],"duplicate contract in rotation partition: "..id)
            seen[id]=true;count=count+1
        end
    end
    assert(count==#self.eligible_ids,"rotation catalog mismatch")
    for _,id in ipairs(self.eligible_ids) do assert(seen[id],"rotation catalog mismatch: "..id) end
    plain(state.receipts,"receipts")
    local receipt_count=0
    for receipt,id in pairs(state.receipts) do
        assert(identity(receipt),"invalid completion receipt identity")
        assert(identity(id) and self.eligible[id],"receipt names unknown contract identity")
        receipt_count=receipt_count+1
    end
    assert((state.revision==0 and receipt_count==0) or
        (state.revision>0 and receipt_count>=state.revision),"receipt history does not support rotation revision")
    return copy_state(state)
end

function Rotation.new(options,persisted_state)
    plain(options,"rotation options")
    assert(integer(options.capacity,1),"positive integer board capacity required")
    assert(array(options.eligible_ids,"eligible_ids")>0,"eligible catalog must not be empty")
    array(options.initial_ids,"initial_ids")
    assert(#options.initial_ids<=options.capacity,"initial board exceeds capacity")
    local self=setmetatable({capacity=options.capacity,eligible_ids={},eligible={}},Rotation)
    for index,id in ipairs(options.eligible_ids) do
        assert(identity(id),"invalid eligible contract identity")
        assert(not self.eligible[id],"duplicate eligible contract identity: "..id)
        self.eligible[id]=true;self.eligible_ids[index]=id
    end
    local initial_seen,initial_ids,queue={},{},{}
    for index,id in ipairs(options.initial_ids) do
        assert(identity(id) and self.eligible[id],"initial board contains unknown contract identity")
        assert(not initial_seen[id],"duplicate initial contract identity: "..id)
        initial_seen[id]=true;initial_ids[index]=id
    end
    for _,id in ipairs(self.eligible_ids) do if not initial_seen[id] then queue[#queue+1]=id end end
    if persisted_state==nil then
        self.state=validate_state(self,{schema_version=1,revision=0,offered=initial_ids,queue=queue,receipts={}})
    else
        -- A corrupt or incompatible save never silently becomes a new board.
        local ok,state=pcall(validate_state,self,persisted_state)
        local generations=options.append_only_generations
        if generations==nil and options.append_only_ids then generations={options.append_only_ids} end
        if not ok and generations then
            -- Ordered release generations. Accept only a complete older
            -- generation prefix and append its missing suffix at queue tail.
            -- This preserves offers, order, receipts and revision without
            -- accepting a board from a partially shipped generation.
            for missing=1,#generations do
                local added={}
                for generation=#generations-missing+1,#generations do
                    for _,id in ipairs(generations[generation]) do added[id]=true end
                end
                local legacy={capacity=self.capacity,eligible_ids={},eligible={}}
                for _,id in ipairs(self.eligible_ids) do
                    if not added[id] then legacy.eligible_ids[#legacy.eligible_ids+1]=id; legacy.eligible[id]=true end
                end
                local legacy_ok,old=pcall(validate_state,legacy,persisted_state)
                if legacy_ok then
                    for generation=#generations-missing+1,#generations do
                        for _,id in ipairs(generations[generation]) do old.queue[#old.queue+1]=id end
                    end
                    local current_ok,current=pcall(validate_state,self,old)
                    if current_ok then state=current;ok=true;break end
                end
            end
        end
        assert(ok,state)
        self.state=state
    end
    return self
end

function Rotation:snapshot() return copy_state(self.state) end
function Rotation:offered_ids() return copy_array(self.state.offered) end
function Rotation:is_offered(id)
    for _,offered in ipairs(self.state.offered) do if offered==id then return true end end
    return false
end

function Rotation:complete_batch(completions)
    local shape_ok=pcall(array,completions,"completion batch")
    if not shape_ok then return nil,false,"invalid_completion_batch" end
    local incoming_receipts,completed,completed_count={},{},0
    for _,completion in ipairs(completions) do
        if type(completion)~="table" or getmetatable(completion)~=nil then
            return nil,false,"invalid_completion"
        end
        for key in pairs(completion) do
            if key~="contract_id" and key~="receipt_id" then return nil,false,"invalid_completion_field" end
        end
        local id,receipt=completion.contract_id,completion.receipt_id
        if not identity(id) or not self.eligible[id] then return nil,false,"unknown_completion_contract" end
        if not identity(receipt) then return nil,false,"invalid_completion_receipt" end
        local known=self.state.receipts[receipt] or incoming_receipts[receipt]
        if known~=nil then
            if known~=id then return nil,false,"completion_receipt_conflict" end
            -- Exact replay is idempotent, even after the old card left the board
            -- or returned in a later rotation. It cannot complete that new offer.
        else
            if not self:is_offered(id) then return nil,false,"completion_contract_not_offered" end
            if completed[id] then return nil,false,"duplicate_contract_completion" end
            incoming_receipts[receipt]=id;completed[id]=true;completed_count=completed_count+1
        end
    end
    if completed_count==0 then return self:snapshot(),false,nil end
    if self.state.revision>=MAX_REVISION then return nil,false,"rotation_revision_exhausted" end
    local proposal=self:snapshot()
    proposal.revision=proposal.revision+1.0
    proposal.offered={};proposal.queue={}
    for _,id in ipairs(self.state.offered) do
        if not completed[id] then proposal.offered[#proposal.offered+1]=id end
    end
    local vacancies=self.capacity-#proposal.offered
    for index,id in ipairs(self.state.queue) do
        if index<=vacancies then proposal.offered[#proposal.offered+1]=id
        else proposal.queue[#proposal.queue+1]=id end
    end
    -- Original board order makes equivalent completion batches deterministic.
    for _,id in ipairs(self.state.offered) do
        if completed[id] then proposal.queue[#proposal.queue+1]=id end
    end
    for receipt,id in pairs(incoming_receipts) do proposal.receipts[receipt]=id end
    return proposal,true,nil
end

function Rotation:commit(state)
    local valid,candidate=pcall(validate_state,self,state)
    if not valid then return false,"invalid_rotation_state" end
    if equal_state(candidate,self.state) then return true,nil end
    if candidate.revision~=self.state.revision+1.0 then return false,"rotation_revision_conflict" end
    local completions={}
    for receipt,id in pairs(self.state.receipts) do
        if candidate.receipts[receipt]~=id then return false,"rotation_receipt_history_changed" end
    end
    for receipt,id in pairs(candidate.receipts) do
        if self.state.receipts[receipt]==nil then
            completions[#completions+1]={contract_id=id,receipt_id=receipt}
        end
    end
    -- Validate reachability as well as shape: a caller cannot rearrange the
    -- roster or fill vacancies by committing an arbitrary well-formed state.
    local expected,changed=self:complete_batch(completions)
    if not changed or not equal_state(candidate,expected) then return false,"rotation_proposal_mismatch" end
    self.state=candidate
    return true,nil
end

return Rotation
