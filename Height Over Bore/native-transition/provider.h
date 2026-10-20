#pragma once
#include "transition_core.h"
#define HBTP_API extern "C" __declspec(dllexport)

struct HBTP_Stats {
    uint32_t size, abi, subscribed, failed;
    uint64_t entered, exited, wielded, unwielded, retired, shutdowns, wrong_thread;
};
// Native subscriber only, not a LuaJIT FFI callback. Its module is pinned.
// 1 = subscribed, 0 = rejected, 2 = incomplete cleanup (retain context).
HBTP_API uint32_t HBTP_Open(hob::Sink sink, void* context);
HBTP_API uint32_t HBTP_Close();
HBTP_API uint32_t HBTP_ReadStats(HBTP_Stats* stats);
struct HBTP_HoBStats {
    uint32_t size,abi,enabled,ads,owned,eligible;
    uint64_t preparations,definition_searches,applications,restorations,foreign_edits;
};
static_assert(sizeof(HBTP_HoBStats)==64,"HoB statistics ABI");
// 0 = activation-closed offline build; 1 = guarded live-review build.
HBTP_API uint32_t HBTP_BuildMode();
// Explicit startup diagnostics: stage, hook index, MinHook status, Windows error.
struct HBTP_Diagnostic { uint32_t size,abi,stage,index; int32_t native_status; uint32_t windows_error; };
HBTP_API uint32_t HBTP_ReadDiagnostic(HBTP_Diagnostic*);
HBTP_API uint32_t HBTP_OpenHoB(uint32_t enabled);
HBTP_API uint32_t HBTP_SetEnabled(uint32_t enabled);
HBTP_API uint32_t HBTP_ReadHoBStats(HBTP_HoBStats* stats);

#if defined(HBTP_FIXTURE)
#include "commit_stub.h"
struct HBTP_Snapshot {
    uint64_t world, implementation, manager;
    uint32_t avatar, weapon, index, body;
    uint64_t camera;
};
struct HBTP_TestBinding {
    uint64_t targets[4], retire_slot, shutdown_slot;
    bool (*snapshot)(HBTP_Snapshot*) noexcept;
    bool (*camera)(uint64_t, uint32_t, uint32_t) noexcept;
    bool (*unwield)(uint64_t, uint32_t, uint32_t, uint32_t) noexcept;
    bool (*retire)(uint64_t, uint32_t) noexcept;
    uint64_t creation_slot=0, image_base=0;
    uint32_t image_size=0, site_count=0;
    const hob::CommitSite* sites=nullptr;
    uint64_t lifecycle_targets[3]{}; // creation, retirement, shutdown entry points
    uint64_t consumer_game=0;
    uint32_t consumer_enabled=0;
};
HBTP_API uint32_t HBTP_TestOpen(const HBTP_TestBinding*, hob::Sink, void*);
#endif
