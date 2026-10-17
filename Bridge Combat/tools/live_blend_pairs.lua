-- Review-only five-field blend-pair lease. Import/new never access the game.
-- No initializer, floats, clip ownership, graph reset, or full trailer writes.
local M = {}
local FIELDS = {
    {0x11C0, 0x6337D460}, {0x11C4, 0x2113EA75}, {0x11C8, 0x1F7FB073},
    {0x11E4, 0xF8B62730}, {0x11E8, 0xED5708CA},
}
local IDENTITY = {'game','stamp','world','pm','lc','avatar','di','def','pc','state','ep'}
local function word(bytes, at)
    at = at or 0
    if type(bytes) ~= 'string' or #bytes < at + 4 then return end
    local a,b,c,d = bytes:byte(at + 1, at + 4)
    return a+b*256+c*65536+d*16777216
end
local function packed(n)
    local out = {}
    for i=1,4 do out[i]=string.char(n%256);n=math.floor(n/256) end
    return table.concat(out)
end
local function attempt(fn)
    local ok,a,b = pcall(fn)
    if not ok then return nil,tostring(a) end
    return a,b
end
function M.new(backend)
    assert(type(backend)=='table','Blend-pair backend is required')
    for _,name in ipairs({'observe','unique','read','write'}) do
        assert(type(backend[name])=='function','Blend-pair backend missing '..name)
    end
    local self, captures = {journal=nil},setmetatable({}, {__mode='k'})
    local last = 'idle'
    local function read(at,size)
        local bytes = backend:read(at,size)
        assert(type(bytes)=='string' and #bytes==size,'Blend-pair memory is unreadable')
        return bytes
    end
    local function pointer(at)
        local bytes=read(at,8);local low,high=word(bytes),word(bytes,4)
        local value=low+high*4294967296
        assert(value>=65536 and value<2^47,'Blend-pair resource pointer is invalid')
        return value
    end
    -- Unknown/unreadable ownership retains cleanup. Only positively different
    -- roots, actor identities, or a retired descriptor retire an old lease.
    local function owns(s)
        local current,why=backend:observe()
        if type(current)~='table' then return nil,why or 'Actor observation is unavailable' end
        for _,name in ipairs(IDENTITY) do
            if current[name]~=nil and current[name]~=s.view[name] then
                return false,'Actor ownership changed: '..name
            end
        end
        local descriptor=backend:read(s.view.ep,24)
        if type(descriptor)~='string' or #descriptor~=24 then return nil,'Actor descriptor is unreadable' end
        if descriptor:sub(1,16)~=s.descriptor or descriptor:byte(21)%2~=1 then
            return false,'Actor descriptor was replaced or retired'
        end
        for _,name in ipairs(IDENTITY) do
            if current[name]==nil then return nil,'Actor ownership is unavailable: '..name end
        end
        local unique,reason=backend:unique(current)
        if unique~=true then return nil,reason or 'Actor definition ownership is unproven' end
        return true,current
    end
    local function source(s)
        assert(pointer(s.view.world+0xF12E30)==s.table,'Base resource root changed')
        assert(read(s.table+s.slot*16,16)==s.slot_bytes,'Base descriptor row changed')
        assert(read(s.base,0x1210)==s.source,'Base resource image changed')
        assert(read(s.view.ep,16)==s.descriptor,'Actor descriptor changed')
    end
    local function applying(s)
        local valid,current=owns(s);assert(valid==true,current)
        assert(current.scene==3,'Blend-pair test requires the ship scene')
        local context=word(read(s.view.pc+0xFD0,4))
        assert(math.floor(context/2)%4==1,'Blend-pair test requires combat control context')
        source(s)
        assert(read(s.view.def,0x1160)==s.source:sub(1,0x1160),'Owned normal profile body differs')
        return true
    end
    local function partial(before,after,count)
        if type(count)=='number' and count==math.floor(count) and count>0 and count<4 then
            return after:sub(1,count)..before:sub(count+1)
        end
    end
    function self:capture()
        if self.journal then return nil,'Blend-pair cleanup is pending' end
        return attempt(function()
            local view,why=backend:observe();assert(type(view)=='table' and view.avatar,why or 'Local actor is absent')
            for _,name in ipairs(IDENTITY) do assert(view[name]~=nil,'Actor identity missing: '..name) end
            assert(view.stamp==0x6AB3B43F,'Unsupported blend-pair game build')
            local s={view={},fields={}}
            for _,name in ipairs(IDENTITY) do s.view[name]=view[name] end
            s.descriptor=read(view.ep,24):sub(1,16)
            s.table=pointer(view.world+0xF12E30)
            local slots=read(s.table,408*16)
            for i=0,407 do
                local row=slots:sub(i*16+1,i*16+16)
                if row:sub(1,8)==s.descriptor:sub(1,8) then
                    assert(s.slot==nil,'Base resource descriptor is ambiguous')
                    local index=word(row,8);assert(index<408,'Base definition index is invalid')
                    s.slot,s.slot_bytes,s.base=i,row,s.table+0x1980+index*0x1210
                end
            end
            assert(s.base,'Base locomotion definition is absent')
            assert(s.base~=view.def,'Owned definition aliases the base resource')
            s.source=read(s.base,0x1210)
            for _,spec in ipairs(FIELDS) do
                local after=packed(spec[2])
                assert(s.source:sub(spec[1]+1,spec[1]+4)==after,'Base blend-pair target differs')
                s.fields[#s.fields+1]={offset=spec[1],before=read(view.def+spec[1],4),after=after}
            end
            applying(s)
            local result={base=s.base,definition=view.def,avatar=view.avatar,count=#s.fields}
            captures[result]=s;last='captured';return result
        end)
    end
    function self:restore()
        local journal=self.journal
        if not journal then return true end
        local pending,reason=0,nil
        for i=#journal.entries,1,-1 do
            local entry=journal.entries[i]
            if entry.pending then
                local called,valid,why=pcall(owns,journal.snapshot)
                if called and valid==false then
                    for _,row in ipairs(journal.entries) do row.pending=false end
                    last='retired';self.journal=nil;return true,why
                elseif not called or valid~=true then
                    reason=called and why or tostring(valid)
                else
                  local serviced,problem=pcall(function()
                    local current=backend:read(entry.address,4)
                    if current==entry.before then entry.pending=false
                    elseif type(current)=='string' and #current==4 and current~=entry.after then
                        entry.pending=false -- Preserve a later writer's value.
                    elseif current==entry.after then
                        -- Revalidate immediately before the bounded four-byte write.
                        local ready,problem=owns(journal.snapshot)
                        if ready==true and backend:read(entry.address,4)==entry.after then
                            local previous=entry.after
                            local wrote,ok,detail,count=pcall(backend.write,backend,entry.address,entry.before)
                            local checked,same=pcall(owns,journal.snapshot)
                            if checked and same==true then
                                local actual=backend:read(entry.address,4)
                                if actual==entry.before then entry.pending=false
                                else
                                    local prefix=wrote and partial(previous,entry.before,count)
                                    if prefix and actual==prefix then entry.after=prefix end
                                    reason=wrote and(detail or 'Blend-pair restore readback is pending')or tostring(ok)
                                end
                            else reason='Blend-pair restore ownership readback is pending' end
                        else reason=problem or 'Blend-pair value changed before restoration' end
                    else reason='Blend-pair restore field is unreadable' end
                  end)
                  if not serviced then reason=tostring(problem) end
                end
                if entry.pending then pending=pending+1 end
            end
        end
        if pending==0 then self.journal=nil;last='restored';return true end
        last='cleanup pending';return false,reason or last
    end
    function self:apply(snapshot)
        if self.journal then return false,'Blend-pair cleanup is pending' end
        local s=captures[snapshot]
        if not s then return false,'A capture from this blend-pair owner is required' end
        local ok,why=attempt(function()
            applying(s)
            for _,field in ipairs(s.fields) do
                assert(read(s.view.def+field.offset,4)==field.before,'Blend-pair source changed before apply')
            end
            self.journal={snapshot=s,entries={}}
            for _,field in ipairs(s.fields) do
                if field.before~=field.after then
                    applying(s)
                    local address=s.view.def+field.offset
                    assert(read(address,4)==field.before,'Blend-pair field changed before write')
                    local entry={address=address,before=field.before,after=field.after,pending=true}
                    self.journal.entries[#self.journal.entries+1]=entry -- Intent precedes host mutation.
                    local wrote,detail,count=backend:write(address,field.after)
                    local same,problem=owns(s);assert(same==true,problem)
                    local prefix=partial(field.before,field.after,count)
                    if prefix and read(address,4)==prefix then entry.after=prefix end
                    source(s)
                    assert(wrote==true,detail or 'Blend-pair write was not acknowledged')
                    assert(read(address,4)==field.after,'Blend-pair write readback differs')
                end
            end
            last='applied';return true
        end)
        if ok then captures[snapshot]=nil;return true end
        if self.journal then self:restore() end
        last=self.journal and 'cleanup pending' or 'apply refused'
        return false,why
    end
    function self:status()
        local pending,total=0,0
        if self.journal then for _,entry in ipairs(self.journal.entries) do
            total=total+1;if entry.pending then pending=pending+1 end
        end end
        return {state=last,pending=pending,total=total,active=self.journal~=nil}
    end
    return self
end
return M
