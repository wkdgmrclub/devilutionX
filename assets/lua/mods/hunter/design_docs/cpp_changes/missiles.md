# Engine changes — Missiles (`Source/missiles.cpp`)

The missile hooks' plain signatures are in `../lua_api_reference.md`; this captures the engine-side
*finesse* — which layer each gate sits at and why, and one crash hazard mod-spawning exposes.

---

## Targeting-layer veto, not damage-layer — `OnMissileCanTargetMonster` 
Pure **targeting** gate (no damage effect): return `false` so an auto-targeting missile does not fire a
bolt at this monster. `source` = `Point` origin tile, so a handler can also reject a target standing
behind a protected monster. **Two call sites, both folded into the existing target-pick `if` via `&&`:**
the Chain Lightning spread `Crawl` in `ProcessChainLightning`, and the `FindClosest` lambda (Chain
Lightning / Lightning bolt bounce, Bone Spirit homing). Default true = vanilla.

**Why this layer:** the project rule is *gate auto-targeting where the engine selects the victim*, so no
bolt is ever fired at a friendly — suppressing damage after the fact is the wrong layer. Vanilla's own
exclusions stay in place; our hook is AND-ed *after* them (never replaces a vanilla minion/golem
exclusion, or the spell would start hitting the vanilla Golem).

> **Landmine for Taming Diablo (`../roadmap.md`):** Diablo's `DiabloApocalypse` (`AddDiabloApocalypse`)
> targets **players only** — it never scans `dMonster`/`FindClosest`, so this targeting veto does **not**
> apply to it. A tamed Diablo would friendly-fire *players*; that needs a different owner/faction gate at
> the `AddDiabloApocalypse` player loop.

---

## Minion-spawn missile gate — `OnGolemMinionMissileSpawn`
Query, fires only for a golem-sourced spawn missile (e.g. HorkSpawn) when it lands, **before** the
engine's default `SpawnMonster` in `ProcessHorkSpawn`. Return `false` to suppress that spawn so a handler
can create the monster itself. *Why it must be vetoable:* the engine spawn uses a **level-local type
index**, wrong for a relocated summoner / a species not natural to the level. The mod returns false on
every client and the **level owner** spawns the correct species (single slot allocator), attributes it to
the ally's owner, and replicates it over the pipe. Default true = vanilla.

---

## Missile-resolution bracket consolidated to one call — `OnMonsterMissileHit`
Fires in `CheckMissileCol` for a missile resolving against a monster, gated to hits where a `MFLAG_GOLEM`
monster is on **either** end (source or target); wild-vs-wild never fires it. `source` may be **null**
(trap hitting a golem-flagged target). Return `<0` to **decline** (engine runs its default
`MonsterTrapHit`, byte-for-byte vanilla), or **fully resolve the hit yourself** — reclassify the element,
transiently adjust the target's resistance, call `target:resolveMissileHit(...)`, return `1`/`0`.

**Engine nuance:** this **replaced** the old `OnGolemMissilePreResolve`/`OnGolemMissilePostResolve`
*bracket* (net −1 hook). Because resolution is one synchronous call, any transient resistance change is
set and restored inline — no paired post-event, and the engine stays vanilla on the decline path. Two
supporting bindings (not hooks): `monster:resolveMissileHit(...)` (thin wrapper over `MonsterTrapHit`) and
`monster:tagForPlayer(playerId)` (sets the player's bit in `whoHit` so a minion's missile kill credits
its owner's XP, exactly like the engine's melee minion tag in `MonsterAttackMonster`).

## Damage chokepoint — `OnGolemMissileDamage`
Fires in `AddMissile` after `addFn`, gated to `MFLAG_GOLEM` sources (wild monsters never fire it). One
override point for resistance-scaled spell damage; fires once per missile incl. each spawned segment of
multi-tick spells (Inferno/Lightning). Melee never routes here.

## Player-kill classification for a pet's killing blow — `OnGolemKillIsPlayerKill`
Query, fires only for a `MFLAG_GOLEM` source, at the `PlayerMHit` dispatch in `CheckMissileCol` (the
melee sibling site is `MonsterAttackPlayer` in `Source/monster.cpp` — same hook, see `monsters.md`).
Vanilla hardcoded `DeathReason::MonsterOrTrap` inline at the `PlayerMHit` call. The change resolves it in a
**single `const DeathReason` ternary** — `(MFLAG_GOLEM && OnGolemKillIsPlayerKill(...)) ? Player : MonsterOrTrap`
— the exact idiom vanilla itself uses for the sibling branch two lines down
(`sourceType() == Player ? Player : MonsterOrTrap`). The `MFLAG_GOLEM` gate mirrors the adjacent
`OnGolemMissileCanHitPlayer` (same predicate, same `&monster`/`player` args already in scope). `PlayerMHit`
already takes a `DeathReason` parameter, so no signature change — only the argument's value can now be the
mod's. With no mod / a `false` return it evaluates to `MonsterOrTrap`, so a wild monster and a vanilla
Golem are byte-for-byte vanilla.

**Why the classification and not a killer id:** the drop split in `StartPlayerKill` is purely
`deathReason == Player ? drop ear : drop items`, and the ear is built from the **victim's own** `_pName`
— there is no killer field to plumb. So the entire fix is the one enum value. MP-safe: the resolve runs
where `&player == MyPlayer` (the victim's client), which broadcasts the reason via `CMD_PLRDEAD`; peers
apply the same reason without regenerating drops (vanilla remote-death path).

---

## Lazy monster-missile GFX — crash hazard for mod spawns (no engine change; document)
Some missile sprites are flagged `MonsterOwned` in `missile_sprites.tsv` (`Acid`/`AcidSplat`/`AcidPuddle`,
`MagmaBall`, `ThinLightning`, the `BloodStar*` variants, etc.). `InitMissileGFX()` deliberately **skips**
these at level load; they load only when a monster that fires them is registered, via per-type branches in
`InitMonsterGFX`. If such a missile is ever drawn without its sprites loaded, `scrollrt.cpp` dereferences
an empty `std::optional` (`*missile._miAnimData`) → assert in debug / crash in release; the engine has no
guard. **Safe today** because the mod's `EnsureMonsterType` calls `AddMonsterType` + `InitMonsterGFX`
before placing any ally, so deploying a tamed Acid Beast / Magma demon loads its missile GFX first.
**Watch for it** only if a future ability fires one of these missiles *without* registering the monster
type (e.g. a player-cast acid effect, or spawning a missile by ID from Lua with no matching monster).
