-- Native per-weapon customization state, derived from 1034BD0..1034D60.
-- Each of three presets starts with the weapon's own default attachments.
local M={BASE=0x178A4EC,SIZE=148,CAPACITY=512}
function M.record(C,defaults)
    assert(type(defaults)=='string' and #defaults==80,'Native defaults are unreadable')
    local slots={};for i=0,9 do slots[i]=0 end
    for i=0,9 do
        local slot,id=C.u32(defaults,i*8),C.u32(defaults,i*8+4)
        assert(slot<=10,'Native customization slot changed')
        if slot>0 and slot<10 then slots[slot]=id end
    end
    local preset={};for i=0,9 do preset[#preset+1]=C.word(slots[i])end
    -- ID, native primary kind (0), selected preset (0), 3x40 bytes,
    -- then four preferred-mode fields. No attachment records are fabricated.
    return C.word(C.ID)..C.word(0)..C.word(0)..string.rep(table.concat(preset),3)..string.rep('\0',16)
end
return M
