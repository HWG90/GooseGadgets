local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))
local Module=dofile(root..'/compat/lll-0.1.14/src/bindings.lua')
local MCM=dofile(root..'/compat/lll-0.1.14/src/mcm.lua')
local count=0
local function eq(a,b)assert(a==b,tostring(a)..' ~= '..tostring(b))end
local function test(name,fn)fn();count=count+1;print('PASS binding: '..name)end
local function fixture()
    local f={globals={},registrations=0,reads=0,toggles=0,ready=true,down=false,allowed=true,saved=true}
    local host={api=1,version=3}
    function host.register_binding(id,label,slot,options)
        eq(id,'bridge_combat.toggle');eq(label,'Toggle Bridge Combat');eq(slot,2);eq(options.category,'Bridge Combat')
        f.registrations=f.registrations+1
        if f.register_fail then return false,'No native slots remain' end
        return true
    end
    function host.ready()return f.ready end
    function host.is_down(id)eq(id,'bridge_combat.toggle');f.reads=f.reads+1;if f.throw then error('Input unavailable')end;return f.down end
    f.host=host;f.globals.ModBindingsMenu=host
    function f:new()
        return Module.new({globals=self.globals,toggle=function()
            f.toggles=f.toggles+1
            if f.save_fail then return false,'Save failed' end
            f.saved=not f.saved;return true
        end,allowed=function()return f.allowed end})
    end
    f.binding=f:new()
    function f:tick(value)self.down=value;return self.binding:update()end
    return f
end
test('construction has no provider/input access',function()local f=fixture();eq(f.registrations,0);eq(f.reads,0)end)
test('one native registration and one saved toggle per press',function()
    local f=fixture();f:tick(false);f:tick(true);f:tick(true);eq(f.registrations,1);eq(f.toggles,1);eq(f.saved,false)
    f:tick(false);f:tick(true);eq(f.toggles,2);eq(f.saved,true)
end)
test('a held key during startup or reload must release first',function()
    local f=fixture();f:tick(true);f:tick(true);eq(f.toggles,0);f:tick(false);f:tick(true);eq(f.toggles,1)
    f.binding:shutdown();f.binding=f:new();f:tick(true);eq(f.toggles,1);f:tick(false);f:tick(true);eq(f.toggles,2)
end)
test('suppressed input is consumed without replay when a menu closes',function()
    local f=fixture();f:tick(false);f.allowed=false;f:tick(true);f.allowed=true;f:tick(true);eq(f.toggles,0)
    f:tick(false);f:tick(true);eq(f.toggles,1)
end)
test('provider/readiness/nil loss quarantine held activation',function()
    for _,kind in ipairs({'provider','ready','nil','error'})do
        local f=fixture();f:tick(false)
        if kind=='provider'then f.globals.ModBindingsMenu=nil;f:tick(false);f.globals.ModBindingsMenu=f.host
        elseif kind=='ready'then f.ready=false;f:tick(false);f.ready=true
        elseif kind=='nil'then f:tick(nil)
        else f.throw=true;f:tick(false);f.throw=false end
        f:tick(true);eq(f.toggles,0);f:tick(false);f:tick(true);eq(f.toggles,1)
    end
end)
test('registration failure never polls an unowned action',function()
    local f=fixture();f.register_fail=true;eq(f:tick(false),false);eq(f.reads,0);eq(f.toggles,0)
end)
test('refused registration is latched until the native registry changes',function()
    local f=fixture();f.host.revision=35;f.register_fail=true
    f:tick(false);f:tick(false);f:tick(true);eq(f.registrations,1);eq(f.reads,0)
    f.host.revision=36;f.register_fail=false;f:tick(false);eq(f.registrations,2);f:tick(true);eq(f.toggles,1)
end)
test('unsupported native provider is not replaced',function()
    local f=fixture();f.host.version=2;f:tick(false);eq(f.registrations,0);eq(f.reads,0)
end)
test('save failure does not retry while key stays held',function()
    local f=fixture();f:tick(false);f.save_fail=true;eq(f:tick(true),false);f:tick(true);eq(f.saved,true);eq(f.toggles,1)
end)
test('shutdown stops sampling without unregistering shared native action',function()
    local f=fixture();f:tick(false);f.binding:shutdown();f:tick(true);eq(f.reads,1);eq(f.toggles,0)
end)
local function mcm_fixture()
    local f={value=true,changes=0,focused=true,editing=false,open=false,chat=false,globals={}}
    local controller={set_enabled=function(_,value)f.changes=f.changes+1;f.applied=value;return true end,status=function()return 'Ready'end,
        set_ammo_station=function(_,value)f.ammo=value;return true end,ammo_station_status=function()return 'Station ready'end,
        queue_ammo_refill=function()f.refill_queued=(f.refill_queued or 0)+1;return true end,
        queue_wall_place=function()f.place_queued=true;return true end,
        support_choices=function()return{'Support A','Support B'}end,support_status=function()return'Support ready'end,
        queue_support=function(_,index)f.support_queued=index;return true end}
    local api={mods={},camera_input={chat_active=function()return f.chat end}}
    function api.is_open()return f.open end
    function api.menu_binding_status()return{focused=f.focused,editing=f.editing}end
    function api.close()f.open=false;f.closes=(f.closes or 0)+1;return true end
    function api.register(spec)
        local handle={}
        function handle.get(id)if id=='ammo_station'then return f.ammo==nil or f.ammo end;if id=='support_weapon'then return 2 end;eq(id,'enabled');return f.value end
        function handle.set(id,value)
            eq(id,'enabled');if f.save_fail then return false,'Save failed' end
            f.value=value;spec.pages[1].controls[1].on_change(value);return true
        end
        function handle.unregister()api.mods[spec.id]=nil end
        api.mods[spec.id]={handle=handle,pages=spec.pages};return handle
    end
    f.api=api;f.old=rawget(_G,'DBFMCM');_G.DBFMCM=api
    f.menu=MCM.new(controller);assert(f.menu:update())
    function f:finish()self.menu:shutdown();_G.DBFMCM=self.old end
    return f
end
test('native toggle and visible switch share saved MCM Enabled',function()
    local f=mcm_fixture();eq(f.applied,true);assert(f.menu:toggle());eq(f.value,false);eq(f.applied,false)
    assert(f.menu:toggle());eq(f.value,true);eq(f.applied,true);eq(f.changes,3);f:finish()
end)
test('station defaults On and its switch does not change combat intent',function()
    local f=mcm_fixture();eq(f.ammo,true);local controls=f.api.mods.goose_bridge_combat.pages[1].controls
    local station;for _,c in ipairs(controls)do if c.id=='ammo_station'then station=c end end
    eq(station.default,true);station.on_change(false);eq(f.ammo,false);eq(f.value,true);eq(f.changes,1);f:finish()
end)
test('failed MCM save leaves applied Enabled unchanged',function()
    local f=mcm_fixture();f.save_fail=true;eq(f.menu:toggle(),false);eq(f.value,true);eq(f.applied,true);eq(f.changes,1);f:finish()
end)
test('console page queues explicit refill/support and closes MCM without changing Enabled',function()
    local f=mcm_fixture();local page=f.api.mods.goose_bridge_combat.pages[2];eq(page.id,'console')
    local controls={};for _,c in ipairs(page.controls)do if c.id then controls[c.id]=c end end
    eq(controls.support_weapon.type,'choice');eq(#controls.support_weapon.choices,2)
    f.open=true;assert(controls.console_refill.on_activate());eq(f.refill_queued,1);eq(f.open,false);eq(f.closes,1)
    f.open=true;assert(controls.console_request.on_activate());eq(f.support_queued,2);eq(f.open,false);eq(f.closes,2)
    _G.DBFMCM={};eq(controls.console_refill.on_activate(),false);eq(f.refill_queued,1);_G.DBFMCM=f.api
    eq(f.value,true);eq(f.changes,1);f.menu:begin_shutdown();eq(controls.console_request.on_activate(),false);eq(f.closes,2);f:finish()
end)
test('release menu has no screen reposition control',function()
    local f=mcm_fixture();for _,page in ipairs(f.api.mods.goose_bridge_combat.pages)do
        for _,c in ipairs(page.controls)do assert(c.id~='wall_place')end
    end;eq(f.place_queued,nil);f:finish()
end)

test('MCM focus capture chat and shutdown suppress hotkey activation',function()
    local f=mcm_fixture();assert(f.menu:hotkey_allowed())
    for _,key in ipairs({'open','editing','chat'})do f[key]=true;eq(f.menu:hotkey_allowed(),false);f[key]=false end
    f.focused=false;eq(f.menu:hotkey_allowed(),false);f.focused=true
    f.menu:begin_shutdown();eq(f.menu:hotkey_allowed(),false);eq(f.menu:toggle(),false);f:finish()
end)
print(('PASS %d native binding and saved-toggle contracts'):format(count))

 test('optional MCM absence preserves independent terminal settings and combat intent',function()
    local old=_G.DBFMCM;_G.DBFMCM=nil
    local c={set_enabled=function(self,v)self.enabled=v;return true end,set_ammo_station=function(self,v)self.ammo=v;return true end}
    local saved={};local m=MCM.new(c,nil,{config={enabled=true,ammo_station=true},save=function(k,v)saved[k]=v;return true end})
    assert(m:update());assert(c.enabled and c.ammo);assert(m:set_enabled(false));assert(c.enabled==false and saved.enabled==false)
    assert(m:toggle());assert(c.enabled==true and saved.enabled==true)
    for _=1,20 do m:update()end;assert(c.enabled and c.ammo);assert(m:shutdown());_G.DBFMCM=old
end)

test('MBM v4 registers once and exposes the same action to MCM import',function()
 local f=fixture();f.host.version=4;f:tick(false);eq(f.registrations,1)
 for i=1,100 do f:tick(false)end;eq(f.registrations,1)
 f:tick(true);eq(f.toggles,1)
end)
