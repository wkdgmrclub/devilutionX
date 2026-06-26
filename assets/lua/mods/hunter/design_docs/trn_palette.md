# TRN Notes — Hunter Palette Remapping

Technical notes on TRN (palette remap) files as used in the Hunter mod.

---

## What TRNs Are

256-byte lookup tables. `trn[i] = j` means every opaque pixel with color index `i` gets drawn as color index `j`. Applied once at sprite load in `LoadPlrGFX` — not animation-aware, not position-aware.

Hunter TRN: `assets/lua/mods/hunter/plrgfx/hunter.trn`. User copies manually to `%APPDATA%\diasurgical\devilution\mods\hunter\plrgfx\hunter.trn`.

---

## The Cross-Palette Consistency Trap

Each dungeon area (and many individual rooms) loads a different `.pal` file, and the **0–127 (`0x00–0x7F`) range is level-specific** — an entry like `0x4B` that is blue in the Church palette may be pink in the Caves palette. **Never use a 0–127 index as a TRN target**: a 0–127 target makes the sprite look broken across different rooms. The runtime area animations (`palette_update_caves/crypt/hive`) only ever cycle indices **1–31**, so they live entirely in this unsafe range too.

**Safe target range = the entire global sprite range `0x80–0xFF` (128–255).** Per `palette.h` ("Entry 128-255 are global") these entries have **identical RGB in every area palette** and are never touched by the area color-cycling — that's exactly why monster/player sprites are authored there and why the warrior TRN, the engine's stone/infra TRNs, and our Bonded scatter TRNs all work in every dungeon. So any 128–255 index is a reliable target (e.g. bright red ~230, bright yellow ~205, bright blue ~186, white ~254). The whole 128–255 range is safe — not just the warm-red `0xA0–0xAE` and slate-blue `0xB0–0xBC` rows the warrior TRN happens to use.

**Grayscale palettes** (`l1palg.pal`, `l3palg.pal`): all 256 entries are fully desaturated (R=G=B). Everything looks gray in gothic/crypt rooms regardless of TRN. This is expected and looks fine.

---

## Swaps Must Be Bidirectional — Critical Mistake to Avoid

When swapping two color roles (shirt↔pants), you must map BOTH directions independently:
- `0xAB → 0xBB` (shirt warm pixel → blue target) AND
- `0xBB → 0xAB` (pants blue pixel → warm target)

If you only map one direction, the other region's pixels stay in their original color and bleed through — e.g. leaving shirt entries `0xAE`/`0xAF` unmapped leaves warm-red pixels on the blue shirt.

---

## Analyze ALL Animation Files, Not Just Stand

`wlast.cl2` (stand) and `wlawl.cl2` (walk) expose different pixel distributions. Walk frames swing the arms, revealing shirt shadow pixels (`0xAE`, `0xDA`) that are completely hidden in every stand frame. Always scan the walk animation to find unmapped warm entries.

---

## Hunter TRN — Final State (20 non-identity entries)

Shirt warm `0xAx` → slate blue `0xBx`; pants slate `0xBx` → warm `0xAx`. Full bidirectional swap:

```
Shirt → Blue:  9E→BC  A9→B9  AA→BA  AB→BB  AC→BC  AD→BC  AE→BC  AF→BC  DA→BA
Pants → Warm:  B9→A9  BA→AA  BB→AB  BC→AC  BD→AD  BE→AE  BF→AF
Fire row→Blue: DB→BA  DC→BC  DD→BC  DE→BC
```

---

## Bonded Recolour TRNs — Full Two-Tone Repaint (the strong-overwrite approach)

A near-IDENTITY map that only nudges each monster's brightest tones into a narrow band barely shows — the
sprite just looks slightly lighter. The Bonded recolours instead use a strong repaint with fixed-bright
targets.

This mirrors how the engine's **Stone Curse** (`stone.trn`) and **Infravision** (`infra.trn`) TRNs
override *every* monster sprite globally: a **full repaint** of all 256 source colours into ONE target
ramp, keeping only brightness. Stone → the gray ramp (`PAL16_GRAY` 240-255); Infravision → a red ramp.
They read consistently in every dungeon because their targets live in the global range 128-255, which
has identical RGB in every area palette. (Applied via `ClxDrawTRN` = full-bright, no lighting pass; see
`scrollrt.cpp DrawMonster`.) **Key rule: the cross-palette trap is about TARGET indices, not source.**
You can remap any source as long as every target is >= 128.

`init.lua` bakes the Bonded recolours via `buildScatterTrn(pattern)`:
- A source pixel's **brightness rank** (offset within its own 8- or 16-entry ramp, dark→bright) indexes
  into the variant's repeating `pattern` (`rank % #pattern`). This is palette-free — no `.pal` needed; the
  ramp structure in `palette.h` (BLUE 176, YELLOW 192, ORANGE 208, RED 224, GRAY 240) gives brightness
  directly. (The brightness rank drives the dither phase, not the shade — see "Why fixed-bright" below.)
- Indices 0-127 (level-specific) stay IDENTITY — no cross-palette brightness data, and sprites live in
  the global range anyway.

### Scatter / dithered (spotty) application — preserving identity while staying distinct

A TRN has **zero spatial awareness** (it's a per-pixel color-index lookup), so it can't do "every other
pixel by position." But Diablo's art is already **checkerboard-dithered**: with ~16 shades per ramp, the
artists faked gradients by interleaving two adjacent palette indices in a checker across each region.
That gives the spatial pattern for free — if a TRN recolours only **some** indices and leaves the rest
identity, the sprite's own dither becomes a checkerboard of `[ally-colour] / [original-colour]`.

`buildScatterTrn(pattern)` exploits this. `pattern` is a short list cycled by brightness rank
(`rank % #pattern`): a numeric slot repaints the pixel a **fixed bright** colour, a `false` slot keeps the
monster's own pixel. So `{A, B, false}` scatters bright colour A / bright colour B / original across
consecutive ranks; the sprite's own dither turns that into a vivid speckle that still shows the monster.

**Why fixed-bright, not a rank-matched gradient:** a rank-matched gradient (`ramp16[rank]`) draws most
pixels from the **dark** end (most monster pixels sit at *low* ranks), so the speckles come out dull and
sparse-looking. Painting selected pixels a fixed bright entry makes the speckles pop regardless of the
source pixel's brightness.

Tuning: density = ratio of colours to `false` (`{A,B}` solid two-tone; `{A,B,false}` ~2/3 bright;
`{A,B,false,false}` sparser). Brightness/hue = the entries themselves (bright ramp entries: red ~230,
yellow ~205, blue ~186, white ~254). Note `ClxDrawTRN` draws full-bright (no lighting), so the identity
pixels show the monster's true colours slightly brightened — consistent with the recoloured speckles,
which are also unlit.

Five variants keyed to the rolled Bonded bonus (`BONDED_TRN_TABLE`, `bondedTrn[seed]` selects one). Each
is a `{colourA, colourB, false}` scatter (two bright tones + original showing through, ~2/3 coverage):
1 Fire immunity → bright red + bright yellow (230, 205); 2 Lightning → bright blue + white (186, 254);
3 Magic → white + bright red (254, 230); 4 +200 AC → near-black grey + bright grey (240, 253);
5 Gilded Metal → gold + white-gold (203, 255), a rare Hell-only upgrade (Hell-tamed allies have a 15%
chance to wear it instead of their bonus colour). To re-tune a look, edit its pattern (colours = bright
palette entries >= 128; density = ratio of colours to `false`). No build/palette tools required.

---

## Analyzing Sprites for Unmapped Warm Entries (PowerShell)

Palettes are extracted from the MPQ to `C:\Users\ndw19\AppData\Local\Temp\claude\allpals\levels\{l1data,l2data,l3data,l4data,towndata}\*.pal` (768 bytes each, R/G/B triplets for 256 entries).

CLX decode format (from `Source/utils/clx_decode.hpp`):
- Control byte `v < 0x80`: transparent, skip `v` pixels
- `0x80 ≤ v ≤ 0xBE`: fill run, color = next byte, width = `0xBF - v` pixels
- `v ≥ 0xBF`: literal run, width = `256 - v`, next `width` bytes are pixel colors

Walk CL2 group structure: `LE32(data, 0) / 4` = numGroups; group `g` starts at `LE32(data, g*4)`; frame `f` starts at `groupStart + LE32(data, groupStart + f*4)`. Scan all groups/frames, collect counts per color index, then filter for warm (R > B, R > G) entries not remapped to blue by the current TRN.
