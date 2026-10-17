-- Cosmetic Ship HUD local-alpha lease. Import/new perform no game access or
-- FFI work. The game retains every widget/resource; no hooks are acquired.
-- Run update/restore on the ordinary game Lua thread. Logical visibility and
-- animation state remain under game control; normal layout consumes alpha.
local M = {}
local STAMP, SETTER = 0x6AB3B43F, 0x1448AD0
local FP = '40574883ec20f30f104144488bf90f2ec17a237521f70100'
local ABI = 'void (*)(void *, float)'
local UI, GUI, GAME_STATE = 0x346D538, 0x347CE90, 0x3326340
local SHIP, SHIP_INIT, UI_INIT = 0x46D900, 0x4F7078, 0x24E334
local ROOTS = {
    {0x8,0x820}, {0x76040,0x820}, {0x78470,0xA40},
    {0x1D00,0x930}, {0x7BE8,0x930}, {0xD170,0x930},
    {0x7CAF8,0xA40}, {0x7D830,0xA40}, {0x7E568,0x820},
    {0x7EDD0,0x820}, {0x81950,0x820}, {0x83510,0x820},
    {0x86660,0x930},
}
local EXPECTED = FP:gsub('..',function(pair)return string.char(tonumber(pair,16))end)
local ZERO = string.rep('\0',4)
local function integer(value,maximum)
    return type(value)=='number' and value==math.floor(value) and value>=0 and value<=maximum
end
local function u32(bytes,off)
    off=off or 0
    local a,b,c,d=bytes:byte(off+1,off+4)
    assert(d,'Ship alpha integer is unreadable')
    return a+b*256+c*65536+d*16777216
end
local function zero(bytes)return u32(bytes)%2147483648==0 end
local function finite(bytes)return math.floor(u32(bytes)/8388608)%256~=255 end

function M.new(backend,io)
    assert(type(backend)=='table' and type(backend.read)=='function',
        'Protected Bridge Combat backend is required')
    assert(type(io)=='table' and type(io.module)=='function' and type(io.native)=='function',
        'Protected native IO is required')
    local self={}
    local lease,binding,binding_game,ffi,void_pointer,float_pointer
    local message,fault,active='Disabled',nil,false
    local function read(at,size)
        assert(integer(at,2^47-1) and at>=65536 and integer(size,64) and size>0
            and at+size<=2^47,'Ship alpha read bounds differ')
        local bytes,why=backend:read(at,size)
        assert(type(bytes)=='string' and #bytes==size,why or 'Ship alpha memory is unreadable')
        return bytes
    end
    local function word(at)return u32(read(at,4))end
    local function pointer(at,optional)
        local bytes=read(at,8)
        local value=u32(bytes)+u32(bytes,4)*4294967296
        assert((optional and value==0) or (integer(value,2^47-1) and value>=65536),
            'Ship alpha pointer is absent or invalid')
        return value
    end
    local function byte(at)return read(at,1):byte()end
    local function retire(why)
        lease=nil;active=false;message=why or 'Ship presentation retired'
    end
    -- Positive retirement is established through current globals before any old
    -- widget address is read. Unreadability retains ownership for later cleanup.
    local function current()
        local game,_,stamp=io.module('game.dll')
        assert(integer(game,2^47-1) and game>=65536 and stamp==STAMP,'Unsupported Ship alpha game build')
        if lease and game~=lease.game then retire('Ship alpha module replaced')end
        local state=pointer(game+GAME_STATE)
        if word(state+0xAC21C)~=3 then retire('Waiting for the ship bridge');return nil end
        local ui=pointer(game+UI,true)
        if lease and ui~=lease.ui then retire('Ship UI replaced')end
        if ui==0 then retire('Waiting for the Ship UI');return nil end
        if byte(ui+UI_INIT)~=1 or byte(ui+SHIP_INIT)~=1 then
            retire('Waiting for the initialized Ship UI');return nil
        end
        local gui=pointer(game+GUI)
        if lease then assert(gui==lease.gui,'Ship alpha GUI owner changed')end
        return {game=game,state=state,ui=ui,gui=gui,context=gui+5*0x3698}
    end
    local function root_value(s,index)
        local spec=ROOTS[index];local at=s.ui+SHIP+spec[1]
        assert(pointer(at+0xF0)==s.ui+spec[2],('Ship widget parent differs at +%X'):format(spec[1]))
        assert(pointer(at+0xF8)==s.context,('Ship widget context differs at +%X'):format(spec[1]))
        -- 1448AD0 cancels an existing alpha animation. Refuse that state rather
        -- than retiring the game's animation slot or borrowing its pool entry.
        local flags,animations=word(at),word(at+0xB0)
        assert(math.floor(flags/0x08000000)%2==0 or math.floor(animations/2048)%2048==0,
            ('Ship widget alpha animation is active at +%X'):format(spec[1]))
        local alpha=read(at+0x44,4)
        assert(finite(alpha),'Ship widget local alpha is not finite')
        return {at=at,alpha=alpha}
    end
    local function roots(s)
        assert(read(s.game+SETTER,#EXPECTED)==EXPECTED,'Ship widget alpha fingerprint differs')
        local values={}
        for index=1,#ROOTS do values[index]=root_value(s,index)end
        return values
    end
    local function still_current(s,index)
        local now=current()
        if not now then return false end
        if now.game~=s.game or now.state~=s.state or now.ui~=s.ui or now.gui~=s.gui then
            retire('Ship presentation changed during alpha update');return false
        end
        assert(read(s.game+SETTER,#EXPECTED)==EXPECTED,'Ship widget alpha fingerprint differs')
        root_value(s,index)
        return true
    end
    local function setter(s)
        if not binding or binding_game~=s.game then
            local why
            binding,why=io.native(s.game+SETTER,ABI,FP,'BRIDGE_SHIP_WIDGET_ALPHA')
            assert(binding,why or 'Ship widget alpha binding is unavailable')
            binding_game=s.game
        end
        if not ffi then
            ffi=backend._ffi or backend.ffi or require('ffi')
            void_pointer=ffi.typeof('void *');float_pointer=ffi.typeof('const float *')
        end
        return binding
    end
    local function set(s,index,bytes)
        if not still_current(s,index)then return false end
        local fn=setter(s)
        fn(ffi.cast(void_pointer,s.ui+SHIP+ROOTS[index][1]),tonumber(ffi.cast(float_pointer,bytes)[0]))
        if not still_current(s,index)then return false end
        assert(read(s.ui+SHIP+ROOTS[index][1]+0x44,4)==bytes,
            'Ship widget alpha call was not acknowledged')
        return true
    end
    local function perform(fn)
        local ok,value,why=pcall(fn)
        if not ok then active=false;fault=tostring(value);message=fault;return nil,fault end
        fault=nil;return value,why
    end
    function self:restore()
        if not lease or not next(lease.owned)then retire('Disabled');fault=nil;return true end
        return perform(function()
            local s=current()
            if not s or not lease then return true end
            local values=roots(s) -- All thirteen preflight before the first call.
            setter(s)
            for index,value in ipairs(values)do
                local original=lease.owned[index]
                if original then
                    -- A nonzero native/foreign update no longer matches our
                    -- zero lease. Preserve it rather than writing old alpha.
                    if zero(value.alpha) and not set(s,index,original)then return true end
                    if not lease then return true end
                    lease.owned[index]=nil
                end
            end
            retire('Disabled');return true
        end)
    end
    function self:update(enabled)
        assert(type(enabled)=='boolean','Ship alpha enable value must be boolean')
        if not enabled then return self:restore()end
        return perform(function()
            local s=current()
            if not s then return true end
            local menu=pointer(s.game+0x347CE28)
            if word(menu+0x4294)~=0 or word(menu+0x4298)~=0 then
                active=false;message='Waiting for normal bridge gameplay';return true
            end
            local values=roots(s)
            setter(s)
            if not lease then lease={game=s.game,ui=s.ui,gui=s.gui,owned={}}end
            for index,value in ipairs(values)do
                if not zero(value.alpha)then
                    -- Capture the latest normal alpha before masking a native
                    -- reset. Journal before the void call in case readback fails.
                    lease.owned[index]=value.alpha
                    if not set(s,index,ZERO)then return true end
                end
            end
            active=true;message='Ship local alpha changes acknowledged';return true
        end)
    end
    function self:status()
        local owned=0
        if lease then for _ in pairs(lease.owned)do owned=owned+1 end end
        return {active=active,owned=owned,pending=owned>0,message=message,error=fault}
    end
    return self
end
return M
