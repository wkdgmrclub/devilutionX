# Net Sync — Ally Multiplayer Data Model

> **Status: shipped + two-client playtested (slot model, leash sync, and delta hygiene verified
> 2026-07-05).** The authoritative *mod-side* design reference for how tamed allies stay consistent
> across clients.
>
> **What lives elsewhere:**
> - The **engine code** this rides (the `CMD_LUAMSG` pipe, `netSpawnAt`, high-slot allocation,
>   mod-extensible monster arrays, the `DeltaLoad` extended-region gate, `makeGolem` owner param) →
>   `cpp_changes/net.md` + `cpp_changes/monsters.md`.
> - The **dated as-built log** → `HISTORY.md` → "Phase 10 — Net Sync".
> - Item-blob trade transport → `item_moddata.md`.
>
> This environment cannot build or run two clients (see `CLAUDE.md`); every "verify" item is for the
> user to run on a real multi-client game.

---

## 1. Architecture: two data planes, two audiences

The organizing principle the whole model falls out of.

**Plane 1 — combat-relevant live state → rides the engine spawn + the pipe → *everyone* gets it.**
What any client (Hunter *or* non-Hunter) needs purely to interact correctly: the monster exists, its
type/stats/HP/resistances, `MFLAG_GOLEM` + owner (so friendly-fire protection and hostile targeting
work). Expressed as **plain monster state**; requires zero Hunter logic on the receiver and is
**never stored** in anyone's save beyond the normal monster delta. This is "non-Hunters get just
enough, dynamically, not stored."

**Plane 2 — Hunter progression & cosmetic state → Hunter-only.** Kill counts, Bonded immunity/TRN
choice, Tamed/Bonded names, recovery registry. Two Hunters run an "open pipe": full dataset shared so
each sees correct names/outlines/Bonded FX and can trade. Carried by: the item blob (survives a
**trade** — see `item_moddata.md`), the generic Lua pipe (live cross-Hunter display), and the
per-Hunter save (owner's own persistence). **Never** sent to or stored by a non-Hunter client.

### Audience matrix

| Data | Hunter (owner) | Hunter (other) | Non-Hunter |
|---|---|---|---|
| Monster existence / type / stats / HP | ✅ | ✅ | ✅ |
| `MFLAG_GOLEM` + owner (friendly-fire / hostility) | ✅ | ✅ | ✅ |
| Applied resistances / AC / unique identity (combat) | ✅ | ✅ | ✅ as live monster state, **not** as Hunter data |
| Kill count / Bonded immunity / TRN choice | ✅ save | ✅ via pipe + trade-encode | ❌ never |
| Tamed/Bonded name, outline, infobox | ✅ | ✅ | ❌ generic monster only |
| Writes to save | ✅ own save | ✅ own save | ❌ never |

### Governing principles (from the user)
- **Clean implementation, minimal desync surface** over cleverness — fewer moving parts, single authority.
- **Level-scoped.** A client only needs to understand a tamed monster if it is on that level. No pipe
  traffic to off-level clients; a client *loading into* a level with deployed allies is synced on entry.
- **Collisions impossible by construction**, not merely improbable — unlimited independent players may
  tame and later play together.

---

## 2. The complete ally dataset

Everything is keyed by the scroll **`seed`** (the per-ally identity). Storage tiers: **encoded in the
item** (travels with the scroll), **session cache** (rebuildable), **per-Hunter save** (seed-keyed,
owner-local).

| # | Datum | Lives in | In the item? | Notes |
|---|---|---|---|---|
| 1 | `typeId` | `seed` bits 0–11 | ✅ seed | `seedToTypeId` |
| 2 | `uniqueTypeIdx` | `seed` bits 0–11 (`UNIQUE_SEED_FLAG 0x800`) | ✅ seed | `seedGetUniqueType` |
| 3 | charTag + scroll counter (uniqueness) | `seed` bits 12–30 | ✅ seed | `OHID % 128` + `scrollCounter` |
| 4 | `maxHp` | `dwBuff` bits 1–15 | ✅ dwBuff | |
| 5 | current HP (as `pct`) | `dwBuff` bits 24–31 | ✅ dwBuff | |
| 6 | `level` | `dwBuff` bits 16–21 | ✅ dwBuff | |
| 7 | `capturedDifficulty` | `dwBuff` bits 22–23 | ✅ dwBuff | drives stat scaling |
| 8 | display `name` | item `_iName` | ✅ item | derived from type + Tamed/Bonded status |
| 9 | kill count | `allyKillCounts[seed]` → save + **item blob** | ✅ blob | Bonded status + toHit bonus |
| 10 | Bonded immunity | `bondedImmunity[seed]` → save + **item blob** | ✅ blob | IMMUNE_* flag or `BONDED_AC` |
| 11 | Bonded TRN variant | `bondedTrn[seed]` → save + **item blob** | ✅ blob | rolled once (1–5) |
| 12 | recovery backup | `recoveryRegistry[seed]` → save | ❌ | Pepin safety net (owner-local, DM6) |
| 13 | base stats snapshot | re-derived from seed+dwBuff at deploy | partial | for share-divided buff |
| 14 | live slot ↔ seed link | `deployedAllies` / `deployedAlliesById` | N/A runtime | re-link key |
| 15 | tamed-in gamemode | `item.modData` bit 22 (+ `scrollGamemode[seed]`) | ✅ blob | `0`=Diablo `1`=Hellfire |

#9–#11, #15 travel with a traded scroll via the **item blob** (`item.modData`) — see `item_moddata.md`.
The earlier 32-bit `_iLuaData` / `TItem.dwLuaData` slot that did this was **removed** in favour of the
optional blob.

---

## 3. The slot model (how allies and natural monsters never contend)

Tamed allies are live engine monsters replicated to other clients over the pipe. Two rules keep the
engine's deterministic level generation and our dynamic allies from contending for a monster slot:

1. **Allies occupy slots above the natural-monster region.** Level generation caps natural placement
   below `MaxMonsters` (`totalmonsters ≤ MaxMonsters - 10`, monster.cpp), so any slot `≥ MaxMonsters`
   is free of natural monsters on every client. An ally placed there can never collide with another
   client's regenerated natural monster. Headroom reserved at load via `requestExtraMonsters(...)`.
2. **The receiver recreates the ally unconditionally at its slot.** Mirrors vanilla `CMD_SPAWNMONSTER`
   → `InitializeSpawnedMonster(slot)` (no occupancy check). Above the natural region the slot has a
   single writer, so overwriting a stale copy left by a prior occupant is always correct.

Engine support (`AllocateHighMonsterSlot`, the array-cap extension) → `cpp_changes/net.md`.

**Sizing:** the extended region holds `AbsoluteMaxMonsters (252) − MaxMonsters (200) = 52` slots. The
reservation covers the party worst case — every Hunter fielding a full deploy including a Skeleton
King AND a Hork Demon at full minions: `MAX_HUNTERS × (MAX_DEPLOYED_PER_HUNTER + 3 + 3) = 4 × 10 = 40`.

### Delta hygiene (the third rule)

Allies **never legitimately persist in any level's delta**: owners auto-recall on level exit, and peer
materialisation is always `RQ`→`SP`, never delta replay. But the engine's routine `CMD_SYNCDATA`
handler records monster position/hp into the delta **even on clients not on that level**
(`delta_sync_monster`), so every client passively accumulates records for ally slots it never
initialised. Left stale, those records get applied to uninitialised slots at that client's next level
load (`DeltaLoadMonsters`/`DeltaLoadEnemies`) → frozen ghosts, and in debug builds assert crashes.
Two layers keep this impossible:

1. **Active forget (delta cleanliness — records also export to joiners):** *an ally that stops
   existing is forgotten by every client's delta.* Recall/despawn: `RM|id|level` → off-level receivers
   invalidate via `monsters.removeDeltaSpawnedMonster(level, id)`. Death: every on-level witness
   invalidates locally in `OnMonsterDeath`, and the owner additionally RM-broadcasts for off-level
   clients (a monster-inflicted ally death broadcasts no `CMD_MONSTDEATH`, so nothing else reaches
   them). The RM receiver dead-guards (`hitPoints <= 0` → no-op) so a death-RM never disturbs a copy
   mid-death-animation.
2. **Load-side gate (the hard guarantee):** `DeltaLoadMonsters`/`DeltaLoadEnemies` skip extended-region
   slots with no `spawnedMonsters` entry (`cpp_changes/monsters.md`). Mod spawns never create such
   entries (pipe, not `CMD_SPAWNMONSTER`), so no stale record can ever be applied — covering every
   path where no message can be sent (owner quit-to-menu, client crash, lost RM).

### Leash (snapToPlayer) in MP

`snapToPlayer` is a **client-local** position write (no net command, no delta). The leash therefore
runs **symmetrically on every client** (`GameDrawComplete`): own allies leash to `player.self()`;
remote-owned allies (from `remoteAllies`) leash to *their* owner via `player.get(rec.ownerId)`, gated
by `isOnActiveLevel()` (skips owner mid-transition) and the same slot-alias guards as the orphan reap.
This is the engine's own MP monster model — each client simulates, `CMD_SYNCDATA` proximity sync
converges the residual tile or two. Accepted residual: the copies' distances can straddle
`LEASH_DISTANCE`, so one side may snap a beat before the other; divergence is bounded by the leash.

### Transport
The pipe sends `PT_MESSAGE` over the reliable, in-order TCP stream every in-game packet uses on every
backend (asio TCP; ZeroTier over lwIP via per-peer `SOCK_STREAM` + `frame_queue`;
`base_protocol::SendTo` → `proto.send`). Same sender → same peer → same connection, drained FIFO, so
messages from one owner (e.g. a recall `RM` then a redeploy `SP`) always arrive in send order — no
reordering or loss to design around.

---

## 4. Mod message types on the pipe

All cross-client behaviour rides **one** generic engine command (`CMD_LUAMSG`, see `cpp_changes/net.md`)
as `"<TAG>|args"` Lua message types the mod's own dispatch switches on. The engine never interprets the
payload. Receivers **level-scope** any slot-id payload (`player:isOnActiveLevel`) because monster slot
ids are per-level. Spawn bindings are **local-only** (no `NetSendCmdSpawnMonster`) — replication is
100% the pipe.

| Tag | Direction | Effect |
|---|---|---|
| `SP\|id\|species\|uniq\|diff\|x\|y\|seed\|owner` | owner → same-level peers | `netSpawnAt` (resolve species to the receiver's own `LevelMonsterTypes`) + `makeGolem(owner)` + record in `remoteAllies`. Idempotent via `monsters.fromId`. |
| `RQ` | joiner → all | on `OnLevelEnter`, same-level ally owners re-send their `deployedAllies` so a late joiner materialises them. |
| `DR` / `DF` | non-owner → level owner / back | non-owner deploy **request** / failure. The level owner is the single spawn authority (only it can allocate a slot). |
| `CO\|…` | owner → same-level | broadcasts an ally's final combat numbers + caster profile (28 fields) so every client computes damage / Bonded effects / infobox identically. **No client re-derives.** (DM1) |
| `RM\|id\|level` | owner → all | remove (recall / retame / level-exit / minion-cleanup / **death**): same-level peers despawn their live copy (guards: `isGolem && ownerPlayerId == senderId`, plus `hitPoints <= 0` → no-op for a death-RM); off-level peers invalidate their delta record for `level` via `monsters.removeDeltaSpawnedMonster` (see "Delta hygiene"). (N3) |
| `SD` | owner → present peers | item-blob (Plane-2 progression) keyed by seed, for a trade where the dropper is present. See `item_moddata.md`. |

Receivers track remote allies in the **Plane-1 runtime `remoteAllies[monsterId]`** record (peer-side
mirror; never saved; cleared on level change / `GameStart`); they do **not** enter `deployedAllies`
(Plane-2 stays owner-local). A remote observer reads ownership from `ownerPlayerId + isGolem`.

> **Why deterministic AI, not suppression:** an interim `OnGolemCanRunAI→false` peer-suppression froze
> allies on peers (engine sync carries position, not mode). The fix runs ally AI on *every* client like
> a vanilla golem, kept identical by the synced per-monster RNG (`monsters.aiRandom`) + owner-anchored
> hooks. Minion spawns (Skeleton King / Hork) are done by the **level owner** and replicated via `SP`.

---

## 5. Resolved decisions

Mechanism decisions were D1–D5 / work blocks N1–N6; data-model decisions were DM1–DM6. Consolidated:

- **Ownership transport (D1 / N1). ✅** Broadcast the golem conversion over the pipe (`SP` carries
  owner; `makeGolem(ownerId)` replays the conversion on peers). The conversion — not just a
  `goalVar3` stamp — must cross the wire; `goalVar3` is an overloaded AI scratch field, only safe as
  an owner store *because* the AI is switched to Golem.
- **DM1 — combat overrides → owner-authoritative, applied live, level-scoped. ✅** Static identity
  (type, unique, captured difficulty, owner, golem conversion) rides the spawn/`SP`. Dynamic values
  (max/current HP, resistance, AC) are computed **only by the owner** and broadcast as final numbers
  over `CO`; every receiver just applies to the live monster. Non-Hunter receivers apply-to-live only.
- **DM2 — trade payload. ✅** Plane-2 (#9–#11, #15) rides the **item blob** (`item.modData`), which
  survives the trade hot path; owner persistence rides the seed-keyed `luamoddata` save. See
  `item_moddata.md`.
- **DM3 / D3 — seed uniqueness → charTag + per-character monotonic counter + re-stamp on acquire. ✅**
  A seed's upper field is `[charTag (OHID % 128)][counter]`: the 7-bit charTag separates different
  characters' seed spaces (two fresh Hunters would otherwise both mint the identical counter-1
  starter-scroll seed and poison each other's seed-keyed caches over `SD`), and each character's
  persistent monotonic `scrollCounter` (never resets) separates their own scrolls. `OnItemPickedUp`
  re-keys a picked-up scroll into the new owner's seed space. A player never holds two scrolls with
  the same seed; cross-character collision requires a 1-in-128 tag match *and* an equal counter+type
  (and the pickup re-key still untangles any traded scroll). (A random 32-bit seed was rejected:
  birthday collision at ~65k scrolls across unlimited players.)
- **DM4 / N1-late — other-Hunter live view + load-in sync. ✅** The owner re-broadcasts Plane-1b
  combat values (same-level clients) + Plane-2 display (same-level Hunters) on deploy / state change /
  `RQ`. The spawn covers static identity for load-in; the pipe re-broadcast covers overrides/progression.
- **DM5 — non-Hunter suppression. ✅** Local-class check = `player.self().className == HUNTER_CLASS`.
  Two gates added (init.lua): `OnCustomItemRecreated` keeps the base "Tame Scroll" name for non-Hunters;
  `OnSavePlayerData` returns `nil` for non-Hunters → no `luamoddata` entry → save byte-identical to
  vanilla. See `cpp_changes/items.md` for the save-slot mechanics.
- **DM6 / D4 — recovery registry stays owner-local; live-remove via `RM`. ✅** A traded scroll's
  recovery becomes the new owner's concern from first deploy. `RM` despawns silently-removed allies on
  peers; since 2026-07-05 it is **also sent on ally death** — not to remove the live copy (every
  on-level client sims the death; the receiver dead-guards) but so off-level clients invalidate their
  delta record (see "Delta hygiene").
- **N4 — MP re-link on rejoin. RETIRED 2026-06-23 (premise void).** No ownerless allies persist on a
  level (all recalled to scroll form on level exit) and mod allies don't ride the engine delta in MP
  (pipe-replicated). Every rejoin/reload case is already covered: observer late-join → `RQ`→`SP`+`CO`;
  owner re-entry → fresh deploy; clean exit → recall + `RM`; SP mid-dungeon load → `relinkSavedAllies`;
  owner crash → Pepin "lost" recovery. The former departed-owner ghost caveat is closed (2026-07-05):
  `reapOrphanedRemoteAllies` removes live copies whose owner left, and the `DeltaLoad` extended-region
  gate stops stale delta records from ever materialising on a later load (owner quit-to-menu / crash
  included) — see "Delta hygiene".
- **N5 — XP attribution. ✅** Ally kills credit `Players[owner]` via `monster:tagForPlayer`.
- **N6 — recovery-scroll store-buy roundtrip. Verification-only** for a future MP playtest.
- **D2 — hostility source of truth.** Read existing engine player-team/hostility state where possible
  rather than broadcasting faction intent separately. (Relevant to the deferred PvP pet targeting in
  `roadmap.md`.)

---

## 6. Residual MP verification (playtest spot-checks)

The core net-sync round-trip is verified. Re-confirm opportunistically:

- **Same-unique deployment is per-Hunter, not global** — four Hunters → four distinct Skeleton Kings,
  one per owner; a single Hunter still can't field two of the same unique. Dedup scoped to the
  deploying Hunter's own `deployedAllies`, never a global "is this unique alive anywhere."
- **Interaction safety matrix** — Berserk / Doppelganger / Stone Curse stay blocked on *all* tamed
  monsters (own, friendly, even hostile pets); direct targeting + ordinary combat allowed on hostile
  pets only.
- **Hunter death drop** — verify which Ear type drops; confirm intended.
- **Deployed-monster sync** — all players consistently synced on dungeon-deployed monsters.
