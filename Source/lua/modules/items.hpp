#pragma once

#include "items.h"

namespace devilution {

// Declare Lua hook so items.cpp can use it
void Lua_OnOilGenerate(Item &item, int maxLvl);

sol::table LuaItemsModule(sol::state_view &lua);

} // namespace devilution
