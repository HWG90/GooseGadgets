local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))..'/compat/lll-0.1.14'
local Controller=dofile(root..'/src/controller.lua')
local function fixture()
    local f={setters=0,ack=true};local view={scene=3,game=1,stamp=2,world=3,pm=4,lc=5,avatar=6,ep=7}
    local b={bit=require('bit'),read=function()return 'resource'end,u32=function()return 8 end}
    local c=Controller.new(b,nil,function(v,lease)
        assert(v==view)
        if not lease.unarmed_returned then lease.unarmed_returned=true;f.setters=f.setters+1 end
        return f.ack,'Waiting for acknowledgement'
    end)
    c.active={game=1,stamp=2,world=3,pm=4,lc=5,avatar=6,resource='resource',render=8,
        restoring=true,done={profiles=true,context=true,dispatch=true,projectiles=true}}
    f.controller,f.view=c,view;return f
end
local f=fixture();f.controller:update(f.view);assert(f.controller.active==nil and f.setters==1)
for _=1,600 do f.controller:update(f.view)end
assert(f.controller:shutdown()and f.setters==1)
f=fixture();f.ack=false;f.controller:update(f.view);assert(f.controller.active and f.setters==1)
for _=1,10 do f.controller:update(f.view)end
assert(f.setters==1 and f.controller.active);f.ack=true;f.controller:update(f.view)
assert(f.controller.active==nil and f.setters==1)
f=fixture();f.view.scene=4;f.controller:update(f.view);assert(f.controller.active==nil and f.setters==0)
print('PASS one-shot unarmed cleanup, pending acknowledgement without setter replay, and retired actor exclusion')
