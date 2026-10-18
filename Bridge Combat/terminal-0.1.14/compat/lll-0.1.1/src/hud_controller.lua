-- Owns the extra HUD/control role only. Animation ownership stays with runtime.
-- Import/new are inert. Native ABI binding belongs to the injected adapter.
local M={}
local STAMP,ROLE8,ACTION86=0x6AB3B43F,8,0x400000
local IDENTITY={'game','stamp','world','pm','lc','avatar','ep','pc'}
local function integer(n,max)return type(n)=='number'and n==math.floor(n)and n>=0 and n<=max end
local function acknowledged(value,why)assert(value==true,why or 'Operation was not acknowledged')end
function M.new(options)
    options=options or {}
    local backend=assert(options.backend,'HUD control backend is required')
    local observe=assert(options.observe,'HUD observer is required')
    local native=assert(options.native,'Injected HUD native adapter is required')
    for _,name in ipairs({'prepare','start','tick','stop','status'})do
        assert(type(native[name])=='function','Missing HUD native adapter method: '..name)
    end
    local self={enabled=false,active=nil}
    local closing,fault,message,last_log=false,nil,'Disabled',nil
    local function report(text)
        message=tostring(text)
        if message~=last_log then last_log=message;if options.log then options.log(message)end end
    end
    local function observed()
        local ok,view,why=pcall(observe)
        if not ok then return nil,tostring(view)end
        return view,why
    end
    local function status()
        local s=native:status()
        assert(type(s)=='table','HUD native status is unavailable')
        return s
    end
    local function valid(view)
        local b=type(view)=='table'and view.base
        return type(b)=='table'and b.stamp==STAMP and b.scene==3 and b.game and b.world and b.pm and b.lc
            and b.avatar and b.ep and b.pc and view.token~=nil
            and integer(view.pm_entity,0xFFFFFFFE)and view.pm_entity>0
    end
    local function same(lease,view)
        if not valid(view)or lease.token~=view.token or lease.pm_entity~=view.pm_entity then return false end
        for _,key in ipairs(IDENTITY)do if lease.base[key]~=view.base[key]then return false end end
        return true
    end
    local function ready(view)
        return valid(view)and view.ready==true and view.menu_closed==true
            and view.photo==false and view.fixed_pose==false
    end
    local function role(view)
        local value=backend:u32(view.base.pc+0xFD0)
        assert(integer(value,0xFFFFFFFF),'HUD actor context is unreadable')
        return backend.bit.band(value,ROLE8)~=0
    end
    local function action(view)
        local value=backend:u32(view.base.pc+0xFD8)
        assert(integer(value,0xFFFFFFFF),'HUD weapon-action context is unreadable')
        return backend.bit.band(value,ACTION86)~=0
    end
    local function validate(view)
        acknowledged(backend:validate(view.base));acknowledged(backend:unique(view.base))
    end
    local function native_error(s)
        if s.error~=nil and s.error~=false and s.error~=''then return tostring(s.error)end
        if type(native.error)=='function'then
            local why=native:error()
            if why~=nil and why~=false and why~=''then return tostring(why)end
        end
    end
    local function healthy_status()
        local s=status();local why=native_error(s);assert(not why,why);return s
    end
    local function retired(lease,s)
        -- A scene/local-player change alone never permits an old-row access.
        if s.retired_safe==true and s.stopped==true and s.role8_owned==false then return true end
        if type(options.retired)=='function'then return options.retired(lease.base)==true end
        return false
    end
    local function cleanup(view)
        local lease=self.active;if not lease then return true end
        lease.stopping=true
        local s=status()
        local current=same(lease,view)
        if s.role8_owned==true then lease.native_role8=true end
        local owns=lease.role8_attempted or lease.native_role8
        if current then
            if owns and not lease.role8_removed then
                validate(view)
                if role(view)then
                    -- Journal before a possibly partial/uncertain call. remove8
                    -- is idempotent, and never removes any unrelated role bits.
                    lease.role8_remove_attempted=true
                    backend:call('remove',view.base.pc+0x50,lease.mask)
                    assert(not role(view),'HUD role8 removal was not acknowledged')
                end
                lease.role8_removed=true
            end
            -- This precedes *all* native widget teardown, including an already
            -- prepared but inactive instance. Never force-clear action bit86.
            assert(not action(view),'Waiting for native weapon action bit86 to become inactive')
        else
            assert(retired(lease,s),'Waiting for owned HUD actor or positive retirement proof')
            lease.role8_removed=true;lease.retired=true
        end
        -- A synchronous scene hook may already have retired the helper. Never
        -- replay its global destructor against a newly entered actor/scene.
        if not lease.stop_attempted and not(s.stopped==true and s.active==false and s.role8_owned~=true)then
            lease.stop_attempted=true
            acknowledged(native:stop())
        end
        s=status()
        assert(s.stopped==true and s.active==false and s.role8_owned~=true,'Waiting for native HUD teardown acknowledgement')
        self.active=nil
        report(closing and 'HUD unloaded'or not self.enabled and 'Disabled'or 'HUD paused; waiting for normal ship controls')
        return true
    end
    local function clean(view)
        local ok,done,why=pcall(cleanup,view)
        if not ok then report('HUD cleanup pending: '..tostring(done));return false,message end
        return done,why
    end
    local function advance(view,dt)
        local lease=self.active
        local s=healthy_status()
        if s.role8_owned==true then lease.native_role8=true end
        if not lease.prepare_attempted then
            lease.prepare_attempted=true;acknowledged(native:prepare(view.base));s=healthy_status()
        end
        -- prepare stages discovery/hooks only. The native start transaction
        -- constructs the whole widget tree before it activates the HUD role.
        if s.prepared~=true then report('Preparing native mission HUD');return end
        if not lease.start_attempted then
            lease.start_attempted=true;acknowledged(native:start(view.base));s=healthy_status()
            if s.role8_owned==true then lease.native_role8=true end
        end
        if s.active~=true or s.widgets_ready~=true then report('Waiting for native mission HUD activation');return end
        local fresh,reason=observed()
        assert(same(lease,fresh)and ready(fresh),reason or 'HUD actor or controls changed before role8 activation')
        validate(fresh)
        if not lease.role8_ready then
            local present=role(fresh)
            assert(not present or lease.native_role8,'HUD role8 was introduced by another operation')
            if not present then
                lease.role8_attempted=true
                backend:call('add',fresh.base.pc+0x50,lease.mask)
                assert(role(fresh),'HUD role8 activation was not acknowledged')
            end
            lease.role8_ready=true
        else assert(role(fresh),'Owned HUD role8 changed')end
        acknowledged(native:tick(dt,fresh.base.pm,fresh.pm_entity))
        report('Mission HUD active on the ship bridge')
    end
    function self:set_enabled(value)
        assert(type(value)=='boolean','HUD Enabled must be boolean')
        if closing then return false,'HUD controller is unloading'end
        if value~=self.enabled then fault=nil end
        self.enabled=value;return true
    end
    function self:update(dt)
        if not self.active and(closing or not self.enabled or fault)then return end
        assert(type(dt)=='number'and dt==dt and dt>=0 and dt<math.huge,'HUD dt must be finite and nonnegative')
        local view,why=observed()
        if self.active then
            if self.active.stopping or closing or not self.enabled or fault or not same(self.active,view)or not ready(view)then
                clean(view);return
            end
        elseif not ready(view)then report(why or view and view.reason or 'Waiting for normal ship controls');return
        else
            local ok,problem=pcall(function()
                validate(view);assert(not role(view),'HUD role8 is already owned by another operation')
                assert(not action(view),'Native weapon action is already active')
                -- Keep our own immutable ownership fields; observers may reuse a table.
                local b={};for key,value in pairs(view.base)do b[key]=value end
                self.active={token=view.token,base=b,pm_entity=view.pm_entity,mask=backend:mask(ROLE8)}
            end)
            if not ok then fault=tostring(problem);report('HUD activation stopped: '..fault);return end
        end
        local ok,problem=pcall(advance,view,dt)
        if not ok then
            fault=tostring(problem);report('HUD activation stopped: '..fault)
            if self.active then self.active.stopping=true;clean(view)end
        end
    end
    function self:cleanup()return clean(observed())end
    function self:shutdown()
        closing=true;self.enabled=false
        if not self.active then return true end
        return self:cleanup()
    end
    function self:is_clean()return self.active==nil end
    function self:error()return fault end
    function self:status()
        if self.active and self.active.stopping then return message end
        if fault then return 'HUD activation stopped: '..fault end
        if not self.enabled and not self.active then return 'Disabled'end
        return message
    end
    return self
end
return M
