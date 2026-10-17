-- Positive Unit-retirement proofs and ordered cleanup coordination only.
-- Never writes game memory, invokes a native state setter, or changes ref floors.
-- Import/new perform no game access. Current player/scene changes are not proof.
local M={}
local proofs=setmetatable({}, {__mode='k'})
local FIELDS={'game','exe','reference','registry','generations','units','unit','avatar',
    'world','state','player','local_unit','pm','row','descriptor','desc'}
local function integer(value,maximum)
    return type(value)=='number' and value==math.floor(value) and value>=0 and value<=maximum
end
local function u32(bytes,off)
    off=off or 0
    if type(bytes)~='string' or #bytes<off+4 then return end
    local a,b,c,d=bytes:byte(off+1,off+4);return a+b*256+c*65536+d*16777216
end
local function pointer(bytes)
    local a,b=u32(bytes),u32(bytes,4)
    local value=a and b and a+b*4294967296
    assert(value==0 or value and value>=65536 and value<2^47,'Retirement pointer is invalid')
    return value
end
local function protected(fn)
    local ok,a,b=pcall(fn);if not ok then return nil,tostring(a)end;return a,b
end
local function same(snapshot,original)
    if type(snapshot)~='table' then return false,'Retirement snapshot is absent' end
    for _,key in ipairs(FIELDS)do
        if snapshot[key]~=original[key] then return false,'Retirement snapshot differs: '..key end
    end
    return true
end
function M.new(io)
    assert(type(io)=='table' and type(io.module)=='function' and type(io.read)=='function',
        'Protected animation lifecycle IO is required')
    local self={}
    local function read(at,size)
        assert(integer(at,2^47-1) and at>=65536 and integer(size,64) and size>0
            and at+size<2^47,'Retirement read bounds differ')
        local b,why=io.read(at,size);assert(type(b)=='string' and #b==size,why or 'Retirement memory is unreadable')
        return b
    end
    local function inspect(s)
        assert(type(s)=='table' and integer(s.reference,0xFFFFFFFE) and s.reference>0
            and integer(s.unit,2^47-1) and s.unit>=65536,'Captured Unit identity is invalid')
        local exe,_,stamp=io.module('helldivers2.exe')
        assert(exe==s.exe and stamp==0x6AB382E4,'Retirement executable identity changed')
        local game,_,game_stamp=io.module('game.dll')
        assert(game==s.game and game_stamp==0x6AB3B43F,'Retirement game identity changed')
        local root=read(exe+0x1A100F0,8)
        local registry=pointer(root)
        assert(registry==s.registry and registry~=0,'Unit registry identity changed; retirement is unproven')
        local count_bytes=read(registry+0x98,4);local count=u32(count_bytes)
        local generations_bytes,units_bytes=read(registry+0xA0,8),read(registry+0x88,8)
        local generations,units=pointer(generations_bytes),pointer(units_bytes)
        -- The registry can relocate either backing array while retaining the
        -- same live reference. Inspect its current arrays; captured allocation
        -- addresses remain sealed provenance, not a liveness requirement.
        assert(generations~=0 and units~=0,'Unit registry arrays are absent; retirement is unproven')
        local index=s.reference%4194304;local generation=math.floor(s.reference/4194304)
        assert(generation<256 and count>0 and count<=0x1000000 and index<count,'Unit registry slot is unavailable')
        local generation_byte=read(generations+index,1)
        local slot=read(units+index*8,8);local current=pointer(slot)
        local reason
        if generation_byte:byte()~=generation then reason='generation changed'
        elseif current~=s.unit then reason='slot replaced' end
        -- A two-phase read prevents a torn registry observation from becoming a
        -- retirement proof. Never dereference the captured old Unit address.
        assert(read(exe+0x1A100F0,8)==root and read(registry+0x98,4)==count_bytes
            and read(registry+0xA0,8)==generations_bytes and read(registry+0x88,8)==units_bytes
            and read(generations+index,1)==generation_byte and read(units+index*8,8)==slot,
            'Unit registry changed during retirement observation')
        if not reason then
            return nil,'Captured Unit is still live; local actor or scene changes alone are insufficient'
        end
        return {reason=reason,index=index,current_generation=generation_byte:byte(),
            current_unit=current,current_generations=generations,current_units=units,
            registry=registry,reference=s.reference,unit=s.unit}
    end
    function self:prove(snapshot)
        return protected(function()
            local observation,why=inspect(snapshot);assert(observation,why)
            local original={};for _,key in ipairs(FIELDS)do original[key]=snapshot[key]end
            local proof={version=1,kind='bridge_unit_retired',reason=observation.reason,
                reference=observation.reference,unit=observation.unit,registry=observation.registry}
            proofs[proof]={owner=self,snapshot=original,inspect=inspect}
            return proof
        end)
    end
    function self:valid(proof,snapshot)
        local entry=proofs[proof]
        if not entry or entry.owner~=self then return false,'Retirement proof belongs to another lifecycle' end
        return M.valid(proof,snapshot)
    end
    -- Helpers implement retire/release_retired using M.valid or the owning
    -- lifecycle callback. The coordinator does not clear unknown journals itself.
    function self:cleanup(proof,consumers,clips,packages)
        return protected(function()
            local entry=proofs[proof];assert(entry and entry.owner==self,'Retirement proof is not owned')
            assert(self:valid(proof,entry.snapshot))
            assert(type(consumers)=='table','Retirement consumers are required')
            for _,consumer in ipairs(consumers)do
                assert(type(consumer)=='table' and type(consumer.retire)=='function',
                    'Animation consumer has no retirement acknowledgement')
                local ok,why=consumer:retire(proof);assert(ok==true,why or 'Animation consumer retirement is pending')
            end
            if clips then
                assert(type(clips.release_retired)=='function','Clip retirement release is unavailable')
                local ok,why=clips:release_retired(proof);assert(ok==true,why or 'Retired clip release is pending')
            end
            if packages then
                assert(type(packages.release)=='function','Package release is unavailable')
                local ok,why=packages:release();assert(ok==true,why or 'Package release is pending')
            end
            return true
        end)
    end
    return self
end
function M.valid(proof,snapshot)
    local entry=proofs[proof]
    if not entry then return false,'Retirement proof was not issued by this module' end
    local equal,why=same(snapshot,entry.snapshot);if not equal then return false,why end
    local observation,reason=protected(function()return entry.inspect(entry.snapshot)end)
    if not observation then return false,reason end
    return true,observation
end
return M
