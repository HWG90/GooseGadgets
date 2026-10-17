local ffi, bit = require('ffi'), require('bit')
local root = assert(rawget(_G,'BRIDGE_COMBAT_TEST_ROOT') or os.getenv('DBF_BRIDGE_COMBAT_TEST_ROOT'))
local Backend = dofile(root .. '/src/backend.lua')
local Controller = dofile(root .. '/src/controller.lua')
local SIZE, PAIR = 0x1160, 0x3100000000
local HASHES = {0xF2F926AB,0xB65540AB,0x13AEB16B,0x2E3F3C44,0xB013CA6F,0x92AA29EB,0x12345678,0x87654321}
local fixture_id = 0
local SPECS = {
 add={0xAA0AA0,'48895c2408574883ec20488b1a488bfa4c8b89900f00004c'},
 remove={0xAA0BB0,'48895c2418574883ec20488bb9800f00004c8bc94c8b5a10'},
 profile={0x831CD0,'405355574883ec203b15421fc502418bf88bda488be90f84'},
 query={0x12FD820,'48895c240848896c24104889742418574883ec204c8bd94c'},
 block={0x12FD250,'48895c240848896c2410488974241848897c242041544156'},
 release={0x12FD3B0,'48896c2418564883ec204c8bd94c8bca488bcae8b88728ff'},
}
local function bytes(kind, value)
 local a=ffi.new(kind .. '[1]',value);return ffi.string(a,ffi.sizeof(a))
end
local function eq(a,b,message) assert(a==b,(message or 'Mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function truth(a,message) assert(a,message or 'Expected true') end
local function fixture(route)
 fixture_id = fixture_id + 1
 local f={data={},reads=0,modules=0,writes={},calls={},mutations={},suppressed=false,unreadable={},fail_native={},fail_write={},logs={}}
 f.native_loads,f.native_starts,f.native_ticks,f.native_stops=0,0,0,0
 f.native_dir='C:/bridge-native-fixture/'..fixture_id
 f.armory_manager=0x300000000
 f.game=0x100000000; f.pm=0x200000000;f.lc=0x210000000;f.player=0x220000000
 f.inventory=0x230000000;f.world=0x240000000;f.scene_ptr=0x250000000
 f.input=0x260000000;f.projectiles=0x270000000;f.ep=0x280000000
 f.definitions=0x290000000;f.base_table=0x2A0000000;f.suppression=0x2B0000000
 f.avatar=8389271;f.render=20972890;f.def=f.definitions
 f.pc=f.pm+0x53D8B0;f.state=f.pm+0x547830
 function f:poke(address,value) for i=1,#value do self.data[address+i-1]=value:byte(i) end end
 function f:get(address,size)
  for _,range in ipairs(self.unreadable) do if address<range[2] and address+size>range[1] then return nil end end
  local out={};for i=0,size-1 do out[#out+1]=string.char(self.data[address+i] or 0) end;return table.concat(out)
 end
 function f:word(address) local b=assert(self:get(address,4));local a,b1,c,d=b:byte(1,4);return a+b1*256+c*65536+d*16777216 end
 function f:put32(a,v) self:poke(a,bytes('uint32_t',v)) end
 function f:put64(a,v) self:poke(a,bytes('uint64_t',v)) end
 local bucket=0x2C0000000
 function f:map(address,entries)
  local base=bucket;bucket=bucket+0x100
  self:put64(address,base);self:put32(address+8,8);self:put32(address+12,0xFFFFFFFF);self:put32(address+16,1)
  for i=0,7 do self:put32(base+i*8,0xFFFFFFFF);self:put32(base+i*8+4,0xFFFFFFFF) end
  for key,value in pairs(entries) do
   local i=key%8;while self:word(base+i*8)~=0xFFFFFFFF do i=(i+1)%8 end
   self:put32(base+i*8,key);self:put32(base+i*8+4,value)
  end
  return base
 end
 local dos=string.rep('\0',64)
 f:poke(f.game,'MZ'..dos:sub(3));f:put32(f.game+0x3C,0x80)
 f:poke(f.game+0x80,'PE\0\0\100\134');f:put32(f.game+0x88,0x6AB3B43F)
 f:poke(f.game+0x80+24,'\11\2');f:put32(f.game+0x80+80,0x4744000)
 for _,spec in pairs(SPECS) do f:poke(f.game+spec[1],spec[2]:gsub('%x%x',function(s)return string.char(tonumber(s,16))end)) end
 for _,spec in ipairs({{0xAB2FA0,'48895c240848896c241856574154415641574883ec308bda'},
  {0x1456BB0,'40534883ec60488b056b620202488bd90f297424500f28f1'},
  {0x14C0550,'4c89442418565741564883ec608b4128488bf183e8014863'},
  {0x14C0C70,'488bc4574881ec9000000083792800488bf90f8694030000'}}) do
  f:poke(f.game+spec[1],spec[2]:gsub('%x%x',function(s)return string.char(tonumber(s,16))end))
 end
 for name,rva in pairs({player=0x3326468,inventory=0x3326738,world=0x346BF98,pm=0x3326D20,lc=0x3326CF8,input=0x347CF18,projectiles=0x347CEA8,scene_ptr=0x3326340}) do f:put64(f.game+rva,f[name]) end
 f:put32(f.scene_ptr+0xAC21C,3);f:put32(f.player+0x3A8,f.render)
 f:put64(f.game+0x347CE28,f.armory_manager)
 function f:armory(open,nested)
  local menu=self.armory_manager+0x4288
  self:put32(menu+0xC,open and (nested and 6 or 5) or 0);self:put32(menu+0x28,open and (nested and 2 or 1) or 0)
  self:put32(menu+0x14,open and 5 or 0);self:put32(menu+0x18,nested and 6 or 0)
 end
 f.level_runtime=0x2E0000000;f.level_definition=0x2F0000000
 f:put64(f.scene_ptr+0xAE288,f.level_runtime);f:put32(f.level_runtime+0x1E4,0);f:put64(f.level_runtime+0x218,f.level_definition)
 f:map(f.world+0xF22EC8,{[f.render]=0});f:put32(f.world+0xF32F18+8,f.avatar)
 f:map(f.inventory+0x28,{[f.avatar]=0});f:put64(f.inventory+0x50,0x2D0000000)
 f:map(f.pm+0xF8,{[f.avatar]=0});f:put64(f.pm+0x110,f.ep)
 f:map(f.lc+0x68,{[f.avatar]=0});f:map(f.lc+0x88,{[0]=f.avatar});f:put64(f.lc+0xA8,f.definitions)
 f.resource=bytes('uint64_t',ffi.new('uint64_t',0x4D1C334D)*4294967296+0x294DFA97)
 f:poke(f.ep,f.resource);f:put32(f.ep+8,f.avatar);f:put32(f.ep+0xC,f.render);f:poke(f.ep+0x14,'\1')
 f:put32(f.pc+0xFD0,0x204);f:put32(f.state+0x20,0)
 f:put64(f.world+0xF12E30,f.base_table);f:poke(f.base_table,f.resource);f:put32(f.base_table+8,0)
 local base,old={},{ }
 for i=0,7 do
  base[#base+1]=bytes('uint32_t',HASHES[i+1])..string.rep(string.char(65+i),0x228)
  old[#old+1]=bytes('uint32_t',i==0 and 0x712947D6 or HASHES[i+1])..string.rep(string.char(97+i),0x228)
 end
 f.base=table.concat(base);f.old=table.concat(old);eq(#f.base,SIZE)
 f:poke(f.def,f.old);f:poke(f.base_table+0x1980,f.base)
 function f:native(name,...)
  self.calls[#self.calls+1]={name,...}
  if self.fail_native[name] then error('Injected native refusal: '..name) end
  local args={...}
  if name=='query' then return self.suppressed and self.suppression or 0 end
  self.mutations[#self.mutations+1]={name,...}
  if name=='add' or name=='remove' then
   local control=args[1]-0x50;local mask=tonumber(args[2][0]);local current=self:word(control+0xFD0)
   self:put32(control+0xFD0,name=='add' and bit.bor(current,mask) or bit.band(current,bit.bnot(mask)))
  elseif name=='profile' then
   local matched=false
   for i=0,7 do if self:word(self.def+i*0x22C)==args[3] then self:put32(self.state+0x20,i);matched=true;break end end
   truth(matched,'Native profile selected a missing hash')
  elseif name=='block' then
   eq(args[1],self.input);eq(tonumber(args[2]),PAIR);eq(args[3],1);eq(args[4],-1)
   self.suppressed=true;self:put32(self.suppression,1);self:put64(self.suppression+4,PAIR);self:put64(self.suppression+0x10,0)
  elseif name=='release' then self:put32(self.suppression,0)
  else error('Unknown fake native '..name) end
  return true
 end
 f.io={module=function(name) f.modules=f.modules+1;eq(name,'game.dll');return f.game end,
  read=function(a,n) f.reads=f.reads+1;return f:get(a,n) end,
  writable=function()return true end,
  write=function(a,s)
   f.writes[#f.writes+1]={address=a,bytes=s};f.mutations[#f.mutations+1]={'write',a,s}
   local fail=f.fail_write[a]
   if fail=='partial' or fail=='unknown_partial' then
    local n=math.max(1,math.floor(#s/2));f:poke(a,s:sub(1,n));return false,'Injected partial copy',fail=='partial' and n or nil
   end
   if fail then return false,'Injected write refusal',0 end
   f:poke(a,s)
   if f.fail_readback==a then f.unreadable={{a,a+#s}} end
   return true,nil,#s
  end,
  call=function(...)return f:native(...)end,
  native_load=function(path)
   f.native_loads=f.native_loads+1;eq(path,f.native_dir..'/runtime/BridgeCombatNative.dll')
   if f.native_missing then error('Injected missing helper DLL')end
   local api = {
    start=function(avatar)
     f.native_starts=f.native_starts+1;eq(avatar,f.avatar)
     truth(f.controller.active.native_claimed,'Native cleanup was not claimed before startup')
     f.native_owned=true;f.mutations[#f.mutations+1]={'native_start',avatar}
     f.native_expected_scene=f.native_scene4 and 4 or 3
     if f.native_scene4 then f:put32(f.scene_ptr+0xAC21C,4)end
     if f.fail_native_start=='throw' then error('Injected partial native startup exception')end
     if f.fail_native_start then return 0 end
     f.native_active=true;return 1
    end,
    status=function()return f.native_active and f:word(f.scene_ptr+0xAC21C)==f.native_expected_scene and 1 or 0 end,
    ready=function()return f.native_active and f.native_ready~=false and 1 or 0 end,
    error=function()return 'Injected native helper refusal' end,
    tick=function(dt)
     f.native_ticks=f.native_ticks+1;f.native_dt=dt
     if f.fail_native_tick then return 0 end;return 1
    end,
    stop=function()
     f.native_stops=f.native_stops+1;f.mutations[#f.mutations+1]={'native_stop'}
     if f.fail_native_stop=='throw' then error('Injected native cleanup exception')end
     if f.fail_native_stop then return 0 end
     if f.native_scene4 and not f.native_retired then
      f:put32(f.scene_ptr+0xAC21C,3)
      f:put32(f.pc+0xFD0,bit.bor(bit.band(f:word(f.pc+0xFD0),bit.bnot(6)),4))
     end
     f.native_active,f.native_owned=false,false;return 1
    end,
   }
   api.start_actor=function(avatar)f.native_actor_starts=(f.native_actor_starts or 0)+1;return api.start(avatar)end
   return api
  end}
 f.backend=Backend.new(function(s)f.logs[#f.logs+1]=s end,f.io,{dir=f.native_dir,native_route=route})
 f.controller=Controller.new(f.backend,function(s)f.logs[#f.logs+1]=s end)
 function f:enable() self.controller:set_enabled(true);self.controller:update();return self.controller.active end
 function f:restored()
  eq(self:get(self.def,SIZE),self.old,'Original profile bytes');eq(bit.band(self:word(self.pc+0xFD0),6),4,'Ship context')
  eq(self:word(self.state+0x20),self.old_index or 0,'Original profile index');eq(self:get(self.projectiles+0x28,1),string.char(self.old_projectiles or 0),'Projectile flag')
  if self.suppressed then eq(self:word(self.suppression),0,'Dispatch release') end
  eq(self.controller.active,nil,'Ownership lease released')
 end
 return f
end

local passed,failed=0,{}
local function test(name,fn)
 local ok,why=pcall(fn)
 if ok then passed=passed+1;print('PASS '..name) else failed[#failed+1]=name..': '..tostring(why);print('FAIL '..failed[#failed]) end
end
test('constructor and setting queue have no reads or mutations',function()
 local f=fixture();eq(f.reads,0);eq(f.modules,0);f.controller:set_enabled(true);eq(f.reads,0);eq(f.modules,0);eq(#f.calls,0);eq(#f.mutations,0);eq(f.native_loads,0)
end)
test('disabled update and mission enable never mutate',function()
 local f=fixture();f.controller:update();eq(#f.mutations,0);f:put32(f.scene_ptr+0xAC21C,4);f:enable();eq(#f.mutations,0);eq(f.controller.active,nil)
end)
test('unsupported build and changed fingerprint refuse without mutations',function()
 local f=fixture();f:put32(f.game+0x88,0);f:enable();eq(#f.mutations,0)
 f=fixture();f:poke(f.game+SPECS.release[1],'X');f:enable();eq(#f.mutations,0)
end)
test('activation fault requires a deliberate setting retoggle',function()
 local f=fixture();local a=f.game+SPECS.release[1];local original=f:get(a,1);f:poke(a,'X');f:enable();f:poke(a,original)
 f.controller:update();eq(#f.mutations,0,'Fault automatically reactivated');f.controller:set_enabled(false);f.controller:update();truth(f:enable());truth(f.controller:shutdown());f:restored()
end)
test('enable and disable restore exact owned state',function()
 local f=fixture();truth(f:enable());eq(f:get(f.def,SIZE),f.base);eq(bit.band(f:word(f.pc+0xFD0),6),2);eq(f:get(f.projectiles+0x28,1),'\1');eq(f:word(f.suppression),1)
 f:put32(f.pc+0xFD0,bit.bor(f:word(f.pc+0xFD0),0x10000));f.controller:set_enabled(false);f.controller:update();f:restored();truth(bit.band(f:word(f.pc+0xFD0),0x10000)~=0,'Foreign context bit preserved')
end)
test('dynamic stance selects real standing crouch prone and moving profiles',function()
 local f=fixture();truth(f:enable());local cases={{0,0,0},{0,0x2000,1},{0,0x4000,2},{0x4000,0,3},{0x4000,0x2000,4},{0,0x80000000,5}}
 for _,c in ipairs(cases)do f:put32(f.pc+0xFD4,c[1]);f:put32(f.pc+0xFD8,c[2]);f.controller:update();eq(f:word(f.state+0x20),c[3])end
 truth(f.controller:shutdown());f:restored()
end)
test('existing profile selection and enabled projectile state are preserved',function()
 local f=fixture();f.old_index=1;f.old_projectiles=1;f:put32(f.state+0x20,1);f:poke(f.projectiles+0x28,'\1');truth(f:enable());truth(f.controller:shutdown());f:restored()
end)
test('same actor definition relocation restores the current owned row',function()
 local f=fixture();truth(f:enable());local old_def=f.def;f.def=f.definitions+0x1210;f:poke(f.def,f.base)
 f:map(f.lc+0x68,{[f.avatar]=1});f:map(f.lc+0x88,{[1]=f.avatar});local n=#f.writes
 truth(f.controller:shutdown());f:restored()
 for i=n+1,#f.writes do truth(f.writes[i].address<old_def or f.writes[i].address>=old_def+SIZE,'Stale relocated definition write')end
end)
test('partial apply refusal rolls back attempted profiles and contexts',function()
 local f=fixture();f.fail_write[f.def+4096]=true;f:enable();f.fail_write={};if f.controller.active then truth(f.controller:shutdown())end;f:restored()
end)
test('partial native apply refusal restores removed ship context',function()
 local f=fixture();f.fail_native.add=true;f:enable();truth(f.controller.active,'Failed restoration retained');f.fail_native={};truth(f.controller:shutdown());f:restored()
end)
test('failed projectile apply retains restoration until writable again',function()
 local f=fixture();f.fail_write[f.projectiles+0x28]='partial';f:enable();truth(f.controller.active);f.fail_write={};truth(f.controller:shutdown());f:restored()
end)
test('cleanup refusal returns false then retries only unfinished phase',function()
 local f=fixture();truth(f:enable());f.fail_native.release=true;local ok=f.controller:shutdown();eq(ok,false);truth(f.controller.active);truth(f.controller.active.done.profiles);truth(f.controller.active.done.context);truth(f.controller.active.done.projectiles)
 local writes=#f.writes;f.fail_native={};truth(f.controller:shutdown());eq(#f.writes,writes,'Acknowledged restore writes not repeated');f:restored()
end)
test('fingerprint drift blocks native cleanup until validated again',function()
 local f=fixture();truth(f:enable());local a=f.game+SPECS.release[1];local original=f:get(a,1);f:poke(a,'X');local calls=#f.calls
 eq(f.controller:shutdown(),false);eq(#f.calls,calls,'Invalid native entrypoint called');truth(f.controller.active)
 f:poke(a,original);truth(f.controller:shutdown());f:restored()
end)
test('actor retirement never writes stale actor heaps',function()
 local f=fixture();truth(f:enable());f:poke(f.ep+0x14,'\0');local n=#f.writes;truth(f.controller:shutdown())
 for i=n+1,#f.writes do truth(f.writes[i].address<f.def or f.writes[i].address>=f.def+SIZE,'Stale profile write')end
 eq(f:get(f.def,SIZE),f.base);eq(f.controller.active,nil)
end)
test('actor render generation reuse is not restored as the old actor',function()
 local f=fixture();truth(f:enable());f:put32(f.ep+0xC,f.render+1);local n=#f.mutations;truth(f.controller:shutdown())
 for i=n+1,#f.mutations do local m=f.mutations[i];truth(m[1]~='add' and m[1]~='remove' and m[1]~='profile','Reused actor mutation')end
end)
test('mission transition releases local suppression without disabling mission projectiles',function()
 local f=fixture();truth(f:enable());f:put32(f.scene_ptr+0xAC21C,4);local n=#f.mutations;truth(f.controller:shutdown());eq(f:word(f.suppression),0);eq(f:get(f.projectiles+0x28,1),'\1')
 for i=n+1,#f.mutations do local m=f.mutations[i];truth(m[1]~='add' and m[1]~='remove' and m[1]~='profile','Actor mutation after scene change')end
end)
test('manager replacement leaves old actor and replaced global owners alone',function()
 local f=fixture();truth(f:enable());f:put64(f.game+0x3326D20,f.pm+0x10000000);f:put64(f.game+0x347CF18,f.input+0x10000000);f:put64(f.game+0x347CEA8,f.projectiles+0x10000000)
 local n=#f.mutations;truth(f.controller:shutdown())
 for i=n+1,#f.mutations do eq(f.mutations[i][1],'native_stop','Replaced managers were mutated')end
end)
test('shared profile definition and foreign suppression refuse activation',function()
 local f=fixture();f:map(f.lc+0x68,{[f.avatar]=0,[f.avatar+1]=0});f:enable();eq(#f.mutations,0)
 f=fixture();f.suppressed=true;f:put32(f.suppression,2);f:put64(f.suppression+0x10,99);f:enable();eq(#f.mutations,0);eq(f:word(f.suppression),2)
end)
test('foreign profile mutation is retained for cleanup attention',function()
 local f=fixture();truth(f:enable());f:poke(f.def+20,'Z');eq(f.controller:shutdown(),false);truth(f.controller.active);eq(f:get(f.def+20,1),'Z')
 f:poke(f.def+20,f.base:sub(21,21));truth(f.controller:shutdown());f:restored()
end)
test('replacement dispatch suppression is preserved on cleanup',function()
 local f=fixture();truth(f:enable());f:put32(f.suppression,2);f:put64(f.suppression+0x10,321);truth(f.controller:shutdown());eq(f:word(f.suppression),2);eq(tonumber(f.backend:u64(f.suppression+0x10)),321)
end)
test('uncertain actor read retains cleanup lease until recovery',function()
 local f=fixture();truth(f:enable());f.unreadable={{f.ep,f.ep+0x20}};eq(f.controller:shutdown(),false);truth(f.controller.active,'Unreadable actor was treated as retired')
 f.unreadable={};truth(f.controller:shutdown());f:restored()
end)
test('partially copied profile chunk is recoverable after write refusal',function()
 local f=fixture();f.fail_write[f.def]='partial';f:enable();f.fail_write={};truth(f.controller:shutdown());f:restored()
end)
test('unknown partial copy refuses guessed restoration and foreign bytes',function()
 local f=fixture();f.fail_write[f.def]='unknown_partial';f:enable();f.fail_write={};local n=#f.writes
 eq(f.controller:shutdown(),false);eq(#f.writes,n,'Unknown partial bytes were overwritten');truth(f.controller.active)
 f:poke(f.def,f.old);truth(f.controller:shutdown());f:restored()
end)
test('full copy with unreadable readback retains ownership until recovery',function()
 local f=fixture();f.fail_readback=f.def;f:enable();truth(f.controller.active,'Readback uncertainty dropped ownership')
 eq(f.controller:shutdown(),false);f.fail_readback=nil;f.unreadable={};truth(f.controller:shutdown());f:restored()
end)
test('missing helper and native fingerprint mismatch reject before mutations',function()
 local f=fixture();f.native_missing=true;f:enable();eq(f.native_starts,0);eq(#f.mutations,0);eq(f.controller.active,nil)
 f=fixture();f:poke(f.game+0xAB2FA0,'X');f:enable();eq(f.native_loads,0);eq(#f.mutations,0)
 f=fixture();local load=f.io.native_load;f.io.native_load=function(path)local api=load(path);api.ready=nil;return api end
 f:enable();eq(f.native_starts,0);eq(#f.mutations,0);eq(f.controller.active,nil)
end)
test('native partial startup retains all Lua state until cleanup acknowledges',function()
 local f=fixture();f.fail_native_start=true;f.fail_native_stop=true;f:enable()
 truth(f.controller.active and f.controller.active.native_claimed);eq(f.controller.active.done.native,nil)
 eq(f:get(f.def,SIZE),f.base);eq(bit.band(f:word(f.pc+0xFD0),6),2);eq(f:word(f.suppression),1)
 local writes=#f.writes;local calls=#f.calls;eq(f.controller:shutdown(),false)
 eq(#f.writes,writes,'Lua bytes restored before native cleanup');eq(#f.calls,calls,'Lua native state restored before native cleanup')
 f.fail_native_stop=false;truth(f.controller:shutdown());f:restored();eq(f.native_owned,false)
end)
test('native startup exception still invokes native cleanup before Lua rollback',function()
 local f=fixture();f.fail_native_start='throw';f:enable();eq(f.native_starts,1);eq(f.native_stops,1);f:restored()
end)
test('native cleanup retries finish before profile restoration and are not repeated',function()
 local f=fixture();truth(f:enable());f.fail_native_stop='throw';local n=#f.mutations;eq(f.controller:shutdown(),false)
 for i=n+1,#f.mutations do eq(f.mutations[i][1],'native_stop','Lua cleanup crossed pending native phase')end
 f.fail_native_stop=false;f.fail_native.release=true;eq(f.controller:shutdown(),false);truth(f.controller.active.done.native)
 local stops=f.native_stops;f.fail_native={};truth(f.controller:shutdown());eq(f.native_stops,stops);f:restored()
end)
test('native tick receives frame delta and retirement cleans up without reactivation',function()
 local f=fixture();truth(f:enable());f.controller:update(.031);eq(f.native_dt,.031);eq(f.native_ticks,1)
 f.fail_native_tick=true;f.controller:update(.016);eq(f.native_stops,1);f:restored()
 local starts=f.native_starts;f.controller:update(.016);eq(f.native_starts,starts,'Retired native fault reactivated itself')
end)
test('DLL keepalive survives new backend and refuses a foreign pending lease',function()
 local f=fixture();truth(f:enable())
 local next_backend=Backend.new(nil,f.io,{dir=f.native_dir});local view=assert(next_backend:observe())
 eq(next_backend:native_prepare(view),false);eq(next_backend:native_stop(),true);eq(f.native_stops,0)
 truth(f.controller:shutdown());f:restored();truth(next_backend:native_prepare(assert(next_backend:observe())))
 eq(f.native_loads,1,'DLL loaded again after backend replacement')
end)
test('scene and actor retirement stop native before skipping stale Lua actor writes',function()
 for _,retire in ipairs({'scene','actor'}) do
  local f=fixture();truth(f:enable());local n=#f.mutations
  if retire=='scene' then f:put32(f.scene_ptr+0xAC21C,4) else f:poke(f.ep+0x14,'\0')end
  f.controller:update(.016);eq(f.mutations[n+1][1],'native_stop');eq(f.native_stops,1);eq(f.controller.active,nil)
  for i=n+1,#f.mutations do local kind=f.mutations[i][1];truth(kind~='add' and kind~='remove' and kind~='profile','Retired actor native mutation')end
 end
end)

test('owned Scene4 stays active while native readiness waits',function()
 local f=fixture();f.native_scene4=true;f.native_ready=false;truth(f:enable())
 truth(f.controller:status():find('waiting for native completion',1,true));eq(f:word(f.scene_ptr+0xAC21C),4)
 local n=#f.calls;f:put32(f.pc+0xFD8,0x4000);f.controller:update(.016)
 eq(f.native_ticks,1);eq(f.native_stops,0);eq(#f.calls,n,'Pending native completion selected a stance')
 f.native_ready=true;f.controller:update(.016);eq(f:word(f.state+0x20),2)
 truth(f.controller:status():find('enabled',1,true));truth(f.controller:shutdown());f:restored()
end)

test('native Scene4 restoration refreshes actor and accepts engine-restored ship context',function()
 local f=fixture();f.native_scene4=true;truth(f:enable());local n=#f.calls
 truth(f.controller:shutdown());f:restored();eq(f:word(f.scene_ptr+0xAC21C),3)
 for i=n+1,#f.calls do truth(f.calls[i][1]~='add' and f.calls[i][1]~='remove','Engine-restored context was toggled again')end
 eq(f.native_stops,1)
end)

test('partial Scene4 startup keeps Lua state until normal mode restoration',function()
 local f=fixture();f.native_scene4=true;f.fail_native_start=true;f.fail_native_stop=true;f:enable()
 truth(f.controller.active);eq(f:word(f.scene_ptr+0xAC21C),4);eq(f:get(f.def,SIZE),f.base)
 local n=#f.calls;eq(f.controller:shutdown(),false);eq(#f.calls,n)
 f.fail_native_stop=false;truth(f.controller:shutdown());f:restored();eq(f:word(f.scene_ptr+0xAC21C),3)
end)

test('level schema replacement retires actor data even when world pointers are reused',function()
 for _,field in ipairs({'kind','definition'})do
  local f=fixture();f.native_scene4=true;truth(f:enable());f.native_retired=true
  if field=='kind' then f:put32(f.level_runtime+0x1E4,3)else f:put64(f.level_runtime+0x218,f.level_definition+0x10000)end
  local n=#f.mutations;f.controller:update(.016);eq(f.controller.active,nil)
  eq(f.mutations[n+1][1],'native_stop');eq(f:get(f.def,SIZE),f.base)
  for i=n+1,#f.mutations do local kind=f.mutations[i][1];truth(kind~='add' and kind~='remove' and kind~='profile','Reused level actor was restored')end
 end
end)

test('unreadable level schema retains ownership until identity is known',function()
 local f=fixture();truth(f:enable());f.unreadable={{f.level_runtime+0x218,f.level_runtime+0x220}}
 eq(f.controller:shutdown(),false);truth(f.controller.active);eq(f:get(f.def,SIZE),f.base)
 f.unreadable={};truth(f.controller:shutdown());f:restored()
end)

test('Armory and its nested menu refuse activation before mutations',function()
 for _,nested in ipairs({false,true})do
  local f=fixture();f:armory(true,nested);f:enable();eq(f.controller.active,nil);eq(f.native_loads,0);eq(#f.mutations,0)
  truth(f.controller.enabled);truth(f.controller:status():find('Paused',1,true))
 end
end)

test('opening Armory releases native first and resumes enabled intent after close',function()
 local f=fixture();truth(f:enable());f:armory(true);local n=#f.mutations;f.controller:update(.016)
 eq(f.mutations[n+1][1],'native_stop');f:restored();truth(f.controller.enabled)
 truth(f.controller:status():find('Paused',1,true));local starts=f.native_starts
 f:armory(true,true);f.controller:update(.016);eq(f.native_starts,starts,'Nested Armory menu resumed combat')
 f:armory(false);f.controller:update(.016);truth(f.controller.active);eq(f.native_starts,starts+1)
 truth(f.controller:shutdown());f:restored()
end)

test('Armory cleanup refusal cannot resume combat even after close',function()
 local f=fixture();truth(f:enable());f.fail_native_stop=true;f:armory(true);f.controller:update(.016)
 truth(f.controller.active and f.controller.active.restoring);eq(f.native_starts,1);eq(f:get(f.def,SIZE),f.base)
 f:armory(false);f.controller:update(.016);eq(f.native_starts,1);eq(f:get(f.def,SIZE),f.base)
 f.fail_native_stop=false;f.controller:update(.016);f:restored();eq(f.native_starts,1)
 f.controller:update(.016);eq(f.native_starts,2);truth(f.controller:shutdown());f:restored()
end)

test('unknown Armory signal refuses activation and retains owned cleanup',function()
 local f=fixture();f:put32(f.armory_manager+0x42B0,6);f:enable();eq(#f.mutations,0);eq(f.native_loads,0)
 f=fixture();truth(f:enable());local a=f.game+0x1456BB0;local old=f:get(a,1);f:poke(a,'X');local writes=#f.writes
 f.controller:update(.016);truth(f.controller.active and f.controller.active.restoring);truth(f.controller.active.done.native)
 eq(#f.writes,writes,'Unknown Armory ownership restored Lua bytes');eq(f.native_starts,1)
 f:poke(a,old);f.controller:update(.016);f:restored();f.controller:update(.016);eq(f.native_starts,2)
 truth(f.controller:shutdown());f:restored()
end)

test('actor route binds the production actor API independently of gated mode',function()
 local f=fixture('actor');f:poke(f.game+0xAB2FA0,'X');truth(f:enable());eq(f.native_actor_starts,1)
 truth(f.controller:shutdown());f:restored()
 local f2=fixture('mode');f2:poke(f2.game+0xAB2FA0,'X');f2:enable();eq(#f2.mutations,0)
end)

test('actor route refuses missing production API and never falls back to test entry',function()
 local f=fixture('actor');local load=f.io.native_load
 f.io.native_load=function(path)local api=load(path);api.start_actor_test=api.start_actor;api.start_actor=nil;return api end
 f:enable();eq(#f.mutations,0);eq(f.native_starts,0);eq(f.controller.active,nil)
end)

test('cached DLL retains separate actor and mode start bindings',function()
 local f=fixture('mode');truth(f:enable());truth(f.controller:shutdown());f:restored()
 local b=Backend.new(nil,f.io,{dir=f.native_dir,native_route='actor'});truth(b:native_prepare(assert(b:observe())))
 eq(f.native_loads,1);eq(b._native_route,'actor');truth(b._native_start~=f.backend._native_start)
end)
print(string.format('Controller contracts: %d passed, %d failed',passed,#failed))
assert(#failed==0,table.concat(failed,'\n'))
