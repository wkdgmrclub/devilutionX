#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "engine/point.hpp"

namespace devilution {

struct Player;
struct Monster;
struct Item;

namespace lua {

void MonsterDataLoaded();
void UniqueMonsterDataLoaded();
void ItemDataLoaded();
void UniqueItemDataLoaded();
void SpellDataLoaded();
void PlayerDataLoaded();

void StoreOpened(std::string_view name);

void OnMonsterTakeDamage(const Monster *monster, int damage, int damageType);
void OnMonsterDeath(const Monster *monster);
bool OnGolemCanTargetMonster(const Monster *golem, const Monster *candidate, bool defaultValue);
bool OnGolemCanTargetGolem(const Monster *golem, const Monster *candidate, bool defaultValue);
bool OnGolemCanChaseTarget(const Monster *golem, const Monster *target, bool defaultValue);
bool OnGolemCanSelect(const Monster *monster, bool defaultValue);
// Returns: nullopt = engine default wander; empty optional<Point> = stand still; Point = walk toward.
// When a Point is returned, GolumAi sets enemyPosition to it and tries AiPlanPath first (wall routing),
// then falls back to RandomWalk if AiPlanPath returns false (clear line).
std::optional<std::optional<Point>> OnGolemIdle(const Monster *golem, bool hasTarget, Point enemyPosition);
// `enemy` is the golem's current target monster, or null when it has none. A handler derives
// distance / line of sight from it (e.g. monster:hasLineOfSightTo). Returns true to consume the tick.
bool OnGolemChooseAction(const Monster *golem, const Monster *enemy);
void OnSpellCast(const Player *player, int spellId, int spellType, const Monster *targetMonster, int targetX, int targetY);
void OnSpellActionFrame(const Player *player, int spellId, int spellType, int targetX, int targetY);
void OnPlayerGainExperience(const Player *player, uint32_t exp);
void OnPlayerTakeDamage(const Player *player, int damage, int damageType);
void OnCalcPlayerResistances(const Player *player, int fire, int lightning, int magic);

void OnCustomItemRecreated(Item &item);
void OnItemPickedUp(const Player &player, const Item &item);
void OnItemDropped(const Player &player, const Item &item);
int8_t OnGetAnimationSkipFrames(const Player *player, std::string_view animType, int8_t defaultSkip);
int8_t OnGetPlayerIdleFrames(const Player *player, int weaponGraphic, bool isInTown);

bool OnCanPlayerUseItem(const Player *player, const Item *item, bool defaultValue);
int OnGetMaxAttributeValue(const Player *player, std::string_view attribute, int defaultValue);

// Archetype hooks — generic hooks for dynamic classes to override class-specific combat formulas.
int OnGetPlayerDamageMod(const Player *player, int strMod, int strDexMod, int totalVit, bool isHoldingBow, bool isHoldingShield, bool isHoldingStaff, bool isUnarmed, int defaultValue);
int OnGetManaCost(const Player *player, int baseCost, int defaultValue);
bool OnPlayerHasCriticalStrike(const Player *player, bool defaultValue);
bool OnPlayerHasIronSkin(const Player *player, bool defaultValue);
bool OnPlayerHasNaturalResistance(const Player *player, bool defaultValue);
int OnGetBowDamageMod(const Player *player, int fullMod, int defaultValue);
int OnGetArrowVelocityBonus(const Player *player, int defaultValue);
bool OnPlayerCanBlockWithoutShield(const Player *player, bool isHoldingStaff, bool isUnarmed, bool defaultValue);
int OnGetArmorLevelBonus(const Player *player, std::string_view armorType, bool isUnique, int defaultValue);
int OnGetPotionHealAmount(const Player *player, int l, int defaultValue);
int OnGetPotionManaAmount(const Player *player, int l, int defaultValue);
bool OnPlayerHasArmorPierce(const Player *player, bool defaultValue);
bool OnPlayerCanCleave(const Player *player, bool isHoldingAxe, bool isHoldingTwoHandedHeavy, bool isHoldingStaff, bool defaultValue);
int OnGetHitRecoveryThreshold(const Player *player, int defaultThreshold);
std::pair<int, int> OnGetUnarmedDamageFloor(const Player *player, int minDamage, int maxDamage);
int OnGetBlockChanceBonus(const Player *player, int blockBonus);
void OnOilyShrine(const Player *player);
bool OnShouldExcludeWirtItem(const Player *player, int itemTypeInt, bool defaultValue);
bool OnVendorWillBuyItem(const Item *item, bool defaultValue);  // query: false = vendor won't buy this item
std::string OnGetPlayerArmorGraphic(const Player *player, std::string_view defaultGraphic);
void OnItemUsed(const Player &player, int mid, int spellID);
std::string OnGetMiscItemDescription(const Item *item);
bool OnPrepareUniqueInfoBox(const Item &item); // true = Lua populated slot, set _iUid = UITEM_LUA_CUSTOM

void LoadModsComplete();
void GameDrawComplete();
void GameStart();
void OnNewCharacter(const Player &player);
void OnCreatePlrItems(Player &player);
void OnLevelExit();
void OnLevelEnter();

// Generic mod net pipe: fired on receipt of a CMD_LUAMSG packet. `senderId` is the player id the
// message came from; `payload` is the opaque bytes the sender passed to system.netSend (binary-safe).
void NetMessage(int senderId, std::string_view payload);

void OnGolemKilledMonster(const Monster *golem, const Monster *victim);
// Fired only for a golem-sourced spawn missile (the source monster has MFLAG_GOLEM) when it lands,
// BEFORE the engine's default SpawnMonster. Returning false suppresses that vanilla spawn at the
// landing tile so a handler can create the monster itself (the engine spawn uses a level-local type
// index, wrong if the source has been relocated). speciesTypeId is the canonical monster type the
// engine would spawn; spawnX/spawnY the landing tile. Default true = unchanged vanilla behaviour.
bool OnGolemMinionMissileSpawn(const Monster *golem, int speciesTypeId, int spawnX, int spawnY, bool defaultValue);
std::vector<std::string> OnGetMonsterInfo(const Monster *monster);
std::string OnGetMonsterDisplayName(const Monster *monster); // default = monster.name()
int OnGetMonsterOutlineColor(const Monster *monster); // -1 = no outline
// Query: a mod may override a monster's palette-remap (TRN) for the frame. Returns the buffer to use,
// or nullptr for the engine default. The Lua handler returns a handle previously obtained from
// RegisterMonsterTRN (-1 = none); this resolves it to the stored 256-byte buffer.
uint8_t *OnGetMonsterTRN(const Monster *monster);
// Store a 256-byte TRN buffer (copied) and return a handle a Lua OnGetMonsterTRN handler can return.
int RegisterMonsterTRN(const uint8_t *data256);
bool OnMonsterCanCompleteQuest(const Monster *monster, bool defaultValue);
bool OnMonsterCanPlaceCorpse(const Monster *monster, bool defaultValue);
bool OnGolemCanRunAI(const Monster *monster, bool defaultValue);
bool OnMonsterCanShowResistances(const Monster *monster, bool defaultValue);
bool OnMissileCanTargetMonster(const Monster *monster, Point source, bool defaultValue);
int OnGolemMissileDamage(const Monster *golem, int missileId, int dam);
// Fired for a missile's resolution against a monster when either the source or the target is a
// player-minion (MFLAG_GOLEM); source may be null (e.g. a trap). Lets a mod fully own the hit
// resolution: return <0 to decline (the engine runs its default trap-hit resolution against the passed
// damageType), or return 1/0 (hit/no-hit) after resolving the hit itself. Passes the resolution inputs
// the engine would otherwise feed the default path.
int OnMonsterMissileHit(const Monster *source, const Monster *target, int missileId, int damageType, int minDamage, int maxDamage, int dist, bool isDamageShifted);
bool OnPlayerAttackMonster(const Player *player, const Monster *monster, bool defaultValue);
bool OnPlayerAttackMonster(const Player *player, int monsterId, bool defaultValue);
bool OnPlayerCanPickUpItem(const Player *player, const Item *item, bool defaultValue);
bool OnCanSelectMonsterWithCursor(int cursorId, bool defaultValue);
bool OnCursorMonsterTarget(const Monster *monster, bool defaultValue);
// Speedbook hooks
struct CustomSpeedbookEntry {
	std::string displayName;
	uint32_t scrollSeed;
	int spellId;
	int scrollCount; // -1 = standard inventory count
};
std::vector<CustomSpeedbookEntry> OnGetCustomSpeedbookScrollEntries(const Player *player);
std::string OnGetSpeedbookSelectionType(const Player *player, int spellId, std::string_view originalType, std::string_view promotedType);
std::string OnGetSpeedbookSpellName(const Player *player, int spellId, std::string_view defaultName);
bool OnShouldHideSpeedbookSpell(const Player *player, int spellId, std::string_view spellType);
bool OnCanSelectSpellBookEntry(const Player *player, int spellId);
int OnResolveCustomScrollSlot(const Player *player, int spellId, uint32_t selectedSeed, int defaultSlot);
bool OnCanCastScroll(const Player *player, int spellId, uint32_t selectedSeed, int monsterId);
bool OnCanCastSkill(const Player *player, int spellId, int monsterId);
bool OnCanAutoRefillBeltItem(const Player *player, const Item *item, bool defaultValue);
bool OnItemAllowedInStash(const Item *item, bool defaultValue); // query: false = item may not be placed in the stash

// Mod data persistence hooks
// OnSavePlayerData: all handlers run; return values (tables of uint32) are concatenated into a flat vector.
// OnLoadPlayerData: the same flat vector is passed back to all handlers on load.
std::vector<uint32_t> OnSavePlayerData();
void OnLoadPlayerData(const std::vector<uint32_t> &data);

// Bracket the hero-file write. A handler may transiently mutate the saved player (e.g. remove an item)
// in OnBeforeSaveHero and must restore it in OnAfterSaveHero so the change spans only this one write.
void OnBeforeSaveHero();
void OnAfterSaveHero();

} // namespace lua

} // namespace devilution
