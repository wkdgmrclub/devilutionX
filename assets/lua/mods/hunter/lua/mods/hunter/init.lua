local events   = require("devilutionx.events")
local spells   = require("devilutionx.spells")
local player   = require("devilutionx.player")
local monsters = require("devilutionx.monsters")
local items    = require("devilutionx.items")
local audio    = require("devilutionx.audio")
local message  = require("devilutionx.message")
local system   = require("devilutionx.system")
local render   = require("devilutionx.render")

-- ============================================================================
-- Hunter mod — init.lua. Extended design notes, rationale, mechanics detail and
-- invariants live in comments.md (next to this file), keyed by symbol/function name.
-- Convention: nearly every top-level declaration here is an intentional sandbox
-- global, not `local` — Lua caps a chunk at 200 active locals/upvalues and this file
-- is large. `local` is reserved for the inter-mod surface only (module requires, the
-- luanet bridge, and the net-layer NET tag table + broadcast*/credit forward-decls).
-- ============================================================================

-- Soft bridge to the LuaNet multiplexer via the shared events.luanet table: no hard require, no
-- load-order dependency, and a silent no-op when the LuaNet mpq isn't enabled.
local luanet
do
  local pending = {} -- channel -> handler, applied once LuaNet becomes available
  local function apply(ch, h)
    local ln = events.luanet
    if ln == nil then return false end
    ln.register(ch, h)
    return true
  end
  luanet = {
    send = function(channel, payload, mask)
      local ln = events.luanet
      if ln ~= nil then ln.send(channel, payload, mask) end
    end,
    register = function(channel, handler)
      if not apply(channel, handler) then pending[channel] = handler end
    end,
  }
  -- GameStart fires after every mod loads; flush registrations LuaNet wasn't available for yet.
  if events.GameStart ~= nil then
    events.GameStart.add(function()
      for ch, h in pairs(pending) do apply(ch, h) end
    end)
  end
end

-- Ally bookkeeping caps.
MAX_HUNTERS             = 4
MAX_DEPLOYED_PER_HUNTER = 4
SKELKING_MAX_MINIONS    = 3                                           -- cap of simultaneous skeleton minions per tamed Skeleton King
HORK_MAX_MINIONS        = 3                                           -- cap of simultaneous Hork minions per tamed Hork Demon
-- Reserve extra per-level monster-TYPE + live-monster slots for a full party's worst case: every hunter fields a full deploy including a Skeleton King AND a Hork Demon at full minions = 4 * (4+3+3) = 40 slots, inside the extended region (AbsoluteMaxMonsters 252 - natural 200 = 52).
monsters.requestExtraTypes(MAX_HUNTERS * MAX_DEPLOYED_PER_HUNTER + 2) -- +2: skeleton + hork-spawn minion species, shared across hunters
monsters.requestExtraMonsters(MAX_HUNTERS * (MAX_DEPLOYED_PER_HUNTER + SKELKING_MAX_MINIONS + HORK_MAX_MINIONS))

-- Queued in SpellDataLoaded, resolved in SpellsAssigned (see spells.registerSpell below).
TAME_ID              = nil
SHARE_POTION_ID      = nil
FORGET_POTION_ID     = nil
TAME_SCROLL_MAP      = 90001   -- mapping ID for Tame Scroll base item; no clash with base items
FORGET_POTION_MAP    = 90002   -- mapping ID for Potion of Forgetting
FORGET_POTION_PRICE  = 1000000 -- gold cost in Pepin's shop
-- Session-only Potion of Forgetting: per-write {ref=liveSlot, saved=poppedCopy} records.
forgetPotionSnapshot = nil

-- Session cache: tameScrollData[seed] = { typeId, savedHp, maxHp, name, level }.
tameScrollData       = {}

-- List of { monster, seed } for all currently deployed allies.
deployedAllies       = {}

-- Parallel monsterId -> entry index for O(1) membership; mutate only via trackDeployedAlly/untrackDeployedAt.
deployedAlliesById   = {}

-- Plane-1 runtime registry of allies owned by ANOTHER client, recreated from a net SP message.
remoteAllies         = {}

-- Local delta level cached at level entry (OnLevelExit RM broadcasts need the departing level; plrlevel is already the destination by then).
myDeltaLevel         = 0

-- Plane-2 runtime: seed -> ally `data` for a deploy we requested from the level owner.
pendingDeploys       = {}

-- Saved deployed-ally roster awaiting re-link on the next level entry (nil when nothing to re-link).
pendingAllyRoster    = nil


-- Last-seen fingerprint of the Hunter's buff-relevant stats; polled to re-derive ally buffs on change.
lastBuffFingerprint = nil

-- monsterId -> true for a deployed ally that just died and must NOT leave a corpse.
corpselessDeaths = {}

-- allyKillCounts[seed] = integer kill count, keyed by seed so kills persist across redeploy cycles.
allyKillCounts = {}

function trackDeployedAlly(entry)
  entry.id = entry.monster.id -- capture the id once; survives the monster userdata going stale
  -- One slot id = one live monster: an existing entry under this id is STALE (its monster is gone and
  -- the engine reused the slot). Evict it from the array too, or deployedAllies holds two entries whose
  -- userdata read the SAME live monster — a later recall of the stale entry then builds a scroll from
  -- the WRONG ally's identity (seen in MP as a Skeleton King scroll named after another Bonded ally).
  local stale = deployedAlliesById[entry.id]
  if stale ~= nil then
    for i = #deployedAllies, 1, -1 do
      if deployedAllies[i] == stale then table.remove(deployedAllies, i) end
    end
  end
  table.insert(deployedAllies, entry)
  deployedAlliesById[entry.id] = entry
end

function untrackDeployedAt(i)
  local entry = table.remove(deployedAllies, i)
  if entry ~= nil then deployedAlliesById[entry.id] = nil end
end

function getDeployedAllyEntry(monsterId)
  return deployedAlliesById[monsterId]
end

function isDeployedAlly(monsterId)
  return getDeployedAllyEntry(monsterId) ~= nil
end

-- True for ANY tamed ally/minion this client knows about (own deployed OR remote-owned); the per-tick AI hooks gate on this.
function isTamedAlly(monsterId)
  return deployedAlliesById[monsterId] ~= nil or remoteAllies[monsterId] ~= nil
end

-- The Player that owns this ally (resolved from monster.ownerPlayerId); works for own + remote allies. nil if none.
function allyOwner(monster)
  return player.get(monster.ownerPlayerId)
end

-- Per-ally record the shared AI hooks read identity/combat state from (own = deployedAllies entry, remote = remoteAllies record).
function allyScratch(monsterId)
  return deployedAlliesById[monsterId] or remoteAllies[monsterId]
end

-- True when players a and b are both in friendly (non-hostile) mode. nil-safe.
function arePeaceful(a, b)
  return a ~= nil and b ~= nil and a.friendlyMode and b.friendlyMode
end

-- Should the local observer see the rich Tamed-pet info readout for this monster?
function isFriendlyTamedView(monster)
  if monster == nil then return false end
  if isDeployedAlly(monster.id) then return true end       -- our own ally/minion
  if remoteAllies[monster.id] == nil then return false end -- not a tamed pet we track
  return arePeaceful(player.self(), player.get(monster.ownerPlayerId))
end

function countDeployedAllies()
  local n = 0
  for _, entry in ipairs(deployedAllies) do
    if not entry.isMinion then n = n + 1 end
  end
  return n
end

-- Deploy requests still awaiting their SP/DF echo (non-owner DR round trip). The deploy GATES must count
-- these as deployed: during the round-trip window the ally isn't in deployedAllies yet, so rapid casting
-- would sail past the cap / duplicate-unique checks. NOT counted by the buff share (countDeployedAllies).
function countPendingDeploys()
  local n = 0
  for _ in pairs(pendingDeploys) do n = n + 1 end
  return n
end

-- Per-character monotonic counter for Tame Scroll seeds; persisted and never reset.
scrollCounter = 1

-- Class name constant used for MP-safe class guards.
HUNTER_CLASS = "Hunter"

-- Original-Hunter ID (OHID): permanent per-character 9-digit "trainer ID", generated once and persisted.
myOhId = nil

-- Deterministic, overflow-safe string hash (polynomial mod 1e9).
function hashString(s)
  local h = 0
  for i = 1, #s do
    h = (h * 31 + s:byte(i)) % 1000000000
  end
  return h
end

-- Generate a fresh 9-digit OHID from the character name + creation timestamp (os.time).
function generateOhId(name)
  return (hashString(name or "") + (os.time() % 1000000000)) % 1000000000
end

-- The local Hunter's OHID, lazily generating+caching one if absent.
function getMyOhId()
  if myOhId == nil then
    local me = player.self()
    myOhId = generateOhId(me ~= nil and me.name or "")
  end
  return myOhId
end

-- Format an OHID as a zero-padded 9-digit string for display (e.g. 042819375).
function formatOhId(id)
  return string.format("%09d", id or 0)
end

-- Scroll "Original Trainer" provenance: seed -> { name, id }. Captured at Tame time, kept with the monster.
scrollOrigin = {}

-- Scroll mod-data blobs heard over the LuaNet "SD" message, keyed by seed, for restoring identity on trade.
receivedBlobs = {}

-- Forward decl: announces a scroll's full identity blob to peers keyed by seed (no-op in SP). Assigned in net section.
local broadcastScrollData

-- The origin to display for a scroll/pet seed: recorded Original Trainer, else the local Hunter. nil if no local player.
function originForSeed(seed)
  local o = scrollOrigin[seed]
  if o ~= nil then return o end
  local me = player.self()
  if me == nil then return nil end
  return { name = me.name, id = getMyOhId() }
end

-- Byte-pack a string into the uint32 luamoddata save sequence: a length word + ceil(len/4) LE data words.
function packStringToWords(t, s)
  s = s or ""
  local len = #s
  t[#t + 1] = len
  local i = 1
  while i <= len do
    local w = 0
    for j = 0, 3 do
      local b = (i + j <= len) and s:byte(i + j) or 0
      -- Integer ops on purpose: `2^n` arithmetic yields FLOAT-typed words, which fail the engine
      -- save reader's integer conversion (SOL_SAFE_NUMERICS) and silently truncate the whole blob
      -- from the first name onward — the root of the "Found: Unknown"/blank-OH class.
      w = w | (b << (8 * j))
    end
    t[#t + 1] = w
    i = i + 4
  end
end

function unpackStringFromWords(data, idx)
  local len = data[idx] or 0
  idx = idx + 1
  local bytes = {}
  local nwords = math.floor((len + 3) / 4)
  local pos = 1
  for _ = 1, nwords do
    local w = data[idx] or 0
    idx = idx + 1
    for j = 0, 3 do
      if pos <= len then
        bytes[pos] = string.char(math.floor(w / (2 ^ (8 * j))) % 256)
        pos = pos + 1
      end
    end
  end
  return table.concat(bytes), idx
end

-- Is this monster a tamed ally/minion belonging to *another* Hunter? Detected from engine state alone (golem flag + owner class).
function isOtherHuntersAlly(monster)
  if not monster.isGolem then return false end
  local me = player.self()
  if me == nil then return false end
  local ownerId = monster.ownerPlayerId
  if ownerId == me.id then return false end
  local owner = player.get(ownerId)
  return owner ~= nil and owner.className == HUNTER_CLASS
end

-- Is `monster` an ally `attacker` must never attack (own ally, or another Hunter's pet at peace)? nil-safe.
function isProtectedFromOffense(attacker, monster)
  if monster == nil then return false end
  for _, entry in ipairs(deployedAllies) do
    if entry.monster == monster then return true end
  end
  if monster.isGolem then
    local owner = player.get(monster.ownerPlayerId)
    if owner ~= nil and owner.id ~= attacker.id
        and owner.className == HUNTER_CLASS and arePeaceful(attacker, owner) then
      return true
    end
  end
  return false
end

-- Named quest bosses: require Tame++ (level 45, ≤10% HP); regular uniques only need Tame+ (level 30, ≤20% HP).
BOSS_NAMES       = {
  ["Arch-Bishop Lazarus"] = true,
  ["Zhar the Mad"]        = true,
  ["Sir Gorash"]          = true,
  ["Warlord of Blood"]    = true,
  ["Blackjade"]           = true,
  ["Red Vex"]             = true,
  ["Gharbad the Weak"]    = true,
  ["Snotspill"]           = true,
  ["The Butcher"]         = true,
  ["Skeleton King"]       = true,
  -- Hellfire
  ["Hork Demon"]          = true,
  ["The Defiler"]         = true,
  ["Na-Krul"]             = true,
}

-- Starter pet: typeId 16 = MT_NSCAV (Scavenger); HP from monstdat.tsv (Normal difficulty).
STARTER_TYPE_ID  = 16
STARTER_LEVEL    = 2
STARTER_MAX_HP   = 6
STARTER_NAME     = "Scavenger"

UNIQUE_SEED_FLAG = 0x800 -- bit 11 of the 12-bit type field marks a unique-monster scroll

-- Seed layout (31 bits, signed-int32 safe): [7-bit charTag][12-bit counter][12-bit type field].
-- charTag = OHID % 128 keeps seeds globally unique across characters in MP. Without it, two Hunters
-- mint identical seeds (every starter scroll is counter 1 + MT_NSCAV) and one player's SD broadcast
-- poisons the other's seed-keyed caches (scrollOrigin/receivedBlobs/item delta) — see bugs.md.
function allocSeed(typeId, uniqueTypeIdx)
  local counter = scrollCounter -- monotonic, never reused (see scrollCounter)
  scrollCounter = scrollCounter + 1
  local upper = (getMyOhId() % 128) * 4096 + counter
  if uniqueTypeIdx ~= nil and uniqueTypeIdx >= 0 then
    return upper * 4096 + UNIQUE_SEED_FLAG + uniqueTypeIdx
  end
  return upper * 4096 + (typeId % 2048)
end

-- Returns typeId for normal scrolls, or nil for unique scrolls.
function seedToTypeId(seed)
  local lower = seed % 4096
  if lower >= UNIQUE_SEED_FLAG then return nil end
  return lower
end

-- Returns uniqueTypeIdx (>=0) if this is a unique scroll, else -1.
function seedGetUniqueType(seed)
  local lower = seed % 4096
  if lower >= UNIQUE_SEED_FLAG then return lower - UNIQUE_SEED_FLAG end
  return -1
end

-- Diablo is the one quest monster that is NOT unique, so his scrolls travel the normal typeId seed
-- path; every Diablo special case keys off the seed's stored type, never a unique index.
DIABLO_TYPE_ID = 110 -- MT_DIABLO (Source/tables/monstdat.h)
function seedIsDiablo(seed)
  return seedToTypeId(seed) == DIABLO_TYPE_ID
end

-- PRESENTATION-only helper: true for any scroll that should get the unique-scroll treatment (no "Lvl N",
-- unique infobox, gold tier) — a real unique index OR Diablo. Do NOT use this where a real unique index is
-- required (getUniqueName, spawnUniqueAt, unique dedup) — those stay uIdx >= 0, since Diablo deploys by
-- typeId and dedups via isDiabloDeployed().
function scrollPresentsAsUnique(seed)
  return seedGetUniqueType(seed) >= 0 or seedIsDiablo(seed)
end

-- Defined after seedGetUniqueType on purpose (avoids a nil-global forward-reference bug).
-- One instance of a unique PER HUNTER (regardless of Tamed/Bonded status or difficulty): scan only OUR
-- OWN deployed allies — another Hunter fielding its own copy of the same unique is allowed.
-- Minion entries have seed = nil — they can never be unique, and seedGetUniqueType(nil) is an
-- arithmetic ERROR that would silently kill the calling hook (the scroll-consumed-into-the-void bug).
function isUniqueTypeDeployed(uniqueTypeIdx)
  for _, entry in ipairs(deployedAllies) do
    if entry.seed ~= nil and seedGetUniqueType(entry.seed) == uniqueTypeIdx then return true end
  end
  -- A deploy request in flight (DR sent, SP/DF echo pending) counts too — its scroll is already committed.
  for seed in pairs(pendingDeploys) do
    if seedGetUniqueType(seed) == uniqueTypeIdx then return true end
  end
  return false
end

-- One Diablo per Hunter, mirroring the one-unique rule: Diablo isn't unique (typeId-keyed scroll),
-- so the dedup scan keys off the seed type instead of a unique index. Same OWN-allies scope.
function isDiabloDeployed()
  for _, entry in ipairs(deployedAllies) do
    if entry.seed ~= nil and seedIsDiablo(entry.seed) then return true end
  end
  for seed in pairs(pendingDeploys) do
    if seedIsDiablo(seed) then return true end
  end
  return false
end

-- dwBuff encoding layout (unsigned, bit 0 = CF_HELLFIRE = 0):
--   Bits  1-15 : maxHp display value (0..32767, full resolution)
--   Bits 16-21 : monster level (0..63)
--   Bits 22-23 : capturedDifficulty (0=Normal 1=Nightmare 2=Hell)
--   Bits 24-31 : savedHp as a percent of maxHp (0..100); current HP = round(maxHp * pct / 100)
function encodeDwBuff(savedHp, maxHp, level, difficulty)
  local mhp = math.min(math.max(math.floor(maxHp), 0), 32767)
  local hp  = math.max(math.floor(savedHp), 0)
  local pct = 0
  if mhp > 0 and hp > 0 then
    pct = math.floor(hp / mhp * 100 + 0.5)
    if pct < 1 then pct = 1 end     -- a living ally must never round down to 0%
    if pct > 100 then pct = 100 end -- current HP is never above max
  end
  local lv  = math.min(math.max(math.floor(level), 0), 63)
  local dif = math.min(math.max(math.floor(difficulty or 0), 0), 3)
  -- bit shifts: maxHp<<1, level<<16, difficulty<<22, savedHp%<<24
  return mhp * 2 + lv * 65536 + dif * 4194304 + pct * 16777216
end

function decodeDwBuff(dwBuff)
  local maxHp      = math.floor(dwBuff / 2) % 32768      -- bits 1-15
  local level      = math.floor(dwBuff / 65536) % 64     -- bits 16-21
  local difficulty = math.floor(dwBuff / 4194304) % 4    -- bits 22-23
  local pct        = math.floor(dwBuff / 16777216) % 256 -- bits 24-31 (0..100)
  local savedHp    = math.floor(maxHp * pct / 100 + 0.5)
  if pct > 0 and savedHp < 1 then savedHp = 1 end
  return savedHp, maxHp, level, difficulty
end

-- Recovery registry: backup ledger of deployed allies, rebuildable from seed+dwBuff. recoveryRegistry[seed] = { dwBuff, state="lost"|"injured", order }.
recoveryRegistry = {}
RECOVERY_CAP = MAX_DEPLOYED_PER_HUNTER -- mirror the deploy cap; evict oldest past this
RECOVERY_INJURED_COST_PER_LEVEL = 100

-- Monotonic insertion order, used only to pick the oldest entry to evict at the cap.
recoveryOrderCounter = 0
function nextRecoveryOrder()
  recoveryOrderCounter = recoveryOrderCounter + 1
  return recoveryOrderCounter
end

-- Allies whose final death frame should spawn the Resurrect beam FX (set in OnMonsterDeath, consumed in OnMonsterCanPlaceCorpse).
pendingResurrectBeam = {}

function recoveryDwBuffFromData(data)
  return encodeDwBuff(data.savedHp, data.maxHp, data.level or 0, data.capturedDifficulty or 0)
end

-- Insert or update a registry entry, enforcing the cap by evicting the oldest entry first.
function putRecovery(seed, dwBuff, state)
  local existing = recoveryRegistry[seed]
  if existing ~= nil then
    existing.dwBuff = dwBuff
    existing.state  = state
    return
  end
  local count = 0
  for _ in pairs(recoveryRegistry) do count = count + 1 end
  if count >= RECOVERY_CAP then
    local oldestSeed, oldestOrder = nil, math.huge
    for s, r in pairs(recoveryRegistry) do
      if r.order < oldestOrder then oldestOrder, oldestSeed = r.order, s end
    end
    if oldestSeed ~= nil then recoveryRegistry[oldestSeed] = nil end
  end
  recoveryRegistry[seed] = { dwBuff = dwBuff, state = state, order = nextRecoveryOrder() }
end

-- Ally Progression: Tamed -> Bonded promotion + CLVL-scaled stat buffs.

-- Resistance bitflags exposed by the engine (monsters.Resistance.*).
RES                      = monsters.Resistance
BONDED_IMMUNE_OPTIONS    = { RES.ImmuneFire, RES.ImmuneMagic, RES.ImmuneLightning }
-- Each immunity supersedes (drops) the same-element resistance, matching vanilla's UI pattern.
BONDED_IMMUNE_SUPERSEDES = {
  [RES.ImmuneFire]      = RES.ResistFire,
  [RES.ImmuneMagic]     = RES.ResistMagic,
  [RES.ImmuneLightning] = RES.ResistLightning,
}
-- Sentinel stored in bondedImmunity for the "already has all three immunities -> +200 AC" fallback.
BONDED_AC                = 4096
BONDED_AC_BONUS          = 200
BONDED_KILLS_PER_LEVEL   = 100

-- Kill-scaled ToHit bonus: +1% per KILL_TOHIT_PER kills, hard-capped at KILL_TOHIT_CAP%.
KILL_TOHIT_PER           = 10
KILL_TOHIT_CAP           = 500

-- Pre-Bonded "about to evolve" flash: a Tamed ally one kill short of Bonded flashes via a solid-colour TRN.
BONDED_FLASH_COLOR       = 0xB0 -- palette index drawn while flashing (global range 128-255 = cross-palette safe)
FLASH_PERIOD_TICKS       = 28 -- how often a blink starts (game ticks, 20/s — synced clock, so peers blink in phase)
FLASH_ON_TICKS           = 7 -- how long the solid peak holds each blink
function buildSolidTrn(colorIndex)
  local t = {}
  for i = 1, 256 do t[i] = colorIndex end
  return t
end

-- Registered once at load; the handle is returned from OnGetMonsterTRN while a flash is "on".
BONDED_FLASH_TRN    = monsters.registerTrn(buildSolidTrn(BONDED_FLASH_COLOR))

-- Bonded "aura" glow: a permanent light source on a Bonded ally (the engine 'lighted'-unique mechanic).
BONDED_LIGHT_RADIUS = 3
function applyBondedGlow(entry)
  if entry.monster ~= nil then entry.monster:setLightRadius(BONDED_LIGHT_RADIUS) end
end

-- Bonded recolour TRNs (one per defensive bonus): a Bonded ally's permanent tint reads its rolled bonus
-- at a glance, via the SCATTER recolour model (only the cross-palette-safe global range 128-255).
GLOBAL_RAMPS = {
  { 128, 8 }, { 136, 8 }, { 144, 8 }, { 152, 8 },
  { 160, 16 }, { 176, 16 }, { 192, 16 }, { 208, 16 }, { 224, 16 }, { 240, 16 },
}
-- Brightness rank (0..15) of a global-range index from its offset within its own ramp (dark -> bright).
function brightnessRank(i)
  for _, r in ipairs(GLOBAL_RAMPS) do
    local base, size = r[1], r[2]
    if i >= base and i < base + size then
      local off = i - base
      if size == 16 then return off end
      return math.floor(off * 15 / (size - 1) + 0.5)
    end
  end
  return 0
end

-- Bake a 256-entry TRN by cycling `pattern` across brightness ranks (numeric slot = repaint, false = keep pixel).
function buildScatterTrn(pattern)
  local n = #pattern
  local t = {}
  for i = 0, 255 do
    local target = i -- default / level-specific 0-127: keep the monster's own pixel
    if i >= 128 then
      local slot = pattern[(brightnessRank(i) % n) + 1]
      if slot then target = slot end
    end
    t[i + 1] = target
  end
  return t
end

-- Registered TRN handles, indexed by variant (1..5).
BONDED_TRN_TABLE       = {
  monsters.registerTrn(buildScatterTrn { 230, 205, false }), -- 1 Fire:      bright red   + bright yellow
  monsters.registerTrn(buildScatterTrn { 186, 254, false }), -- 2 Lightning: bright blue  + white
  monsters.registerTrn(buildScatterTrn { 255, 252, false }), -- 3 Magic:     brightest white + light grey (all-bright white speckle; AC's identity is its near-black component)
  monsters.registerTrn(buildScatterTrn { 240, 253, false }), -- 4 +200 AC:   near-black grey + bright grey
  monsters.registerTrn(buildScatterTrn { 203, 255, false }), -- 5 Gilded:    gold         + white-gold
}
-- Map a rolled bonus to its default variant; Gilded (5) is the Hell-only override (see rollBondedTrn).
BONDED_TRN_GILDED      = 5
BONDED_TRN_BY_IMMUNITY = {
  [RES.ImmuneFire]      = 1,
  [RES.ImmuneLightning] = 2,
  [RES.ImmuneMagic]     = 3,
  [BONDED_AC]           = 4,
}
-- A Hell-tamed ally has HELL_GILD_CHANCE% to wear the rare Gilded Metal recolour. bondedTrn[seed] = rolled variant, saved.
HELL_DIFFICULTY        = 2
HELL_GILD_CHANCE       = 15
bondedTrn              = {}
-- scrollGamemode[seed] = 0 (Diablo) | 1 (Hellfire): gamemode the scroll was first tamed in; captured once, saved.
scrollGamemode         = {}
-- scrollAreaLevel[seed] = dungeon level the scroll was first tamed in; mapped to an area name for the "Found:" field.
scrollAreaLevel        = {}
-- Pre-Bonded flash phase, derived from the synced tick clock once per GameTick (read per-frame by OnGetMonsterTRN).
flashOn                = false

-- Spellcaster allies scale cast damage off the Hunter's matching resistance; maps DamageType -> resistance key.
SPELL_ELEMENT_OF       = {
  [monsters.DamageType.Fire]      = "fire",
  [monsters.DamageType.Lightning] = "lightning",
  [monsters.DamageType.Magic]     = "magic",
  [monsters.DamageType.Acid]      = "magic",
}
-- The local Hunter's UNCAPPED resistances (may exceed the 75% display cap), refreshed from OnCalcPlayerResistances.
hunterResist           = { fire = 0, lightning = 0, magic = 0 }

-- Cache the local Hunter's uncapped resistances for spellcaster damage scaling.
events.OnCalcPlayerResistances.add(function(p, fire, lightning, magic)
  local me = player.self()
  if me == nil or p == nil or p.id ~= me.id then return end
  hunterResist.fire      = fire
  hunterResist.lightning = lightning
  hunterResist.magic     = magic
end)

-- bondedImmunity[seed] = granted IMMUNE_* flag, or BONDED_AC for the +200 AC fallback. Rolled once, then saved.
bondedImmunity = {}

-- Portable scroll payload (item.modData blob): packs a scroll's whole identity so it survives trade/re-stamp.
-- Compact mappings between the bondedImmunity flag value and its index.
IMMUNITY_BY_INDEX = { [1] = RES.ImmuneFire, [2] = RES.ImmuneMagic, [3] = RES.ImmuneLightning, [4] = BONDED_AC }
IMMUNITY_TO_INDEX = {}
for idx, val in pairs(IMMUNITY_BY_INDEX) do IMMUNITY_TO_INDEX[val] = idx end

SCROLL_BLOB_FMT = "I2 B B B B I4 s1" -- kills, immIdx, trnVar, gamemode, areaLvl, ohId, ohName

function encodeBlob(kills, immIdx, trnVar, gamemode, areaLvl, ohId, ohName)
  return string.pack(SCROLL_BLOB_FMT,
    math.min(math.max(math.floor(kills or 0), 0), 65535),
    math.min(math.max(math.floor(immIdx or 0), 0), 7),
    math.min(math.max(math.floor(trnVar or 0), 0), 7),
    (gamemode == 1) and 1 or 0,
    math.min(math.max(math.floor(areaLvl or 0), 0), 255),
    math.floor(ohId or 0),
    tostring(ohName or ""))
end

function decodeBlob(blob)
  if blob == nil or blob == "" then return 0, 0, 0, 0, 0, 0, "" end
  local ok, kills, immIdx, trnVar, gamemode, areaLvl, ohId, ohName = pcall(string.unpack, SCROLL_BLOB_FMT, blob)
  if not ok then return 0, 0, 0, 0, 0, 0, "" end
  return kills, immIdx, trnVar, gamemode, areaLvl, ohId, ohName
end

-- Build the self-describing blob for a seed from its live/saved tables + recorded Original Trainer.
function blobForSeed(seed)
  local o = originForSeed(seed) or {}
  return encodeBlob(
    allyKillCounts[seed] or 0,
    IMMUNITY_TO_INDEX[bondedImmunity[seed]] or 0,
    bondedTrn[seed] or 0,
    scrollGamemode[seed] or 0,
    scrollAreaLevel[seed] or 0,
    o.id, o.name)
end

-- A Tamed ally becomes Bonded once kill count reaches mlvl * BONDED_KILLS_PER_LEVEL (derived live; no encoded field).
function isBonded(seed, mlvl)
  if seed == nil or mlvl == nil or mlvl <= 0 then return false end
  return (allyKillCounts[seed] or 0) >= mlvl * BONDED_KILLS_PER_LEVEL
end

-- True when a deployed ally needs exactly one more kill to cross the Bonded threshold (drives the pre-Bonded flash).
function isOneKillFromBonded(entry)
  if entry.isMinion then return false end
  local mlvl = entry.monster.level
  if mlvl <= 0 then return false end
  local needed = mlvl * BONDED_KILLS_PER_LEVEL
  local kills  = allyKillCounts[entry.seed] or 0
  return kills >= needed - 1 and kills < needed
end

-- Kills for a scroll ITEM, for presentation: our own tables when we hold the seed's identity (its
-- owner), else the scroll's announced identity blob — the item's own modData (a delta-restored floor
-- copy), the live SD cache, then the level-delta blob. Same source family as the pickup restore, so
-- a FOREIGN scroll (another Hunter's floor drop) presents its true kills before we ever own it.
function scrollKillsFor(item)
  local k = allyKillCounts[item.seed]
  if k ~= nil then return k end
  local blob = item.modData or ""
  if blob == "" then blob = receivedBlobs[item.seed] or "" end
  if blob == "" then blob = items.getItemDeltaModData(items.currentDeltaLevel(), item.seed) end
  if blob == "" then return 0 end
  local kills = decodeBlob(blob)
  return kills or 0
end

-- Bonded check for a scroll ITEM (no live monster): mlvl from the dwBuff-encoded level, kills via scrollKillsFor (own tables or the announced blob).
function scrollIsBonded(item)
  local _, _, level = decodeDwBuff(item.buff)
  if level == nil or level <= 0 then return false end
  return scrollKillsFor(item) >= level * BONDED_KILLS_PER_LEVEL
end

-- Base-vs-applied stat machinery: each ally's BASE (pre-buff) stats snapshot into entry.base; the live buff layers on top, recomputed in place and never baked into the persisted scroll.

function clampU8(v) return math.min(math.max(math.floor(v), 0), 255) end

-- Snapshot the freshly-spawned monster's stats as the buff baseline. Call AFTER makeGolem().
function snapshotAllyBase(entry)
  local m = entry.monster
  entry.base = {
    minDamage  = m.minDamage,
    maxDamage  = m.maxDamage,
    toHit      = m.toHit,
    armorClass = m.armorClass,
    maxHp      = m.maxHealth,
  }
end

-- Per-ally share WEIGHT (percent): the CLVL% pool split evenly across deployed allies, doubled for a Bonded ally.
function allySharePct(entry)
  local me = player.self()
  if me == nil or me.className ~= HUNTER_CLASS then return 0 end
  local count = countDeployedAllies()
  if count < 1 then count = 1 end -- guard: self may not be tracked yet at first-deploy recalc
  local bonded = isBonded(entry.seed, entry.monster.level)
  return (me.characterLevel / count) * (bonded and 2 or 1)
end

-- Live, share-divided, CLVL-scaled physical buff pool (HP / dmg / ToHit / AC) + an additive kill-scaled ToHit bonus. Governs MELEE; missile damage is scaled separately in OnGolemMissileDamage.
function computeAllyBuff(entry)
  local zero = { hp = 0, minDamage = 0, maxDamage = 0, toHit = 0, armorClass = 0 }
  if entry.isMinion then return zero end -- minions get a static spawn-time buff, not this live pool
  local me = player.self()
  if me == nil or me.className ~= HUNTER_CLASS then return zero end
  local clvl     = me.characterLevel
  local bonded   = isBonded(entry.seed, entry.monster.level)

  local sharePct = allySharePct(entry)
  local function share(stat) return math.ceil(stat * sharePct / 100) end

  -- Kill-scaled ToHit (additive, per-ally): +1% per KILL_TOHIT_PER kills, clamped to CLVL*10, doubled if Bonded, capped at KILL_TOHIT_CAP%.
  local raw       = math.floor((allyKillCounts[entry.seed] or 0) / KILL_TOHIT_PER)
  raw             = math.min(raw, clvl * 10)
  local killToHit = math.min(raw * (bonded and 2 or 1), KILL_TOHIT_CAP)

  return {
    hp         = share(me.maxHealth),
    minDamage  = share(me.minDamage),
    maxDamage  = share(me.maxDamage),
    toHit      = share(me.toHit) + killToHit,
    armorClass = share(me.armorClass),
  }
end

-- Re-derive and re-apply the live buff for one ally from its base + current inputs.
function applyAllyBuff(entry)
  if entry.isMinion then return end -- minions get a static spawn-time buff, not the live pool
  if entry.base == nil then return end
  local m = entry.monster
  local base = entry.base
  local buff = computeAllyBuff(entry)
  -- The Bonded +200 AC fallback is folded through the buff machinery so a later recalc doesn't wipe it.
  local acBonus = (bondedImmunity[entry.seed] == BONDED_AC) and BONDED_AC_BONUS or 0
  m:setMinDamage(clampU8(base.minDamage + buff.minDamage))
  m:setMaxDamage(clampU8(base.maxDamage + buff.maxDamage))
  m:setToHit(math.max(0, base.toHit + buff.toHit))
  m:setArmorClass(clampU8(base.armorClass + buff.armorClass + acBonus))
  -- HP buff RAISES maxHitPoints only (base.maxHp + live share, never accumulated); current is untouched except to clamp down when a shrinking share drops max below current.
  local newMax = base.maxHp + buff.hp
  m:setMaxHitPoints(newMax)
  if m.health > newMax then m:setHitPoints(newMax) end
end

-- Forward decl: CO (combat-override) broadcaster; assigned in the net section, called by recalcAllyBuffs.
local broadcastAllCombatOverrides

-- Forward decl: live-remove broadcaster; assigned in the net section, called by recall/minion-cleanup helpers.
local broadcastRemove

-- Forward decl: credits one OWN deployed ally with a kill (Bonded progression); assigned at OnGolemKilledMonster.
local creditAllyKill

-- Recompute the buff for every deployed ally; call whenever the deployed set or the Hunter's own stats change.
function recalcAllyBuffs()
  for _, entry in ipairs(deployedAllies) do
    applyAllyBuff(entry)
  end
  if broadcastAllCombatOverrides ~= nil then broadcastAllCombatOverrides() end
end

-- The caster/combat profile a missile-resolution hook needs to scale an ally's spell damage + apply Bonded immunity-piercing. Built live for our own ally; cached from the owner's CO broadcast for a peer's. Same fields either way.
function ownAllyProfile(entry)
  local me = player.self()
  if me == nil or me.className ~= HUNTER_CLASS then return nil end
  local minion = entry.isMinion or false
  -- The pet's Original Trainer (may be a DIFFERENT Hunter if received via trade); rides the CO message for peers.
  local origin = originForSeed(entry.seed) or { name = me.name, id = getMyOhId() }
  return {
    isMinion       = minion,
    bonded         = (not minion) and isBonded(entry.seed, entry.monster.level) or false,
    bondedImm      = bondedImmunity[entry.seed] or 0,
    baseMinDamage  = (entry.base and entry.base.minDamage) or 0,
    baseMaxDamage  = (entry.base and entry.base.maxDamage) or 0,
    baseToHit      = (entry.base and entry.base.toHit) or 0,
    baseArmorClass = (entry.base and entry.base.armorClass) or 0,
    baseMaxHp      = (entry.base and entry.base.maxHp) or 0,
    ohId           = origin.id or 0,
    ohName         = origin.name or "?",
    kills          = allyKillCounts[entry.seed] or 0,  -- lifetime kill count (info box; minions have no seed -> 0)
    gamemode       = scrollGamemode[entry.seed] or 0,  -- tamed-in gamemode (floating box "Version:")
    areaLevel      = scrollAreaLevel[entry.seed] or 0, -- tamed-in dungeon level (floating box "Found:")
    sharePct       = allySharePct(entry),
    magicCurrent   = me.magicCurrent,
    resFire        = hunterResist.fire,
    resLight       = hunterResist.lightning,
    resMagic       = hunterResist.magic,
    -- Cosmetic Plane-2 state a peer can't derive locally: Bonded recolour variant + pre-Bonded flash window.
    trnVariant     = bondedTrn[entry.seed] or 0,
    nearBonded     = isOneKillFromBonded(entry),
  }
end

-- The matching uncapped resistance for a spell element string (SPELL_ELEMENT_OF maps to these).
function profResForElement(prof, element)
  if element == "fire" then return prof.resFire end
  if element == "lightning" then return prof.resLight end
  return prof.resMagic -- "magic" (also acid, reclassified to magic)
end

-- The caster/combat profile for ANY tamed ally on this client (own = built live, remote = cached CO broadcast). nil for a non-ally.
function allyMissileProfile(monster)
  if monster == nil then return nil end
  local entry = getDeployedAllyEntry(monster.id)
  if entry ~= nil then return ownAllyProfile(entry) end
  local rec = remoteAllies[monster.id]
  if rec ~= nil then return rec.profile end
  return nil
end

-- Minions get a flat CLVL% physical buff baked ONCE at spawn (not share-divided, never recomputed). Call once, after snapshotAllyBase.
function applyMinionBuff(entry)
  if entry.base == nil then return end
  local me = player.self()
  if me == nil or me.className ~= HUNTER_CLASS then return end
  local pct = me.characterLevel
  local function buff(stat) return math.ceil(stat * pct / 100) end
  local m    = entry.monster
  local base = entry.base
  m:setMinDamage(clampU8(base.minDamage + buff(me.minDamage)))
  m:setMaxDamage(clampU8(base.maxDamage + buff(me.maxDamage)))
  m:setToHit(math.max(0, base.toHit + buff(me.toHit)))
  m:setArmorClass(clampU8(base.armorClass + buff(me.armorClass)))
  local hpBuff = buff(me.maxHealth)
  if hpBuff > 0 then
    -- Buff raises maxHitPoints only (base.maxHp + hpBuff); current untouched. Baked once.
    m:setMaxHitPoints(base.maxHp + hpBuff)
  end
end

-- Scale a deployed spellcaster ally's ELEMENTAL missile damage off the Hunter's Magic + matching resistance.
-- Formula: spell = (baseDam + sharePct% x CurrentMagic) x (1 + matchingRes%), rounded up. Fires per missile.
events.OnGolemMissileDamage.add(function(golem, missileId, dam)
  if golem == nil then return dam end
  -- A tamed Diablo's primary Apocalypse boom fans out to every other valid hostile in the envelope
  -- (see spreadDiabloApocalypse, defined by the ranged handler). OWNER-ONLY (isDeployedAlly, never a
  -- remote pet): the fan-out reads owner-local state, so the owner computes ONE boom set and
  -- replicates it to peers over AB — firing it per-client from each client's own view produced
  -- divergent boom sets (the spread-desync bug). The spread's own booms — local and AB-received —
  -- re-enter this handler and are guarded out by apocSpreadActive / the isDeployedAlly gate. Only a
  -- tamed Diablo ever fires this missile as a golem (a berserk'd wild Diablo's carrier booms are
  -- nobody's deployed ally → vanilla).
  if missileId == monsters.MissileID.DiabloApocalypseBoom and not apocSpreadActive and isDeployedAlly(golem.id) then
    spreadDiabloApocalypse(golem)
  end
  -- Single-writer fire replication (AT): an OWN ally's missile just spawned — broadcast it so peers
  -- render the same shot (their copies hold instead of self-firing; see the choose-action handlers).
  -- The choose-time stash is consumed on the FIRST spawn of the attack: a multi-part missile's later
  -- segments (e.g. Inferno) find no stash and are skipped — the peer's one AT-fired missile recreates
  -- the whole effect through the same engine processor. Spread booms ride AB, not AT (apocSpreadActive
  -- guard); a peer's AT/AB-fired missile re-enters here as a REMOTE ally and never re-broadcasts.
  if system.isMultiplayer() and not apocSpreadActive and isDeployedAlly(golem.id) then
    local scratch = allyScratch(golem.id)
    if scratch ~= nil and scratch.pendingFireX ~= nil then
      broadcastFireAction(golem.id, missileId, scratch.pendingFireX, scratch.pendingFireY)
      scratch.pendingFireX, scratch.pendingFireY = nil, nil
    end
  end
  local prof = allyMissileProfile(golem)
  if prof == nil or prof.isMinion then return dam end -- not our ally / minions: static buff only
  local element = SPELL_ELEMENT_OF[monsters.getMissileDamageType(missileId)]
  if element == nil then return dam end               -- physical missile: keep the phys-buffed roll
  if prof.baseMaxDamage == 0 then return dam end
  -- Strip the physical buff so the spell scales off Magic + resistance, keeping the missile's native multiplier.
  local cur = golem.maxDamage
  if cur > 0 then dam = math.floor(dam * prof.baseMaxDamage / cur) end
  if dam <= 0 then return 0 end
  local res        = math.max(0, profResForElement(prof, element))
  local magicBonus = prof.sharePct / 100 * prof.magicCurrent
  return math.ceil((dam + magicBonus) * (1 + res / 100))
end)

-- OnGolemMissileCanHitPlayer: extend the engine's Friendly Fire rules to tamed allies' missiles (PlayerMHit has no faction or toggle check of its own — any player in the flight path is fair game). Exact mapping of the vanilla player-missile semantics onto pets:
--   * a pet's missile NEVER hits its own owner — the pet analogue of "a player's missile never hits themself" (the unconditional misource check before Plr2PlrMHit), NOT toggle-gated;
--   * against OTHER players it mirrors Plr2PlrMHit's gate exactly: Friendly Fire off + friendly-mode owner -> no hit. FF on, or a hostile owner -> vanilla resolution proceeds (PvP).
-- A vetoed missile passes through and keeps flying (so a shot at a hostile player is not eaten by a friendly standing in the path). Deterministic on every client: isTamedAlly (synced roster), friendlyMode (synced), isFriendlyFireEnabled (game-init info). Berserk'd wild monsters carry MFLAG_GOLEM too but fail isTamedAlly -> nil (vanilla).
events.OnGolemMissileCanHitPlayer.add(function(ally, victim)
  if not isTamedAlly(ally.id) then return nil end
  local owner = allyOwner(ally)
  if owner == nil then return nil end
  if victim.id == owner.id then return false end -- own owner: never
  if not system.isFriendlyFireEnabled() and owner.friendlyMode then return false end
  return nil                                     -- FF enabled or hostile owner: vanilla hit resolution
end)

-- OnPlayerMissileCanHitGolem: the mirror direction — a PLAYER's missile resolving against a tamed ally (MonsterMHit has no faction or toggle check either). With Friendly Fire OFF, a caster who is the pet's owner or peaceful with the owner passes through (the missile keeps flying, so a spell aimed past the pet still reaches its enemy); hostility or FF ON -> vanilla resolution (pets are fair game in PvP, mirroring how a hostile player's missiles hit players regardless of the toggle). Tamed allies only — a vanilla Golem stays vanilla-hittable (base-mechanics barometer). Deterministic on every client: isTamedAlly (synced roster), friendlyMode (synced), isFriendlyFireEnabled (game-init info).
events.OnPlayerMissileCanHitGolem.add(function(caster, target)
  if system.isFriendlyFireEnabled() then return nil end
  if not isTamedAlly(target.id) then return nil end
  local owner = allyOwner(target)
  if owner == nil then return nil end
  if caster.id == owner.id then return false end      -- own pet: pass through
  if arePeaceful(caster, owner) then return false end -- peaceful allied Hunter's pet: pass through
  return nil                                          -- hostile: vanilla hit resolution
end)

-- OnGolemKillIsPlayerKill: a tamed pet is its owner's weapon, so a killing blow it lands on a HOSTILE
-- player is a PvP kill (ear drop / vanilla player-kill semantics), not a wild-monster kill (item drop).
-- Fires (engine-gated) only for MFLAG_GOLEM sources on the victim's own client, where the victim is the
-- local player, so we resolve hostility from our own synced state. Vanilla monster/trap default (nil) for:
-- a non-tracked source (vanilla Golem = barometer, or a wild monster the engine never gates here anyway),
-- an unknown owner, our own pet (can't be hit by it regardless), and a PEACEFUL owner (not PvP). Only a
-- hostile owner's pet flips it to a player kill. Deterministic: isTamedAlly (synced roster), friendlyMode (synced).
events.OnGolemKillIsPlayerKill.add(function(golem, victim)
  if not isTamedAlly(golem.id) then return nil end -- vanilla Golem / untracked source: vanilla monster/trap
  local owner = allyOwner(golem)
  if owner == nil then return nil end
  if victim.id == owner.id then return nil end      -- own owner: not PvP
  if arePeaceful(owner, victim) then return nil end -- peaceful owner: not PvP
  return true                                       -- hostile owner's pet landed the blow → player kill
end)

-- OnApocalypseCanTargetGolem: vanilla Apocalypse skips ALL player-minions (its own isPlayerMinion continue) — even a hostile caster's Apoc can't touch pets. Widen it for PvP only: a HOSTILE caster's Apocalypse may boom another player's tamed ally (mirrors the OnGolemCanTargetGolem hostility rule; the boom's damage then resolves normally through OnPlayerMissileCanHitGolem, which lets hostile hits through in both FF modes). Own pets and peaceful owners' pets keep the vanilla protection unconditionally — Apoc can't hit players even when hostile, so peace-time pets stay equally untouchable, independent of Friendly Fire. Tamed allies only: a vanilla Golem keeps the vanilla exclusion (barometer). Deterministic: synced roster/flags.
events.OnApocalypseCanTargetGolem.add(function(caster, target)
  if not isTamedAlly(target.id) then return nil end -- vanilla Golem etc.: vanilla exclusion
  local owner = allyOwner(target)
  if owner == nil then return nil end
  if caster.id == owner.id then return nil end      -- own pets: never
  if arePeaceful(caster, owner) then return nil end -- peace: never
  return true                                       -- hostile: Apoc may boom the pet
end)

-- OnGuardianCanTargetGolem: vanilla Guardian skips ALL player-minions (GuardianTryFireAt's isPlayerMinion return) — even a hostile caster's turret ignores pets (observed in PvP testing). Widen it for PvP only, the OnApocalypseCanTargetGolem rule verbatim: a HOSTILE caster's Guardian may fire at another player's tamed ally; the firebolt's damage then resolves normally through OnPlayerMissileCanHitGolem (hostile hits pass in both FF modes). Own pets and peaceful owners' pets keep the vanilla protection unconditionally — a Guardian never fires at players, so peace-time pets stay equally untouchable, independent of Friendly Fire. Tamed allies only: a vanilla Golem keeps the vanilla exclusion (barometer). Deterministic: the turret scans on every simulating client, and every input here is synced state (roster, friendlyMode).
events.OnGuardianCanTargetGolem.add(function(caster, target)
  if not isTamedAlly(target.id) then return nil end -- vanilla Golem etc.: vanilla exclusion
  local owner = allyOwner(target)
  if owner == nil then return nil end
  if caster.id == owner.id then return nil end      -- own pets: never
  if arePeaceful(caster, owner) then return nil end -- peace: never
  return true                                       -- hostile: Guardian may fire at the pet
end)

-- OnGolemMissileCanHitGolem: vanilla never resolves one player-minion's missile against another (the
-- CheckMissileCol faction gate skips the pair — the missile passes through), which made ranged
-- pet-vs-pet combat undeliverable: the targeting layer permits the fight (OnGolemCanTargetGolem), so
-- a ranged pet would lock a hostile pet and spam booms that never register (the zero-damage half of
-- the Apoc-desync bug). Open the pair with EXACTLY the targeting layer's rule — mutually-hostile
-- owners — so a boom is only deliverable where the fight is permitted; the admitted hit then resolves
-- through OnMonsterMissileHit (owner-authoritative) like any minion-involved hit. Same-owner and
-- peaceful pairs keep the vanilla pass-through (a stray boom crossing a friendly pet's tile never
-- resolves), the vanilla Golem included on both ends — same symmetry as the melee rule.
events.OnGolemMissileCanHitGolem.add(function(source, target)
  local a = player.get(source.ownerPlayerId)
  local b = player.get(target.ownerPlayerId)
  if a == nil or b == nil then return nil end -- unknown owner -> vanilla pass-through
  if a.id == b.id then return nil end         -- same owner -> never
  if arePeaceful(a, b) then return nil end    -- both friendly -> never
  return true                                 -- at least one hostile -> the hit may resolve
end)

-- Acid-as-magic + Bonded immunity piercing: two behaviours expressed in OnMonsterMissileHit, both
-- set/restored inline within one synchronous call so nothing ever observes a transient resistance change.

-- DamageType -> { IMMUNE_* flag we clear, RESIST_* (75%) flag we set } for elements with a real resist tier.
PIERCE_OF = {
  [monsters.DamageType.Fire]      = { immune = RES.ImmuneFire, resist = RES.ResistFire },
  [monsters.DamageType.Lightning] = { immune = RES.ImmuneLightning, resist = RES.ResistLightning },
  [monsters.DamageType.Magic]     = { immune = RES.ImmuneMagic, resist = RES.ResistMagic },
}

-- OnMonsterMissileHit: single resolution call-out for any missile with a player-minion on either end. Acts only for OUR allies (vanilla Golem returns -1); resolves inline (acid-as-magic, Bonded pierce, melee-parity to-hit, XP tag, resolve, restore).
events.OnMonsterMissileHit.add(function(source, target, missileId, damageType, minDam, maxDam, dist, shifted)
  if target == nil then return -1 end
  local srcProf = source ~= nil and allyMissileProfile(source) or nil -- our/another's ally as attacker?
  local tgtProf = allyMissileProfile(target)                          -- a tamed ally as victim?
  -- Barometer gate on ROSTER tracking (scratch presence), not profile presence: a vanilla Golem is in
  -- neither roster → -1 (pure engine default), while a TRACKED pet whose CO profile hasn't landed yet
  -- must still fall through to the authority DECLINE below — a -1 here would run a local vanilla
  -- resolution alongside the authority's (a second resolver in the CO-lag window).
  local srcTracked = source ~= nil and allyScratch(source.id) ~= nil
  local tgtTracked = allyScratch(target.id) ~= nil
  if not srcTracked and not tgtTracked then return -1 end -- vanilla Golem / non-allies → engine default

  -- MP resolution authority: vanilla never has monster-vs-monster missile combat, so this collision has
  -- no natural single resolver the way "my own click" (player attacks) or "damage to my own player"
  -- already do. But missiles DO simulate on every client (for rendering), and this hook's own to-hit/
  -- damage roll (target:resolveMissileHit -> the engine's GenerateRnd) is NOT synced outside the
  -- per-monster AI stream — so every observing client independently rolling AND applying, on top of the
  -- CMD_MONSTDAMAGE broadcast from every OTHER client's own roll, stacks damage without bound (observed
  -- as HP going UP: the "500 health bars" corruption). Only the owner of whichever side is the ATTACKER
  -- (falling back to the victim's owner) may resolve; every other client silently declines — the missile
  -- keeps flying and simply expires on duration once its authority is gone. The election reads ENGINE
  -- state (isGolem + ownerPlayerId, synced with the spawn), never the CO-profile cache: profile arrival
  -- is per-client timing, and an election that read it could seat two resolvers in the lag window
  -- (matters for pet-vs-pet, where BOTH sides have an electable owner). Owner-is-Hunter is the usual
  -- cross-player pet proxy: a berserk'd wild source carries MFLAG_GOLEM too, but its owner field is AI
  -- scratch — the class check keeps a garbage read from electing a resolver (falls to the victim's owner).
  local me = player.self()
  local authority = nil
  if source ~= nil and source.isGolem then
    local srcOwner = allyOwner(source)
    if srcOwner ~= nil and srcOwner.className == HUNTER_CLASS then authority = srcOwner end
  end
  if authority == nil and tgtTracked then authority = allyOwner(target) end
  if me == nil or authority == nil or authority.id ~= me.id then return 0 end

  local bondedAttacker = srcProf ~= nil and not srcProf.isMinion and srcProf.bonded

  local res            = target.resistance
  local newRes         = res
  local effectiveType  = damageType

  -- (A)/(B-acid) Acid resolves as Magic; a Bonded attacker bypasses acid immunity, otherwise it is respected.
  if damageType == monsters.DamageType.Acid then
    if bondedAttacker then
      if (newRes & RES.ImmuneAcid) ~= 0 then newRes = newRes - RES.ImmuneAcid end
      effectiveType = monsters.DamageType.Magic
    elseif (res & RES.ImmuneAcid) == 0 then
      effectiveType = monsters.DamageType.Magic
    end
  end

  -- (B) Bonded SOURCE downgrades the target's IMMUNITY to the effective element to big-resistance (25%), unless it is a rolled-Bonded immunity.
  if bondedAttacker then
    local pierce = PIERCE_OF[effectiveType]
    if pierce ~= nil and (newRes & pierce.immune) ~= 0 then
      -- PvP exception: never pierce the random immunity a Bonded ally was GRANTED on promotion.
      local rolled = tgtProf ~= nil and tgtProf.bondedImm == pierce.immune
      if not rolled then
        newRes = (newRes - pierce.immune) | pierce.resist
      end
    end
  end

  if newRes ~= res then target:setResistance(newRes) end

  -- (C) Attacker-aware to-hit for OUR ally's missiles. The engine's monster-missile resolution
  -- (MonsterTrapHit) rolls 90 - targetAC - dist and never consults the ATTACKER, so a high-toHit
  -- caster pet bottoms out at the 5% floor against high-AC targets (a Hell Blood Knight shrugs off
  -- ~19 in 20 Advocate fireballs). Express the wanted chance through a transient victim-AC change so
  -- the engine's own roll computes it (the engine subtracts one dist itself; its 5..95 clamp applies):
  --   * PET target (tgtTracked): the full duel formula, mirroring the engine's own
  --     monster-arrow-vs-player math (PlayerMHit): toHit + 2*(srcLvl-tgtLvl) + 30 - targetAC - 2*dist.
  --     The defender's AC (incl. a Bonded +AC bonus) genuinely protects it.
  --   * WILD target: melee parity (MonsterAttackMonster rolls d100 < toHit, AC ignored): toHit - dist.
  -- source.toHit reads golemToHit for player-minions, so the kill-count toHit bonus applies to
  -- missiles too. Gated on srcTracked (roster truth): a vanilla Golem is never tracked and keeps the
  -- pure vanilla roll (the barometer), and wild/berserk attackers shooting our pets stay vanilla
  -- (attacker-side only). A remote pet target in its CO-lag window reads as wild for a moment (melee
  -- parity instead of the duel formula) — harmless. Set/restored inline around the one synchronous
  -- resolve, like the resistance transient above.
  local origAC = nil
  if srcTracked then
    origAC = target.armorClass
    local wantHper -- the engine still subtracts dist once after this
    if tgtTracked then
      wantHper = source.toHit + 2 * (source.level - target.level) + 30 - origAC - dist
    else
      wantHper = source.toHit
    end
    target:setArmorClass(math.min(math.max(90 - wantHper, 0), 255))
  end

  -- XP credit: an OUR-ally attacker tags its owner BEFORE resolution so a fatal shot still counts.
  if srcProf ~= nil then target:tagForPlayer(source.ownerPlayerId) end

  -- Resolve through the engine (to-hit, resistance/immunity, damage, death/hit reactions).
  local hit = target:resolveMissileHit(missileId, effectiveType, minDam, maxDam, dist, shifted)

  if origAC ~= nil then target:setArmorClass(origAC) end -- restore the transient to-hit AC
  if newRes ~= res then target:setResistance(res) end    -- restore the transient pierce/reclass

  -- Bonded kill-count for an OWN ally that landed the fatal blow (no-op for remote allies).
  if hit and srcProf ~= nil and target.hasNoLife then creditAllyKill(source, target) end

  return hit and 1 or 0
end)

-- Deterministic cross-client pet test for hooks that resolve in the lockstep AI sim on EVERY client
-- (monster melee): engine-synced state only (isGolem + owner class — both set by the replayed
-- conversion), never per-client rosters or CO profiles, whose arrival timing differs per client —
-- two clients disagreeing on the inputs would resolve the same synced d100 swing differently and
-- desync HP. Known limitation (same proxy as isOtherHuntersAlly): a HUNTER-owned vanilla Golem would
-- pass it; deferred with the other cross-player Golem-vs-pet ambiguities.
function isHunterOwnedGolem(monster)
  if monster == nil or not monster.isGolem then return false end
  local owner = player.get(monster.ownerPlayerId)
  return owner ~= nil and owner.className == HUNTER_CLASS
end

-- OnGolemMeleeHitChance: SINGLE-WRITER pet melee + pet-vs-pet toHit-vs-AC duels. The engine's
-- MonsterAttackMonster resolves on EVERY simulating client and its ApplyMonsterDamage each time also
-- broadcasts CMD_MONSTDAMAGE (whose receiver SUBTRACTS on top of the local application) — so any
-- pet-involved melee hit multiplied by the number of same-level clients, and a swing whose inputs
-- diverged per-client (stat in CO transit, position skew) drifted the victim's HP apart permanently.
-- Fix = the same authority election as OnMonsterMissileHit: exactly ONE client rolls and applies
-- (its ApplyMonsterDamage broadcast carries the result to everyone); every other client returns 0 —
-- the engine's d100 still draws there, so the per-monster RNG stream stays aligned, but 0 never
-- hits: no local apply, no broadcast. Authority = the ATTACKER's owner when the attacker is a
-- Hunter pet (kill credit lands where creditAllyKill runs), else the VICTIM's owner (wild/berserk
-- attacker vs our pet). Election reads ENGINE state only (isGolem + owner class — the synced
-- conversion), never rosters/profiles whose arrival timing differs per client. Fights with a pet on
-- NEITHER side (incl. the vanilla Golem, both directions) return nil = pure vanilla multi-writer
-- resolution — the barometer keeps exact base behaviour.
-- Authority chance: hitChance >= 500 is the engine's forced-hit charge/rush value — keep it forced.
-- Pet-vs-pet DUELS roll toHit vs AC (vanilla monster melee ignores the defender's AC entirely):
-- passedHitChance + 2*(atkLvl-tgtLvl) + 30 - targetAC, clamped 5..95, mirroring the engine's own
-- monster-melee-vs-player formula. Built on the PASSED value so per-attack-type variants (special
-- attacks, magma +10 / storm -20) survive; for a pet's normal swing that value IS golemToHit, kill
-- bonus included. Pet-vs-wild keeps the engine's chance (melee parity), just resolved once.
events.OnGolemMeleeHitChance.add(function(attacker, target, hitChance)
  local atkTracked = allyScratch(attacker.id) ~= nil
  local tgtTracked = allyScratch(target.id) ~= nil
  if not atkTracked and not tgtTracked then return nil end -- no pet involved (vanilla Golem included): vanilla
  local me = player.self()
  local authority = nil
  if attacker.isGolem then
    local atkOwner = allyOwner(attacker)
    if atkOwner ~= nil and atkOwner.className == HUNTER_CLASS then authority = atkOwner end
  end
  if authority == nil and tgtTracked then authority = allyOwner(target) end
  if me == nil or authority == nil or authority.id ~= me.id then return 0 end
  if hitChance >= 500 then return nil end
  if isHunterOwnedGolem(attacker) and isHunterOwnedGolem(target) then
    local hper = hitChance + 2 * (attacker.level - target.level) + 30 - target.armorClass
    return math.min(math.max(hper, 5), 95)
  end
  return nil
end)

-- OnGolemMissileHitChance: pet SPELL missiles vs PLAYERS roll toHit vs AC. Vanilla's PlayerMHit
-- SPELL branch is 40 + 2*(mlvl-plvl) - 2*dist — the attacker's toHit and the player's armor are
-- never consulted, so a 249-toHit caster pet vs a lvl-45 player sits at the ~10% min-hit floor
-- while the same pet's ARROWS already roll the full formula. Mirror the arrow branch exactly:
-- vanilla rolls toHit + 2*(mlvl-plvl) + 30 - 2*dist - GetArmor(), and player.armorClass (sheet AC)
-- = GetArmor() + 2*plvl, so toHit + 2*mlvl + 30 - 2*dist - sheetAC is that same math rearranged.
-- Clamp 5..95 like the other two duel rules; the engine's block roll + resistances still follow,
-- so the player keeps real defenses. Arrow-class missiles return nil (the engine already rolled
-- toHit vs AC — don't re-derive). Resolution runs on the victim's own client (its HP is the
-- authority), so no lockstep constraint; golemToHit arrives there via the event-driven CO. A
-- vanilla Golem never fires missiles, so the proxy gate is belt-and-braces for the barometer.
events.OnGolemMissileHitChance.add(function(golem, victim, missileId, dist, hitChance)
  local MID = monsters.MissileID
  if missileId == MID.Arrow or missileId == MID.FireArrow or missileId == MID.LightningArrow then return nil end
  if not isHunterOwnedGolem(golem) then return nil end
  local hper = golem.toHit + 2 * golem.level + 30 - 2 * dist - victim.armorClass
  return math.min(math.max(hper, 5), 95)
end)

-- Bonded defensive bonus: on promotion the ally gains ONE random immunity it lacks (Fire/Magic/Lightning), or +200 AC if it has all three. Rolled once, stored by seed, persisted.

-- Roll & store the bonus from the monster's CURRENT immunities. No-op if already rolled for this seed.
function rollBondedBonus(entry)
  if bondedImmunity[entry.seed] ~= nil then return end
  local res = entry.monster.resistance
  local missing = {}
  for _, flag in ipairs(BONDED_IMMUNE_OPTIONS) do
    if (res & flag) == 0 then missing[#missing + 1] = flag end
  end
  if #missing == 0 then
    bondedImmunity[entry.seed] = BONDED_AC
  else
    bondedImmunity[entry.seed] = missing[math.random(#missing)]
  end
end

-- Pick & store this ally's Bonded recolour TRN from its rolled bonus (call after rollBondedBonus). No-op once stored.
function rollBondedTrn(entry)
  if bondedTrn[entry.seed] ~= nil then return end
  local variant = BONDED_TRN_BY_IMMUNITY[bondedImmunity[entry.seed]] or BONDED_TRN_GILDED
  if entry.capturedDifficulty == HELL_DIFFICULTY and math.random(100) <= HELL_GILD_CHANCE then
    variant = BONDED_TRN_GILDED
  end
  bondedTrn[entry.seed] = variant
end

-- Apply the stored bonus to the live monster (immunity written straight to resistance; +200 AC realised in applyAllyBuff). Call applyAllyBuff after this.
function applyBondedBonus(entry)
  local bonus = bondedImmunity[entry.seed]
  if bonus == nil or bonus == BONDED_AC then return end
  local m = entry.monster
  local res = m.resistance | bonus
  local superseded = BONDED_IMMUNE_SUPERSEDES[bonus]
  if superseded ~= nil and (res & superseded) ~= 0 then res = res - superseded end
  m:setResistance(res)
end

-- The discrete promotion moment: roll/store the bonus, apply it, re-derive stats, and fire a celebratory Flash burst.
function promoteToBonded(entry)
  rollBondedBonus(entry)
  rollBondedTrn(entry) -- pick the recolour matching the rolled bonus (or rare Hell Gilded)
  applyBondedBonus(entry)
  applyAllyBuff(entry)
  applyBondedGlow(entry) -- permanent Bonded aura light
  entry.monster:castFlashSelf()
end

-- Tame tier + monster-category model: a capture/deploy is allowed only when BOTH the tier's mlvl gate (mlvlGateAllows) AND the category's HP threshold pass.

-- Tier indices: 0 = Tame, 1 = Tame+, 2 = Tame++, 3 = Tame+++.
function tameTier(clvl)
  if clvl >= 45 then return 3 end
  if clvl >= 35 then return 2 end
  if clvl >= 20 then return 1 end
  return 0
end

-- Monster categories.
CAT_NORMAL   = "normal"
CAT_CHAMPION = "champion"
CAT_BOSS     = "boss"
CAT_DIABLO   = "diablo"

-- Classify a LIVE monster (capture side). Diablo is the one quest monster that is not unique.
function categoryFromTarget(target)
  if target.isQuestMonster and not target.isUnique then return CAT_DIABLO end
  if target.isUnique then
    return BOSS_NAMES[target.name] and CAT_BOSS or CAT_CHAMPION
  end
  return CAT_NORMAL
end

-- Capture-HP threshold (percent of max HP), keyed by category, fixed at every tier.
function categoryHpThreshold(category)
  if category == CAT_DIABLO then return 5 end
  if category == CAT_BOSS then return 10 end
  if category == CAT_CHAMPION then return 20 end
  return 30 -- normal
end

-- mlvl/category gate for the active tier: may this category at this mlvl be tamed by a Hunter of this clvl?
function mlvlGateAllows(tier, category, clvl, mlvl)
  if category == CAT_DIABLO then
    return tier >= 3                             -- only Tame+++, mlvl-blind
  end
  if tier >= 3 then return true end              -- Tame+++: any non-Diablo, any mlvl
  if tier == 2 then return mlvl <= clvl + 10 end -- Tame++: all non-Diablo categories
  -- Tame (0) and Tame+ (1):
  if category == CAT_NORMAL then return mlvl <= clvl + 1 end
  if category == CAT_CHAMPION then
    if tier >= 1 then return mlvl <= clvl end -- Tame+: champion eased to mlvl<=clvl
    return clvl >= mlvl * 2                   -- Tame: champion clvl>=mlvl*2
  end
  return clvl >= mlvl * 2                     -- Boss (Tame & Tame+): clvl>=mlvl*2
end

-- Classify a TAME SCROLL by its seed (deploy side); mirrors categoryFromTarget from the encoded seed/name.
function categoryFromScroll(seed)
  local uIdx = seedGetUniqueType(seed)
  if uIdx < 0 then
    -- Normal (typeId-keyed) scroll; Diablo travels this path too (he is not unique).
    if seedIsDiablo(seed) then return CAT_DIABLO end
    return CAT_NORMAL
  end
  local name = monsters.getUniqueName(uIdx)
  if name ~= nil and BOSS_NAMES[name] then return CAT_BOSS end
  return CAT_CHAMPION
end

-- True if a Tame scroll (by seed + dwBuff) is deployable at player p's current tier.
function scrollPassesTierGate(p, seed, buff)
  local clvl       = p.characterLevel
  local _, _, mlvl = decodeDwBuff(buff)
  local category   = categoryFromScroll(seed)
  return mlvlGateAllows(tameTier(clvl), category, clvl, mlvl)
end

LEASH_DISTANCE = 12                       -- emergency snap distance
ENGAGE_RADIUS  = 9                        -- max chase/target radius from player
MAX_ALLIES     =
MAX_DEPLOYED_PER_HUNTER                   -- deploy-gate cap on simultaneously deployed non-minion allies; must match the per-Hunter slot/type reservations at the top of the file

-- True when p is the local player AND the local player is a Hunter (gates all local-only event hooks).
function isMyPlayer(p)
  local self = player.self()
  return self ~= nil and p.id == self.id and self.className == HUNTER_CLASS
end

-- Data registration

-- Queue our spells. IDs are assigned by the engine after every mod registers (deterministic, by name). Names namespaced "hunter:".
events.SpellDataLoaded.add(function()
  spells.registerSpell("hunter:tame", "txtdata\\spells\\tame.tsv", "Golem")
  spells.registerSpell("hunter:sharepotion", "txtdata\\spells\\sharepotion.tsv", "HealOther")
  spells.registerSpell("hunter:forgetpotion", "txtdata\\spells\\forgetpotion.tsv", "Null")
end)

-- SpellsAssigned fires after assignment, before ItemDataLoaded / PlayerDataLoaded, so these ids resolve in time.
events.SpellsAssigned.add(function()
  TAME_ID          = spells.getSpellId("hunter:tame")
  SHARE_POTION_ID  = spells.getSpellId("hunter:sharepotion")
  FORGET_POTION_ID = spells.getSpellId("hunter:forgetpotion")
end)

events.PlayerDataLoaded.add(function()
  player.addClassDataFromTsv("txtdata\\classes\\classdat_hunter.tsv")
end)

-- Re-grant Share Potion on every level entry (InitPlayer resets _pAblSpells to the class's starting skill each load).
events.OnLevelEnter.add(function()
  local p = player.self()
  if p == nil then return end
  if p.className ~= HUNTER_CLASS then return end
  p:addSkill(SHARE_POTION_ID)
end)

-- Grant a starting Tame Scroll when a new Hunter character is created (OnCreatePlrItems, the standard item-placement context).
events.OnCreatePlrItems.add(function(p)
  if p == nil then return end
  if p.className ~= HUNTER_CLASS then return end
  resetPersistedCharacterState() -- a NEW character starts from a clean slate (it fires no OnLoadPlayerData, so nothing else would)
  myOhId = generateOhId(p.name)  -- permanent per-character OHID, stamped once at creation
  local monsterData = {
    typeId             = STARTER_TYPE_ID,
    savedHp            = STARTER_MAX_HP,
    maxHp              = STARTER_MAX_HP,
    name               = STARTER_NAME,
    level              = STARTER_LEVEL,
    capturedDifficulty = monsters.currentDifficulty(),
  }
  -- The creating Hunter is the starter pet's Original Trainer; route through the shared scroll-creation helper.
  addTameScrollToInventory(p, monsterData, { name = p.name, id = myOhId })
end)

-- Stat-scaled animation frame tiers: Hunter uses Warrior sprites; melee skip scales off STR/VIT, ranged off DEX, cast off MAG.

-- PlayerWeaponGraphic ids (player.weaponGraphic — the weapon sheet the player's animations play).
WEAPON_GRAPHIC_UNARMED        = 0
WEAPON_GRAPHIC_UNARMED_SHIELD = 1
WEAPON_GRAPHIC_BOW            = 4
WEAPON_GRAPHIC_STAFF          = 8

function getMeleeSkipBonus(str, vit)
  if str >= 170 then
    return 0                                     -- Warrior archetype: optimal
  elseif str >= 150 and vit >= 150 then
    return 0                                     -- Barbarian archetype gate
  elseif str >= 150 then
    return -1
  elseif str >= 125 then
    return -2
  elseif str >= 75 then
    return -3
  else
    return -4
  end
end

function getRangedSkipBonus(dex)
  if dex >= 200 then
    return 4                  -- Rogue archetype: optimal
  elseif dex >= 175 then
    return 3
  elseif dex >= 125 then
    return 2
  elseif dex >= 75 then
    return 1
  else
    return 0
  end
end

function getCastSkipBonus(mag)
  if mag >= 140 then
    return 8                  -- Sorcerer-lite archetype: optimal
  elseif mag >= 120 then
    return 6
  elseif mag >= 80 then
    return 4
  elseif mag >= 40 then
    return 2
  else
    return 0
  end
end

-- CLASS-gated, not isMyPlayer: every client renders/simulates every player's animations, so the skip must resolve identically for a REMOTE Hunter too (same lesson as OnGetPlayerIdleFrames).
events.OnGetAnimationSkipFrames.add(function(p, animType, currentSkip)
  if p.className ~= HUNTER_CLASS then return nil end
  if animType == "Attack" then
    local bonus = getMeleeSkipBonus(p.strength, p.vitality)
    -- Monk-archetype staff/unarmed play the vanilla Monk's animation TOTALS on the warrior sheet:
    -- staff 16→13 (+3), unarmed 16→12 (+4) — the exact monk animations.tsv frame counts. Additive
    -- with the engine's Haste skip exactly like vanilla (monk staff of haste 13−4=9 ≡ 16−(4+3)=9).
    -- Other melee weapons stay on the STR ladder (the monk identity is staff/unarmed; vanilla
    -- Monk's axe, 23f, is already ≈ the ladder at monk-typical STR). max() so a high-STR Monk
    -- keeps ladder speed if it ever exceeds the override. Weapon graphic = synced equipment state,
    -- so every client computes the same skip (same determinism gate as the rest of this handler).
    if hasMonkArchetype(p) then
      local wg = p.weaponGraphic
      if wg == WEAPON_GRAPHIC_STAFF then
        bonus = math.max(bonus, 3)
      elseif wg == WEAPON_GRAPHIC_UNARMED or wg == WEAPON_GRAPHIC_UNARMED_SHIELD then
        bonus = math.max(bonus, 4)
      end
    end
    return currentSkip + bonus
  elseif animType == "RangedAttack" then
    return currentSkip + getRangedSkipBonus(p.dexterity)
  elseif animType == "Cast" then
    return currentSkip + getCastSkipBonus(p.magic)
  elseif animType == "Block" then
    -- Shieldless Monk-archetype block is redirected to the 6-frame hit-recovery flinch
    -- (OnGetPlayerBlockGraphic below); skip 4 so only 2 frames show = vanilla block duration
    -- (recoveryFrames=6 per animations.tsv). Shield blocks use the real 2-frame bl sheet and
    -- keep the default skip. Same synced-state gate as the redirect — deterministic on every client.
    if hasMonkArchetype(p) and not p.isHoldingShield then return 4 end
  end
  -- HitRecovery (and shield Block): item bonuses flow through unchanged
end)

-- Bow-equipped dungeon stand sprite only has 8 frames; apply to EVERY Hunter (rendering property, every client renders every player).
events.OnGetPlayerIdleFrames.add(function(p, weaponGraphic, isInTown)
  if p.className ~= HUNTER_CLASS then return nil end
  if weaponGraphic == WEAPON_GRAPHIC_BOW and not isInTown then
    return 8
  end
end)

-- Hunter always displays the Light Armor sprite set regardless of equipped armor (cosmetic; applies to EVERY Hunter).
events.OnGetPlayerArmorGraphic.add(function(p, currentGraphic)
  if p.className ~= HUNTER_CLASS then return nil end
  return "Light"
end)

-- Elixir restriction: Hunter cannot use stat-raising elixirs (shows red; blocks equip/consume, not pickup).
ELIXIR_MISC_IDS = {
  [items.ItemMiscID.ElixirStr] = true,
  [items.ItemMiscID.ElixirMag] = true,
  [items.ItemMiscID.ElixirDex] = true,
  [items.ItemMiscID.ElixirVit] = true,
}

-- SpellID::Golem = 21 (vanilla enum, stable).
GOLEM_SPELL_ID = 21

events.OnCanPlayerUseItem.add(function(p, item)
  if not isMyPlayer(p) then return nil end
  if ELIXIR_MISC_IDS[item.miscId] then return false end
  -- Block Spectral Elixir (raises all stats) by item index
  if item.IDidx == items.ItemIndex.SpectralElixir then return false end
  -- Golem scrolls are completely invalid for Hunter (cast from memory or staff only).
  if item:isScrollOf(GOLEM_SPELL_ID) then return false end
  -- A Tame scroll outside the Hunter's current tier criteria is red/unusable (data preserved; only deployment gated).
  if item:isScrollOf(TAME_ID) and not scrollPassesTierGate(p, item.seed, item.buff) then
    return false
  end
end)

-- Speedbook spell filter: hide learned spells not on the Hunter allowlist (scrolls/staff charges always show).
-- SpellID integer values from the engine enum (SpellID in spelldat.h).
HUNTER_ALLOWED_LEARNED_SPELLS = {
  [2]  = true, -- Healing
  [7]  = true, -- TownPortal
  [8]  = true, -- StoneCurse
  [10] = true, -- Phasing
  [11] = true, -- ManaShield
  -- Guardian (13) and Golem (21) intentionally excluded: Hunter's summon identity is Tame.
  [23] = true, -- Teleport
  [33] = true, -- Telekinesis
  [34] = true, -- HealOther
  [42] = true, -- Warp      (Hellfire)
  [43] = true, -- Reflect   (Hellfire)
  [44] = true, -- Berserk   (Hellfire)
  [46] = true, -- Search    (Hellfire)
}

events.OnShouldHideSpeedbookSpell.add(function(p, spellId, spellType)
  if not isMyPlayer(p) then return nil end
  if spellType == "Spell" then
    -- Hide any learned spell not on the allowlist.
    if HUNTER_ALLOWED_LEARNED_SPELLS[spellId] then return nil end
    return true
  end
  -- Hide Golem scrolls regardless of type (only memory/charges allowed).
  if spellType == "Scroll" and spellId == GOLEM_SPELL_ID then return true end
  return nil
end)

-- Spellbook: block selecting a restricted learned spell as the active cast spell (display unchanged).
events.OnCanSelectSpellBookEntry.add(function(p, spellId)
  if not isMyPlayer(p) then return nil end
  if HUNTER_ALLOWED_LEARNED_SPELLS[spellId] then return nil end
  return false
end)

-- Stat budget: per-stat cap = the TSV maxima (250 each — archetype headroom in every stat), plus a
-- shared TOTAL budget so the four base stats can never sum past STAT_BUDGET (460, the vanilla
-- Warrior/Sorcerer maxima total; Rogue's 455 quirk is deliberately not emulated).
--
--   max(attr) = clamp(attr + (STAT_BUDGET - total), 0, HUNTER_STAT_CAP)
--
-- Why this exact shape (replaces the old "freeze at current once total >= budget" model, which
-- corrupted GetMaximumAttributeValue consumers — see the 2026-07-08 stat-validation bug):
--  * Pure function of this player's own base stats — the same answer in every state, on every call.
--  * At total == STAT_BUDGET each stat's max IS its current value: golden display, allocation blocked.
--  * Lossless through UnPackPlayer, which zeroes the struct then sets+clamps the four stats ONE AT A
--    TIME: a not-yet-loaded stat reads 0, which only INFLATES headroom, and at each step
--    headroom >= the sum of all not-yet-loaded stats, so a legal <=460 spread always loads intact
--    (the freeze model zeroed late-loading stats whenever the early ones summed past 460).
--  * An over-budget spread (pre-fix saves) self-heals to exactly 460 at load by dumping the excess
--    from the later-loaded stats; one Potion of Forgetting then refunds the full budget — no points lost.
--  * Floors at 0: UnPackPlayer feeds the result through std::min<uint8_t>, so a negative would wrap.
STAT_BUDGET = 460
HUNTER_STAT_CAP = 250 -- mirrors maxStr/maxMag/maxDex/maxVit in txtdata/classes/hunter/attributes.tsv

-- DELIBERATELY isMyPlayer (the one stat hook that must NOT be class-gated): UnPackNetPlayer VALIDATES a
-- joining Hunter's incoming base stats against GetMaximumAttributeValue evaluated on the RECEIVER's copy
-- of that player — which may hold stale stats from an earlier connection. Remote Hunters must resolve
-- the static TSV maxima there or a legitimate respec since we last saw them would be rejected. The
-- budget needs no cross-client enforcement: it only shapes allocation/refund on the owning client, and
-- base stats travel the wire as raw synced values.
events.OnGetMaxAttributeValue.add(function(p, attributeName)
  if not isMyPlayer(p) then return nil end
  local cur
  if attributeName == "Strength" then
    cur = p.strength
  elseif attributeName == "Magic" then
    cur = p.magic
  elseif attributeName == "Dexterity" then
    cur = p.dexterity
  elseif attributeName == "Vitality" then
    cur = p.vitality
  else
    return nil
  end
  local headroom = STAT_BUDGET - (p.strength + p.magic + p.dexterity + p.vitality)
  return math.max(0, math.min(HUNTER_STAT_CAP, cur + headroom))
end)

-- Adaptive Archetype System: Hunter's combat mechanics scale with base-stat investment; each archetype needs its FULL threshold (base stats only).
--
-- Threshold design (2026-07-08 retune, user-approved): every archetype's threshold VALUES sum to 300
-- (Sorc-lite, single-stat, is 140). Inside the fixed 460 stat budget — which caps all four base stats
-- SUMMED, each with a class-start floor (str20/mag15/dex30/vit20) — that makes every non-Barb DUAL
-- reachable: Rogue+Sorc and Warrior+Sorc land at exactly 460 (min-max builds), Monk+Sorc 410,
-- Rogue+Warrior 405, Warrior+Monk 390, Rogue+Monk 370, and even Rogue+Monk+Sorc fits at exactly 460.
-- Barb's mag<=15 keeps it a committed solo identity (Sorc/Monk conflict by design; Warrior/Rogue
-- duals miss the budget by 5-55).
--
-- EVERY archetype hook below gates on CLASS (p.className == HUNTER_CLASS), NEVER isMyPlayer. These hooks
-- fire from CalcPlrInv-family recomputation that runs on EVERY client for EVERY player — including inside
-- UnPackNetPlayer, whose validator then compares the recomputed derived stats field-by-field against the
-- values the owner packed (_pDamageMod, _pIAC, _pIMinDam/_pIMaxDam, baseToBlock, ...). An isMyPlayer gate
-- makes the two sides compute DIFFERENT numbers the moment an archetype threshold is met -> "Player sent
-- an invalid packet" and the join is refused. Archetype checks read only synced state (class, stats,
-- level), so a class gate is deterministic on every client. (Same lesson as the appearance hooks.)
function hasBarbArchetype(p)
  return p.strength >= 150 and p.vitality >= 150 and p.magic <= 15
end

function hasWarriorArchetype(p)
  return p.strength >= 170 and p.dexterity >= 130
end

function hasRogueArchetype(p)
  return p.strength >= 100 and p.dexterity >= 200
end

function hasMonkArchetype(p)
  return p.strength >= 100 and p.magic >= 50 and p.dexterity >= 150
end

function hasSorcLiteArchetype(p)
  return p.magic >= 140
end

-- _pDamageMod: returns the highest damage-mod among all met archetypes, nil if none met.
events.OnGetPlayerDamageMod.add(function(p, strMod, strDexMod, totalVit, isBow, isShield, isStaff, isUnarmed)
  if p.className ~= HUNTER_CLASS then return nil end
  local best = nil
  local level = p.characterLevel

  if hasBarbArchetype(p) then
    local barb
    if isBow then
      barb = strMod // 300
    elseif isShield then
      barb = strMod // 75
    elseif not isStaff then
      barb = strMod // 75 + level * totalVit // 100
    else
      barb = strMod // 100
    end
    best = barb
  end
  if hasWarriorArchetype(p) then
    local w = strMod // 100
    if best == nil or w > best then best = w end
  end
  if hasRogueArchetype(p) then
    local r = strDexMod // 200
    if best == nil or r > best then best = r end
  end
  if hasMonkArchetype(p) then
    local m = (isStaff or isUnarmed) and strDexMod // 150 or strDexMod // 300
    if best == nil or m > best then best = m end
  end
  return best
end)

-- Critical strike (Warrior archetype).
events.OnPlayerHasCriticalStrike.add(function(p)
  if p.className ~= HUNTER_CLASS then return nil end
  return hasWarriorArchetype(p) or nil
end)

-- Iron skin AC bonus (Barbarian archetype).
events.OnPlayerHasIronSkin.add(function(p)
  if p.className ~= HUNTER_CLASS then return nil end
  return hasBarbArchetype(p) or nil
end)

-- Natural resistances (Barbarian archetype).
events.OnPlayerHasNaturalResistance.add(function(p)
  if p.className ~= HUNTER_CLASS then return nil end
  return hasBarbArchetype(p) or nil
end)

-- Full bow damage modifier (Rogue archetype).
events.OnGetBowDamageMod.add(function(p, fullMod)
  if p.className ~= HUNTER_CLASS then return nil end
  if not hasRogueArchetype(p) then return nil end
  return fullMod
end)

-- Arrow velocity bonus (Rogue archetype).
events.OnGetArrowVelocityBonus.add(function(p)
  if p.className ~= HUNTER_CLASS then return nil end
  if not hasRogueArchetype(p) then return nil end
  return (p.characterLevel - 1) // 4
end)

-- Block without shield (Monk archetype).
events.OnPlayerCanBlockWithoutShield.add(function(p, isStaff, isUnarmed)
  if p.className ~= HUNTER_CLASS then return nil end
  return hasMonkArchetype(p) or nil
end)

-- Block animation redirect (Monk archetype). The Hunter renders on warrior sprites, and the
-- warrior sheet has block ("bl") files ONLY for shield combos — a shieldless Monk-archetype
-- Hunter with _pBlockFlag set would make InitPlayerGFX request a nonexistent file on dungeon
-- entry (e.g. plrgfx\warrior\wln\wlnbl.cl2) → app_fatal, surfacing as the masked net-thread
-- crash (see bugs.md). Redirect the block animation to the hit-recovery flinch ("Hit"), which
-- exists for every combo; the bl sheet is then never loaded. Shield combos keep the real block
-- animation. Class+stat+equipment gate = synced state, deterministic on every client (a peer
-- rendering this Hunter runs the same redirect). Swap "Hit" for "Stand" if the flinch reads
-- badly in playtest. The flinch is 6 frames vs the 2-frame vanilla block; the
-- OnGetAnimationSkipFrames handler above skips 4 so the block lockout stays at 2 frames.
events.OnGetPlayerBlockGraphic.add(function(p)
  if p.className ~= HUNTER_CLASS then return nil end
  if not hasMonkArchetype(p) then return nil end
  if p.isHoldingShield then return nil end
  return "Hit"
end)

-- Armor level-scaling AC bonus (Monk archetype).
events.OnGetArmorLevelBonus.add(function(p, armorType, isUnique)
  if p.className ~= HUNTER_CLASS then return nil end
  if not hasMonkArchetype(p) then return nil end
  local level = p.characterLevel
  if armorType == "Heavy" then
    return isUnique and (level // 2) or 0
  elseif armorType == "Medium" then
    return isUnique and (level * 2) or (level // 2)
  else -- Light
    return level * 2
  end
end)

-- Hit recovery stagger threshold (Barbarian archetype); C++ pre-applies level+level/4 only for native Barbarian.
events.OnGetHitRecoveryThreshold.add(function(p, baseThreshold)
  if p.className ~= HUNTER_CLASS then return nil end
  if not hasBarbArchetype(p) then return nil end
  local level = p.characterLevel
  return level + level // 4
end)

-- Unarmed damage floor (Monk archetype): min = max(current, level/2); max = max(current, level).
events.OnGetUnarmedDamageFloor.add(function(p, minDamage, maxDamage)
  if p.className ~= HUNTER_CLASS then return nil end
  if not hasMonkArchetype(p) then return nil end
  local level = p.characterLevel
  return { math.max(minDamage, level // 2), math.max(maxDamage, level) }
end)

-- Block chance bonus by archetype: Warrior/Barb=30, Monk=25, Rogue=20; nil falls back to TSV value of 10.
events.OnGetBlockChanceBonus.add(function(p, baseBonusFromTsv)
  if p.className ~= HUNTER_CLASS then return nil end
  local bonus = 0
  if hasBarbArchetype(p) or hasWarriorArchetype(p) then bonus = math.max(bonus, 30) end
  if hasMonkArchetype(p) then bonus = math.max(bonus, 25) end
  if hasRogueArchetype(p) then bonus = math.max(bonus, 20) end
  if bonus == 0 then return nil end
  return bonus
end)

-- Mana cost reduction (Sorcerer-lite archetype: 25% reduction, same as Rogue/Monk/Bard).
events.OnGetManaCost.add(function(p, baseCost)
  if not isMyPlayer(p) then return nil end
  if not hasSorcLiteArchetype(p) then return nil end
  return baseCost - baseCost // 4
end)

-- Wirt item filter: with a full archetype, bias Wirt's item toward usable types (excluded only when ALL active archetypes agree).
WIRT_EXCLUSIONS = {
  Barbarian = { Bow = true, Staff = true },
  Warrior   = { Bow = true, Staff = true },
  Rogue     = { Sword = true, Staff = true, Axe = true, Mace = true, Shield = true },
  Monk      = { Bow = true, MediumArmor = true, Shield = true, Mace = true },
}

events.OnShouldExcludeWirtItem.add(function(p, itemTypeName)
  if not isMyPlayer(p) then return nil end
  local active = {}
  if hasBarbArchetype(p) then table.insert(active, WIRT_EXCLUSIONS.Barbarian) end
  if hasWarriorArchetype(p) then table.insert(active, WIRT_EXCLUSIONS.Warrior) end
  if hasRogueArchetype(p) then table.insert(active, WIRT_EXCLUSIONS.Rogue) end
  if hasMonkArchetype(p) then table.insert(active, WIRT_EXCLUSIONS.Monk) end
  if #active == 0 then return nil end
  for _, excl in ipairs(active) do
    if not excl[itemTypeName] then return nil end
  end
  return true
end)

-- Partial potion heal: Hunter always gets 2x (same as Warrior/Barbarian).
events.OnGetPotionHealAmount.add(function(p, l)
  if not isMyPlayer(p) then return nil end
  return l * 2
end)

-- Partial potion mana: Hunter always gets 2x (same as Sorcerer in Hellfire).
events.OnGetPotionManaAmount.add(function(p, l)
  if not isMyPlayer(p) then return nil end
  return l * 2
end)

-- Armor pierce in melee (Barbarian archetype).
events.OnPlayerHasArmorPierce.add(function(p)
  if p.className ~= HUNTER_CLASS then return nil end
  return hasBarbArchetype(p) or nil
end)

-- Cleave: Barb archetype grants cleave with axe or 2H mace/sword; Monk archetype with staff.
events.OnPlayerCanCleave.add(function(p, isAxe, isTwoHandedHeavy, isStaff)
  if p.className ~= HUNTER_CLASS then return nil end
  if hasBarbArchetype(p) and (isAxe or isTwoHandedHeavy) then return true end
  if hasMonkArchetype(p) and isStaff then return true end
end)

-- Oily Shrine: +2 to the highest base stat that is not at its individual cap (250).
events.OnOilyShrine.add(function(p)
  if not isMyPlayer(p) then return end
  local stats = {
    { name = "Strength",  value = p.strength },
    { name = "Dexterity", value = p.dexterity },
    { name = "Magic",     value = p.magic },
    { name = "Vitality",  value = p.vitality },
  }
  -- Sort descending by value; skip any at individual cap (250 per attributes.tsv).
  table.sort(stats, function(a, b) return a.value > b.value end)
  for _, stat in ipairs(stats) do
    if stat.value < 250 then
      p:modifyStat(stat.name, 2)
      return
    end
  end
  -- All stats at 250 — nothing to grant.
end)

-- SpellDataLoaded fires before ItemDataLoaded, so TAME_ID / FORGET_POTION_ID are valid here.
events.ItemDataLoaded.add(function()
  items.addItemData({
    {
      name          = "Tame Scroll",
      class         = items.ItemClass.Misc,
      type          = items.ItemType.Misc,
      miscId        = items.ItemMiscID.Scroll,
      spell         = TAME_ID,
      usable        = true,
      dropRate      = 0,
      cursorGraphic = 1, -- ICURS_SCROLL_OF
      skipSpeedbook = true,
      value         = 0,
    }
  }, TAME_SCROLL_MAP)

  -- Potion of Forgetting: IMISC_FULLREJUV (behaves like a full rejuv); 'spell' stores FORGET_POTION_ID only for OnItemUsed detection.
  items.addItemData({
    {
      name          = "Potion of Forgetting",
      class         = items.ItemClass.Misc,
      type          = items.ItemType.Misc,
      miscId        = items.ItemMiscID.FullRejuv,
      spell         = FORGET_POTION_ID,
      usable        = true,
      dropRate      = 0,
      cursorGraphic = 16, -- ICURS_ARENA_POTION
      value         = 0,
    }
  }, FORGET_POTION_MAP)
end)

-- Helpers

function removeDeployedById(monsterId)
  for i = #deployedAllies, 1, -1 do
    if deployedAllies[i].id == monsterId then
      untrackDeployedAt(i)
      return
    end
  end
end

-- Minions: monsters spawned by a tamed ally's special ability; tracked in deployedAllies with isMinion=true + parentId. Never count against the cap, never recalled, despawned with their parent.
function countMinionsOfParent(parentId)
  local n = 0
  for _, entry in ipairs(deployedAllies) do
    if entry.isMinion and entry.parentId == parentId then n = n + 1 end
  end
  -- Also count remote-owned minions: the spawn-cap decision runs on every client, so a peer must match the owner's count.
  for _, rec in pairs(remoteAllies) do
    if rec.parentId == parentId then n = n + 1 end
  end
  return n
end

function removeMinionsOfParent(parentId)
  for i = #deployedAllies, 1, -1 do
    local entry = deployedAllies[i]
    if entry.isMinion and entry.parentId == parentId then
      local mid = entry.monster.id
      entry.monster:remove() -- silently vanish: no death effects, loot, or XP
      broadcastRemove(mid)   -- peers despawn their mirrored copy (a minion has no natural-death sync there)
      untrackDeployedAt(i)
    end
  end
end

-- Build scroll name + dwBuff for a monster data record. Pass existingSeed on recall to preserve seed-keyed state; `origin` stamps a NEW scroll's Original Trainer (omit when recreating).
function buildScrollParams(monsterData, existingSeed, origin)
  local uIdx = monsterData.uniqueTypeIdx
  local dif  = monsterData.capturedDifficulty or 0
  local seed = existingSeed or allocSeed(monsterData.typeId, uIdx)
  -- Record/keep the scroll's origin: explicit on a fresh tame, otherwise whatever this seed already had.
  origin     = origin or scrollOrigin[seed]
  if origin ~= nil then scrollOrigin[seed] = origin end
  -- Capture tamed-in gamemode + area level ONCE on the fresh tame; recall/refund keeps the stored values.
  if existingSeed == nil and scrollGamemode[seed] == nil then
    scrollGamemode[seed] = system.isHellfire() and 1 or 0
    -- currentDeltaLevel() needs the local player, which doesn't exist during char creation; the only pre-player tame is the starter pet (Church Lvl 1).
    scrollAreaLevel[seed] = (player.self() ~= nil) and items.currentDeltaLevel() or 1
  end
  -- Every "Tamed" name surface becomes "Bonded" once the kill threshold is met.
  local prefix = isBonded(seed, monsterData.level) and "Bonded" or "Tamed"
  local scrollName, dwBuff
  if (uIdx ~= nil and uIdx >= 0) or seedIsDiablo(seed) then
    scrollName = prefix .. " " .. monsterData.name
    -- Unique/Diablo names carry no "Lvl N" prefix, but the level is still stored in dwBuff for the infobox.
    dwBuff = encodeDwBuff(monsterData.savedHp, monsterData.maxHp, monsterData.level or 0, dif)
  else
    scrollName = prefix .. " Lvl " .. monsterData.level .. " " .. monsterData.name
    dwBuff = encodeDwBuff(monsterData.savedHp, monsterData.maxHp, monsterData.level, dif)
  end
  -- modData is the self-describing blob so the scroll survives a floor-drop trade and a re-stamp; empty for a non-scroll.
  return seed, scrollName, dwBuff, blobForSeed(seed)
end

-- The ONE floor-drop primitive for a Tame Scroll. The ITEM replicates itself: spawnAt announces it
-- over the engine wire (CMD_SPAWNITEM — same-level peers spawn a live copy, every client registers it
-- in the level delta, dedup included), exactly like a vanilla quest/reward drop. Only the BLOB needs
-- mod plumbing, because the vanilla item wire/save structs are fixed-width and can't carry it: write
-- it at rest into the level delta (survives rejoin/restart) + announce it live over SD (peers' caches).
function placeScrollOnFloor(x, y, seed, scrollName, dwBuff, modData)
  items.spawnAt(x, y, TAME_SCROLL_MAP, seed, scrollName, dwBuff, modData)
  local lvl = items.currentDeltaLevel()
  items.setItemDeltaModData(lvl, seed, modData)
  broadcastScrollData(seed, lvl)
end

-- Allocate a seed, cache monster data, and drop the scroll on the floor (seed+dwBuff survive game restart).
function dropTameScroll(monsterData, x, y, origin)
  local seed, scrollName, dwBuff, modData = buildScrollParams(monsterData, nil, origin)
  tameScrollData[seed] = monsterData -- session cache for fast lookup
  placeScrollOnFloor(x, y, seed, scrollName, dwBuff, modData)
  return seed
end

-- Inventory sibling of dropTameScroll: shares buildScrollParams so a held scroll is identical to a floor-dropped one. Returns the seed, or nil if no room.
function addTameScrollToInventory(owner, monsterData, origin)
  local seed, scrollName, dwBuff, modData = buildScrollParams(monsterData, nil, origin)
  tameScrollData[seed] = monsterData -- session cache for fast lookup
  if not owner:addScrollByMapping(TAME_SCROLL_MAP, seed, scrollName, dwBuff, modData) then return nil end
  broadcastScrollData(seed)          -- announce this held scroll's identity to peers (no level => no delta write; no-op in SP)
  return seed
end

-- Build a monsterData record from a live deployed ally + its tracking entry. Unique-ness is derived from entry.seed (the single source of truth), not the live monster.
function allyToMonsterData(ally, entry)
  local uType = seedGetUniqueType(entry.seed)
  -- ally.maxHealth is the BUFFED max; persist the un-buffed snapshot (entry.base.maxHp) so the buff never bakes into the scroll.
  local baseMax = (entry.base and entry.base.maxHp) or ally.maxHealth
  local savedHp = math.min(ally.health, baseMax)
  return {
    typeId             = ally.typeId,
    savedHp            = savedHp,
    maxHp              = baseMax,
    name               = ally.name,
    level              = ally.level,
    uniqueTypeIdx      = uType >= 0 and uType or nil,
    capturedDifficulty = entry.capturedDifficulty or 0,
  }
end

-- Lazily refresh a Lost entry's stored HP from the live ally (called at level exit, before recall).
function refreshRecoveryEntry(entry)
  if entry == nil or entry.seed == nil then return end
  if recoveryRegistry[entry.seed] == nil then return end
  recoveryRegistry[entry.seed].dwBuff = recoveryDwBuffFromData(allyToMonsterData(entry.monster, entry))
end

-- Recall a deployed ally and place its Tame Scroll in the owner's inventory; NEVER dropped on the floor (a full inventory keeps the Pepin recovery backup instead). Returns true if placed.
function recallAllyToInventory(ally, entry, owner)
  local data = allyToMonsterData(ally, entry)
  -- Reuse entry.seed so allyKillCounts[seed] is still valid after redeploy.
  local seed, scrollName, dwBuff, modData = buildScrollParams(data, entry.seed)
  tameScrollData[seed] = data -- session cache
  local mid = ally.id
  ally:remove()
  broadcastRemove(mid) -- peers despawn their mirrored copy of this recalled ally (no natural-death sync)
  if owner:addScrollByMapping(TAME_SCROLL_MAP, seed, scrollName, dwBuff, modData) then
    local scrollItem = owner:findScrollBySeed(seed)
    if scrollItem then
      -- Gold tier for unique champions/bosses, Diablo, AND Bonded scrolls.
      if data.uniqueTypeIdx ~= nil or seedIsDiablo(seed) or isBonded(seed, data.level) then scrollItem.magical = 2 end -- ITEM_QUALITY_UNIQUE → gold text + outline
    end
    return true
  end
  return false
end

-- Reconstruct monster data from a scroll item's seed and dwBuff (normal + unique scrolls).
function recoverScrollData(scrollSeed, scrollItem)
  local savedHp, maxHp, level, difficulty = decodeDwBuff(scrollItem.buff)
  if savedHp == 0 and maxHp == 0 then return nil end -- no valid HP data; scroll unrecoverable
  if maxHp == 0 then maxHp = savedHp end
  if savedHp == 0 then savedHp = maxHp end

  local uIdx = seedGetUniqueType(scrollSeed)
  if uIdx >= 0 then
    local name = monsters.getUniqueName(uIdx)
    if name == nil then return nil end
    return {
      uniqueTypeIdx      = uIdx,
      capturedDifficulty = difficulty,
      savedHp            = savedHp,
      maxHp              = maxHp,
      name               = name,
      level              = level,
    }
  else
    local typeId = seedToTypeId(scrollSeed)
    local name = monsters.getNameByTypeId(typeId)
    if name == nil then return nil end
    return {
      typeId             = typeId,
      capturedDifficulty = difficulty,
      savedHp            = savedHp,
      maxHp              = maxHp,
      name               = name,
      level              = level,
    }
  end
end

-- Build the player-facing recovery line for a registry entry, or nil if its scroll data can't be reconstructed.
function recoveryMessageFor(seed, rec)
  local data = recoverScrollData(seed, { buff = rec.dwBuff })
  if data == nil then return nil end
  local _, scrollName = buildScrollParams(data, seed)
  scrollName = scrollName or "A tamed monster"
  if rec.state == "injured" then
    return scrollName .. " has been defeated and can be revived at Pepin."
  end
  if rec.state == "lostfull" then
    return "Inventory was full. " .. scrollName .. " sent to Pepin for recovery."
  end
  return scrollName .. " was Lost in the dungeon. Recover at Pepin."
end

-- Fallback only: copy the scroll back so the engine's ConsumeScroll (after the deploy hook) removes the original while the copy survives. For unpredictable spawn failures only.
function refundTameScroll(caster, data, scrollSeed)
  -- The scroll returns to the world, so its recovery backup must go: on the floor-fallback branch the
  -- seed is NOT in inventory, and a lingering "lost" entry would stock a DUPLICATE at Pepin.
  recoveryRegistry[scrollSeed] = nil
  local _, refundName, refundBuff, refundMod = buildScrollParams(data, scrollSeed)
  tameScrollData[scrollSeed] = data -- ensure session cache for the refunded scroll
  if not caster:addScrollByMapping(TAME_SCROLL_MAP, scrollSeed, refundName, refundBuff, refundMod) then
    local pos = caster.position
    placeScrollOnFloor(pos.x, pos.y, scrollSeed, refundName, refundBuff, refundMod)
  end
end

-- Plane-1 net sync: replicate a deployed ally onto same-level peers via mod-owned spawn over opaque "<TAG>|<args...>" pipe payloads (the keystone every cross-client behaviour reads from). NET stays `local` (part of the net layer).
local NET = {
  SPAWNALLY  = "SP",
  REQSYNC    = "RQ",
  DEPLOYREQ  = "DR",
  DEPLOYFAIL = "DF",
  COMBATOVR  = "CO",
  REMOVE     = "RM",
  SCROLLDATA = "SD",
  CAPTURE    = "CR",
  ENEMY      = "EN",
  APOCBOOMS  = "AB",
  ACTION     = "AT",
}

-- Sync model (vanilla parity, NO periodic re-asserts/heartbeat): pets follow the engine's PLAYER
-- model for combat — the owning client decides every discrete action and stat change and broadcasts
-- it as an immediate one-shot the tick it happens (SP/RM/CO/EN/AT/AB; remote copies never self-fire
-- and never resolve pet-involved damage) — and the engine's MONSTER model for movement (every client
-- simulates the walk/chase AI; the engine's own CMD_SYNCDATA converges residual position drift).
-- The pipe is reliable + in-order and RQ-on-level-entry rebuilds a joiner from scratch (the vanilla
-- "delta at join" analog), so one-shots are trusted: nothing is left for a heartbeat to carry.
DEPLOY_TIMEOUT_TICKS = 100 -- ~5s: how long a DR waits for its SP/DF echo before self-refunding
-- Session log of wild monsters we capture-removed, per delta level: [level][monsterId] = {x, y}.
-- Replayed as CRs to an RQ requester so a client whose delta missed the kill reaps the regenerated ghost.
capturedNaturalMonsters = {}

-- Broadcast an ally's full identity so same-level peers recreate it. `mask` answers one requester; `parentId` links a minion to its spawner (else nil/-1). No-op in SP.
local function broadcastSpawnAlly(monster, typeId, uniqueIdx, difficulty, owner, seed, mask, parentId)
  if not system.isMultiplayer() then return end
  local pos = monster.position
  local payload = table.concat(
    { NET.SPAWNALLY, monster.id, typeId, uniqueIdx, difficulty, pos.x, pos.y, seed, owner, parentId or -1 }, "|")
  luanet.send("hunter", payload, mask) -- mask nil => all other clients (luanet.send handles default + SP no-op)
end

-- Tell peers to despawn the monster at `monsterId` (an ally/minion we silently removed); myDeltaLevel travels so an off-level peer can invalidate its stale delta record for the slot. No-op in SP.
function broadcastRemove(monsterId)
  if not system.isMultiplayer() then return end
  luanet.send("hunter", table.concat({ NET.REMOVE, monsterId, myDeltaLevel }, "|"))
end

-- Tell same-level peers to remove a plain (non-golem) wild monster we removed locally as part of a tame conversion. level/x/y travel so an off-level peer can record the removal in that level's delta; typeId travels so a peer can apply species-specific quest credit (Diablo → difficulty kill credit) without a live monster to inspect.
local function broadcastCaptureRemove(monsterId, level, x, y, typeId)
  if not system.isMultiplayer() then return end
  luanet.send("hunter", table.concat({ NET.CAPTURE, monsterId, level, x, y, typeId }, "|"))
end

-- Announce a scroll's full identity blob keyed by seed (so a peer receiving it via trade restores from receivedBlobs). `level` = floor item's delta level, or nil/-1 for a held scroll. Blob is the LAST field (binary).
function broadcastScrollData(seed, level, mask)
  if not system.isMultiplayer() then return end
  local payload = table.concat({ NET.SCROLLDATA, level or -1, seed, blobForSeed(seed) }, "|")
  luanet.send("hunter", payload, mask) -- mask nil => all other clients (luanet.send handles default + SP no-op)
end

-- Broadcast one owned ally's final combat values + caster profile (the CO message). `mask` answers one requester (RQ); default = all same-level clients.
local function broadcastCombatOverride(entry, mask)
  if not system.isMultiplayer() then return end
  local m = entry.monster
  if m == nil then return end
  local prof = ownAllyProfile(entry)
  if prof == nil then return end
  -- OH name is the LAST field (free-form; may contain "|", so the receiver rest-captures it verbatim).
  local ohName = prof.ohName or "?"
  local payload = table.concat({
    NET.COMBATOVR, m.id, m.maxHealth, m.health, m.minDamage, m.maxDamage, m.toHit, m.armorClass,
    m.resistance, prof.isMinion and 1 or 0, prof.bonded and 1 or 0, prof.bondedImm, prof.baseMaxDamage,
    math.floor(prof.sharePct * 1000), prof.magicCurrent, prof.resFire, prof.resLight, prof.resMagic,
    prof.trnVariant or 0, prof.nearBonded and 1 or 0,
    prof.baseMinDamage, prof.baseToHit, prof.baseArmorClass, prof.baseMaxHp, prof.kills, prof.gamemode,
    prof.areaLevel, prof.ohId, ohName,
  }, "|")
  luanet.send("hunter", payload, mask) -- mask nil => all other clients (luanet.send handles default + SP no-op)
end

-- Broadcast CO for every deployed ally/minion (called after a recalc so peers stay current). Assigns the forward-declared local.
function broadcastAllCombatOverrides(mask)
  if not system.isMultiplayer() then return end
  for _, entry in ipairs(deployedAllies) do
    broadcastCombatOverride(entry, mask)
  end
end

-- Broadcast one owned ally's committed ranged fire (the AT message) so same-level peers render the
-- same missile. Single-writer: only the owner's client decides a fire (remote copies hold instead of
-- self-firing — the choose-action handlers), so peers see exactly the owner's shots, never their own
-- divergent ones. Sent from the missile-SPAWN chokepoint (OnGolemMissileDamage fires in AddMissile at
-- the attack frame), not at choose time, so a windup interrupted by stun/death broadcasts nothing.
function broadcastFireAction(monsterId, missileId, x, y)
  if not system.isMultiplayer() then return end
  luanet.send("hunter", table.concat({ NET.ACTION, monsterId, missileId, x, y }, "|"))
end

-- Shared final step of deploying an ally: golem-convert to `ownerId`, restore HP, track, back up for recovery, apply Bonded bonuses, recalc. doBroadcast = true for a local deploy (also SP-broadcasts), false for a requested one (SP already crossed).
function finishDeploy(monster, data, seed, ownerId, doBroadcast)
  -- Set max before current so the wounded current HP is applied against the correct maximum.
  monster:setMaxHitPoints(data.maxHp)
  monster:setHitPoints(data.savedHp)
  local entry = { monster = monster, seed = seed, capturedDifficulty = data.capturedDifficulty or 0 }
  trackDeployedAlly(entry)
  -- Back the ally up as "lost" the moment it deploys so a crash/quit still leaves a recoverable scroll.
  putRecovery(seed, recoveryDwBuffFromData(data), "lost")
  monster:makeGolem(ownerId)
  if doBroadcast then
    -- Replicate the ally onto same-level peers (Plane 1): species + identity so each peer recreates it locally.
    -- typeId from the LIVE monster, never data: a recovered UNIQUE scroll's data has no typeId
    -- (the seed's low bits carry the unique index instead — see allocSeed), and SP always needs
    -- the base species for the receiver's netSpawnAt.
    broadcastSpawnAlly(monster, monster.typeId, data.uniqueTypeIdx or -1, data.capturedDifficulty or 0, ownerId, seed)
  end
  -- Snapshot base stats; restore a prior-session Bonded ally's stored defensive bonus, then recalc the share-divided buff.
  snapshotAllyBase(entry)
  if isBonded(seed, monster.level) then
    rollBondedBonus(entry)
    rollBondedTrn(entry)   -- ensure an already-Bonded ally has its recolour (no-op if rolled)
    applyBondedBonus(entry)
    applyBondedGlow(entry) -- re-light an already-Bonded ally on redeploy
  end
  recalcAllyBuffs()
  tameScrollData[seed] = nil
end

-- Minion spawning is single-authority on the LEVEL OWNER (only it may allocate a monster slot); the ally's OWNER holds the minion's Plane-2 state (track + buff + CO). Peers recreate by species id.

-- The captured difficulty a tamed ally was tamed at (so its minions scale to match); falls back to the live game difficulty.
function allyCapturedDifficulty(ally)
  local entry = allyScratch(ally.id)
  if entry ~= nil and entry.capturedDifficulty ~= nil then return entry.capturedDifficulty end
  return monsters.currentDifficulty()
end

-- Owner-side bookkeeping for an already-spawned, already-golem-flagged minion: track + snapshot + bake the flat minion buff + broadcast CO. Does NOT broadcast SP. Called only on the minion's OWNER. `captured` = the parent's captured difficulty (kept on the entry so an RQ answer can re-SP the minion).
function adoptOwnMinion(minion, parentId, captured)
  local entry = { monster = minion, seed = nil, isMinion = true, parentId = parentId, capturedDifficulty = captured }
  trackDeployedAlly(entry)
  snapshotAllyBase(entry) -- after makeGolem, so golemToHit is set
  applyMinionBuff(entry)  -- minions don't draw from / divide the live pool and never recalc
  broadcastCombatOverride(entry)
  return entry
end

-- Called on the LEVEL OWNER after it spawns a minion for `parentAlly`: golem-flag to the parent's owner, SP-replicate, then adopt (if we're that owner) or track as a remote ally.
function registerSpawnedMinion(minion, parentAlly, captured)
  local ownerId  = parentAlly.ownerPlayerId
  local parentId = parentAlly.id
  minion:makeGolem(ownerId)
  -- SP: species recreate on peers; seed 0 (minions have none); parentId links it for cap-count + despawn.
  broadcastSpawnAlly(minion, minion.typeId, -1, captured, ownerId, 0, nil, parentId)
  local me = player.self()
  if me ~= nil and ownerId == me.id then
    adoptOwnMinion(minion, parentId, captured)
  else
    remoteAllies[minion.id] = { ownerId = ownerId, parentId = parentId, capturedDifficulty = captured }
  end
end

luanet.register("hunter", function(senderId, payload)
  local kind = payload:match("^(%u+)")

  if kind == NET.SPAWNALLY then
    local id, species, uniq, diff, x, y, seed, owner, parent =
        payload:match("^SP|(%-?%d+)|(%-?%d+)|(%-?%d+)|(%-?%d+)|(%-?%d+)|(%-?%d+)|(%-?%d+)|(%-?%d+)|(%-?%d+)$")
    if id == nil then return end
    -- Slot ids are PER-LEVEL: only act when the sender (owner) shares our active level.
    local sender = player.get(senderId)
    if sender == nil or not sender:isOnActiveLevel() then return end
    local ownerId = tonumber(owner)
    local mid = tonumber(id)
    local parentId = tonumber(parent)
    if parentId ~= nil and parentId < 0 then parentId = nil end
    -- Resolve the monster: keep an existing local copy when we already hold this ally (our own, or a
    -- remote one we already materialized and track — an RQ resend must be idempotent, not
    -- clobber-reinitialize a live copy's position/HP); otherwise (re)create at the agreed slot.
    local me = player.self()
    local m
    if me ~= nil and ownerId == me.id then
      m = monsters.fromId(mid)
    elseif remoteAllies[mid] ~= nil then
      local live = monsters.fromId(mid)
      if live ~= nil and live.isGolem and live.ownerPlayerId == ownerId then m = live end
    end
    if m == nil then
      m = monsters.netSpawnAt(mid, tonumber(species), tonumber(uniq),
        tonumber(diff), tonumber(x), tonumber(y))
      if m == nil then return end
    end
    if me ~= nil and ownerId == me.id and parentId == nil then
      -- OUR ally, spawned on our behalf by the level owner (non-owner deploy): complete the deferred local Plane-2 setup.
      local pending = pendingDeploys[tonumber(seed)]
      if pending ~= nil then
        finishDeploy(m, pending.data, tonumber(seed), me.id, false)
        pendingDeploys[tonumber(seed)] = nil
      else
        m:makeGolem(ownerId) -- no pending data (e.g. an RQ resend after we already finished): just own it
      end
    elseif me ~= nil and ownerId == me.id and parentId ~= nil then
      -- OUR minion, spawned on our behalf by the level owner: own it + do the owner-side bookkeeping (idempotent against an RQ/SP resend).
      m:makeGolem(ownerId)
      if not isDeployedAlly(mid) then adoptOwnMinion(m, parentId, tonumber(diff)) end
    else
      -- Another player's ally/minion: golem-flag it for the REMOTE owner (so faction/friendly-fire/hostility resolve here) and record it in remoteAllies so the shared AI runs locally.
      m:makeGolem(ownerId)
      local prev = remoteAllies
      [mid]                          -- an idempotent resend keeps the cached CO profile (no infobox blank until the next CO)
      remoteAllies[mid] = {
        ownerId = ownerId,
        parentId = parentId,
        capturedDifficulty = tonumber(diff),
        uniqueIdx = tonumber(uniq),  -- -1 for a normal ally; >= 0 picks the "no Lvl N" unique name form
        profile = (prev ~= nil and prev.ownerId == ownerId) and prev.profile or nil
      }
    end
  elseif kind == NET.REQSYNC then
    -- A client just entered a level: (re)send each of our deployed allies to it (the requester's SP handler validates the shared level).
    local me = player.self()
    if me == nil then return end
    local mask = 1 << senderId
    for _, entry in ipairs(deployedAllies) do
      local mon = entry.monster
      if mon ~= nil and not entry.isMinion and entry.seed ~= nil then
        local uniq = seedGetUniqueType(entry.seed) -- -1 if not unique
        broadcastSpawnAlly(mon, mon.typeId, uniq, entry.capturedDifficulty or 0, me.id, entry.seed, mask)
        broadcastCombatOverride(entry, mask)       -- follow the spawn with its combat values + caster profile
      elseif mon ~= nil and entry.isMinion then
        -- Minions resend too (seed 0, parentId links them) — the requester materializes them like a live minion spawn (a joiner must see the full deployed set, minions included).
        broadcastSpawnAlly(mon, mon.typeId, -1, entry.capturedDifficulty or 0, me.id, 0, mask, entry.parentId)
        broadcastCombatOverride(entry, mask)
      end
    end
    -- Also answer with the identity blob of every Tame Scroll we're holding, so the new Hunter has it cached for a trade.
    if me.className == HUNTER_CLASS then
      me:iterateInventory(function(item)
        if item:isScrollOf(TAME_ID) then broadcastScrollData(item.seed, nil, mask) end
      end)
    end
    -- Replay this level's capture removals to the requester (masked): if its delta missed a CR, the
    -- wild monster regenerated alive at its load — the live CR receive reaps it and re-records the kill.
    local requester = player.get(senderId)
    if requester ~= nil and requester:isOnActiveLevel() then
      local lvlCaptures = capturedNaturalMonsters[myDeltaLevel]
      if lvlCaptures ~= nil then
        for cmid, cpos in pairs(lvlCaptures) do
          -- typeId -1 on purpose: a replayed CR reaps the ghost but never carries Diablo kill credit (credit = presence at the LIVE tame only).
          luanet.send("hunter", table.concat({ NET.CAPTURE, cmid, myDeltaLevel, cpos.x, cpos.y, -1 }, "|"), mask)
        end
      end
    end
  elseif kind == NET.SCROLLDATA then
    -- A peer announced a scroll's blob (SD|level|seed|<blob>): cache it + its Original Trainer for a later trade; if a FLOOR item (level>=0), mirror it into that level's delta for late joiners. Blob is the last field (verbatim).
    local levelStr, seedStr, blob = payload:match("^SD|(%-?%d+)|(%d+)|(.*)$")
    local seed = tonumber(seedStr)
    if seed == nil or blob == nil then return end
    -- Last write wins, no freshness guard: every SD emitter builds its blob from live tables at send
    -- time, only the current holder of a seed ever announces it, and same-sender messages arrive in
    -- order — so a newer SD for a seed is by construction at least as fresh as the cached one.
    receivedBlobs[seed] = blob
    local _, _, _, _, _, ohId, ohName = decodeBlob(blob)
    if ohName ~= nil and ohName ~= "" then scrollOrigin[seed] = { name = ohName, id = ohId } end
    local level = tonumber(levelStr)
    if level ~= nil and level >= 0 then
      items.setItemDeltaModData(level, seed, blob)
      -- The floor copy landed BEFORE this SD (the item wire and the pipe share one in-order stream),
      -- so it was recreated and named WITHOUT the blob — a Bonded scroll reads "Tamed"/white on every
      -- non-dropper until pickup. Now that the blob is cached, restamp the live floor copy's
      -- name/tier. Hunter-only, mirroring OnCustomItemRecreated's visibility gate.
      local me = player.self()
      if me ~= nil and me.className == HUNTER_CLASS and TAME_ID ~= nil
          and level == items.currentDeltaLevel() then
        local floorItem = items.findFloorItemBySeed(seed)
        if floorItem ~= nil and floorItem:isScrollOf(TAME_ID) then
          restampScrollPresentation(floorItem)
        end
      end
    end
  elseif kind == NET.COMBATOVR then
    -- A remote ally's owner sent its final combat values + caster profile: apply the values to the live monster and cache the profile. Guarded on remoteAllies membership (never our own ally).
    local sender = player.get(senderId)
    if sender == nil or not sender:isOnActiveLevel() then return end
    -- Pull the 28 fixed leading fields positionally, then take everything after the 28th "|" as ohName verbatim (a player name may contain "|").
    local parts = {}
    local rest = payload
    for i = 1, 28 do
      local tok, tail = rest:match("^([^|]*)|(.*)$")
      if tok == nil then return end -- malformed: fewer than 28 delimiters
      parts[i] = tok
      rest = tail
    end
    parts[29] = rest -- free-form ohName, kept intact even if it contains "|"
    local id = tonumber(parts[2])
    local rec = remoteAllies[id]
    if rec == nil then return end -- not (yet) a tracked remote ally; the next CO/RQ will catch it
    local m = monsters.fromId(id)
    if m == nil then return end
    m:setMaxHitPoints(tonumber(parts[3]))
    m:setHitPoints(tonumber(parts[4]))
    m:setMinDamage(tonumber(parts[5]))
    m:setMaxDamage(tonumber(parts[6]))
    m:setToHit(tonumber(parts[7]))
    m:setArmorClass(tonumber(parts[8]))
    m:setResistance(tonumber(parts[9]))
    local prevProfile = rec.profile -- to detect a live Bonded promotion (nil on first CO = no replay)
    local newBonded = tonumber(parts[11]) == 1
    rec.profile = {
      isMinion       = tonumber(parts[10]) == 1,
      bonded         = newBonded,
      bondedImm      = tonumber(parts[12]),
      baseMaxDamage  = tonumber(parts[13]),
      sharePct       = tonumber(parts[14]) / 1000,
      magicCurrent   = tonumber(parts[15]),
      resFire        = tonumber(parts[16]),
      resLight       = tonumber(parts[17]),
      resMagic       = tonumber(parts[18]),
      trnVariant     = tonumber(parts[19]),
      nearBonded     = tonumber(parts[20]) == 1,
      baseMinDamage  = tonumber(parts[21]),
      baseToHit      = tonumber(parts[22]),
      baseArmorClass = tonumber(parts[23]),
      baseMaxHp      = tonumber(parts[24]),
      kills          = tonumber(parts[25]),
      gamemode       = tonumber(parts[26]),
      areaLevel      = tonumber(parts[27]),
      ohId           = tonumber(parts[28]),
      ohName         = parts[29],
    }
    -- Mirror the Bonded aura glow (idempotent); OnGetMonsterTRN paints the recolour from prof.trnVariant.
    if newBonded then m:setLightRadius(BONDED_LIGHT_RADIUS) end
    -- One-shot promotion Flash burst: only on the live false->true transition we witnessed (a fresh record never replays it).
    if prevProfile ~= nil and not prevProfile.bonded and newBonded then
      m:castFlashSelf()
    end
  elseif kind == NET.REMOVE then
    -- The sender removed one of its allies/minions; despawn our local copy. Self-validating: only acts on a monster golem-flagged to THIS sender (never our own ally or the vanilla Golem).
    local idStr, lvlStr = payload:match("^RM|(%-?%d+)|(%-?%d+)$")
    if idStr == nil then return end
    local id = tonumber(idStr)
    local m = monsters.fromId(id)
    if m == nil then
      -- No live copy (off-level or already gone): invalidate our stale delta record for the sender's level, else DeltaLoadMonsters ghosts the uninitialised slot at our next load (see bugs.md; trust model = the CR receiver's recordDeltaKill).
      monsters.removeDeltaSpawnedMonster(tonumber(lvlStr), id)
      remoteAllies[id] = nil
      return
    end
    if not (m.isGolem and m.ownerPlayerId == senderId) then return end
    if m.health <= 0 then return end -- death-RM about a copy our own sim already killed: our OnMonsterDeath invalidated the delta; leave the dying monster alone. (The binding is `health`, NOT hitPoints — a nil-compare here killed every RM for a live copy; see bugs.md.)
    m:remove()
    remoteAllies[id] = nil
  elseif kind == NET.CAPTURE then
    -- The sender tamed a wild monster (removed only on their client); reap it here too AND record the kill in that level's delta so it never regenerates. Never touch a golem-flagged monster (allies use RM).
    local id, level, x, y, typeId = payload:match("^CR|(%-?%d+)|(%-?%d+)|(%-?%d+)|(%-?%d+)|(%-?%d+)$")
    if id == nil then return end
    local mid = tonumber(id)
    local sender = player.get(senderId)
    local senderHere = sender ~= nil and sender:isOnActiveLevel()
    -- A Diablo capture is a quest kill ONLY for players standing on his level at the tame (user
    -- decision 2026-07-09, mirroring vanilla MP: PrepDoEnding credits only clients processing the
    -- level when he dies). The live CR arrives while the tamer stands there, so "sender shares our
    -- active level" = we were present. A REPLAYED CR carries typeId -1 (a replay is after the fact;
    -- presence at replay time earns nothing). Idempotent max. Quest STATE still arrives engine-side
    -- via NetSendCmdQuest (game-wide, exactly as a vanilla DiabloDeath broadcasts it).
    if tonumber(typeId) == DIABLO_TYPE_ID and senderHere then
      local me = player.self()
      if me ~= nil then me:creditDiabloKill() end
    end
    if senderHere then
      -- Same level: remove the live monster. removeAsKilled also records the delta_kill in our delta.
      -- hp > 0 guard: a REPLAYED CR (RQ answer) must only reap a live regenerated ghost, never touch a
      -- copy that is already dead/corpse-marked here (the kill applied fine).
      local m = monsters.fromId(mid)
      if m ~= nil and not m.isGolem and m.health > 0 then m:removeAsKilled() end
    else
      -- Off the captor's level: no live monster here, so just record the kill in that level's delta.
      monsters.recordDeltaKill(tonumber(level), mid, tonumber(x), tonumber(y))
    end
  elseif kind == NET.DEPLOYREQ then
    -- A non-owner asked us to spawn their ally (mirrors CMD_REQUESTSPAWNGOLEM: only the level owner spawns, keeping slot allocation single-authority).
    local me = player.self()
    -- Not ours to answer (the real level owner will); if NOBODY owns the level right now, the requester's pending-deploy timeout refunds the scroll.
    if me == nil or not me:isLevelOwnedByLocalClient() then return end
    local typeId, uniq, diff, x, y, seed, maxHp, savedHp =
        payload:match("^DR|(%-?%d+)|(%-?%d+)|(%-?%d+)|(%-?%d+)|(%-?%d+)|(%-?%d+)|(%-?%d+)|(%-?%d+)$")
    if typeId == nil then return end
    -- We ARE the level owner: the requester's scroll is already consumed, so every rejection from here
    -- MUST answer DF (a silent return voids the scroll until the timeout catches it).
    local function deployFail()
      luanet.send("hunter", NET.DEPLOYFAIL .. "|" .. seed, 1 << senderId)
    end
    local sender = player.get(senderId)
    if sender == nil or not sender:isOnActiveLevel() then
      deployFail() -- e.g. our view of the requester's level lags its arrival
      return
    end
    local uniqIdx = tonumber(uniq)
    -- Owner-authoritative mirror of the REQUESTER's deploy gates (its own tracking can lag, e.g. an
    -- earlier SP echo it never processed): one instance of a unique PER Hunter + the per-Hunter cap,
    -- both counted over the REQUESTER's pets only (our own and other Hunters' pets don't constrain it).
    local senderAllies = 0
    local senderHasUnique = false
    for _, rec in pairs(remoteAllies) do
      if rec.ownerId == senderId then
        if rec.parentId == nil then senderAllies = senderAllies + 1 end
        if uniqIdx >= 0 and rec.uniqueIdx == uniqIdx then senderHasUnique = true end
      end
    end
    if senderHasUnique or senderAllies >= MAX_ALLIES then
      deployFail()
      return
    end
    local d = tonumber(diff)
    local m
    if uniqIdx >= 0 then
      m = monsters.spawnUniqueAt(uniqIdx, d, tonumber(x), tonumber(y))
    else
      m = monsters.spawnWithDifficulty(tonumber(typeId), d, tonumber(x), tonumber(y))
    end
    if m == nil then
      -- Couldn't place it (no free tile / pool full). Tell the requester so it refunds the scroll.
      deployFail()
      return
    end
    -- Owner is HP-authoritative: apply the requester's persisted HP, which then syncs to all clients.
    m:setMaxHitPoints(tonumber(maxHp))
    m:setHitPoints(tonumber(savedHp))
    m:makeGolem(senderId) -- owned by the requester, not us
    -- Someone else's ally; runs its AI locally too. Record the same identity fields the SP receiver
    -- stores (difficulty/unique drive the local infobox + minion scaling until the CO arrives).
    remoteAllies[m.id] = { ownerId = senderId, capturedDifficulty = d, uniqueIdx = uniqIdx }
    -- Broadcast to all other same-level clients (incl. the requester, who materialises it + completes its deferred setup in the SP handler).
    -- typeId from the LIVE monster: the DR wire carries -1 for a unique (a recovered unique scroll has no typeId), but SP always needs the real species.
    broadcastSpawnAlly(m, m.typeId, uniqIdx, d, senderId, tonumber(seed))
  elseif kind == NET.DEPLOYFAIL then
    -- The level owner could not place an ally we requested — refund the scroll the engine already consumed.
    local seedStr = payload:match("^DF|(%-?%d+)$")
    if seedStr == nil then return end
    local seed = tonumber(seedStr)
    local pending = pendingDeploys[seed]
    if pending == nil then return end
    pendingDeploys[seed] = nil
    local me = player.self()
    if me ~= nil then refundTameScroll(me, pending.data, seed) end
  elseif kind == NET.ACTION then
    -- The owner's client committed one of its allies' ranged fires (single-writer): recreate the same
    -- missile here. fireMissileAt spawns without touching the copy's mode, so it is safe mid-walk.
    -- Damage authority is unchanged — vs monsters our OnMonsterMissileHit declines on non-authority
    -- clients; vs players the missile MUST exist here (player damage resolves on the victim's own
    -- client). Same guards as RM/CO/AB: sender on our level, monster golem-flagged to THAT sender.
    local idStr, midStr, xStr, yStr = payload:match("^AT|(%-?%d+)|(%-?%d+)|(%-?%d+)|(%-?%d+)$")
    if idStr == nil then return end
    local sender = player.get(senderId)
    if sender == nil or not sender:isOnActiveLevel() then return end
    local id = tonumber(idStr)
    if remoteAllies[id] == nil then return end
    local m = monsters.fromId(id)
    if m == nil or not m.isGolem or m.ownerPlayerId ~= senderId then return end
    if m.health <= 0 then return end
    m:fireMissileAt(tonumber(midStr), tonumber(xStr), tonumber(yStr))
  elseif kind == NET.ENEMY then
    -- The owner broadcast one of its allies' current enemy (engine wire encoding; -1 = none). A
    -- golem's MONSTER target latches engine-side (GolumAi re-seeks only when it has none), so a single
    -- transiently-divergent pick would stick on a peer forever — converge on the owner's view instead.
    -- Same guards as RM/CO: sender on our level, acting only on a monster golem-flagged to THAT sender.
    local idStr, encStr = payload:match("^EN|(%-?%d+)|(%-?%d+)$")
    if idStr == nil then return end
    local sender = player.get(senderId)
    if sender == nil or not sender:isOnActiveLevel() then return end
    local id = tonumber(idStr)
    if remoteAllies[id] == nil then return end
    local m = monsters.fromId(id)
    if m == nil or not m.isGolem or m.ownerPlayerId ~= senderId then return end
    if m.health <= 0 then return end
    local enc = tonumber(encStr)
    m:setEncodedEnemy(enc >= 0 and enc or nil)
  elseif kind == NET.APOCBOOMS then
    -- The owner's client fanned a multi-target Apocalypse (spreadDiabloApocalypse): recreate the same
    -- extra booms here so every client shows one boom set. Damage stays single-resolver: vs monsters
    -- our OnMonsterMissileHit declines on non-authority clients (the owner's roll arrives via the
    -- engine's CMD_MONSTDAMAGE broadcast); vs players the boom MUST exist here, because player damage
    -- resolves on the victim's own client (vanilla PlayerMHit semantics).
    local idStr, list = payload:match("^AB|(%-?%d+)|(.*)$")
    if idStr == nil then return end
    local sender = player.get(senderId)
    if sender == nil or not sender:isOnActiveLevel() then return end
    local id = tonumber(idStr)
    if remoteAllies[id] == nil then return end
    local m = monsters.fromId(id)
    if m == nil or not m.isGolem or m.ownerPlayerId ~= senderId then return end
    for x, y in list:gmatch("(%-?%d+),(%-?%d+)") do
      m:fireMissileAt(monsters.MissileID.DiabloApocalypseBoom, tonumber(x), tonumber(y))
    end
  end
end)

-- NOTE: we deliberately do NOT register an OnGolemCanRunAI handler — a tamed ally's AI now runs on EVERY client (the per-tick hooks below are written to behave identically on owner and peers).

-- On entering a level, ask same-level ally owners to (re)send their deployed allies (so a late joiner materialises them). Clears stale per-level remote-ally tracking first. Fires for everyone in MP; no-op in SP.
events.OnLevelEnter.add(function()
  myDeltaLevel = items.currentDeltaLevel() -- valid here (plrlevel = this level); consumed by broadcastRemove
  remoteAllies = {}
  -- A deploy request in flight across a level change is stale (slot ids are per-level) — but its scroll
  -- was already consumed, so REFUND rather than drop (a late SP/DF for it is harmlessly ignored:
  -- pendingDeploys no longer holds the seed, and the SP receiver validates the shared level).
  local me = player.self()
  for seed, pending in pairs(pendingDeploys) do
    if me ~= nil then refundTameScroll(me, pending.data, seed) end
  end
  pendingDeploys = {}
  if not system.isMultiplayer() then return end
  luanet.send("hunter", NET.REQSYNC)
end)

-- OnSpellActionFrame (Tame skill + scroll): fires at the mid-animation release frame, so the effect syncs with the animation.
events.OnSpellActionFrame.add(function(caster, spellId, spellType, target, scrollSeed, targetX, targetY)
  if spellId ~= TAME_ID then return end
  local self = player.self()
  if self == nil or caster.id ~= self.id then return end

  -- ---- Scroll cast (spellType == 2): deploy the stored tamed monster ----
  if spellType == 2 then
    -- scrollSeed identifies the exact scroll item that was right-clicked.
    if scrollSeed == nil or scrollSeed == 0 then return end

    local data = tameScrollData[scrollSeed]
    local scrollItem = caster:findScrollBySeed(scrollSeed)
    if data == nil then
      -- Session data lost (game restart). Recover from seed+dwBuff encoding.
      if scrollItem == nil then return end -- scroll not in inventory; nothing to refund
      data = recoverScrollData(scrollSeed, scrollItem)
      if data == nil then
        -- dwBuff is zeroed or corrupt — can't determine what to spawn.
        -- Refund by copying the scroll before ConsumeScroll removes it.
        if not caster:addScrollByMapping(TAME_SCROLL_MAP, scrollSeed, scrollItem.name, scrollItem.buff, scrollItem.modData) then
          local pos = caster.position
          placeScrollOnFloor(pos.x, pos.y, scrollSeed, scrollItem.name, scrollItem.buff, scrollItem.modData)
        end
        return
      end
    end
    -- Cap / duplicate-unique limits are normally blocked upfront in OnCanCastScroll; these are last-resort refund nets for any path that bypasses it (e.g. a hotkey cast). Pending DR requests count as deployed (see countPendingDeploys).
    if countDeployedAllies() + countPendingDeploys() >= MAX_ALLIES then
      refundTameScroll(caster, data, scrollSeed)
      caster:say(player.HeroSpeech.ICantDoThat)
      return
    end
    if (data.uniqueTypeIdx ~= nil and isUniqueTypeDeployed(data.uniqueTypeIdx))
        or (seedIsDiablo(scrollSeed) and isDiabloDeployed()) then
      refundTameScroll(caster, data, scrollSeed)
      caster:say(player.HeroSpeech.ICantDoThat)
      return
    end

    -- Spawn at the cursor's targeted tile; fall back to caster's feet if no position given.
    local spawnX = targetX or caster.position.x
    local spawnY = targetY or caster.position.y
    local capturedDifficulty = data.capturedDifficulty or 0

    -- Spawning is level-owner-authoritative. If we are NOT the level owner, mirror the base Golem spell: send a DR so the owner spawns on our behalf, then completes here via the SP echo (deferred Plane-2 setup).
    if system.isMultiplayer() and not self:isLevelOwnedByLocalClient() then
      -- tick stamps the request: if no SP/DF echo ever arrives (no live level owner, lost message), the GameTick timeout self-refunds the consumed scroll.
      pendingDeploys[scrollSeed] = { data = data, tick = system.gameTick() }
      -- Back the consumed scroll up the MOMENT it leaves inventory, not at echo completion: a
      -- quit/exit inside the SP/DF round trip saves the post-consumption inventory while the
      -- runtime-only pendingDeploys dies with the session — the persisted registry is the only
      -- thing that keeps the scroll recoverable (free at Pepin) next session. A completed deploy
      -- overwrites this same entry (finishDeploy); every refund path deletes it (refundTameScroll).
      putRecovery(scrollSeed, recoveryDwBuffFromData(data), "lost")
      luanet.send("hunter", table.concat(
        { NET.DEPLOYREQ, data.typeId or -1, data.uniqueTypeIdx or -1, capturedDifficulty, spawnX, spawnY,
          scrollSeed, data.maxHp, data.savedHp }, "|"))
      -- The engine removes the scroll after this hook; if the owner can't place the ally it echoes DF and we refund.
      tameScrollData[scrollSeed] = nil
      return
    end

    local newMonster
    if data.uniqueTypeIdx ~= nil then
      newMonster = monsters.spawnUniqueAt(data.uniqueTypeIdx, capturedDifficulty, spawnX, spawnY)
    else
      newMonster = monsters.spawnWithDifficulty(data.typeId, capturedDifficulty, spawnX, spawnY)
    end
    if newMonster == nil then
      -- Genuine spawn failure (no free tile / pool full / type table full) — we ARE the level owner, so this is the legitimate refund fallback (not knowable before the cast).
      refundTameScroll(caster, data, scrollSeed)
      return
    end

    -- We are the level owner: spawn done locally, so finishDeploy with doBroadcast = true.
    finishDeploy(newMonster, data, scrollSeed, caster.id, true)
    return
  end

  -- ---- Skill use (spellType == 0) ----
  if spellType ~= 0 then return end
  if target == nil then return end

  -- ---- Retame: casting Tame on your own deployed ally recalls it to inventory ----
  if isDeployedAlly(target.id) then
    for i = #deployedAllies, 1, -1 do
      if deployedAllies[i].id == target.id then
        -- Minions have no scroll and cannot be recalled — casting Tame on one does nothing.
        if deployedAllies[i].isMinion then return end
        -- Recalling a parent despawns the minions it spawned (they cannot outlive it).
        removeMinionsOfParent(target.id)
        -- Manual retame: recall the scroll into inventory (never the floor). Refresh the backup first; a clean recall deletes it, a full inventory keeps it as "lostfull" (recovered at Pepin).
        local seed = deployedAllies[i].seed
        refreshRecoveryEntry(deployedAllies[i])
        if recallAllyToInventory(target, deployedAllies[i], caster) then
          recoveryRegistry[seed] = nil
        else
          local rec = recoveryRegistry[seed]
          if rec ~= nil then
            rec.state = "lostfull"
            local line = recoveryMessageFor(seed, rec)
            if line ~= nil then message(line) end
          end
        end
        untrackDeployedAt(i)
        recalcAllyBuffs() -- the deployed count dropped; survivors re-absorb the freed buff share
        return
      end
    end
    return -- defensive: tracked id missing from the list (should not happen)
  end

  -- Tame never CAPTURES a player-minion. Our own ally is the retame above; any OTHER golem —
  -- another Hunter's deployed ally or a vanilla Golem — is not a wild monster and must not enter
  -- the capture path: it would remove the local copy while the CR receiver's golem guard rightly
  -- protects every peer's copy (split existence), and mint a duplicate scroll from a live pet
  -- (a redeployed pet is wounded, so it sails under the capture-HP gate). Observed as the Diablo
  -- duplication bug (bugs.md 2026-07-09).
  if target.isGolem then
    caster:say(player.HeroSpeech.ICantDoThat)
    return
  end

  -- A monster at 0 HP (dead / mid death-anim) must never be captured: its synced death would race the conversion into a ghost + a scroll minted from a corpse. The HP-percent gate reads it as 0% (easiest tame), so veto explicitly here.
  if target.hasNoLife then return end

  -- Capture: tame a monster that passes BOTH the active tier's mlvl/category gate AND the category's capture-HP threshold.
  local clvl     = caster.characterLevel
  local mlvl     = target.level
  local tier     = tameTier(clvl)
  local category = categoryFromTarget(target)

  -- mlvl/category gate: an out-of-criteria monster can never be tamed, regardless of HP.
  if not mlvlGateAllows(tier, category, clvl, mlvl) then return end

  -- Capture-HP threshold: keyed by category, applies at every tier.
  local hpPercent = (target.health / target.maxHealth) * 100
  if hpPercent > categoryHpThreshold(category) then return end

  local uType = target.uniqueType
  local monsterData = {
    typeId             = target.typeId,
    savedHp            = target.health,
    maxHp              = target.maxHealth,
    name               = target.name,
    level              = target.level,
    uniqueTypeIdx      = uType >= 0 and uType or nil,
    capturedDifficulty = monsters.currentDifficulty(),
  }
  local pos = target.position
  local capturedId = target.id -- capture before remove() so peers can despawn the same wild monster

  -- Taming a quest monster clears its quest exactly as if killed (state + death speech; Diablo → quest done + difficulty kill credit WITHOUT the game-ending sequence); no-op otherwise. Called before remove() while type/uniqueType are intact.
  target:checkQuestKill()

  -- removeAsKilled (not remove): a wild monster is level-natural, so it must be recorded as killed in the MP delta, else a later loader regenerates it as a live ghost.
  local capturedLevel = items.currentDeltaLevel()                                     -- captor's level, for off-level peers' delta records
  target:removeAsKilled()
  broadcastCaptureRemove(capturedId, capturedLevel, pos.x, pos.y, monsterData.typeId) -- peers reap the wild monster (live or via delta)
  -- Log the capture for this level (session-lifetime): the RQ answer replays it as a CR so a client whose delta missed the kill reaps the regenerated ghost live.
  local lvlCaptures = capturedNaturalMonsters[capturedLevel]
  if lvlCaptures == nil then
    lvlCaptures = {}
    capturedNaturalMonsters[capturedLevel] = lvlCaptures
  end
  lvlCaptures[capturedId] = { x = pos.x, y = pos.y }

  -- Stamp the taming Hunter as the monster's permanent Original Trainer (name + OHID).
  dropTameScroll(monsterData, pos.x, pos.y, { name = caster.name, id = getMyOhId() })
end)

-- applySharePotion: scan the caster's inventory for a health potion, consume it (unless a level-scaled freecast procs), and heal the target ally. Returns true if a potion fired.
function applySharePotion(caster, target)
  local maxHp     = target.maxHealth
  local currentHp = target.health

  if currentHp >= maxHp then
    caster:say(player.HeroSpeech.IDontNeedToDoThat)
    return false
  end

  -- Detect a usable health potion by its EFFECT (miscId), not its base item index; capture the matched IDidx so we remove that exact base type after a share.
  local potionType  = nil
  local potionIDidx = nil
  caster:iterateInventory(function(item)
    if potionType then return end
    if item.miscId == items.ItemMiscID.FullHeal then
      potionType  = "full"
      potionIDidx = item.IDidx
    elseif item.miscId == items.ItemMiscID.Heal then
      potionType  = "partial"
      potionIDidx = item.IDidx
    end
  end)

  local level    = caster.characterLevel
  local freecast = math.random(100) <= level + 10 -- clvl% : potion not consumed
  local overheal = math.random(100) <= level + 10 -- (clvl+10)% : heal to 150% maxHP

  -- The heal is an owner-side HP write peers never simulate — broadcast the CO (absolute HP) the
  -- moment it happens, like every other owner-side mutation (never wait for anything periodic).
  local function healTo(hp)
    target:setHitPoints(hp)
    local entry = getDeployedAllyEntry(target.id)
    if entry ~= nil then broadcastCombatOverride(entry) end
    audio.playSfx(audio.SfxID.ItemPotion)
  end

  if potionType == "full" then
    if not freecast then caster:removeItem(potionIDidx, 1) end
    healTo(overheal and math.floor(maxHp * 1.5) or maxHp)
    return true
  elseif potionType == "partial" then
    if not freecast then caster:removeItem(potionIDidx, 1) end
    healTo(overheal and math.floor(maxHp * 1.5) or math.min(currentHp + math.floor(maxHp * 0.3), maxHp))
    return true
  else
    caster:say(player.HeroSpeech.ICantDoThat)
    return false
  end
end

-- OnSpellActionFrame (Share Potion skill): enter CURSOR_HEALOTHER targeting mode; the actual heal fires in OnCursorMonsterTarget when the player clicks an ally.
events.OnSpellActionFrame.add(function(caster, spellId, spellType, target, scrollSeed, targetX, targetY)
  if spellId ~= SHARE_POTION_ID then return end
  local self = player.self()
  if self == nil or caster.id ~= self.id then return end
  if spellType ~= 0 then return end -- skill casts only
  caster:enterHealOtherMode()
end)

-- OnCanSelectMonsterWithCursor: allow pcursmonst to be set in CURSOR_HEALOTHER mode so the player can click a deployed ally.
events.OnCanSelectMonsterWithCursor.add(function(cursorId)
  if cursorId == player.CursorID.CURSOR_HEALOTHER then return true end
end)

-- OnCursorMonsterTarget: apply Share Potion to a clicked ally. Returns true (dismiss cursor) for any valid ally regardless of potion availability; nil (cursor stays) for invalid targets.
events.OnCursorMonsterTarget.add(function(monster)
  local self = player.self()
  if self == nil then return end
  for _, entry in ipairs(deployedAllies) do
    if entry.monster == monster then
      applySharePotion(self, monster)
      return true
    end
  end
  -- Invalid target (enemy); cursor stays active for retry.
end)

-- OnItemUsed (Potion of Forgetting): reset all base stats to class starting values, refunding invested points. All classes. Identified by FullRejuv miscId + FORGET_POTION_ID spellId.
events.OnItemUsed.add(function(p, miscId, spellId)
  if miscId ~= items.ItemMiscID.FullRejuv then return end
  if spellId ~= FORGET_POTION_ID then return end
  local self = player.self()
  if self == nil or p.id ~= self.id then return end

  local startStr, startMag, startDex, startVit = p:classBaseStats()
  p:resetStats(startStr, startMag, startDex, startVit)
end)

-- OnGetMiscItemDescription: override the Potion of Forgetting's info box (its FullRejuv miscId would show "restore all life and mana").
events.OnGetMiscItemDescription.add(function(item)
  if item.miscId ~= items.ItemMiscID.FullRejuv then return nil end
  if item.name ~= "Potion of Forgetting" then return nil end
  return "Resets All Stats\nItem Lost on Game Exit"
end)

-- Potion of Forgetting: stash exclusion + session-only persistence.

function isForgetPotion(item)
  return item.miscId == items.ItemMiscID.FullRejuv and item.name == "Potion of Forgetting"
end

-- OnItemAllowedInStash: keep mod items out of the normal stash (the potion must never persist; Tame Scrolls must never land in a base-game-loadable stash).
events.OnItemAllowedInStash.add(function(item)
  if isForgetPotion(item) then return false end
  if item:isScrollOf(TAME_ID) then return false end
  return nil
end)

-- Every writable Item field, so a popped item can be put back byte-for-byte into its exact slot (name/iName copied separately).
ITEM_STATE_FIELDS = {
  "seed", "createInfo", "type", "animFlag", "delFlag", "selectionRegion", "postDraw",
  "identified", "magical", "loc", "class", "curs", "value", "ivalue", "minDam", "maxDam",
  "AC", "flags", "miscId", "spell", "IDidx", "charges", "maxCharges", "durability", "maxDur",
  "PLDam", "PLToHit", "PLAC", "PLStr", "PLMag", "PLDex", "PLVit", "PLFR", "PLLR", "PLMR",
  "PLMana", "PLHP", "PLDamMod", "PLGetHit", "PLLight", "splLvlAdd", "request", "uid",
  "fMinDam", "fMaxDam", "lMinDam", "lMaxDam", "PLEnAc", "prePower", "sufPower",
  "vAdd1", "vMult1", "vAdd2", "vMult2", "minStr", "minMag", "minDex", "statFlag",
  "damAcFlags", "buff", "modData",
}

function restoreItemState(dst, src)
  for _, f in ipairs(ITEM_STATE_FIELDS) do dst[f] = src[f] end
  dst.name = src.name
  dst.iName = src.iName
end

-- OnBeforeSaveHero / OnAfterSaveHero: bracket the hero-file write so the Potion of Forgetting is absent from the serialised data, then restored to the live inventory in its exact slot (so it never survives into a new game).
events.OnBeforeSaveHero.add(function()
  local me = player.self()
  if me == nil then return end
  local snap = nil
  me:iterateInventory(function(item)
    if isForgetPotion(item) then
      snap = snap or {}
      snap[#snap + 1] = { ref = item, saved = item:pop() }
    end
  end)
  forgetPotionSnapshot = snap
end)

events.OnAfterSaveHero.add(function()
  if forgetPotionSnapshot == nil then return end
  for _, e in ipairs(forgetPotionSnapshot) do
    restoreItemState(e.ref, e.saved)
  end
  forgetPotionSnapshot = nil
end)

-- Rebuild a Tame Scroll's display name + quality from its seed + the CURRENT tables. Shared by
-- OnCustomItemRecreated (pfile/delta round-trip) and OnItemPickedUp (after the re-key restores the
-- kill count, the name/gold must be re-derived or a traded Bonded scroll keeps reading "Tamed").
function restampScrollPresentation(item)
  local uIdx = seedGetUniqueType(item.seed)
  local bonded = scrollIsBonded(item)
  local prefix = bonded and "Bonded" or "Tamed"
  local scrollName
  if uIdx >= 0 or seedIsDiablo(item.seed) then
    local monsterName = (uIdx >= 0) and monsters.getUniqueName(uIdx) or monsters.getNameByTypeId(DIABLO_TYPE_ID)
    if monsterName == nil then return end
    scrollName = prefix .. " " .. monsterName
    item.magical = 2 -- ITEM_QUALITY_UNIQUE → gold text + outline
  else
    local typeId = seedToTypeId(item.seed)
    if typeId == nil then return end
    local _, _, level = decodeDwBuff(item.buff)
    local monsterName = monsters.getNameByTypeId(typeId)
    if monsterName == nil then return end
    scrollName = prefix .. " Lvl " .. level .. " " .. monsterName
    if bonded then item.magical = 2 end -- Bonded normal scrolls render at gold tier too
  end
  item.name  = scrollName
  item.iName = scrollName
end

-- OnCustomItemRecreated: restore the dynamic scroll name after a pfile/delta round-trip (fires from RecreateItem after InitializeItem resets the name to the base "Tame Scroll").
events.OnCustomItemRecreated.add(function(item)
  if not item:isScrollOf(TAME_ID) then return end
  -- Non-Hunter visibility gate: a non-Hunter sees only the generic base name, never the encoded one (display-only, no state mutation).
  local me = player.self()
  if me == nil or me.className ~= HUNTER_CLASS then return end
  restampScrollPresentation(item)
end)

-- Speedbook: inject one entry per unique Tame Scroll name held in inventory (deduped by display name; count = how many of that name).
events.OnGetCustomSpeedbookScrollEntries.add(function(p)
  if not isMyPlayer(p) then return nil end
  local seen  = {} -- name → { seed, count }
  local order = {} -- insertion-order list of names
  p:iterateInventory(function(item)
    if not item:isScrollOf(TAME_ID) then return end
    -- Skip scrolls outside the current tier criteria (they carry iSkipSpeedbook, so filter at injection).
    if not scrollPassesTierGate(p, item.seed, item.buff) then return end
    local name = item.name
    if not seen[name] then
      seen[name] = { seed = item.seed, buff = item.buff, count = 0 }
      table.insert(order, name)
    end
    seen[name].count = seen[name].count + 1
  end)
  if #order == 0 then return nil end
  local result = {}
  for _, name in ipairs(order) do
    local e = seen[name]
    -- Names already carry the full "Tamed/Bonded [Lvl N] [Name]" form; use as-is so the entry matches the item box.
    table.insert(result, { name = name, seed = e.seed, spell = TAME_ID, count = e.count })
  end
  return result
end)

-- Speedbook: resolve a Tame scroll cast to the EXACT scroll selected (all share TAME_ID, so the engine's "first match" can pick the wrong one), so deploy + ConsumeScroll agree.
events.OnResolveCustomScrollSlot.add(function(p, spellId, selectedSeed, defaultSlot)
  if not isMyPlayer(p) then return nil end
  if spellId ~= TAME_ID then return nil end
  if selectedSeed == nil or selectedSeed == 0 then return nil end

  -- Exact match: the precise scroll the player selected.
  local slot = p:findScrollSlotBySeed(selectedSeed)
  if slot ~= nil then return slot end

  -- The selected scroll is gone (e.g. recasting a same-name stack): fall back to any held scroll of the same type / unique index.
  local wantUidx = seedGetUniqueType(selectedSeed)
  local wantType = seedToTypeId(selectedSeed)
  local fallbackSeed = nil
  p:iterateInventory(function(item)
    if fallbackSeed ~= nil then return end
    if not item:isScrollOf(TAME_ID) then return end
    local s = item.seed
    if wantUidx >= 0 then
      if seedGetUniqueType(s) == wantUidx then fallbackSeed = s end
    elseif seedGetUniqueType(s) < 0 and seedToTypeId(s) == wantType then
      fallbackSeed = s
    end
  end)
  if fallbackSeed ~= nil then return p:findScrollSlotBySeed(fallbackSeed) end
  return nil
end)

-- Block a Tame scroll cast UPFRONT (before the engine consumes it) for limits knowable in advance: the ally cap + deploying a second copy of a unique already out. selectedSeed 0 (hotkey cast) defers the unique check to OnSpellActionFrame.
events.OnCanCastScroll.add(function(p, spellId, selectedSeed, target)
  if not isMyPlayer(p) then return nil end
  if spellId ~= TAME_ID then
    -- Any non-Tame (offensive) scroll must never be cast at our own ally / a friendly Hunter's pet (same misclick protection as a direct attack).
    if isProtectedFromOffense(p, target) then return false end
    return nil
  end

  if countDeployedAllies() + countPendingDeploys() >= MAX_ALLIES then
    p:say(player.HeroSpeech.ICantDoThat)
    return false
  end

  -- Determine which scroll will actually be cast: the selected entry, or (selectedSeed 0 = hotkey) the first Tame scroll — the same first-match the deploy path resolves to.
  local seed = selectedSeed
  if seed == nil or seed == 0 then
    p:iterateInventory(function(item)
      if seed ~= nil and seed ~= 0 then return end
      if item:isScrollOf(TAME_ID) then seed = item.seed end
    end)
  end

  if seed ~= nil and seed ~= 0 then
    local uIdx = seedGetUniqueType(seed)
    -- One-per-Hunter rule: uniques by unique index, Diablo by seed type (he isn't unique).
    if (uIdx >= 0 and isUniqueTypeDeployed(uIdx)) or (seedIsDiablo(seed) and isDiabloDeployed()) then
      p:say(player.HeroSpeech.ICantDoThat)
      return false
    end
    -- Tier gate (belt-and-suspenders): refuse a scroll outside the current tier criteria, backing up the inventory-red / speedbook-hide. Not consumed on refusal.
    local scrollItem = p:findScrollBySeed(seed)
    if scrollItem ~= nil and not scrollPassesTierGate(p, seed, scrollItem.buff) then
      p:say(player.HeroSpeech.ICantDoThat)
      return false
    end
  end

  return true
end)

-- Block a Tame SKILL cast UPFRONT when the cursor-targeted monster fails the active tier's mlvl/category gate (the hard targeting veto, HP-independent). The in-cast HP threshold still governs an in-category target.
events.OnCanCastSkill.add(function(p, spellId, target)
  if not isMyPlayer(p) then return nil end
  if spellId ~= TAME_ID then return nil end
  if target == nil then return nil end
  -- A golem/minion target: our OWN deployed ally/minion is a valid cast (recall / no-op), so allow.
  -- Any OTHER golem is never capturable — refuse upfront (the action-frame isGolem veto is the
  -- authoritative backstop; it stops the capture path that split existence + minted a duplicate
  -- scroll from a live pet — bugs.md 2026-07-09): another Hunter's ally is a pet, not a wild
  -- monster; the vanilla Golem stays vanilla (never captured/converted — the barometer); and a
  -- Berserk'd monster is PERMANENTLY untameable by design — AddBerserk sets MFLAG_BERSERK|MFLAG_GOLEM
  -- for life (never cleared), mutates its damage stats, and CheckMissileCol lets any monster missile
  -- hit a MFLAG_BERSERK target regardless of faction, so a tamed ex-berserk would be a permanently
  -- friendly-fire-hittable pet (see hunter_class_design.md "Untameable targets").
  if target.isGolem then
    if isDeployedAlly(target.id) then return nil end
    p:say(player.HeroSpeech.ICantDoThat)
    return false
  end

  local clvl     = p.characterLevel
  local mlvl     = target.level
  local tier     = tameTier(clvl)
  local category = categoryFromTarget(target)

  if not mlvlGateAllows(tier, category, clvl, mlvl) then
    p:say(player.HeroSpeech.ICantDoThat)
    return false
  end
  return nil -- in-criteria: allow (HP threshold is enforced in-cast).
end)

-- Exempt Tame scrolls from Auto Refill Belt (all share TAME_ID, so refill would redirect a belt cast to the wrong scroll). false keeps the selected belt slot.
events.OnCanAutoRefillBeltItem.add(function(p, item)
  if not isMyPlayer(p) then return nil end
  if item:isScrollOf(TAME_ID) then return false end
  return nil
end)

-- Speedbook: revert Scroll entries sharing TAME_ID with the starting Tame skill back to Scroll type after the starting-skill promotion fires.
events.OnGetSpeedbookSelectionType.add(function(p, spellId, originalType, promotedType)
  if not isMyPlayer(p) then return nil end
  if spellId ~= TAME_ID then return nil end
  if originalType == "Scroll" and promotedType == "Skill" then return "Scroll" end
  return nil
end)

-- Speedbook: show "Tame+"/"Tame++"/"Tame+++" to reflect the unlocked tame tier (clvl 20/35/45).
events.OnGetSpeedbookSpellName.add(function(p, spellId, defaultName)
  if not isMyPlayer(p) then return nil end
  if spellId ~= TAME_ID then return nil end
  local tier = tameTier(p.characterLevel)
  if tier == 3 then return "Tame+++" end
  if tier == 2 then return "Tame++" end
  if tier == 1 then return "Tame+" end
  return nil
end)

-- OnLevelExit: auto-recall all deployed allies to inventory (normal transitions + player death). A full inventory keeps the ally as a "lost" recovery backup; no floor drop.
events.OnLevelExit.add(function()
  local owner = player.self()
  for i = #deployedAllies, 1, -1 do
    local entry = deployedAllies[i]
    if entry.isMinion then
      -- Minions are not recalled (no scroll); RM-broadcast so peers despawn this one (the owner leaving won't reap it for them).
      broadcastRemove(entry.monster.id)
      untrackDeployedAt(i)
    else
      -- Recall to inventory (no floor fallback); refresh the backup first (final HP). A clean recall deletes the backup; a full inventory keeps it as "lost" for Pepin.
      refreshRecoveryEntry(entry)
      if recallAllyToInventory(entry.monster, entry, owner) then
        recoveryRegistry[entry.seed] = nil
      end
      untrackDeployedAt(i)
    end
  end
  -- Announce every still-backed-up, not-yet-recovered ally ("lost"/"lostfull"); "injured" is announced at death.
  for seed, rec in pairs(recoveryRegistry) do
    if rec.state == "lost" or rec.state == "lostfull" then
      local line = recoveryMessageFor(seed, rec)
      if line ~= nil then message(line) end
    end
  end
  -- Drop pending corpse-suppression / resurrect-beam entries so a reused slot id can't inherit them next level.
  for id in pairs(corpselessDeaths) do corpselessDeaths[id] = nil end
  for id in pairs(pendingResurrectBeam) do pendingResurrectBeam[id] = nil end
end)

-- Single-player Load Game re-link: re-bind each saved roster record (from OnLoadPlayerData) to its reloaded golem by stable slot id, so mid-dungeon allies reload tracked, not orphaned. SP only; called from GameStart after the level + the per-game clear.
function relinkSavedAllies()
  if pendingAllyRoster == nil then return end
  local roster = pendingAllyRoster
  pendingAllyRoster = nil -- consume once
  if system.isMultiplayer() then return end

  local me = player.self()
  for _, rec in ipairs(roster) do
    local m = monsters.fromId(rec.id)
    -- Re-link only a still-live golem owned by the local player; a dropped/mismatched slot is left untracked so its "lost" backup survives for Pepin.
    if m ~= nil and m.isGolem and (me == nil or m.ownerPlayerId == me.id) then
      local entry = {
        monster            = m,
        seed               = rec.seed,
        capturedDifficulty = rec.capturedDifficulty,
        isMinion           = rec.isMinion or nil, -- nil for allies, matching the deploy convention
        parentId           = rec.parentId,
        base               = rec.base,
      }
      trackDeployedAlly(entry) -- sets entry.id from the live monster
      -- Re-assert Bonded state (rolls are no-ops since OnLoadPlayerData restored them; re-applies immunity + aura light).
      if not entry.isMinion and isBonded(entry.seed, m.level) then
        rollBondedBonus(entry)
        rollBondedTrn(entry)
        applyBondedBonus(entry)
        applyBondedGlow(entry)
      end
    end
  end
  -- Re-derive the live share-divided buff now the full set is tracked (applyAllyBuff writes base+buff, not accumulate, so no double buff; current HP intact).
  recalcAllyBuffs()
end

-- On entering a game, remind the player of every recovery-registry backup waiting at Pepin ("lost" + "injured"), skipping any seed currently deployed. Runs after relinkSavedAllies.
function announceRecoveryOnEntry()
  local deployedSeeds = {}
  for _, entry in ipairs(deployedAllies) do
    if entry.seed ~= nil then deployedSeeds[entry.seed] = true end
  end
  for seed, rec in pairs(recoveryRegistry) do
    if not deployedSeeds[seed] then
      local line = recoveryMessageFor(seed, rec)
      if line ~= nil then message(line) end
    end
  end
end

-- The PRIMARY load-time blob rebuild (not a repair): held-item modData is deliberately never
-- hero-saved (ItemPack frozen for non-Hunter save stability), so EVERY save→reload empties it.
-- Rebuild each held Tame Scroll's blob from the seed-keyed tables persisted via luamoddata, making a
-- reloaded scroll trade/drop losslessly again. Local Hunter only; runs once per game at GameStart.
function rebuildHeldScrollModData()
  if TAME_ID == nil then return end
  local me = player.self()
  if me == nil or me.className ~= HUNTER_CLASS then return end
  me:iterateInventory(function(it)
    if it:isScrollOf(TAME_ID) then
      -- Origin-record gaps are only ever OUR OWN creation (every foreign acquisition writes
      -- scrollOrigin at pickup re-key; the record is luamoddata-persisted), so claim the local
      -- Hunter: an absent record entirely, or a name left empty by creation-time minting (the
      -- starter scroll is minted before the player name is readable).
      local o = scrollOrigin[it.seed]
      if o == nil then
        scrollOrigin[it.seed] = { name = me.name, id = getMyOhId() }
      elseif o.name == nil or o.name == "" then
        o.name = me.name
      end
      it.modData = blobForSeed(it.seed)
    end
  end)
end

-- GameStart: reset all live, per-game session state to its empty start-of-game invariant (the Lua runtime persists across games but OnLevelExit doesn't fire on quit-to-menu), then SP-relink any mid-dungeon allies. Clears only live/transient state, never the save-persisted tables.
events.GameStart.add(function()
  deployedAllies = {}
  deployedAlliesById = {}
  remoteAllies = {}
  pendingDeploys = {}
  corpselessDeaths = {}
  pendingResurrectBeam = {}
  lastBuffFingerprint = nil
  capturedNaturalMonsters = {}
  relinkSavedAllies()
  announceRecoveryOnEntry()
  rebuildHeldScrollModData() -- the primary load-time rebuild: held modData is never hero-saved
  restoreStatPoints()        -- overwrite the engine's wrapped uint8 _pStatPts with the saved true value
end)

-- Restore the true unspent stat points saved by OnSavePlayerData: the engine hero file carries
-- _pStatPts as one byte, so a >255 Forgetting refund wraps at load. Consume-once (a new character
-- never fires OnLoadPlayerData, so the stash must not leak across a same-launch character swap).
function restoreStatPoints()
  local pts = pendingStatPts
  pendingStatPts = nil
  if pts == nil then return end
  local me = player.self()
  if me == nil or me.className ~= HUNTER_CLASS then return end
  me.statPoints = pts
end

-- OnMonsterDeath: remove an ally from tracking when it dies in combat.
events.OnMonsterDeath.add(function(monster)
  -- Capture remote-owned status BEFORE clearing tracking — the death visuals must fire for an observed (remoteAllies) ally too.
  local remoteRec = remoteAllies[monster.id]
  -- On a peer: drop remote tracking for the dead ally + any remote minions whose parent just died, so the per-client minion count stays correct.
  if remoteAllies[monster.id] ~= nil then remoteAllies[monster.id] = nil end
  for rid, rec in pairs(remoteAllies) do
    if rec.parentId == monster.id then remoteAllies[rid] = nil end
  end
  -- If a parent ally died, its minions cannot outlive it — despawn them silently.
  removeMinionsOfParent(monster.id)
  -- Death visuals apply to an owned OR observed tamed ally/minion (identical on every client). Record BEFORE untracking — the corpse hook fires later.
  local entry = getDeployedAllyEntry(monster.id)
  local isTrackedAlly = entry ~= nil or remoteRec ~= nil
  local isMinion = (entry ~= nil and entry.isMinion) or (remoteRec ~= nil and remoteRec.parentId ~= nil)
  -- A dead ally is forgotten by the delta everywhere (allies are corpseless; a stale record ghosts/crashes a later loader): every on-level witness invalidates locally, and the OWNER additionally RM-broadcasts so OFF-level clients invalidate too (see bugs.md).
  if isTrackedAlly then
    monsters.removeDeltaSpawnedMonster(myDeltaLevel, monster.id)
    if entry ~= nil then broadcastRemove(monster.id) end
  end
  if isTrackedAlly then corpselessDeaths[monster.id] = true end
  -- A NON-minion ally death gets the resurrect-beam FX on its final death frame (own or remote-observed).
  if isTrackedAlly and not isMinion then pendingResurrectBeam[monster.id] = true end
  -- Owner-only: mark OUR OWN non-minion ally's backup "injured" (paid, full-HP recovery) and announce it.
  if entry ~= nil and not entry.isMinion and entry.seed ~= nil then
    local rec = recoveryRegistry[entry.seed]
    if rec ~= nil then
      local _, maxHp, level, dif = decodeDwBuff(rec.dwBuff)
      rec.dwBuff                 = encodeDwBuff(maxHp, maxHp, level, dif) -- recovered at full HP, not its dying HP
      rec.state                  = "injured"
      -- Use the full scroll name ("Tamed/Bonded [Lvl N] [Name]") so the message matches the item.
      local _, scrollName        = buildScrollParams(allyToMonsterData(monster, entry), entry.seed)
      message(scrollName .. " has been defeated and can be revived at Pepin.")
    end
  end
  -- Untrack the dead entry (a minion's own death just removes it; no scroll drops).
  removeDeployedById(monster.id)
  -- Only a non-minion ally death changes the buff share; skip the recalc on unrelated deaths.
  if entry ~= nil and not entry.isMinion then
    recalcAllyBuffs() -- survivors re-absorb the freed buff share
  end
end)

-- OnMonsterCanPlaceCorpse: tamed allies/minions vanish on death (no corpse) and spawn the resurrect-beam FX, keyed by the corpselessDeaths / pendingResurrectBeam sets recorded in OnMonsterDeath. A vanilla Golem keeps its corpse.
events.OnMonsterCanPlaceCorpse.add(function(monster)
  -- Final death frame: spawn the resurrect-beam FX at the ally's tile (queued in OnMonsterDeath).
  if pendingResurrectBeam[monster.id] then
    pendingResurrectBeam[monster.id] = nil
    monster:castResurrectBeamSelf()
  end
  if corpselessDeaths[monster.id] then
    corpselessDeaths[monster.id] = nil
    return false
  end
end)

-- OnMonsterCanCompleteQuest: a tamed quest boss already cleared its quest at tame time, so its later death as an ally must NOT re-trigger the quest. Any golem/player-minion death is never "the player slaying a quest boss".
events.OnMonsterCanCompleteQuest.add(function(monster)
  if monster.isGolem then return false end
end)

-- OnMonsterCanEndGame: a tamed Diablo dying as an ally must NOT run the game-ending death sequence
-- (quest clear, player freeze, level-wide kill, camera pan, ending cinematic) — vetoed, he dies like
-- any other ally: death anim, resurrect beam on the last frame, no corpse, reaped. His quest was
-- already cleared at tame time (checkQuestKill), so nothing quest-side is lost here either.
-- Golem-barometer note: this hook only ever fires for MT_DIABLO, and a vanilla Golem can never be
-- MT_DIABLO, so isGolem here is exactly "someone's tamed Diablo" (own or remote-observed — the same
-- death-time proxy OnMonsterCanCompleteQuest uses). A WILD Diablo is never a golem → nil → full
-- vanilla ending, mod loaded or not.
events.OnMonsterCanEndGame.add(function(monster)
  if monster.isGolem then return false end
end)

-- Deployed allies survive Diablo's level-wide death sweep (the ending plays with the pets standing).
-- Also state hygiene, not just cosmetics: the sweep kills by setting the death animation directly,
-- BYPASSING MonsterDeath and therefore OnMonsterDeath — a swept ally would die untracked (no
-- untrack/RM/beam, the roster holding dead slots through the ending pan). Own (deployedAllies) +
-- observed remote (remoteAllies) copies are the same protected set on every client, so the sweep
-- stays deterministic; a vanilla Golem is in neither → dies with the level (barometer).
events.OnDiabloDeathCanKillMonster.add(function(m)
  if isDeployedAlly(m.id) or remoteAllies[m.id] ~= nil then return false end
end)

-- creditAllyKill: track each OWN deployed ally's kill count (Bonded progression), keyed by seed. No-op for minions + remote allies. Shared by the melee (OnGolemKilledMonster) and missile (OnMonsterMissileHit) paths.
creditAllyKill = function(ally, victim)
  local entry = getDeployedAllyEntry(ally.id)
  if entry == nil then return end
  if entry.isMinion then return end -- minions have no seed and don't accumulate kills
  local mlvl                 = ally.level
  local before               = allyKillCounts[entry.seed] or 0
  local after                = before + 1
  allyKillCounts[entry.seed] = after
  local needed               = mlvl * BONDED_KILLS_PER_LEVEL
  -- Detect the exact kill that crosses the Bonded threshold and promote to Bonded.
  if mlvl > 0 and before < needed and after >= needed then
    promoteToBonded(entry)         -- already re-applies the buff (incl. the new KTH), so we're done
    broadcastCombatOverride(entry) -- Bonded changed its stats/immunity/profile (incl. trnVariant); sync to peers
    return
  end
  -- A KILL_TOHIT_PER milestone re-derives the buff locally (new ToHit); EVERY kill broadcasts CO —
  -- peers render the kill count (infobox/nearBonded) and only ever learn it from an event message.
  if after % KILL_TOHIT_PER == 0 then applyAllyBuff(entry) end
  broadcastCombatOverride(entry)
end

-- Melee kills route here too (the engine fires OnGolemKilledMonster for any golem attacker; creditAllyKill filters to our own).
events.OnGolemKilledMonster.add(creditAllyKill)

-- OnGolemMinionMissileSpawn: a golem-fired spawn missile (a tamed Hork Demon's Hork Spawn) landed. Suppress the vanilla spawn on every client (non-level-natural species); the LEVEL OWNER creates + attributes + replicates the correct species at the landing tile.
events.OnGolemMinionMissileSpawn.add(function(ally, species, x, y)
  if not isTamedAlly(ally.id) then return nil end -- not one of ours → leave the engine's default spawn
  -- Spawn authority + the minion cap are enforced HERE, owner-only and authoritatively, NOT in the Hork's deterministic fire roll (the count is network-timed, so keeping it out of the roll keeps the missile in lockstep).
  local me = player.self()
  if me ~= nil and me:isLevelOwnedByLocalClient()
      and countMinionsOfParent(ally.id) < HORK_MAX_MINIONS then
    local captured = allyCapturedDifficulty(ally)
    local minion = monsters.spawnWithDifficulty(species, captured, x, y)
    if minion ~= nil then registerSpawnedMinion(minion, ally, captured) end
  end
  return false -- suppress the vanilla SpawnMonster on every client
end)

-- OnGetMonsterInfo: replace the base info block for any friendly-viewable tamed pet (own or a peaceful player's) with live HP + kills + resistance/immunity lines (revealed upfront, no kill threshold).

-- A friendly pet's lifetime kill count for the info box (own from allyKillCounts by seed, remote from the CO profile). nil for a minion or an unread remote pet.
function petKills(monster)
  local entry = getDeployedAllyEntry(monster.id)
  if entry ~= nil then
    if entry.isMinion then return nil end
    return allyKillCounts[entry.seed] or 0
  end
  local rec = remoteAllies[monster.id]
  if rec ~= nil and rec.profile ~= nil then
    if rec.profile.isMinion then return nil end
    return rec.profile.kills or 0
  end
  return nil
end

events.OnGetMonsterInfo.add(function(monster)
  -- Regular box for any friendly observer: name (OnGetMonsterDisplayName) + live HP + Kills + resistances; Type/stats/origin live in the floating box.
  if not isFriendlyTamedView(monster) then return nil end

  local lines = { "Hit Points: " .. monster.health .. " / " .. monster.maxHealth }
  local kills = petKills(monster)
  if kills ~= nil then table.insert(lines, "Kills: " .. kills) end

  -- Read the LIVE resistance bitfield (not the type's base) so a Bonded-granted immunity shows.
  local res = monster.resistance
  local function has(flag) return (res & flag) ~= 0 end
  local hasResist = has(RES.ResistMagic) or has(RES.ResistFire) or has(RES.ResistLightning)
  local hasImmune = has(RES.ImmuneMagic) or has(RES.ImmuneFire) or has(RES.ImmuneLightning)
  if not hasResist and not hasImmune then
    table.insert(lines, "No magic resistance")
  else
    if hasResist then
      local r = "Resists:"
      if has(RES.ResistMagic) then r = r .. " Magic" end
      if has(RES.ResistFire) then r = r .. " Fire" end
      if has(RES.ResistLightning) then r = r .. " Lightning" end
      table.insert(lines, r)
    end
    if hasImmune then
      local i = "Immune:"
      if has(RES.ImmuneMagic) then i = i .. " Magic" end
      if has(RES.ImmuneFire) then i = i .. " Fire" end
      if has(RES.ImmuneLightning) then i = i .. " Lightning" end
      table.insert(lines, i)
    end
  end

  return lines
end)

-- Force the healthbar resistance/immunity icons to show for our deployed allies (overriding the vanilla unique-or-15-kills gate). Other monsters keep vanilla behaviour.
events.OnMonsterCanShowResistances.add(function(monster)
  if isDeployedAlly(monster.id) then return true end
end)

-- Floating stat box for a hovered tamed pet (own or a peaceful player's): fully self-drawn each frame (GameDrawComplete), each stat shown as `base / buffed` with the buffed value blue when it differs. OH/ID = the scroll's permanent Original Trainer.
FBOX_LINE_H      = 13
FBOX_WHITE       = render.UiFlags.ColorWhite     | render.UiFlags.Outlined
FBOX_BLUE        = render.UiFlags.ColorBlue      | render.UiFlags.Outlined
FBOX_GOLD        = render.UiFlags.ColorWhitegold | render.UiFlags.Outlined
FBOX_DIFF_NAMES  = { [0] = "Normal", [1] = "Nightmare", [2] = "Hell" }
FBOX_MODE_NAMES  = { [0] = "Diablo", [1] = "Hellfire" }
-- Dungeon-level → area-name ranges { upperBound, name, displayOffset } for the "Found:" field; shown number = dlvl minus the zone's displayOffset (matching the automap: Nest/Crypt restart at 1).
FBOX_AREA_ZONES  = {
  { 4,  "Church", 0 }, { 8, "Catacombs", 0 }, { 12, "Caves", 0 },
  { 16, "Hell",   0 }, { 20, "Nest", 16 }, { 24, "Crypt", 20 },
}
FBOX_NUM_LEVELS  = 25 -- engine NUMLEVELS (diablo.h); the setlevel encode offset
-- Quest sub-level names, indexed by setlvlnum (engine QuestLevelNames in Source/levels/setmaps.cpp).
FBOX_QUEST_NAMES = {
  [1] = "Skeleton King's Lair",
  [2] = "Chamber of Bone",
  [3] = "Maze",
  [4] = "Poisoned Water Supply",
  [5] = "Archbishop Lazarus' Lair",
  [6] = "Church Arena",
  [7] = "Hell Arena",
  [8] = "Circle of Life Arena",
}
function areaLevelName(lvl)
  if lvl == nil or lvl <= 0 then return "Unknown" end
  if lvl > 24 then return FBOX_QUEST_NAMES[lvl - FBOX_NUM_LEVELS] or "Quest Area" end -- name only, no "Lvl N"
  for _, z in ipairs(FBOX_AREA_ZONES) do
    if lvl <= z[1] then return z[2] .. " Lvl " .. (lvl - z[3]) end
  end
  return "Quest Area"
end

-- Base stats + provenance for a hovered friendly pet, or nil if not fully readable yet (remote CO not arrived). Buffed values are read live off the monster.
function petFloatingBase(monster)
  local entry = getDeployedAllyEntry(monster.id)
  if entry ~= nil then
    local b = entry.base or {}
    -- OH = the scroll's recorded Original Trainer (its true tamer even if WE got it via trade); minions fall back to the local Hunter.
    local origin = originForSeed(entry.seed) or {}
    return {
      min = b.minDamage or 0,
      max = b.maxDamage or 0,
      toHit = b.toHit or 0,
      ac = b.armorClass or 0,
      hp = b.maxHp or 0,
      difficulty = entry.capturedDifficulty or 0,
      gamemode = scrollGamemode[entry.seed] or 0,
      areaLevel = scrollAreaLevel[entry.seed] or 0,
      ohName = origin.name or "?",
      ohId = origin.id or 0,
    }
  end
  local rec = remoteAllies[monster.id]
  if rec ~= nil and rec.profile ~= nil then
    local p = rec.profile
    return {
      min = p.baseMinDamage or 0,
      max = p.baseMaxDamage or 0,
      toHit = p.baseToHit or 0,
      ac = p.baseArmorClass or 0,
      hp = p.baseMaxHp or 0,
      difficulty = rec.capturedDifficulty or 0,
      gamemode = p.gamemode or 0,   -- the owner broadcasts the pet's tamed-in gamemode over CO
      areaLevel = p.areaLevel or 0, -- the owner broadcasts the pet's tamed-in dungeon level over CO
      ohName = p.ohName or "?",     -- the owner broadcasts the pet's true origin (OH name + id) over CO
      ohId = p.ohId or 0,
    }
  end
  return nil
end

-- Draw a row as left-to-right colour segments ({text, flags}), advancing x by each measured width.
function fboxDrawRow(x, y, segments)
  local cx = x
  for _, seg in ipairs(segments) do
    render.string(seg[1], cx, y, seg[2])
    cx = cx + render.string_width(seg[1])
  end
end

-- A "Label  base / buffed" row; the buffed value turns blue when it differs from base.
function fboxStatRow(label, base, buffed)
  local buffedColor = (buffed ~= base) and FBOX_BLUE or FBOX_WHITE
  return { { string.format("%-9s%d / ", label, base), FBOX_WHITE }, { tostring(buffed), buffedColor } }
end

function fboxRowWidth(row)
  local w = 0
  for _, seg in ipairs(row) do w = w + render.string_width(seg[1]) end
  return w
end

events.GameDrawComplete.add(function()
  local monster = monsters.getHovered()
  if monster == nil or not isFriendlyTamedView(monster) then return end
  local d = petFloatingBase(monster)
  if d == nil then return end

  -- Rows are {text, colorFlags} segments (buffed values live off the monster): base/buffed stat rows, then the gold provenance block (Found / Type / OH / ID / Version).
  local rows = {
    fboxStatRow("Min Dmg:", d.min, monster.minDamage),
    fboxStatRow("Max Dmg:", d.max, monster.maxDamage),
    fboxStatRow("ToHit:", d.toHit, monster.toHit),
    fboxStatRow("AC:", d.ac, monster.armorClass),
    fboxStatRow("HP:", d.hp, monster.maxHealth),
    { { "Found: " .. areaLevelName(d.areaLevel) .. " / "
    .. (FBOX_DIFF_NAMES[d.difficulty] or "Normal"), FBOX_GOLD } },
    { { "Type: " .. monster.monsterClass, FBOX_GOLD } },
    { { "OH: " .. d.ohName, FBOX_GOLD },                                      { "   ID: " .. formatOhId(d.ohId), FBOX_GOLD } },
    { { "Version: " .. (FBOX_MODE_NAMES[d.gamemode] or "Diablo"), FBOX_GOLD } },
  }

  local maxW = 0
  for _, row in ipairs(rows) do
    local w = fboxRowWidth(row)
    if w > maxW then maxW = w end
  end
  local totalH = #rows * FBOX_LINE_H

  -- Anchor just off the cursor, clamped on-screen.
  local mx, my = render.mouse_position()
  local x, y   = mx + 14, my + 14
  local sw, sh = render.screen_width(), render.screen_height()
  if x + maxW > sw then x = sw - maxW - 2 end
  if x < 2 then x = 2 end
  if y + totalH > sh then y = my - totalH - 6 end
  if y < 2 then y = 2 end

  for i, row in ipairs(rows) do
    fboxDrawRow(x, y + (i - 1) * FBOX_LINE_H, row)
  end
end)

-- OnGolemCanTargetMonster: restrict targets to ACTIVE monsters within the owner's ENGAGE_RADIUS (melee AND ranged), consistent with OnGolemCanChaseTarget. An adjacent monster is always allowed (self-defence).
events.OnGolemCanTargetMonster.add(function(ally, candidate)
  if not isTamedAlly(ally.id) then return nil end
  -- Activation gate FIRST (cheap, no alloc): reject all sleeping monsters so the expensive work below runs only for the handful awake near the player.
  if not candidate.isActive then return false end
  -- Cache .position once: each access allocates a fresh Point userdata, multiplying GC churn across the N*A*tick scan.
  local cp = candidate.position
  local ap = ally.position
  -- Self-defence: always fight back against a monster immediately adjacent (cheap; no LOS needed).
  local adx = math.abs(cp.x - ap.x)
  local ady = math.abs(cp.y - ap.y)
  if math.max(adx, ady) <= 1 then return nil end
  -- Cheap distance gate before the LOS raytrace; anchor to the ally's OWNER (works on every client) so the zone matches on owner and peers.
  local owner = allyOwner(ally)
  if owner == nil then return false end
  local op = owner.position
  local pdx = math.abs(cp.x - op.x)
  local pdy = math.abs(cp.y - op.y)
  if not candidate.isLit or math.max(pdx, pdy) > ENGAGE_RADIUS then return false end
  -- Survived the cheap gates: now pay for line of sight (else the ally targets through walls and paths away from the player).
  if not ally:hasLineOfSightTo(candidate) then return false end
  return nil -- active, lit, within the engage radius, clear LOS: allow
end)

-- OnGolemCanTargetGolem: pet-vs-pet combat between mutually-hostile owners (different players, not both friendly). Symmetric, so a defender's pets fight back automatically. Generic for any class's golems.
events.OnGolemCanTargetGolem.add(function(ally, candidate)
  local a = player.get(ally.ownerPlayerId)
  local b = player.get(candidate.ownerPlayerId)
  if a == nil or b == nil then return nil end -- unknown owner -> vanilla (no infighting)
  if a.id == b.id then return nil end         -- same owner -> never infight
  if arePeaceful(a, b) then return nil end    -- both friendly -> no fight
  return true                                 -- at least one hostile -> permit combat
end)

-- OnGolemCanTargetPlayer: let tamed allies acquire PLAYERS hostile to their owner (the player-target counterpart of OnGolemCanTargetGolem). TAMED ALLIES ONLY — the vanilla Golem must never target players (base-mechanics barometer), and unlike pet-vs-pet there is no engine action for a golem-with-player-target (the melee/chase block is monster-only; our OnGolemChooseAction handlers drive player combat), so granting a vanilla Golem a player target would leave it staring, target-locked, doing nothing. All inputs are synced (ownerPlayerId, hostility flags, positions); on non-owner clients isTamedAlly is false -> default(false), which is fine because a remote pet's AI is suppressed and its enemy arrives via net sync.
events.OnGolemCanTargetPlayer.add(function(ally, candidate)
  if not isTamedAlly(ally.id) then return nil end
  local owner = allyOwner(ally)
  if owner == nil then return nil end
  if candidate.id == owner.id then return nil end      -- never the owner
  if arePeaceful(owner, candidate) then return nil end -- friendly -> vanilla (no player targeting)
  local cp = candidate.position
  local ap = ally.position
  -- Self-defence: a hostile player immediately adjacent is always fair game (cheap; no LOS needed).
  if math.max(math.abs(cp.x - ap.x), math.abs(cp.y - ap.y)) <= 1 then return true end
  -- Otherwise the same owner-anchored engage zone + LOS gates as OnGolemCanTargetMonster.
  local op = owner.position
  if math.max(math.abs(cp.x - op.x), math.abs(cp.y - op.y)) > ENGAGE_RADIUS then return false end
  if not ally:hasLineOfSightToPlayer(candidate) then return false end
  return true
end)

-- OnGolemCanChaseTarget: all allies stay within ENGAGE_RADIUS of the owner when chasing.
events.OnGolemCanChaseTarget.add(function(ally, target)
  if not isTamedAlly(ally.id) then return nil end
  local owner = allyOwner(ally) -- the ally's owner (own or remote), resolved from ownerPlayerId
  if owner == nil then return nil end
  -- Block if the ally itself is outside the lit area — let idle pull it back.
  if not ally.isLit then return false end
  -- Block chasing an unlit or out-of-range target.
  if not target.isLit then return false end
  local tdx = math.abs(target.position.x - owner.position.x)
  local tdy = math.abs(target.position.y - owner.position.y)
  if math.max(tdx, tdy) > ENGAGE_RADIUS then return false end
  return nil
end)

-- Is a PROTECTED pet — one of OUR deployed allies, or a tracked remote ally whose owner is at peace
-- with us — on or within PATH_PADDING tiles (Chebyshev) of the line from (sx,sy) to (tx,ty)? Vetoes an
-- auto-targeting bolt fired through/past a pet. Target endpoint included, source endpoint skipped.
-- A HOSTILE owner's pets are deliberately not swept (fair PvP game). Own ∪ peaceful-remote is the same
-- protected set on every mutually-peaceful client, so the veto stays symmetric across clients.
PATH_PADDING = 1
function friendlyAllyNearPath(sx, sy, tx, ty)
  -- Collect the protected pets' positions once, then sweep the line.
  local positions = {}
  for _, entry in ipairs(deployedAllies) do
    positions[#positions + 1] = entry.monster.position
  end
  local me = player.self()
  for id, rec in pairs(remoteAllies) do
    local m = monsters.fromId(id) -- same slot-alias guards as reapOrphanedRemoteAllies
    if m ~= nil and m.isGolem and m.ownerPlayerId == rec.ownerId
        and arePeaceful(me, player.get(rec.ownerId)) then
      positions[#positions + 1] = m.position
    end
  end
  if #positions == 0 then return false end
  local dx, dy = tx - sx, ty - sy
  local steps = math.max(math.abs(dx), math.abs(dy))
  if steps == 0 then return false end -- target is the origin tile: nothing to sweep
  for i = 1, steps do
    local x = sx + math.floor(dx * i / steps + 0.5)
    local y = sy + math.floor(dy * i / steps + 0.5)
    for _, p in ipairs(positions) do
      if math.abs(p.x - x) <= PATH_PADDING and math.abs(p.y - y) <= PATH_PADDING then
        return true
      end
    end
  end
  return false
end

-- OnMissileCanTargetMonster: TARGETING gate for auto-targeting spells (Chain Lightning, Bone Spirit). Never target our own/friendly pets — always, regardless of Friendly Fire: a bolt aimed AT an untouchable pet is pure jank, and it mirrors the engine never letting these spells pick players at all (same reasoning as vanilla Apocalypse's own isPlayerMinion skip). The friendlyAllyNearPath collateral-path veto (own pets AND a peaceful Hunter's pets) applies only while Friendly Fire is ON: with FF OFF the damage layer (OnPlayerMissileCanHitGolem) makes friendly missiles pass through pets, so the firing line is safe and spells keep their full reach/bounces. A vanilla Golem stays fully targetable.
events.OnMissileCanTargetMonster.add(function(monster, source)
  if isDeployedAlly(monster.id) then return false end
  if isOtherHuntersAlly(monster) then
    local me = player.self()
    local owner = player.get(monster.ownerPlayerId)
    if arePeaceful(me, owner) then return false end
  end
  if system.isFriendlyFireEnabled() then
    local mp = monster.position
    if friendlyAllyNearPath(source.x, source.y, mp.x, mp.y) then return false end
  end
end)

-- OnGolemCanSelect: cursor selection (hover, infobox, click-targeting). Own allies/minions + another Hunter's pet (friendly or hostile) are always selectable; offensive actions are gated separately by isProtectedFromOffense.
events.OnGolemCanSelect.add(function(monster)
  if isDeployedAlly(monster.id) then return true end
  if isOtherHuntersAlly(monster) then return true end
end)

-- OnPlayerAttackMonster: block left-click attacks + offensive staff-charge casts on the attacker's own allies / a friendly Hunter's pet (defense-in-depth). Hostility falls through. Shares isProtectedFromOffense.
events.OnPlayerAttackMonster.add(function(attacker, monster)
  if isProtectedFromOffense(attacker, monster) then return false end
end)

-- OnGolemIdle: follow while the owner moves, settle within ENGAGE_RADIUS when stopped, pursue an active enemy within the radius. Idle wander spot is a pure function of the synced tick (see syncedHash).

-- How many synced lockstep ticks an idle wander spot holds before re-derivation (long enough to actually walk there).
IDLE_REPICK_TICKS = 24

-- Deterministic, cross-client-identical mix of two small non-negative integers (arithmetic only, operands reduced first). Derives an AI choice from (synced tick, entity id) so every client computes the SAME value with no network traffic.
function syncedHash(a, b)
  return ((a % 100003) * 374761 + (b % 100003) * 668251) % 1000003
end

events.OnGolemIdle.add(function(ally, hasTarget, enemyPos)
  if not isTamedAlly(ally.id) then return nil end
  local owner = allyOwner(ally) -- own or remote owner, from ownerPlayerId
  if owner == nil then return false end

  -- Pursue an enemy target that is close to the owner.
  if hasTarget then
    local edx = math.abs(enemyPos.x - owner.position.x)
    local edy = math.abs(enemyPos.y - owner.position.y)
    if math.max(edx, edy) <= ENGAGE_RADIUS then return enemyPos end
  end

  if owner.isMoving then
    -- Owner is walking: follow directly.
    return owner.position
  end

  -- Owner is not moving.
  if ally:distanceTo(owner) <= ENGAGE_RADIUS then
    return false -- already close enough; stand still
  end

  -- Outside engage zone: walk to a wander spot near the owner. The offset is a PURE FUNCTION of (synced tick-bucket, ally slot id) — NOT an aiRandom value cached at first-idle, which differed per client and fought the position sync (the twitch/zap). Holds for IDLE_REPICK_TICKS.
  local span = 2 * ENGAGE_RADIUS + 1
  local bucket = math.floor(system.gameTick() / IDLE_REPICK_TICKS)
  local spot = owner.position
  spot.x = spot.x + (syncedHash(bucket, ally.id) % span) - ENGAGE_RADIUS
  spot.y = spot.y + (syncedHash(bucket, ally.id + 7919) % span) - ENGAGE_RADIUS
  return spot
end)

-- OnGolemChooseAction: give ranged allies a ranged attack at appropriate distance. Fires before GolumAi's melee/chase block (Lua first refusal); true consumes the tick. Non-ranged/vanilla Golem return nil.
RANGED_MIN_DIST = 3 -- don't fire if the enemy is 1–2 tiles away (let melee handle it)
RANGED_MAX_DIST = 8 -- max range for ranged attack

-- Avoidance casters (AiRangedAvoidance): a tamed one backs away from a closing enemy toward the owner, keeping it within leash range.
AVOIDANCE_RANGED = {
  [monsters.AIID.Magma] = true,
  [monsters.AIID.Storm] = true,
  [monsters.AIID.Acid] = true,
  [monsters.AIID.Diablo] = true,
  [monsters.AIID.BoneDemon] = true,
}
KITE_MIN_DIST = 3 -- avoidance allies retreat if the enemy is closer than this

-- The C++ call-out forwards the ally's target (Monster or Player, or nil), not a precomputed distance, so derive Chebyshev distance here. Works for either target kind (both expose .position).
function golemTargetDistance(ally, enemy)
  if enemy == nil then return -1 end
  local ap, ep = ally.position, enemy.position
  return math.max(math.abs(ap.x - ep.x), math.abs(ap.y - ep.y))
end

-- LOS to whichever target the ally holds. The LOS bindings are typed (hasLineOfSightTo takes a Monster, hasLineOfSightToPlayer a Player), so dispatch here instead of at every call site.
function golemHasLosToTarget(ally, enemy, enemyPlayer)
  if enemy ~= nil then return ally:hasLineOfSightTo(enemy) end
  if enemyPlayer ~= nil then return ally:hasLineOfSightToPlayer(enemyPlayer) end
  return false
end

-- AIs whose authentic ranged attack uses the special-ranged animation/mode (vs the normal ranged
-- animation everyone else uses). Mirrors the original native-AI behaviour for these casters.
SPECIAL_RANGED_AI = {
  [monsters.AIID.Mega]       = true,
  [monsters.AIID.Magma]      = true,
  [monsters.AIID.Storm]      = true,
  [monsters.AIID.Acid]       = true,
  [monsters.AIID.AcidUnique] = true,
  [monsters.AIID.Diablo]     = true,
  [monsters.AIID.BoneDemon]  = true,
}

events.OnGolemChooseAction.add(function(ally, enemy, enemyPlayer)
  if not isTamedAlly(ally.id) then return nil end
  if not ally.hasRangedAttack then return nil end
  local target = enemy or enemyPlayer -- Monster or hostile Player; the ranged attack fires at enemyPosition either way
  if target == nil then return nil end
  local dist = golemTargetDistance(ally, target)

  -- Kite within leash: an avoidance caster whose enemy closed inside KITE_MIN_DIST steps back toward the owner instead of firing in melee range.
  if AVOIDANCE_RANGED[ally.originalAiId] and dist < KITE_MIN_DIST then
    local owner = allyOwner(ally)
    if owner ~= nil then
      local odx = math.abs(ally.position.x - owner.position.x)
      local ody = math.abs(ally.position.y - owner.position.y)
      if math.max(odx, ody) >= 2 then -- not already hugging the owner
        ally:walkToward(owner.position.x, owner.position.y)
        return true
      end
    end
  end

  if dist < RANGED_MIN_DIST then return nil end                            -- adjacent: fall through to melee (engine block for monsters, the player-target handler below for players)
  if not golemHasLosToTarget(ally, enemy, enemyPlayer) then return nil end -- no line of sight: fall through to chase
  if dist > RANGED_MAX_DIST then return nil end                            -- too far: fall through to chase
  -- Single-writer fire: only the OWNER's client decides this fire. A remote-owned copy keeps every
  -- movement/kiting/stance decision above (shared positioning) but HOLDS here instead of firing — the
  -- owner's AT broadcast renders the shot on this client. Per-client fire decisions read divergent
  -- inputs (positions mid-walk, LOS, target latch), which produced missiles existing on some clients
  -- only while the owner's authoritative damage still landed (death by invisible missiles).
  if deployedAlliesById[ally.id] == nil then return true end
  -- Stash the choose-time target tile: the AT broadcast fires from the missile-SPAWN chokepoint
  -- (OnGolemMissileDamage), which doesn't know the target — and an interrupted windup then sends nothing.
  local scratch = allyScratch(ally.id)
  if scratch ~= nil then
    local tp = target.position
    scratch.pendingFireX, scratch.pendingFireY = tp.x, tp.y
  end
  -- Fire the monster's authentic missile (not a generic arrow); its elemental damage is resistance-scaled in OnGolemMissileDamage. Avoidance casters + Mega/Diablo/BoneDemon use the special-ranged animation.
  local mid = ally:naturalRangedMissileId()
  -- Diablo's natural missile is the DiabloApocalypse CARRIER, which ignores the firing monster's
  -- target entirely and drops a boom on EVERY active player (AddDiabloApocalypse iterates players —
  -- the friendly-fire landmine from the targeting audit). A tamed Diablo instead fires the
  -- single-tile DiabloApocalypseBoom at his actual target: it resolves through CheckMissileCol like
  -- every other pet missile, so the standard faction rules apply (OnMonsterMissileHit vs monsters,
  -- OnGolemMissileCanHitPlayer vs players — owner never hit, FF toggle respected). Damage rides the
  -- binding's min/max roll (Physical → OnGolemMissileDamage passes it through), so his Apocalypse
  -- scales with the standard physical ally buff. The wild Diablo keeps the vanilla carrier untouched.
  -- Multi-target: when this primary boom spawns, spreadDiabloApocalypse fans extra booms onto every
  -- other valid hostile in the envelope (Apocalypse is inherently multi-target in vanilla).
  if ally.originalAiId == monsters.AIID.Diablo then
    mid = monsters.MissileID.DiabloApocalypseBoom
    -- Record the primary target so the spread skips it (the engine's own boom already lands there).
    -- Owner-only, like everything past the hold above — the spread fan-out is owner-only too.
    local scratch = allyScratch(ally.id)
    if scratch ~= nil then
      scratch.apocPrimaryMonsterId = enemy ~= nil and enemy.id or nil
      scratch.apocPrimaryPlayerId  = enemyPlayer ~= nil and enemyPlayer.id or nil
    end
  end
  if SPECIAL_RANGED_AI[ally.originalAiId] then
    ally:startSpecialRangedAttack(mid)
  else
    ally:startRangedAttack(mid)
  end
  return true
end)

-- Diablo's Apocalypse is inherently MULTI-target: the vanilla carrier drops a boom on every active
-- player on the level. The tamed version mirrors that shape faction-aware — when the primary boom
-- spawns (the OnGolemMissileDamage chokepoint fires in AddMissile at the attack frame), fan an extra
-- boom onto every OTHER valid hostile in the pet's ranged envelope:
--   * monsters: awake (isActive — never wakes unengaged packs), living, and either WILD (non-golem)
--     or a mutually-HOSTILE owner's pet — the placement mirror of OnGolemMissileCanHitGolem, so a
--     boom is only ever placed where the damage layer will resolve it (own/peaceful pets and a
--     peaceful player's vanilla Golem stay untouched);
--   * players: hostile only (never the owner, peaceful players skipped at placement per the
--     targeting-layer rule; the damage layer's OnGolemMissileCanHitPlayer still re-checks).
-- LOS required per target, mirroring the carrier's LineClearMissile. The primary target (recorded at
-- choose time in the ally scratch) is skipped — the engine's own boom already lands there.
-- OWNER-AUTHORITATIVE (the fix for the spread-desync bug): only the owner runs this fan-out, then
-- replicates the boom tiles to same-level peers over AB. A per-client fan-out read per-client state
-- (roster/scratch timing, positions, LOS) and produced divergent boom sets; MP is not lockstep, so
-- "deterministic on every client" was never enforceable here. Damage stays single-resolver
-- (OnMonsterMissileHit authority for monsters; the victim's own client for players, which is exactly
-- why the booms must exist on every client).
APOC_SPREAD_RADIUS  = RANGED_MAX_DIST -- the pet ranged envelope, not vanilla's level-wide reach
APOC_SPREAD_PER_MSG = 24              -- boom tiles per AB message (chunked under the pipe's 255-byte payload cap)
apocSpreadActive    = false           -- reentrancy guard: spread booms re-enter OnGolemMissileDamage

function spreadDiabloApocalypse(golem)
  local scratch    = allyScratch(golem.id)
  local skipMid    = scratch ~= nil and scratch.apocPrimaryMonsterId or nil
  local skipPid    = scratch ~= nil and scratch.apocPrimaryPlayerId or nil
  local gp         = golem.position
  local boom       = monsters.MissileID.DiabloApocalypseBoom
  local owner      = allyOwner(golem)
  local tiles      = {} -- "x,y" per boom, replicated to peers over AB
  apocSpreadActive = true
  -- Monsters: slot order 0..251 (the engine's hard live-monster ceiling; fromId is nil for empty slots).
  for id = 0, 251 do
    if id ~= skipMid then
      local m = monsters.fromId(id)
      if m ~= nil and not m.hasNoLife and m.isActive then
        local valid
        if not m.isGolem then
          valid = true -- wild monster
        else
          -- Hostile pet-vs-pet: mirror OnGolemMissileCanHitGolem (mutually-hostile owners only).
          local b = player.get(m.ownerPlayerId)
          valid = owner ~= nil and b ~= nil and b.id ~= owner.id and not arePeaceful(owner, b)
        end
        if valid then
          local mp = m.position
          if math.max(math.abs(mp.x - gp.x), math.abs(mp.y - gp.y)) <= APOC_SPREAD_RADIUS
              and golem:hasLineOfSightTo(m) then
            golem:fireMissileAt(boom, mp.x, mp.y)
            tiles[#tiles + 1] = mp.x .. "," .. mp.y
          end
        end
      end
    end
  end
  for pid = 0, 3 do
    local p = player.get(pid)
    if p ~= nil and pid ~= skipPid and p:isOnActiveLevel()
        and owner ~= nil and p.id ~= owner.id and not arePeaceful(owner, p) then
      local pp = p.position
      if math.max(math.abs(pp.x - gp.x), math.abs(pp.y - gp.y)) <= APOC_SPREAD_RADIUS
          and golem:hasLineOfSightToPlayer(p) then
        golem:fireMissileAt(boom, pp.x, pp.y)
        tiles[#tiles + 1] = pp.x .. "," .. pp.y
      end
    end
  end
  apocSpreadActive = false
  -- Replicate the fan-out to same-level peers (the AB receiver recreates each boom; chunked so one
  -- message never exceeds the pipe's payload cap).
  if system.isMultiplayer() and #tiles > 0 then
    for i = 1, #tiles, APOC_SPREAD_PER_MSG do
      luanet.send("hunter", table.concat({ NET.APOCBOOMS, golem.id,
        table.concat(tiles, ";", i, math.min(i + APOC_SPREAD_PER_MSG - 1, #tiles)) }, "|"))
    end
  end
end

-- Hybrid AI: restore original AI special behaviours for tamed monsters. Fires AFTER the ranged handler; a non-nil return overrides it.
AIID                    = monsters.AIID

-- Charge threshold: Rhino/Gloom(Bat) need distance >= 5; Snake uses 2-3 tiles.
CHARGE_MIN_DIST         = { [monsters.AIID.Rhino] = 5, [monsters.AIID.Bat] = 5, [monsters.AIID.Snake] = 2 }

SKELKING_SPAWN_MIN_DIST = 3 -- only spawn when the enemy is at least this far (matches LeoricAi)
SKELKING_SPAWN_CHANCE   = 8 -- percent chance per eligible tick to spawn a minion
SKELETON_TYPE_ID        = 8 -- MT_WSKELAX (basic skeleton) — the species a tamed king raises

HORK_SPAWN_MIN_DIST     = 3 -- Hork Demon fires Hork Spawn at range (matches HorkDemonAi)
HORK_SPAWN_CHANCE       = 8 -- percent chance per eligible tick to fire Hork Spawn

events.OnGolemChooseAction.add(function(ally, enemy, enemyPlayer)
  if not isTamedAlly(ally.id) then return nil end
  local aiId = ally.originalAiId
  local target = enemy or enemyPlayer -- special behaviours apply to hostile-player targets too
  local hasTarget = target ~= nil
  local dist = golemTargetDistance(ally, target)

  -- Skeleton King: periodically raise skeleton minions at range, up to a per-king cap. The spawn ROLL is a PURE FUNCTION OF SYNCED STATE (positions, synced menemy, synced aiRandom) so the raise pose plays in lockstep; the CAP is NOT in the roll (network-timed minion count would diverge the AI) — creation + cap are owner-authoritative below.
  if aiId == AIID.SkeletonKing then
    if hasTarget and dist >= SKELKING_SPAWN_MIN_DIST
        and monsters.aiRandom(100) < SKELKING_SPAWN_CHANCE then
      local me = player.self()
      if me ~= nil and me:isLevelOwnedByLocalClient()
          and countMinionsOfParent(ally.id) < SKELKING_MAX_MINIONS then
        -- Spawn one tile toward the enemy; spawnWithDifficulty crawls to the nearest free tile.
        local ap, ep = ally.position, target.position
        local sx = ap.x + (ep.x > ap.x and 1 or (ep.x < ap.x and -1 or 0))
        local sy = ap.y + (ep.y > ap.y and 1 or (ep.y < ap.y and -1 or 0))
        local captured = allyCapturedDifficulty(ally)
        local minion = monsters.spawnWithDifficulty(SKELETON_TYPE_ID, captured, sx, sy)
        if minion ~= nil then registerSpawnedMinion(minion, ally, captured) end
      end
      ally:startSpecialStand() -- raise pose on every client; the skeleton arrives over the net on peers
      return true
    end
    return nil
  end

  -- Hork Demon: fire Hork Spawn at range. The roll draws on every client (keeps the per-monster RNG
  -- stream aligned), but the FIRE is single-writer like the generic ranged handler: a remote copy
  -- holds and renders the owner's AT instead. The minion cap stays enforced authoritatively at the
  -- missile's landing in OnGolemMinionMissileSpawn (the level owner creates + replicates).
  if aiId == AIID.HorkDemon then
    if hasTarget and dist >= HORK_SPAWN_MIN_DIST
        and monsters.aiRandom(100) < HORK_SPAWN_CHANCE then
      if deployedAlliesById[ally.id] == nil then return true end -- remote copy: hold for the owner's AT
      local scratch = allyScratch(ally.id)
      if scratch ~= nil then
        local tp = target.position
        scratch.pendingFireX, scratch.pendingFireY = tp.x, tp.y
      end
      ally:startSpecialRangedAttack(monsters.MissileID.HorkSpawn)
      return true
    end
    return nil
  end

  -- Goat Melee (AiAvoidance): use its special melee attack at low HP, like the wild goat (else normal melee).
  if aiId == AIID.GoatMelee then
    if ally.health < ally.maxHealth * 0.5 and monsters.aiRandom(100) < 50 then
      ally:startSpecialAttack()
      return true
    end
    return nil
  end

  -- Rhino, Bat (Gloom), Snake: charge attack
  if CHARGE_MIN_DIST[aiId] then
    if hasTarget and dist >= CHARGE_MIN_DIST[aiId] and golemHasLosToTarget(ally, enemy, enemyPlayer) then
      if ally:startCharge() then return true end
    end
    return nil
  end

  -- Gargoyle: prioritise self-heal over ranged attack when HP < 50%
  if aiId == AIID.Gargoyle then
    if ally.health < ally.maxHealth * 0.5 then
      ally:startHeal()
      return true
    end
    return nil
  end

  -- Scavenger: eat nearby corpse to heal when HP < 50%
  if aiId == AIID.Scavenger then
    if ally.health < ally.maxHealth * 0.5 then
      local corpsePos = ally:findNearbyCorpse()
      if corpsePos then
        local pos = ally.position
        if corpsePos.x == pos.x and corpsePos.y == pos.y then
          -- Standing on the corpse: eat it. The eat ANIM plays wherever the copy reaches a corpse,
          -- but the HP write is single-writer (owner only, gated on per-client corpse/position state
          -- peers legitimately diverge on) — the immediate CO carries the absolute HP to peers.
          if deployedAlliesById[ally.id] ~= nil then
            local healAmt = math.max(1, math.floor(ally.maxHealth / 8))
            ally:setHitPoints(math.min(ally.health + healAmt, ally.maxHealth))
            local entry = getDeployedAllyEntry(ally.id)
            if entry ~= nil then broadcastCombatOverride(entry) end
          end
          ally:startEating()
          return true
        else
          -- Walk toward the corpse instead of attacking
          ally:walkToward(corpsePos.x, corpsePos.y)
          return true
        end
      end
    end
    return nil
  end

  return nil
end)

-- Stealth AI: Sneak-type allies keep their cloak — fade out when safe, materialise to strike when an enemy closes in (the gold ally outline still renders while cloaked). Fires after the ranged/hybrid handlers.
SNEAK_FADE_IN_DIST = 3  -- emerge to strike when an enemy is at least this close
SNEAK_FADE_OUT_DIST = 4 -- re-cloak when the enemy is at least this far (or gone)

events.OnGolemChooseAction.add(function(ally, enemy, enemyPlayer)
  if not isTamedAlly(ally.id) then return nil end
  if ally.originalAiId ~= AIID.Sneak then return nil end
  local target = enemy or enemyPlayer
  local hasTarget = target ~= nil
  local dist = golemTargetDistance(ally, target)

  if ally.isHidden then
    -- Cloaked: only emerge when an enemy is close and in sight; otherwise stay hidden (default golem AI follows the player).
    if hasTarget and dist <= SNEAK_FADE_IN_DIST and golemHasLosToTarget(ally, enemy, enemyPlayer) then
      ally:startFadein()
      return true
    end
    return nil
  end

  -- Visible: re-cloak when there is no enemy, or the enemy is out of range.
  if (not hasTarget) or dist >= SNEAK_FADE_OUT_DIST then
    ally:startFadeout()
    return true
  end
  return nil -- enemy adjacent: melee (engine block for monsters, the player-target handler below for players)
end)

-- OnGolemChooseAction (player targets): GolumAi's engine melee/chase block only handles MONSTER targets, so drive melee against a hostile player here — swing when adjacent, otherwise return nil and let OnGolemIdle's pursue branch close the distance (enemyPosition tracks the player each tick, and the same owner-anchored ENGAGE_RADIUS leash applies). Registered after the ranged/hybrid/sneak handlers so their behaviours take priority.
events.OnGolemChooseAction.add(function(ally, enemy, enemyPlayer)
  if enemyPlayer == nil then return nil end
  if not isTamedAlly(ally.id) then return nil end
  if golemTargetDistance(ally, enemyPlayer) <= 1 then
    ally:startAttack() -- hit resolution dispatches on MFLAG_TARGETS_MONSTER, so this swings at the player
    return true
  end
  return nil
end)

-- StoreOpened: Pepin stocks the Potion of Forgetting + restores tamed monster HP to max + offers recovery buy-backs.
events.StoreOpened.add(function(townerName)
  if townerName ~= "pepin" then return end

  -- Always keep a Potion of Forgetting in Pepin's buy list (addToHealerStock is idempotent).
  items.addToHealerStock(FORGET_POTION_MAP, FORGET_POTION_PRICE)

  local owner = player.self()
  local healedAnyScroll = false

  -- Restore in-session scrolls (data is in tameScrollData cache).
  for seed, data in pairs(tameScrollData) do
    if data.savedHp < data.maxHp then
      data.savedHp = data.maxHp
      healedAnyScroll = true
      -- Re-encode dwBuff so the restored HP persists through save/load.
      local scrollItem = owner:findScrollBySeed(seed)
      if scrollItem then
        scrollItem.buff = encodeDwBuff(data.maxHp, data.maxHp, data.level, data.capturedDifficulty or 0)
      end
    end
  end

  -- Restore post-restart scrolls (tameScrollData empty; read from dwBuff). Works for normal + unique scrolls.
  owner:iterateInventory(function(item)
    if not item:isScrollOf(TAME_ID) then return end
    if tameScrollData[item.seed] ~= nil then return end -- already handled above
    local savedHp, maxHp, level, difficulty = decodeDwBuff(item.buff)
    if maxHp == 0 then return end                       -- no valid data encoded
    if savedHp < maxHp then
      -- Re-encode with full HP, preserving difficulty.
      item.buff = encodeDwBuff(maxHp, maxHp, level, difficulty)
      healedAnyScroll = true
    end
  end)

  -- Supplement Pepin's healing sound when only scrolls needed healing (HealPlayer only plays it when the player is wounded).
  if healedAnyScroll and owner.health >= owner.maxHealth then
    audio.playSfx(audio.SfxID.CastHealing)
  end

  -- Recovery: a registry seed already in inventory means it was bought back, so drop that entry before re-stocking.
  for seed in pairs(recoveryRegistry) do
    if owner:findScrollBySeed(seed) ~= nil then
      recoveryRegistry[seed] = nil
    end
  end
  -- Stock each remaining backup as a buy-back scroll: free if "lost", paid (level * cost) if "injured".
  for seed, rec in pairs(recoveryRegistry) do
    local data = recoverScrollData(seed, { buff = rec.dwBuff })
    if data ~= nil then
      local _, scrollName, dwBuff, modData = buildScrollParams(data, seed)
      local price = (rec.state == "injured") and ((data.level or 0) * RECOVERY_INJURED_COST_PER_LEVEL) or 0
      -- Gold/unique tier must be stamped on the STOCK item: a vendor purchase copies stock fields verbatim and fires no quality fixups. 2 = ITEM_QUALITY_UNIQUE.
      local magical = (seedGetUniqueType(seed) >= 0 or seedIsDiablo(seed) or isBonded(seed, data.level or 0)) and 2 or
      nil
      items.addToHealerStock(TAME_SCROLL_MAP, price, seed, scrollName, dwBuff, modData, magical)
    end
  end
end)

-- Per-tick ally upkeep rides GameTick (the engine's game-logic step — fires once per synced
-- simulation tick, incl. catch-up ticks a render frame can skip); GameDrawComplete keeps only
-- actual drawing (the floating stat box). Simulation bookkeeping on the tick, drawing on the frame.

-- Despawn any observed remote ally whose owner has left the game (player.get returns nil for a disconnected player). The engine's golem reaper only reaps MT_GOLEM, so our arbitrary-species allies would otherwise ghost. Owner-match guard keeps it barometer-safe.
function reapOrphanedRemoteAllies()
  for id, rec in pairs(remoteAllies) do
    local owner = player.get(rec.ownerId)
    -- Owner left the GAME: reap immediately. Owner left the LEVEL: the owner auto-recalls at level exit
    -- and RMs us, but if that RM is ever lost the copy stands here forever — reap it ourselves. Debounced
    -- over consecutive passes so a transient isOnActiveLevel() flicker (owner mid-transition) can't
    -- false-trigger; a real departure holds the condition indefinitely.
    local offLevel = owner ~= nil and not owner:isOnActiveLevel()
    if owner == nil or (offLevel and (rec.ownerOffLevelPasses or 0) >= 2) then
      local m = monsters.fromId(id)
      if m ~= nil and m.isGolem and m.ownerPlayerId == rec.ownerId then m:remove() end
      remoteAllies[id] = nil
    elseif offLevel then
      rec.ownerOffLevelPasses = (rec.ownerOffLevelPasses or 0) + 1
    else
      rec.ownerOffLevelPasses = nil
    end
  end
end

events.GameTick.add(function()
  local owner = player.self() -- owns the allies leashed below
  local now = system.gameTick()

  -- Pre-Bonded flash cadence off the synced tick clock (flashOn is read by OnGetMonsterTRN to blink a near-Bonded ally); every client computes the same phase, so peers blink in unison.
  flashOn = (now % FLASH_PERIOD_TICKS) < FLASH_ON_TICKS

  -- Periodically clear remote allies whose owner has left the game OR the level (before the own-ally early-return; a peer can observe without owning). No-op in SP. Every 10 ticks (~0.5s) on the synced clock.
  if system.isMultiplayer() and now % 10 == 0 then reapOrphanedRemoteAllies() end

  -- Owner one-shot broadcasts (MP only) — change-triggered, never periodic (see the NET sync model):
  if system.isMultiplayer() then
    local me = player.self()
    -- Pet-target convergence (EN): a golem's MONSTER target latches engine-side (GolumAi re-seeks
    -- only when it has none), so one transiently-divergent pick sticks on a peer forever — observed
    -- as hostile pet-vs-pet attacking DIFFERENT targets per client until a recall/redeploy despawned
    -- the latched targets and forced a joint re-seek. The owner's view is authoritative: broadcast an
    -- ally's wire-encoded enemy the tick it changes. (The engine's own CMD_SYNCDATA enemy sync skips
    -- its application whenever the copies' positions already agree, so EN carries this, not the engine.)
    if me ~= nil and me.className == HUNTER_CLASS then
      for _, entry in ipairs(deployedAllies) do
        local m = entry.monster
        if m ~= nil and m.isGolem then
          local enc = m:encodedEnemy() or -1
          if enc ~= entry.lastSentEnemy then
            entry.lastSentEnemy = enc
            luanet.send("hunter", table.concat({ NET.ENEMY, entry.id, enc }, "|"))
          end
        end
      end
    end
    -- Deploy-request timeout: the engine consumed the scroll at cast; if no SP/DF echo ever came back
    -- (no live level owner, lost message), give the scroll back.
    for seed, pending in pairs(pendingDeploys) do
      if now - pending.tick > DEPLOY_TIMEOUT_TICKS then
        pendingDeploys[seed] = nil
        if me ~= nil then
          refundTameScroll(me, pending.data, seed)
          message("Deploy failed - Tame Scroll refunded.")
        end
      end
    end
  end

  -- Leash remote-owned allies to THEIR owner locally: snapToPlayer is client-local, so every client runs the same leash rule against the synced owner position (isOnActiveLevel skips mid-transition owners; guards mirror reapOrphanedRemoteAllies).
  if system.isMultiplayer() then
    for id, rec in pairs(remoteAllies) do
      local m = monsters.fromId(id)
      if m ~= nil and m.isGolem and m.ownerPlayerId == rec.ownerId then
        local remoteOwner = player.get(rec.ownerId)
        if remoteOwner ~= nil and remoteOwner:isOnActiveLevel()
            and m:distanceTo(remoteOwner) > LEASH_DISTANCE then
          m:snapToPlayer(remoteOwner)
        end
      end
    end
  end

  if #deployedAllies == 0 then return end

  -- Leash every deployed ally that wandered too far — but PRUNE any STALE entry first: mod state outlives a game and quit-to-menu skips OnLevelExit, so a leftover entry can alias a reused slot whose snapToPlayer would crash the town render. A live ally is always isGolem; a freed slot reads isGolem false, so prune those. Iterate backwards.
  for i = #deployedAllies, 1, -1 do
    local entry = deployedAllies[i]
    if not entry.monster.isGolem then
      untrackDeployedAt(i)
    elseif owner ~= nil and entry.monster:distanceTo(owner) > LEASH_DISTANCE then
      entry.monster:snapToPlayer(owner)
    end
  end

  -- Recalc cadence: poll a cheap stat fingerprint once per tick and recalc the buff only when it changes (CLVL-up / gear swap).
  if owner ~= nil and owner.className == HUNTER_CLASS then
    local fp = owner.characterLevel .. ":" .. owner.maxHealth .. ":" .. owner.minDamage
        .. ":" .. owner.maxDamage .. ":" .. owner.toHit .. ":" .. owner.armorClass
    if fp ~= lastBuffFingerprint then
      lastBuffFingerprint = fp
      recalcAllyBuffs()
    end
  end
end)

-- Mod-data save: flat sections of seed-keyed tables separated by 0 markers (0 is never a valid seed/flag/variant).
-- Reset ALL per-character durable state: everything OnSavePlayerData persists, plus the identity and
-- caches that shadow it. The Lua runtime outlives characters within one app session and a NEW
-- character never fires OnLoadPlayerData — without this reset the previous character's tables (Pepin
-- recovery, kills, origins, counter) roll over into the next character and get PERSISTED into its
-- first save. Called at character creation and at the top of the load parser (load REPLACES, never
-- merges). GameStart must NOT call this — it clears only per-game transient state.
function resetPersistedCharacterState()
  allyKillCounts    = {}
  bondedImmunity    = {}
  bondedTrn         = {}
  recoveryRegistry  = {}
  scrollOrigin      = {}
  scrollGamemode    = {}
  scrollAreaLevel   = {}
  tameScrollData    = {}
  pendingAllyRoster = nil
  pendingStatPts    = nil
  scrollCounter     = 1
  myOhId            = nil
end

events.OnSavePlayerData.add(function()
  -- Only a Hunter persists mod data; any other class returns nothing, keeping the save byte-identical to a non-modded one.
  local me = player.self()
  if me == nil or me.className ~= HUNTER_CLASS then return nil end
  local t = {}
  for seed, kills in pairs(allyKillCounts) do
    t[#t + 1] = seed
    t[#t + 1] = kills
  end
  t[#t + 1] = 0                              -- section marker
  for seed, flag in pairs(bondedImmunity) do -- Bonded defensive bonuses
    t[#t + 1] = seed
    t[#t + 1] = flag
  end
  t[#t + 1] = 0                            -- section marker
  for seed, variant in pairs(bondedTrn) do -- Bonded recolour TRN variants
    t[#t + 1] = seed
    t[#t + 1] = variant
  end
  t[#t + 1] = 0                               -- section marker
  for seed, rec in pairs(recoveryRegistry) do -- recovery backups: (seed, dwBuff, state) triples
    t[#t + 1] = seed
    t[#t + 1] = rec.dwBuff
    -- state code: 0 = "lost", 1 = "injured", 2 = "lostfull"
    t[#t + 1] = (rec.state == "injured") and 1 or (rec.state == "lostfull") and 2 or 0
  end
  -- Section 5: deployed-ally roster (SINGLE-PLAYER ONLY) — the live golem<->seed link for a mid-dungeon Load Game re-link. Each record: slot id + seed/capturedDifficulty/isMinion/parentId + un-buffed base stats. Skipped in MP (slot ids aren't cross-client; MP persists via the net delta).
  t[#t + 1] = 0   -- recovery-section terminator
  if system.isMultiplayer() then
    t[#t + 1] = 0 -- roster count 0: MP persists no ally roster
  else
    t[#t + 1] = #deployedAllies
    for _, entry in ipairs(deployedAllies) do
      local base = entry.base or {}
      t[#t + 1] = entry.id or entry.monster.id
      t[#t + 1] = entry.seed or 0
      t[#t + 1] = entry.capturedDifficulty or 0
      t[#t + 1] = entry.isMinion and 1 or 0
      t[#t + 1] = entry.parentId or 0
      t[#t + 1] = base.minDamage or 0
      t[#t + 1] = base.maxDamage or 0
      t[#t + 1] = base.toHit or 0
      t[#t + 1] = base.armorClass or 0
      t[#t + 1] = base.maxHp or 0
    end
  end
  -- Trailing: the persistent monotonic scroll counter, so seeds are never re-issued across sessions.
  t[#t + 1] = scrollCounter
  -- The permanent per-character OHID (generated at creation; see getMyOhId).
  t[#t + 1] = getMyOhId()
  -- Scroll Original-Trainer provenance (count, then seed/ohId/byte-packed-name per entry); variable length, so appended last.
  local originList = {}
  for seed, o in pairs(scrollOrigin) do originList[#originList + 1] = { seed = seed, o = o } end
  t[#t + 1] = #originList
  for _, e in ipairs(originList) do
    t[#t + 1] = e.seed
    t[#t + 1] = e.o.id or 0
    packStringToWords(t, e.o.name or "")
  end
  -- Tamed-in gamemode per seed (count, then bare seeds): only Hellfire (1) entries; a missing seed reads back 0 (Diablo).
  local gmList = {}
  for seed, gm in pairs(scrollGamemode) do
    if gm == 1 then gmList[#gmList + 1] = seed end
  end
  t[#t + 1] = #gmList
  for _, seed in ipairs(gmList) do t[#t + 1] = seed end
  -- Tamed-in area level per seed (count, then seed,areaLvl pairs): any non-zero level; a missing seed reads back 0 (Unknown).
  local alList = {}
  for seed, lvl in pairs(scrollAreaLevel) do
    if lvl and lvl > 0 then alList[#alList + 1] = seed end
  end
  t[#t + 1] = #alList
  for _, seed in ipairs(alList) do
    t[#t + 1] = seed
    t[#t + 1] = scrollAreaLevel[seed]
  end
  -- Trailing: true unspent stat points. The engine hero file carries _pStatPts as a single BYTE, and a
  -- Potion-of-Forgetting refund can exceed 255 (a full respec refunds STAT_BUDGET - 85 = 375), which
  -- wraps on the next load (445 -> 189, the observed join-time point loss). The GameStart restore
  -- writes this value back over the engine's wrapped byte.
  t[#t + 1] = me.statPoints
  return t
end)

events.OnLoadPlayerData.add(function(data)
  -- Load REPLACES, never merges: start from a clean slate so a previous character's state (still in
  -- the runtime from this app session) can never blend into the one loading now.
  resetPersistedCharacterState()
  local n = #data
  local i = 1
  -- Section 1: kill counts, until the 0 marker.
  while i + 1 <= n and data[i] ~= 0 do
    allyKillCounts[data[i]] = data[i + 1]
    i = i + 2
  end
  -- Section 2: Bonded defensive bonuses, between the first and second 0 markers.
  if i <= n and data[i] == 0 then
    i = i + 1
    while i + 1 <= n and data[i] ~= 0 do
      bondedImmunity[data[i]] = data[i + 1]
      i = i + 2
    end
  end
  -- Section 3: Bonded recolour TRN variants, between the second and third markers.
  if i <= n and data[i] == 0 then
    i = i + 1
    while i + 1 <= n and data[i] ~= 0 do
      bondedTrn[data[i]] = data[i + 1]
      i = i + 2
    end
  end
  -- Section 4: recovery backups (seed, dwBuff, state) triples; the never-zero seed slot is the loop guard. state code: 0="lost", 1="injured", 2="lostfull".
  if i <= n and data[i] == 0 then
    i = i + 1
    while i + 2 <= n and data[i] ~= 0 do
      local code = data[i + 2]
      recoveryRegistry[data[i]] = {
        dwBuff = data[i + 1],
        state  = (code == 1) and "injured" or (code == 2) and "lostfull" or "lost",
        order  = nextRecoveryOrder(),
      }
      i = i + 3
    end
  end
  -- Section 5: deployed-ally roster (count, then 10-field records; see OnSavePlayerData). Stashed in pendingAllyRoster for the SP re-link. seed/parentId of 0 decode to nil.
  pendingAllyRoster = nil
  if i <= n and data[i] == 0 then
    i = i + 1
    local count = data[i] or 0
    i = i + 1
    local roster = {}
    for _ = 1, count do
      if i + 9 > n then break end -- truncated record; stop
      roster[#roster + 1] = {
        id                 = data[i],
        seed               = (data[i + 1] ~= 0) and data[i + 1] or nil,
        capturedDifficulty = data[i + 2],
        isMinion           = data[i + 3] == 1,
        parentId           = (data[i + 4] ~= 0) and data[i + 4] or nil,
        base               = {
          minDamage  = data[i + 5],
          maxDamage  = data[i + 6],
          toHit      = data[i + 7],
          armorClass = data[i + 8],
          maxHp      = data[i + 9],
        },
      }
      i = i + 10
    end
    if #roster > 0 then pendingAllyRoster = roster end
  end
  -- Trailing: the persistent monotonic scroll counter; take the max with the current value so it never goes backwards across saves / same-launch character swaps.
  if i <= n and data[i] ~= nil then
    if data[i] > scrollCounter then scrollCounter = data[i] end
    i = i + 1
  end
  -- The permanent per-character OHID. A save predating this field leaves myOhId nil, and getMyOhId
  -- lazily generates one on first use.
  if i <= n and data[i] ~= nil then
    myOhId = data[i]
    i = i + 1
  end
  -- Final section: scroll Original-Trainer provenance (count, then seed, ohId, byte-packed name each).
  if i <= n and data[i] ~= nil then
    local count = data[i]
    i = i + 1
    for _ = 1, count do
      if i + 1 > n then break end
      local seed         = data[i]
      local id           = data[i + 1]
      i                  = i + 2
      local name
      name, i            = unpackStringFromWords(data, i)
      scrollOrigin[seed] = { name = name, id = id }
    end
  end
  -- Trailing section: tamed-in gamemode (count, then that many Hellfire seeds). Only Hellfire (1) seeds
  -- are written; everything else defaults to Diablo (0).
  if i <= n and data[i] ~= nil then
    local count = data[i]
    i = i + 1
    for _ = 1, count do
      if i > n then break end
      scrollGamemode[data[i]] = 1
      i = i + 1
    end
  end
  -- Trailing section: tamed-in area level (count, then seed,areaLvl pairs).
  if i <= n and data[i] ~= nil then
    local count = data[i]
    i = i + 1
    for _ = 1, count do
      if i + 1 > n then break end
      scrollAreaLevel[data[i]] = data[i + 1]
      i = i + 2
    end
  end
  -- Trailing: true unspent stat points (see OnSavePlayerData). Stashed for the GameStart restore,
  -- which overwrites the engine's wrapped uint8; consumed once, like pendingAllyRoster.
  pendingStatPts = nil
  if i <= n and data[i] ~= nil then
    pendingStatPts = data[i]
    i = i + 1
  end
end)

-- Visual Polish

-- Compose an ally's display name matching the scroll-name convention: "Tamed/Bonded Lvl N [Name]", or no "Lvl N" for a unique. (prefix includes its trailing space.)
function allyDisplayName(monster, bonded, isUnique)
  local prefix = bonded and "Bonded " or "Tamed "
  if isUnique then return prefix .. monster.name end
  return prefix .. "Lvl " .. monster.level .. " " .. monster.name
end

events.OnGetMonsterDisplayName.add(function(monster)
  -- typeId is read straight off the live monster, so it covers own AND remote allies alike (no need to
  -- thread Diablo-ness through entry.seed / the CO-broadcast rec fields separately).
  local diablo = monster.typeId == DIABLO_TYPE_ID
  local entry = getDeployedAllyEntry(monster.id)
  if entry ~= nil then
    -- Our own ally/minion; unique-ness derives from the seed (the live monster reads back non-unique).
    if entry.isMinion then return monster.name .. " Minion" end
    return allyDisplayName(monster, isBonded(entry.seed, monster.level), diablo or seedGetUniqueType(entry.seed) >= 0)
  end
  -- Another Hunter's ally/minion (any hostility); nil until its broadcast record arrives.
  if isOtherHuntersAlly(monster) then
    local rec = remoteAllies[monster.id]
    if rec == nil then return nil end
    if rec.parentId ~= nil then return monster.name .. " Minion" end
    local bonded = rec.profile ~= nil and rec.profile.bonded
    return allyDisplayName(monster, bonded, diablo or (rec.uniqueIdx or -1) >= 0)
  end
  return nil
end)

-- Outline colors. Rendered from the local client's perspective (the observer is always MyPlayer).
ALLY_OUTLINE_COLOR         = 194 -- PAL16_YELLOW + 2; our own allies/minions
ALLY_OUTLINE_COLOR_HOVERED = 255 -- PAL16_GRAY + 15; brightest white, own ally hovered
OTHER_HUNTER_OUTLINE_COLOR = 183 -- PAL16_BLUE + 7; another Hunter's allies (friendly view only)

events.OnGetMonsterOutlineColor.add(function(monster)
  -- A monster at 0 HP never shows a selection outline (prevents the brief ally-outline flash on the death frame).
  if monster.hasNoLife then return nil end
  -- Our own allies/minions: always gold (white when hovered), regardless of hostility.
  if isDeployedAlly(monster.id) then
    local hovered = monsters.getHovered()
    if hovered ~= nil and hovered.id == monster.id then
      return ALLY_OUTLINE_COLOR_HOVERED
    end
    return ALLY_OUTLINE_COLOR
  end
  -- Another Hunter's ally: blue only while BOTH sides are friendly; else nil so the default enemy outline applies.
  if isOtherHuntersAlly(monster) then
    local me = player.self()
    local owner = player.get(monster.ownerPlayerId)
    if arePeaceful(me, owner) then
      return OTHER_HUNTER_OUTLINE_COLOR
    end
    return nil
  end
  return nil
end)

-- Bonded recolour + pre-Bonded flash, both via the per-frame monster TRN override. A Bonded ally wears the permanent recolour (bondedTrn[seed]); a near-Bonded ally blinks the flash colour on the FLASH_* cadence. Non-allies return nil (engine default).
events.OnGetMonsterTRN.add(function(monster)
  local entry = getDeployedAllyEntry(monster.id)
  if entry ~= nil then
    -- Our own ally: derive the tint live from its seed-keyed progression (a Bonded ally always has bondedTrn[seed] set).
    if isBonded(entry.seed, monster.level) then return BONDED_TRN_TABLE[bondedTrn[entry.seed]] end
    if flashOn and isOneKillFromBonded(entry) then return BONDED_FLASH_TRN end
    return nil
  end
  -- A remote-owned ally: the kill-derived Bonded state isn't visible on a peer, so drive the tint from the owner's CO profile.
  local rec = remoteAllies[monster.id]
  local prof = rec ~= nil and rec.profile or nil
  if prof == nil then return nil end
  if prof.bonded and prof.trnVariant ~= nil and prof.trnVariant > 0 then
    return BONDED_TRN_TABLE[prof.trnVariant]
  end
  if flashOn and prof.nearBonded then return BONDED_FLASH_TRN end
  return nil
end)

-- Fix up unique/Bonded tame scroll gold quality on level enter (covers a scroll picked up in a prior session).
events.OnLevelEnter.add(function()
  local p = player.self()
  if p == nil then return end
  if p.className ~= HUNTER_CLASS then return end
  p:iterateInventory(function(item)
    if not item:isScrollOf(TAME_ID) then return end
    -- Announce each carried scroll's identity blob so peers (incl. a late joiner) have it cached for a trade. No-op in SP.
    broadcastScrollData(item.seed)
  end)
end)

-- Tame Scroll class restriction: only Hunters may pick up (and hold) Tame Scrolls; Hunter-to-Hunter trade still works.
events.OnPlayerCanPickUpItem.add(function(p, item)
  if item:isScrollOf(TAME_ID) and p.className ~= HUNTER_CLASS then
    return false
  end
end)

-- Tame Scrolls are never sellable to a vendor (taming / Pepin buy-back only); veto the buy-from-player check.
events.OnVendorWillBuyItem.add(function(item)
  if TAME_ID ~= nil and item:isScrollOf(TAME_ID) then return false end
end)

-- Re-stamp every picked-up Tame Scroll into THIS character's own monotonic seed space, so two players' scrolls can never share a seed (collision-proof trading). Lossless via the self-describing modData blob; also (re)applies gold quality.
events.OnItemPickedUp.add(function(p, floorItem)
  -- Local player only: AutoGetItem runs on every client, but re-stamping must mutate only OUR own inventory item.
  local me = player.self()
  if me == nil or p.id ~= me.id then return end
  if p.className ~= HUNTER_CLASS then return end
  if not floorItem:isScrollOf(TAME_ID) then return end
  local oldSeed = floorItem.seed

  -- Locate the LIVE copy we just picked up, matching seed + dwBuff + modData (not seed alone) so a transient seed collision re-stamps the acquired scroll, not an existing one.
  -- Check the HAND first: on the click-pickup path (InvGetItem, inventory panel open) the acquired copy
  -- is a direct struct copy of the floor item held on the cursor, not in an inventory slot. Mutations to
  -- the hand copy are live, and the later paste carries them into the slot.
  local invItem = nil
  local held = p:heldItem()
  if held ~= nil and held:isScrollOf(TAME_ID) and held.seed == oldSeed
      and held.buff == floorItem.buff and held.modData == floorItem.modData then
    invItem = held
  end
  if invItem == nil then
    p:iterateInventory(function(it)
      if invItem ~= nil then return end
      if it:isScrollOf(TAME_ID) and it.seed == oldSeed
          and it.buff == floorItem.buff and it.modData == floorItem.modData then
        invItem = it
      end
    end)
  end
  if invItem == nil then return end

  -- Source the scroll's identity by explicit precedence, first non-empty wins:
  --   1. the item's own blob — set by the dropper's local spawn or restored from the level delta by
  --      DeltaLoadItems; empty only when the engine recreated the item from the item wire (which by
  --      design carries no blob);
  --   2. the level-delta blob — the authoritative at-rest copy (written by placeScrollOnFloor / the
  --      dropper's OnItemDropped and mirrored by every SD receiver; survives a session restart);
  --   3. the live SD cache (receivedBlobs) — same content as 2 for a floor item; also covers a scroll
  --      announced while held (no level, so no delta entry);
  --   4. our own tables (re-pickup of a scroll we already know).
  -- Every channel is written from live state at drop/announce time, so whichever is present is current;
  -- no cross-channel freshness comparison is needed.
  local blob = invItem.modData or ""
  if blob == "" then blob = items.getItemDeltaModData(items.currentDeltaLevel(), oldSeed) end
  if blob == "" then blob = receivedBlobs[oldSeed] or "" end
  if blob == "" then blob = blobForSeed(oldSeed) end
  local kills, immIdx, trnVar, gamemode, areaLvl, ohId, ohName = decodeBlob(blob)
  local immVal = IMMUNITY_BY_INDEX[immIdx]

  -- Fresh seed in our own counter space, preserving the scroll's type / unique identity.
  local uIdx = seedGetUniqueType(oldSeed)
  local newSeed = (uIdx >= 0) and allocSeed(nil, uIdx) or allocSeed(seedToTypeId(oldSeed), nil)

  -- The Original Trainer rides INSIDE the blob (the true tamer travels with the scroll); fall back to the seed-keyed cache only if the blob had no name.
  local origin = (ohName ~= nil and ohName ~= "") and { name = ohName, id = ohId } or scrollOrigin[oldSeed]

  invItem.seed = newSeed
  if kills > 0 then allyKillCounts[newSeed] = kills end
  if immVal ~= nil then bondedImmunity[newSeed] = immVal end
  if trnVar > 0 then bondedTrn[newSeed] = trnVar end
  if origin ~= nil then scrollOrigin[newSeed] = origin end
  if gamemode == 1 then scrollGamemode[newSeed] = 1 end          -- carry the tamed-in gamemode (Diablo = default 0)
  if areaLvl > 0 then scrollAreaLevel[newSeed] = areaLvl end     -- carry the tamed-in area level
  tameScrollData[newSeed] = nil                                  -- rebuilt from seed+dwBuff on cast
  invItem.modData = blobForSeed(newSeed)                         -- re-key the held blob to the fresh seed (a live-trade item arrived empty)

  -- Drop the old seed's tables only if no OTHER held scroll still uses it (so a transient collision never deletes a different scroll's data).
  if p:findScrollBySeed(oldSeed) == nil then
    allyKillCounts[oldSeed]  = nil
    bondedImmunity[oldSeed]  = nil
    bondedTrn[oldSeed]       = nil
    scrollOrigin[oldSeed]    = nil
    scrollGamemode[oldSeed]  = nil
    scrollAreaLevel[oldSeed] = nil
    tameScrollData[oldSeed]  = nil
    receivedBlobs[oldSeed]   = nil
  end
  -- The floor item is gone; drop its blob from the level delta to keep the per-level store bounded.
  items.setItemDeltaModData(items.currentDeltaLevel(), oldSeed, "")

  -- Re-derive name + gold from the just-restored tables (the floor copy was recreated from the vanilla
  -- item wire, which carries neither modData nor the encoded name — before this restamp a traded Bonded
  -- scroll kept reading "Tamed" until the next recreate round-trip).
  restampScrollPresentation(invItem)

  -- Announce this scroll's identity under its fresh seed so peers can show the true tamer / restore it on a later trade.
  broadcastScrollData(newSeed)
end)

-- A manually dropped Tame Scroll (the trade mechanism): persist its identity with the floor item in the level delta + announce it live, so the picker (present or a late joiner) restores it. Catches a hand-drag the drop helpers don't.
events.OnItemDropped.add(function(p, item)
  if TAME_ID == nil then return end
  local me = player.self()
  if me == nil or p.id ~= me.id then return end
  if me.className ~= HUNTER_CLASS then return end
  if not item:isScrollOf(TAME_ID) then return end
  local seed = item.seed
  local lvl = items.currentDeltaLevel()
  items.setItemDeltaModData(lvl, seed, blobForSeed(seed))
  broadcastScrollData(seed, lvl)
end)

-- Hijack the unique item info popup for a gold-tier tame scroll: populate the custom slot with tamed monster stats and return true so it renders instead of UniqueItems[_iUid] (which would show The Butcher's Cleaver).
events.OnPrepareUniqueInfoBox.add(function(item)
  if not item:isScrollOf(TAME_ID) then return end
  local uIdx   = seedGetUniqueType(item.seed)
  local diablo = seedIsDiablo(item.seed)
  local bonded = scrollIsBonded(item)
  -- Fires for any gold-tier scroll (seed-unique champions/bosses, Diablo, AND Bonded normal scrolls); a plain scroll falls through to the engine box.
  if uIdx < 0 and not diablo and not bonded then return end

  local savedHp, maxHp, level, difficulty = decodeDwBuff(item.buff)
  if maxHp == 0 then maxHp = savedHp end
  if savedHp == 0 then savedHp = maxHp end
  local diffNames = { [0] = "Normal", [1] = "Nightmare", [2] = "Hell" }
  local diff      = diffNames[difficulty] or "Normal"
  local kills     = allyKillCounts[item.seed] or 0
  local prefix    = bonded and "Bonded " or "Tamed "

  local monsterName, tier
  if uIdx >= 0 then
    monsterName = monsters.getUniqueName(uIdx) or "Unknown"
    tier = BOSS_NAMES[monsterName] and "Boss" or "Champion"
  elseif diablo then
    monsterName = monsters.getNameByTypeId(DIABLO_TYPE_ID) or "Unknown"
    tier = "Boss" -- Diablo is always a Boss, independent of Bonded state
  else
    monsterName = monsters.getNameByTypeId(seedToTypeId(item.seed)) or "Unknown"
    tier = "Bonded" -- a Bonded normal monster has no champion/boss tier of its own
  end

  items.setCustomUniqueBox(prefix .. monsterName, {
    tier .. " (" .. diff .. ")",
    "Level: " .. level,
    "HP: " .. savedHp .. " / " .. maxHp,
    "Kills: " .. kills,
  })
  return true
end)
