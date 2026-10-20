local C=dofile('src/catalogue.lua')
assert(C.child_id(0x322A9233,0xAA035309)==0xDF3B4668)
assert(C.child_id(0x322A9233,0x80DD6F30)==0x49A4A5A5)
local checks=0
local function check(v,why)checks=checks+1;assert(v,why or ('Check '..checks))end
local function snapshot(kinds)
    local rows,indexes,groups,order={},{},{},{}
    for kind=0,23 do groups[kind]={}end
    for i,kind in ipairs(kinds)do
        local id=1000+i
        rows[i]=C.word(i-1)..C.word(id)..C.word(id)..C.word(kind)..string.rep('\0',C.RECORD-16)
        indexes[i]=C.word(i-1)..C.word(id)..C.word(id)..string.rep('\0',12)
        groups[kind][#groups[kind]+1]=i-1
    end
    local bounds,count={},0
    for kind=0,23 do
        bounds[#bounds+1]=C.word(count)
        for _,row in ipairs(groups[kind])do order[#order+1]=C.word(row);count=count+1 end
    end
    bounds[#bounds+1]=C.word(count)
    return {count=#kinds,records=table.concat(rows),indexes=table.concat(indexes),categories=table.concat(bounds),
        order=table.concat(order)..'TAIL',unused_record=string.rep('r',C.RECORD),unused_index=string.rep('i',C.INDEX)}
end
local s=snapshot({1,2,0,1,3,1,23})
local plan=C.plan(s)
check(#plan==5)
local row=plan[1].after
check(#row==184 and C.u32(row)==7 and C.u32(row,4)==C.ID and C.u32(row,8)==C.ID)
check(C.u32(row,12)==1 and C.u32(row,20)==2 and C.u32(row,176)==1 and row:byte(181)==1)
check(plan[1].before==s.unused_record and plan[2].before==s.unused_index)
check(plan[3].after==C.word(2)..C.word(0)..C.word(3)..C.word(5)..C.word(7)..C.word(1)..C.word(4)..C.word(6),
    'The new root must follow existing weapons without disturbing any other category')
for kind=0,24 do
    check(C.u32(plan[4].after,kind*4)==C.u32(s.categories,kind*4)+(kind>1 and 1 or 0))
end
check(plan[5].offset==C.COUNT and C.u32(plan[5].after)==8,'Count must publish last')
check(s.records==snapshot({1,2,0,1,3,1,23}).records,'Planner mutated its input')
local function refusal(change)
    local a=snapshot({1,2,0,1,3,1,23});change(a)
    check(not pcall(C.plan,a),'Corrupt source must refuse registration')
end
refusal(function(a)a.count=4096 end)
refusal(function(a)a.categories=C.word(1)..a.categories:sub(5)end)
refusal(function(a)a.order=C.word(2)..C.word(2)..a.order:sub(9)end)
refusal(function(a)a.indexes=C.word(99)..a.indexes:sub(5)end)
refusal(function(a)a.records=a.records:sub(1,12)..C.word(24)..a.records:sub(17)end)
refusal(function(a)a.order=a.order:sub(1,-2)end)
local existing=snapshot({1,2,0})
existing.records=existing.records:sub(1,4)..C.word(C.ID)..C.word(C.ID)..existing.records:sub(13)
existing.indexes=existing.indexes:sub(1,4)..C.word(C.ID)..C.word(C.ID)..existing.indexes:sub(13)
local duplicate,why=C.plan(existing)
check(duplicate==nil and why:find('already'),'An existing provider must retain its record')
local a=snapshot({1,2,0,1,3,1,23})
local children={}
for i=1,5 do children[i]={id=C.child_id(100+i),stable=100+i}end
a.order=a.order..string.rep('\0',20)
a.unused_record=string.rep('r',184*6);a.unused_index=string.rep('i',24*6)
local p=C.plan(a,children)
check(C.u32(p[5].after)==13 and C.u32(p[2].after,20)==5)
for i=1,5 do
 check(C.u32(p[1].after,i*184+4)==children[i].id and C.u32(p[1].after,i*184+8)==children[i].stable)
 check(C.u32(p[2].after,i*24+12)==i and C.u32(p[2].after,i*24+16)==i)
end
check(C.u32(p[4].after,12)==C.u32(a.categories,12)+6)
children[1].id=1001;check(not pcall(C.plan,a,children),'Child identity collisions must refuse')
return 'Catalogue invariants: '..checks..' checks passed'
