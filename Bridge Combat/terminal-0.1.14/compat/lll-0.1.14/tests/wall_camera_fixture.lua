local ffi=require('ffi')
local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))..'/compat/lll-0.1.14/src/'
local Adapter=dofile(root..'wall_camera.lua')
local tests=0
local function test(name,fn)fn();tests=tests+1;print('PASS terminal camera '..name)end
local function close(a,b)assert(type(a)=='number'and math.abs(a-b)<1e-6,tostring(a)..' ~= '..tostring(b))end
local function bytes(t,n)local a=ffi.new(t..'[1]',n);return ffi.string(a,ffi.sizeof(a))end
local function unhex(s)return(s:gsub('%x%x',function(x)return string.char(tonumber(x,16))end))end
local function fixture()
    local f={memory={},reads=0,modules=0,game=0x100000000,exe=0x120000000,engine=0x200000000,api=0x210000000,
        getter=0x220000000,implementation=0x220002000,state=0x300000000,camera=0x310000000,scene=0x320000000,array=0x330000000,
        width=1920,height=1080,node=3,camera_reads=0}
    function f:poke(at,s)for i=1,#s do self.memory[at+i-1]=s:byte(i)end end
    function f:p(at,v)self:poke(at,bytes('uint64_t',v))end
    function f:u(at,v)self:poke(at,bytes('uint32_t',v))end
    function f:float(at,v)self:poke(at,bytes('float',v))end
    function f:read(at,n)
        self.reads=self.reads+1
        if at==self.camera and n==160 then self.camera_reads=self.camera_reads+1;if self.torn and self.camera_reads==2 then self:float(self.camera+0x34,1)end end
        local out={};for i=0,n-1 do out[#out+1]=string.char(self.memory[at+i]or 0)end
        local result=table.concat(out);return self.short==at and result:sub(2)or result
    end
    function f:code()
        self:poke(self.getter,unhex('48895c2408574883ec60'))
        self:poke(self.getter+0x132,'\232'..bytes('int32_t',self.implementation-(self.getter+0x137)))
        self:poke(self.implementation,unhex('488bc448895808488968104889701857'))
        self:poke(self.implementation+0x62,unhex('488b471848c1e206418be948035028e80a951500'))
    end
    function f:matrix(m)for i=1,16 do self:float(self.array+self.node*64+(i-1)*4,m[i])end end
    f:p(f.game+0x3326308,f.engine);f:p(f.engine+0x20,f.api);f:p(f.api+0xF8,f.getter);f:code()
    f:p(f.game+0x346D560,f.state);f:p(f.state,f.camera);f:p(f.camera+0x18,f.scene);f:u(f.camera+0x20,f.node)
    f:u(f.camera+0x30,1);f:float(f.camera+0x28,.05);f:float(f.camera+0x34,math.pi/2);f:float(f.camera+0x8C,1)
    f:p(f.scene+0x28,f.array);f:matrix({1,0,0,0,0,1,0,0,0,0,1,0,10,20,30,1})
    f.backend={read=function(at,n)return f:read(at,n)end}
    f.io={module=function(name)f.modules=f.modules+1;return name=='game.dll'and f.game or f.exe,0,name=='game.dll'and(f.bad_game and 0 or 0x6AB3B43F)or(f.bad_exe and 0 or 0x6AB382E4)end}
    f.sr={Gui={resolution=function()return f.width,f.height end}}
    f.owner=Adapter.new({backend=f.backend,io=f.io,sr=f.sr});return f
end
test('construction inert and one frozen sample powers projection without more reads',function()
    local f=fixture();assert(f.reads==0 and f.modules==0);assert(f.owner:sample());local reads,modules=f.reads,f.modules
    local x,y,d=f.owner:project(10,22,30);close(x,.5);close(y,.5);close(d,2)
    x,y,d=f.owner:project(12,22,31);close(x,.78125);close(y,.25);close(d,2)
    assert(f.reads==reads and f.modules==modules)
end)
test('top-left coordinates stay unclipped; only positive near-plane depth is accepted',function()
    local f=fixture();assert(f.owner:sample());local x,y,d=f.owner:project(100,22,40);assert(x>1 and y<0 and d>0)
    assert(f.owner:project(10,20.01,30)==nil);assert(f.owner:project(10,19,30)==nil);assert(f.owner:project(0/0,22,30)==nil)
end)
test('plain placement uses captured right/up/negative-forward and does not follow later samples',function()
    local f=fixture();assert(f.owner:sample());local p=assert(f.owner:placement(2));close(p.center[1],10);close(p.center[2],22);close(p.center[3],30)
    assert(p.width==.8 and p.height==.5 and p.right[1]==1 and p.up[3]==1 and p.normal[2]==-1)
    assert(p.depth.origin[2]==20 and p.depth.direction[2]==1 and p.depth.distance==2)
    f:float(f.array+f.node*64+12*4,50);assert(f.owner:sample());assert(p.center[1]==10 and f.owner:placement(2).center[1]==50)
    local snapshot=f.owner:snapshot();snapshot.matrix[13]=999;assert(f.owner:snapshot().matrix[13]==50)
end)
test('all local offsets and nonidentity local rotations refuse stale CPU projection',function()
    for _,offset in ipairs({0x80,0x84,0x88,0x90,0x94,0x98,0x48,0x4C})do local f=fixture();assert(f.owner:sample());f:float(f.camera+offset,.00001)
        assert(not f.owner:sample());assert(f.owner:snapshot()==nil and f.owner:project(10,22,30)==nil)
    end
    local f=fixture();f:float(f.camera+0x8C,-1);assert(f.owner:sample());f:float(f.camera+0x8C,.9);assert(not f.owner:sample())
end)
test('current game/exe stamps and exact projection wrapper implementation scene bytes are required',function()
    for _,mode in ipairs({'game','exe','wrapper','call','implementation','scene'})do local f=fixture()
        if mode=='game'then f.bad_game=true elseif mode=='exe'then f.bad_exe=true elseif mode=='wrapper'then f:poke(f.getter,'X')
        elseif mode=='call'then f:poke(f.getter+0x132,'X')elseif mode=='implementation'then f:poke(f.implementation,'X')else f:poke(f.implementation+0x62,'X')end
        assert(not f.owner:sample(),mode);assert(f.owner:snapshot()==nil)
        if mode=='game'or mode=='exe'then assert(f.reads==0)end
    end
    local f=fixture();f.implementation=f.getter-0x2000;f:code();assert(f.owner:sample(),'Signed backwards relative call was not resolved')
end)
test('torn owners invalid mode node resolution and affine matrices fail closed',function()
    for _,mode in ipairs({'torn','projection','node','resolution','scale','handed','affine','short'})do local f=fixture()
        if mode=='torn'then f.torn=true elseif mode=='projection'then f:u(f.camera+0x50,1)elseif mode=='node'then f:u(f.camera+0x20,4096)
        elseif mode=='resolution'then f.height=0 elseif mode=='scale'then f:float(f.array+f.node*64,2)
        elseif mode=='handed'then f:float(f.array+f.node*64,-1)elseif mode=='affine'then f:float(f.array+f.node*64+3*4,1)
        else f.short=f.camera end
        assert(not f.owner:sample(),mode);assert(f.owner:snapshot()==nil)
    end
end)
test('rotated camera projection and placement retain engine basis conventions',function()
    local f=fixture();f:matrix({0,1,0,0,-1,0,0,0,0,0,1,0,10,20,30,1});assert(f.owner:sample())
    local x,y,d=f.owner:project(8,20,30);close(x,.5);close(y,.5);close(d,2)
    local p=f.owner:placement(2);close(p.center[1],8);close(p.center[2],20);assert(p.normal[1]==1 and p.right[2]==1)
end)
print(('PASS %d standalone camera adapter contracts'):format(tests))
