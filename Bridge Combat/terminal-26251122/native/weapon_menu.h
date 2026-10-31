#pragma once
#include <windows.h>
#include <cstdint>
#include <string>

// Persistent bridge owner. The caller owns package readiness and stops before
// restoring bridge controls. Native lifecycle acknowledgement is independent.
namespace bc::weapon_menu {
struct Identity { uintptr_t game{},exe{};uint32_t pid{},avatar{};DWORD thread{}; };
struct Io { bool(*read)(uintptr_t,void*,size_t){};bool(*write)(uintptr_t,const void*,size_t){}; };
enum class Phase:uint32_t {None,Preflight,SiblingCalling,SiblingReturned,SiblingAttached,
    WheelCalling,WheelReturned,WheelAttached,RoleCalling,Active,Stopping,Stopped,Interrupted,RetiredPending};
struct Status {Phase phase{};bool owned{},active{},role8_owned{},stopped{},pending{},retired{};};
bool acquire(const Identity&,bool caller_ready,std::string&,Io={});
bool tick(float,uint32_t pid,uint32_t avatar,bool caller_ready,std::string&);
bool stop(std::string&);
Status status();
}
#ifndef BC_WEAPON_MENU_INTERNAL_ONLY
extern "C" {
__declspec(dllexport) int BC_weapon_menu_acquire(uint32_t,uint32_t);
__declspec(dllexport) int BC_weapon_menu_tick(float,uint32_t,uint32_t);
__declspec(dllexport) int BC_weapon_menu_stop();
__declspec(dllexport) uint32_t BC_weapon_menu_phase();
__declspec(dllexport) uint32_t BC_weapon_menu_flags();
__declspec(dllexport) const char* BC_weapon_menu_error();
}
#endif
