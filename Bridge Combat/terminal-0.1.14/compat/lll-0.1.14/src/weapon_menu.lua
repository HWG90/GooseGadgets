-- Persistent native menu coordinator. No timer, automatic rearm or game access
-- on import/new. The native owner alone proves actor/UI lifetime and handoff.
local M={}
local function clean(s)return type(s)=='table'and s.stopped==true and not s.owned and not s.pending and not s.role8_owned end
local function id(n)return type(n)=='number'and n%1==0 and n>0 and n<4294967295 end
function M.new(options)
    assert(type(options)=='table','Native weapon menu dependencies required')
    local native=options.native or options.load('src/weapon_menu_native.lua').new({load=options.load,dir=options.dir,
        read=options.read,globals=options.globals})
    local log=options.log or function()end
    local now=options.now or os.clock
    local self={token=nil,reason='Native weapon menu waiting',retry_at=0}
    local last_message
    local function report(reason)self.reason=reason;if last_message~=reason then log('Weapon menu: '..tostring(reason));last_message=reason end end
    local function state()local ok,s=pcall(native.status,native);if ok and type(s)=='table'then return s end;return nil end
    function self:is_clean()return clean(state())end
    function self:cleanup()
        if self:is_clean()then self.token=nil;return true end
        local called,done,why=pcall(native.stop,native)
        if called and done==true and self:is_clean()then self.token=nil;report('Native weapon menu paused');return true end
        report(not called and tostring(done)or why or 'Native weapon menu cleanup acknowledgement pending')
        return false,self.reason
    end
    function self:update(enabled,view,dt)
        local ready=enabled==true and type(view)=='table'and view.ready==true and view.token~=nil
            and id(view.pid)and id(view.avatar)and type(dt)=='number'and dt==dt and dt>=0 and dt<=1
        if not ready or self.token and self.token~=view.token then
            local done,why=self:cleanup();if done~=true then return false,why end
            self.retry_at=0
            report(enabled and 'Waiting for supported bridge controls and native menu ownership'or 'Native weapon menu disabled')
            return true
        end
        if not self.token then
            if not self:is_clean()then return self:cleanup()end
            if now()<self.retry_at then return false,self.reason end
            -- Journal the Lua identity before a potentially interrupted native
            -- acquire. A failed/unknown native journal must never be replayed.
            self.token=view.token;self.pid,self.avatar=view.pid,view.avatar
            local called,done,why=pcall(native.acquire,native,view.pid,view.avatar)
            local s=state()
            if called and done==true and s and s.active and s.owned and s.role8_owned and not s.pending then
                report('Native weapon menu active');return true
            end
            if clean(s)then self.token=nil;self.retry_at=now()+1 end
            report(not called and tostring(done)or why or 'Native weapon menu activation acknowledgement pending')
            return false,self.reason
        end
        local called,done,why=pcall(native.tick,native,dt,view.pid,view.avatar)
        local s=state()
        if clean(s)then self.token=nil;report('Native weapon menu retired; waiting for fresh acquisition');return true end
        if called and done==true and s and s.active and s.owned and s.role8_owned and not s.pending then
            report('Native weapon menu active');return true
        end
        report(not called and tostring(done)or why or 'Native weapon menu lifetime acknowledgement pending')
        return false,self.reason
    end
    function self:update_settled(dt)
        -- Independent native input/presentation service. Combat discovery,
        -- activation and resource refresh are not part of this path.
        if not self.token then return false,'Native weapon menu lifecycle ended'end
        local called,done,why=pcall(native.tick,native,dt,self.pid,self.avatar)
        local s=state()
        if called and done==true and s and s.active and s.owned and s.role8_owned and not s.pending then return true end
        return false,not called and tostring(done)or why or'Native weapon menu lifecycle ended'
    end
    function self:shutdown()return self:cleanup()end
    function self:status()return self.reason end
    return self
end
return M
