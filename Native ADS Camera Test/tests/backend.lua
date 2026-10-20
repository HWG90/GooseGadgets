-- Byte-addressed fixtures only. No module or memory access reaches the game.
local root = assert(NATIVE_ADS_TEST_ROOT)
local Profile = dofile(root .. '/src/profile.lua')
_G.mod = { require = function(name) assert(name == 'src/profile.lua'); return Profile end }
local Backend = dofile(root .. '/src/backend.lua')
_G.mod = nil
local passed = 0
local function test(name, body)
    local ok, why = pcall(body)
    assert(ok, name .. ': ' .. tostring(why))
    passed = passed + 1
end
local function equal(a, b) assert(a == b, tostring(a) .. ' ~= ' .. tostring(b)) end
local function contains(value, fragment) assert(tostring(value):find(fragment, 1, true), tostring(value)) end
local function pack(value, size)
    local bytes = {}
    for i = 1, size do bytes[i] = string.char(value % 256); value = math.floor(value / 256) end
    return table.concat(bytes)
end
local function hex(value) return (value:gsub('%x%x', function(pair) return string.char(tonumber(pair, 16)) end)) end
-- Independent raw read-only evidence from results_739/740.txt. These literals
-- deliberately do not come from Profile, so opcode transcription is tested.
local EXE_QUERY_CAPTURE='48895c2408574883ec208bfae89fc1e9ff488bc8488bd84c8b0041ff90b00100'
local EXE_TRIGGER_CAPTURE='48895c2408574883ec208bda8bf9e8adbfe9ff448bc38bd7488b4818488b5c24'

local function fixture()
    local f = { memory = {}, base = 0x10000000, context = 0x20000000, camera = 0x20003000,
        world = 0x30000000, owner = 0x40000000, player = 0x50000000,
        wield = 0x60000000, weapons = 0x70000000, avatar_ep = 0x72000000,
        weapon_ep = 0x72000100, controller = 0x75000000,
        avatar = 0x333, body = 0x222, light = 0x111, weapon = 0x444, weapon_unit = 0x555,
        allowed = true, calls = {}, entries = 0, exits = 0, exit_throw = 0,
        executable = 0x80000000, unit_api_root = 0x81000000, unit_api = 0x82000000,
        executable_reads = 0, body_queries = 0, body_events = 0, has_body_event = true,
        expected_body_event = 0x372071D0, viewmodel = 0x400008,
        vm_registry = 0x83000000, vm_units = 0x84000000, vm_generations = 0x85000000,
        vm_object = 0x86000000, alignment_prepares = 0, alignment_begins = 0,
        alignment_ends = 0, alignment_reads = 0, alignment_armed = false }
    function f:write(address, value) for i = 1, #value do self.memory[address + i - 1] = value:byte(i) end end
    function f:read(address, size)
        local value = {}
        for i = 1, size do value[i] = string.char(self.memory[address + i - 1] or 0) end
        return table.concat(value)
    end
    function f:u32(address, value) self:write(address, pack(value, 4)) end
    function f:ptr(address, value) self:write(address, pack(value, 8)) end
    function f:map(address, bucket, key, index)
        self:ptr(address, bucket); self:u32(address + 8, 1)
        self:u32(address + 12, 0xffffffff); self:u32(address + 16, 1)
        self:write(bucket, pack(key, 4) .. pack(index, 4))
    end
    function f:top(kind, options)
        options = options or {}
        local head, tail = options.head or 0, options.tail or 1
        self:u32(self.context + 0x1f8, head); self:u32(self.context + 0x1fc, tail)
        local address = head ~= tail and self.context + 0x200 + ((tail + 31) % 32) * 0xe8 or self.context + 0x1f00
        self:write(address, pack(kind, 2) .. '\0\0' .. pack(options.avatar or self.avatar, 4)
            .. pack(options.weapon or self.weapon, 4) .. pack(options.body or self.body, 4) .. '\0\0\0\0')
        return address
    end
    function f:move_context(address)
        local data = self:read(self.context, 0x2100)
        self.context = address
        self:write(address, data); self:ptr(self.base + Profile.globals.camera, address)
    end
    f:write(f.base, 'MZ'); f:u32(f.base + 0x3c, 0x80)
    f:write(f.base + 0x80, 'PE\0\0' .. pack(0x8664, 2))
    f:u32(f.base + 0x88, Profile.timestamp)
    f:write(f.base + 0x98, pack(0x20b, 2)); f:u32(f.base + 0xd0, Profile.image_size)
    for _, check in ipairs(Profile.checks) do f:write(f.base + check.rva, hex(check.hex)) end
    for name, address in pairs({ camera = f.context, controller = f.controller, world = f.world,
        player = f.player, avatar = f.owner, wield = f.wield, weapons = f.weapons }) do
        f:ptr(f.base + Profile.globals[name], address)
    end
    f:ptr(f.context, f.camera); f:top(4)
    f:u32(f.player + 0x88, 1); f:u32(f.player + 0x3a8, f.light)
    local avatar_descriptor = pack(19, 4) .. pack(23, 4) .. pack(f.avatar, 4)
        .. pack(f.body, 4) .. pack(f.light, 4) .. '\1\0\0\0'
    local weapon_descriptor = pack(29, 4) .. pack(31, 4) .. pack(f.weapon, 4)
        .. pack(f.weapon_unit, 4) .. pack(0x777, 4) .. '\1\0\0\0'
    f:write(f.world + 0xf32f18, avatar_descriptor)
    f:write(f.world + 0xf32f18 + 24, weapon_descriptor)
    f:map(f.world + 0xf22ec8, 0x71000000, f.light, 0)
    f:map(f.world + 0xf1aeb0, 0x71000100, f.weapon, 1)
    f:map(f.owner + 0xf8, 0x71000200, f.avatar, 0)
    f:u32(f.owner + 0x6c, 1); f:ptr(f.owner + 0x110, f.avatar_ep)
    f:u32(f.owner + 0x53e9b8, f.viewmodel)
    f:write(f.avatar_ep, avatar_descriptor:sub(1, 20))
    f:map(f.wield + 0x30, 0x71000300, f.avatar, 0)
    f:ptr(f.wield + 0x48, 0x73000000); f:ptr(0x73000000, f.avatar_ep)
    f:ptr(f.wield + 0x60, 0x74000000); f:u32(0x74000000, f.weapon)
    f:map(f.weapons + 0x30, 0x71000400, f.weapon, 0)
    f:ptr(f.weapons + 0x48, 0x73000100); f:ptr(0x73000100, f.weapon_ep)
    f:write(f.weapon_ep, weapon_descriptor:sub(1, 20))
    local pose = Profile.body_pose
    local exe = pose.executable
    f:write(f.executable, 'MZ'); f:u32(f.executable + 0x3c, 0x80)
    f:write(f.executable + 0x80, 'PE\0\0' .. pack(0x8664, 2))
    f:u32(f.executable + 0x88, exe.timestamp)
    f:write(f.executable + 0x98, pack(0x20b, 2)); f:u32(f.executable + 0xd0, exe.image_size)
    f:write(f.executable + 0x201710, hex(EXE_QUERY_CAPTURE))
    f:write(f.executable + 0x201900, hex(EXE_TRIGGER_CAPTURE))
    f:ptr(f.base + pose.unit_api_global, f.unit_api_root)
    f:ptr(f.unit_api_root + pose.api_offset, f.unit_api)
    f:ptr(f.unit_api + pose.exists_offset, f.executable + exe.exists.rva)
    f:ptr(f.unit_api + pose.trigger_offset, f.executable + exe.trigger.rva)
    f:ptr(f.executable + Profile.alignment.executable.unit_registry, f.vm_registry)
    f:u32(f.vm_registry + 0x98, 32)
    f:ptr(f.vm_registry + 0x88, f.vm_units)
    f:ptr(f.vm_registry + 0xa0, f.vm_generations)
    f:write(f.vm_generations + 8, '\1')
    f:ptr(f.vm_units + 8 * 8, f.vm_object)
    local io = {
        module = function() return f.base end,
        executable = function()
            f.executable_reads = f.executable_reads + 1
            if f.on_executable then f:on_executable() end
            return f.executable
        end,
        read = function(address, size)
            if f.read_failure and f:read_failure(address, size) then return nil end
            return f:read(address, size)
        end,
        invoke = function(name, snapshot, api)
            f.calls[#f.calls + 1] = name
            if name == 'allowed' then
                if f.on_allowed then f:on_allowed(snapshot) end
                return f.allowed
            elseif name == 'enter' then
                f.entries = f.entries + 1
                f:top(6, { head = snapshot.head, tail = (snapshot.tail + 1) % 32 })
                if f.on_enter then f:on_enter(snapshot) end
                return
            elseif name == 'exit' then
                f.exits = f.exits + 1
                if f.exit_throw > 0 then f.exit_throw = f.exit_throw - 1; error('fixture native exit error') end
                if not f.exit_stays then f:top(4) end
                if f.on_exit then f:on_exit(snapshot) end
                return
            elseif name == 'body_event_exists' then
                f.body_queries = f.body_queries + 1
                f.last_body_query = { body = snapshot.body, event = api.event, query = api.query }
                if f.on_body_query then f:on_body_query(snapshot, api) end
                return f.has_body_event and snapshot.body == f.body and api.event == f.expected_body_event
            elseif name == 'body_event_trigger' then
                f.body_events = f.body_events + 1
                f.last_body_event = { body = snapshot.body, event = api.event, trigger = api.trigger }
                if f.on_body_event then f:on_body_event(snapshot, api) end
                return
            end
            error('Unknown fixture native call')
        end,
    }
    f.backend = Backend.new(nil, io)
    f.alignment = {
        prepare = function(self, config)
            f.alignment_prepares = f.alignment_prepares + 1
            assert(not f.alignment_armed, 'Preparation cannot arm hooks')
            f.last_alignment_prepare = config
            if f.on_alignment_prepare then f:on_alignment_prepare(config) end
            return true, { fixture = f }
        end,
        begin = function(self, config, prepared)
            equal(prepared.fixture, f)
            f.alignment_begins = f.alignment_begins + 1
            f.calls[#f.calls + 1] = 'alignment_begin'
            if f.alignment_refuse then return false, 'fixture foreign lease active' end
            if f.alignment_partial then
                f.alignment_handle = {}; f.alignment_owned = true
                return false, 'Alignment partial install cleanup required'
            end
            f.alignment_handle = {}; f.alignment_armed = true
            f.alignment_owned = true
            f.last_alignment_begin = config
            if f.on_alignment_begin then f:on_alignment_begin(config) end
            return true, f.alignment_handle
        end,
        finish = function(self, handle)
            equal(handle, f.alignment_handle)
            f.alignment_ends = f.alignment_ends + 1
            f.calls[#f.calls + 1] = 'alignment_end'
            if f.alignment_end_failure then return false, 'fixture disarm failed' end
            f.alignment_armed = false
            f.alignment_owned = false
            return true, { armed = false, expired = false, skipped_position = 7, skipped_rotation = 8 }
        end,
        owned_handle = function()
            return f.alignment_owned and f.alignment_handle or nil
        end,
        stats = function()
            f.alignment_reads = f.alignment_reads + 1
            if f.on_alignment_stats then f:on_alignment_stats() end
            return { installed = true, armed = f.alignment_armed, expired = f.alignment_expired or false,
                error = f.alignment_error or 0, skipped_position = 7, skipped_rotation = 8 }
        end,
    }
    function f:prepare_alignment()
        self.backend.alignment = self.alignment
        local done, token = self.backend:prepare_alignment(self:snapshot())
        assert(done, token); return token
    end
    function f:enter_alignment()
        local token = self:prepare_alignment()
        local done, lease = self.backend:enter(self:snapshot(), token)
        assert(done, lease); return lease
    end
    function f:snapshot() local snapshot, why = self.backend:snapshot(); assert(snapshot, why); return snapshot end
    function f:enter() local done, lease = self.backend:enter(self:snapshot()); assert(done, lease); return lease end
    return f
end

local function pose_fixture()
    local f=fixture()
    f.weapon_object=0x87000000
    f:write(f.weapon_object+0x358,hex("1234567890abcdef"))
    f:u32(f.vm_registry+0x98,2048)
    f:write(f.vm_generations+f.weapon_unit%0x400000,'\0')
    f:ptr(f.vm_units+(f.weapon_unit%0x400000)*8,f.weapon_object)
    f.pose_prepares,f.pose_begins,f.pose_ends=0,0,0
    f.pose_updates=0
    f.pose_armed,f.pose_owned=false,false
    f.pose={
        prepare=function(self,config)
            f.pose_prepares=f.pose_prepares+1;f.last_pose_prepare=config
            assert(not f.pose_armed)
            if f.on_pose_prepare then f:on_pose_prepare(config) end
            return true,{fixture=f}
        end,
        begin=function(self,config,prepared)
            equal(prepared.fixture,f)
            f.pose_begins=f.pose_begins+1;f.calls[#f.calls+1]='pose_begin'
            if f.pose_refuse then return false,'fixture foreign pose lease' end
            f.pose_handle={};f.pose_owned=true;f.last_pose_begin=config
            if f.pose_partial then return false,'Pose partial install cleanup required' end
            f.pose_armed=true
            if f.on_pose_begin then f:on_pose_begin(config) end
            return true,f.pose_handle
        end,
        owned_handle=function() return f.pose_owned and f.pose_handle or nil end,
        set_placement=function(self,handle,x,y,z)
            equal(handle,f.pose_handle);assert(f.pose_owned)
            f.pose_updates=f.pose_updates+1
            if f.pose_update_refuse then return false,'fixture placement refused' end
            f.last_placement={x=x,y=y,z=z};return true
        end,
        finish=function(self,handle)
            equal(handle,f.pose_handle);f.pose_ends=f.pose_ends+1;f.calls[#f.calls+1]='pose_end'
            if f.pose_end_failure then return false,'fixture pose restoration failed' end
            f.pose_armed=false;f.pose_owned=false
            return true,{armed=false,expired=false,weapon_updates=9,zero_restores=1}
        end,
        stats=function()
            return {installed=f.pose_armed,armed=f.pose_armed,expired=f.pose_expired or false,
                error=f.pose_error or 0,weapon_updates=9,zero_restores=0,
                seen_position=10,seen_rotation=10,forwarded_position=10,forwarded_rotation=10,
                blend=f.pose_target or 1,target_weight=f.pose_target or 1}
        end,
    }
    f.backend.pose=f.pose
    function f:prepare_pose()
        local done,token=self.backend:prepare_pose(self:snapshot());assert(done,token);return token
    end
    function f:enter_pose(duration)
        local token=self:prepare_pose()
        local done,lease=self.backend:enter_pose(self:snapshot(),token,duration or 9000)
        assert(done,lease);return lease
    end
    return f
end

local function diagnostic_backend(f,action_reader)
    -- Exercise the production-only diagnostic branch entirely against copied
    -- fixture bytes. Every module lookup/native call is explicitly replaced.
    local io=f.backend.io
    f.backend._read=function(_,address,size)
        local bytes=io.read(address,size)
        assert(type(bytes)=='string' and #bytes==size,'Fixture read unavailable')
        return bytes
    end
    f.backend._module=function()return f.base end
    f.backend._alignment_executable=function()return f.executable end
    f.backend._invoke=function(_,name,snapshot,api)return io.invoke(name,snapshot,api)end
    f.backend._windows=function()error('Diagnostic fixture cannot access Windows/game runtime')end
    f.backend.action_state=action_reader
    f.backend.io=nil
end

test('snapshot validates actual ownership and derives native aim', function()
    local f = fixture(); local s = f:snapshot()
    equal(s.avatar, f.avatar); equal(s.weapon, f.weapon); equal(s.body, f.body)
    equal(s.camera_kind, 4); equal(s.aiming, false); equal(s.safe, true)
    equal(#f.calls, 0)
    f:write(f.owner + 0x53e880 + 6, '\1'); equal(f:snapshot().aiming, true)
    f:write(f.owner + 0x53e880 + 6, '\0')
    f:write(f.controller + 4, '\1'); equal(f:snapshot().controller_active, true)
    f:write(f.owner + 0x53e880 + 14, '\4'); equal(f:snapshot().safe, false)
end)
test('normal aim requires the observed82/125 pair independently of legacy48 and adds no reads',function()
    local f=fixture();local reader=f.backend.io.read;local reads=0
    f.backend.io.read=function(...)reads=reads+1;return reader(...)end
    local baseline=f:snapshot();local count=reads
    equal(baseline.aiming,false);equal(baseline.shoulder_aim,false)
    for _,case in ipairs({
        {false,false,false,false,false},{true,false,false,false,false},{false,true,false,false,false},
        {true,true,false,false,true},{false,false,true,false,false},{true,true,true,false,true},
        {true,true,false,true,false},{true,true,true,true,false},
    })do
        f:write(f.owner+0x53e880+10,case[1]and'\4'or'\0')
        f:write(f.owner+0x53e880+15,case[2]and'\32'or'\0')
        f:write(f.owner+0x53e880+6,case[3]and'\1'or'\0')
        f:write(f.controller+4,case[4]and'\1'or'\0')
        reads=0;local s=f:snapshot()
        equal(s.shoulder_aim,case[5]);equal(s.aiming,case[3]);equal(s.controller_active,case[4])
        equal(s.safe,true);equal(reads,count);equal(#f.calls,0)
    end
    f:write(f.owner+0x53e880+6,'\0');f:write(f.controller+4,'\0')
    local s=assert(f.backend:player_snapshot());equal(s.shoulder_aim,true);equal(s.aiming,false)
end)

test('animation indices are diagnostic and cannot self-latch native camera eligibility',function()
    local f=fixture();local layer=45
    diagnostic_backend(f,function()return {resource_match=true,layer_count=31,l1=78,l3=layer,l14=36,sprint_hypothesis=true}end)
    for _,kind in ipairs({4,6})do
        f:top(kind)
        for _,value in ipairs({44,45,66,67,69,70,71,11,16})do
            layer=value;local s=f:snapshot()
            equal(s.action_state.l3,value);equal(s.action_state_error,nil)
            equal(s.safe,true);equal(s.engine_safe,true);equal(s.native_pose_eligible,true)
        end
    end
    f:u32(f.controller,2);equal(f:snapshot().safe,false);equal(f:snapshot().native_pose_eligible,false)
    f:u32(f.controller,0);f:write(f.owner+0x53e880+14,'\4');equal(f:snapshot().safe,false)
    f:write(f.owner+0x53e880+14,'\0');f.backend.foreign_camera=function()return true end
    equal(f:snapshot().safe,false);equal(f:snapshot().native_pose_eligible,false);equal(#f.calls,0)
end)

test('unknown dead or non-foot action lifecycle fails closed while native allowed remains independent',function()
    for _,throwing in ipairs({false,true})do
        local f=fixture()
        diagnostic_backend(f,function()
            if throwing then error('fixture animation diagnostic failed')end
            return nil,'fixture animation diagnostic unavailable'
        end)
        local s=f:snapshot();equal(s.safe,false);equal(s.engine_safe,true);equal(s.action_state,nil);assert(s.action_state_error)
        assert(not f.backend:enter(s));equal(f.entries,0);equal(#f.calls,0)
    end
    for _,lifecycle in ipairs({103,64,17})do
        local f=fixture()
        diagnostic_backend(f,function()return {resource_match=true,layer_count=31,l14=lifecycle}end)
        local s=f:snapshot();equal(s.safe,false);assert(not f.backend:enter(s));equal(#f.calls,0)
    end
    local f=fixture()
    diagnostic_backend(f,function()return {resource_match=true,layer_count=31,l14=36,l3=45}end)
    local s=f:snapshot();equal(s.safe,true);f.allowed=false
    assert(not f.backend:enter(s));equal(f.entries,0);equal(#f.calls,1);equal(f.calls[1],'allowed')
end)

test('native rig can enter third-person animation states and retain its lease across motion states',function()
    local f=pose_fixture();local native_layer=67
    diagnostic_backend(f,function(_,s)
        return {resource_match=true,layer_count=31,l1=78,l3=s.camera_kind==4 and 45 or native_layer,l14=36,sprint_hypothesis=true}
    end)
    local lease=f:enter_pose(0);equal(f.entries,1);equal(f:snapshot().camera_kind,6)
    for _,layer in ipairs({71,16,11,44,45,67})do
        native_layer=layer;local stats=assert(f.backend:pose_status(lease))
        equal(stats.armed,true);equal(f.pose_ends,0);equal(lease.pose_owner_retired,nil)
    end
    assert(f.backend:release(lease));equal(f.exits,1);equal(f:snapshot().action_state.l3,45)
    local next_lease=f:enter_pose(0);assert(next_lease~=lease);equal(f.entries,2)
    assert(f.backend:release(next_lease));equal(f.exits,2)
end)
test('unknown PE build refuses every native call', function()
    local f = fixture(); f:u32(f.base + 0x88, Profile.timestamp + 1)
    local s, why = f.backend:snapshot(); equal(s, nil); contains(why, 'Unsupported game build')
    assert(not f.backend:enter({})); equal(#f.calls, 0)
end)
test('every profiled native signature is required', function()
    for _, check in ipairs(Profile.checks) do
        local f = fixture(); f:write(f.base + check.rva, '\0')
        local s, why = f.backend:snapshot(); equal(s, nil); contains(why, 'fingerprint')
        assert(not f.backend:enter({})); equal(#f.calls, 0)
    end
end)
test('local camera, descriptor and component ownership refuse entry', function()
    local mutations = {
        function(f) f:top(4, { avatar = f.avatar + 1 }) end,
        function(f) f:u32(f.world + 0xf32f18 + 16, f.light + 1) end,
        function(f) f:write(f.world + 0xf32f18 + 20, '\0') end,
        function(f) f:write(f.avatar_ep, '\0') end,
        function(f) f:write(f.weapon_ep, '\0') end,
    }
    for _, change in ipairs(mutations) do
        local f = fixture(); change(f)
        equal(f.backend:snapshot(), nil); assert(not f.backend:enter({})); equal(#f.calls, 0)
    end
end)
test('stale snapshot and ineligible weapon cannot mutate camera', function()
    local f = fixture(); local expected = f:snapshot(); f:move_context(0x21000000)
    assert(not f.backend:enter(expected)); equal(#f.calls, 0)
    f = fixture(); f.allowed = false
    assert(not f.backend:enter(f:snapshot())); equal(f.entries, 0); equal(#f.calls, 1)
    equal(f.calls[1], 'allowed')
end)
test('high pointer identity retains exact integer precision', function()
    local f = fixture(); f:move_context(0x7fff00010008)
    local before = f:snapshot()
    f:move_context(0x7fff00010010)
    assert(before.identity ~= f:snapshot().identity, 'Distinct high pointers must retain separate identities')
    assert(not f.backend:enter(before)); equal(#f.calls, 0)
end)
test('preflight changes during allowed predicate refuse mutation', function()
    for _, mutate in ipairs({
        function(f) f:write(f.owner + 0x53e880 + 6, '\1') end,
        function(f) f:write(f.controller + 4, '\1') end,
        function(f) f:move_context(0x21000000) end,
    }) do
        local f = fixture(); f.on_allowed = mutate
        assert(not f.backend:enter(f:snapshot())); equal(f.entries, 0)
    end
end)
test('native entry keeps flags unchanged and returns owned lease', function()
    local f = fixture(); local before = f:snapshot(); local lease = f:enter(); local after = f:snapshot()
    equal(f.entries, 1); equal(after.camera_kind, 6); equal(after.aiming, false)
    equal(after.flags, before.flags); equal(lease.request, after.record)
    assert(f.backend:release(lease)); equal(f.exits, 1); equal(f:snapshot().camera_kind, 4)
    assert(f.backend:release(lease)); equal(f.exits, 1)
end)
test('entry claims tail from final preflight snapshot', function()
    local f = fixture()
    f.on_allowed = function(self) self:top(4, { tail = 3 }) end
    local lease = f:enter(); equal(lease.request, f:snapshot().record)
    assert(f.backend:release(lease)); equal(f.exits, 1)
end)
test('uncertain native entry never discards cleanup lease', function()
    local f = fixture(); f.on_enter = function() error('fixture error after native mutation') end
    local lease = f:enter(); assert(lease.error); equal(f:snapshot().camera_kind, 6)
    assert(f.backend:release(lease)); equal(f.exits, 1)
end)
test('entry-induced aim changes restore own request through native exit', function()
    for _, mutate in ipairs({
        function(f) f:write(f.owner + 0x53e880 + 6, '\1') end,
        function(f) f:write(f.controller + 4, '\1') end,
    }) do
        local f = fixture(); f.on_enter = mutate
        local lease = f:enter()
        assert(lease.entry_aim_changed or lease.entry_controller_changed)
        assert(f.backend:release(lease)); equal(f.exits, 1); equal(f:snapshot().camera_kind, 4)
    end
end)
test('uncertain entry claims only the constructor target slot', function()
    local f = fixture()
    f.on_enter = function(self)
        self.read_failure = function(_, address) return address == self.base end
    end
    local lease = f:enter(); equal(lease.request, f.context + 0x200 + 0xe8)
    f.read_failure = nil
    f:top(6, { tail = 3 }) -- another same-owner native request
    assert(f.backend:release(lease)); equal(f.exits, 0)
end)
test('native exit error and unchanged request retain lease', function()
    local f = fixture(); local lease = f:enter(); f.exit_throw = 1
    assert(not f.backend:release(lease)); equal(lease.done, nil)
    f.exit_stays = true; assert(not f.backend:release(lease)); equal(lease.done, nil)
    f.exit_stays = false; assert(f.backend:release(lease)); equal(f.exits, 3)
end)
test('exit readback failure remains pending without duplicate foreign exit', function()
    local f = fixture(); local lease = f:enter()
    f.on_exit = function(self)
        self.read_failure = function(_, address) return address == self.base end
    end
    assert(not f.backend:release(lease)); equal(lease.done, nil); equal(f.exits, 1)
    f.read_failure = nil; assert(f.backend:release(lease)); equal(f.exits, 1)
end)
test('native aiming takeover never receives native exit', function()
    for _, mutate in ipairs({
        function(f) f:write(f.owner + 0x53e880 + 6, '\1') end,
        function(f) f:write(f.controller + 4, '\1') end,
    }) do
        local f = fixture(); local lease = f:enter(); mutate(f)
        assert(f.backend:release(lease)); equal(f.exits, 0); equal(f:snapshot().camera_kind, 6)
    end
end)
test('native reset or replaced context never receives old exit', function()
    for _, mutate in ipairs({
        function(f) f:top(4) end,
        function(f) f:move_context(0x21000000) end,
        function(f) f:ptr(f.context, f.camera + 8) end,
        function(f) f:top(6, { tail = 3 }) end,
        function(f) f:top(6, { avatar = f.avatar + 1, tail = 2 }) end,
        function(f) f:top(6, { weapon = f.weapon + 1, tail = 2 }) end,
    }) do
        local f = fixture(); local lease = f:enter(); mutate(f)
        assert(f.backend:release(lease)); equal(f.exits, 0)
    end
end)
test('stale weapon generation waits for request retirement', function()
    local f = fixture(); local lease = f:enter()
    f:write(f.weapon_ep, '\0'); assert(not f.backend:release(lease))
    equal(f.exits, 0); equal(lease.done, nil)
    f:top(4); assert(f.backend:release(lease)); equal(f.exits, 0)
end)
test('bad ADS body cannot trigger old native exit', function()
    local f = fixture(); local lease = f:enter()
    f:top(6, { tail = 2, body = f.body + 1 }); assert(not f.backend:release(lease)); equal(f.exits, 0)
    f:top(4); assert(f.backend:release(lease)); equal(f.exits, 0)
end)
test('changed build refuses exit until matching profile is restored', function()
    local f = fixture(); local lease = f:enter(); f:u32(f.base + 0x88, 0)
    assert(not f.backend:release(lease)); equal(f.exits, 0)
    f:u32(f.base + 0x88, Profile.timestamp); assert(f.backend:release(lease)); equal(f.exits, 1)
end)

test('baseline camera path does not resolve optional body event API', function()
    local f = fixture(); local lease = f:enter(); assert(f.backend:release(lease))
    equal(f.executable_reads, 0); equal(f.body_queries, 0); equal(f.body_events, 0)
end)
test('executable profile agrees with independent saved raw opcode capture', function()
    equal(Profile.body_pose.executable.exists.rva, 0x201710)
    equal(Profile.body_pose.executable.trigger.rva, 0x201900)
    equal(Profile.body_pose.executable.exists.hex, EXE_QUERY_CAPTURE)
    equal(Profile.body_pose.executable.trigger.hex, EXE_TRIGGER_CAPTURE)
    local f = fixture()
    local done, token = f.backend:prepare_body_pose(f:snapshot())
    assert(done, token); equal(f.entries, 0); equal(f.body_events, 0)
end)
test('omitted 488b4818 regression fails against literal executable capture before entry', function()
    local f = fixture()
    local original = Profile.body_pose.executable.trigger.hex
    Profile.body_pose.executable.trigger.hex = '48895c2408574883ec208bda8bf9e8adbfe9ff448bc38bd7488b5c24'
    local done, why = f.backend:prepare_body_pose(f:snapshot())
    Profile.body_pose.executable.trigger.hex = original
    equal(done, false); contains(why, 'fingerprint mismatch')
    equal(f.entries, 0); equal(f.exits, 0); equal(f.body_queries, 0); equal(f.body_events, 0)
end)
test('body event preparation validates without native camera mutation', function()
    local f = fixture(); local expected = f:snapshot()
    local done, token = f.backend:prepare_body_pose(expected)
    assert(done, token); equal(type(token), 'table')
    equal(f.entries, 0); equal(f.exits, 0); equal(f.body_events, 0); equal(f.body_queries, 0); equal(#f.calls, 0)
    equal(f:snapshot().camera_kind, 4)
    local lease = f:enter()
    assert(f.backend:release_body_pose(lease, token)); equal(f.body_queries, 1); equal(f.body_events, 1)
    assert(f.backend:release(lease)); equal(f.exits, 1)
end)
test('body event preparation makes no membership claim and postentry query remains mandatory', function()
    local f = fixture(); f.has_body_event = false
    local done, token = f.backend:prepare_body_pose(f:snapshot())
    assert(done, token)
    equal(f.entries, 0); equal(f.exits, 0); equal(f.body_queries, 0); equal(f.body_events, 0); equal(#f.calls, 0)
    local lease = f:enter()
    local dispatched, why = f.backend:release_body_pose(lease, token)
    equal(dispatched, false); contains(why, 'unavailable')
    equal(f.body_queries, 1); equal(f.body_events, 0); equal(lease.body_pose_attempted, nil)
    assert(f.backend:release(lease)); equal(f.exits, 1)
end)
test('body event preparation rejects owner native state or API changes', function()
    for _, mutate in ipairs({
        function(f) f:move_context(0x21000000) end,
        function(f) f:top(6, { tail = 2 }) end,
        function(f) f:write(f.owner + 0x53e880 + 6, '\1') end,
        function(f) f:write(f.controller + 4, '\1') end,
        function(f) f:write(f.controller, '\1') end,
        function(f) f:write(f.executable + 0x201900, '\0') end,
    }) do
        local f = fixture(); local expected = f:snapshot(); mutate(f)
        assert(not f.backend:prepare_body_pose(expected))
        equal(f.entries, 0); equal(f.exits, 0); equal(f.body_queries, 0); equal(f.body_events, 0)
    end
end)
test('body event preparation revalidates ownership and API after fingerprint reads', function()
    for _, mutate in ipairs({
        function(f) f:move_context(0x21000000) end,
        function(f) f:write(f.owner + 0x53e880 + 6, '\1') end,
        function(f) f:write(f.controller + 4, '\1') end,
        function(f) f:ptr(f.unit_api + Profile.body_pose.trigger_offset, f.executable + 8) end,
        function(f)
            local replacement = f.unit_api + 0x1000
            f:write(replacement, f:read(f.unit_api, 0x380))
            f:ptr(f.unit_api_root + Profile.body_pose.api_offset, replacement)
        end,
    }) do
        local f = fixture()
        f.on_executable = function(self) if self.executable_reads == 2 then mutate(self) end end
        assert(not f.backend:prepare_body_pose(f:snapshot()))
        equal(f.entries, 0); equal(f.exits, 0); equal(f.body_queries, 0); equal(f.body_events, 0); equal(#f.calls, 0)
    end
end)
test('prepared token binds backend owner body and exact Unit API', function()
    local f = fixture(); local done, token = f.backend:prepare_body_pose(f:snapshot()); assert(done)
    local lease = f:enter()
    assert(not f.backend:release_body_pose(lease, {})); equal(f.body_events, 0)
    local other = fixture(); local other_lease = other:enter()
    assert(not other.backend:release_body_pose(other_lease, token)); equal(other.body_events, 0)
    local replacement = f.unit_api + 0x1000
    f:write(replacement, f:read(f.unit_api, 0x380))
    f:ptr(f.unit_api_root + Profile.body_pose.api_offset, replacement)
    assert(not f.backend:release_body_pose(lease, token)); equal(f.body_events, 0); equal(f.body_queries, 0)
    assert(f.backend:release(lease)); assert(other.backend:release(other_lease))
end)
test('prepared token is consumed by one dispatch and postentry membership is always checked', function()
    local f = fixture(); local done, token = f.backend:prepare_body_pose(f:snapshot()); assert(done)
    local lease = f:enter(); f.has_body_event = false
    assert(not f.backend:release_body_pose(lease, token)); equal(f.body_events, 0); equal(f.body_queries, 1)
    f.has_body_event = true
    assert(f.backend:release_body_pose(lease, token)); equal(f.body_events, 1); equal(f.body_queries, 2)
    assert(f.backend:release(lease))
    local second = f:enter()
    assert(not f.backend:release_body_pose(second, token)); equal(f.body_events, 1); equal(f.body_queries, 2)
    assert(f.backend:release(second))
end)
test('paired exit body event uses exact body and hash only once', function()
    local f = fixture(); local lease = f:enter(); local before = f:snapshot()
    assert(f.backend:release_body_pose(lease)); equal(f.body_queries, 1); equal(f.body_events, 1)
    equal(f.last_body_query.body, f.body); equal(f.last_body_query.event, 0x372071D0)
    equal(f.last_body_event.body, f.body); equal(f.last_body_event.event, 0x372071D0)
    equal(f.last_body_event.trigger, f.executable + Profile.body_pose.executable.trigger.rva)
    equal(lease.body_pose_attempted, true); equal(lease.body_pose_released, true)
    assert(f.backend:release_body_pose(lease)); equal(f.body_queries, 1); equal(f.body_events, 1)
    equal(f:snapshot().camera_kind, 6); equal(f:snapshot().flags, before.flags)
    assert(f.backend:release(lease)); equal(f.exits, 1)
end)
test('paired exit body event rejects missing or retired camera lease', function()
    local f = fixture()
    assert(not f.backend:release_body_pose(nil)); assert(not f.backend:release_body_pose({}))
    local lease = f:enter(); assert(f.backend:release(lease))
    assert(not f.backend:release_body_pose(lease)); equal(f.body_queries, 0); equal(f.body_events, 0)
end)
test('paired exit body event refuses foreign request or unsafe native state', function()
    for _, mutate in ipairs({
        function(f) f:move_context(0x21000000) end,
        function(f) f:top(4) end,
        function(f) f:top(6, { tail = 3 }) end,
        function(f) f:top(6, { tail = 2, body = f.body + 1 }) end,
        function(f) f:write(f.weapon_ep, '\0') end,
        function(f) f:write(f.owner + 0x53e880 + 6, '\1') end,
        function(f) f:write(f.controller + 4, '\1') end,
        function(f) f:write(f.controller, '\1') end,
        function(f) f:write(f.owner + 0x53e880 + 14, '\4') end,
    }) do
        local f = fixture(); local lease = f:enter(); mutate(f)
        assert(not f.backend:release_body_pose(lease)); equal(f.body_queries, 0); equal(f.body_events, 0)
        equal(lease.body_pose_attempted, nil)
    end
end)
test('paired exit body event rejects executable build or signature drift', function()
    local profile = Profile.body_pose.executable
    for _, mutate in ipairs({
        function(f) f:write(f.executable, '\0') end,
        function(f) f:u32(f.executable + 0x88, profile.timestamp + 1) end,
        function(f) f:u32(f.executable + 0xd0, profile.image_size + 1) end,
        function(f) f:write(f.executable + profile.exists.rva, '\0') end,
        function(f) f:write(f.executable + profile.trigger.rva, '\0') end,
        function(f) f:write(f.base + Profile.checks[1].rva, '\0') end,
    }) do
        local f = fixture(); local lease = f:enter(); mutate(f)
        assert(not f.backend:release_body_pose(lease)); equal(f.body_queries, 0); equal(f.body_events, 0)
        equal(lease.body_pose_attempted, nil)
    end
end)
test('paired exit body event rejects missing or redirected Unit API pointers', function()
    local profile = Profile.body_pose
    for _, mutate in ipairs({
        function(f) f:ptr(f.base + profile.unit_api_global, 0) end,
        function(f) f:ptr(f.unit_api_root + profile.api_offset, 0) end,
        function(f) f:ptr(f.unit_api + profile.exists_offset, f.executable + profile.executable.exists.rva + 8) end,
        function(f) f:ptr(f.unit_api + profile.trigger_offset, f.executable + profile.executable.trigger.rva + 8) end,
    }) do
        local f = fixture(); local lease = f:enter(); mutate(f)
        assert(not f.backend:release_body_pose(lease)); equal(f.body_queries, 0); equal(f.body_events, 0)
        equal(lease.body_pose_attempted, nil)
    end
end)
test('missing paired exit event refuses dispatch without claiming mutation', function()
    local f = fixture(); local lease = f:enter(); f.has_body_event = false
    assert(not f.backend:release_body_pose(lease)); equal(f.body_queries, 1); equal(f.body_events, 0)
    equal(lease.body_pose_attempted, nil)
    f.has_body_event = true; assert(f.backend:release_body_pose(lease)); equal(f.body_events, 1)
end)
test('different available body event hash never causes a trigger', function()
    local f = fixture(); local lease = f:enter(); f.expected_body_event = 0xE7A19E58
    assert(not f.backend:release_body_pose(lease)); equal(f.body_queries, 1); equal(f.body_events, 0)
    equal(f.last_body_query.event, 0x372071D0)
end)
test('body event query cannot carry stale ownership into dispatch', function()
    for _, mutate in ipairs({
        function(f) f:move_context(0x21000000) end,
        function(f) f:top(6, { tail = 3 }) end,
        function(f) f:write(f.owner + 0x53e880 + 6, '\1') end,
        function(f) f:write(f.controller + 4, '\1') end,
        function(f) f:ptr(f.unit_api + Profile.body_pose.trigger_offset, f.executable + 8) end,
        function(f) f:write(f.executable + Profile.body_pose.executable.trigger.rva, '\0') end,
        function(f)
            local replacement = f.unit_api + 0x1000
            f:write(replacement, f:read(f.unit_api, 0x380))
            f:ptr(f.unit_api_root + Profile.body_pose.api_offset, replacement)
        end,
    }) do
        local f = fixture(); local lease = f:enter(); f.on_body_query = mutate
        assert(not f.backend:release_body_pose(lease)); equal(f.body_queries, 1); equal(f.body_events, 0)
        equal(lease.body_pose_attempted, nil)
    end
end)
test('uncertain body event dispatch cannot repeat and retains full native exit', function()
    local f = fixture(); local lease = f:enter()
    f.on_body_event = function() error('fixture error after body event dispatch') end
    assert(not f.backend:release_body_pose(lease)); equal(f.body_events, 1)
    equal(lease.body_pose_attempted, true); equal(lease.body_pose_released, nil); equal(lease.done, nil)
    assert(not f.backend:release_body_pose(lease)); equal(f.body_events, 1)
    assert(f.backend:release(lease)); equal(f.exits, 1)
end)
test('body event synchronous aim changes do not impersonate human takeover', function()
    for _, mutate in ipairs({
        function(f) f:write(f.owner + 0x53e880 + 6, '\1') end,
        function(f) f:write(f.controller + 4, '\1') end,
    }) do
        local f = fixture(); local lease = f:enter(); f.on_body_event = mutate
        assert(f.backend:release_body_pose(lease))
        assert(lease.body_event_aim_changed or lease.body_event_controller_changed)
        assert(f.backend:release(lease)); equal(f.exits, 1)
    end
end)
test('uncertain body event still records synchronous aim mutation for cleanup', function()
    for _, mutate in ipairs({
        function(f) f:write(f.owner + 0x53e880 + 6, '\1') end,
        function(f) f:write(f.controller + 4, '\1') end,
    }) do
        local f = fixture(); local lease = f:enter()
        f.on_body_event = function(self) mutate(self); error('fixture error after native mutation') end
        assert(not f.backend:release_body_pose(lease))
        assert(lease.body_event_aim_changed or lease.body_event_controller_changed)
        equal(lease.body_pose_released, nil); assert(not f.backend:release_body_pose(lease)); equal(f.body_events, 1)
        assert(f.backend:release(lease)); equal(f.exits, 1)
    end
end)
test('unchanged body event preserves later genuine native aim takeover', function()
    for _, mutate in ipairs({
        function(f) f:write(f.owner + 0x53e880 + 6, '\1') end,
        function(f) f:write(f.controller + 4, '\1') end,
    }) do
        local f = fixture(); local lease = f:enter()
        assert(f.backend:release_body_pose(lease))
        equal(lease.body_event_aim_changed, false); equal(lease.body_event_controller_changed, false)
        mutate(f); assert(f.backend:release(lease)); equal(f.exits, 0)
    end
end)

test('alignment remains inactive in idle and ordinary native entry', function()
    local f = fixture(); f:snapshot()
    equal(f.alignment_prepares, 0); equal(f.alignment_begins, 0); equal(f.alignment_ends, 0)
    local lease = f:enter(); equal(f.alignment_begins, 0)
    assert(f.backend:release(lease)); equal(f.alignment_ends, 0)
    local token = f:prepare_alignment()
    assert(token); equal(f.alignment_prepares, 1); equal(f.alignment_begins, 0)
    equal(f.alignment_armed, false); equal(f.entries, 1)
end)

test('alignment preflight validates executable and viewmodel generation before helper preparation', function()
    for _, mutate in ipairs({
        function(f) f:u32(f.executable + 0x88, 0) end,
        function(f) f:write(f.executable + Profile.body_pose.executable.exists.rva, '\0') end,
        function(f) f:write(f.vm_generations + 8, '\2') end,
        function(f) f:u32(f.vm_registry + 0x98, 8) end,
        function(f) f:u32(f.owner + 0x53e9b8, 0) end,
        function(f) f:ptr(f.vm_units + 8 * 8, 0) end,
    }) do
        local f = fixture(); f.backend.alignment = f.alignment; mutate(f)
        assert(not f.backend:prepare_alignment(f:snapshot()))
        equal(f.alignment_prepares, 0); equal(f.entries, 0); equal(f.alignment_begins, 0)
    end
end)

test('alignment arms before native entry and disarms before every native exit', function()
    local f = fixture(); f.on_enter = function(self) assert(self.alignment_armed) end
    local lease = f:enter_alignment()
    equal(f.calls[1], 'allowed'); equal(f.calls[2], 'alignment_begin'); equal(f.calls[3], 'enter')
    local config = f.last_alignment_begin
    equal(config.viewmodel, f.viewmodel); equal(config.avatar_owner, f.owner); equal(config.avatar_index, 0)
    equal(config.request, lease.request); equal(config.duration_ms, 10500)
    local stats = assert(f.backend:alignment_status(lease))
    equal(stats.armed, true); equal(stats.expired, false); equal(stats.skipped_position, 7)
    f.on_exit = function(self) equal(self.alignment_armed, false) end
    assert(f.backend:release(lease))
    equal(f.calls[4], 'alignment_end'); equal(f.calls[5], 'exit')
    equal(lease.alignment_stats.skipped_rotation, 8)
    assert(f.backend:release(lease)); equal(f.alignment_ends, 1)
end)

test('alignment tokens are backend owned, single use and viewmodel bound', function()
    local f = fixture(); local token = f:prepare_alignment()
    local other = fixture(); other.backend.alignment = other.alignment
    assert(not other.backend:enter(other:snapshot(), token)); equal(other.alignment_begins, 0)
    f:ptr(f.vm_units + 8 * 8, f.vm_object + 8)
    assert(not f.backend:enter(f:snapshot(), token)); equal(f.alignment_begins, 0)
    f:ptr(f.vm_units + 8 * 8, f.vm_object)
    local done, lease = f.backend:enter(f:snapshot(), token); assert(done, lease)
    assert(not f.backend:prepare_alignment(f:snapshot()))
    assert(f.backend:release(lease))
    assert(not f.backend:enter(f:snapshot(), token)); equal(f.alignment_begins, 1)
end)

test('alignment Begin refusal never ends a foreign run or enters camera', function()
    local f = fixture(); local token = f:prepare_alignment(); f.alignment_refuse = true
    local done = f.backend:enter(f:snapshot(), token)
    equal(done, false); equal(f.entries, 0); equal(f.alignment_ends, 0)
    equal(f.backend.alignment_lease, nil)
end)

test('partial alignment installation retains rollback ownership without camera entry', function()
    local f = fixture(); local token = f:prepare_alignment(); f.alignment_partial = true
    local done, lease = f.backend:enter(f:snapshot(), token)
    equal(done, true); contains(lease.error, 'partial install cleanup required')
    equal(f.entries, 0); equal(f.alignment_armed, false); equal(f.alignment_owned, true)
    f.alignment_end_failure = true
    assert(not f.backend:release(lease)); equal(f.alignment_ends, 1); equal(f.exits, 0)
    equal(lease.done, nil); equal(f.alignment_owned, true)
    f.alignment_end_failure = false
    assert(f.backend:release(lease)); equal(f.alignment_ends, 2); equal(f.exits, 0)
    equal(f.alignment_owned, false); equal(lease.done, true)
end)

test('post-arm ownership changes skip entry but retain mandatory disarm lease', function()
    local f = fixture()
    f.on_alignment_begin = function(self) self:top(4, { tail = 3 }) end
    local lease = f:enter_alignment()
    equal(f.entries, 0); equal(f.alignment_armed, true); assert(lease.error)
    assert(f.backend:release(lease)); equal(f.alignment_ends, 1); equal(f.exits, 0)
end)

test('partial native entry retains alignment cleanup and retries failed End first', function()
    local f = fixture(); f.on_enter = function() error('fixture failure after native entry') end
    local lease = f:enter_alignment(); assert(lease.error)
    f.alignment_end_failure = true
    assert(not f.backend:release(lease)); equal(f.exits, 0); equal(lease.done, nil)
    equal(f.alignment_armed, true)
    f.alignment_end_failure = false
    assert(f.backend:release(lease)); equal(f.alignment_ends, 2); equal(f.exits, 1)
    equal(f.alignment_armed, false)
end)

test('native aim or replaced owner disarms before yielding camera ownership', function()
    for _, mutate in ipairs({
        function(f) f:write(f.owner + 0x53e880 + 6, '\1') end,
        function(f) f:write(f.controller + 4, '\1') end,
        function(f) f:move_context(0x21000000) end,
    }) do
        local f = fixture(); local lease = f:enter_alignment(); mutate(f)
        assert(f.backend:release(lease)); equal(f.alignment_armed, false)
        equal(f.alignment_ends, 1); equal(f.exits, 0)
    end
end)

test('viewmodel swap changes lease identity and waits for old request retirement', function()
    local f = fixture(); local lease = f:enter_alignment(); local identity = f:snapshot().identity
    f:u32(f.owner + 0x53e9b8, f.viewmodel + 1)
    f:write(f.vm_generations + 9, '\1'); f:ptr(f.vm_units + 9 * 8, f.vm_object + 0x100)
    assert(f:snapshot().identity ~= identity)
    local stats, why = f.backend:alignment_status(lease)
    equal(stats, nil); contains(why, 'changed'); equal(f.alignment_ends, 1)
    equal(f.alignment_armed, false)
    assert(not f.backend:release(lease));equal(f.exits,0)
    f:top(4);assert(f.backend:release(lease)); equal(f.alignment_ends, 1)
end)

test('alignment disarms even when camera verification must remain pending', function()
    local f = fixture(); local lease = f:enter_alignment()
    f:write(f.base, '\0')
    assert(not f.backend:release(lease)); equal(f.alignment_ends, 1); equal(f.alignment_armed, false)
    equal(lease.done, nil); equal(f.exits, 0)
    f:write(f.base, 'MZ'); assert(f.backend:release(lease)); equal(f.alignment_ends, 1)
end)

test('alignment entry retains its cleanup lease when diagnostic logging throws', function()
    local f = fixture(); f.backend.log = function() error('fixture log failure') end
    local lease = f:enter_alignment()
    equal(f.alignment_armed, true); assert(lease.alignment.handle)
    -- Cleanup logging belongs to the existing exit path; silence it here to
    -- isolate retention of the already armed entry lease.
    f.backend.log = function() end
    assert(f.backend:release(lease)); equal(f.alignment_ends, 1)
end)

test('alignment statistics expose expiry and reject native errors', function()
    local f = fixture(); local lease = f:enter_alignment(); f.alignment_expired = true
    equal(assert(f.backend:alignment_status(lease)).expired, true)
    f.alignment_error = 9
    assert(not f.backend:alignment_status(lease)); equal(f.alignment_ends, 1)
    assert(f.backend:release(lease))
end)

test('pose preparation is read-only and ordinary entry never arms either helper',function()
    local f=pose_fixture();local snapshot=f:snapshot()
    equal(snapshot.weapon_component_descriptor,f.weapon_ep)
    local token=f:prepare_pose();equal(type(token),'table')
    equal(f.pose_prepares,1);equal(f.pose_begins,0);equal(f.pose_ends,0)
    equal(f.entries,0);equal(#f.calls,0)
    local lease=f:enter();assert(f.backend:release(lease))
    equal(f.pose_begins,0);equal(f.pose_ends,0);equal(f.alignment_begins,0)
end)

test('pose preflight requires weapon and model registry generations',function()
    for _,mutate in ipairs({
        function(f) f:write(f.vm_generations+f.weapon_unit,'\1') end,
        function(f) f:ptr(f.vm_units+f.weapon_unit*8,0) end,
        function(f) f:u32(f.vm_registry+0x98,f.weapon_unit) end,
        function(f) f:write(f.vm_generations+8,'\2') end,
    }) do
        local f=pose_fixture();mutate(f)
        assert(not f.backend:prepare_pose(f:snapshot()))
        equal(f.pose_prepares,0);equal(f.pose_begins,0);equal(f.entries,0)
    end
    local f=pose_fixture();f.on_pose_prepare=function(self) self:write(self.weapon_ep,'\0') end
    assert(not f.backend:prepare_pose(f:snapshot()));equal(f.pose_begins,0)
end)

test('pose branch callsite is independently fingerprinted before helper preparation or Begin',function()
    local f=pose_fixture();local expected=f:snapshot()
    local check
    for _,item in ipairs(Profile.checks) do
        if item.name=='pose_branch_position_call' then check=item end
    end
    assert(check,'Missing arms/weapon branch fingerprint')
    equal(check.rva,0x1288420);equal(check.hex,'41ff5138')
    -- Literal copied from the captured evaluator, independent of fixture setup.
    equal(f:read(f.base+0x1288420,4),'\65\255\81\56')
    f:write(f.base+0x1288420,'\144\144\144\144')
    local done,why=f.backend:prepare_pose(expected)
    equal(done,false);contains(why,'fingerprint')
    equal(f.pose_prepares,0);equal(f.pose_begins,0);equal(f.entries,0)
    f:write(f.base+0x1288420,'\65\255\81\56')
    local token=f:prepare_pose()
    f:write(f.base+0x1288420,'\0')
    assert(not f.backend:enter_pose(expected,token,100))
    equal(f.pose_prepares,1);equal(f.pose_begins,0);equal(f.entries,0)
end)

test('pose arms before entry with remaining duration and exact weapon descriptor',function()
    local f=pose_fixture();f.on_enter=function(self) assert(self.pose_armed) end
    local lease=f:enter_pose(4356)
    equal(f.calls[1],'allowed');equal(f.calls[2],'pose_begin');equal(f.calls[3],'enter')
    local c=f.last_pose_begin
    equal(c.request,lease.request);equal(c.duration_ms,4356)
    equal(c.weapon_descriptor,f.weapon_ep);equal(c.weapon_unit,f.weapon_unit)
    equal(c.blend_ms,150);equal(c.offset_x,0.15);equal(c.offset_y,0);equal(c.offset_z,-0.12)
    equal(c.viewmodel,f.viewmodel);equal(c.avatar_owner,f.owner)
    f.on_exit=function(self) equal(self.pose_armed,false) end
    assert(f.backend:release(lease))
    equal(f.calls[4],'pose_end');equal(f.calls[5],'exit');equal(lease.pose_stats.zero_restores,1)
end)

test('pose duration accepts manual zero and invalid bounded durations do not consume the token',function()
    local f=pose_fixture();local token=f:prepare_pose()
    for _,duration in ipairs({-1,30501,1.5,'100'}) do
        assert(not f.backend:enter_pose(f:snapshot(),token,duration))
    end
    assert(not f.backend:enter_pose(f:snapshot(),token,nil))
    equal(f.pose_begins,0);equal(f.entries,0)
    local done,lease=f.backend:enter_pose(f:snapshot(),token,1);assert(done,lease)
    assert(f.backend:release(lease))
    local manual=f:enter_pose(0);equal(f.last_pose_begin.duration_ms,0)
    assert(f.backend:release(manual))
end)

test('stable player identity excludes weapon and viewmodel changes but retains player generations',function()
    local f=fixture();local before=f:snapshot()
    assert(type(before.player_identity)=='string' and #before.player_identity>0)
    f:u32(f.owner+0x53e9b8,f.viewmodel+1)
    local new_viewmodel=f:snapshot();assert(new_viewmodel.identity~=before.identity)
    equal(new_viewmodel.player_identity,before.player_identity)
    local replacement=f.weapon_unit+1
    f:u32(f.world+0xf32f18+24+12,replacement);f:u32(f.weapon_ep+12,replacement)
    local changed=f:snapshot();assert(changed.identity~=before.identity)
    equal(changed.player_identity,before.player_identity)
    f:u32(f.world+0xf32f18,20);f:u32(f.avatar_ep,20)
    local regenerated=f:snapshot();assert(regenerated.player_identity~=before.player_identity)
    f:ptr(f.context,f.camera+8)
    assert(f:snapshot().player_identity~=regenerated.player_identity)
end)

test('pose owner retirement reason survives End counter readback',function()
    local f=pose_fixture();local lease=f:enter_pose(0);f.pose_error=7
    local stats,why=f.backend:pose_status(lease);equal(stats,nil);contains(why,'error 7')
    equal(lease.pose_error,7);equal(lease.pose_stats.zero_restores,1)
    assert(f.backend:release(lease))
end)

test('pose owner-retired marker survives an inhibit which recovers before controller observation',function()
    local f=pose_fixture();local lease=f:enter_pose(0)
    f:u32(f.controller,2)
    local stats,why=f.backend:pose_status(lease);equal(stats,nil);assert(why)
    equal(lease.pose_owner_retired,true);assert(lease.pose_retire_reason);equal(f.pose_ends,1)
    f:u32(f.controller,0);equal(f:snapshot().safe,true);equal(f:snapshot().camera_kind,6)
    equal(lease.pose_owner_retired,true);equal(lease.pose_stats.armed,false)
    assert(f.backend:release(lease));equal(f.exits,1);equal(f.pose_ends,1)
end)

test('player-only snapshot proves safe identity during firearm gaps without permitting native entry',function()
    local f=fixture();local before=f:snapshot()
    f:u32(0x74000000,0)
    equal(f.backend:snapshot(),nil)
    local stable=assert(f.backend:player_snapshot());equal(stable.player_identity,before.player_identity)
    equal(stable.safe,true);equal(stable.weapon,nil);equal(stable.weapon_unit,nil)
    assert(not f.backend:enter(stable));equal(f.entries,0)
    f:write(f.owner+0x53e880+14,'\4');equal(f.backend:player_snapshot().safe,false)
    f:write(f.base,'NO');equal(f.backend:player_snapshot(),nil)
end)

test('only the exact observed weapon inhibit annotates a transition without relaxing safety',function()
    local f=fixture()
    for _,kind in ipairs({4,6}) do
        f:top(kind);f:u32(f.controller,2)
        local s=f:snapshot();equal(s.safe,false);equal(s.blocked,true);equal(s.weapon_transition,true)
        equal(f.backend:player_snapshot().weapon_transition,true)
        assert(not f.backend:enter(s));equal(f.entries,0)
    end
    for _,mask in ipairs({0,1,3,4,0xffffffff}) do
        f:top(4);f:u32(f.controller,mask)
        equal(f:snapshot().weapon_transition,false)
    end
    f:u32(f.controller,2);f:write(f.controller+5,'\1')
    equal(f:snapshot().weapon_transition,false)
    f:write(f.controller+5,'\0');f:write(f.owner+0x53e880+14,'\4')
    equal(f:snapshot().weapon_transition,false)
    f:write(f.owner+0x53e880+14,'\0');f:top(5)
    equal(f:snapshot().weapon_transition,false)
end)

test('vault annotation permits only normal-camera fallback and never firearm entry',function()
    local f=fixture();f:top(4);f:u32(f.controller,0x20)
    local s=f:snapshot();equal(s.head_camera_transition,true);equal(s.safe,false)
    assert(not f.backend:enter(s));equal(f.entries,0)
    f:top(6);equal(f:snapshot().head_camera_transition,false)
    f:top(4);f:u32(f.controller,0x40);equal(f:snapshot().head_camera_transition,false)
    f:u32(f.controller,0x20);f:write(f.controller+5,'\1')
    equal(f:snapshot().head_camera_transition,false)
end)

test('head-camera config proves current on-foot lifecycle without requiring a firearm',function()
    local f=fixture()
    -- Remove the firearm using the live fixture's wield row, not a mock full
    -- snapshot: camera_config must keep using the player-only ownership path.
    local wi=f.backend:_map(f.wield+0x30,f.avatar)
    f:u32(f.backend:_ptr(f.wield+0x60)+wi*0x1d0,0)
    equal(f.backend:snapshot(),nil)
    local observed=0
    f.backend.action_state=function(_,s)
        observed=observed+1;equal(s.weapon,nil)
        return {resource_match=true,layer_count=31,l14=36,owner=s.player_identity,body=s.body}
    end
    local c=assert(f.backend:camera_config())
    equal(c.body,f.body);equal(c.avatar,f.avatar);equal(c.camera_kind,4);equal(c.camera,f.camera)
    equal(observed,1);equal(#f.calls,0);equal(f.entries,0)
end)
test('head-camera config refuses unsupported ship resource and unknown or changed lifecycle',function()
    for _,change in ipairs({'resource','layers','lifecycle','unknown','owner','body','throw'})do
        local f=fixture()
        f.backend.action_state=function(_,s)
            if change=='throw'then error('fixture lifecycle reader failed')end
            if change=='unknown'then return nil,'fixture lifecycle unavailable'end
            return {resource_match=change~='resource',layer_count=change=='layers' and 30 or 31,
                l14=change=='lifecycle' and 103 or 36,owner=change=='owner' and 'retired' or s.player_identity,
                body=change=='body' and s.body+1 or s.body}
        end
        local c,why=f.backend:camera_config();equal(c,nil);assert(type(why)=='string')
        equal(f.executable_reads,0);equal(#f.calls,0);equal(f.entries,0)
    end
end)
test('head-camera lifecycle preparation keeps the observed vault fallback independent of firearm entry',function()
    local f=fixture();f:u32(f.controller,0x20)
    f.backend.action_state=function(_,s)
        return {resource_match=true,layer_count=31,l14=36,owner=s.player_identity,body=s.body}
    end
    local c=assert(f.backend:camera_config());equal(c.camera_kind,4)
    local s=f:snapshot();equal(s.safe,false);equal(s.head_camera_transition,true)
    assert(not f.backend:enter(s));equal(#f.calls,0);equal(f.entries,0)
end)

test('FOV config is read-only and only binds the current owned native pose request',function()
    local f=pose_fixture();local idle=assert(f.backend:fov_config())
    equal(idle.game,f.base);equal(idle.exe,f.executable);equal(idle.camera,f.camera)
    equal(f.entries,0);equal(f.pose_begins,0)
    local lease=f:enter_pose(0);local c=assert(f.backend:fov_config(lease))
    equal(c.request,lease.request);equal(c.weapon,f.weapon);equal(c.avatar_owner,f.owner)
    equal(c.avatar_index,0);equal(c.avatar,f.avatar);equal(c.body,f.body)
    assert(not f.backend:fov_config({origin=lease.origin,request=lease.request,alignment=lease.alignment}))
    f:top(4);assert(not f.backend:fov_config(lease))
    assert(f.backend:release(lease));assert(not f.backend:fov_config(lease))
end)

test('pose tokens are kind bound backend owned single use and generation bound',function()
    local f=pose_fixture();local token=f:prepare_pose()
    assert(not f.backend:enter(f:snapshot(),token))
    local other=pose_fixture();assert(not other.backend:enter_pose(other:snapshot(),token,100))
    f:ptr(f.vm_units+f.weapon_unit*8,f.weapon_object+8)
    assert(not f.backend:enter_pose(f:snapshot(),token,100));equal(f.pose_begins,0)
    f:ptr(f.vm_units+f.weapon_unit*8,f.weapon_object)
    local done,lease=f.backend:enter_pose(f:snapshot(),token,100);assert(done,lease)
    assert(not f.backend:prepare_pose(f:snapshot()));assert(f.backend:release(lease))
    assert(not f.backend:enter_pose(f:snapshot(),token,100));equal(f.pose_begins,1)
    local next_lease=f:enter_pose(50);equal(f.last_pose_begin.duration_ms,50)
    assert(f.backend:release(next_lease));equal(f.pose_ends,2)
end)

test('pose accepts real aim and controller on the exact native request',function()
    local f=pose_fixture();local lease=f:enter_pose()
    f:write(f.owner+0x53e880+6,'\1');f:write(f.controller+4,'\1');f.pose_target=0
    local stats=assert(f.backend:pose_status(lease))
    equal(stats.target_weight,0);equal(stats.armed,true);equal(f.pose_ends,0)
    assert(f.backend:release(lease));equal(f.pose_ends,1);equal(f.exits,0)
end)

test('pose allows final kind4 counts and a bounded fresh lease after release',function()
    local f=pose_fixture();local lease=f:enter_pose();f:top(4);f.pose_armed=false
    local stats=assert(f.backend:pose_status(lease));equal(stats.armed,false);equal(stats.weapon_updates,9)
    assert(f.backend:release(lease));equal(lease.done,true);equal(f.exits,0)
    local next_lease=f:enter_pose(100);assert(f.backend:release(next_lease));equal(f.pose_begins,2)
end)

test('pose partial install and uncertain entry retain cleanup only leases',function()
    local f=pose_fixture();local token=f:prepare_pose();f.pose_partial=true
    local done,lease=f.backend:enter_pose(f:snapshot(),token,100)
    assert(done);equal(lease.cleanup_only,true);contains(lease.error,'partial install')
    equal(f.entries,0);f.pose_end_failure=true
    assert(not f.backend:release(lease));equal(lease.done,nil);equal(f.pose_owned,true)
    f.pose_end_failure=false;assert(f.backend:release(lease));equal(f.pose_owned,false)
    f=pose_fixture();f.on_enter=function() error('fixture uncertain pose entry') end
    lease=f:enter_pose();equal(lease.cleanup_only,true);assert(f.backend:release(lease))
end)

test('pose Begin refusal never ends a foreign helper',function()
    local f=pose_fixture();local token=f:prepare_pose();f.pose_refuse=true
    assert(not f.backend:enter_pose(f:snapshot(),token,100))
    equal(f.pose_ends,0);equal(f.entries,0);equal(f.backend.alignment_lease,nil)
end)

test('pose postarm descriptor changes skip entry and retain mandatory End',function()
    local f=pose_fixture();f.on_pose_begin=function(self) self:write(self.weapon_ep,'\0') end
    local lease=f:enter_pose();equal(lease.cleanup_only,true);equal(f.entries,0)
    assert(f.backend:release(lease));equal(f.pose_ends,1)
end)

test('pose status rejects replaced request model generation and weapon object',function()
    for _,mutate in ipairs({
        function(f) f:top(6,{tail=3}) end,
        function(f) f:write(f.vm_generations+8,'\2') end,
        function(f) f:ptr(f.vm_units+f.weapon_unit*8,f.weapon_object+8) end,
        function(f) f:write(f.weapon_ep,'\0') end,
    }) do
        local f=pose_fixture();local lease=f:enter_pose();mutate(f)
        assert(not f.backend:pose_status(lease));equal(f.pose_ends,1)
        equal(lease.pose_owner_retired,true);assert(lease.pose_retire_reason)
    end
end)

test('pose expiry remains observable and End failure blocks native cleanup',function()
    local f=pose_fixture();local lease=f:enter_pose();f.pose_expired=true
    equal(assert(f.backend:pose_status(lease)).expired,true)
    f.pose_end_failure=true;assert(not f.backend:release(lease));equal(f.exits,0)
    local before=#f.calls
    assert(f.backend:set_placement_defaults({x=0,y=.1,z=0}))
    equal(#f.calls,before);equal(f.pose_updates,0);equal(f.pose_owned,true)
    f.pose_end_failure=false;assert(f.backend:release(lease));equal(f.pose_ends,2);equal(f.exits,1)
end)

test('pose adapter marshals ABI validates cold and distinguishes foreign and partial Begin',function()
    local ffi=require('ffi');local original=package.loaded.ffi
    local calls={validate=0,begin=0,finish=0};local result=0;local end_result=1
    local validate_result,native_error=1,77
    local generation=ffi.new('uint64_t',0x20000000)*ffi.new('uint64_t',0x10000000)+1
    local reserved=false;local placements=0
    local library={
        NADSE_Validate=function(c)
            calls.validate=calls.validate+1;equal(tonumber(c.size),104);equal(tonumber(c.abi),2)
            equal(tonumber(c.weapon_descriptor),0x72000100);equal(tonumber(c.blend_ms),150)
            equal(tonumber(c.offset_y),0);equal(tonumber(c.reserved),0)
            assert(math.abs(tonumber(c.offset_z)+0.12)<0.000001);return validate_result
        end,
        NADSE_Begin=function(c,out)
            calls.begin=calls.begin+1;equal(tonumber(c.duration_ms),321)
            equal(out[0],0)
            if result~=0 then generation=generation+1;out[0]=generation;reserved=true end
            if result=='throw' then error('fixture exception after generation publish') end
            return result
        end,
        NADSE_SetPlacement=function(token,x,y,z)
            equal(token,generation);assert(reserved);placements=placements+1
            equal(x,.1);equal(y,.2);equal(z,-.3);return 1
        end,
        NADSE_End=function(token)
            equal(token,generation);calls.finish=calls.finish+1
            if end_result==1 then reserved=false end
            return end_result
        end,
        NADSE_Error=function() return native_error end,
        NADSE_ReadStats=function(token,s)
            assert((token==0 and not reserved) or token==generation,'Wrong or rounded generation')
            s.installed=0;s.armed=0;s.expired=0;s.error=0
            s.weapon_updates=11;s.zero_restores=2;s.blend=0.25;s.target_weight=0
            return 1
        end,
    }
    local fake=setmetatable({load=function() return library end},{__index=ffi})
    package.loaded.ffi=fake
    _G.mod={dir='fixture-only-no-DLL-loaded',scope={}}
    local ok,why=pcall(function()
        local Pose=dofile(root..'/src/pose.lua');_G.mod=nil
        local adapter=Pose.new(Profile.pose)
        local c={game=1,exe=2,context=3,request=4,avatar_owner=5,avatar_index=0,avatar=6,
            weapon=7,body=8,viewmodel=9,duration_ms=321,weapon_descriptor=0x72000100,
            weapon_unit=10,blend_ms=150,offset_x=0.15,offset_y=0,offset_z=-0.12}
        local ready,token=adapter:prepare(c);assert(ready,token)
        equal(calls.validate,1);equal(calls.begin,0);equal(calls.finish,0)
        equal(ffi.sizeof('NADSE_Config'),104);equal(ffi.sizeof('NADSE_Stats'),80)
        equal(ffi.offsetof('NADSE_Config','weapon_descriptor'),72)
        equal(ffi.offsetof('NADSE_Config','offset_x'),88)
        equal(ffi.offsetof('NADSE_Config','offset_y'),92)
        equal(ffi.offsetof('NADSE_Config','offset_z'),96)
        equal(ffi.offsetof('NADSE_Config','reserved'),100)
        equal(ffi.offsetof('NADSE_Stats','blend'),72)
        validate_result=0;native_error=15
        local valid,reason=adapter:prepare(c)
        equal(valid,false);contains(reason,'arms/weapon branch');contains(reason,'native code 15')
        equal(calls.begin,0);equal(calls.finish,0)
        native_error=16;valid,reason=adapter:prepare(c)
        equal(valid,false);contains(reason,'branch position');contains(reason,'native code 16')
        equal(calls.begin,0);equal(calls.finish,0)
        native_error=17;valid,reason=adapter:prepare(c)
        equal(valid,false);contains(reason,'generation');contains(reason,'native code 17')
        native_error=18;valid,reason=adapter:prepare(c)
        equal(valid,false);contains(reason,'deadline');contains(reason,'native code 18')
        validate_result=1;native_error=77
        local rejected,unknown=adapter:begin(c,token)
        equal(rejected,false);contains(unknown,'native code 77')
        equal(adapter:owned_handle(),false);equal(calls.finish,0)
        result=2;local armed,problem=adapter:begin(c,token)
        equal(armed,false);contains(problem,'partial install cleanup required')
        local handle=adapter:owned_handle();assert(handle)
        equal(handle.generation[0],generation);assert(adapter:stats(handle))
        end_result=0;assert(not adapter:finish(handle));equal(adapter:owned_handle(),handle)
        end_result=1;assert(adapter:finish(handle));equal(adapter:owned_handle(),false)
        equal(handle.stats.weapon_updates,11);equal(handle.stats.target_weight,0)
        assert(adapter:finish(handle));equal(calls.finish,2)
        result=1;local armed,new=adapter:begin(c,token);assert(armed,new)
        assert(new.generation[0]~=handle.generation[0])
        assert(not adapter:set_placement(handle,.1,.2,-.3));equal(placements,0)
        assert(not adapter:stats(handle))
        for _,p in ipairs({{.6,0,0},{0,math.huge,0},{0,0,0/0},{.1,.2}}) do
            assert(not adapter:set_placement(new,p[1],p[2],p[3]))
        end
        equal(placements,0);assert(adapter:set_placement(new,.1,.2,-.3));equal(placements,1)
        assert(adapter:finish(new));equal(calls.finish,3)
        result='throw';local accepted=adapter:begin(c,token);equal(accepted,false)
        local uncertain=adapter:owned_handle();assert(uncertain)
        equal(uncertain.generation[0],generation)
        assert(adapter:finish(uncertain));equal(calls.finish,4)
    end)
    package.loaded.ffi=original;_G.mod=nil;assert(ok,why)
end)

test('pose placement defaults copy XYZ without native calls and allow thirty seconds',function()
    local f=pose_fixture();local placement={x=-.2,y=.3,z=.1}
    assert(f.backend:set_placement_defaults(placement));placement.x=.4
    equal(f.backend.pose_placement.x,-.2);equal(#f.calls,0);equal(f.pose_updates,0)
    local lease=f:enter_pose(30000)
    equal(f.last_pose_begin.duration_ms,30000)
    equal(f.last_pose_begin.offset_x,-.2);equal(f.last_pose_begin.offset_y,.3);equal(f.last_pose_begin.offset_z,.1)
    assert(f.backend:set_placement_defaults({x=0,y=0,z=0}))
    equal(f.last_pose_begin.offset_x,-.2);equal(f.pose_updates,0)
    assert(f.backend:release(lease));equal(f.pose_updates,0)
end)

test('pose live placement commits only accepted XYZ on the exact active lease',function()
    local f=pose_fixture();local lease=f:enter_pose();local placement={x=.1,y=-.25,z=.2}
    assert(f.backend:set_pose_placement(lease,placement));placement.y=.4
    equal(f.last_placement.y,-.25);equal(f.backend.pose_placement.y,-.25)
    equal(f.pose_updates,1);equal(f.entries,1);equal(f.pose_begins,1)
    f.pose_update_refuse=true
    assert(not f.backend:set_pose_placement(lease,{x=.2,y=.3,z=.4}))
    equal(f.backend.pose_placement.x,.1);equal(f.backend.pose_placement.y,-.25)
    assert(f.backend:release(lease))
    f.pose_update_refuse=false
    local second=f:enter_pose(100)
    equal(f.last_pose_begin.offset_y,-.25)
    assert(not f.backend:set_pose_placement(lease,{x=0,y=0,z=0}))
    equal(f.pose_updates,2);assert(f.backend:release(second))
end)

test('pose placement rejects invalid values and changed ownership without native update',function()
    for _,p in ipairs({{x=.6,y=0,z=0},{x=0,y=math.huge,z=0},{x=0,y=0,z=0/0},{x=0,z=0}}) do
        local f=pose_fixture();assert(not f.backend:set_placement_defaults(p))
        local lease=f:enter_pose();assert(not f.backend:set_pose_placement(lease,p));equal(f.pose_updates,0)
        assert(f.backend:release(lease))
    end
    for _,mutate in ipairs({
        function(f) f:top(4) end,
        function(f) f:top(6,{tail=3}) end,
        function(f) f:write(f.controller,'\1') end,
        function(f) f:ptr(f.vm_units+f.weapon_unit*8,f.weapon_object+8) end,
    }) do
        local f=pose_fixture();local lease=f:enter_pose();mutate(f)
        assert(not f.backend:set_pose_placement(lease,{x=0,y=0,z=0}));equal(f.pose_updates,0)
    end
end)

test('empty equipped entity gives a concrete firearm instruction before registry lookup',function()
    local f=fixture();f:u32(0x74000000,0xffffffff)
    local snapshot,why=f.backend:snapshot();equal(snapshot,nil)
    contains(why,'Equip a firearm');equal(#f.calls,0)
end)

test('head-camera prearm refusal prevents native pose acquisition without consuming preparation',function()
    local f=pose_fixture();local token=f:prepare_pose();local ready=false
    f.backend.camera_before_entry=function()return ready,'head cleanup pending'end
    assert(not f.backend:enter_pose(f:snapshot(),token,0));equal(f.pose_begins,0);equal(f.entries,0)
    ready=true;local done,lease=f.backend:enter_pose(f:snapshot(),token,0);assert(done,lease)
    equal(f.entries,1);assert(f.backend:release(lease))
end)
test('procedural motion never changes saved placement or the next weapon defaults',function()
    local f=pose_fixture();assert(f.backend:set_placement_defaults({x=.2,y=.1,z=-.1}))
    local lease=f:enter_pose();local count=0
    f.pose.set_motion=function(_,handle,x,y,z)
        equal(handle,f.pose_handle);count=count+1;equal(x,.01);equal(y,-.02);equal(z,.03);return true
    end
    assert(f.backend:set_pose_motion(lease,{dx=.01,dy=-.02,dz=.03}));equal(count,1)
    equal(f.pose_updates,0);equal(f.backend.pose_placement.x,.2);equal(f.backend.pose_placement.y,.1)
    assert(f.backend:release(lease));assert(not f.backend:set_pose_motion(lease,{dx=0,dy=0,dz=0}));equal(count,1)
end)
test('motion rejects malformed displacement and changed weapon generations before native update',function()
    local f=pose_fixture();local lease=f:enter_pose();local count=0
    f.pose.set_motion=function()count=count+1;return true end
    for _,bad in ipairs({.15001,-.15001,math.huge,0/0,'0'})do
        assert(not f.backend:set_pose_motion(lease,{dx=bad,dy=0,dz=0}))
    end
    f:ptr(f.vm_units+f.weapon_unit*8,f.weapon_object+8)
    assert(not f.backend:set_pose_motion(lease,{dx=0,dy=0,dz=0}));equal(count,0)
end)
test('atomic motion forwards translation and unit quaternion in one call without changing placement',function()
    local f=pose_fixture();assert(f.backend:set_placement_defaults({x=.2,y=.1,z=-.1}))
    local lease=f:enter_pose();local calls={}
    f.pose.set_motion=function(_,handle,...)
        equal(handle,f.pose_handle);calls[#calls+1]={...};return true
    end
    local x,w=math.sin(math.rad(20)/2),math.cos(math.rad(20)/2)
    assert(f.backend:set_pose_motion(lease,{dx=.01,dy=-.02,dz=.03,qx=x,qy=0,qz=0,qw=w}))
    equal(#calls,1);equal(#calls[1],8);equal(calls[1][8],false);equal(calls[1][1],.01);equal(calls[1][4],x);equal(calls[1][7],w)
    equal(f.pose_updates,0);equal(f.backend.pose_placement.x,.2)
    assert(f.backend:set_pose_motion(lease,{dx=0,dy=0,dz=0}));equal(#calls,2)
    equal(calls[2][4],0);equal(calls[2][7],1)
    assert(f.backend:release(lease))
end)
test('bad or partial motion quaternion is rejected before the atomic native update',function()
    local f=pose_fixture();local lease=f:enter_pose();local count=0
    f.pose.set_motion=function()count=count+1;return false,'native transform refused'end
    for _,q in ipairs({{1,0,0,0},{0,0,0,.5},{0,0/0,0,1},{0,0,math.huge,1},{0,0,0}})do
        assert(not f.backend:set_pose_motion(lease,{dx=0,dy=0,dz=0,qx=q[1],qy=q[2],qz=q[3],qw=q[4]}))
    end
    equal(count,0);local ok,why=f.backend:set_pose_motion(lease,{dx=.01,dy=0,dz=0,qx=0,qy=0,qz=0,qw=1})
    equal(ok,false);contains(why,'native transform refused');equal(count,1);equal(f.pose_updates,0)
    assert(f.backend:release(lease))
end)
local function watch_reads(f,address)
    local original=f.backend.io.read;local count=0
    f.backend.io.read=function(at,size)
        if at==address then count=count+1 end
        return original(at,size)
    end
    return function()return count end
end
test('one frame shares one immutable game fingerprint scan across ten fresh snapshots',function()
    local f=fixture();local anchor=Profile.checks[1];local scans=watch_reads(f,f.base+anchor.rva)
    local original=f.backend.io.module;local queries=0
    f.backend.io.module=function()queries=queries+1;return original()end
    f.backend:begin_frame()
    for _=1,10 do equal(f:snapshot().avatar,f.avatar)end
    equal(scans(),1);equal(queries,10)
    f.backend:end_frame();f:snapshot();equal(scans(),2)
    f.backend:begin_frame();f:snapshot();equal(scans(),3);f.backend:end_frame()
end)
test('frame reuse never caches mutable aiming controller request or descriptor ownership',function()
    local f=fixture();local scans=watch_reads(f,f.base+Profile.checks[1].rva)
    f.backend:begin_frame();equal(f:snapshot().aiming,false)
    f:write(f.owner+0x53e880+6,'\1');equal(f:snapshot().aiming,true)
    f:u32(f.controller,2);equal(f:snapshot().safe,false)
    f:u32(f.controller,0);f:top(6,{weapon=f.weapon+1});equal(f.backend:snapshot(),nil)
    f:top(4);f:u32(f.avatar_ep,20);equal(f.backend:snapshot(),nil)
    equal(scans(),1);f.backend:end_frame()
end)
test('frame end and a new frame reject changed code and failed validation is never cached',function()
    local f=fixture();local at=f.base+Profile.checks[1].rva;local good=f:read(at,1)
    f.backend:begin_frame();f:snapshot();f.backend:end_frame();f:write(at,'\0')
    local s,why=f.backend:snapshot();equal(s,nil);contains(why,'fingerprint')
    f.backend:begin_frame();s,why=f.backend:snapshot();equal(s,nil);contains(why,'fingerprint')
    f:write(at,good);assert(f.backend:snapshot());f.backend:end_frame()
end)
test('fresh module base changes invalidate earlier frame success even when the former base returns',function()
    local f=fixture();local resolved=f.base;local at=f.base+Profile.checks[1].rva
    f.backend.io.module=function()return resolved end
    f.backend:begin_frame();equal(f.backend:_module(),f.base)
    resolved=f.base+0x1000000;assert(not pcall(f.backend._module,f.backend))
    resolved=f.base;f:write(at,'\0');local ok,why=pcall(f.backend._module,f.backend)
    equal(ok,false);contains(why,'fingerprint');f.backend:end_frame()
    resolved=nil;assert(not pcall(f.backend._module,f.backend))
end)
test('executable checks are shared only within a frame and for the same profile identity',function()
    local f=fixture();local check=Profile.body_pose.executable.exists
    local scans=watch_reads(f,f.executable+check.rva)
    f.backend:begin_frame()
    for _=1,10 do equal(f.backend:_alignment_executable(Profile.pose),f.executable)end
    equal(scans(),1);equal(f.executable_reads,10)
    local copy={};for k,v in pairs(Profile.pose.executable)do copy[k]=v end
    equal(f.backend:_alignment_executable({executable=copy}),f.executable);equal(scans(),2)
    local wrong={};for k,v in pairs(copy)do wrong[k]=v end;wrong.timestamp=wrong.timestamp+1
    assert(not pcall(f.backend._alignment_executable,f.backend,{executable=wrong}))
    f.backend:end_frame();equal(f.backend:_alignment_executable(Profile.pose),f.executable);equal(scans(),3)
end)
test('fresh executable base changes invalidate previous same-frame profile validation',function()
    local f=fixture();local resolved=f.executable;local check=Profile.body_pose.executable.exists
    f.backend.io.executable=function()return resolved end
    f.backend:begin_frame();equal(f.backend:_alignment_executable(Profile.pose),f.executable)
    resolved=f.executable+0x1000000;assert(not pcall(f.backend._alignment_executable,f.backend,Profile.pose))
    resolved=f.executable;f:write(resolved+check.rva,'\0')
    local ok,why=pcall(f.backend._alignment_executable,f.backend,Profile.pose)
    equal(ok,false);contains(why,'fingerprint');f.backend:end_frame()
end)
test('native entry forces fingerprint validation after a same-frame snapshot',function()
    local f=fixture();f.backend:begin_frame();local s=f:snapshot()
    f:write(f.base+Profile.checks[1].rva,'\0')
    local done,why=f.backend:enter(s);equal(done,false);contains(why,'fingerprint')
    equal(#f.calls,0);equal(f.entries,0);f.backend:end_frame()
end)
test('native exit forces fingerprint validation and keeps cleanup ownership on failure',function()
    local f=fixture();local lease=f:enter();f.backend:begin_frame();f:snapshot()
    local at=f.base+Profile.checks[3].rva;local good=f:read(at,1);f:write(at,'\0')
    local done,why=f.backend:release(lease);equal(done,false);contains(why,'fingerprint')
    equal(f.exits,0);equal(lease.done,nil)
    f:write(at,good);assert(f.backend:release(lease));equal(f.exits,1);f.backend:end_frame()
end)
test('native calls also invalidate executable fingerprint reuse in the current frame',function()
    local f=fixture();local scans=watch_reads(f,f.executable+Profile.body_pose.executable.exists.rva)
    f.backend:begin_frame();local s=f:snapshot();f.backend:_alignment_executable(Profile.pose);equal(scans(),1)
    equal(f.backend:_invoke('allowed',s),true)
    f.backend:_alignment_executable(Profile.pose);equal(scans(),2);f.backend:end_frame()
end)
test('map and camera queue decode existing contiguous copies without redundant pointer reads',function()
    local f=fixture();local read=f.backend.io.read;local calls={}
    f.backend.io.read=function(at,n)calls[#calls+1]={at,n};return read(at,n)end
    equal(f.backend:_map(f.owner+0xF8,f.avatar,8),0)
    local header,pointer_reads=0,0
    for _,r in ipairs(calls)do if r[1]==f.owner+0xF8 then
        if r[2]==20 then header=header+1 elseif r[2]==8 then pointer_reads=pointer_reads+1 end
    end end
    equal(header,1);equal(pointer_reads,0);calls={}
    local s=f.backend:_top(f.base);equal(s.camera_kind,4)
    local queues=0
    for _,r in ipairs(calls)do
        if r[1]==f.context+0x1F8 then equal(r[2],8);queues=queues+1 end
        assert(r[1]~=f.context+0x1FC,'Camera tail was reread separately')
    end
    equal(queues,1);f:u32(f.context+0x1FC,32);assert(not pcall(f.backend._top,f.backend,f.base))
end)
test('batched registry and descriptor fields retain both live generation and object rechecks',function()
    local f=pose_fixture();local s=f:snapshot();local read=f.backend.io.read;local calls={}
    f.backend.io.read=function(at,n)calls[#calls+1]={at,n};return read(at,n)end
    local c=f.backend:_pose_context(s);equal(c.weapon_unit,f.weapon_unit)
    local metadata,descriptor,extra_unit,generations=0,0,0,0
    for _,r in ipairs(calls)do
        if r[1]==f.vm_registry+0x88 and r[2]==32 then metadata=metadata+1 end
        if r[1]==f.weapon_ep and r[2]==20 then descriptor=descriptor+1 end
        if r[1]==f.weapon_ep+12 and r[2]==4 then extra_unit=extra_unit+1 end
        if r[1]==f.vm_generations+8 then generations=generations+1 end
    end
    equal(metadata,1);equal(descriptor,2);equal(extra_unit,0);equal(generations,2)
    local seen=0
    f.backend.io.read=function(at,n)
        if at==f.vm_generations+8 then seen=seen+1;if seen==2 then f:write(at,'\2')end end
        return read(at,n)
    end
    assert(not pcall(f.backend._pose_context,f.backend,s));equal(seen,2)
end)
local function dof_fixture()
    local f=fixture();f.get=function()error('Observer invoked SDK getter')end;f.set=function()error('Observer wrote setting')end
    f.backend.io.function_address=function(fn)return fn==f.get and f.executable+0x3fa3d0 or f.executable+0x3fa120 end
    f:write(f.executable+0x3fa3d0,hex('488bd1e938feffff'))
    f:write(f.executable+0x3fa120,hex('488bd1e998fbffff'))
    f:write(f.executable+0x3fa262,hex('4c8b354f606101'))
    f:write(f.executable+0x3fa2f8,hex('83f80475120fb65708'))
    f.settings,f.rows=0x87000000,0x88000000
    f:ptr(f.executable+0x1a102b8,f.settings);f:write(f.settings,pack(3,4)..pack(3,4)..pack(f.rows,8))
    function f:row(index,key,kind,value)
        self:write(self.rows+index*24,pack(kind,4)..pack(0,4)..pack(value,8)..pack(key,4)..pack(0,4))
    end
    f:row(0,1,4,1);f:row(1,0x06f1d0d3,4,0);f:row(2,0x10000000,4,1)
    function f:observe()return self.backend:renderer_dof_value(self.get,self.set)end
    return f
end
test('renderer DoF observer reads fresh values with bounded unchanged-row lookup and no SDK invocation',function()
    local f=dof_fixture();equal(f:observe(),false)
    local reads={};local read=f.backend.io.read
    f.backend.io.read=function(at,n)reads[#reads+1]={at,n};return read(at,n)end
    f:row(1,0x06f1d0d3,4,1);equal(f:observe(),true)
    local row_reads=0
    for _,r in ipairs(reads)do
        if r[1]>=f.rows and r[1]<f.rows+72 then equal(r[1],f.rows+24);equal(r[2],24);row_reads=row_reads+1 end
    end
    equal(row_reads,2);equal(#f.calls,0)
end)
test('renderer observer rejects unsupported binding schema and key ownership without touching settings',function()
    for _,change in ipairs({function(f)f:row(1,0x06f1d0d3,1,0)end,
        function(f)f:row(1,0x06f1d0d3,4,2)end,function(f)f:row(1,0x06f1d0d4,4,0)end,
        function(f)f:u32(f.settings,4097)end,function(f)f:ptr(f.settings+8,1)end,
        function(f)f:write(f.executable+0x3fa262,'\0')end,
        function(f)f.backend.io.function_address=function()return f.executable end end})do
        local f=dof_fixture();change(f);local value,why=f:observe();equal(value,nil);assert(type(why)=='string');equal(#f.calls,0)
    end
end)
test('renderer observer invalidates cached lookup on table relocation and rejects concurrent header or row changes',function()
    local f=dof_fixture();equal(f:observe(),false)
    f:write(f.rows+0x100,f:read(f.rows,72));f.rows=f.rows+0x100;f:ptr(f.settings+8,f.rows)
    f:row(1,0x06f1d0d3,4,1);equal(f:observe(),true)
    for _,target in ipairs({'row','header','global'})do
        f=dof_fixture();equal(f:observe(),false);local read=f.backend.io.read;local seen=0
        f.backend.io.read=function(at,n)
            local watched=target=='row' and f.rows+24 or target=='header' and f.settings or f.executable+0x1a102b8
            if at==watched then seen=seen+1;if seen==2 then
                if target=='row'then f:row(1,0x06f1d0d3,4,1)
                elseif target=='header'then f:u32(f.settings,2)
                else f:ptr(watched,f.settings+0x100)end
            end end
            return read(at,n)
        end
        local value,why=f:observe();equal(value,nil);contains(why,'changed during observation')
    end
end)
local function bridge_fixture()
    local f=fixture();f.scene=0x89000000;f.lifecycle=3
    f:ptr(f.base+0x3326340,f.scene);f:u32(f.scene+0xac21c,3)
    f:u32(f.owner+0x53e880,0x220a)
    diagnostic_backend(f,function(_,s)
        return {resource_match=true,layer_count=31,l14=f.lifecycle,owner=s.player_identity,body=s.body}
    end)
    return f
end
test('current bridge combat flags permit the native and head camera paths while ordinary ship does not',function()
    local f=bridge_fixture();local s=f:snapshot();equal(s.safe,true);equal(s.action_state.l14,3)
    assert(f.backend:on_foot(s,s.action_state));assert(f.backend:camera_config())
    f:u32(f.owner+0x53e880,0x220c);s=f:snapshot();equal(s.safe,false);equal(s.engine_safe,true)
    local c=f.backend:camera_config();equal(c,nil)
    f:u32(f.owner+0x53e880,0x220e);equal(f:snapshot().safe,false)
    f:u32(f.owner+0x53e880,0x220a);f:u32(f.scene+0xac21c,4);equal(f:snapshot().safe,false)
    f:u32(f.scene+0xac21c,3);f.lifecycle=103;equal(f:snapshot().safe,false)
    f.lifecycle=99;equal(f:snapshot().safe,false)
end)
test('ordinary mission lifecycle needs no extra scene or control polling and unknown bridge graphs fail closed',function()
    local f=bridge_fixture();local s=f:snapshot();local reads=0;local read=f.backend._read
    f.backend._read=function(self,at,n)reads=reads+1;return read(self,at,n)end
    assert(f.backend:on_foot(s,{resource_match=true,layer_count=31,l14=36}));equal(reads,0)
    for _,action in ipairs({{resource_match=false,layer_count=31,l14=3},
        {resource_match=true,layer_count=30,l14=3},{resource_match=true,layer_count=31,l14=103}})do
        equal(f.backend:on_foot(s,action),false);equal(reads,0)
    end
    s.flags=pack(4,4)..s.flags:sub(5);equal(f.backend:on_foot(s,s.action_state),false);equal(reads,0)
end)
test('bridge lifecycle rejects flags scene and manager turnover during its bounded permission read',function()
    for _,kind in ipairs({'flags','scene','manager','address'})do
        local f=bridge_fixture();local s=f:snapshot();local read=f.backend._read;local seen=0
        if kind=='address'then s.flags_address=s.flags_address+4 end
        f.backend._read=function(self,at,n)
            local watched=kind=='flags' and s.flags_address or kind=='scene' and f.scene+0xac21c or f.base+0x3326340
            if at==watched then seen=seen+1;if seen==2 then
                if kind=='flags'then f:u32(at,0x220c)
                elseif kind=='scene'then f:u32(at,4)
                else f:ptr(at,f.scene+0x100)end
            end end
            return read(self,at,n)
        end
        equal(f.backend:on_foot(s,s.action_state),false)
    end
end)
test('weapon resource profiles resolve only on pose acquisition',function()
    local f=pose_fixture();local calls=0
    f.backend.placement_resolver=function(key)
        equal(key,'1234567890abcdef');calls=calls+1
        return {x=.23,y=.04,z=-.17}
    end
    local lease=f:enter_pose();assert(calls>0)
    equal(f.backend.pose_placement.x,.23)
    equal(f.backend.placement_weapon_key,'1234567890abcdef')
    local before=calls
    for i=1,10 do assert(f.backend:pose_status(lease))end
    equal(calls,before)
    assert(f.backend:release(lease))
end)

print('Native ADS injected-memory backend fixtures: ' .. passed .. ' passed')
