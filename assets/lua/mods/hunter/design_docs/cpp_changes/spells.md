# Engine changes — Spells

## Lua dynamic spell registration with stable IDs — status: ready (in-game verified 2026-06-25; PR description not finalized)

**One-liner:** A Lua API for mods to register custom spells from TSV (`spells.registerSpell` /
`spells.getSpellId` + the `SpellsAssigned` event), assigning each a **stable, deterministic runtime
SpellID** so custom spells are castable in both game modes and survive save round-trips.

**What upstream has today:** *nothing for this.* The Lua **event framework** (`lua_event.*`,
`events.lua`) is upstream, but there is **no** dynamic spell registration — `spelldat.cpp` in the
merge-base has zero Lua/`SpellDataLoaded` references, and `Source/lua/modules/spells.cpp` does not exist
there. So this introduces a feature, it does not modify an existing one.

**Files (engine):**
- `Source/lua/modules/spells.cpp` — **ours** (new module). `registerSpell` (queues), `getSpellId`, `setSpellIcon`.
- `Source/tables/spelldat.cpp/.h` — **upstream file**; our additions: `ReadSpellRecord` (refactor),
  `MakeInertSpell` (save-stable padding), the pending-queue + `LuaQueueDynamicSpell` /
  `LuaClearPendingDynamicSpells` / `LuaFinalizeDynamicSpells`, and the `SpellDataLoaded`→finalize→
  `SpellsAssigned` sequence inside `LoadSpellData`.
- `Source/lua/lua_event.cpp/.hpp` — **upstream file**; our addition: the `SpellsAssigned` callout.
- `assets/lua/devilutionx/events.lua` — **upstream file**; our addition: the `SpellsAssigned` event entry.
- `Source/msg.cpp` — **upstream file**; one vanilla-logic line changed (below).

**Vanilla-logic changes:** exactly one line, in `InitNewSpell` (`Source/msg.cpp`):
```cpp
- if (wParamSpellID > static_cast<int8_t>(SpellID::LAST))
+ if (wParamSpellID >= SpellsData.size())
```
*Equivalence proof:* the next line already calls `IsValidSpell`, which bounds against
`SpellsData.size()`. For the base game `SpellsData.size() == int(SpellID::LAST) + 1`, so old and new
guards reject the identical input set. The change only matters once `SpellsData` legitimately extends
past `LAST` — i.e. only when a mod has registered a spell.

**No-op-when-unused invariant:** no mod registers → `PendingDynamicSpells` empty →
`LuaFinalizeDynamicSpells` returns immediately → `SpellsAssigned` fires into zero handlers →
`SpellsData` untouched → save format unchanged → `msg.cpp` guard behaves as before. Vanilla Diablo
**and** Hellfire are byte-for-byte identical.

**Save-format invariance even when used:** the `_pSplLvl` load loop always consumes a fixed 64 bytes
(conditional-read across `0..LAST` + skip `LAST..64`; the write side dumps the whole 64-byte array).
Inert padding slots carry `bookLevel = staffLevel = -1`, so `GetSpellBookLevel/StaffLevel` return `-1`
for them exactly as the pre-existing out-of-bounds path did. Dynamic IDs (53+) fall in the skip range.
Non-Hunter / vanilla saves unaffected; the full `uint64` spell bitmasks carry bits 53+ fine.

**Why the determinism is required (not gold-plating):** IDs were originally *appended* at
`SpellsData.size()`, which differs by game mode (37 base spells in Diablo vs 52 in Hellfire). That made
custom spells (a) uncastable in Hellfire — ID 53 > `SpellID::LAST` (52), rejected by `InitNewSpell` —
and (b) unstable across the **natively-supported `.sv`↔`.hsv` transfer**: the same skill/scroll bitmask
bit would resolve to a different spell, silently corrupting saves. Deterministic name-sorted assignment
from a fixed base (`SpellID::LAST + 1`) makes a name resolve to the **same ID in both modes and
regardless of mod load order** — the minimum for custom spells to survive a save round-trip and for
same-mod-set MP clients to agree with no runtime sync.

**Why it can't be pure Lua:** mutating `SpellsData`, growing it with save-stable padding, and populating
the name→ID / icon maps (`LuaDynamicSpellIds`, used by `ParseSpellId` to resolve names in TSVs like
`starting_loadout.tsv`) are C++-only. The only movable slice is the ~10-line sort+assign; kept
engine-side so determinism doesn't depend on Lua load order and the delicate save-padding contract lives
next to the save format.

**Ceiling (document, don't fix here):** dynamic IDs occupy 53–63 (~11 slots) because the per-player
spell sets are `uint64` (`GetSpellBitmask` shifts by `id-1`). Widening would touch the save format and
every bitmask site — out of scope; a known limit.

**Reviewer questions to preempt:**
- *"Why does mod support touch `msg.cpp`/the spell table?"* → new opt-in feature, no-op when unused; one
  vanilla line changed and provably equivalent.
- *"Why not append IDs / why so much machinery?"* → append corrupts saves across modes and load order;
  determinism is the minimum correct design.
- *"Why not do it in Lua?"* → see above; the bulk is irreducible C++.

**Commit structure (suggested):**
1. Pure refactor — extract `ReadSpellRecord` from `LoadSpellDatFromFile` (no behaviour change).
2. The feature — spells module, `SpellsAssigned` event, finalize sequence + padding, and the `msg.cpp`
   guard. Lead the message with the no-op-when-unused invariant.

**Dependency / scoping:** the registry sits on the Lua spells module + `SpellDataLoaded` hook (also
ours). A real upstream PR is the **whole** "Lua custom-spell registration" feature in one piece; the
registry can't land alone against mainline.

**Cross-refs:** `../lua_api_reference.md` (Dynamic registration), `../lua_api_reference.md` (Spells
API), `../HISTORY.md` (Phase 10 — Deterministic dynamic-spell registry).
