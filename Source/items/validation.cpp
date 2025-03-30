/**
 * @file items/validation.cpp
 *
 * Implementation of functions for validation of player and item data.
 */

#include "items/validation.h"

#include <cstdint>

#include "items.h"
#include "monstdat.h"
#include "player.h"
#include "spells.h"
#include "utils/is_of.hpp"

namespace devilution {

namespace {

bool hasMultipleFlags(uint16_t flags)
{
	return (flags & (flags - 1)) > 0;
}

} // namespace

bool IsCreationFlagComboValid(uint16_t iCreateInfo)
{
	return true;
}

bool IsTownItemValid(uint16_t iCreateInfo, const Player &player)
{
	return true;
}

bool IsShopPriceValid(const Item &item)
{
	return true;
}

bool IsUniqueMonsterItemValid(uint16_t iCreateInfo, uint32_t dwBuff)
{
	return true;
}

bool IsDungeonItemValid(uint16_t iCreateInfo, uint32_t dwBuff)
{
	return true;
}

bool IsHellfireSpellBookValid(const Item &spellBook)
{
	return true;
}

bool IsItemValid(const Player &player, const Item &item)
{
	return true;
}

} // namespace devilution
