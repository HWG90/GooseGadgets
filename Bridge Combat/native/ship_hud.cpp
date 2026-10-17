#include "ship_hud.h"
#include "core.h" // guarded read helpers only; no actor/Core lease calls
#include "vendor/minhook/include/MinHook.h"
#include <array>
#include <cmath>
#include <cstring>
#include <mutex>

namespace bc::ship_hud {
namespace {
constexpr uintptr_t kUiPointer=0x346D538, kGuiPointer=0x347CE90, kObserverPointer=0x3326E68;
constexpr uintptr_t kShip=0x46D900, kShipInitialized=kShip+0x89778;
constexpr uintptr_t kUiInitialized=0x24E334, kScale=0x24E324;
constexpr uintptr_t kShipInit=0x137C9B0, kShipDestroy=0x137D500, kShipResize=0x137EC60;
using UiCall=void(__fastcall*)(void*);
using ShipInit=void(__fastcall*)(void*,void*,void*,void*);
using ShipResize=void(__fastcall*)(void*,float);
Identity target;
uintptr_t observer_owner{};
Phase phase=Phase::None;
bool prepared{}, owned{}, retired{};
std::recursive_mutex mutex;
UiCall original_ui_init{}, original_ui_destroy{}, ship_destroy{};
ShipInit ship_initialize{};
ShipResize ship_resize{};
std::string pending_error;
struct Hook {
    uintptr_t rva;
    const char* fingerprint;
    bool created{}, enabled{};
};
// Lifecycle bytes also match Toolkit bridge-common-ui-hook-fingerprints-
// 20261014.txt (current build). They must match before staging each hook.
// No selector sites exist.
std::array<Hook,2> hooks{{
    {0x12F0920,"48895c241048896c24184889742420574154415541564157"},
    {0x12F1540,"40554883ec3080b934e3240000488be90f84590400004889"}
}};
constexpr std::array<std::pair<uintptr_t,const char*>,3> native_abi{{
    {kShipInit,"488bc45553565741564157488d68a14881eca80000004c8b"},
    {kShipDestroy,"40554883ec3080b97897080000488be90f84d30600004889"},
    {kShipResize,"40574883ec2080b978970800000f28e1488bf90f84640100"}
}};
bool fail(std::string& error,const char* message) { error=message; return false; }
bool on_thread() { return target.thread && GetCurrentThreadId()==target.thread; }
bool same_ui() { return value<uintptr_t>(target.game+kUiPointer)==target.ui; }
bool match(uintptr_t address,const char* hex) {
    const auto digit=[](char c) { return c>='0'&&c<='9'?c-'0':c>='a'&&c<='f'?c-'a'+10:-1; };
    for (size_t i=0;hex[i];i+=2) {
        uint8_t actual{}; const int a=digit(hex[i]),b=digit(hex[i+1]);
        if (a<0 || b<0 || !read(address+i/2,actual) || actual!=((a<<4)|b)) return false;
    }
    return true;
}
bool executable(uintptr_t address) {
    MEMORY_BASIC_INFORMATION info{};
    return VirtualQuery(reinterpret_cast<void*>(address),&info,sizeof(info)) &&
        info.State==MEM_COMMIT && !(info.Protect&(PAGE_GUARD|PAGE_NOACCESS)) &&
        (info.Protect&(PAGE_EXECUTE|PAGE_EXECUTE_READ|PAGE_EXECUTE_READWRITE|PAGE_EXECUTE_WRITECOPY));
}
bool writable(uintptr_t address,size_t size) {
    MEMORY_BASIC_INFORMATION info{};
    return VirtualQuery(reinterpret_cast<void*>(address),&info,sizeof(info)) &&
        info.State==MEM_COMMIT && !(info.Protect&(PAGE_GUARD|PAGE_NOACCESS)) &&
        (info.Protect&(PAGE_READWRITE|PAGE_WRITECOPY|PAGE_EXECUTE_READWRITE|PAGE_EXECUTE_WRITECOPY)) &&
        size<=info.RegionSize-(address-reinterpret_cast<uintptr_t>(info.BaseAddress));
}
template<class T> bool store(uintptr_t address,T item) {
    __try { *reinterpret_cast<T*>(address)=item; return *reinterpret_cast<T*>(address)==item; }
    __except(EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool roots(std::string& error) {
    for (const auto& item:std::array<std::pair<uintptr_t,uintptr_t>,3>{{
        {0x820,0x258},{0x930,0x380},{0xA40,0x5D0}}}) {
        uintptr_t parent{}; uint32_t flags{};
        if (!read(target.ui+item.first+0xF0,parent) || parent!=target.ui+item.second || !read(parent,flags))
            return fail(error,"Ship HUD common-root identity changed");
    }
    return true;
}
bool observer_rows(bool registered,std::string& error) {
    // ShipInit directly registers its main pointer/callback0x118 in these three
    // lists; ShipDestroy removes those rows. Require exclusive row0 ownership,
    // not a guessed layout capacity. The freed known row is the rebuild room.
    if (!observer_owner || value<uintptr_t>(target.game+kObserverPointer)!=observer_owner)
        return fail(error,"Ship HUD observer owner changed or unavailable");
    for (const auto& row:std::array<std::pair<uintptr_t,uintptr_t>,3>{{
        {0x27A8,0x27B0},{0x3890,0x3898},{0x38A8,0x38B0}}}) {
        uint32_t count{};
        if (!read(observer_owner+row.first,count) || count!=(registered?1U:0U))
            return fail(error,"Ship HUD observer rows are not exclusively owned or freed");
        if (registered) {
            uintptr_t object{}; uint32_t callback{};
            if (!read(observer_owner+row.second,object) || object!=target.ui+kShip ||
                !read(observer_owner+row.second+8,callback) || callback!=0x118)
                return fail(error,"Ship HUD observer registration identity changed");
        }
    }
    return true;
}
bool presentation(std::string& error) {
    uint8_t initialized{};
    if (!on_thread() || !same_ui()) return fail(error,"Ship HUD UI identity/owning thread changed");
    if (!read(target.ui+kUiInitialized,initialized) || initialized!=1)
        return fail(error,"Ship HUD common UI is not initialized");
    return roots(error);
}
bool scale(float& result,std::string& error) {
    if (!read(target.ui+kScale,result) || !std::isfinite(result) || result<=0)
        return fail(error,"Ship HUD ordinary resize scale unavailable");
    return true;
}
struct GuiJournal {
    uintptr_t gui{}, slot{};
    int32_t old_depth{}, new_depth{};
    uint8_t old_slot{};
    bool depth_pending{}, slot_pending{};
    bool pending() const { return depth_pending || slot_pending; }
    bool restore(std::string& error) {
        if (!pending()) return true;
        // Never overwrite a foreign context/depth after losing ownership.
        if (value<uintptr_t>(target.game+kGuiPointer)!=gui)
            return fail(error,"Ship HUD GUI owner changed with restoration pending");
        int32_t depth{};
        if (depth_pending && (!read(gui+0x2C5BC,depth) || (depth!=new_depth && depth!=old_depth)))
            return fail(error,"Ship HUD GUI depth restoration pending");
        if (slot_pending) {
            uint8_t now{};
            if (!read(slot,now) || (now!=5 && now!=old_slot))
                return fail(error,"Ship HUD GUI context-slot restoration pending");
            if (now!=old_slot && !store(slot,old_slot))
                return fail(error,"Ship HUD GUI context-slot restoration pending");
            slot_pending=false;
        }
        if (depth_pending) {
            if (depth!=old_depth && !store(gui+0x2C5BC,old_depth))
                return fail(error,"Ship HUD GUI depth restoration pending");
            depth_pending=false;
        }
        return true;
    }
    bool available(std::string& error) const {
        const auto pointer=value<uintptr_t>(target.game+kGuiPointer);
        int32_t depth{}; uint8_t byte{};
        if (!pointer || !read(pointer+0x2C5BC,depth) || depth<-1 || depth>2)
            return fail(error,"Ship HUD GUI signed depth cannot push context 5");
        const auto next=pointer+0x2C5B8+static_cast<uintptr_t>(depth+1);
        if (!read(next,byte) || !writable(next,1) || !writable(pointer+0x2C5BC,4))
            return fail(error,"Ship HUD GUI construction scope unavailable");
        return true;
    }
    bool enter(std::string& error) {
        if (pending()) return fail(error,"Ship HUD prior GUI restoration pending");
        if (!available(error)) return false;
        gui=value<uintptr_t>(target.game+kGuiPointer);
        if (!read(gui+0x2C5BC,old_depth) || old_depth<-1 || old_depth>2)
            return fail(error,"Ship HUD GUI depth snapshot unavailable or changed");
        new_depth=old_depth+1; slot=gui+0x2C5B8+static_cast<uintptr_t>(new_depth);
        if (!read(slot,old_slot)) return fail(error,"Ship HUD GUI slot snapshot unavailable");
        depth_pending=true;
        if (!store(gui+0x2C5BC,new_depth)) { restore(error); return fail(error,"Ship HUD GUI push readback failed"); }
        slot_pending=true;
        if (!store(slot,uint8_t{5})) { restore(error); return fail(error,"Ship HUD GUI context readback failed"); }
        return true;
    }
} gui;
bool native_guards(std::string& error) {
    for (const auto& item:native_abi)
        if (!executable(target.game+item.first) || !match(target.game+item.first,item.second))
            return fail(error,"Ship HUD direct native ABI fingerprint changed");
    return true;
}
// Keep SEH at the native-call boundary, outside objects requiring C++ unwinding.
bool call_destroy() {
    __try { ship_destroy(reinterpret_cast<void*>(target.ui+kShip)); return true; }
    __except(EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_initialize() {
    __try {
        ship_initialize(reinterpret_cast<void*>(target.ui+kShip),reinterpret_cast<void*>(target.ui+0x820),
            reinterpret_cast<void*>(target.ui+0x930),reinterpret_cast<void*>(target.ui+0xA40));
        return true;
    } __except(EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool call_resize(float amount) {
    __try { ship_resize(reinterpret_cast<void*>(target.ui+kShip),amount); return true; }
    __except(EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool ship_flag(uint8_t expected,std::string& error) {
    uint8_t flag{};
    if (!read(target.ui+kShipInitialized,flag) || flag!=expected)
        return fail(error,"Ship HUD returned native call readback pending or presentation changed");
    return true;
}
bool returned_destroy(std::string& error) {
    if (phase!=Phase::DestroyReturned) return true;
    if (!ship_flag(0,error) || !observer_rows(false,error)) return false;
    phase=Phase::Suppressed; return true;
}
bool enable_hooks(std::string& error) {
    for (auto& hook:hooks) if (!hook.enabled) {
        const auto result=MH_EnableHook(reinterpret_cast<void*>(target.game+hook.rva));
        if (result!=MH_OK) {
            for (auto& undo:hooks) if (undo.enabled &&
                MH_DisableHook(reinterpret_cast<void*>(target.game+undo.rva))==MH_OK) undo.enabled=false;
            return fail(error,"Ship HUD lifecycle hooks could not be enabled; release staged hooks before retry");
        }
        hook.enabled=true;
    }
    return true;
}
bool retire_before_ui(std::string& error) {
    if (!gui.restore(error) || !returned_destroy(error)) return false;
    if (phase==Phase::RebuildReturned) {
        if (!ship_flag(1,error) || !observer_rows(true,error)) return false;
        phase=Phase::Rebuilt;
    }
    if (phase==Phase::Rebuilt || phase==Phase::ResizeReturned) {
        // A completed owned rebuild may be awaiting resize readback. Destroy it
        // once before ordinary UI init so the next constructor cannot overlap.
        if (!native_guards(error) || !ship_flag(1,error) || !observer_rows(true,error)) return false;
        phase=Phase::DestroyCalling;
        if (!call_destroy()) { phase=Phase::InterruptedDestroy; return fail(error,"Ship HUD teardown interrupted; native ownership retained"); }
        phase=Phase::DestroyReturned;
        if (!returned_destroy(error)) return false;
    }
    if (phase!=Phase::Suppressed)
        return fail(error,"Ship HUD native call/partial construction pending before common UI lifecycle");
    if (!ship_flag(0,error)) return false;
    owned=false; phase=Phase::None; retired=true; pending_error.clear();
    return true;
}
void lifecycle(void* object,UiCall original) {
    std::lock_guard<std::recursive_mutex> lock(mutex);
    if (owned && reinterpret_cast<uintptr_t>(object)==target.ui) {
        std::string error;
        if (!on_thread() || !roots(error) || !retire_before_ui(error)) {
            pending_error=error.empty()?"Ship HUD lifecycle arrived off its owning thread":error;
            // A partial/uncertain native object cannot be forwarded into shared
            // root destruction or a second constructor. Retain the journal.
            return;
        }
    }
    original(object);
}
void __fastcall init_hook(void* object) { lifecycle(object,original_ui_init); }
void __fastcall destroy_hook(void* object) { lifecycle(object,original_ui_destroy); }
} // namespace

bool prepare(const Identity& identity,std::string& error) {
    std::lock_guard<std::recursive_mutex> lock(mutex);
    if (prepared || owned || hooks[0].created || hooks[1].created || gui.pending())
        return fail(error,"Release the existing Ship HUD hook/lease journal before preparing");
    target=identity; retired=false; pending_error.clear();
    observer_owner=value<uintptr_t>(identity.game+kObserverPointer);
    uint16_t mz{}; int32_t pe{}; uint32_t signature{},stamp{};
    if (!identity.game || !identity.ui || !on_thread() ||
        !read(identity.game,mz) || mz!=0x5A4D || !read(identity.game+0x3C,pe) || pe<0x40 || pe>0x1000 ||
        !read(identity.game+pe,signature) || signature!=0x4550 ||
        !read(identity.game+pe+8,stamp) || stamp!=0x6AB3B43F)
        return fail(error,"Unsupported Ship HUD module identity/build/thread");
    float amount{};
    if (!presentation(error) || !ship_flag(1,error) || !observer_rows(true,error) ||
        !scale(amount,error) || !gui.available(error) || !native_guards(error)) return false;
    for (const auto& hook:hooks) if (!executable(target.game+hook.rva) || !match(target.game+hook.rva,hook.fingerprint))
        return fail(error,"Ship HUD common UI lifecycle ABI fingerprint changed");
    const auto initialized=MH_Initialize();
    if (initialized!=MH_OK && initialized!=MH_ERROR_ALREADY_INITIALIZED)
        return fail(error,"Ship HUD hook library initialization failed");
    const std::array<void*,2> detours{{reinterpret_cast<void*>(init_hook),reinterpret_cast<void*>(destroy_hook)}};
    const std::array<void**,2> originals{{reinterpret_cast<void**>(&original_ui_init),reinterpret_cast<void**>(&original_ui_destroy)}};
    for (size_t i=0;i<hooks.size();++i) {
        if (MH_CreateHook(reinterpret_cast<void*>(target.game+hooks[i].rva),detours[i],originals[i])!=MH_OK)
            return fail(error,"Ship HUD disabled hook staging failed; release retained staged hooks");
        hooks[i].created=true;
    }
    ship_initialize=reinterpret_cast<ShipInit>(target.game+kShipInit);
    ship_destroy=reinterpret_cast<UiCall>(target.game+kShipDestroy);
    ship_resize=reinterpret_cast<ShipResize>(target.game+kShipResize);
    prepared=true; return true;
}
bool suppress(std::string& error) {
    std::lock_guard<std::recursive_mutex> lock(mutex);
    if (!prepared || !presentation(error)) return fail(error,"Ship HUD suppression identity/preparation refused");
    if (owned) {
        if (!returned_destroy(error)) return false;
        if (phase!=Phase::Suppressed) return fail(error,"Ship HUD native restoration/interruption remains pending");
        return ship_flag(0,error);
    }
    float amount{};
    if (!ship_flag(1,error) || !observer_rows(true,error) || !scale(amount,error) ||
        !gui.available(error) || !native_guards(error) || !enable_hooks(error)) return false;
    owned=true; retired=false; phase=Phase::DestroyCalling;
    if (!call_destroy()) { phase=Phase::InterruptedDestroy; return fail(error,"Ship HUD destruction interrupted; native ownership retained"); }
    phase=Phase::DestroyReturned;
    return returned_destroy(error);
}
bool restore(std::string& error) {
    std::lock_guard<std::recursive_mutex> lock(mutex);
    if (!owned) return !gui.pending() || gui.restore(error);
    if (!presentation(error) || !gui.restore(error) || !returned_destroy(error)) return false;
    if (phase==Phase::Suppressed) {
        float amount{};
        if (!ship_flag(0,error) || !observer_rows(false,error) || !scale(amount,error) ||
            !native_guards(error) || !gui.enter(error)) return false;
        phase=Phase::RebuildCalling;
        const bool returned=call_initialize();
        phase=returned?Phase::RebuildReturned:Phase::InterruptedRebuild;
        const bool scope_restored=gui.restore(error);
        if (!returned) return fail(error,"Ship HUD partial initialization pending; do not reconstruct or guess cleanup");
        if (!scope_restored) return false;
    }
    if (phase==Phase::RebuildReturned) {
        if (!ship_flag(1,error) || !observer_rows(true,error)) return false;
        phase=Phase::Rebuilt;
    }
    if (phase==Phase::Rebuilt) {
        float amount{};
        if (!native_guards(error) || !scale(amount,error)) return false;
        phase=Phase::ResizeCalling;
        if (!call_resize(amount)) { phase=Phase::InterruptedResize; return fail(error,"Ship HUD resize interrupted; native ownership retained"); }
        phase=Phase::ResizeReturned;
    }
    if (phase!=Phase::ResizeReturned)
        return fail(error,"Ship HUD interrupted native ownership remains pending");
    if (!ship_flag(1,error) || !observer_rows(true,error)) return false;
    owned=false; phase=Phase::None; pending_error.clear();
    return true;
}
bool release(std::string& error) {
    std::lock_guard<std::recursive_mutex> lock(mutex);
    if (!on_thread()) return fail(error,"Ship HUD release requires its owning thread");
    if (owned || gui.pending()) return fail(error,"Ship HUD restoration/retirement must acknowledge before hook removal");
    bool complete=true;
    for (auto& hook:hooks) {
        const auto address=reinterpret_cast<void*>(target.game+hook.rva);
        if (hook.enabled) {
            const auto result=MH_DisableHook(address);
            if (result!=MH_OK && result!=MH_ERROR_DISABLED) { complete=false; continue; }
            hook.enabled=false;
        }
        if (hook.created) {
            if (MH_RemoveHook(address)!=MH_OK) { complete=false; continue; }
            hook.created=false;
        }
    }
    if (!complete) return fail(error,"Ship HUD hook removal pending");
    prepared=false; original_ui_init=nullptr; original_ui_destroy=nullptr;
    ship_initialize=nullptr; ship_destroy=nullptr; ship_resize=nullptr; pending_error.clear();
    return true;
}
Status status() {
    std::lock_guard<std::recursive_mutex> lock(mutex);
    return {phase,prepared,hooks[0].enabled && hooks[1].enabled,owned,gui.pending(),retired,!pending_error.empty()};
}
} // namespace bc::ship_hud

#ifdef BC_NATIVE_TEST_API
namespace {
thread_local char ship_hud_error[512]{};
int ship_result(bool success,const std::string& error) {
    strncpy_s(ship_hud_error,error.c_str(),_TRUNCATE); return success?1:0;
}
}
extern "C" __declspec(dllexport) int BC_ship_hud_prepare() {
    const auto game=reinterpret_cast<uintptr_t>(GetModuleHandleW(L"game.dll"));
    std::string error;
    return ship_result(bc::ship_hud::prepare({game,bc::value<uintptr_t>(game+0x346D538),GetCurrentThreadId()},error),error);
}
extern "C" __declspec(dllexport) int BC_ship_hud_suppress() {
    std::string error; return ship_result(bc::ship_hud::suppress(error),error);
}
extern "C" __declspec(dllexport) int BC_ship_hud_restore() {
    std::string error; return ship_result(bc::ship_hud::restore(error),error);
}
extern "C" __declspec(dllexport) int BC_ship_hud_release() {
    std::string error; return ship_result(bc::ship_hud::release(error),error);
}
extern "C" __declspec(dllexport) uint32_t BC_ship_hud_phase() {
    return static_cast<uint32_t>(bc::ship_hud::status().phase);
}
extern "C" __declspec(dllexport) uint32_t BC_ship_hud_flags() {
    const auto state=bc::ship_hud::status();
    return (state.prepared?1U:0U)|(state.hooks_enabled?2U:0U)|(state.owned?4U:0U)|
        (state.gui_restore_pending?8U:0U)|(state.retired?16U:0U)|(state.lifecycle_blocked?32U:0U);
}
extern "C" __declspec(dllexport) const char* BC_ship_hud_error() {
    std::lock_guard<std::recursive_mutex> lock(bc::ship_hud::mutex);
    if (!bc::ship_hud::pending_error.empty()) strncpy_s(ship_hud_error,bc::ship_hud::pending_error.c_str(),_TRUNCATE);
    return ship_hud_error;
}
#endif
