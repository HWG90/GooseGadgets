-- Bridge Combat owns its input lease; MCM is only an optional observer.
local M={}
function M.new(o)
    local globals=o.globals or _G;local sr=o.sr or assert(globals.stingray)
    local native,user,kernel,ffi,pid,process;local saved,token,mode,last;local self={}
    if o.platform then
        ffi=require('ffi');native=o.platform.native;user=o.platform.user;kernel=o.platform.kernel
        pid=ffi.new('uint32_t[1]');process=kernel.BCI_pid()
    end
    local function init()
        if native then return end
        ffi=require('ffi')
        pcall(ffi.cdef,[[
        int bc_terminal_install(void *);int bc_terminal_capture(int);int bc_terminal_captured(void);void bc_terminal_release(void);
        int bc_terminal_wheel(void);int bc_terminal_mouse_x(void);int bc_terminal_mouse_y(void);double bc_terminal_seconds(void);
        void *BCI_foreground(void) __asm__("GetForegroundWindow");uint32_t BCI_window_pid(void *,uint32_t *) __asm__("GetWindowThreadProcessId");
        uint32_t BCI_pid(void) __asm__("GetCurrentProcessId");short BCI_key(int) __asm__("GetAsyncKeyState");
        typedef struct {int32_t x,y;} BCIPoint;
        int BCI_cursor(BCIPoint *) __asm__("GetCursorPos");int BCI_client(void *,BCIPoint *) __asm__("ScreenToClient");int BCI_rect(void *,int32_t *) __asm__("GetClientRect");
        int BCI_mkdir(const char *,void *) __asm__("CreateDirectoryA");
        ]])
        user=ffi.load('user32');kernel=ffi.load('kernel32');pid=ffi.new('uint32_t[1]');process=kernel.BCI_pid()
        local spec=o.load('src/terminal_input_binary.lua');local data=spec.hex:gsub('%x%x',function(v)return string.char(tonumber(v,16))end)
        assert(o.load('src/sha256.lua')(data)==spec.sha256,'Terminal input integrity differs')
        local root=assert(os.getenv('LOCALAPPDATA'))..'/Goose';kernel.BCI_mkdir(root,nil);root=root..'/BridgeCombat';kernel.BCI_mkdir(root,nil);root=root..'/native';kernel.BCI_mkdir(root,nil)
        local path=root..'/BridgeCombatInput-'..spec.sha256:sub(1,12)..'.dll';local file=io.open(path,'rb')
        if file then local existing=file:read('*a');file:close();assert(existing==data,'Terminal input binary collision')
        else file=assert(io.open(path,'wb'));assert(file:write(data));file:close();file=assert(io.open(path,'rb'));local readback=file:read('*a');file:close();assert(readback==data,'Terminal input write differs')end
        native=ffi.load(path)
    end
    local function foreground()
        init();local w=user.BCI_foreground();user.BCI_window_pid(w,pid);if pid[0]==process then return w end
    end
    local function other()local m=rawget(globals,'DBFMCM');return m end
    function self.is_open()local m=other();return m and type(m.is_open)=='function'and m.is_open()==true or false end
    function self.menu_binding_status()
        local m=other();local state=m and m.menu_binding_status and m.menu_binding_status()
        return {focused=foreground()~=nil,editing=state and state.editing==true or false}
    end
    local input={api=2,isolated_look=true};self.camera_input=input
    function input.now()init();return tonumber(native.bc_terminal_seconds())end
    function input.focused()return foreground()~=nil end
    local guard_backend
    function input.chat_active()
        if o.chat_active then return o.chat_active()end
        local ok,active=pcall(function()
            guard_backend=guard_backend or o.load('src/backend.lua').new()
            local game,stamp=guard_backend:_module();assert(game and stamp==0x6AB3B43F,'Terminal chat build differs')
            local chat=assert(guard_backend:ptr(game+0x346D538));local value=assert(guard_backend:u8(chat+0x27E50))
            assert(guard_backend:ptr(game+0x346D538)==chat,'Terminal chat owner changed');return value~=0
        end)
        return not ok or active
    end

    function input.down(key)return foreground()~=nil and require('bit').band(tonumber(user.BCI_key(key)),0x8000)~=0 end
    local fields={{'mouse_focus','set_mouse_focus'},{'show_cursor','set_show_cursor'},{'clip_cursor','set_clip_cursor'}}
    function input.release()
        if not token then return true end
        native.bc_terminal_release();if native.bc_terminal_captured()~=0 then return false,'Terminal input release pending'end
        for i,f in ipairs(fields)do sr.Window[f[2]](saved[i])end
        for i,f in ipairs(fields)do if sr.Window[f[1]]()~=saved[i]then return false,'Terminal window restoration pending'end end
        token,saved=nil,nil;return true
    end
    function input.acquire()
        if token then return nil,'Terminal already owns input'end
        local w=foreground();if not w or self.is_open()or sr.Window.mouse_focus()~=true then return nil,'Another input owner is active'end
        saved={sr.Window.mouse_focus(),sr.Window.show_cursor(),sr.Window.clip_cursor()};token={}
        local ok,why=pcall(function()
            assert(native.bc_terminal_install(w)~=0 and native.bc_terminal_capture(3)~=0,'Terminal native capture unavailable')
            sr.Window.set_mouse_focus(false);sr.Window.set_show_cursor(false);sr.Window.set_clip_cursor(true)
            assert(not sr.Window.mouse_focus()and not sr.Window.show_cursor()and sr.Window.clip_cursor(),'Terminal window capture refused')
        end)
        if not ok then input.release();return nil,tostring(why)end
        mode=3;last=input.now();return token
    end
    function input.set_focus(menu)
        if not token then return false,'Terminal does not own input'end
        local next_mode=menu and 1 or 3
        if not foreground()or native.bc_terminal_capture(next_mode)==0 then return false,'Terminal focus switch refused'end
        sr.Window.set_show_cursor(menu);sr.Window.set_mouse_focus(false);sr.Window.set_clip_cursor(true)
        if sr.Window.show_cursor()~=menu or sr.Window.mouse_focus()~=false or sr.Window.clip_cursor()~=true then return false,'Terminal focus readback pending'end
        mode=next_mode;last=input.now();return true
    end
    function input.menu_sample()
        if not token or mode~=1 or not foreground()or self.is_open()or native.bc_terminal_captured()~=1 then input.release();return nil end
        local point=ffi.new('BCIPoint[1]');local rect=ffi.new('int32_t[4]');local w=foreground()
        if user.BCI_cursor(point)==0 or user.BCI_client(w,point)==0 or user.BCI_rect(w,rect)==0 or rect[2]<=0 or rect[3]<=0 then return nil end
        local sw,sh=sr.Gui.resolution();local now=input.now();local dt=math.max(0,math.min(.1,now-last));last=now
        return {x=point[0].x*sw/rect[2],y=sh-point[0].y*sh/rect[3],click=input.down(1),wheel=tonumber(native.bc_terminal_wheel()),dt=dt}
    end

    function input.sample()
        if not token or not foreground()or self.is_open()or native.bc_terminal_captured()~=mode then input.release();return nil end
        local now=input.now();local dt=math.max(0,math.min(.1,now-last));last=now
        return {mouse_x=tonumber(native.bc_terminal_mouse_x()),mouse_y=tonumber(native.bc_terminal_mouse_y()),wheel=tonumber(native.bc_terminal_wheel()),dt=dt}
    end
    function self.shutdown()return input.release()end
    return self
end
return M
