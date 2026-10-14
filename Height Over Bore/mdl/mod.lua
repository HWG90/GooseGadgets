-- Standalone MDL API 2 adapter. No game access at import.
local G = rawget(_G, '_G') or _G
local get, set = G.rawget, G.rawset
local OWNER = 'GOOSE_HOB_MDL_OWNER'
local ALLOWED = {['src/memory.lua']=true, ['src/backend.lua']=true,
    ['src/controller.lua']=true, ['src/mcm.lua']=true}
local owner, controller, menu, host
local function pack(...) return {n=select('#', ...), ...} end
local function log(message)
    if owner and owner.log then pcall(owner.log, tostring(message)) end
end
local function finish()
    if owner.pump and get(G, 'update') == owner.pump.callback then set(G, 'update', owner.pump.previous) end
    if get(G, OWNER) == owner then set(G, OWNER, nil) end
    owner.clean = true
    controller, menu = nil, nil
    return true
end
local function retry()
    if not owner or owner.clean then return true end
    owner.stopping = true
    if menu then menu:begin_shutdown() end
    if controller then
        local called, done, why = pcall(controller.shutdown, controller)
        if not called or done ~= true then return false, called and why or tostring(done) end
    end
    if menu then
        local called, done, why = pcall(menu.shutdown, menu)
        if not called or done ~= true then return false, called and why or tostring(done) end
    end
    return finish()
end
local function cleanup_pump()
    if owner.pump then return true end
    local previous = get(G, 'update')
    if type(previous) ~= 'function' then return false, 'Game update delivery is unavailable; cleanup remains owned' end
    local token = owner
    local callback
    callback = function(...)
        local results = pack(previous(...))
        if get(G, OWNER) == token and token.stopping and not token.clean then
            local called, done, why = pcall(retry)
            if not called or done ~= true then
                local issue = tostring(called and why or done)
                if token.last_issue ~= issue then token.last_issue=issue; log('Restoration pending: '..issue) end
            end
        end
        return G.unpack(results, 1, results.n)
    end
    owner.pump = {previous=previous, callback=callback}
    set(G, 'update', callback)
    return true
end
local function shutdown()
    local called, done, why = pcall(retry)
    if called and done == true then return true end
    if owner and not owner.clean then
        local installed, pump_reason = cleanup_pump()
        why = tostring(called and why or done)
        if not installed then why = why .. '; ' .. tostring(pump_reason) end
        log('Restoration pending: ' .. why)
    end
    return false, why
end
local function enable(ctx)
    assert(ctx.api == 2 and type(ctx.dir) == 'string' and ctx.dir ~= ''
        and type(ctx.on_cleanup) == 'function', 'MDL API 2 is required')
    local previous = get(G, OWNER)
    if previous then
        assert(type(previous)=='table' and previous.provider=='MDL' and previous.stopping
            and type(previous.retry)=='function', 'Another Height Over Bore MDL instance is active')
        local called, done = pcall(previous.retry)
        assert(called and done == true and get(G, OWNER)==nil, 'Previous Height Over Bore restoration is pending')
    end
    assert(not controller, 'Previous Height Over Bore restoration is pending')
    owner = {provider='MDL', stopping=false, clean=false, log=ctx.log, context=ctx}
    local token = owner
    owner.retry = function()
        if owner ~= token then return false, 'Height Over Bore cleanup owner changed' end
        return shutdown()
    end
    set(G, OWNER, owner)
    local cache = {}
    host = {dir=ctx.dir, log=log}
    local environment = setmetatable({_G=G, mod=host}, {__index=G})
    function host.require(name)
        assert(ALLOWED[name], 'Height Over Bore module is outside the package allowlist')
        if cache[name] ~= nil then return cache[name] end
        local file = assert(G.io.open(host.dir .. '/' .. name, 'rb'), 'Height Over Bore module is missing: '..name)
        local text = file:read('*a'); file:close()
        local chunk = assert(G.loadstring(text, '@HeightOverBore/'..name))
        G.setfenv(chunk, environment)
        local value=chunk(); cache[name]=value==nil and true or value
        return cache[name]
    end
    ctx.on_cleanup(function()
        if owner ~= token then return true end
        return shutdown()
    end)
    local called, why = pcall(function()
        local Backend, Controller, MCM = host.require('src/backend.lua'), host.require('src/controller.lua'), host.require('src/mcm.lua')
        controller=Controller.new(Backend.new(log),log)
        menu=MCM.new(controller,log)
        menu:update()
        log('Loaded; use MCM > Height Over Bore > Enabled')
    end)
    if not called then shutdown(); error(why) end
end
return {
    name='Height Over Bore', version='0.1.0-experimental', author='Goose',
    description='Restore height over bore across weapon changes and respawns. Configure Enabled in DBF-MCM.',
    on_enable=enable,
    on_update=function(ctx,dt)
        if not owner or owner.clean then return end
        if owner.stopping then shutdown(); return end
        local called, why=pcall(function()
            menu:update(); controller:update(type(dt)=='number' and dt or 1/60); menu:refresh_status()
        end)
        if not called then log('Update failed: '..tostring(why)); shutdown() end
    end,
    on_disable=function(ctx)
        if owner and ctx and ctx ~= owner.context then return true end
        return shutdown()
    end,
}
