local C=dofile('src/catalogue.lua')
mod={require=function(name)return dofile(name)end}
local G=dofile('src/group.lua')
local d=''
for i=1,5 do d=d..C.word(i)..C.word(100+i)end
d=d..string.rep('\0',40)
local row,level,rewards,grants=G.build(C,56,d,0x300000000,0x400000000,0x500000000)
assert(#row==112 and #level==0x848 and #rewards==240)
assert(C.u32(row)==G.KEY and C.u32(row,4)==56 and C.u32(row,8)==2)
assert(C.u32(row,12)==C.ID and C.u32(row,0x5C)==1 and C.u32(row,0x68)==1)
assert(row:sub(97,104)==G.pointer(C,0x300000000))
assert(C.u32(level)==1 and C.u32(level,4)==0 and C.u32(level,8)==3)
assert(C.u32(level,0x840)==5 and level:sub(0x839,0x840)==G.pointer(C,0x400000000))
assert(#grants==60 and C.u32(level,0x830)==5)
assert(level:sub(13,0x828)==string.rep('\0',0x828-12))
for i=0,4 do
 assert(C.u32(rewards,i*48)==C.child_id(101+i) and C.u32(rewards,i*48+4)==1)
 assert(rewards:sub(i*48+9,(i+1)*48)==string.rep('\0',40))
end
assert(not pcall(G.build,C,300,d,65536,65536))
assert(not pcall(G.build,C,56,string.rep('\0',80),65536,65536))
assert(not pcall(G.build,C,56,C.word(11)..d:sub(5),65536,65536))
return 'Native local group layout, own defaults, zero costs and invalid input refusal verified'
