def now
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

class Rows
  def initialize(count, width)
    @width = width
    @rows = Array.new(count, "".b)
    r = 0
    while r < count
      @rows[r] = "\0".b * width
      r += 1
    end
  end

  # setbyte into a String held in an Array instance variable.
  def fill(r)
    row = @rows[r]
    i = 0
    while i < @width
      row.setbyte(i, i & 255)
      i += 1
    end
    @rows[r] = row
  end

  def total
    s = 0
    r = 0
    while r < @rows.size
      s += @rows[r].getbyte(@width - 1)
      r += 1
    end
    s
  end
end

[1000, 2000, 4000, 8000].each do |width|
  rows = Rows.new(100, width)
  t = now
  r = 0
  while r < 100
    rows.fill(r)
    r += 1
  end
  dt = now - t
  puts "width #{width}: #{(dt * 1000).round(2)} ms for #{100 * width} setbytes (#{(dt * 1e9 / (100 * width)).round(1)} ns each), check #{rows.total}"
end
