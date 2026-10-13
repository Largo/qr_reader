# frozen_string_literal: true

module QrReader
  module Formats
    module JPEG2000
      # Tier-1 decoder (ITU-T T.800 Annex C and D): the MQ arithmetic
      # decoder and the three coding passes of EBCOT (significance
      # propagation, magnitude refinement, cleanup) with all code-block style
      # options (selective arithmetic coding bypass, context reset,
      # termination on each pass, vertically causal contexts, predictable
      # termination, segmentation symbols).
      #
      # Coefficients are kept like OpenJPEG does: as signed integers scaled
      # by two, so that the bit below the last decoded bit-plane can hold
      # the reconstruction offset of one half.
      #
      # State flags: one Integer per column of a four-row stripe (with a
      # border of one column and one stripe all around), laid out like
      # OpenJPEG's t1 flags so that every context is one shift and one
      # table lookup. For row r (0..3) of the stripe, bits 3r..3r+8 are the
      # significance of its 3x3 neighbourhood (NW N NE W self E SW S SE);
      # bits 18 + 3r' hold the signs, 20 + 3r "refined", 21 + 3r "visited
      # in this bit-plane".
      #
      # The pass methods inline the MQ decoder (C.3.2) at every decision:
      # this is the hottest code of the JPEG 2000 decoder and a method call
      # per decision would cost more than the decision itself.
      class Tier1
        # Qe, next MPS, next LPS and switch flag of the 47 MQ states
        # (Table C.2).
        MQ_TABLE = [
          [0x5601, 1, 1, 1], [0x3401, 2, 6, 0], [0x1801, 3, 9, 0], [0x0AC1, 4, 12, 0],
          [0x0521, 5, 29, 0], [0x0221, 38, 33, 0], [0x5601, 7, 6, 1], [0x5401, 8, 14, 0],
          [0x4801, 9, 14, 0], [0x3801, 10, 14, 0], [0x3001, 11, 17, 0], [0x2401, 12, 18, 0],
          [0x1C01, 13, 20, 0], [0x1601, 29, 21, 0], [0x5601, 15, 14, 1], [0x5401, 16, 14, 0],
          [0x5101, 17, 15, 0], [0x4801, 18, 16, 0], [0x3801, 19, 17, 0], [0x3401, 20, 18, 0],
          [0x3001, 21, 19, 0], [0x2801, 22, 19, 0], [0x2401, 23, 20, 0], [0x2201, 24, 21, 0],
          [0x1C01, 25, 22, 0], [0x1801, 26, 23, 0], [0x1601, 27, 24, 0], [0x1401, 28, 25, 0],
          [0x1201, 29, 26, 0], [0x1101, 30, 27, 0], [0x0AC1, 31, 28, 0], [0x09C1, 32, 29, 0],
          [0x08A1, 33, 30, 0], [0x0521, 34, 31, 0], [0x0441, 35, 32, 0], [0x02A1, 36, 33, 0],
          [0x0221, 37, 34, 0], [0x0141, 38, 35, 0], [0x0111, 39, 36, 0], [0x0085, 40, 37, 0],
          [0x0049, 41, 38, 0], [0x0025, 42, 39, 0], [0x0015, 43, 40, 0], [0x0009, 44, 41, 0],
          [0x0005, 45, 42, 0], [0x0001, 45, 43, 0], [0x5601, 46, 46, 0]
        ].freeze

        # A context state is 2 * state index + MPS; these give its Qe and
        # the state after an MPS or LPS decision (MPS switch included).
        QE = Array.new(94) { |s| MQ_TABLE[s >> 1][0] }.freeze
        NMPS = Array.new(94) { |s| (MQ_TABLE[s >> 1][1] << 1) | (s & 1) }.freeze
        NLPS = Array.new(94) do |s|
          row = MQ_TABLE[s >> 1]
          (row[2] << 1) | (row[3] == 1 ? 1 - (s & 1) : s & 1)
        end.freeze

        # Initial context states (D.7, Table D.7): all 0 except the uniform
        # context (state 46), run-length (state 3) and zero-coding 0 (state 4).
        INITIAL_CONTEXTS = Array.new(19, 0).tap do |c|
          c[18] = 92
          c[17] = 6
          c[0] = 8
        end.freeze

        CTX_RL = 17
        CTX_UNI = 18

        class << self
          # Zero-coding context (Table D.1) of a 9-bit neighbourhood for
          # subband orientation +orient+ (0 LL, 1 HL, 2 LH, 3 HH).
          def zero_context(f, orient)
            h = (f >> 3 & 1) + (f >> 5 & 1)
            v = (f >> 1 & 1) + (f >> 7 & 1)
            d = (f & 1) + (f >> 2 & 1) + (f >> 6 & 1) + (f >> 8 & 1)
            h, v = v, h if orient == 1 # HL: horizontally high-pass
            if orient == 3
              hv = h + v
              return [0, 1, 2][[hv, 2].min] if d.zero?
              return [3, 4, 5][[hv, 2].min] if d == 1
              return hv.zero? ? 6 : 7 if d == 2

              8
            elsif h.zero?
              return [0, 1, 2][[d, 2].min] if v.zero?

              v == 1 ? 3 : 4
            elsif h == 1
              return d.zero? ? 5 : 6 if v.zero?

              7
            else
              8
            end
          end

          # [horizontal, vertical] sign contribution of a sign-context index
          # (bits: 0 W sign, 1 N sig, 2 E sign, 3 W sig, 4 N sign, 5 E sig,
          # 6 S sign, 7 S sig).
          def sign_contributions(lu)
            contribution = lambda do |sig_a, sgn_a, sig_b, sgn_b|
              pos = [(lu[sig_a] == 1 && lu[sgn_a].zero? ? 1 : 0) + (lu[sig_b] == 1 && lu[sgn_b].zero? ? 1 : 0), 1].min
              neg = [(lu[sig_a] == 1 && lu[sgn_a] == 1 ? 1 : 0) + (lu[sig_b] == 1 && lu[sgn_b] == 1 ? 1 : 0), 1].min
              pos - neg
            end
            [contribution.call(5, 2, 3, 0), contribution.call(1, 4, 7, 6)]
          end
        end

        # Zero-coding contexts: index (orient << 9) | neighbourhood.
        ZC_LUT = Array.new(2048) { |i| zero_context(i & 0x1FF, i >> 9) }.freeze

        # Sign-coding context (Table D.3) per sign-context index.
        SC_LUT = Array.new(256) do |lu|
          hc, vc = sign_contributions(lu)
          hc, vc = -hc, -vc if hc.negative?
          9 + (hc.zero? ? (vc.zero? ? 0 : 1) : vc + 3)
        end.freeze

        # Sign prediction (the XOR bit of Table D.3) per sign-context index.
        SPB_LUT = Array.new(256) do |lu|
          hc, vc = sign_contributions(lu)
          hc.negative? || (hc.zero? && vc.negative?) ? 1 : 0
        end.freeze

        # Bits of the flags words.
        SIGMA_THIS = 0x10
        NEIGHBOURS = 0x1EF
        CHI_THIS_I = 19
        MU_THIS = 1 << 20
        PI_THIS = 1 << 21
        UNVISITED_INSIGNIFICANT = PI_THIS | SIGMA_THIS
        # Significance of the four rows of a stripe.
        ANY_SIGNIFICANT = 0x2490
        # Visited flags of the four rows.
        PI_ALL = (1 << 21) | (1 << 24) | (1 << 27) | (1 << 30)

        STYLE_BYPASS = 1
        STYLE_RESET = 2
        STYLE_VSC = 8
        STYLE_SEGSYM = 0x20

        # The coefficients of the last decoded code-block (w * h Integers,
        # row-major, scaled by two).
        attr_reader :data

        def initialize
          @data = []
          @flags = []
          @ctx = INITIAL_CONTEXTS.dup
        end

        # Decodes one code-block of +w+ x +h+ coefficients from +segments+
        # ([[bytes, passes], ...]) with +numbps+ magnitude bit-planes, ROI
        # shift +roishift+, subband +orient+ (0 LL, 1 HL, 2 LH, 3 HH) and
        # code-block +style+ flags. Returns #data.
        def decode(w, h, segments, numbps, roishift, orient, style)
          n = w * h
          data = @data
          data.fill(0, 0, n)
          stride = w + 2
          @flags.fill(0, 0, stride * (((h + 3) >> 2) + 2))
          @ctx.replace(INITIAL_CONTEXTS)
          bpno = roishift + numbps
          return data if bpno <= 0

          passtype = 2
          bypass = style & STYLE_BYPASS != 0
          reset = style & STYLE_RESET != 0
          vsc = style & STYLE_VSC != 0
          segsym = style & STYLE_SEGSYM != 0
          zoff = orient << 9
          si = 0
          while si < segments.size && bpno >= 1
            bytes, passes = segments[si]
            raw = bypass && passtype < 2 && bpno <= numbps - 4
            raw ? init_raw(bytes) : init_mq(bytes)
            passno = 0
            while passno < passes && bpno >= 1
              case passtype
              when 0 then raw ? sigpass_raw(w, h, bpno, vsc) : sigpass(w, h, bpno, zoff, vsc)
              when 1 then raw ? refpass_raw(w, h, bpno) : refpass(w, h, bpno)
              else cleanup(w, h, bpno, zoff, vsc, segsym)
              end
              @ctx.replace(INITIAL_CONTEXTS) if reset && !raw
              passtype += 1
              if passtype == 3
                passtype = 0
                bpno -= 1
              end
              passno += 1
            end
            si += 1
          end
          data
        end

        # Writes the last code-block's coefficients (+w+ x +h+) into +rows+
        # (an Array of row Arrays) at column +xo+, row +yo+: halved
        # (reversible) when +step+ is nil, else multiplied by +step+. ROI
        # coefficients (magnitude >= 2**roishift) are scaled down first.
        # Rows of +rows+ that are nil (all zero so far) are created
        # (+width+ zeros) when they receive a nonzero value.
        def store(rows, xo, yo, w, h, roishift, step, width)
          data = @data
          apply_roi(w * h, roishift) if roishift.positive?
          j = 0
          di = 0
          while j < h
            # All-zero rows (counted at C speed) need no work.
            unless data[di, w].count(0) == w
              if step
                store_row_scaled(data, rows, yo + j, di, xo, w, step, width)
              else
                store_row_halved(data, rows, yo + j, di, xo, w, width)
              end
            end
            di += w
            j += 1
          end
        end

        private

        def apply_roi(n, shift)
          data = @data
          thresh = 1 << (shift + 1)
          i = 0
          while i < n
            v = data[i]
            if v >= thresh
              data[i] = v >> shift
            elsif -v >= thresh
              data[i] = -((-v) >> shift)
            end
            i += 1
          end
        end

        def store_row_halved(data, rows, ri, di, x, w, width)
          row = rows[ri]
          stop = di + w
          while di < stop
            v = data[di]
            if v != 0
              row ||= (rows[ri] = Array.new(width, 0))
              row[x] = v.negative? ? -((-v) >> 1) : v >> 1
            end
            di += 1
            x += 1
          end
        end

        def store_row_scaled(data, rows, ri, di, x, w, step, width)
          row = rows[ri]
          stop = di + w
          while di < stop
            v = data[di]
            if v != 0
              row ||= (rows[ri] = Array.new(width, 0.0))
              row[x] = v * step
            end
            di += 1
            x += 1
          end
        end

        def init_mq(bytes)
          buf = bytes + "\xFF\xFF".b
          c = buf.getbyte(0) << 16
          bp = 0
          # BYTEIN (C.3.4) once, then INITDEC's shift by 7.
          b = buf.getbyte(1)
          if buf.getbyte(0) == 0xFF
            if b > 0x8F
              c += 0xFF00
              ct = 8
            else
              bp = 1
              c += b << 9
              ct = 7
            end
          else
            bp = 1
            c += b << 8
            ct = 8
          end
          @buf = buf
          @bp = bp
          @c = c << 7
          @ct = ct - 7
          @a = 0x8000
        end

        def init_raw(bytes)
          @buf = bytes + "\xFF\xFF".b
          @bp = 0
          @c = 0
          @ct = 0
        end

        # Significance propagation pass (D.3.1), MQ coded.
        def sigpass(w, h, bpno, zoff, vsc)
          fl = @flags
          data = @data
          ctx = @ctx
          buf = @buf
          bp = @bp
          a = @a
          c = @c
          ct = @ct
          one = 1 << bpno
          oneplushalf = one | (one >> 1)
          stride = w + 2
          row_fi = stride + 1
          k = 0
          while k < h
            nr = h - k
            nr = 4 if nr > 4
            fi = row_fi
            col_di = k * w
            stop = row_fi + w
            while fi < stop
              f = fl[fi]
              if f != 0
                ci = 0
                di = col_di
                while ci < nr
                  sh = 3 * ci
                  fs = f >> sh
                  if fs & UNVISITED_INSIGNIFICANT == 0 && fs & NEIGHBOURS != 0
                    cx = ZC_LUT[zoff | (fs & NEIGHBOURS)]
                    # --- MQ decode (cx) -> d
                    s = ctx[cx]
                    q = QE[s]
                    a -= q
                    if (c >> 16) < q
                      if a < q
                        d = s & 1
                        ctx[cx] = NMPS[s]
                      else
                        d = (s & 1) ^ 1
                        ctx[cx] = NLPS[s]
                      end
                      a = q
                    else
                      c -= q << 16
                      if a < 0x8000
                        if a < q
                          d = (s & 1) ^ 1
                          ctx[cx] = NLPS[s]
                        else
                          d = s & 1
                          ctx[cx] = NMPS[s]
                        end
                      else
                        d = s & 1
                      end
                    end
                    while a < 0x8000
                      if ct.zero?
                        if buf.getbyte(bp) == 0xFF
                          b = buf.getbyte(bp + 1)
                          if b > 0x8F
                            c += 0xFF00
                            ct = 8
                          else
                            bp += 1
                            c += b << 9
                            ct = 7
                          end
                        else
                          bp += 1
                          c += buf.getbyte(bp) << 8
                          ct = 8
                        end
                      end
                      a <<= 1
                      c <<= 1
                      ct -= 1
                    end
                    # ---
                    if d == 1
                      # Sign context (D.3.2).
                      lu = (fs & 0xAA) | ((fl[fi - 1] >> (CHI_THIS_I + sh)) & 1) |
                           ((fl[fi + 1] >> (CHI_THIS_I - 2 + sh)) & 4) |
                           ((fs >> 16) & 64)
                      lu |= ci.zero? ? (f >> 14) & 16 : (f >> (12 + sh)) & 16
                      cx = SC_LUT[lu]
                      # --- MQ decode (cx) -> d
                      s = ctx[cx]
                      q = QE[s]
                      a -= q
                      if (c >> 16) < q
                        if a < q
                          d = s & 1
                          ctx[cx] = NMPS[s]
                        else
                          d = (s & 1) ^ 1
                          ctx[cx] = NLPS[s]
                        end
                        a = q
                      else
                        c -= q << 16
                        if a < 0x8000
                          if a < q
                            d = (s & 1) ^ 1
                            ctx[cx] = NLPS[s]
                          else
                            d = s & 1
                            ctx[cx] = NMPS[s]
                          end
                        else
                          d = s & 1
                        end
                      end
                      while a < 0x8000
                        if ct.zero?
                          if buf.getbyte(bp) == 0xFF
                            b = buf.getbyte(bp + 1)
                            if b > 0x8F
                              c += 0xFF00
                              ct = 8
                            else
                              bp += 1
                              c += b << 9
                              ct = 7
                            end
                          else
                            bp += 1
                            c += buf.getbyte(bp) << 8
                            ct = 8
                          end
                        end
                        a <<= 1
                        c <<= 1
                        ct -= 1
                      end
                      # ---
                      sign = d ^ SPB_LUT[lu]
                      data[di] = sign == 1 ? -oneplushalf : oneplushalf
                      # Significance update of the neighbourhood.
                      fl[fi - 1] |= 0x20 << sh
                      f |= ((sign << CHI_THIS_I) | SIGMA_THIS) << sh
                      fl[fi + 1] |= 0x8 << sh
                      if ci.zero?
                        unless vsc
                          north = fi - stride
                          fl[north] |= (sign << 31) | 0x10000
                          fl[north - 1] |= 0x20000
                          fl[north + 1] |= 0x8000
                        end
                      elsif ci == 3
                        south = fi + stride
                        fl[south] |= (sign << 18) | 2
                        fl[south - 1] |= 4
                        fl[south + 1] |= 1
                      end
                    end
                    f |= PI_THIS << sh
                  end
                  ci += 1
                  di += w
                end
                fl[fi] = f
              end
              fi += 1
              col_di += 1
            end
            k += 4
            row_fi += stride
          end
          @bp = bp
          @a = a
          @c = c
          @ct = ct
        end

        # Magnitude refinement pass (D.3.3), MQ coded.
        def refpass(w, h, bpno)
          fl = @flags
          data = @data
          ctx = @ctx
          buf = @buf
          bp = @bp
          a = @a
          c = @c
          ct = @ct
          poshalf = (1 << bpno) >> 1
          stride = w + 2
          row_fi = stride + 1
          k = 0
          while k < h
            nr = h - k
            nr = 4 if nr > 4
            fi = row_fi
            col_di = k * w
            stop = row_fi + w
            while fi < stop
              f = fl[fi]
              if f & ANY_SIGNIFICANT != 0
                ci = 0
                di = col_di
                while ci < nr
                  sh = 3 * ci
                  fs = f >> sh
                  if fs & UNVISITED_INSIGNIFICANT == SIGMA_THIS
                    cx = if fs & MU_THIS != 0
                           16
                         else
                           fs & NEIGHBOURS != 0 ? 15 : 14
                         end
                    # --- MQ decode (cx) -> d
                    s = ctx[cx]
                    q = QE[s]
                    a -= q
                    if (c >> 16) < q
                      if a < q
                        d = s & 1
                        ctx[cx] = NMPS[s]
                      else
                        d = (s & 1) ^ 1
                        ctx[cx] = NLPS[s]
                      end
                      a = q
                    else
                      c -= q << 16
                      if a < 0x8000
                        if a < q
                          d = (s & 1) ^ 1
                          ctx[cx] = NLPS[s]
                        else
                          d = s & 1
                          ctx[cx] = NMPS[s]
                        end
                      else
                        d = s & 1
                      end
                    end
                    while a < 0x8000
                      if ct.zero?
                        if buf.getbyte(bp) == 0xFF
                          b = buf.getbyte(bp + 1)
                          if b > 0x8F
                            c += 0xFF00
                            ct = 8
                          else
                            bp += 1
                            c += b << 9
                            ct = 7
                          end
                        else
                          bp += 1
                          c += buf.getbyte(bp) << 8
                          ct = 8
                        end
                      end
                      a <<= 1
                      c <<= 1
                      ct -= 1
                    end
                    # ---
                    v = data[di]
                    if v.negative?
                      data[di] = d == 1 ? v - poshalf : v + poshalf
                    else
                      data[di] = d == 1 ? v + poshalf : v - poshalf
                    end
                    f |= MU_THIS << sh
                  end
                  ci += 1
                  di += w
                end
                fl[fi] = f
              end
              fi += 1
              col_di += 1
            end
            k += 4
            row_fi += stride
          end
          @bp = bp
          @a = a
          @c = c
          @ct = ct
        end

        # Cleanup pass (D.3.4) with run-length coding; resets the visited
        # flags. Decodes the segmentation symbol when +segsym+.
        def cleanup(w, h, bpno, zoff, vsc, segsym)
          fl = @flags
          data = @data
          ctx = @ctx
          buf = @buf
          bp = @bp
          a = @a
          c = @c
          ct = @ct
          one = 1 << bpno
          oneplushalf = one | (one >> 1)
          stride = w + 2
          row_fi = stride + 1
          k = 0
          while k < h
            nr = h - k
            nr = 4 if nr > 4
            fi = row_fi
            col_di = k * w
            stop = row_fi + w
            while fi < stop
              f = fl[fi]
              ci = 0
              di = col_di
              # Run-length mode: four insignificant coefficients without
              # significant neighbours.
              runlength = f.zero? && nr == 4
              if runlength
                cx = CTX_RL
                # --- MQ decode (cx) -> d
                s = ctx[cx]
                q = QE[s]
                a -= q
                if (c >> 16) < q
                  if a < q
                    d = s & 1
                    ctx[cx] = NMPS[s]
                  else
                    d = (s & 1) ^ 1
                    ctx[cx] = NLPS[s]
                  end
                  a = q
                else
                  c -= q << 16
                  if a < 0x8000
                    if a < q
                      d = (s & 1) ^ 1
                      ctx[cx] = NLPS[s]
                    else
                      d = s & 1
                      ctx[cx] = NMPS[s]
                    end
                  else
                    d = s & 1
                  end
                end
                while a < 0x8000
                  if ct.zero?
                    if buf.getbyte(bp) == 0xFF
                      b = buf.getbyte(bp + 1)
                      if b > 0x8F
                        c += 0xFF00
                        ct = 8
                      else
                        bp += 1
                        c += b << 9
                        ct = 7
                      end
                    else
                      bp += 1
                      c += buf.getbyte(bp) << 8
                      ct = 8
                    end
                  end
                  a <<= 1
                  c <<= 1
                  ct -= 1
                end
                # ---
                if d.zero?
                  fi += 1
                  col_di += 1
                  next
                end
                # Two uniform-context symbols give the first significant row.
                run = 0
                rn = 0
                while rn < 2
                  cx = CTX_UNI
                  # --- MQ decode (cx) -> d
                  s = ctx[cx]
                  q = QE[s]
                  a -= q
                  if (c >> 16) < q
                    if a < q
                      d = s & 1
                      ctx[cx] = NMPS[s]
                    else
                      d = (s & 1) ^ 1
                      ctx[cx] = NLPS[s]
                    end
                    a = q
                  else
                    c -= q << 16
                    if a < 0x8000
                      if a < q
                        d = (s & 1) ^ 1
                        ctx[cx] = NLPS[s]
                      else
                        d = s & 1
                        ctx[cx] = NMPS[s]
                      end
                    else
                      d = s & 1
                    end
                  end
                  while a < 0x8000
                    if ct.zero?
                      if buf.getbyte(bp) == 0xFF
                        b = buf.getbyte(bp + 1)
                        if b > 0x8F
                          c += 0xFF00
                          ct = 8
                        else
                          bp += 1
                          c += b << 9
                          ct = 7
                        end
                      else
                        bp += 1
                        c += buf.getbyte(bp) << 8
                        ct = 8
                      end
                    end
                    a <<= 1
                    c <<= 1
                    ct -= 1
                  end
                  # ---
                  run = (run << 1) | d
                  rn += 1
                end
                ci = run
                di += run * w
              end
              while ci < nr
                sh = 3 * ci
                fs = f >> sh
                if runlength
                  # The run's first significant coefficient: no zero coding.
                  runlength = false
                  d = 1
                elsif fs & UNVISITED_INSIGNIFICANT == 0
                  cx = ZC_LUT[zoff | (fs & NEIGHBOURS)]
                  # --- MQ decode (cx) -> d
                  s = ctx[cx]
                  q = QE[s]
                  a -= q
                  if (c >> 16) < q
                    if a < q
                      d = s & 1
                      ctx[cx] = NMPS[s]
                    else
                      d = (s & 1) ^ 1
                      ctx[cx] = NLPS[s]
                    end
                    a = q
                  else
                    c -= q << 16
                    if a < 0x8000
                      if a < q
                        d = (s & 1) ^ 1
                        ctx[cx] = NLPS[s]
                      else
                        d = s & 1
                        ctx[cx] = NMPS[s]
                      end
                    else
                      d = s & 1
                    end
                  end
                  while a < 0x8000
                    if ct.zero?
                      if buf.getbyte(bp) == 0xFF
                        b = buf.getbyte(bp + 1)
                        if b > 0x8F
                          c += 0xFF00
                          ct = 8
                        else
                          bp += 1
                          c += b << 9
                          ct = 7
                        end
                      else
                        bp += 1
                        c += buf.getbyte(bp) << 8
                        ct = 8
                      end
                    end
                    a <<= 1
                    c <<= 1
                    ct -= 1
                  end
                  # ---
                else
                  d = 0
                end
                if d == 1
                  lu = (fs & 0xAA) | ((fl[fi - 1] >> (CHI_THIS_I + sh)) & 1) |
                       ((fl[fi + 1] >> (CHI_THIS_I - 2 + sh)) & 4) |
                       ((fs >> 16) & 64)
                  lu |= ci.zero? ? (f >> 14) & 16 : (f >> (12 + sh)) & 16
                  cx = SC_LUT[lu]
                  # --- MQ decode (cx) -> d
                  s = ctx[cx]
                  q = QE[s]
                  a -= q
                  if (c >> 16) < q
                    if a < q
                      d = s & 1
                      ctx[cx] = NMPS[s]
                    else
                      d = (s & 1) ^ 1
                      ctx[cx] = NLPS[s]
                    end
                    a = q
                  else
                    c -= q << 16
                    if a < 0x8000
                      if a < q
                        d = (s & 1) ^ 1
                        ctx[cx] = NLPS[s]
                      else
                        d = s & 1
                        ctx[cx] = NMPS[s]
                      end
                    else
                      d = s & 1
                    end
                  end
                  while a < 0x8000
                    if ct.zero?
                      if buf.getbyte(bp) == 0xFF
                        b = buf.getbyte(bp + 1)
                        if b > 0x8F
                          c += 0xFF00
                          ct = 8
                        else
                          bp += 1
                          c += b << 9
                          ct = 7
                        end
                      else
                        bp += 1
                        c += buf.getbyte(bp) << 8
                        ct = 8
                      end
                    end
                    a <<= 1
                    c <<= 1
                    ct -= 1
                  end
                  # ---
                  sign = d ^ SPB_LUT[lu]
                  data[di] = sign == 1 ? -oneplushalf : oneplushalf
                  fl[fi - 1] |= 0x20 << sh
                  f |= ((sign << CHI_THIS_I) | SIGMA_THIS) << sh
                  fl[fi + 1] |= 0x8 << sh
                  if ci.zero?
                    unless vsc
                      north = fi - stride
                      fl[north] |= (sign << 31) | 0x10000
                      fl[north - 1] |= 0x20000
                      fl[north + 1] |= 0x8000
                    end
                  elsif ci == 3
                    south = fi + stride
                    fl[south] |= (sign << 18) | 2
                    fl[south - 1] |= 4
                    fl[south + 1] |= 1
                  end
                end
                ci += 1
                di += w
              end
              fl[fi] = f & ~PI_ALL
              fi += 1
              col_di += 1
            end
            k += 4
            row_fi += stride
          end
          @bp = bp
          @a = a
          @c = c
          @ct = ct
          segmentation_symbol if segsym
        end

        # Decodes (and ignores) the four segmentation symbols.
        def segmentation_symbol
          4.times { mq_decode(CTX_UNI) }
        end

        # One MQ decision outside the hot loops.
        def mq_decode(cx)
          ctx = @ctx
          buf = @buf
          bp = @bp
          a = @a
          c = @c
          ct = @ct
          s = ctx[cx]
          q = QE[s]
          a -= q
          if (c >> 16) < q
            if a < q
              d = s & 1
              ctx[cx] = NMPS[s]
            else
              d = (s & 1) ^ 1
              ctx[cx] = NLPS[s]
            end
            a = q
          else
            c -= q << 16
            if a < 0x8000
              if a < q
                d = (s & 1) ^ 1
                ctx[cx] = NLPS[s]
              else
                d = s & 1
                ctx[cx] = NMPS[s]
              end
            else
              d = s & 1
            end
          end
          while a < 0x8000
            if ct.zero?
              if buf.getbyte(bp) == 0xFF
                b = buf.getbyte(bp + 1)
                if b > 0x8F
                  c += 0xFF00
                  ct = 8
                else
                  bp += 1
                  c += b << 9
                  ct = 7
                end
              else
                bp += 1
                c += buf.getbyte(bp) << 8
                ct = 8
              end
            end
            a <<= 1
            c <<= 1
            ct -= 1
          end
          @bp = bp
          @a = a
          @c = c
          @ct = ct
          d
        end

        # One raw (bypass) bit (D.6).
        def raw_bit
          ct = @ct
          if ct.zero?
            if @c == 0xFF
              b = @buf.getbyte(@bp)
              if b > 0x8F
                @c = 0xFF
                ct = 8
              else
                @c = b
                @bp += 1
                ct = 7
              end
            else
              @c = @buf.getbyte(@bp)
              @bp += 1
              ct = 8
            end
          end
          ct -= 1
          @ct = ct
          (@c >> ct) & 1
        end

        # Significance propagation pass, raw coded (bypass mode).
        def sigpass_raw(w, h, bpno, vsc)
          fl = @flags
          data = @data
          one = 1 << bpno
          oneplushalf = one | (one >> 1)
          stride = w + 2
          row_fi = stride + 1
          k = 0
          while k < h
            nr = h - k
            nr = 4 if nr > 4
            fi = row_fi
            col_di = k * w
            stop = row_fi + w
            while fi < stop
              f = fl[fi]
              if f != 0
                ci = 0
                di = col_di
                while ci < nr
                  sh = 3 * ci
                  fs = f >> sh
                  if fs & UNVISITED_INSIGNIFICANT == 0 && fs & NEIGHBOURS != 0
                    if raw_bit == 1
                      sign = raw_bit
                      data[di] = sign == 1 ? -oneplushalf : oneplushalf
                      fl[fi - 1] |= 0x20 << sh
                      f |= ((sign << CHI_THIS_I) | SIGMA_THIS) << sh
                      fl[fi + 1] |= 0x8 << sh
                      if ci.zero?
                        unless vsc
                          north = fi - stride
                          fl[north] |= (sign << 31) | 0x10000
                          fl[north - 1] |= 0x20000
                          fl[north + 1] |= 0x8000
                        end
                      elsif ci == 3
                        south = fi + stride
                        fl[south] |= (sign << 18) | 2
                        fl[south - 1] |= 4
                        fl[south + 1] |= 1
                      end
                    end
                    f |= PI_THIS << sh
                  end
                  ci += 1
                  di += w
                end
                fl[fi] = f
              end
              fi += 1
              col_di += 1
            end
            k += 4
            row_fi += stride
          end
        end

        # Magnitude refinement pass, raw coded (bypass mode).
        def refpass_raw(w, h, bpno)
          fl = @flags
          data = @data
          poshalf = (1 << bpno) >> 1
          stride = w + 2
          row_fi = stride + 1
          k = 0
          while k < h
            nr = h - k
            nr = 4 if nr > 4
            fi = row_fi
            col_di = k * w
            stop = row_fi + w
            while fi < stop
              f = fl[fi]
              if f & ANY_SIGNIFICANT != 0
                ci = 0
                di = col_di
                while ci < nr
                  sh = 3 * ci
                  if (f >> sh) & UNVISITED_INSIGNIFICANT == SIGMA_THIS
                    d = raw_bit
                    v = data[di]
                    if v.negative?
                      data[di] = d == 1 ? v - poshalf : v + poshalf
                    else
                      data[di] = d == 1 ? v + poshalf : v - poshalf
                    end
                    f |= MU_THIS << sh
                  end
                  ci += 1
                  di += w
                end
                fl[fi] = f
              end
              fi += 1
              col_di += 1
            end
            k += 4
            row_fi += stride
          end
        end
      end
    end
  end
end
