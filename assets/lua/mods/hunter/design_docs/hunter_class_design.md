# Hunter Class Design

Design specification for the Hunter class — identity, mechanics, archetype system.

---

## Class Identity

- **Graphics / portrait / inv**: Warrior
- **Stats**: Rogue (base stat distribution)
- **Voice lines**: Sorcerer
- **Custom TRN** plrgfx/hunter.trn (blue shirt, red pants)

---

## Skills

- **Tame** — starting skill, no mana cost
- **Share Potion** — granted via `player:addSkill(spellId)` in `OnLevelEnter` (because `InitPlayer` resets `_pAblSpells` on every level load)

## Starting Loadout

- `item0=IDI_ROGUE`, `item1/2=IDI_HEAL`, 100 gold
- Starting Tame Scroll (Lvl 2 Scavenger) added via `OnCreatePlrItems`

---

## Tame Tiers

A capture/deploy requires **both** the active tier's **mlvl gate** (monster level vs character level) **and** the monster category's **HP threshold**. The tier (derived from character level `clvl`) controls *which categories are reachable* and the *mlvl math*; the HP cutoff is decoupled and fixed per category. Implemented in `init.lua` as the single source of truth: `tameTier` / `categoryFromTarget` / `categoryFromScroll` / `categoryHpThreshold` / `mlvlGateAllows` / `scrollPassesTierGate`.

**Tier unlocks + mlvl gate** (`clvl` = character level, `mlvl` = monster's difficulty-adjusted level):

| Tier | Unlocks at clvl | Normal | Champion unique | Unique Boss | Diablo |
|---|---|---|---|---|---|
| Tame | Always | `mlvl ≤ clvl` | `clvl ≥ mlvl×2` | `clvl ≥ mlvl×2` | never |
| Tame+ | 20 | `mlvl ≤ clvl` | `mlvl ≤ clvl` | `clvl ≥ mlvl×2` | never |
| Tame++ | 35 | `mlvl ≤ clvl+10` | `mlvl ≤ clvl+10` | `mlvl ≤ clvl+10` | never |
| Tame+++ | 45 | any mlvl | any mlvl | any mlvl | any mlvl |

**Capture HP threshold** — keyed by category, applies at **every** tier:

| Category | HP threshold |
|---|---|
| Normal | ≤ 30% |
| Champion unique | ≤ 20% |
| Unique Boss | ≤ 10% |
| Diablo | ≤ 5% |

Speedbook name reflects the unlocked tier: **Tame / Tame+ / Tame++ / Tame+++** (`OnGetSpeedbookSpellName`).

**Cast-time refusal:** out-of-criteria targets/scrolls are **actively refused** with the spoken "I can't do that", not silently no-op'd. Skill path via the generic `OnCanCastSkill` C++ hook (reads the cursor-targeted monster); scroll path via three Lua actions — red/unusable in inventory (`OnCanPlayerUseItem`), hidden from the speedbook (filtered in `OnGetCustomSpeedbookScrollEntries`), and pre-cast refusal (`OnCanCastScroll`). The HP threshold remains the in-cast capture condition for a valid-category target (you may keep casting Tame at it until it drops low enough).

Monster categories as implemented in Lua (note: C++ binding sets `isQuestMonster = isUnique() || MT_DIABLO`, so flag-based champion/boss distinction is impossible):
- Normal: `!isUnique`
- Champion unique: `isUnique` and `target.name` not in `BOSS_NAMES` table
- Quest boss: `isUnique` and `target.name` in `BOSS_NAMES` table (13 named bosses — see init.lua)
- Diablo: `isQuestMonster && !isUnique` (only non-unique quest monster)

> **Diablo status:** Diablo is gate-eligible at **Tame+++**, but capture and deploy are still **hard-blocked** in code (`CAT_DIABLO` early-return) pending the Diablo sub-task (Apocalypse friendly-fire-on-players landmine). The tier model already classifies Diablo correctly; only the explicit hard-block needs removing when that work lands.

---

## Scroll Paradigm

Taming destroys the monster → drops a Tame Scroll on the floor. Casting the scroll deploys the monster at the cursor tile.

- Up to 8 tamed monsters deployed simultaneously (Phase 10 cap enforcement); unlimited scrolls held
- Scrolls persist across levels and game restarts
- **Difficulty is frozen at capture time** — deploying in a different difficulty uses the original captured stats

## Tame Scroll Encoding

- `_iSeed` upper 16 bits = counter; lower 16 bits: normal monsters = `typeId` (always < `0x8000`), unique monsters = `0x8000 | uniqueTypeIdx`
- `dwBuff` bits: `maxHp` (bits 1–15, full 0..32767 resolution) + `level` (bits 16–21, 6 bits) + `capturedDifficulty` (bits 22–23) + `savedHp` as a **percent of maxHp** (bits 24–31, 0..100; current HP = `round(maxHp * pct/100)`). `maxHp` is the **un-buffed base max** (the live HP buff lives in `maxHitPoints`, never persisted), and current HP is clamped to it on recall (`savedHp ≤ maxHp` always) — overheal is **not** persisted. The percent field stays 8 bits wide but only ever holds 0..100. Bit 0 stays 0 (CF_HELLFIRE).
- Both fields survive pfile and delta round-trips
- `TAME_SCROLL_MAP = 90001`
- **Item name** (inventory + speedbook) carries a `"Tamed "` / `"Bonded "` prefix on **all** scrolls (the prefix flips to `"Bonded "` once `isBonded(seed, level)` — see Ally Progression): normal = `"<prefix> Lvl N [Name]"`, unique = `"<prefix> [Name]"`. Built in `buildScrollParams`, the starter-scroll grant (`OnCreatePlrItems`), and re-applied after save/delta round-trips in `OnCustomItemRecreated`; the speedbook dedup recognises both prefixes. Nothing parses the name for level/type (the seed + dwBuff carry that), so naming is display-only.
- **Gold/"unique" tier:** a scroll is gilded (`magical = 2`, gold name + unique info box) when it is seed-unique **or** Bonded — `scrollIsGoldTier(item)`. Applied at recall, level enter, pickup, and recreate; `OnPrepareUniqueInfoBox` renders the custom box for Bonded normal-monster scrolls too (tier line "Bonded").

## Tame Scroll Speedbook

- Item definition keeps `skipSpeedbook = true` (prevents a generic bitmask entry)
- Named per-monster entries injected via `OnGetCustomSpeedbookScrollEntries` — one entry per unique scroll name, deduped by `item.name`
- Hovering shows `"Tamed Lvl N Name"` + `"N Scrolls"` (or `"Tamed [Name]"` for unique monsters — no level prefix since unique stats are difficulty-based)
- `OnGetSpeedbookSelectionType` reverts the engine's starting-skill promotion so TAME_ID scroll entries dispatch as `SpellType::Scroll`, not `SpellType::Skill`
- `SpellListItem` carries `displayName` (overrides info-box label) and `customScrollCount` (overrides count) — see `Source/panels/spell_list.hpp`

---

## Ally System

### Tracking
`deployedAllies` table in `init.lua` is the source of truth. Each entry carries:
- `monster` — live reference
- `seed` — used as key for kill counts, re-encoding on recall
- `idleTarget` — cleared when player moves
- `capturedDifficulty` (0/1/2) — used on recall to re-encode the scroll
- `base` — snapshot of the freshly-spawned stats (`minDamage`/`maxDamage`/`toHit`/`armorClass`/`maxHp`); the baseline the transient buff is layered on, and the un-buffed `base.maxHp` persisted to the scroll on recall (see Ally Progression). Minions have no `base` (static spawn-time buff, block 8).

Populated on scroll cast (before `makeGolem()`). Pruned on `OnMonsterDeath` and `OnLevelExit`.

### Leash and Engage
- **Leash**: snap at 12 tiles (`LEASH_DISTANCE`) — teleport safety net
- **Engage radius**: 9 tiles (`ENGAGE_RADIUS`) from player

### Targeting logic (`OnGolemCanTargetMonster`)
- Adjacent monsters: always allowed (self-defense)
- Non-adjacent: requires LOS
- Within `ENGAGE_RADIUS` + lit: allow
- Beyond `ENGAGE_RADIUS`: ranged-only
- Spell golems: return `nil` (unaffected)

### Kill tracking
`allyKillCounts[seed]` — keyed by scroll seed, persists across redeploys. Shown in ally info box hover unconditionally (no kill threshold). Incremented by `OnGolemKilledMonster`, which fires from **both** ally damage paths — melee (`StartDeathFromMonster`) and missiles (`CheckMissileCol`) — so ranged/special attackers (e.g. a tamed unique champion) accumulate kills just like melee allies.

### Ally Progression — Tamed → Bonded + stat buffs (Phase 10, blocks 1–3 shipped)

A two-part progression on top of kill tracking; full implementation record in `HISTORY.md`, remaining design in `roadmap.md`.

- **Bonded promotion:** a Tamed ally becomes **Bonded** once `allyKillCounts[seed] ≥ mlvl × 100` (`isBonded(seed, mlvl)`, derived live — no new encoded field; `BONDED_KILLS_PER_LEVEL = 100`). On the threshold-crossing kill `promoteToBonded` fires. Every "Tamed" surface flips to "Bonded" and the scroll renders at gold/unique tier.
- **Bonded defensive bonus:** one random **immunity** the ally lacks (Fire/Magic/Lightning), or **+200 AC** if it already has all three. Rolled once, stored per-seed in `bondedImmunity[seed]` (`BONDED_AC` sentinel = the AC case) and persisted in the kills save blob. Re-applied on every redeploy; immunity written via `setResistance`, AC folded through the buff machinery. Deployed allies always show their resistance/immunity icons on the healthbar via `OnMonsterCanShowResistances` (overrides the vanilla unique-or-15-kills gate).
- **Kill-scaled ToHit bonus (shipped, block 4):** every Tamed/Bonded ally gains **+1% ToHit per 10 kills** (`floor(kills/10)`, `KILL_TOHIT_PER = 10`), **clamped to `CLVL × 10`**, then **doubled if Bonded** (doubling applied *after* the clamp), then **hard-capped at +500%** (`KILL_TOHIT_CAP`, applies even to Bonded). Additive on top of the share-pool ToHit; not share-divided. E.g. CLVL 1 + 150-kill ally → 15% clamped to 10% → +10% (Tamed) / +20% (Bonded). **Refreshes live** on each 10-kill increment: `OnGolemKilledMonster` re-applies that ally's buff whenever its kill count crosses a multiple of `KILL_TOHIT_PER` (so the bonus updates without waiting for a deploy/recalc).
- **Stat-buff machinery (shipped, block 4):** `entry.base` snapshot + `computeAllyBuff`/`applyAllyBuff`/`recalcAllyBuffs` apply a transient CLVL-scaled, share-divided buff layered over base. dmg/ToHit/AC are rewritten from base each recalc (idempotent). **HP buff raises the live `maxHitPoints`** (idempotently `base.maxHp + share`, never accumulated) and **leaves current HP untouched** — the buff adds headroom the pet can heal into (e.g. via Share Potion), so a full base monster deploys at `base.maxHp / buffed-max` (e.g. 100/120). Current is only ever clamped *down* if a shrinking share drops max below it. The buff is transient — `base.maxHp` is the un-buffed value persisted to the scroll on recall (current is clamped to it), so nothing buff-related ever bakes into saved data.

---

## Elixir Restriction

All stat-raising elixirs (ElixirStr/Mag/Dex/Vit + Spectral Elixir) show red and are blocked via `OnCanPlayerUseItem`. Stat budget comes from level-ups + shrines only.

## Per-Stat Cap + Total Budget

- Each stat capped at 250 in `attributes.tsv`
- `OnGetMaxAttributeValue` freezes all four stats when `STR+MAG+DEX+VIT >= 460` — all display golden simultaneously
- Shrine grinding to 460 is intentional game design

---

## Unconditional Mechanics (no archetype gate)

- Potion partial heal: 2× (same as Warrior/Barbarian) via `OnGetPotionHealAmount`
- Potion partial mana: 2× (same as Sorcerer in Hellfire) via `OnGetPotionManaAmount`
- Oily Shrine: +2 to highest non-maxed base stat (capped at 250 per stat) via `OnOilyShrine`

## Share Potion

- Potion of Healing → restore `min(current + 30% maxHp, maxHp)` to targeted ally
- Potion of Full Healing → restore ally to 100% HP

---

## Adaptive Archetype System

Hunter's class mechanics adapt based on current stat distribution. No selection — archetypes unlock automatically.

| Archetype | STR | MAG | DEX | VIT | MAG gate | Unlocks |
|---|---|---|---|---|---|---|
| Barbarian | ≥150 | — | — | ≥200 | `mag ≤ 15` | `strMod/75 + level*vit/100` dmg, iron skin AC, natural resistances, armor pierce, cleave (axe/2H), hit-recovery stagger resistance (`level+level/4` threshold), block bonus 30; Wirt excludes Bow/Staff |
| Warrior | ≥200 | — | ≥150 | — | — | `strMod/100` dmg, critical strike, block bonus 30; Wirt excludes Bow/Staff |
| Rogue | ≥100 | — | ≥250 | — | — | `strDexMod/200` dmg, full bow dmg mod, arrow velocity, block bonus 20; Wirt excludes Sword/Staff/Axe/Mace/Shield |
| Monk | ≥100 | ≥50 | ≥200 | — | — | `strDexMod/150` dmg (staff/unarmed), block unarmed/staff, armor AC bonus, cleave (staff), unarmed damage floor (`min≥level/2, max≥level`), block bonus 25; Wirt excludes Bow/MediumArmor/Shield/Mace |
| Sorcerer-lite | — | ≥150 | — | — | — | Optimal cast frames, 25% mana cost reduction; no Wirt filter |

All archetype Lua handlers implemented in `init.lua`. 30 C++ hooks total.

---

## Stat-Scaled Animation Frames

Negative skip = slower than Warrior baseline. VIT has no frame axis (contributes to Barbarian archetype unlock only).

| Axis | Stat | Starting | Tier 1 | Tier 2 | Tier 3 | Tier 4 (archetype gate) |
|---|---|---|---|---|---|---|
| Melee (Attack) | STR | −4 (Sorcerer-slow) | 75 → −3 | 125 → −2 | 175 → −1 | 200 STR (Warrior) or 150 STR+200 VIT (Barb) → 0 |
| Ranged (Bow) | DEX | 0 (Warrior baseline) | 75 → +1 | 125 → +2 | 175 → +3 | 250 DEX (Rogue) → +4 |
| Cast | MAG | 0 (Warrior baseline) | 40 → +2 | 80 → +4 | 120 → +6 | 150 (Sorc-lite) → +8 |

---

## Custom Items

### Potion of Forgetting
- `FORGET_POTION_MAP = 90002` / `FORGET_POTION_ID`
- Injected into Pepin's stock via `items.addToHealerStock()` on every `StoreOpened("pepin")` (idempotent)
- Uses `miscId = FullRejuv` — engine restores full HP+mana as a bonus side effect
- `spell = FORGET_POTION_ID` stored for detection in `OnItemUsed`
- On use: `player:classBaseStats()` + `player:resetStats()` atomically resets all four base stats, refunds to `_pStatPts`, recomputes max HP/mana
- Info box shows "Refunds all Stats" via `OnGetMiscItemDescription`
