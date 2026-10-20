// Private synthetic buffers/callbacks only. No actual game process is accessed.
#define NADSB_FIXTURE
#include "native_ads_blur.cpp"
#include <cstdio>
#include <cstdlib>
#include <thread>
#define CHECK(x) do{if(!(x)){std::fprintf(stderr,"FAIL %d: %s error=%u\n",__LINE__,#x,NADSB_Error());std::abort();}}while(0)
static uint64_t active_generation=0,cases=0,calls=0;
struct Record {void* provider;uint64_t packed;uint32_t hash;const void* input;uint8_t bytes[24];};
static Record records[4096]{};
static HANDLE setter_reached=nullptr,setter_continue=nullptr;
static uint64_t mutation_address=0;static uint32_t mutation_value=0;
__declspec(noinline) static void synthetic_setter(void* object,uint64_t packed,uint32_t hash,const void* input) {
    CHECK(calls<4096);auto& r=records[calls++];r.provider=object;r.packed=packed;r.hash=hash;r.input=input;
    std::memcpy(r.bytes,input,24);
    if(mutation_address)std::memcpy(reinterpret_cast<void*>(mutation_address),&mutation_value,4);
    if(setter_reached) {SetEvent(setter_reached);WaitForSingleObject(setter_continue,INFINITE);}
}
__declspec(noinline) static void foreign_setter(void*,uint64_t,uint32_t,const void*) {}
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
static uint32_t begin_current(const NADSB_Config* c) {
    uint64_t token=UINT64_MAX;const uint32_t result=NADSB_Begin(c,&token);
    if(result==0)CHECK(token==0);else {CHECK((result==1 || result==2) && token && token!=active_generation);active_generation=token;}
    return result;
}
static uint32_t end_current() {return NADSB_End(active_generation);}
static float last() {float f=0;std::memcpy(&f,records[calls-1].bytes+8,4);return f;}
static void pass(const char* name) {++cases;std::printf("PASS %s\n",name);}
struct Fixture {
    NADSB_Config c{};uint64_t controller=0,descriptor=0,registry=0,units=0,generations=0,body_object=0;
    uint64_t system=0,object=0,table=0,pool=0,param_descriptor=0,param_rows=0,buckets=0,ids=0,classes=0,chains=0,blobs=0,blob=0,other_blob=0;
    uint64_t packed=0;Setter invoke=nullptr;uint8_t input[24]{};
    Fixture() {
        c.size=sizeof c;c.abi=1;c.game=allocate(0x4744000,PAGE_EXECUTE_READWRITE);c.exe=allocate(0x39E8000);
        fake_image(c.game,0x6AB3B43F,0x4744000);fake_image(c.exe,0x6AB382E4,0x39E8000);
        // Literal current captures, independently transcribed from batches2033/2058/2059.
        literal(c.exe+0x310050,"48895c24084889742410574883ec404c8b11498bd94c8bca418bf8448bc249c1e920488d542460488bf141ff5238");
        literal(c.exe+0x30FFC0,"418bc048c1e0208bca480bc1c3");
        literal(c.exe+0x62ADB0,"405383b9a8000000004c8bda48897c2418488bd9c744241000000000");
        literal(c.exe+0x310140,"e97b9f3100");
        literal(c.exe+0x62A0C0,"48895c2408574883ec200fb60133ff488bd984c0743e3c2e752f8bd34533c02bd1e85ab7faff48c1e82069c895e9d15b");
        c.context=allocate(0x3000);c.camera=allocate(0x1000);c.avatar_owner=allocate(0x540000);
        c.avatar=0x333;c.body=0x400003;c.weapon=0x444;
        controller=allocate(0x1000);descriptor=allocate(0x1000);registry=allocate(0x1000);units=allocate(0x1000);
        generations=allocate(0x1000);body_object=allocate(0x1000);
        put<uint64_t>(c.game+0x346D560,c.context);put<uint64_t>(c.context,c.camera);
        put<uint64_t>(c.game+0x3326D20,c.avatar_owner);put<uint64_t>(c.game+0x347CE70,controller);
        put<uint32_t>(c.avatar_owner+0x6C,1);put<uint64_t>(c.avatar_owner+0x110,descriptor);
        put<uint32_t>(descriptor+8,c.avatar);put<uint32_t>(descriptor+12,c.body);
        put<uint64_t>(c.exe+0x1A100F0,registry);put<uint32_t>(registry+0x98,16);
        put<uint64_t>(registry+0x88,units);put<uint64_t>(registry+0xA0,generations);
        put<uint8_t>(generations+3,1);put<uint64_t>(units+3*8,body_object);
        system=allocate(0x32000);object=allocate(0x1000);const uint64_t root=allocate(0x1000),apis=allocate(0x1000),hash_api=allocate(0x1000);
        put<uint64_t>(c.game+0x3326468,root);put<uint64_t>(root+0x18,system);put<uint64_t>(system+0xDC8,object);
        put<uint64_t>(c.game+0x3326308,apis);put<uint64_t>(apis+0xC0,hash_api);put<uint64_t>(hash_api+0x28,c.exe+0x310140);
        put<uint64_t>(object,c.exe+0x1677DC8);put<uint64_t>(c.exe+0x1677DC8+0x38,c.exe+0x62ADB0);
        put<uint64_t>(c.exe+0x1677DC8+0x28,c.exe+0x2DD5E0);
        put<uint64_t>(system+0xDD8,c.exe+0x27CC5E0);put<uint64_t>(c.exe+0x27CC5E0+0x28,c.exe+0x30FFC0);
        table=c.exe+0x27CC638;put<uint64_t>(system+0xDE8,table);put<uint64_t>(table,reinterpret_cast<uint64_t>(synthetic_setter));
        put<uint64_t>(table+8,c.exe+0x3100C0);fixture_target=synthetic_setter;
        pool=allocate(0x1000);const uint64_t param_buckets=allocate(0x1000),param_descriptors=allocate(0x1000);
        param_descriptor=allocate(0x1000);param_rows=allocate(0x1000);
        put<uint64_t>(c.game+0x3326A38,pool);put<uint64_t>(pool+0x278,param_buckets);put<uint32_t>(pool+0x280,8);
        put<uint32_t>(pool+0x284,UINT32_MAX);put<uint32_t>(pool+0x288,1);
        for(unsigned i=0;i<8;++i)put<uint32_t>(param_buckets+i*8,UINT32_MAX);
        put<uint32_t>(param_buckets+(c.weapon%8)*8,c.weapon);put<uint32_t>(param_buckets+(c.weapon%8)*8+4,1);
        put<uint64_t>(pool+0x290,param_descriptors);put<uint64_t>(param_descriptors+8,param_descriptor);
        put<uint64_t>(pool+0x298,param_rows);put<uint32_t>(param_descriptor+8,c.weapon);put<uint8_t>(param_descriptor+20,1);
        put<uint32_t>(param_rows+8,16);put<uint32_t>(param_rows+12,17);
        put<uint32_t>(system+0x348+16*0x30,107);put<uint32_t>(system+0x348+17*0x30,108);
        buckets=allocate(0x1000);ids=allocate(0x1000);classes=allocate(0x1000);chains=allocate(0x1000);blobs=allocate(0x1000);
        put<uint64_t>(object+0x98,buckets);put<uint32_t>(object+0x90,54);put<uint32_t>(object+0x94,54);
        put<uint32_t>(object+0xA8,38);put<uint32_t>(object+0xAC,39);put<uint32_t>(object+0xB8,92);put<uint32_t>(object+0xBC,256);
        put<uint64_t>(object+0xC8,ids);put<uint64_t>(object+0xD0,classes);put<uint64_t>(object+0xD8,chains);put<uint64_t>(object+0xE8,blobs);
        for(unsigned i=0;i<54;++i)put<uint32_t>(buckets+i*12+8,0xFFFFFFFE);
        put<uint32_t>(buckets+(107%39)*12,107);put<uint32_t>(buckets+(107%39)*12+4,6);put<uint32_t>(buckets+(107%39)*12+8,0x7FFFFFFF);
        put<uint32_t>(ids+6*4,107);put<uint32_t>(classes+6*4,0xC823B21C);
        // The entity108 bucket deliberately collides into overflow40 (>modulus39).
        put<uint32_t>(buckets+(108%39)*12,999);put<uint32_t>(buckets+(108%39)*12+8,40);
        put<uint32_t>(buckets+40*12,108);put<uint32_t>(buckets+40*12+4,3);put<uint32_t>(buckets+40*12+8,0x7FFFFFFF);
        put<uint32_t>(ids+3*4,108);put<uint32_t>(classes+3*4,0xC823B21C);put<uint32_t>(chains+3*4,4);
        put<uint32_t>(ids+4*4,108);put<uint32_t>(classes+4*4,0x35B0F6C2);put<uint32_t>(chains+4*4,5);
        put<uint32_t>(ids+5*4,108);put<uint32_t>(classes+5*4,0xF7A3101F);
        blob=allocate(0x1000);other_blob=allocate(0x1000);put<uint64_t>(blobs+5*8,blob);
        for(uint64_t b:{blob,other_blob}) {
            // Actual native property keys, including unrelated close-near max.
            put<uint32_t>(b+4,4);put<uint32_t>(b+0x10,0xA7990477);put<uint32_t>(b+0x14,0xF07FC12E);
            put<uint32_t>(b+0x18,0x209F72CF);put<uint32_t>(b+0x1C,0x0DB64441);
            for(unsigned i=0;i<4;++i) {put<uint32_t>(b+0x20+i*16,2);put<float>(b+0x28+i*16,.5f);}
        }
        packed=0xF7A3101F0000006CULL;
        // sub rsp,28; mov r11,table; call [r11]; add rsp,28; ret.
        const uint64_t site=c.game+0x100A80B;literal(site-14,"4883ec2849bb");put<uint64_t>(site-8,table);
        literal(site,"41ff134883c428c3");CHECK(FlushInstructionCache(GetCurrentProcess(),reinterpret_cast<void*>(site-14),22));
        invoke=reinterpret_cast<Setter>(site-14);normal();
    }
    void controls(uint32_t mask=0,bool active=false,bool guard=false) {
        put<uint32_t>(controller,mask);put<uint8_t>(controller+4,active?1:0);put<uint8_t>(controller+5,guard?1:0);
    }
    void top(uint32_t kind=6,uint32_t tail=2) {
        put<uint32_t>(c.context+0x1F8,0);put<uint32_t>(c.context+0x1FC,tail);
        c.request=c.context+0x200+((tail+31)%32)*0xE8;
        put<uint32_t>(c.request,kind);put<uint32_t>(c.request+4,c.avatar);put<uint32_t>(c.request+8,c.weapon);put<uint32_t>(c.request+12,c.body);
    }
    void normal() {controls();put<uint8_t>(c.avatar_owner+0x53E886,0);put<uint8_t>(c.avatar_owner+0x53E88E,0);top(4);variant();}
    void variant(float f=1.5f,uint32_t type=2) {for(unsigned i=0;i<24;++i)input[i]=static_cast<uint8_t>(i+0x80);std::memcpy(input,&type,4);std::memcpy(input+8,&f,4);}
    void begin() {normal();top();CHECK(begin_current(&c)==1);}
    void sample(uint32_t hash=0xF07FC12E) {invoke(reinterpret_cast<void*>(object),packed,hash,input);}
    NADSB_Stats stats() {NADSB_Stats s{};s.size=sizeof s;s.abi=1;CHECK(NADSB_ReadStats(reserved.load()?active_generation:0,&s)==1);return s;}
};
int main() {
    Fixture f;CHECK(f.stats().installed==0 && NADSB_Validate(&f.c)==1 && fixture_cas_calls==0 && calls==0);
    CHECK(begin_current(&f.c)==0 && reserved.load()==0);pass("normal4 preflight is read-only; Begin requires the exact owned native6 record");
    uint8_t blob_before[512]{};CHECK(read(f.blob,blob_before,sizeof blob_before));put<uint32_t>(f.blob+4,22);
    // Actual 22-key ordering and three scalar records from batch2052 row5.
    // No production constants or mirrored synthetic layout computes offsets.
    literal(f.blob+0x10,"c7cffea54144b60d56db638ee531af324da6cbf20cdf8eb1c0734c8300a017f63a124c596a74d51e2ec17ff0dcc65cf88f96b7bc90b771ec7426b9a3cf729f200e260ff9e77b335418701472788f10d8770499a73046a41f");
    literal(f.blob+0x108,"0200000000000000802e073b00000000");literal(f.blob+0x158,"0200000000000000802e073b00000000");
    literal(f.blob+0x1A8,"0200000000000000802e873a00000000");CHECK(NADSB_Validate(&f.c)==1);f.top();CHECK(begin_current(&f.c)==1);
    CHECK(policy.sources[0].fields[0]==f.blob+0x1A8 && policy.sources[0].fields[1]==f.blob+0x108 && policy.sources[0].fields[2]==f.blob+0x158);
    CHECK(end_current()==1);std::memcpy(reinterpret_cast<void*>(f.blob),blob_before,sizeof blob_before);
    pass("literal captured22-field schema resolves native near far and far-close offsets independently");
    uint64_t start=calls;f.begin();CHECK(calls==start+3 && f.stats().immediate_applies==3 && policy.source_count==1);
    for(uint64_t i=start;i<calls;++i)CHECK(records[i].packed==0xF7A3101F0000006CULL && records[i].hash!=0x0DB64441);
    CHECK(last()==0);pass("Begin immediately zeros only three secondary-weapon DoF maxima through the original setter");
    uint8_t preserved[24]{};std::memcpy(preserved,f.input,24);
    for(uint32_t hash:{0xA7990477u,0xF07FC12Eu,0x209F72CFu}) {f.sample(hash);CHECK(last()==0 && records[calls-1].input!=f.input);
        uint8_t expected[24]{};std::memcpy(expected,preserved,24);std::memset(expected+8,0,4);CHECK(std::memcmp(expected,records[calls-1].bytes,24)==0);}
    CHECK(std::memcmp(preserved,f.input,24)==0 && f.stats().replaced==3);pass("owned callback changes only float payload; native Variant bytes stay untouched");
    for(uint32_t hash:{0x0DB64441u,0x67414413u,0x6E4BE2C7u,0x46573431u,0u}) {f.sample(hash);CHECK(records[calls-1].input==f.input && last()==1.5f);}
    pass("other properties and unmixed bone-style hashes are exact pass-through");
    setter_hook(reinterpret_cast<void*>(f.object),f.packed,0xF07FC12E,f.input);CHECK(records[calls-1].input==f.input);
    f.invoke(reinterpret_cast<void*>(f.object+8),f.packed,0xF07FC12E,f.input);CHECK(records[calls-1].input==f.input);
    for(uint64_t packed:{f.packed+1,static_cast<uint64_t>(0x8D346F4B0000006CULL)}) {f.invoke(reinterpret_cast<void*>(f.object),packed,0xF07FC12E,f.input);CHECK(records[calls-1].input==f.input);}
    CHECK(armed.load()==1);pass("wrong caller provider entity or concrete component class is exact pass-through");
    put<uint8_t>(f.c.avatar_owner+0x53E886,1);f.sample();CHECK(last()==0);f.controls(0,true);f.sample();CHECK(last()==0);
    f.controls();put<uint8_t>(f.c.avatar_owner+0x53E886,0);pass("hip shoulder and full ADS all remove only the same DoF maxima");
    for(uint32_t mask:{1u,4u,8u,0x20u,0x40u}) {f.controls(mask);f.sample();CHECK(records[calls-1].input==f.input && armed.load()==1);}
    f.controls(2);f.sample();CHECK(last()==0);f.controls(2,false,true);f.sample();CHECK(records[calls-1].input==f.input);
    f.controls();put<uint8_t>(f.c.avatar_owner+0x53E88E,4);f.sample();CHECK(records[calls-1].input==f.input);
    put<uint8_t>(f.c.avatar_owner+0x53E88E,0);pass("unsafe masks seated state and guard preserve native effects");CHECK(end_current()==1);
    for(unsigned mode=0;mode<3;++mode) {f.begin();if(mode==0)f.top(4);if(mode==1)put<uint32_t>(f.c.request+8,f.c.weapon+1);if(mode==2)f.top(6,3);
        f.sample();CHECK(armed.load()==0 && NADSB_Error()==OWNER_MISMATCH && records[calls-1].input==f.input);CHECK(end_current()==1);}
    pass("retired replaced or foreign camera requests disarm without touching any effect");
    for(unsigned mode=0;mode<4;++mode) {f.begin();const uint64_t at=mode==0?f.descriptor:mode==1?f.generations+3:mode==2?f.c.context:f.units+3*8;
        const size_t n=mode==1?1:mode==0?4:8;uint64_t old=0;std::memcpy(&old,reinterpret_cast<void*>(at),n);
        const uint64_t changed=old+1;std::memcpy(reinterpret_cast<void*>(at),&changed,n);f.sample();
        CHECK(armed.load()==0 && records[calls-1].input==f.input);std::memcpy(reinterpret_cast<void*>(at),&old,n);CHECK(end_current()==1);}
    pass("avatar body generation object and context ownership changes passively disarm");
    for(unsigned mode=0;mode<8;++mode) {f.begin();uint64_t at=0;size_t n=8;
        if(mode==0){at=f.param_descriptor;n=4;}if(mode==1){at=f.param_rows+12;n=4;}if(mode==2){at=f.system+0x348+17*0x30;n=4;}
        if(mode==3)at=f.object+0xC8;if(mode==4)at=f.blobs+5*8;if(mode==5){at=f.blob+0x10;n=4;}
        if(mode==6){at=f.blob+0x20;n=4;}if(mode==7){at=f.classes+5*4;n=4;}
        uint64_t old=0;std::memcpy(&old,reinterpret_cast<void*>(at),n);const uint64_t changed=old+1;
        std::memcpy(reinterpret_cast<void*>(at),&changed,n);f.sample();CHECK(armed.load()==0 && NADSB_Error()==UNIT_MISMATCH && records[calls-1].input==f.input);
        std::memcpy(reinterpret_cast<void*>(at),&old,n);CHECK(end_current()==1);}
    pass("parameter descriptor rows effect entities array identities blobs schemas and classes retire the helper");
    f.begin();for(unsigned mode=0;mode<3;++mode) {f.variant(mode==1?NAN:mode==2?INFINITY:1.5f,mode==0?4:2);f.sample();CHECK(records[calls-1].input==f.input);}
    CHECK(armed.load()==1);pass("nonfloat and nonfinite Variants forward bit-exactly");CHECK(end_current()==1);
    f.normal();put<uint32_t>(f.chains+4*4,0);CHECK(NADSB_Validate(&f.c)==0 && NADSB_Error()==NO_SOURCE);
    f.top();CHECK(begin_current(&f.c)==0 && NADSB_Error()==NO_SOURCE && reserved.load()==0);put<uint32_t>(f.chains+4*4,5);
    pass("ordinary weapon with no eligible DoF component reports optional NO_SOURCE without a lease");
    f.normal();put<uint32_t>(f.blob+0x20,4);CHECK(NADSB_Validate(&f.c)==0 && NADSB_Error()==SOURCE_INVALID);put<uint32_t>(f.blob+0x20,2);
    put<uint32_t>(f.blob+0x18,0xF07FC12E);CHECK(NADSB_Validate(&f.c)==0 && NADSB_Error()==SOURCE_INVALID);put<uint32_t>(f.blob+0x18,0x209F72CF);
    pass("known DoF component rejects wrong types duplicate keys and incomplete schema");
    f.normal();CHECK(NADSB_Validate(&f.c)==1);pass("provider overflow bucket40 is valid beyond modulus39 within storage54");
    put<uint32_t>(f.buckets+(108%39)*12+8,54);CHECK(NADSB_Validate(&f.c)==0 && NADSB_Error()==SOURCE_INVALID);put<uint32_t>(f.buckets+(108%39)*12+8,40);
    put<uint32_t>(f.chains+4*4,4);CHECK(NADSB_Validate(&f.c)==0);put<uint32_t>(f.chains+4*4,5);
    pass("out-of-storage buckets and component chain cycles are bounded and refused");
    f.normal();put<uint32_t>(f.classes+6*4,0xF7A3101F);put<uint64_t>(f.blobs+6*8,f.other_blob);f.top();start=calls;CHECK(begin_current(&f.c)==1);
    CHECK(policy.source_count==2 && calls==start+6);f.invoke(reinterpret_cast<void*>(f.object),0xF7A3101F0000006BULL,0xA7990477,f.input);CHECK(last()==0);
    CHECK(end_current()==1);put<uint32_t>(f.classes+6*4,0xC823B21C);put<uint64_t>(f.blobs+6*8,0);
    pass("two independently eligible weapon rows are scoped separately without assuming both exist");
    for(uint64_t at:{f.c.exe+0x310050,f.c.exe+0x30FFC0,f.c.exe+0x62ADB0,f.c.exe+0x310140,f.c.exe+0x62A0C0,f.c.game+0x100A80B}) {
        f.normal();uint8_t old=0;CHECK(value(at,old));put<uint8_t>(at,old^1);CHECK(NADSB_Validate(&f.c)==0 && NADSB_Error()==CODE_MISMATCH);put<uint8_t>(at,old);
    }pass("independent current setter lookup packer parameter-hash and exact callsite fingerprints are mandatory");
    f.begin();const auto stale=active_generation;CHECK(end_current()==1);f.begin();uint64_t busy=99;
    CHECK(NADSB_Begin(&f.c,&busy)==0 && busy==0 && NADSB_End(stale)==0 && armed.load()==1);
    NADSB_Stats stats{};stats.size=80;stats.abi=1;CHECK(NADSB_ReadStats(0,&stats)==0 && NADSB_ReadStats(stale,&stats)==0);
    pass("BUSY and stale tokens cannot observe or alter a later owned session");CHECK(end_current()==1);
    f.normal();f.top();fixture_slot_readonly=true;CHECK(begin_current(&f.c)==0 && reserved.load()==0);fixture_slot_readonly=false;
    fixture_foreign_cas_at=fixture_cas_calls+1;fixture_foreign_value=reinterpret_cast<uint64_t>(foreign_setter);CHECK(begin_current(&f.c)==0 && reserved.load()==0);
    uint64_t target=0;CHECK(value(f.table,target) && target==fixture_foreign_value);fixture_foreign_cas_at=0;put<uint64_t>(f.table,reinterpret_cast<uint64_t>(synthetic_setter));
    pass("read-only and foreign-owned dispatch reject without code writes or foreign overwrite");
    f.normal();f.top();mutation_address=f.c.request+8;mutation_value=f.c.weapon+1;fixture_cas_fail_at=fixture_cas_calls+2;
    CHECK(begin_current(&f.c)==2 && active_generation && reserved.load()==1 && armed.load()==0);
    mutation_address=0;fixture_cas_fail_at=0;fixture_slot_unreadable=true;CHECK(end_current()==0 && reserved.load()==1);
    fixture_slot_unreadable=false;CHECK(end_current()==1 && reserved.load()==0);pass("partial Begin2 retains a token until retryable cleanup succeeds");
    f.begin();fixture_slot_readonly=true;CHECK(end_current()==0 && reserved.load()==1);fixture_slot_readonly=false;CHECK(end_current()==1);
    f.begin();put<uint64_t>(f.table,reinterpret_cast<uint64_t>(foreign_setter));CHECK(end_current()==1);
    CHECK(value(f.table,target) && target==reinterpret_cast<uint64_t>(foreign_setter));put<uint64_t>(f.table,reinterpret_cast<uint64_t>(synthetic_setter));
    pass("End retries owned slot protection failure and preserves a foreign replacement");
    f.begin();start=calls;CHECK(end_current()==1 && calls==start);setter_hook(reinterpret_cast<void*>(f.object),f.packed,0xF07FC12E,f.input);
    CHECK(records[calls-1].input==f.input);pass("End never replays old effect values and resident cached callbacks forward");
    f.begin();setter_reached=CreateEventW(nullptr,TRUE,FALSE,nullptr);setter_continue=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    std::thread writer([&]{f.sample();});CHECK(WaitForSingleObject(setter_reached,1000)==WAIT_OBJECT_0);
    std::atomic<bool> finished{false};std::thread ending([&]{CHECK(end_current()==1);finished.store(true);});Sleep(20);CHECK(!finished.load());
    SetEvent(setter_continue);writer.join();ending.join();CloseHandle(setter_reached);CloseHandle(setter_continue);setter_reached=nullptr;setter_continue=nullptr;
    pass("End drains the actual adjusted original setter before dispatch restoration");
    f.normal();f.top();fixture_before_arm_reached=CreateEventW(nullptr,TRUE,FALSE,nullptr);fixture_continue_arm=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    uint64_t pending_token=0;uint32_t began=0;std::thread starting([&]{began=NADSB_Begin(&f.c,&pending_token);});
    CHECK(WaitForSingleObject(fixture_before_arm_reached,1000)==WAIT_OBJECT_0 && pending_token!=0);finished.store(false);
    std::thread serialized_end([&]{CHECK(NADSB_End(pending_token)==1);finished.store(true);});Sleep(20);CHECK(!finished.load());
    SetEvent(fixture_continue_arm);starting.join();serialized_end.join();CHECK(began==1 && armed.load()==0 && reserved.load()==0);
    CloseHandle(fixture_before_arm_reached);CloseHandle(fixture_continue_arm);fixture_before_arm_reached=nullptr;fixture_continue_arm=nullptr;
    pass("End serializes with Begin so it cannot acknowledge cleanup before a later arm store");
    std::printf("Native blur fixture PASS: %llu cases\n",static_cast<unsigned long long>(cases));return 0;
}
