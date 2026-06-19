local function CreateEvent()
  local functions = {}
  return {
    ---Adds an event handler.
    ---
    ---The handler called every time an event is triggered.
    ---@param func function
    add = function(func)
      table.insert(functions, func)
    end,

    ---Removes the event handler.
    ---@param func function
    remove = function(func)
      for i, f in ipairs(functions) do
        if f == func then
          table.remove(functions, i)
          break
        end
      end
    end,

    ---Triggers an event.
    ---
    ---The arguments are forwarded to handlers.
    ---@param ... any
    ---@return any
    trigger = function(...)
      local result
      for _, func in ipairs(functions) do
        result = func(...)
      end
      return result
    end,
    __sig_trigger = "(...)",
  }
end

-- Like CreateEvent but for query events that return a value.
-- Only updates the result when a handler returns non-nil, so a handler that
-- returns nothing (nil) does not overwrite a value set by an earlier handler.
local function CreateQueryEvent()
  local functions = {}
  return {
    add = function(func)
      table.insert(functions, func)
    end,
    remove = function(func)
      for i, f in ipairs(functions) do
        if f == func then
          table.remove(functions, i)
          break
        end
      end
    end,
    trigger = function(...)
      local result
      for _, func in ipairs(functions) do
        local r = func(...)
        if r ~= nil then result = r end
      end
      return result
    end,
    __sig_trigger = "(...)",
  }
end

local events = {
  ---Called after all mods have been loaded.
  LoadModsComplete = CreateEvent(),
  __doc_LoadModsComplete = "Called after all mods have been loaded.",

  ---Called after the item data TSV file has been loaded.
  ItemDataLoaded = CreateEvent(),
  __doc_ItemDataLoaded = "Called after the item data TSV file has been loaded.",

  ---Called after the unique item data TSV file has been loaded.
  UniqueItemDataLoaded = CreateEvent(),
  __doc_UniqueItemDataLoaded = "Called after the unique item data TSV file has been loaded.",

  ---Called after the spell data TSV file has been loaded. Use spells.addSpellDataFromTsv() in this handler to register additional spells.
  SpellDataLoaded = CreateEvent(),
  __doc_SpellDataLoaded = "Called after the spell data TSV file has been loaded. Use spells.addSpellDataFromTsv() in this handler to register additional spells.",

  ---Called after base class data has been loaded but before class attributes are built. Use player.addClassDataFromTsv() in this handler to register additional classes.
  PlayerDataLoaded = CreateEvent(),
  __doc_PlayerDataLoaded = "Called after base class data has been loaded. Use player.addClassDataFromTsv() in this handler to register additional classes.",

  ---Called after the monster data TSV file has been loaded.
  MonsterDataLoaded = CreateEvent(),
  __doc_MonsterDataLoaded = "Called after the monster data TSV file has been loaded.",

  ---Called after the unique monster data TSV file has been loaded.
  UniqueMonsterDataLoaded = CreateEvent(),
  __doc_UniqueMonsterDataLoaded = "Called after the unique monster data TSV file has been loaded.",

  ---Called every time a new game is started.
  GameStart = CreateEvent(),
  __doc_GameStart = "Called every time a new game is started.",

  ---Called once when a new character is first created (CreatePlayer). Fires before the first level loads.
  ---The player has their starting loadout but no experience. Use this to grant class-specific starting items.
  OnNewCharacter = CreateEvent(),
  __doc_OnNewCharacter = "Called once when a new character is created. Player has starting loadout; fires before first level load.",

  ---Called from CreatePlrItems after the standard starting loadout is placed, before CalcPlrItemVals.
  ---Use player:addScrollByMapping() to place additional starting items. Safe to use during character creation.
  OnCreatePlrItems = CreateEvent(),
  __doc_OnCreatePlrItems = "Called after standard starting items are placed for a new character. Use player:addScrollByMapping() to add class-specific starting items.",

  ---Called every frame at the end.
  GameDrawComplete = CreateEvent(),
  __doc_GameDrawComplete = "Called every frame at the end.",

  ---Called when opening a towner store. Passes the towner name as argument (e.g., "griswold", "adria", "pepin", "wirt", "cain").
  StoreOpened = CreateEvent(),
  __doc_StoreOpened = "Called when opening a towner store. Passes the towner name as argument.",

  ---Called when a Monster takes damage.
  OnMonsterTakeDamage = CreateEvent(),
  __doc_OnMonsterTakeDamage = "Called when a Monster takes damage.",

  ---Called when a Monster dies. Passes the monster as argument.
  OnMonsterDeath = CreateEvent(),
  __doc_OnMonsterDeath = "Called when a Monster dies. Passes the monster as argument.",

  ---Called when a player successfully begins casting a spell or using a skill.
  ---Passes: player, spellId (integer), spellType (integer: 0=Skill 1=Spell 2=Scroll 3=Charges), targetMonster (may be nil for non-monster-targeted casts).
  OnSpellCast = CreateEvent(),
  __doc_OnSpellCast = "Called when a player casts a spell or uses a skill. spellType: 0=Skill 1=Spell 2=Scroll 3=Charges. targetMonster is nil for non-monster-targeted casts.",

  ---Called at the mid-animation release frame of a spell cast (equivalent to _pSFNum). Same parameters as OnSpellCast.
  ---Fires after the vanilla CastSpell call. targetMonster is looked up by target position and may be nil if the monster moved.
  OnSpellActionFrame = CreateEvent(),
  __doc_OnSpellActionFrame = "Called at the spell fire frame (_pSFNum) during cast animation. Same args as OnSpellCast. Use this instead of OnSpellCast when the effect should sync with the animation.",

  ---Called when Player takes damage.
  OnPlayerTakeDamage = CreateEvent(),
  __doc_OnPlayerTakeDamage = "Called when Player takes damage.",

  ---Called when Player gains experience.
  OnPlayerGainExperience = CreateEvent(),
  __doc_OnPlayerGainExperience = "Called when Player gains experience.",

  ---Called when a player's resistances are recalculated (CalcPlrInv). Args: player, fire, lightning,
  ---magic — the UNCAPPED pre-clamp totals (may exceed the 75% display cap shown on the character sheet).
  OnCalcPlayerResistances = CreateEvent(),
  __doc_OnCalcPlayerResistances = "Called when player resistances are recalculated. Args: player, fire, lightning, magic (uncapped pre-clamp totals).",

  ---Called just before the current level is saved and unloaded (level exit, warp, or player death).
  ---All monsters and items are still accessible. Drop or recall anything before this returns.
  OnLevelExit = CreateEvent(),
  __doc_OnLevelExit = "Called just before the current level is saved and unloaded (level exit or player death). Monsters and items are still valid.",

  ---Called after a level has fully loaded and all players have been initialized.
  ---Use this to re-grant class skills that InitPlayer resets on each level entry.
  OnLevelEnter = CreateEvent(),
  __doc_OnLevelEnter = "Called after a level finishes loading and all players are initialized. Fires on every level entry including first load.",

  ---Called inside RecreateItem for any item whose IDidx >= IDI_NUM_DEFAULT_ITEMS (Lua-registered custom items).
  ---Fires after InitializeItem and seed/dwBuff are restored, so item.seed and item.buff are valid.
  ---Use this to restore fields that InitializeItem resets (e.g. the display name).
  OnCustomItemRecreated = CreateEvent(),
  __doc_OnCustomItemRecreated = "Called after a custom (Lua-registered) item is recreated from save/delta data. item.seed and item.buff are valid; use to restore display name or other derived fields.",

  ---Query event fired just before a player animation starts. Return an integer to override
  ---the number of frames to skip (speeds up the animation). Return nil to leave unchanged.
  ---animType is one of: "Attack", "RangedAttack", "Cast", "Block", "HitRecovery".
  ---currentSkip is the value computed from item flags (0 if none apply).
  OnGetAnimationSkipFrames = CreateQueryEvent(),
  __doc_OnGetAnimationSkipFrames = "Query: return integer to override skipped animation frames for the given animType (Attack/RangedAttack/Cast/Block/HitRecovery). Return nil to leave unchanged.",

  ---Query event fired from SetPlrAnims whenever a player's animation frame counts are set
  ---(on equip, level entry, etc). Return an integer to override _pNFrames (the idle frame count).
  ---weaponGraphic is the PlayerWeaponGraphic enum value (0=Unarmed,1=UnarmedShield,2=Sword,
  ---3=SwordShield,4=Bow,5=Axe,6=Mace,7=MaceShield,8=Staff). isInTown is a boolean.
  ---Return nil to leave unchanged.
  OnGetPlayerIdleFrames = CreateQueryEvent(),
  __doc_OnGetPlayerIdleFrames = "Query: return integer to override _pNFrames (idle frame count) for a given weapon graphic. weaponGraphic: 0=Unarmed 4=Bow etc. Return nil to leave unchanged.",

  ---Query event fired from Player::CanUseItem after the standard stat check passes.
  ---Return false to veto item use (shows item red and blocks equip/consume). Return nil or true to allow.
  ---item.miscId and item.IDidx are useful for identifying item type.
  OnCanPlayerUseItem = CreateQueryEvent(),
  __doc_OnCanPlayerUseItem = "Query: return false to block a player from using an item (shows red, blocks equip/consume). Return nil or true to allow. Fires only when standard stat check already passes.",

  ---Query event fired from Player::GetMaximumAttributeValue.
  ---attribute is one of: "Strength", "Magic", "Dexterity", "Vitality".
  ---Return an integer to override the stat cap. Return nil to use the class table value.
  ---Drives both the golden stat display and allocation blocking.
  OnGetMaxAttributeValue = CreateQueryEvent(),
  __doc_OnGetMaxAttributeValue = "Query: return integer to override the maximum for the given attribute (\"Strength\"/\"Magic\"/\"Dexterity\"/\"Vitality\"). Drives golden display and allocation blocking. Return nil to use class table value.",

  ---Query event fired from CalcPlrDamageMod after the per-class switch for dynamic classes.
  ---strMod = level * totalStr, strDexMod = level * (totalStr + totalDex), totalVit = totalVit.
  ---Weapon context booleans: isHoldingBow, isHoldingShield, isHoldingStaff, isUnarmed.
  ---Return an integer to replace _pDamageMod. Return nil to keep the default formula result.
  OnGetPlayerDamageMod = CreateQueryEvent(),
  __doc_OnGetPlayerDamageMod = "Query: return integer to override _pDamageMod. Args: player, strMod, strDexMod, totalVit, isBow, isShield, isStaff, isUnarmed. Return nil to keep default.",

  ---Query event fired from GetManaAmount for classes that don't match the named-class
  ---mana cost reduction checks (Sorcerer 50%, Rogue/Monk/Bard 25%).
  ---Return an integer to replace the mana cost. Return nil to pay full cost.
  OnGetManaCost = CreateQueryEvent(),
  __doc_OnGetManaCost = "Query: return integer to override spell mana cost. Fires only for classes without a hardcoded mana cost reduction. Return nil for full cost.",

  ---Query event fired at the CriticalStrike class-flag check in DealDamage and P2PGetDamageDealt.
  ---Return true to grant critical strike ability (50% chance per level to 2x damage).
  ---Return nil to use the class flag only.
  OnPlayerHasCriticalStrike = CreateQueryEvent(),
  __doc_OnPlayerHasCriticalStrike = "Query: return true to grant critical strike (50% chance per level to 2x melee damage). Return nil to use class flag only.",

  ---Query event fired at the IronSkin class-flag check in CalcPlrDamageMod.
  ---Return true to grant iron skin (AC += level/4).
  ---Return nil to use the class flag only.
  OnPlayerHasIronSkin = CreateQueryEvent(),
  __doc_OnPlayerHasIronSkin = "Query: return true to grant iron skin (AC += level/4). Return nil to use class flag only.",

  ---Query event fired at the NaturalResistance class-flag check in CalcPlrResistances.
  ---Return true to grant natural resistance (all resistances += level).
  ---Return nil to use the class flag only.
  OnPlayerHasNaturalResistance = CreateQueryEvent(),
  __doc_OnPlayerHasNaturalResistance = "Query: return true to grant natural resistance (all resists += level). Return nil to use class flag only.",

  ---Query event fired in GetDamageAttackArrow for the bow _pDamageMod contribution.
  ---fullMod is player._pDamageMod (the full modifier). Default is fullMod for Rogue, fullMod/2 for others.
  ---Return an integer to replace the damage modifier added to arrow damage.
  OnGetBowDamageMod = CreateQueryEvent(),
  __doc_OnGetBowDamageMod = "Query: return integer to override bow damage modifier contribution. fullMod = player._pDamageMod. Return nil to use class default (Rogue=full, others=half).",

  ---Query event fired after the class velocity checks in AddSpectralArrow and AddArrow.
  ---Return an integer bonus to ADD to arrow velocity (stacks with existing class bonus).
  ---Return nil or 0 for no extra bonus.
  OnGetArrowVelocityBonus = CreateQueryEvent(),
  __doc_OnGetArrowVelocityBonus = "Query: return integer bonus to add to arrow velocity (stacks with class bonus). Return nil or 0 for no bonus.",

  ---Query event fired from CalcPlrBlockFlag for classes that are not HeroClass::Monk.
  ---isHoldingStaff and isUnarmed describe the current weapon state.
  ---Return true to enable Monk-style blocking: staff = FastBlock, unarmed/single-weapon = normal block.
  ---Return nil to disallow blocking without a shield.
  OnPlayerCanBlockWithoutShield = CreateQueryEvent(),
  __doc_OnPlayerCanBlockWithoutShield = "Query: return true to enable Monk-style block without a shield (staff=FastBlock, unarmed/single=normal). isHoldingStaff and isUnarmed are passed. Return nil to disallow.",

  ---Query event fired from GetPlrAnimArmorId for classes that are not HeroClass::Monk.
  ---armorType is \"Light\", \"Medium\", or \"Heavy\". isUnique is true for unique-quality items.
  ---Return an integer to add to _pIAC (armor class). Return nil or 0 for no bonus.
  OnGetArmorLevelBonus = CreateQueryEvent(),
  __doc_OnGetArmorLevelBonus = "Query: return integer AC bonus to add based on armor type. armorType: \"Light\"/\"Medium\"/\"Heavy\". isUnique: true for unique items. Return nil or 0 for no bonus.",

  ---Query event fired from StartPlrHit before the hit-recovery animation decision.
  ---baseThreshold is the damage floor (dam>>6 must be >= threshold to stagger the player).
  ---The Barbarian's level+level/4 bonus is pre-applied by C++ before this fires.
  ---Return an integer to override the threshold. Return nil to keep baseThreshold unchanged.
  OnGetHitRecoveryThreshold = CreateQueryEvent(),
  __doc_OnGetHitRecoveryThreshold = "Query: return integer to override the hit-recovery stagger threshold (dam>>6 < threshold = no stagger). Barbarian bonus is pre-applied. Args: player, baseThreshold. Return nil to keep.",

  ---Query event fired from CalcPlrDamage when a player has no weapon equipped
  ---(both hand slots empty and no shield; minDamage and maxDamage were 0 entering the function).
  ---Return a table {newMin, newMax} to set damage floors. Return nil for no change.
  OnGetUnarmedDamageFloor = CreateQueryEvent(),
  __doc_OnGetUnarmedDamageFloor = "Query: return {minDamage, maxDamage} table to set unarmed damage floors. Fires only when player has no weapon equipped. Args: player, currentMin, currentMax. Return nil for no change.",

  ---Query event fired from getBaseToBlock() for every block-chance calculation.
  ---baseBonusFromTsv is the class's TSV blockBonus value.
  ---Return an integer to replace the block bonus. Return nil to keep baseBonusFromTsv unchanged.
  OnGetBlockChanceBonus = CreateQueryEvent(),
  __doc_OnGetBlockChanceBonus = "Query: return integer to replace the block chance bonus (replaces TSV blockBonus). Fires on every block-chance calculation. Args: player, baseBonusFromTsv. Return nil to keep.",

  ---Query event fired from RestorePartialLife for classes that are not Warrior/Barbarian/Rogue/Monk/Bard.
  ---l is the base partial heal amount (before class multiplier). Return an integer to replace l.
  ---Return nil to heal the base amount (no multiplier).
  OnGetPotionHealAmount = CreateQueryEvent(),
  __doc_OnGetPotionHealAmount = "Query: return integer to override partial potion heal amount. Fires for classes without a hardcoded heal multiplier. Return nil for 1x base amount.",

  ---Query event fired from RestorePartialMana for classes that are not Sorcerer/Rogue/Monk/Bard.
  ---l is the base partial mana amount (before class multiplier). Return an integer to replace l.
  ---Return nil to restore the base amount (no multiplier).
  OnGetPotionManaAmount = CreateQueryEvent(),
  __doc_OnGetPotionManaAmount = "Query: return integer to override partial potion mana amount. Fires for classes without a hardcoded mana multiplier. Return nil for 1x base amount.",

  ---Query event fired in CalculateArmorPierce when a melee hit lands.
  ---Return true to grant Barbarian-style armor pierce (subtracts monsterArmor/8 from effective armor).
  ---Return nil to use class check only (Barbarian only by default).
  OnPlayerHasArmorPierce = CreateQueryEvent(),
  __doc_OnPlayerHasArmorPierce = "Query: return true to grant armor pierce in melee (reduces effective monster AC by 1/8). Return nil to use class check only.",

  ---Query event fired from CanCleave() for classes that are not named classes.
  ---isHoldingAxe, isHoldingTwoHandedHeavy (2H mace/sword without shield), isHoldingStaff describe weapon state.
  ---Return true to grant cleave for the current weapon. Return nil to disallow.
  OnPlayerCanCleave = CreateQueryEvent(),
  __doc_OnPlayerCanCleave = "Query: return true to grant cleave. isHoldingAxe, isHoldingTwoHandedHeavy, isHoldingStaff passed. Return nil to disallow.",

  ---Event fired from OperateShrineOily default case (classes not handled by the switch).
  ---Use player:modifyStat(name, amount) to grant the shrine bonus. CheckStats and CalcPlrInv are called automatically after this event.
  OnOilyShrine = CreateEvent(),
  __doc_OnOilyShrine = "Fired when an unrecognised class activates an Oily Shrine. Use player:modifyStat() to grant the bonus.",

  ---Query event fired from GetPlrAnimArmorId for any player wearing Medium or Heavy armor.
  ---Override the resolved armor sprite tier. Receives (player, currentGraphic) where currentGraphic is "Light", "Medium", or "Heavy".
  ---Return "Light", "Medium", or "Heavy" to override; return nil to use the default.
  ---AC bonuses from equipped armor still apply; only the animation sprite set changes.
  OnGetPlayerArmorGraphic = CreateQueryEvent(),
  __doc_OnGetPlayerArmorGraphic = "Query: return \"Light\", \"Medium\", or \"Heavy\" to override the resolved armor sprite tier. Receives (player, currentGraphic). AC bonuses still apply. Return nil for default behavior.",

  ---Query event fired from UpdateEnemy for every MFLAG_GOLEM monster evaluating a new target.
  ---Args: ally (Monster), candidate (Monster).
  ---Runs once per active monster per ally per tick, so keep the handler cheap: gate on distance first
  ---and query line of sight lazily via ally:hasLineOfSightTo(candidate) only for candidates worth it.
  ---Return false to reject the candidate. Return nil or true to allow (default: true).
  OnGolemCanTargetMonster = CreateQueryEvent(),
  __doc_OnGolemCanTargetMonster = "Query: return false to prevent a golem/ally from targeting the candidate monster. Args: ally, candidate. Runs per active monster per ally per tick — gate on distance first, use ally:hasLineOfSightTo(candidate) for lazy LOS. Return nil or true to allow.",

  ---Query event fired from UpdateEnemy when a golem/player-minion evaluates ANOTHER golem/player-minion as a target.
  ---Vanilla always prevents golems from fighting each other; this hook can permit it (e.g. pets of mutually-hostile players).
  ---Args: ally (Monster), candidate (Monster — also a golem/player-minion).
  ---Return true to allow targeting. Return nil or false to keep them from fighting (default: false).
  OnGolemCanTargetGolem = CreateQueryEvent(),
  __doc_OnGolemCanTargetGolem = "Query: return true to allow a golem/ally to target another golem/ally (e.g. mutually-hostile players' pets). Args: ally, candidate. Return nil or false to prevent (default: false).",

  ---Query event fired from GolumAi when a golem has a target not yet in melee range, before pathing toward it.
  ---Args: ally (Monster), target (Monster).
  ---Return false to block the ally from walking toward the target this tick (falls through to idle walk).
  ---Return nil or true to allow normal chase (default: true).
  OnGolemCanChaseTarget = CreateQueryEvent(),
  __doc_OnGolemCanChaseTarget = "Query: return false to block a golem/ally from pathing toward its target. Args: ally, target. Return nil or true to allow chase.",

  ---Query event fired from IsValidMonsterForSelection for every MFLAG_GOLEM monster under the cursor.
  ---Return true to allow cursor selection. Return nil or false to block (default: false for all golems).
  OnGolemCanSelect = CreateQueryEvent(),
  __doc_OnGolemCanSelect = "Query: return true to allow the cursor to select a golem/ally monster. Return nil or false to block selection.",

  ---Query event fired from GolumAi on each idle-walk tick.
  ---Args: ally (Monster), hasTarget (bool — true when pursuing an enemy), enemyPosition (Point — valid when hasTarget).
  ---Return a Point to walk toward. Return false to stand still (Lua takes ownership, no fallback walk).
  ---Return nil to use the engine default (random-walk in the owner's facing direction; use for non-modded golems).
  OnGolemIdle = CreateQueryEvent(),
  __doc_OnGolemIdle = "Query: return Point to walk (AiPlanPath first, RandomWalk fallback), false to stand still, nil for engine default. Args: ally, hasTarget (bool), enemyPosition (Point).",

  ---Query event fired from GolumAi after UpdateEnemy, before the melee-attack and chase block.
  ---Args: ally (Monster), hasTarget (bool), distanceToTarget (int, -1 if no target), hasLOS (bool).
  ---Return true to signal Lua handled this tick entirely (engine skips attack/chase/idle). Return nil or false to let engine proceed normally.
  OnGolemChooseAction = CreateQueryEvent(),
  __doc_OnGolemChooseAction = "Query: return true to consume the GolumAi tick (skip melee/chase/idle). Args: ally, hasTarget (bool), distanceToTarget (int), hasLOS (bool).",

  ---Query event fired from SpawnBoy (Wirt's item generation) for classes not handled by the built-in switch.
  ---itemType is one of: "LightArmor", "MediumArmor", "HeavyArmor", "Shield", "Axe", "Bow", "Mace", "Sword", "Helm", "Staff", "Ring", "Amulet".
  ---Return true to exclude this item type (forces a reroll). Return nil or false to allow.
  OnShouldExcludeWirtItem = CreateQueryEvent(),
  __doc_OnShouldExcludeWirtItem = "Query: return true to exclude an item type from Wirt's item for this player. itemType: \"Bow\"/\"Staff\"/\"Sword\" etc. Return nil or false to allow.",

  ---Query event fired from GetSpellListItems to collect custom scroll entries for the speedbook.
  ---Return a table of {name, seed, spell, count} entries to inject, or nil for none.
  ---count is optional (defaults to -1 = standard inventory count).
  OnGetCustomSpeedbookScrollEntries = CreateQueryEvent(),
  __doc_OnGetCustomSpeedbookScrollEntries = "Query: return a table of {name, seed, spell, count} to inject as custom scroll entries in the speedbook. Return nil for none.",

  ---Called when the player uses (consumes) any item via right-click or belt hotkey.
  ---Args: player, miscId (integer matching items.ItemMiscID.*), spellId (integer, 0 for items with no spell).
  ---Fires after the item's C++ effect is applied (e.g., HP/mana already restored for FullRejuv).
  OnItemUsed = CreateEvent(),
  __doc_OnItemUsed = "Called when a player consumes an item. Args: player, miscId (int), spellId (int). Effect already applied before this fires.",

  ---Called after a floor item is successfully moved into the player's inventory, belt, or equipment slot.
  ---Args: player, item (the floor item as it was before pickup — use item.seed to find the live inventory copy).
  ---Fires before the floor entry is cleaned up, so item.seed and all attributes are still valid for identification.
  OnItemPickedUp = CreateEvent(),
  __doc_OnItemPickedUp = "Called after a floor item is picked up. Args: player, item (floor item snapshot). Use player:findScrollBySeed(item.seed) to get the live inventory copy.",

  ---Query event fired when a player reaches a floor item to pick it up, before the network request is sent.
  ---Args: player, item (the floor item). Return false to forbid this player from picking it up (e.g. class-restricted items); the pickup silently cancels. Return nil or true to allow (default: true).
  OnPlayerCanPickUpItem = CreateQueryEvent(),
  __doc_OnPlayerCanPickUpItem = "Query: return false to forbid a player from picking up a floor item (silently cancels). Args: player, item. Return nil or true to allow (default: true).",

  ---Query event fired in UseInvItem before the Auto Refill Belt redirect, for the belt item being used.
  ---Args: player, item (the selected belt item). Return false to exempt this item from auto-refill so the exact selected belt slot is used (e.g. seeded custom scrolls that must not be swapped for an identical-looking copy). Return nil or true to allow the default redirect (default: true).
  OnCanAutoRefillBeltItem = CreateQueryEvent(),
  __doc_OnCanAutoRefillBeltItem = "Query: return false to exempt a belt item from the Auto Refill Belt redirect (the exact selected belt slot is used). Args: player, item. Return nil or true to allow (default: true).",

  ---Query event fired from GetSpellListSelection after the built-in starting-skill type promotion.
  ---Args: player, spellId (int), originalType (string), promotedType (string).
  ---Return "Skill", "Spell", "Scroll", or "Charges" to override the resolved type; return nil to keep promotedType.
  OnGetSpeedbookSelectionType = CreateQueryEvent(),
  __doc_OnGetSpeedbookSelectionType = "Query: return \"Skill\"/\"Spell\"/\"Scroll\"/\"Charges\" to override the resolved SpellType for a selected speedbook entry. originalType is the entry's own type; promotedType is after starting-skill promotion. Return nil to keep promotedType.",

  ---Query event fired from DrawSpellList when rendering the info string for a hovered speedbook entry.
  ---Args: player, spellId (int), defaultName (string — the spell's sNameText from data).
  ---Return a string to override the spell's display name in the info box. Return nil to keep defaultName.
  OnGetSpeedbookSpellName = CreateQueryEvent(),
  __doc_OnGetSpeedbookSpellName = "Query: return a string to override the spell name shown in the speedbook info box. Args: player, spellId (int), defaultName (string). Return nil to keep defaultName.",

  ---Query event fired from GetSpellListItems for every entry about to be added to the speedbook.
  ---Args: player, spellId (int), spellType (string: "Skill"/"Spell"/"Scroll"/"Charges").
  ---Return true to hide this entry from the speedbook. Return nil or false to show it (default).
  OnShouldHideSpeedbookSpell = CreateQueryEvent(),
  __doc_OnShouldHideSpeedbookSpell = "Query: return true to hide a speedbook entry. Args: player, spellId (int), spellType (\"Skill\"/\"Spell\"/\"Scroll\"/\"Charges\"). Return nil or false to show.",

  ---Query event fired from CheckSBook when the player clicks a learned spell (SpellType::Spell) in the spellbook panel.
  ---Does not fire for skills or staff charges. Args: player, spellId (int).
  ---Return false to block the selection (spell is not set as the active cast spell). Return nil or true to allow.
  OnCanSelectSpellBookEntry = CreateQueryEvent(),
  __doc_OnCanSelectSpellBookEntry = "Query: return false to block a learned spell from being selected as the active cast spell via the spellbook. Only fires for SpellType::Spell entries. Args: player, spellId (int). Return nil or true to allow.",

  ---Query event fired from CheckPlrSpell for every SpellType::Scroll cast, before the cast command is sent.
  ---Lets a mod that overloads one scroll SpellID across many distinct scrolls target the exact scroll the player selected.
  ---Args: player, spellId (int), selectedSeed (int — seed of the custom speedbook entry chosen, 0 if none), defaultSlot (int — 0 = vanilla "first matching scroll").
  ---Return an INVITEM_* slot index (inventory 7-46, belt 47-54) to cast from that exact slot; return nil or defaultSlot to keep vanilla behavior.
  OnResolveCustomScrollSlot = CreateQueryEvent(),
  __doc_OnResolveCustomScrollSlot = "Query: return the INVITEM_* slot a scroll cast should consume/resolve from. Args: player, spellId (int), selectedSeed (int), defaultSlot (int). Return nil or defaultSlot for vanilla first-match behavior.",

  ---Query event fired from CheckPlrSpell while validating a SpellType::Scroll cast, before the cast is committed or the scroll is consumed.
  ---Lets a mod veto a scroll cast up front (e.g. when its custom effect cannot proceed, or to stop an offensive scroll hitting a protected monster) so the engine refuses the cast and nothing is consumed.
  ---Args: player, spellId (int), selectedSeed (int — seed of the custom speedbook entry chosen, 0 if none), target (monster — the cursor-targeted monster, or nil if none / not a monster-aimed cast such as the inventory/belt use-gate).
  ---Return false to block the cast (the mod is responsible for any "I can't do that" feedback); return nil or true to allow.
  OnCanCastScroll = CreateQueryEvent(),
  __doc_OnCanCastScroll = "Query: return false to block a scroll cast before it is committed/consumed. Args: player, spellId (int), selectedSeed (int), target (monster or nil). Return nil or true to allow.",

  ---Query event fired from CheckPlrSpell while validating a SpellType::Skill cast, before the cast is committed.
  ---Lets a mod veto a skill cast up front (e.g. a targeting gate on the cursor-targeted monster).
  ---Args: player, spellId (int), target (monster — the cursor-targeted monster, or nil if none hovered).
  ---Return false to block the cast (the mod is responsible for any "I can't do that" feedback); return nil or true to allow.
  OnCanCastSkill = CreateQueryEvent(),
  __doc_OnCanCastSkill = "Query: return false to block a skill cast before it is committed. Args: player, spellId (int), target (monster or nil). Return nil or true to allow.",

  ---Query event fired when the item info box is rendering an item's description line.
  ---Args: item. Return a string to override the default miscId-derived description; return nil for default.
  OnGetMiscItemDescription = CreateQueryEvent(),
  __doc_OnGetMiscItemDescription = "Query: return a string to add or override the description line for any misc item in the info box. Receives (item). Return nil for default behavior.",

  ---Query event fired from PrintItemDetails when an ITEM_QUALITY_UNIQUE item is hovered, after curruitem is set.
  ---Call items.setCustomUniqueBox(name, lines) inside this handler to populate the slot, then return true.
  ---Returning true causes DrawUniqueInfo to use the Lua-populated slot instead of UniqueItems[_iUid].
  ---Returning nil or false uses the normal engine rendering (UniqueItems table data).
  OnPrepareUniqueInfoBox = CreateQueryEvent(),
  __doc_OnPrepareUniqueInfoBox = "Query: fired when a unique item is hovered. Call items.setCustomUniqueBox(name, lines) then return true to replace the unique popup. Return nil for default engine rendering.",

  ---Event fired when a MFLAG_GOLEM monster kills another monster via melee.
  ---Args: ally (Monster), victim (Monster).
  OnGolemKilledMonster = CreateEvent(),
  __doc_OnGolemKilledMonster = "Fired when a golem/ally kills a monster in melee. Args: ally, victim.",

  ---Event fired when a MFLAG_GOLEM monster spawns another monster via a special ability
  ---(e.g. a tamed Skeleton King spawning skeletons, a tamed Hork Demon's Hork Spawn).
  ---Args: ally (Monster — the spawner), newMonster (Monster — the freshly spawned monster).
  ---Use to adopt the spawn as an owned minion (`newMonster:makeGolem()` + track it).
  OnGolemSpawnedMinion = CreateEvent(),
  __doc_OnGolemSpawnedMinion = "Fired when a golem/ally spawns a new monster via a special ability. Args: ally (spawner), newMonster. Adopt as a minion if desired.",

  ---Query event fired from the monster info box in place of PrintMonstHistory.
  ---Args: monster. Return a table of strings to fully replace the info block; return nil for default (PrintMonstHistory).
  OnGetMonsterInfo = CreateQueryEvent(),
  __doc_OnGetMonsterInfo = "Query: return a table of strings to replace the entire monster info block in the info box. Args: monster. Return nil for default behavior (PrintMonstHistory).",

  ---Query event fired from the info box to override the name shown for a hovered monster.
  ---Args: monster. Return a string to replace the default name; return nil to keep monster.name.
  OnGetMonsterDisplayName = CreateQueryEvent(),
  __doc_OnGetMonsterDisplayName = "Query: return a string to override the monster name in the info box header. Args: monster. Return nil for default (monster.name).",

  ---Query event fired from DrawMonster to get a colored outline for a monster.
  ---Args: monster. Return a palette color index (0–255) to draw a 1px outline; return nil for no outline.
  ---PAL16_YELLOW+2 = 194 (gold/object color). PAL16_BLUE+7 = 183 (blue). PAL16_GRAY+5 = 245 (silver).
  OnGetMonsterOutlineColor = CreateQueryEvent(),
  __doc_OnGetMonsterOutlineColor = "Query: return a palette color index (0-255) to draw a colored outline around a monster sprite. Return nil for no outline.",

  ---Query event fired once per monster per rendered frame (in DrawMonster).
  ---Args: monster. Return a TRN handle (from monsters.registerTrn) to remap this monster's palette
  ---for the frame, e.g. a transient blink; return nil for the engine default. Wins over the
  ---unique/petrified/infravision TRN when set (but a monster on an unlit tile is drawn with the
  ---infravision TRN before this fires).
  OnGetMonsterTRN = CreateQueryEvent(),
  __doc_OnGetMonsterTRN = "Query: return a TRN handle (monsters.registerTrn) to override a monster's palette-remap for the frame. Return nil for default.",

  ---Query event fired from MonsterDeath before CheckQuestKill, for any dying monster.
  ---Args: monster. Return false to skip quest completion for this death (e.g. a tamed quest boss
  ---dying as a player-minion should not re-trigger its quest). Return nil or true to allow (default: true).
  OnMonsterCanCompleteQuest = CreateQueryEvent(),
  __doc_OnMonsterCanCompleteQuest = "Query: return false to prevent a dying monster from completing its quest (CheckQuestKill). Args: monster. Return nil or true to allow (default: true).",

  ---Query event fired from MonsterDeath on the final death-animation frame, before the monster's
  ---corpse is placed on the floor. Args: monster. Return false to suppress corpse placement for this
  ---death (the monster still vanishes and is reaped); return nil or true to place the corpse (default: true).
  OnMonsterCanPlaceCorpse = CreateQueryEvent(),
  __doc_OnMonsterCanPlaceCorpse = "Query: return false to suppress a dying monster's corpse placement. Args: monster. Return nil or true to place the corpse (default: true).",

  ---Query event fired when the monster healthbar decides whether to draw the resistance/immunity
  ---icon row. Vanilla shows it only for uniques or monster types killed 15+ times; return true to
  ---force it on (e.g. for tamed allies that reveal full stats). Args: monster. Default: false.
  OnMonsterCanShowResistances = CreateQueryEvent(),
  __doc_OnMonsterCanShowResistances = "Query: return true to force the monster healthbar's resistance/immunity icons to show, overriding the vanilla unique-or-15-kills gate. Args: monster. Return nil or false for vanilla behaviour (default: false).",

  ---Query event fired when an auto-targeting missile picks a monster to fire at: the Chain
  ---Lightning spread and FindClosest (Chain Lightning / Lightning bolt bounce, Bone Spirit homing).
  ---Args: monster, source (Point — the missile/cast origin tile). Return false to skip this
  ---monster (no bolt fired at it); return nil or true to allow (default: true).
  OnMissileCanTargetMonster = CreateQueryEvent(),
  __doc_OnMissileCanTargetMonster = "Query: return false to stop an auto-targeting missile (Chain Lightning, Bone Spirit) from targeting this monster. Args: monster, source (Point, the cast/bounce origin). Use source to also reject targets behind a protected monster. Return nil or true to allow.",

  ---Query event fired when a golem / player-minion (MFLAG_GOLEM) missile's damage is finalized (at
  ---missile creation, after the missile's own damage roll). Args: golem (the casting monster),
  ---missileId (int), dam (int). Return an integer to override the missile's damage; return nil to keep
  ---dam. Gated to MFLAG_GOLEM sources, so wild-monster missiles never fire it. Fires once per missile,
  ---including each segment of a multi-tick spell (every Inferno/Lightning spawn). Melee never fires this.
  OnGolemMissileDamage = CreateQueryEvent(),
  __doc_OnGolemMissileDamage = "Query: return integer to override a golem/player-minion missile's damage. Args: golem, missileId (int), dam (int). MFLAG_GOLEM sources only; fires per missile incl. each spell segment. Return nil to keep dam.",

  ---Query event fired just BEFORE a golem/player-minion (MFLAG_GOLEM) missile's damage is resolved
  ---against another monster (the MonsterTrapHit path, e.g. a player-minion's cast hitting an enemy
  ---monster), before the engine reads the target's resistance/immunity. Fired when either the source OR
  ---the target is a player-minion (MFLAG_GOLEM); wild-vs-wild missiles never fire it.
  ---Args: source (Monster — the source monster, may be nil for a trap), target (Monster — the monster
  ---being hit), missileId (int), damageType (int — monsters.DamageType.*). A handler may transiently
  ---mutate the target's resistance bitfield (restore it in the paired OnGolemMissilePostResolve so it
  ---only spans this one synchronous resolution) AND/OR return a DamageType int to reclassify the element
  ---the engine resolves this hit as (the engine's own immune/resist math then runs against that element).
  ---Return nil to keep the original damageType. Use to express resistance an element lacks (e.g. resolve
  ---acid as Magic so a monster's magic resistance applies — monster-side acid has no resist tier).
  OnGolemMissilePreResolve = CreateQueryEvent(),
  __doc_OnGolemMissilePreResolve = "Query (MFLAG_GOLEM on either end — source or target): fired before that missile resolves against the target monster. Args: source (may be nil), target, missileId (int), damageType (int). Transiently mutate target resistance (restore in OnGolemMissilePostResolve) and/or return a DamageType int to reclassify the resolved element (nil = keep damageType).",

  ---Event fired immediately AFTER the golem-missile-vs-monster resolution that OnGolemMissilePreResolve
  ---bracketed (same gate). Args: target (Monster). Use to restore any transient resistance change made
  ---in the pre hook.
  OnGolemMissilePostResolve = CreateEvent(),
  __doc_OnGolemMissilePostResolve = "Fired right after a golem-missile-vs-monster resolution (pairs with OnGolemMissilePreResolve). Args: target. Restore any transient resistance change here.",

  ---Query event fired before a player's left-click attack or offensive spell cast is queued on a monster.
  ---Args: player, monster. Return false to cancel (silently no-op); return nil or true to allow (default: true).
  OnPlayerAttackMonster = CreateQueryEvent(),
  __doc_OnPlayerAttackMonster = "Query: return false to cancel a player's attack or spell cast targeting a monster. Args: player, monster. Return nil or true to allow.",

  ---Query event fired when CURSOR_HEALOTHER is active and the cursor is over a monster tile.
  ---Return true to allow pcursmonst to be set (enabling monster click targeting); return nil or false to keep the default player-only restriction.
  OnCanSelectMonsterWithCursor = CreateQueryEvent(),
  __doc_OnCanSelectMonsterWithCursor = "Query: return true to allow monster selection while a player-only cursor (HealOther or Resurrect) is active. Args: cursorId (int, compare against player.CursorID.*). Return nil or false for default (player-only) behavior.",

  ---Query event fired from TryIconCurs when CURSOR_HEALOTHER is active and a monster was clicked (pcursmonst != -1).
  ---Args: monster. Return true to signal the action was handled (cursor resets to hand); return nil or false to leave cursor active.
  OnCursorMonsterTarget = CreateQueryEvent(),
  __doc_OnCursorMonsterTarget = "Query: called when a monster is clicked while the HealOther cursor is active. Args: monster. Return true to consume the click and dismiss cursor; return nil or false to leave cursor active.",

  ---Called when the player's save file is written. Return a sequence table of uint32 values to persist.
  ---Stored in a separate \"luamoddata\" entry in the save MPQ; the base game item format is not modified.
  ---Use OnLoadPlayerData to restore the values on the next load.
  OnSavePlayerData = CreateEvent(),
  __doc_OnSavePlayerData = "Called on save. Return a sequence table of uint32 values to persist in a separate mod-data file. Use OnLoadPlayerData to restore on load.",

  ---Called when the player's save file is loaded. Receives the flat uint32 sequence previously returned
  ---by OnSavePlayerData. Not called for old saves that predate the mod-data file.
  OnLoadPlayerData = CreateEvent(),
  __doc_OnLoadPlayerData = "Called on load with the flat uint32 sequence from the previous OnSavePlayerData return. Not called for old saves lacking mod data.",
}

---Registers a custom event type with the given name.
---@param name string
function events.registerCustom(name)
  events[name] = CreateEvent()
end

events.__sig_registerCustom = "(name: string)"
events.__doc_registerCustom = "Register a custom event type."

return events
