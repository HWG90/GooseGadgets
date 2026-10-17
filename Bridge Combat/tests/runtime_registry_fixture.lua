-- Read-only observer contracts. No runtime owner/native module is instantiated.
local ffi,bit=require('ffi'),require('bit')
local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))
local Runtime=dofile(root..'/compat/lll-0.1.2/src/runtime.lua')
local function bytes(kind,value)return ffi.string(ffi.new(kind..'[1]',value),ffi.sizeof(kind))end
local function fixture()
    local f={memory={},reads=0}
    local game,exe,state,world,pm,lc,player,ep=0x100000000,0x200000000,0x300000000,0x400000000,
        0x500000000,0x600000000,0x700000000,0x800000000
    local registry,generations,units,unit,animator,graph,states,menu=0x900000000,0x900010000,0x900020000,
        0xA00000000,0xB00000000,0xC00000000,0xD00000000,0xE00000000
    function f:put(at,b)for i=1,#b do self.memory[at+i-1]=b:sub(i,i)end end
    function f:u(at,n)self:put(at,bytes('uint32_t',n))end
    function f:p(at,n)self:put(at,bytes('uint64_t',n))end
    function f:read(at,n)
        self.reads=self.reads+1;local out={}
        for i=0,n-1 do out[#out+1]=self.memory[at+i]or'\0'end
        local value=table.concat(out);if self.on_read then self:on_read(at,n)end;return value
    end
    f.base={game=game,stamp=0x6AB3B43F,scene=3,world=world,pm=pm,lc=lc,avatar=249,ep=ep,pc=pm+0x53D8B0}
    f:p(game+0x3326340,state);f:u(state+0xAC21C,3);f:p(game+0x346BF98,world)
    f:p(game+0x3326D20,pm);f:p(game+0x3326CF8,lc);f:p(game+0x3326468,player)
    f:u(player+0x3A8,71);f:u(ep+8,249);f:u(ep+12,1);f:u(ep+20,1)
    f:p(exe+0x1A100F0,registry);f:u(registry+0x98,10)
    f:p(registry+0xA0,generations);f:p(registry+0x88,units);f:p(units+8,unit)
    f:u(unit+8,1);f:put(unit+0x358,string.char(0x97,0xFA,0x4D,0x29,0x4D,0x33,0x1C,0x4D))
    f:p(unit+0x178,animator);f:p(animator+0x28,graph);f:u(graph+4,31);f:p(animator+0x50,states)
    f:u(f.base.pc+0xFD0,2);f:p(game+0x347CE28,menu)
    local backend={bit=bit,observe=function()return f.base end}
    local io={read=function(...)return f:read(...)end,module=function(name)
        assert(name=='helldivers2.exe');return exe,0,0x6AB382E4
    end}
    f.globals={DBFMCM={register=function()end}}
    f.observer=Runtime.observer(backend,io,f.globals)
    f.registry,f.generations,f.units,f.unit,f.menu,f.graph=registry,generations,units,unit,menu,graph
    function f:relocate(both)
        self.current_generations=self.generations+0x100000
        self.current_units=both and self.units+0x200000 or self.units
        self:put(self.current_generations+1,'\0');self:p(self.current_units+8,self.unit)
        self:p(self.registry+0xA0,self.current_generations);self:p(self.registry+0x88,self.current_units)
        self:u(self.registry+0x98,32)
    end
    f.reads=0;return f
end
local passed=0
local function test(name,fn)local ok,why=pcall(fn);assert(ok,name..': '..tostring(why));passed=passed+1;print('PASS '..name)end
test('observer construction is inert and returns a sealed normal bridge actor',function()
    local f=fixture();assert(f.reads==0)
    local s=f.observer();assert(s.ready and s.menu_closed and not s.photo and not s.fixed_pose)
end)
test('coherent generation-only and both-array relocation preserve the logical body token',function()
    for _,both in ipairs({false,true})do
        local f=fixture();local old=f.observer();f:relocate(both);local current=f.observer()
        assert(old.token==current.token and current.ready)
        f:u(f.menu+0x4294,5);local armory=f.observer()
        assert(armory.token==current.token and not armory.ready and not armory.menu_closed)
    end
end)
test('generation slot body and registry-owner changes still refuse or change logical ownership',function()
    for _,kind in ipairs({'generation','slot','body','registry'})do
        local f=fixture();local old=f.observer();f:relocate(true)
        if kind=='generation'then f:put(f.current_generations+1,'\1')
        elseif kind=='slot'then f:p(f.current_units+8,f.unit+0x1000)
        elseif kind=='body'then f:put(f.unit+0x358,string.rep('\0',8))
        else
            local moved=f.registry+0x300000;f:u(moved+0x98,32)
            f:p(moved+0xA0,f.current_generations);f:p(moved+0x88,f.current_units)
            f:p(0x200000000+0x1A100F0,moved)
        end
        local ok,current=pcall(f.observer)
        if kind=='registry'then assert(ok and current.token~=old.token)
        else assert(not ok,kind)end
    end
end)
test('an array pointer changed during observation cannot produce a stable token',function()
    local f=fixture();f:relocate(true);local moved=false
    f.on_read=function(self,at)
        if at==self.current_generations+1 and not moved then
            moved=true;self:p(self.registry+0xA0,self.current_generations+0x1000)
        end
    end
    assert(not pcall(f.observer))
end)
test('Epic forward wrapper exposes the actual Photo Mode owner and fixed-pose gates',function()
    local f=fixture();local photo={active=false}
    local DBF_FREECAM={_poses={active=false,pending=false}}
    DBF_FREECAM.camera_owned=function()return photo.active end
    local forward=function()return DBF_FREECAM end
    local controller={kind='EpicLUT'}
    f.globals.render=function()if controller then return forward()end end
    f.globals.DBF_PHOTO_CAMERA_RUNTIME={photo=photo}
    local normal=f.observer();assert(normal.ready and not normal.photo and not normal.fixed_pose)
    photo.active=true;local active=f.observer()
    assert(not active.ready and active.photo and active.hold and not active.fixed_pose)
    photo.active=false;DBF_FREECAM._poses.pending=true;local fixed=f.observer()
    assert(not fixed.ready and not fixed.photo and fixed.fixed_pose and not fixed.hold)
end)
test('forward traversal also discovers closure-owned photo state without a runtime global',function()
    local f=fixture();local photo={active=false}
    local DBF_FREECAM={camera_owned=function()return photo.active end}
    local forward=function()return DBF_FREECAM end
    f.globals.render=function()return forward()end
    assert(f.observer().ready)
    photo.active=true;local active=f.observer();assert(active.photo and not active.ready and active.hold)
end)
print(('Runtime registry observer: %d contracts passed'):format(passed))
