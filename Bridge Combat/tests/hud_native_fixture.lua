local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))
local saved_require=require
_G.require=function()error('HUD binder imported FFI eagerly')end
local ok,Binder=pcall(dofile,root..'/compat/lll-0.1.1/src/hud_native.lua')
_G.require=saved_require;assert(ok,Binder)
local KEY='BC_BRIDGE_COMBAT_HUD_NATIVE_012_LIFETIMES'
local exports={'prepare','start','tick','stop','release','phase','flags','error'}
local serial,tests=0,0
local function test(name,fn)local good,why=pcall(fn);assert(good,name..': '..tostring(why));tests=tests+1;print('PASS '..name)end
local function word(n)return string.char(n%256,math.floor(n/256)%256,math.floor(n/65536)%256,math.floor(n/16777216)%256)end
local function fixture()
    serial=serial+1
    local f={calls={},events={},flags=8,phase=0,loaded=0,cdefs=0,types=0,reads=0,text='',prepare_result=1,
        start_result=1,stop_result=1,release_result=1,stop_ready=true,release_ready=true}
    f.hash=('%064x'):format(serial)..''
    -- A hash-addressed filename uses a nonzero prefix in every fixture.
    f.hash=('%012x'):format(serial)..f.hash:sub(13)
    f.path='C:/review/bridge-hud-v0.1.2-'..f.hash:sub(1,16)..'.dll'
    f.base={avatar=17,pm_entity=919}
    f.receipt={sha256=f.hash,sha256_verified=true,immutable_filename=true,
        pe={machine='AMD64',exports={}},game_timestamp='6AB3B43F',exe_timestamp='6AB382E4',
        source_sha256=string.rep('a',64)}
    for _,name in ipairs(exports)do f.receipt.pe.exports[#f.receipt.pe.exports+1]='BC_mission_hud_'..name end
    local function record(name,...)
        f.calls[name]=(f.calls[name]or 0)+1;f.events[#f.events+1]={name,...}
        if f.throw==name then error('Injected uncertain '..name)end
    end
    local lib={}
    function lib.BC_mission_hud_prepare(pid,avatar)
        record('prepare',pid,avatar);assert(pid==919 and avatar==17)
        f.flags=f.prepare_result==1 and 9 or 8;return f.prepare_result
    end
    function lib.BC_mission_hud_start()
        record('start');if f.start_result==1 then f.flags=167 else f.text='MH10 Winerr5'end
        return f.start_result
    end
    function lib.BC_mission_hud_tick(dt,pid,avatar)
        record('tick',dt,pid,avatar);assert(dt==0.125 and pid==919 and avatar==17);return 1
    end
    function lib.BC_mission_hud_stop()
        record('stop');if f.stop_ready then f.flags=137 end;return f.stop_result
    end
    function lib.BC_mission_hud_release()
        record('release');if f.release_ready then f.flags=8+(math.floor(f.flags/16)%2)*16 end
        return f.release_result
    end
    function lib.BC_mission_hud_flags()record('flags');return f.flags end
    function lib.BC_mission_hud_phase()record('phase');return f.phase end
    function lib.BC_mission_hud_error()record('error');return f.text end
    f.library=lib
    local ffi={}
    function ffi.typeof(name)f.types=f.types+1;assert(name=='BC_MH_012_u32');if not f.declared then error('Unknown typedef')end;return{}end
    function ffi.cdef(text)
        f.cdefs=f.cdefs+1;f.declared=true
        assert(text:find('BC_mission_hud_tick(float dt, BC_MH_012_u32 pid, BC_MH_012_u32 avatar)',1,true))
        assert(not text:find('(*',1,true),'No repeatedly parsed anonymous function pointer')
        assert(not text:find('probe',1,true),'No unhooked fallback export may be bound')
    end
    function ffi.load(path)assert(path==f.path);f.loaded=f.loaded+1;record('load');return lib end
    function ffi.string(value)assert(type(value)=='string');return value end
    function ffi.cast()error('Binder must not parse/cast an anonymous ABI')end
    f.ffi=ffi
    f.options={path=f.path,receipt=f.receipt,ffi=ffi,source_sha256=string.rep('a',64),read=function(path,offset,size)
        assert(path==f.path);f.reads=f.reads+1
        if offset==0 then assert(size==64);return 'MZ'..string.rep('\0',58)..word(0x80)end
        assert(offset==0x80 and size==26)
        local machine=f.bad_machine and '\x4c\x01'or'\x64\x86'
        return 'PE\0\0'..machine..string.rep('\0',16)..'\0\x20'..'\x0b\x02'
    end}
    f.binder=Binder.new(f.options)
    function f:held()local registry=rawget(_G,KEY);return registry and registry[self.path:lower()]end
    return f
end
test('import constructor and unloaded status are inert',function()
    local f=fixture();assert(f.loaded==0 and f.cdefs==0 and f.reads==0 and not f:held())
    local s=f.binder:status();assert(s.stopped and s.released and #f.events==0)
end)
test('receipt hash filename target source export and actual AMD64 PE are guarded before DLL load',function()
    for _,kind in ipairs({'verified','immutable','filename','target','source','export','machine'})do
        local f=fixture()
        if kind=='verified'then f.receipt.sha256_verified=false
        elseif kind=='immutable'then f.receipt.immutable_filename=false
        elseif kind=='filename'then f.options.path='C:/review/ordinary.dll'
        elseif kind=='target'then f.receipt.exe_timestamp='00000000'
        elseif kind=='source'then f.receipt.source_sha256=string.rep('b',64)
        elseif kind=='export'then table.remove(f.receipt.pe.exports)
        else f.bad_machine=true end
        assert(not f.binder:prepare(f.base),kind);assert(f.loaded==0 and not f:held(),kind)
    end
end)
test('typed prepare and tick use pid plus avatar and ignore controller PM pointer',function()
    local f=fixture();assert(f.binder:prepare(f.base));assert(f.binder:start())
    assert(f.binder:tick(0.125,0x1234567890,919));assert(f.calls.tick==1 and f.loaded==1 and f:held())
    assert(not f.binder:tick(0.125,919,17));assert(f.calls.tick==1)
    assert(f.binder:stop()and not f:held())
end)
test('named declarations are parsed once across10000 status polls and a second clean activation',function()
    local f=fixture();assert(f.binder:prepare(f.base));assert(f.binder:start())
    for _=1,10000 do local s=f.binder:status();assert(s.active and s.widgets_ready and not s.stopped)end
    assert(f.types==1 and f.cdefs==1 and f.loaded==1)
    assert(f.binder:stop());assert(f.binder:prepare(f.base));assert(f.types==1 and f.cdefs==1 and f.loaded==2)
    assert(f.binder:stop())
end)
test('prepared inactive presentation is not reported fully stopped before hook release',function()
    local f=fixture();assert(f.binder:prepare(f.base));local s=f.binder:status()
    assert(s.prepared and not s.widgets_ready and not s.stopped and not s.released and not f.calls.release)
    assert(f.binder:stop());assert(f.calls.stop==1 and f.calls.release==1 and not f:held())
end)
test('pending stop retains DLL and later stopped status releases hooks exactly once',function()
    local f=fixture();assert(f.binder:prepare(f.base));assert(f.binder:start())
    f.stop_ready=false;f.stop_result=0;assert(not f.binder:stop());assert(f:held()and not f.calls.release)
    for _=1,5 do assert(not f.binder:status().stopped)end
    assert(f.calls.stop==1 and not f.calls.release)
    f.flags=137;local s=f.binder:status()
    assert(s.stopped and s.released and f.calls.release==1 and not f:held())
    f.binder:status();assert(f.calls.release==1)
end)
test('returned-false or uncertain release retains library instead of guessing hook cleanup',function()
    for _,kind in ipairs({'false','throw'})do
        local f=fixture();assert(f.binder:prepare(f.base));assert(f.binder:start())
        if kind=='false'then f.release_result=0;f.release_ready=false else f.throw='release'end
        assert(not f.binder:stop());assert(f:held())
        f.flags=8
        for _=1,3 do assert(not f.binder:status().stopped)end
        assert(f.calls.release==1 and f:held())
    end
end)
test('uncertain native stop is never replayed or released just because status becomes empty',function()
    local f=fixture();assert(f.binder:prepare(f.base));assert(f.binder:start());f.throw='stop'
    assert(not f.binder:stop());f.flags=8;f.throw=nil
    for _=1,3 do assert(not f.binder:status().stopped)end
    assert(f.calls.stop==1 and not f.calls.release and f:held())
end)
test('uncertain start cannot be retried ticked stopped or implicitly unloaded',function()
    local f=fixture();assert(f.binder:prepare(f.base));f.throw='start'
    assert(not f.binder:start());f.throw=nil
    assert(not f.binder:start()and not f.binder:tick(0.125,0,919)and not f.binder:stop())
    assert(f.calls.start==1 and not f.calls.tick and not f.calls.stop and f:held())
end)
test('a second binder cannot take over a DLL retained by an earlier owner',function()
    local f=fixture();assert(f.binder:prepare(f.base));local other=Binder.new(f.options)
    assert(not other:prepare(f.base)and f.loaded==1)
    assert(f.binder:stop());assert(other:prepare(f.base)and f.loaded==2);assert(other:stop())
end)
test('positive synchronous retired stopped status releases hooks without another native stop',function()
    local f=fixture();assert(f.binder:prepare(f.base));assert(f.binder:start());f.flags=25
    local s=f.binder:status();assert(s.stopped and s.retired_safe and s.released)
    assert(not f.calls.stop and f.calls.release==1 and not f:held())
end)
test('hook enable denial remains a failure with no probe or guard-stripping fallback',function()
    local f=fixture();assert(f.binder:prepare(f.base));f.start_result=0
    local started,why=f.binder:start();assert(not started and why:find('MH10 Winerr5',1,true))
    assert(f.calls.start==1 and not f.calls.tick and f:held())
    assert(f.binder:stop()and f.calls.release==1)
end)
test('missing resolved export retains loaded library without invoking an incomplete API',function()
    local f=fixture();f.library.BC_mission_hud_tick=nil
    assert(not f.binder:prepare(f.base));assert(f.loaded==1 and f:held()and not f.calls.prepare)
    assert(f.binder:status().cleanup_pending and not f.binder:status().stopped)
end)
print(('HUD native binder: %d contracts passed'):format(tests))
