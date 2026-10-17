// Isolated synthetic modules. No real game DLL is loaded or called.
#define BC_WEAPON_UI_FIXTURE
#include "../native/weapon_ui_review.cpp"
#include <cassert>
#include <iostream>
#include <vector>
namespace {
namespace w=bc::weapon_ui_review;
uintptr_t game{},exe{},ui{},pm{},player{},world{},state{},gui{},observer{},aux{},desc{},local{},registry{},gens{},units{},unit{},menu{},aux_records{};
constexpr uint32_t pid=5,avatar=251,reference=0x40000E;
ULONGLONG time_ms=1000;
unsigned sibling_builds{},wheel_builds{},adds{},removes{},destroys{},ticks{},attaches{};
unsigned alpha_sets{},late_animation_allocations{};
bool cancel_pending{},fault_tick{},partial_sibling{},partial_wheel{},fault_attach{},hidden_destroy{},reenter{};
bool authored_close_model{},fault_alpha{},foreign_alpha_dirty{};
uintptr_t unreadable{};
uintptr_t torn_generations{},torn_unit{};unsigned generation_reads{},slot_reads{};bool tear_generations{},tear_slot{};
std::vector<std::string> calls;
template<class T>void put(uintptr_t p,T v){*reinterpret_cast<T*>(p)=v;}
uintptr_t alloc(size_t n,DWORD mode=PAGE_READWRITE){auto p=reinterpret_cast<uintptr_t>(VirtualAlloc(nullptr,n,MEM_COMMIT|MEM_RESERVE,mode));assert(p);return p;}
void bytes(uintptr_t p,const char* h){auto d=[](char c){return c>='0'&&c<='9'?c-'0':c-'a'+10;};for(size_t i=0;h[i];i+=2)put<uint8_t>(p+i/2,static_cast<uint8_t>((d(h[i])<<4)|d(h[i+1])));}
void map(uintptr_t p,uint32_t key,uint32_t row){auto rows=alloc(64);for(unsigned i=0;i<8;++i)put<uint32_t>(rows+i*8,UINT32_MAX);put(p,rows);put<uint32_t>(p+8,8);put<uint32_t>(p+12,UINT32_MAX);put<uint32_t>(p+16,1);put<uint32_t>(rows+(key&7)*8,key);put<uint32_t>(rows+(key&7)*8+4,row);}
bool reader(uintptr_t p,void* to,size_t n){if(unreadable&&p<=unreadable&&unreadable<p+n)return false;if(tear_generations&&p==registry+0xA0&&n==8&&++generation_reads==2)put(registry+0xA0,torn_generations);if(tear_slot&&p==units+14*8&&n==8&&++slot_reads==2)put(units+14*8,torn_unit);return w::raw_read(p,to,n);}
bool writer(uintptr_t p,const void* from,size_t n){return w::raw_write(p,from,n);}
void widget(uintptr_t p,uintptr_t parent=0){put<uint32_t>(p,0x41011);put(p+0xF0,parent);put(p+0xF8,gui+5*0x3698);}
void component(uintptr_t p){widget(p);widget(p+0x110,p);widget(p+0x220,p);put(p+0xE0,p+0x110);put(p+0x110+0xE8,p+0x220);}
void check_scope(){auto depth=w::value<int32_t>(gui+0x2C5BC);assert(depth==0&&w::value<uint8_t>(gui+0x2C5B8)==5);}
void __fastcall sibling(void* p,uint32_t arg){assert(reinterpret_cast<uintptr_t>(p)==ui+w::SIBLING&&arg==0x1F4);check_scope();++sibling_builds;calls.push_back("sibling");component(reinterpret_cast<uintptr_t>(p));if(reenter){std::string e;assert(!w::start({game,exe,pid,avatar,GetCurrentThreadId()},20,true,e));}if(partial_sibling)RaiseException(0xE0000042,0,0,nullptr);}
void __fastcall wheel(void* p,uint64_t packed,uint32_t arg){assert(reinterpret_cast<uintptr_t>(p)==ui+w::WHEEL&&packed==0x3F0000003F000000ULL&&arg==0x258);check_scope();++wheel_builds;calls.push_back("wheel");component(reinterpret_cast<uintptr_t>(p));put<uint8_t>(reinterpret_cast<uintptr_t>(p)+0xBCD0,1);if(partial_wheel)RaiseException(0xE0000043,0,0,nullptr);}
void __fastcall attach(void* parent,void* child){assert(reinterpret_cast<uintptr_t>(parent)==ui+0x820);++attaches;auto p=reinterpret_cast<uintptr_t>(child);put(p+0xF0,ui+0x820);put(p+0xE8,w::value<uintptr_t>(ui+0x820+0xE0));put(ui+0x820+0xE0,p);if(fault_attach)RaiseException(0xE0000044,0,0,nullptr);}
void __fastcall flush(void* p){assert(reinterpret_cast<uintptr_t>(p)==ui+0x820);}
void __fastcall add(void* action,const uint64_t* mask){assert(reinterpret_cast<uintptr_t>(action)==pm+0x53D8B0+0x50&&mask[0]==8&&!mask[1]&&!mask[2]);++adds;calls.push_back("add");put<uint64_t>(pm+0x53D8B0+0xFD0,w::value<uint64_t>(pm+0x53D8B0+0xFD0)|8);}
void __fastcall remove(void* action,const uint64_t* mask){assert(reinterpret_cast<uintptr_t>(action)==pm+0x53D8B0+0x50&&mask[0]==8&&!mask[1]&&!mask[2]);++removes;calls.push_back("remove");put<uint64_t>(pm+0x53D8B0+0xFD0,w::value<uint64_t>(pm+0x53D8B0+0xFD0)&~8ULL);if(!cancel_pending){
    const bool action86=(w::value<uint32_t>(pm+0x53D8B0+0xFD8)&0x400000)!=0;put<uint32_t>(pm+0x53D8B0+0xFD8,0);
    // Model the actual authored close branch, including its dangerous late
    // alpha allocation. This is independent of the lease's cleanup order.
    if(authored_close_model&&action86&&!w::value<uint8_t>(ui+w::WHEEL+0xBCD0)){
        put<uint8_t>(ui+w::WHEEL+0xBCD0,1);
        if(w::value<float>(ui+w::WHEEL+0x44)!=0.0f)++late_animation_allocations;
        put<uint8_t>(aux_records+5,0);
    }else if(!authored_close_model)put<uint8_t>(aux_records+5,0);
}}
void __fastcall alpha_zero(void* p,float a){assert(reinterpret_cast<uintptr_t>(p)==ui+w::WHEEL&&a==0.0f);assert(w::retired_node(ui+w::WHEEL,false));++alpha_sets;calls.push_back("alpha-zero");
    if(w::value<float>(ui+w::WHEEL+0x44)!=a){put<float>(ui+w::WHEEL+0x44,a);put<uint32_t>(ui+w::WHEEL+0xB8,w::value<uint32_t>(ui+w::WHEEL+0xB8)|0x20);put<uint32_t>(ui+w::WHEEL,4);}
    if(foreign_alpha_dirty)put<uint32_t>(ui+w::WHEEL,12);if(fault_alpha)RaiseException(0xE0000046,0,0,nullptr);
}
void __fastcall sibling_tick(void* p,float dt,uint32_t player_id){assert(reinterpret_cast<uintptr_t>(p)==ui+w::SIBLING&&dt==0.016f&&player_id==pid);calls.push_back("sibling-tick");}
void __fastcall wheel_tick(void* p,float dt,uint32_t player_id,uint32_t avatar_id){assert(reinterpret_cast<uintptr_t>(p)==ui+w::WHEEL&&dt==0.016f&&player_id==pid&&avatar_id==avatar&&player_id!=avatar_id);++ticks;calls.push_back("wheel-tick");if(fault_tick)RaiseException(0xE0000045,0,0,nullptr);}
void retire_component(uintptr_t base){const auto parent=w::value<uintptr_t>(base+0xF0);if(parent){uintptr_t link=parent+0xE0;for(unsigned i=0;i<16;++i){auto child=w::value<uintptr_t>(link);if(!child)break;if(child==base){put(link,w::value<uintptr_t>(base+0xE8));break;}link=child+0xE8;}}for(uintptr_t n:{base,base+0x110,base+0x220}){put<uint32_t>(n,0);for(uintptr_t off:{0xA8ULL,0xB0ULL,0xE0ULL,0xE8ULL,0xF0ULL,0xF8ULL,0x100ULL,0x108ULL})put<uintptr_t>(n+off,0);}}
void __fastcall destroy(void* p){auto base=reinterpret_cast<uintptr_t>(p);assert(base==ui+w::WHEEL||base==ui+w::SIBLING);assert(!(w::value<uint64_t>(pm+0x53D8B0+0xFD0)&8)&&!(w::value<uint32_t>(pm+0x53D8B0+0xFD8)&0x400000)&&w::value<uint8_t>(aux_records+5)==0);++destroys;calls.push_back(base==ui+w::WHEEL?"destroy-wheel":"destroy-sibling");if(w::journal.generic_retired)assert(base==ui+w::WHEEL&&w::retired_node(base,true));retire_component(base);if(hidden_destroy&&destroys==1)unreadable=base;}
void bind(){w::construct_wheel=wheel;w::construct_sibling=sibling;w::update_wheel=wheel_tick;w::update_sibling=sibling_tick;w::attach=attach;w::flush=flush;w::destroy=destroy;w::add_role=add;w::remove_role=remove;w::set_alpha=alpha_zero;}
void fixture(){assert(!GetModuleHandleW(L"game.dll"));game=alloc(0x3500000,PAGE_EXECUTE_READWRITE);exe=alloc(0x1A11000);ui=alloc(0x500000);pm=alloc(0x550000);player=alloc(0x1000);world=alloc(0xF40000);state=alloc(0xAF000);gui=alloc(0x30000);observer=alloc(0x4000);aux=alloc(0x1000);desc=alloc(0x1000);local=alloc(0x1000);registry=alloc(0x1000);gens=alloc(0x1000);units=alloc(0x1000);unit=alloc(0x1000);menu=alloc(0x5000);aux_records=alloc(0x1000);
    for(auto pair:{std::pair<uintptr_t,uint32_t>{game,0x6AB3B43F},{exe,0x6AB382E4}}){put<uint16_t>(pair.first,0x5A4D);put<int32_t>(pair.first+0x3C,0x100);put<uint32_t>(pair.first+0x100,0x4550);put(pair.first+0x108,pair.second);}for(auto p:{std::pair<uintptr_t,uintptr_t>{w::UI,ui},{w::PM,pm},{w::PLAYER,player},{w::WORLD,world},{w::GS,state},{w::GUI,gui},{w::OBSERVER,observer},{w::AUX,aux},{0x347CE28,menu}})put(game+p.first,p.second);
    for(auto a:w::abi)bytes(game+a.first,a.second);put<uint32_t>(state+0xAC21C,3);put<uint32_t>(pm+0x70,1);map(pm+0xF8,avatar,0);put(pm+0x110,desc);put<uint32_t>(desc+8,avatar);put<uint32_t>(desc+12,reference);put<uint8_t>(desc+20,1);put<uint64_t>(pm+0x53D8B0+0xFD0,0x202);put<uint32_t>(player+0x88,1);put(player+0xE8,local);put<uint32_t>(local+8,pid);map(player+0xD0,pid,0);put<uint32_t>(player+0x3A8,14);map(world+0xF22EC8,14,0);put<uint32_t>(world+0xF32F18+8,avatar);map(aux+0x30,avatar,0);put(aux+0x58,aux_records);
    put(exe+0x1A100F0,registry);put<uint32_t>(registry+0x98,100);put(registry+0xA0,gens);put(registry+0x88,units);put<uint8_t>(gens+14,1);put(units+14*8,unit);put<uint32_t>(unit+8,reference);put<uint8_t>(ui+0x24E334,1);put<uint8_t>(ui+w::SINIT,1);put<uint8_t>(ui+w::SACTIVE,1);widget(ui+0x820,ui+0x258);put<float>(ui+0x24E324,1.25f);put<int32_t>(gui+0x2C5BC,-1);put<uint8_t>(gui+0x2C5B8,23);
    auto engine=alloc(0x1000),api=alloc(0x1000);put(game+0x3326308,engine);put(engine+0xD0,api);for(uintptr_t s:{0x118ULL,0x180ULL,0x230ULL,0x238ULL,0x240ULL,0x2B8ULL})put(api+s,game+0x1000);w::fixture_bind=bind;w::fixture_clock=[](){return time_ms;};
}
bool start(std::string& e,float seconds=20,bool ready=true){return w::start({game,exe,pid,avatar,GetCurrentThreadId()},seconds,ready,e,{reader,writer});}
void clean(std::string& e){assert(w::stop(e));assert(!w::status().owned&&w::status().stopped&&!w::status().pending&&w::status().phase==w::Phase::Stopped);assert(adds==1&&removes==1&&destroys==2&&w::value<uint64_t>(pm+0x53D8B0+0xFD0)==0x202);assert(w::value<int32_t>(gui+0x2C5BC)==-1&&w::value<uint8_t>(gui+0x2C5B8)==23);auto before=destroys;assert(w::stop(e)&&destroys==before);assert(!start(e));}
}
int main(int argc,char** argv){fixture();std::string e;std::string mode=argc>1?argv[1]:"ordinary";
    if(mode=="duration"||mode=="not-ready"||mode=="role-preexisting"||mode=="wrong-root"||mode=="aux-missing"||mode=="menu-initial"){
        if(mode=="role-preexisting")put<uint64_t>(pm+0x53D8B0+0xFD0,0x20A);if(mode=="wrong-root")put(ui+0x820+0xF8,gui+4*0x3698);if(mode=="aux-missing")put<uintptr_t>(aux+0x58,0);if(mode=="menu-initial")put<uint32_t>(menu+0x4294,1);
        assert(!start(e,mode=="duration"?61.f:20.f,mode!="not-ready"));assert(!sibling_builds&&!wheel_builds&&!adds&&!destroys&&!w::status().owned);std::cout<<"PASS pure preflight "<<mode<<"\n";return 0;
    }
    partial_sibling=mode=="partial-sibling";partial_wheel=mode=="partial-wheel";fault_attach=mode=="attach-fault";reenter=mode=="reenter";
    if(partial_sibling||partial_wheel||fault_attach){assert(!start(e));assert(w::status().phase==w::Phase::Interrupted&&w::status().pending&&!w::status().active);auto builds=sibling_builds+wheel_builds;assert(!w::stop(e)&&destroys==0&&!adds);assert(!start(e)&&sibling_builds+wheel_builds==builds);assert(e.find("native_exception")!=std::string::npos);assert(w::value<int32_t>(gui+0x2C5BC)==-1);std::cout<<"PASS interrupted native ownership retained "<<mode<<"\n";return 0;}
    assert(start(e));assert(w::status().active&&w::status().owned&&w::status().role8_owned&&adds==1&&sibling_builds==1&&wheel_builds==1&&attaches==2);assert(w::value<uint8_t>(ui+w::MINIT)==0&&w::value<uint8_t>(ui+w::MACTIVE)==0&&w::value<uint8_t>(ui+w::SINIT)==1);
    if(mode.rfind("retired-",0)==0){
        authored_close_model=true;put<uint32_t>(pm+0x53D8B0+0xFD8,0x400000);put<uint8_t>(aux_records+5,1);put<uint8_t>(ui+w::WHEEL+0xBCD0,0);put<float>(ui+w::WHEEL+0x44,1.0f);
        retire_component(ui+w::WHEEL);if(mode!="retired-partial")retire_component(ui+w::SIBLING);
        if(mode=="retired-opaque")unreadable=ui+w::WHEEL+0x110+0xF8;
        if(mode=="retired-foreign-link")put<uintptr_t>(ui+w::WHEEL+0x100,alloc(0x1000));
        if(mode=="retired-still-root-linked")put<uintptr_t>(ui+0x820+0xE0,ui+w::WHEEL);
        if(mode=="retired-foreign-ui")put<uintptr_t>(game+w::UI,alloc(0x500000));
        if(mode=="retired-actor-replaced")put<uint8_t>(gens+14,2);
        if(mode=="retired-native-mission"){put<uint32_t>(state+0xAC21C,4);put<uint8_t>(ui+w::MINIT,1);}
        if(mode=="retired-mission-on-ship")put<uint8_t>(ui+w::MINIT,1);
        if(mode=="retired-aux-inconsistent")put<uint8_t>(ui+w::WHEEL+0xBCD0,1);
        if(mode=="retired-action-inconsistent")put<uint32_t>(pm+0x53D8B0+0xFD8,0);
        if(mode=="retired-invalid-alpha")put<float>(ui+w::WHEEL+0x44,NAN);
        if(mode=="retired-foreign-alpha")foreign_alpha_dirty=true;
        if(mode=="retired-alpha-fault")fault_alpha=true;
        if(mode=="retired-pending")cancel_pending=true;
        if(mode=="retired-closed"||mode=="retired-already-cancelled"){put<uint8_t>(ui+w::WHEEL+0xBCD0,1);put<uint32_t>(pm+0x53D8B0+0xFD8,0);put<uint8_t>(aux_records+5,0);}
        if(mode=="retired-already-cancelled")put<uint64_t>(pm+0x53D8B0+0xFD0,0x202);
        if(mode=="retired-alpha-zero")put<float>(ui+w::WHEEL+0x44,0.0f);
        if(mode=="retired-array-move"){auto ng=alloc(0x1000),nu=alloc(0x1000);std::memcpy(reinterpret_cast<void*>(ng),reinterpret_cast<void*>(gens),0x1000);std::memcpy(reinterpret_cast<void*>(nu),reinterpret_cast<void*>(units),0x1000);put(registry+0xA0,ng);put(registry+0x88,nu);}
        if(mode=="retired-oracle-unsafe"){alignas(16)const uint64_t mask[3]={8,0,0};remove(reinterpret_cast<void*>(pm+0x53D8B0+0x50),mask);assert(late_animation_allocations==1&&!alpha_sets);std::cout<<"PASS independent native-close model detects unsafe late allocation\n";return 0;}
        const auto count=calls.size();const bool result=w::tick(.016f,pid,avatar,true,e);
        if(mode=="retired-partial"||mode=="retired-opaque"||mode=="retired-foreign-link"||mode=="retired-still-root-linked"||mode=="retired-foreign-ui"||mode=="retired-actor-replaced"||mode=="retired-native-mission"||mode=="retired-mission-on-ship"||mode=="retired-aux-inconsistent"||mode=="retired-action-inconsistent"||mode=="retired-invalid-alpha"){
            assert(!result&&calls.size()==count&&!alpha_sets&&!removes&&!destroys&&w::status().pending);assert(!w::stop(e)&&calls.size()==count);std::cout<<"PASS retired preflight refuses "<<mode<<"\n";return 0;
        }
        if(mode=="retired-foreign-alpha"){assert(!result&&alpha_sets==1&&!removes&&!destroys);assert(!w::stop(e)&&alpha_sets==1&&!removes&&!destroys);std::cout<<"PASS foreign post-alpha flags retain owner\n";return 0;}
        if(mode=="retired-alpha-fault"){assert(!result&&alpha_sets==1&&w::status().phase==w::Phase::Interrupted&&!removes&&!destroys);assert(!w::stop(e)&&alpha_sets==1);std::cout<<"PASS retired alpha interruption never replays\n";return 0;}
        if(mode=="retired-pending"){assert(!result&&alpha_sets==1&&removes==1&&!destroys&&w::status().pending);assert(!w::stop(e)&&alpha_sets==1&&removes==1&&!destroys);cancel_pending=false;put<uint32_t>(pm+0x53D8B0+0xFD8,0);put<uint8_t>(aux_records+5,0);put<uint8_t>(ui+w::WHEEL+0xBCD0,1);assert(w::stop(e));}
        else assert(result);
        assert(w::status().stopped&&!w::status().owned&&!w::status().pending&&!w::status().role8_owned&&w::tree_absent(w::wheel_tree)&&w::tree_absent(w::sibling_tree));
        assert(!late_animation_allocations&&!ticks&&w::value<uint64_t>(pm+0x53D8B0+0xFD0)==0x202&&w::value<uint32_t>(pm+0x53D8B0+0xFD8)==0&&w::value<uint8_t>(aux_records+5)==0);
        if(mode=="retired-already-cancelled")assert(!alpha_sets&&!removes&&!destroys);
        else {assert(alpha_sets==1&&removes==1&&destroys==(mode=="retired-alpha-zero"?0u:1u));assert(calls[count]=="alpha-zero"&&calls[count+1]=="remove");}
        const auto final=calls.size();assert(w::stop(e)&&calls.size()==final);assert(w::rearm(e)&&calls.size()==final);std::cout<<"PASS authored generic retirement cleanup "<<mode<<"\n";return 0;
    }
    if(mode=="rearm"||mode=="rearm-refuse"){
        auto before=calls.size();assert(!w::rearm(e)&&calls.size()==before);assert(w::stop(e));before=calls.size();
        if(mode=="rearm-refuse"){put<uint64_t>(pm+0x53D8B0+0xFD0,0x20A);assert(!w::rearm(e)&&calls.size()==before&&w::status().phase==w::Phase::Stopped);put<uint64_t>(pm+0x53D8B0+0xFD0,0x202);put<uint32_t>(ui+w::WHEEL,1);assert(!w::rearm(e));put<uint32_t>(ui+w::WHEEL,0);}
        assert(w::rearm(e)&&calls.size()==before&&w::status().phase==w::Phase::None);assert(start(e)&&sibling_builds==2&&wheel_builds==2&&adds==2);assert(w::stop(e)&&removes==2&&destroys==4&&w::status().stopped);std::cout<<"PASS explicit clean rearm "<<mode<<"\n";return 0;
    }
    if(mode=="generation-array-move"||mode=="both-arrays-move"){
        auto next_gen=alloc(0x1000);std::memcpy(reinterpret_cast<void*>(next_gen),reinterpret_cast<void*>(gens),0x1000);put(registry+0xA0,next_gen);
        if(mode=="both-arrays-move"){auto next_units=alloc(0x1000);std::memcpy(reinterpret_cast<void*>(next_units),reinterpret_cast<void*>(units),0x1000);put(registry+0x88,next_units);}
    }
    if(mode=="actor-retired"||mode=="root-retired"||mode=="observer-changed"||mode=="tree-changed"||mode=="slot-changed"||mode=="torn-arrays"||mode=="torn-slot"){
        if(mode=="actor-retired")put<uint8_t>(gens+14,2);if(mode=="root-retired")put<uint8_t>(ui+0x24E334,0);if(mode=="observer-changed")put<uint32_t>(observer+w::count_offsets[0],1);if(mode=="tree-changed")put<uintptr_t>(ui+w::WHEEL+0x110+0xF0,0);
        if(mode=="slot-changed")put(units+14*8,alloc(0x1000));if(mode=="torn-arrays"){torn_generations=alloc(0x1000);std::memcpy(reinterpret_cast<void*>(torn_generations),reinterpret_cast<void*>(gens),0x1000);tear_generations=true;}if(mode=="torn-slot"){torn_unit=alloc(0x1000);tear_slot=true;}
        auto count=calls.size();assert(!w::tick(.016f,pid,avatar,true,e)&&calls.size()==count);
        if(mode=="torn-arrays"){assert(w::status().pending&&!w::status().active);tear_generations=false;clean(e);std::cout<<"PASS torn array snapshot withheld calls and recovered after stable proof\n";return 0;}
        assert(!w::stop(e)&&calls.size()==count&&w::status().pending);std::cout<<"PASS no stale native calls "<<mode<<"\n";return 0;
    }
    if(mode=="tick-fault"){fault_tick=true;assert(!w::tick(.016f,pid,avatar,true,e)&&w::status().phase==w::Phase::Interrupted);assert(!w::stop(e)&&destroys==0&&removes==0);std::cout<<"PASS update fault pins journal\n";return 0;}
    if(mode=="cancel-pending"){cancel_pending=true;put<uint32_t>(pm+0x53D8B0+0xFD8,0x400000);put<uint8_t>(aux_records+5,1);assert(!w::stop(e)&&removes==1&&destroys==0&&w::status().pending);put<uint32_t>(pm+0x53D8B0+0xFD8,0);put<uint8_t>(aux_records+5,0);clean(e);std::cout<<"PASS cancellation ack before teardown, no replay\n";return 0;}
    if(mode=="destroy-ack"){hidden_destroy=true;assert(!w::stop(e)&&destroys==1&&w::status().pending);unreadable=0;clean(e);std::cout<<"PASS teardown readback retry, no replay\n";return 0;}
    if(mode=="deadline"){time_ms=22000;assert(w::tick(.016f,pid,avatar,true,e)&&w::status().expired&&ticks==0);}
    else if(mode=="menu-pause"){put<uint32_t>(menu+0x4298,1);assert(w::tick(.016f,pid,avatar,true,e)&&ticks==0);}
    else if(mode=="photo-pause")assert(w::tick(.016f,pid,avatar,false,e)&&ticks==0);
    else if(mode=="wrong-pid")assert(w::tick(.016f,pid+1,avatar,true,e)&&ticks==0);
    else assert(w::tick(.016f,pid,avatar,true,e)&&ticks==1);
    clean(e);std::cout<<"PASS bounded native component lifecycle "<<mode<<"\n";return 0;
}
