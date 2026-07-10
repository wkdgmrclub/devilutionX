# Development Notes — Active Task

> **The ONE live doc.** Exactly one task in flight at a time. When it ships, graduate it (hook rows →
> `lua_api_reference.md`, bindings → `lua_api_reference.md`, engine code+why → `cpp_changes/`, dated
> entry → `HISTORY.md`, subsystem reasoning → `net_sync.md`) and **delete it from here.** See
> `README.md`.

---

## Single-writer pet combat + heartbeat retirement (BUILT 2026-07-09, awaiting playtest — init.lua only, NO recompile)

**Playtest observation (user, 2026-07-09, two clients on one machine):** a Tamed Advocate killed a
Tamed Scavenger and the Scavenger owner's client showed **no missiles at all** — the pet died to
invisible damage. Separately, ~1s cross-client delays are visible on localhost, where transit is
sub-tick — meaning some state rides the heartbeat as its *primary transport*, not as a healer.

**Root cause (verified in code):** the ranged-fire decision in the `OnGolemChooseAction` ranged
handler runs independently on every client from per-client inputs (target latch, positions, LOS,
kite-vs-owner-distance). MP is not lockstep (the Apocalypse-spread fix already conceded this —
"deterministic on every client was never enforceable"), so the owner's copy fires while a peer's
copy doesn't: no missile spawns there, but the damage still lands via the owner's authoritative
resolution (`OnMonsterMissileHit` → `ApplyMonsterDamage` → engine `CMD_MONSTDAMAGE`). The heartbeat
can never fix this class: the divergence is a *decision* that already happened, not drifted state.

**Architecture (the fix's organizing principle):** vanilla has two sync models — **monsters**
(deterministic sim + engine `CMD_SYNCDATA` convergence) and **players** (the owning client decides
every discrete action and broadcasts it as an immediate command; nothing ever waits for a timer).
Pets currently straddle both, and every observed desync lives in the straddle. This task moves pet
**combat decisions and damage** fully onto the player model (single writer = the pet's owner,
immediate event messages) while movement stays on the monster model the engine already converges
(`sync_all_monsters` iterates ALL active monsters — extended slots included, verified — so ally
position already rides the engine's own per-tick rotating sync).

### Work items

1. **`AT` fire-action replication (the invisible-missile fix).** New pipe message
   `AT|id|missileId|x|y` broadcast by the owner from the missile-SPAWN chokepoint
   (`OnGolemMissileDamage` fires in `AddMissile` at the attack frame — an interrupted windup sends
   nothing; the choose-time target stash is consumed on the first spawn so a multi-part missile like
   Inferno replicates as ONE fire the peer's engine re-expands). Same shape as the existing `AB`
   Apocalypse-boom replication — this generalizes it; spread booms keep riding `AB`
   (`apocSpreadActive` guard). Receivers: same-level, `remoteAllies` lookup, live golem-flagged copy
   → `fireMissileAt` the same missile at the owner's target tile (mode-safe mid-walk; no pose forced
   — a mode change on a walking copy could corrupt tile occupancy). Damage authority is unchanged
   (attacker-owner via `OnMonsterMissileHit`; victim's client for players — which is exactly why the
   missile must exist on every client). Covers the generic ranged handler AND the Hork Spawn fire.
2. **Suppress independent remote fire.** In the ranged `OnGolemChooseAction` handler, a REMOTE-owned
   ally (`remoteAllies` hit, not in `deployedAlliesById`) keeps all movement/kiting/stance logic
   (shared positioning stays converged) but never self-fires — where the owner's copy would fire, the
   remote copy holds (return true, no action) and renders fire only on `AT` receipt. Same for the
   Diablo primary boom (spread was already owner-only via `AB`).
3. **Single-writer melee.** Same authority election as `OnMonsterMissileHit` (attacker-owner if the
   attacker is a Hunter pet, else victim-owner if the victim is tracked; vanilla Golems fall through
   to the engine default — barometer intact): non-authority clients return 0 from
   `OnGolemMeleeHitChance` (the d100 still draws, so the synced RNG stream is undisturbed; a 0 chance
   never hits → no local apply, no broadcast); the authority rolls the real chance and its
   `ApplyMonsterDamage` already replicates via `CMD_MONSTDAMAGE`/`CMD_MONSTDEATH`.
   **Balance-visible correction (flag for playtest):** today EVERY simulating client resolves a
   pet-involved melee hit locally AND broadcasts it, and the `CMD_MONSTDAMAGE` receiver *subtracts*
   (`msg.cpp OnMonstDamage`) — so pet/golem melee damage effectively multiplies by the number of
   same-level clients (2 clients = ~2× damage; inherited vanilla-Golem behaviour). Single-writer
   corrects pet melee to true 1×; MP pets will hit noticeably softer than in prior playtests. The
   vanilla Golem keeps its vanilla multi-writer behaviour (hook default).
4. **Event-driven CO completeness (kill the beat-transported changes).** Every owner-side mutation of
   peer-visible state fires its CO at the moment of mutation, vanilla-command style: the Share Potion
   heal (was `setHitPoints` with NO broadcast — the confirmed ~1s HP-bar lag), CO on EVERY ally kill
   (infobox kill count stays live; replaces milestone-only resync), and the Scavenger corpse-eat heal
   (HP write now owner-only + CO — it was gated on per-client corpse/position state peers legitimately
   diverge on; the walk/eat anim stays shared). Share Potion targeting verified own-allies-only
   (`OnCursorMonsterTarget` matches `deployedAllies`), so no second writer exists. Gargoyle
   `startHeal` left engine-deterministic (its trigger reads HP, which single-writer damage keeps
   converged; the per-frame heal is engine code identical on every client — vanilla class).
5. **Retire the Lua heartbeat.** Remove the RS roster beat, the CO beat re-assert, the EN beat
   re-assert, and the receiver-side roster-mismatch RQ. Keep: change-triggered EN (the engine's
   `SyncMonster` skips its enemy application when positions already agree, so EN remains necessary),
   RQ-on-level-entry (the vanilla "delta at join" analog), the orphan reap, and all delta hygiene.
   After items 1–4 the beat has nothing left to carry: position = engine sync; existence = SP/RM on a
   reliable in-order pipe + RQ at entry + orphan reap + the DeltaLoad gate; stats/HP = single-writer
   damage + change-triggered CO; targets = change-triggered EN. Accepted residual (documented, not
   engineered around): a message dropped by a receiver-side level-scoping race while both clients
   stay on-level has no healer — same class as vanilla's own accepted desync edges.

**On verify:** rewrite `net_sync.md` §4 (RS/beat rows out, `AT` row in, single-writer melee under the
damage-authority notes), update the accepted-risk memory (the CO-transit flip window is eliminated,
not healed), dated entry → `HISTORY.md`. No C++ changes — every hook and binding needed already
exists; recompile not required, `init.lua` copy only.

**Playtest watch items:**
1. Advocate-vs-pet fight: missiles visible on BOTH clients, same tiles, no invisible deaths.
2. Pet HP bars agree in real time on localhost (Share Potion heal included) — no ~1s snaps anywhere.
3. Pet melee damage in MP reads ~half of prior sessions (the 1× correction, item 3) — expected.
4. Nothing regresses on level entry/exit, recall, owner quit (the paths RS used to paper over).

---

## Pet to-hit overhaul: attacker-aware missiles + pet-vs-pet toHit-vs-AC (BUILT 2026-07-09, awaiting playtest)

**Problem:** ally missiles resolve through the engine's `MonsterTrapHit` (`hper = 90 − targetAC − dist`,
clamp 5..95), which never consults the attacker — a ~260-toHit caster pet (Advocate) hits a high-AC
target (Hell Blood Knight, ~245 AC) at the 5% floor, ~1 fireball in 15. The kill-bonus `golemToHit`
only ever fed melee. And pet-vs-pet combat (melee AND missiles) ignored the defender's AC entirely
(vanilla monster-vs-monster melee is `d100 < attacker.toHit`, nothing else).

**Reference point:** monster-vs-PLAYER melee and ARROWS already do full toHit-vs-AC in vanilla
(`MonsterAttackPlayer`, `PlayerMHit` arrow branch: `toHit + 2×ΔLvl + 30 − AC [− 2×dist]`). But the
`PlayerMHit` SPELL branch is `40 + 2×ΔLvl − 2×dist` — toHit and armor never consulted — so a
249-toHit caster pet vs a lvl-45 player sat at the ~10% min-hit floor (found in playtest 2026-07-09).
The fixes copy the arrow-branch formula shape into BOTH gaps: monster-vs-monster (melee + missiles)
and pet-spell-vs-player.

**Missiles (pure init.lua):** in the `OnMonsterMissileHit` handler, when the attacker is a tracked
ally (`srcTracked` — vanilla Golem stays vanilla; attacker-side only), transiently set the victim's
AC around `resolveMissileHit` (same set/restore pattern as the resistance transient) so the engine's
own roll computes:
- vs a **pet** target (`tgtTracked`): `toHit + 2×(srcLvl−tgtLvl) + 30 − targetAC − 2×dist` (duel
  formula — Bonded +AC genuinely protects);
- vs a **wild** target: `toHit − dist` (melee parity; AC ignored, mirroring vanilla monster melee).
`source.toHit` reads `golemToHit`, so the kill bonus now applies to missiles.

**Melee (new thin hook):** `OnGolemMeleeHitChance(attacker, target, hitChance) -> int` — fired in
`MonsterAttackMonster` when either side is `MFLAG_GOLEM`, default = passed-in value (byte-for-byte
vanilla). Handler (as rebuilt by the single-writer task above): elects one resolving authority per
pet-involved swing; on the authority, a BOTH-sides-Hunter-pet duel returns
`passedHitChance + 2×ΔLvl + 30 − targetAC` clamped 5..95 (built on the passed value so
special/magma/storm to-hit variants survive; `hitChance ≥ 500` forced-hit charge respected).

**Pet spells vs players (new thin hook):** `OnGolemMissileHitChance(golem, player, missileId, dist,
hitChance) -> int` — fired in `PlayerMHit` (MFLAG_GOLEM sources, after the vanilla hper + min-hit
floor), default = passed-in value. Handler: arrow-class missiles (`Arrow`/`FireArrow`/
`LightningArrow`) return nil — the engine already rolled toHit-vs-AC; spell missiles return
`toHit + 2×mlvl + 30 − 2×dist − player.armorClass` clamped 5..95 (sheet AC = `GetArmor() + 2×plvl`,
so this is the arrow formula rearranged). Engine block roll + resistances still follow. Resolves on
the victim's own client (HP authority) — no lockstep constraint; `golemToHit` reaches it via CO.

**Recompile:** `monster.cpp`, `missiles.cpp`, `lua_event.cpp` (+hpp). Refresh assets: `events.lua`;
copy `init.lua`.

**Melee determinism audit (done 2026-07-09 — gap CLOSED, residual documented):**
The melee hook fires in the lockstep sim on every client, so its inputs were audited end-to-end:
- *Proven identical on all clients:* `level` (immutable spawn state), the d100 (synced per-monster
  AI seed), `isGolem`/owner class (replayed conversion).
- *Converging via CO:* `golemToHit` (kill bonus) and `armorClass` (Bonded +AC / buffs) — the owner
  applies locally AND broadcasts CO at every mutation (kill milestone, promotion, recalc); peers
  apply CO **to the engine monster** (absolute values incl. current HP); a wholly-lost CO already
  healed via the RS `profile == nil` reconciliation.
- *The CO-transit flip window:* a swing resolving inside a stat-change CO's transit could flip
  per-client and drift the victim's HP. **Superseded by the single-writer melee in the active task
  above:** exactly one client resolves any pet-involved swing, so a per-client flip can no longer
  write HP anywhere (pet OR wild victim) — the drift class is eliminated at the source, and the
  handler's duel formula now runs only on the elected authority (no lockstep constraint remains).

**Playtest watch items:**
1. Caster pet vs Hell Blood Knight ~85–90% (was ~5%).
2. Pet-vs-pet duels: both melee and missiles should now visibly miss high-AC pets (~45% for
   260-toHit vs 245-AC) and Bonded +AC should matter.
2b. Pet spells vs hostile players: 249-toHit lvl-30 Advocate vs lvl-45 / 137-sheet-AC player ≈ the
   95% cap at close range (was ~10% floor). NOTE on the engine's follow-up defenses (untouched by
   the hook): blocking a missile requires `resper <= 0 || gbIsHellfire` (PlayerMHit) — so in Diablo
   a victim with ANY resistance to the element can NEVER block it (damage is resist-reduced
   instead); a zero-resist victim with shield up blocks per the boosted block roll. Don't misread
   either resist-shrunk hits or zero-resist blocks as the old miss floor.
3. ~~Heartbeat CO snap~~ — superseded by the active task above (the beat is being retired; pet HP
   divergence is eliminated at the source via single-writer damage, not healed after the fact).

*On verify: hook row → `lua_api_reference.md`; dated entry → `HISTORY.md`.*

---

## Guardian vs hostile pets: `OnGuardianCanTargetGolem` (BUILT 2026-07-09, awaiting playtest)

The last faction-blind turret (user go-ahead 2026-07-09): `GuardianTryFireAt` skipped ALL player-minions
via `isPlayerMinion()`, so a **hostile** caster's Guardian ignored pets too (observed in PvP testing).
Built as the exact `OnApocalypseCanTargetGolem` mirror:

- **Engine (thin hook):** the vanilla skip in `GuardianTryFireAt` (`Source/missiles.cpp`) becomes
  `isPlayerMinion() && !lua::OnGuardianCanTargetGolem(missile.sourcePlayer(), &monster, false)` —
  vanilla exclusion kept, hook ANDed after it, default false = byte-for-byte vanilla (can only widen).
  Declaration/dispatch in `lua_event.hpp/.cpp`; event registered in `events.lua`. Hook row already
  added to `lua_api_reference.md` (thin hooks take no `cpp_changes/` entry, per the Apoc precedent).
- **Lua policy (init.lua, the Apoc rule verbatim):** tamed allies only (vanilla Golem = barometer,
  vanilla exclusion); own pets and peaceful owners' pets keep the vanilla protection unconditionally
  (a Guardian never fires at players, so peace-time pets stay untouchable independent of Friendly
  Fire); only a **hostile** caster's Guardian fires at another player's tamed ally. Damage resolves
  through the standard `CheckMissileCol` → `OnPlayerMissileCanHitGolem` layer (hostile hits pass in
  both FF modes). Deterministic: the turret scans on every simulating client from synced state
  (roster, friendlyMode).
- **Scope boundary:** Berserk / Doppelganger / Stone Curse stay categorically blocked on tamed
  monsters regardless of faction (the roadmap §Multiplayer Verification safety matrix) — no
  faction-aware widening there. With this, the Deferred Targeting backlog section is empty and was
  deleted from `roadmap.md` (the pet spell-damage-immunity idea was superseded by the Friendly Fire
  toggle rule: with FF off the damage layer already passes friendly players' missiles through pets;
  with FF on, pets being hittable IS the toggle working — building always-on immunity would violate
  "do not build anything beyond this toggle-mirroring rule").

**Recompile:** `missiles.cpp` + `lua_event.cpp/.hpp` — rides the same recompile the pet to-hit
overhaul above already requires. Refresh assets: `events.lua`; copy `init.lua`.

**Playtest watch items:**
1. Hostile Hunter casts Guardian near your pets → the turret now fires at them; damage lands.
2. Peaceful/own: Guardian still never fires at your own or a peaceful Hunter's pets (either FF mode).
3. Vanilla Golem: a hostile player's Guardian still ignores it (barometer).

*On verify: dated entry → `HISTORY.md` (hook row already in `lua_api_reference.md`).*

---

*Previous state: `bugs.md` review-backlog audits (A1–A8) ALL COMPLETE (2026-07-09); next roadmap
feature: Town-following cosmetic ally (roadmap §4).*
