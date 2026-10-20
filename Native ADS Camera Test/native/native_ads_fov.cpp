// Separate hip/shoulder FOV policy; no camera/weapon transforms or settings.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <intrin.h>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <cmath>
#include "native_ads_fov.h"
using Setter=void (*)(void*,float);
static SRWLOCK control_lock=SRWLOCK_INIT,policy_lock=SRWLOCK_INIT;
static std::atomic<Setter> original{nullptr};
static std::atomic<uint32_t> installed{0},armed{0},reserved{0},last_error{0};
static std::atomic<uint64_t> seen{0},forwarded{0},replaced{0},immediate_applies{0},binds{0},ads_forwarded{0},return_address{0};
static uint64_t slot=0,slot_image=0,generation_counter=0,owned_generation=0,retired_generation=0;
static bool possible=false;
static constexpr uint32_t SETTER=0x30D990,GETTER=0x30D980,CALL=0x127A11A;
static constexpr float RAD_PER_DEG=0.01745329251994329577f;
enum Error:uint32_t { OK=0,INVALID_CONFIG=1,BUSY=2,READ_FAILED=3,IMAGE_MISMATCH=4,
    CODE_MISMATCH=5,API_MISMATCH=6,OWNER_MISMATCH=7,UNIT_MISMATCH=8,PIN_FAILED=9,
    SLOT_NOT_WRITABLE=10,CAS_MISMATCH=11,CAS_FAULT=12,CLEANUP_PENDING=13,
    SOURCE_INVALID=14,TOKEN_MISMATCH=17 };
struct Policy {
    NADSF_Config c{};uint64_t controller=0,descriptor=0,registry=0,units=0,generations=0,body_object=0;
    uint8_t descriptor_bytes[20]{};bool shoulder_aim=false,full_ads=false,safe=false;
    bool shoulder_target=false,shoulder_clock=false;double shoulder_previous=0;
    float shoulder_weight=0;
    float last_native=0,last_applied=0,source_degrees=0;
};
static Policy policy;
// Diagnostics must never make the update thread wait for an in-flight camera
// setter. Writers are serialized by policy_lock (or a disarmed new Begin).
// One bounded sequence check returns either a complete new tuple or the last
// complete tuple; lifecycle/health fields are read separately and stay fresh.
struct Display {float native=0,applied=0,degrees=0;};
static Display display_cache; // control_lock only; never accessed by a setter.
static std::atomic<uint32_t> display_sequence{0};
static std::atomic<float> display_native{0},display_applied{0},display_degrees{0};
static_assert(std::atomic<float>::is_always_lock_free,"FOV diagnostics require lock-free floats");
static void publish_diagnostics(const Policy& p) {
    display_sequence.fetch_add(1,std::memory_order_seq_cst);
    display_native.store(p.last_native,std::memory_order_seq_cst);
    display_applied.store(p.last_applied,std::memory_order_seq_cst);
    display_degrees.store(p.source_degrees,std::memory_order_seq_cst);
    display_sequence.fetch_add(1,std::memory_order_seq_cst);
}
static void read_diagnostics(NADSF_Stats& s) {
    const uint32_t before=display_sequence.load(std::memory_order_seq_cst);
    if((before&1)==0) {
        const Display next{display_native.load(std::memory_order_seq_cst),display_applied.load(std::memory_order_seq_cst),
            display_degrees.load(std::memory_order_seq_cst)};
        if(before==display_sequence.load(std::memory_order_seq_cst))display_cache=next;
    }
    s.last_native=display_cache.native;s.last_applied=display_cache.applied;s.source_degrees=display_cache.degrees;
}
#if defined(NADSF_FIXTURE)
static Setter fixture_target=nullptr;
static uint32_t fixture_cas_calls=0,fixture_cas_fail_at=0,fixture_foreign_cas_at=0;
static uint64_t fixture_foreign_value=0;
static bool fixture_slot_unreadable=false,fixture_slot_readonly=false;
static HANDLE fixture_before_arm_reached=nullptr,fixture_continue_arm=nullptr;
static double fixture_now=0;static uint64_t fixture_clock_reads=0;
static bool fixture_clock_ok=true;
#endif
static bool seconds(double& out) {
#if defined(NADSF_FIXTURE)
    ++fixture_clock_reads;out=fixture_now;return fixture_clock_ok && std::isfinite(out);
#else
    static const double frequency=[]() {
        LARGE_INTEGER f{};return QueryPerformanceFrequency(&f) && f.QuadPart>0?static_cast<double>(f.QuadPart):0.0;
    }();
    LARGE_INTEGER ticks{};
    if(frequency<=0 || !QueryPerformanceCounter(&ticks))return false;
    out=static_cast<double>(ticks.QuadPart)/frequency;return std::isfinite(out);
#endif
}
static void reset_shoulder(Policy& p) {
    p.shoulder_weight=0;p.shoulder_target=false;p.shoulder_clock=false;
}
static float shoulder_lens(Policy& p,float hip) {
    const float target=p.shoulder_aim?1.0f:0.0f;
    // Settled hip is bit-exact TPV, without clock sampling or trigonometry.
    // A settled shoulder also needs no clock until the aim state changes.
    if(p.shoulder_weight!=target) {
        double now=0;
        if(!seconds(now)) {reset_shoulder(p);return hip;}
        if(!p.shoulder_clock || p.shoulder_target!=p.shoulder_aim) {
            p.shoulder_target=p.shoulder_aim;p.shoulder_clock=true;
        } else {
            const double elapsed=now-p.shoulder_previous;
            // Rebase after a pause/rollback; never integrate an unbounded gap.
            if(elapsed>=0 && elapsed<=.25) {
                const float step=static_cast<float>(fmin(elapsed,.12)/.12);
                p.shoulder_weight=p.shoulder_aim?fminf(1,p.shoulder_weight+step):fmaxf(0,p.shoulder_weight-step);
            }
        }
        p.shoulder_previous=now;
    }
    if(p.shoulder_weight==0)return hip;
    const float w=p.shoulder_weight*p.shoulder_weight*(3-2*p.shoulder_weight);
    return 2*std::atan(std::tan(hip*.5f)/(1+.05f*w));
}
static bool read(uint64_t at,void* out,size_t length) {
    if(at<65536 || at>=0x800000000000ULL || length>1024 || at+length>=0x800000000000ULL)return false;
    SIZE_T actual=0;return ReadProcessMemory(GetCurrentProcess(),reinterpret_cast<const void*>(at),out,length,&actual)!=0 && actual==length;
}
template<class T> static bool value(uint64_t at,T& out) {return read(at,&out,sizeof out);}
static bool pointer(uint64_t at,uint64_t& out) {return value(at,out) && out>=65536 && out<0x800000000000ULL;}
static void error(uint32_t code) {last_error.store(code,std::memory_order_release);}
static uint32_t reject(uint32_t code) {error(code);return 0;}
static bool image(uint64_t base,uint32_t stamp,uint32_t length) {
    IMAGE_DOS_HEADER dos{};IMAGE_NT_HEADERS64 nt{};
    return read(base,&dos,sizeof dos) && dos.e_magic==IMAGE_DOS_SIGNATURE && dos.e_lfanew>=64 && dos.e_lfanew<=4096
        && read(base+dos.e_lfanew,&nt,sizeof nt) && nt.Signature==IMAGE_NT_SIGNATURE
        && nt.FileHeader.Machine==IMAGE_FILE_MACHINE_AMD64 && nt.OptionalHeader.Magic==IMAGE_NT_OPTIONAL_HDR64_MAGIC
        && nt.FileHeader.TimeDateStamp==stamp && nt.OptionalHeader.SizeOfImage==length;
}
static bool bytes(uint64_t at,const char* hex) {
    uint8_t actual[64]{};const size_t count=std::strlen(hex)/2;
    if(!count || count>sizeof actual || !read(at,actual,count))return false;
    for(size_t i=0;i<count;++i) {
        auto digit=[](char c)->uint8_t{return static_cast<uint8_t>(c<='9'?c-'0':c-'a'+10);};
        if(actual[i]!=static_cast<uint8_t>((digit(hex[i*2])<<4)|digit(hex[i*2+1])))return false;
    }return true;
}
static bool executable(uint64_t at) {
    MEMORY_BASIC_INFORMATION r{};
    if(VirtualQuery(reinterpret_cast<const void*>(at),&r,sizeof r)!=sizeof r || r.State!=MEM_COMMIT || r.Type!=MEM_IMAGE)return false;
    return r.Protect==PAGE_EXECUTE_READ || r.Protect==PAGE_EXECUTE_READWRITE || r.Protect==PAGE_EXECUTE_WRITECOPY;
}
static bool owner(Policy& p,bool capture) {
    const auto& c=p.c;uint64_t ctx=0,camera=0,avatar_owner=0,controller=0,descriptor=0,registry=0,units=0,generations=0,object=0;
    uint32_t count=0,capacity=0;uint8_t d[20]{},flags[24]{},controls[6]{},generation=0,confirmed=0;uint64_t confirmed_object=0;
    const uint32_t index=c.body&0x3fffff;
    if(!pointer(c.game+0x346D560,ctx) || ctx!=c.context || !pointer(ctx,camera) || camera!=c.camera
        || !pointer(c.game+0x3326D20,avatar_owner) || avatar_owner!=c.avatar_owner
        || !pointer(c.game+0x347CE70,controller) || !read(controller,controls,6)
        || !value(avatar_owner+0x6C,count) || count==0 || count>8 || c.avatar_index>=count
        || !pointer(avatar_owner+0x110+static_cast<uint64_t>(c.avatar_index)*8,descriptor) || !read(descriptor,d,20)
        || !read(avatar_owner+0x53E880+static_cast<uint64_t>(c.avatar_index)*0x1238,flags,24)
        || !pointer(c.exe+0x1A100F0,registry) || !value(registry+0x98,capacity) || capacity==0 || capacity>0x400000 || index>=capacity
        || !pointer(registry+0xA0,generations) || !value(generations+index,generation) || generation!=static_cast<uint8_t>(c.body>>22)
        || !pointer(registry+0x88,units) || !pointer(units+static_cast<uint64_t>(index)*8,object)
        || !value(generations+index,confirmed) || confirmed!=generation
        || !pointer(units+static_cast<uint64_t>(index)*8,confirmed_object) || confirmed_object!=object)return false;
    uint32_t avatar=0,body=0,mask=0;std::memcpy(&avatar,d+8,4);std::memcpy(&body,d+12,4);std::memcpy(&mask,controls,4);
    if(avatar!=c.avatar || body!=c.body)return false;
    if(capture) {
        p.controller=controller;p.descriptor=descriptor;p.registry=registry;p.units=units;p.generations=generations;p.body_object=object;
        std::memcpy(p.descriptor_bytes,d,20);
    } else if(controller!=p.controller || descriptor!=p.descriptor || registry!=p.registry || units!=p.units
        || generations!=p.generations || object!=p.body_object || std::memcmp(d,p.descriptor_bytes,20)!=0)return false;
    // Current normal aim is the agreeing82/125 pair, independent of legacy48.
    // Full native ADS always wins, even while those shoulder flags linger.
    p.full_ads=controls[4]!=0;
    p.shoulder_aim=!p.full_ads && (flags[10]&4)!=0 && (flags[15]&32)!=0;
    p.safe=(mask==0 || mask==2) && controls[5]==0 && (flags[14]&4)==0;
    return true;
}
static bool request_matches(const Policy& p,bool allow_normal=false) {
    uint32_t head=0,tail=0,r[4]{};
    if(!value(p.c.context+0x1F8,head) || !value(p.c.context+0x1FC,tail) || head>=32 || tail>=32)return false;
    const uint64_t at=head==tail?p.c.context+0x1F00:p.c.context+0x200+((tail+31)%32)*0xE8;
    if(at!=p.c.request || !read(at,r,16) || r[1]!=p.c.avatar)return false;
    if(allow_normal && (r[0]&0xffff)==4)return true;
    return head!=tail && (r[0]&0xffff)==6 && r[2]==p.c.weapon && r[3]==p.c.body;
}
static bool source(Policy& p,float& radians) {
    uint64_t settings=0;float degrees=0;
    if(!pointer(p.c.game+0x3326340,settings) || !value(settings+0xAC408,degrees)
        || !std::isfinite(degrees) || degrees<1 || degrees>179)return false;
    radians=degrees*RAD_PER_DEG;p.source_degrees=degrees;return std::isfinite(radians);
}
static bool writable_slot(uint64_t at,uint64_t exe) {
    if((at&7)!=0)return false;
#if defined(NADSF_FIXTURE)
    if(fixture_slot_readonly)return false;
    (void)exe;
#endif
    MEMORY_BASIC_INFORMATION r{};
    if(VirtualQuery(reinterpret_cast<const void*>(at),&r,sizeof r)!=sizeof r || r.State!=MEM_COMMIT || r.Protect!=PAGE_READWRITE
        || at+8>reinterpret_cast<uint64_t>(r.BaseAddress)+r.RegionSize)return false;
#if !defined(NADSF_FIXTURE)
    return r.Type==MEM_IMAGE && reinterpret_cast<uint64_t>(r.AllocationBase)==exe;
#else
    return r.Type==MEM_PRIVATE;
#endif
}
static bool slot_read(uint64_t at,uint64_t& out) {
#if defined(NADSF_FIXTURE)
    if(fixture_slot_unreadable)return false;
#endif
    return value(at,out);
}
static bool cas(uint64_t expected,uint64_t desired,uint64_t& observed) {
#if defined(NADSF_FIXTURE)
    if(++fixture_cas_calls==fixture_cas_fail_at)return false;
    if(fixture_cas_calls==fixture_foreign_cas_at)InterlockedExchangePointer(reinterpret_cast<PVOID volatile*>(slot),reinterpret_cast<void*>(fixture_foreign_value));
#endif
    __try {
        observed=reinterpret_cast<uint64_t>(InterlockedCompareExchangePointer(reinterpret_cast<PVOID volatile*>(slot),
            reinterpret_cast<void*>(desired),reinterpret_cast<void*>(expected)));return true;
    } __except(EXCEPTION_EXECUTE_HANDLER) {return false;}
}
static bool binary_contract(const NADSF_Config& c) {
    if(!image(c.game,0x6AB3B43F,0x4744000) || !image(c.exe,0x6AB382E4,0x39E8000))return reject(IMAGE_MISMATCH)!=0;
    if(!bytes(c.game+CALL,"ff9280000000") || !bytes(c.exe+SETTER,"f30f114934c7415000000000e90f211c00")
        || !bytes(c.exe+GETTER,"f30f104134c3"))return reject(CODE_MISMATCH)!=0;
    return true;
}
static bool contract(const NADSF_Config& c,Setter& setter,uint64_t& address) {
    if(!binary_contract(c))return false;
    uint64_t root=0,api=0,target=0,getter=0;
    if(!pointer(c.game+0x3326308,root) || !pointer(root+0x20,api) || !slot_read(api+0x80,target)
        || !pointer(api+0x78,getter) || getter!=c.exe+GETTER)return reject(API_MISMATCH)!=0;
    address=api+0x80;
    if(!writable_slot(address,c.exe))return reject(SLOT_NOT_WRITABLE)!=0;
#if defined(NADSF_FIXTURE)
    if(target!=reinterpret_cast<uint64_t>(fixture_target))return reject(API_MISMATCH)!=0;
#else
    if(target!=c.exe+SETTER || !executable(getter))return reject(API_MISMATCH)!=0;
#endif
    if(!executable(target))return reject(API_MISMATCH)!=0;
    setter=reinterpret_cast<Setter>(target);return true;
}
static uint64_t callback();
static bool dispatch_owned(const Policy& p) {
    uint64_t root=0,api=0,target=0,getter=0;
    return pointer(p.c.game+0x3326308,root) && pointer(root+0x20,api) && api+0x80==slot
        && pointer(api+0x78,getter) && getter==p.c.exe+GETTER && slot_read(slot,target) && target==callback();
}
// Called under policy_lock. It invokes the pinned original, never the API slot.
static bool apply_immediately(Policy& p) {
    if(!owner(p,false) || !request_matches(p) || !p.safe || !dispatch_owned(p))return false;
    if(p.full_ads) {reset_shoulder(p);return true;}
    float radians=0;if(!source(p,radians))return false;
    radians=shoulder_lens(p,radians);
    original.load(std::memory_order_acquire)(reinterpret_cast<void*>(p.c.camera),radians);
    p.last_applied=radians;immediate_applies.fetch_add(1,std::memory_order_relaxed);return true;
}
static void setter_hook(void* camera,float native) {
    seen.fetch_add(1,std::memory_order_relaxed);
    if(!armed.load(std::memory_order_acquire) || reinterpret_cast<uint64_t>(_ReturnAddress())!=return_address.load(std::memory_order_relaxed)) {
        forwarded.fetch_add(1,std::memory_order_relaxed);original.load(std::memory_order_acquire)(camera,native);return;
    }
    AcquireSRWLockExclusive(&policy_lock);
    struct Unlock {~Unlock(){ReleaseSRWLockExclusive(&policy_lock);}} unlock;
    float applied=native;bool diagnostics_changed=false;
    if(armed.load(std::memory_order_acquire) && reinterpret_cast<uint64_t>(camera)==policy.c.camera) {
        if(!owner(policy,false)) {armed.store(0,std::memory_order_release);error(OWNER_MISMATCH);}
        else if(!dispatch_owned(policy)) {armed.store(0,std::memory_order_release);error(API_MISMATCH);}
        else if(request_matches(policy) && policy.safe) {
            policy.last_native=native;
            if(policy.full_ads) {reset_shoulder(policy);ads_forwarded.fetch_add(1,std::memory_order_relaxed);}
            else if(source(policy,applied)) {
                applied=shoulder_lens(policy,applied);replaced.fetch_add(1,std::memory_order_relaxed);
            } else reset_shoulder(policy);
            policy.last_applied=applied;
            diagnostics_changed=true;
        } else reset_shoulder(policy);
    }
    forwarded.fetch_add(1,std::memory_order_relaxed);original.load(std::memory_order_acquire)(camera,applied);
    if(diagnostics_changed)publish_diagnostics(policy);
}
static uint64_t callback() {return reinterpret_cast<uint64_t>(setter_hook);}
static bool pin(const void* address) {
    HMODULE module=nullptr;return GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_PIN,
        reinterpret_cast<LPCWSTR>(address),&module)!=0;
}
static bool restore_slot() {
    if(possible) {
        uint64_t current=0;if(!slot_read(slot,current))return false;
        if(current==callback()) {
            if(!writable_slot(slot,slot_image))return false;
            uint64_t observed=0;if(!cas(callback(),reinterpret_cast<uint64_t>(original.load()),observed))return false;
        }
        possible=false;
    }
    installed.store(0,std::memory_order_release);retired_generation=owned_generation;owned_generation=0;
    reserved.store(0,std::memory_order_release);return true;
}
static bool output_generation(uint64_t* output,uint64_t generation) {
    SIZE_T actual=0;return WriteProcessMemory(GetCurrentProcess(),output,&generation,8,&actual)!=0 && actual==8;
}
static uint32_t failed_begin(uint32_t cause,uint64_t* output) {
    armed.store(0,std::memory_order_release);
    AcquireSRWLockExclusive(&policy_lock);ReleaseSRWLockExclusive(&policy_lock);
    if(!restore_slot()) {error(CLEANUP_PENDING);return 2;}
    output_generation(output,0);return reject(cause);
}
static bool config(const NADSF_Config* input,NADSF_Config& c) {
    if(!read(reinterpret_cast<uint64_t>(input),&c,sizeof c) || c.size!=sizeof c || c.abi!=1 || c.reserved!=0
        || c.avatar_index>=8 || !c.avatar || c.avatar==0xffffffff || !c.body || c.body==0xffffffff
        || !c.weapon || c.weapon==0xffffffff || c.context<65536 || c.camera<65536 || c.request<65536)return reject(INVALID_CONFIG)!=0;
    return true;
}
NADSF_EXPORT uint32_t NADSF_Validate(const NADSF_Config* input) {
    AcquireSRWLockExclusive(&control_lock);struct Unlock {~Unlock(){ReleaseSRWLockExclusive(&control_lock);}} unlock;
    NADSF_Config c{};if(!config(input,c))return 0;if(reserved.load())return reject(BUSY);
    Policy next{};next.c=c;Setter target=nullptr;uint64_t address=0;float radians=0;
    if(!owner(next,true) || !next.safe || !request_matches(next,true))return reject(OWNER_MISMATCH);
    if(!contract(c,target,address))return 0;if(!source(next,radians))return reject(SOURCE_INVALID);
    if(!owner(next,false) || !next.safe || !request_matches(next,true))return reject(OWNER_MISMATCH);
    error(OK);return 1;
}
NADSF_EXPORT uint32_t NADSF_Begin(const NADSF_Config* input,uint64_t* output) {
    AcquireSRWLockExclusive(&control_lock);struct Unlock {~Unlock(){ReleaseSRWLockExclusive(&control_lock);}} unlock;
    if(!output_generation(output,0))return reject(INVALID_CONFIG);
    NADSF_Config c{};if(!config(input,c))return 0;if(reserved.load())return reject(BUSY);
    Policy next{};next.c=c;Setter target=nullptr;uint64_t address=0;float radians=0;
    if(!owner(next,true) || !next.safe || !request_matches(next))return reject(OWNER_MISMATCH);
    if(!contract(c,target,address))return 0;if(!source(next,radians))return reject(SOURCE_INVALID);
    if(original.load() && original.load()!=target)return reject(API_MISMATCH);
    if(!pin(reinterpret_cast<const void*>(&NADSF_Begin)))return reject(PIN_FAILED);
#if !defined(NADSF_FIXTURE)
    if(!pin(reinterpret_cast<const void*>(c.exe)))return reject(PIN_FAILED);
#endif
    original.store(target,std::memory_order_release);slot=address;slot_image=c.exe;possible=false;
    if(++generation_counter==0)++generation_counter;
    if(!output_generation(output,generation_counter))return reject(INVALID_CONFIG);
    owned_generation=generation_counter;reserved.store(1,std::memory_order_release);possible=true;
    display_cache=Display{0,0,next.source_degrees};publish_diagnostics(next);
    if(!writable_slot(slot,c.exe))return failed_begin(SLOT_NOT_WRITABLE,output);
    uint64_t observed=0;if(!cas(reinterpret_cast<uint64_t>(target),callback(),observed))return failed_begin(CAS_FAULT,output);
    if(observed!=reinterpret_cast<uint64_t>(target)) {possible=false;return failed_begin(CAS_MISMATCH,output);}
    installed.store(1,std::memory_order_release);
    if(!dispatch_owned(next))return failed_begin(CAS_MISMATCH,output);
    AcquireSRWLockExclusive(&policy_lock);
    policy=next;seen.store(0);forwarded.store(0);replaced.store(0);immediate_applies.store(0);binds.store(0);ads_forwarded.store(0);
    const bool applied=apply_immediately(policy);
    const bool stable=applied && owner(policy,false) && request_matches(policy) && policy.safe && dispatch_owned(policy);
    publish_diagnostics(policy);
    return_address.store(c.game+CALL+6,std::memory_order_relaxed);
#if defined(NADSF_FIXTURE)
    if(fixture_before_arm_reached) {SetEvent(fixture_before_arm_reached);WaitForSingleObject(fixture_continue_arm,INFINITE);}
#endif
    if(stable)armed.store(1,std::memory_order_release);
    ReleaseSRWLockExclusive(&policy_lock);
    if(!stable)return failed_begin(OWNER_MISMATCH,output);
    error(OK);return 1;
}
NADSF_EXPORT uint32_t NADSF_Bind(uint64_t generation,uint64_t request,uint32_t weapon) {
    AcquireSRWLockExclusive(&control_lock);struct UnlockControl {~UnlockControl(){ReleaseSRWLockExclusive(&control_lock);}} unlock_control;
    if(!generation || !reserved.load() || generation!=owned_generation)return reject(TOKEN_MISMATCH);
    if(request<65536 || !weapon || weapon==0xffffffff)return reject(INVALID_CONFIG);
    AcquireSRWLockExclusive(&policy_lock);struct UnlockPolicy {~UnlockPolicy(){ReleaseSRWLockExclusive(&policy_lock);}} unlock_policy;
    if(!armed.load())return reject(OWNER_MISMATCH);
    Policy next=policy;next.c.request=request;next.c.weapon=weapon;
    if(!owner(next,false) || !next.safe || !request_matches(next))return reject(OWNER_MISMATCH);
    if(!binary_contract(next.c) || !dispatch_owned(next))return reject(API_MISMATCH);
    if(!apply_immediately(next) || !owner(next,false) || !request_matches(next) || !next.safe || !dispatch_owned(next))return reject(OWNER_MISMATCH);
    policy=next;publish_diagnostics(policy);binds.fetch_add(1,std::memory_order_relaxed);error(OK);return 1;
}
NADSF_EXPORT uint32_t NADSF_End(uint64_t generation) {
    AcquireSRWLockExclusive(&control_lock);struct Unlock {~Unlock(){ReleaseSRWLockExclusive(&control_lock);}} unlock;
    if(!generation)return reject(TOKEN_MISMATCH);
    if(!reserved.load()) {if(generation!=retired_generation)return reject(TOKEN_MISMATCH);error(OK);return 1;}
    if(generation!=owned_generation)return reject(TOKEN_MISMATCH);
    armed.store(0,std::memory_order_release);AcquireSRWLockExclusive(&policy_lock);ReleaseSRWLockExclusive(&policy_lock);
    if(!restore_slot())return reject(CLEANUP_PENDING);error(OK);return 1;
}
NADSF_EXPORT uint32_t NADSF_ReadStats(uint64_t generation,NADSF_Stats* output) {
    AcquireSRWLockExclusive(&control_lock);struct UnlockControl {~UnlockControl(){ReleaseSRWLockExclusive(&control_lock);}} unlock_control;
    if(reserved.load()?(!generation || generation!=owned_generation):generation!=0)return reject(TOKEN_MISMATCH);
    NADSF_Stats s{};if(!read(reinterpret_cast<uint64_t>(output),&s,sizeof s) || s.size!=sizeof s || s.abi!=1)return reject(INVALID_CONFIG);
    read_diagnostics(s);
    s.reserved=0;s.padding=0;s.installed=installed.load();s.armed=armed.load();s.error=last_error.load();
    s.seen=seen.load();s.forwarded=forwarded.load();s.replaced=replaced.load();s.immediate_applies=immediate_applies.load();s.binds=binds.load();s.ads_forwarded=ads_forwarded.load();
    SIZE_T actual=0;return WriteProcessMemory(GetCurrentProcess(),output,&s,sizeof s,&actual)!=0 && actual==sizeof s;
}
NADSF_EXPORT uint32_t NADSF_Error(void) {return last_error.load(std::memory_order_acquire);}
