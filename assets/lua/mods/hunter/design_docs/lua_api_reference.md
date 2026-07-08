# Lua API Reference

Complete reference for the DevilutionX Lua mod system as extended by the Hunter mod project.

**80 hooks total: 7 pre-existing in DevilutionX (StoreOpened, OnMonsterTakeDamage, OnPlayerGainExperience, OnPlayerTakeDamage, GameDrawComplete, GameStart, LoadModsComplete) + 73 added by this project.**

---

## How Mods Load

- Mods live at `assets/lua/mods/<modname>/init.lua`, loaded via `mods.<modname>.init`
- See `Source/lua/lua_global.cpp:LuaReloadActiveMods()`

## Requiring Modules

```lua
local events   = require("devilutionx.events")
local player   = require("devilutionx.player")
local monsters = require("devilutionx.monsters")
local spells   = require("devilutionx.spells")
local items    = require("devilutionx.items")
local audio    = require("devilutionx.audio")
local message  = require("devilutionx.message")
local system   = require("devilutionx.system")
```

### System module (`devilutionx.system`)
- `system.get_ticks() -> integer` — milliseconds since game start
- `system.isMultiplayer() -> boolean` — `true` in a multiplayer game **including a solo-hosted game**, `false` in single-player. Thin getter over `gbIsMultiplayer` (`Source/lua/modules/system.cpp`). Player count cannot distinguish solo-hosted MP from SP, so this is the reliable SP/MP gate — used to scope the single-player Load-Game ally re-link (the deployed-ally roster is persisted/applied only in SP; MP deployed allies persist via the network delta)
- `system.isHellfire() -> boolean` — `true` if the current game runs the **Hellfire** gamemode, `false` for Diablo. Thin getter over `gbIsHellfire` (`Source/lua/modules/system.cpp`), sibling of `isMultiplayer`. Used to stamp a tamed scroll's "tamed-in gamemode" at capture (packed in the `item.modData` blob — never `dwBuff` bit 0, which is the engine's live `CF_HELLFIRE` flag)
- `system.isFriendlyFireEnabled() -> boolean` — the game's **Friendly Fire** option. Thin getter over `sgGameInitInfo.bFriendlyFire` (`Source/lua/modules/system.cpp`), sibling of `isMultiplayer`/`isHellfire`. Part of the synced game-init info (fixed at game creation, `CantChangeInMultiPlayer`), so it reads identically on every client — safe in deterministic per-tick hooks. The engine itself applies it **only** to player-vs-player missiles (`Plr2PlrMHit`); the mod extends the same rule to pets in **both directions** — pet missiles vs players (`OnGolemMissileCanHitPlayer`), player missiles vs pets (`OnPlayerMissileCanHitGolem`) — and keys the `friendlyAllyNearPath` targeting veto off it (path veto active only while FF is on; sweeps own pets + a peaceful Hunter's pets)
- `system.gameTick() -> integer` — the **synced lockstep tick counter** (`sgdwGameLoops`, thin getter via `Source/lua/modules/system.cpp` + `multi.h`). DevilutionX MP is a deterministic lockstep sim; this counter advances once per game tick **identically on every client**, and a client that joins mid-game is initialised to the current value (`ParseTurn`), so even a late joiner reads the same number at the same tick. **Use it to make cached/periodic mod decisions join-time-independent:** derive them from `(gameTick, a stable id)` — e.g. `syncedHash(math.floor(gameTick()/period), monster.id)` — instead of computing/caching them at whatever tick the local client happened to start, so every client agrees with **no network traffic**. This mirrors how the engine keeps per-monster AI RNG in sync (`MonsterSeeds` re-bases each monster's `aiSeed` from this counter + slot id every tick — so `aiSeed` itself needs no syncing). Free-running (not reset per level); the single-player value is not meaningful (only cross-client agreement / differences / modulo are). First use: `OnGolemIdle`'s wander spot (fixes the late-join ally jitter — see `bugs.md`)
- `system.netSend(payload: string, mask?: integer)` — send an opaque payload to other clients over the generic Lua net pipe; received via the `NetMessage` event. Default target is all other players (the local sender applies its own effects directly); pass a player bitmask to override. **No-op in single-player.** This is the single mod-agnostic net primitive — all cross-client behaviour rides it as a Lua message *type* (a string the mod's own dispatch switches on), never a new engine command. **Mod convention:** payloads are `"<TAG>|<args...>"`; current types (init.lua net section): **`"SP|id|species|uniqueIdx|difficulty|x|y|seed|owner"`** = recreate + golem-convert a deployed ally on a peer (via `monsters.netSpawnAt` then `makeGolem(owner)`); **`"RQ"`** = "I just entered this level, ally owners (re)send your allies" (sent on `OnLevelEnter`); **`"MG|id|owner"`** = convert an already-present peer monster to a golem (engine-spawned minions, best-effort); **`"CR|id"`** = a wild monster was tamed (removed locally) — same-level peers remove the same *non-golem* monster too, so the level owner's sync can't re-materialise it (guard: not `isGolem`, since allies use `RM`); **`"CO|...|kills|gamemode|ohId|ohName"`** = the ally owner's combat/profile broadcast (28 fields; `ohName` last/sanitised) carrying everything the info boxes need (base stats, kill count, tamed-in gamemode, Original Trainer). Receivers **must level-scope** before acting on a monster slot id (see `player:isOnActiveLevel`)

### Render module (`devilutionx.render`)
Immediate-mode drawing to the back buffer. Only meaningful inside the per-frame `GameDrawComplete` event (anything drawn elsewhere is overwritten before present).
- `render.string(text: string, x: integer, y: integer, flags?: integer)` — draw `text` at screen pixel `(x, y)`. Optional `flags` = a `render.UiFlags` bitmask for colour/font/alignment/outline (OR them together, e.g. `render.UiFlags.ColorBlue | render.UiFlags.Outlined`). Omitting `flags` = default white GameFont12 (unchanged from the original binding).
- `render.string_width(text: string) -> integer` — pixel width of `text` in the default game font (GameFont12). Use to lay out multiple coloured segments on one line: draw segment A, advance `x` by its width, draw segment B in another colour.
- `render.mouse_position() -> integer, integer` — current cursor position in screen pixels (`x, y`). Use to anchor a hover box near the cursor.
- `render.screen_width() / render.screen_height() -> integer` — screen size in pixels (for clamping on-screen).
- `render.UiFlags` — table of `UiFlags` values: colours (`ColorWhite`, `ColorBlue`, `ColorWhitegold`, `ColorRed`, `ColorGold`, …), font sizes (`FontSize12`…), alignment (`AlignCenter`, `AlignRight`, `VerticalCenter`), and `Outlined` (1px black outline → readable over the world with no background box). Combine with `|`.
- *Used by:* the §2 tamed-pet floating stat box (self-drawn each frame, per-value blue, independent of the base-game Floating Item Info Box toggle).

---

## Events

The event/hook catalog — every signature, C++ fire site, and default — followed by the Lua-side usage
notes. Engine changes beyond a thin call-out live in `cpp_changes/`.

### Dynamic Class Constraint

Hunter registers via `addClassDataFromTsv` — its `HeroClass` enum value is assigned at runtime. All C++ switch statements have no `case HeroClass::Hunter:`, so Hunter falls to `default` everywhere. All mechanics are unlocked via Lua query/fire events.

### All Implemented C++ Hooks (catalog)

| Hook | Purpose | Key file |
|---|---|---|
| `OnCanPlayerUseItem(player, item) -> bool\|nil` | Block elixirs etc. | `Source/player.cpp` `CanUseItem` |
| `OnGetMaxAttributeValue(player, attribute) -> int\|nil` | Per-stat max override; `"Strength"/"Magic"/"Dexterity"/"Vitality"` | `Source/player.cpp` `GetMaximumAttributeValue` |
| `OnGetPlayerDamageMod(player, strMod, strDexMod, totalVit, isBow, isShield, isStaff, isUnarmed) -> int\|nil` | Override `_pDamageMod` for dynamic classes | `Source/items.cpp` `CalcPlrDamageMod` |
| `OnGetManaCost(player, baseCost) -> int\|nil` | Override spell mana cost for non-named classes | `Source/spells.cpp` `GetManaAmount` |
| `OnPlayerHasCriticalStrike(player) -> bool\|nil` | Grant crit (50% chance per level to 2× dmg) | `Source/player.cpp` `DealDamage`, `P2PGetDamageDealt` |
| `OnPlayerHasIronSkin(player) -> bool\|nil` | Grant `_pIAC += level/4` | `Source/items.cpp` `CalcPlrDamageMod` |
| `OnPlayerHasNaturalResistance(player) -> bool\|nil` | Grant all resists `+= level` | `Source/items.cpp` `CalcPlrResistances` |
| `OnGetBowDamageMod(player, fullMod) -> int\|nil` | Override bow `_pDamageMod` contribution | `Source/missiles.cpp` `MonsterMHit` |
| `OnGetArrowVelocityBonus(player) -> int\|nil` | Add to arrow velocity after class checks | `Source/missiles.cpp` `AddSpectralArrow`, `AddArrow` |
| `OnPlayerCanBlockWithoutShield(player, isHoldingStaff, isUnarmed) -> bool\|nil` | Grant staff/unarmed FastBlock | `Source/items.cpp` `CalcPlrBlockFlag` |
| `OnGetArmorLevelBonus(player, armorType, isUnique) -> int\|nil` | Grant level-scaled `_pIAC` bonus; armorType: `"Light"/"Medium"/"Heavy"` | `Source/items.cpp` `GetPlrAnimArmorId` |
| `OnGetPotionHealAmount(player, l) -> int\|nil` | Override partial potion heal for non-named classes | `Source/player.cpp` `RestorePartialLife` |
| `OnGetPotionManaAmount(player, l) -> int\|nil` | Override partial potion mana for non-named classes | `Source/player.cpp` `RestorePartialMana` |
| `OnPlayerHasArmorPierce(player) -> bool\|nil` | Grant melee armor pierce (−monsterAC/8) | `Source/player.cpp` `CalculateArmorPierce` |
| `OnPlayerCanCleave(player, isAxe, isTwoHandedHeavy, isStaff) -> bool\|nil` | Grant cleave for given weapon state | `Source/player.cpp` `CanCleave` |
| `OnGetHitRecoveryThreshold(player, baseThreshold) -> int\|nil` | Override damage threshold for hit-recovery stagger; Barbarian's `level+level/4` pre-applied | `Source/player.cpp` `StartPlrHit` |
| `OnGetUnarmedDamageFloor(player, minDamage, maxDamage) -> {int,int}\|nil` | Set min/max damage floors when no weapon equipped; return `{newMin, newMax}` table | `Source/items.cpp` `CalcPlrDamage` |
| `OnGetBlockChanceBonus(player, baseBonusFromTsv) -> int\|nil` | Replace TSV `blockBonus` for block-chance calculation; fires on every block roll | `Source/player.cpp` `Player::getBaseToBlock` |
| `OnOilyShrine(player)` (event, no return) | Fires for unrecognised classes at Oily Shrine | `Source/objects.cpp` `OperateShrineOily` |
| `OnShouldExcludeWirtItem(player, itemType) -> bool\|nil` | Return `true` to force reroll; itemType: `"Bow"/"Staff"/"Sword"/"Axe"/"Mace"/"Shield"/"Helm"/"Ring"/"Amulet"/"LightArmor"/"MediumArmor"/"HeavyArmor"` | `Source/items.cpp` `SpawnBoy` |
| `OnGetPlayerArmorGraphic(player, currentGraphic) -> "Light"\|"Medium"\|"Heavy"\|nil` | Override resolved armor sprite tier; cosmetic only | `Source/items.cpp` `GetPlrAnimArmorId` |
| `OnGetPlayerBlockGraphic(player) -> "Hit"\|"Stand"\|nil` | Play the hit-recovery flinch (or Stand) while blocking instead of the block sheet — for sprite sets with no `bl` file for the combo; the `bl` file is then never loaded. Block duration follows the played animation. Must resolve identically on every client | `Source/player.cpp` `LoadPlrGFX` (skip-load gate), `StartPlrBlock`, `Player::getGraphic` (PM_BLOCK restore) |
| `OnGetAnimationSkipFrames(player, animType, currentSkip) -> int\|nil` | Override skipped frames for an animation type; animType: `"Attack"/"RangedAttack"/"Cast"/"Block"/"HitRecovery"` | `Source/player.cpp` `StartAttack`, `StartRangeAttack`, `StartSpell`, `StartPlrHit` |
| `OnGetPlayerIdleFrames(player, weaponGraphic, isInTown) -> int\|nil` | Override `_pNFrames` (idle frame count) for a weapon graphic | `Source/player.cpp` `SetPlrAnims` |
| `OnCustomItemRecreated(item)` (event, no return) | Fires from `RecreateItem` for any `IDidx >= IDI_NUM_DEFAULT_ITEMS`; use to restore display name | `Source/items.cpp` `RecreateItem` |
| `OnItemPickedUp(player, item)` (event, no return) | Fires when a player takes a floor item — into inventory/belt/equipment via auto-pickup (`AutoGetItem`, after successful placement), or into the hand via click-pickup with the inventory panel open (`InvGetItem`, before `CleanupItems`); `item` is the floor copy. The live acquired copy is in inventory (`player:findScrollBySeed(item.seed)`) on the auto path, or on the cursor (`player:heldItem()`) on the click path | `Source/inv.cpp` `AutoGetItem`, `InvGetItem` |
| `OnItemDropped(player, item)` (event, no return) | Fires when the local player manually drops a held item onto the floor, before the cursor item is cleared (`item.modData` still valid); sibling of `OnItemPickedUp` — the trade mechanism. Four sites, one per engine drop path: controller/forced drop, mouse click-on-world drop, close-stash force-drop, and the swap-drop when click-picking a floor item while already holding one | `Source/controls/plrctrls.cpp` `TryDropItem`; `Source/diablo.cpp` `LeftMouseDown`; `Source/inv.cpp` `CloseStash`, `InvGetItem` |
| `OnCreatePlrItems(player)` (event, no return) | Fires inside `InitCursor/FreeCursor` window after standard starting items | `Source/items.cpp` `CreatePlrItems` |
| `OnGolemCanTargetMonster(ally, candidate) -> bool\|nil` | Reject a target for any `MFLAG_GOLEM` monster. Runs once per active monster per ally per tick — gate on distance first, query LOS lazily via `ally:hasLineOfSightTo(candidate)` (LOS is not precomputed in C++). | `Source/monster.cpp` `UpdateEnemy` |
| `OnGolemCanTargetGolem(ally, candidate) -> bool\|nil` | Vanilla unconditionally prevents player-minions from targeting each other (the `prevent golems from fighting each other` continue). This generic call-out lets a mod permit it (e.g. pets of mutually-hostile players). Default **false** = vanilla (no infighting); return `true` to allow. `candidate` is also a player-minion/golem. | `Source/monster.cpp` `UpdateEnemy` |
| `OnGolemCanTargetPlayer(ally, candidate) -> bool\|nil` | Vanilla never lets a player-minion acquire a **player** as its target (`UpdateEnemy`'s player scan skipped all candidates for minions). This generic call-out lets a mod permit it (e.g. a player hostile to the minion's owner). Default **false** = vanilla; return `true` to allow. `candidate` is a **Player**; query LOS lazily via `ally:hasLineOfSightToPlayer(candidate)`. A granted player target rides the existing player-target machinery (`MFLAG_TARGETS_MONSTER` clear, per-tick `enemyPosition` refresh, `MonsterAttackEnemy` → `MonsterAttackPlayer`, `encode_enemy` MP sync), but `GolumAi`'s melee/chase block is **monster-only** — acting on a player target is up to `OnGolemChooseAction` handlers (`ally:startAttack()` when adjacent; the `OnGolemIdle` pursue branch covers the chase). While a player target is held, `UpdateEnemy` re-runs every `GolumAi` tick (vanilla no-monster-target flow), so the grant is re-evaluated continuously and drops as soon as the handler stops approving. | `Source/monster.cpp` `UpdateEnemy` |
| `OnGolemCanChaseTarget(ally, target) -> bool\|nil` | Block the ally from pathing toward its current target this tick; returning `false` also clears `MFLAG_TARGETS_MONSTER` so `UpdateEnemy` re-evaluates on the next tick | `Source/monster.cpp` `GolumAi` |
| `OnGolemCanSelect(monster) -> bool\|nil` | Return `true` to allow cursor selection of a golem. For player minions this hook is checked **before** the `MFLAG_HIDDEN` guard, so cloaked (hidden) allies remain selectable. | `Source/cursor.cpp` `IsValidMonsterForSelection` |
| `OnGolemCanRunAI(monster) -> bool\|nil` | Return `false` to skip this golem's local AI simulation this tick (its mode/animation still advance). Fires only for `MFLAG_GOLEM` monsters; default true = vanilla. **The Hunter mod no longer registers a handler** — allies now run deterministic AI on every client (synced per-monster RNG + owner-anchored hooks), like a vanilla golem. (The hook remains for any modder.) | `Source/monster.cpp` `ProcessMonsters` |
| `OnGolemIdle(ally, hasTarget, enemyPos) -> Point\|false\|nil` | Control idle walk: Point to walk toward, false to stand still, nil for engine default | `Source/monster.cpp` `GolumAi` |
| `OnGolemChooseAction(ally, enemy, enemyPlayer) -> bool\|nil` | Fires before the melee-attack/chase block; `enemy` = the ally's current target Monster, `enemyPlayer` = its current target Player (only ever set when `OnGolemCanTargetPlayer` granted it); at most one is non-nil. Derive distance/LOS from the target (e.g. `ally:hasLineOfSightTo(enemy)` / `ally:hasLineOfSightToPlayer(enemyPlayer)`); return `true` to consume the tick entirely (Lua handles the action); nil/false = engine proceeds normally. The engine block that follows only melees/chases **monster** targets — player-target actions must come from handlers here. | `Source/monster.cpp` `GolumAi` |
| `OnGetCustomSpeedbookScrollEntries(player) -> table\|nil` | Inject custom scroll icons into the speedbook | `Source/panels/spell_list.cpp` `GetSpellListItems` |
| `OnGetSpeedbookSelectionType(player, spellId, originalType, promotedType) -> string\|nil` | Override resolved SpellType after starting-skill promotion | `Source/panels/spell_list.cpp` `GetSpellListSelection` |
| `OnGetSpeedbookSpellName(player, spellId, defaultName) -> string\|nil` | Override the spell display name; fires in two places: `Source/panels/spell_list.cpp` `DrawSpellList` (speedbook hover) and `Source/control/control_infobox.cpp` (main-panel skill-button hover) | both callsites |
| `OnShouldHideSpeedbookSpell(player, spellId, spellType) -> bool\|nil` | Return `true` to hide a speedbook entry; spellType: `"Skill"/"Spell"/"Scroll"/"Charges"` | `Source/panels/spell_list.cpp` `GetSpellListItems` |
| `OnCanSelectSpellBookEntry(player, spellId) -> bool\|nil` | Return `false` to block a learned spell from being set as active cast spell via the spellbook; fires only for `SpellType::Spell` | `Source/panels/spell_book.cpp` `CheckSBook` |
| `OnResolveCustomScrollSlot(player, spellId, selectedSeed, defaultSlot) -> int\|nil` | Resolve which `INVITEM_*` slot a `SpellType::Scroll` cast consumes/deploys from — lets a mod overloading one scroll SpellID across many distinct scrolls cast the exact one selected; return a slot, or nil/`defaultSlot` (0) for vanilla first-match. `selectedSeed` = `Player::selectedCustomScrollSeed` (the picked speedbook entry's seed). Called unconditionally for every scroll cast | `Source/player.cpp` `CheckPlrSpell` |
| `OnCanCastScroll(player, spellId, selectedSeed, target) -> bool\|nil` | Return `false` to veto a scroll cast **before** it is committed or consumed (engine's `addflag=false` / no-op path; the mod handles any "I can't do that" feedback). Fires on **both** cast paths: speedbook/RSpell (`selectedSeed` = `Player::selectedCustomScrollSeed`) and direct inventory/belt use (`selectedSeed` = the used item's `_iSeed`). `target` is the cursor-targeted monster resolved from the raw `pcursmonst` (like `OnCanCastSkill`), **nil** when none — the `CheckPlrSpell` path passes `pcursmonst` (so a handler can reject an offensive scroll aimed at a protected ally); the `UseInvItem` use-gate passes `-1`/nil, since a targeted scroll re-enters `CheckPlrSpell` to pick its victim. | `Source/player.cpp` `CheckPlrSpell` + `Source/inv.cpp` `UseInvItem` |
| `OnCanCastSkill(player, spellId, target) -> bool\|nil` | Return `false` to veto a `SpellType::Skill` cast **before** it is committed (engine's `addflag=false` path; the mod handles any "I can't do that" feedback). `target` is the cursor-targeted monster (`pcursmonst` resolved to a monster object, or nil when none hovered). Lets a mod gate a skill on its target (e.g. the Tame mlvl/category veto). Fires only on the skill path, not learned spells | `Source/player.cpp` `CheckPlrSpell` |
| `OnItemUsed(player, miscId, spellId)` (event, no return) | Fires after any item use; HP/mana already applied | `Source/items.cpp` `UseItem` |
| `OnGetMiscItemDescription(item) -> string\|nil` | Override item info box description | `Source/items.cpp` `PrintItemMisc` |
| `OnPrepareUniqueInfoBox(item) -> bool\|nil` | Fires in `PrintItemDetails` after `curruitem = item` for any `ITEM_QUALITY_UNIQUE` item; call `items.setCustomUniqueBox(name, lines)` to fill the custom slot, then return `true` to redirect `DrawUniqueInfo` to that content instead of `UniqueItems[_iUid]`; nil/false = engine default | `Source/items.cpp` `PrintItemDetails` |
| `OnGolemKilledMonster(ally, victim)` (event, no return) | Fires when any `MFLAG_GOLEM` monster kills another monster. **Two call sites covering both ally damage paths:** melee (`StartDeathFromMonster`) and missiles (the faction branch of `CheckMissileCol` → `MonsterTrapHit`, guarded by `missile.sourceMonster()` + `MFLAG_GOLEM` + `victim.hasNoLife()`). The missile site covers every ranged/special ally attack (arrow, fireball, inferno, lightning, etc.) so kill tracking is attack-path-complete. | `Source/monster.cpp` `StartDeathFromMonster`; `Source/missiles.cpp` `CheckMissileCol` |
| `OnGolemMinionMissileSpawn(ally, speciesTypeId, x, y) -> bool\|nil` | Query, fires only for a golem-sourced spawn missile (e.g. HorkSpawn) when it lands, **before** the engine's default `SpawnMonster`. Return `false` to suppress that spawn at the landing tile so a handler can create the monster itself (the engine spawn uses a level-local type index, wrong for a relocated summoner). `speciesTypeId` = the canonical type the engine would spawn (`MT_HORKSPWN`). Default true = vanilla. (Mod-side detail: `cpp_changes/missiles.md`.) | `Source/missiles.cpp` `ProcessHorkSpawn` |
| `OnGetMonsterInfo(monster) -> table\|nil` | Replace entire `PrintMonstHistory` block; nil = default | `Source/control/control_infobox.cpp` monster info block |
| `OnGetMonsterDisplayName(monster) -> string` | Override the monster name shown in the info box and health bar; Lua nil → default `monster.name()`. C++ passes `monster.name()` as the default so each callsite is a single unconditional replacement. | `Source/control/control_infobox.cpp` `DrawInfoBox`; `Source/qol/monhealthbar.cpp` `DrawMonsterHealthBar` |
| `OnGetMonsterOutlineColor(monster) -> int\|nil` | Return a palette index (0–255) to draw a 1px `ClxDrawOutlineSkipColorZero` outline before the main sprite; nil = no outline. `PAL16_YELLOW+2 = 194` (gold). Also queried in the `MFLAG_HIDDEN` early-return of `DrawMonsterHelper`, so a `>= 0` color outlines a hidden monster (no sprite drawn) — lets cloaked stealth allies show their outline. | `Source/engine/render/scrollrt.cpp` `DrawMonster` + `DrawMonsterHelper` hidden branch |
| `OnGetMonsterTRN(monster) -> handle\|nil` | Return a TRN **handle** (from `monsters.registerTrn`) to override this monster's palette-remap (TRN) for the frame; nil = engine default → vanilla render byte-for-byte. **Ungated**, fires for every monster — sibling of `OnGetMonsterOutlineColor` at the same `DrawMonster` site (hence `Monster`, not `Golem`). The engine resolves the handle to a stored 256-byte buffer via an append-only session registry in `lua_event.cpp` (`RegisterMonsterTRN`, fed by the `registerTrn` binding). Override wins over the unique/petrified/infravision TRN; a monster on an *unlit* tile is drawn with the infravision TRN before the hook fires (early-return). | `Source/engine/render/scrollrt.cpp` `DrawMonster` |
| `OnMonsterCanCompleteQuest(monster) -> bool\|nil` | Return `false` to skip `CheckQuestKill` for a dying monster (e.g. a tamed quest boss dying as a player-minion must not re-trigger its quest / replay the death speech). Return nil/true to allow. Default true = vanilla. | `Source/monster.cpp` `MonsterDeath` |
| `OnDiabloDeathCanKillMonster(monster) -> bool\|nil` | Return `false` to spare a monster from the game-ending level-wide kill (fires once per monster when the sweep runs). Must resolve identically on every client. Default true = vanilla kill. | `Source/monster.cpp` `DiabloDeath` |
| `OnMonsterCanPlaceCorpse(monster) -> bool\|nil` | Return `false` to suppress this monster's corpse placement on its final death frame (the monster still clears its tile and is reaped — it just leaves no floor corpse). Used so tamed allies vanish on death instead of leaving a corpse, which also keeps mod-spawned monsters off the hard-capped 31-slot corpse table (`corpseId` is a 5-bit `dCorpse` field). Thin gate around the existing `AddCorpse`, sibling to `OnMonsterCanCompleteQuest`. Default true = vanilla. | `Source/monster.cpp` `MonsterDeath` (`animInfo.isLastFrame()` branch) |
| `OnMonsterCanEndGame(monster) -> bool\|nil` | Return `false` to skip the **game-ending death sequence** for a dying monster, letting it die like any other monster instead. Two fire sites, both gated on `MT_DIABLO` (the only monster with such a sequence): the death **start** (`MonsterDeath`, gating the `DiabloDeath` call — quest completion, player freeze, level-wide monster kill, camera-pan setup; vetoed, the normal `PlayEffect` death sound plays), and the death **tick** (the per-tick `MonsterDeath(Monster&)` camera-pan/`PrepDoEnding` branch; vetoed, the death animation finishes through the generic last-frame path — corpse hook, tile clear, reap — which vanilla Diablo never reaches). Used so a tamed Diablo dying as an ally gets the standard ally death (resurrect beam, no corpse, no quest clear, game keeps running); a wild Diablo returns nil → full vanilla ending. Default true = vanilla. | `Source/monster.cpp` `MonsterDeath` (death start) + `MonsterDeath(Monster&)` (death tick) |
| `OnMonsterCanShowResistances(monster) -> bool\|nil` | Return `true` to force the monster healthbar's resistance/immunity icon row to render, overriding the vanilla `isUnique() \|\| MonsterKillCounts[type] >= 15` gate. Used so a tamed ally always shows its resistances/immunities (incl. a Bonded-granted immunity) on the healthbar, matching the ally infobox revealing full stats. Thin `\|\|`-on-top of the vanilla gate; default false = vanilla. | `Source/qol/monhealthbar.cpp` `DrawMonsterHealthBar` |
| `OnMissileCanTargetMonster(monster, source) -> bool\|nil` | Pure **targeting** gate (no damage effect): return `false` so an auto-targeting missile does not fire a bolt at this monster. `source` = `Point` origin tile, so the handler can also reject a target standing behind a protected monster. Two call sites, both folded into the existing target-pick `if` via `&&`: the Chain Lightning spread `Crawl` in `ProcessChainLightning`, and the `FindClosest` lambda (Chain Lightning / Lightning bolt bounce, Bone Spirit homing). Default true = vanilla. (Layer rationale + Diablo landmine: `cpp_changes/missiles.md`.) | `Source/missiles.cpp` `ProcessChainLightning` + `FindClosest` |
| `OnPlayerAttackMonster(player, monster) -> bool\|nil` | Return `false` to silently cancel a monster-targeted offensive action on this monster. Covers: left-click melee/ranged attack, the scroll-spell cursor cast, and the readied **staff-charge** right-click cast. `monster` is **nil** when no monster is under the cursor (the staff-charge call resolves the raw `pcursmonst`, which is `-1` for an empty-tile cast) — handlers must nil-check and allow. **Scoped on purpose:** the charge gate lives in the `SpellType::Charges` `addflag` case in `CheckPlrSpell`, *not* the shared spell dispatch, so it never touches beneficial readied skills (`SpellType::Skill`, e.g. Share Potion — gated separately by `OnCanCastSkill`) or scrolls (`OnCanCastScroll`). | `Source/diablo.cpp` `LeftMouseCmd` (3 callsites) + `TryIconCurs`; `Source/player.cpp` `CheckPlrSpell` (`SpellType::Charges` case, via the `int`-target overload) |
| `OnPlayerCanPickUpItem(player, item) -> bool\|nil` | Return `false` to forbid this player from picking up a floor item (e.g. class-restricted items); the pickup silently cancels with no item consumed and no network request sent. Fires on every pickup path before the `CMD_REQUESTGITEM`/`CMD_REQUESTAGITEM` send: walk-up pickup (`destAction` cleared on veto) and Telekinesis. Default true. | `Source/player.cpp` `ACTION_PICKUPITEM` / `ACTION_PICKUPAITEM`; `Source/inv.cpp` `DoTelekinesis` |
| `OnCanAutoRefillBeltItem(player, item) -> bool\|nil` | Return `false` to exempt a belt item from the Auto Refill Belt redirect, so the exact selected belt slot is used instead of being swapped for an identical-looking copy. Needed for seeded/custom items that share `_iMiscId` + `_iSpell` but differ by `_iSeed` (e.g. Tame scrolls — otherwise a belt cast deploys a random scroll). Folded into the existing `autoRefillBelt` guard via one local; default true = vanilla. | `Source/inv.cpp` `UseInvItem` |
| `OnCanSelectMonsterWithCursor(cursorId) -> bool\|nil` | Return `true` to allow `pcursmonst` to be set while cursor is in a player-only state (`CURSOR_HEALOTHER`/`CURSOR_RESURRECT`); compare via `player.CursorID.*` | `Source/cursor.cpp` (2 callsites) |
| `OnCursorMonsterTarget(monster) -> bool\|nil` | Fires when monster clicked while `pcurs == CURSOR_HEALOTHER` and no player is under cursor; return `true` to consume click and reset cursor | `Source/diablo.cpp` `TryIconCurs` |
| `StoreOpened(name)` (event) | Fires when a towner store is opened; `name` is lowercase: `"pepin"`, `"griswold"`, `"wirt"`, etc. | `Source/stores.cpp` |
| `OnMonsterDeath(monster)` (event) | Fires at top of `MonsterDeath()` before HP is zeroed | `Source/monster.cpp` `MonsterDeath` |
| `OnMonsterTakeDamage(monster, damage, damageType)` (event) | Fires when any monster takes damage | `Source/monster.cpp` |
| `OnPlayerTakeDamage(player, damage, damageType)` (event) | Fires when any player takes damage | `Source/player.cpp` |
| `OnPlayerGainExperience(player, exp)` (event) | Fires when a player gains XP | `Source/player.cpp` |
| `OnCalcPlayerResistances(player, fire, lightning, magic)` (event) | Fires in `CalcPlrResistances` right before the `std::clamp` into `_pFireResist`/etc.; forwards the **UNCAPPED** pre-clamp resistance totals (may exceed the 75% display cap). | `Source/items.cpp` `CalcPlrResistances` |
| `OnGolemMissileDamage(golem, missileId, dam) -> dam` (query) | Fires in `AddMissile` after `addFn`, gated to **MFLAG_GOLEM** sources (golem / player-minion missiles only — wild monsters never fire it); return an int to override the missile's final damage (default keeps `dam`). Chokepoint — fires once per missile incl. each spawned segment of multi-tick spells (Inferno/Lightning). Melee never routes here. | `Source/missiles.cpp` `AddMissile` |
| `OnMonsterMissileHit(source, target, missileId, damageType, minDam, maxDam, dist, shifted) -> int` (query) | Fires in `CheckMissileCol` for a missile resolving against a monster, gated to hits where a **MFLAG_GOLEM** monster is on **either end** — the source **or** the target; wild-vs-wild/trap-vs-wild missiles never fire it. `source` may be **null** (e.g. a trap hitting a golem-flagged target). Return **`<0` to decline** (the engine runs its default `MonsterTrapHit(... damageType ...)`, byte-for-byte vanilla), or **fully resolve the hit yourself** — reclassify the element, transiently adjust the target's resistance, then call `target:resolveMissileHit(...)` — and return **`1`/`0`** (hit/miss). Because resolution is one synchronous call, any transient resistance change is set and restored inline (no paired post-event). The mod uses it for immunity-piercing / acid-as-magic, owner XP-tagging (`monster:tagForPlayer`), and Bonded kill-credit. | `Source/missiles.cpp` `CheckMissileCol` |
| `OnGolemMissileCanHitPlayer(golem, player) -> bool\|nil` (query) | Fires in `CheckMissileCol` at the `PlayerMHit` dispatch when a missile resolving against a **player** has a **MFLAG_GOLEM** source (wild-monster missiles never fire it — the gate mirrors `OnMonsterMissileHit`'s minion gate in the same function). `PlayerMHit` itself has **no** faction, ownership, or Friendly-Fire-toggle check — any player in a monster missile's flight path is hit — so this is the veto point. Return **false** to veto: the missile **passes through** the player and keeps flying (the same pass-through the engine gives a friendly player-vs-player missile), so a shot at a hostile player is not eaten by a friendly in the path. Default **true** = vanilla resolution. The mod maps the vanilla player-missile semantics onto pets: never the owner (analogue of the unconditional self-hit exclusion), and `Plr2PlrMHit`'s exact gate (`Friendly Fire` off + friendly-mode owner → no hit) for everyone else. | `Source/missiles.cpp` `CheckMissileCol` |
| `OnPlayerMissileCanHitGolem(player, golem) -> bool\|nil` (query) | The **mirror direction**: fires in `CheckMissileCol` at the `MonsterMHit` dispatch when a **player**-sourced missile resolves against a **MFLAG_GOLEM** monster (wild-monster targets never fire it). `MonsterMHit` has no faction/toggle check either — a player's own bolt crossing their pet's tile damages it — so this is the veto point. Same veto semantics: return **false** and the missile passes through and keeps flying (a spell aimed past the pet still reaches its enemy). Default **true** = vanilla (a vanilla Golem stays hittable, and PvP missiles still damage hostile pets). The mod's policy: `Friendly Fire` off + caster is the pet's owner **or peaceful with the owner** → pass through; FF on or hostility → vanilla. Also lets the `OnMissileCanTargetMonster` handler drop its `friendlyAllyNearPath` collateral-path veto while FF is off (the line is damage-safe, so auto-aim spells keep full reach). | `Source/missiles.cpp` `CheckMissileCol` |
| `OnApocalypseCanTargetGolem(player, golem) -> bool\|nil` (query) | Fires from the **Apocalypse victim scan** when it evaluates a **MFLAG_GOLEM** monster — vanilla `ProcessApocalypse` always skips player-minions (its own `isPlayerMinion` `continue`), so the hook can only ever **widen** the scan, never narrow vanilla. Return **true** to let the caster's Apocalypse drop its boom on this minion; default **false** = the vanilla exclusion. The boom's damage then resolves normally through `CheckMissileCol` → `OnPlayerMissileCanHitGolem` → `MonsterMHit`. The mod's policy mirrors the `OnGolemCanTargetGolem` hostility rule: a **hostile** caster's Apoc may boom another player's tamed ally; own/peaceful pets keep the vanilla protection unconditionally (Apoc can't hit players even when hostile, so peace-time pets stay equally untouchable, independent of Friendly Fire); a vanilla Golem keeps the vanilla exclusion. | `Source/missiles.cpp` `ProcessApocalypse` |
| `OnGolemKillIsPlayerKill(golem, player) -> bool\|nil` (query) | Fires (**MFLAG_GOLEM** sources only) at the two sites a monster's hit can be fatal to a player — the missile `PlayerMHit` dispatch (`CheckMissileCol`) and the melee `MonsterAttackPlayer` damage apply — to classify the resulting death. Vanilla always treats a monster-sourced kill as `DeathReason::MonsterOrTrap` (the victim drops **items**); return **true** to classify it as `DeathReason::Player` instead (the victim drops an **ear**, the PvP death path). Default **false** = vanilla. Engine resolves it into a local `deathReason` (default `MonsterOrTrap`) that's threaded into the existing `ApplyPlrDamage`/`PlayerMHit` `deathReason` argument, so with no mod / a `false` return the death is byte-for-byte vanilla; the ear is always the **victim's own** (`_pName`), so no killer id is plumbed. The mod flips it to a player kill only for a **hostile** owner's tamed pet (a pet is its owner's weapon); own/peaceful/vanilla-Golem sources keep vanilla. Fires on the **victim's** client (the death is decided where `&player == MyPlayer`), where hostility resolves from synced state. | `Source/missiles.cpp` `CheckMissileCol`, `Source/monster.cpp` `MonsterAttackPlayer` |
| `OnSpellCast(player, spellId, spellType, targetMonster, scrollSeed, targetX, targetY)` (event) | Fires at cast initiation (action-handler stage, frame 0), **before** StartSpell validity check; scroll still in inventory when fired | `Source/player.cpp` `DoAction` |
| `OnSpellActionFrame(player, spellId, spellType, targetMonster, scrollSeed, targetX, targetY)` (event) | Fires at mid-animation release frame (`_pSFNum`), **before** `CastSpell`; scroll still in inventory so `scrollSeed` is valid; `targetMonster` is looked up by `dMonster[targetX][targetY]` and may be nil; **prefer this over `OnSpellCast` for spell effects** | `Source/player.cpp` `DoSpell` |
| `GameDrawComplete()` (event) | Fires after all rendering completes, once per frame — **rendering only**; per-tick logic belongs on `GameTick` (a frame is client-local and can span several game ticks during MP catch-up) | render loop |
| `GameTick()` (event) | Fires at the end of each **game-logic tick** (`GameLogic` — after players/monsters/missiles/items are processed), i.e. once per synced simulation step (20/s), including catch-up ticks a render frame can skip. The home for per-tick mod logic; pairs with `system.gameTick()` for interval gating | `Source/diablo.cpp` `GameLogic` |
| `GameStart()` (event) | Fires at the start of a game session | `Source/diablo.cpp` |
| `LoadModsComplete()` (event) | Fires after all mods finish initial loading | `Source/lua/lua_global.cpp` |
| `OnNewCharacter(player)` (event) | Fires once from `CreatePlayer` after `CreatePlrItems` returns; `pCursCels` is null here — **do not call `addScrollByMapping`** | `Source/player.cpp` `CreatePlayer` |
| `OnLevelExit()` (event) | Fires before level saves/unloads; monsters and items still valid; use `currlevel`/`setlevel`/`setlvlnum` globals | level transition code |
| `OnLevelEnter()` (event) | Fires after `LoadGameLevel` + all `InitPlayer` calls complete; use to re-grant skills reset by `InitPlayer` | level transition code |
| `OnSavePlayerData() -> table\|nil` | All handlers run; each may return a sequence table of uint32 values; all results concatenated into a flat array written to `"luamoddata"` MPQ entry; not called if Lua returns empty | `Source/loadsave.cpp` `LuaSavePlayerModData` |
| `OnLoadPlayerData(data)` (event) | Fires with the flat uint32 array `OnSavePlayerData` returned on the last save; not called for saves lacking the `"luamoddata"` entry | `Source/loadsave.cpp` `LuaLoadPlayerModData` |
| `OnItemAllowedInStash(item, default) -> bool\|nil` | Query: return `false` to forbid an item from the stash (covers both manual drag-drop paste and auto-place — the one chokepoint). C++ passes the vanilla value (`_iMiscId != IMISC_ARENAPOT`) as `default`; nil → default (byte-identical vanilla). The mod blocks the Potion of Forgetting + Tame Scrolls (mod items must never ride `stash.sv` into a base-game session). | `Source/qol/stash.cpp` `IsItemAllowedInStash` |
| `OnBeforeSaveHero()` (event) | Fires at the **top** of `pfile_write_hero` (the single MyPlayer-write funnel: SaveGame, MP autosave/level-change, demo — NOT char-create), before the player is serialized. Pairs with `OnAfterSaveHero`. A handler may transiently mutate the local player (e.g. pop a session-only item out of its slot) and MUST undo it in `OnAfterSaveHero` so the change spans only this one synchronous write. (Mechanics: `cpp_changes/items.md`.) | `Source/pfile.cpp` `pfile_write_hero(SaveWriter&,bool)` |
| `OnAfterSaveHero()` (event) | Fires at the **bottom** of the same `pfile_write_hero`. Restore any transient change made in `OnBeforeSaveHero` here. The inventory arrays are untouched between the two hooks (the save only reads them), so a live Item reference held across the pair stays valid. | `Source/pfile.cpp` `pfile_write_hero(SaveWriter&,bool)` |
| `OnVendorWillBuyItem(item, default) -> bool\|nil` | Query: return `false` so a vendor will **not** buy this item from the player (removes it from the buy-from-player list). C++ passes the vanilla buy decision as `default`; nil → default (byte-identical vanilla). Called as the last line of both `SmithWillBuy` and `WitchWillBuy` (Smith's early-returns were folded into a single `rv` with precedence preserved, only to reach the call-out). The mod vetoes selling Tame Scrolls. | `Source/stores.cpp` `SmithWillBuy` + `WitchWillBuy` |
| `NetMessage(senderId, payload)` (event) | Fires when a `CMD_LUAMSG` arrives from another client; `senderId` = the sender's player id, `payload` = the opaque string sent via `system.netSend`. The single generic cross-client pipe — **all** mod net traffic rides it as `"<TAG>\|args"` Lua message *types* (no per-feature `CMD_*`); the engine never interprets the payload. Receivers must level-scope any slot-id payload (see `player:isOnActiveLevel`). (Pipe mechanics: `cpp_changes/net.md`.) | `Source/lua/lua_event.cpp` `NetMessage` ← `OnLuaMessage` (`Source/msg.cpp`) |

---

### Lua-side usage notes

Events fire from `Source/lua/lua_event.cpp`, registered in `assets/lua/devilutionx/events.lua`.

### Data-load events (fire once at startup)
`LoadModsComplete`, `SpellDataLoaded`, `SpellsAssigned`, `PlayerDataLoaded`, `ItemDataLoaded`,
`UniqueItemDataLoaded`, `MonsterDataLoaded`, `UniqueMonsterDataLoaded`.
- **Ordering matters:** `SpellsAssigned` fires right after `SpellDataLoaded`, once the engine has
  assigned runtime IDs to every spell queued via `spells.registerSpell` — read IDs here with
  `spells.getSpellId(name)`. It fires **before** `ItemDataLoaded`/`PlayerDataLoaded`, so the IDs are
  valid when item definitions and the class `starting_loadout.tsv` skill are resolved.

### Lifecycle gotchas
- **`GameStart`** — the Lua runtime **persists across games within one app launch**, and `OnLevelExit`
  does **not** fire on quit-to-menu, so use this to reset live per-game session state (Hunter clears
  `deployedAllies`/`deployedAlliesById` + transient death-FX sets here — otherwise stale entries alias
  new monster slots and corrupt town `dMonster`; see `bugs.md`). Fires **after** player load
  (`OnLoadPlayerData`, `OnCreatePlrItems` have run) — don't wipe state those populate. **Timing
  caveat:** `GameStart` fires *after* `StartGame` (which loads the level), and a frame (+ its
  `GameDrawComplete`) can render against the still-stale set before `GameStart` lands — so it is **not**
  a guaranteed "before the first frame" hook; also guard the per-frame consumer itself.
- **`OnCreatePlrItems` vs `OnNewCharacter`** — add custom starting inventory via `addScrollByMapping` in
  `OnCreatePlrItems` (inside the `InitCursor/FreeCursor` window, `pCursCels` loaded). `OnNewCharacter`
  fires after `FreeCursor()` — `pCursCels` is null, so **never** call `addScrollByMapping`/`addItem`
  there.
- **`OnSpellActionFrame` vs `OnSpellCast`** — prefer `OnSpellActionFrame` for spell *effects*: it fires
  at the mid-animation release frame (syncs effect with animation) with `scrollSeed` still valid.
  `OnSpellCast` fires at cast initiation (before animation).

### Mod-data persistence (Lua side)
- `OnSavePlayerData()` returns a flat sequence of uint32 to persist in the `"luamoddata"` MPQ entry (all
  handlers concatenated; empty/nil contributes nothing; skipped for `gbVanilla` saves). `OnLoadPlayerData(data)`
  receives that sequence on load. **Return `nil` for non-Hunters** so no entry is written and the save
  stays byte-identical to vanilla.
- `OnLoadPlayerData` fires in `pfile_read_player_from_save` (from `NetInit` at `StartGame`) for the
  hero actually being played — **not** during menu hero browsing — so staged state (e.g.
  `pendingAllyRoster`) is reliably the played hero.
- `OnBeforeSaveHero`/`OnAfterSaveHero` bracket the one synchronous hero-file write — transiently mutate
  in the first and undo in the second (Hunter makes the Potion of Forgetting session-only this way; see
  `cpp_changes/items.md`).
- **Hunter save layout** (`init.lua`): five flat sections in one `"luamoddata"` blob, split by `0`
  markers (0 is never a valid seed): (1) `allyKillCounts` pairs, (2) `bondedImmunity` pairs, (3)
  `bondedTrn` pairs, (4) `recoveryRegistry` `(seed,dwBuff,state)` triples, (5) **deployed-ally roster** —
  a count then 10-field records `(id, seed, capturedDifficulty, isMinion, parentId,
  base{minDamage,maxDamage,toHit,armorClass,maxHp})`. Section 5 is written **single-player only** (count
  0 in MP) and consumed by `GameStart`'s `relinkSavedAllies`.

### Custom events
- `events.registerCustom(name)` — register mod-local events.

---

## Hook-support mechanics

These describe how to *use / add* hooks (not engine modifications — those are in
[`cpp_changes/`](cpp_changes/README.md)).

### Adding new events
1. Declare in `Source/lua/lua_event.hpp`
2. Implement in `lua_event.cpp` with `CallLuaEvent(...)` or `CallLuaEventReturn<T>(...)`
3. Register in `assets/lua/devilutionx/events.lua` (fire events = `CreateEvent()`, query events = `CreateQueryEvent()`)

### Speedbook custom entries
`SpellListItem` (`Source/panels/spell_list.hpp`) carries:
- `displayName` — non-empty → replaces "Scroll of X" info-box label with the string as-is
- `customScrollCount` — ≥0 → overrides the inventory count shown in the info box
- `customScrollSeed` — seed of the custom scroll entry (from `CustomSpeedbookEntry::scrollSeed`); `GetSpellListSelection` copies the selected item's value into `Player::selectedCustomScrollSeed` (0 for non-custom selections; `ToggleSpell` clears it so hotkey casts fall back to first-match). Consumed by `OnResolveCustomScrollSlot` / `OnCanCastScroll`.
`SpellTypeName()` helper in `spell_list.cpp` anonymous namespace converts `SpellType` to string for hook boundaries.

### Scroll cast slot resolution (overloaded scroll SpellID)
When many distinct custom scrolls share one SpellID, the engine's default "first matching scroll" can deploy/consume the wrong one. `CheckPlrSpell` replaces the hardcoded `spellFrom = 0` with `lua::OnResolveCustomScrollSlot(...)`, which returns the exact `INVITEM_*` slot the player selected so the deploy (`OnSpellActionFrame` reads `executedSpell.spellFrom`) and `ConsumeScroll` agree. The direct inventory/belt path (`UseInvItem` → `UseItem`) already passes the exact slot, so it only needed the `OnCanCastScroll` veto, not slot resolution.

### InitCursor/FreeCursor window
`pCursCels` (item cursor sprites) is only valid between `InitCursor()` and `FreeCursor()` inside `CreatePlrItems`. Any hook triggering `AutoPlaceItemInInventory` → `GetInventorySize` → `GetInvItemSprite` must fire inside this window. `OnCreatePlrItems` is placed correctly; `OnNewCharacter` is outside it.

### Engine changes beyond thin hooks → `cpp_changes/`
The deeper engine modifications that support these hooks — the generic Lua net pipe, mod-spawn-over-pipe + high-slot allocation, mod-extensible monster arrays, the spawn/delta hygiene fixes, the SP re-link getters, dynamic spell registration, the `item.modData` blob, and the `luamoddata` save slot — are documented (with WHY + vanilla-invariance proofs) in [`cpp_changes/`](cpp_changes/README.md), one doc per engine area. Bindings these add are listed in `lua_api_reference.md`.

### snapToPlayer sequence
Zero dMonster at old/tile/future → `M_ClearSquares` → set all three positions → reset mode to Stand → `changeAnimationData(Stand)` → `occupyTile` → `ChangeLightXY`. (MP behaviour un-vetted — see `development_notes.md`.)

---

## Items API

- `items.addItemData(table[], baseMappingId)` / `items.addItemDataFromTsv(path, baseMappingId)`
- `items.spawnAt(x, y, mappingId, seed, name?, dwBuff?, modData?)` — drops item at nearest free tile and announces it like any dynamically spawned item (`NetSendCmdPItem(CMD_SPAWNITEM)`, the vanilla quest/reward-drop path): in MP, same-level peers spawn a live copy via `SyncDropItem` and **every** client — sender included, via loopback `OnSpawnItem` — registers it in the level delta (dedup built in), so the item replicates and persists with no further calls. Bit 0 of dwBuff must be 0. Optional `modData` is a **binary-safe string blob** set on `item.modData` (use `string.pack`) — local only; the item wire carries no blob (persist it via `setItemDeltaModData` + a mod net message) and no name (a peer's copy is renamed via `OnCustomItemRecreated`)
- `items.addToHealerStock(mappingId, ivalue, seed?, name?, dwBuff?, modData?, magical?)` — inject a custom item into Pepin's buy list at the given shop price; idempotent; call from `StoreOpened("pepin")` so it reappears after purchase. Optional `seed`/`name`/`dwBuff`/`modData` (string blob) stock a per-instance seeded item (e.g. a custom scroll) that round-trips when bought. Optional `magical` sets the stock item's `_iMagical` quality (0=normal, 2=unique) so the bought copy keeps gold/unique presentation — a vendor purchase copies the stock item's fields verbatim and fires no pickup/recreate fixups, so quality must be set here. Source: `Source/lua/modules/items.cpp`
- `items.setItemDeltaModData(level, seed, blob)` / `items.getItemDeltaModData(level, seed) -> string` / `items.currentDeltaLevel() -> integer` — attach/read an optional mod-data blob to an item seed in a level's delta, so a dropped floor item keeps it across a rejoin (clamped 255 bytes, count capped at MAXITEMS). Pass `currentDeltaLevel()` as `level` and broadcast it so peers mirror under the same level. Source: `Source/lua/modules/items.cpp` / `Source/msg.cpp`
- `items.setCustomUniqueBox(name, lines)` — set the title and up to 6 content strings for the Lua-custom unique item info popup; `name` is the title shown where `UIName` normally appears; `lines` is an array of strings replacing the power list; call inside `OnPrepareUniqueInfoBox` before returning `true`; `UITEM_LUA_CUSTOM = 0x7FFF` sentinel used internally
- `items.ItemMiscID` — enum table for misc IDs

### Item Properties

Properties accessible on `Item` references (e.g. from `player:findScrollBySeed`, `OnCustomItemRecreated`, `OnItemPickedUp`):

| Property | Type | Notes |
|---|---|---|
| `item.seed` | uint32 (readonly) | `_iSeed`; unique identifier for custom items |
| `item.buff` | uint32 (read/write) | `dwBuff`; bit 0 must stay 0 (CF_HELLFIRE flag); custom encoding space in bits 1–31 |
| `item.modData` | string (read/write) | `_iModData`; **optional variable-length mod-data blob (binary-safe; use `string.pack`/`string.unpack`); empty for non-mod items; base game never reads it**; NOT in the hero save — persist via `OnSavePlayerData`/`OnLoadPlayerData`; survives a dropped floor item across a rejoin via the level delta (see `items.setItemDeltaModData`); live trades are the mod's own responsibility (e.g. a Lua net message keyed by seed) |
| `item.magical` | int (read/write) | `_iMagical`; 0=Normal 1=Magic 2=Unique; set to 2 for gold-name display |
| `item.miscId` | int (readonly) | `_iMiscId` |
| `item.name` | string (readonly) | display name |
| `item.isValid` | bool (readonly) | whether the slot is occupied |

---

## Spells API

- `spells.registerSpell(name, path, iconName?)` — call from `SpellDataLoaded`; **queues** a spell (does not return an ID). Optional `iconName` sets the speedbook icon (e.g. `"Golem"`, `"HealOther"`, `"Null"`).
- `spells.getSpellId(name)` — returns the runtime SpellID integer assigned to a registered name, or `nil`. Valid from `SpellsAssigned` onward.
- `spells.setSpellIcon(spellId, iconName)` — set a dynamic spell's speedbook icon by ID after assignment.
- **Deterministic dynamic-spell registry (engine):** IDs are assigned after every mod has registered, **sorted by name** from a fixed base (`SpellID::LAST + 1`). This makes a name resolve to the **same ID in Diablo and Hellfire** and regardless of mod load order, so saved skill/scroll bits stay valid across `.sv`↔`.hsv`, and every client running the same mod set derives the same map (the basis for multiplayer agreement — no runtime sync needed). The engine pads `SpellsData` with inert (`bookLevel=staffLevel=-1`) placeholders up to the dynamic range so the save layout is byte-identical to vanilla. **Namespace your names** (`"hunter:tame"`) so spell-adding mods never collide. Ceiling: dynamic IDs occupy the 53–63 region (the 64-bit per-player spell sets), ~11 slots shared across all mods.
- Skills pattern: `manaCost=0`, `bookLevel=-1`, `staffLevel=-1`, `minIntelligence=255`; leave `missiles` empty for Lua-only skills

---

## Player API

### Functions
- `player.self()` — returns the local player
- `player.get(id) -> Player|nil` — returns the player at the given 0-based id, or `nil` if out of range or that player is not active. Use to resolve a monster's owner (`player.get(monster.ownerPlayerId)`) and inspect their `className` / `friendlyMode`.
- `player:isOnActiveLevel() -> boolean` — `true` if this player is on the client's currently-active (rendered) level (thin getter over the engine `Player::isOnActiveLevel()`, handles quest/`setlevel` too). **Level-scope guard for net messages:** monster slot ids are per-level, so before applying a received message that references a slot id, check the *sender* is on your active level — `player.get(senderId):isOnActiveLevel()` — or the slot would alias a different monster locally
- `player:isLevelOwnedByLocalClient() -> boolean` — `true` if the local client is the **owner** of the level this player is on (thin getter over the vanilla `Player::isLevelOwnedByLocalClient()`). The level owner is the only client allowed to allocate a monster slot (`PrepareSpawnSlot` / vanilla `SpawnMonster` gate on it "to prevent desyncs"). Used as the **spawn authority** check: a non-owner deploy routes through the `DR` pipe request so the owner spawns the ally, and minion spawns (Skeleton King / Hork) are performed by the level owner and then replicated over the pipe
- `player.walk_to(x, y)`
- `player.addClassDataFromTsv(path)` — call from `PlayerDataLoaded`
- `player.className` (readonly string) — class name, e.g. `"Hunter"`, `"Warrior"`; safe in any event including `OnNewCharacter`
- `player.friendlyMode` (readonly boolean) — `true` = friendly (non-hostile); `false` = the player has toggled Hostile (PvP enabled toward others). Drives hostility-aware logic (outline color, pet-vs-pet combat, attack/selection gates).
- `player.isHoldingShield` (readonly boolean) — `true` when a shield is equipped in either hand. Used to gate the block-animation redirect (`OnGetPlayerBlockGraphic`) to shieldless combos.

### Properties (readonly)
- `name`, `id`, `position`, `mana`, `maxMana`, `health`, `maxHealth`, `characterLevel`, `lightRadius`, `isMoving`
- `player.id` is the **0-based index into the Players array** — the same scheme as `player.get(id)` and `monster.ownerPlayerId`. Compare `monster.ownerPlayerId == player.self().id` to test "do I own this golem/pet?". (Two `player.id` values can be compared for identity as before.)
- Base stats (readonly, base values only — no equipment): `strength`, `dexterity`, `magic`, `vitality`
- Character-sheet-effective combat stats (readonly, **include equipment** — mirror the numbers shown on the char panel): `armorClass` (= `GetArmor() + characterLevel×2`), `toHit` (ranged-to-hit % when a bow is equipped, else melee), `minDamage`, `maxDamage` (bow halves the strength damage-mod, matching the panel).

### Methods
- `player:addSkill(spellId)` — call from `OnLevelEnter`; `InitPlayer` resets `_pAblSpells` on every level load
- `player:addItem(itemId, count?)`, `player:hasItem(itemId)`, `player:removeItem(itemId, count?)`
- `player:addScrollByMapping(mappingId, seed, name, dwBuff?, modData?) -> boolean` — uses `sendNetworkMessage=false`; mod items must not go through `CMD_CHANGEINVITEMS`. Optional `modData` (string blob) sets the item's mod-data blob (see `item.modData`)
- `player:findScrollSeedOf(spellId) -> uint32|nil`, `player:findScrollBySeed(seed) -> Item|nil`
- `player:heldItem() -> Item|nil` — the item currently held on the cursor (`HoldItem`), or nil when the hand is empty; live reference (mutations stick and ride the later inventory paste). On the click-pickup path (`InvGetItem`) the just-acquired copy is HERE, not in inventory. Deliberately separate from `iterateInventory`/`findScrollBySeed`, which cover inventory+belt only
- `player:findScrollSlotBySeed(seed) -> int|nil` — returns the `INVITEM_*` slot (inventory 7–46, belt 47–54) of the item whose `_iSeed` matches, or nil; pairs with `OnResolveCustomScrollSlot`
- `player:classBaseStats() -> (str, mag, dex, vit: integer)` — returns the class starting base stat values; safe in any event
- `player:resetStats(str, mag, dex, vit: integer)` — atomically resets all four base stats, refunds invested difference to `_pStatPts`, recomputes `_pMaxHPBase`/`_pMaxManaBase` from formula, calls `CalcPlrInv`. Source: `Source/lua/modules/player.cpp`
- `player:iterateInventory(fn)` — fn(item) called for each non-empty InvList + SpdList item; live reference
- `player:say(speechId)`, `player.HeroSpeech` — full HeroSpeech enum table
- `player:enterHealOtherMode()` — sets `pcurs = CURSOR_HEALOTHER`; use in `OnSpellActionFrame` to defer targeting to a cursor click rather than resolving the target immediately
- `player.CursorID` — full `cursor_id` enum table (e.g. `player.CursorID.CURSOR_HEALOTHER`); use to compare `cursorId` args from `OnCanSelectMonsterWithCursor`
- `player:restoreFullLife()`, `player:restoreFullMana()`, `player:addExperience(exp, level?)`
- `player:modifyStat(name, amount)` — increments a base stat; calls `CheckStats` + `CalcPlrInv`
- `player:creditDiabloKill()` — raise this player's `pDiabloKillLevel` to the current game difficulty (idempotent max, never lowers) — the difficulty-unlock credit vanilla grants when Diablo dies (`DiabloDeath`/`PrepDoEnding`). Only meaningful on the local player (hero save-file state). Hunter calls it on the taming client via `checkQuestKill` and on every peer from the `CR` receive (a Diablo capture credits everyone in the game, like the vanilla ending would)

---

## Monster API

### Capacity reservation (load-time)
- `monsters.requestExtraTypes(count)` — reserve `count` extra per-level monster-TYPE slots (base cap `MaxLvlMTypes` = 24). Call at mod load, before any level. Cumulative across mods; unmodded play unchanged.
- `monsters.requestExtraMonsters(count)` — reserve `count` extra live-monster slots (base cap 200). Effective cap clamped to the engine's hard ceiling **252** (the `uint8` enemy-encoding limit). Call at mod load, before any level. Cumulative; unmodded play unchanged. Hunter `init.lua` requests 40 monster slots (4 Hunters × (4 allies + 6 minions)) and 18 type slots (16 ally species + the 2 shared minion species).

### Spawning
- `monsters.addMonsterDataFromTsv(path)`, `monsters.addUniqueMonsterDataFromTsv(path)`
- `monsters.spawnAt(typeId, x, y) -> Monster*` — uses `InitMonsterGFX` (not `InitAllMonsterGFX`) to avoid sprite-sharing crash. **LOCAL-ONLY** (no `NetSendCmdSpawnMonster`)
- `monsters.spawnWithDifficulty(typeId, capturedDifficulty, x, y) -> Monster*` — spawns with difficulty temporarily forced to `capturedDifficulty` (0=Normal,1=Nightmare,2=Hell). **LOCAL-ONLY.** Source: `Source/lua/modules/monsters.cpp`
- `monsters.spawnUniqueAt(uniqueTypeIdx, capturedDifficulty, x, y) -> Monster*` — spawns a named unique monster by index; calls `PrepareUniqueMonst` with frozen difficulty. **LOCAL-ONLY.** Source: `Source/lua/modules/monsters.cpp`
- **These three are LOCAL-ONLY** (they no longer broadcast the spawn). The spawn cmd carries a *level-local* `typeIndex` that is meaningless on a peer whose level lacks the species (→ null-sprite crash, bugs.md). Replicate mod-spawned monsters across clients over the net pipe by **species id** via `netSpawnAt` instead.
- `monsters.netSpawnAt(monsterId, typeId, uniqueTypeIdx, capturedDifficulty, x, y, seed) -> Monster*` — recreate a networked mod-spawned monster at a SPECIFIC slot id, resolving `typeId` (globally stable species) to *this* client's own `LevelMonsterTypes` index (registers the type + loads GFX). `uniqueTypeIdx < 0` = normal monster. No level-owner gate (for receivers). Reuses `InitializeSpawnedMonster` + `EnsureMonsterIndexIsActive`. Source: `Source/lua/modules/monsters.cpp`
- `monsters.aiRandom(n) -> integer` — value in `[0, n)` from the engine global RNG (`GenerateRnd`). During monster AI processing the global RNG is reseeded to each monster's per-monster seed (synced across clients in MP), so a draw made **inside a monster-AI hook** is identical on every client — use instead of Lua `math.random` for any AI decision that must stay in lockstep. Outside AI processing it is just the running global RNG. Source: `Source/lua/modules/monsters.cpp`

### Lookup
- `monsters.getNameByTypeId(typeId) -> string|nil`
- `monsters.getUniqueName(uniqueTypeIdx) -> string|nil` — returns `UniqueMonstersData[idx].mName`
- `monsters.currentDifficulty() -> integer` — returns `sgGameInitInfo.nDifficulty` (0/1/2)
- `monsters.getHovered() -> Monster|nil` — returns the monster currently under the player's cursor (`pcursmonst`), or nil if nothing is hovered; use inside `OnGetMonsterOutlineColor` to switch outline color on hover
- `monsters.fromId(id) -> Monster|nil` — returns the **active** Monster occupying slot `id` (`monster.id`), or nil if no active monster holds that slot. Monster slot ids are stable across a single-player save/load (`LoadMonsters` restores `ActiveMonsters` verbatim), so this is the re-link key for restoring deployed-ally tracking after a SP "Load Game" (see `init.lua` `relinkSavedAllies`). Source: `Source/lua/modules/monsters.cpp`
- `monsters.MissileID` — table of missile ID integer constants: `Arrow`, `Firebolt`, `LightningArrow`, `FireArrow`, `ChargedBolt`, `HolyBolt`, `Fireball`, `HorkSpawn`, `DiabloApocalypseBoom`; use with `monster:startRangedAttack()` / `monster:startSpecialRangedAttack()`
- `monsters.AIID` — table of `MonsterAIID` integer constants exposing the **complete** enum (`Zombie`, `Fat`, `SkeletonMelee`, `SkeletonRanged`, `Scavenger`, `Rhino`, `GoatMelee`, `GoatRanged`, `Fallen`, `Magma`, `SkeletonKing`, `Bat`, `Gargoyle`, `Butcher`, `Succubus`, `Sneak`, `Storm`, `FireMan`, `Gharbad`, `Acid`, `AcidUnique`, `Golem`, `Zhar`, `Snotspill`, `Snake`, `Counselor`, `Mega`, `Diablo`, `Lazarus`, `LazarusSuccubus`, `Lachdanan`, `Warlord`, `FireBat`, `Torchant`, `HorkDemon`, `Lich`, `ArchLich`, `Psychorb`, `Necromorb`, `BoneDemon`); compare against `monster.originalAiId` in `OnGolemChooseAction` handlers. **Must expose every value the mod references** — a missing key is `nil`, and `t[nil] = v` in a table constructor (e.g. `{ [monsters.AIID.Magma] = true }`) raises "table index is nil" at mod-load, aborting the rest of `init.lua`. (This caused five visual/behavior regressions when the table was incomplete — see `bugs.md`.)
- `monsters.getTypeKillCount(typeId) -> integer` — returns `MonsterKillCounts[typeId]`
- `monsters.getTypeHpRange(typeId) -> minHp, maxHp` — difficulty-scaled HP range matching `PrintMonstHistory` thresholds
- `monsters.getTypeResistances(typeId) -> table` — `{ resistMagic, resistFire, resistLightning, immuneMagic, immuneFire, immuneLightning }` at current difficulty (reads the **type base**; for the live value incl. granted immunities read `monster.resistance`)
- `monsters.Resistance` — table of `monster_resistance` bitflag integer constants: `ResistMagic` (1), `ResistFire` (2), `ResistLightning` (4), `ImmuneMagic` (8), `ImmuneFire` (16), `ImmuneLightning` (32), `ImmuneAcid` (128); use to read/compose `monster.resistance` and `monster:setResistance()`
- `monsters.getMissileDamageType(missileId) -> integer` — the `DamageType` of a `MissileID` (e.g. to derive a cast's element). Pair with `monster:naturalRangedMissileId()`
- `monsters.DamageType` — table of `DamageType` integer constants: `Physical` (0), `Fire` (1), `Lightning` (2), `Magic` (3), `Acid` (4)
- `monsters.registerTrn(bytes) -> integer` — register a 256-byte TRN (palette-remap) and return a handle. `bytes` is a 1-based Lua array of 256 color indices (entry `i` is the color every pixel of index `i-1` is drawn as; missing entries default to identity). Call **once at mod load** and reuse the handle; the buffer is copied and kept for the session. Return the handle from an `OnGetMonsterTRN` handler to remap a monster's palette for the frame. **Cross-palette caveat:** indices **0–127 are level-specific** (a different color in each area's `.pal`, and the area color-cycling touches only 1–31) — never use them as TRN targets. Indices **128–255 are the global sprite range**: identical RGB in every area palette (per `palette.h`) and never runtime-cycled, so *any* 128–255 entry is a reliable target (see `trn_palette.md`). Grayscale crypt/cathedral palettes desaturate everything to gray (expected)

### Delta bookkeeping (MP, by slot id — for a client NOT on the level)
- `monsters.recordDeltaKill(level, monsterId, x, y)` — record a monster as **killed** in the given level's MP delta with no live instance (mirrors a networked death record), so the slot is reaped instead of regenerated when this client later loads the level. For **level-natural** monsters; the CR (capture) receiver's off-level branch uses it. SP no-op. Source: `Source/lua/modules/monsters.cpp`
- `monsters.removeDeltaSpawnedMonster(level, monsterId)` — **erase** a dynamically spawned monster from the given level's MP delta (`spawnedMonsters` entry + monster record invalidated) with no live instance. Sibling of `recordDeltaKill` for **spawned** monsters (allies/minions): routine cross-level sync fills position/hp records even on clients that never materialised the slot, and a stale record ghosts (or crashes) their next load. The RM receiver's not-found branch and the ally-death forget use it. SP no-op. Source: `Source/lua/modules/monsters.cpp`

### Monster properties (readonly)
- `id`, `position` (Point with .x/.y), `name`, `health`, `maxHealth`, `isUnique`, `isQuestMonster`, `typeId`, `level`, `isLit`, `hasRangedAttack`
- `monster.level` — the monster's **effective level at the current game difficulty** (`monster.level(sgGameInitInfo.nDifficulty)`), i.e. already includes the Nightmare/Hell boost — not the raw monstdat base level. Used as `mlvl` in the Tame mlvl gate
- `monster.hasNoLife` — `true` when the monster is at 0 hit points (dead or playing its death animation); readonly. Use to suppress per-frame visuals (e.g. the ally outline) on a dying monster
- `monster.isGolem` — `true` when `MFLAG_GOLEM` is set (tamed ally or vanilla Golem spell); readonly
- `monster.ownerPlayerId` — the id of the player that owns this monster, from `goalVar3` (stamped when it becomes a golem/player-minion; the caster becomes owner). Only meaningful when `isGolem` is true. Pair with `player.get()` to find the owner. readonly
- `monster.isHidden` — `true` when `MFLAG_HIDDEN` is set (faded out / invisible, e.g. a cloaked Sneak ally); readonly
- `monster.isActive` — `true` when the monster is awake/activated (`activeForTicks > 0`); readonly. A monster sleeps until the player makes it visible, and the engine's own AI does not run while asleep. Use as a cheap first gate in `OnGolemCanTargetMonster` so an ally never wakes or chases monsters the player has not engaged (rejecting sleeping candidates before any position/LOS work is what keeps the per-tick target scan cheap on populated levels)
- `monster.uniqueType` — index into `UniqueMonstersData`; `-1` if not a named unique
- `monster.originalAiId` — original AI ID from type data before `makeGolem()` overwrote it with `MonsterAIID::Golem`; compare against `monsters.AIID.*` constants
- `monster.minDamage`, `monster.maxDamage`, `monster.armorClass` — the monster's **current** melee min/max damage and AC (the live stat fields, not the type base); readonly. Used by Ally Progression to snapshot a deployed ally's base stats before layering the buff
- `monster.toHit` — the monster's **effective** chance-to-hit at the current difficulty; for a golem/player-minion this is the `golemToHit` value set when it became a golem (`Monster::toHit` returns `golemToHit` for player minions); readonly
- `monster.resistance` — the monster's **live** raw resistance/immunity bitfield; test against `monsters.Resistance.*` flags. Reflects any granted immunity (unlike `monsters.getTypeResistances`, which reads the type base); readonly
- `monster.monsterClass` — the creature class from monstdat as a string: `"Animal"`, `"Demon"`, or `"Undead"`; readonly. Used for the tamed-pet info box "Type" line

### Monster methods
- `monster:makeGolem(ownerId?)` — converts to a golem owned by player `ownerId` (defaults to the local `MyPlayerId`); **must insert into `deployedAllies` BEFORE calling** (UpdateEnemy fires inside and reads the table). Pass an explicit `ownerId` when replaying a remote player's conversion on a peer (net sync) so ownership (`goalVar3`/`ownerPlayerId`) is the *remote* caster, not the local player
- `monster:remove()`, `monster:setHitPoints(hp)`, `monster:snapToPlayer(player)`, `monster:distanceTo(player)`
- `monster:removeAsKilled()` — like `remove()` (silent: no death FX/loot/XP) but records the removal in the MP delta as a **kill** (`delta_kill_monster`: hitPoints 0 at a valid tile) instead of invalidating the delta slot. Use this — not `remove()` — for a **level-natural** (generation-placed) monster, so a client that loads the level later reaps its regenerated copy instead of leaving it as a live **ghost** (and so its slot id frees for reuse). `remove()` stays correct for **dynamically spawned** monsters (allies/minions), which a late joiner should simply skip. Both share the engine helper `RemoveMonsterFromLevel`. Capture/`CR` taming a wild monster uses `removeAsKilled()`; recall/retame/`RM`/level-exit use `remove()`
- `monster:hasLineOfSightTo(other)` — `true` if a clear missile line of sight (`LineClearMovingMissile`) exists between this monster and `other`. Query line of sight lazily (after cheap distance gates) instead of raytracing every candidate — see `OnGolemCanTargetMonster`
- `monster:hasLineOfSightToPlayer(player)` — the Player-typed sibling of `hasLineOfSightTo` (the usertype bindings can't overload on Monster vs Player). Same `LineClearMovingMissile` raytrace, same lazy-query guidance — see `OnGolemCanTargetPlayer`
- `monster:setMaxHitPoints(hp)` — set the monster's **maximum** HP (display value; stored fixed-point). Use to restore a persisted max HP that must stay stable across redeploys, instead of the value re-rolled from the type's range at spawn. The Tame Scroll deploy calls this with the captured `maxHp` so a tamed monster's Max HP never drifts (see `bugs.md` → Max HP fix); Ally Progression also calls it every recalc to apply the **live HP buff** as `base.maxHp + share` (idempotent, never accumulated — current HP is left untouched, the buff is headroom the pet heals into). `setHitPoints` is unclamped against this, so set max first, then current.
- `monster:setMinDamage(v)`, `monster:setMaxDamage(v)`, `monster:setArmorClass(v)` — set the live melee min/max damage and AC (each clamped 0..255, the `uint8_t` field range). Generic thin setters used by Ally Progression to apply the transient stat buff as `base + buff`; never written into the scroll. Like the HP buff (which raises `maxHitPoints`), these are re-derived from `base` on every recalc rather than incremented, so the buff never accumulates
- `monster:setToHit(v)` — set the monster's `golemToHit` (clamped 0..65535). Only affects effective to-hit for a golem/player-minion (where `Monster::toHit` returns `golemToHit`); a tamed ally is always a golem, so this is the ToHit buff channel
- `monster:setResistance(flags)` — set the live raw resistance/immunity bitfield. Compose from `monsters.Resistance.*` (read `monster.resistance`, OR in the new flag, write back). Used to grant a Bonded ally its random immunity; survives a buff recalc (recalc never touches resistance)
- `monster:checkQuestKill()` — run this monster's quest-completion side effects as if it had been killed (quest state + death speech: Skeleton King, Butcher, Gharbad, Zhar, Lazarus→opens Diablo, Warlord; **Diablo** → `Q_DIABLO` done + the local player's difficulty kill credit (`pDiabloKillLevel`), *without* the game-ending sequence — his quest completion lives in `DiabloDeath`, not `CheckQuestKill`, so the binding mirrors just its quest/progress side effects). No-op for non-quest monsters; wraps the engine's `CheckQuestKill`. Call before `remove()` while type/uniqueType are intact
- `monster:startRangedAttack(missileId: integer)` — fire a normal ranged attack of the given `MissileID` at the monster's current target; damage drawn from the monster's natural min/max range; wraps `LuaStartMonsterRangedAttack`
- `monster:startCharge() -> boolean` — start a charge attack toward the monster's current target (charge missile + `MonsterMode::Charge`); returns true if it started; wraps `LuaStartMonsterCharge`
- `monster:startSpecialStand()` — play the monster's special-stand animation facing its current target (no spawn, no hook); wraps `LuaStartMonsterSpecialStand`. (Used as the Skeleton King's cast animation; the skeleton itself is spawned in Lua via `monsters.spawnWithDifficulty` and replicated over the net.)
- `monster:startSpecialRangedAttack(missileId: integer)` — fire a special ranged attack (Special animation + `SpecialRangedAttack` mode) of the given `MissileID` at the current target, e.g. the Hork Demon's `HorkSpawn`; the missile uses `TARGET_PLAYERS` with this monster as source; wraps `LuaStartMonsterSpecialRangedAttack`
- `monster:fireMissileAt(missileId, x, y)` — fire the given `MissileID` from this monster at the target tile (`TARGET_PLAYERS`, this monster as source, damage from its natural min/max range) **without** changing mode/animation — for effects needing extra projectiles beyond the single missile the attack mode fires. Hunter uses it for the tamed Diablo's multi-target Apocalypse spread (`spreadDiabloApocalypse`, fired from `OnGolemMissileDamage` when the primary boom spawns)
- `monster:naturalRangedMissileId() -> integer` — the `MissileID` the monster's **authentic** ranged/special attack would fire, keyed off its type AI (Succubus→BloodStar, Counselor→by intelligence, Mega→Inferno, …), **without** firing it; wraps `LuaGetMonsterNaturalRangedMissile`. The mod composes the actual fire in Lua: read this, then call `startRangedAttack`/`startSpecialRangedAttack` (the ranged-vs-special split is a small Lua table). (Removed: the old `startNaturalRangedAttack` and `spawnSkeletonMinion` bindings — that dispatch/spawn logic now lives in `init.lua`.)
- `monster:castFlashSelf()` — cast a **Flash** burst (the Flash spell's `FlashBottom`+`FlashTop` missile pair) centered on the monster's **own tile**, sourced from the monster (`TARGET_PLAYERS` — ally-safe vs other player-minions via the engine's faction check). Fires immediately, no cast animation. Damage is the engine's native monster-Flash value (`level×2` for the bottom, the natural roll for the top). Implemented entirely in `Source/lua` (no core-engine change). Hunter fires it at the Tamed→Bonded promotion moment as a celebratory burst. Note: like any ally-centered AoE it can hit an **adjacent owner** (deferred friendly-fire class, same as Diablo's Apocalypse)
- `monster:castResurrectBeamSelf()` — play a visual-only `MissileID::ResurrectBeam` centered on the monster's own tile (no damage, no spawn); a usertype binding added for the Pepin recovery FX. Hunter fires it on a dying non-minion ally's final death frame (queued in `OnMonsterDeath`, fired from `OnMonsterCanPlaceCorpse`) so a tamed ally vanishes with a resurrect beam instead of leaving a corpse
- `monster:setLightRadius(radius)` — give this monster a light source of `radius` (the same mechanic 'lighted' unique monsters use, via the engine's `AddLight`), or change its radius if it already has one; `radius <= 0` removes the light. The engine moves the light with the monster automatically (`MonsterWalk`/`SyncLightPosition`) and frees it on death/removal, so no per-frame upkeep is needed. Light is monochrome brightness (no colour in vanilla) — a glowing *presence*. Hunter uses it for the Bonded ally aura glow
- `monster:startAttack()` — trigger the monster's **normal melee attack** (Attack animation + `MonsterMode::MeleeAttack`) against its current enemy target; wraps `LuaStartMonsterAttack` (→ vanilla `StartAttack`). Hit resolution goes through `MonsterAttackEnemy`, which dispatches on `MFLAG_TARGETS_MONSTER` — so it swings correctly at monster **and player** targets. The Hunter mod's player-target `OnGolemChooseAction` handler calls this when adjacent to a hostile player (the engine's golem melee block is monster-only)
- `monster:startSpecialAttack()` — trigger the monster's special melee attack (`MonsterMode::SpecialMeleeAttack`), e.g. the Goat Melee low-HP special; wraps `LuaStartMonsterSpecialAttack`
- `monster:startEating()` — start the eating/corpse-consume animation (`MonsterMode::SpecialMeleeAttack`); wraps `LuaStartMonsterEat` (→ vanilla `StartEating`)
- `monster:startHeal()` — start the self-heal animation (`MonsterMode::Heal`); monster recovers HP per tick while healing; wraps `LuaStartMonsterHeal` (→ vanilla `StartHeal`)
- `monster:startFadeout()` — start the fade-out animation (`MonsterMode::FadeOut`); sets `MFLAG_HIDDEN` when complete; wraps `LuaStartMonsterFadeout` (→ vanilla `StartFadeout`)
- `monster:startFadein()` — start the fade-in animation (`MonsterMode::FadeIn`); clears `MFLAG_HIDDEN` immediately; wraps `LuaStartMonsterFadein` (→ vanilla `StartFadein`)

> **C++ thinning note:** these monster-action bindings forward to thin `Lua`-prefixed wrappers in `monster.cpp` (the underlying engine helpers have internal linkage). The vanilla helpers (`StartAttack`/`StartEating`/`StartHeal`/`StartFadein`/`StartFadeout`/`StartRangedAttack`/`StartRangedSpecialAttack`/`StartSpecialAttack`/`StartSpecialStand`) are left byte-for-byte unchanged in their anonymous namespace.
- `monster:walkToward(x, y)` — attempt to path toward tile (x, y) via `AiPlanPath` (wall-aware routing); falls back to `Walk` in the direct direction if pathing fails
- `monster:findNearbyCorpse() -> Point|nil` — scan up to 4 tiles in each direction for a usable corpse with LOS; returns the tile `Point` or nil

### Point type
- `Point.new(x, y)` — constructor for use in `OnGolemIdle` return values

### makeGolem() internals
`LuaChangeMonsterToGolem(monster, ownerPlayerId)` in `Source/monster.cpp`: sets `MFLAG_GOLEM`, clears `MFLAG_TARGETS_MONSTER|MFLAG_NO_ENEMY|MFLAG_SEARCH`, sets `monster.ai = MonsterAIID::Golem`, stores `ownerPlayerId` in `goalVar3` (the `makeGolem` binding defaults this to `MyPlayerId`), calls `UpdateEnemy`.

### sol2 const gotcha
Events fire with `const Monster*`. Mutating methods on stored monster references must accept `const Monster&` + `const_cast` internally — sol2 wraps stored refs as const and silently fails otherwise.

---

## Data File System

TSV files, tab-delimited. Mods ship TSVs in `mods/<modname>/txtdata/`.

- **Class**: `player.addClassDataFromTsv(path)` in `PlayerDataLoaded`; per-class folder: `attributes.tsv`, `starting_loadout.tsv`, `animations.tsv`, `sounds.tsv`, `sprites.tsv`
- `starting_loadout.tsv` key fields: `skill` (dynamic name — namespaced, e.g. `hunter:tame`), `spell`, `spellLevel`, `item0..4`, `gold`. Resolved at `PlayerDataLoaded`, after spell IDs are assigned.
- **Spell/skill**: `spells.registerSpell(name, path, iconName?)` in `SpellDataLoaded`; read the assigned ID via `spells.getSpellId(name)` in `SpellsAssigned`
- See `assets/txtdata/classes/sorcerer/` for template

---

## TSV-Controlled Values (no C++ changes needed)

- Base melee/ranged/magic to-hit — set in `attributes.tsv`
- Base block chance — set in `attributes.tsv` (Hunter: 10); `OnGetBlockChanceBonus` overrides per archetype (Warrior/Barb → 30, Monk → 25, Rogue → 20)
- Hunter ranged to-hit: 70 (same as Rogue); block: 20; melee: 50
- Hit recovery animation speed — controlled by `animations.tsv` (Hunter uses Warrior sprites)

---

## Other Class Mechanics Reference

Useful when implementing archetype hooks — these are the existing class formulas Hunter adapts:

- **Warrior/Barbarian**: Critical strike (50% chance to 2× dmg if `rand(100) < level`); `_pDamageMod` = `strMod / 100`; potions 2× heal
- **Rogue**: `_pDamageMod` = `strDexMod / 200`; full bow `_pDamageMod` (others get half); arrow velocity bonus; potions 1.5× heal
- **Barbarian**: `_pDamageMod` = `strMod / 75` (axe/mace) + `level * VIT / 100`; iron skin `+level/4` AC; natural resistances `+level`; melee armor pierce (`−monsterAC/8`); cleave with axe/2H mace; Rage spell exclusive
- **Bard**: `_pDamageMod` = `strDexMod / 150` (sword); dual-wield swords/maces; cleave = dual swords
- **Monk**: `_pDamageMod` = `strDexMod / 150` (staff/unarmed) or `strDexMod / 300`; block with staff/unarmed; level-scaled armor AC; cleave with staff; 25% mana cost reduction; 2× heal spell
- **Adjacent/cleave damage**: always reduced 75% (`dam >>= 2`); to-hit penalty `−30` if level > 20, else `−(35−level)*2` (`Source/player.cpp` ~539)
- **Elixir use check** (`Source/items.cpp` ~2054): Diablo mode skips stat-cap check entirely; Hellfire gates elixir use on `GetMaximumAttributeValue`. Hunter's `OnCanPlayerUseItem` veto fires after this.
- **Monster-owned missile GFX are lazy-loaded** — see `cpp_changes/missiles.md` for the deploy-flow constraint + crash hazard (Acid/Magma/etc. sprites skipped by `InitMissileGFX`, loaded by `InitMonsterGFX`).

---

## Not Hooked / Not Applicable for Hunter

- `DualWield` classFlag — not planned
- 2H weapon in one hand (`player.h GetItemLocation`) — Hunter won't utilize
- Corpse item drop type (`objects.cpp:2142`) — cosmetic, omitted
- `TrapSense` classFlag — can add to TSV for flavor; no hook needed
- Item generation filter (`items.cpp:4618`) — **hooked** via `OnShouldExcludeWirtItem`
## Reference Examples

- `assets/lua/mods/adria_refills_mana/init.lua` — simplest event hook example
- `assets/lua/mods/Floating Numbers - Damage/init.lua` — more complex, multiple modules
- `mods/Hellfire/lua/mods/Hellfire/init.lua` — mod with data overrides
- Golem AI (`SpellID::Golem`) and Berserk (`SpellID::Berserk`) in `Source/monster.cpp` — ally monster precedents
