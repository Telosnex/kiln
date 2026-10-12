#!/usr/bin/env python3
"""Assert that all eight input files were bundled byte-for-byte (or are absent)."""
import argparse
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--expect-absent', action='store_true')
args = parser.parse_args()
work = Path(__file__).resolve().parent / '.work'
sources = list((work / 'artifacts').iterdir())
assert len(sources) == 8, 'Run prepare.py first'
bundle = work / 'app/build/web/assets/packages/web_payload_probe/web'
for source in sources:
    destination = bundle / source.name
    if args.expect_absent:
        assert not destination.exists(), f'Unexpectedly bundled: {destination}'
    else:
        assert destination.read_bytes() == source.read_bytes(), f'Mismatch: {source.name}'
print('PASS:', 'all eight absent (negative control)' if args.expect_absent else 'all eight bundled byte-for-byte')
