local events   = require("devilutionx.events")
local spells   = require("devilutionx.spells")
local player   = require("devilutionx.player")
local monsters = require("devilutionx.monsters")
local items    = require("devilutionx.items")
local audio    = require("devilutionx.audio")
local message  = require("devilutionx.message")
local system   = require("devilutionx.system")
local render   = require("devilutionx.render")

-- Talk to the LuaNet net-multiplexer WITHOUT a hard cross-mod require. The LuaNet mpq publishes its
-- API onto the shared devilutionx.events table (the SAME table instance in every mod's sandbox), so
-- we just read events.luanet at call time -- no dependency on loading LuaNet's files, and no load-order
-- requirement. If the LuaNet mpq isn't enabled, events.luanet stays nil and these are no-ops (MP net
-- inert; single-player and the class are unaffected). `luanet` is one of the few top-level locals (see
-- the convention note below): the inter-mod surface (module requires + this net bridge) stays local.
local luanet
do
  local pending = {}  -- channel -> handler, applied once LuaNet becomes available
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
  -- GameStart fires after every mod has loaded, so flush any registration LuaNet wasn't available for
  -- at our load time (covers this mod loading before the LuaNet mpq in the list). Guarded so a missing
  -- event can never abort init.lua.
  if events.GameStart ~= nil then
    events.GameStart.add(function()
      for ch, h in pairs(pending) do apply(ch, h) end
    end)
  end
end

-- Reserve extra per-level monster-TYPE slots so a full party of Hunters can deploy distinct
-- tamed types without overrunning the engine's level type table (base cap MaxLvlMTypes = 24).
-- Worst case: 4 Hunters x 8 deployed allies = 32 potentially-distinct types. Load-time only.
-- CONVENTION: nearly every top-level declaration below is an intentionally plain (sandbox-global)
-- assignment rather than `local`. Lua caps a function's main chunk at 200 active locals+upvalues, and
-- this file is large; globals don't count against that cap, need no usage changes, and live only in this
-- mod's own sandbox env, so nothing leaks to other mods. `local` is reserved for the inter-mod surface
-- ONLY: the module requires at the top, the `luanet` bridge, and the net layer (the `NET` tag table and
-- the broadcast*/credit forward-decls) -- i.e. the handles used to talk to the engine modules and the
-- LuaNet multiplexer. Everything else (constants, state tables, helper functions) is a sandbox global.
MAX_HUNTERS              = 4
MAX_DEPLOYED_PER_HUNTER  = 8
-- Extra monster-TYPE slots (distinct tamed species across the party).
monsters.requestExtraTypes(MAX_HUNTERS * MAX_DEPLOYED_PER_HUNTER)
-- Extra live-monster slots so deployed allies don't compete with natural spawns for the
-- base 200-slot array. Engine clamps the effective cap to 252 (uint8 enemy-encoding ceiling),
-- which comfortably fits ~190 natural spawns + 32 allies.
monsters.requestExtraMonsters(MAX_HUNTERS * MAX_DEPLOYED_PER_HUNTER)

-- Queued in SpellDataLoaded, resolved in SpellsAssigned (see spells.registerSpell below).
TAME_ID              = nil
SHARE_POTION_ID      = nil
FORGET_POTION_ID     = nil
TAME_SCROLL_MAP      = 90001   -- mapping ID for Tame Scroll base item; no clash with base items
FORGET_POTION_MAP    = 90002   -- mapping ID for Potion of Forgetting
FORGET_POTION_PRICE  = 1000000 -- gold cost in Pepin's shop
-- The Potion of Forgetting is session-only: it is transiently popped from the local inventory across
-- each hero-file write (OnBeforeSaveHero) and put back in its exact slot afterwards (OnAfterSaveHero),
-- so it is never serialised and never survives into a freshly loaded game (exit, quit, crash, or
-- force-close). This holds the {ref=liveSlot, saved=poppedCopy} records for one write.
forgetPotionSnapshot = nil

-- tameScrollData[seed] = { typeId, savedHp, maxHp, name, level }
-- Session cache only; rebuilt from seed+dwBuff encoding on post-restart cast.
tameScrollData = {}

-- List of { monster, seed } for all currently deployed allies.
deployedAllies = {}

-- Parallel monsterId -> entry index over deployedAllies for O(1) membership tests.
-- The hot per-tick / per-frame hooks all test ally membership: OnGolemCanTargetMonster fires
-- once per active monster per ally per tick (golem target scan), OnGetMonsterOutlineColor once
-- per drawn monster per frame, plus the OnGolemChooseAction / OnGolemIdle chain every tick. A
-- linear scan made each test cost O(allies), so total per-tick work grew with the SQUARE of the
-- deployed count — the documented "performance degrades with more deployed Tamed monsters" issue.
-- Always mutate deployedAllies through trackDeployedAlly / untrackDeployedAt to keep this in sync.
deployedAlliesById = {}

-- Plane-1, runtime-only (never saved): registry of allies owned by ANOTHER client, recreated locally
-- from a net SP message. These are NOT our own allies (those live in deployedAllies). Their AI runs
-- deterministically on EVERY client (same as a vanilla golem) — we no longer suppress it — so this
-- table is the peer-side mirror of an own-ally tracking entry, holding the per-ally scratch the shared
-- AI hooks need to behave identically here as on the owner:
--   remoteAllies[monsterId] = { ownerId, parentId (minions only), capturedDifficulty, uniqueIdx, profile (combat CO) }
-- Keyed by per-level monster slot id, so cleared on every level change / game start.
remoteAllies = {}

-- Plane-2, runtime-only: seed -> ally `data` for a deploy we requested from the level owner because we
-- are NOT the level owner (monster spawning is level-owner-authoritative; see the DR/SP net flow). The
-- owner spawns the ally and echoes it back as SP, where we complete the deferred local Plane-2 setup; if
-- the owner can't place it, it echoes DF and we refund. Cleared on every level change / game start.
pendingDeploys = {}

-- Saved deployed-ally roster awaiting re-link, populated by OnLoadPlayerData (Section 5 of the
-- mod-data save) and consumed on the next level entry. Lets a single-player "Load Game" from inside
-- a dungeon restore allies as tracked deployed monsters (re-bound to their reloaded golems by stable
-- monster slot id) instead of orphaned golems. nil when there is nothing to re-link.
pendingAllyRoster = nil


-- Last-seen fingerprint of the Hunter's buff-relevant stats (CLVL + the four character-sheet
-- stats the buff pool scales off). Polled in GameDrawComplete to re-derive ally buffs on a live
-- CLVL-up or gear swap mid-deployment; recalc fires only when this string changes.
lastBuffFingerprint = nil

-- monsterId -> true for a deployed ally that has just died and must NOT leave a corpse on the
-- floor. Recorded in OnMonsterDeath (which fires at the start of the death, while the ally is still
-- in deployedAllies) and consumed in OnMonsterCanPlaceCorpse (which fires later, on the final death
-- frame, AFTER we have already untracked the ally — so membership can no longer be tested there).
-- Our tamed monsters vanish on death; the loss is conveyed by the disappearance (and, later, the
-- Farnham recovery flow) rather than a corpse, which also keeps them off the limited corpse table.
-- A vanilla Golem is never in deployedAllies, so it is never recorded here and keeps its corpse.
corpselessDeaths = {}

-- allyKillCounts[seed] = integer kill count.
-- Keyed by scroll seed so kills persist across redeploy cycles.
allyKillCounts = {}

function trackDeployedAlly(entry)
  entry.id = entry.monster.id  -- capture the id once: serves as the map key and lets untrack
                               -- work even if the monster userdata later goes stale (e.g. on death)
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

-- True for ANY tamed ally/minion the local client knows about: one of our own deployed allies, OR a
-- remote-owned ally we recreated from the net. The per-tick AI hooks gate on this (not isDeployedAlly)
-- so they run identically on the owner and on peers — the precondition for deterministic, in-lockstep
-- AI across clients. A vanilla Golem is in neither table, so it is never treated as a tamed ally.
function isTamedAlly(monsterId)
  return deployedAlliesById[monsterId] ~= nil or remoteAllies[monsterId] ~= nil
end

-- The Player that owns this ally, resolved from the live monster's ownerPlayerId. Works uniformly for
-- our own allies (ownerPlayerId == local id → returns the local player) and remote allies (returns the
-- remote owner), so an AI hook can anchor to the owner the same way on every client. nil if no such
-- player. Replaces player.self()/cachedOwner in the AI hooks (those were owner-only).
function allyOwner(monster)
  return player.get(monster.ownerPlayerId)
end

-- The per-ally record the shared AI hooks read identity/combat state from (capturedDifficulty, cached
-- combat profile). For an own ally it is the deployedAllies entry; for a remote ally it is the
-- remoteAllies record. Only ever read for fields both shapes carry. IMPORTANT: do NOT cache a per-tick
-- AI *decision* here — the two records are populated at different ticks (own at deploy, remote when the
-- SP arrives on a late joiner), so a value cached at "first use" would differ across clients and desync.
-- Decisions that must agree across clients are derived from the synced tick instead (see syncedHash /
-- system.gameTick, used by OnGolemIdle).
function allyScratch(monsterId)
  return deployedAlliesById[monsterId] or remoteAllies[monsterId]
end

-- True when players a and b are both in friendly (non-hostile) mode. nil-safe.
-- Shared by the outline color logic and the pet-vs-pet targeting logic so the visual
-- relationship (blue vs red) and the combat relationship can never disagree.
function arePeaceful(a, b)
  return a ~= nil and b ~= nil and a.friendlyMode and b.friendlyMode
end

-- Should the LOCAL (observing) player see the rich Tamed-pet info readout for this monster?
-- True for our OWN deployed ally/minion (always), or a NON-HOSTILE other player's tamed pet
-- (any observer class — the info is not Hunter-gated). A hostile player's pet falls through to
-- vanilla. Drives both the regular info box (Type + resistances) and the floating stat box.
function isFriendlyTamedView(monster)
  if monster == nil then return false end
  if isDeployedAlly(monster.id) then return true end        -- our own ally/minion
  if remoteAllies[monster.id] == nil then return false end   -- not a tamed pet we track
  return arePeaceful(player.self(), player.get(monster.ownerPlayerId))
end

function countDeployedAllies()
  local n = 0
  for _, entry in ipairs(deployedAllies) do
    if not entry.isMinion then n = n + 1 end
  end
  return n
end

-- Per-character monotonic counter for Tame Scroll seeds. A seed is encoded as:
--   bits 12-31 = counter (1..1048575), bits 0-11 = type field
--   (bit 11 = UNIQUE_SEED_FLAG, bits 0-10 = typeId or uniqueTypeIdx, 0..2047).
-- The counter is persisted per character (OnSave/OnLoadPlayerData) and NEVER reset, so a character
-- can never re-issue a seed it has already used — eliminating cross-session seed collisions for a
-- single character. (Cross-PLAYER collision-proofing — re-stamping a picked-up scroll into the new
-- owner's counter space — lands with the scroll self-description step, which lets the re-stamp carry
-- the ally's data off the item instead of losing it.)
scrollCounter = 1

-- Class name constant used for MP-safe class guards.
HUNTER_CLASS = "Hunter"

-- ---- Original-Hunter ID (OHID) -----------------------------------------------------------------
-- A permanent per-character "trainer ID": one 9-digit number generated once when a Hunter is created
-- and persisted in that Hunter's save (OnSave/OnLoadPlayerData, trailing field after scrollCounter).
-- Paired with the Hunter's character NAME it labels every monster that Hunter owns in the pet info
-- readout. The OH *name* is never stored — it is always the owning Hunter's player name (read locally,
-- or via player.get(ownerId) for a peer), so only this one integer needs to persist / sync.
myOhId = nil

-- Deterministic, overflow-safe string hash (polynomial mod 1e9; the running value stays under 31e9,
-- well within the 2^53 exact-integer range of a Lua number, so no precision loss).
function hashString(s)
  local h = 0
  for i = 1, #s do
    h = (h * 31 + s:byte(i)) % 1000000000
  end
  return h
end

-- Generate a fresh 9-digit OHID from the character name + creation timestamp (os.time, whitelisted in
-- the sandbox). Two same-named characters created at different seconds still differ; same-second is
-- a cosmetic-only collision with no mechanical effect.
function generateOhId(name)
  return (hashString(name or "") + (os.time() % 1000000000)) % 1000000000
end

-- The local Hunter's OHID, lazily generating+caching one if the active save predates the field.
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

-- ---- Scroll "Original Trainer" (OH) provenance ------------------------------------------------
-- seed -> { name = <original Hunter's character name>, id = <their OHID> }. Captured at Tame time and
-- kept PERMANENTLY with the monster, Pokémon-style. It rides INSIDE the scroll's mod-data blob (see
-- blobForSeed), so it travels with the item — on the level delta for a dropped floor item and live over the
-- LuaNet "SD" message — and is also persisted out-of-band in the luamoddata save. A scroll with no recorded
-- origin falls back to the local Hunter (see originForSeed).
scrollOrigin = {}

-- Blobs heard over the LuaNet "SD" message keyed by seed: a peer announces a scroll's full mod-data blob so
-- that if we later receive that scroll via a live trade (the floor item carries no blob over the wire), the
-- pickup can restore its identity from here. (A scroll dropped by a player who then LEFT is instead restored
-- from the level delta — see items.setItemDeltaModData / item.modData.)
receivedBlobs = {}

-- Forward declaration: announces a scroll's full identity blob to peers keyed by seed (no-op in SP).
-- Assigned in the net section once the message type + luanet.send are in scope.
local broadcastScrollData

-- Forward declaration: replicates a freshly dropped Tame Scroll floor item onto same-level peers so
-- the item exists on every client (incl. the level owner, whose delta is authoritative). Assigned in
-- the net section. Used by the floor-drop helpers above, which run before that section is reached.
local broadcastDropScroll

-- The origin to display for a scroll/pet seed: the recorded Original Trainer, or the local Hunter as a
-- fallback for a freshly tamed scroll not yet stamped. nil only when there is no local player.
function originForSeed(seed)
  local o = scrollOrigin[seed]
  if o ~= nil then return o end
  local me = player.self()
  if me == nil then return nil end
  return { name = me.name, id = getMyOhId() }
end

-- The luamoddata save blob is a uint32 sequence, so a name string is byte-packed: a length word, then
-- ceil(len/4) data words (4 bytes little-endian each). unpack reverses it, returning the string and the
-- next read index. Used by OnSave/OnLoadPlayerData for the scrollOrigin section.
function packStringToWords(t, s)
  s = s or ""
  local len = #s
  t[#t + 1] = len
  local i = 1
  while i <= len do
    local w = 0
    for j = 0, 3 do
      local b = (i + j <= len) and s:byte(i + j) or 0
      w = w + b * (2 ^ (8 * j))
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

-- Is this monster a tamed ally/minion belonging to *another* Hunter (not us)?
-- Detected from engine state alone (golem flag + owner's class), because that Hunter's
-- deployedAllies table is client-local and invisible to us. Minions inherit their owner from
-- the parent ally (goalVar3), so they resolve here exactly like a directly-tamed ally.
function isOtherHuntersAlly(monster)
  if not monster.isGolem then return false end
  local me = player.self()
  if me == nil then return false end
  local ownerId = monster.ownerPlayerId
  if ownerId == me.id then return false end
  local owner = player.get(ownerId)
  return owner ~= nil and owner.className == HUNTER_CLASS
end

-- Is `monster` an ally that `attacker` must never direct an offensive action at?
--   - the attacker's own deployed ally/minion (always), or
--   - another Hunter's pet while the two players are at peace.
-- Shared by every offensive-action gate (left-click attack, offensive scroll cast,
-- staff-charge cast) so the one protection rule lives in a single place. nil-safe:
-- monster is nil when no monster is under the cursor (e.g. a charge/scroll aimed at an
-- empty tile) -> not protected, nothing to guard.
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

-- Named quest bosses: require Tame++ (level 45, ≤10% HP) to tame.
-- Regular unique monsters (champions) only require Tame+ (level 30, ≤20% HP).
BOSS_NAMES = {
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

-- typeId 16 = MT_NSCAV (Scavenger); row 18 of monstdat.tsv, 0-based index.
-- HP values from monstdat.tsv hitPointsMaximum column (Normal difficulty).
STARTER_TYPE_ID  = 16
STARTER_LEVEL    = 2
STARTER_MAX_HP   = 6
STARTER_NAME     = "Scavenger"

-- Bit 15 of the seed's lower 16 bits marks a unique-monster scroll.
-- All normal typeIds are well below 32768 so this flag never collides.
UNIQUE_SEED_FLAG = 0x800  -- bit 11 of the 12-bit type field marks a unique-monster scroll

function allocSeed(typeId, uniqueTypeIdx)
  local counter = scrollCounter   -- monotonic, never reused (see scrollCounter)
  scrollCounter = scrollCounter + 1
  if uniqueTypeIdx ~= nil and uniqueTypeIdx >= 0 then
    return counter * 4096 + UNIQUE_SEED_FLAG + uniqueTypeIdx
  end
  return counter * 4096 + (typeId % 2048)
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

-- Defined here (after seedGetUniqueType) on purpose: a Lua `local function` that
-- references a local declared later in the file binds it as a nil global instead,
-- which threw inside the deploy loop whenever any ally was already deployed.
function isUniqueTypeDeployed(uniqueTypeIdx)
  for _, entry in ipairs(deployedAllies) do
    if seedGetUniqueType(entry.seed) == uniqueTypeIdx then return true end
  end
  return false
end

-- dwBuff encoding layout (all fields are unsigned integers, bit 0 = CF_HELLFIRE = 0):
--   Bits  1-15 : maxHp display value (0..32767, full resolution)
--   Bits 16-21 : monster level (0..63; monster levels never exceed 30 in practice)
--   Bits 22-23 : capturedDifficulty (0=Normal 1=Nightmare 2=Hell)
--   Bits 24-31 : savedHp as a percent of maxHp (0..100); current HP = round(maxHp * pct / 100)
-- Storing maxHp at full resolution keeps a tamed monster's Max HP STABLE across recall/redeploy:
-- the live monster's maxHitPoints is restored verbatim from this value on deploy instead of being
-- re-rolled from the type's HP range (a re-roll would drift with each recast and with dlvl). Current
-- HP is stored relative to max.
-- Current HP is never above max (recall clamps savedHp to maxHp), so pct fits in 7 bits; bits 24-31
-- are read as a byte for simplicity. dwBuff is a uint32_t engine-side and these bits are safe because
-- RecreateItem(createInfo=0) ignores dwBuff entirely and IsDungeonItemValid always passes (see below).
-- Kill count is stored in allyKillCounts and persisted via OnSavePlayerData/OnLoadPlayerData.
-- Difficulty is frozen at tame time so cross-game deploys keep original scaling.
-- RecreateItem with _iCreateInfo=0 ignores dwBuff entirely, so these bits are safe.
-- IsItemDeltaValid passes because IsDungeonItemValid(createInfo=0, dwBuff) always returns true.
function encodeDwBuff(savedHp, maxHp, level, difficulty)
  local mhp = math.min(math.max(math.floor(maxHp), 0), 32767)
  local hp  = math.max(math.floor(savedHp), 0)
  local pct = 0
  if mhp > 0 and hp > 0 then
    pct = math.floor(hp / mhp * 100 + 0.5)
    if pct < 1 then pct = 1 end       -- a living ally must never round down to 0%
    if pct > 100 then pct = 100 end   -- current HP is never above max
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

-- =========================================================================
-- Recovery registry — a backup ledger of deployed allies so a death, crash, quit, or full inventory
-- never permanently loses a Tame Scroll. Each entry is fully rebuildable from (seed, dwBuff): the
-- seed encodes type/uniqueness, the dwBuff encodes HP/level/difficulty (see encode/decodeDwBuff), so
-- the name is re-derived and the scroll re-created on demand. State is internal-only (never shown):
--   "lost"    = alive but never recalled (crash, quit, or full inventory on level change) -> free.
--   "injured" = died in the dungeon -> paid recovery (level * RECOVERY_INJURED_COST_PER_LEVEL).
-- Persisted via OnSavePlayerData/OnLoadPlayerData; surfaced for buy-back in Pepin's store.
-- recoveryRegistry[seed] = { dwBuff = uint32, state = "lost"|"injured", order = n }
-- =========================================================================
recoveryRegistry = {}
RECOVERY_CAP = MAX_DEPLOYED_PER_HUNTER  -- mirror the deploy cap; evict oldest past this
RECOVERY_INJURED_COST_PER_LEVEL = 100

-- Monotonic insertion order, used only to pick the oldest entry to evict at the cap.
recoveryOrderCounter = 0
function nextRecoveryOrder()
  recoveryOrderCounter = recoveryOrderCounter + 1
  return recoveryOrderCounter
end

-- Allies whose final death frame should spawn the Resurrect beam FX. Set in OnMonsterDeath (while the
-- ally is still identifiable) and consumed one frame later in OnMonsterCanPlaceCorpse, mirroring the
-- corpselessDeaths handoff. Cleared on level exit so a reused monster id never inherits a stale beam.
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

-- =========================================================================
-- Ally Progression: Tamed -> Bonded promotion + CLVL-scaled stat buffs.
-- Tamed allies gain stats scaled off the Hunter's own; enough kills promote one to
-- Bonded (a defensive immunity + doubled buff share + visual aura). Minions and
-- spellcaster allies are buffed on their own paths (see the relevant handlers below).
-- =========================================================================

-- Resistance bitflags exposed by the engine (monsters.Resistance.*).
RES = monsters.Resistance
BONDED_IMMUNE_OPTIONS = { RES.ImmuneFire, RES.ImmuneMagic, RES.ImmuneLightning }
-- Each immunity supersedes the same-element resistance. Base-game monsters never carry both a
-- Resist and an Immune of the same element, so when a Bonded roll grants an immunity for an element
-- the ally already resisted, we drop that resistance to match vanilla's infobox/healthbar UI pattern.
BONDED_IMMUNE_SUPERSEDES = {
  [RES.ImmuneFire]      = RES.ResistFire,
  [RES.ImmuneMagic]     = RES.ResistMagic,
  [RES.ImmuneLightning] = RES.ResistLightning,
}
-- Sentinel stored in bondedImmunity for the "already has all three immunities -> +200 AC" fallback.
-- Distinct from any IMMUNE_* flag (8/16/32); stored verbatim in the save blob.
BONDED_AC       = 4096
BONDED_AC_BONUS = 200
BONDED_KILLS_PER_LEVEL = 100

-- Kill-scaled ToHit bonus: +1% per KILL_TOHIT_PER kills, hard-capped at KILL_TOHIT_CAP%.
KILL_TOHIT_PER = 10
KILL_TOHIT_CAP = 500

-- ---- Pre-Bonded "about to evolve" flash FX -----------------------------
-- A Tamed ally one kill short of Bonded flashes as a tell. Built as a registered all-one-colour TRN
-- (palette remap) toggled on/off through the generic OnGetMonsterTRN render hook.
-- BONDED_FLASH_COLOR is the palette index every sprite pixel is drawn as while flashing. Any index in
-- the global sprite range 128-255 is cross-palette consistent (developmentNotes.md "cross-palette trap"),
-- so the choice is purely thematic: 0xB0 (the lightest slate blue) matches the Hunter's blue theme
-- (grayscale crypt/cathedral palettes desaturate it to light gray, as expected).
-- Cadence (two independent knobs, frame-driven — GameDrawComplete runs once per RENDERED frame, not
-- per logic tick, so both are FPS-relative; no Lua tick source exists):
--   FLASH_PERIOD_FRAMES = how OFTEN a blink starts (one rising edge per period → the frequency).
--   FLASH_ON_FRAMES     = how long it HOLDS the solid-blue peak each blink (the dwell at the top).
-- The two are orthogonal: raising the dwell holds the peak longer without changing the frequency.
-- 80/20 = a blink every ~1.3s @60fps, holding blue for 1/4 of each cycle. Tune to taste.
BONDED_FLASH_COLOR  = 0xB0
FLASH_PERIOD_FRAMES = 80
FLASH_ON_FRAMES     = 20
function buildSolidTrn(colorIndex)
  local t = {}
  for i = 1, 256 do t[i] = colorIndex end
  return t
end
-- Registered once at load; the handle is returned from OnGetMonsterTRN while a flash is "on".
BONDED_FLASH_TRN  = monsters.registerTrn(buildSolidTrn(BONDED_FLASH_COLOR))
flashFrameCounter = 0

-- Bonded "aura" glow: a permanent light source on a Bonded ally (the same engine mechanic 'lighted'
-- unique monsters use — AddLight, auto-followed by MonsterWalk/SyncLightPosition, auto-freed on
-- death/recall). Light is monochrome brightness (no colour in vanilla), so it reads as a glowing
-- presence; the blue sprite tint (OnGetMonsterTRN) is what distinguishes it from a unique's aura.
-- Kept small (the unique default is 3) since up to 8 Bonded allies could be lit at once; tune here.
BONDED_LIGHT_RADIUS = 3
function applyBondedGlow(entry)
  if entry.monster ~= nil then entry.monster:setLightRadius(BONDED_LIGHT_RADIUS) end
end

-- ---- Bonded recolour TRNs (one per defensive bonus) --------------------
-- A Bonded ally's permanent tint READS its rolled bonus at a glance: each immunity (and the +200 AC
-- fallback) has its own high-contrast recolour, plus a rare Hell-only "Gilded Metal" variant.
-- SCATTER model: each variant is a short repeating PATTERN of palette entries, indexed by a source
-- pixel's brightness RANK (rank % #pattern). Slots holding a colour repaint the pixel a FIXED BRIGHT
-- colour; a `false` slot keeps the monster's own pixel. Diablo sprites are already checkerboard-DITHERED
-- between adjacent shades (the art fakes gradients that way), so cycling two bright colours + identity
-- across consecutive ranks turns that built-in dither into a vivid, spotty [colourA]/[colourB]/[original]
-- pattern -- bright and high-contrast WITHOUT clobbering the monster's identity (a tan Zombie still reads
-- tan, speckled with its immunity colours). Earlier bakes mapped each pixel to its rank-matched gradient
-- entry, so most pixels (low ranks) got the DARK end and the look came out dull + sparse; fixed bright
-- colours fix that. TUNE: density = ratio of colours to `false` in the pattern ({A,B} = full/solid two-
-- tone, {A,B,false} = ~2/3 bright + 1/3 original, {A,B,false,false} = sparser); brightness/hue = the
-- entries themselves (use bright ramp entries, see bases below).
-- CROSS-PALETTE CORRECTNESS: only the global sprite range 128-255 is recoloured -- per palette.h those
-- entries have IDENTICAL RGB in every area palette (where monster/player sprites live), so the look is
-- the same in every dungeon. Indices 0-127 are LEVEL-SPECIFIC, so they are left strictly IDENTITY (we
-- have no cross-palette brightness for them; sprites barely use them). Every colour entry is >= 128.
-- Palette ramp bases (palette.h): PAL16 BEIGE 160, BLUE 176, YELLOW 192, ORANGE 208, RED 224, GRAY 240
-- (each +0 darkest .. +15 brightest); so e.g. bright red ~230, bright yellow ~205, bright blue ~186,
-- white ~254.
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
-- Bake a 256-entry TRN by cycling `pattern` across brightness ranks. A numeric slot repaints the pixel
-- that fixed bright colour; a `false` slot keeps the monster's own (baked) pixel. map[i+1] = drawn colour.
function buildScatterTrn(pattern)
  local n = #pattern
  local t = {}
  for i = 0, 255 do
    local target = i  -- default / level-specific 0-127: keep the monster's own pixel
    if i >= 128 then
      local slot = pattern[(brightnessRank(i) % n) + 1]
      if slot then target = slot end
    end
    t[i + 1] = target
  end
  return t
end
-- Registered TRN handles, indexed by variant (1..5). Pattern = bright colourA, bright colourB, then
-- `false` (keep original) for ~2/3 bright coverage. Drop the `false` for solid; add more for sparser.
BONDED_TRN_TABLE = {
  monsters.registerTrn(buildScatterTrn { 230, 205, false }), -- 1 Fire:      bright red   + bright yellow
  monsters.registerTrn(buildScatterTrn { 186, 254, false }), -- 2 Lightning: bright blue  + white
  monsters.registerTrn(buildScatterTrn { 254, 230, false }), -- 3 Magic:     white        + bright red
  monsters.registerTrn(buildScatterTrn { 240, 253, false }), -- 4 +200 AC:   near-black grey + bright grey
  monsters.registerTrn(buildScatterTrn { 203, 255, false }), -- 5 Gilded:    gold         + white-gold
}
-- Map a rolled bonus to its default variant; Gilded (5) is the Hell-only override (see rollBondedTrn).
BONDED_TRN_GILDED = 5
BONDED_TRN_BY_IMMUNITY = {
  [RES.ImmuneFire]      = 1,
  [RES.ImmuneLightning] = 2,
  [RES.ImmuneMagic]     = 3,
  [BONDED_AC]           = 4,
}
-- A Hell-tamed ally (capturedDifficulty == HELL_DIFFICULTY) has HELL_GILD_CHANCE% to wear the rare
-- Gilded Metal recolour instead of its bonus colour. bondedTrn[seed] = rolled variant, set once & saved.
HELL_DIFFICULTY  = 2
HELL_GILD_CHANCE = 15
bondedTrn = {}
-- scrollGamemode[seed] = 0 (Diablo) | 1 (Hellfire): the gamemode the scroll was first tamed in. Captured
-- once at fresh tame, preserved across recall/redeploy, carried on trade (packed in the modData blob) and
-- re-keyed on pickup. Persisted in OnSave/OnLoadPlayerData; rebuilt onto held scrolls by healHeldScrollModData.
scrollGamemode = {}
-- scrollAreaLevel[seed] = the dungeon level the scroll was first tamed in (items.currentDeltaLevel at fresh
-- tame: 1-24 in normal play; a setlevel quest area encodes as level+NUMLEVELS). Mapped to an area name for the
-- floating box "Found:" field. Same lifecycle as scrollGamemode: captured once at fresh tame, carried in the
-- modData blob, re-keyed on pickup, persisted in OnSave/OnLoadPlayerData, synced over CO.
scrollAreaLevel = {}
flashOn           = false

-- Spellcaster allies scale their *cast* damage off the Hunter's matching resistance.
-- Maps a missile's DamageType to the resistance key it scales from. Acid has no player-side
-- resistance of its own, so Acid casters are aligned to the Hunter's MAGIC resistance (treated as a
-- spellcaster element). Only Physical casts fall through (nil) and keep the physical melee buff.
SPELL_ELEMENT_OF = {
  [monsters.DamageType.Fire]      = "fire",
  [monsters.DamageType.Lightning] = "lightning",
  [monsters.DamageType.Magic]     = "magic",
  [monsters.DamageType.Acid]      = "magic",
}
-- The local Hunter's UNCAPPED resistances (may exceed the 75% display cap), refreshed from the
-- OnCalcPlayerResistances hook whenever the Hunter's inventory/resistances are recalculated.
hunterResist = { fire = 0, lightning = 0, magic = 0 }

-- Cache the local Hunter's uncapped resistances for spellcaster damage scaling. The hook
-- fires for every player on recalc; we only keep the local player's (its allies are client-local).
events.OnCalcPlayerResistances.add(function(p, fire, lightning, magic)
  local me = player.self()
  if me == nil or p == nil or p.id ~= me.id then return end
  hunterResist.fire      = fire
  hunterResist.lightning = lightning
  hunterResist.magic     = magic
end)

-- bondedImmunity[seed] = the granted IMMUNE_* flag, or BONDED_AC for the +200 AC fallback.
-- Rolled ONCE at the promotion moment, then stored & persisted so a redeploy restores
-- the same bonus instead of re-rolling. Same seed-keyed, save-MPQ-persisted pattern as allyKillCounts.
bondedImmunity = {}

-- ---- Portable scroll payload (item.modData blob) ------------------------------------------------
-- The seed-keyed progression tables (allyKillCounts / bondedImmunity / bondedTrn / scrollGamemode) and the
-- Original Trainer live in the owner's save and so do NOT travel when a scroll is dropped and picked up by
-- someone else. To make a scroll self-describing — so it survives a trade and a re-stamp losslessly — its
-- WHOLE identity is packed into the item's optional mod-data blob (item.modData, a binary string) on every
-- scroll creation. Layout (string.pack), empty for a non-scroll item:
--   I2 kill count (clamped 65535)   B Bonded immunity index (0 = none; see IMMUNITY_BY_INDEX)
--   B  Bonded TRN variant (0 = none) B tamed-in gamemode (0 = Diablo, 1 = Hellfire)
--   B  tamed-in area level (dungeon level at fresh tame; see scrollAreaLevel)
--   I4 Original-Trainer OHID          s1 Original-Trainer name (length-prefixed, <=255)
-- (Gamemode is mod-owned here — NOT dwBuff bit 0, which is the engine's live CF_HELLFIRE flag.) The blob is
-- opaque to the engine and travels two ways: live by seed over the LuaNet "SD" message (broadcastScrollData)
-- and at rest with a dropped floor item via the level delta (items.setItemDeltaModData), so a scroll picked
-- up after its original dropper has left the game still carries everything.
-- Compact mappings between the bondedImmunity flag value and its index.
IMMUNITY_BY_INDEX = { [1] = RES.ImmuneFire, [2] = RES.ImmuneMagic, [3] = RES.ImmuneLightning, [4] = BONDED_AC }
IMMUNITY_TO_INDEX = {}
for idx, val in pairs(IMMUNITY_BY_INDEX) do IMMUNITY_TO_INDEX[val] = idx end

SCROLL_BLOB_FMT = "I2 B B B B I4 s1"  -- kills, immIdx, trnVar, gamemode, areaLvl, ohId, ohName

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

-- Build the self-describing blob for a seed from its live/saved tables + recorded Original Trainer
-- (originForSeed falls back to the local Hunter for a freshly tamed scroll not yet stamped).
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

-- A Tamed ally becomes Bonded once its kill count reaches mlvl * BONDED_KILLS_PER_LEVEL
-- (mlvl = the monster's own level). Derived live from allyKillCounts[seed]; no encoded field needed.
function isBonded(seed, mlvl)
  if seed == nil or mlvl == nil or mlvl <= 0 then return false end
  return (allyKillCounts[seed] or 0) >= mlvl * BONDED_KILLS_PER_LEVEL
end

-- True when a deployed ally needs exactly one more kill to cross the Bonded threshold
-- (kills land one at a time, so this is the single-kill window that drives the pre-Bonded flash).
-- Minions never promote, so they never flash.
function isOneKillFromBonded(entry)
  if entry.isMinion then return false end
  local mlvl = entry.monster.level
  if mlvl <= 0 then return false end
  local needed = mlvl * BONDED_KILLS_PER_LEVEL
  local kills  = allyKillCounts[entry.seed] or 0
  return kills >= needed - 1 and kills < needed
end

-- Bonded check for a scroll ITEM (in inventory / on the floor), where the live monster isn't
-- available: mlvl comes from the dwBuff-encoded level, kills from allyKillCounts[seed].
function scrollIsBonded(item)
  local _, _, level = decodeDwBuff(item.buff)
  return isBonded(item.seed, level)
end

-- Gold/"unique"-tier scroll = a seed-unique champion/boss scroll OR any Bonded scroll
-- (Bonded scrolls render as Unique Tame Scrolls).
function scrollIsGoldTier(item)
  if seedGetUniqueType(item.seed) >= 0 then return true end
  return scrollIsBonded(item)
end

-- ---- Base-vs-applied stat machinery ------------------------------------
-- Each deployed ally's BASE (pre-buff) stats are snapshotted at deploy into entry.base. The live
-- buff is layered on top and recomputed in place whenever the deployed set or the Hunter's stats
-- change, so it can be re-derived without compounding and never leaks into the scroll on recall.
-- INVARIANT: the buff never bakes into the persisted scroll — entry.base (incl. base.maxHp) holds the
-- un-buffed stats and is the single source of truth saved on recall. The live HP buff DOES raise the
-- monster's live maxHitPoints (so its bar reads e.g. 120/120 and a share potion can top it off), but
-- maxHitPoints is recomputed every recalc as base.maxHp + the live share — never accumulated — and
-- dmg/ToHit/AC are likewise rewritten from base, not incremented. Recall persists base.maxHp.

function clampU8(v) return math.min(math.max(math.floor(v), 0), 255) end

-- Snapshot the freshly-spawned monster's stats as the buff baseline. dmg/ToHit/AC are re-rolled by
-- the engine on each spawn (not scroll-encoded), so the per-deploy live value IS the base. Call
-- AFTER makeGolem() so golemToHit (the source of Monster::toHit for player minions) is already set.
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

-- Shared per-ally share WEIGHT (percent): the CLVL% pool divided evenly across all
-- deployed Tamed/Bonded allies, then doubled for a Bonded ally. Returns 0 when there's no local
-- Hunter. Used by both the physical buff and the per-cast spellcaster buff.
function allySharePct(entry)
  local me = player.self()
  if me == nil or me.className ~= HUNTER_CLASS then return 0 end
  local count = countDeployedAllies()
  if count < 1 then count = 1 end           -- guard: self may not be tracked yet at first-deploy recalc
  local bonded = isBonded(entry.seed, entry.monster.level)
  return (me.characterLevel / count) * (bonded and 2 or 1)
end

-- Live, share-divided, CLVL-scaled physical buff pool (HP / min+max damage / ToHit / AC),
-- plus an additive kill-scaled ToHit bonus. Each stat's pool is CLVL% of the Hunter's own matching
-- stat (as shown on the character sheet — see the player.minDamage/maxDamage/toHit/armorClass
-- bindings), split evenly across all deployed Tamed/Bonded allies, with a Bonded ally's share
-- doubled. All fractions round up. Returns the deltas applyAllyBuff layers onto entry.base.
-- EVERY ally (caster or not) gets the physical damage buff here — it governs MELEE damage. A
-- spellcaster's elemental MISSILE damage is scaled separately, per cast, in OnGolemMissileDamage,
-- so a hybrid like the Balrog keeps a physical melee buff AND a resistance-scaled Inferno.
function computeAllyBuff(entry)
  local zero = { hp = 0, minDamage = 0, maxDamage = 0, toHit = 0, armorClass = 0 }
  if entry.isMinion then return zero end  -- minions get a static spawn-time buff, not this live pool
  local me = player.self()
  if me == nil or me.className ~= HUNTER_CLASS then return zero end
  local clvl   = me.characterLevel
  local bonded = isBonded(entry.seed, entry.monster.level)

  local sharePct = allySharePct(entry)
  local function share(stat) return math.ceil(stat * sharePct / 100) end

  -- Kill-scaled ToHit (additive, per-ally, NOT share-divided): +1% per KILL_TOHIT_PER kills,
  -- raw clamped to CLVL*10, doubled if Bonded (after the clamp), hard-capped at KILL_TOHIT_CAP%.
  local raw      = math.floor((allyKillCounts[entry.seed] or 0) / KILL_TOHIT_PER)
  raw            = math.min(raw, clvl * 10)
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
  if entry.isMinion then return end       -- minions get a static spawn-time buff, not the live pool
  if entry.base == nil then return end
  local m = entry.monster
  local base = entry.base
  local buff = computeAllyBuff(entry)
  -- The Bonded +200 AC fallback is folded through the buff machinery so a later recalc
  -- (which rewrites armorClass from base) does not wipe it.
  local acBonus = (bondedImmunity[entry.seed] == BONDED_AC) and BONDED_AC_BONUS or 0
  m:setMinDamage(clampU8(base.minDamage + buff.minDamage))
  m:setMaxDamage(clampU8(base.maxDamage + buff.maxDamage))
  m:setToHit(math.max(0, base.toHit + buff.toHit))
  m:setArmorClass(clampU8(base.armorClass + buff.armorClass + acBonus))
  -- HP buff RAISES maxHitPoints only (idempotently: base.maxHp + the live share, never accumulated).
  -- Current HP is left untouched — the buff adds headroom the pet can heal into (e.g. via share
  -- potions); it does not grant current. So a full base monster deploys at base.maxHp / buffed-max
  -- (e.g. 100/120). base.maxHp is the un-buffed snapshot persisted to the scroll. The only time we
  -- touch current is to clamp it down when a shrinking share drops max below current (avoids an
  -- overrun); otherwise current is purely combat/heal driven and round-trips exactly across recall.
  local newMax = base.maxHp + buff.hp
  m:setMaxHitPoints(newMax)
  if m.health > newMax then m:setHitPoints(newMax) end
end

-- Forward declaration: the CO (combat-override) broadcaster lives in the net section (it needs the net
-- message constants), but recalcAllyBuffs calls it so peers re-sync whenever any ally's stats change.
-- Assigned (without `local`) further down; nil until then (and a no-op in single-player anyway).
local broadcastAllCombatOverrides

-- Forward declaration: the live-remove broadcaster also lives in the net section, but the recall /
-- minion-cleanup helpers above it call it so peers despawn an ally/minion the moment its owner removes
-- it (instead of leaving a ghost until the next level reload). Assigned further down; nil until then.
local broadcastRemove

-- Forward declaration: credits one OWN deployed ally with a kill (Bonded progression). Shared by the melee
-- path (OnGolemKilledMonster) and the missile path (OnMonsterMissileHit handler below, which is defined
-- before the assignment). Assigned (without `local`) at the OnGolemKilledMonster registration further down.
local creditAllyKill

-- Recompute the buff for every deployed ally. Call whenever the deployed set changes (deploy,
-- recall, ally death) or the Hunter's own stats change. Because the share shifts as allies are
-- added/removed, already-deployed allies must update in place — not only at spawn. After re-applying,
-- the owner broadcasts each ally's new combat values to same-level peers (no-op in single-player).
function recalcAllyBuffs()
  for _, entry in ipairs(deployedAllies) do
    applyAllyBuff(entry)
  end
  if broadcastAllCombatOverrides ~= nil then broadcastAllCombatOverrides() end
end

-- The caster/combat profile a missile-resolution hook needs to scale an ally's spell damage and apply
-- its Bonded immunity-piercing. For OUR OWN ally we build it live (from the Hunter's stats + the ally's
-- Bonded state); a peer instead caches the OWNER's broadcast copy (the CO net message) on the remote
-- record, because none of these inputs (Hunter Magic/resistance, the ally's kill-derived Bonded status)
-- are otherwise visible on a peer. Same fields either way, so the missile hooks read it uniformly and
-- compute identical damage on every client. nil when there is no local Hunter / not enough data.
function ownAllyProfile(entry)
  local me = player.self()
  if me == nil or me.className ~= HUNTER_CLASS then return nil end
  local minion = entry.isMinion or false
  -- The pet's Original Trainer (the scroll's recorded origin, which may be a DIFFERENT Hunter if this
  -- owner received it via trade; minions have no seed so they fall back to this owner). Peers can't
  -- derive it, so it rides the CO message for the remote floating box.
  local origin = originForSeed(entry.seed) or { name = me.name, id = getMyOhId() }
  return {
    isMinion      = minion,
    bonded        = (not minion) and isBonded(entry.seed, entry.monster.level) or false,
    bondedImm     = bondedImmunity[entry.seed] or 0,
    baseMinDamage  = (entry.base and entry.base.minDamage) or 0,
    baseMaxDamage  = (entry.base and entry.base.maxDamage) or 0,
    baseToHit      = (entry.base and entry.base.toHit) or 0,
    baseArmorClass = (entry.base and entry.base.armorClass) or 0,
    baseMaxHp      = (entry.base and entry.base.maxHp) or 0,
    ohId           = origin.id or 0,
    ohName         = origin.name or "?",
    -- The pet's own lifetime kill count (drives the regular info box for every friendly observer).
    -- Minions have no seed → 0; the info box hides the line for minions anyway.
    kills          = allyKillCounts[entry.seed] or 0,
    -- The gamemode the pet was tamed in (0 = Diablo, 1 = Hellfire), for the floating box "Version:" field.
    gamemode       = scrollGamemode[entry.seed] or 0,
    -- The dungeon level the pet was tamed in, for the floating box "Found:" field.
    areaLevel      = scrollAreaLevel[entry.seed] or 0,
    sharePct      = allySharePct(entry),
    magicCurrent  = me.magicCurrent,
    resFire       = hunterResist.fire,
    resLight      = hunterResist.lightning,
    resMagic      = hunterResist.magic,
    -- Cosmetic Plane-2 state a peer can't derive locally (it has no seed-keyed kill/Bonded data): the
    -- Bonded recolour variant and the one-kill-from-Bonded "about to evolve" flash window. Carried so a
    -- remote ally shows the same TRN tint + pre-Bonded flash on every client.
    trnVariant    = bondedTrn[entry.seed] or 0,
    nearBonded    = isOneKillFromBonded(entry),
  }
end

-- The matching uncapped resistance for a spell element string (SPELL_ELEMENT_OF maps to these).
function profResForElement(prof, element)
  if element == "fire" then return prof.resFire end
  if element == "lightning" then return prof.resLight end
  return prof.resMagic  -- "magic" (also acid, reclassified to magic)
end

-- The caster/combat profile for ANY tamed ally on this client: built live for our own (deployedAllies),
-- or read from the cached CO broadcast for a remote-owned ally (remoteAllies). nil for a non-ally (e.g.
-- a vanilla Golem) or a remote ally whose CO has not arrived yet. The missile hooks use this so they
-- resolve identically on the owner and on peers.
function allyMissileProfile(monster)
  if monster == nil then return nil end
  local entry = getDeployedAllyEntry(monster.id)
  if entry ~= nil then return ownAllyProfile(entry) end
  local rec = remoteAllies[monster.id]
  if rec ~= nil then return rec.profile end
  return nil
end

-- Minions (a tamed Skeleton King's skeletons, a Hork Demon's spawn) get a flat CLVL% stat
-- buff baked ONCE at spawn — the Tame (non-Bonded) tier weight, independent of the live share-divided
-- ally pool. NOT divided by ally count and never recomputed afterward (minions are transient,
-- summoned/reaped as the parent fights). Damage is purely physical CLVL% — no spellcaster split, since
-- no minion type casts an elemental missile. Layered on top of entry.base (the difficulty-scaled,
-- post-makeGolem snapshot) using the same write pattern as applyAllyBuff; HP as a current-vs-max
-- overrun so maxHitPoints is never touched. Call once, after snapshotAllyBase.
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
    -- Same model as applyAllyBuff: the buff raises maxHitPoints only (base.maxHp + hpBuff), leaving
    -- current HP untouched. Baked once; minions are never recalc'd or recalled.
    m:setMaxHitPoints(base.maxHp + hpBuff)
  end
end

-- Scale a deployed spellcaster ally's ELEMENTAL missile damage off the Hunter's Magic and
-- matching resistance. The C++ hook is gated to MFLAG_GOLEM sources, so this only fires for golem /
-- player-minion missiles (never wild monsters); we still filter to our own deployed allies below
-- (the vanilla Golem is MFLAG_GOLEM too but isn't in deployedAllies). Fires per missile — including
-- each segment of a multi-tick spell (every Inferno / Lightning spawn) and re-sampling spells — so
-- the timing is robust where a one-shot min/max bump was not, and it picks the resistance matching
-- THIS missile's element, so multi-element casters are handled with no per-monster table. Physical
-- missiles pass through unchanged (Acid scales off the Hunter's Magic resistance); MELEE never routes
-- here, so a hybrid (e.g. Balrog) keeps its physical melee buff while its spell scales off this
-- Magic/resistance formula instead.
--
-- Formula:  spell = (baseDam + sharePct% × CurrentMagic) × (1 + matchingRes%)   [round up]
--   - baseDam: the rolled `dam` with the physical buff stripped back out (scale the engine's
--     roll by base/current rather than re-rolling, so the missile's native multiplier — e.g.
--     Lightning's x2 — is preserved).
--   - sharePct = (CLVL / deployedAllyCount) × (Bonded ? 2 : 1): the Magic term is a SHARED POOL —
--     split across deployed allies, doubled for Bonded (via allySharePct, same weight as the physical buff).
--   - matchingRes (uncapped, clamped to ≥0): a FULL multiplier, NOT share-divided, so matching-element
--     resistance stays meaningful even with a big pack. Synergy only ever helps (no negative penalty).
events.OnGolemMissileDamage.add(function(golem, missileId, dam)
  if golem == nil then return dam end
  -- Profile is live for our own ally, or the owner's broadcast copy for a remote ally — so the spell
  -- scaling is identical on every client (this hook fires wherever the missile is created, i.e. all
  -- clients). nil = not our ally (e.g. vanilla Golem) or CO not yet received.
  local prof = allyMissileProfile(golem)
  if prof == nil or prof.isMinion then return dam end    -- not our ally / minions: static buff only
  local element = SPELL_ELEMENT_OF[monsters.getMissileDamageType(missileId)]
  if element == nil then return dam end                  -- physical missile: keep the phys-buffed roll
  if prof.baseMaxDamage == 0 then return dam end
  -- Strip the physical buff (base/current fraction of the live max damage) so the spell
  -- scales off Magic + resistance, while keeping the missile's native multiplier intact.
  local cur = golem.maxDamage
  if cur > 0 then dam = math.floor(dam * prof.baseMaxDamage / cur) end
  if dam <= 0 then return 0 end
  local res        = math.max(0, profResForElement(prof, element))
  local magicBonus = prof.sharePct / 100 * prof.magicCurrent
  return math.ceil((dam + magicBonus) * (1 + res / 100))
end)

-- ---- Acid-as-magic + Bonded immunity piercing --------------------------
-- Two behaviours, both expressed in the OnMonsterMissileHit handler (which fires whenever one of our
-- allies is on either end of a missile) and both set/restored inline within that one synchronous call, so
-- nothing (healthbar/infobox) ever observes a transient change. The vanilla Golem is never in
-- deployedAllies, so it falls through unchanged (Golem barometer respected).
--
-- (A) ACID RESOLVED BY MAGIC RESISTANCE (any ally, attacker OR defender). The engine has NO monster
--     acid-resist tier (Monster::isResistant ignores RESIST_MAGIC for an Acid missile) — monster-side
--     acid is all-or-nothing (full, or 0 if IMMUNE_ACID). To mirror the player side (acid resolves
--     through magic resistance), when one of our allies is the source or the target of an acid missile we
--     return DamageType.Magic, so the engine resolves the hit through the target's magic immunity/
--     resistance instead. IMPORTANT: acid IMMUNITY is RESPECTED here — if the target is acid-immune we
--     leave the element as Acid (engine blocks it). So a wild monster's acid on an acid-immune Tamed or
--     Bonded ally is still blocked; a non-immune ally resolves it via magic resistance.
--
-- (B) BONDED ATTACK PIERCES IMMUNITY (Bonded SOURCE only). A Bonded ally's missiles treat the target's
--     IMMUNITY to the cast element as mere "big resistance" (75%) -> 25% instead of 0. Coarse on/off: ANY
--     Bonded ally pierces, regardless of spell/element. Two cases:
--       - Fire / Lightning / Magic (engine has a real resist tier): TEMPORARILY clear the matching
--         IMMUNE_* bit and set the matching RESIST_* bit -> engine's dam/4 = 25% with "resisted" feedback.
--       - Acid (no resist tier): TURN OFF the target's IMMUNE_ACID and resolve as MAGIC, so the acid
--         missile does magic damage even to an acid-immune target (this is the bypass that (A) withholds).
--         It then also flows through the Magic case above, so a magic-immune target is pierced to 25% too.
--
-- (B) is the OFFENSIVE counterpart to -- and separate from -- the immunity a Bonded ally GAINS on
-- promotion: one is "what my attacks pierce", the other is "what I'm immune to".
--
-- EXCEPTION (PvP): the random immunity a Bonded ally was GRANTED on promotion
-- (bondedImmunity[seed]) is NOT pierceable. When the target is one of our locally-tracked allies and the
-- (effective) cast element matches its granted Bonded immunity, we skip the downgrade so that immunity
-- holds at full — e.g. a rolled Magic immunity blocks our acid (resolved as magic). (A cross-Hunter
-- remote target isn't in our deployedAllies, so its granted immunity can't be read on this client yet —
-- a known MP limitation deferred to Net Sync, like the rest of the mod's cross-client checks. Piercing
-- of a target's *natural* immunities works regardless, incl. wild monsters in single-player, which is
-- the common case; the rolled-immunity guard only matters in PvP.)

-- DamageType -> { IMMUNE_* flag we clear, RESIST_* (big-resistance, 75%) flag we set } for the elements
-- the engine has a real resist tier for. Acid is NOT keyed here — it has no monster resist tier and is
-- reclassified to Magic first (then it shares the Magic entry). Physical is absent (nothing to pierce).
PIERCE_OF = {
  [monsters.DamageType.Fire]      = { immune = RES.ImmuneFire,      resist = RES.ResistFire },
  [monsters.DamageType.Lightning] = { immune = RES.ImmuneLightning, resist = RES.ResistLightning },
  [monsters.DamageType.Magic]     = { immune = RES.ImmuneMagic,     resist = RES.ResistMagic },
}

-- OnMonsterMissileHit: the single resolution call-out for any missile where a player-minion (MFLAG_GOLEM)
-- is on either end. We act only when one end is one of OUR allies (own = live, remote = cached CO profile);
-- a vanilla Golem (never in deployedAllies) returns -1 and falls through to the engine default (Golem
-- barometer respected). Otherwise we resolve the hit ourselves and return 1/0 (hit/miss). Everything the old
-- pre/post bracket did is inline here in one synchronous call: reclassify the element (acid-as-magic),
-- transiently pierce a Bonded attacker's target immunity, tag the owner for kill XP, resolve through the
-- engine (target:resolveMissileHit), restore the transient resistance, and credit the kill.
events.OnMonsterMissileHit.add(function(source, target, missileId, damageType, minDam, maxDam, dist, shifted)
  if target == nil then return -1 end
  -- Resolve each end as a tamed-ally profile (own = live, remote = cached CO) so the acid-reclass and
  -- Bonded piercing compute identically on every client (this handler fires wherever the missile resolves).
  local srcProf = source ~= nil and allyMissileProfile(source) or nil   -- our/another's ally as attacker?
  local tgtProf = allyMissileProfile(target)                            -- a tamed ally as victim?
  if srcProf == nil and tgtProf == nil then return -1 end               -- vanilla Golem / non-allies → engine default
  local bondedAttacker = srcProf ~= nil and not srcProf.isMinion and srcProf.bonded

  local res    = target.resistance
  local newRes = res
  local effectiveType = damageType

  -- (A)/(B-acid) Acid handling. Acid has no monster resist tier, so to apply magic resistance we resolve
  -- it as Magic. A Bonded attacker BYPASSES acid immunity (turn off IMMUNE_ACID, then resolve as Magic);
  -- otherwise acid immunity is RESPECTED (leave the element as Acid -> engine blocks an acid-immune
  -- target), and only a non-immune target is resolved through magic resistance.
  if damageType == monsters.DamageType.Acid then
    if bondedAttacker then
      if (newRes & RES.ImmuneAcid) ~= 0 then newRes = newRes - RES.ImmuneAcid end
      effectiveType = monsters.DamageType.Magic
    elseif (res & RES.ImmuneAcid) == 0 then
      effectiveType = monsters.DamageType.Magic
    end
  end

  -- (B) Bonded SOURCE pierces the target's IMMUNITY to the effective element by downgrading it to the
  -- matching big-resistance (engine's dam/4 -> 25%), UNLESS it is a rolled-Bonded immunity (left intact ->
  -- engine blocks). RESIST_* / no-resistance are left to the engine (25% / full). Non-Bonded allies and
  -- minions never pierce. Acid is Magic by here, so a Bonded acid caster pierces magic immunity too.
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

  -- XP credit: an OUR-ally attacker tags its owner BEFORE resolution, so a fatal shot still counts (the
  -- engine distributes death XP inline during the resolve). Mirrors the melee minion tag the engine already
  -- does in MonsterAttackMonster; owner = goalVar3 (ownerPlayerId).
  if srcProf ~= nil then target:tagForPlayer(source.ownerPlayerId) end

  -- Resolve through the engine (rolls to-hit, applies the effective element's resistance/immunity, deals
  -- damage, runs the inline death/hit reactions). Magic for reclassified acid; unchanged otherwise.
  local hit = target:resolveMissileHit(missileId, effectiveType, minDam, maxDam, dist, shifted)

  if newRes ~= res then target:setResistance(res) end  -- restore the transient pierce/reclass

  -- Bonded kill-count for an OWN ally that landed the fatal blow (remote allies are owner-tracked +
  -- CO-synced; creditAllyKill no-ops for them). Mirrors the melee path's OnGolemKilledMonster.
  if hit and srcProf ~= nil and target.hasNoLife then creditAllyKill(source, target) end

  return hit and 1 or 0
end)

-- ---- Bonded defensive bonus --------------------------------------------
-- On promotion the ally gains ONE random immunity it does not already have (Fire/Magic/Lightning);
-- if it already has all three, it gets +200 AC instead. Rolled once, stored by seed, persisted.

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

-- Pick & store this ally's Bonded recolour TRN from its rolled bonus (call after rollBondedBonus, which
-- sets bondedImmunity[seed]). A Hell-tamed ally has a small chance to override its bonus colour with the
-- rare Gilded Metal look instead. No-op once the seed has a stored variant (so redeploys are stable).
function rollBondedTrn(entry)
  if bondedTrn[entry.seed] ~= nil then return end
  local variant = BONDED_TRN_BY_IMMUNITY[bondedImmunity[entry.seed]] or BONDED_TRN_GILDED
  if entry.capturedDifficulty == HELL_DIFFICULTY and math.random(100) <= HELL_GILD_CHANCE then
    variant = BONDED_TRN_GILDED
  end
  bondedTrn[entry.seed] = variant
end

-- Apply the stored bonus to the live monster. Immunity is written straight to resistance (it
-- survives recalc, which never touches resistance); the +200 AC fallback is realised inside
-- applyAllyBuff (folded into the AC write) so call applyAllyBuff after this. If the granted immunity
-- supersedes a same-element resistance the monster already had, the resistance is dropped so the
-- infobox/healthbar never show a Resist and Immune of the same element (vanilla never does).
function applyBondedBonus(entry)
  local bonus = bondedImmunity[entry.seed]
  if bonus == nil or bonus == BONDED_AC then return end
  local m = entry.monster
  local res = m.resistance | bonus
  local superseded = BONDED_IMMUNE_SUPERSEDES[bonus]
  if superseded ~= nil and (res & superseded) ~= 0 then res = res - superseded end
  m:setResistance(res)
end

-- The discrete promotion moment: roll/store the bonus, apply it, and re-derive stats so the
-- +200 AC fallback (if rolled) takes effect immediately, and fire a celebratory Flash burst at
-- the ally's own tile to mark the evolution. The pre-Bonded flash stops on its own — once the
-- threshold is crossed, isOneKillFromBonded() returns false, so OnGetMonsterTRN no longer flashes it.
function promoteToBonded(entry)
  rollBondedBonus(entry)
  rollBondedTrn(entry)          -- pick the recolour matching the rolled bonus (or rare Hell Gilded)
  applyBondedBonus(entry)
  applyAllyBuff(entry)
  applyBondedGlow(entry)        -- permanent Bonded aura light
  entry.monster:castFlashSelf()
end

-- -------------------------------------------------------------------------
-- Tame tier + monster-category model (single source of truth for the gate).
-- The active TIER is derived from character level (clvl); the monster CATEGORY
-- from its uniqueness/quest flags. A capture/deploy is allowed only when BOTH
-- the tier's mlvl gate (mlvlGateAllows) AND the category's HP threshold pass.
-- Tier unlocks:  Tame (always) / Tame+ (clvl 20) / Tame++ (clvl 35) / Tame+++ (clvl 45).
-- -------------------------------------------------------------------------

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

-- Classify a LIVE monster (capture side). The engine binding sets
-- isQuestMonster = isUnique || MT_DIABLO, so Diablo is the one quest monster
-- that is not unique (isQuestMonster=true, isUnique=false).
function categoryFromTarget(target)
  if target.isQuestMonster and not target.isUnique then return CAT_DIABLO end
  if target.isUnique then
    return BOSS_NAMES[target.name] and CAT_BOSS or CAT_CHAMPION
  end
  return CAT_NORMAL
end

-- Capture-HP threshold (percent of max HP), keyed by category, fixed at every tier.
function categoryHpThreshold(category)
  if category == CAT_DIABLO then return 5  end
  if category == CAT_BOSS   then return 10 end
  if category == CAT_CHAMPION then return 20 end
  return 30 -- normal
end

-- mlvl/category gate for the active tier. Returns true if this monster category at
-- this monster level (mlvl) may be tamed by a Hunter of this character level (clvl).
--   Tame    : Normal mlvl<=clvl ; Champion & Boss clvl>=mlvl*2 ; Diablo never
--   Tame+   : Normal & Champion mlvl<=clvl ; Boss clvl>=mlvl*2 ; Diablo never
--   Tame++  : Normal/Champion/Boss mlvl<=clvl+10 ; Diablo never
--   Tame+++ : any category (incl. Diablo) at any mlvl
function mlvlGateAllows(tier, category, clvl, mlvl)
  if category == CAT_DIABLO then
    return tier >= 3 -- only Tame+++, mlvl-blind
  end
  if tier >= 3 then return true end                 -- Tame+++: any non-Diablo, any mlvl
  if tier == 2 then return mlvl <= clvl + 10 end     -- Tame++: all non-Diablo categories
  -- Tame (0) and Tame+ (1):
  if category == CAT_NORMAL then return mlvl <= clvl + 1 end
  if category == CAT_CHAMPION then
    if tier >= 1 then return mlvl <= clvl end         -- Tame+: champion eased to mlvl<=clvl
    return clvl >= mlvl * 2                           -- Tame: champion clvl>=mlvl*2
  end
  return clvl >= mlvl * 2                             -- Boss (Tame & Tame+): clvl>=mlvl*2
end

-- Classify a TAME SCROLL by its seed (deploy side). Mirrors categoryFromTarget but reads
-- the encoded seed/name instead of a live monster.
function categoryFromScroll(seed)
  local uIdx = seedGetUniqueType(seed)
  if uIdx < 0 then
    -- Normal scroll. No Diablo scrolls can exist yet (Diablo capture is hard-blocked), so every
    -- normal scroll classifies as CAT_NORMAL; revisit Diablo-scroll detection in the Diablo sub-task.
    return CAT_NORMAL
  end
  local name = monsters.getUniqueName(uIdx)
  if name ~= nil and BOSS_NAMES[name] then return CAT_BOSS end
  return CAT_CHAMPION
end

-- True if a Tame scroll (by seed + dwBuff) is deployable at player p's current tier.
-- Used to red/hide/refuse out-of-criteria scrolls, mirroring the capture-side mlvl gate.
function scrollPassesTierGate(p, seed, buff)
  local clvl       = p.characterLevel
  local _, _, mlvl = decodeDwBuff(buff)
  local category   = categoryFromScroll(seed)
  if category == CAT_DIABLO then return false end  -- Diablo deploy deferred to its own sub-task
  return mlvlGateAllows(tameTier(clvl), category, clvl, mlvl)
end

LEASH_DISTANCE  = 12  -- emergency snap distance
ENGAGE_RADIUS   = 9   -- max chase/target radius from player
MAX_ALLIES      = 8   -- hard cap on simultaneously deployed non-minion allies

-- True when p is the local player AND the local player is a Hunter.
-- Used in all query/fire event hooks so they are inert when the local player is a different class
-- (important in mixed-class multiplayer games where the mod is installed on all clients).
function isMyPlayer(p)
  local self = player.self()
  return self ~= nil and p.id == self.id and self.className == HUNTER_CLASS
end

-- -------------------------------------------------------------------------
-- Data registration
-- -------------------------------------------------------------------------

-- Queue our spells. IDs are NOT assigned here — the engine assigns them after every mod has
-- registered, deterministically (sorted by name from a fixed base just past the static SpellID range).
-- That makes a given name resolve to the SAME id in Diablo and Hellfire and regardless of mod load
-- order, so saved skill/scroll bits stay valid across .sv<->.hsv and every same-mod-set client agrees.
-- Names are namespaced ("hunter:") so other spell-adding mods can never collide with ours.
events.SpellDataLoaded.add(function()
  spells.registerSpell("hunter:tame",         "txtdata\\spells\\tame.tsv",         "Golem")
  spells.registerSpell("hunter:sharepotion",  "txtdata\\spells\\sharepotion.tsv",  "HealOther")
  spells.registerSpell("hunter:forgetpotion", "txtdata\\spells\\forgetpotion.tsv", "Null")
end)

-- SpellsAssigned fires right after assignment, before ItemDataLoaded / PlayerDataLoaded, so these
-- ids are valid when the Tame Scroll item (TAME_ID) and the starting-loadout skill ("hunter:tame")
-- are resolved.
events.SpellsAssigned.add(function()
  TAME_ID          = spells.getSpellId("hunter:tame")
  SHARE_POTION_ID  = spells.getSpellId("hunter:sharepotion")
  FORGET_POTION_ID = spells.getSpellId("hunter:forgetpotion")
end)

events.PlayerDataLoaded.add(function()
  player.addClassDataFromTsv("txtdata\\classes\\classdat_hunter.tsv")
end)

-- Re-grant Share Potion on every level entry. InitPlayer (player.cpp) unconditionally
-- resets _pAblSpells to only the class's starting skill on each level load, wiping any
-- extra skills. OnLevelEnter fires after InitPlayer completes so this re-OR is safe.
events.OnLevelEnter.add(function()
  local p = player.self()
  if p == nil then return end
  if p.className ~= HUNTER_CLASS then return end
  p:addSkill(SHARE_POTION_ID)
end)

-- Grant a starting Tame Scroll when a new Hunter character is created.
-- OnCreatePlrItems fires from inside CreatePlrItems (items.cpp) after the standard
-- loadout is placed but before CalcPlrItemVals — the same safe context used by all
-- other starting item placement.
events.OnCreatePlrItems.add(function(p)
  if p == nil then return end
  if p.className ~= HUNTER_CLASS then return end
  myOhId = generateOhId(p.name)  -- permanent per-character OHID, stamped once at creation
  local monsterData = {
    typeId             = STARTER_TYPE_ID,
    savedHp            = STARTER_MAX_HP,
    maxHp              = STARTER_MAX_HP,
    name               = STARTER_NAME,
    level              = STARTER_LEVEL,
    capturedDifficulty = monsters.currentDifficulty(),
  }
  -- The creating Hunter is the starter pet's Original Trainer. Route through the shared scroll-creation
  -- helper a freshly-tamed monster uses, so the starter inherits every current field (modData, seed-keyed
  -- origin, peer announce) and stays identical to any other tamed scroll instead of drifting behind.
  addTameScrollToInventory(p, monsterData, { name = p.name, id = myOhId })
end)

-- -------------------------------------------------------------------------
-- Stat-scaled animation frame tiers
-- Hunter uses Warrior sprites. Negative skip = slower than Warrior baseline.
--
-- Attack (melee, STR-gated):
--   Base penalty -4 (Sorcerer-slow for unarmed/axes), tiers climb toward 0.
--   STR  <75 : -4  (sorcerer-slow)
--   STR  75+ : -3
--   STR 125+ : -2
--   STR 175+ : -1
--   STR 200+ or (STR 150+ and VIT 200+): 0 (Warrior optimal)
--
-- RangedAttack (bow, DEX-gated):
--   Warrior bow = 16 frames, Rogue bow = 12 frames (+4 skip = Rogue speed).
--   DEX  <75 :  0  (Warrior baseline)
--   DEX  75+ : +1
--   DEX 125+ : +2
--   DEX 175+ : +3
--   DEX 250+  : +4 (Rogue optimal)
--
-- Cast (MAG-gated):
--   Warrior cast = 20 frames, Sorcerer cast = 12 frames (+8 skip = Sorcerer speed).
--   MAG  <40 :  0  (Warrior baseline)
--   MAG  40+ : +2
--   MAG  80+ : +4
--   MAG 120+ : +6
--   MAG 150+  : +8 (Sorcerer-lite optimal)
-- -------------------------------------------------------------------------

WEAPON_GRAPHIC_BOW = 4  -- PlayerWeaponGraphic::Bow

function getMeleeSkipBonus(str, vit)
  if str >= 200 then return 0
  elseif str >= 150 and vit >= 200 then return 0  -- Barbarian archetype gate
  elseif str >= 175 then return -1
  elseif str >= 125 then return -2
  elseif str >= 75  then return -3
  else return -4
  end
end

function getRangedSkipBonus(dex)
  if dex >= 250 then return 4   -- Rogue archetype: optimal
  elseif dex >= 175 then return 3
  elseif dex >= 125 then return 2
  elseif dex >= 75  then return 1
  else return 0
  end
end

function getCastSkipBonus(mag)
  if mag >= 150 then return 8   -- Sorcerer-lite archetype: optimal
  elseif mag >= 120 then return 6
  elseif mag >= 80  then return 4
  elseif mag >= 40  then return 2
  else return 0
  end
end

events.OnGetAnimationSkipFrames.add(function(p, animType, currentSkip)
  if not isMyPlayer(p) then return nil end
  if animType == "Attack" then
    return currentSkip + getMeleeSkipBonus(p.strength, p.vitality)
  elseif animType == "RangedAttack" then
    return currentSkip + getRangedSkipBonus(p.dexterity)
  elseif animType == "Cast" then
    return currentSkip + getCastSkipBonus(p.magic)
  end
  -- Block/HitRecovery: item bonuses flow through unchanged
end)

-- Bow-equipped dungeon stand sprite only has 8 frames; match the same override the engine
-- applies to native Warrior/Barbarian but not to dynamically-loaded classes.
-- MUST apply to EVERY Hunter (not just the local one): this is a rendering property, and every
-- client renders every player. Gating it to isMyPlayer left a remote Hunter's idle frame count at
-- the higher animations.tsv value, overrunning its 8-frame bow idle sprite → clx_sprite crash.
events.OnGetPlayerIdleFrames.add(function(p, weaponGraphic, isInTown)
  if p.className ~= HUNTER_CLASS then return nil end
  if weaponGraphic == WEAPON_GRAPHIC_BOW and not isInTown then
    return 8
  end
end)

-- Hunter always displays using the Light Armor sprite set regardless of equipped armor.
-- AC bonuses from worn armor still apply; this is purely cosmetic. Applies to EVERY Hunter
-- (rendering property): a remote Hunter must resolve to the same armor sprite on every client, or
-- a non-light-armored remote Hunter would load a wrong/missing sprite set.
events.OnGetPlayerArmorGraphic.add(function(p, currentGraphic)
  if p.className ~= HUNTER_CLASS then return nil end
  return "Light"
end)

-- -------------------------------------------------------------------------
-- Elixir restriction: Hunter cannot use stat-raising elixirs.
-- Stat budget is accumulated via level-ups + shrine bonuses only.
-- Shows items red; blocks equip/consume without preventing pickup.
-- -------------------------------------------------------------------------

-- ItemMiscID enum values are available as soon as the items module is required.
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
  -- A Tame scroll whose encoded monster is outside the Hunter's current tier criteria is
  -- red/unusable (blocks right-click + belt use). The data is preserved — only deployment is
  -- gated; the scroll becomes usable again once the tier/clvl meets the gate.
  if item:isScrollOf(TAME_ID) and not scrollPassesTierGate(p, item.seed, item.buff) then
    return false
  end
end)

-- -------------------------------------------------------------------------
-- Speedbook spell filter: hide learned spells not on the Hunter allowlist.
-- Scrolls and staff charges always show. Golem scrolls are also hidden
-- (Golem may only be cast from memory or a staff charge, never a scroll).
-- -------------------------------------------------------------------------

-- SpellID integer values from the engine enum (SpellID in spelldat.h).
HUNTER_ALLOWED_LEARNED_SPELLS = {
  [2]  = true, -- Healing
  [7]  = true, -- TownPortal
  [8]  = true, -- StoneCurse
  [10] = true, -- Phasing
  [11] = true, -- ManaShield
  -- Guardian (13) and Golem (21) intentionally excluded: the Hunter's summon
  -- identity is Tame, not the vanilla summon spells, so neither may be
  -- learned/direct-cast. Guardian stays usable via scroll/staff charge; Golem
  -- scrolls are red/hidden (OnCanPlayerUseItem + speedbook hide below) while
  -- Golem staff charges remain usable.
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

-- Spellbook: block selecting a restricted learned spell as the active cast spell.
-- Display is unchanged; only clicking to equip the spell is blocked.
events.OnCanSelectSpellBookEntry.add(function(p, spellId)
  if not isMyPlayer(p) then return nil end
  if HUNTER_ALLOWED_LEARNED_SPELLS[spellId] then return nil end
  return false
end)

-- -------------------------------------------------------------------------
-- Golden stats mechanic: when total base stats reach 460, every stat
-- appears "at its cap" simultaneously, blocking further allocation.
-- Implemented by returning the current stat value as the effective maximum —
-- the engine treats the stat as capped and displays it in golden text.
-- -------------------------------------------------------------------------

STAT_BUDGET = 460

events.OnGetMaxAttributeValue.add(function(p, attributeName)
  if not isMyPlayer(p) then return nil end
  local total = p.strength + p.magic + p.dexterity + p.vitality
  if total < STAT_BUDGET then return nil end
  -- Total budget exhausted: freeze each stat at its current value.
  if attributeName == "Strength"   then return p.strength   end
  if attributeName == "Magic"      then return p.magic      end
  if attributeName == "Dexterity"  then return p.dexterity  end
  if attributeName == "Vitality"   then return p.vitality   end
end)

-- -------------------------------------------------------------------------
-- Adaptive Archetype System
-- Hunter's combat mechanics scale with base stat investment.
-- Each archetype requires its FULL threshold to unlock — no partial benefits.
-- Thresholds use base stats only (_pBaseStr/Mag/Dex/Vit), not equipment bonuses.
--
-- Archetype gates:
--   Barbarian : STR>=150, VIT>=200, MAG<=15
--   Warrior   : STR>=200, DEX>=150
--   Rogue     : STR>=100, DEX>=250
--   Monk      : STR>=100, MAG>=50, DEX>=200
--   Sorc-lite : MAG>=150
-- -------------------------------------------------------------------------

function hasBarbArchetype(p)
  return p.strength >= 150 and p.vitality >= 200 and p.magic <= 15
end
function hasWarriorArchetype(p)
  return p.strength >= 200 and p.dexterity >= 150
end
function hasRogueArchetype(p)
  return p.strength >= 100 and p.dexterity >= 250
end
function hasMonkArchetype(p)
  return p.strength >= 100 and p.magic >= 50 and p.dexterity >= 200
end
function hasSorcLiteArchetype(p)
  return p.magic >= 150
end

-- _pDamageMod: compute best archetype formula using total stats (passed as pre-computed).
-- Returns the highest value among all met archetypes, nil if none met.
events.OnGetPlayerDamageMod.add(function(p, strMod, strDexMod, totalVit, isBow, isShield, isStaff, isUnarmed)
  if not isMyPlayer(p) then return nil end
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
  if not isMyPlayer(p) then return nil end
  return hasWarriorArchetype(p) or nil
end)

-- Iron skin AC bonus (Barbarian archetype).
events.OnPlayerHasIronSkin.add(function(p)
  if not isMyPlayer(p) then return nil end
  return hasBarbArchetype(p) or nil
end)

-- Natural resistances (Barbarian archetype).
events.OnPlayerHasNaturalResistance.add(function(p)
  if not isMyPlayer(p) then return nil end
  return hasBarbArchetype(p) or nil
end)

-- Full bow damage modifier (Rogue archetype).
events.OnGetBowDamageMod.add(function(p, fullMod)
  if not isMyPlayer(p) then return nil end
  if not hasRogueArchetype(p) then return nil end
  return fullMod
end)

-- Arrow velocity bonus (Rogue archetype).
events.OnGetArrowVelocityBonus.add(function(p)
  if not isMyPlayer(p) then return nil end
  if not hasRogueArchetype(p) then return nil end
  return (p.characterLevel - 1) // 4
end)

-- Block without shield (Monk archetype).
events.OnPlayerCanBlockWithoutShield.add(function(p, isStaff, isUnarmed)
  if not isMyPlayer(p) then return nil end
  return hasMonkArchetype(p) or nil
end)

-- Armor level-scaling AC bonus (Monk archetype).
events.OnGetArmorLevelBonus.add(function(p, armorType, isUnique)
  if not isMyPlayer(p) then return nil end
  if not hasMonkArchetype(p) then return nil end
  local level = p.characterLevel
  if armorType == "Heavy" then
    return isUnique and (level // 2) or 0
  elseif armorType == "Medium" then
    return isUnique and (level * 2) or (level // 2)
  else  -- Light
    return level * 2
  end
end)

-- Hit recovery stagger threshold (Barbarian archetype).
-- C++ pre-applies level+level/4 only for HeroClass::Barbarian; Hunter is dynamic so we add it here.
events.OnGetHitRecoveryThreshold.add(function(p, baseThreshold)
  if not isMyPlayer(p) then return nil end
  if not hasBarbArchetype(p) then return nil end
  local level = p.characterLevel
  return level + level // 4
end)

-- Unarmed damage floor (Monk archetype): min = max(current, level/2); max = max(current, level).
-- Fires when both hand slots are empty (no weapon; CalcPlrDamage entered with minDamage==0).
events.OnGetUnarmedDamageFloor.add(function(p, minDamage, maxDamage)
  if not isMyPlayer(p) then return nil end
  if not hasMonkArchetype(p) then return nil end
  local level = p.characterLevel
  return { math.max(minDamage, level // 2), math.max(maxDamage, level) }
end)

-- Block chance bonus: override TSV blockBonus based on active archetype.
-- Warrior/Barb=30, Monk=25, Rogue=20; nil falls back to TSV value of 10.
events.OnGetBlockChanceBonus.add(function(p, baseBonusFromTsv)
  if not isMyPlayer(p) then return nil end
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

-- Wirt item filter: when Hunter has a full archetype, bias Wirt's item toward usable types.
-- Types excluded only when ALL active archetypes agree to exclude them (intersection).
-- No archetype = no filter (any item type allowed).
WIRT_EXCLUSIONS = {
  Barbarian = { Bow=true, Staff=true },
  Warrior   = { Bow=true, Staff=true },
  Rogue     = { Sword=true, Staff=true, Axe=true, Mace=true, Shield=true },
  Monk      = { Bow=true, MediumArmor=true, Shield=true, Mace=true },
}

events.OnShouldExcludeWirtItem.add(function(p, itemTypeName)
  if not isMyPlayer(p) then return nil end
  local active = {}
  if hasBarbArchetype(p)    then table.insert(active, WIRT_EXCLUSIONS.Barbarian) end
  if hasWarriorArchetype(p) then table.insert(active, WIRT_EXCLUSIONS.Warrior)   end
  if hasRogueArchetype(p)   then table.insert(active, WIRT_EXCLUSIONS.Rogue)     end
  if hasMonkArchetype(p)    then table.insert(active, WIRT_EXCLUSIONS.Monk)      end
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
  if not isMyPlayer(p) then return nil end
  return hasBarbArchetype(p) or nil
end)

-- Cleave: Barb archetype grants cleave with axe or 2H mace/sword; Monk archetype with staff.
events.OnPlayerCanCleave.add(function(p, isAxe, isTwoHandedHeavy, isStaff)
  if not isMyPlayer(p) then return nil end
  if hasBarbArchetype(p) and (isAxe or isTwoHandedHeavy) then return true end
  if hasMonkArchetype(p) and isStaff then return true end
end)

-- Oily Shrine: +2 to the highest base stat that is not at its individual cap (250).
events.OnOilyShrine.add(function(p)
  if not isMyPlayer(p) then return end
  local stats = {
    { name = "Strength",  value = p.strength  },
    { name = "Dexterity", value = p.dexterity },
    { name = "Magic",     value = p.magic     },
    { name = "Vitality",  value = p.vitality  },
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
      cursorGraphic = 1,   -- ICURS_SCROLL_OF
      skipSpeedbook = true,
      value         = 0,
    }
  }, TAME_SCROLL_MAP)

  -- Potion of Forgetting: IMISC_FULLREJUV so it behaves exactly like a full rejuv
  -- potion — right-click from inventory and belt hotkey both work, engine restores
  -- full HP and mana. The 'spell' field stores FORGET_POTION_ID purely for detection
  -- in OnItemUsed (the engine ignores it for FullRejuv items). Value = 0 here;
  -- store price is set explicitly in addToHealerStock.
  items.addItemData({
    {
      name          = "Potion of Forgetting",
      class         = items.ItemClass.Misc,
      type          = items.ItemType.Misc,
      miscId        = items.ItemMiscID.FullRejuv,
      spell         = FORGET_POTION_ID,
      usable        = true,
      dropRate      = 0,
      cursorGraphic = 16,  -- ICURS_ARENA_POTION
      value         = 0,
    }
  }, FORGET_POTION_MAP)
end)

-- -------------------------------------------------------------------------
-- Helpers
-- -------------------------------------------------------------------------

function removeDeployedById(monsterId)
  for i = #deployedAllies, 1, -1 do
    if deployedAllies[i].id == monsterId then
      untrackDeployedAt(i)
      return
    end
  end
end

-- Minions are monsters spawned by a tamed ally's special ability (e.g. a tamed Skeleton King's
-- skeletons). They are tracked in deployedAllies with isMinion = true and parentId = the spawner's
-- monster id. They never count against the ally cap, are never recalled to a scroll, and are
-- despawned when their parent is recalled or killed.
function countMinionsOfParent(parentId)
  local n = 0
  for _, entry in ipairs(deployedAllies) do
    if entry.isMinion and entry.parentId == parentId then n = n + 1 end
  end
  -- Also count remote-owned minions of this parent: the spawn-cap decision runs on every client
  -- (deterministic AI), so a peer must see the same minion count the owner does — its copies live in
  -- remoteAllies, not deployedAllies.
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
      entry.monster:remove()  -- silently vanish: no death effects, loot, or XP
      broadcastRemove(mid)    -- peers despawn their mirrored copy (a minion has no natural-death sync there)
      untrackDeployedAt(i)
    end
  end
end

-- Build scroll name + dwBuff for a monster data record.
-- Pass existingSeed when recalling a deployed ally so the seed is preserved and
-- allyKillCounts[seed] persists across recall/redeploy cycles.
-- Unique scrolls: "Tamed [Name]" (no level prefix; difficulty stored in dwBuff).
-- Normal scrolls: "Tamed Lvl N [Name]" (level + difficulty in dwBuff).
-- `origin` (optional) stamps a NEW scroll's Original Trainer ({name, id}); omit it when recreating an
-- existing scroll (recall/refund/recovery) so the seed's already-recorded origin is preserved. The origin
-- is tracked in the seed-keyed scrollOrigin table (persisted + net-synced); it is NOT stored on the item.
function buildScrollParams(monsterData, existingSeed, origin)
  local uIdx = monsterData.uniqueTypeIdx
  local dif  = monsterData.capturedDifficulty or 0
  local seed = existingSeed or allocSeed(monsterData.typeId, uIdx)
  -- Record/keep the scroll's origin: explicit on a fresh tame, otherwise whatever this seed already had.
  origin = origin or scrollOrigin[seed]
  if origin ~= nil then scrollOrigin[seed] = origin end
  -- Capture the tamed-in gamemode + area level ONCE, on the fresh tame (a new seed with nothing recorded
  -- yet). Recall/refund (existingSeed) keeps the values already stored, like the origin above.
  if existingSeed == nil and scrollGamemode[seed] == nil then
    scrollGamemode[seed] = system.isHellfire() and 1 or 0
    -- Dungeon level the player tamed it on. items.currentDeltaLevel() dereferences the local player, which
    -- does NOT exist yet during character creation (the starter scroll is built from OnCreatePlrItems before
    -- MyPlayer is set). Guard on player.self(): a real in-dungeon tame always has one and reads the live
    -- level; the only pre-player tame is the starter pet, which always originates from Church Lvl 1 (dlvl 1).
    scrollAreaLevel[seed] = (player.self() ~= nil) and items.currentDeltaLevel() or 1
  end
  -- Every "Tamed" name surface becomes "Bonded" once the kill threshold is met.
  local prefix = isBonded(seed, monsterData.level) and "Bonded" or "Tamed"
  local scrollName, dwBuff
  if uIdx ~= nil and uIdx >= 0 then
    scrollName = prefix .. " " .. monsterData.name
    -- Unique scroll names carry no "Lvl N" prefix, but the level is still stored in
    -- dwBuff so the unique infobox can display it (otherwise it reads back as 0).
    dwBuff = encodeDwBuff(monsterData.savedHp, monsterData.maxHp, monsterData.level or 0, dif)
  else
    scrollName = prefix .. " Lvl " .. monsterData.level .. " " .. monsterData.name
    dwBuff = encodeDwBuff(monsterData.savedHp, monsterData.maxHp, monsterData.level, dif)
  end
  -- modData is the self-describing blob — the seed's progression (kills/immunity/TRN/gamemode) AND its
  -- Original Trainer — so the scroll survives a floor-drop trade and a re-stamp; empty for a non-scroll.
  return seed, scrollName, dwBuff, blobForSeed(seed)
end

-- Allocate a seed, store monster data in the session cache, and drop scroll on the floor.
-- Encodes typeId/uniqueTypeIdx in seed and hp+difficulty in dwBuff so data survives game restart.
function dropTameScroll(monsterData, x, y, origin)
  local seed, scrollName, dwBuff, modData = buildScrollParams(monsterData, nil, origin)
  tameScrollData[seed] = monsterData  -- session cache for fast lookup
  items.spawnAt(x, y, TAME_SCROLL_MAP, seed, scrollName, dwBuff, modData)
  -- Persist the blob with the floor item (level delta) + announce it live, so whoever picks it up keeps the
  -- scroll's full identity — even after we leave the game (the delta is handed to a joiner on connect, and
  -- restores onto the floor item; see items.setItemDeltaModData / OnItemPickedUp). Also covers SP level-exit.
  local lvl = items.currentDeltaLevel()
  items.setItemDeltaModData(lvl, seed, modData)
  broadcastScrollData(seed, lvl)             -- caches the blob on peers (must precede the DI replicate)
  broadcastDropScroll(x, y, seed, dwBuff, scrollName)  -- peers spawn the same floor item (incl. level owner)
  return seed
end

-- Allocate a seed and place a freshly created Tame Scroll directly in `owner`'s inventory. The inventory
-- sibling of dropTameScroll: shares buildScrollParams so the scroll carries the SAME seed/dwBuff/modData
-- (and records the same seed-keyed origin + session cache + peer announce) a floor-dropped tame would —
-- never a bespoke second-class scroll. Returns the seed, or nil if the inventory had no room.
function addTameScrollToInventory(owner, monsterData, origin)
  local seed, scrollName, dwBuff, modData = buildScrollParams(monsterData, nil, origin)
  tameScrollData[seed] = monsterData  -- session cache for fast lookup
  if not owner:addScrollByMapping(TAME_SCROLL_MAP, seed, scrollName, dwBuff, modData) then return nil end
  broadcastScrollData(seed)  -- announce this held scroll's identity to peers (no level => no delta write; no-op in SP)
  return seed
end

-- Build a monsterData record from a live deployed ally + its tracking entry.
-- entry provides capturedDifficulty (stored at deploy time).
-- Unique-ness is derived from entry.seed — the single source of truth used by every
-- other site (OnLevelEnter / OnItemPickedUp gilding, OnPrepareUniqueInfoBox, the dup
-- check). The live monster's ally.uniqueType can read back as None for a deployed ally,
-- so deriving uniqueness from it would yield a recalled scroll with a normal name and no gold
-- even though its seed/data are still unique.
function allyToMonsterData(ally, entry)
  local uType = seedGetUniqueType(entry.seed)
  -- The HP buff now lives in maxHitPoints, so ally.maxHealth is the BUFFED max. Persist the
  -- un-buffed snapshot (entry.base.maxHp) as the scroll's max and clamp current to it, so the
  -- transient buff (and any potion overheal above the buffed max) never bakes into the scroll.
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

-- Lazily refresh a Lost entry's stored HP from the live ally (called at level exit, before recall,
-- so a kept-Lost entry carries the ally's final HP rather than its stale deploy-time value).
function refreshRecoveryEntry(entry)
  if entry == nil or entry.seed == nil then return end
  if recoveryRegistry[entry.seed] == nil then return end
  recoveryRegistry[entry.seed].dwBuff = recoveryDwBuffFromData(allyToMonsterData(entry.monster, entry))
end

-- Recall a deployed ally and place its Tame Scroll directly in the owner's inventory.
-- Used for auto-recall on level exit and manual retame. The scroll is NEVER dropped on the floor: a
-- full inventory simply creates no scroll, so the caller keeps the recovery backup for Pepin instead
-- (a floor scroll alongside a live backup would be two copies at once — exploitable in multiplayer).
-- Returns true if the scroll was placed in inventory, false if the inventory/belt was full.
function recallAllyToInventory(ally, entry, owner)
  local data = allyToMonsterData(ally, entry)
  -- Reuse entry.seed so allyKillCounts[seed] is still valid after redeploy.
  local seed, scrollName, dwBuff, modData = buildScrollParams(data, entry.seed)
  tameScrollData[seed] = data  -- session cache
  local mid = ally.id
  ally:remove()
  broadcastRemove(mid)  -- peers despawn their mirrored copy of this recalled ally (no natural-death sync)
  if owner:addScrollByMapping(TAME_SCROLL_MAP, seed, scrollName, dwBuff, modData) then
    local scrollItem = owner:findScrollBySeed(seed)
    if scrollItem then
      -- Gold tier for unique champions/bosses AND Bonded scrolls.
      if data.uniqueTypeIdx ~= nil or isBonded(seed, data.level) then scrollItem.magical = 2 end  -- ITEM_QUALITY_UNIQUE → gold text + outline
    end
    return true
  end
  return false
end

-- Reconstruct monster data from a scroll item's seed and dwBuff.
-- Handles both normal scrolls (typeId in seed) and unique scrolls (uniqueTypeIdx in seed, bit 15 set).
function recoverScrollData(scrollSeed, scrollItem)
  local savedHp, maxHp, level, difficulty = decodeDwBuff(scrollItem.buff)
  if savedHp == 0 and maxHp == 0 then return nil end  -- no valid HP data; scroll unrecoverable
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

-- Build the player-facing recovery line for a registry entry, or nil if its scroll data can't be
-- reconstructed. "lost" = recall failed / orphaned (free re-buy at Pepin); "lostfull" = recalled
-- with no inventory room, so it went straight to recovery instead of the floor (free, same as
-- "lost", just a clearer message); "injured" = died in combat (paid, full-HP revive at Pepin). The
-- scroll name ("Tamed/Bonded [Lvl N] [Name]") matches the item Pepin hands back.
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

-- Fallback only: copy the scroll back so the engine's ConsumeScroll (which fires after
-- the deploy hook) removes the original while the copy survives. Used for genuine,
-- unpredictable spawn failures (no free tile, monster pool / type table full). Cap and
-- duplicate-unique limits are knowable before casting and are blocked upfront in
-- OnCanCastScroll instead, so the scroll is never consumed for those.
function refundTameScroll(caster, data, scrollSeed)
  local _, refundName, refundBuff, refundMod = buildScrollParams(data, scrollSeed)
  tameScrollData[scrollSeed] = data  -- ensure session cache for the refunded scroll
  if not caster:addScrollByMapping(TAME_SCROLL_MAP, scrollSeed, refundName, refundBuff, refundMod) then
    local pos = caster.position
    items.spawnAt(pos.x, pos.y, TAME_SCROLL_MAP, scrollSeed, refundName, refundBuff, refundMod)
  end
end

-- -------------------------------------------------------------------------
-- Plane-1 net sync: replicate a deployed ally onto same-level peers (the live monster + its golem
-- conversion + owner). This is the keystone every cross-client behaviour reads from — faction
-- targeting, friendly-fire, hostility, and XP credit all key off ownerPlayerId + isGolem on the live
-- monster. Combat numbers (max/current HP, resistance, AC) are a SEPARATE concern handled by a later
-- block (the owner broadcasts final values); the spawn message carries identity + difficulty only.
--
-- Why a mod-owned spawn instead of the engine spawn wheel: a tamed monster's species is frequently
-- NOT one of the level's natural monsters. The engine spawn cmd broadcasts a *level-local* index into
-- `LevelMonsterTypes`, which is meaningless on a peer whose independently-generated level never
-- registered that species — it resolves to a wrong/empty type → null sprite → render CRASH (bugs.md).
-- So mod spawns are now LOCAL-ONLY on the engine side (no NetSendCmdSpawnMonster); we replicate them
-- across clients over the pipe keyed by the globally-stable SPECIES id. Each client builds its own
-- natural monster set, then the owner's extra allies are recreated on top via `monsters.netSpawnAt`,
-- which registers the species locally (its own index + GFX). A short load delay on the joining client
-- is acceptable.
--
-- Pipe payloads are opaque strings; the mod owns encode/decode. Message types are "<TAG>|<args...>":
--   "SP|id|species|uniqueIdx|difficulty|x|y|seed|owner|parent" → recreate + golem-convert an ally on a
--                                                          peer (parent = spawner id for a minion, else -1).
--   "RQ"                                                → "I just entered this level; ally owners,
--                                                          (re)send your deployed allies to me."
-- "DR|typeId|uniqueIdx|difficulty|x|y|seed|maxHp|savedHp" → a non-owner asks the level owner to spawn
--                                                           its ally (mirrors CMD_REQUESTSPAWNGOLEM).
-- "DF|seed"                                              → owner couldn't place it; requester refunds.
-- "CO|id|maxHp|hp|minDmg|maxDmg|toHit|ac|resist|isMinion|bonded|bondedImm|baseMaxDmg|sharePctMille|
--  magicCur|resFire|resLight|resMagic|trnVariant|nearBonded|baseMinDmg|baseToHit|baseAC|baseMaxHp|kills|
--  gamemode|areaLevel|ohId|ohName" → the ally's OWNER broadcasts its final combat values + caster profile to same-level
-- clients. Receivers apply the combat values to the live monster (so hostile combat, melee damage, and
-- HP-threshold AI all use the owner's buffed numbers, not the base re-roll) and cache the caster profile
-- for spell-damage resolution + the values a peer can't derive (Bonded recolour variant, the pre-Bonded
-- flash window, the base stats / kill count / Original-Trainer the info boxes show). ohName is the LAST
-- field (free-form; may contain "|", so the receiver rest-captures it verbatim). Owner-authoritative:
-- no receiver re-derives.
-- "RM|id" → the OWNER silently removed a tracked ally/minion (recall, retame, level-exit, or a parent's
-- minion cleanup). Receivers despawn their local copy so it doesn't linger as a ghost. NOT used for a
-- natural death (the engine reaps that on every client) nor for a tamed wild monster (see CR).
-- "CR|id" → a wild monster was just removed locally as part of a conversion (e.g. tamed into a scroll).
-- It is NOT golem-flagged, so RM's owner check can't carry it; CR tells same-level peers to remove the
-- same plain monster too, so the level owner's sync can't re-materialise it as a live/ghost copy.
-- "DI|x|y|seed|dwBuff|name" → a Tame Scroll was just dropped on the floor (a fresh tame). Each same-level
-- peer spawns an identical item locally (same seed/mapping/position), so the floor item exists on every
-- client -- including the level owner, whose delta is authoritative, so it is never purged -- and MP
-- pickup (identity-keyed by seed) removes all copies together. The blob rides the SD message sent just
-- before this one; the receiver reads it from receivedBlobs. The name is the LAST field (no "|").
--
-- One table (NET.*) instead of a separate top-level local per tag. NET stays `local` (not a sandbox
-- global) because it is part of the net layer -- the inter-mod surface that talks to the LuaNet
-- multiplexer; grouping the tags into one table also keeps the local footprint to a single slot.
local NET = {
  SPAWNALLY  = "SP",
  REQSYNC    = "RQ",
  DEPLOYREQ  = "DR",
  DEPLOYFAIL = "DF",
  COMBATOVR  = "CO",
  REMOVE     = "RM",
  SCROLLDATA = "SD",
  CAPTURE    = "CR",
  DROPITEM   = "DI",
}

-- Broadcast an ally's full identity so same-level peers can recreate it. `mask` defaults to all other
-- clients; pass a single-player bitmask to answer one requester. `parentId` is the spawner's monster id
-- for a minion (so peers track the parent link for cap-counting and despawn-with-parent), or nil/-1 for a
-- directly-deployed ally. No-op in single-player.
local function broadcastSpawnAlly(monster, typeId, uniqueIdx, difficulty, owner, seed, mask, parentId)
  if not system.isMultiplayer() then return end
  local pos = monster.position
  local payload = table.concat(
    { NET.SPAWNALLY, monster.id, typeId, uniqueIdx, difficulty, pos.x, pos.y, seed, owner, parentId or -1 }, "|")
  luanet.send("hunter", payload, mask)  -- mask nil => all other clients (luanet.send handles default + SP no-op)
end

-- Tell same-level peers to despawn the monster at `monsterId` (an ally/minion we just silently removed).
-- Keyed by monster id, which is identical on every client for a tamed ally (peers recreate it at the
-- owner's id via monsters.netSpawnAt). No-op in single-player. Assigns the forward-declared local above
-- so the recall / minion-cleanup helpers (defined earlier) can reach it.
function broadcastRemove(monsterId)
  if not system.isMultiplayer() then return end
  luanet.send("hunter", NET.REMOVE .. "|" .. monsterId)
end

-- Tell same-level peers to remove a plain (non-golem) wild monster we just removed locally as part of a
-- conversion (taming it into a scroll). Without this the level owner's monster sync re-materialises the
-- monster on the tamer's client (a live "invisible" copy) and it lingers as a ghost on every other peer.
-- Keyed by monster id, identical across clients for a level-natural monster. No-op in single-player.
-- level/x/y travel with the id so a peer NOT on the captor's level (e.g. still in town) can still record
-- the kill in that level's delta -- otherwise it never learns the wild monster was removed (the live removal
-- and a level-scoped pipe message only reach same-level peers) and regenerates it alive on entry, exactly as
-- a networked monster death records the delta on every client regardless of their level.
local function broadcastCaptureRemove(monsterId, level, x, y)
  if not system.isMultiplayer() then return end
  luanet.send("hunter", table.concat({ NET.CAPTURE, monsterId, level, x, y }, "|"))
end

-- Announce a scroll's full identity blob keyed by seed, so a peer that later receives the scroll via a live
-- trade can restore it from receivedBlobs. `level` is the delta level of the floor item being announced
-- (so receivers mirror the blob into that level's delta and can serve a late joiner even after we leave), or
-- nil/-1 for a held scroll (display/trade cache only, no delta write). `mask` answers one requester (RQ);
-- default = all other clients. The blob is the LAST field (it is binary — string.pack output — and may
-- contain "|"; the receiver captures everything after the 2nd "|" verbatim). No-op in single-player.
function broadcastScrollData(seed, level, mask)
  if not system.isMultiplayer() then return end
  local payload = table.concat({ NET.SCROLLDATA, level or -1, seed, blobForSeed(seed) }, "|")
  luanet.send("hunter", payload, mask)  -- mask nil => all other clients (luanet.send handles default + SP no-op)
end

-- Replicate a freshly dropped Tame Scroll floor item onto same-level peers. Each peer spawns an identical
-- item locally (same seed/mapping/position) so the floor item exists on every client -- crucially on the
-- level owner, whose delta is authoritative, so an item dropped by a non-owner is never purged by a delta
-- resync. Pickup is identity-keyed (seed/index/createInfo), so the independently-placed copies are removed
-- together. MUST be sent AFTER the scroll's SD message so the receiver already has the blob cached. The
-- name is the LAST field (free-form, no "|"). No-op in single-player.
function broadcastDropScroll(x, y, seed, dwBuff, name)
  if not system.isMultiplayer() then return end
  luanet.send("hunter", table.concat({ NET.DROPITEM, x, y, seed, dwBuff, name }, "|"))
end


-- Broadcast one owned ally's final combat values + caster profile (the CO message). `mask` defaults to
-- all other same-level clients; pass a single-client bitmask to answer one requester (RQ). No-op in
-- single-player (no peers) and for an ally we cannot profile.
local function broadcastCombatOverride(entry, mask)
  if not system.isMultiplayer() then return end
  local m = entry.monster
  if m == nil then return end
  local prof = ownAllyProfile(entry)
  if prof == nil then return end
  -- OH name is the LAST field (free-form); it may legitimately contain the "|" delimiter, so it is sent
  -- verbatim and the receiver rest-captures it after the fixed leading fields (which never contain "|").
  local ohName = prof.ohName or "?"
  local payload = table.concat({
    NET.COMBATOVR, m.id, m.maxHealth, m.health, m.minDamage, m.maxDamage, m.toHit, m.armorClass,
    m.resistance, prof.isMinion and 1 or 0, prof.bonded and 1 or 0, prof.bondedImm, prof.baseMaxDamage,
    math.floor(prof.sharePct * 1000), prof.magicCurrent, prof.resFire, prof.resLight, prof.resMagic,
    prof.trnVariant or 0, prof.nearBonded and 1 or 0,
    prof.baseMinDamage, prof.baseToHit, prof.baseArmorClass, prof.baseMaxHp, prof.kills, prof.gamemode,
    prof.areaLevel, prof.ohId, ohName,
  }, "|")
  luanet.send("hunter", payload, mask)  -- mask nil => all other clients (luanet.send handles default + SP no-op)
end

-- Broadcast CO for every deployed ally/minion. Called after a recalc (the share-divided buff shifts all
-- allies' stats at once) so peers stay current. `mask` optional (answer one requester on RQ). Assigns the
-- forward-declared local above so recalcAllyBuffs can reach it.
function broadcastAllCombatOverrides(mask)
  if not system.isMultiplayer() then return end
  for _, entry in ipairs(deployedAllies) do
    broadcastCombatOverride(entry, mask)
  end
end

-- Shared final step of deploying an ally: golem-convert it to `ownerId`, restore persisted HP, track it
-- in deployedAllies (its AI runs on the ally's owner), back it up for recovery, apply Bonded bonuses, and
-- recompute the share-divided buff. Used by BOTH deploy paths:
--   • local (we are the level owner): doBroadcast = true — also SP-broadcasts the ally to same-level peers.
--   • requested (we asked the owner, the SP echo arrived): doBroadcast = false — the SP already crossed.
function finishDeploy(monster, data, seed, ownerId, doBroadcast)
  -- Set max before current so the wounded current HP is applied against the correct maximum.
  monster:setMaxHitPoints(data.maxHp)
  monster:setHitPoints(data.savedHp)
  local entry = { monster = monster, seed = seed, capturedDifficulty = data.capturedDifficulty or 0 }
  trackDeployedAlly(entry)
  -- Back the ally up as "lost" the moment it deploys, so a crash/quit while it is out still leaves a
  -- recoverable scroll. A clean recall/retame deletes this entry; only orphaned ones reach Pepin.
  putRecovery(seed, recoveryDwBuffFromData(data), "lost")
  monster:makeGolem(ownerId)
  if doBroadcast then
    -- Replicate the ally onto same-level peers (Plane 1): species + identity so each peer recreates it
    -- locally (registering the species + GFX on its own client) and golem-converts it.
    broadcastSpawnAlly(monster, data.typeId, data.uniqueTypeIdx or -1, data.capturedDifficulty or 0, ownerId, seed)
  end
  -- Snapshot base stats; if already Bonded (kills met in a prior session), restore its stored defensive
  -- bonus, rolling one if the seed has none yet. Then recompute the share-divided buff across all allies.
  snapshotAllyBase(entry)
  if isBonded(seed, monster.level) then
    rollBondedBonus(entry)
    rollBondedTrn(entry)       -- ensure an already-Bonded ally has its recolour (no-op if rolled)
    applyBondedBonus(entry)
    applyBondedGlow(entry)     -- re-light an already-Bonded ally on redeploy
  end
  recalcAllyBuffs()
  tameScrollData[seed] = nil
end

-- -------------------------------------------------------------------------
-- Minion spawning is single-authority on the LEVEL OWNER (the only client that may allocate a monster
-- slot — see the deploy path / PrepareSpawnSlot). The level owner spawns the minion for whichever ally
-- raised it, attributes it to that ally's OWNER, and replicates it over the species-id pipe (SP carrying
-- the parentId + captured difficulty). The ally's owner owns the minion's Plane-2 state: it tracks it in
-- deployedAllies, bakes the one-time buff, and broadcasts its combat values (CO). When the level owner IS
-- the ally's owner it does both halves directly; otherwise the owner adopts on the SP echo. Minion species
-- are not level-natural, so peers must recreate by species id — never the engine spawn wheel.
-- -------------------------------------------------------------------------

-- The captured difficulty a tamed ally was tamed at (so its minions scale to match), from whichever table
-- tracks it; falls back to the live game difficulty if unknown.
function allyCapturedDifficulty(ally)
  local entry = allyScratch(ally.id)
  if entry ~= nil and entry.capturedDifficulty ~= nil then return entry.capturedDifficulty end
  return monsters.currentDifficulty()
end

-- Owner-side bookkeeping for an already-spawned, already-golem-flagged minion: track it in deployedAllies
-- (isMinion + parentId — reuses the ally outline/name path, is excluded from the deploy cap, despawns with
-- its parent), snapshot base + bake the flat CLVL% minion buff once, then broadcast its combat values. Does
-- NOT broadcast SP (the spawn authority already did). Called only on the minion's OWNER.
function adoptOwnMinion(minion, parentId)
  local entry = { monster = minion, seed = nil, isMinion = true, parentId = parentId }
  trackDeployedAlly(entry)
  snapshotAllyBase(entry)   -- after makeGolem, so golemToHit is set
  applyMinionBuff(entry)    -- minions don't draw from / divide the live pool and never recalc
  broadcastCombatOverride(entry)
  return entry
end

-- Called on the LEVEL OWNER immediately after it spawns a minion for `parentAlly`. Golem-flags the minion
-- to the parent ally's owner, replicates it to same-level peers (SP), then either adopts it (we are that
-- owner) or tracks it as a remote ally (the real owner adopts it when the SP echo reaches it).
function registerSpawnedMinion(minion, parentAlly, captured)
  local ownerId  = parentAlly.ownerPlayerId
  local parentId = parentAlly.id
  minion:makeGolem(ownerId)
  -- SP: species recreate on peers; seed 0 (minions have none); parentId links it for cap-count + despawn.
  broadcastSpawnAlly(minion, minion.typeId, -1, captured, ownerId, 0, nil, parentId)
  local me = player.self()
  if me ~= nil and ownerId == me.id then
    adoptOwnMinion(minion, parentId)
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
    -- Resolve the monster. For ANOTHER player's ally we always (re)create it at the slot, mirroring
    -- vanilla CMD_SPAWNMONSTER (which unconditionally re-inits at the given slot id). Deploy slots sit
    -- above the natural-monster region, so we are their sole writer: overwriting a stale copy left by a
    -- prior occupant of a reused slot is always correct. For our OWN ally we keep the copy we spawned
    -- locally, recreating it only if the level owner spawned it for us (DR) and it isn't here yet.
    -- netSpawnAt seeds initial state from the slot id (mid); per-monster AI RNG is re-synced each tick by
    -- the engine (MonsterSeeds, keyed on the same id), so no seed is passed.
    local me = player.self()
    local m
    if me ~= nil and ownerId == me.id then
      m = monsters.fromId(mid)
    end
    if m == nil then
      m = monsters.netSpawnAt(mid, tonumber(species), tonumber(uniq),
        tonumber(diff), tonumber(x), tonumber(y))
      if m == nil then return end
    end
    if me ~= nil and ownerId == me.id and parentId == nil then
      -- This is OUR (directly-deployed) ally, spawned on our behalf by the level owner (non-owner
      -- deploy). Complete the local Plane-2 setup we deferred when we sent the DR. finishDeploy
      -- golem-flags it to us and tracks it in deployedAllies (its AI runs here as on any owner).
      local data = pendingDeploys[tonumber(seed)]
      if data ~= nil then
        finishDeploy(m, data, tonumber(seed), me.id, false)
        pendingDeploys[tonumber(seed)] = nil
      else
        m:makeGolem(ownerId)  -- no pending data (e.g. an RQ resend after we already finished): just own it
      end
    elseif me ~= nil and ownerId == me.id and parentId ~= nil then
      -- OUR minion, spawned on our behalf by the level owner (its parent — our king/Hork — raised it while
      -- we were not the level owner). Own it and do the owner-side minion bookkeeping (buff + CO). Guard
      -- against an RQ/SP resend after we already adopted it (idempotent).
      m:makeGolem(ownerId)
      if not isDeployedAlly(mid) then adoptOwnMinion(m, parentId) end
    else
      -- Another player's ally or minion. Golem-flag it for the REMOTE owner so faction targeting /
      -- friendly-fire / hostility resolve here, and record it in remoteAllies (with its captured difficulty,
      -- so if we are the level owner we can scale the minions it raises) so the shared AI hooks recognise it
      -- and run its (deterministic) AI locally. A remote observer derives ownership from ownerPlayerId +
      -- isGolem (isOtherHuntersAlly).
      m:makeGolem(ownerId)
      remoteAllies[mid] = { ownerId = ownerId, parentId = parentId, capturedDifficulty = tonumber(diff),
        uniqueIdx = tonumber(uniq) }  -- -1 for a normal ally; >= 0 picks the "no Lvl N" unique name form
    end

  elseif kind == NET.REQSYNC then
    -- A client just entered our level (or any level). If we own deployed allies, (re)send each one to
    -- the requester. We don't gate on the requester's level here (it may not be visible to us yet); the
    -- requester's SP handler validates that we share its active level before acting. Allies are always
    -- on our current level (recalled on level exit), so every tracked non-minion entry is eligible.
    local me = player.self()
    if me == nil then return end
    local mask = 1 << senderId
    for _, entry in ipairs(deployedAllies) do
      local mon = entry.monster
      if mon ~= nil and not entry.isMinion and entry.seed ~= nil then
        local uniq = seedGetUniqueType(entry.seed)  -- -1 if not unique
        broadcastSpawnAlly(mon, mon.typeId, uniq, entry.capturedDifficulty or 0, me.id, entry.seed, mask)
        broadcastCombatOverride(entry, mask)  -- follow the spawn with its combat values + caster profile
      end
    end
    -- Also answer with the full identity blob of every Tame Scroll we're holding, so the newly-entered
    -- Hunter already has it cached if we trade one to them.
    if me.className == HUNTER_CLASS then
      me:iterateInventory(function(item)
        if item:isScrollOf(TAME_ID) then broadcastScrollData(item.seed, nil, mask) end
      end)
    end

  elseif kind == NET.SCROLLDATA then
    -- A peer announced a scroll's full mod-data blob keyed by seed: payload = SD|level|seed|<blob bytes>.
    -- Cache the raw blob so a later live trade of that scroll restores everything on pickup, and cache its
    -- Original Trainer for display. If the announcement is for a FLOOR item (level >= 0), mirror the blob
    -- into that level's delta so this client can serve it to a late joiner even after the dropper leaves.
    -- The blob is the last field and may contain "|"/NUL — capture it verbatim, do not split it.
    local levelStr, seedStr, blob = payload:match("^SD|(%-?%d+)|(%d+)|(.*)$")
    local seed = tonumber(seedStr)
    if seed == nil or blob == nil then return end
    receivedBlobs[seed] = blob
    local _, _, _, _, _, ohId, ohName = decodeBlob(blob)
    if ohName ~= nil and ohName ~= "" then scrollOrigin[seed] = { name = ohName, id = ohId } end
    local level = tonumber(levelStr)
    if level ~= nil and level >= 0 then items.setItemDeltaModData(level, seed, blob) end

  elseif kind == NET.COMBATOVR then
    -- The owner of a remote ally sent its final combat values + caster profile. Apply the values to the
    -- live monster (so our hostile combat / melee damage / HP-threshold AI use the buffed numbers) and
    -- cache the profile for spell-damage resolution. Only for a remote ally we track — never our own
    -- (we own the live values) — so guard on remoteAllies membership.
    local sender = player.get(senderId)
    if sender == nil or not sender:isOnActiveLevel() then return end
    -- Pull the 28 fixed leading fields (tag + numbers, never contain "|") positionally, then take
    -- everything after the 28th "|" as ohName (the 29th field) verbatim -- a player name may contain "|".
    local parts = {}
    local rest = payload
    for i = 1, 28 do
      local tok, tail = rest:match("^([^|]*)|(.*)$")
      if tok == nil then return end  -- malformed: fewer than 28 delimiters
      parts[i] = tok
      rest = tail
    end
    parts[29] = rest  -- free-form ohName, kept intact even if it contains "|"
    local id = tonumber(parts[2])
    local rec = remoteAllies[id]
    if rec == nil then return end  -- not (yet) a tracked remote ally; the next CO/RQ will catch it
    local m = monsters.fromId(id)
    if m == nil then return end
    m:setMaxHitPoints(tonumber(parts[3]))
    m:setHitPoints(tonumber(parts[4]))
    m:setMinDamage(tonumber(parts[5]))
    m:setMaxDamage(tonumber(parts[6]))
    m:setToHit(tonumber(parts[7]))
    m:setArmorClass(tonumber(parts[8]))
    m:setResistance(tonumber(parts[9]))
    local prevProfile = rec.profile  -- to detect a live Bonded promotion (nil on first CO = no replay)
    local newBonded = tonumber(parts[11]) == 1
    rec.profile = {
      isMinion      = tonumber(parts[10]) == 1,
      bonded        = newBonded,
      bondedImm     = tonumber(parts[12]),
      baseMaxDamage = tonumber(parts[13]),
      sharePct      = tonumber(parts[14]) / 1000,
      magicCurrent  = tonumber(parts[15]),
      resFire       = tonumber(parts[16]),
      resLight      = tonumber(parts[17]),
      resMagic      = tonumber(parts[18]),
      trnVariant    = tonumber(parts[19]),
      nearBonded    = tonumber(parts[20]) == 1,
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
    -- Mirror the Bonded cosmetics on this peer. The permanent aura glow is state-driven (idempotent), so
    -- (re)apply it whenever the ally is Bonded; OnGetMonsterTRN paints the recolour from prof.trnVariant.
    if newBonded then m:setLightRadius(BONDED_LIGHT_RADIUS) end
    -- One-shot promotion Flash burst: fire only on the live false→true transition we actually witnessed
    -- (prevProfile present and not bonded). A fresh record (prevProfile == nil: late join, redeploy, or RQ
    -- resync of an already-Bonded ally) never replays it. Fires on every client for consistency, exactly
    -- as the owner's own promoteToBonded does — ally-safe per the engine faction check.
    if prevProfile ~= nil and not prevProfile.bonded and newBonded then
      m:castFlashSelf()
    end

  elseif kind == NET.REMOVE then
    -- The sender removed one of its allies/minions; despawn our local copy so it doesn't ghost. Self-
    -- validating: only act on a live monster golem-flagged to THIS sender. That holds even after our own
    -- OnMonsterDeath cleared the Lua tracking (the engine golem flag persists until the body is removed),
    -- so there is no race with a parent-death sweep. It also can never touch our own ally or the vanilla
    -- Golem (their ownerPlayerId is our local id, never the remote sender's) — the Golem barometer holds.
    local id = tonumber(payload:match("^RM|(%-?%d+)$"))
    if id == nil then return end
    local m = monsters.fromId(id)
    if m == nil then remoteAllies[id] = nil; return end
    if not (m.isGolem and m.ownerPlayerId == senderId) then return end
    m:remove()
    remoteAllies[id] = nil

  elseif kind == NET.CAPTURE then
    -- The sender tamed a wild monster, removing it only on their client. We must reap it too -- and crucially
    -- record the kill in our copy of that level's delta -- so it never regenerates alive when we (or a later
    -- joiner served our delta) load the level. This mirrors how a networked monster death records the delta on
    -- EVERY client regardless of their current level. Never touch a golem-flagged monster (allies use RM).
    local id, level, x, y = payload:match("^CR|(%-?%d+)|(%-?%d+)|(%-?%d+)|(%-?%d+)$")
    if id == nil then return end
    local mid = tonumber(id)
    local sender = player.get(senderId)
    if sender ~= nil and sender:isOnActiveLevel() then
      -- Same level: remove the live monster. removeAsKilled also records the delta_kill in our delta.
      local m = monsters.fromId(mid)
      if m ~= nil and not m.isGolem then m:removeAsKilled() end
    else
      -- Not on the captor's level (e.g. still in town): no live monster here, so just record the kill in that
      -- level's delta. Without this a client off-level at tame time regenerates the monster alive on entry.
      monsters.recordDeltaKill(tonumber(level), mid, tonumber(x), tonumber(y))
    end

  elseif kind == NET.DROPITEM then
    -- The sender dropped a Tame Scroll on the floor. Spawn an identical item locally (same seed/mapping/
    -- position) so the floor scroll exists on this client too: on the level owner this lands in the
    -- authoritative delta (so it is never purged), and on every client it shares the dropper's seed
    -- identity, so MP pickup removes all copies together. Slot ids / exact positions are per-client but
    -- pickup is identity-keyed, so they need not match. Only materialise it for a peer on the sender's
    -- level. The blob arrived first over SD (receivedBlobs); attach it so the floor item carries full
    -- identity (and the SD handler already mirrored it into this level's delta for late joiners).
    local sender = player.get(senderId)
    if sender == nil or not sender:isOnActiveLevel() then return end
    local x, y, seed, dwBuff, name = payload:match("^DI|(%-?%d+)|(%-?%d+)|(%d+)|(%d+)|(.*)$")
    if seed == nil then return end
    local s = tonumber(seed)
    -- The encoded "Tamed/Bonded Lvl N <Monster>" name is Hunter-only (OnCustomItemRecreated normally
    -- gates it, but items.spawnAt bypasses that). A non-Hunter must still spawn the item so its delta
    -- holds it, but with the base "Tame Scroll" name — pass nil so spawnAt keeps the base item name.
    local me = player.self()
    local displayName = (me ~= nil and me.className == HUNTER_CLASS) and name or nil
    items.spawnAt(tonumber(x), tonumber(y), TAME_SCROLL_MAP, s, displayName, tonumber(dwBuff), receivedBlobs[s] or "")

  elseif kind == NET.DEPLOYREQ then
    -- A non-owner asked us to spawn their ally. Mirrors the engine's CMD_REQUESTSPAWNGOLEM: only the
    -- level owner spawns, keeping monster-slot allocation single-authority (avoids cross-client desync).
    local me = player.self()
    if me == nil or not me:isLevelOwnedByLocalClient() then return end
    local sender = player.get(senderId)
    if sender == nil or not sender:isOnActiveLevel() then return end
    local typeId, uniq, diff, x, y, seed, maxHp, savedHp =
      payload:match("^DR|(%-?%d+)|(%-?%d+)|(%-?%d+)|(%-?%d+)|(%-?%d+)|(%-?%d+)|(%-?%d+)|(%-?%d+)$")
    if typeId == nil then return end
    local uniqIdx = tonumber(uniq)
    local d = tonumber(diff)
    local m
    if uniqIdx >= 0 then
      m = monsters.spawnUniqueAt(uniqIdx, d, tonumber(x), tonumber(y))
    else
      m = monsters.spawnWithDifficulty(tonumber(typeId), d, tonumber(x), tonumber(y))
    end
    if m == nil then
      -- Couldn't place it (no free tile / pool full). Tell the requester so it refunds the scroll.
      luanet.send("hunter", NET.DEPLOYFAIL .. "|" .. seed, 1 << senderId)
      return
    end
    -- Owner is HP-authoritative: apply the requester's persisted HP, which then syncs to all clients.
    m:setMaxHitPoints(tonumber(maxHp))
    m:setHitPoints(tonumber(savedHp))
    m:makeGolem(senderId)                       -- owned by the requester, not us
    remoteAllies[m.id] = { ownerId = senderId }  -- someone else's ally; runs its AI locally too
    -- Broadcast to all OTHER same-level clients (default mask) — including the requester, who materialises
    -- it and completes its deferred Plane-2 setup in the SP handler (owner == me branch).
    broadcastSpawnAlly(m, tonumber(typeId), uniqIdx, d, senderId, tonumber(seed))

  elseif kind == NET.DEPLOYFAIL then
    -- The level owner could not place an ally we requested — refund the scroll the engine already consumed.
    local seedStr = payload:match("^DF|(%-?%d+)$")
    if seedStr == nil then return end
    local seed = tonumber(seedStr)
    local data = pendingDeploys[seed]
    if data == nil then return end
    pendingDeploys[seed] = nil
    local me = player.self()
    if me ~= nil then refundTameScroll(me, data, seed) end
  end
end)

-- NOTE: we deliberately do NOT register an OnGolemCanRunAI handler. A tamed ally's AI now runs on
-- EVERY client (like a vanilla golem) — the per-tick AI hooks below are written to behave identically
-- on the owner and on peers (owner anchored via ownerPlayerId, randomness drawn from the synced
-- per-monster RNG via monsters.aiRandom, combat inputs synced via the CO message). Suppressing a
-- remote ally's AI was what froze it on peers (the engine monster sync carries position, not mode).

-- On entering a level, ask any same-level ally owners to (re)send their deployed allies, so a client
-- that joins AFTER a deploy still materialises the allies (the live SP at deploy time only reached
-- clients already on the level). Fires for everyone in MP (non-Hunters need allies for correct
-- combat/rendering too); no-op in single-player. Clear stale remote-ally tracking first — monster slot
-- ids are per-level, so the previous level's entries are meaningless here and the RQ replies repopulate.
events.OnLevelEnter.add(function()
  remoteAllies = {}
  pendingDeploys = {}  -- keyed by seed; a deploy request in flight across a level change is stale
  if not system.isMultiplayer() then return end
  luanet.send("hunter", NET.REQSYNC)
end)

-- -------------------------------------------------------------------------
-- OnSpellActionFrame: Tame skill and scroll — fires at the mid-animation release frame.
-- Using OnSpellActionFrame instead of OnSpellCast so the effect syncs with the animation.
-- -------------------------------------------------------------------------

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
      if scrollItem == nil then return end  -- scroll not in inventory; nothing to refund
      data = recoverScrollData(scrollSeed, scrollItem)
      if data == nil then
        -- dwBuff is zeroed or corrupt — can't determine what to spawn.
        -- Refund by copying the scroll before ConsumeScroll removes it.
        if not caster:addScrollByMapping(TAME_SCROLL_MAP, scrollSeed, scrollItem.name, scrollItem.buff, scrollItem.modData) then
          local pos = caster.position
          items.spawnAt(pos.x, pos.y, TAME_SCROLL_MAP, scrollSeed, scrollItem.name, scrollItem.buff, scrollItem.modData)
          -- Floor refund: persist the blob with the floor item + announce it + replicate it to peers,
          -- exactly as dropTameScroll does (so a non-owner's refund isn't purged by a delta resync).
          local lvl = items.currentDeltaLevel()
          items.setItemDeltaModData(lvl, scrollSeed, scrollItem.modData)
          broadcastScrollData(scrollSeed, lvl)
          broadcastDropScroll(pos.x, pos.y, scrollSeed, scrollItem.buff, scrollItem.name)
        end
        return
      end
    end
    -- Cap / duplicate-unique limits are normally blocked upfront in OnCanCastScroll
    -- (no consumption). These are last-resort safety nets for any path that bypasses
    -- the upfront check (e.g. a hotkey cast, where the selected seed is unknown): they
    -- refund so the scroll is never silently lost.
    if countDeployedAllies() >= MAX_ALLIES then
      refundTameScroll(caster, data, scrollSeed)
      caster:say(player.HeroSpeech.ICantDoThat)
      return
    end
    if data.uniqueTypeIdx ~= nil and isUniqueTypeDeployed(data.uniqueTypeIdx) then
      refundTameScroll(caster, data, scrollSeed)
      caster:say(player.HeroSpeech.ICantDoThat)
      return
    end

    -- Spawn at the cursor's targeted tile; fall back to caster's feet if no position given.
    local spawnX = targetX or caster.position.x
    local spawnY = targetY or caster.position.y
    local capturedDifficulty = data.capturedDifficulty or 0

    -- Monster spawning is level-owner-authoritative in this engine (PrepareSpawnSlot / vanilla
    -- SpawnMonster both gate on isLevelOwnedByLocalClient, "to prevent desyncs in multiplayer"). If we
    -- are NOT the level owner we cannot allocate a monster slot locally — mirror the base-game Golem
    -- spell, which sends CMD_REQUESTSPAWNGOLEM so the owner spawns on the caster's behalf. We send a DR
    -- on the pipe; the level owner spawns + golem-flags + applies HP, then SP-broadcasts it back so it
    -- materialises here, where the SP handler (owner == me branch) completes the deferred Plane-2 setup.
    if system.isMultiplayer() and not self:isLevelOwnedByLocalClient() then
      pendingDeploys[scrollSeed] = data
      luanet.send("hunter", table.concat(
        { NET.DEPLOYREQ, data.typeId, data.uniqueTypeIdx or -1, capturedDifficulty, spawnX, spawnY,
          scrollSeed, data.maxHp, data.savedHp }, "|"))
      -- The engine removes the scroll item after this hook returns; if the owner can't place the ally it
      -- echoes DF and we refund (DF handler). Plane-2 setup is deferred until the SP echo arrives.
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
      -- Genuine spawn failure (no free tile, monster pool full, or type table full) — we ARE the level
      -- owner here, so this is not the ownership gate. This is the legitimate use of the refund fallback:
      -- the failure is not knowable before the cast. ConsumeScroll removes the original after this hook
      -- returns; the refunded copy survives.
      refundTameScroll(caster, data, scrollSeed)
      return
    end

    -- We are the level owner: spawn done locally. Golem-convert, restore HP, track, back up, apply Bonded
    -- bonuses, recompute buffs, and SP-broadcast the ally to same-level peers (doBroadcast = true).
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
        -- Manual retame: recall the scroll into inventory (never dropped on the floor). Refresh the
        -- backup first (capture current HP). A clean recall deletes the backup; a full inventory keeps
        -- it as "lostfull" — the scroll lives only in recovery storage (never a grabbable floor item),
        -- recovered at Pepin. Floor-dropping was removed because a floor scroll alongside a live backup
        -- is two copies at once: in multiplayer another player could grab the floor copy and duplicate
        -- it. Announce immediately so the player knows where the scroll went.
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
        recalcAllyBuffs()  -- the deployed count dropped; survivors re-absorb the freed buff share
        return
      end
    end
    return  -- allied monster not tracked by us (e.g. another player's ally), do nothing
  end

  -- A monster that has already reached 0 HP (dead, or mid death-animation) must never be captured. Its
  -- death is deterministic and already running on every other client; converting it here (removeAsKilled +
  -- scroll mint) races that synced death -> a half-removed "twitching" body / ghost on peers, plus a scroll
  -- minted from a corpse. The HP-percent gate below doesn't catch this (a dying monster reads 0%, the
  -- easiest possible tame), so veto it explicitly at the capture layer and let the death complete normally.
  if target.hasNoLife then return end

  -- ---- Capture: tame a monster that passes BOTH the active tier's mlvl/category gate
  --      AND the category's capture-HP threshold (see the tier model near the top). ----
  local clvl     = caster.characterLevel
  local mlvl     = target.level
  local tier     = tameTier(clvl)
  local category = categoryFromTarget(target)

  -- Diablo is gate-eligible at Tame+++, but taming Diablo is deferred to its own sub-task
  -- (the Apocalypse friendly-fire-on-players landmine must be solved first). Hard-block for now.
  if category == CAT_DIABLO then return end

  -- mlvl/category gate: an out-of-criteria monster can never be tamed, regardless of HP.
  -- (This silent return is mirrored as a hard "I can't do that" pre-cast veto in a later pass.)
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
  local capturedId = target.id  -- capture before remove() so peers can despawn the same wild monster

  -- Taming a quest monster clears its quest exactly as if it were killed (quest state + death
  -- speech, e.g. Skeleton King -> "Rest well, Leoric..."; Lazarus -> opens the path to Diablo).
  -- No-op for non-quest monsters (incl. Lachdanan, who is never a combat target). Called before
  -- remove() while the monster's type/uniqueType are still intact.
  target:checkQuestKill()

  -- removeAsKilled (not remove): a wild monster is level-natural, so it must be recorded as killed in
  -- the MP delta. Otherwise a client that loads this level later (e.g. the level owner, whose delta is
  -- authoritative) regenerates it from the level seed and it survives there as a live ghost -- and its
  -- still-occupied slot id can collide with an id reused by a later-deployed ally, hiding that ally.
  local capturedLevel = items.currentDeltaLevel()  -- captor's level, for off-level peers' delta records
  target:removeAsKilled()
  broadcastCaptureRemove(capturedId, capturedLevel, pos.x, pos.y)  -- peers reap the wild monster (live or via delta)

  -- Stamp the taming Hunter as the monster's permanent Original Trainer (name + OHID).
  dropTameScroll(monsterData, pos.x, pos.y, { name = caster.name, id = getMyOhId() })
end)

-- -------------------------------------------------------------------------
-- applySharePotion: internal helper — scan caster's inventory for a health
-- potion, consume it (unless level-scaling freecast proc fires), and heal
-- the target ally. Returns true if a potion fired, false otherwise.
--   Full Heal  → restore to max HP (or 150% on overheal proc).
--   Heal       → restore min(current + 30% maxHP, maxHP) (or 150% on overheal).
--   No potion  → voice line "I can't do that", return false.
-- -------------------------------------------------------------------------

function applySharePotion(caster, target)
  local maxHp     = target.maxHealth
  local currentHp = target.health

  if currentHp >= maxHp then
    caster:say(player.HeroSpeech.IDontNeedToDoThat)
    return false
  end

  -- Detect a usable health potion by its EFFECT (miscId), not its base item index.
  -- IDidx pins one exact AllItemsList entry; IMISC_HEAL / IMISC_FULLHEAL match every
  -- healing potion regardless of how it was created. Capture the matched item's IDidx
  -- so we can remove that exact base type after a successful share.
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
  local freecast = math.random(100) <= level
  local overheal = math.random(100) <= level

  if potionType == "full" then
    if not freecast then caster:removeItem(potionIDidx, 1) end
    target:setHitPoints(overheal and math.floor(maxHp * 1.5) or maxHp)
    audio.playSfx(audio.SfxID.ItemPotion)
    return true
  elseif potionType == "partial" then
    if not freecast then caster:removeItem(potionIDidx, 1) end
    local healedHp = overheal and math.floor(maxHp * 1.5) or math.min(currentHp + math.floor(maxHp * 0.3), maxHp)
    target:setHitPoints(healedHp)
    audio.playSfx(audio.SfxID.ItemPotion)
    return true
  else
    caster:say(player.HeroSpeech.ICantDoThat)
    return false
  end
end

-- -------------------------------------------------------------------------
-- OnSpellActionFrame: Share Potion skill — enter CURSOR_HEALOTHER targeting mode.
-- Fires at the mid-animation release frame so cursor activates after the animation plays.
-- Actual heal fires in OnCursorMonsterTarget when the player clicks an ally.
-- -------------------------------------------------------------------------

events.OnSpellActionFrame.add(function(caster, spellId, spellType, target, scrollSeed, targetX, targetY)
  if spellId ~= SHARE_POTION_ID then return end
  local self = player.self()
  if self == nil or caster.id ~= self.id then return end
  if spellType ~= 0 then return end  -- skill casts only
  caster:enterHealOtherMode()
end)

-- -------------------------------------------------------------------------
-- OnCanSelectMonsterWithCursor: allow pcursmonst to be set while in
-- CURSOR_HEALOTHER mode so the player can click on a deployed ally.
-- -------------------------------------------------------------------------

events.OnCanSelectMonsterWithCursor.add(function(cursorId)
  if cursorId == player.CursorID.CURSOR_HEALOTHER then return true end
end)

-- -------------------------------------------------------------------------
-- OnCursorMonsterTarget: apply Share Potion to a clicked ally.
-- Returns true (dismiss cursor) for any valid ally — including summoned minions —
-- regardless of potion availability. Returns nil (cursor stays active) for invalid targets.
-- -------------------------------------------------------------------------

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

-- -------------------------------------------------------------------------
-- OnItemUsed: Potion of Forgetting — reset all base stats to class starting
-- values, refund invested points, correct HP/mana drift from Black Death / shrines.
-- Works for all classes, not just Hunter.
-- The engine has already restored full HP and mana (FullRejuv effect) before this fires.
-- Identified by miscId == FullRejuv AND spellId == FORGET_POTION_ID; regular Full
-- Rejuvenation Potions have spellId == 0 (SpellID::Null) so they are ignored.
-- -------------------------------------------------------------------------

events.OnItemUsed.add(function(p, miscId, spellId)
  if miscId ~= items.ItemMiscID.FullRejuv then return end
  if spellId ~= FORGET_POTION_ID then return end
  local self = player.self()
  if self == nil or p.id ~= self.id then return end

  local startStr, startMag, startDex, startVit = p:classBaseStats()
  p:resetStats(startStr, startMag, startDex, startVit)
end)

-- -------------------------------------------------------------------------
-- OnGetMiscItemDescription: override the info box description for the Potion of Forgetting.
-- The default "restore all life and mana" line comes from its IMISC_FULLREJUV miscId.
-- We detect by spellId (stored on the item for detection purposes only).
-- -------------------------------------------------------------------------

events.OnGetMiscItemDescription.add(function(item)
  if item.miscId ~= items.ItemMiscID.FullRejuv then return nil end
  if item.name ~= "Potion of Forgetting" then return nil end
  return "Resets All Stats\nItem Lost on Game Exit"
end)

-- -------------------------------------------------------------------------
-- Potion of Forgetting: stash exclusion + session-only persistence.
-- -------------------------------------------------------------------------

function isForgetPotion(item)
  return item.miscId == items.ItemMiscID.FullRejuv and item.name == "Potion of Forgetting"
end

-- OnItemAllowedInStash: keep mod items out of the normal stash. The Potion of Forgetting must never
-- persist (the stash would carry it into another game), and Tame Scrolls must never land in a stash
-- that a non-modded / base-game session could load. (Hunters get a dedicated mod-owned scroll stash
-- later — see the phase 10 roadmap.)
events.OnItemAllowedInStash.add(function(item)
  if isForgetPotion(item) then return false end
  if item:isScrollOf(TAME_ID) then return false end
  return nil
end)

-- Every writable Item field, so a popped item can be put back byte-for-byte into its exact original
-- slot (name/iName are strings, copied separately). Lets us blank a slot for the save then refill the
-- *same* slot afterwards without moving the item (works for both inventory and belt slots).
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

-- OnBeforeSaveHero / OnAfterSaveHero: bracket the hero-file write so the Potion of Forgetting is
-- absent from what gets serialised, then restored to the LIVE inventory in its exact original slot.
-- Net live state is unchanged within the session, but the potion is never written to disk, so it cannot
-- survive into a new game regardless of how the current one ends (menu exit, quit, crash, force-close).
-- No load-time scan is needed. Applies to every class (non-Hunters may buy/use it too).
--
-- pop() clears the slot in place (no array compaction — index/position preserved) and returns a full
-- copy; we hold both the live slot reference and the copy, then write the copy back into the same slot
-- after the write. The inventory arrays are not touched between the two hooks (the save only reads them),
-- so the live reference stays valid. If the game dies between the two hooks, the on-disk save has an empty
-- slot, which RemoveEmptyInventory sanitises on the next load — so a crash mid-save corrupts nothing.
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

-- -------------------------------------------------------------------------
-- OnCustomItemRecreated: restore dynamic scroll name after pfile/delta round-trip.
-- Fires from inside RecreateItem (items.cpp) after InitializeItem resets the name.
-- item.seed and item.buff are valid at this point; name is "Tame Scroll" (base name).
-- -------------------------------------------------------------------------

events.OnCustomItemRecreated.add(function(item)
  if not item:isScrollOf(TAME_ID) then return end
  -- Non-Hunter visibility: a non-Hunter who sees one of these scrolls (e.g. dropped on the floor in MP)
  -- must see only the generic base name, never the class-specific encoded name. Leave the base name in
  -- place when the local player is not a Hunter — purely a display gate, no save/state mutation.
  local me = player.self()
  if me == nil or me.className ~= HUNTER_CLASS then return end
  local uIdx = seedGetUniqueType(item.seed)
  -- Keep the Bonded prefix + gold tier across the pfile/delta round-trip.
  local bonded = scrollIsBonded(item)
  local prefix = bonded and "Bonded" or "Tamed"
  local scrollName
  if uIdx >= 0 then
    local monsterName = monsters.getUniqueName(uIdx)
    if monsterName == nil then return end
    scrollName = prefix .. " " .. monsterName
    item.magical = 2  -- ITEM_QUALITY_UNIQUE → gold text + outline
  else
    local typeId = seedToTypeId(item.seed)
    if typeId == nil then return end
    local _, _, level = decodeDwBuff(item.buff)
    local monsterName = monsters.getNameByTypeId(typeId)
    if monsterName == nil then return end
    scrollName = prefix .. " Lvl " .. level .. " " .. monsterName
    if bonded then item.magical = 2 end  -- Bonded normal scrolls render at gold tier too
  end
  item.name  = scrollName
  item.iName = scrollName
end)

-- -------------------------------------------------------------------------
-- Speedbook: inject one entry per unique Tame Scroll name held in inventory.
-- Deduplicates by display name; count reflects how many of that name exist.
-- -------------------------------------------------------------------------

events.OnGetCustomSpeedbookScrollEntries.add(function(p)
  if not isMyPlayer(p) then return nil end
  local seen  = {}   -- name → { seed, count }
  local order = {}   -- insertion-order list of names
  p:iterateInventory(function(item)
    if not item:isScrollOf(TAME_ID) then return end
    -- Skip scrolls outside the current tier criteria: Tame scrolls carry iSkipSpeedbook and
    -- are custom-injected here, so they don't auto-hide from being made red — filter at injection.
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
    -- Tame scroll item names already carry their full "Tamed/Bonded [Lvl N] [Name]" form; use as-is so
    -- the spellbook entry matches the scroll's own item box (unique names already omit "Lvl N").
    table.insert(result, { name = name, seed = e.seed, spell = TAME_ID, count = e.count })
  end
  return result
end)

-- Speedbook: resolve a Tame scroll cast to the EXACT scroll the player selected.
-- Every Tame scroll shares the single TAME_ID, so the engine's default "first matching
-- scroll" can deploy/consume the wrong one when several distinct Tame scrolls are held.
-- selectedSeed is the seed of the speedbook entry that was clicked; return its inventory
-- slot so OnSpellActionFrame (deploy) and ConsumeScroll agree on one scroll.
events.OnResolveCustomScrollSlot.add(function(p, spellId, selectedSeed, defaultSlot)
  if not isMyPlayer(p) then return nil end
  if spellId ~= TAME_ID then return nil end
  if selectedSeed == nil or selectedSeed == 0 then return nil end

  -- Exact match: the precise scroll the player selected.
  local slot = p:findScrollSlotBySeed(selectedSeed)
  if slot ~= nil then return slot end

  -- The selected scroll is gone (e.g. recasting a same-name stack after one was consumed).
  -- Fall back to any other held scroll of the same monster type / unique index.
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

-- Block a Tame scroll cast UPFRONT (before the engine commits the cast or consumes the
-- scroll) for limits that are knowable in advance: the ally cap and deploying a second
-- copy of a unique already out. The character refuses with "I can't do that" and the
-- scroll is never consumed — the refund fallback is reserved for genuine spawn failures.
-- selectedSeed is the clicked speedbook entry's seed; 0 (e.g. hotkey cast) skips the
-- unique check here and falls back to the safety net in OnSpellActionFrame.
-- target is the cursor-targeted monster (nil when none / not a monster-aimed cast).
events.OnCanCastScroll.add(function(p, spellId, selectedSeed, target)
  if not isMyPlayer(p) then return nil end
  if spellId ~= TAME_ID then
    -- Any non-Tame scroll (e.g. an offensive scroll like Fireball) must never be cast at
    -- the caster's own ally / a friendly Hunter's pet — same misclick protection as a
    -- direct attack. The Tame scroll is exempt: it deploys a new ally and is handled below.
    if isProtectedFromOffense(p, target) then return false end
    return nil
  end

  if countDeployedAllies() >= MAX_ALLIES then
    p:say(player.HeroSpeech.ICantDoThat)
    return false
  end

  -- Determine which scroll will actually be cast so the duplicate-unique block is reliable.
  -- Normally that's the selected speedbook entry; for hotkey / unknown-selection casts
  -- (selectedSeed == 0) fall back to the first Tame scroll in inventory — the same
  -- first-match the deploy path resolves to — instead of skipping the check entirely.
  local seed = selectedSeed
  if seed == nil or seed == 0 then
    p:iterateInventory(function(item)
      if seed ~= nil and seed ~= 0 then return end
      if item:isScrollOf(TAME_ID) then seed = item.seed end
    end)
  end

  if seed ~= nil and seed ~= 0 then
    local uIdx = seedGetUniqueType(seed)
    if uIdx >= 0 and isUniqueTypeDeployed(uIdx) then
      p:say(player.HeroSpeech.ICantDoThat)
      return false
    end
    -- Tier gate (belt-and-suspenders): refuse deploying a scroll whose encoded monster is
    -- outside the current tier criteria. Backs up the inventory-red / speedbook-hide for any
    -- path that still reaches a cast. Not consumed on refusal.
    local scrollItem = p:findScrollBySeed(seed)
    if scrollItem ~= nil and not scrollPassesTierGate(p, seed, scrollItem.buff) then
      p:say(player.HeroSpeech.ICantDoThat)
      return false
    end
  end

  return true
end)

-- Block a Tame SKILL cast UPFRONT (before commit) when the cursor-targeted monster fails the
-- active tier's mlvl/category gate — the hard targeting veto, independent of the target's HP.
-- The Hunter refuses with the spoken "I can't do that"; the in-cast HP threshold still governs
-- whether a valid-category target is actually captured. target is the hovered monster (or nil).
events.OnCanCastSkill.add(function(p, spellId, target)
  if not isMyPlayer(p) then return nil end
  if spellId ~= TAME_ID then return nil end
  if target == nil then return nil end
  -- Never gate-refuse a cast aimed at a golem/minion: own ally = recall, others = no-op.
  -- (Decided from isGolem, not deployedAllies, only to AVOID a refusal — no Hunter behaviour
  --  is granted here, so the vanilla Golem barometer is unaffected.)
  if target.isGolem then return nil end

  local clvl     = p.characterLevel
  local mlvl     = target.level
  local tier     = tameTier(clvl)
  local category = categoryFromTarget(target)

  -- Diablo: deferred hard-block (mirrors the capture handler) until the Diablo sub-task.
  if category == CAT_DIABLO then
    p:say(player.HeroSpeech.ICantDoThat)
    return false
  end
  if not mlvlGateAllows(tier, category, clvl, mlvl) then
    p:say(player.HeroSpeech.ICantDoThat)
    return false
  end
  return nil  -- in-criteria: allow (HP threshold is enforced in-cast).
end)

-- Exempt Tame scrolls from Auto Refill Belt. Every Tame scroll shares the same misc id +
-- spell (TAME_ID), so the engine's belt auto-refill would redirect a belt cast to the first
-- matching scroll in inventory/belt — deploying a random tamed monster instead of the one in
-- the selected belt slot. Returning false keeps the exact selected belt slot.
events.OnCanAutoRefillBeltItem.add(function(p, item)
  if not isMyPlayer(p) then return nil end
  if item:isScrollOf(TAME_ID) then return false end
  return nil
end)

-- Speedbook: revert Scroll entries that share TAME_ID with the starting Tame skill
-- back to Scroll type after the engine's starting-skill promotion fires.
events.OnGetSpeedbookSelectionType.add(function(p, spellId, originalType, promotedType)
  if not isMyPlayer(p) then return nil end
  if spellId ~= TAME_ID then return nil end
  if originalType == "Scroll" and promotedType == "Skill" then return "Scroll" end
  return nil
end)

-- Speedbook: show "Tame+" (clvl 20+), "Tame++" (clvl 35+) or "Tame+++" (clvl 45+)
-- to reflect unlocked tame tiers.
events.OnGetSpeedbookSpellName.add(function(p, spellId, defaultName)
  if not isMyPlayer(p) then return nil end
  if spellId ~= TAME_ID then return nil end
  local tier = tameTier(p.characterLevel)
  if tier == 3 then return "Tame+++" end
  if tier == 2 then return "Tame++"  end
  if tier == 1 then return "Tame+"   end
  return nil
end)

-- -------------------------------------------------------------------------
-- OnLevelExit: auto-recall all deployed allies to the player's inventory.
-- Handles both normal level transitions and player death (WM_DIABRETOWN).
-- A full inventory keeps the ally as a "lost" recovery backup (recover at Pepin) — no floor drop.
-- -------------------------------------------------------------------------

events.OnLevelExit.add(function()
  local owner = player.self()
  for i = #deployedAllies, 1, -1 do
    local entry = deployedAllies[i]
    if entry.isMinion then
      -- Minions are not recalled (no scroll). Tell peers to despawn this one — the owner is leaving the
      -- level, so the engine won't reap it for them and it would otherwise ghost. Our own copy unloads
      -- with the level.
      broadcastRemove(entry.monster.id)
      untrackDeployedAt(i)
    else
      -- Recall ally to owner's inventory so the scroll is not lost on level exit. Refresh the backup
      -- first (capture final HP), then recall WITHOUT a floor fallback: a clean recall deletes the
      -- backup, but a full inventory keeps it as "lost" for recovery at Pepin (no floor drop).
      refreshRecoveryEntry(entry)
      if recallAllyToInventory(entry.monster, entry, owner) then
        recoveryRegistry[entry.seed] = nil
      end
      untrackDeployedAt(i)
    end
  end
  -- Announce every ally still backed up and not yet recovered ("lost" = orphaned, "lostfull" =
  -- recalled with no inventory room). "injured" is announced at death, not here.
  for seed, rec in pairs(recoveryRegistry) do
    if rec.state == "lost" or rec.state == "lostfull" then
      local line = recoveryMessageFor(seed, rec)
      if line ~= nil then message(line) end
    end
  end
  -- Drop any pending corpse-suppression / resurrect-beam entries: a monster that died on this level
  -- but whose death frame never completed (we left first) must not carry its skip into the next
  -- level, where its slot id could be reused by an unrelated monster.
  for id in pairs(corpselessDeaths) do corpselessDeaths[id] = nil end
  for id in pairs(pendingResurrectBeam) do pendingResurrectBeam[id] = nil end
end)

-- Single-player Load Game re-link. A SP "Load Game" restores a mid-dungeon level with the deployed
-- golems still live on it (the level save serialises every monster), but the Lua deployedAllies
-- tracking is session-local and not part of the save. Without this rebuild the golems reload
-- ORPHANED — no Tamed name/outline/leash/buff/kill-credit, not recallable, and their still-"lost"
-- recovery backups would let Pepin hand out duplicate scrolls. Re-bind each saved roster record (set
-- by OnLoadPlayerData) to its reloaded golem via stable monster slot id. Called from GameStart, which
-- fires AFTER StartGame has fully loaded the saved level and its monsters (and after the per-game
-- state clear below — so the rebuilt set is not then wiped). SP only: MP never persists a roster (slot
-- ids aren't comparable across clients) and its deployed allies persist via the network delta.
function relinkSavedAllies()
  if pendingAllyRoster == nil then return end
  local roster = pendingAllyRoster
  pendingAllyRoster = nil  -- consume once
  if system.isMultiplayer() then return end

  local me = player.self()
  for _, rec in ipairs(roster) do
    local m = monsters.fromId(rec.id)
    -- Re-link only a still-live golem owned by the local player (our reloaded ally). A dropped/empty
    -- slot (fromId nil) or a mismatched monster is left untracked so its "lost" recovery backup
    -- survives for Pepin rather than re-binding to the wrong monster.
    if m ~= nil and m.isGolem and (me == nil or m.ownerPlayerId == me.id) then
      local entry = {
        monster            = m,
        seed               = rec.seed,
        capturedDifficulty = rec.capturedDifficulty,
        isMinion           = rec.isMinion or nil,  -- nil for allies, matching the deploy convention
        parentId           = rec.parentId,
        base               = rec.base,
      }
      trackDeployedAlly(entry)  -- sets entry.id from the live monster
      -- Re-assert Bonded state, mirroring the redeploy path. bondedImmunity/bondedTrn were restored by
      -- OnLoadPlayerData, so the rolls are no-ops; applyBondedBonus re-asserts the immunity on the live
      -- monster (idempotent OR) and applyBondedGlow restores the aura light radius (not level-saved).
      if not entry.isMinion and isBonded(entry.seed, m.level) then
        rollBondedBonus(entry)
        rollBondedTrn(entry)
        applyBondedBonus(entry)
        applyBondedGlow(entry)
      end
    end
  end
  -- Re-derive the live share-divided buff now the full set is tracked. applyAllyBuff WRITES base+buff
  -- (it does not accumulate), so this overwrites the already-buffed saved stats with a clean value —
  -- no double buff — while leaving wounded current HP intact. Minions are skipped by applyAllyBuff and
  -- keep their saved stats; bondedImmunity/bondedTrn (restored by OnLoadPlayerData) feed back through
  -- here (AC) and the per-frame TRN hook.
  recalcAllyBuffs()
end

-- On entering a game (new game / load), remind the player of every recovery-registry backup waiting
-- at Pepin — both "lost" (orphaned) and "injured" (defeated) entries. Skip any seed that is actually
-- deployed right now (an SP mid-dungeon load re-links its golems above), so we only nag about scrolls
-- the player still has to reclaim. Runs after relinkSavedAllies so the deployed set is final.
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

-- Heal each held Tame Scroll's modData blob from its seed's save-persisted tables. The blob is NOT written
-- to the hero save (it lives only in memory / the level delta / the wire), so a save→reload leaves a held
-- scroll's item.modData empty. The full identity always survives in the seed-keyed tables + scrollOrigin
-- (restored by OnLoadPlayerData), so rebuild each held scroll's blob from blobForSeed(seed). This makes a
-- scroll that was saved/reloaded since acquisition trade/drop losslessly again — on the next drop the blob
-- is re-persisted to the delta and announced. Local Hunter only: only a Hunter ever holds a Tame Scroll,
-- and only our own inventory may be mutated.
function healHeldScrollModData()
  if TAME_ID == nil then return end
  local me = player.self()
  if me == nil or me.className ~= HUNTER_CLASS then return end
  me:iterateInventory(function(it)
    if it:isScrollOf(TAME_ID) then
      -- A starter scroll records its Original-Trainer name during character creation, but the player
      -- name does not exist yet then (CreatePlayer zeroes the struct and the name is filled in later),
      -- so it persists empty. Fill it in now from the valid local name. An empty stored name only ever
      -- comes from our own un-named creation — a scroll acquired by trade always carries its trainer's
      -- name in the blob — so claiming it for the local Hunter is safe. Done before the blob rebuild
      -- below so the corrected name is baked into the blob too.
      local o = scrollOrigin[it.seed]
      if o ~= nil and (o.name == nil or o.name == "") then o.name = me.name end
      it.modData = blobForSeed(it.seed)
    end
  end)
end

-- -------------------------------------------------------------------------
-- GameStart: reset all live, per-game session state to its empty start-of-game
-- invariant, then (single-player) re-link any deployed allies saved mid-dungeon.
--
-- The Lua runtime persists across games within a single app launch, but OnLevelExit
-- (which recalls allies and clears the per-level death sets) fires ONLY on in-game
-- level transitions — NOT when the player quits to the main menu. So quitting to the
-- menu with an ally still deployed leaves deployedAllies (and the death-FX sets)
-- populated with entries pointing at monster slots from the now-dead game. On the
-- next game those slot ids alias freshly-created monsters (e.g. the reserved golem
-- holding-cell slots), and the per-frame leash check in GameDrawComplete then snaps
-- that aliased monster onto a town tile — writing a live monster index into the
-- town's dMonster, which the town render path reads as a Towner index and crashes
-- (Towners[index] out of range).
--
-- At the start of any game no ally is deployed (allies are always in scroll form
-- between games), so clearing the live set is always correct. Clears only
-- live/transient state — NOT the save-persisted tables (allyKillCounts,
-- recoveryRegistry, bondedTrn, bondedImmunity, scrollOrigin) which OnLoadPlayerData
-- has already repopulated, nor tameScrollData/scrollCounter which OnCreatePlrItems seeds for
-- a brand-new character; all of those run before GameStart. AFTER the clear, the
-- single-player Load-Game re-link repopulates deployedAllies from the saved roster.
-- -------------------------------------------------------------------------
events.GameStart.add(function()
  deployedAllies = {}
  deployedAlliesById = {}
  remoteAllies = {}
  pendingDeploys = {}
  corpselessDeaths = {}
  pendingResurrectBeam = {}
  lastBuffFingerprint = nil
  relinkSavedAllies()
  announceRecoveryOnEntry()
  healHeldScrollModData()  -- restore full modData on held scrolls truncated by the last save→reload
end)

-- -------------------------------------------------------------------------
-- OnMonsterDeath: remove ally from tracking list if it dies in combat
-- -------------------------------------------------------------------------

events.OnMonsterDeath.add(function(monster)
  -- Capture remote-owned status BEFORE clearing the tracking below — the death visuals (corpseless vanish +
  -- resurrect beam) must fire for an ally we only OBSERVE (remoteAllies) too, not just our own.
  local remoteRec = remoteAllies[monster.id]
  -- On a peer: drop remote tracking for the dead ally, and any remote minions whose parent just died, so the
  -- per-client minion count stays correct. (No-op on the owner for its own allies, which live in
  -- deployedAllies. The dead monster's own body is reaped by death itself on every client; the owner's
  -- removeMinionsOfParent below then RM-broadcasts each orphaned minion so peers despawn those bodies too.)
  if remoteAllies[monster.id] ~= nil then remoteAllies[monster.id] = nil end
  for rid, rec in pairs(remoteAllies) do
    if rec.parentId == monster.id then remoteAllies[rid] = nil end
  end
  -- If a parent ally died, its minions cannot outlive it — despawn them silently.
  removeMinionsOfParent(monster.id)
  -- Death visuals apply to a tamed ally/minion we OWN (deployedAllies) OR merely OBSERVE (remoteAllies), so
  -- the corpseless vanish + resurrect beam look identical on every client (the death is engine-synced;
  -- OnMonsterDeath / OnMonsterCanPlaceCorpse fire on each). Record BEFORE untracking — the corpse hook fires
  -- later, after the entry is gone. Minion-ness: own from entry.isMinion, remote from a non-nil parentId.
  local entry = getDeployedAllyEntry(monster.id)
  local isTrackedAlly = entry ~= nil or remoteRec ~= nil
  local isMinion = (entry ~= nil and entry.isMinion) or (remoteRec ~= nil and remoteRec.parentId ~= nil)
  if isTrackedAlly then corpselessDeaths[monster.id] = true end
  -- A NON-minion ally death gets the resurrect-beam FX on its final death frame (own or remote-observed).
  if isTrackedAlly and not isMinion then pendingResurrectBeam[monster.id] = true end
  -- Owner-only recovery bookkeeping: the scroll backup lives only on the owner, so this runs for OUR OWN
  -- non-minion ally — mark its backup "injured" (paid, full-HP recovery) and announce it. Minions have no
  -- scroll and never recover; a remote ally's recovery is its own owner's concern.
  if entry ~= nil and not entry.isMinion and entry.seed ~= nil then
    local rec = recoveryRegistry[entry.seed]
    if rec ~= nil then
      local _, maxHp, level, dif = decodeDwBuff(rec.dwBuff)
      rec.dwBuff = encodeDwBuff(maxHp, maxHp, level, dif)  -- recovered at full HP, not its dying HP
      rec.state  = "injured"
      -- Use the full scroll name ("Tamed/Bonded [Lvl N] [Name]") so the message matches the item.
      local _, scrollName = buildScrollParams(allyToMonsterData(monster, entry), entry.seed)
      message(scrollName .. " has been defeated and can be revived at Pepin.")
    end
  end
  -- Untrack the dead entry (a minion's own death just removes it; no scroll drops).
  removeDeployedById(monster.id)
  -- Only a non-minion ally death changes the buff share; skip the recalc on unrelated deaths.
  if entry ~= nil and not entry.isMinion then
    recalcAllyBuffs()  -- survivors re-absorb the freed buff share
  end
end)

-- -------------------------------------------------------------------------
-- OnMonsterCanPlaceCorpse: tamed allies/minions vanish on death instead of leaving a corpse, and spawn the
-- resurrect-beam FX — for an ally we own OR merely observe (another Hunter's), so every client matches.
-- Keyed by the corpselessDeaths / pendingResurrectBeam sets recorded in OnMonsterDeath (the entry is already
-- untracked by the time this fires). A vanilla Golem is never recorded, so it keeps its vanilla corpse.
-- -------------------------------------------------------------------------

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

-- -------------------------------------------------------------------------
-- OnMonsterCanCompleteQuest: a tamed quest boss already cleared its quest at tame time, so
-- it must NOT re-trigger the quest (and replay the death speech) when it later dies as an ally.
-- Any golem/player-minion dying is never "the player slaying a quest boss". isGolem is stable
-- at death time, so this is independent of when our OnMonsterDeath untracking runs.
-- -------------------------------------------------------------------------

events.OnMonsterCanCompleteQuest.add(function(monster)
  if monster.isGolem then return false end
end)

-- -------------------------------------------------------------------------
-- creditAllyKill: track how many kills each OWN deployed ally has earned (Bonded progression).
-- Keyed by seed so counts survive level transitions and re-deploy. No-op for minions and for remote
-- allies (owner-tracked + CO-synced). Shared by the melee path (the engine fires OnGolemKilledMonster
-- from StartDeathFromMonster) and the missile path (the OnMonsterMissileHit handler). Assigns the
-- forward-declared local so the missile handler defined earlier can reach it.
-- -------------------------------------------------------------------------

creditAllyKill = function(ally, victim)
  local entry = getDeployedAllyEntry(ally.id)
  if entry == nil then return end
  if entry.isMinion then return end  -- minions have no seed and don't accumulate kills
  local mlvl   = ally.level
  local before = allyKillCounts[entry.seed] or 0
  local after  = before + 1
  allyKillCounts[entry.seed] = after
  local needed = mlvl * BONDED_KILLS_PER_LEVEL
  -- Detect the exact kill that crosses the Bonded threshold and promote to Bonded.
  if mlvl > 0 and before < needed and after >= needed then
    promoteToBonded(entry)  -- already re-applies the buff (incl. the new KTH), so we're done
    broadcastCombatOverride(entry)  -- Bonded changed its stats/immunity/profile (incl. trnVariant); sync to peers
    return
  end
  -- Re-sync this ally's combat override to peers on the kills that change something they render:
  --   • a KILL_TOHIT_PER increment (+1% ToHit per 10 kills) — also re-derive the buff locally, and
  --   • entering the single-kill pre-Bonded window (after == needed - 1) so peers start the flash tell.
  local resync = false
  if after % KILL_TOHIT_PER == 0 then
    applyAllyBuff(entry)  -- new ToHit
    resync = true
  end
  if mlvl > 0 and after == needed - 1 then resync = true end
  if resync then broadcastCombatOverride(entry) end
end

-- Melee kills route here too: the engine fires OnGolemKilledMonster from StartDeathFromMonster for any
-- golem-flagged attacker; creditAllyKill filters to our own deployed allies.
events.OnGolemKilledMonster.add(creditAllyKill)

-- -------------------------------------------------------------------------
-- OnGolemMinionMissileSpawn: a golem-fired spawn missile (a tamed Hork Demon's Hork Spawn) landed. The
-- engine's default spawn is suppressed on EVERY client (return false) because the minion species is not
-- level-natural; the LEVEL OWNER creates the correct species at the landing tile, attributes it to the
-- Hork's owner, and replicates it, and peers receive it over the net. Mirrors the Skeleton King flow, but
-- the spawn point comes from where the missile landed.
-- -------------------------------------------------------------------------

events.OnGolemMinionMissileSpawn.add(function(ally, species, x, y)
  if not isTamedAlly(ally.id) then return nil end  -- not one of ours → leave the engine's default spawn
  -- Spawn authority = the LEVEL OWNER (single monster-slot allocator), regardless of who owns the Hork.
  -- The minion cap is enforced HERE, owner-only and authoritatively, NOT in the Hork's fire roll: the
  -- minion count is network-timed (a peer learns of a minion only when the SP arrives), so keeping it out
  -- of the deterministic fire roll lets the missile fire in lockstep (see OnGolemChooseAction). The owner's
  -- count is authoritative, so checking it here never over-spawns even across several in-flight missiles.
  local me = player.self()
  if me ~= nil and me:isLevelOwnedByLocalClient()
     and countMinionsOfParent(ally.id) < HORK_MAX_MINIONS then
    local captured = allyCapturedDifficulty(ally)
    local minion = monsters.spawnWithDifficulty(species, captured, x, y)
    if minion ~= nil then registerSpawnedMinion(minion, ally, captured) end
  end
  return false  -- suppress the vanilla SpawnMonster on every client
end)

-- -------------------------------------------------------------------------
-- OnGetMonsterInfo: replace the base-game info block for any friendly-viewable tamed pet
-- (own or a peaceful player's) with the creature Type + live resistance/immunity lines.
-- No player kill threshold — tamed monsters reveal their resistances upfront.
-- -------------------------------------------------------------------------

-- A friendly pet's lifetime kill count for the info box: own pets from allyKillCounts (by seed), a remote
-- pet from its owner's broadcast CO profile. nil for a minion (no kill progression → no line) or a pet we
-- can't read yet (remote CO not arrived).
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
  -- §2 regular box: any friendly observer (own pet or a peaceful player's pet) sees live HP + kill count
  -- and resistances. The Name is set via OnGetMonsterDisplayName; the creature Type, base/buffed stat
  -- readout, difficulty + Original-Trainer live in the floating box. HP is live off the monster and the
  -- kill count rides the synced CO profile, so every friendly observer sees the same values.
  if not isFriendlyTamedView(monster) then return nil end

  -- Type lives ONLY in the floating box now; the regular box keeps name + HP + Kills + resistances.
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
      if has(RES.ResistMagic)     then r = r .. " Magic"     end
      if has(RES.ResistFire)      then r = r .. " Fire"      end
      if has(RES.ResistLightning) then r = r .. " Lightning" end
      table.insert(lines, r)
    end
    if hasImmune then
      local i = "Immune:"
      if has(RES.ImmuneMagic)     then i = i .. " Magic"     end
      if has(RES.ImmuneFire)      then i = i .. " Fire"      end
      if has(RES.ImmuneLightning) then i = i .. " Lightning" end
      table.insert(lines, i)
    end
  end

  return lines
end)

-- Force the healthbar resistance/immunity icons to show for our deployed allies, overriding the
-- vanilla unique-or-15-kills gate — so a Bonded-granted immunity is visible on the bar, consistent
-- with the ally infobox revealing full stats. Other monsters keep vanilla behaviour.
events.OnMonsterCanShowResistances.add(function(monster)
  if isDeployedAlly(monster.id) then return true end
end)

-- -------------------------------------------------------------------------
-- §2 Floating stat box for a hovered tamed pet (own ally/minion, or a peaceful player's).
-- This deliberately does NOT use the base-game "Floating Item Info Box" QoL toggle or its single-colour
-- item path: it is fully self-drawn here each rendered frame (GameDrawComplete), so it ALWAYS shows for a
-- friendly pet under the cursor and can colour each value independently. Outlined text means no panel
-- background is needed. Each stat reads as `base / buffed` with the BUFFED value in the blue magic-item
-- colour when it differs from base. No Name line — the regular info box carries the name. OH/ID are the
-- scroll's permanent Original Trainer (scrollOrigin / CO profile), so a traded pet still shows its true
-- tamer. Data: own pet from its deployedAllies entry (base) + the live monster (buffed); a remote pet
-- from the CO profile (base + OH name/id) + the live CO-synced monster (buffed). See §2 in the roadmap.
-- -------------------------------------------------------------------------

FBOX_LINE_H = 13
FBOX_WHITE  = render.UiFlags.ColorWhite     | render.UiFlags.Outlined
FBOX_BLUE   = render.UiFlags.ColorBlue      | render.UiFlags.Outlined
FBOX_GOLD   = render.UiFlags.ColorWhitegold | render.UiFlags.Outlined
FBOX_DIFF_NAMES = { [0] = "Normal", [1] = "Nightmare", [2] = "Hell" }
FBOX_MODE_NAMES = { [0] = "Diablo", [1] = "Hellfire" }
-- Dungeon-level → area-name ranges { upperBound, name, displayOffset }, for the "Found:" field. The shown
-- number is the captured dlvl MINUS the zone's displayOffset, matching the base-game automap: Church/
-- Catacombs/Caves/Hell show the absolute dlvl (1-16), but Nest (17-20) and Crypt (21-24) restart at 1-4 —
-- e.g. dlvl 1 -> "Church Lvl 1", 13 -> "Hell Lvl 13", 17 -> "Nest Lvl 1", 21 -> "Crypt Lvl 1". A quest
-- sub-level (setlevel) encodes as setlvlnum + NUMLEVELS (>24) in items.currentDeltaLevel(), so it reads as
-- just the quest-area name with NO "Lvl N" (recovered by subtracting NUMLEVELS). 0/nil reads "Unknown".
FBOX_AREA_ZONES = {
  { 4, "Church", 0 }, { 8, "Catacombs", 0 }, { 12, "Caves", 0 },
  { 16, "Hell", 0 }, { 20, "Nest", 16 }, { 24, "Crypt", 20 },
}
FBOX_NUM_LEVELS = 25  -- engine NUMLEVELS (diablo.h); the setlevel encode offset
-- Quest sub-level names, indexed by setlvlnum (engine QuestLevelNames in Source/levels/setmaps.cpp).
FBOX_QUEST_NAMES = {
  [1] = "Skeleton King's Lair", [2] = "Chamber of Bone", [3] = "Maze", [4] = "Poisoned Water Supply",
  [5] = "Archbishop Lazarus' Lair", [6] = "Church Arena", [7] = "Hell Arena", [8] = "Circle of Life Arena",
}
function areaLevelName(lvl)
  if lvl == nil or lvl <= 0 then return "Unknown" end
  if lvl > 24 then return FBOX_QUEST_NAMES[lvl - FBOX_NUM_LEVELS] or "Quest Area" end  -- name only, no "Lvl N"
  for _, z in ipairs(FBOX_AREA_ZONES) do
    if lvl <= z[1] then return z[2] .. " Lvl " .. (lvl - z[3]) end
  end
  return "Quest Area"
end

-- Base stats + provenance for a hovered friendly pet, or nil if it isn't one we can fully read yet
-- (e.g. a remote pet whose first CO broadcast hasn't arrived). Buffed values are read live off the monster.
function petFloatingBase(monster)
  local entry = getDeployedAllyEntry(monster.id)
  if entry ~= nil then
    local b = entry.base or {}
    -- OH = the scroll's recorded Original Trainer (its true tamer even if WE received it via trade),
    -- not necessarily us. Minions (no seed) fall back to the local Hunter inside originForSeed.
    local origin = originForSeed(entry.seed) or {}
    return {
      min = b.minDamage or 0, max = b.maxDamage or 0, toHit = b.toHit or 0,
      ac = b.armorClass or 0, hp = b.maxHp or 0,
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
      min = p.baseMinDamage or 0, max = p.baseMaxDamage or 0, toHit = p.baseToHit or 0,
      ac = p.baseArmorClass or 0, hp = p.baseMaxHp or 0,
      difficulty = rec.capturedDifficulty or 0,
      gamemode = p.gamemode or 0,   -- the owner broadcasts the pet's tamed-in gamemode over CO
      areaLevel = p.areaLevel or 0, -- the owner broadcasts the pet's tamed-in dungeon level over CO
      ohName = p.ohName or "?",   -- the owner broadcasts the pet's true origin (OH name + id) over CO
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

  -- Each row is a list of {text, colorFlags} segments. Buffed values come live off the monster.
  -- Order (top→bottom): base/buffed stat rows, then the GOLD provenance block — Found, Type, OH/ID,
  -- Version (Version last, OH/ID directly above it, Type above OH/ID). Found reads "Area Lvl N / Difficulty"
  -- (areaLevelName + captured difficulty); the gamemode is its own Version line.
  local rows = {
    fboxStatRow("Min Dmg:", d.min,   monster.minDamage),
    fboxStatRow("Max Dmg:", d.max,   monster.maxDamage),
    fboxStatRow("ToHit:",   d.toHit, monster.toHit),
    fboxStatRow("AC:",      d.ac,    monster.armorClass),
    fboxStatRow("HP:",      d.hp,    monster.maxHealth),
    { { "Found: " .. areaLevelName(d.areaLevel) .. " / "
        .. (FBOX_DIFF_NAMES[d.difficulty] or "Normal"), FBOX_GOLD } },
    { { "Type: " .. monster.monsterClass, FBOX_GOLD } },
    { { "OH: " .. d.ohName, FBOX_GOLD }, { "   ID: " .. formatOhId(d.ohId), FBOX_GOLD } },
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

-- -------------------------------------------------------------------------
-- OnGolemCanTargetMonster: restrict targets to ACTIVE monsters within the owner's engage radius.
-- Bounded by ENGAGE_RADIUS for ALL allies (melee AND ranged) so it stays consistent with
-- OnGolemCanChaseTarget, which clears the lock for any target outside that radius. Ranged allies
-- still attack from range *within* the zone (OnGolemChooseAction fires their missile at dist 3-8);
-- they must NOT lock distant targets they can never reach. A previous "ranged may target outside the
-- radius if it has LOS" exception did exactly that, producing a per-tick thrash: lock a far monster →
-- can't shoot it (beyond RANGED_MAX_DIST) → chase-vetoed (lock cleared) → re-run the full UpdateEnemy
-- scan → re-lock the same monster → repeat. That kept ranged allies perpetually searching.
-- Self-defence exception: an adjacent monster is always allowed (the ally fights back in place;
-- OnGolemCanChaseTarget still stops it from following the attacker out of the engage radius).
-- -------------------------------------------------------------------------

events.OnGolemCanTargetMonster.add(function(ally, candidate)
  if not isTamedAlly(ally.id) then return nil end
  -- Activation gate FIRST, before any position read or math. UpdateEnemy loops EVERY monster on the
  -- level and calls this hook for each, every tick an idle ally has no locked target. The vast
  -- majority of those monsters are asleep (activeForTicks == 0) — the engine's own AI does not run
  -- for them until the player makes them visible. A tamed ally should behave the same: never wake or
  -- chase a monster the player has not engaged. This single flag read rejects all sleeping monsters
  -- with zero allocation, shrinking the expensive position/LOS work below to just the handful of
  -- monsters actually awake near the player. (This is the real fix for "scanning the whole level".)
  if not candidate.isActive then return false end
  -- Cache .position into a local: each `monster.position` access allocates a fresh Point userdata
  -- (the C++ binding returns Point by value), so reading candidate.position / ally.position more
  -- than once per call multiplies GC churn across the N-monsters * A-allies * tick scan. Read each
  -- exactly once here.
  local cp = candidate.position
  local ap = ally.position
  -- Self-defence: always fight back against a monster immediately adjacent (cheap; no LOS needed).
  local adx = math.abs(cp.x - ap.x)
  local ady = math.abs(cp.y - ap.y)
  if math.max(adx, ady) <= 1 then return nil end
  -- Cheap distance gate BEFORE the expensive line-of-sight raytrace. This handler runs once per
  -- active monster per ally per tick, so raytracing every candidate would scale poorly with ally
  -- count. Reject anything outside the engage radius (or unlit) without raytracing — for melee AND
  -- ranged alike. Anchor to the ally's OWNER resolved from ownerPlayerId (works on every client; the
  -- owner may be a remote player), not the local player — so the zone is the same on owner and peers.
  local owner = allyOwner(ally)
  if owner == nil then return false end
  local op = owner.position
  local pdx = math.abs(cp.x - op.x)
  local pdy = math.abs(cp.y - op.y)
  if not candidate.isLit or math.max(pdx, pdy) > ENGAGE_RADIUS then return false end
  -- Survived the cheap gates: now pay for line of sight. Without it the ally would acquire targets
  -- through walls and then pathfind away from the player to reach them.
  if not ally:hasLineOfSightTo(candidate) then return false end
  return nil  -- active, lit, within the engage radius, clear LOS: allow
end)

-- -------------------------------------------------------------------------
-- OnGolemCanTargetGolem: pet-vs-pet combat between mutually-hostile owners.
-- Vanilla never lets player-minions fight each other. We permit it only when the two
-- pets belong to DIFFERENT players who are not both friendly (i.e. at least one has
-- toggled Hostile). The test is symmetric, so a defender's pets fight back automatically
-- even before that player toggles Hostile themselves. Uses the same arePeaceful() test as
-- the blue/red outline so the visual and combat relationships always agree. Generic: works
-- for any class's golems, not just Hunter allies (owner is read from goalVar3/ownerPlayerId).
-- -------------------------------------------------------------------------

events.OnGolemCanTargetGolem.add(function(ally, candidate)
  local a = player.get(ally.ownerPlayerId)
  local b = player.get(candidate.ownerPlayerId)
  if a == nil or b == nil then return nil end   -- unknown owner -> vanilla (no infighting)
  if a.id == b.id then return nil end           -- same owner -> never infight
  if arePeaceful(a, b) then return nil end       -- both friendly -> no fight
  return true                                    -- at least one hostile -> permit combat
end)

-- -------------------------------------------------------------------------
-- OnGolemCanChaseTarget: all allies stay within LR when chasing
-- -------------------------------------------------------------------------

events.OnGolemCanChaseTarget.add(function(ally, target)
  if not isTamedAlly(ally.id) then return nil end
  local owner = allyOwner(ally)  -- the ally's owner (own or remote), resolved from ownerPlayerId
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

-- Is one of OUR deployed allies/minions on or NEAR the straight line from (sx,sy) to (tx,ty)?
-- Used to refuse a spell target whose firing line passes a pet, so an auto-targeting bolt is
-- never fired "through" (or close past) a pet. Chain Lightning's spread bolts travel a line and
-- CheckMissileCol along it, splashing tiles ADJACENT to the rounded path — an exact on-line test
-- let a pet sitting one tile off the line still get hit (and, if it died, crash via the deferred
-- re-entrant minion cleanup). So we pad: veto if a pet is within PATH_PADDING tiles (Chebyshev)
-- of any sampled point. The target endpoint is included (catches a pet hugging the targeted
-- enemy); the source endpoint is skipped so a pet next to the cast origin doesn't veto every shot.
PATH_PADDING = 1
function ownAllyNearPath(sx, sy, tx, ty)
  local dx, dy = tx - sx, ty - sy
  local steps = math.max(math.abs(dx), math.abs(dy))
  if steps == 0 then return false end  -- target is the origin tile: nothing to sweep
  for i = 1, steps do
    local x = sx + math.floor(dx * i / steps + 0.5)
    local y = sy + math.floor(dy * i / steps + 0.5)
    for _, entry in ipairs(deployedAllies) do
      local p = entry.monster.position
      if math.abs(p.x - x) <= PATH_PADDING and math.abs(p.y - y) <= PATH_PADDING then
        return true
      end
    end
  end
  return false
end

-- -------------------------------------------------------------------------
-- OnMissileCanTargetMonster: pure TARGETING gate for auto-targeting spells (Chain Lightning
-- spread + bounces, Bone Spirit homing). Fired with the candidate monster and the missile's
-- origin tile (`source`). Returning false means "do not fire a bolt at this monster".
--   1. Never target our own allies/minions, nor a friendly other-Hunter's pet.
--   2. Beyond base game: never target a monster whose firing line passes one of our own pets —
--      if a pet is on OR within PATH_PADDING tiles of the line from the origin to the target,
--      refuse the target so the bolt is not fired through (or close past) the pet. The padding
--      covers Chain Lightning's adjacent-tile splash, which an exact on-line check missed.
-- A vanilla Golem matches neither pet test (and is not in deployedAllies), so it stays a
-- normal, fully targetable base-game monster.
-- -------------------------------------------------------------------------

events.OnMissileCanTargetMonster.add(function(monster, source)
  if isDeployedAlly(monster.id) then return false end
  if isOtherHuntersAlly(monster) then
    local me = player.self()
    local owner = player.get(monster.ownerPlayerId)
    if arePeaceful(me, owner) then return false end
  end
  local mp = monster.position
  if ownAllyNearPath(source.x, source.y, mp.x, mp.y) then return false end
end)

-- -------------------------------------------------------------------------
-- OnGolemCanSelect: cursor selection (controls hover, infobox, and click-targeting).
--   Own allies/minions   -> always selectable (share potion, recall, etc.).
--   Another Hunter's pet  -> always selectable too, in BOTH friendly and hostile cases, so the observer
--                            can hover it for its name + health bar (and, later, the friendly-only QoL
--                            floating stat infobox). Selecting it never enables an offensive action while
--                            friendly: left-click attacks and offensive casts are blocked separately by
--                            isProtectedFromOffense (which protects a friendly other-Hunter golem). When
--                            hostile, that protection lifts so it can be attacked like a normal enemy.
--                            Hostility governs only the outline colour and the floating-infobox gate.
-- -------------------------------------------------------------------------

events.OnGolemCanSelect.add(function(monster)
  if isDeployedAlly(monster.id) then return true end
  if isOtherHuntersAlly(monster) then return true end
end)

-- -------------------------------------------------------------------------
-- OnPlayerAttackMonster: block left-click attacks and offensive staff-charge casts on
-- the attacker's own allies / a friendly Hunter's pet (defense-in-depth so no path can
-- damage a protected ally). Once either side is hostile, fall through so it can be
-- attacked like a normal enemy. Shares isProtectedFromOffense with OnCanCastScroll.
-- The param is the attacking Player (shadows the `player` module — use `attacker`).
-- -------------------------------------------------------------------------

events.OnPlayerAttackMonster.add(function(attacker, monster)
  if isProtectedFromOffense(attacker, monster) then return false end
end)

-- -------------------------------------------------------------------------
-- OnGolemIdle: follow while player is moving; settle near player when stopped.
--
-- Player moving  → path directly toward player; clear stored idle spot.
-- Player stopped, ally outside ENGAGE_RADIUS → pick ONE random idle spot within
--   ENGAGE_RADIUS (stored per-entry so direction stays stable), walk there.
-- Player stopped, ally inside ENGAGE_RADIUS → stand still.
-- Active enemy target within ENGAGE_RADIUS → pursue that instead.
-- -------------------------------------------------------------------------

-- How many synced lockstep ticks an idle wander spot holds before it is re-derived. Long enough that
-- the ally actually walks toward the spot instead of re-targeting every tick.
IDLE_REPICK_TICKS = 24

-- Deterministic, cross-client-identical mix of two small non-negative integers. Arithmetic only (no
-- bitwise ops / no Lua integer-subtype assumption); operands are reduced first so the products stay
-- within float-exact range. Use to derive an AI choice from (synced tick, entity id) so every client --
-- including a late joiner -- computes the SAME value with no network traffic. (This mirrors how the
-- engine itself keeps per-monster AI RNG in sync: it reseeds each monster from the synced tick + slot
-- id every game loop -- see system.gameTick. So aiSeed needs no syncing; only our *cached/persistent*
-- decisions, made at a join-dependent tick, must be re-expressed as pure functions of the synced tick.)
function syncedHash(a, b)
  return ((a % 100003) * 374761 + (b % 100003) * 668251) % 1000003
end

events.OnGolemIdle.add(function(ally, hasTarget, enemyPos)
  if not isTamedAlly(ally.id) then return nil end
  local owner = allyOwner(ally)  -- own or remote owner, from ownerPlayerId
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
    return false  -- already close enough; stand still
  end

  -- Outside engage zone: walk to a wander spot near the owner. The offset is a PURE FUNCTION of the
  -- synced lockstep tick (system.gameTick, bucketed) + this ally's slot id -- deliberately NOT an
  -- aiRandom value cached at first-idle. aiRandom is synced per tick, but caching it fixed the spot at
  -- whatever tick THIS client first went idle; a late joiner began simulating the ally on a different
  -- tick, so each client cached a different spot (up to 2*ENGAGE_RADIUS apart) and the engine's position
  -- sync fought between them = the twitch/zap. A function of (tick-bucket, id) is identical on every
  -- client at the same tick -- so the copies agree and the sync has nothing to correct -- and it holds
  -- for IDLE_REPICK_TICKS so the spot doesn't change every tick. Point.new is unavailable in the mod
  -- sandbox, so offset a copy of owner.position (its x/y fields are writable).
  local span = 2 * ENGAGE_RADIUS + 1
  local bucket = math.floor(system.gameTick() / IDLE_REPICK_TICKS)
  local spot = owner.position
  spot.x = spot.x + (syncedHash(bucket, ally.id) % span) - ENGAGE_RADIUS
  spot.y = spot.y + (syncedHash(bucket, ally.id + 7919) % span) - ENGAGE_RADIUS
  return spot
end)

-- -------------------------------------------------------------------------
-- OnGolemChooseAction: give ranged allies a ranged attack at appropriate distance.
-- Fires before GolumAi's melee-attack / chase block, giving Lua first refusal.
-- Returning true consumes the tick; the engine skips melee/chase/idle for that ally.
-- Non-ranged allies and vanilla Golem: return nil to let the engine run normally.
-- -------------------------------------------------------------------------

RANGED_MIN_DIST = 3  -- don't fire if the enemy is 1–2 tiles away (let melee handle it)
RANGED_MAX_DIST = 8  -- max range for ranged attack

-- Avoidance casters that vanilla kites with (AiRangedAvoidance). A tamed one backs away from a
-- closing enemy toward the owner, which keeps it within leash range (ENGAGE_RADIUS).
AVOIDANCE_RANGED = {
  [monsters.AIID.Magma] = true, [monsters.AIID.Storm] = true, [monsters.AIID.Acid] = true,
  [monsters.AIID.Diablo] = true, [monsters.AIID.BoneDemon] = true,
}
KITE_MIN_DIST = 3  -- avoidance allies retreat if the enemy is closer than this

-- The C++ OnGolemChooseAction call-out forwards the ally's current target monster (or nil), not a
-- precomputed distance/LOS, so derive them here. Distance is Chebyshev between the two tiles; line
-- of sight uses the same missile-LOS check the engine would (monster:hasLineOfSightTo).
function golemTargetDistance(ally, enemy)
  if enemy == nil then return -1 end
  local ap, ep = ally.position, enemy.position
  return math.max(math.abs(ap.x - ep.x), math.abs(ap.y - ep.y))
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

events.OnGolemChooseAction.add(function(ally, enemy)
  if not isTamedAlly(ally.id) then return nil end
  if not ally.hasRangedAttack then return nil end
  if enemy == nil then return nil end
  local dist = golemTargetDistance(ally, enemy)

  -- Kite within leash: an avoidance caster whose enemy has closed inside KITE_MIN_DIST steps
  -- back toward the owner (raising distance from the enemy while staying near the player)
  -- instead of standing and firing in melee range.
  if AVOIDANCE_RANGED[ally.originalAiId] and dist < KITE_MIN_DIST then
    local owner = allyOwner(ally)
    if owner ~= nil then
      local odx = math.abs(ally.position.x - owner.position.x)
      local ody = math.abs(ally.position.y - owner.position.y)
      if math.max(odx, ody) >= 2 then  -- not already hugging the owner
        ally:walkToward(owner.position.x, owner.position.y)
        return true
      end
    end
  end

  if dist < RANGED_MIN_DIST then return nil end             -- adjacent: let engine do melee
  if not ally:hasLineOfSightTo(enemy) then return nil end   -- no line of sight: let engine chase
  if dist > RANGED_MAX_DIST then return nil end             -- too far: let engine chase
  -- Fire the monster's authentic missile (Succubus->BloodStar, Storm->lightning, Magma->rock,
  -- Counselor->cast by intelligence, Mega->Inferno, ...) instead of a generic arrow. An elemental
  -- missile's damage is resistance-scaled in OnGolemMissileDamage as it's created. Avoidance casters
  -- and Mega/Diablo/BoneDemon use the special-ranged animation; everyone else the normal ranged one.
  local mid = ally:naturalRangedMissileId()
  if SPECIAL_RANGED_AI[ally.originalAiId] then
    ally:startSpecialRangedAttack(mid)
  else
    ally:startRangedAttack(mid)
  end
  return true
end)

-- -------------------------------------------------------------------------
-- Hybrid AI: restore original AI special behaviors for tamed monsters.
-- This handler fires AFTER the ranged handler; non-nil return overrides it.
-- -------------------------------------------------------------------------

AIID = monsters.AIID

-- Charge threshold: Rhino/Gloom(Bat) need distance >= 5; Snake uses 2-3 tiles.
CHARGE_MIN_DIST = { [monsters.AIID.Rhino] = 5, [monsters.AIID.Bat] = 5, [monsters.AIID.Snake] = 2 }

SKELKING_SPAWN_MIN_DIST = 3   -- only spawn when the enemy is at least this far (matches LeoricAi)
SKELKING_MAX_MINIONS    = 3   -- cap of simultaneous skeleton minions per tamed Skeleton King
SKELKING_SPAWN_CHANCE   = 8   -- percent chance per eligible tick to spawn a minion
SKELETON_TYPE_ID        = 8   -- MT_WSKELAX (basic skeleton) — the species a tamed king raises

HORK_SPAWN_MIN_DIST = 3   -- Hork Demon fires Hork Spawn at range (matches HorkDemonAi)
HORK_MAX_MINIONS    = 3   -- cap of simultaneous Hork minions per tamed Hork Demon
HORK_SPAWN_CHANCE   = 8   -- percent chance per eligible tick to fire Hork Spawn

events.OnGolemChooseAction.add(function(ally, enemy)
  if not isTamedAlly(ally.id) then return nil end
  local aiId = ally.originalAiId
  local hasTarget = enemy ~= nil
  local dist = golemTargetDistance(ally, enemy)

  -- Skeleton King: periodically raise skeleton minions at range, up to a per-king cap. The spawn ROLL
  -- must be a PURE FUNCTION OF SYNCED STATE so the king's raise pose plays in lockstep on every client:
  -- positions are lockstep-synced, the target rides the synced menemy, and aiRandom is the synced per-tick
  -- RNG. The minion CAP is deliberately NOT in this roll -- a minion exists on the level owner at its
  -- spawn tick but on peers only once the replicating SP arrives (network-delayed), so
  -- countMinionsOfParent is unequal across clients during that window; gating the shared roll on it would
  -- diverge the king's AI control flow (phantom/missing raise poses, mismatched RNG consumption) = jitter.
  -- Creating the skeleton is single-authority on the LEVEL OWNER, which is also where the cap is enforced
  -- authoritatively (below). At cap the king still plays the harmless raise pose, like a raise that finds
  -- no free tile; peers materialise any actually-spawned skeleton from the SP message.
  if aiId == AIID.SkeletonKing then
    if hasTarget and dist >= SKELKING_SPAWN_MIN_DIST
       and monsters.aiRandom(100) < SKELKING_SPAWN_CHANCE then
      local me = player.self()
      if me ~= nil and me:isLevelOwnedByLocalClient()
         and countMinionsOfParent(ally.id) < SKELKING_MAX_MINIONS then
        -- Spawn one tile toward the enemy; spawnWithDifficulty crawls to the nearest free tile.
        local ap, ep = ally.position, enemy.position
        local sx = ap.x + (ep.x > ap.x and 1 or (ep.x < ap.x and -1 or 0))
        local sy = ap.y + (ep.y > ap.y and 1 or (ep.y < ap.y and -1 or 0))
        local captured = allyCapturedDifficulty(ally)
        local minion = monsters.spawnWithDifficulty(SKELETON_TYPE_ID, captured, sx, sy)
        if minion ~= nil then registerSpawnedMinion(minion, ally, captured) end
      end
      ally:startSpecialStand()  -- raise pose on every client; the skeleton arrives over the net on peers
      return true
    end
    return nil
  end

  -- Hork Demon: fire Hork Spawn at range. Same lockstep rule as the Skeleton King -- the missile FIRE
  -- roll is a pure function of synced state (positions, synced menemy, synced aiRandom), with NO minion
  -- cap, so the missile fires in lockstep on every client (it animates and travels deterministically).
  -- The cap is enforced authoritatively at the missile's landing, owner-only, in OnGolemMinionMissileSpawn
  -- (a network-timed minion count can't live in a deterministic roll without diverging the Hork's AI).
  -- At cap the missile still fires but lands without spawning; peers receive any spawned minion over the net.
  if aiId == AIID.HorkDemon then
    if hasTarget and dist >= HORK_SPAWN_MIN_DIST
       and monsters.aiRandom(100) < HORK_SPAWN_CHANCE then
      ally:startSpecialRangedAttack(monsters.MissileID.HorkSpawn)
      return true
    end
    return nil
  end

  -- Goat Melee (AiAvoidance): use its special melee attack at low HP, like the wild goat.
  -- Otherwise fall through to the engine's normal melee.
  if aiId == AIID.GoatMelee then
    if ally.health < ally.maxHealth * 0.5 and monsters.aiRandom(100) < 50 then
      ally:startSpecialAttack()
      return true
    end
    return nil
  end

  -- Rhino, Bat (Gloom), Snake: charge attack
  if CHARGE_MIN_DIST[aiId] then
    if hasTarget and dist >= CHARGE_MIN_DIST[aiId] and ally:hasLineOfSightTo(enemy) then
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
          -- Standing on the corpse: eat it and heal a chunk of HP
          local healAmt = math.max(1, math.floor(ally.maxHealth / 8))
          ally:setHitPoints(math.min(ally.health + healAmt, ally.maxHealth))
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

-- -------------------------------------------------------------------------
-- Stealth AI: Sneak-type (Hidden/Stalker/Unseen/Illusion Weaver) allies keep their
-- cloak. They fade out when safe and materialise to strike when an enemy closes in.
-- The gold ally outline still renders while cloaked (engine: DrawMonsterHelper hidden
-- branch), so the player can see and select them. Fires after the ranged/hybrid handlers.
-- -------------------------------------------------------------------------

SNEAK_FADE_IN_DIST = 3   -- emerge to strike when an enemy is at least this close
SNEAK_FADE_OUT_DIST = 4  -- re-cloak when the enemy is at least this far (or gone)

events.OnGolemChooseAction.add(function(ally, enemy)
  if not isTamedAlly(ally.id) then return nil end
  if ally.originalAiId ~= AIID.Sneak then return nil end
  local hasTarget = enemy ~= nil
  local dist = golemTargetDistance(ally, enemy)

  if ally.isHidden then
    -- Cloaked: only emerge when an enemy is close and in sight; otherwise stay hidden
    -- and let the default golem AI follow the player / approach the enemy.
    if hasTarget and dist <= SNEAK_FADE_IN_DIST and ally:hasLineOfSightTo(enemy) then
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
  return nil  -- enemy adjacent: let the default golem AI melee
end)

-- -------------------------------------------------------------------------
-- StoreOpened: Pepin stocks the Potion of Forgetting + restores tamed monster HP to max
-- -------------------------------------------------------------------------

events.StoreOpened.add(function(townerName)
  if townerName ~= "pepin" then return end

  -- Always keep a Potion of Forgetting in Pepin's buy list.
  -- addToHealerStock is idempotent: no-op if already present, re-adds after purchase.
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

  -- Restore post-restart scrolls (tameScrollData is empty; read from dwBuff encoding).
  -- Works for both normal and unique scrolls — typeId/uniqueTypeIdx not needed here.
  owner:iterateInventory(function(item)
    if not item:isScrollOf(TAME_ID) then return end
    if tameScrollData[item.seed] ~= nil then return end  -- already handled above
    local savedHp, maxHp, level, difficulty = decodeDwBuff(item.buff)
    if maxHp == 0 then return end  -- no valid data encoded
    if savedHp < maxHp then
      -- Re-encode with full HP, preserving difficulty.
      item.buff = encodeDwBuff(maxHp, maxHp, level, difficulty)
      healedAnyScroll = true
    end
  end)

  -- Play Pepin's healing sound if scrolls were healed but the player's own HP was
  -- already full (C++ HealPlayer() only plays the sound when the player is wounded,
  -- so we supplement it here when tame scrolls are the only thing that needed healing).
  if healedAnyScroll and owner.health >= owner.maxHealth then
    audio.playSfx(audio.SfxID.CastHealing)
  end

  -- Recovery system: reconcile buy-backs, then stock everything still recoverable.
  -- A registry seed already sitting in the player's inventory can only mean the scroll was bought
  -- back (deploy creates the entry; a clean recall/retame deletes it, and the full-inventory paths
  -- never put the scroll in inventory) — so drop that entry before re-stocking.
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
      -- Gold/unique tier (seed-unique champion/boss OR Bonded) must be stamped on the STOCK item: a
      -- vendor purchase copies the stock fields verbatim and fires none of the pickup/level-enter
      -- quality fixups, so a normal-quality stock scroll would buy back without gold lettering or the
      -- unique infobox. 2 = ITEM_QUALITY_UNIQUE; nil leaves a plain Tamed scroll at normal quality.
      local magical = (seedGetUniqueType(seed) >= 0 or isBonded(seed, data.level or 0)) and 2 or nil
      items.addToHealerStock(TAME_SCROLL_MAP, price, seed, scrollName, dwBuff, modData, magical)
    end
  end
end)

-- -------------------------------------------------------------------------
-- GameDrawComplete: leash check for all deployed allies
-- -------------------------------------------------------------------------

-- Despawn any observed remote ally whose owner has left the game. player.get returns nil for an inactive
-- (disconnected) player, so a nil owner means that Hunter is gone and its allies/minions are orphaned.
-- The engine's departed-player golem reaper only reaps MT_GOLEM-type monsters, so it never clears our
-- arbitrary-species allies — without this they linger as idle ghosts on a peer still standing on the level.
-- The owner-match guard keeps it barometer-safe (never touches our own ally or a vanilla Golem).
function reapOrphanedRemoteAllies()
  for id, rec in pairs(remoteAllies) do
    if player.get(rec.ownerId) == nil then
      local m = monsters.fromId(id)
      if m ~= nil and m.isGolem and m.ownerPlayerId == rec.ownerId then m:remove() end
      remoteAllies[id] = nil
    end
  end
end

events.GameDrawComplete.add(function()
  -- The local player owns the allies leashed below (own allies live in deployedAllies; remote allies
  -- are positioned by their owner + the engine sync, not leashed here).
  local owner = player.self()

  -- Advance the pre-Bonded flash cadence. flashOn is read by OnGetMonsterTRN to blink a
  -- one-kill-from-Bonded ally for FLASH_ON_FRAMES out of every FLASH_PERIOD_FRAMES.
  flashFrameCounter = flashFrameCounter + 1
  flashOn = (flashFrameCounter % FLASH_PERIOD_FRAMES) < FLASH_ON_FRAMES

  -- Periodically clear remote allies whose owner has left (cheap table scan; the condition changes
  -- rarely). Runs before the own-ally early-return below — a peer can observe a remote ally while
  -- owning none. No-op in single-player (remoteAllies is always empty there).
  if system.isMultiplayer() and flashFrameCounter % 30 == 0 then reapOrphanedRemoteAllies() end

  if #deployedAllies == 0 then return end

  -- Leash every deployed ally that has wandered too far back to the owner — but guard each entry
  -- against being STALE first. The Lua mod state outlives a game (it is not reloaded between games)
  -- and quit-to-menu never fires OnLevelExit, so deployedAllies can still hold entries from a PREVIOUS
  -- game whose monster slot the new game has since freed or reused. snapToPlayer writes the monster's
  -- index into dMonster; for a stale high-slot entry that index exceeds the new town's Towners vector,
  -- and the town render path (which reads town dMonster as a Towner index) crashes with
  -- "vector subscript out of range". Every live ally/minion is makeGolem'd and always reads isGolem
  -- true; a freed/reused slot has cleared flags, so isGolem is false (Monsters is a stable static
  -- array, so the pointer is always safe to read — it just reads empty data). Prune any non-golem
  -- entry so neither the leash nor the buff recalc below ever touches it again (self-heals a leftover
  -- set even if the GameStart reset did not run early enough on this client/flow). Iterate backwards
  -- so untrackDeployedAt's table.remove is index-safe.
  for i = #deployedAllies, 1, -1 do
    local entry = deployedAllies[i]
    if not entry.monster.isGolem then
      untrackDeployedAt(i)
    elseif owner ~= nil and entry.monster:distanceTo(owner) > LEASH_DISTANCE then
      entry.monster:snapToPlayer(owner)
    end
  end

  -- Recalc cadence: the share-divided buff scales off the Hunter's live stats, so a CLVL-up
  -- or a gear swap mid-deployment must re-derive every ally's buff. Poll a cheap stat fingerprint
  -- (once per frame, only while allies are deployed) and recalc only when it actually changes.
  if owner ~= nil and owner.className == HUNTER_CLASS then
    local fp = owner.characterLevel .. ":" .. owner.maxHealth .. ":" .. owner.minDamage
      .. ":" .. owner.maxDamage .. ":" .. owner.toHit .. ":" .. owner.armorClass
    if fp ~= lastBuffFingerprint then
      lastBuffFingerprint = fp
      recalcAllyBuffs()
    end
  end
end)

-- -------------------------------------------------------------------------
-- allyKillCounts + bondedImmunity + bondedTrn + recoveryRegistry persistence via dedicated mod-data
-- save slot. Stored as flat sections separated by 0 markers (0 is never a valid seed, immunity flag,
-- or TRN variant — seeds are counter*4096 with counter >= 1):
--   {killSeed,kills,..., 0, bondSeed,flag,..., 0, trnSeed,variant,..., 0, recSeed,dwBuff,state,...,
--    0, rosterCount, id,seed,capDiff,isMinion,parentId,bMin,bMax,bToHit,bAC,bMaxHp, ..., scrollCounter}
-- A trailing scrollCounter (the persistent monotonic seed counter) closes the blob.
-- The kill/bonded/TRN sections stay in lockstep (a Bonded seed has both an immunity and a TRN
-- variant). The recovery section is (seed, dwBuff, state) triples; its state field may be 0, so its
-- loop is guarded on the never-zero seed slot rather than on the value. The final section (after a
-- terminating 0) is the count-prefixed deployed-ally roster — single-player only — used to re-link
-- allies to their reloaded golems on a mid-dungeon Load Game (see relinkSavedAllies).
-- -------------------------------------------------------------------------

events.OnSavePlayerData.add(function()
  -- Only a Hunter persists mod data. Returning nothing for any other class leaves the save's
  -- mod-data vector empty, so the engine writes no out-of-band entry and the save stays
  -- byte-identical to a non-modded one (the local player is the character being saved here).
  local me = player.self()
  if me == nil or me.className ~= HUNTER_CLASS then return nil end
  local t = {}
  for seed, kills in pairs(allyKillCounts) do
    t[#t + 1] = seed
    t[#t + 1] = kills
  end
  t[#t + 1] = 0  -- section marker
  for seed, flag in pairs(bondedImmunity) do  -- Bonded defensive bonuses
    t[#t + 1] = seed
    t[#t + 1] = flag
  end
  t[#t + 1] = 0  -- section marker
  for seed, variant in pairs(bondedTrn) do  -- Bonded recolour TRN variants
    t[#t + 1] = seed
    t[#t + 1] = variant
  end
  t[#t + 1] = 0  -- section marker
  for seed, rec in pairs(recoveryRegistry) do  -- recovery backups: (seed, dwBuff, state) triples
    t[#t + 1] = seed
    t[#t + 1] = rec.dwBuff
    -- state code: 0 = "lost", 1 = "injured", 2 = "lostfull"
    t[#t + 1] = (rec.state == "injured") and 1 or (rec.state == "lostfull") and 2 or 0
  end
  -- Section 5: deployed-ally roster (SINGLE-PLAYER ONLY). The live golem<->scroll-seed link lives only
  -- in deployedAllies, which is session-local and NOT part of the level save, so without this a SP
  -- "Load Game" mid-dungeon would reload the golems orphaned. Each record carries the stable monster
  -- slot id (re-link key) + the data needed to rebuild its tracking entry: seed, capturedDifficulty,
  -- isMinion, parentId, and the un-buffed base stats (so the buff is recomputed on load, never doubled).
  -- A terminating 0 (never a valid seed) closes the recovery section, then a count, then count records.
  -- Skipped in multiplayer: slot ids aren't comparable across clients/sessions, and MP deployed allies
  -- persist via the network delta (spawnedMonsters) — MP re-link is deferred to net sync.
  t[#t + 1] = 0  -- recovery-section terminator
  if system.isMultiplayer() then
    t[#t + 1] = 0  -- roster count 0: MP persists no ally roster
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
  -- Trailing field: the persistent monotonic scroll counter, so seeds are never re-issued across
  -- sessions for this character.
  t[#t + 1] = scrollCounter
  -- The permanent per-character OHID (generated at creation; see getMyOhId).
  t[#t + 1] = getMyOhId()
  -- Final section: scroll Original-Trainer provenance, so a traded-in scroll keeps showing the ORIGINAL
  -- Hunter after a reload (the item save format can't hold the name string). count, then per entry:
  -- seed, ohId, then the byte-packed name. Appended last so it can be variable length.
  local originList = {}
  for seed, o in pairs(scrollOrigin) do originList[#originList + 1] = { seed = seed, o = o } end
  t[#t + 1] = #originList
  for _, e in ipairs(originList) do
    t[#t + 1] = e.seed
    t[#t + 1] = e.o.id or 0
    packStringToWords(t, e.o.name or "")
  end
  -- Trailing section: tamed-in gamemode per seed (count, then seed,gamemode pairs). Appended after the
  -- variable-length origin section. Only non-default (Hellfire = 1) entries need saving; a missing seed
  -- reads back as 0 (Diablo).
  local gmList = {}
  for seed, gm in pairs(scrollGamemode) do
    if gm == 1 then gmList[#gmList + 1] = seed end
  end
  t[#t + 1] = #gmList
  for _, seed in ipairs(gmList) do t[#t + 1] = seed end
  -- Trailing section: tamed-in area level per seed (count, then seed,areaLvl pairs). Any non-zero level is
  -- written; a missing seed reads back as 0 (Unknown). Pairs (not bare seeds) since the value isn't a flag.
  local alList = {}
  for seed, lvl in pairs(scrollAreaLevel) do
    if lvl and lvl > 0 then alList[#alList + 1] = seed end
  end
  t[#t + 1] = #alList
  for _, seed in ipairs(alList) do
    t[#t + 1] = seed
    t[#t + 1] = scrollAreaLevel[seed]
  end
  return t
end)

events.OnLoadPlayerData.add(function(data)
  -- Clear last character's OHID so a save missing the field can't leak it to the one loading now.
  myOhId = nil
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
  -- Section 4: recovery backups (seed, dwBuff, state) triples, after the third marker. Seeds are
  -- never 0, so the seed slot doubles as the loop guard (state may legitimately be 0 = "lost").
  -- state code: 0 = "lost", 1 = "injured", 2 = "lostfull".
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
  -- Section 5: deployed-ally roster, after the recovery-section terminator. A count, then count
  -- records of 10 fields each (see OnSavePlayerData). Stashed in pendingAllyRoster for the re-link
  -- OnLevelEnter handler (single-player). seed/parentId of 0 decode back to nil.
  pendingAllyRoster = nil
  if i <= n and data[i] == 0 then
    i = i + 1
    local count = data[i] or 0
    i = i + 1
    local roster = {}
    for _ = 1, count do
      if i + 9 > n then break end  -- truncated record; stop
      roster[#roster + 1] = {
        id                 = data[i],
        seed               = (data[i + 1] ~= 0) and data[i + 1] or nil,
        capturedDifficulty = data[i + 2],
        isMinion           = data[i + 3] == 1,
        parentId           = (data[i + 4] ~= 0) and data[i + 4] or nil,
        base = {
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
  -- Trailing field: the persistent monotonic scroll counter. Never go backwards — take the max with
  -- the current value (which may already be ahead from another character loaded earlier this launch),
  -- keeping the counter monotonic across both saves and same-launch character swaps.
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
      local seed = data[i]
      local id   = data[i + 1]
      i = i + 2
      local name
      name, i = unpackStringFromWords(data, i)
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
end)

-- -------------------------------------------------------------------------
-- Visual Polish
-- -------------------------------------------------------------------------

-- Displayed name for deployed allies (info box + health bar use the same hook).
--   Tamed/Bonded ally -> "Tamed [Name]" / "Bonded [Name]" (prefix)
--   Minion            -> "[Name] Minion" (suffix) — minions are raised by a tamed ally, not tamed directly.
-- Our OWN allies derive this live from their seed data. ANOTHER Hunter's allies show the same tamed
-- identity to EVERY observer (friendly AND hostile) so the name always reads as the tamed monster it is —
-- sourced from the owner's broadcast record (remoteAllies: parentId marks a minion, the CO profile carries
-- bonded). Hostility changes only the outline colour (see the outline hook below) and, later, whether the
-- QoL floating stat infobox is offered to a friendly observer — never the name itself.
-- Compose an ally's display name to match the scroll-name convention: a normal ally is
-- "Tamed/Bonded Lvl N [Name]"; a unique (champion/boss) ally carries NO "Lvl N" (its level lives in the
-- scroll's dwBuff, not the name). prefix already includes its trailing space.
function allyDisplayName(monster, bonded, isUnique)
  local prefix = bonded and "Bonded " or "Tamed "
  if isUnique then return prefix .. monster.name end
  return prefix .. "Lvl " .. monster.level .. " " .. monster.name
end

events.OnGetMonsterDisplayName.add(function(monster)
  local entry = getDeployedAllyEntry(monster.id)
  if entry ~= nil then
    -- Our own ally/minion. Unique-ness derives from the seed (the live monster reads back as non-unique).
    if entry.isMinion then return monster.name .. " Minion" end
    return allyDisplayName(monster, isBonded(entry.seed, monster.level), seedGetUniqueType(entry.seed) >= 0)
  end
  -- Another Hunter's ally/minion (any hostility). nil until its broadcast record arrives → default name.
  if isOtherHuntersAlly(monster) then
    local rec = remoteAllies[monster.id]
    if rec == nil then return nil end
    if rec.parentId ~= nil then return monster.name .. " Minion" end
    local bonded = rec.profile ~= nil and rec.profile.bonded
    return allyDisplayName(monster, bonded, (rec.uniqueIdx or -1) >= 0)
  end
  return nil
end)

-- Outline colors. Rendered from the local client's perspective (the observer is always MyPlayer).
ALLY_OUTLINE_COLOR         = 194  -- PAL16_YELLOW + 2; our own allies/minions
ALLY_OUTLINE_COLOR_HOVERED = 255  -- PAL16_GRAY + 15; brightest white, own ally hovered
OTHER_HUNTER_OUTLINE_COLOR = 183  -- PAL16_BLUE + 7; another Hunter's allies (friendly view only)

events.OnGetMonsterOutlineColor.add(function(monster)
  -- A monster at 0 HP (dead or mid-death-animation) never shows a selection outline. Prevents
  -- the brief ally outline flash an ally/minion shows on the frame it dies, before its death
  -- animation/corpse placement.
  if monster.hasNoLife then return nil end
  -- Our own allies/minions: always gold (white when hovered), regardless of hostility —
  -- a Hunter must always be able to pick out their own pets.
  if isDeployedAlly(monster.id) then
    local hovered = monsters.getHovered()
    if hovered ~= nil and hovered.id == monster.id then
      return ALLY_OUTLINE_COLOR_HOVERED
    end
    return ALLY_OUTLINE_COLOR
  end
  -- Another Hunter's ally: blue, but only while BOTH we and the owner are friendly.
  -- If either side is hostile, return nil so the engine's default enemy outline applies
  -- (the ally becomes a normal red-on-hover, attackable target, with a normal infobox).
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

-- Bonded recolour + pre-Bonded flash, both via the per-frame monster TRN override.
--   * A Bonded deployed ally wears the permanent recolour matching its rolled bonus (its "aura"; the
--     glow light is the other half of that aura). Always on. bondedTrn[seed] selects which one.
--   * A Tamed ally one kill from Bonded blinks the solid flash colour on the FLASH_* cadence (the
--     "about to evolve" tell). Stops once it crosses the threshold and becomes recoloured instead.
-- Every other monster (and a non-flashing pre-Bonded ally in its off-window) returns nil → the
-- engine's default TRN, so this never touches non-allies. O(1) ally lookup, like the outline handler.
events.OnGetMonsterTRN.add(function(monster)
  local entry = getDeployedAllyEntry(monster.id)
  if entry ~= nil then
    -- Our own ally: derive the tint live from its seed-keyed progression.
    -- A Bonded ally always has bondedTrn[seed] set (rolled at promotion / on redeploy), so just look it up.
    if isBonded(entry.seed, monster.level) then return BONDED_TRN_TABLE[bondedTrn[entry.seed]] end
    if flashOn and isOneKillFromBonded(entry) then return BONDED_FLASH_TRN end
    return nil
  end
  -- A remote-owned ally: the kill-derived Bonded state isn't visible on a peer, so drive the same tint
  -- from the owner's broadcast CO profile. flashOn is frame-driven locally on every client (GameDrawComplete).
  local rec = remoteAllies[monster.id]
  local prof = rec ~= nil and rec.profile or nil
  if prof == nil then return nil end
  if prof.bonded and prof.trnVariant ~= nil and prof.trnVariant > 0 then
    return BONDED_TRN_TABLE[prof.trnVariant]
  end
  if flashOn and prof.nearBonded then return BONDED_FLASH_TRN end
  return nil
end)

-- Fix-up unique tame scroll quality on level enter so floor-dropped scrolls that
-- were picked up in the previous session get their gold text on the next level load.
events.OnLevelEnter.add(function()
  local p = player.self()
  if p == nil then return end
  if p.className ~= HUNTER_CLASS then return end
  p:iterateInventory(function(item)
    if not item:isScrollOf(TAME_ID) then return end
    -- Defensive: keep scrollCounter ahead of every held scroll's counter so a freshly allocated
    -- seed can never collide with one already in inventory. scrollCounter is persisted and monotonic,
    -- so for a character's own scrolls this is a no-op; it still guards a scroll acquired from another
    -- character whose counter ran ahead (until re-stamp-on-acquire makes that case impossible too).
    local c = math.floor(item.seed / 4096)
    if c >= scrollCounter then scrollCounter = c + 1 end
    if scrollIsGoldTier(item) then
      item.magical = 2  -- ITEM_QUALITY_UNIQUE → gold text + outline (unique champions/bosses + Bonded scrolls)
    end
    -- Announce the full identity blob of every scroll we're carrying, so peers already have it cached if we
    -- trade one away (and so a peer that just joined gets it). Held scrolls => no delta level. No-op in SP.
    broadcastScrollData(item.seed)
  end)
end)

-- Tame Scroll class restriction: only Hunters may pick up (and therefore hold) Tame Scrolls.
-- Blocks non-Hunters from grabbing them off the floor; Hunters can still trade scrolls to one
-- another via the normal drop/pickup flow (both parties are Hunters, so neither side is blocked).
events.OnPlayerCanPickUpItem.add(function(p, item)
  if item:isScrollOf(TAME_ID) and p.className ~= HUNTER_CLASS then
    return false
  end
end)

-- Tame Scrolls are never sellable to a vendor — they are only obtained by taming or bought back from
-- Pepin's recovery list. Veto the vendor's buy-from-player check (covers Adria/Griswold, both store UIs).
events.OnVendorWillBuyItem.add(function(item)
  if TAME_ID ~= nil and item:isScrollOf(TAME_ID) then return false end
end)

-- Re-stamp every picked-up Tame Scroll into THIS character's own monotonic seed space, so two
-- players' scrolls can never share a seed (collision-proof trading). The scroll is self-describing:
-- its progression (kills/immunity/TRN) rides in modData, so re-keying is lossless — the picked-up
-- ally keeps its full identity under the fresh seed. For the owner's OWN dropped-and-repicked scroll
-- this is observationally a no-op (same monster, same data, new seed under the hood). Also (re)applies
-- the gold quality the moment the scroll enters inventory.
events.OnItemPickedUp.add(function(p, floorItem)
  -- Local player only: AutoGetItem runs for remote players too (on every client), and re-stamping
  -- must mutate only OUR own inventory item, never a remote player's.
  local me = player.self()
  if me == nil or p.id ~= me.id then return end
  if p.className ~= HUNTER_CLASS then return end
  if not floorItem:isScrollOf(TAME_ID) then return end
  local oldSeed = floorItem.seed

  -- Locate the LIVE copy of the scroll we just picked up. Match on seed + dwBuff + modData rather
  -- than seed alone: if the incoming seed momentarily collides with a scroll we already hold (two
  -- characters' counters can both be low), this re-stamps the one we just acquired, never the
  -- existing one. If two truly-identical scrolls coexist, either is interchangeable.
  local invItem = nil
  p:iterateInventory(function(it)
    if invItem ~= nil then return end
    if it:isScrollOf(TAME_ID) and it.seed == oldSeed
        and it.buff == floorItem.buff and it.modData == floorItem.modData then
      invItem = it
    end
  end)
  if invItem == nil then return end

  -- Source the scroll's full self-describing identity. Prefer the item's own blob (set for a floor item
  -- restored from the level delta — i.e. a scroll whose dropper has left the game); else the live announce
  -- cache (a trade where the dropper is present, since the wire carries no blob on the floor item); else our
  -- own tables (re-picking up a scroll we already owned). decodeBlob is authoritative per item.
  local blob = invItem.modData
  if blob == nil or blob == "" then blob = receivedBlobs[oldSeed] end
  if blob == nil or blob == "" then blob = blobForSeed(oldSeed) end
  local kills, immIdx, trnVar, gamemode, areaLvl, ohId, ohName = decodeBlob(blob)
  local immVal = IMMUNITY_BY_INDEX[immIdx]

  -- Fresh seed in our own counter space, preserving the scroll's type / unique identity.
  local uIdx = seedGetUniqueType(oldSeed)
  local newSeed = (uIdx >= 0) and allocSeed(nil, uIdx) or allocSeed(seedToTypeId(oldSeed), nil)

  -- The Original Trainer rides INSIDE the blob, so the true tamer carries with the scroll however it
  -- arrived (delta or live announce). Fall back to any seed-keyed cache only if the blob had no name.
  local origin = (ohName ~= nil and ohName ~= "") and { name = ohName, id = ohId } or scrollOrigin[oldSeed]

  invItem.seed = newSeed
  if kills  > 0    then allyKillCounts[newSeed] = kills  end
  if immVal ~= nil then bondedImmunity[newSeed] = immVal end
  if trnVar > 0    then bondedTrn[newSeed]      = trnVar end
  if origin ~= nil then scrollOrigin[newSeed]   = origin end
  if gamemode == 1 then scrollGamemode[newSeed] = 1      end  -- carry the tamed-in gamemode (Diablo = default 0)
  if areaLvl  > 0    then scrollAreaLevel[newSeed] = areaLvl end  -- carry the tamed-in area level
  tameScrollData[newSeed] = nil  -- rebuilt from seed+dwBuff on cast
  invItem.modData = blobForSeed(newSeed)  -- re-key the held blob to the fresh seed (a live-trade item arrived empty)

  -- Drop the old seed's tables only if no OTHER held scroll still uses it, so a transient seed
  -- collision never deletes a different scroll's data.
  if p:findScrollBySeed(oldSeed) == nil then
    allyKillCounts[oldSeed] = nil
    bondedImmunity[oldSeed] = nil
    bondedTrn[oldSeed]      = nil
    scrollOrigin[oldSeed]   = nil
    scrollGamemode[oldSeed] = nil
    scrollAreaLevel[oldSeed] = nil
    tameScrollData[oldSeed] = nil
    receivedBlobs[oldSeed]  = nil
  end
  -- The floor item is gone now; drop its blob from the current level's delta so the per-level store stays
  -- bounded (a stale entry is harmless but pointless once the item is picked up).
  items.setItemDeltaModData(items.currentDeltaLevel(), oldSeed, "")

  if scrollIsGoldTier(invItem) then invItem.magical = 2 end  -- gold text + outline (unique/Bonded)

  -- Announce this scroll's identity under its fresh seed so peers can show the true tamer / restore it on a
  -- trade if we later pass it onward (the re-stamped seed is new to them). Held now, so no delta level.
  broadcastScrollData(newSeed)
end)

-- A manually dropped Tame Scroll — the trade mechanism (drop on the floor, another Hunter picks it up). The
-- floor item carries no blob over the wire, so persist the scroll's identity with the floor item in the
-- level delta + announce it live, so the picker (present now, or a late joiner after we leave) restores it.
-- dropTameScroll / the refund path already do this inline; this catches a player dragging a scroll out by
-- hand. Local Hunter only (the hook fires for the local dropper).
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

-- Hijack the unique item info popup when hovering a unique tame scroll.
-- Populates the custom slot with tamed monster stats and returns true so DrawUniqueInfo
-- renders our content instead of UniqueItems[_iUid] (which would show The Butcher's Cleaver).
events.OnPrepareUniqueInfoBox.add(function(item)
  if not item:isScrollOf(TAME_ID) then return end
  local uIdx   = seedGetUniqueType(item.seed)
  local bonded = scrollIsBonded(item)
  -- This hook fires for any scroll rendered at unique/gold tier: seed-unique champions/bosses AND
  -- Bonded normal-monster scrolls. A non-unique, non-Bonded scroll is not gold — leave it
  -- to the engine's default item box.
  if uIdx < 0 and not bonded then return end

  local savedHp, maxHp, level, difficulty = decodeDwBuff(item.buff)
  if maxHp == 0 then maxHp = savedHp end
  if savedHp == 0 then savedHp = maxHp end
  local diffNames = { [0] = "Normal", [1] = "Nightmare", [2] = "Hell" }
  local diff   = diffNames[difficulty] or "Normal"
  local kills  = allyKillCounts[item.seed] or 0
  local prefix = bonded and "Bonded " or "Tamed "

  local monsterName, tier
  if uIdx >= 0 then
    monsterName = monsters.getUniqueName(uIdx) or "Unknown"
    tier = BOSS_NAMES[monsterName] and "Boss" or "Champion"
  else
    monsterName = monsters.getNameByTypeId(seedToTypeId(item.seed)) or "Unknown"
    tier = "Bonded"  -- a Bonded normal monster has no champion/boss tier of its own
  end

  items.setCustomUniqueBox(prefix .. monsterName, {
    tier .. " (" .. diff .. ")",
    "Level: " .. level,
    "HP: " .. savedHp .. " / " .. maxHp,
    "Kills: " .. kills,
  })
  return true
end)
