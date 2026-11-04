# Engine Changes (`cpp_changes/`)

Every change to **base-engine** code (anything outside `Source/lua/`) that is more than a thin
`lua::OnXxx()` hook call-out — refactors made to reach a hook, new engine primitives, struct / array /
protocol changes — documented with its **WHY** and its **vanilla-invariance proof**. This is the
material for eventually contributing the *generic* engine changes back to DevilutionX upstream, and for
internal PR review of the MonsterTamer branch.

The thin hook **catalog** (signature + fire site + purpose) lives in `../lua_api_reference.md`. This
folder is for the cases where reaching or supporting a hook required real engine work — the catalog
points here for the detail.

## Scope rule
Only **generic, mod-agnostic** engine changes are PR candidates — never Hunter mechanics. Each entry
reads as "a feature any modder could use," matching the C++ Hook Philosophy in `CLAUDE.md`. Mod-specific
logic stays in Lua and is out of scope.

## Provenance basis
`MonsterTamer` merges `master` (synced with diasurgical upstream) rather than rebasing, so "ours" =
`git diff master MonsterTamer -- . ':!assets/lua/mods'` and "upstream" = whatever `master` has.
**Always re-derive** with `git diff` / `git show master:<path>` rather than trusting memory — both
branches move.

## Branches and PR plan
- **`MonsterTamer`** — the full test branch (engine + mods). Never PR'd directly.
- **PR branches** — cut from `master`, engine only: nothing under `assets/lua/mods/`. Each must build
  on its own against `master`.
  - **`luanet-hooks`** — the generic net pipe (`net.md` §"The generic Lua net pipe") +
    `system.isMultiplayer`. First upstream PR; description drafted. Its doc links LuaNet at
    `assets/lua/mods/luanet` on the `MonsterTamer` branch.
  - **`lua-stash-hooks`** — mod-registered stashes (`devilutionx.stash`, `GetActiveStash`, mod stash
    files), the `OnItemAllowedInStash` query hook, `CreateQueryEvent`, and the towner dialog-option
    placement fix. Self-contained on master. **Ordering:** the later `item.modData` PR must add
    "mod stashes save each item's `modData`" (an extra `sp/mpstashmoddata` entry in the mod stash file —
    on `MonsterTamer` already, cut from this branch because master has no `_iModData`). When splitting
    `lua-mod-hooks`, drop its copies of `OnItemAllowedInStash` + `CreateQueryEvent` (or stack on this branch).
  - **`lua-mod-hooks`** — the old single catch-all branch; **retired** (every piece is assigned in the
    split below). Safe to delete.
- **The split (decided 2026-11-03).** Each branch lives in its own worktree under
  `C:\Users\ndw19\source\Repos\devx-prs\<branch>`. A branch goes straight onto `master` unless it
  needs code from another open PR. Branches that depend on an unmerged PR are **held** (not cut)
  until that PR is merged. Every API follows upstream's current conventions (e.g.
  `XDataLoaded` + `addXDataFromTsv(path)` with the `id` column naming rows).
  - **Cut, ready to push** (independent of `master`):
    - `lua-text-prompt` — `system.promptText` + `control_text_prompt`.
    - `lua-spell-registry` — `SpellDataLoaded`/`SpellsAssigned`, `spells.addSpellDataFromTsv`,
      deterministic IDs, mod spell icons, the `InitNewSpell` bound, spell-before-player reload order.
    - `lua-class-registration` — `PlayerDataLoaded` + `player.addClassDataFromTsv`.
    - `lua-custom-items` — per-instance support for TSV-registered items: the mod-item name gate in
      `GetTranslatedItemName`, `OnCustomItemRecreated` (+ dwBuff kept), `OnItemUsed`, `items.spawnAt`,
      `items.addToHealerStock`. The `modData` arguments are left out; the item-modData PR appends them as
      the **last** argument (MonsterTamer already uses that order).
    - `lua-player-bindings` (bindings and plain `CreateEvent` events only) — player
      properties `strength` / `magic` / `dexterity` / `vitality` / `magicCurrent` / `health` / `maxHealth` /
      `armorClass` / `toHit` / `minDamage` / `maxDamage` / `lightRadius` / `friendlyMode` / `isMoving` /
      `isHoldingShield` / `weaponGraphic` / `readySpellId` / `readySpellType` / `className` /
      `classBaseStats` / `statPoints` / `heldItem`; `player.get`, `iterateInventory`, `modifyStat`,
      `resetStats`, `addSkill`, `say` + `player.HeroSpeech`, `enterHealOtherMode`; `system.isHellfire`,
      `system.isFriendlyFireEnabled`; the render module additions (`string_width`, `mouse_position`, the
      `string` change); events `OnNewCharacter`, `OnCreatePlrItems`, `OnCalcPlayerResistances`.
  - **Held: stack on `lua-stash-hooks`** (they need its `CreateQueryEvent`):
    - `lua-item-rules` — `OnCanPlayerUseItem`, `OnPlayerCanPickUpItem`, `OnPlayerCanCutInvItem`,
      `OnCanAutoRefillBeltItem`, `OnVendorWillBuyItem`, `OnShouldExcludeWirtItem`, `OnOilyShrine`.
    - `lua-monster-display` — `OnGetMonsterDisplayName`, `OnGetMonsterInfo`, `OnGetMonsterOutlineColor`,
      `OnMonsterCanShowResistances`, and TRN:
      `OnGetMonsterTRN` (draw-time hook in `scrollrt.cpp`), the `RegisterMonsterTRN` handle store
      (`lua_event.cpp`) and `monsters.registerTrn` (lives in the monsters module but belongs here, not
      to the spawning chain). Player TRNs need nothing: upstream's class `sprites.tsv` `trn` column.
    - `lua-speedbook-casting` — mod speedbook entries (`OnGetCustomSpeedbookScrollEntries`,
      `OnGetSpeedbookSelectionType`, `OnGetSpeedbookSpellName`, `OnShouldHideSpeedbookSpell`,
      `OnCanSelectSpellBookEntry`), scroll-slot resolution (`OnResolveCustomScrollSlot`), cast gates
      (`OnCanCastScroll`, `OnCanCastSkill`), `OnSpellCast`/`OnSpellActionFrame` (these also want
      `lua-spell-registry`), and the scroll
      bindings `player.selectedScrollSeed`, `findScrollBySeed` / `findScrollSeedOf` /
      `findScrollSlotBySeed`, `addScrollByMapping`.
    - `lua-item-moddata` — `item.modData`, delta/save persistence, mod stashes saving modData;
      `items.setItemDeltaModData` / `getItemDeltaModData` / `currentDeltaLevel` / `findFloorItemBySeed`,
      `OnItemPickedUp` / `OnItemDropped`, and the hero save slot: `OnSavePlayerData` / `OnLoadPlayerData`
      + `OnBeforeSaveHero` / `OnAfterSaveHero` (the `luamoddata` entry). Engine side:
      `LuaSetItemDeltaModData` / `LuaGetItemDeltaModData` / `LuaCurrentDeltaLevel` (`msg.cpp`),
      `LuaSavePlayerModData` / `LuaLoadPlayerModData` (`loadsave.cpp`).
    - `lua-player-hooks` — player query hooks: `OnGetAnimationSkipFrames`, `OnGetPlayerIdleFrames`,
      `OnGetPlayerArmorGraphic`, `OnGetPlayerBlockGraphic`, `OnGetMaxAttributeValue`.
    - `lua-monster-capacity` — `requestExtraMonsters` / `requestExtraTypes`: arrays sized to the 252
      ceiling, `GetMaxMonsters()` / `GetMaxLvlMTypes()` at every bound, the extended-slot delta-load
      gate. Engine-only otherwise.
  - `lua-monster-bindings` (`master`'s Monster type only has `position` / `id`) —
    read/write monster API: `typeId`, `name`, `health` / `maxHealth` + `setHitPoints` / `setMaxHitPoints`,
    `isUnique`, `uniqueType`, `isQuestMonster`, `level`, `minDamage` / `maxDamage` / `armorClass` /
    `toHit` / `resistance` + `setMinDamage` / `setMaxDamage` / `setArmorClass` /
    `setResistance`, `isLit`, `hasNoLife`, `isActive`, `monsterClass`, `isHidden`,
    `hasRangedAttack`, `distanceTo`, `hasLineOfSightTo` / `hasLineOfSightToPlayer`; module functions
    `getNameByTypeId`, `getTypeKillCount`, `getTypeHpRange`, `getTypeResistances`, `getHovered`; the
    `monsters.Resistance` table; the `Point` usertype (`x` / `y` / `Point.new`, registered in the
    monsters module). `getHovered` checks `pcursmonst == -1` like the engine, so it needs no capacity
    bound.
  - **Held: stack on `lua-monster-capacity`:** `lua-monster-spawning` — spawn bindings
    (`spawnAt` / `spawnWithDifficulty` / `spawnUniqueAt` / `netSpawnAt`, `currentDifficulty`,
    `getUniqueName`, `recordDeltaKill`, `removeDeltaSpawnedMonster`), high-slot allocation, the
    delta helpers (`LuaDeltaRemoveSpawnedMonster` ×2, `LuaDeltaKillMonster`), `monster.index` +
    `monsters.fromId`, `remove` / `removeAsKilled`, the `PlaceGroup` underflow clamp, the extended-slot
    `InitializeSpawnedMonster` assert, `OnMonsterDeath` / `OnLevelEnter` / `OnLevelExit` / `GameTick` +
    `system.gameTick`, `player.index`, `player.isOnActiveLevel` / `isLevelOwnedByLocalClient`. Design settled: mod spawns stay local + replayed by species over the mod's own
    transport, because `CMD_SPAWNMONSTER` carries a level-local type index (no species / difficulty /
    unique) and changing that struct would change the protocol. Upstream's `monster.id` / `player.id`
    stay as they are (address-derived; Floating Numbers relies on monster and player ids never
    colliding); the slot is the new `index` property (MonsterTamer + Hunter moved onto it 2026-11-03).
  - **Held: stack on `lua-monster-spawning`:** `lua-monsters-in-town` (nothing on `master` can put a
    monster in town; `IsTownerIndex` separates towners from monsters wherever town code reads
    `dMonster`), then:
    - `lua-player-minions` — owner/golem primitives (`makeGolem`, `isGolem`, `ownerPlayerId`,
      `originalAiId` + the `monsters.AIID` table, `tagForPlayer`, `snapToPlayer`, `checkQuestKill`,
      `setToHit` — it writes `golemToHit`, which `Monster::toHit` reads only for player minions), `OnGolemCanSelect`, `OnGolemCanRunAI`,
      `OnMonsterCanCompleteQuest`, `OnMonsterCanPlaceCorpse`, `OnMonsterCanEndGame`, `OnDiabloDeathCanKillMonster`,
      `player.creditDiabloKill`, `OnCanSelectMonsterWithCursor` / `OnCursorMonsterTarget` +
      `player.CursorID`, `OnPlayerAttackMonster` (×2).
    - `lua-minion-combat` — `OnGolemCanTargetMonster`, `OnGolemCanTargetGolem`, `OnGolemCanTargetPlayer`,
      `OnGolemCanChaseTarget`, `OnGolemIdle`, `OnGolemChooseAction`, `OnMissileCanTargetMonster`,
      `OnGolemMissileCanHitPlayer`, `OnGolemMissileCanHitGolem`,
      `OnPlayerMissileCanHitGolem`, `OnApocalypseCanTargetGolem`, `OnGuardianCanTargetGolem`,
      `OnGolemMissileDamage`, `OnGolemMeleeHitChance`, `OnGolemMissileHitChance`, `OnMonsterMissileHit`,
      `OnGolemKilledMonster`, `OnGolemKillIsPlayerKill`, `OnGolemMinionMissileSpawn`; the AI action
      bindings `startAttack` / `startRangedAttack` / `startCharge` / `startSpecialAttack` /
      `startSpecialStand` / `startSpecialRangedAttack` / `startHeal` / `startEating` / `startFadeout` /
      `startFadein`, `walkToward`, `fireMissileAt`, `naturalRangedMissileId`, `castFlashSelf`,
      `castResurrectBeamSelf`, `setLightRadius`, `findNearbyCorpse`, `encodedEnemy` / `setEncodedEnemy`,
      `resolveMissileHit`, `aiRandom`, `monsters.getMissileDamageType` + the `monsters.MissileID` /
      `monsters.DamageType` tables (their only inputs/consumers are the bindings above). Engine side (`monster.cpp/.h`): `LuaStartMonsterAttack`,
      `LuaStartMonsterRangedAttack`, `LuaStartMonsterCharge`, `LuaStartMonsterSpecialAttack`,
      `LuaStartMonsterSpecialStand`, `LuaStartMonsterSpecialRangedAttack`, `LuaStartMonsterHeal`,
      `LuaStartMonsterEat`, `LuaStartMonsterFadeout`, `LuaStartMonsterFadein`, `LuaMonsterPlanPath`,
      `LuaMonsterFindCorpse`, `LuaGetMonsterNaturalRangedMissile`.
  - **Class mechanics → class flags (two PRs).**
    - `class-flags` (**cut 2026-11-03**, commits `c8ea75da3` + `9c8af9406`, no Lua; `getClassFlags()` is a plain inline
      there): the remaining hardcoded per-class mechanics become
      `PlayerClassFlag` values set in each class's `attributes.tsv` — `ShieldlessBlock`, `ArmorPierce`,
      `StaggerResistance`, `UnarmedMastery`, `LightArmorMastery`, `BowMastery`, `BowTraining`,
      `StaffCleave`, `HeavyCleave`, `DualSwordCleave` (upstream already did `CriticalStrike` / `IronSkin` /
      `NaturalResistance` this way). The enum widens to `uint16_t` and is parsed with explicit compares
      (the `magic_enum` range override can't reach the high bits). Each check keeps the vanilla
      formula; the shipped TSVs carry each class's flags, so behaviour is unchanged. `CanCleave` and
      `CalculateArmorPierce` stay inline in `player.h`.
    - `lua-class-flags` (held on `class-flags` + `lua-stash-hooks` for `CreateQueryEvent`):
      `Player::getClassFlags()` = TSV flags through `OnGetPlayerClassFlags`, every flag check calls it,
      plus the `player.ClassFlag` table. Replaces eleven boolean/numeric hooks. The numeric
      `OnGetPlayerDamageMod` / `OnGetBlockChanceBonus` / `OnGetManaCost` stay (the Hunter takes the
      best of several formulas) and go in this PR too; `Player::getBaseToBlock()` moves out of line to
      call `OnGetBlockChanceBonus`.
  - **Coverage (audited 2026-11-03):** every addition on `MonsterTamer` beyond `master` is assigned above —
    checked hook-by-hook (`lua_event.hpp`), binding-by-binding (player / monsters / items / system /
    render modules), constant-table- and usertype-by-name (`table["X"] =`, `new_usertype<X>`, matched
    case-sensitively — this pass caught `Point`, `Resistance`, `MissileID`, `DamageType` on 2026-11-03)
    and hunk-by-hunk (every non-Lua engine file, by enclosing function). `lua-mod-hooks`
    is retired. Re-run the same four passes after any new engine work.
  - **Held: stack on `lua-stash-hooks`:** `lua-item-descriptions` — `OnGetMiscItemDescription` and the
    custom unique infobox (`OnPrepareUniqueInfoBox` + `items.setCustomUniqueBox` → `SetLuaUniqueInfoBox`), both query events.
  - **Not carried:** the yuripourre framework (Lua-table item definitions, custom cursor sprites) and
    `skipSpeedbook`. Upstream's `addItemDataFromTsv` covers registration (the Hunter's items are
    `itemdat_hunter.tsv`), the Hunter uses vanilla cursors, and `OnShouldHideSpeedbookSpell` hides a
    mod scroll's generic speedbook icon. The speedbook PR's hide hook also fires in `DoSpeedBook`, so
    the cursor jump matches the drawn list.
- Building a PR branch: take `MonsterTamer`'s versions of the engine files onto a branch from `master`,
  then strip what belongs elsewhere. Formatting churn (e.g. `[] {}` → `[] { }` from a different
  clang-format) never goes into a PR branch.

## Status board (checked against `origin` 2026-11-03)

| # | Branch | State | Waits on |
|---|---|---|---|
| 1 | `luanet-hooks` | **pushed** | — |
| 2 | `lua-stash-hooks` | **pushed** | — |
| 3 | `lua-text-prompt` | **pushed** | — |
| 4 | `lua-spell-registry` | **pushed** | — |
| 5 | `lua-class-registration` | **merged** upstream (`ea7b5be46`) | — |
| 6 | `lua-custom-items` | **pushed** | — |
| 7 | `lua-monster-capacity` | **pushed** | — |
| 8 | `class-flags` | **pushed** (tip `30c993b53`) | — |
| 9 | `lua-player-bindings` | **pushed** (tip `236b3798c`, rebased onto `ea7b5be46`) | — |
| 10 | `lua-monster-bindings` | **cut, not pushed** | — |
| 11 | `lua-item-rules` | not cut | #2 merged |
| 12 | `lua-item-moddata` | not cut | #2 merged |
| 13 | `lua-item-descriptions` | not cut | #2 merged |
| 14 | `lua-monster-display` | not cut | #2 merged |
| 15 | `lua-player-hooks` | not cut | #2 merged |
| 16 | `lua-speedbook-casting` | not cut | #2 + #4 merged |
| 17 | `lua-class-flags` | not cut | #2 + #8 merged |
| 18 | `lua-monster-spawning` | not cut | #7 merged |
| 19 | `lua-monsters-in-town` | not cut | #18 merged |
| 20 | `lua-player-minions` | not cut | #19 merged |
| 21 | `lua-minion-combat` | not cut | #20 merged |

Cut-but-unpushed: #10. **Cross-PR follow-up:** #9's `minDamage` / `maxDamage`
mirror `master`'s character panel (`_pClass != HeroClass::Rogue`); whichever of #8 / #9 merges second
switches them to `HasNoneOf(getClassFlags(), PlayerClassFlag::BowMastery)` (MonsterTamer already does). `lua-mod-hooks` is the retired catch-all (local only, delete).

**Completeness check (re-run after any engine change):** collect every name `MonsterTamer` adds beyond
`master` — hooks (`lua_event.hpp`), events (`events.lua`), Lua bindings and tables (every
`Source/lua/modules` file), and functions declared in non-Lua engine headers — and flag any that appear
neither in this README nor in a pushed branch's `git diff master...<branch>`. Last run 2026-11-03: 359
names, 0 unassigned. Also re-check the per-hunk pass (every non-Lua engine hunk, by enclosing
function) when engine code is added without a new hook or header name.

## Files
| Doc | Area |
|---|---|
| `spells.md` | Dynamic spell registration. |
| `net.md` | The generic Lua net pipe, mod-spawn-over-pipe, high-slot allocation, mod-extensible monster arrays. |
| `items.md` | The `item.modData` blob, the `luamoddata` save slot, save-bracket hooks, `OnItemDropped`. |
| `monsters.md` | `LuaChangeMonsterToGolem` owner param, spawn/delta hygiene fixes, the SP re-link getters, corpse/cap notes. |
| `missiles.md` | Targeting-veto sites, `ProcessHorkSpawn` gate, the missile-resolution hook. |

## Per-entry template
```
## <Feature> — status: <draft | ready | landed>
**One-liner:** <what it adds, generically>
**Files (engine):** <non-Lua files touched + ours/upstream>
**Vanilla-logic changes:** <lines that modify shipped behaviour, or "none — additive only">
**No-op-when-unused invariant:** <why base game is byte-identical when the feature isn't exercised>
**Why it can't be pure Lua:** <the irreducible C++>
**Reviewer questions to preempt:** <...>
**Commit structure:** <...>
```

## Classification principle
Keep a single engine *action primitive* rather than decomposing it into many raw-internal setters when
it is branch-free, mod-agnostic, and atomically initializes engine-internal state (canonical:
`LuaChangeMonsterToGolem`). Project line: *gameplay composition* → Lua; *atomic engine-state ops* → thin
`Lua`-prefixed engine primitives. Separate **our** Hunter-authored surface from the **shared upstream
framework** cherry-picked from yuripourre/DevilutionX `lua-custom-items` (custom items/cursors) — ours →
`Lua`-prefix; imported framework + any refactor the base engine depends on at default → keep upstream
name.
