-- Exercise the actual runtime clock factory outside the game. The old
-- millisecond timer repeated at high frame rates and reset sprint motion.
local entry=assert(loadfile(NATIVE_ADS_TEST_ROOT..'/main.lua'))()
local factory
for i=1,80 do
    local name,value=debug.getupvalue(entry.on_enable,i)
    if not name then break end
    if name=='monotonic_clock'then factory=value;break end
end
assert(type(factory)=='function','Runtime clock factory unavailable')
local clock=factory()
local first=clock();local previous=first;local fine=false
assert(type(first)=='number'and first==first and first>=0 and first<math.huge)
for _=1,2000 do
    local current=clock()
    assert(current>=previous,'Runtime clock moved backwards')
    if current>previous and current-previous<.001 then fine=true end
    previous=current
end
assert(previous>first and fine,'Runtime clock does not resolve sub-millisecond updates')
print('Native ADS high-resolution runtime clock: 1 passed')
