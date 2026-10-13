# frozen_string_literal: true

require "strscan"
require "zlib"
require_relative "../kernels/lzw"

module QrReader
  module Formats
    # Extracts the raster images of PDF documents page by page: scanned
    # pages, faxes and photos placed in PDFs. Vector graphics (including
    # vector-drawn QR codes) are not rendered.
    #
    #   PDF.each_image(bytes) { |image, info| ... }  # info: {page: 0, name: "Im0", width: 2480, height: 3508,
    #                                                #        pixel_aspect: 1.0, dpi: [300.0, 300.0]}
    #   PDF.each_image(bytes)                        # => Enumerator
    #   PDF.each_image(bytes, raw_jpeg: true) { |image_or_jpeg, info| ... }
    #   PDF.images(bytes)                            # => [#<QrReader::Image 2480x3508>, ...]
    #
    # Structure: the header may sit anywhere in the first KB; classic
    # cross-reference tables and cross-reference streams (incremental
    # updates, hybrid files), object streams; when the cross-reference data
    # is broken or missing, the file is scanned for "N G obj". Objects are
    # parsed and streams decoded only when needed. Pages are walked through
    # the page tree (inherited resources) and each page's content streams
    # are run to find the images it draws, in drawing order: image
    # XObjects (also inside form XObjects) and inline images
    # (BI ... ID ... EI). Images are not rendered onto a page: each one is
    # yielded as it is stored (an image drawn several times on a page is
    # yielded once), except that bands of one picture - images drawn
    # directly above each other with the same width and scale, as printer
    # drivers write them - are joined into one image. +info[:name]+ is the
    # (first) XObject's resource name (nil for inline images),
    # +info[:page]+ the 0-based page index. +info[:pixel_aspect]+ is the
    # width of an image pixel divided by its height as the page draws it
    # (from the transformation matrix: 0.48 for a 204 x 98 dpi fax drawn
    # at its true size; 1.0 when unknown), +info[:dpi]+ its resolution on
    # the page ([x, y], nil when unknown).
    #
    # With +raw_jpeg: true+, DCT images whose luminance is exactly what
    # JPEG.decode makes of their data (1 or 3 components with the default
    # /Decode, or Adobe CMYK with an inverting one) are not decoded: the
    # block gets the JPEG data (a binary String) in place of the Image,
    # with +info[:format]+ :jpeg and the size of the JPEG frame, so that a
    # caller can decode it at reduced size first (JPEG.decode(data,
    # scale:)). JPEG.decode of such data may still raise ImageError.
    #
    # Images: 1/2/4/8/16 bits per component; DeviceGray/RGB/CMYK, CalGray,
    # CalRGB, ICCBased (by /N), Indexed, Separation and DeviceN (tint =
    # darkness), Lab (L*), named colour spaces; stencil masks; /Decode
    # arrays. Filters: FlateDecode and LZWDecode (with PNG and TIFF
    # predictors), RunLengthDecode, ASCIIHexDecode, ASCII85Decode,
    # DCTDecode (JPEG), CCITTFaxDecode and JBIG2Decode (generic regions;
    # symbol, halftone and refinement coding are skipped). JPEG 2000 images
    # are skipped. Colour is reduced to luminance with Image.luma; alpha
    # (/SMask) is ignored.
    #
    # Encrypted documents are decrypted when their user password is empty
    # (standard security handler: RC4, AES-128, AES-256); other encrypted
    # documents raise UnsupportedImageError.
    #
    # Images that cannot be decoded are skipped. Data that is not a PDF
    # raises ImageError; a document without any decodable image raises
    # UnsupportedImageError (ImageError when its images are corrupt).
    module PDF
      # Raised internally for malformed syntax.
      class ParseError < ImageError; end

      # An indirect reference "num gen R".
      Ref = Data.define(:num, :gen)
      # A bare keyword or operator met while parsing an object.
      Keyword = Data.define(:word)
      # A stream object: its dictionary and raw (encoded, possibly
      # encrypted) data.
      Stream = Struct.new(:dict, :raw, :num, :gen)
      # A page: its dictionary and its (possibly inherited) resources; or,
      # for documents without usable pages, a lone image stream.
      Page = Struct.new(:dict, :resources, :orphan)
      # An image found on a page: an image XObject (+stream+) or an inline
      # image (+data+), with the resources that apply to it and the
      # current transformation matrix it was drawn with.
      ImageSource = Struct.new(:dict, :stream, :data, :resources, :name, :ctm)
      # A DCT image handed over undecoded (each_image with raw_jpeg: true):
      # the JPEG data and its frame size.
      RawJpeg = Struct.new(:data, :width, :height)

      # Largest decoded stream we produce for anything but image samples.
      STREAM_LIMIT = 1 << 26
      # Largest decoded image sample buffer.
      SAMPLE_LIMIT = 1 << 28

      # Errors that garbage input could trigger deep inside the decoders.
      INTERNAL_ERRORS = [NoMethodError, TypeError, ArgumentError, RangeError, IndexError, ZeroDivisionError,
                         EncodingError, RegexpError, Zlib::Error].freeze

      class << self
        # Yields each raster image of the document with an info Hash
        # ({page:, name:, width:, height:}), page by page in drawing order.
        # Returns an Enumerator without a block.
        def each_image(bytes, raw_jpeg: false)
          return enum_for(:each_image, bytes, raw_jpeg: raw_jpeg) unless block_given?

          document = guard { Document.new(binary(bytes)) }
          pages = guard { document.pages }
          failures = []
          count = 0
          pages.each_with_index do |page, index|
            band = nil # the latest image, held back in case the next one continues it
            sources(document, page, failures).each do |source|
              part = decode(document, source, failures, raw_jpeg) or next
              next if band&.join(part, source.ctm)

              if band && (image = band.image)
                count += 1
                yield image, band.info(index, image)
              end
              band = Band.new([part], source.ctm, source.name)
            end
            next unless band && (image = band.image)

            count += 1
            yield image, band.info(index, image)
          end
          raise no_images(failures) if count.zero?

          nil
        end

        # All raster images of the document (see #each_image).
        def images(bytes)
          each_image(bytes).map { |image, _info| image }
        end

        private

        def binary(bytes)
          raise ImageError, "expected a String of PDF data, got #{bytes.class}" unless bytes.is_a?(String)

          bytes.encoding == Encoding::BINARY ? bytes : bytes.b
        end

        def guard
          yield
        rescue *INTERNAL_ERRORS => e
          raise ImageError, "corrupt PDF (#{e.class}: #{e.message})"
        end

        def sources(document, page, failures)
          document.page_images(page)
        rescue Error, *INTERNAL_ERRORS => e
          failures << e
          []
        end

        def decode(document, source, failures, raw_jpeg)
          ImageDecoder.new(document, source, raw_jpeg).decode
        rescue Error, *INTERNAL_ERRORS => e
          failures << e
          nil
        end

        def no_images(failures)
          return UnsupportedImageError.new("PDF contains no raster images") if failures.empty?

          reason = failures.first.message
          if failures.any?(UnsupportedImageError)
            UnsupportedImageError.new("PDF contains no decodable raster image (#{reason})")
          else
            ImageError.new("PDF contains no decodable raster image (#{reason})")
          end
        end
      end

      # Images drawn directly above or below each other with the same width
      # and scale are bands of one picture (scanner drivers that print
      # through PostScript cut page images into strips), joined so that a
      # code across a band boundary stays readable. +parts+ (Images or
      # RawJpegs) are top to bottom; +ctm+ maps the unit square onto the
      # joined picture.
      Band = Struct.new(:parts, :ctm, :name) do
        # The picture: an Image, the JPEG data of a lone RawJpeg, or nil
        # when a joined RawJpeg cannot be decoded.
        def image
          part = parts.first
          return part.is_a?(RawJpeg) ? part.data : part if parts.size == 1

          images = parts.map { |p| p.is_a?(RawJpeg) ? JPEG.decode(p.data) : p }
          Image.new(images.first.width, images.sum(&:height), images.map(&:data).join)
        rescue Error
          nil
        end

        # The info Hash for +image+ (see PDF.each_image).
        def info(page, image)
          info = { page: page, name: name }
          if image.is_a?(String)
            info[:width] = parts.first.width
            info[:height] = parts.first.height
            info[:format] = :jpeg
          else
            info[:width] = image.width
            info[:height] = image.height
          end
          info.merge!(Band.geometry(ctm, info[:width], info[:height]))
        end

        # {pixel_aspect:, dpi:} of a +width+ x +height+ image drawn with
        # +ctm+ (which maps the unit square onto the drawn image).
        def self.geometry(ctm, width, height)
          a, b, c, d = ctm
          drawn_w = ctm && Math.hypot(a, b) # in points (1/72 inch)
          drawn_h = ctm && Math.hypot(c, d)
          return { pixel_aspect: 1.0, dpi: nil } unless drawn_w&.finite? && drawn_h&.finite? &&
                                                        drawn_w > 1e-6 && drawn_h > 1e-6

          aspect = (drawn_w / width) / (drawn_h / height)
          aspect = 1.0 unless aspect.between?(0.125, 8.0)
          { pixel_aspect: aspect.round(6), dpi: [(width * 72 / drawn_w).round(2), (height * 72 / drawn_h).round(2)] }
        end

        # Appends +image+ (drawn with +matrix+) if it continues this band;
        # returns true if it did.
        def join(image, matrix)
          return false unless ctm && matrix && upright?(ctm) && upright?(matrix)

          width = parts.first.width
          height = parts.sum(&:height)
          a, _, _, d, e, f = ctm
          a2, _, _, d2, e2, f2 = matrix
          row = d / height
          return false unless image.width == width && (height + image.height) * width <= MAX_PIXELS
          # Same horizontal placement (within half a pixel) and row height.
          return false unless (a2 - a).abs <= a * 0.01 && (e2 - e).abs <= a / width / 2
          return false unless (d2 / image.height - row).abs <= row * 0.01

          if (f2 + d2 - f).abs <= row / 2 # directly below
            parts << image
            self.ctm = [a, 0.0, 0.0, d + d2, e, f2]
          elsif (f + d - f2).abs <= row / 2 # directly above
            parts.unshift(image)
            self.ctm = [a, 0.0, 0.0, d + d2, e, f]
          else
            return false
          end
          true
        end

        private

        def upright?(m)
          m[1].abs < 1e-6 && m[2].abs < 1e-6 && m[0].positive? && m[3].positive?
        end
      end

      # Small conversions shared by the parts below.
      module Util
        module_function

        def int(value)
          case value
          when Integer then value
          when Float then value.finite? ? value.to_i : nil
          end
        end

        def positive(value)
          v = int(value)
          v if v&.positive?
        end

        def number(value)
          case value
          when Integer then value.to_f
          when Float then value.finite? ? value : nil
          end
        end

        # Big-endian unsigned integer of +width+ bytes at +pos+.
        def be_int(data, pos, width)
          v = 0
          i = 0
          while i < width
            v = (v << 8) | data.getbyte(pos + i)
            i += 1
          end
          v
        end
      end

      # Tokenizer and object parser (ISO 32000-1, 7.2 and 7.3).
      #
      # Regexps never match unbounded runs: Onigmo keeps a backtracking
      # stack entry (about 50 bytes) per character a quantifier matches,
      # gigabytes for the long runs of white space or token characters in
      # a hostile file or stream. White space and tokens are scanned in
      # bounded steps (the rest of an overlong token is skipped), comments
      # with String#index.
      class Parser
        MAX_DEPTH = 100
        # Array elements and dictionary entries one document may parse
        # (about 100 bytes of memory and 2 us each at worst, e.g. empty
        # strings; a scanned page needs about 30).
        MAX_ELEMENTS = 2_000_000
        NOT_SPACE = /[^\x00\t\n\f\r ]/n
        LINE_END = /[\r\n]/n
        SPACE_RUN = /[\x00\t\n\f\r ]{1,1024}/n
        TOKEN_RUN = %r{[^\x00\t\n\f\r ()<>\[\]{}/%]{1,1024}}n
        NAME_RUN = %r{/[^\x00\t\n\f\r ()<>\[\]{}/%]{0,1024}}n
        # Ends a regular token (white space or a delimiter).
        DELIMITER = %r{[\x00\t\n\f\r ()<>\[\]{}/%]}n
        DELIMITERS = "\x00\t\n\f\r ()<>[]{}/%".b.bytes.freeze
        # Byte -> true for white space / for white space and delimiters.
        SPACE_BYTE = Array.new(256) { |b| "\x00\t\n\f\r ".b.bytes.include?(b) }.freeze
        DELIMITER_BYTE = Array.new(256) { |b| DELIMITERS.include?(b) }.freeze
        INTEGER = /\A[+-]?\d+\z/
        REF_TAIL = %r{[\x00\t\n\f\r ]{1,64}(\d{1,10})[\x00\t\n\f\r ]{1,64}R(?![^\x00\t\n\f\r ()<>\[\]{}/%])}n
        OBJ_HEADER = %r{(\d{1,10})[\x00\t\n\f\r ]{1,64}(\d{1,5})[\x00\t\n\f\r ]{0,64}obj(?![^\x00\t\n\f\r ()<>\[\]{}/%])}n
        STREAM = /stream(?:\r\n|\n|\r)?/
        LITERAL_SPECIAL = /[()\\\r]/n
        ESCAPES = { 0x6E => 0x0A, 0x72 => 0x0D, 0x74 => 0x09, 0x62 => 0x08, 0x66 => 0x0C }.freeze
        HEX_PAIR = /#(\h\h)/

        # Name token (with its slash) -> Symbol, #xx escapes decoded.
        def self.name_symbol(token)
          raw = token.byteslice(1, token.bytesize - 1)
          raw = raw.gsub(HEX_PAIR) { ::Regexp.last_match(1).hex.chr } if raw.include?("#")
          raw.to_sym
        end

        # Moves scanner +s+ (over +data+) past white space and comments;
        # returns the next byte (nil at the end).
        def self.skip_space(s, data)
          while true
            s.skip(SPACE_RUN)
            b = data.getbyte(s.pos)
            if b == 0x25
              s.pos = data.index(LINE_END, s.pos) || data.bytesize
            elsif b.nil? || !SPACE_BYTE[b]
              return b
            end
          end
        end

        # The token +pattern+ (TOKEN_RUN or NAME_RUN) matches at the
        # scanner position, or nil; the rest of an overlong token is skipped.
        def self.scan_token(s, data, pattern)
          token = s.scan(pattern) or return nil
          b = data.getbyte(s.pos)
          s.pos = data.index(DELIMITER, s.pos) || data.bytesize if b && !DELIMITER_BYTE[b]
          token
        end

        # A shared count of the elements left to parse (see MAX_ELEMENTS).
        def self.budget
          [MAX_ELEMENTS]
        end

        def initialize(data, budget = Parser.budget)
          @data = data
          @s = StringScanner.new(data)
          @budget = budget
        end

        def pos
          @s.pos
        end

        def pos=(value)
          @s.pos = value.clamp(0, @data.bytesize)
        end

        def skip_space
          Parser.skip_space(@s, @data)
        end

        # The next object: Integer, Float, true, false, nil, Symbol (name),
        # String, Array, Hash (Symbol keys), Ref, or a Keyword.
        def parse(depth = 0)
          s = @s
          data = @data
          case Parser.skip_space(s, data)
          when nil then raise ParseError, "unexpected end of PDF data"
          when 0x2F then Parser.name_symbol(Parser.scan_token(s, data, NAME_RUN))
          when 0x28 then literal_string
          when 0x3C then data.getbyte(s.pos + 1) == 0x3C ? dictionary(depth) : hex_string
          when 0x5B then array(depth)
          else
            token = Parser.scan_token(s, data, TOKEN_RUN)
            unless token
              s.pos += 1
              raise ParseError, "unexpected delimiter in PDF object"
            end
            atom(token)
          end
        end

        # [num, gen, value, stream data offset or nil] for the indirect
        # object at +offset+, or nil when there is none.
        def indirect(offset)
          return nil if offset.negative? || offset >= @data.bytesize

          s = @s
          s.pos = offset
          skip_space
          return nil unless s.scan(OBJ_HEADER)

          num = s[1].to_i
          gen = s[2].to_i
          value = parse
          value = nil if value.is_a?(Keyword) # "endobj" of an empty object
          start = nil
          if value.is_a?(Hash)
            skip_space
            start = s.pos if s.scan(STREAM)
          end
          [num, gen, value, start]
        end

        private

        def atom(token)
          b = token.getbyte(0)
          if b <= 0x39 && (b >= 0x30 || b == 0x2B || b == 0x2D || b == 0x2E)
            return 0 if token.bytesize > 32
            return token.to_f.then { |f| f.finite? ? f : 0.0 } unless INTEGER.match?(token)
            return 0 if token.bytesize > 20

            value = token.to_i
            return Ref.new(value, @s[1].to_i) if b >= 0x30 && @s.scan(REF_TAIL)

            return value
          end
          case token
          when "true" then true
          when "false" then false
          when "null" then nil
          else Keyword.new(token)
          end
        end

        def literal_string
          s = @s
          data = @data
          size = data.bytesize
          s.pos += 1
          out = String.new(encoding: Encoding::BINARY)
          depth = 1
          loop do
            pos = s.pos
            stop = data.index(LITERAL_SPECIAL, pos) || size
            out << data.byteslice(pos, stop - pos) if stop > pos
            s.pos = stop
            b = data.getbyte(stop) or break
            s.pos += 1
            case b
            when 0x28
              depth += 1
              out << b
            when 0x29
              depth -= 1
              break if depth.zero?

              out << b
            when 0x0D
              s.pos += 1 if data.getbyte(s.pos) == 0x0A
              out << 0x0A
            else
              escape(out)
            end
          end
          out
        end

        def escape(out)
          s = @s
          data = @data
          e = data.getbyte(s.pos) or return
          s.pos += 1
          if (mapped = ESCAPES[e])
            out << mapped
          elsif e >= 0x30 && e <= 0x37
            v = e - 0x30
            2.times do
              d = data.getbyte(s.pos)
              break unless d && d >= 0x30 && d <= 0x37

              v = (v << 3) | (d - 0x30)
              s.pos += 1
            end
            out << (v & 0xFF)
          elsif e == 0x0D
            s.pos += 1 if data.getbyte(s.pos) == 0x0A
          elsif e != 0x0A
            out << e
          end
        end

        def hex_string
          s = @s
          data = @data
          start = s.pos + 1
          stop = data.index(">", start) || data.bytesize
          s.pos = stop < data.bytesize ? stop + 1 : stop
          hex = data.byteslice(start, stop - start).delete("^0-9A-Fa-f")
          hex << "0" if hex.bytesize.odd?
          [hex].pack("H*")
        end

        # Counts one array element or dictionary entry against the budget.
        def count_element
          return if (@budget[0] -= 1) >= 0

          raise ParseError, "PDF has too many objects (more than #{MAX_ELEMENTS} array elements and dictionary entries)"
        end

        def array(depth)
          raise ParseError, "PDF objects nested too deeply" if depth > MAX_DEPTH

          s = @s
          data = @data
          s.pos += 1
          list = []
          loop do
            b = Parser.skip_space(s, data)
            raise ParseError, "unterminated array" unless b

            if b == 0x5D
              s.pos += 1
              return list
            end
            value = parse(depth + 1)
            raise ParseError, "unexpected #{value.word} in array" if value.is_a?(Keyword)

            count_element
            list << value
          end
        end

        def dictionary(depth)
          raise ParseError, "PDF objects nested too deeply" if depth > MAX_DEPTH

          s = @s
          data = @data
          s.pos += 2
          dict = {}
          loop do
            b = Parser.skip_space(s, data)
            raise ParseError, "unterminated dictionary" unless b

            if b == 0x3E
              s.pos += data.getbyte(s.pos + 1) == 0x3E ? 2 : 1
              return dict
            end
            raise ParseError, "dictionary key is not a name" unless b == 0x2F

            key = Parser.name_symbol(Parser.scan_token(s, data, NAME_RUN))
            value = parse(depth + 1)
            raise ParseError, "unexpected #{value.word} in dictionary" if value.is_a?(Keyword)

            count_element
            dict[key] = value
          end
        end
      end

      # Cross-reference data, lazy object loading, decryption and the page
      # tree of one document.
      class Document
        include Util

        MAX_REF_DEPTH = 32
        MISSING = Object.new.freeze
        # (Regexps match bounded lengths only, see Parser.)
        OBJ_SCAN = %r{(?<!\d)(\d{1,10})[\x00\t\n\f\r ]{1,64}(\d{1,5})[\x00\t\n\f\r ]{1,64}obj(?![^\x00\t\n\f\r ()<>\[\]{}/%])}n
        SUBSECTION = /[\x00\t\n\f\r ]{0,64}(\d{1,10})[\x00\t\n\f\r ]{1,64}(\d{1,10})/n
        XREF_ENTRY = /[\x00\t\n\f\r ]{0,64}(\d{1,10})[\x00\t\n\f\r ]{1,64}(\d{1,5})[\x00\t\n\f\r ]{1,64}([nf])/n
        TRAILER_AHEAD = /[\x00\t\n\f\r ]{0,64}trailer/n
        TRAILER_DICT = /trailer[\x00\t\n\f\r ]{0,64}<</n
        ENDSTREAM = /\A[\x00\t\n\f\r ]*endstream/
        NUMBER = /\d{1,20}/n
        TRAILER_KEYS = %i[Root Encrypt ID Info].freeze
        # Distinct objects a document may register (about 80 bytes each).
        MAX_OBJECTS = 2_000_000
        # Cross-reference entries read in all (tables and streams, possibly
        # the same entries again through crafted /Prev chains).
        MAX_XREF_ENTRIES = 4 * MAX_OBJECTS
        # Decoded bytes of all content streams (pages, forms) and of all
        # object streams, at least (and twice the file size for large
        # files): a stream may be a decompression bomb, and many pages may
        # draw the same one. Pages beyond the content budget list their
        # image resources instead.
        MIN_STREAM_BUDGET = 1 << 26

        attr_reader :data, :trailer

        def initialize(data)
          @data = data
          @header = data.byteslice(0, 1024).index("%PDF-") or raise ImageError, "not a PDF document (no %PDF- header)"
          @budget = Parser.budget
          @parser = Parser.new(data, @budget)
          @content_left = @object_stream_left = [MIN_STREAM_BUDGET, 2 * data.bytesize].max
          @xref_left = MAX_XREF_ENTRIES
          @object_pairs_left = MAX_OBJECTS
          @offsets = {}
          @cache = {}
          @loading = {}
          @object_streams = {}
          @rebuilt = false
          @security = nil
          @trailer = read_xref
          rebuild unless @trailer && @trailer[:Root]
          setup_security unless @security
        end

        # Value of indirect object +num+ (nil when missing or broken).
        def object(num)
          return @cache[num] if @cache.key?(num)
          return nil if @loading[num] || @loading.size > MAX_REF_DEPTH

          @loading[num] = true
          begin
            value = load_object(num)
            value = load_object(num) if value.equal?(MISSING) && rebuild
            value = nil if value.equal?(MISSING)
          ensure
            @loading.delete(num)
          end
          @cache[num] = value
        end

        # Follows references to a direct value.
        def resolve(value)
          depth = 0
          while value.is_a?(Ref)
            return nil if (depth += 1) > MAX_REF_DEPTH

            value = object(value.num)
          end
          value
        end

        # The resolved value if it is a dictionary (a stream's dictionary
        # does not count), else nil.
        def dict_value(value)
          value = resolve(value)
          value.is_a?(Hash) ? value : nil
        end

        # [filter names, decode parameter dictionaries] of a stream or image
        # dictionary; abbreviated (inline image) names are expanded and the
        # parameter values resolved.
        def filter_chain(dict)
          filters = resolve(dict[:Filter])
          filters = [filters] unless filters.is_a?(Array)
          filters = filters.filter_map do |f|
            f = resolve(f)
            f.is_a?(Symbol) ? Filters::ABBREVIATIONS.fetch(f, f) : nil
          end
          params = resolve(dict[:DecodeParms] || dict[:DP])
          params = [params] unless params.is_a?(Array)
          params = Array.new(filters.size) do |i|
            p = dict_value(params[i])
            p ? p.transform_values { |v| resolve(v) } : {}
          end
          [filters, params]
        end

        # Raw stream data, decrypted.
        def stream_bytes(stream)
          raw = stream.raw
          return raw unless @security && stream.num
          return raw if resolve(stream.dict[:Type]) == :XRef || identity_crypt?(stream.dict)

          @security.decrypt_stream(raw, stream.num, stream.gen)
        end

        # Stream data with all filters applied (no image codecs).
        def decode_stream(stream, limit = STREAM_LIMIT)
          filters, params = filter_chain(stream.dict)
          Filters.decode(stream_bytes(stream), filters, params, limit)
        end

        # Decoded content stream, or nil when it cannot be decoded (or the
        # document's CONTENT_BUDGET is spent).
        def content(stream)
          return nil if @content_left <= 0

          data = decode_stream(stream, @content_left < STREAM_LIMIT ? @content_left : STREAM_LIMIT)
          @content_left -= data.bytesize + 1
          data
        rescue Error, *INTERNAL_ERRORS
          nil
        end

        # The pages in page-tree order; falls back to all page objects (in
        # file order) and then to all image objects for broken documents.
        def pages
          list = walk_pages
          list = walk_pages if list.empty? && rebuild
          list = scan_pages if list.empty?
          list
        end

        # ImageSources drawn by +page+ in drawing order.
        def page_images(page)
          return [ImageSource.new(page.orphan.dict, page.orphan, nil, {}, nil, nil)] if page.orphan

          resources = page.resources
          contents = resolve(page.dict[:Contents])
          streams = (contents.is_a?(Array) ? contents.map { |c| resolve(c) } : [contents]).grep(Stream)
          return [] if streams.empty?

          parts = streams.filter_map { |stream| content(stream) }
          # Undecodable content: list the page's image resources instead.
          return resource_images(resources) if parts.empty?

          ContentScanner.new(self).images(parts.join("\n"), resources)
        end

        private

        def identity_crypt?(dict)
          filters, params = filter_chain(dict)
          i = filters.index(:Crypt) or return false
          (params[i][:Name] || :Identity) == :Identity
        end

        def resource_images(resources)
          xobjects = dict_value(dict_value(resources)&.[](:XObject)) or return []
          xobjects.filter_map do |name, ref|
            stream = resolve(ref)
            next unless stream.is_a?(Stream) && resolve(stream.dict[:Subtype]) == :Image

            ImageSource.new(stream.dict, stream, nil, resources, name.to_s, nil)
          end
        end

        def walk_pages
          root = dict_value(@trailer && @trailer[:Root]) or return []
          list = []
          visited = {}
          stack = [[root[:Pages], nil]]
          until stack.empty?
            ref, inherited = stack.pop
            node = resolve(ref)
            next unless node.is_a?(Hash)

            id = ref.is_a?(Ref) ? ref.num : node.object_id
            next if visited[id]

            visited[id] = true
            resources = node.key?(:Resources) ? node[:Resources] : inherited
            kids = resolve(node[:Kids])
            if kids.is_a?(Array) && node[:Type] != :Page
              kids.reverse_each { |kid| stack << [kid, resources] }
            elsif node[:Type] == :Page || !node.key?(:Kids)
              list << Page.new(node, resources, nil)
            end
          end
          list
        end

        def scan_pages
          rebuild
          pages = []
          images = []
          each_object do |value|
            if value.is_a?(Hash) && value[:Type] == :Page
              pages << Page.new(value, page_resources(value), nil)
            elsif value.is_a?(Stream) && resolve(value.dict[:Subtype]) == :Image
              images << Page.new(nil, nil, value)
            end
          end
          pages.empty? ? images : pages
        end

        def page_resources(page)
          node = page
          MAX_REF_DEPTH.times do
            return node[:Resources] if node.key?(:Resources)

            node = dict_value(node[:Parent]) or return nil
          end
          nil
        end

        # Yields every object, direct ones in file order, then compressed ones.
        def each_object
          direct, compressed = @offsets.partition { |_num, entry| entry.is_a?(Integer) }
          direct.sort_by! { |_num, offset| offset }
          (direct + compressed).each { |num, _entry| yield object(num) }
        end

        # --- objects -------------------------------------------------------

        def load_object(num)
          entry = @offsets[num]
          case entry
          when Integer then load_direct(num, entry)
          when Array then load_compressed(num, entry[0], entry[1])
          else MISSING
          end
        end

        def load_direct(num, offset)
          positions = [offset]
          positions << offset + @header if @header.positive?
          positions.each do |pos|
            parsed = begin
              @parser.indirect(pos)
            rescue ParseError
              nil
            end
            next unless parsed && parsed[0] == num

            _, gen, value, start = parsed
            value = build_stream(value, start, num, gen) if start
            value = decrypt_strings(value, num, gen) if @security && num != @encrypt_num
            return value
          end
          MISSING
        end

        def load_compressed(num, stream_num, index)
          container = object_stream(stream_num) or return MISSING
          by_num, pairs, parser, first = container
          pair = pairs[index]
          offset = pair && pair[0] == num ? pair[1] : by_num[num]
          return MISSING unless offset

          parser.pos = first + offset
          value = parser.parse
          value.is_a?(Keyword) ? nil : value
        rescue ParseError
          MISSING
        end

        # [{num => offset}, [[num, offset], ...], parser, first] of object
        # stream +num+, or nil.
        def object_stream(num)
          return @object_streams[num] if @object_streams.key?(num)

          @object_streams[num] = nil
          stream = object(num)
          return nil unless stream.is_a?(Stream)

          first = int(resolve(stream.dict[:First])) or return nil
          return nil if @object_stream_left <= 0

          data = decode_stream(stream, @object_stream_left < STREAM_LIMIT ? @object_stream_left : STREAM_LIMIT)
          @object_stream_left -= data.bytesize + 1
          return nil if first.negative? || first > data.bytesize

          # At most N pairs, and MAX_OBJECTS pairs in all object streams.
          count = (int(resolve(stream.dict[:N])) || 0).clamp(0, @object_pairs_left)
          numbers = []
          header = StringScanner.new(data.byteslice(0, first))
          numbers << header.matched.to_i while numbers.size < 2 * count && header.skip_until(NUMBER)
          count = numbers.size / 2
          @object_pairs_left -= count
          pairs = Array.new(count) { |i| [numbers[2 * i], numbers[2 * i + 1]] }
          by_num = {}
          pairs.each { |n, offset| by_num[n] ||= offset }
          @object_streams[num] = [by_num, pairs, Parser.new(data, @budget), first]
        rescue Error, *INTERNAL_ERRORS
          nil
        end

        def build_stream(dict, start, num, gen, resolve_length: true)
          length = dict[:Length]
          length = resolve(length) if resolve_length && length.is_a?(Ref)
          size = @data.bytesize
          if length.is_a?(Integer) && length >= 0 && start + length <= size &&
             (start + length == size || ENDSTREAM.match?(@data.byteslice(start + length, 64)))
            raw = @data.byteslice(start, length)
          else
            stop = @data.index("endstream", start) || size
            stop -= 1 if stop > start && @data.getbyte(stop - 1) == 0x0A
            stop -= 1 if stop > start && @data.getbyte(stop - 1) == 0x0D
            raw = @data.byteslice(start, stop - start)
          end
          Stream.new(dict, raw, num, gen)
        end

        def decrypt_strings(value, num, gen)
          case value
          when String then @security.decrypt_string(value, num, gen)
          when Array then value.map! { |v| decrypt_strings(v, num, gen) }
          when Hash then value.transform_values! { |v| decrypt_strings(v, num, gen) }
          when Stream
            decrypt_strings(value.dict, num, gen)
            value
          else value
          end
        end

        # --- cross-reference data -----------------------------------------

        # Merged trailer of all cross-reference sections (newest wins).
        def read_xref
          offset = startxref
          trailers = []
          seen = {}
          while offset.is_a?(Integer) && !seen[offset] && seen.size < 256
            seen[offset] = true
            trailer = read_section(offset) or break
            trailers << trailer
            stream = trailer[:XRefStm]
            if stream.is_a?(Integer) && !seen[stream]
              seen[stream] = true
              read_section(stream)
            end
            offset = trailer[:Prev]
          end
          trailers.reverse.inject { |older, newer| older.merge(newer) }
        end

        def startxref
          from = [@data.bytesize - 4096, 0].max
          tail = @data.byteslice(from, @data.bytesize - from)
          i = tail.rindex("startxref") or return nil
          tail.byteslice(i + 9, 40)[/\A[\x00\t\n\f\r ]*(\d{1,12})/, 1]&.to_i
        end

        # Reads the section at +offset+ (or at +offset+ counted from the
        # header); returns its trailer dictionary or nil.
        def read_section(offset)
          positions = [offset]
          positions << offset + @header if @header.positive?
          positions.each do |pos|
            next unless pos.between?(0, @data.bytesize - 1)

            scanner = StringScanner.new(@data)
            scanner.pos = pos
            Parser.skip_space(scanner, @data)
            trailer = begin
              if scanner.scan(/xref/)
                read_table(scanner)
              else
                read_xref_stream(scanner.pos)
              end
            rescue ParseError
              nil
            end
            return trailer if trailer
          end
          nil
        end

        def read_table(s)
          until s.match?(TRAILER_AHEAD)
            break unless s.scan(SUBSECTION)

            start = s[1].to_i
            count = s[2].to_i
            i = 0
            while i < count && (@xref_left -= 1) >= 0 && s.scan(XREF_ENTRY)
              offset = s[1].to_i
              if s[3] == "n"
                register(start + i, offset) if offset.positive?
              elsif i.zero? && start == 1 && s[2] == "65535"
                start = 0 # a common off-by-one: the table really starts at object 0
              end
              i += 1
            end
          end
          s.skip_until(/trailer/) or return nil
          @parser.pos = s.pos
          trailer = @parser.parse
          trailer.is_a?(Hash) ? trailer : nil
        end

        def read_xref_stream(pos)
          num, gen, dict, start = @parser.indirect(pos)
          return nil unless start && dict.is_a?(Hash) && (dict[:Type] == :XRef || dict.key?(:W))

          widths = dict[:W]
          return nil unless widths.is_a?(Array) && widths.size >= 3 &&
                            widths.first(3).all? { |w| w.is_a?(Integer) && w.between?(0, 8) }

          w0, w1, w2 = widths
          row = w0 + w1 + w2
          return dict if row.zero?

          index = dict[:Index].is_a?(Array) ? dict[:Index] : [0, int(dict[:Size]) || 0]
          rows = 0
          index.each_slice(2) { |_, count| rows += count if count.is_a?(Integer) && count.positive? }
          rows = @xref_left if rows > @xref_left
          return dict if rows <= 0

          stream = build_stream(dict, start, num, gen, resolve_length: false)
          filters, params = filter_chain(dict)
          data = Filters.decode(stream.raw, filters, params, rows * row)
          @xref_left -= data.bytesize / row
          pos = 0
          index.each_slice(2) do |first, count|
            break unless first.is_a?(Integer) && count.is_a?(Integer) && first >= 0

            pos = read_xref_rows(data, pos, first, count, w0, w1, w2)
          end
          dict
        rescue Error, *INTERNAL_ERRORS
          nil
        end

        def read_xref_rows(data, pos, first, count, w0, w1, w2)
          row = w0 + w1 + w2
          i = 0
          while i < count && pos + row <= data.bytesize
            type = w0.zero? ? 1 : be_int(data, pos, w0)
            field = be_int(data, pos + w0, w1)
            if type == 1
              register(first + i, field) if field.positive?
            elsif type == 2
              register(first + i, [field, be_int(data, pos + w0 + w1, w2)])
            end
            pos += row
            i += 1
          end
          pos
        end

        # Records where object +num+ is (the first entry found wins), up to
        # MAX_OBJECTS objects.
        def register(num, entry)
          @offsets[num] ||= entry if @offsets.size < MAX_OBJECTS || @offsets.key?(num)
        end

        # Rebuilds the cross-reference data by scanning the whole file.
        # Returns true if it ran (only the first call does).
        def rebuild
          return false if @rebuilt

          @rebuilt = true
          offsets = {}
          scan_objects { |num, offset| offsets[num] = offset if offsets.size < MAX_OBJECTS || offsets.key?(num) }
          @offsets = offsets
          @object_streams.clear
          @cache.clear
          scanned = scanned_trailer
          @trailer = (@trailer || {}).merge(scanned) { |_key, old, _new| old }
          setup_security if @security.nil? && !@securing && @trailer[:Encrypt]
          register_object_streams
          unless dict_value(@trailer[:Root])
            @trailer[:Root] = dict_value(scanned[:Root]) ? scanned[:Root] : find_catalog
          end
          true
        end

        # Yields [num, offset] of every "N G obj", skipping stream data. The
        # positions of the next keywords are cached so that the scan stays
        # linear in the file size.
        def scan_objects
          data = @data
          size = data.bytesize
          pos = 0
          stream = endobj = other = -1
          while (m = OBJ_SCAN.match(data, pos))
            yield m[1].to_i, m.begin(0)
            pos = m.end(0)
            stream = data.index("stream", pos) || size if stream < pos
            endobj = data.index("endobj", pos) || size if endobj < pos
            other = data.index("obj", pos) || size if other < pos
            next if stream == size || endobj < stream || other < stream

            stop = data.index("endstream", stream + 6) or next
            pos = stop + 9
          end
        end

        # Registers the objects of all object streams (direct objects win).
        def register_object_streams
          objects_containing("/ObjStm").each do |num|
            stream = object(num)
            next unless stream.is_a?(Stream) && resolve(stream.dict[:Type]) == :ObjStm

            container = object_stream(num) or next
            container[1].each_with_index do |(inner, _offset), index|
              next if @offsets[inner].is_a?(Integer) || (@offsets.size >= MAX_OBJECTS && !@offsets.key?(inner))

              @offsets[inner] = [num, index]
            end
          end
        end

        # Numbers of the direct objects whose text contains +needle+.
        def objects_containing(needle)
          sorted = @offsets.select { |_num, entry| entry.is_a?(Integer) }.sort_by { |_num, offset| offset }
          starts = sorted.map(&:last)
          found = []
          pos = 0
          while (pos = @data.index(needle, pos))
            i = starts.bsearch_index { |offset| offset > pos } || starts.size
            found << sorted[i - 1][0] if i.positive?
            pos += needle.bytesize
          end
          found.uniq
        end

        # Trailer entries from "trailer" dictionaries and cross-reference
        # stream dictionaries anywhere in the file (later ones win).
        def scanned_trailer
          trailer = {}
          @data.scan(TRAILER_DICT) do
            @parser.pos = ::Regexp.last_match.end(0) - 2
            dict = begin
              @parser.parse
            rescue ParseError
              nil
            end
            trailer.merge!(dict.slice(*TRAILER_KEYS)) if dict.is_a?(Hash)
          end
          objects_containing("/XRef").each do |num|
            _, _, dict, = @parser.indirect(@offsets[num])
            trailer.merge!(dict.slice(*TRAILER_KEYS)) if dict.is_a?(Hash) && dict[:Type] == :XRef
          rescue ParseError
            next
          end
          trailer
        end

        def find_catalog
          candidates = objects_containing("/Catalog") + @offsets.select { |_num, entry| entry.is_a?(Array) }.keys
          num = candidates.find { |n| dict_value(Ref.new(n, 0))&.[](:Type) == :Catalog }
          num && Ref.new(num, 0)
        end

        # --- encryption ------------------------------------------------------

        def setup_security
          encrypt = @trailer && @trailer[:Encrypt]
          return unless encrypt

          @securing = true
          @encrypt_num = encrypt.num if encrypt.is_a?(Ref)
          dict = dict_value(encrypt) or raise UnsupportedImageError, "encrypted PDF with an invalid /Encrypt dictionary"
          ids = resolve(@trailer[:ID])
          id = ids.is_a?(Array) ? resolve(ids[0]) : nil
          @security = Security.new(dict, id.is_a?(String) ? id : "".b, self)
          @cache.clear # objects loaded so far were not decrypted
          @object_streams.clear
        ensure
          @securing = false
        end
      end

      # Standard security handler with an empty user password (ISO 32000-1
      # 7.6.3, ISO 32000-2 7.6.4): RC4 40-128 bit, AES-128 and AES-256.
      class Security
        include Util

        PADDING = [
          0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, 0x64, 0x00, 0x4E, 0x56, 0xFF, 0xFA, 0x01, 0x08,
          0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80, 0x2F, 0x0C, 0xA9, 0xFE, 0x64, 0x53, 0x69, 0x7A
        ].pack("C*").freeze
        PASSWORD = "password-protected PDF (only documents with an empty user password can be decrypted)"

        def initialize(dict, id, document)
          begin
            require "digest"
            require "openssl"
          rescue LoadError
            raise UnsupportedImageError, "encrypted PDF (needs the openssl library)"
          end
          @doc = document
          filter = document.resolve(dict[:Filter])
          raise UnsupportedImageError, "encrypted PDF (security handler #{filter})" unless filter == :Standard

          @v = int(document.resolve(dict[:V])) || 0
          @r = int(document.resolve(dict[:R])) || 2
          case @v
          when 1, 2 then setup_rc4(dict, id, @v == 1 ? 40 : int(document.resolve(dict[:Length])) || 40)
          when 4 then setup_crypt_filters(dict, id)
          when 5 then setup_aes256(dict)
          else raise UnsupportedImageError, "encrypted PDF (unsupported encryption version #{@v})"
          end
        rescue Error
          raise
        rescue StandardError => e # OpenSSL errors for malformed keys
          raise UnsupportedImageError, "encrypted PDF (#{e.class}: #{e.message})"
        end

        def decrypt_string(data, num, gen)
          decrypt(@string_method, data, num, gen)
        end

        def decrypt_stream(data, num, gen)
          decrypt(@stream_method, data, num, gen)
        end

        private

        def setup_rc4(dict, id, bits)
          @key = file_key(dict, id, (bits / 8).clamp(5, 16))
          @stream_method = @string_method = :rc4
        end

        def setup_crypt_filters(dict, id)
          filters = @doc.dict_value(dict[:CF]) || {}
          methods = %i[StmF StrF].map do |key|
            name = @doc.resolve(dict[key]) || :Identity
            next :identity if name == :Identity

            cf = @doc.dict_value(filters[name]) or raise UnsupportedImageError, "encrypted PDF (crypt filter #{name})"
            case @doc.resolve(cf[:CFM])
            when :V2 then :rc4
            when :AESV2 then :aes128
            when :None, nil then :identity
            else raise UnsupportedImageError, "encrypted PDF (crypt filter method #{cf[:CFM]})"
            end
          end
          @stream_method, @string_method = methods
          bits = int(@doc.resolve(dict[:Length])) || 128
          bits *= 8 if bits <= 16 # some writers give bytes
          bits = 128 if methods.include?(:aes128)
          @key = file_key(dict, id, (bits / 8).clamp(5, 16))
        end

        # Algorithms 2 and 4/5: file key from the empty user password,
        # checked against /U.
        def file_key(dict, id, length)
          o = string(dict[:O])
          u = string(dict[:U])
          p = int(@doc.resolve(dict[:P])) || 0
          md5 = Digest::MD5.new
          md5 << PADDING << o.byteslice(0, 32) << [p & 0xFFFFFFFF].pack("V") << id
          md5 << "\xFF\xFF\xFF\xFF".b if @r >= 4 && @doc.resolve(dict[:EncryptMetadata]) == false
          key = md5.digest
          length = 5 if @r == 2
          50.times { key = Digest::MD5.digest(key.byteslice(0, length)) } if @r >= 3
          key = key.byteslice(0, length)
          valid = if @r == 2
                    rc4(key, PADDING) == u.byteslice(0, 32)
                  else
                    x = rc4(key, Digest::MD5.digest(PADDING + id))
                    1.upto(19) { |i| x = rc4(key.bytes.map { |b| b ^ i }.pack("C*"), x) }
                    x == u.byteslice(0, 16)
                  end
          raise UnsupportedImageError, PASSWORD unless valid

          key
        end

        def setup_aes256(dict)
          u = string(dict[:U])
          ue = string(dict[:UE])
          raise UnsupportedImageError, "encrypted PDF (invalid /U or /UE)" if u.bytesize < 48 || ue.bytesize < 32

          empty = "".b
          check = @r >= 6 ? hash_r6(empty, u.byteslice(32, 8)) : Digest::SHA256.digest(u.byteslice(32, 8))
          raise UnsupportedImageError, PASSWORD unless check == u.byteslice(0, 32)

          intermediate = @r >= 6 ? hash_r6(empty, u.byteslice(40, 8)) : Digest::SHA256.digest(u.byteslice(40, 8))
          cipher = OpenSSL::Cipher.new("AES-256-CBC").decrypt
          cipher.key = intermediate
          cipher.iv = "\0".b * 16
          cipher.padding = 0
          @key = cipher.update(ue.byteslice(0, 32)) + cipher.final
          filters = @doc.dict_value(dict[:CF]) || {}
          @stream_method, @string_method = %i[StmF StrF].map do |key|
            name = @doc.resolve(dict[key]) || :Identity
            cf = @doc.dict_value(filters[name])
            name == :Identity || (cf && @doc.resolve(cf[:CFM]) == :None) ? :identity : :aes256
          end
        end

        # ISO 32000-2 Algorithm 2.B (empty password, no user key data).
        def hash_r6(password, salt)
          k = Digest::SHA256.digest(password + salt)
          i = 0
          loop do
            k1 = (password + k) * 64
            cipher = OpenSSL::Cipher.new("AES-128-CBC").encrypt
            cipher.key = k.byteslice(0, 16)
            cipher.iv = k.byteslice(16, 16)
            cipher.padding = 0
            e = cipher.update(k1) + cipher.final
            k = case e.byteslice(0, 16).sum % 3
                when 0 then Digest::SHA256.digest(e)
                when 1 then Digest::SHA384.digest(e)
                else Digest::SHA512.digest(e)
                end
            i += 1
            break if i >= 64 && e.getbyte(-1) <= i - 32
          end
          k.byteslice(0, 32)
        end

        def string(value)
          value = @doc.resolve(value)
          value.is_a?(String) ? value : "".b
        end

        def decrypt(method, data, num, gen)
          case method
          when :rc4 then rc4(object_key(num, gen, false), data)
          when :aes128 then aes_cbc("AES-128-CBC", object_key(num, gen, true), data)
          when :aes256 then aes_cbc("AES-256-CBC", @key, data)
          else data
          end
        rescue OpenSSL::Cipher::CipherError => e
          raise ImageError, "cannot decrypt PDF data (#{e.message})"
        end

        def object_key(num, gen, aes)
          material = @key + [num].pack("V").byteslice(0, 3) + [gen].pack("V").byteslice(0, 2)
          material << "sAlT" if aes
          Digest::MD5.digest(material).byteslice(0, [@key.bytesize + 5, 16].min)
        end

        def aes_cbc(name, key, data)
          return "".b if data.bytesize < 32

          cipher = OpenSSL::Cipher.new(name).decrypt
          cipher.key = key
          cipher.iv = data.byteslice(0, 16)
          cipher.padding = 0
          out = cipher.update(data.byteslice(16, (data.bytesize - 16) & ~15)) + cipher.final
          pad = out.getbyte(-1) || 0
          if pad.between?(1, 16) && out.byteslice(-pad, pad).bytes.all?(pad)
            out.byteslice(0, out.bytesize - pad)
          else
            out
          end
        end

        def rc4(key, data)
          @openssl_rc4 = openssl_rc4? if @openssl_rc4.nil?
          return RC4.new(key).process(data) unless @openssl_rc4

          cipher = OpenSSL::Cipher.new("RC4").decrypt
          cipher.key_len = key.bytesize
          cipher.key = key
          cipher.update(data) + cipher.final
        end

        # OpenSSL 3 only offers RC4 with its legacy provider loaded.
        def openssl_rc4?
          OpenSSL::Cipher.new("RC4")
          true
        rescue OpenSSL::Cipher::CipherError, RuntimeError
          false
        end

        # Pure-Ruby RC4 (processed in chunks so that YJIT compiles the loop).
        class RC4
          def initialize(key)
            s = (0..255).to_a
            j = 0
            n = key.bytesize
            256.times do |i|
              j = (j + s[i] + key.getbyte(i % n)) & 255
              s[i], s[j] = s[j], s[i]
            end
            @s = s
            @i = 0
            @j = 0
          end

          def process(data)
            n = data.bytesize
            out = "\0".b * n
            pos = 0
            while pos < n
              stop = [pos + 4096, n].min
              chunk(data, out, pos, stop)
              pos = stop
            end
            out
          end

          private

          def chunk(data, out, k, stop)
            s = @s
            i = @i
            j = @j
            while k < stop
              i = (i + 1) & 255
              si = s[i]
              j = (j + si) & 255
              sj = s[j]
              s[i] = sj
              s[j] = si
              out.setbyte(k, data.getbyte(k) ^ s[(si + sj) & 255])
              k += 1
            end
            @i = i
            @j = j
          end
        end
      end

      # Stream filters (ISO 32000-1 7.4) other than the image codecs.
      module Filters
        extend Util

        ABBREVIATIONS = {
          AHx: :ASCIIHexDecode, A85: :ASCII85Decode, LZW: :LZWDecode, Fl: :FlateDecode,
          RL: :RunLengthDecode, CCF: :CCITTFaxDecode, DCT: :DCTDecode
        }.freeze
        NONZERO = /[^\x00]/n
        HEX_DIGITS = "^0-9A-Fa-f"
        WHITESPACE = "\x00\t\n\f\r "

        class << self
          # Applies +filters+ in order; the output of the last one is cut
          # at +limit+ bytes. (Intermediate results are encoded data of the
          # later filters, which never needs much more room than the result.)
          def decode(data, filters, params, limit)
            last = filters.size - 1
            filters.each_with_index do |filter, i|
              data = apply(data, filter, params[i] || {}, i == last ? limit : 2 * limit + 4096)
            end
            data.bytesize > limit ? data.byteslice(0, limit) : data
          end

          private

          def apply(data, filter, params, limit)
            case filter
            when :FlateDecode then unpredict(inflate(data, predicted_limit(params, limit)), params, limit)
            when :LZWDecode
              early = int(params[:EarlyChange]) == 0 ? 0 : 1
              unpredict(QrReaderKernels.lzw_decode(data, predicted_limit(params, limit), early, false), params, limit)
            when :RunLengthDecode then run_length(data, limit)
            when :ASCIIHexDecode then ascii_hex(data)
            when :ASCII85Decode then ascii85(data)
            when :Crypt then data
            else raise UnsupportedImageError, "unsupported PDF filter /#{filter}"
            end
          end

          # Room for the PNG predictor's tag bytes.
          def predicted_limit(params, limit)
            (int(params[:Predictor]) || 1) >= 10 ? limit * 2 + 64 : limit
          end

          def inflate(data, limit)
            inflate_with(Zlib::Inflate.new(Zlib::MAX_WBITS + 32), data, limit) ||
              inflate_with(Zlib::Inflate.new(-Zlib::MAX_WBITS), data, limit) ||
              raise(ImageError, "corrupt Flate data")
          end

          # Inflated data (partial for truncated or damaged streams), nil if
          # nothing could be inflated.
          def inflate_with(zstream, data, limit)
            out = String.new(encoding: Encoding::BINARY)
            full = false
            begin
              zstream.inflate(data) do |chunk|
                out << chunk
                full = out.bytesize >= limit
                break if full
              end
            rescue Zlib::Error
              failed = true
            end
            # Output of an unfinished stream is not yielded.
            out << zstream.flush_next_out.to_s unless full
            failed && out.empty? ? nil : out
          ensure
            zstream.reset unless zstream.closed? || zstream.finished?
            zstream.close unless zstream.closed?
          end

          def unpredict(data, params, limit)
            predictor = int(params[:Predictor]) || 1
            return data if predictor < 2

            colors = (int(params[:Colors]) || 1).clamp(1, 64)
            bpc = int(params[:BitsPerComponent]) || 8
            raise ImageError, "invalid predictor BitsPerComponent #{bpc}" unless [1, 2, 4, 8, 16].include?(bpc)

            columns = int(params[:Columns]) || 1
            columns = 1 if columns < 1
            row = (columns * colors * bpc + 7) / 8
            # (Rows are allocated whole: one longer than the output limit
            # would be a crafted allocation, never an image.)
            raise ImageError, "invalid predictor Columns #{columns}" if row > limit + 1
            if predictor == 2
              tiff_unpredict(data, row, colors, bpc)
            else
              png_unpredict(data, row, [(colors * bpc + 7) / 8, 1].max, limit)
            end
          end

          def png_unpredict(data, row, bpp, limit)
            src_row = row + 1
            rows = [(data.bytesize + row - 1) / src_row, limit / row + 1].min
            return "".b if rows <= 0

            missing = rows * src_row - data.bytesize
            data += "\0".b * missing if missing.positive?
            out = "\0".b * (rows * row)
            r = 0
            while r < rows
              src = r * src_row
              png_row(data.getbyte(src), data, src + 1, out, r * row, row, bpp, r.positive?)
              r += 1
            end
            out
          end

          # Reverses one PNG-filtered row (types 0-4) into +out+ at +dst+.
          def png_row(type, src, so, out, dst, len, bpp, has_up)
            case type
            when 1 then bpp == 1 ? png_sub1(src, so, out, dst, len) : png_sub(src, so, out, dst, len, bpp)
            when 2
              return out.bytesplice(dst, len, src.byteslice(so, len)) unless has_up

              nz = src.index(NONZERO, so)
              return out.bytesplice(dst, len, out.byteslice(dst - len, len)) if nz.nil? || nz >= so + len

              png_up(src, so, out, dst, len)
            when 3
              i = 0
              while i < len
                left = i >= bpp ? out.getbyte(dst + i - bpp) : 0
                up = has_up ? out.getbyte(dst - len + i) : 0
                out.setbyte(dst + i, (src.getbyte(so + i) + ((left + up) >> 1)) & 255)
                i += 1
              end
            when 4
              i = 0
              while i < len
                a = i >= bpp ? out.getbyte(dst + i - bpp) : 0
                b = has_up ? out.getbyte(dst - len + i) : 0
                c = has_up && i >= bpp ? out.getbyte(dst - len + i - bpp) : 0
                p = a + b - c
                pa = (p - a).abs
                pb = (p - b).abs
                pc = (p - c).abs
                pred = if pa <= pb && pa <= pc then a
                       elsif pb <= pc then b
                       else c
                       end
                out.setbyte(dst + i, (src.getbyte(so + i) + pred) & 255)
                i += 1
              end
            else
              out.bytesplice(dst, len, src.byteslice(so, len))
            end
          end

          # Sub with one byte per pixel: a running sum.
          def png_sub1(src, so, out, dst, len)
            left = 0
            i = so
            o = dst
            stop = so + len
            while i < stop
              left = (src.getbyte(i) + left) & 255
              out.setbyte(o, left)
              i += 1
              o += 1
            end
          end

          def png_sub(src, so, out, dst, len, bpp)
            out.bytesplice(dst, bpp, src.byteslice(so, bpp))
            i = bpp
            while i < len
              out.setbyte(dst + i, (src.getbyte(so + i) + out.getbyte(dst + i - bpp)) & 255)
              i += 1
            end
          end

          def png_up(src, so, out, dst, len)
            i = so
            o = dst
            u = dst - len
            stop = so + len
            while i < stop
              out.setbyte(o, (src.getbyte(i) + out.getbyte(u)) & 255)
              i += 1
              o += 1
              u += 1
            end
          end

          # TIFF predictor 2: horizontal differencing per component.
          def tiff_unpredict(data, row, colors, bpc)
            out = data.dup
            rows = out.bytesize / row
            r = 0
            while r < rows
              case bpc
              when 8 then tiff_row8(out, r * row, row, colors)
              when 16 then tiff_row16(out, r * row, row, colors)
              else tiff_row_bits(out, r * row, row, colors, bpc)
              end
              r += 1
            end
            out
          end

          def tiff_row8(out, off, len, colors)
            i = colors
            while i < len
              out.setbyte(off + i, (out.getbyte(off + i) + out.getbyte(off + i - colors)) & 255)
              i += 1
            end
          end

          def tiff_row16(out, off, len, colors)
            step = 2 * colors
            i = step
            while i + 1 < len
              v = ((out.getbyte(off + i) << 8) | out.getbyte(off + i + 1)) +
                  ((out.getbyte(off + i - step) << 8) | out.getbyte(off + i - step + 1))
              out.setbyte(off + i, (v >> 8) & 255)
              out.setbyte(off + i + 1, v & 255)
              i += 2
            end
          end

          def tiff_row_bits(out, off, len, colors, bpc)
            mask = (1 << bpc) - 1
            samples = len * 8 / bpc
            i = colors
            while i < samples
              v = (sample(out, off, i, bpc) + sample(out, off, i - colors, bpc)) & mask
              bit = i * bpc
              shift = 8 - bpc - (bit & 7)
              byte = off + (bit >> 3)
              out.setbyte(byte, (out.getbyte(byte) & ~(mask << shift)) | (v << shift))
              i += 1
            end
          end

          def sample(data, off, i, bpc)
            bit = i * bpc
            (data.getbyte(off + (bit >> 3)) >> (8 - bpc - (bit & 7))) & ((1 << bpc) - 1)
          end

          def run_length(data, limit)
            out = String.new(encoding: Encoding::BINARY)
            pos = 0
            n = data.bytesize
            while pos < n && out.bytesize < limit
              len = data.getbyte(pos)
              pos += 1
              if len < 128
                out << data.byteslice(pos, len + 1)
                pos += len + 1
              elsif len > 128
                break if pos >= n

                out << (data.byteslice(pos, 1) * (257 - len))
                pos += 1
              else
                break
              end
            end
            out
          end

          def ascii_hex(data)
            stop = data.index(">")
            data = data.byteslice(0, stop) if stop
            hex = data.delete(HEX_DIGITS)
            hex << "0" if hex.bytesize.odd?
            [hex].pack("H*")
          end

          def ascii85(data)
            stop = data.index("~>")
            data = data.byteslice(0, stop) if stop
            data = data.delete(WHITESPACE)
            data = data.byteslice(2, data.bytesize - 2) if data.start_with?("<~")
            data = data.gsub("z", "!!!!!") if data.include?("z")
            bad = data.index(/[^!-u]/)
            data = data.byteslice(0, bad) if bad
            full = data.bytesize / 5
            words = []
            pos = 0
            while pos < full
              stop = [pos + 1024, full].min
              ascii85_groups(data, pos, stop, words)
              pos = stop
            end
            out = words.pack("N*")
            rest = data.bytesize - full * 5
            if rest > 1
              tail = []
              ascii85_groups(data.byteslice(full * 5, rest) + ("u" * (5 - rest)), 0, 1, tail)
              out << tail.pack("N").byteslice(0, rest - 1)
            end
            out
          end

          def ascii85_groups(data, group, stop, words)
            while group < stop
              o = group * 5
              v = data.getbyte(o) - 33
              v = v * 85 + data.getbyte(o + 1) - 33
              v = v * 85 + data.getbyte(o + 2) - 33
              v = v * 85 + data.getbyte(o + 3) - 33
              v = v * 85 + data.getbyte(o + 4) - 33
              words << (v & 0xFFFFFFFF)
              group += 1
            end
          end
        end
      end

      # Colour spaces reduced to what luminance needs.
      class ColorSpace
        attr_reader :kind, :components

        def initialize(kind, components, palette: nil, none: false)
          @kind = kind
          @components = components
          @palette = palette
          @none = none
        end

        GRAY = new(:gray, 1)
        RGB = new(:rgb, 3)
        CMYK = new(:cmyk, 4)
        LAB = new(:lab, 3)
        MASK = new(:gray, 1)

        class << self
          # Colour space of an image's /ColorSpace value (names are looked
          # up in the resources); nil when the value is missing.
          def build(doc, spec, resources, depth = 0)
            spec = doc.resolve(spec)
            return nil if spec.nil?
            raise UnsupportedImageError, "colour spaces nested too deeply" if depth > 8

            family = spec.is_a?(Array) ? doc.resolve(spec[0]) : spec
            case family
            when :DeviceGray, :CalGray, :G then GRAY
            when :DeviceRGB, :CalRGB, :RGB then RGB
            when :DeviceCMYK, :CMYK then CMYK
            when :Lab then LAB
            when :ICCBased then icc(doc, spec, resources, depth)
            when :Indexed, :I then indexed(doc, spec, resources, depth)
            when :Separation then new(:separation, 1, none: spec.is_a?(Array) && doc.resolve(spec[1]) == :None)
            when :DeviceN then device_n(doc, spec)
            when :Pattern then raise UnsupportedImageError, "image with a pattern colour space"
            when Symbol
              named = doc.dict_value(doc.dict_value(resources)&.[](:ColorSpace))&.[](family)
              raise UnsupportedImageError, "unknown colour space /#{family}" if named.nil?

              build(doc, named, resources, depth + 1)
            else raise UnsupportedImageError, "invalid colour space"
            end
          end

          # Luminance of CMYK ink amounts (0..255), with the formula of the
          # JPEG decoder (which sees Adobe's inverted CMYK).
          def cmyk_luma(c, m, y, k)
            kk = 255 - k
            Image.luma(((255 - c) * kk + 127) / 255, ((255 - m) * kk + 127) / 255, ((255 - y) * kk + 127) / 255)
          end

          private

          def icc(doc, spec, resources, depth)
            stream = spec.is_a?(Array) ? doc.resolve(spec[1]) : nil
            dict = stream.is_a?(Stream) ? stream.dict : {}
            case doc.resolve(dict[:N])
            when 1 then GRAY
            when 3 then RGB
            when 4 then CMYK
            else
              alternate = dict[:Alternate] or raise UnsupportedImageError, "ICCBased colour space without /N"
              build(doc, alternate, resources, depth + 1)
            end
          end

          def indexed(doc, spec, resources, depth)
            raise UnsupportedImageError, "invalid Indexed colour space" unless spec.is_a?(Array) && spec.size >= 4

            base = build(doc, spec[1], resources, depth + 1)
            raise UnsupportedImageError, "invalid Indexed base colour space" if base.nil? || base.kind == :indexed

            hival = Util.int(doc.resolve(spec[2]))&.clamp(0, 255) || 0
            lookup = doc.resolve(spec[3])
            lookup = doc.decode_stream(lookup, (hival + 1) * base.components) if lookup.is_a?(Stream)
            raise UnsupportedImageError, "invalid Indexed lookup table" unless lookup.is_a?(String)

            n = base.components
            palette = Array.new(hival + 1) { |i| base.luma_at(lookup, i * n) }
            new(:indexed, 1, palette: palette)
          end

          def device_n(doc, spec)
            names = spec.is_a?(Array) ? doc.resolve(spec[1]) : nil
            unless names.is_a?(Array) && names.size.between?(1, 32)
              raise UnsupportedImageError, "invalid DeviceN colour space"
            end

            new(:device_n, names.size, none: names.all? { |n| doc.resolve(n) == :None })
          end
        end

        # [min, max] decode range per component.
        def decode_ranges(decode, bpc)
          if decode.is_a?(Array) && decode.size >= 2 * @components
            ranges = decode.first(2 * @components).map { |v| Util.number(v) }
            return ranges.each_slice(2).to_a unless ranges.include?(nil)
          end
          case @kind
          when :indexed then [[0.0, ((1 << bpc) - 1).to_f]]
          when :lab then [[0.0, 100.0], [-100.0, 100.0], [-100.0, 100.0]]
          else [[0.0, 1.0]] * @components
          end
        end

        # Per component: sample value (the high byte for 16 bits) ->
        # component value 0..255 (or palette index).
        def component_luts(bpc, decode)
          maxv = ((1 << bpc) - 1).to_f
          size = bpc == 16 ? 256 : (1 << bpc)
          step = bpc == 16 ? 257 : 1
          decode_ranges(decode, bpc).each_with_index.map do |(dmin, dmax), c|
            Array.new(size) { |s| normalize(c, dmin + (s * step) * (dmax - dmin) / maxv) }
          end
        end

        # Single-component spaces: sample value -> luminance.
        def luma_lut(bpc, decode)
          component_luts(bpc, decode).first.map { |v| luma1(v) }
        end

        # True if the decode array inverts every component.
        def inverted?(decode, bpc = 8)
          decode_ranges(decode, bpc).all? { |dmin, dmax| dmin > dmax }
        end

        # Luminance of the 8-bit components at +offset+ of a lookup table.
        def luma_at(bytes, offset)
          c = Array.new(@components) { |i| bytes.getbyte(offset + i) || 0 }
          case @kind
          when :gray, :lab then c[0]
          when :rgb then Image.luma(c[0], c[1], c[2])
          when :cmyk then ColorSpace.cmyk_luma(c[0], c[1], c[2], c[3])
          else @none ? 255 : 255 - c.max
          end
        end

        private

        def normalize(component, value)
          case @kind
          when :indexed then value.round.clamp(0, @palette.size - 1)
          when :lab then component.zero? ? (value * 2.55).round.clamp(0, 255) : 0
          else (value * 255).round.clamp(0, 255)
          end
        end

        def luma1(value)
          case @kind
          when :indexed then @palette[value]
          when :separation, :device_n then @none ? 255 : 255 - value
          else value
          end
        end
      end

      # Per-row pixel loops (YJIT compiles methods that are called often,
      # never a loop in a method entered once).
      module Pixels
        # Byte -> its four 2-bit samples, as Integers.
        TWO_BIT = Array.new(256) { |b| [b >> 6, (b >> 4) & 3, (b >> 2) & 3, b & 3] }.freeze

        module_function

        def rgb(src, off, n, out)
          i = off
          stop = off + 3 * n
          while i < stop
            out << ((306 * src.getbyte(i) + 601 * src.getbyte(i + 1) + 117 * src.getbyte(i + 2) + 0x200) >> 10)
            i += 3
          end
        end

        def cmyk(src, off, n, out)
          i = off
          stop = off + 4 * n
          while i < stop
            kk = 255 - src.getbyte(i + 3)
            r = ((255 - src.getbyte(i)) * kk + 127) / 255
            g = ((255 - src.getbyte(i + 1)) * kk + 127) / 255
            b = ((255 - src.getbyte(i + 2)) * kk + 127) / 255
            out << ((306 * r + 601 * g + 117 * b + 0x200) >> 10)
            i += 4
          end
        end

        # Every +stride+-th byte (Lab: L*).
        def first(src, off, n, out, stride)
          i = off
          stop = off + stride * n
          while i < stop
            out << src.getbyte(i)
            i += stride
          end
        end

        # DeviceN: the darkest tint wins.
        def device_n(src, off, n, out, stride)
          i = off
          stop = off + stride * n
          while i < stop
            max = 0
            j = i
            e = i + stride
            while j < e
              v = src.getbyte(j)
              max = v if v > max
              j += 1
            end
            out << (255 - max)
            i += stride
          end
        end

        def high_bytes(src, off, n, out)
          i = off
          stop = off + 2 * n
          while i < stop
            out << src.getbyte(i)
            i += 2
          end
        end

        def two_bit(src, off, nbytes, out, lut)
          i = off
          stop = off + nbytes
          while i < stop
            b = src.getbyte(i)
            out << lut[b >> 6] << lut[(b >> 4) & 3] << lut[(b >> 2) & 3] << lut[b & 3]
            i += 1
          end
        end

        # Colour conversion with a separate lookup table per component.
        def mapped(src, off, n, out, kind, luts)
          ncomp = luts.size
          i = off
          stop = off + ncomp * n
          c = Array.new(ncomp, 0)
          while i < stop
            k = 0
            while k < ncomp
              c[k] = luts[k][src.getbyte(i + k)]
              k += 1
            end
            out << case kind
                   when :rgb then Image.luma(c[0], c[1], c[2])
                   when :cmyk then ColorSpace.cmyk_luma(c[0], c[1], c[2], c[3])
                   when :lab then c[0]
                   else 255 - c.max
                   end
            i += ncomp
          end
        end
      end

      # Runs content streams and collects the images they draw.
      class ContentScanner
        MAX_FORM_DEPTH = 12
        MAX_OPERANDS = 32
        MAX_STACK = 256
        IDENTITY = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0].freeze
        INLINE_KEYS = {
          BPC: :BitsPerComponent, CS: :ColorSpace, D: :Decode, DP: :DecodeParms, F: :Filter,
          H: :Height, IM: :ImageMask, I: :Interpolate, W: :Width, L: :Length
        }.freeze
        EI = %r{EI(?![^\x00\t\n\f\r ()<>\[\]{}/%])}
        EI_AFTER_SPACE = %r{[\x00\t\n\f\r ]EI(?![^\x00\t\n\f\r ()<>\[\]{}/%])}
        TEXTUAL = /\A[\t\n\r\x20-\x7E]*\z/
        STRING_SPECIAL = /[()\\]/

        def initialize(doc)
          @doc = doc
          @images = []
          @seen = {}
          @forms = {}
        end

        def images(content, resources)
          scan(content, resources, IDENTITY, 0)
          @images
        end

        private

        def scan(data, resources, ctm, depth)
          s = StringScanner.new(data)
          operands = []
          stack = []
          space_run = Parser::SPACE_RUN
          space_byte = Parser::SPACE_BYTE
          token_run = Parser::TOKEN_RUN
          delimiter_byte = Parser::DELIMITER_BYTE
          while true
            # (Parser.skip_space, with its common case inlined.)
            s.skip(space_run)
            b = data.getbyte(s.pos) or break
            b = Parser.skip_space(s, data) or break if b == 0x25 || space_byte[b]
            case b
            when 0x2F then operand(operands, Parser.scan_token(s, data, Parser::NAME_RUN))
            when 0x28
              skip_string(s, data)
              operand(operands, nil)
            when 0x3C
              if data.getbyte(s.pos + 1) == 0x3C
                s.pos += 2
              else
                s.skip_until(/>/) || s.terminate
                operand(operands, nil)
              end
            when 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x29, 0x25 then s.pos += 1
            else
              # (Parser.scan_token inlined.)
              token = s.scan(token_run)
              n = data.getbyte(s.pos)
              s.pos = data.index(Parser::DELIMITER, s.pos) || data.bytesize if n && !delimiter_byte[n]
              if b <= 0x39 && (b >= 0x30 || b == 0x2B || b == 0x2D || b == 0x2E)
                operands << token
                operands.shift if operands.size > MAX_OPERANDS
                next
              end
              case token
              when "cm" then ctm = multiply(operands.last(6).map(&:to_f), ctm) if operands.size >= 6
              when "q" then stack << ctm if stack.size < MAX_STACK
              when "Q" then ctm = stack.pop || ctm
              when "Do" then draw(operands.last, resources, ctm, depth)
              when "BI" then inline_image(s, data, resources, ctm)
              end
              operands.clear
            end
          end
        end

        # Keeps the last MAX_OPERANDS operands (operators take at most 6).
        def operand(operands, value)
          operands << value
          operands.shift if operands.size > MAX_OPERANDS
        end

        def skip_string(s, data)
          s.pos += 1
          depth = 1
          while depth.positive?
            unless s.skip_until(STRING_SPECIAL)
              s.terminate
              return
            end
            case data.getbyte(s.pos - 1)
            when 0x5C then s.pos += 1 unless s.eos?
            when 0x28 then depth += 1
            else depth -= 1
            end
          end
        end

        # m x ctm (both [a b c d e f]).
        def multiply(m, n)
          a, b, c, d, e, f = m
          na, nb, nc, nd, ne, nf = n
          [a * na + b * nc, a * nb + b * nd, c * na + d * nc, c * nb + d * nd,
           e * na + f * nc + ne, e * nb + f * nd + nf]
        end

        def draw(token, resources, ctm, depth)
          return unless token.is_a?(String)

          name = Parser.name_symbol(token)
          xobjects = @doc.dict_value(@doc.dict_value(resources)&.[](:XObject)) or return
          ref = xobjects[name]
          stream = @doc.resolve(ref)
          return unless stream.is_a?(Stream)

          key = ref.is_a?(Ref) ? ref : stream.object_id
          dict = stream.dict
          subtype = @doc.resolve(dict[:Subtype])
          if subtype == :Image || (subtype.nil? && dict.key?(:Width))
            return if @seen[key]

            @seen[key] = true
            @images << ImageSource.new(dict, stream, nil, resources, name.to_s, ctm)
          elsif subtype == :Form || subtype.nil?
            return if depth >= MAX_FORM_DEPTH || @forms[key]

            @forms[key] = true
            content = @doc.content(stream) or return
            matrix = @doc.resolve(dict[:Matrix])
            matrix = matrix.map { |v| Util.number(@doc.resolve(v)) || 0.0 } if matrix.is_a?(Array) && matrix.size == 6
            ctm = multiply(matrix, ctm) if matrix.is_a?(Array) && matrix.size == 6
            scan(content, dict.key?(:Resources) ? dict[:Resources] : resources, ctm, depth + 1)
          end
        end

        def inline_image(s, data, resources, ctm)
          parser = Parser.new(data)
          parser.pos = s.pos
          dict = {}
          loop do
            key = parser.parse
            break if key.is_a?(Keyword) && key.word == "ID"
            raise ParseError, "invalid inline image" unless key.is_a?(Symbol) && dict.size < 64

            value = parser.parse
            raise ParseError, "invalid inline image" if value.is_a?(Keyword)

            dict[INLINE_KEYS.fetch(key, key)] = value
          end
          start = parser.pos
          start += 1 if start < data.bytesize && " \t\n\f\r\x00".include?(data.byteslice(start, 1))
          stop, after = extent(data, start, dict, resources)
          s.pos = after
          @images << ImageSource.new(dict, nil, data.byteslice(start, stop - start), resources, nil, ctm)
        rescue ParseError
          s.skip_until(EI) || s.terminate
        end

        # [end of the image data, position after EI].
        def extent(data, start, dict, resources)
          length = Util.int(@doc.resolve(dict[:Length]))
          if length && length >= 0 && (after = ei_at(data, start + length))
            return [start + length, after]
          end

          filters, = @doc.filter_chain(dict)
          if filters.empty?
            size = raw_size(dict, resources)
            return [start + size, after] if size && (after = ei_at(data, start + size))
          else
            marker = { ASCIIHexDecode: ">", ASCII85Decode: "~>" }[filters.first]
            if marker && (stop = data.index(marker, start)) && (after = ei_at(data, stop + marker.bytesize))
              return [stop + marker.bytesize, after]
            end
          end
          search(data, start)
        end

        def raw_size(dict, resources)
          width = Util.positive(@doc.resolve(dict[:Width])) or return nil
          height = Util.positive(@doc.resolve(dict[:Height])) or return nil
          mask = @doc.resolve(dict[:ImageMask]) == true
          bpc = mask ? 1 : Util.positive(@doc.resolve(dict[:BitsPerComponent])) || 8
          components = mask ? 1 : ColorSpace.build(@doc, dict[:ColorSpace], resources)&.components || 1
          (width * components * bpc + 7) / 8 * height
        rescue Error
          nil
        end

        # Position after an "EI" at +pos+ (after optional white space).
        def ei_at(data, pos)
          return nil if pos > data.bytesize

          pos = data.index(Parser::NOT_SPACE, pos) or return nil
          return nil unless data.getbyte(pos) == 0x45 && data.getbyte(pos + 1) == 0x49 # EI
          return nil unless (after = data.getbyte(pos + 2)).nil? || Parser::DELIMITERS.include?(after)

          pos + 2
        end

        # First " EI" followed by something that looks like content stream
        # operators (binary image data rarely does).
        def search(data, start)
          pos = start
          while (i = data.index(EI_AFTER_SPACE, pos))
            after = i + 3
            return [i, after] if TEXTUAL.match?(data.byteslice(after, 48))

            pos = i + 1
          end
          [data.bytesize, data.bytesize]
        end
      end

      # Decodes one image (XObject or inline) to a luminance Image.
      class ImageDecoder
        include Util

        CODECS = %i[DCTDecode CCITTFaxDecode JBIG2Decode JPXDecode].freeze
        ALL_BYTES = Image::TR_ESCAPE.call((0..255).to_a)
        IDENTITY = (0..255).to_a.freeze
        SOF_MARKERS = [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF].freeze

        def initialize(doc, source, raw_jpeg = false)
          @doc = doc
          @source = source
          @dict = source.dict
          @raw_jpeg = raw_jpeg
        end

        def decode
          width = positive(value(:Width))
          height = positive(value(:Height))
          raise ImageError, "image without a valid /Width and /Height" unless width && height
          if width * height > MAX_PIXELS
            raise UnsupportedImageError, "PDF image too large (#{width}x#{height}, limit #{MAX_PIXELS} pixels)"
          end

          filters, params = @doc.filter_chain(@dict)
          codec = CODECS.include?(filters.last) ? filters.pop : nil
          codec_params = codec ? params.pop : nil
          mask = value(:ImageMask) == true
          space = mask ? ColorSpace::MASK : ColorSpace.build(@doc, @dict[:ColorSpace], @source.resources)
          decode = value(:Decode)
          decode = decode.map { |v| @doc.resolve(v) } if decode.is_a?(Array)
          data = @source.stream ? @doc.stream_bytes(@source.stream) : @source.data

          case codec
          when nil
            bpc = mask ? 1 : int(value(:BitsPerComponent)) || 8
            raw_image(data, filters, params, width, height, space || ColorSpace::GRAY, bpc, decode)
          when :DCTDecode
            dct_image(Filters.decode(data, filters, params, SAMPLE_LIMIT), width, height, space, decode)
          when :CCITTFaxDecode
            data = Filters.decode(data, filters, params, SAMPLE_LIMIT)
            ccitt_image(data, codec_params, width, height, one_component(space), decode)
          when :JBIG2Decode
            data = Filters.decode(data, filters, params, SAMPLE_LIMIT)
            jbig2_image(data, codec_params, width, height, one_component(space), decode)
          else
            raise UnsupportedImageError, "JPEG 2000 (JPXDecode) images are not supported"
          end
        end

        private

        def value(key)
          @doc.resolve(@dict[key])
        end

        def one_component(space)
          space && space.components == 1 ? space : ColorSpace::GRAY
        end

        def raw_image(data, filters, params, width, height, space, bpc, decode)
          raise UnsupportedImageError, "unsupported BitsPerComponent #{bpc}" unless [1, 2, 4, 8, 16].include?(bpc)

          ncomp = space.components
          stride = (width * ncomp * bpc + 7) / 8
          # Packed and unpacked (one byte per sample) buffers are both bounded.
          if stride * height > SAMPLE_LIMIT || width * ncomp * height > SAMPLE_LIMIT
            raise UnsupportedImageError, "PDF image too large"
          end

          raw = Filters.decode(data, filters, params, stride * height)
          raise ImageError, "image has no data" if raw.empty?

          if ncomp == 1
            pixels, rows = expand(raw, width, height, bpc, space.luma_lut(bpc, decode))
          else
            luts = space.component_luts(bpc, decode)
            uniform = luts.uniq.size == 1 || space.kind == :lab
            # Uniform: samples are mapped while unpacking; otherwise they
            # stay raw values and each component is mapped while converting.
            lut = uniform ? luts.first : Array.new(luts.first.size) { |s| s }
            samples, rows = expand(raw, width * ncomp, height, bpc, lut)
            pixels = convert(samples, width, rows, space, uniform ? nil : luts)
          end
          pixels << ("\xFF".b * (width * (height - rows))) if rows < height
          Image.new(width, height, pixels)
        end

        # One byte per sample, mapped through +lut+ (indexed by the sample
        # value, or its high byte for 16 bits), for the rows present in
        # +raw+ (a partial last row is zero-padded). Returns [samples, rows].
        def expand(raw, samples_per_row, height, bpc, lut)
          stride = (samples_per_row * bpc + 7) / 8
          rows = [(raw.bytesize + stride - 1) / stride, height].min
          need = rows * stride
          raw = raw.byteslice(0, need) if raw.bytesize > need
          raw += "\0".b * (need - raw.bytesize) if raw.bytesize < need
          out = case bpc
                when 8 then translate(raw, lut)
                when 16
                  buf = String.new(capacity: samples_per_row * rows, encoding: Encoding::BINARY)
                  rows.times { |r| Pixels.high_bytes(raw, r * stride, samples_per_row, buf) }
                  translate(buf, lut)
                when 2
                  buf = String.new(capacity: (stride * 4) * rows, encoding: Encoding::BINARY)
                  rows.times { |r| Pixels.two_bit(raw, r * stride, stride, buf, lut) }
                  strip_padding(buf, stride * 4, samples_per_row, rows)
                else unpack(raw, samples_per_row, stride, rows, bpc, lut)
                end
          [out, rows]
        end

        # 1- and 4-bit samples via unpack ("B"/"H") and String#tr.
        def unpack(raw, samples_per_row, stride, rows, bpc, lut)
          format = bpc == 1 ? "B" : "H"
          chars = bpc == 1 ? "01" : "0123456789abcdef"
          if (samples_per_row * bpc) % 8 == 0
            out = raw.unpack1("#{format}*")
          else
            out = String.new(capacity: samples_per_row * rows)
            directive = "#{format}#{samples_per_row}"
            rows.times { |r| out << raw.unpack1(directive, offset: r * stride) }
          end
          out.force_encoding(Encoding::BINARY)
          out.tr!(chars, Image::TR_ESCAPE.call(lut))
          out
        end

        def strip_padding(buf, have, want, rows)
          return buf if have == want

          out = String.new(capacity: want * rows, encoding: Encoding::BINARY)
          rows.times { |r| out << buf.byteslice(r * have, want) }
          out
        end

        def translate(bytes, lut)
          return bytes if lut == IDENTITY

          bytes.tr(ALL_BYTES, Image::TR_ESCAPE.call(lut))
        end

        def convert(samples, width, rows, space, luts)
          out = String.new(capacity: width * rows, encoding: Encoding::BINARY)
          ncomp = space.components
          row = width * ncomp
          kind = space.kind
          rows.times do |r|
            off = r * row
            if luts then Pixels.mapped(samples, off, width, out, kind, luts)
            elsif kind == :rgb then Pixels.rgb(samples, off, width, out)
            elsif kind == :cmyk then Pixels.cmyk(samples, off, width, out)
            elsif kind == :lab then Pixels.first(samples, off, width, out, ncomp)
            else Pixels.device_n(samples, off, width, out, ncomp)
            end
          end
          out
        end

        def dct_image(jpeg, width, height, space, decode)
          start = jpeg.index("\xFF\xD8".b) or raise ImageError, "DCTDecode data is not a JPEG"
          jpeg = jpeg.byteslice(start, jpeg.bytesize - start) if start.positive?
          # A frame much larger than the image dictionary says is corrupt
          # (and would be expensive to decode).
          jw, jh = JPEG.dimensions(jpeg)
          if jw * jh > 4 * width * height + 4096
            raise ImageError, "JPEG size #{jw}x#{jh} does not match the image (#{width}x#{height})"
          end

          # Plain images (luminance = JPEG.decode) go undecoded with raw_jpeg.
          components = jpeg_components(jpeg) || space&.components || 1
          case components
          when 1
            lut = one_component(space).luma_lut(8, decode)
            return RawJpeg.new(jpeg, jw, jh) if @raw_jpeg && lut == IDENTITY

            image = JPEG.decode(jpeg)
            lut == IDENTITY ? image : Image.new(image.width, image.height, translate(image.data, lut))
          when 4
            # JPEG.decode reads CMYK the Adobe way (stored inverted), which
            # PDFs declare with /Decode [1 0 1 0 1 0 1 0].
            cmyk = space&.components == 4 ? space : ColorSpace::CMYK
            raise UnsupportedImageError, "CMYK JPEG image without an inverting /Decode array" unless cmyk.inverted?(decode)

            @raw_jpeg ? RawJpeg.new(jpeg, jw, jh) : JPEG.decode(jpeg)
          else
            rgb = space&.components == 3 ? space : ColorSpace::RGB
            invert = rgb.kind != :lab && rgb.inverted?(decode)
            return RawJpeg.new(jpeg, jw, jh) if @raw_jpeg && !invert && components == 3

            image = JPEG.decode(jpeg)
            invert ? image.invert : image
          end
        end

        # Number of components in the JPEG frame header.
        def jpeg_components(jpeg)
          pos = 2
          while pos + 10 <= jpeg.bytesize
            return nil unless jpeg.getbyte(pos) == 0xFF

            marker = jpeg.getbyte(pos + 1)
            if marker == 0xFF || marker == 0x01 || marker.between?(0xD0, 0xD7)
              pos += marker == 0xFF ? 1 : 2
              next
            end
            return jpeg.getbyte(pos + 9) if SOF_MARKERS.include?(marker)

            pos += 2 + ((jpeg.getbyte(pos + 2) << 8) | jpeg.getbyte(pos + 3))
          end
          nil
        end

        def ccitt_image(data, params, width, height, space, decode)
          params ||= {}
          rows = positive(params[:Rows])
          image = CCITT.decode(
            data,
            columns: positive(params[:Columns]) || width,
            rows: rows ? [rows, height].min : height,
            k: int(params[:K]) || 0,
            black_is_1: params[:BlackIs1] == true,
            encoded_byte_align: params[:EncodedByteAlign] == true,
            end_of_line: params[:EndOfLine] == true
          )
          bilevel(image, space.luma_lut(1, decode), width, height)
        end

        def jbig2_image(data, params, width, height, space, decode)
          globals = params && params[:JBIG2Globals]
          globals = @doc.decode_stream(globals) if globals.is_a?(Stream)
          image = JBIG2.decode(data, globals: globals.is_a?(String) ? globals : nil,
                                     max_pixels: 4 * width * height + 65_536)
          bilevel(image, space.luma_lut(1, decode), width, height)
        end

        # A 0/255 bilevel image (0 = sample value 0) mapped through +lut+
        # and fitted to the declared size (missing parts white).
        def bilevel(image, lut, width, height)
          pixels = image.data
          if lut != [0, 255]
            pixels = pixels.tr("\x00\xFF".b, Image::TR_ESCAPE.call(lut))
          end
          return Image.new(width, height, pixels) if image.width == width && image.height == height

          out = String.new(capacity: width * height, encoding: Encoding::BINARY)
          w = [image.width, width].min
          pad = "\xFF".b * (width - w)
          [image.height, height].min.times do |y|
            out << pixels.byteslice(y * image.width, w) << pad
          end
          out << ("\xFF".b * (width * height - out.bytesize))
          Image.new(width, height, out)
        end
      end

      # JBIG2 decoder for PDF's embedded streams (ITU-T T.88): page
      # information, immediate generic regions (MQ arithmetic coding with
      # templates 0-3, adaptive pixels and typical prediction, or MMR) and
      # end-of-stripe segments, composed onto the page with any combination
      # operator. Text, halftone and refinement regions (symbol coding) raise
      # UnsupportedImageError: an image is decoded completely or not at all.
      module JBIG2
        # MQ coder probability states: [Qe, next MPS, next LPS, switch].
        QE = [
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
        # Per state: Qe, and the packed context (state << 1 | mps) after an
        # MPS or LPS decision, for mps 0 and 1.
        QE_VALUE = QE.map(&:first).freeze
        NEXT_MPS = QE.each_with_index.flat_map { |(_, nmps, _, _), _i| [nmps << 1, (nmps << 1) | 1] }.freeze
        NEXT_LPS = QE.flat_map do |_, _, nlps, switch|
          [(nlps << 1) | switch, (nlps << 1) | (1 - switch)]
        end.freeze

        # Generic region templates (T.88 6.2.5.3) as sliding windows over
        # the rows y-2, y-1 and y: [row y-2 rightmost dx, its width, row
        # y-1 rightmost dx, its width, row y width], with the nominal
        # adaptive pixel positions inside the windows; the context bit of
        # each adaptive pixel; its nominal position; the typical prediction
        # context.
        TEMPLATES = [
          { windows: [2, 5, 3, 7, 4], at_bits: [4, 10, 11, 15], at: [[3, -1], [-3, -1], [2, -2], [-2, -2]],
            sltp: 0x9B25 },
          { windows: [2, 4, 3, 6, 3], at_bits: [3], at: [[3, -1]], sltp: 0x0795 },
          { windows: [1, 3, 2, 5, 2], at_bits: [2], at: [[2, -1]], sltp: 0x00E5 },
          { windows: [0, 0, 2, 6, 4], at_bits: [4], at: [[2, -1]], sltp: 0x0195 }
        ].freeze
        PAD = 4 # zero pixels left and right of each bitmap row
        BITS = "\x00\x01".b.freeze # bitmap: 1 = black
        LUMA = "\xFF\x00".b.freeze

        UNSUPPORTED = {
          4 => "text region", 6 => "text region", 7 => "text region", 20 => "halftone region",
          22 => "halftone region", 23 => "halftone region", 40 => "refinement region",
          42 => "refinement region", 43 => "refinement region"
        }.freeze

        # Decodes an embedded JBIG2 stream (+globals+: the JBIG2Globals
        # data) to an Image (black 0, white 255). Pages and regions larger
        # than +max_pixels+ are rejected.
        def self.decode(data, globals: nil, max_pixels: MAX_PIXELS)
          Page.new(max_pixels).decode(globals, data)
        end

        # Segment parsing and page composition.
        class Page
          include Util

          def initialize(max_pixels)
            @max_pixels = max_pixels
          end

          def decode(globals, data)
            each_segment(globals) { |type, _body| raise_unsupported(type) } if globals
            each_segment(data) do |type, body|
              case type
              when 48 then page_information(body)
              when 38, 39 then generic_region(body)
              when 50 then end_of_stripe(body)
              when 49, 51 then break
              else raise_unsupported(type)
              end
            end
            raise ImageError, "JBIG2 data without a page" unless @page

            height = @height || @rows
            raise ImageError, "empty JBIG2 page" unless height.positive?

            bitmap = @page.byteslice(0, @width * height)
            Image.new(@width, height, bitmap.tr(BITS, LUMA))
          end

          private

          def raise_unsupported(type)
            what = UNSUPPORTED[type] or return
            raise UnsupportedImageError, "JBIG2 images with symbol coding (#{what}) are not supported"
          end

          # Yields [type, data] of each segment (T.88 7.2).
          def each_segment(data)
            pos = 0
            size = data.bytesize
            while pos + 11 <= size
              number = be_int(data, pos, 4)
              flags = data.getbyte(pos + 4)
              type = flags & 0x3F
              pos += 5
              count = data.getbyte(pos) >> 5
              if count == 7
                return if pos + 4 > size

                count = be_int(data, pos, 4) & 0x1FFFFFFF
                pos += 4 + (count + 8) / 8
              else
                pos += 1
              end
              pos += count * (number <= 256 ? 1 : number <= 65_536 ? 2 : 4)
              pos += flags & 0x40 == 0 ? 1 : 4
              return if pos + 4 > size

              length = be_int(data, pos, 4)
              pos += 4
              length = unknown_length(data, pos) if length == 0xFFFFFFFF
              length = size - pos if pos + length > size
              yield type, data.byteslice(pos, length)
              pos += length
            end
          end

          # Data length of an immediate generic region of unknown size:
          # up to its end marker and row count (T.88 7.2.7).
          def unknown_length(data, pos)
            return data.bytesize - pos if pos + 18 > data.bytesize

            mmr = data.getbyte(pos + 17) & 1 == 1
            marker = mmr ? "\x00\x00".b : "\xFF\xAC".b
            stop = data.index(marker, pos + 18) or return data.bytesize - pos
            stop + 6 - pos
          end

          def page_information(body)
            raise ImageError, "short JBIG2 page information" if body.bytesize < 19

            width = be_int(body, 0, 4)
            height = be_int(body, 4, 4)
            flags = body.getbyte(16)
            @default = flags[2]
            @operator = (flags >> 3) & 3
            @override = flags[6] == 1
            @height = height == 0xFFFFFFFF ? nil : height
            @width = width
            rows = @height || 0 # striped pages of unknown height grow
            raise ImageError, "invalid JBIG2 page size #{width}x#{height}" unless width.positive?
            raise UnsupportedImageError, "JBIG2 page too large" if width * [rows, 1].max > @max_pixels

            @rows = rows
            @page = @default.chr.b * (width * rows)
          end

          def end_of_stripe(body)
            return unless @page && @height.nil? && body.bytesize >= 4

            grow(be_int(body, 0, 4) + 1)
          end

          # Pages of unknown height grow with their stripes.
          def grow(rows)
            return if rows <= @rows
            raise UnsupportedImageError, "JBIG2 page too large" if @width * rows > @max_pixels

            @page << (@default.chr.b * (@width * (rows - @rows)))
            @rows = rows
          end

          def generic_region(body)
            raise ImageError, "JBIG2 region before page information" unless @page
            raise ImageError, "short JBIG2 generic region" if body.bytesize < 18

            width, height, x, y = body.unpack("N4")
            x -= 1 << 32 if x >= 1 << 31
            y -= 1 << 32 if y >= 1 << 31
            operator = @override ? body.getbyte(16) & 7 : @operator
            flags = body.getbyte(17)
            raise UnsupportedImageError, "JBIG2 extended templates are not supported" if flags & 0x10 != 0

            height = be_int(body, body.bytesize - 4, 4) if height == 0xFFFFFFFF && body.bytesize >= 22
            unless width.positive? && height.positive? && width * height <= @max_pixels
              raise ImageError, "invalid JBIG2 region size #{width}x#{height}"
            end

            bitmap = if flags & 1 == 1
                       mmr(body.byteslice(18, body.bytesize - 18), width, height)
                     else
                       template = (flags >> 1) & 3
                       at_count = template.zero? ? 4 : 1
                       at = body.byteslice(18, 2 * at_count).unpack("c*").each_slice(2).to_a
                       raise ImageError, "short JBIG2 generic region" if at.size < at_count

                       data = body.byteslice(18 + 2 * at_count, body.bytesize)
                       GenericRegion.new(data, width, height, template, at, flags[3] == 1).decode
                     end
            grow(y + height) if @height.nil?
            compose(bitmap, width, height, x, y, operator)
          end

          # MMR-coded generic region: T.6 with 1 = black.
          def mmr(data, width, height)
            image = CCITT.decode(data, columns: width, rows: height, k: -1)
            bits = image.data.tr(LUMA, BITS)
            bits << ("\0".b * (width * (height - image.height))) if image.height < height
            bits
          end

          def compose(bitmap, width, height, x, y, operator)
            page = @page
            pw = @width
            x0 = [x, 0].max
            x1 = [x + width, pw].min
            n = x1 - x0
            return if n <= 0

            height.times do |ry|
              py = y + ry
              next if py.negative?
              break if py >= @rows

              src = ry * width + (x0 - x)
              dst = py * pw + x0
              piece = bitmap.byteslice(src, n)
              if operator == 4 || (operator.zero? && !page.byteslice(dst, n).include?("\x01"))
                page.bytesplice(dst, n, piece)
              elsif operator != 0 || piece.include?("\x01")
                combine(page, dst, piece, n, operator)
              end
            end
          end

          def combine(page, dst, piece, n, operator)
            i = 0
            while i < n
              a = page.getbyte(dst + i)
              b = piece.getbyte(i)
              v = case operator
                  when 0 then a | b
                  when 1 then a & b
                  when 2 then a ^ b
                  else 1 ^ a ^ b
                  end
              page.setbyte(dst + i, v)
              i += 1
            end
          end
        end

        # Arithmetic-coded generic region decoding (T.88 6.2.5.7) with the
        # MQ decoder of Annex E. The bitmap has PAD zero pixels left and
        # right of each row and two zero rows on top, so that the context
        # windows never need bounds checks. Past the end of its data the
        # decoder reads 1 bits; a valid stream needs only a few of them, so
        # decoding stops (the rest stays white) after FEED_LIMIT.
        class GenericRegion
          FEED_LIMIT = 64

          def initialize(data, width, height, template, at, typical)
            @data = data
            @size = data.bytesize
            @width = width
            @height = height
            @template = TEMPLATES[template]
            @at = at
            @typical = typical
            @contexts = Array.new(1 << 16, 0)
            nominal = @template[:at]
            @patches = at.each_with_index.filter_map do |(dx, dy), i|
              next if [dx, dy] == nominal[i]
              raise ImageError, "invalid JBIG2 adaptive pixel" if dy.positive? || (dy.zero? && dx >= 0)

              [dx, dy, @template[:at_bits][i]]
            end
            @stride = width + 2 * PAD
            init_decoder
          end

          def decode
            stride = @stride
            buf = "\0".b * (stride * (@height + 2))
            ltp = 0
            sltp = @template[:sltp]
            @height.times do |y|
              break if @fed > FEED_LIMIT

              row = (y + 2) * stride + PAD
              if @typical
                ltp ^= decode_bit(sltp)
                if ltp == 1
                  buf.bytesplice(row - PAD, stride, buf.byteslice(row - PAD - stride, stride))
                  next
                end
              end
              decode_row(buf, row, y)
            end
            out = String.new(capacity: @width * @height, encoding: Encoding::BINARY)
            @height.times { |y| out << buf.byteslice((y + 2) * stride + PAD, @width) }
            out
          end

          private

          def init_decoder
            @fed = 0
            @bp = 0
            @c = (@data.getbyte(0) || 0xFF) << 16
            byte_in
            @c = (@c << 7) & 0xFFFFFFFF
            @ct -= 7
            @a = 0x8000
          end

          def byte_in
            data = @data
            bp = @bp
            if data.getbyte(bp) == 0xFF
              b1 = data.getbyte(bp + 1)
              if b1.nil? || b1 > 0x8F
                @c += 0xFF00
                @ct = 8
                @fed += 1
              else
                @bp = bp + 1
                @c += b1 << 9
                @ct = 7
              end
            else
              @bp = bp += 1
              if bp < @size
                @c += data.getbyte(bp) << 8
              else
                @c += 0xFF00
                @fed += 1
              end
              @ct = 8
            end
          end

          # One decision with context +cx+ (used for typical prediction).
          def decode_bit(cx)
            contexts = @contexts
            state = contexts[cx]
            qe = QE_VALUE[state >> 1]
            mps = state & 1
            a = @a - qe
            if (@c >> 16) < qe
              if a < qe
                bit = mps
                contexts[cx] = NEXT_MPS[state]
              else
                bit = 1 - mps
                contexts[cx] = NEXT_LPS[state]
              end
              a = qe
            else
              @c -= qe << 16
              if a & 0x8000 != 0
                @a = a
                return mps
              end
              if a < qe
                bit = 1 - mps
                contexts[cx] = NEXT_LPS[state]
              else
                bit = mps
                contexts[cx] = NEXT_MPS[state]
              end
            end
            loop do
              byte_in if @ct.zero?
              a <<= 1
              @c = (@c << 1) & 0xFFFFFFFF
              @ct -= 1
              break if a & 0x8000 != 0
            end
            @a = a
            bit
          end

          # Decodes one row at +row+ (the offset of pixel 0) of +buf+. The
          # context is built from sliding windows over the rows y-2, y-1
          # and y; adaptive pixels off their nominal positions are patched
          # in. The MQ decoder is inlined (this loop runs per pixel).
          def decode_row(buf, row, y)
            hi2, n2, hi1, n1, n0 = @template[:windows]
            m0 = (1 << n0) - 1
            s1 = n0
            s2 = n0 + n1
            r2 = row - 2 * @stride + hi2 + 1 # next pixel to enter each window
            r1 = row - @stride + hi1 + 1
            # Rows y-2 and y-1 share one window: shifting moves row y-1's
            # oldest pixel onto row y-2's newest bit, which the mask clears.
            mask = ((((1 << n2) - 1) << s2) | (((1 << n1) - 1) << s1)) & ~(1 << s1) & ~(1 << s2)
            above = 0
            (hi2 - n2 + 1).upto(hi2) { |dx| above |= buf.getbyte(r2 - hi2 - 1 + dx) << (s2 + hi2 - dx) }
            (hi1 - n1 + 1).upto(hi1) { |dx| above |= buf.getbyte(r1 - hi1 - 1 + dx) << (s1 + hi1 - dx) }
            row2 = n2.positive?
            w0 = 0
            patches = @patches.empty? ? nil : @patches
            contexts = @contexts
            qe_value = QE_VALUE
            next_mps = NEXT_MPS
            next_lps = NEXT_LPS
            data = @data
            size = @size
            a = @a
            c = @c
            ct = @ct
            bp = @bp
            fed = @fed
            width = @width
            x = 0
            while x < width
              cx = above | w0
              cx = patch(cx, patches, buf, x, y) if patches
              state = contexts[cx]
              qe = qe_value[state >> 1]
              bit = state & 1
              a -= qe
              if (c >> 16) < qe
                if a < qe
                  contexts[cx] = next_mps[state]
                else
                  bit = 1 - bit
                  contexts[cx] = next_lps[state]
                end
                a = qe
              else
                c -= qe << 16
                if a & 0x8000 == 0
                  if a < qe
                    bit = 1 - bit
                    contexts[cx] = next_lps[state]
                  else
                    contexts[cx] = next_mps[state]
                  end
                end
              end
              while a & 0x8000 == 0
                if ct.zero?
                  if data.getbyte(bp) == 0xFF
                    b1 = data.getbyte(bp + 1)
                    if b1.nil? || b1 > 0x8F
                      c += 0xFF00
                      ct = 8
                      fed += 1
                    else
                      bp += 1
                      c += b1 << 9
                      ct = 7
                    end
                  else
                    bp += 1
                    if bp < size
                      c += data.getbyte(bp) << 8
                    else
                      c += 0xFF00
                      fed += 1
                    end
                    ct = 8
                  end
                end
                a <<= 1
                c = (c << 1) & 0xFFFFFFFF
                ct -= 1
              end
              buf.setbyte(row + x, 1) if bit == 1
              w0 = ((w0 << 1) | bit) & m0
              above = ((above << 1) & mask) | (buf.getbyte(r1 + x) << s1)
              above |= buf.getbyte(r2 + x) << s2 if row2
              x += 1
            end
            @a = a
            @c = c
            @ct = ct
            @bp = bp
            @fed = fed
          end

          # Replaces the nominal adaptive pixels in +cx+ by the real ones.
          def patch(cx, patches, buf, x, y)
            patches.each do |dx, dy, bit|
              px = x + dx
              py = y + dy
              v = px >= 0 && px < @width && py >= 0 ? buf.getbyte((py + 2) * @stride + PAD + px) : 0
              cx = (cx & ~(1 << bit)) | (v << bit)
            end
            cx
          end
        end
      end

      private_constant :ParseError, :Ref, :Keyword, :Stream, :Page, :ImageSource, :Band, :STREAM_LIMIT, :SAMPLE_LIMIT,
                       :INTERNAL_ERRORS, :Util, :Parser, :Document, :Security, :Filters, :ColorSpace, :Pixels,
                       :ContentScanner, :ImageDecoder, :JBIG2
    end
  end
end
