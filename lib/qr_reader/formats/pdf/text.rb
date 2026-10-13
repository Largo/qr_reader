# frozen_string_literal: true

module QrReader
  module Formats
    module PDF
      # Text drawing for the vector pass (ISO 32000-1, 9.3 and 9.4): when
      # paths are collected, ContentScanner positions every glyph and hands
      # the module-like ones (barcode fonts) to the PathCollector; Type 3
      # glyph procedures are run like forms.
      class ContentScanner
        TEXT_OPERATORS = %w[BT ET Tf Tm Td TD T* TL Tc Tw Tz Ts Tr Tj TJ ' "].to_h { |op| [op, true] }.freeze
        # Type 3 glyph procedures run per page (each is a content stream).
        MAX_TYPE3_GLYPHS = 20_000
        # Elements of strings and arrays parsed from one page's content.
        TEXT_ELEMENTS = 1_000_000

        private

        # The String, hex String or Array operand at the scanner position,
        # or nil (garbage is skipped).
        def text_operand(s, data)
          @text_parser ||= {}
          parser = @text_parser[data.object_id] ||= Parser.new(data, @text_budget ||= [TEXT_ELEMENTS])
          parser.pos = s.pos
          value = parser.parse
          s.pos = parser.pos
          value.is_a?(String) || value.is_a?(Array) ? value : nil
        rescue ParseError
          s.pos += 1
          nil
        end

        def text_operator(token, operands, ctm, resources, depth)
          st = @paths.state
          case token
          when "BT" then @tm = @tlm = IDENTITY
          when "Tf"
            name, size = operands.last(2)
            st.font = name.is_a?(String) && name.start_with?("/") ? font(resources, Parser.name_symbol(name)) : nil
            st.font_size = size.to_f
          when "Tm"
            m = operands.last(6).map { |v| text_number(v) }
            @tm = @tlm = m if m.size == 6 && m.none?(&:nil?)
          when "Td", "TD"
            tx, ty = operands.last(2).map { |v| text_number(v) }
            if tx && ty
              st.leading = -ty if token == "TD"
              next_line(tx, ty)
            end
          when "T*" then next_line(0.0, -st.leading)
          when "TL" then st.leading = text_number(operands.last) || st.leading
          when "Tc" then st.char_spacing = text_number(operands.last) || st.char_spacing
          when "Tw" then st.word_spacing = text_number(operands.last) || st.word_spacing
          when "Tz" then st.scaling = text_number(operands.last) || st.scaling
          when "Ts" then st.rise = text_number(operands.last) || st.rise
          when "Tr" then st.render = text_number(operands.last)&.to_i || st.render
          when "Tj" then show(operands.last, ctm, resources, depth)
          when "'"
            next_line(0.0, -st.leading)
            show(operands.last, ctm, resources, depth)
          when "\""
            aw, ac, string = operands.last(3)
            st.word_spacing = text_number(aw) || st.word_spacing
            st.char_spacing = text_number(ac) || st.char_spacing
            next_line(0.0, -st.leading)
            show(string, ctm, resources, depth)
          when "TJ"
            items = operands.last
            return unless items.is_a?(Array)

            items.each do |item|
              if item.is_a?(String)
                show(item, ctm, resources, depth)
              elsif (n = text_number(item))
                advance(-n / 1000.0 * st.font_size * st.scaling / 100.0)
              end
            end
          end
        rescue Error, *INTERNAL_ERRORS
          nil
        end

        def text_number(value)
          case value
          when String then value.start_with?("/") ? nil : (v = value.to_f).finite? ? v : nil
          else Util.number(value)
          end
        end

        def next_line(tx, ty)
          @tlm = multiply([1.0, 0.0, 0.0, 1.0, tx, ty], @tlm || IDENTITY)
          @tm = @tlm
        end

        # Moves the text matrix +tx+ along the line.
        def advance(tx)
          m = @tm || IDENTITY
          @tm = [m[0], m[1], m[2], m[3], tx * m[0] + m[4], tx * m[1] + m[5]]
        end

        def font(resources, name)
          fonts = @doc.dict_value(@doc.dict_value(resources)&.[](:Font)) or return nil
          ref = fonts[name] or return nil
          cache = @doc.fonts
          key = ref.is_a?(Ref) ? ref : @doc.resolve(ref).object_id
          cache.key?(key) ? cache[key] : (cache[key] = Font.load(@doc, ref))
        end

        def show(string, ctm, resources, depth)
          st = @paths.state
          font = st.font
          return unless string.is_a?(String) && font

          size = st.font_size
          h = st.scaling / 100.0
          visible = ![3, 7].include?(st.render)
          font.each_code(string) do |code, w0, space|
            if visible
              trm = multiply(multiply([size * h, 0.0, 0.0, size, 0.0, st.rise], @tm || IDENTITY), ctm)
              if font.type3?
                type3_glyph(font, code, trm, resources, depth)
              elsif (polys = font.glyph(code))
                @paths.add_glyph(polys, trm)
              end
            end
            advance((w0 * size + st.char_spacing + (space ? st.word_spacing : 0.0)) * h)
          end
        end

        # Runs a Type 3 glyph procedure (its images are not collected).
        def type3_glyph(font, code, trm, resources, depth)
          return if depth >= MAX_FORM_DEPTH || (@type3_runs = (@type3_runs || 0) + 1) > MAX_TYPE3_GLYPHS

          content = font.procedure(code) or return
          tm = @tm
          tlm = @tlm
          @paths.save
          @in_glyph = (@in_glyph || 0) + 1
          scan(content, font.resources || resources, multiply(font.matrix, trm), depth + 1)
        ensure
          if content
            @in_glyph -= 1
            @paths.restore
            @tm = tm
            @tlm = tlm
          end
        end
      end
    end
  end
end
