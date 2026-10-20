-- Placement belongs on the linked render skeleton, not the animated body or
-- mesh anchor. Mesh skin bindings select these nodes directly (512b80/5b2990).
local M={}
local function close(a,b)
    return a and b and math.abs(a[1]-b[1])+math.abs(a[2]-b[2])+math.abs(a[3]-b[3])<.00001
end
local function sameq(a,b)
    if not a or not b then return false end
    local dot=0;for i=1,4 do dot=dot+a[i]*b[i]end
    return math.abs(math.abs(dot)-1)<.000001
end
function M.new(b,sr,cal,parts)
    local U,V,Q,A=sr.Unit,sr.Vector3,sr.Quaternion,sr.Matrix4x4
    local ffi=require('ffi')
    if b._alignment_executable then
        local exe=b:_alignment_executable()
        assert(b:_read(exe+0x512b80,16)=='\x40\x55\x57\x48\x8d\x6c\x24\xa8\x48\x81\xec\x58\x01\x00\x00\x48','Skinning palette builder changed')
    end
    local function point(v)return{V.x(v),V.y(v),V.z(v)}end
    local function vec(v)return V(v[1],v[2],v[3])end
    local function quat(v)return Q.from_elements(unpack(v))end
    local function ptr0(at)return b:_u32(at)+b:_u32(at+4)*4294967296 end
    local groups={};local self={writes=0,coalesced=0,nodes=0,publishes=0}
    local function graph_valid(g)
        return g.part.valid() and b:_ptr(g.ctx.object+0x98)==g.links
            and b:_ptr(g.ctx.object+0xa0)==g.hashes
            and b:_ptr(g.ctx.object+0x78)==b:_ptr(cal.body_context.object+0x88)
    end
    for _,part in ipairs(parts)do
        local ctx=assert(part.context,'Render placement context missing')
        local count=b:_u32(ctx.object+0x70);assert(count>0 and count<=256,'Render node count changed')
        local g={part=part,ctx=ctx,links=b:_ptr(ctx.object+0x98),hashes=b:_ptr(ctx.object+0xa0),rows={}}
        assert(graph_valid(g),'Render skeleton ownership changed')
        -- Arm clothing has no blender: parent body animation supplies its pose.
        -- Weapons may animate their internal nodes; only their external roots
        -- are edited, leaving those internal animation channels untouched.
        assert(part.group=='weapon' or ptr0(ctx.object+0x168)==0,'Arm renderer has its own animation writer')
        local selected={}
        local function include(node)
            for depth=1,count do
                assert(node>=0 and node<count,'Skinning node out of range')
                local link=b:_u32(g.links+node*4);local flag,parent=link%65536,math.floor(link/65536)
                if flag==2 then
                    assert(parent<b:_u32(cal.body_context.object+0x70),'External skinning parent changed')
                    selected[node]={parent=parent,link=link};return
                end
                assert(flag==1 and parent~=node,'Skinning node is not linked to owned body')
                node=parent
            end
            error('Skinning hierarchy cycle')
        end
        local meshes=U.num_meshes(part.handle);assert(meshes<=128,'Render mesh count changed')
        for i=1,meshes do
            local mesh=U.mesh(part.handle,i);local p=tonumber(ffi.cast('uintptr_t',mesh))
            local binding=ptr0(p+0x80)
            if binding~=0 then
                local n=b:_u32(binding);assert(n>0 and n<=128,'Skinning binding count changed')
                local offset=b:_u32(binding+8);assert(offset>=16 and offset<=65536,'Skinning map offset changed')
                for j=0,n-1 do include(b:_u32(binding+offset+j*4))end
            elseif part.group=='weapon' then
                include(sr.Mesh.node(mesh)-1)
            end
        end
        for node,info in pairs(selected)do
            local n=node+1
            g.rows[#g.rows+1]={node=n,parent=info.parent+1,link=info.link,
                hash=b:_u32(g.hashes+node*4),before=point(U.local_position(part.handle,n)),
                rotation={Q.to_elements(U.local_rotation(part.handle,n))}}
            self.nodes=self.nodes+1
        end
        assert(#g.rows>0,'No linked skinning nodes found')
        groups[#groups+1]=g
    end
    local function row_valid(g,r)
        return b:_u32(g.links+(r.node-1)*4)==r.link and b:_u32(g.hashes+(r.node-1)*4)==r.hash
    end
    function self:restore()
        for _,g in ipairs(groups)do
            if graph_valid(g)then
                local dirty=false
                for _,r in ipairs(g.rows)do
                    if row_valid(g,r)then
                        if r.last and close(point(U.local_position(g.part.handle,r.node)),r.last)then
                            U.set_local_position(g.part.handle,r.node,vec(r.before));dirty=true
                        end
                        if r.last_rotation and sameq({Q.to_elements(U.local_rotation(g.part.handle,r.node))},r.last_rotation)then
                            U.set_local_rotation(g.part.handle,r.node,quat(r.rotation));dirty=true
                        end
                    end
                    r.last,r.last_rotation=nil,nil
                end
                if dirty then assert(sr.World.update_unit(cal.world,g.part.handle)~=false,'Render restore refused')end
            end
        end
        return true
    end
    function self:apply(transforms)
        local parents={} -- SDK matrix temporaries are valid only within this frame.
        for _,g in ipairs(groups)do
            assert(graph_valid(g),'Render placement generation/parent changed')
            local t=assert(transforms[g.part.group],'Render placement group missing');local dirty=false
            local rotating=not sameq({Q.to_elements(t.rotation)},{0,0,0,1})
            local identity=not rotating and close(t.source,t.target)
            for _,r in ipairs(g.rows)do
                assert(row_valid(g,r),'Skinning bone mapping changed')
                local position=point(U.local_position(g.part.handle,r.node))
                local rotation={Q.to_elements(U.local_rotation(g.part.handle,r.node))}
                -- A foreign writer owns its new value. Never accumulate the
                -- offset on the last authored pose, or stomp a replacement.
                assert(close(position,r.last or r.before) and sameq(rotation,r.last_rotation or r.rotation),'Render local pose has another writer')
                local next_position,next_q
                if identity then
                    -- Avoid a float32 world -> local round trip when unchanged.
                    next_position=r.before;next_q=quat(r.rotation)
                else
                local parent=parents[r.parent]
                if not parent then
                    local world=U.world_pose(cal.body,r.parent)
                    parent={world=world,inverse=A.inverse(world)};parents[r.parent]=parent
                end
                local native=point(A.transform(parent.world,vec(r.before)))
                local relative=V(native[1]-t.source[1],native[2]-t.source[2],native[3]-t.source[3])
                local arm=rotating and Q.rotate(t.rotation,relative)or relative
                local moved=V(V.x(arm)+t.target[1],V.y(arm)+t.target[2],V.z(arm)+t.target[3])
                next_position=point(A.transform(parent.inverse,moved))
                for _,v in ipairs(next_position)do assert(v==v and math.abs(v)<2,'Render placement exceeds bounds')end
                if rotating then
                    parent.q=parent.q or Q.from_matrix4x4(parent.world)
                    local pq=parent.q
                    next_q=Q.normalize(Q.multiply(Q.multiply(Q.multiply(Q.inverse(pq),t.rotation),pq),quat(r.rotation)))
                else next_q=quat(r.rotation)end
                end
                local next_rotation={Q.to_elements(next_q)}
                if not close(position,next_position)then
                    U.set_local_position(g.part.handle,r.node,vec(next_position));r.last=next_position;dirty=true;self.writes=self.writes+1
                else self.coalesced=self.coalesced+1 end
                if not sameq(rotation,next_rotation)then
                    U.set_local_rotation(g.part.handle,r.node,next_q);r.last_rotation=next_rotation;dirty=true;self.writes=self.writes+1
                end
            end
            if dirty then
                assert(sr.World.update_unit(cal.world,g.part.handle)~=false,'Render placement publish refused')
                self.publishes=self.publishes+1
            end
        end
        return true
    end
    return self
end
return M
