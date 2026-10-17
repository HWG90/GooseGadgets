#include "mission_hud.h"
#include "vendor/minhook/include/MinHook.h"
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>

namespace bc::mission_hud {
namespace {
constexpr uintptr_t UI=0x346D538,PM=0x3326D20,PLAYER=0x3326468,WORLD=0x346BF98,GS=0x3326340;
constexpr uintptr_t GUI=0x347CE90,OBSERVER=0x3326E68,M=0x24E340,S=0x46D900;
constexpr uintptr_t MInit=M+0x21F5B0,SInit=S+0x89778,UiInit=0x24E334;
using Void=void(__fastcall*)(void*);
using Init=void(__fastcall*)(void*,void*,void*,void*);
using Active=void(__fastcall*)(void*,uint8_t);
using Visible=void(__fastcall*)(void*,float,uint8_t);
using Data=void(__fastcall*)(void*,float,uint32_t);
using Resize=void(__fastcall*)(void*,float,float);
using ShipResize=void(__fastcall*)(void*,float);
using Context=void(__fastcall*)(const uint64_t*);
using LocalContext=void(__fastcall*)(void*,const uint64_t*);
Identity target; Io io; Phase phase=Phase::None;
struct NativeException {
    const char* operation{};uintptr_t function{},rip{},exception_address{},fault{};
    DWORD code{},flags{},parameters{};ULONG_PTR access{};bool captured{},has_fault{};
};
thread_local NativeException native_exception{};
void begin_native_call(const char* operation,uintptr_t function){native_exception={};native_exception.operation=operation;native_exception.function=function;}
// This filter only copies POD from the OS-supplied exception records. Formatting
// and std::string allocation happen after the __try function has returned.
LONG capture_native_exception(EXCEPTION_POINTERS* info){
    native_exception.captured=true;
    if(info&&info->ContextRecord)native_exception.rip=static_cast<uintptr_t>(info->ContextRecord->Rip);
    if(info&&info->ExceptionRecord){const auto* r=info->ExceptionRecord;
        native_exception.code=r->ExceptionCode;native_exception.flags=r->ExceptionFlags;
        native_exception.exception_address=reinterpret_cast<uintptr_t>(r->ExceptionAddress);
        native_exception.parameters=r->NumberParameters;
        if((r->ExceptionCode==EXCEPTION_ACCESS_VIOLATION||r->ExceptionCode==EXCEPTION_IN_PAGE_ERROR||r->ExceptionCode==EXCEPTION_GUARD_PAGE)&&r->NumberParameters>=2){native_exception.has_fault=true;native_exception.access=r->ExceptionInformation[0];native_exception.fault=r->ExceptionInformation[1];}
    }return EXCEPTION_EXECUTE_HANDLER;
}
std::string exception_details(){
    if(!native_exception.captured)return {};
    const auto& n=native_exception;char text[384]{};
    const char* region=n.rip>=target.game&&n.rip-target.game<0x3500000?"game":n.rip>=target.exe&&n.rip-target.exe<0x1A11000?"exe":"external";
    const auto offset=std::strcmp(region,"game")==0?n.rip-target.game:std::strcmp(region,"exe")==0?n.rip-target.exe:n.rip;
    std::snprintf(text,sizeof(text),"; native_exception op=%s code=0x%08lx rip=0x%llx %s+0x%llx exception_address=0x%llx",
        n.operation?n.operation:"unknown",static_cast<unsigned long>(n.code),static_cast<unsigned long long>(n.rip),region,static_cast<unsigned long long>(offset),static_cast<unsigned long long>(n.exception_address));
    std::string result=text;
    if(n.has_fault){std::snprintf(text,sizeof(text)," access=%s fault=0x%llx",n.access==0?"read":n.access==1?"write":n.access==8?"execute":"unknown",static_cast<unsigned long long>(n.fault));result+=text;}
    return result;
}
uintptr_t ui{},pm{},player{},world{},state{},descriptor{},pc{},observer{},gui_owner{};
uintptr_t registry{},generations{},units{},unit{};
uint32_t reference{},local_unit{};
std::array<uint8_t,16> actor_bytes{};
bool prepared{},owned{},widgets{},active{},role_owned{},retired{},stopping{},blocked{};
uint8_t old_ship_active{};
std::string pending_error;
std::recursive_mutex mutex;
Void original_ui_init{},original_ui_destroy{},ship_destroy{},mission_destroy{};
Init ship_initialize{},mission_initialize{};
Active ship_active{},mission_active{};
Visible mission_visible{}; Data mission_data{}; Resize mission_resize{}; ShipResize ship_resize{};
Context original_remove{}; LocalContext local_remove{};
thread_local bool teardown_scope{};
bool scope_failed{},unexpected_scope_mask{};
// Only the review transaction may start a preparation without lifecycle hooks.
bool probe_nohooks{},probe_inflight{},probe_unacknowledged{};
#ifdef BC_NATIVE_TEST_API
uint32_t probe_receipts{};
#ifdef BC_MISSION_HUD_FIXTURE
void (*fixture_bind)(){};
#endif
#endif
void probe_record(uint32_t bit){
#ifdef BC_NATIVE_TEST_API
    if(probe_inflight)probe_receipts|=bit;
#else
    (void)bit;
#endif
}
struct Hook { uintptr_t rva; const char* fp; bool created{},enabled{}; };
std::array<Hook,3> hooks{{
    {0x12F0920,"48895c241048896c24184889742420574154415541564157"},
    {0x12F1540,"40554883ec3080b934e3240000488be90f84590400004889"},
    {0xAA0E50,"4053574883ec284c8b05c25e880233db488bf9413958700f"}
}};
// AA0E50 is the exact current prefix from the fresh parent capture. Only this
// owner's scoped mask8 teardown is adapted; every ordinary call forwards.
constexpr std::array<std::pair<uintptr_t,const char*>,11> abi{{
    {0x137D500,"40554883ec3080b97897080000488be90f84d30600004889"},
    {0x12E96D0,"48895c2408488974241048897c2418554154415541564157"},
    {0x12EB1B0,"4883ec48488b05550e35014833c44889442438385158744a"},
    {0x12EB670,"405641564883ec5880b9b0f5210000450fb6f00f29742440"},
    {0x12EBC50,"4c8bdc55534156498dabf8feffff4881ecf0010000410f29"},
    {0x12EC800,"48895c2410574883ec600f29742450488bf90f297c244048"},
    {0x12EA5B0,"4c8bdc41564883ec70488b05501a35014833c44889442438"},
    {0x137C9B0,"488bc45553565741564157488d68a14881eca80000004c8b"},
    {0x137EC60,"40574883ec2080b978970800000f28e1488bf90f84640100"},
    {0x137DBF0,"4883ec58488b0515e42b014833c4488944244038110f842d"},
    {0xAA0BB0,"48895c2418574883ec20488bb9800f00004c8bc94c8b5a10"}
}};
bool fail(std::string& e,const char* s){e=s;e+=exception_details();return false;}
bool raw_read(uintptr_t at,void* out,size_t n) {
    if(at<0x10000 || n>65536 || at>0x7FFFFFFFFFFFULL-n)return false;
    __try {std::memcpy(out,reinterpret_cast<const void*>(at),n);return true;}
    __except(EXCEPTION_EXECUTE_HANDLER){return false;}
}
bool raw_write(uintptr_t at,const void* from,size_t n) {
    if(at<0x10000 || n>64 || at>0x7FFFFFFFFFFFULL-n)return false;
    __try {std::memcpy(reinterpret_cast<void*>(at),from,n);return std::memcmp(reinterpret_cast<void*>(at),from,n)==0;}
    __except(EXCEPTION_EXECUTE_HANDLER){return false;}
}
template<class T> bool read(uintptr_t at,T& v){return (io.read?io.read:raw_read)(at,&v,sizeof(v));}
template<class T> T value(uintptr_t at,T fallback=T{}){T v{};return read(at,v)?v:fallback;}
template<class T> bool store(uintptr_t at,T v){return(io.write?io.write:raw_write)(at,&v,sizeof(v));}
bool executable(uintptr_t p){MEMORY_BASIC_INFORMATION i{};return VirtualQuery(reinterpret_cast<void*>(p),&i,sizeof(i))&&i.State==MEM_COMMIT&&!(i.Protect&(PAGE_GUARD|PAGE_NOACCESS))&&(i.Protect&(PAGE_EXECUTE|PAGE_EXECUTE_READ|PAGE_EXECUTE_READWRITE|PAGE_EXECUTE_WRITECOPY));}
bool writable(uintptr_t p,size_t n){MEMORY_BASIC_INFORMATION i{};return VirtualQuery(reinterpret_cast<void*>(p),&i,sizeof(i))&&i.State==MEM_COMMIT&&!(i.Protect&(PAGE_GUARD|PAGE_NOACCESS))&&(i.Protect&(PAGE_READWRITE|PAGE_WRITECOPY|PAGE_EXECUTE_READWRITE|PAGE_EXECUTE_WRITECOPY))&&n<=i.RegionSize-(p-reinterpret_cast<uintptr_t>(i.BaseAddress));}
bool match(uintptr_t at,const char* bytes){
    const auto d=[](char c){return c>='0'&&c<='9'?c-'0':c>='a'&&c<='f'?c-'a'+10:-1;};
    for(size_t i=0;bytes[i];i+=2){uint8_t v{};const int a=d(bytes[i]),b=d(bytes[i+1]);if(a<0||b<0||!read(at+i/2,v)||v!=((a<<4)|b))return false;}return true;
}
bool module(uintptr_t base,uint32_t stamp){uint16_t mz{};int32_t pe{};uint32_t sig{},actual{};return read(base,mz)&&mz==0x5A4D&&read(base+0x3C,pe)&&pe>=0x40&&pe<=0x1000&&read(base+pe,sig)&&sig==0x4550&&read(base+pe+8,actual)&&actual==stamp;}
bool thread(){return target.thread&&GetCurrentThreadId()==target.thread;}
bool native_guards(std::string& e){if(!module(target.game,0x6AB3B43F)||!module(target.exe,0x6AB382E4))return fail(e,"Mission HUD module identity/build changed");for(const auto& a:abi)if(!executable(target.game+a.first)||!match(target.game+a.first,a.second))return fail(e,"Mission HUD native ABI fingerprint changed");return true;}
bool map(uintptr_t at,uint32_t key,uint32_t& row){
    uintptr_t rows{};uint32_t cap{},empty{},mult{};
    if(!read(at,rows)||!rows||!read(at+8,cap)||!cap||cap>0x100000||(cap&(cap-1))||!read(at+12,empty)||!read(at+16,mult)||key==empty)return false;
    for(uint32_t i=0;i<cap&&i<4096;++i){uint32_t found{};const auto p=rows+static_cast<uintptr_t>((key*mult+i)&(cap-1))*8;if(!read(p,found)||found==empty)return false;if(found==key)return read(p+4,row)&&row!=UINT32_MAX;}return false;
}
enum class Actor{Current,Retired,Unknown};
Actor actor(std::string& e,bool sole=false){
    if(!thread()||!module(target.game,0x6AB3B43F)||!module(target.exe,0x6AB382E4)){e="Mission HUD owner thread/module changed";return Actor::Unknown;}
    uintptr_t r{},g{},u{},current{};uint32_t count{};uint8_t generation{};
    const uint32_t index=reference&0x3FFFFF;
    // Array allocations are storage, not Unit lifetime identities. Observe the
    // current arrays and double-seal their root/count/generation/slot before
    // accepting either the exact captured Unit or positive retirement.
    if(!read(target.exe+0x1A100F0,r)||r!=registry||!read(r+0xA0,g)||!g||!read(r+0x88,u)||!u||!read(r+0x98,count)||count>0x400000||index>=count||!read(g+index,generation)||!read(u+static_cast<uintptr_t>(index)*8,current)){e="Mission HUD Unit retirement is unproved";return Actor::Unknown;}
    const auto sealed=[&](){uintptr_t root{},gs{},us{},slot{};uint32_t size{};uint8_t gen{};
        return read(target.exe+0x1A100F0,root)&&root==r&&read(r+0xA0,gs)&&gs==g&&read(r+0x88,us)&&us==u&&read(r+0x98,size)&&size==count&&read(g+index,gen)&&gen==generation&&read(u+static_cast<uintptr_t>(index)*8,slot)&&slot==current;};
    if(!sealed()){e="Mission HUD retirement registry changed during observation";return Actor::Unknown;}
    if(generation!=(reference>>22)||current!=unit)return Actor::Retired;
    uint32_t row{},live_count{};std::array<uint8_t,16> bytes{};uint8_t live{};
    if(value<uintptr_t>(target.game+PM)!=pm||!read(pm+0x70,live_count)||!live_count||live_count>128||(sole&&live_count!=1)||!map(pm+0xF8,target.avatar,row)||row!=0||value<uintptr_t>(pm+0x110)!=descriptor||!(io.read?io.read:raw_read)(descriptor,bytes.data(),bytes.size())||bytes!=actor_bytes||!read(descriptor+0x14,live)||!(live&1)||pm+0x53D8B0+static_cast<uintptr_t>(row)*0x1238!=pc){e="Mission HUD captured actor row is unavailable";return Actor::Unknown;}
    uint32_t unit_reference{},sealed_count{},sealed_row{};std::array<uint8_t,16> sealed_bytes{};uint8_t sealed_live{};
    if(!read(unit+8,unit_reference)||unit_reference!=reference||!sealed()||value<uintptr_t>(target.game+PM)!=pm||!read(pm+0x70,sealed_count)||sealed_count!=live_count||!map(pm+0xF8,target.avatar,sealed_row)||sealed_row!=row||value<uintptr_t>(pm+0x110)!=descriptor||!(io.read?io.read:raw_read)(descriptor,sealed_bytes.data(),sealed_bytes.size())||sealed_bytes!=bytes||!read(descriptor+0x14,sealed_live)||sealed_live!=live){e="Mission HUD actor identity changed during observation";return Actor::Unknown;}
    return Actor::Current;
}
bool roles(bool expected,std::string& e){uint64_t r{};return read(pc+0xFD0,r)&&((r&8)!=0)==expected||fail(e,"Mission HUD local role8 readback pending");}
bool roots(std::string& e){
    for(const auto& v:std::array<std::pair<uintptr_t,uintptr_t>,4>{{{0x820,0x258},{0x930,0x380},{0xA40,0x5D0},{0xB50,0x4A8}}}){uintptr_t p{},context{};uint32_t flags{};if(!read(ui+v.first+0xF0,p)||p!=ui+v.second||!read(p,flags)||!read(ui+v.first+0xF8,context)||context!=gui_owner+5*0x3698)return fail(e,"Mission HUD common root/context5 changed");}return true;
}
bool presentation(std::string& e){uint8_t ready{};if(!thread()||value<uintptr_t>(target.game+UI)!=ui||!read(ui+UiInit,ready)||ready!=1||value<uintptr_t>(target.game+OBSERVER)!=observer||value<uintptr_t>(target.game+GUI)!=gui_owner)return fail(e,"Mission HUD UI/service identity changed");return roots(e);}
constexpr std::array<std::array<uintptr_t,3>,4> mission_rows{{{0x2AA0,0x2AA8,2},{0x2AC8,0x2AD0,39},{0x2D40,0x2D48,2},{0x2D68,0x2D70,2}}};
bool mission_observers(bool registered,std::string& e,bool room=false){
    if(value<uintptr_t>(target.game+OBSERVER)!=observer)return fail(e,"Mission HUD observer manager changed");
    for(const auto& l:mission_rows){uint32_t n{},own{};if(!read(observer+l[0],n)||n>l[2]||(room&&n>=l[2]))return fail(e,"Mission HUD observer capacity/readback unavailable");for(uint32_t i=0;i<n;++i){uintptr_t object{};uint32_t callback{};if(!read(observer+l[1]+i*16,object)||!read(observer+l[1]+i*16+8,callback))return fail(e,"Mission HUD observer row unreadable");if(object==ui+M){if(callback!=0x106)return fail(e,"Mission HUD observer callback changed");++own;}}if(own!=(registered?1U:0U))return fail(e,"Mission HUD observer registration readback pending");}return true;
}
bool ship_observers(bool registered,std::string& e){
    for(const auto& l:std::array<std::pair<uintptr_t,uintptr_t>,3>{{{0x27A8,0x27B0},{0x3890,0x3898},{0x38A8,0x38B0}}}){uint32_t n{};if(!read(observer+l.first,n)||n!=(registered?1U:0U))return fail(e,"Mission HUD Ship observer ownership changed");if(registered&&(value<uintptr_t>(observer+l.second)!=ui+S||value<uint32_t>(observer+l.second+8)!=0x118))return fail(e,"Mission HUD Ship observer row changed");}return true;
}
bool flag(uintptr_t offset,uint8_t expected,std::string& e){uint8_t v{};return read(ui+offset,v)&&v==expected||fail(e,"Mission HUD returned native flag readback pending");}
bool resize_args(float& x,float& y,std::string& e){
    // Normal init writes {1.0f,0.0f} at these offsets. The second argument is
    // clamped to [0,1] inside12ECB38..61; it is not a positive vertical scale.
    return read(ui+0x24E324,x)&&read(ui+0x24E328,y)&&std::isfinite(x)&&std::isfinite(y)&&x>0||fail(e,"Mission HUD normal resize arguments unavailable");
}
bool mission_definition_ready(std::string& e){
    uintptr_t catalogue{},definition{};uint32_t account_mode{};uint8_t difficulty{};
    if(!read(target.game+0x347CEF8,catalogue)||!catalogue||!read(catalogue+0xD8A50,account_mode)||
       !read(state+0xAE288,definition)||!definition||!read(definition+0xF9,difficulty))
        return fail(e,"Mission HUD native mission definition is unavailable");
    // 17C83C0 passes definition+F9 to1373380. In ACCOUNT mode2 its first
    // lookup13733C5 indexes table21D4680 with uint32(difficulty-1); zero
    // therefore becomes0xFFFFFFFF. Refuse before hooks, GUI writes or teardown.
    if(account_mode==2&&difficulty==0)return fail(e,"Mission HUD requires a selected mission difficulty: definition+F9 is zero;13733C5 would index difficulty-1 out of bounds");
    return true;
}
bool weapon_widgets_absent(std::string& e){
    // A separate review owner can construct these subtrees while MInit is0.
    // Refuse overlapping ownership before hooks, GUI writes or Ship teardown.
    for(uintptr_t offset:{M+0x9C38,M+0x19AAF8}){
        uint32_t flags{};uintptr_t child{},sibling{},parent{},context{},tween_a{},tween_b{};
        const auto node=ui+offset;
        if(!read(node,flags)||flags!=0||!read(node+0xE0,child)||child||!read(node+0xE8,sibling)||sibling||!read(node+0xF0,parent)||parent||!read(node+0xF8,context)||context||!read(node+0xA8,tween_a)||tween_a||!read(node+0xB0,tween_b)||tween_b)return fail(e,"Mission HUD native weapon wheel/sibling are not positively absent");
    }
    return true;
}
struct Gui {
    uintptr_t owner{},slot{};int32_t old_depth{},next{};uint8_t old_slot{};bool depth_pending{},slot_pending{};
    bool pending()const{return depth_pending||slot_pending;}
    bool available(std::string& e){int32_t d{};uint8_t b{};return gui_owner&&read(gui_owner+0x2C5BC,d)&&d>=-1&&d<=2&&read(gui_owner+0x2C5B8+static_cast<uintptr_t>(d+1),b)&&writable(gui_owner+0x2C5BC,4)&&writable(gui_owner+0x2C5B8+static_cast<uintptr_t>(d+1),1)||fail(e,"Mission HUD GUI context5 scope unavailable");}
    bool restore(std::string& e){if(!pending())return true;if(value<uintptr_t>(target.game+GUI)!=owner)return fail(e,"Mission HUD GUI provider changed with scope pending");int32_t d{};if(!read(owner+0x2C5BC,d)||(d!=old_depth&&d!=next))return fail(e,"Mission HUD GUI depth belongs to another owner");if(slot_pending){uint8_t b{};if(!read(slot,b)||(b!=old_slot&&b!=5))return fail(e,"Mission HUD GUI slot belongs to another owner");if(b!=old_slot&&!store(slot,old_slot))return fail(e,"Mission HUD GUI slot restore pending");slot_pending=false;}if(depth_pending){if(d!=old_depth&&!store(owner+0x2C5BC,old_depth))return fail(e,"Mission HUD GUI depth restore pending");depth_pending=false;}return true;}
    bool enter(std::string& e){if(pending()||!available(e))return fail(e,"Mission HUD prior/new GUI scope unavailable");owner=gui_owner;if(!read(owner+0x2C5BC,old_depth))return fail(e,"Mission HUD GUI depth unreadable");next=old_depth+1;slot=owner+0x2C5B8+static_cast<uintptr_t>(next);if(!read(slot,old_slot))return fail(e,"Mission HUD GUI slot unreadable");depth_pending=true;if(!store(owner+0x2C5BC,next))return fail(e,"Mission HUD GUI push pending");slot_pending=true;if(!store(slot,uint8_t{5}))return fail(e,"Mission HUD GUI context push pending");return true;}
} gui;
bool probe_solo();
bool call_void(Void fn,uintptr_t object){if(!probe_solo())return false;begin_native_call(fn==mission_destroy?"mission_destroy":"ship_destroy",reinterpret_cast<uintptr_t>(fn));__try{fn(reinterpret_cast<void*>(object));return true;}__except(capture_native_exception(GetExceptionInformation())){return false;}}
bool call_init(Init fn,uintptr_t object,uintptr_t third){if(!probe_solo())return false;begin_native_call(fn==mission_initialize?"mission_init":"ship_init",reinterpret_cast<uintptr_t>(fn));__try{fn(reinterpret_cast<void*>(object),reinterpret_cast<void*>(ui+0x820),reinterpret_cast<void*>(ui+0x930),reinterpret_cast<void*>(ui+third));return true;}__except(capture_native_exception(GetExceptionInformation())){return false;}}
bool call_active(Active fn,uintptr_t object,uint8_t v){if(!probe_solo())return false;begin_native_call(fn==mission_active?(v?"mission_active_on":"mission_active_off"):"ship_active",reinterpret_cast<uintptr_t>(fn));__try{fn(reinterpret_cast<void*>(object),v);return true;}__except(capture_native_exception(GetExceptionInformation())){return false;}}
bool call_resize(float x,float y){if(!probe_solo())return false;begin_native_call("mission_resize",reinterpret_cast<uintptr_t>(mission_resize));__try{mission_resize(reinterpret_cast<void*>(ui+M),x,y);return true;}__except(capture_native_exception(GetExceptionInformation())){return false;}}
bool call_ship_resize(float x){if(!probe_solo())return false;begin_native_call("ship_resize",reinterpret_cast<uintptr_t>(ship_resize));__try{ship_resize(reinterpret_cast<void*>(ui+S),x);return true;}__except(capture_native_exception(GetExceptionInformation())){return false;}}
bool call_ticks(float dt,uint32_t pid){if(!probe_solo())return false;begin_native_call("mission_visibility",reinterpret_cast<uintptr_t>(mission_visible));__try{mission_visible(reinterpret_cast<void*>(ui+M),dt,1);if(!probe_solo())return false;begin_native_call("mission_data",reinterpret_cast<uintptr_t>(mission_data));mission_data(reinterpret_cast<void*>(ui+M),dt,pid);return true;}__except(capture_native_exception(GetExceptionInformation())){return false;}}
bool cancel_options(std::string& e){
    const auto a=actor(e);if(a==Actor::Retired){role_owned=false;return true;}if(a!=Actor::Current)return false;
    uint64_t r{};uint32_t bits{};if(!read(pc+0xFD0,r)||!read(pc+0xFD8,bits))return fail(e,"Mission HUD option cancellation fields unreadable");
    if(r&8){if(!probe_solo())return fail(e,"Mission HUD review solo identity changed before local cancellation");alignas(16)const uint64_t mask[3]={8,0,0};bool called{};begin_native_call("local_role8_remove",reinterpret_cast<uintptr_t>(local_remove));__try{local_remove(reinterpret_cast<void*>(pc+0x50),mask);called=true;}__except(capture_native_exception(GetExceptionInformation())){called=false;}if(!called)return fail(e,"Mission HUD local role8 cancellation interrupted");}
    if(!roles(false,e)||!read(pc+0xFD8,bits)||(bits&0x400000))return fail(e,"Mission HUD weapon-options cancellation pending");role_owned=false;return true;
}
void __fastcall remove_hook(const uint64_t* mask){
    if(!teardown_scope){original_remove(mask);return;}
    std::lock_guard<std::recursive_mutex> lock(mutex);
    uint64_t a{},b{},c{};std::string e;
    if(!thread()||value<uintptr_t>(target.game+UI)!=ui||!read(reinterpret_cast<uintptr_t>(mask),a)||!read(reinterpret_cast<uintptr_t>(mask)+8,b)||!read(reinterpret_cast<uintptr_t>(mask)+16,c)||a!=8||b||c){unexpected_scope_mask=scope_failed=true;pending_error="Mission HUD unexpected scoped role-removal call retained";return;}
    const auto identity=actor(e);
    if(identity==Actor::Retired){role_owned=false;return;}
    if(identity!=Actor::Current){scope_failed=true;pending_error=e;return;}
    if(!cancel_options(e)){scope_failed=true;pending_error=e;}
}
bool probe_solo(){if(!probe_nohooks)return true;std::string e;return probe_inflight&&actor(e,true)==Actor::Current&&presentation(e)&&value<uintptr_t>(target.game+WORLD)==world&&value<uintptr_t>(target.game+GS)==state&&value<uint32_t>(state+0xAC21C)==3;}
bool scoped_active_off(){if(!probe_solo())return false;const bool old=teardown_scope;teardown_scope=true;scope_failed=false;const bool done=call_active(mission_active,ui+M,0);teardown_scope=old;return done;}
bool scoped_destroy(){if(!probe_solo())return false;const bool old=teardown_scope;teardown_scope=true;scope_failed=false;const bool done=call_void(mission_destroy,ui+M);teardown_scope=old;return done;}
bool enable_hooks(std::string& e){for(auto& h:hooks)if(!h.enabled){if(MH_EnableHook(reinterpret_cast<void*>(target.game+h.rva))!=MH_OK){for(auto& undo:hooks)if(undo.enabled&&MH_DisableHook(reinterpret_cast<void*>(target.game+undo.rva))==MH_OK)undo.enabled=false;return fail(e,"Mission HUD hook enable failed; staged journal retained");}h.enabled=true;}return true;}
bool interrupted(std::string& e,const char* why){phase=Phase::Interrupted;return fail(e,why);}
bool calling(){switch(phase){case Phase::ShipDestroyCalling:case Phase::MissionInitCalling:case Phase::InactiveCalling:case Phase::ActivateCalling:case Phase::ResizeCalling:case Phase::DeactivateCalling:case Phase::MissionDestroyCalling:case Phase::ShipInitCalling:case Phase::ShipActiveCalling:case Phase::ShipResizeCalling:return true;default:return false;}}
bool retire_presentation(std::string& e,bool foreign){
    if(!owned)return gui.restore(e);
    if(!presentation(e)||!native_guards(e)||!gui.restore(e))return false;
    if(phase==Phase::Interrupted||unexpected_scope_mask||calling())return fail(e,"Mission HUD interrupted/in-flight native ownership requires retention");
    if(phase==Phase::ShipDestroyReturned){if(!flag(SInit,0,e)||!ship_observers(false,e))return false;phase=Phase::ShipAbsent;probe_record(2);}
    if(phase==Phase::MissionInitReturned){if(!flag(MInit,1,e)||!mission_observers(true,e))return false;widgets=true;phase=Phase::MissionReady;probe_record(4);}
    if(phase==Phase::ActivateReturned){if(!flag(M+0x58,1,e))return false;active=true;phase=Phase::Active;}
    if(phase==Phase::DeactivateReturned){if(scope_failed||!flag(M+0x58,0,e))return fail(e,"Mission HUD deactivation ownership/readback pending");active=false;phase=Phase::MissionReady;}
    if(phase==Phase::MissionDestroyReturned){if(scope_failed||!flag(MInit,0,e)||!mission_observers(false,e))return fail(e,"Mission HUD teardown ownership/readback pending");widgets=false;active=false;phase=Phase::MissionAbsent;}
    if(phase==Phase::ShipInitReturned){if(!flag(SInit,1,e)||!ship_observers(true,e))return false;phase=Phase::ShipReady;}
    if(phase==Phase::InactiveReturned){if(!flag(M+0x58,0,e))return false;phase=Phase::MissionReady;}
    if(widgets){
        if(!cancel_options(e))return false;
        probe_record(128);
        if(active||value<uint8_t>(ui+M+0x58)!=0){phase=Phase::DeactivateCalling;if(!scoped_active_off())return interrupted(e,"Mission HUD deactivation interrupted");phase=Phase::DeactivateReturned;if(scope_failed||!flag(M+0x58,0,e))return fail(e,"Mission HUD deactivation acknowledgement pending");active=false;}
        if(!mission_observers(true,e))return false;
        phase=Phase::MissionDestroyCalling;if(!scoped_destroy())return interrupted(e,"Mission HUD destruction interrupted; journal retained");phase=Phase::MissionDestroyReturned;
        if(scope_failed||!flag(MInit,0,e)||!mission_observers(false,e))return fail(e,"Mission HUD destruction acknowledgement pending");widgets=false;active=false;phase=Phase::MissionAbsent;probe_record(256);
    }
    if(!cancel_options(e))return false;
    if(foreign){
        // A completed owned Ship rebuild can precede a native UI transition.
        // Retire it too; never build another Ship presentation in this hook.
        if(value<uint8_t>(ui+SInit)==1){if(!ship_observers(true,e))return false;phase=Phase::ShipDestroyCalling;if(!call_void(ship_destroy,ui+S))return interrupted(e,"Mission HUD owned Ship destruction interrupted");phase=Phase::ShipDestroyReturned;if(!flag(SInit,0,e)||!ship_observers(false,e))return false;}
        owned=false;retired=true;stopping=false;phase=Phase::Retired;pending_error.clear();return true;
    }
    if(value<uint8_t>(ui+SInit)==0){
        if(!ship_observers(false,e)||!gui.enter(e))return false;
        phase=Phase::ShipInitCalling;const bool returned=call_init(ship_initialize,ui+S,0xA40);phase=returned?Phase::ShipInitReturned:Phase::Interrupted;
        const bool scope=gui.restore(e);if(!returned)return fail(e,"Mission HUD partial Ship reconstruction retained");if(!scope||!flag(SInit,1,e)||!ship_observers(true,e))return false;phase=Phase::ShipReady;
    }
    if(phase!=Phase::ShipActiveReturned&&phase!=Phase::ShipResizeReturned){
        phase=Phase::ShipActiveCalling;if(!call_active(ship_active,ui+S,old_ship_active))return interrupted(e,"Mission HUD Ship activation restore interrupted");phase=Phase::ShipActiveReturned;
    }
    if(!flag(S,old_ship_active,e))return false;
    if(phase!=Phase::ShipResizeReturned){float x{},y{};if(!resize_args(x,y,e))return false;phase=Phase::ShipResizeCalling;if(!call_ship_resize(x))return interrupted(e,"Mission HUD Ship resize interrupted");phase=Phase::ShipResizeReturned;}
    if(!flag(MInit,0,e)||!flag(SInit,1,e)||!ship_observers(true,e)||!mission_observers(false,e))return false;
    owned=false;stopping=false;phase=Phase::Restored;pending_error.clear();probe_record(512);return true;
}
void lifecycle(void* object,Void original){
    std::lock_guard<std::recursive_mutex> lock(mutex);
    if(owned&&reinterpret_cast<uintptr_t>(object)==ui){std::string e;if(!retire_presentation(e,true)){blocked=true;pending_error=e;return;}blocked=false;}
    original(object);
}
void __fastcall init_hook(void* object){lifecycle(object,original_ui_init);}
void __fastcall destroy_hook(void* object){lifecycle(object,original_ui_destroy);}
} // namespace

bool prepare_impl(const Identity& id,std::string& e,Io callbacks,bool stage_hooks){
    std::lock_guard<std::recursive_mutex> lock(mutex);
    if(prepared||owned||gui.pending()||hooks[0].created||hooks[1].created||hooks[2].created)return fail(e,"Mission HUD previous hook/owner journal remains");
    native_exception={};target=id;io=callbacks;retired=blocked=stopping=scope_failed=unexpected_scope_mask=false;widgets=active=role_owned=false;probe_nohooks=!stage_hooks;probe_unacknowledged=false;pending_error.clear();phase=Phase::None;
    if(!thread()||!id.pid||id.pid==UINT32_MAX||!id.avatar||id.avatar==UINT32_MAX||!native_guards(e))return fail(e,"Mission HUD unsupported module/thread/player identity");
    ui=value<uintptr_t>(id.game+UI);pm=value<uintptr_t>(id.game+PM);player=value<uintptr_t>(id.game+PLAYER);world=value<uintptr_t>(id.game+WORLD);state=value<uintptr_t>(id.game+GS);observer=value<uintptr_t>(id.game+OBSERVER);gui_owner=value<uintptr_t>(id.game+GUI);
    uint32_t pr{},wr{},ar{},pm_count{};uintptr_t local_desc{};
    if(!ui||!pm||!player||!world||!state||value<uint32_t>(state+0xAC21C)!=3||!read(pm+0x70,pm_count)||pm_count!=1||!map(pm+0xF8,id.avatar,ar)||ar!=0||!read(player+0x88,pr)||pr==0||!read(player+0xE8,local_desc)||!local_desc||value<uint32_t>(local_desc+8)!=id.pid||!map(player+0xD0,id.pid,pr)||pr>=128||!read(player+0x3A8+static_cast<uintptr_t>(pr)*0x20,local_unit)||!local_unit||!map(world+0xF22EC8,local_unit,wr)||wr>=0x100000||value<uint32_t>(world+0xF32F18+static_cast<uintptr_t>(wr)*24+8)!=id.avatar)return fail(e,"Mission HUD PlayerManager entity/avatar relationship is unproved");
    if(!mission_definition_ready(e))return false;
    descriptor=value<uintptr_t>(pm+0x110);pc=pm+0x53D8B0;
    if(!descriptor||!(io.read?io.read:raw_read)(descriptor,actor_bytes.data(),actor_bytes.size())||value<uint32_t>(descriptor+8)!=id.avatar||!(value<uint8_t>(descriptor+0x14)&1)||!read(descriptor+0xC,reference)||!reference)return fail(e,"Mission HUD local descriptor unavailable");
    registry=value<uintptr_t>(id.exe+0x1A100F0);generations=value<uintptr_t>(registry+0xA0);units=value<uintptr_t>(registry+0x88);unit=value<uintptr_t>(units+static_cast<uintptr_t>(reference&0x3FFFFF)*8);
    if(!registry||!generations||!units||!unit||actor(e,true)!=Actor::Current||!roles(false,e)||value<uint32_t>(pc+0xFD8)&0x400000||!presentation(e)||!flag(MInit,0,e)||!flag(M+0x58,0,e)||!flag(SInit,1,e)||!ship_observers(true,e)||!mission_observers(false,e,true)||!gui.available(e)||!read(ui+S,old_ship_active)||old_ship_active>1)return fail(e,"Mission HUD initial actor/UI ownership preflight refused");
    if(!weapon_widgets_absent(e))return false;
    for(uintptr_t rva:{0x3326308ULL,0x347CE30ULL,0x346D530ULL}){uintptr_t p{};uint8_t probe{};if(!read(id.game+rva,p)||!p||!read(p,probe))return fail(e,"Mission HUD required client service unavailable");}
    const auto engine=value<uintptr_t>(id.game+0x3326308),renderer=value<uintptr_t>(engine+0xD0),app=value<uintptr_t>(engine+0xC0);
    if(!renderer||!app||!executable(value<uintptr_t>(app+0x28)))return fail(e,"Mission HUD application renderer API unavailable");
    for(uintptr_t slot:{0x118ULL,0x180ULL,0x2B8ULL})if(!executable(value<uintptr_t>(renderer+slot)))return fail(e,"Mission HUD renderer callback unavailable");
    float x{},y{};if(!resize_args(x,y,e))return false;
    if(stage_hooks){
        for(const auto& h:hooks)if(!executable(id.game+h.rva)||!match(id.game+h.rva,h.fp))return fail(e,"Mission HUD lifecycle hook ABI changed");
        auto result=MH_Initialize();if(result!=MH_OK&&result!=MH_ERROR_ALREADY_INITIALIZED)return fail(e,"Mission HUD hook library initialization failed");
        const std::array<void*,3> detours{{reinterpret_cast<void*>(init_hook),reinterpret_cast<void*>(destroy_hook),reinterpret_cast<void*>(remove_hook)}};
        const std::array<void**,3> originals{{reinterpret_cast<void**>(&original_ui_init),reinterpret_cast<void**>(&original_ui_destroy),reinterpret_cast<void**>(&original_remove)}};
        for(size_t i=0;i<hooks.size();++i){if(MH_CreateHook(reinterpret_cast<void*>(id.game+hooks[i].rva),detours[i],originals[i])!=MH_OK)return fail(e,"Mission HUD disabled hook staging failed; release retained stages");hooks[i].created=true;}
    }
    ship_destroy=reinterpret_cast<Void>(id.game+0x137D500);mission_initialize=reinterpret_cast<Init>(id.game+0x12E96D0);mission_active=reinterpret_cast<Active>(id.game+0x12EB1B0);mission_visible=reinterpret_cast<Visible>(id.game+0x12EB670);mission_data=reinterpret_cast<Data>(id.game+0x12EBC50);mission_resize=reinterpret_cast<Resize>(id.game+0x12EC800);mission_destroy=reinterpret_cast<Void>(id.game+0x12EA5B0);ship_initialize=reinterpret_cast<Init>(id.game+0x137C9B0);ship_resize=reinterpret_cast<ShipResize>(id.game+0x137EC60);ship_active=reinterpret_cast<Active>(id.game+0x137DBF0);local_remove=reinterpret_cast<LocalContext>(id.game+0xAA0BB0);
    prepared=true;phase=Phase::Prepared;return true;
}
bool prepare(const Identity& id,std::string& e,Io callbacks){return prepare_impl(id,e,callbacks,true);}
bool start(std::string& e){
    std::lock_guard<std::recursive_mutex> lock(mutex);
    if(!prepared||stopping||retired||(probe_nohooks&&!probe_inflight)||!presentation(e)||!native_guards(e))return fail(e,"Mission HUD preparation/start ownership unavailable");
    if(phase==Phase::Active)return flag(MInit,1,e)&&flag(M+0x58,1,e)&&mission_observers(true,e);
    if(phase==Phase::Interrupted)return fail(e,"Mission HUD interrupted native construction retained");
    if(!owned){if(!mission_definition_ready(e)||actor(e,true)!=Actor::Current||!roles(false,e)||!flag(SInit,1,e)||!ship_observers(true,e)||!mission_observers(false,e,true)||!weapon_widgets_absent(e)||!gui.available(e)||(!probe_nohooks&&!enable_hooks(e)))return false;owned=true;phase=Phase::ShipDestroyCalling;if(!call_void(ship_destroy,ui+S))return interrupted(e,"Mission HUD Ship destruction interrupted");phase=Phase::ShipDestroyReturned;}
    if(phase==Phase::ShipDestroyReturned){if(!flag(SInit,0,e)||!ship_observers(false,e))return false;phase=Phase::ShipAbsent;probe_record(2);}
    if(phase==Phase::ShipAbsent){if(actor(e,true)!=Actor::Current||!mission_observers(false,e,true)||!gui.enter(e))return false;phase=Phase::MissionInitCalling;const bool returned=call_init(mission_initialize,ui+M,0xB50);phase=returned?Phase::MissionInitReturned:Phase::Interrupted;const bool scope=gui.restore(e);if(!returned)return fail(e,"Mission HUD partial constructor retained; no guessed teardown");if(!scope)return false;}
    if(phase==Phase::MissionInitReturned){if(!gui.restore(e)||!flag(MInit,1,e)||!mission_observers(true,e))return false;widgets=true;phase=Phase::MissionReady;probe_record(4);}
    if(phase==Phase::MissionReady){if(actor(e,true)!=Actor::Current||!roles(false,e)||!flag(M+0x58,0,e))return false;phase=Phase::InactiveCalling;if(!scoped_active_off())return interrupted(e,"Mission HUD inactive-start call interrupted");phase=Phase::InactiveReturned;}
    if(phase==Phase::InactiveReturned){if(scope_failed||!flag(M+0x58,0,e)||!roles(false,e)||actor(e,true)!=Actor::Current)return false;phase=Phase::ActivateCalling;role_owned=true;if(!call_active(mission_active,ui+M,1))return interrupted(e,"Mission HUD activation interrupted; role ownership retained");phase=Phase::ActivateReturned;}
    if(phase==Phase::ActivateReturned){if(!flag(M+0x58,1,e)||!roles(true,e))return false;active=true;probe_record(16);phase=Phase::ResizeCalling;float x{},y{};if(!resize_args(x,y,e)){phase=Phase::ActivateReturned;return false;}if(!call_resize(x,y))return interrupted(e,"Mission HUD resize interrupted");phase=Phase::ResizeReturned;}
    if(phase==Phase::ResizeReturned){if(!flag(MInit,1,e)||!flag(M+0x58,1,e)||!mission_observers(true,e))return false;phase=Phase::Active;probe_record(32);}
    return phase==Phase::Active;
}
bool tick(float dt,uint32_t pid,uint32_t avatar,std::string& e){std::lock_guard<std::recursive_mutex> lock(mutex);if(!std::isfinite(dt)||dt<0||dt>1||pid!=target.pid||avatar!=target.avatar||phase!=Phase::Active||!owned||stopping||(probe_nohooks&&!probe_inflight)||actor(e)!=Actor::Current||!presentation(e)||!native_guards(e)||!flag(MInit,1,e)||!flag(M+0x58,1,e)||!mission_observers(true,e))return fail(e,"Mission HUD tick identity/readiness refused");float x{},y{};if(!resize_args(x,y,e))return false;if(!call_resize(x,y)||!call_ticks(dt,pid))return interrupted(e,"Mission HUD direct tick interrupted; teardown journal retained");return true;}
bool stop(std::string& e){std::lock_guard<std::recursive_mutex> lock(mutex);stopping=true;if(!thread()||(probe_nohooks&&!probe_inflight&&owned))return fail(e,"Mission HUD stop requires owning coherent transaction/thread");if(!retire_presentation(e,false)){pending_error=e;return false;}stopping=false;return true;}
bool release(std::string& e){std::lock_guard<std::recursive_mutex> lock(mutex);if(!target.thread)return true;if(!thread()||owned||gui.pending()||probe_unacknowledged)return fail(e,"Mission HUD stop/retirement must acknowledge before hook release");bool done=true;for(auto& h:hooks){auto address=reinterpret_cast<void*>(target.game+h.rva);if(h.enabled){auto r=MH_DisableHook(address);if(r!=MH_OK&&r!=MH_ERROR_DISABLED){done=false;continue;}h.enabled=false;}if(h.created){if(MH_RemoveHook(address)!=MH_OK){done=false;continue;}h.created=false;}}if(!done)return fail(e,"Mission HUD hook removal pending");prepared=false;phase=retired?Phase::Retired:Phase::None;pending_error.clear();return true;}
Status status(){std::lock_guard<std::recursive_mutex> lock(mutex);std::string e;const bool safe=retired&&actor(e)==Actor::Retired;return{phase,prepared,widgets,active,!owned&&!gui.pending()&&!probe_unacknowledged,safe,role_owned,blocked,hooks[0].enabled&&hooks[1].enabled&&hooks[2].enabled,owned&&stopping||gui.pending()||phase==Phase::Interrupted||probe_unacknowledged};}

#ifdef BC_NATIVE_TEST_API
namespace {
struct ObserverSnapshot {
    uint32_t count{};
    std::array<uint8_t,39*16> rows{};
};
constexpr std::array<std::array<uintptr_t,3>,7> probe_lists{{
    {0x2AA0,0x2AA8,2},{0x2AC8,0x2AD0,39},{0x2D40,0x2D48,2},
    {0x2D68,0x2D70,2},{0x27A8,0x27B0,1},{0x3890,0x3898,1},{0x38A8,0x38B0,1}
}};
bool observer_snapshot(std::array<ObserverSnapshot,7>& out,std::string& e){
    for(size_t i=0;i<out.size();++i){auto& s=out[i];const auto& l=probe_lists[i];
        if(!read(observer+l[0],s.count)||s.count>l[2]||(s.count&&!(io.read?io.read:raw_read)(observer+l[1],s.rows.data(),s.count*16)))return fail(e,"Mission HUD probe observer snapshot unavailable");
    }return true;
}
struct ProbeDiagnostics {
    bool before_ready{},after_ready{},role_bytes_before{},role_bytes_after{},c4_before_ready{},c4_after_ready{};
    std::array<ObserverSnapshot,7> before{},after{};
    ObserverSnapshot c4_before{},c4_after{};
    std::array<uint8_t,24> old_roles{},new_roles{};
    std::array<uint8_t,4> old_slots{},new_slots{};
    int32_t old_depth{INT32_MIN},new_depth{INT32_MIN};
    uint64_t old_role{},new_role{UINT64_MAX};
    uint32_t checked{},passed{};
} probe_diagnostic;
bool c4_snapshot(ObserverSnapshot& s){
    return read(observer+0xF48,s.count)&&s.count<=5&&(!s.count||(io.read?io.read:raw_read)(observer+0xF50,s.rows.data(),s.count*16));
}
bool semantic_rows_equal(const ObserverSnapshot& a,const ObserverSnapshot& b){
    if(a.count!=b.count)return false;
    std::array<bool,39> matched{};
    for(uint32_t i=0;i<a.count;++i){bool found=false;
        for(uint32_t j=0;j<b.count;++j)if(!matched[j]&&std::memcmp(a.rows.data()+i*16,b.rows.data()+j*16,12)==0){matched[j]=true;found=true;break;}
        if(!found)return false;
    }return true;
}
void probe_after_diagnostic(){
    // Evidence only: do not change acknowledgement rules or replay native work.
    auto& d=probe_diagnostic;d.checked=0;d.passed=0;
    const auto check=[&](uint32_t bit,bool ok){d.checked|=bit;if(ok)d.passed|=bit;};
    check(1,probe_solo());std::string ignored;check(2,presentation(ignored));
    ignored.clear();const bool current=actor(ignored,true)==Actor::Current;check(4,current);
    if(current){d.role_bytes_after=(io.read?io.read:raw_read)(pc+0xFD0,d.new_roles.data(),d.new_roles.size());
        const bool r=read(pc+0xFD0,d.new_role);uint32_t action{};
        check(8,r&&!(d.new_role&8));check(16,r&&d.new_role==d.old_role);
        check(32,read(pc+0xFD8,action)&&!(action&0x400000));}
    if(value<uintptr_t>(target.game+GUI)==gui_owner){check(64,read(gui_owner+0x2C5BC,d.new_depth)&&d.new_depth==d.old_depth);
        check(128,(io.read?io.read:raw_read)(gui_owner+0x2C5B8,d.new_slots.data(),d.new_slots.size())&&d.new_slots==d.old_slots);}
    if(value<uintptr_t>(target.game+OBSERVER)==observer){ignored.clear();d.after_ready=observer_snapshot(d.after,ignored);check(256,d.after_ready);
        bool semantic=d.before_ready&&d.after_ready;if(semantic)for(size_t i=0;i<d.before.size();++i)if(!semantic_rows_equal(d.before[i],d.after[i])){semantic=false;break;}check(512,semantic);
        d.c4_after_ready=c4_snapshot(d.c4_after);}
}
void append_hex(std::string& out,const uint8_t* bytes,size_t n){constexpr char digits[]="0123456789abcdef";for(size_t i=0;i<n;++i){out+=digits[bytes[i]>>4];out+=digits[bytes[i]&15];}}
void append_observer_diagnostic(std::string& out,uintptr_t offset,const ObserverSnapshot& a,const ObserverSnapshot& b,bool ar,bool br){
    char text[512]{};const bool raw=ar&&br&&a.count==b.count&&std::memcmp(a.rows.data(),b.rows.data(),a.count*16)==0;
    std::snprintf(text,sizeof(text),"{\"count_offset\":\"%llx\",\"before_readable\":%s,\"after_readable\":%s,\"raw_equal\":%s,\"semantic_multiset_equal\":%s,\"before\":[",static_cast<unsigned long long>(offset),ar?"true":"false",br?"true":"false",raw?"true":"false",ar&&br&&semantic_rows_equal(a,b)?"true":"false");out+=text;
    for(unsigned side=0;side<2;++side){if(side)out+="],\"after\":[";const auto& s=side?b:a;const bool ready=side?br:ar;
        for(uint32_t i=0;ready&&i<s.count;++i){if(i)out+=',';uintptr_t object{};uint32_t type{},padding{};std::memcpy(&object,s.rows.data()+i*16,8);std::memcpy(&type,s.rows.data()+i*16+8,4);std::memcpy(&padding,s.rows.data()+i*16+12,4);
            std::snprintf(text,sizeof(text),"{\"object\":\"%llx\",\"type\":\"%x\",\"padding\":\"%08x\",\"raw\":\"",static_cast<unsigned long long>(object),type,padding);out+=text;append_hex(out,s.rows.data()+i*16,16);out+="\"}";}}
    out+="]}";
}
bool tree_attached(std::string& e){
    // The full constructor completed at +21F5B0. These are the authored core,
    // native weapon-wheel and sibling attachment roots, not guessed init bits.
    for(uintptr_t child:{0x60ULL,0x9C38ULL,0x19AAF8ULL}){
        uintptr_t parent{},context{};
        if(!read(ui+M+child+0xF0,parent)||parent!=ui+0x820||!read(ui+M+child+0xF8,context)||context!=gui_owner+5*0x3698)return fail(e,"Mission HUD probe native child attachment/context pending");
    }return true;
}
}
bool probe(const Identity& id,std::string& e,Io callbacks){
    std::lock_guard<std::recursive_mutex> lock(mutex);
    if(prepared||owned||gui.pending()||probe_inflight||probe_unacknowledged)return fail(e,"Mission HUD probe prior journal remains; no replay");
    e.clear();
    probe_receipts=0;
    probe_diagnostic={};
    if(!prepare_impl(id,e,callbacks,false)){pending_error=e;return false;}
#ifdef BC_MISSION_HUD_FIXTURE
    if(fixture_bind)fixture_bind();
#endif
    std::array<ObserverSnapshot,7> before{},after{};int32_t old_depth{};
    std::array<uint8_t,4> old_slots{},new_slots{};uint64_t old_role{};
    if(!observer_snapshot(before,e)||!read(gui_owner+0x2C5BC,old_depth)||!(io.read?io.read:raw_read)(gui_owner+0x2C5B8,old_slots.data(),old_slots.size())||!read(pc+0xFD0,old_role)){pending_error=e;return false;}
    probe_diagnostic.before=before;probe_diagnostic.before_ready=true;probe_diagnostic.old_depth=old_depth;probe_diagnostic.old_slots=old_slots;probe_diagnostic.old_role=old_role;
    probe_diagnostic.role_bytes_before=(io.read?io.read:raw_read)(pc+0xFD0,probe_diagnostic.old_roles.data(),probe_diagnostic.old_roles.size());probe_diagnostic.c4_before_ready=c4_snapshot(probe_diagnostic.c4_before);
    probe_receipts|=ProbePreflight;probe_inflight=true;
    bool ran=start(e);
    if(ran){ran=probe_solo()&&tree_attached(e);if(ran)probe_receipts|=ProbeTreeAttached;}
    if(ran){ran=tick(1.0f/60.0f,id.pid,id.avatar,e);if(ran)probe_receipts|=ProbeDataReturned;}
    const std::string first_error=e;
    std::string cleanup_error;const bool cleaned=stop(cleanup_error);
    if(!ran||!cleaned){
        probe_unacknowledged=owned||gui.pending()||!cleaned;probe_inflight=false;
        e=!first_error.empty()?first_error:!cleanup_error.empty()?cleanup_error:"Mission HUD probe current solo identity changed";
        if(!cleanup_error.empty()&&cleanup_error!=e)e+="; cleanup: "+cleanup_error;
        pending_error=e;return false;
    }
    probe_after_diagnostic();
    bool restored=probe_solo()&&presentation(e)&&actor(e,true)==Actor::Current&&roles(false,e)&&
        value<uint64_t>(pc+0xFD0,UINT64_MAX)==old_role&&!(value<uint32_t>(pc+0xFD8,UINT32_MAX)&0x400000)&&
        value<int32_t>(gui_owner+0x2C5BC,INT32_MIN)==old_depth&&
        (io.read?io.read:raw_read)(gui_owner+0x2C5B8,new_slots.data(),new_slots.size())&&new_slots==old_slots&&observer_snapshot(after,e);
    // Native inline observers consume only objectQWORD/typeDWORD. Constructors
    // copy uninitialized stack padding into the final4 bytes and removals may
    // reorder rows. Preserve the complete semantic multiset, including duplicate
    // multiplicity, rather than comparing those nonsemantic bytes or positions.
    if(restored)for(size_t i=0;i<before.size();++i)if(!semantic_rows_equal(before[i],after[i])){restored=false;break;}
    if(restored)probe_receipts|=ProbeGuiRestored|ProbeComplete;
    probe_unacknowledged=!restored;probe_inflight=false;
    if(!restored){if(e.empty())e="Mission HUD probe original observers/role8/GUI acknowledgement pending";pending_error=e;return false;}
    pending_error.clear();e.clear();return true;
}
uint32_t probe_flags(){std::lock_guard<std::recursive_mutex> lock(mutex);return probe_receipts;}
const char* probe_diagnostics(){
    std::lock_guard<std::recursive_mutex> lock(mutex);thread_local std::string out;out.clear();const auto& d=probe_diagnostic;char text[512]{};
    std::snprintf(text,sizeof(text),"{\"version\":1,\"receipts\":%u,\"phase\":%u,\"journal_unacknowledged\":%s,\"checked\":%u,\"passed\":%u,\"failed\":%u,\"old_depth\":%d,\"new_depth\":%d,\"old_role\":\"%llx\",\"new_role\":\"%llx\",\"old_roles_readable\":%s,\"new_roles_readable\":%s,\"old_roles_raw\":\"",probe_receipts,static_cast<unsigned>(phase),probe_unacknowledged?"true":"false",d.checked,d.passed,d.checked&~d.passed,d.old_depth,d.new_depth,static_cast<unsigned long long>(d.old_role),static_cast<unsigned long long>(d.new_role),d.role_bytes_before?"true":"false",d.role_bytes_after?"true":"false");out+=text;
    append_hex(out,d.old_roles.data(),d.old_roles.size());out+="\",\"new_roles_raw\":\"";append_hex(out,d.new_roles.data(),d.new_roles.size());out+="\",\"old_slots\":\"";append_hex(out,d.old_slots.data(),d.old_slots.size());out+="\",\"new_slots\":\"";append_hex(out,d.new_slots.data(),d.new_slots.size());out+="\",\"lists\":[";
    for(size_t i=0;i<d.before.size();++i){if(i)out+=',';append_observer_diagnostic(out,probe_lists[i][0],d.before[i],d.after[i],d.before_ready,d.after_ready);}
    out+=',';append_observer_diagnostic(out,0xF48,d.c4_before,d.c4_after,d.c4_before_ready,d.c4_after_ready);out+="]}";return out.c_str();
}
#endif
} // namespace bc::mission_hud

namespace {thread_local char mission_hud_error[512]{};int result(bool ok,const std::string& e){strncpy_s(mission_hud_error,e.c_str(),_TRUNCATE);return ok?1:0;}}
extern "C" __declspec(dllexport) int BC_mission_hud_prepare(uint32_t pid,uint32_t avatar){std::string e;return result(bc::mission_hud::prepare({reinterpret_cast<uintptr_t>(GetModuleHandleW(L"game.dll")),reinterpret_cast<uintptr_t>(GetModuleHandleW(L"helldivers2.exe")),pid,avatar,GetCurrentThreadId()},e),e);}
extern "C" __declspec(dllexport) int BC_mission_hud_start(){std::string e;return result(bc::mission_hud::start(e),e);}
extern "C" __declspec(dllexport) int BC_mission_hud_tick(float dt,uint32_t pid,uint32_t avatar){std::string e;return result(bc::mission_hud::tick(dt,pid,avatar,e),e);}
extern "C" __declspec(dllexport) int BC_mission_hud_stop(){std::string e;return result(bc::mission_hud::stop(e),e);}
extern "C" __declspec(dllexport) int BC_mission_hud_release(){std::string e;return result(bc::mission_hud::release(e),e);}
extern "C" __declspec(dllexport) uint32_t BC_mission_hud_phase(){return static_cast<uint32_t>(bc::mission_hud::status().phase);}
extern "C" __declspec(dllexport) uint32_t BC_mission_hud_flags(){const auto s=bc::mission_hud::status();return(s.prepared?1U:0U)|(s.widgets_ready?2U:0U)|(s.active?4U:0U)|(s.stopped?8U:0U)|(s.retired_safe?16U:0U)|(s.role8_owned?32U:0U)|(s.lifecycle_blocked?64U:0U)|(s.hooks_enabled?128U:0U)|(s.cleanup_pending?256U:0U);}
extern "C" __declspec(dllexport) const char* BC_mission_hud_error(){std::lock_guard<std::recursive_mutex> lock(bc::mission_hud::mutex);if(!bc::mission_hud::pending_error.empty())strncpy_s(mission_hud_error,bc::mission_hud::pending_error.c_str(),_TRUNCATE);return mission_hud_error;}
#ifdef BC_NATIVE_TEST_API
extern "C" __declspec(dllexport) int BC_mission_hud_probe(uint32_t pid,uint32_t avatar){std::string e;return result(bc::mission_hud::probe({reinterpret_cast<uintptr_t>(GetModuleHandleW(L"game.dll")),reinterpret_cast<uintptr_t>(GetModuleHandleW(L"helldivers2.exe")),pid,avatar,GetCurrentThreadId()},e),e);}
extern "C" __declspec(dllexport) uint32_t BC_mission_hud_probe_flags(){return bc::mission_hud::probe_flags();}
extern "C" __declspec(dllexport) const char* BC_mission_hud_probe_diagnostics(){return bc::mission_hud::probe_diagnostics();}
#endif
