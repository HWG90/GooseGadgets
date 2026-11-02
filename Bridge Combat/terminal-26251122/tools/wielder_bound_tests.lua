-- 26251122 .12: in a multiplayer session the local avatar is not the only wielder (105-148 rows live on 2026-11-01,
-- the user a client among four players). The manager field at +0x20 read 1 in every live sample, so it is not the
-- row capacity the 0.1.17 check took it for; the row index is bounded by the manager's count (+0x1C) and the
-- descriptor ownership check that follows.
test('other wielders in the session do not refuse the capture (.12 multiplayer)',function()
    local f=fixture();f:word(f.wm+0x1C,148);f:word(f.wm+0x20,1)
    local s=assert(f.lease:capture(),'Wielder live row refused with other wielders present');eq(#s.packages,2)
    assert(f.lease:acquire(s));eq(f.refs[f.p1],4);assert(f.lease:release());eq(f.refs[f.p1],3)
end)
test('a wielder row at or beyond the count is still refused',function()
    local f=fixture();f:map(f.wm+0x30,{[249]=148});f:word(f.wm+0x1C,148);f:word(f.wm+0x20,1)
    eq(f.lease:capture(),nil);eq(#f.calls,0)
end)
