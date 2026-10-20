#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include "hob_consumer.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <initializer_list>
#include <thread>
#include <utility>
#include <vector>
#define CHECK(x) do {if(!(x)){std::fprintf(stderr,"line %d: %s\n",__LINE__,#x);std::exit(1);}}while(0)
#include "consumer_model.h"
static void baseline() {
    Model m;hob::HoBConsumer c(m.game);m.start(c);
    CHECK(c.stats().preparations==1 && c.stats().definition_searches==1 && !c.stats().owned);
    uint8_t before[0xa8]{};std::memcpy(before,reinterpret_cast<void*>(m.rows),sizeof before);
    m.enter(c);CHECK(m.get<uint32_t>(m.rows+0x14)==target && c.stats().owned);
    for(unsigned i=0;i<1000;++i)CHECK(c.notify(m.notice(hob::Event::ads_enter)));
    CHECK(c.stats().applications==1 && c.stats().preparations==1 && c.stats().definition_searches==1);
    for(unsigned i=0;i<sizeof before;++i)if(i<0x14 || i>=0x18)CHECK(m.get<uint8_t>(m.rows+i)==before[i]);
    CHECK(c.set_enabled(false));CHECK(m.get<uint32_t>(m.rows+0x14)==pi);
    CHECK(c.set_enabled(true));CHECK(m.get<uint32_t>(m.rows+0x14)==target);
    m.leave(c);CHECK(m.get<uint32_t>(m.rows+0x14)==pi && !c.stats().owned);
    CHECK(c.stats().preparations==1 && c.stats().definition_searches==1);
    CHECK(m.get<uint32_t>(m.base+0x21e0+0x30)==bits(180.0f));
}
static void foreign_edits() {
    Model m;hob::HoBConsumer c(m.game);m.start(c);m.enter(c);
    m.put(m.rows+0x14,bits(1.0f));m.leave(c);
    CHECK(!c.stats().owned && c.stats().foreign_edits==1 && m.get<uint32_t>(m.rows+0x14)==bits(1.0f));
    m.enter(c);CHECK(c.set_enabled(false));CHECK(c.set_enabled(true));
    CHECK(m.get<uint32_t>(m.rows+0x14)==bits(1.0f) && !c.stats().owned);
    CHECK(c.notify(m.notice(hob::Event::unequipped)));CHECK(c.notify(m.notice(hob::Event::equipped)));
    m.enter(c);CHECK(m.get<uint32_t>(m.rows+0x14)==bits(1.0f));
}
static void restore_retry() {
    Model m;hob::HoBConsumer c(m.game);m.start(c);m.enter(c);
    DWORD old=0;CHECK(VirtualProtect(reinterpret_cast<void*>(m.rows),4096,PAGE_READONLY,&old));
    CHECK(!c.notify(m.notice(hob::Event::ads_exit)) && c.stats().owned);
    CHECK(m.get<uint32_t>(m.rows+0x14)==target);
    CHECK(VirtualProtect(reinterpret_cast<void*>(m.rows),4096,PAGE_READWRITE,&old));
    CHECK(c.set_enabled(false));CHECK(!c.stats().owned && m.get<uint32_t>(m.rows+0x14)==pi);
}
static void relocation_and_retirement() {
    Model m;hob::HoBConsumer c(m.game);m.start(c);m.enter(c);
    const auto old=m.rows;const auto moved=m.allocate(4096);
    std::memcpy(reinterpret_cast<void*>(moved),reinterpret_cast<void*>(old),0xa8);m.put(m.projectile+0x78,moved);m.rows=moved;
    m.leave(c);CHECK(m.get<uint32_t>(moved+0x14)==pi && m.get<uint32_t>(old+0x14)==target);
    m.enter(c);auto descriptor=m.get<Descriptor>(m.weapon_descriptor);++descriptor.body;m.put(m.weapon_descriptor,descriptor);
    m.put(moved+0x14,bits(2.0f));m.leave(c);
    CHECK(!c.stats().owned && m.get<uint32_t>(moved+0x14)==bits(2.0f));
}
static void private_definition() {
    Model m;m.set_weapon(0x40000b);hob::HoBConsumer c(m.game);
    m.put(m.projectile+0xc8,uint32_t{1});m.map(m.projectile+0x90,{{m.weapon,0}});m.map(m.projectile+0xb0,{{0,m.weapon}});
    const auto private_row=m.allocate(0x268);m.put(m.projectile+0xd0,private_row);
    m.put(private_row+0x30,bits(120.0f));m.put(private_row+0x264,uint8_t{0});
    float scale=0;const uint32_t scale_bits=0x3C8EFA35;std::memcpy(&scale,&scale_bits,4);
    const uint32_t native=bits(120.0f*scale);m.put(m.rows+0x14,native);
    m.start(c);m.enter(c);CHECK(m.get<uint32_t>(m.rows+0x14)==target);
    m.leave(c);CHECK(m.get<uint32_t>(m.rows+0x14)==native);
    CHECK(c.stats().preparations==1 && c.stats().definition_searches==1);
}
static void native_paths() {
    {Model m;m.map(m.projectile+0x50,{});hob::HoBConsumer c(m.game);m.start(c);m.enter(c);
     CHECK(!c.stats().owned && m.get<uint32_t>(m.rows+0x14)==pi);}
    {Model m;m.put(m.rows+0x13,uint8_t{1});hob::HoBConsumer c(m.game);m.start(c);m.enter(c);
     CHECK(!c.stats().owned && m.get<uint32_t>(m.rows+0x14)==pi);}
    {Model m;m.put(m.base+0x21e0+0x264,uint8_t{1});hob::HoBConsumer c(m.game);m.start(c);m.enter(c);
     CHECK(!c.stats().owned && !c.stats().eligible);}
    {Model m;m.put(m.character+0x53e88e,uint8_t{4});hob::HoBConsumer c(m.game);m.start(c);m.enter(c);
     CHECK(!c.stats().owned && m.get<uint32_t>(m.rows+0x14)==pi);}
    {Model m;m.put(m.base+0x21e0+0x30,uint32_t{0x7fc00000});hob::HoBConsumer c(m.game);m.start(c);m.enter(c);
     CHECK(!c.stats().owned && !c.stats().eligible);}
}
static void module_write_refusal() {
    Model m;const uint64_t inside=m.game+0x100000;m.commit(inside,4096);
    std::memcpy(reinterpret_cast<void*>(inside),reinterpret_cast<void*>(m.rows),0xa8);
    m.rows=inside;m.put(m.projectile+0x78,inside);hob::HoBConsumer c(m.game);m.start(c);m.view(6);
    CHECK(!c.notify(m.notice(hob::Event::ads_enter)) && !c.stats().owned);
    CHECK(m.get<uint32_t>(inside+0x14)==pi);
}
static void identity_and_thread() {
    Model m;hob::HoBConsumer c(m.game);m.start(c);m.view(6);
    auto notice=m.notice(hob::Event::ads_enter);++notice.identity.weapon;
    CHECK(!c.notify(notice));bool called=true;
    std::thread other([&]{called=c.notify(m.notice(hob::Event::ads_enter));});other.join();
    CHECK(!called && !c.stats().owned && m.get<uint32_t>(m.rows+0x14)==pi);
}
int main() {
    baseline();foreign_edits();restore_retry();relocation_and_retirement();private_definition();
    native_paths();module_write_refusal();identity_and_thread();
    std::puts("PASS native consumer: once-per-equip setup, duplicate idleness, exact native cap/restoration, owned definitions/full entity IDs, foreign quarantine, guarded CAS/retry, relocation/retirement, native paths and thread/identity refusal");
}
