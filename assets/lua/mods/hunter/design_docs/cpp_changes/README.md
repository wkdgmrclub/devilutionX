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
  - **Held: stack on `lua-stash-hooks`** (they need its `CreateQueryEvent`):
    - `lua-item-rules` — `OnCanPlayerUseItem`, `OnPlayerCanPickUpItem`, `OnPlayerCanCutInvItem`,
      `OnCanAutoRefillBeltItem`, `OnVendorWillBuyItem`, `OnShouldExcludeWirtItem`, `OnOilyShrine`.
    - `lua-monster-display` — monster display name / info / outline / TRN / show-resistances.
    - `lua-speedbook-casting` — mod speedbook entries, scroll-slot resolution, cast gates,
      `OnSpellCast`/`OnSpellActionFrame` (these also want `lua-spell-registry`).
    - `lua-item-moddata` — `item.modData`, delta/save persistence, mod stashes saving modData.
  - **Needs a design pass first:** `lua-monster-spawning`. (1) Our `monster.id` redefines
    upstream's existing pointer-based `id` as the `Monsters[]` index. Don't change an existing binding;
    add a new property (e.g. `index`) and move the Hunter mod onto it. (2) Upstream already spawns
    through the level owner (`SpawnMonster` → `CMD_SPAWNMONSTER`); route our spawn bindings through it
    where possible.
  - **Held: stack on `lua-monster-spawning`:** `lua-monsters-in-town` (nothing on `master` can put a
    monster in town), `lua-player-minions` → `lua-minion-combat`.
  - **Class mechanics:** propose as new class-TSV attributes (upstream's direction), not hooks.
    Builds on `lua-class-registration`; needs its own design pass against current `playerdat`.
  - **Parked:** hooks layered on the yuripourre custom-items framework (`OnCustomItemRecreated`,
    custom unique infobox, `OnGetMiscItemDescription`, `OnItemUsed`) until that framework's upstream
    status is known.
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
