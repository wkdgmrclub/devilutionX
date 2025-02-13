#include "lua/modules/items.hpp"

#include "items.h"

namespace devilution {

// Store Lua state globally as a state_view
namespace {
sol::state_view *LuaState = nullptr;
}

// Define Lua hook for oil generation
void Lua_OnOilGenerate(Item &item, int maxLvl)
{
	if (LuaState == nullptr)
		return; // Ensure Lua is initialized before calling

	sol::optional<sol::function> callback = (*LuaState)["devilutionx"]["items"]["OnOilGenerate"];

	if (callback) {
		callback.value()(item, maxLvl);
	}
}

sol::table LuaItemsModule(sol::state_view &lua)
{
	static sol::state_view luaStateView = lua; // Store the state globally
	LuaState = &luaStateView;                  // Assign the reference

	sol::table table = lua.create_table();

	// Hook for modifying oil drops
	table.set_function("generateOil", &Lua_OnOilGenerate);

	// Expose dwBuff flag manipulation to Lua
	table.set_function("setItemFlag", [](Item &item, uint32_t flag) { item.dwBuff |= flag; });
	table.set_function("clearItemFlag", [](Item &item, uint32_t flag) { item.dwBuff &= ~flag; });
	table.set_function("hasItemFlag", [](Item &item, uint32_t flag) -> bool { return (item.dwBuff & flag) != 0; });

	lua["devilutionx"]["items"] = table;
	return table;
}

} // namespace devilution
