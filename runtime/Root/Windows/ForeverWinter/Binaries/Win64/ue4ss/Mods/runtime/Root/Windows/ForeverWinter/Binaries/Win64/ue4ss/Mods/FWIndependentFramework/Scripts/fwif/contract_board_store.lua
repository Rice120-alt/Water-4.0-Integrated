-- Primitive append-only board journal. State is data, never executable Lua.
-- FWCB2 stores one baseline then roster snapshots with new receipt bindings
-- only. The accumulated receipt map is reconstructed once when reopening.
local Store = {}
Store.__index = Store
local MAX_FILE = 32 * 1024 * 1024
local MAX_RECORD = 1024 * 1024
local MAX_ENTRIES = 10000
local MAX_REVISION = 1000000

local function integer(v, maximum)
    return type(v)=="number" and v>=0 and v<=maximum and v==math.floor(v)
end
local function id(v)
    return type(v)=="string" and #v>0 and #v<=256 and v:match("^[A-Za-z0-9_:%.-]+$")~=nil
end
local function array(v, membership)
    if type(v)~="table" then return nil end
    local count=0
    for k in pairs(v) do
        if not integer(k,MAX_ENTRIES) or k<1 then return nil end
        count=count+1
    end
    local result={}
    for i=1,count do
        if not id(v[i]) or membership[v[i]] then return nil end
        membership[v[i]]=true;result[i]=v[i]
    end
    return result
end
local function validate(s)
    if type(s)~="table" or s.schema_version~=1 or not integer(s.revision,MAX_REVISION) then
        return nil,"invalid_schema_or_revision"
    end
    for k in pairs(s) do
        if k~="schema_version" and k~="revision" and k~="offered" and k~="queue" and k~="receipts" then
            return nil,"unknown_state_field"
        end
    end
    local membership={}
    local offered=array(s.offered,membership)
    local queue=array(s.queue,membership)
    if not offered or not queue or type(s.receipts)~="table" then return nil,"invalid_state_arrays" end
    local receipts,count={},0
    for key,contract in pairs(s.receipts) do
        count=count+1
        if count>MAX_ENTRIES or not id(key) or not id(contract) then return nil,"invalid_receipt" end
        receipts[key]=contract
    end
    return {schema_version=1,revision=s.revision,offered=offered,queue=queue,receipts=receipts}
end
local function receipt_extension(prior,next_state)
    for key,contract in pairs(prior and prior.receipts or {}) do
        if next_state.receipts[key]~=contract then return false end
    end
    return true
end
local function new_receipts(prior,next_state)
    local delta,count={},0
    for key,contract in pairs(next_state.receipts) do
        if not prior or prior.receipts[key]==nil then delta[key]=contract;count=count+1 end
    end
    return delta,count
end
local function checksum(s)
    -- Keep each arithmetic intermediate portable to 32-bit Lua/Fengari.
    local a,b=1,0
    for i=1,#s do a=(a+s:byte(i))%65521;b=(b+a)%65521 end
    return string.format("%04x%04x",b,a)
end
local function encode(s,kind)
    assert(kind=="B" or kind=="D","journal record kind required")
    local keys,receipts={},{}
    for key in pairs(s.receipts) do keys[#keys+1]=key end
    table.sort(keys)
    for _,key in ipairs(keys) do receipts[#receipts+1]=key.."="..s.receipts[key] end
    local payload=table.concat({"1",kind,string.format("%.0f",s.revision),tostring(#s.offered),table.concat(s.offered,","),
        tostring(#s.queue),table.concat(s.queue,","),tostring(#keys),table.concat(receipts,",")},"|")
    if #payload>MAX_RECORD then return nil,"record_too_large" end
    return "FWCB2|"..#payload.."|"..checksum(payload).."|"..payload.."\n"
end
local function split(s,separator)
    local result={}
    for v in (s..separator):gmatch("(.-)"..separator) do result[#result+1]=v end
    return result
end
local function number(s,maximum)
    if type(s)~="string" or not s:match("^%d+$") then return nil end
    local n=tonumber(s)
    if not integer(n,maximum) or tostring(n)~=s then return nil end
    return n
end
local function parse_record(line)
    local length,hash,payload=line:match("^FWCB2|(%d+)|([0-9a-f]+)|(.+)$")
    if not length or number(length,MAX_RECORD)~=#payload or #hash~=8 or checksum(payload)~=hash then
        return nil,"record_length_or_checksum"
    end
    local fields=split(payload,"|")
    if #fields~=9 or fields[1]~="1" or (fields[2]~="B" and fields[2]~="D") then return nil,"record_schema" end
    local kind=fields[2]
    local revision=number(fields[3],MAX_REVISION)
    local offered_count=number(fields[4],MAX_ENTRIES)
    local queue_count=number(fields[6],MAX_ENTRIES)
    local receipt_count=number(fields[8],MAX_ENTRIES)
    if not revision or not offered_count or not queue_count or not receipt_count then return nil,"record_numbers" end
    local offered=fields[5]=="" and {} or split(fields[5],",")
    local queue=fields[7]=="" and {} or split(fields[7],",")
    local receipt_parts=fields[9]=="" and {} or split(fields[9],",")
    if #offered~=offered_count or #queue~=queue_count or #receipt_parts~=receipt_count then return nil,"record_counts" end
    local receipts={}
    for _,entry in ipairs(receipt_parts) do
        local key,contract=entry:match("^([^=]+)=([^=]+)$")
        if not key or receipts[key] then return nil,"record_receipts" end
        receipts[key]=contract
    end
    local state,reason=validate({schema_version=1,revision=revision,offered=offered,queue=queue,receipts=receipts})
    if not state then return nil,reason end
    if encode(state,kind)~=line.."\n" then return nil,"record_noncanonical" end
    return state,nil,kind
end
local function decode(raw)
    if #raw==0 then return nil,"empty_existing_journal" end
    if #raw>MAX_FILE then return nil,"journal_too_large" end
    if raw:sub(-1)~="\n" then return nil,"truncated_tail" end
    local previous,expected,receipts,receipt_count=nil,0,{},0
    for line in raw:gmatch("([^\n]*)\n") do
        local state,reason,kind=parse_record(line)
        if not state then return nil,reason end
        if state.revision~=expected then return nil,"revision_gap_or_duplicate" end
        if kind~=(expected==0 and "B" or "D") then return nil,"record_kind_order" end
        local added=0
        for key,contract in pairs(state.receipts) do
            -- A delta may never repeat an earlier receipt, even with the same
            -- binding. Replayed revisions are separately rejected above.
            if receipts[key]~=nil then return nil,"receipt_reused_in_delta" end
            receipts[key]=contract;receipt_count=receipt_count+1;added=added+1
            if receipt_count>MAX_ENTRIES then return nil,"receipt_history_too_large" end
        end
        if kind=="D" and added==0 then return nil,"empty_receipt_delta" end
        state.receipts=receipts
        previous=state;expected=expected+1
    end
    return previous
end
local function close(file)
    local ok,result=pcall(function() return file:close() end)
    return ok and result~=nil and result~=false
end
function Store.new(options)
    options=options or {}
    local path=options.path
    assert(type(path)=="string" and not path:find("[%z\r\n]") and
        (path:match("^[A-Za-z]:[/\\]") or path:match("^[/\\][/\\]") or path:sub(1,1)=="/"),
        "absolute board journal path required")
    return setmetatable({path=path,fs=options.io or io,loaded=false,raw=nil,state=nil,blocked=nil},Store)
end
function Store:fail(reason)
    self.blocked=reason
    return nil,reason
end
function Store:read()
    local ok,file,err,code=pcall(function() return self.fs.open(self.path,"rb") end)
    if not ok then return nil,"read_open_exception" end
    if not file then
        if code==2 or err=="missing" then return nil,"missing" end
        return nil,"read_open_failed"
    end
    local read_ok,raw=pcall(function() return file:read("*a") end)
    local closed=close(file)
    if not closed then return nil,"read_close_failed" end
    if not read_ok or type(raw)~="string" then return nil,"read_failed" end
    return raw
end
function Store:load()
    if self.blocked then return nil,"unavailable:"..self.blocked end
    local raw,reason=self:read()
    if not raw and reason~="missing" then return self:fail("unavailable:"..reason) end
    if self.loaded then
        if raw~=self.raw then return self:fail("unavailable:journal_changed_since_load") end
        if self.state then return validate(self.state) end
        return nil,"missing"
    end
    if not raw then self.loaded=true;return nil,"missing" end
    local state,decode_reason=decode(raw)
    if not state then return self:fail("corrupt:"..decode_reason) end
    self.loaded,self.raw,self.state=true,raw,state
    return validate(state)
end
function Store:save(proposal)
    if self.blocked then return nil,"unavailable:"..self.blocked end
    local state,reason=validate(proposal)
    if not state then return nil,reason end
    if not self.loaded then
        local _,load_reason=self:load()
        if self.blocked or (load_reason and load_reason~="missing") then return nil,load_reason end
    end
    local expected=self.state and self.state.revision+1 or 0
    if state.revision~=expected then return nil,"stale_revision" end
    if not receipt_extension(self.state,state) then return nil,"receipt_rewritten_or_removed" end
    local delta,delta_count=new_receipts(self.state,state)
    if self.state and delta_count==0 then return nil,"empty_receipt_delta" end
    local kind=self.state and "D" or "B"
    local record_state={schema_version=1,revision=state.revision,
        offered=state.offered,queue=state.queue,receipts=delta}
    local record,encode_reason=encode(record_state,kind)
    if not record then return nil,encode_reason end
    local before,read_reason=self:read()
    if (not before and read_reason~="missing") or before~=self.raw then
        return self:fail("unavailable:prior_readback_mismatch")
    end
    local target=(self.raw or "")..record
    if #target>MAX_FILE then return nil,"journal_too_large" end
    -- From append-open onward, any error is ambiguous: never retry or reset.
    local open_ok,file=pcall(function() return self.fs.open(self.path,"ab") end)
    if not open_ok or not file then return self:fail("unavailable:append_open_failed") end
    local write_ok,written=pcall(function() return file:write(record) end)
    local flush_ok,flushed=pcall(function() return file:flush() end)
    local closed=close(file)
    if not write_ok or written==nil or written==false or not flush_ok or flushed==nil or flushed==false or not closed then
        return self:fail("unavailable:append_uncertain")
    end
    local after=self:read()
    if after~=target then return self:fail("unavailable:append_readback_mismatch") end
    -- The exact prior bytes were already verified on load/previous append and
    -- checked unchanged above. Verify the appended record's complete checksum
    -- and canonical payload without replaying the whole history per write.
    local observed,decode_reason,observed_kind=parse_record(after:sub(#(self.raw or "")+1,-2))
    if not observed or observed.revision~=state.revision or observed_kind~=kind then
        return self:fail("unavailable:append_verification_failed:"..tostring(decode_reason))
    end
    self.raw,self.state=after,state
    return true
end
return Store
