// Native roots remain exact. Offset only the verified shared arms/weapon node.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <intrin.h>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <cmath>
#include "native_ads_pose.h"
using Setter=void (*)(uint32_t,uint32_t,const float*);
static SRWLOCK control_lock=SRWLOCK_INIT,policy_lock=SRWLOCK_INIT;
static std::atomic<Setter> originals[2]{};
static std::atomic<uint32_t> installed{0},armed{0},reserved{0},expired{0},last_error{0};
static std::atomic<uint64_t> seen[2]{},forwarded[2]{},rig_return{0};
static std::atomic<uint64_t> weapon_updates{0},zero_restores{0};
static uint64_t slots[2]{},slot_image=0;
static bool possible[2]{};
#if defined(NADSP_FIXTURE)
static uint32_t fixture_cas_calls=0,fixture_cas_fail_at=0;
static uint32_t fixture_foreign_cas_at=0;
static uint64_t fixture_foreign_value=0;
static bool fixture_slot_unreadable=false,fixture_slot_readonly=false,fixture_fail_rollback=false;
static HANDLE fixture_before_arm_reached=nullptr,fixture_continue_arm=nullptr;
#endif
static constexpr uint32_t POSITION=0x1FC720,ROTATION=0x1FC880;
static constexpr uint32_t CALLS[2]={0x12887C9,0x12887E9};
static constexpr uint32_t RIG_CALL=0x1288420,GRAPH_GETTER=0x2BD870,RIG_NODE=5;
static constexpr const char* PREFIX[2]={
    "48895c24084889742410574883ec20498bf08bfa8bd9e88511eaff4c8b5018b801000000f0410fc182380017008bc04c",
    "48895c24084889742410574883ec20498bf08bfa8bd9e82510eaff4c8b5018b801000000f0410fc182380017008bc04c"};
enum Error:uint32_t { OK=0,INVALID_CONFIG=1,BUSY=2,READ_FAILED=3,IMAGE_MISMATCH=4,
    CODE_MISMATCH=5,API_MISMATCH=6,OWNER_MISMATCH=7,UNIT_MISMATCH=8,PIN_FAILED=9,
    SLOT_NOT_WRITABLE=10,CAS_MISMATCH=11,CAS_FAULT=12,CLEANUP_PENDING=13,SIGHT_NODE_UNAVAILABLE=14,
    GRAPH_MISMATCH=15,POSE_INVALID=16 };
struct Policy {
    NADSP_Config c{};uint64_t camera=0,controller=0,descriptor=0,object=0,weapon_object=0,deadline=0;
    uint8_t descriptor_bytes[20]{},weapon_bytes[20]{};
    uint64_t graph_vtable=0,graph_links=0,graph_hashes=0;
    bool real_aiming=false,rig_shifted=false;
    float baseline[4]{};
    float weight=0,target=1,start_weight=0;uint64_t blend_start=0;
};
static Policy policy;
static bool read(uint64_t at,void* out,size_t length) {
    if(at<65536 || at>=0x800000000000ULL || length>1024 || at+length>=0x800000000000ULL)return false;
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
static bool unit_object(const NADSP_Config& c,uint32_t ref,uint64_t& object) {
    uint64_t registry=0,gens=0,objects=0;uint32_t cap=0;uint8_t generation=0;
    const uint32_t index=ref&0x3fffff;
    return pointer(c.exe+0x1A100F0,registry) && value(registry+0x98,cap) && index<cap && cap<=0x400000
        && pointer(registry+0xA0,gens) && value(gens+index,generation)
        && generation==static_cast<uint8_t>(ref>>22) && pointer(registry+0x88,objects)
        && pointer(objects+static_cast<uint64_t>(index)*8,object);
}
static bool ownership(Policy& p,bool entering) {
    const NADSP_Config& c=p.c;
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
    p.real_aiming=(flags[6]&1)!=0 || controller_bytes[4]!=0;
    if(entering && p.real_aiming)return false;
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
#if !defined(NADSP_FIXTURE)
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
    for(const auto& row:rows) {
        uint32_t hash=0,link=0;
        if(!value(hashes+static_cast<uint64_t>(row.node)*4,hash) || hash!=row.hash
            || !value(links+static_cast<uint64_t>(row.node)*4,link) || link!=row.link)return false;
    }
    if(capture) {p.graph_vtable=vtable;p.graph_links=links;p.graph_hashes=hashes;}
    return true;
}

#if defined(NADSP_FIXTURE)
static Setter fixture_targets[2]{};
static uint64_t fixture_now=0;
static uint64_t tick() {return fixture_now;}
#else
static uint64_t tick() {return GetTickCount64();}
#endif
static bool writable_slot(uint64_t slot,uint64_t exe) {
    if((slot&7)!=0)return false;
#if defined(NADSP_FIXTURE)
    if(fixture_slot_readonly)return false;
    (void)exe;
#endif
    MEMORY_BASIC_INFORMATION r{};
    if(VirtualQuery(reinterpret_cast<const void*>(slot),&r,sizeof r)!=sizeof r || r.State!=MEM_COMMIT
        || r.Protect!=PAGE_READWRITE || slot+8>reinterpret_cast<uint64_t>(r.BaseAddress)+r.RegionSize)return false;
#if !defined(NADSP_FIXTURE)
    if(r.Type!=MEM_IMAGE || reinterpret_cast<uint64_t>(r.AllocationBase)!=exe)return false;
#else
    if(r.Type!=MEM_PRIVATE)return false;
#endif
    return true;
}
static bool slot_read(uint64_t at,uint64_t& current) {
#if defined(NADSP_FIXTURE)
    if(fixture_slot_unreadable)return false;
#endif
    return value(at,current);
}
static bool cas(uint64_t slot,uint64_t expected,uint64_t desired,uint64_t& observed) {
#if defined(NADSP_FIXTURE)
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
static bool contract(const NADSP_Config& c,Setter (&out)[2],uint64_t (&addresses)[2]) {
    if(!image(c.game,0x6AB3B43F,0x4744000) || !image(c.exe,0x6AB382E4,0x39E8000))return reject(IMAGE_MISMATCH);
    if(!bytes(c.game+CALLS[0],"41ff5138") || !bytes(c.game+CALLS[1],"41ff5148")
        || !bytes(c.game+RIG_CALL,"41ff5138"))return reject(CODE_MISMATCH);
    uint64_t root=0,api=0,position=0,rotation=0;
    if(!pointer(c.game+0x3326308,root) || !pointer(root+0x18,api))return reject(API_MISMATCH);
    addresses[0]=api+0x38;addresses[1]=api+0x48;
    if(!writable_slot(addresses[0],c.exe) || !writable_slot(addresses[1],c.exe))return reject(SLOT_NOT_WRITABLE);
    if(!slot_read(addresses[0],position) || !slot_read(addresses[1],rotation))return reject(READ_FAILED);
    out[0]=reinterpret_cast<Setter>(position);out[1]=reinterpret_cast<Setter>(rotation);
#if defined(NADSP_FIXTURE)
    if(out[0]!=fixture_targets[0] || out[1]!=fixture_targets[1])return reject(API_MISMATCH);
    if(!bytes(c.exe+POSITION,PREFIX[0]) || !bytes(c.exe+ROTATION,PREFIX[1]))return reject(CODE_MISMATCH);
#else
    if(position!=c.exe+POSITION || rotation!=c.exe+ROTATION)return reject(API_MISMATCH);
    if(!bytes(position,PREFIX[0]) || !bytes(rotation,PREFIX[1]))return reject(CODE_MISMATCH);
#endif
    if(!executable(position) || !executable(rotation))return reject(API_MISMATCH);
    return true;
}
static uint64_t callback(unsigned which);
static bool dispatch_owned(const NADSP_Config& c) {
    uint64_t root=0,api=0,a=0,b=0;
    return pointer(c.game+0x3326308,root) && pointer(root+0x18,api) && api+0x38==slots[0] && api+0x48==slots[1]
        && slot_read(slots[0],a) && slot_read(slots[1],b) && a==callback(0) && b==callback(1);
}
// policy_lock is held. Never replay a cached pose into a different owner/rig.
static void restore_rig_if_owned() {
    if(policy.rig_shifted && ownership(policy,false) && graph(policy,false)) {
        alignas(16) float native[4];std::memcpy(native,policy.baseline,16);
        originals[0].load(std::memory_order_acquire)(policy.c.viewmodel,RIG_NODE,native);
        zero_restores.fetch_add(1,std::memory_order_relaxed);
    }
    policy.rig_shifted=false;
}
static bool finite_pose(const float (&pose)[4]) {
    for(unsigned i=0;i<3;++i)if(!std::isfinite(pose[i]))return false;
    return true;
}
static void forward_position(uint32_t unit,uint32_t node,const float* pose) {
    forwarded[0].fetch_add(1,std::memory_order_relaxed);
    originals[0].load(std::memory_order_acquire)(unit,node,pose);
}
static void position_call(uint64_t caller,uint32_t unit,uint32_t node,const float* pose) {
    if(!armed.load(std::memory_order_acquire) || caller!=rig_return.load(std::memory_order_relaxed)) {
        forward_position(unit,node,pose);return;
    }
    AcquireSRWLockExclusive(&policy_lock);
    struct Unlock {~Unlock(){ReleaseSRWLockExclusive(&policy_lock);}} unlock;
    if(!armed.load(std::memory_order_acquire)) {
        forward_position(unit,node,pose);return;
    }
    if(unit!=policy.c.viewmodel || node!=RIG_NODE) {forward_position(unit,node,pose);return;}
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
    if(failure!=OK || now>=policy.deadline) {
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
    const float target=policy.real_aiming?0.0f:1.0f;
    if(target!=policy.target) {policy.start_weight=policy.weight;policy.target=target;policy.blend_start=now;}
    alignas(16) float shifted[4];std::memcpy(shifted,native,16);
    if(policy.weight!=0) {shifted[0]+=policy.c.offset_x*policy.weight;shifted[2]+=policy.c.offset_z*policy.weight;}
    if(!finite_pose(shifted)) {
        policy.rig_shifted=false;armed.store(0,std::memory_order_release);error(POSE_INVALID);
        forward_position(unit,node,pose);return;
    }
    std::memcpy(policy.baseline,native,16);
    policy.rig_shifted=std::memcmp(shifted,native,16)!=0;
    if(policy.rig_shifted) {
        weapon_updates.fetch_add(1,std::memory_order_relaxed);
        forward_position(unit,node,shifted);
    } else forward_position(unit,node,pose);
}
static void position_hook(uint32_t unit,uint32_t node,const float* pose) {
    seen[0].fetch_add(1,std::memory_order_relaxed);
    position_call(reinterpret_cast<uint64_t>(_ReturnAddress()),unit,node,pose);
}
static void rotation_hook(uint32_t unit,uint32_t node,const float* pose) {
    seen[1].fetch_add(1,std::memory_order_relaxed);
    forwarded[1].fetch_add(1,std::memory_order_relaxed);originals[1].load(std::memory_order_acquire)(unit,node,pose);
}
static bool pin(const void* address) {
    HMODULE module=nullptr;return GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_PIN,
        reinterpret_cast<LPCWSTR>(address),&module)!=0;
}
static uint64_t callback(unsigned which) {
    return reinterpret_cast<uint64_t>(which?rotation_hook:position_hook);
}
// control_lock is held; callbacks have already been disarmed and drained.
static bool restore_slots() {
    bool pending=false;
    for(unsigned i=0;i<2;++i)if(possible[i]) {
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
    if(!pending)reserved.store(0,std::memory_order_release);
    return !pending;
}
static uint32_t failed_begin(uint32_t cause) {
    armed.store(0,std::memory_order_release);
    AcquireSRWLockExclusive(&policy_lock);ReleaseSRWLockExclusive(&policy_lock);
    if(!restore_slots()) {error(CLEANUP_PENDING);return 2;}
    error(cause);return 0;
}
static bool copy_config(const NADSP_Config* input,NADSP_Config& c) {
    if(!read(reinterpret_cast<uint64_t>(input),&c,sizeof c) || c.size!=sizeof c || c.abi!=1
        || c.duration_ms==0 || c.duration_ms>10500 || c.avatar_index>=8 || c.avatar==0 || c.weapon==0 || c.body==0
        || c.viewmodel==0 || c.viewmodel==0xffffffff || c.weapon_unit==0 || c.weapon_unit==0xffffffff
        || c.weapon_unit==c.viewmodel || c.weapon_unit==c.body || c.weapon_descriptor<65536
        || c.blend_ms==0 || c.blend_ms>1000 || !std::isfinite(c.offset_x) || !std::isfinite(c.offset_z)
        || std::fabs(c.offset_x)>0.5f || std::fabs(c.offset_z)>0.5f)return reject(INVALID_CONFIG);
    return true;
}
NADSP_EXPORT uint32_t NADSP_Validate(const NADSP_Config* input) {
    AcquireSRWLockExclusive(&control_lock);
    struct Unlock {~Unlock(){ReleaseSRWLockExclusive(&control_lock);}} unlock;
    NADSP_Config c{};if(!copy_config(input,c))return 0;
    if(reserved.load(std::memory_order_acquire))return reject(BUSY);
    Policy checked{};checked.c=c;Setter setters[2]{};uint64_t addresses[2]{};
    if(!ownership(checked,true))return reject(OWNER_MISMATCH);
    if(!graph(checked,true))return reject(GRAPH_MISMATCH);
    if(!contract(c,setters,addresses))return 0;
    if(!ownership(checked,true))return reject(OWNER_MISMATCH);
    if(!graph(checked,false))return reject(GRAPH_MISMATCH);
    error(OK);return 1;
}
NADSP_EXPORT uint32_t NADSP_Begin(const NADSP_Config* input) {
    AcquireSRWLockExclusive(&control_lock);
    struct Unlock {~Unlock(){ReleaseSRWLockExclusive(&control_lock);}} unlock;
    NADSP_Config c{};if(!copy_config(input,c))return 0;
    if(reserved.load(std::memory_order_acquire))return reject(BUSY);
    Policy next{};next.c=c;Setter verified[2]{};uint64_t addresses[2]{};
    if(!ownership(next,true))return reject(OWNER_MISMATCH);
    if(!graph(next,true))return reject(GRAPH_MISMATCH);
    if(!contract(c,verified,addresses))return 0;
    for(unsigned i=0;i<2;++i)if(originals[i].load() && originals[i].load()!=verified[i])return reject(API_MISMATCH);
    if(!pin(reinterpret_cast<const void*>(&NADSP_Begin)))return reject(PIN_FAILED);
#if !defined(NADSP_FIXTURE)
    if(!pin(reinterpret_cast<const void*>(c.exe)))return reject(PIN_FAILED);
#endif
    for(unsigned i=0;i<2;++i) {originals[i].store(verified[i],std::memory_order_release);slots[i]=addresses[i];possible[i]=false;}
    slot_image=c.exe;reserved.store(1,std::memory_order_release);
    // Original callbacks are visible before either pointer is published. Until
    // the final arm store, even a cached or in-flight callback only forwards.
    for(unsigned i=0;i<2;++i) {
        possible[i]=true;uint64_t observed=0;
        if(!writable_slot(slots[i],c.exe))return failed_begin(SLOT_NOT_WRITABLE);
        if(!cas(slots[i],reinterpret_cast<uint64_t>(verified[i]),callback(i),observed))return failed_begin(CAS_FAULT);
        if(observed!=reinterpret_cast<uint64_t>(verified[i])) {possible[i]=false;return failed_begin(CAS_MISMATCH);}
        installed.store(1,std::memory_order_release);
    }
    if(!ownership(next,true))return failed_begin(OWNER_MISMATCH);
    if(!graph(next,false))return failed_begin(GRAPH_MISMATCH);
    for(unsigned i=0;i<2;++i) {
        uint64_t current=0;
        if(!slot_read(slots[i],current) || current!=callback(i))return failed_begin(CAS_MISMATCH);
    }
#if defined(NADSP_FIXTURE)
    if(fixture_before_arm_reached) {SetEvent(fixture_before_arm_reached);WaitForSingleObject(fixture_continue_arm,INFINITE);}
#endif
    AcquireSRWLockExclusive(&policy_lock);policy=next;policy.deadline=tick()+c.duration_ms;policy.blend_start=tick();
    for(unsigned i=0;i<2;++i) {seen[i].store(0);forwarded[i].store(0);}
    weapon_updates.store(0);zero_restores.store(0);
    rig_return.store(c.game+RIG_CALL+4,std::memory_order_relaxed);
    expired.store(0,std::memory_order_release);armed.store(1,std::memory_order_release);ReleaseSRWLockExclusive(&policy_lock);
    error(OK);return 1;
}
NADSP_EXPORT uint32_t NADSP_End(void) {
    AcquireSRWLockExclusive(&control_lock);
    struct Unlock {~Unlock(){ReleaseSRWLockExclusive(&control_lock);}} unlock;
    if(!reserved.load(std::memory_order_acquire)) {error(OK);return 1;}
    armed.store(0,std::memory_order_release);
    AcquireSRWLockExclusive(&policy_lock);restore_rig_if_owned();ReleaseSRWLockExclusive(&policy_lock);
    if(!restore_slots())return reject(CLEANUP_PENDING);
    error(OK);return 1;
}
NADSP_EXPORT uint32_t NADSP_Error(void) {return last_error.load(std::memory_order_acquire);}
NADSP_EXPORT uint32_t NADSP_ReadStats(NADSP_Stats* output) {
    NADSP_Stats s{};
    if(!read(reinterpret_cast<uint64_t>(output),&s,sizeof s) || s.size!=sizeof s || s.abi!=1)return reject(INVALID_CONFIG);
    AcquireSRWLockExclusive(&policy_lock);
    if(armed.load(std::memory_order_acquire) && tick()>=policy.deadline) {restore_rig_if_owned();armed.store(0,std::memory_order_release);expired.store(1,std::memory_order_release);}
    s.blend=policy.weight;s.target_weight=policy.target;
    ReleaseSRWLockExclusive(&policy_lock);
    s.installed=installed.load();s.armed=armed.load();s.expired=expired.load();s.error=last_error.load();
    s.seen_position=seen[0].load();s.seen_rotation=seen[1].load();s.weapon_updates=weapon_updates.load();s.zero_restores=zero_restores.load();
    s.forwarded_position=forwarded[0].load();s.forwarded_rotation=forwarded[1].load();
    SIZE_T actual=0;return WriteProcessMemory(GetCurrentProcess(),output,&s,sizeof s,&actual)!=0 && actual==sizeof s;
}
