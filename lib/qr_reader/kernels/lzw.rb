# frozen_string_literal: true

# LZW kernel shared by TIFF (compression 5) and PDF (LZWDecode). Kernel
# files are plain Ruby in the subset that Spinel compiles (see DESIGN.md,
# "Kernels").
#
# The code table holds no Strings: every entry is a stretch of the output
# decoded so far (the previous code's output plus the first byte of the
# output that followed it), so an entry is an offset and a length, and
# decoding a code copies that stretch.
module QrReaderKernels
  # Codes decoded per lzw_batch call (YJIT compiles methods, not loops).
  LZW_BATCH = 4096
  # Entries up to this length are copied byte by byte, longer ones with
  # byteslice (cheaper than allocating a slice for a few bytes).
  LZW_SHORT = 3

  # Decodes LZW data (codes of 9 to 12 bits, Clear 256, EOI 257) into at
  # most +limit+ bytes. +early_change+ is 1 when the code width grows one
  # code early (TIFF, PDF's default EarlyChange 1) or 0; +lsb_first+ reads
  # codes least significant bit first (the old TIFF variant). Decoding
  # stops at EOI, at the end of the data, at +limit+ bytes and at the
  # first invalid code, keeping what was decoded before.
  # spinel-sample: QrReaderKernels.lzw_decode("\x80\x0b\x60\x50\x22\x0c\x0c\x85\x01".b, 100, 1, false)
  def self.lzw_decode(data, limit, early_change, lsb_first)
    out = lzw_buffer
    return out if limit <= 0

    src = data + "\0\0\0\0"
    offsets = Array.new(4096, 0)
    lengths = Array.new(4096, 0)
    # [bit position, next byte, bit buffer, bits in the buffer, code
    # width, next code, previous output's offset and length (0: no
    # previous code), 1 when done]
    state = [0, 0, 0, 0, 9, 258, 0, 0, 0]
    nbits = data.bytesize * 8
    while state[8] == 0 && out.bytesize < limit
      out << lzw_batch(src, nbits, out, offsets, lengths, state, early_change, lsb_first, limit - out.bytesize)
    end
    out.bytesize > limit ? out.byteslice(0, limit) : out
  end

  # An empty binary String (a helper: YJIT side-exits on the keyword call).
  def self.lzw_buffer
    String.new(capacity: 256, encoding: Encoding::BINARY)
  end

  # Decodes up to LZW_BATCH codes and returns their output. +out+ is the
  # output so far (read only: table entries point into it), +state+ is
  # updated in place.
  def self.lzw_batch(src, nbits, out, offsets, lengths, state, early, lsb_first, room)
    chunk = lzw_buffer
    base = out.bytesize
    pos = state[0]
    i = state[1]
    bits = state[2]
    nb = state[3]
    width = state[4]
    nxt = state[5]
    prev_off = state[6]
    prev_len = state[7]
    mask = (1 << width) - 1
    done = 0
    n = LZW_BATCH
    while n > 0
      if pos + width > nbits || chunk.bytesize >= room
        done = 1
        break
      end
      if lsb_first
        while nb < width
          bits |= src.getbyte(i) << nb
          i += 1
          nb += 8
        end
        code = bits & mask
        bits >>= width
      else
        while nb < width
          bits = ((bits << 8) | src.getbyte(i)) & 0xFFFFFF
          i += 1
          nb += 8
        end
        code = (bits >> (nb - width)) & mask
      end
      nb -= width
      pos += width
      if code == 256
        nxt = 258
        width = 9
        mask = 511
        prev_len = 0
      elsif code == 257
        done = 1
        break
      else
        start = base + chunk.bytesize
        if code < 256
          chunk << code
        else
          if prev_len == 0 || code > nxt
            # A code that is not in the table (yet).
            done = 1
            break
          end
          if code < nxt
            off = offsets[code]
            len = lengths[code]
            extra = -1
          else
            # The code being defined: the previous output plus its first byte.
            off = prev_off
            len = prev_len
            extra = off >= base ? chunk.getbyte(off - base) : out.getbyte(off)
          end
          # Copy the entry's stretch of output: +out+, then +chunk+ from
          # offset +base+ on.
          if off >= base
            j = off - base
            if len <= LZW_SHORT
              stop = j + len
              while j < stop
                chunk << chunk.getbyte(j)
                j += 1
              end
            else
              # (A slice reaching the end of a String that grows later
              # shares its buffer, and the next append copies it all.)
              chunk << chunk.byteslice(j, len - 1) << chunk.getbyte(j + len - 1)
            end
          elsif off + len <= base
            if len <= LZW_SHORT
              stop = off + len
              while off < stop
                chunk << out.getbyte(off)
                off += 1
              end
            else
              chunk << out.byteslice(off, len - 1) << out.getbyte(off + len - 1)
            end
          else
            head = base - off
            chunk << out.byteslice(off, head - 1) << out.getbyte(base - 1)
            chunk << chunk.byteslice(0, len - head - 1) << chunk.getbyte(len - head - 1)
          end
          chunk << extra if extra >= 0
        end
        if prev_len > 0 && nxt < 4096
          offsets[nxt] = prev_off
          lengths[nxt] = prev_len + 1
          nxt += 1
        end
        prev_off = start
        prev_len = base + chunk.bytesize - start
        if width < 12 && nxt + early > mask
          width += 1
          mask = (1 << width) - 1
        end
      end
      n -= 1
    end
    state[0] = pos
    state[1] = i
    state[2] = bits
    state[3] = nb
    state[4] = width
    state[5] = nxt
    state[6] = prev_off
    state[7] = prev_len
    state[8] = done
    chunk
  end
end
