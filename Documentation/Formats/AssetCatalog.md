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

Vector renditions: part 42, pixel format `SVG `, flags 4, layout 9, color
space 0, info records 0x3ec and 0x3ee as for colors; payload `RAWD`,
version 1, length, LZFSE data. The bitmaps rendered from the same SVG are
ordinary bitmap renditions with flags 0x114 (0x10 for plain bitmaps).
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

## Layered icons (Icon Composer `.icon`)

Established by compiling single-setting variants of an `.icon` with actool,
reading the output with the tools above, and comparing how the system draws
the icon (`NSWorkspace.icon(forFile:)` on an app whose `CFBundleIconName`
names it) against the same `.icon` compiled by CarKit. Once the system has
rendered an icon, later renders of it are identical to each other, and those
match exactly, in every icon style (default, dark, clear and tinted, light
and dark). The first render of a catalog the system has not seen differs
slightly from later ones (a level or two at edges), whoever wrote it, so
comparisons skip it. No `.icns` is needed for any of this.

actool's own output is not byte-for-byte reproducible: its flattened bitmap
renditions are named with a random UUID, process ID and timestamp, and the
icon's facet points at part 220 in some runs and 245 in others. The layered
renditions are the same every run.

Appearances are a key attribute (7), named in an `APPEARANCEKEYS` tree (an
ordinary tree like `FACETKEYS`: name to little-endian u16):

| value | name |
|---|---|
| 0 | `NSAppearanceNameSystem` |
| 1 | `NSAppearanceNameDarkAqua` |
| 8 | `NSAppearanceNameAqua` |
| 10 | `ISAppearanceTintable` |

An icon named `N` is a set of renditions, all element 85:

- **Stack** (part 245, one per appearance 1, 8 and 10), named `N.iconstack`,
  1024×1024, scale 100, pixel format `DATA`, layout `0x3fb`, payload an empty
  `RAWD` (`DWAR`, version 0, length 0). Info `0x3ed` is the type,
  `public.layeredimage` (u32 length including NUL, u32 0, string). Its layers
  are the background fill, then one per group.
- **Group** (part 246, one per appearance), named `IconGroup`, size 0, layout
  `0x3fc`, same empty payload. Its layers are images.
- **Layer image** (part 181): an SVG (as a vector rendition, named
  `image.svg`) or a bitmap (as an image rendition, named `image.png`).
- **Colors** (part 217) as `COLR` with a color space: `srgb` 1, `gray` 2,
  `display-p3` 3, `extended-srgb` 4, `extended-gray` 6 (actool rejects any
  other, such as `extended-display-p3`). Components are rounded to three
  decimals as `printf("%.3f")` does (ties to even), stored as single
  precision widened to double. Matching this matters: the system's rendering
  of the full-precision values differs by about one level out of 255.
- **Gradients** (part 247), layout `0x3fd`: `GRA` magic `ARGG`, version 2,
  u32 1, u32 0, f32 start x, start y, stop x, stop y (unit square, y down),
  then two stops of f32 location and a length-prefixed, NUL-terminated color
  name.

The dark stack's fill is always a gradient `N_Assets/system-dark`, gray 0.192
to gray 0.078 (space 2) from (0.5, 0) to (0.5, 1). The light and tintable
stacks use the icon's fill: a gradient, a color, or extended-gray white (1, 1)
when the icon has none.

Stack and group carry four info records, each `u32 count, u32 0` followed by
one entry per layer, bottom-most first (groups in reverse `icon.json` order):

- `0x3f4`, 48 bytes each: u32 0, i32 x, y, width, height (points on the 1024
  canvas, y down; all 0 for full-canvas entries in the stack), u32 blend mode
  (`CGBlendMode` numbering), f32 opacity, u32 16, and a rendition key of what
  the layer draws as (attribute, value) u16 pairs: (1, 85), (2, part),
  (17, identifier), (0, 0). A group's position is applied to its layers'
  frames; the stack's entry for the group carries the group's opacity.
- `0x3fc`, variable: for an image layer, u32 glass (1 on, the default when
  `icon.json` omits it), u32 0, and a length-prefixed fill color name (`""`
  when the layer keeps its own colors). For a group in the stack, u32
  lighting (2 individual, 0 combined), f32 blur material, and `""`. The fill
  entry is u32 0, u32 0, `""`.
- `0x3fd`, 20 bytes each: for a group in the stack, u32 specular, f32
  translucency (0 when off; default 0.3), u32 shadow kind (0 none, 2 layer
  color, 3 neutral; default neutral), f32 shadow opacity (default 0.5), u32 0.
  Zero for every other entry.
- `0x3fe`, 12 bytes each, all zero in every variant tried.

actool also writes flattened bitmaps of the icon (part 220, with a size
attribute 9 and a packed atlas, plus a part 218 multisize set) and an
`.icns`; the system does not need them to draw the layered icon. CarKit keeps
writing an `.icns`, as `CFBundleIconFile`, for systems that predate layered
icons.

## Open questions

- Whether compression 2 means anything distinct (uncompressed data decodes
  the same as with 0).
- Appearance variants of ordinary color and image sets (dark mode).
- `0x3fe`'s purpose, the `0x3fc`/`0x3f4` fields that are always 0, and
  per-appearance specializations in `icon.json` (`*-specializations`), which
  CarKit ignores.
- iOS: the same renditions are presumably what iOS 26 uses, but xtool still
  gives iOS apps a flat PNG icon.
