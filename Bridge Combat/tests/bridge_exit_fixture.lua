-- Isolated fake engine memory; never attaches to the game.
local ffi=require('ffi')
local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))
local M=assert(loadfile(root..'/tools/live_bridge_exit.lua'))()
local FP='4585c00f848000000048895c241048896c24184889742420'
local EVENT_FP='48895c2408574883ec208bda8bf9e8adbfe9ff448bc38bd7'
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
        self.reads=self.reads+1;local parts={};for i=0,size-1 do parts[#parts+1]=self.bytes[at+i]or'\0'end
        return table.concat(parts)
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
    f:put(exe+0x554440,unhex(FP));f:put(exe+0x201900,unhex(EVENT_FP))
    for index=0,30 do f:p(states+index*8,graph+0xF0000+index*0x100)end
    local next_clip=100
    for _,s in ipairs({{0,0,59,60,0x1000,1,1}})do
        local layer=graph+0x80+s[5];f:u(graph+0x84+s[1]*4,s[5]);f:u(layer+4,0);f:u(layer+8,s[4])
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
    f.event=exe+0x201900
    f.io={read=function(...)return f:read(...)end,addresses=function()return A end,avatar=function()return 249 end,
        module=function()return exe,0,0x6AB382E4 end,hashmap=function(at,key)assert(at==pm+0xF8 and key==249);return 0 end,
        game=function()return game end,native=function(at,abi,fp,name)
            if at==f.event then
                assert(fp==EVENT_FP and name=='BRIDGE_EXIT_EVENT')
                assert(abi=='void (*)(uint32_t, uint32_t)')
                return function(reference,event)
                    assert(reference==1 and event==0xF78B4078)
                    f.calls[#f.calls+1]={kind='event',reference=reference,event=event}
                    if not f.skip_event then f:p(states,f.definitions[0][59])end
                    if f.change_other then f:p(states+8,graph+0xFE000)end
                    if f.throw_event then error('Injected interrupted event')end
                    if f.on_event then f:on_event()end
                end
            end
            assert(at==f.setter and fp==FP and name=='BRIDGE_EXIT_RESTORE')
            assert(abi=='void (*)(void *, const int32_t *, uint32_t)')
            return function(instance,array,count)
                assert(tonumber(ffi.cast('uintptr_t',instance))==animator and count==1)
                local call={kind='restore'};for index=0,count-1 do call[index]=tonumber(array[index])end;f.calls[#f.calls+1]=call
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
test('constructor performs no IO',function()
    local f=fixture();assert(f.reads==0 and #f.calls==0)
end)
test('exact idle and target union; event only changes SDK1; restore is count1',function()
    local f=fixture();local s=assert(f.controller:capture());assert(#s.clips==2)
    assert(s.layers[1].layer==0 and s.layers[1].old==0 and s.layers[1].target==59)
    local keys={};for _,clip in ipairs(s.clips)do keys[clip.hex]=true end
    assert(keys.c2c16b9f0c49b54a and keys['759c08277f1296d0'])
    local before=f:read(f.states,31*8)
    assert(f.controller:apply(s));assert(f.controller:status()=='active' and #f.calls==1)
    assert(f.calls[1].kind=='event' and f.calls[1].reference==1 and f.calls[1].event==0xF78B4078)
    assert(f:read(f.states+8,30*8)==before:sub(9))
    assert(f.controller:restore());assert(#f.calls==2 and f.calls[2].kind=='restore' and f.calls[2][0]==0)
    assert(f:read(f.states,31*8)==before and f.controller:status()=='inactive')
end)
test('current bridge state3 captures its own clip and restores state3',function()
    local f=fixture();local old=f.definitions[0][3]
    f:u(old+0xC,1);f:u(old+0x10,0xA8);f:p(old+0xA8,900);f:p(f.states,old)
    local s=assert(f.controller:capture());assert(s.layers[1].old==3 and #s.clips==2)
    assert(f.controller:apply(s));assert(f.controller:restore());assert(f.calls[2][0]==3)
end)
test('already59 is an event and restore no-op',function()
    local f=fixture();f:p(f.states,f.definitions[0][59]);f.expected_clip_count=1
    local s=assert(f.controller:capture());assert(#s.clips==1)
    assert(f.controller:apply(s) and f.controller:restore() and #f.calls==0)
end)
test('only current0..10 or59 are permitted',function()
    local f=fixture();f:p(f.states,f.definitions[0][11])
    local s,why=f.controller:capture();assert(not s and why:find('event footprint',1,true))
    assert(#f.calls==0)
end)
test('authored default remains0 independently of target59',function()
    local f=fixture();f:u(f.layer_addresses[0]+4,59)
    local s,why=f.controller:capture();assert(not s and why:find('default differs',1,true))
end)
test('wrong target or idle clip refuses capture',function()
    for _,which in ipairs({0,59})do
        local f=fixture();f:p(f.definitions[0][which]+0xA8,999)
        assert(not f.controller:capture() and #f.calls==0)
    end
end)
test('exact clip lease refusal prevents event',function()
    local f=fixture();local s=assert(f.controller:capture());f.refuse_residency=true
    local ok,why=f.controller:apply(s);assert(not ok and why:find('clip lease guard',1,true))
    assert(#f.calls==0 and f.controller:restore())
end)
test('actor retirement between capture and apply refuses event',function()
    local f=fixture();local s=assert(f.controller:capture());f:u(f.ep+20,0)
    assert(not f.controller:apply(s) and #f.calls==0)
end)
test('actor replacement during restore retains pending without another call',function()
    local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s))
    f:u(f.ep+8,250);assert(not f.controller:restore())
    assert(#f.calls==1 and f.controller:status()=='cleanup pending')
end)
test('an event exception retains uncertain ownership without replay',function()
    local f=fixture();local s=assert(f.controller:capture());f.throw_event=true
    assert(not f.controller:apply(s));f.throw_event=false
    local ok,why=f.controller:restore();assert(not ok and why:find('did not return',1,true))
    assert(#f.calls==1 and f.controller:status()=='cleanup pending')
end)
test('event footprint mutation of another layer fails all31 readback',function()
    local f=fixture();local s=assert(f.controller:capture());f.change_other=true
    local ok,why=f.controller:apply(s);assert(not ok and why:find('another layer',1,true))
    f.change_other=false;local foreign=f:read(f.states+8,8)
    assert(f.controller:restore());assert(f:read(f.states+8,8)==foreign)
    assert(#f.calls==2 and f.calls[2][0]==0)
end)
test('event without target acknowledgement refuses and retires old state',function()
    local f=fixture();local s=assert(f.controller:capture());f.skip_event=true
    local ok,why=f.controller:apply(s);assert(not ok and why:find('not acknowledged',1,true))
    assert(f.controller:restore() and #f.calls==1)
end)
test('natural later movement is preserved without reverse event or partial call',function()
    local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s))
    f:p(f.states,f.definitions[0][3]);local before=f:read(f.states,31*8)
    assert(f.controller:restore());assert(f:read(f.states,31*8)==before and #f.calls==1)
end)
test('all31 states rechecked after clip guard before event',function()
    local f=fixture();local s=assert(f.controller:capture())
    f.on_guard=function(self)self:p(self.states+8,self.graph+0xFD000)end
    local ok,why=f.controller:apply(s);assert(not ok and why:find('states changed',1,true) and #f.calls==0)
end)
test('event or partial function fingerprint change refuses call',function()
    for _,which in ipairs({'setter','event'})do
        local f=fixture();local s=assert(f.controller:capture());f:put(f[which],'X')
        assert(not f.controller:apply(s) and #f.calls==0)
    end
end)
test('clip guard refusal during cleanup retains then restores SDK1',function()
    local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s))
    f.refuse_residency=true;assert(not f.controller:restore() and #f.calls==1)
    f.refuse_residency=false;assert(f.controller:restore() and #f.calls==2)
end)
test('partial cleanup exception remains uncertain without replay',function()
    local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s))
    f.throw_native=true;assert(not f.controller:restore());f.throw_native=false
    local ok,why=f.controller:restore();assert(not ok and why:find('did not return',1,true))
    assert(#f.calls==2 and f.controller:status()=='cleanup pending')
end)
test('other current layer event mapping refuses capture before dispatch',function()
    local f=fixture();local other=f:getp(f.states+8)
    f:u(other+0x28,1);f:u(other+0x2C,0x100);f:u(other+0x100,0xF78B4078)
    local s,why=f.controller:capture();assert(not s and why:find('another current layer',1,true)and #f.calls==0)
end)
test('missing duplicate conditional or wrong-target exit mappings refuse capture',function()
    for _,kind in ipairs({'missing','duplicate','conditional','wrongtarget','wrongblend'})do
        local f=fixture();local old=f.definitions[0][0]
        if kind=='missing'then f:u(old+0x100,0)
        elseif kind=='duplicate'then
            f:u(old+0x28,2);f:u(old+0x108,0xF78B4078);f:u(old+0x10C,0)
        elseif kind=='conditional'then f:u(old+0x104,0x80000000)
        elseif kind=='wrongtarget'then f:u(old+0x110,60)
        else f:u(old+0x114,0)end
        assert(not f.controller:capture()and #f.calls==0,kind)
    end
end)
test('captured event mapping is rechecked after clip lease guard',function()
    local f=fixture();local s=assert(f.controller:capture())
    f.on_guard=function(self)self:u(self.definitions[0][0]+0x110,58)end
    local ok,why=f.controller:apply(s);assert(not ok and why:find('definition changed',1,true)and #f.calls==0)
end)
test('already59 still validates exact target clip and registration metadata',function()
    for _,kind in ipairs({'clip','registration','mask'})do
        local f=fixture();local target=f.definitions[0][59];f:p(f.states,target)
        if kind=='clip'then f:p(target+0xA8,900)
        elseif kind=='registration'then f:u(target+0xB0,4)
        else f:u(target+0x6C,0)end
        assert(not f.controller:capture() and #f.calls==0,kind)
    end
end)
print(('Bridge exit: %d/22 contracts passed'):format(passed))
