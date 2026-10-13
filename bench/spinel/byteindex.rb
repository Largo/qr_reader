def now
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

# Counts 0xFF bytes with byteindex(needle, from) hopping through the data.
def count_ff(data)
  ff = "\xFF".b
  n = 0
  p = 0
  while (f = data.byteindex(ff, p))
    n += 1
    p = f + 1
  end
  n
end

# Same with byteslice of the stretch before each hit (like entropy_data).
def copy_runs(data)
  ff = "\xFF".b
  buf = String.new(capacity: data.bytesize, encoding: Encoding::BINARY)
  p = 0
  while (f = data.byteindex(ff, p))
    buf << data.byteslice(p, f - p)
    p = f + 1
  end
  buf.bytesize
end

[250_000, 500_000, 1_000_000, 2_000_000].each do |size|
  data = ("\x01".b * 255 + "\xFF".b) * (size / 256)
  t = now; a = count_ff(data); t1 = now - t
  t = now; copy_runs(data); t2 = now - t
  puts "#{size} bytes (#{a} hits): byteindex #{(t1 * 1000).round(1)} ms, +byteslice #{(t2 * 1000).round(1)} ms"
end
