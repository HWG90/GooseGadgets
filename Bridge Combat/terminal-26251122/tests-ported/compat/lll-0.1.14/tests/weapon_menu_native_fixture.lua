local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))..'/compat/lll-0.1.14'
local Native=dofile(root..'/src/weapon_menu_native.lua')
local Hash=dofile(root..'/src/sha256.lua')
local checks,tests=0,0
local function eq(a,b)checks=checks+1;assert(a==b,tostring(a)..' ~= '..tostring(b))end
local function yes(a)checks=checks+1;assert(a)end
local function test(name,fn)fn();tests=tests+1;print('PASS native weapon binder '..name)end
local function fixture(globals)
    local f={globals=globals or {},reads=0,loads=0,cdefs=0,calls=0,flags=8,phase=0,data='isolated immutable native fixture bytes'}
    local sha=Hash(f.data);f.spec={available=true,sha256=sha,bytes=#f.data,file='native/BridgeCombatWeaponMenu-'..sha:sub(1,12)..'.dll'}
    local library={BC_weapon_menu_phase=function()return f.phase end,BC_weapon_menu_flags=function()return f.flags end,BC_weapon_menu_error=function()return ''end}
    function library.BC_weapon_menu_acquire(pid,avatar)eq(pid,5);eq(avatar,251);f.calls=f.calls+1;if f.throw then error('Native acquire acknowledgement unknown')end;f.flags=7;f.phase=9;return 1 end
    function library.BC_weapon_menu_tick(dt,pid,avatar)yes(dt>=0 and dt<=1);eq(pid,5);eq(avatar,251);f.calls=f.calls+1;return 1 end
    function library.BC_weapon_menu_stop()f.calls=f.calls+1;f.flags=f.retired and 40 or 8;f.phase=11;return 1 end
    local ffi={cdef=function()f.cdefs=f.cdefs+1 end,string=function(s)return s end,load=function(path)f.loads=f.loads+1;eq(path,'C:/Mods/goose/'..f.spec.file);return library end}
    f.library=library
    f.options={globals=f.globals,ffi=ffi,spec=f.spec,dir='C:\\Mods\\goose',read=function(path)f.reads=f.reads+1;eq(path,f.spec.file);return f.corrupt and f.data..'!'or f.data end,
        load=function(path)eq(path,'src/sha256.lua');return Hash end}
    f.owner=Native.new(f.options);return f
end
test('import/new/disabled stop are inert',function()local f=fixture();eq(f.loads,0);eq(f.reads,0);eq(f.cdefs,0);yes(f.owner:stop());yes(f.owner:is_clean());eq(f.calls,0)end)
test('exact binary identity precedes lazy pin and distinct player IDs',function()local f=fixture();yes(f.owner:acquire(5,251));eq(f.reads,1);eq(f.loads,1);eq(f.cdefs,1);eq(f.owner:status().flags,7);yes(not f.owner:is_clean());yes(f.owner:tick(0.1,5,251));eq(f.reads,1);eq(f.loads,1);yes(f.owner:stop());yes(f.owner:is_clean())end)
test('hash mismatch refuses before DLL load or FFI declarations',function()local f=fixture();f.corrupt=true;yes(not f.owner:acquire(5,251));eq(f.loads,0);eq(f.cdefs,0);eq(f.calls,0);yes(f.owner:is_clean())end)
test('pending build metadata cannot select a review DLL',function()local f=fixture();f.spec.available=false;f.spec.reason='Proof pending';yes(not f.owner:acquire(5,251));eq(f.reads,0);eq(f.loads,0);eq(f.calls,0)end)
test('reload reuses the pinned exact binary and FFI ABI',function()local a=fixture();yes(a.owner:acquire(5,251));yes(a.owner:stop());local b=fixture(a.globals);yes(b.owner:acquire(5,251));eq(a.loads,1);eq(b.loads,0);eq(b.cdefs,0);eq(a.calls,3);eq(b.calls,0)end)
test('an unknown acquire remains dirty until explicit acknowledgement',function()local f=fixture();f.throw=true;yes(not f.owner:acquire(5,251));yes(not f.owner:is_clean());yes(f.owner:status().pending);f.throw=false;yes(f.owner:stop());yes(f.owner:is_clean())end)
test('positive zero-write native handoff accepts retired status40',function()local f=fixture();yes(f.owner:acquire(5,251));f.retired=true;yes(f.owner:stop());yes(f.owner:is_clean());yes(f.owner:status().retired)end)
test('contradictory clean/native ownership flags retain pending state',function()local f=fixture();f.library.BC_weapon_menu_acquire=function()f.flags=9;return 1 end;yes(not f.owner:acquire(5,251));yes(not f.owner:is_clean())end)
test('missing export remains pinned and does not call acquisition',function()local f=fixture();f.library.BC_weapon_menu_tick=nil;yes(not f.owner:acquire(5,251));eq(f.loads,1);eq(f.calls,0);yes(not f.owner:is_clean());yes(not f.owner:stop());eq(f.loads,1)end)
test('a previous binary journal blocks new code and cannot be forgotten',function()local f=fixture();f.globals.GOOSE_BRIDGE_WEAPON_MENU_LIBRARIES_V1={old={status=function()return{owned=true,pending=true,stopped=false}end}};yes(not f.owner:acquire(5,251));eq(f.loads,0);eq(f.calls,0);yes(not f.owner:is_clean());yes(not f.owner:stop());yes(not f.owner:is_clean())end)
test('Off acknowledges later cleanup of a previous binary without a load',function()local f=fixture();local stopped=false;f.globals.GOOSE_BRIDGE_WEAPON_MENU_LIBRARIES_V1={old={status=function()return{owned=not stopped,pending=not stopped,stopped=stopped,role8_owned=false}end}};yes(not f.owner:acquire(5,251));yes(not f.owner:stop());stopped=true;yes(f.owner:stop());yes(f.owner:is_clean());eq(f.loads,0);eq(f.calls,0)end)
test('unreadable previous status remains retained during Off',function()local f=fixture();f.globals.GOOSE_BRIDGE_WEAPON_MENU_LIBRARIES_V1={old={status=function()error('Status unavailable')end}};yes(not f.owner:acquire(5,251));yes(not f.owner:stop());yes(not f.owner:is_clean());eq(f.loads,0);eq(f.calls,0)end)
test('disappearing previous pin is not cleanup proof',function()local f=fixture();local pins={old={status=function()return{owned=true,pending=true,stopped=false}end}};f.globals.GOOSE_BRIDGE_WEAPON_MENU_LIBRARIES_V1=pins;yes(not f.owner:acquire(5,251));pins.old=nil;yes(not f.owner:stop());yes(not f.owner:is_clean());eq(f.loads,0);eq(f.calls,0)end)
print(string.format('PASS all%d native weapon binder contracts, %d checks',tests,checks))
