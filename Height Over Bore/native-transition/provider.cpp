#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <atomic>
#include <optional>
#include <cstring>
#include "provider.h"
#include "game_binding.h"
#include "hob_consumer.h"
#include "vendor/minhook/include/MinHook.h"

using Enter = void (*)(uint64_t,uint32_t,uint32_t);
using Exit = void (*)(uint64_t);
using Wield = void (*)(uint64_t,uint32_t,uint32_t,uint32_t,uint32_t);
using Unwield = void (*)(uint64_t,uint32_t,uint32_t);
using Retire = void (*)(uint64_t);
using Shutdown = void (*)();
namespace {
SRWLOCK control_lock=SRWLOCK_INIT;
struct ControlGuard {
    bool held=TryAcquireSRWLockExclusive(&control_lock)!=0;
    ~ControlGuard() {if(held)ReleaseSRWLockExclusive(&control_lock);}
};
struct Hook {
    uint64_t target=0;
    void* original=nullptr;
    unsigned char before[5]{}, patch[5]{};
    bool created=false, may_be_enabled=false;
};
struct Lease { uint64_t slot=0, original=0, wrapper=0; bool possible=false; };
std::vector<Hook> hooks(4);
Lease creation, retirement, shutdown_lease;
hob::CommitArena commit_arena;
std::optional<hob::TransitionCore> core;
std::optional<hob::HoBConsumer> consumer;
hob::Snapshot bound{};
std::atomic<bool> subscribed{false}, failed{false};
std::atomic<uint64_t> counters[7]{};
uint64_t game=0, generation=0;
uint64_t retired_world=0;
uint32_t retired_avatar=0;
size_t creation_index=0,retirement_index=0,shutdown_index=0;
DWORD owner=0;
bool used=false, minhook_ready=false, handling=false, reusable=false, closed_clean=false;
std::vector<hob::CommitSite> admitted_commits;
uint64_t admitted_image=0;uint32_t admitted_image_size=0;
HBTP_Diagnostic diagnostic{sizeof(HBTP_Diagnostic),1,0,0,0,0};
void stage(uint32_t value,uint32_t index=0) noexcept {diagnostic.stage=value;diagnostic.index=index;diagnostic.native_status=0;diagnostic.windows_error=0;}
bool hook_status(MH_STATUS value) noexcept {diagnostic.native_status=value;diagnostic.windows_error=GetLastError();return value==MH_OK;}
#if defined(HBTP_FIXTURE)
HBTP_TestBinding fixture{};
bool fixture_mode=false;
#endif
bool owner_event() noexcept {
    if (!subscribed.load(std::memory_order_acquire)) return false;
    if (GetCurrentThreadId()!=owner) {
        counters[6].fetch_add(1,std::memory_order_relaxed);
        failed.store(true,std::memory_order_release);
        return false;
    }
    if (handling) { failed.store(true,std::memory_order_release); return false; }
    return true;
}
bool snapshot(hob::Snapshot& s) noexcept {
#if defined(HBTP_FIXTURE)
    if (fixture_mode && !fixture.consumer_game) {
        HBTP_Snapshot v{};
        if (!fixture.snapshot(&v)) return false;
        s={v.world,v.implementation,v.manager,v.avatar,v.weapon,v.index,v.body,v.camera};
        return true;
    }
#endif
    return hob::local_snapshot(game,s);
}
bool camera_matches(uint64_t camera,uint32_t avatar,uint32_t weapon) noexcept {
#if defined(HBTP_FIXTURE)
    if (fixture_mode && !fixture.consumer_game) return fixture.camera(camera,avatar,weapon);
#endif
    return hob::camera_matches(game,camera,avatar,weapon);
}
bool unwield_matches(uint64_t manager,uint32_t index,uint32_t avatar,uint32_t weapon) noexcept {
#if defined(HBTP_FIXTURE)
    if (fixture_mode && !fixture.consumer_game) return fixture.unwield(manager,index,avatar,weapon);
#endif
    return hob::unwield_matches(game,manager,index,avatar,weapon);
}
bool retirement_matches(uint64_t descriptor,uint32_t avatar) noexcept {
#if defined(HBTP_FIXTURE)
    if (fixture_mode && !fixture.consumer_game) return fixture.retire(descriptor,avatar);
#endif
    return hob::retirement_matches(descriptor,avatar);
}
bool writable(uint64_t at) noexcept {
    MEMORY_BASIC_INFORMATION r{};
    return !(at&7) && VirtualQuery(reinterpret_cast<const void*>(at),&r,sizeof r)==sizeof r
        && r.State==MEM_COMMIT && (r.Protect==PAGE_READWRITE || r.Protect==PAGE_WRITECOPY)
        && at>=reinterpret_cast<uint64_t>(r.BaseAddress)
        && at+8<=reinterpret_cast<uint64_t>(r.BaseAddress)+r.RegionSize;
}
bool cas(uint64_t at,uint64_t before,uint64_t after,uint64_t& observed) noexcept {
    if (!writable(at)) return false;
    __try {
        observed=reinterpret_cast<uint64_t>(InterlockedCompareExchangePointer(
            reinterpret_cast<void* volatile*>(at),reinterpret_cast<void*>(after),reinterpret_cast<void*>(before)));
        return true;
    } __except(EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool acquire(Lease& l) noexcept {
    uint64_t observed=0;
    l.possible=true;
    if (!cas(l.slot,l.original,l.wrapper,observed)) return false;
    if (observed!=l.original) { l.possible=false; return false; }
    return true;
}
bool release(Lease& l) noexcept {
    if (!l.possible) return true;
    uint64_t current=0,observed=0;
    if (!hob::guarded_read(l.slot,&current,sizeof current)) return false;
    if (current!=l.wrapper) { l.possible=false; return true; } // preserve another owner
    if (!cas(l.slot,l.wrapper,l.original,observed)) return false;
    l.possible=false;
    return true;
}
bool pin(const void* address) noexcept {
    HMODULE module=nullptr;
    return GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_PIN,
        reinterpret_cast<LPCWSTR>(address),&module)!=0;
}
bool native_sink(hob::Sink sink) noexcept {
    MEMORY_BASIC_INFORMATION r{};
    return sink && VirtualQuery(reinterpret_cast<const void*>(sink),&r,sizeof r)==sizeof r
        && r.State==MEM_COMMIT && r.Type==MEM_IMAGE
        && (r.Protect==PAGE_EXECUTE_READ || r.Protect==PAGE_EXECUTE_READWRITE)
        && pin(reinterpret_cast<const void*>(sink));
}
bool end_core(hob::Reason reason) noexcept {
    if (!core || !core->state().live) return true;
    return core->end(core->state().identity.generation,reason);
}
bool prepare(const hob::Snapshot& s) noexcept {
    if (!core || failed.load(std::memory_order_acquire)) return false;
    auto state=core->state();
    if (state.live && (state.identity.world!=s.world || state.identity.avatar!=s.avatar
        || bound.implementation!=s.implementation || bound.body!=s.body)) {
        // A missed pre-retirement must not be converted into late restoration.
        failed.store(true,std::memory_order_release);
        return false;
    }
    if (!state.live) {
        bound=s;
        if (!core->begin(s.world,++generation,s.avatar)) return false;
    }
    bound=s;
    state=core->state();
    if (s.weapon && !core->equip(state.identity.generation,s.weapon)) return false;
    return true;
}
void record_failure(bool ok) noexcept { if (!ok) failed.store(true,std::memory_order_release); }
bool retired(const hob::Snapshot& s) noexcept {
    return s.world==retired_world && s.avatar==retired_avatar;
}
bool matches(const hob::CameraRequest& request,const hob::State& state) noexcept {
    return request.kind==6 && request.avatar==state.identity.avatar
        && request.weapon==state.identity.weapon && request.body==bound.body;
}
void before_commit(uint64_t camera,uint32_t value,uint32_t field) noexcept {
    // A failed restoration retains its lease for explicit cleanup. Never turn
    // subsequent camera commits into an unbounded restoration retry loop.
    if (!owner_event() || failed.load() || !core || !core->state().ads || camera!=bound.camera) return;
    handling=true;
    hob::CameraRequest future{};
    const bool readable=hob::camera_request(camera,field,value,future);
    if (!readable || !matches(future,core->state())) {
        record_failure(core->leave(core->state().identity.generation,hob::Reason::camera_replaced));
        if (!readable)failed.store(true,std::memory_order_release);
    }
    handling=false;
}
void after_commit(uint64_t camera) noexcept {
    if (!owner_event() || failed.load()) return;
    handling=true;
    hob::CameraRequest request{};
    if (hob::camera_request(camera,0,0,request) && request.kind==6
        && !(core && core->state().ads && camera==bound.camera && matches(request,core->state()))) {
        hob::Snapshot s{};
        if (snapshot(s) && !retired(s) && s.camera==camera && request.avatar==s.avatar
            && request.weapon==s.weapon && request.body==s.body) {
            record_failure(prepare(s) && core->enter(core->state().identity.generation,s.weapon));
        }
    }
    handling=false;
}

void enter_hook(uint64_t camera,uint32_t avatar,uint32_t weapon) {
    reinterpret_cast<Enter>(hooks[0].original)(camera,avatar,weapon);
    if (!owner_event()) return;
    counters[0].fetch_add(1,std::memory_order_relaxed);
    handling=true;
    hob::Snapshot s{};
    if (!failed.load() && snapshot(s) && !retired(s) && s.avatar==avatar && s.weapon==weapon
        && camera_matches(camera,avatar,weapon)) {
        const bool ok=prepare(s) && core->enter(core->state().identity.generation,weapon);
        record_failure(ok);
    }
    handling=false;
}
void exit_hook(uint64_t camera) {
    if (owner_event()) {
        counters[1].fetch_add(1,std::memory_order_relaxed);
        handling=true;
        if (core && core->state().ads
            && camera==bound.camera)
            record_failure(core->leave(core->state().identity.generation,hob::Reason::camera_replaced));
        handling=false;
    }
    reinterpret_cast<Exit>(hooks[1].original)(camera);
}
void wield_hook(uint64_t manager,uint32_t avatar,uint32_t slot,uint32_t weapon,uint32_t send) {
    reinterpret_cast<Wield>(hooks[2].original)(manager,avatar,slot,weapon,send);
    if (slot || !owner_event()) return;
    // Stable local ownership makes another actor's equip a negative hint only.
    // Do not rediscover our weapon for unrelated native equip events.
    if(core && core->state().live && avatar!=core->state().identity.avatar)return;
    counters[2].fetch_add(1,std::memory_order_relaxed);
    handling=true;
    hob::Snapshot s{};
    if (!failed.load() && snapshot(s) && !retired(s) && s.manager==manager && s.avatar==avatar && s.weapon==weapon)
        record_failure(prepare(s));
    handling=false;
}
void unwield_hook(uint64_t manager,uint32_t index,uint32_t slot) {
    if (!slot && owner_event()) {
        counters[3].fetch_add(1,std::memory_order_relaxed);
        handling=true;
        if (core && core->state().live && core->state().identity.weapon && manager==bound.manager
            && unwield_matches(manager,index,core->state().identity.avatar,core->state().identity.weapon))
            record_failure(core->unequip(core->state().identity.generation,hob::Reason::weapon_change));
        handling=false;
    }
    reinterpret_cast<Unwield>(hooks[3].original)(manager,index,slot);
}
void retirement_notice(uint64_t descriptor) noexcept {
    if (owner_event()) {
        counters[4].fetch_add(1,std::memory_order_relaxed);
        handling=true;
        if (core && core->state().live && retirement_matches(descriptor,core->state().identity.avatar)) {
            retired_world=core->state().identity.world;
            retired_avatar=core->state().identity.avatar;
            record_failure(end_core(hob::Reason::death));
        }
        handling=false;
    }
}
void creation_notice(uint64_t descriptor) noexcept {
    if (owner_event() && retired_avatar && retirement_matches(descriptor,retired_avatar)) {
        retired_world=0;retired_avatar=0;
    }
}
void retire_hook(uint64_t descriptor) {
    retirement_notice(descriptor);
    reinterpret_cast<Retire>(retirement.original)(descriptor);
}
void creation_hook(uint64_t descriptor) {
    reinterpret_cast<Retire>(creation.original)(descriptor);
    creation_notice(descriptor);
}
void retirement_entry(uint64_t descriptor) {
    retirement_notice(descriptor);
    reinterpret_cast<Retire>(hooks[retirement_index].original)(descriptor);
}
void creation_entry(uint64_t descriptor) {
    reinterpret_cast<Retire>(hooks[creation_index].original)(descriptor);
    creation_notice(descriptor);
}
uint32_t close_internal(hob::Reason reason) noexcept;
void shutdown_notice() noexcept {
    if (GetCurrentThreadId()==owner) {
        counters[5].fetch_add(1,std::memory_order_relaxed);
        close_internal(hob::Reason::world_teardown);
    } else {
        subscribed.store(false,std::memory_order_release);
        failed.store(true,std::memory_order_release);
        counters[6].fetch_add(1,std::memory_order_relaxed);
    }
}
void shutdown_hook() {
    shutdown_notice();
    reinterpret_cast<Shutdown>(shutdown_lease.original)();
}
void shutdown_entry() {
    const auto original=reinterpret_cast<Shutdown>(hooks[shutdown_index].original);
    shutdown_notice();
    original();
}
uint32_t close_internal(hob::Reason reason) noexcept {
    if (GetCurrentThreadId()!=owner || handling) return 0;
    subscribed.store(false,std::memory_order_release);
    handling=true;
    const bool ended=end_core(reason);
    handling=false;
    bool clean=release(creation);
    clean=release(retirement) && clean;
    clean=release(shutdown_lease) && clean;
    for (auto& h:hooks) {
        if (!h.may_be_enabled) continue;
        unsigned char bytes[5]{};
        if (!hob::guarded_read(h.target,bytes,sizeof bytes)) { clean=false; continue; }
        if (!std::memcmp(bytes,h.before,sizeof bytes)) { h.may_be_enabled=false; continue; }
        if (std::memcmp(bytes,h.patch,sizeof bytes)) {
            // Never overwrite foreign instructions. Keep trampolines pinned.
            h.may_be_enabled=false;
            continue;
        }
        if (MH_DisableHook(reinterpret_cast<void*>(h.target))!=MH_OK) { clean=false; continue; }
        h.may_be_enabled=false;
    }
    if (!ended) failed.store(true,std::memory_order_release);
    // No MH_RemoveHook/Uninitialize: a cached wrapper may still forward through
    // the retained trampoline. There are no callbacks to the subscriber now.
    closed_clean=clean && ended;
    return closed_clean?1U:2U;
}
bool can_rearm() noexcept {
    if(!used || !reusable || !closed_clean || subscribed.load() || handling
        || GetCurrentThreadId()!=owner || (core && core->state().live)
        || (consumer && consumer->stats().owned))return false;
    for(const auto& h:hooks) {
        if(!h.target)continue;
        unsigned char bytes[5]{};
        if(!h.created || h.may_be_enabled || !hob::guarded_read(h.target,bytes,sizeof bytes)
            || std::memcmp(bytes,h.before,sizeof bytes))return false;
    }
    return true;
}
uint32_t open_internal(hob::Sink sink,void* context,const uint64_t targets[4],
    uint64_t retire_slot,uint64_t shutdown_slot,uint64_t expected_retire,uint64_t expected_shutdown,
    const std::vector<hob::CommitSite>& commits={},uint64_t image_base=0,uint32_t image_size=0,
    uint64_t creation_slot=0,uint64_t expected_creation=0,const uint64_t* lifecycle=nullptr) noexcept {
    const bool rearm=used;
    if ((rearm && !can_rearm()) || !native_sink(sink) || !pin(reinterpret_cast<const void*>(&HBTP_Open))) return 0;
    if(rearm) {
        if(hooks.size()!=4+commits.size()+(lifecycle?3:0) || admitted_image!=image_base
            || admitted_image_size!=image_size || admitted_commits.size()!=commits.size())return 0;
        for(size_t i=0;i<hooks.size();++i) {
            const auto target=i<4?targets[i]:i<4+commits.size()?commits[i-4].instruction:lifecycle[i-4-commits.size()];
            if(hooks[i].target!=target)return 0;
        }
        for(size_t i=0;i<commits.size();++i) {
            const auto& a=admitted_commits[i];const auto& b=commits[i];
            if(a.instruction!=b.instruction || a.instruction_size!=b.instruction_size || a.field!=b.field
                || a.base_register!=b.base_register || a.source_register!=b.source_register
                || std::memcmp(&a.parent,&b.parent,sizeof a.parent))return 0;
        }
    }
    owner=GetCurrentThreadId(); used=true;
    failed.store(false);bound={};retired_world=0;retired_avatar=0;
    core.emplace(sink,context);
    std::vector<void*> detours;
    if(!rearm) {
    try {
        hooks.resize(4+commits.size()+(lifecycle?3:0));
        detours={reinterpret_cast<void*>(&enter_hook),reinterpret_cast<void*>(&exit_hook),
            reinterpret_cast<void*>(&wield_hook),reinterpret_cast<void*>(&unwield_hook)};
        if (!commits.empty()) {
            stage(4);
            if (!hob::build_commit_stubs(image_base,image_size,commits,before_commit,after_commit,commit_arena)) return 0;
            for(const auto& stub:commit_arena.stubs)detours.push_back(reinterpret_cast<void*>(stub.entry));
        }
        if(lifecycle) {
            creation_index=detours.size();detours.push_back(reinterpret_cast<void*>(&creation_entry));
            retirement_index=detours.size();detours.push_back(reinterpret_cast<void*>(&retirement_entry));
            shutdown_index=detours.size();detours.push_back(reinterpret_cast<void*>(&shutdown_entry));
        }
        admitted_commits=commits;admitted_image=image_base;admitted_image_size=image_size;
    } catch (...) {return 0;}
    }
    retirement.slot=retire_slot; retirement.wrapper=reinterpret_cast<uint64_t>(&retire_hook);
    shutdown_lease.slot=shutdown_slot; shutdown_lease.wrapper=reinterpret_cast<uint64_t>(&shutdown_hook);
    if(creation_slot) {
        creation.slot=creation_slot;creation.wrapper=reinterpret_cast<uint64_t>(&creation_hook);
        if(!hob::guarded_read(creation_slot,&creation.original,8) || creation.original!=expected_creation) return 0;
    }
    if (!hob::guarded_read(retire_slot,&retirement.original,8)
        || !hob::guarded_read(shutdown_slot,&shutdown_lease.original,8)
        || retirement.original!=expected_retire || shutdown_lease.original!=expected_shutdown) return 0;
    stage(5);
    if(!rearm)minhook_ready=hook_status(MH_Initialize());
    if (!minhook_ready) return 0;
    if(!rearm)for (unsigned i=0;i<hooks.size();++i) {
        auto& h=hooks[i];
        h.target=i<4?targets[i]:i<4+commits.size()?commits[i-4].instruction:lifecycle[i-4-commits.size()];
        if(!h.target)continue;
        stage(6,i);
        if (!hob::guarded_read(h.target,h.before,sizeof h.before)
            || !hook_status(MH_CreateHook(reinterpret_cast<void*>(h.target),detours[i],&h.original))) {
            close_internal(hob::Reason::disable); return 0;
        }
        h.created=true;
    }
    stage(7);
    reusable=true;closed_clean=false;
    if (!lifecycle && ((creation_slot && !acquire(creation)) || !acquire(retirement) || !acquire(shutdown_lease)))
        return close_internal(hob::Reason::disable)==1?0U:2U;
    for (auto& h:hooks) {
        if(!h.target)continue;
        h.may_be_enabled=true;
        stage(8,static_cast<uint32_t>(&h-hooks.data()));
        if (!hook_status(MH_EnableHook(reinterpret_cast<void*>(h.target)))) {
            // Save the actual post-attempt bytes for recovery only when they
            // are the expected MinHook relative-jump form; otherwise retain.
            hob::guarded_read(h.target,h.patch,sizeof h.patch);
            return close_internal(hob::Reason::disable)==1?0U:2U;
        }
        if (!hob::guarded_read(h.target,h.patch,sizeof h.patch) || h.patch[0]!=0xe9)
            return close_internal(hob::Reason::disable)==1?0U:2U;
    }
    stage(9);
    subscribed.store(true,std::memory_order_release);
    // One initial admission is allowed. No repeated retry if no avatar exists.
    hob::Snapshot initial{};
    handling=true;
    if (snapshot(initial)) {
        bool ok=prepare(initial);
        if (ok && initial.weapon && initial.camera
            && camera_matches(initial.camera,initial.avatar,initial.weapon))
            ok=core->enter(core->state().identity.generation,initial.weapon);
        record_failure(ok);
    }
    handling=false;
    if (failed.load()) return close_internal(hob::Reason::disable)==1?0U:2U;
    stage(10);
    return 1;
}
uint32_t open_game(hob::Sink sink,void* context,bool managed,bool enabled) noexcept {
    // Normal builds remain closed. A separately named, explicitly staged
    // review build enables guarded admission for authorized live verification.
#if !defined(HBTP_LIVE_REVIEW)
    return 0;
#endif
    if (used && !can_rearm()) return 0;
    uint64_t targets[4]{},retire_slot=0,shutdown_slot=0;
    stage(1);
    if (!hob::admit_game(game,targets,retire_slot,shutdown_slot)) return 0;
    std::vector<hob::CommitSite> commits;
    stage(2);
    if(!hob::admit_commit_sites(game,commits))return 0;
    // Retained native-frame unwind chains and cached continuations refer to the
    // original module even after detachment. Its code must share their lifetime.
    stage(3);
    if(!pin(reinterpret_cast<const void*>(game)))return 0;
    uint64_t implementation=0;
    if(!hob::guarded_read(game+0x346BFC8,&implementation,8))return 0;
    targets[0]=0; // ADS entry is emitted by accepted commit branches, not an observer.
    const uint64_t lifecycle[3]={game+0x53FF20,game+0x540070,game+0x4EE7F0};
    if(managed) {
        consumer.emplace(game);
        if(!consumer->set_enabled(enabled))return 0;
        sink=hob::HoBConsumer::receive;context=&*consumer;
    }
    return open_internal(sink,context,targets,retire_slot,shutdown_slot,game+0x540070,game+0x4EE7F0,
        commits,game,0x4744000,implementation+0xF0DCA8,game+0x53FF20,lifecycle);
}
}
uint32_t HBTP_Open(hob::Sink sink,void* context) {
    ControlGuard control;if(!control.held)return 0;
    return open_game(sink,context,false,false);
}
uint32_t HBTP_BuildMode() {
#if defined(HBTP_LIVE_REVIEW)
    return 1;
#else
    return 0;
#endif
}
uint32_t HBTP_ReadDiagnostic(HBTP_Diagnostic* output) {
    ControlGuard control;if(!control.held)return 0;
    HBTP_Diagnostic request{};
    if(!hob::guarded_read(reinterpret_cast<uint64_t>(output),&request,sizeof request)
        || request.size!=sizeof request || request.abi!=1)return 0;
    SIZE_T count=0;
    return WriteProcessMemory(GetCurrentProcess(),output,&diagnostic,sizeof diagnostic,&count) && count==sizeof diagnostic;
}
uint32_t HBTP_OpenHoB(uint32_t enabled) {
    ControlGuard control;if(!control.held || enabled>1)return 0;
    return open_game(nullptr,nullptr,true,enabled!=0);
}
uint32_t HBTP_SetEnabled(uint32_t enabled) {
    ControlGuard control;
    if(!control.held || enabled>1 || GetCurrentThreadId()!=owner || handling
        || !consumer || !subscribed.load() || (enabled && failed.load()))return 0;
    return consumer->set_enabled(enabled!=0)?1U:0U;
}
uint32_t HBTP_Close() {
    ControlGuard control;if(!control.held)return 0;
    return close_internal(hob::Reason::disable);
}
uint32_t HBTP_ReadStats(HBTP_Stats* output) {
    HBTP_Stats s{};
    if (!hob::guarded_read(reinterpret_cast<uint64_t>(output),&s,sizeof s) || s.size!=sizeof s || s.abi!=1) return 0;
    s.subscribed=subscribed.load(); s.failed=failed.load();
    s.entered=counters[0].load(); s.exited=counters[1].load(); s.wielded=counters[2].load();
    s.unwielded=counters[3].load(); s.retired=counters[4].load();
    s.shutdowns=counters[5].load(); s.wrong_thread=counters[6].load();
    SIZE_T n=0;
    return WriteProcessMemory(GetCurrentProcess(),output,&s,sizeof s,&n) && n==sizeof s;
}
uint32_t HBTP_ReadHoBStats(HBTP_HoBStats* output) {
    if(GetCurrentThreadId()!=owner || !consumer)return 0;
    HBTP_HoBStats s{};
    if(!hob::guarded_read(reinterpret_cast<uint64_t>(output),&s,sizeof s) || s.size!=sizeof s || s.abi!=1)return 0;
    const auto value=consumer->stats();
    s.enabled=value.enabled;s.ads=value.ads;s.owned=value.owned;s.eligible=value.eligible;
    s.preparations=value.preparations;s.definition_searches=value.definition_searches;
    s.applications=value.applications;s.restorations=value.restorations;s.foreign_edits=value.foreign_edits;
    SIZE_T n=0;
    return WriteProcessMemory(GetCurrentProcess(),output,&s,sizeof s,&n) && n==sizeof s;
}
#if defined(HBTP_FIXTURE)
uint32_t HBTP_TestOpen(const HBTP_TestBinding* binding,hob::Sink sink,void* context) {
    ControlGuard control;if(!control.held)return 0;
    if ((used && !can_rearm()) || !binding || !hob::guarded_read(reinterpret_cast<uint64_t>(binding),&fixture,sizeof fixture)
        || (!fixture.consumer_game && (!fixture.snapshot || !fixture.camera || !fixture.unwield || !fixture.retire))) return 0;
    fixture_mode=true;
    uint64_t expected_retire=0,expected_shutdown=0,expected_creation=0;
    if (!hob::guarded_read(fixture.retire_slot,&expected_retire,8)
        || !hob::guarded_read(fixture.shutdown_slot,&expected_shutdown,8)) return 0;
    if(fixture.creation_slot && !hob::guarded_read(fixture.creation_slot,&expected_creation,8))return 0;
    std::vector<hob::CommitSite> commits;
    if(fixture.site_count) {
        if(fixture.site_count>64 || !fixture.sites)return 0;
        try {commits.resize(fixture.site_count);} catch (...) {return 0;}
        if(!hob::guarded_read(reinterpret_cast<uint64_t>(fixture.sites),commits.data(),commits.size()*sizeof(hob::CommitSite)))return 0;
    }
    const bool lifecycle=fixture.lifecycle_targets[0] || fixture.lifecycle_targets[1] || fixture.lifecycle_targets[2];
    if(lifecycle && (!fixture.lifecycle_targets[0] || !fixture.lifecycle_targets[1] || !fixture.lifecycle_targets[2]))return 0;
    if(fixture.consumer_game) {
        if(fixture.consumer_enabled>1)return 0;
        game=fixture.consumer_game;consumer.emplace(game);
        if(!consumer->set_enabled(fixture.consumer_enabled!=0))return 0;
        sink=hob::HoBConsumer::receive;context=&*consumer;
    }
    return open_internal(sink,context,fixture.targets,fixture.retire_slot,fixture.shutdown_slot,
        expected_retire,expected_shutdown,commits,fixture.image_base,fixture.image_size,
        fixture.creation_slot,expected_creation,lifecycle?fixture.lifecycle_targets:nullptr);
}
#endif
