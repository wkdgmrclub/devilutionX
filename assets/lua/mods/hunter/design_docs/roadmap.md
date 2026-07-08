# Phase 10 Roadmap — Pending Work

Only open / pending work is listed here, in the user's priority order. Completed Phase 10 items are
documented in `HISTORY.md`; active bugs and shipped fixes in `bugs.md`.

> **Ally Progression**, **Net Sync (Branch B)**, the **Tamed-pet Infobox / Floating Infobox + OHID**, the
> **Pepin Recovery** system, and the **dynamic-spell registry** are all complete and playtested — details in
> `HISTORY.md`.

---

## ▶ Current State (updated 2026-07-06)

- **Engine cleanup (Branch A): COMPLETE & compliant.** (`HISTORY.md` → "Phase 10 — Engine cleanup".)
- **Net sync (Branch B): COMPLETE & two-client playtested** — graduated to `HISTORY.md` ("Phase 10 — Net
  Sync"). N1–N6 + DM1–6 all built/verified. Authoritative design refs stay in `net_sync.md` +
  `net_sync.md` (mechanism + data model); per-session detail in memory `project_net_sync_progress`.
- **Tamed-pet Infobox + Floating Infobox + OHID: COMPLETE & playtested** — graduated to `HISTORY.md`.
- **Everything in the priority list through item 2 is shipped and playtested. ▶ Current work = item 3, Taming
  Diablo (§3) — BUILT 2026-07-06, awaiting compile + playtest (`development_notes.md`).**

---

## ▶ Priority order (user)

**Minion friendly-fire — resolved (no bespoke system):** governed by DevilutionX's built-in **Friendly
Fire toggle**, extended to pets in **both directions** (the engine applies the toggle only to
player-vs-player missiles; `PlayerMHit`/`MonsterMHit` have no faction/toggle checks of their own — see
`lua_api_reference.md`): pet missiles vs players via `OnGolemMissileCanHitPlayer` (never the owner; FF off
+ friendly-mode owner → no player hit), player missiles vs pets via `OnPlayerMissileCanHitGolem` (FF off +
owner/peaceful caster → pass through), and the `friendlyAllyNearPath` targeting veto (own pets + a peaceful
Hunter's pets) active only while FF is on (with FF off the damage layer makes the firing line safe, so
auto-aim spells keep full reach). Player
Apocalypse: vanilla's own `isPlayerMinion` skip in `ProcessApocalypse` protects pets during peace (no mod
gate, FF-independent — Apoc can't hit players even when hostile, so peace-time pets are equally
untouchable); a **hostile** caster's Apoc may boom another player's tamed ally via
`OnApocalypseCanTargetGolem` (default false = vanilla; vanilla Golems keep the vanilla exclusion). Do not
build anything beyond this toggle-mirroring rule. (Diablo's `DiabloApocalypse` carrier does not route
through these dispatches — `AddDiabloApocalypse` targets players directly; a **tamed** Diablo therefore
never fires the carrier and uses the single-tile `DiabloApocalypseBoom` at his target instead, which
resolves through the standard `CheckMissileCol` faction layer — see §3 / `development_notes.md`.)

1. ✅ **DONE + verified** — Pepin Recovery unique-scroll quality (`HISTORY.md`).
2. ✅ **DONE + playtested** — Infobox / Floating Infobox + OHID for tamed pets (`HISTORY.md`).
3. ◀ **CURRENT — Taming Diablo** — §3. **BUILT**, in verification (`development_notes.md`).
4. **Town-following cosmetic ally** — §4.
5. **Tame Tome** (more complex) — §5.
6. **Monster Nickname** (more complex) — §6.

Lower-priority / not in the 1–6 line (kept for when picked up): PvP tamed-monster-attacks-hostile-player +
faction-aware hostile-pet targeting + pet spell-damage immunity (§Deferred Targeting); the Diablo/Hellfire
scroll-compatibility *enforcement* layer (data foundation already shipped — §Diablo/Hellfire). Residual MP
spot-checks in §Multiplayer Verification.

---

## 3. Taming Diablo (CURRENT — BUILT 2026-07-06, awaiting compile + playtest)

Diablo is tameable at **Tame+++** (CLVL 45, ≤5% HP). Full build write-up, decisions, and the playtest
checklist live in **`development_notes.md`** (the live doc); the durable state is in
`hunter_class_design.md` ("Diablo status"), the `OnMonsterCanEndGame` hook row + binding updates in
`lua_api_reference.md`, and the `checkQuestKill` Diablo-coverage rationale in `cpp_changes/monsters.md`.
Highlights: taming completes `Q_DIABLO` without the game-ending sequence and credits **every** player's
`pDiabloKillLevel` (CR message + `player:creditDiabloKill()`); a tamed Diablo dies like any other ally
(resurrect beam, no corpse, no quest clear/ending — `OnMonsterCanEndGame` veto, wild Diablo
byte-for-byte vanilla); his pet attack keeps Apocalypse **multi-target** faction-aware — primary
`DiabloApocalypseBoom` at his target + `spreadDiabloApocalypse` booms every other valid hostile in the
envelope through the standard pet faction layer (the player-seeking `DiabloApocalypse` carrier is never
fired by a pet), Physical damage riding the monster `min/max` → the standard physical ally buff (closes
the old physical-scaling open question). Graduate to `HISTORY.md` once playtested.

---

## 4. Town-following cosmetic ally

While in town, whatever Tame Scroll is selected in the speedbook produces that Tamed/Bonded monster behind the
player in town, leashed to always follow exactly one tile behind.

- Does **not** consume the scroll — purely a cosmetic effect while in town.
- Stretch goal: allow hovering it to see the regular + floating infobox of the Tamed/Bonded monster stats
  (the §2 infobox is now shipped, so this reuses it directly).

---

## 5. Tame Tome — Hunter-only Tame Scroll stash (mod-owned `tome.sv/.hsv`) — *more complex*

Tame Scrolls are **blocked from the normal stash** (`OnItemAllowedInStash` returns false for them, alongside the Potion of Forgetting). The normal stash (`stash.sv`) could be loaded by a non-modded / base-game session, so a Tame Scroll must never live there. **Goal:** a *separate, mod-owned* stash for Tame Scrolls, reached by **leveraging the existing stash code** rather than extending the vanilla stash.

- A Hunter-facing scroll stash that round-trips Tame Scrolls (with their seed/`modData` progression intact) but lives in its own file absent from non-Hunter / non-modded saves — mirroring how the out-of-band `luamoddata` entry keeps Hunter progression off the vanilla save format.
- This feature is **Hunter-only** and can be **completely local** — minimal netcode (just storing/retrieving Tame Scrolls).
- Generate a **book item next to Gillian**; hovered it says **"Tame Tome"**.
- A Hunter interacting with it opens a stash window just like the base-game stash at Gillian (the DevilutionX feature added to Diablo + Hellfire). **Non-Hunter** classes interacting do their "I can't do that" line.
- The Tame Tome stash window is **8×8**, **3 pages**, single-arrow page selectors only, **no gold storage**.
- Clicking it opens the window immediately + plays the **book** sound effect. Clicking the single-arrow page selectors plays the **scroll** sound effect.
- Saved as **`tome.sv/.hsv`**, accessible across any Hunter save in the same config dir as the save (same behaviour as the regular stash).
- Confirm the right reuse of `Source/qol/stash.*` (thin generic hooks, defaults to vanilla, base-game stash untouched). UI layout / exact wiring to be detailed when picked up.

---

## 6. Monster Nickname (rename Tamed/Bonded allies at Deckard Cain) — *more complex*

A **Deckard Cain menu interaction** that lets a player set the **displayed name** of any of their Tamed/Bonded monsters. The nickname replaces the **species portion** of the generated display name while keeping the `Tamed/Bonded Lvl N` prefix — e.g. `Tamed Lvl 2 Scavenger` → `Tamed Lvl 2 Doggo`.

- Applies to **any** of the player's own Tamed/Bonded monsters (held scroll or deployed ally).
- **Nickname must persist when the scroll is traded** — so it rides **with the per-scroll/monster data**, not with the Hunter. Treat it like the existing custom-name/cosmetic data: store on the scroll's seed-keyed record and carry it through the trade path (item-encoding / Plane-2 cosmetic), so a Hunter who receives the traded scroll sees the chosen nickname.
- Open scoping notes (capture when detailing): the Cain UI surface (reuse a towner dialog / text-entry path), how the nickname composes with the existing name generator (prefix + tier + nickname-vs-species), max length / charset / sanitisation, and how it travels over the wire alongside the other Plane-2 cosmetic fields (names/TRN) for the live cross-Hunter view.

---

## Deferred Targeting / Combat QoL (lower priority — not in the 1–6 line)

Split off from the auto-targeting audit (the targeting exemption itself is shipped — see `HISTORY.md` "Auto-targeting Spell Exemption"):

- **Tamed monsters don't attack HOSTILE PLAYERS (observed in PvP testing 2026-06-22) — NOT YET BUILT.** A
  tamed ally fights another player's tamed monsters when the owners are mutually hostile (via `OnGolemCanTargetGolem`),
  but never the hostile *player*. **Root cause (engine):** in `UpdateEnemy` (`Source/monster.cpp:692`) the whole
  player-candidate loop is wrapped in `if (!isPlayerMinion)` — a player-minion is structurally excluded from
  ever considering a player. **Scope (focused sub-project, net-sync-entangled):**
  1. *Engine:* a new thin hook so a player-minion CAN consider a player when a mod permits — unwrap the loop and
     gate each candidate with `if (isPlayerMinion && !lua::OnGolemCanTargetPlayer(&monster, &player, false)) continue;`
     (default false = byte-for-byte vanilla).
  2. *Lua:* return true only when the ally's owner is **hostile** to that player (mirror `arePeaceful`), never the
     owner / a friendly player.
  3. *Damage layer (verify, likely more work):* once a golem *targets* a player, confirm the melee/ranged attack
     lands on a HOSTILE player and is still blocked vs friendly/own players (vanilla golems never hit players, so
     this path is unexercised — faction checks in the monster-attacks-player / `CheckMissileCol` path need auditing).
  4. *Net sync:* deterministic AI must agree on player-targeting on every client → cross-client hostility agreement.
- **Faction-aware hostile-pet targeting.** `ProcessApocalypse` / `GuardianTryFireAt` / `AddBerserk` skip *all* player minions via `isPlayerMinion()` — faction-blind, so these won't target a **hostile** Hunter's pets either (observed with Guardian). A faction-aware hook that overrides the vanilla skip only when the two players are hostile, still protecting friendly/own pets and never the vanilla Golem. Ties into Net Sync.
- **Pet spell-damage immunity (QoL).** The shipped exemption is *targeting* only — a spell that legitimately fires (a pure-AoE, or a bolt fired along a pet-free line a pet later walks into) can still damage a pet. Optional QoL: make own/friendly pets immune to the owner's spell damage. Separate from targeting; decide if wanted. (A Bonded ally's promotion Flash burst is the remaining owner-adjacency friendly-fire case; a tamed Diablo's Apocalypse boom is owner-safe via `OnGolemMissileCanHitPlayer`.) **Note:** minion friendly-fire specifically is now **deferred indefinitely** to the base-game Friendly Fire toggle (see priority list).

---

## Diablo/Hellfire scroll-compatibility / gamemode locking (DECIDED 2026-06-24 — enforcement layer not yet built)

Tame Scrolls record the **gamemode they were tamed in** and are hard-restricted by gamemode when carried
across to the other gamemode. Restriction rules (user, 2026-06-24):

- **Hellfire → Diablo: ALWAYS restricted.** Any Tame Scroll created in the **Hellfire** gamemode is fully
  red/restricted/unusable in **Diablo**. (Hellfire content has no Diablo equivalent, so it never travels back.)
- **Diablo → Hellfire: allowed, with ONE exception.** Most Diablo-gamemode scrolls work fine in Hellfire.
  The exception is a scroll containing **Diablo himself** tamed in the Diablo gamemode — that one is
  red/restricted/unusable in Hellfire.
- **Lockdown is total — not even moveable.** A restricted scroll cannot be deployed, sold, OR even moved
  within the inventory. The player must return to the correct gamemode and file it into the **Tame Tome**
  (§5) properly. No partial/soft state — fully inert until back in its home gamemode.

**Data foundation — BUILT 2026-06-25 (shipped with the "Found:" floating-box field):** the tamed-in
gamemode is captured at fresh tame and stored in **`item.modData` bit 22** (`0` = Diablo, `1` = Hellfire) —
NOT `dwBuff` bit 0, which is the engine's live `CF_HELLFIRE` flag (read by `RecreateItem`→`gbIsHellfire` and
`IsDungeonItemValid`; flipping it corrupts item validation/recreation — confirmed in `Source/items.cpp`).
`modData` is mod-owned + engine-ignored, so bit 22 is safe. It rides every existing path: seed-keyed
`scrollGamemode[seed]` table (persisted in OnSave/OnLoadPlayerData as a trailing section; rebuilt onto held
scrolls by `healHeldScrollModData`), carried on trade + re-keyed on pickup (`OnItemPickedUp`), and synced to
remote observers on the CO message. Capture reads the new **`system.isHellfire()`** engine binding
(read-only getter, sibling of `system.isMultiplayer()`, reads `gbIsHellfire`). So the locking work only needs
the *enforcement* layer:
- Compare the scroll's stored gamemode + "is Diablo unique" against the current gamemode.
- Gate at: deploy (`OnCanCastScroll` / the scroll cast handler), sell (`OnVendorWillBuyItem`), and
  **inventory move** (needs an engine hook to veto picking a restricted item off the inventory grid — no
  such hook exists yet; scope it when this is built). Render the scroll **red** when restricted
  (mirror the existing tier-gate red treatment in `OnGetItemColor`/the scroll-tier veto).
- Default for any scroll predating the bit (none in clean current-state data, per the no-backwards-compat
  rule): modData bit 22 = 0 → reads as Diablo-gamemode, which is the lenient case.

---

## Multiplayer — Residual Verification (playtest spot-checks)

The multi-Hunter visibility, hostility, pet-combat, ownership, Tame-Scroll-restriction, and net-sync systems
are **built and two-client playtested** (graduated to `HISTORY.md` "Phase 10 — Net Sync"). The core
net-sync round-trip is **verified**. The items below are residual spot-checks to re-confirm opportunistically as
play continues:

- **Hunter death drop:** verify which Ear type the Hunter drops when killed by another player; confirm intended.
- **Same-unique deployment is per-Hunter, not global.** Multiple Hunters must EACH be able to deploy their own
  copy of the **same unique** simultaneously (four Hunters → four distinct Skeleton Kings, one per owner), while
  a single Hunter still cannot field two of the same unique. Any dedup check must be scoped to the deploying
  Hunter's own (client-local) `deployedAllies`, never a global "is this unique alive anywhere". SP evidence is
  encouraging (a tamed Butcher coexists with the wild Butcher) but **explicitly re-confirm the multi-Hunter case**.
- **Interaction safety matrix** — confirm all clients respect, on Tamed monsters:

  | Target | Berserk | Doppelganger | Stone Curse | Direct target / etc. |
  |---|---|---|---|---|
  | **Ally** (own or friendly Hunter's pet) | ✗ blocked | ✗ blocked | ✗ blocked | ✗ blocked |
  | **Hostile** (enemy Hunter's pet) | ✗ blocked | ✗ blocked | ✗ blocked | allowed via normal hostile channels |

  Even **hostile** pets stay immune to Berserk / Doppelganger / Stone Curse (categorically disallowed on tamed
  monsters regardless of faction); direct targeting + ordinary combat are allowed on hostile pets.
- **Deployed-monster sync (double-check):** all players consistently synced on dungeon-deployed monsters.

> **Net Sync mechanism + data model:** `net_sync.md` remain the authoritative
> design refs for the *mechanism* and *data model*; the as-built summary now lives in `HISTORY.md`.
