-- Review prototype only. Import/new perform no game access. The caller retains
-- exact clip references through apply and acknowledged cleanup; its lease guard
-- must confirm that ownership. An instantaneous residency query is insufficient.
-- Select only SDK layer1's authored bridge_exit target59 with the synchronous
-- count1 partial state setter. No animation event is bound or dispatched.
-- No MCM changes, reverse event, full graph reset, raw curve or package writes.
local M = {}
local FP = '4585c00f848000000048895c241048896c24184889742420'
local EVENT = 0xF78B4078 -- Used only to prove the authored target mapping.
local SPECS = {{layer = 0, target = 59}}
local TARGET_CLIP, IDLE_CLIP = '759c08277f1296d0', 'c2c16b9f0c49b54a'
local function hex(bytes) return (bytes:gsub('.', function(c) return string.format('%02x', c:byte()) end)) end
local function n(bytes, off)
    local a,b,c,d = bytes:byte(off+1, off+4); assert(d, 'Short pose integer')
    return a+b*256+c*65536+d*16777216
end
local function pointer(bytes, off)
    local value = n(bytes,off)+n(bytes,off+4)*4294967296
    assert(value == 0 or (value >= 65536 and value < 140737488355328), 'Unsupported pose pointer')
    return value
end
local function attempt(fn)
    local ok,a,b = pcall(fn); if not ok then return nil,tostring(a) end; return a,b
end
function M.new(clip_lease_guard, injected)
    assert(type(clip_lease_guard) == 'function', 'Exact animation clip lease guard is required')
    local io = injected or {
        read = function(at,size) return read(at,size) end,
        addresses = function() return use('hd2_addresses').get() end,
        avatar = function(A) return use('hd2_addresses').avatar(A) end,
        module = function(name) return module(name) end,
        hashmap = function(at,key) return hashmap(at,key) end,
        native = function(...) return native(...) end,
        game = function() return game end,
    }
    local self = {journal = nil}
    local function r(at,size)
        assert(at and at >= 65536 and at < 140737488355328 and size <= 65536, 'Pose read out of bounds')
        local bytes = assert(io.read(at,size), 'Pose memory is unreadable'); assert(#bytes == size, 'Pose memory read was short')
        return bytes
    end
    local function p(at, optional) local value=pointer(r(at,8),0); assert(optional or value~=0,'Pose pointer is absent'); return value end
    local function u(at) return n(r(at,4),0) end
    local function observe()
        local A=assert(io.addresses()); local game=io.game(); assert(A.base==game and A.stamp==0x6AB3B43F,'Unsupported pose game build')
        local exe,_,stamp=io.module('helldivers2.exe'); assert(exe and stamp==0x6AB382E4,'Unsupported pose executable')
        local state=p(game+A.GAME_STATE); assert(u(state+A.STATE_VALUE)==3,'Pose actor left the ship')
        local world,player=p(game+A.WORLD),p(game+A.PLAYER)
        local local_unit=u(player+0x3A8)
        local avatar=assert(io.avatar(A),'Local pose actor is absent')
        local pm=p(game+0x3326D20); local row=assert(io.hashmap(pm+0xF8,avatar),'Pose control row is absent')
        assert(row>=0 and row<4096,'Pose control row is out of bounds')
        local descriptor=p(pm+0x110+row*8); local desc=r(descriptor,24)
        assert(n(desc,8)==avatar and desc:byte(21)%2==1,'Pose actor is retired')
        local reference=n(desc,12); assert(reference~=0 and reference~=0xFFFFFFFF,'Pose Unit reference is absent')
        local registry=p(exe+0x1A100F0); local count=u(registry+0x98); local index=reference%4194304
        assert(count>0 and count<=0x1000000 and index<count,'Pose registry bounds differ')
        local generations,units=p(registry+0xA0),p(registry+0x88)
        assert(r(generations+index,1):byte()==math.floor(reference/4194304),'Pose Unit generation changed')
        local unit=p(units+index*8); assert(u(unit+8)==reference,'Pose Unit identity changed')
        assert(hex(r(unit+0x358,8):reverse())=='4d1c334d294dfa97','Pose body graph resource differs')
        local animator=p(unit+0x178); local graph=p(animator+0x28); local gh=r(graph,0x30)
        assert(n(gh,4)==31,'Pose graph layer count differs')
        assert(hex(r(exe+0x554440,#FP/2))==FP,'Pose setter fingerprint differs')
        local states=p(animator+0x50)
        return {game=game,exe=exe,A=A,state=state,world=world,player=player,local_unit=local_unit,
            avatar=avatar,pm=pm,row=row,descriptor=descriptor,desc=desc,
            reference=reference,registry=registry,generations=generations,units=units,unit=unit,animator=animator,
            graph=graph,graph_header=gh,states=states}
    end
    local function same(s,v)
        for _,key in ipairs({'game','exe','state','world','player','local_unit','avatar','pm','row','descriptor','desc','reference','registry',
            'unit','animator','graph','graph_header','states'}) do
            assert(s[key]==v[key],'Pose actor or graph identity changed: '..key)
        end
        -- Registry storage can reallocate while the exact live Unit remains.
        -- Seal the CURRENT arrays, generation and slot; never read old arrays
        -- or rewrite the captured owner merely to acknowledge allocation growth.
        local root=r(v.exe+0x1A100F0,8);assert(pointer(root,0)==s.registry,'Pose registry owner changed')
        local count_bytes=r(s.registry+0x98,4);local count=n(count_bytes,0)
        local generations_bytes,units_bytes=r(s.registry+0xA0,8),r(s.registry+0x88,8)
        assert(pointer(generations_bytes,0)==v.generations and pointer(units_bytes,0)==v.units,
            'Pose registry arrays changed during observation')
        local index=s.reference%4194304;local generation=math.floor(s.reference/4194304)
        assert(generation<256 and count>0 and count<=0x1000000 and index<count,'Pose registry slot is unavailable')
        local generation_byte=r(v.generations+index,1);local slot=r(v.units+index*8,8)
        assert(generation_byte:byte()==generation and pointer(slot,0)==s.unit,'Pose current Unit slot changed')
        local unit_reference=r(s.unit+8,4);assert(n(unit_reference,0)==s.reference,'Pose Unit identity changed')
        assert(r(v.exe+0x1A100F0,8)==root and r(s.registry+0x98,4)==count_bytes
            and r(s.registry+0xA0,8)==generations_bytes and r(s.registry+0x88,8)==units_bytes
            and r(v.generations+index,1)==generation_byte and r(v.units+index*8,8)==slot
            and r(s.unit+8,4)==unit_reference,'Pose registry changed during ownership proof')
    end
    local function no_invalid_active_node(s)
        local blender=p(s.unit+0x168); assert(p(s.animator+0x30)==blender,'Pose Blender identity differs')
        local count=u(blender+0x220); assert(count<=128,'Pose group count is unsupported')
        local groups=p(blender+0x228,count==0); local total=0
        for group=0,count-1 do
            local entry=r(groups+group*0x28,0x18); local nodes=n(entry,8); local rows=pointer(entry,0x10)
            total=total+nodes; assert(nodes<=1024 and total<=4096 and (nodes==0 or rows~=0),'Pose node count is unsupported')
            for index=0,nodes-1 do assert(u(rows+index*0x630+0x10)~=0xFFFFFFFF,'Pose registration14 has an active invalid node') end
        end
        local curve_count=u(s.animator+0x1B0); local curves=p(s.animator+0x1B8)
        assert(curve_count==31,'Pose curve layer count differs')
        for index=0,30 do
            local entry=r(curves+index*24,24); local used,capacity=n(entry,0),n(entry,4); local entries=pointer(entry,8)
            assert(used<=capacity and capacity<=256 and (used==0 or entries~=0),'Pose curve record bounds differ')
            if used>0 then r(entries,used*8) end
        end
        -- The saved 54ADB0/54B490 path accesses curve 4 through this pointer.
        -- No property-buffer count is proved: this is a readable-row and stable
        -- pointer check only, never an invented allocation/array bound.
        local properties=p(blender+0x380)
        local curve4=properties+4*0x58
        r(curve4,0x58)
        assert(p(blender+0x380)==properties,'Pose property buffer changed while reading')
        return blender,curves,properties,curve4
    end
    local function recheck(s,states)
        same(s,observe())
        for _,sample in ipairs(s.samples) do assert(r(sample.at,#sample.bytes)==sample.bytes,'Pose definition changed') end
        if states then assert(r(s.states,31*8)==states,'Pose states changed before native call') end
        local blender,curves,properties,curve4=no_invalid_active_node(s)
        assert(blender==s.blender and curves==s.curves and properties==s.properties and curve4==s.curve4,
            'Pose animation context changed')
    end
    function self:capture()
        if self.journal then return nil,'Pose cleanup is pending' end
        return attempt(function()
            local s=observe(); s.samples={}; s.layers={}; s.clips={}; local clip_keys={}
            local function sample(at,size) local bytes=r(at,size); s.samples[#s.samples+1]={at=at,bytes=bytes}; return bytes end
            local offset=n(s.graph_header,8); assert(offset>0 and offset<0x1000000,'Pose layer table offset differs')
            local table_address=s.graph+offset; local table_bytes=sample(table_address,4+31*4)
            s.state_bytes=r(s.states,31*8)
            for _,spec in ipairs(SPECS) do
                local relative=n(table_bytes,4+spec.layer*4); assert(relative>0 and relative<0x1000000,'Pose layer offset differs')
                local layer=table_address+relative; local lh=sample(layer,12); local count=n(lh,8)
                assert(count>0 and count<=4096 and spec.target<count and n(lh,4)==59,'Pose graph default differs')
                local defs=sample(layer+12,count*4)
                local current=pointer(s.state_bytes,spec.layer*8); local addresses={}
                local old,matches,target_matches=nil,0,0
                local target_relative=n(defs,spec.target*4)
                for index=0,count-1 do
                    local rel=n(defs,index*4); assert(rel>0 and rel<0x1000000,'Pose state offset differs')
                    addresses[index]=layer+rel
                    if addresses[index]==current then old=index; matches=matches+1 end
                    if rel==target_relative then target_matches=target_matches+1 end
                end
                assert(matches==1,'Pose selected state is not a unique authored definition')
                assert(target_matches==1,'Pose target state is not a unique authored definition')
                local target=old>10 and old or spec.target
                local part={layer=spec.layer,old=old,target=target,old_pointer=current,target_pointer=addresses[target]}
                local sampled={}
                for _,which in ipairs({'old','target','authored'}) do
                    local address=which=='authored' and addresses[59] or part[which..'_pointer']
                    if not sampled[address] then
                        sampled[address]=true; local header=sample(address,0xA8)
                        local clip_count,clip_offset=n(header,0xC),n(header,0x10)
                        if address==addresses[59] then
                            assert(clip_count==1 and n(header,8)==3 and n(header,0x6C)==16
                                and n(header,0x40)==0 and n(header,0x70)==1 and n(header,0x74)==0xB0
                                and n(header,0x90)==6 and n(header,0x94)==0x3BC and n(header,0xA0)==0,
                                'Bridge exit target metadata differs')
                            assert(n(sample(address+0xB0,4),0)==3,'Bridge exit registration differs')
                        end
                        assert(clip_count<=256 and clip_offset<0x1000000,'Pose clip table bounds differ')
                        -- EXE54B78F..54B7CB /54BE75..54BEAF: state+C count,
                        -- state+10 relative offset, qword animation names.
                        if clip_count>0 then
                            assert(clip_offset>0,'Pose clip table is absent')
                            local ids=sample(address+clip_offset,clip_count*8)
                            if address==addresses[59] then assert(hex(ids:reverse())==TARGET_CLIP,'Bridge exit target clip differs') end
                            if which=='old' and old==0 then assert(clip_count==1 and hex(ids:reverse())==IDLE_CLIP,'Bridge idle clip differs') end
                            for index=0,clip_count-1 do
                                local bytes=ids:sub(index*8+1,index*8+8); local key=hex(bytes:reverse())
                                assert(key~='0000000000000000','Pose animation name is absent')
                                if part.old_pointer~=part.target_pointer and which~='authored' and not clip_keys[key] then
                                    clip_keys[key]=true; s.clips[#s.clips+1]={bytes=bytes,hex=key,type='931e336d7646cc26'}
                                end
                            end
                        end
                    end
                end
                s.layers[#s.layers+1]=part
            end
            -- A hash alone does not prove an event's footprint. Check every
            -- currently selected layer, then retain its exact event/target rows
            -- as definition samples for the final pre-selection recheck.
            if s.layers[1].old<=10 then for index=0,30 do
                local address=pointer(s.state_bytes,index*8)
                if address~=0 then
                    local header=sample(address,0x38)
                    local count,offset=n(header,0x28),n(header,0x2C)
                    assert(count<=4096 and offset<0x1000000,'Bridge exit event table bounds differ')
                    local matched=0
                    if count>0 then
                        assert(offset>0,'Bridge exit event table is absent')
                        local events=sample(address+offset,count*8)
                        for row=0,count-1 do
                            if n(events,row*8)==EVENT then
                                matched=matched+1
                                assert(index==0,'Bridge exit event affects another current layer')
                                local transition=n(events,row*8+4)
                                local targets,target_offset=n(header,0x30),n(header,0x34)
                                assert(transition<0x80000000 and targets>0 and targets<=4096
                                    and transition<targets and target_offset>0 and target_offset<0x1000000,
                                    'Bridge exit transition bounds or conditional flag differ')
                                local rows=sample(address+target_offset,targets*16)
                                assert(n(rows,transition*16)==59,'Bridge exit target is not state59')
                                if s.layers[1].old==0 then
                                    assert(n(rows,transition*16+4)==0x3E4CCCCD
                                        and n(rows,transition*16+8)==0,'Bridge idle exit blend differs')
                                end
                            end
                        end
                    end
                    if index==0 and s.layers[1].old~=59 then
                        assert(matched==1,'Bridge exit event is not uniquely mapped from the current state')
                    else assert(matched==0,'Bridge exit event has an unexpected current-layer mapping') end
                end
            end end
            assert(#s.clips<=512,'Pose animation list exceeds the diagnostic bound')
            s.blender,s.curves,s.properties,s.curve4=no_invalid_active_node(s)
            recheck(s,s.state_bytes)
            return s
        end)
    end
    local function invoke(s,array,before)
        assert(#s.clips==0 or clip_lease_guard(s,s.clips)==true,'Pose exact clip lease guard refused')
        recheck(s,before)
        local call=assert(io.native(s.exe+0x554440,'void (*)(void *, const int32_t *, uint32_t)',FP,'BRIDGE_EXIT_STATE'))
        recheck(s,before)
        self.journal.uncertain_call=true
        call(require('ffi').cast('void *',s.animator),array,1)
        self.journal.uncertain_call=false
    end
    local function selected_readback(s,before,expected_states)
        same(s,observe()); local after=r(s.states,31*8); local selected={}
        for _,part in ipairs(s.layers) do selected[part.layer]=part end
        for index=0,30 do
            local expected=expected_states[index] or pointer(before,index*8)
            assert(pointer(after,index*8)==expected,selected[index] and 'Pose selected state was not acknowledged' or 'Pose setter changed another layer')
        end
        return after
    end
    function self:apply(s)
        if self.journal then return false,'Bridge exit cleanup is pending' end
        local ok,why=attempt(function()
            assert(type(s)=='table' and s.layers and #s.layers==1 and s.layers[1].layer==0,
                'Bridge exit capture is required')
            recheck(s,s.state_bytes)
            assert(#s.clips==0 or clip_lease_guard(s,s.clips)==true,'Pose exact clip lease guard refused')
            recheck(s,s.state_bytes)
            local part=s.layers[1]
            self.journal={snapshot=s,attempted=true,retired={[0]=part.old_pointer==part.target_pointer}}
            if part.old_pointer~=part.target_pointer then
                local array=require('ffi').new('int32_t[1]')
                array[0]=part.target
                invoke(s,array,s.state_bytes)
            end
            selected_readback(s,s.state_bytes,{[0]=part.target_pointer})
            self.journal.acknowledged=true
            return true
        end)
        return ok==true,why
    end
    function self:restore()
        if not self.journal then return true end
        local journal=self.journal; local s=journal.snapshot
        journal.cleanup_started=true
        local ok,why=attempt(function()
            assert(not journal.uncertain_call,'Native pose call did not return; restoration remains unknown')
            recheck(s)
            local before=r(s.states,31*8); local ffi=require('ffi'); local array=ffi.new('int32_t[1]')
            array[0]=-1
            local needed=false; local expected,retire={},{}
            for _,part in ipairs(s.layers) do
                local current=pointer(before,part.layer*8)
                expected[part.layer]=current
                if not journal.retired[part.layer] and current==part.target_pointer then
                    array[part.layer]=part.old; expected[part.layer]=part.old_pointer; needed=true
                else
                    -- Normal native exit/entry already transferred this layer's
                    -- curve ownership. Preserve old or game-replacement states,
                    -- and never reclaim a retired part if the game picks target.
                    retire[part.layer]=true
                end
            end
            recheck(s,before)
            for layer in pairs(retire) do journal.retired[layer]=true end
            if needed then invoke(s,array,before); selected_readback(s,before,expected) end
            self.journal=nil
            return true
        end)
        return ok==true,why
    end
    function self:retire(proof)
        if not self.journal then return true end
        self.journal.cleanup_started=true
        local ok,why=attempt(function()
            assert(type(io.retired)=='function','Positive Unit-retirement validator is unavailable')
            local retired,reason=io.retired(proof,self.journal.snapshot)
            assert(retired==true,reason or 'Unit retirement remains unproven')
            self.journal=nil -- Old Unit cannot consume states; never dereference it.
            return true
        end)
        return ok==true,why
    end
    function self:status()
        return not self.journal and 'inactive'
            or self.journal.acknowledged and not self.journal.cleanup_started and 'active' or 'cleanup pending'
    end
    return self
end
return M
