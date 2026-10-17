-- Temporary same-primary native attachment test. Import performs no game access.
-- The caller must own every held/spare package and native animation cleanup.
local M = {}
local FP = '4053555741544883ec78488b051f62eb014833c448894424503b1521decf0241'
local function hexbytes(s) return (s:gsub('.',function(c) return string.format('%02x',c:byte()) end)) end
function M.run(expected_avatar)
    local H=use('hd2_addresses');local A=assert(H.get())
    assert(A.stamp==0x6AB3B43F,'Unsupported rebind build')
    local samples={}
    local function r(at,n)
        local bytes=assert(read(at,n),'Rebind memory unreadable')
        assert(#bytes==n,'Rebind short read');samples[#samples+1]={at,n,bytes};return bytes
    end
    local function p(at) local value=get(r(at,8),0,'u64');local n=tonumber(value);assert(n and n>=65536 and n<140737488355328,'Rebind pointer unavailable');return n end
    local function n(at) return get(r(at,4),0,'u32') end
    local function live(bytes) return bytes:byte(21)%2==1 end
    local world=p(game+A.WORLD)
    local function descriptor(entity)
        local i=hashmap(world+A.WORLD_ENTITIES,entity)
        assert(i and i<1048576,'Rebind entity absent')
        local bytes=r(world+A.WORLD_RECORDS+i*24,24)
        assert(get(bytes,8,'u32')==entity and live(bytes),'Rebind entity retired')
        return bytes
    end
    local avatar,inv=H.avatar(A)
    assert(avatar==expected_avatar and inv,'Rebind avatar changed')
    local ad=descriptor(avatar)
    local ii=assert(hashmap(inv+0x28,avatar))
    assert(ii<n(inv+0x18) and n(inv+0x18)<=4096,'Rebind inventory row out of bounds')
    local id=r(p(p(inv+0x40)+ii*8),24)
    assert(id:sub(1,16)==ad:sub(1,16) and live(id),'Rebind inventory owner changed')
    local row=r(p(inv+0x50)+ii*48,48)
    assert(get(row,0x1C,'u32')==1,'Draw the primary before rebind')
    local primary=get(row,0,'u32')
    assert(primary~=0 and primary~=0xFFFFFFFF,'Rebind primary is empty')
    local pd=descriptor(primary)
    local ww=p(game+0x3326420)
    local wi=assert(hashmap(ww+0x30,avatar))
    local count,capacity=n(ww+0x1C),n(ww+0x20)
    assert(count<=capacity and capacity<=0x10000 and wi<count,'Rebind Wielder bounds differ')
    local wd=r(p(p(ww+0x48)+wi*8),24)
    assert(wd:sub(1,16)==ad:sub(1,16) and live(wd),'Rebind Wielder owner changed')
    local runtime=p(ww+0x60)+wi*0x1D0
    local pair=r(runtime,8)
    assert(get(pair,0,'u32')==primary,'Rebind primary is not currently held')
    local spare=get(pair,4,'u32')
    local invalid,none=n(game+0x3483C20),n(game+0x3483C34)
    if spare~=0 and spare~=invalid and spare~=none then descriptor(spare) end
    local wieldable=p(game+0x3326730)
    local wr=assert(hashmap(wieldable+0x18,primary))
    local wc,wcap=n(wieldable+8),n(wieldable)
    assert(wc<=wcap and wcap<=1048576 and wr<wc,'Rebind Wieldable bounds differ')
    local wpd=r(p(p(wieldable+0x30)+wr*8),24)
    assert(wpd:sub(1,16)==pd:sub(1,16) and live(wpd),'Rebind Wieldable identity changed')
    assert(hexbytes(r(game+0x785DE0,#FP/2))==FP,'Rebind fingerprint differs')
    local call=assert(native(game+0x785DE0,
        'void (*)(void *, uint32_t, uint32_t, uint32_t, uint32_t)',FP,'BRIDGE_SAME_PRIMARY_ATTACH'))
    for _,s in ipairs(samples) do assert(read(s[1],s[2])==s[3],'Rebind snapshot changed') end
    assert(H.avatar(A)==avatar,'Rebind local player changed')
    call(ffi.cast('void *',ww),avatar,0,primary,0)
    local av,im,after=H.avatar(A)
    assert(av==avatar and im==inv and after and get(after,0,'u32')==primary
        and get(after,0x1C,'u32')==1,'Rebind changed inventory identity')
    local after_i=assert(hashmap(ww+0x30,avatar))
    assert(u32(ptr(ww+0x60)+after_i*0x1D0)==primary,'Rebind held identity not acknowledged')
    out('PRIMARY_REBIND_ACK',avatar,primary,'same selection; notify0')
    return true
end
return M
