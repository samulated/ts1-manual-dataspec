# IFF Format — Complete Reference

> Sources: `notes/iff.md` (wiki), `notes/iff_working.md` (real-file findings),
> all `crates/sims-iff/src/chunks/*.rs` decoders, and smoke tests against base-game files.
>
> **Confidence key:**
> - **[HIGH]** — verified against real TS1 game files, implemented and unit-tested
> - **[MED]** — observed pattern on a small sample; plausible but not exhaustively verified
> - **[LOW]** — inferred or partially observed; treat as a hypothesis

---

## 1. Overview

IFF ("Interchange File Format") is a chunk-based binary container format used by The Sims 1 for all object data, strings, sprites, and house save files. Every file inside a FAR archive is an IFF, as are all house save files in `UserData/Houses/`.

- **Structure:** 64-byte file header → flat sequence of chunks, each self-describing  
- **No nesting:** chunks do not contain other chunks  
- **Chunk data is typed by a 4-character ASCII type code**  
- Unknown chunk types can be safely skipped — by design **[HIGH]**

### File Extensions **[HIGH]**

| Extension | Contents |
|-----------|----------|
| `.iff`    | Object data, game options, characters, Edith UI strings, careers |
| `.flr`    | Floor coverings catalog |
| `.wll`    | Wall coverings catalog |
| `.spf`    | Sprites split from an object |
| `.stx`    | Strings split from an object |

All use the identical container structure.

---

## 2. Byte Order — Critical **[HIGH]**

IFF uses **mixed** byte order, which is the most common source of parsing bugs:

| Region | Byte order |
|--------|-----------|
| Chunk header fields (type, size, chunk_id, flags) | **Big-endian** |
| Chunk data (everything inside a chunk) | **Little-endian** |
| rsmp type codes and chunk IDs | Byte-swapped (see §5) |

The type code is ASCII so byte order is moot there, but `size`, `chunk_id`, and `flags` are all big-endian.

---

## 3. File Header (64 bytes) **[HIGH]**

Two versions, detected by bytes 8–10.

### Version 2.0
Full 64-byte ASCII signature (no trailing data field):
```
IFF FILE 2.0:TYPE FOLLOWED BY SIZE\0 JAMIE DOORNBOS & MAXIS 1996\0
```
Chunks start at byte 64.

### Version 2.5
First 60 bytes are a truncated version of the same signature:
```
IFF FILE 2.5:TYPE FOLLOWED BY SIZE\0 JAMIE DOORNBOS & MAXIS 1
```
Bytes 60–63: **big-endian u32** — absolute file offset of the rsmp chunk.

### Which version is used where? **[MED]**
- Base-game object IFFs inside FARs: v2.5 (confirmed for Toilets.iff)
- House save files in `UserData/Houses/`: v2.0 (documented; House00.iff noted as such)
- Other UserData files: unknown

---

## 4. Chunk Header (76 bytes) **[HIGH]**

Every chunk begins with a 76-byte header:

| Offset | Size | Type | Field | Notes |
|--------|------|------|-------|-------|
| 0x00 | 4 | ASCII | `type_code` | e.g. `OBJD`, `STR#`, `SPR2`. Not null-terminated. |
| 0x04 | 4 | u32 BE | `size` | Total chunk size **including** this 76-byte header. Data = `size − 76` bytes. |
| 0x08 | 2 | u16 BE | `chunk_id` | Unique within the file. Used as a cross-reference key. |
| 0x0A | 2 | u16 BE | `flags` | See §4.1 below. |
| 0x0C | 64 | ASCII | `label` | Null-terminated human-readable comment. Cosmetic only. |
| 0x4C | var | — | `data` | `size − 76` bytes, **little-endian** encoding within. |

The next chunk starts at `current_offset + size`. Iterate until EOF.

### 4.1 Chunk Flags **[MED]**

Two values observed in Toilets.iff:

| Value | Chunks | Hypothesis |
|-------|--------|-----------|
| `0x0010` | OBJD, OBJf, CTSS, STR#, TTAB, TTAs, DGRP, BHAV, BMP_, SLOT, BCON, FWAV, rsmp | "Always loaded" / indexed |
| `0x0000` | PALT, SPR2 | "Load on demand" (graphics) |

The actual game interpretation of these bits is unconfirmed.

---

## 5. Resource Map (rsmp) **[HIGH]**

An optional index chunk enabling O(1) lookup by type+ID. Chunk ID is always 0, label is empty.

### rsmp position **[HIGH — known wiki error corrected]**

The wiki says rsmp is always the last chunk. **This is wrong.** In Toilets.iff (base game), the rsmp is the **first** chunk (rsmp_offset=64, immediately after the file header), with all 104 content chunks following. The linear scanner must **not** stop at rsmp — treat it as a normal chunk.

### rsmp data layout **[HIGH]**

| Field | Type | Notes |
|-------|------|-------|
| Reserved | 4 bytes | Zero |
| Version | u32 LE | 0 for TS1, 1 for TSO |
| Magic | 4 bytes | ASCII `pmsr` (= `rsmp` reversed) or zero |
| Size | u32 LE | Ignore — may be 0 or garbage in v1 |
| Chunk type count | u32 LE | Number of distinct types listed (excludes rsmp itself) |

For each type:

| Field | Type | Notes |
|-------|------|-------|
| Type | 4 bytes | **Byte-swapped** — e.g. `DJBO` means `OBJD` |
| Count | u32 LE | Number of chunks of this type |

For each chunk of that type:

| Field | Type | Notes |
|-------|------|-------|
| Offset | u32 LE | Absolute file byte offset to the chunk header |
| Chunk ID | u16 LE (v0) | **Byte-swapped** — reverse the 2 bytes to get the real ID |
| Flags | u16 LE | **Byte-swapped** |
| Label | null-terminated string (v0) | Chunk label |

---

## 6. House-IFF Chunk Preamble **[HIGH]**

Chunks specific to house save files (HOUS, Arry, ObjM, objt) share a 12-byte preamble at the start of their data field:

```
bytes 0–3:  u32 = 0 (reserved)
bytes 4–7:  u32 LE = save_version  (matches HOUS save_version)
bytes 8–11: 4-byte reversed magic (e.g. "SUOH" for HOUS, "tjbo" for objt, "MjbO" for ObjM)
```

---

## 7. Chunk Types — Object IFFs

These chunks appear in object `.iff` files (and `.spf`/`.stx` variants). The primary example is `Toilets.iff` from `Objects.far`.

---

### 7.1 OBJD — Object Definition **[HIGH]**

The primary descriptor for a placeable object. An IFF can contain multiple OBJDs (e.g., both "Toilet - Cheap" and "Toilet - Expensive" in Toilets.iff).

**Data layout** (all u16 LE unless noted):

| Offset | Field | Notes |
|--------|-------|-------|
| 0 | `version` (u32) | 136 = base game, 138 = expansion. Full size distinguishes 138a (190 bytes) vs 138b (216 bytes) |
| 4 | `initial_stack_size` | SimAntics execution stack depth |
| 6 | `base_graphic_id` | DGRP chunk_id for the first drawing group |
| 8 | `num_graphics` | Number of DGRP chunks for this object |
| 10 | `main_bhav_id` | BHAV chunk_id of the "main" (idle) behavior |
| 12 | `gardening_bhav_id` | |
| 14 | `ttab_id` | TTAB chunk_id for this object's interaction table |
| 16 | `interaction_group` | |
| 18 | `object_type` | See object type codes below |
| 20 | `master_id` | Non-zero = multi-tile object; references the master tile's chunk_id |
| 22 | `sub_index` (i16) | −1 = this is the master tile; otherwise `(y << 8 \| x)` offset |
| 24 | `wash_hands_bhav_id` | |
| 26 | `anim_table_str_id` | STR# chunk_id listing animation names |
| 28 | `guid` (u32) | Global unique ID matching objt catalogue GUIDs |
| 32 | `disabled` | |
| 34 | `portal` | |
| 36 | `price` | Simoleons |
| 38 | `body_strings_str_id` | STR# for character body strings (Person only) |
| 40 | `slot_id` | SLOT chunk_id for routing slots |
| 42 | `allow_intersection_bhav_id` | |
| 44 | `unknown_0` (u32) | Unknown purpose |
| 48 | `prepare_food_bhav_id` | |
| 50 | `cook_food_bhav_id` | |
| 52 | `place_on_surface_bhav_id` | |
| 54 | `dispose_bhav_id` | |
| 56 | `eat_food_bhav_id` | |
| 58 | `pickup_from_slot_bhav_id` | |
| 60 | `wash_dish_bhav_id` | |
| 62 | `eating_surface_bhav_id` | |
| 64 | `sit_bhav_id` | |
| 66 | `stand_bhav_id` | |
| 68 | `sale_price` | |
| 70 | `initial_depreciation` | |
| 72 | `daily_depreciation` | |
| 74 | `self_depreciating` | |
| 76 | `depreciation_limit` | |
| 78+ | `remaining` | Undocumented fields for v138b and beyond |

**Object type codes:**

| Value | Meaning |
|-------|---------|
| 0 | Unknown |
| 2 | Person |
| 4 | Normal (buyable object) |
| 7 | Controller (NPC controller, job finder) |
| 8 | Architectural (stairs, doors, windows) |
| 9 | Cursor (placement indicator) |
| 10 | Prize |
| 11 | Internal (temporary drop/shoo location) |
| 34 | Food |

**Confirmed values (Toilets.iff):**
- Cheap toilet: version=138, size=216, guid=`0x84e0774c`, price=300
- Expensive toilet: version=138, size=216, guid=`0x3c566968`, price=1200

---

### 7.2 BHAV — SimAntics Bytecode **[HIGH]**

Behavior scripts for object logic.

**Header** (12 bytes):

| Offset | Type | Field | Notes |
|--------|------|-------|-------|
| 0 | u16 LE | `magic` | Observed: 0x8000 |
| 2 | u16 LE | `instruction_count` | Number of instructions |
| 4 | u8 | `arg_count` | Number of caller-passed arguments |
| 5 | u8 | `local_count` | Number of local variables |
| 6 | u16 LE | `flags` | Unknown |
| 8 | u32 LE | `extra` | Unknown |

**Instructions** (12 bytes each):

| Offset | Type | Field | Notes |
|--------|------|-------|-------|
| 0 | u16 LE | `opcode` | Primitive ID (0=Sleep, 1=Generic Call, 2=Expression, etc.) |
| 2 | u8 | `true_dest` | Instruction index if primitive returns TRUE |
| 3 | u8 | `false_dest` | Instruction index if primitive returns FALSE |
| 4–11 | [u8; 8] | `operands` | Primitive-specific arguments |

**Special destination values:**

| Value | Meaning |
|-------|---------|
| 0xFE | Return TRUE from this BHAV |
| 0xFF | Return FALSE from this BHAV |
| 0xFD | Error / kill frame |

**Confirmed (Toilets.iff):** 31 BHAVs; `number1` = 51 instructions, `Unclog` = 44 instructions.

---

### 7.3 OBJf — Object Function Table **[HIGH]**

Maps well-known function slots to BHAV chunk IDs (guard/action pairs).

**Header** (16 bytes):

| Offset | Type | Field |
|--------|------|-------|
| 0 | 8 bytes | Reserved (zero) |
| 8 | 4 bytes | Magic: `fJBO` (= `OBJf` reversed, LE) |
| 12 | u32 LE | `count` — number of entries |

**Entries** (4 bytes each, as `(guard_bhav_id u16, action_bhav_id u16)`):

- Slot 0 = Init; Slot 1 = Main; remaining slots are documented in the wiki function table
- Toilets.iff cheap toilet: slot 0 guard=BHAV#4119 ("init cheap"), slot 1 guard=BHAV#4096 ("main")
- 30 function slots in Toilets.iff

---

### 7.4 STR# / CTSS / TTAs / FAMs — String Tables **[HIGH]**

All four use the same binary format, distinguished only by type code:

| Type | Purpose |
|------|---------|
| `STR#` | Animation name tables, suit strings, generic string lists |
| `CTSS` | Catalog text (one per OBJD: object name + description) |
| `TTAs` | Pie-menu interaction labels (one per TTAB) |
| `FAMs` | Family/character name strings |

**Data layout:**

Starts with a 2-byte signed version field:

| Version (i16 LE) | Format |
|-----------------|--------|
| 0 | Pascal strings (1-byte length prefix) |
| −1 (0xFFFF) | Null-terminated C strings |
| −2 (0xFEFF) | Null-terminated C string pairs (data + comment) |
| −3 (0xFDFF) | C string pairs with 1-byte language code prefix |
| −4 (0xFCFF) | TSO only — not needed for TS1 |

TS1 base game uses versions 0 through −3. Strings are Windows-1252 encoded.

---

### 7.5 TTAB — Interaction Table **[HIGH]**

Maps pie-menu items to guard/action BHAV subroutines, autonomy weights, and motive advertisements.

**Header** (4 bytes + 1 compression byte):

| Offset | Type | Field |
|--------|------|-------|
| 0 | u16 LE | `interaction_count` |
| 2 | u16 LE | `version` (9 for TS1 base game, 10 for some objects) |
| 4 | u8 | `compression_code` (ignored) |

**Version 9/10 bit-packed encoding:**

All remaining bytes form a big-endian bit stream. Each field is decoded as:
1. Read 1 bit — if 0, value is 0 (done)
2. Read 2 bits as `prefix` (0–3)
3. Look up `width` from the field's type table
4. Read `width` bits and sign-extend to i64

Width tables:
- Narrow (i16/u16): `{5, 8, 13, 16}` bits for prefix `{0, 1, 2, 3}`
- Wide (u32/i32): `{6, 11, 21, 32}` bits for prefix `{0, 1, 2, 3}`

**Per-entry fields** (decoded in order):

| Field | Type | Notes |
|-------|------|-------|
| `action_func_id` | Narrow (i16) | BHAV chunk_id to run |
| `guard_func_id` | Narrow (i16) | BHAV chunk_id for availability check (0 = always available) |
| `motive_count` | Wide (u32) | Number of motive records that follow |
| `flags` | Wide (u32) | Joinable, autonomous, etc. |
| `ttaid` | Wide (u32) | Index into paired TTAs string chunk for the label |
| `attenuation_code` | Wide (u32) | 0–4; 0 = use `attenuation_value` |
| `attenuation_value` | Wide (u32) | Custom attenuation multiplier |
| `autonomy_threshold` | Wide (u32) | Minimum autonomy level for autonomous use |
| `joining_index` | Wide (i32) | Joinable interaction ID (−1 = not joinable) |
| Per motive × motive_count: | | |
| `effect_range_min` | Narrow (i16) | Lower bound of advertised motive effect |
| `effect_range_max` | Narrow (i16) | Upper bound of advertised motive effect |
| `personality_modifier` | Narrow (u16) | Personality trait index (0 = none) |

**Version 10** adds one extra Wide field per entry after the motive records.

**Confirmed (Toilets.iff cheap toilet):** 5 interactions; action BHAVs = 0x1002, 0x101d, 0x1006, 0x1008, 0x1015; guard BHAVs = 0x1003, 0x1005, 0x1007, 0x1009, 0x1016.

---

### 7.6 DGRP — Drawing Group **[HIGH]**

Assembles sprites into renderable tiles. Each DGRP represents one visual state of an object (e.g., "toilet seat up, zoom 1, south-facing").

**Data layout:**

| Offset | Type | Field |
|--------|------|-------|
| 0 | u16 LE | `version` — 20003 or 20004 |
| 2 | u32 LE | `image_count` |

For each image:

| Offset | Type | Field |
|--------|------|-------|
| 0 | u32 LE | `direction` — 0=south, 1=east, 2=north, 3=west |
| 4 | u32 LE | `zoom` — 1, 2, or 3 |
| 8 | u32 LE | `sprite_count` |

For each sprite in an image:

| Offset | Type | Field | Notes |
|--------|------|-------|-------|
| 0 | u32 LE | `spr_chunk_id` | SPR2 chunk_id to draw |
| 4 | u32 LE | `frame_index` | Which frame within that SPR2 |
| 8 | i32 LE | `pixel_x` | Pixel offset from tile foot point (east/west) |
| 12 | i32 LE | `pixel_y` | Pixel offset from tile foot point (north/south) |
| 16 | u32 LE | `z_offset` | Depth sorting offset |
| 20 | u32 LE | `flags` | Unknown |
| 24 | u32 LE | `world_x` | World-space X (sub-tile) |
| 28 | u32 LE | `world_y` | World-space Y (sub-tile) |

**Confirmed (Toilets.iff):** 14 DGRPs × 12 images × 3 sprites each = 168 total rendered images.

---

### 7.7 SPR2 — Sprite **[HIGH]**

A paletted sprite with optional z-buffer and alpha channels. Multiple frames per SPR2.

**SPR2 header** (12 bytes):

| Offset | Type | Field |
|--------|------|-------|
| 0 | u32 LE | `version` |
| 4 | u32 LE | `sprite_count` — number of frames |
| 8 | u32 LE | `palette_id` — PALT chunk_id to use |

Followed by an offset table: `sprite_count × u32` offsets (absolute within the chunk data).

**Per-frame header:**

| Offset | Type | Field | Notes |
|--------|------|-------|-------|
| 0 | u16 LE | `width` | Pixels |
| 2 | u16 LE | `height` | Pixels |
| 4 | u32 LE | `flags` | Bit 0 = has z-buffer; bit 1 = has alpha |
| 8 | u16 LE | `palette_id` | Per-frame palette override |
| 10 | u16 LE | `transparent_pixel_index` | Palette index treated as transparent |
| 12 | u16 LE | `y_location` | Canvas draw Y |
| 14 | u16 LE | `x_location` | Canvas draw X |

**Pixel row encoding:**

Rows are encoded as a stream of commands (packed u16 big-endian):

| High 3 bits | Low 13 bits | Meaning |
|------------|------------|---------|
| 0 | count | Data row: `count` inner pixel commands follow |
| 4 | count | Transparent rows: skip `count` rows |
| 5 | 0 | End of frame |

Inner pixel commands (each 1–5 bytes):

| First byte | Meaning |
|-----------|---------|
| 1 | z-value (1 byte) + palette index (1 byte) |
| 2 | z-value (1 byte) + palette index (1 byte) + alpha (1 byte) + even-byte pad |
| 3 | transparent skip (no pixel data) |
| 6 | palette index only (1 byte) + even-byte pad |

**Confirmed (Toilets.iff):** 6 frames per SPR2; pixel decoder produces correct RGBA.

---

### 7.8 PALT — Color Palette **[HIGH]**

256-entry RGB color table.

**Header** (16 bytes):

| Offset | Type | Field |
|--------|------|-------|
| 0 | u32 LE | `version` |
| 4 | u32 LE | `count` — always 256 in TS1 |
| 8 | 8 bytes | Reserved (zero) |

Followed by `count × 3` bytes of RGB triplets (R, G, B order).

Note: The header is 16 bytes, **not** 8 as some documentation suggests. 8 reserved bytes precede the RGB data.

---

### 7.9 BCON — Behaviour Constants **[HIGH]**

A small lookup table of u16 constants referenced by BHAV scripts.

**Data layout:**

| Offset | Type | Field |
|--------|------|-------|
| 0 | u8 | `count` — number of constants |
| 1 | u8 | `flags` |
| 2+ | u16 LE × count | The constants |

In BHAV scripts, BCON constants are referenced by the object's chunk_id and an index. Only load BCONs from the object's own IFF for the "tuning" scope (scope 26); do not mix with global BCONs to avoid namespace collisions.

---

### 7.10 GLOB — Semi-global Reference **[HIGH]**

A reference to an external shared IFF file that provides common BHAVs and BCONs.

**Data layout:** Null-terminated filename string (e.g., `Global.iff`, `PersonGlobals.iff`), followed by any remaining bytes (unknown purpose).

When executing a BHAV that calls chunk_id 0x0100–0x01FF, look up the BHAV in the GLOB-referenced file.

---

### 7.11 FWAV — Sound Event **[HIGH]**

A single null-terminated ASCII string naming a sound event (e.g., `"toilet_flush"`).

Multiple FWAVs in one object map sound event names for different actions.

---

### 7.12 SLOT — Routing Slots **[MED]**

Specifies where a Sim must stand to use an object.

**Header** (16 bytes):

| Offset | Type | Field |
|--------|------|-------|
| 0 | u32 LE | Reserved (0) |
| 4 | u32 LE | `count` |
| 8 | 4 bytes | Magic: `TOLS` |
| 12 | u32 LE | Unknown |

**Per-entry** (28 bytes = 7 × 4 bytes):

| Offset | Type | Field | Notes |
|--------|------|-------|-------|
| 0 | u32 LE | `slot_type` | Purpose not confirmed |
| 4 | u32 LE | `unk0` | Unknown |
| 8 | i32 LE | `dx` | X offset (east/west) from object origin |
| 12 | i32 LE | `dy` | Y offset (north/south) from object origin |
| 16 | i32 LE | `dz` | Z offset (elevation) |
| 20 | u32 LE | `unk1` | Unknown |
| 24 | u32 LE | `unk2` | Unknown |

**Coordinate scale [LOW]:** Values observed in Toilets.iff entry 0 are `dx=0xC080=49280`, `dy=0x4080=16512`. In 16.16 fixed-point this is approximately (0.75, 0.25) tiles. Other entries have small integers suggesting a sub-tile fixed-point encoding, but the exact scale is not confirmed.

**Confirmed (Toilets.iff):** 296 bytes total, 10 entries.

---

### 7.13 BMP_ — Bitmap **[LOW]**

Bitmap images used for catalog thumbnails and speech bubble graphics. The format is not decoded — the bytes are kept raw. Toilets.iff has 4 BMP_ chunks (cheap/expensive variants, catalog vs speech bubble).

---

## 8. Chunk Types — House Save IFFs

These appear in `UserData/Houses/House*.iff`. They use the common 12-byte preamble (§6).

---

### 8.1 HOUS — Lot Metadata **[HIGH]**

Chunk #0 = persistent lot data. Chunk #1 = transient runtime state (62 bytes, not decoded).

**Data layout** (after 12-byte preamble):

| Offset | Type | Field | Notes |
|--------|------|-------|-------|
| 12 | u32 LE | `lot_id` | 0-based index in the neighbourhood |
| 16 | u32 LE | Unknown | Always 1 |
| 20 | u32 LE | `funds` | Family funds in simoleons |
| 24 | i32 LE | `neighborhood_pos` | Signed tile offset on the neighbourhood map |

**Confirmed (House01.iff):** save_version=62, lot_id=1, funds=204, neighborhood_pos=−266.

---

### 8.2 Arry — Compressed Tile Grid **[HIGH]**

A 2D array of tile data, RLE-compressed. Multiple Arry chunks appear in each house IFF, identified by chunk_id.

**Header** (20 bytes, after 0-byte preamble for Arry — Arry does NOT use the 12-byte preamble):

| Offset | Type | Field |
|--------|------|-------|
| 0 | u32 LE | `type_id` (purpose unknown) |
| 4 | u32 LE | `cols` — grid width (64 for standard lots) |
| 8 | u32 LE | `rows` — grid height (64 for standard lots) |
| 12 | u32 LE | `cell_size` — bytes per tile |
| 16 | u32 LE | `flag` (unknown) |

Followed by compressed data (20 bytes offset).

**RLE compression:**

Each record is a 2-byte count header:
- High bit = 1 → **RLE run**: count = low 15 bits; next 2 bytes = value byte + pad byte. Emit `count` copies of value.
- High bit = 0 → **Literal run**: next `count_hdr` bytes are raw data. Odd counts get a trailing pad byte.

**Known Arry chunks by chunk_id:**

| Chunk ID | `cell_size` | Contents |
|----------|------------|---------|
| 0 | 4 | **Altitude** — 4 bytes per tile encoding corner heights |
| 1 | 1 | **Floors** — floor covering ID (0 = unfloored/outdoor) |
| 2 | 8 | **Walls** — 8 bytes per tile (see wall encoding below) |
| 3 | 1 | **Objects** — object type sequence ID (from objt catalogue) |
| 101 | 1 | **Floors2** — second floor layer |

**Wall encoding (Arry #2, cell_size=8) [MED]:**

Observed in House01 and House02:

| Byte | Observed values | Interpretation |
|------|----------------|----------------|
| raw[0] | 0x00–0x20 | Unknown / covering data |
| raw[1] | 0x0f | Unknown |
| raw[2] | 0x01 or 0x02 | Likely wall covering ID (changes on tiles adjacent to north exterior walls) |
| raw[3] | 0x01 | Unknown |
| raw[4] | 0x00, 0xf8, 0x0c, 0xf9, 0x03, 0x20 | **North structural wall**: non-zero = wall present |
| raw[5–7] | varies | Unknown |

Default no-wall cell: `[00, 0f, 01, 01, 00, 00, 00, 00]`

**West wall encoding [LOW]:** Not confirmed. `raw[2]` was initially suspected but is the covering ID for the adjacent north wall face. West structural walls are currently undetected; exterior boundaries are inferred from unfloored tiles in the flood-fill algorithm.

---

### 8.3 objt — Object Type Catalogue **[HIGH]**

A list of all object types present in this house save. Provides the mapping from GUID to type name and sequential type index.

Uses the 12-byte preamble with magic `tjbo` (= `objt` reversed).

**Per-entry layout:**

| Offset | Type | Field | Notes |
|--------|------|-------|-------|
| 0 | u32 LE | `guid` | Matches OBJD.guid in the object's IFF |
| 4 | u16 LE | unknown | |
| 6 | u16 LE | unknown | |
| 8 | u16 LE | unknown | |
| 10 | u16 LE | `unk3` | Unknown |
| 12 | u16 LE | `type_seq_id` | 1-based sequential type index |
| 14 | u16 LE | unknown | |
| 16+ | C string | `name` | Null-terminated, 2-byte aligned (padded if odd length) |

The list ends when a null GUID (`00 00 00 00`) is encountered.

The `type_seq_id` values are **1-based** and match the values stored in the Arry #3 (objects) tile grid. Arry #3 stores these type_seq_ids, not zero-based indices.

---

### 8.4 ObjM — Per-Instance Object Placement **[MED]**

Stores the position and state of every placed object instance in the lot. This chunk accumulates across saves — **old records are not removed when objects are moved or replaced**. The last record for any given instance ID reflects the current state.

**Header** (12 bytes, using the 12-byte preamble):

| Bytes | Content |
|-------|---------|
| 0–3 | u32 = 0 |
| 4–7 | u32 LE = `save_version` |
| 8–11 | Magic `MjbO` (= `ObjM` modified) |

**Structure:**

- After the header: a **pre-record block** (type-map bitstream) — ends 8 bytes before the first `88 0c 0c` marker
- **Records**: variable-length; each ends with the 3-byte marker `88 0c 0c`
- **Terminator**: `00 00 00 00 00 a3` at the end of the chunk data

**Position encoding [HIGH]:**

The 8 bytes immediately before each `88 0c 0c` marker:

```
col = pre_field[7] & 0x3f           // low 6 bits of byte[7]
row = (pre_field[6] >> 6)           // top 2 bits of byte[6]
    | ((pre_field[5] & 0x0f) << 2)  // low 4 bits of byte[5]
```

Both values are 0-based tile indices matching the 64×64 Arry grid.

**Type-map bitstream (pre-record block) [MED]:**

Uses the same narrow bit-stream encoding as TTAB (1-bit flag, 2-bit prefix, {5,8,13,16}-bit values). Decodes into `(instance_id, type_seq_id)` pairs:

- Zeros are padding (skip)
- If first value < `num_types`: primary encoding is `(type_idx, instance_id)` where type_idx is 1-based
- If first value ≥ `num_types`: swap roles (first = instance_id)
- Ambiguous case (both < num_types): default to `(type_idx=first, instance_id=second)` — **known to be wrong for ~5% of records** across test houses

**Instance ID extraction (post-record bitstream) [MED]:**

Each record's post-data is also a narrow bit-stream. Field 25 (0-indexed) = the object's instance ID. Zero means absent; use Arry-3 tile value as fallback.

**Type resolution lookup priority:**

1. `post_data field 25` > 0 → look up in type_map
2. `post_data field 25` > 0 but not in type_map → try Arry-3 tile value as instance_id
3. `post_data field 25` = 0 → use Arry-3 tile value directly

**Last-record-wins rule [MED]:** When multiple ObjM records exist for the same tile, the last (highest index) record is current. Earlier records are stale from prior placements.

**Confirmed sizes:** House01.iff ObjM = 4758 bytes; House00.iff = 19 bytes (effectively empty lot).

---

## 9. Cross-Chunk Relationships

These links connect chunks within the same IFF file (or across files via GLOB):

```
Within an object IFF:

  OBJD.ttab_id         ──→  TTAB.chunk_id        (interaction table)
  OBJD.slot_id         ──→  SLOT.chunk_id        (routing slots)
  OBJD.base_graphic_id ──→  DGRP.chunk_id        (first drawing group)
  OBJD.main_bhav_id    ──→  BHAV.chunk_id        (idle behavior)
  OBJD.anim_table_str_id──→ STR#.chunk_id        (animation name list)
  OBJD.guid            ──→  objt.guid            (cross-file: lot catalogue)

  TTAB.action_func_id  ──→  BHAV.chunk_id        (action script)
  TTAB.guard_func_id   ──→  BHAV.chunk_id        (guard script)
  TTAB.ttaid           ──→  TTAs string index    (pie menu label)

  OBJf.entries[n]      ──→  BHAV.chunk_id        (guard/action for each function slot)

  DGRP sprite entries  ──→  SPR2.chunk_id        (which sprite to draw)
  SPR2.palette_id      ──→  PALT.chunk_id        (color table to use)

  BHAV calls (opcode 1)──→  BHAV.chunk_id in same file, or
                             via GLOB → external IFF's BHAV

Across files:

  GLOB.filename        ──→  external .iff file   (e.g. "Global.iff")
  BHAV call IDs 0x100–0x1FF ──→ BHAVs in GLOB file

Within a house IFF:

  Arry#3 cell values   ──→  objt.type_seq_id     (1-based type index)
  objt.guid            ──→  OBJD.guid in object IFF  (type identification)
  ObjM.type_map        ──→  objt index           (instance → type)
  ObjM.instance_id     ──→  ObjM.type_map        (per-record lookup)
```

---

## 10. Typical Chunk Inventory (Toilets.iff)

For reference, a complete single-object IFF:

| Count | Type | Purpose |
|-------|------|---------|
| 2 | OBJD | "Toilet - Cheap" and "Toilet - Expensive" |
| 2 | OBJf | Function tables (one per OBJD) |
| 2 | CTSS | Catalog strings (one per OBJD) |
| 4 | STR# | Animation name tables + suit primitive strings |
| 2 | TTAB | Interaction tables (cheap / expensive) |
| 2 | TTAs | Pie menu labels (one per TTAB) |
| 14 | DGRP | Drawing groups for seat states × zoom levels |
| 8 | PALT | Color palettes (IDs 0–7) |
| 12 | SPR2 | Sprite sheets (two zoom levels) |
| 31 | BHAV | All behavior subroutines |
| 4 | BMP_ | Catalog and speech-bubble thumbnails |
| 1 | SLOT | Routing slot table |
| 2 | BCON | Behavior constants |
| 19 | FWAV | Sound event names |
| 1 | rsmp | Resource map (first chunk, not last) |

---

## 11. Open Questions

| Question | Status |
|----------|--------|
| West wall encoding in Arry #2 | **Unsolved** — raw[4] = north, west encoding unknown |
| ObjM post-data field layout beyond field 25 | **Partially decoded** — only field 25 (instance_id) is extracted |
| ObjM type_map ambiguous pairs (~5% error rate) | **Known limitation** — unsolvable without external ground truth |
| SLOT coordinate scale (sub-tile fixed-point?) | **Unconfirmed** — 16.16 hypothesis from Toilets.iff values |
| SLOT `slot_type` value meanings | **Unknown** |
| Chunk flags 0x0010 vs 0x0000 exact meaning | **Hypothesis only** (always-loaded vs on-demand graphics) |
| OBJD 138a vs 138b sub-version (same version field, differ by byte count) | **Confirmed by observation** — no version field to distinguish them, use byte count |
| BMP_ chunk format | **Not decoded** |
| Arry #2 bytes 0–3 and 5–7 exact purpose | **Unknown** |
| HOUS chunk #1 (runtime state, 62 bytes) | **Not decoded** |
| OBJD fields beyond offset 78 (version 138b) | **Preserved as raw `remaining` bytes** |
