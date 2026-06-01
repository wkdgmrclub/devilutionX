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

void LoadModsComplete();
void GameDrawComplete();
void GameStart();
void OnLevelExit();

} // namespace lua

} // namespace devilution
