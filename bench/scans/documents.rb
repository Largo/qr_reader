# frozen_string_literal: true

require "scan_sim"
require_relative "payloads"

# Page layouts of the documents people scan, built with ScanSim. Every
# builder takes a Random and the symbols to print (ScanSim::Code) with their
# physical size, and returns a ScanSim::Document with those symbols placed
# (keeping their quiet zones clear) among realistic clutter.
module ScanDocs
  include ScanSim
  extend self

  A4 = [210.0, 297.0].freeze
  LETTER = [215.9, 279.4].freeze
  PAPERS = ["white", "#fbfaf5", "#f7f4ea", "#f2f0e8", "#fdfcf8"].freeze
  INKS = { black: "black", thermal: "#26262e", blue: "#1a2f80", red: "#a3122a", green: "#155c2e",
           gray60: "#666666", gray45: "#8c8c8c", orange: "#e8740c", brown: "#5a3a1c", teal: "#0e5f6b" }.freeze

  # Shared options: paper:, texture:, ink: (text colour), qr_ink: (module
  # colour), gain: (dot gain of the symbols).
  def new_doc(size, opts)
    Document.new(*size, paper: opts.fetch(:paper, "white"), texture: opts.fetch(:texture, 0.6))
  end

  def qr_opts(opts)
    { color: opts.fetch(:qr_ink, "black"), gain: opts.fetch(:gain, 0.0) }
  end

  # Business letter (A4 or US Letter) with one symbol in the header, the
  # footer or next to the signature.
  def letter(rng, code, size, place: :footer, format: A4, **opts)
    doc = new_doc(format, opts)
    w, h = format
    ink = doc.ink
    color = opts.fetch(:ink, "black")
    company = ScanPayloads.pick(rng, ScanPayloads::COMPANIES)
    Clutter.logo(ink, rng, 20, 14, 8 + rng.rand * 4, company, color: opts.fetch(:brand, "#1a3c8c"))
    ink.text(20, 46, "#{company} · #{ScanPayloads.pick(rng, ScanPayloads::STREETS)} 12 · 8001 Zürich", size: 6.5, color: color)
    ink.line(20, 47.2, 95, 47.2, color: color, width: 0.12)
    Clutter.lines(ink, 20, 53, address(rng), size: 10, color: color)
    ink.text(w - 20, 88, "Zürich, #{Clutter.date(rng)}", size: 10, anchor: :end, color: color)
    ink.text(20, 100, "#{ScanPayloads.pick(rng, %w[Offerte Auftragsbestätigung Mahnung Kündigung Information])} " \
                      "#{ScanPayloads.digits(rng, 6)}", size: 12, font: SANS_BOLD, color: color)
    qx = w - 20 - size
    body_width = place == :body ? qx - 28 : w - 40
    y = 110
    (3 + rng.rand(3)).times do
      y = Clutter.paragraph(ink, rng, 20, y, body_width, lines: 2 + rng.rand(5), size: 10, color: color) + 4
      break if y > h - 80
    end
    ink.text(20, y + 4, "Freundliche Grüsse", size: 10, color: color)
    Clutter.signature(doc.marks, rng, 22, y + 8, 35 + rng.rand * 15, 10)
    ink.text(20, y + 26, ScanPayloads.person(rng), size: 10, color: color)
    footer(ink, rng, w, h, color, width: place == :footer ? w - 50 - size : w - 40)
    case place
    when :header then ink.qr(code, qx, 14, size, **qr_opts(opts))
    when :body then ink.qr(code, qx, [y - size, 112].max, size, **qr_opts(opts))
    else ink.qr(code, qx, h - 16 - size, size, **qr_opts(opts))
    end
    doc
  end

  def address(rng)
    zip, town = ScanPayloads.pick(rng, ScanPayloads::TOWNS)
    [ScanPayloads.pick(rng, ["Herr", "Frau", "Familie", ScanPayloads.pick(rng, ScanPayloads::COMPANIES)]),
     ScanPayloads.person(rng), "#{ScanPayloads.pick(rng, ScanPayloads::STREETS)} #{rng.rand(1..99)}", "#{zip} #{town}"]
  end

  def footer(ink, rng, w, h, color, width: w - 40)
    ink.line(20, h - 22, 20 + width, h - 22, color: color, width: 0.15)
    cols = [["Bankverbindung", "IBAN CH93 0076 2011 6238 5295 7", "BIC POFICHBEXXX"],
            ["Kontakt", "+41 44 123 45 67", "info@example.ch"],
            ["MWST-Nr.", "CHE-123.456.789 MWST", "HR Zürich"]]
    step = width / 3.0
    cols.each_with_index do |lines, i|
      Clutter.lines(ink, 20 + i * step, h - 17.5, lines, size: 6.5, color: color)
    end
    ink.text(w / 2, h - 6, "Seite 1 von 1", size: 6.5, anchor: :middle, color: color) if rng.rand < 0.5
  end

  # Invoice with a line-item table; +codes+ is [[code, size], ...]: the
  # first goes next to the payment information, a second one into the footer.
  def invoice(rng, codes, **opts)
    doc = new_doc(A4, opts)
    w, h = A4
    ink = doc.ink
    color = opts.fetch(:ink, "black")
    company = ScanPayloads.pick(rng, ScanPayloads::COMPANIES)
    Clutter.logo(ink, rng, 20, 14, 10, company, color: opts.fetch(:brand, "#7a1c1c"))
    Clutter.lines(ink, w - 20, 16, [company, "#{ScanPayloads.pick(rng, ScanPayloads::STREETS)} 7", "3011 Bern",
                                    "Tel. 031 123 45 67"], size: 8, anchor: :end, color: color)
    Clutter.lines(ink, 20, 50, address(rng), size: 10, color: color)
    meta = [["Rechnungsnr.", ScanPayloads.digits(rng, 7)], ["Datum", Clutter.date(rng)],
            ["Kundennr.", ScanPayloads.digits(rng, 5)], ["Fällig", Clutter.date(rng)]]
    meta.each_with_index do |(k, v), i|
      ink.text(125, 52 + i * 4.6, k, size: 8.5, color: color)
      ink.text(w - 20, 52 + i * 4.6, v, size: 8.5, anchor: :end, color: color)
    end
    ink.text(20, 86, "Rechnung", size: 16, font: SANS_BOLD, color: color)
    rows = 4 + rng.rand(9)
    y = Clutter.table(ink, rng, 20, 92, [12, 78, 22, 25, 33], rows: rows, size: 8.5, grid: rng.rand < 0.5, color: color)
    [["Zwischensumme", Clutter.amount(rng)], ["MwSt 8.1%", Clutter.amount(rng, 300)], ["Total CHF", Clutter.amount(rng)]]
      .each_with_index do |(k, v), i|
      font = i == 2 ? SANS_BOLD : SANS
      ink.text(130, y + 6 + i * 5, k, size: 9, font: font, color: color)
      ink.text(w - 20, y + 6 + i * 5, v, size: 9, font: font, anchor: :end, color: color)
    end
    main, main_size = codes[0]
    py = [y + 26, h - 40 - main_size].min
    text_x = 20
    if rng.rand < 0.5
      ink.qr(main, 20, py, main_size, **qr_opts(opts))
      text_x = 20 + main_size + 8
    else
      ink.qr(main, w - 20 - main_size, py, main_size, **qr_opts(opts))
    end
    ink.text(text_x, py + 4, "Zahlungsinformationen", size: 9, font: SANS_BOLD, color: color)
    Clutter.lines(ink, text_x, py + 9, ["Zahlbar innert 30 Tagen netto", "IBAN DE89 3704 0044 0532 0130 00",
                                        "Mit der Banking-App scannen"], size: 8.5, color: color)
    if codes[1]
      extra, extra_size = codes[1]
      ink.qr(extra, w - 20 - extra_size, h - 8 - extra_size, extra_size, **qr_opts(opts))
      ink.text(w - 24 - extra_size, h - 10, "Rechnung online ansehen", size: 7, anchor: :end, color: color)
      footer(ink, rng, w, h - extra_size + 8, color, width: w - 50 - extra_size)
    else
      footer(ink, rng, w, h, color)
    end
    doc
  end

  # Swiss QR-bill: an invoice whose bottom 105 mm are the payment part
  # (receipt 62 mm + payment part 148 mm, layout per the SIX implementation
  # guidelines), or just the detached slip (+slip+: 210 x 105 mm).
  def qr_bill(rng, code, slip: false, **opts)
    doc = new_doc(slip ? [210.0, 105.0] : A4, opts)
    ink = doc.ink
    color = opts.fetch(:ink, "black")
    top = slip ? 0.0 : 192.0
    unless slip
      company = qr_bill_fields(code.text)[:creditor][0]
      Clutter.logo(ink, rng, 20, 14, 9, company, color: opts.fetch(:brand, "#14532d"))
      Clutter.lines(ink, 20, 46, address(rng), size: 10, color: color)
      ink.text(20, 78, "Rechnung #{ScanPayloads.digits(rng, 6)}", size: 14, font: SANS_BOLD, color: color)
      y = Clutter.table(ink, rng, 20, 86, [12, 88, 20, 25, 25], rows: 2 + rng.rand(5), size: 8.5, grid: false, color: color)
      lines = ((top - y - 20) / 4.8).floor.clamp(1, 3)
      Clutter.paragraph(ink, rng, 20, y + 8, 170, lines: lines, size: 9, color: color)
      # Perforation with scissors symbol.
      ink.line(0, top, 210, top, color: color, width: 0.2, dash: [1.2, 0.8])
      ink.text(4, top + 1.2, "✂", size: 11, color: color)
    end
    ink.line(62, top, 62, top + 105, color: color, width: 0.2, dash: [1.2, 0.8])
    payment_part(ink, code, top, color, opts)
    doc
  end

  # Field values of a QR-bill payload (for printing them next to the code).
  def qr_bill_fields(text)
    f = text.split(/\r?\n/)
    { account: f[3], creditor: [f[5], "#{f[6]} #{f[7]}", "#{f[8]} #{f[9]}"], amount: f[18], currency: f[19],
      debtor: [f[21], "#{f[22]} #{f[23]}", "#{f[24]} #{f[25]}"], reference: f[28], message: f[29] }
  end

  def payment_part(ink, code, top, color, opts)
    f = qr_bill_fields(code.text)
    account = f[:account].to_s.scan(/.{1,4}/).join(" ")
    reference = f[:reference].to_s.empty? ? nil : f[:reference]
    # Receipt (left, 62 mm).
    ink.text(5, top + 9, "Empfangsschein", size: 11, font: SANS_BOLD, color: color)
    y = section(ink, 5, top + 16, "Konto / Zahlbar an", [account, *f[:creditor]], 6, 8, color)
    y = section(ink, 5, y + 2, "Referenz", [reference], 6, 8, color) if reference
    section(ink, 5, y + 2, "Zahlbar durch", f[:debtor], 6, 8, color)
    ink.text(5, top + 70, "Währung", size: 6, font: SANS_BOLD, color: color)
    ink.text(22, top + 70, "Betrag", size: 6, font: SANS_BOLD, color: color)
    ink.text(5, top + 74, f[:currency], size: 8, color: color)
    ink.text(22, top + 74, f[:amount].to_s.empty? ? "" : f[:amount], size: 8, color: color)
    ink.text(57, top + 88, "Annahmestelle", size: 6, font: SANS_BOLD, anchor: :end, color: color)
    # Payment part (148 mm): title, Swiss QR code with the cross, amount, information.
    ink.text(67, top + 9, "Zahlteil", size: 11, font: SANS_BOLD, color: color)
    ink.qr(code, 67, top + 17, 46, cross: true, **qr_opts(opts))
    ink.text(67, top + 70, "Währung", size: 8, font: SANS_BOLD, color: color)
    ink.text(87, top + 70, "Betrag", size: 8, font: SANS_BOLD, color: color)
    ink.text(67, top + 75, f[:currency], size: 10, color: color)
    ink.text(87, top + 75, f[:amount].to_s, size: 10, color: color)
    y = section(ink, 118, top + 9, "Konto / Zahlbar an", [account, *f[:creditor]], 8, 10, color)
    y = section(ink, 118, y + 2, "Referenz", [reference], 8, 10, color) if reference
    y = section(ink, 118, y + 2, "Zusätzliche Informationen", [f[:message]], 8, 10, color) unless f[:message].to_s.empty?
    section(ink, 118, y + 2, "Zahlbar durch", f[:debtor], 8, 10, color)
  end

  def section(ink, x, y, heading, lines, heading_size, size, color)
    ink.text(x, y, heading, size: heading_size, font: SANS_BOLD, color: color)
    Clutter.lines(ink, x, y + size * PT * 1.25, lines.compact, size: size, leading: 1.15, color: color)
  end

  # Thermal shipping label (100 x 150 mm) with several codes: +codes+ is
  # [[code, size], ...], the first is the big one.
  def label(rng, codes, **opts)
    doc = new_doc([100.0, 150.0], opts)
    ink = doc.ink
    color = opts.fetch(:ink, INKS[:thermal])
    ink.rect(2, 2, 96, 146, fill: nil, stroke: color, width: 0.6)
    carrier = ScanPayloads.pick(rng, %w[PAKETBLITZ SWIFTSHIP POSTA-EXPRESS VELOCARGO])
    ink.text(5, 13, carrier, size: 20, font: SANS_BOLD, color: color)
    service = ScanPayloads.pick(rng, %w[PRIORITY ECONOMY 24H])
    ink.text(95, 13, service, size: 12, font: SANS_BOLD, anchor: :end, color: color)
    ink.line(2, 17, 98, 17, color: color, width: 0.5)
    ink.text(5, 22, "FROM:", size: 6.5, font: SANS_BOLD, color: color)
    Clutter.lines(ink, 5, 26, [ScanPayloads.pick(rng, ScanPayloads::COMPANIES), "Industriestrasse 4", "6003 Luzern"],
                  size: 7, color: color)
    ink.line(2, 38, 98, 38, color: color, width: 0.5)
    ink.text(5, 43, "TO:", size: 6.5, font: SANS_BOLD, color: color)
    Clutter.lines(ink, 5, 49, address(rng).drop(1), size: 11, font: SANS_BOLD, color: color)
    ink.line(2, 66, 98, 66, color: color, width: 0.5)
    main, main_size = codes[0]
    ink.qr(main, 5, 69, main_size, **qr_opts(opts))
    rx = 5 + main_size + 4
    ink.text(rx, 75, "CH-#{rng.rand(1000..9999)}", size: 16, font: SANS_BOLD, color: color)
    route = "#{ScanPayloads.pick(rng, %w[ZH BE LU GE TI])} #{rng.rand(10..99)}"
    ink.text(rx, 82, route, size: 16, font: SANS_BOLD, color: color)
    if codes[1]
      extra, extra_size = codes[1]
      ink.qr(extra, 95 - extra_size, 69 + main_size - extra_size, extra_size, **qr_opts(opts))
    else
      Clutter.matrix_code(ink, rng, 95 - 14, 69 + main_size - 14, 14, color: color)
    end
    by = [69 + main_size + 5, 112].max
    Clutter.barcode(ink, rng, 8, by, 84, [140 - by - 6, 18].min, color: color)
    ink.text(5, 146, "Gewicht #{rng.rand(1..30)}.#{rng.rand(10)} kg · #{Clutter.date(rng)}", size: 6.5, color: color)
    if codes[2]
      third, third_size = codes[2]
      ink.qr(third, 95 - third_size, 19.5, third_size, **qr_opts(opts))
    end
    doc
  end

  # Thermal receipt (+width+ 80 or 58 mm), the symbol near the bottom.
  def receipt(rng, code, size, width: 80.0, **opts)
    items = 4 + rng.rand(10)
    height = 58 + items * 4.2 + size + 26
    doc = new_doc([width, height], opts)
    ink = doc.ink
    color = opts.fetch(:ink, INKS[:thermal])
    cx = width / 2
    ink.text(cx, 10, ScanPayloads.pick(rng, ["CAFÉ FÄSSLER", "BÄCKEREI ZÜRCHER", "MIGROLINO", "DROGERIE BÜHLER"]),
             size: 13, font: SANS_BOLD, anchor: :middle, color: color)
    header = ["Bahnhofplatz 3, 8001 Zürich", "MWST CHE-109.322.551", "#{Clutter.date(rng)} 10:42  Kasse 2"]
    Clutter.lines(ink, cx, 16, header, size: 7, anchor: :middle, color: color)
    y = 34
    ink.text(4, y, "-" * (width / 1.9).floor, size: 8, font: MONO, color: color)
    items.times do |i|
      name = Clutter.words(rng, 1 + rng.rand(2))[0, (width / 3.2).floor]
      ink.text(4, y + 5 + i * 4.2, "#{rng.rand(1..3)}x #{name}", size: 8, font: MONO, color: color)
      ink.text(width - 4, y + 5 + i * 4.2, Clutter.amount(rng, 30), size: 8, font: MONO, anchor: :end, color: color)
    end
    y += 5 + items * 4.2
    ink.text(4, y + 2, "TOTAL CHF", size: 11, font: MONO_BOLD, color: color)
    ink.text(width - 4, y + 2, Clutter.amount(rng, 200), size: 11, font: MONO_BOLD, anchor: :end, color: color)
    Clutter.lines(ink, 4, y + 8, ["Visa **** #{ScanPayloads.digits(rng, 4)}", "MWST 8.1% #{Clutter.amount(rng, 15)}"],
                  size: 7.5, font: MONO, color: color)
    ink.qr(code, cx - size / 2, y + 17, size, **qr_opts(opts.merge(qr_ink: opts.fetch(:qr_ink, color))))
    ink.text(cx, y + 22 + size, "Vielen Dank für Ihren Besuch!", size: 8, anchor: :middle, color: color)
    doc
  end

  # Business card (85 x 55 mm). +style+: :plain, :tinted, :panel (coloured
  # card, white panel behind the code), :inverted (light code on a dark
  # card), :color (coloured code).
  def business_card(rng, code, size, style: :plain, **opts)
    dark = ScanPayloads.pick(rng, ["#0d2a4f", "#3b0d2e", "#123c2b", "#222222"])
    paper = case style
            when :tinted then ScanPayloads.pick(rng, ["#f3eddc", "#e9eef3", "#f6e9e4"])
            else opts.fetch(:paper, "white")
            end
    doc = Document.new(85.0, 55.0, paper: paper, texture: opts.fetch(:texture, 1.0))
    ink = doc.ink
    text_color = "black"
    qx = 85 - 4 - size
    qy = 55 - 4 - size
    case style
    when :panel
      ink.rect(0, 0, 85, 55, fill: dark)
      ink.rect(qx - 2.5, qy - 2.5, size + 5, size + 5, fill: "white", radius: 1.5)
      text_color = "white"
    when :inverted
      ink.rect(0, 0, 85, 55, fill: dark)
      text_color = "#f0f0f0"
    end
    first = ScanPayloads.pick(rng, ScanPayloads::FIRST_NAMES)
    last = ScanPayloads.pick(rng, ScanPayloads::LAST_NAMES)
    ink.text(5, 10, "#{first} #{last}", size: 11, font: SANS_BOLD, color: text_color)
    ink.text(5, 15, ScanPayloads.pick(rng, ["Geschäftsführerin", "Projektleiter", "Directrice commerciale"]),
             size: 7.5, color: text_color)
    Clutter.lines(ink, 5, qy + 2, ["+41 44 123 45 67", "#{first.downcase[0, 4]}@example.ch", "www.example.ch",
                                   "Seeweg 5, 8640 Rapperswil"].first(((55 - qy - 4) / 3.5).floor.clamp(2, 4)),
                  size: 6.5, leading: 1.25, color: text_color)
    ink.rect(5, 18, 18, 0.6, fill: style == :plain || style == :tinted ? "#b8860b" : text_color)
    qr = case style
         when :inverted then { color: "#f4f4f4", background: dark }
         when :color then { color: opts.fetch(:qr_ink, "#0d2a4f") }
         else { color: opts.fetch(:qr_ink, "black") }
         end
    ink.qr(code, qx, qy, size, gain: opts.fetch(:gain, 0.0), **qr)
    doc
  end

  # Ticket: :a4 print-at-home (big code, colour header, ads) or :stub
  # (150 x 70 mm thermal card).
  def ticket(rng, code, size, kind: :a4, **opts)
    if kind == :stub
      doc = new_doc([150.0, 70.0], opts)
      ink = doc.ink
      color = opts.fetch(:ink, INKS[:thermal])
      venue = ScanPayloads.pick(rng, ["OPENAIR GURTEN", "HALLENSTADION", "KKL LUZERN"])
      ink.text(6, 12, venue, size: 14, font: SANS_BOLD, color: color)
      info = ["Sa #{Clutter.date(rng)} · Einlass 19:00",
              "Sektor #{rng.rand(1..9)} · Reihe #{rng.rand(1..30)} · Platz #{rng.rand(1..40)}",
              "CHF #{Clutter.amount(rng, 150)}"]
      Clutter.lines(ink, 6, 20, info, size: 9, color: color)
      ink.line(110, 0, 110, 70, color: color, width: 0.2, dash: [1, 1])
      Clutter.barcode(ink, rng, 6, 42, 60, 14, color: color)
      ink.qr(code, 114 + (32 - size) / 2.0, (70 - size) / 2.0, size,
             **qr_opts(opts.merge(qr_ink: opts.fetch(:qr_ink, color))))
      return doc
    end
    doc = new_doc(A4, opts)
    ink = doc.ink
    brand = opts.fetch(:brand, ScanPayloads.pick(rng, ["#c2185b", "#1565c0", "#2e7d32", "#ef6c00"]))
    ink.rect(0, 0, 210, 32, fill: brand)
    title = ScanPayloads.pick(rng, ["E-TICKET", "ONLINE-TICKET", "BILLET ÉLECTRONIQUE"])
    ink.text(15, 21, title, size: 22, font: SANS_BOLD, color: "white")
    event = ScanPayloads.pick(rng, ["Konzert: Züri West", "Musical: Die Schöne und das Biest", "FC Thun – FC Basel"])
    ink.text(15, 48, event, size: 15, font: SANS_BOLD)
    info = ["Datum: #{Clutter.date(rng)}, 20:00", "Ort: #{ScanPayloads.pick(rng, %w[Bern Basel Zürich Luzern])}",
            "Kategorie #{rng.rand(1..4)} · Platz #{rng.rand(1..300)}", "Preis CHF #{Clutter.amount(rng, 180)}",
            "Ticket-Nr. #{ScanPayloads.digits(rng, 12)}"]
    Clutter.lines(ink, 15, 58, info, size: 10)
    ink.qr(code, 195 - size, 42, size, **qr_opts(opts))
    Clutter.paragraph(ink, rng, 15, 100, 180, lines: 4, size: 7.5)
    Clutter.photo(ink, rng, 15, 125, 85, 60)
    Clutter.photo(ink, rng, 110, 125, 85, 60)
    ink.text(15, 196, "Anzeige", size: 6.5, color: "#555555")
    Clutter.paragraph(ink, rng, 15, 205, 180, lines: 10, size: 7)
    doc
  end

  # A4 page with several codes (+codes+: [[code, size], ...], 2..6).
  # +layout+: :labels (sheet of asset labels), :handout (sections with
  # different code sizes), :catalog (product table, a code per row).
  def multi(rng, codes, layout: :handout, **opts)
    doc = new_doc(A4, opts)
    ink = doc.ink
    color = opts.fetch(:ink, "black")
    case layout
    when :labels
      # 3 x 8 grid of 70 x 37 mm labels, codes on some of them.
      slots = (0...24).to_a.shuffle(random: rng).first(codes.size).sort
      24.times do |i|
        lx = (i % 3) * 70.0
        ly = 8.5 + (i / 3) * 35.0
        ink.rect(lx + 1, ly + 1, 68, 33, fill: nil, stroke: "#bbbbbb", width: 0.1, radius: 2) if rng.rand < 0.3
        k = slots.index(i)
        next unless k

        code, size = codes[k]
        size = [size, 29.0].min
        ink.qr(code, lx + 4, ly + (35 - size) / 2.0, size, **qr_opts(opts))
        Clutter.lines(ink, lx + size + 8, ly + 10, ["Inventar-Nr.", ScanPayloads.digits(rng, 6), "IT-Abteilung"],
                      size: 7.5, color: color)
      end
    when :catalog
      ink.text(20, 22, "Produktübersicht #{2026 - rng.rand(3)}", size: 16, font: SANS_BOLD, color: color)
      y = 34.0
      codes.each do |code, size|
        ink.qr(code, 20, y, size, **qr_opts(opts))
        ink.text(20 + size + 8, y + 5, Clutter.words(rng, 3), size: 11, font: SANS_BOLD, color: color)
        Clutter.paragraph(ink, rng, 20 + size + 8, y + 11, 150 - size, lines: 2, size: 8.5, color: color)
        ink.text(190, y + 5, "CHF #{Clutter.amount(rng, 900)}", size: 11, anchor: :end, color: color)
        y += [size, 22].max + 9
        ink.line(20, y - 4.5, 190, y - 4.5, color: "#999999", width: 0.15)
      end
    else
      ink.text(20, 22, ScanPayloads.pick(rng, ["Weiterführende Links", "Unterlagen zum Kurs", "Ressources en ligne"]),
               size: 16, font: SANS_BOLD, color: color)
      y = 34.0
      codes.each_with_index do |(code, size), i|
        left = i.even?
        qx = left ? 20 : 190 - size
        ink.qr(code, qx, y, size, **qr_opts(opts))
        tx = left ? 20 + size + 8 : 20
        ink.text(tx, y + 5, Clutter.words(rng, 2 + rng.rand(3)), size: 12, font: SANS_BOLD, color: color)
        Clutter.paragraph(ink, rng, tx, y + 12, 162 - size, lines: 3 + rng.rand(3), size: 9, color: color)
        y += [size, 30].max + 10
      end
      Clutter.paragraph(ink, rng, 20, y, 170, lines: ((280 - y) / 4.8).floor.clamp(0, 8), size: 9, color: color) if y < 270
    end
    doc
  end

  # A4 page with the code in a corner, +margin+ mm from both edges.
  def edge(rng, code, size, corner: :bottom_right, margin: 4.0, **opts)
    doc = letter(rng, code, 1.0, **opts, place: :header)
    doc.placements.clear
    doc.ink.items.reject! { |item| item[0] == :qr }
    w, h = A4
    x = %i[top_left bottom_left].include?(corner) ? margin : w - margin - size
    y = %i[top_left top_right].include?(corner) ? margin : h - margin - size
    # A white sticker behind the code covers the page content there.
    doc.ink.qr(code, x, y, size, background: "white", quiet: 2, **qr_opts(opts))
    doc
  end

  # Fax cover sheet / order form with a code.
  def fax_form(rng, code, size, **opts)
    doc = new_doc(A4, opts)
    ink = doc.ink
    ink.text(20, 30, "FAX", size: 40, font: SANS_BOLD)
    ink.text(190, 30, ScanPayloads.pick(rng, ScanPayloads::COMPANIES), size: 11, font: SANS_BOLD, anchor: :end)
    fields = ["An:", "Firma:", "Fax-Nr.:", "Von:", "Datum:", "Seiten:", "Betreff:"]
    fields.each_with_index do |f, i|
      y = 50 + i * 9
      ink.text(20, y, f, size: 11, font: SANS_BOLD)
      ink.text(55, y, i == 4 ? Clutter.date(rng) : Clutter.words(rng, 2 + rng.rand(2)), size: 11)
      ink.line(55, y + 1.5, 190 - (i < 4 ? size + 6 : 0), y + 1.5, width: 0.2)
    end
    ink.qr(code, 190 - size, 44, size, gain: opts.fetch(:gain, 0.0))
    y = Clutter.paragraph(ink, rng, 20, 125, 170, lines: 8 + rng.rand(6), size: 10)
    Clutter.table(ink, rng, 20, y + 8, [15, 95, 25, 35], rows: 3 + rng.rand(4), size: 9)
    ink.rect(20, 255, 170, 18, fill: nil, stroke: "black", width: 0.3)
    ink.text(23, 261, "Bitte unterschrieben zurückfaxen an +41 44 123 45 68", size: 9)
    Clutter.signature(doc.marks, rng, 120, 259, 40, 10, color: "#111111")
    doc
  end

  # A4 page with one big high-version code (signed e-invoice etc.).
  def large(rng, code, size, **opts)
    doc = new_doc(A4, opts)
    ink = doc.ink
    color = opts.fetch(:ink, "black")
    ink.text(20, 22, "Tax Invoice (e-Invoice)", size: 16, font: SANS_BOLD, color: color)
    ack = ["IRN: #{ScanPayloads.token(rng, 64, [*'0'..'9', *'a'..'f'])}", "Ack No.: #{ScanPayloads.digits(rng, 15)}",
           "Ack Date: #{Clutter.date(rng)}"]
    Clutter.lines(ink, 20, 32, ack, size: 7.5, font: MONO, color: color)
    qx = 190 - size
    ink.qr(code, qx, 50, size, **qr_opts(opts))
    Clutter.lines(ink, 20, 56, address(rng), size: 10, color: color)
    Clutter.lines(ink, 20, 82, address(rng), size: 10, color: color)
    y = [50 + size + 10, 110].max
    y = Clutter.table(ink, rng, 20, y, [12, 78, 22, 25, 33], rows: 3 + rng.rand(8), size: 8.5, color: color)
    lines = ((285 - y - 10) / 4.6).floor.clamp(0, 10)
    Clutter.paragraph(ink, rng, 20, y + 10, 170, lines: lines, size: 9, color: color)
    doc
  end

  # Magazine / book page: text columns, colour photos and an advert with a
  # coloured code on a coloured box. +spine+ (:left/:right) leaves room for
  # the gutter.
  def magazine(rng, code, size, spine: :left, **opts)
    doc = new_doc([200.0, 270.0], opts)
    ink = doc.ink
    inner = spine == :left ? 22.0 : 14.0
    section = ScanPayloads.pick(rng, ["Reportage", "Wohnen & Garten", "Digital", "Reisen"]).upcase
    ink.text(inner, 22, section, size: 9, font: SANS_BOLD, color: "#b71c1c")
    ink.text(inner, 34, Clutter.words(rng, 4), size: 20, font: SERIF_BOLD)
    col_w = (200 - 36 - 6) / 2.0
    Clutter.photo(ink, rng, inner, 42, 200 - 36, 70)
    y0 = 120
    2.times do |c|
      Clutter.paragraph(ink, rng, inner + c * (col_w + 6), y0, col_w, lines: 18, size: 8.5, font: SERIF)
    end
    box_y = 205.0
    box_color = opts.fetch(:box, ScanPayloads.pick(rng, ["#fde9a9", "#d7ecf7", "#f9d7d0", "#e3f1d4"]))
    ink.rect(inner, box_y, 200 - 36, 55, fill: box_color)
    ink.text(inner + 5, box_y + 12, "Jetzt scannen und gewinnen!", size: 14, font: SANS_BOLD, color: "#222222")
    Clutter.paragraph(ink, rng, inner + 5, box_y + 21, 200 - 46 - size - 8, lines: 5, size: 8.5, color: "#222222")
    panel = opts.fetch(:panel, nil)
    ink.qr(code, inner + 200 - 36 - 5 - size, box_y + (55 - size) / 2.0, size,
           background: panel, quiet: panel ? 2 : 4, **qr_opts(opts))
    doc
  end

  # A plain text page (multi-page documents: pages without codes).
  def text_page(rng, **opts)
    doc = new_doc(A4, opts)
    y = 25.0
    while y < 260
      y = Clutter.paragraph(doc.ink, rng, 20, y, 170, lines: 3 + rng.rand(6), size: 10,
                                                     color: opts.fetch(:ink, "black")) + 5
    end
    doc
  end

  # Separator sheet for batch scanning: big text and a code in the middle.
  def separator(rng, code, size, **opts)
    doc = new_doc(A4, opts)
    doc.ink.text(105, 60, "TRENNBLATT", size: 40, font: SANS_BOLD, anchor: :middle)
    doc.ink.text(105, 75, "Dokument #{ScanPayloads.digits(rng, 5)} · nicht entfernen", size: 12, anchor: :middle)
    doc.ink.qr(code, 105 - size / 2, 110, size, gain: opts.fetch(:gain, 0.0))
    doc
  end
end
