// Synthetic private allocations and local callbacks only; no game access.
#define NADSP_FIXTURE
#include "native_ads_pose.cpp"
#include <cstdio>
#include <cstdlib>
#include <thread>
#define CHECK(x) do{if(!(x)){std::fprintf(stderr,"FAIL %d: %s error=%u\n",__LINE__,#x,NADSP_Error());std::abort();}}while(0)
struct Record {uint32_t unit,node,kind,bits[4];const float* pointer;};
static Record records[4096]{};static uint64_t actual_calls=0,cases=0;
static HANDLE setter_reached=nullptr,setter_continue=nullptr;
static void record(uint32_t unit,uint32_t node,const float* pose,uint32_t kind) {
    CHECK(actual_calls<4096);auto& r=records[actual_calls++];r.unit=unit;r.node=node;r.kind=kind;r.pointer=pose;
    std::memcpy(r.bits,pose,16);
    if(setter_reached) {SetEvent(setter_reached);WaitForSingleObject(setter_continue,INFINITE);}
}
__declspec(noinline) static void synthetic_position(uint32_t unit,uint32_t node,const float* pose) {record(unit,node,pose,1);}
__declspec(noinline) static void synthetic_rotation(uint32_t unit,uint32_t node,const float* pose) {record(unit,node,pose,2);}
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
static Setter stub(uint64_t site,unsigned which,uint64_t api) {
    // sub rsp,28; mov r9,API; call [r9+38/48]; add rsp,28; ret.
    literal(site-14,"4883ec2849b9");put<uint64_t>(site-8,api);
    literal(site,which?"41ff51484883c428c3":"41ff51384883c428c3");
    CHECK(FlushInstructionCache(GetCurrentProcess(),reinterpret_cast<void*>(site-14),23));return reinterpret_cast<Setter>(site-14);
}
struct Fixture {
    NADSP_Config c{};uint64_t controller=0,descriptor=0,registry=0,gens=0,objects=0,api=0,object=0,vtable=0,links=0,hashes=0;
    Setter calls[2]{},rig=nullptr;
    Fixture() {
        c.size=sizeof c;c.abi=1;c.game=allocate(0x4744000,PAGE_EXECUTE_READWRITE);c.exe=allocate(0x39E8000);
        fake_image(c.game,0x6AB3B43F,0x4744000);fake_image(c.exe,0x6AB382E4,0x39E8000);
        // Independent captured opcode literals, not populated from production constants.
        literal(c.exe+0x1FC720,"48895c24084889742410574883ec20498bf08bfa8bd9e88511eaff4c8b5018b801000000f0410fc182380017008bc04c");
        literal(c.exe+0x1FC880,"48895c24084889742410574883ec20498bf08bfa8bd9e82510eaff4c8b5018b801000000f0410fc182380017008bc04c");
        literal(c.exe+0x2BD870,"488d4160c3");
        c.context=allocate(0x3000);c.avatar_owner=allocate(0x540000);controller=allocate(0x1000);descriptor=allocate(0x1000);
        c.avatar_index=0;c.avatar=0x333;c.weapon=0x444;c.body=0x222;c.viewmodel=0x400003;c.duration_ms=1000;
        c.weapon_descriptor=allocate(0x1000);c.weapon_unit=0x400004;c.blend_ms=150;c.offset_x=.15f;c.offset_z=-.12f;
        put<uint32_t>(c.weapon_descriptor+8,c.weapon);put<uint32_t>(c.weapon_descriptor+12,c.weapon_unit);
        put<uint64_t>(c.game+0x346D560,c.context);put<uint64_t>(c.game+0x3326D20,c.avatar_owner);
        put<uint64_t>(c.game+0x347CE70,controller);put<uint64_t>(c.context,allocate(0x1000));
        put<uint32_t>(c.avatar_owner+0x6C,1);put<uint64_t>(c.avatar_owner+0x110,descriptor);
        put<uint32_t>(descriptor+8,c.avatar);put<uint32_t>(descriptor+12,c.body);put<uint32_t>(c.avatar_owner+0x53E9B8,c.viewmodel);
        registry=allocate(0x1000);gens=allocate(0x1000);objects=allocate(0x1000);object=allocate(0x1000);
        put<uint64_t>(c.exe+0x1A100F0,registry);put<uint32_t>(registry+0x98,16);
        put<uint64_t>(registry+0xA0,gens);put<uint8_t>(gens+3,1);put<uint64_t>(registry+0x88,objects);
        put<uint64_t>(objects+3*8,object);put<uint8_t>(gens+4,1);put<uint64_t>(objects+4*8,allocate(0x1000));
        vtable=allocate(0x1000);links=allocate(0x1000);hashes=allocate(0x1000);
        put<uint64_t>(object,vtable);put<uint64_t>(vtable+0xE8,c.exe+0x2BD870);put<uint32_t>(object+0x70,63);
        put<uint64_t>(object+0x98,links);put<uint64_t>(object+0xA0,hashes);
        // Independent full captured graph: uint32 parent/flag links and hash rows.
        literal(links,"000000000100000001000100010002000100030001000400010005000100050001000700010008000100070001000a0001000a0001000c0001000d0001000e0001000f0001000d00010011000100120001000d00010014000100150001000d00010017000100180001000d0001001a0001001b0001000c000100070001001e0001001e000100200001002000010022000100230001002400010022000100260001002700010022000100290001002a000100220001002c0001002d000100220001002f0001003000010004000100020001000200010034000100340001003400010034000100340001000c000100040001003b0001003b0001003b00");
        literal(hashes,"4127184a1ce6307fb23e6232bdeb5c97e591cfbc6355119b9d39944121d03b6f3733dd4f1e3b7289982c750398c74c1566cda21cd3680c5c54e0197a861e37d5b95c543040f6817864f9b82dea7e91a2757876e494c96cda7760e18328ffd1c798ab5bb10d94d76cf09fd8b7635d23c2925d1fdf3c6e78f6ceb22016123d4082ac4de3316cb31093f50480245fdeabaeea3b99735cb8af37d3e547e5e240ec9f427da945e9901568ae3ee464baabf19fe64a0b4677be9f43c6020ac0b53ec1d696b255f346436e6f398ced60d191d4a361d15c315675f12026d589f5d02a5069129de14412170ecb5b11c8a52008ef3739d8bcb24e7b78c466af7877");
        uint64_t root=allocate(0x1000);api=allocate(0x1000);put<uint64_t>(c.game+0x3326308,root);put<uint64_t>(root+0x18,api);
        fixture_targets[0]=synthetic_position;fixture_targets[1]=synthetic_rotation;
        put<uint64_t>(api+0x38,reinterpret_cast<uint64_t>(synthetic_position));put<uint64_t>(api+0x48,reinterpret_cast<uint64_t>(synthetic_rotation));
        calls[0]=stub(c.game+0x12887C9,0,api);calls[1]=stub(c.game+0x12887E9,1,api);rig=stub(c.game+0x1288420,0,api);normal();
    }
    void normal() {
        put<uint32_t>(c.context+0x1F8,0);put<uint32_t>(c.context+0x1FC,1);put<uint32_t>(c.context+0x200,4);put<uint32_t>(c.context+0x204,c.avatar);
        c.request=c.context+0x200+0xE8;put<uint8_t>(c.avatar_owner+0x53E886,0);std::memset(reinterpret_cast<void*>(controller),0,6);
    }
    float* source() {return reinterpret_cast<float*>(c.request+0x48);}
    void pose(float x,float y,float z,uint32_t w=0x80000000) {const float xyz[3]={x,y,z};std::memcpy(source(),xyz,12);put<uint32_t>(c.request+0x54,w);}
    void fpv() {
        put<uint32_t>(c.context+0x1FC,2);put<uint32_t>(c.request,6);put<uint32_t>(c.request+4,c.avatar);
        put<uint32_t>(c.request+8,c.weapon);put<uint32_t>(c.request+12,c.body);put<uint32_t>(c.request+0x18,3);pose(1,2,3);
    }
    void begin_at(uint64_t now) {normal();fixture_now=now;CHECK(NADSP_Begin(&c)==1);fpv();}
    void match() {rig(c.viewmodel,5,source());}
};
static float component(unsigned index) {float out=0;std::memcpy(&out,&records[actual_calls-1].bits[index],4);return out;}
static bool approximately(float a,float b) {return std::fabs(a-b)<.00001f;}
static void exact(uint64_t index,uint32_t unit,uint32_t node,const float* ptr,const void* bits) {
    CHECK(records[index].unit==unit && records[index].node==node && records[index].pointer==ptr && std::memcmp(records[index].bits,bits,16)==0);
}
static void pass(const char* name) {++cases;std::printf("PASS %s\n",name);}
int main() {
    Fixture f;fixture_now=1000;NADSP_Stats stats{};stats.size=sizeof stats;stats.abi=1;
    CHECK(NADSP_ReadStats(&stats)==1 && stats.installed==0 && stats.armed==0);CHECK(NADSP_Validate(&f.c)==1 && fixture_cas_calls==0);
    pass("cold ABI and read-only preflight");
    uint8_t before[2][64]{};CHECK(read(reinterpret_cast<uint64_t>(synthetic_position),before[0],64));CHECK(read(reinterpret_cast<uint64_t>(synthetic_rotation),before[1],64));
    const uint32_t root_bits[4]={0x80000000,0x7FC12345,0x7F800000,0x00000001};const float* root=reinterpret_cast<const float*>(root_bits);
    f.begin_at(1000);uint64_t start=actual_calls;f.calls[0](f.c.viewmodel,0,root);f.calls[1](f.c.viewmodel,0,root);CHECK(actual_calls==start+2);
    exact(start,f.c.viewmodel,0,root,root_bits);exact(start+1,f.c.viewmodel,0,root,root_bits);pass("both roots exact pointer and bits; no weapon setter");
    uint8_t source_bits[16]{};std::memcpy(source_bits,f.source(),16);f.match();CHECK(approximately(component(0),1));
    fixture_now=1075;f.match();CHECK(approximately(component(0),1.075f) && approximately(component(2),2.94f));
    CHECK(records[actual_calls-1].bits[1]==0x40000000 && records[actual_calls-1].bits[3]==0x80000000 && std::memcmp(f.source(),source_bits,16)==0);
    pass("fresh X/Z offset; Y/W and source bytes preserved");
    fixture_now=1150;f.match();CHECK(approximately(component(0),1.15f) && approximately(component(2),2.88f));
    f.match();CHECK(approximately(component(0),1.15f));f.pose(4,5,6);f.match();CHECK(approximately(component(0),4.15f) && approximately(component(2),5.88f));
    pass("changing native movement retained without accumulation");
    put<uint8_t>(f.c.avatar_owner+0x53E886,1);fixture_now=1160;f.match();CHECK(NADSP_ReadStats(&stats)==1 && stats.armed==1 && stats.target_weight==0);
    fixture_now=1235;f.match();CHECK(approximately(component(0),4.075f));fixture_now=1310;f.match();CHECK(approximately(component(0),4) && records[actual_calls-1].pointer==f.source());
    put<uint8_t>(f.c.avatar_owner+0x53E886,0);put<uint8_t>(f.controller+4,1);fixture_now=1320;f.match();CHECK(NADSP_ReadStats(&stats)==1 && stats.armed==1 && stats.target_weight==0);
    put<uint8_t>(f.controller+4,0);fixture_now=1330;f.match();fixture_now=1480;f.match();CHECK(approximately(component(0),4.15f));
    pass("real ADS and controller blend to stock without disarming");
    CHECK(NADSP_ReadStats(&stats)==1 && stats.forwarded_position==stats.seen_position && stats.forwarded_rotation==stats.seen_rotation);
    start=actual_calls;CHECK(NADSP_End()==1 && actual_calls==start+1);CHECK(records[start].unit==f.c.viewmodel && records[start].node==5);
    CHECK(std::memcmp(records[start].bits,f.source(),16)==0 && records[start].bits[0]!=0);CHECK(NADSP_End()==1 && actual_calls==start+1);
    pass("End restores latest native baseline once, never zero or weapon root");
    f.begin_at(2000);fixture_now=2150;start=actual_calls;reinterpret_cast<Setter>(callback(0))(f.c.viewmodel,5,f.source());
    CHECK(actual_calls==start+1);exact(start,f.c.viewmodel,5,f.source(),f.source());CHECK(NADSP_End()==1);pass("wrong caller exact pass-through");
    f.begin_at(2500);fixture_now=2650;f.match();start=actual_calls;f.rig(f.c.viewmodel+2,5,root);
    exact(start,f.c.viewmodel+2,5,root,root_bits);CHECK(NADSP_ReadStats(&stats)==1 && stats.armed==1);
    CHECK(NADSP_End()==1 && actual_calls==start+2 && records[start+1].unit==f.c.viewmodel && std::memcmp(records[start+1].bits,f.source(),16)==0);
    pass("foreign unit on same callsite forwards without disarming or losing own baseline");
    f.begin_at(4000);fixture_now=4150;f.match();start=actual_calls;f.rig(f.c.viewmodel,6,root);
    exact(start,f.c.viewmodel,6,root,root_bits);CHECK(NADSP_ReadStats(&stats)==1 && stats.armed==1);
    CHECK(NADSP_End()==1 && actual_calls==start+2);pass("other node exact-forwards and retains own node5 baseline");
    f.begin_at(5000);fixture_now=5150;f.match();start=actual_calls;f.rig(f.c.viewmodel,5,root);
    exact(start,f.c.viewmodel,5,root,root_bits);CHECK(NADSP_ReadStats(&stats)==1 && stats.armed==1);
    CHECK(NADSP_End()==1 && actual_calls==start+1);pass("fading record pointer exact-forwards; no stale End replay or disarm");
    f.begin_at(5500);fixture_now=5650;f.match();f.rig(f.c.viewmodel,5,root);f.pose(7,8,9);f.match();start=actual_calls;
    CHECK(NADSP_End()==1 && actual_calls==start+1 && std::memcmp(records[start].bits,f.source(),16)==0);
    pass("later owned record reestablishes fresh baseline after fading record");
    f.begin_at(6000);fixture_now=6150;f.match();f.pose(7,8,9);fixture_now=7000;start=actual_calls;f.match();CHECK(actual_calls==start+1);
    exact(start,f.c.viewmodel,5,f.source(),f.source());CHECK(NADSP_ReadStats(&stats)==1 && stats.expired==1 && stats.armed==0);
    CHECK(NADSP_Begin(&f.c)==0 && NADSP_Error()==BUSY);CHECK(NADSP_End()==1 && actual_calls==start+1);pass("TTL forwards latest baseline; reservation lasts until End");
    f.begin_at(8000);fixture_now=8150;f.match();start=actual_calls;fixture_now=9000;CHECK(NADSP_ReadStats(&stats)==1 && stats.zero_restores==1 && actual_calls==start+1);
    CHECK(std::memcmp(records[start].bits,f.source(),16)==0 && NADSP_End()==1 && actual_calls==start+1);pass("stats TTL restores cached native baseline once");
    f.normal();fixture_cas_calls=0;put<uint32_t>(f.object+0x70,62);CHECK(NADSP_Validate(&f.c)==0 && NADSP_Error()==GRAPH_MISMATCH && NADSP_Begin(&f.c)==0 && fixture_cas_calls==0);put<uint32_t>(f.object+0x70,63);
    put<uint8_t>(f.c.exe+0x2BD870,0x90);CHECK(NADSP_Validate(&f.c)==0 && NADSP_Error()==GRAPH_MISMATCH);put<uint8_t>(f.c.exe+0x2BD870,0x48);
    put<uint8_t>(f.c.game+0x1288420,0x90);CHECK(NADSP_Validate(&f.c)==0 && NADSP_Error()==CODE_MISMATCH);put<uint8_t>(f.c.game+0x1288420,0x41);
    pass("count/getter/callsite drift rejects before CAS");
    const uint32_t selected[]={0,1,2,3,4,5,7,8,10,12,13,30,32,34,50};
    for(uint32_t node:selected)for(unsigned table=0;table<2;++table) {
        const uint64_t address=(table?f.hashes:f.links)+node*4;uint32_t old=0;CHECK(value(address,old));put<uint32_t>(address,old^1);
        CHECK(NADSP_Validate(&f.c)==0 && NADSP_Error()==GRAPH_MISMATCH);put<uint32_t>(address,old);
    }pass("every selected arms/weapon/camera/ancestor hash and parent fails closed");
    for(unsigned failure=0;failure<5;++failure) {
        f.begin_at(10000+failure*2000);fixture_now+=150;f.match();start=actual_calls;uint64_t old_pointer=0;
        if(failure==0)put<uint32_t>(f.links+50*4,0x50001);if(failure==1)put<uint32_t>(f.hashes+5*4,0);
        if(failure==2) {CHECK(value(f.object+0x98,old_pointer));put<uint64_t>(f.object+0x98,allocate(0x1000));}
        if(failure==3)put<uint8_t>(f.gens+3,2);if(failure==4)put<uint32_t>(f.c.request+8,f.c.weapon+1);
        f.match();CHECK(actual_calls==start+1);exact(start,f.c.viewmodel,5,f.source(),f.source());CHECK(NADSP_End()==1 && actual_calls==start+1);
        if(failure==0)put<uint32_t>(f.links+50*4,0x40001);if(failure==1)put<uint32_t>(f.hashes+5*4,0x9B115563);
        if(failure==2)put<uint64_t>(f.object+0x98,old_pointer);if(failure==3)put<uint8_t>(f.gens+3,1);
    }pass("graph pointer/hash/camera drift and owner loss never replay stale baseline");
    for(unsigned index=0;index<3;++index) {
        f.begin_at(20000+index*2000);fixture_now+=150;f.match();put<uint32_t>(f.c.request+0x48+index*4,index&1?0x7F800000:0x7FC12345);
        start=actual_calls;f.match();CHECK(actual_calls==start+1);exact(start,f.c.viewmodel,5,f.source(),f.source());CHECK(NADSP_Error()==POSE_INVALID && NADSP_End()==1 && actual_calls==start+1);
    }pass("each nonfinite XYZ component exact-forwards and invalidates replay");
    f.begin_at(28000);fixture_now=28150;f.pose(1,2,3,0x7FC12345);f.match();
    CHECK(records[actual_calls-1].bits[3]==0x7FC12345 && NADSP_ReadStats(&stats)==1 && stats.armed==1);
    CHECK(NADSP_End()==1 && records[actual_calls-1].bits[3]==0x7FC12345);pass("arbitrary W padding preserved through offset and baseline restore");
    f.begin_at(30000);fixture_now=30150;f.match();put<uint32_t>(f.c.request+0x18,0);start=actual_calls;f.match();
    CHECK(actual_calls==start+1 && NADSP_Error()==SIGHT_NODE_UNAVAILABLE && NADSP_End()==1 && actual_calls==start+1);pass("sight guard forwards fresh baseline without older replay");
    for(unsigned failure=0;failure<4;++failure) {
        f.begin_at(32000+failure*2000);fixture_now+=150;f.match();start=actual_calls;
        if(failure==0)f.normal();if(failure==1)put<uint8_t>(f.gens+4,2);if(failure==2)put<uint32_t>(f.links+13*4,0x50001);if(failure==3)put<uint32_t>(f.c.request+12,f.c.body+1);
        CHECK(NADSP_End()==1 && actual_calls==start);if(failure==1)put<uint8_t>(f.gens+4,1);if(failure==2)put<uint32_t>(f.links+13*4,0xC0001);
    }pass("End skips kind4/generation/graph/foreign request");
    f.begin_at(42000);fixture_now=42150;setter_reached=CreateEventW(nullptr,TRUE,FALSE,nullptr);setter_continue=CreateEventW(nullptr,TRUE,FALSE,nullptr);CHECK(setter_reached && setter_continue);
    std::atomic<uint32_t> ended{0};std::thread callback_thread([&]{f.match();});CHECK(WaitForSingleObject(setter_reached,3000)==WAIT_OBJECT_0);
    std::thread end_thread([&]{CHECK(NADSP_End()==1);ended.store(1);});while(armed.load(std::memory_order_acquire))SwitchToThread();CHECK(ended.load()==0);
    SetEvent(setter_continue);callback_thread.join();end_thread.join();CloseHandle(setter_reached);CloseHandle(setter_continue);setter_reached=nullptr;setter_continue=nullptr;
    CHECK(ended.load()==1 && std::memcmp(records[actual_calls-1].bits,f.source(),16)==0);pass("End drains shifted setter before restoring baseline");
    f.normal();fixture_cas_calls=0;fixture_cas_fail_at=2;fixture_fail_rollback=true;CHECK(NADSP_Begin(&f.c)==2 && armed.load()==0 && reserved.load()==1);
    CHECK(NADSP_Begin(&f.c)==0 && NADSP_Error()==BUSY);fixture_fail_rollback=false;fixture_cas_fail_at=0;CHECK(NADSP_End()==1);
    f.begin_at(44000);fixture_now=44150;f.match();fixture_slot_unreadable=true;start=actual_calls;CHECK(NADSP_End()==0 && reserved.load()==1 && actual_calls==start+1);
    fixture_slot_unreadable=false;CHECK(NADSP_End()==1 && actual_calls==start+1);pass("partial Begin2 and End retry never repeat baseline write");
    f.normal();fixture_cas_calls=0;fixture_foreign_cas_at=2;fixture_foreign_value=reinterpret_cast<uint64_t>(synthetic_position);
    CHECK(NADSP_Begin(&f.c)==0 && reserved.load()==0);uint64_t slot=0;CHECK(value(f.api+0x48,slot) && slot==fixture_foreign_value);
    fixture_foreign_cas_at=0;put<uint64_t>(f.api+0x48,reinterpret_cast<uint64_t>(synthetic_rotation));pass("foreign pointer CAS replacement preserved");
    for(uint64_t i=0;i<actual_calls;++i)CHECK(records[i].unit!=f.c.weapon_unit);
    uint8_t after[2][64]{};CHECK(read(reinterpret_cast<uint64_t>(synthetic_position),after[0],64));CHECK(read(reinterpret_cast<uint64_t>(synthetic_rotation),after[1],64));
    CHECK(std::memcmp(before,after,sizeof before)==0);pass("no weapon root writes anywhere; executable bytes unchanged");
    std::printf("Native shared-rig pose fixture PASS: %llu cases\n",static_cast<unsigned long long>(cases));return 0;
}
