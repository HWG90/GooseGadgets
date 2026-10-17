#include "core.h"
#include "mode.h"
#include "actor.h"
#include <vector>
#include <cstring>
#include <new>
#include <array>
#include <cstdio>
#include <cmath>

namespace {
std::atomic<bc::Owner*> published{nullptr};
char last_error[512]{};
void fail(const std::string& message) { strncpy_s(last_error, message.c_str(), _TRUNCATE); }
bool map_index(uintptr_t header, uint32_t key, uint32_t& index) {
    const auto buckets = bc::value<uintptr_t>(header);
    const auto cap = bc::value<uint32_t>(header + 8);
    const auto empty = bc::value<uint32_t>(header + 12);
    const auto multiplier = bc::value<uint32_t>(header + 16);
    if (!buckets || !cap || cap > 1048576 || (cap & (cap - 1)) || key == empty) return false;
    uint32_t slot = (key * multiplier) & (cap - 1);
    for (uint32_t count = 0; count < cap && count < 4096; ++count) {
        uint32_t found{};
        if (!bc::read(buckets + slot * 8ULL, found) || found == empty) return false;
        if (found == key) return bc::read(buckets + slot * 8ULL + 4, index) && index != UINT32_MAX;
        slot = (slot + 1) & (cap - 1);
    }
    return false;
}
bool discover(bc::Owner& owner, uint32_t expected_avatar) {
    owner.game = reinterpret_cast<uintptr_t>(GetModuleHandleW(L"game.dll"));
    if (!owner.game) return false;
    const auto pe = bc::value<int32_t>(owner.game + 0x3C);
    if (pe < 0x40 || pe > 0x1000 || bc::value<uint32_t>(owner.game + pe) != 0x4550
        || bc::value<uint32_t>(owner.game + pe + 8) != 0x6AB3B43F) return false;
    owner.state = bc::value<uintptr_t>(owner.game + 0x3326340);
    owner.ui = bc::value<uintptr_t>(owner.game + 0x346D538);
    owner.pm = bc::value<uintptr_t>(owner.game + 0x3326D20);
    const auto player = bc::value<uintptr_t>(owner.game + 0x3326468);
    const auto world = bc::value<uintptr_t>(owner.game + 0x346BF98);
    const auto unit = bc::value<uint32_t>(player + 0x3A8);
    owner.player = player; owner.world = world; owner.local_unit = unit;
    uint32_t wi{}, pi{}, hi{};
    if (!owner.state || !owner.ui || !owner.pm || !player || !world || !unit
        || bc::value<uint32_t>(owner.state + 0xAC21C) != 3
        || !map_index(world + 0xF22EC8, unit, wi) || wi >= 1048576) return false;
    owner.avatar = bc::value<uint32_t>(world + 0xF32F18 + wi * 24ULL + 8);
    if (!owner.avatar || owner.avatar != expected_avatar || !map_index(owner.pm + 0xF8, owner.avatar, pi) || pi >= 128) return false;
    owner.pc = owner.pm + 0x53D8B0 + pi * 0x1238ULL;
    owner.descriptor = bc::value<uintptr_t>(owner.pm + 0x110 + pi * 8ULL);
    if (!owner.descriptor || bc::value<uint32_t>(owner.descriptor + 8) != owner.avatar
        || !(bc::value<uint8_t>(owner.descriptor + 0x14) & 1)) return false;
    owner.health = bc::value<uintptr_t>(owner.game + 0x3326688);
    if (!owner.health || !map_index(owner.health + 0x1030, owner.avatar, hi)
        || hi >= bc::value<uint32_t>(owner.health + 0x101C)) return false;
    const auto descriptors = bc::value<uintptr_t>(owner.health + 0x1048);
    const auto runtimes = bc::value<uintptr_t>(owner.health + 0x1058);
    owner.health_descriptor = bc::value<uintptr_t>(descriptors + hi * 8ULL);
    owner.health_runtime = runtimes + hi * 0x1B8ULL;
    if (!descriptors || !runtimes || !owner.health_descriptor
        || bc::value<uint32_t>(owner.health_descriptor + 8) != owner.avatar
        || !(bc::value<uint8_t>(owner.health_descriptor + 0x14) & 1)) return false;
    owner.game_thread = GetCurrentThreadId();
    return true;
}
}

namespace bc {
Owner* current() { return published.load(std::memory_order_acquire); }
bool active(const Owner* owner) {
    return owner && owner->enabled.load(std::memory_order_acquire)
        && value<uintptr_t>(owner->game + 0x3326340) == owner->state
        && value<uint32_t>(owner->state + 0xAC21C) == owner->expected_scene.load(std::memory_order_acquire)
        && value<uintptr_t>(owner->game + 0x346D538) == owner->ui
        && value<uintptr_t>(owner->game + 0x3326D20) == owner->pm
        && value<uintptr_t>(owner->game + 0x3326468) == owner->player
        && value<uintptr_t>(owner->game + 0x346BF98) == owner->world
        && value<uint32_t>(owner->player + 0x3A8) == owner->local_unit
        && value<uint32_t>(owner->descriptor + 8) == owner->avatar
        && (value<uint8_t>(owner->descriptor + 0x14) & 1);
}
bool fingerprint(uintptr_t address, const char* hex) {
    if (!hex) return false;
    const auto count = strlen(hex);
    if (!count || count > 256 || count % 2) return false;
    for (size_t i = 0; i < count; i += 2) {
        auto digit = [](char c) { return c >= '0' && c <= '9' ? c-'0' : c >= 'a' && c <= 'f' ? c-'a'+10 : -1; };
        const int high = digit(hex[i]), low = digit(hex[i+1]); uint8_t actual{};
        if (high < 0 || low < 0 || !read(address + i/2, actual) || actual != ((high<<4)|low)) return false;
    }
    return true;
}
}

extern "C" __declspec(dllexport) const char* BC_error() { return last_error; }
extern "C" __declspec(dllexport) int BC_stop();
extern "C" __declspec(dllexport) uint32_t BC_status() {
    const auto owner = bc::current(); return owner && bc::active(owner) ? 1 : 0;
}
extern "C" __declspec(dllexport) uint32_t BC_ready() {
    const auto owner = bc::current();
    return owner && bc::active(owner) && owner->actor_initialized.load(std::memory_order_acquire)
        && (owner->actor_test || bc::mode_ready(owner)) ? 1 : 0;
}
extern "C" __declspec(dllexport) int BC_start(uint32_t avatar) {
    last_error[0] = 0;
    if (bc::current()) { fail("A native lease already exists; stop it before starting another"); return 0; }
    auto owner = new(std::nothrow) bc::Owner;
    if (!owner || !discover(*owner, avatar)) { delete owner; fail("Current local bridge actor/build is not valid"); return 0; }
    // Publish an Off cleanup handle before preparation. Activation uses the
    // engine's mode lifecycle; the helper never patches module instructions.
    published.store(owner, std::memory_order_release);
    std::string error;
    if (!bc::actor_prepare(owner, error) || !bc::mode_prepare(owner, error)) {
        if (!BC_stop()) error += std::string("; cleanup pending: ") + last_error;
        fail(error); return 0;
    }
    owner->enabled.store(1, std::memory_order_release);
    if (!bc::mode_enter(owner, error)) { owner->enabled.store(0); fail(error); return 0; }
    // Both routes begin pending. Ticks own the stable equipment observation.
    owner->actor_initialized.store(0, std::memory_order_release);
    return 1;
}
// Explicit bridge animation route. The Lua controller owns combat controls;
// this route never owns mode, HUD, damage or telemetry initialization.
extern "C" __declspec(dllexport) int BC_start_actor(uint32_t avatar) {
    last_error[0] = 0;
    if (bc::current()) { fail("A native lease already exists; stop it before starting another"); return 0; }
    auto owner = new(std::nothrow) bc::Owner;
    if (!owner || !discover(*owner, avatar)) { delete owner; fail("Current local bridge actor/build is not valid"); return 0; }
    owner->actor_test = true;
    published.store(owner, std::memory_order_release);
    std::string error;
    if (!bc::actor_prepare(owner, error)) {
        if (!BC_stop()) error += std::string("; cleanup pending: ") + last_error;
        fail(error); return 0;
    }
    owner->enabled.store(1, std::memory_order_release);
    // Preparation claims cleanup while controls are already active. Defer the
    // whole graph reset to ticks, so Start+Tick in one Lua callback cannot be
    // counted as two stable equipped-weapon updates.
    owner->actor_initialized.store(0, std::memory_order_release);
    return 1;
}
#ifdef BC_NATIVE_TEST_API
extern "C" __declspec(dllexport) int BC_start_actor_test(uint32_t avatar) {
    return BC_start_actor(avatar);
}
#endif
extern "C" __declspec(dllexport) int BC_tick(float dt) {
    auto owner = bc::current();
    if (!owner) return 1;
    if (GetCurrentThreadId() != owner->game_thread) { fail("Native tick must run on its owning game thread"); return 0; }
    std::string error;
    if (!bc::active(owner)) { fail("Native actor or scene retired; restoration is required"); return 0; }
    if (!std::isfinite(dt) || dt < 0 || dt > 1) { fail("Invalid native frame delta"); return 0; }
    if (owner->actor_test) {
        // Pending ticks observe equipment. After reset_done this is read-only.
        if (!bc::actor_reset(owner, error)) { owner->actor_initialized.store(0); fail(error); return 0; }
        owner->actor_initialized.store(bc::actor_ready(owner) ? 1 : 0, std::memory_order_release);
        return 1;
    }
    if (!bc::mode_tick(owner, error)) { fail(error); return 0; }
    if (bc::mode_ready(owner)) {
        if (!bc::actor_reset(owner, error)) { owner->actor_initialized.store(0); fail(error); return 0; }
        owner->actor_initialized.store(bc::actor_ready(owner) ? 1 : 0, std::memory_order_release);
    }
    return 1;
}
extern "C" __declspec(dllexport) int BC_stop() {
    auto owner = bc::current();
    if (!owner) return 1;
    if (GetCurrentThreadId() != owner->game_thread) { fail("Native stop must run on its owning game thread"); return 0; }
    owner->enabled.store(0, std::memory_order_release);
    std::string error;
    if (!bc::mode_retired(owner) && !bc::actor_restore(owner, error)) { fail(error); return 0; }
    if (!bc::mode_restore(owner, error)) { fail(error); return 0; }
    published.store(nullptr, std::memory_order_release);
    // Lease records remain resident and this DLL stays loaded through shutdown.
    return 1;
}
