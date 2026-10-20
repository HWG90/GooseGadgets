#pragma once
#include <stdint.h>
#define NADSC_EXPORT extern "C" __declspec(dllexport)
struct NADSC_Config {
    uint32_t size,abi;
    uint64_t game,exe,context,camera,avatar_owner;
    uint32_t avatar_index,avatar,body,camera_unit;
    // Horizontal view clearance/world-up metres; head damping is root-local.
    float forward,up,smoothing_ms,blend_ms;
    uint32_t max_gap_ms,reserved;
};
struct NADSC_Stats {
    uint32_t size,abi,installed,armed,error,reserved;
    uint64_t seen,forwarded,replaced,native6_forwarded,resets;
    float blend,head_distance,last_dt,padding;
};
static_assert(sizeof(NADSC_Config)==88,"NADSC_Config ABI");
static_assert(sizeof(NADSC_Stats)==80,"NADSC_Stats ABI");
NADSC_EXPORT uint32_t NADSC_Validate(const NADSC_Config*);
// Begin0: output0/no own lease; Begin1: armed; Begin2: token owns cleanup.
// Arming permits mask0/2; observed vault mask0x20 is an already-owned normal4 fallback only.
// Normal4 head anchoring accepts known mission state36, or bridge state3 only
// with the fresh scene3/combat-role2 predicate; ordinary ship role4 is excluded.
NADSC_EXPORT uint32_t NADSC_Begin(const NADSC_Config*,uint64_t* generation);
NADSC_EXPORT uint32_t NADSC_End(uint64_t generation);
// Generation0 is accepted only while no session is reserved.
// Atomic health/counters are fresh; display floats use a bounded complete
// tuple snapshot and never wait for the native camera setter.
NADSC_EXPORT uint32_t NADSC_ReadStats(uint64_t generation,NADSC_Stats*);
NADSC_EXPORT uint32_t NADSC_Error(void);

// Update only an armed generation's offsets; no dispatch changes or blend reset.
NADSC_EXPORT uint32_t NADSC_SetOffsets(uint64_t generation,float right,float forward,float up);

struct NADSC_FreeStats {uint32_t size,gate;uint64_t applied,ads_bypassed,remaining_ms;float yaw,pitch;uint64_t measured;double total_us,max_us;};
static_assert(sizeof(NADSC_FreeStats)==64,"NADSC_FreeStats ABI");
NADSC_EXPORT uint32_t NADSC_FreeAim(uint64_t generation,uint32_t milliseconds);
NADSC_EXPORT uint32_t NADSC_FreeAimStats(uint64_t generation,NADSC_FreeStats*);

struct NADSC_ParentStats45 {uint64_t samples,rejected,remaining_ms;float max_degrees,padding;};
NADSC_EXPORT uint32_t NADSC_ObserveParent(uint64_t generation,uint32_t milliseconds);
NADSC_EXPORT uint32_t NADSC_ParentStats(uint64_t generation,NADSC_ParentStats45*);

struct NADSC_KickStats46Data {uint64_t pulses,frames;uint32_t enabled;float angle;};
NADSC_EXPORT uint32_t NADSC_SetKick46(uint64_t generation,uint32_t enabled);
NADSC_EXPORT uint32_t NADSC_KickStats46(uint64_t generation,NADSC_KickStats46Data*);

NADSC_EXPORT uint32_t NADSC_SetPresentation47(uint64_t generation);
NADSC_EXPORT uint32_t NADSC_SetCameraMotion47(uint64_t generation,float x,float y,float z,float pitch,float yaw,float roll);

struct NADSC_Profile47Data {uint32_t remaining,count;double mean_us,p99_us,max_us;};
NADSC_EXPORT uint32_t NADSC_Profile47(uint64_t generation,uint32_t count);
NADSC_EXPORT uint32_t NADSC_ProfileStats47(uint64_t generation,NADSC_Profile47Data*);
