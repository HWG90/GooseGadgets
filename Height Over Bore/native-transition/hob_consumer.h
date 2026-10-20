#pragma once
#include "transition_core.h"
#include <array>

namespace hob {
struct ConsumerStats {
    uint64_t preparations=0,definition_searches=0,applications=0,restorations=0,foreign_edits=0;
    bool enabled=false,ads=false,owned=false,eligible=false;
};
// Native event consumer. No frame/update method, worker, Lua callback or timer.
// Construct and call on the provider's control/game thread.
class HoBConsumer final {
public:
    explicit HoBConsumer(uint64_t game) noexcept : game_(game),thread_(GetCurrentThreadId()) {}
    static bool receive(void*,const Notice&) noexcept;
    bool notify(const Notice&) noexcept;
    bool set_enabled(bool) noexcept;
    ConsumerStats stats() const noexcept {return stats_;} // control thread only
private:
    struct Descriptor {uint64_t type=0;uint32_t entity=0,body=0,light=0,flags=0;};
    struct Record {
        uint64_t world=0,implementation=0,manager=0,address=0;
        Descriptor descriptor{};
        uint32_t cap=0;uint8_t mode=0;
    };
    struct Definition {
        uint64_t address=0,base=0,bucket=0;
        uint32_t row=0,angle=0,native_cap=0;
        uint8_t flag=0;
        bool owned=false;
    };
    struct Foreign {uint64_t world=0;Descriptor descriptor{};};
    enum class Result {found,absent,retired,error};
    bool prepare(const Identity&) noexcept;
    Result resolve(uint64_t,uint32_t,Record&) const noexcept;
    bool definition(const Record&,Definition&,bool search) noexcept;
    bool ads_witness(const Record&) const noexcept;
    bool apply() noexcept;
    bool restore() noexcept;
    bool quarantined(const Record&) const noexcept;
    void quarantine(const Record&) noexcept;
    uint64_t game_;
    DWORD thread_;
    Identity identity_{};
    Record prepared_{},lease_{};
    Definition definition_{};
    bool prepared_valid_=false,prepared_attempted_=false,prepare_ok_=false,quarantine_full_=false;
    std::array<Foreign,16> foreign_{};
    uint32_t foreign_count_=0;
    ConsumerStats stats_{};
};
}
