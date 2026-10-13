# frozen_string_literal: true

require "zlib"

# Minimal PDF writer for tests: builds documents object by object, so tests
# can produce exactly the structures they need (inline images, unusual
# colour spaces and filters, incremental updates, broken cross-reference
# data, ...). Independent of the library's parser on purpose.
#
#   w = PdfWriter.new
#   img = w.image(width: 2, height: 2, data: "\x00\xFF\xFF\x00".b)
#   bytes = w.document([["q 2 0 0 2 0 0 cm /Im0 Do Q", { XObject: { Im0: img } }]])
class PdfWriter
  # Indirect reference.
  Ref = Struct.new(:num, :gen) do
    def to_pdf = "#{num} #{gen || 0} R"
  end
  # A string written in hex form.
  Hex = Struct.new(:bytes)
  # PDF syntax inserted verbatim.
  Raw = Struct.new(:text)

  attr_reader :version

  def initialize(version: "1.4")
    @version = version
    @objects = {}
    @next = 1
  end

  # Allocates an object number (to be filled with #set).
  def reserve
    ref = Ref.new(@next, 0)
    @next += 1
    ref
  end

  # Object body: +value+, plus stream data if given (/Length is added
  # unless +value+ has one).
  def set(ref, value, stream: nil)
    body = if stream
             dict = value.key?(:Length) ? value : value.merge(Length: stream.bytesize)
             "#{PdfWriter.serialize(dict)}\nstream\n".b + stream.b + "\nendstream".b
           else
             PdfWriter.serialize(value).b
           end
    @objects[ref.num] = body
    ref
  end

  def add(value, stream: nil)
    set(reserve, value, stream: stream)
  end

  # Raw object body text (for deliberately broken objects).
  def add_raw(body)
    ref = reserve
    @objects[ref.num] = body.b
    ref
  end

  # An image XObject; +filter+ :flate compresses +data+ (other filters:
  # pass already encoded data and a /Filter in +extra+).
  def image(width:, height:, data:, color_space: :DeviceGray, bpc: 8, filter: nil, extra: {})
    dict = { Type: :XObject, Subtype: :Image, Width: width, Height: height, BitsPerComponent: bpc }
    dict[:ColorSpace] = color_space if color_space
    if filter == :flate
      data = Zlib::Deflate.deflate(data)
      dict[:Filter] = :FlateDecode
    end
    add(dict.merge(extra), stream: data)
  end

  # A complete document: +pages+ is an Array of [content, resources]
  # (content: a String, or an Array of Strings for several streams).
  # Options: see #render.
  def document(pages, media_box: [0, 0, 612, 792], **options)
    tree = reserve
    kids = pages.map do |content, resources|
      contents = Array(content).map { |c| add({}, stream: c) }
      page = { Type: :Page, Parent: tree, MediaBox: media_box, Contents: contents.size == 1 ? contents[0] : contents }
      page[:Resources] = resources if resources
      add(page)
    end
    set(tree, { Type: :Pages, Kids: kids, Count: kids.size })
    root = add({ Type: :Catalog, Pages: tree })
    render(root: root, **options)
  end

  # Serialises all objects. +xref+: :table, :stream (cross-reference
  # stream), :none (no cross-reference data and no startxref), :wrong
  # (table with bogus offsets). +header+ is written before "%PDF-".
  def render(root:, xref: :table, header: "", trailer: {})
    out = String.new(encoding: Encoding::BINARY)
    out << header.b << "%PDF-#{@version}\n%\xE2\xE3\xCF\xD3\n".b
    offsets = {}
    @objects.keys.sort.each do |num|
      offsets[num] = out.bytesize
      out << "#{num} 0 obj\n".b << @objects[num] << "\nendobj\n".b
    end
    size = @next
    trailer_dict = { Size: size, Root: root }.merge(trailer)
    case xref
    when :table, :wrong
      start = out.bytesize
      out << "xref\n0 #{size}\n0000000000 65535 f \n".b
      (1...size).each do |num|
        offset = offsets[num]
        offset = (offset * 7 + 13) % out.bytesize if offset && xref == :wrong
        out << (offset ? format("%010d 00000 n \n", offset) : "0000000000 65535 f \n").b
      end
      out << "trailer\n#{PdfWriter.serialize(trailer_dict)}\nstartxref\n#{start}\n%%EOF\n".b
    when :stream
      start = out.bytesize
      rows = String.new(encoding: Encoding::BINARY)
      rows << [0, 0, 65_535].pack("CNn")
      (1...size).each { |num| rows << (offsets[num] ? [1, offsets[num], 0].pack("CNn") : [0, 0, 0].pack("CNn")) }
      rows << [1, start, 0].pack("CNn")
      dict = trailer_dict.merge(Type: :XRef, Size: size + 1, W: [1, 4, 2], Filter: :FlateDecode)
      data = Zlib::Deflate.deflate(rows)
      out << "#{size} 0 obj\n#{PdfWriter.serialize(dict.merge(Length: data.bytesize))}\nstream\n".b
      out << data << "\nendstream\nendobj\nstartxref\n#{start}\n%%EOF\n".b
    when :none
      out << "%%EOF\n".b
    else
      raise ArgumentError, "unknown xref style #{xref.inspect}"
    end
    out
  end

  # Appends an incremental update to +base+ (a document from #render):
  # +objects+ maps Refs to [value, stream] replacing or adding objects.
  def self.update(base, objects, root:, size:)
    prev = base[/startxref\s+(\d+)/m, 1].to_i
    out = base.b.dup
    offsets = {}
    objects.each do |ref, (value, stream)|
      offsets[ref.num] = out.bytesize
      writer = new
      body = writer.set(Ref.new(1, 0), value, stream: stream) && writer.instance_variable_get(:@objects)[1]
      out << "#{ref.num} 0 obj\n".b << body << "\nendobj\n".b
    end
    start = out.bytesize
    out << "xref\n".b
    offsets.sort.each { |num, offset| out << format("%d 1\n%010d 00000 n \n", num, offset).b }
    trailer = { Size: size, Root: root, Prev: prev }
    out << "trailer\n#{serialize(trailer)}\nstartxref\n#{start}\n%%EOF\n".b
  end

  def self.serialize(value)
    case value
    when Hash then "<<#{value.map { |k, v| "/#{k} #{serialize(v)}" }.join(' ')}>>"
    when Array then "[#{value.map { |v| serialize(v) }.join(' ')}]"
    when Symbol then "/#{value}"
    when String then "(#{value.b.gsub(/[()\\\r]/n) { |c| c == "\r" ? "\\r" : "\\#{c}" }})"
    when Hex then "<#{value.bytes.unpack1('H*')}>"
    when Ref then value.to_pdf
    when Raw then value.text
    when nil then "null"
    else value.to_s
    end
  end

  # --- encoders for filter tests ---------------------------------------

  # LZWDecode encoding (9-12 bit codes, clear code at start and when the
  # table fills).
  def self.lzw(data, early_change: 1)
    codes = []
    table = nil
    next_code = nil
    reset = lambda do
      table = {}
      256.times { |i| table[i.chr.b] = i }
      next_code = 258
      codes << 256
    end
    reset.call
    w = "".b
    data.b.each_char do |c|
      wc = w + c
      if table.key?(wc)
        w = wc
      else
        codes << table[w]
        table[wc] = next_code
        next_code += 1
        w = c
        if next_code >= 4094
          codes << table[w]
          w = "".b
          reset.call
        end
      end
    end
    codes << table[w] unless w.empty?
    codes << 257
    pack_codes(codes, early_change)
  end

  # Packs codes MSB first with the decoder's code width rules.
  def self.pack_codes(codes, early_change)
    bits = +""
    entries = 258
    width = 9
    first_after_clear = true
    codes.each do |code|
      bits << code.to_s(2).rjust(width, "0")
      if code == 256
        entries = 258
        width = 9
        first_after_clear = true
        next
      end
      # The decoder adds an entry for every code except the first after a clear.
      entries += 1 unless first_after_clear
      first_after_clear = false
      width += 1 while width < 12 && entries + early_change >= (1 << width)
    end
    bits << "0" * (-bits.size % 8)
    [bits].pack("B*")
  end

  def self.run_length(data)
    out = String.new(encoding: Encoding::BINARY)
    bytes = data.b
    i = 0
    while i < bytes.bytesize
      run = 1
      run += 1 while i + run < bytes.bytesize && run < 128 && bytes.getbyte(i + run) == bytes.getbyte(i)
      if run >= 2
        out << (257 - run).chr << bytes.byteslice(i, 1)
        i += run
      else
        lit = 1
        lit += 1 while i + lit < bytes.bytesize && lit < 128 &&
                       bytes.getbyte(i + lit) != bytes.getbyte(i + lit - 1)
        out << (lit - 1).chr << bytes.byteslice(i, lit)
        i += lit
      end
    end
    out << 128.chr
  end

  def self.ascii85(data)
    out = +""
    bytes = data.b
    (0...bytes.bytesize).step(4) do |i|
      chunk = bytes.byteslice(i, 4)
      pad = 4 - chunk.bytesize
      v = (chunk + ("\0" * pad)).unpack1("N")
      if v.zero? && pad.zero?
        out << "z"
        next
      end
      digits = Array.new(5) { |k| ((v / (85**(4 - k))) % 85 + 33).chr }
      out << digits.join[0, 5 - pad]
    end
    out.scan(/.{1,60}/).join("\n") + "~>"
  end

  def self.ascii_hex(data)
    data.b.unpack1("H*").scan(/.{1,64}/).join("\n") + ">"
  end

  # PNG-predicts rows of +row+ bytes with filter +types+ (0-4; an Array
  # is cycled through row by row).
  def self.png_predict(data, row, bpp, types)
    types = Array(types)
    out = String.new(encoding: Encoding::BINARY)
    prev = "\0".b * row
    (0...data.bytesize).step(row).with_index do |off, r|
      cur = data.byteslice(off, row)
      type = types[r % types.size]
      out << type.chr
      cur.bytesize.times do |i|
        a = i >= bpp ? cur.getbyte(i - bpp) : 0
        b = prev.getbyte(i)
        c = i >= bpp ? prev.getbyte(i - bpp) : 0
        pred = case type
               when 0 then 0
               when 1 then a
               when 2 then b
               when 3 then (a + b) / 2
               else
                 p = a + b - c
                 pa = (p - a).abs
                 pb = (p - b).abs
                 pc = (p - c).abs
                 pa <= pb && pa <= pc ? a : (pb <= pc ? b : c)
               end
        out << ((cur.getbyte(i) - pred) & 255)
      end
      prev = cur
    end
    out
  end

  # TIFF predictor 2 for 8-bit samples.
  def self.tiff_predict(data, row, colors)
    out = data.b.dup
    (0...data.bytesize).step(row) do |off|
      (row - 1).downto(colors) do |i|
        out.setbyte(off + i, (data.getbyte(off + i) - data.getbyte(off + i - colors)) & 255)
      end
    end
    out
  end
end
