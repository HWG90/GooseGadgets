#pragma once
#include <stdint.h>
#define NADSB_EXPORT extern "C" __declspec(dllexport)
struct NADSB_Config {
    uint32_t size,abi;
    uint64_t game,exe,context,camera,avatar_owner,request;
    uint32_t avatar_index,avatar,body,weapon;
    uint64_t reserved;
};
struct NADSB_Stats {
    uint32_t size,abi,installed,armed,error,reserved;
    uint64_t seen,forwarded,replaced,immediate_applies;
    uint32_t last_hash,last_instance;
    float last_native,last_applied;
    uint64_t reserved_tail;
};
static_assert(sizeof(NADSB_Config)==80,"NADSB_Config ABI");
static_assert(sizeof(NADSB_Stats)==80,"NADSB_Stats ABI");
// Validate permits normal4 for read-only preflight. Begin requires owned6.
// Error18 means no eligible per-weapon optic source; no session is owned.
NADSB_EXPORT uint32_t NADSB_Validate(const NADSB_Config*);
// 0: output0/no own lease; 1: armed; 2: nonzero token owns cleanup.
NADSB_EXPORT uint32_t NADSB_Begin(const NADSB_Config*,uint64_t* generation);
NADSB_EXPORT uint32_t NADSB_End(uint64_t generation);
// Generation0 is valid only while no lease is reserved.
NADSB_EXPORT uint32_t NADSB_ReadStats(uint64_t generation,NADSB_Stats*);
NADSB_EXPORT uint32_t NADSB_Error(void);
