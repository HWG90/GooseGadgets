#pragma once
#include <windows.h>
#include <cstdint>
#include <string>

// Private, bounded bridge experiment. This is not a persistent lifecycle owner.
namespace bc::weapon_ui_review {
struct Identity { uintptr_t game{},exe{};uint32_t pid{},avatar{};DWORD thread{}; };
struct Io { bool(*read)(uintptr_t,void*,size_t){};bool(*write)(uintptr_t,const void*,size_t){}; };
enum class Phase:uint32_t {None,Preflight,SiblingCalling,SiblingReturned,SiblingAttached,
    WheelCalling,WheelReturned,WheelAttached,RoleCalling,Active,Stopping,Stopped,Interrupted,RetiredPending};
struct Status {Phase phase{};bool owned{},active{},role8_owned{},stopped{},pending{},expired{};};
// caller_ready must be true only with Photo Mode/pose ownership absent and the
// user's bounded bridge-only experiment still authorized. Native checks also
// validate current scene, menus, sole local player, roots and actual player ID.
bool start(const Identity&,float seconds,bool caller_ready,std::string&,Io={});
bool tick(float,uint32_t pid,uint32_t avatar,bool caller_ready,std::string&);
bool stop(std::string&);
bool rearm(std::string&);
Status status();
}
extern "C" {
__declspec(dllexport) int BC_weapon_ui_start(uint32_t,uint32_t,float,uint32_t);
__declspec(dllexport) int BC_weapon_ui_tick(float,uint32_t,uint32_t,uint32_t);
__declspec(dllexport) int BC_weapon_ui_stop();
__declspec(dllexport) int BC_weapon_ui_rearm();
__declspec(dllexport) uint32_t BC_weapon_ui_phase();
__declspec(dllexport) uint32_t BC_weapon_ui_flags();
__declspec(dllexport) const char* BC_weapon_ui_error();
}
