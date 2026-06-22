#include "lua/modules/items.hpp"

#include <string_view>

#include <fmt/format.h>
#include <sol/sol.hpp>

#include "appfat.h"
#include "cursor.h"
#include "data/file.hpp"
#include "engine/load_cel.hpp"
#include "items.h"
#include "lua/metadoc.hpp"
#include "msg.h"
#include "player.h"
#include "stores.h"
#include "tables/itemdat.h"
#include "utils/utf8.hpp"

namespace devilution {

namespace {

void InitItemUserType(sol::state_view &lua)
{
	// Create a new usertype for Item with no constructor
	sol::usertype<Item> itemType = lua.new_usertype<Item>(sol::no_constructor);

	// Member variables
	LuaSetDocProperty(itemType, "seed", "number", "Randomly generated identifier", &Item::_iSeed);
	LuaSetDocProperty(itemType, "createInfo", "number", "Creation flags", &Item::_iCreateInfo);
	LuaSetDocProperty(itemType, "type", "ItemType", "Item type", &Item::_itype);
	LuaSetDocProperty(itemType, "animFlag", "boolean", "Animation flag", &Item::_iAnimFlag);
	LuaSetDocProperty(itemType, "position", "Point", "Item world position", &Item::position);
	// TODO: Add AnimationInfo usertype
	// LuaSetDocProperty(itemType, "animInfo", "AnimationInfo", "Animation information", &Item::AnimInfo);
	LuaSetDocProperty(itemType, "delFlag", "boolean", "Deletion flag", &Item::_iDelFlag);
	LuaSetDocProperty(itemType, "selectionRegion", "number", "Selection region", &Item::selectionRegion);
	LuaSetDocProperty(itemType, "postDraw", "boolean", "Post-draw flag", &Item::_iPostDraw);
	LuaSetDocProperty(itemType, "identified", "boolean", "Identified flag", &Item::_iIdentified);
	LuaSetDocProperty(itemType, "magical", "number", "Item quality", &Item::_iMagical);
	LuaSetDocProperty(itemType, "name", "string", "Item name", [](const Item &i) { return std::string_view(i._iName); }, [](Item &i, std::string_view val) { CopyUtf8(i._iName, val, sizeof(i._iName)); });
	LuaSetDocProperty(itemType, "iName", "string", "Identified item name", [](const Item &i) { return std::string_view(i._iIName); }, [](Item &i, std::string_view val) { CopyUtf8(i._iIName, val, sizeof(i._iIName)); });
	LuaSetDocProperty(itemType, "loc", "ItemEquipType", "Equipment location", &Item::_iLoc);
	LuaSetDocProperty(itemType, "class", "ItemClass", "Item class", &Item::_iClass);
	LuaSetDocProperty(itemType, "curs", "number", "Cursor index", &Item::_iCurs);
	LuaSetDocProperty(itemType, "value", "number", "Item value", &Item::_ivalue);
	LuaSetDocProperty(itemType, "ivalue", "number", "Identified item value", &Item::_iIvalue);
	LuaSetDocProperty(itemType, "minDam", "number", "Minimum damage", &Item::_iMinDam);
	LuaSetDocProperty(itemType, "maxDam", "number", "Maximum damage", &Item::_iMaxDam);
	LuaSetDocProperty(itemType, "AC", "number", "Armor class", &Item::_iAC);
	LuaSetDocProperty(itemType, "flags", "ItemSpecialEffect", "Special effect flags", &Item::_iFlags);
	LuaSetDocProperty(itemType, "miscId", "ItemMiscID", "Miscellaneous ID", &Item::_iMiscId);
	LuaSetDocProperty(itemType, "spell", "SpellID", "Spell", &Item::_iSpell);
	LuaSetDocProperty(itemType, "IDidx", "ItemIndex", "Base item index", &Item::IDidx);
	LuaSetDocProperty(itemType, "charges", "number", "Number of charges", &Item::_iCharges);
	LuaSetDocProperty(itemType, "maxCharges", "number", "Maximum charges", &Item::_iMaxCharges);
	LuaSetDocProperty(itemType, "durability", "number", "Durability", &Item::_iDurability);
	LuaSetDocProperty(itemType, "maxDur", "number", "Maximum durability", &Item::_iMaxDur);
	LuaSetDocProperty(itemType, "PLDam", "number", "Damage % bonus", &Item::_iPLDam);
	LuaSetDocProperty(itemType, "PLToHit", "number", "Chance to hit bonus", &Item::_iPLToHit);
	LuaSetDocProperty(itemType, "PLAC", "number", "Armor class % bonus", &Item::_iPLAC);
	LuaSetDocProperty(itemType, "PLStr", "number", "Strength bonus", &Item::_iPLStr);
	LuaSetDocProperty(itemType, "PLMag", "number", "Magic bonus", &Item::_iPLMag);
	LuaSetDocProperty(itemType, "PLDex", "number", "Dexterity bonus", &Item::_iPLDex);
	LuaSetDocProperty(itemType, "PLVit", "number", "Vitality bonus", &Item::_iPLVit);
	LuaSetDocProperty(itemType, "PLFR", "number", "Fire resistance bonus", &Item::_iPLFR);
	LuaSetDocProperty(itemType, "PLLR", "number", "Lightning resistance bonus", &Item::_iPLLR);
	LuaSetDocProperty(itemType, "PLMR", "number", "Magic resistance bonus", &Item::_iPLMR);
	LuaSetDocProperty(itemType, "PLMana", "number", "Mana bonus", &Item::_iPLMana);
	LuaSetDocProperty(itemType, "PLHP", "number", "Life bonus", &Item::_iPLHP);
	LuaSetDocProperty(itemType, "PLDamMod", "number", "Damage modifier bonus", &Item::_iPLDamMod);
	LuaSetDocProperty(itemType, "PLGetHit", "number", "Damage from enemies bonus", &Item::_iPLGetHit);
	LuaSetDocProperty(itemType, "PLLight", "number", "Light bonus", &Item::_iPLLight);
	LuaSetDocProperty(itemType, "splLvlAdd", "number", "Spell level bonus", &Item::_iSplLvlAdd);
	LuaSetDocProperty(itemType, "request", "boolean", "Request flag", &Item::_iRequest);
	LuaSetDocProperty(itemType, "uid", "number", "Unique item ID", &Item::_iUid);
	LuaSetDocProperty(itemType, "fMinDam", "number", "Fire minimum damage", &Item::_iFMinDam);
	LuaSetDocProperty(itemType, "fMaxDam", "number", "Fire maximum damage", &Item::_iFMaxDam);
	LuaSetDocProperty(itemType, "lMinDam", "number", "Lightning minimum damage", &Item::_iLMinDam);
	LuaSetDocProperty(itemType, "lMaxDam", "number", "Lightning maximum damage", &Item::_iLMaxDam);
	LuaSetDocProperty(itemType, "PLEnAc", "number", "Damage target AC bonus", &Item::_iPLEnAc);
	LuaSetDocProperty(itemType, "prePower", "ItemEffectType", "Prefix power", &Item::_iPrePower);
	LuaSetDocProperty(itemType, "sufPower", "ItemEffectType", "Suffix power", &Item::_iSufPower);
	LuaSetDocProperty(itemType, "vAdd1", "number", "Value addition 1", &Item::_iVAdd1);
	LuaSetDocProperty(itemType, "vMult1", "number", "Value multiplier 1", &Item::_iVMult1);
	LuaSetDocProperty(itemType, "vAdd2", "number", "Value addition 2", &Item::_iVAdd2);
	LuaSetDocProperty(itemType, "vMult2", "number", "Value multiplier 2", &Item::_iVMult2);
	LuaSetDocProperty(itemType, "minStr", "number", "Minimum strength required", &Item::_iMinStr);
	LuaSetDocProperty(itemType, "minMag", "number", "Minimum magic required", &Item::_iMinMag);
	LuaSetDocProperty(itemType, "minDex", "number", "Minimum dexterity required", &Item::_iMinDex);
	LuaSetDocProperty(itemType, "statFlag", "boolean", "Equippable flag", &Item::_iStatFlag);
	LuaSetDocProperty(itemType, "damAcFlags", "ItemSpecialEffectHf", "Secondary special effect flags", &Item::_iDamAcFlags);
	LuaSetDocProperty(itemType, "buff", "number", "Secondary creation flags", &Item::dwBuff);
	LuaSetDocProperty(itemType, "modData", "number", "Mod-data slot (uint32); persisted through save/load; base game never reads or writes this field", &Item::_iLuaData); // Lua mod support

	// Member functions
	LuaSetDocFn(itemType, "pop", "() -> Item", "Clears this item and returns the old value", &Item::pop);
	LuaSetDocFn(itemType, "clear", "() -> void", "Resets the item", &Item::clear);
	LuaSetDocFn(itemType, "isEmpty", "() -> boolean", "Checks whether this item is empty", &Item::isEmpty);
	LuaSetDocFn(itemType, "isEquipment", "() -> boolean", "Checks if item is equipment", &Item::isEquipment);
	LuaSetDocFn(itemType, "isWeapon", "() -> boolean", "Checks if item is a weapon", &Item::isWeapon);
	LuaSetDocFn(itemType, "isArmor", "() -> boolean", "Checks if item is armor", &Item::isArmor);
	LuaSetDocFn(itemType, "isGold", "() -> boolean", "Checks if item is gold", &Item::isGold);
	LuaSetDocFn(itemType, "isHelm", "() -> boolean", "Checks if item is a helm", &Item::isHelm);
	LuaSetDocFn(itemType, "isShield", "() -> boolean", "Checks if item is a shield", &Item::isShield);
	LuaSetDocFn(itemType, "isJewelry", "() -> boolean", "Checks if item is jewelry", &Item::isJewelry);
	LuaSetDocFn(itemType, "isScroll", "() -> boolean", "Checks if item is a scroll", &Item::isScroll);
	LuaSetDocFn(itemType, "isScrollOf", "(spell: SpellID) -> boolean", "Checks if item is a scroll of a given spell", &Item::isScrollOf);
	LuaSetDocFn(itemType, "isRune", "() -> boolean", "Checks if item is a rune", &Item::isRune);
	LuaSetDocFn(itemType, "isRuneOf", "(spell: SpellID) -> boolean", "Checks if item is a rune of a given spell", &Item::isRuneOf);
	LuaSetDocFn(itemType, "isUsable", "() -> boolean", "Checks if item is usable", &Item::isUsable);
	LuaSetDocFn(itemType, "keyAttributesMatch", "(seed: number, idx: number, createInfo: number) -> boolean", "Checks if key attributes match", &Item::keyAttributesMatch);
	LuaSetDocFn(itemType, "getTextColor", "() -> UiFlags", "Gets the text color", &Item::getTextColor);
	LuaSetDocFn(itemType, "getTextColorWithStatCheck", "() -> UiFlags", "Gets the text color with stat check", &Item::getTextColorWithStatCheck);
	LuaSetDocFn(itemType, "setNewAnimation", "(showAnimation: boolean) -> void", "Sets the new animation", &Item::setNewAnimation);
	LuaSetDocFn(itemType, "updateRequiredStatsCacheForPlayer", "(player: Player) -> void", "Updates the required stats cache", &Item::updateRequiredStatsCacheForPlayer);
	LuaSetDocFn(itemType, "getName", "() -> string", "Gets the translated item name", &Item::getName);
}

void RegisterItemTypeEnum(sol::state_view &lua)
{
	lua.new_enum<ItemType>("ItemType",
	    {
	        { "Misc", ItemType::Misc },
	        { "Sword", ItemType::Sword },
	        { "Axe", ItemType::Axe },
	        { "Bow", ItemType::Bow },
	        { "Mace", ItemType::Mace },
	        { "Shield", ItemType::Shield },
	        { "LightArmor", ItemType::LightArmor },
	        { "Helm", ItemType::Helm },
	        { "MediumArmor", ItemType::MediumArmor },
	        { "HeavyArmor", ItemType::HeavyArmor },
	        { "Staff", ItemType::Staff },
	        { "Gold", ItemType::Gold },
	        { "Ring", ItemType::Ring },
	        { "Amulet", ItemType::Amulet },
	        { "None", ItemType::None },
	    });
}

void RegisterItemEquipTypeEnum(sol::state_view &lua)
{
	lua.new_enum<item_equip_type>("ItemEquipType",
	    {
	        { "None", ILOC_NONE },
	        { "OneHand", ILOC_ONEHAND },
	        { "TwoHand", ILOC_TWOHAND },
	        { "Armor", ILOC_ARMOR },
	        { "Helm", ILOC_HELM },
	        { "Ring", ILOC_RING },
	        { "Amulet", ILOC_AMULET },
	        { "Unequipable", ILOC_UNEQUIPABLE },
	        { "Belt", ILOC_BELT },
	        { "Invalid", ILOC_INVALID },
	    });
}

void RegisterItemClassEnum(sol::state_view &lua)
{
	lua.new_enum<item_class>("ItemClass",
	    {
	        { "None", ICLASS_NONE },
	        { "Weapon", ICLASS_WEAPON },
	        { "Armor", ICLASS_ARMOR },
	        { "Misc", ICLASS_MISC },
	        { "Gold", ICLASS_GOLD },
	        { "Quest", ICLASS_QUEST },
	    });
}

void RegisterItemSpecialEffectEnum(sol::state_view &lua)
{
	lua.new_enum<ItemSpecialEffect>("ItemSpecialEffect",
	    {
	        { "None", ItemSpecialEffect::None },
	        { "RandomStealLife", ItemSpecialEffect::RandomStealLife },
	        { "RandomArrowVelocity", ItemSpecialEffect::RandomArrowVelocity },
	        { "FireArrows", ItemSpecialEffect::FireArrows },
	        { "FireDamage", ItemSpecialEffect::FireDamage },
	        { "LightningDamage", ItemSpecialEffect::LightningDamage },
	        { "DrainLife", ItemSpecialEffect::DrainLife },
	        { "MultipleArrows", ItemSpecialEffect::MultipleArrows },
	        { "Knockback", ItemSpecialEffect::Knockback },
	        { "StealMana3", ItemSpecialEffect::StealMana3 },
	        { "StealMana5", ItemSpecialEffect::StealMana5 },
	        { "StealLife3", ItemSpecialEffect::StealLife3 },
	        { "StealLife5", ItemSpecialEffect::StealLife5 },
	        { "QuickAttack", ItemSpecialEffect::QuickAttack },
	        { "FastAttack", ItemSpecialEffect::FastAttack },
	        { "FasterAttack", ItemSpecialEffect::FasterAttack },
	        { "FastestAttack", ItemSpecialEffect::FastestAttack },
	        { "FastHitRecovery", ItemSpecialEffect::FastHitRecovery },
	        { "FasterHitRecovery", ItemSpecialEffect::FasterHitRecovery },
	        { "FastestHitRecovery", ItemSpecialEffect::FastestHitRecovery },
	        { "FastBlock", ItemSpecialEffect::FastBlock },
	        { "LightningArrows", ItemSpecialEffect::LightningArrows },
	        { "Thorns", ItemSpecialEffect::Thorns },
	        { "NoMana", ItemSpecialEffect::NoMana },
	        { "HalfTrapDamage", ItemSpecialEffect::HalfTrapDamage },
	        { "TripleDemonDamage", ItemSpecialEffect::TripleDemonDamage },
	        { "ZeroResistance", ItemSpecialEffect::ZeroResistance },
	    });
}

void RegisterItemMiscIDEnum(sol::state_view &lua)
{
	lua.new_enum<item_misc_id>("ItemMiscID",
	    {
	        { "None", IMISC_NONE },
	        { "FullHeal", IMISC_FULLHEAL },
	        { "Heal", IMISC_HEAL },
	        { "Mana", IMISC_MANA },
	        { "FullMana", IMISC_FULLMANA },
	        { "ElixirStr", IMISC_ELIXSTR },
	        { "ElixirMag", IMISC_ELIXMAG },
	        { "ElixirDex", IMISC_ELIXDEX },
	        { "ElixirVit", IMISC_ELIXVIT },
	        { "Rejuv", IMISC_REJUV },
	        { "FullRejuv", IMISC_FULLREJUV },
	        { "Scroll", IMISC_SCROLL },
	        { "ScrollT", IMISC_SCROLLT },
	        { "Staff", IMISC_STAFF },
	        { "Book", IMISC_BOOK },
	        { "Ring", IMISC_RING },
	        { "Amulet", IMISC_AMULET },
	        { "Unique", IMISC_UNIQUE },
	    });
}

void RegisterSpellIDEnum(sol::state_view &lua)
{
	lua.new_enum<SpellID>("SpellID",
	    {
	        { "Null", SpellID::Null },
	        { "Firebolt", SpellID::Firebolt },
	        { "Healing", SpellID::Healing },
	        { "Lightning", SpellID::Lightning },
	        { "Flash", SpellID::Flash },
	        { "Identify", SpellID::Identify },
	        { "FireWall", SpellID::FireWall },
	        { "TownPortal", SpellID::TownPortal },
	        { "StoneCurse", SpellID::StoneCurse },
	        { "Infravision", SpellID::Infravision },
	        { "Phasing", SpellID::Phasing },
	        { "ManaShield", SpellID::ManaShield },
	        { "Fireball", SpellID::Fireball },
	        { "Guardian", SpellID::Guardian },
	        { "ChainLightning", SpellID::ChainLightning },
	        { "FlameWave", SpellID::FlameWave },
	        { "DoomSerpents", SpellID::DoomSerpents },
	        { "BloodRitual", SpellID::BloodRitual },
	        { "Nova", SpellID::Nova },
	        { "Invisibility", SpellID::Invisibility },
	        { "Inferno", SpellID::Inferno },
	        { "Golem", SpellID::Golem },
	        { "Rage", SpellID::Rage },
	        { "Teleport", SpellID::Teleport },
	        { "Apocalypse", SpellID::Apocalypse },
	        { "Etherealize", SpellID::Etherealize },
	        { "ItemRepair", SpellID::ItemRepair },
	        { "StaffRecharge", SpellID::StaffRecharge },
	        { "TrapDisarm", SpellID::TrapDisarm },
	        { "Elemental", SpellID::Elemental },
	        { "ChargedBolt", SpellID::ChargedBolt },
	        { "HolyBolt", SpellID::HolyBolt },
	        { "Resurrect", SpellID::Resurrect },
	        { "Telekinesis", SpellID::Telekinesis },
	        { "HealOther", SpellID::HealOther },
	        { "BloodStar", SpellID::BloodStar },
	        { "BoneSpirit", SpellID::BoneSpirit },
	        { "Mana", SpellID::Mana },
	        { "Magi", SpellID::Magi },
	        { "Jester", SpellID::Jester },
	        { "LightningWall", SpellID::LightningWall },
	        { "Immolation", SpellID::Immolation },
	        { "Warp", SpellID::Warp },
	        { "Reflect", SpellID::Reflect },
	        { "Berserk", SpellID::Berserk },
	        { "RingOfFire", SpellID::RingOfFire },
	        { "Search", SpellID::Search },
	        { "RuneOfFire", SpellID::RuneOfFire },
	        { "RuneOfLight", SpellID::RuneOfLight },
	        { "RuneOfNova", SpellID::RuneOfNova },
	        { "RuneOfImmolation", SpellID::RuneOfImmolation },
	        { "RuneOfStone", SpellID::RuneOfStone },
	        { "Invalid", SpellID::Invalid },
	    });
}

void RegisterItemIndexEnum(sol::state_view &lua)
{
	lua.new_enum<_item_indexes>("ItemIndex",
	    {
	        { "Gold", IDI_GOLD },
	        { "Warrior", IDI_WARRIOR },
	        { "WarriorShield", IDI_WARRSHLD },
	        { "WarriorClub", IDI_WARRCLUB },
	        { "Rogue", IDI_ROGUE },
	        { "Sorcerer", IDI_SORCERER },
	        { "Cleaver", IDI_CLEAVER },
	        { "FirstQuest", IDI_FIRSTQUEST },
	        { "SkeletonKingCrown", IDI_SKCROWN },
	        { "InfravisionRing", IDI_INFRARING },
	        { "Rock", IDI_ROCK },
	        { "OpticAmulet", IDI_OPTAMULET },
	        { "TruthRing", IDI_TRING },
	        { "Banner", IDI_BANNER },
	        { "HarlequinCrest", IDI_HARCREST },
	        { "SteelVeil", IDI_STEELVEIL },
	        { "GoldenElixir", IDI_GLDNELIX },
	        { "Anvil", IDI_ANVIL },
	        { "Mushroom", IDI_MUSHROOM },
	        { "Brain", IDI_BRAIN },
	        { "FungalTome", IDI_FUNGALTM },
	        { "SpectralElixir", IDI_SPECELIX },
	        { "BloodStone", IDI_BLDSTONE },
	        { "MapOfDoom", IDI_MAPOFDOOM },
	        { "LastQuest", IDI_LASTQUEST },
	        { "Ear", IDI_EAR },
	        { "Heal", IDI_HEAL },
	        { "Mana", IDI_MANA },
	        { "Identify", IDI_IDENTIFY },
	        { "Portal", IDI_PORTAL },
	        { "ArmorOfValor", IDI_ARMOFVAL },
	        { "FullHeal", IDI_FULLHEAL },
	        { "FullMana", IDI_FULLMANA },
	        { "Griswold", IDI_GRISWOLD },
	        { "Lightforge", IDI_LGTFORGE },
	        { "LazarusStaff", IDI_LAZSTAFF },
	        { "Resurrect", IDI_RESURRECT },
	        { "Oil", IDI_OIL },
	        { "ShortStaff", IDI_SHORTSTAFF },
	        { "BardSword", IDI_BARDSWORD },
	        { "BardDagger", IDI_BARDDAGGER },
	        { "RuneBomb", IDI_RUNEBOMB },
	        { "Theodore", IDI_THEODORE },
	        { "Auric", IDI_AURIC },
	        { "Note1", IDI_NOTE1 },
	        { "Note2", IDI_NOTE2 },
	        { "Note3", IDI_NOTE3 },
	        { "FullNote", IDI_FULLNOTE },
	        { "BrownSuit", IDI_BROWNSUIT },
	        { "GreySuit", IDI_GREYSUIT },
	        { "Book1", IDI_BOOK1 },
	        { "Book2", IDI_BOOK2 },
	        { "Book3", IDI_BOOK3 },
	        { "Book4", IDI_BOOK4 },
	        { "Barbarian", IDI_BARBARIAN },
	        { "ShortBattleBow", IDI_SHORT_BATTLE_BOW },
	        { "RuneOfStone", IDI_RUNEOFSTONE },
	        { "SorcererDiablo", IDI_SORCERER_DIABLO },
	        { "ArenaPotion", IDI_ARENAPOT },
	        { "None", IDI_NONE },
	    });
}

void RegisterItemEffectTypeEnum(sol::state_view &lua)
{
	lua.new_enum<item_effect_type>("ItemEffectType",
	    {
	        { "ToHit", IPL_TOHIT },
	        { "ToHitCurse", IPL_TOHIT_CURSE },
	        { "DamagePercent", IPL_DAMP },
	        { "DamagePercentCurse", IPL_DAMP_CURSE },
	        { "ToHitDamagePercent", IPL_TOHIT_DAMP },
	        { "ToHitDamagePercentCurse", IPL_TOHIT_DAMP_CURSE },
	        { "ArmorClassPercent", IPL_ACP },
	        { "ArmorClassPercentCurse", IPL_ACP_CURSE },
	        { "FireResist", IPL_FIRERES },
	        { "LightningResist", IPL_LIGHTRES },
	        { "MagicResist", IPL_MAGICRES },
	        { "AllResist", IPL_ALLRES },
	        { "SpellLevelAdd", IPL_SPLLVLADD },
	        { "Charges", IPL_CHARGES },
	        { "FireDamage", IPL_FIREDAM },
	        { "LightningDamage", IPL_LIGHTDAM },
	        { "Strength", IPL_STR },
	        { "StrengthCurse", IPL_STR_CURSE },
	        { "Magic", IPL_MAG },
	        { "MagicCurse", IPL_MAG_CURSE },
	        { "Dexterity", IPL_DEX },
	        { "DexterityCurse", IPL_DEX_CURSE },
	        { "Vitality", IPL_VIT },
	        { "VitalityCurse", IPL_VIT_CURSE },
	        { "Attributes", IPL_ATTRIBS },
	        { "AttributesCurse", IPL_ATTRIBS_CURSE },
	        { "GetHitCurse", IPL_GETHIT_CURSE },
	        { "GetHit", IPL_GETHIT },
	        { "Life", IPL_LIFE },
	        { "LifeCurse", IPL_LIFE_CURSE },
	        { "Mana", IPL_MANA },
	        { "ManaCurse", IPL_MANA_CURSE },
	        { "Durability", IPL_DUR },
	        { "DurabilityCurse", IPL_DUR_CURSE },
	        { "Indestructible", IPL_INDESTRUCTIBLE },
	        { "Light", IPL_LIGHT },
	        { "LightCurse", IPL_LIGHT_CURSE },
	        { "MultipleArrows", IPL_MULT_ARROWS },
	        { "FireArrows", IPL_FIRE_ARROWS },
	        { "LightningArrows", IPL_LIGHT_ARROWS },
	        { "Thorns", IPL_THORNS },
	        { "NoMana", IPL_NOMANA },
	        { "Fireball", IPL_FIREBALL },
	        { "AbsorbHalfTrap", IPL_ABSHALFTRAP },
	        { "Knockback", IPL_KNOCKBACK },
	        { "StealMana", IPL_STEALMANA },
	        { "StealLife", IPL_STEALLIFE },
	        { "TargetArmorClass", IPL_TARGAC },
	        { "FastAttack", IPL_FASTATTACK },
	        { "FastRecover", IPL_FASTRECOVER },
	        { "FastBlock", IPL_FASTBLOCK },
	        { "DamageModifier", IPL_DAMMOD },
	        { "RandomArrowVelocity", IPL_RNDARROWVEL },
	        { "SetDamage", IPL_SETDAM },
	        { "SetDurability", IPL_SETDUR },
	        { "NoMinimumStrength", IPL_NOMINSTR },
	        { "Spell", IPL_SPELL },
	        { "OneHand", IPL_ONEHAND },
	        { "3xDamageVsDemons", IPL_3XDAMVDEM },
	        { "AllResistZero", IPL_ALLRESZERO },
	        { "DrainLife", IPL_DRAINLIFE },
	        { "RandomStealLife", IPL_RNDSTEALLIFE },
	        { "SetArmorClass", IPL_SETAC },
	        { "AddArmorClassLife", IPL_ADDACLIFE },
	        { "AddManaArmorClass", IPL_ADDMANAAC },
	        { "ArmorClassCurse", IPL_AC_CURSE },
	        { "LastDiablo", IPL_LASTDIABLO },
	        { "FireResistCurse", IPL_FIRERES_CURSE },
	        { "LightResistCurse", IPL_LIGHTRES_CURSE },
	        { "MagicResistCurse", IPL_MAGICRES_CURSE },
	        { "Devastation", IPL_DEVASTATION },
	        { "Decay", IPL_DECAY },
	        { "Peril", IPL_PERIL },
	        { "Jesters", IPL_JESTERS },
	        { "Crystalline", IPL_CRYSTALLINE },
	        { "Doppelganger", IPL_DOPPELGANGER },
	        { "ArmorClassDemon", IPL_ACDEMON },
	        { "ArmorClassUndead", IPL_ACUNDEAD },
	        { "ManaToLife", IPL_MANATOLIFE },
	        { "LifeToMana", IPL_LIFETOMANA },
	        { "Invalid", IPL_INVALID },
	    });
}

void RegisterItemSpecialEffectHfEnum(sol::state_view &lua)
{
	lua.new_enum<ItemSpecialEffectHf>("ItemSpecialEffectHf",
	    {
	        { "None", ItemSpecialEffectHf::None },
	        { "Devastation", ItemSpecialEffectHf::Devastation },
	        { "Decay", ItemSpecialEffectHf::Decay },
	        { "Peril", ItemSpecialEffectHf::Peril },
	        { "Jesters", ItemSpecialEffectHf::Jesters },
	        { "Doppelganger", ItemSpecialEffectHf::Doppelganger },
	        { "ACAgainstDemons", ItemSpecialEffectHf::ACAgainstDemons },
	        { "ACAgainstUndead", ItemSpecialEffectHf::ACAgainstUndead },
	    });
}

void AddItemDataFromTsv(const std::string_view path, const int32_t baseMappingId)
{
	DataFile dataFile = DataFile::loadOrDie(path);
	LoadItemDatFromFile(dataFile, path, baseMappingId);
}

void AddUniqueItemDataFromTsv(const std::string_view path, const int32_t baseMappingId)
{
	DataFile dataFile = DataFile::loadOrDie(path);
	LoadUniqueItemDatFromFile(dataFile, path, baseMappingId);
}

ItemData ParseItemDataTable(sol::table t)
{
	ItemData item = {};
	item.dropRate = static_cast<uint8_t>(t.get_or("dropRate", 1));
	item.iClass = t.get_or("class", ICLASS_NONE);
	item.iLoc = t.get_or("equipType", ILOC_NONE);
	item.iCurs = static_cast<item_cursor_graphic>(t.get_or("cursorGraphic", 0));
	item.itype = t.get_or("type", ItemType::None);
	item.iItemId = static_cast<unique_base_item>(t.get_or("uniqueBaseItem", UITYPE_NONE));
	item.iName = t.get<std::string>("name");
	item.iSName = t.get_or("shortName", item.iName);
	item.iMinMLvl = static_cast<uint8_t>(t.get_or("minMonsterLevel", 0));
	item.iDurability = static_cast<uint8_t>(t.get_or("durability", 0));
	item.iMinDam = static_cast<uint8_t>(t.get_or("minDam", 0));
	item.iMaxDam = static_cast<uint8_t>(t.get_or("maxDam", 0));
	item.iMinAC = static_cast<uint8_t>(t.get_or("minAC", 0));
	item.iMaxAC = static_cast<uint8_t>(t.get_or("maxAC", 0));
	item.iMinStr = static_cast<uint8_t>(t.get_or("minStr", 0));
	item.iMinMag = static_cast<uint8_t>(t.get_or("minMag", 0));
	item.iMinDex = static_cast<uint8_t>(t.get_or("minDex", 0));
	item.iFlags = t.get_or("flags", ItemSpecialEffect::None);
	item.iMiscId = t.get_or("miscId", IMISC_NONE);
	item.iSpell = t.get_or("spell", SpellID::Null);
	item.iUsable = t.get_or("usable", false);
	item.iSkipSpeedbook = t.get_or("skipSpeedbook", false);
	item.iValue = static_cast<uint16_t>(t.get_or("value", 0));
	return item;
}

UniqueItem ParseUniqueItemDataTable(sol::table t)
{
	UniqueItem item = {};
	item.UIName = t.get<std::string>("name");
	item.UICurs = static_cast<item_cursor_graphic>(t.get_or("cursorGraphic", 0));
	item.UIItemId = static_cast<unique_base_item>(t.get_or("uniqueBaseItem", UITYPE_NONE));
	item.UIMinLvl = static_cast<int8_t>(t.get_or("minLevel", 0));
	item.UIValue = t.get_or("value", 0);
	item.UINumPL = 0;
	sol::optional<sol::table> powers = t["powers"];
	if (powers) {
		for (size_t i = 1; i <= std::size(item.powers); ++i) {
			sol::optional<sol::table> power = (*powers)[i];
			if (!power) break;
			item.powers[item.UINumPL].type = power->get_or("type", IPL_INVALID);
			item.powers[item.UINumPL].param1 = power->get_or("param1", 0);
			item.powers[item.UINumPL].param2 = power->get_or("param2", 0);
			item.UINumPL++;
		}
	}
	return item;
}

void AddItemData(sol::table itemData, const int32_t baseMappingId)
{
	const size_t numItems = itemData.size();
	AllItemsList.reserve(AllItemsList.size() + numItems);
	for (size_t i = 1; i <= numItems; ++i) {
		sol::optional<sol::table> itemTable = itemData[i];
		if (!itemTable) {
			app_fatal(fmt::format("Expected item data table at index {}.", i));
		}
		const int32_t mappingId = baseMappingId + static_cast<int32_t>(i - 1);
		ItemData item = ParseItemDataTable(*itemTable);
		item.iMappingId = mappingId;
		AllItemsList.push_back(std::move(item));
		const auto [it, inserted] = ItemMappingIdsToIndices.emplace(mappingId, static_cast<int16_t>(AllItemsList.size()) - 1);
		if (!inserted) {
			app_fatal(fmt::format("An item already exists for mapping ID {}.", mappingId));
		}
	}
}

void AddUniqueItemData(sol::table itemData, const int32_t baseMappingId)
{
	const size_t numItems = itemData.size();
	UniqueItems.reserve(UniqueItems.size() + numItems);
	for (size_t i = 1; i <= numItems; ++i) {
		sol::optional<sol::table> itemTable = itemData[i];
		if (!itemTable) {
			app_fatal(fmt::format("Expected unique item data table at index {}.", i));
		}
		const int32_t mappingId = baseMappingId + static_cast<int32_t>(i - 1);
		UniqueItem item = ParseUniqueItemDataTable(*itemTable);
		item.mappingId = mappingId;
		UniqueItems.push_back(std::move(item));
		const auto [it, inserted] = UniqueItemMappingIdsToIndices.emplace(mappingId, static_cast<int32_t>(UniqueItems.size()) - 1);
		if (!inserted) {
			app_fatal(fmt::format("A unique item already exists for mapping ID {}.", mappingId));
		}
	}
}

int LuaRegisterCursorGraphic(const std::string &path, int width)
{
	OwnedClxSpriteList sprite = LoadCel(path.c_str(), static_cast<uint16_t>(width));
	return RegisterCustomCursorGraphic(std::move(sprite));
}

void LuaSpawnItemAt(int x, int y, int32_t mappingId, uint32_t seed, sol::optional<std::string> nameOverride, sol::optional<uint32_t> buffOverride, sol::optional<uint32_t> modDataOverride) // Lua mod support
{
	if (ActiveItemCount >= MAXITEMS)
		return;

	const auto it = ItemMappingIdsToIndices.find(mappingId);
	if (it == ItemMappingIdsToIndices.end())
		return;

	const auto itemIndex = static_cast<_item_indexes>(it->second);
	const Point pos { x, y };
	// Try the exact tile first (e.g. the monster was just removed from this tile).
	// GetSuperItemLoc starts at radius 1 and would miss it.
	const Point dropPos = ItemSpaceOk(pos) ? pos : GetSuperItemLoc(pos);
	if (dropPos == Point { 0, 0 } && pos != Point { 0, 0 })
		return; // GetSuperItemLoc found no valid tile

	Item item {};
	GetItemAttrs(item, itemIndex, 1);
	SetupItem(item);
	item._iSeed = seed;
	item._iCreateInfo = 0;
	item._iIdentified = true;
	if (buffOverride.has_value()) item.dwBuff = *buffOverride; // Lua mod support
	if (modDataOverride.has_value()) item._iLuaData = *modDataOverride; // Lua mod support

	if (nameOverride.has_value()) {
		CopyUtf8(item._iName, *nameOverride, sizeof(item._iName));
		CopyUtf8(item._iIName, *nameOverride, sizeof(item._iIName));
	}

	const uint8_t ii = PlaceItemInWorld(std::move(item), dropPos);
	// In multiplayer mode, PlaceItemInWorld alone doesn't persist items across level transitions.
	// Register as DroppedItem in the delta so DeltaLoadItems re-spawns it on return.
	LuaDeltaRegisterDroppedItem(ii);
}

void LuaAddToHealerStock(int32_t mappingId, int ivalue, sol::optional<uint32_t> seedOpt, sol::optional<std::string> nameOverride, sol::optional<uint32_t> buffOverride, sol::optional<uint32_t> modDataOverride)
{
	const auto it = ItemMappingIdsToIndices.find(mappingId);
	if (it == ItemMappingIdsToIndices.end()) return;
	const auto itemIndex = static_cast<_item_indexes>(it->second);

	const uint32_t seed = seedOpt.value_or(0);

	// Idempotent: skip if this item is already in stock. Without a seed (a single static stock
	// item) any same-mapping entry counts as already present; with a seed (per-instance custom
	// items sharing one mapping, e.g. seeded scrolls) only a matching seed counts, so distinct
	// seeds coexist.
	for (const Item &existing : HealerItems) {
		if (existing.IDidx != itemIndex) continue;
		if (!seedOpt.has_value() || existing._iSeed == seed) return;
	}

	// If at capacity, replace the last (lowest-priority) random item.
	if (HealerItems.size() >= NumHealerItemsHf) {
		HealerItems.erase(HealerItems.end() - 1);
	}

	Item item = {};
	GetItemAttrs(item, itemIndex, 1);
	if (seedOpt.has_value()) {
		// Seeded custom item: set it up like a normal dropped/inventory item so its seed, name and
		// dwBuff roundtrip intact when bought (createInfo 0 keeps RecreateItem from touching dwBuff).
		SetupItem(item);
		item._iSeed = seed;
		item._iCreateInfo = 0;
	}
	item._iIdentified = true;
	item._iIvalue = ivalue;
	item._ivalue = ivalue;
	item._iStatFlag = true;
	if (buffOverride.has_value()) item.dwBuff = *buffOverride;
	if (modDataOverride.has_value()) item._iLuaData = *modDataOverride; // Lua mod support
	if (nameOverride.has_value()) {
		CopyUtf8(item._iName, *nameOverride, sizeof(item._iName));
		CopyUtf8(item._iIName, *nameOverride, sizeof(item._iIName));
	}
	HealerItems.push_back(std::move(item));
}

} // namespace

sol::table LuaItemModule(sol::state_view &lua)
{
	InitItemUserType(lua);
	RegisterItemTypeEnum(lua);
	RegisterItemEquipTypeEnum(lua);
	RegisterItemClassEnum(lua);
	RegisterItemSpecialEffectEnum(lua);
	RegisterItemMiscIDEnum(lua);
	RegisterSpellIDEnum(lua);
	RegisterItemIndexEnum(lua);
	RegisterItemEffectTypeEnum(lua);
	RegisterItemSpecialEffectHfEnum(lua);

	sol::table table = lua.create_table();

	LuaSetDocFn(table, "addItemDataFromTsv", "(path: string, baseMappingId: number)", AddItemDataFromTsv);
	LuaSetDocFn(table, "addUniqueItemDataFromTsv", "(path: string, baseMappingId: number)", AddUniqueItemDataFromTsv);
	LuaSetDocFn(table, "addItemData", "(itemData: table[], baseMappingId: number)", "Add item definitions from a list of Lua tables. Required field: name. Optional: dropRate, class, equipType, cursorGraphic, type, uniqueBaseItem, shortName, minMonsterLevel, durability, minDam, maxDam, minAC, maxAC, minStr, minMag, minDex, flags, miscId, spell, usable, skipSpeedbook, value.", AddItemData);
	LuaSetDocFn(table, "addUniqueItemData", "(itemData: table[], baseMappingId: number)", "Add unique item definitions from a list of Lua tables. Required field: name. Optional: cursorGraphic, uniqueBaseItem, minLevel, value, powers (array of {type, param1, param2}).", AddUniqueItemData);
	LuaSetDocFn(table, "registerCursorGraphic", "(path: string, width: number) -> number", "Load a sprite for inventory/cursor display and return its cursorGraphic ID (pass to item's cursorGraphic field).", LuaRegisterCursorGraphic);
	LuaSetDocFn(table, "spawnAt", "(x: integer, y: integer, mappingId: integer, seed: integer, name?: string, dwBuff?: integer, modData?: integer)",
	    "Drop a custom item at the nearest free tile to (x, y) with the given seed. Optional name overrides the display name. Optional dwBuff sets item.dwBuff (bit 0 must be 0). Optional modData sets item.modData (uint32; persisted through save/load; base game ignores this field).",
	    LuaSpawnItemAt);
	LuaSetDocFn(table, "addToHealerStock", "(mappingId: integer, ivalue: integer, seed?: integer, name?: string, dwBuff?: integer, modData?: integer)",
	    "Add a custom item to the healer's buy list at the given identified value (shop price). Optional seed/name/dwBuff/modData stock a per-instance seeded item (e.g. a custom scroll) that roundtrips when bought; omitting them stocks a single static item. Idempotent — without a seed any same-mapping entry is a no-op, with a seed only a matching seed is a no-op, so distinct seeds coexist. If the list is at capacity the last random entry is replaced. Call from StoreOpened(\"pepin\") so items reappear after purchase.",
	    LuaAddToHealerStock);
	// Lua mod support: populate the custom unique info box slot.
	// Call inside OnPrepareUniqueInfoBox then return true to redirect DrawUniqueInfo to this content.
	LuaSetDocFn(table, "setCustomUniqueBox",
	    "(name: string, lines: string[]) -> void",
	    "Set the title and up to 6 content lines for the Lua-custom unique item info popup. Call inside OnPrepareUniqueInfoBox before returning true.",
	    [](std::string_view name, sol::table lines) {
		    std::vector<std::string> lineVec;
		    for (std::size_t i = 1; i <= lines.size() && lineVec.size() < 6; ++i) {
			    sol::optional<std::string> s = lines.get<sol::optional<std::string>>(i);
			    if (s) lineVec.push_back(*s);
		    }
		    SetLuaUniqueInfoBox(name, lineVec);
	    });

	// Expose enums through the module table
	table["ItemIndex"] = lua["ItemIndex"];
	table["ItemType"] = lua["ItemType"];
	table["ItemClass"] = lua["ItemClass"];
	table["ItemEquipType"] = lua["ItemEquipType"];
	table["ItemMiscID"] = lua["ItemMiscID"];
	table["SpellID"] = lua["SpellID"];
	table["ItemEffectType"] = lua["ItemEffectType"];
	table["ItemSpecialEffect"] = lua["ItemSpecialEffect"];
	table["ItemSpecialEffectHf"] = lua["ItemSpecialEffectHf"];

	return table;
}

} // namespace devilution
