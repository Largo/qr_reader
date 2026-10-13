# frozen_string_literal: true

module QrReader
  module Formats
    module PDF
      # Glyph outlines of embedded font programs (TrueType, CFF, Type 1),
      # enough to draw text set in a barcode font: each glyph becomes closed
      # polygons (flat [x0, y0, x1, y1, ...] Arrays in glyph units, curves
      # flattened). Hinting is ignored. Corrupt programs raise ImageError
      # (via INTERNAL_ERRORS at the caller) or yield no outline.
      module FontPrograms
        # Line segments per curve.
        CURVE_STEPS = 4
        # Interpreter limits per glyph (subroutine nesting, operators run,
        # points made) and composite glyph nesting.
        MAX_CALL_DEPTH = 10
        MAX_OPERATORS = 50_000
        MAX_POINTS = 20_000
        MAX_COMPONENT_DEPTH = 8

        # Collects contours (flat point Arrays) from moveto/lineto/curveto.
        class Pen
          attr_reader :polys

          def initialize
            @polys = []
            @current = nil
            @points = 0
            @x = @y = 0.0
          end

          attr_reader :x, :y

          # Moves the current point without starting a contour.
          def set_point(x, y)
            @x = x.to_f
            @y = y.to_f
          end

          def move_to(x, y)
            close
            @x = x.to_f
            @y = y.to_f
            @current = [@x, @y]
          end

          def line_to(x, y)
            move_to(@x, @y) unless @current
            @x = x.to_f
            @y = y.to_f
            add(@x, @y)
          end

          def curve_to(x1, y1, x2, y2, x3, y3)
            move_to(@x, @y) unless @current
            x0 = @x
            y0 = @y
            i = 1
            while i <= CURVE_STEPS
              t = i.to_f / CURVE_STEPS
              u = 1 - t
              a = u * u * u
              b = 3 * u * u * t
              c = 3 * u * t * t
              d = t * t * t
              add(a * x0 + b * x1 + c * x2 + d * x3, a * y0 + b * y1 + c * y2 + d * y3)
              i += 1
            end
            @x = x3.to_f
            @y = y3.to_f
          end

          def quad_to(x1, y1, x2, y2)
            x0 = @x
            y0 = @y
            curve_to(x0 + 2.0 / 3 * (x1 - x0), y0 + 2.0 / 3 * (y1 - y0),
                     x2 + 2.0 / 3 * (x1 - x2), y2 + 2.0 / 3 * (y1 - y2), x2, y2)
          end

          def close
            @polys << @current if @current && @current.size >= 6
            @current = nil
          end

          private

          def add(x, y)
            raise ImageError, "font glyph has too many points" if (@points += 1) > MAX_POINTS

            @current << x << y
          end
        end

        # Big-endian readers over a binary String.
        module Bytes
          module_function

          def u8(d, o) = d.getbyte(o) || raise(ImageError, "font data ends early")

          def u16(d, o) = (u8(d, o) << 8) | u8(d, o + 1)

          def s16(d, o)
            v = u16(d, o)
            v >= 0x8000 ? v - 0x10000 : v
          end

          def u32(d, o) = (u16(d, o) << 16) | u16(d, o + 2)

          def s32(d, o)
            v = u32(d, o)
            v >= 0x80000000 ? v - 0x100000000 : v
          end
        end

        # A TrueType (or OpenType) font: glyph outlines from 'glyf', advance
        # widths from 'hmtx', character maps from 'cmap'. An OpenType font
        # with CFF outlines answers #cff instead.
        class TrueType
          include Bytes

          attr_reader :units_per_em, :cff

          def initialize(data)
            @data = data
            @tables = {}
            count = u16(data, 4)
            raise ImageError, "TrueType font without tables" if count.zero? || count > 512

            count.times do |i|
              rec = 12 + i * 16
              tag = data.byteslice(rec, 4)
              offset = u32(data, rec + 8)
              length = u32(data, rec + 12)
              @tables[tag] = [offset, length] if offset + length <= data.bytesize
            end
            head = table("head") or raise ImageError, "TrueType font without a head table"
            @units_per_em = u16(data, head + 18)
            @units_per_em = 1000 if @units_per_em < 16
            @long_loca = s16(data, head + 50) == 1
            @num_glyphs = (maxp = table("maxp")) ? u16(data, maxp + 4) : 0
            @cff = (offset = table("CFF ")) ? CFF.new(data.byteslice(offset, @tables["CFF "][1])) : nil
            @cmaps = {}
            read_cmaps
          end

          # Glyph index for character +code+ in the (platform, encoding)
          # cmap, or nil.
          def lookup(platform, encoding, code)
            cmap = @cmaps[[platform, encoding]] or return nil
            gid = cmap_lookup(cmap, code)
            gid&.positive? ? gid : nil
          end

          def cmap?(platform, encoding)
            @cmaps.key?([platform, encoding])
          end

          def glyph_count
            @num_glyphs
          end

          # Contours of glyph +gid+ in font units ([] for none).
          def outline(gid)
            return @cff.outline(gid) if @cff

            pen = Pen.new
            draw(gid, [1.0, 0.0, 0.0, 1.0, 0.0, 0.0], pen, 0)
            pen.close
            pen.polys
          end

          # Advance width of +gid+ in font units, or nil.
          def advance(gid)
            hhea = table("hhea") or return nil
            hmtx = table("hmtx") or return nil
            metrics = u16(@data, hhea + 34)
            return nil if metrics.zero?

            u16(@data, hmtx + 4 * (gid < metrics ? gid : metrics - 1))
          end

          private

          def u16(d, o) = Bytes.u16(d, o)
          def s16(d, o) = Bytes.s16(d, o)
          def u32(d, o) = Bytes.u32(d, o)

          def table(tag)
            @tables[tag]&.first
          end

          def read_cmaps
            cmap = table("cmap") or return
            count = u16(@data, cmap + 2)
            [count, 64].min.times do |i|
              rec = cmap + 4 + i * 8
              @cmaps[[u16(@data, rec), u16(@data, rec + 2)]] ||= cmap + u32(@data, rec + 4)
            end
          end

          def cmap_lookup(at, code)
            d = @data
            case u16(d, at)
            when 0
              code < 256 ? d.getbyte(at + 6 + code) : nil
            when 4
              segs = u16(d, at + 6) / 2
              ends = at + 14
              starts = ends + 2 * segs + 2
              deltas = starts + 2 * segs
              ranges = deltas + 2 * segs
              i = 0
              while i < segs
                if code <= u16(d, ends + 2 * i)
                  start = u16(d, starts + 2 * i)
                  return nil if code < start

                  range = u16(d, ranges + 2 * i)
                  delta = u16(d, deltas + 2 * i)
                  return (code + delta) & 0xFFFF if range.zero?

                  gid = u16(d, ranges + 2 * i + range + 2 * (code - start))
                  return gid.zero? ? nil : (gid + delta) & 0xFFFF
                end
                i += 1
              end
              nil
            when 6
              first = u16(d, at + 6)
              count = u16(d, at + 8)
              code >= first && code < first + count ? u16(d, at + 10 + 2 * (code - first)) : nil
            when 12
              groups = u32(d, at + 12)
              [groups, 100_000].min.times do |i|
                g = at + 16 + 12 * i
                start = u32(d, g)
                stop = u32(d, g + 4)
                return u32(d, g + 8) + code - start if code.between?(start, stop)
              end
              nil
            end
          end

          def glyph_range(gid)
            loca = table("loca") or return nil
            glyf = table("glyf") or return nil
            return nil if gid.negative? || gid >= @num_glyphs

            if @long_loca
              start = u32(@data, loca + 4 * gid)
              stop = u32(@data, loca + 4 * gid + 4)
            else
              start = 2 * u16(@data, loca + 2 * gid)
              stop = 2 * u16(@data, loca + 2 * gid + 2)
            end
            stop > start ? [glyf + start, glyf + stop] : nil
          end

          # Draws glyph +gid+ transformed by +m+ ([a b c d e f]) into +pen+.
          def draw(gid, m, pen, depth)
            range = glyph_range(gid) or return
            at = range.first
            contours = s16(@data, at)
            if contours.negative?
              composite(at + 10, m, pen, depth)
            else
              simple(at, contours, m, pen)
            end
          end

          def simple(at, contours, m, pen)
            d = @data
            ends = Array.new(contours) { |i| u16(d, at + 10 + 2 * i) }
            count = contours.zero? ? 0 : ends.last + 1
            raise ImageError, "TrueType glyph has too many points" if count > MAX_POINTS

            pos = at + 10 + 2 * contours
            pos += 2 + u16(d, pos) # instructions
            flags = []
            while flags.size < count
              f = Bytes.u8(d, pos)
              pos += 1
              flags << f
              next unless f & 8 != 0

              repeat = Bytes.u8(d, pos)
              pos += 1
              repeat.times { flags << f }
            end
            xs, pos = coordinates(flags, count, pos, 2, 16)
            ys, = coordinates(flags, count, pos, 4, 32)
            a, b, c, dd, e, f = m
            first = 0
            ends.each do |last|
              points = (first..last).map do |i|
                x = xs[i]
                y = ys[i]
                [a * x + c * y + e, b * x + dd * y + f, flags[i] & 1 != 0]
              end
              contour(points, pen)
              first = last + 1
            end
          end

          def coordinates(flags, count, pos, short_bit, same_bit)
            values = Array.new(count)
            v = 0
            i = 0
            while i < count
              f = flags[i]
              if f & short_bit != 0
                delta = Bytes.u8(@data, pos)
                pos += 1
                v += f & same_bit != 0 ? delta : -delta
              elsif f & same_bit == 0
                v += Bytes.s16(@data, pos)
                pos += 2
              end
              values[i] = v
              i += 1
            end
            [values, pos]
          end

          # One quadratic contour (on/off-curve points) into +pen+.
          def contour(points, pen)
            return if points.size < 2

            start = points.index { |p| p[2] }
            if start
              points = points.rotate(start)
              sx, sy = points[0]
            else # all off-curve: start between the first two
              sx = (points[0][0] + points[1][0]) / 2
              sy = (points[0][1] + points[1][1]) / 2
              points = [[sx, sy, true]] + points
            end
            pen.move_to(sx, sy)
            control = nil
            (points.drop(1) + [[sx, sy, true]]).each do |x, y, on|
              if on
                control ? pen.quad_to(control[0], control[1], x, y) : pen.line_to(x, y)
                control = nil
              elsif control
                mx = (control[0] + x) / 2
                my = (control[1] + y) / 2
                pen.quad_to(control[0], control[1], mx, my)
                control = [x, y]
              else
                control = [x, y]
              end
            end
            pen.close
          end

          def composite(pos, m, pen, depth)
            raise ImageError, "TrueType composite glyphs nested too deeply" if depth > MAX_COMPONENT_DEPTH

            d = @data
            loop do
              flags = u16(d, pos)
              gid = u16(d, pos + 2)
              pos += 4
              if flags & 1 != 0
                dx = s16(d, pos)
                dy = s16(d, pos + 2)
                pos += 4
              else
                dx = Bytes.u8(d, pos)
                dy = Bytes.u8(d, pos + 1)
                dx -= 256 if dx >= 128
                dy -= 256 if dy >= 128
                pos += 2
              end
              dx = dy = 0 if flags & 2 == 0 # point matching: not supported
              a = dd = 1.0
              b = c = 0.0
              if flags & 8 != 0
                a = dd = s16(d, pos) / 16_384.0
                pos += 2
              elsif flags & 0x40 != 0
                a = s16(d, pos) / 16_384.0
                dd = s16(d, pos + 2) / 16_384.0
                pos += 4
              elsif flags & 0x80 != 0
                a = s16(d, pos) / 16_384.0
                b = s16(d, pos + 2) / 16_384.0
                c = s16(d, pos + 4) / 16_384.0
                dd = s16(d, pos + 6) / 16_384.0
                pos += 8
              end
              ma, mb, mc, md, me, mf = m
              child = [a * ma + b * mc, a * mb + b * md, c * ma + dd * mc, c * mb + dd * md,
                       dx * ma + dy * mc + me, dx * mb + dy * md + mf]
              draw(gid, child, pen, depth + 1)
              break if flags & 0x20 == 0
            end
          end
        end

        # A CFF font (bare, as in /FontFile3 /Type1C or /CIDFontType0C, or
        # the 'CFF ' table of an OpenType font) with Type 2 charstrings.
        class CFF
          include Bytes

          attr_reader :font_matrix

          def initialize(data)
            @data = data
            pos = Bytes.u8(data, 2)
            _names, pos = index(pos)
            tops, pos = index(pos)
            @strings, pos = index(pos)
            @global_subrs, = index(pos)
            top = dict(tops.first || raise(ImageError, "CFF font without a Top DICT"))
            @font_matrix = top[1207] || [0.001, 0.0, 0.0, 0.001, 0.0, 0.0]
            @charstrings, = index(int(top[17]) || raise(ImageError, "CFF font without CharStrings"))
            @cid = top.key?(1230)
            if @cid
              fds, = index(int(top[1236]) || raise(ImageError, "CID CFF font without FDArray"))
              @privates = fds.map { |fd| private_dict(dict(fd)) }
              @fd_select = fd_select(int(top[1237]))
            else
              @privates = [private_dict(top)]
            end
            @charset = charset(int(top[15]) || 0)
            @encoding = encoding(int(top[16]) || 0)
          end

          def cid?
            @cid
          end

          def glyph_count
            @charstrings.size
          end

          # Glyph index by glyph name (non-CID fonts) or CID (CID fonts).
          def gid_for_name(name)
            @names ||= @charset.each_with_index.to_h { |sid, gid| [string(sid), gid] }
            @names[name]
          end

          def gid_for_cid(cid)
            @cids ||= @charset.each_with_index.to_h { |c, gid| [c, gid] }
            @cids[cid]
          end

          # The font's built-in encoding: code -> gid.
          def gid_for_code(code)
            @encoding[code]
          end

          def outline(gid)
            data = @charstrings[gid] or return []
            fd = @fd_select ? @fd_select[gid] || 0 : 0
            priv = @privates[fd] || @privates.first
            Type2.new(data, @global_subrs, priv[:subrs]).run
          end

          def advance(gid)
            data = @charstrings[gid] or return nil
            fd = @fd_select ? @fd_select[gid] || 0 : 0
            priv = @privates[fd] || @privates.first
            interpreter = Type2.new(data, @global_subrs, priv[:subrs])
            interpreter.run
            w = interpreter.width
            w ? priv[:nominal] + w : priv[:default]
          end

          private

          def string(sid)
            return FontTables::CFF_STANDARD_STRINGS[sid] if sid < 391

            @strings[sid - 391]
          end

          def int(value)
            value.is_a?(Array) ? value.last&.to_i : value&.to_i
          end

          # [Array of item Strings, position after the INDEX].
          def index(pos)
            count = u16(@data, pos)
            return [[], pos + 2] if count.zero?

            size = Bytes.u8(@data, pos + 2)
            raise ImageError, "invalid CFF INDEX" unless size.between?(1, 4)

            offsets = Array.new(count + 1) { |i| offset(pos + 3 + i * size, size) }
            base = pos + 2 + (count + 1) * size
            items = Array.new(count) do |i|
              start = offsets[i]
              stop = offsets[i + 1]
              raise ImageError, "invalid CFF INDEX" if start < 1 || stop < start

              @data.byteslice(base + start, stop - start) || ""
            end
            [items, base + offsets.last]
          end

          def offset(pos, size)
            v = 0
            size.times { |i| v = (v << 8) | Bytes.u8(@data, pos + i) }
            v
          end

          # DICT data -> {operator => operands (Array) or single operand}.
          def dict(data)
            out = {}
            operands = []
            pos = 0
            while pos < data.bytesize
              b = data.getbyte(pos)
              if b <= 21
                op = b
                pos += 1
                if b == 12
                  op = 1200 + data.getbyte(pos).to_i
                  pos += 1
                end
                out[op] = operands.size == 1 ? operands[0] : operands
                operands = []
              elsif b == 28
                operands << Bytes.s16(data, pos + 1)
                pos += 3
              elsif b == 29
                operands << Bytes.s32(data, pos + 1)
                pos += 5
              elsif b == 30
                value, pos = real(data, pos + 1)
                operands << value
              elsif b >= 32 && b <= 246
                operands << b - 139
                pos += 1
              elsif b >= 247 && b <= 250
                operands << (b - 247) * 256 + data.getbyte(pos + 1).to_i + 108
                pos += 2
              elsif b >= 251 && b <= 254
                operands << -(b - 251) * 256 - data.getbyte(pos + 1).to_i - 108
                pos += 2
              else
                pos += 1
              end
            end
            out
          end

          def real(data, pos)
            text = +""
            loop do
              b = data.getbyte(pos) or break
              pos += 1
              done = false
              [b >> 4, b & 15].each do |n|
                case n
                when 0..9 then text << n.to_s
                when 0xA then text << "."
                when 0xB then text << "E"
                when 0xC then text << "E-"
                when 0xE then text << "-"
                when 0xF then done = true
                end
                break if done
              end
              break if done
            end
            [text.to_f, pos]
          end

          def private_dict(top)
            size, offset = top[18]
            priv = size && offset ? dict(@data.byteslice(offset, size) || "") : {}
            subrs = []
            if (rel = int(priv[19]))
              subrs, = index(offset + rel)
            end
            { subrs: subrs, default: (priv[20].is_a?(Numeric) ? priv[20] : 0),
              nominal: (priv[21].is_a?(Numeric) ? priv[21] : 0) }
          end

          # gid -> SID (or CID).
          def charset(offset)
            count = @charstrings.size
            return Array.new(count) { |i| i } if offset <= 2 # ISOAdobe (and the expert sets, approximately)

            out = [0]
            format = Bytes.u8(@data, offset)
            pos = offset + 1
            while out.size < count
              case format
              when 0
                out << u16(@data, pos)
                pos += 2
              when 1, 2
                first = u16(@data, pos)
                left = format == 1 ? Bytes.u8(@data, pos + 2) : u16(@data, pos + 2)
                pos += format == 1 ? 3 : 4
                (left + 1).times { |i| out << first + i if out.size < count }
              else raise ImageError, "invalid CFF charset format #{format}"
              end
            end
            out
          end

          # code -> gid.
          def encoding(offset)
            out = {}
            if offset <= 1
              return out if offset == 1 || @cid

              # Standard encoding through the charset names.
              FontTables::STANDARD_ENCODING.each_with_index do |name, code|
                gid = name && gid_for_name(name)
                out[code] = gid if gid
              end
              return out
            end
            format = Bytes.u8(@data, offset)
            case format & 0x7F
            when 0
              n = Bytes.u8(@data, offset + 1)
              n.times { |i| out[Bytes.u8(@data, offset + 2 + i)] = i + 1 }
            when 1
              n = Bytes.u8(@data, offset + 1)
              gid = 1
              n.times do |i|
                first = Bytes.u8(@data, offset + 2 + 2 * i)
                left = Bytes.u8(@data, offset + 3 + 2 * i)
                (left + 1).times do |j|
                  out[first + j] = gid
                  gid += 1
                end
              end
            end
            out
          end

          def fd_select(offset)
            return nil unless offset

            count = @charstrings.size
            case Bytes.u8(@data, offset)
            when 0
              Array.new(count) { |i| Bytes.u8(@data, offset + 1 + i) }
            when 3
              ranges = u16(@data, offset + 1)
              out = Array.new(count, 0)
              ranges.times do |i|
                r = offset + 3 + 3 * i
                first = u16(@data, r)
                fd = Bytes.u8(@data, r + 2)
                stop = i + 1 < ranges ? u16(@data, r + 3) : u16(@data, offset + 3 + 3 * ranges)
                (first...[stop, count].min).each { |g| out[g] = fd }
              end
              out
            end
          end

          def u16(d, o) = Bytes.u16(d, o)
        end

        # Type 2 charstring interpreter (Adobe TN 5177) producing contours.
        class Type2
          attr_reader :width

          def initialize(data, global_subrs, local_subrs)
            @data = data
            @gsubrs = global_subrs
            @lsubrs = local_subrs
            @pen = Pen.new
            @stack = []
            @stems = 0
            @width = nil
            @first = true
            @ops = 0
            @transient = {}
          end

          def run
            exec(@data, 0)
            @pen.close
            @pen.polys
          end

          private

          def bias(subrs)
            n = subrs.size
            n < 1240 ? 107 : (n < 33_900 ? 1131 : 32_768)
          end

          # Takes the width argument off the stack at the first
          # stack-clearing operator when there is one more than +even+ says.
          def take_width(extra)
            return unless @first

            @first = false
            @width = @stack.shift if extra
          end

          def exec(code, depth)
            raise ImageError, "charstring subroutines nested too deeply" if depth > MAX_CALL_DEPTH

            pen = @pen
            s = @stack
            pos = 0
            while pos < code.bytesize
              raise ImageError, "charstring runs too long" if (@ops += 1) > MAX_OPERATORS

              b = code.getbyte(pos)
              pos += 1
              if b >= 32 || b == 28
                if b == 28
                  s << Bytes.s16(code, pos)
                  pos += 2
                elsif b <= 246
                  s << b - 139
                elsif b <= 250
                  s << (b - 247) * 256 + code.getbyte(pos).to_i + 108
                  pos += 1
                elsif b <= 254
                  s << -(b - 251) * 256 - code.getbyte(pos).to_i - 108
                  pos += 1
                else
                  s << Bytes.s32(code, pos) / 65_536.0
                  pos += 4
                end
                next
              end
              case b
              when 1, 3, 18, 23 # hstem vstem hstemhm vstemhm
                take_width(s.size.odd?)
                @stems += s.size / 2
                s.clear
              when 19, 20 # hintmask cntrmask
                take_width(s.size.odd?)
                @stems += s.size / 2
                s.clear
                pos += (@stems + 7) / 8
              when 21 # rmoveto
                take_width(s.size > 2)
                pen.move_to(pen.x + s[-2].to_f, pen.y + s[-1].to_f) if s.size >= 2
                s.clear
              when 22 # hmoveto
                take_width(s.size > 1)
                pen.move_to(pen.x + s[-1].to_f, pen.y) unless s.empty?
                s.clear
              when 4 # vmoveto
                take_width(s.size > 1)
                pen.move_to(pen.x, pen.y + s[-1].to_f) unless s.empty?
                s.clear
              when 5 # rlineto
                (s.size / 2).times { |i| pen.line_to(pen.x + s[2 * i], pen.y + s[2 * i + 1]) }
                s.clear
              when 6, 7 # hlineto vlineto
                horizontal = b == 6
                s.each do |v|
                  horizontal ? pen.line_to(pen.x + v, pen.y) : pen.line_to(pen.x, pen.y + v)
                  horizontal = !horizontal
                end
                s.clear
              when 8 # rrcurveto
                (s.size / 6).times { |i| rcurve(*s[6 * i, 6]) }
                s.clear
              when 24 # rcurveline
                n = (s.size - 2) / 6
                n.times { |i| rcurve(*s[6 * i, 6]) }
                pen.line_to(pen.x + s[6 * n], pen.y + s[6 * n + 1]) if s.size >= 6 * n + 2
                s.clear
              when 25 # rlinecurve
                n = (s.size - 6) / 2
                n.times { |i| pen.line_to(pen.x + s[2 * i], pen.y + s[2 * i + 1]) }
                rcurve(*s[2 * n, 6]) if s.size >= 2 * n + 6
                s.clear
              when 26 # vvcurveto
                dx1 = s.size.odd? ? s.shift : 0
                (s.size / 4).times do |i|
                  rcurve(i.zero? ? dx1 : 0, s[4 * i], s[4 * i + 1], s[4 * i + 2], 0, s[4 * i + 3])
                end
                s.clear
              when 27 # hhcurveto
                dy1 = s.size.odd? ? s.shift : 0
                (s.size / 4).times do |i|
                  rcurve(s[4 * i], i.zero? ? dy1 : 0, s[4 * i + 1], s[4 * i + 2], s[4 * i + 3], 0)
                end
                s.clear
              when 30, 31 # vhcurveto hvcurveto
                alternating(s, b == 31)
                s.clear
              when 10, 29 # callsubr callgsubr
                subrs = b == 10 ? @lsubrs : @gsubrs
                n = s.pop.to_i + bias(subrs)
                sub = subrs[n] or raise ImageError, "charstring calls a missing subroutine"
                return :endchar if exec(sub, depth + 1) == :endchar
              when 11 # return
                return nil
              when 14 # endchar
                take_width(s.size == 1 || s.size == 5)
                pen.close
                return :endchar
              when 12
                op = code.getbyte(pos).to_i
                pos += 1
                escape(op, s)
              else
                s.clear
              end
            end
            nil
          end

          def rcurve(dx1, dy1, dx2, dy2, dx3, dy3)
            pen = @pen
            x1 = pen.x + dx1
            y1 = pen.y + dy1
            x2 = x1 + dx2
            y2 = y1 + dy2
            pen.curve_to(x1, y1, x2, y2, x2 + dx3, y2 + dy3)
          end

          # hvcurveto (horizontal first) / vhcurveto.
          def alternating(s, horizontal)
            i = 0
            while s.size - i >= 4
              last = s.size - i == 5
              if horizontal
                rcurve(s[i], 0, s[i + 1], s[i + 2], last ? s[i + 4] : 0, s[i + 3])
              else
                rcurve(0, s[i], s[i + 1], s[i + 2], s[i + 3], last ? s[i + 4] : 0)
              end
              horizontal = !horizontal
              i += last ? 5 : 4
            end
          end

          def escape(op, s)
            case op
            when 35 # flex
              rcurve(*s[0, 6]) if s.size >= 12
              rcurve(*s[6, 6]) if s.size >= 12
            when 34 # hflex
              if s.size >= 7
                dx1, dx2, dy2, dx3, dx4, dx5, dx6 = s
                rcurve(dx1, 0, dx2, dy2, dx3, 0)
                rcurve(dx4, 0, dx5, -dy2, dx6, 0)
              end
            when 36 # hflex1
              if s.size >= 9
                dx1, dy1, dx2, dy2, dx3, dx4, dx5, dy5, dx6 = s
                rcurve(dx1, dy1, dx2, dy2, dx3, 0)
                rcurve(dx4, 0, dx5, dy5, dx6, -(dy1 + dy2 + dy5))
              end
            when 37 # flex1
              if s.size >= 11
                d = s[0, 10]
                dx = d[0] + d[2] + d[4] + d[6] + d[8]
                dy = d[1] + d[3] + d[5] + d[7] + d[9]
                rcurve(*d[0, 6])
                if dx.abs > dy.abs
                  rcurve(d[6], d[7], d[8], d[9], s[10], -dy)
                else
                  rcurve(d[6], d[7], d[8], d[9], -dx, s[10])
                end
              end
            when 3 then binary(s) { |a, b| a != 0 && b != 0 ? 1 : 0 }
            when 4 then binary(s) { |a, b| a != 0 || b != 0 ? 1 : 0 }
            when 5 then s << (s.pop.to_f.zero? ? 1 : 0)
            when 9 then s << s.pop.to_f.abs
            when 10 then binary(s) { |a, b| a + b }
            when 11 then binary(s) { |a, b| a - b }
            when 12 then binary(s) { |a, b| b.zero? ? 0 : a.to_f / b }
            when 14 then s << -s.pop.to_f
            when 15 then binary(s) { |a, b| a == b ? 1 : 0 }
            when 18 then s.pop
            when 20 then (v, i = s.pop(2)) && @transient[i.to_i] = v
            when 21 then s << (@transient[s.pop.to_i] || 0)
            when 22
              a, b, c, d = s.pop(4)
              s << (c.to_f <= d.to_f ? a : b)
            when 23 then s << 0.5
            when 24 then binary(s) { |a, b| a * b }
            when 26 then s << Math.sqrt(s.pop.to_f.abs)
            when 27 then s << s.last if s.last
            when 28
              a, b = s.pop(2)
              s.push(b, a) if b
            when 29
              i = s.pop.to_i
              s << (i.negative? ? s.last : s[-1 - i]) unless s.empty?
            when 30
              n, j = s.pop(2)
              n = n.to_i
              if n.positive? && n <= s.size
                part = s.pop(n).rotate(-j.to_i)
                s.concat(part)
              end
            else
              s.clear
              return
            end
            s.clear if [34, 35, 36, 37].include?(op)
          end

          def binary(s)
            b = s.pop.to_f
            a = s.pop.to_f
            s << yield(a, b)
          end
        end

        # A Type 1 font program (/FontFile): the clear-text part with the
        # encoding and font matrix, and the eexec-encrypted part with the
        # charstrings and subroutines.
        class Type1
          attr_reader :font_matrix, :encoding

          def initialize(data, clear_length = nil)
            eexec = data.index("eexec") or raise ImageError, "Type 1 font without eexec section"
            clear = data.byteslice(0, clear_length&.between?(1, data.bytesize) ? clear_length : eexec)
            @font_matrix = matrix(clear) || [0.001, 0.0, 0.0, 0.001, 0.0, 0.0]
            @encoding = parse_encoding(clear)
            start = eexec + 5
            start += 1 while start < data.bytesize && " \t\r\n".include?(data.byteslice(start, 1))
            private = decrypt(binary(data.byteslice(start, data.bytesize - start)), 55_665).byteslice(4..) || ""
            len_iv = private[%r{/lenIV\s+(-?\d+)}, 1]&.to_i || 4
            @subrs = subrs(private, len_iv)
            @charstrings = charstrings(private, len_iv)
          end

          def glyph?(name)
            @charstrings.key?(name)
          end

          def outline(name)
            code = @charstrings[name] or return []
            Type1Charstring.new(self, @subrs).run(code)
          end

          def advance(name)
            code = @charstrings[name] or return nil
            interpreter = Type1Charstring.new(self, @subrs)
            interpreter.run(code)
            interpreter.width
          end

          # The charstring of glyph +name+ (for seac).
          def charstring(name)
            @charstrings[name]
          end

          private

          def matrix(clear)
            m = clear[%r</FontMatrix\s*[\[{]([^\]}]*)[\]}]>, 1] or return nil
            values = m.split.map(&:to_f)
            values.size == 6 ? values : nil
          end

          def parse_encoding(clear)
            return :standard if clear.match?(%r{/Encoding\s+StandardEncoding\s+def})

            out = {}
            clear.scan(%r{dup\s+(\d+)\s*/([^\s/\[\]{}()<>]+)\s+put}) { |code, name| out[code.to_i] = name }
            out
          end

          def binary(data)
            head = data.byteslice(0, 4) || ""
            return data unless head.match?(/\A\h{4}\z/)

            [data.gsub(/[^0-9A-Fa-f]/, "")].pack("H*")
          end

          def decrypt(data, r)
            out = String.new(capacity: data.bytesize, encoding: Encoding::BINARY)
            data.each_byte do |c|
              out << (c ^ (r >> 8))
              r = ((c + r) * 52_845 + 22_719) & 0xFFFF
            end
            out
          end

          def charstring_bytes(bytes, len_iv)
            return bytes if len_iv.negative?

            decrypt(bytes, 4330).byteslice(len_iv..) || ""
          end

          def subrs(private, len_iv)
            out = []
            private.scan(/dup\s+(\d+)\s+(\d+)\s*(?:RD|-\|)\s/) do
              m = Regexp.last_match
              index = m[1].to_i
              length = m[2].to_i
              next if index > 65_535

              out[index] = charstring_bytes(private.byteslice(m.end(0), length) || "", len_iv)
            end
            out
          end

          def charstrings(private, len_iv)
            out = {}
            at = private.index("/CharStrings") or return out
            private.byteslice(at, private.bytesize - at)
                   .scan(%r{/([^\s/\[\]{}()<>]+)\s+(\d+)\s*(?:RD|-\|)\s}) do
              m = Regexp.last_match
              start = at + m.end(0)
              out[m[1]] = charstring_bytes(private.byteslice(start, m[2].to_i) || "", len_iv)
            end
            out
          end
        end

        # Type 1 charstring interpreter (Adobe Type 1 Font Format, 6),
        # including flex, hint replacement and seac.
        class Type1Charstring
          attr_reader :width

          def initialize(font, subrs, pen = Pen.new, origin = [0.0, 0.0])
            @font = font
            @subrs = subrs
            @pen = pen
            @stack = []
            @ps = []
            @flex = nil
            @ops = 0
            @origin = origin
            @width = nil
          end

          def run(code)
            exec(code, 0)
            @pen.close
            @pen.polys
          end

          private

          def exec(code, depth)
            raise ImageError, "charstring subroutines nested too deeply" if depth > MAX_CALL_DEPTH

            pen = @pen
            s = @stack
            pos = 0
            while pos < code.bytesize
              raise ImageError, "charstring runs too long" if (@ops += 1) > MAX_OPERATORS

              b = code.getbyte(pos)
              pos += 1
              if b >= 32
                if b <= 246
                  s << b - 139
                elsif b <= 250
                  s << (b - 247) * 256 + code.getbyte(pos).to_i + 108
                  pos += 1
                elsif b <= 254
                  s << -(b - 251) * 256 - code.getbyte(pos).to_i - 108
                  pos += 1
                else
                  s << Bytes.s32(code, pos)
                  pos += 4
                end
                next
              end
              case b
              when 13 # hsbw: sbx wx
                sbx, wx = s.pop(2)
                @width = wx
                pen.move_to(@origin[0] + sbx.to_f, @origin[1])
                @started = false
                s.clear
              when 21 then move(s[-2].to_f, s[-1].to_f) && s.clear
              when 22 then move(s[-1].to_f, 0) && s.clear
              when 4 then move(0, s[-1].to_f) && s.clear
              when 5
                pen.line_to(pen.x + s[-2], pen.y + s[-1]) if s.size >= 2
                s.clear
              when 6
                pen.line_to(pen.x + s[-1], pen.y) unless s.empty?
                s.clear
              when 7
                pen.line_to(pen.x, pen.y + s[-1]) unless s.empty?
                s.clear
              when 8
                if s.size >= 6
                  dx1, dy1, dx2, dy2, dx3, dy3 = s.last(6)
                  x1 = pen.x + dx1
                  y1 = pen.y + dy1
                  x2 = x1 + dx2
                  y2 = y1 + dy2
                  pen.curve_to(x1, y1, x2, y2, x2 + dx3, y2 + dy3)
                end
                s.clear
              when 30 # vhcurveto dy1 dx2 dy2 dx3
                if s.size >= 4
                  dy1, dx2, dy2, dx3 = s.last(4)
                  x1 = pen.x
                  y1 = pen.y + dy1
                  pen.curve_to(x1, y1, x1 + dx2, y1 + dy2, x1 + dx2 + dx3, y1 + dy2)
                end
                s.clear
              when 31 # hvcurveto dx1 dx2 dy2 dy3
                if s.size >= 4
                  dx1, dx2, dy2, dy3 = s.last(4)
                  x1 = pen.x + dx1
                  y1 = pen.y
                  pen.curve_to(x1, y1, x1 + dx2, y1 + dy2, x1 + dx2, y1 + dy2 + dy3)
                end
                s.clear
              when 9 # closepath
                pen.close
                s.clear
              when 10 # callsubr
                n = s.pop.to_i
                sub = @subrs[n] or raise ImageError, "charstring calls a missing subroutine"
                return :endchar if exec(sub, depth + 1) == :endchar
              when 11 then return nil
              when 14
                pen.close
                return :endchar
              when 1, 3 then s.clear # hstem vstem
              when 12
                op = code.getbyte(pos).to_i
                pos += 1
                return :endchar if escape(op, s, depth) == :endchar
              else
                s.clear
              end
            end
            nil
          end

          def move(dx, dy)
            pen = @pen
            if @flex
              @flex << [pen.x + dx, pen.y + dy]
              pen.set_point(pen.x + dx, pen.y + dy)
            else
              pen.move_to(pen.x + dx, pen.y + dy)
            end
            true
          end

          def escape(op, s, depth)
            pen = @pen
            case op
            when 7 # sbw: sbx sby wx wy
              sbx, sby, wx, = s.pop(4)
              @width = wx
              pen.move_to(@origin[0] + sbx.to_f, @origin[1] + sby.to_f)
              s.clear
            when 6 # seac: asb adx ady bchar achar
              asb, adx, ady, bchar, achar = s.pop(5)
              s.clear
              base = FontTables::STANDARD_ENCODING[bchar.to_i]
              accent = FontTables::STANDARD_ENCODING[achar.to_i]
              [[base, 0.0, 0.0], [accent, adx.to_f - asb.to_f, ady.to_f]].each do |name, dx, dy|
                code = name && @font.charstring(name) or next
                Type1Charstring.new(@font, @subrs, pen, [@origin[0] + dx, @origin[1] + dy]).send(:exec, code, depth + 1)
                pen.close
              end
              return :endchar
            when 12 # div
              a, b = s.pop(2)
              s << (b.to_f.zero? ? 0 : a.to_f / b)
            when 16 # callothersubr: args... n othersubr#
              number = s.pop.to_i
              n = s.pop.to_i
              args = n.positive? ? s.pop(n) : []
              case number
              when 1 # start flex
                @flex = []
                @flex_start = [pen.x, pen.y]
              when 2 then nil # flex point (recorded by rmoveto)
              when 0 # end flex: 7 points (reference + 6 curve points)
                points = @flex || []
                @flex = nil
                if points.size >= 7 && @flex_start
                  pen.set_point(*@flex_start)
                  pen.curve_to(*points[1], *points[2], *points[3])
                  pen.curve_to(*points[4], *points[5], *points[6])
                end
                # "pop pop setcurrentpoint" follows: x first, then y.
                @ps = [pen.x, pen.y]
                return nil
              end
              @ps = args.reverse
            when 17 then s << (@ps.shift || 0) # pop
            when 33 # setcurrentpoint
              x, y = s.pop(2)
              pen.set_point(x, y) if x && y
              s.clear
            else # dotsection vstem3 hstem3
              s.clear
            end
            nil
          end
        end
      end
    end
  end
end
