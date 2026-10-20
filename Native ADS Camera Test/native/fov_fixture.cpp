// Synthetic private buffers and local callbacks only; never accesses the game.
#define NADSF_FIXTURE
#include "native_ads_fov.cpp"
#include <cstdio>
#include <cstdlib>
#include <thread>
#define CHECK(x) do{if(!(x)){std::fprintf(stderr,"FAIL %d: %s error=%u\n",__LINE__,#x,NADSF_Error());std::abort();}}while(0)
static uint64_t active_generation=0,cases=0,calls=0;
struct Record {void* camera;uint32_t bits;};static Record records[4096]{};
static HANDLE setter_reached=nullptr,setter_continue=nullptr;
static uint64_t mutation_address=0;static uint32_t mutation_value=0;
__declspec(noinline) static void synthetic_setter(void* camera,float fov) {
    CHECK(calls<4096);records[calls].camera=camera;std::memcpy(&records[calls++].bits,&fov,4);
    if(mutation_address)std::memcpy(reinterpret_cast<void*>(mutation_address),&mutation_value,4);
    if(setter_reached) {SetEvent(setter_reached);WaitForSingleObject(setter_continue,INFINITE);}
}
__declspec(noinline) static void foreign_setter(void*,float) {}
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
static uint32_t begin_current(const NADSF_Config* c) {
    uint64_t token=UINT64_MAX;const uint32_t result=NADSF_Begin(c,&token);
    if(result==0)CHECK(token==0);else {CHECK((result==1 || result==2) && token && token!=active_generation);active_generation=token;}
    return result;
}
static uint32_t end_current() {return NADSF_End(active_generation);}
static float last() {float f=0;std::memcpy(&f,&records[calls-1].bits,4);return f;}
static bool approximately(float a,float b) {return std::fabs(a-b)<.00001f;}
static float lens(double degrees,double magnification) {
    return static_cast<float>(2*std::atan(std::tan(degrees*3.14159265358979323846/360)/magnification));
}
static void pass(const char* name) {++cases;std::printf("PASS %s\n",name);}
struct Fixture {
    NADSF_Config c{};uint64_t controller=0,descriptor=0,registry=0,units=0,generations=0,body_object=0,api=0,settings=0;
    Setter invoke=nullptr;
    Fixture() {
        c.size=sizeof c;c.abi=1;c.game=allocate(0x4744000,PAGE_EXECUTE_READWRITE);c.exe=allocate(0x39E8000);
        fake_image(c.game,0x6AB3B43F,0x4744000);fake_image(c.exe,0x6AB382E4,0x39E8000);
        // Independent literal read-only capture from live-fov-api.txt.
        literal(c.exe+0x30D990,"f30f114934c7415000000000e90f211c00");literal(c.exe+0x30D980,"f30f104134c3");
        c.context=allocate(0x3000);c.camera=allocate(0x1000);c.avatar_owner=allocate(0x540000);
        c.avatar_index=0;c.avatar=0x333;c.body=0x400003;c.weapon=0x444;
        controller=allocate(0x1000);descriptor=allocate(0x1000);registry=allocate(0x1000);units=allocate(0x1000);
        generations=allocate(0x1000);body_object=allocate(0x1000);settings=allocate(0xAD000);
        put<uint64_t>(c.game+0x346D560,c.context);put<uint64_t>(c.context,c.camera);
        put<uint64_t>(c.game+0x3326D20,c.avatar_owner);put<uint64_t>(c.game+0x347CE70,controller);
        put<uint32_t>(c.avatar_owner+0x6C,1);put<uint64_t>(c.avatar_owner+0x110,descriptor);
        put<uint32_t>(descriptor+8,c.avatar);put<uint32_t>(descriptor+12,c.body);
        put<uint64_t>(c.exe+0x1A100F0,registry);put<uint32_t>(registry+0x98,16);
        put<uint64_t>(registry+0x88,units);put<uint64_t>(registry+0xA0,generations);
        put<uint8_t>(generations+3,1);put<uint64_t>(units+3*8,body_object);
        put<uint64_t>(c.game+0x3326340,settings);degrees(90);
        const uint64_t root=allocate(0x1000);api=allocate(0x1000);
        put<uint64_t>(c.game+0x3326308,root);put<uint64_t>(root+0x20,api);
        put<uint64_t>(api+0x78,c.exe+0x30D980);put<uint64_t>(api+0x80,reinterpret_cast<uint64_t>(synthetic_setter));fixture_target=synthetic_setter;
        // sub rsp,28; mov rdx,API; call [rdx+80]; add rsp,28; ret.
        const uint64_t site=c.game+0x127A11A;literal(site-14,"4883ec2848ba");put<uint64_t>(site-8,api);
        literal(site,"ff92800000004883c428c3");CHECK(FlushInstructionCache(GetCurrentProcess(),reinterpret_cast<void*>(site-14),25));
        invoke=reinterpret_cast<Setter>(site-14);normal();
    }
    void degrees(float f) {put<float>(settings+0xAC408,f);}
    void shoulder(bool held) {put<uint8_t>(c.avatar_owner+0x53E88A,held?4:0);put<uint8_t>(c.avatar_owner+0x53E88F,held?32:0);}
    void controls(uint32_t mask=0,bool active=false,bool guard=false) {
        put<uint32_t>(controller,mask);put<uint8_t>(controller+4,active?1:0);put<uint8_t>(controller+5,guard?1:0);
    }
    void normal() {controls();shoulder(false);put<uint8_t>(c.avatar_owner+0x53E886,0);put<uint8_t>(c.avatar_owner+0x53E88E,0);top(4,1,c.weapon);}
    void top(uint32_t kind,uint32_t tail,uint32_t weapon) {
        put<uint32_t>(c.context+0x1F8,0);put<uint32_t>(c.context+0x1FC,tail);
        c.request=c.context+0x200+((tail+31)%32)*0xE8;
        put<uint32_t>(c.request,kind);put<uint32_t>(c.request+4,c.avatar);put<uint32_t>(c.request+8,weapon);put<uint32_t>(c.request+12,c.body);
    }
    void fp() {normal();top(6,2,c.weapon);}
    void begin() {fp();CHECK(begin_current(&c)==1);}
    void sample(float f=.785398185f) {invoke(reinterpret_cast<void*>(c.camera),f);}
    NADSF_Stats stats() {NADSF_Stats s{};s.size=sizeof s;s.abi=1;CHECK(NADSF_ReadStats(reserved.load()?active_generation:0,&s)==1);return s;}
};
int main() {
    Fixture f;CHECK(f.stats().installed==0);CHECK(NADSF_Validate(&f.c)==1 && fixture_cas_calls==0);
    CHECK(begin_current(&f.c)==0 && reserved.load()==0);pass("normal4 read-only preflight; Begin requires owned6");
    fixture_now=0;f.begin();f.shoulder(true);uint8_t legacy=1;CHECK(value(f.c.avatar_owner+0x53E886,legacy) && legacy==0);
    f.sample();fixture_now=.06;f.sample();CHECK(approximately(last(),lens(90,1.025)));
    fixture_now=.12;f.sample();CHECK(approximately(last(),lens(90,1.05)) && f.stats().ads_forwarded==0);
    CHECK(end_current()==1);pass("agreeing82/125 with legacy48false produces the complete shoulder zoom");

    fixture_now=0;f.begin();put<uint8_t>(f.c.avatar_owner+0x53E886,1);const uint64_t legacy_reads=fixture_clock_reads;
    for(double time:{0.0,.06,.12,.24}) {fixture_now=time;f.sample(.321f);CHECK(last()==90*RAD_PER_DEG);}
    CHECK(fixture_clock_reads==legacy_reads && f.stats().ads_forwarded==0 && armed.load()==1 && end_current()==1);
    pass("legacy48 alone neither starts shoulder zoom nor masquerades as full ADS");

    for(unsigned selected=0;selected<2;++selected)for(unsigned old=0;old<2;++old) {
        fixture_now=0;f.begin();put<uint8_t>(f.c.avatar_owner+0x53E886,static_cast<uint8_t>(old));
        put<uint8_t>(f.c.avatar_owner+0x53E88A,selected==0?4:0);
        put<uint8_t>(f.c.avatar_owner+0x53E88F,selected==1?32:0);
        f.sample();fixture_now=.12;f.sample();CHECK(last()==90*RAD_PER_DEG && f.stats().ads_forwarded==0 && armed.load()==1);
        f.controls(0,true);f.sample(.213f);CHECK(last()==.213f && f.stats().ads_forwarded==1 && end_current()==1);
    }
    pass("mismatched82/125 never acquires shoulder zoom or vetoes native full ADS");

    fixture_now=0;f.begin();f.shoulder(true);f.sample();fixture_now=.06;f.sample();const float paired_half=last();
    put<uint8_t>(f.c.avatar_owner+0x53E886,1);f.sample();CHECK(last()==paired_half);
    fixture_now=.12;f.sample();CHECK(approximately(last(),lens(90,1.05)));
    f.controls(0,true);f.sample(.271f);CHECK(last()==.271f && f.stats().ads_forwarded==1 && end_current()==1);
    pass("legacy48 changes do not veto the paired shoulder tween; full ADS still wins both flags");

    fixture_now=0;f.begin();const uint64_t clock_before=fixture_clock_reads;
    const float exact_hip=90*RAD_PER_DEG;uint32_t exact_hip_bits=0;std::memcpy(&exact_hip_bits,&exact_hip,4);
    for(unsigned i=0;i<100;++i) {fixture_now+=.016;f.sample();CHECK(records[calls-1].bits==exact_hip_bits);}
    CHECK(fixture_clock_reads==clock_before && end_current()==1);
    pass("settled hip stays bit-exact live TPV with no clock or shoulder tween");

    fixture_now=0;f.begin();f.shoulder(true);f.sample();CHECK(last()==exact_hip);
    float previous=last();
    for(double time:{.03,.06,.09,.12}) {
        fixture_now=time;f.sample();CHECK(last()<previous && last()>1.5f);previous=last();
        if(time==.06)CHECK(approximately(last(),lens(90,1.025)));
    }
    CHECK(approximately(last(),1.522025508f) && approximately(last(),lens(90,1.05)));
    const uint64_t settled_reads=fixture_clock_reads;
    for(unsigned i=0;i<100;++i) {fixture_now+=.016;f.sample();CHECK(approximately(last(),lens(90,1.05)));}
    CHECK(fixture_clock_reads==settled_reads && end_current()==1);
    pass("shoulder aim eases to five-percent focal magnification in120ms and rests without clock reads");

    fixture_now=0;f.begin();f.shoulder(true);f.sample();fixture_now=.06;f.sample();
    fixture_now=.12;f.sample();f.shoulder(false);f.sample();CHECK(approximately(last(),lens(90,1.05)));
    fixture_now=.18;f.sample();CHECK(approximately(last(),lens(90,1.025)));
    fixture_now=.24;f.sample();CHECK(records[calls-1].bits==exact_hip_bits);
    const uint64_t released_reads=fixture_clock_reads;fixture_now=.3;f.sample();CHECK(fixture_clock_reads==released_reads);
    CHECK(end_current()==1);pass("shoulder release follows the same120ms lens easing to exact hip");

    fixture_now=0;f.begin();f.shoulder(true);f.sample();fixture_now=.06;f.sample();
    const float half=last();f.shoulder(false);fixture_now=.07;f.sample();CHECK(last()==half);
    fixture_now=.10;f.sample();CHECK(approximately(last(),lens(90,1.0078125)));
    fixture_now=.13;f.sample();CHECK(approximately(last(),exact_hip));CHECK(end_current()==1);
    pass("mid-transition shoulder reversal is continuous and never overshoots hip");

    fixture_now=0;f.begin();f.shoulder(true);f.sample();fixture_now=.06;f.sample();
    f.degrees(105);f.sample();CHECK(approximately(last(),lens(105,1.025)));
    float unchanged_degrees=0;CHECK(value(f.settings+0xAC408,unchanged_degrees) && unchanged_degrees==105);
    fixture_now=.12;f.sample();CHECK(approximately(last(),lens(105,1.05)));
    CHECK(end_current()==1);f.degrees(90);pass("shoulder magnification uses the fresh live TPV setting without changing its source");

    fixture_now=0;f.begin();f.shoulder(true);f.sample();fixture_now=.12;f.sample();
    f.controls(0,true);f.sample(.211f);CHECK(last()==.211f && f.stats().ads_forwarded==1);
    f.controls();fixture_now=.13;f.sample();CHECK(records[calls-1].bits==exact_hip_bits);
    fixture_now=.19;f.sample();CHECK(approximately(last(),lens(90,1.025)));
    f.controls(0,true);f.shoulder(false);f.sample(.299f);CHECK(last()==.299f);
    f.controls();f.sample();CHECK(records[calls-1].bits==exact_hip_bits && end_current()==1);
    pass("full ADS forwards native zoom immediately and discards shoulder blend on both exit paths");

    fixture_now=0;f.begin();f.shoulder(true);f.sample();fixture_now=.06;f.sample();
    fixture_now=.01;f.sample();CHECK(approximately(last(),lens(90,1.025)));
    fixture_now=10;f.sample();CHECK(approximately(last(),lens(90,1.025)));
    fixture_now=10.06;f.sample();CHECK(approximately(last(),lens(90,1.05)) && end_current()==1);
    fixture_now=0;f.begin();f.shoulder(true);f.sample();fixture_now=.06;f.sample();
    fixture_clock_ok=false;f.sample();CHECK(records[calls-1].bits==exact_hip_bits);
    fixture_clock_ok=true;f.sample();CHECK(records[calls-1].bits==exact_hip_bits);
    fixture_now=.12;f.sample();CHECK(approximately(last(),lens(90,1.025)) && end_current()==1);
    pass("backward and long clock gaps rebase; failed QPC falls back to exact hip and restarts cleanly");

    fixture_now=0;f.begin();f.shoulder(true);f.sample();fixture_now=.12;f.sample();
    f.controls(32);f.sample(.333f);CHECK(last()==.333f && armed.load()==1);
    f.controls();f.sample();CHECK(records[calls-1].bits==exact_hip_bits);
    fixture_now=.18;f.sample();CHECK(approximately(last(),lens(90,1.025)));
    f.top(4,3,f.c.weapon);f.sample(.444f);CHECK(last()==.444f);
    f.top(6,4,f.c.weapon+1);CHECK(NADSF_Bind(active_generation,f.c.request,f.c.weapon+1)==1);
    CHECK(records[calls-1].bits==exact_hip_bits && end_current()==1);
    pass("unsupported actions and unbound camera requests forward native and reset shoulder tween");

    f.fp();f.shoulder(true);uint64_t before_aim=calls;
    CHECK(begin_current(&f.c)==1 && calls==before_aim+1 && approximately(last(),90*RAD_PER_DEG));CHECK(end_current()==1);
    f.fp();f.controls(0,true);before_aim=calls;
    CHECK(begin_current(&f.c)==1 && calls==before_aim);f.sample(.2f);CHECK(last()==.2f);CHECK(end_current()==1);
    pass("Begin starts shoulder easing from exact hip and never overwrites full ADS zoom");
    uint8_t code_before[64]{};CHECK(read(reinterpret_cast<uint64_t>(synthetic_setter),code_before,64));
    uint64_t start=calls;f.begin();CHECK(calls==start+1 && approximately(last(),1.5707963268f));
    CHECK(f.stats().immediate_applies==1 && armed.load()==1);pass("Begin immediately applies live90 hip FOV through original setter");
    f.sample();CHECK(approximately(last(),1.5707963268f));float source_value=0;CHECK(value(f.settings+0xAC408,source_value) && source_value==90);
    CHECK(f.stats().replaced==1 && f.stats().last_native==.785398185f);f.degrees(105);f.sample();CHECK(approximately(last(),105*RAD_PER_DEG));
    CHECK(value(f.settings+0xAC408,source_value) && source_value==105);pass("live105 honored; source settings and native request untouched");
    for(float valid:{1.0f,179.0f}) {f.degrees(valid);f.sample();CHECK(approximately(last(),valid*RAD_PER_DEG));}
    const uint32_t invalid_bits[]={0,0x43340000,0x7F800000,0x7FC12345};
    for(uint32_t bits:invalid_bits) {put<uint32_t>(f.settings+0xAC408,bits);f.sample(.123f);CHECK(last()==.123f);}
    f.degrees(90);pass("finite1..179 accepted; invalid source forwards native exactly");
    f.shoulder(true);f.sample(.25f);
    CHECK(approximately(last(),90*RAD_PER_DEG) && f.stats().ads_forwarded==0);
    pass("shoulder edge starts at live hip before its gradual magnification");
    f.controls(0,true);f.sample(.3f);CHECK(last()==.3f && f.stats().ads_forwarded==1);
    f.shoulder(false);f.sample(.31f);CHECK(last()==.31f && f.stats().ads_forwarded==2);
    f.controls();pass("only native controller full ADS forwards native zoom with explicit counter");
    f.controls(2);f.sample();CHECK(approximately(last(),90*RAD_PER_DEG) && armed.load()==1);
    for(uint32_t mask:{1U,3U,4U}) {f.controls(mask);f.sample(.4f);CHECK(last()==.4f && armed.load()==1);}
    f.controls(2,false,true);f.sample(.41f);CHECK(last()==.41f);f.controls();put<uint8_t>(f.c.avatar_owner+0x53E88E,4);f.sample(.42f);CHECK(last()==.42f);
    put<uint8_t>(f.c.avatar_owner+0x53E88E,0);pass("mask2 retains hip FOV; other masks guard and seated states forward");
    const uint32_t nan_bits=0x7FC12345;float nan=0;std::memcpy(&nan,&nan_bits,4);
    reinterpret_cast<Setter>(callback())(reinterpret_cast<void*>(f.c.camera),nan);CHECK(records[calls-1].bits==nan_bits);
    f.invoke(reinterpret_cast<void*>(f.c.camera+8),nan);CHECK(records[calls-1].camera==reinterpret_cast<void*>(f.c.camera+8) && records[calls-1].bits==nan_bits);
    CHECK(armed.load()==1 && f.stats().ads_forwarded==2);pass("wrong caller or camera bit-exact forward without foreign ADS counts");
    // Native exit/entry can occur before the host binds its new request.
    f.top(4,3,f.c.weapon);f.sample(.5f);CHECK(last()==.5f && armed.load()==1);
    f.top(6,4,f.c.weapon+1);f.sample(.6f);CHECK(last()==.6f && armed.load()==1);
    f.shoulder(true);
    start=calls;CHECK(NADSF_Bind(active_generation,f.c.request,f.c.weapon+1)==1 && calls==start+1 && approximately(last(),90*RAD_PER_DEG));
    f.sample();CHECK(approximately(last(),90*RAD_PER_DEG) && f.stats().binds==1);pass("type4/new unbound6 pass through; Bind starts shoulder easing from hip in the same update");
    f.top(6,5,f.c.weapon+2);f.controls(0,true);start=calls;
    CHECK(NADSF_Bind(active_generation,f.c.request,f.c.weapon+2)==1 && calls==start);f.sample(.2f);CHECK(last()==.2f);
    f.controls();pass("Bind during ADS does not overwrite native zoom");
    start=calls;CHECK(NADSF_Bind(active_generation,f.c.request+0xE8,f.c.weapon+2)==0 && calls==start);
    CHECK(NADSF_Bind(active_generation,f.c.request,f.c.weapon+3)==0 && calls==start);pass("Bind rejects noncurrent record or mismatched weapon without immediate write");
    start=calls;CHECK(end_current()==1 && calls==start && f.stats().installed==0);CHECK(end_current()==1 && calls==start);
    reinterpret_cast<Setter>(callback())(reinterpret_cast<void*>(f.c.camera),.7f);CHECK(last()==.7f);pass("End restores slot without cached FOV restore; cached callbacks remain forwarding");
    const uint64_t stale=active_generation;f.begin();CHECK(active_generation!=stale);start=calls;
    CHECK(NADSF_Bind(stale,f.c.request,f.c.weapon)==0 && NADSF_End(stale)==0 && armed.load()==1 && calls==start);
    NADSF_Stats bad{};bad.size=sizeof bad;bad.abi=1;CHECK(NADSF_ReadStats(0,&bad)==0 && NADSF_ReadStats(stale,&bad)==0);
    uint64_t busy=UINT64_MAX;CHECK(NADSF_Begin(&f.c,&busy)==0 && busy==0);CHECK(end_current()==1);pass("stale token and BUSY cannot affect another session");
    for(unsigned failure=0;failure<5;++failure) {
        f.begin();
        if(failure==0)put<uint8_t>(f.generations+3,2);
        if(failure==1)put<uint64_t>(f.units+3*8,f.body_object+8);
        if(failure==2)put<uint32_t>(f.descriptor,1);
        if(failure==3)put<uint64_t>(f.c.context,f.c.camera+8);
        if(failure==4)put<uint64_t>(f.c.game+0x346D560,f.c.context+8);
        f.sample(.8f);CHECK(last()==.8f && armed.load()==0);start=calls;CHECK(end_current()==1 && calls==start);
        if(failure==0)put<uint8_t>(f.generations+3,1);
        if(failure==1)put<uint64_t>(f.units+3*8,f.body_object);
        if(failure==2)put<uint32_t>(f.descriptor,0);
        if(failure==3)put<uint64_t>(f.c.context,f.c.camera);
        if(failure==4)put<uint64_t>(f.c.game+0x346D560,f.c.context);
    }pass("avatar descriptor/body generation/object/current camera lifetime changes disarm and forward");
    f.normal();
    for(uint64_t address:{f.c.game+0x127A11A,f.c.exe+0x30D990,f.c.exe+0x30D980,f.c.exe+0x88}) {
        uint8_t old=0;CHECK(value(address,old));put<uint8_t>(address,old^1);fixture_cas_calls=0;
        CHECK(NADSF_Validate(&f.c)==0 && begin_current(&f.c)==0 && fixture_cas_calls==0);put<uint8_t>(address,old);
    }pass("literal callsite getter setter and PE drift refuse before CAS");
    fixture_slot_readonly=true;f.fp();fixture_cas_calls=0;CHECK(begin_current(&f.c)==0 && fixture_cas_calls==0);fixture_slot_readonly=false;
    fixture_cas_calls=0;fixture_foreign_cas_at=1;fixture_foreign_value=reinterpret_cast<uint64_t>(foreign_setter);
    CHECK(begin_current(&f.c)==0 && reserved.load()==0);uint64_t actual=0;CHECK(value(f.api+0x80,actual) && actual==fixture_foreign_value);
    fixture_foreign_cas_at=0;put<uint64_t>(f.api+0x80,reinterpret_cast<uint64_t>(synthetic_setter));pass("read-only slots rejected; CAS preserves foreign pointer replacements");
    // Successful install, uncertain immediate apply result, failed rollback.
    f.fp();mutation_address=f.c.request+8;mutation_value=f.c.weapon+1;fixture_cas_calls=0;fixture_cas_fail_at=2;
    CHECK(begin_current(&f.c)==2 && reserved.load()==1 && armed.load()==0 && active_generation==owned_generation);
    mutation_address=0;fixture_cas_fail_at=0;fixture_slot_unreadable=true;CHECK(NADSF_End(active_generation)==0 && owned_generation==active_generation);
    CHECK(f.stats().installed==1);fixture_slot_unreadable=false;start=calls;CHECK(end_current()==1 && calls==start);pass("partial Begin2 retains generation until End repairs pointer with no FOV replay");
    f.begin();fixture_slot_readonly=true;start=calls;CHECK(end_current()==0 && reserved.load()==1 && armed.load()==0 && calls==start);
    fixture_slot_readonly=false;CHECK(end_current()==1 && calls==start);pass("End protection failure retains only its own cleanup reservation");
    f.begin();start=calls;put<uint64_t>(f.api+0x80,reinterpret_cast<uint64_t>(foreign_setter));CHECK(end_current()==1 && calls==start);
    CHECK(value(f.api+0x80,actual) && actual==reinterpret_cast<uint64_t>(foreign_setter));put<uint64_t>(f.api+0x80,reinterpret_cast<uint64_t>(synthetic_setter));
    pass("End never overwrites a foreign slot owner");
    f.begin();put<uint32_t>(f.c.avatar_owner+0x53E9B8,0xffffffff);f.controls(2);f.sample();CHECK(approximately(last(),90*RAD_PER_DEG));
    CHECK(end_current()==1);pass("no weapon/model generation dependency during pose suspension");
    f.begin();f.sample(.111f);const NADSF_Stats completed=f.stats();f.degrees(105);
    setter_reached=CreateEventW(nullptr,TRUE,FALSE,nullptr);setter_continue=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    HANDLE stats_done=CreateEventW(nullptr,TRUE,FALSE,nullptr);CHECK(setter_reached && setter_continue && stats_done);
    std::thread blocked_setter([&]{f.sample(.222f);});CHECK(WaitForSingleObject(setter_reached,3000)==WAIT_OBJECT_0);
    // Simulate a freshly published health failure while the camera setter still
    // owns policy_lock. Diagnostics may be old; health must not be cached.
    armed.store(0,std::memory_order_release);error(OWNER_MISMATCH);
    NADSF_Stats concurrent{};concurrent.size=sizeof concurrent;concurrent.abi=1;uint32_t stats_result=0;
    std::thread reading([&]{stats_result=NADSF_ReadStats(active_generation,&concurrent);SetEvent(stats_done);});
    CHECK(WaitForSingleObject(stats_done,1000)==WAIT_OBJECT_0);
    CHECK(stats_result==1 && concurrent.installed==1 && concurrent.armed==0 && concurrent.error==OWNER_MISMATCH);
    CHECK(concurrent.last_native==completed.last_native && concurrent.last_applied==completed.last_applied
        && concurrent.source_degrees==completed.source_degrees);
    NADSF_Stats invalid{};invalid.size=sizeof invalid;invalid.abi=1;
    CHECK(NADSF_ReadStats(active_generation+1,&invalid)==0 && NADSF_Error()==TOKEN_MISMATCH);
    invalid.abi=2;CHECK(NADSF_ReadStats(active_generation,&invalid)==0 && NADSF_Error()==INVALID_CONFIG);
    invalid.abi=1;invalid.size=sizeof invalid-4;
    CHECK(NADSF_ReadStats(active_generation,&invalid)==0 && NADSF_Error()==INVALID_CONFIG);
    CHECK(NADSF_ReadStats(active_generation,reinterpret_cast<NADSF_Stats*>(1))==0);
    SetEvent(setter_continue);blocked_setter.join();reading.join();
    CloseHandle(setter_reached);CloseHandle(setter_continue);CloseHandle(stats_done);setter_reached=nullptr;setter_continue=nullptr;
    const NADSF_Stats after_setter=f.stats();CHECK(after_setter.last_native==.222f && after_setter.source_degrees==105
        && after_setter.last_applied==105*RAD_PER_DEG && after_setter.armed==0);
    CHECK(end_current()==1);f.degrees(90);
    pass("ReadStats completes during a blocked setter with fresh health, completed angles, and strict token/ABI/pointer guards");

    f.begin();f.sample(.333f);const NADSF_Stats coherent=f.stats();
    // An interrupted atomic publication must yield the cached whole tuple in
    // one attempt, rather than spin or combine different setter frames.
    display_sequence.fetch_add(1,std::memory_order_seq_cst);
    display_native.store(.999f,std::memory_order_seq_cst);display_degrees.store(179,std::memory_order_seq_cst);
    const NADSF_Stats interrupted=f.stats();
    CHECK(interrupted.last_native==coherent.last_native && interrupted.last_applied==coherent.last_applied
        && interrupted.source_degrees==coherent.source_degrees);
    display_native.store(policy.last_native,std::memory_order_seq_cst);display_degrees.store(policy.source_degrees,std::memory_order_seq_cst);
    display_sequence.fetch_add(1,std::memory_order_seq_cst);
    CHECK(end_current()==1);pass("in-progress diagnostic publication returns the last complete tuple without spinning");

    f.fp();f.degrees(105);f.controls(0,true);start=calls;
    CHECK(begin_current(&f.c)==1 && calls==start);const NADSF_Stats new_display=f.stats();
    CHECK(new_display.last_native==0 && new_display.last_applied==0 && new_display.source_degrees==105);
    f.sample(.456f);const NADSF_Stats before_busy=f.stats();uint64_t busy_display=UINT64_MAX;
    CHECK(NADSF_Begin(&f.c,&busy_display)==0 && busy_display==0);const NADSF_Stats after_busy=f.stats();
    CHECK(after_busy.last_native==before_busy.last_native && after_busy.last_applied==before_busy.last_applied
        && after_busy.source_degrees==before_busy.source_degrees && after_busy.error==BUSY);
    CHECK(end_current()==1);f.degrees(90);
    pass("new generations reset old display angles while BUSY Begin preserves the active owner's tuple");
    f.begin();setter_reached=CreateEventW(nullptr,TRUE,FALSE,nullptr);setter_continue=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    CHECK(setter_reached && setter_continue);std::atomic<uint32_t> ended{0};
    std::thread in_flight([&]{f.sample();});CHECK(WaitForSingleObject(setter_reached,3000)==WAIT_OBJECT_0);
    std::thread ending([&]{CHECK(end_current()==1);ended.store(1);});while(armed.load())SwitchToThread();CHECK(ended.load()==0);
    SetEvent(setter_continue);in_flight.join();ending.join();CloseHandle(setter_reached);CloseHandle(setter_continue);setter_reached=nullptr;setter_continue=nullptr;
    CHECK(ended.load()==1);pass("End drains in-flight overridden setter before restoring owned slot");
    uint8_t code_after[64]{};CHECK(read(reinterpret_cast<uint64_t>(synthetic_setter),code_after,64));CHECK(std::memcmp(code_before,code_after,64)==0);
    pass("setter executable bytes unchanged");std::printf("Native FOV fixture PASS: %llu cases\n",static_cast<unsigned long long>(cases));return 0;
}
