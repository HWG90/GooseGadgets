#pragma once
#include <stdint.h>
#define NADSP_EXPORT extern "C" __declspec(dllexport)
struct NADSP_Config {
    uint32_t size,abi;
    uint64_t game,exe,context,request,avatar_owner;
    uint32_t avatar_index,avatar,weapon,body,viewmodel,duration_ms;
    uint64_t weapon_descriptor;
    uint32_t weapon_unit,blend_ms;
    float offset_x,offset_z;
};
struct NADSP_Stats {
    uint32_t size,abi,installed,armed,expired,error;
    // Legacy ABI field names: modified shared-rig calls and native-baseline restores.
    uint64_t seen_position,seen_rotation,forwarded_position,forwarded_rotation,weapon_updates,zero_restores;
    float blend,target_weight;
};
static_assert(sizeof(NADSP_Config)==96,"NADSP_Config ABI");
static_assert(sizeof(NADSP_Stats)==80,"NADSP_Stats ABI");
NADSP_EXPORT uint32_t NADSP_Validate(const NADSP_Config*);
// Begin: 0 rejected/no owned lease; 1 armed; 2 owned cleanup required.
NADSP_EXPORT uint32_t NADSP_Begin(const NADSP_Config*);
NADSP_EXPORT uint32_t NADSP_End(void);
NADSP_EXPORT uint32_t NADSP_ReadStats(NADSP_Stats*);
NADSP_EXPORT uint32_t NADSP_Error(void);
