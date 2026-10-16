-- Comparison settings, not recovered historical values. Pure data; no game IO.
-- Native conversion float32(.5 * float32(35FA8E3C)) = 35FA0E3C.
-- The engine returns its native corrected direction unchanged when the required
-- angle <= this positive cap. Larger corrections are limited at any distance.
local ffi=require('ffi')
local M={
    NATIVE = string.char(0xDB,0x0F,0x49,0x40), -- float32 pi
    TARGET = string.char(0x35,0xFA,0x0E,0x3C), -- float32 0.5 degrees in radians
    DEGREES = 0.5,
    RADIANS = 0.008726646192371845,
}
local function scalar(bytes)
    if type(bytes)~='string' or #bytes~=4 then return nil end
    -- Authored native limits in this build are finite and non-negative. Do not
    -- guess at custom negative/NaN values, including signed negative zero.
    if bytes:byte(4)>=128 then return nil end
    local v=ffi.new('float[1]');ffi.copy(v,bytes,4)
    local value=tonumber(v[0])
    if not value or value~=value or value==math.huge then return nil end
    return value
end
function M.native_cap(angle_bytes)
    local angle=scalar(angle_bytes)
    if not angle or angle>180 then return nil,'Unsupported authored aiming angle' end
    local conversion=ffi.new('float[1]');ffi.copy(conversion,string.char(0x35,0xFA,0x8E,0x3C),4)
    local radians=ffi.new('float[1]',angle*tonumber(conversion[0]))
    return ffi.string(radians,4),angle
end
function M.should_limit(native_bytes)
    local value=scalar(native_bytes)
    return value~=nil and value>M.RADIANS and value<=3.1415927410125732
end
return M
