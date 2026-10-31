-- Own only client-window confinement while the terminal captures raw mouse input.
local M={}
function M.new()
    local ffi,user,kernel,rect,point,pid,prior,owned
    local self={}
    local function init()
        if ffi then return end;ffi=require('ffi')
        ffi.cdef[[
          void * __stdcall BC_screen_foreground(void) asm("GetForegroundWindow");
          uint32_t __stdcall BC_screen_process(void *, uint32_t *) asm("GetWindowThreadProcessId");
          uint32_t __stdcall BC_screen_self(void) asm("GetCurrentProcessId");
          int __stdcall BC_screen_rect(void *, int32_t *) asm("GetClientRect");
          int __stdcall BC_screen_to_desktop(void *, int32_t *) asm("ClientToScreen");
          int __stdcall BC_screen_get_clip(int32_t *) asm("GetClipCursor");
          int __stdcall BC_screen_clip(const int32_t *) asm("ClipCursor");
        ]]
        user=ffi.load('user32');kernel=ffi.load('kernel32');rect=ffi.new('int32_t[4]');point=ffi.new('int32_t[2]');pid=ffi.new('uint32_t[1]')
    end
    local function same(a,b)for i=0,3 do if a[i]~=b[i]then return false end end;return true end
    function self:release()
        if not owned then return true end
        assert(user.BC_screen_get_clip(rect)~=0,'Cursor confinement readback unavailable')
        if same(rect,owned)then assert(user.BC_screen_clip(prior)~=0,'Cursor confinement restoration pending')end
        owned,prior=nil,nil;return true
    end
    function self:update()
        init();local window=user.BC_screen_foreground();user.BC_screen_process(window,pid)
        if window==nil or pid[0]~=kernel.BC_screen_self()then self:release();return false,'Game focus released'end
        assert(user.BC_screen_rect(window,rect)~=0 and rect[2]>0 and rect[3]>0,'Game client rectangle unavailable')
        point[0],point[1]=0,0;assert(user.BC_screen_to_desktop(window,point)~=0,'Game client origin unavailable')
        local target=ffi.new('int32_t[4]',{point[0],point[1],point[0]+rect[2],point[1]+rect[3]})
        if not owned then prior=ffi.new('int32_t[4]');assert(user.BC_screen_get_clip(prior)~=0,'Previous cursor confinement unavailable')end
        assert(user.BC_screen_get_clip(rect)~=0,'Cursor confinement readback unavailable')
        if not same(rect,target)then assert(user.BC_screen_clip(target)~=0,'Game window confinement refused')end
        owned=target;return true
    end
    function self:focus(enabled)if enabled then return self:update()end;return self:release()end
    return self
end
return M
