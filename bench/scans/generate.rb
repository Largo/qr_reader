# frozen_string_literal: true

# Generates the scanned-document QR corpus: test/corpus/scans/*.{png,jpg,tif,pdf}
# plus manifest.json (expected texts, tags, tier, resolution, module sizes).
#
#   bundle exec ruby bench/scans/generate.rb            # (proposed: rake scans:generate)
#   bundle exec ruby bench/scans/generate.rb --list     # show the cases
#   bundle exec ruby bench/scans/generate.rb --only 'qrbill-*' --jobs 4
#
# Needs ImageMagick 7 (`magick`; TIFF via libtiff) and, for the PDF variants
# with object streams / linearisation, `qpdf`. Deterministic: the same
# ImageMagick version produces the same pixels (ImageMagick runs
# single-threaded; parallelism comes from --jobs processes). The corpus is
# not checked in (test/corpus/scans/ is gitignored); about 260 cases,
# a few minutes with 8 jobs.
#
# Every case models something people actually scan (letters, invoices,
# Swiss QR-bills, parcel labels, receipts, business cards, tickets, sheets
# with several codes, codes near the page edge, faxes, big e-invoice codes,
# magazine pages, photocopies) with a scanner setup (office MFP, sheet
# feeder, flatbed, archive at 150 dpi, fax) and a difficulty tier:
#
#   common  - a decent office scanner on an ordinary document: must
#             essentially always work
#   hard    - one or two serious problems (low resolution, heavy JPEG, ink
#             spread, fold, stamp, pen, photocopy, fax, dither ...)
#   extreme - stacked or severe problems: partial failure expected
#
# Options:
#   --jobs N         parallel render processes (default: processors - 2)
#   --only PATTERN   render only cases whose id, tier or a tag matches the glob
#                    (repeatable); manifest.json always lists every case
#   --missing        render only cases whose file does not exist yet
#   --list           print the cases and exit
#   --manifest-only  write manifest.json without rendering
#   --out DIR        output directory (default test/corpus/scans)

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../test/support", __dir__)

require "digest"
require "etc"
require "fileutils"
require "json"
require "optparse"
require "time"
require "zlib"
require "scan_sim"
require_relative "payloads"
require_relative "documents"

module ScanCorpus
  ROOT = File.expand_path("../../test/corpus/scans", __dir__)
  SEED = 20_261_013
  # Bump when the generated corpus changes (recorded in the manifest).
  VERSION = 1

  # Cases per family and tier: [common, hard, extreme].
  PLAN = {
    letter: [12, 7, 3], invoice: [12, 8, 4], qrbill: [16, 12, 6], label: [9, 8, 4], receipt: [8, 8, 5],
    card: [9, 7, 4], ticket: [8, 6, 3], multi: [10, 8, 4], edge: [7, 6, 3], fax: [6, 10, 6],
    large: [5, 5, 3], magazine: [4, 6, 4], photocopy: [3, 6, 4]
  }.freeze
  TIERS = %i[common hard extreme].freeze

  # Scanner set-ups: resolutions, colour modes, file formats they write.
  SCANNERS = {
    mfp: { dpi: [200, 300, 300], modes: %i[color gray], formats: %w[pdf-dct pdf-dct jpeg-color jpeg-gray pdf-flate] },
    mfp_bw: { dpi: [200, 300, 300], modes: %i[threshold threshold adaptive diffusion ordered],
              formats: %w[pdf-g4 pdf-g4 tiff-g4 png-1bit] },
    sheetfed: { dpi: [200, 300], modes: %i[color gray], formats: %w[pdf-dct jpeg-color jpeg-gray tiff-jpeg] },
    flatbed: { dpi: [300, 300, 600], modes: %i[color gray],
               formats: %w[png-color png-gray tiff-lzw tiff-lzw-color jpeg-color] },
    archive: { dpi: [150], modes: %i[gray color], formats: %w[jpeg-gray jpeg-color pdf-dct] },
    fax: { dpi: [[204, 196], [204, 98]], modes: %i[threshold threshold diffusion], formats: %w[tiff-g3 tiff-g4 pdf-g4] }
  }.freeze
  BILEVEL_FORMATS = %w[pdf-g4 tiff-g4 tiff-g3 png-1bit].freeze
  GRAY_FORMATS = %w[jpeg-gray png-gray tiff-lzw pdf-dct pdf-flate tiff-jpeg].freeze
  COLOR_FORMATS = %w[jpeg-color png-color tiff-lzw-color pdf-dct pdf-flate tiff-jpeg].freeze
  TINTS = ["#efebe0", "#f6efcf", "#e9eff6", "#f5e6e9", "#e9f2e5", "#f1efe9"].freeze

  # A case to render: one file with one or more pages.
  Spec = Struct.new(:id, :family, :tier, :pages, :format, :quality, :tags, :notes, :post, :seed, keyword_init: true) do
    def file
      "#{id}.#{ScanSim.extension(format)}"
    end

    # Ground truth for all symbols on all pages.
    def codes
      pages.each_with_index.flat_map { |page, i| page.truth.map { |t| t.merge(page: i) } }
    end
  end

  # Random choices and the tags/notes describing them, for one case.
  class Builder
    attr_reader :rng, :tier, :family, :tags, :notes, :factors, :dpi, :mode, :format, :kind
    attr_accessor :quality, :post

    def initialize(family, tier, seed)
      @family = family
      @tier = tier
      @rng = Random.new(seed)
      @tags = ["doc:#{family}"]
      @notes = []
      @factors = []
      @post = nil
      @halftone_always = false
    end

    def chance(probability)
      @rng.rand < probability
    end

    def uniform(range)
      range.begin + @rng.rand * (range.end - range.begin)
    end

    def pick(list)
      list[@rng.rand(list.size)]
    end

    # +pairs+: {value => weight}.
    def weighted(pairs)
      r = @rng.rand * pairs.values.sum
      pairs.each do |value, weight|
        return value if r < weight

        r -= weight
      end
      pairs.keys.last
    end

    def by_tier(common, hard, extreme)
      { common: common, hard: hard, extreme: extreme }.fetch(@tier)
    end

    def tag(*names)
      names.each { |n| @tags << n unless @tags.include?(n) }
    end

    def note(text)
      @notes << text
    end

    def factor?(name)
      @factors.include?(name)
    end

    # Picks the hard factors for this case from +allowed+ (none for common).
    def choose_factors(allowed, count: nil)
      count ||= by_tier(0, 1 + (chance(0.35) ? 1 : 0), 2 + (chance(0.4) ? 1 : 0))
      @factors = allowed.shuffle(random: @rng).first(count)
    end

    # --- symbols ---------------------------------------------------------

    def ec(default: nil)
      default || weighted({ m: 5, l: 2, q: 2, h: 1 })
    end

    # Encodes a payload of +kind+ (see ScanPayloads).
    def code(kind, level: nil, length: nil)
      level = ec(default: level)
      text = case kind
             when :url then ScanPayloads.url(@rng, length: length || 30 + @rng.rand(50))
             when :alnum then ScanPayloads.alnum_url(@rng)
             when :vcard then ScanPayloads.vcard(@rng)
             when :epc then ScanPayloads.epc(@rng)
             when :qrbill then ScanPayloads.qr_bill(@rng)
             when :utf8 then ScanPayloads.utf8_text(@rng)
             when :numeric then ScanPayloads.numeric(@rng, length || 12 + @rng.rand(60))
             when :jwt then ScanPayloads.jwt(@rng, length || 1200)
             when :rksv then ScanPayloads.rksv(@rng)
             when :ticket then ScanPayloads.ticket(@rng)
             when :parcel then ScanPayloads.parcel(@rng)
             else raise ArgumentError, "unknown payload #{kind}"
             end
      level = :m if kind == :qrbill || kind == :epc
      ScanSim::Code.encode(text, level: level, kind: kind.to_s)
    end

    # Smallest pixels per module this case's scanner/tier should see.
    def min_ppm
      bilevel = ScanSim::BILEVEL_MODES.include?(@mode)
      bilevel ? by_tier(3.6, 2.4, 1.6) : by_tier(3.0, 2.0, 1.4)
    end

    # A printed size in +range+ (mm) giving at least min_ppm at the scan
    # resolution (the smaller axis for fax).
    def fit_size(code, range)
      dpi = [@dpi].flatten.min
      needed = min_ppm * code.modules * 25.4 / dpi
      [uniform(range), needed].max.round(1)
    end

    # Thermal printers print each module as a whole number of dots.
    def thermal_size(code, range, printer_dpi = 203)
      size = fit_size(code, range)
      dots = [(size / code.modules * printer_dpi / 25.4).round, 2].max
      (code.modules * dots * 25.4 / printer_dpi).round(2)
    end

    # --- scanner -----------------------------------------------------------

    # Chooses scanner set-up +kind+; +dpi+, +mode+ and +format+ override.
    def scanner(kind, dpi: nil, mode: nil, format: nil)
      preset = SCANNERS.fetch(kind)
      @kind = kind
      @dpi = dpi || pick(preset[:dpi])
      @mode = mode || pick(preset[:modes])
      choices = preset[:formats].select { |f| fits?(f, @mode) }
      # Lossless colour at 600 dpi gives 30-60 MB files; keep a few, prefer JPEG.
      choices -= %w[png-color tiff-lzw-color] if [@dpi].flatten.max >= 600 && choices.size > 2
      @format = format || pick(choices)
      @format = pick(formats_for(@mode)) unless fits?(@format, @mode)
      @quality = jpeg? ? uniform(by_tier(72..92, 55..85, 45..75)).round : 90
      tag("scanner:#{kind}")
      self
    end

    def fits?(format, mode)
      formats_for(mode).include?(format)
    end

    def formats_for(mode)
      case mode
      when :color then COLOR_FORMATS
      when :gray then GRAY_FORMATS
      else BILEVEL_FORMATS - (@kind == :fax ? [] : ["tiff-g3"])
      end
    end

    def jpeg?
      %w[jpeg-color jpeg-gray pdf-dct tiff-jpeg].include?(@format)
    end

    # Switches to a black-and-white mode (and a format that stores it).
    def black_and_white!(modes = %i[threshold adaptive ordered diffusion])
      @mode = pick(modes)
      @format = pick(BILEVEL_FORMATS - ["tiff-g3"]) unless fits?(@format, @mode)
    end

    # --- documents ---------------------------------------------------------

    # Paper, texture, module ink and dot gain for the document builders.
    def doc_opts(qr_inks: nil)
      opts = {}
      opts[:paper] = chance(by_tier(0.25, 0.4, 0.5)) ? pick(TINTS) : pick(ScanDocs::PAPERS)
      tag("deg:tint") if TINTS.include?(opts[:paper])
      opts[:texture] = uniform(by_tier(0.2..0.8, 0.4..1.4, 0.8..2.0)).round(2)
      tag("deg:texture") if opts[:texture] > 1.0
      opts[:gain] = if factor?(:dotgain) then uniform(by_tier(0.08..0.12, 0.14..0.25, 0.25..0.35))
                    elsif factor?(:thin) then -uniform(by_tier(0.08..0.12, 0.14..0.25, 0.25..0.35))
                    elsif chance(0.4) then uniform(-0.08..0.1)
                    else 0.0
                    end.round(3)
      tag("deg:dotgain") if opts[:gain] >= 0.12
      tag("deg:thin") if opts[:gain] <= -0.12
      if qr_inks
        opts[:qr_ink] = pick(qr_inks)
      elsif factor?(:halftone) || factor?(:lowcontrast)
        inks = factor?(:lowcontrast) ? %i[orange gray45] : %i[gray60 blue red green teal]
        opts[:qr_ink] = ScanDocs::INKS.fetch(pick(inks))
      elsif chance(0.15)
        opts[:qr_ink] = ScanDocs::INKS.fetch(pick(%i[blue green brown]))
      end
      tag("deg:color-qr") if opts[:qr_ink] && !%w[black #26262e].include?(opts[:qr_ink])
      tag("deg:low-contrast") if [ScanDocs::INKS[:orange], ScanDocs::INKS[:gray45]].include?(opts[:qr_ink])
      opts
    end

    # Print defects for +doc+ (mostly from the chosen factors).
    def printing(doc, thermal: false)
      halftone = nil
      if factor?(:halftone) || factor?(:moire) || @halftone_always
        halftone = pick(%w[h4x4a h6x6a h6x6a h8x8a])
        tag("deg:halftone")
      end
      fade = if factor?(:faded) then uniform(by_tier(0.2..0.3, 0.35..0.5, 0.55..0.68))
             elsif thermal then uniform(0.0..by_tier(0.15, 0.25, 0.3))
             else 0.0
             end
      tag("deg:faded") if fade >= 0.3
      starvation = factor?(:starvation) ? uniform(by_tier(0.2..0.3, 0.3..0.5, 0.5..0.7)) : 0.0
      tag("deg:starvation") if starvation.positive?
      speckles = factor?(:speckles) ? uniform(by_tier(20..40, 40..120, 150..300)) : (chance(0.2) ? uniform(2..10) : 0)
      tag("deg:speckles") if speckles > 30
      dead = []
      if factor?(:dead_lines) && (p = doc.placements.first)
        (by_tier(1, 1 + @rng.rand(2), 3 + @rng.rand(2))).times { dead << (p.x + p.size * uniform(0.12..0.88)).round(2) }
        tag("deg:dead-lines")
      end
      copies = factor?(:photocopy) ? by_tier(1, 2, 3) : 0
      tag("deg:photocopy") if copies.positive?
      ScanSim::Printing.new(halftone: halftone, fade: fade.round(3), starvation: starvation.round(3),
                            speckles: speckles.round(1), dead_lines: dead, copies: copies)
    end

    # Colour print (business cards, tickets, magazines) is screened.
    def halftone!
      @halftone_always = true
    end

    # Pen strokes and stamps over a symbol (from the chosen factors).
    def marks(doc, placement)
      x, y = placement.x, placement.y
      s = placement.size
      if factor?(:pen)
        if tier == :extreme
          pts = Array.new(5 + @rng.rand(4)) { [x + uniform(-0.1..1.1) * s, y + uniform(0.1..0.9) * s] }
          ScanSim::Clutter.pen(doc.marks, @rng, pts, color: pick(["#1b2f9e", "#111111", "#1d4ed8"]),
                                                     width: uniform(0.4..0.7))
        else
          # A tick or an underline that runs into the code.
          y0 = y + s * uniform(0.25..0.85)
          pts = [[x - s * 0.4, y0 + s * 0.1], [x + s * uniform(0.2..0.6), y0 - s * 0.05],
                 [x + s * uniform(0.6..1.2), y0 + s * 0.08]]
          ScanSim::Clutter.pen(doc.marks, @rng, pts, color: pick(["#1b2f9e", "#111111"]), width: uniform(0.35..0.55))
        end
        tag("deg:pen")
      end
      if factor?(:stamp)
        reach = by_tier(0.9, uniform(0.55..0.8), uniform(0.15..0.45))
        angle = uniform(0..2 * Math::PI)
        cx = x + s / 2 + Math.cos(angle) * s * reach
        cy = y + s / 2 + Math.sin(angle) * s * reach
        ScanSim::Clutter.stamp(doc.marks, cx, cy, pick(%w[BEZAHLT ERHALTEN PAYÉ GEBUCHT KOPIE]),
                               lines: ["13. Okt. 2026"], color: pick(["#c0152f", "#1f3fa6", "#5b2a86", "#1e7a3c"]),
                               angle: uniform(-20..20), opacity: uniform(0.65..0.85))
        tag("deg:stamp")
      end
      doc
    end

    # --- scanning ----------------------------------------------------------

    # Builds the Page: scan geometry, lighting and sensor settings from the
    # tier and factors. +on_glass+: small document on an A4 flatbed.
    def page(doc, printing:, on_glass: false, rotation: true, codes: true)
      sc = { dpi: @dpi, mode: @mode }
      sc[:blur] = if factor?(:blur) then uniform(by_tier(0.7..0.9, 0.9..1.2, 1.2..1.5))
                  else uniform(by_tier(0.3..0.7, 0.45..0.9, 0.7..1.1))
                  end
      sc[:blur] *= 1.4 if [@dpi].flatten.max >= 600
      tag("deg:blur") if sc[:blur] >= 0.9 && [@dpi].flatten.max < 600
      sc[:noise] = if factor?(:noise) then uniform(by_tier(3.0..4.0, 4.0..7.0, 7.0..10.0))
                   else uniform(by_tier(0.5..2.5, 1.5..4.0, 2.5..5.0))
                   end
      tag("deg:noise") if sc[:noise] >= 4
      sc[:threshold] = uniform(by_tier(46..56, 42..60, 38..64)).round if ScanSim::BILEVEL_MODES.include?(@mode)
      skew = if factor?(:skew) then on_glass ? uniform(4.0..12.0) : uniform(2.0..3.0)
             elsif chance(by_tier(0.7, 0.8, 0.9)) then uniform(by_tier(0.1..1.5, 0.3..2.5, 0.5..3.0))
             else 0.0
             end
      sc[:skew] = (chance(0.5) ? -skew : skew).round(2)
      tag("deg:skew") if skew >= 2.0
      if rotation && chance(0.3)
        sc[:rotation] = @kind == :fax ? 180 : pick([90, 180, 270])
        tag("deg:rot#{sc[:rotation]}")
      end
      if on_glass
        tw, th = [90, 270].include?(sc[:rotation]) ? [doc.height, doc.width] : [doc.width, doc.height]
        # At 600 dpi people select a preview region instead of the whole glass.
        sc[:area] = [216.0, [@dpi].flatten.max >= 600 ? [th + 30, 150].max.clamp(0, 297).round : 297.0]
        sc[:position] = [uniform(2.0..[216 - tw - 2, 3].max),
                         uniform(2.0..[sc[:area][1] - th - 2, 3].max).clamp(2.0, 60.0)].map { |v| v.round(1) }
        sc[:background] = pick(["#f2f2f2", "#e6e6e6", "#fafafa", "#d9d9d9"])
        tag("deg:on-glass")
      else
        sc[:background] = @kind == :sheetfed || chance(0.2) ? pick(["#202020", "#f0f0f0", "#3a3a3a"]) : "#f4f4f4"
      end
      sc[:illumination] = []
      if chance(0.4)
        sc[:illumination] << [:gradient, uniform(0..360).round, uniform(by_tier(0.02..0.10, 0.08..0.2, 0.15..0.3)).round(3)]
      end
      sc[:warp] = []
      if factor?(:wave)
        sc[:warp] << [:wave, uniform(by_tier(0.3..0.5, 0.5..1.0, 1.2..2.0)).round(2), uniform(40..90).round,
                      uniform(0..6.28).round(2), pick(%i[x y])]
        tag("deg:wave")
      end
      sc[:streaks] = []
      page = ScanSim::Page.new(doc, printing: printing, scan: ScanSim::Scan.new(**sc))
      return page unless codes

      # Effects aimed at the (first) symbol need its final position.
      target = page.truth.first
      gw, gh = page.size
      if target
        cx, cy = target[:center]
        near = { left: cx, right: gw - cx, top: cy, bottom: gh - cy }.min_by { |_, d| d }.first
        if factor?(:shadow)
          sc[:illumination] << [:shadow, near, uniform(by_tier(10..20, 15..30, 25..40)).round,
                                uniform(by_tier(0.2..0.3, 0.3..0.5, 0.5..0.65)).round(3)]
          tag("deg:shadow")
        end
        if factor?(:curl)
          sc[:warp] << [:curl, near, uniform(by_tier(20..30, 25..40, 30..50)).round,
                        uniform(by_tier(0.8..1.2, 1.0..2.5, 2.5..4.0)).round(2)]
          sc[:illumination] << [:shadow, near, uniform(8..15).round, uniform(0.3..0.55).round(3)]
          tag("deg:curl")
        end
        if factor?(:streak)
          sc[:streaks] << [(cx + uniform(-0.3..0.3) * target[:modules] * target[:module_px][0]) / gw,
                           uniform(by_tier(0.15..0.3, 0.25..0.45, 0.5..0.8)).round(2), uniform(1..3).round]
          tag("deg:adf-streak")
        end
        p = doc.placements.first
        if factor?(:crease)
          horizontal = chance(0.7)
          at = [p.x + p.size * uniform(0.15..0.85), p.y + p.size * uniform(0.15..0.85)]
          mag = uniform(by_tier(0.1..0.2, 0.2..0.4, 0.4..0.8))
          shift = horizontal ? [uniform(-0.2..0.2) * mag, mag] : [mag, uniform(-0.2..0.2) * mag]
          sc[:crease] = { at: at.map { |v| v.round(2) }, angle: horizontal ? 0 : 90, shift: shift.map { |v| v.round(3) },
                          shade: uniform(by_tier(0.2..0.35, 0.3..0.5, 0.45..0.7)).round(2) }
          tag("deg:crease")
        end
      end
      tag("deg:moire") if printing.halftone && [@dpi].flatten.min <= 300 && @mode != :threshold
      ScanSim::Page.new(doc, printing: printing, scan: ScanSim::Scan.new(**sc))
    end
  end

  module_function

  def seed_for(id)
    (SEED ^ Zlib.crc32(id)) & 0x7fff_ffff
  end

  # All case specs (or those of some +families+), in a fixed order.
  def specs(families: PLAN.keys)
    PLAN.slice(*families).flat_map do |family, counts|
      TIERS.zip(counts).flat_map do |tier, count|
        Array.new(count) do |i|
          id = format("%s-%s-%02d", family, tier, i + 1)
          seed = seed_for(id)
          b = Builder.new(family, tier, seed)
          pages = Array(public_send("build_#{family}", b, i))
          outside = pages.flat_map { |p| p.document.placements.reject { |pl| inside?(p, pl) } }
          raise "#{id}: a code lies outside the scanned image" unless outside.empty?

          finalize(b, id, pages, seed)
        end
      end
    end
  end

  # True if the whole symbol of +placement+ is inside the scanned image.
  def inside?(page, placement, margin: 0.0)
    t = page.transform
    w, h = page.size
    x = placement.x
    y = placement.y
    s = placement.size
    [[x, y], [x + s, y], [x + s, y + s], [x, y + s]].all? do |px, py|
      fx, fy = t.apply(px, py)
      fx >= margin && fy >= margin && fx <= w - margin && fy <= h - margin
    end
  end

  def finalize(b, id, pages, seed)
    if b.format.start_with?("pdf") && b.chance(0.35)
      # Re-saved PDFs: object streams with a cross-reference stream, or linearised.
      b.post = b.chance(0.7) ? :objstm : :linearize
      b.tag("pdf:#{b.post}")
    end
    spec = Spec.new(id: id, family: b.family.to_s, tier: b.tier.to_s, pages: pages, format: b.format,
                    quality: b.quality, tags: b.tags, notes: b.notes, post: b.post, seed: seed)
    codes = spec.codes
    dpi = b.dpi
    b.tag("fmt:#{b.format}", "mode:#{b.mode}")
    b.tag(dpi.is_a?(Array) ? (dpi[1] < 150 ? "dpi:fax-standard" : "dpi:fax-fine") : "dpi:#{dpi}")
    b.tag("pages:multi") if pages.size > 1
    b.tag("fmt:jpeg-q<50") if b.jpeg? && b.quality < 50
    b.tag(codes.size > 2 ? "codes:3+" : "codes:#{codes.size}")
    codes.each do |c|
      b.tag("payload:#{c[:kind]}", "ec:#{c[:ec]}", "version:#{bucket(c[:version], [4, 9, 17, 25], 'v')}",
            "size:#{bucket(c[:size_mm], [15, 25, 40], 'mm')}")
    end
    ppm = codes.map { |c| c[:module_px].min }.min
    b.tag("ppm:#{ppm_bucket(ppm)}") if ppm
    spec
  end

  def bucket(value, limits, unit)
    lower = 0
    limits.each do |limit|
      return unit == "v" ? "#{lower + 1}-#{limit}" : "#{lower}-#{limit}#{unit}" if value <= limit

      lower = limit
    end
    unit == "v" ? "#{lower + 1}-40" : ">#{lower}#{unit}"
  end

  def ppm_bucket(ppm)
    if ppm < 2 then "<2"
    elsif ppm < 3 then "2-3"
    elsif ppm < 4 then "3-4"
    elsif ppm < 6 then "4-6"
    else "6+"
    end
  end

  # --- families -------------------------------------------------------------

  def build_letter(b, _i)
    b.choose_factors(%i[blur noise jpeg dotgain thin crease pen shadow streak skew bw halftone speckles])
    b.scanner(b.pick(b.by_tier(%i[mfp mfp mfp_bw sheetfed flatbed], %i[mfp mfp_bw sheetfed archive], %i[archive mfp_bw mfp])))
    apply_scanner_factors(b)
    code = b.code(b.weighted({ url: 6, vcard: 2.5, utf8: 1.5 }))
    size = b.fit_size(code, b.by_tier(15..30, 12..20, 10..15))
    doc = ScanDocs.letter(b.rng, code, size, place: b.pick(%i[footer header body]),
                                             format: b.chance(0.2) ? ScanDocs::LETTER : ScanDocs::A4, **b.doc_opts)
    b.marks(doc, doc.placements.first)
    b.note("letter, #{size} mm code")
    b.page(doc, printing: b.printing(doc))
  end

  def build_invoice(b, _i)
    b.choose_factors(%i[blur noise jpeg dotgain thin crease pen stamp shadow streak bw speckles starvation])
    b.scanner(b.pick(b.by_tier(%i[mfp mfp mfp_bw sheetfed flatbed], %i[mfp mfp_bw sheetfed archive],
                               %i[archive mfp_bw sheetfed])))
    apply_scanner_factors(b)
    main = b.code(b.weighted({ epc: 4, url: 3, numeric: 1, utf8: 2 }))
    codes = [[main, b.fit_size(main, b.by_tier(20..30, 15..24, 12..18))]]
    if b.chance(0.4)
      extra = b.code(:url, length: 25 + b.rng.rand(20))
      codes << [extra, b.fit_size(extra, b.by_tier(12..18, 10..14, 10..12))]
    end
    doc = ScanDocs.invoice(b.rng, codes, **b.doc_opts)
    b.marks(doc, doc.placements.first)
    b.page(doc, printing: b.printing(doc))
  end

  def build_qrbill(b, i)
    allowed = %i[crease stamp pen dotgain thin jpeg blur noise bw photocopy faded shadow speckles streak]
    b.choose_factors(allowed)
    kinds = b.by_tier(%i[mfp mfp mfp_bw sheetfed flatbed], %i[mfp mfp_bw sheetfed archive fax], %i[fax archive mfp_bw])
    kind = b.pick(kinds)
    kind = :fax if b.tier == :extreme && i < 2
    if kind == :fax
      b.scanner(:fax, dpi: b.tier == :extreme ? b.pick([[204, 98], [204, 196]]) : [204, 196])
    else
      b.scanner(kind)
    end
    apply_scanner_factors(b)
    code = b.code(:qrbill)
    raise "QR-bill payload needs version #{code.version} > 25" if code.version > 25

    slip = b.chance(0.3)
    doc = ScanDocs.qr_bill(b.rng, code, slip: slip, **b.doc_opts)
    b.tag("deg:slip-only") if slip
    b.marks(doc, doc.placements.first)
    b.page(doc, printing: b.printing(doc), rotation: kind != :fax)
  end

  def build_label(b, _i)
    b.choose_factors(%i[faded dead_lines dotgain skew blur jpeg noise crease wave streak])
    on_glass = b.chance(0.6)
    b.scanner(on_glass ? b.pick(%i[flatbed mfp]) : b.pick(%i[flatbed sheetfed]),
              dpi: b.tier == :extreme ? b.pick([150, 200]) : nil)
    apply_scanner_factors(b)
    main = b.code(:parcel)
    codes = [[main, b.thermal_size(main, b.by_tier(25..40, 20..30, 18..25))]]
    if b.chance(0.65)
      second = b.code(b.pick(%i[numeric alnum url]), length: 16 + b.rng.rand(20))
      codes << [second, b.thermal_size(second, 12..20)]
    end
    if b.chance(0.25)
      third = b.code(:numeric, length: 10 + b.rng.rand(10))
      codes << [third, b.thermal_size(third, 10..15)]
    end
    doc = ScanDocs.label(b.rng, codes, **b.doc_opts, paper: "#fbfbf8")
    b.marks(doc, doc.placements.first)
    b.page(doc, printing: b.printing(doc, thermal: true), on_glass: on_glass)
  end

  def build_receipt(b, _i)
    b.choose_factors(%i[faded dead_lines wave crease blur jpeg noise skew curl speckles])
    on_glass = b.chance(0.6)
    b.scanner(on_glass ? b.pick(%i[flatbed mfp]) : :sheetfed, dpi: b.by_tier(nil, nil, b.pick([150, 200])))
    apply_scanner_factors(b)
    b.factors << :faded if b.tier != :common && !b.factor?(:faded) && b.chance(0.5)
    code = b.code(b.weighted({ rksv: 5, url: 3, utf8: 2 }))
    size = b.thermal_size(code, b.by_tier(22..35, 18..26, 15..22))
    doc = ScanDocs.receipt(b.rng, code, size, width: b.chance(0.7) ? 80.0 : 58.0, **b.doc_opts, paper: "#fdfdfb")
    b.page(doc, printing: b.printing(doc, thermal: true), on_glass: on_glass)
  end

  def build_card(b, i)
    b.choose_factors(%i[blur jpeg noise skew halftone lowcontrast dotgain])
    on_glass = b.chance(0.7)
    b.scanner(on_glass ? :flatbed : :sheetfed, dpi: b.by_tier(b.pick([300, 600]), b.pick([200, 300]), b.pick([150, 200])))
    apply_scanner_factors(b)
    styles = b.by_tier(%i[plain tinted panel color plain], %i[plain tinted panel inverted color],
                       %i[panel inverted color tinted])
    style = styles[i % styles.size]
    b.tag("deg:inverted") if style == :inverted
    b.tag("deg:color-bg") if %i[panel inverted].include?(style)
    b.halftone! if %i[panel inverted color].include?(style)
    code = b.code(:vcard, level: b.weighted({ m: 4, l: 3, q: 2 }))
    size = b.fit_size(code, b.by_tier(18..25, 15..22, 14..18))
    size = [size, 40.0].min
    opts = b.doc_opts
    doc = ScanDocs.business_card(b.rng, code, size, style: style, **opts)
    b.page(doc, printing: b.printing(doc), on_glass: on_glass)
  end

  def build_ticket(b, _i)
    b.choose_factors(%i[jpeg blur noise crease pen skew halftone faded])
    kind = b.chance(0.7) ? :a4 : :stub
    on_glass = kind == :stub && b.chance(0.6)
    b.scanner(b.pick(kind == :a4 ? %i[mfp sheetfed flatbed archive] : %i[flatbed sheetfed]),
              dpi: b.by_tier(nil, nil, b.pick([150, 200])))
    apply_scanner_factors(b)
    b.halftone! if kind == :a4
    code = b.code(:ticket)
    size = if kind == :a4 then b.fit_size(code, b.by_tier(35..50, 28..40, 25..35))
           else b.thermal_size(code, b.by_tier(25..30, 20..28, 18..25))
           end
    doc = ScanDocs.ticket(b.rng, code, size, kind: kind, **b.doc_opts)
    b.marks(doc, doc.placements.first)
    b.page(doc, printing: b.printing(doc, thermal: kind == :stub), on_glass: on_glass)
  end

  # Pages with several codes; some cases are multi-page documents.
  def build_multi(b, i)
    b.choose_factors(%i[blur jpeg noise skew dotgain bw shadow])
    multipage = i < b.by_tier(2, 1, 1)
    b.scanner(b.pick(b.by_tier(%i[mfp mfp_bw sheetfed flatbed], %i[mfp mfp_bw sheetfed archive], %i[archive mfp_bw])))
    apply_scanner_factors(b)
    if multipage
      unless b.format.start_with?("pdf", "tiff")
        formats = ScanSim::BILEVEL_MODES.include?(b.mode) ? %w[pdf-g4 tiff-g4] : %w[pdf-dct pdf-flate tiff-jpeg]
        b.scanner(b.kind, dpi: b.dpi, mode: b.mode, format: b.pick(formats))
      end
      return multi_pages(b)
    end
    layout = b.pick(%i[labels handout catalog])
    count = layout == :handout ? 2 + b.rng.rand(3) : 2 + b.rng.rand(5)
    range = layout == :catalog ? b.by_tier(14..22, 12..18, 10..14) : b.by_tier(15..30, 12..22, 10..16)
    codes = Array.new(count) do
      c = b.code(b.pick(%i[url numeric alnum utf8 url]), length: 20 + b.rng.rand(40))
      [c, b.fit_size(c, range)]
    end
    doc = ScanDocs.multi(b.rng, codes, layout: layout, **b.doc_opts)
    b.tag("layout:#{layout}")
    b.page(doc, printing: b.printing(doc))
  end

  def multi_pages(b)
    opts = b.doc_opts
    if b.chance(0.5)
      # Batch scan with separator sheets: codes on the first and a later page.
      b.tag("layout:separators")
      pages = []
      n = 3 + b.rng.rand(2)
      second = 2 + b.rng.rand(n - 2)
      n.times do |p|
        if p.zero? || p == second
          c = b.code(:alnum)
          sheet = ScanDocs.separator(b.rng, c, b.fit_size(c, 25..40), **opts)
          pages << b.page(sheet, printing: b.printing(sheet))
        else
          pages << b.page(ScanDocs.text_page(b.rng, **opts), printing: ScanSim::Printing.new, codes: false)
        end
      end
      pages
    else
      # Invoice: letter page with a URL code, then the QR-bill page.
      b.tag("layout:invoice+qrbill")
      url = b.code(:url)
      bill = b.code(:qrbill)
      first = ScanDocs.letter(b.rng, url, b.fit_size(url, 15..22), place: :header, **opts)
      second = ScanDocs.qr_bill(b.rng, bill, **opts)
      [b.page(first, printing: b.printing(first)), b.page(second, printing: b.printing(second))]
    end
  end

  def build_edge(b, _i)
    b.choose_factors(%i[skew blur jpeg noise shadow])
    b.scanner(b.pick(%i[sheetfed mfp mfp_bw]))
    apply_scanner_factors(b)
    code = b.code(b.pick(%i[alnum url numeric]), length: 14 + b.rng.rand(20))
    size = b.fit_size(code, b.by_tier(15..25, 12..20, 10..16))
    margin = b.uniform(b.by_tier(4.0..8.0, 2.0..4.0, 0.8..2.0)).round(1)
    corner = b.pick(%i[top_left top_right bottom_left bottom_right])
    doc = ScanDocs.edge(b.rng, code, size, corner: corner, margin: margin, **b.doc_opts)
    b.tag("deg:edge")
    b.note("#{corner} corner, #{margin} mm margin")
    page = b.page(doc, printing: b.printing(doc))
    sc = page.scan
    # Sheet feeders often scan with a dark backing; a page shifted against
    # the scan area loses part of the margin.
    shift = b.by_tier(0.0, b.uniform(0.0..1.0), b.uniform(0.5..[margin - 0.3, 0.6].max))
    dx = corner.to_s.end_with?("left") ? -shift : shift
    dy = corner.to_s.start_with?("top") ? -shift : shift
    tw, th = page.turned_size
    rot = sc.rotation
    dx, dy = case rot
             when 90 then [-dy, dx]
             when 180 then [-dx, -dy]
             when 270 then [dy, -dx]
             else [dx, dy]
             end
    background = b.chance(0.5) ? "#1c1c1c" : sc.background
    b.tag("deg:dark-backing") if background == "#1c1c1c"
    # A skewed page swings its corners by several mm: keep the code inside
    # the scanned area (at least partly in its quiet zone) by reducing skew.
    skew = sc.skew
    loop do
      shifted = ScanSim::Page.new(doc, printing: page.printing,
                                       scan: sc.with(area: [tw, th], position: [dx.round(2), dy.round(2)],
                                                     background: background, skew: skew.round(2)))
      return shifted if inside?(shifted, doc.placements.first, margin: 1.0) || (skew.zero? && dx.zero? && dy.zero?)

      skew *= 0.5
      skew = 0.0 if skew.abs < 0.05
      if skew.zero?
        dx *= 0.5
        dy *= 0.5
      end
    end
  end

  def build_fax(b, i)
    b.choose_factors(%i[skew noise blur speckles dotgain thin bw])
    standard = b.tier == :extreme || (b.tier == :hard && i.odd?)
    b.scanner(:fax, dpi: standard ? [204, 98] : [204, 196], mode: b.factor?(:bw) ? :diffusion : nil)
    content = b.weighted({ form: 6, letter: 2, qrbill: 2 })
    code = content == :qrbill ? b.code(:qrbill) : b.code(b.pick(%i[url alnum numeric utf8]), length: 15 + b.rng.rand(30))
    size = b.fit_size(code, b.by_tier(25..40, 22..35, 20..30))
    opts = b.doc_opts
    doc = case content
          when :form then ScanDocs.fax_form(b.rng, code, size, **opts)
          when :letter then ScanDocs.letter(b.rng, code, size, place: :header, **opts)
          else ScanDocs.qr_bill(b.rng, code, **opts)
          end
    page = b.page(doc, printing: b.printing(doc), rotation: true)
    b.tag("layout:#{content}")
    return page unless b.chance(0.35)

    # Multi-page fax: cover sheet first, the code on page 2.
    cover = ScanDocs.text_page(b.rng, **opts)
    [b.page(cover, printing: ScanSim::Printing.new, codes: false), page]
  end

  def build_large(b, _i)
    b.choose_factors(%i[blur jpeg noise skew dotgain bw crease])
    b.scanner(b.pick(b.by_tier(%i[mfp flatbed sheetfed], %i[mfp sheetfed mfp_bw], %i[archive mfp mfp_bw])),
              dpi: b.by_tier(b.pick([300, 300, 600]), b.pick([200, 300]), b.pick([150, 200])))
    apply_scanner_factors(b)
    level = b.pick(%i[l l m])
    length = { l: 1300..2900, m: 1100..2300 }[level]
    code = b.code(:jwt, level: level, length: b.uniform(length).round)
    size = b.fit_size(code, b.by_tier(50..60, 45..60, 40..55))
    doc = ScanDocs.large(b.rng, code, [size, 75.0].min, **b.doc_opts)
    b.marks(doc, doc.placements.first)
    b.page(doc, printing: b.printing(doc))
  end

  def build_magazine(b, _i)
    b.choose_factors(%i[curl shadow jpeg blur lowcontrast moire noise], count: b.by_tier(0, 2, 3))
    b.scanner(:flatbed, dpi: b.by_tier(b.pick([300, 600]), b.pick([200, 300]), b.pick([150, 200])),
                        mode: b.pick(%i[color color gray]))
    b.halftone!
    code = b.code(b.pick(%i[url url alnum]), length: 25 + b.rng.rand(30))
    size = b.fit_size(code, b.by_tier(20..30, 16..24, 14..20))
    inks = ScanDocs::INKS
    qr_inks = b.factor?(:lowcontrast) ? [inks[:orange], "#3f7fd0"] : [inks[:blue], inks[:red], "black", inks[:green]]
    opts = b.doc_opts(qr_inks: qr_inks)
    b.tag("deg:color-qr") unless opts[:qr_ink] == "black"
    b.tag("deg:color-bg")
    doc = ScanDocs.magazine(b.rng, code, size, panel: b.chance(0.4) ? "white" : nil, **opts)
    b.factors << :curl if b.tier != :common && !b.factor?(:curl) && b.chance(0.5)
    b.page(doc, printing: b.printing(doc), on_glass: false)
  end

  def build_photocopy(b, _i)
    b.choose_factors(%i[blur noise speckles dotgain jpeg skew], count: b.by_tier(0, 1, 2))
    b.factors << :photocopy
    b.scanner(b.pick(%i[mfp mfp_bw sheetfed]))
    apply_scanner_factors(b)
    base = b.pick(%i[letter invoice qrbill])
    opts = b.doc_opts
    doc = case base
          when :letter
            c = b.code(:url)
            ScanDocs.letter(b.rng, c, b.fit_size(c, b.by_tier(20..30, 15..25, 15..20)), place: :footer, **opts)
          when :invoice
            c = b.code(:epc)
            ScanDocs.invoice(b.rng, [[c, b.fit_size(c, b.by_tier(22..30, 18..25, 15..22))]], **opts)
          else ScanDocs.qr_bill(b.rng, b.code(:qrbill), **opts)
          end
    b.tag("layout:#{base}")
    b.page(doc, printing: b.printing(doc))
  end

  # Scanner-related factors: B&W mode, heavy JPEG, low resolution.
  def apply_scanner_factors(b)
    b.black_and_white! if b.factor?(:bw) && !ScanSim::BILEVEL_MODES.include?(b.mode)
    if b.factor?(:jpeg)
      b.scanner(b.kind == :mfp_bw ? :mfp : b.kind, dpi: b.dpi, mode: %i[color gray].include?(b.mode) ? b.mode : :gray,
                                                   format: b.pick(%w[jpeg-color jpeg-gray pdf-dct]))
      b.quality = b.uniform(b.by_tier(55..65, 40..55, 30..40)).round
      b.tag("deg:jpeg")
    end
  end

  # --- rendering --------------------------------------------------------------

  def render(spec, dir)
    path = File.join(dir, spec.file)
    tmp = "#{path}.tmp#{Process.pid}.#{File.extname(path).delete('.')}"
    ScanSim.render(spec.pages, tmp, format: spec.format, quality: spec.quality, seed: spec.seed)
    postprocess(tmp, spec.post) if spec.post
    File.rename(tmp, path)
  ensure
    FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
  end

  def postprocess(path, kind)
    args = kind == :linearize ? ["--linearize"] : ["--object-streams=generate"]
    out = "#{path}.post.pdf" # (qpdf may only be allowed to write *.pdf)
    system("qpdf", *args, path, out, exception: true)
    File.rename(out, path)
  end

  # Renders +specs+ with up to +jobs+ parallel processes; returns failures.
  def render_all(specs, dir, jobs)
    FileUtils.mkdir_p(dir)
    queue = specs.dup
    running = {}
    failures = {}
    done = 0
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    until queue.empty? && running.empty?
      while running.size < jobs && (spec = queue.shift)
        err = File.join(dir, ".#{spec.id}.err")
        pid = fork do
          $stderr.reopen(err, "w")
          render(spec, dir)
          exit!(0)
        rescue Exception => e # rubocop:disable Lint/RescueException
          warn "#{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
          exit!(1)
        end
        running[pid] = [spec, err, Process.clock_gettime(Process::CLOCK_MONOTONIC)]
      end
      pid, status = Process.wait2
      spec, err, t0 = running.delete(pid)
      done += 1
      unless status.success?
        failures[spec.id] = File.exist?(err) ? File.read(err)[0, 2000] : "exit #{status.exitstatus}"
      end
      FileUtils.rm_f(err)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      warn format("[%3d/%d] %-26s %s %5.1fs  (%.0fs)", done, specs.size, spec.id, status.success? ? "ok  " : "FAIL",
                  Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0, elapsed)
    end
    failures
  end

  # --- manifest ---------------------------------------------------------------

  def manifest(specs, dir)
    {
      "generator" => {
        "version" => VERSION, "seed" => SEED, "imagemagick" => ScanSim.magick_version, "ruby" => RUBY_VERSION,
        "created" => Time.now.utc.iso8601, "cases" => specs.size
      },
      "cases" => specs.map { |s| manifest_entry(s, dir) }
    }
  end

  def manifest_entry(spec, dir)
    path = File.join(dir, spec.file)
    scan = spec.pages.first.scan
    codes = spec.codes
    {
      "id" => spec.id, "file" => spec.file, "family" => spec.family, "tier" => spec.tier, "tags" => spec.tags,
      "format" => spec.format, "quality" => spec.quality, "dpi" => scan.dpi, "mode" => scan.mode.to_s,
      "pages" => spec.pages.size, "image_size" => spec.pages.map(&:size),
      "expected" => codes.map { |c| c[:text] },
      "codes" => codes.map { |c| c.transform_keys(&:to_s).transform_values { |v| v.is_a?(Symbol) ? v.to_s : v } },
      "notes" => spec.notes.join("; "),
      "bytes" => File.exist?(path) ? File.size(path) : nil
    }.compact
  end

  def matches?(spec, patterns)
    patterns.any? do |pat|
      [spec.id, spec.tier, spec.family, *spec.tags].any? { |v| File.fnmatch?(pat, v) }
    end
  end

  def run(argv)
    options = { jobs: [Etc.nprocessors - 2, 1].max, only: [], out: ROOT }
    OptionParser.new do |o|
      o.banner = "Usage: bundle exec ruby bench/scans/generate.rb [options]"
      o.on("--jobs N", Integer) { |v| options[:jobs] = v }
      o.on("--only PATTERN") { |v| options[:only] << v }
      o.on("--missing") { options[:missing] = true }
      o.on("--list") { options[:list] = true }
      o.on("--manifest-only") { options[:manifest_only] = true }
      o.on("--out DIR") { |v| options[:out] = File.expand_path(v) }
    end.parse!(argv)

    all = specs
    if options[:list]
      all.each do |s|
        ppm = s.codes.map { |c| c[:module_px].min }.min
        puts format("%-24s %-8s %-15s %2d codes ppm %5.2f  %s", s.id, s.tier, s.format, s.codes.size, ppm || 0,
                    s.tags.grep(/\Adeg:/).map { |t| t.delete_prefix("deg:") }.join(","))
      end
      tiers = all.group_by(&:tier).transform_values(&:size)
      puts "#{all.size} cases: #{tiers.map { |t, n| "#{t} #{n}" }.join(', ')}"
      return
    end
    abort "ImageMagick 7 (magick) not found" unless ScanSim.available?

    dir = options[:out]
    FileUtils.mkdir_p(dir)
    selected = options[:only].empty? ? all : all.select { |s| matches?(s, options[:only]) }
    selected = selected.reject { |s| File.exist?(File.join(dir, s.file)) } if options[:missing]
    failures = options[:manifest_only] ? {} : render_all(selected, dir, options[:jobs])
    File.write(File.join(dir, "manifest.json"), JSON.pretty_generate(manifest(all, dir)))
    warn "wrote #{File.join(dir, 'manifest.json')} (#{all.size} cases)"
    return if failures.empty?

    warn "#{failures.size} cases failed:"
    failures.each { |id, msg| warn "  #{id}: #{msg.lines.first(3).join('    ')}" }
    exit 1
  end
end

ScanCorpus.run(ARGV) if $PROGRAM_NAME == __FILE__
