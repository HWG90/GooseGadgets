#define HBTP_FIXTURE
#include "provider.h"
#include "consumer_model.h"
static Model* model=nullptr;
using QueueWrite=uint32_t (*)(void*,uint32_t);
static QueueWrite write_head=nullptr,write_tail=nullptr;
static unsigned retired_calls=0,shutdown_calls=0;
#pragma optimize("",off)
__declspec(noinline) void native_exit(uint64_t camera) {
    CHECK(camera==model->camera);CHECK(model->get<uint32_t>(model->rows+0x14)==pi);model->view(4);
}
__declspec(noinline) void native_unwield(uint64_t manager,uint32_t index,uint32_t slot) {
    CHECK(manager==model->wielder && index==0 && slot==0);
    CHECK(model->get<uint32_t>(model->rows+0x14)==pi);model->put(model->wield_rows,uint32_t{0});
}
__declspec(noinline) void native_wield(uint64_t manager,uint32_t avatar,uint32_t slot,uint32_t weapon,uint32_t send) {
    CHECK(manager==model->wielder && avatar==10 && slot==0 && send==0);
    native_unwield(manager,0,slot);model->set_weapon(weapon);
}
__declspec(noinline) void native_retire(uint64_t descriptor) {
    CHECK(descriptor==model->actor_descriptor);CHECK(model->get<uint32_t>(model->rows+0x14)==pi);
    ++retired_calls;native_unwield(model->wielder,0,0);
}
__declspec(noinline) void native_create(uint64_t descriptor) {
    CHECK(descriptor==model->actor_descriptor);model->put(model->wield_rows,uint32_t{0});model->view(4);
}
__declspec(noinline) void native_shutdown() {
    CHECK(model->get<uint32_t>(model->rows+0x14)==pi);++shutdown_calls;
}
#pragma optimize("",on)
using Retire=void (*)(uint64_t);using Shutdown=void (*)();
alignas(8) static Retire retire_slot=native_retire,creation_slot=native_create;
alignas(8) static Shutdown shutdown_slot=native_shutdown;
static uint64_t make_queue_functions(std::vector<hob::CommitSite>& sites) {
    auto* memory=static_cast<uint8_t*>(VirtualAlloc(nullptr,65536,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE));CHECK(memory);
    const auto base=reinterpret_cast<uint64_t>(memory);
    auto* functions=reinterpret_cast<RUNTIME_FUNCTION*>(memory+0x300);
    for(unsigned i=0;i<2;++i) {
        const uint32_t field=i?0x1fc:0x1f8,start=0x1000+i*0x100;
        uint8_t code[]={0x57,0x48,0x83,0xec,0x20,0x48,0x89,0xcf,0x89,0xd0,
            0x89,0x87,0,0,0,0,0x48,0x83,0xc4,0x20,0x5f,0xc3};
        std::memcpy(code+12,&field,4);std::memcpy(memory+start,code,sizeof code);
        const uint8_t unwind[]={1,5,2,0,5,0x32,1,0x70};
        std::memcpy(memory+0x200+i*16,unwind,sizeof unwind);
        functions[i]={start,start+sizeof code,0x200+i*16};
        sites.push_back({base+start+10,6,field,7,0,functions[i]});
    }
    DWORD previous=0;CHECK(VirtualProtect(memory,65536,PAGE_EXECUTE_READ,&previous));
    CHECK(RtlAddFunctionTable(functions,2,base));
    write_head=reinterpret_cast<QueueWrite>(base+0x1000);
    write_tail=reinterpret_cast<QueueWrite>(base+0x1100);
    return base;
}
static void push(uint16_t kind) {
    const auto camera=model->camera;
    uint32_t head=model->get<uint32_t>(camera+0x1f8),tail=model->get<uint32_t>(camera+0x1fc);
    const uint32_t request[4]={kind,10,model->weapon,7};
    std::memcpy(reinterpret_cast<void*>(camera+0x200+tail*0xe8),request,16);
    tail=(tail+1)%32;
    if(tail==head)model->put(camera+0x1f8,(head+1)%32);
    write_tail(reinterpret_cast<void*>(camera),tail);
}
int main(int argc,char** argv) {
    CHECK(argc==2);Model m;model=&m;m.put(m.wield_rows,uint32_t{0});
    const uint32_t fallback[4]={4,10,0,7};std::memcpy(reinterpret_cast<void*>(m.camera+0x1f00),fallback,16);
    auto dll=LoadLibraryA(argv[1]);CHECK(dll);
    auto open=reinterpret_cast<decltype(&HBTP_TestOpen)>(GetProcAddress(dll,"HBTP_TestOpen"));
    auto close=reinterpret_cast<decltype(&HBTP_Close)>(GetProcAddress(dll,"HBTP_Close"));
    auto enabled=reinterpret_cast<decltype(&HBTP_SetEnabled)>(GetProcAddress(dll,"HBTP_SetEnabled"));
    auto stats=reinterpret_cast<decltype(&HBTP_ReadHoBStats)>(GetProcAddress(dll,"HBTP_ReadHoBStats"));
    auto provider_stats=reinterpret_cast<decltype(&HBTP_ReadStats)>(GetProcAddress(dll,"HBTP_ReadStats"));
    CHECK(open && close && enabled && stats && provider_stats);
    std::vector<hob::CommitSite> sites;HBTP_TestBinding binding{};
    binding.targets[1]=reinterpret_cast<uint64_t>(&native_exit);
    binding.targets[2]=reinterpret_cast<uint64_t>(&native_wield);
    binding.targets[3]=reinterpret_cast<uint64_t>(&native_unwield);
    binding.retire_slot=reinterpret_cast<uint64_t>(&retire_slot);binding.shutdown_slot=reinterpret_cast<uint64_t>(&shutdown_slot);
    binding.creation_slot=reinterpret_cast<uint64_t>(&creation_slot);
    binding.lifecycle_targets[0]=reinterpret_cast<uint64_t>(&native_create);
    binding.lifecycle_targets[1]=reinterpret_cast<uint64_t>(&native_retire);
    binding.lifecycle_targets[2]=reinterpret_cast<uint64_t>(&native_shutdown);
    binding.image_base=make_queue_functions(sites);binding.image_size=65536;
    binding.site_count=static_cast<uint32_t>(sites.size());binding.sites=sites.data();
    binding.consumer_game=m.game;binding.consumer_enabled=1;
    CHECK(open(&binding,nullptr,nullptr)==1);
    HBTP_HoBStats h{sizeof h,1};CHECK(stats(&h));CHECK(h.preparations==0);
    native_wield(m.wielder,10,0,11,0);push(6);CHECK(m.get<uint32_t>(m.rows+0x14)==target);
    for(unsigned i=0;i<1000;++i)push(6);
    CHECK(stats(&h));CHECK(h.preparations==1 && h.definition_searches==1 && h.applications==1 && h.owned);
    push(8);CHECK(m.get<uint32_t>(m.rows+0x14)==pi);
    push(6);CHECK(enabled(0)==1 && m.get<uint32_t>(m.rows+0x14)==pi);
    CHECK(enabled(1)==1 && m.get<uint32_t>(m.rows+0x14)==target);
    native_exit(m.camera);CHECK(m.get<uint32_t>(m.rows+0x14)==pi);
    push(6);native_unwield(m.wielder,0,0);CHECK(m.get<uint32_t>(m.rows+0x14)==pi);
    native_wield(m.wielder,10,0,11,0);push(6);native_retire(m.actor_descriptor);
    CHECK(retired_calls==1 && m.get<uint32_t>(m.rows+0x14)==pi);
    native_create(m.actor_descriptor);native_wield(m.wielder,10,0,11,0);push(6);
    CHECK(m.get<uint32_t>(m.rows+0x14)==target);
    native_shutdown();CHECK(shutdown_calls==1 && m.get<uint32_t>(m.rows+0x14)==pi);
    HBTP_Stats p{sizeof p,1};CHECK(provider_stats(&p));CHECK(!p.failed && !p.subscribed && !p.wrong_thread);
    CHECK(stats(&h));CHECK(h.preparations==3 && h.definition_searches==3 && !h.owned);
    CHECK(close()==1);
    m.view(4);m.put(m.wield_rows,uint32_t{0});
    CHECK(open(&binding,nullptr,nullptr)==1);
    native_wield(m.wielder,10,0,11,0);push(6);CHECK(m.get<uint32_t>(m.rows+0x14)==target);
    CHECK(close()==1 && m.get<uint32_t>(m.rows+0x14)==pi);
    CHECK(open(&binding,nullptr,nullptr)==1);
    push(6);CHECK(m.get<uint32_t>(m.rows+0x14)==target);
    CHECK(close()==1 && m.get<uint32_t>(m.rows+0x14)==pi);
    CHECK(open(&binding,nullptr,nullptr)==1);push(6);
    DWORD previous=0;CHECK(VirtualProtect(reinterpret_cast<void*>(m.rows),4096,PAGE_READONLY,&previous));
    CHECK(close()==2);CHECK(open(&binding,nullptr,nullptr)==0);
    CHECK(stats(&h));CHECK(h.owned && m.get<uint32_t>(m.rows+0x14)==target);
    CHECK(VirtualProtect(reinterpret_cast<void*>(m.rows),4096,PAGE_READWRITE,&previous));
    CHECK(close()==1 && m.get<uint32_t>(m.rows+0x14)==pi);
    auto changed=binding;changed.targets[1]=0;
    CHECK(open(&changed,nullptr,nullptr)==0); // retained hook layout cannot be silently replaced
    CHECK(open(&binding,nullptr,nullptr)==1);CHECK(close()==1);
    std::puts("PASS integrated native STORE -> provider -> real memory consumer: once/equip, 1000 unchanged commits, forced exit, toggles, unwield, retirement/recreation and shutdown; restoration precedes native teardown; retained hooks rearm, incomplete cleanup blocks rearm and changed layouts rejected");
}
