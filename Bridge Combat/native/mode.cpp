#include "mode.h"
#include <array>
#include <memory>
#include <mutex>
#include <vector>

// Direct mode entry is a controlled candidate. Completion AD4520 also enables
// telemetry and requires GeneratedLevel prerequisites absent from the ship.
// A build must explicitly approve the entry-only experiment; there is no
// timeout fallback that calls completion or clears its phase byte.
#ifndef BC_GAMEPLAY_MODE_PREFLIGHT_APPROVED
#define BC_GAMEPLAY_MODE_PREFLIGHT_APPROVED 0
#endif

namespace bc {
namespace {
constexpr uintptr_t kTransition = 0xAB2FA0;
constexpr char kTransitionFp[] = "48895c240848896c241856574154415641574883ec308bda";
constexpr uintptr_t kStateGame = 0x1FA08;
constexpr uintptr_t kShipState = 0x15118;
constexpr uintptr_t kUiInitialized = 0x24E334;
constexpr uintptr_t kMissionUi = 0x46D8F0;
constexpr uintptr_t kShipUi = 0x4F7078;
constexpr unsigned kPendingFrames = 30;
using Transition = void(__fastcall*)(void*, uint32_t, void*);

struct Lease {
    Owner* owner{};
    uintptr_t exe{}, network{}, chat{}, session{}, telemetry{}, runtime{};
    uintptr_t runtime_2d0{}, runtime_2d8{};
    uintptr_t level_definition{};
    uint32_t level_kind{};
    uint64_t local_peer{};
    uint8_t ui_initialized{}, ship_ui{}, mission_ui{};
    bool prepared{}, attempted{}, in_call{}, entered{}, returned{};
    unsigned pending_frames{};
    // GameExit owns its transient lists. Capture diagnostic headers only;
    // never copy those lists or reporting fields back over engine-owned data.
    std::array<uint8_t, 64> game_header_after{};
};
std::recursive_mutex mutex;
std::vector<std::unique_ptr<Lease>> leases;

Lease* find(const Owner* owner) {
    for (const auto& lease : leases) if (lease->owner == owner) return lease.get();
    return nullptr;
}
bool reject(std::string& error, const char* message) { error = message; return false; }
bool mapped(uintptr_t pointer) { uint8_t byte{}; return pointer && read(pointer, byte); }
bool actor_current(const Owner* o) {
    return o && value<uintptr_t>(o->game + 0x3326D20) == o->pm
        && value<uintptr_t>(o->game + 0x3326468) == o->player
        && value<uint32_t>(o->player + 0x3A8) == o->local_unit
        && value<uint32_t>(o->descriptor + 8) == o->avatar
        && (value<uint8_t>(o->descriptor + 0x14) & 1) != 0;
}
bool world_same(const Owner* o) {
    return o && value<uintptr_t>(o->game + 0x3326340) == o->state
        && value<uintptr_t>(o->game + 0x346BF98) == o->world
        && value<uintptr_t>(o->game + 0x346D538) == o->ui
        && value<uint32_t>(o->state + 0x10F0) == o->level_id
        && value<uintptr_t>(o->state + 0x10E8) == o->flow_world
        && value<uintptr_t>(o->game + 0x346BFA0) == o->flow_world
        && value<uintptr_t>(o->pm + 8) == o->flow_world
        && value<uintptr_t>(o->state + 0x10F8) == o->audio_world;
}
bool environment(Owner* o, const Lease& lease, std::string& error) {
    if (!world_same(o)) return reject(error, "Original authored ship world or level changed");
    uint32_t loading{};
    std::array<uint8_t, 32> pending{};
    if (!read(o->state + 0xAC218, loading) || loading != 0
        || !read(o->state + kShipState + 0xA40, pending))
        return reject(error, "A loading or pending ship transition is active");
    for (uint8_t byte : pending) if (byte != 0)
        return reject(error, "A pending ship transition token is active");
    uint32_t missions{};
    uintptr_t descriptor{};
    uint8_t live{}, reporting{};
    if (value<uintptr_t>(o->game + 0x3326968) != o->mission_manager
        || !read(o->mission_manager + 0x10, missions) || missions != 0
        || !read(o->mission_manager + 0x430, descriptor) || !descriptor
        || !read(descriptor + 0x14, live) || (live & 1) != 0)
        return reject(error, "A mission descriptor is active or unavailable");
    if (value<uintptr_t>(o->game + 0x347CE18) != lease.telemetry
        || !read(lease.telemetry + 0x31276, reporting) || reporting != 0)
        return reject(error, "Mission reporting is active; its data is preserved");
    if (value<uintptr_t>(o->state + 0xAE288) != lease.runtime
        || value<uint32_t>(lease.runtime + 0x1E4, UINT32_MAX) != lease.level_kind
        || value<uintptr_t>(lease.runtime + 0x218) != lease.level_definition
        || value<uintptr_t>(lease.runtime + 0x2D0) != lease.runtime_2d0
        || value<uintptr_t>(lease.runtime + 0x2D8) != lease.runtime_2d8
        || !mapped(lease.runtime_2d0) || !mapped(lease.runtime_2d8))
        return reject(error, "Authored level runtime prerequisites changed");
    return true;
}
bool peers(const Owner* o, const Lease& lease, bool require_solo, std::string& error) {
    uint64_t local{}, host{}, session_local{}, session_host{};
    uint32_t total{}, connected{};
    uintptr_t rows{};
    const uintptr_t network_root = value<uintptr_t>(lease.exe + 0x2361D88);
    if (value<uintptr_t>(o->game + 0x347CEF0) != lease.network
        || value<uintptr_t>(o->game + 0x347CED8) != lease.chat
        || value<uintptr_t>(network_root + 0xA8) != lease.session
        || !read(lease.network + 0xB398, local) || !local || local != lease.local_peer
        || !read(lease.network + 0xB3A8, host) || (host && host != local)
        || !read(lease.session + 0x20, session_local) || session_local != local
        || !read(lease.session + 0x130, session_host) || (session_host && session_host != local)
        || !read(lease.session + 0x138, total) || total == 0 || total > 8
        || !read(lease.session + 0x140, rows) || !rows)
        return reject(error, "Local host/session authority is unavailable");
    unsigned local_rows = 0;
    for (uint32_t i = 0; i < total; ++i) {
        uint64_t key{};
        if (!read(rows + i * 0x30ULL, key) || !key)
            return reject(error, "Session peer row is unavailable");
        if (key == local) ++local_rows;
        else if (require_solo) return reject(error, "A joined or synchronizing remote peer is present");
    }
    if (local_rows != 1 || (require_solo && total != 1))
        return reject(error, "The session is not an owned solo session");
    unsigned occupied = 0, me = 0;
    for (uint32_t i = 0; i < 8; ++i) {
        uint64_t key{};
        if (!read(lease.chat + i * 0xC0ULL, key)) return reject(error, "Chat peer list is unreadable");
        if (key) { ++occupied; if (key == local) ++me; }
    }
    if (me != 1 || (require_solo && occupied != 1))
        return reject(error, "The local peer list is not solo and stable");
    if (!read(lease.network + 0x16390, connected) || connected > 8)
        return reject(error, "Connected peer list is unavailable");
    for (uint32_t i = 0; i < connected; ++i) {
        uint64_t key{};
        if (!read(lease.network + 0x16398 + i * 0x20ULL, key) || !key
            || (require_solo && key != local))
            return reject(error, "A connected remote or unknown peer is present");
    }
    return true;
}
bool ui_original(const Owner* o, const Lease& lease) {
    uint8_t common{}, ship{}, mission{};
    return read(o->ui + kUiInitialized, common) && read(o->ui + kShipUi, ship)
        && read(o->ui + kMissionUi, mission) && common == lease.ui_initialized
        && ship == lease.ship_ui && mission == lease.mission_ui;
}
bool invoke(Owner* owner, uint32_t scene, DWORD& exception) {
    const auto function = reinterpret_cast<Transition>(owner->game + kTransition);
    __try { function(reinterpret_cast<void*>(owner->state), scene, nullptr); return true; }
    __except(EXCEPTION_EXECUTE_HANDLER) { exception = GetExceptionCode(); return false; }
}
}

bool mode_prepare(Owner* owner, std::string& error) {
    std::lock_guard<std::recursive_mutex> lock(mutex);
    if (!owner || GetCurrentThreadId() != owner->game_thread || find(owner))
        return reject(error, "Native mode preparation requires a new owning game-thread lease");
    auto lease = std::make_unique<Lease>();
    lease->owner = owner;
    owner->level_id = value<uint32_t>(owner->state + 0x10F0);
    owner->flow_world = value<uintptr_t>(owner->state + 0x10E8);
    owner->audio_world = value<uintptr_t>(owner->state + 0x10F8);
    owner->mission_manager = value<uintptr_t>(owner->game + 0x3326968);
    lease->runtime = value<uintptr_t>(owner->state + 0xAE288);
    lease->runtime_2d0 = value<uintptr_t>(lease->runtime + 0x2D0);
    lease->runtime_2d8 = value<uintptr_t>(lease->runtime + 0x2D8);
    lease->level_kind = value<uint32_t>(lease->runtime + 0x1E4, UINT32_MAX);
    lease->level_definition = value<uintptr_t>(lease->runtime + 0x218);
    lease->telemetry = value<uintptr_t>(owner->game + 0x347CE18);
    lease->network = value<uintptr_t>(owner->game + 0x347CEF0);
    lease->chat = value<uintptr_t>(owner->game + 0x347CED8);
    lease->local_peer = value<uint64_t>(lease->network + 0xB398);
    lease->exe = reinterpret_cast<uintptr_t>(GetModuleHandleW(L"helldivers2.exe"));
    const auto pe = value<int32_t>(lease->exe + 0x3C);
    if (!lease->exe || pe < 0x40 || pe > 0x1000
        || value<uint32_t>(lease->exe + pe) != 0x4550
        || value<uint32_t>(lease->exe + pe + 8) != 0x6AB382E4)
        return reject(error, "Native session executable build is unsupported");
    lease->session = value<uintptr_t>(value<uintptr_t>(lease->exe + 0x2361D88) + 0xA8);
    const uintptr_t vtable = value<uintptr_t>(lease->session);
    if (value<uintptr_t>(vtable + 0x68) != lease->exe + 0x292BD0
        || value<uintptr_t>(vtable + 0x70) != lease->exe + 0x292BE0
        || value<uintptr_t>(vtable + 0x78) != lease->exe + 0x292BF0
        || value<uintptr_t>(vtable + 0xA0) != lease->exe + 0x292CD0
        || !fingerprint(lease->exe + 0x292BD0, "488b4120c3")
        || !fingerprint(lease->exe + 0x292BE0, "8b8138010000c3")
        || !fingerprint(lease->exe + 0x292BF0, "8bc2488d1440488b81400100004803d2488b04d0c3")
        || !fingerprint(lease->exe + 0x292CC0, "488b8130010000c3")
        || !fingerprint(lease->exe + 0x292CD0, "448b893801000033c04585c974264c8b9140010000")
        || !fingerprint(owner->game + kTransition, kTransitionFp))
        return reject(error, "Native session or mode lifecycle fingerprint mismatch");
    if (!mapped(owner->world) || !mapped(owner->flow_world) || !mapped(owner->audio_world)
        || !owner->mission_manager || !lease->telemetry || !lease->runtime
        || lease->level_kind != 0 || !mapped(lease->level_definition)
        || !lease->network || !lease->chat || !lease->session || owner->level_id != 2
        || value<uint32_t>(owner->state + 0xAC21C) != 3 || !actor_current(owner)
        || !environment(owner, *lease, error) || !peers(owner, *lease, true, error))
        return error.empty() ? reject(error, "Authored solo ship prerequisites are unavailable") : false;
    if (!read(owner->ui + kUiInitialized, lease->ui_initialized) || lease->ui_initialized != 1
        || !read(owner->ui + kShipUi, lease->ship_ui) || lease->ship_ui != 1
        || !read(owner->ui + kMissionUi, lease->mission_ui) || lease->mission_ui != 0)
        return reject(error, "Original ship UI initialization is not ready");
#if !BC_GAMEPLAY_MODE_PREFLIGHT_APPROVED
    return reject(error, "Native mode candidate awaits completion/account contract approval");
#else
    lease->prepared = true;
    leases.push_back(std::move(lease));
    return true;
#endif
}

bool mode_enter(Owner* owner, std::string& error) {
    std::lock_guard<std::recursive_mutex> lock(mutex);
    auto* lease = find(owner);
    if (!lease || !lease->prepared || lease->attempted || lease->in_call
        || GetCurrentThreadId() != owner->game_thread)
        return reject(error, "Native mode entry has no fresh prepared lease");
    if (!environment(owner, *lease, error) || !peers(owner, *lease, true, error)
        || !actor_current(owner) || !ui_original(owner, *lease)
        || value<uint32_t>(owner->state + 0xAC21C) != 3)
        return error.empty() ? reject(error, "Ship identity changed before mode entry") : false;
    lease->attempted = lease->in_call = true;
    owner->mode_owned.store(1, std::memory_order_release); // Claim partial outcomes before the call.
    DWORD exception{};
    const bool called = invoke(owner, 4, exception);
    lease->in_call = false;
    const uint32_t scene = value<uint32_t>(owner->state + 0xAC21C);
    if (scene == 4) {
        owner->expected_scene.store(4, std::memory_order_release);
        lease->entered = true;
        read(owner->state + kStateGame, lease->game_header_after);
    }
    if (!called) return reject(error, "Native mode entry raised an exception; cleanup is retained");
    if (scene != 4 || !world_same(owner) || !actor_current(owner))
        return reject(error, "Native mode entry did not retain the original ship actor/world");
    return environment(owner, *lease, error) && peers(owner, *lease, true, error);
}

bool mode_restore(Owner* owner, std::string& error) {
    std::lock_guard<std::recursive_mutex> lock(mutex);
    auto* lease = find(owner);
    if (!owner || !owner->mode_owned.load(std::memory_order_acquire)) return true;
    if (!lease || lease->in_call || GetCurrentThreadId() != owner->game_thread)
        return reject(error, "Native mode restoration is waiting for its owning call/thread");
    uintptr_t state{}, world{};
    uint32_t level{};
    if (!read(owner->game + 0x3326340, state) || !read(owner->game + 0x346BF98, world)
        || !state || !world || !read(state + 0x10F0, level))
        return reject(error, "Current level identity is unavailable during mode restoration");
    if (state != owner->state || world != owner->world || level != owner->level_id || mode_retired(owner)) {
        owner->mode_owned.store(0, std::memory_order_release);
        lease->returned = true; // An external world/level transition retired our scope.
        return true;
    }
    if (!environment(owner, *lease, error) || !peers(owner, *lease, false, error)) return false;
    uint32_t scene{};
    if (!read(owner->state + 0xAC21C, scene)) return reject(error, "Current native scene is unreadable");
    if (scene == 3) {
        if (!ui_original(owner, *lease) || !actor_current(owner))
            return reject(error, "Partial entry has not recovered original ship UI/actor state");
    } else if (scene == 4) {
        lease->in_call = true;
        DWORD exception{};
        const bool called = invoke(owner, 3, exception);
        lease->in_call = false;
        if (value<uint32_t>(owner->state + 0xAC21C) == 3)
            owner->expected_scene.store(3, std::memory_order_release);
        if (!called || value<uint32_t>(owner->state + 0xAC21C) != 3
            || !world_same(owner) || !ui_original(owner, *lease) || !actor_current(owner))
            return reject(error, "Native ship mode restoration was not fully acknowledged");
    } else return reject(error, "Another native scene transition is pending");
    if (!environment(owner, *lease, error) || !peers(owner, *lease, false, error)) return false;
    owner->expected_scene.store(3, std::memory_order_release);
    owner->mode_owned.store(0, std::memory_order_release);
    lease->returned = true;
    return true;
}

bool mode_ready(const Owner* owner) {
    uint8_t phase{};
    return owner && owner->mode_owned.load(std::memory_order_acquire)
        && value<uint32_t>(owner->state + 0xAC21C) == 4
        && read(owner->state + kStateGame + 0x14, phase) && phase == 0;
}

bool mode_retired(const Owner* owner) {
    std::lock_guard<std::recursive_mutex> lock(mutex);
    const auto* lease = find(owner);
    if (!owner || !lease) return false;
    uintptr_t state{}, world{}, runtime{}, definition{};
    uint32_t level{}, kind{};
    if (!read(owner->game + 0x3326340, state) || !state
        || !read(owner->game + 0x346BF98, world) || !world || !read(state + 0x10F0, level)) return false;
    if (state != owner->state || world != owner->world || level != owner->level_id) return true;
    if (!read(state + 0xAE288, runtime) || !runtime) return false;
    if (runtime != lease->runtime) return true;
    if (!read(runtime + 0x1E4, kind) || kind > 3
        || !read(runtime + 0x218, definition) || !mapped(definition)) return false;
    return kind != lease->level_kind || definition != lease->level_definition;
}

bool mode_tick(Owner* owner, std::string& error) {
    std::lock_guard<std::recursive_mutex> lock(mutex);
    auto* lease = find(owner);
    if (!lease || !lease->entered || !owner->mode_owned.load(std::memory_order_acquire)
        || GetCurrentThreadId() != owner->game_thread || value<uint32_t>(owner->state + 0xAC21C) != 4)
        return reject(error, "Native gameplay mode ownership retired");
    if (!environment(owner, *lease, error) || !peers(owner, *lease, true, error)
        || !actor_current(owner)) return error.empty() ? reject(error, "Native mode actor retired") : false;
    uint8_t phase{};
    if (!read(owner->state + kStateGame + 0x14, phase) || phase > 1)
        return reject(error, "Native gameplay completion phase is unavailable");
    if (phase == 1 && ++lease->pending_frames > kPendingFrames)
        return reject(error, "Native gameplay completion stayed pending; no completion or flag forcing was attempted");
    return true;
}
}
