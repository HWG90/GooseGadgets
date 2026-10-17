#pragma once
#include "core.h"

namespace bc::hud {
// prepare creates disabled hooks only. The core enables every prepared hook in
// one batch. start/stop are game-thread calls; tick never fabricates render args.
bool prepare(Owner* owner, std::string& error);
bool start(Owner* owner, std::string& error);
bool stop(Owner* owner, std::string& error);
bool tick(Owner* owner, float dt, std::string& error);
// Call only after core has disabled and removed the staged MinHook entries.
bool release(std::string& error);
}
