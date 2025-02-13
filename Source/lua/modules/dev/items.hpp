#pragma once
#ifdef _DEBUG
#include <sol/sol.hpp>
#include "items.h"

namespace devilution {

sol::table LuaDevItemsModule(sol::state_view &lua);
sol::table LuaItemsModule(sol::state_view &lua);
void Lua_OnOilGenerate(Item &item, int maxLvl);

} // namespace devilution
#endif // _DEBUG
