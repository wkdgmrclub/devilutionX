#include "lua/modules/player.hpp"

#include <optional>

#include <magic_enum/magic_enum.hpp>
#include <sol/sol.hpp>

#include "data/file.hpp"
#include "effects.h"
#include "engine/backbuffer_state.hpp"
#include "engine/point.hpp"
#include "engine/random.hpp"
#include "inv.h"
#include "items.h"
#include "lua/metadoc.hpp"
#include "player.h"
#include "spells.h"
#include "tables/itemdat.h"
#include "tables/playerdat.hpp"
#include "utils/utf8.hpp"

namespace devilution {
namespace {

void InitPlayerUserType(sol::state_view &lua)
{
	sol::usertype<Player> playerType = lua.new_usertype<Player>(sol::no_constructor);
	LuaSetDocReadonlyProperty(playerType, "name", "string",
	    "Player's name (readonly)",
	    &Player::name);
	LuaSetDocReadonlyProperty(playerType, "id", "integer",
	    "Player's unique ID (readonly)",
	    [](const Player &player) {
		    return static_cast<int>(reinterpret_cast<uintptr_t>(&player));
	    });
	LuaSetDocReadonlyProperty(playerType, "position", "Point",
	    "Player's current position (readonly)",
	    [](const Player &player) -> Point {
		    return Point { player.position.tile };
	    });
	LuaSetDocFn(playerType, "addExperience", "(experience: integer, monsterLevel: integer = nil)",
	    "Adds experience to this player based on the current game mode",
	    [](Player &player, uint32_t experience, std::optional<int> monsterLevel) {
		    if (monsterLevel.has_value()) {
			    player.addExperience(experience, *monsterLevel);
		    } else {
			    player.addExperience(experience);
		    }
	    });
	LuaSetDocProperty(playerType, "characterLevel", "number",
	    "Character level (writeable)",
	    &Player::getCharacterLevel, &Player::setCharacterLevel);
	LuaSetDocFn(playerType, "addItem", "(itemId: integer, count: integer = 1)",
	    "Add an item to the player's inventory",
	    [](Player &player, int itemId, std::optional<int> count) -> bool {
		    const auto itemIndex = static_cast<_item_indexes>(itemId);
		    const int itemCount = count.value_or(1);
		    const bool inGame = MyPlayer == &player;
		    for (int i = 0; i < itemCount; i++) {
			    Item tempItem {};
			    SetupAllItems(player, tempItem, itemIndex, AdvanceRndSeed(), 1, 1, true, false);
			    if (!AutoPlaceItemInInventory(player, tempItem, inGame)) {
				    return false;
			    }
		    }
		    CalcPlrInv(player, inGame);
		    return true;
	    });
	LuaSetDocFn(playerType, "hasItem", "(itemId: integer)",
	    "Check if the player has an item with the given ID",
	    [](const Player &player, int itemId) -> bool {
		    return HasInventoryOrBeltItemWithId(player, static_cast<_item_indexes>(itemId));
	    });
	LuaSetDocFn(playerType, "removeItem", "(itemId: integer, count: integer = 1)",
	    "Remove an item from the player's inventory",
	    [](Player &player, int itemId, std::optional<int> count) -> int {
		    const auto targetId = static_cast<_item_indexes>(itemId);
		    const int itemCount = count.value_or(1);
		    int removed = 0;

		    // Remove from inventory
		    for (int i = player._pNumInv - 1; i >= 0 && removed < itemCount; i--) {
			    if (player.InvList[i].IDidx == targetId) {
				    player.RemoveInvItem(i);
				    removed++;
			    }
		    }

		    // Remove from belt if needed
		    for (int i = MaxBeltItems - 1; i >= 0 && removed < itemCount; i--) {
			    if (!player.SpdList[i].isEmpty() && player.SpdList[i].IDidx == targetId) {
				    player.RemoveSpdBarItem(i);
				    removed++;
			    }
		    }

		    if (removed > 0) {
			    CalcPlrInv(player, true);
		    }

		    return removed;
	    });
	LuaSetDocFn(playerType, "restoreFullLife", "()",
	    "Restore player's HP to maximum",
	    [](Player &player) {
		    player._pHitPoints = player._pMaxHP;
		    player._pHPBase = player._pMaxHPBase;
	    });
	LuaSetDocFn(playerType, "restoreFullMana", "()",
	    "Restore player's mana to maximum",
	    [](Player &player) {
		    player._pMana = player._pMaxMana;
		    player._pManaBase = player._pMaxManaBase;
	    });
	LuaSetDocReadonlyProperty(playerType, "mana", "number",
	    "Current mana (readonly)",
	    [](Player &player) { return player._pMana >> 6; });
	LuaSetDocReadonlyProperty(playerType, "maxMana", "number",
	    "Maximum mana (readonly)",
	    [](Player &player) { return player._pMaxMana >> 6; });
	LuaSetDocReadonlyProperty(playerType, "health", "integer",
	    "Current hit points (readonly)",
	    [](const Player &player) { return player._pHitPoints >> 6; });
	LuaSetDocReadonlyProperty(playerType, "maxHealth", "integer",
	    "Maximum hit points (readonly)",
	    [](const Player &player) { return player._pMaxHP >> 6; });
	LuaSetDocReadonlyProperty(playerType, "lightRadius", "integer",
	    "Player's light radius in tiles (readonly)",
	    [](const Player &player) { return static_cast<int>(player._pLightRad); });
	LuaSetDocReadonlyProperty(playerType, "strength", "integer",
	    "Base strength stat (readonly)",
	    [](const Player &player) { return static_cast<int>(player._pBaseStr); });
	LuaSetDocReadonlyProperty(playerType, "magic", "integer",
	    "Base magic stat (readonly)",
	    [](const Player &player) { return static_cast<int>(player._pBaseMag); });
	LuaSetDocReadonlyProperty(playerType, "dexterity", "integer",
	    "Base dexterity stat (readonly)",
	    [](const Player &player) { return static_cast<int>(player._pBaseDex); });
	LuaSetDocReadonlyProperty(playerType, "vitality", "integer",
	    "Base vitality stat (readonly)",
	    [](const Player &player) { return static_cast<int>(player._pBaseVit); });
	LuaSetDocReadonlyProperty(playerType, "className", "string",
	    "Player class name (readonly)",
	    [](const Player &player) -> std::string { return std::string(GetPlayerDataForClass(player._pClass).className); });
	LuaSetDocFn(playerType, "addScrollByMapping", "(mappingId: integer, seed: integer, name: string, dwBuff?: integer) -> boolean",
	    "Add a custom scroll item directly to the player's inventory using a mapping ID, seed, and display name. Optional dwBuff sets item.dwBuff (preserved through save/load). Returns true if placed successfully, false if inventory is full or item type not found.",
	    [](Player &player, int32_t mappingId, uint32_t seed, const std::string &name, sol::optional<uint32_t> buffOverride) -> bool {
		    const auto it = ItemMappingIdsToIndices.find(mappingId);
		    if (it == ItemMappingIdsToIndices.end()) return false;
		    const auto itemIndex = static_cast<_item_indexes>(it->second);
		    const bool inGame = MyPlayer == &player;
		    Item item {};
		    GetItemAttrs(item, itemIndex, 1);
		    // SetupItem accesses Players[MyPlayerId], which is uninitialized during character creation. Lua mod support
		    if (inGame) SetupItem(item);
		    item._iSeed = seed;
		    item._iCreateInfo = 0;
		    if (buffOverride.has_value()) item.dwBuff = *buffOverride; // Lua mod support
		    CopyUtf8(item._iName, name, sizeof(item._iName));
		    CopyUtf8(item._iIName, name, sizeof(item._iIName));
		    if (!AutoPlaceItemInInventory(player, item, inGame)) return false;
		    if (inGame) CalcPlrInv(player, true);
		    return true;
	    });
	LuaSetDocFn(playerType, "findScrollBySeed", "(seed: integer) -> Item|nil",
	    "Return the Item in inventory or belt whose _iSeed matches the given seed, or nil if not found.",
	    [](Player &player, uint32_t seed) -> Item * {
		    for (int i = 0; i < player._pNumInv; i++) {
			    if (!player.InvList[i].isEmpty() && player.InvList[i]._iSeed == seed)
				    return &player.InvList[i];
		    }
		    for (int i = 0; i < MaxBeltItems; i++) {
			    if (!player.SpdList[i].isEmpty() && player.SpdList[i]._iSeed == seed)
				    return &player.SpdList[i];
		    }
		    return nullptr;
	    });
	LuaSetDocFn(playerType, "iterateInventory", "(callback: function) -> void",
	    "Call callback(item) for each non-empty Item in the player's inventory and belt. The Item usertype is passed by reference; modifications are live.",
	    [](Player &player, sol::function callback) {
		    for (int i = 0; i < player._pNumInv; i++) {
			    if (!player.InvList[i].isEmpty())
				    callback(&player.InvList[i]);
		    }
		    for (int i = 0; i < MaxBeltItems; i++) {
			    if (!player.SpdList[i].isEmpty())
				    callback(&player.SpdList[i]);
		    }
	    });
	LuaSetDocFn(playerType, "say", "(speechId: integer)",
	    "Play the player's voice line for the given HeroSpeech enum ID",
	    [](const Player &player, int speechId) {
		    player.Say(static_cast<HeroSpeech>(speechId));
	    });
	LuaSetDocFn(playerType, "modifyStat", "(name: string, amount: integer)",
	    "Increase a base stat by the given amount. name is \"Strength\", \"Magic\", \"Dexterity\", or \"Vitality\". Recalculates inventory after modification.",
	    [](Player &player, const std::string_view name, int amount) {
		    if (name == "Strength") ModifyPlrStr(player, amount);
		    else if (name == "Magic") ModifyPlrMag(player, amount);
		    else if (name == "Dexterity") ModifyPlrDex(player, amount);
		    else if (name == "Vitality") ModifyPlrVit(player, amount);
		    CheckStats(player);
		    CalcPlrInv(player, true);
	    });
	LuaSetDocFn(playerType, "addSkill", "(spellId: integer)",
	    "Add a skill to the player's ability bitmask (_pAblSpells). Idempotent — safe to call every GameStart.",
	    [](Player &player, int spellIdInt) {
		    player._pAblSpells |= GetSpellBitmask(static_cast<SpellID>(spellIdInt));
	    });
	LuaSetDocFn(playerType, "findScrollSeedOf", "(spellId: integer) -> integer|nil",
	    "Return the _iSeed of the first scroll in inventory or belt matching the given spell ID, or nil if none found.",
	    [](const Player &player, int spellIdInt) -> sol::optional<uint32_t> {
		    const auto spellId = static_cast<SpellID>(spellIdInt);
		    for (int i = 0; i < player._pNumInv; i++) {
			    const Item &item = player.InvList[i];
			    if (!item.isEmpty() && item._iMiscId == IMISC_SCROLL && item._iSpell == spellId)
				    return item._iSeed;
		    }
		    for (int i = 0; i < MaxBeltItems; i++) {
			    const Item &item = player.SpdList[i];
			    if (!item.isEmpty() && item._iMiscId == IMISC_SCROLL && item._iSpell == spellId)
				    return item._iSeed;
		    }
		    return sol::nullopt;
	    });
}
} // namespace

sol::table LuaPlayerModule(sol::state_view &lua)
{
	InitPlayerUserType(lua);
	sol::table table = lua.create_table();
	LuaSetDocFn(table, "self", "()",
	    "The current player",
	    []() {
		    return MyPlayer;
	    });
	LuaSetDocFn(table, "walk_to", "(x: integer, y: integer)",
	    "Walk to the given coordinates",
	    [](int x, int y) {
		    NetSendCmdLoc(MyPlayerId, true, CMD_WALKXY, Point { x, y });
	    });
	LuaSetDocFn(table, "addClassDataFromTsv", "(path: string)",
	    "Register a new player class from a classdat-format TSV file. Call this inside a PlayerDataLoaded handler.",
	    [](const std::string_view path) {
		    DataFile dataFile = DataFile::loadOrDie(path);
		    LoadClassDatFromFile(dataFile, path);
	    });

	// Expose HeroSpeech enum so mods can trigger class-appropriate voice lines.
	sol::table heroSpeechTable = lua.create_table();
	for (const auto val : magic_enum::enum_values<HeroSpeech>()) {
		heroSpeechTable[std::string(magic_enum::enum_name(val))] = static_cast<int>(val);
	}
	table["HeroSpeech"] = heroSpeechTable;

	return table;
}

} // namespace devilution
