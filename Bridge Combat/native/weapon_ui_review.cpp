#include "weapon_ui_review.h"
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <vector>

namespace bc::weapon_ui_review { namespace {
constexpr uintptr_t UI=0x346D538,PM=0x3326D20,PLAYER=0x3326468,WORLD=0x346BF98,
    GS=0x3326340,GUI=0x347CE90,OBSERVER=0x3326E68,AUX=0x3326420;
constexpr uintptr_t WHEEL=0x257F78,SIBLING=0x3E8E38,MINIT=0x46D8F0,
    MACTIVE=0x24E398,SINIT=0x4F7078,SACTIVE=0x46D900;
using Void=void(__fastcall*)(void*);
using Attach=void(__fastcall*)(void*,void*);
using WheelCtor=void(__fastcall*)(void*,uint64_t,uint32_t);
using SiblingCtor=void(__fastcall*)(void*,uint32_t);
using WheelTick=void(__fastcall*)(void*,float,uint32_t,uint32_t);
using SiblingTick=void(__fastcall*)(void*,float,uint32_t);
using Context=void(__fastcall*)(void*,const uint64_t*);
using Alpha=void(__fastcall*)(void*,float);
Identity target;Io io;Phase phase=Phase::None;
uintptr_t ui{},pm{},player{},world{},state{},gui{},observer{},aux{},descriptor{},pc{},
    registry{},generations{},units{},unit{},aux_record{};
uint32_t reference{},world_unit{};
std::array<uint8_t,16> descriptor_bytes{};
std::array<uint32_t,7> observer_counts{};
uint8_t ship_active{};
bool owned{},active{},role_owned{},expired{};
ULONGLONG deadline{};
std::string pending_error;
std::recursive_mutex mutex;
struct Journal {uint8_t sibling{},wheel{},attach_sibling{},attach_wheel{},add{},remove{},destroy_wheel{},destroy_sibling{},retired_alpha{},retired_final{};bool generic_retired{};} journal;
struct Tree {uintptr_t base{},limit{};std::vector<uintptr_t> nodes;} wheel_tree,sibling_tree;
WheelCtor construct_wheel{};SiblingCtor construct_sibling{};WheelTick update_wheel{};
SiblingTick update_sibling{};Attach attach{};Void flush{},destroy{};Context add_role{},remove_role{};Alpha set_alpha{};
#ifdef BC_WEAPON_UI_FIXTURE
void(*fixture_bind)(){};
ULONGLONG(*fixture_clock)(){};
#endif
ULONGLONG now(){
#ifdef BC_WEAPON_UI_FIXTURE
    if(fixture_clock)return fixture_clock();
#endif
    return GetTickCount64();
}
struct Exception {const char* operation{};DWORD code{};uintptr_t rip{},fault{};ULONG_PTR access{};bool has_fault{};} exception;
LONG capture_exception(EXCEPTION_POINTERS* p){if(p&&p->ContextRecord)exception.rip=static_cast<uintptr_t>(p->ContextRecord->Rip);if(p&&p->ExceptionRecord){auto r=p->ExceptionRecord;exception.code=r->ExceptionCode;if((r->ExceptionCode==EXCEPTION_ACCESS_VIOLATION||r->ExceptionCode==EXCEPTION_IN_PAGE_ERROR)&&r->NumberParameters>=2){exception.has_fault=true;exception.access=r->ExceptionInformation[0];exception.fault=r->ExceptionInformation[1];}}return EXCEPTION_EXECUTE_HANDLER;}
bool fail(std::string& e,const char* text){e=text;if(exception.code){char detail[256]{};const bool game=exception.rip>=target.game&&exception.rip-target.game<0x3500000;std::snprintf(detail,sizeof(detail),"; native_exception op=%s code=0x%08lx rip=0x%llx %s+0x%llx access=%s fault=0x%llx",exception.operation?exception.operation:"unknown",static_cast<unsigned long>(exception.code),static_cast<unsigned long long>(exception.rip),game?"game":"external",static_cast<unsigned long long>(game?exception.rip-target.game:exception.rip),exception.has_fault?(exception.access==0?"read":exception.access==1?"write":"execute"):"none",static_cast<unsigned long long>(exception.fault));e+=detail;}pending_error=e;return false;}
bool raw_read(uintptr_t p,void* out,size_t n){if(p<0x10000||n>65536||p>0x7FFFFFFFFFFFULL-n)return false;__try{std::memcpy(out,reinterpret_cast<void*>(p),n);return true;}__except(EXCEPTION_EXECUTE_HANDLER){return false;}}
bool raw_write(uintptr_t p,const void* from,size_t n){if(p<0x10000||n>64||p>0x7FFFFFFFFFFFULL-n)return false;__try{std::memcpy(reinterpret_cast<void*>(p),from,n);return std::memcmp(reinterpret_cast<void*>(p),from,n)==0;}__except(EXCEPTION_EXECUTE_HANDLER){return false;}}
template<class T>bool read(uintptr_t p,T& v){return(io.read?io.read:raw_read)(p,&v,sizeof(v));}
template<class T>T value(uintptr_t p,T fallback=T{}){T v{};return read(p,v)?v:fallback;}
template<class T>bool write(uintptr_t p,T v){return(io.write?io.write:raw_write)(p,&v,sizeof(v));}
bool module(uintptr_t p,uint32_t stamp){uint16_t mz{};int32_t pe{};uint32_t sig{},s{};return read(p,mz)&&mz==0x5A4D&&read(p+0x3C,pe)&&pe>=0x40&&pe<=0x1000&&read(p+pe,sig)&&sig==0x4550&&read(p+pe+8,s)&&s==stamp;}
bool executable(uintptr_t p){MEMORY_BASIC_INFORMATION m{};return VirtualQuery(reinterpret_cast<void*>(p),&m,sizeof(m))&&m.State==MEM_COMMIT&&!(m.Protect&(PAGE_GUARD|PAGE_NOACCESS))&&(m.Protect&(PAGE_EXECUTE|PAGE_EXECUTE_READ|PAGE_EXECUTE_READWRITE|PAGE_EXECUTE_WRITECOPY));}
bool writable(uintptr_t p,size_t n){MEMORY_BASIC_INFORMATION m{};return VirtualQuery(reinterpret_cast<void*>(p),&m,sizeof(m))&&m.State==MEM_COMMIT&&!(m.Protect&(PAGE_GUARD|PAGE_NOACCESS))&&(m.Protect&(PAGE_READWRITE|PAGE_WRITECOPY|PAGE_EXECUTE_READWRITE|PAGE_EXECUTE_WRITECOPY))&&n<=m.RegionSize-(p-reinterpret_cast<uintptr_t>(m.BaseAddress));}
constexpr std::array<std::pair<uintptr_t,const char*>,14> abi{{
    {0x1823910,"488bc4488958084889701048897818554154415541564157"},
    {0x17B4830,"488bc4488958105556574154415541564157488d68a14881"},
    {0x1825F40,"488bc4488958104889681848897020574154415541564157"},
    {0x17B6560,"488bc4488958185556574154415541564157488d68a14881"},
    {0x144C5C0,"40534883ec204c8bca488bd9488b91e00000004885d27454"},
    {0x144C2C0,"488b81e00000004532c94c8bc14885c0742f0f1f40006666"},
    {0x144DD70,"40534883ec20488bd9e8a20b00008b03c1e81283e00f83f8"},
    {0xAA0AA0,"48895c2408574883ec20488b1a488bfa4c8b89900f00004c"},
    {0xAA0BB0,"48895c2418574883ec20488bb9800f00004c8bc94c8b5a10"},
    {0x1448AD0,"40574883ec20f30f104144488bf90f2ec17a237521f70100"},
    {0xAA0760,"4883ec48488b05a5b8b9014833c448894424388b0148895c"},
    {0x1828A70,"4883ec3880b9d0bc0000000f85fe000000f30f101de7e2b9"},
    {0x1450DD0,"40564881ec90000000f30f102d8f5ff7000f28e30f297c24"},
    {0x1448870,"4053574883ec78f30f104144410fb6d90f2ec1488bf90f8a"}
}};
bool match(uintptr_t p,const char* h){auto digit=[](char c){return c>='0'&&c<='9'?c-'0':c-'a'+10;};for(size_t i=0;h[i];i+=2){uint8_t b{};if(!read(p+i/2,b)||b!=((digit(h[i])<<4)|digit(h[i+1])))return false;}return true;}
bool natives(std::string& e){if(GetCurrentThreadId()!=target.thread||!module(target.game,0x6AB3B43F)||!module(target.exe,0x6AB382E4))return fail(e,"Weapon UI thread/build identity changed");for(auto a:abi)if(!executable(target.game+a.first)||!match(target.game+a.first,a.second))return fail(e,"Weapon UI native fingerprint changed");return true;}
bool map(uintptr_t p,uint32_t key,uint32_t& row){uintptr_t rows{};uint32_t cap{},empty{},mult{};if(!read(p,rows)||!rows||!read(p+8,cap)||!cap||cap>0x100000||(cap&(cap-1))||!read(p+12,empty)||!read(p+16,mult)||key==empty)return false;for(uint32_t i=0;i<cap&&i<4096;++i){const auto at=rows+static_cast<uintptr_t>((key*mult+i)&(cap-1))*8;uint32_t found{};if(!read(at,found)||found==empty)return false;if(found==key)return read(at+4,row)&&row!=UINT32_MAX;}return false;}
bool actor(std::string& e){uint32_t row{},count{},index=reference&0x3FFFFF;uint8_t gen{},live{};uintptr_t current{},current_generations{},current_units{},seal_root{},seal_generations{},seal_units{},seal_unit{};uint32_t seal_count{};uint8_t seal_gen{};std::array<uint8_t,16> bytes{};
    // Unit arrays can relocate while the exact Unit/reference remains live.
    // Seal current root, allocations, count, generation and slot twice instead
    // of treating cached array addresses as lifetime identities.
    if(value<uintptr_t>(target.game+PM)!=pm||value<uint32_t>(pm+0x70)!=1||!map(pm+0xF8,target.avatar,row)||row!=0||value<uintptr_t>(pm+0x110)!=descriptor||!(io.read?io.read:raw_read)(descriptor,bytes.data(),bytes.size())||bytes!=descriptor_bytes||!read(descriptor+20,live)||!(live&1)||value<uintptr_t>(target.exe+0x1A100F0)!=registry||!read(registry+0xA0,current_generations)||!current_generations||!read(registry+0x88,current_units)||!current_units||!read(registry+0x98,count)||count>0x400000||index>=count||!read(current_generations+index,gen)||gen!=(reference>>22)||!read(current_units+static_cast<uintptr_t>(index)*8,current)||current!=unit||!read(target.exe+0x1A100F0,seal_root)||seal_root!=registry||!read(registry+0xA0,seal_generations)||seal_generations!=current_generations||!read(registry+0x88,seal_units)||seal_units!=current_units||!read(registry+0x98,seal_count)||seal_count!=count||!read(current_generations+index,seal_gen)||seal_gen!=gen||!read(current_units+static_cast<uintptr_t>(index)*8,seal_unit)||seal_unit!=current)return fail(e,"Weapon UI actor identity unavailable; no stale actor calls");
    uintptr_t local{};uint32_t wr{};if(value<uintptr_t>(target.game+PLAYER)!=player||value<uintptr_t>(target.game+WORLD)!=world||value<uint32_t>(player+0x88)==0||!read(player+0xE8,local)||!local||value<uint32_t>(local+8)!=target.pid||!map(player+0xD0,target.pid,row)||row>=128||value<uint32_t>(player+0x3A8+static_cast<uintptr_t>(row)*0x20)!=world_unit||!map(world+0xF22EC8,world_unit,wr)||wr>=0x100000||value<uint32_t>(world+0xF32F18+static_cast<uintptr_t>(wr)*24+8)!=target.avatar)return fail(e,"Weapon UI player entity/avatar relation changed");
    uint32_t ar{};uintptr_t records{};if(value<uintptr_t>(target.game+AUX)!=aux||!map(aux+0x30,target.avatar,ar)||ar>=0x100000||!read(aux+0x58,records)||!records||(aux_record&&records+static_cast<uintptr_t>(ar)*0x20!=aux_record))return fail(e,"Weapon UI avatar auxiliary row unavailable");uint8_t b{};return read(records+static_cast<uintptr_t>(ar)*0x20+5,b)||fail(e,"Weapon UI auxiliary row unreadable");
}
constexpr std::array<uintptr_t,7> count_offsets{{0x2AA0,0x2AC8,0x2D40,0x2D68,0x27A8,0x3890,0x38A8}};
bool observers(std::string& e){if(value<uintptr_t>(target.game+OBSERVER)!=observer)return fail(e,"Weapon UI observer provider changed");for(size_t i=0;i<count_offsets.size();++i){uint32_t c{};if(!read(observer+count_offsets[i],c)||c!=observer_counts[i])return fail(e,"Weapon UI full-HUD observer counts changed");}return true;}
bool presentation(std::string& e){uint32_t flags{};uintptr_t parent{},context{};uint8_t a{},b{},c{},d{};if(value<uintptr_t>(target.game+UI)!=ui||value<uintptr_t>(target.game+GUI)!=gui||value<uintptr_t>(target.game+GS)!=state||value<uint32_t>(state+0xAC21C)!=3||value<uint8_t>(ui+0x24E334)!=1||!read(ui+0x820,flags)||!(flags&1)||!read(ui+0x820+0xF0,parent)||parent!=ui+0x258||!read(ui+0x820+0xF8,context)||context!=gui+5*0x3698||!read(ui+MINIT,a)||a||!read(ui+MACTIVE,b)||b||!read(ui+SINIT,c)||c!=1||!read(ui+SACTIVE,d)||d!=ship_active)return fail(e,"Weapon UI bridge/root presentation changed; ownership retained");return observers(e);}
bool menu_clear(){const auto menu=value<uintptr_t>(target.game+0x347CE28);return menu&&value<uint32_t>(menu+0x4294,UINT32_MAX)==0&&value<uint32_t>(menu+0x4298,UINT32_MAX)==0;}
bool roles(bool on,std::string& e){uint64_t v{};return(read(pc+0xFD0,v)&&((v&8)!=0)==on)||fail(e,"Weapon UI role8 acknowledgement pending");}
bool closed(std::string& e){uint32_t v{};uint8_t aux_open{};return(read(pc+0xFD8,v)&&!(v&0x400000)&&aux_record&&read(aux_record+5,aux_open)&&aux_open==0)||fail(e,"Weapon UI action86/auxiliary cancellation acknowledgement pending");}
struct GuiScope {int32_t before{},after{};uint8_t old{};uintptr_t slot{};bool depth_pending{},slot_pending{};
    bool pending()const{return depth_pending||slot_pending;}
    bool available(std::string& e){int32_t d{};return(read(gui+0x2C5BC,d)&&d>=-1&&d<=2&&writable(gui+0x2C5BC,4)&&writable(gui+0x2C5B8+static_cast<uintptr_t>(d+1),1))||fail(e,"Weapon UI renderer context5 stack unavailable");}
    bool restore(std::string& e){if(!pending())return true;if(value<uintptr_t>(target.game+GUI)!=gui)return fail(e,"Weapon UI GUI provider changed during scope");int32_t d{};if(!read(gui+0x2C5BC,d)||(d!=before&&d!=after))return fail(e,"Weapon UI GUI stack has foreign owner");if(slot_pending){uint8_t b{};if(!read(slot,b)||(b!=old&&b!=5))return fail(e,"Weapon UI GUI slot has foreign owner");if(b!=old&&!write(slot,old))return fail(e,"Weapon UI GUI slot restoration pending");slot_pending=false;}if(depth_pending){if(d!=before&&!write(gui+0x2C5BC,before))return fail(e,"Weapon UI GUI stack restoration pending");depth_pending=false;}return true;}
    bool enter(std::string& e){if(pending()||!available(e)||!read(gui+0x2C5BC,before))return false;after=before+1;slot=gui+0x2C5B8+static_cast<uintptr_t>(after);if(!read(slot,old))return fail(e,"Weapon UI GUI slot unreadable");depth_pending=true;if(!write(gui+0x2C5BC,after))return fail(e,"Weapon UI GUI push pending");slot_pending=true;return write(slot,uint8_t{5})||fail(e,"Weapon UI GUI context write pending");}
} scope;
bool before_call(std::string& e){return natives(e)&&actor(e)&&presentation(e);}
bool empty(uintptr_t p){uint32_t f{};uintptr_t a{},b{},c{},d{},tween_a{},tween_b{};return read(p,f)&&f==0&&read(p+0xE0,a)&&!a&&read(p+0xE8,b)&&!b&&read(p+0xF0,c)&&!c&&read(p+0xF8,d)&&!d&&read(p+0xA8,tween_a)&&!tween_a&&read(p+0xB0,tween_b)&&!tween_b;}
bool tree_node(Tree& t,uintptr_t node,uintptr_t parent,std::string& e){if(t.nodes.size()>=512||node<t.base||node>t.limit-0x110)return fail(e,"Weapon UI child tree escaped component boundary");for(auto old:t.nodes)if(old==node)return fail(e,"Weapon UI child tree cycle/alias");uint32_t f{};uintptr_t p{},context{},child{};if(!read(node,f)||!(f&1)||!read(node+0xF0,p)||p!=parent||!read(node+0xF8,context)||context!=gui+5*0x3698||!read(node+0xE0,child))return fail(e,"Weapon UI complete child header/parent/context proof unavailable");t.nodes.push_back(node);while(child){uintptr_t next{};if(!read(child+0xE8,next)||!tree_node(t,child,node,e))return false;child=next;}return true;}
bool tree_capture(Tree& t,uintptr_t parent,std::string& e){t.nodes.clear();return tree_node(t,t.base,parent,e);}
bool tree_present(const Tree& t,std::string& e){Tree current;current.base=t.base;current.limit=t.limit;if(!tree_capture(current,ui+0x820,e)||current.nodes!=t.nodes)return fail(e,"Weapon UI owned widget tree retired/changed; native calls withheld");return true;}
bool tree_absent(const Tree& t){for(auto n:t.nodes)if(!empty(n))return false;return true;}
// This is positive generic retirement, not a missing/changed-tree heuristic.
// Generic1446B00 clears these fields but leaves geometry, alpha44 and BCD0.
bool retired_node(uintptr_t n,bool alpha_dirty){uint32_t flags{};if(!read(n,flags)||(flags!=0&&(!alpha_dirty||flags!=4)))return false;for(uintptr_t off:{0xA8ULL,0xB0ULL,0xE0ULL,0xE8ULL,0xF0ULL,0xF8ULL,0x100ULL,0x108ULL}){uintptr_t v{};if(!read(n+off,v)||v)return false;}return true;}
bool retired_root_clear(std::vector<uintptr_t>& found,std::string& e){uintptr_t n{};if(!read(ui+0x820+0xE0,n))return fail(e,"Weapon UI current root children unreadable");while(n){if(found.size()>=1024||n==ui+WHEEL||n==ui+SIBLING)return fail(e,"Weapon UI retired component still linked to current root");for(auto old:found)if(old==n)return fail(e,"Weapon UI current root child cycle");uint32_t flags{};uintptr_t parent{},context{},next{};if(!read(n,flags)||!(flags&1)||!read(n+0xF0,parent)||parent!=ui+0x820||!read(n+0xF8,context)||context!=gui+5*0x3698||!read(n+0xE8,next))return fail(e,"Weapon UI current root child ownership opaque");found.push_back(n);n=next;}return true;}
bool retired_trees(bool alpha_dirty,std::string& e){if(wheel_tree.nodes.empty()||sibling_tree.nodes.empty())return fail(e,"Weapon UI captured retirement tree unavailable");std::vector<uintptr_t> first;for(unsigned seal=0;seal<2;++seal){for(const auto* t:{&wheel_tree,&sibling_tree})for(auto n:t->nodes)if(!retired_node(n,alpha_dirty&&n==ui+WHEEL))return fail(e,"Weapon UI retirement is partial, opaque or foreign; no late cancellation");std::vector<uintptr_t> current;if(!retired_root_clear(current,e))return false;if(seal&&first!=current)return fail(e,"Weapon UI root children changed during retirement proof");first=std::move(current);}return true;}
void begin(const char* op){exception={};exception.operation=op;}
bool call_ctor(bool wheel){begin(wheel?"wheel_ctor":"sibling_ctor");__try{if(wheel)construct_wheel(reinterpret_cast<void*>(ui+WHEEL),0x3F0000003F000000ULL,0x258);else construct_sibling(reinterpret_cast<void*>(ui+SIBLING),0x1F4);return true;}__except(capture_exception(GetExceptionInformation())){return false;}}
bool call_attach(uintptr_t node){begin("attach");__try{attach(reinterpret_cast<void*>(ui+0x820),reinterpret_cast<void*>(node));return true;}__except(capture_exception(GetExceptionInformation())){return false;}}
bool call_flush(){begin("layout_flush");__try{flush(reinterpret_cast<void*>(ui+0x820));return true;}__except(capture_exception(GetExceptionInformation())){return false;}}
bool call_context(bool on){begin(on?"role8_add":"role8_remove");alignas(16)const uint64_t mask[3]={8,0,0};__try{(on?add_role:remove_role)(reinterpret_cast<void*>(pc+0x50),mask);return true;}__except(capture_exception(GetExceptionInformation())){return false;}}
bool call_sibling_tick(float dt){begin("sibling_tick");__try{update_sibling(reinterpret_cast<void*>(ui+SIBLING),dt,target.pid);return true;}__except(capture_exception(GetExceptionInformation())){return false;}}
bool call_wheel_tick(float dt){begin("wheel_tick");__try{update_wheel(reinterpret_cast<void*>(ui+WHEEL),dt,target.pid,target.avatar);return true;}__except(capture_exception(GetExceptionInformation())){return false;}}
bool call_destroy(uintptr_t node){begin(node==ui+WHEEL?"wheel_destroy":"sibling_destroy");__try{destroy(reinterpret_cast<void*>(node));return true;}__except(capture_exception(GetExceptionInformation())){return false;}}
bool call_alpha_zero(){begin("retired_wheel_alpha_zero");__try{set_alpha(reinterpret_cast<void*>(ui+WHEEL),0.0f);return true;}__except(capture_exception(GetExceptionInformation())){return false;}}
bool interrupted(std::string& e,const char* message){phase=Phase::Interrupted;active=false;return fail(e,message);}
bool cleanup_retired(std::string& e){
    // Current initialized ship roots, no Mission owner, and the same sole actor
    // remain mandatory. A scene change or replacement never removes native8.
    if(!before_call(e)||!retired_trees(journal.retired_alpha>=2,e))return false;
    uint8_t custom_closed{},aux_open{};uint32_t action{};float alpha{};
    if(!read(ui+WHEEL+0xBCD0,custom_closed)||custom_closed>1||!read(aux_record+5,aux_open)||aux_open>1||!read(pc+0xFD8,action)||!read(ui+WHEEL+0x44,alpha)||!std::isfinite(alpha)||alpha<0||alpha>1||
       (custom_closed&&aux_open)||(!custom_closed&&!(action&0x400000)))
        return fail(e,"Weapon UI retired custom/action/auxiliary state inconsistent");
    // A normal engine cancellation may already have ended our bit. Never
    // publish another removal merely to obtain a close side effect.
    if(journal.retired_alpha==0&&!roles(true,e)){
        if(!closed(e))return false;
        journal.generic_retired=true;journal.remove=3;role_owned=false;
        journal.destroy_wheel=journal.destroy_sibling=3;journal.wheel=journal.sibling=4;
        owned=false;phase=Phase::Stopped;pending_error.clear();e.clear();return true;
    }
    journal.generic_retired=true;phase=Phase::Stopping;
    if(journal.retired_alpha==0){
        if(!role_owned||journal.remove!=0||!before_call(e)||!retired_trees(false,e))return fail(e,"Weapon UI retired alpha acquisition refused");
        journal.retired_alpha=1;
        if(!call_alpha_zero())return interrupted(e,"Weapon UI retired alpha setter interrupted; no replay");
        journal.retired_alpha=2;
    }
    if(journal.retired_alpha==1)return interrupted(e,"Weapon UI retired alpha result unknown");
    if(!before_call(e)||!retired_trees(true,e)||!read(ui+WHEEL+0x44,alpha)||alpha!=0.0f)return fail(e,"Weapon UI retired alpha acknowledgement pending");
    journal.retired_alpha=3;
    // At alpha0 with no animation handles, authored1828A70's1450DD0 takes the
    // no-allocation return1450F13. Do not write its custom closed byte.
    if(role_owned){
        if(journal.remove==0){if(!before_call(e)||!retired_trees(true,e))return false;journal.remove=1;if(!call_context(false))return interrupted(e,"Weapon UI retired local cancellation interrupted");journal.remove=2;}
        if(journal.remove==1)return interrupted(e,"Weapon UI retired cancellation result unknown");
        if(!roles(false,e)||!closed(e)||!read(ui+WHEEL+0xBCD0,custom_closed)||custom_closed!=1)return fail(e,"Weapon UI retired authored close acknowledgement pending");
        journal.remove=3;role_owned=false;
    }
    if(!before_call(e)||!roles(false,e)||!closed(e)||!retired_trees(true,e))return false;
    // Alpha setter can introduce only dirty flag4 into the empty root. The
    // native generic destructor on flags4/no links/no handles clears that bit;
    // no child, context or animation resource path is reachable.
    uint32_t flags{};if(!read(ui+WHEEL,flags))return fail(e,"Weapon UI retired dirty flag unreadable");
    if(journal.retired_final==0&&flags==4){journal.retired_final=1;if(!call_destroy(ui+WHEEL))return interrupted(e,"Weapon UI retired dirty normalization interrupted");journal.retired_final=2;}
    if(journal.retired_final==1)return interrupted(e,"Weapon UI retired normalization result unknown");
    if(!before_call(e)||!retired_trees(false,e)||!roles(false,e)||!closed(e)||!scope.restore(e))return fail(e,"Weapon UI retired final acknowledgement pending");
    journal.retired_final=3;journal.destroy_wheel=journal.destroy_sibling=3;journal.wheel=journal.sibling=4;
    owned=false;phase=Phase::Stopped;pending_error.clear();e.clear();return true;
}
bool cleanup(std::string& e){active=false;if(!owned)return scope.restore(e);if(phase==Phase::Interrupted)return fail(e,"Weapon UI interrupted native stage retained; no replay/guessed teardown");if(!before_call(e)||!scope.restore(e)){phase=Phase::RetiredPending;return false;}phase=Phase::Stopping;
    if(journal.generic_retired||((journal.wheel==3&&journal.destroy_wheel==0&&!tree_present(wheel_tree,e))||(journal.sibling==3&&journal.destroy_sibling==0&&!tree_present(sibling_tree,e)))){if(cleanup_retired(e))return true;if(phase!=Phase::Interrupted)phase=Phase::RetiredPending;return false;}
    if(role_owned){if(journal.remove==0){if(!before_call(e))return false;journal.remove=1;if(!call_context(false))return interrupted(e,"Weapon UI local cancellation interrupted; owner retained");journal.remove=2;}if(!roles(false,e)||!closed(e))return false;journal.remove=3;role_owned=false;}
    else if(!roles(false,e)||!closed(e))return false;
    if(journal.wheel==3){if(journal.destroy_wheel==0){if(!before_call(e))return false;journal.destroy_wheel=1;if(!call_destroy(ui+WHEEL))return interrupted(e,"Weapon UI recursive wheel teardown interrupted");journal.destroy_wheel=2;}if(!tree_absent(wheel_tree))return fail(e,"Weapon UI wheel teardown acknowledgement pending");journal.destroy_wheel=3;journal.wheel=4;}
    if(journal.sibling==3){if(journal.destroy_sibling==0){if(!before_call(e))return false;journal.destroy_sibling=1;if(!call_destroy(ui+SIBLING))return interrupted(e,"Weapon UI recursive sibling teardown interrupted");journal.destroy_sibling=2;}if(!tree_absent(sibling_tree))return fail(e,"Weapon UI sibling teardown acknowledgement pending");journal.destroy_sibling=3;journal.sibling=4;}
    if(!roles(false,e)||!closed(e)||!observers(e)||!scope.restore(e))return false;owned=false;phase=Phase::Stopped;pending_error.clear();e.clear();return true;
}
} // namespace

bool start(const Identity& id,float seconds,bool caller_ready,std::string& e,Io callbacks){std::lock_guard<std::recursive_mutex> lock(mutex);if(phase!=Phase::None||owned||scope.pending())return fail(e,"Weapon UI review is one-shot; prior journal remains");exception={};target=id;io=callbacks;pending_error.clear();if(!caller_ready||!std::isfinite(seconds)||seconds<=0||seconds>60||!id.pid||id.pid==UINT32_MAX||!id.avatar||id.avatar==UINT32_MAX||!natives(e))return fail(e,"Weapon UI review readiness/duration/identity refused");
    ui=value<uintptr_t>(id.game+UI);pm=value<uintptr_t>(id.game+PM);player=value<uintptr_t>(id.game+PLAYER);world=value<uintptr_t>(id.game+WORLD);state=value<uintptr_t>(id.game+GS);gui=value<uintptr_t>(id.game+GUI);observer=value<uintptr_t>(id.game+OBSERVER);aux=value<uintptr_t>(id.game+AUX);descriptor=value<uintptr_t>(pm+0x110);pc=pm+0x53D8B0;uint32_t row{};
    if(!ui||!pm||!player||!world||!state||!gui||!observer||!aux||!descriptor||!(io.read?io.read:raw_read)(descriptor,descriptor_bytes.data(),descriptor_bytes.size())||value<uint32_t>(descriptor+8)!=id.avatar||!read(descriptor+12,reference)||!reference||!map(player+0xD0,id.pid,row)||row>=128||!read(player+0x3A8+static_cast<uintptr_t>(row)*0x20,world_unit)||!world_unit||!read(ui+SACTIVE,ship_active)||ship_active>1)return fail(e,"Weapon UI initial owner discovery refused");
    registry=value<uintptr_t>(id.exe+0x1A100F0);generations=value<uintptr_t>(registry+0xA0);units=value<uintptr_t>(registry+0x88);unit=value<uintptr_t>(units+static_cast<uintptr_t>(reference&0x3FFFFF)*8);
    uintptr_t aux_rows{};uint32_t aux_row{};if(!map(aux+0x30,id.avatar,aux_row)||aux_row>=0x100000||!read(aux+0x58,aux_rows)||!aux_rows)return fail(e,"Weapon UI initial auxiliary mapping unavailable");aux_record=aux_rows+static_cast<uintptr_t>(aux_row)*0x20;
    for(size_t i=0;i<count_offsets.size();++i)if(!read(observer+count_offsets[i],observer_counts[i]))return fail(e,"Weapon UI observer snapshot unavailable");
    float scale{};if(!actor(e)||!presentation(e)||!menu_clear()||!roles(false,e)||!closed(e)||!(value<uint64_t>(pc+0xFD0)&2)||!empty(ui+WHEEL)||!empty(ui+SIBLING)||!read(ui+0x24E324,scale)||!std::isfinite(scale)||scale<=0||!scope.available(e))return fail(e,"Weapon UI pure preflight refused");
    const auto engine=value<uintptr_t>(id.game+0x3326308),api=value<uintptr_t>(engine+0xD0);if(!engine||!api)return fail(e,"Weapon UI renderer API unavailable");for(uintptr_t slot:{0x118ULL,0x180ULL,0x230ULL,0x238ULL,0x240ULL,0x2B8ULL})if(!executable(value<uintptr_t>(api+slot)))return fail(e,"Weapon UI renderer callback unavailable");
    construct_wheel=reinterpret_cast<WheelCtor>(id.game+0x1823910);construct_sibling=reinterpret_cast<SiblingCtor>(id.game+0x17B4830);update_wheel=reinterpret_cast<WheelTick>(id.game+0x1825F40);update_sibling=reinterpret_cast<SiblingTick>(id.game+0x17B6560);attach=reinterpret_cast<Attach>(id.game+0x144C5C0);flush=reinterpret_cast<Void>(id.game+0x144C2C0);destroy=reinterpret_cast<Void>(id.game+0x144DD70);add_role=reinterpret_cast<Context>(id.game+0xAA0AA0);remove_role=reinterpret_cast<Context>(id.game+0xAA0BB0);set_alpha=reinterpret_cast<Alpha>(id.game+0x1448AD0);
#ifdef BC_WEAPON_UI_FIXTURE
    if(fixture_bind)fixture_bind();
#endif
    wheel_tree.base=ui+WHEEL;wheel_tree.limit=wheel_tree.base+0xBCF0;sibling_tree.base=ui+SIBLING;sibling_tree.limit=sibling_tree.base+0x20B8;phase=Phase::Preflight;owned=true;deadline=now()+static_cast<ULONGLONG>(seconds*1000);
    if(!before_call(e)||!scope.enter(e))return false;phase=Phase::SiblingCalling;journal.sibling=1;bool returned=call_ctor(false);journal.sibling=returned?2:1;phase=returned?Phase::SiblingReturned:Phase::Interrupted;const bool gui_ok=scope.restore(e);if(!returned)return interrupted(e,"Weapon UI partial sibling constructor retained");if(!gui_ok||!observers(e)||!tree_capture(sibling_tree,0,e))return interrupted(e,"Weapon UI returned sibling tree unproved; retained");journal.sibling=3;
    if(!before_call(e))return false;journal.attach_sibling=1;if(!call_attach(ui+SIBLING))return interrupted(e,"Weapon UI sibling attachment interrupted");journal.attach_sibling=2;if(!before_call(e)||!tree_capture(sibling_tree,ui+0x820,e))return interrupted(e,"Weapon UI sibling attachment acknowledgement unavailable");if(!call_flush())return interrupted(e,"Weapon UI sibling layout flush interrupted");journal.attach_sibling=3;phase=Phase::SiblingAttached;
    if(!before_call(e)||!scope.enter(e))return false;phase=Phase::WheelCalling;journal.wheel=1;returned=call_ctor(true);journal.wheel=returned?2:1;phase=returned?Phase::WheelReturned:Phase::Interrupted;const bool second_gui_ok=scope.restore(e);if(!returned)return interrupted(e,"Weapon UI partial wheel constructor retained");if(!second_gui_ok||!observers(e)||!tree_capture(wheel_tree,0,e))return interrupted(e,"Weapon UI returned wheel tree unproved; retained");journal.wheel=3;
    if(!before_call(e))return false;journal.attach_wheel=1;if(!call_attach(ui+WHEEL))return interrupted(e,"Weapon UI wheel attachment interrupted");journal.attach_wheel=2;if(!before_call(e)||!tree_capture(wheel_tree,ui+0x820,e))return interrupted(e,"Weapon UI wheel attachment acknowledgement unavailable");if(!call_flush())return interrupted(e,"Weapon UI wheel layout flush interrupted");journal.attach_wheel=3;phase=Phase::WheelAttached;
    if(!before_call(e)||!roles(false,e)||!closed(e))return false;phase=Phase::RoleCalling;role_owned=true;journal.add=1;if(!call_context(true))return interrupted(e,"Weapon UI role8 acquisition interrupted");journal.add=2;if(!roles(true,e))return false;journal.add=3;active=true;phase=Phase::Active;e.clear();pending_error.clear();return true;
}
bool tick(float dt,uint32_t pid,uint32_t avatar,bool caller_ready,std::string& e){std::lock_guard<std::recursive_mutex> lock(mutex);if(!owned)return phase==Phase::Stopped;if(!caller_ready||pid!=target.pid||avatar!=target.avatar||!std::isfinite(dt)||dt<0||dt>1||!menu_clear()||now()>=deadline){expired=now()>=deadline;return cleanup(e);}if(phase==Phase::RetiredPending&&journal.generic_retired)return cleanup(e);if(phase!=Phase::Active||!active)return fail(e,"Weapon UI review is not active; use stop/read retained journal");if(!before_call(e)){active=false;phase=Phase::RetiredPending;return false;}if(!tree_present(wheel_tree,e)||!tree_present(sibling_tree,e))return cleanup(e);if(!roles(true,e)){active=false;phase=Phase::RetiredPending;return false;}if(!call_sibling_tick(dt))return interrupted(e,"Weapon UI sibling update interrupted; journal retained");if(!before_call(e)||!tree_present(wheel_tree,e)||!tree_present(sibling_tree,e)||!roles(true,e)){active=false;phase=Phase::RetiredPending;return false;}if(!call_wheel_tick(dt))return interrupted(e,"Weapon UI wheel update interrupted; journal retained");return true;}
bool stop(std::string& e){std::lock_guard<std::recursive_mutex> lock(mutex);if(phase==Phase::Stopped)return true;return cleanup(e);}
bool rearm(std::string& e){std::lock_guard<std::recursive_mutex> lock(mutex);
    if(phase!=Phase::Stopped||owned||active||role_owned||scope.pending()||journal.wheel!=4||journal.sibling!=4||journal.destroy_wheel!=3||journal.destroy_sibling!=3||journal.remove!=3)
        return fail(e,"Weapon UI rearm requires fully acknowledged stopped ownership");
    if(!before_call(e)||!roles(false,e)||!closed(e)||!empty(ui+WHEEL)||!empty(ui+SIBLING)||!tree_absent(wheel_tree)||!tree_absent(sibling_tree))
        return fail(e,"Weapon UI clean rearm preflight refused");
    journal={};wheel_tree={};sibling_tree={};scope={};aux_record=0;deadline=0;expired=false;exception={};phase=Phase::None;pending_error.clear();e.clear();return true;
}
Status status(){std::lock_guard<std::recursive_mutex> lock(mutex);return{phase,owned,active,role_owned,!owned&&!scope.pending(),owned||scope.pending(),expired};}
} // namespace bc::weapon_ui_review

namespace {std::string exported_error;}
extern "C" __declspec(dllexport) int BC_weapon_ui_start(uint32_t pid,uint32_t avatar,float seconds,uint32_t ready){auto game=reinterpret_cast<uintptr_t>(GetModuleHandleW(L"game.dll")),exe=reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));return bc::weapon_ui_review::start({game,exe,pid,avatar,GetCurrentThreadId()},seconds,ready==1,exported_error)?1:0;}
extern "C" __declspec(dllexport) int BC_weapon_ui_tick(float dt,uint32_t pid,uint32_t avatar,uint32_t ready){return bc::weapon_ui_review::tick(dt,pid,avatar,ready==1,exported_error)?1:0;}
extern "C" __declspec(dllexport) int BC_weapon_ui_stop(){return bc::weapon_ui_review::stop(exported_error)?1:0;}
extern "C" __declspec(dllexport) int BC_weapon_ui_rearm(){return bc::weapon_ui_review::rearm(exported_error)?1:0;}
extern "C" __declspec(dllexport) uint32_t BC_weapon_ui_phase(){return static_cast<uint32_t>(bc::weapon_ui_review::status().phase);}
extern "C" __declspec(dllexport) uint32_t BC_weapon_ui_flags(){auto s=bc::weapon_ui_review::status();return(s.owned?1U:0U)|(s.active?2U:0U)|(s.role8_owned?4U:0U)|(s.stopped?8U:0U)|(s.pending?16U:0U)|(s.expired?32U:0U);}
extern "C" __declspec(dllexport) const char* BC_weapon_ui_error(){if(exported_error.empty())exported_error=bc::weapon_ui_review::pending_error;return exported_error.c_str();}
