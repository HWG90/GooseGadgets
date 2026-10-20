#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include "hob_consumer.h"
#include "game_binding.h"
#include <cmath>
#include <cstring>

namespace hob {
namespace {
constexpr uint32_t target=0x3C0EFA35;
template<class T> bool read(uint64_t at,T& value) noexcept {return guarded_read(at,&value,sizeof value);}
bool pointer(uint64_t at,uint64_t& value) noexcept {return read(at,value) && value>=65536 && value<0x800000000000ULL;}
enum class Lookup {found,absent,error};
Lookup map(uint64_t at,uint32_t key,uint32_t& value) noexcept {
    struct Header {uint64_t buckets;uint32_t capacity,empty,multiplier;};
    Header h{};
    if(!guarded_read(at,&h,20) || h.buckets<65536 || !h.capacity || h.capacity>1048576
        || (h.capacity&(h.capacity-1)))return Lookup::error;
    if(key==h.empty)return Lookup::absent;
    const uint32_t hash=key*h.multiplier;
    for(uint32_t i=0;i<h.capacity && i<4096;++i) {
        uint32_t row[2]{};
        if(!guarded_read(h.buckets+static_cast<uint64_t>((hash+i)&(h.capacity-1))*8,row,sizeof row))return Lookup::error;
        if(row[0]==h.empty)return Lookup::absent;
        if(row[0]==key) {value=row[1];return Lookup::found;}
    }
    return Lookup::error;
}
float scalar(uint32_t bits) noexcept {float value=0;std::memcpy(&value,&bits,4);return value;}
bool native_cap(uint32_t angle,uint32_t& bits) noexcept {
    const float degrees=scalar(angle);
    if(angle>>31 || !std::isfinite(degrees) || degrees>180.0f)return false;
    const float radians=degrees*scalar(0x3C8EFA35);
    std::memcpy(&bits,&radians,4);return true;
}
bool writable(uint64_t address,uint64_t game) noexcept {
    if((address&3) || (address>=game && address<game+0x4744000))return false;
    MEMORY_BASIC_INFORMATION region{};
    return VirtualQuery(reinterpret_cast<void*>(address),&region,sizeof region)==sizeof region
        && region.State==MEM_COMMIT && region.Type==MEM_PRIVATE && region.Protect==PAGE_READWRITE
        && address+4<=reinterpret_cast<uint64_t>(region.BaseAddress)+region.RegionSize;
}
bool compare_exchange(uint64_t address,uint32_t expected,uint32_t desired,uint32_t& observed) noexcept {
    __try {
        observed=static_cast<uint32_t>(InterlockedCompareExchange(reinterpret_cast<volatile LONG*>(address),
            static_cast<LONG>(desired),static_cast<LONG>(expected)));
        return true;
    } __except(EXCEPTION_EXECUTE_HANDLER) {return false;}
}
}
bool HoBConsumer::receive(void* context,const Notice& notice) noexcept {
    return context && static_cast<HoBConsumer*>(context)->notify(notice);
}
bool HoBConsumer::quarantined(const Record& record) const noexcept {
    if(quarantine_full_)return true;
    for(uint32_t i=0;i<foreign_count_;++i)if(foreign_[i].world==record.world
        && !std::memcmp(&foreign_[i].descriptor,&record.descriptor,16))return true;
    return false;
}
void HoBConsumer::quarantine(const Record& record) noexcept {
    if(quarantined(record))return;
    ++stats_.foreign_edits;
    if(foreign_count_==foreign_.size()) {quarantine_full_=true;return;}
    foreign_[foreign_count_++]={record.world,record.descriptor};
}
HoBConsumer::Result HoBConsumer::resolve(uint64_t world,uint32_t entity,Record& result) const noexcept {
    Record r{};r.world=world;
    uint64_t current=0,descriptors=0,descriptor=0,rows=0;
    uint32_t index=0,count=0,capacity=0;
    if(!read(game_+0x346BF98,current))return Result::error;
    if(current!=world)return Result::retired;
    if(!pointer(game_+0x346BFC8,r.implementation) || r.implementation!=world+0x40)return Result::error;
    const auto member=map(world+0xF1AEB0,entity,index);
    if(member==Lookup::absent)return Result::retired;
    if(member!=Lookup::found || index>=1048576
        || !read(world+0xF32F18+static_cast<uint64_t>(index)*24,r.descriptor))return Result::error;
    if(r.descriptor.entity!=entity || (r.descriptor.flags&3)!=1)return Result::retired;
    if(!pointer(game_+0x33266D8,r.manager) || r.manager!=r.implementation+0xF0B3B8)return Result::error;
    const auto runtime=map(r.manager+0x50,entity,index);
    if(runtime==Lookup::absent)return Result::absent; // e.g. continuous beam
    if(runtime!=Lookup::found || !read(r.manager+0x38,count) || !read(r.manager+0x2C,capacity)
        || count>capacity || capacity>4096 || index>=count || !pointer(r.manager+0x68,descriptors)
        || !pointer(descriptors+static_cast<uint64_t>(index)*8,descriptor))return Result::error;
    Descriptor d{};
    if(!read(descriptor,d))return Result::error;
    if(std::memcmp(&d,&r.descriptor,16) || (d.flags&3)!=1)return Result::retired;
    if(!pointer(r.manager+0x78,rows))return Result::error;
    const uint64_t row=rows+static_cast<uint64_t>(index)*0xA8;
    r.address=row+0x14;
    if(!read(r.address,r.cap) || !read(row+0x13,r.mode))return Result::error;
    if(!read(game_+0x346BF98,current) || current!=world)return Result::retired;
    result=r;return Result::found;
}
bool HoBConsumer::definition(const Record& record,Definition& result,bool search) noexcept {
    if(search)++stats_.definition_searches;
    uint32_t count=0,capacity=0,index=0,inverse=0;
    if(!read(record.manager+0xC8,count) || !read(record.manager+0x30,capacity)
        || count>capacity || capacity>4096)return false;
    const auto found=count?map(record.manager+0x90,record.descriptor.entity,index):Lookup::absent;
    if(found==Lookup::error)return false;
    Definition d{};
    if(found==Lookup::found) {
        uint64_t rows=0;
        if(index>=count || map(record.manager+0xB0,index,inverse)!=Lookup::found
            || inverse!=record.descriptor.entity || !pointer(record.manager+0xD0,rows))return false;
        d.address=rows+static_cast<uint64_t>(index)*0x268;d.owned=true;
    } else {
        if(!pointer(record.world+0xF12E80,d.base))return false;
        if(search) {
            const uint32_t first=static_cast<uint32_t>(record.descriptor.type%542);
            bool matched=false;
            for(uint32_t probe=0;probe<542;++probe) {
                struct Bucket {uint64_t type;uint32_t row,padding;} bucket{};
                const uint64_t address=d.base+static_cast<uint64_t>((first+probe)%542)*16;
                if(!read(address,bucket) || !bucket.type)return false;
                if(bucket.type==record.descriptor.type) {
                    if(bucket.row>=271)return false;
                    d.bucket=address-d.base;d.row=bucket.row;matched=true;break;
                }
            }
            if(!matched)return false;
        } else {
            if(definition_.owned)return false; // a different definition needs a new equip
            struct Bucket {uint64_t type;uint32_t row,padding;} bucket{};
            d.bucket=definition_.bucket;d.row=definition_.row;
            if(!read(d.base+d.bucket,bucket) || bucket.type!=record.descriptor.type || bucket.row!=d.row)return false;
        }
        d.address=d.base+0x21E0+static_cast<uint64_t>(d.row)*0x268;
    }
    if(!read(d.address+0x30,d.angle) || !read(d.address+0x264,d.flag) || !native_cap(d.angle,d.native_cap))return false;
    result=d;return true;
}
bool HoBConsumer::ads_witness(const Record& record) const noexcept {
    Snapshot local{};CameraRequest request{};
    if(!local_snapshot(game_,local) || local.world!=record.world || local.avatar!=identity_.avatar
        || local.weapon!=record.descriptor.entity || !camera_request(local.camera,0,0,request)
        || request.kind!=6 || request.avatar!=local.avatar || request.weapon!=local.weapon || request.body!=local.body)return false;
    uint64_t manager=0,descriptor=0;
    uint32_t count=0,index=0;
    Descriptor actor{},character{};
    if(map(record.world+0xF1AEB0,local.avatar,index)!=Lookup::found || index>=1048576
        || !read(record.world+0xF32F18+static_cast<uint64_t>(index)*24,actor)
        || !pointer(game_+0x3326D20,manager) || !read(manager+0x6C,count) || !count || count>8
        || map(manager+0xF8,local.avatar,index)!=Lookup::found || index>=count
        || !pointer(manager+0x110+static_cast<uint64_t>(index)*8,descriptor) || !read(descriptor,character)
        || std::memcmp(&actor,&character,sizeof actor))return false;
    uint8_t flags[24]{};
    return guarded_read(manager+0x53E880+static_cast<uint64_t>(index)*0x1238,flags,sizeof flags)
        && (flags[6]&1) && !(flags[14]&4);
}
bool HoBConsumer::prepare(const Identity& identity) noexcept {
    if(prepared_attempted_ && identity_.world==identity.world && identity_.weapon==identity.weapon
        && identity_.avatar==identity.avatar && identity_.generation==identity.generation)return prepare_ok_;
    if(!restore())return false;
    identity_=identity;prepared_valid_=false;prepared_attempted_=true;prepare_ok_=false;
    stats_.eligible=false;++stats_.preparations;
    Record record{};
    const auto found=resolve(identity.world,identity.weapon,record);
    if(found==Result::error)return false;
    if(found!=Result::found) {prepare_ok_=true;return true;}
    Snapshot local{};
    if(!local_snapshot(game_,local) || local.world!=identity.world || local.avatar!=identity.avatar
        || local.weapon!=identity.weapon)return false;
    Definition d{};
    if(!definition(record,d,true)) {prepare_ok_=true;return true;} // unsupported authored policy remains native
    Record closing{};
    if(resolve(identity.world,identity.weapon,closing)!=Result::found || closing.address!=record.address
        || std::memcmp(&closing.descriptor,&record.descriptor,16) || closing.cap!=record.cap)return false;
    prepared_=record;definition_=d;prepared_valid_=true;
    stats_.eligible=!d.flag && scalar(d.native_cap)>scalar(target) && scalar(d.native_cap)<=scalar(0x40490FDB);
    if(stats_.eligible && record.cap!=d.native_cap)quarantine(record);
    prepare_ok_=true;return true;
}
bool HoBConsumer::apply() noexcept {
    if(stats_.owned || !stats_.enabled || !stats_.ads || !prepared_valid_ || !stats_.eligible || quarantined(prepared_))return true;
    Record current{};
    const auto found=resolve(prepared_.world,prepared_.descriptor.entity,current);
    if(found==Result::error)return false;
    if(found!=Result::found || std::memcmp(&current.descriptor,&prepared_.descriptor,16))return true;
    Definition d{};
    if(current.mode || !definition(current,d,false) || d.angle!=definition_.angle || d.flag!=definition_.flag
        || d.native_cap!=definition_.native_cap)return true;
    if(current.cap!=definition_.native_cap) {quarantine(current);return true;}
    if(!ads_witness(current))return true;
    Record closing{};
    if(resolve(current.world,current.descriptor.entity,closing)!=Result::found || closing.address!=current.address
        || std::memcmp(&closing.descriptor,&current.descriptor,16) || closing.cap!=current.cap || closing.mode!=current.mode)return false;
    if(!writable(current.address,game_))return false;
    lease_=current;lease_.cap=definition_.native_cap;stats_.owned=true;
    uint32_t observed=0;
    if(!compare_exchange(current.address,definition_.native_cap,target,observed))return false;
    if(observed!=definition_.native_cap) {stats_.owned=false;quarantine(current);return true;}
    uint32_t check=0;
    if(!read(current.address,check))return false;
    if(check!=target) {stats_.owned=false;quarantine(current);return true;}
    ++stats_.applications;return true;
}
bool HoBConsumer::restore() noexcept {
    if(!stats_.owned)return true;
    Record current{};
    const auto found=resolve(lease_.world,lease_.descriptor.entity,current);
    if(found==Result::error)return false;
    if(found!=Result::found || std::memcmp(&current.descriptor,&lease_.descriptor,16)) {stats_.owned=false;return true;}
    if(current.cap==lease_.cap) {stats_.owned=false;return true;}
    if(current.cap!=target) {quarantine(current);stats_.owned=false;return true;}
    if(!writable(current.address,game_))return false;
    uint32_t observed=0;
    if(!compare_exchange(current.address,target,lease_.cap,observed))return false;
    if(observed!=target && observed!=lease_.cap)quarantine(current);
    uint32_t check=0;
    if(!read(current.address,check))return false;
    if(check==target)return false;
    if(check!=lease_.cap)quarantine(current);
    stats_.owned=false;++stats_.restorations;return true;
}
bool HoBConsumer::set_enabled(bool enabled) noexcept {
    if(GetCurrentThreadId()!=thread_)return false;
    stats_.enabled=enabled;
    return enabled?apply():restore();
}
bool HoBConsumer::notify(const Notice& notice) noexcept {
    if(GetCurrentThreadId()!=thread_)return false;
    if(notice.event!=Event::world_begin && notice.event!=Event::equipped
        && (notice.identity.world!=identity_.world || notice.identity.generation!=identity_.generation
            || notice.identity.avatar!=identity_.avatar || notice.identity.weapon!=identity_.weapon))return false;
    switch(notice.event) {
    case Event::world_begin:
        if(!restore())return false;
        if(identity_.world && identity_.world!=notice.identity.world) {foreign_count_=0;quarantine_full_=false;}
        identity_=notice.identity;prepared_valid_=prepared_attempted_=false;stats_.ads=stats_.eligible=false;return true;
    case Event::equipped:return prepare(notice.identity);
    case Event::ads_enter:stats_.ads=true;return apply();
    case Event::ads_exit:stats_.ads=false;return restore();
    case Event::unequipped:
        if(!restore())return false;
        prepared_valid_=prepared_attempted_=false;stats_.eligible=false;identity_.weapon=0;return true;
    case Event::world_end:
        stats_.ads=false;
        prepared_valid_=prepared_attempted_=false;stats_.eligible=false;
        // Keep identity-only recovery intent if the dropped weapon still lives.
        return restore();
    }
    return false;
}
}
