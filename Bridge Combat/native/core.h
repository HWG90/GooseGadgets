#pragma once
#include <windows.h>
#include <atomic>
#include <cstdint>
#include <string>

namespace bc {
// Published once per lease and retained for the process lifetime. Only enabled
// changes after publication; native detours never enter Lua or own game objects.
struct Owner {
    std::atomic<uint32_t> enabled{0};
    uintptr_t game{}, state{}, ui{}, pm{}, pc{}, descriptor{};
    uintptr_t health{}, health_runtime{}, health_descriptor{};
    uint32_t avatar{};
    DWORD game_thread{};
    uintptr_t player{}, world{};
    uint32_t local_unit{};
    std::atomic<uint32_t> expected_scene{3};
    std::atomic<uint32_t> mode_owned{0};
    std::atomic<uint32_t> actor_initialized{0};
    uint32_t level_id{};
    uintptr_t flow_world{}, audio_world{}, mission_manager{};
    bool actor_test{}; // Immutable: explicit actor-only route owns no native mode.
};
Owner* current();
bool active(const Owner* owner);
bool fingerprint(uintptr_t address, const char* hex);
bool stage_hook(uintptr_t address, void* replacement, void** original,
                const char* expected, std::string& error);
template<class T> bool read(uintptr_t address, T& value) {
    if (address < 0x10000 || address > 0x7FFFFFFFFFFFULL - sizeof(T)) return false;
    __try { value = *reinterpret_cast<const T*>(address); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
template<class T> T value(uintptr_t address, T fallback = T{}) {
    T result{}; return read(address, result) ? result : fallback;
}
}
