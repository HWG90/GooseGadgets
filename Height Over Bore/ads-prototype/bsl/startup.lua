-- HD2-Addon: mods/goose/hob_ads_prototype/startup
-- Standalone BSL entry. The builder embeds every required module here.
local existing = rawget(_G, 'GOOSE_HOB_ADS_PROTOTYPE_BSL_OWNER')
if existing then return existing end
local root = (os.getenv('LOCALAPPDATA') or '.') .. '/CowboyBingus/Helldivers2/Logs'
local function log(message)
    local file = io.open(root .. '/HeightOverBoreADSPrototype.log', 'a')
    if file then file:write(tostring(message), '\n'); file:close() end
end
local mod, factories, cache = {log = log}, {}, {}
-- __MODULES__
function mod.require(name)
    if cache[name] ~= nil then return cache[name] end
    local factory = assert(factories[name], 'Missing embedded HoB module: ' .. tostring(name))
    local value = factory()
    cache[name] = value == nil and true or value
    return cache[name]
end
local previous_update = assert(rawget(_G, 'update'), 'Game update callback is unavailable')
assert(type(previous_update) == 'function', 'Game update callback is unsupported')
local previous_shutdown = rawget(_G, 'shutdown')
local controller = mod.require('src/controller.lua').new(mod.require('src/backend.lua').new(log), log)
local options = mod.require('src/options.lua').new(controller, log)
local owner = {provider = 'BSL', version = '__VERSION__', stopping = false}
local wrapper, shutdown_wrapper
local last_problem, last_status
local function report(why)
    why = tostring(why)
    if why ~= last_problem then log(why); last_problem = why end
end
function owner.stop()
    if owner.cleaned then return true end
    owner.stopping = true
    options:begin_shutdown()
    local called, done, why = pcall(controller.shutdown, controller)
    if not called or done ~= true then
        report('Height Over Bore cleanup pending: ' .. tostring(called and why or done))
        return false, called and why or done
    end
    local done, problem = options:shutdown()
    if done ~= true then return false, problem end
    owner.cleaned = true
    if rawget(_G, 'update') == wrapper then rawset(_G, 'update', previous_update) end
    if rawget(_G, 'shutdown') == shutdown_wrapper then rawset(_G, 'shutdown', previous_shutdown) end
    if rawget(_G, 'GOOSE_HOB_ADS_PROTOTYPE_BSL_OWNER') == owner then rawset(_G, 'GOOSE_HOB_ADS_PROTOTYPE_BSL_OWNER', nil) end
    return true
end
local function step(dt)
    if owner.stopping then owner.stop(); return end
    local called, why = pcall(function()
        options:update(dt)
        controller:update(dt)
        local status = controller:status()
        if status ~= last_status then log('Height Over Bore: ' .. status); last_status = status end
    end)
    if not called then
        report('Height Over Bore update failed: ' .. tostring(why))
        owner.stop()
    end
end
local function pack(...) return {n = select('#', ...), ...} end
wrapper = function(dt, ...)
    local result = pack(previous_update(dt, ...))
    step(dt)
    return unpack(result, 1, result.n)
end
rawset(_G, 'GOOSE_HOB_ADS_PROTOTYPE_BSL_OWNER', owner)
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
        if not called then report('Height Over Bore menu registration: ' .. tostring(problem)) end
    end)
    if not ok then report('Height Over Bore startup registration deferred: ' .. tostring(why)) end
end
log('Height Over Bore __VERSION__ loaded. Use Mod Options > Height Over Bore > Enabled, then Apply.')
return owner
