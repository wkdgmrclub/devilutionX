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
bool OnGolemCanTargetMonster(const Monster *ally, const Monster *candidate, bool hasLOS, bool defaultValue);
bool OnGolemCanChaseTarget(const Monster *ally, const Monster *target, bool defaultValue);
bool OnGolemCanSelect(const Monster *monster, bool defaultValue);
// Returns: nullopt = engine default wander; empty optional<Point> = stand still; Point = walk toward.
// When a Point is returned, GolumAi sets enemyPosition to it and tries AiPlanPath first (wall routing),
// then falls back to RandomWalk if AiPlanPath returns false (clear line).
std::optional<std::optional<Point>> OnGolemIdle(const Monster *golem, bool hasTarget, Point enemyPosition);
void OnSpellCast(const Player *player, int spellId, int spellType, const Monster *targetMonster, int targetX, int targetY);

void OnPlayerGainExperience(const Player *player, uint32_t exp);
void OnPlayerTakeDamage(const Player *player, int damage, int damageType);

void OnCustomItemRecreated(Item &item);

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
bool OnShouldExcludeWirtItem(const Player *player, std::string_view itemType, bool defaultValue);
std::string OnGetPlayerArmorGraphic(const Player *player, std::string_view defaultGraphic);
void OnItemUsed(const Player &player, int mid, int spellID); // Lua mod support
std::string OnGetMiscItemDescription(const Item *item); // Lua mod support

void LoadModsComplete();
void GameDrawComplete();
void GameStart();
void OnNewCharacter(const Player &player);
void OnCreatePlrItems(Player &player); // Lua mod support
void OnLevelExit();
void OnLevelEnter();

void OnGolemKilledMonster(const Monster *ally, const Monster *victim);
std::vector<std::string> OnGetMonsterInfo(const Monster *monster);

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

} // namespace lua

} // namespace devilution
