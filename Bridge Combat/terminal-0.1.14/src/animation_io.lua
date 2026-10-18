-- Standalone protected IO for the maintained animation/resource leases.
-- Import/new perform no game access, FFI declarations, or DLL helper loads.
local M = {}
local STAMPS = {['game.dll']=0x6AB3B43F,['helldivers2.exe']=0x6AB382E4}
local MIN_IMAGE = {['game.dll']=0x347CF20,['helldivers2.exe']=0x1A100F8}
local RVAS = {GAME_STATE=0x3326340,STATE_VALUE=0xAC21C,WORLD=0x346BF98,
    PLAYER=0x3326468,INVENTORY=0x3326738,WORLD_UNITS=0xF22EC8,
    WORLD_ENTITIES=0xF1AEB0,WORLD_RECORDS=0xF32F18,ENGINE=0x3326308,
    PACKAGES=0x347CEB0,PACKAGE_REQUEST=0x12FE350,PACKAGE_RELEASE=0x12FE4E0}
local HAS_LOADED_SHAPE = '48895c2408574883ec20488b05????????488bd1488bf9488b9800040000488b8b08020000e8'
local function integer(value,maximum)
    return type(value)=='number' and value==math.floor(value) and value>=0 and value<=maximum
end
local function u32(bytes,off)
    off=off or 0
    if type(bytes)~='string' or #bytes<off+4 then return end
    local a,b,c,d=bytes:byte(off+1,off+4);return a+b*256+c*65536+d*16777216
end
local function pointer(bytes)
    local low,high=u32(bytes),u32(bytes,4)
    local value=low and high and low+high*4294967296
    return value and value>=65536 and value<2^47 and value or nil
end
local function hex(bytes)return(bytes:gsub('.',function(c)return('%02x'):format(c:byte())end))end
local function unhex(bytes)return(bytes:gsub('..',function(c)return string.char(tonumber(c,16))end))end
local function protected(fn)
    local ok,a,b,c=pcall(fn);if not ok then return nil,tostring(a)end;return a,b,c
end
local PackageResolver=(function()
-- Offline-authored read-only mirror, game.dll stamp 6AB3B43F.
-- Loading this file makes no game reads/calls. Pass a protected read(addr,n)
-- function explicitly. No writes, native calls, package requests or releases.
local M = {}
local ZERO8 = string.rep('\0', 8)
local FP = {
    base = {0x4F5680, '4885c97471488b050c69f702448bc14c8b905825f10048b8'},
    instance = {0x4F5B40, '4883ec284c8bd14885c9750733c04883c428c38b41083b05'},
    materialize = {0x9C5D20, '48895c240848896c2410488974241848897c242041564883'},
    single = {0x4F5710, '48896c2410488974241848897c242041564883ec20498bf0'},
    list = {0x4F57C0, '40564881ec00010000488b05406814024833c448898424e0'},
    modifier = {0x5154C0, '48895c2408488b05cc6af50233d24533c04c8bd9488b9898'},
    overlay = {0x515540, '48895c240848896c24104889742418574883ec208b5a0449'},
}
local function hex(s)
    return (s:gsub('.', function(c) return string.format('%02X', c:byte()) end))
end
local function unhex(s)
    return (s:gsub('%x%x', function(p) return string.char(tonumber(p, 16)) end))
end
local function number32(s, at)
    local a,b,c,d = s:byte(at or 1, (at or 1) + 3)
    return a + b*256 + c*65536 + d*16777216
end
local function number64(s)
    return number32(s) + number32(s, 5)*4294967296
end
local function remainder64(s, cap)
    local n = 0
    for i=8,1,-1 do n = (n*256 + s:byte(i)) % cap end
    return n
end
local function multiply32(a,b)
    local lo = (a%65536)*(b%65536)
    local mid = ((a%65536)*math.floor(b/65536) + math.floor(a/65536)*(b%65536))%65536
    return (lo + mid*65536)%4294967296
end
local function session(read, game, world, names)
    assert(type(read)=='function', 'a protected read function is required')
    local samples, order, reads = {}, {}, 0
    local function r(at,n)
        assert(type(at)=='number' and at==math.floor(at) and at>=65536
            and n>=1 and n<=32 and at+n<=140737488355328, 'read address/size refused')
        reads = reads+1
        assert(reads<=32768, 'read budget exhausted')
        local value = read(at,n)
        assert(type(value)=='string' and #value==n, 'unreadable field at '..string.format('%X',at))
        local key = tostring(at)..':'..n
        if samples[key] then assert(samples[key].value==value, 'identity changed during observation')
        else samples[key]={at=at,n=n,value=value}; order[#order+1]=samples[key] end
        return value
    end
    local function u32(at) return number32(r(at,4)) end
    local function ptr(at)
        local p = number64(r(at,8))
        assert(p>=65536 and p<140737488355328 and p==math.floor(p), 'null/invalid pointer')
        return p
    end
    -- Native u32->u32 open-addressed map; absence and unreadability differ.
    local function map(at,key)
        local h=r(at,20); local rows=number64(h); local cap=number32(h,9)
        local empty,mult=number32(h,13),number32(h,17)
        assert(cap>0 and cap<=1048576 and cap==2^math.floor(math.log(cap)/math.log(2)+0.5), 'map capacity refused')
        assert(key~=empty, 'map empty sentinel is not an entity')
        for probe=0,math.min(cap,4096)-1 do
            local row=r(rows+((multiply32(key,mult)+probe)%cap)*8,8)
            local have=number32(row)
            if have==key then local index=number32(row,5); return index~=4294967295 and index or false end
            if have==empty then return false end
        end
        error('map probe bound reached without proven absence')
    end
    assert(r(game,2)=='MZ', 'game PE signature differs')
    local pe=u32(game+0x3C)
    assert(pe>=64 and pe<=4096 and r(game+pe,4)=='PE\0\0', 'game PE header differs')
    assert(u32(game+pe+8)==0x6AB3B43F, 'game build differs')
    for _,name in ipairs(names) do
        local f=assert(FP[name]); assert(r(game+f[1],24)==unhex(f[2]), name..' fingerprint differs')
    end
    assert(ptr(game+0x346BF98)==world, 'current ECS world differs')
    local function base(type_bytes)
        assert(type(type_bytes)=='string' and #type_bytes==8 and type_bytes~=ZERO8, 'invalid type hash')
        local table_at=ptr(world+0xF12558); local bucket=remainder64(type_bytes,0x438)
        for probe=0,0x438-1 do
            local slot=r(table_at+((bucket+probe)%0x438)*16,16)
            local key=slot:sub(1,8)
            if key==type_bytes then
                local index=number32(slot,9)
                -- 4F5B20 / 9C5E0B place the default record at +8700.
                assert(index<0x21C, 'base definition index exceeds the pre-default region')
                local component=table_at+0x4380+index*32
                return component,r(component,32)
            end
            if key==ZERO8 then return nil end
        end
        return nil
    end
    local function finish()
        for _,s in ipairs(order) do assert(read(s.at,s.n)==s.value, 'snapshot changed before acknowledgement') end
    end
    return r,u32,ptr,map,base,finish
end
local function protected(fn)
    local ok,value=pcall(fn)
    if ok then return value end
    return nil,tostring(value)
end

-- Native-equivalent instance lookup 4F5B40, with extra descriptor/inverse checks.
-- Result identifies a package only; it confers no package lifetime ownership.
function M.resolve(read, game, world, entity)
    return protected(function()
        assert(type(entity)=='number' and entity>0 and entity<4294967295 and entity==math.floor(entity), 'invalid entity')
        local r,u32,ptr,map,base,finish=session(read,game,world,{'base','instance','materialize'})
        local wi=map(world+0xF1AEB0,entity); assert(wi~=false and wi<1048576, 'entity is absent')
        local descriptor=world+0xF32F18+wi*24; local identity=r(descriptor,24)
        assert(number32(identity,9)==entity and identity:byte(21)%2==1, 'entity descriptor is not live')
        local type_bytes=identity:sub(1,8); assert(type_bytes~=ZERO8, 'entity type is empty')
        local manager=ptr(game+0x3326C40)
        local index=map(manager+0xD0,entity)
        local component,bytes,source
        if index~=false then
            local capacity,count=u32(manager+0x84),u32(manager+0x108)
            assert(capacity>0 and capacity<=1048576 and count<=capacity and index<count, 'dynamic definition bounds differ')
            assert(map(manager+0xF0,index)==entity, 'dynamic definition inverse owner differs')
            component=ptr(manager+0x110)+index*32; bytes=r(component,32); source='instance'
        else component,bytes=base(type_bytes); source='base' end
        assert(component and bytes, 'entity has no LoadoutPackage component')
        local package_bytes=bytes:sub(9,16); assert(package_bytes~=ZERO8, 'effective package is empty')
        finish()
        return {entity=entity,descriptor=descriptor,reference=number32(identity,13),world=world,
            manager=manager,component=component,component_bytes=bytes,source=source,
            dynamic_index=index~=false and index or nil,type_hex=hex(type_bytes:reverse()),
            package_bytes=package_bytes,package_hex=hex(package_bytes:reverse())}
    end)
end

return M

end)()
function M.new(backend,injected)
    assert(type(backend)=='table' and type(backend.read)=='function'
        and type(backend.hashmap)=='function' and type(backend._avatar)=='function',
        'Protected Bridge Combat backend is required')
    injected=injected or {}
    local io={}
    local native_types,native_bindings={},{}
    local function ffi()return backend._ffi or require('ffi')end
    function io.read(address,size)
        return protected(function()
            assert(integer(address,2^47-1) and address>=65536 and integer(size,65536)
                and size>0 and address+size<=2^47,'Animation read bounds differ')
            local chunks={}
            for offset=0,size-1,8192 do
                local count=math.min(8192,size-offset)
                local bytes,why=backend:read(address+offset,count)
                assert(type(bytes)=='string' and #bytes==count,why or 'Animation memory is unreadable')
                chunks[#chunks+1]=bytes
            end
            return table.concat(chunks)
        end)
    end
    local function read(address,size)return assert(io.read(address,size))end
    local function ptr(address)return assert(pointer(read(address,8)),'Animation pointer is unavailable')end
    local function lookup(name)
        if injected.module then return injected.module(name)end
        local kernel,why=backend:_windows();assert(kernel,why)
        local value=kernel.module(name)
        return tonumber(ffi().cast('uintptr_t',value))
    end
    function io.module(name)
        return protected(function()
            assert(type(name)=='string' and STAMPS[name:lower()],'Unsupported animation module name')
            name=name:lower();local base=lookup(name)
            assert(integer(base,2^47-1) and base>=65536,'Animation module is unavailable')
            local dos=read(base,64);assert(dos:sub(1,2)=='MZ','Animation DOS header differs')
            local offset=u32(dos,0x3C);assert(offset>=64 and offset<=4096,'Animation PE offset differs')
            local pe=read(base+offset,96)
            assert(pe:sub(1,4)=='PE\0\0' and pe:sub(5,6)=='\100\134'
                and pe:sub(25,26)=='\11\2','Animation module is not AMD64 PE32+')
            local stamp,size=u32(pe,8),u32(pe,80)
            assert(stamp==STAMPS[name],'Unsupported animation module build')
            assert(size>=MIN_IMAGE[name] and size<=0x80000000 and base+size<2^47,'Animation module size differs')
            assert(lookup(name)==base,'Animation module identity changed')
            return base,size,stamp
        end)
    end
    function io.addresses()
        local base,why,stamp=io.module('game.dll');if not base then return nil,why end
        local A={base=base,stamp=stamp}
        for name,value in pairs(RVAS)do A[name]=value end
        return A
    end
    function io.game()local A,why=io.addresses();return A and A.base or nil,why end
    function io.meta()local A,why=io.addresses();return A and {game=A.base,A=A}or nil,why end
    function io.avatar(A)
        return protected(function()
            local current,why=io.addresses();assert(current,why)
            assert(type(A)=='table' and A.base==current.base and A.stamp==current.stamp,'Avatar game identity changed')
            return backend:_avatar(current.base,ptr(current.base+current.WORLD))
        end)
    end
    function io.hashmap(address,key)return backend:hashmap(address,key)end
    local function native_owner(address,size)
        for _,name in ipairs({'game.dll','helldivers2.exe'})do
            local base,length,stamp=io.module(name)
            if base and address>=base and address+size<=base+length then
                return name,base,length,stamp
            end
        end
        error('Animation native address is outside verified modules')
    end
    function io.native(address,abi,fingerprint,label)
        return protected(function()
            assert(integer(address,2^47-1) and address>=65536 and type(abi)=='string'
                and #abi>0 and #abi<=256 and abi:find('%(%s*%*%s*%)%s*%('),
                'Animation native signature is invalid')
            assert(type(fingerprint)=='string' and #fingerprint>=2 and #fingerprint<=256
                and #fingerprint%2==0 and not fingerprint:find('[^%x]'),'Animation native fingerprint is invalid')
            local expected=unhex(fingerprint)
            local name,base,length,stamp=native_owner(address,#expected)
            assert(read(address,#expected)==expected,'Animation native fingerprint differs')
            local key=abi..':'..tostring(address)..':'..fingerprint:lower()
            local cached=native_bindings[key]
            if cached and cached.name==name and cached.base==base and cached.length==length
                and cached.stamp==stamp then return cached.wrapper end
            local fn
            if injected.cast then fn=injected.cast(abi,address,label)
            else
                local ctype=native_types[abi]
                if not ctype then ctype=ffi().typeof(abi);native_types[abi]=ctype end
                fn=ffi().cast(ctype,address)
            end
            assert(type(fn)=='function' or type(fn)=='cdata','Animation native binding is unavailable')
            local wrapper=function(...)
                local current,current_length,current_stamp=io.module(name)
                assert(current==base and current_length==length and current_stamp==stamp,
                    'Animation native module identity changed')
                assert(read(address,#expected)==expected,'Animation native fingerprint changed before call')
                return fn(...)
            end
            native_bindings[key]={name=name,base=base,length=length,stamp=stamp,wrapper=wrapper}
            return wrapper
        end)
    end
    function io.resolve(raw,base,world,entity)
        local current,why=io.game();if not current or current~=base then return nil,why or 'Package game identity changed'end
        return PackageResolver.resolve(raw,base,world,entity)
    end
    function io.resident(A,pkg)
        return protected(function()
            local current,why=io.addresses();assert(current,why)
            assert(type(A)=='table' and A.base==current.base and A.stamp==current.stamp,'Package game identity changed')
            assert(type(pkg)=='string' and #pkg==8 and pkg~=string.rep('\0',8),'Package key is invalid')
            local root=ptr(current.base+current.ENGINE);local app=ptr(root+0x10)
            local target=ptr(app+0x328);local bytes=read(target,#HAS_LOADED_SHAPE/2)
            local have=hex(bytes)
            for at=1,#HAS_LOADED_SHAPE,2 do
                local wanted=HAS_LOADED_SHAPE:sub(at,at+1)
                assert(wanted=='??'or wanted==have:sub(at,at+1),'Package resident fingerprint differs')
            end
            local exe,size=io.module('helldivers2.exe')
            assert(exe and target>=exe and target+#bytes<=exe+size,'Package resident target is outside the executable')
            local fn,reason=io.native(target,'int (*)(uint64_t)',have,'BRIDGE_PACKAGE_RESIDENT')
            assert(fn,reason)
            assert(ptr(current.base+current.ENGINE)==root and ptr(root+0x10)==app
                and ptr(app+0x328)==target,'Package resident API identity changed')
            local value=ffi().new('uint64_t[1]');ffi().copy(value,pkg,8)
            return fn(value[0])~=0
        end)
    end
    return io
end
return M
