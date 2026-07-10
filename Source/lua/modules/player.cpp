#include "lua/modules/player.hpp"

#include <algorithm>
#include <optional>

#include <magic_enum/magic_enum.hpp>
#include <sol/sol.hpp>

#include "cursor.h"
#include "data/file.hpp"
#include "effects.h"
#include "engine/backbuffer_state.hpp"
#include "engine/point.hpp"
#include "engine/random.hpp"
#include "inv.h"
#include "items.h"
#include "lua/metadoc.hpp"
#include "msg.h"
#include "multi.h"
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
	    "Player's 0-based index into the Players array (readonly). Matches player.get(id) and monster.ownerPlayerId.",
	    [](const Player &player) {
		    return static_cast<int>(player.getId());
	    });
	LuaSetDocReadonlyProperty(playerType, "position", "Point",
	    "Player's current position (readonly)",
	    [](const Player &player) -> Point {
		    return Point { player.position.tile };
	    });
	LuaSetDocFn(playerType, "isOnActiveLevel", "() -> boolean",
	    "Returns true if this player is on the client's currently-active (rendered) level. Useful for scoping net-message handling to same-level players, since monster slot ids are per-level. // Lua mod support",
	    [](const Player &player) { return player.isOnActiveLevel(); });
	LuaSetDocFn(playerType, "isLevelOwnedByLocalClient", "() -> boolean",
	    "Returns true if the local client is the authority (owner) for this player's current level. Monster spawning is level-owner-authoritative in multiplayer (the engine gates SpawnMonster on this, 'to prevent desyncs in multiplayer'); a non-owner must ask the owner to spawn on its behalf, mirroring the Golem spell's CMD_REQUESTSPAWNGOLEM. // Lua mod support",
	    [](const Player &player) { return player.isLevelOwnedByLocalClient(); });
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
	LuaSetDocReadonlyProperty(playerType, "health", "integer",
	    "Current hit points (readonly)",
	    [](const Player &player) { return player._pHitPoints >> 6; });
	LuaSetDocReadonlyProperty(playerType, "maxHealth", "integer",
	    "Maximum hit points (readonly)",
	    [](const Player &player) { return player._pMaxHP >> 6; });
	LuaSetDocReadonlyProperty(playerType, "lightRadius", "integer",
	    "Player's light radius in tiles (readonly)",
	    [](const Player &player) { return static_cast<int>(player._pLightRad); });
	LuaSetDocReadonlyProperty(playerType, "isMoving", "boolean",
	    "True when the player is currently walking (PM_WALK_*). False during stand, attack, cast, etc. // Lua mod support",
	    [](const Player &player) { return player.isWalking(); });
	LuaSetDocReadonlyProperty(playerType, "strength", "integer",
	    "Base strength stat (readonly)",
	    [](const Player &player) { return static_cast<int>(player._pBaseStr); });
	LuaSetDocReadonlyProperty(playerType, "magic", "integer",
	    "Base magic stat (readonly)",
	    [](const Player &player) { return static_cast<int>(player._pBaseMag); });
	LuaSetDocReadonlyProperty(playerType, "magicCurrent", "integer",
	    "Effective (current) magic stat as shown on the character sheet — base plus equipment bonuses (readonly)",
	    [](const Player &player) { return static_cast<int>(player._pMagic); });
	LuaSetDocReadonlyProperty(playerType, "dexterity", "integer",
	    "Base dexterity stat (readonly)",
	    [](const Player &player) { return static_cast<int>(player._pBaseDex); });
	LuaSetDocReadonlyProperty(playerType, "vitality", "integer",
	    "Base vitality stat (readonly)",
	    [](const Player &player) { return static_cast<int>(player._pBaseVit); });
	LuaSetDocProperty(playerType, "statPoints", "integer",
	    "Unspent stat points (_pStatPts). Writable: the hero file stores this as a single byte, so a mod granting more than 255 points must persist the true value itself (e.g. via OnSavePlayerData) and write it back on load.",
	    [](const Player &player) { return player._pStatPts; },
	    [](Player &player, int value) { player._pStatPts = std::max(value, 0); });
	// Effective combat stats as shown on the character sheet (readonly). These read the player's
	// already-accumulated combat accessors/fields (GetArmor/GetMeleeToHit/GetRangedToHit and the
	// CalcPlrInv-cached _pI* damage fields) and combine them exactly as charpanel.cpp does for
	// display — no inventory iteration of our own. // Lua mod support
	LuaSetDocReadonlyProperty(playerType, "armorClass", "integer",
	    "Effective armor class as shown on the character sheet (readonly)",
	    [](const Player &player) { return player.GetArmor() + (player.getCharacterLevel() * 2); });
	LuaSetDocReadonlyProperty(playerType, "toHit", "integer",
	    "Effective to-hit percentage as shown on the character sheet (ranged when a bow is equipped, else melee) (readonly)",
	    [](const Player &player) {
		    return player.UsesRangedWeapon() ? player.GetRangedToHit() : player.GetMeleeToHit();
	    });
	LuaSetDocReadonlyProperty(playerType, "minDamage", "integer",
	    "Effective minimum attack damage as shown on the character sheet (readonly)",
	    [](const Player &player) {
		    int damageMod = player._pIBonusDamMod;
		    damageMod += (player.UsesRangedWeapon() && player._pClass != HeroClass::Rogue) ? player._pDamageMod / 2 : player._pDamageMod;
		    return player._pIMinDam + (player._pIBonusDam * player._pIMinDam / 100) + damageMod;
	    });
	LuaSetDocReadonlyProperty(playerType, "maxDamage", "integer",
	    "Effective maximum attack damage as shown on the character sheet (readonly)",
	    [](const Player &player) {
		    int damageMod = player._pIBonusDamMod;
		    damageMod += (player.UsesRangedWeapon() && player._pClass != HeroClass::Rogue) ? player._pDamageMod / 2 : player._pDamageMod;
		    return player._pIMaxDam + (player._pIBonusDam * player._pIMaxDam / 100) + damageMod;
	    });
	LuaSetDocReadonlyProperty(playerType, "className", "string",
	    "Player class name (readonly)",
	    [](const Player &player) -> std::string { return std::string(GetPlayerDataForClass(player._pClass).className); });
	LuaSetDocReadonlyProperty(playerType, "friendlyMode", "boolean",
	    "Whether this player is in friendly (non-hostile) mode. False = hostile, i.e. PvP is enabled toward other players. readonly",
	    [](const Player &player) -> bool { return player.friendlyMode; });
	LuaSetDocReadonlyProperty(playerType, "isHoldingShield", "boolean",
	    "Whether a shield is currently equipped in either hand (readonly)",
	    [](const Player &player) -> bool { return player.isHoldingItem(ItemType::Shield); });
	LuaSetDocReadonlyProperty(playerType, "weaponGraphic", "integer",
	    "The PlayerWeaponGraphic id of the currently equipped weapon combo (Unarmed=0, UnarmedShield=1, Sword=2, SwordShield=3, Bow=4, Axe=5, Mace=6, MaceShield=7, Staff=8) — the low nibble of _pgfxnum, i.e. the weapon sheet the player's animations play (readonly)",
	    [](const Player &player) { return static_cast<int>(player._pgfxnum & 0xF); });
	LuaSetDocFn(playerType, "addScrollByMapping", "(mappingId: integer, seed: integer, name: string, dwBuff?: integer, modData?: string) -> boolean",
	    "Add a custom scroll item directly to the player's inventory using a mapping ID, seed, and display name. Optional dwBuff sets item.dwBuff (preserved through save/load). Optional modData sets item.modData (binary-safe blob; base game ignores it, not saved to the hero file). Returns true if placed successfully, false if inventory is full or item type not found.",
	    [](Player &player, int32_t mappingId, uint32_t seed, const std::string &name, sol::optional<uint32_t> buffOverride, sol::optional<std::string> modDataOverride) -> bool {
		    const auto it = ItemMappingIdsToIndices.find(mappingId);
		    if (it == ItemMappingIdsToIndices.end()) return false;
		    const auto itemIndex = static_cast<_item_indexes>(it->second);
		    Item item {};
		    GetItemAttrs(item, itemIndex, 1);
		    SetupItem(item);
		    item._iIdentified = true;
		    item._iSeed = seed;
		    item._iCreateInfo = 0;
		    if (buffOverride.has_value()) item.dwBuff = *buffOverride; // Lua mod support
		    if (modDataOverride.has_value()) item._iModData = *modDataOverride; // Lua mod support
		    CopyUtf8(item._iName, name, sizeof(item._iName));
		    CopyUtf8(item._iIName, name, sizeof(item._iIName));
		    if (!AutoPlaceItemInInventory(player, item, false)) return false;
		    CalcPlrInv(player, true);
		    return true;
	    });
	LuaSetDocFn(playerType, "heldItem", "() -> Item|nil",
	    "Return the Item currently held on the cursor (HoldItem), or nil if the hand is empty. The Item is passed by reference; modifications are live.",
	    [](Player &player) -> Item * {
		    if (player.HoldItem.isEmpty())
			    return nullptr;
		    return &player.HoldItem;
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
	LuaSetDocFn(playerType, "findScrollSlotBySeed", "(seed: integer) -> integer|nil",
	    "Return the INVITEM_* slot index (inventory 7-46, belt 47-54) of the item whose _iSeed matches the given seed, or nil if not found.",
	    [](Player &player, uint32_t seed) -> std::optional<int> {
		    for (int i = 0; i < player._pNumInv; i++) {
			    if (!player.InvList[i].isEmpty() && player.InvList[i]._iSeed == seed)
				    return INVITEM_INV_FIRST + i;
		    }
		    for (int i = 0; i < MaxBeltItems; i++) {
			    if (!player.SpdList[i].isEmpty() && player.SpdList[i]._iSeed == seed)
				    return INVITEM_BELT_FIRST + i;
		    }
		    return std::nullopt;
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
	LuaSetDocFn(playerType, "creditDiabloKill", "()",
	    "Raise this player's Diablo kill level (pDiabloKillLevel) to the current game difficulty — the "
	    "difficulty-unlock credit the engine grants when Diablo dies (DiabloDeath/PrepDoEnding). Idempotent "
	    "(max, never lowers). Only meaningful for the local player: the field is hero save-file state. // Lua mod support",
	    [](Player &player) {
		    player.pDiabloKillLevel = std::max(player.pDiabloKillLevel, static_cast<uint8_t>(sgGameInitInfo.nDifficulty + 1));
	    });
	LuaSetDocFn(playerType, "enterHealOtherMode", "()",
	    "Switch the cursor to CURSOR_HEALOTHER targeting mode.",
	    [](const Player & /*player*/) {
		    NewCursor(CURSOR_HEALOTHER);
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
	LuaSetDocFn(playerType, "classBaseStats", "() -> integer, integer, integer, integer",
	    "Return the class starting base stats as (str, mag, dex, vit). Useful for stat-reset items.",
	    [](const Player &player) -> std::tuple<int, int, int, int> {
		    const ClassAttributes &attr = player.getClassAttributes();
		    return { attr.baseStr, attr.baseMag, attr.baseDex, attr.baseVit };
	    });
	LuaSetDocFn(playerType, "resetStats", "(str: integer, mag: integer, dex: integer, vit: integer)",
	    "Reset all base stats to the given values, refund the invested difference back to _pStatPts, and recompute max HP/mana from scratch to correct any drift (Black Death, shrine side-effects). Sends net sync messages.",
	    [](Player &player, int str, int mag, int dex, int vit) {
		    // Compute the total invested points to refund before wiping stats.
		    const int refund = (player._pBaseStr - str) + (player._pBaseMag - mag)
		        + (player._pBaseDex - dex) + (player._pBaseVit - vit);

		    player._pBaseStr = str; player._pStrength = str;
		    player._pBaseMag = mag; player._pMagic = mag;
		    player._pBaseDex = dex; player._pDexterity = dex;
		    player._pBaseVit = vit; player._pVitality = vit;

		    if (refund > 0) player._pStatPts += refund;

		    // Recompute HP/mana bases from the class formula so drift (Black Death,
		    // shrine side-effects) is corrected rather than carried forward.
		    const int32_t correctHPBase = player.calculateBaseLife();
		    player._pMaxHPBase = correctHPBase;
		    player._pHPBase = std::min(player._pHPBase, correctHPBase);

		    const int32_t correctManaBase = player.calculateBaseMana();
		    player._pMaxManaBase = correctManaBase;
		    player._pManaBase = std::min(player._pManaBase, correctManaBase);

		    CheckStats(player);
		    CalcPlrInv(player, true);

		    if (&player == MyPlayer) {
			    NetSendCmdParam1(false, CMD_SETSTR, player._pBaseStr);
			    NetSendCmdParam1(false, CMD_SETMAG, player._pBaseMag);
			    NetSendCmdParam1(false, CMD_SETDEX, player._pBaseDex);
			    NetSendCmdParam1(false, CMD_SETVIT, player._pBaseVit);
		    }
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
	LuaSetDocFn(table, "get", "(id: integer) -> Player|nil",
	    "The player with the given id (0-based index into the Players array), or nil if the id is out of range or that player is not active.",
	    [](int id) -> Player * {
		    if (id < 0 || static_cast<size_t>(id) >= Players.size())
			    return nullptr;
		    Player &player = Players[id];
		    if (!player.plractive)
			    return nullptr;
		    return &player;
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

	// Expose cursor_id enum so mods can compare cursor IDs in OnCanSelectMonsterWithCursor and similar hooks.
	sol::table cursorIdTable = lua.create_table();
	for (const auto val : magic_enum::enum_values<cursor_id>()) {
		cursorIdTable[std::string(magic_enum::enum_name(val))] = static_cast<int>(val);
	}
	table["CursorID"] = cursorIdTable;

	return table;
}

} // namespace devilution
