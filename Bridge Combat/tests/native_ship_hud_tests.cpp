// Isolated fake module/widgets and fake MinHook. No game handle or DLL load.
#include "../native/ship_hud.cpp"
#include <cassert>
#include <iostream>
#include <thread>
#include <vector>

namespace {
namespace sh=bc::ship_hud;
uintptr_t game{},ui{},gui_memory{},observer_memory{};
unsigned ship_destroys{},ship_initializes{},ship_resizes{},ui_initializes{},ui_destroys{},foreign_calls{};
unsigned created{},enabled{},disabled{},removed{},widgets{},observer_entries{},roots_epoch{};
bool hide_destroy_readback{},hide_constructor_readback{},change_scope_slot{},partial_constructor{};
int fail_create_index=-1,fail_enable_index=-1;
uintptr_t hidden_page{};
float resize_value{};
std::array<bool,2> fake_created{},fake_enabled{};
template<class T> void put(uintptr_t address,T item) { *reinterpret_cast<T*>(address)=item; }
uintptr_t alloc(size_t count,DWORD protection=PAGE_READWRITE) {
    const auto address=reinterpret_cast<uintptr_t>(VirtualAlloc(nullptr,count,MEM_RESERVE|MEM_COMMIT,protection));
    assert(address); return address;
}
void bytes(uintptr_t address,const char* hex) {
    const auto digit=[](char c) { return c>='0'&&c<='9'?c-'0':c-'a'+10; };
    for (size_t i=0;hex[i];i+=2) put<uint8_t>(address+i/2,static_cast<uint8_t>((digit(hex[i])<<4)|digit(hex[i+1])));
}
void root_links() {
    for (const auto& pair:std::array<std::pair<uintptr_t,uintptr_t>,3>{{{0x820,0x258},{0x930,0x380},{0xA40,0x5D0}}}) {
        put(ui+pair.first+0xF0,ui+pair.second); put<uint32_t>(ui+pair.second,0x1015);
    }
}
void observer_rows(bool registered) {
    for (const auto& row:std::array<std::pair<uintptr_t,uintptr_t>,3>{{
        {0x27A8,0x27B0},{0x3890,0x3898},{0x38A8,0x38B0}}}) {
        put<uint32_t>(observer_memory+row.first,registered?1U:0U);
        if (registered) { put(observer_memory+row.second,ui+sh::kShip); put<uint32_t>(observer_memory+row.second+8,0x118); }
    }
}
void hide_flag_page() {
    hidden_page=(ui+sh::kShipInitialized)&~uintptr_t{4095}; DWORD old{};
    assert(VirtualProtect(reinterpret_cast<void*>(hidden_page),4096,PAGE_NOACCESS,&old));
}
void show_flag_page() {
    DWORD old{}; assert(VirtualProtect(reinterpret_cast<void*>(hidden_page),4096,PAGE_READWRITE,&old));
    hidden_page=0;
}
void __fastcall destroy_ship(void* object) {
    assert(reinterpret_cast<uintptr_t>(object)==ui+sh::kShip);
    assert(bc::value<uint8_t>(ui+sh::kShipInitialized)==1 && widgets==1 && observer_entries==1);
    ++ship_destroys; widgets=0; observer_entries=0; observer_rows(false); put<uint8_t>(ui+sh::kShipInitialized,0);
    if (hide_destroy_readback) { hide_destroy_readback=false; hide_flag_page(); }
}
void __fastcall initialize_ship(void* object,void* a,void* b,void* c) {
    assert(reinterpret_cast<uintptr_t>(object)==ui+sh::kShip);
    assert(a==reinterpret_cast<void*>(ui+0x820) && b==reinterpret_cast<void*>(ui+0x930) && c==reinterpret_cast<void*>(ui+0xA40));
    assert(bc::value<uint8_t>(ui+sh::kShipInitialized)==0 && widgets==0 && observer_entries==0);
    const auto depth=bc::value<int32_t>(gui_memory+0x2C5BC);
    assert(depth>=0 && depth<=3 && bc::value<uint8_t>(gui_memory+0x2C5B8+depth)==5);
    ++ship_initializes; widgets=1; observer_entries=1; observer_rows(true);
    if (partial_constructor) RaiseException(0xE0000001,0,0,nullptr);
    put<uint8_t>(ui+sh::kShipInitialized,1);
    if (change_scope_slot) {
        change_scope_slot=false; put<uint8_t>(gui_memory+0x2C5B8+depth,9);
    }
    if (hide_constructor_readback) { hide_constructor_readback=false; hide_flag_page(); }
}
void __fastcall resize_ship(void* object,float scale) {
    assert(reinterpret_cast<uintptr_t>(object)==ui+sh::kShip);
    assert(bc::value<uint8_t>(ui+sh::kShipInitialized)==1 && widgets==1 && observer_entries==1);
    ++ship_resizes; resize_value=scale;
}
void __fastcall normal_ui_init(void* object) {
    if (reinterpret_cast<uintptr_t>(object)!=ui) { ++foreign_calls; return; }
    assert(!sh::status().owned && !sh::status().gui_restore_pending);
    assert(bc::value<uint8_t>(ui+sh::kShipInitialized)==0);
    ++ui_initializes; ++roots_epoch;
    root_links(); widgets=1; observer_entries=1; observer_rows(true);
    put<uint8_t>(ui+sh::kUiInitialized,1); put<uint8_t>(ui+sh::kShipInitialized,1);
}
void __fastcall normal_ui_destroy(void* object) {
    if (reinterpret_cast<uintptr_t>(object)!=ui) { ++foreign_calls; return; }
    assert(!sh::status().owned && !sh::status().gui_restore_pending);
    assert(bc::value<uint8_t>(ui+sh::kShipInitialized)==0 && widgets==0 && observer_entries==0);
    ++ui_destroys; ++roots_epoch; put<uint8_t>(ui+sh::kUiInitialized,0);
}
void native_stubs() {
    sh::ship_destroy=destroy_ship; sh::ship_initialize=initialize_ship; sh::ship_resize=resize_ship;
}
void fixture() {
    assert(!GetModuleHandleW(L"game.dll"));
    game=alloc(0x3500000,PAGE_EXECUTE_READWRITE); ui=alloc(0x500000); gui_memory=alloc(0x30000); observer_memory=alloc(0x4000);
    put<uint16_t>(game,0x5A4D); put<int32_t>(game+0x3C,0x100);
    put<uint32_t>(game+0x100,0x4550); put<uint32_t>(game+0x108,0x6AB3B43F);
    put(game+sh::kUiPointer,ui); put(game+sh::kGuiPointer,gui_memory);
    put(game+sh::kObserverPointer,observer_memory);
    put<uint8_t>(ui+sh::kUiInitialized,1); put<uint8_t>(ui+sh::kShipInitialized,1);
    put<float>(ui+sh::kScale,1.25f); put<int32_t>(gui_memory+0x2C5BC,-1);
    for (uintptr_t i=0;i<4;++i) put<uint8_t>(gui_memory+0x2C5B8+i,static_cast<uint8_t>(20+i));
    root_links(); widgets=1; observer_entries=1; observer_rows(true);
    for (const auto& item:sh::native_abi) bytes(game+item.first,item.second);
    for (const auto& hook:sh::hooks) bytes(game+hook.rva,hook.fingerprint);
    // Sentinels outside the Ship lease: scene, role, and Mission fields.
    put<uint32_t>(game+0x1000,3); put<uint64_t>(game+0x1010,0x202);
    put<uint8_t>(ui+0x46D8F0,0xA5); put<uint8_t>(ui+0x24E398,0xB6);
}
void unrelated_unchanged() {
    assert(bc::value<uint32_t>(game+0x1000)==3 && bc::value<uint64_t>(game+0x1010)==0x202);
    assert(bc::value<uint8_t>(ui+0x46D8F0)==0xA5 && bc::value<uint8_t>(ui+0x24E398)==0xB6);
    for (const auto& item:sh::native_abi) assert(sh::match(game+item.first,item.second));
}
void prepare(std::string& error) {
    assert(sh::prepare({game,ui,GetCurrentThreadId()},error)); native_stubs();
    assert(sh::status().prepared && !sh::status().hooks_enabled && !sh::status().owned);
    assert(!fake_enabled[0] && !fake_enabled[1]);
}
int hook_index(LPVOID pointer) {
    assert(pointer && pointer!=MH_ALL_HOOKS);
    for (int i=0;i<2;++i) if (reinterpret_cast<uintptr_t>(pointer)==game+sh::hooks[i].rva) return i;
    assert(false); return -1;
}
}
extern "C" MH_STATUS WINAPI MH_Initialize() { return MH_OK; }
extern "C" MH_STATUS WINAPI MH_CreateHook(LPVOID pointer,LPVOID callback,LPVOID* original) {
    const int index=hook_index(pointer);
    assert(callback==reinterpret_cast<void*>(index==0?sh::init_hook:sh::destroy_hook));
    assert(!fake_created[index]);
    if (fail_create_index==index) return MH_ERROR_MEMORY_ALLOC;
    fake_created[index]=true; ++created;
    *original=reinterpret_cast<void*>(index==0?normal_ui_init:normal_ui_destroy); return MH_OK;
}
extern "C" MH_STATUS WINAPI MH_EnableHook(LPVOID pointer) {
    const int index=hook_index(pointer); assert(fake_created[index] && !fake_enabled[index]);
    if (fail_enable_index==index) return MH_ERROR_MEMORY_PROTECT;
    fake_enabled[index]=true; ++enabled; return MH_OK;
}
extern "C" MH_STATUS WINAPI MH_DisableHook(LPVOID pointer) {
    const int index=hook_index(pointer); assert(fake_created[index]);
    if (!fake_enabled[index]) return MH_ERROR_DISABLED;
    fake_enabled[index]=false; ++disabled; return MH_OK;
}
extern "C" MH_STATUS WINAPI MH_RemoveHook(LPVOID pointer) {
    const int index=hook_index(pointer); assert(fake_created[index] && !fake_enabled[index]);
    fake_created[index]=false; ++removed; return MH_OK;
}
int main() {
    fixture(); std::string error;
    const auto thread=GetCurrentThreadId();
    assert(!sh::prepare({game,ui,thread+1},error)); assert(created==0 && ship_destroys==0);
    put<uint8_t>(game+sh::kShipDestroy,0xCC);
    assert(!sh::prepare({game,ui,thread},error)); assert(created==0 && ship_destroys==0);
    bytes(game+sh::kShipDestroy,sh::native_abi[1].second);
    put<uintptr_t>(ui+0x820+0xF0,ui+0x380);
    assert(!sh::prepare({game,ui,thread},error)); assert(created==0 && ship_destroys==0); root_links();
    put<uint32_t>(observer_memory+0x27A8,2);
    assert(!sh::prepare({game,ui,thread},error)); assert(created==0 && ship_destroys==0); observer_rows(true);
    put<uintptr_t>(observer_memory+0x38B0,ui+16);
    assert(!sh::prepare({game,ui,thread},error)); assert(created==0 && ship_destroys==0); observer_rows(true);
    for (const int32_t depth:{-2,3}) {
        put<int32_t>(gui_memory+0x2C5BC,depth);
        assert(!sh::prepare({game,ui,thread},error)); assert(created==0 && ship_destroys==0);
    }
    put<int32_t>(gui_memory+0x2C5BC,-1);
    fail_create_index=1; assert(!sh::prepare({game,ui,thread},error));
    assert(fake_created[0] && !fake_created[1] && !fake_enabled[0] && ship_destroys==0);
    assert(sh::release(error)); fail_create_index=-1;
    prepare(error); fail_enable_index=1;
    assert(!sh::suppress(error)); assert(!fake_enabled[0] && !fake_enabled[1] && ship_destroys==0);
    assert(sh::release(error)); fail_enable_index=-1;
    for (const int32_t depth:{-1,0,1,2}) {
        put<int32_t>(gui_memory+0x2C5BC,depth);
        std::array<uint8_t,4> before{};
        std::memcpy(before.data(),reinterpret_cast<void*>(gui_memory+0x2C5B8),before.size());
        prepare(error); assert(sh::suppress(error));
        assert(sh::status().owned && sh::status().hooks_enabled && widgets==0 && observer_entries==0);
        const auto destroyed=ship_destroys,constructed=ship_initializes;
        assert(sh::suppress(error) && ship_destroys==destroyed); assert(!sh::release(error));
        sh::init_hook(reinterpret_cast<void*>(ui+16)); sh::destroy_hook(reinterpret_cast<void*>(ui+16));
        assert(sh::status().owned && foreign_calls>=2 && ship_initializes==constructed);
        bool cross_thread_result=true;
        std::thread other([&]{std::string e; cross_thread_result=sh::restore(e);}); other.join();
        assert(!cross_thread_result && ship_initializes==constructed);
        assert(sh::restore(error));
        assert(ship_initializes==constructed+1 && resize_value==1.25f && widgets==1 && observer_entries==1);
        assert(bc::value<int32_t>(gui_memory+0x2C5BC)==depth);
        assert(std::memcmp(before.data(),reinterpret_cast<void*>(gui_memory+0x2C5B8),before.size())==0);
        assert(sh::restore(error) && ship_initializes==constructed+1);
        unrelated_unchanged(); assert(sh::release(error));
    }
    // A returned destructor with hidden readback must not execute twice.
    put<int32_t>(gui_memory+0x2C5BC,-1); prepare(error); hide_destroy_readback=true;
    assert(!sh::suppress(error)); const auto destroyed=ship_destroys;
    assert(sh::status().phase==sh::Phase::DestroyReturned && !sh::release(error));
    assert(!sh::restore(error) && ship_destroys==destroyed);
    show_flag_page(); assert(sh::restore(error)); assert(ship_destroys==destroyed); assert(sh::release(error));
    // A returned constructor with hidden readback must retain its phase.
    prepare(error); assert(sh::suppress(error)); hide_constructor_readback=true;
    assert(!sh::restore(error)); const auto built=ship_initializes;
    assert(sh::status().phase==sh::Phase::RebuildReturned && !sh::status().gui_restore_pending);
    assert(!sh::restore(error) && ship_initializes==built);
    show_flag_page(); assert(sh::restore(error) && ship_initializes==built); assert(sh::release(error));
    // A foreign context change blocks restoration and constructor replay.
    prepare(error); assert(sh::suppress(error)); change_scope_slot=true;
    assert(!sh::restore(error)); const auto scope_built=ship_initializes;
    assert(sh::status().gui_restore_pending && !sh::release(error));
    assert(!sh::restore(error) && ship_initializes==scope_built);
    put<uint8_t>(sh::gui.slot,5);
    assert(sh::restore(error) && ship_initializes==scope_built); assert(sh::release(error));
    // A changed global UI owner must not be reconstructed through stale roots.
    prepare(error); assert(sh::suppress(error)); const auto identity_built=ship_initializes;
    put(game+sh::kUiPointer,ui+16);
    assert(!sh::restore(error) && ship_initializes==identity_built && sh::status().owned);
    put(game+sh::kUiPointer,ui); assert(sh::restore(error)); assert(sh::release(error));
    // A foreign registration filling a freed row must refuse reconstruction.
    prepare(error); assert(sh::suppress(error)); const auto observer_built=ship_initializes;
    put<uint32_t>(observer_memory+0x27A8,1); put<uintptr_t>(observer_memory+0x27B0,ui+16);
    assert(!sh::restore(error) && ship_initializes==observer_built && sh::status().owned);
    observer_rows(false); assert(sh::restore(error)); assert(sh::release(error));
    // A returned owned rebuild is destroyed once before a subsequent native
    // common UI initializer; it cannot overlap the game's next constructor.
    prepare(error); assert(sh::suppress(error)); hide_constructor_readback=true;
    assert(!sh::restore(error)); show_flag_page();
    const auto transition_destroyed=ship_destroys,transition_built=ship_initializes,transition_resized=ship_resizes;
    sh::init_hook(reinterpret_cast<void*>(ui));
    assert(!sh::status().owned && sh::status().retired && ship_destroys==transition_destroyed+1);
    assert(ship_initializes==transition_built && ship_resizes==transition_resized);
    assert(sh::restore(error) && sh::release(error));
    // Owned suppression retires synchronously before either common UI original.
    prepare(error); assert(sh::suppress(error)); const auto epoch=roots_epoch;
    sh::destroy_hook(reinterpret_cast<void*>(ui));
    assert(!sh::status().owned && sh::status().retired && ui_destroys==1 && roots_epoch==epoch+1);
    assert(sh::restore(error) && sh::release(error)); normal_ui_init(reinterpret_cast<void*>(ui));
    prepare(error); assert(sh::suppress(error)); const auto before_transition=ship_initializes;
    sh::init_hook(reinterpret_cast<void*>(ui));
    assert(!sh::status().owned && sh::status().retired && ship_initializes==before_transition);
    assert(sh::restore(error) && sh::release(error)); unrelated_unchanged();
    assert(created==removed && enabled==disabled);
    // Interrupted initialization is deliberately pending; no guessed destructor,
    // second constructor, shared-root forwarding or hook release is permitted.
    prepare(error); assert(sh::suppress(error)); partial_constructor=true;
    assert(!sh::restore(error)); const auto partial_built=ship_initializes,partial_destroyed=ship_destroys;
    assert(sh::status().phase==sh::Phase::InterruptedRebuild && sh::status().owned && !sh::status().gui_restore_pending);
    assert(!sh::restore(error) && ship_initializes==partial_built && ship_destroys==partial_destroyed);
    const auto forwarded=ui_destroys+ui_initializes;
    sh::destroy_hook(reinterpret_cast<void*>(ui)); sh::init_hook(reinterpret_cast<void*>(ui));
    assert(ui_destroys+ui_initializes==forwarded && sh::status().lifecycle_blocked && !sh::release(error));
#ifdef BC_NATIVE_TEST_API
    assert((BC_ship_hud_flags()&32)!=0 && std::strlen(BC_ship_hud_error())>0);
#endif
    unrelated_unchanged();
    std::cout << "PASS Ship HUD lease: disabled staging, native/identity/GUI refusal, two-hook enable rollback, suppression, all four GUI depths, exact scope restore, foreign UI, thread refusal, returned-call retries, synchronous retirement, partial-init pending; stub native only\n";
}
