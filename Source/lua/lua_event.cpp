#include "lua/lua_event.hpp"

#include <optional>
#include <string_view>
#include <utility>
#include <vector>

#include <sol/sol.hpp>

#include "inv.h"
#include "items.h"
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

bool OnGolemCanTargetMonster(const Monster *ally, const Monster *candidate, bool hasLOS, bool defaultValue)
{
	return CallLuaEventReturn<bool>(defaultValue, "OnGolemCanTargetMonster", ally, candidate, hasLOS);
}

bool OnGolemCanChaseTarget(const Monster *ally, const Monster *target, bool defaultValue)
{
	return CallLuaEventReturn<bool>(defaultValue, "OnGolemCanChaseTarget", ally, target);
}

bool OnGolemCanSelect(const Monster *monster, bool defaultValue)
{
	return CallLuaEventReturn<bool>(defaultValue, "OnGolemCanSelect", monster);
}

std::optional<std::optional<Point>> OnGolemIdle(const Monster *golem, bool hasTarget, Point enemyPosition)
{
	sol::table *events = GetLuaEvents();
	if (events == nullptr) return std::nullopt;
	const auto trigger = events->traverse_get<std::optional<sol::object>>("OnGolemIdle", "trigger");
	if (!trigger.has_value() || !trigger->is<sol::protected_function>()) return std::nullopt;
	const sol::protected_function fn = trigger->as<sol::protected_function>();
	sol::object result = SafeCallResult(fn(golem, hasTarget, enemyPosition), /*optional=*/true);
	if (result.is<Point>()) return std::optional<Point>{ result.as<Point>() };          // walk toward Point
	if (result.get_type() != sol::type::lua_nil) return std::optional<Point>{};         // any non-nil = stand still (false, true, etc.)
	return std::nullopt;                                                                  // nil = engine default
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
void OnCustomItemRecreated(Item &item)
{
	CallLuaEvent("OnCustomItemRecreated", &item);
}

int8_t OnGetAnimationSkipFrames(const Player *player, std::string_view animType, int8_t defaultSkip)
{
	return static_cast<int8_t>(CallLuaEventReturn<int>(static_cast<int>(defaultSkip), "OnGetAnimationSkipFrames", player, std::string(animType), static_cast<int>(defaultSkip)));
}

int8_t OnGetPlayerIdleFrames(const Player *player, int weaponGraphic, bool isInTown)
{
	return static_cast<int8_t>(CallLuaEventReturn<int>(0, "OnGetPlayerIdleFrames", player, weaponGraphic, isInTown));
}

void GameStart()
{
	CallLuaEvent("GameStart");
}
void OnNewCharacter(const Player &player)
{
	// MyPlayer is null during character creation (pfile_ui_save_create fires before NetInit).
	// CreatePlayer is only ever called for the local player, so always fire the event.
	if (MyPlayer != nullptr && &player != MyPlayer) return;
	CallLuaEvent("OnNewCharacter", &player);
}
void OnCreatePlrItems(Player &player)
{
	CallLuaEvent("OnCreatePlrItems", &player);
}

void OnLevelExit()
{
	CallLuaEvent("OnLevelExit");
}
void OnLevelEnter()
{
	CallLuaEvent("OnLevelEnter");
}

bool OnCanPlayerUseItem(const Player *player, const Item *item, bool defaultValue)
{
	return CallLuaEventReturn<bool>(defaultValue, "OnCanPlayerUseItem", player, item);
}

int OnGetMaxAttributeValue(const Player *player, std::string_view attribute, int defaultValue)
{
	return CallLuaEventReturn<int>(defaultValue, "OnGetMaxAttributeValue", player, std::string(attribute), defaultValue);
}

int OnGetPlayerDamageMod(const Player *player, int strMod, int strDexMod, int totalVit, bool isHoldingBow, bool isHoldingShield, bool isHoldingStaff, bool isUnarmed, int defaultValue)
{
	return CallLuaEventReturn<int>(defaultValue, "OnGetPlayerDamageMod", player, strMod, strDexMod, totalVit, isHoldingBow, isHoldingShield, isHoldingStaff, isUnarmed);
}

int OnGetManaCost(const Player *player, int baseCost, int defaultValue)
{
	return CallLuaEventReturn<int>(defaultValue, "OnGetManaCost", player, baseCost);
}

bool OnPlayerHasCriticalStrike(const Player *player, bool defaultValue)
{
	return CallLuaEventReturn<bool>(defaultValue, "OnPlayerHasCriticalStrike", player);
}

bool OnPlayerHasIronSkin(const Player *player, bool defaultValue)
{
	return CallLuaEventReturn<bool>(defaultValue, "OnPlayerHasIronSkin", player);
}

bool OnPlayerHasNaturalResistance(const Player *player, bool defaultValue)
{
	return CallLuaEventReturn<bool>(defaultValue, "OnPlayerHasNaturalResistance", player);
}

int OnGetBowDamageMod(const Player *player, int fullMod, int defaultValue)
{
	return CallLuaEventReturn<int>(defaultValue, "OnGetBowDamageMod", player, fullMod);
}

int OnGetArrowVelocityBonus(const Player *player, int defaultValue)
{
	return CallLuaEventReturn<int>(defaultValue, "OnGetArrowVelocityBonus", player);
}

bool OnPlayerCanBlockWithoutShield(const Player *player, bool isHoldingStaff, bool isUnarmed, bool defaultValue)
{
	return CallLuaEventReturn<bool>(defaultValue, "OnPlayerCanBlockWithoutShield", player, isHoldingStaff, isUnarmed);
}

int OnGetArmorLevelBonus(const Player *player, std::string_view armorType, bool isUnique, int defaultValue)
{
	return CallLuaEventReturn<int>(defaultValue, "OnGetArmorLevelBonus", player, std::string(armorType), isUnique);
}

int OnGetPotionHealAmount(const Player *player, int l, int defaultValue)
{
	return CallLuaEventReturn<int>(defaultValue, "OnGetPotionHealAmount", player, l);
}

int OnGetPotionManaAmount(const Player *player, int l, int defaultValue)
{
	return CallLuaEventReturn<int>(defaultValue, "OnGetPotionManaAmount", player, l);
}

bool OnPlayerHasArmorPierce(const Player *player, bool defaultValue)
{
	return CallLuaEventReturn<bool>(defaultValue, "OnPlayerHasArmorPierce", player);
}

bool OnPlayerCanCleave(const Player *player, bool isHoldingAxe, bool isHoldingTwoHandedHeavy, bool isHoldingStaff, bool defaultValue)
{
	return CallLuaEventReturn<bool>(defaultValue, "OnPlayerCanCleave", player, isHoldingAxe, isHoldingTwoHandedHeavy, isHoldingStaff);
}

int OnGetHitRecoveryThreshold(const Player *player, int defaultThreshold)
{
	return CallLuaEventReturn<int>(defaultThreshold, "OnGetHitRecoveryThreshold", player, defaultThreshold);
}

std::pair<int, int> OnGetUnarmedDamageFloor(const Player *player, int minDamage, int maxDamage)
{
	sol::table *events = GetLuaEvents();
	if (events == nullptr) return { minDamage, maxDamage };
	const auto trigger = events->traverse_get<std::optional<sol::object>>("OnGetUnarmedDamageFloor", "trigger");
	if (!trigger.has_value() || !trigger->is<sol::protected_function>()) return { minDamage, maxDamage };
	const sol::protected_function fn = trigger->as<sol::protected_function>();
	sol::object result = SafeCallResult(fn(player, minDamage, maxDamage), /*optional=*/true);
	if (!result.is<sol::table>()) return { minDamage, maxDamage };
	const sol::table tbl = result.as<sol::table>();
	return { tbl.get_or(1, minDamage), tbl.get_or(2, maxDamage) };
}

int OnGetBlockChanceBonus(const Player *player, int blockBonus)
{
	return CallLuaEventReturn<int>(blockBonus, "OnGetBlockChanceBonus", player, blockBonus);
}

void OnOilyShrine(const Player *player)
{
	CallLuaEvent("OnOilyShrine", player);
}

bool OnShouldExcludeWirtItem(const Player *player, int itemTypeInt, bool defaultValue)
{
	std::string_view typeName;
	switch (static_cast<ItemType>(itemTypeInt)) {
	case ItemType::LightArmor:  typeName = "LightArmor";  break;
	case ItemType::MediumArmor: typeName = "MediumArmor"; break;
	case ItemType::HeavyArmor:  typeName = "HeavyArmor";  break;
	case ItemType::Shield:      typeName = "Shield";       break;
	case ItemType::Axe:         typeName = "Axe";          break;
	case ItemType::Bow:         typeName = "Bow";          break;
	case ItemType::Mace:        typeName = "Mace";         break;
	case ItemType::Sword:       typeName = "Sword";        break;
	case ItemType::Helm:        typeName = "Helm";         break;
	case ItemType::Staff:       typeName = "Staff";        break;
	case ItemType::Ring:        typeName = "Ring";         break;
	case ItemType::Amulet:      typeName = "Amulet";       break;
	default:                    return defaultValue;
	}
	return CallLuaEventReturn<bool>(defaultValue, "OnShouldExcludeWirtItem", player, std::string(typeName));
}

std::string OnGetPlayerArmorGraphic(const Player *player, std::string_view defaultGraphic)
{
	return CallLuaEventReturn<std::string>(std::string(defaultGraphic), "OnGetPlayerArmorGraphic", player, std::string(defaultGraphic));
}

void OnItemUsed(const Player &player, int mid, int spellID)
{
	CallLuaEvent("OnItemUsed", &player, mid, spellID);
}

std::string OnGetMiscItemDescription(const Item *item) // Lua mod support
{
	return CallLuaEventReturn<std::string>(std::string {}, "OnGetMiscItemDescription", item);
}

void OnGolemKilledMonster(const Monster *ally, const Monster *victim)
{
	CallLuaEvent("OnGolemKilledMonster", ally, victim);
}

std::vector<std::string> OnGetMonsterInfo(const Monster *monster) // Lua mod support
{
	sol::table *events = GetLuaEvents();
	if (events == nullptr) return {};
	const auto trigger = events->traverse_get<std::optional<sol::object>>("OnGetMonsterInfo", "trigger");
	if (!trigger.has_value() || !trigger->is<sol::protected_function>()) return {};
	const sol::protected_function fn = trigger->as<sol::protected_function>();
	sol::object result = SafeCallResult(fn(monster), /*optional=*/true);
	if (!result.is<sol::table>()) return {};
	std::vector<std::string> lines;
	const sol::table tbl = result.as<sol::table>();
	for (int i = 1; ; ++i) {
		const sol::optional<std::string> entry = tbl.get<sol::optional<std::string>>(i);
		if (!entry) break;
		lines.push_back(*entry);
	}
	return lines;
}

bool OnMissileCanTargetMonster(const Monster *monster, bool defaultValue) // Lua mod support
{
	return CallLuaEventReturn<bool>(defaultValue, "OnMissileCanTargetMonster", monster);
}

bool OnPlayerAttackMonster(const Player *player, const Monster *monster, bool defaultValue) // Lua mod support
{
	return CallLuaEventReturn<bool>(defaultValue, "OnPlayerAttackMonster", player, monster);
}

bool OnCanSelectMonsterWithCursor(int cursorId, bool defaultValue) // Lua mod support
{
	return CallLuaEventReturn<bool>(defaultValue, "OnCanSelectMonsterWithCursor", cursorId);
}

bool OnCursorMonsterTarget(const Monster *monster, bool defaultValue) // Lua mod support
{
	return CallLuaEventReturn<bool>(defaultValue, "OnCursorMonsterTarget", monster);
}

std::vector<CustomSpeedbookEntry> OnGetCustomSpeedbookScrollEntries(const Player *player)
{
	sol::table *events = GetLuaEvents();
	if (events == nullptr) return {};
	const auto trigger = events->traverse_get<std::optional<sol::object>>("OnGetCustomSpeedbookScrollEntries", "trigger");
	if (!trigger.has_value() || !trigger->is<sol::protected_function>()) return {};
	const sol::protected_function fn = trigger->as<sol::protected_function>();
	sol::object result = SafeCallResult(fn(player), /*optional=*/true);
	if (!result.is<sol::table>()) return {};
	std::vector<CustomSpeedbookEntry> entries;
	const sol::table tbl = result.as<sol::table>();
	for (int i = 1; ; ++i) {
		const sol::optional<sol::table> entry = tbl.get<sol::optional<sol::table>>(i);
		if (!entry) break;
		CustomSpeedbookEntry e;
		e.displayName = entry->get_or("name", std::string {});
		e.scrollSeed = static_cast<uint32_t>(entry->get_or("seed", 0));
		e.spellId = entry->get_or("spell", 0);
		e.scrollCount = entry->get_or("count", -1);
		if (!e.displayName.empty())
			entries.push_back(std::move(e));
	}
	return entries;
}

std::string OnGetSpeedbookSelectionType(const Player *player, int spellId, std::string_view originalType, std::string_view promotedType)
{
	return CallLuaEventReturn<std::string>(std::string(promotedType), "OnGetSpeedbookSelectionType", player, spellId, std::string(originalType), std::string(promotedType));
}

std::string OnGetSpeedbookSpellName(const Player *player, int spellId, std::string_view defaultName)
{
	return CallLuaEventReturn<std::string>(std::string(defaultName), "OnGetSpeedbookSpellName", player, spellId, std::string(defaultName));
}

bool OnShouldHideSpeedbookSpell(const Player *player, int spellId, std::string_view spellType)
{
	return CallLuaEventReturn<bool>(false, "OnShouldHideSpeedbookSpell", player, spellId, std::string(spellType));
}

bool OnCanSelectSpellBookEntry(const Player *player, int spellId)
{
	return CallLuaEventReturn<bool>(true, "OnCanSelectSpellBookEntry", player, spellId);
}

} // namespace lua

} // namespace devilution
