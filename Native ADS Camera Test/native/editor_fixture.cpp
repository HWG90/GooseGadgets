// Synthetic private allocations and local callbacks only; no game access.
#define NADSE_FIXTURE
#include "native_ads_editor.cpp"
#include <cstdio>
#include <cstdlib>
#include <thread>
#define CHECK(x) do{if(!(x)){std::fprintf(stderr,"FAIL %d: %s error=%u\n",__LINE__,#x,NADSE_Error());std::abort();}}while(0)
static uint64_t fixture_generation=0;
static uint32_t begin_current(const NADSE_Config* config) {
    uint64_t token=UINT64_MAX;const uint32_t result=NADSE_Begin(config,&token);CHECK(result<=2);
    if(result==0)CHECK(token==0);
    else {CHECK(token!=0 && token!=fixture_generation);fixture_generation=token;}
    return result;
}
static uint32_t end_current() {return NADSE_End(fixture_generation);}
static uint32_t read_current(NADSE_Stats* output) {return NADSE_ReadStats(reserved.load()?fixture_generation:0,output);}
struct Record {uint32_t unit,node,kind,bits[4];const float* pointer;};
static Record records[4096]{};static uint64_t actual_calls=0,cases=0;
static HANDLE setter_reached=nullptr,setter_continue=nullptr;
static HANDLE getter_reached=nullptr,getter_continue=nullptr;
static uint64_t getter_calls=0;static uint32_t getter_unit=0,getter_node=0;
static float getter_result[3]={.125f,-.25f,.5f};
static void record(uint32_t unit,uint32_t node,const float* pose,uint32_t kind) {
    CHECK(actual_calls<4096);auto& r=records[actual_calls++];r.unit=unit;r.node=node;r.kind=kind;r.pointer=pose;
    std::memcpy(r.bits,pose,16);
    if(setter_reached) {SetEvent(setter_reached);WaitForSingleObject(setter_continue,INFINITE);}
}
__declspec(noinline) static void synthetic_position(uint32_t unit,uint32_t node,const float* pose) {record(unit,node,pose,1);}
__declspec(noinline) static void synthetic_rotation(uint32_t unit,uint32_t node,const float* pose) {record(unit,node,pose,2);}
__declspec(noinline) static void synthetic_branch_rotation(uint32_t unit,uint32_t node,const float* pose) {record(unit,node,pose,3);}
__declspec(noinline) static const float* synthetic_getter(uint32_t unit,uint32_t node) {
    ++getter_calls;getter_unit=unit;getter_node=node;
    if(getter_reached) {SetEvent(getter_reached);WaitForSingleObject(getter_continue,INFINITE);}
    return getter_result;
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
static Setter stub(uint64_t site,unsigned which,uint64_t api) {
    // sub rsp,28; mov r9,API; call [r9+38/48]; add rsp,28; ret.
    literal(site-14,"4883ec2849b9");put<uint64_t>(site-8,api);
    literal(site,which==2?"41ff51404883c428c3":(which?"41ff51484883c428c3":"41ff51384883c428c3"));
    CHECK(FlushInstructionCache(GetCurrentProcess(),reinterpret_cast<void*>(site-14),23));return reinterpret_cast<Setter>(site-14);
}
static Getter getter_stub(uint64_t site,uint64_t api) {
    literal(site-17,"4883ec2849b9");put<uint64_t>(site-11,api);literal(site-3,"4d8b01");
    literal(site,"41ffd04883c428c3");CHECK(FlushInstructionCache(GetCurrentProcess(),reinterpret_cast<void*>(site-17),25));
    return reinterpret_cast<Getter>(site-17);
}
struct Fixture {
    NADSE_Config c{};uint64_t controller=0,descriptor=0,registry=0,gens=0,objects=0,api=0,object=0,vtable=0,links=0,hashes=0,poses=0;
    Setter calls[2]{},rig=nullptr,branch=nullptr;Getter getter=nullptr;
    Fixture() {
        c.size=sizeof c;c.abi=2;c.game=allocate(0x4744000,PAGE_EXECUTE_READWRITE);c.exe=allocate(0x39E8000);
        fake_image(c.game,0x6AB3B43F,0x4744000);fake_image(c.exe,0x6AB382E4,0x39E8000);
        // Independent captured opcode literals, not populated from production constants.
        literal(c.exe+0x1FC720,"48895c24084889742410574883ec20498bf08bfa8bd9e88511eaff4c8b5018b801000000f0410fc182380017008bc04c");
        literal(c.exe+0x1FC880,"48895c24084889742410574883ec20498bf08bfa8bd9e82510eaff4c8b5018b801000000f0410fc182380017008bc04c");
        literal(c.exe+0x1FC7A0,"48895c24084889742410574881eca0000000440f29b42490000000498bd84863fae8fa10eaff488bc8488bf04c8b0841");
        literal(c.exe+0x1FC450,"40534883ec204863dae86214eaff488bc84c8b0041ff90e8000000488bcb48c1e1064883c124488b40204803c14883c4205bc3");
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
        poses=allocate(0x1000);put<uint64_t>(object+0x80,poses);
        put<uint64_t>(object,vtable);put<uint64_t>(vtable+0xE8,c.exe+0x2BD870);put<uint32_t>(object+0x70,63);
        put<uint64_t>(object+0x98,links);put<uint64_t>(object+0xA0,hashes);
        // Independent full captured graph: uint32 parent/flag links and hash rows.
        literal(links,"000000000100000001000100010002000100030001000400010005000100050001000700010008000100070001000a0001000a0001000c0001000d0001000e0001000f0001000d00010011000100120001000d00010014000100150001000d00010017000100180001000d0001001a0001001b0001000c000100070001001e0001001e000100200001002000010022000100230001002400010022000100260001002700010022000100290001002a000100220001002c0001002d000100220001002f0001003000010004000100020001000200010034000100340001003400010034000100340001000c000100040001003b0001003b0001003b00");
        literal(hashes,"4127184a1ce6307fb23e6232bdeb5c97e591cfbc6355119b9d39944121d03b6f3733dd4f1e3b7289982c750398c74c1566cda21cd3680c5c54e0197a861e37d5b95c543040f6817864f9b82dea7e91a2757876e494c96cda7760e18328ffd1c798ab5bb10d94d76cf09fd8b7635d23c2925d1fdf3c6e78f6ceb22016123d4082ac4de3316cb31093f50480245fdeabaeea3b99735cb8af37d3e547e5e240ec9f427da945e9901568ae3ee464baabf19fe64a0b4677be9f43c6020ac0b53ec1d696b255f346436e6f398ced60d191d4a361d15c315675f12026d589f5d02a5069129de14412170ecb5b11c8a52008ef3739d8bcb24e7b78c466af7877");
        uint64_t root=allocate(0x1000);api=allocate(0x1000);put<uint64_t>(c.game+0x3326308,root);put<uint64_t>(root+0x18,api);
        fixture_targets[0]=synthetic_position;fixture_targets[1]=synthetic_rotation;fixture_targets[2]=synthetic_branch_rotation;
        fixture_targets[3]=reinterpret_cast<Setter>(synthetic_getter);
        put<uint64_t>(api+0x38,reinterpret_cast<uint64_t>(synthetic_position));put<uint64_t>(api+0x48,reinterpret_cast<uint64_t>(synthetic_rotation));
        put<uint64_t>(api+0x40,reinterpret_cast<uint64_t>(synthetic_branch_rotation));
        put<uint64_t>(api,reinterpret_cast<uint64_t>(synthetic_getter));
        calls[0]=stub(c.game+0x12887C9,0,api);calls[1]=stub(c.game+0x12887E9,1,api);rig=stub(c.game+0x1288420,0,api);
        branch=stub(c.game+0x12890DB,2,api);getter=getter_stub(c.game+0x1287A41,api);normal();
    }
    void normal() {
        put<uint32_t>(c.context+0x1F8,0);put<uint32_t>(c.context+0x1FC,1);put<uint32_t>(c.context+0x200,4);put<uint32_t>(c.context+0x204,c.avatar);
        c.request=c.context+0x200+0xE8;put<uint8_t>(c.avatar_owner+0x53E886,0);shoulder(false);std::memset(reinterpret_cast<void*>(controller),0,6);
    }
    void shoulder(bool active) {put<uint8_t>(c.avatar_owner+0x53E88A,active?4:0);put<uint8_t>(c.avatar_owner+0x53E88F,active?32:0);}
    float* source() {return reinterpret_cast<float*>(c.request+0x48);}
    void pose(float x,float y,float z,uint32_t w=0x80000000) {const float xyz[3]={x,y,z};std::memcpy(source(),xyz,12);put<uint32_t>(c.request+0x54,w);}
    void fpv() {
        put<uint32_t>(c.context+0x1FC,2);put<uint32_t>(c.request,6);put<uint32_t>(c.request+4,c.avatar);
        put<uint32_t>(c.request+8,c.weapon);put<uint32_t>(c.request+12,c.body);put<uint32_t>(c.request+0x18,3);pose(1,2,3);
    }
    void begin_at(uint64_t now) {normal();fixture_now=now;CHECK(begin_current(&c)==1);fpv();}
    void match() {rig(c.viewmodel,5,source());}
    void sole() {put<uint32_t>(c.context+0x1F8,1);put<float>(c.request+0x98,0);}
};
struct DepthFixture {
    Fixture& f;uint64_t frame=0,pool=0,primary=0,overrides=0,runtime=0,packed=0,data=0,table=0,world=0;
    unsigned selection=0;float target=0;
    explicit DepthFixture(Fixture& input):f(input) {
        frame=allocate(0x1000);pool=allocate(0x1000);primary=allocate(0x1000);overrides=allocate(0x1000);
        runtime=allocate(0x1000);packed=allocate(0x1000);data=allocate(0x4000);table=allocate(0x20000);world=allocate(0xF14000);
        const uint64_t settings=allocate(0xAD000),descriptors=allocate(0x1000);
        put<uint64_t>(f.c.game+0x3326CE0,pool);put<uint64_t>(f.c.game+0x346BF98,world);
        put<uint64_t>(f.c.game+0x3326340,settings);put<float>(settings+0xAC408,90);
        put<uint64_t>(pool+0x30,primary);put<uint32_t>(pool+0x38,8);put<uint32_t>(pool+0x3C,UINT32_MAX);put<uint32_t>(pool+0x40,1);
        put<uint64_t>(pool+0x70,overrides);put<uint32_t>(pool+0x78,8);put<uint32_t>(pool+0x7C,UINT32_MAX);put<uint32_t>(pool+0x80,1);
        for(unsigned i=0;i<8;++i) {put<uint64_t>(primary+i*8,UINT32_MAX);put<uint64_t>(overrides+i*8,UINT32_MAX);}
        put<uint64_t>(primary+(f.c.weapon%8)*8,f.c.weapon);
        put<uint64_t>(pool+0x48,descriptors);put<uint64_t>(descriptors,f.c.weapon_descriptor);
        put<uint64_t>(pool+0x58,runtime);put<uint64_t>(pool+0x60,packed);put<uint64_t>(pool+0xB0,data);
        put<uint32_t>(runtime+0x350,1);put<uint64_t>(f.c.weapon_descriptor,UINT64_C(0xFFFFFFFFFFFFFFFE));
        put<uint64_t>(world+0xF12BD8,table);
        const uint32_t bucket=static_cast<uint32_t>(UINT64_C(0xFFFFFFFFFFFFFFFE)%730);
        put<uint64_t>(table+bucket*16,UINT64_C(0xFFFFFFFFFFFFFFFE));put<uint32_t>(table+bucket*16+8,0);
        properties(data);properties(table+0x2DA0);
        literal(f.c.game+0x12873B3,"f30f1044245cf30f1015df4b1401");
        literal(f.c.game+0x12873D9,"f30f5c4424600f54c2f30f5ec1");
        literal(f.c.game+0x1287A91,"f3450f58fb");literal(f.c.game+0x1287B43,"f30f59faf3410f59cff3");
        literal(f.c.game+0x1287C04,"f3410f11774cf3450f114750");
        literal(f.c.game+0x1286335,"5556574154415541564157488dac24f0fcffff4881ec10040000");
        literal(f.c.game+0x128878B,"4c8d8540010000f2410f11475433");literal(f.c.game+0x12887D4,"4c8d8530010000");
        f.c.offset_x=0;f.c.offset_y=0;f.c.offset_z=0;f.c.duration_ms=0;
    }
    static void properties(uint64_t at) {
        put<float>(at+0x74,1);put<float>(at+0x78,2.5f);put<float>(at+0x7C,3.5f);
        for(unsigned i=0;i<3;++i)put<float>(at+0x13C+i*4,.6f);
    }
    static float lens(unsigned index) {const float zoom[3]={1,2.5f,3.5f};return (90.0f/zoom[index])*.01745329238474369f;}
    static float distance(unsigned index) {return .03391552f/(std::tan(lens(index)*.5f)*.6f);}
    void begin(uint64_t now,unsigned index=0) {
        fixture_depth_frame=frame;f.begin_at(now);f.sole();selection=index;target=lens(index);
        put<uint32_t>(packed+4,64|(index<<4));put<float>(f.c.request+0x90,distance(index));put<float>(f.c.request+0x9C,0);
        put<float>(f.c.request+0xA0,target);put<uint8_t>(f.c.request+0x8D,0);put<uint8_t>(f.c.request+0x8F,0);
        std::memset(reinterpret_cast<void*>(frame),0,0x100);frame_at(0);
    }
    void event(unsigned index) {
        float old=0,prior=0;CHECK(value(f.c.request+0x90,old) && value(f.c.request+0x84,prior));
        put<float>(f.c.request+0x9C,old);put<float>(f.c.request+0xA0,prior);put<float>(f.c.request+0x90,distance(index));
        put<uint32_t>(packed+4,64|(index<<4));selection=index;target=lens(index);
    }
    float frame_at(float progress,float x=1.25f,float z=-3.5f) {
        float prior=0,current=0,previous=0;CHECK(value(f.c.request+0xA0,prior));
        const float live=target+(prior-target)*progress;
        put<float>(frame+0x5C,target);put<float>(frame+0x60,live);put<float>(f.c.request+0x84,live);
        CHECK(value(f.c.request+0x90,current) && value(f.c.request+0x9C,previous));
        const float span=std::fabs(target-prior),t=span>1.1920928955078125e-7f?std::fmin(std::fabs(target-live)/span,1.0f):0;
        const float effective=(1-t)*current+t*previous;
        float gain=1,mix=0;uint8_t mode=0;CHECK(value(f.c.request+0x8D,mode));
        if(mode) {CHECK(value(f.c.request+0x88,mix));gain=mix;}
        f.pose(x,2+effective*gain,z,0x7FC12345);
        CHECK(f.getter(f.c.viewmodel,50)==getter_result);
        // The real evaluator reuses+5C after the observed getter. A late
        // stack read must fail this fixture rather than appear to work.
        put<float>(frame+0x5C,-1234.5f);return effective;
    }
    void end() {CHECK(end_current()==1);fixture_depth_frame=0;}
    float* root_source() {return reinterpret_cast<float*>(frame+0x240);}
    void root(float native_depth,const float (&q)[4],float base_x=10,float base_y=20,float base_z=30) {
        const float forward[3]={2*(q[0]*q[1]-q[2]*q[3]),q[3]*q[3]+q[1]*q[1]-q[0]*q[0]-q[2]*q[2],2*(q[1]*q[2]+q[0]*q[3])};
        const float native[4]={base_x-native_depth*forward[0],base_y-native_depth*forward[1],base_z-native_depth*forward[2],0};
        std::memcpy(reinterpret_cast<void*>(frame+0x230),q,16);std::memcpy(root_source(),native,16);
        put<uint32_t>(frame+0x24C,0x7FC54321);
        f.calls[0](f.c.viewmodel,0,root_source());
    }
    void settle_root() {CHECK(records[actual_calls-1].node==0);std::memcpy(reinterpret_cast<void*>(f.poses+0x24),records[actual_calls-1].bits,12);}
};
static float component(unsigned index) {float out=0;std::memcpy(&out,&records[actual_calls-1].bits[index],4);return out;}
static bool approximately(float a,float b) {return std::fabs(a-b)<.00001f;}
static void exact(uint64_t index,uint32_t unit,uint32_t node,const float* ptr,const void* bits) {
    CHECK(records[index].unit==unit && records[index].node==node && records[index].pointer==ptr && std::memcmp(records[index].bits,bits,16)==0);
}
static void pass(const char* name) {++cases;std::printf("PASS %s\n",name);}
int main() {
    Fixture f;fixture_now=1000;NADSE_Stats stats{};stats.size=sizeof stats;stats.abi=2;
    CHECK(read_current(&stats)==1 && stats.installed==0 && stats.armed==0);CHECK(NADSE_Validate(&f.c)==1 && fixture_cas_calls==0);
    pass("cold ABI and read-only preflight");
    for(unsigned state=0;state<2;++state) {
        f.normal();put<uint8_t>(state==0?f.c.avatar_owner+0x53E886:f.controller+4,1);fixture_cas_calls=0;
        CHECK(NADSE_Validate(&f.c)==0 && begin_current(&f.c)==0 && fixture_cas_calls==0 && reserved.load()==0);
    }
    f.normal();pass("entry preserves the original bit48 and native full ADS veto");
    f.shoulder(true);fixture_now=800;CHECK(NADSE_Validate(&f.c)==1 && begin_current(&f.c)==1);f.fpv();f.match();
    fixture_now=950;f.match();CHECK(policy.shoulder_aiming && !policy.native_aiming && approximately(policy.weight,1.0f));
    CHECK(end_current()==1);f.normal();
    pass("accepted shoulder aim with bit48 clear permits entry and retains full saved offset");
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
    f.shoulder(true);fixture_now=1160;f.match();CHECK(read_current(&stats)==1 && stats.armed==1 && stats.target_weight==1.0f && !policy.native_aiming);
    fixture_now=1235;f.match();CHECK(approximately(component(0),4.15f));fixture_now=1310;f.match();
    CHECK(approximately(component(0),4.15f) && approximately(component(2),5.88f) && approximately(policy.weight,1.0f));
    pass("agreeing accepted aim bits82 and125 retain saved placement with bit48 clear");
    put<uint8_t>(f.c.avatar_owner+0x53E886,1);put<uint8_t>(f.controller+4,1);fixture_now=1320;f.match();CHECK(read_current(&stats)==1 && stats.armed==1 && stats.target_weight==0);
    fixture_now=1395;f.match();CHECK(approximately(component(0),4.075f));fixture_now=1470;f.match();
    CHECK(approximately(component(0),4) && records[actual_calls-1].pointer==f.source());
    f.shoulder(false);fixture_now=1480;f.match();CHECK(records[actual_calls-1].pointer==f.source());
    f.shoulder(true);put<uint8_t>(f.c.avatar_owner+0x53E886,0);put<uint8_t>(f.controller+4,0);fixture_now=1490;f.match();
    fixture_now=1640;f.match();CHECK(approximately(component(0),4.15f));
    f.shoulder(false);fixture_now=1650;f.match();fixture_now=1800;f.match();CHECK(approximately(component(0),4.15f));
    pass("native controller ADS wins both aim flags and returns through shoulder to hip without disarming");
    CHECK(read_current(&stats)==1 && stats.forwarded_position==stats.seen_position && stats.forwarded_rotation==stats.seen_rotation);
    start=actual_calls;CHECK(end_current()==1 && actual_calls==start+1);CHECK(records[start].unit==f.c.viewmodel && records[start].node==5);
    CHECK(std::memcmp(records[start].bits,f.source(),16)==0 && records[start].bits[0]!=0);CHECK(end_current()==1 && actual_calls==start+1);
    pass("End restores latest native baseline once, never zero or weapon root");
    f.begin_at(1800);fixture_now=1950;f.match();put<uint8_t>(f.c.avatar_owner+0x53E886,1);f.match();
    CHECK(policy.native_aiming && !policy.shoulder_aiming && approximately(policy.target,1) && approximately(component(0),1.15f));
    CHECK(read_current(&stats)==1 && stats.armed==1 && end_current()==1);
    pass("native bit48 alone does not claim shoulder aim or alter running hip weight");
    for(unsigned mismatch=0;mismatch<2;++mismatch) {
        f.begin_at(1800);fixture_now=1950;f.match();
        put<uint8_t>(f.c.avatar_owner+(mismatch==0?0x53E88A:0x53E88F),mismatch==0?4:32);f.match();
        CHECK(!policy.shoulder_aiming && approximately(policy.target,1) && approximately(component(0),1.15f));
        put<uint8_t>(f.controller+4,1);f.match();fixture_now=2100;f.match();
        CHECK(approximately(policy.target,0) && records[actual_calls-1].pointer==f.source());
        CHECK(read_current(&stats)==1 && stats.armed==1 && end_current()==1);
    }
    pass("either mismatched aim bit stays hip while full ADS still reaches exact native input");
    f.begin_at(2000);fixture_now=2150;start=actual_calls;reinterpret_cast<Setter>(callback(0))(f.c.viewmodel,5,f.source());
    CHECK(actual_calls==start+1);exact(start,f.c.viewmodel,5,f.source(),f.source());CHECK(end_current()==1);pass("wrong caller exact pass-through");
    f.begin_at(2500);fixture_now=2650;f.match();start=actual_calls;f.rig(f.c.viewmodel+2,5,root);
    exact(start,f.c.viewmodel+2,5,root,root_bits);CHECK(read_current(&stats)==1 && stats.armed==1);
    CHECK(end_current()==1 && actual_calls==start+2 && records[start+1].unit==f.c.viewmodel && std::memcmp(records[start+1].bits,f.source(),16)==0);
    pass("foreign unit on same callsite forwards without disarming or losing own baseline");
    f.begin_at(4000);fixture_now=4150;f.match();start=actual_calls;f.rig(f.c.viewmodel,6,root);
    exact(start,f.c.viewmodel,6,root,root_bits);CHECK(read_current(&stats)==1 && stats.armed==1);
    CHECK(end_current()==1 && actual_calls==start+2);pass("other node exact-forwards and retains own node5 baseline");
    f.begin_at(5000);fixture_now=5150;f.match();start=actual_calls;f.rig(f.c.viewmodel,5,root);
    exact(start,f.c.viewmodel,5,root,root_bits);CHECK(read_current(&stats)==1 && stats.armed==1);
    CHECK(end_current()==1 && actual_calls==start+1);pass("fading record pointer exact-forwards; no stale End replay or disarm");
    f.begin_at(5500);fixture_now=5650;f.match();f.rig(f.c.viewmodel,5,root);f.pose(7,8,9);f.match();start=actual_calls;
    CHECK(end_current()==1 && actual_calls==start+1 && std::memcmp(records[start].bits,f.source(),16)==0);
    pass("later owned record reestablishes fresh baseline after fading record");
    f.begin_at(6000);fixture_now=6150;f.match();f.pose(7,8,9);fixture_now=7000;start=actual_calls;f.match();CHECK(actual_calls==start+1);
    exact(start,f.c.viewmodel,5,f.source(),f.source());CHECK(read_current(&stats)==1 && stats.expired==1 && stats.armed==0);
    CHECK(begin_current(&f.c)==0 && NADSE_Error()==BUSY);CHECK(end_current()==1 && actual_calls==start+1);pass("TTL forwards latest baseline; reservation lasts until End");
    f.begin_at(8000);fixture_now=8150;f.match();start=actual_calls;fixture_now=9000;CHECK(read_current(&stats)==1 && stats.zero_restores==1 && actual_calls==start+1);
    CHECK(std::memcmp(records[start].bits,f.source(),16)==0 && end_current()==1 && actual_calls==start+1);pass("stats TTL restores cached native baseline once");
    f.normal();fixture_cas_calls=0;put<uint32_t>(f.object+0x70,62);CHECK(NADSE_Validate(&f.c)==0 && NADSE_Error()==GRAPH_MISMATCH && begin_current(&f.c)==0 && fixture_cas_calls==0);put<uint32_t>(f.object+0x70,63);
    put<uint8_t>(f.c.exe+0x2BD870,0x90);CHECK(NADSE_Validate(&f.c)==0 && NADSE_Error()==GRAPH_MISMATCH);put<uint8_t>(f.c.exe+0x2BD870,0x48);
    put<uint8_t>(f.c.game+0x1288420,0x90);CHECK(NADSE_Validate(&f.c)==0 && NADSE_Error()==CODE_MISMATCH);put<uint8_t>(f.c.game+0x1288420,0x41);
    pass("count/getter/callsite drift rejects before CAS");
    const uint32_t selected[]={0,1,2,3,4,5,7,8,10,12,13,30,32,34,50};
    for(uint32_t node:selected)for(unsigned table=0;table<2;++table) {
        const uint64_t address=(table?f.hashes:f.links)+node*4;uint32_t old=0;CHECK(value(address,old));put<uint32_t>(address,old^1);
        CHECK(NADSE_Validate(&f.c)==0 && NADSE_Error()==GRAPH_MISMATCH);put<uint32_t>(address,old);
    }pass("every selected arms/weapon/camera/ancestor hash and parent fails closed");
    for(unsigned failure=0;failure<5;++failure) {
        f.begin_at(10000+failure*2000);fixture_now+=150;f.match();start=actual_calls;uint64_t old_pointer=0;
        if(failure==0)put<uint32_t>(f.links+50*4,0x50001);if(failure==1)put<uint32_t>(f.hashes+5*4,0);
        if(failure==2) {CHECK(value(f.object+0x98,old_pointer));put<uint64_t>(f.object+0x98,allocate(0x1000));}
        if(failure==3)put<uint8_t>(f.gens+3,2);if(failure==4)put<uint32_t>(f.c.request+8,f.c.weapon+1);
        f.match();CHECK(actual_calls==start+1);exact(start,f.c.viewmodel,5,f.source(),f.source());CHECK(end_current()==1 && actual_calls==start+1);
        if(failure==0)put<uint32_t>(f.links+50*4,0x40001);if(failure==1)put<uint32_t>(f.hashes+5*4,0x9B115563);
        if(failure==2)put<uint64_t>(f.object+0x98,old_pointer);if(failure==3)put<uint8_t>(f.gens+3,1);
    }pass("graph pointer/hash/camera drift and owner loss never replay stale baseline");
    for(unsigned index=0;index<3;++index) {
        f.begin_at(20000+index*2000);fixture_now+=150;f.match();put<uint32_t>(f.c.request+0x48+index*4,index&1?0x7F800000:0x7FC12345);
        start=actual_calls;f.match();CHECK(actual_calls==start+1);exact(start,f.c.viewmodel,5,f.source(),f.source());CHECK(NADSE_Error()==POSE_INVALID && end_current()==1 && actual_calls==start+1);
    }pass("each nonfinite XYZ component exact-forwards and invalidates replay");
    f.begin_at(28000);fixture_now=28150;f.pose(1,2,3,0x7FC12345);f.match();
    CHECK(records[actual_calls-1].bits[3]==0x7FC12345 && read_current(&stats)==1 && stats.armed==1);
    CHECK(end_current()==1 && records[actual_calls-1].bits[3]==0x7FC12345);pass("arbitrary W padding preserved through offset and baseline restore");
    f.begin_at(30000);fixture_now=30150;f.match();put<uint32_t>(f.c.request+0x18,0);start=actual_calls;f.match();
    CHECK(actual_calls==start+1 && NADSE_Error()==SIGHT_NODE_UNAVAILABLE && end_current()==1 && actual_calls==start+1);pass("sight guard forwards fresh baseline without older replay");
    for(unsigned failure=0;failure<4;++failure) {
        f.begin_at(32000+failure*2000);fixture_now+=150;f.match();start=actual_calls;
        if(failure==0)f.normal();if(failure==1)put<uint8_t>(f.gens+4,2);if(failure==2)put<uint32_t>(f.links+13*4,0x50001);if(failure==3)put<uint32_t>(f.c.request+12,f.c.body+1);
        CHECK(end_current()==1 && actual_calls==start);if(failure==1)put<uint8_t>(f.gens+4,1);if(failure==2)put<uint32_t>(f.links+13*4,0xC0001);
    }pass("End skips kind4/generation/graph/foreign request");
    f.begin_at(42000);fixture_now=42150;setter_reached=CreateEventW(nullptr,TRUE,FALSE,nullptr);setter_continue=CreateEventW(nullptr,TRUE,FALSE,nullptr);CHECK(setter_reached && setter_continue);
    std::atomic<uint32_t> ended{0};std::thread callback_thread([&]{f.match();});CHECK(WaitForSingleObject(setter_reached,3000)==WAIT_OBJECT_0);
    std::thread end_thread([&]{CHECK(end_current()==1);ended.store(1);});while(armed.load(std::memory_order_acquire))SwitchToThread();CHECK(ended.load()==0);
    SetEvent(setter_continue);callback_thread.join();end_thread.join();CloseHandle(setter_reached);CloseHandle(setter_continue);setter_reached=nullptr;setter_continue=nullptr;
    CHECK(ended.load()==1 && std::memcmp(records[actual_calls-1].bits,f.source(),16)==0);pass("End drains shifted setter before restoring baseline");
    f.normal();fixture_cas_calls=0;fixture_cas_fail_at=2;fixture_fail_rollback=true;CHECK(begin_current(&f.c)==2 && armed.load()==0 && reserved.load()==1);
    CHECK(begin_current(&f.c)==0 && NADSE_Error()==BUSY);fixture_fail_rollback=false;fixture_cas_fail_at=0;CHECK(end_current()==1);
    f.begin_at(44000);fixture_now=44150;f.match();fixture_slot_unreadable=true;start=actual_calls;CHECK(end_current()==0 && reserved.load()==1 && actual_calls==start);
    fixture_slot_unreadable=false;CHECK(end_current()==1 && actual_calls==start);pass("partial Begin2 and unreadable dispatch cleanup never replay an unverified cached baseline");
    f.normal();fixture_cas_calls=0;fixture_foreign_cas_at=2;fixture_foreign_value=reinterpret_cast<uint64_t>(synthetic_position);
    CHECK(begin_current(&f.c)==0 && reserved.load()==0);uint64_t slot=0;CHECK(value(f.api+0x48,slot) && slot==fixture_foreign_value);
    fixture_foreign_cas_at=0;put<uint64_t>(f.api+0x48,reinterpret_cast<uint64_t>(synthetic_rotation));pass("foreign pointer CAS replacement preserved");
    // Generation must identify the currently reserved session for every API.
    const uint64_t stale=fixture_generation;f.begin_at(50000);const uint64_t current=fixture_generation;CHECK(current!=stale);
    start=actual_calls;CHECK(NADSE_SetPlacement(stale,.3f,.3f,.3f)==0 && NADSE_Error()==TOKEN_MISMATCH);
    CHECK(NADSE_End(stale)==0 && NADSE_Error()==TOKEN_MISMATCH && armed.load()==1);
    CHECK(NADSE_ReadStats(0,&stats)==0 && NADSE_ReadStats(stale,&stats)==0 && NADSE_ReadStats(current,&stats)==1);
    uint64_t busy_token=UINT64_MAX;CHECK(NADSE_Begin(&f.c,&busy_token)==0 && busy_token==0 && owned_generation==current && armed.load()==1);
    CHECK(actual_calls==start && end_current()==1);CHECK(NADSE_ReadStats(current,&stats)==0 && NADSE_ReadStats(0,&stats)==1);
    pass("stale/zero generation cannot edit, observe, or end another session; BUSY output zero");
    // New native Y placement is initial config data, not a separate pre-entry write.
    f.c.offset_y=.08f;f.begin_at(52000);fixture_now=52150;f.match();
    CHECK(approximately(component(0),1.15f) && approximately(component(1),2.08f) && approximately(component(2),2.88f));
    CHECK(end_current()==1);f.c.offset_y=0;pass("initial config carries all XYZ including depth");
    f.begin_at(54000);fixture_now=54150;start=actual_calls;
    CHECK(NADSE_SetPlacement(fixture_generation,-.2f,.25f,.3f)==1 && actual_calls==start);
    const uint64_t deadline=policy.deadline;f.match();CHECK(approximately(component(0),.8f) && approximately(component(1),2.25f) && approximately(component(2),3.3f));
    f.match();CHECK(approximately(component(1),2.25f));f.pose(4,5,6,0x7FC12345);f.match();
    CHECK(approximately(component(0),3.8f) && approximately(component(1),5.25f) && approximately(component(2),6.3f));
    CHECK(records[actual_calls-1].bits[3]==0x7FC12345 && policy.deadline==deadline);
    float invalid=0;const uint32_t invalid_bits=0x7FC12345;std::memcpy(&invalid,&invalid_bits,4);
    CHECK(NADSE_SetPlacement(fixture_generation,invalid,0,0)==0 && NADSE_SetPlacement(fixture_generation,0,.5001f,0)==0);
    CHECK(NADSE_SetPlacement(fixture_generation,0,0,-.5001f)==0 && armed.load()==1);
    f.match();CHECK(approximately(component(0),3.8f) && approximately(component(1),5.25f));
    CHECK(end_current()==1 && std::memcmp(records[actual_calls-1].bits,f.source(),16)==0);
    pass("hot XYZ updates are absolute, source/W preserved, invalid values keep last placement");
    f.begin_at(56000);fixture_now=56150;CHECK(NADSE_SetPlacement(fixture_generation,.1f,.2f,.3f)==1);f.match();
    put<uint8_t>(f.controller+4,1);fixture_now=56160;f.match();fixture_now=56310;f.match();
    CHECK(approximately(component(0),1) && approximately(component(1),2) && approximately(component(2),3) && armed.load()==1);
    CHECK(end_current()==1);pass("real ADS blends all three editable axes to native zero");
    // Updates never renew the native lifetime; 30500 is an absolute hard limit.
    f.c.duration_ms=30501;f.normal();uint64_t invalid_token=UINT64_MAX;fixture_cas_calls=0;
    CHECK(NADSE_Validate(&f.c)==0 && NADSE_Begin(&f.c,&invalid_token)==0 && invalid_token==0 && fixture_cas_calls==0);
    f.c.duration_ms=30500;f.begin_at(60000);const uint64_t fixed_deadline=policy.deadline;CHECK(fixed_deadline==90500);
    fixture_now=60150;CHECK(NADSE_SetPlacement(fixture_generation,.1f,.2f,.3f)==1);f.match();
    fixture_now=90499;CHECK(NADSE_SetPlacement(fixture_generation,.2f,.1f,-.1f)==1 && policy.deadline==fixed_deadline);f.match();
    fixture_now=90500;start=actual_calls;CHECK(NADSE_SetPlacement(fixture_generation,0,0,0)==0 && NADSE_Error()==DEADLINE_EXPIRED);
    CHECK(armed.load()==0 && reserved.load()==1 && expired.load()==1 && actual_calls==start+1 && policy.deadline==fixed_deadline);
    CHECK(NADSE_ReadStats(fixture_generation,&stats)==1 && stats.expired==1 && end_current()==1);f.c.duration_ms=1000;
    pass("30.5 second hard limit cannot be extended by placement updates");
    // Token is already published when the very first pointer CAS is attempted.
    f.normal();fixture_cas_calls=0;fixture_cas_fail_at=2;fixture_fail_rollback=true;
    uint64_t partial=0;fixture_output_to_check=&partial;fixture_generation_published=true;
    CHECK(NADSE_Begin(&f.c,&partial)==2 && partial!=0 && owned_generation==partial && fixture_generation_published);
    fixture_output_to_check=nullptr;CHECK(NADSE_ReadStats(partial,&stats)==1 && stats.installed==1 && stats.armed==0);
    CHECK(NADSE_SetPlacement(partial,0,0,0)==0 && NADSE_End(current)==0 && reserved.load()==1);
    fixture_slot_unreadable=true;CHECK(NADSE_End(partial)==0 && owned_generation==partial && NADSE_ReadStats(partial,&stats)==1);
    fixture_slot_unreadable=false;fixture_fail_rollback=false;fixture_cas_fail_at=0;
    CHECK(NADSE_End(partial)==1 && NADSE_End(partial)==1 && NADSE_ReadStats(0,&stats)==1);
    pass("Begin2 publishes its own cleanup token before CAS and retains it across End retries");
    // SetPlacement serializes all axes with the actual original setter call.
    f.begin_at(100000);fixture_now=100150;CHECK(NADSE_SetPlacement(fixture_generation,.1f,.2f,.3f)==1);
    setter_reached=CreateEventW(nullptr,TRUE,FALSE,nullptr);setter_continue=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    HANDLE update_started=CreateEventW(nullptr,TRUE,FALSE,nullptr);CHECK(setter_reached && setter_continue && update_started);
    std::atomic<uint32_t> updated{0};start=actual_calls;std::thread xyz_callback([&]{f.match();});
    CHECK(WaitForSingleObject(setter_reached,3000)==WAIT_OBJECT_0);
    std::thread update_thread([&]{SetEvent(update_started);CHECK(NADSE_SetPlacement(fixture_generation,-.1f,-.2f,-.3f)==1);updated.store(1);});
    CHECK(WaitForSingleObject(update_started,3000)==WAIT_OBJECT_0 && updated.load()==0);SetEvent(setter_continue);
    xyz_callback.join();update_thread.join();CloseHandle(setter_reached);CloseHandle(setter_continue);CloseHandle(update_started);
    setter_reached=nullptr;setter_continue=nullptr;CHECK(updated.load()==1);
    CHECK(approximately(component(0),1.1f) && approximately(component(1),2.2f) && approximately(component(2),3.3f));
    f.match();CHECK(actual_calls==start+2 && approximately(component(0),.9f) && approximately(component(1),1.8f) && approximately(component(2),2.7f));
    CHECK(end_current()==1);pass("XYZ update waits for in-flight setter and cannot expose mixed-axis placement");
    // The live update API retains every native guard from the matching callback.
    f.begin_at(102000);fixture_now=102150;f.match();put<uint32_t>(f.links+50*4,0x50001);start=actual_calls;
    CHECK(NADSE_SetPlacement(fixture_generation,0,0,0)==0 && NADSE_Error()==GRAPH_MISMATCH && armed.load()==0 && actual_calls==start);
    CHECK(end_current()==1 && actual_calls==start);put<uint32_t>(f.links+50*4,0x40001);
    f.begin_at(104000);fixture_now=104150;f.match();put<uint32_t>(f.c.request+8,f.c.weapon+1);start=actual_calls;
    CHECK(NADSE_SetPlacement(fixture_generation,0,0,0)==0 && NADSE_Error()==OWNER_MISMATCH && end_current()==1 && actual_calls==start);
    pass("hot update refuses changed graph or owner without stale native restoration");
    // Manual lifetime is explicit zero, with unchanged generation/rig guards.
    f.c.duration_ms=0;f.normal();CHECK(NADSE_Validate(&f.c)==1);f.begin_at(106000);CHECK(policy.deadline==0);
    fixture_now=UINT64_C(0x100000000);CHECK(NADSE_ReadStats(fixture_generation,&stats)==1 && stats.armed==1 && stats.expired==0);
    CHECK(NADSE_SetPlacement(fixture_generation,.2f,-.2f,.1f)==1 && policy.deadline==0);f.match();
    CHECK(approximately(component(0),1.2f) && approximately(component(1),1.8f) && approximately(component(2),3.1f));
    CHECK(NADSE_ReadStats(fixture_generation,&stats)==1 && stats.armed==1 && stats.expired==0);start=actual_calls;
    CHECK(end_current()==1 && actual_calls==start+1 && std::memcmp(records[start].bits,f.source(),16)==0);
    pass("zero duration accepts manual lifetime; long clock advances and edits never expire it; End restores");
    f.begin_at(UINT64_C(0x100001000));fixture_now+=150;f.match();put<uint8_t>(f.controller+5,1);start=actual_calls;f.match();
    CHECK(armed.load()==0 && reserved.load()==1 && NADSE_Error()==OWNER_MISMATCH && actual_calls==start+1);
    CHECK(end_current()==1 && actual_calls==start+1);f.c.duration_ms=1000;
    pass("manual lifetime still disarms on unsafe native guard and retains owned cleanup");
    f.begin_at(110000);fixture_now=110150;
    CHECK(NADSE_SetPlacement(fixture_generation,-.2f,.25f,.3f)==1);
    CHECK(NADSE_SetMotion(fixture_generation,.01f,-.02f,.03f)==1);
    const uint64_t motion_deadline=policy.deadline;std::memcpy(source_bits,f.source(),16);f.match();
    CHECK(approximately(component(0),.81f) && approximately(component(1),2.23f) && approximately(component(2),3.33f));
    f.match();CHECK(approximately(component(0),.81f) && std::memcmp(source_bits,f.source(),16)==0);
    CHECK(NADSE_SetMotion(fixture_generation,-.04f,.02f,-.01f)==1 && policy.c.offset_x==-.2f && policy.c.offset_y==.25f);
    CHECK(NADSE_SetPlacement(fixture_generation,-.1f,.1f,.1f)==1 && policy.motion[0]==-.04f && policy.motion[1]==.02f);
    f.pose(4,5,6,0x7FC12345);f.match();
    CHECK(approximately(component(0),3.86f) && approximately(component(1),5.12f) && approximately(component(2),6.09f));
    CHECK(records[actual_calls-1].bits[3]==0x7FC12345 && policy.deadline==motion_deadline);
    CHECK(end_current()==1 && std::memcmp(records[actual_calls-1].bits,f.source(),16)==0);
    CHECK(policy.motion[0]==0 && policy.motion[1]==0 && policy.motion[2]==0);
    pass("motion and placement stay separate; fresh baseline/W preserved; End clears motion");
    f.begin_at(112000);fixture_now=112150;
    CHECK(NADSE_SetMotion(fixture_generation,.15f,-.15f,.15f)==1);
    float bad_motion=0;const uint32_t bad_motion_bits=0x7FC12345;std::memcpy(&bad_motion,&bad_motion_bits,4);
    CHECK(NADSE_SetMotion(fixture_generation,bad_motion,0,0)==0);
    CHECK(NADSE_SetMotion(fixture_generation,0,.150001f,0)==0 && NADSE_SetMotion(fixture_generation,0,0,-.150001f)==0);
    CHECK(NADSE_SetMotion(fixture_generation-1,0,0,0)==0 && NADSE_Error()==TOKEN_MISMATCH);
    CHECK(NADSE_SetMotion(0,0,0,0)==0 && armed.load()==1);
    f.match();CHECK(approximately(component(0),1.3f) && approximately(component(1),1.85f) && approximately(component(2),3.03f));
    CHECK(end_current()==1);f.begin_at(113000);fixture_now=113150;f.match();
    CHECK(approximately(component(0),1.15f) && approximately(component(1),2) && approximately(component(2),2.88f));
    CHECK(end_current()==1);pass("motion finite bounds and opaque generation guards; new leases start at zero motion");
    f.begin_at(114000);fixture_now=114150;CHECK(NADSE_SetPlacement(fixture_generation,0,0,0)==1);
    CHECK(NADSE_SetMotion(fixture_generation,.1f,-.1f,.1f)==1);f.match();
    CHECK(approximately(component(0),1.1f) && approximately(component(1),1.9f));
    put<uint8_t>(f.controller+4,1);fixture_now=114160;f.match();fixture_now=114310;f.match();
    CHECK(std::memcmp(records[actual_calls-1].bits,f.source(),16)==0 && records[actual_calls-1].pointer==f.source());
    CHECK(end_current()==1);pass("real ADS blends procedural motion to exact native stock");
    f.begin_at(116000);fixture_now=116150;const uint64_t nonrenewed=policy.deadline;
    CHECK(NADSE_SetMotion(fixture_generation,.02f,.03f,.04f)==1);f.match();fixture_now=116999;
    CHECK(NADSE_SetMotion(fixture_generation,.03f,.02f,.01f)==1 && policy.deadline==nonrenewed);
    fixture_now=117000;CHECK(NADSE_SetMotion(fixture_generation,0,0,0)==0 && NADSE_Error()==DEADLINE_EXPIRED);
    CHECK(armed.load()==0 && reserved.load()==1 && end_current()==1 && policy.motion[0]==0);
    pass("motion updates cannot renew a bounded native deadline");
    f.begin_at(118000);fixture_now=118150;f.match();put<uint32_t>(f.links+50*4,0x50001);start=actual_calls;
    CHECK(NADSE_SetMotion(fixture_generation,.01f,0,0)==0 && NADSE_Error()==GRAPH_MISMATCH && armed.load()==0);
    CHECK(end_current()==1 && actual_calls==start);put<uint32_t>(f.links+50*4,0x40001);
    pass("motion retains graph and camera ownership guards without stale restore");
    f.begin_at(120000);fixture_now=120150;
    CHECK(NADSE_SetPlacement(fixture_generation,.1f,.2f,.3f)==1 && NADSE_SetMotion(fixture_generation,.01f,.02f,.03f)==1);
    setter_reached=CreateEventW(nullptr,TRUE,FALSE,nullptr);setter_continue=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    HANDLE motion_started=CreateEventW(nullptr,TRUE,FALSE,nullptr);CHECK(setter_reached && setter_continue && motion_started);
    std::atomic<uint32_t> motion_updated{0};std::thread motion_callback([&]{f.match();});
    CHECK(WaitForSingleObject(setter_reached,3000)==WAIT_OBJECT_0);
    std::thread motion_thread([&]{SetEvent(motion_started);CHECK(NADSE_SetMotion(fixture_generation,-.01f,-.02f,-.03f)==1);motion_updated.store(1);});
    CHECK(WaitForSingleObject(motion_started,3000)==WAIT_OBJECT_0 && motion_updated.load()==0);SetEvent(setter_continue);
    motion_callback.join();motion_thread.join();CloseHandle(setter_reached);CloseHandle(setter_continue);CloseHandle(motion_started);
    setter_reached=nullptr;setter_continue=nullptr;
    CHECK(motion_updated.load()==1 && approximately(component(0),1.11f) && approximately(component(1),2.22f) && approximately(component(2),3.33f));
    f.match();CHECK(approximately(component(0),1.09f) && approximately(component(1),2.18f) && approximately(component(2),3.27f));
    CHECK(end_current()==1);pass("motion XYZ updates serialize with in-flight original setter calls");
    // Independent noncommuting quaternions: parent X20deg * native Y90deg.
    const float sx=.1736481777f,cx=.9848077530f,h=.7071067812f;
    alignas(16) float base_q[4]={0,h,0,h};uint32_t base_bits[4];std::memcpy(base_bits,base_q,16);
    f.begin_at(122000);f.sole();fixture_now=122150;
    CHECK(NADSE_SetTransform(fixture_generation,.01f,-.02f,.03f,sx,0,0,cx)==1);
    const uint64_t transform_deadline=policy.deadline;start=actual_calls;f.branch(f.c.viewmodel,5,base_q);
    CHECK(actual_calls==start+1 && records[start].kind==3 && records[start].node==5);
    CHECK(approximately(component(0),sx*h) && approximately(component(1),cx*h)
        && approximately(component(2),sx*h) && approximately(component(3),cx*h));
    uint32_t first_q[4];std::memcpy(first_q,records[start].bits,16);f.branch(f.c.viewmodel,5,base_q);
    CHECK(std::memcmp(first_q,records[start+1].bits,16)==0 && std::memcmp(base_bits,base_q,16)==0);
    CHECK(policy.deadline==transform_deadline && approximately(policy.motion[0],.01f));
    CHECK(read_current(&stats)==1 && stats.weapon_updates==2 && stats.seen_rotation==2);
    start=actual_calls;CHECK(end_current()==1 && actual_calls==start+1);
    CHECK(records[start].kind==3 && std::memcmp(records[start].bits,base_bits,16)==0);
    CHECK(end_current()==1 && actual_calls==start+1 && identity(policy.rotation));
    pass("fresh branch5 quaternion left-composes once without feedback and End restores exactly once");
    f.begin_at(124000);f.sole();fixture_now=124150;
    CHECK(NADSE_SetTransform(fixture_generation,0,0,0,sx,0,0,cx)==1);start=actual_calls;
    f.branch(f.c.viewmodel,0,base_q);f.branch(f.c.viewmodel,50,base_q);f.branch(f.c.viewmodel+2,5,base_q);
    f.calls[1](f.c.viewmodel,0,base_q);
    for(uint64_t i=start;i<actual_calls;++i)exact(i,records[i].unit,records[i].node,base_q,base_bits);
    CHECK(read_current(&stats)==1 && stats.weapon_updates==0 && end_current()==1);
    pass("carrier root, camera sibling, foreign units and queued root rotation remain pointer-and-bit exact");
    f.begin_at(126000);fixture_now=126150;
    CHECK(NADSE_SetTransform(fixture_generation,0,0,0,sx,0,0,cx)==1);start=actual_calls;
    f.branch(f.c.viewmodel,5,base_q);exact(start,f.c.viewmodel,5,base_q,base_bits);
    f.sole();put<float>(f.c.request+0x98,.1f);f.branch(f.c.viewmodel,5,base_q);
    exact(start+1,f.c.viewmodel,5,base_q,base_bits);
    put<float>(f.c.request+0x98,NAN);f.branch(f.c.viewmodel,5,base_q);
    exact(start+2,f.c.viewmodel,5,base_q,base_bits);
    put<float>(f.c.request+0x98,0);f.branch(f.c.viewmodel,5,base_q);
    CHECK(approximately(component(0),sx*h) && armed.load()==1 && end_current()==1);
    pass("multi-record camera blends and nonzero or nonfinite sight coupling stay native exact");
    f.begin_at(128000);f.sole();fixture_now=128150;
    CHECK(NADSE_SetTransform(fixture_generation,0,0,0,sx,0,0,cx)==1);f.branch(f.c.viewmodel,5,base_q);
    f.shoulder(true);f.branch(f.c.viewmodel,5,base_q);
    CHECK(approximately(component(0),sx*h)); // Shoulder return is supplied smoothly by Lua.
    put<uint8_t>(f.controller+4,1);start=actual_calls;f.branch(f.c.viewmodel,5,base_q);
    exact(start,f.c.viewmodel,5,base_q,base_bits);CHECK(!policy.rotation_shifted && armed.load()==1);
    put<uint8_t>(f.controller+4,0);
    CHECK(NADSE_SetTransform(fixture_generation,0,0,0,0,0,0,1)==1);f.branch(f.c.viewmodel,5,base_q);
    exact(start+1,f.c.viewmodel,5,base_q,base_bits);CHECK(end_current()==1);
    pass("shoulder permits a bounded smooth return while actual full ADS and identity forward exact native quaternion");
    f.begin_at(130000);f.sole();fixture_now=130150;
    CHECK(NADSE_SetTransform(fixture_generation,.01f,.02f,.03f,sx,0,0,cx)==1);
    CHECK(NADSE_SetTransform(fixture_generation,.1f,.1f,.1f,1,0,0,0)==0 && NADSE_Error()==INVALID_CONFIG);
    CHECK(approximately(policy.motion[0],.01f) && approximately(policy.rotation[0],sx));
    CHECK(NADSE_SetTransform(fixture_generation,.1f,.1f,.1f,NAN,0,0,1)==0);
    CHECK(NADSE_SetTransform(fixture_generation,.1f,.1f,.1f,0,0,0,.5f)==0);
    CHECK(NADSE_SetTransform(fixture_generation,.151f,0,0,0,0,0,1)==0);
    CHECK(NADSE_SetTransform(fixture_generation-1,0,0,0,0,0,0,1)==0 && NADSE_Error()==TOKEN_MISMATCH);
    CHECK(NADSE_SetMotion(fixture_generation,-.01f,-.02f,-.03f)==1 && approximately(policy.rotation[0],sx));
    CHECK(policy.deadline==131000 && policy.c.offset_x==.15f && end_current()==1);
    pass("atomic transform rejects bad angle, quaternion, displacement and token without partial updates or deadline extension");
    f.begin_at(132000);f.sole();fixture_now=132150;
    CHECK(NADSE_SetTransform(fixture_generation,0,0,0,sx,0,0,cx)==1);f.branch(f.c.viewmodel,5,base_q);
    start=actual_calls;branch_rotation_call(0,f.c.viewmodel,5,base_q);
    CHECK(!policy.rotation_shifted && end_current()==1 && actual_calls==start+1);
    f.begin_at(134000);f.sole();fixture_now=134150;
    CHECK(NADSE_SetTransform(fixture_generation,0,0,0,sx,0,0,cx)==1);f.branch(f.c.viewmodel,5,base_q);
    put<uint32_t>(f.links+50*4,0x50001);start=actual_calls;
    CHECK(end_current()==1 && actual_calls==start);put<uint32_t>(f.links+50*4,0x40001);
    pass("a foreign branch writer supersedes restoration and changed graph never receives a cached rotation");
    f.begin_at(136000);f.sole();fixture_now=136150;
    CHECK(NADSE_SetTransform(fixture_generation,0,0,0,sx,0,0,cx)==1);f.branch(f.c.viewmodel,5,base_q);
    start=actual_calls;fixture_slot_unreadable=true;CHECK(end_current()==0 && actual_calls==start);
    fixture_slot_unreadable=false;CHECK(end_current()==1 && actual_calls==start);
    f.begin_at(138000);f.sole();fixture_now=138150;
    CHECK(NADSE_SetTransform(fixture_generation,0,0,0,sx,0,0,cx)==1);f.branch(f.c.viewmodel,5,base_q);
    const uint64_t foreign_rotation=UINT64_C(0x1234567890);put<uint64_t>(f.api+0x40,foreign_rotation);
    start=actual_calls;CHECK(end_current()==1 && actual_calls==start);uint64_t kept=0;CHECK(value(f.api+0x40,kept) && kept==foreign_rotation);
    put<uint64_t>(f.api+0x40,reinterpret_cast<uint64_t>(synthetic_branch_rotation));
    pass("unreadable or foreign dispatch prevents stale rotation replay and a foreign callback replacement is preserved");
    f.begin_at(140000);f.sole();fixture_now=140150;
    CHECK(NADSE_SetTransform(fixture_generation,.01f,.02f,.03f,sx,0,0,cx)==1);f.match();f.branch(f.c.viewmodel,5,base_q);
    start=actual_calls;fixture_now=141000;CHECK(read_current(&stats)==1 && stats.expired==1 && stats.armed==0);
    CHECK(actual_calls==start+2 && records[start].kind==1 && records[start+1].kind==3);
    CHECK(std::memcmp(records[start+1].bits,base_bits,16)==0 && end_current()==1 && actual_calls==start+2);
    pass("TTL restores translation and fresh native branch rotation independently without renewing lifetime");
    f.normal();fixture_cas_calls=0;put<uint8_t>(f.c.game+0x12890DB,0x90);
    CHECK(NADSE_Validate(&f.c)==0 && NADSE_Error()==CODE_MISMATCH && fixture_cas_calls==0);
    put<uint8_t>(f.c.game+0x12890DB,0x41);put<uint8_t>(f.c.exe+0x1FC7A0,0x90);
    CHECK(NADSE_Validate(&f.c)==0 && NADSE_Error()==CODE_MISMATCH && fixture_cas_calls==0);
    put<uint8_t>(f.c.exe+0x1FC7A0,0x48);CHECK(NADSE_Validate(&f.c)==1);
    fixture_cas_fail_at=3;CHECK(begin_current(&f.c)==0 && reserved.load()==0);
    CHECK(value(f.api+0x38,kept) && kept==reinterpret_cast<uint64_t>(synthetic_position));
    CHECK(value(f.api+0x48,kept) && kept==reinterpret_cast<uint64_t>(synthetic_rotation));
    CHECK(value(f.api+0x40,kept) && kept==reinterpret_cast<uint64_t>(synthetic_branch_rotation));
    fixture_cas_calls=0;fixture_fail_rollback=true;CHECK(begin_current(&f.c)==2 && reserved.load()==1 && armed.load()==0);
    fixture_cas_fail_at=0;fixture_fail_rollback=false;CHECK(end_current()==1);
    pass("new immediate-rotation wrapper and callsite fail closed; third-slot partial Begin retains cleanup ownership");
    f.begin_at(142000);f.sole();fixture_now=142150;
    CHECK(NADSE_SetTransform(fixture_generation,0,0,0,sx,0,0,cx)==1);
    setter_reached=CreateEventW(nullptr,TRUE,FALSE,nullptr);setter_continue=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    CHECK(setter_reached && setter_continue);ended.store(0);start=actual_calls;
    std::thread rotation_thread([&]{f.branch(f.c.viewmodel,5,base_q);});
    CHECK(WaitForSingleObject(setter_reached,3000)==WAIT_OBJECT_0);
    std::thread rotation_end([&]{CHECK(end_current()==1);ended.store(1);});
    while(armed.load(std::memory_order_acquire))SwitchToThread();CHECK(ended.load()==0);
    SetEvent(setter_continue);rotation_thread.join();rotation_end.join();CloseHandle(setter_reached);CloseHandle(setter_continue);
    setter_reached=nullptr;setter_continue=nullptr;
    CHECK(ended.load()==1 && actual_calls==start+2 && std::memcmp(records[start+1].bits,base_bits,16)==0);
    pass("End drains the in-flight branch rotation before a single native quaternion restore and pointer cleanup");
    f.begin_at(144000);f.sole();fixture_now=144150;
    fixture_reads=0;f.match();const uint64_t position_reads=fixture_reads;
    fixture_reads=0;f.branch(f.c.viewmodel,5,base_q);const uint64_t idle_rotation_reads=fixture_reads;
    fixture_reads=0;CHECK(NADSE_SetTransform(fixture_generation,0,0,0,0,0,0,1)==1);
    const uint64_t transform_reads=fixture_reads;
    CHECK(position_reads==42 && idle_rotation_reads==0 && transform_reads==41);
    CHECK(NADSE_SetTransform(fixture_generation,0,0,0,sx,0,0,cx)==1);
    fixture_reads=0;f.branch(f.c.viewmodel,5,base_q);CHECK(fixture_reads==44 && policy.rotation_shifted);
    CHECK(NADSE_SetTransform(fixture_generation,0,0,0,0,0,0,1)==1);
    fixture_reads=0;start=actual_calls;f.branch(f.c.viewmodel,5,base_q);
    CHECK(fixture_reads==43 && !policy.rotation_shifted);exact(start,f.c.viewmodel,5,base_q,base_bits);
    fixture_reads=0;f.branch(f.c.viewmodel,5,base_q);CHECK(fixture_reads==0);
    CHECK(end_current()==1);
    std::printf("PERF read_calls position=%llu identity_rotation=%llu transform=%llu\n",
        static_cast<unsigned long long>(position_reads),static_cast<unsigned long long>(idle_rotation_reads),
        static_cast<unsigned long long>(transform_reads));
    pass("batched graph preserves all mutation guards; settled identity has zero memory reads after one guarded native return");
    f.begin_at(146000);f.sole();fixture_now=146150;start=actual_calls;
    put<uint32_t>(f.hashes+50*4,0);fixture_reads=0;f.branch(f.c.viewmodel,5,base_q);
    CHECK(fixture_reads==0 && armed.load()==1);exact(start,f.c.viewmodel,5,base_q,base_bits);
    CHECK(NADSE_SetTransform(fixture_generation,0,0,0,sx,0,0,cx)==0 && NADSE_Error()==GRAPH_MISMATCH);
    CHECK(armed.load()==0 && end_current()==1 && actual_calls==start+1);
    put<uint32_t>(f.hashes+50*4,0x60ED8C39);
    pass("identity forwards native input without validation, while the next attempted mutation still rejects changed graph");
    DepthFixture depth(f);depth.begin(200000);f.match();
    CHECK(policy.depth.valid && policy.depth.observed.supported && policy.depth.observed.applied==0);
    const float fixed=DepthFixture::distance(0);
    depth.event(1);
    for(float t:{1.0f,.75f,.25f,0.0f}) {
        fixture_now+=16;depth.frame_at(t,1.5f+t,-4-t);uint8_t source[16]{};std::memcpy(source,f.source(),16);f.match();
        CHECK(approximately(component(0),1.5f+t) && approximately(component(1),2+fixed) && approximately(component(2),-4-t));
        CHECK(records[actual_calls-1].bits[3]==0x7FC12345 && std::memcmp(source,f.source(),16)==0);
    }
    depth.event(2);
    for(float t:{1.0f,.5f,0.0f}) {fixture_now+=16;depth.frame_at(t);f.match();CHECK(approximately(component(1),2+fixed));}
    CHECK(policy.depth.observed.zoom_index==2 && policy.depth.observed.applied>0 && approximately(policy.depth.observed.zoom,3.5f));
    pass("normal optic zoom0/1/2 stays at the authored reference through the exact native distance interpolation");
    depth.event(1);fixture_now+=16;depth.frame_at(.6f);f.match();depth.event(2);
    for(float t:{1.0f,.4f,0.0f}) {fixture_now+=16;depth.frame_at(t);f.match();CHECK(approximately(component(1),2+fixed));}
    pass("rapid zoom changes use proven previous-distance references instead of guessing from an intermediate lens");
    f.shoulder(true);fixture_now+=16;depth.frame_at(0);f.match();fixture_now+=150;depth.frame_at(0);f.match();
    CHECK(approximately(policy.target,1.0f) && approximately(component(1),2+fixed));
    pass("normal shoulder aim retains the same hip depth reference independently of the saved offset weight");
    put<uint8_t>(f.controller+4,1);depth.frame_at(0);start=actual_calls;f.match();
    exact(start,f.c.viewmodel,5,f.source(),f.source());CHECK(policy.depth.observed.reason==1 && policy.depth.observed.ads_bypassed==1);
    put<uint8_t>(f.controller+4,0);fixture_now+=16;depth.frame_at(0);f.match();CHECK(approximately(component(1),2+fixed));
    NADSE_DepthStats observed{};observed.size=sizeof observed;observed.abi=1;
    CHECK(NADSE_ReadDepthStats(fixture_generation,&observed)==1 && observed.supported==1 && observed.applied>0);
    CHECK(NADSE_ReadDepthStats(0,&observed)==0 && NADSE_ReadDepthStats(fixture_generation-1,&observed)==0);
    observed.size=80;CHECK(NADSE_ReadDepthStats(fixture_generation,&observed)==0);observed.size=sizeof observed;
    const uint64_t final_restore=actual_calls;depth.end();CHECK(actual_calls==final_restore+1);
    exact(final_restore,f.c.viewmodel,5,records[final_restore].pointer,f.source());
    CHECK(NADSE_ReadDepthStats(0,&observed)==1 && observed.armed==0 && observed.applied>0);
    pass("full ADS bypasses depth immediately; release resumes the reference; generation-owned diagnostics and End remain exact");
    depth.begin(202000);f.match();depth.event(2);depth.frame_at(0);f.match();
    put<uint8_t>(f.c.request+0x8D,1);put<float>(f.c.request+0x88,.25f);depth.frame_at(0);f.match();
    CHECK(approximately(component(1),2+fixed*.25f) && approximately(policy.depth.observed.gain,.25f));
    for(unsigned mode=0;mode<4;++mode) {
        put<uint8_t>(f.c.request+0x8D,0);put<uint8_t>(f.c.request+0x8F,0);put<float>(f.c.request+0x98,0);put<uint8_t>(depth.frame+0x44,0);
        if(mode==0)put<uint8_t>(f.c.request+0x8F,1);
        if(mode==1)put<float>(f.c.request+0x98,.1f);
        if(mode==2)put<uint8_t>(depth.frame+0x44,1);
        if(mode==3)put<uint8_t>(f.c.request+0x8D,2);
        depth.frame_at(0);start=actual_calls;f.match();exact(start,f.c.viewmodel,5,f.source(),f.source());
        CHECK(armed.load()==1 && policy.depth.observed.reason==4);
    }
    depth.end();pass("normal entry blend has the proven gain; alternate optic, special, malformed and coupled modes stay native");
    depth.begin(204000);f.match();depth.event(1);depth.frame_at(0);f.match();
    const uint64_t refreshes=policy.depth.refreshes;fixture_reads=0;
    for(unsigned i=0;i<100;++i) {++fixture_now;depth.frame_at(0);f.match();}
    const uint64_t depth_steady_reads=fixture_reads;
    // frame_at itself makes four fixture observation reads per sample.
    CHECK(policy.depth.refreshes==refreshes && policy.depth.checks==0 && depth_steady_reads==100*(45+4));
    std::printf("PERF depth steady getter+setter reads=45 (four beyond22), metadata_refreshes=%llu\n",static_cast<unsigned long long>(refreshes));
    fixture_now=204600;depth.frame_at(0);f.match();CHECK(policy.depth.checks==1 && policy.depth.refreshes==refreshes);
    CHECK(approximately(component(1),2+fixed));
    put<float>(depth.table+0x2DA0+0x140,.7f);fixture_now=205100;depth.frame_at(0);start=actual_calls;f.match();
    exact(start,f.c.viewmodel,5,f.source(),f.source());CHECK(policy.depth.observed.reason==9 && !policy.depth.valid);
    depth.frame_at(0);f.match();CHECK(policy.depth.refreshes==refreshes);
    put<float>(depth.table+0x2DA0+0x140,.6f);depth.end();
    pass("unchanged depth has no registry scans or tangent calls; two-Hz metadata validation rejects a changed definition without stale reuse");
    depth.begin(206000);f.match();depth.event(2);depth.frame_at(0);f.match();
    CHECK(policy.depth.data.resource_row!=0);
    put<uint64_t>(depth.overrides+(f.c.weapon%8)*8,f.c.weapon);fixture_now=206600;depth.frame_at(0);f.match();
    CHECK(!policy.depth.valid && policy.depth.observed.reason==9);
    depth.event(1);depth.frame_at(0);f.match();CHECK(policy.depth.data.resource_row==0 && policy.depth.data.data==depth.data);
    depth.end();put<uint64_t>(depth.overrides+(f.c.weapon%8)*8,UINT32_MAX);
    pass("an entity override appearing after resource lookup invalidates the cache; the next native event resolves the new source");
    depth.begin(208000);fixture_depth_mutation=f.gens+3;fixture_depth_mutation_byte=2;
    depth.frame_at(0);start=actual_calls;f.match();fixture_depth_mutation=0;
    exact(start,f.c.viewmodel,5,f.source(),f.source());CHECK(armed.load()==0 && NADSE_Error()==OWNER_MISMATCH);
    depth.end();put<uint8_t>(f.gens+3,1);
    depth.begin(210000);fixture_depth_mutation=f.hashes+50*4;fixture_depth_mutation_byte=0;
    depth.frame_at(0);start=actual_calls;f.match();fixture_depth_mutation=0;
    exact(start,f.c.viewmodel,5,f.source(),f.source());CHECK(armed.load()==0 && NADSE_Error()==GRAPH_MISMATCH);
    depth.end();put<uint8_t>(f.hashes+50*4,0x39);
    pass("ownership and graph changes during metadata capture are rechecked before any corrected pose can reach the native setter");
    depth.begin(212000);put<uint8_t>(f.c.game+0x12873B3,0x90);depth.frame_at(0);start=actual_calls;f.match();
    exact(start,f.c.viewmodel,5,f.source(),f.source());CHECK(policy.depth.observed.reason==2 && armed.load()==1);depth.end();
    put<uint8_t>(f.c.game+0x12873B3,0xF3);
    pass("unproven native caller-frame layout leaves depth untouched without refusing the existing FPV lease");
    depth.begin(214000);f.match();depth.event(2);depth.frame_at(0);
    fixture_reads=0;const uint64_t original_getters=getter_calls;
    const float* unchanged=position_getter_hook(f.c.viewmodel+1,37);
    CHECK(unchanged==getter_result && getter_calls==original_getters+1 && getter_unit==f.c.viewmodel+1 && getter_node==37
        && fixture_reads==0 && policy.observation.ready);
    f.match();CHECK(approximately(component(1),2+fixed));
    for(unsigned mismatch=0;mismatch<5;++mismatch) {
        depth.frame_at(0);
        if(mismatch==0)policy.observation.native_stack+=8;
        if(mismatch==1)++policy.observation.thread;
        if(mismatch==2) {float old=0;CHECK(value(f.c.request+0x90,old));put<float>(f.c.request+0x90,old+.01f);}
        if(mismatch==3)CHECK(f.getter(f.c.viewmodel+1,50)==getter_result);
        if(mismatch==4) {
            float fading[4]={1,2,3,4};f.rig(f.c.viewmodel,5,fading);CHECK(!policy.observation.ready);
        }
        start=actual_calls;f.match();exact(start,f.c.viewmodel,5,f.source(),f.source());CHECK(!policy.observation.ready);
        if(mismatch==2)put<float>(f.c.request+0x90,DepthFixture::distance(2));
    }
    put<uint8_t>(f.c.request+0x8D,1);put<float>(f.c.request+0x88,.25f);depth.frame_at(0);
    put<float>(f.c.request+0x88,.5f);f.pose(1.25f,2+DepthFixture::distance(2)*.5f,-3.5f,0x7FC12345);f.match();
    CHECK(approximately(component(1),2+fixed*.5f) && approximately(policy.depth.observed.gain,.5f));
    depth.end();
    pass("getter forwards unrelated calls without reads; capture is invocation/thread/request matched and consumed once, while88 may advance natively");
    f.normal();fixture_cas_calls=0;fixture_cas_fail_at=4;fixture_fail_rollback=true;
    CHECK(begin_current(&f.c)==2 && reserved.load()==1 && armed.load()==0);
    CHECK(value(f.api,kept) && kept==reinterpret_cast<uint64_t>(synthetic_getter));
    fixture_cas_fail_at=0;fixture_fail_rollback=false;CHECK(end_current()==1);
    depth.begin(216000);f.match();depth.event(2);depth.frame_at(0);f.match();start=actual_calls;
    fixture_unreadable_slot=f.api;CHECK(end_current()==0 && reserved.load()==1 && actual_calls==start);
    fixture_unreadable_slot=0;CHECK(end_current()==1 && actual_calls==start);
    CHECK(value(f.api,kept) && kept==reinterpret_cast<uint64_t>(synthetic_getter));fixture_depth_frame=0;
    pass("fourth-slot partial Begin and unreadable getter cleanup preserve the generation and never replay an unverified depth baseline");
    depth.begin(218000);f.match();depth.event(2);depth.frame_at(0);f.match();start=actual_calls;
    put<uint64_t>(f.api,foreign_rotation);depth.end();CHECK(actual_calls==start);
    CHECK(value(f.api,kept) && kept==foreign_rotation);put<uint64_t>(f.api,reinterpret_cast<uint64_t>(synthetic_getter));
    pass("a foreign getter replacement is preserved and prevents stale corrected-pose restoration");
    depth.begin(220000);f.match();depth.event(2);depth.frame_at(0);f.match();
    getter_reached=CreateEventW(nullptr,TRUE,FALSE,nullptr);getter_continue=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    CHECK(getter_reached && getter_continue);ended.store(0);
    std::thread getter_thread([&]{depth.frame_at(0);});
    CHECK(WaitForSingleObject(getter_reached,3000)==WAIT_OBJECT_0);
    std::thread getter_end([&]{CHECK(end_current()==1);ended.store(1);});
    while(armed.load(std::memory_order_acquire))SwitchToThread();CHECK(ended.load()==0);
    SetEvent(getter_continue);getter_thread.join();getter_end.join();
    CloseHandle(getter_reached);CloseHandle(getter_continue);getter_reached=nullptr;getter_continue=nullptr;
    CHECK(ended.load()==1 && !policy.observation.ready);fixture_depth_frame=0;
    CHECK(value(f.api,kept) && kept==reinterpret_cast<uint64_t>(synthetic_getter));
    pass("End drains the owned getter invocation before restoring all four dispatch pointers; a late capture cannot survive shutdown");
    const float root_identity[4]={0,0,0,1};
    depth.begin(230000);f.match();fixture_reads=0;start=actual_calls;
    depth.root(DepthFixture::distance(0),root_identity);
    CHECK(fixture_reads==0 && !policy.carrier_shifted);exact(start,f.c.viewmodel,0,depth.root_source(),depth.root_source());
    depth.event(1);float effective=depth.frame_at(0);f.match();
    fixture_reads=0;depth.root(effective,root_identity);const uint64_t root_reads_first=fixture_reads;
    CHECK(policy.carrier_shifted && approximately(component(0),10) && approximately(component(1),20-fixed)
        && approximately(component(2),30) && records[actual_calls-1].bits[3]==0x7FC54321);
    effective=depth.frame_at(0);f.match();fixture_reads=0;depth.root(effective,root_identity);
    const uint64_t root_reads_steady=fixture_reads;CHECK(root_reads_steady+3==root_reads_first);
    CHECK(policy.carrier_shifted && approximately(component(1),20-fixed));depth.end();
    std::printf("PERF carrier root reads first=%llu steady=%llu; zero correction=0\n",
        static_cast<unsigned long long>(root_reads_first),static_cast<unsigned long long>(root_reads_steady));
    pass("paired carrier cancels zoom depth in copied native root XYZ; reference zoom forwards with zero reads and W stays exact");

    depth.begin(232000);f.match();
    for(unsigned zoom:{1U,2U,0U}) {
        depth.event(zoom);
        for(float progress:{1.0f,.5f,0.0f}) {
            fixture_now+=16;effective=depth.frame_at(progress);f.match();
            // Change the native root orientation AFTER the earlier getter and
            // node5 setter. The carrier must use this final solve, not a basis
            // cached by Lua or an earlier iteration of the native evaluator.
            const float yaw=.4f+progress*.3f,pitch=-.2f;
            const float q[4]={std::cos(yaw*.5f)*std::sin(pitch*.5f),std::sin(yaw*.5f)*std::sin(pitch*.5f),
                std::sin(yaw*.5f)*std::cos(pitch*.5f),std::cos(yaw*.5f)*std::cos(pitch*.5f)};
            const float forward[3]={2*(q[0]*q[1]-q[2]*q[3]),q[3]*q[3]+q[1]*q[1]-q[0]*q[0]-q[2]*q[2],2*(q[1]*q[2]+q[0]*q[3])};
            depth.root(effective,q,10+progress,20-progress,30+progress*.5f);
            CHECK(approximately(component(0),10+progress-fixed*forward[0])
                && approximately(component(1),20-progress-fixed*forward[1])
                && approximately(component(2),30+progress*.5f-fixed*forward[2]));
        }
    }
    depth.end();pass("zoom transitions and fresh yaw/pitch/root travel keep the same direct camera-depth reference without accumulated feedback");

    depth.begin(234000);f.match();depth.event(2);effective=depth.frame_at(0);f.match();
    f.shoulder(true);depth.root(effective,root_identity);CHECK(approximately(component(1),20-fixed));
    effective=depth.frame_at(0);f.match();CHECK(policy.carrier.ready);put<uint8_t>(f.controller+4,1);
    start=actual_calls;depth.root(effective,root_identity);exact(start,f.c.viewmodel,0,depth.root_source(),depth.root_source());
    CHECK(!policy.carrier.ready && !policy.carrier_shifted);
    depth.frame_at(0);f.match();start=actual_calls;depth.root(effective,root_identity);
    exact(start,f.c.viewmodel,0,depth.root_source(),depth.root_source());
    put<uint8_t>(f.controller+4,0);effective=depth.frame_at(0);f.match();depth.root(effective,root_identity);
    CHECK(approximately(component(1),20-fixed));depth.end();
    pass("shoulder shares the reference; full ADS wins even between paired calls and release resumes native-reference compensation");

    depth.begin(236000);f.match();depth.event(2);
    for(unsigned mismatch=0;mismatch<8;++mismatch) {
        effective=depth.frame_at(0);f.match();CHECK(policy.carrier.ready);
        if(mismatch==0)policy.carrier.observation.native_stack+=8;
        if(mismatch==1)++policy.carrier.observation.thread;
        if(mismatch==2)++policy.carrier.observation.generation;
        if(mismatch==3)policy.carrier.observation.request+=0xE8;
        if(mismatch==4)put<float>(f.c.request+0x90,DepthFixture::distance(2)+.01f);
        if(mismatch==5)policy.carrier.observation.request_state[0xD]=1;
        if(mismatch==6) {start=actual_calls;f.calls[0](f.c.viewmodel,0,f.source());exact(start,f.c.viewmodel,0,f.source(),f.source());}
        if(mismatch==7) {start=actual_calls;f.calls[0](f.c.viewmodel+2,0,f.source());exact(start,f.c.viewmodel+2,0,f.source(),f.source());}
        start=actual_calls;depth.root(effective,root_identity);exact(start,f.c.viewmodel,0,depth.root_source(),depth.root_source());
        CHECK(!policy.carrier.ready && !policy.carrier_shifted && armed.load()==1);
        put<float>(f.c.request+0x90,DepthFixture::distance(2));
    }
    depth.end();pass("carrier pairing consumes once and rejects wrong invocation/thread/generation/request/source/unit without stale reuse");

    depth.begin(238000);f.match();depth.event(1);effective=depth.frame_at(0);f.match();
    put<uint32_t>(f.c.context+0x1F8,0);start=actual_calls;depth.root(effective,root_identity);
    exact(start,f.c.viewmodel,0,depth.root_source(),depth.root_source());put<uint32_t>(f.c.context+0x1F8,1);
    for(unsigned bad=0;bad<3;++bad) {
        effective=depth.frame_at(0);f.match();float q[4]={0,0,0,1};
        if(bad==0)q[3]=2;
        if(bad==1)q[0]=NAN;
        start=actual_calls;depth.root(effective,q,bad==2?NAN:10);
        exact(start,f.c.viewmodel,0,depth.root_source(),depth.root_source());CHECK(armed.load()==1 && !policy.carrier_shifted);
    }
    depth.end();
    depth.begin(238500);f.match();depth.event(1);effective=depth.frame_at(0);f.match();
    put<uint8_t>(f.c.game+0x1286335,0x90);start=actual_calls;depth.root(effective,root_identity);
    exact(start,f.c.viewmodel,0,depth.root_source(),depth.root_source());CHECK(armed.load()==1 && !policy.carrier_shifted);
    depth.end();put<uint8_t>(f.c.game+0x1286335,0x55);
    pass("fading ring entries, invalid final poses and unproven stack layout leave the native carrier untouched");

    for(unsigned race=0;race<3;++race) {
        depth.begin(240000+race*1000);f.match();depth.event(2);effective=depth.frame_at(0);f.match();
        if(race==0)put<uint8_t>(f.gens+3,2);
        if(race==1)put<uint32_t>(f.hashes+50*4,0);
        if(race==2)put<uint64_t>(f.api,foreign_rotation);
        start=actual_calls;depth.root(effective,root_identity);exact(start,f.c.viewmodel,0,depth.root_source(),depth.root_source());
        CHECK(armed.load()==0 && !policy.carrier_shifted && !policy.carrier.ready);const uint64_t after_race=actual_calls;
        depth.end();CHECK(actual_calls==after_race);
        if(race==0)put<uint8_t>(f.gens+3,1);
        if(race==1)put<uint32_t>(f.hashes+50*4,0x60ED8C39);
        if(race==2)put<uint64_t>(f.api,reinterpret_cast<uint64_t>(synthetic_getter));
    }
    pass("ownership generation, graph and dispatch races between node5 and carrier forward native and prohibit stale restoration");

    depth.begin(244000);f.match();depth.event(2);effective=depth.frame_at(0);f.match();depth.root(effective,root_identity);depth.settle_root();
    float root_baseline[4]{};std::memcpy(root_baseline,depth.root_source(),16);start=actual_calls;depth.end();
    CHECK(actual_calls==start+2);exact(start+1,f.c.viewmodel,0,records[start+1].pointer,root_baseline);
    pass("End restores the original carrier baseline only after exact live XYZ and pose-array ownership agree");

    for(unsigned replacement=0;replacement<4;++replacement) {
        depth.begin(246000+replacement*1000);f.match();depth.event(2);effective=depth.frame_at(0);f.match();depth.root(effective,root_identity);
        if(replacement==0)put<float>(f.poses+0x24,999); // This queued write has not reached the live matrix.
        if(replacement!=0)depth.settle_root();
        if(replacement==1)put<float>(f.poses+0x24,999);
        if(replacement==2)put<uint64_t>(f.object+0x80,f.poses+0x100);
        if(replacement==3) {
            position_call(0,f.c.viewmodel,0,depth.root_source());CHECK(!policy.carrier_shifted);
        }
        start=actual_calls;depth.end();CHECK(actual_calls==start+1);
        put<uint64_t>(f.object+0x80,f.poses);
    }
    pass("unsettled queued writes, foreign live XYZ, replaced pose arrays and other root writers never receive a cached carrier replay");

    depth.begin(251000);f.match();depth.event(1);effective=depth.frame_at(0);f.match();
    setter_reached=CreateEventW(nullptr,TRUE,FALSE,nullptr);setter_continue=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    CHECK(setter_reached && setter_continue);ended.store(0);
    std::thread root_thread([&]{depth.root(effective,root_identity);});CHECK(WaitForSingleObject(setter_reached,3000)==WAIT_OBJECT_0);
    std::thread root_end([&]{CHECK(end_current()==1);ended.store(1);});
    while(armed.load(std::memory_order_acquire))SwitchToThread();CHECK(ended.load()==0);
    SetEvent(setter_continue);root_thread.join();root_end.join();
    CloseHandle(setter_reached);CloseHandle(setter_continue);setter_reached=nullptr;setter_continue=nullptr;
    CHECK(ended.load()==1 && !policy.carrier.ready && !policy.carrier_shifted);fixture_depth_frame=0;
    pass("End drains the paired carrier setter before releasing its reservation and clears pending work");
    f.c.duration_ms=0;f.c.offset_x=.15f;f.c.offset_z=-.12f;f.begin_at(300000);fixture_now=300050;f.match();
    CHECK(read_current(&stats)==1);const NADSE_Stats display_before=stats;
    setter_reached=CreateEventW(nullptr,TRUE,FALSE,nullptr);setter_continue=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    HANDLE stats_done=CreateEventW(nullptr,TRUE,FALSE,nullptr);CHECK(setter_reached && setter_continue && stats_done);
    fixture_now=300150;std::thread stats_writer([&]{f.match();});CHECK(WaitForSingleObject(setter_reached,3000)==WAIT_OBJECT_0);
    armed.store(0,std::memory_order_release);error(OWNER_MISMATCH);
    NADSE_Stats concurrent{};concurrent.size=sizeof concurrent;concurrent.abi=2;uint32_t stats_result=0;
    std::thread stats_reader([&]{stats_result=NADSE_ReadStats(fixture_generation,&concurrent);SetEvent(stats_done);});
    CHECK(WaitForSingleObject(stats_done,1000)==WAIT_OBJECT_0);
    CHECK(stats_result==1 && concurrent.installed==1 && concurrent.armed==0 && concurrent.error==OWNER_MISMATCH
        && concurrent.blend==display_before.blend && concurrent.target_weight==display_before.target_weight);
    NADSE_Stats invalid_stats{};invalid_stats.size=sizeof invalid_stats;invalid_stats.abi=2;
    CHECK(NADSE_ReadStats(fixture_generation+1,&invalid_stats)==0 && NADSE_Error()==TOKEN_MISMATCH);
    invalid_stats.abi=1;CHECK(NADSE_ReadStats(fixture_generation,&invalid_stats)==0 && NADSE_Error()==INVALID_CONFIG);
    invalid_stats.abi=2;invalid_stats.size=sizeof invalid_stats-4;CHECK(NADSE_ReadStats(fixture_generation,&invalid_stats)==0);
    CHECK(NADSE_ReadStats(fixture_generation,reinterpret_cast<NADSE_Stats*>(1))==0);
    SetEvent(setter_continue);stats_writer.join();stats_reader.join();
    CloseHandle(setter_reached);CloseHandle(setter_continue);CloseHandle(stats_done);setter_reached=nullptr;setter_continue=nullptr;
    CHECK(read_current(&stats)==1 && stats.blend==1 && stats.target_weight==1 && stats.armed==0);
    CHECK(end_current()==1);pass("manual ReadStats completes during blocked setter with fresh health and only completed diagnostics; token ABI pointer guards stay live");

    f.begin_at(302000);fixture_now=302075;f.match();CHECK(read_current(&stats)==1);const NADSE_Stats completed_display=stats;
    display_sequence.fetch_add(1,std::memory_order_seq_cst);display_blend.store(.99f,std::memory_order_seq_cst);
    CHECK(read_current(&stats)==1 && stats.blend==completed_display.blend && stats.target_weight==completed_display.target_weight);
    display_blend.store(policy.weight,std::memory_order_seq_cst);display_sequence.fetch_add(1,std::memory_order_seq_cst);
    const uint64_t old_display_generation=fixture_generation;CHECK(end_current()==1);f.begin_at(304000);
    CHECK(read_current(&stats)==1 && stats.blend==0 && stats.target_weight==1);
    CHECK(NADSE_ReadStats(old_display_generation,&stats)==0 && NADSE_Error()==TOKEN_MISMATCH);
    uint64_t busy_stats=UINT64_MAX;CHECK(NADSE_Begin(&f.c,&busy_stats)==0 && busy_stats==0);
    CHECK(read_current(&stats)==1 && stats.blend==0 && stats.target_weight==1 && stats.error==BUSY);
    CHECK(end_current()==1);pass("odd pose publication returns complete cache; new generation resets display and BUSY cannot replace it");

    f.c.duration_ms=1000;f.begin_at(306000);fixture_now=306050;f.match();CHECK(read_current(&stats)==1);
    setter_reached=CreateEventW(nullptr,TRUE,FALSE,nullptr);setter_continue=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    stats_done=CreateEventW(nullptr,TRUE,FALSE,nullptr);CHECK(setter_reached && setter_continue && stats_done);
    fixture_now=306150;std::thread timed_writer([&]{f.match();});CHECK(WaitForSingleObject(setter_reached,3000)==WAIT_OBJECT_0);
    std::thread timed_reader([&]{stats_result=NADSE_ReadStats(fixture_generation,&concurrent);SetEvent(stats_done);});
    CHECK(WaitForSingleObject(stats_done,1000)==WAIT_OBJECT_0);timed_reader.join();
    CHECK(stats_result==1 && concurrent.armed==1 && concurrent.expired==0 && stats_deadline==307000);
    ResetEvent(stats_done);fixture_now=307000;
    std::thread expiry_reader([&]{stats_result=NADSE_ReadStats(fixture_generation,&concurrent);SetEvent(stats_done);});
    CHECK(WaitForSingleObject(stats_done,20)==WAIT_TIMEOUT);start=actual_calls;
    SetEvent(setter_continue);timed_writer.join();expiry_reader.join();
    CloseHandle(setter_reached);CloseHandle(setter_continue);CloseHandle(stats_done);setter_reached=nullptr;setter_continue=nullptr;
    CHECK(stats_result==1 && concurrent.armed==0 && concurrent.expired==1 && reserved.load()==1 && actual_calls==start+1);
    CHECK(end_current()==1 && stats_deadline==0);
    pass("timed unexpired stats avoid setter wait; reached deadline still drains and restores before reporting expiry");

    f.c.duration_ms=1000;f.begin_at(310000);fixture_now=310150;f.match();
    CHECK(NADSE_SetADSPlacement(fixture_generation+1,.1f,0,0)==0);
    CHECK(NADSE_SetADSPlacement(fixture_generation,.6f,0,0)==0);
    CHECK(NADSE_SetADSPlacement(fixture_generation,.1f,.02f,-.03f)==1);
    CHECK(policy.ads_placement[0]==.1f && policy.ads_placement[1]==.02f);
    put<uint8_t>(f.controller+4,1);f.match();fixture_now=310300;f.match();
    CHECK(approximately(component(0),f.source()[0]+.1f));
    CHECK(approximately(component(1),f.source()[1]+.02f));
    CHECK(approximately(component(2),f.source()[2]-.03f));
    CHECK(end_current()==1);
    pass("ADS placement export preserves generation, bounds and cleanup guards");
    f.begin_at(312000);f.sole();fixture_now=312150;
    CHECK(NADSE_SetAuthoredTransform(fixture_generation+1,0,0,0,sx,0,0,cx)==0);
    CHECK(NADSE_SetAuthoredTransform(fixture_generation,0,0,0,1,0,0,0)==0);
    CHECK(NADSE_SetAuthoredTransform(fixture_generation,0,0,0,sx,0,0,cx)==1);
    put<uint8_t>(f.controller+4,1);start=actual_calls;f.branch(f.c.viewmodel,5,base_q);
    CHECK(std::memcmp(records[start].bits,base_bits,16)!=0);
    CHECK(NADSE_SetTransform(fixture_generation,0,0,0,sx,0,0,cx)==1);
    start=actual_calls;f.branch(f.c.viewmodel,5,base_q);exact(start,f.c.viewmodel,5,base_q,base_bits);
    CHECK(NADSE_SetAuthoredTransform(fixture_generation,0,0,0,sx,0,0,cx)==1);
    put<float>(f.c.request+0x98,.1f);start=actual_calls;f.branch(f.c.viewmodel,5,base_q);
    exact(start,f.c.viewmodel,5,base_q,base_bits);CHECK(end_current()==1);
    pass("explicit authored ADS rotation stays bounded; ordinary motion and coupled sights remain native");
    f.begin_at(314000);f.sole();fixture_now=314150;
    CHECK(NADSE_SetTransform(fixture_generation,0,0,0,.70710678f,0,0,.70710678f)==1);
    CHECK(NADSE_SetTransform(fixture_generation,0,0,0,.9396926f,0,0,.3420201f)==0);
    CHECK(end_current()==1);pass("90 degree authored rotation accepted; above120 combined rotation still rejects");
    for(uint64_t i=0;i<actual_calls;++i)CHECK(records[i].unit!=f.c.weapon_unit);
    uint8_t after[2][64]{};CHECK(read(reinterpret_cast<uint64_t>(synthetic_position),after[0],64));CHECK(read(reinterpret_cast<uint64_t>(synthetic_rotation),after[1],64));
    CHECK(std::memcmp(before,after,sizeof before)==0);pass("no weapon root writes anywhere; executable bytes unchanged");
    std::printf("Native editor pose fixture PASS: %llu cases\n",static_cast<unsigned long long>(cases));return 0;
}
