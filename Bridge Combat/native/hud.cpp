#include "hud.h"
#include <array>
#include <cmath>
#include <cstring>
#include <mutex>
#include <vector>

namespace bc::hud {
namespace {
constexpr uintptr_t kUi = 0x346D538, kPm = 0x3326D20;
constexpr uintptr_t kMission = 0x24E340, kShip = 0x46D900;
constexpr uintptr_t kUiInitialized = 0x24E334;
constexpr uintptr_t kMissionInitialized = kMission + 0x21F5B0;
constexpr uintptr_t kShipInitialized = kShip + 0x89778;
using VoidUi = void(__fastcall*)(void*);
using VisibleTick = void(__fastcall*)(void*, float, uint8_t);
using FrameTick = void(__fastcall*)(void*, float, uint32_t);
using ActiveUi = void(__fastcall*)(void*, uint8_t);
using ContextAll = void(__fastcall*)(const uint64_t*);
using ContextLocal = void(__fastcall*)(void*, const uint64_t*);
VoidUi original_init{}, original_destroy{};
VisibleTick original_visible{};
FrameTick original_frame{}, original_mission_data{};
ActiveUi original_active{};
ContextAll original_remove{};
std::recursive_mutex mutex;
Owner* lease{};
enum class Mode { None, Mission, Retired, Fault };
Mode mode = Mode::None;
bool prepared{}, was_active{}, had_role3{};
bool mission_owned{}, empty_ui{}, native_retired{};
enum class Returned { None, Destroy, MissionInit, ShipInit };
Returned returned=Returned::None;
bool ship_rebuilt{};
std::string fault;
thread_local Owner* role_scope{};
thread_local Owner* building_scope{};

bool ui_identity(const Owner* o) {
    return o && current() == o && value<uintptr_t>(o->game+kUi) == o->ui;
}
bool actor_identity(const Owner* o) {
    return ui_identity(o) && value<uintptr_t>(o->game+kPm) == o->pm &&
        value<uint32_t>(o->descriptor+8) == o->avatar &&
        (value<uint8_t>(o->descriptor+0x14) & 1) != 0;
}
bool game_thread(const Owner* o) { return o && GetCurrentThreadId() == o->game_thread; }
bool executable_pointer(uintptr_t p) {
    MEMORY_BASIC_INFORMATION info{};
    if (!p || !VirtualQuery(reinterpret_cast<void*>(p),&info,sizeof(info)) || info.State!=MEM_COMMIT ||
        (info.Protect&(PAGE_GUARD|PAGE_NOACCESS))) return false;
    return (info.Protect&(PAGE_EXECUTE|PAGE_EXECUTE_READ|PAGE_EXECUTE_READWRITE|PAGE_EXECUTE_WRITECOPY))!=0;
}
bool prerequisites(Owner* o,std::string& error) {
    // These client UI services already exist on the bridge. No mission director,
    // mission timer or objective service is invented by the selector projection.
    for (const uintptr_t rva:{0x347CE90ULL,0x3326E68ULL,0x3326308ULL,0x347CE30ULL,0x346D530ULL}) {
        uintptr_t pointer{}; uint8_t probe{};
        if (!read(o->game+rva,pointer) || !pointer || !read(pointer,probe)) {
            error="native HUD client service unavailable before teardown"; return false;
        }
    }
    const auto gui=value<uintptr_t>(o->game+0x347CE90);
    int32_t nesting{};
    // Empty is signed -1. Native init increments depth, then stores context5
    // at 2C5B9+oldDepth: -1 selects slot0 at 2C5B8; 2 selects slot3.
    // At oldDepth3 the byte overlaps the depth DWORD at 2C5BC.
    // The original UI constructor owns this push/pop; do not push it twice.
    if (!read(gui+0x2C5BC,nesting) || nesting<-1 || nesting>2) {
        error="native GUI construction stack is unavailable or unexpectedly nested"; return false;
    }
    const auto observer=value<uintptr_t>(o->game+0x3326E68);
    for (const auto bound:std::array<std::pair<uintptr_t,uint32_t>,4>{{{0x2AA0,2},{0x2AC8,39},{0x2D40,2},{0x2D68,2}}}) {
        uint32_t count{};
        if (!read(observer+bound.first,count) || count>=bound.second) {
            error="native MissionHUD observer capacity unavailable"; return false;
        }
    }
    const auto api=value<uintptr_t>(o->game+0x3326308);
    const auto ui_api=value<uintptr_t>(api+0xD0), app_api=value<uintptr_t>(api+0xC0);
    if (!ui_api || !app_api || !executable_pointer(value<uintptr_t>(app_api+0x28))) {
        error="native HUD application API unavailable"; return false;
    }
    for (const uintptr_t slot:{0x118ULL,0x180ULL,0x2B8ULL}) if (!executable_pointer(value<uintptr_t>(ui_api+slot))) {
        error="native HUD renderer API unavailable"; return false;
    }
    for (const auto root:std::array<std::pair<uintptr_t,uintptr_t>,4>{{{0x820,0x258},{0x930,0x380},{0xA40,0x5D0},{0xB50,0x4A8}}}) {
        uintptr_t parent{}; uint32_t flags{};
        if (!read(o->ui+root.first+0xF0,parent) || parent!=o->ui+root.second || !read(parent,flags)) {
            error="native HUD root ownership unavailable"; return false;
        }
    }
    return true;
}
bool owned_ui(void* object) {
    return mission_owned && ui_identity(lease) && game_thread(lease) &&
        reinterpret_cast<uintptr_t>(object) == lease->ui;
}
bool store8(uintptr_t p, uint8_t v) {
    __try { *reinterpret_cast<uint8_t*>(p)=v; return *reinterpret_cast<uint8_t*>(p)==v; }
    __except(EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool bytes_equal(uintptr_t p, const std::vector<uint8_t>& bytes) {
    __try { return std::memcmp(reinterpret_cast<void*>(p),bytes.data(),bytes.size())==0; }
    __except(EXCEPTION_EXECUTE_HANDLER) { return false; }
}
struct ProtectionJournal {
    uintptr_t address{}; size_t size{}; DWORD original{}; bool pending{};
};
bool restore_protection(ProtectionJournal& journal) {
    if (!journal.pending) return true;
    DWORD ignored{};
    if (!VirtualProtect(reinterpret_cast<void*>(journal.address),journal.size,journal.original,&ignored)) return false;
    journal.pending=false; return true;
}
bool code_write(uintptr_t p, const std::vector<uint8_t>& bytes,ProtectionJournal& journal) {
    DWORD old{};
    if (!VirtualProtect(reinterpret_cast<void*>(p),bytes.size(),PAGE_EXECUTE_READWRITE,&old)) return false;
    if (!journal.pending) journal={p,bytes.size(),old,true};
    bool copied{};
    __try { std::memcpy(reinterpret_cast<void*>(p),bytes.data(),bytes.size()); copied=true; }
    __except(EXCEPTION_EXECUTE_HANDLER) { copied=false; }
    const bool protect=restore_protection(journal);
    const bool flush=FlushInstructionCache(GetCurrentProcess(),reinterpret_cast<void*>(p),bytes.size())!=0;
    return copied && protect && flush && bytes_equal(p,bytes);
}
std::vector<uint8_t> unhex(const char* s) {
    std::vector<uint8_t> out;
    const auto digit=[](char c) { return c>='0'&&c<='9'?c-'0':c-'a'+10; };
    while (*s) { out.push_back(static_cast<uint8_t>((digit(s[0])<<4)|digit(s[1]))); s+=2; }
    return out;
}
struct Site {
    uintptr_t rva;
    std::vector<uint8_t> before, after;
    unsigned references{};
    bool pending{};
    ProtectionJournal protection;
};
// The projections below alter only the audited UI selector instructions. They
// are applied while guarded original UI calls hold mutex, then restored before
// returning. GameState.Scene is never written. Every function containing a
// projected site has an entry hook, which serializes other callers as well.
std::vector<Site> init_sites = {
    {0x12F0BEF,unhex("418b821cc20a00"),unhex("b8040000009090")},
    {0x12F0F9C,unhex("7557"),unhex("9090")},
    {0x12F10A0,unhex("755f"),unhex("9090")},
    {0x12F11A0,unhex("755d"),unhex("9090")},
    {0x12F126A,unhex("7552"),unhex("9090")},
    {0x12F1404,unhex("7523"),unhex("eb23")},
    {0x12F14CC,unhex("8b881cc20a00"),unhex("b90400000090")}
};
std::vector<Site> destroy_sites = {
    {0x12F1909,unhex("8b881cc20a00"),unhex("b90400000090")}
};
std::vector<Site> visible_sites = {
    {0x12F3CB5,unhex("448ba61cc20a00"),unhex("41bc0400000090")},
    {0x12F42B5,unhex("418b831cc20a00"),unhex("b8040000009090")}
};
std::vector<Site> frame_sites = {
    {0x12F5738,unhex("756c"),unhex("eb6c")},
    {0x12F5884,unhex("8b881cc20a00"),unhex("b90400000090")},
    {0x12F5A38,unhex("8b881cc20a00"),unhex("b90400000090")},
    {0x12F5B47,unhex("0f8543feffff"),unhex("e944feffff90")}
};
std::vector<Site> data_sites = {
    {0x12EBE3A,unhex("757f"),unhex("9090")}
};
std::array<std::vector<Site>*,5> all_sites = {
    &init_sites,&destroy_sites,&visible_sites,&frame_sites,&data_sites
};
bool restore_sites(Owner* o) {
    bool ok=true;
    for (auto set:all_sites) for (auto& s:*set) {
        if (s.references) continue;
        if (!s.pending) { if (!restore_protection(s.protection)) ok=false; continue; }
        const uintptr_t p=o->game+s.rva;
        if (bytes_equal(p,s.before)) {
            if (!restore_protection(s.protection)) { ok=false; continue; }
            s.pending=false; continue;
        }
        if (!bytes_equal(p,s.after) || !code_write(p,s.before,s.protection)) { ok=false; continue; }
        s.pending=false;
    }
    return ok;
}
class Projection {
    Owner* owner;
    std::vector<Site>* sites;
    std::vector<Site*> entered;
public:
    bool ready{true};
    Projection(Owner* o,std::vector<Site>& set):owner(o),sites(&set) {
        entered.reserve(set.size()); // Allocation must precede the first code write.
        for (auto& s:set) {
            const uintptr_t p=o->game+s.rva;
            if (!s.references) {
                if (!bytes_equal(p,s.before)) { ready=false; break; }
                // Ownership starts before the write, including failed readback.
                s.pending=true;
                if (!code_write(p,s.after,s.protection)) { ready=false; break; }
            } else if (!bytes_equal(p,s.after)) { ready=false; break; }
            ++s.references; entered.push_back(&s);
        }
    }
    ~Projection() {
        for (auto it=entered.rbegin();it!=entered.rend();++it) --(*it)->references;
        if (!restore_sites(owner)) { fault="UI selector restore pending or changed by another owner"; mode=Mode::Fault; }
    }
    Projection(const Projection&)=delete;
    Projection& operator=(const Projection&)=delete;
};
class RoleScope {
    Owner* old;
public:
    explicit RoleScope(Owner* o):old(role_scope) { role_scope=o; }
    ~RoleScope() { role_scope=old; }
};
class BuildScope {
    Owner* old;
public:
    explicit BuildScope(Owner* o):old(building_scope) { building_scope=o; }
    ~BuildScope() { building_scope=old; }
};
bool reconcile_returned(Owner* o) {
    if (returned==Returned::None) return true;
    uint8_t initialized{},mission{},ship{};
    if (!read(o->ui+kUiInitialized,initialized) || !read(o->ui+kMissionInitialized,mission) ||
        !read(o->ui+kShipInitialized,ship)) return false;
    if (returned==Returned::Destroy && initialized==0 && mission==0 && ship==0) {
        mission_owned=false; empty_ui=true; returned=Returned::None; return true;
    }
    if (returned==Returned::MissionInit && initialized==1 && mission==1 && ship==0) {
        mission_owned=true; empty_ui=false; returned=Returned::None; return true;
    }
    if (returned==Returned::ShipInit && initialized==1 && mission==0 && ship==1) {
        mission_owned=false; empty_ui=false; ship_rebuilt=true; returned=Returned::None; return true;
    }
    return false;
}
bool context_available(Owner* o,bool add) {
    return fingerprint(o->game+(add?0xAA0AA0:0xAA0BB0),add?
        "48895c2408574883ec20488b1a488bfa4c8b89900f00004c":
        "48895c2418574883ec20488bb9800f00004c8bc94c8b5a10");
}
bool change_role3(Owner* o,bool add) {
    if (!actor_identity(o)) return true;
    if (!context_available(o,add)) { fault="local HUD context ABI changed"; mode=Mode::Fault; return false; }
    alignas(16) const uint64_t mask[3]={8,0,0};
    const auto f=reinterpret_cast<ContextLocal>(o->game+(add?0xAA0AA0:0xAA0BB0));
    f(reinterpret_cast<void*>(o->pc+0x50),mask);
    uint64_t roles{};
    if (!read(o->pc+0xFD0,roles) || ((roles&8)!=0)!=add) {
        fault="local HUD context readback pending"; mode=Mode::Fault; return false;
    }
    return true;
}
void __fastcall remove_hook(const uint64_t* mask) {
    // Unrelated context work must not wait for an entire HUD/render call.
    if (!role_scope) { original_remove(mask); return; }
    std::lock_guard<std::recursive_mutex> lock(mutex);
    uint64_t a{},b{},c{};
    if (role_scope && game_thread(role_scope) && read(reinterpret_cast<uintptr_t>(mask),a) &&
        read(reinterpret_cast<uintptr_t>(mask)+8,b) && read(reinterpret_cast<uintptr_t>(mask)+16,c) &&
        a==8 && b==0 && c==0) {
        // Even if the actor retired, suppress this owned HUD's global removal.
        // The actor lifecycle owns its retirement; foreign actors are untouched.
        change_role3(role_scope,false); return;
    }
    original_remove(mask);
}
void local_active(Owner* o,bool enabled) {
    const uint8_t desired=enabled?1:0;
    const bool changed=value<uint8_t>(o->ui+kMission+0x58)!=desired;
    if (changed && actor_identity(o) && !context_available(o,enabled)) {
        fault="local HUD context ABI changed before activation"; mode=Mode::Fault; return;
    }
    if (!store8(o->ui,desired) || !store8(o->ui+kMission+0x58,desired)) {
        fault="owned HUD active byte write failed"; mode=Mode::Fault; return;
    }
    if (changed) change_role3(o,enabled);
}
void __fastcall active_hook(void* object,uint8_t enabled) {
    std::lock_guard<std::recursive_mutex> lock(mutex);
    if (building_scope && ui_identity(building_scope) && game_thread(building_scope) &&
        reinterpret_cast<uintptr_t>(object)==building_scope->ui) {
        local_active(building_scope,enabled!=0); return;
    }
    if (mode==Mode::Fault && owned_ui(object)) return;
    if (owned_ui(object)) { local_active(lease,enabled!=0); return; }
    original_active(object,enabled);
}
bool destroy_owned(Owner* o) {
    Projection projection(o,destroy_sites);
    if (!projection.ready) { fault="HUD destructor selector fingerprint changed"; mode=Mode::Fault; return false; }
    RoleScope roles(o);
    original_destroy(reinterpret_cast<void*>(o->ui));
    returned=Returned::Destroy;
    return reconcile_returned(o);
}
void __fastcall destroy_hook(void* object) {
    std::lock_guard<std::recursive_mutex> lock(mutex);
    if (owned_ui(object)) {
        Owner* retiring=lease;
        if (!reconcile_returned(retiring)) { fault="HUD native teardown readback pending"; mode=Mode::Fault; return; }
        if (!restore_sites(retiring)) { fault="HUD selector restoration pending before native teardown"; mode=Mode::Fault; return; }
        if (!destroy_owned(retiring)) { fault="native HUD teardown incomplete"; mode=Mode::Fault; return; }
        // This happens before the game's subsequent native constructor. It is
        // deliberately not a Lua/update poll and does not rebuild the old scene.
        native_retired=true;
        if (mode!=Mode::Fault) mode=Mode::Retired;
        return;
    }
    original_destroy(object);
}
void __fastcall init_hook(void* object) {
    std::lock_guard<std::recursive_mutex> lock(mutex);
    if (owned_ui(object)) {
        if (!reconcile_returned(lease)) { fault="HUD native reinit readback pending"; mode=Mode::Fault; return; }
        if (!restore_sites(lease)) { fault="HUD selector restoration pending before reinit"; mode=Mode::Fault; return; }
        if (!destroy_owned(lease)) { fault="HUD cleanup before native reinit incomplete"; mode=Mode::Fault; return; }
        native_retired=true;
        if (mode!=Mode::Fault) mode=Mode::Retired;
    }
    if (mode==Mode::Fault && lease && ui_identity(lease) && reinterpret_cast<uintptr_t>(object)==lease->ui) return;
    if (lease && native_retired) empty_ui=false; // The game owns the next construction.
    original_init(object);
}
void __fastcall visible_hook(void* object,float dt,uint8_t allowed) {
    std::lock_guard<std::recursive_mutex> lock(mutex);
    if (mode==Mode::Fault && owned_ui(object)) return;
    if (owned_ui(object)) {
        Projection projection(lease,visible_sites);
        if (!projection.ready) { fault="HUD tick selector changed"; mode=Mode::Fault; return; }
        original_visible(object,dt,allowed); return;
    }
    original_visible(object,dt,allowed);
}
void __fastcall frame_hook(void* opaque,float dt,uint32_t opaque_r8) {
    std::lock_guard<std::recursive_mutex> lock(mutex);
    if (mode==Mode::Fault && lease && ui_identity(lease) && game_thread(lease)) return;
    if (mode==Mode::Mission && ui_identity(lease) && game_thread(lease)) {
        Projection projection(lease,frame_sites);
        if (!projection.ready) { fault="HUD frame selector changed"; mode=Mode::Fault; return; }
        original_frame(opaque,dt,opaque_r8); return;
    }
    original_frame(opaque,dt,opaque_r8);
}
void __fastcall data_hook(void* object,float dt,uint32_t player_id) {
    std::lock_guard<std::recursive_mutex> lock(mutex);
    if (mode==Mode::Fault && lease && ui_identity(lease) && reinterpret_cast<uintptr_t>(object)==lease->ui+kMission) return;
    if (mode==Mode::Mission && ui_identity(lease) && game_thread(lease) &&
        reinterpret_cast<uintptr_t>(object)==lease->ui+kMission) {
        Projection projection(lease,data_sites);
        if (!projection.ready) { fault="HUD mission subset selector changed"; mode=Mode::Fault; return; }
        original_mission_data(object,dt,player_id); return;
    }
    original_mission_data(object,dt,player_id);
}
bool hooks(Owner* o,std::string& error) {
    const struct Hook { uintptr_t rva; void* callback; void** original; const char* expected; } list[]={
        {0x12F0920,reinterpret_cast<void*>(init_hook),reinterpret_cast<void**>(&original_init),"48895c241048896c24184889742420574154415541564157"},
        {0x12F1540,reinterpret_cast<void*>(destroy_hook),reinterpret_cast<void**>(&original_destroy),"40554883ec3080b934e3240000488be90f84590400004889"},
        {0x12F3C70,reinterpret_cast<void*>(visible_hook),reinterpret_cast<void**>(&original_visible),"488bc44488401853574881ec980000000f2978a8488bf944"},
        {0x12F53A0,reinterpret_cast<void*>(frame_hook),reinterpret_cast<void**>(&original_frame),"48894c24085355565741564883ec50488b2d82811702418b"},
        {0x12F1BA0,reinterpret_cast<void*>(active_hook),reinterpret_cast<void**>(&original_active),"48895c2410574883ec40488b055fa434014833c448894424"},
        {0x12EBC50,reinterpret_cast<void*>(data_hook),reinterpret_cast<void**>(&original_mission_data),"4c8bdc55534156498dabf8feffff4881ecf0010000410f29"},
        {0xAA0E50,reinterpret_cast<void*>(remove_hook),reinterpret_cast<void**>(&original_remove),"4053574883ec284c8b05c25e880233db488bf9413958700f"}
    };
    for (const auto& h:list) if (!stage_hook(o->game+h.rva,h.callback,h.original,h.expected,error)) return false;
    return true;
}
} // namespace

bool prepare(Owner* o,std::string& error) {
    std::lock_guard<std::recursive_mutex> lock(mutex);
    if (prepared) return true;
    if (!o || !fingerprint(o->game+0xAA0AA0,"48895c2408574883ec20488b1a488bfa4c8b89900f00004c") ||
        !fingerprint(o->game+0xAA0BB0,"48895c2418574883ec20488bb9800f00004c8bc94c8b5a10")) {
        error="unsupported native local-context ABI"; return false;
    }
    for (auto set:all_sites) for (const auto& s:*set) if (!bytes_equal(o->game+s.rva,s.before)) {
        error="unsupported HUD selector fingerprint"; return false;
    }
    prepared=hooks(o,error); return prepared;
}
bool start(Owner* o,std::string& error) {
    std::lock_guard<std::recursive_mutex> lock(mutex);
    if (!prepared || !active(o) || !game_thread(o) || !ui_identity(o)) { error="HUD start identity/thread refused"; return false; }
    if (mode==Mode::Mission && lease==o) return true;
    if (mode==Mode::Fault) { error=fault; return false; }
    if (mode==Mode::Mission || value<uint8_t>(o->ui+kUiInitialized)!=1 ||
        value<uint8_t>(o->ui+kShipInitialized)!=1 || value<uint8_t>(o->ui+kMissionInitialized)!=0) {
        error="HUD is not an exclusive initialized ship presentation"; return false;
    }
    if (!prerequisites(o,error)) return false;
    lease=o;
    uint8_t original_active_byte{}; uint64_t original_role{};
    if (!read(o->ui,original_active_byte) || !read(o->pc+0xFD0,original_role)) {
        lease=nullptr; error="HUD activation snapshot unavailable"; return false;
    }
    was_active=original_active_byte!=0; had_role3=(original_role&8)!=0;
    native_retired=false; mission_owned=false; empty_ui=false; ship_rebuilt=false; returned=Returned::None;
    RoleScope roles(o);
    original_destroy(reinterpret_cast<void*>(o->ui));
    returned=Returned::Destroy;
    if (!reconcile_returned(o)) {
        mode=Mode::Fault; fault=error="ship HUD teardown incomplete"; return false;
    }
    empty_ui=true;
    {
        Projection projection(o,init_sites);
        if (!projection.ready) { mode=Mode::Fault; fault=error="mission HUD selector preparation failed"; return false; }
        empty_ui=false; // Partial native construction cannot be guessed away.
        BuildScope build(o);
        original_init(reinterpret_cast<void*>(o->ui));
        returned=Returned::MissionInit;
    }
    const bool constructed=reconcile_returned(o);
    if (mode==Mode::Fault) { error=fault; return false; }
    if (!constructed || !mission_owned) {
        mode=Mode::Fault; fault=error="native mission HUD construction incomplete"; return false;
    }
    mode=Mode::Mission;
    local_active(o,true);
    if (mode==Mode::Fault) { error=fault; return false; }
    return true;
}
bool stop(Owner* o,std::string& error) {
    std::lock_guard<std::recursive_mutex> lock(mutex);
    if (!lease || lease!=o) return true;
    if (!game_thread(o)) { error="HUD cleanup requires game thread"; return false; }
    if (!restore_sites(o)) { error="HUD selector cleanup pending"; return false; }
    if (ui_identity(o) && !reconcile_returned(o)) { error="native HUD lifecycle readback pending"; return false; }
    if (native_retired || !ui_identity(o)) {
        lease=nullptr; mission_owned=false; empty_ui=false; mode=Mode::None; fault.clear(); return true;
    }
    if (mode==Mode::Fault && !mission_owned && !empty_ui && !ship_rebuilt) { error=fault; return false; }
    if (mission_owned) {
        if (!destroy_owned(o)) { mode=Mode::Fault; fault=error="mission HUD cleanup incomplete"; return false; }
        if (!restore_sites(o)) { error="HUD destructor selector cleanup pending"; return false; }
    }
    if (empty_ui) {
        // A completed destructor is journaled independently of code restoration.
        // A failed selector restore can therefore be retried without a second
        // object destruction or guessing that partial construction was complete.
        if (value<uint32_t>(o->state+0xAC21C)==3) {
            mode=Mode::Retired; empty_ui=false;
            original_init(reinterpret_cast<void*>(o->ui));
            returned=Returned::ShipInit;
            if (!reconcile_returned(o)) {
                mode=Mode::Fault; fault=error="native ship HUD reconstruction incomplete"; return false;
            }
        }
    }
    if (ship_rebuilt) {
        original_active(reinterpret_cast<void*>(o->ui),was_active?1:0);
        if (actor_identity(o) && !change_role3(o,had_role3)) { error=fault; return false; }
        ship_rebuilt=false;
    }
    lease=nullptr; mission_owned=false; mode=Mode::None; fault.clear(); return true;
}
bool tick(Owner* o,float dt,std::string& error) {
    std::lock_guard<std::recursive_mutex> lock(mutex);
    if (!std::isfinite(dt) || dt<0 || dt>1) { error="invalid HUD frame delta"; return false; }
    if (mode==Mode::Fault) { error=fault; return false; }
    if (lease!=o || mode!=Mode::Mission) { error="native HUD lease retired"; return false; }
    if (!ui_identity(o) || !game_thread(o)) { error="HUD lease identity/thread changed"; return false; }
    if (value<uint8_t>(o->ui+kUiInitialized)!=1 || value<uint8_t>(o->ui+kMissionInitialized)!=1 ||
        value<uint8_t>(o->ui+kShipInitialized)!=0) { error="owned HUD presentation changed"; return false; }
    return true;
}
bool release(std::string& error) {
    std::lock_guard<std::recursive_mutex> lock(mutex);
    if (lease) { error="HUD lease must acknowledge cleanup before hook removal/reset"; return false; }
    for (auto set:all_sites) for (const auto& s:*set) if (s.pending || s.references || s.protection.pending) {
        error="HUD selector ownership must restore before hook reset"; return false;
    }
    prepared=false;
    original_init=nullptr; original_destroy=nullptr; original_visible=nullptr;
    original_frame=nullptr; original_mission_data=nullptr; original_active=nullptr; original_remove=nullptr;
    mode=Mode::None; fault.clear(); returned=Returned::None;
    return true;
}
} // namespace bc::hud
