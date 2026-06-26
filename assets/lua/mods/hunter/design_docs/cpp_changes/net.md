# Engine changes — Net (`Source/msg.*`, `Source/lua/*`, `Source/monster.*`)

The mod's entire engine net surface is **one** generic command (`CMD_LUAMSG`) plus a handful of thin
generic affordances. Everything else is Lua messages on the pipe (no per-feature `CMD_*`). All
generic / modder-facing: unmodded play never sends a `CMD_LUAMSG`, every binding is byte-for-byte
vanilla when not driven by a mod, and both query hooks default to vanilla. The mod-side data model that
rides this is `../net_sync.md`.

---

## The generic Lua net pipe — status: ready

**One-liner:** a single mod-agnostic net primitive that ferries an opaque length-prefixed payload
between clients and hands it to Lua. The engine never learns what a message *means* — it only moves
bytes.

- `CMD_LUAMSG` — new `_cmd_id`, commented as the generic Lua mod net channel.
- `struct TCmdLuaMsg { _cmd_id bCmd; uint16_t len; char data[...]; }` — **length-prefixed** so Lua may
  send arbitrary bytes / a serialized table (unlike `TCmdString`'s null-terminated body).
- `NetSendCmdLuaMessage(pmask, bytes, len)` (`Source/msg.cpp/.h`) — mirrors `NetSendCmdString`.
- `OnLuaMessage` receive handler → `lua::NetMessage(senderId, payload)` (`Source/lua/lua_event.cpp`) →
  fires the `NetMessage(senderId, payload)` event.
- Lua-facing send: `system.netSend(payload[, mask])` (`Source/lua/modules/system.cpp`), default mask =
  all other clients, no-op in SP.

**Feasibility basis:** `CMD_STRING`/`TCmdString` (`msg.h`, `OnString` `msg.cpp`) already proves the
engine supports variable-length payloads via `multi_send_msg_packet` on the reliable ordered channel.
**Invariant:** unmodded play never sends one; the engine never interprets the payload. This is the only
net command ever added — reusable by any mod.

## `monster:makeGolem(ownerId?)` owner param
See `monsters.md` (the `LuaChangeMonsterToGolem` primitive). The net relevance: it lets a receiving
client replay the golem conversion for a *remote* player's pet.

## Mod-spawn-over-pipe affordances

- **`monsters.netSpawnAt(monsterId, typeId, uniqueTypeIdx, capturedDifficulty, x, y, seed)`**
  (`Source/lua/modules/monsters.cpp`) — recreate a networked mod-spawned monster at a specific slot id,
  resolving the **species** (`typeId`, globally stable) to the **receiver's own** `LevelMonsterTypes`
  index (`EnsureMonsterType` → register + `InitMonsterGFX`). Reuses `InitializeSpawnedMonster`
  (→ `EnsureMonsterIndexIsActive`) + `PrepareUniqueMonst` for uniques; **no level-owner gate** (receivers
  aren't the owner).
- **Mod spawn bindings are now LOCAL-ONLY:** `monsters.spawnAt` / `spawnWithDifficulty` /
  `spawnUniqueAt` no longer call `NetSendCmdSpawnMonster`. *Rationale:* that cmd broadcasts a
  **level-local `typeIndex`** into `LevelMonsterTypes`, meaningless on a peer whose independently
  generated level never registered that species → null-sprite render crash (`../bugs.md`, High).
  Cross-client spawn is mod-owned over the pipe by species id instead. Vanilla spawn cmd / delta / save
  formats unchanged.
- **`player:isOnActiveLevel()`** (`Source/lua/modules/player.cpp`) — thin getter over engine
  `Player::isOnActiveLevel()`. Level-scope guard: monster slot ids are per-level, so a `NetMessage`
  handler must confirm the sender shares the receiver's active level before acting on a slot id (else it
  aliases a different monster). Mirrors the engine's own `OnSpawnMonster` gate.
- **`player:isLevelOwnedByLocalClient()`** (`Source/lua/modules/player.cpp`) — thin getter over engine
  `Player::isLevelOwnedByLocalClient()` (vanilla). The level owner is the single client allowed to
  allocate a monster slot (`PrepareSpawnSlot` / vanilla `SpawnMonster` both gate on it). The mod uses it
  for spawn authority: a non-owner deploy routes through the `DR` request; minion spawns are done by the
  level owner then replicated over the pipe.

## High-slot allocation (the MP slot model — *bring-up in `../development_notes.md`*)
`AllocateHighMonsterSlot()` (`Source/lua/modules/monsters.cpp`) returns the first free-pool id
`≥ MaxMonsters`; `PrepareSpawnSlot` uses it. Allies occupy slots above the natural-monster region (which
level generation caps below `MaxMonsters`), so an ally never collides with another client's regenerated
natural monster, and the receiver can clobber a stale slot unconditionally. Headroom reserved via
`requestExtraMonsters(...)` (below). Design reasoning: `../net_sync.md` §3.

## Deterministic-AI affordances (allies run AI on every client, like a vanilla golem)
- **`monsters.aiRandom(n)`** (`Source/lua/modules/monsters.cpp`) — draws `[0, n)` from the engine global
  RNG (`GenerateRnd`). During `ProcessMonsters` the global RNG is reseeded to each monster's synced
  per-monster seed, so a draw made inside a monster-AI hook is identical on every client. Used in place
  of Lua `math.random` for any ally-AI decision that must stay in lockstep.
- **`monster:startSpecialStand()`** (→ `LuaStartMonsterSpecialStand`) — plays the special-stand (cast)
  animation toward the target, **no spawn, no hook**. Used as the Skeleton King's minion-cast animation
  on peers (the skeleton itself is level-owner-spawned + pipe-replicated), so every client animates the
  cast without anyone spawning a duplicate.
- **`OnGolemCanRunAI(monster, default=true)`** (`Source/monster.cpp` `ProcessMonsters`, fired only for
  `MFLAG_GOLEM`) — gates whether this client simulates the golem's AI this tick. **The mod no longer
  registers a handler** (it was an interim peer-suppression that *froze* allies on peers → Bug #1; the
  fix reverted to deterministic AI everywhere). The hook remains for any modder; default true = vanilla.

---

## Mod-extensible monster arrays — status: ready (`Source/monster.h/.cpp`)

**One-liner:** two fixed monster caps become mod-extensible at load time; unmodded play is byte-identical
(accessors return the vanilla base), so save/wire formats are unchanged.

- **Type table:** `LevelMonsterTypes` is a `std::vector<CMonster>`, sized in `InitLevelMonsters` to
  `GetMaxLvlMTypes()` = `MaxLvlMTypes` (24) + extension. `RequestExtraLevelMonsterTypes(n)` accumulates.
  Rebuilt per level, never serialized → zero save/wire coupling.
- **Live monsters:** `Monsters[]`, `ActiveMonsters[]`, `DLevel::monster[]`, the sync LRU/priority arrays,
  `monsterConversionData[]`, and `sgRecvBuf` sizing are dimensioned to `AbsoluteMaxMonsters = 252` (static
  arrays → all `Monster*`/`Monster&` stay valid, no init-ordering hazard). Runtime logical cap is
  `GetMaxMonsters()` = `min(MaxMonsters + extension, AbsoluteMaxMonsters)`; `RequestExtraMonsters(n)`
  accumulates. All logical bounds, delta loop counts, validation guards, and the **enemy-encoding offset**
  (`encode_enemy`/`decode_enemy`) use `GetMaxMonsters()`. **Frozen at literal `MaxMonsters`:**
  natural-placement caps (`PlaceMonsters`, `AddMonster`, `SpawnMonster`, monster-split spawns) so vanilla
  monsters keep ids `< 200` and the extension is reserved for mod allies; plus the vanilla
  `MonsterKillCounts` save-padding in `loadsave.cpp`.
- **Hard ceiling 252 = `256 − MAX_PLRS`:** the enemy reference (`Monster.enemy`, `DMonsterStr.menemy`,
  `TSyncMonster._menemy`) is a `uint8_t` packing monster targets into `[0, GetMaxMonsters())` and player
  targets above. Raising past 252 requires widening those fields to `uint16` (format-breaking). Do not
  exceed without that work.
- **Lua API:** `monsters.requestExtraTypes(n)` / `monsters.requestExtraMonsters(n)` — call at mod-load
  (before any level), cumulative across mods.

**No-op-when-unused invariant:** with no `requestExtra*` call the accessors return the vanilla base; the
static arrays are oversized but only `[0, MaxMonsters)` is ever touched; wire/save bytes unchanged.
