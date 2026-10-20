#pragma once
#include "hob_consumer.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <initializer_list>
#include <utility>
#include <vector>
#ifndef CHECK
#define CHECK(x) do {if(!(x)){std::fprintf(stderr,"line %d: %s\n",__LINE__,#x);std::exit(1);}}while(0)
#endif
constexpr uint32_t pi=0x40490FDB,target=0x3C0EFA35;
struct Descriptor {uint64_t type;uint32_t entity,body,light,flags;};
static_assert(sizeof(Descriptor)==24);
static uint32_t bits(float value) {uint32_t b=0;std::memcpy(&b,&value,4);return b;}
struct Model {
    std::vector<void*> allocations;
    uint64_t game=0,world=0,implementation=0,projectile=0,wielder=0,character=0;
    uint64_t rows=0,wield_rows=0,base=0,camera=0,actor_descriptor=0,weapon_descriptor=0;
    uint32_t weapon=11;
    uint64_t allocate(size_t n,bool reserve=false) {
        void* p=VirtualAlloc(nullptr,n,reserve?MEM_RESERVE:MEM_RESERVE|MEM_COMMIT,reserve?PAGE_NOACCESS:PAGE_READWRITE);
        CHECK(p);allocations.push_back(p);return reinterpret_cast<uint64_t>(p);
    }
    void commit(uint64_t at,size_t n) {
        const uint64_t start=at&~uint64_t{4095},end=(at+n+4095)&~uint64_t{4095};
        CHECK(VirtualAlloc(reinterpret_cast<void*>(start),static_cast<SIZE_T>(end-start),MEM_COMMIT,PAGE_READWRITE));
    }
    template<class T> void put(uint64_t at,T value) {commit(at,sizeof value);std::memcpy(reinterpret_cast<void*>(at),&value,sizeof value);}
    template<class T> T get(uint64_t at) const {T value{};std::memcpy(&value,reinterpret_cast<const void*>(at),sizeof value);return value;}
    void map(uint64_t at,std::initializer_list<std::pair<uint32_t,uint32_t>> entries) {
        const auto buckets=allocate(32);
        for(uint32_t i=0;i<4;++i) {put(buckets+i*8,uint32_t{0xffffffff});put(buckets+i*8+4,uint32_t{0});}
        for(const auto& e:entries) {
            uint32_t slot=e.first&3;
            while(get<uint32_t>(buckets+slot*8)!=0xffffffff)slot=(slot+1)&3;
            put(buckets+slot*8,e.first);put(buckets+slot*8+4,e.second);
        }
        put(at,buckets);put(at+8,uint32_t{4});put(at+12,uint32_t{0xffffffff});put(at+16,uint32_t{1});
    }
    void set_weapon(uint32_t id) {
        weapon=id;
        put(weapon_descriptor,Descriptor{0x1122334455667788ULL,id,9,42,1});
        map(world+0xF1AEB0,{{10,0},{id,1}});map(projectile+0x50,{{id,0}});
        put(wield_rows,id);
    }
    void view(uint16_t kind) {
        put(camera+0x1f8,uint32_t{0});put(camera+0x1fc,uint32_t{1});
        const uint32_t request[4]={kind,10,weapon,7};std::memcpy(reinterpret_cast<void*>(camera+0x200),request,16);
    }
    hob::Identity identity(uint32_t selected=0) const {return {world,1,10,selected};}
    hob::Notice notice(hob::Event event) const {return {event,hob::Reason::ordinary,identity(weapon)};}
    void start(hob::HoBConsumer& consumer) {
        CHECK(consumer.set_enabled(true));
        CHECK(consumer.notify({hob::Event::world_begin,hob::Reason::ordinary,identity()}));
        CHECK(consumer.notify(notice(hob::Event::equipped)));
    }
    void enter(hob::HoBConsumer& c) {view(6);CHECK(c.notify(notice(hob::Event::ads_enter)));}
    void leave(hob::HoBConsumer& c) {CHECK(c.notify(notice(hob::Event::ads_exit)));view(4);}
    Model() {
        game=allocate(0x4744000,true);world=allocate(0xF40000,true);implementation=world+0x40;
        projectile=implementation+0xF0B3B8;wielder=implementation+0xE9FB10;
        put(game+0x346BF98,world);put(game+0x346BFC8,implementation);put(game+0x33266D8,projectile);
        put(game+0x3326420,wielder);
        actor_descriptor=world+0xF32F18;weapon_descriptor=actor_descriptor+24;
        put(actor_descriptor,Descriptor{0x8877,10,7,41,1});
        map(world+0xF22EC8,{{41,0}});
        const uint64_t player=allocate(4096);put(player+0x88,uint32_t{1});put(player+0x3a8,uint32_t{41});
        put(game+0x3326468,player);
        put(wielder+0x1c,uint32_t{1});map(wielder+0x30,{{10,0}});
        const uint64_t wielder_descriptors=allocate(8);put(wielder_descriptors,actor_descriptor);put(wielder+0x48,wielder_descriptors);
        wield_rows=allocate(0x1d0);put(wielder+0x60,wield_rows);
        put(projectile+0x38,uint32_t{1});put(projectile+0x2c,uint32_t{4});
        put(projectile+0xc8,uint32_t{0});put(projectile+0x30,uint32_t{4});
        const uint64_t descriptors=allocate(8);put(descriptors,weapon_descriptor);put(projectile+0x68,descriptors);
        rows=allocate(4096);put(projectile+0x78,rows);put(rows+0x14,pi);put(rows+0x13,uint8_t{0});
        set_weapon(11);
        base=allocate(0x21e0+271*0x268);put(world+0xF12E80,base);
        const uint64_t bucket=base+(0x1122334455667788ULL%542)*16;
        put(bucket,uint64_t{0x1122334455667788ULL});put(bucket+8,uint32_t{0});
        put(base+0x21e0+0x30,bits(180.0f));put(base+0x21e0+0x264,uint8_t{0});
        camera=allocate(0x2100);put(game+0x346D560,camera);view(4);
        character=allocate(0x540000,true);put(game+0x3326D20,character);
        put(character+0x6c,uint32_t{1});map(character+0xf8,{{10,0}});put(character+0x110,actor_descriptor);
        commit(character+0x53e880,24);put(character+0x53e886,uint8_t{1});
    }
    ~Model() {for(auto* p:allocations)CHECK(VirtualFree(p,0,MEM_RELEASE));}
};
