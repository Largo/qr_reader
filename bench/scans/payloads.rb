# frozen_string_literal: true

# Realistic QR payloads found on scanned paper: Swiss QR-bills (SIX
# implementation guidelines v2.3), SEPA/EPC GiroCodes, vCards, URLs, receipt
# signatures (Austrian RKSV), ticket and parcel codes, signed e-invoice JWTs,
# UTF-8 text and plain numbers. Deterministic for a given Random.
module ScanPayloads
  FIRST_NAMES = %w[Jürg Anna-Lena Sébastien Zoë Ueli Françoise Jörg Mia Noah Béatrice Lukas Elif Nicolò Ruth].freeze
  LAST_NAMES = %w[Häfeli Müller Schnyder Rüegg Dubois Märki Brändli Gerber Würsch Zürcher Fässler Bühler
                  Rutschmann-Schnyder Kälin].freeze
  COMPANIES = ["Häfeli Treuhand AG", "Bäckerei Zürcher GmbH", "Elektro Brändli AG", "Société Générale de Fribourg SA",
               "Rösti & Söhne KG", "Schreinerei Würsch", "Garage du Lac Sàrl", "Müller Haustechnik AG",
               "Stiftung Bühl", "Café Fässler", "Märki Logistik AG", "Genossenschaft Kälin"].freeze
  STREETS = ["Bahnhofstrasse", "Rue du Lac", "Grosse Marktgasse", "Hauptstrasse", "Chemin des Écoliers",
             "Dorfstrasse", "Seeweg", "Via Cantonale", "Löwenstrasse", "Rämistrasse", "Avenue de la Gare"].freeze
  TOWNS = [%w[8001 Zürich], %w[2501 Biel], %w[9400 Rorschach], %w[1700 Fribourg], %w[3011 Bern], %w[4051 Basel],
           %w[6003 Luzern], %w[1204 Genève], %w[8640 Rapperswil], %w[7000 Chur], %w[6900 Lugano]].freeze
  DOMAINS = %w[example.com example.ch example.de shop.example.org portal.example.net beispiel.ch].freeze
  BASE64URL = [*"A".."Z", *"a".."z", *"0".."9", "-", "_"].freeze

  module_function

  def pick(rng, list)
    list[rng.rand(list.size)]
  end

  def digits(rng, n)
    Array.new(n) { rng.rand(10) }.join
  end

  def token(rng, n, alphabet = BASE64URL)
    Array.new(n) { alphabet[rng.rand(alphabet.size)] }.join
  end

  def person(rng)
    "#{pick(rng, FIRST_NAMES)} #{pick(rng, LAST_NAMES)}"
  end

  # A web address of +length+ characters or so (invoice portals, product
  # pages, review links, tracking).
  def url(rng, length: 40)
    base = "https://#{pick(rng, %w[www. portal. app. ])}#{pick(rng, DOMAINS)}/"
    path = pick(rng, %w[r/ i/ invoice/ de/rechnung/ track/ p/ go/ fr/facture/])
    rest = [length - base.size - path.size, 4].max
    "#{base}#{path}#{token(rng, rest)}"
  end

  # Upper-case URL (fits the alphanumeric mode, as some ticket and label
  # printers encode it).
  def alnum_url(rng)
    "HTTPS://#{pick(rng, %w[QR.EXAMPLE.COM T.EXAMPLE.CH GO.EXAMPLE.DE])}/#{token(rng, 8 + rng.rand(14), [*'A'..'Z', *'0'..'9'])}"
  end

  # vCard 3.0 business card with accented names.
  def vcard(rng)
    first = pick(rng, FIRST_NAMES)
    last = pick(rng, LAST_NAMES)
    company = pick(rng, COMPANIES)
    street = "#{pick(rng, STREETS)} #{rng.rand(1..120)}"
    zip, town = pick(rng, TOWNS)
    mail = "#{first.downcase.tr('äöüéèëçò', 'aoueeeco').delete('^a-z')}.#{last.downcase.tr('äöüéè', 'aouee').delete('^a-z')}"
    lines = ["BEGIN:VCARD", "VERSION:3.0", "N:#{last};#{first};;;", "FN:#{first} #{last}", "ORG:#{company}",
             "TITLE:#{pick(rng, %w[Geschäftsführerin Projektleiter Directrice Buchhaltung Verkaufsleiter])}",
             "TEL;TYPE=WORK,VOICE:+41 #{rng.rand(21..91)} #{digits(rng, 3)} #{digits(rng, 2)} #{digits(rng, 2)}",
             "EMAIL:#{mail}@#{pick(rng, DOMAINS)}", "ADR;TYPE=WORK:;;#{street};#{town};;#{zip};Schweiz"]
    lines << "TEL;TYPE=CELL:+41 7#{rng.rand(5..9)} #{digits(rng, 3)} #{digits(rng, 2)} #{digits(rng, 2)}" if rng.rand < 0.6
    lines << "URL:https://www.#{pick(rng, DOMAINS)}" if rng.rand < 0.6
    lines << "END:VCARD"
    lines.join(rng.rand < 0.7 ? "\r\n" : "\n")
  end

  # SEPA credit transfer (EPC069-12 "GiroCode").
  def epc(rng)
    iban = iban(rng, "DE", digits(rng, 18))
    ["BCD", "002", "1", "SCT", pick(rng, %w[COBADEFFXXX GENODEF1S04 BFSWDE33BER INGDDEFFXXX]),
     pick(rng, COMPANIES), iban, format("EUR%.2f", rng.rand(5.0..2500.0)), "", "",
     "Rechnung #{digits(rng, 6)} vom #{rng.rand(1..28)}.#{rng.rand(1..12)}.2026"].join("\n")
  end

  # Swiss QR-bill payload (SPC 0200, structured addresses). +reference+:
  # :qrr (QR-IBAN + QR reference), :scor (IBAN + creditor reference) or :non.
  def qr_bill(rng, reference: nil, amount: true, info: true)
    reference ||= pick(rng, %i[qrr qrr scor non])
    account = if reference == :qrr
                iban(rng, "CH", "#{rng.rand(30_000..31_999)}#{digits(rng, 12)}")
              else
                iban(rng, "CH", "#{format('%05d', rng.rand(100..9999))}#{digits(rng, 12)}")
              end
    ref = case reference
          when :qrr then qrr_reference(digits(rng, 26))
          when :scor then scor_reference(token(rng, 6 + rng.rand(10), [*"A".."Z", *"0".."9"]))
          else ""
          end
    zip, town = pick(rng, TOWNS)
    dzip, dtown = pick(rng, TOWNS)
    message = info ? "#{pick(rng, ['Rechnung', 'Facture', 'Auftrag vom', 'Abo', 'Mitgliederbeitrag'])} #{digits(rng, 5)}" : ""
    billing = info && rng.rand < 0.5 ? "//S1/10/#{digits(rng, 8)}/11/#{digits(rng, 6)}/30/#{digits(rng, 9)}/32/8.1" : ""
    fields = ["SPC", "0200", "1", account,
              "S", pick(rng, COMPANIES), pick(rng, STREETS), rng.rand(1..99).to_s, zip, town, "CH",
              "", "", "", "", "", "", "",
              amount ? format("%.2f", rng.rand(10.0..4000.0)) : "", "CHF",
              "S", person(rng), pick(rng, STREETS), rng.rand(1..99).to_s, dzip, dtown, "CH",
              reference.to_s.upcase, ref, message, "EPD"]
    fields << billing unless billing.empty?
    fields << "eBill/B/#{pick(rng, %w[peter.muster@example.com 41010560425610173])}" if rng.rand < 0.2
    fields.join(rng.rand < 0.5 ? "\r\n" : "\n")
  end

  # IBAN with valid ISO 13616 check digits.
  def iban(_rng, country, bban)
    numeric = "#{bban}#{country}00".gsub(/[A-Z]/) { |c| (c.ord - 55).to_s }
    "#{country}#{format('%02d', 98 - numeric.to_i % 97)}#{bban}"
  end

  # 27-digit QR reference: 26 digits plus the modulo-10 recursive check digit.
  def qrr_reference(body)
    table = [0, 9, 4, 6, 8, 2, 7, 1, 3, 5]
    carry = body.each_char.reduce(0) { |c, d| table[(c + d.to_i) % 10] }
    "#{body}#{(10 - carry) % 10}"
  end

  # ISO 11649 creditor reference "RFxx...".
  def scor_reference(body)
    numeric = "#{body}RF00".gsub(/[A-Z]/) { |c| (c.ord - 55).to_s }
    "RF#{format('%02d', 98 - numeric.to_i % 97)}#{body}"
  end

  # UTF-8 text with umlauts and other non-ASCII characters (labels, notes).
  def utf8_text(rng)
    item = pick(rng, ["Grösse 42, Farbe Grün", "Größe XL – Blau", "Käse & Brötchen", "Café crème, 2× Croissant",
                      "Lagerort Bühl, Regal Ä3", "Übergabe an Hr. Jürg Häfeli", "Pièce détachée n° 7",
                      "Prüfprotokoll bestanden ✓", "Temperatur −18 °C", "Ölwechsel fällig: 15 000 km"])
    "#{pick(rng, ['Lieferschein', 'Bon de livraison', 'Inventar', 'Prüfetikette', 'Notiz'])} " \
      "#{digits(rng, 5)} – #{item} – #{pick(rng, %w[Zürich Genève München Linz])}"
  end

  # Digits only (meter numbers, parcel/inventory IDs): numeric mode.
  def numeric(rng, length = 20)
    digits(rng, length)
  end

  # Signed e-invoice token (e.g. a GST e-invoice JWT): long base64url
  # payload for high-version symbols.
  def jwt(rng, length)
    header = "eyJhbGciOiJSUzI1NiIsImtpZCI6IjQ0NDQwNUM3ODFFNDgyNTA3MkIzNENBNEY4QkRDNjA2Qzg2QjU3MjAiLCJ0eXAiOiJKV1QifQ"
    body_len = [length - header.size - 2 - 342, 20].max
    "#{header}.#{token(rng, body_len)}.#{token(rng, 342)}"
  end

  # Austrian cash register receipt code (RKSV): "_R1-AT1_..." with base64 parts.
  def rksv(rng)
    b64 = [*"A".."Z", *"a".."z", *"0".."9", "+", "/"]
    amounts = Array.new(5) { |i| i.zero? ? format("%.2f", rng.rand(1.0..300.0)).tr(".", ",") : "0,00" }
    ["", "R1-AT#{rng.rand(0..3)}", "KASSE-#{digits(rng, 2)}", "ft#{digits(rng, 4)}#1",
     "2026-#{format('%02d', rng.rand(1..12))}-#{format('%02d', rng.rand(1..28))}T#{format('%02d', rng.rand(7..21))}:" \
     "#{format('%02d', rng.rand(60))}:#{format('%02d', rng.rand(60))}",
     *amounts, "#{token(rng, 22, b64)}==", "#{token(rng, 8, [*'0'..'9', *'A'..'F'])}",
     "#{token(rng, 11, b64)}=", "#{token(rng, 86, b64)}=="].join("_")
  end

  # Event or travel ticket barcode content.
  def ticket(rng)
    case rng.rand(3)
    when 0 then "TKT:#{digits(rng, 4)}-#{token(rng, 6, [*'A'..'Z', *'0'..'9'])}:SEAT-#{pick(rng, %w[A B C D])}#{rng.rand(1..40)}:" \
                "#{token(rng, 40 + rng.rand(40))}"
    when 1 then token(rng, 80 + rng.rand(120), [*"A".."Z", *"a".."z", *"0".."9", "+", "/"])
    else alnum_url(rng)
    end
  end

  # Parcel label content: tracking URL or GS1 Digital Link.
  def parcel(rng)
    if rng.rand < 0.5
      "https://#{pick(rng, %w[track.example.com parcel.example.ch])}/#{digits(rng, 18)}"
    else
      "https://id.example.com/01/#{digits(rng, 14)}/21/#{token(rng, 10, [*'A'..'Z', *'0'..'9'])}"
    end
  end
end
