-- Native Mod Bindings owns mapping and activation. No physical-key polling.
local M={}
local ID='bridge_combat.toggle'
function M.new(options)
    options=options or {}
    local globals=options.globals or _G
    local toggle=assert(options.toggle,'Toggle callback is required')
    local allowed=assert(options.allowed,'Input ownership check is required')
    local log=options.log or function()end
    local self={provider=nil,registered=false,stopping=false}
    local armed,down,last_problem=false,false,nil
    local refused_revision
    local function reset()armed,down=false,false end
    local function problem(why)
        why=tostring(why)
        if why~=last_problem then log('Binding: '..why);last_problem=why end
        return false,why
    end
    function self:update()
        if self.stopping then return end
        local api=rawget(globals,'ModBindingsMenu')
        if api~=self.provider then self.provider=api;self.registered=false;refused_revision=nil;reset()end
        if type(api)~='table'or api.api~=1 or (api.version~=3 and api.version~=4)
            or type(api.register_binding)~='function'or type(api.is_down)~='function'
            or type(api.ready)~='function' then
            reset();return problem('Waiting for native Mod Bindings Menu')
        end
        if not self.registered then
            local revision=api.revision or false
            if refused_revision==revision then return false,last_problem end
            -- MBM reserves fixed slot2 for third-party mods. Automatic slots
            -- can be exhausted even while this dedicated action is unused.
            local called,ok,why=pcall(api.register_binding,ID,'Toggle Bridge Combat',2,{category='Bridge Combat'})
            if not called or ok~=true then refused_revision=revision;reset();return problem(called and why or ok)end
            refused_revision=nil
            self.registered=true
        end
        local called,ready=pcall(api.ready)
        if not called or ready~=true then reset();return end
        local read,value=pcall(api.is_down,ID)
        if not read or type(value)~='boolean' then reset();return end
        -- Observe releases even while menus/focus block activation. Reload or
        -- unavailable input must see an up state before accepting another edge.
        if not value then armed,down=true,false;return true end
        local pressed=armed and not down;down=true
        if not pressed then return true end
        local checked,permitted=pcall(allowed)
        if not checked or permitted~=true then return true end
        local ran,ok,why=pcall(toggle)
        if not ran or ok~=true then return problem(ran and why or ok)end
        last_problem=nil
        return true
    end
    function self:shutdown()self.stopping=true;reset();return true end
    return self
end
return M
