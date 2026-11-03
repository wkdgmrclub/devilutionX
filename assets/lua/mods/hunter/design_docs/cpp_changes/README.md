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
  - **`lua-mod-hooks`** — the old single catch-all branch; **superseded** by the split below. Kept
    only as a reference until every piece has its own branch.
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
  - **Held: stack on `lua-stash-hooks`** (they need its `CreateQueryEvent`):
    - `lua-item-rules` — `OnCanPlayerUseItem`, `OnPlayerCanPickUpItem`, `OnPlayerCanCutInvItem`,
      `OnCanAutoRefillBeltItem`, `OnVendorWillBuyItem`, `OnShouldExcludeWirtItem`, `OnOilyShrine`.
    - `lua-monster-display` — monster display name / info / outline / TRN / show-resistances.
    - `lua-speedbook-casting` — mod speedbook entries, scroll-slot resolution, cast gates,
      `OnSpellCast`/`OnSpellActionFrame` (these also want `lua-spell-registry`).
    - `lua-item-moddata` — `item.modData`, delta/save persistence, mod stashes saving modData.
    - `lua-monster-capacity` — `requestExtraMonsters` / `requestExtraTypes`: arrays sized to the 252
      ceiling, `GetMaxMonsters()` / `GetMaxLvlMTypes()` at every bound, the extended-slot delta-load
      gate. Engine-only otherwise.
  - **Held: stack on `lua-monster-capacity`:** `lua-monster-spawning` — spawn bindings
    (`spawnAt` / `spawnWithDifficulty` / `spawnUniqueAt` / `netSpawnAt`), high-slot allocation, the
    delta helpers (`LuaDeltaRemoveSpawnedMonster` ×2, `LuaDeltaKillMonster`), `monster.index` +
    `monsters.fromId`, `remove` / `removeAsKilled`, the `PlaceGroup` underflow clamp, the extended-slot
    `InitializeSpawnedMonster` assert, `OnMonsterDeath` / `OnLevelEnter` / `OnLevelExit` / `GameTick` +
    `system.gameTick`. Design settled: mod spawns stay local + replayed by species over the mod's own
    transport, because `CMD_SPAWNMONSTER` carries a level-local type index (no species / difficulty /
    unique) and changing that struct would change the protocol. Upstream's `monster.id` / `player.id`
    stay as they are (address-derived; Floating Numbers relies on monster and player ids never
    colliding); the slot is the new `index` property (MonsterTamer + Hunter moved onto it 2026-11-03).
  - **Held: stack on `lua-monster-spawning`:** `lua-monsters-in-town` (nothing on `master` can put a
    monster in town), `lua-player-minions` → `lua-minion-combat`.
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
      `OnGetPlayerDamageMod` / `OnGetBlockChanceBonus` stay (the Hunter takes the best of several
      formulas) and go in this PR too.
  - **Held: stack on `lua-stash-hooks`:** `lua-item-descriptions` — `OnGetMiscItemDescription` and the
    custom unique infobox (`OnPrepareUniqueInfoBox` + `items.setCustomUniqueBox`), both query events.
  - **Not carried:** the yuripourre framework (Lua-table item definitions, custom cursor sprites) and
    `skipSpeedbook`. Upstream's `addItemDataFromTsv` covers registration (the Hunter's items are
    `itemdat_hunter.tsv`), the Hunter uses vanilla cursors, and `OnShouldHideSpeedbookSpell` hides a
    mod scroll's generic speedbook icon. The speedbook PR's hide hook also fires in `DoSpeedBook`, so
    the cursor jump matches the drawn list.
- Building a PR branch: take `MonsterTamer`'s versions of the engine files onto a branch from `master`,
  then strip what belongs elsewhere. Formatting churn (e.g. `[] {}` → `[] { }` from a different
  clang-format) never goes into a PR branch.

## Status
Entries are added per-feature as built. The top-down pass (diff the whole branch, confirm every engine
touch is accounted for, group into PRs, write PR descriptions) is in progress via the branches above.

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
