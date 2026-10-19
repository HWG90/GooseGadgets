local root=assert(BRIDGE_COMBAT_TEST_ROOT)..'/compat/lll-0.1.14/src/'
local R=dofile(root..'ship_return.lua');local ffi=require('ffi');local tests=0
local function test(n,fn)fn();tests=tests+1;print('PASS ship return '..n)end
local function fixture()
 local f={memory={},reads=0,writes=0,calls=0};local g,e,w,pm,ep,pc,reg,gens,ui,state,aux,rows=0x10000000,0x20000000,0x30000000,0x31000000,0x32000000,0x3153D8B0,0x34000000,0x35000000,0x36000000,0x37000000,0x38000000,0x39000000
 function f.put(a,n,size)for i=0,size-1 do f.memory[a+i]=string.char(n%256);n=math.floor(n/256)end end
 local function zero(a,n)for i=0,n-1 do f.memory[a+i]='\0'end end
 f.put(g+0x346BF98,w,8);f.put(g+0x3326D20,pm,8);f.put(pm+0x110,ep,8);f.put(ep+8,252,4);f.put(ep+12,0x80000f,4);f.put(ep+20,1,1)
 f.put(e+0x1A100F0,reg,8);f.put(reg+0x98,100,4);f.put(reg+0xA0,gens,8);f.put(gens+14,2,1);f.put(g+0x3326340,state,8);f.put(state+0xAC21C,3,4);f.put(g+0x346D538,ui,8)
 for _,off in ipairs({0x24E334,0x4F7078,0x46D900,0x24E398})do f.put(ui+off,1,1)end;f.put(ui+0x46D8F0,0,1)
 f.put(pc+0xFD0,0x20C,4);f.put(pc+0xFD8,0,4);f.put(g+0x3326420,aux,8);f.put(aux+0x58,rows,8);f.put(rows+5,0,1)
 for _,off in ipairs({0x257F78,0x3E8E38,0x267658})do zero(ui+off,4);zero(ui+off+0xE0,32)end
 local io={module=function(n)return n=='game.dll'and g or e,0x4000000,n=='game.dll'and 0x6AB3B43F or 0x6AB382E4 end,
 read=function(a,n)f.reads=f.reads+1;local out={};for i=0,n-1 do assert(f.memory[a+i],'Unexpected read');out[i+1]=f.memory[a+i]end;return table.concat(out)end,
 hashmap=function(a,key)assert(key==252);if a==pm+0xF8 or a==aux+0x30 then return 0 end;error('Unexpected map')end,
 native=function(a,abi,fp,label)assert(a==g+0xAA0BB0 and label=='SHIP_RETURN_ORPHAN_ROLE_REMOVE'and #fp>20);return function(at,mask)
 assert(tonumber(ffi.cast('uintptr_t',at))==pc+0x50 and tonumber(mask[0])==8 and tonumber(mask[1])==0 and tonumber(mask[2])==0);f.calls=f.calls+1;f.put(pc+0xFD0,f.remove_result or 0x204,4)end end}
 local backend={write=function(_,a,s)assert(a==ui+0x24E398 and s=='\0');f.writes=f.writes+1;f.memory[a]=s;return true end}
 f.repair=R.new(io,backend);f.lease={game=g,avatar=251,render=0x40000e};f.view={can_start=true,menu_closed=true,photo=false,fixed_pose=false,context=4,render=0x80000f,base={game=g,world=w,pm=pm,ep=ep,pc=pc,avatar=252,scene=3}};f.status={phase=13,owned=true,pending=true};f.ui,f.pc,f.gens=ui,pc,gens;return f
end
local function run(f)return f.repair:repair(f.lease,f.view,f.status)end
test('once-only role and presentation recovery then zero idle work',function()local f=fixture();assert(f.reads==0);assert(run(f));assert(f.calls==1 and f.writes==1 and f.repair.phase=='done');local n=f.reads;for _=1,100 do assert(run(f))end;assert(f.reads==n and f.calls==1 and f.writes==1)end)
test('already cleared role is never removed again',function()local f=fixture();f.put(f.pc+0xFD0,0x204,4);assert(run(f));assert(f.calls==0 and f.writes==1)end)
test('same body and real Mission are untouched',function()for _,mode in ipairs({'same','mission','open','clean','interrupted'})do local f=fixture();if mode=='same'then f.view.render=f.lease.render elseif mode=='mission'then f.view.base.scene=4 elseif mode=='open'then f.view.menu_closed=false elseif mode=='clean'then f.status.owned=false elseif mode=='interrupted'then f.status.phase=12 end;assert(run(f));assert(f.reads==0 and f.calls==0 and f.writes==0)end end)
test('live original generation and foreign combat context are preserved',function()for _,mode in ipairs({'generation','foreign'})do local f=fixture();if mode=='generation'then f.put(f.gens+14,1,1)else f.put(f.pc+0xFD0,0x20A,4)end;assert(run(f));assert(f.calls==0 and f.writes==0)end end)
test('live Mission widgets and input actions refuse before mutation',function()for _,mode in ipairs({'mission','widget','action'})do local f=fixture();if mode=='mission'then f.put(f.ui+0x46D8F0,1,1)elseif mode=='widget'then f.put(f.ui+0x257F78,1,4)else f.put(f.pc+0xFD8,0x400000,4)end;assert(not pcall(run,f));assert(f.calls==0 and f.writes==0)end end)
print('PASS '..tests..' ship return contracts')

local function preflight_fixture()
 local f=fixture();f.lease={game=f.view.base.game,avatar=f.view.base.avatar,render=f.view.render,pc=f.pc,ep=f.view.base.ep}
 f.view.context=2;f.status={phase=0,owned=false,active=false,pending=false,role8_owned=false}
 f.put(f.gens+15,2,1);f.put(f.pc+0xFD0,0x20A,4);f.remove_result=0x202
 return f
end
local function preflight(f)return f.repair:repair(f.lease,f.view,f.status,true)end
test('unowned current actor preflight clears stale mission presentation once',function()
 local f=preflight_fixture();assert(preflight(f));assert(f.calls==1 and f.writes==1)
 local reads=f.reads;for i=1,100 do assert(preflight(f))end;assert(f.reads==reads and f.calls==1 and f.writes==1)
end)
test('unowned preflight preserves live owners and actual Mission',function()
 for _,mode in ipairs({'owned','active','pending','role_owned','mission','actor','photo','menu'})do
  local f=preflight_fixture()
  if mode=='owned'then f.status.owned=true elseif mode=='active'then f.status.active=true elseif mode=='pending'then f.status.pending=true elseif mode=='role_owned'then f.status.role8_owned=true elseif mode=='mission'then f.view.base.scene=4 elseif mode=='actor'then f.lease.avatar=251 elseif mode=='photo'then f.view.photo=true else f.view.menu_closed=false end
  assert(preflight(f));assert(f.reads==0 and f.calls==0 and f.writes==0)
 end
end)
test('unowned preflight refuses live widget and open action before mutation',function()
 for _,mode in ipairs({'widget','mission_init','action','generation'})do local f=preflight_fixture()
  if mode=='widget'then f.put(f.ui+0x257F78,1,4)elseif mode=='mission_init'then f.put(f.ui+0x46D8F0,1,1)elseif mode=='action'then f.put(f.pc+0xFD8,1,4)else f.put(f.gens+15,3,1)end
  local ok=pcall(preflight,f);if mode~='generation'then assert(not ok)end;assert(f.calls==0 and f.writes==0)
 end
end)
