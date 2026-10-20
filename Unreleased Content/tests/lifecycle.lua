local attempts,writes,reads,restores=0,0,0,0
local waiting,fail_cleanup=true,false
local backend={
    prepare=function()attempts=attempts+1;reads=reads+1;if waiting then return nil,'waiting',true end;return {}end,
    apply=function()writes=writes+1;return true end,
    restore=function()restores=restores+1;return not fail_cleanup,'cleanup pending'end,
}
mod={require=function()return {new=function()return backend end}end,log=function()end}
local main=dofile('main.lua')
main.on_enable()
for i=1,600 do main.on_update(1/60)end
assert(attempts<=11,'Startup readiness was polled more than once per second')
waiting=false
main.on_update(1)
assert(writes==1)
local before=reads
for i=1,36000 do main.on_update(1/60)end
assert(reads==before and writes==1,'Registered steady state performed memory I/O')
fail_cleanup=true;assert(main.on_disable()==false)
fail_cleanup=false;assert(main.on_cleanup_poll()==true)
waiting=true;attempts=0
main.on_enable()
for i=1,1000 do main.on_update(1)end
assert(attempts==60,'Startup readiness retries were not bounded')
assert(main.on_disable()==true)
return 'Lifecycle: bounded startup retries, one registration, idle steady state, cleanup ownership passed'
