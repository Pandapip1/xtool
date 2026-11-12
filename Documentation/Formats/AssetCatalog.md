# Compiled asset catalogs (`Assets.car`)

Notes for xtool's own asset-catalog compiler. These are written clean-room:
from files produced by compiling sample catalogs, from what the system
frameworks accept when loading files we write, and from independent
third-party code (xcbuild's BSD-licensed `libcar`). No Apple code is read or
disassembled.

## Container

An Apple BOM store (`BOMStore` magic, big-endian): a block index plus named
variables. A catalog uses:

| Variable | Contents |
|---|---|
| `CARHEADER` | `RATC` header: versions, rendition count, creator strings, UUID, schema version, color space |
| `KEYFORMAT` | `tmfk`, then the attribute identifiers making up every rendition key, in order |
| `FACETKEYS` | B-tree: asset name → attribute pairs (identifier 17 ties a name to its renditions) |
| `RENDITIONS` | B-tree: rendition key (one little-endian `u16` per key-format attribute) → `CTSI` rendition |
| `EXTENDED_METADATA` | `META` block with deployment/tool strings |
| `BITMAPKEYS` | B-tree of bitmap entries |

Observed key format (macOS, Xcode 27): attributes 7, 13, 1, 2, 3, 17, 11, 12.
Attribute 2 ("part") distinguishes rendition kinds: 181 bitmap, 42 vector,
217 color. Attribute 12 is the scale (1 or 2); attribute 17 the identifier.

### B-trees

A `tree` header (version 1, root node block, node size 4096, total entry
count) points at the root node. Nodes are `is_leaf: u16, count: u16,
forward: u32, backward: u32` followed by `(value_block, key_block)` pairs.
Leaves hold sorted entries and are chained through `forward`/`backward`.
When there is more than one leaf the root is a branch in B+-tree form:
`count` separator keys (each the last key of the leaf to its left) and
`count + 1` child pointers, the last child sitting in the value slot after
the final pair. Observed with a 600-entry catalog: two leaves (296 + 304)
under a one-separator root.

Rendition keys sort by their encoded bytes (memcmp of the little-endian
`u16` attributes): written in numeric order instead, lookups fail for
identifiers above 255 (verified with 260 to 3000 assets). Facet names sort
lexically, and inline keys (`BITMAPKEYS`) numerically.

## Renditions (`CTSI`)

A fixed header (version, flags, width, height, scale × 100, pixel format,
layout, 128-byte name, info length, payload length), a list of typed info
records, then the payload.

| Asset | Renditions | Payload |
|---|---|---|
| PNG image | one `ARGB` per scale | `CELM` v2, compression 11 (`dmp2`) |
| SVG image (preserving vectors) | one `SVG ` vector + `ARGB` at 1x and 2x | vector: `RAWD`, LZFSE-compressed SVG text |
| Color | one, pixel format 0 | `COLR` v1: color space, component count, components as `f64` |

Info record types seen: 0x3e9 (slices), 0x3eb (metrics), 0x3ec, 0x3ee,
0x3ef (bytes per row).

### Header and tables (Xcode 27, macOS)

- `CARHEADER` (436 bytes, little-endian): `RATC`, CoreUI version (1011),
  storage version (17), timestamp (0), rendition count, 128-byte creator,
  256-byte other-creator, 16-byte UUID (zero), checksum (0), schema version
  2, color space 1, key semantics 1.
- `KEYFORMAT`: `tmfk`, reserved 0, count, identifiers (`u32` each).
- `EXTENDED_METADATA` (1028 bytes): `META`, then NUL-separated strings:
  deployment target, platform, tool versions.
- Facet values: hot-spot `(u16, u16)`, attribute count `u16`, then
  `(identifier, value)` `u16` pairs: element 85, part, identifier 17.
- `BITMAPKEYS`: a tree with 1024-byte nodes whose key slot holds the name
  identifier inline (not a block). Values are 48 bytes: `1, 0, 36, 8`, then
  one `u32` mask per key-format attribute: the set of values the name's
  renditions use (scale: 2 for 1x only, 6 for 1x and 2x), 1 for an
  attribute always 0, and `0xffffffff` for some (not yet understood).

### Bitmap payloads (verified by loading written files)

A writer that produces the tables above, with renditions laid out as
observed, is accepted by the system: `NSColor(named:bundle:)` returns the
exact color, and the bundle's image lookup returns a bitmap whose decoded
bytes match what was written. Established by writing variants and loading
them, one field at a time:

- `CELM` compression 0: uncompressed, premultiplied BGRA rows (decoded as
  32-bit little-endian, alpha first). Compression 4: LZFSE of the same rows
  (decoded to RGBA order). CarKit writes LZFSE, using the vendored reference
  implementation (Sources/CLzfse). zlib, whether wrapped or raw deflate, is not
  decoded under any type number tried (0–12).
- `CELM` flags: bit 0 marks chunked data ("Can't find the correct chunk"
  when set on unchunked data); bit 1 makes the image opaque.
- Rendition color space (low bits of the header field after the pixel
  format): 0 is Generic RGB, 1 is sRGB. The `CARHEADER` color space does not
  change how bitmaps are tagged.

## Open questions

- Whether compression 2 means anything distinct (uncompressed data decodes
  the same as with 0).
- Appearance variants (dark mode), and the `.icon` (Icon Composer) renditions.
