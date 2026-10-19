-- Repairs only the retired-owner -> new Ship actor transition. No update loop.
-- A live Mission, unchanged body, open action or foreign widget never qualifies.
local M={}
local function word(s,o)local a,b,c,d=s:byte(o+1,o+4);assert(d,'Ship return word unavailable');return a+b*256+c*65536+d*16777216 end
function M.new(io,backend)
    local self={phase='idle'};local ffi,remove
    local function r(a,n)local s,why=io.read(a,n);assert(type(s)=='string'and #s==n,why or'Ship return memory unavailable');return s end
    local function u(a)return word(r(a,4),0)end
    local function p(a)local s=r(a,8);local n=word(s,0)+word(s,4)*4294967296;assert(n>=65536 and n<2^47,'Ship return pointer invalid');return n end
    function self:repair(lease,v,status,preflight)
        if self.phase=='done'then return true end
        if not lease or not v or not v.base or not status then return true end
        local unowned=preflight==true and status.phase==0 and not status.owned and not status.active and not status.pending and not status.role8_owned
        if not unowned and (preflight or status.phase~=13 or not status.owned or not status.pending)then return true end
        local b=v.base
        if not v.can_start or not v.menu_closed or v.photo or v.fixed_pose or b.scene~=3 then return true end
        if unowned then
            if v.context~=2 or b.avatar~=lease.avatar or v.render~=lease.render or b.ep~=lease.ep then return true end
        elseif v.context~=4 or b.avatar==lease.avatar or v.render==lease.render then return true end
        local g,_,gs=io.module('game.dll');local e,_,es=io.module('helldivers2.exe')
        assert(gs==0x6AB3B43F and es==0x6AB382E4 and g==b.game and g==lease.game,'Ship return build/owner differs')
        local registry=p(e+0x1A100F0);local count=u(registry+0x98);local index=lease.render%0x400000
        assert(count>0 and count<=0x400000 and index<count,'Retired body registry differs')
        local function generation_ok()local same=r(p(registry+0xA0)+index,1):byte()==math.floor(lease.render/0x400000);return unowned and same or not unowned and not same end
        if not generation_ok()then return true end
        local context=unowned and 2 or 4
        local ui=p(g+0x346D538);local pc=b.pc;local roles=u(pc+0xFD0)
        if unowned then assert(pc==b.pm+0x53D8B0,'Current control row changed')end
        local function gate(expected)
            assert(p(g+0x346BF98)==b.world and p(g+0x3326D20)==b.pm and p(b.pm+0x110)==b.ep
                and u(b.ep+8)==b.avatar and u(b.ep+12)==v.render and r(b.ep+20,1):byte()%2==1
                and io.hashmap(b.pm+0xF8,b.avatar)==0 and u(p(g+0x3326340)+0xAC21C)==3,'Current Ship actor changed')
            assert(p(g+0x346D538)==ui and r(ui+0x24E334,1)=='\1'and r(ui+0x46D8F0,1)=='\0'
                and r(ui+0x4F7078,1)=='\1'and r(ui+0x46D900,1)=='\1','Native Mission/Ship owner changed')
            assert(p(e+0x1A100F0)==registry and generation_ok(),'Ship return body generation changed')
            assert(u(pc+0xFD0)==expected and (expected%16==context or expected%16==context+8)and u(pc+0xFD8)==0,'Ship action/context changed')
            local aux=p(g+0x3326420);local row=assert(io.hashmap(aux+0x30,b.avatar));assert(row<0x100000 and r(p(aux+0x58)+row*0x20+5,1)=='\0','Ship auxiliary action is open')
            for _,off in ipairs({0x257F78,0x3E8E38,0x267658})do
                assert(u(ui+off)==0 and r(ui+off+0xE0,32)==string.rep('\0',32),'A native weapon widget still has an owner')
            end
        end
        if roles%16~=context and roles%16~=context+8 then return true end
        gate(roles)
        if self.phase=='idle'then self.pc,self.avatar,self.reference,self.roles,self.ui=pc,b.avatar,v.render,roles,ui;self.phase='prepared'end
        assert(self.pc==pc and self.avatar==b.avatar and self.reference==v.render and self.ui==ui,'Ship return repair owner changed')
        if self.phase=='prepared'and self.roles%16==context+8 then
            gate(self.roles);ffi=ffi or require('ffi');remove=remove or assert(io.native(g+0xAA0BB0,'void (*)(void *, const void *)',
                '48895c2418574883ec20488bb9800f00004c8bc94c8b5a10','SHIP_RETURN_ORPHAN_ROLE_REMOVE'))
            local mask=ffi.new('uint64_t[3]',8,0,0);self.phase='role_unknown';remove(ffi.cast('void *',pc+0x50),mask);self.phase='role_returned'
        end
        assert(self.phase~='role_unknown','Ship return native result unknown; no replay')
        local expected=self.roles-self.roles%16+context;gate(expected)
        assert(u(pc+0xFD0)==expected,'Ship return role removal not acknowledged')
        local flag=r(ui+0x24E398,1);assert(flag=='\0'or flag=='\1','Inactive Mission presentation flag invalid')
        if flag=='\1'then
            -- MINIT=0 and empty weapon roots prove no native Mission widgets.
            -- This stale active byte otherwise deadlocks the old owner's stop.
            self.phase='presentation_pending';local ok,why=backend:write(ui+0x24E398,'\0');assert(ok,why)
        end
        gate(expected);assert(r(ui+0x24E398,1)=='\0','Ship return presentation repair not acknowledged')
        self.phase='done';return true
    end
    return self
end
return M
