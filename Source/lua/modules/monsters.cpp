#include "lua/modules/monsters.hpp"

#include <optional>
#include <string>
#include <string_view>

#include <fmt/format.h>
#include <sol/sol.hpp>

#include "crawl.hpp"
#include "cursor.h"
#include "dead.h"
#include "diablo.h"
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
#include "utils/log.hpp"
#include "utils/str_split.hpp"

namespace devilution {

namespace {

struct MonsterPlacement {
	size_t typeIndex;
	size_t monsterIndex;
	Point spawnPos;
	uint32_t seed;
};

// Shared pre-spawn setup: crawl for a free tile, grab the next ActiveMonsters slot.
// Does NOT call InitializeSpawnedMonster — callers do that after setting difficulty.
std::optional<MonsterPlacement> PrepareSpawnSlot(size_t typeIndex, int x, int y)
{
	if (ActiveMonsterCount >= MaxMonsters) return std::nullopt;
	if (!MyPlayer->isLevelOwnedByLocalClient()) return std::nullopt;
	const Point requestedPos { x, y };
	const auto freePos = Crawl(0, MaxCrawlRadius, [&requestedPos](Displacement d) -> std::optional<Point> {
		const Point c = requestedPos + d;
		if (dPlayer[c.x][c.y] != 0 || dMonster[c.x][c.y] != 0) return {};
		if (!IsTileWalkable(c)) return {};
		return c;
	});
	if (!freePos) return std::nullopt;
	return MonsterPlacement { typeIndex, ActiveMonsters[ActiveMonsterCount], *freePos, GetLCGEngineState() };
}

// Shared type registration: find or register the monster type and load its GFX.
std::optional<size_t> EnsureMonsterType(_monster_id type, placeflag pflag)
{
	for (size_t i = 0; i < LevelMonsterTypeCount; i++) {
		if (LevelMonsterTypes[i].type == type) return i;
	}
	// AddMonsterType does not bounds-check the level type table; registering a new type
	// at capacity would index LevelMonsterTypes[MaxLvlMTypes] out of bounds. Fail
	// gracefully so the caller returns nil (and the mod refunds the scroll). // Lua mod support
	if (LevelMonsterTypeCount >= MaxLvlMTypes) return std::nullopt;
	auto result = AddMonsterType(type, pflag);
	if (!result) return std::nullopt;
	const size_t idx = *result;
	if (!InitMonsterGFX(LevelMonsterTypes[idx])) return std::nullopt;
	RegisterLateMonsterTypeCorpse(LevelMonsterTypes[idx]);
	return idx;
}

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
	LuaSetDocReadonlyProperty(monsterType, "uniqueType", "integer",
	    "Index into UniqueMonstersData (-1 if not a named unique monster). readonly",
	    [](const Monster &m) -> int {
		    if (m.uniqueType == UniqueMonsterType::None) return -1;
		    return static_cast<int>(m.uniqueType);
	    });
	LuaSetDocReadonlyProperty(monsterType, "isQuestMonster", "boolean",
	    "Whether this monster is quest-critical (named unique or Diablo). readonly",
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
	LuaSetDocReadonlyProperty(monsterType, "isGolem", "boolean",
	    "Whether this monster has the MFLAG_GOLEM flag set (Golem spell or player-controlled ally). readonly",
	    [](const Monster &monster) -> bool {
		    return (monster.flags & MFLAG_GOLEM) != 0;
	    });
	LuaSetDocReadonlyProperty(monsterType, "isHidden", "boolean",
	    "Whether this monster has the MFLAG_HIDDEN flag set (faded out / invisible, e.g. a cloaked Sneak monster). readonly // Lua mod support",
	    [](const Monster &monster) -> bool {
		    return (monster.flags & MFLAG_HIDDEN) != 0;
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
	LuaSetDocReadonlyProperty(monsterType, "originalAiId", "integer",
	    "The monster type's original AI ID as a MonsterAIID integer. Stable after taming (GolemAi overwrites monster.ai but not the type data). Use monsters.AIID constants. readonly // Lua mod support",
	    [](const Monster &monster) {
		    return static_cast<int>(monster.data().ai);
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
	LuaSetDocFn(monsterType, "startRangedAttack", "(missileId: integer)",
	    "Fire a ranged attack at the monster's current target using the given MissileID integer. Damage is drawn from the monster's natural min/max damage range. Use monsters.MissileID for missile ID constants.",
	    [](const Monster &constMonster, int missileIdInt) {
		    Monster &monster = const_cast<Monster &>(constMonster);
		    StartGolemRangedAttack(monster, static_cast<MissileID>(missileIdInt));
	    });
	LuaSetDocFn(monsterType, "startCharge", "() -> boolean",
	    "Fire a Rhino-missile charge at the current enemy target. Ally-safe via the monster's MFLAG_TARGETS_MONSTER flag (not the missile caster). Returns true if the charge started. // Lua mod support",
	    [](const Monster &constMonster) -> bool {
		    Monster &monster = const_cast<Monster &>(constMonster);
		    return StartGolemCharge(monster);
	    });
	LuaSetDocFn(monsterType, "startHeal", "()",
	    "Trigger the Gargoyle self-heal animation (reverses Special animation, enters Heal mode). // Lua mod support",
	    [](const Monster &constMonster) {
		    Monster &monster = const_cast<Monster &>(constMonster);
		    StartHeal(monster);
	    });
	LuaSetDocFn(monsterType, "startEating", "()",
	    "Trigger the Scavenger corpse-eating animation (enters SpecialMeleeAttack mode). GolumAi will not interrupt until the animation finishes. // Lua mod support",
	    [](const Monster &constMonster) {
		    Monster &monster = const_cast<Monster &>(constMonster);
		    StartEating(monster);
	    });
	LuaSetDocFn(monsterType, "startFadeout", "()",
	    "Trigger the Sneak fade-out animation (enters FadeOut mode; sets MFLAG_HIDDEN when the animation completes). Used to cloak a tamed stealth ally. // Lua mod support",
	    [](const Monster &constMonster) {
		    Monster &monster = const_cast<Monster &>(constMonster);
		    StartFadeout(monster, monster.direction, true);
	    });
	LuaSetDocFn(monsterType, "startFadein", "()",
	    "Trigger the Sneak fade-in animation (enters FadeIn mode; clears MFLAG_HIDDEN immediately). Used to materialise a tamed stealth ally. // Lua mod support",
	    [](const Monster &constMonster) {
		    Monster &monster = const_cast<Monster &>(constMonster);
		    StartFadein(monster, monster.direction, false);
	    });
	LuaSetDocFn(monsterType, "findNearbyCorpse", "() -> Point|nil",
	    "Search within 4 tiles for a corpse tile with line-of-sight. Returns the tile position or nil. // Lua mod support",
	    [](const Monster &monster) -> sol::optional<Point> {
		    const auto result = ScavengerFindCorpse(monster);
		    if (!result) return sol::nullopt;
		    return *result;
	    });
	LuaSetDocFn(monsterType, "walkToward", "(x: integer, y: integer) -> boolean",
	    "Walk one step toward the given tile using AiPlanPath (wall routing) with RandomWalk fallback. Returns true if a step was taken. // Lua mod support",
	    [](const Monster &constMonster, int x, int y) -> bool {
		    Monster &monster = const_cast<Monster &>(constMonster);
		    monster.enemyPosition = { static_cast<WorldTileCoord>(x), static_cast<WorldTileCoord>(y) };
		    if (AiPlanPath(monster)) return true;
		    const WorldTilePosition dest { static_cast<WorldTileCoord>(x), static_cast<WorldTileCoord>(y) };
		    return Walk(monster, GetDirection(monster.position.tile, dest));
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
	LuaSetDocFn(table, "getTypeKillCount", "(typeId: integer) -> integer",
	    "Returns the total number of monsters of this type the player has killed (MonsterKillCounts).",
	    [](int typeId) -> int {
		    if (typeId < 0 || typeId >= static_cast<int>(NUM_MAX_MTYPES))
			    return 0;
		    return MonsterKillCounts[typeId];
	    });
	LuaSetDocFn(table, "getTypeHpRange", "(typeId: integer) -> integer, integer",
	    "Returns the difficulty-scaled HP range (minHp, maxHp) for this monster type, matching the PrintMonstHistory thresholds.",
	    [](int typeId) -> std::tuple<int, int> {
		    if (typeId < 0 || typeId >= static_cast<int>(MonstersData.size()))
			    return { 0, 0 };
		    int minHP = MonstersData[typeId].hitPointsMinimum;
		    int maxHP = MonstersData[typeId].hitPointsMaximum;
		    if (!gbIsMultiplayer) {
			    minHP /= 2;
			    maxHP /= 2;
		    }
		    minHP = std::max(minHP, 1);
		    maxHP = std::max(maxHP, 1);
		    int hpBonusNightmare = 100;
		    int hpBonusHell = 200;
		    if (gbIsHellfire) {
			    hpBonusNightmare = (!gbIsMultiplayer ? 50 : 100);
			    hpBonusHell = (!gbIsMultiplayer ? 100 : 200);
		    }
		    if (sgGameInitInfo.nDifficulty == DIFF_NIGHTMARE) {
			    minHP = 3 * minHP + hpBonusNightmare;
			    maxHP = 3 * maxHP + hpBonusNightmare;
		    } else if (sgGameInitInfo.nDifficulty == DIFF_HELL) {
			    minHP = 4 * minHP + hpBonusHell;
			    maxHP = 4 * maxHP + hpBonusHell;
		    }
		    return { minHP, maxHP };
	    });
	LuaSetDocFn(table, "getTypeResistances", "(typeId: integer) -> table",
	    "Returns a table of resistance/immunity booleans for the type at current difficulty: resistMagic, resistFire, resistLightning, immuneMagic, immuneFire, immuneLightning.",
	    [&lua](int typeId) -> sol::table {
		    sol::table t = lua.create_table();
		    if (typeId < 0 || typeId >= static_cast<int>(MonstersData.size()))
			    return t;
		    const int res = (sgGameInitInfo.nDifficulty != DIFF_HELL)
		        ? MonstersData[typeId].resistance
		        : MonstersData[typeId].resistanceHell;
		    t["resistMagic"]     = (res & RESIST_MAGIC) != 0;
		    t["resistFire"]      = (res & RESIST_FIRE) != 0;
		    t["resistLightning"] = (res & RESIST_LIGHTNING) != 0;
		    t["immuneMagic"]     = (res & IMMUNE_MAGIC) != 0;
		    t["immuneFire"]      = (res & IMMUNE_FIRE) != 0;
		    t["immuneLightning"] = (res & IMMUNE_LIGHTNING) != 0;
		    return t;
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
			    RegisterLateMonsterTypeCorpse(LevelMonsterTypes[typeIndex]);
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
	LuaSetDocFn(table, "currentDifficulty", "() -> integer",
	    "Returns the current game difficulty: 0=Normal, 1=Nightmare, 2=Hell.",
	    []() -> int {
		    return static_cast<int>(sgGameInitInfo.nDifficulty);
	    });
	LuaSetDocFn(table, "getUniqueName", "(uniqueTypeIdx: integer) -> string|nil",
	    "Returns the display name of a unique monster by its UniqueMonstersData index. Returns nil if out of range.",
	    [](int idx) -> sol::optional<std::string> {
		    if (idx < 0 || idx >= static_cast<int>(UniqueMonstersData.size())) return sol::nullopt;
		    return UniqueMonstersData[static_cast<size_t>(idx)].mName;
	    });
	LuaSetDocFn(table, "spawnWithDifficulty", "(typeId: integer, capturedDifficulty: integer, x: integer, y: integer) -> Monster|nil",
	    "Spawn a monster using captured-difficulty stat scaling. Temporarily overrides nDifficulty for InitializeSpawnedMonster. // Lua mod support",
	    [](int typeIdInt, int capturedDifficulty, int x, int y) -> Monster * {
		    const auto type = static_cast<_monster_id>(typeIdInt);
		    const auto typeIndex = EnsureMonsterType(type, PLACE_SCATTER);
		    if (!typeIndex) return nullptr;
		    const auto placement = PrepareSpawnSlot(*typeIndex, x, y);
		    if (!placement) return nullptr;
		    ActiveMonsterCount++;
		    const _difficulty savedDiff = sgGameInitInfo.nDifficulty;
		    sgGameInitInfo.nDifficulty = static_cast<_difficulty>(capturedDifficulty);
		    InitializeSpawnedMonster(placement->spawnPos, Direction::South, placement->typeIndex, placement->monsterIndex, placement->seed, 0, 0);
		    sgGameInitInfo.nDifficulty = savedDiff;
		    NetSendCmdSpawnMonster(placement->spawnPos, Direction::South, static_cast<uint16_t>(placement->typeIndex),
		        static_cast<uint16_t>(placement->monsterIndex), placement->seed, 0, 0);
		    return &Monsters[placement->monsterIndex];
	    });
	LuaSetDocFn(table, "spawnUniqueAt", "(uniqueTypeIdx: integer, capturedDifficulty: integer, x: integer, y: integer) -> Monster|nil",
	    "Spawn a named unique monster with captured-difficulty stat scaling. No minion pack. // Lua mod support",
	    [](int uniqueTypeIdx, int capturedDifficulty, int x, int y) -> Monster * {
		    if (uniqueTypeIdx < 0 || uniqueTypeIdx >= static_cast<int>(UniqueMonstersData.size())) return nullptr;
		    const UniqueMonsterType uniqueType = static_cast<UniqueMonsterType>(uniqueTypeIdx);
		    const _monster_id baseType = UniqueMonstersData[static_cast<size_t>(uniqueTypeIdx)].mtype;
		    const auto typeIndex = EnsureMonsterType(baseType, PLACE_UNIQUE);
		    if (!typeIndex) return nullptr;
		    const auto placement = PrepareSpawnSlot(*typeIndex, x, y);
		    if (!placement) return nullptr;
		    ActiveMonsterCount++;
		    const _difficulty savedDiff = sgGameInitInfo.nDifficulty;
		    sgGameInitInfo.nDifficulty = static_cast<_difficulty>(capturedDifficulty);
		    InitializeSpawnedMonster(placement->spawnPos, Direction::South, placement->typeIndex, placement->monsterIndex, placement->seed, 0, 0);
		    if (const auto result = PrepareUniqueMonst(Monsters[placement->monsterIndex], uniqueType, 0, 0, UniqueMonstersData[static_cast<size_t>(uniqueTypeIdx)]); !result) {
			    LogError("spawnUniqueAt: PrepareUniqueMonst failed for unique type {}: {}", uniqueTypeIdx, result.error());
			    sgGameInitInfo.nDifficulty = savedDiff;
			    Monster &m = Monsters[placement->monsterIndex];
			    if (m.lightId != NO_LIGHT) { AddUnLight(m.lightId); m.lightId = NO_LIGHT; }
			    M_ClearSquares(m);
			    dMonster[m.position.tile.x][m.position.tile.y] = 0;
			    m.isInvalid = true;
			    DeleteMonsterList();
			    return nullptr;
		    }
		    sgGameInitInfo.nDifficulty = savedDiff;
		    NetSendCmdSpawnMonster(placement->spawnPos, Direction::South, static_cast<uint16_t>(placement->typeIndex),
		        static_cast<uint16_t>(placement->monsterIndex), placement->seed, 0, 0);
		    return &Monsters[placement->monsterIndex];
	    });
	LuaSetDocFn(table, "getHovered", "() -> Monster|nil",
	    "Returns the monster currently under the player's cursor (pcursmonst), or nil if no monster is hovered.",
	    []() -> Monster * {
		    if (pcursmonst < 0 || pcursmonst >= static_cast<int>(MaxMonsters)) return nullptr;
		    return &Monsters[pcursmonst];
	    });
	// Lua mod support: missile ID constants for use with monster:startRangedAttack()
	{
		sol::table missileIdTable = lua.create_table();
		missileIdTable["Arrow"]          = static_cast<int>(MissileID::Arrow);
		missileIdTable["Firebolt"]       = static_cast<int>(MissileID::Firebolt);
		missileIdTable["LightningArrow"] = static_cast<int>(MissileID::LightningArrow);
		missileIdTable["FireArrow"]      = static_cast<int>(MissileID::FireArrow);
		missileIdTable["ChargedBolt"]    = static_cast<int>(MissileID::ChargedBolt);
		missileIdTable["HolyBolt"]       = static_cast<int>(MissileID::HolyBolt);
		missileIdTable["Fireball"]       = static_cast<int>(MissileID::Fireball);
		table["MissileID"] = missileIdTable;
	}
	// Lua mod support: MonsterAIID constants for use with monster.originalAiId
	{
		sol::table aiIdTable = lua.create_table();
		aiIdTable["Sneak"]        = static_cast<int>(MonsterAIID::Sneak);
		aiIdTable["Scavenger"]    = static_cast<int>(MonsterAIID::Scavenger);
		aiIdTable["Rhino"]        = static_cast<int>(MonsterAIID::Rhino);
		aiIdTable["Gargoyle"]     = static_cast<int>(MonsterAIID::Gargoyle);
		aiIdTable["Bat"]          = static_cast<int>(MonsterAIID::Bat);
		aiIdTable["Snake"]        = static_cast<int>(MonsterAIID::Snake);
		aiIdTable["SkeletonKing"] = static_cast<int>(MonsterAIID::SkeletonKing);
		aiIdTable["HorkDemon"]    = static_cast<int>(MonsterAIID::HorkDemon);
		aiIdTable["GoatMelee"]    = static_cast<int>(MonsterAIID::GoatMelee);
		table["AIID"] = aiIdTable;
	}
	return table;
}

} // namespace devilution
