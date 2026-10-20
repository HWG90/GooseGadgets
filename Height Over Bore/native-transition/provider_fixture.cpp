#define HBTP_FIXTURE
#include "provider.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <vector>
#define CHECK(x) do {if (!(x)) {std::fprintf(stderr,"line %d: %s\n",__LINE__,#x);std::exit(1);}} while(0)
using hob::Event;
using hob::Reason;
using Enter=void (*)(uint64_t,uint32_t,uint32_t);
using Exit=void (*)(uint64_t);
using Wield=void (*)(uint64_t,uint32_t,uint32_t,uint32_t,uint32_t);
using Unwield=void (*)(uint64_t,uint32_t,uint32_t);
using Retire=void (*)(uint64_t);
using Shutdown=void (*)();
static HBTP_Snapshot current{100,164,200,7,0,3,5,300};
static bool fps=false,owned=false,readable=true;
static bool queue_mode=false,inject_retire_commit=false;
static unsigned snapshots=0;
alignas(16) static uint8_t queue_memory[0x2100]{};
using QueueWrite=uint32_t (*)(void*,uint32_t);
static QueueWrite write_head=nullptr,write_tail=nullptr;
static unsigned original_enter=0,original_exit=0,original_wield=0,original_unwield=0;
static unsigned original_retire=0,original_shutdown=0;
static std::vector<hob::Notice> notices;
static Event fail=static_cast<Event>(999);
static bool nested=false;
#pragma optimize("",off)
__declspec(noinline) void native_enter(uint64_t camera,uint32_t avatar,uint32_t weapon) {
    ++original_enter;
    if (camera==current.camera && avatar==current.avatar && weapon==current.weapon) fps=true;
}
__declspec(noinline) void native_exit(uint64_t camera) {
    ++original_exit;
    if (camera==current.camera) fps=false;
}
__declspec(noinline) void native_unwield(uint64_t manager,uint32_t index,uint32_t slot) {
    ++original_unwield;
    if (manager==current.manager && index==current.index && slot==0) current.weapon=0;
}
__declspec(noinline) void native_wield(uint64_t manager,uint32_t avatar,uint32_t slot,uint32_t weapon,uint32_t send) {
    ++original_wield;
    if (manager==current.manager && avatar==current.avatar && slot==0) {
        native_unwield(manager,current.index,slot);
        current.weapon=weapon;
    }
    (void)send;
}
__declspec(noinline) void native_retire(uint64_t descriptor) {
    ++original_retire;
    if (descriptor==current.avatar) {
        if(inject_retire_commit) {
            uint32_t tail=0;std::memcpy(&tail,queue_memory+0x1fc,4);
            write_tail(queue_memory,tail);
        }
        native_unwield(current.manager,current.index,0);
        current.avatar=0;
    }
}
__declspec(noinline) void native_create(uint64_t descriptor) {current.avatar=static_cast<uint32_t>(descriptor);}
__declspec(noinline) void native_shutdown() { ++original_shutdown; current={}; }
#pragma optimize("",on)
alignas(8) static Retire retire_slot=native_retire;
alignas(8) static Retire creation_slot=native_create;
alignas(8) static Shutdown shutdown_slot=native_shutdown;
static Retire cached_retire=nullptr;
static void foreign_retire(uint64_t descriptor) {cached_retire(descriptor);}
static bool snapshot(HBTP_Snapshot* out) noexcept {
    ++snapshots;
    if (!readable || !current.avatar) return false;
    *out=current; return true;
}
static bool camera(uint64_t c,uint32_t a,uint32_t w) noexcept {
    if(queue_mode) {
        if(!readable || c!=current.camera)return false;
        uint32_t h=0,t=0,record[4]{};
        std::memcpy(&h,queue_memory+0x1f8,4);std::memcpy(&t,queue_memory+0x1fc,4);
        if(h>=32 || t>=32)return false;
        const auto* p=h==t?queue_memory+0x1f00:queue_memory+0x200+((t+31)%32)*0xe8;
        std::memcpy(record,p,16);
        return (record[0]&0xffff)==6 && record[1]==a && record[2]==w;
    }
    return readable && fps && c==current.camera && a==current.avatar && w==current.weapon;
}
static bool unwield(uint64_t m,uint32_t i,uint32_t a,uint32_t w) noexcept {
    return readable && m==current.manager && i==current.index && a==current.avatar && w==current.weapon;
}
static bool retire(uint64_t d,uint32_t a) noexcept {return readable && d==a;}
static bool sink(void*,const hob::Notice& n) noexcept {
    notices.push_back(n);
    if (n.event==Event::ads_enter) {
        CHECK(camera(current.camera,current.avatar,current.weapon)); // committed, not input intent
        CHECK(n.identity.weapon==current.weapon);
        owned=true; // also model partial apply before failed acknowledgement
        if (nested) native_enter(current.camera,current.avatar,current.weapon);
    }
    if (n.event==Event::ads_exit) {
        CHECK(n.identity.weapon==current.weapon); // before native removal
        if (n.event!=fail) owned=false;
    }
    return n.event!=fail;
}
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
static Retire make_retirement_tail() {
    const auto executable=reinterpret_cast<uint64_t>(GetModuleHandleA(nullptr));
    const auto* dos=reinterpret_cast<const IMAGE_DOS_HEADER*>(executable);
    const auto* nt=reinterpret_cast<const IMAGE_NT_HEADERS64*>(executable+dos->e_lfanew);
    uint64_t at=(executable+nt->OptionalHeader.SizeOfImage+0xffff)&~uint64_t{0xffff};
    uint8_t* memory=nullptr;
    while(at<executable+0x70000000) {
        MEMORY_BASIC_INFORMATION region{};CHECK(VirtualQuery(reinterpret_cast<void*>(at),&region,sizeof region)==sizeof region);
        if(region.State==MEM_FREE)memory=static_cast<uint8_t*>(VirtualAlloc(reinterpret_cast<void*>(at),65536,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE));
        if(memory)break;
        at=(reinterpret_cast<uint64_t>(region.BaseAddress)+region.RegionSize+0xffff)&~uint64_t{0xffff};
    }
    CHECK(memory);
    const int64_t delta=reinterpret_cast<int64_t>(&native_retire)-reinterpret_cast<int64_t>(memory)-8;
    CHECK(delta>=-2147483648LL && delta<=2147483647LL);
    const uint8_t prefix[4]={0x48,0x8b,0xd1,0xe9};std::memcpy(memory,prefix,4);
    const auto jump=static_cast<int32_t>(delta);std::memcpy(memory+4,&jump,4);
    DWORD previous=0;CHECK(VirtualProtect(memory,65536,PAGE_EXECUTE_READ,&previous));
    FlushInstructionCache(GetCurrentProcess(),memory,8);
    return reinterpret_cast<Retire>(memory);
}
static void push_request(uint16_t kind) {
    uint32_t head=0,tail=0;
    std::memcpy(&head,queue_memory+0x1f8,4);std::memcpy(&tail,queue_memory+0x1fc,4);
    const uint32_t record[4]={kind,current.avatar,current.weapon,current.body};
    std::memcpy(queue_memory+0x200+tail*0xe8,record,16);
    tail=(tail+1)%32;
    if(tail==head) {head=(head+1)%32;std::memcpy(queue_memory+0x1f8,&head,4);}
    write_tail(queue_memory,tail);
}
int main(int argc,char** argv) {
    CHECK(argc==3);
    const char* scenario=argv[2];
    if (!std::strcmp(scenario,"bootstrap")) {current.weapon=9;fps=true;}
    HMODULE dll=LoadLibraryA(argv[1]);CHECK(dll);
    auto open=reinterpret_cast<decltype(&HBTP_TestOpen)>(GetProcAddress(dll,"HBTP_TestOpen"));
    auto close=reinterpret_cast<decltype(&HBTP_Close)>(GetProcAddress(dll,"HBTP_Close"));
    auto stats=reinterpret_cast<decltype(&HBTP_ReadStats)>(GetProcAddress(dll,"HBTP_ReadStats"));
    CHECK(open && close && stats);
    HBTP_TestBinding binding{{reinterpret_cast<uint64_t>(&native_enter),reinterpret_cast<uint64_t>(&native_exit),
        reinterpret_cast<uint64_t>(&native_wield),reinterpret_cast<uint64_t>(&native_unwield)},
        reinterpret_cast<uint64_t>(&retire_slot),reinterpret_cast<uint64_t>(&shutdown_slot),snapshot,camera,unwield,retire};
    binding.creation_slot=reinterpret_cast<uint64_t>(&creation_slot);
    std::vector<hob::CommitSite> queue_sites;
    const bool entry_case=!std::strcmp(scenario,"lifecycle_entries");
    const bool queue_case=entry_case || !std::strcmp(scenario,"commits") || !std::strcmp(scenario,"commit_fault")
        || !std::strcmp(scenario,"commit_body") || !std::strcmp(scenario,"commit_restorefail");
    if(queue_case) {
        queue_mode=true;current.camera=reinterpret_cast<uint64_t>(queue_memory);
        const uint32_t fallback[4]={4,current.avatar,0,current.body};std::memcpy(queue_memory+0x1f00,fallback,16);
        binding.image_base=make_queue_functions(queue_sites);binding.image_size=65536;
        binding.sites=queue_sites.data();binding.site_count=static_cast<uint32_t>(queue_sites.size());
        binding.targets[0]=0; // no entry-point observer: only real queue STORE callbacks
    }
    if(entry_case) {
        retire_slot=make_retirement_tail();
        binding.lifecycle_targets[0]=reinterpret_cast<uint64_t>(&native_create);
        binding.lifecycle_targets[1]=reinterpret_cast<uint64_t>(retire_slot);
        binding.lifecycle_targets[2]=reinterpret_cast<uint64_t>(&native_shutdown);
    }
    const auto original_retire_slot=retire_slot;
    unsigned char before[4][5]{};
    for(unsigned i=0;i<4;++i)if(binding.targets[i])std::memcpy(before[i],reinterpret_cast<void*>(binding.targets[i]),5);
    if (!std::strcmp(scenario,"reject")) {
        binding.targets[2]=1; CHECK(open(&binding,sink,nullptr)==0);
        CHECK(retire_slot==native_retire && shutdown_slot==native_shutdown);
        for(unsigned i=0;i<2;++i)CHECK(!std::memcmp(before[i],reinterpret_cast<void*>(binding.targets[i]),5));
        std::puts("PASS reject");return 0;
    }
    CHECK(open(&binding,sink,nullptr)==1);
    CHECK(open(&binding,sink,nullptr)==0);
    CHECK(entry_case?(retire_slot==original_retire_slot && shutdown_slot==native_shutdown):
        (retire_slot!=original_retire_slot && shutdown_slot!=native_shutdown));
    cached_retire=retire_slot;
    if(queue_case) {
        native_wield(current.manager,current.avatar,0,9,0);
        push_request(6);CHECK(owned);
        if(!std::strcmp(scenario,"commit_restorefail")) {
            fail=Event::ads_exit;push_request(8);CHECK(owned);
            const auto count=notices.size();
            for(unsigned i=0;i<1000;++i)push_request(8);
            CHECK(notices.size()==count && owned);
            HBTP_Stats state{sizeof state,1};CHECK(stats(&state));CHECK(state.failed);
            fail=static_cast<Event>(999);CHECK(close()==1 && !owned);
            std::puts("PASS commit_restorefail: failed lease retained, 1000 commits idle, explicit cleanup retries");return 0;
        }
        if(!std::strcmp(scenario,"commit_fault")) {
            write_tail(queue_memory,33);
            HBTP_Stats s{sizeof s,1};CHECK(stats(&s));CHECK(s.failed && !owned);
            CHECK(close()==1);
            std::puts("PASS commit_fault");return 0;
        }
        if(!std::strcmp(scenario,"commit_body")) {
            ++current.body;push_request(6);
            HBTP_Stats s{sizeof s,1};CHECK(stats(&s));CHECK(s.failed && !owned);
            CHECK(close()==1);
            std::puts("PASS commit_body");return 0;
        }
        const auto first_generation=notices.back().identity.generation;
        const auto count=notices.size();const auto reads=snapshots;
        for(unsigned i=0;i<1000;++i)push_request(6);
        CHECK(notices.size()==count && snapshots==reads); // unchanged mode does no setup/discovery
        push_request(8);CHECK(!owned && notices.back().event==Event::ads_exit);
        push_request(6);CHECK(owned);
        const uint32_t fps_default[4]={6,current.avatar,current.weapon,current.body};
        std::memcpy(queue_memory+0x1f00,fps_default,16); // default becomes effective only after queue removal
        push_request(8);CHECK(!owned);
        uint32_t tail=0;std::memcpy(&tail,queue_memory+0x1fc,4);
        write_head(queue_memory,tail);CHECK(owned && notices.back().event==Event::ads_enter);
        push_request(4);CHECK(!owned);
        const uint32_t native_default[4]={4,current.avatar,current.weapon,current.body};
        std::memcpy(queue_memory+0x1f00,native_default,16);
        std::memcpy(&tail,queue_memory+0x1fc,4);write_head(queue_memory,tail);CHECK(!owned);
        push_request(6);CHECK(owned);
        if(entry_case) {
            // Native API/registry refreshes may rewrite callback slots. Entry
            // interception must survive all three assignments without polling.
            retire_slot=original_retire_slot;creation_slot=native_create;shutdown_slot=native_shutdown;
        }
        inject_retire_commit=true;retire_slot(current.avatar);inject_retire_commit=false;
        CHECK(!owned && notices.back().event==Event::world_end);
        creation_slot(7);native_wield(current.manager,current.avatar,0,10,0);push_request(6);
        CHECK(owned && notices.back().identity.generation>first_generation);
        HBTP_Stats s{sizeof s,1};CHECK(stats(&s));CHECK(!s.failed && s.entered==0);
        shutdown_slot();CHECK(!owned && notices.back().event==Event::world_end);
    } else if (!std::strcmp(scenario,"bootstrap")) {
        CHECK(notices.size()==3 && notices.back().event==Event::ads_enter && owned);
        CHECK(close()==1 && !owned);
    } else if (!std::strcmp(scenario,"idle")) {
        const size_t count=notices.size();
        Sleep(100);
        CHECK(notices.size()==count);
        HBTP_Stats s{sizeof s,1};CHECK(stats(&s));
        CHECK(s.entered==0 && s.exited==0 && s.wielded==0 && s.unwielded==0);
        CHECK(close()==1);
    } else {
        native_wield(current.manager,current.avatar,0,9,0);
        CHECK(notices.back().event==Event::equipped && notices.back().identity.weapon==9);
        if (!std::strcmp(scenario,"partial")) fail=Event::ads_enter;
        if (!std::strcmp(scenario,"nested")) nested=true;
        native_enter(current.camera,current.avatar,current.weapon);
        CHECK(owned);
        if (!std::strcmp(scenario,"thread")) {
            std::thread t([] {native_enter(current.camera,current.avatar,current.weapon);});t.join();
            HBTP_Stats s{sizeof s,1};CHECK(stats(&s));CHECK(s.failed && s.wrong_thread==1);
            CHECK(close()==1 && !owned);
        } else if (!std::strcmp(scenario,"partial") || !std::strcmp(scenario,"nested")) {
            HBTP_Stats s{sizeof s,1};CHECK(stats(&s));CHECK(s.failed);
            nested=false;
            native_exit(current.camera);CHECK(!owned);
            CHECK(close()==1);
        } else if (!std::strcmp(scenario,"foreign")) {
            retire_slot=foreign_retire;
            CHECK(close()==1 && !owned);
            CHECK(retire_slot==foreign_retire);
            size_t count=notices.size();cached_retire(current.avatar);CHECK(notices.size()==count);
        } else if (!std::strcmp(scenario,"restorefail")) {
            fail=Event::ads_exit;
            CHECK(close()==2 && owned);
            CHECK(notices.back().event==Event::ads_exit);
            fail=static_cast<Event>(999);
            CHECK(close()==1 && !owned);
            CHECK(notices.back().event==Event::world_end);
        } else if (!std::strcmp(scenario,"worldchange")) {
            // No pre-retirement: do not restore the old record into a new world.
            current.world=500;current.implementation=564;
            const auto count=notices.size();const auto reads=snapshots;
            native_wield(999,99,0,11,0); // unrelated actor must not adopt the new identity
            CHECK(notices.size()==count && snapshots==reads);
            native_enter(current.camera,current.avatar,current.weapon);
            HBTP_Stats s{sizeof s,1};CHECK(stats(&s));CHECK(s.failed);
            current.world=100;current.implementation=164;
            CHECK(close()==1 && !owned);
        } else {
            native_exit(current.camera);CHECK(!owned);
            CHECK(notices.back().event==Event::ads_exit);
            native_enter(current.camera,current.avatar,current.weapon);CHECK(owned);
            native_wield(current.manager,current.avatar,0,10,0);CHECK(!owned);
            CHECK(notices.back().event==Event::equipped && notices.back().identity.weapon==10);
            native_enter(current.camera,current.avatar,current.weapon);CHECK(owned);
            retire_slot(current.avatar);CHECK(!owned);
            CHECK(notices.back().event==Event::world_end);
            current.avatar=8;current.body=6;current.weapon=0;fps=false;
            native_wield(current.manager,current.avatar,0,12,0);
            native_enter(current.camera,current.avatar,current.weapon);CHECK(owned);
            shutdown_slot();CHECK(!owned && original_shutdown==1);
            CHECK(notices.back().event==Event::world_end);
            CHECK(original_enter==4 && original_exit==1 && original_wield==3 && original_retire==1);
        }
    }
    CHECK(shutdown_slot==native_shutdown);
    for(unsigned i=0;i<4;++i)if(binding.targets[i])CHECK(!std::memcmp(before[i],reinterpret_cast<void*>(binding.targets[i]),5));
    CHECK(creation_slot==native_create);
    if (std::strcmp(scenario,"foreign"))CHECK(retire_slot==original_retire_slot);
    const auto count=notices.size();cached_retire(999);CHECK(notices.size()==count);
    std::printf("PASS %s\n",scenario);
}
