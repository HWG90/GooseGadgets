#pragma once
#include "core.h"

namespace bc {
bool mode_prepare(Owner* owner, std::string& error);
bool mode_enter(Owner* owner, std::string& error);
bool mode_restore(Owner* owner, std::string& error);
bool mode_tick(Owner* owner, std::string& error);
// Scene 4 alone is not operational readiness. AD4520 completion is not called
// or simulated here; phase+14 must clear through a reviewed engine lifecycle.
bool mode_ready(const Owner* owner);
// Pointer reuse across real mission/ship loads is distinguished by the
// retained level runtime kind and definition, not just ECS World/GS pointers.
bool mode_retired(const Owner* owner);
}
