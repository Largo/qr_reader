def now
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

# 1. Appending single bytes to a growing binary String.
def append_bytes(n)
  out = String.new(capacity: n, encoding: Encoding::BINARY)
  i = 0
  while i < n
    out << (i & 255)
    i += 1
  end
  out.bytesize
end

# 2. Appending 2000-byte rows (built by a helper) to a growing String.
def make_row(k)
  row = String.new(capacity: 2000, encoding: Encoding::BINARY)
  i = 0
  while i < 2000
    row << ((i + k) & 255)
    i += 1
  end
  row
end

def append_rows(n)
  out = String.new(capacity: n * 2000, encoding: Encoding::BINARY)
  k = 0
  while k < n
    out << make_row(k)
    k += 1
  end
  out.bytesize
end

# 3. getbyte over a large binary String containing NUL bytes.
def read_bytes(s)
  sum = 0
  i = 0
  n = s.bytesize
  while i < n
    sum += s.getbyte(i)
    i += 1
  end
  sum
end

[250_000, 500_000, 1_000_000, 2_000_000].each do |n|
  t = now; append_bytes(n); a = now - t
  t = now; append_rows(n / 2000); b = now - t
  s = "\x00\x01".b * (n / 2)
  t = now; read_bytes(s); c = now - t
  puts "n=#{n}: append_bytes #{(a * 1000).round(1)} ms, append_rows #{(b * 1000).round(1)} ms, getbyte #{(c * 1000).round(1)} ms"
end
