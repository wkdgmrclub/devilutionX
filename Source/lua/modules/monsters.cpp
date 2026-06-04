#include "lua/modules/monsters.hpp"

#include <string>
#include <string_view>

#include <fmt/format.h>
#include <sol/sol.hpp>

#include "crawl.hpp"
#include "engine/lighting_defs.hpp"
#include "data/file.hpp"
#include "engine/point.hpp"
#include "engine/random.hpp"
#include "levels/gendung.h"
#include "levels/tile_properties.hpp"
#include "lighting.h"
#include "lua/metadoc.hpp"
#include "monster.h"
#include "msg.h"
#include "multi.h"
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

void InitPointUserType(sol::state_view &lua)
{
	sol::usertype<Point> pointType = lua.new_usertype<Point>(sol::no_constructor);
	pointType["x"] = &Point::x;
	pointType["y"] = &Point::y;
	pointType["new"] = [](int x, int y) -> Point { return { x, y }; };
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
	    "Monster's index in the Monsters array (readonly). Stable within a session; range 0..MaxMonsters-1.",
	    [](const Monster &monster) {
		    return static_cast<int>(&monster - &Monsters[0]);
	    });
	LuaSetDocReadonlyProperty(monsterType, "typeId", "integer",
	    "Monster type ID matching _monster_id constants (readonly)",
	    [](const Monster &monster) {
		    return static_cast<int>(monster.type().type);
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
	LuaSetDocReadonlyProperty(monsterType, "level", "integer",
	    "Monster's effective level at the current game difficulty (readonly)",
	    [](const Monster &monster) {
		    return static_cast<int>(monster.level(static_cast<_difficulty>(sgGameInitInfo.nDifficulty)));
	    });
	LuaSetDocFn(monsterType, "remove", "()",
	    "Silently remove this monster from the level without triggering death effects, loot, or XP.",
	    [](const Monster &constMonster) {
		    Monster &monster = const_cast<Monster &>(constMonster);
		    if (monster.lightId != NO_LIGHT) {
			    AddUnLight(monster.lightId);
			    monster.lightId = NO_LIGHT;
		    }
		    M_ClearSquares(monster);
		    dMonster[monster.position.tile.x][monster.position.tile.y] = 0;
		    monster.isInvalid = true;
		    // Remove from ActiveMonsters immediately so SaveLevel does not persist this monster.
		    // (DeleteMonsterList normally runs next tick, but that is after pfile_save_level.)
		    DeleteMonsterList();
	    });
	LuaSetDocFn(monsterType, "setHitPoints", "(hp: integer)",
	    "Set this monster's current hit points (pass display value; stored as fixed-point internally).",
	    [](const Monster &constMonster, int hp) {
		    Monster &monster = const_cast<Monster &>(constMonster);
		    monster.hitPoints = hp << 6;
	    });
	LuaSetDocFn(monsterType, "makeGolem", "()",
	    "Convert this monster to a golem (switches AI to GolumAi; use OnGolemCanTargetMonster and OnGolemCanSelect to customise behaviour)",
	    [](Monster &monster) {
		    ChangeMonsterToGolem(monster);
	    });
	LuaSetDocReadonlyProperty(monsterType, "isLit", "boolean",
	    "Whether the tile this monster stands on is currently illuminated by any light source (readonly)",
	    [](const Monster &monster) {
		    return dLight[monster.position.tile.x][monster.position.tile.y] < LightsMax;
	    });
	LuaSetDocReadonlyProperty(monsterType, "hasRangedAttack", "boolean",
	    "Whether this monster type has a ranged attack (based on original AI type; unchanged by taming). readonly",
	    [](const Monster &monster) -> bool {
		    const MonsterAIID ai = monster.data().ai;
		    return ai == MonsterAIID::SkeletonRanged
		        || ai == MonsterAIID::GoatRanged
		        || ai == MonsterAIID::Magma
		        || ai == MonsterAIID::Gargoyle
		        || ai == MonsterAIID::Succubus
		        || ai == MonsterAIID::Storm
		        || ai == MonsterAIID::Acid
		        || ai == MonsterAIID::AcidUnique
		        || ai == MonsterAIID::Diablo
		        || ai == MonsterAIID::LazarusSuccubus
		        || ai == MonsterAIID::FireBat
		        || ai == MonsterAIID::Torchant
		        || ai == MonsterAIID::Lich
		        || ai == MonsterAIID::ArchLich
		        || ai == MonsterAIID::Psychorb
		        || ai == MonsterAIID::Necromorb
		        || ai == MonsterAIID::BoneDemon;
	    });
	LuaSetDocFn(monsterType, "snapToPlayer", "(player: Player)",
	    "Instantly move this monster to the nearest free tile adjacent to the player.",
	    [](const Monster &constMonster, const Player &player) {
		    Monster &monster = const_cast<Monster &>(constMonster);
		    const Point targetPos = player.position.tile;
		    // Search outward from the player tile for the nearest unoccupied walkable tile.
		    // Multiple allies snapping in the same frame each get a unique tile because
		    // occupyTile updates dMonster before the next snap runs.
		    const auto freePos = Crawl(0, MaxCrawlRadius, [&](Displacement d) -> std::optional<Point> {
			    const Point candidate = targetPos + d;
			    if (dPlayer[candidate.x][candidate.y] != 0 || dMonster[candidate.x][candidate.y] != 0)
				    return {};
			    if (!IsTileWalkable(candidate))
				    return {};
			    return candidate;
		    });
		    if (!freePos) return;
		    const Point snapPos = *freePos;
		    // Explicitly zero dMonster at all three position fields before M_ClearSquares.
		    // M_ClearSquares only covers a 3x3 around position.old; a walking monster can
		    // have dMonster entries at position.future outside that radius, which would
		    // persist as stale ghost images. // Lua mod support
		    dMonster[monster.position.old.x][monster.position.old.y] = 0;
		    dMonster[monster.position.tile.x][monster.position.tile.y] = 0;
		    dMonster[monster.position.future.x][monster.position.future.y] = 0;
		    M_ClearSquares(monster);
		    monster.position.tile = snapPos;
		    monster.position.future = snapPos;
		    monster.position.old = snapPos;
		    // Reset to Stand so the engine does not process the interrupted walk step on
		    // the next tick, which would otherwise set a new dMonster entry at the old
		    // walk destination and create another ghost image. // Lua mod support
		    monster.mode = MonsterMode::Stand;
		    monster.changeAnimationData(MonsterGraphic::Stand);
		    monster.occupyTile(snapPos, false);
		    ChangeLightXY(monster.lightId, snapPos);
	    });
	LuaSetDocFn(monsterType, "distanceTo", "(player: Player) -> integer",
	    "Returns the Chebyshev tile distance between this monster and the given player.",
	    [](const Monster &monster, const Player &player) {
		    return monster.position.tile.WalkingDistance(player.position.tile);
	    });
}

} // namespace

sol::table LuaMonstersModule(sol::state_view &lua)
{
	InitPointUserType(lua);
	InitMonsterUserType(lua);
	sol::table table = lua.create_table();
	LuaSetDocFn(table, "addMonsterDataFromTsv", "(path: string)", AddMonsterDataFromTsv);
	LuaSetDocFn(table, "addUniqueMonsterDataFromTsv", "(path: string)", AddUniqueMonsterDataFromTsv);
	LuaSetDocFn(table, "getNameByTypeId", "(typeId: integer) -> string|nil",
	    "Get the base display name of a monster type by its numeric type ID. Returns nil if the type ID is out of range.",
	    [](int typeIdInt) -> sol::optional<std::string> {
		    if (typeIdInt < 0 || typeIdInt >= static_cast<int>(MonstersData.size()))
			    return sol::nullopt;
		    return MonstersData[typeIdInt].name;
	    });
	LuaSetDocFn(table, "spawnAt", "(typeId: integer, x: integer, y: integer) -> Monster|nil",
	    "Spawn a monster of the given type ID at the given tile. Returns the new Monster or nil on failure.",
	    [](int typeIdInt, int x, int y) -> Monster * {
		    const auto type = static_cast<_monster_id>(typeIdInt);

		    // Find existing level type index, or register the type for this level.
		    size_t typeIndex = LevelMonsterTypeCount;
		    for (size_t i = 0; i < LevelMonsterTypeCount; i++) {
			    if (LevelMonsterTypes[i].type == type) {
				    typeIndex = i;
				    break;
			    }
		    }
		    if (typeIndex == LevelMonsterTypeCount) {
			    auto result = AddMonsterType(type, PLACE_SCATTER);
			    if (!result) return nullptr;
			    typeIndex = *result;
			    // Load GFX for this type only. InitAllMonsterGFX() skips entire sprite
			    // groups when the first type sharing a sprite file is already loaded —
			    // which breaks spawning two types from the same family (e.g. two drake
			    // colors). Loading just the new type always works correctly. // Lua mod support
			    if (!InitMonsterGFX(LevelMonsterTypes[typeIndex])) return nullptr;
		    }

		    if (ActiveMonsterCount >= MaxMonsters) return nullptr;
		    if (!MyPlayer->isLevelOwnedByLocalClient()) return nullptr;

		    const Point requestedPos { x, y };
		    // InitializeSpawnedMonster asserts the given tile is free; find the nearest one.
		    const auto freePos = Crawl(0, MaxCrawlRadius, [&requestedPos](Displacement displacement) -> std::optional<Point> {
			    const Point candidate = requestedPos + displacement;
			    if (dPlayer[candidate.x][candidate.y] != 0 || dMonster[candidate.x][candidate.y] != 0)
				    return {};
			    if (!IsTileWalkable(candidate))
				    return {};
			    return candidate;
		    });
		    if (!freePos) return nullptr;
		    const Point spawnPos = *freePos;

		    const size_t monsterIndex = ActiveMonsters[ActiveMonsterCount];
		    ActiveMonsterCount++;
		    const uint32_t seed = GetLCGEngineState();
		    InitializeSpawnedMonster(spawnPos, Direction::South, typeIndex, monsterIndex, seed, 0, 0);
		    NetSendCmdSpawnMonster(spawnPos, Direction::South, static_cast<uint16_t>(typeIndex),
		        static_cast<uint16_t>(monsterIndex), seed, 0, 0);

		    return &Monsters[monsterIndex];
	    });
	return table;
}

} // namespace devilution
