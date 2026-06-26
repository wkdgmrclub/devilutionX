# Engine changes — Items / Save (`Source/items.*`, `Source/msg.*`, `Source/loadsave.cpp`, `Source/pfile.cpp`)

Mod-side design for the blob is `../item_moddata.md`; the save-stability constraint is in `CLAUDE.md`
(non-Hunter `.sv`/`.hsv` must stay byte-identical).

---

## Optional Mod-Data Blob (`item.modData`) — status: ready (rewritten 2026-06-25)

**One-liner:** an optional, variable-length byte blob attachable to any item; **empty (zero cost) when
no mod uses it**; the base game never reads or interprets it.

- `std::string _iModData` on the `Item` struct (`Source/items.h`, after `dwBuff`), exposed to Lua as
  `item.modData` (binary-safe string get/set, `Source/lua/modules/items.cpp`).
- **Replaced + removed** the old always-on `uint32_t _iLuaData` + `TItem::dwLuaData` (4 bytes on every
  networked item, mod or not) + the `pack.cpp` `wValue` squat. Item network commands are back to
  byte-for-byte vanilla; the blob **never rides `TItem`** (that struct is `memcpy`'d as raw bytes → must
  stay POD; `Item` itself copies by assignment and saves field-by-field, so it can hold a `std::string`).

**Transport (two complementary paths, both opaque to the engine):**

| Path | Mechanism | Covers |
|---|---|---|
| Live hop | the mod's own Lua net pipe keyed by item seed (Hunter `SD` msg) | a trade where the dropper is present |
| At-rest | per-level `DLevel.modData` map (`seed->blob`) riding the existing delta export/import (mirrors `spawnedMonsters`); restored onto a floor item in `DeltaLoadItems` | a dropped floor item across a rejoin — **even after the dropper leaves** (delta handed to a joiner on connect) |

**NOT in the hero save** (`ItemPack` frozen). A mod persists it out-of-band via the `luamoddata` slot
(below) and rebuilds it onto held items at load.

**Bindings (`Source/lua/modules/items.cpp`, backed by `Source/msg.cpp`):**
- `items.setItemDeltaModData(level, seed, blob)` — write a level's delta map (empty blob clears).
  Clamped to `MaxItemModDataBytes = 255`; entry count capped at `MAXITEMS`.
- `items.getItemDeltaModData(level, seed) -> string` — read it back.
- `items.currentDeltaLevel() -> integer` — the local player's MP delta level id.
- `items.spawnAt` / `items.addToHealerStock` / `player:addScrollByMapping` take an optional **string**
  `modData` override (sets `item._iModData`).

**No-op-when-unused invariant:** an empty `_iModData` is never serialized, broadcast, or stored; base /
no-mod items behave exactly as vanilla. Net win vs. the removed always-on `dwLuaData`.

> **Rejected (reverted, do not look for it):** a generic STRING item slot
> (`Item::_iLuaText`/`TItem::szLuaText`/`item.modText`) and an earlier `ItemPack`/`.sv` `dwLuaData`
> extension — both grew the item wire/save format for **every** player unconditionally, breaking
> "byte-for-byte vanilla without the mod." Reaffirmed: even a 4-byte always-on item-wire field is the
> ceiling; arbitrary mod data rides the generic pipe keyed by seed, or the optional blob.

---

## `OnItemDropped(player, item)` hook — status: ready
Fired in `TryDropItem` (`Source/controls/plrctrls.cpp`) when the **local** player manually drops a held
item onto the floor, before the cursor item is cleared (`item.modData` still valid). Sibling of
`OnItemPickedUp`; the trade mechanism (drop → another player picks up). Plumbing: `lua_event.hpp/cpp`,
`events.lua`.

---

## Mod-Data Save Slot (`"luamoddata"` MPQ entry) — status: ready
A separate named entry in the player's `.sv`/`.hsv` MPQ archive, written only when an `OnSavePlayerData`
handler returns a non-empty table. The MPQ archive format is like ZIP — adding a named entry never
touches existing entries or their sizes, so non-Hunter saves stay byte-stable.

- Written in `LuaSavePlayerModData(SaveWriter&)` (`Source/loadsave.cpp`) — flat `uint32` array
  `[count, val0, …]`.
- Read in `LuaLoadPlayerModData()` — `LoadHelper::IsValid()` checked first; missing entry (old / non-Hunter
  save) silently skipped.
- Both called inside the `!gbVanilla` block in `pfile_write_hero`/`pfile_read_player_from_save`
  (`Source/pfile.cpp`), same guard as other mod-only save data.
- Lua entry points: `OnSavePlayerData() -> table` / `OnLoadPlayerData(data)`.

**No-op-when-unused invariant:** non-Hunter `OnSavePlayerData` returns `nil` → empty vector →
`data.empty()` early-return → **no entry written** → the save is byte-identical to a non-modded one.

---

## Save-bracket hooks `OnBeforeSaveHero` / `OnAfterSaveHero` — status: ready
A void bracket pair at the top and bottom of `pfile_write_hero(SaveWriter&, bool)` (`Source/pfile.cpp`) —
the single MyPlayer-write funnel (SaveGame, MP autosave/level-change, demo; **not** char-create
`pfile_ui_save_create`). Lets a handler transiently mutate the saved player and restore it within the one
synchronous write. Used to make the Potion of Forgetting session-only: Lua pops it from its slot before
serialization and writes the popped copy back into the **same** slot after (in-place restore via a held
live ref + full-field copy, so belt/inventory position is preserved), so it is never on disk and never
survives a reload, with no load-time scan. A crash between the two hooks leaves an empty slot that
`RemoveEmptyInventory` sanitises on load. Applies to all classes.

---

## `OnItemAllowedInStash(item, default)` hook — status: ready
Query in `IsItemAllowedInStash` (`Source/qol/stash.cpp`); C++ passes the vanilla value
(`_iMiscId != IMISC_ARENAPOT`) as `default`; nil → default. Covers both manual paste and auto-place (the
one chokepoint). The mod blocks the Potion of Forgetting + Tame Scrolls from the normal stash (mod items
must never ride `stash.sv` into a base-game session).
