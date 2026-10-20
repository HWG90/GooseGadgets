-- Native group/level/reward formats from 13694C0, 136A1E0, 136CE70 and
-- 136D080. The group is reconstructed locally from the Shear's own defaults;
-- its unpublished server XP tree is NOT available in the local game files.
local M={KEY=0xD62DC83D, STRIDE=112, LEVEL=0x848, REWARD=48}
function M.pointer(C,v)return C.word(v%4294967296)..C.word(math.floor(v/4294967296))end
local function replace(s,at,b)return s:sub(1,at)..b..s:sub(at+#b+1)end
function M.build(C,index,defaults,levels,rewards,grants)
    assert(index>=0 and index<256 and index%1==0,'Native group capacity changed')
    local entries,given,seen={},{},{}
    for i=0,9 do
        local slot,id=C.u32(defaults,i*8),C.u32(defaults,i*8+4)
        if slot~=0 then
            assert(id~=0 and slot<=10 and not seen[id],'Invalid native Shear defaults')
            seen[id]=true
            -- Native unlockable item: real attachment ID, quantity=1, no price.
            entries[#entries+1]=C.word(C.child_id(id))..C.word(1)..string.rep('\0',40)
            given[#given+1]=C.word(1)..C.word(C.child_id(id))..C.word(1)
        end
    end
    assert(#entries==5,'Native Shear default attachment count changed')
    local level=string.rep('\0',M.LEVEL)
    level=replace(level,0,C.word(1)..C.word(0)..C.word(3))
    level=replace(level,0x828,M.pointer(C,grants)..C.word(#given))
    level=replace(level,0x838,M.pointer(C,rewards)..C.word(#entries))
    local row=string.rep('\0',M.STRIDE)
    row=replace(row,0,C.word(M.KEY)..C.word(index)..C.word(2)..C.word(C.ID))
    row=replace(row,0x5C,C.word(1)..M.pointer(C,levels)..C.word(1))
    return row,level,table.concat(entries),table.concat(given)
end
function M.plan(backend,ctx,definition,defaults)
    local C=mod.require('src/catalogue.lua')
    local mem=backend.mem
    if mem:u32(definition+0x12FC)~=M.KEY then return nil,'Shear customization group key changed' end
    local root=mem:ptr(ctx.game+0x347CE78)
    if not root or mem:u32(root)~=2 then return nil,'Waiting for native progression settings',true end
    local n,base=mem:u32(root+16),mem:ptr(root+8)
    if not n or n<1 or n>=256 or not base then return nil,'Native progression group bounds changed' end
    local rows=backend:span(base,n*M.STRIDE)
    if not rows then return nil,'Native progression groups are unreadable' end
    for i=0,n-1 do
        if C.u32(rows,i*M.STRIDE)==M.KEY then return {},nil end
        if C.u32(rows,i*M.STRIDE+4)~=i then return nil,'Native progression group indexes changed' end
    end
    -- Complete all validation BEFORE allocating or publishing any new data.
    local valid,problem=pcall(M.build,C,n,defaults,65536,65536,65536)
    if not valid then return nil,tostring(problem)end
    -- Native 1038CCE/13696BE: profile group ID includes the definition index,
    -- followed by level/xp and their previous values. It is NOT a compact list.
    local profile=ctx.account+0x4D4+n*24
    local state=mem:read(profile,24)
    local owned=mem:u32(ctx.account+0x1CD4)
    if not state or state~=string.rep('\0',24) or not owned or owned>=256 then
        return nil,'The new progression state slot is already owned or unreadable'
    end
    local addresses={}
    for _,size in ipairs({(n+1)*M.STRIDE,M.LEVEL,5*M.REWARD,5*12})do
        local p,why=mem:allocate(size);if not p then return nil,why end
        addresses[#addresses+1]=p
    end
    local row,level,rewards,grants=M.build(C,n,defaults,addresses[2],addresses[3],addresses[4])
    local edits={}
    for i,bytes in ipairs({rows..row,level,rewards,grants})do
        local before=backend:span(addresses[i],#bytes)
        if not before then return nil,'Native group allocation is unreadable' end
        edits[#edits+1]={address=addresses[i],before=before,after=bytes}
    end
    edits[#edits+1]={address=profile,before=state,
        after=C.word(M.KEY)..C.word(n)..C.word(1)..C.word(0)..C.word(1)..C.word(0)}
    edits[#edits+1]={address=ctx.account+0x1CD4,before=C.word(owned),after=C.word(owned+1)}
    local before=mem:read(root+8,16)
    if not before or mem:ptr(root+8)~=base or mem:u32(root+16)~=n then return nil,'Progression table changed during preparation' end
    edits[#edits+1]={address=root+8,before=before,
        after=M.pointer(C,addresses[1])..C.word(n+1)..before:sub(13,16)}
    ctx.group_root,ctx.group_base,ctx.group_rows=root,base,rows
    return edits
end
return M
