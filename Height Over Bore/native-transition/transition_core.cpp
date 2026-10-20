#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include "transition_core.h"

namespace hob {
TransitionCore::TransitionCore(Sink sink, void* context) noexcept
    : sink_(sink), context_(context), thread_(GetCurrentThreadId()) {}
bool TransitionCore::allowed(uint64_t generation) const noexcept {
    // Thread check precedes access to mutable state. Reentrant delivery is refused.
    return GetCurrentThreadId() == thread_ && !dispatching_ && sink_
        && state_.live && state_.identity.generation == generation;
}
bool TransitionCore::send(Event event, Reason reason) noexcept {
    dispatching_ = true;
    const Notice notice{event, reason, state_.identity};
    ++state_.notices;
    const bool ok = sink_(context_, notice);
    dispatching_ = false;
    if (!ok) state_.failed = true;
    return ok;
}
bool TransitionCore::begin(uint64_t world, uint64_t generation, uint32_t avatar) noexcept {
    if (GetCurrentThreadId() != thread_ || dispatching_ || !sink_ || state_.live
        || !world || !avatar || generation <= retired_generation_) return false;
    state_.identity = {world, generation, avatar, 0};
    state_.live = true;
    state_.failed = state_.ads = false;
    return send(Event::world_begin, Reason::ordinary);
}
bool TransitionCore::leave_inner(Reason reason) noexcept {
    if (!state_.ads) return true;
    // Consumer restores before this event is acknowledged, before native exit.
    if (!send(Event::ads_exit, reason)) return false;
    state_.ads = false;
    return true;
}
bool TransitionCore::unequip_inner(Reason reason) noexcept {
    if (!leave_inner(reason)) return false;
    if (!state_.identity.weapon) return true;
    if (!send(Event::unequipped, reason)) return false;
    state_.identity.weapon = 0;
    return true;
}
bool TransitionCore::equip(uint64_t generation, uint32_t weapon) noexcept {
    if (!allowed(generation) || state_.failed || !weapon) return false;
    if (state_.identity.weapon == weapon) return true;
    // The adapter must deliver pre-unequip while the old record is still live.
    // A post-equip notification cannot safely restore the previous record.
    if (state_.identity.weapon) return false;
    state_.identity.weapon = weapon;
    return send(Event::equipped, Reason::ordinary);
}
bool TransitionCore::enter(uint64_t generation, uint32_t weapon) noexcept {
    if (!allowed(generation) || state_.failed || !weapon
        || state_.identity.weapon != weapon) return false;
    if (state_.ads) return true;
    // Set only after a verified first-person entry, never from input intent.
    state_.ads = true;
    // Claim before delivery: failed acknowledgement may follow a partial apply.
    return send(Event::ads_enter, Reason::ordinary);
}
bool TransitionCore::leave(uint64_t generation, Reason reason) noexcept {
    return allowed(generation) && leave_inner(reason);
}
bool TransitionCore::unequip(uint64_t generation, Reason reason) noexcept {
    return allowed(generation) && unequip_inner(reason);
}
bool TransitionCore::end(uint64_t generation, Reason reason) noexcept {
    if (!allowed(generation)) return false;
    const bool restored = unequip_inner(reason);
    // Disable is reversible: retain recovery intent until the consumer restores.
    // Real retirement cannot defer the engine's object lifetime.
    if (!restored && reason==Reason::disable) return false;
    // Invalidation must be delivered even if restoration failed. A failed sink
    // must retain its failure record, never dereference a retired game object.
    const bool invalidated = send(Event::world_end, reason);
    if (!invalidated && reason==Reason::disable) return false;
    retired_generation_ = generation;
    state_.identity = {};
    state_.ads = state_.live = false;
    return restored && invalidated;
}
}
