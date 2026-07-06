# Engine changes — Monsters (`Source/monster.*`, `Source/msg.*`, `Source/dead.cpp`)

Engine-action primitives + spawn/delta hygiene fixes that mod-spawning a monster after level generation
exposes. The thin monster hooks (the `OnGolem*` / `OnMonster*` call-outs) are catalogued in
`../lua_api_reference.md`.

---

## `LuaChangeMonsterToGolem(Monster&, uint8_t ownerPlayerId)` — status: ready
`monster:makeGolem(ownerId?)` (`Source/lua/modules/monsters.cpp`) → `LuaChangeMonsterToGolem`
(`Source/monster.cpp/.h`). Added the `ownerPlayerId` param (was hardcoded `MyPlayerId`); the binding
defaults it to `MyPlayerId` so the existing no-arg call is **byte-for-byte unchanged**. Lets a client
replay a conversion for a *remote* player's pet (sets `goalVar3` = that owner).

**Why this stays a single engine primitive (and is NOT decomposed into Lua):** it is an *engine action
primitive*, not a hook — branch-free, mod-agnostic, an atomic initializer of engine-internal state. It
writes `monster.flags` bits (`MFLAG_GOLEM` on; `MFLAG_TARGETS_MONSTER | MFLAG_NO_ENEMY | MFLAG_SEARCH`
off), the AI-mode field (`ai = MonsterAIID::Golem`), `golemToHit`, `goal`, `activeForTicks`, `goalVar3`
(owner), `pathCount`, and calls `UpdateEnemy`. Doing this from Lua would need ~6 new bindings exposing
raw flag bits / the AI-mode enum / owner slot / scheduling fields as *writable* — strictly more engine
surface, exposes engine guts any mod could corrupt, and the sequence is order-sensitive (flags must be
cleared before `UpdateEnemy`), so splitting across binding calls risks inconsistent intermediate state.
Project line: *gameplay composition* → Lua; *atomic engine-state ops* → thin `Lua`-prefixed primitives.

---

## Spawn / delta hygiene for post-load mod spawns — status: ready
Both generic; no vanilla behaviour change (full diagnosis in `../bugs.md`).

- **`PlaceGroup` unsigned-underflow clamp (`Source/monster.cpp`).** `PrepareUniqueMonst` calls
  `PlaceGroup(minionType, bosspacksize, leader, …)` for any unique whose `monsterPack != None`,
  regardless of `bosspacksize`. `PlaceGroup` clamps `num` to `totalmonsters - ActiveMonsterCount`;
  `totalmonsters` is fixed at generation time, so spawning a pack-leader unique once `ActiveMonsterCount`
  has grown past it (e.g. `spawnUniqueAt` for a tamed Skeleton King, `bosspacksize = 0`) wrapped the
  `size_t` subtraction huge and overran the monster array. Fixed:
  `num = (totalmonsters > ActiveMonsterCount) ? (totalmonsters - ActiveMonsterCount) : 0;`. Vanilla never
  hits it (at load `totalmonsters >= ActiveMonsterCount` whenever `PlaceGroup` runs).
- **`LuaDeltaRemoveSpawnedMonster(const Monster&)` (`Source/msg.cpp`, decl `Source/msg.h`).**
  `DLevel::spawnedMonsters` records dynamically spawned monsters for level-reload re-creation and is
  **never erased** by vanilla (death only zeroes delta HP). A monster removed via `monster:remove()`
  therefore replays on MP level re-entry (orphan re-creation + `ActiveMonsterCount` inflation). The helper
  erases the `spawnedMonsters` entry and invalidates `deltaLevel.monster[id]`; no-op in SP; resolves the
  level from `currlevel`/`setlevel` (like `DeltaSaveLevel`) so it is correct when called from
  `OnLevelExit` recall (where `player.plrlevel` is already the destination). Called from the
  `monster:remove()` binding; the delta erase runs immediately, while the `ActiveMonsters` compaction
  (`DeleteMonsterList()`) is deferred when a game-logic step is in flight to avoid re-entrant array
  mutation (`../bugs.md` → "Ally/minion death crashed the renderer").
- **`LuaDeltaRemoveSpawnedMonster(uint8_t level, size_t monsterId)` overload (`Source/msg.cpp`, decl
  `Source/msg.h`) + `monsters.removeDeltaSpawnedMonster(level, monsterId)` binding
  (`Source/lua/modules/monsters.cpp`).** The by-slot-id sibling of the above, for a client **not on that
  level** — the level-keyed counterpart of `LuaDeltaKillMonster`/`recordDeltaKill`. Needed because
  `delta_sync_monster` fills `deltaLevel.monster[slot]` position/hp records from routine cross-level
  `CMD_SYNCDATA` traffic even on clients that never materialised the monster; after the owner removes it,
  that stale record would be applied by `DeltaLoadMonsters` to the never-initialized slot on the client's
  next load of the level (frozen ghost). Same shape as the live-instance overload: erase the
  `spawnedMonsters` entry + invalidate `deltaLevel.monster[id]`; bounds-checked against `GetMaxMonsters()`;
  no-op in SP. Vanilla-dead code with no mod loaded.
- **`DeltaLoadMonsters` / `DeltaLoadEnemies` extended-region gate (`Source/msg.cpp`).** Both loops now
  skip slots `i >= MaxMonsters` that have no `deltaLevel.spawnedMonsters` entry. A client can hold a
  monster[] record for an extended-region slot it never created (`delta_sync_monster` fills records from
  cross-level `CMD_SYNCDATA` traffic), and applying it to the never-initialized `Monsters[i]` manufactures
  a frozen ghost (or feeds debug asserts). Extended-region slots only exist while explicitly spawned —
  `spawnedMonsters` entries are only written by the `CMD_SPAWNMONSTER` receiver and the game-join delta
  import, so "no entry" proves "no monster". **Vanilla-invariant:** unmodded, `GetMaxMonsters() ==
  MaxMonsters`, the loop never reaches the gated region — dead code, byte-for-byte identical.

---

## Single-player Load-Game ally re-link (thin getters) — status: ready
A SP "Load Game" restores a mid-dungeon level with deployed golems still live (the level save serialises
every monster into the same slot ids), but the live-golem↔scroll-seed link lives only in the session-local
Lua `deployedAllies`. Two thin generic getters let `init.lua` rebuild that tracking on load (logic stays
in Lua — `relinkSavedAllies`):
- `monsters.fromId(id) -> Monster|nil` (`Source/lua/modules/monsters.cpp`) — active monster occupying
  slot `id`, membership-checked against `ActiveMonsters`; the stable save/load re-link key. Mirrors
  `getHovered`.
- `system.isMultiplayer() -> boolean` (`Source/lua/modules/system.cpp`, over `gbIsMultiplayer`) — the
  reliable SP/MP gate (player count can't distinguish solo-hosted MP from SP). The roster persists/applies
  **SP only**; MP allies replicate via the pipe.
- `system.isHellfire() -> boolean` (`Source/lua/modules/system.cpp`, over `gbIsHellfire`) — read-only
  gamemode gate, sibling of `isMultiplayer`. Stamps a tamed scroll's gamemode (packed in `item.modData`
  bit 22 — **never** `dwBuff` bit 0 = engine `CF_HELLFIRE`, read by `RecreateItem`/`IsDungeonItemValid`).

---

## Corpse cap interaction (no engine change, document) 
`Corpses[MaxCorpses=31]` (`Source/dead.cpp`); `corpseId` is a 5-bit field packed into `dCorpse`
(`(dv & 0x1F) + (dir << 5)`), so 31 is an *encoding* ceiling. **Mod-spawned monsters do not register a
corpse** — tamed allies/minions are gated by `OnMonsterCanPlaceCorpse` (vanish on death, no corpse), so
they never consume the table. `InitCorpses` only ever sees natural level types (well under 31) since
allies are recalled on level exit.
