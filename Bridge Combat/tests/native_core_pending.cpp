// Test production Core tick/readiness/stop wiring with isolated actor/mode
// stubs. No game module is loaded and no engine routine is called.
#include "../native/core.cpp"
#include <stdexcept>

namespace {
bool fixture_ready{}, fixture_reset_ok{true}, fixture_restore_ok{true};
int fixture_reset_calls{}, fixture_restore_calls{}, passed{};
}
namespace bc {
bool actor_prepare(Owner*, std::string&) { return true; }
bool actor_reset(Owner*, std::string& error) {
    ++fixture_reset_calls;
    if (!fixture_reset_ok) error = "synthetic reset refusal";
    return fixture_reset_ok;
}
bool actor_ready(Owner*) { return fixture_ready; }
bool actor_restore(Owner*, std::string& error) {
    ++fixture_restore_calls;
    if (!fixture_restore_ok) error = "synthetic pending cleanup";
    return fixture_restore_ok;
}
bool mode_prepare(Owner*, std::string&) { return true; }
bool mode_enter(Owner*, std::string&) { return true; }
bool mode_restore(Owner*, std::string&) { return true; }
bool mode_tick(Owner*, std::string&) { return true; }
bool mode_ready(const Owner*) { return true; }
bool mode_retired(const Owner*) { return false; }
}
namespace {
void check(bool value, const char* name) {
    if (!value) throw std::runtime_error(name);
    ++passed;
}
template<class T> void put(std::vector<uint8_t>& buffer, size_t offset, T value) {
    std::memcpy(buffer.data() + offset, &value, sizeof(value));
}
}
int main() {
    try {
        check(!GetModuleHandleW(L"game.dll"), "isolated process only");
        std::vector<uint8_t> game(0x346E000), state(0xAD000), player(0x400), descriptor(0x20);
        bc::Owner owner;
        owner.game = reinterpret_cast<uintptr_t>(game.data());
        owner.state = reinterpret_cast<uintptr_t>(state.data());
        owner.player = reinterpret_cast<uintptr_t>(player.data());
        owner.descriptor = reinterpret_cast<uintptr_t>(descriptor.data());
        owner.pm = 0x10000; owner.ui = 0x20000; owner.world = 0x30000;
        owner.avatar = 252; owner.local_unit = 0x888; owner.game_thread = GetCurrentThreadId();
        owner.actor_test = true; owner.enabled.store(1);
        put(game, 0x3326340, owner.state); put(game, 0x346D538, owner.ui);
        put(game, 0x3326D20, owner.pm); put(game, 0x3326468, owner.player);
        put(game, 0x346BF98, owner.world); put(state, 0xAC21C, uint32_t(3));
        put(player, 0x3A8, owner.local_unit); put(descriptor, 8, owner.avatar);
        put(descriptor, 0x14, uint8_t(1)); published.store(&owner);
        check(BC_status() == 1 && BC_ready() == 0, "pending owner active but not ready");
        check(BC_tick(1.0f / 60) == 1 && BC_ready() == 0, "waiting tick succeeds without claiming ready");
        check(BC_tick(1.0f / 60) == 1 && BC_ready() == 0, "repeated wait remains pending");
        fixture_ready = true;
        check(BC_tick(1.0f / 60) == 1 && BC_ready() == 1, "completed reset publishes readiness");
        fixture_reset_ok = false;
        check(BC_tick(1.0f / 60) == 0 && BC_ready() == 0, "reset refusal clears previous readiness");
        fixture_reset_ok = true; fixture_ready = false; fixture_restore_ok = false;
        check(BC_stop() == 0 && bc::current() == &owner && fixture_restore_calls == 1,
            "pending cleanup refusal retains published owner");
        check(BC_status() == 0 && BC_ready() == 0, "cleanup-pending owner reports disabled");
        fixture_restore_ok = true;
        check(BC_stop() == 1 && !bc::current() && fixture_restore_calls == 2, "cleanup retry acknowledges release");
        check(BC_stop() == 1 && fixture_restore_calls == 2, "acknowledged stop is idempotent");
        check(BC_tick(1.0f / 60) == 1 && fixture_reset_calls == 4, "unowned tick does no reset");
        owner.actor_test = false; owner.enabled.store(1); owner.actor_initialized.store(0);
        published.store(&owner);
        check(BC_tick(1.0f / 60) == 1 && BC_ready() == 0, "mode route also retains pending readiness");
        fixture_ready = true;
        check(BC_tick(1.0f / 60) == 1 && BC_ready() == 1, "mode route publishes actual actor completion");
        check(BC_stop() == 1 && !bc::current(), "mode route cleanup acknowledges release");
        std::printf("%d Core pending/readiness/cleanup contracts passed; stub engine only\n", passed);
    } catch (const std::exception& e) { std::fprintf(stderr, "%s\n", e.what()); return 1; }
}
