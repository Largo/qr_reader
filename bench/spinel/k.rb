module QrReaderKernels
  # Sums the bytes of a String passed in from CRuby.
  def self.sum_param(s)
    sum = 0
    i = 0
    n = s.bytesize
    while i < n
      sum += s.getbyte(i)
      i += 1
    end
    sum
  end

  # Same, on a copy made inside the kernel.
  def self.sum_copy(s)
    t = String.new(capacity: s.bytesize, encoding: Encoding::BINARY)
    t << s
    sum = 0
    i = 0
    n = t.bytesize
    while i < n
      sum += t.getbyte(i)
      i += 1
    end
    sum
  end
end

module QrReaderKernels
  # byteindex hopping over a String passed in from CRuby (like JPEG entropy_data).
  def self.count_ff(data)
    ff = "\xFF".b
    n = 0
    p = 0
    while (f = data.byteindex(ff, p))
      n += 1
      p = f + 1
    end
    n
  end

  # The same on a String with the input's bytes, created inside the kernel.
  def self.count_ff_copy(data)
    copy = String.new(capacity: data.bytesize, encoding: Encoding::BINARY)
    copy << data
    count_ff(copy)
  end
end
