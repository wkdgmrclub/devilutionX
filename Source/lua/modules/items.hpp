#pragma once

#include "items.h"
#include <sol/sol.hpp>

namespace devilution {

// Declare Lua hook so items.cpp can use it
void Lua_OnOilGenerate(Item &item, int maxLvl);

sol::table LuaItemsModule(sol::state_view &lua);

} // namespace devilution
