#pragma once
#include <stdint.h>
#define NADSE_EXPORT extern "C" __declspec(dllexport)
struct NADSE_Config {
    uint32_t size,abi;
    uint64_t game,exe,context,request,avatar_owner;
    // duration_ms: 0 stays armed until End/guard failure; 1..30500 is bounded.
    uint32_t avatar_index,avatar,weapon,body,viewmodel,duration_ms;
    uint64_t weapon_descriptor;
    uint32_t weapon_unit,blend_ms;
    float offset_x,offset_y,offset_z;
    uint32_t reserved;
};
struct NADSE_Stats {
    uint32_t size,abi,installed,armed,expired,error;
    // Legacy ABI field names: modified shared-rig calls and native-baseline restores.
    uint64_t seen_position,seen_rotation,forwarded_position,forwarded_rotation,weapon_updates,zero_restores;
    float blend,target_weight;
};
// Optional, lazy diagnostics; it does not change Config/Stats ABI2.
struct NADSE_DepthStats {
    uint32_t size,abi,installed,armed,supported,reason,zoom_index,reserved;
    uint64_t applied,unsupported,cache_refreshes,cache_checks,ads_bypassed;
    float native_distance,reference_distance,correction,zoom,target_fov,current_fov,gain,padding;
};
static_assert(sizeof(NADSE_Config)==104,"NADSE_Config ABI");
static_assert(sizeof(NADSE_Stats)==80,"NADSE_Stats ABI");
static_assert(sizeof(NADSE_DepthStats)==104,"NADSE_DepthStats ABI");
NADSE_EXPORT uint32_t NADSE_Validate(const NADSE_Config*);
// Begin: 0 rejected/no owned lease; 1 armed; 2 owned cleanup required.
NADSE_EXPORT uint32_t NADSE_Begin(const NADSE_Config*,uint64_t* generation);
NADSE_EXPORT uint32_t NADSE_SetPlacement(uint64_t generation,float x,float y,float z);
// Presentation delta is separate from saved placement; all axes are metres.
NADSE_EXPORT uint32_t NADSE_SetADSPlacement(uint64_t generation,float x,float y,float z);
NADSE_EXPORT uint32_t NADSE_SetMotion(uint64_t generation,float dx,float dy,float dz);
// Atomic presentation motion: metres plus a parent-local unit quaternion.
// Rotation is limited to 35 degrees and applies only to the verified branch 5.
NADSE_EXPORT uint32_t NADSE_SetTransform(uint64_t generation,float dx,float dy,float dz,
    float qx,float qy,float qz,float qw);
// Explicit authored ADS rotation only; the ordinary motion API still yields.
NADSE_EXPORT uint32_t NADSE_SetAuthoredTransform(uint64_t generation,float dx,float dy,float dz,float qx,float qy,float qz,float qw);
NADSE_EXPORT uint32_t NADSE_End(uint64_t generation);
// Generation 0 is accepted only when no lease is reserved.
// Health/counters stay atomic and fresh. Display values use one bounded
// complete-tuple snapshot. Timed expiry still drains/restores under its lock.
NADSE_EXPORT uint32_t NADSE_ReadStats(uint64_t generation,NADSE_Stats*);
NADSE_EXPORT uint32_t NADSE_ReadDepthStats(uint64_t generation,NADSE_DepthStats*);
NADSE_EXPORT uint32_t NADSE_Error(void);
