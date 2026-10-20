#pragma once
#include <cstddef>
#include "commit_stub.h"
#include <cstdint>
namespace hob {
struct Snapshot {
    uint64_t world = 0, implementation = 0, manager = 0;
    uint32_t avatar = 0, weapon = 0, index = 0, body = 0;
    uint64_t camera = 0;
};
bool guarded_read(uint64_t, void*, size_t) noexcept;
bool admit_game(uint64_t& game, uint64_t targets[4], uint64_t& retire_slot,
    uint64_t& shutdown_slot) noexcept;
bool inspect_module_profile(uint64_t game,uint64_t targets[4],uint64_t& retire_slot,
    uint64_t& shutdown_slot) noexcept;
bool local_snapshot(uint64_t game, Snapshot& result) noexcept;
bool camera_matches(uint64_t game, uint64_t camera, uint32_t avatar, uint32_t weapon) noexcept;
bool unwield_matches(uint64_t game, uint64_t manager, uint32_t index,
    uint32_t avatar, uint32_t weapon) noexcept;
bool retirement_matches(uint64_t descriptor, uint32_t avatar) noexcept;
struct CameraRequest { uint16_t kind=0,reserved=0; uint32_t avatar=0,weapon=0,body=0; };
// Read-only event witness. An override predicts a STORE already selected by the
// native branch; it is not independent authority for changing a weapon.
bool camera_request(uint64_t camera,uint32_t field,uint32_t value,CameraRequest&) noexcept;
bool admit_commit_sites(uint64_t game,std::vector<CommitSite>&) noexcept;
}
