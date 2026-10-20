#pragma once
#include <cmath>
#include <algorithm>
namespace FreeAim {
constexpr float PI=3.14159265358979323846f;
struct Q {float x=0,y=0,z=0,w=1;};
inline Q mul(Q a,Q b){return {a.w*b.x+a.x*b.w+a.y*b.z-a.z*b.y,a.w*b.y-a.x*b.z+a.y*b.w+a.z*b.x,a.w*b.z+a.x*b.y-a.y*b.x+a.z*b.w,a.w*b.w-a.x*b.x-a.y*b.y-a.z*b.z};}
inline void rotate(Q q,const float* v,float* out){const Q r=mul(mul(q,{v[0],v[1],v[2],0}),{-q.x,-q.y,-q.z,q.w});out[0]=r.x;out[1]=r.y;out[2]=r.z;}
inline Q inv(Q q){return {-q.x,-q.y,-q.z,q.w};}
inline bool valid(Q q){const float n=q.x*q.x+q.y*q.y+q.z*q.z+q.w*q.w;return std::isfinite(n)&&std::fabs(n-1)<.025f;}
inline Q look(float yaw,float pitch){return mul({0,0,std::sin(yaw/2),std::cos(yaw/2)},{std::sin(pitch/2),0,0,std::cos(pitch/2)});}
inline float wrap(float a){return std::remainder(a,2*PI);}
inline float limit(float x,float a){return std::max(-a,std::min(a,x));}
inline bool angles(Q q,float& yaw,float& pitch){if(!valid(q))return false;const float x=2*(q.x*q.y-q.w*q.z),y=1-2*(q.x*q.x+q.z*q.z),z=2*(q.y*q.z+q.w*q.x);yaw=std::atan2(-x,y);pitch=std::asin(limit(z,1));return std::fabs(pitch)<PI*.47f;}
// A dead zone, not a spring: holding the mouse still holds the same aim offset.
// The native weapon quaternion is read-only. Only the camera result changes.
struct State {
 bool tracking=false;float yaw=0,pitch=0,range=1,offset_yaw=0,offset_pitch=0;
 void reset(){tracking=false;offset_yaw=offset_pitch=0;range=1;}
 bool apply(Q native,bool aiming,float dt,Q& out){
  float ny=0,np=0;if(!angles(native,ny,np)){reset();return false;}
  if(!tracking||dt<0||dt>.25f){yaw=ny;pitch=np;tracking=true;range=aiming?.22f:1;out=native;return true;}
  const float target=aiming?.22f:1;
  range+=limit(target-range,dt/ .12f);
  offset_yaw=limit(wrap(ny-yaw),5*PI/180*range);
  offset_pitch=limit(np-pitch,3*PI/180*range);
  yaw=wrap(ny-offset_yaw);pitch=np-offset_pitch;
  const Q roll=mul(inv(look(ny,np)),native);
  out=mul(look(yaw,pitch),roll);return valid(out);
 }
};
// Remove the prior camera-local orientation from its current world orientation.
// This recovers the actual animated parent without assuming a bone assignment.
inline bool matrix_q(const float* m,Q& q){
 float n[9]{};for(unsigned a=0;a<3;++a){float len=0;for(unsigned b=0;b<3;++b)len+=m[a*4+b]*m[a*4+b];if(!std::isfinite(len)||std::fabs(len-1)>.04f)return false;for(unsigned b=0;b<3;++b)n[a*3+b]=m[a*4+b];}
 for(unsigned a=0;a<3;++a)for(unsigned b=a+1;b<3;++b){float d=0;for(unsigned i=0;i<3;++i)d+=n[a*3+i]*n[b*3+i];if(std::fabs(d)>.02f)return false;}
 const float det=n[0]*(n[4]*n[8]-n[5]*n[7])-n[1]*(n[3]*n[8]-n[5]*n[6])+n[2]*(n[3]*n[7]-n[4]*n[6]);if(det<.95f)return false;
 const float trace=n[0]+n[4]+n[8];
 if(trace>0){float s=std::sqrt(trace+1)*2;q={(n[5]-n[7])/s,(n[6]-n[2])/s,(n[1]-n[3])/s,s/4};}
 else if(n[0]>n[4]&&n[0]>n[8]){float s=std::sqrt(1+n[0]-n[4]-n[8])*2;q={s/4,(n[3]+n[1])/s,(n[6]+n[2])/s,(n[5]-n[7])/s};}
 else if(n[4]>n[8]){float s=std::sqrt(1+n[4]-n[0]-n[8])*2;q={(n[3]+n[1])/s,s/4,(n[7]+n[5])/s,(n[6]-n[2])/s};}
 else{float s=std::sqrt(1+n[8]-n[0]-n[4])*2;q={(n[6]+n[2])/s,(n[7]+n[5])/s,s/4,(n[1]-n[3])/s};}
 return valid(q);
}
}
