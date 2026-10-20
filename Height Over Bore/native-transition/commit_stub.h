#pragma once
#include <windows.h>
#include <cstdint>
#include <vector>

namespace hob {
// Instruments a native queue STORE branch, not the enclosing frame evaluator.
// Register numbers use x64 encoding (rax=0, rcx=1, ..., r15=15).
using BeforeCommit = void (*)(uint64_t,uint32_t,uint32_t) noexcept;
using AfterCommit = void (*)(uint64_t) noexcept;
struct CommitSite {
    uint64_t instruction;
    uint32_t instruction_size, field;
    uint8_t base_register, source_register;
    RUNTIME_FUNCTION parent;
};
struct CommitStub {
    uint64_t entry=0, body=0, pushed_flags=0, allocated=0, pop_flags=0, restored_flags=0, returning=0;
    uint32_t bytes=0;
};
struct CommitArena {
    uint64_t allocation=0, image_base=0;
    uint32_t bytes=0;
    std::vector<CommitStub> stubs;
};
// Memory and unwind registrations are process-retained. A retired native caller
// or a sampled stack can still refer to a thunk after detachment.
bool build_commit_stubs(uint64_t image_base,uint32_t image_size,
    const std::vector<CommitSite>&,BeforeCommit,AfterCommit,CommitArena&) noexcept;
}
