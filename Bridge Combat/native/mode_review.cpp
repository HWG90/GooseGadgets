// Standalone, explicit entry-only review. Link ONLY mode.cpp + this file with
// BC_GAMEPLAY_MODE_PREFLIGHT_APPROVED=1. No Core/actor/HUD/control/layer modules.
#include "mode.h"
#include <array>
#include <cstring>
#include <memory>
#include <mutex>
#include <new>
#include <vector>

#if !defined(BC_GAMEPLAY_MODE_PREFLIGHT_APPROVED) || BC_GAMEPLAY_MODE_PREFLIGHT_APPROVED != 1
#error The mode-only entry review requires BC_GAMEPLAY_MODE_PREFLIGHT_APPROVED=1.
#endif

namespace {
struct Review {
    std::unique_ptr<bc::Owner> owner;
    uintptr_t exe{}, registry{}, body_unit{};
    uint32_t body_reference{}, player_row{};
    bool prepared{}, entry_attempted{};
    unsigned ticks{};
};
std::recursive_mutex review_mutex;
// mode.cpp retains borrowed Owner addresses in its own leases. A stopped or
// rejected review keeps its Owner storage alive for this DLL's lifetime.
std::vector<std::unique_ptr<Review>> retained;
Review* current_review{};
thread_local char review_error[512]{};

bool reject(std::string& error,const char* message) { error=message; return false; }
int result(bool success,const std::string& error) {
    strncpy_s(review_error,error.c_str(),_TRUNCATE); return success?1:0;
}
bool image(uintptr_t base,uint32_t expected) {
    uint16_t mz{}; int32_t pe{}; uint32_t signature{},stamp{};
    return base && bc::read(base,mz) && mz==0x5A4D && bc::read(base+0x3C,pe) &&
        pe>=0x40 && pe<=0x1000 && bc::read(base+pe,signature) && signature==0x4550 &&
        bc::read(base+pe+8,stamp) && stamp==expected;
}
bool map_row(uintptr_t header,uint32_t key,uint32_t& row) {
    uintptr_t buckets{}; uint32_t capacity{},empty{},multiplier{};
    if (!bc::read(header,buckets) || !buckets || !bc::read(header+8,capacity) ||
        !capacity || capacity>1048576 || (capacity&(capacity-1)) ||
        !bc::read(header+12,empty) || key==empty || !bc::read(header+16,multiplier)) return false;
    uint32_t slot=(key*multiplier)&(capacity-1);
    for (uint32_t n=0;n<capacity && n<4096;++n) {
        uint32_t actual{};
        if (!bc::read(buckets+slot*8ULL,actual) || actual==empty) return false;
        if (actual==key) return bc::read(buckets+slot*8ULL+4,row) && row!=UINT32_MAX;
        slot=(slot+1)&(capacity-1);
    }
    return false;
}
bool ui_roots(const bc::Owner& owner,std::string& error) {
    for (const auto& pair:std::array<std::pair<uintptr_t,uintptr_t>,4>{{
        {0x820,0x258},{0x930,0x380},{0xA40,0x5D0},{0xB50,0x4A8}}}) {
        uintptr_t parent{}; uint32_t flags{};
        if (!bc::read(owner.ui+pair.first+0xF0,parent) || parent!=owner.ui+pair.second || !bc::read(parent,flags))
            return reject(error,"Current UI common-root ownership is unavailable");
    }
    return true;
}
bool body_registry(Review& review,bool capture,std::string& error) {
    auto& owner=*review.owner;
    uintptr_t registry{},generations{},units{},unit{},vtable{};
    uint32_t reference{},capacity{}; uint8_t generation{};
    if (!image(review.exe,0x6AB382E4) || !bc::read(owner.descriptor+12,reference) || !reference ||
        !bc::read(review.exe+0x1A100F0,registry) || !registry ||
        !bc::read(registry+0x98,capacity) || !capacity ||
        (reference&0x3FFFFF)>=capacity || !bc::read(registry+0xA0,generations) || !generations ||
        !bc::read(generations+(reference&0x3FFFFF),generation) || generation!=(reference>>22) ||
        !bc::read(registry+0x88,units) || !units ||
        !bc::read(units+(reference&0x3FFFFF)*8ULL,unit) || !unit || !bc::read(unit,vtable) || !vtable)
        return reject(error,"Current body reference/EXE registry generation is unavailable");
    if (capture) {
        review.body_reference=reference; review.registry=registry; review.body_unit=unit;
    } else if (review.body_reference!=reference || review.registry!=registry || review.body_unit!=unit)
        return reject(error,"Prepared body reference or registry Unit identity changed");
    return true;
}
bool discover(Review& review,uintptr_t game,uintptr_t exe,uint32_t expected_avatar,std::string& error) {
    auto& owner=*review.owner;
    owner.game=game; review.exe=exe; owner.game_thread=GetCurrentThreadId();
    if (!expected_avatar || !image(game,0x6AB3B43F) || !image(exe,0x6AB382E4))
        return reject(error,"Mode-only bootstrap requires the supported game/EXE builds and nonzero avatar");
    if (!bc::read(game+0x3326340,owner.state) || !owner.state ||
        !bc::read(game+0x346BF98,owner.world) || !owner.world ||
        !bc::read(game+0x3326468,owner.player) || !owner.player ||
        !bc::read(game+0x3326D20,owner.pm) || !owner.pm ||
        !bc::read(game+0x346D538,owner.ui) || !owner.ui ||
        !bc::read(owner.player+0x3A8,owner.local_unit) || !owner.local_unit)
        return reject(error,"Mode-only current ship world/player/UI pointers are unavailable");
    uint32_t scene{},world_row{},live_count{};
    if (!bc::read(owner.state+0xAC21C,scene) || scene!=3 ||
        !map_row(owner.world+0xF22EC8,owner.local_unit,world_row) || world_row>=0x100000 ||
        !bc::read(owner.world+0xF32F18+world_row*24ULL+8,owner.avatar) || owner.avatar!=expected_avatar ||
        !map_row(owner.pm+0xF8,owner.avatar,review.player_row) || review.player_row>=128 ||
        !bc::read(owner.pm+0x70,live_count) || !live_count || live_count>4096 || review.player_row>=live_count ||
        !bc::read(owner.pm+0x110+review.player_row*8ULL,owner.descriptor) || !owner.descriptor)
        return reject(error,"Mode-only local Unit/avatar/PlayerManager row does not match the bridge actor");
    uint32_t avatar{}; uint8_t live{};
    if (!bc::read(owner.descriptor+8,avatar) || avatar!=owner.avatar ||
        !bc::read(owner.descriptor+0x14,live) || !(live&1))
        return reject(error,"Mode-only local player descriptor is retired or mismatched");
    owner.pc=owner.pm+0x53D8B0+review.player_row*0x1238ULL;
    return ui_roots(owner,error) && body_registry(review,true,error);
}
bool actor_still_current(Review& review,std::string& error) {
    const auto& owner=*review.owner;
    if (GetCurrentThreadId()!=owner.game_thread || !image(owner.game,0x6AB3B43F) ||
        bc::value<uintptr_t>(owner.game+0x3326340)!=owner.state ||
        bc::value<uintptr_t>(owner.game+0x346BF98)!=owner.world ||
        bc::value<uintptr_t>(owner.game+0x3326468)!=owner.player ||
        bc::value<uintptr_t>(owner.game+0x3326D20)!=owner.pm ||
        bc::value<uintptr_t>(owner.game+0x346D538)!=owner.ui ||
        bc::value<uint32_t>(owner.player+0x3A8)!=owner.local_unit)
        return reject(error,"Mode-only prepared actor/world/UI/thread identity changed");
    uint32_t world_row{},avatar{},row{},count{}; uintptr_t descriptor{}; uint8_t live{};
    if (!map_row(owner.world+0xF22EC8,owner.local_unit,world_row) || world_row>=0x100000 ||
        !bc::read(owner.world+0xF32F18+world_row*24ULL+8,avatar) || avatar!=owner.avatar ||
        !map_row(owner.pm+0xF8,owner.avatar,row) || row!=review.player_row ||
        !bc::read(owner.pm+0x70,count) || row>=count ||
        !bc::read(owner.pm+0x110+row*8ULL,descriptor) || descriptor!=owner.descriptor ||
        !bc::read(descriptor+8,avatar) || avatar!=owner.avatar ||
        !bc::read(descriptor+0x14,live) || !(live&1))
        return reject(error,"Mode-only prepared descriptor row or avatar changed");
    return body_registry(review,false,error);
}
bool prepare_images(uintptr_t game,uintptr_t exe,uint32_t avatar,std::string& error) {
    if (current_review) return reject(error,"A mode-only review handle exists; acknowledge stop before another prepare");
    auto review=std::unique_ptr<Review>(new(std::nothrow) Review);
    if (!review) return reject(error,"Mode-only review allocation failed");
    review->owner=std::unique_ptr<bc::Owner>(new(std::nothrow) bc::Owner);
    if (!review->owner) return reject(error,"Mode-only Owner allocation failed");
    // Publish an Off cleanup handle before admission. Failed preparation retains
    // the exact Owner address too; stop clears publication, never its storage.
    auto* candidate=review.get(); retained.push_back(std::move(review)); current_review=candidate;
    candidate->owner->game_thread=GetCurrentThreadId();
    if (!discover(*candidate,game,exe,avatar,error)) return false;
    candidate->prepared=bc::mode_prepare(candidate->owner.get(),error);
    return candidate->prepared;
}
}

namespace bc {
bool fingerprint(uintptr_t address,const char* hex) {
    if (!hex) return false;
    const size_t size=std::strlen(hex);
    if (!size || size>256 || size%2) return false;
    const auto digit=[](char c) { return c>='0'&&c<='9'?c-'0':c>='a'&&c<='f'?c-'a'+10:-1; };
    for (size_t i=0;i<size;i+=2) {
        uint8_t actual{}; const int a=digit(hex[i]),b=digit(hex[i+1]);
        if (a<0 || b<0 || !read(address+i/2,actual) || actual!=((a<<4)|b)) return false;
    }
    return true;
}
}

extern "C" __declspec(dllexport) int BC_mode_review_prepare(uint32_t avatar) {
    std::lock_guard<std::recursive_mutex> lock(review_mutex);
    std::string error;
    return result(prepare_images(reinterpret_cast<uintptr_t>(GetModuleHandleW(L"game.dll")),
        reinterpret_cast<uintptr_t>(GetModuleHandleW(L"helldivers2.exe")),avatar,error),error);
}
extern "C" __declspec(dllexport) int BC_mode_review_enter() {
    std::lock_guard<std::recursive_mutex> lock(review_mutex);
    std::string error;
    if (!current_review || !current_review->prepared || current_review->entry_attempted)
        return result(reject(error,"Mode-only entry requires a fresh admitted review handle"),error);
    if (!actor_still_current(*current_review,error)) return result(false,error);
    current_review->entry_attempted=true;
    current_review->owner->enabled.store(1,std::memory_order_release);
    return result(bc::mode_enter(current_review->owner.get(),error),error);
}
extern "C" __declspec(dllexport) int BC_mode_review_tick() {
    std::lock_guard<std::recursive_mutex> lock(review_mutex);
    std::string error;
    if (!current_review || !current_review->prepared || !current_review->entry_attempted)
        return result(reject(error,"Mode-only tick requires an entered review handle"),error);
    if (current_review->ticks>=30)
        return result(reject(error,"Mode-only review reached 30 frames; acknowledge normal stop"),error);
    if (!actor_still_current(*current_review,error)) return result(false,error);
    if (!bc::mode_tick(current_review->owner.get(),error)) return result(false,error);
    ++current_review->ticks; return result(true,error);
}
extern "C" __declspec(dllexport) int BC_mode_review_stop() {
    std::lock_guard<std::recursive_mutex> lock(review_mutex);
    std::string error;
    if (!current_review) return result(true,error);
    auto* owner=current_review->owner.get();
    if (GetCurrentThreadId()!=owner->game_thread)
        return result(reject(error,"Mode-only stop requires its owning game-call thread"),error);
    owner->enabled.store(0,std::memory_order_release);
    if (!bc::mode_restore(owner,error)) return result(false,error);
    current_review=nullptr; return result(true,error);
}
extern "C" __declspec(dllexport) uint32_t BC_mode_review_scene() {
    std::lock_guard<std::recursive_mutex> lock(review_mutex);
    const auto game=current_review?current_review->owner->game:reinterpret_cast<uintptr_t>(GetModuleHandleW(L"game.dll"));
    const auto state=bc::value<uintptr_t>(game+0x3326340);
    return state?bc::value<uint32_t>(state+0xAC21C,UINT32_MAX):UINT32_MAX;
}
extern "C" __declspec(dllexport) int BC_mode_review_ready() {
    std::lock_guard<std::recursive_mutex> lock(review_mutex);
    std::string error;
    return current_review && current_review->prepared && current_review->entry_attempted &&
        current_review->owner->enabled.load(std::memory_order_acquire)!=0 &&
        actor_still_current(*current_review,error) && bc::mode_ready(current_review->owner.get())?1:0;
}
extern "C" __declspec(dllexport) const char* BC_mode_review_error() { return review_error; }
