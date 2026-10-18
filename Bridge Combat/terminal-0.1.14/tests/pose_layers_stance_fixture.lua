-- Isolated fake engine memory; never attaches to the game.
local ffi=require('ffi')
local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))
local M=assert(loadfile(root..'/tools/live_pose_layers_stance.lua'))()
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
    f.profile_address=pm+0x547830+0x20;f:u(f.profile_address,0)
    f.control_address=pm+0x53D8B0
    f.io={read=function(...)return f:read(...)end,addresses=function()return A end,avatar=function()return 249 end,
        module=function()return exe,0,0x6AB382E4 end,hashmap=function(at,key)assert(at==pm+0xF8 and key==249);return 0 end,
        game=function()return game end,native=function(at,abi,fp,name)
            assert(at==f.setter and fp==FP and name=='BRIDGE_POSE_LAYERS_STANCE')
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
local function test(name,callback)
    local ok,why=pcall(callback);assert(ok,name..': '..tostring(why))
    passed=passed+1;print('PASS '..name)
end
local function clips(f,node,ids)
    f:u(node+0xC,#ids);f:u(node+0x10,0xA8)
    for i,id in ipairs(ids)do f:p(node+0xA8+(i-1)*8,id)end
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
test('one shared same-cell replacement repairs pending cleanup without journal changes',function()
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
test('coherent current registry array relocation restores exact held pose without changing its snapshot',function()
    for _,both in ipairs({false,true})do
        local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s))
        local old_generations,old_units=s.generations,s.units;relocate(f,s,both)
        assert(f.controller:restore());assert(#f.calls==2 and s.generations==old_generations and s.units==old_units)
    end
end)
test('coherent relocation inside clip guard is rechecked and permits only the same body',function()
    local f=fixture();local s=assert(f.controller:capture())
    f.on_guard=function(self)self.on_guard=nil;relocate(self,s,true)end
    assert(f.controller:apply(s)and #f.calls==1 and f.controller:restore())
end)
test('changed generation slot or body after array relocation cannot restore the old pose',function()
    for _,kind in ipairs({'generation','slot','body'})do
        local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s))
        local generations,units,index=relocate(f,s,true)
        if kind=='generation'then f:put(generations+index,'\1')
        elseif kind=='slot'then f:p(units+index*8,s.unit+0x1000)
        else f:put(s.unit+0x358,string.rep('\0',8))end
        assert(not f.controller:restore()and #f.calls==1 and f.controller.journal,kind)
    end
end)
test('torn current registry array proof refuses cleanup before any native setter',function()
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
test('constructor performs no IO and neutral fixture retains original behavior',function()
    local f=fixture();assert(f.reads==0 and #f.calls==0)
    local s=assert(f.controller:capture());assert(s.normal_profile==0 and #s.clips==20)
    local before=f:read(f.states,31*8);assert(f.controller:apply(s))
    assert(f.calls[1][3]==67 and f.calls[1][20]==10 and f.calls[1][21]==6)
    assert(f.controller:restore() and f:read(f.states,31*8)==before)
end)
test('normal prone aim53 and its exact clips are preserved instead of forcing67',function()
    local f=fixture();local normal=f.definitions[3][53]
    f:p(f.states+3*8,normal);clips(f,normal,{900})
    f:u(f.definitions[3][67]+0xC,999) -- Irrelevant neutral target must not be loaded.
    f.expected_clip_count=20
    local s=assert(f.controller:capture());local part=s.layers[1]
    assert(part.old==53 and part.target==53 and part.old_pointer==part.target_pointer)
    local has=false;for _,clip in ipairs(s.clips)do if clip.hex=='0000000000000384'then has=true end end
    assert(not has and f.controller:apply(s) and f.calls[1][3]==-1)
    assert(f:getp(f.states+3*8)==normal and f.controller:restore())
    assert(f.calls[2][3]==-1 and f:getp(f.states+3*8)==normal)
end)
for _,case in ipairs({{0,67},{1,8},{2,18},{3,67},{4,8}})do
    test('ship76 chooses profile'..case[1]..' target'..case[2]..' with exact target clips',function()
        local f=fixture();f:u(f.profile_address,case[1])
        local target=f.definitions[3][case[2]];clips(f,target,{901,902})
        f.expected_clip_count=22
        local s=assert(f.controller:capture());local part=s.layers[1]
        assert(part.old==76 and part.target==case[2] and part.target_pointer==target)
        local ids={};for _,clip in ipairs(s.clips)do ids[clip.hex]=true end
        assert(ids['0000000000000385'] and ids['0000000000000386'])
        assert(f.controller:apply(s) and f.calls[1][3]==case[2])
        for index=0,21 do
            assert(f.calls[1][index]==(index==3 and case[2] or index==20 and 10 or index==21 and 6 or -1))
        end
        assert(f.controller:restore()and f.calls[2][3]==76)
    end)
end
test('unknown profile5 refuses ship76 replacement but preserves normal53',function()
    local f=fixture();f:u(f.profile_address,5)
    local s,why=f.controller:capture();assert(not s and why:find('unsupported normal player profile',1,true))
    assert(#f.calls==0)
    f:p(f.states+3*8,f.definitions[3][53])
    s=assert(f.controller:capture());assert(s.layers[1].target==53)
    assert(f.controller:apply(s)and f.calls[1][3]==-1 and f.controller:restore())
end)
test('normal profile source is the player-state row rather than control context57',function()
    local f=fixture();f:u(f.profile_address,2);f:u(f.control_address+0xFD0,57)
    local s=assert(f.controller:capture());assert(s.normal_profile==2 and s.layers[1].target==18)
    assert(f.controller:apply(s)and f.calls[1][3]==18)
    assert(f.controller:restore())
end)
test('authored SDK4 default remains67 separately from dynamic target8',function()
    local f=fixture();f:u(f.profile_address,1);f:u(f.layer_addresses[3]+4,8)
    local s,why=f.controller:capture();assert(not s and why:find('default differs',1,true)and #f.calls==0)
end)
test('dynamic current and target clip lists form a deduplicated exact union',function()
    local f=fixture();f:u(f.profile_address,2)
    clips(f,f.definitions[3][76],{900,901});clips(f,f.definitions[3][18],{901,902})
    f.expected_clip_count=23
    local s=assert(f.controller:capture());assert(#s.clips==23)
    local ids={};for _,clip in ipairs(s.clips)do assert(not ids[clip.hex]);ids[clip.hex]=true end
    assert(ids['0000000000000384'] and ids['0000000000000385']and ids['0000000000000386'])
    assert(f.controller:apply(s)and f.controller:restore())
end)
test('profile change after capture refuses native apply',function()
    local f=fixture();local s=assert(f.controller:capture());f:u(f.profile_address,1)
    local ok,why=f.controller:apply(s)
    assert(not ok and why:find('Normal player profile changed',1,true) and #f.calls==0)
end)
test('profile change inside clip guard is rechecked before native apply',function()
    local f=fixture();local s=assert(f.controller:capture())
    f.on_guard=function(self)self:u(self.profile_address,2)end
    local ok,why=f.controller:apply(s)
    assert(not ok and why:find('Normal player profile changed',1,true) and #f.calls==0)
end)
test('cleanup permits stance changes and preserves natural prone aiming53',function()
    local f=fixture();local s=assert(f.controller:capture());assert(f.controller:apply(s))
    f:u(f.profile_address,2);f:p(f.states+3*8,f.definitions[3][53])
    local normal=f:read(f.states+3*8,8)
    assert(f.controller:restore()and f.calls[2][3]==-1)
    assert(f.calls[2][20]==1 and f.calls[2][21]==1 and f:read(f.states+3*8,8)==normal)
end)
test('cleanup permits unknown profile5 while restoring an owned target',function()
    local f=fixture();f:u(f.profile_address,1)
    local s=assert(f.controller:capture());assert(f.controller:apply(s)and f.calls[1][3]==8)
    f:u(f.profile_address,5)
    assert(f.controller:restore()and f.calls[2][3]==76)
end)
test('already normal SDK4 does not weaken exact ownership or clip guard',function()
    local f=fixture();f:p(f.states+3*8,f.definitions[3][53])
    local s=assert(f.controller:capture());f.refuse_residency=true
    assert(not f.controller:apply(s)and #f.calls==0)
    f.refuse_residency=false;f:u(f.ep+20,0)
    assert(not f.controller:apply(s)and #f.calls==0)
end)
test('preserved SDK4 with35 clips leases only changed SDK21 and22 clips',function()
    local f=fixture();local normal=f.definitions[3][59];local ids={}
    for i=1,35 do ids[i]=900+i end
    clips(f,normal,ids);f:p(f.states+3*8,normal)
    local s=assert(f.controller:capture())
    assert(s.layers[1].old==59 and s.layers[1].target==59 and #s.clips==20 and #s.clips<=32)
    for _,clip in ipairs(s.clips)do assert(not clip.hex:find('00000000000003',1,true))end
    assert(f.controller:apply(s)and f.calls[1][3]==-1)
    assert(f.controller:restore()and f.calls[2][3]==-1 and f:getp(f.states+3*8)==normal)
end)
test('all no-op parts lease no clips and call neither guard nor native setter',function()
    local f=fixture();local normal=f.definitions[3][59];local ids={}
    for i=1,35 do ids[i]=900+i end
    clips(f,normal,ids);f:p(f.states+3*8,normal)
    f:p(f.states+20*8,f.definitions[20][10]);f:p(f.states+21*8,f.definitions[21][6])
    local s=assert(f.controller:capture());assert(#s.clips==0)
    f.refuse_residency=true
    assert(f.controller:apply(s)and f.controller:restore())
    assert(#f.calls==0 and f.guard_calls==0)
end)
test('preserved static clip tables are still fingerprinted before changed-part apply',function()
    local f=fixture();local normal=f.definitions[3][59]
    clips(f,normal,{900});f:p(f.states+3*8,normal)
    local s=assert(f.controller:capture());assert(#s.clips==20)
    f:p(normal+0xA8,901)
    local ok,why=f.controller:apply(s)
    assert(not ok and why:find('definition changed',1,true)and #f.calls==0)
end)
test('changed clip-free SDK4 can use partial setter with an empty lease union',function()
    local f=fixture();f:p(f.states+20*8,f.definitions[20][10]);f:p(f.states+21*8,f.definitions[21][6])
    local s=assert(f.controller:capture());assert(#s.clips==0 and s.layers[1].old==76)
    f.refuse_residency=true
    assert(f.controller:apply(s)and f.calls[1][3]==67)
    assert(f.controller:restore()and f.calls[2][3]==76)
    assert(f.guard_calls==0)
end)
test('pose ownership retirement requires a sealed proof and never reads the old Unit',function()
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
print(('Pose layers stance: %d contracts passed'):format(passed))
