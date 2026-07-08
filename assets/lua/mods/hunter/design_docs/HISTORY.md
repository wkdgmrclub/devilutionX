# Hunter Mod — Implementation Reference

Current-state implementation details, organized by the phase that introduced each system. Describes what the mod does now; the code is the authoritative source. Bug history lives in `bugs.md`.

---

## Phase 1 — Generic monster info (C++ only)
Extended Monster usertype (all readonly): `name`, `health`, `maxHealth`, `isUnique`, `isQuestMonster`.
- `isQuestMonster` — true for `isUnique() || type == MT_DIABLO`; Diablo is NOT in UniqueMonsterType
- Added `OnMonsterDeath(monster)` — fires at top of `MonsterDeath()` before HP is zeroed
- HP uses fixed-point `>> 6` shift (same as `hasNoLife()`)

Files: `Source/lua/modules/monsters.cpp`, `Source/lua/lua_event.hpp/.cpp`, `assets/lua/devilutionx/events.lua`, `Source/monster.cpp`

---

## Phase 2 — Generic spell/skill cast hook (C++)
Added `OnSpellCast(player, spellId, spellType, targetMonster, scrollSeed, targetX, targetY)`.
Hook added to ACTION_SPELL, ACTION_SPELLWALL, ACTION_SPELLMON cases in `Source/player.cpp`. No existing signatures changed.
Note: event fires BEFORE StartSpell validity check — rare edge case where event fires but mana cast fails.

Files: `Source/lua/lua_event.hpp/.cpp`, `assets/lua/devilutionx/events.lua`, `Source/player.cpp`

---

## Phase 3 — Monster allegiance API
Added `monster:makeAlly(player)` → calls `MakeMonsterAlly(monster, player)` in C++.
- Sets `MFLAG_GOLEM | MFLAG_ALLY_SELECTABLE`; stores owner in `monster.allyOwnerPlayerId`
- Preserves natural `toHit` via `golemToHit`; resets goal; calls `UpdateEnemy` immediately
- `MFLAG_ALLY_SELECTABLE = 1 << 13` added to `monster_flag`
- `IsValidMonsterForSelection` in `cursor.cpp` updated to flag-based check

Files: `Source/lua/modules/monsters.cpp`, `Source/monster.cpp`, `Source/monster.h`, `Source/cursor.cpp`

---

## Phase 4 — Generic additive data loading + Hunter class + Tame skill
Generic infrastructure (no mod-specific enum changes):
- `SpellDataLoaded` / `PlayerDataLoaded` events
- `spells.addSpellDataFromTsv(name, path)` — appends to `LuaDynamicSpellIds`
- `player.addClassDataFromTsv(path)` — appends to `PlayersData`
- New `Source/lua/modules/spells.cpp`

Mod data: `mods/hunter/txtdata/spells/tame.tsv`, `txtdata/classes/classdat_hunter.tsv`, `txtdata/classes/hunter/`

Files: `Source/tables/spelldat.cpp/.h`, `Source/tables/playerdat.cpp`, `Source/lua/lua_event.hpp/.cpp`, `assets/lua/devilutionx/events.lua`, `Source/lua/modules/spells.cpp/.hpp`, `Source/lua/modules/player.cpp`, `Source/lua/lua_global.cpp`, `Source/CMakeLists.txt`

---

## Phase 5 — Hunter Lua mod (init.lua)
`SpellDataLoaded` → registers Tame + SharePotion, captures IDs.
`PlayerDataLoaded` → registers Hunter class.
`OnSpellCast` → tame/retame/deploy logic.
`OnMonsterDeath` → clears tracking.
`GameDrawComplete` → leash snap at 12 tiles.

## Phase 5b — Heal Other (not implemented)
Heal Other is not used. Its spell flow is deeply multiplayer-oriented (CMD_HEALOTHER → msg.cpp) and resists Lua interception; revisiting it would mean implementing entirely in C++ or as a dedicated skill.

## Phase 5c — Pet leash / snap-to-player
`monster:snapToPlayer(player)` — teleport with pre-clear of dMonster at all three position fields + mode reset to prevent walk-step ghost entries.
`monster:distanceTo(player)` — Chebyshev distance, const-safe.
`InitPointUserType` — registers Point with .x/.y for all mods.
`player.lightRadius` — readonly property.
Leash threshold `LEASH_DISTANCE = 12` in init.lua.

---

## Phase 6 — Monster Scroll System
Taming destroys the monster and drops a Tame Scroll. Casting the scroll deploys the monster.
- Seed encoding: upper 16 bits = counter, lower 16 bits = typeId
- `dwBuff` encoding: maxHp at full 15-bit resolution (bits 1–15), monster level (16–21), captured difficulty (22–23), current HP as a percent of max (24–31). See "Max-HP stability" below for the rationale.
- `TAME_SCROLL_MAP = 90001`
- `items.spawnAt` calls `LuaDeltaRegisterDroppedItem` for multiplayer persistence
- `monsters.spawnAt` uses `InitMonsterGFX` (not `InitAllMonsterGFX`) to avoid null-sprite crash

Key C++ hooks added: `monster.level`, `monster.isAlly`, `monster:remove()`, `monster:setHitPoints(hp)`, `monsters.spawnAt`, `items.spawnAt`, `player:findScrollSeedOf`, `LuaDeltaRegisterDroppedItem` (`Source/msg.cpp`).
`LuaDeltaRegisterDroppedItem` must use `currlevel`/`setlevel`/`setlvlnum` globals (not `MyPlayer->plrlevel`) because `plrlevel` is already the destination level when `OnLevelExit` fires.

---

## Phase 7 — Retame + Auto-recall
Tame skill dual-purposes: hostile ≤30% HP → tame scroll on floor; own deployed ally → retame scroll on floor.
`OnLevelExit` → `recallAllyToInventory` → `addScrollByMapping` to inventory; floor fallback at ally's former tile (capture `allyPos` BEFORE `ally:remove()`).
New C++ hook: `player:addScrollByMapping(mappingId, seed, name, dwBuff?)`.

## Phase 7b — Tame Scroll Data Persistence
`_iSeed` and `dwBuff` both survive pfile and delta round-trips. Monster data encoded at creation; recovered at deploy time via `recoverScrollData`.
Pepin healing: re-encodes `dwBuff` with `savedHp = maxHp` for both in-session and post-restart scrolls.
New C++ hooks: `monsters.getNameByTypeId`, `player:findScrollBySeed`, `player:iterateInventory`.

## Phase 7c — Full scroll persistence + snap ghost fix
Root cause of scroll disappearing on restart: `RemapItemIdxToDiablo(168)` returned -1 (stored as 0xFFFF = empty slot). Fixed by `if (i >= IDI_NUM_DEFAULT_ITEMS) return i;` passthrough in `Source/loadsave.cpp`.
Root cause of name loss: `InitializeItem` in `RecreateItem` zeroed the struct after `dwBuff` was set. Fixed: `dwBuff` and `OnCustomItemRecreated` event now fire AFTER `InitializeItem`, inside `idx >= IDI_NUM_DEFAULT_ITEMS` guard.
snapToPlayer ghost fix: zero dMonster at old/tile/future before `M_ClearSquares`; reset mode to Stand before `occupyTile`.

Files: `Source/items.cpp`, `Source/loadsave.cpp`, `Source/lua/lua_event.hpp/.cpp`, `assets/lua/devilutionx/events.lua`, `Source/lua/modules/monsters.cpp`, `Source/lua/modules/player.cpp`

---

## Phase 8 — Share Potion skill
Skill scans inventory then belt for first health potion:
- Potion of Full Healing → restore ally to 100% HP
- Potion of Healing → restore `min(current + 30% maxHp, maxHp)`
- None found / invalid target → `ICantDoThat` voice line

New C++ hooks: `player:say(speechId)`, `player.HeroSpeech` enum table.

---

## Phase 9 — Hunter Class Design (complete)

**Identity:** Warrior sprites/portrait/inv, Rogue stats, Sorcerer voice lines.
**Skills:** Tame (starting), Share Potion (granted via `addSkill` in `OnLevelEnter`).
**Loadout:** `item0=IDI_ROGUE`, `item1/2=IDI_HEAL`, 100 gold. Starting Tame Scroll (Lvl 2 Scavenger) via `OnCreatePlrItems`.
**Key C++ additions:** `player:addSkill`, `OnGetAnimationSkipFrames` query event, `OnGetPlayerIdleFrames` query event, `OnLevelEnter` event, `OnNewCharacter` event.

**Implemented in Phase 9:**
- Potion of Forgetting (`FORGET_POTION_MAP = 90002`) — resets all base stats; Pepin stock; `OnItemUsed` + `OnGetMiscItemDescription` hooks
- `OnGetMiscItemDescription` hook — generic query from `PrintItemMisc` for all misc items
- Ally kill counter — `OnGolemKilledMonster` + `allyKillCounts[seed]` + `OnGetMonsterInfo`; `getTypeKillCount`, `getTypeHpRange`, `getTypeResistances` monster module accessors
- Tame+/Tame++ tier system — all taming logic in `OnSpellCast`; `monster.uniqueType` readonly property
- Unique monster scroll support — `0x8000 | uniqueTypeIdx` seed encoding; `monsters.spawnUniqueAt`
- Difficulty-frozen stat preservation — `capturedDifficulty` (bits 22–23 of `dwBuff`); `spawnWithDifficulty` + `spawnUniqueAt` freeze/restore
- Adaptive archetype system — 29 C++ hooks; all Lua handlers in `init.lua`
- Stat-scaled animation frames — `OnGetAnimationSkipFrames` tiers by STR/DEX/MAG
- Elixir restriction — `OnCanPlayerUseItem` blocks all stat-raising elixirs
- Per-stat cap (250) + total budget freeze (460) — `attributes.tsv` + `OnGetMaxAttributeValue`
- `OnGetCustomSpeedbookScrollEntries` + `OnGetSpeedbookSelectionType` — per-scroll speedbook entries, deduped by name
- `player:classBaseStats()`, `player:resetStats()`, `player:modifyStat()` — `Source/lua/modules/player.cpp`
- `monsters.currentDifficulty()`, `monsters.getUniqueName()`, `monster.uniqueType` — `Source/lua/modules/monsters.cpp`
- `OnGetHitRecoveryThreshold(player, baseThreshold) -> int|nil` — Barbarian stagger resistance for Hunter archetype; `Source/player.cpp` `StartPlrHit`
- `OnGetUnarmedDamageFloor(player, minDamage, maxDamage) -> {int,int}|nil` — Monk unarmed damage floor for Hunter archetype; `Source/items.cpp` `CalcPlrDamage`
- `OnGetBlockChanceBonus(player, baseBonusFromTsv) -> int|nil` — archetype block bonus; `Player::getBaseToBlock()` moved to `Source/player.cpp`; Hunter TSV `blockBonus` corrected to 10 (base); Warrior/Barb→30, Monk→25, Rogue→20 via Lua

**Phase 9 final items (completed):**

- **Share Potion level-scaling proc** — Two independent `1% × level` rolls per use: `freecast` (potion not consumed) and `overheal` (ally set to 150% maxHP). Pure Lua in `OnSpellCast` handler for `SHARE_POTION_ID`. `monster:setHitPoints(hp)` is unclamped so values above maxHP work.

- **Tame+/Tame++ speedbook display name** — New `OnGetSpeedbookSpellName(player, spellId, defaultName) -> string|nil` query hook; fires in `DrawSpellList` for all hovered entries. Hunter Lua returns "Tame+" at level 30, "Tame++" at level 45, nil otherwise. Hook is generic — any mod can rename any spell's speedbook label. Files: `lua_event.hpp/.cpp`, `events.lua`, `Source/panels/spell_list.cpp`, `init.lua`.

- **Spell restrictions** — Three new hooks:
  - `OnShouldHideSpeedbookSpell(player, spellId, spellType) -> bool|nil` — fires in `GetSpellListItems` for every entry; return `true` to hide. Hunter hides all learned spells not on allowlist (Golem/Guardian/Healing/HealOther/ManaShield/Phasing/StoneCurse/Telekinesis/Teleport/TownPortal + Hellfire: Berserk/Reflect/Search/Warp) and also hides Golem scrolls. Scrolls and charges always show.
  - `OnCanSelectSpellBookEntry(player, spellId) -> bool|nil` — fires in `CheckSBook` only when `st == SpellType::Spell`; return `false` to block selection. Spellbook display unchanged; only click-to-equip is blocked for non-allowlisted spells.
  - Golem scroll item block — `OnCanPlayerUseItem` extended to return `false` for any Golem scroll (`item:isScrollOf(GOLEM_SPELL_ID)`); shows red in inventory.
  - `GOLEM_SPELL_ID = 21` constant in `init.lua` (matches `SpellID::Golem` in `spelldat.h`).
  - Files: `lua_event.hpp/.cpp`, `events.lua`, `Source/panels/spell_list.cpp`, `Source/panels/spell_book.cpp`, `init.lua`.

---

## Phase 10 — Gameplay Cap Enforcement (Lua-only)

Pure Lua additions in `init.lua`; no C++ changes.

- **`MAX_ALLIES = 8`** constant (co-located with `LEASH_DISTANCE`/`ENGAGE_RADIUS`).
- **`countDeployedAllies()`** — counts `deployedAllies` entries where `isMinion` is falsy. Future-proof: when the Minion System lands, minions are excluded automatically.
- **`isUniqueTypeDeployed(uniqueTypeIdx)`** — scans `deployedAllies` seeds via the existing `seedGetUniqueType()` helper.
- **Guards in the scroll deploy block** (after data recovery, before `monsters.spawnWithDifficulty` / `monsters.spawnUniqueAt`):
  - If `countDeployedAllies() >= 8` → `ICantDoThat` voice line, return.
  - If scroll is a unique type and `isUniqueTypeDeployed(data.uniqueTypeIdx)` → `ICantDoThat` voice line, return.
  - Duplicate check is by `uniqueTypeIdx` only; difficulty is irrelevant.

## Phase 10 — Auto-targeting Spell Exemption (C++ + Lua)

Auto-targeting spells (those that find a monster victim themselves — by homing, radius spread, or snap-to-nearest) must never fire at the Hunter's own / friendly tamed monsters, and — one step beyond base game — never fire *through* one of our pets at an enemy behind it. This is a pure **targeting** exemption (not damage immunity): a vetoed candidate simply isn't picked.

**The hook — `OnMissileCanTargetMonster(monster, source, default) -> bool|nil`:**
- Declared in `lua_event.hpp`, implemented in `lua_event.cpp` via `CallLuaEventReturn<bool>`, registered in `events.lua` as `CreateQueryEvent()`. Default `true` = vanilla.
- Carries the cast/origin tile (`source`) so the handler can inspect the origin→target line. All C++ comments marked `// Lua mod support`.

**Gated sites in `Source/missiles.cpp` (all at the targeting layer, default `true`):**
- `FindClosest` — the homing target-pick for **Bone Spirit** (`ProcessBoneSpirit`) and **Elemental** (`ProcessElemental`). Lambda returns `lua::OnMissileCanTargetMonster(&Monsters[mid-1], source, true)`.
- `ProcessChainLightning` — the radius **spread** `Crawl`; the hook is AND-ed into the existing target-pick `if` (origin = the spread `position`).
- `AddStoneCurse` — the snap-to-nearest seek lambda returns `lua::OnMissileCanTargetMonster(&monster, target, true)` on top of the existing `MT_GOLEM`/`MT_DIABLO`/`MT_NAKRUL` type exclusion. The candidate `target` tile is passed as the source, so the handler's path walk is inert (`source == target`) — correct for a non-traveling spell. Keeps the vanilla type check so the base-game Golem stays untouched.

**Lua handler (`init.lua`) — current form:**
```lua
events.OnMissileCanTargetMonster.add(function(monster, source)
  if isDeployedAlly(monster.id) then return false end           -- own ally / minion
  if isOtherHuntersAlly(monster) then                            -- a friendly other-Hunter's pet
    local me = player.self()
    local owner = player.get(monster.ownerPlayerId)
    if arePeaceful(me, owner) then return false end
  end
  local mp = monster.position
  if ownAllyNearPath(source.x, source.y, mp.x, mp.y) then return false end  -- pet on/near the firing line
end)
```
`ownAllyNearPath` pads the firing-line check by `PATH_PADDING = 1` tile (Chebyshev) and includes the target endpoint — Chain Lightning's spread bolts splash tiles *adjacent* to the rounded path, so an exact on-line test let a pet one tile off the line still get hit (and crash via the deferred re-entrant minion cleanup — see `bugs.md`).
Keyed off our own `deployedAllies` set, **not** `MFLAG_GOLEM`/`isGolem` — so a vanilla Golem is a normal targetable base-game monster (per the Golem barometer in `CLAUDE.md`).

**`player.id`:** returns the 0-based `Players` index (`player.getId()`), matching `player.get(id)` / `monster.ownerPlayerId`. This is what makes `isOtherHuntersAlly`'s own-pet early-return work (it compares slot indices, so the player's own vanilla Golem is correctly excluded from "another Hunter's pet"). Generic, modder-facing.

**Audit conclusion — what does NOT need this hook (verified by reading the code):**
- **Apocalypse / Guardian / Berserk** (`ProcessApocalypse`, `GuardianTryFireAt`, `AddBerserk`) already skip `isPlayerMinion()` in vanilla, so they never target our pets or the vanilla Golem. No change. (Faction-blindness — they also won't target a *hostile* Hunter's pets — is a deferred feature in `roadmap.md`.)
- **Ally-cast Apocalypse / Bone Spirit don't exist.** A tamed ally's authentic ranged attack routes through `StartGolemNaturalRangedAttack` → `GetMissileType(originalAi)`: Diablo → `DiabloApocalypse` (players-only, no monster seek — and Diablo is not tameable), BoneDemon → `BlueFlare2` (a straight-line directed flare, not the homing `BoneSpirit`). `MissileID::BoneSpirit` is fired only by the player spell. So no ally path needs gating, and the `FindClosest`/Chain Lightning gates (player spells only — no enemy AI routes through them) leave enemy abilities byte-for-byte vanilla.

---

## Phase 10 — Hunter Cannot Offensively Act on Own Allies (C++ + Lua)

Left-click attacks and offensive spell casts silently no-op when the cursor resolves to one of the Hunter's own deployed allies (including minions).

**New C++ additions:**
- `OnPlayerAttackMonster(player, monster) -> bool` query hook declared in `lua_event.hpp`, implemented in `lua_event.cpp` via `CallLuaEventReturn<bool>`, registered in `events.lua` as `CreateQueryEvent()`.
- Four thin call-outs in `Source/diablo.cpp`, all marked `// Lua mod support`:
  - `LeftMouseCmd` branch A (ranged weapon, no shift): hook as `else if` replacing bare `else` before `CMD_RATTACKID`.
  - `LeftMouseCmd` branch B (melee, shift): hook as `else if` replacing bare `else` before `CMD_SATTACKXY`.
  - `LeftMouseCmd` branch C (melee, no shift): hook wraps `CMD_ATTACKID` dispatch in an `if`.
  - `TryIconCurs` spell cursor: hook wraps `CMD_SPELLID` dispatch in an `if`.
- Default value `true` = allow, preserving all existing behavior when no Lua handler is registered.

**Lua handler (`init.lua`):**
```lua
events.OnPlayerAttackMonster.add(function(player, monster)
  for _, entry in ipairs(deployedAllies) do
    if entry.monster == monster then return false end
  end
end)
```
Blocks all four attack paths for any monster present in `deployedAllies` (regular allies and minions alike).

---

## Phase 10 — Share Potion Targeting Overhaul (C++ + Lua)

Share Potion now works like HealOther: activating the skill enters a targeting cursor mode, and the player clicks a deployed (non-minion) ally to apply the heal.

**New C++ additions:**
- `player:enterHealOtherMode()` in `Source/lua/modules/player.cpp` — calls `NewCursor(CURSOR_HEALOTHER)`. Added `#include "cursor.h"` to that file.
- `player.CursorID` table in `Source/lua/modules/player.cpp` — exposes all `cursor_id` enum values via `magic_enum` (same pattern as `player.HeroSpeech`), so Lua can compare cursor IDs by name (e.g. `player.CursorID.CURSOR_HEALOTHER`).
- `OnCanSelectMonsterWithCursor(cursorId: int) -> bool` hook — fired from the two `IsNoneOf(pcurs, CURSOR_HEALOTHER, CURSOR_RESURRECT)` guards in `Source/cursor.cpp` (pixel-based search and tile-based selection) when the cursor IS in the restricted set. `pcurs` is passed as `cursorId`. When Lua returns `true`, `pcursmonst` is allowed to be set in that restricted cursor state. All marked `// Lua mod support`.
- `OnCursorMonsterTarget(monster) -> bool` hook — fired from `TryIconCurs` in `Source/diablo.cpp` when `pcurs == CURSOR_HEALOTHER`, `PlayerUnderCursor == nullptr`, and `pcursmonst != -1`. Returns `true` = action handled, reset cursor to CURSOR_HAND; returns `false`/nil = cursor stays active.

**Lua changes (`init.lua`):**
- `applySharePotion(caster, target)` local helper — handles potion scan, level-scaling procs (freecast / overheal), full/partial heal, and "I can't do that" / "I don't need to do that" voice lines. Potion consumption and `audio.playSfx(ItemPotion)` only fire on a successful heal. Returns bool.
- `OnSpellCast` for Share Potion (spellType 0): calls `caster:enterHealOtherMode()` — no potion consumed, no sound. All targeting is deferred to the cursor click.
- `OnCanSelectMonsterWithCursor(cursorId)`: returns `true` only when `cursorId == player.CursorID.CURSOR_HEALOTHER`, leaving `CURSOR_RESURRECT` and any other restricted cursor unaffected.
- `OnCursorMonsterTarget`: scans `deployedAllies` for a matching non-minion entry; if found, calls `applySharePotion` and returns `true` (cursor dismissed). If not a valid target, returns nil (cursor stays for retry).

---

## Phase 10 — Visual Polish (C++ + Lua)

**New C++ hooks:**
- `OnGetMonsterDisplayName(monster) -> string` — fires in `DrawInfoBox` (`Source/control/control_infobox.cpp`) and `DrawMonsterHealthBar` (`Source/qol/monhealthbar.cpp`). C++ implementation passes `monster.name()` as the default via `CallLuaEventReturn`, so each callsite is a single unconditional replacement with no branching or logic added to engine code.
- `OnGetMonsterOutlineColor(monster) -> int` — fires in `DrawMonster` (`Source/engine/render/scrollrt.cpp`) after the infravision early-return, before the TRN/light draw. Returns `-1` (default) for no outline, or a palette index (0–255) to call `ClxDrawOutlineSkipColorZero` before drawing the main sprite.

Both hooks declared in `lua_event.hpp`, implemented in `lua_event.cpp` via `CallLuaEventReturn`, registered in `events.lua` as `CreateQueryEvent()`. All C++ additions marked `// Lua mod support`.

**Lua (`init.lua`):**
- `OnGetMonsterDisplayName`: returns `"Tamed " .. monster.name` for any `deployedAllies` entry. Name renders in default white InfoColor.
- `OnGetMonsterOutlineColor`: returns `194` (`PAL16_YELLOW+2`, same as engine object outlines) for deployed allies.
- Gold unique Tame Scrolls (`item.magical = 2` = `ITEM_QUALITY_UNIQUE`) set in three active paths:
  - `OnCustomItemRecreated` — save/load round-trip (unique scroll seed flag check)
  - `OnLevelEnter` fixup loop — `iterateInventory` sets quality for any unique tame scroll in inventory on every level entry
  - `OnItemPickedUp` — fires from `AutoGetItem` in `Source/inv.cpp` after successful placement; Lua calls `findScrollBySeed(floorItem.seed)` to get the live inventory copy and sets `magical = 2` immediately, closing the floor-drop same-session gap
  - `recallAllyToInventory` sets `magical = 2` — hover popup now handled by `OnPrepareUniqueInfoBox` (see below)

---

## Phase 10 — Unique item info box hijack for tame scrolls (C++ + Lua)

A unique tame scroll renders at gold/`magical = 2` quality, so hovering it triggers the engine's unique item info popup. `DrawUniqueInfo` unconditionally indexes `UniqueItems[curruitem._iUid]`, and a tame scroll has no real `_iUid` — without a redirect it would render as `UniqueItems[0]` ("The Butcher's Cleaver"). A mutable Lua-custom slot plus a one-line redirect in `DrawUniqueInfo` supplies the tamed monster's own info box instead.

**New C++ additions:**
- `constexpr int UITEM_LUA_CUSTOM = 0x7FFF` — sentinel value for `Item::_iUid`; stored only on the render-time `curruitem` global copy, never written to save files
- `struct LuaUniqueSlot { std::string name; std::vector<std::string> lines; } g_luaUniqueSlot` — static in `Source/items.cpp`; holds up to 6 content strings
- `void SetLuaUniqueInfoBox(std::string_view name, const std::vector<std::string> &lines)` — populates `g_luaUniqueSlot`; declared in `Source/items.h`, defined in `items.cpp`
- Early-exit block at top of `DrawUniqueInfo` (`Source/items.cpp`): if `curruitem._iUid == UITEM_LUA_CUSTOM`, render `g_luaUniqueSlot.name` as the title and `g_luaUniqueSlot.lines` as the power list; return early. Original code below is untouched.
- Thin hook call in `PrintItemDetails` after `curruitem = item`: `if (lua::OnPrepareUniqueInfoBox(curruitem)) curruitem._iUid = UITEM_LUA_CUSTOM;`
- `OnPrepareUniqueInfoBox(item) -> bool` query hook in `lua_event.hpp/.cpp` + `events.lua`
- `items.setCustomUniqueBox(name, lines)` binding in `Source/lua/modules/items.cpp` — calls `SetLuaUniqueInfoBox`

**Non-Hunter impact: zero.** The hook fires for every unique item hover, but returns false for all non-tame-scroll items. `UITEM_LUA_CUSTOM` is never set on real items.

**Lua (`init.lua`):**
`OnPrepareUniqueInfoBox` handler checks `item:isScrollOf(TAME_ID)` and `seedGetUniqueType(item.seed) >= 0`. If matched:
- Decodes `item.buff` for savedHp, maxHp, level, difficulty
- Looks up `monsters.getUniqueName(uIdx)` for the title
- Determines tier: `BOSS_NAMES[name] and "Boss" or "Champion"`
- Reads `allyKillCounts[item.seed]` for kills
- Calls `items.setCustomUniqueBox(monsterName, { tier.."("..diff..")", "Level: "..level, "HP: "..savedHp.."/"..maxHp, "Kills: "..kills })`
- Returns `true`

The gold popup shows the tamed monster's name, tier, difficulty, level, HP, and kill count.

---

## Phase 10 — Mod-data save slot (C++ + Lua)

Per-character mod data is persisted in a separate `"luamoddata"` named entry in the player's MPQ archive, independent of the item save path. MPQ is an archive format (like ZIP) — each named entry is independent, so the mod entry never touches existing entries or their sizes.

**Base-game invariant:** `DiabloItemSaveSize` / `HellfireItemSaveSize` are base-game constants and are never changed — doing so would break save-file compatibility with vanilla clients. Mod data therefore lives in its own MPQ entry, not appended to item records. A vanilla or non-Hunter save lacks the `"luamoddata"` entry, so the load is skipped (`LoadHelper::IsValid()` returns false).

**C++ surface:**
- `LuaSavePlayerModData(SaveWriter &)` / `LuaLoadPlayerModData()` in `Source/loadsave.cpp` (declared in `Source/loadsave.h`) — write/read the `"luamoddata"` entry as a flat `uint32` array (count header + values).
- Called in `pfile_write_hero` / `pfile_read_player_from_save` in `Source/pfile.cpp`, inside the `!gbVanilla` block (same guard as other mod-only save data).
- `lua::OnSavePlayerData() -> vector<uint32_t>` / `lua::OnLoadPlayerData(vector<uint32_t>)` in `Source/lua/lua_event.hpp/.cpp` — concatenate the return tables from all Lua handlers and pass the flat array back on load.
- `OnSavePlayerData` / `OnLoadPlayerData` events registered in `assets/lua/devilutionx/events.lua`.

**Lua (`init.lua`):** `allyKillCounts`, `bondedImmunity`, and `bondedTrn` (all keyed by seed) are serialized through `OnSavePlayerData` and restored through `OnLoadPlayerData` as three flat sections split by `0` markers.

---

## Phase 10 — Tame scroll refund on spawn failure (Lua)

When `monsters.spawnWithDifficulty` / `monsters.spawnUniqueAt` returns nil (tile blocked, monster pool full, etc.), the engine's `ConsumeScroll` still fires immediately after `OnSpellActionFrame` returns (because the Tame spell TSV has no missiles — `fizzled` is always false), which would consume the scroll for nothing. The refund prevents that loss.

**Mechanism (Lua only, `init.lua`):**
When `newMonster == nil`, before returning:
1. Reconstruct `scrollName` / `dwBuff` via `buildScrollParams(data, scrollSeed)` (seed preserved)
2. Set `tameScrollData[scrollSeed] = data` to ensure session cache is populated for the refunded copy
3. Call `caster:addScrollByMapping(TAME_SCROLL_MAP, scrollSeed, refundName, refundBuff)` — adds a copy to inventory BEFORE `ConsumeScroll` runs; `ConsumeScroll` removes the original by `spellFrom` slot index, leaving the copy as the refund
4. If inventory is full, fall back to `items.spawnAt` at the caster's position

Engine timing note: `OnSpellActionFrame` fires before `CastSpell` in `DoSpell` (`player.cpp`). `CastSpell` fires `ConsumeSpell` → `ConsumeScroll` which removes the scroll at `executedSpell.spellFrom`. The refund exploits this ordering: the copy is added DURING our hook, the original is removed AFTER we return.

---

## Phase 10 — OnGolemChooseAction hook + ranged ally behavior (C++ + Lua)

A tamed monster runs `GolumAi`, which only melee-attacks. This hook lets a ranged tame fire at range instead of chasing into melee.

**C++ surface:**
- `StartGolemRangedAttack(Monster &monster, MissileID missileType)` in `Source/monster.cpp` — wrapper around the anonymous-namespace `StartRangedAttack`; damage drawn from `monster.minDamage/maxDamage`. Declared in `Source/monster.h`. Marked `// Lua mod support`.
- `OnGolemChooseAction(ally, enemy) -> bool` hook in `lua_event.hpp/.cpp`; registered in `events.lua` as `CreateQueryEvent()`. Fires from `GolumAi` after `UpdateEnemy` but before the melee-attack / chase block. Returning `true` consumes the tick; the engine skips attack/chase/idle. The engine passes only the current target `enemy` monster (or nil) and computes nothing just for the hook; Lua handlers derive distance from `ally.position`/`enemy.position` and LOS via `monster:hasLineOfSightTo(enemy)`.
- `MonsterMode::RangedAttack` added to the GolumAi early-return check (alongside `MeleeAttack`) so the ranged animation is never interrupted mid-play.
- `monster:startRangedAttack(missileId: integer)` method added to the monster usertype in `Source/lua/modules/monsters.cpp`.
- `monsters.MissileID` table added to the `monsters` module with key missile ID constants: `Arrow`, `Firebolt`, `LightningArrow`, `FireArrow`, `ChargedBolt`, `HolyBolt`, `Fireball`.

**Lua (`init.lua`):**
- `OnGolemChooseAction` handler: for deployed allies with `hasRangedAttack`, fires a ranged attack when distance is in `[RANGED_MIN_DIST=3, RANGED_MAX_DIST=8]` and LOS exists; returns `true` to consume the tick. Returns `nil` for non-ranged allies or vanilla Golem. The missile fired is the monster's authentic attack via `ally:startNaturalRangedAttack()` (see "Hybrid AI" below).

---

## Phase 10 — Vanilla Golem idle, panel InfoBox name, boss classification (Lua + C++)

- **Vanilla Golem idle walk.** `OnGolemIdle` returns `nil` for non-deployed golems, so the engine's random-walk (`RandomWalk(_pdir)`) runs normally. (Returning `false` would freeze a vanilla Golem mid walk-animation — MT_GOLEM has `Stand=0` frames.) The hook only governs the mod's own deployed allies.
- **Panel-hover InfoBox name.** `control_infobox.cpp` computes `spellDisplayName` via `lua::OnGetSpeedbookSpellName` before its spell-type switch and uses it for every spell type (Skill/Spell/Scroll/Charges), so the panel-hover box shows the mod's spell names (e.g. "Tame+").
- **`BOSS_NAMES`** (`init.lua`) — the named-quest-boss table the tier system uses to split a unique into champion vs. boss (`isQuestMonster` is `isUnique() || MT_DIABLO`, so flags alone can't distinguish them): Arch-Bishop Lazarus, Zhar the Mad, Sir Gorash, Warlord of Blood, Blackjade, Red Vex, Gharbad the Weak, Snotspill, The Butcher, Skeleton King; Hellfire: Hork Demon, The Defiler, Na-Krul. Tiers and HP thresholds: see "Tame Tier Restructure" below.

---

## Phase 10 — Tamed-ally corpses (C++ + Lua)

Tamed allies and minions vanish on death and leave no corpse. The `OnMonsterCanPlaceCorpse(monster) -> bool` veto hook (default true) gates the corpse placement in `MonsterDeath` (`Source/monster.cpp`); the mod returns false for any monster it is currently untracking as an ally, so allies never need a `corpseId` and never touch the 31-slot corpse table (`InitCorpses` only ever sees natural level types). The corpse-table files (`dead.cpp`/`dead.h`) are vanilla.

Recorded in `OnMonsterDeath` (fires at the start of death, while the ally is still tracked) and consumed in `OnMonsterCanPlaceCorpse` (fires on the final death frame, after the ally has been untracked, so membership can no longer be tested there directly — see the `init.lua` corpse-suppression comment).

---

## Phase 10 — Manual retame recalls to inventory (Lua)

Casting the Tame skill on a deployed ally recalls it via `recallAllyToInventory(target, entry, caster, caster.position)`:
- Scroll goes to inventory or belt first.
- If inventory/belt full, drops at the **caster's feet**.

`recallAllyToInventory` takes an optional `fallbackPos` for the full-inventory drop tile. The level-exit auto-recall path passes no `fallbackPos`, so it drops at the ally's former tile if inventory is full.

---

## Phase 10 — Mod-extensible monster arrays (C++ + Lua)

The engine's `MaxMonsters` (200) and `MaxLvlMTypes` (24) caps blocked deploying a full party of allies on populated levels (`bugs.md`). Both are now mod-extensible at load time with **zero effect on unmodded play** — the accessors return the vanilla base when no mod requests extension, so save and network byte layouts are unchanged. Generic and modder-facing; nothing Hunter-specific in the engine.

**Monster-TYPE table:**
- `LevelMonsterTypes` converted from `CMonster[MaxLvlMTypes]` to `std::vector<CMonster>`, sized in `InitLevelMonsters` to `GetMaxLvlMTypes()` = `MaxLvlMTypes` + extension (grows the empty vector once; later levels are a no-op, so element addresses are stable).
- `RequestExtraLevelMonsterTypes(n)` / `GetMaxLvlMTypes()` in `monster.h/.cpp`; `EnsureMonsterType` cap and the dev-spawn fallbacks use `GetMaxLvlMTypes()`. Rebuilt per level, never serialized → no save/wire coupling.

**Live-monster array:**
- Backing arrays (`Monsters`, `ActiveMonsters`, `DLevel::monster`, sync `sgnMonsterPriority`/`sgwLRU`, `monsterConversionData`, `sgRecvBuf` sizing) dimensioned to a new `AbsoluteMaxMonsters = 252` constant. Kept as **static arrays** (not vectors) so every `Monster*`/`Monster&` across the engine stays valid with no init-ordering hazard; the ~20 KB extra is negligible.
- Runtime logical cap `GetMaxMonsters()` = `min(MaxMonsters + extension, AbsoluteMaxMonsters)`, raised by `RequestExtraMonsters(n)`. All logical bounds, delta loop counts, validation guards, and the enemy-encoding offset (`encode_enemy`/`decode_enemy`) use `GetMaxMonsters()`.
- **Frozen at literal `MaxMonsters`:** natural-placement caps (`PlaceMonsters`, `AddMonster`, `SpawnMonster`, monster-split spawns) so vanilla monsters keep ids `< 200` and the extended slots are reserved for mod-spawned allies; plus the vanilla `MonsterKillCounts` save-padding in `loadsave.cpp`.
- Verified the multiplayer ally path (owner gate → `OnSpawnMonster` receiver via explicit id → `InitializeSpawnedMonster`/`LoadDeltaSpawnedMonster` → `EnsureMonsterIndexIsActive`) never touches the frozen `SpawnMonster` cap.

**Hard ceiling — 252 (`256 − MAX_PLRS`):** the enemy reference (`Monster.enemy`, `DMonsterStr.menemy`, `TSyncMonster._menemy`) is a `uint8_t` that packs monster targets into `[0, GetMaxMonsters())` and player targets above. Raising past 252 would require widening those fields to `uint16`, which changes the vanilla wire/save layout — so 252 is the format-safe maximum. Covers ~190 natural spawns + 32 allies.

**Lua:** `monsters.requestExtraTypes(n)` / `monsters.requestExtraMonsters(n)` bindings; `init.lua` requests 32 of each at load (4 Hunters × 8 deployed allies).

**Files:** `Source/monster.h/.cpp`, `Source/msg.cpp`, `Source/sync.cpp`, `Source/multi.cpp`, `Source/engine/render/scrollrt.cpp`, `Source/monsters/validation.cpp`, `Source/loadsave.cpp`, `Source/debug.cpp`, `Source/lua/modules/monsters.cpp`, `Source/lua/modules/dev/monsters.cpp`, `init.lua`

---

## Phase 10 — Multi-Hunter ownership + visibility: outlines & minion naming (C++ + Lua)

Foundation for all multi-Hunter MP behavior: a per-observer ownership/visibility model. Outline color and display name are decided from the local `MyPlayer`'s perspective relative to each ally's owner.

**New C++ additions:**
- `monster.ownerPlayerId` (readonly int) in `Source/lua/modules/monsters.cpp` — returns `goalVar3`, the owning player id stamped when a monster becomes a golem/player-minion. Only meaningful when `isGolem`.
- `player.get(id) -> Player|nil` module function in `Source/lua/modules/player.cpp` — returns `Players[id]` or nil if out of range / not active. Lets Lua resolve a monster's owner and inspect their class/hostility.
- `player.friendlyMode` (readonly boolean) in `Source/lua/modules/player.cpp` — `false` = the player has toggled Hostile.
- No render/name hooks of its own — name routes through `OnGetMonsterDisplayName` (infobox + healthbar) and outline through `OnGetMonsterOutlineColor` (scrollrt), the visual-polish hooks above.

**Ownership model:** the Tame Scroll carries no embedded owner. `makeGolem` → `ChangeMonsterToGolem` stamps `goalVar3 = MyPlayerId` at deploy, so the caster becomes owner. Trading a scroll between Hunters re-owners it automatically on cast. (Cross-client owner broadcast remains the deferred Net Sync item — `goalVar3` is an AI goal var, not auto-synced.)

**Lua (`init.lua`):**
- `arePeaceful(a, b)` helper — both players in friendly mode (nil-safe). Shared by outline color AND pet-combat targeting so visual and combat state always agree.
- `isOtherHuntersAlly(monster)` helper — golem owned by a different player whose `className == "Hunter"`.
- `OnGetMonsterOutlineColor`: own allies/minions → gold `194` (white `255` when hovered), always (even if owner is hostile); another Hunter's ally → blue `183` (`PAL16_BLUE+7`) only when `arePeaceful(me, owner)`, else nil (engine default red-on-hover). Minions inherit owner from the parent, so they color identically with no special path.
- `OnGetMonsterDisplayName`: own ally → `"Tamed " .. name`; own minion (`deployedAllies` entry with `isMinion`) → `name .. " Minion"` (suffix). Another Hunter's pets keep their default name.

---

## Phase 10 — Hostility: pet-vs-pet combat + interactability gate (C++ + Lua)

Lets a Hunter's deployed pets participate in PvP when their owner toggles Hostile, while preserving Diablo's player-level "you must toggle to fight" rule.

**New C++ hook:**
- `OnGolemCanTargetGolem(ally, candidate) -> bool` (default false) in `lua_event.hpp/.cpp` + `events.lua` (`CreateQueryEvent`). Fired at the `prevent golems from fighting each other` continue in `UpdateEnemy` (`Source/monster.cpp`) — vanilla unconditionally blocks player-minion-vs-player-minion targeting *before* any hook, so this generic call-out is the only way to permit it. Default false preserves vanilla no-infighting.

**Pet-vs-Pet model — Option B (symmetric / auto-defense):** two pets may fight iff they belong to different players who are not both friendly (at least one toggled Hostile). Symmetric, so a defender's pets fight back automatically before that player toggles. (Considered/rejected: Option A aggressor-only — no pre-toggle defense; Option C hit-triggered retaliation — disproportionate complexity + transient net-sync state.)

**Lua (`init.lua`):**
- `OnGolemCanTargetGolem` handler: nil if either owner unknown / same owner / both friendly (`arePeaceful`); true otherwise. Generic — works for any class's golems.
- `OnGolemCanSelect`: own allies always selectable; another Hunter's pet selectable only when NOT `arePeaceful` (friendly = no hover/infobox/target; hostile = normal enemy).
- `OnPlayerAttackMonster`: in addition to blocking attacks on own allies, blocks attacks on another Hunter's pet while at peace (attacker-relative; param renamed `attacker` since it shadows the `player` module). Defense-in-depth so no non-cursor path damages a friendly pet.

Net effect, all keyed off the one `arePeaceful` predicate: friendly → blue outline + unselectable + no infighting; hostile → red-on-hover + selectable/attackable + pets fight. Outline, selectability, and combat can never disagree.

---

## Phase 10 — Tame Scroll class restriction (C++ + Lua)

Only the Hunter class may pick up or hold Tame Scrolls; Hunters can still trade them to each other via drop/pickup.

**New C++ hook:**
- `OnPlayerCanPickUpItem(player, item) -> bool` (default true) in `lua_event.hpp/.cpp` + `events.lua` (`CreateQueryEvent`). Fired before the pickup network request on every path, so nothing is consumed on veto:
  - Walk-up pickup: `ACTION_PICKUPITEM` / `ACTION_PICKUPAITEM` in `Source/player.cpp`; on veto sets `destAction = ACTION_NONE` (no per-tick retry loop).
  - Telekinesis: `DoTelekinesis` in `Source/inv.cpp`; on veto the item is simply not pulled.

**Lua (`init.lua`):**
- `OnPlayerCanPickUpItem` handler: `return false` when `item:isScrollOf(TAME_ID)` and `p.className ~= "Hunter"`. Blocking floor acquisition (the only inbound path) also prevents holding. Hunter↔Hunter trades work because neither party is blocked.

---

## Phase 10 — Minion System: Skeleton King minions (C++ + Lua)

A tamed Skeleton King spawns skeleton minions that become owned allies. This is the first user of the Minion System framework (minions are tracked entries that don't count against the cap, can't be recalled, and despawn with their parent). Key constraint: a tamed monster runs `GolumAi`, **not** its original AI (`LeoricAi`), so the spawn is triggered from the `OnGolemChooseAction` handler — not from `LeoricAi` itself.

**New C++ hook:**
- `OnGolemSpawnedMinion(ally, newMonster)` (event, no return) in `lua_event.hpp/.cpp` + `events.lua` (`CreateEvent`). Fired from the spawn wrapper below; `ally` is the spawner, `newMonster` the freshly spawned monster.

**New C++ wrapper:**
- `StartGolemSpawnSkeleton(Monster &monster) -> bool` in `Source/monster.cpp` (declared in `monster.h`). Mirrors the `LeoricAi` spawn block: direction toward `monster.enemyPosition`, `GetRandomSkeletonTypeIndex`, `SpawnMonster`, `StartSpecialStand`. Detects the spawned monster via the pre/post `ActiveMonsterCount` delta (`Monsters[ActiveMonsters[before]]`) since `SpawnMonster` returns void — no signature change. Fires `lua::OnGolemSpawnedMinion(&monster, &spawned)`. Returns false if the spawn was blocked or `SpawnMonster` bailed (cap reached / not level owner). `SpawnMonster`'s own `MaxMonsters` cap governs, so no separate precheck.
- Exposed as `monster:spawnSkeletonMinion() -> boolean` in `Source/lua/modules/monsters.cpp`.

**Lua (`init.lua`):**
- `OnGolemChooseAction` (hybrid handler): for `originalAiId == AIID.SkeletonKing`, when `hasTarget` and `dist >= 3` (matching `LeoricAi`) and `countMinionsOfParent(ally.id) < 3` and an 8%-per-tick roll, calls `ally:spawnSkeletonMinion()` and consumes the tick. The King's `StartSpecialStand` (set by the wrapper) keeps `GolumAi` from re-running until the spawn animation finishes, throttling spawns.
- `OnGolemSpawnedMinion` handler: `newMonster:makeGolem()` (stamps owner = caster, switches to `GolumAi`), then inserts `{ monster, seed = nil, isMinion = true, parentId = ally.id }` into `deployedAllies`.
- Helpers `countMinionsOfParent(parentId)` / `removeMinionsOfParent(parentId)` (the latter calls `monster:remove()` to despawn silently).
- Lifecycle: minions despawn when the parent is killed (`OnMonsterDeath` → `removeMinionsOfParent`), recalled via retame (retame on a minion is a no-op; recalling a parent despawns its minions first), or on `OnLevelExit` (minions are dropped from tracking, not recalled). `OnGolemKilledMonster` skips minions (they have no `seed`, so no kill-count write). Minions reuse the existing outline (gold) and name (`"<Name> Minion"`) paths automatically.

**Multiplayer note:** `SpawnMonster` only runs on the level owner, and the adoption happens in that owner's `OnGolemSpawnedMinion`. On non-owner clients the spawn arrives via the `OnSpawnMonster` net path and is not yet adopted as a tracked minion — consistent with the deferred multi-client net-sync scope. Fully correct in singleplayer.

---

## Phase 10 — Minion System: Hork Demon minions (C++ + Lua)

A tamed Hork Demon fires Hork Spawn at range; each landing spawns a Hork that is adopted as a minion. Reuses the `OnGolemSpawnedMinion` hook and the entire minion framework from the Skeleton King work — only the *firing* and the *spawn-site adoption* were new.

**Missile-source insight:** the Hork Demon's spawn uses the Special-ranged path (`MonsterRangedSpecialAttack`), whose `AddMissile` call always passes `TARGET_PLAYERS` with the monster as source — even for a tamed golem. So in `ProcessHorkSpawn`, `Missile::sourceMonster()` resolves back to the Hork Demon (tamed or wild), which is how the spawn site recovers the parent.

**C++ additions:**
- `StartGolemSpecialRangedAttack(Monster &, MissileID)` in `Source/monster.cpp` (declared in `monster.h`) — wraps `StartRangedSpecialAttack` (Special animation + `SpecialRangedAttack` mode). Exposed as `monster:startSpecialRangedAttack(missileId)` in `Source/lua/modules/monsters.cpp`.
- `MonsterMode::SpecialRangedAttack` added to the `GolumAi` early-return guard (alongside `RangedAttack`/`Charge`/etc.) so the spawn animation isn't interrupted before the missile fires.
- `ProcessHorkSpawn` (`Source/missiles.cpp`): after `SpawnMonster`, recover `missile.sourceMonster()`; if it's `MFLAG_GOLEM` and the spawn succeeded (`ActiveMonsterCount` delta), fire `lua::OnGolemSpawnedMinion(parent, &spawned)`. Same delta technique as the Skeleton King wrapper.
- `monsters.MissileID.HorkSpawn` constant added to the missile-ID table.

**Lua (`init.lua`):**
- `OnGolemChooseAction` (hybrid handler): for `originalAiId == AIID.HorkDemon`, when `hasTarget` and `dist >= 3` and under the per-demon minion cap (3) and an 8%-per-tick roll, calls `ally:startSpecialRangedAttack(monsters.MissileID.HorkSpawn)` and consumes the tick. The special-attack animation lockout (via the new `GolumAi` guard) throttles firing.
- Adoption is the **existing** `OnGolemSpawnedMinion` handler — no new Lua adoption code. Note the cap check lags by the missile's travel time (the minion doesn't exist until the missile lands), so a small overshoot of the cap is possible; the animation lockout keeps it minor.

With this, the Minion System is complete for both spawners. `OnGolemSpawnedMinion` now has two C++ call sites; the hook count is unchanged from the Skeleton King work (67 total / 60 added).

---

## Phase 10 — Hybrid AI: authentic ranged attacks + avoidance (C++ + Lua)

Tamed allies fire their authentic ranged attack and use avoidance/kiting behavior. No C++ hooks of its own — only `StartGolem*` wrappers and Lua wiring.

**Context:** a tamed monster runs `GolumAi`, so its native AI never runs. The mod re-creates special behaviors from `OnGolemChooseAction`, keyed off `monster.originalAiId`. `hasRangedAttack` includes Counselor and Mega so the ranged handler picks them up.

**New C++ wrappers** (`Source/monster.cpp`, declared in `monster.h`; bound in `Source/lua/modules/monsters.cpp`):
- `StartGolemNaturalRangedAttack(Monster&)` → `monster:startNaturalRangedAttack()`. Fires the monster's authentic attack using `monster.data().ai` (the original AI, since the live `ai` is `Golem`):
  - Counselor/Advocate: `MissileTypes[intelligence]` = Firebolt/ChargedBolt/LightningControl/Fireball (clamped 0–3), normal ranged anim.
  - Mega: `InfernoControl`, special-ranged anim.
  - Magma/Storm/Acid/AcidUnique/Diablo/BoneDemon: `GetMissileType(ai)`, special-ranged anim (mirrors `AiRangedAvoidance`).
  - Everyone else (Succubus→BloodStar, Lich→flares, FireBat/Torchant→fire, archers→Arrow, …): `GetMissileType(ai)`, normal ranged anim.
  - Damage = `RandomIntBetween(minDamage, maxDamage)` (consistent with the other golem attack wrappers).
- `StartGolemSpecialAttack(Monster&)` → `monster:startSpecialAttack()`. Wraps `StartSpecialAttack` (`SpecialMeleeAttack` mode, already in the `GolumAi` early-return guard).
- `hasRangedAttack` property includes `Counselor` and `Mega` so the ranged handler picks them up.

**Lua (`init.lua`):**
- Ranged `OnGolemChooseAction` handler calls `ally:startNaturalRangedAttack()`; the missile is the monster's authentic attack (no per-typeId override table).
- **Kite within leash:** for the avoidance ranged set (`AVOIDANCE_RANGED` = Magma/Storm/Acid/Diablo/BoneDemon), if the enemy closes inside `KITE_MIN_DIST` (3) and the ally is ≥2 tiles from the owner, it walks toward the owner instead of firing — backing away from the enemy while staying leashed (`ENGAGE_RADIUS`).
- Hybrid handler: new `GoatMelee` branch — at <50% HP with a coin flip, `ally:startSpecialAttack()`; otherwise falls through to normal melee.

**Deliberately not replicated:** Counselor teleport-reposition (conflicts with leash, low value), `AiRanged` light back-pedal (allies should hold their firing line), GoatMelee anti-surround jitter (it's a melee fighter). Per-AI distance bands aren't matched (e.g. Mega infernos within the generic `[3,8]` window rather than 2–4) — cosmetic.

**Resolved non-issue:** Blink teleport-on-hard-hit needs no control. A tamed `MT_BLINK` ally only blinks to a tile near the enemy it's fighting; the idle leash walks it back if it lands outside engage range, and the 12-tile hard snap returns it to the owner.

---

## Phase 10 — Quest clear on tame (C++ + Lua)

Taming a quest monster clears its quest **exactly as if it were killed**, including the death speech. The engine already centralizes this in `CheckQuestKill(const Monster&, bool sendmsg)` (`Source/quests.cpp`), which handles Skeleton King (Q_SKELKING + "Rest well, Leoric…"), Butcher (Q_BUTCHER), Gharbad (Q_GARBUD), Zhar (Q_ZHAR), Lazarus (Q_BETRAYER done + Q_DIABLO active + the Diablo portal/triggers), and Warlord (Q_WARLORD) — and is a no-op for every other monster.

**C++:** `monster:checkQuestKill()` binding in `Source/lua/modules/monsters.cpp` (added `#include "quests.h"`) calls `CheckQuestKill(monster, true)`. No new logic — it reuses the engine's own death-quest handler.

**Lua (`init.lua`):** the Tame skill calls `target:checkQuestKill()` immediately before `target:remove()` (while the monster's `type()`/`uniqueType` are still intact). Because `CheckQuestKill` is a no-op for non-quest monsters, ordinary tames are unaffected, and **Lachdanan** (never a combat target, not handled by `CheckQuestKill`) needs no special case.

**Companion fix — suppress quest completion on a golem's death.** Vanilla also runs `CheckQuestKill` from `MonsterDeath`, so a tamed quest boss dying as an ally would replay the speech and re-fire the quest (observed in testing). New generic veto hook `OnMonsterCanCompleteQuest(monster) -> bool` (default true) wraps that call: `if (lua::OnMonsterCanCompleteQuest(&monster, true)) CheckQuestKill(...)` in `Source/monster.cpp` (declared `lua_event.hpp`, defined `lua_event.cpp`, registered `events.lua`). The mod's handler returns `false` when `monster.isGolem` — a golem/player-minion death never completes a quest. `isGolem` (MFLAG_GOLEM) is stable at death, so this is independent of when the ally-untracking `OnMonsterDeath` handler runs. Hook count: **68 total / 61 added**.

**Optional follow-up (not done):** quests gated on a *dropped item* rather than quest state — the Defiler's Map of the Stars and the Hork Demon's amulet — live in `SpawnLoot`, not `CheckQuestKill`, so taming those monsters does not drop the item. Add a `SpawnLoot`-style path if those quests must stay completable post-tame.

---

## Phase 10 — Max-HP stability (C++ + Lua)

A tamed monster's Max HP is stable across recall / redeploy / level-load:
- `monster:setMaxHitPoints(hp)` binding in `Source/lua/modules/monsters.cpp` (mirrors `setHitPoints`).
- Deploy calls `setMaxHitPoints(data.maxHp)` before `setHitPoints(data.savedHp)`, restoring the captured max verbatim — independent of the difficulty/`dlvl` re-roll that `spawnWithDifficulty`/`InitMonster` apply to a fresh spawn (all other stats stay frozen at `capturedDifficulty`).
- `dwBuff` layout: maxHp at full 15-bit resolution (bits 1–15), monster level (16–21), captured difficulty (22–23), current HP as a percent of max (bits 24–31, so `savedHp ≤ maxHp`). `encode/decodeDwBuff` carry these.

`monsters.AIID` exposes the complete `MonsterAIID` enum, so a Lua table literal keyed by AI ID (`{ [monsters.AIID.Magma] = true, ... }`) never reads back a `nil` key. (A C++ constant table a mod indexes by key must expose every value the mod names — a `nil` key is a hard load error.)

---

## Phase 10 — Spellbook: Golem & Guardian removed from learned allowlist (Lua only)

The Hunter's summon identity is **Tame**, not the vanilla summon spells, so Guardian (SpellID 13) and Golem (SpellID 21) were removed from `HUNTER_ALLOWED_LEARNED_SPELLS` (`init.lua`). That single table feeds three guards — speedbook visibility (`OnShouldHideSpeedbookSpell`), active-cast selection (`OnCanSelectSpellBookEntry`), and (by exclusion) the learned-spell filter — so neither spell can now be learned or direct-cast.

Differential behavior preserved:
- **Guardian:** behaves like every other off-allowlist spell — not castable as a learned spell, but still usable via **scroll or staff charge** (no special handling).
- **Golem:** also not learnable; its **scrolls** stay red/unusable in inventory (the existing `OnCanPlayerUseItem` `item:isScrollOf(GOLEM_SPELL_ID) → false` block) and hidden from the speedbook (the `spellType == "Scroll" and spellId == GOLEM_SPELL_ID` hide). Both guards were **kept as-is**; Golem **staff charges remain usable**.

Pure Lua; no C++. Hook count unchanged.

---

## Phase 10 — Tame Tier Restructure + mlvl Gate (Lua + 1 new C++ hook)

Re-leveled the Tame tiers, added a top tier **Tame+++**, layered a **monster-level (mlvl) vs character-level (clvl)** gate on top of decoupled per-category HP thresholds, and made both cast paths **actively refuse** out-of-criteria targets/scrolls with the spoken "I can't do that" instead of silently no-oping.

**Single source of truth (`init.lua`, near the seed helpers).** Pure-Lua helpers implement the tier gate:
- `tameTier(clvl)` → 0..3 — unlocks: Tame (always) / Tame+ (clvl **20**) / Tame++ (clvl **35**) / Tame+++ (clvl **45**).
- `categoryFromTarget(target)` (live monster) and `categoryFromScroll(seed)` (encoded scroll) → `normal`/`champion`/`boss`/`diablo`. Diablo = `isQuestMonster && !isUnique`; boss vs champion = `BOSS_NAMES[name]`.
- `categoryHpThreshold(cat)` — fixed per category at **every** tier: Normal 30% / Champion 20% / Boss 10% / Diablo 5%.
- `mlvlGateAllows(tier, cat, clvl, mlvl)` — the matrix: Tame Normal `mlvl≤clvl`, Champion/Boss `clvl≥mlvl×2`; Tame+ eases Champion to `mlvl≤clvl`; Tame++ opens all non-Diablo categories to `mlvl≤clvl+10`; Tame+++ is mlvl-blind for all categories incl. Diablo. A tame requires **both** the mlvl gate and the category HP threshold. mlvl (`target.level`) is the engine's **difficulty-adjusted** level, so the gate respects Nightmare/Hell.

**Capture side (skill).** The in-cast gate (`OnSpellActionFrame`) now selects HP threshold by category and applies the mlvl gate. A new generic C++ hook **`OnCanCastSkill(player, spellId, target)`** (default true; `target` = `pcursmonst` resolved to a monster in the `lua_event.cpp` wrapper, mirroring `OnSpellActionFrame`) fires in `CheckPlrSpell`'s `case SpellType::Skill:` (split from `Spell` so only skills are vetoed) — the Lua handler refuses out-of-criteria targets up front with the spoken line. Golem/minion targets return nil (own ally = recall, others = no-op); the HP threshold still governs whether a valid-category target is actually captured. **Hook count: 69 total / 62 added.**

**Deploy side (scroll) — three Lua actions** reusing `scrollPassesTierGate(p, seed, buff)`:
- **Red/unusable in inventory** — `OnCanPlayerUseItem` returns false for an out-of-criteria Tame scroll (mirrors the Golem-scroll block; also blocks right-click/belt use).
- **Hidden from speedbook** — filtered at injection in `OnGetCustomSpeedbookScrollEntries` (Tame scrolls carry `iSkipSpeedbook`, so red ≠ auto-hidden).
- **Pre-cast refusal** — `OnCanCastScroll` rejects an out-of-criteria scroll with the spoken line (belt-and-suspenders; not consumed).

**Diablo deferred.** Diablo is gate-eligible at Tame+++, but capture and deploy remain **hard-blocked** (`category == CAT_DIABLO → return`/`return false`) until the Diablo sub-task solves the Apocalypse friendly-fire-on-players landmine. The tier model and `mlvlGateAllows` already encode Diablo correctly; only the explicit hard-block needs removing when that lands.

---

## Phase 10 — Ally Progression: blocks 1–3 (stat machinery + Tamed→Bonded + Bonded bonus)

The first three blocks of the Ally Progression feature (`roadmap.md` → "Ally Progression"): base-vs-applied stat machinery, Tamed→Bonded promotion, and the Bonded defensive bonus.

**Block 1 — base-vs-applied stat machinery.**
- Generic bindings in `Source/lua/modules/monsters.cpp`: readonly getters `minDamage`/`maxDamage`/`armorClass`/`toHit`/`resistance`; setters `setMinDamage`/`setMaxDamage`/`setArmorClass` (clamped 0–255), `setToHit` (→ `golemToHit`, the source of `Monster::toHit` for player-minions), `setResistance`; plus a `monsters.Resistance.*` flag table. No core-engine call-outs.
- `init.lua`: `snapshotAllyBase(entry)` captures the freshly-spawned ally's stats into `entry.base` at deploy (after `makeGolem`, so `golemToHit` is set). `applyAllyBuff`/`recalcAllyBuffs` re-apply `base + buff` for dmg/ToHit/AC (each rewritten from base every recalc) and the `maxHitPoints` HP buff (see block 4). Recalc is wired at deploy, manual retame/recall, non-minion ally death, and the per-frame stat-fingerprint poll. **Invariant:** the buff is never written into base/the scroll.

**Block 2 — Tamed→Bonded promotion (state + naming).** `isBonded(seed, mlvl)` = `allyKillCounts[seed] ≥ mlvl × BONDED_KILLS_PER_LEVEL` (100), derived live with no new encoded field. `promoteToBonded(entry)` fires from `OnGolemKilledMonster` on the exact threshold-crossing kill. Every "Tamed" surface flips to "Bonded": scroll name (`buildScrollParams`), display name/healthbar (`OnGetMonsterDisplayName`), speedbook dedup (recognises both prefixes), `OnCustomItemRecreated`, and the unique gold box (`OnPrepareUniqueInfoBox`). **Bonded scrolls render at gold/"unique" tier** — `scrollIsGoldTier(item)` = seed-unique OR Bonded gilds `magical=2` at `recallAllyToInventory` / `OnLevelEnter` / `OnItemPickedUp` / `OnCustomItemRecreated`, and `OnPrepareUniqueInfoBox` renders a custom box for **Bonded normal-monster** scrolls (tier line "Bonded"), not just seed-uniques.

**Block 3 — Bonded defensive bonus.** On promotion the ally gains **one random missing immunity** from {Fire, Magic, Lightning} (rolled from the ones it does *not* already have, read off live `monster.resistance`), or **+200 AC** if it already has all three. Stored once per seed in `bondedImmunity[seed]` (`BONDED_AC` sentinel = the AC case) and **persisted** in the mod-data save blob (its own section). Immunity is written via `setResistance` (survives recalc, which never touches resistance); the +200 AC is folded through the AC buff write so a recalc can't wipe it. Re-applied on every redeploy (a fresh spawn re-rolls only if the seed has no stored bonus). **Same-element supersession:** because the roll keys off the *immune* flag, it can grant e.g. Immune Fire to an ally that already has Resist Fire. `applyBondedBonus` clears the matching `Resist*` flag (`BONDED_IMMUNE_SUPERSEDES` map) when it ORs in the `Immune*`, so the live resistance bitfield never carries a Resist + Immune of the same element — matching base-game UI, where no monster shows both. Both the ally infobox (`OnGetMonsterInfo`) and the healthbar icons read the live bitfield, so this is correct at the source with no display-side special-casing.

**Healthbar resistance icons for allies.** Vanilla `monhealthbar.cpp` only draws the resistance/immunity icon row for uniques or monster types killed 15+ times, so a Bonded non-unique ally's granted immunity would not show on its own. The thin generic hook **`OnMonsterCanShowResistances(monster, default)`** (`lua_event.hpp`/`.cpp`, `events.lua`) is `||`-ed onto the vanilla gate; the mod returns true for any deployed ally so their resistances/immunities always show (consistent with the ally infobox revealing full stats). **Hook count: 70 total / 63 added.**

---

## Phase 10 — Ally Progression: block 4 (live share-divided physical buff pool + kill-scaled ToHit)

Block 4 of the Ally Progression feature — the buff math `computeAllyBuff`, the kill-scaled ToHit bonus, and the Bonded promotion threshold.

**New player stat bindings (`Source/lua/modules/player.cpp`).** Four readonly properties exposing the Hunter's **character-sheet-effective** combat stats (so the buff scales off exactly the numbers the player sees): `armorClass` (= `GetArmor() + characterLevel×2`), `toHit` (ranged-to-hit when a bow is equipped, else melee), `minDamage`/`maxDamage` (mirroring `charpanel.cpp`'s `GetDamage()` bow-half-damage logic). HP already had `maxHealth`. Pure getters in the binding layer — no core-engine call-out, no signature change.

**`computeAllyBuff(entry)` (`init.lua`) — the share-divided pool.** For each deployed Tamed/Bonded ally (minions return zero — they get the block-8 static buff): pool = **CLVL%** of the Hunter's matching stat (HP/min+max dmg/ToHit/AC), split evenly across `countDeployedAllies()` allies, then the share **doubled for Bonded**. `sharePct = (CLVL / count) × (Bonded ? 2 : 1)`; every stat = `ceil(hunterStat × sharePct / 100)` (all fractions round up). Layered onto `entry.base` by `applyAllyBuff`: dmg/ToHit/AC are rewritten from base each recalc, and the HP buff raises `maxHitPoints` to `base.maxHp + buff.hp` (current HP is left alone, clamped down only if a shrinking share drops max below current). See "HP buff model" below.

**Kill-scaled ToHit (additive, per-ally, not share-divided).** Folded into the same `toHit` term: `raw = floor(kills / 10)`, clamped to `CLVL×10`, doubled if Bonded (after the clamp), hard-capped at **+500%** (`KILL_TOHIT_PER = 10`, `KILL_TOHIT_CAP = 500`). Applied as flat percentage points on top of the share-pool ToHit. `OnGolemKilledMonster` re-applies the ally's buff whenever its kill count crosses a `KILL_TOHIT_PER` multiple, so the bonus updates live (the Bonded-promotion kill already re-applies, so it returns early to avoid a redundant call).

**Recalc cadence.** `GameDrawComplete` polls a cheap stat fingerprint (CLVL + the four character-sheet stats) once per frame *while allies are deployed* and calls `recalcAllyBuffs()` only when it changes — catching a live CLVL-up or mid-deployment gear swap, alongside the deploy / retame-recall / ally-death recalc triggers.

**Bonded promotion threshold.** `BONDED_KILLS_PER_LEVEL = 100` (a lvl-2 ally bonds at 200 kills). Promotion gate only; all naming/gold/immunity logic keys off `isBonded`.

**HP buff model.** `applyAllyBuff`/`applyMinionBuff` set `maxHitPoints = base.maxHp + buff.hp` — idempotent (recomputed from the snapshot every recalc, never accumulated) — and leave current HP alone (clamped down only if a shrinking share drops max below current). A full base monster deploys at e.g. **100/120**; the buff is headroom the pet heals into. Max is idempotent like dmg/ToHit/AC, Share Potions heal up to the buffed max, and current HP round-trips exactly across repeated retames.

**Overheal is not persisted; recall clamps to `base.maxHp`.** Because the buff lives in `maxHitPoints`, `ally.maxHealth` is the *buffed* max at recall, so `allyToMonsterData` persists the un-buffed `entry.base.maxHp` as the scroll's `maxHp` and clamps saved current to it. `encodeDwBuff` clamps `pct` to **0..100**. The Share Potion 150% proc works **live** (it just isn't saved through a recall; a recalc clips it back to the buffed max) — see the `init.lua` `encodeDwBuff`/`decodeDwBuff` comments.

The player stat getters are usertype properties, not event call-outs. **Hook count: 70 total / 63 added.**

---

## Phase 10 — Ally Progression: block 5 (spellcaster resistance-scaled missile damage)

Block 5 — a spellcaster ally's **elemental missile** damage scales off the **Hunter's Magic and matching resistance**; its **melee** keeps the block-4 physical buff. The two are independent, so a hybrid (e.g. the **Balrog**/Mega: physical melee + Inferno special) gets a proper physical melee buff **and** a Magic/resistance-scaled Inferno.

> **Why missile damage is intercepted (not min/max).** `AddInferno`/`ProcessLightningControl` re-sample `monster.minDamage/maxDamage` **live over the missile's whole flight** ([missiles.cpp:2689](../../../../Source/missiles.cpp), [:3382](../../../../Source/missiles.cpp)), and the shared min/max field cannot give melee and a re-sampling spell different values from Lua. So the spell buff is applied to the **missile damage** itself (via `OnGolemMissileDamage`), leaving melee on the shared min/max.

**New C++ surface (all thin call-outs / generic bindings — no logic, no signature changes):**
- **`OnCalcPlayerResistances(player, fire, lightning, magic)` event** (`lua_event.hpp/.cpp`, `events.lua`; call-out in `items.cpp` → `CalcPlrResistances`). Forwards the **UNCAPPED pre-clamp** resistance totals (already in scope right before the `std::clamp` into `_pFireResist`/etc.) so a mod can read the true value above the 75% display cap. Chosen over adding `Player` fields (the user's call): a thin call-out passing only in-scope values.
- **`OnGolemMissileDamage(golem, missileId, dam) -> dam` query event** — call-out in **`AddMissile`** ([missiles.cpp](../../../../Source/missiles.cpp)) right after `missileData.addFn(...)`, **gated to MFLAG_GOLEM sources** (`missile.sourceMonster()` non-null with `MFLAG_GOLEM`) so wild-monster missiles never cross into Lua — important since `events.lua` registers the event for the whole base game. It's the chokepoint where a golem/player-minion missile's `_midam` is final, **including each spawned segment** of multi-tick spells — Inferno segments (`ProcessInfernoControl` → `AddMissile`) and Lightning segments (`SpawnLightning` → `AddMissile`). Returns the (possibly adjusted) damage; default keeps `dam`. Melee never routes through `AddMissile`, so melee is untouched. (The vanilla Golem is MFLAG_GOLEM too but casts nothing / isn't a deployed ally, so the Lua handler no-ops it.)
- **`GetGolemNaturalMissile(const Monster&)` (`monster.cpp/.h`)** — factored out of `StartGolemNaturalRangedAttack` (single source of truth); bound as **`monster:naturalRangedMissileId() -> int`**. Behaviour of `StartGolemNaturalRangedAttack` is byte-for-byte unchanged. (A generic binding; the mod doesn't currently use it.)
- **`monsters.getMissileDamageType(missileId) -> int`** via `GetMissileData(id).damageType()`, plus the **`monsters.DamageType.*`** table (Physical/Fire/Lightning/Magic/Acid).

**Lua (`init.lua`):**
- `OnCalcPlayerResistances` handler caches the **local Hunter's** uncapped `hunterResist = { fire, lightning, magic }` (other players' recalcs ignored; allies are client-local).
- `player.magicCurrent` (new getter, `Source/lua/modules/player.cpp`) — the **effective** Magic stat (`_pMagic`, base + gear), distinct from the base-only `player.magic`.
- `allySharePct(entry)` factored out of `computeAllyBuff` so the share weight `(CLVL / count) × (Bonded ? 2 : 1)` is shared with the missile hook.
- `computeAllyBuff` gives **every** ally (caster or not) the physical damage buff — it governs **melee**.
- **`OnGolemMissileDamage` handler:** for a deployed non-minion ally firing an **elemental** missile (`SPELL_ELEMENT_OF[getMissileDamageType(missileId)] ~= nil`), recomputes the damage off the Hunter's **Magic** and **matching resistance**:
  ```
  spell = (baseDam + sharePct% × CurrentMagic) × (1 + matchingRes%)        -- round up
  ```
  The rolled `dam` comes from the ally's live min/max (carrying the block-4 physical buff), so the handler first **strips that physical buff** — `baseDam = floor(dam × base.maxDamage / cur.maxDamage)` — scaling the engine's roll down to its pre-buff fraction (not re-rolling, so the missile's native multiplier like Lightning's ×2 survives). Then: the **Magic** term is a *shared pool* (`sharePct = (CLVL/count) × (Bonded?2:1)` via `allySharePct`, so more pets dilute it, Bonded doubles it); the **matching resistance** (uncapped, clamped ≥0 — synergy never penalizes) is a *full multiplier, NOT share-divided*, so it stays meaningful with a big pack. Melee keeps the physical buff. **Acid casts are aligned to the Hunter's Magic resistance** (acid has no player-side resistance of its own); only **Physical** missiles, minions, and non-ally monsters return `dam` unchanged. The hook reads the **actual** `missileId`, so a multi-element caster matches each spell to its own resistance automatically — no per-monster element table, no hybrid list.

**Worked examples** (final rounded up): CLVL 20 Hunter, current Magic 80, base spell dmg 10, 30% Fire res, 1 Tamed Advocate → `(10 + 20%×80) × (1 + 30%)` = `26 × 1.30` ≈ **34**; Bonded (sharePct 40) → `(10 + 32) × 1.30` ≈ **55**; 4 Tamed deployed (sharePct 5) → `(10 + 4) × 1.30` ≈ **19** (Magic term diluted by the pack, but resistance still gives its full ×1.30).

**Hook count: 72 total / 65 added** (two new events this block: `OnCalcPlayerResistances`, `OnGolemMissileDamage`; the missile/damage-type/`naturalRangedMissileId` additions are usertype/module bindings, not event call-outs).

---

## Phase 10 — Ally Progression: block 6 (acid-as-magic + Bonded immunity piercing)

Two distinct target-side resistance behaviours, both expressed in one pair of C++ hooks bracketing the monster-vs-monster missile resolution.

**(A) Acid resolved by Magic resistance whenever one of our allies is on either end (not Bonded-gated).** The engine has no monster acid-resist tier (`Monster::isResistant` ignores `RESIST_MAGIC` for an Acid missile — verified in `monster.cpp`), so monster-side acid is all-or-nothing (full, or 0 if `IMMUNE_ACID`). To mirror the player side (where acid resolves through magic resistance), when one of our allies is the source OR target of an acid missile and the target is **not** acid-immune, the handler reclassifies the hit to `DamageType::Magic` so the engine resolves it through the target's magic immunity/resistance. Acid IMMUNITY is respected: an acid-immune target (ally or wild) is still blocked (element left as Acid).

**(B) A Bonded *source* pierces the *target's* immunities.** A Bonded ally's missile treats the target's immunity to the cast element as mere "big resistance" (75%) → the hit lands at 25% instead of 0 (monster resistance in the damage code is binary — a `RESIST_*` bit → `dam/4`, or `IMMUNE_*`; verified in `isResistant`/`MonsterTrapHit`). Coarse on/off: any Bonded ally pierces regardless of element; non-Bonded allies and minions never pierce. Fire/Lightning/Magic: transiently clear the `Immune*` bit and set the matching `Resist*` bit. Acid (no resist tier): turn off `IMMUNE_ACID` and resolve as Magic, then flow through the Magic case so a magic-immune target is pierced too. This offensive piercing is distinct from the defensive immunity a Bonded ally *gains* on promotion (block 3) — one is "what my attacks pierce", the other is "what I'm immune to".

**Rolled-immunity exception (PvP):** the random immunity a Bonded ally gained on promotion (`bondedImmunity[seed]`) is NOT pierceable — if the target is one of our locally-tracked allies and the cast element matches its granted immunity, the downgrade is skipped. A cross-Hunter remote target isn't in our `deployedAllies`, so its granted immunity can't be read on this client — a known MP limitation deferred to Net Sync. Piercing of a target's *natural* immunities (incl. wild monsters in single-player, the common case) works regardless.

**New C++ hooks (two thin call-outs bracketing the resolution; all logic in Lua):**
- The resolution site is `MonsterTrapHit` (`missiles.cpp`), which has no source monster in scope, so the hooks live one level up in `CheckMissileCol` where source + target + missile are all available.
- `OnGolemMissilePreResolve(source, target, missileId, damageType) -> int` fires before the `MonsterTrapHit` call; `OnGolemMissilePostResolve(target)` immediately after. Both gated to hits where a `MFLAG_GOLEM` monster is on EITHER end (the existing source-side idiom widened with `|| (monster.flags & MFLAG_GOLEM)` so a wild attacker hitting our ally also fires it — needed for the (A) defence case). The call-out is mod-agnostic and defaults to base behaviour (returns `damageType`); `source` may be null (e.g. a trap).
- The pre-hook may return `DamageType::Magic` to reclassify acid (a monster-only local keeps the shared `damageType` intact for the player-hit branch — `ApplyMonsterDamage` uses `damageType` only to label the event, no second resistance pass) and/or transiently mutate the target's resistance via `monster:setResistance`. Any transient change is restored by the post-hook so it spans only the one synchronous resolution — healthbar/infobox never observe it.
- Block 5's source-side damage buff and block 6's target-side reduction compose (a Bonded spellcaster's buffed Inferno on a fire-immune target deals `buffed_dam / 4`).

**Lua (`init.lua`):** `OnGolemMissilePreResolve` handler reclassifies acid and applies the pierce (via the `PIERCE_OF` element→{immune,resist} map), keyed off our own `deployedAllies` so a vanilla Golem falls through unchanged (Golem barometer). `pierceRestore` records any transient resistance change for `OnGolemMissilePostResolve` to undo.

**Hook count: 74 total / 67 added** (two new events this block: `OnGolemMissilePreResolve`, `OnGolemMissilePostResolve`).

> **Superseded (2026-06-23):** the `OnGolemMissilePreResolve`/`OnGolemMissilePostResolve` bracket above was later **consolidated into a single `OnMonsterMissileHit(source, target, missileId, damageType, minDam, maxDam, dist, shifted) -> int` query call-out** (return `<0` to decline → engine default; else resolve in Lua and return `1`/`0`). This de-saturated `CheckMissileCol` (one mod line instead of four) and moved the whole golem-missile resolution into one `init.lua` handler — element reclass, immunity pierce, the new owner XP-tag, the engine damage step (`monster:resolveMissileHit`, a thin wrapper over `MonsterTrapHit`), and the Bonded kill-credit. Two new bindings (`monster:resolveMissileHit`, `monster:tagForPlayer`); net hook count −1 (the current authoritative count lives in `lua_api_reference.md`). All behaviour above (A/B element rules) is preserved; the `pierceRestore` bridge is gone (set/restore is now inline in the one synchronous call). Done as part of the missile-kill XP-tagging fix — see `project_net_sync_progress`.

---

## Phase 10 — Ally Progression: block 7 (pre-Bonded flash + promotion Flash cast)

Block 7 visual/FX polish — the two coupled FX (`roadmap.md` → block 7). A dedicated "buffed-ally indicator" is covered by the gold ally outline + `Tamed `/`Bonded ` infobox name prefix, so it needs no separate surface.

**Design intent.** A Tamed ally one kill short of Bonded **flashes** on a periodic cadence as an "about to evolve" tell; at the promotion instant it **casts Flash** on its own tile as a celebratory burst and the flash stops.

**New engine surface (two seams; all FX logic in Lua):**
- **`monster:castFlashSelf()`** binding (`Source/lua/modules/monsters.cpp`) — **entirely inside `Source/lua`, no core-engine file touched.** Adds the Flash spell's `FlashBottom`+`FlashTop` missile pair ([spelldat.tsv](../../../txtdata/spells/spelldat.tsv)) at the monster's own tile, sourced from the monster (`TARGET_PLAYERS` — ally-safe vs other player-minions via the existing opposing-faction check in `CheckMissileCol`). Damage is the engine's **native monster-Flash** value: `AddFlashBottom` hardcodes a monster source's `_midam = level*2`; `AddFlashTop` uses the passed roll. So "Flash damage derived from the monster's own damage" holds with **zero engine logic change**. Owner-adjacency friendly-fire (the burst is centered on the ally; an adjacent owner can be hit) is the same deferred class as Diablo's Apocalypse — see Deferred Targeting / Combat QoL.
- **`OnGetMonsterTRN(monster) -> handle|nil`** generic render hook — **one thin call-out** in `DrawMonster` ([scrollrt.cpp](../../../../Source/engine/render/scrollrt.cpp)), placed alongside the existing unique/petrified/infravision TRN selection and **mirroring its same-site sibling `OnGetMonsterOutlineColor`** (hence the `Monster`, not `Golem`, prefix — it is **ungated**, fires for every monster, and any modder can recolor any monster). Returns the engine default (`nullptr`) with no mod loaded → vanilla rendering byte-for-byte unchanged. The handler returns a small int **handle**; the engine resolves it to a stored 256-byte buffer via an append-only session **registry in `lua_event.cpp`** (`RegisterMonsterTRN`, exposed to the binding via `lua_event.hpp`). Companion module binding **`monsters.registerTrn(bytes[256]) -> handle`** registers a palette-remap once at load. The override **wins over** the unique/petrified/infravision TRN when set; a monster on an *unlit* tile is still drawn with the infravision TRN (that path early-returns before the hook), which is fine.

**Lua (`init.lua`):**
- `isOneKillFromBonded(entry)` — true when `kills == mlvl*100 - 1` (the single-kill window; minions never promote).
- Block-7 constants + a one-time `monsters.registerTrn` of an all-one-colour TRN → `BONDED_FLASH_TRN` handle. **Colour is slate blue `0xB0`, NOT white:** per `trn_palette.md` "cross-palette trap" there is no cross-palette-consistent white (each area loads its own `.pal`); the only consistent indices are the warm-red row `0xA0–0xAE` and the slate-blue row `0xB0–0xBC`. `0xB0` (lightest slate blue) matches the Hunter's blue theme; grayscale crypt/cathedral palettes desaturate it to light gray as expected. Tunable via `BONDED_FLASH_COLOR`.
- `GameDrawComplete` advances a frame counter and sets `flashOn = (counter % FLASH_PERIOD_FRAMES) < FLASH_ON_FRAMES` (FPS-relative — no Lua tick source exists, `GameDrawComplete` is per *rendered* frame). Two **orthogonal** knobs: `FLASH_PERIOD_FRAMES` = blink frequency (one rising edge per period); `FLASH_ON_FRAMES` = the solid-blue dwell at the top of each blink. Tuned to **80/20** (~1.3s period @60fps, blue held ¼ of the cycle). Hard on/off — no ease/fade.
- `OnGetMonsterTRN` handler returns `BONDED_FLASH_TRN` for a deployed one-kill-from-Bonded ally while `flashOn`, else nil. O(1) ally lookup (`deployedAlliesById`), like the outline handler.
- `promoteToBonded` calls `entry.monster:castFlashSelf()`. The pre-Bonded flash **stops on its own**: once the kill threshold is crossed `isOneKillFromBonded` is false, so the TRN hook stops remapping it.

**Hooks added this block:** one new event call-out (`OnGetMonsterTRN`); plus `RegisterMonsterTRN` (a non-event support fn for the registry) and the `monster:castFlashSelf()` / `monsters.registerTrn` bindings (usertype/module bindings, not event call-outs).

### Block 7 follow-up — Bonded glow light + spellbook level-name

A permanent glow light source for a **Bonded** ally (its colour identity comes from the block-9 recolour TRN), plus a small naming consistency change.

**Glow (light source).** New thin binding **`monster:setLightRadius(radius)`** (`Source/lua/modules/monsters.cpp`) wraps the engine's own `AddLight`/`ChangeLightRadius`/`AddUnLight` — the same mechanic 'lighted' unique monsters use. The engine **auto-follows** the light as the monster walks (`MonsterWalk` → `ChangeLightXY`/`SyncLightPosition`, [monster.cpp:1072,1081](../../../../Source/monster.cpp#L1072)) and **auto-frees** it on death/removal (the `remove()` binding + `MonsterDeath` both `AddUnLight`), so there's zero per-frame upkeep. Lua: `applyBondedGlow(entry)` calls it with `BONDED_LIGHT_RADIUS = 3` (kept modest — up to 8 Bonded allies can be lit at once); wired into **both** `promoteToBonded` (live promotion) and the redeploy path (already-Bonded ally re-lit on each deploy, since allies don't persist across levels). Vanilla lighting is **monochrome brightness** (the `Light` struct has only `radius`, no colour — [lighting.h:30](../../../../Source/lighting.h#L30)), so the light is a glowing *presence*, not a coloured glow; colour identity comes from the block-9 recolour TRN. The glow keeps the ally's tile lit, so its recolour TRN always shows (it never hits the unlit-tile early-return that would draw the infravision TRN instead).

**Handler precedence (`OnGetMonsterTRN`):** Bonded ally → its permanent recolour TRN (block 9); else a one-kill-from-Bonded Tamed ally → blue flash on the cadence; else nil. The pre-Bonded flash is the blue "charging up" tell; the recolour is the "achieved Bonded" state.

**Spellbook level-name (Lua only).** `OnGetCustomSpeedbookScrollEntries` uses the scroll's full item name as-is for the spellbook callout, so the entry matches the scroll's own item box. Non-unique scrolls (Tamed **and** Bonded) keep their inline `Lvl N`; unique scrolls have no `Lvl N` in their name to begin with (their level lives on its own `Level:` line in the unique info box). *(Reverted an earlier change that stripped `Lvl N` from gold-tier/Bonded non-unique callouts — the `Lvl N` still shows on the scroll item's own infobox, so the spellbook now matches it again.)*

**Surface added:** one new binding `monster:setLightRadius(radius)` (usertype binding, not an event call-out — no change to the hook total).

---

## Phase 10 — Ally Progression: block 8 (summoned-minion buffing + summoner-difficulty enforcement)

Minions summoned by Tamed/Bonded allies (Skeleton King skeletons, Hork demons) are full ally-support recipients, but buffed more simply than their summoner. All in `OnGolemSpawnedMinion` (`init.lua`); no new C++.

- **Flat CLVL% buff, independent of the shared pool.** Each minion gets a straight CLVL% buff to HP / min+max damage / ToHit / AC — the Tame (non-Bonded) tier weight — and does NOT draw from or divide the Tamed/Bonded buff pool (blocks 4–5). Not share-divided. Implemented as `applyMinionBuff(entry)`, layered on `entry.base` with the same write pattern as `applyAllyBuff` (HP buff raises `maxHitPoints` to `base.maxHp + buff`, current untouched — see block 4; baked once, minions are never recalc'd/recalled). All fractions round up.
- **Damage is purely physical CLVL% — no spellcaster split.** No minion type casts an elemental missile (Hork Spawn explode physically; a Skeleton King only raises non-elemental skeletons), so block 5's resistance path never applies.
- **Baked once at spawn, statically.** Minions are transient (summoned/reaped as the parent fights), so there's no live recompute — set once in `OnGolemSpawnedMinion` off the Hunter's current CLVL. `computeAllyBuff`/`applyAllyBuff` early-return for `isMinion`, so the live pool never touches a minion.
- **Summoner-difficulty enforcement (no new C++).** A minion is spawned by the engine at the live game difficulty, but it must match its summoner's *captured* difficulty (a Normal-tamed King raises Normal-scaled skeletons even in a Hell game). When `parent.capturedDifficulty ~= monsters.currentDifficulty()`, the live-difficulty minion is `monster:remove()`d and re-created via `monsters.spawnWithDifficulty(typeId, captured, x, y)` — the same lock the deploy path uses. `remove()` is mid-tick-safe (parks the monster off-map, defers `DeleteMonsterList` to next tick); both spawn sites (`StartGolemSpawnSkeleton`, `ProcessHorkSpawn`) fire the hook as the last thing they do with the minion, so removing it inside the hook is safe. Matching difficulties adopt the engine spawn as-is.
- **Share Potion targets minions too** — `OnCursorMonsterTarget` has no `isMinion` guard, so minions are healed exactly like directly-tamed allies (full heal / 150% overheal proc).

**Not supported (deliberate):**
- Minions don't raise from corpses — vanilla's King doesn't either (`LeoricAi` and `StartGolemSpawnSkeleton` both spawn from nothing; `ActivateSkeleton` only wakes pre-placed dormant skeletons).
- Minions aren't packaged with their summoner on retame/redeploy — they're lost on recall and re-summoned from scratch on the parent's next deploy.

No new C++ hooks. **Hook count unchanged.**

---

## Phase 10 — Ally Progression: block 9 (Bonded recolour TRNs keyed to the rolled bonus)

A Bonded ally wears one of **five distinct recolour TRNs, one per rolled Bonded bonus**, so its tint *reads its immunity at a glance*. All in `init.lua` via the `OnGetMonsterTRN` hook; **no new C++**.

- **Five variants (`BONDED_TRN_TABLE`).** Keyed to the bonus `rollBondedBonus` already stored in `bondedImmunity[seed]`: Fire → bright red + yellow; Lightning → bright blue + white; Magic → white + bright red; +200 AC → near-black + bright grey. Plus a 5th **Gilded Metal** (gold + white-gold).
- **Gilded Metal is a rare Hell-only upgrade.** A Hell-tamed ally (`entry.capturedDifficulty == 2`) has a **15%** chance (`HELL_GILD_CHANCE`) to wear Gilded instead of its bonus colour. Rolled once in `rollBondedTrn(entry)` (called right after `rollBondedBonus` in both `promoteToBonded` and the redeploy path).
- **Scatter / dither application (preserves identity).** `buildScatterTrn(pattern)` recolours only ~2/3 of the global-range pixels with two **fixed bright** colours and leaves ~1/3 the monster's own pixel, using the sprite's built-in checkerboard dither for the spatial pattern (a tan Zombie still reads tan, speckled with its immunity colours). Scatter is used rather than a full repaint (which erases identity) or a rank-matched gradient (which comes out dull/sparse, since most pixels are low-brightness). Density/colour are tunable in each `{A, B, false}` pattern. Full mechanism + tuning in `trn_palette.md` → "Bonded Recolour TRNs" / "Scatter / dithered application".
- **Persistence.** New `bondedTrn[seed]` map saved as a **3rd section** in the mod-data blob (`{kills…, 0, immunities…, 0, trnVariants…}`). The three sections stay in lockstep — `rollBondedTrn` runs alongside `rollBondedBonus` at both entry points (promotion + redeploy), so a Bonded seed always has both an immunity and a TRN variant, and the render handler is a plain lookup.

No new C++ hooks. **Hook count unchanged.**

---

## Phase 10 — Pepin Recovery System (deployed-ally safety net + buy-back store)

A backup ledger so a death, crash, quit, or full inventory never permanently loses a Tame Scroll. Orphaned/dead allies surface as ordinary **buy-back stock in Pepin's existing store** (no custom dialogue); all bookkeeping is invisible to the player. Design lives in `roadmap.md` → "Pepin Recovery System"; remaining MP store-buy verification is tracked under that doc's **Net Sync** section.

**Registry (`recoveryRegistry[seed]`, `init.lua`).** Each entry is just `{ dwBuff, state, order }`. The seed encodes type/uniqueness and `dwBuff` encodes HP/level/difficulty (existing `encode/decodeDwBuff`), so the monster name + full data are **re-derived on demand** (`recoverScrollData`) rather than stored; kills are not duplicated (they already persist in `allyKillCounts[seed]`). `state` is internal-only: `"lost"` (orphaned — recall failed / crashed → free recovery), `"lostfull"` (retamed with no inventory room → free, behaves like `"lost"` but with its own "inventory was full" message), or `"injured"` (died → paid, `level × 100`). Capped at `MAX_DEPLOYED_PER_HUNTER` (8); `putRecovery` evicts the lowest-`order` entry past the cap.

**Lifecycle (state machine).**
- **Deploy** (`OnSpellActionFrame` scroll cast): `putRecovery(seed, …, "lost")` immediately after `trackDeployedAlly`, so a crash/quit while the ally is out still leaves a recoverable scroll. The town invariant (allies can't be deployed in town, Pepin is town-only) guarantees a live ally never shows for sale.
- **Death** (`OnMonsterDeath`): for a non-minion ally, re-encode `dwBuff` to **full HP** (recovered fresh, not at its dying HP), flip to `"injured"`, fire the defeat chat message, and queue the resurrect-beam FX. Minions have no scroll and are skipped.
- **Recall** (`OnLevelExit`): `refreshRecoveryEntry` captures the live ally's final HP, then `recallAllyToInventory` (never drops on the floor). A clean recall deletes the entry; a **full inventory keeps it `"lost"` with no floor drop**. After the sweep, every still-`"lost"`/`"lostfull"` entry gets its chat message (repeats each level change — accepted spam if the player never visits Pepin).
- **Game entry** (`GameStart` → `announceRecoveryOnEntry`, after `relinkSavedAllies`): re-announce **every** backup waiting at Pepin — `"lost"`, `"lostfull"`, and `"injured"` — so a player loading in is reminded of pending recoveries up front. Seeds that were re-linked as live deployed allies (SP mid-dungeon load) are skipped so we only nag about scrolls still to reclaim.
- **Retame** (manual, Tame skill on own ally): `refreshRecoveryEntry` (capture current HP), then `recallAllyToInventory` — **never drops the scroll on the floor**. A clean recall deletes the entry; a **full inventory keeps the backup as `"lostfull"`** (scroll lives only in recovery storage) and fires the inventory-full message immediately. Floor-dropping was removed: a floor scroll alongside a live backup is two copies at once, which in multiplayer lets another player grab the floor copy and duplicate it (was a documented Net-Sync follow-up; eliminated at the source instead). The scroll can now only ever be a deployed ally → the owner's inventory/belt → the owner's recovery storage — never grabbable by anyone else.
- **Buy-back** (`StoreOpened` "pepin"): drop any registry seed already in the player's inventory (a held scroll can only be one bought back, so it's no longer owed), then stock each remaining entry via the extended `addToHealerStock` (free for `"lost"`/`"lostfull"`, `level × 100` for `"injured"`). No store-purchase hook needed (the bought copy is `HealerItems.erase`d immediately; the stale entry clears on the next open).

**Resurrect-beam FX.** Queued per dying non-minion ally in `pendingResurrectBeam` (mirrors the `corpselessDeaths` handoff) and fired one frame later in `OnMonsterCanPlaceCorpse` — the **final death frame** — via the new `monster:castResurrectBeamSelf()`. Both sets are cleared in `OnLevelExit` so a reused monster id never inherits a stale beam.

**Persistence.** A **4th section** of the existing mod-data save block (`OnSavePlayerData`/`OnLoadPlayerData`): `(seed, dwBuff, state)` triples after a third `0` marker. `state` is encoded `0 = "lost"`, `1 = "injured"`, `2 = "lostfull"`. The seed slot (never 0) guards the load loop since `state` may legitimately be 0.

**Chat messages.** Via `require("devilutionx.message")` (`EventPlrMsg`), one line per state:
- `"<Name> has been defeated and can be revived at Pepin."` — on death (`"injured"`).
- `"<Name> was Lost in the dungeon. Recover at Pepin."` — per `"lost"` entry.
- `"Inventory was full. <Name> sent to Pepin for recovery."` — per `"lostfull"` entry, fired immediately on the full-inventory retame.

`"lost"`/`"lostfull"` lines repeat on each level change and are replayed for **every** outstanding backup on **game entry** (`announceRecoveryOnEntry`). `<Name>` is the **full scroll item name** (`Tamed/Bonded [Lvl N] [Name]`, `Lvl N` omitted for uniques) built via `buildScrollParams`. The shared helper `recoveryMessageFor(seed, rec)` picks the line from `rec.state` off the `recoverScrollData` record (used by the level-exit sweep, the game-entry replay, and the immediate retame announce); the death path builds its own from `allyToMonsterData(monster, entry)` — so the message always matches the scroll, not the bare monster type.

**Tame Scrolls made unsellable.** New generic engine query hook **`OnVendorWillBuyItem(item, defaultValue)`** (declared `lua_event.hpp`, dispatched `lua_event.cpp`, registered `events.lua`), called as the last line of **both** `SmithWillBuy` and `WitchWillBuy` (`stores.cpp`) fed the vanilla result as default — Smith's early-returns were converted to a single `rv` (precedence preserved) only to reach the call-out; vanilla-identical with no handler. The mod's handler returns `false` for any `isScrollOf(TAME_ID)`, removing Tame Scrolls from every vendor's buy-from-player list (classic + visual store, both gate on these predicates). The `class = Quest` Lua trick was rejected as hacky/MP-risky; the item-value lever was confirmed useless (the sell list never reads value).

**C++ surface added:**
- `OnVendorWillBuyItem(const Item *item, bool defaultValue)` — one new event call-out (thin query, Hook-Philosophy-compliant).
- `items.addToHealerStock` — **extended** with optional `seed`/`name`/`dwBuff` + dedupe by `(mapping, seed)` (module binding, backward-compatible — the Forget-Potion call is unchanged).
- `monster:castResurrectBeamSelf()` — new usertype binding (visual-only `MissileID::ResurrectBeam`).

---

## Phase 10 — Engine cleanup (Hook Philosophy audit / "Branch A")

A full pass bringing **every** mod-touched engine file into line with the C++ Hook Philosophy (CLAUDE.md): thin generic call-outs only, mod-only full functions `Lua`-prefixed, vanilla functions left byte-for-byte unchanged + not needlessly externalised, generic mod-agnostic comments, no stale/dead code. No gameplay change — the whole branch is refactor + renames + comment hygiene, so it compiles to identical behaviour. **Blow-by-blow lives in memory `project_golem_cpp_thinning` (the file-by-file sweep) + `project_engine_surface_inventory` (the end-of-project PR-explainable accounting);** this is the as-built summary.

- **`monster.cpp`/`.h`:** `StartGolem*` → thin `LuaStartMonster*` wrappers (vanilla helpers kept in their anon namespace); `ChangeMonsterToGolem` → `LuaChangeMonsterToGolem` (+ `ownerPlayerId` param, defaulted to `MyPlayerId` so no-arg callers are unchanged); `AiPlanPath`/`ScavengerFindCorpse` restored to internal linkage behind thin `LuaMonster*` wrappers; dangling `StartFadeout/Fadein` decls + the dead `OnGolemSpawnedMinion` hook removed.
- **`player.cpp`/`.h`, `missiles.cpp`:** audited compliant; only cosmetic include-ordering fixes. `isOnActiveLevel`/`isLevelOwnedByLocalClient` confirmed **vanilla** (not mod-added). The 8 missile hook families default byte-for-byte vanilla.
- **`msg.cpp`/`.h`:** the two mod-only delta funcs renamed `LuaDeltaRemoveSpawnedMonster` / `LuaDeltaRegisterDroppedItem` (they read like vanilla `DeltaAddItem`); net pipe (`CMD_LUAMSG`/`TCmdLuaMsg`), array-cap infra, and `TItem.dwLuaData` all cleared.
- **`items.cpp`/`.h`:** 4 fixes incl. reconciling our divergent `GetItemAnimIndex` back to upstream `GetItemAnimType`, and two vanilla-divergence bugs found + fixed (`GetTranslatedItemName` composed-name early-return, `PrintItemMisc` oil fallback in `None` control mode).
- **`lua/lua_event.*`:** cross-checked all hook decls ↔ cpp defs ↔ `events.lua` in both directions — no dead hooks; `OnNetMessage`→`lua::NetMessage` rename to match the event it fires; jammed multi-decl lines split.
- **Wider UI footprint (~25 files / ~80 markers):** control_infobox, spell_book/list/icons, objects, qol/monhealthbar, debug, multi, loadsave, pack, pfile, sync, validation, scrollrt, diablo, inv, cursor, stores, tables — all markers confirmed thin call-outs / sanctioned array-cap infra / the gated item-modData persistence / imported custom-cursor framework. Only change: added a missing `// Lua mod support` marker to the `lua::StoreOpened` call.
- **`Lua`-prefix sign-off (user's rule):** code *specifically for Lua* gets the `Lua` prefix; code **engrained in engine logic** (base game depends on its work at default) stays unprefixed (`LoadSpellDatFromFile`, `GetItemAnimType`); pre-Monster-Tamer-commit-1 code left alone. Prefixed: `LuaRegisterDynamicSpellId`/`LuaDynamicSpellIds`/`LuaRegisterDynamicSpellIcon`/`LuaParseSpellIconName`/`LuaClearDynamicSpellIcons`/`LuaDynamicSpellIconFrames`/`LuaSavePlayerModData`/`LuaLoadPlayerModData`.

---

## Phase 10 — Pepin Recovery unique-scroll quality (DONE, verified 2026-06-25)

A gold/unique-tier recovery scroll (seed-unique champion/boss, or any Bonded scroll) bought back from Pepin's
recovery list used to lose its gold lettering + custom unique infobox + "Unique Item" line until a full retame.
**Root cause:** the recovery scroll was stocked via `items.addToHealerStock(...)`, which created the stock item
at `ITEM_QUALITY_NORMAL`; a vendor purchase (`HealerBuyItem` → `StoreAutoPlace`) copies the stock item's fields
verbatim and fires none of the pickup/level-enter/recreate quality fixups, so the bought scroll entered the
inventory at normal quality and the unique-box gate (`items.cpp` — `_iMagical == ITEM_QUALITY_UNIQUE`) never
fired. **Fix:** added an optional `magical` param to `addToHealerStock` / `LuaAddToHealerStock`
(`Source/lua/modules/items.cpp`; default unchanged), and the recovery-stocking call now passes
`ITEM_QUALITY_UNIQUE` for gold-tier scrolls (`seedGetUniqueType(seed) >= 0 or isBonded(seed, level)`), so the
bought copy is gold + unique-box-eligible from purchase — no retame needed. **User-verified good 2026-06-25.**

---

## Phase 10 — Deterministic dynamic-spell registry + Hellfire fix (C++ + Lua, 2026-06-25)

**Symptom:** Tame skill and Tame Scroll could not be cast in **Hellfire** gamemode (worked in Diablo).
**Root cause:** dynamic spells were *appended* at `SpellsData.size()`, so their IDs shifted with the base
table (37 spells in Diablo → Tame=38; 52 in Hellfire → Tame=53). `InitNewSpell` (`Source/msg.cpp`) rejected
`wParamSpellID > SpellID::LAST` (=52), so 53+ never cast. The same position-dependence also meant a character
moved between `.sv` (Diablo) and `.hsv` (Hellfire) — which DevX allows natively — would mis-read its
skill/scroll bitmask bits (bit 38 = Tame in Diablo, = Mana in Hellfire).

**Fix — engine "thin pipe", Lua owns policy** (per design decision; net model = deterministic, no runtime sync):
- New deterministic dynamic-spell registry in `Source/tables/spelldat.cpp`. `spells.registerSpell(name, path, icon?)`
  **queues** during `SpellDataLoaded` (`LuaQueueDynamicSpell`); `LoadSpellData` then runs `LuaFinalizeDynamicSpells`
  (sort queued by name → assign IDs from `SpellID::LAST + 1` → pad `SpellsData` with inert `bookLevel=staffLevel=-1`
  placeholders so direct indexing is valid in both modes and the save layout stays byte-identical to vanilla →
  load each TSV into its slot → register name→ID + icon) and fires the new `lua::SpellsAssigned()` event.
- `spells.getSpellId(name)` returns the assigned ID (mod reads it in `events.SpellsAssigned`). Names are
  **namespaced** (`hunter:tame` / `hunter:sharepotion` / `hunter:forgetpotion`) so spell-adding mods never collide.
- `InitNewSpell` guard changed from `> SpellID::LAST` to `>= SpellsData.size()` (byte-identical for base game;
  `IsValidSpell` already used that bound one line later).
- Result: a name resolves to the **same ID in Diablo and Hellfire and across load order**, so `.sv`↔`.hsv`
  migration and same-mod-set MP both stay consistent with no registry sync. Ceiling: IDs 53–63 (~11 slots, the
  64-bit per-player spell sets). Pre-existing characters/scrolls under the old appending scheme are throwaway
  (no backwards compat).

**Files:** `Source/tables/spelldat.h/.cpp`, `Source/lua/lua_event.hpp/.cpp` (`SpellsAssigned`),
`Source/lua/modules/spells.cpp` (`registerSpell`/`getSpellId`, removed `addSpellDataFromTsv`), `Source/msg.cpp`,
`assets/lua/devilutionx/events.lua`, `init.lua` (queue + `SpellsAssigned` resolve),
`txtdata/classes/hunter/starting_loadout.tsv` (`skill = hunter:tame`). **Built + in-game verified working 2026-06-25** (Tame skill + scroll castable in both Diablo and Hellfire).

---

## Phase 10 — Net Sync (Branch B): cross-client tamed-ally replication (C++ + Lua, VERIFIED 2026-06-25)

Full multi-client multiplayer for tamed allies, built entirely on **one** generic engine net primitive (the
Lua message pipe) plus a small set of thin generic hooks; all replication logic lives in `init.lua`.
**Verified working in a two-client game 2026-06-25** (remote allies spawn/animate, Bonded display + hover +
floating box, starter OH, fresh-tame scroll persists + is pickable; no ghosts after the `monster:remove()`
all-three-`dMonster`-fields fix). Authoritative mechanism + data-model design refs remain in
`net_sync.md`; per-session blow-by-blow in memory `project_net_sync_progress`.

- **The only net command the mod adds:** generic `CMD_LUAMSG`/`TCmdLuaMsg` (length-prefixed, `LUA_MSG_MAX_LEN=255`),
  `NetSendCmdLuaMessage`, `lua::OnLuaMessage` → `NetMessage` event, `system.netSend(payload[,mask])`. Every
  cross-client behaviour rides it as a Lua message type — never a new `CMD_*`. The net layer is multiplexed by a
  standalone **LuaNet** companion-mpq (channel framing; see memory `project_luanet`).
- **Architecture — two planes:** Plane 1 (combat-relevant live state: type/stats/HP/resist/`MFLAG_GOLEM`+owner)
  rides the spawn/conversion pipe so every client (Hunter & non-Hunter) renders the ally; Plane 2 (Hunter
  progression/cosmetic: kills, Bonded immunity/TRN, names, OH/ID) is Hunter-only (item encoding for trades + the
  pipe for live view + per-Hunter `luamoddata` save). Pipe traffic is level-scoped; load-ins re-sync on entry.
- **Ledger (all done):** N1 ownership broadcast (`MG`→`SP` species-keyed spawn via `monsters.netSpawnAt`),
  N2 seed uniqueness (monotonic `scrollCounter`, by construction), N3 live-remove (`RM`/`CR`), N4 retired
  (premise void — allies recall on level exit, never delta-persist), N5 XP (inherited via `goalVar3`/`whoHit` +
  the `OnMonsterMissileHit` consolidation), N6 recovery store-buy round-trip; DM1 combat-override (`CO`),
  DM2 modData encoding, DM3 seed hardening, DM4 Plane-2 live view, DM5 non-Hunter suppression, DM6 owner-local
  recovery. Deterministic personality AI runs on every client (synced per-monster RNG via `monsters.aiRandom`).
- **Item mod-data:** carried by the OPTIONAL `item.modData` blob (`_iModData`) — live over the `SD` pipe message
  + at-rest in a per-level `DLevel.modData` delta map; vanilla item net commands + the `.sv`/`.hsv` save streams
  stay byte-identical (non-Hunter saves never change). See `item_moddata.md` "AS BUILT".
- **Thin generic engine additions (all default = vanilla):** `monster:makeGolem(ownerId?)`,
  `player:isOnActiveLevel()` / `:isLevelOwnedByLocalClient()`, `monsters.netSpawnAt`/`fromId`/`aiRandom`,
  `monster:startSkeletonSpawnCast`, hooks `OnGolemMinionMissileSpawn` + `OnMonsterMissileHit`, `system.isMultiplayer`.

---

## Phase 10 — Tamed-pet Infobox / Floating Infobox + Original-Hunter ID (C++ + Lua, DONE + playtested 2026-06-25)

Rich hover readout for a deployed Tamed/Bonded monster, shown to **any friendly observer of any class** (own
ally or a peaceful player's pet); a hostile observer gets vanilla behaviour. Built + playtested 2026-06-25.

- **Regular infobox** (`OnGetMonsterInfo`): Tamed/Bonded **name** + live **resistances/immunities** + **Hit
  Points** + **Kills**. (`Type` was intentionally moved OUT of this box into the floating box.)
- **Floating infobox** — **fully self-drawn in Lua** each frame in `GameDrawComplete` (NOT the base-game item
  float box, which renders one colour per line and is gated by the `floatingInfoBox` QoL toggle). Always shows
  for a hovered friendly pet, colours each value. Line order (top→bottom): stat rows `base / buffed` for Min/Max
  Dmg, ToHit, AC, HP (white label/base, **blue** buffed) → **gold** `Found: <Area> Lvl N / <Difficulty>` →
  **gold** `Type: <monsterClass>` → **gold** `OH: <name>   ID: <id>` → **gold** `Version: <Diablo|Hellfire>`
  (last line). Engine: `render.string` gained optional `flags`; new `render.string_width` + `render.mouse_position`
  (all generic, default-vanilla).
- **`Found: <Area> Lvl N`** = the dungeon level the pet was tamed on, captured at fresh tame
  (`items.currentDeltaLevel()`), stored in a seed-keyed `scrollAreaLevel[seed]` mirroring the `scrollGamemode`
  plumbing exactly (modData blob field, re-keyed on pickup, persisted, synced on `CO`). Zone bands rebased per
  the base-game automap `displayOffset` (Church/Catacombs/Caves/Hell show absolute dlvl; Nest/Crypt restart at
  1–4); quest setlevels (>24) read as the bare quest-area name (mirrors engine `QuestLevelNames`).
- **OHID (Pokémon Trainer-ID model):** a permanent 9-digit numeric generated once at character creation
  (`hashString(name)+os.time()` mod 1e9), the **final field in the Hunter save blob**; OH **name** is just the
  owning Hunter's character name (never stored separately). **Survives trade — pure Lua, no engine change:**
  the OT `{name,id}` is folded into the seed-keyed `item.modData` blob (the old `OO`/`NET_ORIGIN` pipe was
  retired), re-keyed on pickup, and also carried on the `CO` message so a remote observer's box shows the TRUE
  original tamer.

---

## Phase 10 — MP ally slot model: bring-up, leash sync + delta hygiene (C++ + Lua, VERIFIED 2026-07-05)

The final MP bring-up wave: the high-slot model compiled and proven in two-client testing, plus the bug
sweep it surfaced — all found, fixed, and re-verified 2026-07-05 (full forensics per bug in `bugs.md`;
the distilled model now lives in `net_sync.md` §3).

- **Slot model green:** `AllocateHighMonsterSlot` + `requestExtraMonsters` reservation verified live —
  allies materialise on peers at slots above the natural region via `RQ`→`SP`→`netSpawnAt` clobber, with
  the starter-scroll charTag seed hardening (DM3) landed during bring-up.
- **Leash sync (`snapToPlayer`):** the binding is client-local by design, and the old owner-only leash
  assumed snaps would propagate — they never did. Fixed pure-Lua: the leash runs **symmetrically on every
  client**, remote allies leashing to *their* engine-synced owner (the MP monster model: simulate
  everywhere, let proximity sync converge the residual).
- **Delta hygiene (three bugs, one invariant):** routine cross-level `CMD_SYNCDATA` fills delta records
  for ally slots on clients that never materialised them; applied at level load to uninitialized slots
  they rendered frozen "golem ghosts" (recall + owner-quit repros) and fed a debug-assert hard crash
  (ally-death repro — the visible `PlayerState[255]` net-thread crash was the `FreeDlg` shutdown race
  masking the real assert). Fixes: *an ally that stops existing is forgotten by every client's delta* —
  `RM|id|level` + `monsters.removeDeltaSpawnedMonster(level, id)` (the level-keyed
  `LuaDeltaRemoveSpawnedMonster` overload, sibling of `LuaDeltaKillMonster`) on recall AND death; plus the
  hard guarantee, the `DeltaLoadMonsters`/`DeltaLoadEnemies` **extended-region gate** (skip slots
  `≥ MaxMonsters` with no `spawnedMonsters` entry — vanilla-dead 2-liner) covering the no-message paths
  (owner quit, client crash). All three repros re-verified clean.
- **Cap right-sizing:** `MAX_DEPLOYED_PER_HUNTER` 8 → 4 with minions now counted in the reservation:
  worst case 4 Hunters × (4 allies + SK 3 + Hork 3 minions) = 40 slots ≤ the 52-slot extended region
  (8/hunter could exceed it). Types reservation 18 (16 ally species + 2 shared minion species).
- **Files:** `Source/msg.cpp/.h` (overload + gate), `Source/lua/modules/monsters.cpp`
  (`removeDeltaSpawnedMonster` binding), `init.lua` (symmetric leash, `myDeltaLevel`, RM protocol +
  dead-guard, death forget, caps); PR docs in `cpp_changes/monsters.md` + `net.md`.

---

## Phase 10 — PvP: allies target hostile players + Friendly Fire extended to pets (C++ + Lua, VERIFIED 2026-07-06)

Pre-Diablo-taming prerequisite: tamed allies fight hostile PLAYERS, and the engine's Friendly Fire toggle
governs every pet↔player missile interaction in both directions. Hook catalog + engine proofs in
`lua_api_reference.md` + `cpp_changes/monsters.md`; policy summary in `roadmap.md` ("Minion friendly-fire —
resolved").

- **Player targeting:** new `OnGolemCanTargetPlayer` in `UpdateEnemy` (default false = vanilla; the vanilla
  Golem never targets players — barometer). Policy: never the owner, `arePeaceful` → no; adjacent hostile
  always (self-defence); else owner-anchored `ENGAGE_RADIUS` + LOS. `GolumAi`'s monster reads gated on
  `MFLAG_TARGETS_MONSTER`; `OnGolemChooseAction` forwards `enemyPlayer`; new bindings `monster:startAttack()`
  + `monster:hasLineOfSightToPlayer(player)`. Ranged/hybrid/sneak handlers act on `enemy or enemyPlayer`
  (`golemHasLosToTarget` dispatch); a last-in-chain melee handler swings when adjacent to a player target
  (`OnGolemIdle`'s pursue branch closes distance). Everything else rides the existing shared player-target
  machinery (enemyPosition refresh, `MonsterAttackPlayer`, `encode_enemy` player offset).
- **FF, pet missiles vs players:** `PlayerMHit` has no faction/toggle check — new `OnGolemMissileCanHitPlayer`
  at the `CheckMissileCol` dispatch (MFLAG_GOLEM-source gate; veto = missile passes through). Policy: never
  the owner (self-hit analogue, unconditional); other players get `Plr2PlrMHit`'s exact gate (FF off +
  friendly owner → no hit). New getter `system.isFriendlyFireEnabled()` (`sgGameInitInfo.bFriendlyFire`).
- **FF, player missiles vs pets (mirror):** new `OnPlayerMissileCanHitGolem` at the `MonsterMHit` dispatch
  (MFLAG_GOLEM-target gate). Policy: FF off + caster is owner/peaceful-with-owner → pass through; FF on or
  hostility → vanilla (pets fair PvP game; vanilla Golems always hittable).
- **Apocalypse vs pets:** vanilla `ProcessApocalypse` skips ALL player-minions; new
  `OnApocalypseCanTargetGolem` ANDed after the vanilla skip (default false — can only widen). Policy: hostile
  caster may boom another Hunter's pets; own/peaceful pets protected unconditionally (FF-independent, since
  Apoc can't hit players); vanilla Golems keep the vanilla exclusion.
- **Targeting-layer veto rebalance:** the auto-aim direct-target vetoes (own pet / peaceful Hunter's pet)
  stay unconditional; the collateral-path veto — now `friendlyAllyNearPath`, sweeping own pets AND a
  peaceful Hunter's pets (own ∪ peaceful-remote = same protected set on every mutually-peaceful client) —
  applies only while FF is ON (with FF off the damage layer makes the line safe, restoring full auto-aim
  reach/bounces).
- **Files:** `Source/monster.cpp/.h`, `Source/missiles.cpp`, `Source/lua/lua_event.hpp/.cpp`,
  `Source/lua/modules/monsters.cpp`, `Source/lua/modules/system.cpp`, `events.lua`, `init.lua`; PR docs in
  `cpp_changes/monsters.md`.

---

## Phase 10 — MP self-healing sync layer + deploy-gate hardening + stat-hook class gating (Lua only, VERIFIED 2026-07-06)

The bug-sweep wave after the first sustained multi-Hunter sessions (full forensics per bug in `bugs.md`;
protocol now in `net_sync.md` §4). Principle established: **one-shot messages (SP/RM/CR/DF) are hints, the
periodically re-asserted owner state is truth** — peers reconcile instead of trusting any single delivery.

- **`RS` roster heartbeat (~2.5s, `system.gameTick()`-paced):** each Hunter broadcasts the ally/minion slot
  ids it owns (an empty roster is meaningful). Same-level peers remove tracked copies not in the roster
  (lost RM with the owner present) and RQ a resend for listed ids they're missing (lost SP). The SP receiver
  is idempotent (an already-tracked live copy is kept, not clobber-reinitialised; the cached CO profile
  survives an owner-matched resend); RQ answers now resend minions too (seed 0 + `parentId`;
  `adoptOwnMinion` keeps `capturedDifficulty` for it).
- **Capture replay:** the captor logs capture-removals per level (`capturedNaturalMonsters`) and replays
  them as `CR`s in every RQ answer, so a client whose delta missed the kill reaps the regenerated wild
  monster live (CR live-branch `hp > 0` guard keeps replays off dead copies).
- **Reaper + tracking invariants:** `reapOrphanedRemoteAllies` also reaps when the owner left the LEVEL
  (debounced); `trackDeployedAlly` evicts a stale same-slot entry (one slot = one live monster — the
  mislabeled-scroll fix).
- **Deploy gates (per-Hunter, user-confirmed design):** cap = `MAX_ALLIES = MAX_DEPLOYED_PER_HUNTER` (4);
  one instance of a unique per Hunter (two Hunters may field the same unique). Gates count in-flight
  `pendingDeploys` (the DR round-trip window) and skip minion entries safely (`seedGetUniqueType(nil)` was
  an error that silently killed the hook and voided scrolls). The level owner mirrors both gates
  authoritatively on `DR` (over the requester's `remoteAllies`) and answers `DF` on EVERY rejection;
  requester-side `pendingDeploys` are tick-stamped with a ~5s self-refund, and a level change refunds
  in-flight requests instead of dropping them (no more scrolls into the void).
- **Stat hooks class-gated (join-validation fix):** `UnPackNetPlayer` recomputes and equality-validates
  derived stats (`_pDamageMod`, `_pIAC`, `_pIMinDam/_pIMaxDam`, `baseToBlock`, …), so every
  archetype/derived-stat/animation hook now gates on `p.className == HUNTER_CLASS` instead of `isMyPlayer`
  (deterministic from synced class/stats/level on every client). Deliberate exception:
  `OnGetMaxAttributeValue` stays isMyPlayer (unpack clamps incoming base stats against it — remote Hunters
  must resolve the static TSV maxima). UI-only gates (item use, speedbook, Wirt, potions, shrines) stay
  isMyPlayer.
- **Scroll-origin heal extension:** `healHeldScrollModData` now recreates an ABSENT `scrollOrigin` record
  (restore from the scroll's own blob; else claim locally — only our own creation is record-less AND
  blob-less), fixing the starter pet's blank OH tag after reload.
- **Files:** `init.lua` only (+ doc updates: `net_sync.md` §4, `bugs.md`).
