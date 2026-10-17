#pragma once
#include <windows.h>
#include <cstdint>
#include <string>

namespace bc::mission_hud {
struct Identity { uintptr_t game{},exe{}; uint32_t pid{},avatar{}; DWORD thread{}; };
struct Io {
    bool (*read)(uintptr_t,void*,size_t){};
    bool (*write)(uintptr_t,const void*,size_t){};
};
enum class Phase : uint32_t {
    None,Prepared,ShipDestroyCalling,ShipDestroyReturned,ShipAbsent,
    MissionInitCalling,MissionInitReturned,MissionReady,InactiveCalling,InactiveReturned,
    ActivateCalling,ActivateReturned,ResizeCalling,ResizeReturned,Active,
    DeactivateCalling,DeactivateReturned,MissionDestroyCalling,MissionDestroyReturned,MissionAbsent,
    ShipInitCalling,ShipInitReturned,ShipReady,ShipActiveCalling,ShipActiveReturned,
    ShipResizeCalling,ShipResizeReturned,Restored,Retired,Interrupted
};
struct Status {
    Phase phase{};
    bool prepared{},widgets_ready{},active{},stopped{},retired_safe{},role8_owned{},
        lifecycle_blocked{},hooks_enabled{},cleanup_pending{};
};
// No game access at DLL import. prepare stages exactly three disabled hooks;
// start owns only the two direct HUD presentations and local role8 it acquires.
bool prepare(const Identity&,std::string&,Io = {});
bool start(std::string&);
bool tick(float,uint32_t pid,uint32_t avatar,std::string&);
bool stop(std::string&);
bool release(std::string&);
Status status();
#ifdef BC_NATIVE_TEST_API
// A review-only coherent game-thread transaction. It never stages hooks or
// retains a successful HUD across frames. A failed native call pins its journal.
bool probe(const Identity&,std::string&,Io = {});
enum ProbeReceipt : uint32_t {
    ProbePreflight=1,ProbeShipRemoved=2,ProbeMissionConstructed=4,
    ProbeTreeAttached=8,ProbeActivated=16,ProbeResized=32,ProbeDataReturned=64,
    ProbeOptionsCancelled=128,ProbeMissionRemoved=256,ProbeShipRestored=512,
    ProbeGuiRestored=1024,ProbeComplete=2048
};
uint32_t probe_flags();
// Read-only retained evidence. This never acknowledges or releases a journal.
const char* probe_diagnostics();
#endif
}
extern "C" {
__declspec(dllexport) int BC_mission_hud_prepare(uint32_t pid,uint32_t avatar);
__declspec(dllexport) int BC_mission_hud_start();
__declspec(dllexport) int BC_mission_hud_tick(float dt,uint32_t pid,uint32_t avatar);
__declspec(dllexport) int BC_mission_hud_stop();
__declspec(dllexport) int BC_mission_hud_release();
__declspec(dllexport) uint32_t BC_mission_hud_phase();
__declspec(dllexport) uint32_t BC_mission_hud_flags();
__declspec(dllexport) const char* BC_mission_hud_error();
#ifdef BC_NATIVE_TEST_API
__declspec(dllexport) int BC_mission_hud_probe(uint32_t pid,uint32_t avatar);
__declspec(dllexport) uint32_t BC_mission_hud_probe_flags();
__declspec(dllexport) const char* BC_mission_hud_probe_diagnostics();
#endif
}
