# frozen_string_literal: true

require_relative "decoder_test_helper"

class TestDecoderReedSolomon < Minitest::Test
  RS = QrReader::Decoder::ReedSolomon
  GF = QrReader::Decoder::GaloisField
  Builder = DecoderTestHelper::SymbolBuilder

  # Every [block length, ec codewords] combination used by QR codes.
  SHAPES = (1..40).flat_map do |v|
    %i[L M Q H].flat_map do |level|
      blocks = QrReader::SymbolVersion[v].ec_blocks(level)
      blocks.groups.map { |_, data| [data + blocks.ec_codewords_per_block, blocks.ec_codewords_per_block] }
    end
  end.uniq.freeze

  def codeword(rng, n, ec)
    data = Array.new(n - ec) { rng.rand(256) }
    data + Builder.rs_encode(data, ec)
  end

  def corrupt(block, count, rng)
    positions = (0...block.size).to_a.sample(count, random: rng)
    positions.each { |p| block[p] ^= 1 + rng.rand(255) }
    positions
  end

  def test_field_tables
    assert_equal 1, GF::EXP[0]
    assert_equal 2, GF::EXP[1]
    assert_equal 0x1D, GF::EXP[8]
    1.upto(255) { |a| assert_equal a, GF::EXP[GF::LOG[a]] }
    assert_equal 255, GF::EXP.first(255).uniq.size
    rng = Random.new(1)
    200.times do
      a = rng.rand(1..255)
      b = rng.rand(1..255)
      assert_equal Builder.gf_mul(a, b), GF.multiply(a, b)
      assert_equal a, GF.multiply(GF.divide(a, b), b)
    end
    assert_equal 0, GF.multiply(0, 7)
    assert_equal GF::EXP[254], GF.power(-1)
    30.times { |j| 256.times { |s| assert_equal GF.multiply(s, GF::EXP[j]), GF::MULTIPLY_BY_ALPHA_POWER[j][s] } }
  end

  def test_valid_codewords_have_zero_syndromes
    rng = Random.new(2)
    SHAPES.each do |n, ec|
      block = codeword(rng, n, ec)
      assert_nil RS.syndromes(block, ec)
      original = block.dup
      assert_equal 0, RS.decode(block, ec)
      assert_equal original, block
    end
  end

  def test_both_syndrome_methods_agree
    rng = Random.new(7)
    SHAPES.each do |n, ec|
      clean = codeword(rng, n, ec)
      assert_nil RS.horner_syndromes(clean, ec)
      assert_nil RS.remainder_syndromes(clean, ec)
      3.times do
        block = clean.dup
        corrupt(block, rng.rand(1..n), rng)
        expected = RS.horner_syndromes(block, ec)
        refute_nil expected
        assert_equal expected, RS.remainder_syndromes(block, ec), "n=#{n} ec=#{ec}"
      end
    end
  end

  def test_corrects_up_to_capacity
    rng = Random.new(3)
    SHAPES.each do |n, ec|
      t = ec / 2
      [1, t, rng.rand(1..t)].uniq.each do |errors|
        original = codeword(rng, n, ec)
        block = original.dup
        corrupt(block, errors, rng)
        assert_equal errors, RS.decode(block, ec), "n=#{n} ec=#{ec} errors=#{errors}"
        assert_equal original, block
      end
    end
  end

  def test_beyond_capacity_never_returns_an_invalid_block
    rng = Random.new(4)
    wrong = 0
    SHAPES.each do |n, ec|
      t = ec / 2
      40.times do
        original = codeword(rng, n, ec)
        block = original.dup
        corrupt(block, t + 1 + rng.rand(3), rng)
        received = block.dup
        result = RS.decode(block, ec)
        if result
          # A miscorrection can only land on another valid codeword within t.
          assert_operator result, :<=, t
          assert_nil RS.syndromes(block, ec)
          assert_equal result, block.zip(received).count { |a, b| a != b }
          wrong += 1 if block != original
        else
          assert_equal received, block, "failed decode must not modify the block"
        end
      end
    end
    assert_operator wrong, :<=, 2, "miscorrections should be extremely rare"
  end

  def test_random_garbage_never_raises
    rng = Random.new(5)
    SHAPES.each do |n, ec|
      30.times do
        block = Array.new(n) { rng.rand(256) }
        result = RS.decode(block, ec)
        next unless result

        assert_operator result, :<=, ec / 2
        assert_nil RS.syndromes(block, ec)
      end
    end
  end

  def test_errors_in_ec_part_and_at_block_edges
    rng = Random.new(6)
    original = codeword(rng, 70, 26)
    [[0], [69], [0, 69], [44, 45, 46], (57..69).to_a].each do |positions|
      block = original.dup
      positions.each { |p| block[p] ^= 0x5A }
      assert_equal positions.size, RS.decode(block, 26)
      assert_equal original, block
    end
  end

  def test_rejects_bad_arguments
    assert_nil RS.decode([1, 2, 3], 0)
    assert_nil RS.decode([1, 2, 3], 3)
    assert_nil RS.decode(Array.new(300, 1), 10)
  end
end
