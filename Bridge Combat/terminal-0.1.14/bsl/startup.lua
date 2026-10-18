-- HD2-Addon: mods/goose/bridge_combat_014/startup
-- Standalone BSL entry for Bridge Combat 0.1.15. The builder embeds every
-- module and the immutable native weapon-menu helper; nothing is read from
-- the addon archive after this startup runs.
-- Under the LLL stack (which also loads Bingus addons) this entry goes inert:
-- LLL publishes a real DBF-MCM within the first update ticks, and running a
-- second Bridge Combat variant beside the LLL one is refused by design.
local OWNER = 'GOOSE_BRIDGE_COMBAT_BSL_014_OWNER'
local existing = rawget(_G, OWNER)
if existing then return existing end
local VERSION, NATIVE_ASSET, NATIVE_SHA256 = '__VERSION__', '__NATIVE_ASSET__', '__NATIVE_SHA256__'
local sources = {}
-- __MODULES__
local NATIVE_HEX = __NATIVE_HEX__

local ffi = require('ffi')
local base = (os.getenv('LOCALAPPDATA') or '.'):gsub('\\', '/')
local root = base .. '/Goose/BridgeCombat'
pcall(ffi.cdef, [[
    int BridgeCombatBSL014_CreateDirectoryA(const char *path, void *security) __asm__("CreateDirectoryA");
    uint32_t BridgeCombatBSL014_GetLastError(void) __asm__("GetLastError");
]])
local directories_ready = pcall(function()
    local kernel = ffi.load('kernel32')
    for _, path in ipairs({base .. '/Goose', root, root .. '/runtime', root .. '/native'}) do
        if kernel.BridgeCombatBSL014_CreateDirectoryA(path, nil) == 0 then
            assert(kernel.BridgeCombatBSL014_GetLastError() == 183, 'Cannot create ' .. path)
        end
    end
end)
local log_file = directories_ready and io.open(root .. '/BridgeCombat-0.1.14.log', 'w') or nil
local function log(message)
    if log_file then pcall(function() log_file:write(tostring(message), '\n'); log_file:flush() end) end
end

local cache = {}
local function require_module(name)
    if cache[name] ~= nil then return cache[name] end
    local source = assert(sources[name], 'Missing embedded Bridge Combat module: ' .. tostring(name))
    local value = assert(loadstring(source, '@BridgeCombat/' .. name))()
    cache[name] = value == nil and true or value
    return cache[name]
end

-- The helper is written only once, under its content-hashed name, so a loaded
-- DLL is never replaced in place.
local native_ok, native_problem
local function extract_native()
    if native_ok ~= nil then return native_ok, native_problem end
    local ok, why = pcall(function()
        assert(directories_ready, 'Bridge Combat runtime folder is unavailable')
        local payload = (NATIVE_HEX:gsub('%x%x', function(pair) return string.char(tonumber(pair, 16)) end))
        assert(#payload * 2 == #NATIVE_HEX, 'Embedded native helper is malformed')
        local path = root .. '/' .. NATIVE_ASSET
        local current = io.open(path, 'rb')
        if current then
            local bytes = current:read('*a'); current:close()
            assert(bytes == payload, 'A different file occupies ' .. NATIVE_ASSET .. '; refusing replacement')
            return
        end
        local partial = path .. '.partial'
        os.remove(partial)
        local file = assert(io.open(partial, 'wb'))
        local written = file:write(payload); file:close()
        assert(written, 'Native helper could not be written')
        assert(os.rename(partial, path))
        local check = assert(io.open(path, 'rb'))
        local bytes = check:read('*a'); check:close()
        assert(bytes == payload, 'Native helper readback differs')
    end)
    native_ok, native_problem = ok, not ok and tostring(why) or nil
    log(ok and ('Native helper ready: ' .. NATIVE_ASSET .. ' sha256 ' .. NATIVE_SHA256)
        or ('Native helper unavailable: ' .. native_problem))
    return native_ok, native_problem
end

local function native_read(relative)
    assert(type(relative) == 'string' and relative:sub(1, 7) == 'native/'
        and not relative:find('%.%.') and not relative:find('\\'), 'Native read is out of bounds')
    local file = assert(io.open(root .. '/' .. relative, 'rb'), 'Native file is unavailable')
    local data = file:read('*a'); file:close()
    return data
end

-- Screen placement persistence. Saved records hold only numbers in shallow
-- nested tables; wall_station validates the decoded shape before use.
local placement_path = root .. '/wall-terminal.txt'
local function encode_record(value, indent)
    local kind = type(value)
    if kind == 'number' then return string.format('%.17g', value) end
    if kind == 'boolean' then return tostring(value) end
    if kind == 'string' then return string.format('%q', value) end
    assert(kind == 'table' and indent <= 3, 'Saved screen placement value is unsupported')
    local parts = {}
    for key, item in pairs(value) do
        local label
        if type(key) == 'number' then
            assert(key % 1 == 0 and key >= 1 and key <= 3, 'Saved screen placement index is unsupported')
            label = '[' .. tostring(key) .. ']'
        else
            assert(type(key) == 'string' and key:find('^[%w_]+$'), 'Saved screen placement key is unsupported')
            label = key
        end
        parts[#parts + 1] = label .. '=' .. encode_record(item, indent + 1)
    end
    return '{' .. table.concat(parts, ',') .. '}'
end
local function load_placement()
    local file = io.open(placement_path, 'rb')
    if not file then return nil end
    local data = file:read('*a'); file:close()
    local chunk = assert(loadstring(data, '@wall-terminal.txt'))
    setfenv(chunk, {})
    local ok, value = pcall(chunk)
    if not ok or type(value) ~= 'table' then return nil end
    return value
end
local function save_placement(value)
    local ok, why = pcall(function()
        assert(type(value) == 'table', 'Saved screen placement must be a table')
        local encoded = 'return ' .. encode_record(value, 1)
        assert(loadstring(encoded), 'Saved screen placement did not round-trip')
        local partial = placement_path .. '.partial'
        local file = assert(io.open(partial, 'wb'))
        local written = file:write(encoded); file:close()
        assert(written, 'Screen placement could not be written')
        pcall(ffi.cdef, [[int BridgeCombatBSL014_MoveFileExA(const char *from, const char *to, uint32_t flags) __asm__("MoveFileExA");]])
        assert(ffi.load('kernel32').BridgeCombatBSL014_MoveFileExA(partial, placement_path, 9) ~= 0,
            'Screen placement atomic replacement failed')
    end)
    return ok, not ok and tostring(why) or nil
end

-- Only boolean runtime settings live here; screen placement has its own validated record.
local settings_path=root..'/settings.cfg'
local standalone_settings={enabled=false,ammo_station=true}
do local f=io.open(settings_path,'rb');if f then local data=f:read('*a');f:close()
    for _,key in ipairs({'enabled','ammo_station'})do local value=data:match(key..'=(%a+)');if value=='true'or value=='false'then standalone_settings[key]=value=='true'end end
end end
local function save_setting(key,value)
    assert((key=='enabled'or key=='ammo_station')and type(value)=='boolean','Unsupported Bridge Combat setting')
    local next_values={enabled=standalone_settings.enabled,ammo_station=standalone_settings.ammo_station};next_values[key]=value
    local ok,why=pcall(function()
        local f=assert(io.open(settings_path..'.partial','wb'));assert(f:write('enabled='..tostring(next_values.enabled)..'\nammo_station='..tostring(next_values.ammo_station)..'\n'));f:close()
        pcall(ffi.cdef,[[int BridgeCombatBSL014_MoveFileExA(const char *,const char *,uint32_t) __asm__("MoveFileExA");]])
        assert(ffi.load('kernel32').BridgeCombatBSL014_MoveFileExA(settings_path..'.partial',settings_path,9)~=0,'Settings replacement failed')
    end)
    if ok then standalone_settings[key]=value end;return ok,not ok and tostring(why)or nil
end

local previous_update = assert(rawget(_G, 'update'), 'Game update callback is unavailable')
assert(type(previous_update) == 'function', 'Game update callback is unsupported')
local previous_shutdown = rawget(_G, 'shutdown')

local owner = {provider = 'BSL', version = VERSION, stopping = false}
local wrapper, shutdown_wrapper
local last_problem, last_station
local probe_file=io.open(root..'/measure-once','rb');local probe
if probe_file then probe_file:close();os.remove(root..'/measure-once');probe={frames=0,seconds=0,max=0}end

local function report(why)
    why = tostring(why)
    if why ~= last_problem then log(why); last_problem = why end
end

-- LLL detection: its Bridge Combat record (or the 0.2.0 BSL owner) means this entry
-- must not run. A shim installed by an earlier instance of this addon is
-- replaceable and does not count. LLL loads its mods before the first update
-- ticks, so a short grace window is a reliable discriminator.
local function lll_stack_present()
    if rawget(_G, 'GOOSE_BRIDGE_COMBAT_BSL_OWNER') ~= nil then return true end
    local loader=rawget(_G,'LiveLuaLoader')
    if type(loader)=='table'and type(loader.records)=='table'and loader.records['live/goose_bridge_combat']then return true end
    local mcm = rawget(_G, 'DBFMCM')
    return type(mcm) == 'table' and mcm.bridgecombat_bsl_shim ~= true
        and type(mcm.mods) == 'table' and mcm.mods.goose_bridge_combat ~= nil
end

local GRACE_SECONDS = 3
local elapsed, refused, wired = 0, false, false
local controller, menu, bindings, bridge, bridge_installed, services

local function wire()
    if wired or refused or owner.stopping then return end
    wired = true
    if not extract_native() then return end
    require_module('src/terminal_render.lua')
    assert(not rawget(_G,'GOOSE_BRIDGE_SERVICES'),'Another Bridge Combat input service is active')
    services=require_module('src/terminal_services.lua').new({load=require_module})
    rawset(_G,'GOOSE_BRIDGE_SERVICES',services)
    local Runtime = require_module('src/runtime.lua')
    local MCM = require_module('src/mcm.lua')
    controller = Runtime.new({load = require_module, log = log, native_dir = root,
        native_read = native_read, config = {wall_terminal = load_placement()},
        save = save_placement,enable_combat=function()if not menu then return false,'Combat settings unavailable'end;return menu:set_enabled(true)end,
        set_combat=function(value)if not menu then return false,'Combat settings unavailable'end;return menu:set_enabled(value)end})
    menu = MCM.new(controller, log,{config=standalone_settings,save=save_setting})
    bindings = require_module('src/bindings.lua').new({
        log = log,
        toggle = function() return menu:toggle() end,
        allowed = function() return menu:hotkey_allowed() and controller:hotkey_allowed() end,
    })
    log('Bridge Combat ' .. VERSION .. ' loaded. Use the terminal WEAPONS FREE switch. '
        .. 'Bind Toggle Bridge Combat under Options > Controls > MODS.')
end

local function refuse(reason)
    if refused then return end
    refused = true
    last_problem = tostring(reason)
    log('Bridge Combat ' .. VERSION .. ' inert: ' .. last_problem)
end

function owner.status()
    if refused then return 'Refused: ' .. tostring(last_problem) end
    if wired and controller then return tostring(controller:status()) end
    return 'Detecting the loader stack'
end

function owner.stop()
    if owner.cleaned then return true end
    owner.stopping = true
    if bindings then bindings:shutdown() end
    if menu then menu:begin_shutdown() end
    if controller then
        local called, done, why = pcall(controller.shutdown, controller)
        if not called or done ~= true then
            report('Bridge Combat cleanup pending: ' .. tostring(called and why or done))
            return false, called and why or done
        end
    end
    if menu then
        local menu_done, menu_why = menu:shutdown()
        if menu_done ~= true then return false, menu_why end
    end
    -- Only a shim this instance installed may be shut down; a real provider
    -- is shared state that belongs to its own loader.
    if services then local ok,why=services.shutdown();if ok~=true then return false,why end
        if rawget(_G,'GOOSE_BRIDGE_SERVICES')==services then rawset(_G,'GOOSE_BRIDGE_SERVICES',nil)end;services=nil end
    owner.cleaned = true
    if rawget(_G, 'update') == wrapper then rawset(_G, 'update', previous_update) end
    if rawget(_G, 'shutdown') == shutdown_wrapper then rawset(_G, 'shutdown', previous_shutdown) end
    if rawget(_G, OWNER) == owner then rawset(_G, OWNER, nil) end
    log('Bridge Combat stopped; owned changes restored')
    return true
end

local function step(dt)
    if owner.stopping then owner.stop(); return end
    if refused then return end
    if not wired then
        elapsed = elapsed + math.max(0, math.min(1, dt))
        if lll_stack_present() then
            refuse('the LLL stack (real DBF-MCM) or another Bridge Combat BSL variant is active; use one variant')
            return
        end
        if elapsed < GRACE_SECONDS then return end
        wire()
        if not controller then
            refuse('native helper unavailable: ' .. tostring(native_problem))
            return
        end
    end
    if controller and controller.reinitialize then
        if bindings then bindings:shutdown()end
        if menu then menu:begin_shutdown()end
        local done,why=controller:shutdown();if done~=true then report(why);return end
        if menu then local released,reason=menu:shutdown();if released~=true then report(reason);return end end
        if services then local ok,why=services.shutdown();if ok~=true then report(why);return end
            if rawget(_G,'GOOSE_BRIDGE_SERVICES')==services then rawset(_G,'GOOSE_BRIDGE_SERVICES',nil)end;services=nil end
        controller,menu,bindings=nil,nil,nil;wired=false;wire()
    end
    local begin=probe and services.camera_input.now()
    local called, why = pcall(function()
        menu:update()
        if bridge and bridge.update then bridge.update() end
        bindings:update()
        controller:update(dt)
        menu:refresh_status()
        -- The wall station reports through menu labels only; mirror its
        -- status into the log so a missing terminal is diagnosable.
        local station = tostring(controller:ammo_station_status())
        if station ~= last_station then log('Wall terminal: ' .. station); last_station = station end
    end)
    if probe then
        local t=services.camera_input.now();local cost=t-begin;probe.frames=probe.frames+1;probe.seconds=probe.seconds+cost;probe.max=math.max(probe.max,cost);probe.start=probe.start or t
        if t-probe.start>=10 then log(string.format('PERFORMANCE update frames=%d ms/s=%.3f max_ms=%.3f station=%s',probe.frames,probe.seconds*1000/(t-probe.start),probe.max*1000,tostring(controller:ammo_station_status())));probe=nil end
    end
    if not called then
        report('Bridge Combat update failed: ' .. tostring(why))
        owner.stop()
    end
end

local function pack(...) return {n = select('#', ...), ...} end
wrapper = function(dt, ...)
    local result = pack(previous_update(dt, ...))
    step(dt)
    return unpack(result, 1, result.n)
end
rawset(_G, OWNER, owner)
rawset(_G, 'update', wrapper)
shutdown_wrapper = function(...)
    owner.stop()
    if type(previous_shutdown) == 'function' then return previous_shutdown(...) end
end
rawset(_G, 'shutdown', shutdown_wrapper)
log('Bridge Combat ' .. VERSION .. ' detecting the loader stack (up to ' .. GRACE_SECONDS .. 's)')

local loader = rawget(_G, 'CowboyBingusModLoader')
if type(loader) == 'table' and type(loader.after_startup) == 'function' then
    local ok, why = pcall(loader.after_startup, function()
        -- Early registration only when the grace phase already wired us.
        if owner.stopping or refused or not wired then return end
        local called, problem = pcall(menu.update, menu)
        if not called then report('Bridge Combat menu registration: ' .. tostring(problem)) end
    end)
    if not ok then report('Bridge Combat startup registration deferred: ' .. tostring(why)) end
end
return owner
