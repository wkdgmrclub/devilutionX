# Development Notes — Active Task

> **The ONE live doc.** Exactly one task in flight at a time. When it ships, graduate it (hook rows →
> `lua_api_reference.md`, bindings → `lua_api_reference.md`, engine code+why → `cpp_changes/`, dated
> entry → `HISTORY.md`, subsystem reasoning → `net_sync.md`) and **delete it from here.** See
> `README.md`.

---

## ACTIVE: MP ally slot model — bring-up & netcode debugging

**State:** built, **not yet green** — high-slot allocation needs a compile pass; latest commit is
"Broken MP netcode". This is the current focus (Taming Diablo, the next roadmap item, is parked until
this is stable).

### The model (authoritative reasoning lives in `net_sync.md`)
Tamed allies are live engine monsters replicated to other clients over the Lua `SP`/`RQ` pipe. Two
rules keep them from contending with the engine's deterministic level generation for a monster slot:

1. **Allies occupy slots above the natural-monster region.** Level generation caps natural placement
   below `MaxMonsters` (`totalmonsters ≤ MaxMonsters - 10`, monster.cpp), so any slot `≥ MaxMonsters`
   is free of natural monsters on every client. Headroom reserved at load via
   `requestExtraMonsters(MAX_HUNTERS * MAX_DEPLOYED_PER_HUNTER)`.
2. **The receiver recreates the ally unconditionally at its slot.** Mirrors vanilla
   `CMD_SPAWNMONSTER` → `InitializeSpawnedMonster(slot)` with no occupancy check. Above the natural
   region the slot has a single writer, so clobbering a stale copy is always correct.

### As-built
- **Slot allocation** (`Source/lua/modules/monsters.cpp`): `AllocateHighMonsterSlot()` returns the
  first free-pool id `≥ MaxMonsters`; `PrepareSpawnSlot` uses it (deploy paths `spawnWithDifficulty` /
  `spawnUniqueAt`). Activated by `InitializeSpawnedMonster` → `EnsureMonsterIndexIsActive`.
- **Receiver** (`init.lua` SP handler): another player's ally → always `netSpawnAt(mid, …)` (clobber).
  Our own ally → keep the locally-spawned copy; recreate only if the level owner spawned it for us via
  `DR` and it isn't present yet.
- **Transport:** the pipe sends `PT_MESSAGE` over the reliable, in-order TCP stream all in-game
  packets use on every backend (asio TCP; ZeroTier over lwIP via per-peer `SOCK_STREAM` +
  `frame_queue`; `base_protocol::SendTo` → `proto.send`). Same sender → same peer → same connection,
  drained FIFO, so an owner's `RM` then `SP` always arrive in send order — no reordering/loss to
  design around.

### Open / to verify
- [ ] **Compile the high-slot allocation** and confirm `AllocateHighMonsterSlot` + the
      `requestExtraMonsters` reservation behave (the "needs compile" gap).
- [ ] **"Broken MP netcode"** — diagnose the current breakage; capture root cause here as it's found.
- [ ] **`snapToPlayer` MP behaviour is un-vetted** — never checked for other-client / late-joiner sync
      (whether the teleport replicates or is local-only). Trace before relying on it.

### When this graduates
- Slot-model reasoning → already belongs in `net_sync.md` (fold the two rules + transport note there).
- `AllocateHighMonsterSlot` / high-slot reservation engine code → `cpp_changes/net.md`
  (alongside the mod-extensible monster arrays).
- Dated entry → `HISTORY.md` under the Net Sync line.
