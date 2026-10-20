local C=dofile('src/catalogue.lua')
local M=dofile('src/customization.lua')
local defaults=C.word(4)..C.word(3596468569)..C.word(2)..C.word(841650739)..C.word(1)..C.word(3651359518)
    ..C.word(5)..C.word(1450370231)..C.word(3)..C.word(2163992125)..string.rep('\0',40)
local row=M.record(C,defaults)
assert(#row==148 and C.u32(row)==C.ID and C.u32(row,4)==0 and C.u32(row,8)==0)
for preset=0,2 do
    local base=12+preset*40
    assert(C.u32(row,base)==0 and C.u32(row,base+4)==3651359518 and C.u32(row,base+8)==841650739)
    assert(C.u32(row,base+12)==2163992125 and C.u32(row,base+16)==3596468569 and C.u32(row,base+20)==1450370231)
end
assert(row:sub(133)==string.rep('\0',16))
assert(not pcall(M.record,C,C.word(11)..defaults:sub(5)))
return 'Customization defaults match the native three-preset initializer; invalid slots refused'
