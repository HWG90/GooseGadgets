#pragma once
#include <windows.h>
#include <cstdint>
#include <string>

namespace bc::ship_hud {
struct Identity {
    uintptr_t game{}, ui{};
    DWORD thread{};
};
enum class Phase : uint32_t {
    None, DestroyCalling, DestroyReturned, Suppressed, RebuildCalling,
    RebuildReturned, Rebuilt, ResizeCalling, ResizeReturned,
    InterruptedDestroy, InterruptedRebuild, InterruptedResize
};
struct Status {
    Phase phase{};
    bool prepared{}, hooks_enabled{}, owned{}, gui_restore_pending{}, retired{}, lifecycle_blocked{};
};
// Independent Ship HUD presentation only. No actor, scene, role or Mission HUD
// state is changed. Preparation creates exactly two disabled lifecycle hooks.
bool prepare(const Identity& identity, std::string& error);
bool suppress(std::string& error);
bool restore(std::string& error);
// The owning thread must acknowledge restoration/retirement before removal.
// This removes only this module's two hooks; it never uses MH_ALL_HOOKS.
bool release(std::string& error);
Status status();
}

#ifdef BC_NATIVE_TEST_API
extern "C" {
__declspec(dllexport) int BC_ship_hud_prepare();
__declspec(dllexport) int BC_ship_hud_suppress();
__declspec(dllexport) int BC_ship_hud_restore();
__declspec(dllexport) int BC_ship_hud_release();
__declspec(dllexport) uint32_t BC_ship_hud_phase();
__declspec(dllexport) uint32_t BC_ship_hud_flags();
__declspec(dllexport) const char* BC_ship_hud_error();
}
#endif
