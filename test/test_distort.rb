# frozen_string_literal: true

require_relative "test_helper"
require "qr_encoder"
require "distort"
require "reference"
require "tmpdir"

# Self-tests for the image distortions in test/support/distort.rb.
class TestDistort < Minitest::Test
  def setup
    @symbol = QrTestEncoder.build("DISTORT 0123456789", version: 2, level: :M, mask: 3)
    @image = @symbol.to_image(module_size: 4)
  end

  def gray(width, height, value)
    QrReader::Image.new(width, height, value.chr.b * (width * height))
  end

  def ramp(width, height)
    data = String.new(capacity: width * height, encoding: Encoding::BINARY)
    height.times { |y| width.times { |x| data << ((x * 7 + y * 13) % 256).chr } }
    QrReader::Image.new(width, height, data)
  end

  def max_diff(a, b)
    assert_equal [a.width, a.height], [b.width, b.height]
    a.data.bytes.zip(b.data.bytes).map { |p, q| (p - q).abs }.max
  end

  def mean(image)
    image.data.sum.fdiv(image.size)
  end

  def test_lookup_table_distortions
    c = Distort.contrast(@image, low: 80, high: 170)
    assert_equal [80, 170], c.data.bytes.minmax
    assert_equal 255 - @image[0, 0], Distort.invert(@image)[0, 0]
    assert_equal 0, Distort.brightness(gray(2, 2, 10), -20)[0, 0]
    assert_equal 255, Distort.brightness(gray(2, 2, 250), 10)[1, 1]
    assert_equal 64, Distort.gamma(gray(1, 1, 128), 2)[0, 0]
    assert_equal @image.mirror.data, Distort.mirror(@image).data
  end

  def test_gradient_and_vignette
    white = gray(101, 51, 255)
    g = Distort.gradient(white, from: 1.0, to: 0.4)
    assert_in_delta 255, g[0, 10], 1
    assert_in_delta 102, g[100, 10], 1
    assert_in_delta 178, g[50, 30], 2
    v = Distort.gradient(white, from: 0.5, to: 1.0, angle: 90)
    assert_in_delta 127, v[60, 0], 1
    assert_in_delta 255, v[60, 50], 1
    vig = Distort.vignette(gray(101, 101, 200), strength: 0.5)
    assert_equal 200, vig[50, 50]
    assert_in_delta 100, vig[0, 0], 1
  end

  def test_shadow_darkens_part_of_the_image
    s = Distort.shadow(gray(80, 80, 200), darkness: 0.5, seed: 4)
    values = s.data.bytes.tally
    assert_operator values.fetch(200, 0), :>, 0
    assert_operator values.fetch(100, 0), :>, 0
    assert_equal s.data, Distort.shadow(gray(80, 80, 200), darkness: 0.5, seed: 4).data
    refute_equal s.data, Distort.shadow(gray(80, 80, 200), darkness: 0.5, seed: 5).data
  end

  def test_gaussian_noise_statistics
    img = gray(200, 200, 128)
    noisy = Distort.gaussian_noise(img, sigma: 20, seed: 1)
    values = noisy.data.bytes
    m = values.sum.fdiv(values.size)
    sd = Math.sqrt(values.sum { |v| (v - m)**2 } / values.size)
    assert_in_delta 128, m, 1
    assert_in_delta 20, sd, 1
    assert_equal noisy.data, Distort.gaussian_noise(img, sigma: 20, seed: 1).data
    refute_equal noisy.data, Distort.gaussian_noise(img, sigma: 20, seed: 2).data
  end

  def test_salt_and_pepper
    img = gray(100, 100, 128)
    sp = Distort.salt_pepper(img, amount: 0.1, seed: 3)
    changed = sp.data.bytes.count { |v| v != 128 }
    assert_includes 900..1000, changed # positions may repeat
    assert_equal [0, 255], sp.data.bytes.reject { |v| v == 128 }.uniq.sort
  end

  def test_blurs_preserve_flat_areas_and_match_reference_box_blur
    flat = gray(40, 30, 90)
    assert_equal flat.data, Distort.blur(flat, 2.5).data
    assert_equal flat.data, Distort.motion_blur(flat, length: 9, angle: 30).data
    [1, 2, 5].each { |r| assert_operator max_diff(Distort.box_blur(@image, r), QrTestHelper.blur(@image, r)), :<=, 1 }
    blurred = Distort.blur(@image, 1.5)
    assert_operator blurred.data.bytes.count { |v| v > 0 && v < 255 }, :>, @image.size / 10
  end

  def test_motion_blur_is_directional
    # A vertical edge: horizontal motion blurs it, vertical motion does not.
    data = String.new(encoding: Encoding::BINARY)
    20.times { data << ("\0".b * 10) << ("\xFF".b * 10) }
    edge = QrReader::Image.new(20, 20, data)
    assert_equal edge.data, Distort.motion_blur(edge, length: 7, angle: 90).data
    h = Distort.motion_blur(edge, length: 7, angle: 0)
    assert_equal [0, 36, 73, 109, 146, 182, 219, 255], h.row(5).bytes[6, 8]
  end

  def test_scale
    img = ramp(64, 48)
    assert_equal img.downscale(2).data, Distort.scale(img, 0.5).data
    assert_equal img.downscale(4).data, Distort.scale(img, 0.25).data
    small = Distort.scale(@image, 0.375) # 4 px/module -> 1.5 px/module
    assert_equal [(@image.width * 0.375).round] * 2, [small.width, small.height]
    big = Distort.scale(gray(10, 10, 77), 2.5)
    assert_equal [25, 25], [big.width, big.height]
    assert_equal [77], big.data.bytes.uniq
  end

  def test_perspective_matches_qr_test_helper_warp
    w = @image.width
    identity = Distort.perspective(@image, [[0, 0], [w, 0], [w, w], [0, w]], w, w)
    assert_equal @image.data, identity.data
    corners = [[20, 30], [190, 12], [215, 205], [8, 170]]
    ours = Distort.perspective(@image, corners, 240, 220, supersample: 2)
    theirs = QrTestHelper.warp(@image, corners, 240, 220)
    assert_operator max_diff(ours, theirs), :<=, 1
    assert_operator max_diff(Distort.rotate(@image, 27), QrTestHelper.rotate(@image, 27)), :<=, 1
    # A strongly converging quad puts the horizon inside the canvas.
    horizon = Distort.perspective(@image, [[0, 0], [60, 0], [300, 300], [0, 60]], 320, 320)
    assert_equal 255, horizon[319, 0]
  end

  def test_perspective_tilt_is_seeded
    a = Distort.perspective_tilt(@image, strength: 0.2, seed: 1)
    assert_equal [@image.width, @image.height], [a.width, a.height]
    assert_equal a.data, Distort.perspective_tilt(@image, strength: 0.2, seed: 1).data
    refute_equal a.data, Distort.perspective_tilt(@image, strength: 0.2, seed: 2).data
  end

  def test_lens_distortions
    img = ramp(60, 40)
    assert_equal img.data, Distort.barrel(img, k: 0.0).data
    assert_operator max_diff(img, Distort.cylinder(img, arc: 1, bulge: 0)), :<=, 1
    barrel = Distort.barrel(@image, k: 0.2)
    # Barrel distortion pulls the corners inwards: the quiet zone grows there.
    assert_equal 255, barrel[18, 18]
    assert_equal 0, @image[18, 18]
    cyl = Distort.cylinder(@image, arc: 150)
    assert_equal 255, cyl[2, cyl.height / 2] # compressed edges leave background
    assert_equal @image[@image.width / 2, 20], cyl[@image.width / 2, 20]
  end

  def test_pad_and_compose
    padded = Distort.pad(gray(3, 2, 0), 2, value: 255)
    assert_equal [7, 6], [padded.width, padded.height]
    assert_equal 6, padded.data.count("\0")
    canvas = Distort.compose(20, 10, [[gray(3, 3, 0), 1, 1], [gray(2, 2, 100), 15, 6]])
    assert_equal 0, canvas[3, 3]
    assert_equal 100, canvas[16, 7]
    assert_equal 255, canvas[10, 5]
    assert_raises(ArgumentError) { Distort.compose(5, 5, [[gray(3, 3, 0), 4, 0]]) }
  end

  def test_apply_chains_steps_with_derived_seeds
    steps = [[:gradient, { to: 0.5 }], [:blur, 1.0], :gaussian_noise, [:scale, 0.5]]
    expected = Distort.scale(Distort.gaussian_noise(Distort.blur(Distort.gradient(@image, to: 0.5), 1.0), seed: 9), 0.5)
    assert_equal expected.data, Distort.apply(@image, steps, seed: 7).data
  end

  def test_jpeg_round_trip
    skip "ImageMagick not available" unless Distort.jpeg_available?

    bytes = Distort.jpeg_bytes(@image, quality: 80)
    assert_equal "\xFF\xD8".b, bytes.byteslice(0, 2)
    assert_equal "\xFF\xD8".b, Distort.jpeg_bytes(@image, quality: 50, color: true, progressive: true).byteslice(0, 2)
    back = Distort.jpeg(@image, quality: 90)
    assert_equal [@image.width, @image.height], [back.width, back.height]
    assert_operator (mean(back) - mean(@image)).abs, :<, 2
    low = Distort.jpeg(@image, quality: 10, color: true)
    refute_equal back.data, low.data
  end

  # Moderate settings of every distortion keep the symbol readable for an
  # independent decoder, so the synthetic benchmark measures something real.
  def test_moderate_distortions_stay_readable_for_zxing_cpp
    skip "zxing-cpp reference venv not available" unless QrReference.available?

    img = @symbol.to_image(module_size: 6)
    variants = {
      "contrast" => Distort.contrast(img, low: 70, high: 180),
      "gradient" => Distort.gradient(img, from: 1.0, to: 0.35, angle: 40),
      "vignette" => Distort.vignette(img, strength: 0.6),
      "shadow" => Distort.shadow(img, darkness: 0.4, softness: 0.2, seed: 2),
      "noise" => Distort.gaussian_noise(img, sigma: 25, seed: 3),
      "salt_pepper" => Distort.salt_pepper(img, amount: 0.01, seed: 3),
      "blur" => Distort.blur(img, 2.0),
      "motion" => Distort.motion_blur(img, length: 7, angle: 20),
      "tilt" => Distort.perspective_tilt(img, strength: 0.2, seed: 5),
      "rotate" => Distort.rotate(img, 33),
      "cylinder" => Distort.cylinder(img, arc: 100),
      "barrel" => Distort.barrel(img, k: 0.15),
      "scale" => Distort.scale(img, 0.3),
      "inverted" => Distort.invert(img),
      "mirrored" => Distort.mirror(img)
    }
    variants["jpeg"] = Distort.jpeg(img, quality: 25, color: true) if Distort.jpeg_available?
    Dir.mktmpdir do |dir|
      paths = variants.map do |name, image|
        path = File.join(dir, "#{name}.png")
        QrTestHelper.write_png(image, path)
        path
      end
      QrReference.decode(paths).zip(variants.keys).each do |result, name|
        assert_equal ["DISTORT 0123456789"], result["results"].map { |r| r["text"] }, name
      end
    end
  end
end
