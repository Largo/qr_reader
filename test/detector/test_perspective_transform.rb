# frozen_string_literal: true

require_relative "detector_test_helper"

class TestPerspectiveTransform < Minitest::Test
  PT = QrReader::Detector::PerspectiveTransform
  UNIT = [[0, 0], [1, 0], [1, 1], [0, 1]].freeze

  def assert_maps(t, from, to, delta = 1e-6)
    from.zip(to).each do |(x, y), (u, v)|
      px, py = t.apply(x, y)
      assert_in_delta u, px, delta
      assert_in_delta v, py, delta
    end
  end

  def test_square_to_quad_affine_and_projective
    parallelogram = [[10, 20], [110, 30], [120, 130], [20, 120]]
    assert_maps PT.square_to_quad(parallelogram), UNIT, parallelogram
    quad = [[10, 20], [110, 5], [140, 150], [0, 100]]
    assert_maps PT.square_to_quad(quad), UNIT, quad
  end

  def test_quad_to_quad
    src = [[3.5, 3.5], [21.5, 3.5], [18.5, 18.5], [3.5, 21.5]]
    dst = [[40.2, 50.1], [200.7, 70.3], [170.0, 190.4], [30.5, 210.9]]
    t = PT.quad_to_quad(src, dst)
    assert_maps t, src, dst, 1e-6
    # Lines stay lines: the midpoint of an edge maps onto the image edge.
    mx, my = t.apply(12.5, 3.5)
    cross = (dst[1][0] - dst[0][0]) * (my - dst[0][1]) - (dst[1][1] - dst[0][1]) * (mx - dst[0][0])
    assert_in_delta 0, cross, 1e-6
  end

  def test_adjoint_inverts
    t = PT.square_to_quad([[10, 20], [110, 5], [140, 150], [0, 100]])
    inverse = t.adjoint
    [[0.25, 0.5], [0.9, 0.1]].each do |x, y|
      u, v = t.apply(x, y)
      bx, by = inverse.apply(u, v)
      assert_in_delta x, bx, 1e-9
      assert_in_delta y, by, 1e-9
    end
  end

  def test_degenerate_quads
    assert_nil PT.square_to_quad([[0, 0], [10, 0], [20, 0], [30, 0]])
    assert_nil PT.quad_to_quad(UNIT, [[5, 5], [5, 5], [5, 5], [5, 5]])
  end

  def test_regular_over
    t = PT.square_to_quad([[0, 0], [100, 0], [100, 100], [0, 100]])
    assert t.regular_over?(0, 0, 1, 1)
    # A strongly converging quad puts the horizon inside a larger area.
    steep = PT.square_to_quad([[0, 0], [100, 0], [60, 10], [40, 10]])
    refute steep.regular_over?(-5, -5, 5, 5)
  end

  def test_apply_returns_nil_at_infinity
    m = PT.new([1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 1.0, 0.0, 0.0])
    assert_nil m.apply(0.0, 3.0)
  end
end
