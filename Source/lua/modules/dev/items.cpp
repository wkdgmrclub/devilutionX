#ifdef _DEBUG
#include "lua/modules/dev/items.hpp"

#include <random>
#include <string>

#include <sol/sol.hpp>

#include "cursor.h"
#include "engine/random.hpp"
#include "items.h"
#include "lua/metadoc.hpp"
#include "pack.h"
#include "player.h"
#include "utils/is_of.hpp"
#include "utils/str_case.hpp"
#include "utils/str_cat.hpp"

namespace devilution {

namespace {

sol::state_view *LuaState = nullptr;

std::string DebugCmdItemInfo()
{
	Player &myPlayer = *MyPlayer;
	Item *pItem = nullptr;
	if (!myPlayer.HoldItem.isEmpty()) {
		pItem = &myPlayer.HoldItem;
	} else if (pcursinvitem != -1) {
		if (pcursinvitem <= INVITEM_INV_LAST)
			pItem = &myPlayer.InvList[pcursinvitem - INVITEM_INV_FIRST];
		else
			pItem = &myPlayer.SpdList[pcursinvitem - INVITEM_BELT_FIRST];
	} else if (pcursitem != -1) {
		pItem = &Items[pcursitem];
	}
	if (pItem != nullptr) {
		std::string_view netPackValidation { "N/A" };
		if (gbIsMultiplayer) {
			ItemNetPack itemPack;
			Item unpacked;
			PackNetItem(*pItem, itemPack);
			netPackValidation = UnPackNetItem(myPlayer, itemPack, unpacked) ? "Success" : "Failure";
		}
		return StrCat("Name: ", pItem->_iIName,
		    "\nIDidx: ", pItem->IDidx, " (", AllItemsList[pItem->IDidx].iName, ")",
		    "\nSeed: ", pItem->_iSeed,
		    "\nCreateInfo: ", pItem->_iCreateInfo,
		    "\nLevel: ", pItem->_iCreateInfo & CF_LEVEL,
		    "\nOnly Good: ", ((pItem->_iCreateInfo & CF_ONLYGOOD) == 0) ? "False" : "True",
		    "\nUnique Monster: ", ((pItem->_iCreateInfo & CF_UPER15) == 0) ? "False" : "True",
		    "\nDungeon Item: ", ((pItem->_iCreateInfo & CF_UPER1) == 0) ? "False" : "True",
		    "\nUnique Item: ", ((pItem->_iCreateInfo & CF_UNIQUE) == 0) ? "False" : "True",
		    "\nSmith: ", ((pItem->_iCreateInfo & CF_SMITH) == 0) ? "False" : "True",
		    "\nSmith Premium: ", ((pItem->_iCreateInfo & CF_SMITHPREMIUM) == 0) ? "False" : "True",
		    "\nBoy: ", ((pItem->_iCreateInfo & CF_BOY) == 0) ? "False" : "True",
		    "\nWitch: ", ((pItem->_iCreateInfo & CF_WITCH) == 0) ? "False" : "True",
		    "\nHealer: ", ((pItem->_iCreateInfo & CF_HEALER) == 0) ? "False" : "True",
		    "\nPregen: ", ((pItem->_iCreateInfo & CF_PREGEN) == 0) ? "False" : "True",
		    "\nNet Validation: ", netPackValidation);
	}
	return StrCat("Num items: ", ActiveItemCount);
}

std::mt19937 BetterRng;
std::string DebugSpawnItem(std::string itemName)
{
	if (ActiveItemCount >= MAXITEMS) return "No space to generate the item!";

	const int max_time = 3000;
	const int max_iter = 1000000;

	AsciiStrToLower(itemName);

	Item testItem;

	uint32_t begin = SDL_GetTicks();
	int i = 0;
	for (;; i++) {
		// using a better rng here to seed the item to prevent getting stuck repeating same values using old one
		std::uniform_int_distribution<int32_t> dist(0, INT_MAX);
		SetRndSeed(dist(BetterRng));
		if (SDL_GetTicks() - begin > max_time)
			return StrCat("Item not found in ", max_time / 1000, " seconds!");

		if (i > max_iter)
			return StrCat("Item not found in ", max_iter, " tries!");

		const int8_t monsterLevel = dist(BetterRng) % CF_LEVEL + 1;
		_item_indexes idx = RndItemForMonsterLevel(monsterLevel);
		if (IsAnyOf(idx, IDI_NONE, IDI_GOLD))
			continue;

		testItem = {};
		SetupAllItems(*MyPlayer, testItem, idx, AdvanceRndSeed(), monsterLevel, 1, false, false);
		TryRandomUniqueItem(testItem, idx, monsterLevel, 1, false, false);
		SetupItem(testItem);

		std::string tmp = AsciiStrToLower(testItem._iIName);
		if (tmp.find(itemName) != std::string::npos)
			break;
	}

	int ii = AllocateItem();
	auto &item = Items[ii];
	item = testItem.pop();
	item._iIdentified = true;
	Point pos = MyPlayer->position.tile;
	GetSuperItemSpace(pos, ii);
	NetSendCmdPItem(false, CMD_SPAWNITEM, item.position, item);
	return StrCat("Item generated successfully - iterations: ", i);
}

std::string DebugSpawnUniqueItem(std::string itemName)
{
	if (ActiveItemCount >= MAXITEMS) return "No space to generate the item!";

	AsciiStrToLower(itemName);
	UniqueItem uniqueItem;
	bool foundUnique = false;
	int uniqueIndex = 0;
	for (int j = 0, n = static_cast<int>(UniqueItems.size()); j < n; ++j) {
		if (!IsUniqueAvailable(j))
			break;

		const std::string tmp = AsciiStrToLower(std::string_view(UniqueItems[j].UIName));
		if (tmp.find(itemName) != std::string::npos) {
			itemName = tmp;
			uniqueItem = UniqueItems[j];
			uniqueIndex = j;
			foundUnique = true;
			break;
		}
	}
	if (!foundUnique) return "No unique item found!";

	_item_indexes uniqueBaseIndex = IDI_GOLD;
	for (std::underlying_type_t<_item_indexes> j = IDI_GOLD; j <= IDI_LAST; j++) {
		if (!IsItemAvailable(j))
			continue;
		if (AllItemsList[j].iItemId == uniqueItem.UIItemId) {
			uniqueBaseIndex = static_cast<_item_indexes>(j);
			break;
		}
	}

	if (uniqueBaseIndex == IDI_GOLD) return "Base item not available!";

	auto &baseItemData = AllItemsList[static_cast<size_t>(uniqueBaseIndex)];

	Item testItem;

	int i = 0;
	for (uint32_t begin = SDL_GetTicks();; i++) {
		constexpr int max_time = 3000;
		if (SDL_GetTicks() - begin > max_time)
			return StrCat("Item not found in ", max_time / 1000, " seconds!");

		constexpr int max_iter = 1000000;
		if (i > max_iter)
			return StrCat("Item not found in ", max_iter, " tries!");

		testItem = {};
		testItem._iMiscId = baseItemData.iMiscId;
		std::uniform_int_distribution<int32_t> dist(0, INT_MAX);
		SetRndSeed(dist(BetterRng));
		for (auto &flag : UniqueItemFlags)
			flag = true;
		UniqueItemFlags[uniqueIndex] = false;
		SetupAllItems(*MyPlayer, testItem, uniqueBaseIndex, testItem._iMiscId == IMISC_UNIQUE ? uniqueIndex : AdvanceRndSeed(), uniqueItem.UIMinLvl, 1, false, false);
		TryRandomUniqueItem(testItem, uniqueBaseIndex, uniqueItem.UIMinLvl, 1, false, false);
		SetupItem(testItem);
		for (auto &flag : UniqueItemFlags)
			flag = false;

		if (testItem._iMagical != ITEM_QUALITY_UNIQUE)
			continue;

		const std::string tmp = AsciiStrToLower(testItem._iIName);
		if (tmp.find(itemName) != std::string::npos)
			break;
		return "Impossible to generate!";
	}

	int ii = AllocateItem();
	auto &item = Items[ii];
	item = testItem.pop();
	Point pos = MyPlayer->position.tile;
	GetSuperItemSpace(pos, ii);
	item._iIdentified = true;
	NetSendCmdPItem(false, CMD_SPAWNITEM, item.position, item);

	return StrCat("Item generated successfully - iterations: ", i);
}

} // namespace

void Lua_OnOilGenerate(Item &item, int maxLvl)
{
	if (LuaState == nullptr)
		return;

	sol::optional<sol::function> callback = (*LuaState)["devilutionx"]["items"]["OnOilGenerate"];

	if (callback) {
		callback.value()(item, maxLvl);
	}
}

sol::table LuaDevItemsModule(sol::state_view &lua)
{
	LuaState = &lua;

	// Retrieve or create the 'devilutionx' table
	sol::table devilutionx = lua["devilutionx"].get_or(lua.create_table());

	// Create a separate 'devItems' table for development item functions
	sol::table devItems = lua.create_table();

	// Register development item functions
	SetDocumented(devItems, "info", "()", "Show info of currently selected item.", &DebugCmdItemInfo);
	SetDocumented(devItems, "spawn", "(name: string)", "Attempt to generate an item.", &DebugSpawnItem);
	SetDocumented(devItems, "spawnUnique", "(name: string)", "Attempt to generate a unique item.", &DebugSpawnUniqueItem);

	// Assign the 'devItems' table to the 'devilutionx' table under the 'devItems' key
	devilutionx["devItems"] = devItems;

	return devItems;
}

// Function to register general item functions
sol::table LuaItemsModule(sol::state_view &lua)
{
	LuaState = &lua;

	// Retrieve or create the 'devilutionx' table
	sol::table devilutionx = lua["devilutionx"].get_or(lua.create_table());

	// Create a separate 'items' table for general item functions
	sol::table items = lua.create_table();

	// Register general item functions
	items.set_function("generateOil", &Lua_OnOilGenerate);
	items.set_function("setItemFlag", [](Item &item, uint32_t flag) { item.dwBuff |= flag; });
	items.set_function("clearItemFlag", [](Item &item, uint32_t flag) { item.dwBuff &= ~flag; });
	items.set_function("hasItemFlag", [](Item &item, uint32_t flag) -> bool { return (item.dwBuff & flag) != 0; });

	// Assign the 'items' table to the 'devilutionx' table under the 'items' key
	devilutionx["items"] = items;

	return items;
}

} // namespace devilution
#endif // _DEBUG
