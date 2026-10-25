import unittest
from terrain_coverage import missing_terrain


class CoverageTests(unittest.TestCase):
    def manifest(self, present, columns=4, rows=4):
        return dict(columns=columns, rows=rows,
                    bounds=dict(minLongitude=0, maxLongitude=columns, minLatitude=0, maxLatitude=rows),
                    tiles=[dict(column=x, row=y) for x, y in present])

    def test_complete_grid_has_no_gaps(self):
        self.assertEqual(missing_terrain(self.manifest([(x, y) for y in range(4) for x in range(4)])), [])

    def test_missing_cells_are_covered_once_without_covering_real_terrain(self):
        present = {(0, 0), (1, 0), (1, 1), (2, 2), (3, 3)}
        gaps = missing_terrain(self.manifest(present))
        for y in range(4):
            for x in range(4):
                lon, lat = x + .5, 4 - y - .5
                count = sum(b['minLongitude'] < lon < b['maxLongitude'] and
                            b['minLatitude'] < lat < b['maxLatitude'] for b in gaps)
                self.assertEqual(count, 0 if (x, y) in present else 1)

    def test_adjacent_ocean_rows_merge(self):
        gaps = missing_terrain(self.manifest([(x, y) for y in range(2) for x in range(4)]))
        self.assertEqual(gaps, [dict(minLongitude=0, maxLongitude=4, minLatitude=0, maxLatitude=2)])

    def test_bad_grid_is_rejected(self):
        for present in [[(4, 0)], [(0, 0), (0, 0)]]:
            with self.assertRaises(ValueError):
                missing_terrain(self.manifest(present))


if __name__ == '__main__':
    unittest.main()
