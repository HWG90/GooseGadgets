local ffi=require('ffi')
local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))..'/compat/lll-0.1.14'
local Atlas=dofile(root..'/src/ui_atlas_readiness.lua')
local function raw(s)return(s:gsub('%x%x',function(x)return string.char(tonumber(x,16))end))end
local function key(s)return raw(s):reverse()end
local function word(v)local t=ffi.new('uint64_t[1]',v);return ffi.string(t,8)end
local checks,tests=0,0
local function eq(a,b)checks=checks+1;assert(a==b,tostring(a)..' ~= '..tostring(b))end
local function yes(a)checks=checks+1;assert(a)end
local function test(name,fn)fn();tests=tests+1;print('PASS UI atlas '..name)end
local function fixture()
    local f={game=0x100000000,exe=0x120000000,root=0x200000000,manager=0x210000000,rows=0x220000000,
        used=1482,buckets=2048,reads=0,bindings=0,calls=0,region=true,texture=true,key='127A9AEA3916C70E',stamp=0x6AB382E4}
    local b={_ffi=ffi}
    function b:ptr(p)f.reads=f.reads+1;if p==f.exe+0x1A10238 then return f.root elseif p==f.root+0x3F8 then return f.manager elseif p==f.manager+0x2A0 then return f.rows end;return nil,'unknown pointer'end
    function b:u32(p)f.reads=f.reads+1;if p==f.manager+0x2B0 then return f.used elseif p==f.manager+0x2B4 then return f.buckets end;return nil,'unknown field'end
    function b:read(p,n)f.reads=f.reads+1;local s=p==f.exe+0x3438E0 and raw('48895c2410488b054cc96c0133db4d8bc848895c24084c8b')or p==f.exe+0x5F2160 and raw('4053415641574883ec30488b02488bd98b89c00200004533');if f.badfp then return string.rep('\0',n)end;return s and s:sub(1,n)or nil end
    local io={module=function(name)return name=='game.dll'and f.game or f.exe,0x4000000,name=='game.dll'and 0x6AB3B43F or f.stamp end,
        native=function(_,_,_,label)f.bindings=f.bindings+1
            if label=='BRIDGE_UI_ATLAS_REGION'then return function(input,out,uv)
                f.calls=f.calls+1;eq(word(input),key(f.key));if f.torn then f.used=f.used+1 end
                if not f.region then out[0]=0;return 0 end
                ffi.copy(out,key('10A0814C0FAD8650'),8);for i=0,3 do uv[i]=i<2 and 0 or 1 end
                if f.nan then uv[0]=0/0 end
                return 1
            end end
            eq(label,'BRIDGE_UI_ATLAS_TEXTURE_PRESENT');if f.failbind then return nil,'factory unavailable'end
            return function(manager,t,name)
                f.calls=f.calls+1;eq(tonumber(ffi.cast('uintptr_t',manager)),f.manager);eq(ffi.string(t,8),key('CD4238C6A0C69E32'));eq(ffi.string(name,8),key('10A0814C0FAD8650'));return f.texture and 1 or 0
            end
        end}
    f.adapter=Atlas.new(io,b);return f
end
test('inert construction, exact region and actual TEXTURE proof',function()local f=fixture();eq(f.reads,0);eq(f.bindings,0);yes(f.adapter:all({key(f.key)}));eq(f.bindings,2);eq(f.calls,2);yes(f.adapter:all({f.key}));eq(f.bindings,2)end)
test('region miss is not texture readiness',function()local f=fixture();f.region=false;yes(not f.adapter:all({f.key}));eq(f.calls,1)end)
test('actual texture absence refuses a registered region',function()local f=fixture();f.texture=false;yes(not f.adapter:all({f.key}));eq(f.calls,2)end)
test('module stamp and native fingerprint refusal precede calls',function()for _,mode in ipairs({'stamp','fp'})do local f=fixture();if mode=='stamp'then f.stamp=0 else f.badfp=true end;yes(not f.adapter:all({f.key}));eq(f.calls,0);eq(f.bindings,0)end end)
test('map changes during resolution refuse readiness',function()local f=fixture();f.torn=true;yes(not f.adapter:all({f.key}));eq(f.calls,1)end)
test('zero bucket count refuses the native lookup',function()local f=fixture();f.buckets=0;yes(not f.adapter:all({f.key}));eq(f.calls,0)end)
test('invalid UV does not acknowledge a usable atlas',function()local f=fixture();f.nan=true;yes(not f.adapter:all({f.key}));eq(f.calls,2)end)
test('binding failure can retry without partially publishing callbacks',function()local f=fixture();f.failbind=true;yes(not f.adapter:all({f.key}));eq(f.calls,0);f.failbind=false;yes(f.adapter:all({f.key}));eq(f.bindings,4)end)
print(string.format('PASS all%d UI atlas contracts, %d checks',tests,checks))
