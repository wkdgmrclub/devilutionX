# Hunter Mod — Bug Tracker

Active and resolved bugs. New open bugs go to the top (under High); fixed bugs move to the bottom (under Fixed).

---

## High

*No open bugs.*

---

## Review backlog — MP/Lua subsystem audits (opened 2026-07-08; no visible bugs, fine-tooth comb)

The 2026-07-08 item-pipe audit found a whole CLASS of problem, not one bug: mechanisms hand-rolling
engine machinery on an unverified premise, plus guards defending against triggers nobody could name.
Every custom MP/Lua subsystem was built in the same style and deserves the same pass. **Method (apply
all four to each area):**
1. **Premise check** — any comment/doc line justifying a mechanism by citing an engine limitation
   ("the engine can't X", "CMD_Y was rejected because…") gets re-verified against engine source. The
   items lesson: the limitation was hallucinated; the engine carried the item fine.
2. **Native-overlap check** — before keeping any mod transport/registration, read the engine
   receiver it parallels end-to-end. If a vanilla command already does it (validation, replication,
   delta, dedup), ride the vanilla command and delete ours.
3. **Guard check** — every guard/comparison must have a NAMEABLE trigger (concrete sequence of events
   that produces the bad input). Can't name it → delete it. Reconciling against nameable loss (RS
   heartbeat) is fine; guarding against confusion is not.
4. **Consumer check** — every net message, cache table, and persisted field must have a live consumer
   list; orphaned or double-covered consumers die.

**Disposition rule:** an audit that finds a defect spawns a normal High/Low entry; an audit that
comes back clean gets a dated "audited clean" line here and the item is struck. One subsystem at a
time, in this order (highest state-loss risk × most accreted first):

**Status 2026-07-09 — ALL EIGHT AUDITS COMPLETE** (open bugs, if any, live under High as usual —
they are no longer audit scope). The Apoc spread/targeting fix
passed the two-client retest (entry moved to Fixed; Taming Diablo graduated to `HISTORY.md`). A1–A3
clean; A4 clean (delta-transfer premise verified in engine source); A5 defect fixed + symptom-guards
deleted 2026-07-09 (re-check = one panel-open floor trade); A6 relabeled as the primary load path
(renamed `rebuildHeldScrollModData`, dead leg deleted); A7 closed the unpersisted DR-window scroll
backup (pure Lua); A8 clean + the `OnSavePlayerData` reader hardening built (needs recompile).
**ALL AUDITS COMPLETE 2026-07-09** (A7 closed one gap — the DR round-trip window had no persisted
scroll backup; A8 clean + the reader hardening built). The review backlog is finished; this section is
now record-only.

### ~~A1. Ally spawn/remove/capture plane vs the engine's monster delta~~ — audited CLEAN 2026-07-08
**Audited 2026-07-08 — no redundant write, no unnameable guard, nothing to delete.** The verified facts,
so nobody re-derives them:
- **Q1 (double-written delta records): none.** Deltas are PER-CLIENT in devilutionX (each client keeps its
  own; joiners inherit one), and a mod capture/removal is silent — it never traverses the engine's death
  broadcast — so each client's own `removeAsKilled`/`recordDeltaKill` write is the SOLE writer of that
  record on that client. Premise verified in source: `LuaDeltaKillMonster` mirrors `delta_kill_monster`
  field-for-field (`position` + `hitPoints=0`, `msg.cpp` — nothing else is written by either).
- **The ally-spawn plane writes NO delta records at all**: `netSpawnAt`/`spawnAt`/`makeGolem` are
  local-only (the engine's `CMD_SPAWNMONSTER`, which fills `spawnedMonsters` + a live `DMonsterStr`, is
  deliberately unused — the settled level-local-typeIndex decision, `cpp_changes/net.md`). Allies persist
  by live resync (RQ/RS→SP), never at rest. The mod's `removeDeltaSpawnedMonster` calls are therefore pure
  HYGIENE: they erase `DMonsterStr` records that the engine's own cross-level sync traffic (HP corrections
  etc.) fills into ally slots — records only the mod knows are stale. Not redundant; sole eraser.
- **Q2 (CR-replay-on-RQ trigger): nameable, keep.** (a) The same-level CR receiver with NO live copy at
  arrival (id lookup fails mid-transition) records nothing — and blind-recording there is UNSAFE by
  design (the slot may have been legitimately reused by an ally SP; a blind delta-kill would clobber it),
  so the safe reconciliation point is exactly the requester's next level entry, when a regenerated ghost
  has a live non-golem hp>0 copy to test. All three guards in the replayed-CR branch are load-bearing on
  every healthy replay, not defensive cruft. (b) The receiver-failure class was OBSERVED in production
  (the `m.hitPoints` nil-compare killed CR receivers for two days; the replay bounded the damage).
- **Q3 (RM invalidation vs reaper): disjoint windows, no double coverage.** RM live-branch = the primary
  remover; RM `m==nil` branch = off-level delta hygiene (the reaper can't reach it — it only inspects
  live copies). The RS roster heals a lost RM only for a SAME-LEVEL owner (the RS receiver gates on
  `sender:isOnActiveLevel()`); the reaper's two branches cover exactly the windows RS cannot: owner left
  the GAME (no RS will ever come) and owner left the LEVEL (its RS is ignored here), debounced 2 passes.
  Each removal-loss window has exactly ONE healer. (This settles A2's removal side; A2 retains the
  presence side + cadence review.)
- Consumer check: `capturedNaturalMonsters` written at capture, consumed by the RQ answer, reset at
  GameStart — live, bounded, session-scoped. ✔

### ~~A2. The self-healing layer's coverage map (RS heartbeat + RQ replay + reaper + deploy timeout)~~ — audited CLEAN 2026-07-08
**Audited 2026-07-08 (presence side + cadence; removal side was settled by A1) — no triple coverage,
no vestigial healer, nothing to delete.** The verified facts:
- **Transport premise re-checked:** the pipe is reliable/in-order, so a "lost" one-shot in practice
  means a RECEIVER-side drop — the `sender:isOnActiveLevel()` gate rejecting a message while a
  player-level state lags, a mid-transition `remoteAllies` reset, or a handler error (the
  production-observed `m.hitPoints` class) — all nameable; true in-flight loss is not the trigger.
- **Presence loss-window → healer map: exactly TWO mechanisms, disjoint primary windows.**
  (1) *Peer arrives after the deploy* (was never sent an SP) → `OnLevelEnter` RQ (primary bootstrap;
  clears `remoteAllies` first, owners answer masked SP+CO pairs). (2) *SP gate-dropped on an on-level
  peer* → RS missing-diff → rate-limited RQ back → idempotent SP+CO resend; repeats every heartbeat
  until healed. A dropped RQ heals via the same RS-diff path on the next heartbeat. The reaper and the
  deploy timeout touch presence not at all (removal hygiene / requester-side scroll refund). A
  FALSE-positive reap self-corrects by design: the owner's next RS lists the id → missing-diff → RQ →
  idempotent SP. No window has a third consumer; both healers earn their keep.
- **One gap found and CLOSED (2026-07-08, pure Lua, no recompile):** a CO-only loss (SP applied, its
  paired CO eaten by a receiver error — the production-precedented `m.hitPoints` failure class) had no
  bounded healer; it healed only opportunistically on the next CO retrigger. Closed by extending the
  EXISTING RS missing-diff: a roster-listed id tracked in `remoteAllies` but with `profile == nil` now
  counts as missing → the same rate-limited RQ → the answer resends the SP+CO pair (SP side idempotent).
  No new mechanism, no new message — the heartbeat that already owns SP loss now owns CO loss too;
  detection latency ≤ one heartbeat. A CO merely in flight self-clears before the next heartbeat, so
  the check can't churn. (`net_sync.md` §4 RS row updated.)
- **Guard check:** the RS missing-diff's `not isDeployedAlly(id)` has a nameable trigger (a
  sender-listed id transiently aliasing our own STALE `deployedAllies` entry inside the one-frame
  isGolem-prune window); its suppression is bounded — the next heartbeat retries after the prune. Keep.
- **Cadence review — all justified, keep as-is:** `ROSTER_INTERVAL_TICKS = 50` (~2.5s) bounds
  presence/removal detection at ≤2.5s for ~20 B per Hunter per interval — negligible traffic. The
  RQ-back rate limit is one GLOBAL timestamp (not per-sender): two owners with simultaneous deficits
  heal one heartbeat apart — bounded, fine. `DEPLOY_TIMEOUT_TICKS = 100` (~5s) rides the SYNCED tick
  clock, and ticks only advance while every client processes turns — so "owner stalled >5s while the
  clock ran" cannot happen; the timeout fires only for a genuinely absent/never-answering owner, which
  also closes the "late SP after a self-refund" double-deploy from a stall (remaining late-echo edges
  are A7's scope). The reaper-cadence nit found here (sole frame-paced cadence in the layer) was CLOSED 2026-07-08
  by the `GameTick` migration: a new thin `GameTick` event now fires at the end of each engine
  game-logic tick (`GameLogic`, `diablo.cpp` — needs recompile), and ALL simulation-side upkeep
  (reaper — now every 10 ticks on the synced clock, debounce unchanged — RS heartbeat, deploy
  timeout, both leashes, stale-entry prune, buff-fingerprint recalc) moved onto it;
  `GameDrawComplete` keeps only render work (flash blink, floating infobox). Frames can span
  multiple catch-up ticks in MP, so the tick event is the correct domain for sim bookkeeping.

### ~~A3. CO message field-by-field (29 fields, ~157 B of the 255 B budget)~~ — audited CLEAN 2026-07-08
**Audited 2026-07-08 — every field has a live consumer, no engine-native overlap, no deletable
double-carriage.** The verified facts:
- **Engine-overlap check (fields 3–9, applied live to the monster):** the engine never syncs monster
  stat BASELINES — vanilla monsters read static species data; the engine wire carries damage events
  (`CMD_MONSTDAMAGE`) and position corrections only. A pipe-spawned ally materialises with species
  defaults on the peer, so the CO snapshot (maxHP/HP/minDam/maxDam/toHit/AC/resistance) is the only
  carrier of the owner's computed values. The DR path's owner-side HP pre-apply makes the follow-up CO
  apply idempotent, not redundant (CO also corrects every later recalc).
- **Consumer list (profile fields 10–29, all live):** `isMinion` → missile-scaling guard + kills-display
  guard; `bonded` → TRN gate, glow mirror, outline, and the one-shot promotion-Flash EDGE detect
  (prevProfile false→true — needs the explicit flag; a kills-derived recompute can't tell a fresh
  record from a witnessed transition); `bondedImm` → the pierce-vs-target-pet check; `baseMaxDamage` →
  the spell-scaling phys-buff strip + fbox base row; `sharePct`/`magicCurrent`/`resFire`/`resLight`/
  `resMagic` → elemental spell scaling (owner-computed, incl. uncapped res the receiver can't read);
  `trnVariant` → recolour index (owner's random roll); `nearBonded` → pre-Bonded flash;
  `baseMin`/`baseToHit`/`baseAC`/`baseMaxHp` → fbox base rows (pre-buff snapshot exists only on the
  owner); `kills` → remote-pet display name + infobox; `gamemode`/`areaLevel`/`ohId`/`ohName` → fbox
  provenance rows. Nothing orphaned.
- **Derivable-but-kept (3 fields, deliberate under DM1 "receivers apply, never re-derive"):** `isMinion`
  (from the SP's `parentId`), `bonded`/`nearBonded` (from `kills` + the live monster level). Cost ≈2 B
  each; keeping them keeps the own/remote profile struct uniform (`ownAllyProfile` builds the same
  shape live) and the promotion edge-detect explicit. Not cruft — recorded so nobody "optimises" them
  into receiver-side derivation.
- **The CO∩SD double-carriage suspicion (kills/gamemode/areaLevel/ohId/ohName) is answered: two
  disjoint windows, both earn their keep.** CO is the only reliable carrier for a LIVE pet's display —
  the receiver's `remoteAllies` record keeps no seed, and the consumed scroll's SD is not guaranteed
  cached (the held-scroll floods cover only scrolls IN inventory). SD is the only carrier for the
  AT-REST scroll (no live monster exists to hang a CO on). Same content, different key (monster id vs
  seed), different lifetime — not redundant transport.
- **Guard check (receiver):** sender level gate (per-level slot ids), `rec == nil` drop (SP not yet
  processed; healed by the SP/CO pairing + RS-diff), the <28-delimiter malformed return, and the
  `prevProfile` edge-detect (replay suppression) — all nameable, keep.
- **Budget:** ~157 B nominal + a player-name-bounded `ohName` stays comfortably under the 255 B cap. ✔

### ~~A4. `receivedBlobs` + join-time held-scroll SD floods~~ — audited CLEAN 2026-07-09
**Audited 2026-07-09 — nothing to delete; the decisive premise VERIFIED in engine source.** The facts:
- **The decisive question (late-joiner floor drops): the engine's join-time delta transfer DOES carry
  the blob store.** Verified end-to-end in `Source/msg.cpp`: `DeltaExportData` serializes
  `deltaLevel.modData` into every `CMD_DLEVEL` chunk sent to a joiner (`DeltaExportModData`,
  msg.cpp:2931); the joiner's `CMD_DLEVEL` import parses it (`DeltaImportModData`, msg.cpp:881);
  `DeltaLoadItems` restores the blob onto the recreated floor item at level entry (msg.cpp:1033). A
  floor scroll dropped before a client joins reaches that client with full identity through the
  VANILLA channel — no mod transport, no defect, nothing missing.
- **Recreate-order nuance (by design, don't "fix"):** in `DeltaLoadItems`, `item._iModData` is
  assigned AFTER `RecreateItem` (which fires `OnCustomItemRecreated`), so the recreate handler runs
  with an empty item blob — but `restampScrollPresentation` → `scrollKillsFor` ends its precedence
  chain with `items.getItemDeltaModData(currentDeltaLevel, seed)`, and the delta map is imported/live
  before `DeltaLoadItems` runs, so presentation resolves correctly.
- **`receivedBlobs` has TWO live readers, not one** (the A3 head-start note undercounted — the
  floor-copy presentation fix added the second): `scrollKillsFor` precedence #3 and the
  `OnItemPickedUp` re-key precedence #3. Its unique window: **held-scroll SDs (level −1) write no
  delta entry anywhere**, so `receivedBlobs` is the ONLY place a scroll identity announced while HELD
  lands — and it doubles as the cover for a drop-time SD eaten by a receiver error (the
  production-precedented failure class). Keep.
- **The two floods are NOT double coverage — they are the two DIRECTIONS of one bootstrap.** The
  `OnLevelEnter` unmasked flood PUSHES the arriving client's held-scroll identities to peers (a peer
  that was absent for the change-time announces has no other channel); the RQ-answer masked flood
  PULLS the present peers' held-scroll identities to the arriver (their pushes fired before it was
  present). A same-level trade pair is covered in both directions by whichever client arrived later.
  Deleting either opens a real window; neither is shrinkable. Re-fires per level change are idempotent
  last-write-wins cache refreshes (~≤50 B per held scroll) riding an RQ that must fire per level
  anyway (per-level ally slot ids). ✔
- **SD receiver consumer check:** writes `receivedBlobs` + `scrollOrigin` (OH cache) + the floor-item
  delta mirror (`setItemDeltaModData`, keeps OFF-level peers' deltas current at drop time — the engine
  transfer only covers the JOIN) + the same-level live-copy restamp. All four consumed. ✔

### ~~A5. Seed-space guards left from the collision era~~ — audited 2026-07-08 (defect → fixed); symptom-guards DELETED 2026-07-09
**Audited 2026-07-08.** Every clean inventory-entry path is collision-proof by construction: mints
(`allocSeed`) and `AutoGetItem`-pickups (restamp) stay behind `scrollCounter`; the hero save persists
counter + items atomically (load max-merges upward); Pepin buy-back restores seeds the counter already
covered; the stash is barred to scrolls (`OnItemAllowedInStash`). BUT both guards still have a nameable
trigger through one hole: **the cursor pickup path (`InvGetItem`, inventory panel open) never fires
`OnItemPickedUp`** — a scroll can enter inventory un-restamped (counter trigger: crash-rollback floor
scroll or a 1-in-128 charTag collision, then cursor-picked; gold trigger: ANY cursor-picked trade).
Both guards are symptom-patches over that root, whose fix is now BUILT + user-VERIFIED 2026-07-08
(see the cursor-pickup entry under Fixed).
**Disposition — DONE 2026-07-09: deleted BOTH the `OnLevelEnter` defensive `scrollCounter` bump and
the `scrollIsGoldTier` → `magical = 2` fixup (their only triggers died with the root), plus the
now-orphaned `scrollIsGoldTier` function itself (that fixup was its last caller; Pepin buy-back
stamps its stock tier inline). Re-check on next playtest: one panel-open floor trade.** (The third
thing in that handler, the per-held-scroll SD broadcast, is A4's question — untouched.)

### ~~A6. `healHeldScrollModData` (GameStart blob heal)~~ — audited 2026-07-09: it IS the primary path; renamed
**Audited 2026-07-09 — the "heal" framing was the mislabel the audit suspected.** Held-item modData is
deliberately never hero-saved (ItemPack frozen), so EVERY save→reload empties every held scroll's blob —
rebuilding it at `GameStart` from the `luamoddata`-persisted tables (`blobForSeed`) is the primary
load-time path, not a repair. **Renamed `rebuildHeldScrollModData` + re-commented as primary** (call
site, `item_moddata.md`, roadmap updated; historical records keep the old name).
**One dead leg deleted:** the absent-origin branch's "restore the trainer from the scroll's own blob if
it survived" — unnameable trigger: the sole call site is `GameStart`, where held modData was just
reloaded EMPTY from a save that never carries it, so the blob-read could never see data. The
load-bearing part stays: an absent/empty-named origin record is only ever our OWN creation (every
foreign acquisition writes `scrollOrigin` at pickup re-key, and the record is persisted), so it claims
the local Hunter — the verified starter-scroll behaviour is unchanged.

### ~~A7. DR/DF deploy-echo protocol completeness~~ — audited 2026-07-09, one gap CLOSED (pure Lua)
**Audited 2026-07-09.** The verified facts + the one fix:
- **Owner-side rejection coverage: every reachable rejection answers DF.** The DR receiver's
  `deployFail()` fires on requester-not-on-level, the owner-authoritative gate mirror (unique dup /
  cap), and spawn failure. Two deliberate silent returns remain, both named: not-the-level-owner (the
  real owner answers; nobody-owns → the requester's timeout refunds) and an unparseable payload (no
  seed to answer with; can't originate from our own fixed-format sender — timeout backstops). ✔
- **Late-echo double-refund/double-deploy: structurally closed by the turn-coupled pipe.** A late DF
  no-ops (`pending == nil` guard); a late SP after the ~100-tick timeout would require the owner's
  answer — sent within a turn or two of processing the DR — to arrive 100 PROCESSED turns later, which
  the in-order turn-coupled pipe cannot do (the same argument that already closed the stall case in
  A2: the synced clock only advances while every client processes turns). A post-LEVEL-CHANGE SP is
  rejected by the SP receiver's shared-level gate. `pendingDeploys` clears exactly once on every path:
  SP completion, DF, timeout, level-change refund, GameStart reset. ✔
- **Accepted transient (named):** a level change with an in-flight DR refunds the scroll while the
  owner-spawned copy stands on the old level for ≤2 reaper passes / one roster beat before the RS
  reconcile + orphan reaper remove it — a redeployed unique can briefly coexist with its dying
  old-level orphan. Bounded, self-healing, cosmetic.
- **GAP FOUND + CLOSED (pure Lua): the DR round-trip window had NO persisted backup.** The scroll is
  consumed at cast, `pendingDeploys` is runtime-only, and the recovery backup was written only in
  `finishDeploy` (after the SP echo) — so a quit-to-menu (which SAVES the post-consumption inventory)
  or app exit inside the round trip lost the scroll with no refund and no Pepin entry. **Fix:**
  `putRecovery(seed, …, "lost")` now fires at DR-request time (the moment the scroll leaves
  inventory); a completed deploy overwrites that same entry in `finishDeploy` (in-place update, no
  eviction), and **every refund path now deletes the entry** (`refundTameScroll` — also load-bearing
  for its floor-fallback branch, where the seed is NOT in inventory and a lingering "lost" entry would
  have stocked a DUPLICATE at Pepin). Eviction semantics unchanged — the request-time entry evicts
  exactly what the finishDeploy entry would have a tick later.

### ~~A8. Pepin recovery registry state machine~~ — audited CLEAN 2026-07-09 (+ the folded-in reader hardening BUILT, needs recompile)
**Audited 2026-07-09 — every exit path reconciles, no unreachable state.** The verified map:
- **Entry lifecycle:** created "lost" at deploy (`finishDeploy`; now also at DR-request time — see A7)
  → death upgrades to "injured" at full-HP dwBuff (owner-only, non-minion) → clean recall/retame
  deletes (both the retame path and the level-exit recall, after `refreshRecoveryEntry` refreshes HP)
  → full-inventory retame-recall flips to "lostfull" (kept, stocks free) → refund deletes (new) →
  Pepin buy-back self-cleans via the found-in-inventory sweep at `StoreOpened`. Quit/crash keep the
  persisted entry (that is the feature). All three states reachable and stocked (injured = paid,
  lost/lostfull = free); the load parser maps codes 0/1/2 exactly. ✔
- **Folded-in hardening BUILT (`Source/lua/lua_event.cpp`, needs recompile):** the `OnSavePlayerData`
  reader now distinguishes the END of the array (nil) from a NON-uint32 value and logs a loud
  `LogError` naming the index before dropping the remainder — the silent-truncation failure mode
  (top remaining suspect in the Low one-off empty-Pepin entry) is now attributable on sight.

---

## Low / Deferred

### Pepin recovery came back EMPTY once, after the CRASHED wild-Diablo session — did not reproduce; diagnostic on file
**Reported:** 2026-07-07: reloading the Hunter from the crashed session (2 allies deployed at the kill + 1 earlier death) → nothing at Pepin. Ruled out by code read: persistence cadence (60s MP hero writes incl. `luamoddata` — `pfile_update`), load parser (registry section parses early + guard-robust; later-section errors can't un-populate it), stocking (`encodeDwBuff` clamps sanely; the 4-entry eviction can't clear all). Top remaining suspect: the engine-side `OnSavePlayerData` reader (`lua_event.cpp`) **silently truncates the blob at the first non-uint32 value** — fragile, worth hardening someday.
**Downgraded 2026-07-07:** the clean wild-Diablo re-kill session (fixed init.lua) had every dead ally recoverable — the chain verified end-to-end; the one-off loss is attributed to the crashed session's Lua-error cascade. If it EVER recurs: watch debug output for `Lua error` (1) at character load (`OnLoadPlayerData`) and (2) at Pepin open (`StoreOpened`); no errors + empty stock → dig the save-side truncation.
**Hardening live 2026-07-09 (A8 fold-in, compiled + verified with the save-blob truncation fix):** the save-side reader no longer truncates silently — a float-typed exact uint32 is accepted, and a genuinely bad value logs a `LogError` with its index (see the A8 disposition), so a recurrence is attributable immediately. The suspected truncation mechanism was in fact CONFIRMED as a real bug (see Fixed → the save-blob truncation entry), which may well explain this one-off.

---

## Fixed

### Casting Tame on ANOTHER Hunter's deployed ally runs the wild-capture path — ally duplication (observed: two Diablos) ✓ (fix 2026-07-09, user-verified 2026-07-09)
**Reported:** 2026-07-09 (user): A tamed Diablo, traded the scroll to B, B deployed it; A then cast
Tame on B's deployed Diablo. On A: Diablo vanished + a duplicate Tame Scroll appeared. On B: Diablo
still alive AND the duplicate scroll visible → picked it up → TWO Diablos deployed, scrolls tradeable.
Not reproducible afterwards (the gates below explain why: it needs a WOUNDED pet in tier/category
criteria — a redeployed pet spawns at its saved HP, so a fresh redeploy is reliably capturable).
**Root (confirmed in source):** the Tame skill's action frame handles OWN allies (retame/recall,
`isDeployedAlly`) — but a REMOTE-owned ally matches nothing and falls straight through to the
WILD-monster capture path (a comment claimed "another player's ally → do nothing"; that branch was
unreachable). The capture then ran fully on A's client: local `removeAsKilled` (no golem guard
locally — A's copy vanished), a second `checkQuestKill`, a NEW scroll minted+floor-spawned (item
spawns replicate → B saw it too), and a `CR` broadcast whose receiver's golem guard rightly protected
B's live copy — split existence + a duplicated, fully functional scroll. The upfront
`OnCanCastSkill` gate explicitly passed all golem targets through, trusting the (nonexistent) no-op.
The same hole covered a vanilla Golem and a berserk'd wild (both carry `MFLAG_GOLEM`): capturable.
**Fix (pure Lua, two layers):** (1) action frame — after the own-ally retame block, `target.isGolem`
→ `ICantDoThat` + return: Tame never captures ANY player-minion (own ally = the recall above; the
vanilla Golem stays vanilla — never captured/converted). (2) `OnCanCastSkill` upfront — a golem
target that is not an own deployed ally refuses before the cast animation. **Deliberate rule (user
2026-07-09), not a side effect: a Berserk'd monster is PERMANENTLY untameable** — the engine's
`AddBerserk` sets `MFLAG_BERSERK|MFLAG_GOLEM` for the monster's remaining life (never cleared),
mutates its damage stats, and `CheckMissileCol` lets any monster missile hit a `MFLAG_BERSERK`
target regardless of faction, so a tamed ex-berserk would be a permanently friendly-fire-hittable
pet with corrupted stats. Rule documented in `hunter_class_design.md` → "Untameable targets".

### Deleted character's Pepin recovery (and all persisted Hunter state) rolls over into the next character created in the same app session ✓ (fix 2026-07-09, user-verified 2026-07-09)
**Reported:** 2026-07-09 (user, while testing with delete-and-recreate-same-name Hunters): the new
Hunter's Pepin stocked the DELETED Hunter's tamed-monster recoveries.
**Root (two halves):** the Lua runtime outlives characters within one app session, and (1) a NEW
character never fires `OnLoadPlayerData` (no `luamoddata` entry exists), so NOTHING reset the previous
character's persisted tables — `recoveryRegistry`, `allyKillCounts`, `bondedImmunity`, `bondedTrn`,
`scrollOrigin`, `scrollGamemode`, `scrollAreaLevel`, `scrollCounter` all carried over (only `myOhId`
and `pendingStatPts` had per-character protection); (2) the `OnLoadPlayerData` parser MERGED into the
existing tables instead of replacing them, so even switching between two SAVED Hunters in one session
blended the first one's state into the second. The new character's first save then PERSISTED the
rolled-over state into its own `luamoddata` — permanent. (Same-name is a red herring: OHIDs include a
creation timestamp, so the leak is identity-independent.)
**Fix (pure Lua):** one lifecycle function, `resetPersistedCharacterState()` — clears everything
`OnSavePlayerData` persists plus the identity/caches that shadow it (`tameScrollData`,
`pendingAllyRoster`, `pendingStatPts`, `scrollCounter = 1`, `myOhId = nil`) — called at BOTH character
boundaries: top of `OnLoadPlayerData` (load = replace, never merge) and top of the `OnCreatePlrItems`
Hunter branch, before the starter mint (a new character is the one boundary no load ever covers).
`GameStart` deliberately does NOT call it (loaded characters need their tables; it clears only
per-game transient state, as before).
**Cleanup note:** a character whose save already absorbed rolled-over state keeps it (it is
indistinguishable from legit data); delete/recreate once more on the fixed build for a clean slate.

### "Found:" shows Unknown after changing games + redeploying — the save blob silently TRUNCATED at the first Original-Trainer name ✓ (fix 2026-07-09 both sides, user-verified 2026-07-09)
**Reported:** 2026-07-09 (user). **Root (confirmed in source):** `packStringToWords` built each packed
name word with `b * (2 ^ (8 * j))` — and Lua 5.4's `^` ALWAYS yields a FLOAT. The engine's
`OnSavePlayerData` reader converts entries via sol's integer conversion, and this project defines
**`SOL_SAFE_NUMERICS 1`** (`3rdParty/sol2/sol_config/sol/config.hpp`), whose integer check is
SUBTYPE-precise: a float-typed whole number FAILS. So every save containing at least one scroll-origin
name truncated at the first name word, silently dropping everything after it in the blob: the
remaining origin records, ALL of `scrollGamemode` (Version:), ALL of `scrollAreaLevel` (Found:), and
the true-stat-points field. Everything BEFORE the origin section (kills, Bonded rolls, TRNs, Pepin
registry, roster, counter, OHID) always survived — which is why only "Found: Unknown" was visible
(origin loss was masked by the GameStart rebuild claiming the local Hunter — correct for self-tamed
scrolls; gamemode loss defaults to Diablo — correct in Diablo mode).
**Why it looked new only then:** the runtime tables used to mask the loss WITHIN an app session (game
changes reused the stale globals — the same mechanism as the character-rollover bug above); the
2026-07-09 load-replaces-never-merges fix made every game change re-read the (truncated) save.
Across app RESTARTS the loss was always live — the 2026-07-06 "starter scavenger blank OH name" and
"absent origin record" fixes were symptom patches over exactly this root (a truncation mid-origin-entry
leaves a record with an empty name; a truncation before it leaves no record).
**Fix (both sides of the boundary):**
- `packStringToWords` now uses integer ops (`w | (b << 8*j)`) — the ONLY float producer feeding the
  save table (all other writers audited: bindings, counters, `encodeDwBuff`, ids are integer-subtype).
- The engine reader (`lua_event.cpp`, with the A8 hardening) now ACCEPTS any number holding an
  exact uint32 value regardless of Lua subtype — the float/integer distinction is a Lua implementation
  detail and must never corrupt a save; genuinely bad values still LogError + drop.
**Data note (no back-fill, per the no-backwards-compat rule):** already-truncated saves stay truncated —
scrolls tamed before the fix keep "Found: Unknown" (and Diablo-default Version) forever; re-tame for
fresh data.

### Tamed Diablo's Apocalypse: pet-vs-pet booms landed on a DIFFERENT target per client and dealt ZERO damage; spread hit a shifting subset ✓ (fix 2026-07-09, user-verified 2026-07-09)
**Three root causes, all confirmed in source (the built design is in HISTORY.md "Taming Diablo"):**
1. **RC1 (zero damage): pet-vs-pet missiles were engine-undeliverable.** `CheckMissileCol`'s faction gate
   only admits a monster missile against a monster when `isPlayerMinion()` differs or a side is berserked —
   two tamed pets are both player-minions, so the boom NEVER entered the hit block (`OnMonsterMissileHit`
   never fired), on every client, authority included; `ProcessApocalypseBoom` re-collides every tick and
   never connects. The targeting layer (`OnGolemCanTargetGolem`) permits the fight the damage layer forbade;
   melee has no such gate, which is why melee pet-vs-pet always worked. **Fix:** new thin
   `OnGolemMissileCanHitGolem` gate (default false = vanilla) admits the pair under exactly the targeting
   rule (mutually-hostile owners); resolution rides the existing `OnMonsterMissileHit` owner authority.
2. **RC2 (different target per client): the golem MONSTER target LATCHES with no convergence channel.**
   `GolumAi` runs `UpdateEnemy` only when the golem has no monster target; the seek is deterministic but its
   inputs (mid-walk positions between near-equidistant candidates, roster timing) can transiently differ per
   client, and one divergent pick then sticks forever. This exactly explains the observed unstick: recalling
   the TARGET pets despawned both clients' latched enemies and forced a joint re-seek — nothing to do with
   stale profile data. Vanilla's `_menemy` sync can't heal it (both clients send their own latched view and
   mutually overwrite). **Fix:** `EN` owner-authoritative pet-target broadcast (on change + roster-beat
   re-assert), applied on peers via the new `monster:setEncodedEnemy` binding (the engine's own
   `decode_enemy` application). See `net_sync.md`.
3. **RC3 (missing/partial booms): the spread ran per-client over per-client state.** MP is not lockstep; the
   fan-out fired inside each client's own `AddMissile` reading local state (`allyScratch` primary-id, roster
   timing, `isActive`, LOS from possibly-diverged positions), so boom SETS legitimately differed per client —
   and a boom that doesn't exist on a player-victim's client deals that player no damage (player hits resolve
   victim-side, vanilla `PlayerMHit` semantics). **Fix:** owner-only fan-out (`isDeployedAlly` gate) +
   `AB` boom-tile replication to same-level peers; monster damage stays single-resolver (owner roll →
   engine `CMD_MONSTDAMAGE` broadcast), player damage resolves on the victim's client as vanilla does.
4. **Symptom 4 (two-shot damage) DISSOLVED — attribution error, no formula defect.** The post-unstick damage
   cannot have been booms (RC1: they never resolve vs pets); it was Diablo's **melee**, whose buffed min/max
   is `clampU8`-capped at 255/swing (`MonsterAttackMonster` deals the raw roll `<<6`). The "two-shot from
   1000+" magnitude is the vanilla monster-vs-monster damage model: BOTH clients sim the melee swing, each
   applies its own roll locally AND broadcasts `CMD_MONSTDAMAGE`, which the other side applies on top —
   ~2x per swing (up to ~510), two swings ≈ 1000+. A vanilla Golem's melee has the identical MP dynamic
   (barometer: this is base-game behaviour, not a mod defect). Named and accepted for melee; the missile
   path deliberately avoids it via the single-resolver authority. If pet-vs-pet melee ever needs balancing,
   that is a design decision against vanilla mechanics, not a bug fix — take it to the roadmap.
**Engine surface:** one thin gate hook in `CheckMissileCol` (sibling-mirrored, default false = byte-for-byte
vanilla) + two `Source/lua` bindings (`encodedEnemy`/`setEncodedEnemy` wrapping the engine's own
`encode_enemy`/`decode_enemy` + `IsEnemyValid`). Zero engine logic added.

**Original report (2026-07-08):**
**Reported:** 2026-07-08 (user, two-client, during the board-confirmation testing). Three symptom groups, likely one system:
1. **Missing booms:** sometimes the Apoc missiles don't visibly spawn AT ALL on a client; sometimes they do.
2. **Partial spread:** sometimes the spread hits every valid on-screen target, sometimes only one or two — a shifting subset, not a stable envelope.
3. **Hostile pet-vs-pet desync + zero damage (clean repro):** two Hunters hostile; A fields tamed Diablo, B fields Tamed Sir Gorash + Tamed Blood Knight. On A's screen Diablo spams Apoc at the **Blood Knight** and deals **ZERO damage**; on B's screen the same casts land on **Sir Gorash**. The boom should land on both (spread), but instead each client shows a different single target and nobody takes damage. **Follow-up same session: recalling + redeploying B's hostile pets UN-STUCK it** — after the redeploy Diablo's booms finally land and damage. So the zero-damage state tracks STALE per-pet roster/tracking state (the SP/CO-era records for the target pets on the resolving client), not the hit math itself — a redeploy rebuilds those records fresh on every client.
4. **Post-unstick, damage is WAY too high:** once landing, Apoc **two-shot Sir Gorash from over 1000 HP**. Diablo's owner is the WARRIOR-archetype Hunter wielding a **King's sword (inherent ~+100% damage prefix)** — the Deadly Hunter unique bow is on the OTHER Hunter and is not involved (user corrected initial report). The boom is Physical BY DESIGN ("rides min/max = the physical ally buff"), and the ally buff polls the owner's CHARACTER-SHEET effective damage (equipment included) — so the King's +dam% flows into the pet buff by design; the question is MAGNITUDE: two-shotting a 1000+ HP Bonded boss suggests a DOUBLE-application somewhere (buffed min/max fed into a path that buffs again, the Warrior-archetype damage-mod stacking on top, or the spread's `fireMissileAt` booms compounding on the primary's already-buffed roll). Verify the intended boom formula end-to-end with the owner's sheet damage as input.
(The original report's "stale roster records" read of the unstick was wrong — RC2's latch explains it: the recall despawned both clients' latched TARGETS, forcing a joint re-seek. The 2026-07-07 HP-corruption fix is untouched and not implicated; its owner-authority model is what the fix EXTENDS to the spread and to pet-vs-pet hits.)
**Retest 2026-07-09 — PASSED on these markers:** two-client hostile pet-vs-pet: both clients show Diablo attacking the SAME pet (EN convergence — allow ~2.5s worst-case after an engagement change); every cast shows the SAME boom set on both clients, landing on BOTH valid hostile pets; boom damage applies (HP down, never up) at single-resolver scale — a 1000+ HP Bonded boss survives several BOOMS (melee remains ~2x-per-swing by the vanilla monster-vs-monster model — expected, see item 4); kills credit correctly; hits keep landing WITHOUT a recall/redeploy of the target pets; spread against a wild-monster pack hits the full envelope identically on both screens; a spread boom on a hostile PLAYER now damages that player (new — AB puts the boom on the victim's client); SP (owner-only) unchanged; the peaceful case keeps current confirmed-good behavior (no boom ever resolves on a friendly/peaceful pet or a peaceful player's vanilla Golem).

### Hunter stat validation holistically broken (shifting max-stat totals 380–465, Rogue lock-in "invalid packet", join-time point loss ~189) ✓ (fix 2026-07-08, user-verified 2026-07-08)
**Two roots.** (1) The old freeze-at-current maxima model made `GetMaximumAttributeValue` spread/state-dependent, corrupting its consumers — worst: `UnPackPlayer` (`pack.cpp:349`) clamps the four base stats ONE AT A TIME against the partially-loaded struct, so once the earlier-loaded stats summed ≥ 460 a later stat was clamped to **0** (Rogue lock-in zeroed VITALITY at load → owner packed vit 0 → peers failed `_pMaxHPBase <= calculateBaseLife()` at `pack.cpp:608` = the "invalid packet"); also order-dependent debug give-stats (totals up to 550) and the char panel's per-draw `_pStatPts = min(CalcStatDiff, pts)` rewrite (`charpanel.cpp:166`). (2) `pStatPts` is **uint8** in both the hero save and net pack (`pack.h:51`/`102`) — a 445-point Forgetting refund wrapped to exactly 189 on save→load.
**Fix (the current model — do not relitigate):** budget-FORMULA maxima `max(attr) = clamp(attr + (460 − total), 0, 250)` in the `OnGetMaxAttributeValue` handler — pure function of own base stats, monotone-safe through the sequential load, golden freeze at exactly 460; `isMyPlayer` kept so REMOTE Hunters resolve TSV maxima at the join validator (a stale local copy would reject a legit respec). Debug give-stats always lands exactly 460; Forgetting always refunds exactly 375. True `_pStatPts` persisted past the uint8 via the writable **`player.statPoints`** binding + an `OnSavePlayerData` trailing field + `restoreStatPoints()` at GameStart (consume-once). Accepted cosmetic residual: a peer inspecting our char panel reads the wrapped net-pack byte for the points row. Legacy over-budget saves self-heal to exactly 460 on first load (mangled spread); one Forgetting refunds the full 375 — zero real loss.
**Same fix, user-approved retune:** archetype threshold sums 350 → 300, Sorc-lite 150 → 140 (Warrior 170/130 · Rogue 100/200 · Monk 100/50/150 · Barb 150/150 mag≤15 · Sorc 140) — every non-Barb dual now fits the 460 budget (Rogue+Sorc and Warrior+Sorc at exactly 460); skip-tier archetype rungs moved with the thresholds. Tables in `hunter_class_design.md`.

### Weapon attack-speed frames: Monk-archetype staff visibly slower than sword (Staff of Haste vs Sword of Haste) ✓ (fix 2026-07-08, user-verified 2026-07-08)
**Root:** the melee `OnGetAnimationSkipFrames` axis was purely STR-scaled with no weapon awareness — Monk-archetype staff ran the warrior sheet (16 frames, hit frame 11) at the STR-ladder rate instead of the vanilla Monk's 13/8; pre-fix sword and staff were equal in TOTAL ticks, the staff's later hit frame (11 vs 9) is what read as slower. **Fix:** Monk-archetype weapon override in the Attack branch — staff `max(ladder, +3)` → 13 ticks, unarmed/unarmed+shield `max(ladder, +4)` → 12 — the exact monk `animations.tsv` totals, additive with Haste like vanilla (staff of haste 13−4 = 9 ≡ 16−(4+3)). Weapon context = new readonly **`player.weaponGraphic`** binding (`_pgfxnum & 0xF`, synced equipment state). Verified needing NOTHING: axe (Warrior/Barb = the sheet's 20 exactly; vanilla Monk axe 23 ≈ the ladder at monk-typical STR), bow (rogue 12 = 16−4, already exact), sword/mace (STR ladder is the design — staff/unarmed is the monk identity).

### MP: a traded Bonded scroll's FLOOR copy read "Tamed"/white on the non-dropper until pickup ✓ (fix 2026-07-08, user-verified 2026-07-08)
**Root (two halves):** the item wire and the mod pipe share one in-order stream, so the non-dropper always recreated the floor copy BEFORE the drop-time SD blob arrived and nothing revisited it; and `scrollIsBonded` read kills from `allyKillCounts[seed]` only (empty for a foreign seed). **Fix:** `scrollKillsFor(item)` presentation-time kills source with explicit precedence (own tables → item's own `modData` → `receivedBlobs` → level-delta blob) now behind every presentation consumer; SD-receiver restamp of the live floor copy on a floor-item SD for the current level; new **`items.findFloorItemBySeed(seed)`** binding (live floor-item lookup). Off-level rides the delta (`DeltaLoadItems` → `OnCustomItemRecreated`); the late-JOINER delta question remains A4's scope.

### MP: cursor pickup (inventory panel OPEN) never fired `OnItemPickedUp` — restamp-on-acquire skipped entirely (found by audit A5) ✓ (fix 2026-07-08, user-verified 2026-07-08)
**Root:** `OnItemPickedUp` fired only from `AutoGetItem`; panel-open left-click routes `InvGetItem` (item to the HAND, then paste) — no re-key, no blob restore, no restamp, permanent identity loss after the picker's save/reload. **Fix (as specced):** `OnItemPickedUp` call-out in `InvGetItem` before `CleanupItems` (covers gold + to-hand branches and all three callers incl. the off-level `OnGetItem` echo); swap-drop `OnItemDropped` call-out after the `CMD_SYNCPUTITEM` send; **`player:heldItem()`** binding; the Lua handler checks the hand first for the live copy. Rejected (don't relitigate): hooking `CheckInvPaste` — can't distinguish acquisition from shuffle. **Residual:** the two A5 symptom-guards in `OnLevelEnter` (defensive `scrollCounter` bump + `scrollIsGoldTier`→`magical=2` fixup) were DELETED 2026-07-09 (see the A5 disposition); re-check = one panel-open trade.

### Diablo's Apoc Boom made enemy HP go UP ("500 health bars") ✓ (fix 2026-07-07, user-verified 2026-07-08 — original symptom confirmed gone)
**Root:** `OnMonsterMissileHit` had no client-authority gate — every client rolled `MonsterTrapHit` on the free-running global RNG and broadcast `CMD_MONSTDAMAGE` on a local hit, stacking on every peer's own roll; the boom's per-tick retry multiplied it. **Fix (pure Lua):** owner-authority gate in the handler — authority = attacker's owner if tracked ally, else victim's owner; non-owning clients return an explicit miss (no roll, no damage, no broadcast). Accepted residual: a bystander client may see a boom "miss" while the owner's client shows the impact. NOTE: the spread/TARGETING layer this gate exposed is fixed separately (the Apoc spread/targeting entry above).

### Diablo Tame Scroll presentation: needed full UNIQUE treatment (no "Lvl 30"; hover showed "The Butcher's Cleaver") ✓ (fix 2026-07-08, user-verified 2026-07-08)
**Root:** Diablo is the one quest monster that is NOT unique — his scroll rides the typeId seed path, and every unique-PRESENTATION switch keyed on `seedGetUniqueType(seed) >= 0` alone. **Fix (pure Lua, presentation-only):** `scrollPresentsAsUnique(seed)` (`= unique-seed OR seedIsDiablo`) swept through `buildScrollParams`, `OnCustomItemRecreated`, `OnPrepareUniqueInfoBox`/`setCustomUniqueBox` (custom box with `tier = "Boss"`), and `OnGetMonsterDisplayName` (ORs `monster.typeId == DIABLO_TYPE_ID`, covers own + remote allies). Paths needing a REAL unique index deliberately kept `uIdx >= 0` semantics (wire `uniq`, `CAT_DIABLO`, dedup, `recoverScrollData`).

### MP PvP: a Hunter killed by another Hunter's TAMED monster dropped items via the killed-by-MONSTER path ✓ (fix 2026-07-08, user-verified 2026-07-08)
**Fix:** new thin hook **`OnGolemKillIsPlayerKill(golem, player) -> bool|nil`** (default false = vanilla) at the two monster-sourced `DeathReason::MonsterOrTrap` sites (`CheckMissileCol` `PlayerMHit` dispatch + `MonsterAttackPlayer` melee apply), MFLAG_GOLEM-gated, flipping the enum to `Player` so the victim drops an ear (their own class ear, vanilla `StartPlayerKill`). Lua handler: true only for a tamed ally with a resolvable HOSTILE owner; runs on the victim's client (drops are generated there), reason rides `CMD_PLRDEAD` to peers. Vanilla Golem/wild monsters byte-identical (default false).

### MP debug assert: joining a level with another client's allies mid-fight (`InitializeSpawnedMonster` owner-tile assert) ✓ (fix 2026-07-07, user-verified 2026-07-08)
The assert encoded "level owner allocated this tile" — false for network-materialized ally spawns after an ownership handover; release builds were already graceful (Crawl fallback + position sync). **Fix:** assert scoped with `monsterId >= MaxMonsters ||` (extended-region ally slots exempt; vanilla slots keep the full invariant; unmodded the clause is dead). `cpp_changes/monsters.md`.

### MP: RM/CR receivers dead for every LIVE copy (`m.hitPoints` is not a binding) ✓ (fix 2026-07-07, user-verified 2026-07-08)
The hp guards read `m.hitPoints`; the binding is **`health`** → nil-compare threw → whole handler died (same failure class as bare-`log`). Both guards now read `m.health`. The self-healing layer had masked the loss.

### MP: deploying a UNIQUE from a session-recovered scroll crashed the SP broadcast (`recoverScrollData` has no typeId for uniques) ✓ (fix 2026-07-07, user-verified 2026-07-08)
Unique seeds carry no species typeId; the SP wire needs one for the receiver's `netSpawnAt`. `finishDeploy` + the DR receiver's SP echo now broadcast `monster.typeId` from the LIVE monster (mirroring the RQ resend); the DR sender sends `data.typeId or -1`.

### Monk-archetype Hunter crashed instantly entering any dungeon level (missing no-shield block animation) ✓ (fix 2026-07-06, user-verified 2026-07-08)
`OnPlayerCanBlockWithoutShield` set `_pBlockFlag` for shieldless combos, and `InitPlayerGFX` eagerly loaded a warrior `bl` sheet that only exists for shield combos → `app_fatal` (masked by the net-thread race). **Fix:** generic **`OnGetPlayerBlockGraphic(player) -> "Hit"|"Stand"|nil`** hook at the three engine sites equating "blocking" with the `bl` sheet (default `"Block"` = vanilla); mod redirects shieldless Monk-archetype block to the hit-recovery flinch with a `"Block"` skip of 4 (2 shown frames = vanilla lockout); new `player.isHoldingShield` binding. Every client computes the same flag (class+stat+equipment gate).

### MP: killing WILD Diablo → null-sprite assert during the ending ✓ (2026-07-07 — clean retest after the receiver fixes)
**Reported:** 2026-07-07 (accidental wild-Diablo kill while playtesting Taming Diablo): `clx_sprite.hpp:614 value_.data_ != nullptr` — a monster-type `AnimStruct.sprites` deref, i.e. an animation change on a species whose GFX were never loaded on this client; `DiabloDeath`'s kill-all (which force-plays Death on every monster on the level) is where such a poisoned slot dies loudly. The session ran with the `m.hitPoints` receiver bug + the unique-SP typeId bug active (entries under High at the time, now below) — heavy poisoned sync state of exactly the class that produces bad monster slots. Hook audit was clean (wild Diablo reads byte-for-byte vanilla through `OnMonsterCanEndGame`; every mod spawn path runs full `InitMonsterGFX`).
**Resolution:** re-kill of wild Diablo after those two Lua fixes → no assert; all allies died in the kill-all and were recoverable at Pepin. Resolved as fallout of the receiver fixes; the exact poisoned slot was never captured. If it EVER resurfaces on a clean session: breakpoints on `assert_fail` (`appfat.cpp:76`) + `DisplayFatalErrorAndExit` before reproducing.
**Kept from the dig:** the kill-all kills allies by setting the death animation directly, bypassing `MonsterDeath`/`OnMonsterDeath` (untracked deaths, roster holding dead slots through the ending pan) — addressed separately by the ally kill-all exemption (`OnDiabloDeathCanKillMonster`, built + verified 2026-07-08; `HISTORY.md` "Taming Diablo").

### MP: joining fails with "Player sent an invalid packet" when the host's Hunter has allocated stats ✓ (2026-07-06 — verified in two-client re-test)
**Reported:** 2026-07-06 (user): a debug-leveled Hunter with allocated (legal, in-bounds) stats makes the joining client fail with "invalid packets"; drinking a Potion of Forgetting (clearing allocations) lets the join succeed.
**Root cause (the appearance-hooks lesson, extended to DERIVED-STAT hooks):** `UnPackNetPlayer` (`Source/pack.cpp`) RECOMPUTES the incoming player's derived stats locally (CalcPlrInv) and validates them field-by-field against the packed values — `_pDamageMod`, `_pIAC`, `_pIMinDam/_pIMaxDam`, `getBaseToBlock`, etc. All the Hunter archetype hooks that feed those fields (`OnGetPlayerDamageMod`, `OnGetArmorLevelBonus`, `OnGetBlockChanceBonus`, `OnGetUnarmedDamageFloor`, `OnPlayerHasIronSkin`, …) were gated `isMyPlayer(p)` — so the OWNER computed them with the archetype formulas while the RECEIVER recomputed the same Hunter with vanilla formulas → mismatch → validation rejects the packet. With allocations cleared, no archetype threshold is met, both sides compute vanilla, join passes — exactly the Potion-of-Forgetting observation. (bugs.md had flagged `OnGetPlayerDamageMod`'s isMyPlayer gate as "review if needed" in the renderer-crash entry — this is that shoe dropping.)
**Fix (init.lua):** every archetype/derived-stat/animation hook now gates on CLASS (`p.className == HUNTER_CLASS`) — they read only synced state (class, stats, level), so a class gate is deterministic on every client. Converted: `OnGetAnimationSkipFrames`, `OnGetPlayerDamageMod`, `OnPlayerHasCriticalStrike`, `OnPlayerHasIronSkin`, `OnPlayerHasNaturalResistance`, `OnGetBowDamageMod`, `OnGetArrowVelocityBonus`, `OnPlayerCanBlockWithoutShield`, `OnGetArmorLevelBonus`, `OnGetHitRecoveryThreshold`, `OnGetUnarmedDamageFloor`, `OnGetBlockChanceBonus`, `OnPlayerHasArmorPierce`, `OnPlayerCanCleave`. **Exception (deliberate, commented in-code): `OnGetMaxAttributeValue` stays isMyPlayer** — it is an allocation-UI freeze, and `UnPackNetPlayer` clamps incoming base stats against `GetMaximumAttributeValue` BEFORE applying them; class-gating it would clamp a freshly-leveled joiner's stats against the receiver's stale copy. Remote Hunters must resolve the static TSV maxima there.
**Also fixed in passing:** UI-only gates stay isMyPlayer (item use, speedbook, Wirt, potions, shrines) — those are genuinely local.
**Status:** ✅ verified 2026-07-06 (joins clean with allocated-stat Hunters).

### MP: Pepin recovery missing on the REMOTE client for its dead allies ✓ (2026-07-06 — verified in re-test after the tracking fixes)
**Reported:** 2026-07-06 (user): the remote player had allies (the starter scavenger included) die in the dungeon and could not recover ANY of them at Pepin — plural, so the remote's whole recovery chain looks broken, not one bad scroll.
**Analysis:** the recovery chain is fully LOCAL to the owner — `putRecovery(seed, …, "lost")` at deploy, the `OnMonsterDeath` owner-branch upgrade to "injured" (requires the dying ally to be a TRACKED own entry with a seed), and the `StoreOpened` stocking from `recoveryRegistry` (skips silently only if `recoverScrollData` can't decode the stored dwBuff; drops an entry whose seed is found in inventory = "bought back"). No net dependence found — the prime suspect is the tracking desync this same session exhibited (5 deployed with 4 counted): an ally that dies while UNTRACKED takes the `entry == nil` path in `OnMonsterDeath` and its registry entry is never upgraded/announced. The deploy-time "lost" backup should still stock as a free recovery though, so if this reproduces after the tracking fixes it is NOT chaos fallout and needs its own dig (next suspects: the death-time `recoveryRegistry` upgrade writing a dwBuff `recoverScrollData` rejects, or the found-in-inventory cleanup eating entries).
**Status:** ✅ verified 2026-07-06 — resolved alongside the tracking fixes (roster heartbeat + gate/eviction batch); the exact failing leaf was never isolated. If it ever recurs, the splitter: (1) no "…has been defeated and can be revived at Pepin" message at death → tracking layer; (2) message but absent at Pepin → stocking path (check for a same-seed scroll in inventory — the intentional "bought back" drop).

### MP: remote's starter scavenger missing its OH (Original Hunter) tag ✓ (2026-07-06 — verified in re-test)
**Reported:** 2026-07-06 (user), same session as the over-deploy + Pepin failures, all centered on the starter scavenger. (OH is only rendered on the DEPLOYED pet's floating box — the scroll item shows none — so the pet box is the only observable.)
**Root cause (heal gap):** the pet box's OH line reads `scrollOrigin[seed]` with NO local fallback (`petFloatingBase` shows "?" when the record is missing). The starter scroll is the one scroll minted BEFORE the player exists (`OnCreatePlrItems`), and the `GameStart` heal (`healHeldScrollModData`) only filled an EMPTY NAME on an existing record — an ABSENT record (lost across a save→reload) was silently skipped, leaving the OH line blank forever. Related prior fix: "starter scroll shows blank OH name" (Fixed below) — same area; that fix handled empty-name, this handles record-gone.
**Fix (init.lua, `healHeldScrollModData`):** when a held Tame Scroll has NO origin record, restore the true trainer from the scroll's own modData blob if it survived; otherwise claim it for the local Hunter (only our own creation is ever record-less AND blob-less — a traded scroll always carried its trainer in the blob/SD). Then the blob is rebuilt as before.
**Status:** ✅ verified 2026-07-06. **CORRECTION 2026-07-09:** the true root of "record lost across a reload" was found — the save blob silently TRUNCATED at the first packed origin name (float-typed words vs SOL_SAFE_NUMERICS; see the "Found: Unknown" entry) — this fix and the blank-OH fix below were symptom patches over it; both remain as the claim-local fallback for a genuinely record-less own creation.

### MP: deploy gates ignored MP state — two Skeleton Kings at once, >4 allies per Hunter, and a unique scroll eaten with no refund ✓ (2026-07-06 — verified in re-test)
**Reported:** 2026-07-06 (user): (a) two Skeleton Kings deployed simultaneously (one Tamed, one Bonded); (b) more than 4 allies deployable per Hunter; (c) an El Chupacabra (unique champion) Tame Scroll consumed on deploy with no monster and no refund.
**Design rule (user-confirmed): one instance of a unique PER HUNTER** — regardless of Tamed/Bonded status or difficulty; Hunter A and Hunter B fielding their own copies of the same unique is fine. The gate's own-pets-only scan was therefore the RIGHT semantics; what failed was the state it reads and an error inside it:
1. **Double-deploy of the same unique by ONE Hunter = the gate scanning a desynced roster.** `isUniqueTypeDeployed` reads `deployedAllies` — if the first copy is alive but UNTRACKED (a DR deploy whose SP echo was lost or arrived after its `pendingDeploys` entry was gone; or the pre-fix stale-alias corruption from the same session), the gate legitimately finds nothing and the second scroll passes. Closed structurally, not by the gate: the roster heartbeat reaps an owned-but-unlisted copy everywhere, and the deploy timeout refunds the scroll of an echo that never completed — an untracked live copy can no longer persist to fool the gate.
2. **Cap constant didn't match the design:** the gate used `MAX_ALLIES = 8`, while every reservation (extra monster slots, extra species, `RECOVERY_CAP`) is sized on `MAX_DEPLOYED_PER_HUNTER = 4` — 8 deployed allies + minions can even exhaust the reserved slot pool. Fixed: `MAX_ALLIES = MAX_DEPLOYED_PER_HUNTER`; the DR path also enforces the requester's cap owner-side (counting its non-minion `remoteAllies`).
3. **The scroll-void: `seedGetUniqueType(nil)` runtime error.** Minion entries in `deployedAllies` have `seed = nil`, and the gate loop did `entry.seed % 4096` on them — an arithmetic-on-nil error that silently kills the running hook (same failure class as the old `OnGolemCanSelect` bare-`log` bug). Casting a unique scroll whose unique was NOT already out forces a full-array scan → first minion entry → error. In `OnCanCastScroll` that meant "gate silently allows"; in `OnSpellActionFrame` the error aborted the handler AFTER the engine had committed to consuming the scroll → no spawn, no refund, scroll gone. Exactly reproduces El Chupacabra with Skeleton Kings + raised skeletons on the field. Fixed: nil-seed guard in the loop.
The level owner additionally mirrors both gates authoritatively on the `DR` path, counted over the REQUESTER's pets only (`remoteAllies` filtered by `ownerId == senderId`): its unique already out → `DF`; at its cap → `DF`.
**Addendum (2026-07-06 retest — remote reached FIVE deployed, the starter scavenger among them; back to four after the scavenger died):** fourth hole found — the **DR round-trip window**. On a non-level-owner client an ally enters `deployedAllies` only when the SP echo returns, so scrolls cast during the round trip weren't counted by either gate (cap or duplicate-unique). Fixed: `pendingDeploys` (in-flight DR requests) now count as deployed in both gate sites (`countPendingDeploys`) and in `isUniqueTypeDeployed`; NOT counted by the buff share. The owner-side DF answers + timeout refunds from the earlier fix cap the pending set's lifetime. NOTE: the 5th being the STARTER scavenger, which also showed a missing OH tag and failed Pepin recovery (own entries), keeps a second suspect alive — the starter pet being deployed while UNTRACKED (an untracked ally is invisible to the count). If a 5th deploy recurs after this fix, check whether the extra pet responds to a recall cast (untracked ones don't).
**Additional void hole closed (DR path):** a non-owner deploy whose `DR` nobody answers (no live level owner, guard mismatch, lost message) used to hang forever in `pendingDeploys` — and a level change silently DROPPED in-flight requests. Now: the level owner answers `DF` for **every** rejection (including the sender-level guard), `pendingDeploys` entries are tick-stamped and self-refund after `DEPLOY_TIMEOUT_TICKS` (~5s) with a screen message, and a level change refunds instead of dropping.
**Status:** ✅ verified 2026-07-06 (per-Hunter unique rule + 4-cap holding; no scroll voids).

### MP: cross-client ally REMOVAL unreliable — leftover allies after the owner leaves the level, duplicate Leoric after off-level deploy/recall cycles ✓ (2026-07-06 — verified across re-test sessions)
**Reported:** 2026-07-06 (user). Two symptoms, one suspected theme:
1. When one client leaves a level (stairs or return-to-town after death), the staying client often keeps seeing the departed owner's allies standing there — the level-exit auto-recall's `RM`s are not taking effect.
2. Host idle in town; Remote on dlvl3 tames Leoric, then deploys → recalls → deploys him. Host then enters dlvl3: **two** Leorics (Remote sees one); recalling on Remote leaves Host still seeing two; clears only after everyone leaves and Host re-enters.
**Analysis so far (code-read, no smoking gun in the logic):** every receiver path reads correct: the `RM` receiver removes a live copy / invalidates the off-level delta; the `CR` receiver records the off-level kill; ally slots allocate exclusively in the extended region (`AllocateHighMonsterSlot`), so the `DeltaLoadMonsters`/`DeltaLoadEnemies` extended-region gate blocks ally delta ghosts at load; `CMD_LUAMSG` and `CMD_SYNCDATA` share one in-order stream and the engine receive path has no sender-level gating. The duplicate-Leoric evidence is consistent with **the CR kill record AND the recall RMs all failing on the town-bound Host**: no kill record → the natural (wild) Leoric regenerates from the level seed at Host's load = Leoric #1; RQ→SP materialises the tamed Leoric = #2; the later recall-RM also failing leaves both. Notably the only messages that ever mattered CROSS-level (CR, RM) are the ones failing, while same-level traffic (SP/CO/RQ) demonstrably works — suggesting a cross-level receive-side hole not yet identified, or send-time loss during the sender's transition window.
**Hardening landed now (init.lua):**
- `reapOrphanedRemoteAllies` also reaps a remote ally whose owner left the **level** (not just the game), debounced over consecutive passes — a lost RM can no longer leave a live copy standing on same-level peers (closes symptom 1's user-visible effect regardless of the transport question).
- The `trackDeployedAlly` stale-entry eviction (scroll-mislabeling entry below) removes the one state-corruption mechanism found in this session's chaos; it may have been feeding these symptoms too (a poisoned roster mis-recalls / mis-RMs).
**Self-healing sync layer (2026-07-06, after a second repro of the ghost Leoric):** one-shot messages structurally can't be trusted forever, so the mod now re-asserts state periodically instead (see `net_sync.md` §4):
- **`RS` roster heartbeat** (~2.5s, `system.gameTick()`-paced): each Hunter broadcasts the ally/minion slot ids it owns; same-level peers remove tracked copies not in the roster (lost RM with the owner still present — the case the reap can't cover) and RQ a resend for listed ids they're missing (lost SP). The SP receiver is now idempotent (an already-tracked live copy is kept, not clobber-reinitialised), so resends are safe; RQ answers now include minions.
- **Capture replay:** the captor logs its capture-removals per level (`capturedNaturalMonsters`) and replays them as `CR`s in every RQ answer — a client whose delta missed the kill (the suspected ghost-Leoric mechanism: the regenerated natural monster) reaps the live ghost on arrival and re-records the kill. The CR receiver's live branch gained an `hp > 0` guard so a replay never touches an already-dead copy.
**Status:** ✅ verified 2026-07-06 — with the self-healing layer in, no ghosts across sessions (removal on level exit + death-return, minion cleanup on owner level-change, no duplicate uniques); final session fully clean. The one-shot delivery question was never conclusively answered — the reconciliation layer makes it moot (any lost RM/SP/CR now self-heals within a heartbeat). If ghosts EVER resurface, note whether they clear within ~5s (heartbeat working; spawn-side issue) or persist (heartbeat failing — new information).

### MP: recalled scroll mislabeled — Skeleton King's Tame Scroll showed "Bonded Plague Beast"; deploy+recall self-healed ✓ (2026-07-06 — verified in re-test)
**Reported:** 2026-07-06 (user), immediately after the duplicate-Leoric session above. The scroll DEPLOYED the Skeleton King correctly (seed-derived identity intact); only the item's name/HP payload was another ally's.
**Root cause (mechanism found; trigger sequence not pinned):** `deployedAllies` entries hold the live monster by slot reference, and `trackDeployedAlly` inserted blindly. If a stale entry (whose monster is gone but which was never untracked — e.g. during the removal chaos above) shares its slot id with a NEW deploy, `deployedAlliesById[id]` gets overwritten but the ARRAY keeps both entries reading the SAME live monster. A later recall of the stale entry builds the scroll from `entry.monster` (the wrong, current occupant — a Bonded Plague Beast) while keeping `entry.seed` (the Skeleton King's) → mislabeled scroll that still deploys the right species; the next clean recall rebuilds the name = self-heal observed.
**Fix (init.lua):** `trackDeployedAlly` now evicts any existing entry under the same slot id from the array before inserting (one slot = one live monster invariant).
**Status:** ✅ verified 2026-07-06 (deploy/recall-heavy sessions, scroll names stayed correct).

### MP: tamed-monster floating infobox sometimes shows base stats as 0 (buffed stats correct) ✓ (2026-07-06 — verified in re-test)
**Reported:** 2026-07-06 (user); seen on both own and remote allies' boxes.
**Analysis:** the box's base column comes from `entry.base` (own; written by `snapshotAllyBase` in every deploy path) or the CO profile fields (remote; `(entry.base and ...) or 0` on the sender). No static path yields zeros for a cleanly tracked OWN ally — but a stale-entry slot alias (previous entry) makes the array and `deployedAlliesById` disagree, and a CO built from a poisoned entry carries wrong/zero base fields to peers. Plausibly the same root event as the scroll mislabeling.
**Also landed:** the DR receiver's `remoteAllies` record now stores `capturedDifficulty`/`uniqueIdx` (was `{ ownerId }` only — the level owner's own infobox for a requester's pet read difficulty 0 until the CO arrived); an idempotent SP resend keeps the cached CO profile (no infobox blank until the next CO).
**Status:** ✅ verified 2026-07-06 (resolved with the eviction + resend fixes; no zeros in later sessions).

### MP, Friendly Fire ON: Chain Lightning kept hitting a peaceful ally's pets after a hostile→friendly round-trip ✓ (2026-07-06 — verified in re-test)
**Reported:** 2026-07-06 (user): with FF on, friendly state initially respected; after toggling hostile (hits work, correct) and back to friendly, chain lightning kept hitting the other Hunter's pets.
**Root cause (coverage gap, not stale state):** the direct-target veto (`OnMissileCanTargetMonster` → `arePeaceful`) reads the LIVE `friendlyMode` flags and did recover on re-friend — but the FF-on collateral-path veto swept **only `deployedAllies` (own pets)**. A peaceful other-Hunter's pet was never in the path check, so a bolt could be aimed straight past it and the FF-on damage layer (vanilla `MonsterMHit`; `OnPlayerMissileCanHitGolem` deliberately returns nil with FF on) hit it in the path. The hostile round-trip only mattered positionally: during the hostile phase the pets closed in on the caster (retaliation), so afterwards they sat in the caster's firing lines — before it they idled out of them. Intended design (confirmed by user): the crawl must not pick a target when ANY protected allied pet is in the way, a friendly Hunter's pets included.
**Fix (init.lua):** `ownAllyNearPath` → `friendlyAllyNearPath` — the sweep now covers own deployed allies AND tracked remote allies whose owner is at peace with us (same slot-alias guards as the reaper); a hostile owner's pets stay fair PvP game. Own ∪ peaceful-remote is the same protected set on every mutually-peaceful client, so the veto stays cross-client symmetric. FF-off behaviour unchanged (path veto still skipped; the damage layer makes the line safe).
**Status:** ✅ verified 2026-07-06 (final session: FF veto behaviour correct through hostile→friendly round-trips).

### MP: owner quitting to menu with allies deployed leaves ghost golems for peers ✓ (2026-07-05 — verified in two-client re-test)
**Reported:** 2026-07-05 (user; the last residual sibling of the recall/death delta bugs, reproduced deliberately: owner quits to menu with allies deployed → a peer later loading that level sees ghost golems).
**Root cause:** quit-to-menu skips `OnLevelExit`, so the auto-recall never runs and no RM is ever broadcast — and a quitting (or crashing) client can never be relied on to send anything. Off-level peers keep the routine `delta_sync_monster`-accumulated records for the departed owner's high slots; on their next load, `DeltaLoadMonsters`/`DeltaLoadEnemies` apply them to never-initialized slots — the same poisoned state as the recall/death bugs. Message-based hygiene structurally cannot close this hole; the fix must be on the LOAD side.
**Fix (engine, 2 lines, vanilla-invariant):** `DeltaLoadMonsters` + `DeltaLoadEnemies` (`Source/msg.cpp`) skip extended-region slots (`i >= MaxMonsters`) that have no `spawnedMonsters` entry. Why that's exactly right: allies never legitimately persist in any level delta (the owner auto-recalls on level exit; peer materialization is always RQ→SP, never delta-replay), and mod spawns never create `spawnedMonsters` entries (they ride the pipe, not `CMD_SPAWNMONSTER` — verified: the only inserters are the `CMD_SPAWNMONSTER` receiver and the game-join delta import). So an extended-region record with no spawn entry describes a monster this client never created — applying it is what manufactures the ghost. Unmodded, `GetMaxMonsters() == MaxMonsters` and the gate is dead code — byte-for-byte vanilla.
**Defense-in-depth:** this also makes the recall/death ghosts structurally impossible even if an RM is ever lost. The RM/death invalidation machinery stays for delta hygiene (records still export to joiners).
**Same-level peers:** already handled — `reapOrphanedRemoteAllies` removes live copies whose owner left, and `remove()` invalidates the local delta.
**Status:** ✅ verified 2026-07-05 (deploy, owner quits to menu, peer enters the level → no ghosts).

### MP: host hard-crashes entering a level where a peer's deployed ally died (debug assert masked by a net-thread race) ✓ (2026-07-05 — verified: crash gone in re-test)
**Reported:** 2026-07-05 (user, two-client test: Remote alone on a dungeon level, its deployed ally dies there; Host then enters the level → Host crashes with an unhandled `std::array<net::base::PlayerState,4>` subscript-out-of-range on the net turn thread (`SNetGetTurnsInTransit`, `base.cpp:554`), no error dialog shown).
**The visible crash is a MASK, not the bug.** This codebase redefines `assert` → `assert_fail` → `app_fatal` (`appfat.h:21`). `app_fatal` → `FreeDlg()` (`appfat.cpp:53`) calls `SNetLeaveGame` **without stopping the net turn thread** (the clean quit path `multi.cpp:821` runs `nthread_cleanup()` first), which resets `plr_self = PLR_BROADCAST` (255, `base.cpp:497`), then sits in `SDL_Delay(2000)` before showing the dialog. Within that window the still-running turn thread indexes `playerStateTable_[255]` → the observed secondary crash, pre-empting the real "assertion failed (file:line)" dialog. (Vanilla shutdown race, loud in debug builds; not mod code.) Capture recipe if a masked fatal ever resurfaces: breakpoints on `assert_fail` (`appfat.cpp:76`) + `DisplayFatalErrorAndExit` (`appfat.cpp:63`) before reproducing.
**Root-cause state (= residual sibling 1 of the ghost bug below):** nothing invalidated an off-level peer's delta record when an ally DIED. Death sends no RM; a monster-inflicted kill doesn't even broadcast `CMD_MONSTDEATH` (only player kills do), so the off-level Host kept a stale position/hp record (filled by routine cross-level `delta_sync_monster`) for a slot it never initialized. At the Host's level load, `DeltaLoadMonsters`/`DeltaLoadEnemies` applied it to the uninitialized slot — the same poisoned state as the recall-ghosts, which the debug build's assert tripwires then hit.
**Fix (pure Lua; reuses the RM/`removeDeltaSpawnedMonster` machinery from the ghost fix):** one uniform rule — *an ally that stops existing (recalled OR dead) is forgotten by every client's delta.* In `OnMonsterDeath`: every on-level witness of a tracked ally/minion death calls `monsters.removeDeltaSpawnedMonster(myDeltaLevel, id)` locally, and the OWNER additionally `broadcastRemove(id)` so off-level clients invalidate via the RM receiver's monster-not-found branch. The RM receiver gains a dead-guard (`m.hitPoints <= 0 → return`) so a death-RM never `remove()`s a copy mid-death-animation on an on-level peer. Bonus: local invalidation also stops a dead (corpseless) ally's wrong corpse from re-materializing on level re-entry (`DeltaLoadMonsters` bypasses the corpse hook).
**Known accepted corner:** a hostile *player* killing another Hunter's ally sends `CMD_MONSTDEATH` from the killer while the RM comes from the owner — different senders, so an off-level third client could receive them out of order and keep a kill record. Cosmetic-level risk; revisit only if seen.
**Status:** ✅ verified 2026-07-05 (re-test: no crash). The primary assert's exact identity was never captured — the fix removes the state class it fired on, and the `DeltaLoadMonsters`/`DeltaLoadEnemies` extended-region gate (quit-to-menu bug, High) now makes it structurally unreachable.

### MP: frozen "golem ghost" artifacts on a late-arriving client after a peer deployed + recalled allies ✓ (2026-07-05 — verified in two-client re-test)
**Reported:** 2026-07-05 (user, two-client test: Remote deployed several allies in the dungeon and recalled them while Host stood in town; when Host later entered the level, frozen golem-like figures stood on tiles at the allies' old positions — invisible on Remote. Re-deploying allies that reused those slots cleared the ghosts).
**Root cause (traced end-to-end):** the engine's routine `CMD_SYNCDATA` handler records monster state into the delta **even for levels the receiver is not on** (`OnSyncData` → `delta_sync_monster`, `sync.cpp`/`msg.cpp`) — so while Remote's allies were deployed, town-bound Host was accumulating valid position/hp delta records for their high slots. On recall, Remote invalidates its **own** delta (`remove()` → `LuaDeltaRemoveSpawnedMonster`) and broadcasts `RM` — but Host's RM receiver found no live monster (`monsters.fromId` nil, Host off-level) and only cleared `remoteAllies`, leaving Host's delta records stale. When Host then loaded the level, `DeltaLoadMonsters`/`DeltaLoadEnemies` (`msg.cpp`) applied each still-valid record to `Monsters[slot]` — high slots that were **never initialized** on Host (no `spawnedMonsters` entry → `DeltaLoadSpawnedMonsters` recreates nothing) — writing position fields and `occupyTile`-ing the tile: a `dMonster` entry pointing at an uninitialized slot = frozen rendered ghost. Redeploy clearing them confirms the mechanism: `netSpawnAt` clobber-reinitializes the reused slot.
**Fix (one generic C++ delta helper + RM carries the level):**
- `Source/msg.cpp`/`.h` — new overload `LuaDeltaRemoveSpawnedMonster(uint8_t level, size_t monsterId)`: by-slot-id, no live instance, for a client not on that level; erases `spawnedMonsters` + invalidates `deltaLevel.monster[id]`. The exact sibling of `LuaDeltaKillMonster` (the CR/capture equivalent). SP no-op.
- `Source/lua/modules/monsters.cpp` — binding `monsters.removeDeltaSpawnedMonster(level, monsterId)`, next to `recordDeltaKill`.
- `init.lua` — `RM` payload is now `RM|id|level`; the sender's level rides in `myDeltaLevel`, a new global cached at `OnLevelEnter` (OnLevelExit-time RM broadcasts need the **departing** level, but `items.currentDeltaLevel()` reads `plrlevel`, already the destination by then). The RM receiver's monster-not-found branch now calls `monsters.removeDeltaSpawnedMonster(level, id)` before clearing `remoteAllies`. Trust model mirrors the CR receiver's `recordDeltaKill` (no live monster to ownership-check). No in-flight race: same-sender `CMD_SYNCDATA` and pipe messages share one in-order TCP stream, and a removed ally leaves `ActiveMonsters` immediately, so no sync packet for the slot can follow its RM.
**Residual siblings (both since resolved):**
1. **Ally dies (not recalled) while a peer is off-level:** CONFIRMED 2026-07-05 as the host hard-crash; fixed + verified — see the entry above.
2. **Owner quits to menu with allies deployed:** CONFIRMED 2026-07-05 (ghost golems); fixed via the `DeltaLoadMonsters`/`DeltaLoadEnemies` extended-region gate — see the entry under High.
**Status:** ✅ verified 2026-07-05 (deploy + recall on Remote while Host in town, Host walks in → no ghosts).

### MP: `snapToPlayer` (tamed-monster leash teleport) is not synced ✓ (2026-07-05 — verified in two-client test)
**Symptom:** the snap-to-player leash that keeps tamed monsters close to their Hunter was not synced in MP.
**Root cause:** `snapToPlayer` (`Source/lua/modules/monsters.cpp`) is a **purely client-local** write — `dMonster` cells, the three position fields, mode/animation, light; no net command, no delta record. And the leash (`GameDrawComplete`, init.lua) only iterated `deployedAllies` — the **owner's own** allies; the old comment even asserted "remote allies are owner-positioned, not leashed here", i.e. the design *assumed* the owner's snap would propagate. It never does: after an owner-side snap the two clients' copies disagreed by > `LEASH_DISTANCE` tiles, and the only reconciler was the engine's slow LRU-scheduled `CMD_SYNCDATA` proximity sync (`sync.cpp`, closer-client-wins) — the same fight that produced the late-joiner zap.
**Fix (pure Lua, init.lua `GameDrawComplete`; no C++, no protocol change):** run the leash **symmetrically on every client**, matching the engine's MP monster model (each client simulates; engine position sync converges small residual divergence). New block before the own-ally early-return: for each `remoteAllies` record, resolve the live monster (`monsters.fromId`) with the same `isGolem` + `ownerPlayerId == rec.ownerId` slot-alias guards as `reapOrphanedRemoteAllies`, resolve the owner via `player.get(rec.ownerId)`, and if the owner `isOnActiveLevel()` and `distanceTo(owner) > LEASH_DISTANCE`, `snapToPlayer(owner)`. `isOnActiveLevel()` skips the owner-mid-transition window; `remoteAllies` never contains a vanilla Golem (barometer-safe).
**Status:** ✅ verified 2026-07-05 (two-client test: Host saw Remote's zombie snap to the Remote player). **Accepted residual (engine model, not a bug):** the two copies' distances to the owner can straddle `LEASH_DISTANCE` (one client's copy just inside, the other's just outside), so one side may snap while the other holds until the engine's proximity sync converges them — observed once as a delayed remote-side snap. Reconvergence is bounded by the leash itself: divergence can't exceed snap range for long.

### MP: remote Hunter's starter scavenger shows the HOST's name as OH (starter-scroll seed collision) ✓ (2026-07-05 — verified in two-client test)
**Symptom:** Create a new Hunter, join an MP game as the remote client: the starter scavenger's stat box shows the **host's** name/ID as its Original Trainer.
**Root cause (cross-character seed collision):** `scrollCounter` starts at 1 for *every* character, so every fresh Hunter's starter scroll got the identical seed (`1*4096 + MT_NSCAV = 4112`). On join, the host answers with `broadcastScrollData` for every Tame Scroll it holds (its own seed-4112 starter scroll included); the remote's `SD` handler stores `scrollOrigin[4112]`/`receivedBlobs[4112]` keyed by seed, **overwriting** the origin the remote stamped at creation → `originForSeed` (stat box + `CO` broadcast) resolves to the host. Wider than the display: the blob-restore fallback on drop/re-pick and the floor-item delta/`DI` shared-seed identity were exposed to the same collision. (Same lineage as the earlier *session*-local `nextScrollSeed` collision below, but **cross-character** — the "keep scrollCounter ahead" self-heal can't fix two legitimately coexisting scrolls on different characters.)
**Fix (`init.lua` only — global seed uniqueness, user-chosen over an SD ownership guard / join-time re-seed):** `allocSeed` now mints `[7-bit charTag = OHID % 128][12-bit counter][12-bit type]` (31 bits, signed-int32 safe), so different characters mint from disjoint seed spaces. The `OnLevelEnter` defensive counter bump decomposes the upper field and only tracks scrolls with **our** charTag (foreign-tag scrolls can't collide and no longer inflate the counter). Docs: `hunter_class_design.md` encoding + `net_sync.md` DM3/dataset table updated (the old "collisions impossible by construction" claim was wrong — counters alone never separated characters).
**Residual (accepted):** two characters can still collide at 1-in-128 tag odds *and* an equal counter+type; the pickup re-key untangles traded scrolls regardless.
**Retest note:** scrolls minted before this fix keep their old-layout seeds (upper field = bare counter) — retest with freshly created Hunters.
**Status:** ✅ verified 2026-07-05 (two-client test: fresh remote Hunter's scavenger shows its own name as OH).

### MP: a Hunter rendering ANOTHER Hunter crashes the renderer (appearance hooks gated to the local player) ✓ (verified 2026-07-05)
**Symptom:** Two-client MP, both Hunters. A is in dungeon L1; B loads into the level → **A crashes** (`clx_sprite.hpp:123 spriteIndex < numSprites()`, preceded by repeated `getFrameToUseForRendering: Invalid ticksSinceSequenceStarted_ -128`). Reproduces with **no deployed tamed monster** — it is the **Hunter class itself**. Works in single-player (you only ever render your own Hunter).
**Root cause:** the crash is rendering a **remote player's Hunter sprite**, not a monster. The Hunter is a ranged class that **starts with a bow**, and its bow-equipped dungeon idle sprite has only **8 frames** — so the mod overrides `_pNFrames` to 8 via `OnGetPlayerIdleFrames` (the engine hardcodes the same for native Warrior/Barbarian; SetPlrAnims `player.cpp`). But that handler (and `OnGetPlayerArmorGraphic`) was gated `if not isMyPlayer(p)` → the override applied **only to the local Hunter**. When a client renders a *remote* bow-Hunter, the override is skipped, `_pNFrames` stays at the higher `hunter/animations.tsv` idle value, and rendering its idle animation indexes past the 8-frame bow idle sprite → assert. (`-128` is incidental: the engine's join message-buffer pause froze logic ticks while rendering continued, so the already-bad idle frame got drawn repeatedly.)
**The general lesson:** `isMyPlayer(p)` is correct for **action** hooks (only the local player acts) but **wrong** for **appearance/rendering** hooks — every client renders *every* player, so those must be gated by **class**, not by local-player.
**Fix (Lua only, init.lua):** `OnGetPlayerIdleFrames` and `OnGetPlayerArmorGraphic` now gate on `p.className == HUNTER_CLASS` instead of `isMyPlayer(p)`, so they apply to every Hunter on every client. Local behaviour unchanged (the local Hunter is still a Hunter); remote Hunters now resolve the correct idle frame count + Light armor sprite.
**Not caused by the net-sync work** — this is a pre-existing custom-class-in-MP bug that surfaces any time two Hunters share a level; it was masked earlier by the monster-spawn crashes that fired first.
**Same-pattern hooks NOT changed (not crashes — review if needed):** `OnGetAnimationSkipFrames` (attack/cast skip timing — a remote Hunter's attack animation renders without the local skip; cosmetic, no overflow) and `OnGetPlayerDamageMod` (combat math, computed on the acting client). Flag if remote attack animations look off.
**Status:** ✅ verified 2026-07-05 (two-Hunter MP sessions, host + remote sharing dungeon levels, no renderer crash).

### MP: joining a level with a deployed tamed monster crashes the renderer (cross-client `typeIndex` is level-local) ✓ (verified 2026-07-05)
**STATUS (fix, two layers, verified 2026-07-05):** **Layer 1 (spawn/type)** — fixed; the joiner now correctly renders the ally (verified in test: golem→scavenger morph + blue outline). **Layer 2 (animation desync)** — a second crash surfaced the moment the owner's ally began to move/attack: `getFrameToUseForRendering: Invalid ticksSinceSequenceStarted_ -128` (repeated) → `clx_sprite.hpp:123`. Cause: `ProcessMonsters` runs each active monster's AI on **every** client (DevilutionX monster AI is deterministic-across-clients + corrected by sync), but our `GolumAi` behaviour is driven by Lua hooks that read the **owner-local `deployedAllies`** — empty on a peer — so the peer's copy made *different* AI decisions, diverged from the owner, and the conflict with the owner's position sync corrupted the animation. **Interim fix (`OnGolemCanRunAI→false` to suppress peer AI) was REVERSED** — suppressing the AI fixed the crash but FROZE the ally on peers (the engine sync carries position, not mode/animation), which became **Bug #1**. The proper fix (deterministic personality AI on all clients) is now built — see **"Tamed allies freeze on peers in MP …" under Fixed**. `OnGolemCanRunAI` the engine hook stays (generic, default true); the mod no longer registers a handler.

Layer-1 detail: Resolved via **Option 1 — mod-owned spawn over the generic pipe** (user-chosen). The mod's monster-spawn bindings (`spawnAt`/`spawnWithDifficulty`/`spawnUniqueAt`) are now **local-only** — they no longer broadcast `NetSendCmdSpawnMonster` (so the level-local `typeIndex` never crosses the wire → the crash can't happen). Cross-client allies are replicated over the pipe keyed by the globally-stable **species id**: new engine binding `monsters.netSpawnAt(monsterId, typeId, uniqueIdx, difficulty, x, y, seed)` registers the species into the *receiver's own* `LevelMonsterTypes` (loads GFX) and recreates the monster at the agreed slot id (reuses `InitializeSpawnedMonster` + `EnsureMonsterIndexIsActive`; no level-owner gate). Lua: a `SP|…` pipe message carries the ally's identity (sent on deploy to same-level peers, and re-sent on demand); receivers `netSpawnAt` + `makeGolem(owner)`. A `RQ` message sent on `OnLevelEnter` asks same-level owners to (re)send their allies, so a client joining *after* a deploy still materialises them (small load delay, acceptable). Each client builds its own natural monster set; the owner's extra allies sync on top. No vanilla wire/save format changed. **Remaining (follow-ups, not crashes):** live-remove broadcast (a recalled ally lingers as a ghost on peers until their next level reload — N3); engine-spawned **minions** of a non-natural species still ride `SpawnMonster`'s `NetSendCmdSpawnMonster` and could hit the same crash (narrower; deploy allies — the reported case — are fixed); only the level owner can deploy (pre-existing `PrepareSpawnSlot` gate).
**Symptom:** Two-client MP. Hunter A enters a dungeon level and deploys a Tamed monster. Client B then enters that same level → crash. Asserts seen: `clx_sprite.hpp:123` (null sprite) + log `getFrameToUseForRendering: Invalid ticksSinceSequenceStarted_ -128`; and (same run / downstream) `std::array<PlayerState,4>::operator[]` out-of-range on the **network thread** in `SNetGetTurnsInTransit` (`dvlnet/base.cpp:554`) — memory corruption cascading from the bad spawn.
**Severity:** critical for MP. The crash is in the **engine spawn/render path**, so it fires for **any** joining client — including a **non-Hunter** visiting a level where a Hunter has a pet deployed. MP is unusable with a deployed ally until fixed.
**Root cause (cross-client monster-type index mismatch):** A monster's graphics are keyed by `monster.levelType` = a **level-local index into `LevelMonsterTypes`** (the per-level type table, built in monster-add order during level generation). For a mod-spawned tamed monster:
- On the **deploying client**, `monsters.spawnWithDifficulty`/`spawnUniqueAt`/`spawnAt` call `EnsureMonsterType(species)` (`Source/lua/modules/monsters.cpp`) which registers the species into *that client's* `LevelMonsterTypes` (+ `InitMonsterGFX`) and returns its local index, then `NetSendCmdSpawnMonster(..., typeIndex, ...)` broadcasts that **local index** (also stored in the `spawnedMonsters` delta).
- On the **joining client**, that level was generated independently and the tamed species is **not** in its `LevelMonsterTypes` (it's not a natural monster there). The received `typeIndex` therefore resolves to a different/empty slot. `InitMonster` (`Source/monster.cpp:196`) sets `levelType = typeIndex` and calls `changeAnimationData(Stand)` → reads a **null/garbage sprite** from `LevelMonsterTypes[typeIndex]` → `clx_sprite.hpp:123` assert + invalid animation frame, then heap/array corruption surfacing on the net thread.
Vanilla never hits this: every vanilla dynamic spawn (golem, King's skeletons, Hork spawns) is a type **already present on the level on all clients** (deterministic generation), so `typeIndex` matches everywhere. Our mod is the first to spawn an **arbitrary species not naturally on the level** and broadcast it.
**Not caused by build #2 (the `MG` golem-conversion pipe).** The spawn broadcast (`NetSendCmdSpawnMonster`) predates it; the `MG` message rides on top. Build #2 (peer golem-conversion) merely surfaced this by being the first real two-client test of a deployed ally. It is a **prerequisite** for N1, not a follow-up: a peer must be able to register/render the monster type before any ownership/conversion is meaningful.
**Fix direction (design decision — user chose option 1):** the wire/sync must carry the **species** (`_monster_id`, globally stable) so each client resolves its **own** local `LevelMonsterTypes` index via `EnsureMonsterType` (register + load GFX locally). Two candidate approaches:
1. *Mod-owned spawn over the generic pipe (preferred, no vanilla format change):* stop using `NetSendCmdSpawnMonster` for mod spawns (local-only spawn); broadcast a pipe `spawn` message carrying species + unique + difficulty + slot id + position; each receiver spawns locally (registers type/GFX) at the same slot id, then applies the `MG` conversion. Engine handles ongoing position/HP sync of the now-existing monster; late-join/reload re-creation rides the DM4/N4 owner re-broadcast (already planned). Keeps the vanilla spawn cmd / save / delta byte-for-byte unchanged.
2. *Generic engine spawn-cmd generalization:* carry `_monster_id` in `TCmdSpawnMonster` + the `spawnedMonsters` delta and resolve to a local index on receive. Fixes live + delta + reload in one place, but **changes the engine spawn wire/save layout** (vanilla-compat concern) — weigh against the byte-for-byte-vanilla rule.
**Status:** ✅ verified 2026-07-05 (MP sessions with deployed allies + clients joining occupied levels, no crash).

### MP: summoner allies (Skeleton King / Hork Demon) jitter — minion CAP in the deterministic spawn roll ✓ (2026-06-25 — verified 2026-07-05)
**Symptom / found by:** flagged while auditing whether minions inherit the ally sync fixes. Same *class* as the idle-jitter bug below, but summoner-specific.
**Root cause:** the per-summoner minion cap `countMinionsOfParent(ally.id) < MAX` was part of the **shared spawn roll** that must be deterministic across clients (the king's raise pose / the Hork's Hork-Spawn missile fires on EVERY client in lockstep). But that count is **not** a pure function of synced state: a minion exists on the level owner at its spawn tick, yet on peers only when the replicating `SP` message arrives (network-delayed). During that window `countMinionsOfParent` is unequal across clients → the roll's `< MAX` gate diverges → divergent AI control flow AND divergent RNG consumption (Lua short-circuits `aiRandom` when the count gate fails, so `aiRandom` was drawn on some clients but not others) → summoner jitter + phantom/missing raise poses. (`init.lua` `OnGolemChooseAction`, Skeleton King + Hork Demon branches.)
**What minions DO inherit automatically (verified, no change needed):** they're tracked in `deployedAllies`/`remoteAllies`, so they flow through `OnGolemIdle` (the tick-deterministic wander fix), `allyOwner`, the `SP` recreate + engine `MonsterSeeds` `aiSeed` sync (slot-id keyed), `RM` removal, death-visual, and `CO` combat-override broadcast (`adoptOwnMinion`/`broadcastAllCombatOverrides`). The cap-in-the-roll was the one summoner-side decision that isn't auto-inherited.
**Fix (`init.lua` only):** make the **roll cap-free** — `hasTarget && dist >= MIN && aiRandom(100) < CHANCE` — a pure function of synced state (positions lockstep-synced, target via `menemy`, `aiRandom` synced per tick), so `aiRandom` is drawn identically on every client and the raise pose / missile fires in lockstep. Enforce the **cap authoritatively at the owner-only spawn site**: the Skeleton King's `isLevelOwnedByLocalClient()` block (`countMinionsOfParent < SKELKING_MAX_MINIONS`), and the Hork's missile **landing** (`OnGolemMinionMissileSpawn`, `< HORK_MAX_MINIONS`). The owner's count is authoritative so it never over-spawns (even across several in-flight Hork missiles). Cost: at cap a summoner still plays the (harmless) raise pose / fires a missile that lands without spawning — deterministic and minor, versus an unsyncable count in the roll.
**General principle (same as the idle fix):** a decision that must agree across clients cannot depend on network-timed state (minion existence via `SP`); keep the shared roll a pure function of synced inputs and push any network-timed constraint to the single authority (level owner).
**Status:** ✅ verified 2026-07-05 (MP re-test pass: summoners in lockstep, no jitter).

### MP: deployed allies jitter/zap on a late joiner (cached AI decision made at a join-dependent tick) ✓ (2026-06-25 — verified 2026-07-05)
**Symptom:** After the delta-kill fix below made the owner's allies finally appear on a late joiner, the allies "bugged out" — twitching/vibrating and **zapping all over the place** — and monsters (e.g. two zombies) appeared dead on one client but alive on the other ("desync fiesta"). Surfaced now because before the delta fix the allies never materialised on the joiner, so only ONE client ran their AI; with both running it, the divergence showed.
**FIRST (WRONG) THEORY — recorded so we don't repeat it:** that the per-monster `aiSeed` wasn't synced because our two spawn paths passed different `seed` args to `InitializeSpawnedMonster` (owner `GetLCGEngineState()` vs joiner the scroll seed). **This is FALSE.** The engine **already keeps `aiSeed` synced**: `MonsterSeeds()` (`multi.cpp:230`) runs once per game tick inside the lockstep turn handler (`multi.cpp:728`) and **re-bases every monster's `aiSeed` from `(sgdwGameLoops, slotId)`**, where `sgdwGameLoops` is the synced lockstep tick counter — and a late joiner is initialised to the current value (`ParseTurn`, `multi.cpp:263`). So at any tick, monster `i`'s `aiSeed` is identical on every client (incl. late joiners), keyed only on slot id, regardless of spawn time. The `InitializeSpawnedMonster` seed is overwritten every tick and only affects the initial animation frame. **DevilutionX is a deterministic lockstep sim** (`nthread.cpp` turn exchange) — this is why monster AI RNG is sync-able at all.
**ACTUAL root cause (cached decision at a join-dependent tick):** with `aiSeed` synced and the slot id matched (delta fix), the AI still diverged via a value that was computed once and **cached** at a client-specific tick. `OnGolemIdle` (`init.lua`) picked a wander spot via `monsters.aiRandom` and cached it in the per-ally scratch. `aiRandom` is synced *per tick*, but the owner cached its spot at deploy-tick while the late joiner cached at join-tick → different tick → different `aiRandom` → spots up to `2*ENGAGE_RADIUS` (=18) tiles apart → the two copies walked to different places and the proximity position sync (`sync.cpp:157`, *closer* client wins) fought between them = the zap. Enter-together worked because both cached on the same tick. (The "respawned" zombies were the separate delta-kill issue fixed below + ordinary vanilla late-join natural-monster phase wobble, not this.)
**Fix (the lockstep CLOCK, not a new RNG channel):**
- New generic engine getter **`system.gameTick()`** (`Source/lua/modules/system.cpp`; exports `sgdwGameLoops` via `multi.h`) — the synced lockstep tick counter, identical on every client incl. late joiners. Mod-agnostic, read-only, zero logic.
- `OnGolemIdle` (`init.lua`) now derives the wander offset as a **pure function of `(gameTick bucketed by IDLE_REPICK_TICKS, slot id)`** via a new arithmetic `syncedHash` — no caching. Every client (incl. a late joiner that started simulating the ally on a different tick) computes the SAME spot at the same tick, so the copies agree and the position sync has nothing to correct; bucketing holds the spot for ~24 ticks so it doesn't change every frame. Removed all `idleTarget` scratch caching.
- Kept `SyncSpawnSeed` (slot-id seed for `InitializeSpawnedMonster`) as a minor init-animation-frame sync; **corrected its comments** to stop claiming it drives AI sync (it doesn't — `MonsterSeeds` does).
**General principle (now in the `allyScratch` comment):** for deterministic-AI-everywhere, never cache a per-tick AI *decision* in per-ally scratch — the own (`deployedAllies`) and remote (`remoteAllies`) records are populated at different ticks, so a "first-use" cache desyncs. Express cross-client decisions as pure functions of `system.gameTick()` (+ a stable id) instead. Engine-synced inputs (`aiSeed`, `menemy`, player positions via lockstep) need no transport.
**Status:** ✅ verified 2026-07-05 (MP re-test pass: late-join allies track smoothly, no zapping).

### MP late-join: captured wild monster ghosts on the joiner AND the owner's deployed allies don't appear (delta slot invalidated instead of killed) ✓ (2026-06-25 — verified 2026-07-05)
**Symptom (two-client, late-join ordering):** Remote joins Host's game, goes to a dungeon level **first** (becoming the level owner), kills/tames monsters, and deploys 2 Bonded allies. Host **then** enters that level. Host sees **none of Remote's deployed allies**, and there is a **ghost enemy monster attacking on Host but not on Remote**. The earlier "both clients enter together" test worked because that exercised the **real-time deploy** path (live `SP` broadcast to clients already on the level), never the **late-join** path (level delta + one-shot `RQ` resync).
**Root cause (one bug, two symptoms — engine delta):** taming a wild monster removed it via `target:remove()`, whose binding records the MP removal with `LuaDeltaRemoveSpawnedMonster` → it **invalidates the delta slot** (`position = {0xFF,0xFF}`, `msg.cpp`). That is correct for a *dynamically spawned* monster (absent from level-gen, so a late joiner should skip it), but **wrong for a level-natural monster**: on a late join, `DeltaLoadMonsters`/`IsMonsterDeltaValid` **skip invalid slots**, so the joiner regenerates the wild monster from the level seed and it stays **alive = ghost**. (A properly *killed* monster instead gets `delta_kill_monster` → `hitPoints 0` at a **valid** tile, so the joiner reaps its regenerated copy.)
- **Why the allies also vanish (same root cause, via id reuse):** captured monsters free their `Monsters[]` slot ids on the owner; a later deploy **reuses those freed low ids**. The owner answers Host's `RQ` with `SP|<id>|…` carrying those reused ids. On Host the captures were never applied (ghosts still live), so those ids are **still occupied** → the `SP` handler's `monsters.fromId(mid)` finds the ghost (non-nil), **skips `netSpawnAt`**, and `makeGolem`s a wild monster instead → the real ally never materialises.
**Fix (new binding + 2 init.lua call sites; no engine/non-`Source/lua` change, no hook/signature change):**
- `Source/lua/modules/monsters.cpp`: factored the shared silent-removal cleanup into `RemoveMonsterFromLevel(monster, markKilled)` and added a new binding **`monster:removeAsKilled()`** (= `remove()` local cleanup, but records the removal with `delta_kill_monster` instead of `LuaDeltaRemoveSpawnedMonster`). `remove()` is unchanged for dynamically spawned monsters (recall, retame, minion cleanup, level-exit, `RM`, reaper).
- `init.lua`: the **direct capture** path (`OnSpellActionFrame`, was `init.lua:2706`) and the **`CR` receiver** (was `init.lua:2450`) now call `removeAsKilled()`, so whichever client is the level owner records the kill in its **authoritative** delta. Barometer-safe: only non-golem level-natural monsters go through capture/`CR`.
- After this: a late joiner reaps the captured monster at level load → its slot id frees → the `SP` ally claims it via `netSpawnAt` → ally appears, ghost gone. Both symptoms resolved by the one change.
**Note (not changed):** the `RQ` resync is still a single un-retried request on `OnLevelEnter`; the delta fix should make it sufficient. Revisit only if a residual late-join flake appears after this is verified.
**Status:** ✅ verified 2026-07-05 (MP re-test pass: late-join ghosts gone, owner's allies materialise on the joiner).

### Ghost monster lingers after Taming and after Retaming (static visible copy + invisible killable copy) ✓ (2026-06-25 — VERIFIED squashed in playtest)
**Symptom:** After taming a wild monster — and after **re-taming** an already-Tamed deployed ally — a "ghost" stayed standing in place: both a **static visible** copy (a frozen rendered body) and an **invisible killable** copy (the tile still resolved to a monster you could attack/re-tame as a duplicate). Same ghost pattern as the now-removed legacy netcode. Surfaced in MP, but the root cause is client-local (not net-specific).
**Root cause (the `remove()` binding only cleared one `dMonster` field):** the generic `monster:remove()` binding (`Source/lua/modules/monsters.cpp`) zeroed `dMonster` **only at `position.tile`**, then called `M_ClearSquares`, which clears just the 3×3 around `position.old`. A monster removed **mid-walk** still holds a `dMonster` reservation at `position.future` (and/or `position.old`) **outside** that 3×3 — so a stale `dMonster` entry survived, pointing at the now-parked/invalid slot. That stale entry is the killable copy (clicking the tile resolves the old monster id) and, with the body parked at `GolemHoldingCell` + flagged invalid, renders a frozen frame = the visible copy. A monster standing still when removed has `old == tile == future`, so it cleaned up fine — hence the intermittency. Both report paths hit it because their receivers both call the same `m:remove()` (capture `CR` → `init.lua:2450`, retame `RM` → `init.lua:2436`), and the local tame/retame go through it directly.
**This was already a solved pattern:** the `snapToPlayer` binding in the *same* file had the identical latent bug and was fixed by explicitly zeroing all three position fields before `M_ClearSquares` (with a comment to that effect). `remove()` had simply never been given the same treatment.
**Fix (one generic binding, `Source/lua/modules/monsters.cpp` `remove()`):** zero `dMonster` at **`position.old`, `position.tile`, and `position.future`** before `M_ClearSquares` (mirrors `snapToPlayer`). Generic — fixes every caller (tame consume, capture, recall, retame, minion cleanup, level-exit) on every client; no `init.lua` change, no engine (non-`Source/lua/`) change, no hook/signature change.
**Status:** ✅ **VERIFIED in playtest 2026-06-25** — no ghost after taming a moving wild monster or re-taming a moving deployed ally.

### Character-creation crash: area-level capture dereferences null `MyPlayer` ✓ (2026-06-25 — verified 2026-07-05: fresh Hunter creation + MP join clean)
**Symptom:** Read access violation (`player was nullptr`) at character creation, in `GetLevelForMultiplayer(const Player &player)` (`appfat.cpp`/`msg.cpp:3125`), call stack `SelheroNameSelect → CreatePlayer → CreatePlrItems → OnCreatePlrItems → … → LuaCurrentDeltaLevel`.
**Root cause:** the new `Found:`/area-level capture set `scrollAreaLevel[seed] = items.currentDeltaLevel()` at fresh tame. `LuaCurrentDeltaLevel` returns `GetLevelForMultiplayer(*MyPlayer)`, dereferencing the local-player global — but the **starter** Tame Scroll is built from `OnCreatePlrItems`, which runs *before* `MyPlayer` is set (same pre-player window as the earlier `system.netSend` null-guard fix). Normal in-dungeon tames were fine; only the creation-time starter pet hit it.
**Fix (Lua only, `init.lua`):** guard the live read on `player.self()` (returns nil when `MyPlayer` is null, and is safe to call). A real tame always has a local player and reads the live level; the only pre-player tame is the starter pet, which always originates from **Church Lvl 1 (dlvl 1)**, so the capture falls back to `1` — `scrollAreaLevel[seed] = (player.self() ~= nil) and items.currentDeltaLevel() or 1`.

### Starter Scavenger scroll shows blank OH name (ID present) ✓ (2026-06-25 — verified in playtest)
**Symptom:** The starter Tame Scroll's floating box showed `OH:` blank but `ID:` correct, for the owner. Fresh tames were fine.
**Root cause:** `CreatePlayer` (`Source/player.cpp`) does `player = {}` (zeroes `_pName`) and only fills the name in *after* `CreatePlrItems` returns — but `OnCreatePlrItems` fires *inside* `CreatePlrItems`. So the starter captured `origin.name = p.name = ""` (blank OH), while `myOhId = generateOhId("")` still produced a timestamp-based value (ID shows). The name pack/unpack round-trip was innocent — the name was already empty when saved.
**Fix (Lua only, `init.lua`):** `healHeldScrollModData` (runs at `GameStart`, after the player name is valid) now fills any held scroll's empty origin name from `me.name` before rebuilding its blob. An empty stored name only ever comes from our own un-named creation (a traded scroll always carries its trainer's name), so claiming it for the local Hunter is safe.

### MP: freshly-tamed scroll dropped on the floor vanishes / can't be picked up ✓ (2026-06-25 — verified in playtest)
**Symptom:** After taming, the reward scroll dropped on the floor disappeared and couldn't be interacted with (non-owner tamer); peers never saw it.
**Root cause:** `items.spawnAt` placed the item via `PlaceItemInWorld` + `LuaDeltaRegisterDroppedItem` (`Source/msg.cpp`) — both **local-only**, no networked drop. So the level owner's authoritative delta never held it; a delta resync purged it on a non-owner tamer, and the owner couldn't agree to a pickup. `CMD_DROPITEM` was rejected as the fix because its receiver runs `IsPItemValid` + `SyncDropItem`→`RecreateItem` (the validation/recreate chokepoints the blob architecture avoids).
**Fix (Lua only, `init.lua`):** new `DI` pipe message. `dropTameScroll` (and the deploy-refund path) broadcast it after the `SD` blob; each same-level peer — **including the level owner** — runs `items.spawnAt` locally. Every client now holds the item (owner's authoritative delta included → no purge), and MP pickup is identity-keyed (seed/index/createInfo), so the independently-placed copies are removed together. The encoded name is gated Hunter-only on the receiver (DM5). Tame Scrolls intentionally stay out of auto-pickup (`items.spawnAt` sets no item record).
**CORRECTION (2026-07-08 audit):** the `CMD_DROPITEM` rejection rationale above was WRONG — it conflated the blob (which the vanilla wire truly can't carry) with the item (which it carries fine: createInfo 0 passes `IsPItemValid`, and `RecreateItem`'s createInfo==0 branch fires `OnCustomItemRecreated`, rebuilding the name — proven end-to-end by the playtested hand-drop trade, which rides `CMD_PUTITEM` through those exact chokepoints). The `DI` message hand-rolled what `CMD_SPAWNITEM`/`OnSpawnItem` does natively and has been **removed**: `items.spawnAt` now announces `CMD_SPAWNITEM` itself. See `cpp_changes/items.md` (rejected list) + `development_notes.md`.

### MP: create-game crash (null `MyPlayer`) + CO message truncation ✓ (2026-06-25 — verified, allies/Bonded now sync)
**Symptom:** Creating an MP game as a new Hunter crashed (`Player::GetTargetPosition`, `this == nullptr`). Separately, remote clients didn't receive a deployed ally's full combat/cosmetic state (no Bonded display, no hover).
**Root cause:** (1) a Lua `netSend` fired from `OnCreatePlrItems` (a setup callback that runs before the local net player exists), and `NetReceivePlayerData` builds the packet header from `*MyPlayer`. (2) The generic Lua net pipe buffer was `MAX_SEND_STR_LEN` (80, inherited from chat); the 28-field `CO` message (~157 B incl. the LuaNet channel frame) was truncated, so the receiver's `#parts < 28` guard dropped the whole profile.
**Fix (engine, Lua-layer):** (1) the `system.netSend` binding (`Source/lua/modules/system.cpp`) now also guards `MyPlayer == nullptr` — a generic precondition (no packet header without the local player), drop the send. (2) added `#define LUA_MSG_MAX_LEN 255` (`Source/msg.h`), pointed `TCmdLuaMsg.data[]` + the two clamp sites (`Source/msg.cpp`) at it; chat's `MAX_SEND_STR_LEN` stays 80. `TCmdLuaMsg` is 257 B, half of the 493-B packet body.

### Tame Scrolls lose unique-scroll quality after Pepin Recovery buy-back ✓ (2026-06-23 — verified 2026-07-05)
**Symptom:** A scroll that should render at unique/gold tier (Bonded non-unique, Tamed unique, Bonded unique) lost its unique-scroll presentation after being bought back from Pepin's recovery list — no gold lettering, no custom unique infobox, no "Unique Item" line — until a full retame. Data was always intact (purely a quality/presentation defect).
**Root cause (confirmed by source read):** the unique-box gate is purely `_iMagical == ITEM_QUALITY_UNIQUE` (`Source/items.cpp:4290` — adds the "unique item" line, sets `ShowUniqueItemInfoBox`, fires `OnPrepareUniqueInfoBox`). The recovery scroll is stocked via `items.addToHealerStock(...)`, whose binding `LuaAddToHealerStock` created the stock item at `ITEM_QUALITY_NORMAL` (it set seed/name/dwBuff/modData/identified but never `_iMagical`). A vendor purchase (`HealerBuyItem` → `StoreAutoPlace`, `Source/stores.cpp:1738`) copies the stock item's fields verbatim and fires **none** of the pickup/level-enter/recreate quality fixups, so the bought scroll entered inventory at normal quality → gate never fired.
**Fix:** added an optional `magical` param to `addToHealerStock` / `LuaAddToHealerStock` (`Source/lua/modules/items.cpp`; default leaves base-item quality unchanged) that sets `item._iMagical`. The recovery-stocking loop (`init.lua`) now passes `2` (`ITEM_QUALITY_UNIQUE`) for gold-tier scrolls (`seedGetUniqueType(seed) >= 0 or isBonded(seed, level)`), so the bought copy is gold + unique-box-eligible from purchase. (`HealerBuyItem`'s `if (_iMagical == NORMAL) _iIdentified = false` no longer fires for these, so identified stays true too.)
**Verify:** buy back a Bonded / unique recovery scroll from Pepin and confirm gold name + "Unique Item" line + custom infobox WITHOUT a retame. **Note for verify:** the original report said a floor drop+re-pickup restored gold but NOT the infobox; that couldn't be reproduced by source reading (the gate is solely `_iMagical == UNIQUE`), so confirm whether the re-pickup case is also fully resolved now or still needs a look.

### Bug #1 — Tamed allies freeze on peers in MP (peer-AI suppression) ✓ (verified 2026-07-05)
**Symptom:** In MP a tamed ally animated only on its owner's client; on every other client it was frozen (it could finish its current animation but never started a new one). Direct consequence of the interim Layer-2 fix above (`OnGolemCanRunAI→false` suppressed a remote ally's AI; the engine monster sync carries position only, no mode/animation, so a suppressed golem never starts a new mode).
**Fix (deterministic personality AI on all clients — the vanilla monster model):** reverse the suppression and run the **same** AI on every client, made identical by the engine's synced per-monster RNG. User-chosen scope: deterministic AI everywhere + combat-override (DM1) pulled forward.
- **Engine (4 thin generic additions, all default = vanilla):** `monsters.aiRandom(n)` (draws from `GenerateRnd`, which `ProcessMonsters` has reseeded to each monster's synced per-monster stream in MP → identical on every client when called inside an AI hook); `monster:startSkeletonSpawnCast()` + `StartGolemSpawnSkeletonCast` (the skeleton-spawn **cast animation only**, no create / no hook — a non-authoritative client mirrors the cast without creating a monster); new hook `OnGolemMinionMissileSpawn(golem, speciesTypeId, x, y, default=true)` gating `ProcessHorkSpawn`'s vanilla `SpawnMonster(spawnPos, facing, 1)` (the engine passes the canonical `MT_HORKSPWN`; a handler returning false suppresses the level-local-indexed spawn so the mod can create the correct species). Engine comments are generic (no mod terms).
- **Lua (init.lua):** removed the `OnGolemCanRunAI` suppression handler. `remoteAllies` enriched from `id→ownerId` to `id→{ownerId, parentId, idleTarget, profile}` (the peer-side mirror of an own-ally tracking entry). New helpers `isTamedAlly` (own ∪ remote), `allyOwner(monster)=player.get(monster.ownerPlayerId)` (resolves the owner uniformly — own ally's ownerId is the local player), `allyScratch`, `isAllyOwnerLocal`. **Every per-tick AI hook** (`OnGolemCanTargetMonster`, `OnGolemCanChaseTarget`, `OnGolemIdle`, the 3 `OnGolemChooseAction` handlers) rewritten client-symmetric: gate on `isTamedAlly`, anchor to `allyOwner` (dropped the owner-only `cachedOwnerX/Y`), and draw randomness from `monsters.aiRandom` instead of `math.random`.
- **Minions ride the species-id `SP` pipe (not the engine spawn — minion species aren't level-natural):** Skeleton King spawn is owner-gated (`isAllyOwnerLocal` → `spawnSkeletonMinion` → `adoptMinion` → SP+CO; peers play `startSkeletonSpawnCast` only and receive the skeleton via SP). Hork spawn rides the new engine gate (the missile fires on all clients for animation; the **owner** spawns `MT_HORKSPWN` at the landing tile + adopts + SP, peers suppress + receive). New `adoptMinion` helper SP-replicates with `parentId`; `countMinionsOfParent` now counts remote minions too so the cap decision matches across clients. The dead `broadcastMakeGolem`/`MG` path was removed.
- **Combat-override sync (DM1, `CO` message):** the owner broadcasts each ally's final combat values + caster profile (`CO|id|maxHp|hp|min|max|toHit|ac|resist|isMinion|bonded|bondedImm|baseMaxDmg|sharePctMille|magicCur|resFire|resLight|resMagic`) to same-level clients on deploy / recalc / Bonded transition / RQ-reply; receivers apply the stats to the live monster and cache the profile. `recalcAllyBuffs` auto-broadcasts (forward-declared `broadcastAllCombatOverrides`). Unified `ownAllyProfile`/`allyMissileProfile` make `OnGolemMissileDamage` + `OnGolemMissilePreResolve` (Bonded pierce / acid-as-magic) compute identically on owner and peers. This also makes HP-threshold AI (Scavenger/Gargoyle/Goat at <50% HP) and melee damage deterministic across clients.
**Files:** `Source/lua/modules/monsters.cpp` (`aiRandom`, `startSkeletonSpawnCast`), `Source/monster.cpp`/`monster.h` (`StartGolemSpawnSkeletonCast`), `Source/missiles.cpp` (`ProcessHorkSpawn` gate), `Source/lua/lua_event.hpp`/`.cpp` (`OnGolemMinionMissileSpawn`), `assets/lua/devilutionx/events.lua`, `init.lua` (the bulk). No vanilla wire/save format changed.
**Known interim (not crashes):** remote minion bodies linger on peers until level reload (N3 live-remove still pending; `remoteAllies` tracking IS cleared on death so counts stay correct); `CO` carries current hp so an infrequent recalc can briefly rewind a peer's HP a little; a Skeleton-King spawn that fails on the owner (no free tile) can desync one cast-animation frame on peers.
**Status:** ✅ verified 2026-07-05 (MP sessions: remote allies animate/kite/spawn normally, no freeze, no duplicate minions).

### Single-player Load Game mid-dungeon orphaned deployed allies ✓ (current session)
**Symptom (latent; raised by user while reviewing save/load):** In single-player, "Load Game" restores the entire game state as it was — including a mid-dungeon level with deployed Tamed allies still on it. The golems reloaded as live monsters but became **orphaned**: they lost their Tamed name / outline / leash / stat-buff / kill-credit, could not be recalled (casting Tame re-captured instead), and — because their `recoveryRegistry` "lost" backups survive in the save — Pepin would hand out **duplicate** scrolls while the orphan golems persisted on the level.
**Root cause:** The explicit SP **Save Game** menu (`gamemenu.cpp` → `SaveGame()` → `pfile_write_hero(writeGameData=true)` → `SaveGameData`) does **not** fire `OnLevelExit`, so allies are **not** recalled before the save — `SaveLevel` serialises the deployed golems as live monsters (and the full `dMonster`). On `LoadGame`, `LoadMonsters` restores them into the **same slot ids** (`ActiveMonsters` is saved/loaded verbatim). But the live-golem↔scroll-seed link lives only in the Lua `deployedAllies` table, which is session-local and **not** part of any save, and nothing rebuilt it on load.
**Fix (additive Lua + two thin generic C++ getters; established functions untouched):**
- **C++ `Source/lua/modules/monsters.cpp`** — new `monsters.fromId(id) -> Monster|nil`: returns the active monster occupying a slot id (membership-checked against `ActiveMonsters`), nil otherwise. The stable re-link key. Generic getter, mirrors `getHovered`.
- **C++ `Source/lua/modules/system.cpp`** — new `system.isMultiplayer() -> boolean` (thin getter over `gbIsMultiplayer`): player count can't distinguish solo-hosted MP from SP, so this is the reliable SP/MP gate.
- **Lua `init.lua`** — a 5th section of the `OnSavePlayerData`/`OnLoadPlayerData` blob persists a **deployed-ally roster** (per ally: slot id, seed, capturedDifficulty, isMinion, parentId, and the un-buffed `base` stats), **single-player only** (count 0 in MP). On load it stages into `pendingAllyRoster`; `relinkSavedAllies` (called from the `GameStart` handler, **after** the per-game state clear so it isn't wiped, and after `StartGame` has fully loaded the saved level + monsters) re-binds each record to its reloaded golem via `monsters.fromId`, validating `isGolem` + local owner. It rebuilds the tracking entry, re-asserts Bonded state (mirroring the redeploy path: `rollBondedBonus`/`rollBondedTrn`/`applyBondedBonus`/`applyBondedGlow`), then `recalcAllyBuffs()` — which **writes** `base+buff` (never accumulates), so the already-buffed saved stats are overwritten with a clean value (no double buff) while wounded current HP is preserved.
**Why it can't mis-link:** `OnLoadPlayerData` fires only for the loaded hero (`pfile_read_player_from_save` in `NetInit`, not menu browsing) and resets `pendingAllyRoster` to nil first; the roster is consumed once on the first `GameStart`; records validate against `fromId` + `isGolem` + local owner; and the whole apply is gated to single-player.
**MP:** untouched — no roster is persisted in MP (slot ids aren't comparable across clients/sessions) and MP deployed allies persist via the network delta (`spawnedMonsters`). A full MP re-link is deferred to net sync (`roadmap.md`).
**Files:** `Source/lua/modules/monsters.cpp` (`fromId`), `Source/lua/modules/system.cpp` (`isMultiplayer`), `init.lua` (roster save/load section + `relinkSavedAllies` + `GameStart` call), `lua_api_reference.md`, `lua_api_reference.md`, `roadmap.md`.

### Quit-to-menu with an ally deployed, then New Game → `Towners[]` subscript-out-of-range crash in town ✓ (current session)
**Symptom (MP, incl. solo-hosted):** Deploy any tamed/bonded ally in a dungeon, quit the game to the **main menu** (not all the way out), then create a **new game** → immediate crash on the first town frame: `vector subscript out of range` in `std::vector<devilution::Towner>::operator[]`, called from `DrawMonsterHelper` (`scrollrt.cpp:746`).
**Root cause (stale per-game Lua state snaps an aliased monster into town):** The Lua runtime persists across games within one app launch, but `OnLevelExit` — which recalls allies and clears the per-level death sets — fires **only on in-game level transitions** (`DeltaSaveLevel`/`pfile_save_level`), **never on quit-to-menu**. So quitting with an ally still out leaves `deployedAllies`/`deployedAlliesById` populated with entries whose `entry.monster` wraps a monster **slot from the dead game**. The mod registered **no `GameStart` handler** (the per-game reset point, `lua::GameStart()` in `RunGameLoop` after `StartGame`), so that state survived into the next game. In the new game's **town**, those slot ids alias freshly-created monsters (the reserved golem holding-cell slots from `InitGolems`); `GameDrawComplete`'s per-frame leash loop reads the aliased monster's far-away position (> `LEASH_DISTANCE`) and calls `snapToPlayer`, whose `occupyTile` writes `dMonster[ownerTile] = slotId + 1` — a **real monster index** into the town's `dMonster`. `DrawMonsterHelper`'s town branch (`leveltype == DTYPE_TOWN`) reads that as a **Towner index** (`Towners[mi]`), and `mi` ≫ `Towners.size()` → out-of-range crash.
**Fix (two layers, pure Lua — no engine change):**
1. **`GameStart` reset (primary/hygiene).** Added an `events.GameStart.add` handler in `init.lua` that resets the live/transient per-game session state to its empty start-of-game invariant: `deployedAllies`, `deployedAlliesById`, `corpselessDeaths`, `pendingResurrectBeam`, `cachedOwnerX/Y`, `lastBuffFingerprint`, `pierceRestore`. At the start of any game no ally is deployed (allies are always in scroll form between games), so enforcing that here is always correct. Deliberately does **not** clear the save-persisted tables (`allyKillCounts`, `recoveryRegistry`, `bondedTrn`, `bondedImmunity`), which `OnLoadPlayerData` has already repopulated by the time `GameStart` fires, nor `tameScrollData`/`nextScrollSeed`, which `OnCreatePlrItems` seeds for a brand-new character before `GameStart`.
2. **Leash stale-entry guard (the actual safety net).** The `GameStart` reset alone did **not** stop the crash in MP testing — `lua::GameStart()` fires in `RunGameLoop` *after* `StartGame`, so a frame (and its `GameDrawComplete` leash) can run against the stale set before the reset lands. So the leash loop in `GameDrawComplete` now guards each entry: it skips **and prunes** (`untrackDeployedAt`) any entry whose `entry.monster.isGolem` is false. A leftover cross-game entry points at a slot the new game freed/reused (cleared flags ⇒ `isGolem` false; `Monsters` is a stable static array so the pointer is always safe to read); every live ally/minion is `makeGolem`'d and reads `isGolem` true. The stale entry is pruned on the first `GameDrawComplete` **before** it can `snapToPlayer`, so the bogus `dMonster` write never happens — independent of whether the `GameStart` reset ran in time. Self-heals the set for every per-frame consumer (leash + buff recalc).
Both the `GameStart` event and the `snapToPlayer`/`isGolem` bindings already existed; no C++ was needed.
**Files:** `init.lua` (`GameStart` handler + `GameDrawComplete` leash guard).
**Note (latent, NOT fixed here — flag if it surfaces):** `nextScrollSeed` resets to 1 each launch while `tameScrollData` persists across games, so two different characters in one launch could allocate the same seed and conflate `tameScrollData[seed]` (wrong-monster deploy on collision). Mitigated by the `OnLevelEnter` handler that bumps `nextScrollSeed` past every held scroll, and by `recoverScrollData` (seed+dwBuff) as the cast-time fallback. Out of scope for this crash.

### Bonded monster TRN "upgrade" barely visible / not working ✓ (current session)
**Symptom:** The visual TRN "upgrade" marking a monster as **Bonded** did almost nothing — the sprite came out only slightly lighter, no clear recolour or "gilding".
**Root cause:** the original `BONDED_GILD_MAP` was a **near-identity** remap — it kept each monster's own colours and only nudged the brightest tones into a narrow gold band (`196..202`). Most sprite pixels were left unchanged, and the few that moved went into mid/dark gold, so it read as a faint brightening. (TRN selection/return path was fine; the *map* was the problem.)
**Fix:** replaced the single near-identity gild with **five `buildScatterTrn` variants keyed to the rolled Bonded bonus** (Fire / Lightning / Magic / +200 AC, plus a rare Hell-only Gilded Metal). Each scatters two **fixed bright** high-contrast colours over the global sprite range (128-255) using the sprite's own checkerboard dither, leaving ~1/3 of pixels original so the monster's identity still reads. `bondedTrn[seed]` stores the rolled variant (persisted as a 3rd save section); applied via the existing `OnGetMonsterTRN` handler. See `trn_palette.md` → "Bonded Recolour TRNs" + "Scatter / dithered application" for the full mechanism and tuning knobs.

### Offensive staff charges / scrolls could be cast on own Tamed/Bonded monsters ✓ (current session)
**Symptom:** Right-clicking a readied offensive **staff charge** (the main way Hunter accesses offensive spells) — or an offensive **scroll** (e.g. Scroll of Fireball) — onto the player's own tamed/bonded ally would cast it at the ally. The existing misclick protection covered left-click attacks and the scroll-*teleport* cursor cast, but not the readied staff-charge cast nor the readied/inventory offensive-scroll cast.
**Root cause:** `OnPlayerAttackMonster` already gated every other monster-targeted offensive path (`LeftMouseCmd`'s 3 callsites + `TryIconCurs`'s `CURSOR_TELEPORT` scroll cast), but the `SpellType::Charges` cast in `CheckPlrSpell` (`Source/player.cpp`) had no veto at all (`addflag = pcurs == CURSOR_HAND && CanUseStaff(...)`), and the `SpellType::Scroll` veto (`OnCanCastScroll`) was not target-aware.
**False start (reverted):** first attempt added the gate to the shared spell **dispatch** (`else if (pcursmonst != -1 ...)`), which fires for *every* readied cast type — including `SpellType::Skill`. That would have **broken Share Potion** (a Skill, allowed by its own `OnCanCastSkill` gate): casting it while hovering an ally would hit the dispatch gate and be silently cancelled before the animation / `CURSOR_HEALOTHER` could start. The shared handler can't distinguish a beneficial skill from an offensive charge (it never receives the spell id), and the C++ rule forbids spell-type branching in the engine, so the dispatch is the wrong layer.
**Fix (scoped to the offensive type):** AND the veto into the `SpellType::Charges` `addflag` case only — `addflag = pcurs == CURSOR_HAND && CanUseStaff(myPlayer, spellID) && lua::OnPlayerAttackMonster(&myPlayer, pcursmonst, true)`. A veto makes `addflag` false → silent cancel, no `CMD_*` queued, no charge consumed. `Skill` (Share Potion → `OnCanCastSkill`) and `Scroll` (Tame → `OnCanCastScroll`) are untouched, so beneficial casts on allies still work. Mirrors the adjacent `Skill`/`Scroll` cases that AND their own veto into the same switch.
**New int-target overload (charges):** `OnPlayerAttackMonster(const Player*, int monsterId, bool default)` resolves the raw `pcursmonst` (`-1` → nullptr/`nil`) exactly like `OnCanCastSkill`, so the engine passes the global directly with no `-1` deref and no ternary/logic. The shared Lua helper nil-checks `monster` first (a charge aimed at an empty tile passes `nil` → allow).
**Scroll fix (spellId-aware, after the charge fix):** `SpellType::Scroll` is heterogeneous — it carries both offensive scrolls (block on allies) **and** the Hunter's own **Tame** deploy scroll (must NOT be blocked when aimed near an ally). So `OnPlayerAttackMonster` (no spellId) could not be reused for scrolls: it would over-block the Tame deploy, and gating a *deploy* scroll with "attack" protection is the wrong concept. Instead `OnCanCastScroll` — which already knows the spellId and fires on both scroll cast paths — was given the cursor target (4th arg `target`, resolved from raw `pcursmonst` like `OnCanCastSkill`). Its handler now blocks **non-Tame** scrolls aimed at a protected ally and leaves Tame (and the inventory use-gate, which passes `-1`/nil) untouched. The actual monster-targeted commit always funnels through `CheckPlrSpell` (the `UseItem` path sets `prepareSpellID` for targeted scrolls and re-enters it), so passing `pcursmonst` there is the single chokepoint.
**Shared rule (DRY):** the ally-protection decision lives in one Lua helper `isProtectedFromOffense(attacker, monster)` (nil-safe) used by **both** the `OnPlayerAttackMonster` and `OnCanCastScroll` handlers, so the "don't direct offense at a protected ally" rule has a single source of truth.
**Files:** `Source/player.cpp` (`CheckPlrSpell` `SpellType::Charges` + `Scroll` cases), `Source/lua/lua_event.hpp`/`.cpp` (`OnPlayerAttackMonster` int-target overload + `OnCanCastScroll` `target` param), `Source/inv.cpp` (`UseInvItem` `OnCanCastScroll` call passes `-1`), `init.lua` (shared `isProtectedFromOffense` helper; `OnPlayerAttackMonster` + `OnCanCastScroll` handlers), `assets/lua/devilutionx/events.lua` (`OnCanCastScroll` doc), `lua_api_reference.md` (rows updated).

### Recurring "monster array" renderer crash near a Skeleton King — corpse table overrun ✓ (current session)
**Symptom:** Renderer crash in the monster-array family, **typically both asserts together**: `ProcessMonsters` `assert(ActiveMonsterCount <= GetMaxMonsters())` (monster.cpp) **and** null-sprite `clx_sprite.hpp` `value_.data_ != nullptr`. "Always seems to involve a Skeleton King **and a monster death**." Hit on a fresh level killing just the King, and after killing many monsters, with tamed monsters deployed or not. Persisted **before and after** the live-monster-array extension (which is why raising that cap never helped — wrong array).
**Root cause (the corpse table was never extended alongside the monster TYPE table):** The earlier work extended the per-level monster **type** table (`LevelMonsterTypes` → `GetMaxLvlMTypes()` = 24 + 32 = 56) and the live-monster arrays (→ 252), but left the **corpse** table at its vanilla size: `MaxCorpses = 31`, `Corpse Corpses[31]` (`dead.h`). `corpseId` is a **5-bit field packed into `dCorpse`** (`(dv & 0x1F) + (dir << 5)`, dead.cpp) — so 31 is a hard *encoding* ceiling, not just an array size (analogous to the 252 live-monster ceiling). With the type table able to carry far more than 31 distinct types/uniques per level, two spots became reachable:
- `InitCorpses` (dead.cpp) wrote `Corpses[nd]` with **no bounds check** — a high-variety level (many natural types + uniques + tamed species/uniques) registers `nd > 31`, overrunning the 31-element global array → corrupts adjacent globals (this is the paired `ActiveMonsterCount` assert) and leaves garbage corpse entries (null sprites).
- `RegisterLateMonsterTypeCorpse` (dead.cpp, the mod's late-corpse path) **silently left `corpseId = 0`** when the table was full → on that monster's death, `AddCorpse(…, 0, …)` makes the renderer read `Corpses[-1]` → null sprite. (Same failure mode as the earlier "late-registered monster type corpse crash.")
This is why it correlates with a **Skeleton King + a death**: the King is unique (consumes a corpse slot) and raises skeletons (more types), and the corruption only surfaces when a corpse is actually placed (a death). It only happens with the mod because only the type-table extension lets a level exceed 31 distinct corpse types.
**Fix — two parts:**
**The actual mechanism:** allies are recalled on level exit, so `InitCorpses` only ever sees *natural* types at level load (well under 31) — it does not overrun. The crash came from **post-load tamed deploys**: each distinct tamed species called `RegisterLateMonsterTypeCorpse`, which scans the 31-slot corpse table for a free slot and, when full, **silently left `corpseId = 0`**. That tamed monster then died → `AddCorpse(…, 0, …)` → renderer read `Corpses[-1]` → null sprite (and the paired array assert from the corrupted draw). Same family as the earlier "late-registered monster type corpse crash," whose `RegisterLate` fix only deferred the failure to "table full."
**Fix — tamed monsters leave no corpse (design; one thin generic hook, no save-format change).** Rather than widen `dCorpse` (which would change the level save format) or band-aid the corpse table, tamed allies/minions now vanish on death without placing a corpse — the loss is conveyed by disappearance (and, later, the Farnham recovery flow), which also keeps them off the limited corpse table entirely. New thin generic hook `lua::OnMonsterCanPlaceCorpse(monster, default=true)` gates the `AddCorpse` in `MonsterDeath` (mirrors the adjacent `OnMonsterCanCompleteQuest` gate; default true = vanilla, monster still clears its tile and is reaped). The mod records a dying ally in a `corpselessDeaths` set in `OnMonsterDeath` (before untracking) and returns false for it in `OnMonsterCanPlaceCorpse` (the ally is already untracked by the time that fires). A vanilla Golem is never recorded, so it keeps its vanilla corpse (barometer respected). Because every mod spawn is tracked → gated → never places a corpse, tamed types never need a `corpseId`.
**Engine-change cleanup (this is why no band-aid was needed):** the corpse-specific base-game changes were removed/avoided — `RegisterLateMonsterTypeCorpse` (`dead.cpp`/`dead.h` + its two `monsters.cpp` call sites) was **deleted** (redundant: tracked tamed monsters never place a corpse), and an interim "crash-safe corpse table" guard set in `InitCorpses` was **reverted**. No `dCorpse` widening. Unrelated engine fixes for *different* crashes were kept: `PlaceGroup` underflow guard (deploy-time pack-leader flood), `LuaDeltaRemoveSpawnedMonster` (MP recall delta hygiene), and the `monster:remove()` re-entrancy fix.
**Files:** `Source/monster.cpp` (`OnMonsterCanPlaceCorpse` gate in `MonsterDeath`), `Source/lua/lua_event.hpp/.cpp` (hook), `assets/lua/devilutionx/events.lua` (event + doc), `init.lua` (`corpselessDeaths` + the two handlers + level-exit clear); removed `RegisterLateMonsterTypeCorpse` from `Source/dead.cpp`/`dead.h`/`Source/lua/modules/monsters.cpp`.
**Status:** ✅ verified 2026-07-05 — no recurrence across extended play sessions since the fix.

### Investigated & reverted: dead-spawn-recipe replay / `EnsureMonsterIndexIsActive` (NOT the cause)
While chasing the above, a delta-hygiene change (skip dead `spawnedMonsters` recipes in `DeltaLoadSpawnedMonsters`; cap-guard `EnsureMonsterIndexIsActive`) was prototyped in `Source/msg.cpp` / `Source/monster.cpp`, then **reverted**. Reason: `spawnedMonsters` is keyed by monster **slot id** (`map<size_t, …>`) and freed slots overwrite, so the recipe map is bounded by `GetMaxMonsters()`; and `EnsureMonsterIndexIsActive` cannot push the count past the cap under a stable cap. So that path could not produce the count-overflow and was the wrong lead. Recorded here so it isn't re-chased. (There remains a minor, separate latent wrongness — a dead spawned monster briefly re-creating on re-entry before its `hitPoints = 0` is re-applied — but it does not overflow and was deliberately left alone.)

### Ally/minion death crashed the renderer (re-entrant `ActiveMonsters` mutation) ✓ (current session)
**Symptom:** A deployed ally or minion dying could crash the renderer with a null-sprite / out-of-range-id assert (`clx_sprite.hpp` `value_.data_ != nullptr`; `scrollrt.cpp` `DrawDungeon` `assert(mid < GetMaxMonsters())`). Reproduced with the Skeleton King both **with** live skeleton minions and with **none visible** (killing-blow source — own spell, enemy, environment — irrelevant). Same array/stale-slot family as the `PlaceGroup` underflow and delta-spawned-monster bugs.
**Root cause:** the generic `monster:remove()` binding ended with an immediate `DeleteMonsterList()`, which compacts `ActiveMonsters` and decrements `ActiveMonsterCount`. The engine's `MonsterDeath` fires `lua::OnMonsterDeath` **synchronously, mid-tick**, while `ProcessMonsters`/`ProcessMissiles` is iterating `ActiveMonsters` by index. Our handler's `removeMinionsOfParent` → `monster:remove()` → `DeleteMonsterList()` mutated that array under the live iterator, leaving a stale slot / out-of-range id the renderer later dereferenced. The "zero visible minions" case is the **same** path: a tamed Skeleton King's `GolumAi` can spawn-and-adopt a skeleton in the **same tick** it dies, so `removeMinionsOfParent` finds that fresh minion at death time.
**Fix (`Source/lua/modules/monsters.cpp`, generic binding — no Lua change):** `monster:remove()` now mirrors the engine's own `MonsterDeath` discipline — it never compacts `ActiveMonsters` mid-iteration. It still clears tile/light/delta and flags the monster `isInvalid` immediately, but only calls `DeleteMonsterList()` when no game-logic step is in flight (`gGameLogicStep == GameLogicStep::None` — level-exit recall / out-of-tick removals, where immediate compaction is required so `SaveLevel` does not persist the monster). During a tick it instead parks the monster on `GolemHoldingCell` (the `{1,0}` tile where `GolumAi` early-returns) so its AI cannot re-occupy a tile before the engine's own `DeleteMonsterList` (top & bottom of `ProcessMonsters`) reaps it next tick.
**Why safe / generic:** fixes `remove()` for every caller (minion cleanup, recall, retame, tame consume) and any mod — not Hunter-specific. No engine file touched, no hook added, no signature changed. The out-of-tick path (the only one that must compact immediately for `SaveLevel`) is unchanged, so the MP delta-hygiene fix below still holds.
**Files:** `Source/lua/modules/monsters.cpp` (`monster:remove()` binding; added `#include "missiles.h"` for `GolemHoldingCell`), `roadmap.md` (section marked RESOLVED).

### Overhealed unique's scroll HP display caps current at max ✓ (current session)
**⚠ Superseded — overheal-to-scroll was later intentionally removed.** The 8-bit / 0..200% widening described below was reverted: overheal is no longer persisted through a recall. `encodeDwBuff` now clamps `pct` to 0..100 and recall persists the un-buffed `base.maxHp` with current clamped to it. The Share Potion 150% proc still works *live*. See HISTORY.md → "Block-4 follow-up — HP-buff model revision". Retained below for history.
**Symptom:** Overheal a Tamed Unique so its current HP is 150% of max, then retame it back into the scroll. The scroll's "current / max" HP **display** showed 100%, not 150%. (Redeploy in the *same session* correctly kept the 150%.)
**Root cause (it was an encode loss, not just a display read):** within a session, redeploy restores HP from the `tameScrollData[seed]` session cache (`allyToMonsterData` keeps the live `ally.health` = 150%), which is why same-session redeploy kept the overheal. But the **scroll's `dwBuff` itself never stored >100%**: `encodeDwBuff` clamped current HP to max (`hp = min(savedHp, mhp)`) **and** clamped `pct > 100` to 100, and the percent field was only **7 bits (bits 24–30, 0..127)** — too small for 150 anyway. The info box reads `decodeDwBuff(item.buff)` (the recalled scroll, not a live monster), so it could only ever read back ≤100%. A pure display-read change had no better source.
**Fix (Lua-only, `init.lua`):** widened the percent field to **8 bits (bits 24–31, 0..200)** using the previously-unused bit 31, and stopped clamping current HP to max in `encodeDwBuff` (the `pct > 100 → 100` cap became `pct > 200 → 200`). The info box line (`"HP: savedHp / maxHp"`) is unchanged — it now simply receives the true 150% from `decodeDwBuff` (`% 128` → `% 256`).
**Why safe / non-regressive:** `Item::dwBuff` is `uint32_t` (`items.h`), and the engine never interprets these bits — `RecreateItem(createInfo=0)` ignores `dwBuff` and `IsDungeonItemValid` always passes — so bit 31 has no signedness/wire concern. Old scrolls have bit 31=0 and pct≤100, so they decode **identically** under the widened `% 256` read (full backward compat). Resolution stays at 1% for wounded allies (no rescale). Bit 0 (CF_HELLFIRE) stays 0. As a bonus the overheal now also survives a game restart (post-restart redeploy recovers savedHp from the scroll and calls the same already-exercised `setHitPoints` path). No C++ change.
**Files:** `init.lua` (`encodeDwBuff`/`decodeDwBuff` + layout comment), `hunter_class_design.md` (encoding doc).

### Chain Lightning splash kills the Hunter's own pet (path padding) ✓ (current session)
**Symptom:** With only a Skeleton King deployed on a fresh level, spam-casting Chain Lightning crashed when the King died — even though the targeting gate correctly never aimed a bolt *at* him. CL spread bolts forming on adjacent tiles were close enough to sweep him.
**Root cause:** each CL spread bolt is a `LightningControl` fired from the chain origin to a nearby enemy tile, `CheckMissileCol`-ing along the whole line and splashing tiles *adjacent* to the rounded path. `ownAllyInPath` only matched tiles **exactly** on the integer-rounded line, so a pet one tile off it was still hit.
**Fix (Lua-only, `init.lua`):** `ownAllyInPath` → `ownAllyNearPath` — vetoes a target when a pet is within `PATH_PADDING = 1` tile (Chebyshev) of any sampled line point, and now samples the target endpoint too (catches a pet hugging the targeted enemy). Strictly widens the existing veto; no vanilla/non-pet effect.
**Note — this removed the reproduced *trigger*; the underlying crash was fixed separately.** The re-entrant minion-cleanup crash is now resolved at the binding layer — see "Ally/minion death crashed the renderer (re-entrant `ActiveMonsters` mutation)" above. The padding stays as defence-in-depth (keeps CL spread bolts off pets) but is no longer load-bearing for the crash.
**Files:** `init.lua` (`ownAllyNearPath` + `OnMissileCanTargetMonster` call site).

### Stone Curse petrifies the Hunter's own tamed ally ✓ (current session)
**Symptom (gap from the auto-target audit):** `AddStoneCurse` (`Source/missiles.cpp`) snaps to the nearest valid monster via its own `FindClosestValidPosition` seek lambda, which excludes only `MT_GOLEM`/`MT_DIABLO`/`MT_NAKRUL` **by type**. A tamed ally is a *non-golem* monster type carrying `MFLAG_GOLEM`, so it was not covered — a Hunter aiming Stone Curse near their own pet could snap onto and petrify it. (The vanilla Golem stays protected by the `MT_GOLEM` type check.)
**Fix (thin call-out, reuses the established veto — no new plumbing):** the seek lambda's final `return true;` became `return lua::OnMissileCanTargetMonster(&monster, target, true);`, keeping the `MT_GOLEM` exclusion above it. Both args (`monster`, `target`) are already in scope, so no new local/capture is introduced (an earlier attempt that manufactured a `source = missile.position.start` local + capture was rejected as engine plumbing — rule violation). Passing the candidate `target` tile as the source makes the handler's `ownAllyInPath` walk empty (`source == target`), so only the pet-ownership veto runs — correct for a snap-to-target spell (no "fire through a pet" semantics, no spurious path-fizzle). Default `true` = vanilla; no monster casts Stone Curse, so only the player path is affected and enemy abilities are untouched.
**Files:** `Source/missiles.cpp` (`AddStoneCurse`). Lua handler `OnMissileCanTargetMonster` unchanged (already excludes own/friendly pets).

### Auto-targeting spells target the Hunter's own pets; vanilla Golem wrongly treated as an ally ✓ (current session)
**Symptom:** Chain Lightning (and other auto-targeting spells — Bone Spirit, etc.) **targeted the Hunter's own tamed allies, their raised minions, and a vanilla Golem from the first cast** — i.e. fired bolts straight at them, not just bounced into them. Separately, base-game Golem behaviour must never be touched by Hunter logic (the barometer for the mod respecting base mechanics), but the targeting rule was catching it.
**Desired behaviour (clarified by user — this is targeting, not damage):** auto-targeting spells must **not target** the player's own/allied tamed monsters at all, and — one step beyond base game — must **fail to target** an enemy that sits behind one of our pets (no firing a bolt "through" a pet). Damage immunity for pets is a *separate* QoL deferred for later; do **not** make pets damage-immune here.
**Root cause (two parts):**
1. **Chain Lightning auto-targets every monster in radius, with no faction filter.** `ProcessChainLightning` (`Source/missiles.cpp`) fires one `LightningControl` bolt at the cast destination, then `Crawl`s an expanding radius and fires another bolt at **every** tile with `dMonster > 0` — including the caster's own pets and Golem. (An earlier attempt to gate this in `CheckMissileCol` only suppressed *damage*, leaving the bolts still fired at pets — wrong layer; reverted.) Bounces/homing go through `FindClosest`, which already had the `OnMissileCanTargetMonster` hook but no path awareness.
2. **`player.id` returned a pointer, not the slot index — the vanilla-Golem cause.** The `player.id` Lua binding returned `reinterpret_cast<uintptr_t>(&player)` (a memory address), while `player.get(id)` and `monster.ownerPlayerId` (`goalVar3`) both use the **0-based Players index**. So `isOtherHuntersAlly`'s own-pet early-return `if ownerId == me.id` compared a slot index against a pointer — **never equal, dead code** — so `player.get(ownerId)` resolved the owner slot back to *the player themselves* (a Hunter) and every Hunter-owned golem, **including the player's own vanilla Golem**, was mis-classified as "another Hunter's pet" (blue outline; targeting/selection treated it as an ally). All other `.id` comparisons in the mod are Player-object-vs-Player-object (pointer-vs-pointer) and happened to work, masking the bug — only the one `ownerPlayerId`(slot)-vs-`player.id` comparison was broken.
**Fix (pure targeting; no damage changes):**
- **C++ (`Source/missiles.cpp`):** the `OnMissileCanTargetMonster(monster, source)` query (now also carrying the missile/cast **origin tile**) is folded into the existing target-pick `if` at both sites via `&&` short-circuit — the Chain Lightning spread `Crawl` in `ProcessChainLightning` and the `FindClosest` lambda. A vetoed monster simply has **no bolt fired at it**. No new branch, default `true` = vanilla.
- **C++ (`Source/lua/lua_event.hpp/.cpp`):** added the `Point source` parameter to the hook so the Lua handler can inspect the origin→target line.
- **C++ (`Source/lua/modules/player.cpp`):** `player.id` now returns `player.getId()` (0-based Players index) instead of a pointer address, making it consistent with `player.get(id)` and `monster.ownerPlayerId` — exactly as its doc already implied ("Pair with player.get()"). Verified every existing `.id` comparison in the mod still holds (`getId()` is unique per active player), and the previously-dead own-pet guard now fires. Generic, modder-facing.
- **Lua (`init.lua`):** `OnMissileCanTargetMonster(monster, source)` returns false for (a) our own deployed allies/minions, (b) a friendly other-Hunter pet, and (c) **any target with one of our own pets on the line from `source` to the target** (`ownAllyInPath` walks the integer line and checks `deployedAllies` positions). A vanilla Golem matches none of these → normal base-game target.
- Docs: `events.lua`, `lua_api_reference.md`, `lua_api_reference.md` updated for the `source` param, the pure-targeting (no-damage) semantics, and the corrected `player.id` contract.
**Result:** auto-targeting spells never fire a bolt at the player's own/allied pets and skip an enemy standing behind a pet; a vanilla Golem is a normal targetable base-game monster (no outline). Pets are **not** made damage-immune (a bolt that *is* fired still damages whatever it hits; pure-AoE spells like Apocalypse don't auto-target and are unaffected) — that QoL is deferred.
**Known limitations (deferred to Phase 10 net-sync):** the hook is caster-agnostic, so on the local client a *friendly* other-Hunter pet is skipped for any caster; the path check only enumerates **our own** `deployedAllies` (a friendly other-Hunter pet in the path is not detected — no access to a remote client's list); and `isOtherHuntersAlly` still cannot distinguish another player's tamed pet from their vanilla Golem. None of these affect single-player or the player's own pets/Golem.
**Files:** `Source/missiles.cpp`, `Source/lua/lua_event.hpp`, `Source/lua/lua_event.cpp`, `Source/lua/modules/player.cpp`, `init.lua`, `assets/lua/devilutionx/events.lua`, `lua_api_reference.md`, `lua_api_reference.md`.

### Tamed ally/minion flashes a selection outline on the frame it dies ✓ (current session)
**Symptom:** When a tamed monster or minion dies, it briefly shows a selection outline for a frame right before its death animation / corpse placement.
**Root cause:** `OnGetMonsterOutlineColor` is queried per-frame while a monster's live sprite is drawn, including during the death animation and on the frame its HP first reaches 0 (in MP the networked death can lag a tick behind the local damage, leaving the monster at 0 HP with its tracking entry/owner state still readable). The handler had no "is this monster dead/dying?" guard, so it could still resolve an outline colour for a monster that is on its way out.
**Fix:** added a thin generic `monster.hasNoLife` readonly binding (`monster.hasNoLife()` → at 0 HP) in `Source/lua/modules/monsters.cpp`, and guarded the top of the `OnGetMonsterOutlineColor` handler to return nil for any monster at 0 HP. Covers every colour branch uniformly (own ally, other-Hunter pet) regardless of which one would have produced the flash. Generic/no-op for vanilla (vanilla returns nil for all monsters anyway).
**Files:** `Source/lua/modules/monsters.cpp` (thin `hasNoLife` binding), `init.lua`, `lua_api_reference.md`.

### Recalled/removed allies persist in the MP level delta — re-create + count inflation on level re-entry ✓ (current session)
**Symptom (latent; surfaced while diagnosing the Skeleton King crash):** In a multiplayer game (incl. solo-hosted), a tamed ally removed from the live level via the Lua `monster:remove()` binding (recall, retame, minion despawn, death cleanup) is **not** removed from the level's network delta. On returning to that level, the ally is re-created as an orphan monster and the replay bumps `ActiveMonsterCount`; with enough accumulated entries this can push the count toward/over `GetMaxMonsters()`.
**Root cause:** Dynamically spawned monsters (golems, raised skeletons, Hork spawns, and all mod spawns via `spawnAt`/`spawnWithDifficulty`/`spawnUniqueAt`) are recorded in `DLevel::spawnedMonsters` by `OnSpawnMonster` so they can be re-created on level reload. Nothing ever **erases** a `spawnedMonsters` entry — monster death only sets `deltaLevel.monster[id].hitPoints = 0` (`delta_kill_monster`), leaving the spawn record intact. `monster:remove()` cleared the live monster (and pulls it from `ActiveMonsters` before `SaveLevel` for the singleplayer path) but left the multiplayer delta untouched. On re-entry, `DeltaLoadSpawnedMonsters` → `LoadDeltaSpawnedMonster` → `EnsureMonsterIndexIsActive` re-creates it and increments the count.
**Fix (thin generic engine helper + Lua-module call site):**
- `Source/msg.cpp` — new `void LuaDeltaRemoveSpawnedMonster(const Monster &monster)`: erases the monster's `spawnedMonsters` entry and invalidates its `deltaLevel.monster[id]` slot (out-of-bounds tile ⇒ `IsMonsterDeltaValid` false). No-op in singleplayer. It resolves the level from `currlevel`/`setlevel` (mirroring `DeltaSaveLevel`), **not** from the player — because `OnLevelExit` recall runs while `currlevel` is still the departing level but `player.plrlevel` is already the destination.
- `Source/msg.h` — declaration.
- `Source/lua/modules/monsters.cpp` — the existing `monster:remove()` binding now calls `LuaDeltaRemoveSpawnedMonster(monster)` before the `ActiveMonsters` compaction (the compaction is now deferred while a game-logic step is in flight — see the re-entrancy fix above; the delta erase always runs immediately). This makes `remove()`'s contract ("silently remove this monster from the level") actually hold across an MP level reload, for any mod — not Hunter-specific.
**Why no guard added to `EnsureMonsterIndexIsActive`'s unguarded `ActiveMonsterCount += 1`:** with stale entries no longer replayed, the replay count is bounded by the live monsters that legitimately fit under the cap, so the unguarded increment is no longer reachable with overflowing data. Hardening that increment further sits on the multi-client replay path and is deferred to Phase 10 net-sync.
**PR note:** all three Source edits are generic delta-hygiene; vanilla never removes a spawned monster mid-level, so `LuaDeltaRemoveSpawnedMonster` is dead code for unmodded play and changes no vanilla save/wire format.

### Deploying a pack-leader unique (Skeleton King) crashes — `PlaceGroup` size_t underflow ✓ (current session)
**Symptom:** On a brand-new dungeon level (solo-hosted MP), with no monsters killed, deploying tamed allies crashed on deploying the **Skeleton King** (reported as the 5th deploy, but the trigger is the unique itself, not the count). Two debug asserts fired: `assert(ActiveMonsterCount <= GetMaxMonsters())` (`monster.cpp` `ProcessMonsters`) and `assert(mid < GetMaxMonsters())` (`scrollrt.cpp` `DrawDungeon`).
**Root cause (unsigned underflow → unguarded placement flood, not a count/slot bug in the spawn path):** The Skeleton King's unique data has `monsterPack = Independent` (≠ `None`). `monsters.spawnUniqueAt` passes `bosspacksize = 0`, but `PrepareUniqueMonst` (`monster.cpp`) gates its pack placement on `uniqueMonsterData.monsterPack != None` — **not** on `bosspacksize` — so it still called `PlaceGroup(minionType = 0, num = 0, &leader, …)`. Inside `PlaceGroup`, the clamp
```cpp
if (num + ActiveMonsterCount > totalmonsters)
    num = totalmonsters - ActiveMonsterCount;
```
underflows: `totalmonsters` is the level's **load-time** monster target, and after deploying allies post-load `ActiveMonsterCount > totalmonsters`, so `totalmonsters - ActiveMonsterCount` (both `size_t`) wrapped to ~1.8×10¹⁹. `PlaceGroup` then placed monsters in an unguarded loop (`PlaceMonster(ActiveMonsterCount); ActiveMonsterCount++` with no per-placement cap check — it relied on the now-broken `num` clamp), flooding `Monsters[]`/`ActiveMonsters[]` past `GetMaxMonsters()` and the 252 array ceiling → assert + heap corruption.
**Why the spawn-path analysis looked clean:** every *deploy-time* guard (`PrepareSpawnSlot`, `spawnAt`, `spawnWithDifficulty`, `spawnUniqueAt`) correctly checks `GetMaxMonsters()` and increments by exactly 1, so 5 deploys can't overflow a 232 cap. The overflow came from `PlaceGroup`'s internal loop, reached only for a **pack-leader unique** (`monsterPack != None`) deployed **post-load** — which is exactly the Skeleton King case. Any such unique would trigger it; the King was just the one tested.
**Fix:** Guard the clamp against `size_t` underflow in `PlaceGroup` — `num = (totalmonsters > ActiveMonsterCount) ? (totalmonsters - ActiveMonsterCount) : 0;`. Generic, not Hunter-specific. No-op for vanilla: at level load `totalmonsters >= ActiveMonsterCount` whenever `PlaceGroup` runs, so the new `else 0` branch never triggers in unmodded play. With the fix, deploying the Skeleton King places 0 pack minions (correct — `spawnUniqueAt` asks for none); the King still raises its 3 skeleton minions afterward through the intended guarded `OnGolemChooseAction` → `spawnSkeletonMinion` → `SpawnMonster` path.
**Files:** `Source/monster.cpp` (`PlaceGroup`).

### Performance degrades with more deployed Tamed monsters — quadratic ally-membership scan ✓ (current session)
**Symptom:** Overall game performance drops as the number of deployed Tamed monsters increases; dozens of *regular* monsters cause no lag.
**Root cause (super-linear scaling in ally count):** the golem target scan is the hot path. `GolumAi` calls `UpdateEnemy` **every tick** for every ally that has no current monster target (i.e. every ally following the player with no adjacent enemy). For a golem/player-minion, `UpdateEnemy` (`monster.cpp:707-741`) iterates **all active monsters** and, per candidate, does a `LineClearMovingMissile` LOS raytrace **and** a `lua::OnGolemCanTargetMonster` call. Regular monsters `continue` out of this branch cheaply (no raytrace, no Lua) — which is why a screen full of normal monsters never lagged. Inside our Lua hooks, `isDeployedAlly` / `getDeployedAllyEntry` did a **linear scan of `deployedAllies`** (O(allies)). Because the targeting hook fires `allies × monsters` times per tick and each call paid an `O(allies)` membership scan, total per-tick work grew with the **square of the deployed count**. The same linear scan also sat in the per-frame `OnGetMonsterOutlineColor` (once per drawn monster) and the per-tick `OnGolemChooseAction` / `OnGolemIdle` chain.
**Fix — two parts:**
1. **O(1) ally membership (pure Lua).** Added a parallel `deployedAlliesById[monsterId] = entry` index, so `getDeployedAllyEntry` / `isDeployedAlly` are **O(1)**. All `deployedAllies` mutations now go through `trackDeployedAlly` / `untrackDeployedAt`, which keep the map in sync (the entry caches its `id` at insert so untrack is safe even if the monster userdata later goes stale). Per-tick targeting drops from **O(allies² × monsters)** to **O(allies × monsters)**, killing the quadratic term; the per-frame outline hook and the idle/choose-action chain drop their inner `O(allies)` scan to `O(1)`.
2. **Lazy line-of-sight (thin generic C++ hook).** The single heaviest per-candidate op was the `LineClearMovingMissile` raytrace, which `UpdateEnemy` precomputed for **every** candidate before calling `OnGolemCanTargetMonster`. Removed that precomputation and dropped the `hasLOS` arg from the hook; added a generic, modder-facing `monster:hasLineOfSightTo(other)` binding. The Lua handler now applies its **cheap distance gates first** (adjacency, owner-distance/engage-range, ranged-capability) and only raytraces line of sight for the few candidates that survive — so a screen of distant monsters no longer costs one raytrace each per ally per tick. The C++ change is a pure removal-plus-thin-callout (no new branching, no signature change to any vanilla function); the reordered Lua handler is logically identical to the old one (`allow ⟺ adjacent OR ((in-engage-lit OR ranged) AND LOS)`).
**Files:** `init.lua` (membership index + all deploy/recall/death/level-exit/minion mutation sites; `OnGetMonsterInfo`, `OnGolemKilledMonster`, `OnGolemIdle` lookups; reordered `OnGolemCanTargetMonster`), `Source/lua/lua_event.hpp/.cpp` (drop `hasLOS` param), `Source/monster.cpp` (`UpdateEnemy`: drop the per-candidate raytrace), `Source/lua/modules/monsters.cpp` (`monster:hasLineOfSightTo` binding), `assets/lua/devilutionx/events.lua` (hook doc).
**Follow-up second pass (current session) — still scaled poorly when standing still:** even after the above, a *parked* party on a populated level lagged, because `GolumAi` re-runs `UpdateEnemy` **every tick** for an idle ally with no locked target (our veto means it rarely locks one), and that scan still called the Lua hook once per active monster, each call allocating several short-lived `Point` userdata (`monster.position` returns by value) plus a `player.self()` lookup → heavy GC churn ∝ allies × monsters. Two more fixes, both matching how the engine already works:
1. **Activation gate (new `monster.isActive` binding + first check in `OnGolemCanTargetMonster`).** Vanilla monster AI early-returns while `activeForTicks == 0` (asleep until the player makes them visible). A tamed ally now does the same: reject any candidate with `not candidate.isActive` **first**, before any position/LOS work. Most monsters on a level are asleep, so the expensive path now runs only for the handful actually awake near the player — the engine-native expression of "pets only engage what the player has engaged."
2. **Per-candidate allocation cut.** `OnGolemCanTargetMonster` caches `candidate.position`/`ally.position` into locals (read once, not 2–3×) and reads a frame-cached owner tile (`cachedOwnerX/Y`, refreshed in `GameDrawComplete`) instead of `player.self()` + `owner.position` on every candidate — removing a C++ usertype call and several `Point` allocations per call. Behaviour-preserving (owner ≤1 tile stale, fine for a radius gate).
3. **Ranged allies no longer thrash-search (targeting/chase consistency).** `OnGolemCanTargetMonster` previously let a ranged ally lock a target *outside* `ENGAGE_RADIUS` (any distance, with LOS), but `OnGolemCanChaseTarget` clears the lock for any target outside that radius and `OnGolemChooseAction` only fires the missile at dist ≤ `RANGED_MAX_DIST` (8). So a ranged ally locked a far active monster → couldn't shoot it → got chase-vetoed (lock cleared) → re-ran the full `UpdateEnemy` scan next tick → re-locked the same monster → repeat every tick. Fix: bound targeting to `ENGAGE_RADIUS` for **all** allies (removed the ranged "target outside the radius" exception), making `OnGolemCanTargetMonster` consistent with `OnGolemCanChaseTarget`. Ranged allies still attack from range *within* the engage zone via `OnGolemChooseAction`; they just don't lock unreachable distant targets. No functional loss (those far locks were always immediately cleared anyway) — purely removes the per-tick re-search. Once a target is locked and stays in range, `GolumAi` skips `UpdateEnemy` (it only scans when `MFLAG_TARGETS_MONSTER == 0`), so locked allies of every type stop searching.
**Follow-up files:** `Source/lua/modules/monsters.cpp` (`monster.isActive` readonly binding), `init.lua` (`OnGolemCanTargetMonster` activation gate + position/owner caching + `ENGAGE_RADIUS` bound for ranged; `cachedOwnerX/Y` refreshed in `GameDrawComplete`).

### Tame scrolls / Tamed monster names missing "Tamed " prefix — full name-wiring audit ✓ (current session)
**Symptom:** "Tamed " prefix missing from multiple surfaces — non-unique scroll names (showed "Lvl N [Name]"), the unique scroll gold floating box (showed bare monster name), and reportedly the monster healthbar. Prefix only appeared in the bottom infobox when hovering a deployed ally.
**Audit — every monster-name / scroll-name surface:**
- **Scroll inventory/recreated name** (`buildScrollParams` L736, `OnCustomItemRecreated` L1137, starter scroll L235): normal scrolls were built as `"Lvl N [Name]"` with no "Tamed " — only *unique* scrolls carried the prefix. The speedbook (`OnGetCustomSpeedbookScrollEntries`) added "Tamed " at display time, so the speedbook looked right but the actual item name (inventory hover) did not. **Fixed:** all three normal-scroll sites now build `"Tamed Lvl N [Name]"`. Speedbook dedup guard (L1166) already prevents double-prefixing. Nothing parses the name for level/type (seed+dwBuff carry that), so the change is display-only and safe.
- **Unique scroll gold floating box** (`OnPrepareUniqueInfoBox` → `items.setCustomUniqueBox` L1915): passed bare `monsterName`. **Fixed:** now `"Tamed " .. monsterName`.
- **Infobox name** (`control_infobox.cpp:422`) and **healthbar name** (`monhealthbar.cpp:147`): **both** call the identical `lua::OnGetMonsterDisplayName(&monster)` on `Monsters[pcursmonst]`. `OnGetMonsterDisplayName` (init.lua L1821) returns `"Tamed " .. monster.name` for deployed allies. Verified these are the *only* two player-facing monster-name surfaces in C++ (all other `monster.name()` uses are debug/log) — no separate wire to fix; the healthbar resolves the same string as the infobox.
**Files:** `init.lua` (L235, L736, L1137, L1915). No C++ change needed.

### Ally kills not recorded for ranged/special (missile) attackers ✓ (current session)
**Symptom:** A deployed unique champion did not accumulate kills, while a deployed Skeleton King (melee) did. Generalised: the kill counter only worked for **melee** allies.
**Root cause (attack-path coverage, not tier/seed):** `allyKillCounts[seed]` is incremented by the `OnGolemKilledMonster` hook. That hook fired from only **one** death path — `StartDeathFromMonster` (`monster.cpp:1017`), the monster-vs-monster **melee** kill, guarded by `attacker.flags & MFLAG_GOLEM`. Ally **ranged/special** attacks deal damage as **missiles**: `CheckMissileCol` → `MonsterTrapHit` (the faction branch, `_micaster == TARGET_PLAYERS` + opposing `isPlayerMinion`) → `MonsterDeath` directly. That path never fired the golem-kill hook, so arrow/fireball/inferno/all special kills went uncredited. The champion was a ranged attacker → no kills; the melee Skeleton King → kills counted. So the differentiator was **attack type, not unique tier or seed keying**.
**Fix (two-hook approach, chosen over a death-logic field after review):** the dying monster carries no "killed by monster" field (only `whoHit`, a player bitmask), so `OnMonsterDeath` alone can't attribute the killer. Allies only deal damage via melee or missiles — two sites — so mirror the existing melee call-out on the missile side. Added one thin guarded call-out in `CheckMissileCol` right after the `MonsterTrapHit` hit, using the existing `missile.sourceMonster()` accessor and the same `MFLAG_GOLEM` guard as the melee site:
```cpp
if (Monster *missileSource = missile.sourceMonster(); isMonsterHit && monster.hasNoLife() && missileSource != nullptr && (missileSource->flags & MFLAG_GOLEM) != 0)
    lua::OnGolemKilledMonster(missileSource, &monster);
```
This covers every missile-based ally attack (arrow, fireball, inferno, lightning, all specials). No new struct state, no signature change; symmetric with the committed melee hook.
**Files:** `Source/missiles.cpp`. (Lua handler `OnGolemKilledMonster` in `init.lua` unchanged — it already keys kills by the ally's seed.)

### Tame scrolls cast from belt with Auto Refill Belt cast a random Tame scroll, not the selected slot ✓ (current session)
**Symptom:** With Auto Refill Belt enabled, casting a Tame scroll from the belt casts a random Tame scroll rather than the belt slot the player selected.
**Root cause:** `UseInvItem` (`inv.cpp`) has an Auto-Refill-Belt redirect: for a belt item it scans InvList (then the rest of the belt) for an item with the same `_iMiscId` + `_iSpell` and uses that one instead, so the belt slot refills from a duplicate. Every Tame scroll shares the same scroll misc id and `_iSpell` (TAME_ID) — only the per-scroll **seed** distinguishes which monster deploys — so the redirect matched the first identical-looking Tame scroll and deployed *its* monster instead of the selected slot's.
**Fix (new generic, modder-facing hook):** added a thin query hook `lua::OnCanAutoRefillBeltItem(player, item, default=true)`. `UseInvItem` folds it into the existing auto-refill guard via one local (`allowAutoRefill = autoRefillBelt && OnCanAutoRefillBeltItem(...)`) used by both redirect loops — no new branching, default true = vanilla. Lua handler returns **false** for `item:isScrollOf(TAME_ID)`, so a belt Tame-scroll cast always uses the exact selected slot. Generic: any mod can exempt a seeded/custom item type from belt auto-refill.
**Files:** `Source/lua/lua_event.hpp`, `Source/lua/lua_event.cpp`, `Source/inv.cpp`, `assets/lua/devilutionx/events.lua`, `init.lua`.

### Tamed monster shows no hover feedback (healthbar/infobox) — ONE specific monster — closed (no code change, not reproduced)
**Note: closed per user decision, NOT a code fix.** A single deployed ally once showed no healthbar/infobox on hover, reproducible only for that one monster/scroll that session. Investigated but **no obvious code cause** found and it did not recur on retest, so it was closed without a fix. If it returns, this is the place to start.
**Symptom:** One specific deployed ally shows no healthbar/infobox on hover; recasting/retaming it keeps the bug, every other ally that session is fine. Retame still "works" on it.
**Investigation (inconclusive):**
- Hover feedback needs `pcursmonst` set (cursor.cpp `TrySelectMonster`) → then infobox (`control_infobox.cpp`) and healthbar (`monhealthbar.cpp`) render via `OnGetMonsterDisplayName` / `OnGetMonsterInfo`. Selection of a player-minion delegates to `OnGolemCanSelect` → `isDeployedAlly`.
- Retame resolves its target from the raw tile (`dMonster[targetX][targetY]` in `lua_event.cpp` `OnSpellActionFrame`), **not** cursor selection — so "retame works" does **not** prove the monster is cursor-selectable. If `isDeployedAlly` is false for it, retame would re-**capture** (new scroll, **same typeId**) rather than recall, which would also explain why the bug persists across recasts.
- Reviewed the `deployedAllies` lifecycle and lookups (`getDeployedAllyEntry`, `OnGetMonsterInfo` loop) — all consistent; monster array slots are stable in DevilutionX (only `ActiveMonsters` reorders), so `entry.monster.id` shouldn't drift. No single obvious break found. Ruled out: not the struct/array-size pass; not the name-wiring.
**Leading hypotheses if it recurs:** (a) that one ally's `deployedAllies` entry got dropped or mismatched while the monster stayed alive (→ `isDeployedAlly` false → all three hooks fall back to default + retame re-captures); or (b) a stale/odd `typeId` from that scroll's seed yielding bad type data. **Debug in-game** (no logging per project rules): on the broken monster, surface via a screen message whether `isDeployedAlly(hovered.id)` is true and what `getDeployedAllyEntry` returns, and whether casting Tame on it recalls vs. re-captures.

### Null-sprite render crash on redeploy — stale cross-version scrolls (current session)

**Symptom:** With several allies out (≈4 uniques + a Hidden) on dlvl 3, redeploying previous-session tame scrolls and casting a normal "Shadow Beast" scroll crashed with a flood of `Draw Monster: tried to draw illegal monster -1` then `assertion failed (clx_sprite.hpp:599) value_.data_ != nullptr`.

**Resolution — not a live bug; stale data.** The `illegal monster -1` lines are harmless (offset-draw of a moving monster's empty neighbour tile). The crash is a **null sprite** (`currentSprite()` on an empty sprite list). Diagnosis:
- **Golem logic ruled out.** Verified against `monstdat.tsv`: every AI our handlers route through the Special animation is backed by a `hasSpecial=true` type, and every `hasSpecial=false` type we touch (Bat/Snake → charge = Attack anim; GoatRanged/Succubus → ranged = Attack anim) is only ever driven with an animation it has. For any *correctly-spawned* monster the handlers mirror vanilla and never start a missing animation. (A `hasSpecialAnim` Lua gate was prototyped and reverted — it never fires for a real monster and reads the static flag, not actual sprite presence.)
- **Root cause = cross-version scroll corruption.** The monster type is stored as a raw `_monster_id` integer in the scroll **seed** (`allocSeed`: `typeId` in the low 16 bits). `_monster_id` is a base-game enum whose numeric values shift when monster types are added/reordered upstream. A scroll tamed on an older base build therefore decodes, after a codebase update, to a *different* or **out-of-range** `typeId`. The normal-scroll spawn path (`spawnWithDifficulty` → `MonstersData[static_cast<_monster_id>(typeId)]`) does **not** range-check, so a stale/out-of-range type is an out-of-bounds read → a garbage `CMonster` with no real animations → null sprite. (Unique scrolls already validate `uniqueTypeIdx` and refund — which is why the 4 uniques were fine and the normal Shadow Beast scroll crashed.)
- This is also **not** the Max-HP/`dwBuff` bug — `typeId` lives in the seed, not `dwBuff`.

**Decision (live development):** old scrolls are disposable. Resolved by **re-taming on the current build / fresh character**; no compatibility shim or `typeId` range-guard added (declined intentionally). If stale-save robustness is ever wanted, mirror the unique path's validation in the `spawnWithDifficulty` binding (return nil → refund) — a one-line input-validation change in `Source/lua/modules/monsters.cpp`.

### Tamed monster Max HP changes on retame / recast / level load ✓ (current session)

**Symptom:** A tamed monster's Max HP was not stable — it changed when the ally was recalled and re-cast, and on level loads, as if the HP range were re-rolled on every cast; the value could also shift with dungeon level (`dlvl`).

**Root cause (two parts):**
1. **Max HP was never restored on deploy.** The deploy handler called `newMonster:setHitPoints(data.savedHp)` (current HP only). The monster's `maxHitPoints` was left at whatever `spawnWithDifficulty`/`InitMonster` re-rolled from the type's min/max range (× difficulty/level scaling) — a fresh roll every deploy. The persisted `maxHp` was used only for the info box / Pepin healing, never applied to the live monster.
2. **The persisted `maxHp` was lossy.** `dwBuff` stored `maxHp/8` in 8 bits — quantized to multiples of 8 and **hard-capped at 2040**, so high-HP uniques/bosses (especially in Nightmare/Hell) couldn't round-trip even if restored.

**Fix:**
- Added a thin `monster:setMaxHitPoints(hp)` binding (mirrors `setHitPoints`) in `Source/lua/modules/monsters.cpp`.
- Deploy now restores the persisted max verbatim: `newMonster:setMaxHitPoints(data.maxHp)` before `setHitPoints(data.savedHp)`. Restoring the exact captured value makes Max HP stable across recall/redeploy/level-load and sidesteps any difficulty/`dlvl` re-application (the override is authoritative; other stats stay frozen at `capturedDifficulty`).
- Re-laid-out `dwBuff` so `maxHp` is stored at **full 15-bit resolution** (bits 1-15, 0..32767) and current HP is stored as a **percent of max** (bits 24-30), which also guarantees `savedHp ≤ maxHp`. `encodeDwBuff`/`decodeDwBuff` keep their signatures; callers are unchanged.

**Compatibility:** the new `dwBuff` layout differs from the old one, so scrolls tamed before this change decode to wrong HP until re-tamed (or healed at Pepin, which re-encodes). Acceptable in development.

**Files:** `Source/lua/modules/monsters.cpp` (thin `setMaxHitPoints` binding), `init.lua`

### Five regressions from one mod-load crash: incomplete `monsters.AIID` table ✓ (current session)

**Symptoms (all five reported together):**
1. Tamed monsters no longer display "Tamed " at the front of their names.
2. Tamed monsters no longer "snap back" when 12+ tiles away (leash).
3. Tamed monster outline no longer displays properly.
4. Tamed Hidden (Sneak) allies are permanently invisible and show no outline.
5. Unique Tame scrolls show "The Butcher's Cleaver" info again instead of the custom monster box.

**Single root cause:** `Source/lua/modules/monsters.cpp` exposed only a hand-picked **subset** of the `MonsterAIID` enum in `monsters.AIID` (9 of 41 values). `init.lua` builds a top-level table literal:
```lua
local AVOIDANCE_RANGED = {
  [monsters.AIID.Magma] = true, [monsters.AIID.Storm] = true, [monsters.AIID.Acid] = true,
  [monsters.AIID.Diablo] = true, [monsters.AIID.BoneDemon] = true,
}
```
`Magma/Storm/Acid/Diablo/BoneDemon` were **missing** from the C++ table, so each read back as `nil`. In Lua, `t[nil] = v` (a nil **key**) raises **"table index is nil"** — a hard error thrown **during mod load** at that line.

Everything registered **before** that line still worked (taming, deploy, golem combat, targeting, selection, follow, `OnGetMonsterInfo`). Everything registered **after** it never registered: the `OnGolemChooseAction` handlers (ranged / hybrid specials / **Sneak fade-in**), `StoreOpened` (Pepin HP restore), the `GameDrawComplete` **leash** (bug 2), `OnGetMonsterDisplayName` (bug 1), `OnGetMonsterOutlineColor` (bugs 3 & 4 outline), and the `OnLevelEnter` unique-scroll-box fixup (bug 5). The "permanently invisible" Hidden (bug 4) was the lost Sneak fade-in in `OnGolemChooseAction`.

**Fix:** `monsters.AIID` now exposes the **complete** `MonsterAIID` enum (generic, modder-facing), so no referenced AI key is ever nil. Prevents this whole class of nil-key load crash from recurring.

**Lesson:** A nil **value** is harmless (`t[k] == nil`), but a nil **key** in a table constructor/assignment throws. When a mod indexes a C++-provided constant table to build a key set, the C++ table must expose every constant the mod names — expose the full enum, not a subset.

**Files:** `Source/lua/modules/monsters.cpp`

### Engine array capacity pass (current session)

#### Engine monster cap blocks Hunter ally deployment on full dungeon levels ✓
**Symptom:** On populated dungeon levels, `MaxMonsters` (200) is already at capacity from naturally spawned enemies. All `spawnWithDifficulty` / `spawnUniqueAt` calls return nil simultaneously — all 8 allies fail to deploy. Scroll refunds fire correctly but the Hunter cannot deploy until enemies are killed. The level monster-TYPE table (`MaxLvlMTypes`, 24) had the same problem for distinct tamed species.
**Fix:** Both caps are now mod-extensible at load time with **zero effect on unmodded play** (save/wire formats byte-identical). Generic, modder-facing — nothing Hunter-specific in the engine.
- **Type table:** `LevelMonsterTypes` is now a `std::vector<CMonster>` sized to `GetMaxLvlMTypes()` = `MaxLvlMTypes` + mod extension. Lua: `monsters.requestExtraTypes(n)`.
- **Live monsters:** backing arrays sized to a new `AbsoluteMaxMonsters = 252` ceiling; the runtime logical cap is `GetMaxMonsters()` = `min(200 + extension, 252)`. Lua: `monsters.requestExtraMonsters(n)`. Natural-placement caps stay frozen at `MaxMonsters` so vanilla spawns keep the low slots and the extension is reserved for mod spawns.
- **Hard ceiling = 252:** the enemy reference (`Monster.enemy`, `DMonsterStr.menemy`, `TSyncMonster._menemy`) is a `uint8_t` packing monster targets into `[0, GetMaxMonsters())` and players above; `GetMaxMonsters() + MAX_PLRS` must fit in a byte. Raising past 252 needs uint16 widening (breaks vanilla wire/save). 252 covers ~190 natural + 32 allies.
- **Hunter mod:** `init.lua` calls `requestExtraTypes(32)` and `requestExtraMonsters(32)` at load (4 Hunters × 8).
**Files:** `Source/monster.h/.cpp`, `Source/msg.cpp`, `Source/sync.cpp`, `Source/multi.cpp`, `Source/engine/render/scrollrt.cpp`, `Source/monsters/validation.cpp`, `Source/loadsave.cpp`, `Source/debug.cpp`, `Source/lua/modules/monsters.cpp`, `Source/lua/modules/dev/monsters.cpp`, `init.lua`

### Seed scroll/scroll pass (current session)

#### Same-unique scrolls share kill count / only one shows "Unique" gold ✓
**Symptom:** With two scrolls of the same unique (e.g. two Butchers), they shared a single kill count and only one ever showed the gold "Unique Item" effect.
**Root cause:** `nextScrollSeed` is a session local that resets to 1 each launch and was never persisted, so a scroll tamed in a later session could be issued the **same seed** as an existing one. Kill counts (`allyKillCounts[seed]`), unique status (`seedGetUniqueType`), and the gold visual (`findScrollBySeed` — first match only) all key off the seed, so the two scrolls were conflated. (No collision occurs within a single session because the counter increments.)
**Fix:** `OnLevelEnter` now bumps `nextScrollSeed` past the counter of every held Tame scroll (self-healing each load), so freshly tamed scrolls never collide with existing ones. Already-collided scrolls keep their shared seed until re-tamed.
**Files:** `init.lua`

#### Retame produces a non-unique scroll (normal name, no gold) though data is intact ✓
**Symptom:** Recalling a unique ally produced a scroll that displayed as a normal Tame scroll — normal "Lvl N" name, no gold — even though its seed/data (hover infobox) were still the correct unique.
**Root cause:** `allyToMonsterData` (used by `recallAllyToInventory`) derived unique-ness from the live monster's `ally.uniqueType`, which can read back as `None` for a deployed ally — unlike every other site, which keys off the seed (`seedGetUniqueType`). With `uniqueTypeIdx` nil, `buildScrollParams` named the scroll "Lvl N …" and the `magical = 2` gild was skipped, while the seed (preserved from `entry.seed`) stayed unique-encoded — hence "displays normal but data intact". (A level transition would later re-gild it via `OnLevelEnter`, masking the issue.)
**Fix:** `allyToMonsterData` now derives `uniqueTypeIdx` from `seedGetUniqueType(entry.seed)` — the same source of truth used everywhere else.
**Files:** `init.lua`

#### Duplicate-unique block bypassed on hotkey casts (the "weak link") ✓
**Symptom:** After certain casts, attempting to deploy a second copy of an already-out unique was not refused up front ("I can't do that"); instead it deployed-then-refunded via the safety net — different feedback than the clean upfront block.
**Root cause:** `OnCanCastScroll`'s dup check relied solely on `selectedCustomScrollSeed`, which is 0 for hotkey / unknown-selection casts, so the check was skipped and the cast fell through to the `OnSpellActionFrame` refund safety net.
**Fix:** When `selectedSeed` is 0, `OnCanCastScroll` now falls back to the first Tame scroll in inventory — the same first-match the deploy path resolves to — so the upfront block fires reliably either way.
**Files:** `init.lua`

#### Only the first unique deployed per session; rest failed to place with no refund ✓
**Root cause:** Lua forward-reference bug — `isUniqueTypeDeployed` (top of `init.lua`) called `seedGetUniqueType`, declared `local` ~60 lines later, so it bound to a nil global. The call only ran when `deployedAllies` was non-empty, throwing inside the protected `OnSpellActionFrame` → handler aborted before `spawnUniqueAt`, scroll consumed with no refund.
**Fix:** Moved `isUniqueTypeDeployed` below `seedGetUniqueType`. (Lesson: define seed/helper locals before any function that calls them.)
**Update (2026-06-24):** this whole class of forward-reference bug is now structurally impossible for top-level helpers. The init.lua sandbox-global sweep made every top-level helper a **global** (only the inter-mod surface — the module requires, `luanet`, and the net layer — stays `local`; see the CONVENTION comment block at the top of init.lua), and globals resolve at **call time**, so call-before-define no longer binds to nil. Order still matters for the kept `local` net forward-decls only.
**Files:** `init.lua`

#### Unique tame scroll deployed the wrong monster (stacked non-unique scroll) ✓
**Root cause:** All Tame scrolls share one `TAME_ID`; speedbook entries are cosmetic name groupings. The cast queued `spellFrom == 0`, so `OnSpellActionFrame` (deploy) and `ConsumeScroll` each resolved to the **first** `TAME_ID` scroll, which could be a different scroll than the one clicked.
**Fix:** New generic hook `lua::OnResolveCustomScrollSlot(player, spellId, selectedSeed, defaultSlot)` resolves the exact `INVITEM_*` slot the player selected (exact-seed match, else same monster-type / unique-index fallback). `SpellListItem`/`Player` carry `customScrollSeed`/`selectedCustomScrollSeed`; new Lua API `player:findScrollSlotBySeed`. Seed logic stays in Lua.
**Files:** `Source/panels/spell_list.hpp`, `Source/panels/spell_list.cpp`, `Source/player.h`, `Source/player.cpp`, `Source/lua/lua_event.hpp/.cpp`, `Source/lua/modules/player.cpp`, `assets/lua/devilutionx/events.lua`, `init.lua`

#### Share Potion said "I can't do that" with potions in hand ✓
**Root cause:** `applySharePotion` detected potions by base item index (`item.IDidx`), which didn't match the held potions.
**Fix:** Detect by effect (`item.miscId == items.ItemMiscID.Heal/FullHeal`) — same pattern the Potion of Forgetting handler uses — and capture the matched item's `IDidx` for removal.
**Files:** `init.lua`

#### Tame scroll consumed when deploy blocked by cap / duplicate-unique ✓
**Root cause:** Both limits were checked mid-cast in `OnSpellActionFrame` (after commit), so the early return skipped the deploy but `ConsumeScroll` still ran.
**Design:** Knowable limits refuse the cast up front (no consumption); the scroll-copy refund is reserved for unpredictable spawn failures.
**Fix:** New generic pre-cast veto hook `lua::OnCanCastScroll(player, spellId, selectedSeed)` in `CheckPlrSpell` (part of the Scroll `addflag`); Lua does the cap + dup check and says the line. `OnSpellActionFrame` cap/dup kept only as refunding safety nets (shared `refundTameScroll` helper).
**Files:** `Source/player.cpp`, `Source/lua/lua_event.hpp/.cpp`, `assets/lua/devilutionx/events.lua`, `init.lua`

#### Upfront cap/dup block skipped when a scroll is used directly from inventory/belt ✓
**Symptom:** Casting a Tame scroll via the speedbook correctly refused a duplicate-unique / cap-exceeded deploy ("I can't do that", no consumption), but **right-clicking the scroll directly in inventory or belt** deployed-then-refunded instead.
**Root cause:** Direct item use goes `UseInvItem` → `UseItem` → `CMD_SPELLXY`, never through `CheckPlrSpell` where the `OnCanCastScroll` veto lives. So the upfront gate was bypassed and the cast fell through to the `OnSpellActionFrame` refund safety net. (Deploy/consume were already precise on this path — `UseItem` passes the exact `spellFrom` slot — so only the upfront veto was missing.)
**Fix:** Call the existing `lua::OnCanCastScroll(&player, item->_iSpell, item->_iSeed)` in `UseInvItem` (with the exact scroll's seed) before the item is used; a `false` returns without casting/consuming. Covers inventory, belt, and gamepad use (all funnel through `UseInvItem`).
**Files:** `Source/inv.cpp`, `init.lua` (handler already present)

#### Out-of-bounds write past the level monster-type cap (MaxLvlMTypes) ✓
**Root cause:** `EnsureMonsterType` called `AddMonsterType` without a cap check; at capacity it indexed `LevelMonsterTypes[24]` out of bounds.
**Fix:** `EnsureMonsterType` returns nil at the cap, so the spawn returns nil and the deploy refunds the scroll (a legitimate, unpredictable spawn failure).
**Files:** `Source/lua/modules/monsters.cpp`

### Earlier fixes

### Hidden-type ally freezes when it goes idle — can't attack, can't be targeted ✓
**Symptom:** A deployed Hidden-type (Sneak) ally attacked fine if it had a target immediately, but the moment it went idle it froze — wouldn't attack again, couldn't be targeted/selected.
**Root cause:** `GolumAi` (`monster.cpp`) runs `OnGolemChooseAction` every tick unless the golem is in an uninterruptible mode — the guard listed MeleeAttack/RangedAttack/SpecialMeleeAttack/Heal/Charge but **not** `FadeIn`/`FadeOut`. While the stealth ally was mid-fade, the AI fired again, the Lua handler re-saw "visible + no target" (or mid-fade-in "not hidden") and called `startFadeout`/`startFadein` again, resetting the animation to its last frame every tick. The fade never completed → stuck perpetually restarting a fade, frozen and unselectable.
**Fix:** Added `MonsterMode::FadeIn`/`MonsterMode::FadeOut` to that `GolumAi` guard. The fade now completes via `UpdateModeStance`/`MonsterFadeout` (AI-independent) before the AI runs again. Generic/no-op for vanilla golems (which never fade).
Files: `Source/monster.cpp`

### Unique infobox popup shows "Level: 0" ✓
`OnPrepareUniqueInfoBox` (`init.lua`) reads `level` from `decodeDwBuff(item.buff)`, but `buildScrollParams` hardcoded `0` as the level when encoding **unique** scrolls (their name uses "Tamed [Name]" with no "Lvl N" prefix, so the level field was left unset). Fix: encode `monsterData.level` into dwBuff for unique scrolls too (name format unchanged); `recoverScrollData`'s unique branch also carries `level` through.
Files: `init.lua`

### Speedbook shows "Tamed Tamed [Name]" for unique monster scrolls ✓
`buildScrollParams` stores unique scroll names with a `"Tamed "` prefix. `OnGetCustomSpeedbookScrollEntries` unconditionally prepended `"Tamed "` again. Fix: check `name:sub(1,6) == "Tamed "` before prepending.

### Unique tame scroll deploy: PrepareUniqueMonst failure silently consumed scroll ✓
`spawnUniqueAt` returned the live `Monster*` even when `PrepareUniqueMonst` failed, so Lua never saw nil and never refunded the scroll. Fix: on failure, remove monster light, clear `dMonster`, mark invalid, call `DeleteMonsterList()`, return `nullptr`.
Files: `Source/lua/modules/monsters.cpp`

### Tame scroll silently consumed when spawn fails ✓
When `spawnWithDifficulty` / `spawnUniqueAt` returned nil, `ConsumeScroll` still fired. Fix: before returning, call `addScrollByMapping` to add a copy — `ConsumeScroll` removes the original by slot, the copy survives as the refund. Floor fallback if inventory full.

### SaveItem heap corruption / crash on save ✓
`SaveItem` wrote `_iLuaData` (4 bytes) past the `SaveHelper` buffer allocated by the unchanged `DiabloItemSaveSize`/`HellfireItemSaveSize` constants. Fix: removed `_iLuaData` from `SaveItem`/`LoadItem`; mod data now persisted in a separate `"luamoddata"` MPQ entry via `OnSavePlayerData`/`OnLoadPlayerData`.

### Vanilla Golem treadmill after re-summon ✓
`OnGolemIdle` returned `false` (stand still) for non-deployed golems. `MT_GOLEM` has `Stand=0` frames, so it played the walk animation while stationary. Fix: return `nil` for non-deployed golems so the engine's original random-walk runs.

### Panel hover InfoBox not showing Tame+ skill name ✓
`control_infobox.cpp` read `GetSpellData(spellId).sNameText` raw, bypassing `OnGetSpeedbookSpellName`. Fix: compute `spellDisplayName` via `lua::OnGetSpeedbookSpellName` before the panel-hover switch block.

### Unique monsters require level 45 to tame ✓
`isQuestMonster = isUnique() || MT_DIABLO` made all uniques quest monsters; `isChampion = isUnique && !isQuestMonster` was always false, pushing all uniques to the `isBoss` path (level 45 gate). Fix: `BOSS_NAMES` Lua table (13 named quest bosses) distinguishes champions from named bosses. Three-tier system restored.

### Ranged tamed monsters walk into melee instead of attacking at range ✓
`GolumAi` only does melee. Fix: `OnGolemChooseAction` hook fires before the melee block; ranged allies fire `startRangedAttack` at distance 3–8 with LOS.

### Late-registered monster type corpse crash ✓
Tamed monsters registered after `InitCorpses()` had `corpseId = 0`. On death, `AddCorpse(tile, 0, dir)` wrote direction bits to `dCorpse`; renderer computed `Corpses[-1]` → null sprite → assert crash. Fix: `RegisterLateMonsterTypeCorpse` scans from `stonendx` for a free `Corpses[]` slot and populates it from the type's death animation data.
Files: `Source/dead.cpp`, `Source/dead.h`, `Source/lua/modules/monsters.cpp`

### Manual retame dropped scroll at ally's tile ✓
Casting Tame on a deployed ally dropped the scroll at the ally's tile, often unreachable. Fix: manual retame calls `recallAllyToInventory` — scroll goes to inventory/belt; drops at caster's feet if full.

### Cast Instant-Fire (Tame / Share Potion) ✓
`OnSpellCast` fires at frame 0 (cast initiation) — before the animation begins. All Hunter effect logic fired immediately. Fix: new `OnSpellActionFrame` hook in `DoSpell` fires at `currentFrame == _pSFNum` (frame 14 for Hunter). Tame and Share Potion handlers moved there.

### monster.cpp ADL ambiguity (C2668 build error) ✓
Adding public declarations for `AiPlanPath`, `StartEating`, `StartHeal`, `ScavengerFindCorpse` (and later `StartFadein`/`StartFadeout` for the stealth-ally rework) to `monster.h` caused "ambiguous call" errors — each call site inside `monster.cpp` matched both the anonymous-namespace version and the `devilution` namespace version via ADL. Fix: moved the definitions out of the anonymous namespace to after it closes, making them unambiguously `devilution::`. **When exposing any other anon-namespace `monster.cpp` helper to Lua, move its definition out the same way.**
Files: `Source/monster.cpp`, `Source/monster.h`

### monsters.cpp walkToward narrowing conversion (C2398 build error) ✓
`walkToward` lambda assigned `int` values `x`/`y` directly into `monster.enemyPosition` (`WorldTileCoord = uint8_t`). Fix: wrap with `static_cast<WorldTileCoord>()`.
Files: `Source/lua/modules/monsters.cpp`

### Unique tame scroll hover popup shows "The Butcher's Cleaver" ✓
`magical = 2` triggers `DrawUniqueInfo` → `UniqueItems[curruitem._iUid]`; `_iUid` defaults to 0 = Butcher's Cleaver. Fix: `OnPrepareUniqueInfoBox` query hook fires after `curruitem = item` in `PrintItemDetails`. For unique tame scrolls, Lua calls `items.setCustomUniqueBox(name, lines)` to populate `g_luaUniqueSlot`, then returns `true`. C++ sets `curruitem._iUid = UITEM_LUA_CUSTOM` (0x7FFF). `DrawUniqueInfo` early-exits for that sentinel and renders monster name + tier/difficulty/level/HP/kills. Gold appearance (`magical = 2`) fully restored in all paths.
Files: `Source/items.h`, `Source/items.cpp`, `Source/lua/lua_event.hpp`, `Source/lua/lua_event.cpp`, `assets/lua/devilutionx/events.lua`, `Source/lua/modules/items.cpp`, `init.lua`

### Tamed ally cursor hover inconsistency ✓
**Root cause:** A debug `log.info(...)` line inside the `OnGolemCanSelect` handler. Mods run in a restricted sandbox (`CreateLuaSandbox`, `Source/lua/lua_global.cpp`) that exposes only built-ins + `os` + `require` + `SfxID` — **`log` is not a sandbox global** (it is the `devilutionx.log` package and must be `require`d). The line threw whenever `#deployedAllies > 0`, and `OnGolemCanSelect` (a protected call) swallowed the error and returned its default `false`. The gold outline kept working because `OnGetMonsterOutlineColor` runs the same `isDeployedAlly` check but never touches `log`.
**Fix:** Removed the debug block. Also fixed the same class of bug in `OnGolemIdle` — `Point.new` is likewise unavailable in the sandbox; replaced by offsetting a writable copy of `owner.position`.
**Lesson:** Never reference `log`/`Point`/`inspect` as bare globals in mod code — they are not in the mod sandbox. An unhandled throw in a query hook silently degrades it to the C++ default.

### IsTileSafe nullptr crash during ally charge ✓
**Root cause:** `StartGolemCharge` fired the `MissileID::Rhino` charge missile with `TARGET_MONSTERS`, while every vanilla Rhino cast uses `TARGET_PLAYERS`. `Missile::sourceMonster()` returns `nullptr` unless `_micaster == TARGET_PLAYERS`, so the ally's charge missile had a null source; `MoveMissilePos` dereferenced it → crash (only for E/W/S/SE/SW charge directions).
**Why `TARGET_MONSTERS` was inert anyway:** the Rhino impact picks its victim from the monster's `MFLAG_TARGETS_MONSTER` flag, which tamed allies have cleared, so the charge is a no-damage gap-closer regardless of caster.
**Fix:** `StartGolemCharge` (`monster.cpp`) uses `TARGET_PLAYERS` like the vanilla casts.
**Files:** `Source/monster.cpp`, `Source/lua/modules/monsters.cpp`

### Hidden-monster (SneakAi) ally always invisible — stealth-ally rework ✓
**Root cause:** All four Sneak types carry `HIDDEN` in their `abilityFlags` (`monstdat.tsv`), and `InitMonster` does `monster.flags = monster.data().abilityFlags`, so a freshly spawned Sneak monster is hidden from frame 0. Normally `SneakAi` fades it in when an enemy approaches, but once `makeGolem` sets `ai = Golem`, `SneakAi` never runs again and `GolumAi` had no fade logic, so the ally stayed cloaked permanently.
**Fix (kept the cloak as a feature):**
- **Engine render** (`scrollrt.cpp`): the `MFLAG_HIDDEN` early-return still queries `OnGetMonsterOutlineColor` and draws the outline when color `>= 0`. Hidden allies show their outline; vanilla hidden monsters (color `-1`) unchanged.
- **Engine selection** (`cursor.cpp`): player minions delegate to `OnGolemCanSelect` before the `MFLAG_HIDDEN` guard, so cloaked allies stay hoverable.
- **API**: `StartFadeout`/`StartFadein` in `monster.h`; Lua `monster:startFadeout()` / `:startFadein()` / readonly `monster.isHidden`; `MonsterAIID::Sneak` in `monsters.AIID`.
- **Mod AI** (`init.lua`): `OnGolemChooseAction` for `originalAiId == AIID.Sneak` — fade in to strike within `SNEAK_FADE_IN_DIST` with LOS, else re-cloak.

### MP: floor-traded Tame Scroll carries STALE Plane-2 data — traded Bonded scrolls lose kills/Bonded state ✓ (retest PASSED 2026-07-08)
**RETEST PASSED 2026-07-08 (user, two-client, same dlvl, post-recompile):** owner Bonds + recalls + mouse-drops; the other Hunter picks up → correct Bonded scroll, deploys the Bonded monster properly; the return trip (second Hunter re-keys, deploys, recalls, drops back to the original owner) round-trips correctly too. The one residual — the FLOOR copy reading "Tamed" on the non-dropper until pickup, pre-named in the retest markers below as a known cosmetic — graduated to its own High entry (floor-copy presentation) and is fixed there.
**Reported:** 2026-07-07 (user): Hunter A drops a Tame Scroll containing a **Bonded** monster; Hunter B sees the floor/picked-up scroll named "Tamed …"; deploying yields a NON-Bonded ally with stale/zero kills. Escalation same day: a traded **Bonded Dark Lord** came back "~7 kills, not Bonded" — a whole session of progression missing. **Clean repro 2026-07-08 (user, screenshots):** Remote Bonds a Fallen One (kills 1, `BONDED_KILLS_PER_LEVEL=1`), drops the scroll, same-level Host sees "Tamed Lvl 1 Fallen One" and deploys a kills=0 pet — while the pet's OH tag ("Ash") arrived CORRECTLY.
**ROOT CAUSE (verified in engine source, and it reproduces every observed detail):** `lua::OnItemDropped` — the hook that runs the mod's entire drop-time announce (`setItemDeltaModData` + the `SD` blob broadcast) — fired **only inside `TryDropItem` (`plrctrls.cpp`), which the ordinary MOUSE drop never reaches.** The mouse click-on-world drop (`diablo.cpp` `LeftMouseDown` held-item branch, line ~406) sends `CMD_PUTITEM` directly; `CloseStash` (`inv.cpp`) is a third uncovered drop site. All user drops are mouse drops → **no SD was ever sent at drop time, ever.** The vanilla item wire (`TItem`) carries no modData (by design — frozen format), so the peer's floor copy is blob-less, and pickup fell back to `receivedBlobs[seed]` = whatever the LAST SD for that seed carried — the fresh-tame / pickup-re-key era snapshot. That snapshot has kills=0 (Fallen One) or ~7 (the Dark Lord's re-key moment) **but a correct OH name — exactly matching the screenshots.** Not Diablo-specific, not ordering, not a stale-overwrite: the fresh data simply never left the owner's client.
**Fix (engine, 2 one-line call-outs):** `lua::OnItemDropped(...)` now fires at ALL manual-drop paths — added the identical call-out (immediately after the same `NetSendCmdPItem`, `HoldItem` still valid, mirroring the existing `TryDropItem` site) to the `diablo.cpp` `LeftMouseDown` mouse drop and the `inv.cpp` `CloseStash` force-drop (the fourth site, `InvGetItem`'s swap-drop, landed with the cursor-pickup fix). Zero logic; no mod loaded = a no-op event. Documented in `cpp_changes/items.md` §OnItemDropped.
**Fix (init.lua, two completions):** (1) pickup blob candidates include the level delta (the authoritative at-rest copy; survives a session restart, which `receivedBlobs` does not); (2) pickup re-stamps the scroll's name/gold via the shared `restampScrollPresentation(item)` (factored out of `OnCustomItemRecreated`).
**Removed (2026-07-08, the item-pipe consolidation):** the monotonic `blobKills` guard (SD receiver + freshest-wins pickup selection). Built BEFORE the root cause was found; defended against a trigger nobody could name (an SD can't regress a cache: only the current holder of a seed ever announces it, every emitter builds the blob from live tables at send time, same-sender messages arrive in order). Guarding against confusion (vs. reconciling against nameable loss, like the RS heartbeat) is the anti-pattern. Pickup uses explicit first-non-empty precedence: item's own blob → level delta → `receivedBlobs` → own tables.
**Residual markers not yet exercised:** the off-level drop (peer walks to the level later — the delta path) and drop-and-quit (dropper quits to menu, peer relogs) — spot-check opportunistically.
