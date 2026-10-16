-- Pure parameter contracts; no native backend or game memory access.
local P=dofile(assert(HOB_TEST_ROOT)..'/src/parameters.lua')
local function unhex(s)return (s:gsub('..',function(b)return string.char(tonumber(b,16))end))end
local cases={
    {'00000000','00000000',false},
    {'cdcc4c3d','88c3643a',false},
    {'0000003f','35fa0e3c',false},
    {'00004040','5077563d',true},
    {'0000a040','c2b8b23d',true},
    {'00000041','35fa0e3e',true},
    {'00002041','c2b8323e',true},
    {'00007041','920a863e',true},
    {'0000a041','c2b8b23e',true},
    {'0000c841','f366df3e',true},
    {'00000c42','aa611c3f',true},
    {'00004842','f3665f3f',true},
    {'0000c842','f366df3f',true},
    {'00003443','db0f4940',true},
}
for _,case in ipairs(cases) do
    local result=assert(P.native_cap(unhex(case[1])))
    assert(result==unhex(case[2]),'Native float32 conversion mismatch: '..case[1])
    assert(P.should_limit(result)==case[3],'Native cap policy mismatch: '..case[1])
end
for _,bad in ipairs({'','abc','abcde',unhex('00000080'),unhex('0000807f'),unhex('0100c07f'),unhex('00003543')}) do
    assert(P.native_cap(bad)==nil,'Unsupported angle admitted')
end
assert(P.native_cap(nil)==nil);assert(P.should_limit(nil)==false)
assert(P.should_limit(unhex('0100c07f'))==false)
assert(P.should_limit(unhex('0000807f'))==false)
print('ADS parameters: 14 float32/native-policy cases and invalid-input guards passed')
