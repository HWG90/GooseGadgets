#include "weapon_menu.h"
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <vector>
#include <intrin.h>

namespace bc::weapon_menu { namespace {
constexpr uintptr_t UI=0x346D538,PM=0x3326D20,PLAYER=0x3326468,WORLD=0x346BF98,
    GS=0x3326340,GUI=0x347CE90,OBSERVER=0x3326E68,AUX=0x3326420;
constexpr uintptr_t WHEEL=0x257F78,SIBLING=0x3E8E38,MINIT=0x46D8F0,
    MACTIVE=0x24E398,SINIT=0x4F7078,SACTIVE=0x46D900,DROP=0x267658;
constexpr uint32_t owned_actions=0x08400000; // Native action86 (R) and91 (Drop).
using Void=void(__fastcall*)(void*);
using Attach=void(__fastcall*)(void*,void*);
using WheelCtor=void(__fastcall*)(void*,uint64_t,uint32_t);
using SiblingCtor=void(__fastcall*)(void*,uint32_t);
using DropCtor=void(__fastcall*)(void*,uint64_t,uint32_t,uint32_t,bool);
using VitalsCtor=void(__fastcall*)(void*,uint64_t,uint64_t,uint64_t,uint32_t);
using Material=uintptr_t(__fastcall*)(void*);
using WheelTick=void(__fastcall*)(void*,float,uint32_t,uint32_t);
using SiblingTick=void(__fastcall*)(void*,float,uint32_t);
using Context=void(__fastcall*)(void*,const uint64_t*);
using Alpha=void(__fastcall*)(void*,float);
using GuiDelete=void(__fastcall*)(void*,uintptr_t);
Identity target;Io io;Phase phase=Phase::None;
uintptr_t ui{},pm{},player{},world{},state{},gui{},observer{},aux{},descriptor{},pc{},
    registry{},generations{},units{},unit{},aux_record{};
uint32_t reference{},world_unit{};
std::array<uint8_t,16> descriptor_bytes{};
std::array<uint32_t,7> observer_counts{};
uint8_t ship_active{};
bool owned{},active{},role_owned{},retired{};
std::string pending_error;
std::recursive_mutex mutex;
struct Journal {uint8_t sibling{},wheel{},drop{},drop_orphan{},attach_sibling{},attach_wheel{},attach_drop{},add{},remove{},destroy_wheel{},destroy_sibling{},destroy_drop{},destroy_orphan{},retired_alpha{},retired_final{};bool generic_retired{};} journal;
struct Tree {uintptr_t base{},limit{};std::vector<uintptr_t> nodes;} wheel_tree,sibling_tree,drop_tree;
struct Vitals {Tree tree;uint8_t built{},attached{},destroyed{};};
std::array<Vitals,2> vitals;
VitalsCtor construct_health{},construct_stamina{};WheelTick update_health{},update_stamina{};
#ifdef BC_WEAPON_MENU_FIXTURE
bool enable_vitals{};
#else
constexpr bool enable_vitals=true;
#endif
constexpr uintptr_t HEALTH=0x24E340+0x60,STAMINA=0x24E340+0x5778;
std::vector<std::pair<uintptr_t,uint8_t>> retired_dirty_calls;
WheelCtor construct_wheel{};SiblingCtor construct_sibling{};WheelTick update_wheel{};
DropCtor construct_drop{};WheelTick update_drop{};Material get_material{};
SiblingTick update_sibling{};Attach attach{};Void flush{},destroy{};Context add_role{},remove_role{};Alpha set_alpha{};
struct Witness {uintptr_t node{},parent{},context{},renderer{};uintptr_t material{};} witness;
struct Barrier {uintptr_t engine{},api{},slot{};GuiDelete original{};bool installed{},inside{},seen{},cancelled{},restore_pending{};} barrier;
void __fastcall gui_delete_barrier(void*,uintptr_t);
#ifdef BC_WEAPON_MENU_PRIVATE_RECOVERY
uintptr_t recovery_expected_callback{};
#endif
#ifdef BC_WEAPON_MENU_FIXTURE
void(*fixture_bind)(){};
SIZE_T(*fixture_query)(LPCVOID,PMEMORY_BASIC_INFORMATION,SIZE_T){};
#endif
struct Exception {const char* operation{};DWORD code{};uintptr_t rip{},fault{};ULONG_PTR access{};bool has_fault{};} exception;
LONG capture_exception(EXCEPTION_POINTERS* p){if(p&&p->ContextRecord)exception.rip=static_cast<uintptr_t>(p->ContextRecord->Rip);if(p&&p->ExceptionRecord){auto r=p->ExceptionRecord;exception.code=r->ExceptionCode;if((r->ExceptionCode==EXCEPTION_ACCESS_VIOLATION||r->ExceptionCode==EXCEPTION_IN_PAGE_ERROR)&&r->NumberParameters>=2){exception.has_fault=true;exception.access=r->ExceptionInformation[0];exception.fault=r->ExceptionInformation[1];}}return EXCEPTION_EXECUTE_HANDLER;}
bool fail(std::string& e,const char* text){e=text;if(exception.code){char detail[256]{};const bool game=exception.rip>=target.game&&exception.rip-target.game<0x3500000;std::snprintf(detail,sizeof(detail),"; native_exception op=%s code=0x%08lx rip=0x%llx %s+0x%llx access=%s fault=0x%llx",exception.operation?exception.operation:"unknown",static_cast<unsigned long>(exception.code),static_cast<unsigned long long>(exception.rip),game?"game":"external",static_cast<unsigned long long>(game?exception.rip-target.game:exception.rip),exception.has_fault?(exception.access==0?"read":exception.access==1?"write":"execute"):"none",static_cast<unsigned long long>(exception.fault));e+=detail;}pending_error=e;return false;}
bool raw_read(uintptr_t p,void* out,size_t n){if(p<0x10000||n>65536||p>0x7FFFFFFFFFFFULL-n)return false;__try{std::memcpy(out,reinterpret_cast<void*>(p),n);return true;}__except(EXCEPTION_EXECUTE_HANDLER){return false;}}
bool raw_write(uintptr_t p,const void* from,size_t n){if(p<0x10000||n>64||p>0x7FFFFFFFFFFFULL-n)return false;__try{std::memcpy(reinterpret_cast<void*>(p),from,n);return std::memcmp(reinterpret_cast<void*>(p),from,n)==0;}__except(EXCEPTION_EXECUTE_HANDLER){return false;}}
template<class T>bool read(uintptr_t p,T& v){return(io.read?io.read:raw_read)(p,&v,sizeof(v));}
template<class T>T value(uintptr_t p,T fallback=T{}){T v{};return read(p,v)?v:fallback;}
template<class T>bool write(uintptr_t p,T v){return(io.write?io.write:raw_write)(p,&v,sizeof(v));}
bool module(uintptr_t p,uint32_t stamp){uint16_t mz{};int32_t pe{};uint32_t sig{},s{};return read(p,mz)&&mz==0x5A4D&&read(p+0x3C,pe)&&pe>=0x40&&pe<=0x1000&&read(p+pe,sig)&&sig==0x4550&&read(p+pe+8,s)&&s==stamp;}
SIZE_T query_memory(uintptr_t p,MEMORY_BASIC_INFORMATION& m){
#ifdef BC_WEAPON_MENU_FIXTURE
    if(fixture_query)return fixture_query(reinterpret_cast<void*>(p),&m,sizeof(m));
#endif
    return VirtualQuery(reinterpret_cast<void*>(p),&m,sizeof(m));
}
bool executable_region(const MEMORY_BASIC_INFORMATION& m){return m.State==MEM_COMMIT&&!(m.Protect&(PAGE_GUARD|PAGE_NOACCESS))&&(m.Protect&(PAGE_EXECUTE|PAGE_EXECUTE_READ|PAGE_EXECUTE_READWRITE|PAGE_EXECUTE_WRITECOPY));}
bool executable(uintptr_t p){MEMORY_BASIC_INFORMATION m{};return query_memory(p,m)&&executable_region(m);}
struct ExecutableProof {
    // This cache lives for ONE natives() validation, never across callbacks or
    // native calls. VirtualQuery describes every address inside one region.
    std::array<std::pair<uintptr_t,SIZE_T>,32> regions{};size_t count{};
    bool check(uintptr_t p){
        for(size_t i=0;i<count;++i)if(p>=regions[i].first&&p-regions[i].first<regions[i].second)return true;
        MEMORY_BASIC_INFORMATION m{};if(!query_memory(p,m)||!executable_region(m))return false;
        const auto base=reinterpret_cast<uintptr_t>(m.BaseAddress);
        if(p<base||p-base>=m.RegionSize)return false;
        if(count<regions.size())regions[count++]={base,m.RegionSize};
        return true;
    }
};
bool writable(uintptr_t p,size_t n){MEMORY_BASIC_INFORMATION m{};return VirtualQuery(reinterpret_cast<void*>(p),&m,sizeof(m))&&m.State==MEM_COMMIT&&!(m.Protect&(PAGE_GUARD|PAGE_NOACCESS))&&(m.Protect&(PAGE_READWRITE|PAGE_WRITECOPY|PAGE_EXECUTE_READWRITE|PAGE_EXECUTE_WRITECOPY))&&n<=m.RegionSize-(p-reinterpret_cast<uintptr_t>(m.BaseAddress));}
constexpr std::array<std::pair<uintptr_t,const char*>,36> abi{{
    {0x1816A60,"488bc4488958084889701048897818554154415541564157"},
    {0x181DE50,"488bc44889580848897010488978185541564157488d68a9"},
    {0x1819A70,"4c8bdc554155498dab38ffffff4881ecb8010000488b0585"},
    {0x181EB90,"4c8bdc53554881ecd8000000410f2973c8488b0568d4e100"},
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
    {0x1448870,"4053574883ec78f30f104144410fb6d90f2ec1488bf90f8a"},
    {0x137D500,"40554883ec3080b97897080000488be90f84d30600004889"},
    {0x137DA69,"488d4d08e8fe020d00488d8d"},
    {0x12F1540,"40554883ec3080b934e3240000488be90f84590400004889"},
    {0x1446A90,"40534883ec20448b09488bd9418bc1c1e806a8017450418b"},
    {0x144CBC0,"4154415641574883ec304c8bb9e0000000440fb6e24c8bf1"},
    {0x144F6E0,"8b01c1e81283e00f83c0fd83f80a77444c8d050909bbfe41"},
    {0xAB2FA0,"48895c240848896c241856574154415641574883ec308bda"},
    {0xAB309C,"899f1cc20a00"},
    {0x18298F0,"488bc4488958084889701048897818554154415541564157"},
    {0x182A550,"488bc4488958084889701048897818554154415541564157"},
    {0xA51CA0,"48895c24084889742410574883ec20410fb6f1488bda488b"},
    {0xA521F0,"41574883ec50488b05139ebe014833c448894424388b0144"},
    {0x182D0B0,"48895c2408574883ec6080b9d01c0000000fb6fa488bd90f"},
    {0x12E9F9C,"498d8f18930100c745d40000003f4533c9488b55d041b858"},
    {0x12EA8A7,"498d8e18930100e8bd341600498d8e20760100e8b1341600"},
    {0x12EC133,"498d8e18930100448bce448bc30f28cfe808e45300498d8e"},
    {0x1829B4C,"498d9f30030000488bcbe8554fc1ff4584ed0f84b5000000"},
    {0x143EAB0,"40534883ec20ba03000000488bd9e87d7d000048c7442430"}
}};
bool match(uintptr_t p,const char* h){
    constexpr size_t maximum=64;const auto digits=std::strlen(h);
    if(!digits||(digits&1)||digits/2>maximum)return false;
    std::array<uint8_t,maximum> bytes{};
    if(!(io.read?io.read:raw_read)(p,bytes.data(),digits/2))return false;
    auto digit=[](char c){return c>='0'&&c<='9'?c-'0':c-'a'+10;};
    for(size_t i=0;i<digits;i+=2)if(bytes[i/2]!=((digit(h[i])<<4)|digit(h[i+1])))return false;
    return true;
}
bool natives(std::string& e){if(GetCurrentThreadId()!=target.thread||!module(target.game,0x6AB3B43F)||!module(target.exe,0x6AB382E4))return fail(e,"Weapon UI thread/build identity changed");ExecutableProof executable_now;for(auto a:abi)if(!executable_now.check(target.game+a.first)||!match(target.game+a.first,a.second))return fail(e,"Weapon UI native fingerprint changed");return true;}
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
bool presentation(std::string& e,bool cleaning=false){uint32_t flags{};uintptr_t parent{},context{};uint8_t a{},b{},c{},d{};if(value<uintptr_t>(target.game+UI)!=ui||value<uintptr_t>(target.game+GUI)!=gui||value<uintptr_t>(target.game+GS)!=state||value<uint32_t>(state+0xAC21C)!=3||value<uint8_t>(ui+0x24E334)!=1||!read(ui+0x820,flags)||!(flags&1)||!read(ui+0x820+0xF0,parent)||parent!=ui+0x258||!read(ui+0x820+0xF8,context)||context!=gui+5*0x3698||!read(ui+MINIT,a)||a||!read(ui+MACTIVE,b)||b||!read(ui+SINIT,c)||c!=1||!read(ui+SACTIVE,d)||d>1||(!cleaning&&d!=ship_active))return fail(e,"Weapon UI bridge/root presentation changed; ownership retained");return observers(e);}
bool menu_clear(){const auto menu=value<uintptr_t>(target.game+0x347CE28);return menu&&value<uint32_t>(menu+0x4294,UINT32_MAX)==0&&value<uint32_t>(menu+0x4298,UINT32_MAX)==0;}
bool roles(bool on,std::string& e){uint64_t v{};return(read(pc+0xFD0,v)&&((v&8)!=0)==on)||fail(e,"Weapon UI role8 acknowledgement pending");}
bool closed(std::string& e){uint32_t v{};uint8_t aux_open{},drop_closed{};return(read(pc+0xFD8,v)&&!(v&owned_actions)&&aux_record&&read(aux_record+5,aux_open)&&aux_open==0&&(journal.drop!=3||(read(ui+DROP+0x1CD0,drop_closed)&&drop_closed==1)))||fail(e,"Weapon UI action86/91/auxiliary cancellation acknowledgement pending");}
struct GuiScope {int32_t before{},after{};uint8_t old{};uintptr_t slot{};bool depth_pending{},slot_pending{};
    bool pending()const{return depth_pending||slot_pending;}
    bool available(std::string& e){int32_t d{};return(read(gui+0x2C5BC,d)&&d>=-1&&d<=2&&writable(gui+0x2C5BC,4)&&writable(gui+0x2C5B8+static_cast<uintptr_t>(d+1),1))||fail(e,"Weapon UI renderer context5 stack unavailable");}
    bool restore(std::string& e){if(!pending())return true;if(value<uintptr_t>(target.game+GUI)!=gui)return fail(e,"Weapon UI GUI provider changed during scope");int32_t d{};if(!read(gui+0x2C5BC,d)||(d!=before&&d!=after))return fail(e,"Weapon UI GUI stack has foreign owner");if(slot_pending){uint8_t b{};if(!read(slot,b)||(b!=old&&b!=5))return fail(e,"Weapon UI GUI slot has foreign owner");if(b!=old&&!write(slot,old))return fail(e,"Weapon UI GUI slot restoration pending");slot_pending=false;}if(depth_pending){if(d!=before&&!write(gui+0x2C5BC,before))return fail(e,"Weapon UI GUI stack restoration pending");depth_pending=false;}return true;}
    bool enter(std::string& e){if(pending()||!available(e)||!read(gui+0x2C5BC,before))return false;after=before+1;slot=gui+0x2C5B8+static_cast<uintptr_t>(after);if(!read(slot,old))return fail(e,"Weapon UI GUI slot unreadable");depth_pending=true;if(!write(gui+0x2C5BC,after))return fail(e,"Weapon UI GUI push pending");slot_pending=true;return write(slot,uint8_t{5})||fail(e,"Weapon UI GUI context write pending");}
} scope;
bool before_call(std::string& e){return natives(e)&&actor(e)&&presentation(e);}
// Stock Ship active0/1 is presentation state. A change stops active updates,
// but must not prevent otherwise-proven cancellation and owned-tree cleanup.
// Providers, actor, initialized roots, parents, context and observers stay sealed.
bool before_cleanup(std::string& e){return natives(e)&&actor(e)&&presentation(e,true);}
bool empty(uintptr_t p){uint32_t f{};uintptr_t a{},b{},c{},d{},tween_a{},tween_b{};return read(p,f)&&f==0&&read(p+0xE0,a)&&!a&&read(p+0xE8,b)&&!b&&read(p+0xF0,c)&&!c&&read(p+0xF8,d)&&!d&&read(p+0xA8,tween_a)&&!tween_a&&read(p+0xB0,tween_b)&&!tween_b;}
bool tree_node(Tree& t,uintptr_t node,uintptr_t parent,std::string& e){if(t.nodes.size()>=512||node<t.base||node>t.limit-0x110)return fail(e,"Weapon UI child tree escaped component boundary");for(auto old:t.nodes)if(old==node)return fail(e,"Weapon UI child tree cycle/alias");uint32_t f{};uintptr_t p{},context{},child{};if(!read(node,f)||!(f&1)||!read(node+0xF0,p)||p!=parent||!read(node+0xF8,context)||context!=gui+5*0x3698||!read(node+0xE0,child))return fail(e,"Weapon UI complete child header/parent/context proof unavailable");t.nodes.push_back(node);while(child){uintptr_t next{};if(!read(child+0xE8,next)||!tree_node(t,child,node,e))return false;child=next;}return true;}
bool tree_capture(Tree& t,uintptr_t parent,std::string& e){t.nodes.clear();return tree_node(t,t.base,parent,e);}
bool tree_matches(const Tree& t,uintptr_t node,uintptr_t parent,size_t& cursor,std::string& e){
    if(cursor>=t.nodes.size()||node!=t.nodes[cursor++]||node<t.base||node>t.limit-0x110)return false;
    uint32_t flags{};uintptr_t actual_parent{},context{},child{};
    if(!read(node,flags)||!(flags&1)||!read(node+0xF0,actual_parent)||actual_parent!=parent||!read(node+0xF8,context)||context!=gui+5*0x3698||!read(node+0xE0,child))return false;
    while(child){uintptr_t next{};if(!read(child+0xE8,next)||!tree_matches(t,child,node,cursor,e))return false;child=next;}return true;
}
bool tree_present(const Tree& t,std::string& e){size_t cursor{};return(tree_matches(t,t.base,ui+0x820,cursor,e)&&cursor==t.nodes.size())||fail(e,"Weapon UI owned widget tree retired/changed; native calls withheld");}
bool tree_absent(const Tree& t){for(auto n:t.nodes)if(!empty(n))return false;return true;}
// Authored18298F0(type0,false) constructs these fixed nodes. Its eight icon
// images begin1208/stride158;182BAF0 assigns textures to those exact images.
constexpr std::array<uintptr_t,18> drop_nodes{{0,0x110,0x220,0x488,0x5E0,0x738,0x890,0xB40,0xC98,0xF50,
    0x1208,0x1360,0x14B8,0x1610,0x1768,0x18C0,0x1A18,0x1B70}};
constexpr std::array<uintptr_t,13> drop_images{{0x488,0x5E0,0x738,0x890,0xB40,
    0x1208,0x1360,0x14B8,0x1610,0x1768,0x18C0,0x1A18,0x1B70}};
bool drop_attached_empty(){for(auto off:drop_nodes)if(!empty(ui+DROP+off))return false;return true;}
bool drop_empty(){return drop_attached_empty()&&empty(ui+DROP+0x330);}
// 1829B4C constructs this type3 primitive UNCONDITIONALLY. The false
// fifth argument skips its material/attachment, not its construction. It is
// not a descendant of Drop and root-recursive teardown cannot own it for us.
bool drop_orphan_present(){
    const auto n=ui+DROP+0x330;uint32_t flags{},index{};uint64_t dimensions{};
    for(unsigned seal=0;seal<2;++seal){
        if(!read(n,flags)||(flags&~4U)!=0xC0011||value<uintptr_t>(n+0xF8)!=gui+5*0x3698||
           !read(n+0x110,index)||index!=UINT32_MAX||!read(n+0x11C,dimensions)||dimensions!=0x3F8000003F800000ULL)return false;
        for(uintptr_t off:{0xA8ULL,0xB0ULL,0xE0ULL,0xE8ULL,0xF0ULL,0x100ULL,0x108ULL,0x114ULL,0x148ULL,0x150ULL}){
            uintptr_t v{};if(!read(n+off,v)||v)return false;
        }
    }
    return true;
}
bool drop_geometry(std::string& e){
    if(value<uint32_t>(ui+DROP+0x1CE0,UINT32_MAX)!=0||value<uint8_t>(ui+DROP+0x1CD0,2)>1||value<uint8_t>(ui+DROP+0x1CF0,1)!=0||!drop_orphan_present())return fail(e,"Weapon UI Drop type/state/detached primitive acknowledgement unavailable");
    for(auto off:drop_nodes){bool found=false;for(auto n:drop_tree.nodes)if(n==ui+DROP+off){found=true;break;}if(!found)return fail(e,"Weapon UI authored Drop child missing");
        if(off){const bool root_child=off==0x110||off==0x220;const bool outer=off==0x488||off==0x738||off==0xB40||off==0xC98||off==0xF50;
            if(value<uintptr_t>(ui+DROP+off+0xF0)!=ui+DROP+(root_child?0:outer?0x220:0x110))return fail(e,"Weapon UI authored Drop child parent changed");}}
    return true;
}
// This is positive generic retirement, not a missing/changed-tree heuristic.
// Generic1446B00 clears these fields but leaves geometry, alpha44 and BCD0.
bool retired_node(uintptr_t n,bool alpha_dirty){uint32_t flags{};if(!read(n,flags)||(flags!=0&&(!alpha_dirty||flags!=4)))return false;for(uintptr_t off:{0xA8ULL,0xB0ULL,0xE0ULL,0xE8ULL,0xF0ULL,0xF8ULL,0x100ULL,0x108ULL}){uintptr_t v{};if(!read(n+off,v)||v)return false;}return true;}
bool retired_root_clear(std::vector<uintptr_t>& found,std::string& e){uintptr_t n{};if(!read(ui+0x820+0xE0,n))return fail(e,"Weapon UI current root children unreadable");while(n){if(found.size()>=1024||n==ui+WHEEL||n==ui+SIBLING||n==ui+DROP)return fail(e,"Weapon UI retired component still linked to current root");for(auto old:found)if(old==n)return fail(e,"Weapon UI current root child cycle");uint32_t flags{};uintptr_t parent{},context{},next{};if(!read(n,flags)||!(flags&1)||!read(n+0xF0,parent)||parent!=ui+0x820||!read(n+0xF8,context)||context!=gui+5*0x3698||!read(n+0xE8,next))return fail(e,"Weapon UI current root child ownership opaque");found.push_back(n);n=next;}return true;}
bool vitals_present(std::string& e){for(auto& v:vitals)if(v.built==3&&!tree_present(v.tree,e))return false;return true;}
bool vitals_retired(){for(auto& v:vitals)if(v.built==3)for(auto node:v.tree.nodes)if(!retired_node(node,false))return false;return true;}
bool retired_trees(bool alpha_dirty,std::string& e){if(!vitals_retired())return fail(e,"Native vitals retirement is incomplete");if(wheel_tree.nodes.empty()||sibling_tree.nodes.empty()||drop_tree.nodes.empty())return fail(e,"Weapon UI captured retirement tree unavailable");std::vector<uintptr_t> first;for(unsigned seal=0;seal<2;++seal){for(const auto* t:{&wheel_tree,&sibling_tree,&drop_tree})for(auto n:t->nodes)if(!retired_node(n,alpha_dirty&&n==ui+WHEEL))return fail(e,"Weapon UI retirement is partial, opaque or foreign; no late cancellation");std::vector<uintptr_t> current;if(!retired_root_clear(current,e))return false;if(seal&&first!=current)return fail(e,"Weapon UI root children changed during retirement proof");first=std::move(current);}return true;}
void begin(const char* op){exception={};exception.operation=op;}
bool call_ctor(bool wheel){begin(wheel?"wheel_ctor":"sibling_ctor");__try{if(wheel)construct_wheel(reinterpret_cast<void*>(ui+WHEEL),0x3F0000003F000000ULL,0x258);else construct_sibling(reinterpret_cast<void*>(ui+SIBLING),0x1F4);return true;}__except(capture_exception(GetExceptionInformation())){return false;}}
bool call_drop_ctor(){begin("drop_ctor");__try{construct_drop(reinterpret_cast<void*>(ui+DROP),0x3F0000003F000000ULL,0x258,0,false);return true;}__except(capture_exception(GetExceptionInformation())){return false;}}
bool call_drop_materials(){begin("drop_material_guard");__try{for(auto off:drop_images)if(!get_material(reinterpret_cast<void*>(ui+DROP+off)))return false;return true;}__except(capture_exception(GetExceptionInformation())){return false;}}
bool call_attach(uintptr_t node){begin("attach");__try{attach(reinterpret_cast<void*>(ui+0x820),reinterpret_cast<void*>(node));return true;}__except(capture_exception(GetExceptionInformation())){return false;}}
bool call_flush(){begin("layout_flush");__try{flush(reinterpret_cast<void*>(ui+0x820));return true;}__except(capture_exception(GetExceptionInformation())){return false;}}
bool call_context(bool on){begin(on?"role8_add":"role8_remove");alignas(16)const uint64_t mask[3]={8,0,0};__try{(on?add_role:remove_role)(reinterpret_cast<void*>(pc+0x50),mask);return true;}__except(capture_exception(GetExceptionInformation())){return false;}}
// Only ordinary writable DATA is accepted. This owner never changes a page's
// protection and never patches an instruction or executable table allocation.
bool writable_data(uintptr_t p,size_t n){MEMORY_BASIC_INFORMATION m{};if(!VirtualQuery(reinterpret_cast<void*>(p),&m,sizeof(m))||m.State!=MEM_COMMIT||m.Protect&(PAGE_GUARD|PAGE_NOACCESS))return false;const DWORD protection=m.Protect&0xFF;return(protection==PAGE_READWRITE||protection==PAGE_WRITECOPY)&&p>=reinterpret_cast<uintptr_t>(m.BaseAddress)&&n<=m.RegionSize-(p-reinterpret_cast<uintptr_t>(m.BaseAddress));}
bool common_listener(std::string& e){uint32_t count{};if(value<uintptr_t>(target.game+OBSERVER)!=observer||!read(observer+0x2440,count)||!count||count>6)return fail(e,"Weapon menu common UI observer table unavailable");unsigned found=0;for(uint32_t i=0;i<count;++i){uintptr_t object{};uint32_t type{};const auto row=observer+0x2448+static_cast<uintptr_t>(i)*16;if(!read(row,object)||!read(row+8,type))return fail(e,"Weapon menu common UI observer row unreadable");if(object==ui&&type==0x108)++found;}uint32_t seal{};return(read(observer+0x2440,seal)&&seal==count&&found==1)||fail(e,"Weapon menu requires exactly one stock common UI listener");}
bool read_witness(Witness& out,bool deleting=false){
    out.node=ui+0x46D900+0x490;out.parent=ui+0x46D900+0x228;uint32_t flags{};uintptr_t parent{};
    if(!read(out.node,flags)||!(flags&1)||((flags>>18)&15)!=3||(flags&0x10040)!=0x40||!read(out.node+0xF0,parent)||(parent!=out.parent&&(!deleting||parent))||!read(out.node+0xF8,out.context)||out.context!=gui+5*0x3698||!read(out.context+8,out.renderer)||!out.renderer||!read(out.node+0x148,out.material)||!out.material)return false;
    if(deleting)return true;
    // Seal the stock Ship subtree membership before enabling8. Generic child
    // retirement can already unlink this node before its248 callback; only the
    // exact owned material/context/type predicate is required inside that call.
    const auto root=ui+0x46D900+8;std::vector<uintptr_t> seen;
    while(parent){if(seen.size()>=32)return false;for(auto old:seen)if(old==parent)return false;seen.push_back(parent);uint32_t f{};uintptr_t context{},next{};if(!read(parent,f)||!(f&1)||!read(parent+0xF8,context)||context!=out.context)return false;if(parent==root)return true;if(!read(parent+0xF0,next))return false;parent=next;}return false;
}
bool same_witness(const Witness& a,const Witness& b){return a.node==b.node&&a.parent==b.parent&&a.context==b.context&&a.renderer==b.renderer&&a.material==b.material;}
bool barrier_provider(){uintptr_t engine{},api{};return read(target.game+0x3326308,engine)&&engine==barrier.engine&&read(engine+0xD0,api)&&api==barrier.api;}
bool barrier_owned(std::string& e){uintptr_t current{};
#ifdef BC_WEAPON_MENU_PRIVATE_RECOVERY
    const auto expected=recovery_expected_callback;
#else
    const auto expected=reinterpret_cast<uintptr_t>(&gui_delete_barrier);
#endif
    return(barrier.installed&&barrier_provider()&&read(barrier.slot,current)&&current==expected)||fail(e,"Weapon menu GUI data callback ownership changed");}
bool barrier_prepare(std::string& e){
    barrier.engine=value<uintptr_t>(target.game+0x3326308);barrier.api=value<uintptr_t>(barrier.engine+0xD0);barrier.slot=barrier.api+0x248;uintptr_t original{};
    if(!barrier.engine||!barrier.api||(barrier.slot&7)||!writable_data(barrier.slot,sizeof(uintptr_t))||!read(barrier.slot,original)||!original||!executable(original)||!common_listener(e)||!read_witness(witness))return fail(e,"Weapon menu writable GUI callback/witness preflight refused");
#ifndef BC_WEAPON_MENU_FIXTURE
    // Parent-owned fresh current-build capture fixes this normal GUI release
    // thunk; unknown targets refuse before any callback or widget mutation.
    constexpr uintptr_t gui_delete_rva=0x341E60;
    constexpr const char* gui_delete_fp="e98b1cf2ffcccccccccccccccccccccc4883ec28e80756f2";
    if(original!=target.exe+gui_delete_rva||!match(original,gui_delete_fp)||!executable(target.exe+0x263AF0)||!match(target.exe+0x263AF0,"405356574883ec30488b8180000000be0800000048896c2450488bfa488be94c"))return fail(e,"Weapon menu exact GUI release thunk/body differs");
#endif
    Witness seal{};if(!read_witness(seal)||!same_witness(witness,seal))return fail(e,"Weapon menu stock witness changed during preflight");barrier.original=reinterpret_cast<GuiDelete>(original);return true;
}
bool barrier_install(std::string& e){if(barrier.installed)return barrier_owned(e);if(!barrier_provider()||!writable_data(barrier.slot,8))return fail(e,"Weapon menu GUI callback data is no longer writable");
#ifndef BC_WEAPON_MENU_FIXTURE
    HMODULE self{};if(!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_PIN,reinterpret_cast<LPCWSTR>(&gui_delete_barrier),&self))return fail(e,"Weapon menu native callback module pin failed");
#endif
    const auto previous=InterlockedCompareExchangePointer(reinterpret_cast<void* volatile*>(barrier.slot),reinterpret_cast<void*>(&gui_delete_barrier),reinterpret_cast<void*>(barrier.original));if(previous!=reinterpret_cast<void*>(barrier.original))return fail(e,"Weapon menu GUI callback compare-owned acquisition refused");barrier.installed=true;return barrier_owned(e);
}
bool barrier_restore(std::string& e){if(!barrier.installed)return true;if(!barrier_provider()||!writable_data(barrier.slot,8))return fail(e,"Weapon menu GUI callback restoration provider unavailable");barrier.restore_pending=true;const auto previous=InterlockedCompareExchangePointer(reinterpret_cast<void* volatile*>(barrier.slot),reinterpret_cast<void*>(barrier.original),reinterpret_cast<void*>(&gui_delete_barrier));if(previous!=reinterpret_cast<void*>(&gui_delete_barrier))return fail(e,"Weapon menu GUI callback restoration has a foreign owner");barrier.installed=false;barrier.restore_pending=false;return true;}
bool barrier_cancel(std::string& e){
    // ShipDestroy removes its own observer rows before this deletion. Do not
    // demand the old observer counts or mutate any tree from this callback.
    if(!natives(e)||!actor(e)||value<uintptr_t>(target.game+UI)!=ui||value<uintptr_t>(target.game+GUI)!=gui||value<uintptr_t>(target.game+GS)!=state||value<uint32_t>(state+0xAC21C)!=3||value<uint8_t>(ui+0x24E334)!=1||value<uint8_t>(ui+MINIT)||value<uint8_t>(ui+SINIT)!=1||!tree_present(wheel_tree,e)||!tree_present(sibling_tree,e)||!tree_present(drop_tree,e)||!drop_geometry(e)||!vitals_present(e))return fail(e,"Weapon menu early UI barrier could not prove its live owner");
    if(role_owned){if(journal.remove==0){journal.remove=1;if(!call_context(false)){phase=Phase::Interrupted;return fail(e,"Weapon menu early native cancellation interrupted");}journal.remove=2;}if(journal.remove==1)return fail(e,"Weapon menu early cancellation result unknown");if(!roles(false,e)||!closed(e))return false;journal.remove=3;role_owned=false;}else if(!roles(false,e)||!closed(e))return false;
    barrier.cancelled=true;active=false;phase=Phase::Stopping;return true;
}
void __fastcall gui_delete_barrier(void* renderer,uintptr_t material){
    // This is one compare-owned service callback DATA slot, not a code hook.
    // Forward exactly once with unchanged arguments, including during recursion.
    const GuiDelete original=barrier.original;
    {std::lock_guard<std::recursive_mutex> lock(mutex);
        if(barrier.installed&&!barrier.inside&&owned&&role_owned&&reinterpret_cast<uintptr_t>(renderer)==witness.renderer&&material==witness.material){
            barrier.inside=true;barrier.seen=true;active=false;Witness current{};std::string e;
            if(GetCurrentThreadId()!=target.thread||!barrier_owned(e)||!read_witness(current,true)||!same_witness(witness,current)||!barrier_cancel(e)){if(phase!=Phase::Interrupted)phase=Phase::RetiredPending;fail(e,"Weapon menu early UI barrier acknowledgement pending");}
            barrier.inside=false;
        }
    }
    if(original)original(renderer,material);
}
bool call_sibling_tick(float dt){begin("sibling_tick");__try{update_sibling(reinterpret_cast<void*>(ui+SIBLING),dt,target.pid);return true;}__except(capture_exception(GetExceptionInformation())){return false;}}
bool call_wheel_tick(float dt){begin("wheel_tick");__try{update_wheel(reinterpret_cast<void*>(ui+WHEEL),dt,target.pid,target.avatar);return true;}__except(capture_exception(GetExceptionInformation())){return false;}}
bool call_destroy(uintptr_t node){begin(node==ui+WHEEL?"wheel_destroy":node==ui+SIBLING?"sibling_destroy":node==ui+DROP?"drop_destroy":node==ui+DROP+0x330?"drop_detached_primitive_destroy":"retired_dirty_node_destroy");__try{destroy(reinterpret_cast<void*>(node));return true;}__except(capture_exception(GetExceptionInformation())){return false;}}
bool call_drop_tick(float dt){begin("drop_tick");__try{update_drop(reinterpret_cast<void*>(ui+DROP),dt,target.pid,target.avatar);return true;}__except(capture_exception(GetExceptionInformation())){return false;}}
bool call_alpha_zero(){begin("retired_wheel_alpha_zero");__try{set_alpha(reinterpret_cast<void*>(ui+WHEEL),0.0f);return true;}__except(capture_exception(GetExceptionInformation())){return false;}}
bool call_vitals_ctor(unsigned index){begin(index?"native_stamina_ctor":"native_health_ctor");__try{
    if(index)construct_stamina(reinterpret_cast<void*>(ui+STAMINA),0x4280000000000000ULL,0x3F000000ULL,0x3F000000ULL,0x226);
    else construct_health(reinterpret_cast<void*>(ui+HEALTH),0,0,0,0x226);
    return true;}__except(capture_exception(GetExceptionInformation())){return false;}}
bool call_vitals_tick(unsigned index,float dt){begin(index?"native_stamina_tick":"native_health_tick");__try{(index?update_stamina:update_health)(reinterpret_cast<void*>(ui+(index?STAMINA:HEALTH)),dt,target.pid,target.avatar);return true;}__except(capture_exception(GetExceptionInformation())){return false;}}
bool interrupted(std::string& e,const char* message){phase=Phase::Interrupted;active=false;return fail(e,message);}
bool drop_orphan_absent(){return retired_node(ui+DROP+0x330,false)&&value<uintptr_t>(ui+DROP+0x330+0x148,UINTPTR_MAX)==0&&value<uintptr_t>(ui+DROP+0x330+0x150,UINTPTR_MAX)==0;}
// Callers must first prove their current same-actor cleanup gate, or the
// sealed fresh-actor/old-Unit-retirement gate. This helper never calls an actor.
bool cleanup_drop_orphan(std::string& e){
    if(journal.drop_orphan==0||journal.drop_orphan==4)return true;
    if(journal.drop_orphan!=3)return fail(e,"Weapon UI detached Drop primitive ownership unproved");
    if(journal.destroy_orphan==1)return interrupted(e,"Weapon UI detached Drop primitive destruction result unknown");
    if(journal.destroy_orphan==0){
        if(drop_orphan_absent()){journal.destroy_orphan=3;journal.drop_orphan=4;return true;}
        if(!drop_orphan_present())return fail(e,"Weapon UI detached Drop primitive changed; no guessed teardown");
        journal.destroy_orphan=1;
        if(!call_destroy(ui+DROP+0x330))return interrupted(e,"Weapon UI detached Drop primitive teardown interrupted; no replay");
        journal.destroy_orphan=2;
    }
    if(!drop_orphan_absent())return fail(e,"Weapon UI detached Drop primitive teardown acknowledgement pending");
    journal.destroy_orphan=3;journal.drop_orphan=4;return true;
}
bool cleanup_retired(std::string& e){
    // Current initialized ship roots, no Mission owner, and the same sole actor
    // remain mandatory. A scene change or replacement never removes native8.
    if(!before_cleanup(e)||!retired_trees(journal.retired_alpha>=2,e))return false;
    // Unlike the proved alpha0 R-close route, Drop close can touch retired
    // containers. An open91 must have been cancelled by the EARLY live barrier.
    if(value<uint32_t>(pc+0xFD8,owned_actions)&0x08000000)return fail(e,"Weapon UI retired Drop action91 cannot be cancelled late");
    uint8_t custom_closed{},aux_open{};uint32_t action{};float alpha{};
    if(!read(ui+WHEEL+0xBCD0,custom_closed)||custom_closed>1||!read(aux_record+5,aux_open)||aux_open>1||!read(pc+0xFD8,action)||!read(ui+WHEEL+0x44,alpha)||!std::isfinite(alpha)||alpha<0||alpha>1||
       (custom_closed&&aux_open)||(!custom_closed&&!(action&0x400000)))
        return fail(e,"Weapon UI retired custom/action/auxiliary state inconsistent");
    // A normal engine cancellation may already have ended our bit. Never
    // publish another removal merely to obtain a close side effect.
    if(journal.retired_alpha==0&&!roles(true,e)){
        if(!closed(e))return false;
        if(!before_cleanup(e)||!cleanup_drop_orphan(e))return false;
        journal.generic_retired=true;journal.remove=3;role_owned=false;
        journal.destroy_wheel=journal.destroy_sibling=journal.destroy_drop=3;journal.wheel=journal.sibling=journal.drop=4;
        owned=false;phase=Phase::Stopped;pending_error.clear();e.clear();return true;
    }
    journal.generic_retired=true;phase=Phase::Stopping;
    if(journal.retired_alpha==0){
        if(!role_owned||journal.remove!=0||!before_cleanup(e)||!retired_trees(false,e))return fail(e,"Weapon UI retired alpha acquisition refused");
        journal.retired_alpha=1;
        if(!call_alpha_zero())return interrupted(e,"Weapon UI retired alpha setter interrupted; no replay");
        journal.retired_alpha=2;
    }
    if(journal.retired_alpha==1)return interrupted(e,"Weapon UI retired alpha result unknown");
    if(!before_cleanup(e)||!retired_trees(true,e)||!read(ui+WHEEL+0x44,alpha)||alpha!=0.0f)return fail(e,"Weapon UI retired alpha acknowledgement pending");
    journal.retired_alpha=3;
    // At alpha0 with no animation handles, authored1828A70's1450DD0 takes the
    // no-allocation return1450F13. Do not write its custom closed byte.
    if(role_owned){
        if(journal.remove==0){if(!before_cleanup(e)||!retired_trees(true,e))return false;journal.remove=1;if(!call_context(false))return interrupted(e,"Weapon UI retired local cancellation interrupted");journal.remove=2;}
        if(journal.remove==1)return interrupted(e,"Weapon UI retired cancellation result unknown");
        if(!roles(false,e)||!closed(e)||!read(ui+WHEEL+0xBCD0,custom_closed)||custom_closed!=1)return fail(e,"Weapon UI retired authored close acknowledgement pending");
        journal.remove=3;role_owned=false;
    }
    if(!before_cleanup(e)||!roles(false,e)||!closed(e)||!retired_trees(true,e))return false;
    // Alpha setter can introduce only dirty flag4 into the empty root. The
    // native generic destructor on flags4/no links/no handles clears that bit;
    // no child, context or animation resource path is reachable.
    uint32_t flags{};if(!read(ui+WHEEL,flags))return fail(e,"Weapon UI retired dirty flag unreadable");
    if(journal.retired_final==0&&flags==4){journal.retired_final=1;if(!call_destroy(ui+WHEEL))return interrupted(e,"Weapon UI retired dirty normalization interrupted");journal.retired_final=2;}
    if(journal.retired_final==1)return interrupted(e,"Weapon UI retired normalization result unknown");
    if(!before_cleanup(e)||!retired_trees(false,e)||!roles(false,e)||!closed(e)||!scope.restore(e))return fail(e,"Weapon UI retired final acknowledgement pending");
    if(!before_cleanup(e)||!cleanup_drop_orphan(e))return false;
    journal.retired_final=3;journal.destroy_wheel=journal.destroy_sibling=journal.destroy_drop=3;journal.wheel=journal.sibling=journal.drop=4;
    owned=false;phase=Phase::Stopped;pending_error.clear();e.clear();return true;
}
bool cleanup_widgets(std::string& e){active=false;if(!owned)return scope.restore(e);if(phase==Phase::Interrupted)return fail(e,"Weapon UI interrupted native stage retained; no replay/guessed teardown");if(!before_cleanup(e)||!scope.restore(e)){phase=Phase::RetiredPending;return false;}phase=Phase::Stopping;
    if(journal.generic_retired||((journal.wheel==3&&journal.destroy_wheel==0&&!tree_present(wheel_tree,e))||(journal.sibling==3&&journal.destroy_sibling==0&&!tree_present(sibling_tree,e))||(journal.drop==3&&journal.destroy_drop==0&&!tree_present(drop_tree,e)))){if(cleanup_retired(e))return true;if(phase!=Phase::Interrupted)phase=Phase::RetiredPending;return false;}
    if(journal.drop==3&&journal.destroy_drop==0&&!drop_geometry(e))return false;
    if(role_owned){if(journal.remove==0){if(!before_cleanup(e))return false;journal.remove=1;if(!call_context(false))return interrupted(e,"Weapon UI local cancellation interrupted; owner retained");journal.remove=2;}if(!roles(false,e)||!closed(e))return false;journal.remove=3;role_owned=false;}
    else if(!roles(false,e)||!closed(e))return false;
    for(size_t i=vitals.size();i>0;--i){auto& v=vitals[i-1];if(v.built==3){if(v.destroyed==0){if(!before_cleanup(e)||!tree_present(v.tree,e))return false;v.destroyed=1;if(!call_destroy(v.tree.base))return interrupted(e,"Native vitals teardown interrupted; no replay");v.destroyed=2;}if(!tree_absent(v.tree))return fail(e,"Native vitals teardown acknowledgement pending");v.destroyed=3;v.built=4;}}
    // Reverse construction order, after BOTH native open actions acknowledge
    // cancellation while all of their widgets are still live.
    if(journal.drop==3){if(journal.destroy_drop==0){if(!before_cleanup(e))return false;journal.destroy_drop=1;if(!call_destroy(ui+DROP))return interrupted(e,"Weapon UI recursive Drop teardown interrupted");journal.destroy_drop=2;}if(!tree_absent(drop_tree))return fail(e,"Weapon UI Drop teardown acknowledgement pending");journal.destroy_drop=3;journal.drop=4;}
    if(!before_cleanup(e)||!cleanup_drop_orphan(e))return false;
    if(journal.wheel==3){if(journal.destroy_wheel==0){if(!before_cleanup(e))return false;journal.destroy_wheel=1;if(!call_destroy(ui+WHEEL))return interrupted(e,"Weapon UI recursive wheel teardown interrupted");journal.destroy_wheel=2;}if(!tree_absent(wheel_tree))return fail(e,"Weapon UI wheel teardown acknowledgement pending");journal.destroy_wheel=3;journal.wheel=4;}
    if(journal.sibling==3){if(journal.destroy_sibling==0){if(!before_cleanup(e))return false;journal.destroy_sibling=1;if(!call_destroy(ui+SIBLING))return interrupted(e,"Weapon UI recursive sibling teardown interrupted");journal.destroy_sibling=2;}if(!tree_absent(sibling_tree))return fail(e,"Weapon UI sibling teardown acknowledgement pending");journal.destroy_sibling=3;journal.sibling=4;}
    if(!roles(false,e)||!closed(e)||!observers(e)||!scope.restore(e))return false;owned=false;phase=Phase::Stopped;pending_error.clear();e.clear();return true;
}
bool original_retired(){
    const uint32_t index=reference&0x3FFFFF;uintptr_t root{},g{},u{},slot{},r2{},g2{},u2{},slot2{};uint32_t count{},count2{};uint8_t gen{},gen2{};
    if(!read(target.exe+0x1A100F0,root)||root!=registry||!read(root+0xA0,g)||!g||!read(root+0x88,u)||!u||!read(root+0x98,count)||!count||count>0x400000||index>=count||!read(g+index,gen)||!read(u+static_cast<uintptr_t>(index)*8,slot))return false;
    if(!read(target.exe+0x1A100F0,r2)||r2!=root||!read(root+0xA0,g2)||g2!=g||!read(root+0x88,u2)||u2!=u||!read(root+0x98,count2)||count2!=count||!read(g+index,gen2)||gen2!=gen||!read(u+static_cast<uintptr_t>(index)*8,slot2)||slot2!=slot)return false;
    return gen!=(reference>>22)||slot!=unit;
}
struct Fresh {uintptr_t manager{},descriptor{},control{},unit{},auxrow{},generations{},units{};uint32_t pid{},avatar{},reference{},count{};uint64_t roles{};uint32_t actions{};uint8_t auxopen{},generation{};
    bool operator==(const Fresh& b)const{return manager==b.manager&&descriptor==b.descriptor&&control==b.control&&unit==b.unit&&auxrow==b.auxrow&&generations==b.generations&&units==b.units&&pid==b.pid&&avatar==b.avatar&&reference==b.reference&&count==b.count&&roles==b.roles&&actions==b.actions&&auxopen==b.auxopen&&generation==b.generation;}
};
bool fresh_actor(Fresh& f){
    uintptr_t pl{},wrld{},local{},auxiliary{},records{};uint32_t row{},worldid{},worldrow{},auxrow{};uint8_t live{};
    if(!read(target.game+PM,f.manager)||!f.manager||value<uint32_t>(f.manager+0x70)!=1||!read(f.manager+0x110,f.descriptor)||!f.descriptor||!read(f.descriptor+8,f.avatar)||!f.avatar||f.avatar==UINT32_MAX||!read(f.descriptor+12,f.reference)||!f.reference||f.reference==reference||!read(f.descriptor+20,live)||!(live&1)||!map(f.manager+0xF8,f.avatar,row)||row!=0)return false;
    f.control=f.manager+0x53D8B0;
    if(!read(target.game+PLAYER,pl)||!pl||value<uint32_t>(pl+0x88)!=1||!read(pl+0xE8,local)||!local||!read(local+8,f.pid)||!f.pid||f.pid==UINT32_MAX||!map(pl+0xD0,f.pid,row)||row>=128||!read(pl+0x3A8+static_cast<uintptr_t>(row)*0x20,worldid)||!worldid||!read(target.game+WORLD,wrld)||!wrld||!map(wrld+0xF22EC8,worldid,worldrow)||worldrow>=0x100000||value<uint32_t>(wrld+0xF32F18+static_cast<uintptr_t>(worldrow)*24+8)!=f.avatar)return false;
    if(value<uintptr_t>(target.exe+0x1A100F0)!=registry||!read(registry+0xA0,f.generations)||!f.generations||!read(registry+0x88,f.units)||!f.units||!read(registry+0x98,f.count)||!f.count||f.count>0x400000)return false;
    const uint32_t index=f.reference&0x3FFFFF;
    if(index>=f.count||!read(f.generations+index,f.generation)||f.generation!=(f.reference>>22)||!read(f.units+static_cast<uintptr_t>(index)*8,f.unit)||!f.unit||value<uint32_t>(f.unit+8)!=f.reference||!read(f.control+0xFD0,f.roles)||!read(f.control+0xFD8,f.actions)||!read(target.game+AUX,auxiliary)||!auxiliary||!map(auxiliary+0x30,f.avatar,auxrow)||auxrow>=0x100000||!read(auxiliary+0x58,records)||!records)return false;
    f.auxrow=records+static_cast<uintptr_t>(auxrow)*0x20;return read(f.auxrow+5,f.auxopen)&&f.auxopen<=1;
}
bool current_root(bool require_components){
    const auto root=ui+0x820;uint32_t f{};uintptr_t parent{},context{},node{};
    if(!read(root,f)||!(f&1)||!read(root+0xF0,parent)||parent!=ui+0x258||!read(root+0xF8,context)||context!=gui+5*0x3698||!read(root+0xE0,node))return false;
    std::vector<uintptr_t> seen;unsigned wheel=0,sibling=0,drop=0;
    while(node){if(seen.size()>=1024)return false;for(auto old:seen)if(old==node)return false;seen.push_back(node);if(!read(node,f)||!(f&1)||!read(node+0xF0,parent)||parent!=root||!read(node+0xF8,context)||context!=gui+5*0x3698)return false;if(node==ui+WHEEL)++wheel;if(node==ui+SIBLING)++sibling;if(node==ui+DROP)++drop;if(!read(node+0xE8,node))return false;}
    return require_components?(wheel==1&&sibling==1&&drop==1):(wheel==0&&sibling==0&&drop==0);
}
bool normal_mission(std::string& e){
    if(value<uint32_t>(state+0xAC21C)!=4||value<uint8_t>(ui+0x24E334)!=1||value<uint8_t>(ui+MINIT)!=1||value<uint8_t>(ui+SINIT)!=0||value<uintptr_t>(target.game+OBSERVER)!=observer||!current_root(true))return false;
    Tree a,b,c;a.base=ui+WHEEL;a.limit=a.base+0xBCF0;b.base=ui+SIBLING;b.limit=b.base+0x20B8;c.base=ui+DROP;c.limit=c.base+0x1CF8;if(!tree_capture(a,ui+0x820,e)||!tree_capture(b,ui+0x820,e)||!tree_capture(c,ui+0x820,e)||!drop_orphan_present())return false;
    constexpr uint32_t capacity[4]={2,39,2,2};for(size_t list=0;list<4;++list){uint32_t count{};if(!read(observer+count_offsets[list],count)||!count||count>capacity[list])return false;unsigned found=0;for(uint32_t row=0;row<count;++row){uintptr_t object{};uint32_t type{};const auto at=observer+count_offsets[list]+8+static_cast<uintptr_t>(row)*16;if(!read(at,object)||!read(at+8,type))return false;if(object==ui+0x24E340&&type==0x106)++found;}if(found!=1||value<uint32_t>(observer+count_offsets[list])!=count)return false;}return true;
}
bool retired_dirty_gate(const Fresh& expected,std::string& e){
    Fresh a{},b{};
    return phase!=Phase::Interrupted&&!scope.pending()&&natives(e)&&original_retired()&&value<uintptr_t>(target.game+UI)==ui&&value<uintptr_t>(target.game+GUI)==gui&&value<uintptr_t>(target.game+GS)==state&&value<uint32_t>(state+0xAC21C)==3&&value<uint8_t>(ui+0x24E334)==1&&value<uint8_t>(ui+MINIT)==0&&value<uint8_t>(ui+MACTIVE)==0&&value<uint8_t>(ui+SINIT)==1&&barrier_owned(e)&&current_root(false)&&fresh_actor(a)&&fresh_actor(b)&&a==b&&a==expected&&!(a.roles&8)&&!(a.actions&owned_actions)&&a.auxopen==0;
}
bool normalize_retired_dirty(const Fresh& expected,std::string& e){
    // A layout pass can mark an already generic-retired descendant dirty4.
    // Only flags0/4 with ALL links/context/animation/delegates zero qualify.
    // Native144DD70(flags4) follows the resource-free type0/base cleanup path.
    if(!retired_dirty_gate(expected,e)||wheel_tree.nodes.empty()||sibling_tree.nodes.empty()||drop_tree.nodes.empty())return false;
    std::vector<uintptr_t> dirty;
    for(unsigned seal=0;seal<2;++seal){std::vector<uintptr_t> now;
        for(const auto* t:{&wheel_tree,&sibling_tree,&drop_tree})for(auto node:t->nodes){uint32_t flags{};if(!retired_node(node,true)||!read(node,flags))return false;if(flags==4)now.push_back(node);}
        if(seal&&dirty!=now)return fail(e,"Weapon menu retired dirty-node snapshot changed");dirty=std::move(now);
    }
    for(auto node:dirty){
        if(!retired_dirty_gate(expected,e))return false;
        auto at=retired_dirty_calls.begin();for(;at!=retired_dirty_calls.end();++at)if(at->first==node)break;
        if(at==retired_dirty_calls.end()){retired_dirty_calls.emplace_back(node,uint8_t{0});at=retired_dirty_calls.end()-1;}
        if(at->second==1)return interrupted(e,"Weapon menu retired dirty normalization result unknown");
        if(at->second==0){if(!retired_node(node,true)||value<uint32_t>(node,UINT32_MAX)!=4)return false;at->second=1;if(!call_destroy(node))return interrupted(e,"Weapon menu retired dirty normalization interrupted; no replay");at->second=2;}
        if(!retired_node(node,false))return fail(e,"Weapon menu retired dirty normalization acknowledgement pending");at->second=3;
    }
    return retired_dirty_gate(expected,e)&&retired_trees(false,e);
}
bool metadata_handoff(std::string& e){
    // Never dereference the captured retired Unit or call the old PC. A current
    // array relocation retaining the same generation/Unit is not retirement.
    if(phase==Phase::Interrupted||scope.pending()||!natives(e)||!original_retired()||value<uintptr_t>(target.game+UI)!=ui||value<uintptr_t>(target.game+GUI)!=gui||value<uintptr_t>(target.game+GS)!=state)return false;
    Fresh first{},seal{};if(!fresh_actor(first)||!fresh_actor(seal)||!(first==seal))return false;
    const auto scene=value<uint32_t>(state+0xAC21C);bool complete=false;
    if(scene==3&&value<uint8_t>(ui+0x24E334)==1&&value<uint8_t>(ui+MINIT)==0&&value<uint8_t>(ui+SINIT)==1&&!(first.roles&8)&&!(first.actions&owned_actions)&&first.auxopen==0&&current_root(false))complete=retired_trees(false,e)||normalize_retired_dirty(first,e);
    else if(scene==4)complete=normal_mission(e);
    if(!complete||!original_retired()||!fresh_actor(seal)||!(first==seal))return false;
    // The detached primitive survives generic root retirement on Ship. Its
    // resource-free normal destruction uses no retired actor. A complete new
    // native Mission instead owns this same storage; preserve it untouched.
    if(scene==3){if(!retired_dirty_gate(first,e)||!cleanup_drop_orphan(e)||!retired_dirty_gate(first,e))return false;}
    else{journal.drop_orphan=4;journal.destroy_orphan=3;}
    if(!barrier_restore(e))return false;
    // No retired actor context, observer, native Mission role8 or open action
    // is changed. Ship's separately captured detached primitive is released.
    owned=active=role_owned=false;retired=true;phase=Phase::Stopped;journal.remove=3;journal.wheel=journal.sibling=journal.drop=4;journal.destroy_wheel=journal.destroy_sibling=journal.destroy_drop=3;e.clear();pending_error.clear();return true;
}
bool cleanup(std::string& e){
    if(owned&&metadata_handoff(e))return true;
    if(!cleanup_widgets(e))return false;
    if(!barrier_restore(e)){phase=Phase::RetiredPending;return false;}
    if(!owned){phase=Phase::Stopped;e.clear();pending_error.clear();}return true;
}
void reset_clean(){journal={};vitals={};wheel_tree={};sibling_tree={};drop_tree={};retired_dirty_calls.clear();scope={};barrier={};witness={};aux_record=0;retired=false;exception={};phase=Phase::None;pending_error.clear();}
} // namespace

bool acquire(const Identity& id,bool caller_ready,std::string& e,Io callbacks){std::lock_guard<std::recursive_mutex> lock(mutex);
    if(active&&owned&&phase==Phase::Active&&id.game==target.game&&id.exe==target.exe&&id.pid==target.pid&&id.avatar==target.avatar)return barrier_owned(e)&&before_call(e)&&tree_present(wheel_tree,e)&&tree_present(sibling_tree,e)&&tree_present(drop_tree,e)&&drop_geometry(e)&&roles(true,e);
    if(phase==Phase::Stopped&&!owned&&!active&&!role_owned&&!scope.pending()&&!barrier.installed)reset_clean();
    if(phase!=Phase::None||owned||scope.pending()||barrier.installed)return fail(e,"Weapon menu prior lifetime acknowledgement pending");exception={};target=id;io=callbacks;pending_error.clear();if(!caller_ready||!id.pid||id.pid==UINT32_MAX||!id.avatar||id.avatar==UINT32_MAX||!natives(e))return fail(e,"Weapon menu readiness/identity refused");
    ui=value<uintptr_t>(id.game+UI);pm=value<uintptr_t>(id.game+PM);player=value<uintptr_t>(id.game+PLAYER);world=value<uintptr_t>(id.game+WORLD);state=value<uintptr_t>(id.game+GS);gui=value<uintptr_t>(id.game+GUI);observer=value<uintptr_t>(id.game+OBSERVER);aux=value<uintptr_t>(id.game+AUX);descriptor=value<uintptr_t>(pm+0x110);pc=pm+0x53D8B0;uint32_t row{};
    if(!ui||!pm||!player||!world||!state||!gui||!observer||!aux||!descriptor||!(io.read?io.read:raw_read)(descriptor,descriptor_bytes.data(),descriptor_bytes.size())||value<uint32_t>(descriptor+8)!=id.avatar||!read(descriptor+12,reference)||!reference||!map(player+0xD0,id.pid,row)||row>=128||!read(player+0x3A8+static_cast<uintptr_t>(row)*0x20,world_unit)||!world_unit||!read(ui+SACTIVE,ship_active)||ship_active>1)return fail(e,"Weapon UI initial owner discovery refused");
    registry=value<uintptr_t>(id.exe+0x1A100F0);generations=value<uintptr_t>(registry+0xA0);units=value<uintptr_t>(registry+0x88);unit=value<uintptr_t>(units+static_cast<uintptr_t>(reference&0x3FFFFF)*8);
    uintptr_t aux_rows{};uint32_t aux_row{};if(!map(aux+0x30,id.avatar,aux_row)||aux_row>=0x100000||!read(aux+0x58,aux_rows)||!aux_rows)return fail(e,"Weapon UI initial auxiliary mapping unavailable");aux_record=aux_rows+static_cast<uintptr_t>(aux_row)*0x20;
    for(size_t i=0;i<count_offsets.size();++i)if(!read(observer+count_offsets[i],observer_counts[i]))return fail(e,"Weapon UI observer snapshot unavailable");
    float scale{};if(!actor(e)||!presentation(e)||!menu_clear()||!roles(false,e)||!closed(e)||!(value<uint64_t>(pc+0xFD0)&2)||!empty(ui+WHEEL)||!empty(ui+SIBLING)||!drop_attached_empty()||!read(ui+0x24E324,scale)||!std::isfinite(scale)||scale<=0||!scope.available(e))return fail(e,e.empty()?"Weapon UI pure preflight refused":e.c_str());
    const auto engine=value<uintptr_t>(id.game+0x3326308),api=value<uintptr_t>(engine+0xD0);if(!engine||!api)return fail(e,"Weapon UI renderer API unavailable");for(uintptr_t slot:{0x118ULL,0x180ULL,0x230ULL,0x238ULL,0x240ULL,0x2B8ULL})if(!executable(value<uintptr_t>(api+slot)))return fail(e,"Weapon UI renderer callback unavailable");
    if(enable_vitals){vitals[0].tree.base=ui+HEALTH;vitals[0].tree.limit=ui+STAMINA;vitals[1].tree.base=ui+STAMINA;vitals[1].tree.limit=ui+0x24E340+0x8208;
        for(auto& v:vitals)if(!empty(v.tree.base))return fail(e,"Native health/stamina storage already owned");}
    construct_health=reinterpret_cast<VitalsCtor>(id.game+0x1816A60);construct_stamina=reinterpret_cast<VitalsCtor>(id.game+0x181DE50);update_health=reinterpret_cast<WheelTick>(id.game+0x1819A70);update_stamina=reinterpret_cast<WheelTick>(id.game+0x181EB90);construct_drop=reinterpret_cast<DropCtor>(id.game+0x18298F0);update_drop=reinterpret_cast<WheelTick>(id.game+0x182A550);get_material=reinterpret_cast<Material>(id.game+0x144F6E0);construct_wheel=reinterpret_cast<WheelCtor>(id.game+0x1823910);construct_sibling=reinterpret_cast<SiblingCtor>(id.game+0x17B4830);update_wheel=reinterpret_cast<WheelTick>(id.game+0x1825F40);update_sibling=reinterpret_cast<SiblingTick>(id.game+0x17B6560);attach=reinterpret_cast<Attach>(id.game+0x144C5C0);flush=reinterpret_cast<Void>(id.game+0x144C2C0);destroy=reinterpret_cast<Void>(id.game+0x144DD70);add_role=reinterpret_cast<Context>(id.game+0xAA0AA0);remove_role=reinterpret_cast<Context>(id.game+0xAA0BB0);set_alpha=reinterpret_cast<Alpha>(id.game+0x1448AD0);
#ifdef BC_WEAPON_MENU_FIXTURE
    if(fixture_bind)fixture_bind();
#endif
    if(!barrier_prepare(e))return false;
    // Stock Mission teardown can leave only its unlinked, resource-free type3
    // Drop primitive behind on a fully initialized Ship. No Mission/widget
    // owner or resource may survive this proof. Use the ordinary destructor,
    // once, with the same no-replay journal as our own detached primitive.
    if(!empty(ui+DROP+0x330)){
        for(unsigned seal=0;seal<2;++seal){
            if(ship_active!=1||!before_cleanup(e)||!menu_clear()||!roles(false,e)||!closed(e)||
               !(value<uint64_t>(pc+0xFD0)&2)||!empty(ui+WHEEL)||!empty(ui+SIBLING)||
               !drop_attached_empty()||!drop_orphan_present())return fail(e,"Weapon UI foreign or linked preexisting Drop primitive; no recovery");
        }
        phase=Phase::Preflight;owned=true;journal.drop_orphan=3;
        if(!cleanup_drop_orphan(e))return false;
        if(!before_cleanup(e)||!drop_empty())return fail(e,"Weapon UI stock detached primitive cleanup not acknowledged");
        owned=false;phase=Phase::None;journal={};
    }
    wheel_tree.base=ui+WHEEL;wheel_tree.limit=wheel_tree.base+0xBCF0;sibling_tree.base=ui+SIBLING;sibling_tree.limit=sibling_tree.base+0x20B8;drop_tree.base=ui+DROP;drop_tree.limit=drop_tree.base+0x1CF8;phase=Phase::Preflight;owned=true;if(!barrier_install(e)){owned=false;phase=Phase::None;return false;}
    if(!before_call(e)||!scope.enter(e))return false;phase=Phase::SiblingCalling;journal.sibling=1;bool returned=call_ctor(false);journal.sibling=returned?2:1;phase=returned?Phase::SiblingReturned:Phase::Interrupted;const bool gui_ok=scope.restore(e);if(!returned)return interrupted(e,"Weapon UI partial sibling constructor retained");if(!gui_ok||!observers(e)||!tree_capture(sibling_tree,0,e))return interrupted(e,"Weapon UI returned sibling tree unproved; retained");journal.sibling=3;
    if(!before_call(e))return false;journal.attach_sibling=1;if(!call_attach(ui+SIBLING))return interrupted(e,"Weapon UI sibling attachment interrupted");journal.attach_sibling=2;if(!before_call(e)||!tree_capture(sibling_tree,ui+0x820,e))return interrupted(e,"Weapon UI sibling attachment acknowledgement unavailable");if(!call_flush())return interrupted(e,"Weapon UI sibling layout flush interrupted");journal.attach_sibling=3;phase=Phase::SiblingAttached;
    if(!before_call(e)||!scope.enter(e))return false;phase=Phase::WheelCalling;journal.wheel=1;returned=call_ctor(true);journal.wheel=returned?2:1;phase=returned?Phase::WheelReturned:Phase::Interrupted;const bool second_gui_ok=scope.restore(e);if(!returned)return interrupted(e,"Weapon UI partial wheel constructor retained");if(!second_gui_ok||!observers(e)||!tree_capture(wheel_tree,0,e))return interrupted(e,"Weapon UI returned wheel tree unproved; retained");journal.wheel=3;
    if(!before_call(e))return false;journal.attach_wheel=1;if(!call_attach(ui+WHEEL))return interrupted(e,"Weapon UI wheel attachment interrupted");journal.attach_wheel=2;if(!before_call(e)||!tree_capture(wheel_tree,ui+0x820,e))return interrupted(e,"Weapon UI wheel attachment acknowledgement unavailable");if(!call_flush())return interrupted(e,"Weapon UI wheel layout flush interrupted");journal.attach_wheel=3;phase=Phase::WheelAttached;
    // DropOpen2:39 requires native roles2+8. Build its separate type0
    // Mission widget BEFORE8, matching12E9F9C..12E9FD3, without a full HUD.
    if(!before_call(e)||!scope.enter(e))return false;journal.drop=1;returned=call_drop_ctor();journal.drop=returned?2:1;const bool drop_gui_ok=scope.restore(e);if(!returned)return interrupted(e,"Weapon UI partial Drop constructor retained");if(!drop_gui_ok||!observers(e)||!tree_capture(drop_tree,0,e)||!drop_geometry(e))return interrupted(e,"Weapon UI returned Drop tree unproved; retained");journal.drop=3;journal.drop_orphan=3;
    journal.attach_drop=1;if(!call_attach(ui+DROP))return interrupted(e,"Weapon UI Drop attachment interrupted");journal.attach_drop=2;if(!before_call(e)||!tree_capture(drop_tree,ui+0x820,e)||!drop_geometry(e))return interrupted(e,"Weapon UI Drop attachment acknowledgement unavailable");if(!call_flush())return interrupted(e,"Weapon UI Drop layout flush interrupted");journal.attach_drop=3;
    if(!before_call(e)||!call_drop_materials()){if(exception.code)return interrupted(e,"Weapon UI Drop material getter interrupted");return fail(e,"Weapon UI Drop material unavailable before role8");}
    if(enable_vitals)for(unsigned i=0;i<vitals.size();++i){auto& v=vitals[i];if(!before_call(e)||!scope.enter(e))return false;v.built=1;const bool made=call_vitals_ctor(i);v.built=made?2:1;const bool restored=scope.restore(e);if(!made)return interrupted(e,"Native vitals constructor interrupted; no replay");if(!restored||!observers(e)||!tree_capture(v.tree,0,e))return interrupted(e,"Native vitals returned tree unavailable");v.built=3;
        v.attached=1;if(!call_attach(v.tree.base))return interrupted(e,"Native vitals attachment interrupted");v.attached=2;if(!before_call(e)||!tree_capture(v.tree,ui+0x820,e)||!call_flush())return interrupted(e,"Native vitals layout acknowledgement unavailable");v.attached=3;}
    Witness final_witness{};
    if(!before_call(e)||!roles(false,e)||!closed(e)||!barrier_owned(e)||!read_witness(final_witness)||!same_witness(witness,final_witness))return fail(e,"Weapon menu witness changed before role8 acquisition");phase=Phase::RoleCalling;role_owned=true;journal.add=1;if(!call_context(true))return interrupted(e,"Weapon UI role8 acquisition interrupted");journal.add=2;if(!roles(true,e))return false;journal.add=3;active=true;phase=Phase::Active;e.clear();pending_error.clear();return true;
}
bool tick(float dt,uint32_t pid,uint32_t avatar,bool caller_ready,std::string& e){
    std::lock_guard<std::recursive_mutex> lock(mutex);
    if(!owned&&!barrier.installed)return phase==Phase::Stopped;
    if(!caller_ready||pid!=target.pid||avatar!=target.avatar||!std::isfinite(dt)||dt<0||dt>1||phase!=Phase::Active||!active)return cleanup(e);
    // ESC pauses this UI service; it does not retire combat or reapply it on
    // close. Actual widget destruction is still handled by the GUI barrier.
    if(!menu_clear())return true;
    Witness current{};if(!barrier_owned(e)||!read_witness(current)||!same_witness(witness,current)){active=false;return cleanup(e);}
    // The tutorial updates these native services even with closed menus:
    // sibling computes the floating aim marker; wheel processes quick functions.
    // Keep the validated closed-frame path, but never suppress their frame work.
    uint32_t actions{};uint8_t auxiliary_open{},wheel_closed{},drop_closed{};
    if(read(pc+0xFD8,actions)&&!(actions&owned_actions)&&aux_record&&read(aux_record+5,auxiliary_open)&&auxiliary_open==0
        &&read(ui+WHEEL+0xBCD0,wheel_closed)&&wheel_closed==1&&read(ui+DROP+0x1CD0,drop_closed)&&drop_closed==1){
        auto current_closed_owner=[&](){Witness live{};return owned&&active&&phase==Phase::Active&&GetCurrentThreadId()==target.thread&&actor(e)&&presentation(e)&&roles(true,e)&&barrier_owned(e)&&read_witness(live)&&same_witness(witness,live);};
        if(!current_closed_owner()){active=false;return cleanup(e);}
        if(!vitals_present(e)){active=false;return cleanup(e);}
        for(unsigned i=0;i<vitals.size();++i)if(vitals[i].built==3){if(!current_closed_owner()){active=false;return cleanup(e);}if(!call_vitals_tick(i,dt))return interrupted(e,"Native vitals update interrupted");}
        if(!call_sibling_tick(dt))return interrupted(e,"Weapon reticle update interrupted; journal retained");
        if(!current_closed_owner()){active=false;return cleanup(e);}
        if(!call_wheel_tick(dt))return interrupted(e,"Weapon quick functions update interrupted; journal retained");
        if(!current_closed_owner()){active=false;return cleanup(e);}
        if(!call_drop_tick(dt))return interrupted(e,"Weapon Drop update interrupted; journal retained");
        return true;
    }
    if(!vitals_present(e)){active=false;return cleanup(e);}
    for(unsigned i=0;i<vitals.size();++i)if(vitals[i].built==3){if(!before_call(e)||!roles(true,e)||!barrier_owned(e)){active=false;return cleanup(e);}if(!call_vitals_tick(i,dt))return interrupted(e,"Native vitals update interrupted");}
    if(!before_call(e)){active=false;phase=Phase::RetiredPending;return cleanup(e);}
    if(!tree_present(wheel_tree,e)||!tree_present(sibling_tree,e)||!tree_present(drop_tree,e)||!drop_geometry(e))return cleanup(e);
    if(!roles(true,e)){active=false;phase=Phase::RetiredPending;return cleanup(e);}
    if(!call_sibling_tick(dt))return interrupted(e,"Weapon menu sibling update interrupted; journal retained");
    if(!before_call(e)||!tree_present(wheel_tree,e)||!tree_present(sibling_tree,e)||!tree_present(drop_tree,e)||!drop_geometry(e)||!roles(true,e)||!barrier_owned(e)){active=false;phase=Phase::RetiredPending;return cleanup(e);}
    if(!call_wheel_tick(dt))return interrupted(e,"Weapon menu wheel update interrupted; journal retained");
    if(!before_call(e)||!tree_present(wheel_tree,e)||!tree_present(sibling_tree,e)||!tree_present(drop_tree,e)||!drop_geometry(e)||!roles(true,e)||!barrier_owned(e)){active=false;phase=Phase::RetiredPending;return cleanup(e);}
    if(!call_drop_tick(dt))return interrupted(e,"Weapon menu Drop update interrupted; journal retained");return true;
}
bool stop(std::string& e){std::lock_guard<std::recursive_mutex> lock(mutex);if(phase==Phase::Stopped&&!barrier.installed)return true;return cleanup(e);}
Status status(){std::lock_guard<std::recursive_mutex> lock(mutex);const bool holds=owned||scope.pending()||barrier.installed;const bool healthy=owned&&active&&role_owned&&phase==Phase::Active&&!scope.pending()&&!barrier.restore_pending;return{phase,holds,active,role_owned,!holds&&phase==Phase::Stopped,holds&&!healthy,retired};}
} // namespace bc::weapon_menu

namespace {std::string exported_error;}
#ifndef BC_WEAPON_MENU_INTERNAL_ONLY
extern "C" __declspec(dllexport) int BC_weapon_menu_acquire(uint32_t pid,uint32_t avatar){auto game=reinterpret_cast<uintptr_t>(GetModuleHandleW(L"game.dll")),exe=reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));return bc::weapon_menu::acquire({game,exe,pid,avatar,GetCurrentThreadId()},true,exported_error)?1:0;}
extern "C" __declspec(dllexport) int BC_weapon_menu_tick(float dt,uint32_t pid,uint32_t avatar){return bc::weapon_menu::tick(dt,pid,avatar,true,exported_error)?1:0;}
extern "C" __declspec(dllexport) int BC_weapon_menu_stop(){return bc::weapon_menu::stop(exported_error)?1:0;}
extern "C" __declspec(dllexport) uint32_t BC_weapon_menu_phase(){return static_cast<uint32_t>(bc::weapon_menu::status().phase);}
extern "C" __declspec(dllexport) uint32_t BC_weapon_menu_flags(){auto s=bc::weapon_menu::status();return(s.owned?1U:0U)|(s.active?2U:0U)|(s.role8_owned?4U:0U)|(s.stopped?8U:0U)|(s.pending?16U:0U)|(s.retired?32U:0U);}
extern "C" __declspec(dllexport) const char* BC_weapon_menu_error(){if(exported_error.empty())exported_error=bc::weapon_menu::pending_error;return exported_error.c_str();}
#endif
