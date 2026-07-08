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

**The ITEM itself needs no mod transport.** A custom floor item is a valid vanilla item (createInfo 0
passes `IsPItemValid`; `RecreateItem`'s createInfo==0 branch rebuilds it and fires
`OnCustomItemRecreated` for the name), so it rides the standard item commands: hand drops send
`CMD_PUTITEM` as always, and `items.spawnAt` announces `CMD_SPAWNITEM` exactly like a vanilla
quest/reward drop (`SpawnRewardItem` pattern) — same-level peers spawn a live copy, every client
(sender included, via loopback `OnSpawnItem`) registers it in the level delta, with the engine's own
dedup/anti-dupe. Only the blob is mod-carried, over the two paths above.

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
>
> **Also rejected (removed 2026-07-08, do not rebuild):** mod-side replication of the ITEM record —
> `LuaDeltaRegisterDroppedItem`/`LuaDeltaRegisterDroppedItemAt` (`msg.cpp`) + the
> `items.registerDeltaDroppedItem` binding + the Hunter `DI` pipe message. They hand-rolled what
> `CMD_SPAWNITEM`'s `OnSpawnItem` receiver already does natively (same-level live spawn, all-client
> delta registration, dedup), built on the mistaken belief that the vanilla receiver's
> `IsPItemValid`/`RecreateItem` chokepoints would reject a custom item — they don't (createInfo 0
> validates, and the recreate path is what rebuilds the custom name). `items.spawnAt` now just sends
> `CMD_SPAWNITEM`; only the blob needs mod transport.

---

## `OnItemDropped(player, item)` hook — status: ready
Fired when the **local** player manually drops a held item onto the floor, immediately after the
`NetSendCmdPItem` send and before the cursor item is cleared (`item.modData` still valid). Sibling of
`OnItemPickedUp`; the trade mechanism (drop → another player picks up).
**Four fire sites — one per engine drop path** (each is the identical one-line call-out after the same
send; a drop path without the call-out silently breaks the mod's drop-time announce, which is exactly
the class of bug the missing mouse site caused):
- `TryDropItem` (`Source/controls/plrctrls.cpp`) — controller drops + the `NewCursor` forced drop +
  the `inv.cpp` drop fallback (those route through it). After `CMD_PUTITEM`.
- The mouse click-on-world drop (`Source/diablo.cpp`, `LeftMouseDown` held-item branch) — the
  ordinary mouse trade drop; does NOT route through `TryDropItem`. After `CMD_PUTITEM`.
- The close-stash-while-holding force-drop (`Source/inv.cpp` `CloseStash`). After `CMD_PUTITEM`.
- The swap-drop inside `InvGetItem` (`Source/inv.cpp`) — clicking a floor item while already holding
  an item drops the held item in place. After `CMD_SYNCPUTITEM`, before `player.HoldItem` is
  overwritten by the picked-up item.
Plumbing: `lua_event.hpp/cpp`, `events.lua`.

---

## `OnItemPickedUp(player, item)` hook — status: ready
Fired when a player takes a floor item, before `CleanupItems` clears the floor slot (`item` is the
floor copy, still valid). **Two fire sites — one per engine pickup path:**
- `AutoGetItem` (`Source/inv.cpp`) — auto-pickup into inventory/belt/equipment (walk-over, or a
  left-click with the inventory panel closed); fires only when placement succeeded.
- `InvGetItem` (`Source/inv.cpp`) — click-pickup with the inventory panel open; one unconditional
  call-out after the gold/hand branch, before `CleanupItems`, covering both the gold auto-place and
  the to-hand branch and all three `msg.cpp` callers (incl. the off-level `OnGetItem` echo). On this
  path the acquired copy is the player's `HoldItem` (cursor), not an inventory slot.
Both sites are unconditional one-line event call-outs after the same floor-copy window the engine
itself documents (`HoldItem` copy first so `CleanupItems` can run after); no mod loaded = no-op,
vanilla behaviour byte-identical.

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
