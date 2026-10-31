-- Build 26251122 keeps a game.dll code page encrypted (PAGE_NOACCESS) until the game first executes it,
-- so a function the ship never runs cannot be checked or called until a mission has run it. The game's
-- own handler decrypts a page on any execute fault, so executing one `ret` on the page is enough
-- (checked live 2026-10-30 03:04 on the ship: page +0x9c0000 went from protection 1 to 0x20 and read
-- back as the capture). code_warmup_sites.lua lists, for every page Bridge reads or calls, a one-byte
-- ret on it and the eight bytes there in the decrypted image.
--
-- Import does nothing. new() binds nothing. step() handles one site per call, so the caller spreads the
-- work over frames and runs it only once the ship actor is observed (the game, not its boot, is what
-- decrypts code; two launches on 2026-10-30 died with the whole table run inside the loader's enable).
-- Before a touch the page must be committed, image-backed and PAGE_NOACCESS (VirtualQuery), the site is
-- logged, and afterwards the eight bytes are read back and must match. No game memory is written.
local M={}
local DECLARATIONS=[[
    typedef struct BridgeWarm_Region {
        uint64_t base, allocation_base;
        uint32_t allocation_protection;
        uint16_t partition, reserved;
        uint64_t size;
        uint32_t state, protection, type, padding;
    } BridgeWarm_Region;
    void *BridgeWarm_GetModuleHandleA(const char *name) __asm__("GetModuleHandleA");
    void *BridgeWarm_GetCurrentProcess(void) __asm__("GetCurrentProcess");
    int BridgeWarm_ReadProcessMemory(void *process, const void *address, void *buffer, size_t size, size_t *done) __asm__("ReadProcessMemory");
    size_t BridgeWarm_VirtualQuery(const void *address, BridgeWarm_Region *region, size_t size) __asm__("VirtualQuery");
    typedef void (*BridgeWarm_Touch)(void);
]]
local MEM_COMMIT,PAGE_NOACCESS,MEM_IMAGE,MEM_MAPPED=0x1000,0x1,0x1000000,0x40000
local function unhex(s)return(s:gsub('%x%x',function(x)return string.char(tonumber(x,16))end))end
function M.new(options)
    options=options or{}
    local sites=assert(options.sites,'Warm-up sites required')
    local log=options.log or function()end
    local self={done=false,index=0,total=#sites.sites,warm=0,touched=0,failed={}}
    local ffi,kernel,base,process,buffer,done,region
    local function bind()
        ffi=require('ffi')
        if not pcall(ffi.typeof,'BridgeWarm_Touch')then ffi.cdef(DECLARATIONS)end
        kernel=ffi.C
        local handle=kernel.BridgeWarm_GetModuleHandleA('game.dll')
        assert(handle~=nil,'game.dll is not loaded')
        base=tonumber(ffi.cast('uintptr_t',handle))
        process=kernel.BridgeWarm_GetCurrentProcess()
        buffer,done,region=ffi.new('uint8_t[64]'),ffi.new('size_t[1]'),ffi.new('BridgeWarm_Region[1]')
        local function read(at,n)
            done[0]=0
            if kernel.BridgeWarm_ReadProcessMemory(process,ffi.cast('const void *',at),buffer,n,done)==0 or tonumber(done[0])~=n then return nil end
            return ffi.string(buffer,n)
        end
        -- The same build this table was made from: PE timestamp at e_lfanew+8.
        local dos=assert(read(base,64),'game.dll header is unreadable')
        local pe=dos:byte(61)+dos:byte(62)*256+dos:byte(63)*65536+dos:byte(64)*16777216
        local head=assert(read(base+pe,12),'game.dll PE header is unreadable')
        local stamp=head:byte(9)+head:byte(10)*256+head:byte(11)*65536+head:byte(12)*16777216
        assert(stamp==sites.stamp,('Warm-up table is for build %08X, game is %08X'):format(sites.stamp,stamp))
        self.read=read
    end
    local function finish()
        self.done=true
        local summary=('Code warm-up: %d pages ready, %d decrypted now%s'):format(self.warm,self.touched,
            #self.failed>0 and('; %d failed: %s'):format(#self.failed,table.concat(self.failed,', ',1,math.min(#self.failed,4)))or'')
        log(summary);self.summary=summary
        return true
    end
    -- One site per call. Returns true once every site is handled; the first failure stops the touches.
    function self:step()
        if self.done then return true end
        if not base then bind()end
        self.index=self.index+1
        local site=sites.sites[self.index]
        if not site then return finish()end
        local page,ret,expected=site[1],site[2],unhex(site[3])
        assert(ret>=page and ret<page+4096 and #expected==8,'Malformed warm-up site')
        local got=self.read(base+ret,8)
        if got==expected then self.warm=self.warm+1;return false end
        if got~=nil then self.failed[#self.failed+1]=('+0x%x differs'):format(ret);return finish()end
        local r=region[0]
        if tonumber(kernel.BridgeWarm_VirtualQuery(ffi.cast('const void *',base+ret),region,ffi.sizeof(r)))~=ffi.sizeof(r)
            or tonumber(r.state)~=MEM_COMMIT or tonumber(r.protection)~=PAGE_NOACCESS
            or(tonumber(r.type)~=MEM_IMAGE and tonumber(r.type)~=MEM_MAPPED)then
            self.failed[#self.failed+1]=('+0x%x is not a committed no-access image page (state %x protection %x type %x)'):format(
                ret,tonumber(r.state),tonumber(r.protection),tonumber(r.type))
            return finish()
        end
        log(('Code warm-up: page +0x%x (%d/%d), ret at +0x%x'):format(page,self.index,self.total,ret))
        ffi.cast('BridgeWarm_Touch',base+ret)()
        self.touched=self.touched+1
        got=self.read(base+ret,8)
        if got==expected then self.warm=self.warm+1;return false end
        self.failed[#self.failed+1]=('+0x%x %s after touch'):format(ret,got and'differs'or'still unreadable')
        return finish()
    end
    function self:status()
        if self.done then return self.summary end
        return ('Code warm-up: %d of %d pages'):format(self.index,self.total)
    end
    return self
end
return M
