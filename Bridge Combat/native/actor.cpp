#include "actor.h"
#include <array>
#include <memory>
#include <vector>

namespace bc {
namespace {
constexpr uint32_t kExeStamp = 0x6AB382E4;
constexpr uint64_t kGraphType = 0xA486D4045106165CULL;
constexpr uint64_t kModelType = 0x18DEAD01056B72E9ULL;
constexpr uint32_t kStand = 0xF2F926AB;
constexpr uint32_t kCrouch = 0xB65540AB;
constexpr uint32_t kProne = 0x13AEB16B;
constexpr uint32_t kBridge = 0x712947D6;
constexpr uint32_t kWeaponOut = 0x17CBE1C0;
constexpr uint32_t kEnd = 0x7FFFFFFF;
constexpr uint32_t kEmpty = 0xFFFFFFFE;

struct View {
    uintptr_t exe{}, unit{}, animator{}, graph{}, model{}, resources{}, api{};
    uint64_t graph_name{}, model_name{};
    uint32_t reference{}, stance{};
};
struct WeaponIdentity {
    uint32_t entity{}, reference{};
    uint64_t type{};
    uintptr_t prototype{};
};
struct WeaponSlot {
    WeaponIdentity held{}, spare{};
};
struct Weapons {
    uintptr_t manager{}, descriptor{}, runtime{}, config{};
    bool absent{};
    std::array<WeaponSlot, 5> slots{};
};
struct ReadyWeapon {
    uintptr_t manager{}, descriptor{}, runtime{}, config{};
    uintptr_t inventory{}, inventory_descriptor{}, inventory_runtime{}, weapon_descriptor{};
    uint32_t selected_slot{};
    WeaponIdentity held{};
};
struct Lease {
    Owner* owner{};
    uintptr_t unit{}, graph{}, model{}, instance{};
    uint64_t graph_name{}, model_name{};
    uint32_t reference{};
    bool dirty{}, reset_done{}, instance_known{true};
    // Combat controls can already have emitted clips before our first reset.
    // The pending lease must therefore restore/disarm before Lua releases them.
    bool controls_claimed{}, candidate_valid{};
    ReadyWeapon candidate{};
    Weapons weapons{};
    bool weapons_claimed{}, weapons_retired{};
    std::array<bool, 5> detach_attempted{};
};
// Owner records and this journal live in the retained helper. Native detours
// never access the vector; these functions only run on the owner's game thread.
std::vector<std::unique_ptr<Lease>> leases;

bool refuse(std::string& error, const char* reason) {
    error = reason;
    return false;
}
Lease* journal(Owner* owner) {
    for (const auto& item : leases) if (item->owner == owner) return item.get();
    return nullptr;
}

enum class MapResult { found, absent, unavailable };
MapResult map_row(uintptr_t header, uint32_t key, uint32_t& row) {
    uintptr_t buckets{};
    uint32_t capacity{}, empty{}, multiplier{};
    if (!read(header, buckets) || !read(header + 8, capacity)
        || !read(header + 12, empty) || !read(header + 16, multiplier)
        || !capacity || capacity > 0x100000 || (capacity & (capacity - 1))
        ) return MapResult::unavailable;
    if (key == empty) return MapResult::absent;
    uint32_t product = key * multiplier;
    for (uint32_t probe = 0; probe < capacity && probe < 4096; ++probe) {
        uintptr_t entry = buckets + size_t((product + probe) & (capacity - 1)) * 8;
        uint32_t found{};
        if (!read(entry, found)) return MapResult::unavailable;
        if (found == empty) return MapResult::absent;
        if (found == key) return read(entry + 4, row) && row != 0xFFFFFFFF
            ? MapResult::found : MapResult::unavailable;
    }
    return capacity <= 4096 ? MapResult::absent : MapResult::unavailable;
}

bool weapon_empty(Owner* owner, uint32_t entity) {
    uint32_t invalid{}, none{};
    return read(owner->game + 0x3483C20, invalid)
        && read(owner->game + 0x3483C34, none)
        && (!entity || entity == invalid || entity == none);
}
bool weapon_contract(Owner* owner) {
    return fingerprint(owner->game + 0x785C10,
        "4053415641574883ec403b1500e0cf02458bf9458bf08bda")
        && fingerprint(owner->game + 0x7853D0,
        "405341564881ec98000000488b052e6ceb014833c4488944")
        && fingerprint(owner->game + 0x783B30,
        "48895c2410574883ec208bc24869d8d0010000418bc04803");
}
bool inventory_contract(Owner* owner) {
    // 9A83D0 / 9A84A0 / 9B0720 prove the selected-slot runtime layout.
    return fingerprint(owner->game + 0x9A83D0,
        "41564883ec20443b0543b8ad024c8bf24c8b1551e3970275")
        && fingerprint(owner->game + 0x9A84A0,
        "4883ec083b1576b7ad024c8b1587e297027507b8ffffffff")
        && fingerprint(owner->game + 0x9B0720,
        "4585c9745d418bc04c8d044049c1e004418d41ff4c034150");
}
// Mirror the native read-only prototype lookup (5092B0 / 508E90). A live
// entity record alone does not establish that its definition is still loaded.
bool weapon_identity(Owner* owner, uint32_t entity, WeaponIdentity& out) {
    out.entity = entity;
    if (weapon_empty(owner, entity)) return true;
    uint32_t wi{};
    if (map_row(owner->world + 0xF1AEB0, entity, wi) != MapResult::found
        || wi >= 0x100000) return false;
    const uintptr_t record = owner->world + 0xF32F18 + size_t(wi) * 24;
    uint32_t actual{};
    uint8_t live{};
    if (!read(record, out.type) || !out.type || !read(record + 8, actual)
        || actual != entity || !read(record + 0xC, out.reference)
        || !read(record + 0x14, live) || !(live & 1)) return false;
    uintptr_t definitions{};
    uint32_t di{};
    if (!read(owner->game + 0x3326DC0, definitions) || !definitions) return false;
    const auto dynamic = map_row(definitions + 0x50, entity, di);
    if (dynamic == MapResult::unavailable) return false;
    if (dynamic == MapResult::found) {
        uintptr_t rows{};
        if (di >= 0x100000 || !read(definitions + 0x90, rows) || !rows) return false;
        out.prototype = rows + size_t(di) * 0xE8;
    } else {
        uintptr_t table{};
        if (!read(owner->world + 0xF12BC0, table) || !table) return false;
        uint32_t bucket = uint32_t(out.type % 0x2B0);
        for (uint32_t probe = 0; probe < 0x2B0; ++probe) {
            const uintptr_t entry = table + size_t(bucket) * 16;
            uint64_t found{};
            if (!read(entry, found) || !found) return false;
            if (found == out.type) {
                if (!read(entry + 8, di) || di >= 0x2B0) return false;
                out.prototype = table + 0x2B00 + size_t(di) * 0xE8;
                break;
            }
            bucket = (bucket + 1) % 0x2B0;
        }
    }
    uint32_t kind{}, category{};
    return out.prototype && read(out.prototype + 0x80, kind)
        && read(out.prototype + 0xC0, category);
}
bool weapons_view(Owner* owner, Weapons& out) {
    uint32_t row{}, count{}, capacity{}, actor{};
    uintptr_t descriptors{}, rows{};
    uint8_t live{};
    if (!read(owner->game + 0x3326420, out.manager) || !out.manager) return false;
    const auto found = map_row(out.manager + 0x30, owner->avatar, row);
    if (found == MapResult::absent) { out.absent = true; return true; }
    if (found != MapResult::found || !read(out.manager + 0x1C, count)
        || !read(out.manager + 0x20, capacity) || !count || count > capacity
        || capacity > 0x10000 || row >= count
        || !read(out.manager + 0x48, descriptors) || !descriptors
        || !read(descriptors + size_t(row) * 8, out.descriptor)
        || !read(out.descriptor + 8, actor) || actor != owner->avatar
        || !read(out.descriptor + 0x14, live) || !(live & 1)
        || !read(out.manager + 0x60, rows) || !rows
        || !read(out.manager + 0x58, out.config) || !out.config) return false;
    out.runtime = rows + size_t(row) * 0x1D0;
    out.config += size_t(row) * 0x20;
    for (size_t slot = 0; slot < out.slots.size(); ++slot) {
        uint32_t held{}, spare{};
        const auto entry = rows + size_t(row) * 0x1D0 + slot * 0x50;
        if (!read(entry, held) || !read(entry + 4, spare)
            || !weapon_identity(owner, held, out.slots[slot].held)) return false;
        // The native detach can consult the alternate entry of an occupied
        // slot; an already-cleared slot has no remaining detach work.
        out.slots[slot].spare.entity = spare;
        if (!weapon_empty(owner, held)
            && !weapon_identity(owner, spare, out.slots[slot].spare)) return false;
    }
    return true;
}
bool same_weapon(const WeaponIdentity& a, const WeaponIdentity& b) {
    return a.entity == b.entity && a.reference == b.reference
        && a.type == b.type && a.prototype == b.prototype;
}
bool same_ready_weapon(const ReadyWeapon& a, const ReadyWeapon& b) {
    return a.manager == b.manager && a.descriptor == b.descriptor
        && a.runtime == b.runtime && a.config == b.config
        && a.inventory == b.inventory && a.inventory_descriptor == b.inventory_descriptor
        && a.inventory_runtime == b.inventory_runtime && a.weapon_descriptor == b.weapon_descriptor
        && a.selected_slot == b.selected_slot && same_weapon(a.held, b.held);
}
bool ready_weapon(Owner* owner, ReadyWeapon& out) {
    Weapons weapons{};
    uint8_t hidden{}, cached_hidden{}, live{};
    uintptr_t descriptors{}, rows{}, weapon_data{};
    uint32_t row{}, count{}, actor{}, selected{}, weapon_row{}, weapon_entity{}, weapon_reference{};
    if (!weapons_view(owner, weapons) || weapons.absent
        || !read(weapons.config + 5, hidden) || hidden != 0
        || !read(weapons.runtime + 0x190, cached_hidden) || cached_hidden != 0
        || weapon_empty(owner, weapons.slots[0].held.entity)
        || !read(owner->game + 0x3326738, out.inventory) || !out.inventory
        || map_row(out.inventory + 0x28, owner->avatar, row) != MapResult::found
        || !read(out.inventory + 0x18, count) || !count || count > 0x10000 || row >= count
        || !read(out.inventory + 0x40, descriptors) || !descriptors
        || !read(descriptors + size_t(row) * 8, out.inventory_descriptor)
        || !read(out.inventory_descriptor + 8, actor) || actor != owner->avatar
        || !read(out.inventory_descriptor + 0x14, live) || !(live & 1)
        || !read(out.inventory + 0x50, rows) || !rows) return false;
    out.inventory_runtime = rows + size_t(row) * 0x30;
    if (!read(out.inventory_runtime + 0x1C, out.selected_slot)) return false;
    // Exact native 9B0720 mapping; +14 is a different retained entity field.
    size_t offset{};
    switch (out.selected_slot) {
    case 1: offset = 0; break;
    case 2: offset = 4; break;
    case 3: offset = 8; break;
    case 4: case 5: offset = 0x10; break;
    case 6: offset = 0xC; break;
    default: return false;
    }
    if (!read(out.inventory_runtime + offset, selected)
        || selected != weapons.slots[0].held.entity
        || !read(owner->game + 0x3326730, weapon_data) || !weapon_data
        || map_row(weapon_data + 0x18, selected, weapon_row) != MapResult::found
        || weapon_row >= 0x100000 || !read(weapon_data + 0x30, descriptors) || !descriptors
        || !read(descriptors + size_t(weapon_row) * 8, out.weapon_descriptor)
        || !read(out.weapon_descriptor + 8, weapon_entity) || weapon_entity != selected
        || !read(out.weapon_descriptor + 0xC, weapon_reference) || !weapon_reference
        || weapon_reference != weapons.slots[0].held.reference
        || !read(out.weapon_descriptor + 0x14, live) || !(live & 1)) return false;
    out.manager = weapons.manager; out.descriptor = weapons.descriptor;
    out.runtime = weapons.runtime; out.config = weapons.config;
    out.held = weapons.slots[0].held;
    return true;
}
bool stable_ready_weapon(Lease& lease, const ReadyWeapon* current) {
    if (!current) { lease.candidate_valid = false; return false; }
    const bool stable = lease.candidate_valid && same_ready_weapon(lease.candidate, *current);
    lease.candidate = *current;
    lease.candidate_valid = true;
    return stable;
}
bool needs_restore(const Lease& lease) { return lease.dirty || lease.controls_claimed; }
bool invoke_detach(Owner* owner, uintptr_t manager, uint32_t slot) noexcept {
    using Detach = void(__fastcall*)(void*, uint32_t, uint32_t, uint32_t);
    __try {
        reinterpret_cast<Detach>(owner->game + 0x785C10)(
            reinterpret_cast<void*>(manager), owner->avatar, slot, 1);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool retire_weapons(Owner* owner, Lease& lease, std::string& error) {
    Weapons current{};
    if (!weapon_contract(owner) || !weapons_view(owner, current))
        return refuse(error, "Current weapon retirement prerequisites are unavailable");
    if (lease.weapons_retired) {
        // A failed graph restore may yield a frame. Native controls can then
        // reattach a weapon; do not trust a prior frame's disarm result.
        bool clear = true;
        for (const auto& slot : current.slots)
            if (!weapon_empty(owner, slot.held.entity)) clear = false;
        if (current.absent || clear) return true;
        lease.weapons_retired = false;
    }
    if (!lease.weapons_claimed) {
        lease.weapons = current; // All five slots/prototypes validated before any call.
        lease.weapons_claimed = true;
    }
    if (current.absent) { lease.weapons_retired = true; return true; }
    if (lease.weapons.absent || current.manager != lease.weapons.manager
        || current.descriptor != lease.weapons.descriptor)
        return refuse(error, "Another owner replaced the weapon-wielder component");
    // Prevalidate every remaining slot before the first mutation or retry.
    for (size_t slot = 0; slot < current.slots.size(); ++slot) {
        if (weapon_empty(owner, current.slots[slot].held.entity)) continue;
        if (!same_weapon(current.slots[slot].held, lease.weapons.slots[slot].held)
            || !same_weapon(current.slots[slot].spare, lease.weapons.slots[slot].spare))
            return refuse(error, "A replacement weapon is preserved; retirement is pending");
    }
    for (uint32_t slot = 0; slot < current.slots.size(); ++slot) {
        if (weapon_empty(owner, current.slots[slot].held.entity)) continue;
        // A prior native detach can run callbacks that replace another slot.
        // Validate the refreshed snapshot immediately before each call too.
        if (!same_weapon(current.slots[slot].held, lease.weapons.slots[slot].held)
            || !same_weapon(current.slots[slot].spare, lease.weapons.slots[slot].spare))
            return refuse(error, "A replacement weapon is preserved; retirement is pending");
        lease.detach_attempted[slot] = true;
        const bool called = invoke_detach(owner, current.manager, slot);
        Weapons after{};
        if (!weapons_view(owner, after) || after.absent
            || after.manager != lease.weapons.manager
            || after.descriptor != lease.weapons.descriptor)
            return refuse(error, "Weapon detach result is unavailable; cleanup is retained");
        if (!called || !weapon_empty(owner, after.slots[slot].held.entity))
            return refuse(error, "Native weapon detach was not acknowledged; cleanup is retained");
        current = after;
    }
    for (const auto& slot : current.slots)
        if (!weapon_empty(owner, slot.held.entity))
            return refuse(error, "A weapon reattached during cleanup; retirement is pending");
    lease.weapons_retired = true;
    return true;
}

// Already-loaded resource lookup, without the resolver's locks, aliases,
// fallback loading, or mutations. Layout proved by EXE5FE1D0/5F2290.
bool loaded_resource(uintptr_t manager, uint64_t type, uint64_t name,
                     uintptr_t& resource) {
    uintptr_t types{};
    uint32_t count{}, capacity{}, storage{};
    if (!read(manager + 0x2F0, types) || !read(manager + 0x300, count)
        || !read(manager + 0x304, capacity) || !read(manager + 0x2E8, storage)
        || !count || !capacity || !storage || storage > 0x10000
        || capacity > storage || count > storage) return false;
    uint32_t index = uint32_t(type >> 32) % capacity;
    uintptr_t typed{};
    for (uint32_t probe = 0; probe < storage; ++probe) {
        if (index >= storage) return false;
        uintptr_t entry = types + size_t(index) * 0xD0;
        uint32_t next{};
        uint64_t found{};
        if (!read(entry + 0xC8, next) || next == kEmpty || !read(entry, found)) return false;
        if (found == type) { typed = entry; break; }
        if (next == kEnd) return false;
        index = next;
    }
    uintptr_t entries{}, rows{};
    uint32_t names{}, slots{}, name_storage{}, row_count{};
    if (!typed || !read(typed + 0x28, entries) || !read(typed + 0x38, names)
        || !read(typed + 0x3C, slots) || !read(typed + 0x10, rows)
        || !read(typed + 0x20, name_storage)
        || !read(typed + 8, row_count) || !names || !slots || slots > 0x100000
        || !name_storage || name_storage > 0x100000
        || slots > name_storage || names > name_storage
        || !row_count || row_count > 0x100000) return false;
    index = uint32_t(name >> 32) % slots;
    for (uint32_t probe = 0; probe < name_storage && probe < 4096; ++probe) {
        if (index >= name_storage) return false;
        uintptr_t entry = entries + size_t(index) * 24;
        uint32_t next{}, resource_index{};
        uint64_t found{};
        if (!read(entry + 16, next) || next == kEmpty || !read(entry, found)) return false;
        if (found == name) {
            if (!read(entry + 8, resource_index) || resource_index >= row_count
                || !read(rows + size_t(resource_index) * 0xA0, resource)
                || !resource) return false;
            uint32_t first{};
            return read(resource, first);
        }
        if (next == kEnd) return false;
        index = next;
    }
    return false;
}

bool engine_contract(uintptr_t exe, uintptr_t game) {
    uint32_t pe{}, stamp{};
    if (!read(exe + 0x3C, pe) || pe < 0x40 || pe > 0x1000
        || !read(exe + pe + 8, stamp) || stamp != kExeStamp) return false;
    struct Check { uintptr_t rva; const char* bytes; };
    constexpr Check checks[] = {
        {0x2C0AA0, "405356574883ec30488b01488bda488bf1ff90c001000048"},
        {0x2C0970, "40534883ec20488b9178010000488bd94885d2742c488b49"},
        {0x1B3950, "48895c240848896c2410488974241848897c242041544156"},
        {0x547D90, "488bc44c894820555357415441554156488da838ffffff48"},
        {0x554F00, "48895c241048896c2418564883ec20488bda488bf14885d2"},
        {0x55B230, "40534883ec2048896c2430488bd9488974243833f639b120"},
        {0x201710, "48895c2408574883ec208bfae89fc1e9ff488bc8488bd84c"},
        {0x201900, "48895c2408574883ec208bda8bf9e8adbfe9ff448bc38bd7"}
    };
    for (const auto& check : checks) if (!fingerprint(exe + check.rva, check.bytes)) return false;
    return fingerprint(game + 0x79B480,
        "405341564883ec483b159287ce02418bd84c8b3598b2b802");
}

enum class Identity { valid, retired, unavailable };
const char* identity_error = "Current player animation ownership is unavailable";
Identity identify(Owner* owner, View& view, bool allow_empty = false) {
    identity_error = "Current player animation identity is unavailable";
    if (!owner || owner->game_thread != GetCurrentThreadId()) return Identity::unavailable;
    uintptr_t pm{}, state{}, player{}, world{};
    uint32_t scene{}, actor{}, reference{}, pi{};
    uint8_t live{};
    if (!read(owner->game + 0x3326D20, pm)
        || !read(owner->game + 0x3326340, state)
        || !read(owner->game + 0x3326468, player)
        || !read(owner->game + 0x346BF98, world)) return Identity::unavailable;
    if (pm != owner->pm || state != owner->state || player != owner->player
        || world != owner->world) return Identity::retired;
    uint32_t local_unit{}, wi{}, world_actor{};
    if (!read(player + 0x3A8, local_unit)) return Identity::unavailable;
    if (local_unit != owner->local_unit) return Identity::retired;
    MapResult local = map_row(world + 0xF22EC8, local_unit, wi);
    if (local == MapResult::absent) return Identity::retired;
    if (local != MapResult::found || wi >= 0x100000
        || !read(world + 0xF32F18 + size_t(wi) * 24 + 8, world_actor))
        return Identity::unavailable;
    if (world_actor != owner->avatar) return Identity::retired;
    if (!read(state + 0xAC21C, scene)) return Identity::unavailable;
    if (scene != 3) {
        if (scene != 4 || !owner->mode_owned.load(std::memory_order_acquire)
            || owner->expected_scene.load(std::memory_order_acquire) != 4)
            return Identity::retired;
        // Mode 4 is accepted only for this owner's retained bridge world. An
        // ordinary mission, a level reload, or another owner never qualifies.
        uintptr_t flow{}, audio{}, mission{};
        uint32_t level{};
        if (!read(state + 0x10E8, flow) || !read(state + 0x10F0, level)
            || !read(state + 0x10F8, audio)
            || !read(owner->game + 0x3326968, mission)) return Identity::unavailable;
        if (flow != owner->flow_world || audio != owner->audio_world
            || level != owner->level_id || mission != owner->mission_manager)
            return Identity::retired;
    }
    MapResult control = map_row(pm + 0xF8, owner->avatar, pi);
    if (control == MapResult::absent) return Identity::retired;
    if (control != MapResult::found) return Identity::unavailable;
    uintptr_t descriptor{};
    if (pi >= 128 || !read(pm + 0x110 + size_t(pi) * 8, descriptor)
        || !read(descriptor + 8, actor) || !read(descriptor + 0x14, live)
        || !read(descriptor + 0xC, reference)) return Identity::unavailable;
    if (descriptor != owner->descriptor || actor != owner->avatar || !(live & 1)
        || pm + 0x53D8B0 + size_t(pi) * 0x1238 != owner->pc) return Identity::retired;
    view.exe = reinterpret_cast<uintptr_t>(GetModuleHandleW(L"helldivers2.exe"));
    identity_error = "Player animation native fingerprints differ";
    if (!view.exe || !engine_contract(view.exe, owner->game)) return Identity::unavailable;
    identity_error = "Current player render Unit is unavailable";
    uintptr_t registry{}, generations{}, units{}, vtable{}, context{}, unit30{}, engine{};
    uint32_t unit_capacity{};
    uint8_t generation{};
    uint32_t unit_index = reference & 0x3FFFFF;
    if (!reference || !read(view.exe + 0x1A100F0, registry)
        || !read(registry + 0x98, unit_capacity) || unit_index >= unit_capacity
        || !read(registry + 0xA0, generations) || !read(generations + unit_index, generation)
        || generation != (reference >> 22) || !read(registry + 0x88, units)
        || !read(units + size_t(unit_index) * 8, view.unit) || !read(view.unit, vtable))
        return Identity::unavailable;
    if (value<uintptr_t>(vtable + 0xF8) != view.exe + 0x2BD890
        || value<uintptr_t>(vtable + 0x1C0) != view.exe + 0x2C0970
        || value<uintptr_t>(vtable + 0x1D0) != view.exe + 0x2C0AA0
        || !read(view.unit + 0x178, view.animator) || (!view.animator && !allow_empty)
        || !read(view.unit + 0x358, view.graph_name) || !view.graph_name
        || !read(view.unit + 0x30, unit30) || !read(unit30 + 8, view.model_name)
        || !read(view.unit + 0x18, context) || !read(context + 0x2301E8, view.resources)
        || !value<uintptr_t>(view.unit + 0x168) || !value<uintptr_t>(view.unit + 0x170)
        || !read(owner->game + 0x3326308, engine) || !read(engine + 0x18, view.api)
        || value<uintptr_t>(view.api + 0x350) != view.exe + 0x201710
        || value<uintptr_t>(view.api + 0x370) != view.exe + 0x201900
        || !read(owner->pc + 0xFD8, view.stance)) return Identity::unavailable;
    uintptr_t loaded_graph{};
    identity_error = "Current animation graph is not present in the loaded resource registry";
    if (!loaded_resource(view.resources, kGraphType, view.graph_name, loaded_graph))
        return Identity::unavailable;
    identity_error = "Current player model is not present in the loaded resource registry";
    if (!loaded_resource(view.resources, kModelType, view.model_name, view.model))
        return Identity::unavailable;
    identity_error = "Loaded animation graph differs from the current player graph";
    if (view.animator && (!read(view.animator + 0x28, view.graph)
        || view.graph != loaded_graph)) return Identity::unavailable;
    view.graph = loaded_graph;
    identity_error = "Current animation graph dimensions are unsupported";
    uint32_t layers{}, variables{}, constraints{};
    if (!read(view.graph + 4, layers) || layers == 0 || layers > 32
        || !read(view.graph + 0x14, variables) || variables > 256
        || !read(view.graph + 0x24, constraints) || constraints > 64)
        return Identity::unavailable;
    view.reference = reference;
    return Identity::valid;
}

bool has_event(uintptr_t exe, uint32_t reference, uint32_t event, bool& found) noexcept {
    using Has = uint8_t(__fastcall*)(uint32_t, uint32_t);
    __try {
        found = reinterpret_cast<Has>(exe + 0x201710)(reference, event) != 0;
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool set_graph(const View& view) noexcept {
    using Set = void(__fastcall*)(void*, uint64_t);
    __try {
        reinterpret_cast<Set>(view.exe + 0x2C0AA0)(reinterpret_cast<void*>(view.unit), view.graph_name);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool send_event(const View& view, uint32_t event) noexcept {
    using Send = void(__fastcall*)(uint32_t, uint32_t);
    __try {
        reinterpret_cast<Send>(view.exe + 0x201900)(view.reference, event);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool category_refresh(uintptr_t game, uint32_t weapon, uint32_t actor) noexcept {
    using Refresh = void(__fastcall*)(void*, uint32_t, uint32_t);
    __try {
        reinterpret_cast<Refresh>(game + 0x79B480)(nullptr, weapon, actor);
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool events_available(const View& view) {
    for (uint32_t event : {kStand, kCrouch, kProne, kBridge, kWeaponOut}) {
        bool found{};
        if (!has_event(view.exe, view.reference, event, found) || !found) return false;
    }
    return true;
}
bool same_graph(const Lease& lease, const View& view) {
    return view.unit == lease.unit && view.reference == lease.reference
        && view.graph_name == lease.graph_name && view.model_name == lease.model_name
        && view.graph == lease.graph && view.model == lease.model;
}
bool refresh_held_weapon(Owner* owner, const ReadyWeapon& expected) {
    ReadyWeapon current{};
    return ready_weapon(owner, current) && same_ready_weapon(expected, current)
        && category_refresh(owner->game, current.held.entity, owner->avatar);
}

bool rebuild(Owner* owner, Lease& lease, bool bridge, std::string& error,
             const ReadyWeapon* expected = nullptr) {
    View before{};
    if (identify(owner, before, bridge && lease.dirty) != Identity::valid)
        return refuse(error, identity_error);
    if (!same_graph(lease, before))
        return refuse(error, "Current player animation resources changed");
    if (!lease.instance_known)
        return refuse(error, "Player animation reconstruction result is still unknown");
    if (before.animator != lease.instance)
        return refuse(error, "Another owner replaced the player animation instance");
    if (!bridge && (value<uint32_t>(owner->pc + 0xFD0) & 6) != 2)
        return refuse(error, "Mission controls are not ready for animation initialization");
    ReadyWeapon current{};
    if (!bridge && (!expected || !ready_weapon(owner, current)
        || !same_ready_weapon(*expected, current)))
        return refuse(error, "Current equipped weapon changed before animation initialization");
    // The attempt is journaled before the native setter can destroy old state.
    lease.dirty = true;
    lease.reset_done = false;
    bool completed = set_graph(before);
    lease.instance_known = read(lease.unit + 0x178, lease.instance);
    View after{};
    if (!completed || !lease.instance_known || identify(owner, after, true) != Identity::valid
        || !same_graph(lease, after) || !after.animator || !events_available(after))
        return refuse(error, "Player animation reconstruction needs restoration");
    lease.instance = after.animator;
    uint32_t event = bridge ? kBridge : (after.stance & 0x4000) ? kProne
        : (after.stance & 0x2000) ? kCrouch : kStand;
    if (!bridge && !refresh_held_weapon(owner, *expected))
        return refuse(error, "Current weapon animation refresh needs restoration");
    if (!send_event(after, event) || (!bridge && !send_event(after, kWeaponOut)))
        return refuse(error, "Player animation event needs restoration");
    if (bridge) { lease.dirty = false; lease.controls_claimed = false; lease.candidate_valid = false; }
    else lease.reset_done = true;
    error.clear();
    return true;
}
}

bool actor_prepare(Owner* owner, std::string& error) {
    View view{};
    if (identify(owner, view) != Identity::valid)
        return refuse(error, identity_error);
    if (!events_available(view))
        return refuse(error, "Current player graph lacks the required animation events");
    Weapons weapons{};
    if (!weapon_contract(owner) || !inventory_contract(owner) || !weapons_view(owner, weapons))
        return refuse(error, "Current weapon retirement prerequisites are unavailable");
    if ((value<uint32_t>(owner->pc + 0xFD0) & 6) != 2)
        return refuse(error, "Mission controls are not ready for animation ownership");
    if (Lease* existing = journal(owner)) {
        if (needs_restore(*existing) || !same_graph(*existing, view) || existing->instance != view.animator)
            return refuse(error, "Previous player animation ownership is still pending");
        error.clear();
        return true;
    }
    auto lease = std::make_unique<Lease>();
    lease->owner = owner;
    lease->unit = view.unit;
    lease->graph = view.graph;
    lease->model = view.model;
    lease->instance = view.animator;
    lease->graph_name = view.graph_name;
    lease->model_name = view.model_name;
    lease->reference = view.reference;
    lease->controls_claimed = true;
    leases.push_back(std::move(lease));
    error.clear();
    return true;
}
bool actor_reset(Owner* owner, std::string& error) {
    Lease* lease = journal(owner);
    if (!lease) return refuse(error, "Player animation initialization was not prepared");
    if (!owner || !owner->enabled.load(std::memory_order_acquire))
        return refuse(error, "Player animation owner is disabled");
    if (lease->reset_done) {
        View view{};
        if (identify(owner, view) != Identity::valid) return refuse(error, identity_error);
        if (!same_graph(*lease, view) || view.animator != lease->instance)
            return refuse(error, "Current player animation resources changed");
        error.clear(); return true;
    }
    View view{};
    if (identify(owner, view) != Identity::valid) return refuse(error, identity_error);
    if (!same_graph(*lease, view) || !lease->instance_known || view.animator != lease->instance)
        return refuse(error, "Current player animation resources changed while initialization was pending");
    if ((value<uint32_t>(owner->pc + 0xFD0) & 6) != 2)
        return refuse(error, "Mission controls changed while animation initialization was pending");
    ReadyWeapon ready{};
    if (!stable_ready_weapon(*lease, ready_weapon(owner, ready) ? &ready : nullptr)) {
        // Missing/hidden/unattached replacement weapons are a normal wait.
        // BC_tick runs once per game update; two matching ticks establish the
        // same equipped identity before the first destructive graph setter.
        error.clear(); return true;
    }
    return rebuild(owner, *lease, false, error, &ready);
}
bool actor_ready(Owner* owner) {
    const Lease* lease = journal(owner);
    return lease && lease->reset_done && lease->dirty && lease->instance_known;
}
bool actor_restore(Owner* owner, std::string& error) {
    Lease* lease = journal(owner);
    if (!lease || !needs_restore(*lease)) { error.clear(); return true; }
    View view{};
    Identity identity = identify(owner, view, true);
    if (identity == Identity::retired) {
        lease->dirty = false;
        lease->controls_claimed = false;
        lease->candidate_valid = false;
        lease->reset_done = false;
        error = "Player retired; animation restoration skipped";
        return true;
    }
    if (identity != Identity::valid)
        return refuse(error, identity_error);
    if (!lease->instance_known)
        return refuse(error, "Player animation reconstruction result is still unknown");
    if (!same_graph(*lease, view) || view.animator != lease->instance) {
        lease->dirty = false;
        lease->controls_claimed = false;
        lease->candidate_valid = false;
        lease->reset_done = false;
        error = "Foreign player graph preserved; animation restoration skipped";
        return true;
    }
    // Retire active weapon attachments before dropping their playing clips.
    // Native Inventory still owns actual weapon Unit destruction afterward.
    if (!retire_weapons(owner, *lease, error)) return false;
    return rebuild(owner, *lease, true, error);
}
}

#ifdef BC_NATIVE_TEST_API
extern "C" __declspec(dllexport) uint32_t BC_test_actor_resource(
    uintptr_t manager, uint64_t type, uint64_t name, uintptr_t* output) {
    uintptr_t result{};
    if (!output || !bc::loaded_resource(manager, type, name, result)) return 0;
    *output = result;
    return 1;
}
#endif
