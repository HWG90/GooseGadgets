#include "transition_core.h"
#include <cstdio>
#include <cstdlib>
#include <thread>
#include <vector>
using namespace hob;
#define CHECK(x) do { if (!(x)) { std::fprintf(stderr,"line %d: %s\n",__LINE__,#x); std::exit(1); } } while (0)
struct Consumer {
    std::vector<Notice> events;
    TransitionCore* core = nullptr;
    Event fail = static_cast<Event>(999);
    bool reenter = false;
    static bool receive(void* context, const Notice& event) noexcept {
        auto& self = *static_cast<Consumer*>(context);
        self.events.push_back(event);
        if (self.reenter) {
            CHECK(!self.core->enter(event.identity.generation,event.identity.weapon));
            CHECK(!self.core->end(event.identity.generation,Reason::disable));
        }
        return event.event != self.fail;
    }
};
int main() {
    Consumer c;
    TransitionCore core(Consumer::receive,&c); c.core=&core;
    CHECK(!core.enter(1,9));
    CHECK(core.begin(100,1,7));
    CHECK(!core.begin(200,2,7));
    CHECK(!core.enter(1,9));
    CHECK(core.equip(1,9));
    CHECK(core.equip(1,9)); CHECK(c.events.size()==2);
    CHECK(!core.enter(1,10)); CHECK(!core.enter(2,9));
    c.reenter=true;
    CHECK(core.enter(1,9));
    c.reenter=false;
    CHECK(core.enter(1,9)); CHECK(c.events.size()==3);
    CHECK(!core.equip(1,10));
    CHECK(core.state().ads && core.state().identity.weapon==9);
    CHECK(core.unequip(1,Reason::weapon_change));
    CHECK(core.equip(1,10));
    CHECK(c.events[3].event==Event::ads_exit);
    CHECK(c.events[3].identity.weapon==9);
    CHECK(c.events[4].event==Event::unequipped);
    CHECK(c.events[5].event==Event::equipped);
    CHECK(c.events[5].identity.weapon==10);
    CHECK(core.enter(1,10));
    CHECK(core.leave(1,Reason::camera_replaced));
    CHECK(c.events.back().reason==Reason::camera_replaced);
    CHECK(!core.state().ads);
    CHECK(core.enter(1,10));
    CHECK(core.unequip(1,Reason::death));
    CHECK(!core.state().ads && !core.state().identity.weapon);
    CHECK(core.equip(1,11)); CHECK(core.enter(1,11));
    bool foreign_result=true;
    std::thread foreign([&] {foreign_result=core.end(1,Reason::disable);}); foreign.join();
    CHECK(!foreign_result && core.state().live);
    CHECK(core.end(1,Reason::world_teardown));
    CHECK(c.events.back().event==Event::world_end);
    CHECK(c.events[c.events.size()-2].event==Event::unequipped);
    CHECK(c.events[c.events.size()-3].event==Event::ads_exit);
    CHECK(!core.state().live && !core.state().identity.world);
    CHECK(!core.enter(1,11)); CHECK(!core.begin(100,1,7));
    CHECK(core.begin(200,2,8)); CHECK(core.equip(2,11));
    c.fail=Event::ads_enter;
    CHECK(!core.enter(2,11));
    CHECK(core.state().failed && core.state().ads);
    CHECK(!core.equip(2,12));
    c.fail=Event::ads_exit;
    CHECK(!core.end(2,Reason::world_teardown));
    CHECK(c.events.back().event==Event::world_end);
    CHECK(!core.state().live && core.state().failed);
    CHECK(!core.leave(2,Reason::ordinary));
    c.fail=static_cast<Event>(999);
    CHECK(core.begin(200,3,8)); CHECK(core.equip(3,12));
    CHECK(core.enter(3,12)); CHECK(core.end(3,Reason::disable));
    CHECK(core.begin(200,4,8)); CHECK(core.equip(4,12)); CHECK(core.enter(4,12));
    c.fail=Event::ads_exit;
    CHECK(!core.end(4,Reason::disable));
    CHECK(core.state().live && core.state().ads);
    c.fail=static_cast<Event>(999);
    CHECK(core.end(4,Reason::disable));
    CHECK(!core.state().live);
    TransitionCore no_consumer(nullptr,nullptr);
    CHECK(!no_consumer.begin(100,1,1));
    std::puts("PASS: lifecycle ordering, forced exits, stale generations, duplicate suppression, reentrancy, thread ownership, partial-apply failure and teardown invalidation");
}
