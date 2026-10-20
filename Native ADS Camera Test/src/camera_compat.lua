-- Observe Photo's current local camera lease without acquiring or changing it.
-- Older Photo releases retain their owned ActionCam reader-chain adapter.
local M={}
function M.new(controller,log,G)
    assert(type(controller)=='table' and type(controller.is_enabled)=='function','Camera compatibility controller required')
    G=G or _G;log=log or function()end
    local dbg=rawget(G,'debug') or debug
    local self={}
    local record,closing,conflict=nil,false,false
    local phase,message='idle',nil
    local function report(next_phase,why)
        if phase~=next_phase then phase=next_phase end
        if why~=message and why then log('FPV camera sharing: '..tostring(why))end
        message=why
    end
    local function reader(setter)
        if type(dbg)~='table' or type(dbg.getupvalue)~='function' then
            return false,nil,'Photo camera reader ownership API unavailable'
        end
        for index=1,32 do
            local ok,name,value=pcall(dbg.getupvalue,setter,index)
            if not ok then return false,nil,'Photo camera reader cannot be inspected' end
            if not name then break end
            if name=='input_reader' then
                if value~=nil and type(value)~='function' then return false,nil,'Photo camera reader is invalid'end
                return true,value
            end
        end
        return false,nil,'Photo camera reader contract changed'
    end
    local function provider()
        local owner=rawget(G,'DBF_PHOTO_CAMERA_OWNERSHIP')
        if owner~=nil then
            if type(owner)~='table' or type(owner.held)~='boolean' or owner.available~=true
                or owner.disabled==true then
                return nil,'Photo camera ownership interface unavailable'
            end
            -- Module presence does not establish a live camera lease. Modern
            -- Photo deliberately owns no ActionCam callback or input bridge.
            return owner,nil,'local'
        end
        local api=rawget(G,'DBF_PHOTO_ACTIONCAM_COMPAT')
        if api==nil then
            local package_table=rawget(G,'package')
            local loaded=type(package_table)=='table' and package_table.loaded
            if type(loaded)=='table' and loaded['mods/actioncam/actioncam'] then
                return nil,'ActionCam camera-sharing bridge unavailable'
            end
            return nil
        end
        if type(api)~='table' or type(api.set_input_blocked)~='function' or type(api.held)~='boolean'
            or api.disabled==true or api.available==false then
            return nil,'Photo camera sharing interface unavailable'
        end
        return api,nil,'legacy'
    end
    local function enabled()
        local ok,value=pcall(controller.is_enabled,controller)
        return not ok or type(value)~='boolean' or value
    end
    local function verify(r)
        local api,why,kind=provider()
        if why then return false,why end
        if kind~='legacy' or api~=r.provider or api.set_input_blocked~=r.setter then return false,'Photo camera sharing provider changed'end
        local ok,current,problem=reader(r.setter)
        if not ok then return false,problem end
        if current~=r.shim then return false,'Photo camera reader was replaced; its replacement was preserved'end
        return true
    end
    local function reject(why)
        if record then record.blocking=false end
        conflict=true;report('conflict',why)
        return false,why
    end
    function self:foreign()
        if conflict then return true,message or 'Photo camera sharing requires cleanup'end
        local api,why,kind=provider()
        if why then return true,why end
        if record then
            local ok,problem=verify(record)
            if not ok then return true,problem end
        end
        if api and api.held then return true,'Photo Mode owns the camera'end
        if api and kind=='legacy' and not record then
            local ok,_,problem=reader(api.set_input_blocked)
            if not ok then return true,problem end
        end
        return false
    end
    function self:is_clean()return record==nil end
    function self:prepare()
        if closing then return false,'Camera compatibility is shutting down'end
        if conflict then return false,message or 'Photo camera sharing requires cleanup'end
        local api,why,kind=provider()
        if why then return reject(why)end
        if record then
            local ok,problem=verify(record)
            if not ok then return reject(problem)end
        end
        if api and api.held then report('foreign','Photo Mode owns the camera');return false,message end
        if not api then report('absent');return true end
        if kind=='local' then report('observing');return true end
        if record then record.blocking=true;report('active');return true end
        local readable,previous,problem=reader(api.set_input_blocked)
        if not readable then return reject(problem)end
        local r={provider=api,setter=api.set_input_blocked,previous=previous,blocking=true,reading=false}
        r.shim=function()
            -- Always honor the older callback. Errors and non-boolean results
            -- preserve Photo's conservative input_blocked contract.
            if r.reading then return true end
            r.reading=true
            local blocked=false
            if r.previous then
                local ok,value=pcall(r.previous)
                blocked=not ok or value~=false
            end
            r.reading=false
            if blocked then return true end
            return r.blocking and enabled() and r.provider.held~=true or false
        end
        -- Retain the record before the setter: a throwing setter may already
        -- have installed our function and must remain reviewably restorable.
        record=r
        local called,accepted,issue=pcall(r.setter,r.shim)
        local owned,current,ownership_problem=reader(r.setter)
        if not called or accepted==false or not owned or current~=r.shim then
            return reject(not called and tostring(accepted) or issue or ownership_problem or 'Photo camera reader installation was not accepted')
        end
        local stable,stability_problem=verify(r)
        if not stable then return reject(stability_problem)end
        report('active');return true
    end
    function self:stop()
        if not record then conflict=false;report('idle');return true end
        local r=record;r.blocking=false
        local ok,current,why=reader(r.setter)
        if not ok then report('cleanup_pending',why);return false,why end
        if current==r.shim then
            local called,value,issue=pcall(r.setter,r.previous)
            local inspected,after,problem=reader(r.setter)
            if not inspected or after==r.shim then
                local reason=not called and tostring(value) or issue or problem or 'Photo camera reader restoration is pending'
                report('cleanup_pending',reason);return false,reason
            end
            -- Readback proves our callback is gone, including a setter which
            -- throws after restoring it. Any foreign replacement is preserved.
        end
        record=nil;conflict=false;report('idle');return true
    end
    function self:shutdown()closing=true;return self:stop()end
    function self:update()
        if closing or not enabled() then return self:stop()end
        if conflict then return false,message end
        local api,why=provider()
        if why then return reject(why)end
        if record then
            local ok,problem=verify(record)
            if not ok then return reject(problem)end
        end
        if api and api.held then
            if record then record.blocking=false end
            report('foreign','Photo Mode owns the camera');return true,message
        end
        return self:prepare()
    end
    function self:result()
        local foreign,why=self:foreign()
        local installed=false
        if record then local ok,current=reader(record.setter);installed=ok and current==record.shim end
        return {phase=phase,installed=installed,blocking=installed and record.blocking and enabled()
            and record.provider.held~=true or false,foreign=foreign,foreign_reason=why,
            cleanup_pending=phase=='cleanup_pending',error_message=message,closing=closing}
    end
    function self:status()
        local value=self:result()
        return value.phase..'; ActionCam blocked='..tostring(value.blocking)..'; Photo owns camera='..tostring(value.foreign)
    end
    return self
end
return M
