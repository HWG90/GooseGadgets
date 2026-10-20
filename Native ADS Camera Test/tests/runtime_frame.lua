-- Scope binary-contract reuse to one callback, including early returns/errors.
local entry=assert(loadfile(NATIVE_ADS_TEST_ROOT..'/main.lua'))()
local function replace(key,value)
    for i=1,80 do
        local name=debug.getupvalue(entry.on_update,i)
        if not name then break end
        if name==key then debug.setupvalue(entry.on_update,i,value);return end
    end
    error('Runtime frame upvalue unavailable: '..key)
end
local calls={begin=0,finish=0,body=0,active=false}
local backend={}
function backend:begin_frame()
    assert(not calls.active);calls.active=true;calls.begin=calls.begin+1
end
function backend:end_frame()
    assert(calls.active);calls.active=false;calls.finish=calls.finish+1
end
replace('backend',backend);replace('controller',{});replace('stopping',false)
replace('update_frame',function()calls.body=calls.body+1;return end)
entry.on_update()
assert(calls.begin==1 and calls.finish==1 and calls.body==1 and not calls.active)
replace('update_frame',function()error('fixture update error')end)
local ok,why=pcall(entry.on_update)
assert(not ok and tostring(why):find('fixture update error'))
assert(calls.begin==2 and calls.finish==2 and not calls.active)
replace('stopping',true);entry.on_update()
replace('stopping',false);replace('controller',nil);entry.on_update()
assert(calls.begin==2 and calls.finish==2)
print('Native ADS runtime frame lifetime: 3 passed')
