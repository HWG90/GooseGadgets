-- Experimental ADS convergence caps for held projectile components.
-- Beam targeting remains native; beam helpers below are read-only diagnostics.
-- Authored definitions and native modes remain read-only. No native calls,
-- materialization or code patches are used.
-- All discovery runs on the loader's game thread without yielding.
local Memory = mod.require('src/memory.lua')
local AdsGate = mod.require('src/ads_gate.lua')
local Parameters = mod.require('src/parameters.lua')
local M = {}
local STAMP, MAX_ROWS = 0x6AB3B43F, 4096
local OFF = {world=0x346BF98, implementation=0x346BFC8, player=0x3326468,
    inventory=0x3326738}
local FAMILIES = {
    {id='projectile',global=0x33266D8,world_offset=0xF0B3B8,
    runtime_map=0x50,runtime_count=0x38,runtime_capacity=0x2C,descriptors=0x68,
    runtime_rows=0x78,runtime_stride=0xA8,mode=0x13,cap=0x14,
    owned_map=0x90,inverse_map=0xB0,owned_count=0xC8,owned_capacity=0x30,
    owned_rows=0xD0,definition_stride=0x268,angle=0x30,flag=0x264,
    base_table=0xF12E80,buckets=542,base_offset=0x21E0,base_count=271},
    {id='beam',global=0x3326A20,world_offset=0xEB6758,
    runtime_map=0x40,runtime_count=0x2C,runtime_capacity=0x20,descriptors=0x58,
    runtime_rows=0x60,runtime_stride=0x70,mode=0x18,cap=0x14,
    owned_map=0x70,inverse_map=0x90,owned_count=0xA8,owned_capacity=0x24,
    owned_rows=0xB0,definition_stride=0x78,angle=0xC,
    base_table=0xF12CE8,buckets=46,base_offset=0x2E0,base_count=23},
}
local FPS = {
    {0x613D29, '488b4424788078130074290f2885d00200000f298530'},
    {0x613F47, 'f30f104814410f2fce76700f2fc1766bf30f5ec8440f2ff1'},
    {0x612070, 'f30f5905e845db01f30f114514f3410f104530'},
    {0x61288B, '498b43784869d1a80000004488740213'},
    {0x742550, '40534883ec203b15c416d4028bda4c8b0dfb40be027507b8'},
    {0x515100, '4883ec284c8bd14885c9750733c04883c428c38b41083b05'},
    {0x612800, '41563b151814e702450fb6f04c8b1dc53ed1027507b8ffff'},
    {0x576AA7, '498d8db8b3f0004d8bc6498bd4e857440a00e967d7ffff66'},
    {0x515554, '8b5a04498bf0448b4a08488bfa4403cb488be9413bd97332'},
    {0x613D5D, '4180be64020000007452f20f1085c0020000'},
    {0x83ECDE, '43807c2f1800f30f117dd8f3440f1145dcf30f1175e07423'},
    {0x83ED22, 'f3470f104c2f14450f2fcd440f299424f0010000440f299c24e0010000'},
    {0x83EDAA, '0f5405efd1b801410f2fc1767ef3440f5ec8450f2fe97606'},
    {0x83E16A, 'f30f5905ee84b801f30f114314f30f10470c0f2ec1'},
    {0x83F7EB, '498b4360486bd1704488740218415e'},
    {0x50ECC0, '4883ec284c8bd14885c9750733c04883c428c38b41083b05484ff702'},
}
for _, item in ipairs(FPS) do
    item.bytes=item[2]:gsub('%x%x',function(pair) return string.char(tonumber(pair,16)) end)
end
-- Read adjacent immutable code markers together, then compare every original
-- byte on every validation. No cached build result or runtime pointer survives
-- a call. Small spans bound copied bytes and avoid large per-frame strings.
local fingerprint_spans={}
do
    local sorted={}
    for _,item in ipairs(FPS)do sorted[#sorted+1]=item end
    table.sort(sorted,function(a,b)return a[1]<b[1]end)
    for _,item in ipairs(sorted)do
        local span=fingerprint_spans[#fingerprint_spans]
        local finish=item[1]+#item.bytes
        if not span or finish-span.start>1024 then
            span={start=item[1],size=#item.bytes,items={}}
            fingerprint_spans[#fingerprint_spans+1]=span
        else span.size=math.max(span.size,finish-span.start)end
        span.items[#span.items+1]=item
    end
end
local function entity(value)
    return type(value)=='number' and value==math.floor(value) and value>0 and value<0xFFFFFFFF
end
local function text_id(...)
    local values={...};for i=1,#values do values[i]=tostring(values[i]) end
    return table.concat(values,':')
end
local function hex(bytes)
    return (bytes:gsub('.',function(c) return string.format('%02x',c:byte()) end))
end
local function absent(why) return why=='Hash map entry is absent' or why=='Hash map key is empty' end
local function family_for(value)
    if value==nil then return FAMILIES[1] end
    if type(value)=='table' then value=value.id end
    for _,family in ipairs(FAMILIES) do if family.id==value then return family end end
end
local function recoverable_apply(bytes,native)
    if bytes==native or bytes==Parameters.TARGET then return true end
    -- The controller retains an exact copied-prefix acknowledgement. A fresh
    -- expected-byte match plus the original admitted lease may finish that
    -- known native-to-target prefix; unrelated intermediate images stay foreign.
    for copied=1,3 do
        if bytes==Parameters.TARGET:sub(1,copied)..native:sub(copied+1) then return true end
    end
    return false
end

-- Track map headers/buckets and all pointer/count/descriptor/row reads as well
-- as the final field. Repeated equality detects observed mutation, not ABA.
local function tracked(mem)
    local reads={}
    local count=0
    local reader=setmetatable({}, {__index=mem})
    function reader:read(address,size)
        local bytes,why=mem:read(address,size)
        if type(bytes)=='string' and #bytes==size then
            -- A flat journal keeps the identical address/size/byte proof without
            -- allocating a separate table for every guarded pointer read.
            reads[count+1],reads[count+2],reads[count+3]=address,size,bytes
            count=count+3
        end
        return bytes,why
    end
    function reader:stable()
        for i=1,count,3 do
            if mem:read(reads[i],reads[i+1])~=reads[i+2] then return false end
        end
        return true
    end
    return reader
end

function M.new(log,io)
    assert(Parameters.TARGET==string.char(0x35,0xFA,0x0E,0x3C)
        and type(Parameters.native_cap)=='function' and type(Parameters.should_limit)=='function',
        'Unsupported cap experiment parameters')
    return setmetatable({mem=Memory.new(io),log=log or function() end},{__index=M})
end

function M:_context()
    local mem=self.mem
    local game,stamp=mem:_module()
    if not game then return nil,stamp end
    for _,span in ipairs(fingerprint_spans) do
        local bytes=mem:read(game+span.start,span.size)
        if not bytes then return nil,'HOB game fingerprint mismatch' end
        for _,item in ipairs(span.items)do
            local offset=item[1]-span.start
            if bytes:sub(offset+1,offset+#item.bytes)~=item.bytes then return nil,'HOB game fingerprint mismatch' end
        end
    end
    local world=mem:ptr(game+OFF.world)
    local implementation=mem:ptr(game+OFF.implementation)
    if not world or not implementation then return nil,'Waiting for weapon World' end
    if mem:ptr(game+OFF.world)~=world or mem:ptr(game+OFF.implementation)~=implementation
        then return nil,'Weapon World roots changed' end
    return {game=game,stamp=STAMP,world=world,implementation=implementation,
        managers={},token=text_id(game,world,implementation)}
end

function M:_runtime(ctx,id,family)
    if not entity(id) then return nil,'retired' end
    family=family_for(family)
    if not family then return nil,'Invalid weapon family' end
    local reader=tracked(self.mem)
    if reader:ptr(ctx.game+OFF.world)~=ctx.world
        or reader:ptr(ctx.game+OFF.implementation)~=ctx.implementation then
        return nil,'Weapon World roots changed'
    end
    local manager,manager_problem=reader:ptr(ctx.game+family.global)
    if not manager then return nil,manager_problem or family.id..' manager is unavailable' end
    if manager~=ctx.implementation+family.world_offset then return nil,family.id..' manager belongs to another World' end
    ctx.managers[family.id]=manager
    local wi,why=reader:hashmap(ctx.world+0xF1AEB0,id)
    if not wi then return nil,absent(why) and 'retired' or why end
    if wi>=1048576 then return nil,'World row exceeds bounds' end
    local descriptor=reader:read(ctx.world+0xF32F18+wi*24,24)
    if not descriptor then return nil,'World descriptor is unreadable' end
    if Memory.u32_bytes(descriptor,8)~=id or self.mem.bit.band(descriptor:byte(21),3)~=1 then
        return nil,'retired'
    end
    local index
    index,why=reader:hashmap(manager+family.runtime_map,id)
    if not index then return nil,absent(why) and 'not applicable' or why end
    local count,capacity=reader:u32(manager+family.runtime_count),reader:u32(manager+family.runtime_capacity)
    if not count or not capacity or count>capacity or capacity>MAX_ROWS or index>=count then
        return nil,family.id..' runtime row exceeds bounds'
    end
    local descriptors=reader:ptr(manager+family.descriptors)
    local ep=descriptors and reader:ptr(descriptors+index*8)
    local runtime_descriptor=ep and reader:read(ep,24)
    if not runtime_descriptor then return nil,family.id..' runtime descriptor is unreadable' end
    if runtime_descriptor:sub(1,16)~=descriptor:sub(1,16)
        or self.mem.bit.band(runtime_descriptor:byte(21),3)~=1 then return nil,'retired' end
    local rows=reader:ptr(manager+family.runtime_rows)
    if not rows then return nil,family.id..' runtime rows are unavailable' end
    local row=rows+index*family.runtime_stride
    local address=row+family.cap
    local cap=reader:read(address,4)
    local mode=reader:u8(row+family.mode)
    if not cap or mode==nil then return nil,family.id..' convergence cache or native mode is unreadable' end
    if not reader:stable() then return nil,family.id..' identity or convergence cache changed during read' end
    local identity=descriptor:sub(1,16)
    return {key=text_id(ctx.token,family.id,manager,id,hex(identity)),token=ctx.token,
        game=ctx.game,world=ctx.world,manager=manager,family=family.id,entity=id,
        descriptor=identity,resource=identity:sub(1,8),descriptor_address=ep,
        runtime_index=index,runtime_rows=rows,address=address,bytes=cap,native_mode=mode}
end

function M:_definition(ctx,id,descriptor,family)
    family=family_for(family)
    if not family then return nil,'Invalid weapon family' end
    local reader=tracked(self.mem)
    local manager=ctx.managers[family.id]
    if not manager then return nil,'Weapon manager is unavailable' end
    local count,capacity=reader:u32(manager+family.owned_count),reader:u32(manager+family.owned_capacity)
    if not count or not capacity or count>capacity or capacity>MAX_ROWS then
        return nil,'Owned definition bounds are unavailable'
    end
    local index,why
    if count>0 then
        index,why=reader:hashmap(manager+family.owned_map,id)
        if not index and not absent(why) then return nil,why end
    end
    local address,owned
    if index then
        if index>=count then return nil,'Owned definition index exceeds count' end
        local inverse,problem=reader:hashmap(manager+family.inverse_map,index)
        if inverse~=id then return nil,problem or 'Owned definition inverse mismatch' end
        local rows=reader:ptr(manager+family.owned_rows)
        address,owned=rows and rows+index*family.definition_stride,true
    else
        local base=reader:ptr(ctx.world+family.base_table)
        if not base then return nil,'Base '..family.id..' definitions are unavailable' end
        local lo,hi=Memory.u32_bytes(descriptor),Memory.u32_bytes(descriptor,4)
        local buckets=family.buckets
        local start=((hi%buckets)*(4294967296%buckets)+lo%buckets)%buckets
        for probe=0,buckets-1 do
            local slot=reader:read(base+((start+probe)%buckets)*16,16)
            if not slot then return nil,'Base '..family.id..' table is unreadable' end
            if slot:sub(1,8)==string.rep('\0',8) then break end
            if slot:sub(1,8)==descriptor:sub(1,8) then
                local row=Memory.u32_bytes(slot,8)
                if row>=family.base_count then return nil,'Base '..family.id..' definition exceeds bounds' end
                address=base+family.base_offset+row*family.definition_stride
                break
            end
        end
        owned=false
    end
    if not address then return nil,family.id..' definition is unavailable' end
    local angle=reader:read(address+family.angle,4)
    local flag=family.flag and reader:u8(address+family.flag) or nil
    if not angle or family.flag and flag==nil then return nil,family.id..' definition guards are unreadable' end
    if not reader:stable() then return nil,family.id..' definition guards changed during read' end
    local native,angle_value=Parameters.native_cap(angle)
    if not native then return nil,angle_value or 'Unsupported authored aiming angle' end
    return {native_angle_bytes=angle,native_bytes=native,native_angle=angle_value,
        definition_flag=flag,definition_address=address,owned=owned}
end

function M:_record(ctx,id,family,read_definition)
    if type(family)=='boolean' then read_definition,family=family,nil end
    family=family_for(family)
    if not family then return nil,'Invalid weapon family' end
    local record,why=self:_runtime(ctx,id,family)
    if not record then return nil,why end
    if read_definition~=false then
        local definition,problem=self:_definition(ctx,id,record.descriptor,family)
        if definition then for key,value in pairs(definition) do record[key]=value end
        else record.definition_error=problem end
        -- Definition reads never justify using an earlier runtime address.
        local closing,reason=self:_runtime(ctx,id,family)
        if not closing then return nil,reason end
        if closing.key~=record.key or closing.address~=record.address or closing.bytes~=record.bytes
            or closing.native_mode~=record.native_mode then return nil,family.id..' runtime changed during definition read' end
    end
    return record
end

function M:_local(ctx)
    local reader=tracked(self.mem)
    local player,inventory=reader:ptr(ctx.game+OFF.player),reader:ptr(ctx.game+OFF.inventory)
    local unit=player and reader:u32(player+0x3A8)
    if not inventory or not entity(unit) then return nil,'Waiting for local player' end
    local index,why=reader:hashmap(ctx.world+0xF22EC8,unit)
    if not index or index>=1048576 then return nil,why or 'Local player index exceeds bounds' end
    local descriptor=reader:read(ctx.world+0xF32F18+index*24,24)
    if not descriptor or Memory.u32_bytes(descriptor,16)~=unit
        or self.mem.bit.band(descriptor:byte(21),3)~=1 then return nil,'Local player descriptor is unavailable' end
    local avatar=Memory.u32_bytes(descriptor,8)
    if not entity(avatar) then return nil,'Local avatar is unavailable' end
    local ii,problem=reader:hashmap(inventory+0x28,avatar)
    local count=reader:u32(inventory+0x18)
    if not ii or not count or count>MAX_ROWS or ii>=count then return nil,problem or 'Local inventory index exceeds bounds' end
    local descriptors=reader:ptr(inventory+0x40)
    local ep=descriptors and reader:ptr(descriptors+ii*8)
    local inventory_descriptor=ep and reader:read(ep,24)
    if not inventory_descriptor or inventory_descriptor:sub(1,16)~=descriptor:sub(1,16)
        or self.mem.bit.band(inventory_descriptor:byte(21),3)~=1 then return nil,'Local inventory owner changed' end
    local rows=reader:ptr(inventory+0x50)
    if not rows or not reader:read(rows+ii*48,48) then return nil,'Local inventory is unavailable' end
    if not reader:stable() then return nil,'Local player or inventory changed during read' end
    return descriptor
end

local function guards(record)
    -- Nonzero native modes and alternate directions bypass this cap. Preserve
    -- those routes rather than turning them into convergence.
    if record.native_mode~=0 then return false,'native direction override remains unchanged' end
    if record.definition_error then return nil,record.definition_error end
    if type(record.native_bytes)~='string' or #record.native_bytes~=4 then return nil,'Native cap conversion is unavailable' end
    if record.family=='projectile' and record.definition_flag~=0 then
        return false,'native alternate direction remains unchanged'
    end
    if not Parameters.should_limit(record.native_bytes) then
        if record.native_angle==0 then return false,'native authored raw direction remains unchanged' end
        return false,'native cap at or below 0.5 degrees remains unchanged'
    end
    return true
end

function M:_collect(ctx,id)
    local all,eligible,reasons={},{},{}
    local family=FAMILIES[1]
    local record,why=self:_record(ctx,id,family)
    if not record then
        if why~='not applicable' then return nil,family.id..': '..tostring(why) end
    else
        local allowed,reason=guards(record)
        if allowed==nil then return nil,family.id..': '..tostring(reason) end
        all[#all+1]=record
        if allowed then eligible[#eligible+1]=record
        else reasons[#reasons+1]=family.id..': '..reason end
    end
    return all,nil,eligible,reasons
end

function M:observe()
    local ctx,why=self:_context()
    if not ctx then return nil,why end
    ctx.weapons={}
    ctx.mode_status='Experiment inactive: ADS convergence is not applied'
    local local_descriptor,problem=self:_local(ctx)
    if not local_descriptor then return nil,problem end
    local active,reason,snapshot=AdsGate.check(self.mem,ctx,local_descriptor,nil)
    if not active then ctx.mode_status='Experiment inactive: '..tostring(reason or 'ADS inactive'); return ctx end
    local selected=snapshot and snapshot.held
    if not entity(selected) or type(snapshot.held_descriptor)~='string' then return nil,'ADS held weapon is unavailable' end
    local sampled
    sampled,problem=self:_collect(ctx,selected)
    if not sampled then return nil,problem end
    for _,record in ipairs(sampled) do
        if snapshot.held_descriptor:sub(1,16)~=record.descriptor then return nil,'ADS held component ownership changed' end
    end
    local closing,closing_reason,closed=AdsGate.check(self.mem,ctx,local_descriptor,selected)
    if not closing then return nil,closing_reason end
    if not closed.held_descriptor or closed.held_descriptor~=snapshot.held_descriptor then return nil,'Held weapon changed during observation' end
    local final,final_reason,eligible,reasons=self:_collect(ctx,selected)
    if not final then return nil,final_reason end
    if #final~=#sampled then return nil,'Weapon component membership changed during ADS observation' end
    for index,record in ipairs(final) do
        local before=sampled[index]
        if record.key~=before.key or record.bytes~=before.bytes or record.native_mode~=before.native_mode
            or record.native_bytes~=before.native_bytes or record.definition_flag~=before.definition_flag then
            return nil,'Weapon component changed during ADS observation'
        end
    end
    for _,record in ipairs(eligible) do record.ads_local_descriptor=local_descriptor end
    ctx.weapons,ctx.native_reasons=eligible,reasons
    if #eligible>0 then ctx.mode_status='ADS convergence experiment'
    elseif #reasons>0 then ctx.mode_status='Native aiming: '..table.concat(reasons,'; ')
    else ctx.mode_status='Native aiming: beams remain native; held weapon has no projectile component' end
    return ctx
end

function M:resolve(record)
    if type(record)~='table' or type(record.family)~='string' or not family_for(record.family) or not entity(record.entity) then
        return nil,'Invalid convergence lease'
    end
    local ctx,why=self:_context()
    if not ctx then return nil,why end
    if record.token~=ctx.token then return nil,'retired' end
    -- Cleanup deliberately ignores ADS, authored prefix/angle/flag, and native
    -- mode. Its identity and raw cap are enough to preserve competing edits.
    local current,problem=self:_record(ctx,record.entity,record.family,false)
    if not current then return nil,problem=='not applicable' and 'retired' or problem end
    if current.key~=record.key then return nil,'retired' end
    return current
end

function M:write(record,expected,target)
    if type(expected)~='string' or #expected~=4 or type(target)~='string' or #target~=4 then
        return false,'Convergence writes require exactly four bytes',0
    end
    if type(record)~='table' or record.family~='projectile'
        or type(record.native_bytes)~='string' or #record.native_bytes~=4
        or record.bytes~=record.native_bytes or not Parameters.should_limit(record.native_bytes)
        or (target~=Parameters.TARGET and target~=record.native_bytes) then
        return false,'Only an exact native projectile cap lease may be changed',0
    end
    local current,why=self:resolve(record)
    if not current then return false,why,0 end
    if current.bytes~=expected then return false,'Convergence cache changed externally',0 end
    -- One closing witness binds every authorization read to the final runtime
    -- address. The outer reader also sees nested map/ADS stability rereads.
    local witness=tracked(self.mem)
    local transaction=setmetatable({mem=witness},{__index=self})
    local ctx,problem=transaction:_context()
    if not ctx or ctx.token~=record.token then return false,problem or 'Convergence World changed',0 end
    if target==Parameters.TARGET then
        local active,reason,snapshot=AdsGate.check(witness,ctx,record.ads_local_descriptor,record.entity)
        if not active then return false,reason,0 end
        if not snapshot.held_descriptor or snapshot.held_descriptor:sub(1,16)~=current.descriptor then
            return false,'ADS held descriptor changed before cap write',0
        end
        -- Reacquire the held projectile only. Beam diagnostics never authorize
        -- writes or block projectile observation.
        local all,detail=transaction:_collect(ctx,record.entity)
        if not all then return false,detail,0 end
        local refreshed
        for _,candidate in ipairs(all) do if candidate.family==record.family then refreshed=candidate;break end end
        if not refreshed then return false,'Weapon component retired before cap write',0 end
        local allowed,explanation=guards(refreshed)
        if not allowed then return false,explanation,0 end
        if refreshed.native_bytes~=record.native_bytes then return false,'Authored native cap changed before write',0 end
        if refreshed.key~=record.key or refreshed.bytes~=expected then return false,'Weapon cap changed before write',0 end
        if not recoverable_apply(refreshed.bytes,refreshed.native_bytes) then
            return false,'Cap is neither native, owned target nor a recoverable forward-copy prefix',0
        end
        current=refreshed
    else
        -- A fresh identity/cap-only resolution permits exact restoration even
        -- when the mode or authored definition became foreign or unreadable.
        current,why=transaction:_record(ctx,record.entity,record.family,false)
        if not current then return false,why=='not applicable' and 'retired' or why,0 end
        if current.key~=record.key then return false,'retired',0 end
        if current.bytes~=expected then return false,'Convergence cache changed before restoration',0 end
    end
    if not witness:stable() then return false,'Convergence authorization changed before write',0 end
    return self.mem:copy(current.address,target)
end

return M
