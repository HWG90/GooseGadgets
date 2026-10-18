-- HD2-Addon: mods/holographic_utility_display/render_bridge
-- Startup-only dispatcher. Never load this file as an MDL loose mod.
local existing=rawget(_G,'HUDRenderBridge')
if existing and existing.api==1 then return existing end
local original=rawget(_G,'render')
assert(type(original)=='function','HUD render bridge: host render callback missing')
local listeners={}
local bridge={api=1,status='ready',errors={}}
function bridge.subscribe(id,callback)
    assert(type(id)=='string' and type(callback)=='function','invalid render subscription')
    local entry={callback=callback};listeners[id]=entry
    return function()if listeners[id]==entry then listeners[id]=nil end end
end
local function dispatch(...)
    local snapshot={}
    for id,entry in pairs(listeners) do snapshot[#snapshot+1]={id,entry} end
    table.sort(snapshot,function(a,b)return a[1]<b[1]end)
    for _,item in ipairs(snapshot) do
        local id,entry=item[1],item[2]
        if listeners[id]==entry then
            local ok,why=pcall(entry.callback,...)
            if not ok then listeners[id]=nil;bridge.errors[id]=tostring(why) end
        end
    end
    return original(...)
end
rawset(_G,'HUDRenderBridge',bridge)
rawset(_G,'render',dispatch)
return bridge
