-- Positive Unit-retirement proof contracts only; no game/native writes.
local ffi=require('ffi')
local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))
local Lifecycle=dofile(root..'/src/animation_lifecycle.lua')
local function bytes(kind,n)return ffi.string(ffi.new(kind..'[1]',n),ffi.sizeof(kind))end
local function fixture()
    local f={memory={},reads=0,modules=0,events={}}
    f.snapshot={game=0x100000000,exe=0x200000000,reference=2*4194304+3,
        registry=0x300000000,generations=0x400000000,units=0x500000000,
        unit=0x600000000,avatar=249,world=0x700000000,state=0x800000000,
        player=0x900000000,local_unit=71,pm=0xA00000000,row=0,
        descriptor=0xB00000000,desc='captured descriptor'}
    function f:put(at,s)for i=1,#s do self.memory[at+i-1]=s:sub(i,i)end end
    function f:u(at,n)self:put(at,bytes('uint32_t',n))end
    function f:p(at,n)self:put(at,bytes('uint64_t',n))end
    function f:read(at,size)
        self.reads=self.reads+1
        assert(at<self.snapshot.unit or at>=self.snapshot.unit+0x1000,'Old retired Unit was dereferenced')
        if self.forbid_old_arrays then
            assert(at~=self.snapshot.generations+3 and at~=self.snapshot.units+3*8,'Captured registry arrays were read after relocation')
        end
        if self.unreadable==at then return nil,'fixture unreadable'end
        local out={};for i=0,size-1 do out[#out+1]=self.memory[at+i]or'\0'end
        local result=table.concat(out)
        if self.on_read then self:on_read(at,size)end
        return result
    end
    f.io={read=function(...)return f:read(...)end,module=function(name)
        f.modules=f.modules+1
        if name=='game.dll'then return f.snapshot.game,0x4744000,f.game_stamp or 0x6AB3B43F end
        return f.snapshot.exe,0x2400000,f.exe_stamp or 0x6AB382E4
    end}
    f:p(f.snapshot.exe+0x1A100F0,f.snapshot.registry)
    f:u(f.snapshot.registry+0x98,10);f:p(f.snapshot.registry+0xA0,f.snapshot.generations)
    f:p(f.snapshot.registry+0x88,f.snapshot.units)
    f:put(f.snapshot.generations+3,'\2');f:p(f.snapshot.units+3*8,f.snapshot.unit)
    f.life=Lifecycle.new(f.io)
    return f
end
local passed=0
local function test(name,fn)local ok,why=pcall(fn);assert(ok,name..': '..tostring(why));passed=passed+1;print('PASS '..name)end
test('construction performs no reads or module lookup',function()
    local f=fixture();assert(f.reads==0 and f.modules==0)
end)
test('still-live reference is not retired by local actor or scene changes',function()
    local f=fixture();local proof,why=f.life:prove(f.snapshot)
    assert(not proof and why:find('still live',1,true))
    f.snapshot.avatar=250;f.snapshot.world=0x710000000;f.snapshot.state=0x810000000
    assert(not f.life:prove(f.snapshot))
end)
test('generation mismatch gives a fresh sealed positive retirement proof',function()
    local f=fixture();f:put(f.snapshot.generations+3,'\3')
    local proof,why=f.life:prove(f.snapshot);assert(proof,why)
    assert(proof.reason=='generation changed'and f.life:valid(proof,f.snapshot))
    assert(Lifecycle.valid(proof,f.snapshot))
    proof.reason='forged display field';assert(f.life:valid(proof,f.snapshot))
end)
test('replaced or null slot proves retirement without dereferencing the old Unit',function()
    for _,replacement in ipairs({0,0x610000000})do
        local f=fixture();f:p(f.snapshot.units+3*8,replacement)
        local proof=assert(f.life:prove(f.snapshot));assert(proof.reason=='slot replaced')
        assert(f.life:valid(proof,f.snapshot))
    end
end)
test('unreadable generation absent arrays changed registry and invalid bounds refuse proof',function()
    for _,kind in ipairs({'unreadable','registry','generations','units','bounds','stamp'})do
        local f=fixture();f:put(f.snapshot.generations+3,'\3')
        if kind=='unreadable'then f.unreadable=f.snapshot.generations+3
        elseif kind=='registry'then f:p(f.snapshot.exe+0x1A100F0,0x310000000)
        elseif kind=='generations'then f:p(f.snapshot.registry+0xA0,0)
        elseif kind=='units'then f:p(f.snapshot.registry+0x88,0)
        elseif kind=='bounds'then f:u(f.snapshot.registry+0x98,2)
        else f.exe_stamp=0 end
        assert(not f.life:prove(f.snapshot),kind)
    end
end)
local function relocate(f,which,generation,unit)
    local generations=which~='units' and 0x410000000 or f.snapshot.generations
    local units=which~='generations' and 0x510000000 or f.snapshot.units
    f:p(f.snapshot.registry+0xA0,generations);f:p(f.snapshot.registry+0x88,units)
    f:put(generations+3,string.char(generation or 2));f:p(units+3*8,unit==nil and f.snapshot.unit or unit)
    return generations,units
end
test('relocation resolving the captured generation and Unit remains live',function()
    for _,which in ipairs({'generations','units','both'})do
        local f=fixture();local original_gen,original_units=f.snapshot.generations,f.snapshot.units
        relocate(f,which)
        local proof,why=f.life:prove(f.snapshot)
        assert(not proof and why:find('still live',1,true),which..': '..tostring(why))
        assert(f.snapshot.generations==original_gen and f.snapshot.units==original_units,'Snapshot was rewritten')
    end
end)
test('current relocated arrays prove retirement without consulting captured allocations',function()
    for _,kind in ipairs({'generation','replacement','null'})do
        local f=fixture();local generations,units=relocate(f,'both',kind=='generation' and 3 or 2,
            kind=='replacement' and 0x610000000 or kind=='null' and 0 or f.snapshot.unit)
        f.forbid_old_arrays=true
        local proof,why=f.life:prove(f.snapshot);assert(proof,why)
        local valid,observation=f.life:valid(proof,f.snapshot);assert(valid)
        assert(observation.current_generations==generations and observation.current_units==units)
        assert(proof.reason==(kind=='generation' and 'generation changed' or 'slot replaced'))
        assert(f.snapshot.generations==0x400000000 and f.snapshot.units==0x500000000)
    end
end)
test('unreadable current relocated generation or slot does not prove retirement',function()
    for _,which in ipairs({'generations','units'})do
        local f=fixture();local generations,units=relocate(f,'both',3)
        f.unreadable=which=='generations' and generations+3 or units+3*8
        assert(not f.life:prove(f.snapshot))
    end
end)
test('torn relocated root bounds pointers generation and slot all refuse proof',function()
    for _,kind in ipairs({'root','count','generations','units','generation','slot'})do
        local f=fixture();local generations,units=relocate(f,'both',3)
        f.on_read=function(self,at)
            if at~=units+3*8 or self.changed then return end
            self.changed=true
            if kind=='root' then self:p(self.snapshot.exe+0x1A100F0,0x310000000)
            elseif kind=='count' then self:u(self.snapshot.registry+0x98,11)
            elseif kind=='generations' then self:p(self.snapshot.registry+0xA0,0x420000000)
            elseif kind=='units' then self:p(self.snapshot.registry+0x88,0x520000000)
            elseif kind=='generation' then self:put(generations+3,'\4')
            else self:p(units+3*8,0x610000000)end
        end
        local proof,why=f.life:prove(f.snapshot)
        assert(not proof and why:find('changed during',1,true),kind..': '..tostring(why))
    end
end)
test('a torn still-live relocation is rechecked rather than accepted as a coherent sample',function()
    local f=fixture();local _,units=relocate(f,'both')
    f.on_read=function(self,at)if at==units+3*8 then self:u(self.snapshot.registry+0x98,11)end end
    local proof,why=f.life:prove(f.snapshot);assert(not proof and why:find('changed during',1,true))
end)
test('proof remains sealed to original snapshot allocations after registry relocation',function()
    local f=fixture();local generations,units=relocate(f,'both',3)
    local proof=assert(f.life:prove(f.snapshot))
    local forged={};for key,value in pairs(f.snapshot)do forged[key]=value end
    forged.generations,forged.units=generations,units
    assert(not f.life:valid(proof,forged),'Relocation rewrote sealed provenance')
    relocate(f,'both',2,f.snapshot.unit)
    local valid,why=f.life:valid(proof,f.snapshot)
    assert(not valid and why:find('still live',1,true))
end)
test('torn registry observation refuses a positive proof',function()
    local f=fixture();f:put(f.snapshot.generations+3,'\3')
    f.on_read=function(self,at)
        if at==self.snapshot.units+3*8 then self:put(self.snapshot.generations+3,'\4')end
    end
    assert(not f.life:prove(f.snapshot))
end)
test('proof is rejected when registry once again resolves the captured live Unit',function()
    local f=fixture();f:put(f.snapshot.generations+3,'\3')
    local proof=assert(f.life:prove(f.snapshot));f:put(f.snapshot.generations+3,'\2')
    assert(not f.life:valid(proof,f.snapshot))
end)
test('forged proofs other lifecycle owners and different consumer snapshots are refused',function()
    local f=fixture();f:put(f.snapshot.generations+3,'\3');local proof=assert(f.life:prove(f.snapshot))
    assert(not Lifecycle.valid({version=1,kind='bridge_unit_retired'},f.snapshot))
    assert(not Lifecycle.new(f.io):valid(proof,f.snapshot))
    local other={};for k,v in pairs(f.snapshot)do other[k]=v end;other.reference=other.reference+1
    assert(not f.life:valid(proof,other))
end)
test('cleanup retires consumers before clip release and package release',function()
    local f=fixture();f:put(f.snapshot.generations+3,'\3');local proof=assert(f.life:prove(f.snapshot))
    local function consumer(name)return{retire=function(_,p)
        assert(f.life:valid(p,f.snapshot));f.events[#f.events+1]=name;return true
    end}end
    local clips={release_retired=function(_,p)assert(f.life:valid(p,f.snapshot));f.events[#f.events+1]='clips';return true end}
    local packages={release=function()f.events[#f.events+1]='packages';return true end}
    assert(f.life:cleanup(proof,{consumer('pose'),consumer('idle')},clips,packages))
    assert(table.concat(f.events,',')=='pose,idle,clips,packages')
end)
test('pending consumer or conservative clip floor prevents subsequent releases',function()
    for _,phase in ipairs({'consumer','clips'})do
        local f=fixture();f:put(f.snapshot.generations+3,'\3');local proof=assert(f.life:prove(f.snapshot))
        local consumer={retire=function()f.events[#f.events+1]='consumer';return phase~='consumer','retirement pending'end}
        local clips={release_retired=function()f.events[#f.events+1]='clips';return false,'Final reference retained'end}
        local packages={release=function()error('Package released before clip retirement acknowledgement')end}
        local ok,why=f.life:cleanup(proof,{consumer},clips,packages)
        assert(not ok and type(why)=='string')
        assert(table.concat(f.events,',')==(phase=='consumer'and'consumer'or'consumer,clips'))
    end
end)
print(('Animation lifecycle: %d contracts passed'):format(passed))
