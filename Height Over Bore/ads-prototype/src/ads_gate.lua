-- Read-only, build-specific ADS predicate. Importing performs no game access.
-- API: eligible, reason, snapshot = Gate.check(mem, ctx, descriptor24, held_or_nil)
-- mem is src/memory.lua's instance; ctx is a fresh Backend:_context() result.
-- descriptor24 is the fresh local World descriptor. If held_or_nil is supplied,
-- it must match the independently selected wield row. snapshot.held is the
-- selected entity. A snapshot is diagnostic, never reusable authorization.
-- False does not restore any lease: the caller must retire its existing owned
-- work separately. No writes, game-function calls or mode caching are performed.
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
    local reads={}
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
        camera=camera,request=request,request_bytes=record,read_count=#reads}
end

-- Negative-only fast path. It never authorizes a write or reuses pointers.
-- Unreadable/changing/first-person requests fall through to the full proof.
function M.inactive(mem,ctx)
    local ok, inactive, reason = pcall(function()
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
    end)
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
