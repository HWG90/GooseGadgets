#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <cstring>
#include <bcrypt.h>
#include "game_binding.h"
#include "queue_profile.h"

namespace hob {
bool guarded_read(uint64_t at, void* out, size_t n) noexcept {
    if (at < 65536 || n == 0 || n > 4096 || at > 0x7fffffffffffULL - n) return false;
    SIZE_T done = 0;
    return ReadProcessMemory(GetCurrentProcess(), reinterpret_cast<const void*>(at),out,n,&done)
        && done == n;
}
template<class T> static bool get(uint64_t at, T& out) noexcept {
    return guarded_read(at,&out,sizeof out);
}
static bool pointer(uint64_t at, uint64_t& out) noexcept {
    return get(at,out) && out >= 65536 && out < 0x800000000000ULL;
}
static bool entity(uint32_t id) noexcept { return id && id < 0xfffffffeU; }
struct Map { uint64_t buckets; uint32_t capacity, empty, multiplier; };
static bool lookup(uint64_t at, uint32_t id, uint32_t& index) noexcept {
    Map h{};
    // sizeof(Map) includes padding; read only its 20 defined bytes.
    if (!guarded_read(at,&h,20) || h.buckets < 65536 || !h.capacity
        || h.capacity > 1048576 || (h.capacity & (h.capacity-1)) || id == h.empty) return false;
    const uint32_t hash = id * h.multiplier;
    for (uint32_t p=0;p<h.capacity && p<4096;++p) {
        uint32_t bucket[2]{};
        if (!guarded_read(h.buckets+static_cast<uint64_t>((hash+p)&(h.capacity-1))*8,
            bucket,sizeof bucket) || bucket[0] == h.empty) return false;
        if (bucket[0] == id) { index=bucket[1]; return index<1048576; }
    }
    return false;
}
struct Descriptor { uint64_t type; uint32_t entity,body,light,flags; };
static bool roots(uint64_t game, uint64_t& world, uint64_t& impl) noexcept {
    return pointer(game+0x346BF98,world) && pointer(game+0x346BFC8,impl)
        && impl == world+0x40;
}
bool local_snapshot(uint64_t game, Snapshot& s) noexcept {
    Snapshot result{};
    uint64_t player=0,descs=0,descriptor=0,rows=0;
    uint32_t light=0,count=0,local=0;
    Descriptor d{},wd{};
    if (!roots(game,result.world,result.implementation)
        || !pointer(game+0x3326468,player) || !get(player+0x88,count) || !count
        || !get(player+0x3A8,light) || !entity(light)
        || !lookup(result.world+0xF22EC8,light,local)
        || !get(result.world+0xF32F18+static_cast<uint64_t>(local)*24,d)
        || d.light!=light || (d.flags&3)!=1 || !entity(d.entity) || !entity(d.body)
        || !pointer(game+0x3326420,result.manager)
        || result.manager!=result.implementation+0xE9FB10
        || !get(result.manager+0x1C,count) || !count || count>4096
        || !lookup(result.manager+0x30,d.entity,result.index) || result.index>=count
        || !pointer(result.manager+0x48,descs)
        || !pointer(descs+static_cast<uint64_t>(result.index)*8,descriptor)
        || !get(descriptor,wd) || std::memcmp(&wd,&d,sizeof d)
        || !pointer(result.manager+0x60,rows)
        || !get(rows+static_cast<uint64_t>(result.index)*0x1D0,result.weapon)) return false;
    uint64_t closing_world=0,closing_impl=0;
    if (!roots(game,closing_world,closing_impl) || closing_world!=result.world
        || closing_impl!=result.implementation) return false;
    result.avatar=d.entity; result.body=d.body;
    pointer(game+0x346D560,result.camera);
    if (!entity(result.weapon)) result.weapon=0;
    s=result;
    return true;
}
bool camera_matches(uint64_t game, uint64_t camera, uint32_t avatar, uint32_t weapon) noexcept {
    uint64_t current=0;
    uint32_t queue[2]{},request[4]{};
    if (!pointer(game+0x346D560,current) || current!=camera
        || !guarded_read(camera+0x1F8,queue,sizeof queue) || queue[0]>=32 || queue[1]>=32) return false;
    const uint64_t record=queue[0]==queue[1]?camera+0x1F00:
        camera+0x200+static_cast<uint64_t>((queue[1]+31)%32)*0xE8;
    return guarded_read(record,request,sizeof request) && (request[0]&0xffff)==6
        && request[1]==avatar && request[2]==weapon;
}
bool unwield_matches(uint64_t game, uint64_t manager, uint32_t index,
    uint32_t avatar, uint32_t weapon) noexcept {
    uint64_t current=0,rows=0,descs=0,descriptor=0;
    uint32_t count=0,held=0;
    Descriptor d{};
    return pointer(game+0x3326420,current) && current==manager
        && get(manager+0x1C,count) && count<=4096 && index<count
        && pointer(manager+0x48,descs) && pointer(descs+static_cast<uint64_t>(index)*8,descriptor)
        && get(descriptor,d) && d.entity==avatar && (d.flags&3)==1
        && pointer(manager+0x60,rows) && get(rows+static_cast<uint64_t>(index)*0x1D0,held)
        && held==weapon;
}
bool retirement_matches(uint64_t descriptor, uint32_t avatar) noexcept {
    Descriptor d{};
    return get(descriptor,d) && d.entity==avatar;
}
bool camera_request(uint64_t camera,uint32_t field,uint32_t value,CameraRequest& result) noexcept {
    uint32_t queue[2]{};
    if ((field && field!=0x1f8 && field!=0x1fc)
        || !guarded_read(camera+0x1f8,queue,sizeof queue)) return false;
    if (field)queue[field==0x1f8?0:1]=value;
    if (queue[0]>=32 || queue[1]>=32) return false;
    const uint64_t address=queue[0]==queue[1]?camera+0x1f00:
        camera+0x200+static_cast<uint64_t>((queue[1]+31)%32)*0xe8;
    CameraRequest request{};
    if (!get(address,request)) return false;
    result=request;
    return true;
}
bool admit_commit_sites(uint64_t game,std::vector<CommitSite>& sites) noexcept {
    BCRYPT_ALG_HANDLE algorithm=nullptr;
    if (!sites.empty() || BCryptOpenAlgorithmProvider(&algorithm,BCRYPT_SHA256_ALGORITHM,nullptr,0)<0) return false;
    bool valid=true;
    try {
        for(const auto& span:queue_span_guards) {
            std::vector<unsigned char> code(span.length);
            for(uint32_t offset=0;offset<span.length;) {
                const uint32_t count=span.length-offset>4096?4096:span.length-offset;
                if(!guarded_read(game+span.rva+offset,code.data()+offset,count)) {valid=false;break;}
                offset+=count;
            }
            unsigned char digest[32]{};
            if(!valid || BCryptHash(algorithm,nullptr,0,code.data(),span.length,digest,sizeof digest)<0
                || std::memcmp(digest,span.sha256,sizeof digest)) {valid=false;break;}
        }
        if(valid)for(const auto& site:queue_site_guards) {
            DWORD64 image_base=0;
            auto* entry=RtlLookupFunctionEntry(game+site.rva,&image_base,nullptr);
            if(!entry || image_base!=game || std::memcmp(entry,&site.parent,sizeof site.parent)) {valid=false;break;}
            sites.push_back({game+site.rva,site.length,site.field,site.base,site.source,site.parent});
        }
    } catch (...) {valid=false;}
    BCryptCloseAlgorithmProvider(algorithm,0);
    if(!valid)sites.clear();
    return valid && sites.size()==18;
}
static bool prefix(uint64_t at, const unsigned char* expected, size_t n) noexcept {
    unsigned char bytes[32]{};
    return n<=sizeof bytes && guarded_read(at,bytes,n) && !std::memcmp(bytes,expected,n);
}
bool admit_game(uint64_t& game, uint64_t targets[4], uint64_t& retire_slot,
    uint64_t& shutdown_slot) noexcept {
    game=reinterpret_cast<uint64_t>(GetModuleHandleA("game.dll"));
    return inspect_module_profile(game,targets,retire_slot,shutdown_slot);
}
bool inspect_module_profile(uint64_t game,uint64_t targets[4],uint64_t& retire_slot,
    uint64_t& shutdown_slot) noexcept {
    IMAGE_DOS_HEADER dos{}; IMAGE_NT_HEADERS64 nt{};
    if (!get(game,dos) || dos.e_magic!=IMAGE_DOS_SIGNATURE || dos.e_lfanew<64 || dos.e_lfanew>4096
        || !get(game+dos.e_lfanew,nt) || nt.Signature!=IMAGE_NT_SIGNATURE
        || nt.FileHeader.Machine!=IMAGE_FILE_MACHINE_AMD64
        || nt.FileHeader.TimeDateStamp!=0x6AB3B43F || nt.OptionalHeader.SizeOfImage!=0x4744000) return false;
    const uint32_t rvas[4]={0x127DE20,0x127E9D0,0x785DE0,0x7853D0};
    const unsigned char expected[4][16]={
        {0x40,0x55,0x53,0x56,0x57,0x48,0x8d,0xac,0x24,0x78,0xff,0xff,0xff,0x48,0x81,0xec},
        {0x40,0x55,0x41,0x54,0x41,0x56,0x48,0x8d,0xac,0x24,0xd0,0xfe,0xff,0xff,0x48,0x81},
        {0x40,0x53,0x55,0x57,0x41,0x54,0x48,0x83,0xec,0x78,0x48,0x8b,0x05,0x1f,0x62,0xeb},
        {0x40,0x53,0x41,0x56,0x48,0x81,0xec,0x98,0,0,0,0x48,0x8b,0x05,0x2e,0x6c}};
    for (unsigned i=0;i<4;++i) {
        targets[i]=game+rvas[i];
        if (!prefix(targets[i],expected[i],sizeof expected[i])) return false;
    }
    const unsigned char create_code[16]={0x48,0x89,0x5c,0x24,0x10,0x48,0x89,0x7c,0x24,0x18,0x41,0x56,0x48,0x83,0xec,0x20};
    const unsigned char retire_code[8]={0x48,0x8b,0xd1,0xe9,0x48,0xd9,0x23,0};
    const unsigned char shutdown_code[16]={0x48,0x89,0x5c,0x24,0x18,0x55,0x48,0x83,0xec,0x50,0x48,0x89,0x74,0x24,0x60,0xe8};
    if(!prefix(game+0x53FF20,create_code,sizeof create_code)
        || !prefix(game+0x540070,retire_code,sizeof retire_code)
        || !prefix(game+0x4EE7F0,shutdown_code,sizeof shutdown_code))return false;
    uint64_t world=0,impl=0,retire=0,shutdown=0,create=0;
    if (!roots(game,world,impl)) return false;
    retire_slot=impl+0xF0E6C8;
    shutdown_slot=game+0x37CEBB0;
    return get(impl+0xF0DCA8,create) && create==game+0x53FF20
        && get(retire_slot,retire) && retire==game+0x540070
        && get(shutdown_slot,shutdown) && shutdown==game+0x4EE7F0;
}
}
