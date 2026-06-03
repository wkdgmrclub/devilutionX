#pragma once

#include <cstdint>
#include <string_view>

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
void OnOilyShrine(const Player *player);
bool OnShouldExcludeWirtItem(const Player *player, std::string_view itemType, bool defaultValue);
bool OnPlayerForceLightArmorSprite(const Player *player, bool defaultValue);

void LoadModsComplete();
void GameDrawComplete();
void GameStart();
void OnNewCharacter(const Player &player);
void OnCreatePlrItems(Player &player); // Lua mod support
void OnLevelExit();
void OnLevelEnter();

} // namespace lua

} // namespace devilution
