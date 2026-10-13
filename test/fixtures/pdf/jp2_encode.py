"""Encodes a PGM as a lossy JPEG 2000 file (9/7 wavelet, 6 resolutions) with
Pillow/OpenJPEG. Development tool for generate_jpx.rb:

    python -I jp2_encode.py IN.pgm OUT.jp2
"""
import sys

from PIL import Image

Image.open(sys.argv[1]).save(sys.argv[2], irreversible=True, num_resolutions=6,
                             quality_mode="rates", quality_layers=[40])
