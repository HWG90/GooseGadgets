#pragma once
#include <cstdint>
#include <windows.h>

// Offline component only. The caller must be a verified synchronous native
// lifecycle adapter. These entry points do not install hooks or observe memory.
namespace hob {
enum class Event : uint32_t { world_begin, equipped, ads_enter, ads_exit, unequipped, world_end };
enum class Reason : uint32_t { ordinary, camera_replaced, weapon_change, death, world_teardown, disable };
struct Identity {
    uint64_t world = 0, generation = 0;
    uint32_t avatar = 0, weapon = 0;
};
struct Notice { Event event; Reason reason; Identity identity; };
// Native, non-throwing sink. Never call a LuaJIT closure from this boundary.
// False means the consumer failed; no automatic retry or continued application.
using Sink = bool (*)(void*, const Notice&) noexcept;
struct State {
    Identity identity{};
    bool ads = false, failed = false, live = false;
    uint64_t notices = 0;
};
class TransitionCore final {
public:
    TransitionCore(Sink sink, void* context) noexcept;
    TransitionCore(const TransitionCore&) = delete;
    TransitionCore& operator=(const TransitionCore&) = delete;
    bool begin(uint64_t world, uint64_t generation, uint32_t avatar) noexcept;
    bool equip(uint64_t generation, uint32_t weapon) noexcept;
    bool enter(uint64_t generation, uint32_t weapon) noexcept;
    bool leave(uint64_t generation, Reason reason) noexcept;
    bool unequip(uint64_t generation, Reason reason) noexcept;
    bool end(uint64_t generation, Reason reason) noexcept;
    State state() const noexcept { return state_; } // owner thread only
private:
    bool allowed(uint64_t generation) const noexcept;
    bool send(Event event, Reason reason) noexcept;
    bool leave_inner(Reason reason) noexcept;
    bool unequip_inner(Reason reason) noexcept;
    Sink sink_;
    void* context_;
    DWORD thread_;
    bool dispatching_ = false;
    uint64_t retired_generation_ = 0;
    State state_{};
};
}
