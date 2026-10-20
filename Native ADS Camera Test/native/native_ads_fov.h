#pragma once
#include <stdint.h>
#define NADSF_EXPORT extern "C" __declspec(dllexport)
struct NADSF_Config {
    uint32_t size,abi;
    uint64_t game,exe,context,camera,avatar_owner,request;
    uint32_t avatar_index,avatar,body,weapon;
    uint64_t reserved;
};
struct NADSF_Stats {
    uint32_t size,abi,installed,armed,error,reserved;
    uint64_t seen,forwarded,replaced,immediate_applies,binds,ads_forwarded;
    float last_native,last_applied,source_degrees,padding;
};
static_assert(sizeof(NADSF_Config)==80,"NADSF_Config ABI");
static_assert(sizeof(NADSF_Stats)==88,"NADSF_Stats ABI");
// Validate permits current normal4 for read-only preflight; Begin requires6.
NADSF_EXPORT uint32_t NADSF_Validate(const NADSF_Config*);
// 0: output generation0/no owned lease; 1: armed; 2: owned cleanup required.
NADSF_EXPORT uint32_t NADSF_Begin(const NADSF_Config*,uint64_t* generation);
NADSF_EXPORT uint32_t NADSF_Bind(uint64_t generation,uint64_t request,uint32_t weapon);
NADSF_EXPORT uint32_t NADSF_End(uint64_t generation);
// Generation0 is valid only while no lease is reserved. Health/counters are
// atomic; display angles use the latest complete nonblocking diagnostic tuple.
NADSF_EXPORT uint32_t NADSF_ReadStats(uint64_t generation,NADSF_Stats*);
NADSF_EXPORT uint32_t NADSF_Error(void);
