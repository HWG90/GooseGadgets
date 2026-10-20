local Host=mod
local ffi=require('ffi')
assert(ffi.os=='Windows' and ffi.abi('64bit'),'Native HoB requires Windows x64')
if not pcall(ffi.typeof,'HBTP_HoBStats') then ffi.cdef([[
    typedef struct HBTP_HoBStats {
        uint32_t size,abi,enabled,ads,owned,eligible;
        uint64_t preparations,definition_searches,applications,restorations,foreign_edits;
    } HBTP_HoBStats;
    uint32_t HBTP_OpenHoB(uint32_t);
    uint32_t HBTP_SetEnabled(uint32_t);
    uint32_t HBTP_Close(void);
    uint32_t HBTP_ReadHoBStats(HBTP_HoBStats*);
]]) end
assert(ffi.sizeof('HBTP_HoBStats')==64,'Native HoB ABI mismatch')
assert(type(Host.dir)=='string' and type(Host.scope)=='table','Loader directory and retained scope required')
if not pcall(ffi.typeof,'HBTP_Diagnostic') then ffi.cdef([[
    typedef struct HBTP_Diagnostic { uint32_t size,abi,stage,index; int32_t native_status; uint32_t windows_error; } HBTP_Diagnostic;
    uint32_t HBTP_ReadDiagnostic(HBTP_Diagnostic*);
]]) end
local library=ffi.load(Host.dir..'/hob_transition_live_review.dll')
-- Never unload a library referenced by retained native trampolines or cleanup.
Host.scope.hob_transition_library=library
return library
