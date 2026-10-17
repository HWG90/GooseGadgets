-- Isolated fake engine memory; never attaches to the game.
local ffi=require('ffi')
local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))
local M=assert(loadfile(root..'/tools/live_pose_layers.lua'))()
local FP='4585c00f848000000048895c241048896c24184889742420'
local function unhex(value) return (value:gsub('..',function(pair)return string.char(tonumber(pair,16))end))end
local function fixture()
    local f={bytes={},calls={},reads=0,definitions={},layer_addresses={},guard_calls=0,expected_clip_count=20}
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
    f:put(exe+0x554440,unhex(FP))
    for index=0,30 do f:p(states+index*8,graph+0xF0000+index*0x100)end
    local next_clip=100
    for _,s in ipairs({{3,76,67,78,0x1000,0,0},{20,1,10,14,0x4000,1,5},{21,1,6,8,0x8000,11,3}})do
        local layer=graph+0x80+s[5];f:u(graph+0x84+s[1]*4,s[5]);f:u(layer+4,s[3]);f:u(layer+8,s[4])
        f.definitions[s[1]]={};f.layer_addresses[s[1]]=layer
        for index=0,s[4]-1 do
            f:u(layer+12+index*4,0x400+index*0x400);f.definitions[s[1]][index]=layer+0x400+index*0x400
        end
        for which=2,3 do
            local node=layer+0x400+s[which]*0x400;f.definitions[s[1]][s[which]]=node
            local clips=s[which+4];f:u(node+0xC,clips);f:u(node+0x10,0xA8)
            for index=0,clips-1 do f:p(node+0xA8+index*8,next_clip);next_clip=next_clip+1 end
        end
        f:p(states+s[1]*8,f.definitions[s[1]][s[2]])
    end
    f.states,f.graph,f.state,f.ep,f.setter,f.blender=states,graph,state,ep,exe+0x554440,blender
    f.io={read=function(...)return f:read(...)end,addresses=function()return A end,avatar=function()return 249 end,
        module=function()return exe,0,0x6AB382E4 end,hashmap=function(at,key)assert(at==pm+0xF8 and key==249);return 0 end,
        game=function()return game end,native=function(at,abi,fp,name)
            assert(at==f.setter and fp==FP and name=='BRIDGE_POSE_LAYERS')
            assert(abi=='void (*)(void *, const int32_t *, uint32_t)')
            return function(instance,array,count)
                assert(tonumber(ffi.cast('uintptr_t',instance))==animator and count==22)
                local call={};for index=0,count-1 do call[index]=tonumber(array[index])end;f.calls[#f.calls+1]=call
                for index=0,count-1 do
                    if call[index]~=-1 and index~=f.skip_layer then
                        assert(f.definitions[index]and f.definitions[index][call[index]],'Invalid fake state')
                        f:p(states+index*8,f.definitions[index][call[index]])
                        if f.throw_native then error('Injected interrupted native call')end
                    end
                end
                if f.change_other then f:p(states,graph+0xFE000)end
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
local function test(name,callback)local ok,why=pcall(callback);assert(ok,name..': '..tostring(why));passed=passed+1;print('PASS '..name)end
test('constructor performs no IO',function()local f=fixture();assert(f.reads==0 and #f.calls==0)end)
test('captured three-layer clip union and normal apply/restore preserve other layers',function()
    local f=fixture();local s=assert(f.controller:capture());assert(#s.clips==20)
    assert(f.controller:apply(s));assert(f.controller:status()=='active'and #f.calls==1)
    local call=f.calls[1];for index=0,21 do assert(call[index]==(index==3 and 67 or index==20 and 10 or index==21 and 6 or -1))end
    assert(f.controller:restore());assert(f.controller:status()=='inactive'and #f.calls==2)
    call=f.calls[2];for index=0,21 do assert(call[index]==(index==3 and 76 or(index==20 or index==21)and 1 or -1))end
end)
test('another current authored state restores its own index and captures its clips',function()
    local f=fixture();local current=f.definitions[3][12]
    f:u(current+0xC,2);f:u(current+0x10,0xA8);f:p(current+0xA8,900);f:p(current+0xB0,901)
    f:p(f.states+3*8,current);f.expected_clip_count=22
    local s=assert(f.controller:capture());assert(s.layers[1].old==12 and s.layers[1].old_pointer==current and #s.clips==22)
    local ids={};for _,clip in ipairs(s.clips)do ids[clip.hex]=true end
    assert(ids['0000000000000384']and ids['0000000000000385'])
    assert(f.controller:apply(s));assert(f.controller:restore())
    assert(f.calls[2][3]==12 and f:getp(f.states+3*8)==current)
end)
test('a layer already at its authored default target skips native exit and entry',function()
    local f=fixture();f:p(f.states+20*8,f.definitions[20][10]);f.expected_clip_count=19
    local s=assert(f.controller:capture());assert(s.layers[2].old==10 and s.layers[2].old_pointer==s.layers[2].target_pointer)
    assert(f.controller:apply(s));assert(f.calls[1][3]==67 and f.calls[1][20]==-1 and f.calls[1][21]==6)
    assert(f.controller:restore());assert(f.calls[2][3]==76 and f.calls[2][20]==-1 and f.calls[2][21]==1)
    assert(f:getp(f.states+20*8)==s.layers[2].target_pointer)
end)
test('all layers already at target need no native setter or cleanup replay',function()
    local f=fixture();for _,spec in ipairs({{3,67},{20,10},{21,6}})do f:p(f.states+spec[1]*8,f.definitions[spec[1]][spec[2]])end
    f.expected_clip_count=8;local s=assert(f.controller:capture());local before=f:read(f.states,31*8)
    assert(f.controller:apply(s)and #f.calls==0 and f.controller:status()=='active')
    assert(f.controller:restore()and #f.calls==0 and f.controller:status()=='inactive')
    assert(f:read(f.states,31*8)==before)
end)
test('selected pointers outside authored definitions refuse capture',function()
    local f=fixture();f:p(f.states+20*8,f.graph+0xFD000)
    local s,why=f.controller:capture();assert(not s and why:find('unique authored definition',1,true)and #f.calls==0)
end)
test('ambiguous current authored definition refuses capture',function()
    local f=fixture();local layer=f.layer_addresses[3]
    f:u(layer+12+7*4,0x400+76*0x400)
    local s,why=f.controller:capture();assert(not s and why:find('selected state is not a unique',1,true)and #f.calls==0)
end)
test('ambiguous target authored definition refuses capture',function()
    local f=fixture();local layer=f.layer_addresses[20]
    f:u(layer+12+7*4,0x400+10*0x400)
    local s,why=f.controller:capture();assert(not s and why:find('target state is not a unique',1,true)and #f.calls==0)
end)
test('exact clip lease refusal makes no native call',function()
    local f=fixture();local s=assert(f.controller:capture());f.refuse_residency=true
    local ok,why=f.controller:apply(s);assert(not ok and why:find('clip lease guard',1,true)and #f.calls==0)
    assert(f.controller:restore())
end)
test('actor retirement between capture and apply makes no native call',function()
    local f=fixture();local s=assert(f.controller:capture());f:u(f.ep+20,0)
    assert(not f.controller:apply(s));assert(#f.calls==0)
end)
test('registration14 guard refuses an active FFFFFFFF node',function()
    local f=fixture();local groups,nodes=0xB00001000,0xB00002000
    f:u(f.blender+0x220,1);f:p(f.blender+0x228,groups);f:u(groups+8,1);f:p(groups+0x10,nodes)
    f:u(nodes+0x10,0xFFFFFFFF)
    local s,why=f.controller:capture();assert(not s and why:find('active invalid node',1,true)and #f.calls==0)
end)
test('absent Blender property buffer refuses capture',function()
    local f=fixture();f:p(f.blender+0x380,0)
    assert(not f.controller:capture() and #f.calls==0)
end)
test('unreadable curve 4 property row refuses capture',function()
    local f=fixture();local raw=f.io.read
    f.io.read=function(at,size)if at==0xB00010000+4*0x58 then return nil end;return raw(at,size)end
    local s,why=f.controller:capture();assert(not s and why:find('unreadable',1,true)and #f.calls==0)
end)
test('property pointer change between capture and apply refuses native call',function()
    local f=fixture();local s=assert(f.controller:capture());f:p(f.blender+0x380,0xB00020000)
    assert(not f.controller:apply(s)and #f.calls==0)
end)
test('world change between capture and apply refuses native call',function()
    local f=fixture();local s=assert(f.controller:capture());f:p(0x100000000+0x108,0x500003000)
    assert(not f.controller:apply(s)and #f.calls==0)
end)
test('native exception retains unknown journal without another call',function()
    local f=fixture();local s=assert(f.controller:capture());f.throw_native=true
    assert(not f.controller:apply(s));local ok,why=f.controller:restore()
    assert(not ok and why:find('did not return',1,true)and #f.calls==1 and f.controller:status()=='cleanup pending')
end)
test('foreign selected state is preserved while owned layers restore',function()
    local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s))
    f:p(f.states+20*8,f.graph+0xFD000);local before=f:read(f.states+20*8,8)
    assert(f.controller:restore());assert(#f.calls==2 and f:read(f.states+20*8,8)==before)
    assert(f.calls[2][3]==76 and f.calls[2][20]==-1 and f.calls[2][21]==1)
    assert(f.controller:status()=='inactive')
end)
test('all foreign selected layers retire without another native call',function()
    local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s))
    for _,part in ipairs(s.layers)do f:p(f.states+part.layer*8,f.graph+0xFD000+part.layer*0x100)end
    local before=f:read(f.states,31*8);local curves=f:read(0xB00010000+4*0x58,0x58)
    assert(f.controller:restore());assert(#f.calls==1 and f:read(f.states,31*8)==before)
    assert(f:read(0xB00010000+4*0x58,0x58)==curves and f.controller:status()=='inactive')
end)
test('mixed target old foreign and unrelated game states preserve each owner',function()
    local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s))
    f:p(f.states+20*8,s.layers[2].old_pointer);f:p(f.states+21*8,f.graph+0xFD000)
    f:p(f.states+8*8,f.graph+0xFD800);local before=f:read(f.states,31*8)
    assert(f.controller:restore());local call=f.calls[2]
    for index=0,21 do assert(call[index]==(index==3 and 76 or -1))end
    assert(f:getp(f.states+3*8)==s.layers[1].old_pointer)
    assert(f:read(f.states+20*8,16)==before:sub(20*8+1,22*8))
    assert(f:read(f.states+8*8,8)==before:sub(8*8+1,9*8))
end)
test('retired foreign parts are not reclaimed after another layer fails cleanup',function()
    local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s))
    f:p(f.states+20*8,f.graph+0xFD000);f:p(f.states+21*8,s.layers[3].old_pointer);f.skip_layer=3
    local ok,why=f.controller:restore();assert(not ok and why:find('not acknowledged',1,true))
    assert(#f.calls==2 and f.controller:status()=='cleanup pending')
    f:p(f.states+20*8,s.layers[2].target_pointer);f.skip_layer=nil
    assert(f.controller:restore());local call=f.calls[3]
    assert(call[3]==76 and call[20]==-1 and call[21]==-1)
    assert(f:getp(f.states+20*8)==s.layers[2].target_pointer and f.controller:status()=='inactive')
end)
test('native cleanup must preserve a foreign selected replacement',function()
    local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s))
    f:p(f.states+20*8,f.graph+0xFD000)
    f.on_native=function(self)self:p(self.states+20*8,self.graph+0xFC000)end
    local ok,why=f.controller:restore();assert(not ok and why:find('not acknowledged',1,true))
    assert(#f.calls==2 and f.controller:status()=='cleanup pending')
    f.on_native=nil;local changed=f:read(f.states+20*8,8);assert(f.controller:restore())
    assert(#f.calls==2 and f:read(f.states+20*8,8)==changed)
end)
test('unselected native cleanup mutation fails readback and remains preserved',function()
    local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s));f.change_other=true
    local ok,why=f.controller:restore();assert(not ok and why:find('another layer',1,true))
    assert(#f.calls==2 and f.controller:status()=='cleanup pending')
    f.change_other=false;local changed=f:read(f.states,8);assert(f.controller:restore())
    assert(#f.calls==2 and f:read(f.states,8)==changed)
end)
test('native cleanup exception retains uncertain ownership without replay',function()
    local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s));f.throw_native=true
    assert(not f.controller:restore());assert(#f.calls==2 and f.controller:status()=='cleanup pending')
    f.throw_native=false;local ok,why=f.controller:restore()
    assert(not ok and why:find('did not return',1,true)and #f.calls==2)
end)
test('identity loss during cleanup never discards ownership',function()
    local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s))
    for _,part in ipairs(s.layers)do f:p(f.states+part.layer*8,f.graph+0xFD000+part.layer*0x100)end
    f:u(f.ep+20,0);assert(not f.controller:restore())
    assert(#f.calls==1 and f.controller:status()=='cleanup pending')
    assert(not f.controller:capture())
end)
test('clip lease refusal during cleanup retains owned target states for retry',function()
    local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s));f.refuse_residency=true
    local ok,why=f.controller:restore();assert(not ok and why:find('clip lease guard',1,true))
    assert(#f.calls==1 and f.controller:status()=='cleanup pending')
    for _,part in ipairs(s.layers)do assert(f:getp(f.states+part.layer*8)==part.target_pointer)end
    f.refuse_residency=false;assert(f.controller:restore());assert(#f.calls==2)
end)
test('unselected native mutation fails readback and is preserved during cleanup',function()
    local f=fixture();local s=assert(f.controller:capture());f.change_other=true
    local ok,why=f.controller:apply(s);assert(not ok and why:find('another layer',1,true))
    f.change_other=false;local before=f:read(f.states,8);assert(f.controller:restore());assert(f:read(f.states,8)==before)
end)
print(('Pose layers: %d/26 contracts passed'):format(passed))
