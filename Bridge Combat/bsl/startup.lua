-- HD2-Addon: mods/goose/bridge_combat/startup
-- Standalone BSL entry. The builder embeds every module and the native helper.
local OWNER = 'GOOSE_BRIDGE_COMBAT_BSL_OWNER'
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
    int BridgeCombatBSL_CreateDirectoryA(const char *path, void *security) __asm__("CreateDirectoryA");
    uint32_t BridgeCombatBSL_GetLastError(void) __asm__("GetLastError");
]])
local directories_ready = pcall(function()
    local kernel = ffi.load('kernel32')
    for _, path in ipairs({base .. '/Goose', root, root .. '/runtime'}) do
        if kernel.BridgeCombatBSL_CreateDirectoryA(path, nil) == 0 then
            assert(kernel.BridgeCombatBSL_GetLastError() == 183, 'Cannot create ' .. path)
        end
    end
end)
local log_file = directories_ready and io.open(root .. '/BridgeCombat.log', 'w') or nil
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

-- The helper is written only once Enabled is first requested. Its file name
-- carries the content hash, so a loaded DLL is never replaced in place.
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

-- Only one Bridge Combat variant may own the bridge in this game process.
local function lll_variant_active()
    local mcm = rawget(_G, 'DBFMCM')
    if type(mcm) ~= 'table' then return false end
    local ok, active = pcall(function() return type(mcm.mods) == 'table' and mcm.mods.goose_bridge_combat ~= nil end)
    return ok and active == true
end
local function mcm_open()
    local mcm = rawget(_G, 'DBFMCM')
    if type(mcm) ~= 'table' or type(mcm.is_open) ~= 'function' then return false end
    local ok, open = pcall(mcm.is_open)
    return ok and open == true
end

local previous_update = assert(rawget(_G, 'update'), 'Game update callback is unavailable')
assert(type(previous_update) == 'function', 'Game update callback is unsupported')
local previous_shutdown = rawget(_G, 'shutdown')
local Backend = require_module('src/backend.lua')
local Controller = require_module('src/controller.lua')
local backend = Backend.new(log, nil, {dir = root, native_asset = NATIVE_ASSET, native_route = 'actor'})
local controller = Controller.new(backend, log)
local intent, conflict = false, false
local preference = {set_enabled = function(_, value) intent = value == true; return true end}
local options = require_module('src/options.lua').new(preference, log)
local bindings = require_module('src/bindings.lua').new({
    log = log,
    toggle = function() return options:toggle() end,
    allowed = function() return options:hotkey_allowed() and not conflict and not mcm_open() end,
})
local owner = {provider = 'BSL', version = VERSION, stopping = false}
local wrapper, shutdown_wrapper
local last_problem, last_status
local function report(why)
    why = tostring(why)
    if why ~= last_problem then log(why); last_problem = why end
end
function owner.status()
    if conflict then return 'Refused: the LLL Bridge Combat variant is active; use one variant' end
    if intent and native_ok == false then return 'Native helper unavailable: ' .. tostring(native_problem) end
    return tostring(controller:status())
end
function owner.stop()
    if owner.cleaned then return true end
    owner.stopping = true
    options:begin_shutdown()
    bindings:shutdown()
    local called, done, why = pcall(controller.shutdown, controller)
    if not called or done ~= true then
        report('Bridge Combat cleanup pending: ' .. tostring(called and why or done))
        return false, called and why or done
    end
    options:shutdown()
    owner.cleaned = true
    if rawget(_G, 'update') == wrapper then rawset(_G, 'update', previous_update) end
    if rawget(_G, 'shutdown') == shutdown_wrapper then rawset(_G, 'shutdown', previous_shutdown) end
    if rawget(_G, OWNER) == owner then rawset(_G, OWNER, nil) end
    log('Bridge Combat stopped; owned changes restored')
    return true
end
local function step(dt)
    if owner.stopping then owner.stop(); return end
    local called, why = pcall(function()
        options:update(dt)
        bindings:update()
        conflict = lll_variant_active()
        local want = intent and not conflict
        if want and not extract_native() then want = false end
        controller:set_enabled(want)
        controller:update(dt)
        local status = owner.status()
        if status ~= last_status then log('Bridge Combat: ' .. status); last_status = status end
    end)
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
local loader = rawget(_G, 'CowboyBingusModLoader')
if type(loader) == 'table' and type(loader.after_startup) == 'function' then
    local ok, why = pcall(loader.after_startup, function()
        if owner.stopping then return end
        local called, problem = pcall(options.update, options, 0)
        if not called then report('Bridge Combat menu registration: ' .. tostring(problem)) end
    end)
    if not ok then report('Bridge Combat startup registration deferred: ' .. tostring(why)) end
end
log('Bridge Combat ' .. VERSION .. ' loaded. Use Mod Options > Bridge Combat > Enabled, then Apply. '
    .. 'Bind Toggle Bridge Combat under Options > Controls > MODS.')
return owner
