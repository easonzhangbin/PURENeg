Independent TIFF codec fixtures generated with Pillow 13.0.0 (not this project's
writer). They contain synthetic samples only, no photographs or private data.

Sample generator starts with seed=77 and updates it once per sample:
  seed = (1664525 * seed + 1013904223) mod 2^32
  8-bit value = seed >> 24; 16-bit value = seed >> 16

8-bit files: 97 x 83 interleaved RGB.
16-bit files: 37 x 31 grayscale.
The be file is big-endian; the others are native little-endian.
Pillow compression names: tiff_lzw, packbits, tiff_adobe_deflate.

These fixtures exercise a separate encoder, including LZW code-size growth and
dictionary clears, so round-trip tests cannot conceal matching reader/writer bugs.
