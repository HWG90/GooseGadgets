-- Read-only graph/clip footprint for a possible whole-animator reconstruction.
-- Import/new perform no reads. No FFI, event dispatch, setters, or memory writes.
local M={}
local LIMIT,MAX_BYTES=2^47,8*1024*1024
local EVENTS={
    [0xF2F926AB]='stand',[0xB65540AB]='crouch',[0x13AEB16B]='prone',
    [0x17CBE1C0]='weapon_out',[0x712947D6]='bridge',
}
local TYPE='931e336d7646cc26'
-- EXE 6AB382E4,552470: index highbit selects the conditional path. Row mode6
-- takes55278E->5529D8->54B490 directly when extra is0. Its distinct reentry
-- boolean is not interpreted here; only the authored target footprint is sealed.
local MODE6_PROOF='6AB382E4:552470'
local function integer(n,max)return type(n)=='number'and n==math.floor(n)and n>=0 and n<=max end
local function u32(b,off)
    off=off or 0;local a,c,d,e=b:byte(off+1,off+4)
    assert(e,'Manifest integer is truncated');return a+c*256+d*65536+e*16777216
end
local function pointer(b,off)
    off=off or 0;local n=u32(b,off)+u32(b,off+4)*4294967296
    assert(n>=65536 and n<LIMIT,'Manifest pointer is invalid');return n
end
local function hex(b)return(b:gsub('.',function(c)return('%02x'):format(c:byte())end))end
local function attempt(fn)local ok,a,b=pcall(fn);if not ok then return nil,tostring(a)end;return a,b end
function M.new(io)
    assert(type(io)=='table'and type(io.read)=='function','Read-only manifest IO is required')
    local self={};local captured=setmetatable({}, {__mode='k'})
    local function reader()
        local used=0
        return function(at,n)
            assert(integer(at,LIMIT-1)and at>=65536 and integer(n,65536)and n>0
                and at+n<LIMIT,'Manifest read bounds differ')
            used=used+n;assert(used<=MAX_BYTES,'Manifest read budget exceeds8MiB')
            local b,why=io.read(at,n)
            assert(type(b)=='string'and #b==n,why or 'Manifest memory is unreadable')
            return b
        end,function()return used end
    end
    local function recheck(data,read)
        for key,value in pairs(data.labels)do
            assert(data.manifest[key]==value,'Manifest diagnostic/approval label changed')
        end
        if not data.labels.events_checked then
            assert(#data.manifest.edges==0,'Root-only diagnostic cannot approve event edges')
        end
        for _,row in ipairs(data.samples)do
            assert(read(row.at,#row.bytes)==row.bytes,'Manifest definition or actor identity changed')
        end
        return true
    end
    local function capture(s,roots_only)
        return attempt(function()
            assert(type(s)=='table'and s.game and s.exe and s.unit and s.animator and s.graph
                and s.states and integer(s.reference,0xFFFFFFFE)and s.reference>0,
                'A validated native animation snapshot is required')
            assert(type(s.state_bytes)=='string'and #s.state_bytes==31*8,'Manifest requires all31 captured states')
            local read,used=reader();local samples,seen_samples={},{}
            local function sample(at,n)
                local b=read(at,n);local key=string.format('%.0f:%d',at,n)
                if seen_samples[key]then assert(seen_samples[key].bytes==b,'Manifest changed during capture')
                else local row={at=at,bytes=b};seen_samples[key]=row;samples[#samples+1]=row end
                return b
            end
            assert(u32(sample(s.unit+8,4))==s.reference,'Manifest Unit reference changed')
            assert(pointer(sample(s.unit+0x178,8))==s.animator
                and pointer(sample(s.animator+0x28,8))==s.graph
                and pointer(sample(s.animator+0x50,8))==s.states,'Manifest animator roots changed')
            local header=sample(s.graph,0x30)
            assert(u32(header,4)==31,'Manifest graph must have31 layers')
            if s.graph_header then assert(header==s.graph_header,'Manifest graph header changed')end
            assert(sample(s.states,31*8)==s.state_bytes,'Manifest current states changed')
            local offset=u32(header,8)
            assert(offset>0 and offset<0x1000000,'Manifest layer-table offset differs')
            local table_at=s.graph+offset;local layer_table=sample(table_at,4+31*4)
            local result={version=1,graph=s.graph,unit=s.unit,reference=s.reference,layers={},clips={},edges={},
                scope=roots_only and 'current-default-roots-only'or'unconditional-event-footprint',
                complete=not roots_only,reset_approved=false,events_checked=not roots_only}
            local queue,clip_seen={},{};local visits=0
            local function enqueue(layer,index)
                assert(integer(index,layer.count-1),'Manifest transition target is outside the authored layer')
                local address=layer.addresses[index]
                assert(layer.address_counts[address]==1,'Manifest selected/default/reachable definition is aliased')
                if not layer.seen[index]then
                    layer.seen[index]=true;queue[#queue+1]={layer=layer,index=index,address=address}
                end
            end
            for index=0,30 do
                local rel=u32(layer_table,4+index*4)
                assert(rel>0 and rel<0x1000000,'Manifest layer offset differs')
                local at=table_at+rel;local lh=sample(at,12)
                local default,count=u32(lh,4),u32(lh,8)
                assert(count>0 and count<=4096 and default<count,'Manifest layer default/count differs')
                local defs=sample(at+12,count*4)
                local layer={index=index,sdk_layer=index+1,default=default,count=count,addresses={},address_counts={},seen={},states={}}
                local current=pointer(s.state_bytes,index*8)
                for state=0,count-1 do
                    local relative=u32(defs,state*4)
                    assert(relative>0 and relative<0x1000000,'Manifest state offset differs')
                    local address=at+relative;layer.addresses[state]=address
                    layer.address_counts[address]=(layer.address_counts[address]or 0)+1
                    if address==current then
                        assert(layer.current==nil,'Manifest current state has multiple authored definitions')
                        layer.current=state
                    end
                end
                assert(layer.current~=nil,'Manifest current state is not an authored definition')
                result.layers[#result.layers+1]=layer
                enqueue(layer,layer.current);enqueue(layer,layer.default)
            end
            local cursor=1
            while cursor<=#queue do
                local item=queue[cursor];cursor=cursor+1;visits=visits+1
                assert(visits<=4096,'Manifest reachable-state bound exceeded')
                local layer,index,at=item.layer,item.index,item.address
                local state=sample(at,0xA8)
                local clip_count,clip_offset=u32(state,0xC),u32(state,0x10)
                assert(clip_count<=256 and clip_offset<0x1000000,'Manifest clip table bounds differ')
                if clip_count>0 then
                    assert(clip_offset>0,'Manifest clip table is absent')
                    local ids=sample(at+clip_offset,clip_count*8)
                    for clip=0,clip_count-1 do
                        local bytes=ids:sub(clip*8+1,clip*8+8)
                        assert(bytes~=string.rep('\0',8),'Manifest clip name is empty')
                        if not clip_seen[bytes]then
                            assert(#result.clips<512,'Manifest exact clip union exceeds512')
                            clip_seen[bytes]=true;result.clips[#result.clips+1]={bytes=bytes,hex=hex(bytes:reverse()),type=TYPE}
                        end
                    end
                end
                -- Roots are a resource-owner diagnostic, not a weaker reset preflight.
                -- Do not inspect/approve any event transition in this mode.
                if not roots_only then
                local event_count,event_offset=u32(state,0x28),u32(state,0x2C)
                assert(event_count<=4096 and event_offset<0x1000000,'Manifest event table bounds differ')
                local matches={}
                if event_count>0 then
                    assert(event_offset>0,'Manifest event table is absent')
                    local events=sample(at+event_offset,event_count*8)
                    for event=0,event_count-1 do
                        local hash,transition=u32(events,event*8),u32(events,event*8+4)
                        if EVENTS[hash]then
                            local where=string.format('SDK%d state%d %s(%08x)',layer.sdk_layer,index,EVENTS[hash],hash)
                            assert(not matches[hash],'Manifest requested event mapping is ambiguous: '..where)
                            assert(transition<0x80000000,'Manifest requested event is conditional and unproved: '
                                ..where..string.format(' transition=%08x',transition))
                            matches[hash]=transition
                        end
                    end
                end
                if next(matches)then
                    local target_count,target_offset=u32(state,0x30),u32(state,0x34)
                    assert(target_count>0 and target_count<=4096 and target_offset>0
                        and target_offset<0x1000000,'Manifest transition-table bounds differ')
                    local targets=sample(at+target_offset,target_count*16)
                    for hash,transition in pairs(matches)do
                        local where=string.format('SDK%d state%d %s(%08x)',layer.sdk_layer,index,EVENTS[hash],hash)
                        assert(transition<target_count,'Manifest event transition index is invalid: '..where)
                        local off=transition*16
                        local target,blend,flags,extra=u32(targets,off),u32(targets,off+4),u32(targets,off+8),u32(targets,off+12)
                        assert((flags==0 or flags==6)and extra==0,'Manifest transition flags/extra are unproved: '..where
                            ..string.format(' flags=%08x extra=%08x',flags,extra))
                        assert(blend<0x80000000 and math.floor(blend/8388608)%256~=255,
                            'Manifest transition blend is not finite and nonnegative: '..where)
                        assert(target<layer.count,'Manifest target leaves authored layer: '..where)
                        enqueue(layer,target)
                        result.edges[#result.edges+1]={layer=layer.index,from=index,target=target,
                            event=EVENTS[hash],hash=('%08x'):format(hash),blend_bits=blend,mode=flags,
                            mode_proof=flags==6 and MODE6_PROOF or nil,
                            reentry_semantics=flags==6 and 'unresolved-native-distinct-boolean'or nil}
                    end
                end
                end
                layer.states[#layer.states+1]=index
            end
            for _,layer in ipairs(result.layers)do
                layer.addresses,layer.address_counts,layer.seen=nil,nil,nil
                table.sort(layer.states)
            end
            table.sort(result.clips,function(a,b)return a.hex<b.hex end)
            local private={samples=samples,manifest=result,labels={scope=result.scope,
                complete=result.complete,reset_approved=false,events_checked=result.events_checked}}
            recheck(private,read)
            result.layer_count,result.state_count,result.clip_count=31,visits,#result.clips
            result.sample_count,result.read_bytes=#samples,used()
            captured[result]=private;return result
        end)
    end
    function self:capture(s)return capture(s,false)end
    -- This intentionally remains incomplete even if there are no authored events.
    -- Callers must not substitute it for capture() or a native/resource preflight.
    function self:roots(s)return capture(s,true)end
    function self:recheck(manifest)
        local ok,why=attempt(function()
            local data=assert(captured[manifest],'Manifest was not captured by this reader')
            local read=reader();return recheck(data,read)
        end)
        return ok==true,why
    end
    return self
end
return M
