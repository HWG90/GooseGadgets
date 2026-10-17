#include "core.h"
namespace bc {
bool fingerprint(uintptr_t, const char*) { return false; }
bool stage_hook(uintptr_t, void*, void**, const char*, std::string& error) {
    error = "Offline fixture never stages hooks"; return false;
}
}
