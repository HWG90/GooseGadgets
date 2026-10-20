// Runs only in this standalone fixture process; never locates a game process.
#define NADS_FIXTURE
#include "native_ads_alignment.cpp"
#include <cstdio>
#include <cstdlib>
#include <thread>
#include <vector>
#define CHECK(x) do{if(!(x)){std::fprintf(stderr,"FAIL %d: %s error=%u\n",__LINE__,#x,NADS_Error());std::abort();}}while(0)
static uint32_t actual_unit=0,actual_node=0;
static const float* actual_pose=nullptr;
static uint32_t actual_bits[4]{};
static uint64_t actual_calls=0;
static uint32_t actual_kind=0;
__declspec(noinline) static void synthetic_position(uint32_t unit,uint32_t node,const float* pose) {
    actual_unit=unit;actual_node=node;actual_pose=pose;std::memcpy(actual_bits,pose,16);++actual_calls;actual_kind=1;
}
__declspec(noinline) static void synthetic_rotation(uint32_t unit,uint32_t node,const float* pose) {
    actual_unit=unit;actual_node=node;actual_pose=pose;std::memcpy(actual_bits,pose,16);++actual_calls;actual_kind=2;
}
template<class T> static void put(uint64_t at,const T& val) {std::memcpy(reinterpret_cast<void*>(at),&val,sizeof val);}
static uint64_t allocate(size_t size,DWORD protect=PAGE_READWRITE) {
    auto memory=VirtualAlloc(nullptr,size,MEM_COMMIT|MEM_RESERVE,protect);CHECK(memory);return reinterpret_cast<uint64_t>(memory);
}
static void fake_image(uint64_t base,uint32_t stamp,uint32_t size) {
    IMAGE_DOS_HEADER dos{};dos.e_magic=IMAGE_DOS_SIGNATURE;dos.e_lfanew=128;
    IMAGE_NT_HEADERS64 nt{};nt.Signature=IMAGE_NT_SIGNATURE;nt.FileHeader.Machine=IMAGE_FILE_MACHINE_AMD64;
    nt.FileHeader.TimeDateStamp=stamp;nt.OptionalHeader.Magic=IMAGE_NT_OPTIONAL_HDR64_MAGIC;nt.OptionalHeader.SizeOfImage=size;
    put(base,dos);put(base+128,nt);
}
static void literal(uint64_t at,const char* hex) {
    for(size_t i=0;i<std::strlen(hex)/2;++i) {
        auto digit=[](char c)->uint8_t{return static_cast<uint8_t>(c<='9'?c-'0':c-'a'+10);};
        put<uint8_t>(at+i,static_cast<uint8_t>((digit(hex[i*2])<<4)|digit(hex[i*2+1])));
    }
}
static Setter stub(uint64_t game,unsigned which,uint64_t api) {
    const uint64_t site=game+CALLS[which];
    // sub rsp,28; mov r9,API; call [r9+38/48]; add rsp,28; ret.
    literal(site-14,"4883ec2849b9");put<uint64_t>(site-8,api);
    literal(site,which?"41ff51484883c428c3":"41ff51384883c428c3");
    CHECK(FlushInstructionCache(GetCurrentProcess(),reinterpret_cast<void*>(site-14),23));
    return reinterpret_cast<Setter>(site-14);
}
struct Fixture {
    NADS_Config c{};uint64_t controller=0,descriptor=0,registry=0,gens=0,objects=0,api=0;
    Setter calls[2]{};
    Fixture() {
        c.size=sizeof c;c.abi=1;c.game=allocate(0x4744000,PAGE_EXECUTE_READWRITE);c.exe=allocate(0x39E8000);
        fake_image(c.game,0x6AB3B43F,0x4744000);fake_image(c.exe,0x6AB382E4,0x39E8000);
        // Independent literal captured 48-byte prefixes, not generated from PREFIX.
        literal(c.exe+0x1FC720,"48895c24084889742410574883ec20498bf08bfa8bd9e88511eaff4c8b5018b801000000f0410fc182380017008bc04c");
        literal(c.exe+0x1FC880,"48895c24084889742410574883ec20498bf08bfa8bd9e82510eaff4c8b5018b801000000f0410fc182380017008bc04c");
        c.context=allocate(0x3000);c.avatar_owner=allocate(0x540000);controller=allocate(0x1000);descriptor=allocate(0x1000);
        c.avatar_index=0;c.avatar=0x333;c.weapon=0x444;c.body=0x222;c.viewmodel=0x400003;c.duration_ms=100;
        put<uint64_t>(c.game+0x346D560,c.context);put<uint64_t>(c.game+0x3326D20,c.avatar_owner);
        put<uint64_t>(c.game+0x347CE70,controller);put<uint64_t>(c.context,allocate(0x1000));
        put<uint32_t>(c.avatar_owner+0x6C,1);put<uint64_t>(c.avatar_owner+0x110,descriptor);
        put<uint32_t>(descriptor+8,c.avatar);put<uint32_t>(descriptor+12,c.body);
        put<uint32_t>(c.avatar_owner+0x53E9B8,c.viewmodel);
        registry=allocate(0x1000);gens=allocate(0x1000);objects=allocate(0x1000);
        put<uint64_t>(c.exe+0x1A100F0,registry);put<uint32_t>(registry+0x98,16);
        put<uint64_t>(registry+0xA0,gens);put<uint8_t>(gens+3,1);put<uint64_t>(registry+0x88,objects);
        put<uint64_t>(objects+3*8,allocate(0x1000));
        uint64_t root=allocate(0x1000);api=allocate(0x1000);
        put<uint64_t>(c.game+0x3326308,root);put<uint64_t>(root+0x18,api);
        fixture_targets[0]=synthetic_position;fixture_targets[1]=synthetic_rotation;
        put<uint64_t>(api+0x38,reinterpret_cast<uint64_t>(synthetic_position));
        put<uint64_t>(api+0x48,reinterpret_cast<uint64_t>(synthetic_rotation));
        calls[0]=stub(c.game,0,api);calls[1]=stub(c.game,1,api);normal();
    }
    void normal() {
        put<uint32_t>(c.context+0x1F8,0);put<uint32_t>(c.context+0x1FC,1);
        put<uint32_t>(c.context+0x200,4);put<uint32_t>(c.context+0x204,c.avatar);
        c.request=c.context+0x200+0xE8;
        put<uint8_t>(c.avatar_owner+0x53E886,0);std::memset(reinterpret_cast<void*>(controller),0,6);
    }
    void fpv() {
        put<uint32_t>(c.context+0x1FC,2);put<uint32_t>(c.request,6);
        put<uint32_t>(c.request+4,c.avatar);put<uint32_t>(c.request+8,c.weapon);put<uint32_t>(c.request+12,c.body);
    }
    bool begin() {return NADS_Begin(&c)==1;}
};
int main() {
    Fixture f;fixture_now=1000;
    NADS_Stats stats{};stats.size=sizeof stats;stats.abi=1;
    CHECK(NADS_ReadStats(&stats)==1 && stats.installed==0 && stats.armed==0);
    CHECK(NADS_Validate(&f.c)==1 && installed.load()==0 && reserved.load()==0 && fixture_cas_calls==0);
    uint8_t code_before[2][64]{};CHECK(read(reinterpret_cast<uint64_t>(synthetic_position),code_before[0],64));
    CHECK(read(reinterpret_cast<uint64_t>(synthetic_rotation),code_before[1],64));
    CHECK(NADS_Begin(nullptr)==0);auto bad=f.c;bad.duration_ms=10501;CHECK(NADS_Begin(&bad)==0);
    put<uint8_t>(f.c.exe+0x1FC720,0);CHECK(NADS_Validate(&f.c)==0 && NADS_Error()==CODE_MISMATCH);
    CHECK(!f.begin());literal(f.c.exe+0x1FC720,PREFIX[0]);
    fixture_slot_readonly=true;CHECK(NADS_Validate(&f.c)==0 && NADS_Error()==SLOT_NOT_WRITABLE);
    CHECK(!f.begin() && fixture_cas_calls==0);fixture_slot_readonly=false;
    uint32_t bits[4]={0x80000000,0x7FC12345,0x7F800000,0x00000001};const float* pose=reinterpret_cast<const float*>(bits);
    CHECK(f.begin());CHECK(NADS_ReadStats(&stats)==1 && stats.installed==1 && stats.armed==1);
    CHECK(!f.begin() && NADS_Error()==BUSY && armed.load()==1);f.fpv();
    const uint64_t initial=actual_calls;f.calls[0](f.c.viewmodel,0,pose);f.calls[1](f.c.viewmodel,0,pose);CHECK(actual_calls==initial);
    CHECK(NADS_ReadStats(&stats)==1 && stats.skipped_position==1 && stats.skipped_rotation==1);
    f.calls[0](f.c.viewmodel,1,pose);f.calls[1](f.c.viewmodel+1,0,pose);CHECK(actual_calls==initial+2);
    Setter cached=reinterpret_cast<Setter>(callback(0));cached(f.c.viewmodel,0,pose);CHECK(actual_calls==initial+3);
    CHECK(actual_pose==pose && std::memcmp(actual_bits,bits,16)==0);
    put<uint8_t>(f.c.avatar_owner+0x53E886,1);f.calls[0](f.c.viewmodel,0,pose);
    CHECK(actual_calls==initial+4 && NADS_ReadStats(&stats)==1 && stats.armed==0);
    f.normal();CHECK(!f.begin() && NADS_Error()==BUSY);CHECK(NADS_End()==1);
    CHECK(NADS_ReadStats(&stats)==1 && stats.installed==0 && reserved.load()==0);
    cached(f.c.viewmodel,0,pose);CHECK(actual_calls==initial+5);
    f.normal();CHECK(f.begin());f.fpv();put<uint8_t>(f.controller+4,1);f.calls[1](f.c.viewmodel,0,pose);
    CHECK(NADS_ReadStats(&stats)==1 && stats.armed==0);CHECK(NADS_End()==1);
    f.normal();CHECK(f.begin());f.fpv();fixture_now=1100;f.calls[0](f.c.viewmodel,0,pose);
    CHECK(NADS_ReadStats(&stats)==1 && stats.expired==1 && stats.armed==0);
    f.normal();CHECK(!f.begin() && NADS_Error()==BUSY);CHECK(NADS_End()==1);
    fixture_now=1200;f.normal();CHECK(f.begin());f.fpv();put<uint8_t>(f.gens+3,2);f.calls[0](f.c.viewmodel,0,pose);
    CHECK(NADS_ReadStats(&stats)==1 && stats.armed==0);put<uint8_t>(f.gens+3,1);CHECK(NADS_End()==1);
    f.normal();CHECK(f.begin());f.fpv();put<uint32_t>(f.c.request+8,f.c.weapon+1);f.calls[0](f.c.viewmodel,0,pose);
    CHECK(NADS_ReadStats(&stats)==1 && stats.armed==0);CHECK(NADS_End()==1);
    // First/second CAS failures are rolled back without code or foreign writes.
    f.normal();fixture_cas_calls=0;fixture_cas_fail_at=1;CHECK(NADS_Begin(&f.c)==0 && reserved.load()==0);
    fixture_cas_calls=0;fixture_cas_fail_at=2;CHECK(NADS_Begin(&f.c)==0 && reserved.load()==0);
    uint64_t a=0,b=0;CHECK(pointer(f.api+0x38,a) && pointer(f.api+0x48,b));
    CHECK(a==reinterpret_cast<uint64_t>(synthetic_position) && b==reinterpret_cast<uint64_t>(synthetic_rotation));
    fixture_cas_calls=0;fixture_cas_fail_at=0;fixture_foreign_cas_at=2;
    fixture_foreign_value=reinterpret_cast<uint64_t>(synthetic_position);
    CHECK(NADS_Begin(&f.c)==0 && NADS_Error()==CAS_MISMATCH && reserved.load()==0);
    CHECK(pointer(f.api+0x38,a) && a==reinterpret_cast<uint64_t>(synthetic_position));
    CHECK(pointer(f.api+0x48,b) && b==fixture_foreign_value);
    put<uint64_t>(f.api+0x48,reinterpret_cast<uint64_t>(synthetic_rotation));fixture_foreign_cas_at=0;
    // An uncertain rollback explicitly returns an OWNED cleanup handle (2).
    fixture_cas_calls=0;fixture_cas_fail_at=2;fixture_fail_rollback=true;
    CHECK(NADS_Begin(&f.c)==2 && reserved.load()==1 && armed.load()==0 && installed.load()==1);
    CHECK(NADS_Begin(&f.c)==0 && NADS_Error()==BUSY);
    fixture_fail_rollback=false;fixture_cas_fail_at=0;CHECK(NADS_End()==1 && reserved.load()==0);
    f.normal();CHECK(f.begin());Setter cached_rotation=reinterpret_cast<Setter>(callback(1));
    // A foreign dispatch replacement is preserved; the other owned slot restores.
    put<uint64_t>(f.api+0x38,reinterpret_cast<uint64_t>(synthetic_rotation));
    CHECK(NADS_End()==1);CHECK(pointer(f.api+0x38,a) && a==reinterpret_cast<uint64_t>(synthetic_rotation));
    put<uint64_t>(f.api+0x38,reinterpret_cast<uint64_t>(synthetic_position));
    const uint64_t before_cached=actual_calls;cached_rotation(f.c.viewmodel,0,pose);CHECK(actual_calls==before_cached+1);
    // Cleanup cannot be acknowledged without readable, writable owned slots.
    f.normal();CHECK(f.begin());fixture_slot_unreadable=true;CHECK(NADS_End()==0 && reserved.load()==1 && armed.load()==0);
    fixture_slot_unreadable=false;fixture_slot_readonly=true;CHECK(NADS_End()==0 && reserved.load()==1);
    fixture_slot_readonly=false;CHECK(NADS_End()==1 && reserved.load()==0);
    f.normal();CHECK(f.begin());CHECK(NADS_ReadStats(&stats)==1 && stats.skipped_position==0 && stats.skipped_rotation==0);
    CHECK(NADS_End()==1);
    // End serializes after an in-progress Begin and restores its published slots.
    f.normal();fixture_before_arm_reached=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    fixture_continue_arm=CreateEventW(nullptr,TRUE,FALSE,nullptr);CHECK(fixture_before_arm_reached && fixture_continue_arm);
    std::atomic<bool> end_started{false},end_done{false},begin_success{false};
    std::thread begin_thread([&](){begin_success.store(f.begin());});
    CHECK(WaitForSingleObject(fixture_before_arm_reached,5000)==WAIT_OBJECT_0);
    std::thread end_thread([&](){end_started.store(true);CHECK(NADS_End()==1);end_done.store(true);});
    while(!end_started.load())Sleep(1);Sleep(10);CHECK(!end_done.load());
    SetEvent(fixture_continue_arm);begin_thread.join();end_thread.join();CHECK(begin_success.load());
    CHECK(NADS_ReadStats(&stats)==1 && stats.armed==0 && stats.installed==0 && reserved.load()==0);
    CloseHandle(fixture_before_arm_reached);CloseHandle(fixture_continue_arm);fixture_before_arm_reached=nullptr;fixture_continue_arm=nullptr;
    uint8_t code_after[2][64]{};CHECK(read(reinterpret_cast<uint64_t>(synthetic_position),code_after[0],64));
    CHECK(read(reinterpret_cast<uint64_t>(synthetic_rotation),code_after[1],64));CHECK(std::memcmp(code_before,code_after,sizeof code_before)==0);
    CHECK(bytes(f.c.exe+POSITION,PREFIX[0]) && bytes(f.c.exe+ROTATION,PREFIX[1]));
    std::puts("Native dispatch fixture PASS: atomic aligned pointer install/restore; executable bytes unchanged; scoped owner/caller/unit/node; exact ABI/bit forwarding; CAS rollback/owned-pending result2; foreign preservation; cached callbacks; TTL/reservation/concurrentEnd; cleanup retry");
    return 0;
}
