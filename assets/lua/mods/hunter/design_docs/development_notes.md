# Development Notes — Active Task

> **The ONE live doc.** Exactly one task in flight at a time. When it ships, graduate it (hook rows →
> `lua_api_reference.md`, bindings → `lua_api_reference.md`, engine code+why → `cpp_changes/`, dated
> entry → `HISTORY.md`, subsystem reasoning → `net_sync.md`) and **delete it from here.** See
> `README.md`.

---

## `monster.index` / `player.index` replace the slot meaning of `.id` (BUILT 2026-11-03, awaiting compile + two-client check)

`monster.id` / `player.id` are back to upstream's meaning (address-derived; the two never collide, which
upstream's Floating Numbers mod relies on, and they differ per client). The slot number we relied on is
now `.index`, the same on every client. `init.lua`: all 143 uses on engine monsters/players moved to
`.index`; the 15 left are the mod's own records (`entry.id`, `rec.id`, Original-Trainer `o.id` /
`origin.id`, `deployedAllies[i].id`). **Recompile:** `lua/modules/monsters.cpp`, `lua/modules/player.cpp`;
copy `init.lua`. **Two-client check:** deploy, fight, recall and re-deploy a pet; a peer sees it and its
infobox; pet death; Pepin recovery; minions (Skeleton King / Hork); the town follower; a level change
with pets out. Any identity mix-up shows as a pet not tracked, duplicated or not despawned.

---

## Spell API matches upstream: `spells.addSpellDataFromTsv` (BUILT 2026-11-03, awaiting compile + check)

`spells.registerSpell(name, path, icon)` is replaced by upstream's shape: `spells.addSpellDataFromTsv(path)`,
where each row's `id` column is the spell name. The Hunter's three spells now live in one
`txtdata/spells/spelldat_hunter.tsv` (ids `hunter:tame` / `hunter:sharepotion` / `hunter:forgetpotion`; the
three single-spell TSVs are deleted). Icons are set in `SpellsAssigned` via `spells.setSpellIcon`. A
duplicate id or too many mod spells is now a fatal load error. **Recompile:** `tables/spelldat.cpp/.h`,
`lua/modules/spells.cpp`, `msg.cpp` (comment only), `lua/modules/items.cpp` (`addToHealerStock` now
takes `magical` before `modData`; the Hunter's Pepin buy-back call is updated to match). Refresh `events.lua`; copy `init.lua` **and the new
TSV** (and delete the three old TSVs from the installed mod). **Check:** a Hunter starts with Tame;
Tame / Share Potion show their Golem / Heal Other icons; Forget Potion still works; a Pepin buy-back
scroll keeps its gold/unique look and its data.

---

## Class mechanics as class flags + `OnGetPlayerClassFlags` (BUILT 2026-11-03, awaiting compile + check)

Ten new `PlayerClassFlag` values replace the hardcoded `HeroClass` checks for shieldless block, armor pierce,
stagger resistance, the unarmed floor, the Monk armor bonus, bow damage / arrow speed and cleave; the six
vanilla `attributes.tsv` files carry them (vanilla behaviour unchanged). Every flag check goes through
`Player::getClassFlags()`, which fires `OnGetPlayerClassFlags`. Eleven hooks are gone (`OnPlayerHasCriticalStrike`,
`…IronSkin`, `…NaturalResistance`, `OnGetBowDamageMod`, `OnGetArrowVelocityBonus`, `OnPlayerCanBlockWithoutShield`,
`OnGetArmorLevelBonus`, `OnPlayerHasArmorPierce`, `OnPlayerCanCleave`, `OnGetHitRecoveryThreshold`,
`OnGetUnarmedDamageFloor`); the Hunter adds archetype flags in one handler. One intended change: a
Rogue-archetype Hunter now also gets the Rogue's speed bonus on elemental arrows (and Diablo's −1 there),
which the old hooks missed. **Recompile:** `tables/playerdat.cpp/.hpp`, `player.cpp/.h`, `items.cpp`,
`missiles.cpp`, `inv.cpp`, `objects.cpp`, `lua/lua_event.cpp/.hpp`, `lua/modules/player.cpp`; refresh
`events.lua` and the six vanilla class `attributes.tsv`; copy `init.lua`. **Check:** vanilla classes —
Monk staff block + unarmed damage, Barbarian cleave + stagger, Bard dual-sword cleave, Rogue arrow speed;
Hunter — each archetype's crit / cleave / block / AC / arrow behaviour as before, and a peer joining a
Hunter with archetypes met isn't refused (derived stats must match on both clients).

---

## Hunter items from TSV; custom-items framework + `skipSpeedbook` removed (BUILT 2026-11-03, awaiting compile + check)

The Tame Scroll and Potion of Forgetting are rows in `txtdata/items/itemdat_hunter.tsv`, loaded with
upstream's `items.addItemDataFromTsv(path, TAME_SCROLL_MAP)` (mapping ids 90001/90002 unchanged; spell
column `hunter:tame` / `hunter:forgetpotion`; equip type is now `Unequippable` like vanilla scrolls). Engine:
the Lua-table item loaders, `registerCursorGraphic` + custom cursor sprites, `GetItemAnimType`, and
`iSkipSpeedbook` are gone (those lines match `master` again). The generic Tame speedbook icon is hidden by
`OnShouldHideSpeedbookSpell`, which now also fires in `DoSpeedBook`. Side effect: the Tame bit is in the
scroll mask, so a readied Tame scroll is no longer cleared on inventory recalculation. **Recompile:**
`cursor.cpp/.h`, `items.cpp/.h`, `inv.cpp`, `qol/stash.cpp`, `qol/itemlabels.cpp`, `qol/visual_store.cpp`,
`tables/itemdat.h`, `player.cpp`, `panels/spell_list.cpp`, `lua/modules/items.cpp`; copy `init.lua` **and the
new TSV**. **Check:** Tame scrolls drop / buy back / deploy as before; the speedbook shows only the named Tame
entries (no plain "Tame Scroll" icon); opening the speedbook puts the mouse on the readied spell; Potion of
Forgetting still works.

---

## Scroll-seed validation + follower session reset (BUILT 2026-11-03, awaiting compile + playtest)

The two High bugs in `bugs.md` ("Hunter's Bow" scrolls; town follower stall). **Recompile:**
`lua/lua_event.cpp`, `lua/modules/player.cpp`; copy `init.lua`. **Playtest:** at fastest speed, right-click
several Tame Scrolls rapidly, with a non-scroll item in an earlier inventory slot. Each cast must spawn its
own monster and consume exactly that scroll. Then quit, rejoin, and check the town follower appears straight
away.

---

## Monster Nickname (roadmap §5) — engine text prompt BUILT + user-checked 2026-11-03; Lua BUILT, awaiting playtest

**Lua (built, init.lua only — copy init.lua):** `scrollNickname[seed]` (saved trailing section, blob field 8,
CO field 29 before the free-form `ohName`); Cain option via `selectedTameScroll`; one name formatter
`tameDisplayName` for scroll creation/recall (`buildScrollParams`), restamp and pet names; `Species:` line in
the floating box (always), the gold unique box and the regular scroll hover (nicknamed only). CO size: +≤17 B
on the ~157 B nominal + ≤32 B ohName budget — still well under 255 B. Full mechanics: `comments.md`
"Monster Nickname".

**Playtest watch items:**
1. Cain shows "Nickname Monster" only for a Hunter with a Tame Scroll selected; a non-Hunter / no selection sees
   vanilla Cain.
2. Name it "Doggo" → scroll reads `Doggo Lvl N Tamed/Bonded` in inventory, speedbook and the Hunters Tome; hover
   shows `Species:`; a gold scroll's unique box titles `Doggo Bonded` with a `Species:` line.
3. Invalid text (17+ chars, `|`, symbols) → message, name unchanged; blank → nickname cleared.
4. Deploy it / town follower → pet name `Doggo Lvl N ...`; floating box `Species:` line; recall → scroll keeps
   the nickname.
5. Save/load, deposit in the Tome on hero A and withdraw on hero B, trade to another Hunter → nickname intact.
6. MP: the other client sees the nickname on the pet (CO) and on a traded scroll.

**Decisions (user, 2026-11-03):** Cain gets a "Nickname Monster" option for **Hunters only**, shown only when a
Tame Scroll is selected in the speedbook (the follower's selection shortcut — no shop-style list); select it →
type a nickname. Bottom infobox is full at 5 lines, so the species moves to the floating box as a
`Species: Fire Drake` line. Name rules enforced in Lua (proposed ≤16 chars; letters, digits, space, `'`, `-`).
Display + persistence are pure Lua (the nickname rides the scroll blob → trades / Tome / saves / MP).

**Engine (built):** the only missing piece was text entry. New generic `system.promptText(prompt, maxLength,
onFinish)` — `Source/control/control_text_prompt.*` (gold-drop box art + layout, centred, `TextInputState`),
wired like the gold-withdraw dialog: `PressKey` (Enter/keys), text-input events, `PressEscKey`, draw in
`scrollrt.cpp`; discarded on mod reload / Lua shutdown. Everything is gated on `IsTextPromptOpen()`, which is
never true without a mod. **Compile check:** gold drop / gold withdraw / chat still work; then a Lua test
prompt opens, types, Enter/Escape both return.

---

## Town-following ally (roadmap §4) — engine "monsters in town" BUILT + user-checked (town unchanged) 2026-11-02; Lua BUILT, awaiting playtest

**Lua (built):** follower = real spawned ally tracked in `deployedAllies` with `isTownFollower`; selected Tame
Scroll in the speedbook drives it (new read-only bindings `player.readySpellId` / `readySpellType` /
`selectedScrollSeed` in `Source/lua/modules/player.cpp` — binding only, no engine change). Never consumed /
backed up / recalled (despawned on level exit); docile via the town rule in the target hooks; trails within 3
tiles, snaps back past 6; MP via the normal DR/SP/RM/RQ + its own `pendingFollower`. Full mechanics:
`comments.md` "Town follower". **Recompile:** `lua/modules/player.cpp` (+ the engine files above); copy init.lua.

**Playtest watch items:**
1. Select a Tame Scroll in town → its monster appears on a free tile near you, trails 1–3 tiles behind, never
   inside buildings; switch scrolls → it swaps; select anything else → it disappears.
2. Hover it: name, regular + floating infobox (Bonded look/recolour intact).
3. Docile: never attacks, can't be attacked; clicking it does nothing; towners still talk normally.
4. Get it stuck behind scenery → it snaps back near you.
5. Leave town (stairs / portal / town portal) → it's gone, the scroll is still in inventory exactly once, no
   Pepin "lost" message; come back → it reappears.
6. MP (two clients in town): both see each follower move; the non-level-owner's follower spawns too; a player
   entering town sees existing followers; leaving / deselecting removes it on both.
7. SP: save in town, load → no duplicate scroll, follower respawns from the selection.

**Approach (user):** a real spawned monster (not visual-only), full MP, smallest engine footprint. The engine
never expected monsters in town, so the generic engine part is "allow monsters to exist in town" — likely its
own upstream PR.

**Town gotchas found (verified in code):**
- Towners occupy the town's `dMonster` grid with their own indices (towner `i` → `i + 1`, cow extra tiles
  `-(i + 1)`), and every town reader of `dMonster` / `pcursmonst` treated the index as `Towners[]`.
- `GameLogic` never ran `ProcessMonsters()` in town (only `ProcessTowners()`).
- Town has no reserved golem slots (`InitGolems` is dungeon-only; `InitLevelMonsters` zeroes the count for
  every level), but `DeleteMonsterList` only compacted from index 4.
- Fine as-is: runtime monster GFX load (`EnsureMonsterType`), `sync_all_monsters` / `OnSyncData` (no town
  filter), the high-slot spawn path, the `CMD_TALKXY` receiver (validates `townerIdx < GetNumTowners()`), town
  not saving monsters, town skipping monster damage/spell commands (follower never fights).

**Engine edits (each inert in vanilla town, where `ActiveMonsterCount == 0`):**
- `towners.h/.cpp`: `IsTownerIndex(int)` — in town, index < towner count.
- `scrollrt.cpp` `DrawMonsterHelper`; `cursor.cpp` pixel select, `TrySelectTowner` (towners only),
  `TrySelectMonster` (skip towners), town tile-select also tries monsters; `control_infobox.cpp` hover text;
  `plrctrls.cpp` `Interact` — all use `IsTownerIndex` instead of "is town".
- `diablo.cpp` `GameLogic`: in town, `ProcessMonsters()` when `ActiveMonsterCount > 0`.
- `monster.cpp` `DeleteMonsterList`: in town, compact from index 0.

**Compile check (before the Lua):** vanilla town unchanged — towner drawing, hover outline/name, click and
gamepad talk, cows. Pre-existing clang-format issues in `monster.cpp` / `cursor.cpp` (old hook comments /
include order) are not from this change.

---

## Mod-registered stashes + Tame Tome (engine BUILT + user-verified vanilla-stash-safe 2026-11-02; Tome Lua BUILT, awaiting playtest)

**Tome Lua (built, init.lua only — copy init.lua):** `stash.register("hunters_tome", {pages=4, gold=false})`;
"Hunters Tome" option on Gillian (hidden for non-Hunters; placed after her first option via a fix to
upstream's dialog-option placement in `stores.cpp`, which put mod options directly under "Would you like to:"); Tame Scrolls only, never gamemode-locked ones;
withdrawals re-keyed via the shared `rekeyAcquiredScroll` (factored out of `OnItemPickedUp`) when the Tome
closes (snapshot at open + `stash.activeName()` transition in `GameTick`; also on `OnBeforeSaveHero`); no
deploys while open; during the session a scroll's own blob wins over this hero's tables (kills / Bonded,
gamemode lock, drop blob). Edge case "close with a rejected item and no room" deliberately left as vanilla's
(user). Full mechanics: `comments.md` "Tame Tome".

**Tome playtest watch items:**
1. Hunter sees "Hunters Tome" at Gillian, below "Access Storage", with "Talk to Gillian" still the default
   selection; a non-Hunter's menu is exactly vanilla; "Access Storage" still opens the normal stash.
2. Tome: 4 pages, no gold shown, gold / non-scroll items refused, Tame Scrolls accepted (drag, shift-click,
   ctrl-click), a gamemode-locked scroll refused even by ctrl-click.
3. Deposit on hero A (incl. a Bonded and a unique/Diablo scroll) → save → hero B withdraws: names, gold tier,
   info-box kills, Bonded state, Original Trainer, floating box all intact, and B's own scrolls unaffected
   (seed collisions are expected and must not mix data). B deploys it after closing the Tome.
4. Withdraw then close the Tome with the scroll on the cursor (it drops to the floor) → pick it up: intact. In
   MP the other client sees the right identity.
5. Deploy attempt while the Tome is open → "I can't do that".
6. SP: deposit, quit without saving → the scroll is back in inventory and not in the Tome (no duplication).
7. `hunters_tome.sv` / `.hsv` exist separately; `stash.sv` never contains a Tame Scroll.
8. Known cosmetic: the panel art still shows the gold box + withdraw coin button (inert; amount hidden).

**Split (user):** engine first — expose just enough that a mod fully owns its own stash, file name
included — then the Tame Tome Lua logic separately.

**As built (engine, no new hooks):** `StashStruct` gained `pageCount` (default 100) + `allowsGold`
(default true); `GetActiveStash()` (player stash unless a mod stash is open) replaces `Stash` on every
window path; Gillian's "Access Storage" and mod stashes share `OpenStash()`; `CloseStash()` resets to the
player stash. Registry + `Lua*` functions in `qol/stash.cpp`; `LoadStash`/`SaveStash` refactored onto
`LoadStashData`/`SaveStashData(StashStruct&, …)` (vanilla bytes unchanged) + `LuaLoadModStash` /
`LuaSaveModStash` (`loadsave.cpp`, adds the `sp/mpstashmoddata` entry); `<name>.<ext>` path + reader/writer
in `pfile.cpp`; `sfile_write_stash()` writes dirty mod stashes first; `LoadStash()` unloads them so they
re-read from disk (same save rules as the player stash — SP only on save game, MP also on quit/autosave).
Lua: `devilutionx.stash` → `register(name, {pages, gold})`, `open(name)`, `activeName()`.
Name rules: `[A-Za-z0-9_-]`, ≤32 chars, refuses `stash*`, `single_`, `multi_`, `spawn_`, `share_`, `demo_`.
**Recompile:** `qol/stash.*`, `loadsave.*`, `pfile.*`, `inv.cpp`, `stores.cpp`, `diablo.cpp`,
`controls/game_controls.cpp`, `controls/plrctrls.cpp`, `control/control_infobox.cpp`, `items.cpp`,
`objects.cpp`, `lua/lua_global.cpp`, new `lua/modules/stash.*` (+ CMakeLists); refresh `events.lua`.
**Engine watch items (no Tome needed):** Gillian's stash works exactly as before (paste, ctrl-transfer,
pages, 10-page jumps, gold deposit/withdraw, identify/repair on stash items, gamepad); a test mod stash
opens, holds items across save/load, honours its page count, shows no gold when `gold = false`, and never
touches `stash.sv`. Known edge (same class as vanilla's): closing a stash while holding an item with no
floor/inventory/belt room auto-places it into the open stash; a stash that rejects the item hits vanilla's
"No room for item" fatal.

**Original design notes below** (still the reference for the Tome Lua phase).

**Goal:** a generic engine feature letting a Lua mod register its own stash (own save file, page limit,
gold on/off, item filter), opened through the vanilla stash window. The Tame Tome is the first user.
**Constraint (user):** as few new hooks as possible — expose engine *primitives*, no bloat. Likely its own
upstream PR ("Lua: mod-registered stashes").

**Tame Tome decisions (user, 2026-11-02):** opened from **Gillian's talk menu** via upstream's existing
`towners.addDialogOption(townerName, getLabel, onSelect)` (`getLabel` returns "" for non-Hunters → hidden;
no new hook). ~4 pages, no gold, Tame Scrolls only, zero data loss. Vanilla 10×10 grid + panel art kept
(an 8×8 grid would need new art/layout). Book / bookstand in town = possible later cosmetic shortcut onto
the same stash, not now.

### What the engine has today (surveyed)
- One global `StashStruct Stash` (`qol/stash.h`) — `stashGrids` (page → 10×10), `stashList`, `gold`,
  `dirty`, current `page`. Page cap = file-local `CountStashPages = 100` (`qol/stash.cpp`).
- The whole window (`qol/stash.cpp` draw / cut / paste / ctrl-transfer / buttons / gold withdraw) plus
  page nav (`diablo.cpp`, `controls/game_controls.cpp`), gamepad grid nav (`controls/plrctrls.cpp`),
  stash-item identify/repair/recharge/oil (`diablo.cpp` ~2856), and the infobox (`control_infobox.cpp`)
  read the global directly.
- Vanilla-only consumers that must ALWAYS mean the vanilla stash: shop gold (`stores.cpp`
  `TotalPlayerGold`, cost deduction; `qol/visual_store.cpp`), `LoadStash` / `SaveStash` (`loadsave.cpp`),
  `sfile_write_stash` (`pfile.cpp`).
- Opened only by Gillian (`stores.cpp` ~2032: `IsStashOpen = true; Stash.RefreshItemStatFlags()`);
  closed only by `CloseStash()` (`inv.cpp`).
- Saved by `sfile_write_stash()` when `dirty` — on quit (`init.cpp`, `diablo.cpp`), save game
  (`loadsave.cpp`) and the **periodic autosave** (`pfile.cpp` ~846), which can fire while the window is open.
- File: `stash.<ext>` archive, entry `spstashitems` / `mpstashitems`; format = version, gold, pages+grids,
  items (`SaveItem` — **`modData` is not written**), current page.
- `StashStruct::RemoveStashItem` and `RefreshItemStatFlags` reference the global `Stash` instead of `this`.

### Proposed design — "active stash" accessor (no new hooks)
**Rejected: swapping a mod stash into the global `Stash` while open.** The periodic autosave can fire
mid-swap and write mod items into `stash.sv` (the exact failure the Tome exists to prevent); it also
leaves vanilla consumers reading the wrong container across frames.

**Engine:**
1. `StashStruct` gains per-container settings with vanilla defaults: `maxPages` (100), `allowsGold`
   (true). `SetPage` / `NextPage` / `PreviousPage` / `AutoPlaceItemInStash` use `maxPages` instead of
   `CountStashPages`; `RemoveStashItem` / `RefreshItemStatFlags` use `this`.
2. `StashStruct &GetActiveStash()` — returns the vanilla `Stash` unless a mod stash is open. Every
   window-side reference above switches from `Stash` to `GetActiveStash()`; vanilla-only consumers keep
   `Stash`. With no mod stash open the accessor returns `Stash`, so behaviour is byte-identical.
3. `allowsGold == false` → the window skips the gold text and the withdraw button (container setting,
   not mod logic).
4. A small registry of mod stashes (name → `StashStruct` + loaded flag). `LoadStash` / `SaveStash`
   become parameterised by (container, archive path, entry name); the vanilla call sites pass the vanilla
   stash and today's names, so vanilla save bytes are unchanged. A mod stash saves to `<name>.<ext>`
   (same extension rules as `stash`), entries `sp<name>` / `mp<name>`, loaded on first open.
5. **`modData`:** a mod stash file gets a second entry with each item's blob (count + length-prefixed
   strings, in `stashList` order). The vanilla stash format is untouched.
6. `CloseStash()` saves the open mod stash if dirty, then resets the active stash to vanilla.
   `sfile_write_stash()` also writes any dirty mod stash (so autosave / quit never lose it).

**Lua API (bindings, not hooks):** `stash.register(name, { pages = N, gold = bool })`,
`stash.open(name)` (sets the active stash, opens the window like Gillian's option), `stash.activeName()`
(nil = vanilla). The existing `OnItemAllowedInStash(item, default)` hook is the item filter — the handler
checks `stash.activeName()`, so its signature doesn't change.

### Tame-Tome-specific problems (mod side)
- **Seeds and per-hero tables.** The Tome is shared by every Hunter save, but a scroll's kills / Bonded
  immunity / TRN / gamemode / Original Trainer live in tables owned by one hero, and seeds come from each
  hero's own counter (two heroes can mint the same seed). A scroll leaving the Tome must be **re-keyed
  into the withdrawing hero's seed space and rehydrated from its blob** — exactly what `OnItemPickedUp`
  does for a traded scroll. Deposit must make sure the blob is complete (`blobForSeed`) first.
- **When to re-key — DECIDED (user, 2026-11-02):** option (a), snapshot at open + close detected from the
  `stash.activeName()` transition; no new hook.
- Gamemode: `.sv` and `.hsv` give separate Tome files per gamemode for free; a locked scroll can't be
  moved, so it can never be filed into the wrong Tome.

### Before building
- Count + list every `Stash` reference by bucket (window → accessor; vanilla-only → unchanged) for the
  PR description.
- Confirm stores can't be open with the stash window (`IsPlayerInStore` vs `IsStashOpen`), so shop gold
  never runs while a mod stash is active.
- Decide the re-key trigger (above).

---

## Diablo/Hellfire scroll gamemode lock (BUILT 2026-11-02, awaiting compile + playtest)

**Why it's needed:** players may rename a hero's save between `.sv` (Diablo) and `.hsv` (Hellfire) —
DevilutionX explicitly allows moving characters between modes — so a Tame Scroll can cross gamemodes,
and Diablo/Hellfire monster data differ in many small ways.

**Rules (user, 2026-06-24):** a Hellfire-tamed scroll is locked in Diablo; a Diablo-tamed **Diablo**
scroll is locked in Hellfire; every other Diablo-tamed scroll works in Hellfire. **Total lockdown**
(user, 2026-11-02): a locked scroll is fully inert — no deploy, no sell, no move — until back in its
home gamemode.

**Data foundation (built 2026-06-25):** tamed-in gamemode captured at fresh tame via
`system.isHellfire()` into `scrollGamemode[seed]` (persisted in OnSave/OnLoadPlayerData) and `item.modData`
bit 22 (`0` Diablo / `1` Hellfire — never `dwBuff` bit 0, the engine's live `CF_HELLFIRE`); carried on
trade + re-keyed on pickup (`OnItemPickedUp`), synced on CO.

**Built (enforcement):** `scrollIsGamemodeLocked(seed)` in init.lua, applied at:
- red / unusable — `OnCanPlayerUseItem` (vanilla draws `_iStatFlag == false` red);
- speedbook — skipped in `OnGetCustomSpeedbookScrollEntries`; never a fallback in `OnResolveCustomScrollSlot`;
- deploy — refused in `OnCanCastScroll` (covers belt hotkeys / right-click);
- move / drop / visual-store sell — **new thin hook `OnPlayerCanCutInvItem`** gating the `CheckInvCut`
  call in `CheckInvItem` (`Source/inv.cpp`), default true = vanilla;
- stash / vendor — already refused for every Tame Scroll (`OnItemAllowedInStash`, `OnVendorWillBuyItem`).

**Recompile:** `inv.cpp`, `lua_event.cpp/.hpp`; refresh `events.lua`; copy `init.lua`. The new hook also
belongs in the `lua-mod-hooks` PR branch (item/inventory behaviour group).

**Playtest watch items** (tame in one mode, rename the save `.sv`↔`.hsv`, load in the other):
1. Hellfire-tamed scroll in Diablo: red, not in speedbook, right-click / belt hotkey → "I can't do that",
   click / shift-click / ctrl-click on it → "I can't do that" and it stays put.
2. Diablo-tamed Diablo scroll in Hellfire: same lockdown. Any other Diablo-tamed scroll in Hellfire: normal.
3. Unlocked scrolls and every non-scroll item still move, drop, belt and sell exactly as before.
4. Back in the home gamemode: the scroll is fully normal again.

*On verify: hook row already in `lua_api_reference.md`; dated entry → `HISTORY.md`; delete this section.*

---

## Upstream sync (merged master 2026-11-02, awaiting compile + playtest)

`master` (synced with diasurgical upstream, 144 commits) merged into `MonsterTamer` (`c2e76fa62`).
Recompile everything — reconfigure CMake first (new fetched dependency SheenBidi; `CMakePresets.json`
replaces `CMakeSettings.json`). Copy `init.lua` **and** `txtdata/classes/hunter/attributes.tsv` +
`sprites.tsv`.

Adaptations made in the merge (verify these compile + behave):
- HP/mana fields are `Fixed26_6`: monster `health`/`maxHealth`/`setHitPoints`/`setMaxHitPoints`,
  player `health`/`maxHealth`/`maxMana`, `resetStats` ported to `.whole()` / `fromInt`.
- `fmt::format` → `std::format` (`lua/modules/items.cpp`); `tl::expected` → `std::expected`.
- `ApplyPlrDamage` new arg order — the pet melee kill-classification passes `(dam, 0, deathReason)`.
- Potion hooks deleted; Hunter's 2× potions now come from the TSV. `OnGetManaCost` now fires on the
  whole-point cost before the class multiplier.
- The Hunter class TSVs gained required rows — 6 in `attributes.tsv`, 6 `partyOffset*` in
  `sprites.tsv` (Warrior's values) — without them the class `app_fatal`s at load.

**Playtest watch items:** Hunter loads at character select; potions heal/restore 2×; Sorc-lite mana
cost still −25%; ally HP bars / infobox HP read correctly (not 64× off); speedbook / infobox spell names
still show. Note: **release** builds refuse multiplayer while loose `.lua`/`.tsv` overrides exist
(`menu.cpp` `InitMultiPlayerMenu`) — playtest on a debug build or pack the mods as `.mpq`.

*On verify: dated entry → `HISTORY.md`; delete this section.*

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
feature: Tame Tome (roadmap §1).*
