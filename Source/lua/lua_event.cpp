#include "lua/lua_event.hpp"

#include <optional>
#include <string_view>
#include <utility>

#include <sol/sol.hpp>

#include "inv.h"
#include "lua/lua_global.hpp"
#include "monster.h"
#include "player.h"
#include "utils/log.hpp"

namespace devilution {

namespace lua {

template <typename... Args>
void CallLuaEvent(std::string_view name, Args &&...args)
{
	sol::table *events = GetLuaEvents();
	if (events == nullptr) {
		return;
	}

	const auto trigger = events->traverse_get<std::optional<sol::object>>(name, "trigger");
	if (!trigger.has_value() || !trigger->is<sol::protected_function>()) {
		LogError("events.{}.trigger is not a function", name);
		return;
	}
	const sol::protected_function fn = trigger->as<sol::protected_function>();
	SafeCallResult(fn(std::forward<Args>(args)...), /*optional=*/true);
}

template <typename T, typename... Args>
T CallLuaEventReturn(T defaultValue, std::string_view name, Args &&...args)
{
	sol::table *events = GetLuaEvents();
	if (events == nullptr) {
		return defaultValue;
	}

	const auto trigger = events->traverse_get<std::optional<sol::object>>(name, "trigger");
	if (!trigger.has_value() || !trigger->is<sol::protected_function>()) {
		return defaultValue;
	}
	const sol::protected_function fn = trigger->as<sol::protected_function>();
	sol::object result = SafeCallResult(fn(std::forward<Args>(args)...), /*optional=*/true);
	if (result.is<T>()) {
		return result.as<T>();
	}
	return defaultValue;
}

void MonsterDataLoaded()
{
	CallLuaEvent("MonsterDataLoaded");
}
void UniqueMonsterDataLoaded()
{
	CallLuaEvent("UniqueMonsterDataLoaded");
}
void ItemDataLoaded()
{
	CallLuaEvent("ItemDataLoaded");
}
void UniqueItemDataLoaded()
{
	CallLuaEvent("UniqueItemDataLoaded");
}
void SpellDataLoaded()
{
	CallLuaEvent("SpellDataLoaded");
}
void PlayerDataLoaded()
{
	CallLuaEvent("PlayerDataLoaded");
}

void StoreOpened(std::string_view name)
{
	CallLuaEvent("StoreOpened", name);
}

void OnMonsterTakeDamage(const Monster *monster, int damage, int damageType)
{
	CallLuaEvent("OnMonsterTakeDamage", monster, damage, damageType);
}

void OnMonsterDeath(const Monster *monster)
{
	CallLuaEvent("OnMonsterDeath", monster);
}

void OnSpellCast(const Player *player, int spellId, int spellType, const Monster *targetMonster, int targetX, int targetY)
{
	// For scroll casts, resolve which specific scroll item was used so Lua can
	// distinguish between multiple scrolls of the same spell in inventory.
	uint32_t scrollSeed = 0;
	if (spellType == static_cast<int>(SpellType::Scroll) && player != nullptr) {
		const int8_t spellFrom = player->queuedSpell.spellFrom;
		if (spellFrom >= INVITEM_INV_FIRST && spellFrom <= INVITEM_INV_LAST) {
			const Item &item = player->InvList[spellFrom - INVITEM_INV_FIRST];
			if (!item.isEmpty()) scrollSeed = item._iSeed;
		} else if (spellFrom >= INVITEM_BELT_FIRST && spellFrom <= INVITEM_BELT_LAST) {
			const Item &item = player->SpdList[spellFrom - INVITEM_BELT_FIRST];
			if (!item.isEmpty()) scrollSeed = item._iSeed;
		}
		// spellFrom == 0 (cast via spell selection): find first matching scroll.
		if (scrollSeed == 0) {
			const auto spellIdEnum = static_cast<SpellID>(spellId);
			for (int i = 0; i < player->_pNumInv && scrollSeed == 0; i++) {
				const Item &item = player->InvList[i];
				if (!item.isEmpty() && item.isScrollOf(spellIdEnum))
					scrollSeed = item._iSeed;
			}
			for (int i = 0; i < MaxBeltItems && scrollSeed == 0; i++) {
				const Item &item = player->SpdList[i];
				if (!item.isEmpty() && item.isScrollOf(spellIdEnum))
					scrollSeed = item._iSeed;
			}
		}
	}
	CallLuaEvent("OnSpellCast", player, spellId, spellType, targetMonster, scrollSeed, targetX, targetY);
}

void OnPlayerGainExperience(const Player *player, uint32_t exp)
{
	CallLuaEvent("OnPlayerGainExperience", player, exp);
}
void OnPlayerTakeDamage(const Player *player, int damage, int damageType)
{
	CallLuaEvent("OnPlayerTakeDamage", player, damage, damageType);
}

void LoadModsComplete()
{
	CallLuaEvent("LoadModsComplete");
}
void GameDrawComplete()
{
	CallLuaEvent("GameDrawComplete");
}
void GameStart()
{
	CallLuaEvent("GameStart");
}
void OnLevelExit()
{
	CallLuaEvent("OnLevelExit");
}

} // namespace lua

} // namespace devilution
