// Synthetic local buffers only. No game process or installed files are touched.
#define NADSC_FIXTURE
#include "native_ads_camera.cpp"
#include <cstdio>
#include <cstdlib>
#include <thread>
#define CHECK(x) do{if(!(x)){std::fprintf(stderr,"FAIL %d: %s error=%u\n",__LINE__,#x,NADSC_Error());std::abort();}}while(0)
static uint64_t active_generation=0,cases=0,calls=0,camera_local=0,camera_world=0;
struct Record {void* camera;uint32_t unit,bits[4];const float* input;};static Record records[4096]{};
static HANDLE setter_reached=nullptr,setter_continue=nullptr;
__declspec(noinline) static void synthetic_setter(void* camera,uint32_t unit,const float* point) {
    CHECK(calls<4096);auto& r=records[calls++];r.camera=camera;r.unit=unit;r.input=point;std::memcpy(r.bits,point,16);
    std::memcpy(reinterpret_cast<void*>(camera_local),point,12);std::memcpy(reinterpret_cast<void*>(camera_world),point,12);
    if(setter_reached) {SetEvent(setter_reached);WaitForSingleObject(setter_continue,INFINITE);}
}
__declspec(noinline) static void foreign_setter(void*,uint32_t,const float*) {}
template<class T> static void put(uint64_t at,const T& v) {std::memcpy(reinterpret_cast<void*>(at),&v,sizeof v);}
static uint64_t allocate(size_t n,DWORD protection=PAGE_READWRITE) {
    const auto p=VirtualAlloc(nullptr,n,MEM_COMMIT|MEM_RESERVE,protection);CHECK(p);return reinterpret_cast<uint64_t>(p);
}
static void literal(uint64_t at,const char* hex) {
    auto digit=[](char c)->uint8_t{return static_cast<uint8_t>(c<='9'?c-'0':c-'a'+10);};
    for(size_t i=0;i<std::strlen(hex)/2;++i)put<uint8_t>(at+i,static_cast<uint8_t>((digit(hex[i*2])<<4)|digit(hex[i*2+1])));
}
static void fake_image(uint64_t base,uint32_t stamp,uint32_t size) {
    IMAGE_DOS_HEADER dos{};dos.e_magic=IMAGE_DOS_SIGNATURE;dos.e_lfanew=128;
    IMAGE_NT_HEADERS64 nt{};nt.Signature=IMAGE_NT_SIGNATURE;nt.FileHeader.Machine=IMAGE_FILE_MACHINE_AMD64;
    nt.FileHeader.TimeDateStamp=stamp;nt.OptionalHeader.Magic=IMAGE_NT_OPTIONAL_HDR64_MAGIC;nt.OptionalHeader.SizeOfImage=size;
    put(base,dos);put(base+128,nt);
}
static uint32_t begin_current(const NADSC_Config* c) {
    uint64_t token=UINT64_MAX;const uint32_t result=NADSC_Begin(c,&token);
    if(result==0)CHECK(token==0);else {CHECK((result==1 || result==2) && token && token!=active_generation);active_generation=token;}
    return result;
}
static uint32_t end_current() {return NADSC_End(active_generation);}
static float last(unsigned axis) {float f=0;std::memcpy(&f,&records[calls-1].bits[axis],4);return f;}
static bool approximately(float a,float b) {return std::fabs(a-b)<.0001f;}
static void pass(const char* name) {++cases;std::printf("PASS %s\n",name);}
struct Fixture {
    NADSC_Config c{};uint64_t controller=0,descriptor=0,registry=0,units=0,generations=0,body_object=0,camera_object=0;
    uint64_t api=0,hashes=0,links=0,body_world=0,body_vtable=0,camera_locals=0,camera_worlds=0,request=0;
    uint64_t anim_instance=0,anim_graph=0,anim_current=0,anim_definition=0,settings=0;
    Setter invoke=nullptr;float input[4]{-2,0,1,0};
    Fixture() {
        c.size=sizeof c;c.abi=1;c.game=allocate(0x4744000,PAGE_EXECUTE_READWRITE);c.exe=allocate(0x39E8000);
        fake_image(c.game,0x6AB3B43F,0x4744000);fake_image(c.exe,0x6AB382E4,0x39E8000);
        // Independent literal captures from batches1616/1627, not production constants.
        literal(c.exe+0x30DEB0,"48895c2408574883ec60488bd9498bf88bcae8f9f9d8ff4c8b4b184c8bd04c6343208b4708498bd048c1e206498b4920");
        literal(c.exe+0x1FD220,"40534883ec204863dae89206eaff488bc84c8b0041ff90e8000000488bcb48c1e10648034828488bc14883c4205bc3");
        literal(c.exe+0x2BD870,"488d4160c3");
        literal(c.exe+0x2BD9C0,"488b8178010000c3");
        c.context=allocate(0x3000);c.camera=allocate(0x1000);c.avatar_owner=allocate(0x540000);
        c.avatar_index=0;c.avatar=0x333;c.body=0x400003;c.camera_unit=0x400004;
        c.forward=.18f;c.up=.04f;c.blend_ms=150;c.smoothing_ms=100;c.max_gap_ms=250;
        controller=allocate(0x1000);descriptor=allocate(0x1000);registry=allocate(0x1000);units=allocate(0x1000);
        generations=allocate(0x1000);body_object=allocate(0x1000);camera_object=allocate(0x1000);body_vtable=allocate(0x1000);
        put<uint64_t>(c.game+0x346D560,c.context);put<uint64_t>(c.context,c.camera);put<uint32_t>(c.context+8,c.camera_unit);
        put<uint64_t>(c.game+0x3326D20,c.avatar_owner);put<uint64_t>(c.game+0x347CE70,controller);
        settings=allocate(0xAD000);put<uint64_t>(c.game+0x3326340,settings);
        put<uint32_t>(c.avatar_owner+0x6C,1);put<uint64_t>(c.avatar_owner+0x110,descriptor);
        put<uint32_t>(descriptor+8,c.avatar);put<uint32_t>(descriptor+12,c.body);
        put<uint64_t>(c.exe+0x1A100F0,registry);put<uint32_t>(registry+0x98,16);
        put<uint64_t>(registry+0x88,units);put<uint64_t>(registry+0xA0,generations);
        put<uint8_t>(generations+3,1);put<uint64_t>(units+3*8,body_object);
        put<uint8_t>(generations+4,1);put<uint64_t>(units+4*8,camera_object);
        put<uint64_t>(body_object,body_vtable);put<uint64_t>(body_vtable+0xE8,c.exe+0x2BD870);
        hashes=allocate(0x1000);links=allocate(0x1000);body_world=allocate(107*64);
        put<uint32_t>(body_object+0x70,107);put<uint64_t>(body_object+0xA0,hashes);put<uint64_t>(body_object+0x98,links);
        put<uint64_t>(body_object+0x88,body_world);put<uint32_t>(hashes+90*4,0x8C5570C9);put<uint32_t>(hashes+89*4,0xE9ECCA21);
        put<uint32_t>(links+90*4,(89u<<16)|1u);
        anim_instance=allocate(0x1000);anim_graph=allocate(0x20000);anim_current=allocate(0x1000);anim_definition=anim_graph+0x200;
        put<uint64_t>(body_vtable+0x1B0,c.exe+0x2BD9C0);put<uint64_t>(body_object+0x178,anim_instance);
        put<uint64_t>(body_object+0x358,0x4D1C334D294DFA97ULL);put<uint64_t>(anim_instance+0x28,anim_graph);
        put<uint64_t>(anim_instance+0x50,anim_current);put<uint32_t>(anim_graph+4,31);put<uint32_t>(anim_graph+8,0x100);
        put<uint32_t>(anim_graph+0x100+4+13*4,0x100);put<uint32_t>(anim_definition+8,128);
        for(uint32_t i=0;i<128;++i)put<uint32_t>(anim_definition+12+i*4,0x1000+i*16);
        camera_locals=allocate(0x1000);camera_worlds=allocate(0x1000);
        put<uint64_t>(c.camera+0x18,camera_object+0x60);put<uint32_t>(c.camera+0x20,0);put<uint32_t>(camera_object+0x70,1);
        put<uint64_t>(camera_object+0x80,camera_locals);put<uint64_t>(camera_object+0x88,camera_worlds);
        camera_local=camera_locals+0x24;camera_world=camera_worlds+0x30;
        const uint64_t root=allocate(0x1000);api=allocate(0x1000);put<uint64_t>(c.game+0x3326308,root);put<uint64_t>(root+0x20,api);
        put<uint64_t>(api+0x20,reinterpret_cast<uint64_t>(synthetic_setter));fixture_target=synthetic_setter;
        // sub rsp,28; mov r9,API; call [r9+20]; add rsp,28; ret.
        const uint64_t site=c.game+0x127A135;literal(site-14,"4883ec2849b9");put<uint64_t>(site-8,api);
        literal(site,"41ff51204883c428c3");CHECK(FlushInstructionCache(GetCurrentProcess(),reinterpret_cast<void*>(site-14),23));
        invoke=reinterpret_cast<Setter>(site-14);normal();
    }
    void controls(uint32_t mask=0,bool active=false,bool guard=false) {put<uint32_t>(controller,mask);put<uint8_t>(controller+4,active?1:0);put<uint8_t>(controller+5,guard?1:0);}
    void point(uint64_t at,float x,float y,float z) {put<float>(at,x);put<float>(at+4,y);put<float>(at+8,z);}
    void body(float x=0,float y=0,float z=0,float head_z=1.5f) {point(body_world+0x30,x,y,z);point(body_world+90*64+0x30,x,y,z+head_z);}
    void body_yaw(float radians=0) {
        const float cosine=std::cos(radians),sine=std::sin(radians);
        point(body_world,cosine,sine,0);point(body_world+0x10,-sine,cosine,0);point(body_world+0x20,0,0,1);
    }
    void top(uint32_t kind) {put<uint32_t>(c.context+0x1F8,0);put<uint32_t>(c.context+0x1FC,1);request=c.context+0x200;
        put<uint32_t>(request,kind);put<uint32_t>(request+4,c.avatar);put<uint32_t>(request+8,0x444);put<uint32_t>(request+12,c.body);}
    void normal() {
        controls();top(4);body();body_yaw();put<uint8_t>(c.avatar_owner+0x53E88E,0);put<uint64_t>(camera_object+0x1D0,0);
        put<uint32_t>(c.avatar_owner+0x53E880,0);put<uint32_t>(settings+0xAC21C,0);
        put<uint64_t>(anim_current+13*8,anim_definition+0x1000+36*16);
        point(c.context+0x0C,1,0,0);point(c.context+0x1C,0,1,0);point(c.context+0x2C,0,0,1);
        point(camera_local,0,0,0);point(camera_world,0,0,0);input[0]=-2;input[1]=0;input[2]=1;input[3]=0;
    }
    void begin() {normal();CHECK(begin_current(&c)==1);}
    void sample(uint64_t elapsed=16) {fixture_time+=elapsed;invoke(reinterpret_cast<void*>(c.camera),c.camera_unit,input);}
    void settle() {sample();sample(150);CHECK(approximately(policy.blend,1));}
    NADSC_Stats stats() {NADSC_Stats s{};s.size=sizeof s;s.abi=1;CHECK(NADSC_ReadStats(reserved.load()?active_generation:0,&s)==1);return s;}
};
int main() {
    Fixture f;CHECK(f.stats().installed==0);CHECK(NADSC_Validate(&f.c)==1 && fixture_cas_calls==0);
    CHECK(begin_current(&f.c)==1 && calls==0);CHECK(end_current()==1);pass("read-only preflight; Begin owns dispatch without out-of-frame camera writes");
    f.begin();f.settle();const auto offsets_cas=fixture_cas_calls;
    CHECK(NADSC_SetOffsets(active_generation,.1f,-.1f,.02f)==1);f.sample();
    CHECK(approximately(last(0),.1f)&&approximately(last(1),-.1f)&&approximately(last(2),1.52f));
    CHECK(policy.blend==1 && fixture_cas_calls==offsets_cas);
    CHECK(NADSC_SetOffsets(active_generation+1,.2f,0,0)==0 && policy.side==.1f);
    CHECK(NADSC_SetOffsets(active_generation,.6f,0,0)==0 && policy.side==.1f);
    f.top(6);f.sample();CHECK(records[calls-1].input==f.input);
    CHECK(end_current()==1);CHECK(NADSC_SetOffsets(active_generation,0,0,0)==0);
    pass("owned live XYZ offsets preserve blend and dispatch, reject stale/range writes, and leave native ADS exact");
    for(uint32_t kind:{4u,6u}) {
        f.normal();f.top(kind);f.controls(0x20);const auto prior_cas=fixture_cas_calls;uint64_t rejected=99;
        CHECK(NADSC_Validate(&f.c)==0 && NADSC_Error()==OWNER_MISMATCH);
        CHECK(NADSC_Begin(&f.c,&rejected)==0 && rejected==0 && reserved.load()==0 && fixture_cas_calls==prior_cas);
    }pass("observed vault mask cannot Validate or Begin a camera lease in either camera kind");
    f.begin();f.sample();CHECK(approximately(last(0),-2) && approximately(last(2),1));f.sample(75);
    CHECK(approximately(policy.blend,.5f) && approximately(last(0),-1) && approximately(last(1),.09f));
    f.sample(75);CHECK(approximately(last(0),0) && approximately(last(1),.18f) && approximately(last(2),1.54f));
    CHECK(f.stats().replaced==3 && f.stats().head_distance==1.5f);pass("smoothstep ingress uses fresh head and current native offset");
    float before[4]{};std::memcpy(before,f.input,16);f.body(10,20,3);f.input[0]=8;f.input[1]=20;f.input[2]=4;
    f.sample();CHECK(approximately(last(0),10) && approximately(last(1),20.18f) && approximately(last(2),4.54f));
    std::memcpy(before,f.input,16);f.sample();CHECK(std::memcmp(before,f.input,16)==0 && approximately(last(0),10));
    pass("root movement tracks immediately; source untouched and no positional accumulation");CHECK(end_current()==1);
    f.begin();f.point(f.body_world+90*64+0x30,.2f,.1f,1.5f);f.settle();
    CHECK(approximately(last(0),.2f) && approximately(last(1),.28f));
    f.body(10,20,3);f.body_yaw(1.5707963268f);f.point(f.body_world+90*64+0x30,9.9f,20.2f,4.5f);
    f.input[0]=8;f.input[1]=20;f.input[2]=4;f.sample();
    CHECK(approximately(last(0),9.9f) && approximately(last(1),20.38f) && approximately(last(2),4.54f));
    CHECK(approximately(policy.relative_head[0],.2f) && approximately(policy.relative_head[1],.1f));
    pass("fresh body-root translation and rotation carry damped local head without turn or movement lag");CHECK(end_current()==1);
    f.begin();f.settle();f.body(0,0,0,.7f);f.sample(16);CHECK(last(2)<=.80f && last(2)>=.73f);
    pass("head-relative bob smoothing lag is capped at six centimeters");CHECK(end_current()==1);
    f.begin();f.settle();
    for(unsigned frame=0;frame<60;++frame) {
        const float x=static_cast<float>(frame)*.01f,bob=frame%2?.02f:-.02f;
        f.body(x,0,0,1.5f+bob);f.input[0]=x-2;f.sample();
        CHECK(approximately(last(0),x) && std::fabs(last(2)-1.54f)<.004f);
    }
    pass("rapid small action bob is damped while fresh root travel remains exact");CHECK(end_current()==1);
    f.begin();f.settle();const uint32_t nan=0x7fc01234;std::memcpy(&f.input[3],&nan,4);f.sample();CHECK(records[calls-1].bits[3]==nan);
    pass("padding W stays bit-exact including NaN sentinel");CHECK(end_current()==1);
    f.begin();f.settle();f.point(f.c.context+0x1C,1,0,0);f.point(f.c.context+0x0C,0,-1,0);f.sample();
    CHECK(approximately(last(0),.18f) && approximately(last(1),0));pass("bounded forward/up offset uses verified native view basis");CHECK(end_current()==1);
    f.begin();f.settle();
    for(float pitch:{-.9f,.9f,1.5707963268f}) {
        const float c=std::cos(pitch),s=std::sin(pitch);
        f.point(f.c.context+0x0C,1,0,0);f.point(f.c.context+0x1C,0,c,s);f.point(f.c.context+0x2C,0,-s,c);f.sample();
        CHECK(approximately(last(0),0) && approximately(last(1),.18f) && approximately(last(2),1.54f));
    }
    f.point(f.c.context+0x0C,.8f,0,-.6f);f.point(f.c.context+0x1C,0,1,0);f.point(f.c.context+0x2C,.6f,0,.8f);f.sample();
    CHECK(approximately(last(0),0) && approximately(last(1),.18f) && approximately(last(2),1.54f));
    pass("pitch and roll do not orbit the clearance or eye height; vertical view uses current body yaw");CHECK(end_current()==1);
    f.begin();f.settle();const uint64_t old_replaced=replaced.load();f.top(6);put<uint64_t>(f.camera_object+0x1D0,0x1234);
    f.sample();CHECK(records[calls-1].input==f.input && std::memcmp(records[calls-1].bits,f.input,16)==0);
    CHECK(f.stats().native6_forwarded==1 && replaced.load()==old_replaced && armed.load()==1);
    pass("native6 forwards exact pointer and bits even in another parent space");
    f.top(4);put<uint64_t>(f.camera_object+0x1D0,0);f.sample();
    CHECK(policy.blend==1 && approximately(last(0),0) && approximately(last(1),.18f) && approximately(last(2),1.54f));
    pass("first normal4 frame after native6 is at fresh head without TPV retreat or local-space reuse");CHECK(end_current()==1);
    f.begin();f.top(6);f.sample();f.top(4);put<uint64_t>(f.camera_object+0x1D0,0x1234);f.sample();
    CHECK(policy.native6_seen && records[calls-1].input==f.input);put<uint64_t>(f.camera_object+0x1D0,0);f.sample();
    CHECK(policy.blend==1 && approximately(last(2),1.54f));pass("brief parent-space settling preserves recent native6 handoff");CHECK(end_current()==1);
    for(unsigned mode=0;mode<5;++mode) {
        f.begin();f.top(6);f.sample();f.top(4);
        if(mode==0)f.top(12);if(mode==1)f.controls(1);if(mode==2)put<uint64_t>(f.anim_current+13*8,f.anim_definition+0x1000+103*16);
        if(mode==3)put<uint32_t>(f.request+4,f.c.avatar+1);f.sample(mode==4?500:16);
        CHECK(!policy.native6_seen);f.top(4);f.controls();put<uint64_t>(f.anim_current+13*8,f.anim_definition+0x1000+36*16);
        f.sample();CHECK(policy.blend<1 && records[calls-1].input!=nullptr);CHECK(end_current()==1);
    }pass("unsupported foreign unsafe death and long gaps discard stale native6 ingress shortcut");
    f.begin();f.settle();f.sample(500);CHECK(policy.blend==0 && records[calls-1].bits[0]==*reinterpret_cast<uint32_t*>(f.input));
    pass("long frame gap resets interpolation instead of replaying old world positions");CHECK(end_current()==1);
    f.begin();f.settle();for(uint32_t mask:{1u,3u,4u,8u,0x10u,0x22u,0x30u,0x40u,0x60u,0x80u}) {f.controls(mask);f.sample();CHECK(records[calls-1].input==f.input && armed.load()==1);}
    f.controls(0,false,true);f.sample();CHECK(records[calls-1].input==f.input);f.controls(2);f.sample();f.sample(150);
    CHECK(approximately(last(2),1.54f));put<uint8_t>(f.c.avatar_owner+0x53E88E,4);f.sample();CHECK(records[calls-1].input==f.input);
    pass("mask2 allows normal head anchor; unknown masks guard and seated states forward");CHECK(end_current()==1);
    f.begin();f.top(6);f.controls(0x20);float vault_source[4]{};std::memcpy(vault_source,f.input,16);f.sample();
    CHECK(records[calls-1].input==f.input && std::memcmp(records[calls-1].bits,vault_source,16)==0 && replaced.load()==0);
    f.top(4);f.sample();
    CHECK(armed.load()==1 && policy.safe==false && policy.fallback_safe && policy.blend==1 && replaced.load()==1);
    CHECK(approximately(last(0),0) && approximately(last(1),.18f) && approximately(last(2),1.54f) && std::memcmp(vault_source,f.input,16)==0);
    pass("owned native6 to on-foot vault normal4 anchors the first frame while native6 and input remain exact");CHECK(end_current()==1);
    f.begin();f.top(6);f.sample();f.top(4);f.controls(0x20);put<uint64_t>(f.camera_object+0x1D0,0x1234);f.sample();
    CHECK(policy.native6_seen && records[calls-1].input==f.input && NADSC_Error()==SPACE_INVALID);
    put<uint64_t>(f.camera_object+0x1D0,0);f.sample();CHECK(policy.blend==1 && approximately(last(2),1.54f));
    pass("vault fallback waits for verified world space without exposing a fresh TPV ingress");CHECK(end_current()==1);
    for(unsigned mode=0;mode<8;++mode) {
        f.begin();f.settle();f.controls(0x20);const auto unchanged=replaced.load();uint32_t saved_hash=0;
        if(mode==0)put<uint64_t>(f.anim_current+13*8,f.anim_definition+0x1000+103*16);
        if(mode==1)f.controls(0x20,false,true);if(mode==2)put<uint8_t>(f.c.avatar_owner+0x53E88E,4);
        if(mode==3)put<uint64_t>(f.camera_object+0x1D0,0x1234);if(mode==4)f.point(camera_world,1,0,0);
        if(mode==5) {CHECK(value(f.hashes+90*4,saved_hash));put<uint32_t>(f.hashes+90*4,0);}
        if(mode==6)f.top(7);if(mode==7)put<uint32_t>(f.request+4,f.c.avatar+1);
        f.sample();CHECK(armed.load()==1 && records[calls-1].input==f.input && replaced.load()==unchanged);
        if(mode==5)put<uint32_t>(f.hashes+90*4,saved_hash);CHECK(end_current()==1);
    }pass("vault exception retains on-foot graph owner space guard and seated exclusions");
    f.begin();f.settle();for(uint64_t state:{f.anim_definition+0x1000+103*16,static_cast<uint64_t>(0),f.anim_definition+0x1FFFF}) {
        put<uint64_t>(f.anim_current+13*8,state);f.sample();CHECK(armed.load()==1 && records[calls-1].input==f.input && NADSC_Error()==ON_FOOT_REQUIRED);}
    put<uint64_t>(f.anim_current+13*8,f.anim_definition+0x1000+36*16);f.sample();f.sample(150);CHECK(approximately(last(2),1.54f));
    put<uint32_t>(f.anim_definition+12,0x1000+36*16);f.sample();CHECK(records[calls-1].input==f.input);
    put<uint32_t>(f.anim_definition+12,0x1000);put<uint32_t>(f.anim_graph+4,30);f.sample();CHECK(records[calls-1].input==f.input);
    put<uint32_t>(f.anim_graph+4,31);pass("positive on-foot state36 required; death103 null unknown aliased and wrong graph states forward");CHECK(end_current()==1);
    f.normal();put<uint64_t>(f.anim_current+13*8,f.anim_definition+0x1000+3*16);
    put<uint32_t>(f.c.avatar_owner+0x53E880,0x220A);put<uint32_t>(f.settings+0xAC21C,3);
    CHECK(NADSC_Validate(&f.c)==1 && begin_current(&f.c)==1);f.settle();
    CHECK(armed.load()==1 && approximately(last(2),1.54f) && NADSC_Error()==OK);
    f.top(6);f.sample();CHECK(records[calls-1].input==f.input && native6_forwarded.load()==1);
    f.top(4);f.sample();CHECK(approximately(last(2),1.54f) && policy.blend==1);
    CHECK(end_current()==1);pass("observed bridge state3 with scene3 and actual combat-role2 anchors normal4 and preserves native6 exactly");
    for(uint32_t role:{0U,4U,6U,0x220CU,0x220EU}) {
        f.begin();f.settle();put<uint64_t>(f.anim_current+13*8,f.anim_definition+0x1000+3*16);
        put<uint32_t>(f.c.avatar_owner+0x53E880,role);put<uint32_t>(f.settings+0xAC21C,3);f.sample();
        CHECK(records[calls-1].input==f.input && NADSC_Error()==ON_FOOT_REQUIRED && armed.load()==1 && !policy.tracking);
        CHECK(end_current()==1);
    }pass("ordinary ship role4, absent role and conflicting role bits never receive the bridge exception");
    for(unsigned mode=0;mode<5;++mode) {
        f.begin();f.settle();put<uint64_t>(f.anim_current+13*8,f.anim_definition+0x1000+(mode==3?4:3)*16);
        put<uint32_t>(f.c.avatar_owner+0x53E880,0x220A);put<uint32_t>(f.settings+0xAC21C,mode<3?mode:3);
        if(mode==4)put<uint32_t>(f.anim_definition+12,0x1000+3*16);
        f.sample();CHECK(records[calls-1].input==f.input && NADSC_Error()==ON_FOOT_REQUIRED && armed.load()==1);
        if(mode==4)put<uint32_t>(f.anim_definition+12,0x1000);CHECK(end_current()==1);
    }pass("bridge permission does not admit other scenes, unknown states or first-index aliases");
    for(unsigned mutation=0;mutation<5;++mutation) {
        f.begin();f.settle();put<uint64_t>(f.anim_current+13*8,f.anim_definition+0x1000+3*16);
        put<uint32_t>(f.c.avatar_owner+0x53E880,0x220A);put<uint32_t>(f.settings+0xAC21C,3);
        fixture_bridge_mutation=mutation==0?f.c.avatar_owner+0x53E880:mutation==1?f.settings+0xAC21C
            :mutation==2?f.generations+3:mutation==3?f.anim_graph+4:f.body_object+0x358;
        uint32_t saved=0;CHECK(value(fixture_bridge_mutation,saved));const uint64_t changed_at=fixture_bridge_mutation;
        fixture_bridge_value=mutation==0?0x220C:mutation==1?4:mutation==2?saved+1:mutation==3?30:0;
        f.sample();CHECK(fixture_bridge_mutation==0 && records[calls-1].input==f.input && NADSC_Error()==ON_FOOT_REQUIRED && armed.load()==1);
        put<uint32_t>(changed_at,saved);CHECK(end_current()==1);
    }pass("bridge gate rereads role scene body generation resource and graph before any head substitution");
    f.begin();f.settle();put<uint32_t>(f.c.avatar_owner+0x53E880,0x220A);put<uint32_t>(f.settings+0xAC21C,3);
    f.sample();CHECK(approximately(last(2),1.54f) && NADSC_Error()==OK);
    put<uint32_t>(f.c.avatar_owner+0x53E880,0x220C);put<uint64_t>(f.c.game+0x3326340,0);
    f.sample();CHECK(approximately(last(2),1.54f) && NADSC_Error()==OK);CHECK(end_current()==1);
    put<uint64_t>(f.c.game+0x3326340,f.settings);
    pass("mission state36 remains independent of bridge scene reads and control-role bits");
    f.begin();f.settle();const auto replaced_before=replaced.load();setter_hook(reinterpret_cast<void*>(f.c.camera),f.c.camera_unit,f.input);
    f.invoke(reinterpret_cast<void*>(f.c.camera+64),f.c.camera_unit,f.input);f.invoke(reinterpret_cast<void*>(f.c.camera),f.c.camera_unit+1,f.input);
    CHECK(replaced.load()==replaced_before && armed.load()==1 && records[calls-1].input==f.input);
    pass("foreign caller camera and UnitRef forward exactly without changing own state");CHECK(end_current()==1);
    f.begin();f.settle();for(uint32_t kind:{0u,1u,7u,12u}) {f.top(kind);f.sample();CHECK(armed.load()==1 && policy.blend==0 && records[calls-1].input==f.input);}
    f.top(4);put<uint32_t>(f.request+4,f.c.avatar+1);f.sample();CHECK(armed.load()==1 && records[calls-1].input==f.input);
    put<uint32_t>(f.request+4,f.c.avatar);f.sample();f.sample(150);CHECK(approximately(last(2),1.54f));
    pass("unsupported or foreign request is native pass-through; stable own camera resumes");CHECK(end_current()==1);
    f.begin();f.settle();const auto stale=active_generation;CHECK(end_current()==1);f.begin();uint64_t busy=99;
    CHECK(NADSC_Begin(&f.c,&busy)==0 && busy==0 && NADSC_End(stale)==0 && armed.load()==1);
    NADSC_Stats s{};s.size=sizeof s;s.abi=1;CHECK(NADSC_ReadStats(0,&s)==0 && NADSC_ReadStats(stale,&s)==0);
    pass("BUSY and stale tokens cannot affect a later reservation");CHECK(end_current()==1);
    for(unsigned mode=0;mode<6;++mode) {
        f.begin();f.settle();uint64_t at=0;uint64_t saved=0;size_t length=0;
        if(mode==0){at=f.descriptor;length=4;}if(mode==1){at=f.generations+3;length=1;}if(mode==2){at=f.units+3*8;length=8;}
        if(mode==3){at=f.c.context;length=8;}if(mode==4){at=f.generations+4;length=1;}if(mode==5){at=f.c.context+8;length=4;}
        if(mode==6){at=f.request+4;length=4;}std::memcpy(&saved,reinterpret_cast<void*>(at),length);
        const uint64_t changed=saved+1;std::memcpy(reinterpret_cast<void*>(at),&changed,length);f.sample();
        CHECK(armed.load()==0 && records[calls-1].input==f.input);std::memcpy(reinterpret_cast<void*>(at),&saved,length);CHECK(end_current()==1);
    }pass("avatar body camera generation object and context ownership changes disarm passively");
    for(unsigned mode=0;mode<4;++mode) {
        f.begin();f.settle();uint64_t at=mode==0?f.hashes+90*4:mode==1?f.links+90*4:mode==2?f.body_object+0x70:f.body_object+0xA0;
        const size_t length=mode==3?8:4;uint64_t saved=0;std::memcpy(&saved,reinterpret_cast<void*>(at),length);
        const uint64_t changed=saved+1;std::memcpy(reinterpret_cast<void*>(at),&changed,length);f.sample();
        CHECK(armed.load()==1 && NADSC_Error()==GRAPH_MISMATCH && records[calls-1].input==f.input);
        std::memcpy(reinterpret_cast<void*>(at),&saved,length);CHECK(end_current()==1);
    }pass("per-frame head hash parent graph count and array identity guards");
    f.normal();put<uint32_t>(f.hashes+91*4,0x8C5570C9);CHECK(NADSC_Validate(&f.c)==0);put<uint32_t>(f.hashes+91*4,0);
    put<uint32_t>(f.hashes+90*4,0);CHECK(NADSC_Validate(&f.c)==0);put<uint32_t>(f.hashes+90*4,0x8C5570C9);
    pass("duplicate or absent head cannot arm");
    f.begin();f.settle();put<uint64_t>(f.camera_object+0x1D0,0x111);f.sample();CHECK(armed.load()==1 && NADSC_Error()==SPACE_INVALID);CHECK(end_current()==1);
    f.normal();f.point(camera_world,1,0,0);CHECK(NADSC_Validate(&f.c)==0 && NADSC_Error()==SPACE_INVALID);
    pass("parented or different local/world camera positions refuse head world coordinates");
    for(unsigned mode=0;mode<4;++mode) {f.begin();f.settle();if(mode==0)f.input[0]=NAN;
        if(mode==1)f.point(f.c.context+0x1C,1,1,1);if(mode==2)f.body(0,0,0,4);if(mode==3)f.input[0]=100;
        f.sample();CHECK(armed.load()==1 && records[calls-1].input==f.input);CHECK(end_current()==1);}
    pass("nonfinite invalid basis implausible head and remote camera forward while retaining stable lease");
    f.begin();f.settle();f.point(f.body_world,2,0,0);f.sample();
    CHECK(records[calls-1].input==f.input && armed.load()==1 && NADSC_Error()==GRAPH_MISMATCH);
    pass("invalid body-root basis forwards native instead of damping in an unproven frame");CHECK(end_current()==1);
    for(uint64_t at:{f.c.exe+0x30DEB0,f.c.exe+0x1FD220,f.c.exe+0x2BD870,f.c.game+0x127A135}) {
        f.normal();uint8_t b=0;CHECK(value(at,b));put<uint8_t>(at,b^1);CHECK(begin_current(&f.c)==0 && reserved.load()==0);put<uint8_t>(at,b);
    }pass("independent captured setter world-pose graph-getter and callsite bytes required");
    f.normal();fixture_slot_readonly=true;CHECK(begin_current(&f.c)==0);fixture_slot_readonly=false;
    fixture_foreign_cas_at=fixture_cas_calls+1;fixture_foreign_value=reinterpret_cast<uint64_t>(foreign_setter);CHECK(begin_current(&f.c)==0 && reserved.load()==0);
    uint64_t slot_value=0;CHECK(value(f.api+0x20,slot_value) && slot_value==fixture_foreign_value);fixture_foreign_cas_at=0;
    put<uint64_t>(f.api+0x20,reinterpret_cast<uint64_t>(synthetic_setter));pass("read-only slot and foreign CAS owner reject without overwriting foreign dispatch");
    f.normal();fixture_mutate_after_cas=f.request+4;fixture_mutation_value=f.c.avatar+1;fixture_cas_fail_at=fixture_cas_calls+2;
    CHECK(begin_current(&f.c)==2 && active_generation && reserved.load()==1 && armed.load()==0);
    fixture_mutate_after_cas=0;fixture_cas_fail_at=0;fixture_slot_unreadable=true;CHECK(end_current()==0 && reserved.load()==1);
    fixture_slot_unreadable=false;CHECK(end_current()==1 && reserved.load()==0);pass("partial Begin2 retains token for retryable owned cleanup");
    f.begin();fixture_slot_readonly=true;CHECK(end_current()==0 && reserved.load()==1);fixture_slot_readonly=false;CHECK(end_current()==1);
    f.begin();put<uint64_t>(f.api+0x20,reinterpret_cast<uint64_t>(foreign_setter));CHECK(end_current()==1);
    CHECK(value(f.api+0x20,slot_value) && slot_value==reinterpret_cast<uint64_t>(foreign_setter));put<uint64_t>(f.api+0x20,reinterpret_cast<uint64_t>(synthetic_setter));
    pass("End retries its own read-only slot and preserves foreign replacement");
    f.begin();f.settle();const auto calls_before_end=calls;CHECK(end_current()==1 && calls==calls_before_end);
    f.sample();CHECK(records[calls-1].input==f.input);pass("End performs no cached position replay and resident cached callbacks forward");
    f.begin();f.settle();const NADSC_Stats completed=f.stats();f.body(0,0,0,1.6f);
    setter_reached=CreateEventW(nullptr,TRUE,FALSE,nullptr);setter_continue=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    HANDLE stats_done=CreateEventW(nullptr,TRUE,FALSE,nullptr);CHECK(setter_reached && setter_continue && stats_done);
    std::thread display_writer([&]{f.sample();});CHECK(WaitForSingleObject(setter_reached,1000)==WAIT_OBJECT_0);
    armed.store(0,std::memory_order_release);error(OWNER_MISMATCH);
    NADSC_Stats concurrent{};concurrent.size=sizeof concurrent;concurrent.abi=1;uint32_t stats_result=0;
    std::thread display_reader([&]{stats_result=NADSC_ReadStats(active_generation,&concurrent);SetEvent(stats_done);});
    CHECK(WaitForSingleObject(stats_done,1000)==WAIT_OBJECT_0);
    CHECK(stats_result==1 && concurrent.installed==1 && concurrent.armed==0 && concurrent.error==OWNER_MISMATCH
        && concurrent.blend==completed.blend && concurrent.head_distance==completed.head_distance && concurrent.last_dt==completed.last_dt);
    NADSC_Stats invalid{};invalid.size=sizeof invalid;invalid.abi=1;
    CHECK(NADSC_ReadStats(active_generation+1,&invalid)==0 && NADSC_Error()==TOKEN_MISMATCH);
    invalid.abi=2;CHECK(NADSC_ReadStats(active_generation,&invalid)==0 && NADSC_Error()==INVALID_CONFIG);
    invalid.abi=1;invalid.size=sizeof invalid-4;CHECK(NADSC_ReadStats(active_generation,&invalid)==0);
    CHECK(NADSC_ReadStats(active_generation,reinterpret_cast<NADSC_Stats*>(1))==0);
    SetEvent(setter_continue);display_writer.join();display_reader.join();
    CloseHandle(setter_reached);CloseHandle(setter_continue);CloseHandle(stats_done);setter_reached=nullptr;setter_continue=nullptr;
    const auto newly_completed=f.stats();CHECK(newly_completed.head_distance==1.6f && newly_completed.armed==0);
    CHECK(end_current()==1);const auto ended_display=f.stats();CHECK(ended_display.blend==0 && ended_display.last_dt==0);
    pass("camera ReadStats completes while setter is blocked; health is fresh and diagnostics publish only after completion; End publishes reset");

    f.begin();f.settle();const auto coherent=f.stats();display_sequence.fetch_add(1,std::memory_order_seq_cst);
    display_head_distance.store(2.9f,std::memory_order_seq_cst);const auto interrupted=f.stats();
    CHECK(interrupted.blend==coherent.blend && interrupted.head_distance==coherent.head_distance && interrupted.last_dt==coherent.last_dt);
    display_head_distance.store(policy.head_distance,std::memory_order_seq_cst);display_sequence.fetch_add(1,std::memory_order_seq_cst);
    CHECK(end_current()==1);f.begin();const auto fresh_display=f.stats();
    CHECK(fresh_display.blend==0 && fresh_display.last_dt==0 && fresh_display.head_distance==1.5f);
    uint64_t busy_display=UINT64_MAX;CHECK(NADSC_Begin(&f.c,&busy_display)==0 && busy_display==0);
    const auto after_busy=f.stats();CHECK(after_busy.blend==fresh_display.blend && after_busy.head_distance==fresh_display.head_distance
        && after_busy.last_dt==fresh_display.last_dt && after_busy.error==BUSY);
    CHECK(end_current()==1);pass("camera odd publication uses complete cache; new generation resets and BUSY preserves the current tuple");

    f.begin();f.settle();
    fixture_before_policy_reached=CreateEventW(nullptr,TRUE,FALSE,nullptr);fixture_continue_policy=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    fixture_begin_display_reached=CreateEventW(nullptr,TRUE,FALSE,nullptr);fixture_continue_begin=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    CHECK(fixture_before_policy_reached && fixture_continue_policy && fixture_begin_display_reached && fixture_continue_begin);
    std::thread queued_callback([&]{f.sample();});CHECK(WaitForSingleObject(fixture_before_policy_reached,1000)==WAIT_OBJECT_0);
    CHECK(end_current()==1);f.normal();f.body(0,0,0,1.9f);uint32_t new_begin_result=0;
    std::thread new_begin([&]{new_begin_result=begin_current(&f.c);});
    CHECK(WaitForSingleObject(fixture_begin_display_reached,1000)==WAIT_OBJECT_0);
    const uint32_t new_sequence=display_sequence.load(std::memory_order_seq_cst);
    CHECK(display_head_distance.load(std::memory_order_seq_cst)==1.9f);
    SetEvent(fixture_continue_policy);queued_callback.join();
    CHECK(display_sequence.load(std::memory_order_seq_cst)==new_sequence && display_head_distance.load(std::memory_order_seq_cst)==1.9f);
    SetEvent(fixture_continue_begin);new_begin.join();CHECK(new_begin_result==1);
    CloseHandle(fixture_before_policy_reached);CloseHandle(fixture_continue_policy);
    CloseHandle(fixture_begin_display_reached);CloseHandle(fixture_continue_begin);
    fixture_before_policy_reached=nullptr;fixture_continue_policy=nullptr;fixture_begin_display_reached=nullptr;fixture_continue_begin=nullptr;
    CHECK(f.stats().head_distance==1.9f && f.stats().blend==0 && end_current()==1);
    pass("a callback queued before End cannot publish old diagnostics over a new reserved generation");

    f.begin();f.settle();setter_reached=CreateEventW(nullptr,TRUE,FALSE,nullptr);setter_continue=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    std::thread writer([&]{f.sample();});CHECK(WaitForSingleObject(setter_reached,1000)==WAIT_OBJECT_0);
    std::atomic<bool> finished{false};std::thread ending([&]{CHECK(end_current()==1);finished.store(true);});
    Sleep(20);CHECK(!finished.load());SetEvent(setter_continue);writer.join();ending.join();
    CloseHandle(setter_reached);CloseHandle(setter_continue);setter_reached=nullptr;setter_continue=nullptr;
    pass("End drains the actual adjusted native setter before restoring dispatch");

    {
        FreeAim::State a;FreeAim::Q out{};CHECK(a.apply(FreeAim::look(0,0),false,1,out));
        CHECK(a.apply(FreeAim::look(.04f,.02f),false,.016f,out));float y=0,z=0;CHECK(FreeAim::angles(out,y,z));
        CHECK(approximately(y,0)&&approximately(z,0));
        for(unsigned i=0;i<100;++i)CHECK(a.apply(FreeAim::look(.04f,.02f),false,.016f,out));
        CHECK(FreeAim::angles(out,y,z)&&approximately(y,0)&&approximately(z,0));
        CHECK(a.apply(FreeAim::look(.2f,.1f),false,.016f,out));CHECK(FreeAim::angles(out,y,z));
        CHECK(approximately(.2f-y,5*FreeAim::PI/180)&&approximately(.1f-z,3*FreeAim::PI/180));
        for(unsigned i=0;i<10;++i)CHECK(a.apply(FreeAim::look(.2f,.1f),true,.016f,out));
        CHECK(std::fabs(a.offset_yaw)<=1.101f*FreeAim::PI/180&&std::fabs(a.offset_pitch)<=.661f*FreeAim::PI/180);
        a.reset();CHECK(a.apply(FreeAim::look(.2f,.1f),false,1,out));CHECK(FreeAim::angles(out,y,z)&&approximately(y,.2f)&&approximately(z,.1f));
        CHECK(!a.apply({0,0,0,0},false,.016f,out));
        a.reset();CHECK(a.apply(FreeAim::look(3.13f,0),false,1,out));CHECK(a.apply(FreeAim::look(-3.13f,0),false,.016f,out));
        CHECK(std::fabs(a.offset_yaw)<.03f);
        const float matrix[16]{0,1,0,0,-1,0,0,0,0,0,1,0,0,0,0,1};FreeAim::Q mq{};
        CHECK(FreeAim::matrix_q(matrix,mq)&&FreeAim::angles(mq,y,z)&&approximately(y,FreeAim::PI/2));
        pass("free aim dead zone holds still, caps yaw/pitch, tightens aim, wraps yaw and rejects invalid poses");
    }
    f.normal();f.begin();f.top(6);f.controls();CHECK(owner(policy,false));
    const uint64_t fps=allocate(0x1000),fps_world=allocate(63*64),fps_hashes=allocate(63*4),fps_links=allocate(63*4);
    put<uint64_t>(f.units+5*8,fps);put<uint8_t>(f.generations+5,1);put<uint32_t>(f.c.avatar_owner+0x53E9B8,0x400005);
    put<uint64_t>(f.camera_object+0x1D0,fps);put<uint64_t>(f.camera_object+0x78,fps_world);put<uint32_t>(f.links,0x00320002);
    put<uint64_t>(f.camera_object+0x98,f.links);put<uint32_t>(fps+0x70,63);put<uint64_t>(fps+0x88,fps_world);
    put<uint64_t>(fps+0xA0,fps_hashes);put<uint64_t>(fps+0x98,fps_links);put<uint32_t>(fps_hashes+50*4,0x60ED8C39);put<uint32_t>(fps_links+50*4,0x40001);
    float frame[20]{};frame[19]=1;const auto before_frame=frame[0];
    const float local_identity[16]{1,0,0,0,1,0,0,0,1,0,0,0,1,1,1,0};
    const float world_identity[16]{1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1};
    put(f.camera_locals,local_identity);put(f.camera_worlds,world_identity);put(fps_world+50*64,world_identity);
    literal(f.c.game+0x127A127,"4c8d45c08b5308488b0b4c8b482041ff5120488b05c8c10a024c8d45008b5308488b0b4c8b482041ff5128");
    CHECK(NADSC_FreeAim(active_generation,30001)==0);
    CHECK(NADSC_FreeAim(active_generation,30000)==1);
    NADSC_FreeStats fs{};CHECK(NADSC_FreeAimStats(active_generation,&fs)==1&&fs.remaining_ms==30000);
    CHECK(NADSC_FreeAimStats(active_generation-1,&fs)==0);
    free_aim_camera(policy,frame,0,fixture_time);CHECK(policy.free_gate==0&&policy.free_applied==1);
    auto native_q=FreeAim::look(.04f,.02f);std::memcpy(frame+16,&native_q,16);
    fixture_time+=16;free_aim_camera(policy,frame,0,fixture_time);FreeAim::Q output_q{};std::memcpy(&output_q,frame+16,16);
    float camera_yaw=0,camera_pitch=0;CHECK(FreeAim::angles(output_q,camera_yaw,camera_pitch));
    CHECK(approximately(camera_yaw,0)&&approximately(camera_pitch,0)&&frame[0]==before_frame);
    policy.full_ads=true;std::memcpy(frame+16,&native_q,16);free_aim_camera(policy,frame,0,fixture_time+16);
    CHECK(std::memcmp(frame+16,&native_q,16)==0&&policy.free_ads==1&&!policy.free_aim.tracking);
    policy.full_ads=false;policy.free_aim.reset();policy.free_previous=0;
    const float parent_matrix[16]{0,1,0,0,-1,0,0,0,0,0,1,0,0,0,0,1};put(fps_world+50*64,parent_matrix); // Camera-world deliberately remains stale.
    native_q=FreeAim::look(0,0);std::memcpy(frame+16,&native_q,16);free_aim_camera(policy,frame,0,fixture_time+32);
    native_q=FreeAim::look(.04f,0);std::memcpy(frame+16,&native_q,16);free_aim_camera(policy,frame,0,fixture_time+48);
    std::memcpy(&output_q,frame+16,16);CHECK(FreeAim::angles(output_q,camera_yaw,camera_pitch)&&approximately(camera_yaw,0));
    CHECK(NADSC_FreeAim(active_generation,0)==1);
    CHECK(NADSC_ObserveParent(active_generation,3000)==1);observe_camera_parent(policy,fixture_time);
    NADSC_ParentStats45 ps{};CHECK(NADSC_ParentStats(active_generation,&ps)==1&&ps.samples==1&&ps.max_degrees>89);
    CHECK(NADSC_ObserveParent(active_generation,3001)==0&&NADSC_ObserveParent(active_generation-1,100)==0);
    FreeAim::Q guarded{};put<uint32_t>(fps_hashes+50*4,0);CHECK(!direct_camera_parent(policy,guarded));put<uint32_t>(fps_hashes+50*4,0x60ED8C39);
    put<uint8_t>(f.generations+5,2);CHECK(!direct_camera_parent(policy,guarded));put<uint8_t>(f.generations+5,1);
    pass("direct parent ignores stale camera-world readback; diagnostic is bounded/read-only and foreign generation/hash fail closed");
    policy.full_ads=false;policy.free_until=fixture_time;free_aim_camera(policy,frame,0,fixture_time);CHECK(policy.free_until==0);
    CHECK(NADSC_FreeAim(active_generation-1,0)==0&&NADSC_FreeAim(active_generation,0)==1);
    CHECK(NADSC_SetKick46(active_generation,1)==1);
    CHECK(NADSC_SetKick46(active_generation-1,1)==0);
    const uint64_t measured_before=policy.free_measured;
    policy.free_until=0;put<uint8_t>(f.c.avatar_owner+0x53E88C,64);CHECK(owner(policy,false));
    native_q=FreeAim::look(.04f,0);std::memcpy(frame+16,&native_q,16);
    free_aim_camera(policy,frame,0,fixture_time+64);CHECK(policy.kick_pulses==1&&policy.kick_angle>0);
    free_aim_camera(policy,frame,0,fixture_time+80);CHECK(policy.kick_pulses==1);
    put<uint8_t>(f.c.avatar_owner+0x53E88C,0);CHECK(owner(policy,false));free_aim_camera(policy,frame,0,fixture_time+96);
    put<uint8_t>(f.c.avatar_owner+0x53E88C,64);CHECK(owner(policy,false));free_aim_camera(policy,frame,0,fixture_time+112);CHECK(policy.kick_pulses==2);
    CHECK(policy.free_measured==measured_before); // No indefinite timing outside the bounded free-aim test.
    f.controls(0,true);CHECK(owner(policy,false));std::memcpy(frame+16,&native_q,16);free_aim_camera(policy,frame,0,fixture_time+128);
    CHECK(std::memcmp(frame+16,&native_q,16)==0&&policy.kick_angle==0);
    f.controls();put<uint8_t>(f.c.avatar_owner+0x53E88C,0);CHECK(owner(policy,false));
    for(unsigned n=0;n<100;++n)free_aim_camera(policy,frame,0,fixture_time+144+n*16);
    CHECK(policy.kick_angle==0);NADSC_KickStats46Data ks{};CHECK(NADSC_KickStats46(active_generation,&ks)==1&&ks.pulses==2&&ks.enabled==1);
    CHECK(NADSC_SetKick46(active_generation,0)==1);
    pass("shot pulses kick once per edge, held firing does not fabricate shots, ADS is exact and settled kick does no pose/timing work");
    CHECK(end_current()==1);
    pass("free aim edits only caller camera scratch, bypasses exact native ADS, expires and rejects stale tokens");

    {
     CameraTransition::State t;CameraTransition::Pose start{},desired{},out{};start.q=FreeAim::look(.4f,0);start.p[0]=1;
     t.apply(start,6,true,10,1000,out);CHECK(out.p[0]==1);
     desired.q=FreeAim::look(1.0f,0);desired.p[0]=1.27f;t.apply(desired,4,false,10,1010,out);float y=0,pitch=0;
     CHECK(approximately(out.p[0],1)&&FreeAim::angles(out.q,y,pitch)&&approximately(y,.4f));
     desired.q=FreeAim::look(.6f,0);desired.p[0]=.8f;t.apply(desired,6,false,10,1040,out);CHECK(approximately(out.p[0],1));
     t.apply(desired,6,false,10,1115,out);CHECK(out.p[0]>.8f&&out.p[0]<1);
     t.apply(desired,6,false,10,1190,out);CHECK(approximately(out.p[0],.8f)&&!t.active);
     desired.q=FreeAim::look(.7f,.1f);t.apply(desired,6,false,10,1200,out);CHECK(out.q.z==desired.q.z); // No settled input lag.
     desired.p[0]=1.5f;t.apply(desired,6,false,11,1210,out);CHECK(approximately(out.p[0],.8f));
     desired.p[0]=1.6f;t.apply(desired,6,true,11,1220,out);CHECK(out.p[0]==desired.p[0]&&out.q.z==desired.q.z&&!t.active);
     desired.p[0]=10;t.apply(desired,6,false,12,1230,out);CHECK(out.p[0]==10&&!t.active);
     pass("ADS release and 6-4-6/support swaps keep pose continuity, settle in 150ms, never delay steady look/native ADS or blend a teleport");
    }
    {
     CameraTransition::State t;CameraTransition::Pose a{},b{},out{};
     t.apply(a,6,true,10,1000,out);
     b.p[0]=.3f;t.apply(b,6,false,10,1010,out);CHECK(approximately(out.p[0],0));
     t.apply(b,6,false,10,1020,out);const float presented_before=out.p[0];
     b.p[0]=-.3f;b.q=FreeAim::look(.6f,0);t.apply(b,6,false,10,1030,out);
     float yaw=0,pitch=0;CHECK(std::fabs(out.p[0]-presented_before)<.03f);
     CHECK(FreeAim::angles(out.q,yaw,pitch)&&std::fabs(yaw)<.06f);
     t.apply(b,6,false,10,1160,out);CHECK(approximately(out.p[0],-.3f)&&!t.active);
     t.apply(a,6,false,10,1170,out);CHECK(approximately(out.p[0],0));
     pass("late incoming-rig solve is blended too, with exact steady look after handoff");
    }
    std::printf("Native camera fixture PASS: %llu cases\n",static_cast<unsigned long long>(cases));return 0;
}

