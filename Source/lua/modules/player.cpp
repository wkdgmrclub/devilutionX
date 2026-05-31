#include "lua/modules/player.hpp"

#include <optional>

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
		    for (int i = 0; i < itemCount; i++) {
			    Item tempItem {};
			    SetupAllItems(player, tempItem, itemIndex, AdvanceRndSeed(), 1, 1, true, false);
			    if (!AutoPlaceItemInInventory(player, tempItem, true)) {
				    return false;
			    }
		    }
		    CalcPlrInv(player, true);
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
	LuaSetDocReadonlyProperty(playerType, "lightRadius", "integer",
	    "Player's light radius in tiles (readonly)",
	    [](const Player &player) { return static_cast<int>(player._pLightRad); });
	LuaSetDocFn(playerType, "addScrollByMapping", "(mappingId: integer, seed: integer, name: string) -> boolean",
	    "Add a custom scroll item directly to the player's inventory using a mapping ID, seed, and display name. Returns true if placed successfully, false if inventory is full or item type not found.",
	    [](Player &player, int32_t mappingId, uint32_t seed, const std::string &name) -> bool {
		    const auto it = ItemMappingIdsToIndices.find(mappingId);
		    if (it == ItemMappingIdsToIndices.end()) return false;
		    const auto itemIndex = static_cast<_item_indexes>(it->second);
		    Item item {};
		    GetItemAttrs(item, itemIndex, 1);
		    SetupItem(item);
		    item._iSeed = seed;
		    item._iCreateInfo = 0;
		    item._iIdentified = true;
		    CopyUtf8(item._iName, name, sizeof(item._iName));
		    CopyUtf8(item._iIName, name, sizeof(item._iIName));
		    if (!AutoPlaceItemInInventory(player, item, true)) return false;
		    CalcPlrInv(player, true);
		    return true;
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

	return table;
}

} // namespace devilution
