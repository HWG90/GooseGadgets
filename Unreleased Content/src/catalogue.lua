-- Native inventory layout reconstructed from game.dll 6AB3B43F:
-- 136EC00 constructs records/index rows; 136E6A0 builds category boundaries
-- and the category permutation. This planner performs no I/O or game calls.
local M = {ID=0x7DE53646, RESOURCE='48b9a4baa545317e', CAPACITY=4096,
    RECORD=0xB8, INDEX=24, COUNT=0x1CE0, RECORDS=0x1CE4,
    INDEXES=0xB9CE4, CATEGORIES=0xD1CE4, ORDER=0xD1D48}
M.RESOURCE=M.RESOURCE:gsub('%x%x',function(v)return string.char(tonumber(v,16))end)
function M.word(v)
    return string.char(v%256,math.floor(v/256)%256,math.floor(v/65536)%256,math.floor(v/16777216)%256)
end
function M.u32(s,o)
    o=o or 0
    if type(s)~='string' or #s<o+4 then return nil end
    local a,b,c,d=s:byte(o+1,o+4);return a+b*256+c*65536+d*16777216
end
local function need(ok,why) if not ok then error(why,0) end end
local function integer(n,max) return type(n)=='number' and n>=0 and n<=max and n==math.floor(n) end

local function product(a,b)
    local al,ah,bl,bh=a%65536,math.floor(a/65536),b%65536,math.floor(b/65536)
    return (al*bl+((al*bh+ah*bl)%65536)*65536)%4294967296
end
-- Native 1494350 / 14943C0; verified against two released inventory trees.
function M.child_id(stable,parent)
    local bit=require('bit')
    local k=product(stable,0x5BD1E995)
    k=product(bit.bxor(k,bit.rshift(k,24))%4294967296,0x5BD1E995)
    return bit.bxor(k,product(parent or M.ID,0x5BD1E995))%4294967296
end
function M.children(defaults)
    local out={}
    for i=0,9 do
        local slot,stable=M.u32(defaults,i*8),M.u32(defaults,i*8+4)
        if slot~=0 then out[#out+1]={id=M.child_id(stable),stable=stable}end
    end
    need(#out==5,'Native Shear defaults changed')
    return out
end
function M.plan(snapshot,children)
    children=children or {}
    local added=1+#children
    local n=snapshot.count
    need(integer(n,M.CAPACITY-1) and n>0,'Catalogue is empty or full')
    need(#snapshot.records==n*M.RECORD and #snapshot.indexes==n*M.INDEX,
        'Catalogue record/index span changed')
    need(n+added<=M.CAPACITY,'Catalogue is full')
    need(#snapshot.categories==100 and #snapshot.order==(n+added)*4,'Category span changed')
    need(#snapshot.unused_record==M.RECORD*added and #snapshot.unused_index==M.INDEX*added,'Append slots unreadable')
    local kinds,counts,seen,identities={}, {}, {},{}
    for i=0,23 do counts[i]=0 end
    for i=0,n-1 do
        local at,ix=i*M.RECORD,i*M.INDEX
        local kind=M.u32(snapshot.records,at+12)
        identities[M.u32(snapshot.records,at+4)]=true
        need(M.u32(snapshot.records,at)==i and M.u32(snapshot.indexes,ix)==i,
            'Native record/index correspondence changed')
        need(snapshot.records:sub(at+5,at+12)==snapshot.indexes:sub(ix+5,ix+12),
            'Native index identity changed')
        -- A pre-existing Shear belongs to the game or another provider. Never
        -- change its ownership or append a competing record.
        if M.u32(snapshot.records,at+4)==M.ID or M.u32(snapshot.records,at+8)==M.ID then
            return nil,'Shear already has an inventory record'
        end
        need(integer(kind,23),'Native inventory category changed')
        kinds[i]=kind;counts[kind]=counts[kind]+1
    end
    local boundary=0
    for kind=0,23 do
        need(M.u32(snapshot.categories,kind*4)==boundary,'Category boundary disagrees with records')
        boundary=boundary+counts[kind]
    end
    need(M.u32(snapshot.categories,96)==n,'Category sentinel disagrees with inventory count')
    local previous=0
    for i=0,n-1 do
        local id=M.u32(snapshot.order,i*4)
        need(integer(id,n-1) and not seen[id],'Category order is not a permutation')
        need(kinds[id]>=previous,'Category order is not grouped by native kind')
        previous=kinds[id];seen[id]=true
    end
    -- A root weapon has no prices, dependencies, parent, descendants, or
    -- customization grants. These are the native constructor defaults, with
    -- the real Shear ID and state=2/quantity=1 so the Armory can select it.
    local row=M.word(n)..M.word(M.ID)..M.word(M.ID)..M.word(1)..M.word(0)..M.word(2)
        ..M.word(0x7FFFFFFF)..string.rep('\0',M.RECORD-28-8)..M.word(1)..'\1\0\0\0'
    need(#row==M.RECORD,'Internal record size mismatch')
    local index=M.word(n)..M.word(M.ID)..M.word(M.ID)..string.rep('\0',8)..M.word(#children)
    for j,child in ipairs(children)do
        need(integer(child.id,4294967295) and child.id~=0 and not identities[child.id],'Attachment identity collides with an existing record')
        need(integer(child.stable,4294967295) and child.stable~=0,'Invalid attachment stable ID')
        identities[child.id]=true
        row=row..M.word(n+j)..M.word(child.id)..M.word(child.stable)..M.word(2)..M.word(0)..M.word(2)
            ..M.word(0x7FFFFFFF)..string.rep('\0',M.RECORD-28-8)..M.word(1)..'\1\0\0\0'
        index=index..M.word(n+j)..M.word(child.id)..M.word(child.stable)..M.word(j)..M.word(j)..M.word(0)
    end
    local ordered={}
    for kind=0,23 do
        local first,last=M.u32(snapshot.categories,kind*4),M.u32(snapshot.categories,(kind+1)*4)
        ordered[#ordered+1]=snapshot.order:sub(first*4+1,last*4)
        if kind==1 then ordered[#ordered+1]=M.word(n)end
        if kind==2 then for j=1,#children do ordered[#ordered+1]=M.word(n+j)end end
    end
    local order=table.concat(ordered)
    local categories={}
    for kind=0,24 do
        categories[#categories+1]=M.word(M.u32(snapshot.categories,kind*4)+(kind>1 and 1 or 0)+(kind>2 and #children or 0))
    end
    local function edit(offset,before,after)return {offset=offset,before=before,after=after}end
    -- Publish count LAST. All edits run in one game-thread callback. No engine
    -- functions are called between preparation and publication.
    return {
        edit(M.RECORDS+n*M.RECORD,snapshot.unused_record,row),
        edit(M.INDEXES+n*M.INDEX,snapshot.unused_index,index),
        edit(M.ORDER,snapshot.order,order),
        edit(M.CATEGORIES,snapshot.categories,table.concat(categories)),
        edit(M.COUNT,M.word(n),M.word(n+added)),
    }
end
return M
