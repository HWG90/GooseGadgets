#pragma once
#include "core.h"

namespace bc {
// prepare is read-only with respect to the game. reset reconstructs the current
// graph using its existing resource; restore does the same before bridge entry.
bool actor_prepare(Owner* owner, std::string& error);
bool actor_reset(Owner* owner, std::string& error);
// reset may return true while waiting for two stable equipped-weapon ticks.
// Only ready confirms that reconstruction and category/event refresh finished.
bool actor_ready(Owner* owner);
// No writes after actor retirement or a foreign graph replacement. Otherwise a
// failed restoration retains its journal and returns false for the next poll.
bool actor_restore(Owner* owner, std::string& error);
}
