# Spinel investigation

Native (Spinel-compiled) JPEG entropy decoding in qr_reader-native slows down
superlinearly with image size (`QrReaderKernels.jpeg_luma_keep` at scale 8,
YJIT host): 32 ms at 640x480, 282 ms at 1280x960, 2986 ms at 2560x1920; the
same Ruby runs in 68 / 25 / 83 ms. Native IDCT rendering of the same data is
linear (4 / 13 / 50 ms).

These standalone programs rule out the obvious String operations - all are
linear when compiled with `spinel FILE.rb`:

- append.rb: `<<` of bytes and of row Strings, `getbyte` on large Strings
- rows_setbyte.rb: `setbyte` into Strings kept in an Array instance variable
- byteindex.rb: `byteindex` + `byteslice` hopping through 0xFF bytes

k.rb holds the same checks as extension entries (strings passed from CRuby),
built with `ruby script/spinel_ext.rb OUT --require bench/spinel/k.rb --sample
'QrReaderKernels.count_ff("\x00\xFF".b)' ...`; also linear.

The remaining suspect is the Huffman decoding loop itself
(lib/qr_reader/kernels/jpeg.rb, JpegDecoder); `spinel-reduce` on a program
that calls `QrReaderKernels.jpeg_luma_keep` on a 2560x1920 JPEG is the next step.
