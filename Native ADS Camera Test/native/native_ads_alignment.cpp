// Owned atomic dispatch-pointer leases. Executable instructions are never written.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <intrin.h>
#include <atomic>
#include <cstdint>
#include <cstring>
#include "native_ads_alignment.h"
using Setter=void (*)(uint32_t,uint32_t,const float*);
static SRWLOCK control_lock=SRWLOCK_INIT,policy_lock=SRWLOCK_INIT;
static std::atomic<Setter> originals[2]{};
static std::atomic<uint32_t> installed{0},armed{0},reserved{0},expired{0},last_error{0};
static std::atomic<uint64_t> seen[2]{},skipped[2]{},forwarded[2]{},returns[2]{};
static uint64_t slots[2]{},slot_image=0;
static bool possible[2]{};
#if defined(NADS_FIXTURE)
static uint32_t fixture_cas_calls=0,fixture_cas_fail_at=0;
static uint32_t fixture_foreign_cas_at=0;
static uint64_t fixture_foreign_value=0;
static bool fixture_slot_unreadable=false,fixture_slot_readonly=false,fixture_fail_rollback=false;
static HANDLE fixture_before_arm_reached=nullptr,fixture_continue_arm=nullptr;
#endif
static constexpr uint32_t POSITION=0x1FC720,ROTATION=0x1FC880;
static constexpr uint32_t CALLS[2]={0x12887C9,0x12887E9};
static constexpr const char* PREFIX[2]={
    "48895c24084889742410574883ec20498bf08bfa8bd9e88511eaff4c8b5018b801000000f0410fc182380017008bc04c",
    "48895c24084889742410574883ec20498bf08bfa8bd9e82510eaff4c8b5018b801000000f0410fc182380017008bc04c"};
enum Error:uint32_t { OK=0,INVALID_CONFIG=1,BUSY=2,READ_FAILED=3,IMAGE_MISMATCH=4,
    CODE_MISMATCH=5,API_MISMATCH=6,OWNER_MISMATCH=7,UNIT_MISMATCH=8,PIN_FAILED=9,
    SLOT_NOT_WRITABLE=10,CAS_MISMATCH=11,CAS_FAULT=12,CLEANUP_PENDING=13 };
struct Policy { NADS_Config c{};uint64_t camera=0,controller=0,descriptor=0,object=0,deadline=0;uint8_t descriptor_bytes[20]{}; };
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
static bool unit_object(const NADS_Config& c,uint64_t& object) {
    uint64_t registry=0,gens=0,objects=0;uint32_t cap=0;uint8_t generation=0;
    const uint32_t index=c.viewmodel&0x3fffff;
    return pointer(c.exe+0x1A100F0,registry) && value(registry+0x98,cap) && index<cap && cap<=0x400000
        && pointer(registry+0xA0,gens) && value(gens+index,generation)
        && generation==static_cast<uint8_t>(c.viewmodel>>22) && pointer(registry+0x88,objects)
        && pointer(objects+static_cast<uint64_t>(index)*8,object);
}
static bool ownership(Policy& p,bool entering) {
    const NADS_Config& c=p.c;
    uint64_t ctx=0,owner=0,camera=0,controller=0,descriptor=0,object=0;
    uint32_t count=0,head=0,tail=0,viewmodel=0;
    uint8_t d[20]{},flags[24]{},controller_bytes[6]{};uint32_t request[4]{};
    if(!pointer(c.game+0x346D560,ctx) || ctx!=c.context || !pointer(ctx,camera)
        || !pointer(c.game+0x3326D20,owner) || owner!=c.avatar_owner
        || !pointer(c.game+0x347CE70,controller) || !read(controller,controller_bytes,sizeof controller_bytes)
        || !value(owner+0x6C,count) || count==0 || count>8 || c.avatar_index>=count
        || !pointer(owner+0x110+static_cast<uint64_t>(c.avatar_index)*8,descriptor)
        || !read(descriptor,d,sizeof d) || !read(owner+0x53E880+static_cast<uint64_t>(c.avatar_index)*0x1238,flags,sizeof flags)
        || !value(owner+0x53E9B8+static_cast<uint64_t>(c.avatar_index)*0x1238,viewmodel)
        || viewmodel!=c.viewmodel || !unit_object(c,object) || !value(ctx+0x1F8,head) || !value(ctx+0x1FC,tail)
        || head>=32 || tail>=32)return false;
    uint32_t avatar=0,body=0;std::memcpy(&avatar,d+8,4);std::memcpy(&body,d+12,4);
    if(avatar!=c.avatar || body!=c.body || (flags[6]&1)!=0 || (flags[14]&4)!=0)return false;
    for(uint8_t b:controller_bytes)if(b)return false;
    const uint64_t top=head==tail?ctx+0x1F00:ctx+0x200+((tail+31)%32)*0xE8;
    if(!read(top,request,sizeof request) || request[1]!=c.avatar)return false;
    if(entering) {
        if((request[0]&0xffff)!=4 || c.request!=ctx+0x200+tail*0xE8)return false;
        p.camera=camera;p.controller=controller;p.descriptor=descriptor;p.object=object;std::memcpy(p.descriptor_bytes,d,20);
        return true;
    }
    return top==c.request && (request[0]&0xffff)==6 && request[2]==c.weapon && request[3]==c.body
        && camera==p.camera && controller==p.controller && descriptor==p.descriptor && object==p.object
        && std::memcmp(d,p.descriptor_bytes,20)==0;
}

#if defined(NADS_FIXTURE)
static Setter fixture_targets[2]{};
static uint64_t fixture_now=0;
static uint64_t tick() {return fixture_now;}
#else
static uint64_t tick() {return GetTickCount64();}
#endif
static bool writable_slot(uint64_t slot,uint64_t exe) {
    if((slot&7)!=0)return false;
#if defined(NADS_FIXTURE)
    if(fixture_slot_readonly)return false;
    (void)exe;
#endif
    MEMORY_BASIC_INFORMATION r{};
    if(VirtualQuery(reinterpret_cast<const void*>(slot),&r,sizeof r)!=sizeof r || r.State!=MEM_COMMIT
        || r.Protect!=PAGE_READWRITE || slot+8>reinterpret_cast<uint64_t>(r.BaseAddress)+r.RegionSize)return false;
#if !defined(NADS_FIXTURE)
    if(r.Type!=MEM_IMAGE || reinterpret_cast<uint64_t>(r.AllocationBase)!=exe)return false;
#else
    if(r.Type!=MEM_PRIVATE)return false;
#endif
    return true;
}
static bool slot_read(uint64_t at,uint64_t& current) {
#if defined(NADS_FIXTURE)
    if(fixture_slot_unreadable)return false;
#endif
    return value(at,current);
}
static bool cas(uint64_t slot,uint64_t expected,uint64_t desired,uint64_t& observed) {
#if defined(NADS_FIXTURE)
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
static bool contract(const NADS_Config& c,Setter (&out)[2],uint64_t (&addresses)[2]) {
    if(!image(c.game,0x6AB3B43F,0x4744000) || !image(c.exe,0x6AB382E4,0x39E8000))return reject(IMAGE_MISMATCH);
    if(!bytes(c.game+CALLS[0],"41ff5138") || !bytes(c.game+CALLS[1],"41ff5148"))return reject(CODE_MISMATCH);
    uint64_t root=0,api=0,position=0,rotation=0;
    if(!pointer(c.game+0x3326308,root) || !pointer(root+0x18,api))return reject(API_MISMATCH);
    addresses[0]=api+0x38;addresses[1]=api+0x48;
    if(!writable_slot(addresses[0],c.exe) || !writable_slot(addresses[1],c.exe))return reject(SLOT_NOT_WRITABLE);
    if(!slot_read(addresses[0],position) || !slot_read(addresses[1],rotation))return reject(READ_FAILED);
    out[0]=reinterpret_cast<Setter>(position);out[1]=reinterpret_cast<Setter>(rotation);
#if defined(NADS_FIXTURE)
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
static bool dispatch_owned(const NADS_Config& c) {
    uint64_t root=0,api=0,a=0,b=0;
    return pointer(c.game+0x3326308,root) && pointer(root+0x18,api) && api+0x38==slots[0] && api+0x48==slots[1]
        && slot_read(slots[0],a) && slot_read(slots[1],b) && a==callback(0) && b==callback(1);
}
static bool should_skip(unsigned which,uint64_t caller,uint32_t unit,uint32_t node) {
    if(!armed.load(std::memory_order_acquire) || caller!=returns[which].load(std::memory_order_relaxed) || node!=0)return false;
    AcquireSRWLockShared(&policy_lock);
    bool answer=false;
    if(armed.load(std::memory_order_acquire) && unit==policy.c.viewmodel) {
        if(tick()>=policy.deadline) {armed.store(0,std::memory_order_release);expired.store(1,std::memory_order_release);}
        else if(ownership(policy,false) && dispatch_owned(policy.c))answer=true;
        else armed.store(0,std::memory_order_release);
    }
    ReleaseSRWLockShared(&policy_lock);return answer;
}
static void position_hook(uint32_t unit,uint32_t node,const float* pose) {
    seen[0].fetch_add(1,std::memory_order_relaxed);
    if(should_skip(0,reinterpret_cast<uint64_t>(_ReturnAddress()),unit,node)) {skipped[0].fetch_add(1,std::memory_order_relaxed);return;}
    forwarded[0].fetch_add(1,std::memory_order_relaxed);originals[0].load(std::memory_order_acquire)(unit,node,pose);
}
static void rotation_hook(uint32_t unit,uint32_t node,const float* pose) {
    seen[1].fetch_add(1,std::memory_order_relaxed);
    if(should_skip(1,reinterpret_cast<uint64_t>(_ReturnAddress()),unit,node)) {skipped[1].fetch_add(1,std::memory_order_relaxed);return;}
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
static bool copy_config(const NADS_Config* input,NADS_Config& c) {
    if(!read(reinterpret_cast<uint64_t>(input),&c,sizeof c) || c.size!=sizeof c || c.abi!=1
        || c.duration_ms==0 || c.duration_ms>10500 || c.avatar_index>=8 || c.avatar==0 || c.weapon==0 || c.body==0
        || c.viewmodel==0 || c.viewmodel==0xffffffff)return reject(INVALID_CONFIG);
    return true;
}
NADS_EXPORT uint32_t NADS_Validate(const NADS_Config* input) {
    AcquireSRWLockExclusive(&control_lock);
    struct Unlock {~Unlock(){ReleaseSRWLockExclusive(&control_lock);}} unlock;
    NADS_Config c{};if(!copy_config(input,c))return 0;
    if(reserved.load(std::memory_order_acquire))return reject(BUSY);
    Policy checked{};checked.c=c;Setter setters[2]{};uint64_t addresses[2]{};
    if(!ownership(checked,true))return reject(OWNER_MISMATCH);
    if(!contract(c,setters,addresses))return 0;
    if(!ownership(checked,true))return reject(OWNER_MISMATCH);
    error(OK);return 1;
}
NADS_EXPORT uint32_t NADS_Begin(const NADS_Config* input) {
    AcquireSRWLockExclusive(&control_lock);
    struct Unlock {~Unlock(){ReleaseSRWLockExclusive(&control_lock);}} unlock;
    NADS_Config c{};if(!copy_config(input,c))return 0;
    if(reserved.load(std::memory_order_acquire))return reject(BUSY);
    Policy next{};next.c=c;Setter verified[2]{};uint64_t addresses[2]{};
    if(!ownership(next,true))return reject(OWNER_MISMATCH);
    if(!contract(c,verified,addresses))return 0;
    for(unsigned i=0;i<2;++i)if(originals[i].load() && originals[i].load()!=verified[i])return reject(API_MISMATCH);
    if(!pin(reinterpret_cast<const void*>(&NADS_Begin)))return reject(PIN_FAILED);
#if !defined(NADS_FIXTURE)
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
    for(unsigned i=0;i<2;++i) {
        uint64_t current=0;
        if(!slot_read(slots[i],current) || current!=callback(i))return failed_begin(CAS_MISMATCH);
    }
#if defined(NADS_FIXTURE)
    if(fixture_before_arm_reached) {SetEvent(fixture_before_arm_reached);WaitForSingleObject(fixture_continue_arm,INFINITE);}
#endif
    AcquireSRWLockExclusive(&policy_lock);policy=next;policy.deadline=tick()+c.duration_ms;
    for(unsigned i=0;i<2;++i) {seen[i].store(0);skipped[i].store(0);forwarded[i].store(0);}
    returns[0].store(c.game+CALLS[0]+4,std::memory_order_relaxed);returns[1].store(c.game+CALLS[1]+4,std::memory_order_relaxed);
    expired.store(0,std::memory_order_release);armed.store(1,std::memory_order_release);ReleaseSRWLockExclusive(&policy_lock);
    error(OK);return 1;
}
NADS_EXPORT uint32_t NADS_End(void) {
    AcquireSRWLockExclusive(&control_lock);
    struct Unlock {~Unlock(){ReleaseSRWLockExclusive(&control_lock);}} unlock;
    armed.store(0,std::memory_order_release);
    AcquireSRWLockExclusive(&policy_lock);ReleaseSRWLockExclusive(&policy_lock);
    if(!restore_slots())return reject(CLEANUP_PENDING);
    error(OK);return 1;
}
NADS_EXPORT uint32_t NADS_Error(void) {return last_error.load(std::memory_order_acquire);}
NADS_EXPORT uint32_t NADS_ReadStats(NADS_Stats* output) {
    NADS_Stats s{};
    if(!read(reinterpret_cast<uint64_t>(output),&s,sizeof s) || s.size!=sizeof s || s.abi!=1)return reject(INVALID_CONFIG);
    AcquireSRWLockShared(&policy_lock);
    if(armed.load(std::memory_order_acquire) && tick()>=policy.deadline) {armed.store(0,std::memory_order_release);expired.store(1,std::memory_order_release);}
    ReleaseSRWLockShared(&policy_lock);
    s.installed=installed.load();s.armed=armed.load();s.expired=expired.load();s.error=last_error.load();
    s.seen_position=seen[0].load();s.seen_rotation=seen[1].load();s.skipped_position=skipped[0].load();s.skipped_rotation=skipped[1].load();
    s.forwarded_position=forwarded[0].load();s.forwarded_rotation=forwarded[1].load();
    SIZE_T actual=0;return WriteProcessMemory(GetCurrentProcess(),output,&s,sizeof s,&actual)!=0 && actual==sizeof s;
}
