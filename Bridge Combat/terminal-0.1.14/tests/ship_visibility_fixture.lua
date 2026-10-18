-- Isolated alpha ownership/native-call contracts; no game attachment.
local ffi,bit=require('ffi'),require('bit')
local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT') or os.getenv('DBF_BRIDGE_COMBAT_TEST_ROOT'))
local Visibility=dofile(root..'/src/ship_visibility.lua')
local FP='40574883ec20f30f104144488bf90f2ec17a237521f70100'
local specs={{0x76040,0x820},{0x78470,0xA40},{0x1D00,0x930},
    {0x7BE8,0x930},{0xD170,0x930},{0x7CAF8,0xA40},{0x7D830,0xA40},
    {0x7E568,0x820},{0x7EDD0,0x820},{0x81950,0x820},{0x83510,0x820},{0x86660,0x930},{0x27E68-0x46D900,0xC60,11}}
local function bytes(kind,value)return ffi.string(ffi.new(kind..'[1]',value),ffi.sizeof(kind))end
local function unhex(value)return(value:gsub('..',function(pair)return string.char(tonumber(pair,16))end))end
local function fixture(alphas)
    local f={memory={},reads=0,lookups=0,binds=0,calls={},stamp=0x6AB3B43F}
    f.game,f.ui,f.gui,f.gs,f.menu=0x100000000,0x200000000,0x300000000,0x400000000,0x500000000
    function f:put(at,value)for i=1,#value do self.memory[at+i-1]=value:sub(i,i)end end
    function f:u(at,value)self:put(at,bytes('uint32_t',value))end
    function f:p(at,value)self:put(at,bytes('uint64_t',value))end
    function f:read(at,size)
        self.reads=self.reads+1
        if self.forbid and at>=self.forbid and at<self.forbid+0x500000 then error('Stale widget read')end
        if self.unreadable==at then return nil,'Injected unreadable memory'end
        local out={};for i=0,size-1 do out[#out+1]=self.memory[at+i] or '\0'end
        return table.concat(out)
    end
    function f:at(index)return self.ui+0x46D900+specs[index][1]end
    function f:flags(index)return tonumber(ffi.cast('const uint32_t *',self:read(self:at(index),4))[0])end
    function f:alpha(index)return tonumber(ffi.cast('const float *',self:read(self:at(index)+0x44,4))[0])end
    function f:alpha_bytes(index)return self:read(self:at(index)+0x44,4)end
    function f:a(index,value)self:put(self:at(index)+0x44,bytes('float',value))end
    function f:normal_layout()
        for index=1,#specs do
            local shown=bit.band(self:flags(index),0x10)~=0
            self:put(self:at(index)+0x54,bytes('float',shown and self:alpha(index) or 0))
        end
    end
    f:p(f.game+0x3326340,f.gs);f:u(f.gs+0xAC21C,3)
    f:p(f.game+0x346D538,f.ui);f:p(f.game+0x347CE90,f.gui);f:p(f.game+0x347CE28,f.menu)
    f:put(f.ui+0x24E334,'\1');f:put(f.ui+0x4F7078,'\1');f:put(f.game+0x1448AD0,unhex(FP))
    f.addresses={}
    for index,spec in ipairs(specs)do
        local at=f:at(index)
        f.addresses[at]=index;f:u(at,0x91);f:a(index,alphas and alphas[index] or 1)
        f:p(at+0xF0,(spec[2]==0 and 0 or f.ui+spec[2]));f:p(at+0xF8,f.gui+(spec[3] or 5)*0x3698)
    end
    f.backend={_ffi=ffi,read=function(_,...)return f:read(...)end}
    f.io={module=function(name)f.lookups=f.lookups+1;assert(name=='game.dll');return f.game,0x4744000,f.stamp end,
        native=function(at,abi,fp,label)
            f.binds=f.binds+1
            assert(at==f.game+0x1448AD0 and abi=='void (*)(void *, float)' and fp==FP
                and label=='BRIDGE_SHIP_WIDGET_ALPHA','Wrong native contract')
            return function(pointer,alpha)
                local target=tonumber(ffi.cast('uintptr_t',pointer));local index=assert(f.addresses[target],
                    'Native call was not an authored Ship widget root')
                assert(type(alpha)=='number' and target~=f.ui+0x46D900,'Ship aggregate passed to widget API')
                f.calls[#f.calls+1]={index=index,alpha=alpha,target=target}
                if not f.no_ack then
                    f:a(index,alpha);f:u(target,bit.bor(f:flags(index),4))
                    f:u(target+0xB8,0x20) -- Normal native dirty/layout propagation.
                end
                if f.on_call then f:on_call(index,alpha)end
            end
        end}
    f.controller=Visibility.new(f.backend,f.io);f.reads=0
    return f
end
local passed=0
local function test(name,fn)local ok,why=pcall(fn);assert(ok,name..': '..tostring(why));passed=passed+1;print('PASS '..name)end

test('import construction and disabled empty updates perform no IO',function()
    local f=fixture();assert(f.reads==0 and f.lookups==0 and f.binds==0 and #f.calls==0)
    assert(f.controller:update(false) and f.controller:restore())
    assert(f.reads==0 and f.lookups==0 and f.binds==0 and #f.calls==0)
end)
test('all thirteen local alphas use only the cached native alpha setter',function()
    local f=fixture();assert(f.controller:update(true));assert(#f.calls==13 and f.binds==1)
    for index=1,#specs do
        assert(f:alpha(index)==0 and f.calls[index].index==index and f.calls[index].alpha==0)
        assert(bit.band(f:flags(index),0x10)~=0,'Logical visibility was changed')
    end
    assert(f.controller:status().active and f.controller:status().owned==13)
    assert(f.controller:update(true) and #f.calls==13 and f.binds==1,'Zero alpha was repeatedly set')
end)
test('normal visibility re-enable cannot resurrect zero local alpha during layout',function()
    local f=fixture();assert(f.controller:update(true))
    for index=1,#specs do f:u(f:at(index),bit.bor(f:flags(index),0x10))end
    f:normal_layout()
    for index=1,#specs do assert(ffi.cast('const float *',f:read(f:at(index)+0x54,4))[0]==0)end
    assert(f.controller:update(true) and #f.calls==13)
end)
test('exact fractional alpha bytes restore and originally zero roots remain untouched',function()
    local f=fixture({[2]=0,[3]=0.375,[6]=0,[9]=0.25})
    local originals={};for index=1,#specs do originals[index]=f:alpha_bytes(index)end
    assert(f.controller:update(true) and #f.calls==11)
    assert(f.controller:restore() and #f.calls==22)
    for index=1,#specs do assert(f:alpha_bytes(index)==originals[index])end
    local before=f.reads;assert(f.controller:restore() and f.reads==before)
end)
test('acknowledged alpha is applied once and later native changes are preserved',function()
    local f=fixture();assert(f.controller:update(true));f:a(5,0.625)
    assert(f.controller:update(true) and #f.calls==13 and f:alpha(5)==0.625)
    assert(f.controller:restore() and f:alpha(5)==0.625)
end)
test('restore never overwrites a nonzero foreign alpha',function()
    local f=fixture();assert(f.controller:update(true));f:a(3,0.5)
    local before=#f.calls;assert(f.controller:restore() and #f.calls-before==12 and f:alpha(3)==0.5)
end)
test('all root parents and contexts preflight before the first mutation',function()
    for _,field in ipairs({0xF0,0xF8})do
        local f=fixture();f:p(f:at(13)+field,0x600000000)
        local ok,why=f.controller:update(true);assert(not ok and why:find('differs') and #f.calls==0 and f.binds==0)
    end
end)
test('active alpha animation is refused without canceling game animation slots',function()
    local f=fixture();f:u(f:at(13),bit.bor(f:flags(13),0x08000000));f:u(f:at(13)+0xB0,2048)
    local ok,why=f.controller:update(true)
    assert(not ok and why:find('alpha animation is active') and #f.calls==0 and f.binds==0)
    f:u(f:at(13)+0xB0,0);assert(f.controller:update(true) and #f.calls==13)
end)
test('restoration waits while a new game alpha animation owns a root',function()
    local f=fixture();assert(f.controller:update(true));local before=#f.calls
    f:u(f:at(13),bit.bor(f:flags(13),0x08000000));f:u(f:at(13)+0xB0,2048)
    assert(not f.controller:restore() and #f.calls==before and f.controller:status().owned==13)
    f:u(f:at(13)+0xB0,0);assert(f.controller:restore() and #f.calls==before+13)
end)
test('nonfinite alpha is refused before binding or any mutation',function()
    for _,bits in ipairs({0x7F800000,0xFF800000,0x7FC00001})do
        local f=fixture();f:u(f:at(13)+0x44,bits)
        local ok,why=f.controller:update(true);assert(not ok and why:find('not finite') and #f.calls==0 and f.binds==0)
    end
end)
test('build fingerprint and all readable alpha fields are required',function()
    local f=fixture();f.stamp=1;assert(not f.controller:update(true) and #f.calls==0 and f.binds==0)
    f=fixture();f:put(f.game+0x1448AD0,'X');assert(not f.controller:update(true) and #f.calls==0 and f.binds==0)
    f=fixture();f.unreadable=f:at(13)+0x44;assert(not f.controller:update(true) and #f.calls==0 and f.binds==0)
end)
test('void setter requires positive local-alpha acknowledgement and journals first',function()
    local f=fixture();f.no_ack=true
    local ok,why=f.controller:update(true)
    assert(not ok and why:find('not acknowledged') and #f.calls==1 and f.controller:status().owned==1)
    f.no_ack=false;assert(f.controller:restore() and #f.calls==1,'Already nonzero alpha was overwritten')
end)
test('failed post-call readback retains exact alpha cleanup',function()
    local f=fixture()
    f.on_call=function(self,index,alpha)if alpha==0 then self.unreadable=self:at(index)+0x44 end end
    assert(not f.controller:update(true) and #f.calls==1 and f.controller:status().owned==1)
    f.on_call=nil;f.unreadable=nil;assert(f.controller:restore())
    assert(#f.calls==2 and f.calls[2].alpha==1 and f.calls[2].index==1)
end)
test('restore validates every root before restoring any owned alpha',function()
    local f=fixture();assert(f.controller:update(true));local before=#f.calls
    f:p(f:at(13)+0xF0,0x600000000)
    assert(not f.controller:restore() and #f.calls==before and f.controller:status().owned==13)
    f:p(f:at(13)+0xF0,f.ui+specs[13][2]);assert(f.controller:restore() and #f.calls==before+13)
end)
test('menus prevent new alpha changes and retain an existing lease without calls',function()
    local f=fixture();f:u(f.menu+0x4294,13)
    assert(f.controller:update(true) and #f.calls==0 and f.binds==0 and not f.controller:status().pending)
    f:u(f.menu+0x4294,0);assert(f.controller:update(true));local before=#f.calls
    f:u(f.menu+0x4298,13);assert(f.controller:update(true))
    assert(#f.calls==before and f.controller:status().owned==13 and not f.controller:status().active)
end)
test('positive scene retirement performs no stale widget access',function()
    local f=fixture();assert(f.controller:update(true));local before=#f.calls
    f:u(f.gs+0xAC21C,4);f.forbid=f.ui
    assert(f.controller:restore() and #f.calls==before and not f.controller:status().pending)
end)
test('UI replacement and initialized retirement avoid stale widgets',function()
    local f=fixture();assert(f.controller:update(true));local before=#f.calls
    f:p(f.game+0x346D538,0x600000000);f.forbid=f.ui
    assert(f.controller:restore() and #f.calls==before and not f.controller:status().pending)
    for _,offset in ipairs({0x24E334,0x4F7078})do
        f=fixture();assert(f.controller:update(true));before=#f.calls
        f:put(f.ui+offset,'\0');f.unreadable=f:at(1)+0xF0
        assert(f.controller:restore() and #f.calls==before and not f.controller:status().pending)
    end
end)
test('retirement during setter avoids old-widget readback and later calls',function()
    local f=fixture()
    f.on_call=function(self)self:u(self.gs+0xAC21C,4);self.forbid=self.ui end
    assert(f.controller:update(true) and #f.calls==1 and not f.controller:status().pending)
end)
test('unreadable identity retains ownership until cleanup can acknowledge',function()
    local f=fixture();assert(f.controller:update(true));local before=#f.calls
    f.unreadable=f.game+0x346D538
    assert(not f.controller:restore() and #f.calls==before and f.controller:status().owned==13)
    f.unreadable=nil;assert(f.controller:restore() and #f.calls==before+13)
end)
test('shared social parent and chat are excluded from the cosmetic lease',function()
    local f=fixture();local at=f.ui+0xC60;f:put(at+0x44,bytes('float',1))
    assert(f.controller:update(true));local calls=#f.calls
    for _=1,100 do assert(f.controller:update(true))end
    assert(#f.calls==calls and ffi.cast('const float *',f:read(at+0x44,4))[0]==1)
end)
test('native emote wheel is untouched on entry steady state and cleanup',function()
    local f=fixture();local at=f.ui+0x46D908
    f:put(at+0x44,bytes('float',1))
    assert(f.controller:update(true))
    for _=1,100 do assert(f.controller:update(true))end
    assert(f.controller:restore())
    assert(ffi.cast('const float *',f:read(at+0x44,4))[0]==1)
    for _,call in ipairs(f.calls)do assert(call.target~=at)end
end)
print(('Ship alpha visibility contracts: %d passed'):format(passed))
