// Isolated synthetic modules. No real game DLL is loaded or called.
#define BC_WEAPON_MENU_FIXTURE
#include "../native/weapon_menu.cpp"
#include <cassert>
#include <iostream>
#include <vector>
namespace {
namespace w=bc::weapon_menu;
uintptr_t game{},exe{},ui{},pm{},player{},world{},state{},gui{},observer{},aux{},desc{},local{},registry{},gens{},units{},unit{},menu{},aux_records{};
constexpr uint32_t pid=5,avatar=251,reference=0x40000E;
uintptr_t gui_api{};unsigned deletes{};bool delete_retires{},delete_reenters{};
unsigned sibling_builds{},wheel_builds{},drop_builds{},adds{},removes{},destroys{},ticks{},drop_ticks{},attaches{};
unsigned orphan_destroys{};bool orphan_fault{},orphan_ack_delay{};
unsigned alpha_sets{},late_animation_allocations{};
unsigned fingerprint_reads{},fingerprint_bytes{},memory_queries{};
bool query_fails{},change_fingerprint_after_sibling{},change_protection_after_sibling{};
bool cancel_pending{},fault_tick{},partial_sibling{},partial_wheel{},fault_attach{},hidden_destroy{},reenter{};
bool partial_drop{},missing_drop_material{},missing_drop_child{},foreign_drop_parent{},drop_cancel_pending{},fault_drop_tick{};
bool authored_close_model{},fault_alpha{},foreign_alpha_dirty{},lose_witness_ctor{},dirty_fault{},dirty_ack_delay{};unsigned dirty_normalizations{};
uintptr_t unreadable{};
uintptr_t torn_generations{},torn_unit{};unsigned generation_reads{},slot_reads{};bool tear_generations{},tear_slot{};
std::vector<std::string> calls;
template<class T>void put(uintptr_t p,T v){*reinterpret_cast<T*>(p)=v;}
uintptr_t alloc(size_t n,DWORD mode=PAGE_READWRITE){auto p=reinterpret_cast<uintptr_t>(VirtualAlloc(nullptr,n,MEM_COMMIT|MEM_RESERVE,mode));assert(p);return p;}
void bytes(uintptr_t p,const char* h){auto d=[](char c){return c>='0'&&c<='9'?c-'0':c-'a'+10;};for(size_t i=0;h[i];i+=2)put<uint8_t>(p+i/2,static_cast<uint8_t>((d(h[i])<<4)|d(h[i+1])));}
void map(uintptr_t p,uint32_t key,uint32_t row){auto rows=alloc(64);for(unsigned i=0;i<8;++i)put<uint32_t>(rows+i*8,UINT32_MAX);put(p,rows);put<uint32_t>(p+8,8);put<uint32_t>(p+12,UINT32_MAX);put<uint32_t>(p+16,1);put<uint32_t>(rows+(key&7)*8,key);put<uint32_t>(rows+(key&7)*8+4,row);}
bool reader(uintptr_t p,void* to,size_t n){for(auto a:w::abi)if(p>=game+a.first&&p-game-a.first<std::strlen(a.second)/2){++fingerprint_reads;fingerprint_bytes+=static_cast<unsigned>(n);break;}if(unreadable&&p<=unreadable&&unreadable<p+n)return false;if(tear_generations&&p==registry+0xA0&&n==8&&++generation_reads==2)put(registry+0xA0,torn_generations);if(tear_slot&&p==units+14*8&&n==8&&++slot_reads==2)put(units+14*8,torn_unit);return w::raw_read(p,to,n);}
SIZE_T query(LPCVOID p,PMEMORY_BASIC_INFORMATION m,SIZE_T n){++memory_queries;return query_fails?0:VirtualQuery(p,m,n);}
bool writer(uintptr_t p,const void* from,size_t n){return w::raw_write(p,from,n);}
void widget(uintptr_t p,uintptr_t parent=0){put<uint32_t>(p,0x41011);put(p+0xF0,parent);put(p+0xF8,gui+5*0x3698);}
void component(uintptr_t p){widget(p);widget(p+0x110,p);widget(p+0x220,p);put(p+0xE0,p+0x110);put(p+0x110+0xE8,p+0x220);}
void drop_component(uintptr_t base){
    // Actual false-fifth-argument ctor still invokes143EAB0 at1829B56.
    // This primitive is never attached to Drop's recursive child tree.
    const auto orphan=base+0x330;widget(orphan);put<uint32_t>(orphan,0xC0011);put<uint32_t>(orphan+0x110,UINT32_MAX);put<uint64_t>(orphan+0x114,0);put<uint64_t>(orphan+0x11C,0x3F8000003F800000ULL);put<uintptr_t>(orphan+0x148,0);put<uintptr_t>(orphan+0x150,0);
    for(auto off:w::drop_nodes)widget(base+off,base+(off==0?0:off==0x110||off==0x220?0:off==0x488||off==0x738||off==0xB40||off==0xC98||off==0xF50?0x220:0x110));
    auto link=[&](uintptr_t parent,const std::vector<uintptr_t>& offsets){put(base+parent+0xE0,base+offsets.front());for(size_t i=0;i<offsets.size();++i)put<uintptr_t>(base+offsets[i]+0xE8,i+1<offsets.size()?base+offsets[i+1]:0);};
    put<uintptr_t>(base+0xF0,0);link(0,{0x110,0x220});link(0x110,{0x890,0x5E0,0x1208,0x1360,0x14B8,0x1610,0x1768,0x18C0,0x1A18,0x1B70});link(0x220,{0x488,0x738,0xB40,0xC98,0xF50});
    for(auto off:w::drop_images){put<uint32_t>(base+off,0xC1013);put<uintptr_t>(base+off+0x148,alloc(0x1000));}
    put<uint32_t>(base+0x1CE0,0);put<uint8_t>(base+0x1CD0,1);put<uint8_t>(base+0x1CF0,0);
}
void __fastcall drop(void* p,uint64_t packed,uint32_t order,uint32_t type,bool extra){const auto base=reinterpret_cast<uintptr_t>(p);assert(base==ui+w::DROP&&packed==0x3F0000003F000000ULL&&order==0x258&&type==0&&!extra);const auto depth=w::value<int32_t>(gui+0x2C5BC);assert(depth==0&&w::value<uint8_t>(gui+0x2C5B8)==5);assert(!(w::value<uint64_t>(pm+0x53D8B0+0xFD0)&8));++drop_builds;calls.push_back("drop");if(partial_drop){widget(base);RaiseException(0xE0000049,0,0,nullptr);}drop_component(base);if(missing_drop_child)put<uintptr_t>(base+0x1A18+0xE8,0);if(foreign_drop_parent)put(base+0x1208+0xF0,base+0x220);}
uintptr_t __fastcall material(void* p){const auto node=reinterpret_cast<uintptr_t>(p);if(missing_drop_material&&node==ui+w::DROP+0x1208)return 0;return w::value<uintptr_t>(node+0x148);}
void check_scope(){auto depth=w::value<int32_t>(gui+0x2C5BC);assert(depth==0&&w::value<uint8_t>(gui+0x2C5B8)==5);}
void __fastcall sibling(void* p,uint32_t arg){assert(reinterpret_cast<uintptr_t>(p)==ui+w::SIBLING&&arg==0x1F4);check_scope();++sibling_builds;calls.push_back("sibling");component(reinterpret_cast<uintptr_t>(p));if(reenter){std::string e;assert(!w::acquire({game,exe,pid,avatar,GetCurrentThreadId()},true,e));}if(partial_sibling)RaiseException(0xE0000042,0,0,nullptr);}
void __fastcall wheel(void* p,uint64_t packed,uint32_t arg){assert(reinterpret_cast<uintptr_t>(p)==ui+w::WHEEL&&packed==0x3F0000003F000000ULL&&arg==0x258);check_scope();++wheel_builds;calls.push_back("wheel");component(reinterpret_cast<uintptr_t>(p));put<uint8_t>(reinterpret_cast<uintptr_t>(p)+0xBCD0,1);if(lose_witness_ctor)put<uintptr_t>(ui+0x46D900+0x490+0x148,0);if(partial_wheel)RaiseException(0xE0000043,0,0,nullptr);}
void __fastcall attach(void* parent,void* child){assert(reinterpret_cast<uintptr_t>(parent)==ui+0x820);++attaches;auto p=reinterpret_cast<uintptr_t>(child);put(p+0xF0,ui+0x820);put(p+0xE8,w::value<uintptr_t>(ui+0x820+0xE0));put(ui+0x820+0xE0,p);if(fault_attach)RaiseException(0xE0000044,0,0,nullptr);}
void __fastcall flush(void* p){assert(reinterpret_cast<uintptr_t>(p)==ui+0x820);}
void __fastcall add(void* action,const uint64_t* mask){assert(reinterpret_cast<uintptr_t>(action)==pm+0x53D8B0+0x50&&mask[0]==8&&!mask[1]&&!mask[2]);std::string guard;assert(drop_builds&&w::journal.attach_drop==3&&w::tree_present(w::drop_tree,guard));for(auto off:w::drop_images)assert(material(reinterpret_cast<void*>(ui+w::DROP+off)));++adds;calls.push_back("add");put<uint64_t>(pm+0x53D8B0+0xFD0,w::value<uint64_t>(pm+0x53D8B0+0xFD0)|8);}
void __fastcall remove(void* action,const uint64_t* mask){assert(reinterpret_cast<uintptr_t>(action)==pm+0x53D8B0+0x50&&mask[0]==8&&!mask[1]&&!mask[2]);++removes;calls.push_back("remove");put<uint64_t>(pm+0x53D8B0+0xFD0,w::value<uint64_t>(pm+0x53D8B0+0xFD0)&~8ULL);if(!cancel_pending){
    const bool action91=(w::value<uint32_t>(pm+0x53D8B0+0xFD8)&0x08000000)!=0;
    const bool action86=(w::value<uint32_t>(pm+0x53D8B0+0xFD8)&0x400000)!=0;put<uint32_t>(pm+0x53D8B0+0xFD8,drop_cancel_pending&&action91?0x08000000:0);
    if(action91&&!drop_cancel_pending){assert(!w::retired_node(ui+w::DROP,false));put<uint8_t>(ui+w::DROP+0x1CD0,1);calls.push_back("drop-close");}
    // Model the actual authored close branch, including its dangerous late
    // alpha allocation. This is independent of the lease's cleanup order.
    if(authored_close_model&&action86&&!w::value<uint8_t>(ui+w::WHEEL+0xBCD0)){
        put<uint8_t>(ui+w::WHEEL+0xBCD0,1);
        if(w::value<float>(ui+w::WHEEL+0x44)!=0.0f)++late_animation_allocations;
        put<uint8_t>(aux_records+5,0);
    }else if(!authored_close_model){put<uint8_t>(aux_records+5,0);put<uint8_t>(ui+w::WHEEL+0xBCD0,1);}
}}
void __fastcall alpha_zero(void* p,float a){assert(reinterpret_cast<uintptr_t>(p)==ui+w::WHEEL&&a==0.0f);assert(w::retired_node(ui+w::WHEEL,false));++alpha_sets;calls.push_back("alpha-zero");
    if(w::value<float>(ui+w::WHEEL+0x44)!=a){put<float>(ui+w::WHEEL+0x44,a);put<uint32_t>(ui+w::WHEEL+0xB8,w::value<uint32_t>(ui+w::WHEEL+0xB8)|0x20);put<uint32_t>(ui+w::WHEEL,4);}
    if(foreign_alpha_dirty)put<uint32_t>(ui+w::WHEEL,12);if(fault_alpha)RaiseException(0xE0000046,0,0,nullptr);
}
void __fastcall sibling_tick(void* p,float dt,uint32_t player_id){assert(reinterpret_cast<uintptr_t>(p)==ui+w::SIBLING&&dt==0.016f&&player_id==pid);calls.push_back("sibling-tick");const auto changed=game+w::abi.back().first;if(change_fingerprint_after_sibling)put<uint8_t>(changed+std::strlen(w::abi.back().second)/2-1,0xFF);if(change_protection_after_sibling){DWORD old{};assert(VirtualProtect(reinterpret_cast<void*>(changed),1,PAGE_READWRITE,&old));}}
void __fastcall wheel_tick(void* p,float dt,uint32_t player_id,uint32_t avatar_id){assert(reinterpret_cast<uintptr_t>(p)==ui+w::WHEEL&&dt==0.016f&&player_id==pid&&avatar_id==avatar&&player_id!=avatar_id);++ticks;calls.push_back("wheel-tick");if(fault_tick)RaiseException(0xE0000045,0,0,nullptr);}
void retire_component(uintptr_t base){const auto parent=w::value<uintptr_t>(base+0xF0);if(parent){uintptr_t link=parent+0xE0;for(unsigned i=0;i<32;++i){auto child=w::value<uintptr_t>(link);if(!child)break;if(child==base){put(link,w::value<uintptr_t>(base+0xE8));break;}link=child+0xE8;}}
    std::vector<uintptr_t> nodes;if(base==ui+w::DROP){for(auto off:w::drop_nodes)nodes.push_back(base+off);}else nodes={base,base+0x110,base+0x220};
    for(auto n:nodes){put<uint32_t>(n,0);for(uintptr_t off:{0xA8ULL,0xB0ULL,0xE0ULL,0xE8ULL,0xF0ULL,0xF8ULL,0x100ULL,0x108ULL})put<uintptr_t>(n+off,0);}
}
void __fastcall destroy(void* p){auto base=reinterpret_cast<uintptr_t>(p);
    if(base==ui+w::DROP+0x330){assert(w::drop_orphan_present());assert(!(w::value<uint64_t>(pm+0x53D8B0+0xFD0)&8)&&!(w::value<uint32_t>(pm+0x53D8B0+0xFD8)&w::owned_actions)&&w::value<uint8_t>(aux_records+5)==0);++orphan_destroys;calls.push_back("destroy-drop-orphan");if(orphan_fault)RaiseException(0xE000004B,0,0,nullptr);put<uint32_t>(base,0);for(uintptr_t off:{0xA8ULL,0xB0ULL,0xE0ULL,0xE8ULL,0xF0ULL,0xF8ULL,0x100ULL,0x108ULL})put<uintptr_t>(base+off,0);if(orphan_ack_delay)unreadable=base;return;}
    if(w::retired_node(base,true)&&w::value<uint32_t>(base)==4){++dirty_normalizations;calls.push_back("normalize-dirty");put<uint32_t>(base,0);if(dirty_fault)RaiseException(0xE0000048,0,0,nullptr);if(dirty_ack_delay)unreadable=base;return;}assert(base==ui+w::WHEEL||base==ui+w::SIBLING||base==ui+w::DROP);assert(!(w::value<uint64_t>(pm+0x53D8B0+0xFD0)&8)&&!(w::value<uint32_t>(pm+0x53D8B0+0xFD8)&w::owned_actions)&&w::value<uint8_t>(aux_records+5)==0);++destroys;calls.push_back(base==ui+w::WHEEL?"destroy-wheel":base==ui+w::SIBLING?"destroy-sibling":"destroy-drop");if(w::journal.generic_retired)assert(base==ui+w::WHEEL&&w::retired_node(base,true));retire_component(base);if(hidden_destroy&&destroys==1)unreadable=base;}
void __fastcall gui_delete_model(void* renderer,uintptr_t material){assert(reinterpret_cast<uintptr_t>(renderer)==w::witness.renderer&&material==w::witness.material);++deletes;calls.push_back("original-delete");if(delete_retires){assert(removes==1&&!destroys&&!w::status().role8_owned);retire_component(ui+w::WHEEL);retire_component(ui+w::SIBLING);retire_component(ui+w::DROP);}if(delete_reenters&&deletes==1)w::gui_delete_barrier(renderer,material);}
void __fastcall drop_tick(void* p,float dt,uint32_t player_id,uint32_t avatar_id){assert(reinterpret_cast<uintptr_t>(p)==ui+w::DROP&&dt==.016f&&player_id==pid&&avatar_id==avatar);++drop_ticks;calls.push_back("drop-tick");if(fault_drop_tick)RaiseException(0xE000004A,0,0,nullptr);}
void bind(){put(gui_api+0x248,reinterpret_cast<uintptr_t>(&gui_delete_model));w::construct_wheel=wheel;w::construct_sibling=sibling;w::construct_drop=drop;w::get_material=material;w::update_wheel=wheel_tick;w::update_drop=drop_tick;w::update_sibling=sibling_tick;w::attach=attach;w::flush=flush;w::destroy=destroy;w::add_role=add;w::remove_role=remove;w::set_alpha=alpha_zero;}
void fixture(){assert(!GetModuleHandleW(L"game.dll"));game=alloc(0x3500000,PAGE_EXECUTE_READWRITE);exe=alloc(0x1A11000);ui=alloc(0x500000);pm=alloc(0x550000);player=alloc(0x1000);world=alloc(0xF40000);state=alloc(0xAF000);gui=alloc(0x30000);observer=alloc(0x4000);aux=alloc(0x1000);desc=alloc(0x1000);local=alloc(0x1000);registry=alloc(0x1000);gens=alloc(0x1000);units=alloc(0x1000);unit=alloc(0x1000);menu=alloc(0x5000);aux_records=alloc(0x1000);w::fixture_query=query;
    for(auto pair:{std::pair<uintptr_t,uint32_t>{game,0x6AB3B43F},{exe,0x6AB382E4}}){put<uint16_t>(pair.first,0x5A4D);put<int32_t>(pair.first+0x3C,0x100);put<uint32_t>(pair.first+0x100,0x4550);put(pair.first+0x108,pair.second);}for(auto p:{std::pair<uintptr_t,uintptr_t>{w::UI,ui},{w::PM,pm},{w::PLAYER,player},{w::WORLD,world},{w::GS,state},{w::GUI,gui},{w::OBSERVER,observer},{w::AUX,aux},{0x347CE28,menu}})put(game+p.first,p.second);
    for(auto a:w::abi)bytes(game+a.first,a.second);put<uint32_t>(state+0xAC21C,3);put<uint32_t>(pm+0x70,1);map(pm+0xF8,avatar,0);put(pm+0x110,desc);put<uint32_t>(desc+8,avatar);put<uint32_t>(desc+12,reference);put<uint8_t>(desc+20,1);put<uint64_t>(pm+0x53D8B0+0xFD0,0x202);put<uint32_t>(player+0x88,1);put(player+0xE8,local);put<uint32_t>(local+8,pid);map(player+0xD0,pid,0);put<uint32_t>(player+0x3A8,14);map(world+0xF22EC8,14,0);put<uint32_t>(world+0xF32F18+8,avatar);map(aux+0x30,avatar,0);put(aux+0x58,aux_records);
    put(exe+0x1A100F0,registry);put<uint32_t>(registry+0x98,100);put(registry+0xA0,gens);put(registry+0x88,units);put<uint8_t>(gens+14,1);put(units+14*8,unit);put<uint32_t>(unit+8,reference);put<uint8_t>(ui+0x24E334,1);put<uint8_t>(ui+w::SINIT,1);put<uint8_t>(ui+w::SACTIVE,1);widget(ui+0x820,ui+0x258);put<float>(ui+0x24E324,1.25f);put<int32_t>(gui+0x2C5BC,-1);put<uint8_t>(gui+0x2C5B8,23);
    auto engine=alloc(0x1000),api=alloc(0x1000);put(game+0x3326308,engine);put(engine+0xD0,api);for(uintptr_t s:{0x118ULL,0x180ULL,0x230ULL,0x238ULL,0x240ULL,0x2B8ULL})put(api+s,game+0x1000);gui_api=api;put(api+0x248,reinterpret_cast<uintptr_t>(&gui_delete_model));w::fixture_bind=bind;
    auto root=ui+0x46D900+8,parent=ui+0x46D900+0x228,node=ui+0x46D900+0x490;widget(root,ui+0x820);widget(parent,root);widget(node,parent);put<uint32_t>(node,0xC1053);put<uintptr_t>(node+0x148,alloc(0x1000));put(gui+5*0x3698+8,alloc(0x1000));put<uint32_t>(observer+0x2440,1);put(observer+0x2448,ui);put<uint32_t>(observer+0x2450,0x108);
}
bool start(std::string& e,bool ready=true){return w::acquire({game,exe,pid,avatar,GetCurrentThreadId()},ready,e,{reader,writer});}
void clean(std::string& e){assert(w::stop(e));assert(!w::status().owned&&w::status().stopped&&!w::status().pending&&!w::barrier.installed);assert(w::value<uintptr_t>(gui_api+0x248)==reinterpret_cast<uintptr_t>(&gui_delete_model));assert(w::value<uint64_t>(pm+0x53D8B0+0xFD0)==0x202);auto before=destroys;assert(w::stop(e)&&destroys==before);}
void open(){put<uint32_t>(pm+0x53D8B0+0xFD8,0x400000);put<uint8_t>(aux_records+5,1);put<uint8_t>(ui+w::WHEEL+0xBCD0,0);put<float>(ui+w::WHEEL+0x44,1.f);}
void fire_witness(){w::gui_delete_barrier(reinterpret_cast<void*>(w::witness.renderer),w::witness.material);}
void fresh(bool native_mission){
    const uint32_t nextref=0x80000F,nextavatar=252;auto nd=alloc(0x1000),nu=alloc(0x1000);put<uint8_t>(gens+14,2);put<uint8_t>(gens+15,2);put(units+15*8,nu);put<uint32_t>(nu+8,nextref);put(pm+0x110,nd);put<uint32_t>(nd+8,nextavatar);put<uint32_t>(nd+12,nextref);put<uint8_t>(nd+20,1);map(pm+0xF8,nextavatar,0);put<uint32_t>(world+0xF32F18+8,nextavatar);map(aux+0x30,nextavatar,0);put<uint32_t>(pm+0x53D8B0+0xFD8,native_mission?0x400000:0);put<uint64_t>(pm+0x53D8B0+0xFD0,native_mission?0x20A:0x202);put<uint8_t>(aux_records+5,native_mission?1:0);
    if(native_mission){put<uint32_t>(state+0xAC21C,4);put<uint8_t>(ui+w::SINIT,0);put<uint8_t>(ui+w::MINIT,1);component(ui+w::WHEEL);component(ui+w::SIBLING);drop_component(ui+w::DROP);put(ui+w::DROP+0xF0,ui+0x820);put(ui+w::DROP+0xE8,ui+w::SIBLING);put(ui+w::WHEEL+0xF0,ui+0x820);put(ui+w::SIBLING+0xF0,ui+0x820);put(ui+0x820+0xE0,ui+w::DROP);put(ui+w::SIBLING+0xE8,ui+w::WHEEL);put<uintptr_t>(ui+w::WHEEL+0xE8,0);for(unsigned i=0;i<4;++i){put<uint32_t>(observer+w::count_offsets[i],1);put(observer+w::count_offsets[i]+8,ui+0x24E340);put<uint32_t>(observer+w::count_offsets[i]+16,0x106);}}
    else{retire_component(ui+w::WHEEL);retire_component(ui+w::SIBLING);retire_component(ui+w::DROP);}
}
}
int main(int argc,char** argv){fixture();std::string e;std::string mode=argc>1?argv[1]:"ordinary";
    if(mode.rfind("drop-",0)==0){
        // Exercise the physical native action row independently of pc aliases:
        // A51FF0/A521F0 use PM+53D900+F88, bit27 = action91.
        const auto action=pm+0x53D900;assert(action+0xF88==pm+0x53D8B0+0xFD8);
        if(mode=="drop-preimage-foreign"){widget(ui+w::DROP+0x1208);assert(!start(e)&&!adds&&!drop_builds&&!w::status().owned);}
        else if(mode=="drop-partial"||mode=="drop-child-missing"||mode=="drop-parent-foreign"){
            partial_drop=mode=="drop-partial";missing_drop_child=mode=="drop-child-missing";foreign_drop_parent=mode=="drop-parent-foreign";
            assert(!start(e)&&drop_builds==1&&!adds&&!destroys&&w::status().phase==w::Phase::Interrupted);const auto count=calls.size();assert(!w::stop(e)&&calls.size()==count&&!destroys&&!start(e)&&drop_builds==1);
        }else if(mode=="drop-material-missing"){
            missing_drop_material=true;assert(!start(e)&&drop_builds==1&&!adds&&w::status().pending&&w::status().phase!=w::Phase::Interrupted);clean(e);assert(destroys==3&&!removes);
        }else{
            // A raw old-order role8 addition makes Drop eligible while the
            // native first icon has no material: the actual crash precondition.
            assert((w::value<uint64_t>(action+0xF80)&0xA)==2&&material(reinterpret_cast<void*>(ui+w::DROP+0x1208))==0);
            put<uint64_t>(action+0xF80,0x20A);assert((w::value<uint64_t>(action+0xF80)&0xA)==0xA&&material(reinterpret_cast<void*>(ui+w::DROP+0x1208))==0);put<uint64_t>(action+0xF80,0x202);
            assert(start(e)&&adds==1&&drop_builds==1);for(auto off:w::drop_images)assert(material(reinterpret_cast<void*>(ui+w::DROP+off)));
            put<uint32_t>(action+0xF88,0x08000000);put<uint8_t>(ui+w::DROP+0x1CD0,0);
            if(mode=="drop-physical-actions"){assert(!w::closed(e));clean(e);assert(removes==1&&destroys==3);}
            else if(mode=="drop-cancel-pending"){
                drop_cancel_pending=true;assert(!w::stop(e)&&removes==1&&!destroys&&w::status().pending);put<uint32_t>(action+0xF88,0);put<uint8_t>(ui+w::DROP+0x1CD0,1);drop_cancel_pending=false;clean(e);assert(removes==1&&destroys==3);
            }else if(mode=="drop-early-barrier"){
                open();put<uint32_t>(action+0xF88,0x08400000);delete_retires=true;fire_witness();assert(removes==1&&!destroys&&!w::status().role8_owned&&w::value<uint32_t>(action+0xF88)==0);clean(e);assert(!destroys);
            }else if(mode=="drop-retired-open-refuse"){
                retire_component(ui+w::WHEEL);retire_component(ui+w::SIBLING);retire_component(ui+w::DROP);const auto count=calls.size();assert(!w::stop(e)&&calls.size()==count&&!removes&&!destroys&&!alpha_sets&&w::status().pending);
            }else if(mode=="drop-tick-fault"){
                fault_drop_tick=true;assert(!w::tick(.016f,pid,avatar,true,e)&&ticks==1&&drop_ticks==1&&w::status().phase==w::Phase::Interrupted);const auto count=calls.size();assert(!w::stop(e)&&calls.size()==count&&!removes&&!destroys);
            }else if(mode=="drop-parent-changed"){
                put(ui+w::DROP+0x1208+0xF0,ui+w::DROP+0x220);const auto count=calls.size();assert(!w::tick(.016f,pid,avatar,true,e)&&calls.size()==count&&!removes&&!destroys&&w::status().pending);
            }else if(mode=="drop-native-mission-handoff"){
                fresh(true);put<uint32_t>(action+0xF88,0x08400000);put<uint8_t>(ui+w::DROP+0x1CD0,0);const auto count=calls.size();assert(w::stop(e)&&calls.size()==count&&!removes&&!destroys&&w::status().retired&&w::value<uint32_t>(action+0xF88)==0x08400000);
            }else{
                const auto before=calls.size();clean(e);assert(removes==1&&destroys==3&&calls[before]=="remove"&&calls[before+1]=="drop-close"&&calls[before+2]=="destroy-drop");assert(start(e)&&drop_builds==2);clean(e);assert(drop_builds==2&&adds==2&&destroys==6);
            }
        }
        std::cout<<"PASS native Drop prerequisite "<<mode<<"\n";return 0;
    }
    if(mode=="validation-counters"||mode=="validation-fingerprint-refusal"||mode=="validation-executable-refusal"){
        w::target={game,exe,pid,avatar,GetCurrentThreadId()};w::io={reader,writer};
        unsigned expected_bytes=0;for(auto a:w::abi)expected_bytes+=static_cast<unsigned>(std::strlen(a.second)/2);
        if(mode=="validation-counters"){
            const bool valid=w::natives(e);const auto queries_per_validation=memory_queries;
            assert(valid&&fingerprint_reads==w::abi.size()&&fingerprint_bytes==expected_bytes&&queries_per_validation>0&&queries_per_validation<w::abi.size());
            assert(w::natives(e)&&fingerprint_reads==w::abi.size()*2&&fingerprint_bytes==expected_bytes*2&&memory_queries==queries_per_validation*2);
            assert(calls.empty());assert(start(e));fingerprint_reads=fingerprint_bytes=memory_queries=0;
            const auto before=calls.size();assert(w::tick(.016f,pid,avatar,true,e));
            assert(fingerprint_reads==w::abi.size()*3&&fingerprint_bytes==expected_bytes*3&&memory_queries==queries_per_validation*3);
            std::cout<<"healthy tick fingerprint_reads="<<fingerprint_reads<<" fingerprint_bytes="<<fingerprint_bytes<<" VirtualQuery="<<memory_queries<<"\n";
            assert(calls.size()==before+3&&calls[before]=="sibling-tick"&&calls[before+1]=="wheel-tick"&&calls[before+2]=="drop-tick");clean(e);
        }else if(mode=="validation-fingerprint-refusal"){
            for(auto a:w::abi){const auto last=game+a.first+std::strlen(a.second)/2-1;const auto old=w::value<uint8_t>(last);put<uint8_t>(last,static_cast<uint8_t>(old^0xFF));assert(!w::natives(e)&&calls.empty());bytes(game+a.first,a.second);}
            const auto a=w::abi.front();unreadable=game+a.first+std::strlen(a.second)/2-1;assert(!w::natives(e)&&calls.empty());unreadable=0;assert(w::natives(e));
        }else{
            const auto changed=game+w::abi.back().first;DWORD old{};assert(VirtualProtect(reinterpret_cast<void*>(changed),1,PAGE_READWRITE,&old));
            assert(!w::natives(e)&&calls.empty());assert(VirtualProtect(reinterpret_cast<void*>(changed),1,old,&old));assert(w::natives(e));
            query_fails=true;assert(!w::natives(e)&&calls.empty());query_fails=false;assert(w::natives(e));
        }
        std::cout<<"PASS batched validation "<<mode<<"\n";return 0;
    }
    if(mode=="not-ready"||mode=="role-preexisting"||mode=="wrong-root"||mode=="aux-missing"||mode=="menu-initial"||mode=="no-witness"||mode=="wrong-witness-parent"||mode=="wrong-witness-context"||mode=="no-observer"||mode=="duplicate-observer"||mode=="observer-overflow"||mode=="readonly-slot"||mode=="executable-slot"||mode=="shared-material"||mode=="wrong-material-type"||mode=="witness-cycle"){
        if(mode=="role-preexisting")put<uint64_t>(pm+0x53D8B0+0xFD0,0x20A);if(mode=="wrong-root")put(ui+0x820+0xF8,gui+4*0x3698);if(mode=="aux-missing")put<uintptr_t>(aux+0x58,0);if(mode=="menu-initial")put<uint32_t>(menu+0x4294,1);
        const auto wn=ui+0x46D900+0x490;if(mode=="no-witness")put<uintptr_t>(wn+0x148,0);if(mode=="shared-material")put<uint32_t>(wn,0xD1013);if(mode=="wrong-material-type")put<uint32_t>(wn,0x101053);if(mode=="witness-cycle")put<uintptr_t>(ui+0x46D900+0x228+0xF0,ui+0x46D900+0x228);if(mode=="wrong-witness-parent")put<uintptr_t>(wn+0xF0,0);if(mode=="wrong-witness-context")put(wn+0xF8,gui+4*0x3698);if(mode=="no-observer")put<uint32_t>(observer+0x2440,0);if(mode=="duplicate-observer"){put<uint32_t>(observer+0x2440,2);put(observer+0x2458,ui);put<uint32_t>(observer+0x2460,0x108);}if(mode=="observer-overflow")put<uint32_t>(observer+0x2440,7);
        if(mode=="readonly-slot"||mode=="executable-slot"){DWORD prior{};assert(VirtualProtect(reinterpret_cast<void*>(gui_api),0x1000,mode=="readonly-slot"?PAGE_READONLY:PAGE_EXECUTE_READWRITE,&prior));w::fixture_bind=nullptr;}
        assert(!start(e,mode!="not-ready"));assert(!sibling_builds&&!wheel_builds&&!adds&&!destroys&&!w::status().owned&&!w::barrier.installed);std::cout<<"PASS pure preflight "<<mode<<"\n";return 0;
    }
    if(mode=="witness-lost-during-constructor"){lose_witness_ctor=true;assert(!start(e)&&!adds&&wheel_builds==1&&sibling_builds==1&&w::status().pending);clean(e);assert(destroys==3&&!removes);std::cout<<"PASS witness rechecked before8 acquisition\n";return 0;}
    partial_sibling=mode=="partial-sibling";partial_wheel=mode=="partial-wheel";fault_attach=mode=="attach-fault";reenter=mode=="reenter";
    if(partial_sibling||partial_wheel||fault_attach){assert(!start(e));assert(w::status().phase==w::Phase::Interrupted&&w::status().pending&&!w::status().active&&w::barrier.installed);auto builds=sibling_builds+wheel_builds;assert(!w::stop(e)&&!destroys&&!adds);assert(!start(e)&&sibling_builds+wheel_builds==builds);std::cout<<"PASS interrupted journal "<<mode<<"\n";return 0;}
    if(mode.rfind("ship-active-0-to-1",0)==0)put<uint8_t>(ui+w::SACTIVE,0);
    assert(start(e));assert(w::status().owned&&w::status().active&&w::status().role8_owned&&!w::status().pending&&w::barrier.installed);assert(adds==1&&wheel_builds==1&&sibling_builds==1);
    if(mode=="revalidate-fingerprint-after-sibling"||mode=="revalidate-executable-after-sibling"){
        change_fingerprint_after_sibling=mode=="revalidate-fingerprint-after-sibling";change_protection_after_sibling=mode=="revalidate-executable-after-sibling";
        const auto before=calls.size();assert(!w::tick(.016f,pid,avatar,true,e)&&!ticks&&w::status().pending&&w::status().role8_owned);
        assert(calls.size()==before+1&&calls.back()=="sibling-tick"&&!removes&&!destroys);
        change_fingerprint_after_sibling=change_protection_after_sibling=false;const auto a=w::abi.back();DWORD old{};assert(VirtualProtect(reinterpret_cast<void*>(game+a.first),1,PAGE_EXECUTE_READWRITE,&old));bytes(game+a.first,a.second);clean(e);
    }
    else if(mode.rfind("ship-active-",0)==0){
        const auto old=w::ship_active;put<uint8_t>(ui+w::SACTIVE,mode=="ship-active-invalid"?2:static_cast<uint8_t>(1-old));
        if(mode.find("-open")!=std::string::npos)open();
        if(mode=="ship-active-flip-parent")put<uintptr_t>(ui+0x820+0xF0,ui+0x380);
        if(mode=="ship-active-flip-context")put<uintptr_t>(ui+0x820+0xF8,gui+4*0x3698);
        const auto before=calls.size();const bool ok=w::tick(.016f,pid,avatar,true,e);
        if(mode=="ship-active-invalid"||mode=="ship-active-flip-parent"||mode=="ship-active-flip-context"){
            assert(!ok&&calls.size()==before&&!removes&&!destroys&&!ticks&&w::status().pending&&w::status().role8_owned&&w::barrier.installed);
        }else{
            assert(ok&&!ticks&&removes==1&&destroys==3&&w::status().stopped&&!w::status().pending&&!w::status().role8_owned);
            assert(calls[before]=="remove"&&calls[before+1]=="destroy-drop"&&calls[before+2]=="destroy-drop-orphan"&&calls[before+3]=="destroy-wheel"&&calls[before+4]=="destroy-sibling");clean(e);
        }
    }
    else if(mode=="idempotent"){assert(start(e)&&adds==1&&wheel_builds==1);clean(e);assert(start(e)&&adds==2&&wheel_builds==2);clean(e);}
    else if(mode=="witness-retire"||mode=="witness-live"||mode=="witness-recursion"||mode=="witness-unrelated"||mode=="witness-foreign-thread"||mode=="witness-detached"||mode=="witness-alpha-zero"){
        open();if(mode=="witness-detached")put<uintptr_t>(w::witness.node+0xF0,0);if(mode=="witness-alpha-zero")put<float>(w::witness.node+0x44,0.f);delete_retires=mode=="witness-retire";delete_reenters=mode=="witness-recursion";
        if(mode=="witness-unrelated"){const auto original=w::barrier.original;w::barrier.original=[](void*,uintptr_t){++deletes;};w::gui_delete_barrier(reinterpret_cast<void*>(w::witness.renderer),w::witness.material+1);w::barrier.original=original;assert(!removes&&deletes==1&&w::status().active);}
        else if(mode=="witness-foreign-thread"){w::target.thread+=1;fire_witness();assert(!removes&&deletes==1&&w::status().pending);w::target.thread=GetCurrentThreadId();}
        else {fire_witness();assert(removes==1&&!w::status().role8_owned&&!w::status().active&&!destroys&&w::barrier.cancelled);assert(calls[calls.size()-(delete_reenters?3:2)]=="remove");assert(deletes==(delete_reenters?2u:1u));}
        clean(e);if(delete_retires)assert(!destroys);else assert(destroys==3);
    }
    else if(mode=="generation-array-move"||mode=="both-arrays-move"){auto ng=alloc(0x1000);std::memcpy(reinterpret_cast<void*>(ng),reinterpret_cast<void*>(gens),0x1000);put(registry+0xA0,ng);if(mode=="both-arrays-move"){auto ns=alloc(0x1000);std::memcpy(reinterpret_cast<void*>(ns),reinterpret_cast<void*>(units),0x1000);put(registry+0x88,ns);}assert(w::tick(.016f,pid,avatar,true,e)&&ticks==1);clean(e);}
    else if(mode=="foreign-slot"){put(gui_api+0x248,game+0x2000);assert(!w::stop(e)&&w::status().pending&&w::barrier.installed);assert(!start(e));}
    else if(mode=="actor-retired"){put<uint8_t>(gens+14,2);const auto count=calls.size();assert(!w::tick(.016f,pid,avatar,true,e)&&calls.size()==count&&w::status().pending);}
    else if(mode=="handoff-ship"||mode=="handoff-mission"||mode=="handoff-missing-observer"||mode=="handoff-foreign-ship8"||mode=="handoff-partial"||mode=="handoff-live-original"||mode=="handoff-array-move"||mode=="handoff-root-missing"||mode=="handoff-foreign-ui"){
        fresh(mode=="handoff-mission"||mode=="handoff-missing-observer"||mode=="handoff-root-missing");if(mode=="handoff-array-move"){auto ng=alloc(0x1000),ns=alloc(0x1000);std::memcpy(reinterpret_cast<void*>(ng),reinterpret_cast<void*>(gens),0x1000);std::memcpy(reinterpret_cast<void*>(ns),reinterpret_cast<void*>(units),0x1000);put(registry+0xA0,ng);put(registry+0x88,ns);}if(mode=="handoff-root-missing")put<uintptr_t>(ui+0x820+0xE0,0);if(mode=="handoff-foreign-ui")put(game+w::UI,alloc(0x500000));if(mode=="handoff-missing-observer")put<uint32_t>(observer+w::count_offsets[0],0);if(mode=="handoff-foreign-ship8")put<uint64_t>(pm+0x53D8B0+0xFD0,0x20A);if(mode=="handoff-partial")put<uint32_t>(ui+w::WHEEL+0x110,1);if(mode=="handoff-live-original")put<uint8_t>(gens+14,1);
        const auto count=calls.size();const auto context=w::value<uint64_t>(pm+0x53D8B0+0xFD0);const auto action=w::value<uint32_t>(pm+0x53D8B0+0xFD8);const bool ok=w::stop(e);
        if(mode=="handoff-ship"||mode=="handoff-mission"||mode=="handoff-array-move"){assert(ok&&w::status().stopped&&w::status().retired&&!w::status().owned&&!w::status().pending&&!w::barrier.installed);}else assert(!ok&&w::status().pending);
        const bool ship_cleanup=mode=="handoff-ship"||mode=="handoff-array-move";
        assert(calls.size()==count+(ship_cleanup?1:0)&&orphan_destroys==(ship_cleanup?1u:0u)&&!removes&&!destroys&&w::value<uint64_t>(pm+0x53D8B0+0xFD0)==context&&w::value<uint32_t>(pm+0x53D8B0+0xFD8)==action);
    }
    else if(mode.rfind("orphan-",0)==0){
        const auto n=ui+w::DROP+0x330;assert(w::drop_orphan_present()&&w::journal.drop_orphan==3&&w::drop_tree.nodes.size()==18);
        if(mode=="orphan-reacquire"){
            // Stock generic Drop root teardown misses the unlinked primitive.
            retire_component(ui+w::DROP);assert(w::tree_absent(w::drop_tree)&&w::drop_orphan_present()&&!w::drop_empty());
            retire_component(ui+w::WHEEL);retire_component(ui+w::SIBLING);put<uint64_t>(pm+0x53D8B0+0xFD0,0x202);put<uint8_t>(ui+w::WHEEL+0xBCD0,1);
            clean(e);assert(orphan_destroys==1&&w::drop_empty());assert(start(e)&&drop_builds==2);clean(e);assert(orphan_destroys==2&&destroys==3);
        }else if(mode=="orphan-ack-delay"){
            orphan_ack_delay=true;assert(!w::stop(e)&&orphan_destroys==1&&w::journal.destroy_orphan==2&&w::status().pending);const auto old=calls.size();assert(!w::stop(e)&&orphan_destroys==1&&calls.size()==old);unreadable=0;orphan_ack_delay=false;clean(e);assert(orphan_destroys==1);assert(start(e));clean(e);assert(orphan_destroys==2);
        }else if(mode=="orphan-destroy-fault"){
            orphan_fault=true;assert(!w::stop(e)&&orphan_destroys==1&&w::journal.destroy_orphan==1&&w::status().phase==w::Phase::Interrupted);const auto old=calls.size();assert(!w::stop(e)&&calls.size()==old&&!start(e)&&orphan_destroys==1);
        }else if(mode=="orphan-external-retired"){
            retire_component(ui+w::DROP);retire_component(ui+w::WHEEL);retire_component(ui+w::SIBLING);put<uint32_t>(n,0);put<uintptr_t>(n+0xF8,0);put<uint64_t>(pm+0x53D8B0+0xFD0,0x202);put<uint8_t>(ui+w::WHEEL+0xBCD0,1);clean(e);assert(orphan_destroys==0&&w::drop_empty());
        }else if(mode=="orphan-dirty"){
            put<uint32_t>(n,0xC0015);clean(e);assert(orphan_destroys==1&&w::drop_empty());
        }else if(mode=="orphan-afk"){
            fresh(false);const auto before=calls.size();assert(w::drop_orphan_present()&&w::stop(e)&&w::status().retired&&orphan_destroys==1&&calls.size()==before+1&&!removes&&!destroys&&w::drop_orphan_absent());
        }else if(mode=="orphan-native-mission"){
            fresh(true);const auto before=calls.size();assert(w::stop(e)&&w::status().retired&&calls.size()==before&&!orphan_destroys&&w::drop_orphan_present()&&w::value<uint64_t>(pm+0x53D8B0+0xFD0)==0x20A);
        }else{
            if(mode=="orphan-material")put<uintptr_t>(n+0x148,alloc(0x1000));
            else if(mode=="orphan-parent")put(n+0xF0,ui+0x820);
            else if(mode=="orphan-context")put(n+0xF8,gui+4*0x3698);
            else if(mode=="orphan-child")put(n+0xE0,n+0x110);
            else if(mode=="orphan-delegate")put<uintptr_t>(n+0x108,1);
            else if(mode=="orphan-tween")put<uintptr_t>(n+0xA8,1);
            else if(mode=="orphan-type")put<uint32_t>(n,0x100011);
            else if(mode=="orphan-defaults")put<uint32_t>(n+0x110,1);
            else assert(false);
            const auto before=calls.size();assert(!w::stop(e)&&w::status().pending&&!orphan_destroys&&!removes&&!destroys&&calls.size()==before);assert(!start(e));
        }
        std::cout<<"PASS detached Drop primitive ownership "<<mode<<"\n";
    }
    else if(mode.rfind("dirty-",0)==0){
        fresh(false);const auto n=ui+w::SIBLING+0x110;put<uint32_t>(n,4);
        if(mode=="dirty-multiple")for(auto t:{&w::wheel_tree,&w::sibling_tree,&w::drop_tree})for(auto x:t->nodes)put<uint32_t>(x,4);
        if(mode=="dirty-foreign-flags")put<uint32_t>(n,12);if(mode=="dirty-context")put<uintptr_t>(n+0xF8,gui+5*0x3698);if(mode=="dirty-animation")put<uintptr_t>(n+0xA8,1);if(mode=="dirty-delegate")put<uintptr_t>(n+0x108,1);if(mode=="dirty-opaque")unreadable=n+0xF8;if(mode=="dirty-newactor8")put<uint64_t>(pm+0x53D8B0+0xFD0,0x20A);if(mode=="dirty-old-live")put<uint8_t>(gens+14,1);
        dirty_fault=mode=="dirty-fault";dirty_ack_delay=mode=="dirty-ack-delay";const auto before=calls.size();bool ok=w::stop(e);
        if(mode=="dirty-foreign-flags"||mode=="dirty-context"||mode=="dirty-animation"||mode=="dirty-delegate"||mode=="dirty-opaque"||mode=="dirty-newactor8"||mode=="dirty-old-live"){assert(!ok&&!dirty_normalizations&&calls.size()==before&&w::status().pending);}
        else if(mode=="dirty-fault"){assert(!ok&&dirty_normalizations==1&&w::status().phase==w::Phase::Interrupted);assert(!w::stop(e)&&dirty_normalizations==1);}
        else {if(mode=="dirty-ack-delay"){assert(!ok&&dirty_normalizations==1&&w::status().pending);dirty_ack_delay=false;unreadable=0;ok=w::stop(e);}assert(ok&&w::status().stopped&&w::status().retired&&!w::status().pending&&!w::barrier.installed);assert(dirty_normalizations==(mode=="dirty-multiple"?24u:1u));}
        assert(!removes&&!destroys&&!alpha_sets);std::cout<<"PASS empty dirty descendant normalization "<<mode<<"\n";
    }
    else if(mode=="cancel-pending"){cancel_pending=true;open();assert(!w::stop(e)&&removes==1&&!destroys&&w::status().pending);put<uint32_t>(pm+0x53D8B0+0xFD8,0);put<uint8_t>(aux_records+5,0);cancel_pending=false;clean(e);assert(removes==1);}
    else if(mode=="destroy-ack"){hidden_destroy=true;assert(!w::stop(e)&&destroys==1&&w::status().pending);unreadable=0;clean(e);assert(destroys==3);}
    else if(mode=="tick-fault"){fault_tick=true;assert(!w::tick(.016f,pid,avatar,true,e)&&w::status().phase==w::Phase::Interrupted);const auto count=calls.size();assert(!w::stop(e)&&calls.size()==count);}
    else if(mode=="witness-lost"){put<uintptr_t>(w::witness.node+0x148,alloc(0x1000));assert(w::tick(.016f,pid,avatar,true,e)&&w::status().stopped&&!ticks);}
    else if(mode=="menu-pause"){put<uint32_t>(menu+0x4298,1);assert(w::tick(.016f,pid,avatar,true,e)&&!ticks&&w::status().stopped);}
    else if(mode=="photo-pause"){assert(w::tick(.016f,pid,avatar,false,e)&&!ticks&&w::status().stopped);}
    else{assert(w::tick(.016f,pid,avatar,true,e)&&ticks==1);clean(e);}
    std::cout<<"PASS persistent native owner "<<mode<<"\n";return 0;
}
