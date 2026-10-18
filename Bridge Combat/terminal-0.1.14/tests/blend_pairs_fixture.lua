-- Offline byte-memory ownership contracts; no game process or native calls.
local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))
local ffi=require('ffi')
local Module=dofile(root..'/tools/live_blend_pairs.lua')
local specs={{0x11C0,0x6337D460},{0x11C4,0x2113EA75},{0x11C8,0x1F7FB073},
    {0x11E4,0xF8B62730},{0x11E8,0xED5708CA}}
local checks=0
local function check(value,why)checks=checks+1;assert(value,why or 'Contract failed')end
local function eq(a,b)check(a==b,tostring(a)..' ~= '..tostring(b))end
local function bytes(kind,n)return ffi.string(ffi.new(kind..'[1]',n),ffi.sizeof(kind))end
local function fixture()
    local f={memory={},reads=0,observations=0,writes={},unique_value=true}
    f.view={game=0x100000000,stamp=0x6AB3B43F,world=0x200000000,pm=0x300000000,
        lc=0x400000000,avatar=0x12345678,di=2,def=0x500000000,
        pc=0x600000000,state=0x700000000,ep=0x800000000,scene=3}
    f.table,f.index,f.slot=0x900000000,5,3
    f.base=f.table+0x1980+f.index*0x1210
    function f:put(at,s)for i=1,#s do self.memory[at+i-1]=s:sub(i,i)end end
    function f:u(at,n)self:put(at,bytes('uint32_t',n))end
    function f:p(at,n)self:put(at,bytes('uint64_t',n))end
    function f:read(at,size)
        self.reads=self.reads+1
        if self.unreadable==at then return nil end
        if self.throw_read==at then error('fixture read throws')end
        local out={};for i=0,size-1 do out[#out+1]=self.memory[at+i]or'\0'end
        return table.concat(out)
    end
    function f:observe()
        self.observations=self.observations+1
        if self.unobserved then return nil,'observation unreadable'end
        local v={};for k,x in pairs(self.view)do v[k]=x end
        if self.partial_observation then v.avatar=nil;v.def=nil;v.ep=nil end
        return v
    end
    function f:unique()return self.unique_value,'uniqueness unreadable'end
    function f:write(at,value)
        check(#value==4,'Only four-byte writes are allowed')
        local allowed=false;for _,spec in ipairs(specs)do if at==self.owned+spec[1]then allowed=true end end
        check(allowed,'Write escaped the five-field allowlist')
        self.writes[#self.writes+1]={address=at,value=value}
        if self.writer then return self.writer(self,at,value,#self.writes)end
        self:put(at,value);return true,nil,4
    end
    f.owned=f.view.def
    f:put(f.view.ep,'ABCDEFGH'..bytes('uint32_t',f.view.avatar)..bytes('uint32_t',0xAABBCCDD)..'\0\0\0\0\1\0\0\0')
    f:p(f.view.world+0xF12E30,f.table)
    f:put(f.table+f.slot*16,'ABCDEFGH'..bytes('uint32_t',f.index)..'\0\0\0\0')
    f:put(f.base,string.rep('A',0x1160)..string.rep('B',0xB0))
    f:put(f.view.def,f:read(f.base,0x1210))
    for i,spec in ipairs(specs)do
        f:u(f.base+spec[1],spec[2]);f:u(f.view.def+spec[1],0xAABB0000+i)
    end
    f:u(f.view.pc+0xFD0,2)
    f.original=f:read(f.view.def,0x1210)
    f.reads=0;f.observations=0
    f.lease=Module.new(f)
    return f
end
local function capture(f)local s,why=f.lease:capture();check(s,why);return s end
local function apply(f)local s=capture(f);local ok,why=f.lease:apply(s);check(ok,why);return s end
local function original(f)eq(f:read(f.owned,0x1210),f.original)end
do
    local f=fixture();eq(f.reads,0);eq(f.observations,0);eq(#f.writes,0)
    local s=capture(f);eq(s.count,5);eq(#f.writes,0);original(f)
    check(f.lease:apply(s));eq(#f.writes,5)
    eq(f.lease:status().pending,5)
    local changed=f:read(f.owned,0x1210)
    for _,spec in ipairs(specs)do eq(changed:sub(spec[1]+1,spec[1]+4),bytes('uint32_t',spec[2]))end
    eq(changed:sub(1,0x1160),f.original:sub(1,0x1160))
    eq(changed:sub(0x1201),f.original:sub(0x1201)) -- +0x1200 and final trailer untouched.
    check(f.lease:restore());original(f);eq(#f.writes,10);eq(f.lease:status().pending,0)
end
for _,mutate in ipairs({
    function(f)f.view.scene=4 end,
    function(f)f:u(f.view.pc+0xFD0,4)end,
    function(f)f:put(f.owned,'Z')end,
    function(f)f:u(f.base+0x11C0,0)end,
    function(f)f:u(f.table+f.slot*16+8,408)end,
    function(f)f:put(f.table+16,'ABCDEFGH'..bytes('uint32_t',5)..'\0\0\0\0')end,
    function(f)f.view.def=f.base end,
    function(f)f.unique_value=false end,
    function(f)f:put(f.view.ep+0x14,'\0')end,
    function(f)f.unreadable=f.view.ep end,
})do
    local f=fixture();mutate(f);local s=f.lease:capture();check(s==nil);eq(#f.writes,0)
end
do
    local f=fixture();local s=capture(f);s.base=1;s.definition=2;s.count=99
    check(f.lease:apply(s));check(f.lease:restore());original(f)
    local arbitrary={};local ok=f.lease:apply(arbitrary);check(not ok);eq(#f.writes,10)
end
for _,mutate in ipairs({
    function(f)f:u(f.owned+0x11C4,99)end,
    function(f)f:put(f.base+0x1200,'X')end,
    function(f)f:p(f.view.world+0xF12E30,f.table+0x10000)end,
    function(f)f.view.avatar=f.view.avatar+1 end,
    function(f)f:put(f.view.ep+0x14,'\0')end,
    function(f)f:u(f.view.pc+0xFD0,4)end,
})do
    local f=fixture();local s=capture(f);mutate(f);check(not f.lease:apply(s));eq(#f.writes,0)
end
do
    local f=fixture();apply(f);f:u(f.view.pc+0xFD0,4);f.view.scene=4
    check(f.lease:restore());original(f)
end
do
    local f=fixture();apply(f);f:u(f.owned+0x11C4,0x13572468)
    check(f.lease:restore());eq(f:read(f.owned+0x11C4,4),bytes('uint32_t',0x13572468))
    eq(#f.writes,9);eq(f.lease:status().pending,0)
end
for _,mutate in ipairs({
    function(f)f.view.avatar=f.view.avatar+1 end,
    function(f)f.view.world=f.view.world+1 end,
    function(f)f:put(f.view.ep+0x14,'\0');f.partial_observation=true end,
})do
    local f=fixture();apply(f);mutate(f);check(f.lease:restore());eq(#f.writes,5)
    eq(f.lease:status().pending,0);eq(f.lease:status().state,'retired')
end
for _,mode in ipairs({'unobserved','partial_observation','unreadable','throw_read','unique'})do
    local f=fixture();apply(f)
    if mode=='unreadable' or mode=='throw_read'then f[mode]=f.view.ep
    elseif mode=='unique'then f.unique_value=false else f[mode]=true end
    check(not f.lease:restore());eq(f.lease:status().pending,5);eq(#f.writes,5)
    f.unobserved=nil;f.partial_observation=nil;f.unreadable=nil;f.throw_read=nil;f.unique_value=true
    check(f.lease:restore());original(f)
end
for _,failure in ipairs({'zero','full','partial','throw'})do
    local f=fixture();local s=capture(f)
    f.writer=function(self,at,value,n)
        if n==3 then
            if failure=='full'or failure=='throw'then self:put(at,value)
            elseif failure=='partial'then self:put(at,value:sub(1,2))end
            if failure=='throw'then error('write failed after copying')end
            return false,'injected failure',failure=='partial'and 2 or failure=='full'and 4 or 0
        end
        self:put(at,value);return true,nil,4
    end
    check(not f.lease:apply(s));eq(f.lease:status().pending,0);original(f)
end
do
    local f=fixture();apply(f)
    local stop=true
    f.writer=function(self,at,value)
        if stop then self:put(at,value:sub(1,2));return false,'short restoration',2 end
        self:put(at,value);return true,nil,4
    end
    check(not f.lease:restore());check(f.lease:status().pending>0)
    stop=false;check(f.lease:restore());original(f)
end
do
    local f=fixture();apply(f);f.throw_read=f.owned+0x11C4
    check(not f.lease:restore());eq(f.lease:status().pending,1)
    f.throw_read=nil;check(f.lease:restore());original(f)
end
do
    local f=fixture();local s=capture(f)
    f.writer=function(self,at,value)
        self:put(at,value);self.view.avatar=self.view.avatar+1;return true,nil,4
    end
    check(not f.lease:apply(s));eq(#f.writes,1);eq(f.lease:status().pending,0)
end
do
    local f=fixture();local s=capture(f)
    f.writer=function(self,at,value)
        self:put(at,value);self.unobserved=true;return true,nil,4
    end
    check(not f.lease:apply(s));eq(f.lease:status().pending,1)
    check(f.lease:capture()==nil);check(not f.lease:apply(s));eq(#f.writes,1)
    f.unobserved=nil;f.writer=nil;check(f.lease:restore());original(f)
end
do
    local f=fixture();local s=capture(f)
    f.writer=function(self,at,value,n)
        self:put(at,value)
        if n==1 then self:put(self.base+0x1200,'X')end
        return true,nil,4
    end
    check(not f.lease:apply(s));eq(f.lease:status().pending,0);original(f)
end
do
    local f=fixture()
    for _,spec in ipairs(specs)do f:u(f.owned+spec[1],spec[2])end
    local s=capture(f);check(f.lease:apply(s));eq(#f.writes,0)
    check(f.lease:restore());eq(f.lease:status().pending,0)
end
print('blend_pairs_fixture: '..checks..' checks passed')
