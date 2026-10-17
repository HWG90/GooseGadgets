-- Isolated fake engine memory; never attaches to the game.
local ffi=require('ffi')
local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))
local M=assert(loadfile(root..'/tools/live_bridge_exit_state.lua'))()
local FP='4585c00f848000000048895c241048896c24184889742420'
local function unhex(value) return (value:gsub('..',function(pair)return string.char(tonumber(pair,16))end))end
local function fixture()
    local f={bytes={},calls={},reads=0,definitions={},layer_addresses={},guard_calls=0,expected_clip_count=2}
    local game,exe,pm,ep,state=0x100000000,0x200000000,0x300000000,0x400000000,0x500000000
    local reg,gens,units,unit=0x600000000,0x600001000,0x600002000,0x700000000
    local animator,graph,states,blender,curves=0x800000000,0x900000000,0xA00000000,0xB00000000,0xC00000000
    local A={base=game,stamp=0x6AB3B43F,GAME_STATE=0x100,STATE_VALUE=0x20,WORLD=0x108,PLAYER=0x110}
    function f:put(at,bytes)for i=1,#bytes do self.bytes[at+i-1]=bytes:sub(i,i)end end
    function f:u(at,v)self:put(at,ffi.string(ffi.new('uint32_t[1]',v),4))end
    function f:p(at,v)self:put(at,ffi.string(ffi.new('uint64_t[1]',v),8))end
    function f:getp(at)local v=ffi.new('uint64_t[1]');ffi.copy(v,self:read(at,8),8);return tonumber(v[0])end
    function f:read(at,size)
        assert(not self.old_generations_read or at~=self.old_generations_read,'Old generation array was dereferenced')
        assert(not self.old_units_read or at~=self.old_units_read,'Old Unit array was dereferenced')
        self.reads=self.reads+1;local parts={};for i=0,size-1 do parts[#parts+1]=self.bytes[at+i]or'\0'end
        local value=table.concat(parts);if self.on_read then self:on_read(at,size)end;return value
    end
    f:p(game+A.GAME_STATE,state);f:u(state+A.STATE_VALUE,3);f:p(game+0x3326D20,pm);f:p(pm+0x110,ep)
    f:p(game+A.WORLD,0x500001000);f:p(game+A.PLAYER,0x500002000);f:u(0x500002000+0x3A8,1)
    f:u(ep+8,249);f:u(ep+12,1);f:u(ep+20,1)
    f:p(exe+0x1A100F0,reg);f:u(reg+0x98,10);f:p(reg+0xA0,gens);f:p(reg+0x88,units)
    f:p(units+8,unit);f:u(unit+8,1);f:put(unit+0x358,unhex('97fa4d294d331c4d'))
    f:p(unit+0x178,animator);f:p(animator+0x28,graph);f:u(graph+4,31);f:u(graph+8,0x80)
    f:p(animator+0x50,states);f:p(unit+0x168,blender);f:p(animator+0x30,blender)
    f:u(animator+0x1B0,31);f:p(animator+0x1B8,curves)
    f:p(blender+0x380,0xB00010000)
    f:put(exe+0x554440,unhex(FP))
    for index=0,30 do f:p(states+index*8,graph+0xF0000+index*0x100)end
    local next_clip=100
    for _,s in ipairs({{0,0,59,124,0x1000,1,1}})do
        local layer=graph+0x80+s[5];f:u(graph+0x84+s[1]*4,s[5]);f:u(layer,0x12C);f:u(layer+4,59);f:u(layer+8,s[4])
        f.definitions[s[1]]={};f.layer_addresses[s[1]]=layer
        for index=0,s[4]-1 do
            f:u(layer+12+index*4,0x400+index*0x400);f.definitions[s[1]][index]=layer+0x400+index*0x400
        end
        for which=2,3 do
            local node=layer+0x400+s[which]*0x400;f.definitions[s[1]][s[which]]=node
            local clips=s[which+4];f:u(node+0xC,clips);f:u(node+0x10,0xA8)
            for index=0,clips-1 do f:p(node+0xA8+index*8,next_clip);next_clip=next_clip+1 end
            f:put(node+0xA8,unhex(s[which]==0 and '4ab5490c9f6bc1c2' or 'd096127f27089c75'))
        end
        f:p(states+s[1]*8,f.definitions[s[1]][s[2]])
    end
    local target=f.definitions[0][59]
    f:u(target+8,3);f:u(target+0x6C,16);f:u(target+0x70,1);f:u(target+0x74,0xB0)
    f:u(target+0x90,6);f:u(target+0x94,0x3BC);f:u(target+0xB0,3)
    function f:exit_event(index)
        local node=self.definitions[0][index]
        self:u(node+0x28,1);self:u(node+0x2C,0x100)
        self:u(node+0x100,0xF78B4078);self:u(node+0x104,0)
        self:u(node+0x30,1);self:u(node+0x34,0x110)
        self:u(node+0x110,59);self:u(node+0x114,0x3E4CCCCD)
    end
    for i=0,10 do f:exit_event(i)end
    f.states,f.graph,f.state,f.ep,f.setter,f.blender=states,graph,state,ep,exe+0x554440,blender
    f.io={read=function(...)return f:read(...)end,addresses=function()return A end,avatar=function()return 249 end,
        module=function()return exe,0,0x6AB382E4 end,hashmap=function(at,key)assert(at==pm+0xF8 and key==249);return 0 end,
        game=function()return game end,native=function(at,abi,fp,name)
            assert(at==f.setter and fp==FP and name=='BRIDGE_EXIT_STATE')
            assert(abi=='void (*)(void *, const int32_t *, uint32_t)')
            return function(instance,array,count)
                assert(tonumber(ffi.cast('uintptr_t',instance))==animator and count==1)
                local call={kind='partial'};for index=0,count-1 do call[index]=tonumber(array[index])end;f.calls[#f.calls+1]=call
                for index=0,count-1 do
                    if call[index]~=-1 and index~=f.skip_layer then
                        assert(f.definitions[index]and f.definitions[index][call[index]],'Invalid fake state')
                        f:p(states+index*8,f.definitions[index][call[index]])
                        if f.throw_native then error('Injected interrupted native call')end
                    end
                end
                if f.change_other then f:p(states+8,graph+0xFE000)end
                if f.on_native then f:on_native(call)end
            end
        end}
    function f:guard(snapshot,clips)
        self.guard_calls=self.guard_calls+1
        assert(snapshot.avatar==249 and #clips==self.expected_clip_count)
        for _,clip in ipairs(clips)do assert(#clip.bytes==8 and clip.type=='931e336d7646cc26')end
        if self.on_guard then self:on_guard()end
        return not self.refuse_residency
    end
    f.controller=M.new(function(...)return f:guard(...)end,f.io)
    return f
end
local passed=0
local function test(name,callback)
    local ok,why=pcall(callback);assert(ok,name..': '..tostring(why))
    passed=passed+1;print('PASS '..name)
end
local function relocate(f,s,both)
    local index=s.reference%4194304;local generations=s.generations+0x100000
    local units=both and s.units+0x200000 or s.units
    f:put(generations+index,string.char(math.floor(s.reference/4194304)))
    if both then f:p(units+index*8,s.unit)end
    f:p(s.registry+0xA0,generations);f:p(s.registry+0x88,units);f:u(s.registry+0x98,32)
    f.old_generations_read=s.generations+index;if both then f.old_units_read=s.units+index*8 end
    return generations,units,index
end
local function up(fn,key)
    for index=1,100 do local name,value=debug.getupvalue(fn,index)
        if name==key then return value,index end;if not name then break end
    end
    error('Missing expected fixture closure: '..key)
end
test('one shared idle same-cell replacement repairs pending cleanup without journal changes',function()
    local f=fixture();local recheck=up(f.controller.capture,'recheck');local fresh,index=up(recheck,'same')
    local readback=up(f.controller.apply,'selected_readback');assert(up(readback,'same')==fresh)
    debug.setupvalue(recheck,index,function(s,v)
        assert(s.generations==v.generations and s.units==v.units,'Legacy array identity guard');return fresh(s,v)
    end)
    local s=assert(f.controller:capture());assert(f.controller:apply(s));local journal=f.controller.journal
    relocate(f,s,true);assert(not f.controller:restore()and f.controller.journal==journal and #f.calls==1)
    debug.setupvalue(recheck,index,fresh);assert(up(readback,'same')==fresh)
    assert(f.controller:restore()and #f.calls==2 and journal.snapshot==s)
end)
test('coherent current registry array relocation restores exact idle owner without changing its snapshot',function()
    for _,both in ipairs({false,true})do
        local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s))
        local old_generations,old_units=s.generations,s.units;relocate(f,s,both)
        assert(f.controller:restore());assert(#f.calls==2 and s.generations==old_generations and s.units==old_units)
    end
end)
test('coherent relocation inside idle clip guard preserves exact count1 selection',function()
    local f=fixture();local s=assert(f.controller:capture())
    f.on_guard=function(self)self.on_guard=nil;relocate(self,s,true)end
    assert(f.controller:apply(s)and #f.calls==1 and f.controller:restore())
end)
test('changed generation slot or body after relocation cannot restore the old idle',function()
    for _,kind in ipairs({'generation','slot','body'})do
        local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s))
        local generations,units,index=relocate(f,s,true)
        if kind=='generation'then f:put(generations+index,'\1')
        elseif kind=='slot'then f:p(units+index*8,s.unit+0x1000)
        else f:put(s.unit+0x358,string.rep('\0',8))end
        assert(not f.controller:restore()and #f.calls==1 and f.controller.journal,kind)
    end
end)
test('torn current registry proof refuses idle cleanup before any native setter',function()
    local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s))
    local generations,units,index=relocate(f,s,true);local slot_reads=0
    f.on_read=function(self,at)
        if at==units+index*8 then
            slot_reads=slot_reads+1
            if slot_reads==2 then self:p(s.registry+0xA0,generations+0x1000);self:put(generations+0x1000+index,'\0')end
        end
    end
    assert(not f.controller:restore()and #f.calls==1 and f.controller.journal)
end)
test('constructor performs no IO',function()
    local f=fixture();assert(f.reads==0 and #f.calls==0)
end)
test('target59 selection and restoration use only partial setter count1',function()
    local f=fixture();local s=assert(f.controller:capture());assert(#s.clips==2)
    assert(s.layers[1].layer==0 and s.layers[1].old==0 and s.layers[1].target==59)
    local keys={};for _,clip in ipairs(s.clips)do keys[clip.hex]=true end
    assert(keys.c2c16b9f0c49b54a and keys['759c08277f1296d0'])
    local before=f:read(f.states,31*8)
    assert(f.controller:apply(s));assert(f.controller:status()=='active' and #f.calls==1)
    assert(f.calls[1].kind=='partial' and f.calls[1][0]==59)
    assert(f:read(f.states+8,30*8)==before:sub(9))
    assert(f.controller:restore());assert(#f.calls==2 and f.calls[2].kind=='partial' and f.calls[2][0]==0)
    assert(f:read(f.states,31*8)==before and f.controller:status()=='inactive')
end)
test('current bridge state3 captures its own clip and restores state3',function()
    local f=fixture();local old=f.definitions[0][3]
    f:u(old+0xC,1);f:u(old+0x10,0xA8);f:p(old+0xA8,900);f:p(f.states,old)
    local s=assert(f.controller:capture());assert(s.layers[1].old==3 and #s.clips==2)
    assert(f.controller:apply(s));assert(f.controller:restore());assert(f.calls[2][0]==3)
end)
test('already59 validates target but needs no apply or restore call',function()
    local f=fixture();f:p(f.states,f.definitions[0][59]);f.expected_clip_count=1
    local s=assert(f.controller:capture());assert(#s.clips==0)
    assert(f.controller:apply(s) and f.controller:restore() and #f.calls==0)
end)
test('authored default59 remains mandatory independently of preserved movement',function()
    local f=fixture();f:u(f.layer_addresses[0]+4,0)
    assert(not f.controller:capture() and #f.calls==0)
end)
test('exact target metadata registration and both clip identities are required',function()
    for _,kind in ipairs({'targetclip','idleclip','registration','mask'})do
        local f=fixture();local target=f.definitions[0][59]
        if kind=='targetclip'then f:p(target+0xA8,900)
        elseif kind=='idleclip'then f:p(f.definitions[0][0]+0xA8,900)
        elseif kind=='registration'then f:u(target+0xB0,4)
        else f:u(target+0x6C,0)end
        assert(not f.controller:capture() and #f.calls==0,kind)
    end
end)
test('authored mapping remains exact and isolated before direct selection',function()
    for _,kind in ipairs({'missing','duplicate','conditional','wrongtarget','wrongblend','otherlayer'})do
        local f=fixture();local old=f.definitions[0][0]
        if kind=='missing'then f:u(old+0x100,0)
        elseif kind=='duplicate'then
            f:u(old+0x28,2);f:u(old+0x108,0xF78B4078);f:u(old+0x10C,0)
        elseif kind=='conditional'then f:u(old+0x104,0x80000000)
        elseif kind=='wrongtarget'then f:u(old+0x110,60)
        elseif kind=='wrongblend'then f:u(old+0x114,0)
        else
            local other=f:getp(f.states+8)
            f:u(other+0x28,1);f:u(other+0x2C,0x100);f:u(other+0x100,0xF78B4078)
        end
        assert(not f.controller:capture()and #f.calls==0,kind)
    end
end)
test('clip lease refusal prevents partial selection',function()
    local f=fixture();local s=assert(f.controller:capture());f.refuse_residency=true
    local ok,why=f.controller:apply(s);assert(not ok and why:find('clip lease guard',1,true))
    assert(#f.calls==0 and f.controller:restore())
end)
test('actor retirement between capture and apply refuses native call',function()
    local f=fixture();local s=assert(f.controller:capture());f:u(f.ep+20,0)
    assert(not f.controller:apply(s) and #f.calls==0)
end)
test('actor replacement during restore retains pending without another call',function()
    local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s))
    f:u(f.ep+8,250);assert(not f.controller:restore())
    assert(#f.calls==1 and f.controller:status()=='cleanup pending')
end)
test('apply exception retains uncertain ownership without replay',function()
    local f=fixture();local s=assert(f.controller:capture());f.throw_native=true
    assert(not f.controller:apply(s));f.throw_native=false
    local ok,why=f.controller:restore();assert(not ok and why:find('did not return',1,true))
    assert(#f.calls==1 and f.controller:status()=='cleanup pending')
end)
test('mutation of another layer fails all31 readback and remains foreign',function()
    local f=fixture();local s=assert(f.controller:capture());f.change_other=true
    local ok,why=f.controller:apply(s);assert(not ok and why:find('another layer',1,true))
    f.change_other=false;local foreign=f:read(f.states+8,8)
    assert(f.controller:restore());assert(f:read(f.states+8,8)==foreign)
    assert(#f.calls==2 and f.calls[2][0]==0)
end)
test('synchronous setter missing target acknowledgement refuses without replay',function()
    local f=fixture();local s=assert(f.controller:capture());f.skip_layer=0
    local ok,why=f.controller:apply(s);assert(not ok and why:find('not acknowledged',1,true))
    assert(f.controller:restore() and #f.calls==1)
end)
test('natural later movement is preserved without any cleanup native call',function()
    local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s))
    f:p(f.states,f.definitions[0][3]);local before=f:read(f.states,31*8)
    assert(f.controller:restore());assert(f:read(f.states,31*8)==before and #f.calls==1)
end)
test('all31 states and authored mapping rechecked after clip guard',function()
    for _,kind in ipairs({'state','definition'})do
        local f=fixture();local s=assert(f.controller:capture())
        f.on_guard=function(self)
            if kind=='state'then self:p(self.states+8,self.graph+0xFD000)
            else self:u(self.definitions[0][0]+0x110,58)end
        end
        assert(not f.controller:apply(s)and #f.calls==0)
    end
end)
test('partial function fingerprint change refuses native call',function()
    local f=fixture();local s=assert(f.controller:capture());f:put(f.setter,'X')
    assert(not f.controller:apply(s) and #f.calls==0)
end)
test('clip guard refusal during cleanup retains then restores SDK1',function()
    local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s))
    f.refuse_residency=true;assert(not f.controller:restore() and #f.calls==1)
    f.refuse_residency=false;assert(f.controller:restore() and #f.calls==2)
end)
test('cleanup exception remains uncertain without replay',function()
    local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s))
    f.throw_native=true;assert(not f.controller:restore());f.throw_native=false
    local ok,why=f.controller:restore();assert(not ok and why:find('did not return',1,true))
    assert(#f.calls==2 and f.controller:status()=='cleanup pending')
end)
test('normal authored states11 and87 are preserved with no native call or clip leases',function()
    for _,index in ipairs({11,87})do
        local f=fixture();local normal=f.definitions[0][index]
        f:u(normal+0xC,1);f:u(normal+0x10,0xA8);f:p(normal+0xA8,900)
        f:p(f.states,normal)
        -- Normal movement need not satisfy bridge-event footprint assumptions.
        f:u(normal+0x28,1);f:u(normal+0x2C,0x100);f:u(normal+0x100,0xF78B4078)
        local s=assert(f.controller:capture());assert(s.layers[1].target==index and #s.clips==0)
        f.refuse_residency=true
        assert(f.controller:apply(s)and f.controller:restore()and #f.calls==0 and f.guard_calls==0)
        assert(f:getp(f.states)==normal)
    end
end)
test('normal movement still validates the authored exit target independently',function()
    local f=fixture();f:p(f.states,f.definitions[0][87]);f:u(f.definitions[0][59]+0xB0,4)
    assert(not f.controller:capture()and #f.calls==0)
end)
test('idle ownership can retire only with a sealed positive Unit proof',function()
    local Lifecycle=dofile(root..'/src/animation_lifecycle.lua')
    local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s))
    local life=Lifecycle.new({read=f.io.read,module=function(name)
        if name=='game.dll'then return s.game,0,0x6AB3B43F end
        return s.exe,0,0x6AB382E4
    end})
    f.io.retired=function(proof,snapshot)return life:valid(proof,snapshot)end
    assert(not f.controller:retire({})and f.controller:status()=='cleanup pending')
    f:put(s.generations+s.reference%4194304,'\1')
    local proof=assert(life:prove(s));local raw=f.io.read
    f.io.read=function(at,size)assert(at<s.unit or at>=s.unit+0x1000,'Retired Unit read');return raw(at,size)end
    assert(f.controller:retire(proof)and f.controller:status()=='inactive'and #f.calls==1)
end)
print(('Bridge exit state: %d contracts passed'):format(passed))
