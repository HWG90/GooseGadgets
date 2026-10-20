-- Explicit loader/UI calls only. No frame hook, timer, worker or Lua native callback.
local M = {}
function M.new(native, api, log)
    assert(type(api)=='table' and type(api.register)=='function', 'Enable DBF-MCM before Height Over Bore')
    log=log or function()end
    local self={opened=false,stopping=false,handle=nil}
    local last
    local function apply(value)
        assert(type(value)=='boolean', 'Enabled must be boolean')
        assert(self.opened and not self.stopping, 'Height Over Bore is stopping')
        if value==last then return true end
        assert(tonumber(native.HBTP_SetEnabled(value and 1 or 0))==1, 'Native setting rejected; disable HoB to restore')
        last=value
        return true
    end
    function self:shutdown()
        self.stopping=true
        if self.opened then
            local result=tonumber(native.HBTP_Close())
            if result~=1 then return false,'Native cleanup incomplete; retain helper and retry explicit cleanup' end
            self.opened=false
        end
        if self.handle then self.handle.unregister();self.handle=nil end
        return true
    end
    function self:start()
        assert(not self.opened and not self.handle, 'Height Over Bore already started')
        local result=tonumber(native.HBTP_OpenHoB(0))
        self.opened=result~=0 -- 2 retains native cleanup intent, too.
        assert(result==1, result==2 and 'Native startup cleanup is pending' or 'Native admission rejected; no activation')
        self.stopping=false
        self.handle=api.register({id='goose_hob_native_review',name='Height Over Bore Native Review',
            description='Native event-driven projectile ADS correction; native hip fire, third-person and beams.',
            pages={{id='general',name='General',require_confirmation=false,controls={
                {id='enabled',type='toggle',label='Enabled',default=false,require_confirmation=false,on_change=apply},
                {id='retry_cleanup',type='button',label='Retry cleanup',on_activate=function()
                    local ok,why=self:shutdown();assert(ok,why)
                end},
            }}}})
        assert(type(self.handle)=='table' and type(self.handle.get)=='function' and type(self.handle.unregister)=='function','Unsupported MCM handle')
        apply(self.handle.get('enabled'))
        log('Native HoB subscribed; equip and first-person transitions run without frame polling')
        return true
    end
    return self
end
return M
