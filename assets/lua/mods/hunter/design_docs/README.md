# Hunter Mod — Design Docs

This is the map. Read it before touching any other doc, and before writing a new one.

The cardinal rule: **one fact, one home.** A single piece of information lives in exactly one
authoritative doc. If you find yourself updating "the same thing" in two files, the structure is
wrong — fix the structure, don't shotgun the update.

---

## The docs

### Temporal buckets (where work lives by its lifecycle)

| Doc | Holds | Rule |
|---|---|---|
| **roadmap.md** | Future, not-yet-started work, in priority order. | The backlog. When an item becomes the active task, it **moves** to `development_notes.md` (not copied). |
| **development_notes.md** | The **ONE** task currently in flight — scratchpad, open questions, in-progress reasoning. | Exactly one live task at a time. When it ships, it **graduates** (see below) and is deleted from here. |
| **HISTORY.md** | The dated log of everything shipped + playtested. | Append-only narrative. The "what happened, when" record. |
| **bugs.md** | Active + resolved bug log. | Keep. |

### Reference (the stable "what exists" docs — change only when the thing changes)

| Doc | Holds |
|---|---|
| **lua_api_reference.md** | The single Lua-facing reference: the **hook catalog** (every `lua::OnXxx()` call-out — signature, C++ fire site, default), the Lua bindings (`player.` / `monster.` / `items.` / `spells.` / `system.` / `render.`), mod-loading, and data files. **Thin hooks only**; any engine change bigger than a call-out points *out* to `cpp_changes/`. |
| **hunter_class_design.md** | Hunter identity, Tame tiers, scroll encoding, archetypes, animation frames. The "what we're building." |
| **trn_palette.md** | TRN palette-remapping reference + the Hunter TRN file. |

### Subsystem design (the "how a shipped system works + why" deep dives)

| Doc | Holds |
|---|---|
| **net_sync.md** | The multiplayer ally sync **data model + decisions**: two-plane (Hunter/non-Hunter) architecture, ownership/spawn/combat-override sync, the slot model, DM/N decisions. The *mod-side reasoning*. The *engine code* it rides lives in `cpp_changes/net.md`. |
| **item_moddata.md** | The optional `item.modData` blob — as-built design + the mod payload layout. Engine surface lives in `cpp_changes/items.md`. |

### cpp_changes/ — engine modifications (the upstream/PR material)

Every change to base-engine code (anything outside `Source/lua/`) that is **more than a thin
hook** — refactors made to reach a hook, new engine primitives, struct/array/protocol changes —
with its **WHY** and its **vanilla-invariance proof** (why the base game is byte-identical when the
mod isn't loaded). One doc per engine area.

| Doc | Holds |
|---|---|
| **cpp_changes/README.md** | Scope rules, provenance basis (`git merge-base`), the per-entry template, the eventual top-down branch-diff pass. |
| **cpp_changes/spells.md** | Dynamic spell registration (`spelldat.cpp`, the `msg.cpp` guard). |
| **cpp_changes/net.md** | The generic Lua net pipe (`CMD_LUAMSG`), `netSpawnAt`, high-slot allocation, mod-extensible monster arrays. |
| **cpp_changes/items.md** | The `item.modData` blob engine surface, the `luamoddata` save slot, `OnItemDropped`. |
| **cpp_changes/monsters.md** | `LuaChangeMonsterToGolem` owner param, `PlaceGroup` clamp, `LuaDeltaRemoveSpawnedMonster`, the SP re-link getters. |
| **cpp_changes/missiles.md** | The targeting-veto sites, `ProcessHorkSpawn` gate, missile-resolution hook. |

---

## The two discipline rules

### 1. One live doc
Work-in-progress lives **only** in `development_notes.md`, for **one** task. Resist the urge to spin
up `feature_x_plan.md` — that is how three-docs-per-feature sprawl starts.

### 2. Graduation (what happens when a task ships)
A shipped feature legitimately touches several docs — but each is a **different concern**, not a
duplicate:

- **Hook rows** (signature + fire site) + **new Lua bindings** → `lua_api_reference.md`
- **Engine code + why + invariance proof** → `cpp_changes/<area>.md`
- **Dated "we did this" entry** → `HISTORY.md`
- **Mod-side system reasoning**, if it's a whole subsystem → a `net_sync.md`-style design doc

Then **delete it from `development_notes.md`.** The test for "is this duplication or correct
separation": if updating fact F means editing two docs, it's duplication — collapse it. If two docs
mention the same feature but describe *different facets* (the hook signature vs. the engine refactor
that reaches it), that's correct separation — cross-link them.

> Engine "finesse" belongs in `cpp_changes/`, never in the hook catalog. The catalog says *what the
> hook is*; `cpp_changes/` says *what we had to do to the engine to make it fire*.
