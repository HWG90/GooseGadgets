-- Entity-owned aiming definitions; no shared resources or executable patches.
-- No game access at import/construction. All discoveries run on LLL's game thread.
local Memory = mod.require('src/memory.lua')
local M = {}
local STAMP, MAX_ROWS = 0x6AB3B43F, 4096
local OFF = {world=0x346BF98, player=0x3326468, inventory=0x3326738, projectile=0x33266D8}
local FAMILIES = {
    {id='projectile',global=0x33266D8,world_offset=0xF0B3B8,
     runtime_map=0x50,runtime_count=0x38,runtime_cap=0x2C,descriptors=0x68,
     owned_map=0x90,inverse_map=0xB0,count=0xC8,cap=0x30,rows=0xD0,stride=0x268,angle=0x30,prefix=16,
     base_table=0xF12E80,buckets=542,base_offset=0x21E0,base_count=271,clone=0x61AF10,component=0x141},
    {id='beam',global=0x3326A20,world_offset=0xEB6758,
     runtime_map=0x40,runtime_count=0x2C,runtime_cap=0x20,descriptors=0x58,
     owned_map=0x70,inverse_map=0x90,count=0xA8,cap=0x24,rows=0xB0,stride=0x78,angle=0xC,prefix=12,
     base_table=0xF12CE8,buckets=46,base_offset=0x2E0,base_count=23,clone=0x841AF0,component=0x10E},
}
local FPS = {
    {0x742550, '40534883ec203b15c416d4028bda4c8b0dfb40be027507b8'},
    {0x515100, '4883ec284c8bd14885c9750733c04883c428c38b41083b05'},
    {0x612800, '41563b151814e702450fb6f04c8b1dc53ed1027507b8ffff'},
    {0x61AF10, '48895c240848896c2410488974241848897c242041564883ec408b4208498be8'},
    {0x576AA7, '498d8db8b3f0004d8bc6498bd4e857440a00e967d7ffff66'},
    {0x515554, '8b5a04498bf0448b4a08488bfa4403cb488be9413bd97332'},
    {0x50ECC0, '4883ec284c8bd14885c9750733c04883c428c38b41083b05484ff7020f849000'},
    {0x50E880, '4885c9746c488b050cd7f502448bc14c8b90e82cf10048b8'},
    {0x841AF0, '48895c240848896c2410488974241848897c242041564883ec408b4208498be8'},
    {0x576490, '498d8d5867eb004d8bc6498bd4e84eb62c00e97eddffff49'},
    {0x83F750, '41563b15dc44c402450fb6f04c8b1dbd72ae027517b8ffff'},
    {0x83ECDE, '43807c2f1800f30f117dd8f3440f1145dcf30f1175e07423'},
}
for _, item in ipairs(FPS) do
    item.bytes=item[2]:gsub('%x%x',function(p) return string.char(tonumber(p,16)) end)
end
local function valid_entity(e) return e and e>0 and e<0xFFFFFFFF end
local function text_id(...) local t={...};for i=1,#t do t[i]=tostring(t[i]) end;return table.concat(t,':') end
local function hex(s) return (s:gsub('.',function(c) return string.format('%02x',c:byte()) end)) end
local function retired_lookup(why) return why=='Hash map entry is absent' or why=='Hash map key is empty' end

function M.new(log, io)
    return setmetatable({mem=Memory.new(io), log=log or function() end}, {__index=M})
end

function M:_context()
    local mem=self.mem
    local game,stamp=mem:_module()
    if not game then return nil,stamp end
    for _, item in ipairs(FPS) do
        if mem:read(game+item[1],#item.bytes)~=item.bytes then return nil,'HOB game fingerprint mismatch' end
    end
    local world=mem:ptr(game+OFF.world)
    local implementation=mem:ptr(game+0x346BFC8)
    if not world or not implementation then return nil,'Waiting for weapon managers' end
    local ctx={game=game,stamp=STAMP,world=world,implementation=implementation,managers={}}
    local tokens={game,world,implementation}
    for _,family in ipairs(FAMILIES) do
        local manager=mem:ptr(game+family.global)
        if not manager or manager~=implementation+family.world_offset then
            return nil,family.id..' manager is not owned by current world'
        end
        ctx.managers[family.id]=manager;tokens[#tokens+1]=manager
    end
    ctx.token=text_id(unpack(tokens))
    return ctx
end

function M:_descriptor(ctx,entity,family)
    if not valid_entity(entity) then return nil,'retired' end
    local mem=self.mem
    local wi,why=mem:hashmap(ctx.world+0xF1AEB0,entity)
    if not wi then return nil,retired_lookup(why) and 'retired' or why end
    if wi>=1048576 then return nil,'World row exceeds bounds' end
    local desc=mem:read(ctx.world+0xF32F18+wi*24,24)
    if not desc then return nil,'World descriptor is unreadable' end
    if Memory.u32_bytes(desc,8)~=entity or mem.bit.band(desc:byte(21),1)==0 then return nil,'retired' end
    local ri
    local manager=ctx.managers[family.id]
    ri,why=mem:hashmap(manager+family.runtime_map,entity)
    if not ri then return nil,retired_lookup(why) and 'not applicable' or why end
    local count,cap=mem:u32(manager+family.runtime_count),mem:u32(manager+family.runtime_cap)
    if not count or not cap or count>cap or cap>MAX_ROWS or ri>=count then
        return nil,'Projectile row exceeds bounds'
    end
    local entities=mem:ptr(manager+family.descriptors)
    local ep=entities and mem:ptr(entities+ri*8)
    local runtime=ep and mem:read(ep,24)
    if not runtime then return nil,'Projectile descriptor is unreadable' end
    if runtime:sub(1,16)~=desc:sub(1,16) or mem.bit.band(runtime:byte(21),1)==0 then return nil,'retired' end
    return desc:sub(1,16),nil,ep
end

function M:_base(ctx,descriptor,family)
    local mem=self.mem
    local table_address=mem:ptr(ctx.world+family.base_table)
    if not table_address then return nil,'Base aiming definitions unavailable' end
    local lo,hi=Memory.u32_bytes(descriptor),Memory.u32_bytes(descriptor,4)
    local buckets=family.buckets
    local start=((hi%buckets)*(4294967296%buckets)+lo%buckets)%buckets
    for probe=0,buckets-1 do
        local slot=mem:read(table_address+((start+probe)%buckets)*16,16)
        if not slot then return nil,'Base aiming definition table unreadable' end
        if slot:sub(1,8)==string.rep('\0',8) then return nil,'No aiming definition for weapon' end
        if slot:sub(1,8)==descriptor:sub(1,8) then
            local index=Memory.u32_bytes(slot,8)
            if index>=family.base_count then return nil,'Base aiming definition exceeds bounds' end
            return table_address+family.base_offset+index*family.stride
        end
    end
    return nil,'No aiming definition for weapon'
end

function M:_record(ctx,entity,family,raw_value)
    local mem=self.mem
    local manager=ctx.managers[family.id]
    local descriptor,why,ep=self:_descriptor(ctx,entity,family)
    if not descriptor then return nil,why end
    local count,cap=mem:u32(manager+family.count),mem:u32(manager+family.cap)
    if not count or not cap or count>cap or cap>MAX_ROWS then return nil,'Owned definition bounds unavailable' end
    local index
    if count>0 then
        index,why=mem:hashmap(manager+family.owned_map,entity)
        if not index and not retired_lookup(why) then return nil,why end
    end
    local address,owned
    if index then
        if index>=count then return nil,'Owned definition index exceeds live count' end
        local inverse
        inverse,why=mem:hashmap(manager+family.inverse_map,index)
        if inverse~=entity then return nil,why or 'Owned definition inverse mismatch' end
        local rows=mem:ptr(manager+family.rows)
        address,owned=rows and rows+index*family.stride,true
    else
        address,why=self:_base(ctx,descriptor,family)
        if not address then return nil,why end
        owned=false
    end
    local prefix=address and mem:read(address,family.prefix)
    local bytes=address and mem:read(address+family.angle,4)
    if not prefix or not bytes then return nil,'Owned aiming definition unreadable' end
    -- Reject NaNs/infinities and implausible angles, retaining the exact original bytes.
    local bits=Memory.u32_bytes(bytes)
    local scalar=mem._ffi.new('float[1]');mem._ffi.copy(scalar,bytes,4)
    local angle=tonumber(scalar[0])
    if not raw_value and (mem.bit.band(bits,0x7F800000)==0x7F800000 or not angle or angle<0 or angle>180) then
        return nil,'Unsupported aiming angle'
    end
    return {key=text_id(ctx.token,family.id,entity,hex(descriptor),hex(prefix)),token=ctx.token,
        game=ctx.game,world=ctx.world,manager=manager,entity=entity,family=family.id,
        descriptor=descriptor,prefix=prefix,address=address+family.angle,bytes=bytes,angle=angle,
        owned=owned,descriptor_address=ep}
end

function M:observe()
    local ctx,why=self:_context()
    if not ctx then return nil,why end
    local mem=self.mem
    local player,inventory=mem:ptr(ctx.game+OFF.player),mem:ptr(ctx.game+OFF.inventory)
    local unit=player and mem:u32(player+0x3A8)
    if not inventory or not valid_entity(unit) then return nil,'Waiting for local player' end
    local ui
    ui,why=mem:hashmap(ctx.world+0xF22EC8,unit)
    if not ui or ui>=1048576 then return nil,why or 'Waiting for local player' end
    local local_descriptor=mem:read(ctx.world+0xF32F18+ui*24,24)
    if not local_descriptor or Memory.u32_bytes(local_descriptor,16)~=unit
        or mem.bit.band(local_descriptor:byte(21),1)==0 then return nil,'Waiting for live local player' end
    local avatar=Memory.u32_bytes(local_descriptor,8)
    if not valid_entity(avatar) then return nil,'Waiting for local player' end
    local ii
    ii,why=mem:hashmap(inventory+0x28,avatar)
    local inventory_count=mem:u32(inventory+0x18)
    if not ii or not inventory_count or inventory_count>MAX_ROWS or ii>=inventory_count then
        return nil,why or 'Waiting for local inventory'
    end
    local inventory_descriptors=mem:ptr(inventory+0x40)
    local inventory_ep=inventory_descriptors and mem:ptr(inventory_descriptors+ii*8)
    local inventory_descriptor=inventory_ep and mem:read(inventory_ep,24)
    if not inventory_descriptor or inventory_descriptor:sub(1,16)~=local_descriptor:sub(1,16)
        or mem.bit.band(inventory_descriptor:byte(21),1)==0 then return nil,'Local inventory ownership changed' end
    local rows=mem:ptr(inventory+0x50)
    local row=rows and mem:read(rows+ii*48,48)
    if not row then return nil,'Waiting for local inventory' end
    local seen,weapons={},{}
    local missing,reasons=0,{}
    -- Primary, sidearm, support and held item. A held throwable/backpack only
    -- qualifies if it actually has this projectile-weapon component.
    for _,offset in ipairs({0,4,8,16,20}) do
        local entity=Memory.u32_bytes(row,offset)
        if valid_entity(entity) and not seen[entity] then
            seen[entity]=true
            local applicable=false
            for _,family in ipairs(FAMILIES) do
                local record,reason=self:_record(ctx,entity,family)
                if record then applicable=true;weapons[#weapons+1]=record
                elseif reason~='retired' and reason~='not applicable' then
                    applicable=true
                    missing=missing+1;reasons[#reasons+1]=family.id..': '..tostring(reason)
                end
            end
            if not applicable and offset<12 then
                missing=missing+1;reasons[#reasons+1]='Weapon '..entity..' has no available aiming component'
            end
        end
    end
    ctx.avatar,ctx.weapons,ctx.missing,ctx.reasons=avatar,weapons,missing,reasons
    return ctx
end

function M:resolve(record)
    if type(record)~='table' then return nil,'Invalid HOB lease' end
    local ctx,why=self:_context()
    if not ctx then return nil,why end
    if record.token~=ctx.token then return nil,'retired' end
    local current
    local family
    for _,item in ipairs(FAMILIES) do if item.id==record.family then family=item;break end end
    if not family then return nil,'Invalid aiming family' end
    current,why=self:_record(ctx,record.entity,family,true)
    if not current then return nil,why=='not applicable' and 'retired' or why end
    if current.key~=record.key then return nil,'retired' end
    return current
end

function M:write(record,expected,bytes)
    if type(expected)~='string' or #expected~=4 or type(bytes)~='string' or #bytes~=4 then
        return false,'HOB writes require exactly four bytes',0
    end
    local current,why=self:resolve(record)
    if not current then return false,why,0 end
    if current.bytes~=expected then return false,'Aiming definition changed externally',0 end
    if not current.owned then
        -- Never change the shared fallback. Ask the normal modifier component
        -- to clone it with zero patches, then re-discover its owned storage.
        local mem=self.mem
        local family
        for _,item in ipairs(FAMILIES) do if item.id==current.family then family=item;break end end
        local count,cap=mem:u32(current.manager+family.count),mem:u32(current.manager+family.cap)
        if not count or not cap or count>=cap or cap>MAX_ROWS then
            return false,'Owned aiming definition capacity exhausted',0
        end
        if not mem:ptr(current.manager+family.rows) then return false,'Owned definition buffer unavailable',0 end
        for _,offset in ipairs({family.owned_map,family.inverse_map}) do
            local map,reason=mem:_map_header(current.manager+offset)
            if not map or map.cap>MAX_ROWS or count+1>=map.cap then
                return false,reason or 'Owned definition map capacity exhausted',0
            end
        end
        local occupied,reason=mem:hashmap(current.manager+family.inverse_map,count)
        if occupied or not retired_lookup(reason) then return false,reason or 'Next definition index is already owned',0 end
        local source=mem:read(current.address-family.angle,family.stride)
        if not source then return false,'Full source aiming definition is unreadable',0 end
        local rechecked
        rechecked,why=self:resolve(record)
        if not rechecked or rechecked.owned or rechecked.bytes~=expected
            or rechecked.descriptor_address~=current.descriptor_address then
            return false,why or 'Weapon changed before definition clone',0
        end
        -- All clone fingerprints were just checked by resolve(), and the
        -- descriptor belongs to the live component. No pointer is retained.
        local patch=mem._ffi.new('uint32_t[3]',family.component,0,0)
        local ok,result,detail
        if mem._io then
            if type(mem._io.materialize)~='function' then return false,'Injected materializer unavailable',0 end
            ok,result,detail=pcall(mem._io.materialize,current)
        else
            local clone=mem._ffi.cast('void (*)(void *, const void *, const void *)',current.game+family.clone)
            ok,result=pcall(clone,mem._ffi.cast('void *',current.manager),
                mem._ffi.cast('const void *',current.descriptor_address),patch)
        end
        if not ok or result==false then return false,detail or tostring(result),0 end
        current,why=self:resolve(record)
        if not current or not current.owned then return false,why or 'Owned definition clone not acknowledged',0 end
        if current.bytes~=expected then return false,'Cloned aiming definition differs from source',0 end
        if mem:read(current.address-family.angle,family.stride)~=source then
            return false,'Cloned definition is not an exact source copy',0
        end
    end
    return self.mem:copy(current.address,bytes)
end

return M
