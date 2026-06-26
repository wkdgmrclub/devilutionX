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
`git merge-base HEAD master` (was `4c7d80c0`). "Upstream" = exists in the merge-base (vanilla). "Ours" =
added after the merge-base. **Always re-derive** provenance with `git cat-file -e <merge-base>:<path>` /
`git show <merge-base>:<path>` rather than trusting memory — the branch moves.

## Status: bottom-up for now
Entries are added per-feature as built. A later session does the **top-down pass**: diff the whole
branch against the merge-base, confirm every engine touch is accounted for across these docs, group
them into coherent PRs, and write final PR descriptions. (This subsumes the old "engine surface
inventory" milestone.)

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
