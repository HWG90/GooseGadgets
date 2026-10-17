// Isolated process test: synthetic module/UI memory, no game handle or DLL load.
#include "../native/hud.cpp"
#include <cassert>
#include <iostream>

namespace {
bc::Owner owner;
bc::Owner* published{};
unsigned constructors{},destructors{},foreign_removes{},local_changes{};
bool force_ctor_readback=false;
uintptr_t hidden_ui_page{};
template<class T> void put(uintptr_t p,T v) { *reinterpret_cast<T*>(p)=v; }
void reset_roots() {
    for (const auto item:std::array<std::pair<uintptr_t,uintptr_t>,4>{{{0x820,0x258},{0x930,0x380},{0xA40,0x5D0},{0xB50,0x4A8}}})
        put(owner.ui+item.first+0xF0,owner.ui+item.second);
}
void __fastcall local_add(void* action,const uint64_t* mask) {
    assert(reinterpret_cast<uintptr_t>(action)==owner.pc+0x50 && mask[0]==8 && mask[1]==0 && mask[2]==0);
    put(owner.pc+0xFD0,bc::value<uint64_t>(owner.pc+0xFD0)|8); ++local_changes;
}
void __fastcall local_remove(void* action,const uint64_t* mask) {
    assert(reinterpret_cast<uintptr_t>(action)==owner.pc+0x50 && mask[0]==8);
    put(owner.pc+0xFD0,bc::value<uint64_t>(owner.pc+0xFD0)&~uint64_t{8}); ++local_changes;
}
void __fastcall all_remove(const uint64_t*) { ++foreign_removes; }
void __fastcall native_active(void* object,uint8_t b) { put(reinterpret_cast<uintptr_t>(object),b); }
void __fastcall native_destroy(void* object) {
    assert(reinterpret_cast<uintptr_t>(object)==owner.ui);
    assert(bc::value<uint32_t>(owner.state+0xAC21C)==3);
    if (bc::value<uint8_t>(owner.ui+bc::hud::kMissionInitialized)) {
        assert(bc::hud::bytes_equal(owner.game+0x12F1909,bc::hud::destroy_sites[0].after));
        const uint64_t mask[3]={8,0,0}; bc::hud::remove_hook(mask);
    }
    put<uint8_t>(owner.ui+bc::hud::kUiInitialized,0);
    put<uint8_t>(owner.ui+bc::hud::kMissionInitialized,0);
    put<uint8_t>(owner.ui+bc::hud::kShipInitialized,0);
    ++destructors;
}
void __fastcall native_init(void* object) {
    assert(reinterpret_cast<uintptr_t>(object)==owner.ui);
    assert(bc::value<uint32_t>(owner.state+0xAC21C)==3);
    // Model the audited native construction scope, including signed empty -1.
    // The slot at oldDepth+1 must precede the depth DWORD; pop restores depth.
    const auto gui=bc::value<uintptr_t>(owner.game+0x347CE90);
    const auto old_depth=bc::value<int32_t>(gui+0x2C5BC);
    assert(old_depth>=-1 && old_depth<=2);
    const int32_t depth=old_depth+1;
    put<int32_t>(gui+0x2C5BC,depth);
    put<uint8_t>(gui+0x2C5B8+depth,5);
    assert(bc::value<int32_t>(gui+0x2C5BC)==depth);
    assert(bc::value<uint8_t>(gui+0x2C5B8+depth)==5);
    const bool projected=bc::hud::bytes_equal(owner.game+0x12F0BEF,bc::hud::init_sites[0].after);
    put<uint8_t>(owner.ui+bc::hud::kUiInitialized,1);
    put<uint8_t>(owner.ui+bc::hud::kMissionInitialized,projected?1:0);
    put<uint8_t>(owner.ui+bc::hud::kShipInitialized,projected?0:1);
    reset_roots();
    if (projected) {
        for (const auto& s:bc::hud::init_sites) assert(bc::hud::bytes_equal(owner.game+s.rva,s.after));
        bc::hud::active_hook(object,1); // A ctor callback must remain local.
    }
    ++constructors;
    put<int32_t>(gui+0x2C5BC,bc::value<int32_t>(gui+0x2C5BC)-1);
    assert(bc::value<int32_t>(gui+0x2C5BC)==old_depth);
    if (force_ctor_readback) {
        DWORD ignored{}; hidden_ui_page=(owner.ui+bc::hud::kMissionInitialized)&~uintptr_t{4095};
        assert(VirtualProtect(reinterpret_cast<void*>(hidden_ui_page),4096,PAGE_NOACCESS,&ignored));
        force_ctor_readback=false;
    }
}
void __fastcall native_visible(void*,float,uint8_t) {
    for (const auto& s:bc::hud::visible_sites) assert(bc::hud::bytes_equal(owner.game+s.rva,s.after));
}
void __fastcall native_data(void* object,float,uint32_t player_id) {
    assert(reinterpret_cast<uintptr_t>(object)==owner.ui+bc::hud::kMission);
    assert(player_id==73 && player_id!=owner.avatar);
    assert(bc::hud::bytes_equal(owner.game+0x12EBE3A,bc::hud::data_sites[0].after));
}
void __fastcall native_frame(void* opaque,float dt,uint32_t arg) {
    assert(opaque==reinterpret_cast<void*>(0x123450) && arg==73);
    for (const auto& s:bc::hud::frame_sites) assert(bc::hud::bytes_equal(owner.game+s.rva,s.after));
    bc::hud::visible_hook(reinterpret_cast<void*>(owner.ui),dt,1);
    bc::hud::data_hook(reinterpret_cast<void*>(owner.ui+bc::hud::kMission),dt,arg);
}
void thunk(uintptr_t p,void* callback) {
    const uint8_t first[2]={0x48,0xB8}, last[2]={0xFF,0xE0};
    std::memcpy(reinterpret_cast<void*>(p),first,2);
    put(p+2,reinterpret_cast<uintptr_t>(callback));
    std::memcpy(reinterpret_cast<void*>(p+10),last,2);
}
uintptr_t alloc(size_t n,DWORD protect=PAGE_READWRITE) {
    const auto p=reinterpret_cast<uintptr_t>(VirtualAlloc(nullptr,n,MEM_RESERVE|MEM_COMMIT,protect)); assert(p); return p;
}
void make_fixture() {
    owner.game=alloc(0x3800000,PAGE_EXECUTE_READWRITE);
    owner.state=alloc(0xAD000); owner.ui=alloc(0x500000);
    owner.pm=alloc(0x1000); owner.pc=alloc(0x2000); owner.descriptor=alloc(0x1000);
    owner.avatar=123; owner.game_thread=GetCurrentThreadId(); owner.enabled=1; published=&owner;
    put(owner.game+0x346D538,owner.ui); put(owner.game+0x3326D20,owner.pm);
    put<uint32_t>(owner.state+0xAC21C,3); put<uint32_t>(owner.descriptor+8,owner.avatar);
    put<uint8_t>(owner.descriptor+0x14,1); put<uint64_t>(owner.pc+0xFD0,0x202);
    put<uint8_t>(owner.ui,1); put<uint8_t>(owner.ui+bc::hud::kUiInitialized,1);
    put<uint8_t>(owner.ui+bc::hud::kShipInitialized,1); reset_roots();
    for (auto set:bc::hud::all_sites) for (const auto& s:*set)
        std::memcpy(reinterpret_cast<void*>(owner.game+s.rva),s.before.data(),s.before.size());
    for (const uintptr_t rva:{0x347CE90ULL,0x3326E68ULL,0x3326308ULL,0x347CE30ULL,0x346D530ULL})
        put(owner.game+rva,alloc(rva==0x347CE90?0x30000:0x5000));
    put<int32_t>(bc::value<uintptr_t>(owner.game+0x347CE90)+0x2C5BC,-1);
    const auto api=bc::value<uintptr_t>(owner.game+0x3326308);
    const auto ui_api=alloc(0x1000),app_api=alloc(0x1000);
    put(api+0xD0,ui_api); put(api+0xC0,app_api);
    put(app_api+0x28,owner.game+0x1000);
    for (const uintptr_t slot:{0x118ULL,0x180ULL,0x2B8ULL}) put(ui_api+slot,owner.game+0x1000);
    thunk(owner.game+0xAA0AA0,reinterpret_cast<void*>(local_add));
    thunk(owner.game+0xAA0BB0,reinterpret_cast<void*>(local_remove));
}
void original_sites() {
    for (auto set:bc::hud::all_sites) for (const auto& s:*set) {
        assert(s.references==0 && !s.pending);
        assert(bc::hud::bytes_equal(owner.game+s.rva,s.before));
    }
    assert(bc::value<uint32_t>(owner.state+0xAC21C)==3);
}
}
namespace bc {
Owner* current() { return published; }
bool active(const Owner* o) { return o==published && o->enabled && value<uint32_t>(o->state+0xAC21C)==3; }
bool fingerprint(uintptr_t,const char*) { return true; } // ABI endpoints are fixture thunks.
bool stage_hook(uintptr_t p,void*,void** original,const char*,std::string&) {
    void* callback{};
    switch (p-owner.game) {
    case 0x12F0920: callback=reinterpret_cast<void*>(native_init); break;
    case 0x12F1540: callback=reinterpret_cast<void*>(native_destroy); break;
    case 0x12F3C70: callback=reinterpret_cast<void*>(native_visible); break;
    case 0x12F53A0: callback=reinterpret_cast<void*>(native_frame); break;
    case 0x12F1BA0: callback=reinterpret_cast<void*>(native_active); break;
    case 0x12EBC50: callback=reinterpret_cast<void*>(native_data); break;
    case 0xAA0E50: callback=reinterpret_cast<void*>(all_remove); break;
    default: assert(false);
    }
    *original=callback; return true;
}
}
int main() {
    make_fixture(); std::string error;
    assert(bc::hud::prepare(&owner,error)); original_sites();
    assert(constructors==0 && destructors==0 && local_changes==0);
    const auto gui=bc::value<uintptr_t>(owner.game+0x347CE90);
    put<uintptr_t>(owner.game+0x347CE90,0);
    assert(!bc::hud::start(&owner,error)); assert(constructors==0 && destructors==0); original_sites();
    put(owner.game+0x347CE90,gui);
    for (const int32_t depth:{-2,3}) {
        put<int32_t>(gui+0x2C5BC,depth);
        assert(!bc::hud::start(&owner,error));
        assert(constructors==0 && destructors==0 && local_changes==0);
        assert(bc::value<int32_t>(gui+0x2C5BC)==depth); original_sites();
    }
    for (const int32_t depth:{-1,0,1,2}) {
        put<int32_t>(gui+0x2C5BC,depth);
        assert(bc::hud::prerequisites(&owner,error));
        assert(bc::value<int32_t>(gui+0x2C5BC)==depth);
        assert(constructors==0 && destructors==0 && local_changes==0); original_sites();
    }
    put<int32_t>(gui+0x2C5BC,-1);
    const auto observer=bc::value<uintptr_t>(owner.game+0x3326E68);
    put<uint32_t>(observer+0x2D68,2);
    assert(!bc::hud::start(&owner,error)); assert(constructors==0 && destructors==0 && local_changes==0);
    assert(bc::value<uint8_t>(owner.ui+bc::hud::kShipInitialized)==1); original_sites();
    put<uint32_t>(observer+0x2D68,0);
    assert(bc::hud::start(&owner,error)); original_sites();
    assert(bc::value<int32_t>(gui+0x2C5BC)==-1);
    assert(bc::value<uint8_t>(gui+0x2C5B8)==5);
    assert(bc::value<uint8_t>(owner.ui+bc::hud::kMissionInitialized)==1 && foreign_removes==0);
    bc::hud::frame_hook(reinterpret_cast<void*>(0x123450),0.016f,73); original_sites();
    assert(bc::hud::tick(&owner,0.016f,error));
    owner.enabled=0; assert(bc::hud::stop(&owner,error)); original_sites();
    assert(bc::value<uint8_t>(owner.ui+bc::hud::kShipInitialized)==1);
    assert((bc::value<uint64_t>(owner.pc+0xFD0)&8)==0 && foreign_removes==0);
    assert(bc::hud::release(error)); assert(bc::hud::prepare(&owner,error)); owner.enabled=1;
    assert(bc::hud::start(&owner,error));
    bc::hud::destroy_hook(reinterpret_cast<void*>(owner.ui)); original_sites();
    const auto calls=destructors; owner.enabled=0; assert(bc::hud::stop(&owner,error));
    assert(destructors==calls); // Native pre-reinit teardown already acknowledged.
    native_init(reinterpret_cast<void*>(owner.ui)); owner.enabled=1;
    force_ctor_readback=true;
    assert(!bc::hud::start(&owner,error)); owner.enabled=0;
    assert(!bc::hud::stop(&owner,error)); // Retain constructor-return readback phase.
    DWORD ignored{}; assert(VirtualProtect(reinterpret_cast<void*>(hidden_ui_page),4096,PAGE_READWRITE,&ignored));
    assert(bc::hud::stop(&owner,error)); original_sites();
    assert(bc::value<uint8_t>(owner.ui+bc::hud::kShipInitialized)==1 && foreign_removes==0);
    owner.enabled=1; assert(bc::hud::start(&owner,error));
    put<uint8_t>(owner.descriptor+0x14,0); const auto changes=local_changes;
    owner.enabled=0; assert(bc::hud::stop(&owner,error)); assert(local_changes==changes);
    assert(foreign_removes==0); original_sites(); assert(bc::hud::release(error));
    // Exercise each nonempty allowed scope, especially slot3 adjacent to depth.
    put<uint8_t>(owner.descriptor+0x14,1);
    for (const int32_t depth:{0,1,2}) {
        put<int32_t>(gui+0x2C5BC,depth);
        owner.enabled=1; assert(bc::hud::prepare(&owner,error));
        assert(bc::hud::start(&owner,error)); original_sites();
        assert(bc::value<int32_t>(gui+0x2C5BC)==depth);
        assert(bc::value<uint8_t>(gui+0x2C5B9+depth)==5);
        owner.enabled=0; assert(bc::hud::stop(&owner,error)); original_sites();
        assert(bc::value<int32_t>(gui+0x2C5BC)==depth);
        assert(bc::hud::release(error));
    }
    std::cout << "PASS native HUD: inactive, signed empty GUI scope, push bounds refusal, full lifecycle, nested UI projection, local contexts, pre-reinit retirement, retryable readback, actor retirement, restaging\n";
}
