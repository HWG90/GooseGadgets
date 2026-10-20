local C=dofile('src/catalogue.lua')
mod={require=function(name)return dofile(name)end}
local Backend=dofile('src/backend.lua')
local GAME,ACCOUNT,WEAPONS,LOADOUT,PROFILE=0x140000000,0x300000000,0x310000000,0x320000000,0x330000000
local checks=0
local function check(v,why)checks=checks+1;assert(v,why or ('Check '..checks))end
local function fixture(n)
    n=n or 7
    local cells,writes={},{}
    local function put(at,s)for i=1,#s do cells[at+i-1]=s:byte(i)end end
    local function read(at,size)local s={};for i=0,size-1 do if cells[at+i]==nil then return nil end;s[#s+1]=string.char(cells[at+i])end;return table.concat(s)end
    local function pointer(v)return C.word(v%4294967296)..C.word(math.floor(v/4294967296))end
    local function code(at,hex)put(GAME+at,hex:gsub('%x%x',function(v)return string.char(tonumber(v,16))end))end
    code(0x11E7810,'488b05d1f11302448bc9468b8488401b00004585c0742846')
    code(0x136EC00,'48895c240848896c2410488974241848897c242041554156')
    code(0x136E6A0,'4c8bdc53555641554881eca8000000488b055ad92c014833')
    put(GAME+0x347CEF8,pointer(ACCOUNT));put(GAME+0x33269E8,pointer(WEAPONS))
    put(GAME+0x347CE50,pointer(LOADOUT));put(GAME+0x347CDD8,pointer(PROFILE))
    put(GAME+0x347CE28,pointer(PROFILE+0x10000));put(PROFILE+0x10000+0x4294,string.rep('\0',32))
    local world,component=0x340000000,0x350000000
    put(GAME+0x346BF98,pointer(world));put(world+0xF12CF0,pointer(component))
    put(component-28,('d0f3a8eb4c444c4401000000d0f3a8ebe05d0e000100000000000000'):gsub('%x%x',function(v)return string.char(tonumber(v,16))end))
    put(component,C.RESOURCE..C.word(0)..C.word(0)..string.rep('\0',6112-16))
    put(component+6112,C.word(5)..C.word(0x5672E4B7)..string.rep('\0',72))
    put(ACCOUNT+0x178A4EC,string.rep('\0',512*148))
    put(LOADOUT+0x2D200,C.word(1));put(LOADOUT+0x38,C.word(1000));put(PROFILE+0x40,C.word(1000))
    put(WEAPONS+42*32,C.word(C.ID)..C.word(0)..C.RESOURCE..C.word(1)..string.rep('\0',12))
    put(ACCOUNT+0xDDCF8,C.word(12));put(ACCOUNT+C.COUNT,C.word(n))
    local kind_counts={};for kind=0,23 do kind_counts[kind]=0 end
    local group={};for kind=0,23 do group[kind]={}end
    for i=0,n-1 do
        local kind=i%4
        put(ACCOUNT+C.RECORDS+i*C.RECORD,C.word(i)..C.word(1000+i)..C.word(1000+i)..C.word(kind)..string.rep('\0',C.RECORD-16))
        put(ACCOUNT+C.INDEXES+i*C.INDEX,C.word(i)..C.word(1000+i)..C.word(1000+i)..string.rep('\0',12))
        group[kind][#group[kind]+1]=i
    end
    local boundaries,ordering,count={},{},0
    for kind=0,23 do
        boundaries[#boundaries+1]=C.word(count)
        for _,i in ipairs(group[kind])do ordering[#ordering+1]=C.word(i);count=count+1 end
    end
    boundaries[#boundaries+1]=C.word(n)
    put(ACCOUNT+C.CATEGORIES,table.concat(boundaries));put(ACCOUNT+C.ORDER,table.concat(ordering)..'tail')
    put(ACCOUNT+C.RECORDS+n*C.RECORD,string.rep('r',C.RECORD))
    put(ACCOUNT+C.INDEXES+n*C.INDEX,string.rep('i',C.INDEX))
    local mem={reads=0,root=GAME}
    function mem:_module()return self.root,0x6AB3B43F end
    function mem:read(at,size)self.reads=self.reads+1;return read(at,size)end
    function mem:u32(at)return C.u32(self:read(at,4))end
    function mem:ptr(at)local b=self:read(at,8);return b and C.u32(b)+C.u32(b,4)*4294967296 end
    function mem:copy(at,s)
        writes[#writes+1]={at=at,size=#s}
        if self.fail==#writes then
            local amount=self.partial or 0;put(at,s:sub(1,amount))
            if self.unknown then return false,'unknown',nil end
            return false,'injected failure',amount
        end
        put(at,s);return true,nil,#s
    end
    return Backend.new(mem),mem,writes,put,read,pointer
end
local backend,mem,writes,put,read,pointer=fixture()
local plan=assert(backend:prepare())
check(#writes==0,'Read-only preparation wrote memory')
local originals={};for _,e in ipairs(plan.edits)do originals[e.offset]=e.before end
check(backend:apply(plan)==true and mem:u32(ACCOUNT+C.COUNT)==8)
check(writes[#writes].at==ACCOUNT+C.COUNT,'Count was not published last')
check(mem:u32(ACCOUNT+C.RECORDS+7*C.RECORD+8)==C.ID)
local duplicate=backend:prepare();check(duplicate==nil,'Duplicate registration was accepted')
put(PROFILE+0x40,C.word(C.ID))
local before=#writes;check(backend:restore()==false and #writes==before,'Equipped Shear was removed')
put(PROFILE+0x40,C.word(1000))
check(backend:restore()==true)
for offset,original in pairs(originals)do check(backend:span(ACCOUNT+offset,#original)==original,'Rollback differed from preimage')end
check(#backend.journal==0 and backend.owner==nil)
-- Inject a short write at every publication stage; the complete catalogue
-- must be byte-identical afterwards, including nonzero unused append slots.
for fail=1,6 do
    local b,m,w=fixture();local p=assert(b:prepare());m.fail=fail;m.partial=2
    check(b:apply(p)==false)
    check(#b.journal==0 and not b.uncertain,'A known partial write was not restored')
    for _,e in ipairs(p.edits)do check(b:span(ACCOUNT+e.offset,#e.before)==e.before)end
end
-- Chunking exercised at a real-sized category permutation (over 8 KiB).
local large,lmem,lwrites=fixture(2981)
local lp=assert(large:prepare());check(large:apply(lp)==true)
for _,w in ipairs(lwrites)do check(w.size<=4096)end
check(large:restore()==true)
-- Fail cleanup midway, then retry without mistaking the restored prefix for
-- a foreign writer or leaving the count published.
local b,m,w=fixture();local p=assert(b:prepare());assert(b:apply(p))
m.fail=#w+2;m.partial=2;check(b:restore()==false);check(m:u32(ACCOUNT+C.COUNT)==7)
m.fail=nil;check(b:restore()==true)
-- A foreign writer, refreshed account allocation, or unsupported build must
-- never receive a speculative restoration or registration.
local b,m,w,put,read,pointer=fixture();local p=assert(b:prepare());assert(b:apply(p))
put(ACCOUNT+C.CATEGORIES,'xxxx');local before=#w
check(b:restore()==false and #w==before)
put(GAME+0x347CEF8,pointer(ACCOUNT+0x100000));check(b:restore()==true and #w==before)
local b,m,w,put=fixture();put(GAME+0x136EC00,'xxxx');check(b:prepare()==nil and #w==0)
local b,m,w,put=fixture();put(ACCOUNT+0xDDCF8,C.word(7));local p,why,waiting=b:prepare()
check(p==nil and waiting==true and #w==0)
local b,m,w,put=fixture();local p=assert(b:prepare());put(ACCOUNT+C.COUNT,C.word(8))
check(b:apply(p)==false and #w==0)
local b,m,w=fixture();local p=assert(b:prepare());m.fail=1;m.partial=1;m.unknown=true
check(b:apply(p)==false and b.uncertain and b:restore()==false)
-- Full six-record tree plus independently allocated progression group.
local function grouped()
    local b,m,w,put,read,pointer=fixture()
    b.with_group=true
    local defaults=''
    for i=1,5 do defaults=defaults..C.word(i)..C.word(100+i)end
    put(0x350000000+6112,defaults..string.rep('\0',40))
    put(0x350000000+6112+0x12FC,C.word(0xD62DC83D))
    put(ACCOUNT+C.RECORDS+7*C.RECORD,string.rep('r',6*C.RECORD))
    put(ACCOUNT+C.INDEXES+7*C.INDEX,string.rep('i',6*C.INDEX))
    put(ACCOUNT+C.ORDER+8*4,string.rep('\0',20))
    local root,rows=0x360000000,0x361000000
    put(GAME+0x347CE78,pointer(root));put(root,C.word(2)..C.word(0)..pointer(rows)..C.word(1)..C.word(0))
    put(rows,string.rep('\0',112))
    put(ACCOUNT+0x4D4+24,string.rep('\0',24));put(ACCOUNT+0x1CD4,C.word(0))
    m.allocs=0
    function m:allocate(size)self.allocs=self.allocs+1;local p=0x370000000+self.allocs*65536;put(p,string.rep('a',size));return p end
    return b,m,w,put,read,root,rows
end
local b,m,w,put,read,root,rows=grouped();local p=assert(b:prepare())
check(m.allocs==4 and #p.edits==13)
assert(b:apply(p));check(m:u32(ACCOUNT+C.COUNT)==13 and m:u32(root+16)==2)
check(b:restore()==true and m:u32(root+16)==1 and m:ptr(root+8)==rows)
for failed=1,13 do
    local b,m,w,put,read=grouped();local p=assert(b:prepare());m.fail=failed;m.partial=2
    check(b:apply(p)==false and #b.journal==0 and not b.uncertain,'Group partial write rollback failed')
    for _,e in ipairs(p.edits)do check(b:span(e.address or ACCOUNT+e.offset,#e.before)==e.before)end
end
local b,m,w,put,read,root,rows=grouped();local p=assert(b:prepare());assert(b:apply(p))
put(rows,'xxxx');local count=#w;check(b:restore()==false and #w==count,'Foreign original group mutation must block cleanup')
return 'Catalogue transactions: '..checks..' checks passed'
