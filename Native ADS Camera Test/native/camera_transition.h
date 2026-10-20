#pragma once
#include "free_aim_math.h"
#include <cstdint>
namespace CameraTransition {
struct Pose{FreeAim::Q q{};float p[3]{};};
inline FreeAim::Q toward_identity(FreeAim::Q q,float t){
 if(q.w<0){q.x=-q.x;q.y=-q.y;q.z=-q.z;q.w=-q.w;}
 const float angle=std::acos(std::min(1.0f,q.w));
 if(angle<.0001f)return {};
 const float scale=std::sin((1-t)*angle)/std::sin(angle);
 return {q.x*scale,q.y*scale,q.z*scale,std::cos((1-t)*angle)};
}
struct State{
 bool valid=false,active=false,last_ads=false;uint32_t kind=0,weapon=0;uint64_t start=0,previous=0,transitions=0;Pose last{};FreeAim::Q error{};float offset[3]{};
 void reset(){valid=active=false;}
 void apply(const Pose& desired,uint32_t next_kind,bool ads,uint32_t next_weapon,uint64_t tick,Pose& out){
  out=desired;
  if(!valid){if(next_kind==6)valid=true;}
  else if(tick<previous||tick-previous>250){active=false;}
  else if(!ads&&(kind!=next_kind||last_ads||next_weapon!=weapon)){
   float distance=0;for(unsigned a=0;a<3;++a){offset[a]=last.p[a]-desired.p[a];distance+=offset[a]*offset[a];}
   // Never blend a teleported/dead player through world geometry.
   active=distance<=4;start=tick;error=FreeAim::mul(last.q,FreeAim::inv(desired.q));if(active)++transitions;
  }
  if(ads)active=false; // Native ADS owns its entry, pose and zoom exactly.
  if(active){const float t=std::min(1.0f,static_cast<float>(tick-start)/150),e=t*t*(3-2*t);
   if(t>=1)active=false;
   else{
    // The incoming rig continues solving after its camera becomes active.
    // Decaying a single captured offset forwards every later solve jump.
    // Rebase against our last presented pose and spend only this frame's
    // fraction of the remaining blend. A stationary target follows the same
    // smoothstep curve, while moving targets cannot bypass the handoff.
    const float prior=std::min(1.0f,static_cast<float>(previous>=start?previous-start:0)/150);
    const float prior_e=prior*prior*(3-2*prior);
    const float step=tick==start?0:std::min(1.0f,(e-prior_e)/std::max(.000001f,1-prior_e));
    error=FreeAim::mul(last.q,FreeAim::inv(desired.q));
    out.q=FreeAim::mul(toward_identity(error,step),desired.q);
    for(unsigned a=0;a<3;++a)out.p[a]=last.p[a]+(desired.p[a]-last.p[a])*step;
   }
  }
  if(valid){last=out;kind=next_kind;weapon=next_weapon;last_ads=ads;previous=tick;}
 }
};
}
