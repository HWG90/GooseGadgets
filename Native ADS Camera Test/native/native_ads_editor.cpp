// Fresh native arms/weapon offsets plus paired carrier-depth normalization.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <intrin.h>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <cmath>
#include "native_ads_editor.h"
using Setter=void (*)(uint32_t,uint32_t,const float*);
using Getter=const float* (*)(uint32_t,uint32_t);
static SRWLOCK control_lock=SRWLOCK_INIT,policy_lock=SRWLOCK_INIT;
static constexpr unsigned SLOT_COUNT=4;
static std::atomic<Setter> originals[SLOT_COUNT]{};
static std::atomic<uint32_t> installed{0},armed{0},reserved{0},expired{0},last_error{0};
static std::atomic<uint64_t> seen[2]{},forwarded[2]{},rig_return{0},rotation_return{0};
static std::atomic<uint64_t> getter_return{0},active_generation{0};
static std::atomic<uint64_t> carrier_return{0};
static std::atomic<uint32_t> watched_viewmodel{0};
static std::atomic<uint64_t> weapon_updates{0},zero_restores{0};
static uint64_t slots[SLOT_COUNT]{},slot_image=0;
static bool possible[SLOT_COUNT]{};
// control_lock protects the lease generation and prevents stale GUI handles
// from changing or ending a later preview. Counter zero is never issued.
static uint64_t generation_counter=0,owned_generation=0,retired_generation=0;
// Lifecycle-owned immutable deadline, accessed only under control_lock. Stats
// need policy_lock only when a timed lease has reached its restoration point.
static uint64_t stats_deadline=0;
#if defined(NADSE_FIXTURE)
static uint32_t fixture_cas_calls=0,fixture_cas_fail_at=0;
static uint32_t fixture_foreign_cas_at=0;
static uint64_t fixture_foreign_value=0;
static bool fixture_slot_unreadable=false,fixture_slot_readonly=false,fixture_fail_rollback=false;
static uint64_t fixture_unreadable_slot=0;
static HANDLE fixture_before_arm_reached=nullptr,fixture_continue_arm=nullptr;
static uint64_t* fixture_output_to_check=nullptr;
static bool fixture_generation_published=true;
static uint64_t fixture_reads=0;
static uint64_t fixture_depth_frame=0;
static uint64_t fixture_depth_mutation=0;
static uint8_t fixture_depth_mutation_byte=0;
#endif
static constexpr uint32_t POSITION=0x1FC720,ROTATION=0x1FC880,BRANCH_ROTATION=0x1FC7A0,LOCAL_POSITION=0x1FC450;
static constexpr uint32_t CALLS[2]={0x12887C9,0x12887E9};
static constexpr uint32_t RIG_CALL=0x1288420,ROTATION_CALL=0x12890DB,OBSERVE_CALL=0x1287A41,GRAPH_GETTER=0x2BD870,RIG_NODE=5;
static constexpr uint32_t API_OFFSETS[SLOT_COUNT]={0x38,0x48,0x40,0};
static constexpr uint32_t WRAPPERS[SLOT_COUNT]={POSITION,ROTATION,BRANCH_ROTATION,LOCAL_POSITION};
static constexpr const char* PREFIX[SLOT_COUNT]={
    "48895c24084889742410574883ec20498bf08bfa8bd9e88511eaff4c8b5018b801000000f0410fc182380017008bc04c",
    "48895c24084889742410574883ec20498bf08bfa8bd9e82510eaff4c8b5018b801000000f0410fc182380017008bc04c",
    "48895c24084889742410574881eca0000000440f29b42490000000498bd84863fae8fa10eaff488bc8488bf04c8b0841",
    "40534883ec204863dae86214eaff488bc84c8b0041ff90e8000000488bcb48c1e1064883c124488b40204803c14883c4205bc3"};
enum Error:uint32_t { OK=0,INVALID_CONFIG=1,BUSY=2,READ_FAILED=3,IMAGE_MISMATCH=4,
    CODE_MISMATCH=5,API_MISMATCH=6,OWNER_MISMATCH=7,UNIT_MISMATCH=8,PIN_FAILED=9,
    SLOT_NOT_WRITABLE=10,CAS_MISMATCH=11,CAS_FAULT=12,CLEANUP_PENDING=13,SIGHT_NODE_UNAVAILABLE=14,
    GRAPH_MISMATCH=15,POSE_INVALID=16,TOKEN_MISMATCH=17,DEADLINE_EXPIRED=18 };
struct DepthProbe {uint64_t buckets=0;uint32_t cap=0,start=0,count=0;uint64_t rows[64]{};};
struct DepthData {
    uint64_t pool=0,world=0,settings=0,data=0,resource_table=0,resource_row=0,parameters=0,packed=0;
    uint8_t pool_bytes[0x88]{},data_bytes[0xdc]{},parameter_bytes[16]{},resource_bytes[16]{};
    DepthProbe primary,overrides;float degrees=0,zoom[3]{},coefficient[3]{},near_term[2]{};
};
struct DepthState {
    bool checked=false,code_ok=false,signature_set=false,valid=false,previous_known=false;
    uint32_t signature[4]{};uint64_t next_check=0,retry_at=0,refreshes=0,checks=0;
    float current=0,previous=0,current_reference=0,previous_reference=0;
    NADSE_DepthStats observed{};
    DepthData data;
};
struct DepthObservation {
    uint64_t native_stack=0,generation=0,request=0;uint32_t thread=0;bool ready=false;
    uint8_t frame[0x20]{};
    uint8_t request_state[0x24]{};
};
struct CarrierPending {DepthObservation observation;float delta=0;bool ready=false;};
struct Policy {
    NADSE_Config c{};uint64_t camera=0,controller=0,descriptor=0,object=0,weapon_object=0,deadline=0;
    uint8_t descriptor_bytes[20]{},weapon_bytes[20]{};
    uint64_t graph_vtable=0,graph_links=0,graph_hashes=0;
    bool native_aiming=false,shoulder_aiming=false,full_ads=false,rig_shifted=false,rotation_shifted=false,carrier_shifted=false;
    float baseline[4]{},rotation_baseline[4]{};
    float carrier_baseline[4]{},carrier_written[3]{};uint64_t carrier_poses=0;
    bool carrier_checked=false,carrier_code_ok=false;
    float motion[3]{};
    float ads_placement[3]{};
    bool authored_ads_rotation=false;
    float rotation[4]{0,0,0,1};
    float weight=0,target=1,start_weight=0;uint64_t blend_start=0;
    DepthState depth;
    DepthObservation observation;
    CarrierPending carrier;
};
static Policy policy;
// Display-only values never make a stats reader wait for an engine setter.
// Policy writers remain serialized; a disarmed new Begin resets its own tuple.
struct Display {float blend=0,target=1;};
static Display display_cache; // control_lock only; callbacks never touch it.
static std::atomic<uint32_t> display_sequence{0};
static std::atomic<float> display_blend{0},display_target{1};
static_assert(std::atomic<float>::is_always_lock_free,"Pose diagnostics require lock-free floats");
static void publish_diagnostics(const Policy& p) {
    display_sequence.fetch_add(1,std::memory_order_seq_cst);
    display_blend.store(p.weight,std::memory_order_seq_cst);
    display_target.store(p.target,std::memory_order_seq_cst);
    display_sequence.fetch_add(1,std::memory_order_seq_cst);
}
static void read_diagnostics(NADSE_Stats& s) {
    const uint32_t before=display_sequence.load(std::memory_order_seq_cst);
    if((before&1)==0) {
        const Display next{display_blend.load(std::memory_order_seq_cst),display_target.load(std::memory_order_seq_cst)};
        if(before==display_sequence.load(std::memory_order_seq_cst))display_cache=next;
    }
    s.blend=display_cache.blend;s.target_weight=display_cache.target;
}
static bool read(uint64_t at,void* out,size_t length) {
    if(at<65536 || at>=0x800000000000ULL || length>1024 || at+length>=0x800000000000ULL)return false;
#if defined(NADSE_FIXTURE)
    ++fixture_reads;
#endif
    SIZE_T actual=0;return ReadProcessMemory(GetCurrentProcess(),reinterpret_cast<const void*>(at),out,length,&actual)!=0 && actual==length;
}
template<class T> static bool value(uint64_t at,T& out) {return read(at,&out,sizeof out);}
static bool pointer(uint64_t at,uint64_t& out) {return value(at,out) && out>=65536 && out<0x800000000000ULL;}
static void error(uint32_t code) {last_error.store(code,std::memory_order_release);}
static bool reject(uint32_t code) {error(code);return false;}
static bool image(uint64_t base,uint32_t stamp,uint32_t length) {
    IMAGE_DOS_HEADER dos{};IMAGE_NT_HEADERS64 nt{};
    return read(base,&dos,sizeof dos) && dos.e_magic==IMAGE_DOS_SIGNATURE && dos.e_lfanew>=64 && dos.e_lfanew<=4096
        && read(base+dos.e_lfanew,&nt,sizeof nt) && nt.Signature==IMAGE_NT_SIGNATURE
        && nt.FileHeader.Machine==IMAGE_FILE_MACHINE_AMD64 && nt.OptionalHeader.Magic==IMAGE_NT_OPTIONAL_HDR64_MAGIC
        && nt.FileHeader.TimeDateStamp==stamp && nt.OptionalHeader.SizeOfImage==length;
}
static bool bytes(uint64_t at,const char* hex) {
    uint8_t actual[128]{};const size_t count=std::strlen(hex)/2;
    if(!count || count>sizeof actual || !read(at,actual,count))return false;
    for(size_t i=0;i<count;++i) {
        auto digit=[](char c)->uint8_t{return static_cast<uint8_t>(c<='9'?c-'0':c-'a'+10);};
        if(actual[i]!=static_cast<uint8_t>((digit(hex[i*2])<<4)|digit(hex[i*2+1])))return false;
    }
    return true;
}
static bool executable(uint64_t at) {
    MEMORY_BASIC_INFORMATION r{};
    if(VirtualQuery(reinterpret_cast<const void*>(at),&r,sizeof r)!=sizeof r || r.State!=MEM_COMMIT || r.Type!=MEM_IMAGE)return false;
    return r.Protect==PAGE_EXECUTE_READ || r.Protect==PAGE_EXECUTE_READWRITE || r.Protect==PAGE_EXECUTE_WRITECOPY;
}
static bool unit_object(const NADSE_Config& c,uint32_t ref,uint64_t& object) {
    uint64_t registry=0,gens=0,objects=0;uint32_t cap=0;uint8_t generation=0;
    const uint32_t index=ref&0x3fffff;
    return pointer(c.exe+0x1A100F0,registry) && value(registry+0x98,cap) && index<cap && cap<=0x400000
        && pointer(registry+0xA0,gens) && value(gens+index,generation)
        && generation==static_cast<uint8_t>(ref>>22) && pointer(registry+0x88,objects)
        && pointer(objects+static_cast<uint64_t>(index)*8,object);
}
static bool ownership(Policy& p,bool entering) {
    const NADSE_Config& c=p.c;
    uint64_t ctx=0,owner=0,camera=0,controller=0,descriptor=0,object=0,weapon_object=0;
    uint32_t count=0,head=0,tail=0,viewmodel=0;
    uint8_t d[20]{},wd[20]{},flags[24]{},controller_bytes[6]{};uint32_t request[4]{};
    if(!pointer(c.game+0x346D560,ctx) || ctx!=c.context || !pointer(ctx,camera)
        || !pointer(c.game+0x3326D20,owner) || owner!=c.avatar_owner
        || !pointer(c.game+0x347CE70,controller) || !read(controller,controller_bytes,sizeof controller_bytes)
        || !value(owner+0x6C,count) || count==0 || count>8 || c.avatar_index>=count
        || !pointer(owner+0x110+static_cast<uint64_t>(c.avatar_index)*8,descriptor)
        || !read(descriptor,d,sizeof d) || !read(owner+0x53E880+static_cast<uint64_t>(c.avatar_index)*0x1238,flags,sizeof flags)
        || !value(owner+0x53E9B8+static_cast<uint64_t>(c.avatar_index)*0x1238,viewmodel)
        || viewmodel!=c.viewmodel || !unit_object(c,c.viewmodel,object) || !unit_object(c,c.weapon_unit,weapon_object)
        || !read(c.weapon_descriptor,wd,sizeof wd) || !value(ctx+0x1F8,head) || !value(ctx+0x1FC,tail)
        || head>=32 || tail>=32)return false;
    uint32_t avatar=0,body=0;std::memcpy(&avatar,d+8,4);std::memcpy(&body,d+12,4);
    uint32_t weapon=0,weapon_unit=0;std::memcpy(&weapon,wd+8,4);std::memcpy(&weapon_unit,wd+12,4);
    if(avatar!=c.avatar || body!=c.body || weapon!=c.weapon || weapon_unit!=c.weapon_unit || (flags[14]&4)!=0)return false;
    for(unsigned i=0;i<6;++i)if(i!=4 && controller_bytes[i])return false;
    // Bit48 belongs to the native camera lifecycle. Normal accepted aim uses
    // agreeing character bits82/125 even while a forced kind6 keeps48 clear.
    // An inconsistent pair cannot claim shoulder presentation; no extra reads.
    p.native_aiming=(flags[6]&1)!=0;
    p.shoulder_aiming=(flags[10]&4)!=0 && (flags[15]&32)!=0;
    p.full_ads=controller_bytes[4]!=0;
    if(entering && (p.native_aiming || p.full_ads))return false;
    const uint64_t top=head==tail?ctx+0x1F00:ctx+0x200+((tail+31)%32)*0xE8;
    if(!read(top,request,sizeof request) || request[1]!=c.avatar)return false;
    if(entering) {
        if((request[0]&0xffff)!=4 || c.request!=ctx+0x200+tail*0xE8)return false;
        p.camera=camera;p.controller=controller;p.descriptor=descriptor;p.object=object;p.weapon_object=weapon_object;
        std::memcpy(p.descriptor_bytes,d,20);std::memcpy(p.weapon_bytes,wd,20);
        return true;
    }
    return top==c.request && (request[0]&0xffff)==6 && request[2]==c.weapon && request[3]==c.body
        && camera==p.camera && controller==p.controller && descriptor==p.descriptor && object==p.object
        && weapon_object==p.weapon_object && std::memcmp(d,p.descriptor_bytes,20)==0 && std::memcmp(wd,p.weapon_bytes,20)==0;
}

// This candidate supports the captured 63-node rig only. The camera is a sibling
// of node 5, while both arms and the weapon attachment descend from node 5.
static bool graph(Policy& p,bool capture) {
    uint64_t vtable=0,getter=0,links=0,hashes=0;uint32_t count=0;
    if(!pointer(p.object,vtable) || !pointer(vtable+0xE8,getter) || getter!=p.c.exe+GRAPH_GETTER
        || !bytes(getter,"488d4160c3") || !value(p.object+0x70,count) || count!=63
        || !pointer(p.object+0x98,links) || !pointer(p.object+0xA0,hashes))return false;
#if !defined(NADSE_FIXTURE)
    if(!executable(getter))return false;
#endif
    if(!capture && (vtable!=p.graph_vtable || links!=p.graph_links || hashes!=p.graph_hashes))return false;
    struct Row {uint32_t node,hash,link;};
    static constexpr Row rows[]={
        {0,0x4A182741,0},{1,0x7F30E61C,1},{2,0x32623EB2,0x10001},
        {3,0x975CEBBD,0x20001},{4,0xBCCF91E5,0x30001},{5,0x9B115563,0x40001},
        {7,0x6F3BD021,0x50001},{8,0x4FDD3337,0x70001},
        {10,0x03752C98,0x70001},{12,0x1CA2CD66,0xA0001},{13,0x5C0C68D3,0xC0001},
        {30,0x1620B2CE,0x70001},{32,0x31E34DAC,0x1E0001},{34,0x248004F5,0x200001},
        {50,0x60ED8C39,0x40001}};
    // Count63 proves these two complete arrays. Keep every selected-node
    // comparison live, but copy each array once instead of 30 scalar reads.
    uint32_t current_hashes[63],current_links[63];
    if(!read(hashes,current_hashes,sizeof current_hashes) || !read(links,current_links,sizeof current_links))return false;
    for(const auto& row:rows) {
        if(current_hashes[row.node]!=row.hash || current_links[row.node]!=row.link)return false;
    }
    if(capture) {p.graph_vtable=vtable;p.graph_links=links;p.graph_hashes=hashes;}
    return true;
}

#if defined(NADSE_FIXTURE)
static Setter fixture_targets[SLOT_COUNT]{};
static uint64_t fixture_now=0;
static uint64_t tick() {return fixture_now;}
#else
static uint64_t tick() {return GetTickCount64();}
#endif
static bool writable_slot(uint64_t slot,uint64_t exe) {
    if((slot&7)!=0)return false;
#if defined(NADSE_FIXTURE)
    if(fixture_slot_readonly)return false;
    (void)exe;
#endif
    MEMORY_BASIC_INFORMATION r{};
    if(VirtualQuery(reinterpret_cast<const void*>(slot),&r,sizeof r)!=sizeof r || r.State!=MEM_COMMIT
        || r.Protect!=PAGE_READWRITE || slot+8>reinterpret_cast<uint64_t>(r.BaseAddress)+r.RegionSize)return false;
#if !defined(NADSE_FIXTURE)
    if(r.Type!=MEM_IMAGE || reinterpret_cast<uint64_t>(r.AllocationBase)!=exe)return false;
#else
    if(r.Type!=MEM_PRIVATE)return false;
#endif
    return true;
}
static bool slot_read(uint64_t at,uint64_t& current) {
#if defined(NADSE_FIXTURE)
    if(fixture_slot_unreadable || at==fixture_unreadable_slot)return false;
#endif
    return value(at,current);
}
static bool cas(uint64_t slot,uint64_t expected,uint64_t desired,uint64_t& observed) {
#if defined(NADSE_FIXTURE)
    if(fixture_output_to_check) {
        uint64_t published=0;
        if(!value(reinterpret_cast<uint64_t>(fixture_output_to_check),published) || !published
            || published!=owned_generation || !reserved.load())fixture_generation_published=false;
    }
    if(++fixture_cas_calls==fixture_cas_fail_at)return false;
    if(fixture_fail_rollback && desired==reinterpret_cast<uint64_t>(originals[0].load()))return false;
    if(fixture_cas_calls==fixture_foreign_cas_at)InterlockedExchangePointer(
        reinterpret_cast<PVOID volatile*>(slot),reinterpret_cast<void*>(fixture_foreign_value));
#endif
    __try {
        observed=reinterpret_cast<uint64_t>(InterlockedCompareExchangePointer(
            reinterpret_cast<PVOID volatile*>(slot),reinterpret_cast<void*>(desired),reinterpret_cast<void*>(expected)));
        return true;
    } __except(EXCEPTION_EXECUTE_HANDLER) {return false;}
}
static bool contract(const NADSE_Config& c,Setter (&out)[SLOT_COUNT],uint64_t (&addresses)[SLOT_COUNT]) {
    if(!image(c.game,0x6AB3B43F,0x4744000) || !image(c.exe,0x6AB382E4,0x39E8000))return reject(IMAGE_MISMATCH);
    if(!bytes(c.game+CALLS[0],"41ff5138") || !bytes(c.game+CALLS[1],"41ff5148")
        || !bytes(c.game+RIG_CALL,"41ff5138") || !bytes(c.game+ROTATION_CALL,"41ff5140")
        || !bytes(c.game+OBSERVE_CALL,"41ffd0"))return reject(CODE_MISMATCH);
    uint64_t root=0,api=0;
    if(!pointer(c.game+0x3326308,root) || !pointer(root+0x18,api))return reject(API_MISMATCH);
    for(unsigned i=0;i<SLOT_COUNT;++i) {
        addresses[i]=api+API_OFFSETS[i];
        if(!writable_slot(addresses[i],c.exe))return reject(SLOT_NOT_WRITABLE);
        uint64_t current=0;if(!slot_read(addresses[i],current))return reject(READ_FAILED);
        out[i]=reinterpret_cast<Setter>(current);
#if defined(NADSE_FIXTURE)
        if(out[i]!=fixture_targets[i])return reject(API_MISMATCH);
        if(!bytes(c.exe+WRAPPERS[i],PREFIX[i]))return reject(CODE_MISMATCH);
#else
        if(current!=c.exe+WRAPPERS[i])return reject(API_MISMATCH);
        if(!bytes(current,PREFIX[i]))return reject(CODE_MISMATCH);
#endif
        if(!executable(current))return reject(API_MISMATCH);
    }
    return true;
}
static uint64_t callback(unsigned which);
static bool dispatch_owned(const NADSE_Config& c) {
    uint64_t root=0,api=0;
    if(!pointer(c.game+0x3326308,root) || !pointer(root+0x18,api))return false;
    for(unsigned i=0;i<SLOT_COUNT;++i) {
        uint64_t current=0;
        if(api+API_OFFSETS[i]!=slots[i] || !slot_read(slots[i],current) || current!=callback(i))return false;
    }
    return true;
}
// The native postpass visits every kind-6 ring entry. Its quaternion lives on
// the stack, so only a sole owned entry proves which request supplied it.
static bool sole_request(const Policy& p) {
    uint32_t head=0,tail=0;
    return value(p.c.context+0x1F8,head) && value(p.c.context+0x1FC,tail) && head<32 && tail<32
        && ((tail+32-head)%32)==1 && p.c.request==p.c.context+0x200+static_cast<uint64_t>(head)*0xE8;
}
static bool rotation_uncoupled(const Policy& p) {
    float coupling=1;
    return value(p.c.request+0x98,coupling) && coupling==0.0f;
}
template<class T> static T field(const uint8_t* block,unsigned offset) {
    T result{};std::memcpy(&result,block+offset,sizeof result);return result;
}
static bool address(uint64_t at) {return at>=65536 && at<0x800000000000ULL;}
// Cache the exact bounded probe prefix, so periodic validation does not repeat
// a registry scan. The native key multiplication intentionally wraps32 bits.
static bool depth_map(const uint8_t* header,uint32_t key,DepthProbe& out,uint32_t& index) {
    out.buckets=field<uint64_t>(header,0);out.cap=field<uint32_t>(header,8);
    const uint32_t empty=field<uint32_t>(header,12),mult=field<uint32_t>(header,16);
    if(!address(out.buckets) || !out.cap || out.cap>0x100000 || (out.cap&(out.cap-1)) || key==empty)return false;
    out.start=(key*mult)&(out.cap-1);out.count=0;index=UINT32_MAX;
    while(out.count<out.cap && out.count<64) {
        const uint32_t at=(out.start+out.count)&(out.cap-1);
        uint32_t n=out.cap-at;if(n>8)n=8;if(n>out.cap-out.count)n=out.cap-out.count;if(n>64-out.count)n=64-out.count;
        uint64_t rows[8]{};if(!read(out.buckets+static_cast<uint64_t>(at)*8,rows,n*8))return false;
        for(uint32_t i=0;i<n;++i) {
            const uint64_t row=rows[i];out.rows[out.count++]=row;
            const uint32_t entity=static_cast<uint32_t>(row);
            if(entity==key) {index=static_cast<uint32_t>(row>>32);return true;}
            if(entity==empty)return true;
        }
    }
    return false;
}
static bool depth_probe_valid(const DepthProbe& probe) {
    if(!probe.count || probe.count>64)return false;
    uint64_t rows[64]{};uint32_t first=probe.cap-probe.start;if(first>probe.count)first=probe.count;
    if(!read(probe.buckets+static_cast<uint64_t>(probe.start)*8,rows,first*8))return false;
    if(first<probe.count && !read(probe.buckets,rows+first,(probe.count-first)*8))return false;
    return std::memcmp(rows,probe.rows,probe.count*8)==0;
}
static bool depth_data_valid(const Policy& p,const DepthData& d) {
    uint64_t pool=0,world=0,settings=0,table=0;uint8_t bytes_[0xdc]{};float degrees=0;
    if(!pointer(p.c.game+0x3326CE0,pool) || pool!=d.pool || !pointer(p.c.game+0x346BF98,world) || world!=d.world
        || !pointer(p.c.game+0x3326340,settings) || settings!=d.settings
        || !read(pool+0x30,bytes_,sizeof d.pool_bytes) || std::memcmp(bytes_,d.pool_bytes,sizeof d.pool_bytes)
        || !depth_probe_valid(d.primary) || !depth_probe_valid(d.overrides)
        || !read(d.parameters,bytes_,16) || std::memcmp(bytes_,d.parameter_bytes,16)
        || !read(d.data+0x74,bytes_,sizeof d.data_bytes) || std::memcmp(bytes_,d.data_bytes,sizeof d.data_bytes)
        || !value(settings+0xAC408,degrees) || degrees!=d.degrees)return false;
    if(d.resource_row && (!pointer(world+0xF12BD8,table) || table!=d.resource_table
        || !read(d.resource_row,bytes_,16) || std::memcmp(bytes_,d.resource_bytes,16)))return false;
    return true;
}
static bool depth_data(const Policy& p,DepthData& d,uint32_t& selected) {
    if(!pointer(p.c.game+0x3326CE0,d.pool) || !pointer(p.c.game+0x346BF98,d.world)
        || !pointer(p.c.game+0x3326340,d.settings) || !read(d.pool+0x30,d.pool_bytes,sizeof d.pool_bytes))return false;
    uint32_t wi=UINT32_MAX,di=UINT32_MAX;
    if(!depth_map(d.pool_bytes,p.c.weapon,d.primary,wi) || wi>=4096
        || !depth_map(d.pool_bytes+0x40,p.c.weapon,d.overrides,di))return false;
    const uint64_t descriptors=field<uint64_t>(d.pool_bytes,0x18);
    uint64_t descriptor=0;if(!address(descriptors) || !pointer(descriptors+static_cast<uint64_t>(wi)*8,descriptor)
        || descriptor!=p.c.weapon_descriptor)return false;
    if(di!=UINT32_MAX) {
        const uint64_t data=field<uint64_t>(d.pool_bytes,0x80);
        if(!address(data) || di>=4096)return false;
        d.data=data+static_cast<uint64_t>(di)*0x4D0;
    } else {
        uint64_t resource=0;std::memcpy(&resource,p.weapon_bytes,8);
        if(!resource || !pointer(d.world+0xF12BD8,d.resource_table))return false;
        const uint32_t bucket=static_cast<uint32_t>(resource%730);
        for(uint32_t n=0;n<730;) {
            const uint32_t at=(bucket+n)%730;uint32_t count=730-at;if(count>16)count=16;if(count>730-n)count=730-n;
            uint8_t rows[256]{};if(!read(d.resource_table+static_cast<uint64_t>(at)*16,rows,count*16))return false;
            for(uint32_t i=0;i<count;++i,++n) {
                const uint64_t key=field<uint64_t>(rows,i*16);if(!key)return false;
                if(key==resource) {
                    di=field<uint32_t>(rows,i*16+8);if(di>=730)return false;
                    d.resource_row=d.resource_table+static_cast<uint64_t>(at+i)*16;
                    std::memcpy(d.resource_bytes,rows+i*16,16);break;
                }
            }
            if(d.resource_row)break;
        }
        if(!d.resource_row)return false;
        d.data=d.resource_table+0x2DA0+static_cast<uint64_t>(di)*0x4D0;
    }
    const uint64_t parameters=field<uint64_t>(d.pool_bytes,0x28),packed=field<uint64_t>(d.pool_bytes,0x30);
    if(!address(parameters) || !address(packed))return false;
    d.parameters=parameters+static_cast<uint64_t>(wi)*0x3F0+0x350;d.packed=packed+static_cast<uint64_t>(wi)*12+4;
    uint32_t bits=0;
    if(!read(d.parameters,d.parameter_bytes,16) || !value(d.packed,bits)
        || !read(d.data+0x74,d.data_bytes,sizeof d.data_bytes) || !value(d.settings+0xAC408,d.degrees))return false;
    unsigned matches=0;for(unsigned i=0;i<4;++i)if(field<uint32_t>(d.parameter_bytes,i*4)==1)++matches;
    if(matches!=1)return false;selected=(bits>>4)&3;if(selected>2)return false;
    for(unsigned i=0;i<3;++i) {
        d.zoom[i]=field<float>(d.data_bytes,i*4);d.coefficient[i]=field<float>(d.data_bytes,0xC8+i*4);
        if(!std::isfinite(d.zoom[i]) || d.zoom[i]<.1f || d.zoom[i]>100
            || !std::isfinite(d.coefficient[i]) || d.coefficient[i]<.0001f || d.coefficient[i]>100)return false;
    }
    d.near_term[0]=field<float>(d.data_bytes,0xD4);d.near_term[1]=field<float>(d.data_bytes,0xD8);
    if(!std::isfinite(d.degrees) || d.degrees<10 || d.degrees>170
        || !std::isfinite(d.near_term[0]) || !std::isfinite(d.near_term[1]) || std::fabs(d.near_term[0])>1 || std::fabs(d.near_term[1])>1)return false;
    return depth_data_valid(p,d);
}
static bool depth_code(const NADSE_Config& c) {
    return bytes(c.game+0x12873B3,"f30f1044245cf30f1015df4b1401")
        && bytes(c.game+0x12873D9,"f30f5c4424600f54c2f30f5ec1")
        && bytes(c.game+0x1287A91,"f3450f58fb")
        && bytes(c.game+0x1287B43,"f30f59faf3410f59cff3")
        && bytes(c.game+0x1287C04,"f3410f11774cf3450f114750");
}
static bool depth_reference(const DepthData& d,uint32_t selected,float distance,float& reference) {
    constexpr float rad=.01745329238474369f;
    const float angle=((d.degrees/d.zoom[selected])*rad)*.5f,base=((d.degrees/d.zoom[0])*rad)*.5f;
    if(angle<.0001f || angle>1.48f || base<.0001f || base>1.48f || !std::isfinite(distance) || distance<0 || distance>4)return false;
    if(selected==0) {reference=distance;return true;}
    const float denominator=std::tan(base)*d.coefficient[0],current=std::tan(angle)*d.coefficient[selected];
    const float u=(d.degrees-45.0f)/45.0f,base_term=(1-u)*d.near_term[0]+u*d.near_term[1];
    reference=base_term+(distance-base_term)*(current/denominator);
    return std::isfinite(reference) && reference>=0 && reference<=4;
}
// The exact native caller owns these stack locals. Reading its target/current
// lens avoids replicating camera-profile/stance logic or modifying a request.
// Only the existing exact caller/node/source gates authorize this observer.
static float depth_pass(DepthState& state,uint32_t reason) {
    state.observed.supported=0;state.observed.reason=reason;state.observed.correction=0;
    if(reason==1)++state.observed.ads_bypassed;else ++state.observed.unsupported;
    return 0;
}
static float depth_delta(Policy& p,const DepthObservation& observation,uint64_t native_stack,uint64_t now) {
#if defined(NADSE_FIXTURE)
    native_stack=fixture_depth_frame;
#endif
    if(!native_stack)return 0;
    DepthState& s=p.depth;
    if(p.full_ads)return depth_pass(s,1);
    if(!observation.ready || observation.native_stack!=native_stack || observation.request!=p.c.request
        || observation.generation!=active_generation.load(std::memory_order_relaxed)
        || observation.thread!=GetCurrentThreadId())return depth_pass(s,3);
    if(!s.checked) {s.checked=true;s.code_ok=depth_code(p.c);}
    if(!s.code_ok)return depth_pass(s,2);
    uint8_t request[0x24]{};const uint8_t* frame=observation.frame;
    if(!read(p.c.request+0x80,request,sizeof request)
        || std::memcmp(request,observation.request_state,8)
        || std::memcmp(request+0xC,observation.request_state+0xC,sizeof request-0xC))return depth_pass(s,3);
    const float current=field<float>(request,0x10),previous=field<float>(request,0x1C),prior=field<float>(request,0x20);
    const float target=field<float>(frame,0x18),lens=field<float>(frame,0x1C),mix=field<float>(request,8);
    if(request[0xD]>1 || request[0xF]!=0 || frame[0]!=0 || frame[1]>1 || field<float>(request,0x18)!=0)return depth_pass(s,4);
    if(field<uint32_t>(request,4)!=field<uint32_t>(frame,0x1C)
        || !std::isfinite(target) || target<.0002f || target>2.96f || !std::isfinite(lens) || lens<.0002f || lens>2.96f
        || !std::isfinite(prior) || prior<0 || prior>2.96f || !std::isfinite(current) || !std::isfinite(previous)
        || current<0 || current>4 || previous<0 || previous>4 || (request[0xD] && (!std::isfinite(mix) || mix<0 || mix>1)))return depth_pass(s,5);
    const float span=std::fabs(target-prior);
    float t=span>1.1920928955078125e-7f?std::fabs(target-lens)/span:0;
    if(t>1)t=1;
    const uint32_t signature[4]={field<uint32_t>(request,0x10),field<uint32_t>(request,0x1C),
        field<uint32_t>(request,0x20),0};
    const bool changed=!s.signature_set || std::memcmp(signature,s.signature,sizeof signature)!=0;
    if(changed || (!s.valid && now>=s.retry_at)) {
        const bool old_valid=s.valid;const float old_current=s.current,old_previous=s.previous;
        const float old_reference=s.current_reference,old_previous_reference=s.previous_reference;
        const bool old_previous_known=s.previous_known;
        s.signature_set=true;std::memcpy(s.signature,signature,sizeof signature);s.valid=false;s.previous_known=false;
        s.current=current;s.previous=previous;s.retry_at=now+500;
        DepthData data{};uint32_t selected=0;++s.refreshes;
        if(!depth_data(p,data,selected) || !depth_reference(data,selected,current,s.current_reference))return depth_pass(s,6);
#if defined(NADSE_FIXTURE)
        if(fixture_depth_mutation)std::memcpy(reinterpret_cast<void*>(fixture_depth_mutation),&fixture_depth_mutation_byte,1);
#endif
        s.observed.zoom_index=selected;s.observed.zoom=data.zoom[selected];
        if(previous==0) {s.previous_reference=0;s.previous_known=true;}
        else if(old_valid && previous==old_current) {s.previous_reference=old_reference;s.previous_known=true;}
        else if(old_valid && old_previous_known && previous==old_previous) {s.previous_reference=old_previous_reference;s.previous_known=true;}
        // A missing previous event cannot be reconstructed from prior lens:
        // it may be an intermediate lens or belong to another definition.
        s.data=data;s.next_check=now+500;s.valid=true;
    } else if(s.valid && now>=s.next_check) {
        ++s.checks;s.next_check=now+500;
        if(!depth_data_valid(p,s.data)) {
            // A different definition is not the provenance of an unchanged
            // native distance. Stay passive until a new native event publishes
            // fresh distances; do not reinterpret an old result with new data.
            s.valid=false;s.retry_at=UINT64_MAX;return depth_pass(s,9);
        }
    }
    if(!s.valid)return depth_pass(s,6);
    if(t!=0 && !s.previous_known)return depth_pass(s,7);
    const float native=(1-t)*current+t*previous;
    const float reference=(1-t)*s.current_reference+(t==0?0:t*s.previous_reference);
    const float gain=request[0xD]?mix:1;
    const float delta=(reference-native)*gain;
    if(!std::isfinite(delta) || std::fabs(delta)>1)return depth_pass(s,8);
    s.observed.supported=1;s.observed.reason=0;s.observed.native_distance=native;
    s.observed.reference_distance=reference;s.observed.correction=delta;
    s.observed.target_fov=target;s.observed.current_fov=lens;s.observed.gain=gain;
    return delta;
}
// No counters, locks or memory walks for unrelated getter callers. The narrow
// observation forwards the original arguments/return pointer exactly, under
// the same drain lock as End. It reads the native lens locals BEFORE1287F41
// reuses+5C for orientation scratch, and is consumed once by the paired setter.
static const float* position_getter_hook(uint32_t unit,uint32_t node) {
    const uint64_t caller=reinterpret_cast<uint64_t>(_ReturnAddress());
    const Getter original=reinterpret_cast<Getter>(originals[3].load(std::memory_order_acquire));
    if(!armed.load(std::memory_order_acquire) || caller!=getter_return.load(std::memory_order_relaxed))return original(unit,node);
    uint64_t native_stack=reinterpret_cast<uint64_t>(_AddressOfReturnAddress())+8;
#if defined(NADSE_FIXTURE)
    native_stack=fixture_depth_frame;
#endif
    const uint64_t generation=active_generation.load(std::memory_order_relaxed);
    AcquireSRWLockExclusive(&policy_lock);
    struct Unlock {~Unlock(){ReleaseSRWLockExclusive(&policy_lock);}} unlock;
    policy.observation.ready=false;
    policy.carrier.ready=false;
    const float* result=original(unit,node);
    if(armed.load(std::memory_order_acquire) && generation==active_generation.load(std::memory_order_relaxed)
        && unit==policy.c.viewmodel && node==50 && native_stack) {
        auto& observation=policy.observation;
        observation.native_stack=native_stack;observation.thread=GetCurrentThreadId();
        observation.generation=generation;observation.request=policy.c.request;
        observation.ready=read(native_stack+0x44,observation.frame,sizeof observation.frame)
            && read(policy.c.request+0x80,observation.request_state,sizeof observation.request_state);
    }
    return result;
}
// policy_lock is held. Never replay a cached pose into a different owner/rig.
static void restore_rig_if_owned() {
    const bool owned=(policy.rig_shifted || policy.rotation_shifted || policy.carrier_shifted)
        && ownership(policy,false) && graph(policy,false) && dispatch_owned(policy.c);
    if(policy.rig_shifted && owned) {
        alignas(16) float native[4];std::memcpy(native,policy.baseline,16);
        originals[0].load(std::memory_order_acquire)(policy.c.viewmodel,RIG_NODE,native);
        zero_restores.fetch_add(1,std::memory_order_relaxed);
    }
    if(policy.rotation_shifted && owned && sole_request(policy)) {
        alignas(16) float native[4];std::memcpy(native,policy.rotation_baseline,16);
        originals[2].load(std::memory_order_acquire)(policy.c.viewmodel,RIG_NODE,native);
        zero_restores.fetch_add(1,std::memory_order_relaxed);
    }
    if(policy.carrier_shifted && owned && sole_request(policy)) {
        // The original position setter queues its write. Replay only if that
        // exact write is now the live owned node0 pose; another writer or a
        // replaced pose array wins. Never restore unconditionally into root0.
        uint64_t poses=0;float current[3]{};
        if(pointer(policy.object+0x80,poses) && poses==policy.carrier_poses
            && read(poses+0x24,current,sizeof current)
            && std::memcmp(current,policy.carrier_written,sizeof current)==0) {
            alignas(16) float native[4];std::memcpy(native,policy.carrier_baseline,16);
            originals[0].load(std::memory_order_acquire)(policy.c.viewmodel,0,native);
            zero_restores.fetch_add(1,std::memory_order_relaxed);
        }
    }
    policy.rig_shifted=false;
    policy.rotation_shifted=false;
    policy.carrier_shifted=false;policy.carrier.ready=false;
}
static bool finite_pose(const float (&pose)[4]) {
    for(unsigned i=0;i<3;++i)if(!std::isfinite(pose[i]))return false;
    return true;
}
static void forward_position(uint32_t unit,uint32_t node,const float* pose) {
    forwarded[0].fetch_add(1,std::memory_order_relaxed);
    originals[0].load(std::memory_order_acquire)(unit,node,pose);
}
static bool quaternion(const float (&q)[4],float tolerance);
static void carrier_position(uint64_t caller,uint32_t unit,uint32_t node,const float* pose,uint64_t native_stack) {
#if defined(NADSE_FIXTURE)
    native_stack=fixture_depth_frame;
#endif
    AcquireSRWLockExclusive(&policy_lock);
    struct Unlock {~Unlock(){ReleaseSRWLockExclusive(&policy_lock);}} unlock;
    const CarrierPending pending=policy.carrier;policy.carrier.ready=false;
    if(unit==policy.c.viewmodel && node==0)policy.carrier_shifted=false;
    if(!armed.load(std::memory_order_acquire) || caller!=carrier_return.load(std::memory_order_relaxed)
        || unit!=policy.c.viewmodel || node!=0 || !pending.ready) {forward_position(unit,node,pose);return;}
    const auto& observation=pending.observation;
    if(!native_stack || observation.native_stack!=native_stack || observation.request!=policy.c.request
        || observation.generation!=active_generation.load(std::memory_order_relaxed)
        || observation.thread!=GetCurrentThreadId() || reinterpret_cast<uint64_t>(pose)!=native_stack+0x240) {
        forward_position(unit,node,pose);return;
    }
    if(!policy.carrier_checked) {
        policy.carrier_checked=true;
        policy.carrier_code_ok=bytes(policy.c.game+0x1286335,"5556574154415541564157488dac24f0fcffff4881ec10040000")
            && bytes(policy.c.game+0x128878B,"4c8d8540010000f2410f11475433")
            && bytes(policy.c.game+0x12887D4,"4c8d8530010000");
    }
    if(!policy.carrier_code_ok || !sole_request(policy)) {forward_position(unit,node,pose);return;}
    uint32_t failure=OK;
    if(!ownership(policy,false))failure=OWNER_MISMATCH;
    else if(!graph(policy,false))failure=GRAPH_MISMATCH;
    else if(!dispatch_owned(policy.c))failure=API_MISMATCH;
    if(failure!=OK || (policy.deadline!=0 && tick()>=policy.deadline)) {
        armed.store(0,std::memory_order_release);
        if(failure!=OK)error(failure);else expired.store(1,std::memory_order_release);
        forward_position(unit,node,pose);return;
    }
    uint8_t request[0x24]{};
    if(policy.full_ads || !read(policy.c.request+0x80,request,sizeof request)
        || std::memcmp(request,observation.request_state,8)
        || std::memcmp(request+0xC,observation.request_state+0xC,sizeof request-0xC)) {
        forward_position(unit,node,pose);return;
    }
    // Same-invocation final quaternion, after all native solve passes. Native
    // root contains -rotate(q,+Y*D); cancel only our paired node5 depth term.
    // This does not change the native quaternion or its zoom-dependent solve.
    alignas(16) float source[8]{},q[4]{},shifted[4]{};uint64_t poses=0;
    if(!read(reinterpret_cast<uint64_t>(pose)-0x10,source,sizeof source)) {forward_position(unit,node,pose);return;}
    std::memcpy(q,source,16);std::memcpy(shifted,source+4,16);
    if(!quaternion(q,.002f) || !finite_pose(shifted) || !pointer(policy.object+0x80,poses)) {
        forward_position(unit,node,pose);return;
    }
    const float x=q[0],y=q[1],z=q[2],w=q[3];
    const float forward[3]={2*(x*y-z*w),w*w+y*y-x*x-z*z,2*(y*z+x*w)};
    for(unsigned i=0;i<3;++i)shifted[i]-=pending.delta*forward[i];
    if(!finite_pose(shifted)) {forward_position(unit,node,pose);return;}
    std::memcpy(policy.carrier_baseline,source+4,16);std::memcpy(policy.carrier_written,shifted,12);
    policy.carrier_poses=poses;policy.carrier_shifted=std::memcmp(shifted,source+4,12)!=0;
    if(policy.carrier_shifted)forward_position(unit,node,shifted);else forward_position(unit,node,pose);
}
static void position_call(uint64_t caller,uint32_t unit,uint32_t node,const float* pose,uint64_t native_stack=0) {
    // Only this owned unit's root can need invalidation; all other global
    // position setters keep the exact no-lock/no-read forwarding path.
    if((node==0 && unit==watched_viewmodel.load(std::memory_order_relaxed))
        || (armed.load(std::memory_order_acquire) && caller==carrier_return.load(std::memory_order_relaxed))) {
        carrier_position(caller,unit,node,pose,native_stack);return;
    }
    if(!armed.load(std::memory_order_acquire) || caller!=rig_return.load(std::memory_order_relaxed)) {
        forward_position(unit,node,pose);return;
    }
    AcquireSRWLockExclusive(&policy_lock);
    struct Unlock {~Unlock(){ReleaseSRWLockExclusive(&policy_lock);}} unlock;
    if(!armed.load(std::memory_order_acquire)) {
        forward_position(unit,node,pose);return;
    }
    // Destroyed before Unlock, after the original setter completes or refuses.
    struct Publish {~Publish(){publish_diagnostics(policy);}} publish;
    if(unit!=policy.c.viewmodel || node!=RIG_NODE) {forward_position(unit,node,pose);return;}
    const DepthObservation observation=policy.observation;policy.observation.ready=false;policy.carrier.ready=false;
    if(reinterpret_cast<uint64_t>(pose)!=policy.c.request+0x48) {
        // Fading native ring records legitimately use this same callsite/unit.
        // Their fresh writes supersede our cache, but do not end our lease.
        policy.rig_shifted=false;
        forward_position(unit,node,pose);return;
    }
    uint32_t failure=OK,sight=0;
    const uint64_t now=tick();
    if(!ownership(policy,false))failure=OWNER_MISMATCH;
    else if(!graph(policy,false))failure=GRAPH_MISMATCH;
    else if(!dispatch_owned(policy.c))failure=API_MISMATCH;
    else if(!value(policy.c.request+0x18,sight) || sight==0)failure=SIGHT_NODE_UNAVAILABLE;
    alignas(16) float native[4]{};
    if(failure==OK && (!read(reinterpret_cast<uint64_t>(pose),native,16) || !finite_pose(native)))failure=POSE_INVALID;
    if(failure!=OK || (policy.deadline!=0 && now>=policy.deadline)) {
        // This very call supplies a fresh native baseline. Forward it exactly,
        // rather than replaying an older cached baseline before or after it.
        if(policy.rig_shifted && failure!=OWNER_MISMATCH && failure!=GRAPH_MISMATCH && failure!=POSE_INVALID)
            zero_restores.fetch_add(1,std::memory_order_relaxed);
        policy.rig_shifted=false;armed.store(0,std::memory_order_release);
        if(failure!=OK)error(failure);else expired.store(1,std::memory_order_release);
        forward_position(unit,node,pose);return;
    }
    const float u=static_cast<float>(now-policy.blend_start)/static_cast<float>(policy.c.blend_ms);
    const float t=u<0?0:(u>1?1:u),eased=t*t*(3-2*t);
    policy.weight=policy.start_weight+(policy.target-policy.start_weight)*eased;
    // Normal aim retains saved placement. Only the native FPV
    // controller owns full ADS and receives the original, unshifted pose.
    const float target=policy.full_ads?0.0f:1.0f;
    if(target!=policy.target) {policy.start_weight=policy.weight;policy.target=target;policy.blend_start=now;}
    alignas(16) float shifted[4];std::memcpy(shifted,native,16);
    if(policy.weight!=0) {
        shifted[0]+=(policy.c.offset_x+policy.motion[0])*policy.weight;
        shifted[1]+=(policy.c.offset_y+policy.motion[1])*policy.weight;
        shifted[2]+=(policy.c.offset_z+policy.motion[2])*policy.weight;
    }
    // Optional user-authored ADS placement; zero retains native sight pose.
    if(policy.full_ads)for(unsigned axis=0;axis<3;++axis)shifted[axis]+=policy.ads_placement[axis];
    // This presentation-only term is independent of saved placement/shoulder
    // weight. Full native ADS bypasses it immediately inside depth_delta.
    const uint64_t depth_reads=policy.depth.refreshes+policy.depth.checks;
    float depth=depth_delta(policy,observation,native_stack,now);
    if(depth_reads!=policy.depth.refreshes+policy.depth.checks) {
        uint32_t changed=OK;
        if(!ownership(policy,false))changed=OWNER_MISMATCH;
        else if(!graph(policy,false))changed=GRAPH_MISMATCH;
        else if(!dispatch_owned(policy.c))changed=API_MISMATCH;
        if(changed!=OK) {
            depth_pass(policy.depth,9);
            policy.rig_shifted=false;armed.store(0,std::memory_order_release);error(changed);
            forward_position(unit,node,pose);return;
        }
        if(policy.full_ads) {depth=0;depth_pass(policy.depth,1);}
    }
    float applied_depth=0;
    if(depth!=0) {
        const float before=shifted[1];shifted[1]+=depth;
        if(shifted[1]!=before) {++policy.depth.observed.applied;applied_depth=shifted[1]-before;}
    }
    if(!finite_pose(shifted)) {
        policy.rig_shifted=false;armed.store(0,std::memory_order_release);error(POSE_INVALID);
        forward_position(unit,node,pose);return;
    }
    std::memcpy(policy.baseline,native,16);
    if(applied_depth!=0) {policy.carrier.observation=observation;policy.carrier.delta=applied_depth;policy.carrier.ready=true;}
    policy.rig_shifted=std::memcmp(shifted,native,16)!=0;
    if(policy.rig_shifted) {
        weapon_updates.fetch_add(1,std::memory_order_relaxed);
        forward_position(unit,node,shifted);
    } else forward_position(unit,node,pose);
}
static void position_hook(uint32_t unit,uint32_t node,const float* pose) {
    seen[0].fetch_add(1,std::memory_order_relaxed);
    position_call(reinterpret_cast<uint64_t>(_ReturnAddress()),unit,node,pose,
        reinterpret_cast<uint64_t>(_AddressOfReturnAddress())+8);
}
static void rotation_hook(uint32_t unit,uint32_t node,const float* pose) {
    seen[1].fetch_add(1,std::memory_order_relaxed);
    forwarded[1].fetch_add(1,std::memory_order_relaxed);originals[1].load(std::memory_order_acquire)(unit,node,pose);
}
static void forward_branch_rotation(uint32_t unit,uint32_t node,const float* pose) {
    forwarded[1].fetch_add(1,std::memory_order_relaxed);
    originals[2].load(std::memory_order_acquire)(unit,node,pose);
}
static bool quaternion(const float (&q)[4],float tolerance) {
    float norm=0;
    for(float v:q) {if(!std::isfinite(v))return false;norm+=v*v;}
    return std::isfinite(norm) && std::fabs(norm-1.0f)<=tolerance;
}
static bool identity(const float (&q)[4]) {return q[0]==0 && q[1]==0 && q[2]==0 && q[3]==1;}
static void branch_rotation_call(uint64_t caller,uint32_t unit,uint32_t node,const float* pose) {
    if(!armed.load(std::memory_order_acquire)) {forward_branch_rotation(unit,node,pose);return;}
    AcquireSRWLockExclusive(&policy_lock);
    struct Unlock {~Unlock(){ReleaseSRWLockExclusive(&policy_lock);}} unlock;
    if(!armed.load(std::memory_order_acquire) || unit!=policy.c.viewmodel || node!=RIG_NODE) {
        forward_branch_rotation(unit,node,pose);return;
    }
    if(caller!=rotation_return.load(std::memory_order_relaxed)) {
        // Another writer owns this newer pose. Do not replay our older cache.
        policy.rotation_shifted=false;forward_branch_rotation(unit,node,pose);return;
    }
    // No owned rotation remains to restore, and the input will be forwarded
    // untouched. Do not walk ownership/graph metadata for a no-write path.
    // The next nonidentity delta still performs the complete live guards.
    if(identity(policy.rotation) && !policy.rotation_shifted) {
        forward_branch_rotation(unit,node,pose);return;
    }
    uint32_t failure=OK;
    if(!ownership(policy,false))failure=OWNER_MISMATCH;
    else if(!graph(policy,false))failure=GRAPH_MISMATCH;
    else if(!dispatch_owned(policy.c))failure=API_MISMATCH;
    if(failure!=OK) {
        policy.rotation_shifted=false;policy.rig_shifted=false;armed.store(0,std::memory_order_release);
        error(failure);forward_branch_rotation(unit,node,pose);return;
    }
    const bool sole=sole_request(policy);
    if(policy.deadline!=0 && tick()>=policy.deadline) {
        // The current call already supplies the new native rotation.
        if(policy.rotation_shifted && sole)zero_restores.fetch_add(1,std::memory_order_relaxed);
        policy.rotation_shifted=false;restore_rig_if_owned();armed.store(0,std::memory_order_release);
        expired.store(1,std::memory_order_release);forward_branch_rotation(unit,node,pose);return;
    }
    // Nonzero coupling makes the earlier native sight solver depend on weapon
    // world orientation. The supported live capture has coupling zero. Remain
    // passive for every other value, fading request and full ADS. Generic
    // shoulder aim permits the sampler's smooth return to an identity delta.
    if(!sole || !rotation_uncoupled(policy) || (policy.full_ads && !policy.authored_ads_rotation) || identity(policy.rotation)) {
        if(policy.rotation_shifted && sole)zero_restores.fetch_add(1,std::memory_order_relaxed);
        policy.rotation_shifted=false;forward_branch_rotation(unit,node,pose);return;
    }
    alignas(16) float native[4],shifted[4];
    if(!read(reinterpret_cast<uint64_t>(pose),native,16) || !quaternion(native,.02f)) {
        policy.rotation_shifted=false;armed.store(0,std::memory_order_release);error(POSE_INVALID);
        forward_branch_rotation(unit,node,pose);return;
    }
    const float* a=policy.rotation;const float* b=native;
    // Parent-local delta * fresh native local rotation; no graph readback.
    shifted[0]=a[3]*b[0]+a[0]*b[3]+a[1]*b[2]-a[2]*b[1];
    shifted[1]=a[3]*b[1]-a[0]*b[2]+a[1]*b[3]+a[2]*b[0];
    shifted[2]=a[3]*b[2]+a[0]*b[1]-a[1]*b[0]+a[2]*b[3];
    shifted[3]=a[3]*b[3]-a[0]*b[0]-a[1]*b[1]-a[2]*b[2];
    if(!quaternion(shifted,.025f)) {
        policy.rotation_shifted=false;armed.store(0,std::memory_order_release);error(POSE_INVALID);
        forward_branch_rotation(unit,node,pose);return;
    }
    std::memcpy(policy.rotation_baseline,native,16);policy.rotation_shifted=true;
    weapon_updates.fetch_add(1,std::memory_order_relaxed);
    forward_branch_rotation(unit,node,shifted);
}
static void branch_rotation_hook(uint32_t unit,uint32_t node,const float* pose) {
    seen[1].fetch_add(1,std::memory_order_relaxed);
    branch_rotation_call(reinterpret_cast<uint64_t>(_ReturnAddress()),unit,node,pose);
}
static bool pin(const void* address) {
    HMODULE module=nullptr;return GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_PIN,
        reinterpret_cast<LPCWSTR>(address),&module)!=0;
}
static uint64_t callback(unsigned which) {
    if(which==3)return reinterpret_cast<uint64_t>(position_getter_hook);
    return reinterpret_cast<uint64_t>(which==2?branch_rotation_hook:(which?rotation_hook:position_hook));
}
// control_lock is held; callbacks have already been disarmed and drained.
static bool restore_slots() {
    bool pending=false;
    for(unsigned i=0;i<SLOT_COUNT;++i)if(possible[i]) {
        uint64_t current=0;
        if(!slot_read(slots[i],current)) {pending=true;continue;}
        if(current==callback(i)) {
            if(!writable_slot(slots[i],slot_image)) {pending=true;continue;}
            uint64_t observed=0;
            if(!cas(slots[i],callback(i),reinterpret_cast<uint64_t>(originals[i].load()),observed)) {pending=true;continue;}
            // A foreign replacement won the CAS race: preserve it unchanged.
        }
        possible[i]=false;
    }
    installed.store(pending?1U:0U,std::memory_order_release);
    if(!pending) {
        retired_generation=owned_generation;owned_generation=0;
        stats_deadline=0;
        reserved.store(0,std::memory_order_release);
    }
    return !pending;
}
static bool write_generation(uint64_t* output,uint64_t generation) {
    SIZE_T actual=0;
    return WriteProcessMemory(GetCurrentProcess(),output,&generation,sizeof generation,&actual)!=0 && actual==sizeof generation;
}
static uint32_t failed_begin(uint32_t cause,uint64_t* output) {
    armed.store(0,std::memory_order_release);
    AcquireSRWLockExclusive(&policy_lock);ReleaseSRWLockExclusive(&policy_lock);
    if(!restore_slots()) {error(CLEANUP_PENDING);return 2;}
    write_generation(output,0);error(cause);return 0;
}
static bool copy_config(const NADSE_Config* input,NADSE_Config& c) {
    if(!read(reinterpret_cast<uint64_t>(input),&c,sizeof c) || c.size!=sizeof c || c.abi!=2 || c.reserved!=0
        || c.duration_ms>30500 || c.avatar_index>=8 || c.avatar==0 || c.weapon==0 || c.body==0
        || c.viewmodel==0 || c.viewmodel==0xffffffff || c.weapon_unit==0 || c.weapon_unit==0xffffffff
        || c.weapon_unit==c.viewmodel || c.weapon_unit==c.body || c.weapon_descriptor<65536
        || c.blend_ms==0 || c.blend_ms>1000 || !std::isfinite(c.offset_x) || !std::isfinite(c.offset_y) || !std::isfinite(c.offset_z)
        || std::fabs(c.offset_x)>0.5f || std::fabs(c.offset_y)>0.5f || std::fabs(c.offset_z)>0.5f)return reject(INVALID_CONFIG);
    return true;
}
NADSE_EXPORT uint32_t NADSE_Validate(const NADSE_Config* input) {
    AcquireSRWLockExclusive(&control_lock);
    struct Unlock {~Unlock(){ReleaseSRWLockExclusive(&control_lock);}} unlock;
    NADSE_Config c{};if(!copy_config(input,c))return 0;
    if(reserved.load(std::memory_order_acquire))return reject(BUSY);
    Policy checked{};checked.c=c;Setter setters[SLOT_COUNT]{};uint64_t addresses[SLOT_COUNT]{};
    if(!ownership(checked,true))return reject(OWNER_MISMATCH);
    if(!graph(checked,true))return reject(GRAPH_MISMATCH);
    if(!contract(c,setters,addresses))return 0;
    if(!ownership(checked,true))return reject(OWNER_MISMATCH);
    if(!graph(checked,false))return reject(GRAPH_MISMATCH);
    error(OK);return 1;
}
NADSE_EXPORT uint32_t NADSE_Begin(const NADSE_Config* input,uint64_t* output) {
    AcquireSRWLockExclusive(&control_lock);
    struct Unlock {~Unlock(){ReleaseSRWLockExclusive(&control_lock);}} unlock;
    if(!write_generation(output,0))return reject(INVALID_CONFIG);
    NADSE_Config c{};if(!copy_config(input,c))return 0;
    if(reserved.load(std::memory_order_acquire))return reject(BUSY);
    Policy next{};next.c=c;Setter verified[SLOT_COUNT]{};uint64_t addresses[SLOT_COUNT]{};
    if(!ownership(next,true))return reject(OWNER_MISMATCH);
    if(!graph(next,true))return reject(GRAPH_MISMATCH);
    if(!contract(c,verified,addresses))return 0;
    for(unsigned i=0;i<SLOT_COUNT;++i)if(originals[i].load() && originals[i].load()!=verified[i])return reject(API_MISMATCH);
    if(!pin(reinterpret_cast<const void*>(&NADSE_Begin)))return reject(PIN_FAILED);
#if !defined(NADSE_FIXTURE)
    if(!pin(reinterpret_cast<const void*>(c.exe)))return reject(PIN_FAILED);
#endif
    for(unsigned i=0;i<SLOT_COUNT;++i) {originals[i].store(verified[i],std::memory_order_release);slots[i]=addresses[i];possible[i]=false;}
    if(++generation_counter==0)++generation_counter;
    if(!write_generation(output,generation_counter))return reject(INVALID_CONFIG);
    owned_generation=generation_counter;slot_image=c.exe;reserved.store(1,std::memory_order_release);
    stats_deadline=0;display_cache=Display{};publish_diagnostics(next);
    // Original callbacks are visible before either pointer is published. Until
    // the final arm store, even a cached or in-flight callback only forwards.
    for(unsigned i=0;i<SLOT_COUNT;++i) {
        possible[i]=true;uint64_t observed=0;
        if(!writable_slot(slots[i],c.exe))return failed_begin(SLOT_NOT_WRITABLE,output);
        if(!cas(slots[i],reinterpret_cast<uint64_t>(verified[i]),callback(i),observed))return failed_begin(CAS_FAULT,output);
        if(observed!=reinterpret_cast<uint64_t>(verified[i])) {possible[i]=false;return failed_begin(CAS_MISMATCH,output);}
        installed.store(1,std::memory_order_release);
    }
    if(!ownership(next,true))return failed_begin(OWNER_MISMATCH,output);
    if(!graph(next,false))return failed_begin(GRAPH_MISMATCH,output);
    for(unsigned i=0;i<SLOT_COUNT;++i) {
        uint64_t current=0;
        if(!slot_read(slots[i],current) || current!=callback(i))return failed_begin(CAS_MISMATCH,output);
    }
#if defined(NADSE_FIXTURE)
    if(fixture_before_arm_reached) {SetEvent(fixture_before_arm_reached);WaitForSingleObject(fixture_continue_arm,INFINITE);}
#endif
    AcquireSRWLockExclusive(&policy_lock);policy=next;
    policy.deadline=c.duration_ms?tick()+c.duration_ms:0;policy.blend_start=tick();
    stats_deadline=policy.deadline;publish_diagnostics(policy);
    for(unsigned i=0;i<2;++i) {seen[i].store(0);forwarded[i].store(0);}
    weapon_updates.store(0);zero_restores.store(0);
    rig_return.store(c.game+RIG_CALL+4,std::memory_order_relaxed);
    rotation_return.store(c.game+ROTATION_CALL+4,std::memory_order_relaxed);
    getter_return.store(c.game+OBSERVE_CALL+3,std::memory_order_relaxed);
    carrier_return.store(c.game+CALLS[0]+4,std::memory_order_relaxed);watched_viewmodel.store(c.viewmodel,std::memory_order_relaxed);
    active_generation.store(owned_generation,std::memory_order_relaxed);
    expired.store(0,std::memory_order_release);armed.store(1,std::memory_order_release);ReleaseSRWLockExclusive(&policy_lock);
    error(OK);return 1;
}
static uint32_t set_offsets(uint64_t generation,float x,float y,float z,bool motion,const float* rotation=nullptr,bool ads=false,bool authored_ads=false) {
    AcquireSRWLockExclusive(&control_lock);
    struct UnlockControl {~UnlockControl(){ReleaseSRWLockExclusive(&control_lock);}} unlock_control;
    if(!generation || !reserved.load(std::memory_order_acquire) || generation!=owned_generation)return reject(TOKEN_MISMATCH);
    const float limit=motion?0.15f:0.5f;
    if(!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z)
        || std::fabs(x)>limit || std::fabs(y)>limit || std::fabs(z)>limit)return reject(INVALID_CONFIG);
    alignas(16) float normalized[4]{0,0,0,1};
    if(rotation) {
        std::memcpy(normalized,rotation,16);
        if(!quaternion(normalized,.002f))return reject(INVALID_CONFIG);
        const float norm=std::sqrt(normalized[0]*normalized[0]+normalized[1]*normalized[1]
            +normalized[2]*normalized[2]+normalized[3]*normalized[3]);
        for(float& v:normalized)v/=norm;
        if(normalized[3]<0)for(float& v:normalized)v=-v;
        if(normalized[3]<.5f)return reject(INVALID_CONFIG); // cos(120 degrees / 2)
    }
    AcquireSRWLockExclusive(&policy_lock);
    struct UnlockPolicy {~UnlockPolicy(){ReleaseSRWLockExclusive(&policy_lock);}} unlock_policy;
    if(!armed.load(std::memory_order_acquire))return reject(expired.load()?DEADLINE_EXPIRED:OWNER_MISMATCH);
    uint32_t failure=OK,sight=0;
    if(policy.deadline!=0 && tick()>=policy.deadline) {
        restore_rig_if_owned();armed.store(0,std::memory_order_release);expired.store(1,std::memory_order_release);
        return reject(DEADLINE_EXPIRED);
    }
    if(!ownership(policy,false))failure=OWNER_MISMATCH;
    else if(!graph(policy,false))failure=GRAPH_MISMATCH;
    else if(!dispatch_owned(policy.c))failure=API_MISMATCH;
    else if(!value(policy.c.request+0x18,sight) || sight==0)failure=SIGHT_NODE_UNAVAILABLE;
    if(failure!=OK) {
        if(failure!=OWNER_MISMATCH && failure!=GRAPH_MISMATCH)restore_rig_if_owned();
        policy.rig_shifted=false;policy.rotation_shifted=false;armed.store(0,std::memory_order_release);return reject(failure);
    }
    // Store all axes together. The next matching native call applies them to
    // its fresh baseline; neither editing nor observing extends the deadline.
    if(ads) {policy.ads_placement[0]=x;policy.ads_placement[1]=y;policy.ads_placement[2]=z;}
    else if(motion) {policy.motion[0]=x;policy.motion[1]=y;policy.motion[2]=z;}
    else {policy.c.offset_x=x;policy.c.offset_y=y;policy.c.offset_z=z;}
    if(rotation) {std::memcpy(policy.rotation,normalized,16);policy.authored_ads_rotation=authored_ads;}
    error(OK);return 1;
}
NADSE_EXPORT uint32_t NADSE_SetPlacement(uint64_t generation,float x,float y,float z) {
    return set_offsets(generation,x,y,z,false);
}
NADSE_EXPORT uint32_t NADSE_SetADSPlacement(uint64_t generation,float x,float y,float z) {
    return set_offsets(generation,x,y,z,false,nullptr,true);
}
NADSE_EXPORT uint32_t NADSE_SetMotion(uint64_t generation,float dx,float dy,float dz) {
    return set_offsets(generation,dx,dy,dz,true);
}
NADSE_EXPORT uint32_t NADSE_SetTransform(uint64_t generation,float dx,float dy,float dz,float qx,float qy,float qz,float qw) {
    const float rotation[4]={qx,qy,qz,qw};return set_offsets(generation,dx,dy,dz,true,rotation);
}
NADSE_EXPORT uint32_t NADSE_SetAuthoredTransform(uint64_t generation,float dx,float dy,float dz,float qx,float qy,float qz,float qw) {
    const float rotation[4]={qx,qy,qz,qw};return set_offsets(generation,dx,dy,dz,true,rotation,false,true);
}
NADSE_EXPORT uint32_t NADSE_End(uint64_t generation) {
    AcquireSRWLockExclusive(&control_lock);
    struct Unlock {~Unlock(){ReleaseSRWLockExclusive(&control_lock);}} unlock;
    if(!generation)return reject(TOKEN_MISMATCH);
    if(!reserved.load(std::memory_order_acquire)) {
        if(generation!=retired_generation)return reject(TOKEN_MISMATCH);
        error(OK);return 1;
    }
    if(generation!=owned_generation)return reject(TOKEN_MISMATCH);
    armed.store(0,std::memory_order_release);
    active_generation.store(0,std::memory_order_relaxed);
    AcquireSRWLockExclusive(&policy_lock);restore_rig_if_owned();
    policy.observation.ready=false;policy.depth.valid=false;
    std::memset(policy.motion,0,sizeof policy.motion);std::memset(policy.rotation,0,sizeof policy.rotation);policy.rotation[3]=1;
    ReleaseSRWLockExclusive(&policy_lock);
    watched_viewmodel.store(0,std::memory_order_relaxed);
    if(!restore_slots())return reject(CLEANUP_PENDING);
    error(OK);return 1;
}
NADSE_EXPORT uint32_t NADSE_Error(void) {return last_error.load(std::memory_order_acquire);}
NADSE_EXPORT uint32_t NADSE_ReadStats(uint64_t generation,NADSE_Stats* output) {
    AcquireSRWLockExclusive(&control_lock);
    struct UnlockControl {~UnlockControl(){ReleaseSRWLockExclusive(&control_lock);}} unlock_control;
    if(reserved.load(std::memory_order_acquire)?(!generation || generation!=owned_generation):generation!=0)return reject(TOKEN_MISMATCH);
    NADSE_Stats s{};
    if(!read(reinterpret_cast<uint64_t>(output),&s,sizeof s) || s.size!=sizeof s || s.abi!=2)return reject(INVALID_CONFIG);
    if(armed.load(std::memory_order_acquire) && stats_deadline!=0 && tick()>=stats_deadline) {
        AcquireSRWLockExclusive(&policy_lock);
        if(armed.load(std::memory_order_acquire) && policy.deadline!=0 && tick()>=policy.deadline) {
            restore_rig_if_owned();armed.store(0,std::memory_order_release);expired.store(1,std::memory_order_release);
        }
        ReleaseSRWLockExclusive(&policy_lock);
    }
    read_diagnostics(s);
    s.installed=installed.load();s.armed=armed.load();s.expired=expired.load();s.error=last_error.load();
    s.seen_position=seen[0].load();s.seen_rotation=seen[1].load();s.weapon_updates=weapon_updates.load();s.zero_restores=zero_restores.load();
    s.forwarded_position=forwarded[0].load();s.forwarded_rotation=forwarded[1].load();
    SIZE_T actual=0;return WriteProcessMemory(GetCurrentProcess(),output,&s,sizeof s,&actual)!=0 && actual==sizeof s;
}
NADSE_EXPORT uint32_t NADSE_ReadDepthStats(uint64_t generation,NADSE_DepthStats* output) {
    AcquireSRWLockExclusive(&control_lock);
    struct UnlockControl {~UnlockControl(){ReleaseSRWLockExclusive(&control_lock);}} unlock_control;
    if(reserved.load(std::memory_order_acquire)?(!generation || generation!=owned_generation):generation!=0)return reject(TOKEN_MISMATCH);
    NADSE_DepthStats s{};
    if(!read(reinterpret_cast<uint64_t>(output),&s,sizeof s) || s.size!=sizeof s || s.abi!=1 || s.reserved)return reject(INVALID_CONFIG);
    AcquireSRWLockExclusive(&policy_lock);
    s=policy.depth.observed;s.cache_refreshes=policy.depth.refreshes;s.cache_checks=policy.depth.checks;
    ReleaseSRWLockExclusive(&policy_lock);
    s.size=sizeof s;s.abi=1;s.installed=installed.load();s.armed=armed.load();
    SIZE_T actual=0;return WriteProcessMemory(GetCurrentProcess(),output,&s,sizeof s,&actual)!=0 && actual==sizeof s;
}
