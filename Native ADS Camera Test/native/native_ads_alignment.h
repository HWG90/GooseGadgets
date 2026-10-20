#pragma once
#include <stdint.h>
#if defined(_WIN32)
#define NADS_EXPORT extern "C" __declspec(dllexport)
#else
#define NADS_EXPORT extern "C"
#endif
struct NADS_Config {
    uint32_t size, abi;
    uint64_t game, exe, context, request, avatar_owner;
    uint32_t avatar_index, avatar, weapon, body, viewmodel, duration_ms;
};
struct NADS_Stats {
    uint32_t size, abi, installed, armed, expired, error;
    uint64_t seen_position, seen_rotation, skipped_position, skipped_rotation,
        forwarded_position, forwarded_rotation;
};
static_assert(sizeof(NADS_Config)==72,"NADS_Config ABI");
static_assert(sizeof(NADS_Stats)==72,"NADS_Stats ABI");
NADS_EXPORT uint32_t NADS_Begin(const NADS_Config* config);
// Begin: 1=armed; 0=rejected with no owned lease; 2=owned cleanup required.
NADS_EXPORT uint32_t NADS_Validate(const NADS_Config* config);
NADS_EXPORT uint32_t NADS_End(void);
NADS_EXPORT uint32_t NADS_ReadStats(NADS_Stats* stats);
NADS_EXPORT uint32_t NADS_Error(void);
