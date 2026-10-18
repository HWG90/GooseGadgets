-- Bridge Combat render dispatcher. No listener sorting or allocation while unchanged.
local existing=rawget(_G,'HUDRenderBridge');if existing and existing.api==1 then return existing end
local original=assert(rawget(_G,'render'),'Game render callback unavailable');local entries,ordered={},{}
local bridge={api=1,status='ready',errors={}}
local function rebuild()ordered={};for id,e in pairs(entries)do ordered[#ordered+1]={id,e}end;table.sort(ordered,function(a,b)return a[1]<b[1]end)end
function bridge.subscribe(id,callback)
    assert(type(id)=='string'and type(callback)=='function');local e={callback=callback};entries[id]=e;rebuild()
    return function()if entries[id]==e then entries[id]=nil;rebuild()end end
end
rawset(_G,'render',function(...)
    local frame=ordered
    for _,item in ipairs(frame)do local id,e=item[1],item[2];if entries[id]==e then local ok,why=pcall(e.callback,...);if not ok then entries[id]=nil;bridge.errors[id]=tostring(why);rebuild()end end end
    return original(...)
end)
rawset(_G,'HUDRenderBridge',bridge);return bridge
