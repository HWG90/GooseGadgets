-- ReadProcessMemory microbenchmark on an isolated Lua-owned buffer, never game memory.
local ffi=require('ffi')
local root=assert(HOB_TEST_ROOT)
local baseline=root..'/../dist/releases/original-baseline-20261014/ads-native-beams-20261015/prototype'
local old_mod=mod
mod={require=function(path)return dofile(root..'/'..path)end}
local Original=dofile(baseline..'/src/backend.lua')
local Optimized=dofile(root..'/src/backend.lua')
mod=old_mod
local buffer=ffi.new('uint8_t[?]',0x346C000)
local base=tonumber(ffi.cast('uintptr_t',buffer))
local file=assert(io.open(baseline..'/src/backend.lua','rb'));local source=file:read('*a');file:close()
local markers=0
for rva,hex in source:gmatch("{(0x%x+),%s*'(%x+)'")do
 local bytes=hex:gsub('%x%x',function(pair)return string.char(tonumber(pair,16))end)
 ffi.copy(buffer+tonumber(rva:sub(3),16),bytes,#bytes);markers=markers+1
end
local pointer=ffi.new('uint64_t[1]',base+0x100)
ffi.copy(buffer+0x346BF98,pointer,8);pointer[0]=base+0x200;ffi.copy(buffer+0x346BFC8,pointer,8)
local old,new=Original.new(),Optimized.new()
for _,backend in ipairs({old,new})do backend.mem._module=function()return base,0x6AB3B43F end end
local function run(backend,count)
 local began=os.clock()
 for i=1,count do assert(backend:_context())end
 return os.clock()-began
end
run(old,300);run(new,300)
local old_total,new_total=0,0
for round=1,4 do
 if round%2==1 then old_total=old_total+run(old,4000);new_total=new_total+run(new,4000)
 else new_total=new_total+run(new,4000);old_total=old_total+run(old,4000)end
end
print(string.format('Isolated native fingerprint benchmark: original %.3f us/context, grouped %.3f us/context (%d markers, all comparisons retained)',old_total/16000*1e6,new_total/16000*1e6,markers))
