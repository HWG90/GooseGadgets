-- Read-only, standalone perspective-camera snapshot. No native calls, HUD
-- globals, mutable camera state, or private SDK dependencies.
local M={}
local function unhex(v)return(v:gsub('%x%x',function(x)return string.char(tonumber(x,16))end))end
local WRAPPER=unhex('48895c2408574883ec60')
local IMPLEMENTATION=unhex('488bc448895808488968104889701857')
local SCENE=unhex('488b471848c1e206418be948035028e80a951500')
local function word(s,o)o=o or 0;local a,b,c,d=s:byte(o+1,o+4);assert(d,'Camera word unavailable');return a+b*256+c*65536+d*16777216 end
local function pointer(s,o)o=o or 0;local v=word(s,o)+word(s,o+4)*4294967296;assert(v>=65536 and v<2^47,'Camera pointer unavailable');return v end
local function finite(v)return type(v)=='number'and v==v and math.abs(v)<1e7 end
local function copy(v)local out={};for k,x in pairs(v)do if type(x)=='table'then out[k]=copy(x)else out[k]=x end end;return out end
function M.new(options)
    local backend,io,sr=assert(options.backend),assert(options.io),assert(options.sr)
    assert(type(backend.read)=='function'and type(io.module)=='function'and sr.Gui and type(sr.Gui.resolution)=='function','Camera protected read/module/resolution required')
    local self={status='not sampled'};local current;local ffi,camera_floats,matrix_floats
    local function r(at,n)
        assert(type(at)=='number'and at==math.floor(at)and at>=65536 and at<2^47,'Camera read address invalid')
        assert(at>=65536 and n>0 and n<=4096 and at+n<2^47,'Camera read bounds invalid')
        local s,why=backend.read(at,n);assert(type(s)=='string'and #s==n,why or'Camera protected read unavailable');return s
    end
    local function p(at)return pointer(r(at,8))end
    local function modules()
        local g,_,gs=io.module('game.dll');local e,_,es=io.module('helldivers2.exe')
        assert(type(g)=='number'and g>=65536 and g<2^47 and type(e)=='number'and e>=65536 and e<2^47
            and gs==0x6AB3B43F and es==0x6AB382E4,'Unsupported wall terminal camera build')
        return g,e
    end
    local function sample(identity_only)
        local game,exe=modules()
        -- Fingerprint the same public engine projection wrapper and decoded
        -- implementation that establish the maintained camera scene layout.
        local engine=p(game+0x3326308);local api=p(engine+0x20);local getter=p(api+0xF8)
        local wrapper=r(getter,0x137);assert(wrapper:sub(1,#WRAPPER)==WRAPPER,'Unknown projection wrapper')
        local call=wrapper:sub(0x133,0x137);assert(call:byte()==0xE8,'Unknown projection call')
        local displacement=word(call,1);if displacement>=2147483648 then displacement=displacement-4294967296 end
        local implementation=getter+0x137+displacement;local code=r(implementation,0x76)
        assert(code:sub(1,#IMPLEMENTATION)==IMPLEMENTATION,'Unknown projection implementation')
        assert(code:sub(0x63,0x76)==SCENE,'Unknown camera scene layout')
        local state_bytes=r(game+0x346D560,8);local state=pointer(state_bytes)
        local owner_bytes=r(state,8);local camera=pointer(owner_bytes);local data=r(camera,160)
        local scene,index=pointer(data,0x18),word(data,0x20)
        assert(index<4096 and word(data,0x30)==1 and word(data,0x50)==0,'Unsupported perspective camera mode/node')
        ffi=ffi or require('ffi');camera_floats=camera_floats or ffi.new('float[40]');matrix_floats=matrix_floats or ffi.new('float[16]')
        ffi.copy(camera_floats,data,160)
        local near,fov=tonumber(camera_floats[0x28/4]),tonumber(camera_floats[0x34/4])
        assert(finite(near)and near>0 and near<10 and finite(fov)and fov>.05 and fov<3.1,'Camera near plane/FOV invalid')
        for _,offset in ipairs({0x80,0x84,0x88,0x90,0x94,0x98,0x48,0x4C})do
            local v=tonumber(camera_floats[offset/4]);assert(finite(v),'Camera local offset is invalid')
            if not identity_only then assert(math.abs(v)<1e-6,'Camera local offset unsupported for CPU projection')end
        end
        local qw=tonumber(camera_floats[0x8C/4]);assert(finite(qw),'Camera local rotation is invalid')
        if not identity_only then assert(math.abs(math.abs(qw)-1)<1e-6,'Camera local rotation unsupported for CPU projection')end
        local array_bytes=r(scene+0x28,8);local array=pointer(array_bytes);local pose_bytes=r(array+index*64,64)
        ffi.copy(matrix_floats,pose_bytes,64);local matrix={}
        for i=1,16 do local v=tonumber(matrix_floats[i-1]);assert(finite(v),'Camera matrix nonfinite');matrix[i]=v end
        for _,k in ipairs({1,5,9})do assert(math.abs(matrix[k]^2+matrix[k+1]^2+matrix[k+2]^2-1)<.01,'Camera matrix axis scale invalid')end
        for _,pair in ipairs({{1,5},{1,9},{5,9}})do local a,b=pair[1],pair[2];assert(math.abs(matrix[a]*matrix[b]+matrix[a+1]*matrix[b+1]+matrix[a+2]*matrix[b+2])<.01,'Camera matrix axes invalid')end
        local handed=(matrix[2]*matrix[7]-matrix[3]*matrix[6])*matrix[9]
            +(matrix[3]*matrix[5]-matrix[1]*matrix[7])*matrix[10]+(matrix[1]*matrix[6]-matrix[2]*matrix[5])*matrix[11]
        assert(handed>.99 and math.abs(matrix[4])+math.abs(matrix[8])+math.abs(matrix[12])+math.abs(matrix[16]-1)<1e-5,'Camera affine/orientation invalid')
        local width,height=sr.Gui.resolution();assert(finite(width)and finite(height)and width>0 and height>0,'Camera GUI resolution unavailable')
        local aspect=width/height;assert(aspect>.1 and aspect<10,'Camera aspect invalid')
        local g2,e2=modules();local w2,h2=sr.Gui.resolution()
        assert(g2==game and e2==exe and width==w2 and height==h2 and p(game+0x3326308)==engine and p(engine+0x20)==api and p(api+0xF8)==getter
            and r(getter,0x137)==wrapper and r(implementation,0x76)==code,'Camera engine/build/layout changed during snapshot')
        assert(r(game+0x346D560,8)==state_bytes and r(state,8)==owner_bytes and r(camera,160)==data
            and r(scene+0x28,8)==array_bytes and r(array+index*64,64)==pose_bytes,'Camera owner/pose changed during snapshot')
        return{game=game,exe=exe,state=state,camera=camera,scene=scene,index=index,array=array,getter=getter,implementation=implementation,
            matrix=matrix,fov=fov,near=near,aspect=aspect,width=width,height=height,tangent=math.tan(fov*.5)}
    end
    function self:sample()
        current=nil
        local ok,value=pcall(sample)
        if not ok then self.status=tostring(value);return false,self.status end
        current=value;self.status='camera sampled';return true
    end
    -- Identity ownership is valid with recoil/local camera transforms that the
    -- CPU projector cannot reproduce. Do not publish these as projectable data
    -- or replace/clear its separate strict snapshot.
    function self:sample_identity()
        local ok,value=pcall(sample,true)
        if not ok then self.identity_status=tostring(value);return false,self.identity_status end
        self.identity_status='camera identity sampled';return true,copy(value)
    end
    function self:project(x,y,z)
        if not current then return nil,self.status end
        if not finite(x)or not finite(y)or not finite(z)then return nil,'Camera point invalid'end
        local c,m=current,current.matrix;local dx,dy,dz=x-m[13],y-m[14],z-m[15]
        local right=dx*m[1]+dy*m[2]+dz*m[3];local depth=dx*m[5]+dy*m[6]+dz*m[7];local up=dx*m[9]+dy*m[10]+dz*m[11]
        if depth<=math.max(c.near,.0001)then return nil,'Point behind camera/near plane'end
        local nx,ny=.5+.5*right/(depth*c.tangent*c.aspect),.5-.5*up/(depth*c.tangent)
        if nx~=nx or ny~=ny or math.abs(nx)==math.huge or math.abs(ny)==math.huge then return nil,'Camera projection nonfinite'end
        return nx,ny,depth
    end
    function self:snapshot()return current and copy(current)or nil,self.status end
    function self:placement(distance)
        if not current then return nil,self.status end
        distance=distance or 2;assert(finite(distance)and distance>=.5 and distance<=6 and distance>current.near+.01,'Terminal placement distance invalid')
        local m=current.matrix;local right,up,forward={m[1],m[2],m[3]},{m[9],m[10],m[11]},{m[5],m[6],m[7]}
        local origin={m[13],m[14],m[15]};local center={};for i=1,3 do center[i]=origin[i]+forward[i]*distance end
        local normal={right[2]*up[3]-right[3]*up[2],right[3]*up[1]-right[1]*up[3],right[1]*up[2]-right[2]*up[1]}
        return{center=center,right=right,up=up,normal=normal,width=.8,height=.5,
            depth={origin=origin,direction=forward,distance=distance,min=.5,max=6}}
    end
    return self
end
return M
