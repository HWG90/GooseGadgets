-- Reproduce the captured animation_get_state reader using copied memory only.
-- Numeric state meanings remain hypotheses unless the exact resource matches.
local M={}
local EXPECTED_RESOURCE='\151\250\77\41\77\51\28\77' -- 4D1C334D294DFA97
local ANIM_GETTER='\72\139\129\120\1\0\0\195'
local RESOURCE_GETTER='\72\139\129\88\3\0\0\72\137\2\72\139\194\195'
local function uint(bytes,offset)
    offset=offset or 0
    local a,b,c,d=bytes:byte(offset+1,offset+4)
    assert(d,'Incomplete animation integer')
    return a+b*256+c*65536+d*16777216
end
local function pointer(bytes)
    local value=uint(bytes)+uint(bytes,4)*4294967296
    if value==0 then return 0 end
    assert(value>=65536 and value<140737488355328,'Animation state pointer unavailable')
    return value
end
local function offset(value)
    assert(value>=12 and value<=0x1000000,'Animation definition offset out of bounds')
    return value
end
local function resource_name(bytes)
    local result={}
    for i=8,1,-1 do result[#result+1]=string.format('%02X',bytes:byte(i))end
    return table.concat(result)
end
local function player(snapshot)
    return type(snapshot)=='table' and type(snapshot.player_identity)=='string' and snapshot.player_identity~=''
        and type(snapshot.body)=='number' and snapshot.body>0 and snapshot.body<0xFFFFFFFF
end
function M.new(backend)
    assert(type(backend)=='table','Animation backend required')
    local self,cache={},nil
    local function read(at,n)return backend:_read(at,n)end
    local function block(at,n)
        assert(n>0 and n<=8192,'Animation table read out of bounds')
        local out={}
        for i=0,n-1,1024 do out[#out+1]=read(at+i,math.min(1024,n-i))end
        return table.concat(out)
    end
    local function context(snapshot)
        return backend:_alignment_context({viewmodel=snapshot.body,avatar_owner=snapshot.avatar_owner,
            avatar_index=snapshot.avatar_index})
    end
    function self:sample(expected,layers)
        local ok,result=pcall(function()
            local s,why=expected,nil
            if not s then s,why=backend:player_snapshot()end
            assert(player(s),why or 'Animation local player unavailable')
            local c=context(s)
            local vt=backend:_ptr(c.object)
            assert(backend:_ptr(vt+0x1B0)==c.exe+0x2BD9C0
                and read(c.exe+0x2BD9C0,#ANIM_GETTER)==ANIM_GETTER,'Animation interface getter changed')
            assert(backend:_ptr(vt+0x1B8)==c.exe+0x2BD9D0
                and read(c.exe+0x2BD9D0,#RESOURCE_GETTER)==RESOURCE_GETTER,'Animation resource getter changed')
            local resource=read(c.object+0x358,8)
            local instance=backend:_ptr(c.object+0x178)
            local graph=backend:_ptr(instance+0x28)
            local header=read(graph,12)
            local count=uint(header,4)
            assert(count>0 and count<=32,'Animation layer count out of bounds')
            local table_offset=offset(uint(header,8))
            assert(table_offset<=0x10000,'Animation layer table out of bounds')
            local table_at=graph+table_offset
            local definitions=read(table_at+4,count*4)
            local active=backend:_ptr(instance+0x50)
            if not cache or cache.body~=c.object or cache.ref~=c.unit or cache.generation~=c.generation
                or cache.instance~=instance or cache.graph~=graph or cache.resource~=resource
                or cache.header~=header or cache.definitions~=definitions then
                cache={body=c.object,ref=c.unit,generation=c.generation,instance=instance,graph=graph,
                    resource=resource,header=header,definitions=definitions,maps={}}
            end
            layers=layers or {1,3,14}
            assert(type(layers)=='table' and #layers>0 and #layers<=32,'Animation layer selection unavailable')
            local states,unknown,observed,chosen={},{},{},{}
            for _,layer in ipairs(layers)do
                assert(type(layer)=='number' and layer==math.floor(layer) and layer>=1 and layer<=count
                    and not chosen[layer],'Animation layer selection out of bounds')
                chosen[layer]=true
                local def=table_at+offset(uint(definitions,(layer-1)*4))
                local n=backend:_u32(def+8)
                assert(n>0 and n<=2048,'Animation state count out of bounds')
                local map=cache.maps[layer]
                if not map or map.def~=def or map.count~=n then
                    local entries=block(def+12,n*4)
                    map={def=def,count=n,indices={}}
                    for state=0,n-1 do
                        local at=def+offset(uint(entries,state*4))
                        if map.indices[at]==nil then map.indices[at]=state end
                    end
                    cache.maps[layer]=map
                end
                local raw=read(active+(layer-1)*8,8)
                local p=pointer(raw)
                local index=p==0 and -1 or map.indices[p]
                states[layer]=index or 0
                if index==nil then unknown[#unknown+1]=layer end
                observed[#observed+1]={at=active+(layer-1)*8,raw=raw,def=def,count=n}
            end
            -- Neither an actor replacement nor an animation graph reload may
            -- turn a copied old state into the current player's action signal.
            local after,problem=backend:player_snapshot();assert(player(after),problem)
            assert(after.player_identity==s.player_identity and after.body==s.body,'Animation player changed during read')
            local final=context(after)
            for _,key in ipairs({'exe','unit','index','generation','object','registry','units','generations','owner','avatar_index'})do
                assert(final[key]==c[key],'Animation body generation changed during read')
            end
            assert(backend:_ptr(c.object+0x178)==instance and read(c.object+0x358,8)==resource
                and backend:_ptr(instance+0x28)==graph and backend:_ptr(instance+0x50)==active
                and read(graph,12)==header and read(table_at+4,count*4)==definitions,'Animation graph changed during read')
            for _,entry in ipairs(observed)do
                assert(read(entry.at,8)==entry.raw and backend:_u32(entry.def+8)==entry.count,
                    'Animation layer changed during read')
            end
            local matches=resource==EXPECTED_RESOURCE and count==31
            local sprint=matches and (states[1]==78 or states[1]==79 or states[3]==71) or false
            return {owner=s.player_identity,body=s.body,body_object=c.object,graph=graph,instance=instance,
                layer_count=count,resource=resource_name(resource),resource_match=matches,states=states,
                l1=states[1],l3=states[3],l10=states[10],l11=states[11],l14=states[14],unknown_layers=unknown,
                sprint_hypothesis=sprint,sprint_evidence='historical ActionCam state mapping; current action unverified'}
        end)
        if not ok then return nil,tostring(result)end
        return result
    end
    return self
end
return M
