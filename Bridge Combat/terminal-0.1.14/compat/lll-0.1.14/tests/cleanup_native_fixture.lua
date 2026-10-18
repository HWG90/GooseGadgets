local root=assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT'))..'/compat/lll-0.1.14'
local f=assert(io.open(root..'/src/runtime.lua','rb'));local source=f:read('*a');f:close()
local block=assert(source:match('(    local select_unarmed,detach_hand.-)    local visibility='))
local function word(b,o)o=o or 0;local a,c,d,e=b:byte(o+1,o+4);assert(e);return a+c*256+d*65536+e*16777216 end
local function pointer(b)return word(b)+word(b,4)*2^32 end
local function bytes(v,n)local b={};for i=1,n do b[i]=string.char(v%256);v=math.floor(v/256)end;return table.concat(b)end
local function fixture(selected,held,cleanup)
 local f={selects=0,detaches=0,events=0,actions=0,held=held,selected=selected,ack=true};local mem={};local function put(a,v,n)mem[a]=bytes(v,n)end
 local g,e,ep,im,ds,rows,wm,wds,wr,reg,gens,units,body=0x100000,0x200000,0x300000,0x400000,0x500000,0x600000,0x700000,0x800000,0x900000,0xA00000,0xB00000,0xC00000,0xD00000
 local ref=0x800123;local desc='resource'..bytes(6,4)..bytes(ref,4)..bytes(0,4)..bytes(1,4);mem[ep]=desc
 put(g+0x3326D20,im,8);put(im+0x70,1,4);put(im+0x110,ep,8);put(g+0x3326738,im,8);put(im+0x18,1,4);put(im+0x40,ds,8);put(ds,ep,8);put(im+0x50,rows,8)
 put(g+0x3326DC0,0xE10000,8);put(0xE10000+0x18,2,4);put(0xE10000+0x38,0xE20000,8);put(0xE10000+0x40,0xE30000,8);put(0xE20000,0xE40000,8);put(0xE20008,0xE50000,8);mem[0xE40000]="weapon01"..bytes(71,4)..bytes(601,4)..bytes(0,4)..bytes(1,4);mem[0xE50000]="weapon02"..bytes(72,4)..bytes(602,4)..bytes(0,4)..bytes(1,4);put(0xE30004,6,4);put(0xE30034,6,4);put(rows,71,4);put(rows+4,72,4);put(g+0x3326420,wm,8);put(wm+0x1C,1,4);put(wm+0x20,1,4);put(wm+0x48,wds,8);put(wds,ep,8);put(wm+0x60,wr,8)
 put(g+0x3483C20,0xFFFFFFFF,4);put(g+0x3483C34,0xFFFFFFFE,4)
 put(e+0x1A100F0,reg,8);put(reg+0x98,0x10000,4);put(reg+0xA0,gens,8);put(gens+0x123,2,1);put(reg+0x88,units,8);put(units+0x123*8,body,8);put(body+8,ref,4);put(body+0x178,0xE00000,8)
 local io={read=function(a,n)if a==rows+0x1C then return bytes(f.selected,4)elseif a==wr then return bytes(f.held,4)end;local b=assert(mem[a],'Unexpected protected read '..a);assert(#b==n);return b end,
  hashmap=function(at,id)if at==0xE10000+0x20 then return id==71 and 0 or 1 end;return 0 end,module=function()return e,0x3000000,0x6AB382E4 end,
  native=function(a)
   if a==g+0x835F70 then return function(_,actor,action,a,b)assert(actor==6 and action==0x39 and a==0 and b==0);f.actions=f.actions+1;if f.action_error then error('Unknown action outcome')end end
   elseif a==g+0x9AAA50 then return function()f.selects=f.selects+1;f.selected=0;if f.ack then f.held=0 end end
   elseif a==g+0x785C10 then return function()f.detaches=f.detaches+1;if f.ack then f.held=0 end end
   elseif a==g+0x8BF870 then return function(_,weapon,actor,a,b,c)assert((weapon==71 or weapon==72)and actor==6 and a==0 and b==0 and c==0);f.holsters=(f.holsters or 0)+1;if f.holster_error then error('Unknown native holster result')end end
   elseif a==e+0x201710 then return function()return 1 end
   elseif a==e+0x201900 then return function()f.events=f.events+1;if f.event_error then error('Unknown event outcome')end end
   else error('Unexpected native call')end
  end}
 local chunk=assert(loadstring('local io,pointer,word,photo_state,support=...;local options={}; local reset_unarmed; '..block..';return reset_unarmed'))
 f.reset=chunk(io,pointer,word,function()return f.photo==true,false end,cleanup);f.view={game=g,avatar=6,ep=ep,pm=im};f.lease={render=ref,resource='resource'};return f
end
local f=fixture(0,42);assert(f.reset(f.view,f.lease));assert(f.detaches==1 and f.events==1 and f.selects==0 and f.held==0)
for _=1,600 do assert(f.reset(f.view,f.lease))end;assert(f.detaches==1 and f.events==1 and f.selects==0 and f.actions==1 and f.holsters==2)
f=fixture(3,42);assert(f.reset(f.view,f.lease));assert(f.selects==1 and f.events==1 and f.detaches==0)
f=fixture(0,42);f.ack=false;assert(not pcall(f.reset,f.view,f.lease));assert(f.detaches==1 and f.events==0);assert(not pcall(f.reset,f.view,f.lease));assert(f.detaches==1)
f=fixture(0,0);f.action_error=true;assert(not pcall(f.reset,f.view,f.lease));assert(not pcall(f.reset,f.view,f.lease));assert(f.actions==1 and f.selects==0 and f.events==0)
f=fixture(0,0);f.event_error=true;assert(not pcall(f.reset,f.view,f.lease));assert(not pcall(f.reset,f.view,f.lease));assert(f.events==1)
f=fixture(0,0);f.lease.render=1;assert(not pcall(f.reset,f.view,f.lease));assert(f.events==0 and f.selects==0 and f.detaches==0)
f=fixture(3,42);f.photo=true;assert(not pcall(f.reset,f.view,f.lease));assert(f.selects==0 and f.events==0 and f.detaches==0);f.photo=false;assert(f.reset(f.view,f.lease)and f.selects==1 and f.events==1)
local ready=false;local attempts=0
f=fixture(3,42,{cleanup_inventory=function()attempts=attempts+1;return ready,'Waiting for native support retirement'end})
assert(not pcall(f.reset,f.view,f.lease));assert(f.actions==0 and f.selects==0 and f.detaches==0 and f.events==0)
ready=true;assert(f.reset(f.view,f.lease));assert(attempts==2 and f.actions==1 and f.selects==1 and f.held==0 and f.events==1)
f=fixture(0,0);f.holster_error=true;assert(not pcall(f.reset,f.view,f.lease));assert(not pcall(f.reset,f.view,f.lease));assert(f.holsters==1 and f.events==0)
print('PASS actual native cleanup: stale empty selection, held-hand release, normal animation once, 600 settled polls, uncertain results and identity refusal')
