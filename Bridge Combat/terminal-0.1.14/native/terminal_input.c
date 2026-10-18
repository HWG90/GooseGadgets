/* Bridge Combat-owned terminal input. Derived from Goose DBF-MCM input capture.
 * No menu framework, loader, game hook, or Photo Mode service is included. */
/* Per-window input capture. No Lua callbacks from the window thread.
 * Does not hook another process or suppress OS shortcuts globally.
 */
#define WIN32_LEAN_AND_MEAN
#define UNICODE
#define _UNICODE
#include <windows.h>

static HWND owner;
static WNDPROC previous;
static volatile LONG captured;
/* Hardware cursor artwork: 1 Windows arrow, 2 engine-selected resource.
 * This changes WM_SETCURSOR only; gameplay input gating is unchanged. */
static volatile LONG cursor_mode = 2;
__declspec(dllexport) int bc_terminal_set_cursor_mode(int mode) {
    if (mode != 1 && mode != 2) return 0;
    InterlockedExchange(&cursor_mode, mode);return 1;
}
__declspec(dllexport) int bc_terminal_cursor_mode(void) {
    return (int)InterlockedCompareExchange(&cursor_mode,0,0);
}

static volatile LONG wheel;
static volatile LONG look_x, look_y;
static volatile LONG keys[256];
static volatile LONG buttons[5];
static volatile LONG pending_keys,pending_buttons;
static volatile LONG previous_raw[256];
static volatile LONG previous_legacy[256];
static volatile LONG previous_mouse_raw,previous_mouse_legacy;

__declspec(dllexport) int bc_terminal_policy(UINT message, UINT raw_type, int capture) {
    if (!capture) return 0;
    if (message == WM_INPUT) return raw_type == RIM_TYPEKEYBOARD || raw_type == RIM_TYPEMOUSE;
    if (message >= WM_KEYFIRST && message <= WM_KEYLAST) return 1;
    if (capture == 2 && message == WM_MOUSEMOVE) return 0;
    if (message >= WM_MOUSEFIRST && message <= WM_MOUSELAST) return 1;
    return 0;
}

static int keyboard_gate(UINT key, int up, int capture) {
    if (key >= 256) return capture;
    if (capture) { LONG next=up?0:1;LONG old=InterlockedExchange(&keys[key],next);if(old!=next)InterlockedExchangeAdd(&pending_keys,next?1:-1); return 1; }
    if (InterlockedCompareExchange(&keys[key], 0, 0)) {
        if (up && InterlockedExchange(&keys[key],0))InterlockedDecrement(&pending_keys);
        return 1;
    }
    return 0;
}

static int mouse_gate(USHORT flags, int capture) {
    int gate = capture == 2 ? flags != 0 : capture;
    const USHORT down[5] = {RI_MOUSE_LEFT_BUTTON_DOWN,RI_MOUSE_RIGHT_BUTTON_DOWN,
        RI_MOUSE_MIDDLE_BUTTON_DOWN,RI_MOUSE_BUTTON_4_DOWN,RI_MOUSE_BUTTON_5_DOWN};
    const USHORT up[5] = {RI_MOUSE_LEFT_BUTTON_UP,RI_MOUSE_RIGHT_BUTTON_UP,
        RI_MOUSE_MIDDLE_BUTTON_UP,RI_MOUSE_BUTTON_4_UP,RI_MOUSE_BUTTON_5_UP};
    for (int i=0; i<5; ++i) {
        if (capture != 2 && InterlockedCompareExchange(&buttons[i],0,0)) gate=1;
        if (capture && (flags & down[i]) && !InterlockedExchange(&buttons[i],1))InterlockedIncrement(&pending_buttons);
        if ((flags & up[i]) && InterlockedExchange(&buttons[i],0))InterlockedDecrement(&pending_buttons);
    }
    return gate;
}

/* A key already held on entry must release to gameplay AND retire any
 * repeated-down tracking accumulated while the terminal owned input. */
static int previous_keyboard_release(volatile LONG *held,UINT key,int up) {
    if(key>=256||!up||!InterlockedExchange(&held[key],0))return 0;
    if(InterlockedExchange(&keys[key],0))InterlockedDecrement(&pending_keys);
    return 1;
}
static int previous_mouse_release(volatile LONG *held, USHORT flags) {
    LONG released=InterlockedCompareExchange(held,0,0) & flags;
    if (!released) return 0;
    InterlockedAnd(held,~released);
    const USHORT up[5]={RI_MOUSE_LEFT_BUTTON_UP,RI_MOUSE_RIGHT_BUTTON_UP,RI_MOUSE_MIDDLE_BUTTON_UP,RI_MOUSE_BUTTON_4_UP,RI_MOUSE_BUTTON_5_UP};
    for(int i=0;i<5;++i)if((released&up[i])&&InterlockedExchange(&buttons[i],0))InterlockedDecrement(&pending_buttons);
    return 1;
}
static USHORT mouse_flags(UINT msg, WPARAM wp) {
    switch (msg) {
    case WM_LBUTTONDOWN:case WM_LBUTTONDBLCLK:return RI_MOUSE_LEFT_BUTTON_DOWN;
    case WM_LBUTTONUP:return RI_MOUSE_LEFT_BUTTON_UP;
    case WM_RBUTTONDOWN:case WM_RBUTTONDBLCLK:return RI_MOUSE_RIGHT_BUTTON_DOWN;
    case WM_RBUTTONUP:return RI_MOUSE_RIGHT_BUTTON_UP;
    case WM_MBUTTONDOWN:case WM_MBUTTONDBLCLK:return RI_MOUSE_MIDDLE_BUTTON_DOWN;
    case WM_MBUTTONUP:return RI_MOUSE_MIDDLE_BUTTON_UP;
    case WM_XBUTTONDOWN:case WM_XBUTTONDBLCLK:return HIWORD(wp)==XBUTTON1?RI_MOUSE_BUTTON_4_DOWN:RI_MOUSE_BUTTON_5_DOWN;
    case WM_XBUTTONUP:return HIWORD(wp)==XBUTTON1?RI_MOUSE_BUTTON_4_UP:RI_MOUSE_BUTTON_5_UP;
    default:return 0;
    }
}

static LRESULT CALLBACK guarded_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if(!InterlockedCompareExchange(&captured,0,0)&&!InterlockedCompareExchange(&pending_keys,0,0)&&!InterlockedCompareExchange(&pending_buttons,0,0))return CallWindowProcW(previous,hwnd,msg,wp,lp);
    int capture = hwnd==owner && GetForegroundWindow()==owner ? (int)InterlockedCompareExchange(&captured,0,0) : 0;
    if (msg==WM_KILLFOCUS || (msg==WM_ACTIVATEAPP && !wp)) {
        InterlockedExchange(&captured,0);
        InterlockedExchange(&look_x,0);InterlockedExchange(&look_y,0);
        for (int i=0;i<256;++i) { InterlockedExchange(&keys[i],0); InterlockedExchange(&previous_raw[i],0); InterlockedExchange(&previous_legacy[i],0); }
        for (int i=0;i<5;++i) InterlockedExchange(&buttons[i],0);
        InterlockedExchange(&previous_mouse_raw,0);InterlockedExchange(&previous_mouse_legacy,0);
        InterlockedExchange(&pending_keys,0);InterlockedExchange(&pending_buttons,0);capture=0;
    }
    if (msg==WM_INPUT) {
        RAWINPUT raw;UINT size=sizeof raw;
        UINT read=GetRawInputData((HRAWINPUT)lp,RID_INPUT,&raw,&size,sizeof(RAWINPUTHEADER));
        if (read!=(UINT)-1 && read>=sizeof(RAWINPUTHEADER)) {
            int block=0;
            if (raw.header.dwType==RIM_TYPEKEYBOARD) {
                UINT key=raw.data.keyboard.VKey;int up=(raw.data.keyboard.Flags&RI_KEY_BREAK)!=0;
                /* Release keys that the game already saw before capture. */
                if (previous_keyboard_release(previous_raw,key,up))block=0;
                else block=keyboard_gate(key,up,capture);
            }
            else if (raw.header.dwType==RIM_TYPEMOUSE) {
                if (capture && (raw.data.mouse.usButtonFlags & RI_MOUSE_WHEEL))
                    InterlockedExchangeAdd(&wheel,(SHORT)raw.data.mouse.usButtonData);
                if (capture == 3 && !(raw.data.mouse.usFlags & MOUSE_MOVE_ABSOLUTE)) {
                    InterlockedExchangeAdd(&look_x,raw.data.mouse.lLastX);
                    InterlockedExchangeAdd(&look_y,raw.data.mouse.lLastY);
                }
                block=previous_mouse_release(&previous_mouse_raw,raw.data.mouse.usButtonFlags) ? 0 : mouse_gate(raw.data.mouse.usButtonFlags,capture);
            }
            if (block) {
                /* WM_INPUT foreground packets require DefWindowProc cleanup. */
                return DefWindowProcW(hwnd,msg,wp,lp);
            }
        } else if (capture) return DefWindowProcW(hwnd,msg,wp,lp);
    } else if (msg==WM_KEYDOWN || msg==WM_SYSKEYDOWN || msg==WM_KEYUP || msg==WM_SYSKEYUP) {
        UINT key=(UINT)wp;int up=msg==WM_KEYUP || msg==WM_SYSKEYUP;
        if (!(previous_keyboard_release(previous_legacy,key,up)) && keyboard_gate(key,up,capture))return 0;
    } else if (msg>=WM_MOUSEFIRST && msg<=WM_MOUSELAST) {
        if (!previous_mouse_release(&previous_mouse_legacy,mouse_flags(msg,wp)) && mouse_gate(mouse_flags(msg,wp),capture))return 0;
    } else if (bc_terminal_policy(msg,99,capture))return 0;
    if (capture == 1 && msg==WM_SETCURSOR && bc_terminal_cursor_mode()==1) { SetCursor(LoadCursorW(NULL,IDC_ARROW));return TRUE; }
    return CallWindowProcW(previous,hwnd,msg,wp,lp);
}

__declspec(dllexport) int bc_terminal_install(HWND hwnd) {
    DWORD pid=0;GetWindowThreadProcessId(hwnd,&pid);
    if (!IsWindow(hwnd) || pid!=GetCurrentProcessId())return 0;
    if (owner) return owner==hwnd;
    previous=(WNDPROC)GetWindowLongPtrW(hwnd,GWLP_WNDPROC);
    if (!previous)return 0;
    /* Pin before installing a callback that other subclasses may retain. */
    HMODULE module;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_PIN,
        (LPCWSTR)guarded_proc,&module))return 0;
    owner=hwnd;SetLastError(0);
    LONG_PTR old=SetWindowLongPtrW(hwnd,GWLP_WNDPROC,(LONG_PTR)guarded_proc);
    if (!old && GetLastError()) {owner=NULL;previous=NULL;return 0;}
    previous=(WNDPROC)old;
    return 1;
}

__declspec(dllexport) int bc_terminal_capture(int active) {
    if (active < 0 || active > 3 || !owner || !IsWindow(owner))return 0;
    if (active && GetForegroundWindow()!=owner)return 0;
    if (active && !InterlockedCompareExchange(&captured,0,0)) {
        /* A held gameplay mouse button cannot be released through a raw packet
         * without also forwarding its movement. Refuse acquisition until up.
         */
        const int mouse_keys[5]={VK_LBUTTON,VK_RBUTTON,VK_MBUTTON,VK_XBUTTON1,VK_XBUTTON2};
        LONG held_mouse=0;
        const USHORT releases[5]={RI_MOUSE_LEFT_BUTTON_UP,RI_MOUSE_RIGHT_BUTTON_UP,RI_MOUSE_MIDDLE_BUTTON_UP,RI_MOUSE_BUTTON_4_UP,RI_MOUSE_BUTTON_5_UP};
        for (int i=0;i<5;++i)if (GetAsyncKeyState(mouse_keys[i])&0x8000) {
            if (active != 3) return 0;
            held_mouse |= releases[i];
        }
        InterlockedExchange(&previous_mouse_raw,held_mouse);InterlockedExchange(&previous_mouse_legacy,held_mouse);
        for (int i=0;i<256;++i) {
            LONG down=(GetAsyncKeyState(i)&0x8000)?1:0;
            InterlockedExchange(&previous_raw[i],down);InterlockedExchange(&previous_legacy[i],down);
        }
    }
    if (!active || !InterlockedCompareExchange(&captured,0,0))InterlockedExchange(&wheel,0);
    InterlockedExchange(&look_x,0);InterlockedExchange(&look_y,0);
    InterlockedExchange(&captured,active);return 1;
}
__declspec(dllexport) int bc_terminal_captured(void) {
    return owner && GetForegroundWindow()==owner ? (int)InterlockedCompareExchange(&captured,0,0) : 0;
}
__declspec(dllexport) void bc_terminal_release(void) {
    InterlockedExchange(&cursor_mode,2);
    InterlockedExchange(&captured,0);InterlockedExchange(&wheel,0);
    InterlockedExchange(&look_x,0);InterlockedExchange(&look_y,0);
    /* Keep an inert callback until held menu keys/buttons have released.
     * Its DLL is pinned; all ordinary traffic continues through previous.
     */
}

__declspec(dllexport) int bc_terminal_wheel(void) { return (int)InterlockedExchange(&wheel,0); }

__declspec(dllexport) int bc_terminal_mouse_x(void) { return (int)InterlockedExchange(&look_x,0); }
__declspec(dllexport) int bc_terminal_mouse_y(void) { return (int)InterlockedExchange(&look_y,0); }

__declspec(dllexport) double bc_terminal_seconds(void) { LARGE_INTEGER now,frequency;QueryPerformanceCounter(&now);QueryPerformanceFrequency(&frequency);return (double)now.QuadPart/(double)frequency.QuadPart; }
