#!/usr/bin/env python3
"""Audit the committed regional plan without needing the external source drive."""
import json
import unittest
from pathlib import Path

PLAN = Path(__file__).resolve().parents[2] / 'ridge v3/Resources/uk-pack-regions.json'

class RegionalPackTests(unittest.TestCase):
    def test_complete_nonoverlapping_assignment(self):
        plan = json.loads(PLAN.read_text())
        self.assertEqual(plan['schemaVersion'], 1)
        self.assertEqual(plan['status'], 'publication-plan')
        self.assertEqual(len(plan['regions']), 20)
        identifiers = [c['id'] for r in plan['regions'] for c in r['cells']]
        self.assertEqual(len(identifiers), 674)
        self.assertEqual(len(set(identifiers)), len(identifiers))
        self.assertEqual(sum(r['detailedSections'] for r in plan['regions']), 342)
        for region in plan['regions']:
            self.assertTrue(region['cells'])
            self.assertFalse(region['mapPackReady'])
            total = sum(c['background']['byteCount'] +
                        c.get('detail', {}).get('byteCount', 0) +
                        c.get('detail', {}).get('meshBytes', 0) for c in region['cells'])
            self.assertEqual(region['terrainBytes'], total)
            self.assertEqual(region['detailedSections'], sum('detail' in c for c in region['cells']))
            for cell in region['cells']:
                self.assertTrue(cell['background']['path'].startswith('uk-coarse-background-v2/'))
                if 'detail' in cell:
                    self.assertTrue(cell['detail']['path'].startswith('uk-adaptive-0p5-v3/'))

if __name__ == '__main__':
    unittest.main()
