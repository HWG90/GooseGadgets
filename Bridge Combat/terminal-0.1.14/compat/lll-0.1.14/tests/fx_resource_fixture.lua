-- Synthetic exact typed definitions; no game process is attached.
local ffi=require('ffi')
local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))..'/compat/lll-0.1.14'
local Resource=dofile(root..'/src/fx_resource_readiness.lua')
local function raw(s)return(s:gsub('%x%x',function(x)return string.char(tonumber(x,16))end))end
local function key(s)return raw(s):reverse()end
local function word(v)local a=ffi.new('uint64_t[1]',v);return ffi.string(a,8)end
local catalog={{type='A8193123526FAD64',name='62E478ACF4347B9C'},
    {type='EAC0B497876ADEDF',name='08EF612BD25100E3'},
    {type='CD4238C6A0C69E32',name='70B34AFEB8915FFE'},{type='535A7BD3E650D799',name='3543B29A8A90B1BE'}}
local checks,tests=0,0
local function eq(a,b)checks=checks+1;assert(a==b,tostring(a)..' ~= '..tostring(b))end
local function yes(a)checks=checks+1;assert(a)end
local function test(name,fn)fn();tests=tests+1;print('PASS FX resource '..name)end
local function fixture()
    local f={game=0x100000000,exe=0x120000000,root=0x200000000,manager=0x210000000,rows=0x220000000,
        reads=0,bindings=0,present=0,fetch=0,types=0,stamp=0x6AB382E4,count=42}
    local b={_ffi=setmetatable({typeof=function(s)f.types=f.types+1;return ffi.typeof(s)end},{__index=ffi})}
    function b:ptr(p)f.reads=f.reads+1;if p==f.exe+0x1A10238 then return f.root elseif p==f.root+0x3F8 then return f.manager elseif p==f.manager+0x2C8 then return f.rows end;return nil,'unknown pointer'end
    function b:u32(p)f.reads=f.reads+1;if p==f.manager+0x2C0 then return f.count end;error('FX must not read GUI flag+4')end
    function b:read(p,n)
        f.reads=f.reads+1
        if p==f.exe+0x5F2160 or p==f.exe+0x5F2290 then
            if f.badfp then return string.rep('\0',n)end
            return raw(p==f.exe+0x5F2160 and '4053415641574883ec30488b02488bd98b89c00200004533'or '4c894424184889542410535556574155415641574883ec30'):sub(1,n)
        end
        if p==0x230000000 then return not f.unreadable and string.rep('\0',n)or nil end
        return nil,'unknown memory'
    end
    local expected={};for _,c in ipairs(catalog)do expected[key(c.name)]=key(c.type)end
    local io={module=function(name)return name=='game.dll'and f.game or f.exe,0x4000000,name=='game.dll'and 0x6AB3B43F or f.stamp end,
        native=function(_,_,_,label)f.bindings=f.bindings+1
            if label=='BRIDGE_FX_RESOURCE_PRESENT'then return function(manager,typ,name)
                f.present=f.present+1;eq(tonumber(ffi.cast('uintptr_t',manager)),f.manager);eq(ffi.string(typ,8),expected[ffi.string(name,8)])
                if f.torn then f.manager=f.manager+0x100000 end
                return f.missing and 0 or 1
            end end
            eq(label,'BRIDGE_FX_RESOURCE_FETCH');if f.failbind then return nil,'bind unavailable'end
            return function(_,typ,name,canonical)
                f.fetch=f.fetch+1;eq(ffi.string(typ,8),expected[ffi.string(name,8)]);ffi.copy(canonical,f.alias and key('1111111111111111')or ffi.string(name,8),8)
                return f.null and 0 or 0x230000000
            end
        end}
    f.io,f.backend=io,b;f.ready=Resource.new(io,b,catalog);return f
end
test('construction is inert and all four FX/audio types resolve exactly',function()local f=fixture();eq(f.reads,0);eq(f.bindings,0);eq(f.types,0);for _,c in ipairs(catalog)do yes(f.ready(c.name))end;eq(f.present,4);eq(f.fetch,4);eq(f.bindings,2)end)
test('FX material with zero header flag is valid without GUI access',function()local f=fixture();yes(f.ready(key(catalog[2].name)));eq(f.present,1);eq(f.fetch,1)end)
test('unknown name and invalid type/catalog refuse before game access',function()local f=fixture();yes(not f.ready('1111111111111111'));eq(f.reads,0);yes(not pcall(Resource.new,f.io,f.backend,{{type='1111111111111111',name=catalog[1].name}}));yes(not pcall(Resource.new,f.io,f.backend,{catalog[1],catalog[1]}));eq(f.reads,0)end)
test('missing resource never fetches a default',function()local f=fixture();f.missing=true;yes(not f.ready(catalog[1].name));eq(f.fetch,0)end)
test('fallback alias and null definitions are refused',function()for _,mode in ipairs({'alias','null','unreadable'})do local f=fixture();f[mode]=true;yes(not f.ready(catalog[1].name))end end)
test('manager change after presence refuses before fetch',function()local f=fixture();f.torn=true;yes(not f.ready(catalog[1].name));eq(f.fetch,0)end)
test('module build/fingerprints checked on every invocation',function()for _,mode in ipairs({'stamp','badfp'})do local f=fixture();yes(f.ready(catalog[1].name));if mode=='stamp'then f.stamp=0 else f.badfp=true end;yes(not f.ready(catalog[1].name));eq(f.present,1)end end)
test('native callbacks and ctype allocations are cached',function()local f=fixture();for i=1,25 do yes(f.ready(catalog[1].name))end;eq(f.bindings,2);eq(f.types,2)end)
test('partial binding failure can retry without partial publication',function()local f=fixture();f.failbind=true;yes(not f.ready(catalog[1].name));eq(f.present,0);f.failbind=false;yes(f.ready(catalog[1].name));eq(f.bindings,4)end)
test('normal manager replacement can be reacquired coherently',function()local f=fixture();yes(f.ready(catalog[1].name));f.manager=f.manager+0x100000;yes(f.ready(catalog[1].name));eq(f.bindings,2)end)
test('invalid registration bounds refuse before binding',function()local f=fixture();f.count=0;yes(not f.ready(catalog[1].name));eq(f.bindings,0);eq(f.present,0)end)
print(string.format('PASS all%d FX resource contracts, %d checks',tests,checks))
