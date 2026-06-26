# Optional Item Mod-Data Blob (`item.modData`)

> **Status: shipped 2026-06-25.** Design + mod payload reference. The **engine surface** (the
> `Item::_iModData` field, the `DLevel.modData` delta map, the bindings, `OnItemDropped`) lives in
> `cpp_changes/items.md`; the dated log is in `HISTORY.md`.

A mod attaches arbitrary data to an item by packing its own layout in Lua (`string.pack`) into
`item.modData` — an **optional, variable-length** byte blob that is **empty (zero cost) when no mod
uses it**. This replaced the old always-on `Item::_iLuaData` / `TItem::dwLuaData` slot (4 bytes on
every networked item, base game included) and the `pack.cpp` `wValue` squat — all removed, so item
network commands are back to byte-for-byte vanilla. The base game never reads or interprets the blob.

## Architecture — two complementary transports, both opaque to the engine

The blob never rides `TItem` (that struct is `memcpy`'d as raw bytes and must stay POD). Instead:

1. **Live hop = the mod's Lua net pipe.** A mod broadcasts the blob keyed by item seed over its own
   channel (Hunter: the `SD` message, `broadcastScrollData`). A present peer caches it and restores it
   on pickup. Covers a trade where the dropper is present. Engine adds nothing for this.
2. **At-rest persistence = the level delta.** A per-level `DLevel.modData` map (`seed -> blob`) rides
   the existing delta export/import (mirrors `spawnedMonsters`), so a dropped floor item keeps its blob
   across a rejoin — even after the dropper leaves (the delta is handed to a joiner on connect).
   Restored onto the floor item in `DeltaLoadItems`.

**NOT in the hero save** (`ItemPack` frozen for non-Hunter save stability). A mod persists it
out-of-band via `OnSavePlayerData`/`OnLoadPlayerData` and rebuilds it onto held items at load.

## Hunter-mod payload

`encodeBlob`/`decodeBlob`/`blobForSeed` pack the per-scroll Plane-2 data:

```lua
-- string.pack "I2 B B B I4 s1" = kills / immunity-idx / TRN / gamemode + OHID + OT name
item.modData = encodeBlob(kills, immIdx, trn, gamemode, ohId, ohName)
```

- kills (`I2`, clamped 65535) + Bonded immunity index (`B`) + Bonded TRN variant (`B`) + tamed-in
  gamemode (`B`, also bit 22) + **Original Trainer id + name folded in** (`I4 s1`).
- `s1` = a length-prefixed string (≤255 bytes; player names ≤32). Empty `""` for any non-scroll.
- The old `OO`/`NET_ORIGIN` pipe message for Original-Trainer is **retired** — origin rides the one blob.

Pickup sources the blob from `item.modData` (delta-restored) → `receivedBlobs[seed]` (live announce) →
`blobForSeed` (own tables). Drops (`dropTameScroll`, manual via `OnItemDropped`, refund) persist to the
delta + announce. `healHeldScrollModData` (at `GameStart`) rebuilds `modData` from `luamoddata` so a
held scroll saved/reloaded since acquisition still trades losslessly.

## Watch-items
- **Trivially-copyable.** `Item` is never raw-copied (it copies by assignment, saves field-by-field via
  `PackItem`), so it can hold a `std::string` directly — but `TItem`/`TCmdPItem` cannot. Verified.
- **Delta index-alignment.** The `DLevel.modData` map must stay consistent with the item delta through
  every add/remove/compaction path (highest-risk area).
- **Anti-cheat / validation.** Custom scrolls pass via `_iCreateInfo == 0`; the blob is opaque to base
  validation. Re-confirm no validator rejects an item for carrying extra bytes.
