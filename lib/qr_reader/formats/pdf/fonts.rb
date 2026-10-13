# frozen_string_literal: true

module QrReader
  module Formats
    module PDF
      # A PDF font as drawing text in a barcode font needs it: the codes of
      # a string, their widths, and the outline of each glyph (from the
      # embedded font program) or its glyph procedure (Type 3). Fonts that
      # are not embedded draw nothing.
      #
      # Only glyphs whose outlines are all right-angled polygons (see
      # VectorRenderer.rectilinear?), as in barcode fonts, are returned by
      # #glyph: ordinary text (with curves) never becomes part of a rendered
      # code and costs only a lookup.
      class Font
        # Largest font program decoded.
        PROGRAM_LIMIT = 1 << 24
        # Most glyphs (outlines or procedures) prepared per font.
        MAX_GLYPHS = 4096
        IDENTITY = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0].freeze

        # The Font of font dictionary +value+, or nil.
        def self.load(doc, value)
          dict = doc.dict_value(value)
          dict ? new(doc, dict) : nil
        rescue Error, *INTERNAL_ERRORS
          nil
        end

        # Glyph space -> text space (Type 3: the FontMatrix).
        attr_reader :matrix
        # Resources of a Type 3 font's glyph procedures (nil: the page's).
        attr_reader :resources

        def initialize(doc, dict)
          @doc = doc
          @glyphs = {}
          @matrix = IDENTITY
          @widths = {}
          @default_width = 0.0
          @code_bytes = 1
          case doc.resolve(dict[:Subtype])
          when :Type3 then init_type3(dict)
          when :Type0 then init_type0(dict)
          else init_simple(dict)
          end
        end

        def type3?
          !@procs.nil?
        end

        # Yields code, width (text space, before the font size) and whether
        # word spacing applies, for each character code of +string+.
        def each_code(string)
          if @ranges
            pos = 0
            while pos < string.bytesize
              code, length = split(string, pos)
              yield code, width(code), length == 1 && code == 32
              pos += length
            end
          elsif @code_bytes == 2
            pos = 0
            while pos + 1 < string.bytesize
              code = (string.getbyte(pos) << 8) | string.getbyte(pos + 1)
              yield code, width(code), false
              pos += 2
            end
          else
            string.each_byte { |code| yield code, width(code), code == 32 }
          end
        end

        # Outline of +code+ in text space (closed flat polygons) when it is
        # made of module-like shapes, else nil.
        def glyph(code)
          return @glyphs[code] if @glyphs.key?(code)
          return nil if @glyphs.size >= MAX_GLYPHS

          @glyphs[code] = begin
            polys = outline(code)
            if polys && !polys.empty? && polys.all? { |p| VectorRenderer.rectilinear?(p) }
              a, b, c, d, e, f = @matrix
              polys.map do |p|
                q = Array.new(p.size)
                i = 0
                while i < p.size
                  x = p[i]
                  y = p[i + 1]
                  q[i] = a * x + c * y + e
                  q[i + 1] = b * x + d * y + f
                  i += 2
                end
                q
              end
            end
          rescue Error, *INTERNAL_ERRORS
            nil
          end
        end

        # Decoded content of the Type 3 glyph procedure of +code+, or nil.
        def procedure(code)
          return nil unless @procs
          return @glyphs[code] if @glyphs.key?(code)
          return nil if @glyphs.size >= MAX_GLYPHS

          name = @names[code]
          stream = name && @doc.resolve(@procs[name])
          @glyphs[code] = stream.is_a?(Stream) ? @doc.content(stream) : nil
        end

        private

        def value(dict, key)
          @doc.resolve(dict[key])
        end

        def number(v)
          Util.number(@doc.resolve(v))
        end

        # Widths of composite fonts are by CID.
        def width(code)
          @widths.fetch(@cids ? cid_for(code) : code, @default_width)
        end

        # --- Simple fonts (Type1, MMType1, TrueType) ------------------------

        def init_simple(dict)
          descriptor = @doc.dict_value(dict[:FontDescriptor]) || {}
          @program, @kind = program(descriptor)
          @names = encoding(dict)
          @symbolic = ((Util.int(value(descriptor, :Flags)) || 0) & 4) != 0
          read_simple_widths(dict, descriptor, 0.001)
          @matrix = program_matrix
        end

        def read_simple_widths(dict, descriptor, scale)
          first = Util.int(value(dict, :FirstChar)) || 0
          widths = value(dict, :Widths)
          if widths.is_a?(Array)
            widths.first(256).each_with_index do |w, i|
              w = number(w)
              @widths[first + i] = w * scale if w
            end
          end
          missing = number(value(descriptor, :MissingWidth))
          @default_width = missing ? missing * scale : 0.0
        end

        # [program, kind] from a FontDescriptor (nil when not embedded).
        def program(descriptor)
          %i[FontFile FontFile2 FontFile3].each do |key|
            stream = value(descriptor, key)
            next unless stream.is_a?(Stream)

            data = @doc.decode_stream(stream, PROGRAM_LIMIT)
            return parse_program(data, stream.dict)
          end
          [nil, nil]
        rescue Error, *INTERNAL_ERRORS
          [nil, nil]
        end

        def parse_program(data, dict)
          head = data.byteslice(0, 4)
          if ["\x00\x01\x00\x00".b, "true", "OTTO"].include?(head)
            [FontPrograms::TrueType.new(data), :truetype]
          elsif data.start_with?("%!") || data.getbyte(0) == 0x80
            data, clear = pfb(data)
            [FontPrograms::Type1.new(data, clear || Util.int(@doc.resolve(dict[:Length1]))), :type1]
          else
            [FontPrograms::CFF.new(data), :cff]
          end
        end

        # PFB segments joined; [data, length of the clear-text part].
        def pfb(data)
          return [data, nil] unless data.getbyte(0) == 0x80

          out = String.new(encoding: Encoding::BINARY)
          clear = nil
          pos = 0
          while data.getbyte(pos) == 0x80 && [1, 2].include?(data.getbyte(pos + 1))
            length = data.byteslice(pos + 2, 4).unpack1("V")
            out << data.byteslice(pos + 6, length).to_s
            clear ||= out.bytesize
            pos += 6 + length
          end
          [out, clear]
        end

        def program_matrix
          upem = @program.respond_to?(:units_per_em) && !@program.cff ? @program.units_per_em : nil
          return [1.0 / upem, 0.0, 0.0, 1.0 / upem, 0.0, 0.0] if upem

          cff = @program.respond_to?(:cff) ? @program.cff : @program
          m = cff.respond_to?(:font_matrix) ? cff.font_matrix : nil
          m.is_a?(Array) && m.size == 6 && m.all?(Numeric) ? m.map(&:to_f) : [0.001, 0.0, 0.0, 0.001, 0.0, 0.0]
        end

        # code -> glyph name from /Encoding (Differences over a base
        # encoding over the font program's own).
        def encoding(dict)
          names = Array.new(256)
          builtin = @program.is_a?(FontPrograms::Type1) ? @program.encoding : nil
          case builtin
          when :standard then FontTables::STANDARD_ENCODING.each_with_index { |name, code| names[code] = name }
          when Hash then builtin.each { |code, name| names[code] = name if code < 256 }
          end
          enc = value(dict, :Encoding)
          base = enc.is_a?(Hash) ? value(enc, :BaseEncoding) : enc
          if (table = base_table(base))
            table.each_with_index { |name, code| names[code] = name if name }
          end
          if enc.is_a?(Hash) && (diffs = value(enc, :Differences)).is_a?(Array)
            code = 0
            diffs.each do |item|
              item = @doc.resolve(item)
              case item
              when Integer then code = item
              when Symbol
                names[code] = item.to_s if code.between?(0, 255)
                code += 1
              end
            end
          end
          names
        end

        def base_table(name)
          case name
          when :WinAnsiEncoding then FontTables::WIN_ANSI_ENCODING
          when :MacRomanEncoding then FontTables::MAC_ROMAN_ENCODING
          when :StandardEncoding then FontTables::STANDARD_ENCODING
          end
        end

        # Glyph outline of +code+ in glyph space.
        def outline(code)
          return nil unless @program

          if @cid_font
            gid = cid_gid(cid_for(code)) or return nil
            return @program.outline(gid)
          end
          name = @names[code]
          case @kind
          when :type1
            @program.outline(name) if name
          when :cff
            gid = (name && @program.gid_for_name(name)) || @program.gid_for_code(code)
            gid ? @program.outline(gid) : nil
          when :truetype
            gid = truetype_gid(code, name) or return nil
            @program.outline(gid)
          end
        end

        def truetype_gid(code, name)
          tt = @program
          if @symbolic || !name
            [code, 0xF000 | code, 0xF100 | code, 0xF200 | code].each do |c|
              gid = tt.lookup(3, 0, c) and return gid
            end
            gid = tt.lookup(1, 0, code) and return gid
          end
          if name
            unicode = FontTables::UNICODE[name] || name[/\Auni(\h{4})\z/, 1]&.hex || name[/\Au(\h{4,6})\z/, 1]&.hex
            gid = unicode && tt.lookup(3, 1, unicode) and return gid
            gid = tt.cff&.gid_for_name(name) and return gid
          end
          gid = tt.lookup(3, 1, code) and return gid
          code.positive? && code < tt.glyph_count ? code : nil
        end

        # --- Type 3 ---------------------------------------------------------

        def init_type3(dict)
          m = value(dict, :FontMatrix)
          m = m.map { |v| number(v) } if m.is_a?(Array)
          @matrix = m.is_a?(Array) && m.size == 6 && m.none?(&:nil?) ? m : [0.001, 0.0, 0.0, 0.001, 0.0, 0.0]
          @procs = @doc.dict_value(dict[:CharProcs]) || {}
          @resources = dict[:Resources]
          @names = Array.new(256)
          enc = @doc.dict_value(dict[:Encoding])
          if enc && (diffs = value(enc, :Differences)).is_a?(Array)
            code = 0
            diffs.each do |item|
              item = @doc.resolve(item)
              case item
              when Integer then code = item
              when Symbol
                @names[code] = item if code.between?(0, 255)
                code += 1
              end
            end
          end
          # Widths are in glyph space.
          read_simple_widths(dict, {}, @matrix[0])
        end

        # --- Type 0 (composite) ---------------------------------------------

        def init_type0(dict)
          descendant = value(dict, :DescendantFonts)
          cid = @doc.dict_value(descendant.is_a?(Array) ? descendant.first : descendant) || {}
          descriptor = @doc.dict_value(cid[:FontDescriptor]) || {}
          @program, @kind = program(descriptor)
          @cid_font = true
          @matrix = @program ? program_matrix : IDENTITY
          read_cmap(value(dict, :Encoding))
          map = value(cid, :CIDToGIDMap)
          @cid_to_gid = map.is_a?(Stream) ? @doc.decode_stream(map, 1 << 18) : nil
          read_cid_widths(cid)
        end

        # Identity-H/V and other predefined CMaps: 2-byte codes, CID = code;
        # embedded CMaps: their code space and CID ranges.
        def read_cmap(enc)
          @code_bytes = 2
          return unless enc.is_a?(Stream)

          text = @doc.decode_stream(enc, 1 << 20)
          @ranges = []
          text.scan(/begincodespacerange(.*?)endcodespacerange/m) do |(body)|
            body.scan(/<(\h+)>\s*<(\h+)>/) { |lo, hi| @ranges << [lo.size / 2, lo.hex, hi.hex] if lo.size == hi.size }
          end
          @ranges = nil if @ranges.empty?
          @cids = []
          text.scan(/begincidrange(.*?)endcidrange/m) do |(body)|
            body.scan(/<(\h+)>\s*<(\h+)>\s*(\d+)/) { |lo, hi, cid| @cids << [lo.hex, hi.hex, cid.to_i] }
          end
          text.scan(/begincidchar(.*?)endcidchar/m) do |(body)|
            body.scan(/<(\h+)>\s*(\d+)/) { |c, cid| @cids << [c.hex, c.hex, cid.to_i] }
          end
          @cids = nil if @cids.empty?
        end

        # [code, length] of the code at +pos+ (code space ranges).
        def split(string, pos)
          (1..4).each do |n|
            break if pos + n > string.bytesize

            code = 0
            n.times { |i| code = (code << 8) | string.getbyte(pos + i) }
            return [code, n] if @ranges.any? { |len, lo, hi| len == n && code.between?(lo, hi) }
          end
          [string.getbyte(pos), 1]
        end

        def cid_for(code)
          return code unless @cids

          @cids.each { |lo, hi, cid| return cid + code - lo if code.between?(lo, hi) }
          0
        end

        def cid_gid(cid)
          if @cid_to_gid
            return nil if 2 * cid + 1 >= @cid_to_gid.bytesize

            return (@cid_to_gid.getbyte(2 * cid) << 8) | @cid_to_gid.getbyte(2 * cid + 1)
          end
          if @kind == :cff && @program.cid?
            @program.gid_for_cid(cid)
          elsif @program.is_a?(FontPrograms::TrueType) && @program.cff&.cid?
            @program.cff.gid_for_cid(cid)
          else
            cid
          end
        end

        def read_cid_widths(cid)
          dw = number(value(cid, :DW))
          @default_width = (dw || 1000.0) * 0.001
          w = value(cid, :W)
          return unless w.is_a?(Array)

          i = 0
          entries = 0
          while i < w.size && entries < 65_536
            first = Util.int(@doc.resolve(w[i]))
            nxt = @doc.resolve(w[i + 1])
            break unless first

            if nxt.is_a?(Array)
              nxt.each_with_index do |v, j|
                v = number(v)
                @widths[first + j] = v * 0.001 if v
                entries += 1
              end
              i += 2
            else
              last = Util.int(nxt)
              v = number(w[i + 2])
              break unless last && v

              (first..[last, first + 65_536].min).each { |c| @widths[c] = v * 0.001 }
              entries += last - first + 1
              i += 3
            end
          end
        end
      end

      private_constant :Font, :FontPrograms, :FontTables
    end
  end
end
