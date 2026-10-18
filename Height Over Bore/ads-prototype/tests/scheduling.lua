local root=assert(HOB_TEST_ROOT)
local oldmod=mod
mod={require=function(name)return assert(loadfile(root..'/'..name))()end}
local Controller=assert(loadfile(root..'/src/controller.lua'))()
local function fixture()
    local b={reads=0,settled=true}
    function b:steady()self.reads=self.reads+1;return true end
    function b:is_settled()return self.settled end
    function b:invalidate()end
    local c=Controller.new(b);assert(c:set_enabled(true))
    return c,b
end
local c,b=fixture()
c:update(1/240)
for _=1,240 do c:update(1/240)end
assert(b.reads==61,'240 Hz must produce 60 further checks per second')
local before=b.reads;c:update(5)
assert(b.reads==before+1,'Stalls must not replay missed checks')
c:update(0);assert(b.reads==before+2,'Unknown delta must not delay cleanup')
assert(c:set_enabled(false));before=b.reads
for _=1,240 do c:update(1/240)end
assert(b.reads==before,'Disabled clean state must remain idle')
assert(c:set_enabled(true));c:update(1/1000)
assert(b.reads==before+1,'Enable must inspect immediately')
local d,e=fixture();e.settled=false
for _=1,10 do d:update(1/1000)end
assert(e.reads==10,'Unsettled state must not be throttled')
local f,g=fixture();f:update(1/240);assert(f:shutdown())
assert(f:is_clean(),'Shutdown must bypass the rate bound')
mod=oldmod
print('Bounded transition scheduling: passed')
