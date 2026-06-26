#include "lua/modules/spells.hpp"

#include <string_view>
#include <type_traits>

#include <sol/sol.hpp>

#include "data/file.hpp"
#include "lua/metadoc.hpp"
#include "panels/spell_icons.hpp"
#include "tables/spelldat.h"

namespace devilution {

sol::table LuaSpellsModule(sol::state_view &lua)
{
	sol::table table = lua.create_table();
	LuaSetDocFn(table, "registerSpell", "(name: string, path: string, iconName?: string)",
	    "Queue a dynamic spell for registration, loading its data from a TSV file. Call inside a SpellDataLoaded handler. IDs are assigned deterministically (sorted by name, from a fixed base) after every mod has registered, so the same name resolves to the same ID across game modes and load order; read the assigned ID with getSpellId(name) in a SpellsAssigned handler. Optional iconName sets the speedbook icon (e.g. \"Golem\").",
	    [](std::string_view name, std::string_view path, sol::optional<std::string_view> iconName) {
		    LuaQueueDynamicSpell(name, path, iconName.value_or(std::string_view {}));
	    });
	LuaSetDocFn(table, "getSpellId", "(name: string)",
	    "Return the runtime SpellID integer assigned to a dynamic spell name, or nil if not registered. Valid from the SpellsAssigned event onward.",
	    [](std::string_view name) -> sol::optional<int> {
		    auto id = ParseSpellId(name);
		    if (id.has_value() && *id != SpellID::Null)
			    return static_cast<int>(*id);
		    return sol::nullopt;
	    });
	LuaSetDocFn(table, "setSpellIcon", "(spellId: integer, iconName: string)",
	    "Set the speedbook icon for a dynamic spell by ID (e.g. \"Golem\"). Call after the spell has been assigned (e.g. in a SpellsAssigned handler).",
	    [](int spellId, std::string_view iconName) {
		    LuaRegisterDynamicSpellIcon(spellId, LuaParseSpellIconName(iconName));
	    });
	return table;
}

} // namespace devilution
