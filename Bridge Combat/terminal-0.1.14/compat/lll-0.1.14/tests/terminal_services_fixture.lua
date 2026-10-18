local root=assert(BRIDGE_COMBAT_TEST_ROOT)..'/compat/lll-0.1.14/'
local Service=dofile(root..'src/terminal_services.lua')
local f={focus=true,cursor=false,clip=false,foreground=true,captured=0,t=0,dx=12,dy=-8,wheel=120,installs=0,releases=0}
local W={};for _,field in ipairs({'mouse_focus','show_cursor','clip_cursor'})do local key=({mouse_focus='focus',show_cursor='cursor',clip_cursor='clip'})[field];W[field]=function()return f[key]end;W['set_'..field]=function(v)if f.refuse_restore and key=='focus'and v then return end;f[key]=v end end
local native={bc_terminal_install=function()f.installs=f.installs+1;return 1 end,bc_terminal_capture=function(v)f.captured=v;return 1 end,
 bc_terminal_captured=function()return f.captured end,bc_terminal_release=function()f.releases=f.releases+1;f.captured=0 end,
 bc_terminal_seconds=function()f.t=f.t+.01;return f.t end,bc_terminal_mouse_x=function()local v=f.dx;f.dx=0;return v end,
 bc_terminal_mouse_y=function()local v=f.dy;f.dy=0;return v end,bc_terminal_wheel=function()local v=f.wheel;f.wheel=0;return v end}
local globals={};local service=Service.new({globals=globals,sr={Window=W},platform={native=native,kernel={BCI_pid=function()return 42 end},user={
 BCI_foreground=function()return f.foreground and 1 or nil end,BCI_window_pid=function(w,p)p[0]=w and 42 or 0 end,BCI_key=function()return 0 end}}})
local input=service.camera_input
for _,name in ipairs({'acquire','set_focus','sample','menu_sample','release','down','focused','now'})do assert(type(input[name])=='function','Terminal input contract missing: '..name)end
assert(globals.DBFMCM==nil and service.menu_binding_status().editing==false)
assert(input.acquire());assert(not f.focus and not f.cursor and f.clip and f.captured==3)
assert(not input.acquire());assert(input.set_focus(false));local s=assert(input.sample());assert(s.mouse_x==12 and s.mouse_y==-8 and s.wheel==120)
s=assert(input.sample());assert(s.mouse_x==0 and s.mouse_y==0 and s.wheel==0)
f.refuse_restore=true;assert(input.release()==false);assert(not input.acquire(),'Pending restore must retain ownership')
f.refuse_restore=false;assert(input.release());assert(f.focus and not f.cursor and not f.clip)
local releases=f.releases;assert(input.release());assert(releases==f.releases,'Idle release touched native capture')
f.focus=false;assert(not input.acquire());f.focus=true
globals.DBFMCM={is_open=function()return true end};assert(not input.acquire());globals.DBFMCM=nil
assert(input.acquire());f.foreground=false;assert(input.sample()==nil);assert(f.focus and not f.clip and f.captured==0)
assert(service.shutdown());assert(globals.DBFMCM==nil)
local spec=dofile(root..'src/terminal_input_binary.lua');local data=spec.hex:gsub('%x%x',function(v)return string.char(tonumber(v,16))end)
assert(dofile(root..'src/sha256.lua')(data)==spec.sha256 and data:sub(1,2)=='MZ')
print('PASS standalone input: no MCM; raw deltas and wheel, exclusive capture, pending restore, foreground loss, idle release, optional menu exclusion and binary integrity')
