#!/usr/bin/env python3
"""Verify native Metal readbacks against source pixels and ASTC CPU reference."""
import json
import sys
from pathlib import Path
import numpy as np
from PIL import Image

root = Path(sys.argv[1])
results = {}
for actual, reference, exact in [
    ('map-hd.png', 'hd-0.png', True),
    ('map-astc.png', 'astc-reference.png', True),
    ('close-hd.png', 'close-astc.png', False),
]:
    a = np.asarray(Image.open(root / actual).convert('RGB'), dtype=np.float32)
    b = np.asarray(Image.open(root / reference).convert('RGB'), dtype=np.float32)
    assert a.shape == b.shape
    delta = np.abs(a-b)
    results[f'{actual} vs {reference}'] = dict(
        meanAbsoluteChannelError=float(delta.mean()),
        maxChannelError=float(delta.max()),
        pixelsOver16Percent=float(np.mean(delta.max(axis=2)>16)*100),
    )
    if exact:
        assert np.array_equal(a, b), f'GPU readback differs from reference: {actual}'
    else:
        assert delta.max() <= 16, 'Visible compression error threshold exceeded'
(root / 'verification.json').write_text(json.dumps(results, indent=2)+'\n')
print(json.dumps(results, indent=2))
