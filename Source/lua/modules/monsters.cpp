#include "lua/modules/monsters.hpp"

#include <algorithm>
#include <array>
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
#include "lua/lua_event.hpp"
#include "lua/metadoc.hpp"
#include "missiles.h"
#include "monster.h"
#include "msg.h"
#include "multi.h"
#include "player.h"
#include "quests.h"
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

// Seed for InitializeSpawnedMonster, derived from the monster's (stable, cross-client) slot id.
//
// A networked mod spawn is recreated at the SAME slot id on every client (the owner spawns locally and
// peers recreate it at that id via monsters.netSpawnAt). InitializeSpawnedMonster does SetRndSeed(seed)
// and InitMonster then makes a few RNG draws (e.g. the starting animation frame). Seeding from the slot
// id makes those draws identical on every client, so a recreated monster starts on the same frame
// regardless of which client spawned it or when. Seeding from the local RNG state instead
// (GetLCGEngineState) gives each client a different starting frame — purely cosmetic, but free to avoid.
//
// NOTE: this does NOT drive the per-monster AI sync. In multiplayer the engine re-bases every monster's
// aiSeed each game tick from the synced lockstep tick counter + slot id (MonsterSeeds, multi.cpp), so
// aiSeed is already identical across clients every tick and overwrites whatever was set here. AI
// determinism therefore depends on the slot id matching (it does) and on the mod's own AI consuming RNG
// / making cached decisions symmetrically across clients — not on this initial seed.
uint32_t SyncSpawnSeed(size_t monsterId)
{
	return static_cast<uint32_t>(monsterId);
}

// Allocate a free slot at or above MaxMonsters. Natural placement is capped below MaxMonsters, so
// slots here are never used by level generation and stay collision-free across clients. Needs
// headroom from RequestExtraMonsters(); nullopt when exhausted. Free pool is ActiveMonsters at
// index >= ActiveMonsterCount.
std::optional<size_t> AllocateHighMonsterSlot()
{
	for (size_t i = ActiveMonsterCount; i < GetMaxMonsters(); i++) {
		if (ActiveMonsters[i] >= MaxMonsters)
			return ActiveMonsters[i];
	}
	return std::nullopt;
}

// Shared pre-spawn setup: crawl for a free tile, allocate a slot. Does NOT call
// InitializeSpawnedMonster — callers do that (it activates the slot) after setting difficulty.
std::optional<MonsterPlacement> PrepareSpawnSlot(size_t typeIndex, int x, int y)
{
	if (ActiveMonsterCount >= GetMaxMonsters()) return std::nullopt; // Lua mod support
	if (!MyPlayer->isLevelOwnedByLocalClient()) return std::nullopt;
	const Point requestedPos { x, y };
	const auto freePos = Crawl(0, MaxCrawlRadius, [&requestedPos](Displacement d) -> std::optional<Point> {
		const Point c = requestedPos + d;
		if (dPlayer[c.x][c.y] != 0 || dMonster[c.x][c.y] != 0) return {};
		if (!IsTileWalkable(c)) return {};
		return c;
	});
	if (!freePos) return std::nullopt;
	const auto monsterIndex = AllocateHighMonsterSlot();
	if (!monsterIndex) return std::nullopt;
	return MonsterPlacement { typeIndex, *monsterIndex, *freePos, SyncSpawnSeed(*monsterIndex) };
}

// Shared type registration: find or register the monster type and load its GFX.
std::optional<size_t> EnsureMonsterType(_monster_id type, placeflag pflag)
{
	for (size_t i = 0; i < LevelMonsterTypeCount; i++) {
		if (LevelMonsterTypes[i].type == type) return i;
	}
	// AddMonsterType does not bounds-check the level type table; registering a new type
	// at capacity would index LevelMonsterTypes out of bounds. Fail gracefully so the
	// caller returns nil (and the mod refunds the scroll). GetMaxLvlMTypes() includes any
	// mod-requested extension, so mods that reserved extra slots get the headroom. // Lua mod support
	if (LevelMonsterTypeCount >= GetMaxLvlMTypes()) return std::nullopt;
	auto result = AddMonsterType(type, pflag);
	if (!result) return std::nullopt;
	const size_t idx = *result;
	if (!InitMonsterGFX(LevelMonsterTypes[idx])) return std::nullopt;
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

// Shared silent removal of a monster from the live level (no death effects, loot, or XP). The only
// difference between callers is how the multiplayer delta records the removal, selected by markKilled:
//   false — invalidate the delta slot (LuaDeltaRemoveSpawnedMonster). Correct for a monster that does
//           NOT exist in the deterministic level generation (a dynamically spawned monster): a client
//           loading the level later simply skips the slot, never recreating it.
//   true  — record it as killed (delta_kill_monster: hit points 0 at a valid tile). Correct for a
//           level-natural (generation-placed) monster: a client loading the level later regenerates the
//           monster from the level seed, so the delta must reap that copy — otherwise it survives as a
//           live ghost. It also frees the monster's slot id on that client so it can be reused.
// Capture the tile before the cleanup zeroes the position fields, so the killed-delta record is valid.
void RemoveMonsterFromLevel(Monster &monster, bool markKilled)
{
	const Point tile { monster.position.tile };
	// Zero hit points so an in-flight position sync (SyncMonster, keyed by slot index) skips this slot
	// instead of re-occupying it after removal. delta_kill_monster sets the delta's hit points to 0
	// explicitly, so this does not change what is persisted.
	monster.hitPoints = 0;
	if (monster.lightId != NO_LIGHT) {
		AddUnLight(monster.lightId);
		monster.lightId = NO_LIGHT;
	}
	// Explicitly zero dMonster at all three position fields before M_ClearSquares.
	// M_ClearSquares only covers a 3x3 around position.old; a monster removed mid-walk can
	// have a dMonster reservation at position.future (or position.old) outside that radius,
	// which would otherwise survive as a stale entry pointing at this now-invalid slot — a
	// ghost (a clickable/killable copy, and a frozen rendered body) on the removing client.
	dMonster[monster.position.old.x][monster.position.old.y] = 0;
	dMonster[monster.position.tile.x][monster.position.tile.y] = 0;
	dMonster[monster.position.future.x][monster.position.future.y] = 0;
	M_ClearSquares(monster);
	monster.isInvalid = true;
	// Update the multiplayer delta so the removal survives a level reload / late join. No-op in
	// singleplayer. (Singleplayer persistence is handled by the DeleteMonsterList compaction below,
	// before SaveLevel.)
	if (markKilled)
		delta_kill_monster(monster, tile, *MyPlayer);
	else
		LuaDeltaRemoveSpawnedMonster(monster);
	// DeleteMonsterList() compacts ActiveMonsters and decrements ActiveMonsterCount. Doing
	// that here while a game-logic step is in flight — e.g. this runs from an OnMonsterDeath
	// handler despawning a dead monster's minions while ProcessMonsters / ProcessMissiles is
	// still iterating ActiveMonsters by index — mutates the array the engine is mid-iteration
	// over, leaving a stale slot / out-of-range monster id that the renderer then dereferences
	// (the DrawDungeon `mid < GetMaxMonsters()` and null-sprite asserts). Mirror the engine's own
	// MonsterDeath: during a tick, only flag the monster invalid and park it in the golem holding
	// cell so its AI cannot re-occupy a tile before it is reaped; the engine's DeleteMonsterList
	// (top & bottom of ProcessMonsters) then compacts it safely next tick.
	if (gGameLogicStep == GameLogicStep::None) {
		// Outside the game-logic tick (level-exit recall, or any removal requested while no
		// step is in flight): compact immediately so SaveLevel does not persist this monster
		// (DeleteMonsterList would otherwise not run until next tick, after pfile_save_level).
		DeleteMonsterList();
	} else {
		monster.position.tile = GolemHoldingCell;
		monster.position.future = GolemHoldingCell;
		monster.position.old = GolemHoldingCell;
	}
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
	    "Monster's index in the Monsters array (readonly). Stable within a session; range 0..GetMaxMonsters()-1.",
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
	    "Silently remove this monster from the level without triggering death effects, loot, or XP. For a "
	    "dynamically spawned monster (one not present in the deterministic level generation): the multiplayer "
	    "delta slot is invalidated so a client loading the level later does not recreate it. To remove a "
	    "level-natural monster, use removeAsKilled (see below) so a late-loading client reaps its regenerated "
	    "copy instead of leaving a ghost. // Lua mod support",
	    [](const Monster &constMonster) {
		    RemoveMonsterFromLevel(const_cast<Monster &>(constMonster), false);
	    });
	LuaSetDocFn(monsterType, "removeAsKilled", "()",
	    "Silently remove this monster from the level (no death effects, loot, or XP) AND record it as killed "
	    "in the multiplayer delta (hit points 0 at its tile). Use this — not remove — for a level-natural "
	    "(generation-placed) monster: a client loading the level later regenerates it from the level seed, so "
	    "the delta must reap that copy; otherwise the monster survives there as a live ghost (and its slot id "
	    "stays occupied, which can collide with ids reused for dynamically spawned monsters). No-op delta in "
	    "singleplayer. // Lua mod support",
	    [](const Monster &constMonster) {
		    RemoveMonsterFromLevel(const_cast<Monster &>(constMonster), true);
	    });
	LuaSetDocFn(monsterType, "setHitPoints", "(hp: integer)",
	    "Set this monster's current hit points (pass display value; stored as fixed-point internally).",
	    [](const Monster &constMonster, int hp) {
		    Monster &monster = const_cast<Monster &>(constMonster);
		    monster.hitPoints = hp << 6;
	    });
	LuaSetDocFn(monsterType, "setMaxHitPoints", "(hp: integer)",
	    "Set this monster's maximum hit points (pass display value; stored as fixed-point internally). Use to restore a persisted max HP instead of the value re-rolled from the type's range at spawn. // Lua mod support",
	    [](const Monster &constMonster, int hp) {
		    Monster &monster = const_cast<Monster &>(constMonster);
		    monster.maxHitPoints = hp << 6;
	    });
	LuaSetDocReadonlyProperty(monsterType, "minDamage", "integer",
	    "Monster's current minimum melee damage (readonly). // Lua mod support",
	    [](const Monster &monster) -> int {
		    return monster.minDamage;
	    });
	LuaSetDocReadonlyProperty(monsterType, "maxDamage", "integer",
	    "Monster's current maximum melee damage (readonly). // Lua mod support",
	    [](const Monster &monster) -> int {
		    return monster.maxDamage;
	    });
	LuaSetDocReadonlyProperty(monsterType, "armorClass", "integer",
	    "Monster's current armor class (readonly). // Lua mod support",
	    [](const Monster &monster) -> int {
		    return monster.armorClass;
	    });
	LuaSetDocReadonlyProperty(monsterType, "toHit", "integer",
	    "Monster's effective chance-to-hit at the current difficulty (readonly). For a golem/player-minion this is the golemToHit value set when it became a golem. // Lua mod support",
	    [](const Monster &monster) -> int {
		    return static_cast<int>(monster.toHit(static_cast<_difficulty>(sgGameInitInfo.nDifficulty)));
	    });
	LuaSetDocReadonlyProperty(monsterType, "resistance", "integer",
	    "Monster's raw resistance/immunity bitfield (readonly). Test against monsters.Resistance.* flags. // Lua mod support",
	    [](const Monster &monster) -> int {
		    return monster.resistance;
	    });
	LuaSetDocFn(monsterType, "setMinDamage", "(value: integer)",
	    "Set this monster's minimum melee damage (clamped to 0..255). Generic; used to apply transient stat buffs. // Lua mod support",
	    [](const Monster &constMonster, int value) {
		    Monster &monster = const_cast<Monster &>(constMonster);
		    monster.minDamage = static_cast<uint8_t>(std::clamp(value, 0, 255));
	    });
	LuaSetDocFn(monsterType, "setMaxDamage", "(value: integer)",
	    "Set this monster's maximum melee damage (clamped to 0..255). Generic; used to apply transient stat buffs. // Lua mod support",
	    [](const Monster &constMonster, int value) {
		    Monster &monster = const_cast<Monster &>(constMonster);
		    monster.maxDamage = static_cast<uint8_t>(std::clamp(value, 0, 255));
	    });
	LuaSetDocFn(monsterType, "setArmorClass", "(value: integer)",
	    "Set this monster's armor class (clamped to 0..255). Generic; used to apply transient stat buffs. // Lua mod support",
	    [](const Monster &constMonster, int value) {
		    Monster &monster = const_cast<Monster &>(constMonster);
		    monster.armorClass = static_cast<uint8_t>(std::clamp(value, 0, 255));
	    });
	LuaSetDocFn(monsterType, "setToHit", "(value: integer)",
	    "Set this monster's golemToHit value (clamped to 0..65535). Only affects effective to-hit for a golem/player-minion (Monster::toHit returns golemToHit for player minions). Generic; used to apply transient stat buffs. // Lua mod support",
	    [](const Monster &constMonster, int value) {
		    Monster &monster = const_cast<Monster &>(constMonster);
		    monster.golemToHit = static_cast<uint16_t>(std::clamp(value, 0, 65535));
	    });
	LuaSetDocFn(monsterType, "setResistance", "(flags: integer)",
	    "Set this monster's raw resistance/immunity bitfield. Compose from monsters.Resistance.* flags. Generic; used to grant/remove resistances and immunities. // Lua mod support",
	    [](const Monster &constMonster, int flags) {
		    Monster &monster = const_cast<Monster &>(constMonster);
		    monster.resistance = static_cast<uint16_t>(flags);
	    });
	LuaSetDocFn(monsterType, "resolveMissileHit", "(missileId: integer, damageType: integer, minDam: integer, maxDam: integer, dist: integer, shifted: boolean) -> boolean",
	    "Resolve a missile hit against this monster through the engine's monster-vs-monster damage path "
	    "(MonsterTrapHit): rolls to-hit, applies the given DamageType's resistance/immunity, deals the rolled "
	    "damage, and runs the inline death/hit reactions. Returns true if the monster was hit. Lets a mod own a "
	    "player-minion's missile resolution from Lua (e.g. reclassify the element or adjust resistance around the "
	    "call) while the engine still performs the actual damage step. Use monsters.MissileID / monsters.DamageType "
	    "constants. // Lua mod support",
	    [](const Monster &constMonster, int missileId, int damageType, int minDam, int maxDam, int dist, bool shifted) -> bool {
		    Monster &monster = const_cast<Monster &>(constMonster);
		    return MonsterTrapHit(monster, minDam, maxDam, dist, static_cast<MissileID>(missileId), static_cast<DamageType>(damageType), shifted);
	    });
	LuaSetDocFn(monsterType, "tagForPlayer", "(playerId: integer)",
	    "Record that the given player has damaged this monster (sets the player's bit in the monster's whoHit "
	    "mask), so the player shares in the kill XP when it dies — the same credit a player's own attack records. "
	    "Use to attribute a player-minion's kills to its owner. No-op for an out-of-range playerId. // Lua mod support",
	    [](const Monster &constMonster, int playerId) {
		    if (playerId < 0 || playerId >= static_cast<int>(Players.size())) return;
		    Monster &monster = const_cast<Monster &>(constMonster);
		    monster.tag(Players[static_cast<size_t>(playerId)]);
	    });
	LuaSetDocFn(monsterType, "makeGolem", "(ownerId?: integer)",
	    "Convert this monster to a golem owned by player ownerId (defaults to the local player). Switches AI to GolumAi; use OnGolemCanTargetMonster and OnGolemCanSelect to customise behaviour. // Lua mod support",
	    [](Monster &monster, sol::optional<int> ownerId) {
		    LuaChangeMonsterToGolem(monster, ownerId.has_value() ? static_cast<uint8_t>(*ownerId) : MyPlayerId);
	    });
	LuaSetDocFn(monsterType, "checkQuestKill", "()",
	    "Run this monster's quest-completion side effects as if it had been killed (quest state + death speech, e.g. Skeleton King -> Q_SKELKING done + 'Rest well, Leoric'; Lazarus -> opens the path to Diablo; Diablo -> Q_DIABLO done + difficulty kill credit, WITHOUT the game-ending sequence). No-op for non-quest monsters. Wraps the engine's CheckQuestKill. // Lua mod support",
	    [](const Monster &monster) {
		    CheckQuestKill(monster, true);
		    // Diablo's quest completion lives in his game-ending death sequence (DiabloDeath), not in
		    // CheckQuestKill; mirror just its quest/progress side effects here (quest state + the local
		    // player's difficulty kill credit) so this binding covers every quest monster.
		    if (monster.type().type == MT_DIABLO) {
			    auto &quest = Quests[Q_DIABLO];
			    quest._qactive = QUEST_DONE;
			    NetSendCmdQuest(true, quest);
			    MyPlayer->pDiabloKillLevel = std::max(MyPlayer->pDiabloKillLevel, static_cast<uint8_t>(sgGameInitInfo.nDifficulty + 1));
		    }
	    });
	LuaSetDocReadonlyProperty(monsterType, "isLit", "boolean",
	    "Whether the tile this monster stands on is currently illuminated by any light source (readonly)",
	    [](const Monster &monster) {
		    return dLight[monster.position.tile.x][monster.position.tile.y] < LightsMax;
	    });
	LuaSetDocReadonlyProperty(monsterType, "hasNoLife", "boolean",
	    "Whether this monster is at 0 hit points (dead or playing its death animation). readonly",
	    [](const Monster &monster) -> bool {
		    return monster.hasNoLife();
	    });
	LuaSetDocReadonlyProperty(monsterType, "isActive", "boolean",
	    "Whether this monster is awake/activated (activeForTicks > 0). A monster sleeps (activeForTicks == 0) until the player makes it visible, and the engine's own AI does not run for a sleeping monster. Use as a cheap gate so a golem/ally never wakes or chases monsters the player has not engaged. readonly // Lua mod support",
	    [](const Monster &monster) -> bool {
		    return monster.activeForTicks != 0;
	    });
	LuaSetDocReadonlyProperty(monsterType, "isGolem", "boolean",
	    "Whether this monster has the MFLAG_GOLEM flag set (Golem spell or player-controlled ally). readonly",
	    [](const Monster &monster) -> bool {
		    return (monster.flags & MFLAG_GOLEM) != 0;
	    });
	LuaSetDocReadonlyProperty(monsterType, "ownerPlayerId", "integer",
	    "The id of the player that owns this monster, stored in goalVar3 (set when it becomes a golem/player-controlled ally; the caster becomes owner). Only meaningful when isGolem is true. Use to filter golem hooks by ownership. readonly",
	    [](const Monster &monster) -> int {
		    return static_cast<int>(monster.goalVar3);
	    });
	LuaSetDocReadonlyProperty(monsterType, "monsterClass", "string",
	    "The monster's creature class from monstdat: \"Animal\", \"Demon\", or \"Undead\". readonly",
	    [](const Monster &monster) -> std::string {
		    switch (monster.data().monsterClass) {
		    case MonsterClass::Animal: return "Animal";
		    case MonsterClass::Demon: return "Demon";
		    case MonsterClass::Undead: return "Undead";
		    }
		    return "Animal";
	    });
	LuaSetDocReadonlyProperty(monsterType, "isHidden", "boolean",
	    "Whether this monster has the MFLAG_HIDDEN flag set (faded out / invisible, e.g. a cloaked Sneak monster). readonly",
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
		        || ai == MonsterAIID::BoneDemon
		        || ai == MonsterAIID::Counselor
		        || ai == MonsterAIID::Mega;
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
		    // Multiple monsters snapping in the same frame each get a unique tile because
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
	LuaSetDocFn(monsterType, "hasLineOfSightTo", "(other: Monster) -> boolean",
	    "Returns true if a clear missile line of sight exists between this monster and the other monster. // Lua mod support",
	    [](const Monster &monster, const Monster &other) -> bool {
		    return LineClearMovingMissile(monster.position.tile, other.position.tile);
	    });
	LuaSetDocFn(monsterType, "hasLineOfSightToPlayer", "(player: Player) -> boolean",
	    "Returns true if a clear missile line of sight exists between this monster and the given player. // Lua mod support",
	    [](const Monster &monster, const Player &player) -> bool {
		    return LineClearMovingMissile(monster.position.tile, player.position.tile);
	    });
	LuaSetDocFn(monsterType, "startRangedAttack", "(missileId: integer)",
	    "Fire a ranged attack at the monster's current target using the given MissileID integer. Damage is drawn from the monster's natural min/max damage range. Use monsters.MissileID for missile ID constants.",
	    [](const Monster &constMonster, int missileIdInt) {
		    Monster &monster = const_cast<Monster &>(constMonster);
		    LuaStartMonsterRangedAttack(monster, static_cast<MissileID>(missileIdInt));
	    });
	LuaSetDocFn(monsterType, "startCharge", "() -> boolean",
	    "Fire a Rhino-missile charge at the current enemy target. Ally-safe via the monster's MFLAG_TARGETS_MONSTER flag (not the missile caster). Returns true if the charge started. // Lua mod support",
	    [](const Monster &constMonster) -> bool {
		    Monster &monster = const_cast<Monster &>(constMonster);
		    return LuaStartMonsterCharge(monster);
	    });
	LuaSetDocFn(monsterType, "startSpecialStand", "()",
	    "Play this monster's special-stand animation facing its current enemy (the brief cast/special pose). Does not fire a missile, deal damage, or spawn anything — purely the animation. // Lua mod support",
	    [](const Monster &constMonster) {
		    Monster &monster = const_cast<Monster &>(constMonster);
		    LuaStartMonsterSpecialStand(monster);
	    });
	LuaSetDocFn(monsterType, "startSpecialRangedAttack", "(missileId: integer)",
	    "Fire a special ranged attack (Special animation + SpecialRangedAttack mode) at the current target, e.g. the Hork Demon's HorkSpawn. The missile uses TARGET_PLAYERS with this monster as source. Use monsters.MissileID.* for missile IDs. // Lua mod support",
	    [](const Monster &constMonster, int missileIdInt) {
		    Monster &monster = const_cast<Monster &>(constMonster);
		    LuaStartMonsterSpecialRangedAttack(monster, static_cast<MissileID>(missileIdInt));
	    });
	LuaSetDocFn(monsterType, "fireMissileAt", "(missileId: integer, x: integer, y: integer)",
	    "Fire the given MissileID from this monster at the target tile (TARGET_PLAYERS with this monster as "
	    "source, damage drawn from its natural min/max range) without changing the monster's mode or "
	    "animation — for effects needing extra projectiles beyond the single missile the attack mode fires "
	    "(e.g. a multi-target special attack). Use monsters.MissileID.* for missile IDs. // Lua mod support",
	    [](const Monster &constMonster, int missileIdInt, int x, int y) {
		    Monster &monster = const_cast<Monster &>(constMonster);
		    const WorldTilePosition dst { static_cast<WorldTileCoord>(x), static_cast<WorldTileCoord>(y) };
		    AddMissile(monster.position.tile, dst, monster.direction, static_cast<MissileID>(missileIdInt),
		        TARGET_PLAYERS, monster, RandomIntBetween(monster.minDamage, monster.maxDamage), 0);
	    });
	LuaSetDocFn(monsterType, "naturalRangedMissileId", "() -> integer",
	    "Returns the MissileID integer this monster's authentic ranged/special attack would fire, derived from its original AI (Counselor/Advocate by intelligence, Mega->Inferno, others by type), without firing it. Combine with monsters.getMissileDamageType to derive the attack's element. // Lua mod support",
	    [](const Monster &monster) -> int {
		    return static_cast<int>(LuaGetMonsterNaturalRangedMissile(monster));
	    });
	LuaSetDocFn(monsterType, "castFlashSelf", "()",
	    "Cast a Flash burst (the FlashBottom+FlashTop missile pair of the Flash spell) centered on this "
	    "monster's own tile, sourced from this monster (TARGET_PLAYERS — ally-safe vs other player-minions "
	    "via the engine's faction check in CheckMissileCol). Damage is the engine's native monster-Flash "
	    "value. Fires immediately (no cast animation), for an instant area burst at the monster's location. // Lua mod support",
	    [](const Monster &constMonster) {
		    Monster &monster = const_cast<Monster &>(constMonster);
		    const int dam = RandomIntBetween(monster.minDamage, monster.maxDamage);
		    AddMissile(monster.position.tile, monster.position.tile, monster.direction, MissileID::FlashBottom, TARGET_PLAYERS, monster, dam, 0);
		    AddMissile(monster.position.tile, monster.position.tile, monster.direction, MissileID::FlashTop, TARGET_PLAYERS, monster, dam, 0);
	    });
	LuaSetDocFn(monsterType, "castResurrectBeamSelf", "()",
	    "Spawn the Resurrect beam visual (MissileID::ResurrectBeam) centred on this monster's own tile. "
	    "Purely cosmetic — the beam deals no damage and targets nothing; it plays the Resurrect sprite "
	    "animation once at the monster's location (intended to mark a spot on a monster's final death "
	    "frame). Fires immediately, no cast animation. // Lua mod support",
	    [](const Monster &constMonster) {
		    Monster &monster = const_cast<Monster &>(constMonster);
		    AddMissile(monster.position.tile, monster.position.tile, monster.direction, MissileID::ResurrectBeam, TARGET_PLAYERS, monster, 0, 0);
	    });
	LuaSetDocFn(monsterType, "setLightRadius", "(radius: integer)",
	    "Give this monster a light source of the given radius (the same mechanic 'lighted' unique monsters "
	    "use), or change its radius if it already has one; radius <= 0 removes the light. The engine moves "
	    "the light with the monster automatically (MonsterWalk / SyncLightPosition) and frees it on "
	    "death/removal, so no per-frame upkeep is needed. // Lua mod support",
	    [](const Monster &constMonster, int radius) {
		    Monster &monster = const_cast<Monster &>(constMonster);
		    if (radius <= 0) {
			    if (monster.lightId != NO_LIGHT) {
				    AddUnLight(monster.lightId);
				    monster.lightId = NO_LIGHT;
			    }
			    return;
		    }
		    const uint8_t r = static_cast<uint8_t>(radius);
		    if (monster.lightId == NO_LIGHT)
			    monster.lightId = AddLight(monster.position.tile, r);
		    else
			    ChangeLightRadius(monster.lightId, r);
	    });
	LuaSetDocFn(monsterType, "startAttack", "()",
	    "Trigger this monster's normal melee attack (Attack animation + MeleeAttack mode) against its current enemy target. Hit resolution dispatches on MFLAG_TARGETS_MONSTER, so it works for monster and player targets alike. // Lua mod support",
	    [](const Monster &constMonster) {
		    Monster &monster = const_cast<Monster &>(constMonster);
		    LuaStartMonsterAttack(monster);
	    });
	LuaSetDocFn(monsterType, "startSpecialAttack", "()",
	    "Trigger this monster's special melee attack (Special animation + SpecialMeleeAttack mode), e.g. the Goat Melee low-HP special. // Lua mod support",
	    [](const Monster &constMonster) {
		    Monster &monster = const_cast<Monster &>(constMonster);
		    LuaStartMonsterSpecialAttack(monster);
	    });
	LuaSetDocFn(monsterType, "startHeal", "()",
	    "Trigger the Gargoyle self-heal animation (reverses Special animation, enters Heal mode). // Lua mod support",
	    [](const Monster &constMonster) {
		    Monster &monster = const_cast<Monster &>(constMonster);
		    LuaStartMonsterHeal(monster);
	    });
	LuaSetDocFn(monsterType, "startEating", "()",
	    "Trigger the Scavenger corpse-eating animation (enters SpecialMeleeAttack mode). GolumAi will not interrupt until the animation finishes. // Lua mod support",
	    [](const Monster &constMonster) {
		    Monster &monster = const_cast<Monster &>(constMonster);
		    LuaStartMonsterEat(monster);
	    });
	LuaSetDocFn(monsterType, "startFadeout", "()",
	    "Trigger the Sneak fade-out animation (enters FadeOut mode; sets MFLAG_HIDDEN when the animation completes). Used to cloak a monster.",
	    [](const Monster &constMonster) {
		    Monster &monster = const_cast<Monster &>(constMonster);
		    LuaStartMonsterFadeout(monster);
	    });
	LuaSetDocFn(monsterType, "startFadein", "()",
	    "Trigger the Sneak fade-in animation (enters FadeIn mode; clears MFLAG_HIDDEN immediately). Used to materialise a monster.",
	    [](const Monster &constMonster) {
		    Monster &monster = const_cast<Monster &>(constMonster);
		    LuaStartMonsterFadein(monster);
	    });
	LuaSetDocFn(monsterType, "findNearbyCorpse", "() -> Point|nil",
	    "Search within 4 tiles for a corpse tile with line-of-sight. Returns the tile position or nil. // Lua mod support",
	    [](const Monster &monster) -> sol::optional<Point> {
		    const auto result = LuaMonsterFindCorpse(monster);
		    if (!result) return sol::nullopt;
		    return *result;
	    });
	LuaSetDocFn(monsterType, "walkToward", "(x: integer, y: integer) -> boolean",
	    "Walk one step toward the given tile using AiPlanPath (wall routing) with RandomWalk fallback. Returns true if a step was taken. // Lua mod support",
	    [](const Monster &constMonster, int x, int y) -> bool {
		    Monster &monster = const_cast<Monster &>(constMonster);
		    monster.enemyPosition = { static_cast<WorldTileCoord>(x), static_cast<WorldTileCoord>(y) };
		    if (LuaMonsterPlanPath(monster)) return true;
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
	LuaSetDocFn(table, "requestExtraTypes", "(count: integer)",
	    "Reserve additional per-level monster-type slots for this session (on top of the base cap). "
	    "Call at mod-load time, before any level is generated. Cumulative across mods; unmodded play is unchanged. // Lua mod support",
	    [](int count) {
		    if (count > 0)
			    RequestExtraLevelMonsterTypes(static_cast<size_t>(count));
	    });
	LuaSetDocFn(table, "requestExtraMonsters", "(count: integer)",
	    "Reserve additional live-monster slots for this session (on top of the base cap of 200). "
	    "Call at mod-load time, before any level is generated. Cumulative across mods; the effective cap "
	    "is clamped to the engine's hard ceiling of 252 (the uint8 enemy-encoding limit). Unmodded play is unchanged. // Lua mod support",
	    [](int count) {
		    if (count > 0)
			    RequestExtraMonsters(static_cast<size_t>(count));
	    });
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
	LuaSetDocFn(table, "getMissileDamageType", "(missileId: integer) -> integer",
	    "Returns the DamageType integer (monsters.DamageType.*) of the given MissileID. Use to derive a missile's element (Fire/Lightning/Magic/Physical/Acid), e.g. for resistance-scaled mechanics. // Lua mod support",
	    [](int missileId) -> int {
		    return static_cast<int>(GetMissileData(static_cast<MissileID>(missileId)).damageType());
	    });
	LuaSetDocFn(table, "registerTrn", "(bytes: integer[256]) -> integer",
	    "Register a 256-byte TRN (palette-remap) table and return a handle. Pass a Lua array of 256 "
	    "color indices (1-based; entry i is the color every pixel of index i-1 is drawn as). Return the "
	    "handle from an OnGetMonsterTRN handler to remap a monster's palette for the frame (e.g. a blink). "
	    "Call once at load and reuse the handle; the buffer is copied and kept for the session. // Lua mod support",
	    [](const sol::table &bytes) -> int {
		    std::array<uint8_t, 256> trn {};
		    for (int i = 0; i < 256; i++)
			    trn[static_cast<size_t>(i)] = static_cast<uint8_t>(bytes.get_or(i + 1, i));
		    return lua::RegisterMonsterTRN(trn.data());
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

		    if (ActiveMonsterCount >= GetMaxMonsters()) return nullptr; // Lua mod support
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
		    InitializeSpawnedMonster(spawnPos, Direction::South, typeIndex, monsterIndex, SyncSpawnSeed(monsterIndex), 0, 0);
		    // Local-only spawn — the level-local typeIndex is meaningless on a peer whose level lacks
		    // this species, so it is NOT broadcast. Cross-client spawn rides the mod net pipe keyed by
		    // the (globally stable) species id; see monsters.netSpawnAt. // Lua mod support

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
		    // InitializeSpawnedMonster activates the slot; no manual ActiveMonsterCount bump.
		    const _difficulty savedDiff = sgGameInitInfo.nDifficulty;
		    sgGameInitInfo.nDifficulty = static_cast<_difficulty>(capturedDifficulty);
		    InitializeSpawnedMonster(placement->spawnPos, Direction::South, placement->typeIndex, placement->monsterIndex, placement->seed, 0, 0);
		    sgGameInitInfo.nDifficulty = savedDiff;
		    // Local-only spawn; cross-client spawn rides the mod net pipe by species id (see netSpawnAt). // Lua mod support
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
		    // InitializeSpawnedMonster activates the slot; no manual ActiveMonsterCount bump.
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
		    // Local-only spawn; cross-client spawn rides the mod net pipe by species id (see netSpawnAt). // Lua mod support
		    return &Monsters[placement->monsterIndex];
	    });
	LuaSetDocFn(table, "netSpawnAt", "(monsterId: integer, typeId: integer, uniqueTypeIdx: integer, capturedDifficulty: integer, x: integer, y: integer) -> Monster|nil",
	    "Recreate a networked mod-spawned monster at a SPECIFIC slot id on this client, resolving the species to THIS client's own LevelMonsterTypes index (registering the type + loading its GFX as needed). For replaying a peer's mod spawn: each client builds its own natural monster set, then the owner's extra monsters are recreated on top via this. uniqueTypeIdx < 0 = a normal (non-unique) monster. Unlike spawnWithDifficulty/spawnUniqueAt this does NOT gate on level ownership (the receiver is not the level owner) and uses the caller-supplied slot id instead of allocating one. The RNG seed is derived from that slot id (see SyncSpawnSeed) so every client starts the monster on the same initial state (e.g. animation frame); no seed is taken from the caller. (Per-monster AI RNG is synced separately by the engine each tick via MonsterSeeds, keyed on the same slot id.) // Lua mod support",
	    [](int monsterId, int typeIdInt, int uniqueTypeIdx, int capturedDifficulty, int x, int y) -> Monster * {
		    if (monsterId < 0 || monsterId >= static_cast<int>(GetMaxMonsters())) return nullptr;
		    const auto type = static_cast<_monster_id>(typeIdInt);
		    const auto typeIndex = EnsureMonsterType(type, uniqueTypeIdx >= 0 ? PLACE_UNIQUE : PLACE_SCATTER);
		    if (!typeIndex) return nullptr;
		    const _difficulty savedDiff = sgGameInitInfo.nDifficulty;
		    sgGameInitInfo.nDifficulty = static_cast<_difficulty>(capturedDifficulty);
		    InitializeSpawnedMonster({ x, y }, Direction::South, *typeIndex, static_cast<size_t>(monsterId), SyncSpawnSeed(static_cast<size_t>(monsterId)), 0, 0);
		    Monster &monster = Monsters[static_cast<size_t>(monsterId)];
		    if (uniqueTypeIdx >= 0 && uniqueTypeIdx < static_cast<int>(UniqueMonstersData.size())) {
			    const UniqueMonsterType uniqueType = static_cast<UniqueMonsterType>(uniqueTypeIdx);
			    if (const auto result = PrepareUniqueMonst(monster, uniqueType, 0, 0, UniqueMonstersData[static_cast<size_t>(uniqueTypeIdx)]); !result)
				    LogError("netSpawnAt: PrepareUniqueMonst failed for unique type {}: {}", uniqueTypeIdx, result.error());
		    }
		    sgGameInitInfo.nDifficulty = savedDiff;
		    return &monster;
	    });
	LuaSetDocFn(table, "recordDeltaKill", "(level: integer, monsterId: integer, x: integer, y: integer)",
	    "Record a monster as killed in the given level's multiplayer delta by slot id + position, without a live "
	    "monster instance. For a client not on that level (so it has no live monster to remove): mirrors the delta "
	    "record a networked monster death makes, so the slot is reaped instead of regenerated from the level seed "
	    "when the client later loads the level. No-op in singleplayer. // Lua mod support",
	    [](int level, int monsterId, int x, int y) {
		    if (level < 0 || monsterId < 0) return;
		    LuaDeltaKillMonster(static_cast<uint8_t>(level), static_cast<size_t>(monsterId), { x, y });
	    });
	LuaSetDocFn(table, "removeDeltaSpawnedMonster", "(level: integer, monsterId: integer)",
	    "Erase a dynamically spawned monster from the given level's multiplayer delta by slot id, without a live "
	    "monster instance — for a client not on that level. No-op in singleplayer. // Lua mod support",
	    [](int level, int monsterId) {
		    if (level < 0 || monsterId < 0) return;
		    LuaDeltaRemoveSpawnedMonster(static_cast<uint8_t>(level), static_cast<size_t>(monsterId));
	    });
	LuaSetDocFn(table, "getHovered", "() -> Monster|nil",
	    "Returns the monster currently under the player's cursor (pcursmonst), or nil if no monster is hovered.",
	    []() -> Monster * {
		    if (pcursmonst < 0 || pcursmonst >= static_cast<int>(GetMaxMonsters())) return nullptr; // Lua mod support
		    return &Monsters[pcursmonst];
	    });
	LuaSetDocFn(table, "fromId", "(id: integer) -> Monster|nil",
	    "Returns the active Monster occupying the given slot id (Monster.id), or nil if no active monster holds that slot. // Lua mod support",
	    [](int id) -> Monster * {
		    if (id < 0 || id >= static_cast<int>(GetMaxMonsters())) return nullptr;
		    for (size_t i = 0; i < ActiveMonsterCount; i++) {
			    if (ActiveMonsters[i] == static_cast<size_t>(id))
				    return &Monsters[id];
		    }
		    return nullptr;
	    });
	LuaSetDocFn(table, "aiRandom", "(n: integer) -> integer",
	    "Returns a value in [0, n) from the engine's global RNG (GenerateRnd). During monster AI processing the global RNG is reseeded to each monster's per-monster seed (synced across clients in multiplayer), so a draw made from inside a monster-AI hook is identical on every client; outside AI processing it is just the running global RNG. // Lua mod support",
	    [](int n) -> int {
		    if (n <= 0) return 0;
		    return GenerateRnd(n);
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
		missileIdTable["HorkSpawn"]      = static_cast<int>(MissileID::HorkSpawn);
		missileIdTable["DiabloApocalypseBoom"] = static_cast<int>(MissileID::DiabloApocalypseBoom);
		table["MissileID"] = missileIdTable;
	}
	// Lua mod support: monster_resistance bitflags for use with monster.resistance / monster:setResistance()
	{
		sol::table resistanceTable = lua.create_table();
		resistanceTable["ResistMagic"]     = static_cast<int>(RESIST_MAGIC);
		resistanceTable["ResistFire"]       = static_cast<int>(RESIST_FIRE);
		resistanceTable["ResistLightning"]  = static_cast<int>(RESIST_LIGHTNING);
		resistanceTable["ImmuneMagic"]      = static_cast<int>(IMMUNE_MAGIC);
		resistanceTable["ImmuneFire"]       = static_cast<int>(IMMUNE_FIRE);
		resistanceTable["ImmuneLightning"]  = static_cast<int>(IMMUNE_LIGHTNING);
		resistanceTable["ImmuneAcid"]       = static_cast<int>(IMMUNE_ACID);
		table["Resistance"] = resistanceTable;
	}
	// Lua mod support: DamageType constants for use with monsters.getMissileDamageType
	{
		sol::table damageTypeTable = lua.create_table();
		damageTypeTable["Physical"]  = static_cast<int>(DamageType::Physical);
		damageTypeTable["Fire"]      = static_cast<int>(DamageType::Fire);
		damageTypeTable["Lightning"] = static_cast<int>(DamageType::Lightning);
		damageTypeTable["Magic"]     = static_cast<int>(DamageType::Magic);
		damageTypeTable["Acid"]      = static_cast<int>(DamageType::Acid);
		table["DamageType"] = damageTypeTable;
	}
	// Lua mod support: MonsterAIID constants for use with monster.originalAiId
	{
		// Expose the complete MonsterAIID enum so mods can reference any AI by name.
		// (A missing key reads back as nil; using one as a Lua table key — e.g. in a
		// constructor literal — raises "table index is nil" at mod-load time.)
		sol::table aiIdTable = lua.create_table();
		aiIdTable["Zombie"]          = static_cast<int>(MonsterAIID::Zombie);
		aiIdTable["Fat"]             = static_cast<int>(MonsterAIID::Fat);
		aiIdTable["SkeletonMelee"]   = static_cast<int>(MonsterAIID::SkeletonMelee);
		aiIdTable["SkeletonRanged"]  = static_cast<int>(MonsterAIID::SkeletonRanged);
		aiIdTable["Scavenger"]       = static_cast<int>(MonsterAIID::Scavenger);
		aiIdTable["Rhino"]           = static_cast<int>(MonsterAIID::Rhino);
		aiIdTable["GoatMelee"]       = static_cast<int>(MonsterAIID::GoatMelee);
		aiIdTable["GoatRanged"]      = static_cast<int>(MonsterAIID::GoatRanged);
		aiIdTable["Fallen"]          = static_cast<int>(MonsterAIID::Fallen);
		aiIdTable["Magma"]           = static_cast<int>(MonsterAIID::Magma);
		aiIdTable["SkeletonKing"]    = static_cast<int>(MonsterAIID::SkeletonKing);
		aiIdTable["Bat"]             = static_cast<int>(MonsterAIID::Bat);
		aiIdTable["Gargoyle"]        = static_cast<int>(MonsterAIID::Gargoyle);
		aiIdTable["Butcher"]         = static_cast<int>(MonsterAIID::Butcher);
		aiIdTable["Succubus"]        = static_cast<int>(MonsterAIID::Succubus);
		aiIdTable["Sneak"]           = static_cast<int>(MonsterAIID::Sneak);
		aiIdTable["Storm"]           = static_cast<int>(MonsterAIID::Storm);
		aiIdTable["FireMan"]         = static_cast<int>(MonsterAIID::FireMan);
		aiIdTable["Gharbad"]         = static_cast<int>(MonsterAIID::Gharbad);
		aiIdTable["Acid"]            = static_cast<int>(MonsterAIID::Acid);
		aiIdTable["AcidUnique"]      = static_cast<int>(MonsterAIID::AcidUnique);
		aiIdTable["Golem"]           = static_cast<int>(MonsterAIID::Golem);
		aiIdTable["Zhar"]            = static_cast<int>(MonsterAIID::Zhar);
		aiIdTable["Snotspill"]       = static_cast<int>(MonsterAIID::Snotspill);
		aiIdTable["Snake"]           = static_cast<int>(MonsterAIID::Snake);
		aiIdTable["Counselor"]       = static_cast<int>(MonsterAIID::Counselor);
		aiIdTable["Mega"]            = static_cast<int>(MonsterAIID::Mega);
		aiIdTable["Diablo"]          = static_cast<int>(MonsterAIID::Diablo);
		aiIdTable["Lazarus"]         = static_cast<int>(MonsterAIID::Lazarus);
		aiIdTable["LazarusSuccubus"] = static_cast<int>(MonsterAIID::LazarusSuccubus);
		aiIdTable["Lachdanan"]       = static_cast<int>(MonsterAIID::Lachdanan);
		aiIdTable["Warlord"]         = static_cast<int>(MonsterAIID::Warlord);
		aiIdTable["FireBat"]         = static_cast<int>(MonsterAIID::FireBat);
		aiIdTable["Torchant"]        = static_cast<int>(MonsterAIID::Torchant);
		aiIdTable["HorkDemon"]       = static_cast<int>(MonsterAIID::HorkDemon);
		aiIdTable["Lich"]            = static_cast<int>(MonsterAIID::Lich);
		aiIdTable["ArchLich"]        = static_cast<int>(MonsterAIID::ArchLich);
		aiIdTable["Psychorb"]        = static_cast<int>(MonsterAIID::Psychorb);
		aiIdTable["Necromorb"]       = static_cast<int>(MonsterAIID::Necromorb);
		aiIdTable["BoneDemon"]       = static_cast<int>(MonsterAIID::BoneDemon);
		table["AIID"] = aiIdTable;
	}
	return table;
}

} // namespace devilution
