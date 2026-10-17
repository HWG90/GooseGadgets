#pragma once
#include "core.h"

namespace bc {
// Prepare a native branch hook; the core enables it only after every feature
// has staged successfully. No initializer or health-value write is performed.
bool health_prepare(Owner* owner, std::string& error);
// Retire this owner's health exception. Code/control storage remains resident.
void health_deactivate(Owner* owner);
}
