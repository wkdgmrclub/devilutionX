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

  ---Called when Player takes damage.
  OnPlayerTakeDamage = CreateEvent(),
  __doc_OnPlayerTakeDamage = "Called when Player takes damage.",

  ---Called when Player gains experience.
  OnPlayerGainExperience = CreateEvent(),
  __doc_OnPlayerGainExperience = "Called when Player gains experience.",

  ---Called just before the current level is saved and unloaded (level exit, warp, or player death).
  ---All monsters and items are still accessible. Drop or recall anything before this returns.
  OnLevelExit = CreateEvent(),
  __doc_OnLevelExit = "Called just before the current level is saved and unloaded (level exit or player death). Monsters and items are still valid.",

  ---Called inside RecreateItem for any item whose IDidx >= IDI_NUM_DEFAULT_ITEMS (Lua-registered custom items).
  ---Fires after InitializeItem and seed/dwBuff are restored, so item.seed and item.buff are valid.
  ---Use this to restore fields that InitializeItem resets (e.g. the display name).
  OnCustomItemRecreated = CreateEvent(),
  __doc_OnCustomItemRecreated = "Called after a custom (Lua-registered) item is recreated from save/delta data. item.seed and item.buff are valid; use to restore display name or other derived fields.",
}

---Registers a custom event type with the given name.
---@param name string
function events.registerCustom(name)
  events[name] = CreateEvent()
end

events.__sig_registerCustom = "(name: string)"
events.__doc_registerCustom = "Register a custom event type."

return events
