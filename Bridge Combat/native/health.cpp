#include "health.h"
#include <cstddef>
#include <cstring>
#include <exception>
#include <memory>
#include <mutex>
#include <vector>

namespace bc {
namespace {
constexpr uintptr_t kDamage = 0x9235F0;
constexpr uintptr_t kCompare = 0x9238B2;
constexpr uintptr_t kBranch = 0x9238B9;
constexpr uintptr_t kContinue = 0x9238BF;
constexpr uintptr_t kBlocked = 0x925D31;
constexpr char kDamageFingerprint[] = "4c8bdc55534154498dab48f5ffff4881ecc00b0000488b05";
constexpr char kGateFingerprint[] = "83b81cc20a00030f8472240000";
constexpr char kBranchFingerprint[] = "0f8472240000";

// Build proof: 6AB3B43F, 9235F0 -> PlayerManager membership -> scene == 3
// at 9238B2 -> JE 925D31. At this gate EBX is target entity, R12 the health
// manager, R15 its runtime row, [RBP-60] its descriptor, and RAX GameState.
// All earlier native health/permission checks and all later native damage,
// health, synchronization and effects remain on their original paths.
struct CaveLease {
    std::atomic<uint32_t> allowed{0};
    Owner* owner{};
    void* code{};
    size_t code_size{};
    void* unused_trampoline{};
};
static_assert(offsetof(CaveLease, allowed) == 0, "Cave flag layout changed");
static_assert(offsetof(Owner, enabled) == 0, "Owner flag layout changed");
static_assert(offsetof(Owner, avatar) < 128 && offsetof(Owner, health_descriptor) < 128,
              "Owner fields no longer fit the audited disp8 instructions");
static_assert(offsetof(Owner, player) < 128 && offsetof(Owner, world) < 128
              && offsetof(Owner, local_unit) < 128, "Local actor fields no longer fit disp8");

std::mutex leases_mutex;
// Intentionally retained for process lifetime, including disabled generations.
// A stopped thread can still be in a cave when MinHook restores its entry site.
std::vector<CaveLease*> leases;

class Code {
public:
    std::vector<uint8_t> bytes;
    std::vector<size_t> blocked;
    size_t fast_continue{};

    void emit(std::initializer_list<uint8_t> data) { bytes.insert(bytes.end(), data); }
    template<class T> void integer(T value) {
        const auto* begin = reinterpret_cast<const uint8_t*>(&value);
        bytes.insert(bytes.end(), begin, begin + sizeof(value));
    }
    size_t conditional(uint8_t opcode) {
        emit({0x0F, opcode});
        const size_t displacement = bytes.size();
        integer<int32_t>(0);
        return displacement;
    }
    void deny_if(uint8_t opcode) { blocked.push_back(conditional(opcode)); }
    void resolve(size_t displacement, size_t destination) {
        const int32_t relative = static_cast<int32_t>(destination - (displacement + 4));
        std::memcpy(bytes.data() + displacement, &relative, sizeof(relative));
    }
    void absolute_jump(uintptr_t address) {
        emit({0xFF, 0x25, 0, 0, 0, 0});
        integer<uintptr_t>(address);
    }
    void restore() { emit({0x41, 0x5B, 0x41, 0x5A, 0x9D}); } // R11, R10, RFLAGS
};

Code make_cave(uintptr_t game, uintptr_t owner_address, uintptr_t lease_address) {
    Code code;
    code.bytes.reserve(256);
    // The original JE consumes ZF from CMP [GameState+AC21C],3. Outside the
    // ship its fallthrough must happen without touching any register or flag.
    code.fast_continue = code.conditional(0x85); // JNZ native continuation
    code.emit({0x9C, 0x41, 0x52, 0x41, 0x53});  // PUSHFQ; PUSH R10; PUSH R11
    code.emit({0x49, 0xBB}); code.integer<uintptr_t>(owner_address);
    code.emit({0x41, 0x83, 0x3B, 0x01}); code.deny_if(0x85); // Owner.enabled == 1
    code.emit({0x49, 0xBA}); code.integer<uintptr_t>(lease_address);
    code.emit({0x41, 0x83, 0x3A, 0x01}); code.deny_if(0x85); // CaveLease.allowed == 1

    code.emit({0x41, 0x3B, 0x5B, static_cast<uint8_t>(offsetof(Owner, avatar))});
    code.deny_if(0x85); // EBX == captured local avatar
    code.emit({0x4D, 0x3B, 0x63, static_cast<uint8_t>(offsetof(Owner, health))});
    code.deny_if(0x85); // R12 == captured HealthComponent manager
    code.emit({0x4D, 0x3B, 0x7B, static_cast<uint8_t>(offsetof(Owner, health_runtime))});
    code.deny_if(0x85); // R15 == captured actor's health runtime row
    code.emit({0x49, 0x3B, 0x43, static_cast<uint8_t>(offsetof(Owner, state))});
    code.deny_if(0x85); // RAX == captured real GameState pointer

    // Reject a manager replacement even if an in-flight damage event still
    // has the old manager/row in its registers. Module globals remain mapped
    // whenever execution is inside the validated game.dll damage function.
    code.emit({0x4D, 0x8B, 0x53, static_cast<uint8_t>(offsetof(Owner, game))});
    code.emit({0x4D, 0x3B, 0xA2}); code.integer<int32_t>(0x3326688);
    code.deny_if(0x85); // Current HealthComponent == R12
    code.emit({0x49, 0x3B, 0x82}); code.integer<int32_t>(0x3326340);
    code.deny_if(0x85); // Current GameState == RAX
    code.emit({0x4D, 0x8B, 0x92}); code.integer<int32_t>(0x3326D20);
    code.emit({0x4D, 0x3B, 0x53, static_cast<uint8_t>(offsetof(Owner, pm))});
    code.deny_if(0x85); // Current PlayerManager == captured manager

    // A previous local actor may remain alive during a fresh spawn. Match the
    // exact PLAYER+3A8 unit reference used by the native local-avatar chain;
    // descriptor render/game references are distinct and are not substituted.
    code.emit({0x4D, 0x8B, 0x53, static_cast<uint8_t>(offsetof(Owner, game))});
    code.emit({0x4D, 0x8B, 0x92}); code.integer<int32_t>(0x346BF98);
    code.emit({0x4D, 0x3B, 0x53, static_cast<uint8_t>(offsetof(Owner, world))});
    code.deny_if(0x85);
    code.emit({0x4D, 0x8B, 0x53, static_cast<uint8_t>(offsetof(Owner, game))});
    code.emit({0x4D, 0x8B, 0x92}); code.integer<int32_t>(0x3326468);
    code.emit({0x4D, 0x3B, 0x53, static_cast<uint8_t>(offsetof(Owner, player))});
    code.deny_if(0x85);
    code.emit({0x45, 0x8B, 0x92}); code.integer<int32_t>(0x3A8); // R10D = current local unit
    code.emit({0x45, 0x3B, 0x53, static_cast<uint8_t>(offsetof(Owner, local_unit))});
    code.deny_if(0x85);

    code.emit({0x4C, 0x8B, 0x55, 0xA0}); // R10 = current descriptor [RBP-60]
    code.emit({0x4D, 0x3B, 0x53, static_cast<uint8_t>(offsetof(Owner, health_descriptor))});
    code.deny_if(0x85);
    code.emit({0x41, 0x39, 0x5A, 0x08}); code.deny_if(0x85); // descriptor.entity == EBX
    code.emit({0x41, 0xF6, 0x42, 0x14, 0x01}); code.deny_if(0x84); // descriptor live bit

    // Fields are immutable after publication. Only aligned atomic flags can
    // change; a second check closes retirement during the identity checks.
    code.emit({0x41, 0x83, 0x3B, 0x01}); code.deny_if(0x85);
    code.emit({0x49, 0xBA}); code.integer<uintptr_t>(lease_address);
    code.emit({0x41, 0x83, 0x3A, 0x01}); code.deny_if(0x85);
    code.restore();
    const size_t continuation = code.bytes.size();
    code.absolute_jump(game + kContinue);
    const size_t blocked = code.bytes.size();
    code.restore();
    code.absolute_jump(game + kBlocked);
    code.resolve(code.fast_continue, continuation);
    for (size_t displacement : code.blocked) code.resolve(displacement, blocked);
    return code;
}
}

bool health_prepare(Owner* owner, std::string& error) {
    if (!owner || !owner->game || !owner->state || !owner->pm || !owner->player || !owner->world
        || !owner->local_unit || owner->local_unit == 0xFFFFFFFF || !owner->health
        || !owner->health_runtime || !owner->health_descriptor || !owner->avatar
        || owner->avatar == 0xFFFFFFFF) {
        error = "Health exception requires a complete local actor identity";
        return false;
    }
    if (value<uintptr_t>(owner->game + 0x3326688) != owner->health
        || value<uintptr_t>(owner->game + 0x3326D20) != owner->pm
        || value<uintptr_t>(owner->game + 0x3326340) != owner->state
        || value<uintptr_t>(owner->game + 0x3326468) != owner->player
        || value<uintptr_t>(owner->game + 0x346BF98) != owner->world
        || value<uint32_t>(owner->player + 0x3A8) != owner->local_unit
        || value<uint32_t>(owner->state + 0xAC21C) != 3
        || value<uint32_t>(owner->health_descriptor + 8) != owner->avatar
        || (value<uint8_t>(owner->health_descriptor + 0x14) & 1) == 0
        || value<uint8_t>(owner->health_runtime + 5) != 1) {
        error = "Health exception actor or manager identity changed";
        return false;
    }
    if (!fingerprint(owner->game + kDamage, kDamageFingerprint)
        || !fingerprint(owner->game + kCompare, kGateFingerprint)) {
        error = "Health damage branch fingerprint mismatch";
        return false;
    }
    std::lock_guard<std::mutex> lock(leases_mutex);
    for (const auto* existing : leases) {
        if (existing->owner == owner) {
            error = "Health exception was already prepared for this owner";
            return false;
        }
    }
    try {
        leases.reserve(leases.size() + 1);
        auto lease = std::make_unique<CaveLease>();
        lease->owner = owner;
        const Code code = make_cave(owner->game, reinterpret_cast<uintptr_t>(owner),
                                    reinterpret_cast<uintptr_t>(lease.get()));
        void* buffer = VirtualAlloc(nullptr, code.bytes.size(), MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
        if (!buffer) { error = "Health branch cave allocation failed"; return false; }
        std::memcpy(buffer, code.bytes.data(), code.bytes.size());
        DWORD old_protection{};
        if (!VirtualProtect(buffer, code.bytes.size(), PAGE_EXECUTE_READ, &old_protection)
            || !FlushInstructionCache(GetCurrentProcess(), buffer, code.bytes.size())) {
            VirtualFree(buffer, 0, MEM_RELEASE);
            error = "Health branch cave could not become executable";
            return false;
        }
        lease->code = buffer;
        lease->code_size = code.bytes.size();
        // Bookkeeping was reserved before allocating executable memory, so a
        // successful CreateHook cannot lose its tracked retirement flag.
        if (!stage_hook(owner->game + kBranch, buffer, &lease->unused_trampoline,
                        kBranchFingerprint, error)) {
            VirtualFree(buffer, 0, MEM_RELEASE); // No hook enabled by stage_hook.
            return false;
        }
        lease->allowed.store(1, std::memory_order_release);
        leases.push_back(lease.release());
        return true;
    } catch (const std::exception& exception) {
        error = std::string("Health cave preparation failed: ") + exception.what();
        return false;
    }
}

void health_deactivate(Owner* owner) {
    std::lock_guard<std::mutex> lock(leases_mutex);
    for (auto* lease : leases) {
        if (lease->owner == owner) lease->allowed.store(0, std::memory_order_release);
    }
}
}

#ifdef BC_NATIVE_TEST_API
// Offline test exports use this exact production generator. Addresses may be
// synthetic Unicorn addresses: none are dereferenced by the recipe builder.
extern "C" __declspec(dllexport) size_t BC_health_cave_recipe(
    uintptr_t game, uintptr_t owner, uintptr_t lease, uint8_t* output, size_t capacity) {
    const auto code = bc::make_cave(game, owner, lease);
    if (output && capacity >= code.bytes.size()) std::memcpy(output, code.bytes.data(), code.bytes.size());
    return code.bytes.size();
}
extern "C" __declspec(dllexport) size_t BC_health_owner_offsets(uint32_t* output, size_t capacity) {
    const uint32_t offsets[] = {
        offsetof(bc::Owner, enabled), offsetof(bc::Owner, game), offsetof(bc::Owner, state),
        offsetof(bc::Owner, pm), offsetof(bc::Owner, health), offsetof(bc::Owner, health_runtime),
        offsetof(bc::Owner, health_descriptor), offsetof(bc::Owner, avatar),
        offsetof(bc::Owner, player), offsetof(bc::Owner, world), offsetof(bc::Owner, local_unit),
    };
    if (output && capacity >= 11) std::memcpy(output, offsets, sizeof(offsets));
    return 11;
}
#endif
