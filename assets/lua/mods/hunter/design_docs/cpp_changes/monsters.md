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

## Player-target support for player-minions (`UpdateEnemy` / `GolumAi`) — status: ready
Reaches the `OnGolemCanTargetPlayer` hook (catalogued in `../lua_api_reference.md`). Two structural
changes beyond the call-out line itself:

- **`UpdateEnemy` player-scan unwrap (`Source/monster.cpp`).** Vanilla wraps the whole player loop in
  `if (!isPlayerMinion)`, so a minion never even considers players. The wrapper is removed and replaced
  by a per-candidate gate inside the loop: `if (isPlayerMinion && !lua::OnGolemCanTargetPlayer(...))
  continue;` (default **false**). **Vanilla-invariant:** for non-minions the gate never fires (loop body
  identical); for minions the default rejects every candidate, so no loop iteration writes any state
  (`menemy`/`target`/flags are only touched for an accepted candidate) — byte-for-byte the same outcome
  as never entering the loop. Mirrors the existing `OnGolemCanTargetGolem` gate in the monster loop.
- **`GolumAi` `MFLAG_TARGETS_MONSTER` gates (`Source/monster.cpp`).** `GolumAi` read
  `Monsters[golem.enemy]` in two places (the `OnGolemChooseAction` enemy forward and the melee/chase
  block) guarded only by `MFLAG_NO_ENEMY` — valid in vanilla because a golem's `UpdateEnemy` (re-run at
  the top of every `GolumAi` tick whenever `MFLAG_TARGETS_MONSTER` is clear, incl. after `M_StartHit`
  transiently wrote a player id) can only ever produce a monster target, so NO_ENEMY-clear implies
  TARGETS_MONSTER-set. Once a mod can grant a player target that implication breaks, so both reads now
  also require `MFLAG_TARGETS_MONSTER` (and the hook forward passes `&Players[golem.enemy]` as a new
  `enemyPlayer` argument when the flag is clear — the same dispatch `MonsterAttackEnemy` performs).
  **Vanilla-invariant:** the added flag check is redundant in vanilla (see the implication above), so it
  is dead weight with no mod loaded; a player target only exists via the hook.

No other engine change is needed: the player-target machinery is the code vanilla monsters already use
and is fully shared — per-tick `enemyPosition` refresh (`ProcessMonsters`), attack dispatch
(`MonsterAttackEnemy` → `MonsterAttackPlayer`), leave-level cleanup (`RemoveEnemyReferences`), and MP
enemy sync (`encode_enemy`/`decode_enemy` player offset) all key off `MFLAG_TARGETS_MONSTER`
generically. `GolumAi`'s melee/chase block deliberately stays monster-only — acting on a player target
is gameplay composition and lives in Lua (`OnGolemChooseAction` + the `monster:startAttack()` wrapper,
which forwards to the untouched vanilla `StartAttack` like the other `LuaStartMonster*` wrappers).

---

## Player-kill classification for a pet's melee killing blow — `OnGolemKillIsPlayerKill` — status: ready
The melee sibling of the missile-site change documented in `missiles.md` (same hook). In
`MonsterAttackPlayer` (`Source/monster.cpp`), vanilla calls `ApplyPlrDamage(..., dam)` with the
parameter's default `DeathReason::MonsterOrTrap`. The change adds, inside the existing
`if (&player == MyPlayer)` block, one `const DeathReason` ternary
(`(MFLAG_GOLEM && OnGolemKillIsPlayerKill(...)) ? Player : MonsterOrTrap`) passed as the (previously
defaulted) `deathReason` argument. `monster`/`player` are already the function's parameters; no signature
or control-flow change. **Vanilla-invariant:** the gate is `MFLAG_GOLEM`-only and defaults false, so a
wild monster / vanilla Golem hits `ApplyPlrDamage` with `MonsterOrTrap` exactly as before. Runs on the victim's own client (`&player == MyPlayer`), the only
place drops are generated; the reason then rides `CMD_PLRDEAD` to peers. Rationale (a pet is its
hostile owner's weapon → PvP ear drop, not a wild-monster item drop) and the "no killer id needed"
point are in `missiles.md`.

---

## `monster:checkQuestKill()` Diablo coverage (`Source/lua/modules/monsters.cpp`) — status: ready
The binding wraps `CheckQuestKill`, which handles every quest monster **except Diablo** — his quest
completion lives inside `DiabloDeath`, entangled with the game-ending sequence (player freeze,
level-wide kill, camera pan, `PrepDoEnding`). The binding now mirrors *just* the quest/progress side
effects for `MT_DIABLO`: `Q_DIABLO → QUEST_DONE` + `NetSendCmdQuest` + raising the local player's
`pDiabloKillLevel` (the union of vanilla's two sites: SP-only in `DiabloDeath`, local player in
`PrepDoEnding`). **Vanilla-invariant:** binding-only logic (`Source/lua`), no engine file touched,
`DiabloDeath` itself unchanged; the sequence-vs-quest *split* on death is the thin `OnMonsterCanEndGame`
hook (catalogued in `../lua_api_reference.md`).

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
- **`InitializeSpawnedMonster` owner-tile assert scoped to base-game slots (`Source/monster.cpp`).**
  The debug assert `!MyPlayer->isLevelOwnedByLocalClient() || (freePosition && position == *freePosition)`
  encodes a vanilla invariant: the level owner is the client that ALLOCATED the spawn tile, so on the
  owner the requested tile is free. Mod ally materialization (`monsters.netSpawnAt`, extended-region
  slots `>= MaxMonsters`) breaks the owner=allocator identity legitimately: level ownership follows the
  lowest player id on the level, so a client entering an occupied level takes ownership and THEN
  materializes another client's allies at wire positions that may be locally occupied (an ally mid-fight
  is adjacent to monsters by definition). The non-assert code already handles this (the Crawl fallback
  picks the next free tile; engine position sync converges). Fix: `monsterId >= MaxMonsters ||` prepended
  to the assert. **Vanilla-invariant:** debug-only, and unmodded `monsterId` is always `< MaxMonsters`
  (extended slots don't exist) — the clause is dead, the assert identical.
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
