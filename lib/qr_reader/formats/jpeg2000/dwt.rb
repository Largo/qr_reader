# frozen_string_literal: true

module QrReader
  module Formats
    module JPEG2000
      # Inverse discrete wavelet transform (ITU-T T.800 Annex F): one
      # synthesis level at a time from the four subbands, by lifting with
      # periodic symmetric extension. The parity of the resolution's first
      # coordinate (+cas+) says whether its first sample is low-pass (0) or
      # high-pass (1), as in the standard's 1D_SR procedure. Rows are
      # transformed first, then columns (like OpenJPEG).
      #
      # Planes are Arrays of row Arrays. Columns are lifted as whole rows
      # (no gathering), and the subbands' rows are reused for the output.
      # The lifting steps are pipelined: step k runs a fixed lag behind
      # step k-1, so one loop applies all of them (2 for 5/3, 4 for 9/7)
      # while the operands are in local variables; only the first and last
      # few samples, where the symmetric extension mirrors, take the
      # generic path.
      #
      # The 9/7 synthesis omits the K / (2/K) scaling of the lifting
      # scheme: the decoder folds those factors into the dequantization
      # step sizes (see DWT.scale_factor), saving a multiplication per
      # sample and level.
      module DWT
        f32 = ->(v) { [v].pack("e").unpack1("e") }
        # 9/7 lifting constants (Table F.4) as the single-precision values
        # OpenJPEG uses, whose output is the reference; OpenJPEG scales
        # high-pass samples by 1.625732422 instead of 2/K and compensates in
        # the step sizes.
        ALPHA = f32.call(-1.586134342)
        BETA = f32.call(-0.052980118)
        GAMMA = f32.call(0.882911075)
        DELTA = f32.call(0.443506852)
        K = f32.call(1.230174105)
        TWO_INV_K = f32.call(1.625732422)

        # The four 9/7 synthesis steps: t += c * (s[i + o] + s[i + o + 1]).
        COEFFS97 = [-DELTA, -GAMMA, -BETA, -ALPHA].freeze

        module_function

        # The factor by which the 9/7 synthesis would scale a subband in
        # one direction: +high+ is whether the band is high-pass in this
        # direction at its own level, +sizes+ the sizes (width or height) of
        # the resolutions from the band's own level up to the decoded one.
        # Levels of size 1 are not scaled (like OpenJPEG).
        def scale_factor(high, sizes)
          factor = 1.0
          sizes.each_with_index do |n, i|
            next if n <= 1

            factor *= i.zero? && high ? TWO_INV_K : K
          end
          factor
        end

        # One synthesis level: +ll+ (sn_y rows of sn_x), +hl+ (sn_y x
        # dn_x), +lh+ (dn_y x sn_x) and +hh+ (dn_y x dn_x) become the next
        # resolution's +rw+ x +rh+ rows. +cas_x+ / +cas_y+ are the parities
        # of its x0 / y0. Subband rows may be nil: all zero (never written by
        # tier-1). Rows with zero high-pass input take shortcuts (exact: the
        # skipped terms are zero). Consumed subband rows are released.
        def synthesize(ll, hl, lh, hh, rw, rh, sn_x, sn_y, cas_x, cas_y, reversible)
          dn_x = rw - sn_x
          dn_y = rh - sn_y
          zero = reversible ? 0 : 0.0
          perm = interleave_order(sn_x, dn_x, cas_x)
          lows = Array.new(sn_y)
          i = 0
          while i < sn_y
            high = hl[i]
            lows[i] = horizontal(ll[i] || Array.new(sn_x, zero), high || Array.new(dn_x, zero), sn_x, dn_x, cas_x,
                                 reversible, perm, !high.nil?)
            ll[i] = hl[i] = nil
            i += 1
          end
          highs = Array.new(dn_y)
          zero_rows = Array.new(dn_y, false)
          i = 0
          while i < dn_y
            low = lh[i]
            high = hh[i]
            if low.nil? && high.nil?
              zero_rows[i] = true # stays nil: an all-zero row
            else
              highs[i] = horizontal(low || Array.new(sn_x, zero), high || Array.new(dn_x, zero), sn_x, dn_x, cas_x,
                                    reversible, perm, !high.nil?)
              lh[i] = hh[i] = nil
            end
            i += 1
          end
          vertical(lows, highs, sn_y, dn_y, rw, cas_y, reversible, zero_rows)
        end

        # Indices into low + high that give the interleaved row.
        def interleave_order(sn, dn, cas)
          Array.new(sn + dn) do |k|
            if (k + cas).even?
              (k - cas) >> 1
            else
              sn + ((k - 1 + cas) >> 1)
            end
          end
        end

        # Horizontal synthesis of one row: +low+ (sn samples) and +high+
        # (dn samples) are lifted in place and returned interleaved.
        # +high_nonzero+ false says that +high+ is all zero.
        def horizontal(low, high, sn, dn, cas, reversible, perm, high_nonzero = true)
          n = sn + dn
          if n <= 1
            if cas == 1 && dn == 1
              v = high[0]
              v = v.negative? ? -(-v / 2) : v / 2 if reversible
              return [v]
            end
            return low
          end
          if reversible
            high_nonzero ? lift53(low, high, sn, dn, cas) : predict53_only(low, high, sn, dn, cas)
          else
            lift97(low, high, sn, dn, cas, high_nonzero)
          end
          # Interleaved in place (the row keeps its storage; high is dropped).
          low.replace(low.concat(high).values_at(*perm))
          high.clear # frees its storage now (it would wait for a major GC)
          low
        end

        # Lags of the pipelined steps behind step 1 (see the module notes).
        def lags(cas, reversible)
          if reversible
            cas.zero? ? [0, 1] : [0, 0]
          else
            cas.zero? ? [0, 1, 1, 2] : [0, 0, 1, 1]
          end
        end

        # First wavefront after the pipelined interior.
        def interior_end(sn, dn, cas)
          cas.zero? ? [sn, dn].min : [sn, dn - 1].min
        end

        # 9/7 lifting of one row (low and high samples separately). With
        # all-zero high samples step 1 changes nothing and is skipped.
        def lift97(l, h, sn, dn, cas, high_nonzero = true)
          lag = lags(cas, false)
          last = [sn - 1 + lag[2], dn - 1 + lag[3]].max
          ge = interior_end(sn, dn, cas)
          lo = cas.zero? ? -1 : 0
          ho = cas.zero? ? 0 : -1
          g = 0
          while g <= last
            if g >= 2 && g < ge
              if high_nonzero
                cas.zero? ? fused97_cas0(l, h, g, ge) : fused97_cas1(l, h, g, ge)
              else
                cas.zero? ? fused97z_cas0(l, h, g, ge) : fused97z_cas1(l, h, g, ge)
              end
              g = ge
              next
            end
            k = high_nonzero ? 0 : 1
            while k < 4
              i = g - lag[k]
              if k.even?
                step_at(l, h, dn, i, lo, COEFFS97[k]) if i >= 0 && i < sn
              elsif i >= 0 && i < dn
                step_at(h, l, sn, i, ho, COEFFS97[k])
              end
              k += 1
            end
            g += 1
          end
        end

        # t[i] += c * (s[i + o] + s[i + o + 1]), indices mirrored into s.
        def step_at(t, s, ns, i, o, c)
          j = i + o
          j1 = j + 1
          last = ns - 1
          j = 0 if j.negative?
          j = last if j > last
          j1 = last if j1 > last
          t[i] += c * (s[j] + s[j1])
        end

        # Wavefronts g...ge of the 9/7 steps for cas 0, operands carried in
        # locals (see the module notes).
        def fused97_cas0(l, h, g, ge)
          c1 = -DELTA
          c2 = -GAMMA
          c3 = -BETA
          c4 = -ALPHA
          hm1 = h[g - 1]
          lm1 = l[g - 1]
          hm2 = h[g - 2]
          lm2 = l[g - 2]
          while g < ge
            hg = h[g]
            a = l[g] + c1 * (hm1 + hg)
            b = hm1 + c2 * (lm1 + a)
            d = lm1 + c3 * (hm2 + b)
            h[g - 2] = hm2 + c4 * (lm2 + d)
            l[g - 1] = d
            lm2 = d
            hm2 = b
            lm1 = a
            hm1 = hg
            g += 1
          end
          l[ge - 1] = lm1
          h[ge - 2] = hm2
        end

        def fused97_cas1(l, h, g, ge)
          c1 = -DELTA
          c2 = -GAMMA
          c3 = -BETA
          c4 = -ALPHA
          hc = h[g]
          lm1 = l[g - 1]
          hm1 = h[g - 1]
          lm2 = l[g - 2]
          while g < ge
            hn = h[g + 1]
            a = l[g] + c1 * (hc + hn)
            b = hc + c2 * (lm1 + a)
            d = lm1 + c3 * (hm1 + b)
            h[g - 1] = hm1 + c4 * (lm2 + d)
            l[g - 1] = d
            lm2 = d
            hm1 = b
            lm1 = a
            hc = hn
            g += 1
          end
          l[ge - 1] = lm1
          h[ge - 1] = hm1
        end

        # fused97_cas0 for all-zero high input (step 1 is the identity).
        def fused97z_cas0(l, h, g, ge)
          c2 = -GAMMA
          c3 = -BETA
          c4 = -ALPHA
          lm1 = l[g - 1]
          hm2 = h[g - 2]
          lm2 = l[g - 2]
          while g < ge
            a = l[g]
            b = c2 * (lm1 + a)
            d = lm1 + c3 * (hm2 + b)
            h[g - 2] = hm2 + c4 * (lm2 + d)
            l[g - 1] = d
            lm2 = d
            hm2 = b
            lm1 = a
            g += 1
          end
          h[ge - 2] = hm2
        end

        def fused97z_cas1(l, h, g, ge)
          c2 = -GAMMA
          c3 = -BETA
          c4 = -ALPHA
          lm1 = l[g - 1]
          hm1 = h[g - 1]
          lm2 = l[g - 2]
          while g < ge
            a = l[g]
            b = c2 * (lm1 + a)
            d = lm1 + c3 * (hm1 + b)
            h[g - 1] = hm1 + c4 * (lm2 + d)
            l[g - 1] = d
            lm2 = d
            hm1 = b
            lm1 = a
            g += 1
          end
          h[ge - 1] = hm1
        end

        # 5/3 synthesis of a row whose high samples are all zero: the update
        # step is the identity, the predict step reads low samples only.
        def predict53_only(l, h, sn, dn, cas)
          last = sn - 1
          i = 0
          if cas.zero?
            while i < dn
              j1 = i + 1
              j1 = last if j1 > last
              h[i] = (l[i] + l[j1]) >> 1
              i += 1
            end
          else
            while i < dn
              j = i - 1
              j = 0 if j.negative?
              j1 = i
              j1 = last if j1 > last
              h[i] = (l[j] + l[j1]) >> 1
              i += 1
            end
          end
        end

        # 5/3 lifting of one row.
        def lift53(l, h, sn, dn, cas)
          lag = lags(cas, true)
          last = [sn - 1, dn - 1 + lag[1]].max
          ge = interior_end(sn, dn, cas)
          lo = cas.zero? ? -1 : 0
          ho = cas.zero? ? 0 : -1
          g = 0
          while g <= last
            if g >= 1 && g < ge
              cas.zero? ? fused53_cas0(l, h, g, ge) : fused53_cas1(l, h, g, ge)
              g = ge
              next
            end
            update53_at(l, h, dn, g, lo) if g < sn
            i = g - lag[1]
            predict53_at(h, l, sn, i, ho) if i >= 0 && i < dn
            g += 1
          end
        end

        def update53_at(t, s, ns, i, o)
          j = i + o
          j1 = j + 1
          last = ns - 1
          j = 0 if j.negative?
          j = last if j > last
          j1 = last if j1 > last
          t[i] -= (s[j] + s[j1] + 2) >> 2
        end

        def predict53_at(t, s, ns, i, o)
          j = i + o
          j1 = j + 1
          last = ns - 1
          j = 0 if j.negative?
          j = last if j > last
          j1 = last if j1 > last
          t[i] += (s[j] + s[j1]) >> 1
        end

        def fused53_cas0(l, h, g, ge)
          hm1 = h[g - 1]
          lm1 = l[g - 1]
          while g < ge
            hg = h[g]
            a = l[g] - ((hm1 + hg + 2) >> 2)
            h[g - 1] = hm1 + ((lm1 + a) >> 1)
            l[g] = a
            lm1 = a
            hm1 = hg
            g += 1
          end
        end

        def fused53_cas1(l, h, g, ge)
          hc = h[g]
          lm1 = l[g - 1]
          while g < ge
            hn = h[g + 1]
            a = l[g] - ((hc + hn + 2) >> 2)
            h[g] = hc + ((lm1 + a) >> 1)
            l[g] = a
            lm1 = a
            hc = hn
            g += 1
          end
        end

        # Vertical synthesis of whole rows; returns the interleaved rows.
        # +zero_rows+ flags high rows that are all zero (given as nil).
        def vertical(lows, highs, sn, dn, width, cas, reversible, zero_rows = nil)
          n = sn + dn
          if zero_rows
            zero = reversible ? 0 : 0.0
            i = 0
            while i < dn
              highs[i] ||= Array.new(width, zero)
              i += 1
            end
          end
          if n <= 1
            if cas == 1 && dn == 1
              row = highs[0]
              halve_row(row, width) if reversible
              return [row]
            end
            return lows
          end
          if reversible
            rows53(lows, highs, sn, dn, cas, width, zero_rows)
          else
            rows97(lows, highs, sn, dn, cas, width, zero_rows)
          end
          out = Array.new(n)
          i = 0
          while i < sn
            out[2 * i + cas] = lows[i]
            i += 1
          end
          i = 0
          while i < dn
            out[2 * i + 1 - cas] = highs[i]
            i += 1
          end
          out
        end

        # The 9/7 steps on rows, pipelined like lift97.
        def rows97(l, h, sn, dn, cas, width, zero_rows = nil)
          lag = lags(cas, false)
          last = [sn - 1 + lag[2], dn - 1 + lag[3]].max
          ge = interior_end(sn, dn, cas)
          lo = cas.zero? ? -1 : 0
          ho = cas.zero? ? 0 : -1
          g = 0
          while g <= last
            if g >= 2 && g < ge
              if cas.zero?
                if zero_rows && zero_rows[g - 1] && zero_rows[g]
                  row_fused97z(l[g], h[g - 1], l[g - 1], h[g - 2], l[g - 2], width)
                else
                  row_fused97(l[g], h[g - 1], h[g], l[g - 1], h[g - 2], l[g - 2], width)
                end
              elsif zero_rows && zero_rows[g] && zero_rows[g + 1]
                row_fused97z(l[g], h[g], l[g - 1], h[g - 1], l[g - 2], width)
              else
                row_fused97(l[g], h[g], h[g + 1], l[g - 1], h[g - 1], l[g - 2], width)
              end
            else
              k = 0
              while k < 4
                i = g - lag[k]
                if k.even?
                  row_step(l, h, dn, i, lo, COEFFS97[k], width) if i >= 0 && i < sn
                elsif i >= 0 && i < dn
                  row_step(h, l, sn, i, ho, COEFFS97[k], width)
                end
                k += 1
              end
            end
            g += 1
          end
        end

        def row_step(t, s, ns, i, o, c, width)
          j = i + o
          j1 = j + 1
          last = ns - 1
          j = 0 if j.negative?
          j = last if j > last
          j1 = last if j1 > last
          row_axpy(t[i], s[j], s[j1], c, width)
        end

        # All four 9/7 steps of one wavefront on rows: a += c1 (b + c);
        # b += c2 (d + a); d += c3 (e + b); e += c4 (f + d).
        def row_fused97(ra, rb, rc, rd, re, rf, width)
          c1 = -DELTA
          c2 = -GAMMA
          c3 = -BETA
          c4 = -ALPHA
          x = 0
          while x < width
            b = rb[x]
            a = ra[x] + c1 * (b + rc[x])
            ra[x] = a
            d = rd[x]
            b += c2 * (d + a)
            rb[x] = b
            e = re[x]
            d += c3 * (e + b)
            rd[x] = d
            re[x] = e + c4 * (rf[x] + d)
            x += 1
          end
        end

        # row_fused97 when rows b and c are all zero (a is unchanged).
        def row_fused97z(ra, rb, rd, re, rf, width)
          c2 = -GAMMA
          c3 = -BETA
          c4 = -ALPHA
          x = 0
          while x < width
            d = rd[x]
            b = c2 * (d + ra[x])
            rb[x] = b
            e = re[x]
            d += c3 * (e + b)
            rd[x] = d
            re[x] = e + c4 * (rf[x] + d)
            x += 1
          end
        end

        def rows53(l, h, sn, dn, cas, width, zero_rows = nil)
          lag = lags(cas, true)
          last = [sn - 1, dn - 1 + lag[1]].max
          ge = interior_end(sn, dn, cas)
          lo = cas.zero? ? -1 : 0
          ho = cas.zero? ? 0 : -1
          g = 0
          while g <= last
            if g >= 1 && g < ge
              if cas.zero?
                if zero_rows && zero_rows[g - 1] && zero_rows[g]
                  row_average(h[g - 1], l[g - 1], l[g], width)
                else
                  row_fused53(l[g], h[g - 1], h[g], l[g - 1], width)
                end
              elsif zero_rows && zero_rows[g] && zero_rows[g + 1]
                row_average(h[g], l[g - 1], l[g], width)
              else
                row_fused53(l[g], h[g], h[g + 1], l[g - 1], width)
              end
            else
              row_step53(l, h, dn, g, lo, width, true) if g < sn
              i = g - lag[1]
              row_step53(h, l, sn, i, ho, width, false) if i >= 0 && i < dn
            end
            g += 1
          end
        end

        def row_step53(t, s, ns, i, o, width, update)
          j = i + o
          j1 = j + 1
          last = ns - 1
          j = 0 if j.negative?
          j = last if j > last
          j1 = last if j1 > last
          if update
            row_update53(t[i], s[j], s[j1], width)
          else
            row_predict53(t[i], s[j], s[j1], width)
          end
        end

        # Both 5/3 steps of one wavefront: a -= (b + c + 2) >> 2;
        # b += (d + a) >> 1.
        def row_fused53(ra, rb, rc, rd, width)
          x = 0
          while x < width
            b = rb[x]
            a = ra[x] - ((b + rc[x] + 2) >> 2)
            ra[x] = a
            rb[x] = b + ((rd[x] + a) >> 1)
            x += 1
          end
        end

        # t = (a + b) >> 1: the 5/3 wavefront when t and its neighbour
        # high row are zero (the update step is then the identity).
        def row_average(t, a, b, width)
          x = 0
          while x < width
            t[x] = (a[x] + b[x]) >> 1
            x += 1
          end
        end

        def row_axpy(t, a, b, c, width)
          x = 0
          while x < width
            t[x] += c * (a[x] + b[x])
            x += 1
          end
        end

        def row_update53(t, a, b, width)
          x = 0
          while x < width
            t[x] -= (a[x] + b[x] + 2) >> 2
            x += 1
          end
        end

        def row_predict53(t, a, b, width)
          x = 0
          while x < width
            t[x] += (a[x] + b[x]) >> 1
            x += 1
          end
        end

        def halve_row(row, width)
          x = 0
          while x < width
            v = row[x]
            row[x] = v.negative? ? -(-v / 2) : v / 2
            x += 1
          end
        end
      end
    end
  end
end
