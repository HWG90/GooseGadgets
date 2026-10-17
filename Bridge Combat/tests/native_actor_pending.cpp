// Isolated synthetic memory only. Include the production predicates directly;
// no game modules, Unit setters, events, or weapon detaches are invoked.
#include "../native/actor.cpp"
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <stdexcept>

namespace bc {
bool fingerprint(uintptr_t address, const char* hex) {
    for (size_t i = 0; hex[i]; i += 2) {
        auto digit = [](char c) { return c <= '9' ? c - '0' : c - 'a' + 10; };
        uint8_t actual{};
        if (!read(address + i / 2, actual) || actual != ((digit(hex[i]) << 4) | digit(hex[i + 1]))) return false;
    }
    return true;
}
}
namespace {
struct Buffer {
    std::vector<uint8_t> bytes;
    explicit Buffer(size_t size) : bytes(size) {}
    uintptr_t address() { return reinterpret_cast<uintptr_t>(bytes.data()); }
    template<class T> void put(size_t offset, T value) { std::memcpy(bytes.data() + offset, &value, sizeof(value)); }
};
struct Fixture {
    Buffer game{0x3484000}, world{0xF33000}, wm{0x80}, im{0x80}, wd{0x60}, definitions{0xA0};
    Buffer wb{64}, ib{64}, db{64}, pb{64}, world_map{64};
    Buffer wdesc{0x20}, idesc{0x20}, ddesc{0x20}, warr{8}, iarr{8}, darr{8};
    Buffer runtime{0x1D0}, config{0x20}, inventory{0x30}, prototype{0xE8};
    bc::Owner owner{};
    Fixture() {
        owner.game = game.address(); owner.world = world.address(); owner.avatar = 252;
        game.put<uintptr_t>(0x3326420, wm.address());
        game.put<uintptr_t>(0x3326738, im.address());
        game.put<uintptr_t>(0x3326730, wd.address());
        game.put<uintptr_t>(0x3326DC0, definitions.address());
        game.put<uint32_t>(0x3483C20, 0xFFFFFFFF); game.put<uint32_t>(0x3483C34, 0);
        map(wm, 0x30, wb, 252); map(im, 0x28, ib, 252);
        map(wd, 0x18, db, 100); map(definitions, 0x50, pb, 100);
        map(world, 0xF1AEB0, world_map, 100);
        wm.put<uint32_t>(0x1C, 1); wm.put<uint32_t>(0x20, 1);
        wm.put<uintptr_t>(0x48, warr.address()); warr.put<uintptr_t>(0, wdesc.address());
        wm.put<uintptr_t>(0x60, runtime.address()); wm.put<uintptr_t>(0x58, config.address());
        descriptor(wdesc, 252, 0x888); runtime.put<uint32_t>(0, 100);
        im.put<uint32_t>(0x18, 1); im.put<uintptr_t>(0x40, iarr.address());
        iarr.put<uintptr_t>(0, idesc.address()); descriptor(idesc, 252, 0x888);
        im.put<uintptr_t>(0x50, inventory.address()); inventory.put<uint32_t>(0, 100);
        inventory.put<uint32_t>(0x1C, 1);
        wd.put<uintptr_t>(0x30, darr.address()); darr.put<uintptr_t>(0, ddesc.address());
        descriptor(ddesc, 100, 0x894);
        definitions.put<uintptr_t>(0x90, prototype.address()); prototype.put<uint32_t>(0xC0, 10);
        world.put<uint64_t>(0xF32F18, 0x1234567890ABCDEFULL);
        world.put<uint32_t>(0xF32F20, 100); world.put<uint32_t>(0xF32F24, 0x894);
        world.put<uint8_t>(0xF32F2C, 1);
    }
    static void descriptor(Buffer& b, uint32_t entity, uint32_t ref) {
        b.put<uint32_t>(8, entity); b.put<uint32_t>(0xC, ref); b.put<uint8_t>(0x14, 1);
    }
    static void map(Buffer& header, size_t offset, Buffer& buckets, uint32_t key) {
        std::fill(buckets.bytes.begin(), buckets.bytes.end(), 0xFF);
        buckets.put<uint32_t>((key & 7) * 8, key); buckets.put<uint32_t>((key & 7) * 8 + 4, 0);
        header.put<uintptr_t>(offset, buckets.address()); header.put<uint32_t>(offset + 8, 8);
        header.put<uint32_t>(offset + 12, 0xFFFFFFFF); header.put<uint32_t>(offset + 16, 1);
    }
    bool ready(bc::ReadyWeapon& out) { return bc::ready_weapon(&owner, out); }
};
int passed{};
void check(bool value, const char* name) {
    if (!value) throw std::runtime_error(name);
    ++passed;
}
}
int main() {
    try {
        Fixture f;
        const auto original_game = f.game.bytes, original_world = f.world.bytes;
        bc::ReadyWeapon ready{};
        check(f.ready(ready) && ready.held.entity == 100, "current live selected weapon ready");
        bc::Lease lease{};
        check(!bc::stable_ready_weapon(lease, &ready), "first ready tick waits");
        check(bc::stable_ready_weapon(lease, &ready), "second same ready tick qualifies");
        f.config.put<uint8_t>(5, 1);
        check(!f.ready(ready), "configuration hidden waits");
        check(!bc::stable_ready_weapon(lease, nullptr), "hidden tick clears previous candidate");
        f.config.put<uint8_t>(5, 0); f.runtime.put<uint8_t>(0x190, 1);
        check(!f.ready(ready), "cached hidden waits");
        f.runtime.put<uint8_t>(0x190, 0); f.runtime.put<uint32_t>(0, 0);
        check(!f.ready(ready), "empty attachment waits");
        f.runtime.put<uint32_t>(0, 100); f.inventory.put<uint32_t>(0, 101);
        check(!f.ready(ready), "stale attachment versus replacement inventory waits");
        f.inventory.put<uint32_t>(0, 100); f.inventory.put<uint32_t>(0x1C, 0);
        check(!f.ready(ready), "unarmed selection waits");
        f.inventory.put<uint32_t>(0x1C, 7);
        check(!f.ready(ready), "unsupported selection waits");
        for (const auto item : {std::pair<uint32_t, size_t>{1, 0}, {2, 4}, {3, 8}, {4, 0x10}, {5, 0x10}, {6, 0xC}}) {
            f.inventory.put<uint32_t>(0x1C, item.first); f.inventory.put<uint32_t>(item.second, 100);
            check(f.ready(ready), "native selected-slot mapping");
        }
        f.inventory.put<uint32_t>(0x1C, 1); f.ddesc.put<uint32_t>(0xC, 0x895);
        check(!f.ready(ready), "weapon render generation mismatch waits");
        f.ddesc.put<uint32_t>(0xC, 0x894); f.ddesc.put<uint8_t>(0x14, 0);
        check(!f.ready(ready), "retired weapon descriptor waits");
        f.ddesc.put<uint8_t>(0x14, 1); f.idesc.put<uint32_t>(8, 253);
        check(!f.ready(ready), "foreign inventory preserved");
        f.idesc.put<uint32_t>(8, 252); f.im.put<uint32_t>(0x18, 0);
        check(!f.ready(ready), "inventory row outside count waits");
        f.im.put<uint32_t>(0x18, 1); check(f.ready(ready), "equipment returns ready after waiting");
        check(!bc::stable_ready_weapon(lease, &ready), "ready after waiting needs fresh first tick");
        auto changed = ready; changed.inventory_runtime += 0x30;
        check(!bc::stable_ready_weapon(lease, &changed), "row relocation restarts consecutive identity wait");
        check(bc::stable_ready_weapon(lease, &changed), "relocated identity stable on subsequent tick");
        check(!bc::needs_restore(lease), "unclaimed lease does not manufacture cleanup");
        lease.controls_claimed = true;
        check(bc::needs_restore(lease) && !lease.dirty, "controls lease retains cleanup before first setter");
        lease.controls_claimed = false; lease.dirty = true;
        check(bc::needs_restore(lease), "partial reconstruction retains cleanup");
        lease.dirty = false;
        check(!bc::needs_restore(lease), "acknowledged cleanup is idempotent");
        check(f.game.bytes == original_game && f.world.bytes == original_world,
            "readiness never mutates game or world memory");
        std::printf("%d actor pending/equipment contracts passed; no game modules or native mutation calls\n", passed);
    } catch (const std::exception& e) { std::fprintf(stderr, "%s\n", e.what()); return 1; }
}
