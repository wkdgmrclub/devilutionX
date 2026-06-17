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
bool OnGolemChooseAction(const Monster *golem, bool hasTarget, int distanceToTarget, bool hasLOS);
void OnSpellCast(const Player *player, int spellId, int spellType, const Monster *targetMonster, int targetX, int targetY);
void OnSpellActionFrame(const Player *player, int spellId, int spellType, int targetX, int targetY);
void OnPlayerGainExperience(const Player *player, uint32_t exp);
void OnPlayerTakeDamage(const Player *player, int damage, int damageType);

void OnCustomItemRecreated(Item &item);
void OnItemPickedUp(const Player &player, const Item &item);
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
std::string OnGetPlayerArmorGraphic(const Player *player, std::string_view defaultGraphic);
void OnItemUsed(const Player &player, int mid, int spellID);std::string OnGetMiscItemDescription(const Item *item);bool OnPrepareUniqueInfoBox(const Item &item);          // true = Lua populated slot, set _iUid = UITEM_LUA_CUSTOM

void LoadModsComplete();
void GameDrawComplete();
void GameStart();
void OnNewCharacter(const Player &player);
void OnCreatePlrItems(Player &player);void OnLevelExit();
void OnLevelEnter();

void OnGolemKilledMonster(const Monster *golem, const Monster *victim);
void OnGolemSpawnedMinion(const Monster *golem, const Monster *newMonster);
std::vector<std::string> OnGetMonsterInfo(const Monster *monster);
std::string OnGetMonsterDisplayName(const Monster *monster); // default = monster.name()
int OnGetMonsterOutlineColor(const Monster *monster); // -1 = no outline
bool OnMonsterCanCompleteQuest(const Monster *monster, bool defaultValue);
bool OnMonsterCanPlaceCorpse(const Monster *monster, bool defaultValue);
bool OnMonsterCanShowResistances(const Monster *monster, bool defaultValue);
bool OnMissileCanTargetMonster(const Monster *monster, Point source, bool defaultValue);
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

// Mod data persistence hooks
// OnSavePlayerData: all handlers run; return values (tables of uint32) are concatenated into a flat vector.
// OnLoadPlayerData: the same flat vector is passed back to all handlers on load.
std::vector<uint32_t> OnSavePlayerData();
void OnLoadPlayerData(const std::vector<uint32_t> &data);

} // namespace lua

} // namespace devilution
