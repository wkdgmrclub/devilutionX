# Development Notes — Active Task

> **The ONE live doc.** Exactly one task in flight at a time. When it ships, graduate it (hook rows →
> `lua_api_reference.md`, bindings → `lua_api_reference.md`, engine code+why → `cpp_changes/`, dated
> entry → `HISTORY.md`, subsystem reasoning → `net_sync.md`) and **delete it from here.** See
> `README.md`.

---

# Taming Diablo — status: core mechanics PLAYTESTED ✅ (2026-07-07) — graduation blocked on bugs.md

Roadmap §3. Diablo is now tameable at **Tame+++** (CLVL 45, ≤5% HP). All four requirements + the
multi-target Apocalypse + the everyone-gets-credit MP rule are implemented and **passed the user's
playtest 2026-07-07**. Hook row + binding docs live in `lua_api_reference.md`; class-design summary in
`hunter_class_design.md` ("Diablo status"); binding rationale in `cpp_changes/monsters.md`.

**Before graduating to `HISTORY.md` — the Diablo-fallout entries at the top of `bugs.md`:**
1. **Apoc Boom HP corruption** ("enemy health goes UP per boom hit", "500 health bars") — observed in
   two-client MP (the user's standard setup); no addition exists in the code path, so it is HP
   corruption rendered as growth. The MP leads are primary (every-client boom simulation +
   cross-broadcast `CMD_MONSTDAMAGE`; missile-time to-hit rolls off the synced RNG; boom re-resolves
   every tick until `_miHitFlag`); the damage-scale audit is the fallback.
2. **Diablo Tame Scroll presentation** — must present as a UNIQUE scroll ("Tamed/Bonded The Dark
   Lord", no "Lvl 30"; hover popup regresses to "The Butcher's Cleaver" — the
   `OnPrepareUniqueInfoBox` handler keys on the unique seed only).
3. **Floor-trade Plane-2 staleness** — ROOT CAUSE FOUND + fixed 2026-07-08 (see the bugs.md entry):
   `OnItemDropped` only fired from `TryDropItem`, which mouse drops never reach, so the drop-time
   blob announce never happened. Fixed with two one-line call-outs (`diablo.cpp` mouse drop,
   `inv.cpp` CloseStash) + pickup completions. Retest after recompile.

Also logged (non-blocking, separate entry): killed-by-tamed-monster deaths drop items via the
killed-by-MONSTER path instead of killed-by-PLAYER. The kill-all ally exemption (below) still needs
its recompile + retest.

## Item-pipe consolidation (2026-07-08) — needs the same recompile, retest with bugs.md #3

Fallout of the floor-trade audit (user: "explicit, not redundant, no guards for confusion"): the mod's
item replication was found to hand-roll engine machinery that was never broken, on a wrong premise
(see the CORRECTION on the resolved "scroll vanishes" bugs.md entry). Consolidated:

- **`items.spawnAt` now announces `CMD_SPAWNITEM` itself** (`Source/lua/modules/items.cpp`, the
  vanilla `SpawnRewardItem` pattern) — same-level peers spawn a live copy, every client (sender
  included, via loopback `OnSpawnItem`) registers it in the level delta, engine dedup included.
- **Deleted:** the `DI` pipe message + receiver + `broadcastDropScroll`;
  `items.registerDeltaDroppedItem`; `LuaDeltaRegisterDroppedItem` + `LuaDeltaRegisterDroppedItemAt`
  (`msg.cpp`/`msg.h`) — net engine-surface shrinkage of two functions.
- **Deleted:** the SD monotonic guard + `blobKills` + freshest-wins pickup. No nameable trigger
  existed (single announcer per seed, live-built blobs, in-order same-sender delivery). Pickup blob
  sourcing is now explicit first-non-empty precedence: item's own blob → level delta →
  `receivedBlobs` → own tables. (Principle going forward: reconcile against loss you can name — the
  RS heartbeat; never guard against confusion.)
- **One drop primitive, `placeScrollOnFloor(x, y, seed, name, dwBuff, modData)`:** spawnAt (item
  replicates itself) + level-delta blob write + SD announce. Used by `dropTameScroll`, the
  corrupt-scroll refund, and `refundTameScroll`'s floor fallback — the last previously dropped with
  NO replication at all (rare-path hole, never reported).

**Retest (two-client MP, with the bugs.md #3 markers):** tame with peer same-level → scroll appears
on both clients, either can pick up; tame with peer OFF-level → peer walks there later, scroll
present with full data; drop-and-quit → rejoiner sees it; deploy-refund paths (cap/dup refusal with
full inventory) drop a scroll the peer also sees.

**Follow-on audits (separate tasks, not started):** the same premise/native-overlap/guard/consumer
method is now queued for every custom MP/Lua subsystem — see **bugs.md §"Review backlog"** (A1–A8;
includes the `receivedBlobs` + join-time SD flood pass as A4).

## Requirements (user, 2026-07-06)

1. **Taming Diablo must not end the game** — quest completion still happens like other bosses, but no
   player freeze, no camera pan, no level-wide monster kill, no ending cinematic.
2. **A tamed Diablo's death is a normal ally death** — death animation plays, resurrect beam on the
   last frame, he disappears (no corpse).
3. **His `DiabloApocalypse` must hit targets dynamically** like the other pets (friendly/hostile
   faction rules).
4. **A tamed Diablo's death must not trigger quest clear or the game ending.**

## What was built

**Engine — one new thin hook, `OnMonsterCanEndGame(monster) -> bool|nil`** (default true = vanilla),
fired at the only two `MT_DIABLO`-gated sites in `Source/monster.cpp`:
- *Death start* (`MonsterDeath`): gates the `DiabloDeath` call (quest done + freeze + kill-all +
  camera-pan setup). Vetoed → the generic `PlayEffect` death-sound branch runs instead.
- *Death tick* (`MonsterDeath(Monster&)`): gates the camera-pan / `PrepDoEnding` branch. Vetoed → the
  death animation finishes through the generic last-frame path (corpse hook → tile clear → reap),
  which vanilla Diablo never reaches. That path already carries the ally death machinery, so the
  resurrect beam + corpse suppression (`OnMonsterDeath` → `pendingResurrectBeam`/`corpselessDeaths` →
  `OnMonsterCanPlaceCorpse`) work for Diablo with **zero new death code**. → covers reqs 2 + 4.

**Mod handler:** `OnMonsterCanEndGame` returns `false` for `monster.isGolem` (mirrors
`OnMonsterCanCompleteQuest`). Barometer-safe: the hook only ever fires for MT_DIABLO and a vanilla
Golem can never be MT_DIABLO, so `isGolem` there = "someone's tamed Diablo" (own or remote-observed).
A **wild** Diablo is never a golem → nil → **full vanilla ending, mod loaded or not**.

**Quest completion on tame (req 1):** the existing capture-path `target:checkQuestKill()` now covers
Diablo — the binding (`Source/lua/modules/monsters.cpp`) mirrors the quest/progress side effects of
`DiabloDeath` for MT_DIABLO (`Q_DIABLO → QUEST_DONE` + `NetSendCmdQuest` + local `pDiabloKillLevel`
raise) without the game-ending sequence. No capture-handler change was needed beyond deleting the
hard-block.

**Apocalypse (req 3) — no engine gate, and MULTI-target (user, 2026-07-06):** a tamed Diablo never
fires the vanilla `DiabloApocalypse` **carrier** (whose `AddDiabloApocalypse` ignores the firing
monster's target and booms EVERY active player — the friendly-fire landmine from the targeting
audit). The `OnGolemChooseAction` ranged handler overrides `naturalRangedMissileId()` for
`AIID.Diablo` to fire the single-tile **`DiabloApocalypseBoom`** at his actual target via the
existing `startSpecialRangedAttack` path (Diablo was already in `AVOIDANCE_RANGED` +
`SPECIAL_RANGED_AI`, so kiting + the special-cast animation just work). The boom resolves through
`CheckMissileCol` like every other pet missile → the standard faction layer applies
(`OnMonsterMissileHit` vs monsters, `OnGolemMissileCanHitPlayer` vs players: owner never hit, FF
toggle respected). Wild Diablo keeps the carrier byte-for-byte. The boom's `MonsterOwned` graphic
loads with the MT_DIABLO type, so it renders on any level a Diablo ally is deployed.

Because vanilla Apocalypse is inherently multi-target (the carrier booms every player on the level),
the tamed version keeps that shape **faction-aware**: when the primary boom spawns (the
`OnGolemMissileDamage` chokepoint fires inside `AddMissile` at the attack frame),
`spreadDiabloApocalypse` fans an extra boom onto every OTHER valid hostile in the pet's ranged
envelope (`APOC_SPREAD_RADIUS` = `RANGED_MAX_DIST` = 8, per-target LOS mirroring the carrier's
`LineClearMissile`): awake/living/non-golem monsters (pets and vanilla Golems are never boomed) and
hostile players only (never the owner; peaceful skipped at placement; the damage layer re-checks).
Extra booms fire via the new generic `monster:fireMissileAt(missileId, x, y)` binding (no
mode/animation change); the primary target — recorded in the ally scratch at choose time — is
skipped, and the spread's own booms re-enter `OnGolemMissileDamage` behind the `apocSpreadActive`
guard. Deterministic on every client: ally AI runs everywhere, fixed slot-order scan over synced
state, damage rolls the synced per-monster RNG stream. (`Missiles` is a `std::list`, so firing
missiles from inside the primary's `AddMissile` hook is reference-safe.)

**Damage (closes the roadmap's open physical-scaling question):** `startSpecialRangedAttack` rolls
damage from the monster's live `min/max` — which is where the standard physical ally buff lives — and
`DiabloApocalypseBoom` is **Physical**, so `OnGolemMissileDamage` passes it through unchanged. Net:
a tamed Diablo's Apocalypse **scales with the physical melee buff** (option (b) of the old open
question), no special-case damage code.

**Scroll plumbing:** Diablo is the one quest monster that is **not unique**, so his scroll travels the
normal typeId seed path. New `DIABLO_TYPE_ID = 110` (`MT_DIABLO`) + `seedIsDiablo(seed)` key every
special case: `categoryFromScroll` → `CAT_DIABLO` (tier gate now flows through `mlvlGateAllows`, so
below CLVL 45 the scroll is red / speedbook-hidden / cast-refused like any out-of-tier scroll);
**gold tier** everywhere a scroll's quality is stamped (`scrollIsGoldTier`, recall, recreate, Pepin
stock); **one Diablo deployed per Hunter** via `isDiabloDeployed()` (mirrors the unique dedup at both
the upfront `OnCanCastScroll` check and the hotkey-cast fallback). Display name rides the normal
"Tamed/Bonded Lvl N <engine name>" path. New Lua constant `monsters.MissileID.DiabloApocalypseBoom`.

## Decisions / known limits (don't relitigate)

- **MP kill credit goes to EVERYONE (user, 2026-07-06 — "don't limit Diablo's credit"):** a Diablo
  capture credits every client like the vanilla ending would. The `CR` capture-removal message now
  carries the captured `typeId`; on a Diablo CR every receiver calls the new
  `player:creditDiabloKill()` binding (idempotent max) — quest STATE still arrives engine-side via
  `NetSendCmdQuest`. The taming client credits itself in `checkQuestKill`. `capturedNaturalMonsters`
  stores `typeId` so the RQ→CR replay carries it too (a replay can also credit a late joiner —
  accepted: generous beats lost credit, and the max() makes it harmless).
- **Gamemode locking:** a Diablo-gamemode Diablo scroll must be restricted in Hellfire — that is the
  already-decided enforcement layer (roadmap §Diablo/Hellfire), NOT built here; the data foundation
  (modData bit 22) already stamps Diablo scrolls correctly.
- **Hellfire lvl 24 (`UberDiabloMonsterIndex`):** checked — that machinery keys off MT_NAKRUL, not
  MT_DIABLO; a deployed Diablo ally doesn't touch it.

## Follow-up BUILT 2026-07-07 (after the clean assert retest): ally exemption from the kill-all

**Deployed allies are exempt from `DiabloDeath`'s level-wide kill.** The sweep kills by setting the
death animation directly, bypassing `MonsterDeath`/`OnMonsterDeath` (untracked deaths + a roster of
dead slots through the ending pan), so this is state hygiene as well as cosmetics. Built as specced:
new thin query hook **`OnDiabloDeathCanKillMonster(monster) -> bool|nil`** (default true = vanilla)
in the kill-all loop's skip condition (`monster.cpp` `DiabloDeath`); Lua handler exempts monsters in
`deployedAllies`/`remoteAllies` (same protected set on every client = deterministic; a vanilla Golem
is in neither → still dies — barometer intact). Hook row in `lua_api_reference.md`. **Needs the next
recompile** (rides along with the `InitializeSpawnedMonster` assert scope + the block-redirect hook).
Playtest: kill wild Diablo with allies deployed → pets stand through the pan/ending, everything else
dies; scrolls still recover as before.

## Playtest checklist (user, after compile)

- Tame Diablo (CLVL 45+, ≤5% HP): scroll drops (gold), quest flips DONE, **no** freeze / camera pan /
  level-wide kill / ending; other monsters on lvl 16 stay alive; game continues (TP/stairs work).
- Barometer: kill a wild Diablo with the mod loaded → full vanilla ending sequence.
- Deploy elsewhere: spawns, follows, melees adjacent; Apocalypse boom at range on hostile monsters
  (damage scales with the phys buff); never booms the owner; FF on/off vs friendly players; kite
  behaviour (avoidance) intact.
- Multi-target Apocalypse: with several awake hostiles in range, ONE cast booms all of them (one boom
  each, no double-boom on the primary target); sleeping packs out of combat stay asleep; own/friendly
  pets and a vanilla Golem in the blast area are untouched; in MP both clients show the same booms and
  the same damage.
- MP kill credit: after a Hunter tames Diablo, EVERY connected player's difficulty unlock advances
  (check char select / new-game difficulty on the peers too), Hunter and non-Hunter alike.
- Tamed Diablo death: death anim → resurrect beam on last frame → vanishes, no corpse, **no** quest
  re-trigger / ending; "revived at Pepin" recovery works; redeploy after buy-back.
- Dedup: second Diablo scroll refuses to deploy while one is out ("I can't do that"); recall + redeploy
  works; below CLVL 45 the scroll is red + speedbook-hidden + cast-refused.
- MP spot-checks: peer observes tame (wild Diablo despawns), deployed Diablo syncs, peer-side death
  shows beam and does NOT end the peer's game; quest state arrives on peers.
