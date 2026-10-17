"""Reproduce backend contracts in a separate LuaJIT process, without game access.

The Windows-copy smoke check reads/writes only the interpreter's own FFI heap.
All game-module, manager, avatar and native-call contracts use injected I/O.
"""
from pathlib import Path
import unittest

from test_adapter import literal, run_lua


ROOT = Path(__file__).resolve().parents[1]


def check(code):
    source = (ROOT / "src" / "backend.lua").read_text(encoding="utf-8")
    run_lua("local Backend=assert(loadstring(" + literal(source) + "))()\n" + code)


class BackendTests(unittest.TestCase):
    def test_lazy_bounds_pe_fingerprints_hash_and_write_guards(self):
        check(r'''
local ffi,bit=require('ffi'),require('bit')
local memory,reads,writes,lookups,calls={},0,0,0,0
local function put(at,s)for i=1,#s do memory[at+i-1]=s:byte(i)end end
local function p32(n)return string.char(n%256,math.floor(n/256)%256,math.floor(n/65536)%256,math.floor(n/16777216)%256)end
local function p64(n)return p32(n%4294967296)..p32(math.floor(n/4294967296))end
local function read(at,n)reads=reads+1;local s={};for i=0,n-1 do if memory[at+i]==nil then return nil end;s[#s+1]=string.char(memory[at+i])end;return table.concat(s)end
local game=0x180000000
local io={module=function(name)lookups=lookups+1;assert(name=='game.dll');return game end,read=read,
 write=function(at,s)writes=writes+1;put(at,s);return true end,
 call=function(name,...)calls=calls+1;return name=='query'and 0 or nil end}
local b=Backend.new(nil,io)
assert(reads==0 and writes==0 and calls==0 and lookups==0,'constructor touched game')
assert(b:read(0xFFFF,1)==nil and b:read(0x800000000000,1)==nil and b:read(0x10000,8193)==nil)
assert(not b:write(0x200000000,string.rep('x',4097)))
put(game,string.rep('\0',64));put(game,'MZ');put(game+0x3C,p32(0x80))
local pe=game+0x80;put(pe,string.rep('\0',96));put(pe,'PE\0\0\100\134');put(pe+24,'\11\2')
put(pe+8,p32(0x6AB3B43F));put(pe+80,p32(0x4744000))
local fps={
 add={0xAA0AA0,'48895c2408574883ec20488b1a488bfa4c8b89900f00004c'},
 remove={0xAA0BB0,'48895c2418574883ec20488bb9800f00004c8bc94c8b5a10'},
 profile={0x831CD0,'405355574883ec203b15421fc502418bf88bda488be90f84'},
 query={0x12FD820,'48895c240848896c24104889742418574883ec204c8bd94c'},
 block={0x12FD250,'48895c240848896c2410488974241848897c242041544156'},
 release={0x12FD3B0,'48896c2418564883ec204c8bd94c8bca488bcae8b88728ff'},
}
local function unhex(s)return(s:gsub('%x%x',function(p)return string.char(tonumber(p,16))end))end
for _,f in pairs(fps)do put(game+f[1],unhex(f[2]))end
local v=assert(b:observe());assert(v.game==game and v.stamp==0x6AB3B43F and v.avatar==nil)
assert(b:validate(v));assert(b:call('query',0x280000000,0x3100000000)==0)
for name,f in pairs(fps)do
 put(game+f[1],'x');local ok,why=b:validate(v);assert(not ok and why:find(name,1,true));assert(calls==1,'validation called game')
 put(game+f[1],unhex(f[2]));assert(b:validate(v))
end
put(pe+8,p32(1));assert(b:observe()==nil);put(pe+8,p32(0x6AB3B43F))
assert(not b:write(game+0x1000,'x'),'module image accepted write')
local header,buckets=0x260000000,0x270000000
local key,mult=0xFEFFFFFF,0xEFFFFFFF
put(header,p64(buckets)..p32(16)..p32(0xFFFFFFFF)..p32(mult));put(buckets,string.rep('\255',16*8))
local product=tonumber(ffi.cast('uint32_t',ffi.new('uint64_t',key)*ffi.new('uint64_t',mult)))
local slot=bit.band(product,15);put(buckets+slot*8,p32(key)..p32(71));assert(b:hashmap(header,key)==71,'u32 multiplication mismatch')
put(buckets+slot*8,p32(key)..p32(0xFFFFFFFF));assert(b:hashmap(header,key)==nil)
assert(b:hashmap(header,0xFFFFFFFF)==nil)
put(header+8,p32(15));assert(b:hashmap(header,key)==nil)
local heap=0x280000000;put(heap,'old');local ok,why,count=b:write(heap,'new');assert(ok and count==3 and b:read(heap,3)=='new')
io.writable=function()return false,'blocked' end;local w=writes;ok,why,count=b:write(heap,'abc');assert(not ok and count==0 and writes==w);io.writable=nil
io.write=function()return true end;ok,why,count=b:write(heap,'bad');assert(not ok and count==3 and why:find('readback'))
io.write=function(at,s)put(at,s:sub(1,1));return false,'partial',1 end
ok,why,count=b:write(heap,'abc');assert(not ok and count==1 and b:read(heap,3)=='aew')
io.write=function()return false,'unknown partial' end
ok,why,count=b:write(heap,'abc');assert(not ok and count==nil)
assert(tonumber(b:mask(4)[0])==4 and tonumber(b:mask(4)[1])==0)
assert(b:_address(b:mask(4),1));assert(not b:_address(ffi.cast('void *',0),1))
''')

    def test_avatar_identity_unique_ownership_and_base_resource_mapping(self):
        check(r'''
local mem={};local function put(at,s)for i=1,#s do mem[at+i-1]=s:byte(i)end end
local function p32(n)return string.char(n%256,math.floor(n/256)%256,math.floor(n/65536)%256,math.floor(n/16777216)%256)end
local function p64(n)return p32(n%4294967296)..p32(math.floor(n/4294967296))end
local function read(at,n)local r={};for i=0,n-1 do if mem[at+i]==nil then return nil end;r[#r+1]=string.char(mem[at+i])end;return table.concat(r)end
local game,player,inventory,world,pm,lc,inp,ps,gs=0x180000000,0x200000000,0x210000000,0x220000000,0x230000000,0x240000000,0x250000000,0x260000000,0x270000000
local ep,defs,rows,tablep=0x280000000,0x290000000,0x300000000,0x310000000
local io={module=function()return game end,read=read};local b=Backend.new(nil,io)
put(game,string.rep('\0',64));put(game,'MZ');put(game+0x3C,p32(0x80))
local pe=game+0x80;put(pe,string.rep('\0',96));put(pe,'PE\0\0\100\134');put(pe+24,'\11\2');put(pe+8,p32(0x6AB3B43F));put(pe+80,p32(0x4744000))
for off,v in pairs({[0x3326468]=player,[0x3326738]=inventory,[0x346BF98]=world,[0x3326D20]=pm,[0x3326CF8]=lc,[0x3326340]=gs,[0x347CF18]=inp,[0x347CEA8]=ps})do put(game+off,p64(v))end
local next_bucket=0x320000000
local function map(header,key,value)
 local buckets=next_bucket;next_bucket=next_bucket+0x1000
 put(header,p64(buckets)..p32(16)..p32(0xFFFFFFFF)..p32(1));put(buckets,string.rep('\255',128))
 put(buckets+(key%16)*8,p32(key)..p32(value));return buckets
end
local avatar,unit,ui,ii,pi,di=45,75,7,4,2,3
put(player+0x3A8,p32(unit));map(world+0xF22EC8,unit,ui);put(world+0xF32F18+ui*24+8,p32(avatar))
map(inventory+0x28,avatar,ii);put(inventory+0x50,p64(rows));put(rows+ii*48,string.rep('\0',48))
map(pm+0xF8,avatar,pi);local owners=map(lc+0x68,avatar,di);local inverse=map(lc+0x88,di,avatar)
put(pm+0x110+pi*8,p64(ep));put(ep,string.rep('\0',24));put(ep,'TYPEHERE');put(ep+8,p32(avatar));put(ep+0x14,string.char(1))
put(lc+0xA8,p64(defs));local def=defs+di*0x1210;put(def,string.rep('o',0x1160))
local pc,state=pm+0x53D8B0+pi*0x1238,pm+0x547830+pi*0x78
put(pc+0xFD0,p32(4)..p32(0)..p32(0));put(state+0x20,p32(0));put(gs+0xAC21C,p32(3))
put(world+0xF12E30,p64(tablep));put(tablep,string.rep('\0',408*16));put(tablep+16*21,'TYPEHERE'..p32(17)..p32(0))
local base=tablep+0x1980+17*0x1210;put(base,string.rep('b',0x1160))
local v=assert(b:observe());assert(v.avatar==avatar and v.di==di and v.def==def and v.pc==pc and v.state==state and v.ep==ep)
assert(b:unique(v));assert(b:base_profiles(v)==string.rep('b',0x1160));assert(b:base_profiles(v,0x1210)==nil)
put(owners+8*15,p32(111)..p32(di));local ok,why=b:unique(v);assert(not ok and why:find('another owner'));put(owners+8*15,string.rep('\255',8))
put(inverse+8*(di%16),p32(di)..p32(avatar+1));local retired=assert(b:observe());assert(retired.avatar==nil and retired.pm==pm and retired.lc==lc and retired.input==inp and retired.projectiles==ps and retired.scene==3);assert(not b:unique(v))
put(inverse+8*(di%16),p32(di)..p32(avatar));put(ep+0x14,string.char(0));retired=assert(b:observe());assert(retired.avatar==nil and retired.scene==3 and retired.input==inp)
put(ep+0x14,string.char(1));put(tablep+16*21+8,p32(408));assert(b:base_profiles(v)==nil);put(tablep+16*21+8,p32(17))
put(game+0x3326D20,p64(pm+0x1000000));assert(not b:unique(v));put(game+0x3326D20,p64(pm))
''')

    def test_real_windows_copies_only_interpreter_owned_heap(self):
        check(r'''
local ffi=require('ffi')
local real=Backend.new();local own=ffi.new('uint8_t[16]');local at=tonumber(ffi.cast('uintptr_t',own))
assert(real:read(at,16)==string.rep('\0',16));local ok,why,count=real:write(at,'abc');assert(ok and count==3);assert(ffi.string(own,3)=='abc')
''')


if __name__ == "__main__":
    unittest.main(verbosity=2)
