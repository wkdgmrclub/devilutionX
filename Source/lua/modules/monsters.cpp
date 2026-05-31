#include "lua/modules/monsters.hpp"

#include <string>
#include <string_view>

#include <fmt/format.h>
#include <sol/sol.hpp>

#include "data/file.hpp"
#include "engine/point.hpp"
#include "lua/metadoc.hpp"
#include "monster.h"
#include "player.h"
#include "tables/monstdat.h"
#include "utils/language.h"
#include "utils/str_split.hpp"

namespace devilution {

namespace {

void AddMonsterDataFromTsv(const std::string_view path)
{
	DataFile dataFile = DataFile::loadOrDie(path);
	LoadMonstDatFromFile(dataFile, path, true);
}

void AddUniqueMonsterDataFromTsv(const std::string_view path)
{
	DataFile dataFile = DataFile::loadOrDie(path);
	LoadUniqueMonstDatFromFile(dataFile, path);
}

void InitMonsterUserType(sol::state_view &lua)
{
	sol::usertype<Monster> monsterType = lua.new_usertype<Monster>(sol::no_constructor);
	LuaSetDocReadonlyProperty(monsterType, "position", "Point",
	    "Monster's current position (readonly)",
	    [](const Monster &monster) {
		    return Point { monster.position.tile };
	    });
	LuaSetDocReadonlyProperty(monsterType, "id", "integer",
	    "Monster's unique ID (readonly)",
	    [](const Monster &monster) {
		    return static_cast<int>(reinterpret_cast<uintptr_t>(&monster));
	    });
	LuaSetDocReadonlyProperty(monsterType, "name", "string",
	    "Monster's display name (readonly)",
	    [](const Monster &monster) -> std::string {
		    return std::string(monster.name());
	    });
	LuaSetDocReadonlyProperty(monsterType, "health", "integer",
	    "Monster's current hit points (readonly)",
	    [](const Monster &monster) {
		    return monster.hitPoints >> 6;
	    });
	LuaSetDocReadonlyProperty(monsterType, "maxHealth", "integer",
	    "Monster's maximum hit points (readonly)",
	    [](const Monster &monster) {
		    return monster.maxHitPoints >> 6;
	    });
	LuaSetDocReadonlyProperty(monsterType, "isUnique", "boolean",
	    "Whether this is a named unique monster (readonly)",
	    [](const Monster &monster) {
		    return monster.isUnique();
	    });
	LuaSetDocReadonlyProperty(monsterType, "isQuestMonster", "boolean",
	    "Whether this monster is quest-critical and should not be tameable or skippable (readonly)",
	    [](const Monster &monster) {
		    return monster.isUnique() || monster.type().type == MT_DIABLO;
	    });
	LuaSetDocFn(monsterType, "makeAlly", "(player: Player)",
	    "Make this monster fight as an ally for the given player (uses the same mechanism as Golem)",
	    [](Monster &monster, const Player &player) {
		    MakeMonsterAlly(monster, player);
	    });
}

} // namespace

sol::table LuaMonstersModule(sol::state_view &lua)
{
	InitMonsterUserType(lua);
	sol::table table = lua.create_table();
	LuaSetDocFn(table, "addMonsterDataFromTsv", "(path: string)", AddMonsterDataFromTsv);
	LuaSetDocFn(table, "addUniqueMonsterDataFromTsv", "(path: string)", AddUniqueMonsterDataFromTsv);
	return table;
}

} // namespace devilution
