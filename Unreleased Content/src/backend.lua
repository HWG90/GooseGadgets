local C=mod.require('src/catalogue.lua')
local Memory=mod.require('src/memory.lua')
local Custom=mod.require('src/customization.lua')
local Group=mod.require('src/group.lua')
local M={}
local FINGERPRINTS={
    {0x11E7810,'488b05d1f11302448bc9468b8488401b00004585c0742846'},
    {0x136EC00,'48895c240848896c2410488974241848897c242041554156'},
    {0x136E6A0,'4c8bdc53555641554881eca8000000488b055ad92c014833'},
}
for _,p in ipairs(FINGERPRINTS)do p.bytes=p[2]:gsub('%x%x',function(v)return string.char(tonumber(v,16))end)end
function M.new(memory,with_group)return setmetatable({mem=memory or Memory.new(),journal={},with_group=with_group}, {__index=M})end
function M:armory_closed(game)
    local root=self.mem:ptr(game+0x347CE28)
    local raw=root and self.mem:read(root+0x4294,32)
    if not raw then return false,'Waiting for the native menu manager' end
    local current,depth=C.u32(raw),C.u32(raw,28)
    if current>52 or depth>5 then return false,'Native menu stack layout changed' end
    if current==5 then return false,'Close the Armory before changing its catalogue' end
    for i=0,depth-1 do
        local id=C.u32(raw,8+i*4)
        if id==5 then return false,'Close the Armory before changing its catalogue' end
        if id<1 or id>52 then return false,'Native menu stack layout changed' end
    end
    if (depth==0 and current~=0) or (depth>0 and C.u32(raw,8+(depth-1)*4)~=current) then
        return false,'Native menu stack is transitioning'
    end
    return true
end
function M:span(address,size)
    local chunks={}
    for at=0,size-1,8192 do
        local b,why=self.mem:read(address+at,math.min(8192,size-at))
        if not b then return nil,why end
        chunks[#chunks+1]=b
    end
    return table.concat(chunks)
end
function M:context()
    local game,why=self.mem:_module();if not game then return nil,why end
    for _,p in ipairs(FINGERPRINTS)do
        if self.mem:read(game+p[1],#p.bytes)~=p.bytes then return nil,'Cut-content native fingerprint changed' end
    end
    local account=self.mem:ptr(game+0x347CEF8)
    if not account or self.mem:u32(account+0xDDCF8)~=12 then return nil,'Waiting for the completed inventory catalogue',true end
    local count=self.mem:u32(account+C.COUNT)
    if not count or count<1 or count>=C.CAPACITY then return nil,'Inventory count is unsupported' end
    local weapons=self.mem:ptr(game+0x33269E8)
    if not weapons then return nil,'Waiting for the weapon catalogue',true end
    -- The exact native slot, resource and primary classification are checked;
    -- a known timestamp alone is insufficient evidence for a writable layout.
    local row=self.mem:read(weapons+42*32,32)
    if not row or C.u32(row)~=C.ID or row:sub(9,16)~=C.RESOURCE or C.u32(row,16)~=1
        or row:sub(5,8)~=string.rep('\0',4) or row:sub(21)~=string.rep('\0',12) then
        return nil,'The native Shear weapon definition changed'
    end
    return {game=game,account=account,count=count,weapons=weapons}
end
function M:same(ctx)
    return self.mem:ptr(ctx.game+0x347CEF8)==ctx.account
        and self.mem:ptr(ctx.game+0x33269E8)==ctx.weapons
        and self.mem:u32(ctx.account+C.COUNT)==ctx.count
        and self.mem:u32(ctx.account+0xDDCF8)==12
end
function M:prepare()
    local ctx,why,waiting=self:context();if not ctx then return nil,why,waiting end
    local closed,problem=self:armory_closed(ctx.game)
    if not closed then return nil,problem,true end
    local a,n=ctx.account,ctx.count
    local custom,custom_problem,definition,defaults=self:customization_plan(ctx)
    if not custom then return nil,custom_problem end
    local children=self.with_group and C.children(defaults) or {}
    local added=1+#children
    local snapshot={count=n,records=self:span(a+C.RECORDS,n*C.RECORD),
        indexes=self:span(a+C.INDEXES,n*C.INDEX),categories=self.mem:read(a+C.CATEGORIES,100),
        order=self:span(a+C.ORDER,(n+added)*4),unused_record=self:span(a+C.RECORDS+n*C.RECORD,C.RECORD*added),
        unused_index=self:span(a+C.INDEXES+n*C.INDEX,C.INDEX*added)}
    for _,key in ipairs({'records','indexes','categories','order','unused_record','unused_index'})do
        if not snapshot[key] then return nil,'Inventory snapshot is unreadable' end
    end
    if not self:same(ctx)then return nil,'Inventory changed during preparation' end
    local ok,plan,problem=pcall(C.plan,snapshot,children)
    if not ok then return nil,tostring(plan) end
    if not plan then return nil,problem end
    if custom~=true then table.insert(plan,#plan,custom)end
    if self.with_group then
        local edits,problem,waiting=Group.plan(self,ctx,definition,defaults)
        if not edits then return nil,problem,waiting end
        for _,edit in ipairs(edits)do table.insert(plan,#plan,edit)end
    end
    return {context=ctx,edits=plan}
end
function M:customization_plan(ctx)
    local world=self.mem:ptr(ctx.game+0x346BF98)
    local base=world and self.mem:ptr(world+0xF12CF0)
    local expected='d0f3a8eb4c444c4401000000d0f3a8ebe05d0e000100000000000000'
    expected=expected:gsub('%x%x',function(v)return string.char(tonumber(v,16))end)
    if not base or self.mem:read(base-28,28)~=expected then return nil,'Native customization schema changed' end
    local indexes=self:span(base,382*16)
    if not indexes then return nil,'Native customization index is unreadable' end
    local record,owners
    for i=0,381 do
        if indexes:sub(i*16+1,i*16+8)==C.RESOURCE then
            if record then return nil,'Native customization identity is ambiguous' end
            record=C.u32(indexes,i*16+8)
        end
    end
    if not record or record>=192 then return nil,'Shear customization defaults are unavailable' end
    owners=0
    for i=0,381 do
        if indexes:sub(i*16+1,i*16+8)~=string.rep('\0',8) and C.u32(indexes,i*16+8)==record then owners=owners+1 end
    end
    if owners~=1 then return nil,'Shear customization definition has shared owners' end
    local definition=base+6112+record*4872
    local defaults=self.mem:read(definition,80)
    if not defaults then return nil,'Shear customization defaults are unreadable' end
    local raw=self:span(ctx.account+Custom.BASE,Custom.SIZE*Custom.CAPACITY)
    if not raw then return nil,'Per-weapon customization state is unreadable' end
    local empty
    for i=0,Custom.CAPACITY-1 do
        local id=C.u32(raw,i*Custom.SIZE)
        if id==C.ID then return true,nil,definition,defaults end -- preserve an existing provider/save
        if id==0 and empty==nil then empty=i end
    end
    if empty==nil then return nil,'Per-weapon customization table is full' end
    local ok,bytes=pcall(Custom.record,C,defaults)
    if not ok then return nil,tostring(bytes)end
    local offset=empty*Custom.SIZE
    return {offset=Custom.BASE+offset,before=raw:sub(offset+1,offset+Custom.SIZE),after=bytes},nil,definition,defaults
end
function M:apply(plan)
    if #self.journal>0 then return false,'An earlier registration still owns bytes' end
    local ctx=plan.context
    local closed,problem=self:armory_closed(ctx.game)
    if not closed then return false,problem end
    if not self:same(ctx)then return false,'Inventory changed before registration' end
    if ctx.group_root and (self.mem:ptr(ctx.game+0x347CE78)~=ctx.group_root
        or self:span(ctx.group_base,#ctx.group_rows)~=ctx.group_rows)then
        return false,'Native progression settings changed before registration'
    end
    for _,edit in ipairs(plan.edits)do
        if self:span(edit.address or ctx.account+edit.offset,#edit.before)~=edit.before then
            return false,'Registration preimage changed'
        end
    end
    self.owner=ctx
    for _,edit in ipairs(plan.edits)do
        for at=0,#edit.after-1,4096 do
            local after=edit.after:sub(at+1,at+4096)
            local before=edit.before:sub(at+1,at+#after)
            local address=(edit.address or ctx.account+edit.offset)+at
            local called,ok,why,copied=pcall(self.mem.copy,self.mem,address,after)
            if not called then ok,why,copied=false,tostring(ok),nil end
            if type(copied)=='number' and copied>=0 and copied<=#after and copied==math.floor(copied) then
                if copied>0 then self.journal[#self.journal+1]={address=address,before=before:sub(1,copied),after=after:sub(1,copied)}end
            else
                self.uncertain=true
            end
            if ok~=true or copied~=#after then
                local restored,problem=self:restore(true)
                return false,tostring(why or 'Short registration write')..(restored and '; original bytes restored' or '; '..tostring(problem))
            end
        end
    end
    self.applied=true
    return true
end
function M:in_use()
    local g=self.owner.game
    -- Native loadout records and the saved loadout are read-only here. Never
    -- remove a selectable record while any local primary still references it.
    local manager=self.mem:ptr(g+0x347CE50)
    local profile=self.mem:ptr(g+0x347CDD8)
    if not manager or not profile then return nil,'Loadout ownership is unavailable' end
    local n=self.mem:u32(manager+0x2D200)
    if not n or n>16 then return nil,'Loadout bounds changed' end
    for i=0,n-1 do
        local id=self.mem:u32(manager+i*0x1690+0x38)
        if not id then return nil,'Loadout is unreadable' end
        if id==C.ID then return true,'Select another primary before disabling Unreleased Content' end
    end
    local saved=self.mem:u32(profile+0x40)
    if not saved then return nil,'Saved primary is unreadable' end
    if saved==C.ID then return true,'Select another primary before disabling Unreleased Content' end
    return false
end
function M:restore(failed_apply)
    if #self.journal==0 and not self.uncertain then self.owner=nil;return true end
    if self.uncertain then return false,'An unacknowledged write requires a game restart' end
    local ctx=self.owner
    local game=self.mem:_module()
    if game~=ctx.game then return false,'Game module changed; original allocation was not written' end
    if self.mem:ptr(game+0x347CEF8)~=ctx.account then
        -- The old allocation may have been recycled. It must never be restored.
        self.journal={};self.owner=nil;self.applied=false;return true
    end
    if self.applied and not failed_apply then
        local closed,problem=self:armory_closed(game);if not closed then return false,problem end
        local used,why=self:in_use();if used~=false then return false,why end
    end
    if ctx.group_root and (self.mem:ptr(game+0x347CE78)~=ctx.group_root
        or self:span(ctx.group_base,#ctx.group_rows)~=ctx.group_rows)then
        return false,'Progression settings ownership changed; cleanup retained ownership'
    end
    -- Check the whole transaction BEFORE restoring any part. Reverse order
    -- unpublishes count before reverting order/boundaries and append slots.
    for _,piece in ipairs(self.journal)do
        if self.mem:read(piece.address,#piece.after)~=piece.after then return false,'Catalogue bytes changed; cleanup retained ownership' end
    end
    for i=#self.journal,1,-1 do
        local piece=self.journal[i]
        local ok,why,copied=self.mem:copy(piece.address,piece.before)
        if not ok or copied~=#piece.before then
            -- A partial restore remains owned; update the expected bytes to
            -- the exact acknowledged restored prefix before retrying cleanup.
            if type(copied)=='number' and copied>=0 and copied<=#piece.before then
                piece.after=piece.before:sub(1,copied)..piece.after:sub(copied+1)
            else self.uncertain=true end
            return false,why or 'Cleanup write was not acknowledged'
        end
        self.journal[i]=nil
    end
    self.applied=false;self.owner=nil;return true
end
return M
