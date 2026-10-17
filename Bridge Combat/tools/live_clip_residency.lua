-- Read-only exact animation resource probe. Import/new do no game access.
-- Positive results prove instantaneous residency only: no package ownership,
-- resource reference, playback, rig acceptance or native state change is made.
local M = {}
local FP = '4053574883ec384c8bd9498bf84881c1e80200004c8bd2e8'
local TYPE_HEX = '931e336d7646cc26'
local ABI = 'uintptr_t (*)(void *, const uint64_t *, const uint64_t *)'
local END, EMPTY = 0x7FFFFFFF, 0xFFFFFFFE
local function hex(bytes) return (bytes:gsub('.',function(c)return string.format('%02x',c:byte())end))end
local function unhex(value)return(value:gsub('..',function(v)return string.char(tonumber(v,16))end))end
local TYPE_BYTES = unhex(TYPE_HEX):reverse()
local function u(bytes,off)
    local a,b,c,d=bytes:byte(off+1,off+4);assert(d,'Clip integer is unavailable')
    return a+b*256+c*65536+d*16777216
end
local function ptr(bytes,off)
    local value=u(bytes,off)+u(bytes,off+4)*4294967296
    assert(value==0 or(value>=65536 and value<140737488355328),'Clip pointer is unsupported')
    return value
end
function M.new(injected)
    local io=injected or {
        read=function(at,size)return read(at,size)end,
        addresses=function()return use('hd2_addresses').get()end,
        avatar=function(A)return use('hd2_addresses').avatar(A)end,
        module=function(name)return module(name)end,
        hashmap=function(at,key)return hashmap(at,key)end,
        native=function(...)return native(...)end,
        game=function()return game end,
    }
    local self={}
    function self:query(s,clips)
        local ok,result=pcall(function()
            assert(type(s)=='table' and type(clips)=='table' and #clips>0 and #clips<=512,
                'A captured actor and bounded clip list are required')
            local ffi=require('ffi');local read_bytes=0
            local function r(at,size)
                assert(type(at)=='number' and at==math.floor(at) and at>=65536
                    and type(size)=='number' and size==math.floor(size) and size>0 and size<=65536
                    and at+size<=140737488355328,'Clip read is out of bounds')
                read_bytes=read_bytes+size;assert(read_bytes<=2097152,'Clip read budget exceeded')
                local bytes=assert(io.read(at,size),'Clip memory is unreadable')
                assert(type(bytes)=='string' and #bytes==size,'Clip memory read was short')
                return bytes
            end
            local function p(at)local value=ptr(r(at,8),0);assert(value~=0,'Clip pointer is absent');return value end
            local function n(at)return u(r(at,4),0)end
            local function identity()
                local A=assert(io.addresses());local game=io.game()
                local exe,_,stamp=io.module('helldivers2.exe')
                assert(A.base==game and A.stamp==0x6AB3B43F and exe==s.exe and stamp==0x6AB382E4
                    and game==s.game,'Clip game or executable changed')
                assert(hex(r(exe+0x5F34E0,#FP/2))==FP,'Clip getter fingerprint differs')
                assert(p(game+A.GAME_STATE)==s.state and n(s.state+A.STATE_VALUE)==3
                    and p(game+A.WORLD)==s.world and p(game+A.PLAYER)==s.player
                    and n(s.player+0x3A8)==s.local_unit,'Clip world or local player changed')
                assert(io.avatar(A)==s.avatar and p(game+0x3326D20)==s.pm
                    and io.hashmap(s.pm+0xF8,s.avatar)==s.row
                    and p(s.pm+0x110+s.row*8)==s.descriptor
                    and r(s.descriptor,24)==s.desc,'Clip current actor changed')
                assert(u(s.desc,8)==s.avatar and s.desc:byte(21)%2==1 and u(s.desc,12)==s.reference,
                    'Clip current actor is retired')
                local registry=p(exe+0x1A100F0);local count=n(registry+0x98)
                local index=s.reference%4194304
                assert(s.reference~=0 and s.reference~=0xFFFFFFFF and count>0 and count<=0x1000000
                    and index<count and registry==s.registry,'Clip Unit registry changed')
                local generations,units=p(registry+0xA0),p(registry+0x88)
                assert(generations==s.generations and units==s.units
                    and r(generations+index,1):byte()==math.floor(s.reference/4194304)
                    and p(units+index*8)==s.unit and n(s.unit+8)==s.reference,
                    'Clip Unit generation or identity changed')
                local context=p(s.unit+0x18);local manager=p(context+0x2301E8)
                assert(n(manager+0x318)==0,'Clip resource manager would bypass its shared lock')
                return {exe=exe,context=context,manager=manager}
            end
            local base=identity()
            local function recheck()
                local current=identity()
                assert(current.context==base.context and current.manager==base.manager,
                    'Clip resource context changed')
            end
            -- These are the saved 5FE1D0/5FB990 map headers and traversed
            -- links, not the unproved A0 ResourceRecord vector bounds.
            local function map_header(at,max_slots)
                local header=r(at,32)
                local limit,used,buckets=u(header,0),u(header,0x18),u(header,0x1C)
                assert(limit>0 and limit<=max_slots and used<=limit and buckets>0 and buckets<=limit,
                    'Clip resource map header is incoherent')
                local rows=ptr(header,8);assert(rows~=0,'Clip resource map rows are absent')
                return {at=at,bytes=header,rows=rows,limit=limit,used=used,buckets=buckets}
            end
            local function chain(map,key,stride,link_offset,required)
                if map.used==0 then assert(not required,'Animation resource type is unregistered');return nil end
                local index=u(key,4)%map.buckets;local seen={};local samples={}
                while index~=END do
                    assert(index<map.limit and not seen[index],'Clip resource map chain is invalid')
                    seen[index]=true;local at=map.rows+index*stride;local row=r(at,stride)
                    samples[#samples+1]={at=at,bytes=row}
                    local link=u(row,link_offset)
                    if link==EMPTY then
                        assert(#samples==1,'Clip resource map contains an empty chain link')
                        break
                    end
                    assert(link==END or link<map.limit,'Clip resource map contains a poisoned chain link')
                    if row:sub(1,8)==key then
                        assert(r(map.at,32)==map.bytes,'Clip resource map changed during lookup')
                        for _,sample in ipairs(samples)do assert(r(sample.at,#sample.bytes)==sample.bytes,
                            'Clip resource map link changed during lookup')end
                        return at,row
                    end
                    index=link
                end
                assert(r(map.at,32)==map.bytes,'Clip resource map changed during lookup')
                for _,sample in ipairs(samples)do assert(r(sample.at,#sample.bytes)==sample.bytes,
                    'Clip resource map link changed during lookup')end
                assert(not required,'Animation resource type is unregistered')
            end
            local function maps_for(name)
                local types=map_header(base.manager+0x2E8,4096)
                local type_at,type_row=chain(types,TYPE_BYTES,0xD0,0xC8,true)
                local records=ptr(type_row,0x10)
                assert(records~=0,'Clip native record storage is absent');r(records,8)
                local names=map_header(type_at+0x20,65536)
                chain(names,name,0x18,0x10,false)
                return types,names
            end
            local query=assert(io.native(base.exe+0x5F34E0,ABI,FP,'BRIDGE_CLIP_RESIDENCY'))
            recheck()
            local type_arg=ffi.new('uint64_t[1]');ffi.copy(type_arg,TYPE_BYTES,8)
            local report={all_resident=true,ownership=false,instantaneous=true,entries={},
                avatar=s.avatar,reference=s.reference,unit=s.unit,world=s.world,manager=base.manager}
            local seen={}
            for _,clip in ipairs(clips)do
                assert(type(clip)=='table' and type(clip.bytes)=='string' and #clip.bytes==8
                    and clip.bytes~=string.rep('\0',8) and type(clip.hex)=='string'
                    and hex(clip.bytes:reverse())==clip.hex:lower()
                    and type(clip.type)=='string' and clip.type:lower()==TYPE_HEX,
                    'Clip exact hash/type is invalid')
                assert(not seen[clip.hex:lower()],'Clip list contains a duplicate hash');seen[clip.hex:lower()]=true
                recheck();local types,names=maps_for(clip.bytes)
                local name_arg=ffi.new('uint64_t[1]');ffi.copy(name_arg,clip.bytes,8)
                recheck()
                assert(r(types.at,32)==types.bytes and r(names.at,32)==names.bytes,
                    'Clip resource map header changed before query')
                -- Argument storage remains alive through the synchronous call.
                local raw=query(ffi.cast('void *',base.manager),type_arg,name_arg)
                local data=assert(tonumber(raw),'Clip getter returned no pointer value')
                assert(data==0 or(data==math.floor(data) and data>=65536 and data<140737488355328),
                    'Clip getter returned an unsupported data pointer')
                if data~=0 then r(data,16)end
                recheck()
                assert(r(types.at,32)==types.bytes and r(names.at,32)==names.bytes,
                    'Clip resource map header changed during query')
                report.entries[#report.entries+1]={hex=clip.hex:lower(),type=TYPE_HEX,data=data,resident=data~=0}
                if data==0 then report.all_resident=false end
            end
            report.read_bytes=read_bytes
            return report
        end)
        if not ok then return nil,tostring(result)end
        return result
    end
    return self
end
return M
