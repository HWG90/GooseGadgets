// Owned native-weapon DoF maxima only; no global effect, lens or transform writes.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <intrin.h>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <cmath>
#include "native_ads_blur.h"
using Setter=void (*)(void*,uint64_t,uint32_t,const void*);
static SRWLOCK control_lock=SRWLOCK_INIT,policy_lock=SRWLOCK_INIT;
static std::atomic<Setter> original{nullptr};
static std::atomic<uint32_t> installed{0},armed{0},reserved{0},last_error{0};
static std::atomic<uint64_t> seen{0},forwarded{0},replaced{0},immediate_applies{0};
static uint64_t slot=0,slot_image=0,generation_counter=0,owned_generation=0,retired_generation=0;
static std::atomic<uint64_t> return_address{0};
static bool possible=false;
static constexpr uint32_t SETTER=0x310050,CALL=0x100A80B;
enum Error:uint32_t { OK=0,INVALID_CONFIG=1,BUSY=2,READ_FAILED=3,IMAGE_MISMATCH=4,
    CODE_MISMATCH=5,API_MISMATCH=6,OWNER_MISMATCH=7,UNIT_MISMATCH=8,PIN_FAILED=9,
    SLOT_NOT_WRITABLE=10,CAS_MISMATCH=11,CAS_FAULT=12,CLEANUP_PENDING=13,
    SOURCE_INVALID=14,TOKEN_MISMATCH=17,NO_SOURCE=18 };
static constexpr uint32_t DOF_CLASS=0xF7A3101F,HASHES[3]{0xA7990477,0xF07FC12E,0x209F72CF};
struct Source {
    uint32_t post_index=0,entity=0,row=0,count=0;uint64_t blob=0;
    uint32_t hashes[512]{};uint64_t fields[3]{};
};
struct Policy {
    NADSB_Config c{};uint64_t controller=0,descriptor=0,registry=0,units=0,generations=0,body_object=0;
    uint8_t descriptor_bytes[20]{};bool safe=false;
    uint64_t system=0,provider=0,setter_table=0,param_pool=0,param_descriptor=0,param_row=0;
    uint8_t param_bytes[24]{};uint32_t post_indices[2]{},source_count=0;Source sources[2]{};
    uint64_t ids=0,classes=0,chains=0,blobs=0;
    uint32_t last_hash=0,last_instance=0;float last_native=0,last_applied=0;
};
static Policy policy;
#if defined(NADSB_FIXTURE)
static Setter fixture_target=nullptr;
static uint32_t fixture_cas_calls=0,fixture_cas_fail_at=0,fixture_foreign_cas_at=0;
static uint64_t fixture_foreign_value=0;
static bool fixture_slot_unreadable=false,fixture_slot_readonly=false;
static HANDLE fixture_before_arm_reached=nullptr,fixture_continue_arm=nullptr;
#endif
static bool read(uint64_t at,void* out,size_t length) {
    if(at<65536 || at>=0x800000000000ULL || length>4096 || at+length>=0x800000000000ULL)return false;
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
    // The per-weapon blur filter serves both hip and ADS. Inhibited actions,
    // seated state and the unknown controller guard retain native effects.
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
static bool provider(const NADSB_Config&,uint64_t&,uint64_t&,uint64_t&);
// The weapon parameter map uses the same bounded open-addressed lookup as the
// verified native ADS constructor. No engine query or property getter is called.
static int weapon_parameters(Policy& p,bool capture,uint32_t* indices) {
    uint64_t pool=0,buckets=0,descriptors=0,rows=0,d=0;uint32_t cap=0,empty=0,mult=0,index=0;
    if(!pointer(p.c.game+0x3326A38,pool) || !pointer(pool+0x278,buckets)
        || !value(pool+0x280,cap) || !value(pool+0x284,empty) || !value(pool+0x288,mult)
        || !cap || cap>1048576 || (cap&(cap-1)) || empty==p.c.weapon
        || !pointer(pool+0x290,descriptors) || !pointer(pool+0x298,rows))return -1;
    bool found=false;const uint32_t first=p.c.weapon*mult;
    for(uint32_t n=0;n<cap && n<4096;++n) {
        uint32_t r[2]{};if(!read(buckets+static_cast<uint64_t>((first+n)&(cap-1))*8,r,8))return -1;
        if(r[0]==empty)return 0;if(r[0]==p.c.weapon) {index=r[1];found=true;break;}
    }
    if(!found || index>=65536)return -1;
    uint8_t bytes24[24]{};uint32_t entity=0;
    if(!pointer(descriptors+static_cast<uint64_t>(index)*8,d) || !read(d,bytes24,24))return -1;
    std::memcpy(&entity,bytes24+8,4);if(entity!=p.c.weapon)return -1;
    if((bytes24[20]&1)==0)return 0;
    const uint64_t row=rows+static_cast<uint64_t>(index)*8;
    if(!read(row,indices,8))return -1;
    if(capture) {p.param_pool=pool;p.param_descriptor=d;p.param_row=row;std::memcpy(p.param_bytes,bytes24,24);}
    else if(pool!=p.param_pool || d!=p.param_descriptor || row!=p.param_row || std::memcmp(bytes24,p.param_bytes,24)!=0)return -1;
    return 1;
}
// Exact EXE62ADB0 semantics: +AC is the bucket modulus, while +94 is
// storage capacity (overflow next indices may legitimately exceed +AC).
static int component(const Policy& p,uint32_t entity,uint32_t& row) {
    uint64_t buckets=0;uint32_t count=0,capacity=0,active=0,divisor=0,rows=0,allocated=0;
    if(!pointer(p.provider+0x98,buckets) || !value(p.provider+0x90,count) || !value(p.provider+0x94,capacity)
        || !value(p.provider+0xA8,active) || !value(p.provider+0xAC,divisor)
        || !value(p.provider+0xB8,rows) || !value(p.provider+0xBC,allocated)
        || !capacity || capacity>4096 || count>capacity || active>count || !divisor || divisor>capacity
        || !rows || rows>allocated || allocated>4096)return -1;
    uint32_t at=entity%divisor,index=0;bool found=false;
    for(uint32_t n=0;n<capacity;++n) {
        uint32_t b[3]{};if(at>=count || !read(buckets+static_cast<uint64_t>(at)*12,b,12))return -1;
        if(b[2]==0xFFFFFFFE)return 0;
        if(b[0]==entity) {index=b[1];found=true;break;}
        if(b[2]==0x7FFFFFFF)return 0;at=b[2];
    }
    if(!found)return -1;
    for(uint32_t n=0;n<rows;++n) {
        if(index==0)return 0;if(index>=rows)return -1;
        uint32_t id=0,kind=0,next=0;
        if(!value(p.ids+static_cast<uint64_t>(index)*4,id) || id!=entity
            || !value(p.classes+static_cast<uint64_t>(index)*4,kind))return -1;
        if(kind==DOF_CLASS) {row=index;return 1;}
        if(!value(p.chains+static_cast<uint64_t>(index)*4,next))return -1;index=next;
    }return -1;
}
static bool fields(Source& s,bool capture) {
    uint32_t count=0,keys[512]{};
    if(!value(s.blob+4,count) || !count || count>512 || !read(s.blob+0x10,keys,count*4))return false;
    if(!capture && (count!=s.count || std::memcmp(keys,s.hashes,count*4)!=0))return false;
    uint64_t offsets[3]{};
    for(uint32_t i=0;i<count;++i)for(unsigned k=0;k<3;++k)if(keys[i]==HASHES[k]) {
        uint32_t type=0;if(offsets[k])return false;
        offsets[k]=s.blob+0x10+static_cast<uint64_t>(count)*4+static_cast<uint64_t>(i)*16;
        if(!value(offsets[k],type) || type!=2)return false;
    }
    for(unsigned k=0;k<3;++k)if(!offsets[k] || (!capture && offsets[k]!=s.fields[k]))return false;
    if(capture) {s.count=count;std::memcpy(s.hashes,keys,count*4);std::memcpy(s.fields,offsets,sizeof offsets);}
    return true;
}
static bool source(Policy& p,bool capture) {
    uint64_t system=0,object=0,table=0,ids=0,classes=0,chains=0,blobs=0;
    if(!provider(p.c,system,object,table) || !pointer(object+0xC8,ids) || !pointer(object+0xD0,classes)
        || !pointer(object+0xD8,chains) || !pointer(object+0xE8,blobs))return reject(capture?SOURCE_INVALID:UNIT_MISMATCH)!=0;
    if(capture) {p.system=system;p.provider=object;p.setter_table=table;p.ids=ids;p.classes=classes;p.chains=chains;p.blobs=blobs;}
    else if(system!=p.system || object!=p.provider || table!=p.setter_table || ids!=p.ids
        || classes!=p.classes || chains!=p.chains || blobs!=p.blobs)return reject(capture?SOURCE_INVALID:UNIT_MISMATCH)!=0;
    uint32_t indices[2]{};const int params=weapon_parameters(p,capture,indices);
    if(params<=0)return reject(capture?(params==0?NO_SOURCE:SOURCE_INVALID):UNIT_MISMATCH)!=0;
    if(!capture && std::memcmp(indices,p.post_indices,8)!=0)return reject(capture?SOURCE_INVALID:UNIT_MISMATCH)!=0;
    Source current[2]{};uint32_t found=0;
    for(unsigned i=0;i<2;++i) {
        if(indices[i]>=4096)continue;uint32_t entity=0,row=0;
        if(!value(system+0x348+static_cast<uint64_t>(indices[i])*0x30,entity) || !entity || entity==UINT32_MAX)return reject(capture?SOURCE_INVALID:UNIT_MISMATCH)!=0;
        const int member=component(p,entity,row);if(member<0)return reject(capture?SOURCE_INVALID:UNIT_MISMATCH)!=0;if(member==0)continue;
        Source s{};s.post_index=indices[i];s.entity=entity;s.row=row;
        if(!pointer(blobs+static_cast<uint64_t>(row)*8,s.blob))return reject(capture?SOURCE_INVALID:UNIT_MISMATCH)!=0;
        if(capture) {if(!fields(s,true))return reject(capture?SOURCE_INVALID:UNIT_MISMATCH)!=0;}
        else {
            if(found>=p.source_count || s.post_index!=p.sources[found].post_index || s.entity!=p.sources[found].entity
                || s.row!=p.sources[found].row || s.blob!=p.sources[found].blob)return reject(capture?SOURCE_INVALID:UNIT_MISMATCH)!=0;
            s=p.sources[found];if(!fields(s,false))return reject(capture?SOURCE_INVALID:UNIT_MISMATCH)!=0;
        }
        if(found && s.entity==current[0].entity)return reject(capture?SOURCE_INVALID:UNIT_MISMATCH)!=0;current[found++]=s;
    }
    if(!found)return reject(capture?NO_SOURCE:UNIT_MISMATCH)!=0;
    if(capture) {p.source_count=found;std::memcpy(p.post_indices,indices,8);std::memcpy(p.sources,current,sizeof current);}
    else if(found!=p.source_count)return reject(capture?SOURCE_INVALID:UNIT_MISMATCH)!=0;
    return true;
}
static bool writable_slot(uint64_t at,uint64_t exe) {
    if((at&7)!=0)return false;
#if defined(NADSB_FIXTURE)
    if(fixture_slot_readonly)return false;
    (void)exe;
#endif
    MEMORY_BASIC_INFORMATION r{};
    if(VirtualQuery(reinterpret_cast<const void*>(at),&r,sizeof r)!=sizeof r || r.State!=MEM_COMMIT || r.Protect!=PAGE_READWRITE
        || at+8>reinterpret_cast<uint64_t>(r.BaseAddress)+r.RegionSize)return false;
#if !defined(NADSB_FIXTURE)
    return r.Type==MEM_IMAGE && reinterpret_cast<uint64_t>(r.AllocationBase)==exe;
#else
    return r.Type==MEM_PRIVATE;
#endif
}
static bool slot_read(uint64_t at,uint64_t& out) {
#if defined(NADSB_FIXTURE)
    if(fixture_slot_unreadable)return false;
#endif
    return value(at,out);
}
static bool cas(uint64_t expected,uint64_t desired,uint64_t& observed) {
#if defined(NADSB_FIXTURE)
    if(++fixture_cas_calls==fixture_cas_fail_at)return false;
    if(fixture_cas_calls==fixture_foreign_cas_at)InterlockedExchangePointer(reinterpret_cast<PVOID volatile*>(slot),reinterpret_cast<void*>(fixture_foreign_value));
#endif
    __try {
        observed=reinterpret_cast<uint64_t>(InterlockedCompareExchangePointer(reinterpret_cast<PVOID volatile*>(slot),
            reinterpret_cast<void*>(desired),reinterpret_cast<void*>(expected)));return true;
    } __except(EXCEPTION_EXECUTE_HANDLER) {return false;}
}
static bool binary_contract(const NADSB_Config& c) {
    if(!image(c.game,0x6AB3B43F,0x4744000) || !image(c.exe,0x6AB382E4,0x39E8000))return reject(IMAGE_MISMATCH)!=0;
    if(!bytes(c.game+CALL,"41ff13")
        || !bytes(c.exe+SETTER,"48895c24084889742410574883ec404c8b11498bd94c8bca418bf8448bc249c1e920488d542460488bf141ff5238")
        || !bytes(c.exe+0x30FFC0,"418bc048c1e0208bca480bc1c3")
        || !bytes(c.exe+0x62ADB0,"405383b9a8000000004c8bda48897c2418488bd9c744241000000000")
        || !bytes(c.exe+0x310140,"e97b9f3100")
        || !bytes(c.exe+0x62A0C0,"48895c2408574883ec200fb60133ff488bd984c0743e3c2e752f8bd34533c02bd1e85ab7faff48c1e82069c895e9d15b"))return reject(CODE_MISMATCH)!=0;
    return true;
}
static bool provider(const NADSB_Config& c,uint64_t& system,uint64_t& object,uint64_t& table) {
    uint64_t root=0,vt=0,lookup=0,apply=0,query=0,pack=0,getter=0,apis=0,hash_api=0,hash=0;
    return pointer(c.game+0x3326468,root) && pointer(root+0x18,system)
        && pointer(system+0xDC8,object) && pointer(object,vt) && vt==c.exe+0x1677DC8
        && pointer(vt+0x38,lookup) && lookup==c.exe+0x62ADB0
        && pointer(vt+0x28,apply) && apply==c.exe+0x2DD5E0
        && pointer(system+0xDD8,query) && query==c.exe+0x27CC5E0
        && pointer(query+0x28,pack) && pack==c.exe+0x30FFC0
        && pointer(system+0xDE8,table) && table==c.exe+0x27CC638
        && pointer(table+8,getter) && getter==c.exe+0x3100C0
        && pointer(c.game+0x3326308,apis) && pointer(apis+0xC0,hash_api)
        && pointer(hash_api+0x28,hash) && hash==c.exe+0x310140;
}
static bool contract(const NADSB_Config& c,Setter& setter,uint64_t& address) {
    if(!binary_contract(c))return false;
    uint64_t system=0,object=0,table=0,target=0;
    if(!provider(c,system,object,table) || !slot_read(table,target))return reject(API_MISMATCH)!=0;
    address=table;if(!writable_slot(address,c.exe))return reject(SLOT_NOT_WRITABLE)!=0;
#if defined(NADSB_FIXTURE)
    if(target!=reinterpret_cast<uint64_t>(fixture_target))return reject(API_MISMATCH)!=0;
#else
    if(target!=c.exe+SETTER || !executable(c.exe+0x30FFC0) || !executable(c.exe+0x62ADB0)
        || !executable(c.exe+0x2DD5E0))return reject(API_MISMATCH)!=0;
#endif
    if(!executable(target))return reject(API_MISMATCH)!=0;
    setter=reinterpret_cast<Setter>(target);return true;
}
static uint64_t callback();
static bool dispatch_owned(const Policy& p) {
    uint64_t system=0,object=0,table=0,target=0;
    return provider(p.c,system,object,table) && system==p.system && object==p.provider && table==p.setter_table
        && table==slot && slot_read(slot,target) && target==callback();
}
static bool selected_hash(uint32_t hash) {return hash==HASHES[0] || hash==HASHES[1] || hash==HASHES[2];}
static bool selected_source(const Policy& p,uint64_t packed) {
    if(static_cast<uint32_t>(packed>>32)!=DOF_CLASS)return false;
    for(unsigned i=0;i<p.source_count;++i)if(static_cast<uint32_t>(packed)==p.sources[i].entity)return true;
    return false;
}
// Under policy_lock; the pinned original is the only mutating engine call.
static bool apply_immediately(Policy& p) {
    if(!owner(p,false) || !request_matches(p) || !p.safe || !source(p,false) || !dispatch_owned(p))return false;
    for(unsigned i=0;i<p.source_count;++i)for(unsigned k=0;k<3;++k) {
        if(!owner(p,false) || !request_matches(p) || !p.safe || !source(p,false) || !dispatch_owned(p))return false;
        alignas(16) uint8_t variant[24]{};const uint32_t type=2;std::memcpy(variant,&type,4);
        const uint64_t packed=static_cast<uint64_t>(DOF_CLASS)<<32|p.sources[i].entity;
        original.load(std::memory_order_acquire)(reinterpret_cast<void*>(p.provider),packed,HASHES[k],variant);
        p.last_hash=HASHES[k];p.last_instance=DOF_CLASS;p.last_applied=0;immediate_applies.fetch_add(1,std::memory_order_relaxed);
    }
    return true;
}
static void setter_hook(void* object,uint64_t instance,uint32_t hash,const void* native) {
    seen.fetch_add(1,std::memory_order_relaxed);
    if(!armed.load(std::memory_order_acquire) || reinterpret_cast<uint64_t>(_ReturnAddress())!=return_address.load(std::memory_order_relaxed)) {
        forwarded.fetch_add(1,std::memory_order_relaxed);original.load(std::memory_order_acquire)(object,instance,hash,native);return;
    }
    AcquireSRWLockExclusive(&policy_lock);struct Unlock {~Unlock(){ReleaseSRWLockExclusive(&policy_lock);}} unlock;
    const void* output=native;alignas(16) uint8_t adjusted[24]{};
    if(armed.load(std::memory_order_acquire) && reinterpret_cast<uint64_t>(object)==policy.provider && selected_hash(hash)
        && selected_source(policy,instance)) {
        if(!owner(policy,false)) {armed.store(0,std::memory_order_release);error(OWNER_MISMATCH);}
        else if(!dispatch_owned(policy)) {armed.store(0,std::memory_order_release);error(API_MISMATCH);}
        else if(!request_matches(policy)) {armed.store(0,std::memory_order_release);error(OWNER_MISMATCH);}
        else if(policy.safe) {
            if(!source(policy,false)) {armed.store(0,std::memory_order_release);}
            else {
            uint32_t tag=0;float scalar=0;
            if(read(reinterpret_cast<uint64_t>(native),adjusted,24)) {
                std::memcpy(&tag,adjusted,4);std::memcpy(&scalar,adjusted+8,4);
                if(tag==2 && std::isfinite(scalar)) {
                    const float zero=0;std::memcpy(adjusted+8,&zero,4);output=adjusted;
                    policy.last_hash=hash;policy.last_instance=static_cast<uint32_t>(instance>>32);
                    policy.last_native=scalar;policy.last_applied=0;replaced.fetch_add(1,std::memory_order_relaxed);
                }
            }
            }
        }
    }
    forwarded.fetch_add(1,std::memory_order_relaxed);original.load(std::memory_order_acquire)(object,instance,hash,output);
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
static bool config(const NADSB_Config* input,NADSB_Config& c) {
    if(!read(reinterpret_cast<uint64_t>(input),&c,sizeof c) || c.size!=sizeof c || c.abi!=1 || c.reserved!=0
        || c.avatar_index>=8 || !c.avatar || c.avatar==0xffffffff || !c.body || c.body==0xffffffff
        || !c.weapon || c.weapon==0xffffffff || c.context<65536 || c.camera<65536 || c.request<65536)return reject(INVALID_CONFIG)!=0;
    return true;
}
NADSB_EXPORT uint32_t NADSB_Validate(const NADSB_Config* input) {
    AcquireSRWLockExclusive(&control_lock);struct Unlock {~Unlock(){ReleaseSRWLockExclusive(&control_lock);}} unlock;
    NADSB_Config c{};if(!config(input,c))return 0;if(reserved.load())return reject(BUSY);
    Policy next{};next.c=c;Setter target=nullptr;uint64_t address=0;
    if(!owner(next,true) || !next.safe || !request_matches(next,true))return reject(OWNER_MISMATCH);
    if(!contract(c,target,address))return 0;if(!source(next,true))return 0;
    if(!owner(next,false) || !next.safe || !request_matches(next,true))return reject(OWNER_MISMATCH);
    if(!source(next,false))return 0;
    error(OK);return 1;
}
NADSB_EXPORT uint32_t NADSB_Begin(const NADSB_Config* input,uint64_t* output) {
    AcquireSRWLockExclusive(&control_lock);struct Unlock {~Unlock(){ReleaseSRWLockExclusive(&control_lock);}} unlock;
    if(!output_generation(output,0))return reject(INVALID_CONFIG);
    NADSB_Config c{};if(!config(input,c))return 0;if(reserved.load())return reject(BUSY);
    Policy next{};next.c=c;Setter target=nullptr;uint64_t address=0;
    if(!owner(next,true) || !next.safe || !request_matches(next))return reject(OWNER_MISMATCH);
    if(!contract(c,target,address))return 0;if(!source(next,true))return 0;
    if(original.load() && original.load()!=target)return reject(API_MISMATCH);
    if(!pin(reinterpret_cast<const void*>(&NADSB_Begin)))return reject(PIN_FAILED);
#if !defined(NADSB_FIXTURE)
    if(!pin(reinterpret_cast<const void*>(c.exe)))return reject(PIN_FAILED);
#endif
    original.store(target,std::memory_order_release);slot=address;slot_image=c.exe;possible=false;
    if(++generation_counter==0)++generation_counter;
    if(!output_generation(output,generation_counter))return reject(INVALID_CONFIG);
    owned_generation=generation_counter;reserved.store(1,std::memory_order_release);possible=true;
    if(!writable_slot(slot,c.exe))return failed_begin(SLOT_NOT_WRITABLE,output);
    uint64_t observed=0;if(!cas(reinterpret_cast<uint64_t>(target),callback(),observed))return failed_begin(CAS_FAULT,output);
    if(observed!=reinterpret_cast<uint64_t>(target)) {possible=false;return failed_begin(CAS_MISMATCH,output);}
    installed.store(1,std::memory_order_release);
    if(!dispatch_owned(next))return failed_begin(CAS_MISMATCH,output);
    AcquireSRWLockExclusive(&policy_lock);
    policy=next;seen.store(0);forwarded.store(0);replaced.store(0);immediate_applies.store(0);
    const bool applied=apply_immediately(policy);
    const bool stable=applied && owner(policy,false) && request_matches(policy) && policy.safe && source(policy,false) && dispatch_owned(policy);
    return_address.store(c.game+CALL+3,std::memory_order_relaxed);
#if defined(NADSB_FIXTURE)
    if(fixture_before_arm_reached) {SetEvent(fixture_before_arm_reached);WaitForSingleObject(fixture_continue_arm,INFINITE);}
#endif
    if(stable)armed.store(1,std::memory_order_release);
    ReleaseSRWLockExclusive(&policy_lock);
    if(!stable)return failed_begin(OWNER_MISMATCH,output);
    error(OK);return 1;
}
NADSB_EXPORT uint32_t NADSB_End(uint64_t generation) {
    AcquireSRWLockExclusive(&control_lock);struct Unlock {~Unlock(){ReleaseSRWLockExclusive(&control_lock);}} unlock;
    if(!generation)return reject(TOKEN_MISMATCH);
    if(!reserved.load()) {if(generation!=retired_generation)return reject(TOKEN_MISMATCH);error(OK);return 1;}
    if(generation!=owned_generation)return reject(TOKEN_MISMATCH);
    armed.store(0,std::memory_order_release);AcquireSRWLockExclusive(&policy_lock);ReleaseSRWLockExclusive(&policy_lock);
    if(!restore_slot())return reject(CLEANUP_PENDING);error(OK);return 1;
}
NADSB_EXPORT uint32_t NADSB_ReadStats(uint64_t generation,NADSB_Stats* output) {
    AcquireSRWLockExclusive(&control_lock);struct UnlockControl {~UnlockControl(){ReleaseSRWLockExclusive(&control_lock);}} unlock_control;
    if(reserved.load()?(!generation || generation!=owned_generation):generation!=0)return reject(TOKEN_MISMATCH);
    NADSB_Stats s{};if(!read(reinterpret_cast<uint64_t>(output),&s,sizeof s) || s.size!=sizeof s || s.abi!=1)return reject(INVALID_CONFIG);
    AcquireSRWLockExclusive(&policy_lock);s.last_native=policy.last_native;s.last_applied=policy.last_applied;
    s.last_hash=policy.last_hash;s.last_instance=policy.last_instance;ReleaseSRWLockExclusive(&policy_lock);
    s.reserved=0;s.reserved_tail=0;s.installed=installed.load();s.armed=armed.load();s.error=last_error.load();
    s.seen=seen.load();s.forwarded=forwarded.load();s.replaced=replaced.load();s.immediate_applies=immediate_applies.load();
    SIZE_T actual=0;return WriteProcessMemory(GetCurrentProcess(),output,&s,sizeof s,&actual)!=0 && actual==sizeof s;
}
NADSB_EXPORT uint32_t NADSB_Error(void) {return last_error.load(std::memory_order_acquire);}
