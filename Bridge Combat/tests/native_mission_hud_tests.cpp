// Isolated synthetic modules, widgets and MinHook. Never loads game.dll.
#define BC_NATIVE_TEST_API
#define BC_MISSION_HUD_FIXTURE
#include "../native/mission_hud.cpp"
#include <cassert>
#include <iostream>
#include <thread>
#include <vector>

namespace {
namespace mh=bc::mission_hud;
uintptr_t game{},exe{},ui{},pm{},player{},world{},state{},observer{},gui{},descriptor{};
uintptr_t registry{},generations{},units{},unit{},local_desc{},catalogue{},definition{};
unsigned ship_builds{},ship_destroys{},mission_builds{},mission_destroys{},resizes{},ticks{},
    original_init{},original_destroy{},foreign_calls{},global_calls{},foreign_removals{},local_removals{},hook_calls{},inactive_calls{};
std::array<bool,3> created{},enabled{};
std::vector<std::string> order;
uintptr_t unreadable{},change_after_read{},change_address{},change_value{};bool hide_mission_init{},hide_mission_destroy{},partial{},reenter{};
unsigned write_calls{};int relocation{};
int fail_create=-1,fail_enable=-1;
std::string fault_stage,ack_fault;bool bad_tree{},join_in_constructor{};
void fault(const char* stage){if(fault_stage=="mission-init-access"&&std::string(stage)=="mission-init"){const ULONG_PTR arguments[2]={0,0x12345678};RaiseException(EXCEPTION_ACCESS_VIOLATION,0,2,arguments);}if(fault_stage==stage)RaiseException(0xE0000012,0,0,nullptr);}
constexpr uint32_t avatar=251,pid=5,reference=0x40000E;
template<class T>void put(uintptr_t p,T value){*reinterpret_cast<T*>(p)=value;}
uintptr_t alloc(size_t n,DWORD protect=PAGE_READWRITE){auto p=reinterpret_cast<uintptr_t>(VirtualAlloc(nullptr,n,MEM_COMMIT|MEM_RESERVE,protect));assert(p);return p;}
void bytes(uintptr_t p,const char* hex){const auto d=[](char c){return c>='0'&&c<='9'?c-'0':c-'a'+10;};for(size_t i=0;hex[i];i+=2)put<uint8_t>(p+i/2,static_cast<uint8_t>((d(hex[i])<<4)|d(hex[i+1])));}
bool read(uintptr_t p,void* into,size_t n){if(unreadable&&p<=unreadable&&unreadable<p+n)return false;const bool ok=mh::raw_read(p,into,n);if(ok&&p==change_after_read){change_after_read=0;put(change_address,change_value);}return ok;}
bool write(uintptr_t p,const void* from,size_t n){++write_calls;return mh::raw_write(p,from,n);}
void relocate_storage(bool both){auto next=alloc(0x1000);std::memcpy(reinterpret_cast<void*>(next),reinterpret_cast<void*>(generations),0x1000);generations=next;put(registry+0xA0,generations);if(both){next=alloc(0x1000);std::memcpy(reinterpret_cast<void*>(next),reinterpret_cast<void*>(units),0x1000);units=next;put(registry+0x88,units);}}
void map(uintptr_t at,uint32_t key,uint32_t row){auto data=alloc(64);for(unsigned i=0;i<8;++i)put<uint32_t>(data+i*8,UINT32_MAX);put(at,data);put<uint32_t>(at+8,8);put<uint32_t>(at+12,UINT32_MAX);put<uint32_t>(at+16,1);put<uint32_t>(data+(key&7)*8,key);put<uint32_t>(data+(key&7)*8+4,row);}
void mission_observers(bool registered){for(const auto& l:mh::mission_rows){auto n=mh::value<uint32_t>(observer+l[0]);if(registered){assert(n<l[2]);put(observer+l[1]+n*16,ui+mh::M);put<uint32_t>(observer+l[1]+n*16+8,0x106);put<uint32_t>(observer+l[0],n+1);}else for(uint32_t i=0;i<n;++i)if(mh::value<uintptr_t>(observer+l[1]+i*16)==ui+mh::M){--n;std::memcpy(reinterpret_cast<void*>(observer+l[1]+i*16),reinterpret_cast<void*>(observer+l[1]+n*16),16);put<uint32_t>(observer+l[0],n);break;}}}
void ship_observers(bool registered){for(const auto& l:std::array<std::pair<uintptr_t,uintptr_t>,3>{{{0x27A8,0x27B0},{0x3890,0x3898},{0x38A8,0x38B0}}}){put<uint32_t>(observer+l.first,registered?1U:0U);if(registered){put(observer+l.second,ui+mh::S);put<uint32_t>(observer+l.second+8,0x118);}}}
void root_links(){for(const auto& l:std::array<std::pair<uintptr_t,uintptr_t>,4>{{{0x820,0x258},{0x930,0x380},{0xA40,0x5D0},{0xB50,0x4A8}}}){put(ui+l.first+0xF0,ui+l.second);put(ui+l.first+0xF8,gui+5*0x3698);put<uint32_t>(ui+l.second,0x1015);}}
void __fastcall normal_remove(const uint64_t* mask){++global_calls;for(uint32_t row=0;row<mh::value<uint32_t>(pm+0x70);++row){auto pc=pm+0x53D8B0+static_cast<uintptr_t>(row)*0x1238;auto role=mh::value<uint64_t>(pc+0xFD0);if(role&mask[0]){if(row)++foreign_removals;put<uint64_t>(pc+0xFD0,role&~mask[0]);}}}
void __fastcall local_remove(void* action,const uint64_t* mask){assert(reinterpret_cast<uintptr_t>(action)==pm+0x53D8B0+0x50&&mask[0]==8&&mask[1]==0&&mask[2]==0);++local_removals;order.push_back("cancel");auto pc=pm+0x53D8B0;put<uint64_t>(pc+0xFD0,mh::value<uint64_t>(pc+0xFD0)&~8ULL);put<uint32_t>(pc+0xFD8,mh::value<uint32_t>(pc+0xFD8)&~0x400000U);}
void __fastcall destroy_ship(void* object){assert(reinterpret_cast<uintptr_t>(object)==ui+mh::S&&mh::value<uint8_t>(ui+mh::SInit)==1);++ship_destroys;order.push_back("ship-destroy");fault("ship-destroy");put<uint8_t>(ui+mh::SInit,0);ship_observers(false);}
void check_context(){auto d=mh::value<int32_t>(gui+0x2C5BC);assert(d>=0&&d<=3&&mh::value<uint8_t>(gui+0x2C5B8+d)==5);}
void __fastcall initialize_mission(void* object,void* a,void* b,void* c){assert(reinterpret_cast<uintptr_t>(object)==ui+mh::M&&a==reinterpret_cast<void*>(ui+0x820)&&b==reinterpret_cast<void*>(ui+0x930)&&c==reinterpret_cast<void*>(ui+0xB50));check_context();assert(mh::value<uint8_t>(ui+mh::SInit)==0);++mission_builds;order.push_back("mission-init");mission_observers(true);if(relocation){relocate_storage(relocation==2);relocation=0;}if(reenter){const auto before=original_destroy;mh::destroy_hook(reinterpret_cast<void*>(ui));assert(original_destroy==before&&mh::status().lifecycle_blocked);reenter=false;}fault("mission-init");if(partial)RaiseException(0xE0000011,0,0,nullptr);for(uintptr_t child:{0x60ULL,0x9C38ULL,0x19AAF8ULL}){put(ui+mh::M+child+0xF0,ui+0x820);put(ui+mh::M+child+0xF8,gui+5*0x3698);}if(bad_tree)put<uintptr_t>(ui+mh::M+0x9C38+0xF0,0);put<uint8_t>(ui+mh::MInit,1);if(join_in_constructor){put<uint32_t>(pm+0x70,2);put<uint64_t>(pm+0x53D8B0+0x1238+0xFD0,0xA0A);}if(hide_mission_init){hide_mission_init=false;unreadable=ui+mh::MInit;}}
void __fastcall active_mission(void* object,uint8_t v){assert(reinterpret_cast<uintptr_t>(object)==ui+mh::M&&mh::value<uint8_t>(ui+mh::MInit)==1);if(v)fault("mission-activate");else fault(++inactive_calls%2?"mission-inactive":"mission-deactivate");put<uint8_t>(ui+mh::M+0x58,v);order.push_back(v?"activate":"deactivate");if(v){assert(mh::value<uint32_t>(pm+0x70)==1);put<uint64_t>(pm+0x53D8B0+0xFD0,mh::value<uint64_t>(pm+0x53D8B0+0xFD0)|8);}else{alignas(16)const uint64_t mask[3]={8,0,0};(enabled[2]?mh::remove_hook:normal_remove)(mask);}}
void __fastcall destroy_mission(void* object){assert(reinterpret_cast<uintptr_t>(object)==ui+mh::M&&mh::value<uint8_t>(ui+mh::MInit)==1);assert((mh::value<uint32_t>(pm+0x53D8B0+0xFD8)&0x400000)==0||mh::value<uint8_t>(generations+14)!=1);++mission_destroys;order.push_back("mission-destroy");fault("mission-destroy");put<uint8_t>(ui+mh::MInit,0);for(uintptr_t child:{0x60ULL,0x9C38ULL,0x19AAF8ULL}){put<uintptr_t>(ui+mh::M+child+0xF0,0);put<uintptr_t>(ui+mh::M+child+0xF8,0);}alignas(16)const uint64_t mask[3]={8,0,0};(enabled[2]?mh::remove_hook:normal_remove)(mask);mission_observers(false);if(hide_mission_destroy){hide_mission_destroy=false;unreadable=ui+mh::MInit;}}
void __fastcall initialize_ship(void* object,void* a,void* b,void* c){assert(reinterpret_cast<uintptr_t>(object)==ui+mh::S&&a==reinterpret_cast<void*>(ui+0x820)&&b==reinterpret_cast<void*>(ui+0x930)&&c==reinterpret_cast<void*>(ui+0xA40));check_context();assert(mh::value<uint8_t>(ui+mh::MInit)==0&&mh::value<uint8_t>(ui+mh::SInit)==0);++ship_builds;order.push_back("ship-init");fault("ship-init");put<uint8_t>(ui+mh::SInit,1);put<uint8_t>(ui+mh::S,1);ship_observers(true);}
void __fastcall active_ship(void* object,uint8_t v){assert(reinterpret_cast<uintptr_t>(object)==ui+mh::S);fault("ship-active");put<uint8_t>(ui+mh::S,v);}
void __fastcall resize_ship(void* object,float x){assert(reinterpret_cast<uintptr_t>(object)==ui+mh::S&&x==1.25f);order.push_back("ship-resize");fault("ship-resize");if(ack_fault=="role")put<uint64_t>(pm+0x53D8B0+0xFD0,mh::value<uint64_t>(pm+0x53D8B0+0xFD0)^0x10000);if(ack_fault=="gui")put<uint8_t>(gui+0x2C5BB,99);if(ack_fault=="padding")put<uint32_t>(observer+0x27B0+12,0xAABBCCDD);
    if(ack_fault=="reorder"){std::array<uint8_t,16> temporary{};std::memcpy(temporary.data(),reinterpret_cast<void*>(observer+0x2AD0),16);std::memcpy(reinterpret_cast<void*>(observer+0x2AD0),reinterpret_cast<void*>(observer+0x2AE0),16);std::memcpy(reinterpret_cast<void*>(observer+0x2AE0),temporary.data(),16);}
    if(ack_fault=="type")put<uint32_t>(observer+0x2AD0+8,0xFF);
    if(ack_fault=="object")put<uintptr_t>(observer+0x2AD0,ui+0x1234);
    if(ack_fault=="duplicate")std::memcpy(reinterpret_cast<void*>(observer+0x2AE0),reinterpret_cast<void*>(observer+0x2AD0),16);
    if(ack_fault=="count")put<uint32_t>(observer+0x2AC8,1);
}
void __fastcall resize_mission(void* object,float x,float y){assert(reinterpret_cast<uintptr_t>(object)==ui+mh::M&&x==1.25f&&y==mh::value<float>(ui+0x24E328));fault("mission-resize");++resizes;}
void __fastcall visible(void* object,float,uint8_t allowed){assert(reinterpret_cast<uintptr_t>(object)==ui+mh::M&&allowed==1&&mh::value<uint8_t>(ui+mh::M+0x58)==1);fault("mission-visible");}
void __fastcall data(void* object,float,uint32_t actual_pid){assert(reinterpret_cast<uintptr_t>(object)==ui+mh::M&&actual_pid==pid&&actual_pid!=avatar&&mh::value<uint8_t>(ui+mh::M+0x58)==1);fault("mission-data");++ticks;}
void __fastcall ui_init(void* object){if(reinterpret_cast<uintptr_t>(object)!=ui){++foreign_calls;return;}assert(!mh::status().widgets_ready&&!mh::status().active&&!mh::status().cleanup_pending);assert(mh::value<uint8_t>(ui+mh::MInit)==0&&mh::value<uint8_t>(ui+mh::SInit)==0);++original_init;order.push_back("original-init");put<uint8_t>(ui+mh::UiInit,1);put<uint8_t>(ui+mh::SInit,1);ship_observers(true);root_links();}
void __fastcall ui_destroy(void* object){if(reinterpret_cast<uintptr_t>(object)!=ui){++foreign_calls;return;}assert(!mh::status().widgets_ready&&!mh::status().active);assert(mh::value<uint8_t>(ui+mh::MInit)==0&&mh::value<uint8_t>(ui+mh::SInit)==0);++original_destroy;order.push_back("original-destroy");put<uint8_t>(ui+mh::UiInit,0);}
void native_stubs(){mh::ship_destroy=destroy_ship;mh::mission_initialize=initialize_mission;mh::mission_active=active_mission;mh::mission_visible=visible;mh::mission_data=data;mh::mission_resize=resize_mission;mh::mission_destroy=destroy_mission;mh::ship_initialize=initialize_ship;mh::ship_resize=resize_ship;mh::ship_active=active_ship;mh::local_remove=local_remove;}
void fixture(){
    assert(!GetModuleHandleW(L"game.dll"));game=alloc(0x3500000,PAGE_EXECUTE_READWRITE);exe=alloc(0x1A11000);ui=alloc(0x500000);pm=alloc(0x550000);player=alloc(0x1000);world=alloc(0xF40000);state=alloc(0xAF000);observer=alloc(0x4000);gui=alloc(0x30000);descriptor=alloc(0x1000);local_desc=alloc(0x1000);catalogue=alloc(0xD9000);definition=alloc(0x1000);registry=alloc(0x1000);generations=alloc(0x1000);units=alloc(0x1000);unit=alloc(0x1000);
    for(auto pair:{std::pair<uintptr_t,uint32_t>{game,0x6AB3B43F},{exe,0x6AB382E4}}){put<uint16_t>(pair.first,0x5A4D);put<int32_t>(pair.first+0x3C,0x100);put<uint32_t>(pair.first+0x100,0x4550);put<uint32_t>(pair.first+0x108,pair.second);}
    for(auto pair:{std::pair<uintptr_t,uintptr_t>{mh::UI,ui},{mh::PM,pm},{mh::PLAYER,player},{mh::WORLD,world},{mh::GS,state},{mh::GUI,gui},{mh::OBSERVER,observer}})put(game+pair.first,pair.second);
    put<uint32_t>(state+0xAC21C,3);put(game+0x347CEF8,catalogue);put<uint32_t>(catalogue+0xD8A50,2);put(state+0xAE288,definition);put<uint8_t>(definition+0xF9,1);put<uint32_t>(pm+0x70,1);map(pm+0xF8,avatar,0);put(pm+0x110,descriptor);put<uint32_t>(descriptor+8,avatar);put<uint32_t>(descriptor+12,reference);put<uint8_t>(descriptor+20,1);put<uint64_t>(pm+0x53D8B0+0xFD0,0x202);
    put<uint32_t>(player+0x88,1);put(player+0xE8,local_desc);put<uint32_t>(local_desc+8,pid);map(player+0xD0,pid,0);put<uint32_t>(player+0x3A8,14);map(world+0xF22EC8,14,0);put<uint32_t>(world+0xF32F18+8,avatar);
    put(exe+0x1A100F0,registry);put<uint32_t>(registry+0x98,100);put(registry+0xA0,generations);put(registry+0x88,units);put<uint8_t>(generations+14,1);put(units+14*8,unit);put<uint32_t>(unit+8,reference);
    put<uint8_t>(ui+mh::UiInit,1);put<uint8_t>(ui+mh::SInit,1);put<uint8_t>(ui+mh::S,0);put<float>(ui+0x24E324,1.25f);put<float>(ui+0x24E328,1.5f);put<int32_t>(gui+0x2C5BC,-1);for(unsigned i=0;i<4;++i)put<uint8_t>(gui+0x2C5B8+i,static_cast<uint8_t>(20+i));root_links();ship_observers(true);mission_observers(false);
    for(uintptr_t rva:{0x3326308ULL,0x347CE30ULL,0x346D530ULL})put(game+rva,alloc(0x1000));auto engine=mh::value<uintptr_t>(game+0x3326308);auto renderer=alloc(0x1000),app=alloc(0x1000);put(engine+0xD0,renderer);put(engine+0xC0,app);put(app+0x28,game+0x1000);for(uintptr_t slot:{0x118ULL,0x180ULL,0x2B8ULL})put(renderer+slot,game+0x1000);
    for(const auto& a:mh::abi)bytes(game+a.first,a.second);for(const auto& h:mh::hooks)bytes(game+h.rva,h.fp);
}
void prepare(std::string& e){assert(mh::prepare({game,exe,pid,avatar,GetCurrentThreadId()},e,{read,write}));native_stubs();assert(mh::status().prepared&&!mh::status().hooks_enabled&&mh::status().stopped);}
int hook_index(LPVOID at){assert(at&&at!=MH_ALL_HOOKS);for(unsigned i=0;i<3;++i)if(reinterpret_cast<uintptr_t>(at)==game+mh::hooks[i].rva)return static_cast<int>(i);assert(false);return-1;}
}
extern "C" MH_STATUS WINAPI MH_Initialize(){++hook_calls;return MH_OK;}
extern "C" MH_STATUS WINAPI MH_CreateHook(LPVOID at,LPVOID detour,LPVOID* original){++hook_calls;auto i=hook_index(at);assert(detour==reinterpret_cast<void*>(i==0?reinterpret_cast<uintptr_t>(mh::init_hook):i==1?reinterpret_cast<uintptr_t>(mh::destroy_hook):reinterpret_cast<uintptr_t>(mh::remove_hook)));if(fail_create==i)return MH_ERROR_MEMORY_ALLOC;assert(!created[i]);created[i]=true;*original=i==0?reinterpret_cast<void*>(ui_init):i==1?reinterpret_cast<void*>(ui_destroy):reinterpret_cast<void*>(normal_remove);return MH_OK;}
extern "C" MH_STATUS WINAPI MH_EnableHook(LPVOID at){++hook_calls;auto i=hook_index(at);assert(created[i]&&!enabled[i]);if(fail_enable==i)return MH_ERROR_MEMORY_PROTECT;enabled[i]=true;return MH_OK;}
extern "C" MH_STATUS WINAPI MH_DisableHook(LPVOID at){++hook_calls;auto i=hook_index(at);assert(created[i]);if(!enabled[i])return MH_ERROR_DISABLED;enabled[i]=false;return MH_OK;}
extern "C" MH_STATUS WINAPI MH_RemoveHook(LPVOID at){++hook_calls;auto i=hook_index(at);assert(created[i]&&!enabled[i]);created[i]=false;return MH_OK;}

int main(int argc,char** argv){
    fixture();std::string e;
    if(argc>1&&std::string(argv[1]).rfind("ack-",0)==0){
        const std::string mode=argv[1];auto& d=mh::probe_diagnostic;d={};d.before_ready=d.after_ready=true;d.before[0].count=d.after[0].count=2;
        const auto row=[](mh::ObserverSnapshot& s,unsigned i,uintptr_t object,uint32_t type,uint32_t padding){std::memcpy(s.rows.data()+i*16,&object,8);std::memcpy(s.rows.data()+i*16+8,&type,4);std::memcpy(s.rows.data()+i*16+12,&padding,4);};
        row(d.before[0],0,ui+1,0xA1,0);row(d.before[0],1,ui+2,0xA2,0);d.after[0]=d.before[0];
        bool semantic{};
        if(mode=="ack-reorder"){row(d.after[0],0,ui+2,0xA2,0);row(d.after[0],1,ui+1,0xA1,0);semantic=true;}
        else if(mode=="ack-padding"){row(d.after[0],0,ui+1,0xA1,0xDEADBEEF);semantic=true;}
        else if(mode=="ack-type")row(d.after[0],0,ui+1,0xAA,0);
        else if(mode=="ack-multiplicity")row(d.after[0],1,ui+1,0xA1,0);
        else assert(false);
        assert(mh::semantic_rows_equal(d.before[0],d.after[0])==semantic);
        mh::probe_unacknowledged=true;mh::phase=mh::Phase::Restored;const auto writes=write_calls,hooks=hook_calls;
        const std::string text=BC_mission_hud_probe_diagnostics();const auto at=text.find("\"count_offset\":\"2aa0\"");assert(at!=std::string::npos);
        const auto end=text.find("\"before\":[",at);const auto header=text.substr(at,end-at);
        assert(header.find("\"raw_equal\":false")!=std::string::npos);
        assert(header.find(semantic?"\"semantic_multiset_equal\":true":"\"semantic_multiset_equal\":false")!=std::string::npos);
        assert(text.front()=='{'&&text.back()=='}'&&text.find("\"old_roles_raw\":\"")!=std::string::npos);
        assert(text==BC_mission_hud_probe_diagnostics()&&mh::probe_unacknowledged&&mh::phase==mh::Phase::Restored&&write_calls==writes&&hook_calls==hooks&&mission_builds==0&&ship_destroys==0);
        std::cout<<"PASS "<<mode<<": semantic multiset distinguishes order/padding from type/multiplicity; diagnostic is read-only and keeps journal\n";return 0;
    }
    if(argc>1&&std::string(argv[1]).rfind("actor-",0)==0){
        const std::string mode=argv[1];
        assert(mh::prepare_impl({game,exe,pid,avatar,GetCurrentThreadId()},e,{read,write},false));
        mh::Actor expected=mh::Actor::Unknown;
        if(mode=="actor-relocate-generation"||mode=="actor-relocate-both"){relocate_storage(mode=="actor-relocate-both");expected=mh::Actor::Current;}
        else if(mode=="actor-generation"){put<uint8_t>(generations+14,2);expected=mh::Actor::Retired;}
        else if(mode=="actor-unit"){put(units+14*8,alloc(0x1000));expected=mh::Actor::Retired;}
        else if(mode=="actor-root")put(exe+0x1A100F0,alloc(0x1000));
        else if(mode=="actor-reference")put<uint32_t>(unit+8,reference+1);
        else if(mode=="actor-descriptor")put<uint32_t>(descriptor+8,avatar+1);
        else{
            change_after_read=generations+14;
            if(mode=="actor-torn-root"){change_address=exe+0x1A100F0;change_value=alloc(0x1000);}
            else if(mode=="actor-torn-arrays"){change_address=registry+0x88;change_value=alloc(0x1000);}
            else if(mode=="actor-torn-count"){change_address=registry+0x98;change_value=101;}
            else if(mode=="actor-torn-generation"){change_address=generations+14;change_value=2;}
            else if(mode=="actor-torn-unit"){change_after_read=units+14*8;change_address=units+14*8;change_value=alloc(0x1000);}
            else assert(false);
        }
        assert(mh::actor(e,true)==expected);
        assert(hook_calls==0&&write_calls==0&&ship_destroys==0&&mission_builds==0&&mh::status().stopped);
        assert(mh::release(e));
        std::cout<<"PASS "<<mode<<": current allocation relocation accepted; actual retirement/torn identity cannot authorize native calls\n";return 0;
    }
    if(argc>1&&std::string(argv[1])=="diagnostic-filter"){
        mh::target={game,exe,pid,avatar,GetCurrentThreadId()};
        CONTEXT context{};context.Rip=game+0x12E9A70;EXCEPTION_RECORD record{};
        record.ExceptionCode=EXCEPTION_ACCESS_VIOLATION;record.ExceptionAddress=reinterpret_cast<void*>(context.Rip);record.NumberParameters=2;record.ExceptionInformation[1]=0xA0;
        EXCEPTION_POINTERS pointers{&record,&context};
        for(ULONG_PTR access:{0ULL,1ULL,8ULL}){
            record.ExceptionInformation[0]=access;mh::begin_native_call("mission_init",game+0x12E96D0);
            assert(mh::capture_native_exception(&pointers)==EXCEPTION_EXECUTE_HANDLER);
            auto text=mh::exception_details();assert(text.find("op=mission_init")!=std::string::npos&&text.find("code=0xc0000005")!=std::string::npos&&text.find("game+0x12e9a70")!=std::string::npos&&text.find("fault=0xa0")!=std::string::npos);
            assert(text.find(access==0?"access=read":access==1?"access=write":"access=execute")!=std::string::npos);
        }
        mh::begin_native_call("mission_data",0);assert(mh::exception_details().empty());
        std::cout<<"PASS native exception filter: exact RIP/game RVA/code/fault and read/write/execute, cleared before next call\n";return 0;
    }
    if(argc>1&&std::string(argv[1]).rfind("probe",0)==0){
        const std::string mode=argv[1];mh::fixture_bind=native_stubs;
        if(mode.rfind("probe-fault-",0)==0)fault_stage=mode.substr(12);
        if(mode=="probe-partial")partial=true;
        if(mode=="probe-hidden")hide_mission_init=true;
        if(mode=="probe-tree")bad_tree=true;
        if(mode=="probe-join")join_in_constructor=true;
        if(mode=="probe-relocate-generation")relocation=1;
        if(mode=="probe-relocate-both")relocation=2;
        if(mode.rfind("probe-ack-",0)==0)ack_fault=mode.substr(10);
        if(ack_fault=="reorder"||ack_fault=="type"||ack_fault=="object"||ack_fault=="duplicate"||ack_fault=="count"){
            put<uint32_t>(observer+0x2AC8,2);put(observer+0x2AD0,ui+0x100);put<uint32_t>(observer+0x2AD0+8,0xA1);put(observer+0x2AE0,ui+0x200);put<uint32_t>(observer+0x2AE0+8,0xA2);
        }
        if(mode=="probe-existing-wheel")put<uint32_t>(ui+mh::M+0x9C38,1);
        if(mode=="probe-existing-sibling")put<uint32_t>(ui+mh::M+0x19AAF8,1);
        if(mode=="probe-wheel-orphan")put(ui+mh::M+0x9C38+0xF8,gui+5*0x3698);
        if(mode=="probe-sibling-tween")put<uintptr_t>(ui+mh::M+0x19AAF8+0xA8,1);
        if(mode=="probe-zero-difficulty")put<uint8_t>(definition+0xF9,0);
        if(mode=="probe-zero-difficulty-mode0"){put<uint8_t>(definition+0xF9,0);put<uint32_t>(catalogue+0xD8A50,0);}
        if(mode=="probe-adjust-zero")put<float>(ui+0x24E328,0.0f);
        if(mode=="probe-adjust-negative")put<float>(ui+0x24E328,-0.5f);
        if(mode=="probe-adjust-nan")put<uint32_t>(ui+0x24E328,0x7FC00000);
        if(mode=="probe-access")fault_stage="mission-init-access";
        if(mode=="probe-root")put<uintptr_t>(ui+0x820+0xF8,gui+4*0x3698);
        const auto initial_hooks=hook_calls;
        const bool ok=mh::probe({game,exe,pid,avatar,GetCurrentThreadId()},e,{read,write});
        assert(hook_calls==initial_hooks&&!mh::status().hooks_enabled);
        for(unsigned i=0;i<3;++i)assert(!created[i]&&!enabled[i]);
        if(mode=="probe"||mode=="probe-adjust-zero"||mode=="probe-adjust-negative"||mode=="probe-zero-difficulty-mode0"||mode=="probe-relocate-generation"||mode=="probe-relocate-both"||mode=="probe-ack-padding"||mode=="probe-ack-reorder"){
            assert(ok&&e.empty()&&mh::probe_flags()==4095&&mission_builds==1&&mission_destroys==1&&ship_destroys==1&&ship_builds==1&&ticks==1);
            assert(mh::status().phase==mh::Phase::Restored&&mh::status().stopped&&!mh::status().cleanup_pending);
            assert(mh::value<uint8_t>(ui+mh::S)==0&&mh::value<uint64_t>(pm+0x53D8B0+0xFD0)==0x202&&mh::value<int32_t>(gui+0x2C5BC)==-1);
            if(mode=="probe-ack-padding"||mode=="probe-ack-reorder"){
                const std::string diagnostic=BC_mission_hud_probe_diagnostics();assert(diagnostic.find("\"failed\":0")!=std::string::npos);
                const auto at=diagnostic.find(mode=="probe-ack-padding"?"\"count_offset\":\"27a8\"":"\"count_offset\":\"2ac8\"");const auto end=diagnostic.find("\"before\":[",at);assert(at!=std::string::npos);const auto header=diagnostic.substr(at,end-at);
                assert(header.find("\"raw_equal\":false")!=std::string::npos&&header.find("\"semantic_multiset_equal\":true")!=std::string::npos);
            }
            assert(!mh::start(e));assert(mh::release(e)&&hook_calls==initial_hooks);
            std::cout<<"PASS coherent review probe: full ctor/tree/data, exact role/observer/GUI/Ship restore, zero MinHook calls\n";return 0;
        }
        assert(!ok&&!(mh::probe_flags()&mh::ProbeComplete));
        if(mode.rfind("probe-ack-",0)==0){
            const std::string diagnostic=BC_mission_hud_probe_diagnostics();const auto expected=ack_fault=="role"?"\"failed\":16":ack_fault=="gui"?"\"failed\":128":"\"failed\":512";
            assert(diagnostic.find(expected)!=std::string::npos&&mh::probe_flags()==1023&&mh::status().phase==mh::Phase::Restored&&mh::probe_unacknowledged);
            assert(mission_builds==1&&mission_destroys==1&&ship_builds==1&&ship_destroys==1);
            if(ack_fault=="padding"){const auto at=diagnostic.find("\"count_offset\":\"27a8\"");assert(at!=std::string::npos&&diagnostic.find("\"semantic_multiset_equal\":true",at)<diagnostic.find("\"before\":[",at));}
        }
        if(mode=="probe-access"){
            assert(e.find("native_exception op=mission_init code=0xc0000005 rip=0x")!=std::string::npos&&e.find("access=read fault=0x12345678")!=std::string::npos);
            assert(std::string(BC_mission_hud_error()).find("access=read fault=0x12345678")!=std::string::npos);
        }
        if(mode.rfind("probe-fault-",0)==0)assert(e.find("code=0xe0000012")!=std::string::npos&&e.find("rip=0x")!=std::string::npos);
        if(mode=="probe-tree"){
            assert(mission_builds==1&&mission_destroys==1&&ship_builds==1&&mh::status().stopped&&!mh::status().cleanup_pending&&mh::release(e));
        }else if(mode=="probe-root"||mode=="probe-adjust-nan"||mode=="probe-zero-difficulty"||mode=="probe-existing-wheel"||mode=="probe-existing-sibling"||mode=="probe-wheel-orphan"||mode=="probe-sibling-tween"){
            assert(ship_destroys==0&&mission_builds==0&&mh::probe_flags()==0);
            assert(write_calls==0&&mh::value<int32_t>(gui+0x2C5BC)==-1);
            if(mode=="probe-existing-wheel"||mode=="probe-existing-sibling"||mode=="probe-wheel-orphan"||mode=="probe-sibling-tween")assert(e.find("not positively absent")!=std::string::npos);
            if(mode=="probe-zero-difficulty"){assert(e.find("difficulty-1 out of bounds")!=std::string::npos&&hook_calls==0&&mh::value<int32_t>(gui+0x2C5BC)==-1&&mh::value<uint8_t>(ui+mh::SInit)==1);assert(!mh::prepare({game,exe,pid,avatar,GetCurrentThreadId()},e,{read,write})&&hook_calls==0);}
        }else if(mode.rfind("probe-ack-",0)==0){
            assert(mh::status().cleanup_pending&&!mh::status().stopped&&!mh::release(e));
            const auto builds=mission_builds,destroys=mission_destroys,ship_count=ship_builds,writes=write_calls;
            const std::string retained=BC_mission_hud_probe_diagnostics();
            assert(!mh::probe({game,exe,pid,avatar,GetCurrentThreadId()},e,{read,write})&&!mh::start(e)&&!mh::tick(.01f,pid,avatar,e));
            assert(retained==BC_mission_hud_probe_diagnostics()&&mission_builds==builds&&mission_destroys==destroys&&ship_builds==ship_count&&write_calls==writes&&hook_calls==initial_hooks);
        }else{
            assert(mh::status().cleanup_pending&&!mh::status().stopped&&!mh::release(e));
            const auto builds=mission_builds,destroys=mission_destroys,ship_count=ship_builds;
            assert(!mh::probe({game,exe,pid,avatar,GetCurrentThreadId()},e,{read,write})&&!mh::start(e)&&!mh::tick(.01f,pid,avatar,e)&&!mh::stop(e));
            assert(mission_builds==builds&&mission_destroys==destroys&&ship_builds==ship_count&&hook_calls==initial_hooks);
            assert(mh::value<int32_t>(gui+0x2C5BC)==-1);
            if(mode=="probe-join")assert(global_calls==0&&foreign_removals==0&&mh::value<uint64_t>(pm+0x53D8B0+0x1238+0xFD0)==0xA0A);
        }
        std::cout<<"PASS "<<mode<<": guarded rejection or interrupted journal retained without replay/patch\n";return 0;
    }
    if(argc>1&&std::string(argv[1])=="partial"){
        prepare(e);partial=true;assert(!mh::start(e));assert(mh::status().phase==mh::Phase::Interrupted&&mh::status().widgets_ready==false&&!mh::status().stopped);const auto built=mission_builds;assert(!mh::stop(e)&&mission_builds==built&&mission_destroys==0);mh::destroy_hook(reinterpret_cast<void*>(ui));assert(original_destroy==0&&mh::status().lifecycle_blocked&&!mh::release(e));assert(mh::value<int32_t>(gui+0x2C5BC)==-1);std::cout<<"PASS partial-constructor: no replay, guessed destructor or foreign forwarding\n";return 0;
    }
    if(argc>1&&std::string(argv[1])=="unexpected"){
        prepare(e);assert(mh::start(e));alignas(16)const uint64_t mask[3]={16,0,0};mh::teardown_scope=true;mh::remove_hook(mask);mh::teardown_scope=false;assert(global_calls==0&&mh::unexpected_scope_mask&&!mh::stop(e));mh::init_hook(reinterpret_cast<void*>(ui));assert(original_init==0&&mh::status().lifecycle_blocked&&!mh::release(e));std::cout<<"PASS unexpected scoped mask: no global forwarding, journal retained\n";return 0;
    }
    const auto thread=GetCurrentThreadId();
    assert(!mh::prepare({game,exe,pid,avatar,thread+1},e,{read,write}));assert(ship_destroys==0);
    assert(!mh::prepare({game,exe,avatar,avatar,thread},e,{read,write}));assert(ship_destroys==0);
    put<uint64_t>(pm+0x53D8B0+0xFD0,0x20A);assert(!mh::prepare({game,exe,pid,avatar,thread},e,{read,write}));put<uint64_t>(pm+0x53D8B0+0xFD0,0x202);
    for(int32_t d:{-2,3}){put(gui+0x2C5BC,d);assert(!mh::prepare({game,exe,pid,avatar,thread},e,{read,write}));}put<int32_t>(gui+0x2C5BC,-1);
    fail_create=2;assert(!mh::prepare({game,exe,pid,avatar,thread},e,{read,write}));assert(created[0]&&created[1]&&!created[2]&&ship_destroys==0);assert(mh::release(e));fail_create=-1;
    prepare(e);fail_enable=1;assert(!mh::start(e));assert(!enabled[0]&&!enabled[1]&&!enabled[2]&&ship_destroys==0);assert(mh::release(e));fail_enable=-1;
    for(int32_t d:{-1,0,1,2}){
        put(gui+0x2C5BC,d);std::array<uint8_t,4> old{};std::memcpy(old.data(),reinterpret_cast<void*>(gui+0x2C5B8),4);prepare(e);assert(mh::start(e));assert(mh::status().widgets_ready&&mh::status().active&&mh::status().role8_owned);assert(mh::tick(.01f,pid,avatar,e));assert(!mh::tick(.01f,avatar,avatar,e));const auto builds=mission_builds;assert(mh::start(e)&&mission_builds==builds);
        // A joining foreign row retains its own role8 and receives no callback.
        put<uint32_t>(pm+0x70,2);auto foreign=pm+0x53D8B0+0x1238;put<uint64_t>(foreign+0xFD0,0xA0A);put<uint32_t>(pm+0x53D8B0+0xFD8,0x400000);assert(mh::stop(e));assert(mh::value<uint64_t>(foreign+0xFD0)==0xA0A&&foreign_removals==0&&global_calls==0);put<uint32_t>(pm+0x70,1);
        assert(mh::status().stopped&&!mh::status().widgets_ready&&!mh::status().active&&!mh::status().role8_owned);assert(mh::value<uint8_t>(ui+mh::S)==0&&mh::value<uint64_t>(pm+0x53D8B0+0xFD0)==0x202);assert(mh::value<int32_t>(gui+0x2C5BC)==d&&std::memcmp(old.data(),reinterpret_cast<void*>(gui+0x2C5B8),4)==0);const auto destroys=mission_destroys;assert(mh::stop(e)&&mission_destroys==destroys);assert(mh::release(e));
    }
    put<int32_t>(gui+0x2C5BC,-1);prepare(e);hide_mission_init=true;assert(!mh::start(e));assert(mh::status().phase==mh::Phase::MissionInitReturned);const auto builds=mission_builds;assert(!mh::start(e)&&mission_builds==builds);unreadable=0;assert(mh::start(e)&&mission_builds==builds);hide_mission_destroy=true;assert(!mh::stop(e));const auto destroys=mission_destroys;assert(mh::status().phase==mh::Phase::MissionDestroyReturned);assert(!mh::stop(e)&&mission_destroys==destroys);unreadable=0;assert(mh::stop(e)&&mission_destroys==destroys);assert(mh::release(e));
    // Ordinary global calls retain their original semantics.
    prepare(e);assert(mh::start(e));auto foreign=pm+0x53D8B0+0x1238;put<uint32_t>(pm+0x70,2);put<uint64_t>(foreign+0xFD0,8);alignas(16)const uint64_t mask[3]={8,0,0};mh::remove_hook(mask);assert(global_calls==1&&foreign_removals==1);put<uint32_t>(pm+0x70,1);assert(mh::stop(e)&&mh::release(e));
    // A live but unreadable old owner cannot be substituted with a new avatar.
    prepare(e);assert(mh::start(e));unreadable=descriptor+8;assert(!mh::stop(e));const auto forwarded=original_destroy;mh::destroy_hook(reinterpret_cast<void*>(ui));assert(original_destroy==forwarded&&mh::status().lifecycle_blocked);unreadable=0;assert(mh::stop(e)&&mh::release(e));
    // Positive old Unit retirement permits scoped skip without touching old PC.
    prepare(e);assert(mh::start(e));put<uint8_t>(generations+14,2);unreadable=descriptor+8;mh::destroy_hook(reinterpret_cast<void*>(ui));assert(original_destroy==forwarded+1&&mh::status().retired_safe&&mh::status().stopped);assert(mh::release(e));unreadable=0;put<uint8_t>(generations+14,1);put<uint64_t>(pm+0x53D8B0+0xFD0,0x202);ui_init(reinterpret_cast<void*>(ui));
    prepare(e);assert(mh::start(e));const auto ship_count=ship_builds;mh::init_hook(reinterpret_cast<void*>(ui));assert(original_init>=1&&ship_builds==ship_count&&mh::status().stopped);assert(mh::release(e));
    // Reentrant common UI entry during constructor must not forward.
    prepare(e);reenter=true;assert(mh::start(e));assert(mh::stop(e)&&mh::release(e));
    // Off-thread operations and foreign UI callbacks preserve the owned HUD.
    prepare(e);assert(mh::start(e));bool wrong=true;std::thread other([&]{std::string why;wrong=mh::stop(why);});other.join();assert(!wrong);mh::init_hook(reinterpret_cast<void*>(ui+16));mh::destroy_hook(reinterpret_cast<void*>(ui+16));assert(foreign_calls==2);assert(mh::stop(e)&&mh::release(e));
    std::cout<<"PASS direct Mission HUD: readonly preflight, three disabled hooks, enable failure rollback, all GUI depths, distinct PID, complete widget lifecycle, scoped owner-only role removal, foreign rows, returned-call retries, positive retirement, pre-lifecycle teardown, reentrancy and thread guards; synthetic native only\n";
}
