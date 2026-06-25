#include "lua/modules/spells.hpp"

#include <string_view>
#include <type_traits>

#include <sol/sol.hpp>

#include "data/file.hpp"
#include "lua/metadoc.hpp"
#include "panels/spell_icons.hpp"
#include "tables/spelldat.h"

namespace devilution {

namespace {

int AddSpellDataFromTsv(std::string_view name, std::string_view path, sol::optional<std::string_view> iconName)
{
	const auto newId = static_cast<std::underlying_type_t<SpellID>>(SpellsData.size());
	DataFile dataFile = DataFile::loadOrDie(path);
	LoadSpellDatFromFile(dataFile, path);
	LuaRegisterDynamicSpellId(name, static_cast<SpellID>(newId));
	if (iconName.has_value() && !iconName->empty()) {
		LuaRegisterDynamicSpellIcon(static_cast<int>(newId), LuaParseSpellIconName(*iconName));
	}
	return static_cast<int>(newId);
}

} // namespace

sol::table LuaSpellsModule(sol::state_view &lua)
{
	sol::table table = lua.create_table();
	LuaSetDocFn(table, "addSpellDataFromTsv", "(name: string, path: string, iconName?: string)",
	    "Register a new spell by name and load its data from a TSV file. Call this inside a SpellDataLoaded handler. Optional iconName sets the speedbook icon (e.g. \"Golem\").",
	    AddSpellDataFromTsv);
	LuaSetDocFn(table, "setSpellIcon", "(spellId: integer, iconName: string)",
	    "Set the speedbook icon for a dynamic spell by name (e.g. \"Golem\"). Call after addSpellDataFromTsv.",
	    [](int spellId, std::string_view iconName) {
		    LuaRegisterDynamicSpellIcon(spellId, LuaParseSpellIconName(iconName));
	    });
	return table;
}

} // namespace devilution
