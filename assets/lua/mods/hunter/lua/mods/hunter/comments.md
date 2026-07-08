# init.lua — extended commentary

This file holds the design notes, rationale, and mechanics detail that used to live as
multi-line comment blocks inside `init.lua`. The code keeps only terse one-line comments;
everything else lives here, keyed by the symbol / function / region it documents.

To find an entry: search this file for the symbol name (e.g. `deployedAlliesById`) or the
section heading. Sections are ordered top-to-bottom to mirror `init.lua`.

> Design-doc rationale (the *why* behind whole subsystems) still lives in
> `assets/lua/mods/hunter/design_docs/`. This file is the line-level companion to the code:
> it explains specific symbols, invariants, and handoffs that a reader of `init.lua` needs.

---

## Module setup

### `local luanet` — LuaNet bridge
Talks to the LuaNet net-multiplexer WITHOUT a hard cross-mod require. The LuaNet mpq publishes its API
onto the shared `devilutionx.events` table (the SAME table instance in every mod's sandbox), so we just
read `events.luanet` at call time — no dependency on loading LuaNet's files, and no load-order
requirement. If the LuaNet mpq isn't enabled, `events.luanet` stays nil and these are no-ops (MP net
inert; single-player and the class are unaffected). `luanet` is one of the few top-level locals: the
inter-mod surface (module requires + this net bridge) stays local.

`GameStart` fires after every mod has loaded, so the handler flushes any registration LuaNet wasn't
available for at our load time (covers this mod loading before the LuaNet mpq in the list). Guarded so a
missing event can never abort init.lua.

### Globals-vs-locals convention (file-wide)
Nearly every top-level declaration in init.lua is an intentionally plain (sandbox-global) assignment
rather than `local`. Lua caps a function's main chunk at 200 active locals+upvalues, and this file is
large; globals don't count against that cap, need no usage changes, and live only in this mod's own
sandbox env, so nothing leaks to other mods. `local` is reserved for the inter-mod surface ONLY: the
module requires at the top, the `luanet` bridge, and the net layer (the `NET` tag table and the
broadcast*/credit forward-decls) — i.e. the handles used to talk to the engine modules and the LuaNet
multiplexer. Everything else (constants, state tables, helper functions) is a sandbox global.

### `MAX_HUNTERS` / `MAX_DEPLOYED_PER_HUNTER` — slot reservation
Reserve extra per-level monster-TYPE slots so a full party of Hunters can deploy distinct tamed types
without overrunning the engine's level type table (base cap `MaxLvlMTypes = 24`). Worst case: 4 Hunters
× 8 deployed allies = 32 potentially-distinct types. Load-time only. The extra live-monster slots stop
deployed allies competing with natural spawns for the base 200-slot array; the engine clamps the
effective cap to 252 (uint8 enemy-encoding ceiling), which comfortably fits ~190 natural spawns + 32
allies.

## State tables

### `forgetPotionSnapshot`
The Potion of Forgetting is session-only: it is transiently popped from the local inventory across each
hero-file write (`OnBeforeSaveHero`) and put back in its exact slot afterwards (`OnAfterSaveHero`), so it
is never serialised and never survives into a freshly loaded game (exit, quit, crash, or force-close).
Holds the `{ref=liveSlot, saved=poppedCopy}` records for one write.

### `tameScrollData`
Session cache only; rebuilt from seed+dwBuff encoding on post-restart cast.
`tameScrollData[seed] = { typeId, savedHp, maxHp, name, level }`.

### `deployedAlliesById`
Parallel `monsterId -> entry` index over `deployedAllies` for O(1) membership tests. The hot per-tick /
per-frame hooks all test ally membership: `OnGolemCanTargetMonster` fires once per active monster per ally
per tick (golem target scan), `OnGetMonsterOutlineColor` once per drawn monster per frame, plus the
`OnGolemChooseAction` / `OnGolemIdle` chain every tick. A linear scan made each test cost O(allies), so
total per-tick work grew with the SQUARE of the deployed count — the documented "performance degrades with
more deployed Tamed monsters" issue. Always mutate `deployedAllies` through `trackDeployedAlly` /
`untrackDeployedAt` to keep this in sync.

### `remoteAllies`
Plane-1, runtime-only (never saved): registry of allies owned by ANOTHER client, recreated locally from a
net SP message. These are NOT our own allies (those live in `deployedAllies`). Their AI runs
deterministically on EVERY client (same as a vanilla golem) — we no longer suppress it — so this table is
the peer-side mirror of an own-ally tracking entry, holding the per-ally scratch the shared AI hooks need
to behave identically here as on the owner:
`remoteAllies[monsterId] = { ownerId, parentId (minions only), capturedDifficulty, uniqueIdx, profile (combat CO) }`.
Keyed by per-level monster slot id, so cleared on every level change / game start.

### `pendingDeploys`
Plane-2, runtime-only: `seed -> ally data` for a deploy we requested from the level owner because we are
NOT the level owner (monster spawning is level-owner-authoritative; see the DR/SP net flow). The owner
spawns the ally and echoes it back as SP, where we complete the deferred local Plane-2 setup; if the owner
can't place it, it echoes DF and we refund. Cleared on every level change / game start.

### `pendingAllyRoster`
Saved deployed-ally roster awaiting re-link, populated by `OnLoadPlayerData` (Section 5 of the mod-data
save) and consumed on the next level entry. Lets a single-player "Load Game" from inside a dungeon restore
allies as tracked deployed monsters (re-bound to their reloaded golems by stable monster slot id) instead
of orphaned golems. nil when there is nothing to re-link.

### `lastBuffFingerprint`
Last-seen fingerprint of the Hunter's buff-relevant stats (CLVL + the four character-sheet stats the buff
pool scales off). Polled in `GameDrawComplete` to re-derive ally buffs on a live CLVL-up or gear swap
mid-deployment; recalc fires only when this string changes.

### `corpselessDeaths`
`monsterId -> true` for a deployed ally that has just died and must NOT leave a corpse on the floor.
Recorded in `OnMonsterDeath` (which fires at the start of the death, while the ally is still in
`deployedAllies`) and consumed in `OnMonsterCanPlaceCorpse` (which fires later, on the final death frame,
AFTER we have already untracked the ally — so membership can no longer be tested there). Our tamed monsters
vanish on death; the loss is conveyed by the disappearance (and, later, the Farnham recovery flow) rather
than a corpse, which also keeps them off the limited corpse table. A vanilla Golem is never in
`deployedAllies`, so it is never recorded here and keeps its corpse.

## Ally membership / ownership helpers

### `isTamedAlly`
True for ANY tamed ally/minion the local client knows about: one of our own deployed allies, OR a
remote-owned ally we recreated from the net. The per-tick AI hooks gate on this (not `isDeployedAlly`) so
they run identically on the owner and on peers — the precondition for deterministic, in-lockstep AI across
clients. A vanilla Golem is in neither table, so it is never treated as a tamed ally.

### `allyOwner`
The Player that owns this ally, resolved from the live monster's `ownerPlayerId`. Works uniformly for our
own allies (`ownerPlayerId == local id` → returns the local player) and remote allies (returns the remote
owner), so an AI hook can anchor to the owner the same way on every client. nil if no such player. Replaces
`player.self()`/`cachedOwner` in the AI hooks (those were owner-only).

### `allyScratch`
The per-ally record the shared AI hooks read identity/combat state from (`capturedDifficulty`, cached combat
profile). For an own ally it is the `deployedAllies` entry; for a remote ally it is the `remoteAllies`
record. Only ever read for fields both shapes carry. IMPORTANT: do NOT cache a per-tick AI *decision* here —
the two records are populated at different ticks (own at deploy, remote when the SP arrives on a late
joiner), so a value cached at "first use" would differ across clients and desync. Decisions that must agree
across clients are derived from the synced tick instead (see `syncedHash` / `system.gameTick`, used by
`OnGolemIdle`).

### `arePeaceful`
Shared by the outline color logic and the pet-vs-pet targeting logic so the visual relationship (blue vs
red) and the combat relationship can never disagree.

### `isFriendlyTamedView`
True for our OWN deployed ally/minion (always), or a NON-HOSTILE other player's tamed pet (any observer
class — the info is not Hunter-gated). A hostile player's pet falls through to vanilla. Drives both the
regular info box (Type + resistances) and the floating stat box.

## Seeds, IDs, and provenance

### `scrollCounter`
Per-character monotonic counter for Tame Scroll seeds. A seed is encoded as: bits 12-31 = counter
(1..1048575), bits 0-11 = type field (bit 11 = `UNIQUE_SEED_FLAG`, bits 0-10 = typeId or uniqueTypeIdx,
0..2047). The counter is persisted per character (`OnSave`/`OnLoadPlayerData`) and NEVER reset, so a
character can never re-issue a seed it has already used — eliminating cross-session seed collisions for a
single character. (Cross-PLAYER collision-proofing — re-stamping a picked-up scroll into the new owner's
counter space — lands with the scroll self-description step, which lets the re-stamp carry the ally's data
off the item instead of losing it.)

### `myOhId` / OHID (Original-Hunter ID)
A permanent per-character "trainer ID": one 9-digit number generated once when a Hunter is created and
persisted in that Hunter's save (`OnSave`/`OnLoadPlayerData`, trailing field after `scrollCounter`). Paired
with the Hunter's character NAME it labels every monster that Hunter owns in the pet info readout. The OH
*name* is never stored — it is always the owning Hunter's player name (read locally, or via
`player.get(ownerId)` for a peer), so only this one integer needs to persist / sync.

### `hashString`
Deterministic, overflow-safe string hash (polynomial mod 1e9; the running value stays under 31e9, well
within the 2^53 exact-integer range of a Lua number, so no precision loss).

### `generateOhId`
Generates a fresh 9-digit OHID from the character name + creation timestamp (`os.time`, whitelisted in the
sandbox). Two same-named characters created at different seconds still differ; same-second is a
cosmetic-only collision with no mechanical effect.

### `scrollOrigin`
`seed -> { name = <original Hunter's character name>, id = <their OHID> }`. Captured at Tame time and kept
PERMANENTLY with the monster, Pokémon-style. It rides INSIDE the scroll's mod-data blob (see `blobForSeed`),
so it travels with the item — on the level delta for a dropped floor item and live over the LuaNet "SD"
message — and is also persisted out-of-band in the luamoddata save. A scroll with no recorded origin falls
back to the local Hunter (see `originForSeed`).

### `receivedBlobs`
Blobs heard over the LuaNet "SD" message keyed by seed: a peer announces a scroll's full mod-data blob so
that if we later receive that scroll via a live trade (the floor item carries no blob over the wire), the
pickup can restore its identity from here. (A scroll dropped by a player who then LEFT is instead restored
from the level delta — see `items.setItemDeltaModData` / `item.modData`.)

### `broadcastScrollData` (forward decl)
Announces a scroll's full identity blob to peers keyed by seed (no-op in SP), assigned in the net section
once the message type + `luanet.send` are in scope; used by the floor-drop helpers which run before that
section is reached. Only the BLOB needs this mod transport — the floor ITEM replicates itself over the
engine wire (`items.spawnAt` announces `CMD_SPAWNITEM`; a hand drop sends `CMD_PUTITEM`).

### `packStringToWords` / `unpackStringFromWords`
The luamoddata save blob is a uint32 sequence, so a name string is byte-packed: a length word, then
ceil(len/4) data words (4 bytes little-endian each). `unpack` reverses it, returning the string and the next
read index. Used by `OnSave`/`OnLoadPlayerData` for the `scrollOrigin` section.

### `isOtherHuntersAlly`
Detected from engine state alone (golem flag + owner's class), because that Hunter's `deployedAllies` table
is client-local and invisible to us. Minions inherit their owner from the parent ally (`goalVar3`), so they
resolve here exactly like a directly-tamed ally.

### `isProtectedFromOffense`
`monster` is protected when it is the attacker's own deployed ally/minion (always), or another Hunter's pet
while the two players are at peace. Shared by every offensive-action gate (left-click attack, offensive
scroll cast, staff-charge cast) so the one protection rule lives in a single place. nil-safe: `monster` is
nil when no monster is under the cursor (e.g. a charge/scroll aimed at an empty tile) → not protected.

### `BOSS_NAMES`
Named quest bosses require Tame++ (level 45, ≤10% HP) to tame. Regular unique monsters (champions) only
require Tame+ (level 30, ≤20% HP).

### `STARTER_*`
typeId 16 = `MT_NSCAV` (Scavenger); row 18 of monstdat.tsv, 0-based index. HP values from monstdat.tsv
`hitPointsMaximum` column (Normal difficulty).

### `UNIQUE_SEED_FLAG`
Bit 11 of the 12-bit type field marks a unique-monster scroll. All normal typeIds are well below it so this
flag never collides.

### `isUniqueTypeDeployed`
Defined here (after `seedGetUniqueType`) on purpose: a Lua `local function` that references a local declared
later in the file binds it as a nil global instead, which threw inside the deploy loop whenever any ally was
already deployed. (These are sandbox globals, but the ordering lesson stands for the local-typed surface.)

### `encodeDwBuff` / `decodeDwBuff`
dwBuff encoding layout (all fields unsigned, bit 0 = `CF_HELLFIRE` = 0): bits 1-15 maxHp display value
(0..32767, full resolution); bits 16-21 monster level (0..63; never exceeds 30 in practice); bits 22-23
`capturedDifficulty` (0=Normal 1=Nightmare 2=Hell); bits 24-31 savedHp as a percent of maxHp (0..100),
current HP = round(maxHp * pct / 100). Storing maxHp at full resolution keeps a tamed monster's Max HP
STABLE across recall/redeploy: the live monster's `maxHitPoints` is restored verbatim instead of re-rolled
from the type's HP range (a re-roll would drift with each recast and with dlvl). Current HP is never above
max (recall clamps savedHp to maxHp), so pct fits in 7 bits; bits 24-31 are read as a byte for simplicity.
dwBuff is a `uint32_t` engine-side and these bits are safe because `RecreateItem(createInfo=0)` ignores
dwBuff entirely and `IsItemDeltaValid` passes (`IsDungeonItemValid(createInfo=0, dwBuff)` always returns
true). Kill count is stored in `allyKillCounts`; difficulty is frozen at tame time so cross-game deploys keep
original scaling.

## Recovery + progression

### `recoveryRegistry`
A backup ledger of deployed allies so a death, crash, quit, or full inventory never permanently loses a Tame
Scroll. Each entry is fully rebuildable from (seed, dwBuff): the seed encodes type/uniqueness, the dwBuff
encodes HP/level/difficulty (see encode/decodeDwBuff), so the name is re-derived and the scroll re-created on
demand. State is internal-only (never shown): `"lost"` = alive but never recalled (crash, quit, or full
inventory on level change) → free; `"injured"` = died in the dungeon → paid recovery
(level * `RECOVERY_INJURED_COST_PER_LEVEL`). Persisted via `OnSavePlayerData`/`OnLoadPlayerData`; surfaced for
buy-back in Pepin's store. `recoveryRegistry[seed] = { dwBuff = uint32, state = "lost"|"injured", order = n }`.

### `pendingResurrectBeam`
Allies whose final death frame should spawn the Resurrect beam FX. Set in `OnMonsterDeath` (while the ally is
still identifiable) and consumed one frame later in `OnMonsterCanPlaceCorpse`, mirroring the
`corpselessDeaths` handoff. Cleared on level exit so a reused monster id never inherits a stale beam.

### Ally Progression (section)
Tamed allies gain stats scaled off the Hunter's own; enough kills promote one to Bonded (a defensive
immunity + doubled buff share + visual aura). Minions and spellcaster allies are buffed on their own paths.

### `BONDED_IMMUNE_SUPERSEDES`
Each immunity supersedes the same-element resistance. Base-game monsters never carry both a Resist and an
Immune of the same element, so when a Bonded roll grants an immunity for an element the ally already
resisted, we drop that resistance to match vanilla's infobox/healthbar UI pattern.

### `BONDED_AC`
Sentinel stored in `bondedImmunity` for the "already has all three immunities → +200 AC" fallback. Distinct
from any `IMMUNE_*` flag (8/16/32); stored verbatim in the save blob.

### Pre-Bonded flash FX (`BONDED_FLASH_COLOR` / `FLASH_PERIOD_FRAMES` / `FLASH_ON_FRAMES`)
A Tamed ally one kill short of Bonded flashes as a tell. Built as a registered all-one-colour TRN (palette
remap) toggled on/off through the generic `OnGetMonsterTRN` render hook. `BONDED_FLASH_COLOR` is the palette
index every sprite pixel is drawn as while flashing. Any index in the global sprite range 128-255 is
cross-palette consistent (the "cross-palette trap"), so the choice is purely thematic: 0xB0 (the lightest
slate blue) matches the Hunter's blue theme (grayscale crypt/cathedral palettes desaturate it to light gray,
as expected). Cadence (two independent knobs, frame-driven — `GameDrawComplete` runs once per RENDERED
frame, not per logic tick, so both are FPS-relative; no Lua tick source exists): `FLASH_PERIOD_FRAMES` = how
OFTEN a blink starts (one rising edge per period → the frequency); `FLASH_ON_FRAMES` = how long it HOLDS the
solid-blue peak each blink (the dwell at the top). The two are orthogonal: raising the dwell holds the peak
longer without changing the frequency. 80/20 = a blink every ~1.3s @60fps, holding blue for 1/4 of each
cycle. Tune to taste.

### `BONDED_LIGHT_RADIUS` / `applyBondedGlow`
Bonded "aura" glow: a permanent light source on a Bonded ally (the same engine mechanic 'lighted' unique
monsters use — `AddLight`, auto-followed by `MonsterWalk`/`SyncLightPosition`, auto-freed on death/recall).
Light is monochrome brightness (no colour in vanilla), so it reads as a glowing presence; the blue sprite
tint (`OnGetMonsterTRN`) is what distinguishes it from a unique's aura. Kept small (the unique default is 3)
since up to 8 Bonded allies could be lit at once; tune here.

### Bonded recolour TRNs (`GLOBAL_RAMPS` / `brightnessRank` / `buildScatterTrn` / `BONDED_TRN_TABLE`)
A Bonded ally's permanent tint READS its rolled bonus at a glance: each immunity (and the +200 AC fallback)
has its own high-contrast recolour, plus a rare Hell-only "Gilded Metal" variant. SCATTER model: each
variant is a short repeating PATTERN of palette entries, indexed by a source pixel's brightness RANK
(rank % #pattern). Slots holding a colour repaint the pixel a FIXED BRIGHT colour; a `false` slot keeps the
monster's own pixel. Diablo sprites are already checkerboard-DITHERED between adjacent shades (the art fakes
gradients that way), so cycling two bright colours + identity across consecutive ranks turns that built-in
dither into a vivid, spotty [colourA]/[colourB]/[original] pattern — bright and high-contrast WITHOUT
clobbering the monster's identity (a tan Zombie still reads tan, speckled with its immunity colours). Earlier
bakes mapped each pixel to its rank-matched gradient entry, so most pixels (low ranks) got the DARK end and
the look came out dull + sparse; fixed bright colours fix that. TUNE: density = ratio of colours to `false`
in the pattern (`{A,B}` = full/solid two-tone, `{A,B,false}` = ~2/3 bright + 1/3 original, `{A,B,false,false}`
= sparser); brightness/hue = the entries themselves (use bright ramp entries).

CROSS-PALETTE CORRECTNESS: only the global sprite range 128-255 is recoloured — per palette.h those entries
have IDENTICAL RGB in every area palette (where monster/player sprites live), so the look is the same in
every dungeon. Indices 0-127 are LEVEL-SPECIFIC, so they are left strictly IDENTITY (we have no cross-palette
brightness for them; sprites barely use them). Every colour entry is ≥ 128. Palette ramp bases (palette.h):
PAL16 BEIGE 160, BLUE 176, YELLOW 192, ORANGE 208, RED 224, GRAY 240 (each +0 darkest .. +15 brightest); so
e.g. bright red ~230, bright yellow ~205, bright blue ~186, white ~254. `BONDED_TRN_TABLE` pattern = bright
colourA, bright colourB, then `false` (keep original) for ~2/3 bright coverage; drop the `false` for solid,
add more for sparser.

### `HELL_GILD_CHANCE` / `bondedTrn`
A Hell-tamed ally (`capturedDifficulty == HELL_DIFFICULTY`) has `HELL_GILD_CHANCE`% to wear the rare Gilded
Metal recolour instead of its bonus colour. `bondedTrn[seed]` = rolled variant, set once & saved.

### `scrollGamemode`
`scrollGamemode[seed] = 0 (Diablo) | 1 (Hellfire)`: the gamemode the scroll was first tamed in. Captured once
at fresh tame, preserved across recall/redeploy, carried on trade (packed in the modData blob) and re-keyed
on pickup. Persisted in `OnSave`/`OnLoadPlayerData`; rebuilt onto held scrolls by `healHeldScrollModData`.

### `scrollAreaLevel`
`scrollAreaLevel[seed]` = the dungeon level the scroll was first tamed in (`items.currentDeltaLevel` at fresh
tame: 1-24 in normal play; a setlevel quest area encodes as level+NUMLEVELS). Mapped to an area name for the
floating box "Found:" field. Same lifecycle as `scrollGamemode`: captured once at fresh tame, carried in the
modData blob, re-keyed on pickup, persisted in `OnSave`/`OnLoadPlayerData`, synced over CO.

### `SPELL_ELEMENT_OF`
Spellcaster allies scale their *cast* damage off the Hunter's matching resistance. Maps a missile's
`DamageType` to the resistance key it scales from. Acid has no player-side resistance of its own, so Acid
casters are aligned to the Hunter's MAGIC resistance (treated as a spellcaster element). Only Physical casts
fall through (nil) and keep the physical melee buff.

### `hunterResist` / `OnCalcPlayerResistances` cache
The local Hunter's UNCAPPED resistances (may exceed the 75% display cap), refreshed from the
`OnCalcPlayerResistances` hook whenever the Hunter's inventory/resistances are recalculated. The hook fires
for every player on recalc; we only keep the local player's (its allies are client-local).

### `bondedImmunity`
`bondedImmunity[seed]` = the granted `IMMUNE_*` flag, or `BONDED_AC` for the +200 AC fallback. Rolled ONCE at
the promotion moment, then stored & persisted so a redeploy restores the same bonus instead of re-rolling.
Same seed-keyed, save-MPQ-persisted pattern as `allyKillCounts`.

### Portable scroll payload (`SCROLL_BLOB_FMT` / `encodeBlob` / `decodeBlob` / `blobForSeed`)
The seed-keyed progression tables (`allyKillCounts` / `bondedImmunity` / `bondedTrn` / `scrollGamemode`) and
the Original Trainer live in the owner's save and so do NOT travel when a scroll is dropped and picked up by
someone else. To make a scroll self-describing — so it survives a trade and a re-stamp losslessly — its WHOLE
identity is packed into the item's optional mod-data blob (`item.modData`, a binary string) on every scroll
creation. Layout (`string.pack`, empty for a non-scroll item):
`I2` kill count (clamped 65535); `B` Bonded immunity index (0 = none; see `IMMUNITY_BY_INDEX`); `B` Bonded TRN
variant (0 = none); `B` tamed-in gamemode (0 = Diablo, 1 = Hellfire); `B` tamed-in area level (dungeon level
at fresh tame; see `scrollAreaLevel`); `I4` Original-Trainer OHID; `s1` Original-Trainer name (length-prefixed,
≤255). (Gamemode is mod-owned here — NOT dwBuff bit 0, which is the engine's live `CF_HELLFIRE` flag.) The
blob is opaque to the engine and travels two ways: live by seed over the LuaNet "SD" message
(`broadcastScrollData`) and at rest with a dropped floor item via the level delta (`items.setItemDeltaModData`),
so a scroll picked up after its original dropper has left the game still carries everything. `blobForSeed`
falls back via `originForSeed` to the local Hunter for a freshly tamed scroll not yet stamped.

### `isBonded`
A Tamed ally becomes Bonded once its kill count reaches `mlvl * BONDED_KILLS_PER_LEVEL` (mlvl = the monster's
own level). Derived live from `allyKillCounts[seed]`; no encoded field needed.

## Stat machinery (ally buffs)

### `isOneKillFromBonded`
True when a deployed ally needs exactly one more kill to cross the Bonded threshold (kills land one at a
time, so this is the single-kill window that drives the pre-Bonded flash). Minions never promote, so they
never flash.

### `scrollIsBonded`
Bonded check for a scroll ITEM (in inventory / on the floor), where the live monster isn't available: mlvl
comes from the dwBuff-encoded level, kills from `allyKillCounts[seed]`.

### `scrollIsGoldTier`
Gold/"unique"-tier scroll = a seed-unique champion/boss scroll OR any Bonded scroll (Bonded scrolls render as
Unique Tame Scrolls).

### Base-vs-applied stat machinery (section)
Each deployed ally's BASE (pre-buff) stats are snapshotted at deploy into `entry.base`. The live buff is
layered on top and recomputed in place whenever the deployed set or the Hunter's stats change, so it can be
re-derived without compounding and never leaks into the scroll on recall. INVARIANT: the buff never bakes
into the persisted scroll — `entry.base` (incl. `base.maxHp`) holds the un-buffed stats and is the single
source of truth saved on recall. The live HP buff DOES raise the monster's live `maxHitPoints` (so its bar
reads e.g. 120/120 and a share potion can top it off), but `maxHitPoints` is recomputed every recalc as
`base.maxHp` + the live share — never accumulated — and dmg/ToHit/AC are likewise rewritten from base, not
incremented. Recall persists `base.maxHp`.

### `snapshotAllyBase`
Snapshot the freshly-spawned monster's stats as the buff baseline. dmg/ToHit/AC are re-rolled by the engine
on each spawn (not scroll-encoded), so the per-deploy live value IS the base. Call AFTER `makeGolem()` so
`golemToHit` (the source of `Monster::toHit` for player minions) is already set.

### `allySharePct`
Shared per-ally share WEIGHT (percent): the CLVL% pool divided evenly across all deployed Tamed/Bonded allies,
then doubled for a Bonded ally. Returns 0 when there's no local Hunter. Used by both the physical buff and the
per-cast spellcaster buff.

### `computeAllyBuff`
Live, share-divided, CLVL-scaled physical buff pool (HP / min+max damage / ToHit / AC), plus an additive
kill-scaled ToHit bonus. Each stat's pool is CLVL% of the Hunter's own matching stat (as shown on the
character sheet — see the `player.minDamage`/`maxDamage`/`toHit`/`armorClass` bindings), split evenly across
all deployed Tamed/Bonded allies, with a Bonded ally's share doubled. All fractions round up. Returns the
deltas `applyAllyBuff` layers onto `entry.base`. EVERY ally (caster or not) gets the physical damage buff here
— it governs MELEE damage. A spellcaster's elemental MISSILE damage is scaled separately, per cast, in
`OnGolemMissileDamage`, so a hybrid like the Balrog keeps a physical melee buff AND a resistance-scaled
Inferno. The kill-scaled ToHit is additive, per-ally, NOT share-divided: +1% per `KILL_TOHIT_PER` kills, raw
clamped to CLVL*10, doubled if Bonded (after the clamp), hard-capped at `KILL_TOHIT_CAP`%.

### `applyAllyBuff`
Re-derives and re-applies the live buff for one ally from its base + current inputs. The Bonded +200 AC
fallback is folded through the buff machinery so a later recalc (which rewrites `armorClass` from base) does
not wipe it. The HP buff RAISES `maxHitPoints` only (idempotently: `base.maxHp` + the live share, never
accumulated). Current HP is left untouched — the buff adds headroom the pet can heal into (e.g. via share
potions); it does not grant current. So a full base monster deploys at `base.maxHp` / buffed-max (e.g.
100/120). `base.maxHp` is the un-buffed snapshot persisted to the scroll. The only time we touch current is to
clamp it down when a shrinking share drops max below current (avoids an overrun); otherwise current is purely
combat/heal driven and round-trips exactly across recall.

### `broadcastAllCombatOverrides` / `broadcastRemove` / `creditAllyKill` (forward decls)
`broadcastAllCombatOverrides` (CO broadcaster) lives in the net section (it needs the net message constants),
but `recalcAllyBuffs` calls it so peers re-sync whenever any ally's stats change; no-op in single-player.
`broadcastRemove` (live-remove broadcaster) also lives in the net section, but the recall / minion-cleanup
helpers above it call it so peers despawn an ally/minion the moment its owner removes it (instead of leaving a
ghost until the next level reload). `creditAllyKill` credits one OWN deployed ally with a kill (Bonded
progression); shared by the melee path (`OnGolemKilledMonster`) and the missile path (`OnMonsterMissileHit`
handler), assigned at the `OnGolemKilledMonster` registration.

### `recalcAllyBuffs`
Recompute the buff for every deployed ally. Call whenever the deployed set changes (deploy, recall, ally
death) or the Hunter's own stats change. Because the share shifts as allies are added/removed, already-deployed
allies must update in place — not only at spawn. After re-applying, the owner broadcasts each ally's new
combat values to same-level peers (no-op in single-player).

### `ownAllyProfile`
The caster/combat profile a missile-resolution hook needs to scale an ally's spell damage and apply its
Bonded immunity-piercing. For OUR OWN ally we build it live (from the Hunter's stats + the ally's Bonded
state); a peer instead caches the OWNER's broadcast copy (the CO net message) on the remote record, because
none of these inputs (Hunter Magic/resistance, the ally's kill-derived Bonded status) are otherwise visible on
a peer. Same fields either way, so the missile hooks read it uniformly and compute identical damage on every
client. nil when there is no local Hunter / not enough data. The `origin` field is the pet's Original Trainer
(the scroll's recorded origin, which may be a DIFFERENT Hunter if this owner received it via trade; minions
have no seed so they fall back to this owner); peers can't derive it, so it rides the CO message for the remote
floating box. The cosmetic Plane-2 fields (`trnVariant`, `nearBonded`) a peer can't derive locally (it has no
seed-keyed kill/Bonded data) so they're carried so a remote ally shows the same TRN tint + pre-Bonded flash on
every client.

### `allyMissileProfile`
The caster/combat profile for ANY tamed ally on this client: built live for our own (`deployedAllies`), or
read from the cached CO broadcast for a remote-owned ally (`remoteAllies`). nil for a non-ally (e.g. a vanilla
Golem) or a remote ally whose CO has not arrived yet. The missile hooks use this so they resolve identically on
the owner and on peers.

### `applyMinionBuff`
Minions (a tamed Skeleton King's skeletons, a Hork Demon's spawn) get a flat CLVL% stat buff baked ONCE at
spawn — the Tame (non-Bonded) tier weight, independent of the live share-divided ally pool. NOT divided by ally
count and never recomputed afterward (minions are transient, summoned/reaped as the parent fights). Damage is
purely physical CLVL% — no spellcaster split, since no minion type casts an elemental missile. Layered on top
of `entry.base` (the difficulty-scaled, post-makeGolem snapshot) using the same write pattern as
`applyAllyBuff`; HP as a current-vs-max overrun so `maxHitPoints` is never touched. Call once, after
`snapshotAllyBase`. The HP buff uses the same model as `applyAllyBuff`: it raises `maxHitPoints` only
(`base.maxHp` + hpBuff), leaving current HP untouched.

## Spellcaster + Bonded combat

### `OnGolemMissileDamage` handler
Scales a deployed spellcaster ally's ELEMENTAL missile damage off the Hunter's Magic and matching resistance.
The C++ hook is gated to `MFLAG_GOLEM` sources, so this only fires for golem / player-minion missiles (never
wild monsters); we still filter to our own deployed allies (the vanilla Golem is `MFLAG_GOLEM` too but isn't
in `deployedAllies`). Fires per missile — including each segment of a multi-tick spell (every Inferno /
Lightning spawn) and re-sampling spells — so the timing is robust where a one-shot min/max bump was not, and it
picks the resistance matching THIS missile's element, so multi-element casters are handled with no per-monster
table. Physical missiles pass through unchanged (Acid scales off the Hunter's Magic resistance); MELEE never
routes here, so a hybrid (e.g. Balrog) keeps its physical melee buff while its spell scales off this
Magic/resistance formula instead.

Formula: `spell = (baseDam + sharePct% × CurrentMagic) × (1 + matchingRes%)` [round up].
- `baseDam`: the rolled `dam` with the physical buff stripped back out (scale the engine's roll by
  base/current rather than re-rolling, so the missile's native multiplier — e.g. Lightning's ×2 — is preserved).
- `sharePct = (CLVL / deployedAllyCount) × (Bonded ? 2 : 1)`: the Magic term is a SHARED POOL — split across
  deployed allies, doubled for Bonded (via `allySharePct`, same weight as the physical buff).
- `matchingRes` (uncapped, clamped to ≥0): a FULL multiplier, NOT share-divided, so matching-element
  resistance stays meaningful even with a big pack. Synergy only ever helps (no negative penalty).

The profile is live for our own ally, or the owner's broadcast copy for a remote ally — so the spell scaling is
identical on every client (this hook fires wherever the missile is created). nil = not our ally / CO not yet
received.

### Acid-as-magic + Bonded immunity piercing (`PIERCE_OF` / `OnMonsterMissileHit` handler)
Two behaviours, both expressed in the `OnMonsterMissileHit` handler (which fires whenever one of our allies is
on either end of a missile) and both set/restored inline within that one synchronous call, so nothing
(healthbar/infobox) ever observes a transient change. The vanilla Golem is never in `deployedAllies`, so it
falls through unchanged (Golem barometer respected).

(A) ACID RESOLVED BY MAGIC RESISTANCE (any ally, attacker OR defender). The engine has NO monster acid-resist
tier (`Monster::isResistant` ignores `RESIST_MAGIC` for an Acid missile) — monster-side acid is all-or-nothing
(full, or 0 if `IMMUNE_ACID`). To mirror the player side (acid resolves through magic resistance), when one of
our allies is the source or the target of an acid missile we return `DamageType.Magic`, so the engine resolves
the hit through the target's magic immunity/resistance instead. IMPORTANT: acid IMMUNITY is RESPECTED here — if
the target is acid-immune we leave the element as Acid (engine blocks it). So a wild monster's acid on an
acid-immune Tamed or Bonded ally is still blocked; a non-immune ally resolves it via magic resistance.

(B) BONDED ATTACK PIERCES IMMUNITY (Bonded SOURCE only). A Bonded ally's missiles treat the target's IMMUNITY
to the cast element as mere "big resistance" (75%) → 25% instead of 0. Coarse on/off: ANY Bonded ally pierces,
regardless of spell/element. Two cases: Fire / Lightning / Magic (engine has a real resist tier) → TEMPORARILY
clear the matching `IMMUNE_*` bit and set the matching `RESIST_*` bit → engine's dam/4 = 25% with "resisted"
feedback; Acid (no resist tier) → TURN OFF the target's `IMMUNE_ACID` and resolve as MAGIC, so the acid missile
does magic damage even to an acid-immune target (this is the bypass that (A) withholds), then it also flows
through the Magic case so a magic-immune target is pierced to 25% too. (B) is the OFFENSIVE counterpart to —
and separate from — the immunity a Bonded ally GAINS on promotion: one is "what my attacks pierce", the other
is "what I'm immune to".

EXCEPTION (PvP): the random immunity a Bonded ally was GRANTED on promotion (`bondedImmunity[seed]`) is NOT
pierceable. When the target is one of our locally-tracked allies and the (effective) cast element matches its
granted Bonded immunity, we skip the downgrade so that immunity holds at full — e.g. a rolled Magic immunity
blocks our acid (resolved as magic). (A cross-Hunter remote target isn't in our `deployedAllies`, so its
granted immunity can't be read on this client yet — a known MP limitation deferred to Net Sync. Piercing of a
target's *natural* immunities works regardless, incl. wild monsters in single-player; the rolled-immunity guard
only matters in PvP.)

`PIERCE_OF` maps `DamageType -> { IMMUNE_* flag we clear, RESIST_* (big-resistance, 75%) flag we set }` for the
elements the engine has a real resist tier for. Acid is NOT keyed here — it has no monster resist tier and is
reclassified to Magic first (then shares the Magic entry). Physical is absent (nothing to pierce). The
`OnMonsterMissileHit` handler resolves the hit itself and returns 1/0 (hit/miss): reclassify the element
(acid-as-magic), transiently pierce a Bonded attacker's target immunity, tag the owner for kill XP, resolve
through the engine (`target:resolveMissileHit`), restore the transient resistance, and credit the kill. The XP
tag fires BEFORE resolution so a fatal shot still counts (the engine distributes death XP inline during the
resolve); mirrors the melee minion tag the engine already does in `MonsterAttackMonster` (owner = `goalVar3`
/ ownerPlayerId). Bonded kill-count credit goes to an OWN ally that landed the fatal blow (remote allies are
owner-tracked + CO-synced; `creditAllyKill` no-ops for them); mirrors the melee path's `OnGolemKilledMonster`.

### Bonded defensive bonus (`rollBondedBonus` / `rollBondedTrn` / `applyBondedBonus` / `promoteToBonded`)
On promotion the ally gains ONE random immunity it does not already have (Fire/Magic/Lightning); if it already
has all three, it gets +200 AC instead. Rolled once, stored by seed, persisted. `rollBondedTrn` picks the
recolour TRN matching the rolled bonus (call after `rollBondedBonus`, which sets `bondedImmunity[seed]`); a
Hell-tamed ally has a small chance to override its bonus colour with the rare Gilded Metal look instead; no-op
once the seed has a stored variant (so redeploys are stable). `applyBondedBonus` writes the immunity straight
to resistance (it survives recalc, which never touches resistance); the +200 AC fallback is realised inside
`applyAllyBuff` (folded into the AC write) so call `applyAllyBuff` after this; if the granted immunity
supersedes a same-element resistance the monster already had, the resistance is dropped so the infobox/healthbar
never show a Resist and Immune of the same element (vanilla never does). `promoteToBonded` is the discrete
promotion moment: roll/store the bonus, apply it, re-derive stats so the +200 AC fallback (if rolled) takes
effect immediately, and fire a celebratory Flash burst at the ally's own tile. The pre-Bonded flash stops on
its own — once the threshold is crossed, `isOneKillFromBonded()` returns false, so `OnGetMonsterTRN` no longer
flashes it.

## Tame tier / category gate

### Tame tier + monster-category model (section)
Single source of truth for the gate. The active TIER is derived from character level (clvl); the monster
CATEGORY from its uniqueness/quest flags. A capture/deploy is allowed only when BOTH the tier's mlvl gate
(`mlvlGateAllows`) AND the category's HP threshold pass. Tier unlocks: Tame (always) / Tame+ (clvl 20) /
Tame++ (clvl 35) / Tame+++ (clvl 45). Tier indices: 0 = Tame, 1 = Tame+, 2 = Tame++, 3 = Tame+++.

### `categoryFromTarget`
Classify a LIVE monster (capture side). The engine binding sets `isQuestMonster = isUnique || MT_DIABLO`, so
Diablo is the one quest monster that is not unique (`isQuestMonster=true, isUnique=false`).

### `mlvlGateAllows`
Returns true if this monster category at this monster level (mlvl) may be tamed by a Hunter of this character
level (clvl):
- Tame    : Normal mlvl≤clvl ; Champion & Boss clvl≥mlvl*2 ; Diablo never
- Tame+   : Normal & Champion mlvl≤clvl ; Boss clvl≥mlvl*2 ; Diablo never
- Tame++  : Normal/Champion/Boss mlvl≤clvl+10 ; Diablo never
- Tame+++ : any category (incl. Diablo) at any mlvl

### `categoryFromScroll`
Classify a TAME SCROLL by its seed (deploy side). Mirrors `categoryFromTarget` but reads the encoded
seed/name instead of a live monster. No Diablo scrolls can exist yet (Diablo capture is hard-blocked), so
every normal scroll classifies as `CAT_NORMAL`; revisit Diablo-scroll detection in the Diablo sub-task.

### `scrollPassesTierGate`
True if a Tame scroll (by seed + dwBuff) is deployable at player p's current tier. Used to red/hide/refuse
out-of-criteria scrolls, mirroring the capture-side mlvl gate.

### `isMyPlayer`
True when p is the local player AND the local player is a Hunter. Used in all query/fire event hooks so they
are inert when the local player is a different class (important in mixed-class multiplayer games where the mod
is installed on all clients).

## Data registration + animation

### Spell / item / class registration
`SpellDataLoaded`: queue our spells. IDs are NOT assigned here — the engine assigns them after every mod has
registered, deterministically (sorted by name from a fixed base just past the static SpellID range). That
makes a given name resolve to the SAME id in Diablo and Hellfire and regardless of mod load order, so saved
skill/scroll bits stay valid across .sv↔.hsv and every same-mod-set client agrees. Names are namespaced
("hunter:") so other spell-adding mods can never collide. `SpellsAssigned` fires right after assignment,
before `ItemDataLoaded` / `PlayerDataLoaded`, so these ids are valid when the Tame Scroll item (`TAME_ID`) and
the starting-loadout skill ("hunter:tame") are resolved.

`OnLevelEnter` re-grants Share Potion on every level entry: `InitPlayer` (player.cpp) unconditionally resets
`_pAblSpells` to only the class's starting skill on each level load, wiping any extra skills; `OnLevelEnter`
fires after `InitPlayer` completes so this re-OR is safe.

`OnCreatePlrItems` grants a starting Tame Scroll when a new Hunter character is created: it fires from inside
`CreatePlrItems` (items.cpp) after the standard loadout is placed but before `CalcPlrItemVals` — the same safe
context used by all other starting item placement. The creating Hunter is the starter pet's Original Trainer;
routing through the shared scroll-creation helper a freshly-tamed monster uses means the starter inherits every
current field (modData, seed-keyed origin, peer announce) and stays identical to any other tamed scroll instead
of drifting behind.

### Stat-scaled animation frame tiers (`getMeleeSkipBonus` / `getRangedSkipBonus` / `getCastSkipBonus`)
Hunter uses Warrior sprites. Negative skip = slower than Warrior baseline.
- Attack (melee, STR-gated): base penalty −4 (Sorcerer-slow for unarmed/axes), tiers climb toward 0. STR <75:
  −4; 75+: −3; 125+: −2; 175+: −1; 200+ or (STR 150+ and VIT 200+): 0 (Warrior optimal).
- RangedAttack (bow, DEX-gated): Warrior bow = 16 frames, Rogue bow = 12 (+4 skip = Rogue speed). DEX <75: 0;
  75+: +1; 125+: +2; 175+: +3; 250+: +4 (Rogue optimal).
- Cast (MAG-gated): Warrior cast = 20 frames, Sorcerer cast = 12 (+8 skip = Sorcerer speed). MAG <40: 0; 40+:
  +2; 80+: +4; 120+: +6; 150+: +8 (Sorcerer-lite optimal).

### `OnGetPlayerIdleFrames`
Bow-equipped dungeon stand sprite only has 8 frames; match the same override the engine applies to native
Warrior/Barbarian but not to dynamically-loaded classes. MUST apply to EVERY Hunter (not just the local one):
this is a rendering property, and every client renders every player. Gating it to `isMyPlayer` left a remote
Hunter's idle frame count at the higher animations.tsv value, overrunning its 8-frame bow idle sprite →
`clx_sprite` crash.

## Class restrictions + archetypes

### `OnGetPlayerArmorGraphic`
Hunter always displays using the Light Armor sprite set regardless of equipped armor. AC bonuses from worn
armor still apply; this is purely cosmetic. Applies to EVERY Hunter (rendering property): a remote Hunter must
resolve to the same armor sprite on every client, or a non-light-armored remote Hunter would load a
wrong/missing sprite set.

### Elixir restriction (`ELIXIR_MISC_IDS` / `OnCanPlayerUseItem`)
Hunter cannot use stat-raising elixirs. Stat budget is accumulated via level-ups + shrine bonuses only. Shows
items red; blocks equip/consume without preventing pickup. Also blocks the Spectral Elixir (raises all stats)
by item index, and Golem scrolls (cast from memory or staff only). A Tame scroll whose encoded monster is
outside the Hunter's current tier criteria is red/unusable (blocks right-click + belt use); the data is
preserved — only deployment is gated; the scroll becomes usable again once the tier/clvl meets the gate.

### Speedbook spell filter (`HUNTER_ALLOWED_LEARNED_SPELLS` / `OnShouldHideSpeedbookSpell` / `OnCanSelectSpellBookEntry`)
Hide learned spells not on the Hunter allowlist. Scrolls and staff charges always show. Golem scrolls are also
hidden (Golem may only be cast from memory or a staff charge, never a scroll). Guardian (13) and Golem (21) are
intentionally excluded from the allowlist: the Hunter's summon identity is Tame, not the vanilla summon spells,
so neither may be learned/direct-cast. Guardian stays usable via scroll/staff charge; Golem scrolls are
red/hidden (`OnCanPlayerUseItem` + speedbook hide) while Golem staff charges remain usable.
`OnCanSelectSpellBookEntry` blocks selecting a restricted learned spell as the active cast spell; display is
unchanged, only clicking to equip the spell is blocked.

### Golden stats (`STAT_BUDGET` / `OnGetMaxAttributeValue`)
When total base stats reach 460, every stat appears "at its cap" simultaneously, blocking further allocation.
Implemented by returning the current stat value as the effective maximum — the engine treats the stat as capped
and displays it in golden text.

### Adaptive Archetype System (`hasBarbArchetype` etc. + the archetype hooks)
Hunter's combat mechanics scale with base stat investment. Each archetype requires its FULL threshold to unlock
— no partial benefits. Thresholds use base stats only (`_pBaseStr/Mag/Dex/Vit`), not equipment bonuses.
Archetype gates: Barbarian STR≥150, VIT≥200, MAG≤15; Warrior STR≥200, DEX≥150; Rogue STR≥100, DEX≥250; Monk
STR≥100, MAG≥50, DEX≥200; Sorc-lite MAG≥150. `OnGetPlayerDamageMod` (`_pDamageMod`) computes the best archetype
formula using total stats (passed pre-computed), returning the highest value among all met archetypes (nil if
none). The remaining archetype hooks grant: critical strike (Warrior), iron skin AC + natural resistances + hit
recovery stagger (Barbarian), full bow damage + arrow velocity (Rogue), block-without-shield + armor
level-scaling AC (Monk). The hit-recovery hook adds level+level/4 that C++ pre-applies only for native
Barbarian (Hunter is a dynamic class).

### Other archetype hooks
`OnGetUnarmedDamageFloor` (Monk): fires when both hand slots are empty (no weapon; `CalcPlrDamage` entered
with minDamage==0). `OnGetBlockChanceBonus`: overrides TSV `blockBonus` by active archetype (nil falls back to
the TSV value of 10). `OnGetManaCost` (Sorc-lite): 25% reduction, same as Rogue/Monk/Bard. `OnPlayerCanCleave`:
Barb grants cleave with axe or 2H mace/sword, Monk with staff. Partial potion heal/mana: Hunter always gets 2×
(heal like Warrior/Barbarian, mana like Hellfire Sorcerer).

### `WIRT_EXCLUSIONS` / `OnShouldExcludeWirtItem`
When Hunter has a full archetype, bias Wirt's item toward usable types. Types are excluded only when ALL active
archetypes agree to exclude them (intersection). No archetype = no filter (any item type allowed).

### `OnOilyShrine`
+2 to the highest base stat that is not at its individual cap (250 per attributes.tsv). All stats at 250 →
nothing to grant.

### `ItemDataLoaded` (Tame Scroll + Potion of Forgetting)
`SpellDataLoaded` fires before `ItemDataLoaded`, so `TAME_ID` / `FORGET_POTION_ID` are valid here. The Potion
of Forgetting uses `IMISC_FULLREJUV` so it behaves exactly like a full rejuv potion — right-click from
inventory and belt hotkey both work, engine restores full HP and mana. The `spell` field stores
`FORGET_POTION_ID` purely for detection in `OnItemUsed` (the engine ignores it for FullRejuv items). Value = 0
here; store price is set explicitly in `addToHealerStock`.

## Scroll helpers

### `countMinionsOfParent` / `removeMinionsOfParent`
Minions are monsters spawned by a tamed ally's special ability (e.g. a tamed Skeleton King's skeletons). They
are tracked in `deployedAllies` with `isMinion = true` and `parentId` = the spawner's monster id. They never
count against the ally cap, are never recalled to a scroll, and are despawned when their parent is recalled or
killed. `countMinionsOfParent` also counts remote-owned minions of this parent: the spawn-cap decision runs on
every client (deterministic AI), so a peer must see the same minion count the owner does — its copies live in
`remoteAllies`, not `deployedAllies`. `removeMinionsOfParent` makes each vanish silently (no death effects,
loot, or XP) and broadcasts the remove so peers despawn their mirrored copy (a minion has no natural-death sync
there).

### `buildScrollParams`
Build scroll name + dwBuff for a monster data record. Pass `existingSeed` when recalling a deployed ally so the
seed is preserved and `allyKillCounts[seed]` persists across recall/redeploy cycles. Unique scrolls:
"Tamed [Name]" (no level prefix; difficulty stored in dwBuff). Normal scrolls: "Tamed Lvl N [Name]" (level +
difficulty in dwBuff). `origin` (optional) stamps a NEW scroll's Original Trainer (`{name, id}`); omit it when
recreating an existing scroll (recall/refund/recovery) so the seed's already-recorded origin is preserved. The
origin is tracked in the seed-keyed `scrollOrigin` table (persisted + net-synced); it is NOT stored on the
item. The tamed-in gamemode + area level are captured ONCE, on the fresh tame (a new seed with nothing recorded
yet); recall/refund (existingSeed) keeps the values already stored. `items.currentDeltaLevel()` dereferences
the local player, which does NOT exist yet during character creation (the starter scroll is built from
`OnCreatePlrItems` before MyPlayer is set), so it's guarded on `player.self()`: a real in-dungeon tame always
has one and reads the live level; the only pre-player tame is the starter pet, which always originates from
Church Lvl 1 (dlvl 1). Unique scroll names carry no "Lvl N" prefix, but the level is still stored in dwBuff so
the unique infobox can display it (otherwise it reads back as 0). `modData` is the self-describing blob — the
seed's progression (kills/immunity/TRN/gamemode) AND its Original Trainer — so the scroll survives a floor-drop
trade and a re-stamp; empty for a non-scroll.

### `dropTameScroll` / `addTameScrollToInventory`
`dropTameScroll` allocates a seed, stores monster data in the session cache, and drops the scroll on the
floor; it encodes typeId/uniqueTypeIdx in the seed and hp+difficulty in dwBuff so data survives a game
restart. It persists the blob with the floor item (level delta) + announces it live, so whoever picks it up
keeps the scroll's full identity — even after we leave the game (the delta is handed to a joiner on connect
and restores onto the floor item; see `items.setItemDeltaModData` / `OnItemPickedUp`); this also covers SP
level-exit. The SD broadcast caches the blob on peers and must precede the DI replicate.
`addTameScrollToInventory` is the inventory sibling: it shares `buildScrollParams` so the scroll carries the
SAME seed/dwBuff/modData (and records the same seed-keyed origin + session cache + peer announce) a
floor-dropped tame would — never a bespoke second-class scroll. Returns the seed, or nil if the inventory had
no room.

### `allyToMonsterData`
Build a monsterData record from a live deployed ally + its tracking entry. `entry` provides
`capturedDifficulty` (stored at deploy time). Unique-ness is derived from `entry.seed` — the single source of
truth used by every other site (`OnLevelEnter` / `OnItemPickedUp` gilding, `OnPrepareUniqueInfoBox`, the dup
check). The live monster's `ally.uniqueType` can read back as None for a deployed ally, so deriving uniqueness
from it would yield a recalled scroll with a normal name and no gold even though its seed/data are still
unique. The HP buff now lives in `maxHitPoints`, so `ally.maxHealth` is the BUFFED max; persist the un-buffed
snapshot (`entry.base.maxHp`) as the scroll's max and clamp current to it, so the transient buff (and any
potion overheal above the buffed max) never bakes into the scroll.

### `refreshRecoveryEntry`
Lazily refresh a Lost entry's stored HP from the live ally (called at level exit, before recall, so a
kept-Lost entry carries the ally's final HP rather than its stale deploy-time value).

### `recallAllyToInventory`
Recall a deployed ally and place its Tame Scroll directly in the owner's inventory. Used for auto-recall on
level exit and manual retame. The scroll is NEVER dropped on the floor: a full inventory simply creates no
scroll, so the caller keeps the recovery backup for Pepin instead (a floor scroll alongside a live backup
would be two copies at once — exploitable in multiplayer). Returns true if the scroll was placed in inventory,
false if the inventory/belt was full. Gold tier (`magical = 2`, ITEM_QUALITY_UNIQUE → gold text + outline) is
set for unique champions/bosses AND Bonded scrolls.

### `recoverScrollData`
Reconstruct monster data from a scroll item's seed and dwBuff. Handles both normal scrolls (typeId in seed)
and unique scrolls (uniqueTypeIdx in seed, bit 15 set).

### `recoveryMessageFor`
Build the player-facing recovery line for a registry entry, or nil if its scroll data can't be reconstructed.
`"lost"` = recall failed / orphaned (free re-buy at Pepin); `"lostfull"` = recalled with no inventory room, so
it went straight to recovery instead of the floor (free, same as "lost", just a clearer message);
`"injured"` = died in combat (paid, full-HP revive at Pepin). The scroll name ("Tamed/Bonded [Lvl N] [Name]")
matches the item Pepin hands back.

### `refundTameScroll`
Fallback only: copy the scroll back so the engine's `ConsumeScroll` (which fires after the deploy hook)
removes the original while the copy survives. Used for genuine, unpredictable spawn failures (no free tile,
monster pool / type table full). Cap and duplicate-unique limits are knowable before casting and are blocked
upfront in `OnCanCastScroll` instead, so the scroll is never consumed for those.

## Plane-1 net sync protocol

Replicate a deployed ally onto same-level peers (the live monster + its golem conversion + owner). This is the
keystone every cross-client behaviour reads from — faction targeting, friendly-fire, hostility, and XP credit
all key off `ownerPlayerId` + `isGolem` on the live monster. Combat numbers (max/current HP, resistance, AC)
are a SEPARATE concern handled by the CO message (the owner broadcasts final values); the spawn message
carries identity + difficulty only.

Why a mod-owned spawn instead of the engine spawn wheel: a tamed monster's species is frequently NOT one of
the level's natural monsters. The engine spawn cmd broadcasts a *level-local* index into `LevelMonsterTypes`,
which is meaningless on a peer whose independently-generated level never registered that species — it resolves
to a wrong/empty type → null sprite → render CRASH (bugs.md). So mod spawns are LOCAL-ONLY on the engine side
(no `NetSendCmdSpawnMonster`); we replicate them across clients over the pipe keyed by the globally-stable
SPECIES id. Each client builds its own natural monster set, then the owner's extra allies are recreated on top
via `monsters.netSpawnAt`, which registers the species locally (its own index + GFX). A short load delay on
the joining client is acceptable.

Message types (`NET.*` tags), payload = `"<TAG>|<args...>"`:
- **SP** `id|species|uniqueIdx|difficulty|x|y|seed|owner|parent` → recreate + golem-convert an ally on a peer
  (parent = spawner id for a minion, else -1).
- **RQ** → "I just entered this level; ally owners, (re)send your deployed allies to me."
- **DR** `typeId|uniqueIdx|difficulty|x|y|seed|maxHp|savedHp` → a non-owner asks the level owner to spawn its
  ally (mirrors `CMD_REQUESTSPAWNGOLEM`).
- **DF** `seed` → owner couldn't place it; requester refunds.
- **CO** `id|maxHp|hp|minDmg|maxDmg|toHit|ac|resist|isMinion|bonded|bondedImm|baseMaxDmg|sharePctMille|magicCur|resFire|resLight|resMagic|trnVariant|nearBonded|baseMinDmg|baseToHit|baseAC|baseMaxHp|kills|gamemode|areaLevel|ohId|ohName`
  → the ally's OWNER broadcasts its final combat values + caster profile to same-level clients. Receivers
  apply the combat values to the live monster (so hostile combat, melee damage, and HP-threshold AI all use
  the owner's buffed numbers, not the base re-roll) and cache the caster profile for spell-damage resolution +
  the values a peer can't derive (Bonded recolour variant, the pre-Bonded flash window, the base stats / kill
  count / Original-Trainer the info boxes show). `ohName` is the LAST field (free-form; may contain "|", so the
  receiver rest-captures it verbatim). Owner-authoritative: no receiver re-derives.
- **RM** `id` → the OWNER silently removed a tracked ally/minion (recall, retame, level-exit, or a parent's
  minion cleanup). Receivers despawn their local copy so it doesn't linger as a ghost. NOT used for a natural
  death (the engine reaps that on every client) nor for a tamed wild monster (see CR).
- **CR** `id` → a wild monster was just removed locally as part of a conversion (e.g. tamed into a scroll). It
  is NOT golem-flagged, so RM's owner check can't carry it; CR tells same-level peers to remove the same plain
  monster too, so the level owner's sync can't re-materialise it as a live/ghost copy.
- **DI** `x|y|seed|dwBuff|name` → a Tame Scroll was just dropped on the floor (a fresh tame). Each same-level
  peer spawns an identical item locally (same seed/mapping/position), so the floor item exists on every client
  — including the level owner, whose delta is authoritative, so it is never purged — and MP pickup
  (identity-keyed by seed) removes all copies together. The blob rides the SD message sent just before this
  one; the receiver reads it from `receivedBlobs`. The name is the LAST field (no "|").

The tags live in one table (`NET.*`) instead of a separate top-level local per tag. NET stays `local` (not a
sandbox global) because it is part of the net layer — the inter-mod surface that talks to the LuaNet
multiplexer; grouping the tags into one table also keeps the local footprint to a single slot.

### `broadcastSpawnAlly`
Broadcast an ally's full identity so same-level peers can recreate it. `mask` defaults to all other clients;
pass a single-player bitmask to answer one requester. `parentId` is the spawner's monster id for a minion (so
peers track the parent link for cap-counting and despawn-with-parent), or nil/-1 for a directly-deployed ally.
No-op in single-player.

### `broadcastRemove`
Tell same-level peers to despawn the monster at `monsterId` (an ally/minion we just silently removed). Keyed
by monster id, which is identical on every client for a tamed ally (peers recreate it at the owner's id via
`monsters.netSpawnAt`). No-op in single-player. Assigns the forward-declared local so the recall /
minion-cleanup helpers (defined earlier) can reach it.

### `broadcastCaptureRemove`
Tell same-level peers to remove a plain (non-golem) wild monster we just removed locally as part of a
conversion (taming it into a scroll). Without this the level owner's monster sync re-materialises the monster
on the tamer's client (a live "invisible" copy) and it lingers as a ghost on every other peer. Keyed by
monster id, identical across clients for a level-natural monster. No-op in single-player. level/x/y travel with
the id so a peer NOT on the captor's level (e.g. still in town) can still record the kill in that level's delta
— otherwise it never learns the wild monster was removed (the live removal and a level-scoped pipe message only
reach same-level peers) and regenerates it alive on entry, exactly as a networked monster death records the
delta on every client regardless of their level.

### `broadcastScrollData`
Announce a scroll's full identity blob keyed by seed, so a peer that later receives the scroll via a live
trade can restore it from `receivedBlobs`. `level` is the delta level of the floor item being announced (so
receivers mirror the blob into that level's delta and can serve a late joiner even after we leave), or nil/-1
for a held scroll (display/trade cache only, no delta write). `mask` answers one requester (RQ); default = all
other clients. The blob is the LAST field (it is binary — `string.pack` output — and may contain "|"; the
receiver captures everything after the 2nd "|" verbatim). No-op in single-player.

### `placeScrollOnFloor`
The ONE floor-drop primitive for a Tame Scroll (fresh tame, corrupt-scroll refund, full-inventory deploy
refund all route through it). The ITEM replicates itself: `items.spawnAt` announces it over the engine wire
(`CMD_SPAWNITEM` — same-level peers spawn a live copy via `SyncDropItem`, every client incl. the sender
registers it in the level delta through `OnSpawnItem`, dedup built in), exactly like a vanilla quest/reward
drop; the level owner's authoritative delta therefore always holds it, and MP pickup removes the
identity-keyed (seed/index/createInfo) copies together. Only the BLOB needs mod plumbing, because the
vanilla item wire/save structs are fixed-width: it is written at rest into the level delta
(`setItemDeltaModData`, survives rejoin/restart) and announced live over SD (peers' caches). A peer's copy
is recreated from the wire (no encoded name), so it reads as the base scroll until `OnCustomItemRecreated`
/ the pickup restamp re-derives the name.

### `broadcastCombatOverride` / `broadcastAllCombatOverrides`
`broadcastCombatOverride` broadcasts one owned ally's final combat values + caster profile (the CO message);
`mask` defaults to all other same-level clients, pass a single-client bitmask to answer one requester (RQ);
no-op in single-player and for an ally we cannot profile. The OH name is the LAST field (free-form); it may
legitimately contain the "|" delimiter, so it is sent verbatim and the receiver rest-captures it after the
fixed leading fields (which never contain "|"). `broadcastAllCombatOverrides` broadcasts CO for every deployed
ally/minion, called after a recalc (the share-divided buff shifts all allies' stats at once) so peers stay
current.

### `finishDeploy`
Shared final step of deploying an ally: golem-convert it to `ownerId`, restore persisted HP, track it in
`deployedAllies` (its AI runs on the ally's owner), back it up for recovery, apply Bonded bonuses, and recompute
the share-divided buff. Used by BOTH deploy paths: local (we are the level owner) → `doBroadcast = true`, also
SP-broadcasts the ally to same-level peers; requested (we asked the owner, the SP echo arrived) →
`doBroadcast = false`, the SP already crossed. Sets max HP before current so the wounded current HP is applied
against the correct maximum. Backs the ally up as "lost" the moment it deploys, so a crash/quit while it is out
still leaves a recoverable scroll (a clean recall/retame deletes this entry; only orphaned ones reach Pepin).
If already Bonded (kills met in a prior session), restores its stored defensive bonus, rolling one if the seed
has none yet.

### Minion spawning (`allyCapturedDifficulty` / `adoptOwnMinion` / `registerSpawnedMinion`)
Minion spawning is single-authority on the LEVEL OWNER (the only client that may allocate a monster slot — see
the deploy path / PrepareSpawnSlot). The level owner spawns the minion for whichever ally raised it, attributes
it to that ally's OWNER, and replicates it over the species-id pipe (SP carrying the parentId + captured
difficulty). The ally's owner owns the minion's Plane-2 state: it tracks it in `deployedAllies`, bakes the
one-time buff, and broadcasts its combat values (CO). When the level owner IS the ally's owner it does both
halves directly; otherwise the owner adopts on the SP echo. Minion species are not level-natural, so peers must
recreate by species id — never the engine spawn wheel. `allyCapturedDifficulty` reads the captured difficulty a
tamed ally was tamed at (so its minions scale to match), falling back to the live game difficulty if unknown.
`adoptOwnMinion` is owner-side bookkeeping for an already-spawned, already-golem-flagged minion: track it in
`deployedAllies` (isMinion + parentId — reuses the ally outline/name path, excluded from the deploy cap,
despawns with its parent), snapshot base + bake the flat CLVL% minion buff once, then broadcast its combat
values; does NOT broadcast SP. `registerSpawnedMinion` is called on the LEVEL OWNER immediately after it spawns
a minion: golem-flags it to the parent ally's owner, replicates it (SP), then either adopts it (we are that
owner) or tracks it as a remote ally (the real owner adopts it on the SP echo).

### `luanet.register("hunter", ...)` dispatcher
The single message dispatcher for the "hunter" channel. Slot ids are PER-LEVEL: handlers only act when the
sender shares the active level. SP resolves the monster — for ANOTHER player's ally we always (re)create it at
the slot, mirroring vanilla `CMD_SPAWNMONSTER` (which unconditionally re-inits at the given slot id); deploy
slots sit above the natural-monster region, so we are their sole writer (overwriting a stale copy left by a
prior occupant of a reused slot is always correct); for our OWN ally we keep the copy we spawned locally,
recreating it only if the level owner spawned it for us (DR) and it isn't here yet. `netSpawnAt` seeds initial
state from the slot id (mid); per-monster AI RNG is re-synced each tick by the engine (MonsterSeeds, keyed on
the same id), so no seed is passed. For our own directly-deployed ally the handler completes the local Plane-2
setup we deferred when we sent the DR (`finishDeploy` golem-flags it to us and tracks it). For our own minion
it owns it + does the owner-side minion bookkeeping, idempotent against an RQ/SP resend. For another player's
ally/minion it golem-flags for the REMOTE owner (so faction targeting / friendly-fire / hostility resolve here)
and records it in `remoteAllies` (with captured difficulty so a level owner can scale minions it raises); a
remote observer derives ownership from `ownerPlayerId` + `isGolem` (`isOtherHuntersAlly`). RQ: a client just
entered our level (or any level); if we own deployed allies, (re)send each one to the requester — we don't gate
on the requester's level here (it may not be visible to us yet); the requester's SP handler validates the
shared level. Allies are always on our current level (recalled on level exit), so every tracked non-minion
entry is eligible; we also answer with the full identity blob of every Tame Scroll we're holding, so the
newly-entered Hunter already has it cached if we trade one to them.

**CO handler**: parses 28 fixed fields then a free-form ohName (kept intact even if it contains "|"). Applies
combat values to the live monster and rebuilds `rec.profile`. Mirrors the Bonded cosmetics on this peer: the
permanent aura glow is state-driven (idempotent), so it's (re)applied whenever the ally is Bonded;
`OnGetMonsterTRN` paints the recolour from `prof.trnVariant`. The one-shot promotion Flash burst fires only on
the live false→true transition we actually witnessed (`prevProfile` present and not bonded); a fresh record
(`prevProfile == nil`: late join, redeploy, or RQ resync of an already-Bonded ally) never replays it. It fires
on every client for consistency, exactly as the owner's own `promoteToBonded` does — ally-safe per the engine
faction check.

**RM handler**: the sender removed one of its allies/minions; despawn our local copy so it doesn't ghost.
Self-validating: only act on a live monster golem-flagged to THIS sender. That holds even after our own
`OnMonsterDeath` cleared the Lua tracking (the engine golem flag persists until the body is removed), so there
is no race with a parent-death sweep. It also can never touch our own ally or the vanilla Golem (their
`ownerPlayerId` is our local id, never the remote sender's) — the Golem barometer holds.

**CR handler**: the sender tamed a wild monster, removing it only on their client. We must reap it too — and
crucially record the kill in our copy of that level's delta — so it never regenerates alive when we (or a later
joiner served our delta) load the level. This mirrors how a networked monster death records the delta on EVERY
client regardless of their current level. Never touch a golem-flagged monster (allies use RM). On the captor's
level `removeAsKilled` also records the delta_kill; off-level we just `recordDeltaKill` for that level.

**DI handler**: the sender dropped a Tame Scroll on the floor. Spawn an identical item locally (same
seed/mapping/position) so the floor scroll exists on this client too: on the level owner this lands in the
authoritative delta (so it is never purged), and on every client it shares the dropper's seed identity, so MP
pickup removes all copies together. Slot ids / exact positions are per-client but pickup is identity-keyed, so
they need not match. Only materialise it for a peer on the sender's level. The blob arrived first over SD
(`receivedBlobs`). The encoded "Tamed/Bonded Lvl N <Monster>" name is Hunter-only (`OnCustomItemRecreated`
normally gates it, but `items.spawnAt` bypasses that); a non-Hunter must still spawn the item so its delta
holds it, but with the base "Tame Scroll" name — pass nil so spawnAt keeps the base item name.

**DR handler**: a non-owner asked us to spawn their ally. Mirrors the engine's `CMD_REQUESTSPAWNGOLEM`: only
the level owner spawns, keeping monster-slot allocation single-authority (avoids cross-client desync). Owner is
HP-authoritative: it applies the requester's persisted HP, which then syncs to all clients; golem-flags the
ally to the requester (not us); records it in `remoteAllies`; and broadcasts to all OTHER same-level clients
(default mask) — including the requester, who materialises it and completes its deferred Plane-2 setup in the
SP handler. If it can't place the ally (no free tile / pool full) it sends DF so the requester refunds.

**DF handler**: the level owner could not place an ally we requested — refund the scroll the engine already
consumed.

### No `OnGolemCanRunAI`
We deliberately do NOT register an `OnGolemCanRunAI` handler. A tamed ally's AI now runs on EVERY client (like
a vanilla golem) — the per-tick AI hooks are written to behave identically on the owner and on peers (owner
anchored via `ownerPlayerId`, randomness drawn from the synced per-monster RNG via `monsters.aiRandom`, combat
inputs synced via the CO message). Suppressing a remote ally's AI was what froze it on peers (the engine
monster sync carries position, not mode).

### `OnLevelEnter` (RQ on entry)
On entering a level, ask any same-level ally owners to (re)send their deployed allies, so a client that joins
AFTER a deploy still materialises the allies (the live SP at deploy time only reached clients already on the
level). Fires for everyone in MP (non-Hunters need allies for correct combat/rendering too); no-op in
single-player. Clears stale remote-ally tracking first — monster slot ids are per-level, so the previous
level's entries are meaningless here and the RQ replies repopulate. `pendingDeploys` is also cleared (a deploy
request in flight across a level change is stale).

## Tame cast + Share Potion

### `OnSpellActionFrame` (Tame skill + scroll)
Fires at the mid-animation release frame (instead of `OnSpellCast`) so the effect syncs with the animation.
- **Scroll cast (spellType == 2)**: deploy the stored tamed monster. `scrollSeed` identifies the exact scroll
  item that was right-clicked. If the session data was lost (game restart), recover from seed+dwBuff; if dwBuff
  is zeroed/corrupt the scroll can't be spawned, so refund by copying it before `ConsumeScroll`. Cap /
  duplicate-unique limits are normally blocked upfront in `OnCanCastScroll`; the checks here are last-resort
  refund nets for any path that bypasses it (e.g. a hotkey cast where the selected seed is unknown). Spawning
  is level-owner-authoritative (PrepareSpawnSlot / vanilla SpawnMonster both gate on
  `isLevelOwnedByLocalClient`, "to prevent desyncs in multiplayer"): if we are NOT the level owner we cannot
  allocate a monster slot locally, so we mirror the base Golem spell (`CMD_REQUESTSPAWNGOLEM`) — send a DR; the
  owner spawns + golem-flags + applies HP, then SP-broadcasts it back so it materialises here (the SP handler's
  owner==me branch completes the deferred Plane-2 setup). When we ARE the level owner, `finishDeploy(...,
  doBroadcast = true)`. A genuine spawn failure when we own the level is the legitimate refund-fallback case
  (not knowable before the cast).
- **Retame (skill, target is our own deployed ally)**: recall it to inventory. Minions have no scroll and
  cannot be recalled (casting Tame on one does nothing); recalling a parent despawns the minions it spawned.
  The scroll is recalled into inventory (never dropped on the floor): refresh the backup first (capture current
  HP); a clean recall deletes the backup; a full inventory keeps it as "lostfull" — the scroll lives only in
  recovery storage (never a grabbable floor item), recovered at Pepin. Floor-dropping was removed because a
  floor scroll alongside a live backup is two copies at once (in multiplayer another player could grab the
  floor copy and duplicate it). The deployed count drops, so survivors re-absorb the freed buff share.
- **Capture (skill, target is a wild monster)**: a monster at 0 HP (dead, or mid death-animation) must never be
  captured — its death is deterministic and already running on every other client; converting it here
  (`removeAsKilled` + scroll mint) races that synced death → a half-removed "twitching" body / ghost on peers,
  plus a scroll minted from a corpse. The HP-percent gate doesn't catch this (a dying monster reads 0%, the
  easiest possible tame), so it's vetoed explicitly at the capture layer. Capture requires passing BOTH the
  active tier's mlvl/category gate AND the category's capture-HP threshold. Diablo is gate-eligible at Tame+++
  but hard-blocked for now (taming Diablo is deferred to its own sub-task: the Apocalypse friendly-fire-on-
  players landmine must be solved first). The mlvl/category silent return is mirrored as a hard "I can't do
  that" pre-cast veto in a later pass. Taming a quest monster clears its quest exactly as if it were killed
  (quest state + death speech, e.g. Skeleton King → "Rest well, Leoric..."; Lazarus → opens the path to
  Diablo); no-op for non-quest monsters (incl. Lachdanan, who is never a combat target); called before
  `remove()` while the monster's type/uniqueType are still intact. `removeAsKilled` (not `remove`): a wild
  monster is level-natural, so it must be recorded as killed in the MP delta — otherwise a client that loads
  this level later (e.g. the level owner, whose delta is authoritative) regenerates it from the level seed and
  it survives there as a live ghost, and its still-occupied slot id can collide with an id reused by a
  later-deployed ally, hiding that ally. The taming Hunter is stamped as the monster's permanent Original
  Trainer (name + OHID).

### `applySharePotion`
Internal helper — scan caster's inventory for a health potion, consume it (unless a level-scaling freecast proc
fires), and heal the target ally. Returns true if a potion fired, false otherwise. Full Heal → restore to max
HP (or 150% on overheal proc); Heal → restore min(current + 30% maxHP, maxHP) (or 150% on overheal); no potion
→ voice line "I can't do that", return false. Potions are detected by EFFECT (miscId), not base item index:
`IDidx` pins one exact AllItemsList entry, while `IMISC_HEAL` / `IMISC_FULLHEAL` match every healing potion
regardless of how it was created; the matched item's `IDidx` is captured so we remove that exact base type
after a successful share. A separate `OnSpellActionFrame` handler for the Share Potion skill enters
CURSOR_HEALOTHER targeting mode (fires at the mid-animation release frame so the cursor activates after the
animation plays); the actual heal fires in `OnCursorMonsterTarget` when the player clicks an ally.

## Potion of Forgetting + scroll item hooks

### `OnItemUsed` (Potion of Forgetting)
Reset all base stats to class starting values, refund invested points, correct HP/mana drift from Black Death
/ shrines. Works for all classes, not just Hunter. The engine has already restored full HP and mana (FullRejuv
effect) before this fires. Identified by `miscId == FullRejuv` AND `spellId == FORGET_POTION_ID`; regular Full
Rejuvenation Potions have `spellId == 0` (`SpellID::Null`) so they are ignored.

### `OnGetMiscItemDescription`
Override the info box description for the Potion of Forgetting. The default "restore all life and mana" line
comes from its `IMISC_FULLREJUV` miscId. We detect by spellId (stored on the item for detection purposes only).

### Potion stash exclusion + session-only persistence
`OnItemAllowedInStash` keeps mod items out of the normal stash: the Potion of Forgetting must never persist
(the stash would carry it into another game), and Tame Scrolls must never land in a stash that a non-modded /
base-game session could load (Hunters get a dedicated mod-owned scroll stash later — see the phase 10
roadmap). `ITEM_STATE_FIELDS` lists every writable Item field, so a popped item can be put back byte-for-byte
into its exact original slot (name/iName are strings, copied separately); this lets us blank a slot for the
save then refill the *same* slot afterwards without moving the item (works for both inventory and belt slots).
`OnBeforeSaveHero` / `OnAfterSaveHero` bracket the hero-file write so the Potion of Forgetting is absent from
what gets serialised, then restored to the LIVE inventory in its exact original slot. Net live state is
unchanged within the session, but the potion is never written to disk, so it cannot survive into a new game
regardless of how the current one ends (menu exit, quit, crash, force-close); no load-time scan is needed;
applies to every class. `pop()` clears the slot in place (no array compaction — index/position preserved) and
returns a full copy; we hold both the live slot reference and the copy, then write the copy back into the same
slot after the write. The inventory arrays are not touched between the two hooks (the save only reads them), so
the live reference stays valid. If the game dies between the two hooks, the on-disk save has an empty slot,
which `RemoveEmptyInventory` sanitises on the next load — so a crash mid-save corrupts nothing.

### `OnCustomItemRecreated`
Restore dynamic scroll name after a pfile/delta round-trip. Fires from inside `RecreateItem` (items.cpp) after
`InitializeItem` resets the name. `item.seed` and `item.buff` are valid at this point; name is "Tame Scroll"
(base name). Non-Hunter visibility: a non-Hunter who sees one of these scrolls (e.g. dropped on the floor in
MP) must see only the generic base name, never the class-specific encoded name; leave the base name in place
when the local player is not a Hunter — purely a display gate, no save/state mutation. Keeps the Bonded prefix
+ gold tier (`magical = 2`, ITEM_QUALITY_UNIQUE) across the round-trip; Bonded normal scrolls render at gold
tier too.

### Speedbook scroll injection (`OnGetCustomSpeedbookScrollEntries` / `OnResolveCustomScrollSlot`)
`OnGetCustomSpeedbookScrollEntries` injects one entry per unique Tame Scroll name held in inventory,
deduplicated by display name (count reflects how many of that name exist). Tame scrolls carry `iSkipSpeedbook`
and are custom-injected here, so they don't auto-hide from being made red — out-of-tier scrolls are filtered
at injection. Tame scroll item names already carry their full "Tamed/Bonded [Lvl N] [Name]" form; used as-is so
the spellbook entry matches the scroll's own item box (unique names already omit "Lvl N"). `OnResolveCustomScrollSlot`
resolves a Tame scroll cast to the EXACT scroll the player selected: every Tame scroll shares the single
`TAME_ID`, so the engine's default "first matching scroll" can deploy/consume the wrong one when several
distinct Tame scrolls are held; `selectedSeed` is the seed of the speedbook entry that was clicked, and we
return its inventory slot so `OnSpellActionFrame` (deploy) and `ConsumeScroll` agree on one scroll. If the
selected scroll is gone (e.g. recasting a same-name stack after one was consumed) it falls back to any other
held scroll of the same monster type / unique index.

### `OnCanCastScroll`
Block a Tame scroll cast UPFRONT (before the engine commits the cast or consumes the scroll) for limits that
are knowable in advance: the ally cap and deploying a second copy of a unique already out. The character
refuses with "I can't do that" and the scroll is never consumed — the refund fallback is reserved for genuine
spawn failures. `selectedSeed` is the clicked speedbook entry's seed; 0 (e.g. hotkey cast) skips the unique
check here and falls back to the safety net in `OnSpellActionFrame`. `target` is the cursor-targeted monster
(nil when none / not a monster-aimed cast). Any non-Tame scroll (e.g. an offensive scroll like Fireball) must
never be cast at the caster's own ally / a friendly Hunter's pet — same misclick protection as a direct
attack; the Tame scroll is exempt (it deploys a new ally).

## Belt/speedbook + level exit + save/load lifecycle

### Belt + speedbook tweaks
`OnCanAutoRefillBeltItem` exempts Tame scrolls from Auto Refill Belt: every Tame scroll shares the same misc
id + spell (`TAME_ID`), so the engine's belt auto-refill would redirect a belt cast to the first matching
scroll in inventory/belt — deploying a random tamed monster instead of the one in the selected belt slot;
returning false keeps the exact selected belt slot. `OnGetSpeedbookSelectionType` reverts Scroll entries that
share `TAME_ID` with the starting Tame skill back to Scroll type after the engine's starting-skill promotion
fires. `OnGetSpeedbookSpellName` shows "Tame+" (clvl 20+), "Tame++" (clvl 35+) or "Tame+++" (clvl 45+) to
reflect unlocked tame tiers.

### `OnLevelExit`
Auto-recall all deployed allies to the player's inventory. Handles both normal level transitions and player
death (WM_DIABRETOWN). A full inventory keeps the ally as a "lost" recovery backup (recover at Pepin) — no
floor drop. Minions are not recalled (no scroll); we tell peers to despawn each one — the owner is leaving the
level, so the engine won't reap it for them and it would otherwise ghost (our own copy unloads with the level).
Recalled allies refresh their backup first (capture final HP), then recall WITHOUT a floor fallback: a clean
recall deletes the backup, but a full inventory keeps it as "lost" for recovery at Pepin. Announces every ally
still backed up and not yet recovered ("lost" = orphaned, "lostfull" = recalled with no inventory room);
"injured" is announced at death, not here. Finally drops any pending corpse-suppression / resurrect-beam
entries: a monster that died on this level but whose death frame never completed (we left first) must not carry
its skip into the next level, where its slot id could be reused by an unrelated monster.

### `relinkSavedAllies`
Single-player Load Game re-link. A SP "Load Game" restores a mid-dungeon level with the deployed golems still
live on it (the level save serialises every monster), but the Lua `deployedAllies` tracking is session-local
and not part of the save. Without this rebuild the golems reload ORPHANED — no Tamed name/outline/leash/buff/
kill-credit, not recallable, and their still-"lost" recovery backups would let Pepin hand out duplicate scrolls.
Re-bind each saved roster record (set by `OnLoadPlayerData`) to its reloaded golem via stable monster slot id.
Called from `GameStart`, which fires AFTER `StartGame` has fully loaded the saved level and its monsters (and
after the per-game state clear — so the rebuilt set is not then wiped). SP only: MP never persists a roster
(slot ids aren't comparable across clients) and its deployed allies persist via the network delta. Re-links
only a still-live golem owned by the local player; a dropped/empty slot (`fromId` nil) or a mismatched monster
is left untracked so its "lost" recovery backup survives for Pepin rather than re-binding to the wrong monster.
Re-asserts Bonded state, mirroring the redeploy path (`bondedImmunity`/`bondedTrn` were restored by
`OnLoadPlayerData`, so the rolls are no-ops; `applyBondedBonus` re-asserts the immunity via idempotent OR and
`applyBondedGlow` restores the aura light radius, which is not level-saved). Then re-derives the live
share-divided buff now the full set is tracked: `applyAllyBuff` WRITES base+buff (it does not accumulate), so
this overwrites the already-buffed saved stats with a clean value — no double buff — while leaving wounded
current HP intact; minions keep their saved stats.

### `announceRecoveryOnEntry`
On entering a game (new game / load), remind the player of every recovery-registry backup waiting at Pepin —
both "lost" (orphaned) and "injured" (defeated) entries. Skips any seed that is actually deployed right now (an
SP mid-dungeon load re-links its golems first), so we only nag about scrolls the player still has to reclaim.
Runs after `relinkSavedAllies` so the deployed set is final.

### `healHeldScrollModData`
Heal each held Tame Scroll's modData blob from its seed's save-persisted tables. The blob is NOT written to the
hero save (it lives only in memory / the level delta / the wire), so a save→reload leaves a held scroll's
`item.modData` empty. The full identity always survives in the seed-keyed tables + `scrollOrigin` (restored by
`OnLoadPlayerData`), so rebuild each held scroll's blob from `blobForSeed(seed)`. This makes a scroll that was
saved/reloaded since acquisition trade/drop losslessly again — on the next drop the blob is re-persisted to the
delta and announced. Local Hunter only: only a Hunter ever holds a Tame Scroll, and only our own inventory may
be mutated. A starter scroll records its Original-Trainer name during character creation, but the player name
does not exist yet then (CreatePlayer zeroes the struct and the name is filled in later), so it persists empty;
fill it in now from the valid local name (an empty stored name only ever comes from our own un-named creation —
a scroll acquired by trade always carries its trainer's name in the blob — so claiming it for the local Hunter
is safe). Done before the blob rebuild so the corrected name is baked into the blob too.

### `GameStart`
Reset all live, per-game session state to its empty start-of-game invariant, then (single-player) re-link any
deployed allies saved mid-dungeon. The Lua runtime persists across games within a single app launch, but
`OnLevelExit` (which recalls allies and clears the per-level death sets) fires ONLY on in-game level
transitions — NOT when the player quits to the main menu. So quitting to the menu with an ally still deployed
leaves `deployedAllies` (and the death-FX sets) populated with entries pointing at monster slots from the
now-dead game. On the next game those slot ids alias freshly-created monsters (e.g. the reserved golem
holding-cell slots), and the per-frame leash check in `GameDrawComplete` then snaps that aliased monster onto a
town tile — writing a live monster index into the town's `dMonster`, which the town render path reads as a
Towner index and crashes (`Towners[index]` out of range). At the start of any game no ally is deployed (allies
are always in scroll form between games), so clearing the live set is always correct. Clears only
live/transient state — NOT the save-persisted tables (`allyKillCounts`, `recoveryRegistry`, `bondedTrn`,
`bondedImmunity`, `scrollOrigin`) which `OnLoadPlayerData` has already repopulated, nor
`tameScrollData`/`scrollCounter` which `OnCreatePlrItems` seeds for a brand-new character; all of those run
before `GameStart`. AFTER the clear, the single-player Load-Game re-link repopulates `deployedAllies` from the
saved roster.

## Death, kill-credit, minion spawn, info boxes

### `OnMonsterDeath`
Remove an ally from the tracking list if it dies in combat. Captures remote-owned status BEFORE clearing the
tracking — the death visuals (corpseless vanish + resurrect beam) must fire for an ally we only OBSERVE
(`remoteAllies`) too, not just our own. On a peer: drop remote tracking for the dead ally, and any remote
minions whose parent just died, so the per-client minion count stays correct (no-op on the owner for its own
allies, which live in `deployedAllies`; the dead monster's own body is reaped by death itself on every client;
the owner's `removeMinionsOfParent` then RM-broadcasts each orphaned minion so peers despawn those bodies too).
If a parent ally died, its minions cannot outlive it — despawn them silently. Death visuals apply to a tamed
ally/minion we OWN OR merely OBSERVE, so the corpseless vanish + resurrect beam look identical on every client
(the death is engine-synced; `OnMonsterDeath` / `OnMonsterCanPlaceCorpse` fire on each); record BEFORE
untracking (the corpse hook fires later, after the entry is gone); minion-ness comes from `entry.isMinion`
(own) or a non-nil `parentId` (remote). A NON-minion ally death gets the resurrect-beam FX on its final death
frame. Owner-only recovery bookkeeping: the scroll backup lives only on the owner, so this runs for OUR OWN
non-minion ally — mark its backup "injured" (paid, full-HP recovery, recovered at full HP not its dying HP) and
announce it; minions have no scroll and never recover; a remote ally's recovery is its own owner's concern.
Only a non-minion ally death changes the buff share, so the recalc is skipped on unrelated deaths.

### `OnMonsterCanPlaceCorpse`
Tamed allies/minions vanish on death instead of leaving a corpse, and spawn the resurrect-beam FX — for an
ally we own OR merely observe (another Hunter's), so every client matches. Keyed by the `corpselessDeaths` /
`pendingResurrectBeam` sets recorded in `OnMonsterDeath` (the entry is already untracked by the time this
fires). A vanilla Golem is never recorded, so it keeps its vanilla corpse.

### `OnMonsterCanCompleteQuest`
A tamed quest boss already cleared its quest at tame time, so it must NOT re-trigger the quest (and replay the
death speech) when it later dies as an ally. Any golem/player-minion dying is never "the player slaying a quest
boss". `isGolem` is stable at death time, so this is independent of when our `OnMonsterDeath` untracking runs.

### `creditAllyKill` / `OnGolemKilledMonster`
Track how many kills each OWN deployed ally has earned (Bonded progression). Keyed by seed so counts survive
level transitions and re-deploy. No-op for minions and for remote allies (owner-tracked + CO-synced). Shared by
the melee path (the engine fires `OnGolemKilledMonster` from `StartDeathFromMonster`) and the missile path (the
`OnMonsterMissileHit` handler); assigns the forward-declared local so the missile handler can reach it. Detects
the exact kill that crosses the Bonded threshold and promotes (which re-applies the buff incl. the new
kill-ToHit, then broadcasts CO since stats/immunity/profile changed). Otherwise re-syncs CO to peers on the
kills that change something they render: a `KILL_TOHIT_PER` increment (+1% ToHit per 10 kills — also re-derive
the buff locally) and entering the single-kill pre-Bonded window (`after == needed - 1`) so peers start the
flash tell.

### `OnGolemMinionMissileSpawn`
A golem-fired spawn missile (a tamed Hork Demon's Hork Spawn) landed. The engine's default spawn is suppressed
on EVERY client (return false) because the minion species is not level-natural; the LEVEL OWNER creates the
correct species at the landing tile, attributes it to the Hork's owner, and replicates it, and peers receive it
over the net. Mirrors the Skeleton King flow, but the spawn point comes from where the missile landed. Spawn
authority = the LEVEL OWNER (single monster-slot allocator), regardless of who owns the Hork. The minion cap is
enforced HERE, owner-only and authoritatively, NOT in the Hork's fire roll: the minion count is network-timed
(a peer learns of a minion only when the SP arrives), so keeping it out of the deterministic fire roll lets the
missile fire in lockstep (see `OnGolemChooseAction`). The owner's count is authoritative, so checking it here
never over-spawns even across several in-flight missiles.

### `OnGetMonsterInfo` / `petKills` / `OnMonsterCanShowResistances`
`OnGetMonsterInfo` replaces the base-game info block for any friendly-viewable tamed pet (own or a peaceful
player's) with the creature Type + live HP + Kills + resistance/immunity lines. No player kill threshold —
tamed monsters reveal their resistances upfront. The Name is set via `OnGetMonsterDisplayName`; the creature
Type, base/buffed stat readout, difficulty + Original-Trainer live in the floating box. HP is live off the
monster and the kill count rides the synced CO profile, so every friendly observer sees the same values. Reads
the LIVE resistance bitfield (not the type's base) so a Bonded-granted immunity shows. `petKills` returns a
friendly pet's lifetime kill count: own pets from `allyKillCounts` (by seed), a remote pet from its owner's
broadcast CO profile; nil for a minion (no kill progression → no line) or a pet we can't read yet.
`OnMonsterCanShowResistances` forces the healthbar resistance/immunity icons to show for our deployed allies,
overriding the vanilla unique-or-15-kills gate — so a Bonded-granted immunity is visible on the bar, consistent
with the ally infobox revealing full stats; other monsters keep vanilla behaviour.

### Floating stat box (`FBOX_*` / `areaLevelName` / `petFloatingBase` / `fboxDrawRow`)
A floating stat box for a hovered tamed pet (own ally/minion, or a peaceful player's). This deliberately does
NOT use the base-game "Floating Item Info Box" QoL toggle or its single-colour item path: it is fully
self-drawn each rendered frame (`GameDrawComplete`), so it ALWAYS shows for a friendly pet under the cursor and
can colour each value independently. Outlined text means no panel background is needed. Each stat reads as
`base / buffed` with the BUFFED value in the blue magic-item colour when it differs from base. No Name line —
the regular info box carries the name. OH/ID are the scroll's permanent Original Trainer (`scrollOrigin` / CO
profile), so a traded pet still shows its true tamer. Data: own pet from its `deployedAllies` entry (base) +
the live monster (buffed); a remote pet from the CO profile (base + OH name/id) + the live CO-synced monster
(buffed). `FBOX_AREA_ZONES` maps dungeon-level → area-name ranges `{ upperBound, name, displayOffset }` for the
"Found:" field; the shown number is the captured dlvl MINUS the zone's displayOffset, matching the base-game
automap: Church/Catacombs/Caves/Hell show the absolute dlvl (1-16), but Nest (17-20) and Crypt (21-24) restart
at 1-4 (e.g. dlvl 1 → "Church Lvl 1", 13 → "Hell Lvl 13", 17 → "Nest Lvl 1", 21 → "Crypt Lvl 1"). A quest
sub-level (setlevel) encodes as `setlvlnum + NUMLEVELS` (>24) in `items.currentDeltaLevel()`, so it reads as
just the quest-area name with NO "Lvl N" (recovered by subtracting NUMLEVELS); 0/nil reads "Unknown".
`petFloatingBase` returns base stats + provenance for a hovered friendly pet, or nil if it isn't one we can
fully read yet (e.g. a remote pet whose first CO broadcast hasn't arrived); buffed values are read live off the
monster.

## Ally AI hooks (targeting, chase, idle)

### `OnGolemCanTargetMonster`
Restrict targets to ACTIVE monsters within the owner's engage radius. Bounded by `ENGAGE_RADIUS` for ALL
allies (melee AND ranged) so it stays consistent with `OnGolemCanChaseTarget`, which clears the lock for any
target outside that radius. Ranged allies still attack from range *within* the zone (`OnGolemChooseAction`
fires their missile at dist 3-8); they must NOT lock distant targets they can never reach. A previous "ranged
may target outside the radius if it has LOS" exception did exactly that, producing a per-tick thrash: lock a
far monster → can't shoot it (beyond `RANGED_MAX_DIST`) → chase-vetoed (lock cleared) → re-run the full
UpdateEnemy scan → re-lock the same monster → repeat. That kept ranged allies perpetually searching.
Self-defence exception: an adjacent monster is always allowed (the ally fights back in place;
`OnGolemCanChaseTarget` still stops it from following the attacker out of the engage radius). The activation
gate runs FIRST, before any position read or math: `UpdateEnemy` loops EVERY monster on the level and calls
this hook for each, every tick an idle ally has no locked target; the vast majority are asleep
(`activeForTicks == 0`) — the engine's own AI does not run for them until the player makes them visible, and a
tamed ally should behave the same (never wake or chase a monster the player has not engaged). This single flag
read rejects all sleeping monsters with zero allocation — the real fix for "scanning the whole level".
`.position` is cached into a local because each `monster.position` access allocates a fresh Point userdata
(the C++ binding returns Point by value), so reading it more than once per call multiplies GC churn across the
N-monsters × A-allies × tick scan. The cheap distance gate runs BEFORE the expensive LOS raytrace (this handler
runs once per active monster per ally per tick). The zone is anchored to the ally's OWNER resolved from
`ownerPlayerId` (works on every client; the owner may be a remote player), not the local player — so the zone
is the same on owner and peers. LOS is paid last (without it the ally would acquire targets through walls and
pathfind away from the player to reach them).

### `OnGolemCanTargetGolem`
Pet-vs-pet combat between mutually-hostile owners. Vanilla never lets player-minions fight each other. We
permit it only when the two pets belong to DIFFERENT players who are not both friendly (i.e. at least one has
toggled Hostile). The test is symmetric, so a defender's pets fight back automatically even before that player
toggles Hostile themselves. Uses the same `arePeaceful()` test as the blue/red outline so the visual and combat
relationships always agree. Generic: works for any class's golems, not just Hunter allies (owner is read from
`goalVar3`/`ownerPlayerId`).

### `OnGolemCanChaseTarget`
All allies stay within the engage radius when chasing: blocked if the ally itself is outside the lit area (let
idle pull it back), or chasing an unlit / out-of-range target.

### `friendlyAllyNearPath` / `OnMissileCanTargetMonster`
`friendlyAllyNearPath` answers: is a PROTECTED pet — one of OUR deployed allies/minions, or a tracked remote
ally whose owner is at peace with us — on or NEAR the straight line from (sx,sy) to (tx,ty)? Used to refuse a
spell target whose firing line passes a pet, so an auto-targeting bolt is never fired "through" (or close past)
a pet. A HOSTILE owner's pets are deliberately not swept (fair PvP game); own ∪ peaceful-remote is the same
protected set on every mutually-peaceful client, so the veto stays symmetric across clients. Chain Lightning's
spread bolts travel a line and `CheckMissileCol` along it, splashing tiles ADJACENT to the rounded path — an
exact on-line test let a pet sitting one tile off the line still get hit (and, if it died, crash via the
deferred re-entrant minion cleanup). So we pad: veto if a pet is within `PATH_PADDING` tiles (Chebyshev) of any
sampled point. The target endpoint is included (catches a pet hugging the targeted enemy); the source endpoint
is skipped so a pet next to the cast origin doesn't veto every shot. `OnMissileCanTargetMonster` is the pure
TARGETING gate for auto-targeting spells (Chain Lightning spread + bounces, Bone Spirit homing), fired with the
candidate monster and the missile's origin tile (`source`); returning false means "do not fire a bolt at this
monster": (1) never target our own allies/minions, nor a friendly other-Hunter's pet; (2) beyond base game
(only while Friendly Fire is ON — with FF off the damage layer makes the line safe), never target a monster
whose firing line passes a protected pet. A vanilla Golem matches neither pet test (and is in neither tracking
table), so it stays a normal, fully targetable base-game monster.

### `OnGolemCanSelect`
Cursor selection (controls hover, infobox, and click-targeting). Own allies/minions are always selectable
(share potion, recall, etc.). Another Hunter's pet is always selectable too, in BOTH friendly and hostile
cases, so the observer can hover it for its name + health bar (and the friendly-only QoL floating stat
infobox). Selecting it never enables an offensive action while friendly: left-click attacks and offensive casts
are blocked separately by `isProtectedFromOffense` (which protects a friendly other-Hunter golem). When
hostile, that protection lifts so it can be attacked like a normal enemy. Hostility governs only the outline
colour and the floating-infobox gate.

### `OnPlayerAttackMonster`
Block left-click attacks and offensive staff-charge casts on the attacker's own allies / a friendly Hunter's
pet (defense-in-depth so no path can damage a protected ally). Once either side is hostile, fall through so it
can be attacked like a normal enemy. Shares `isProtectedFromOffense` with `OnCanCastScroll`. The param is the
attacking Player (shadows the `player` module — use `attacker`).

### `OnGolemIdle` / `syncedHash` / `IDLE_REPICK_TICKS`
`OnGolemIdle`: follow while player is moving; settle near player when stopped. Player moving → path directly
toward player; clear stored idle spot. Player stopped, ally outside `ENGAGE_RADIUS` → pick ONE wander spot
within `ENGAGE_RADIUS` (held stable per re-pick window), walk there. Player stopped, ally inside → stand still.
Active enemy target within `ENGAGE_RADIUS` → pursue that instead. The wander offset is a PURE FUNCTION of the
synced lockstep tick (`system.gameTick`, bucketed) + this ally's slot id — deliberately NOT an `aiRandom` value
cached at first-idle: `aiRandom` is synced per tick, but caching it fixed the spot at whatever tick THIS client
first went idle; a late joiner began simulating the ally on a different tick, so each client cached a different
spot (up to 2×`ENGAGE_RADIUS` apart) and the engine's position sync fought between them = the twitch/zap. A
function of (tick-bucket, id) is identical on every client at the same tick — so the copies agree and the sync
has nothing to correct — and it holds for `IDLE_REPICK_TICKS` so the spot doesn't change every tick. `Point.new`
is unavailable in the mod sandbox, so we offset a copy of `owner.position` (its x/y fields are writable).
`syncedHash` is a deterministic, cross-client-identical mix of two small non-negative integers (arithmetic only
— no bitwise ops / no Lua integer-subtype assumption; operands reduced first so the products stay within
float-exact range). Use it to derive an AI choice from (synced tick, entity id) so every client — including a
late joiner — computes the SAME value with no network traffic. This mirrors how the engine keeps per-monster AI
RNG in sync (it reseeds each monster from the synced tick + slot id every game loop, see `system.gameTick`); so
`aiSeed` needs no syncing, only our *cached/persistent* decisions, made at a join-dependent tick, must be
re-expressed as pure functions of the synced tick. `IDLE_REPICK_TICKS` is how many synced lockstep ticks an
idle wander spot holds before it is re-derived (long enough that the ally actually walks toward the spot
instead of re-targeting every tick).

## Hybrid AI, store, per-frame, persistence

### `OnGolemChooseAction` (hybrid AI) — ranged + special behaviours
The ranged handler fires the monster's authentic missile (Succubus→BloodStar, Storm→lightning, Magma→rock,
Counselor→cast by intelligence, Mega→Inferno, …) instead of a generic arrow; an elemental missile's damage is
resistance-scaled in `OnGolemMissileDamage` as it's created. Avoidance casters and Mega/Diablo/BoneDemon use
the special-ranged animation; everyone else the normal ranged one. A second handler restores original AI
special behaviours for tamed monsters (fires AFTER the ranged handler; a non-nil return overrides it):
- **Skeleton King**: periodically raise skeleton minions at range, up to a per-king cap. The spawn ROLL must
  be a PURE FUNCTION OF SYNCED STATE so the king's raise pose plays in lockstep on every client (positions are
  lockstep-synced, the target rides the synced menemy, `aiRandom` is the synced per-tick RNG). The minion CAP
  is deliberately NOT in this roll — a minion exists on the level owner at its spawn tick but on peers only
  once the replicating SP arrives (network-delayed), so `countMinionsOfParent` is unequal across clients during
  that window; gating the shared roll on it would diverge the king's AI control flow (phantom/missing raise
  poses, mismatched RNG consumption) = jitter. Creating the skeleton is single-authority on the LEVEL OWNER,
  which is also where the cap is enforced authoritatively. At cap the king still plays the harmless raise pose
  (like a raise that finds no free tile); peers materialise any actually-spawned skeleton from the SP message.
- **Hork Demon**: fire Hork Spawn at range. Same lockstep rule as the Skeleton King — the missile FIRE roll is
  a pure function of synced state, with NO minion cap, so the missile fires in lockstep on every client (it
  animates and travels deterministically). The cap is enforced authoritatively at the missile's landing,
  owner-only, in `OnGolemMinionMissileSpawn`. At cap the missile still fires but lands without spawning; peers
  receive any spawned minion over the net.
- **Goat Melee (AiAvoidance)**: use its special melee attack at low HP, like the wild goat; otherwise fall
  through to the engine's normal melee.
- **Rhino / Bat (Gloom) / Snake**: charge attack at `CHARGE_MIN_DIST` (Rhino/Bat ≥5, Snake ≥2) with LOS.
- **Gargoyle**: prioritise self-heal over ranged attack when HP < 50%.
- **Scavenger**: eat a nearby corpse to heal when HP < 50% (walk to it, then eat for ~1/8 max HP).

### Stealth AI (`SNEAK_*` + second `OnGolemChooseAction`)
Sneak-type (Hidden/Stalker/Unseen/Illusion Weaver) allies keep their cloak. They fade out when safe and
materialise to strike when an enemy closes in. The gold ally outline still renders while cloaked (engine:
`DrawMonsterHelper` hidden branch), so the player can see and select them. Fires after the ranged/hybrid
handlers. Cloaked: only emerge when an enemy is close (`SNEAK_FADE_IN_DIST`) and in sight; otherwise stay
hidden and let the default golem AI follow the player / approach. Visible: re-cloak when there is no enemy or
the enemy is out of range (`SNEAK_FADE_OUT_DIST`); enemy adjacent → let the default golem AI melee.

### `StoreOpened` (Pepin)
Pepin stocks the Potion of Forgetting + restores tamed monster HP to max + offers recovery buy-backs. Always
keeps a Potion of Forgetting in Pepin's buy list (`addToHealerStock` is idempotent: no-op if already present,
re-adds after purchase). Restores in-session scrolls (data is in the `tameScrollData` cache) and post-restart
scrolls (cache empty; read from the dwBuff encoding — works for both normal and unique scrolls). Re-encodes
dwBuff so the restored HP persists through save/load. Plays Pepin's healing sound if scrolls were healed but
the player's own HP was already full (C++ `HealPlayer()` only plays the sound when the player is wounded, so we
supplement it when tame scrolls are the only thing that needed healing). Recovery system: reconcile buy-backs
first — a registry seed already sitting in the player's inventory can only mean the scroll was bought back
(deploy creates the entry; a clean recall/retame deletes it, and the full-inventory paths never put the scroll
in inventory), so drop that entry before re-stocking — then stock each remaining backup as a buy-back scroll:
free if "lost", paid (level × cost) if "injured".

### `GameDrawComplete` (per-frame leash + recalc)
The local player owns the allies leashed here (own allies live in `deployedAllies`; remote allies are
positioned by their owner + the engine sync, not leashed). Advances the pre-Bonded flash cadence (`flashOn` is
read by `OnGetMonsterTRN` to blink a one-kill-from-Bonded ally for `FLASH_ON_FRAMES` out of every
`FLASH_PERIOD_FRAMES`). Periodically clears remote allies whose owner has left (cheap table scan; runs before
the own-ally early-return — a peer can observe a remote ally while owning none; no-op in SP). Leashes every
deployed ally that has wandered too far back to the owner — but guards each entry against being STALE first:
the Lua mod state outlives a game (it is not reloaded between games) and quit-to-menu never fires
`OnLevelExit`, so `deployedAllies` can still hold entries from a PREVIOUS game whose monster slot the new game
has since freed or reused; `snapToPlayer` writes the monster's index into `dMonster`, and for a stale high-slot
entry that index exceeds the new town's `Towners` vector, so the town render path crashes ("vector subscript
out of range"). Every live ally/minion is `makeGolem`'d and always reads `isGolem` true; a freed/reused slot
has cleared flags, so `isGolem` is false (Monsters is a stable static array, so the pointer is always safe to
read — it just reads empty data). Pruning any non-golem entry self-heals a leftover set even if the GameStart
reset did not run early enough on this client/flow (iterate backwards so `untrackDeployedAt`'s `table.remove`
is index-safe). Recalc cadence: the share-divided buff scales off the Hunter's live stats, so a CLVL-up or gear
swap mid-deployment must re-derive every ally's buff; poll a cheap stat fingerprint (once per frame, only while
allies are deployed) and recalc only when it actually changes.

### Mod-data save format (`OnSavePlayerData` / `OnLoadPlayerData`)
`allyKillCounts` + `bondedImmunity` + `bondedTrn` + `recoveryRegistry` (and more) persist via a dedicated
mod-data save slot. Stored as flat sections separated by 0 markers (0 is never a valid seed, immunity flag, or
TRN variant — seeds are counter×4096 with counter ≥ 1):
```
{ killSeed,kills,..., 0,
  bondSeed,flag,..., 0,
  trnSeed,variant,..., 0,
  recSeed,dwBuff,state,..., 0,
  rosterCount, id,seed,capDiff,isMinion,parentId,bMin,bMax,bToHit,bAC,bMaxHp,...,
  scrollCounter, ohId,
  originCount, (seed,ohId,packedName)...,
  gmCount, seed...,
  alCount, (seed,areaLvl)... }
```
The kill/bonded/TRN sections stay in lockstep (a Bonded seed has both an immunity and a TRN variant). The
recovery section is (seed, dwBuff, state) triples; its `state` field may be 0, so its loop is guarded on the
never-zero seed slot rather than on the value (state code: 0 = "lost", 1 = "injured", 2 = "lostfull"). The
deployed-ally roster (after a terminating 0) is count-prefixed and single-player only — used to re-link allies
to their reloaded golems on a mid-dungeon Load Game (see `relinkSavedAllies`); each record carries the stable
monster slot id (re-link key) + the data to rebuild its tracking entry (seed, capturedDifficulty, isMinion,
parentId, un-buffed base stats so the buff is recomputed on load, never doubled); skipped in multiplayer (slot
ids aren't comparable across clients/sessions, and MP deployed allies persist via the network delta — MP
re-link is deferred to net sync). A trailing `scrollCounter` keeps seeds unique across sessions; the permanent
per-character OHID follows. The Original-Trainer provenance section (count, then seed/ohId/byte-packed-name per
entry) is appended after the fixed sections because it is variable length, so a traded-in scroll keeps showing
the ORIGINAL Hunter after a reload (the item save format can't hold the name string). Then the tamed-in
gamemode section (count, then bare seeds — only Hellfire=1 entries; a missing seed reads back 0=Diablo) and
the tamed-in area-level section (count, then seed,areaLvl pairs — any non-zero level; a missing seed reads back
0=Unknown). On load, `OnSavePlayerData` returning nothing for a non-Hunter leaves the save's mod-data vector
empty, so the engine writes no out-of-band entry and the save stays byte-identical to a non-modded one;
`OnLoadPlayerData` clears the last character's OHID first so a save missing the field can't leak it to the one
loading now.

## Visual polish + item pickup/trade

### `allyDisplayName` / `OnGetMonsterDisplayName`
Displayed name for deployed allies (info box + health bar use the same hook). Tamed/Bonded ally → "Tamed
[Name]" / "Bonded [Name]" (prefix); minion → "[Name] Minion" (suffix — minions are raised by a tamed ally, not
tamed directly). Our OWN allies derive this live from their seed data. ANOTHER Hunter's allies show the same
tamed identity to EVERY observer (friendly AND hostile) so the name always reads as the tamed monster it is —
sourced from the owner's broadcast record (`remoteAllies`: parentId marks a minion, the CO profile carries
bonded). Hostility changes only the outline colour and whether the QoL floating stat infobox is offered to a
friendly observer — never the name. `allyDisplayName` composes the name to match the scroll-name convention: a
normal ally is "Tamed/Bonded Lvl N [Name]"; a unique (champion/boss) ally carries NO "Lvl N" (its level lives
in the scroll's dwBuff, not the name); prefix already includes its trailing space.

### `OnGetMonsterOutlineColor` (`ALLY_OUTLINE_COLOR` etc.)
Rendered from the local client's perspective (the observer is always MyPlayer). A monster at 0 HP (dead or
mid-death-animation) never shows a selection outline — prevents the brief ally outline flash an ally/minion
shows on the frame it dies, before its death animation/corpse placement. Our own allies/minions: always gold
(`ALLY_OUTLINE_COLOR`), white when hovered (`ALLY_OUTLINE_COLOR_HOVERED`), regardless of hostility — a Hunter
must always be able to pick out their own pets. Another Hunter's ally: blue (`OTHER_HUNTER_OUTLINE_COLOR`), but
only while BOTH we and the owner are friendly; if either side is hostile, return nil so the engine's default
enemy outline applies (the ally becomes a normal red-on-hover, attackable target, with a normal infobox).

### `OnGetMonsterTRN` (Bonded recolour + pre-Bonded flash)
Bonded recolour + pre-Bonded flash, both via the per-frame monster TRN override. A Bonded deployed ally wears
the permanent recolour matching its rolled bonus (its "aura"; the glow light is the other half of that aura) —
always on, `bondedTrn[seed]` selects which one. A Tamed ally one kill from Bonded blinks the solid flash colour
on the `FLASH_*` cadence (the "about to evolve" tell), which stops once it crosses the threshold and becomes
recoloured instead. Every other monster (and a non-flashing pre-Bonded ally in its off-window) returns nil →
the engine's default TRN, so this never touches non-allies (O(1) ally lookup, like the outline handler). A
remote-owned ally's kill-derived Bonded state isn't visible on a peer, so the same tint is driven from the
owner's broadcast CO profile (`flashOn` is frame-driven locally on every client in `GameDrawComplete`).

### `OnLevelEnter` (gold-tier fixup)
Fix up unique tame scroll quality on level enter so floor-dropped scrolls that were picked up in the previous
session get their gold text on the next level load. Defensive: keep `scrollCounter` ahead of every held
scroll's counter so a freshly allocated seed can never collide with one already in inventory (`scrollCounter`
is persisted and monotonic, so for a character's own scrolls this is a no-op; it still guards a scroll acquired
from another character whose counter ran ahead, until re-stamp-on-acquire makes that case impossible too). Also
announces the full identity blob of every scroll we're carrying, so peers (incl. a late joiner) already have it
cached if we trade one away (held scrolls → no delta level; no-op in SP).

### `OnPlayerCanPickUpItem` / `OnVendorWillBuyItem`
`OnPlayerCanPickUpItem`: only Hunters may pick up (and therefore hold) Tame Scrolls — blocks non-Hunters from
grabbing them off the floor; Hunters can still trade scrolls to one another via the normal drop/pickup flow
(both parties are Hunters, so neither side is blocked). `OnVendorWillBuyItem`: Tame Scrolls are never sellable
to a vendor — they are only obtained by taming or bought back from Pepin's recovery list; veto the vendor's
buy-from-player check (covers Adria/Griswold, both store UIs).

### `OnItemPickedUp` (re-stamp on pickup)
Re-stamp every picked-up Tame Scroll into THIS character's own monotonic seed space, so two players' scrolls
can never share a seed (collision-proof trading). The scroll is self-describing: its progression
(kills/immunity/TRN) rides in `modData`, so re-keying is lossless — the picked-up ally keeps its full identity
under the fresh seed. For the owner's OWN dropped-and-repicked scroll this is observationally a no-op (same
monster, same data, new seed under the hood). Also (re)applies the gold quality the moment the scroll enters
inventory. Local player only: `AutoGetItem` runs for remote players too (on every client), and re-stamping must
mutate only OUR own inventory item, never a remote player's. Locates the LIVE copy of the scroll we just picked
up by matching on seed + dwBuff + modData rather than seed alone: if the incoming seed momentarily collides
with a scroll we already hold (two characters' counters can both be low), this re-stamps the one we just
acquired, never the existing one. Sources the scroll's full self-describing identity by explicit
first-non-empty precedence: the item's own blob (set by the dropper's local spawn or restored from the level
delta by `DeltaLoadItems`; empty only when the engine recreated the item from the item wire, which by design
carries no blob) → the level-delta blob (the authoritative at-rest copy) → the live SD cache (same content
for a floor item; also covers a scroll announced while held) → our own tables (re-picking up a scroll we
already owned). Every channel is written from live state at drop/announce time, so whichever is present is
current — no cross-channel freshness comparison. The Original Trainer rides INSIDE the blob, so
the true tamer carries with the scroll however it arrived; fall back to the seed-keyed cache only if the blob
had no name. Drops the old seed's tables only if no OTHER held scroll still uses it, so a transient seed
collision never deletes a different scroll's data; clears the floor item's blob from the current level's delta
to keep the per-level store bounded; and announces the scroll's identity under its fresh seed so peers can show
the true tamer / restore it on a later trade.

## Remaining handlers (net handlers, cast gates, share-potion cursor, ranged AI, info popup)

### SD / CO dispatcher handlers
**SD**: a peer announced a scroll's full mod-data blob keyed by seed (payload = `SD|level|seed|<blob bytes>`).
Cache the raw blob so a later live trade of that scroll restores everything on pickup, and cache its Original
Trainer for display. If the announcement is for a FLOOR item (`level >= 0`), mirror the blob into that level's
delta so this client can serve it to a late joiner even after the dropper leaves. The blob is the last field
and may contain "|"/NUL — captured verbatim, not split. **CO**: the owner of a remote ally sent its final
combat values + caster profile. Apply the values to the live monster (so our hostile combat / melee damage /
HP-threshold AI use the buffed numbers) and cache the profile for spell-damage resolution. Only for a remote
ally we track — never our own (we own the live values) — so guarded on `remoteAllies` membership. The 28 fixed
leading fields (tag + numbers, never contain "|") are pulled positionally, then everything after the 28th "|"
is taken as `ohName` (the 29th field) verbatim because a player name may contain "|".

### `reapOrphanedRemoteAllies`
Despawn any observed remote ally whose owner has left the game. `player.get` returns nil for an inactive
(disconnected) player, so a nil owner means that Hunter is gone and its allies/minions are orphaned. The
engine's departed-player golem reaper only reaps MT_GOLEM-type monsters, so it never clears our
arbitrary-species allies — without this they linger as idle ghosts on a peer still standing on the level. The
owner-match guard keeps it barometer-safe (never touches our own ally or a vanilla Golem). Called periodically
from `GameDrawComplete`.

### Share Potion cursor flow (`OnCanSelectMonsterWithCursor` / `OnCursorMonsterTarget`)
`OnCanSelectMonsterWithCursor` allows `pcursmonst` to be set while in CURSOR_HEALOTHER mode so the player can
click on a deployed ally. `OnCursorMonsterTarget` applies Share Potion to a clicked ally: returns true (dismiss
cursor) for any valid ally — including summoned minions — regardless of potion availability; returns nil
(cursor stays active) for invalid targets.

### Cast gates tail (`OnCanCastScroll` duplicate/tier checks, `OnCanCastSkill`)
`OnCanCastScroll` determines which scroll will actually be cast so the duplicate-unique block is reliable:
normally the selected speedbook entry; for hotkey / unknown-selection casts (`selectedSeed == 0`) it falls back
to the first Tame scroll in inventory — the same first-match the deploy path resolves to — instead of skipping
the check. It also applies a belt-and-suspenders tier gate: refuse deploying a scroll whose encoded monster is
outside the current tier criteria (backs up the inventory-red / speedbook-hide for any path that still reaches
a cast; not consumed on refusal). `OnCanCastSkill` blocks a Tame SKILL cast UPFRONT (before commit) when the
cursor-targeted monster fails the active tier's mlvl/category gate — the hard targeting veto, independent of
the target's HP; the Hunter refuses with the spoken "I can't do that"; the in-cast HP threshold still governs
whether a valid-category target is actually captured. It never gate-refuses a cast aimed at a golem/minion
(own ally = recall, others = no-op); that's decided from `isGolem` (not `deployedAllies`) only to AVOID a
refusal, so no Hunter behaviour is granted and the vanilla Golem barometer is unaffected.

### Ranged AI (`OnGolemChooseAction` ranged handler, `RANGED_*`, `AVOIDANCE_RANGED`, `KITE_MIN_DIST`, `golemTargetDistance`)
Give ranged allies a ranged attack at appropriate distance. Fires before GolumAi's melee-attack / chase block,
giving Lua first refusal; returning true consumes the tick (the engine skips melee/chase/idle for that ally);
non-ranged allies and the vanilla Golem return nil to let the engine run normally. `RANGED_MIN_DIST` = 3 (don't
fire if the enemy is 1–2 tiles away; let melee handle it); `RANGED_MAX_DIST` = 8. `AVOIDANCE_RANGED` are the
avoidance casters vanilla kites with (`AiRangedAvoidance`: Magma/Storm/Acid/Diablo/BoneDemon); a tamed one
backs away from a closing enemy toward the owner, which keeps it within leash range (`ENGAGE_RADIUS`).
`KITE_MIN_DIST` = 3: an avoidance caster whose enemy has closed inside it steps back toward the owner (raising
distance from the enemy while staying near the player) instead of standing and firing in melee range.
`golemTargetDistance` derives the Chebyshev distance from the ally's current target monster (the C++ call-out
forwards the target or nil, not a precomputed distance/LOS).

### `OnItemDropped`
A manually dropped Tame Scroll — the trade mechanism (drop on the floor, another Hunter picks it up). The floor
item carries no blob over the wire, so persist the scroll's identity with the floor item in the level delta +
announce it live, so the picker (present now, or a late joiner after we leave) restores it. `dropTameScroll` /
the refund path already do this inline; this catches a player dragging a scroll out by hand. Local Hunter only
(the hook fires for the local dropper).

### `OnPrepareUniqueInfoBox`
Hijack the unique item info popup when hovering a gold-tier tame scroll. Populates the custom slot with tamed
monster stats and returns true so `DrawUniqueInfo` renders our content instead of `UniqueItems[_iUid]` (which
would show The Butcher's Cleaver). Fires for any scroll rendered at unique/gold tier: seed-unique
champions/bosses AND Bonded normal-monster scrolls; a non-unique, non-Bonded scroll is not gold, so it falls
through to the engine's default item box.

### Floating-box draw helpers (`fboxDrawRow` / `fboxStatRow` / the `rows` layout)
`fboxDrawRow` draws a row as left-to-right colour segments (`{text, flags}`), advancing x by each measured
width. A stat row is "Label  base / buffed" with the buffed value turned blue when it differs from base. Buffed
values come live off the monster. Row order (top→bottom): base/buffed stat rows, then the GOLD provenance block
— Found, Type, OH/ID, Version (Version last, OH/ID directly above it, Type above OH/ID). "Found" reads
"Area Lvl N / Difficulty" (`areaLevelName` + captured difficulty); the gamemode is its own Version line.
