-- Read-only, build-specific ADS predicate. Importing performs no game access.
-- API: eligible, reason, snapshot = Gate.check(mem, ctx, descriptor24, held_or_nil)
-- mem is src/memory.lua's instance; ctx is a fresh Backend:_context() result.
-- descriptor24 is the fresh local World descriptor. If held_or_nil is supplied,
-- it must match the independently selected wield row. snapshot.held is the
-- selected entity. A snapshot is diagnostic, never reusable authorization.
-- False does not restore any lease: the caller must retire its existing owned
-- work separately. No writes, game-function calls or mode caching are performed.
-- poll(mem,ctx,snapshot) is a settled-state hint, never write authorization.
-- It follows a prior successful check with fresh bounded identity/state reads.
local Memory = mod.require('src/memory.lua')
local M = {}
local LOW, LIMIT, U32 = 65536, 140737488355328, 4294967296
local MAX_ROWS, MAX_MAP, MAX_PROBES, MAX_CHARACTERS = 4096, 1048576, 4096, 8
local STAMP = 0x6AB3B43F
local FPS = {
    {0x12B29B0,'48895c2410574883ec20807904008bda488bf90f85010100008339000f85f8000000'},
    {0x12B2AE0,'4883ec28807904007446c6410400488b0d6baa1b02e8d6befcff'},
    {0x12B28A3,'48b800000000000001004985842480e85300'},
    {0xA41C0B,'488b0d5eb2a3024c8bb424b80000003a4104741984c074098bd3e8860d8700eb0c488b0d3db2a302e8a80e8700'},
    {0x127DEB4,'668338040f85fa0a0000b806000000'},
    {0x127E022,'4c8b642438418b4c240c894c246c'},
}
for _, item in ipairs(FPS) do
    item.bytes=item[2]:gsub('%x%x',function(p) return string.char(tonumber(p,16)) end)
end
local function integer(v,max)
    return type(v)=='number' and v==math.floor(v) and v>=0 and v<=max
end
local function pointer(v) return integer(v,LIMIT-1) and v>=LOW end
local function entity(v) return integer(v,U32-2) and v>0 end
local function power2(v)
    if not integer(v,MAX_MAP) or v==0 then return false end
    while v%2==0 do v=v/2 end
    return v==1
end
local function product32(a,b)
    local al,ah,bl,bh=a%65536,math.floor(a/65536),b%65536,math.floor(b/65536)
    return (al*bl+((al*bh+ah*bl)%65536)*65536)%U32
end
local function fail(reason) error({ads_reason=reason},0) end

local function inspect(mem,ctx,local_descriptor,expected_held)
    if type(mem)~='table' or type(mem.read)~='function' or type(ctx)~='table'
        or ctx.stamp~=STAMP or not pointer(ctx.game) or not pointer(ctx.world)
        or not pointer(ctx.implementation) then fail('ADS context is invalid') end
    if type(local_descriptor)~='string' or #local_descriptor~=24 then fail('ADS local descriptor must contain 24 bytes') end
    if expected_held~=nil and not entity(expected_held) then fail('ADS expected held entity is invalid') end
    local reads,maps={},{}
    local function read(at,n,label)
        if not pointer(at) or not integer(n,8192) or n==0 or at+n>LIMIT then fail('ADS '..label..' address is invalid') end
        local bytes=mem:read(at,n)
        if type(bytes)~='string' or #bytes~=n then fail('ADS '..label..' is unreadable') end
        reads[#reads+1]={address=at,size=n,bytes=bytes,label=label}
        return bytes
    end
    local function ptr(at,label)
        local result=Memory.pointer_bytes(read(at,8,label))
        if not result then fail('ADS '..label..' pointer is unavailable') end
        return result
    end
    local function u32(at,label) return Memory.u32_bytes(read(at,4,label)) end
    local function map(at,key,label,max_index)
        local h=read(at,20,label..' map header')
        local buckets=Memory.pointer_bytes(h)
        local cap,empty,mult=Memory.u32_bytes(h,8),Memory.u32_bytes(h,12),Memory.u32_bytes(h,16)
        if not buckets or not power2(cap) or buckets+cap*8>LIMIT then fail('ADS '..label..' map bounds are invalid') end
        if key==empty then fail('ADS '..label..' map key is empty') end
        local product=product32(key,mult)
        for probe=0,math.min(cap,MAX_PROBES)-1 do
            local row=read(buckets+((product+probe)%cap)*8,8,label..' map bucket')
            local found=Memory.u32_bytes(row)
            if found==empty then fail('ADS '..label..' entity is absent') end
            if found==key then
                local index=Memory.u32_bytes(row,4)
                if index>=max_index then fail('ADS '..label..' index exceeds bounds') end
                maps[label]={address=at,header=h,bucket=buckets+((product+probe)%cap)*8,
                    bytes=row,index=index,key=key}
                return index
            end
        end
        fail('ADS '..label..' map probe limit reached')
    end
    local game=ctx.game
    for _,item in ipairs(FPS) do
        if read(game+item[1],#item.bytes,'source fingerprint')~=item.bytes then fail('ADS source fingerprint mismatch') end
    end
    if ptr(game+0x346BF98,'World root')~=ctx.world
        or ptr(game+0x346BFC8,'implementation root')~=ctx.implementation then fail('ADS context roots changed') end
    local player=ptr(game+0x3326468,'local player')
    if u32(player+0x88,'local player count')==0 then fail('ADS local player is unavailable') end
    local light=u32(player+0x3A8,'local player Unit')
    if not entity(light) then fail('ADS local player Unit is invalid') end
    local li=map(ctx.world+0xF22EC8,light,'local player',MAX_MAP)
    local descriptor=read(ctx.world+0xF32F18+li*24,24,'local descriptor')
    if descriptor~=local_descriptor or Memory.u32_bytes(descriptor,16)~=light
        or descriptor:byte(21)%4~=1 then fail('ADS local descriptor ownership changed') end
    local avatar,body=Memory.u32_bytes(descriptor,8),Memory.u32_bytes(descriptor,12)
    if not entity(avatar) or not entity(body) then fail('ADS local owner or body UnitRef is invalid') end
    local character=ptr(game+0x3326D20,'character manager')
    local cc=u32(character+0x6C,'character count')
    -- Eight is this prototype's supported character scope, not a global engine claim.
    if cc==0 or cc>MAX_CHARACTERS then fail('ADS character count exceeds supported bounds') end
    local ci=map(character+0xF8,avatar,'character owner',cc)
    local cd=ptr(character+0x110+ci*8,'character descriptor')
    if read(cd,24,'character owner descriptor')~=descriptor then fail('ADS character owner descriptor changed') end
    local flags=read(character+0x53E880+ci*0x1238,24,'character state')
    if flags:byte(7)%2~=1 then fail('ADS character continuity flag is absent') end
    if math.floor(flags:byte(15)/4)%2~=0 then fail('ADS character is seated or in an unsupported state') end
    local wield=ptr(game+0x3326420,'wield manager')
    if wield~=ctx.implementation+0xE9FB10 then fail('ADS wield manager belongs to another World') end
    local count=u32(wield+0x1C,'wield count')
    if count==0 or count>MAX_ROWS then fail('ADS wield count exceeds bounds') end
    local wi=map(wield+0x30,avatar,'wield owner',count)
    local wdescs=ptr(wield+0x48,'wield descriptors')
    local wdesc=ptr(wdescs+wi*8,'wield descriptor')
    if read(wdesc,24,'wield owner descriptor')~=descriptor then fail('ADS wield owner descriptor changed') end
    local rows=ptr(wield+0x60,'wield rows')
    local held=u32(rows+wi*0x1D0,'held entity')
    if not entity(held) or expected_held~=nil and held~=expected_held then fail('ADS held weapon changed') end
    local hi=map(ctx.world+0xF1AEB0,held,'held weapon',MAX_MAP)
    local held_descriptor=read(ctx.world+0xF32F18+hi*24,24,'held weapon descriptor')
    if Memory.u32_bytes(held_descriptor,8)~=held or held_descriptor:byte(21)%4~=1
        or not entity(Memory.u32_bytes(held_descriptor,12)) then fail('ADS held weapon descriptor is retired') end
    local controller=ptr(game+0x347CE70,'controller')
    local controls=read(controller,6,'controller state')
    if Memory.u32_bytes(controls)~=0 then fail('ADS controller is inhibited') end
    if controls:byte(6)~=0 then fail('ADS controller guard is active') end
    if controls:byte(5)~=1 then fail('ADS controller is inactive or unsupported') end
    local camera_context=ptr(game+0x346D560,'camera context')
    local camera=ptr(camera_context,'camera')
    local queue=read(camera_context+0x1F8,8,'camera queue')
    local head,tail=Memory.u32_bytes(queue),Memory.u32_bytes(queue,4)
    if head>=32 or tail>=32 then fail('ADS camera queue indices are invalid') end
    if head==tail then fail('ADS camera queue is empty') end
    local request=camera_context+0x200+((tail+31)%32)*0xE8
    local record=read(request,16,'camera request')
    if record:byte(1)+record:byte(2)*256~=6 then fail('ADS latest camera request is not first person') end
    if Memory.u32_bytes(record,4)~=avatar or Memory.u32_bytes(record,8)~=held
        or Memory.u32_bytes(record,12)~=body then fail('ADS camera request ownership changed') end
    for _,r in ipairs(reads) do
        if mem:read(r.address,r.size)~=r.bytes then fail('ADS '..r.label..' changed during observation') end
    end
    return true,nil,{held=held,avatar=avatar,body=body,local_descriptor=descriptor,
        held_descriptor=held_descriptor,controller=controller,controller_bytes=controls,
        character=character,character_index=ci,camera_context=camera_context,
        camera=camera,request=request,request_bytes=record,read_count=#reads,
        poll={game=game,world=ctx.world,implementation=ctx.implementation,token=ctx.token,
            player=player,light=light,local_index=li,character_count=cc,character_descriptor=cd,
            wield=wield,wield_count=count,wield_index=wi,wield_descriptors=wdescs,
            wield_descriptor=wdesc,wield_rows=rows,held_index=hi,maps=maps}}
end

-- No cached result grants permission to mutate memory. Identity or layout
-- changes return nil so the caller re-enters the full discovery/cleanup route.
-- Only values proved by check are cached; semantic mode fields are read fresh.
-- Keep the settled path's helpers stable: creating closures inside every poll
-- adds allocation and prevents LuaJIT compiling the enclosing hot function.
local function poll_read(mem,at,n,label)
    if not pointer(at) or not integer(n,8192) or n==0 or at+n>LIMIT then
        fail('ADS cached '..label..' address is invalid')
    end
    local bytes=mem:read(at,n)
    if type(bytes)~='string' or #bytes~=n then fail('ADS cached '..label..' is unreadable') end
    return bytes
end
local function poll_same(mem,at,bytes,label)
    if type(bytes)~='string' or poll_read(mem,at,#bytes,label)~=bytes then fail('ADS cached '..label..' changed') end
end
local function poll_ptr(mem,at,expected,label)
    local bytes=poll_read(mem,at,8,label)
    if Memory.pointer_bytes(bytes)~=expected then fail('ADS cached '..label..' changed') end
end
local function poll_map(mem,s,label,header)
    local cached=s.maps and s.maps[label]
    if type(cached)~='table' then fail('ADS cached '..label..' map is unavailable') end
    if header then
        if header~=cached.header then fail('ADS cached '..label..' map changed') end
    else poll_same(mem,cached.address,cached.header,label..' map') end
    poll_same(mem,cached.bucket,cached.bytes,label..' map row')
end
local function poll_done(mem,s,snapshot,roots,held_address,held_bytes,controls,queue,request,record,result,why)
    if poll_read(mem,s.game+0x346BF98,0x38,'closing World roots')~=roots
        or poll_read(mem,held_address,4,'closing held entity')~=held_bytes
        or controls and poll_read(mem,snapshot.controller,6,'closing controller')~=controls
        or queue and poll_read(mem,snapshot.camera_context+0x1F8,8,'closing camera queue')~=queue
        or request and poll_read(mem,request,16,'closing camera request')~=record then
        fail('ADS cached state changed during polling')
    end
    return result,why
end
local function poll_inspect(mem,ctx,snapshot)
        local s=type(snapshot)=='table' and snapshot.poll
        if type(s)~='table' or type(ctx)~='table' or ctx.stamp~=STAMP
            or ctx.game~=s.game or ctx.world~=s.world or ctx.implementation~=s.implementation
            or ctx.token~=s.token or type(mem)~='table' or type(mem.read)~='function' then
            fail('ADS cached context changed')
        end
        -- Adjacent fixed roots are copied together; unknown intervening bytes
        -- are ignored rather than invalidating the cache on unrelated changes.
        local roots=poll_read(mem,s.game+0x346BF98,0x38,'World roots')
        if Memory.pointer_bytes(roots)~=s.world or Memory.pointer_bytes(roots,0x30)~=s.implementation then
            fail('ADS cached World roots changed')
        end
        local owners=poll_read(mem,s.game+0x3326420,0x50,'local owner roots')
        if Memory.pointer_bytes(owners)~=s.wield or Memory.pointer_bytes(owners,0x48)~=s.player then
            fail('ADS cached local owner roots changed')
        end
        if not pointer(s.player) or not pointer(s.wield) or s.wield~=s.implementation+0xE9FB10 then
            fail('ADS cached local owner is invalid')
        end
        local player=poll_read(mem,s.player+0x88,0x324,'local player state')
        if Memory.u32_bytes(player)==0 or Memory.u32_bytes(player,0x320)~=s.light then
            fail('ADS cached local player changed')
        end
        -- Character and wield descriptors independently bind the same local
        -- owner/Unit. Replaying the local World map would duplicate that proof.
        poll_ptr(mem,s.game+0x3326D20,snapshot.character,'character manager')
        local cm=poll_read(mem,snapshot.character+0x6C,0xAC+snapshot.character_index*8,'character layout')
        if Memory.u32_bytes(cm)~=s.character_count then
            fail('ADS cached character layout changed')
        end
        poll_map(mem,s,'character owner',cm:sub(0x8D,0xA0))
        if Memory.pointer_bytes(cm,0xA4+snapshot.character_index*8)~=s.character_descriptor then
            fail('ADS cached character descriptor moved')
        end
        poll_same(mem,s.character_descriptor,snapshot.local_descriptor,'character owner descriptor')
        local flags=poll_read(mem,snapshot.character+0x53E886+snapshot.character_index*0x1238,9,'character state')
        local wm=poll_read(mem,s.wield+0x1C,0x4C,'wield layout')
        if Memory.u32_bytes(wm)~=s.wield_count or Memory.pointer_bytes(wm,0x2C)~=s.wield_descriptors
            or Memory.pointer_bytes(wm,0x44)~=s.wield_rows then fail('ADS cached wield layout changed') end
        poll_map(mem,s,'wield owner',wm:sub(0x15,0x28))
        poll_ptr(mem,s.wield_descriptors+s.wield_index*8,s.wield_descriptor,'wield descriptor')
        poll_same(mem,s.wield_descriptor,snapshot.local_descriptor,'wield owner descriptor')
        local held_address=s.wield_rows+s.wield_index*0x1D0
        local held_bytes=poll_read(mem,held_address,4,'held entity')
        if Memory.u32_bytes(held_bytes)~=snapshot.held then
            fail('ADS cached held weapon changed')
        end
        -- The backend's independent settled component watcher must check the
        -- held World descriptor and runtime component identity. This hint alone
        -- does not prove an equipped component or authorize a cap write.
        local controls,queue,record,request
        if flags:byte(1)%2~=1 then
            return poll_done(mem,s,snapshot,roots,held_address,held_bytes,nil,nil,nil,nil,
                'native','ADS character continuity flag is absent')
        end
        if math.floor(flags:byte(9)/4)%2~=0 then
            return poll_done(mem,s,snapshot,roots,held_address,held_bytes,nil,nil,nil,nil,
                'native','ADS character is seated or unsupported')
        end
        local controller_root=poll_read(mem,s.game+0x347CE70,8,'controller root')
        local controller=Memory.pointer_bytes(controller_root)
        if controller~=snapshot.controller then fail('ADS cached controller root changed') end
        controls=poll_read(mem,controller,6,'controller state')
        if Memory.u32_bytes(controls)~=0 or controls:byte(6)~=0 or controls:byte(5)~=1 then
            return poll_done(mem,s,snapshot,roots,held_address,held_bytes,controls,nil,nil,nil,
                'native','ADS controller is inactive, inhibited or unsupported')
        end
        poll_ptr(mem,s.game+0x346D560,snapshot.camera_context,'camera context')
        poll_ptr(mem,snapshot.camera_context,snapshot.camera,'camera')
        queue=poll_read(mem,snapshot.camera_context+0x1F8,8,'camera queue')
        local head,tail=Memory.u32_bytes(queue),Memory.u32_bytes(queue,4)
        if head>=32 or tail>=32 then fail('ADS cached camera queue indices are invalid') end
        if head==tail then
            return poll_done(mem,s,snapshot,roots,held_address,held_bytes,controls,queue,nil,nil,
                'native','ADS camera queue is empty')
        end
        request=snapshot.camera_context+0x200+((tail+31)%32)*0xE8
        record=poll_read(mem,request,16,'camera request')
        if record:byte(1)+record:byte(2)*256~=6 then
            return poll_done(mem,s,snapshot,roots,held_address,held_bytes,controls,queue,request,record,
                'native','ADS latest camera request is not first person')
        end
        if Memory.u32_bytes(record,4)~=snapshot.avatar or Memory.u32_bytes(record,8)~=snapshot.held
            or Memory.u32_bytes(record,12)~=snapshot.body then fail('ADS cached camera request ownership changed') end
        return poll_done(mem,s,snapshot,roots,held_address,held_bytes,controls,queue,request,record,'ads')
end
function M.poll(mem,ctx,snapshot)
    local ok,mode,reason=pcall(poll_inspect,mem,ctx,snapshot)
    if not ok then return nil,type(mode)=='table' and mode.ads_reason or 'ADS cached reader failed' end
    return mode,reason
end

-- Single-pass transition hint for a previously admitted equip. It does not
-- replay maps, descriptors or authored data, and never authorizes a copy.
-- All positive acquisition and restoration still take the full fresh proof.
local function edge_inspect(mem,ctx,snapshot)
    local s=type(snapshot)=='table' and snapshot.poll
    if type(s)~='table' or type(ctx)~='table' or ctx.stamp~=STAMP
        or ctx.game~=s.game or ctx.world~=s.world or ctx.implementation~=s.implementation
        or ctx.token~=s.token then fail('ADS equipped context changed') end
    local roots=poll_read(mem,s.game+0x346BF98,0x38,'World roots')
    if Memory.pointer_bytes(roots)~=s.world or Memory.pointer_bytes(roots,0x30)~=s.implementation then
        fail('ADS equipped World changed')
    end
    poll_ptr(mem,s.game+0x347CE70,snapshot.controller,'controller root')
    local controls=poll_read(mem,snapshot.controller,6,'controller state')
    if Memory.u32_bytes(controls)~=0 or controls:byte(6)~=0 or controls:byte(5)~=1 then
        return 'native','ADS controller is inactive, inhibited or unsupported'
    end
    poll_ptr(mem,s.game+0x346D560,snapshot.camera_context,'camera context')
    local camera=poll_read(mem,snapshot.camera_context,0x200,'camera header')
    if Memory.pointer_bytes(camera)~=snapshot.camera then fail('ADS equipped camera changed') end
    local head,tail=Memory.u32_bytes(camera,0x1F8),Memory.u32_bytes(camera,0x1FC)
    if head>=32 or tail>=32 then fail('ADS equipped camera queue indices are invalid') end
    if head==tail then return 'native','ADS camera queue is empty' end
    local at=snapshot.camera_context+0x200+((tail+31)%32)*0xE8
    local request=poll_read(mem,at,16,'camera request')
    if request:byte(1)+request:byte(2)*256~=6 then return 'native','ADS camera is not first person' end
    if Memory.u32_bytes(request,4)~=snapshot.avatar or Memory.u32_bytes(request,8)~=snapshot.held
        or Memory.u32_bytes(request,12)~=snapshot.body then fail('ADS equipped camera owner or weapon changed') end
    -- One image copy covers the three owner roots and projectile manager root.
    -- Ignore intervening globals; only these admitted pointer slices compare.
    local owners=poll_read(mem,s.game+0x3326420,0x908,'equip roots')
    if Memory.pointer_bytes(owners)~=s.wield or Memory.pointer_bytes(owners,0x48)~=s.player
        or Memory.pointer_bytes(owners,0x900)~=snapshot.character
        or ctx.managers and ctx.managers.projectile
            and Memory.pointer_bytes(owners,0x2B8)~=ctx.managers.projectile then
        fail('ADS equipped owner roots changed')
    end
    if Memory.u32_bytes(poll_read(mem,s.player+0x3A8,4,'local Unit'))~=s.light then
        fail('ADS equipped local owner changed')
    end
    local wield=poll_read(mem,s.wield+0x1C,0x4C,'equip layout')
    local count=Memory.u32_bytes(wield)
    if count==0 or count>MAX_ROWS or s.wield_index>=count
        or Memory.pointer_bytes(wield,0x2C)~=s.wield_descriptors
        or Memory.pointer_bytes(wield,0x44)~=s.wield_rows then fail('ADS equipped storage changed') end
    if Memory.u32_bytes(poll_read(mem,s.wield_rows+s.wield_index*0x1D0,4,'held entity'))~=snapshot.held then
        fail('ADS equipped held weapon changed')
    end
    local flags=poll_read(mem,snapshot.character+0x53E886+snapshot.character_index*0x1238,9,'character state')
    if flags:byte(1)%2~=1 or math.floor(flags:byte(9)/4)%2~=0 then
        return 'native','ADS character is inactive or unsupported'
    end
    return 'ads'
end
function M.edge(mem,ctx,snapshot)
    local ok,mode,reason=pcall(edge_inspect,mem,ctx,snapshot)
    if not ok then return nil,type(mode)=='table' and mode.ads_reason or 'ADS transition reader failed' end
    return mode,reason
end

-- Native-state hint: stop after a fresh controller/camera rejection. No
-- closing replay is needed for this non-authorizing, read-only observation.
local function idle_inspect(mem,ctx)
    local controller=Memory.pointer_bytes(poll_read(mem,ctx.game+0x347CE70,8,'controller root'))
    local controls=poll_read(mem,controller,6,'controller state')
    if Memory.u32_bytes(controls)~=0 or controls:byte(6)~=0 or controls:byte(5)~=1 then return true end
    local camera=Memory.pointer_bytes(poll_read(mem,ctx.game+0x346D560,8,'camera context'))
    local queue=poll_read(mem,camera+0x1F8,8,'camera queue')
    local head,tail=Memory.u32_bytes(queue),Memory.u32_bytes(queue,4)
    if head>=32 or tail>=32 then return false end
    if head==tail then return true end
    local request=poll_read(mem,camera+0x200+((tail+31)%32)*0xE8,2,'camera kind')
    return request:byte(1)+request:byte(2)*256~=6
end
function M.idle(mem,ctx)
    local ok,inactive=pcall(idle_inspect,mem,ctx)
    return ok and inactive==true
end

-- Negative-only fast path. It never authorizes a write or reuses pointers.
-- Unreadable/changing/first-person requests fall through to the full proof.
local function inspect_inactive(mem,ctx)
        local controller_root = ctx.game + 0x347CE70
        local controller_bytes = mem:read(controller_root,8)
        local controller = Memory.pointer_bytes(controller_bytes)
        local controls = controller and mem:read(controller,6)
        if controls and (Memory.u32_bytes(controls)~=0 or controls:byte(6)~=0 or controls:byte(5)~=1) then
            if mem:read(controller_root,8)==controller_bytes and mem:read(controller,6)==controls then
                return true, 'ADS controller is inactive, inhibited or unsupported'
            end
            return false
        end
        local root = ctx.game + 0x346D560
        local root_bytes = mem:read(root,8)
        local camera_context = Memory.pointer_bytes(root_bytes)
        if not camera_context then return false end
        local queue = mem:read(camera_context+0x1F8,8)
        if not queue then return false end
        local head,tail = Memory.u32_bytes(queue),Memory.u32_bytes(queue,4)
        if head>=32 or tail>=32 then return false end
        local request, record
        if head~=tail then
            request = camera_context+0x200+((tail+31)%32)*0xE8
            record = mem:read(request,16)
            if not record or record:byte(1)+record:byte(2)*256==6 then return false end
        end
        if mem:read(root,8)~=root_bytes or mem:read(camera_context+0x1F8,8)~=queue
            or request and mem:read(request,16)~=record then return false end
        return true, head==tail and 'ADS camera queue is empty' or 'ADS latest camera request is not first person'
end
function M.inactive(mem,ctx)
    local ok,inactive,reason=pcall(inspect_inactive,mem,ctx)
    if not ok then return false end
    return inactive, reason
end

function M.check(mem,ctx,local_descriptor,held_or_nil)
    local ok,eligible,why,snapshot=pcall(inspect,mem,ctx,local_descriptor,held_or_nil)
    if not ok then
        return false,type(eligible)=='table' and eligible.ads_reason or 'ADS gate reader failed'
    end
    return eligible,why,snapshot
end
return M
