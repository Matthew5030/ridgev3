#!/usr/bin/env python3
"""Small analytic terrain and semantic archives exercise the real overview path.

No external drive, iCloud files, network, or national dataset is required.
"""
import json
import math
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile
import zlib

import numpy as np
from PIL import Image

from build import Builder, key, mercator, sha
import texture_overview as renderer


def latitude(y):
    return math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * y / 1024))))


def position(x, y):
    return [x / 1024 * 360 - 180, latitude(y)]


def bounds(x, y):
    return dict(minLongitude=position(x, y)[0], maxLongitude=position(x + 1, y)[0],
                maxLatitude=latitude(y), minLatitude=latitude(y + 1))


def rectangle(x0, y0, x1, y1):
    return [position(x0, y0), position(x1, y0), position(x1, y1),
            position(x0, y1), position(x0, y0)]


class OverviewTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.background = self.root / 'background.json'
        entries = []
        for y in (333, 334):
            for x in (500, 501):
                # Eastward analytic ramp, identical native samples at joins.
                h = np.tile(np.arange(513) + (x - 500) * 512 + 1000, (513, 1)).astype('<i2')
                raw = h.tobytes()
                compressed = zlib.compress(raw)
                name = f'z10-x{x}-y{y}.height.zlib'
                (self.root / name).write_bytes(compressed)
                entries.append(dict(id=f'z10-x{x}-y{y}', path=name, bounds=bounds(x, y),
                                    byteCount=len(compressed), sha256=sha(compressed), decodedSHA256=sha(raw)))
        self.background.write_text(json.dumps(dict(partitions=entries)))
        self.atlas = self.root / 'atlas.json'
        self.atlas.write_text(json.dumps(dict(land=[[[-10, 49], [2, 49], [2, 61], [-10, 61], [-10, 49]]])))
        self.style = self.root / 'style.swift'
        self.style.write_text('0xede9d9 0xa8cbd1')
        self.base = self.root / 'base'
        self.base.mkdir()
        self.base.joinpath('index.json').write_text(json.dumps(dict(minZoom=10, maxZoom=10, tiles=[], sources=[])))
        self.archives = self.root / 'archives'
        self.descriptor = self.archives / 'tiles/10/500/333/descriptor.json'
        self.descriptor.parent.mkdir(parents=True)
        self.archive = self.descriptor.with_name('fixture.ridgetile')
        self.data = dict(coordinateReferenceSystem='EPSG:4326', bounds=bounds(500, 333), features=[
            dict(kind='woodland', source={'tags': {'natural': 'wood'}},
                 geometry=dict(type='Polygon', coordinates=[rectangle(500.1, 333.1, 500.4, 333.4)])),
            dict(kind='water', source={'tags': {'natural': 'water'}},
                 geometry=dict(type='Polygon', coordinates=[rectangle(500.6, 333.6, 500.9, 333.9)]))])
        self.write_archive()

    def tearDown(self):
        self.temporary.cleanup()

    def write_archive(self, data=None, bad_map_checksum=False):
        raw = json.dumps(self.data if data is None else data, separators=(',', ':')).encode()
        identity = dict(tileID='z10-x500-y333', tileVersion='fixture-v1', bounds=bounds(500, 333),
                        datasetRevision='fixture', x=500, y=333, z=10)
        manifest = dict(identity, files=[dict(path='map-data.ridgemap', sizeBytes=len(raw),
                                             sha256='0' * 64 if bad_map_checksum else sha(raw))])
        with zipfile.ZipFile(self.archive, 'w', compression=zipfile.ZIP_STORED) as archive:
            archive.writestr('manifest.json', json.dumps(manifest))
            archive.writestr('map-data.ridgemap', raw)
        descriptor = dict(identity, archiveURL='/tiles/10/500/333/fixture.ridgetile',
                          archiveSizeBytes=self.archive.stat().st_size, archiveSHA256=sha(self.archive.read_bytes()))
        self.descriptor.write_text(json.dumps(descriptor))

    def textures(self):
        return renderer.Textures(self.base, self.background, self.atlas, self.style,
                                 self.archives, self.root / 'output')

    def test_polygon_hole_preserves_existing_pixels_and_mask(self):
        image = Image.new('RGB', (40, 40), (17, 35, 63))
        original = np.asarray(image).copy()
        rings = [[(3, 3), (36, 3), (36, 36), (3, 36)], [(13, 13), (26, 13), (26, 26), (13, 26)]]
        renderer.polygon(image, rings, (180, 210, 220))
        np.testing.assert_array_equal(np.asarray(image)[15:25, 15:25], original[15:25, 15:25])
        self.assertEqual(image.getpixel((7, 7)), (180, 210, 220))
        self.assertEqual(image.getpixel((0, 0)), (17, 35, 63))
        mask = Image.new('L', (40, 40), 0)
        renderer.polygon(mask, rings, 255)
        self.assertEqual(mask.getpixel((7, 7)), 255)
        self.assertEqual(mask.getpixel((20, 20)), 0)

    def test_global_sample_registration_and_neighbour_gutters_at_three_sizes(self):
        out = self.root / 'sample'
        out.mkdir()
        builder = Builder(self.background, self.atlas, self.style, out)
        for size, gutter in [(64, 2), (256, 4), (1024, 7)]:
            with self.subTest(size=size, gutter=gutter):
                left = builder.sample(500, 333, size, gutter)
                right = builder.sample(501, 333, size, gutter)
                below = builder.sample(500, 334, size, gutter)
                px, py = mercator(left[2], left[3], 10)
                axis = (np.arange(size + gutter * 2) - gutter + .5) / size
                xx, yy = np.meshgrid(500 + axis, 333 + axis)
                np.testing.assert_allclose(px, xx, atol=1e-11, rtol=0)
                np.testing.assert_allclose(py, yy, atol=1e-11, rtol=0)
                for index in range(4):
                    np.testing.assert_allclose(left[index][:, size:], right[index][:, :gutter * 2], atol=1e-10, rtol=0)
                    np.testing.assert_allclose(left[index][size:, :], below[index][:gutter * 2, :], atol=1e-10, rtol=0)

    def test_semantic_fill_is_registered_in_expected_geographic_quadrant(self):
        textures = self.textures()
        with patch.object(renderer, 'SIDE', 128):
            image = textures.render(500, 333, self.data)
        self.assertEqual(image.size, (128, 128))
        forest = image.getpixel((32, 32))
        water = image.getpixel((96, 96))
        background = image.getpixel((96, 32))
        self.assertGreater(forest[1] - forest[0], 8, 'Woodland lost or drawn in wrong quadrant')
        self.assertGreater(water[2] - water[0], 20, 'Water lost or drawn in wrong quadrant')
        self.assertGreater(background[0], background[2], 'Unexpected fill in unpainted quadrant')

    def test_clipped_woodland_has_no_colour_seam_between_sections(self):
        textures = self.textures()
        def woodland(x, y):
            # Each original archive ends exactly at its own geographic edge.
            return dict(features=[dict(kind='woodland', source={'tags': {'natural': 'wood'}},
                                       geometry=dict(type='Polygon', coordinates=[rectangle(x, y, x + 1, y + 1)]))])
        for size in (64, 128, 512):
            with self.subTest(size=size), patch.object(renderer, 'SIDE', size):
                left = np.asarray(textures.render(500, 333, woodland(500, 333))).astype(int)
                right = np.asarray(textures.render(501, 333, woodland(501, 333))).astype(int)
                below = np.asarray(textures.render(500, 334, woodland(500, 334))).astype(int)
                middle = slice(size // 4, size * 3 // 4)
                # Avoid outer fixture corners, where actual neighbouring DEM
                # coverage ends. A one-level tolerance allows integer shading.
                self.assertLessEqual(np.abs(left[middle, -1] - right[middle, 0]).max(), 1)
                self.assertLessEqual(np.abs(left[-1, middle] - below[0, middle]).max(), 1)
                self.assertLessEqual(np.abs(left[middle, -1] - left[middle, -3]).max(), 1)
                self.assertLessEqual(np.abs(right[middle, 0] - right[middle, 2]).max(), 1)

    def test_source_tagged_wetland_stays_land_coloured_beside_real_lake(self):
        textures = self.textures()
        data = dict(features=[
            dict(kind='water', source={'tags': {'natural': 'wetland', 'wetland': 'bog'}},
                 geometry=dict(type='Polygon', coordinates=[rectangle(500.1, 333.1, 500.4, 333.4)])),
            dict(kind='water', source={'tags': {'natural': 'water', 'water': 'lake'}},
                 geometry=dict(type='Polygon', coordinates=[rectangle(500.6, 333.6, 500.9, 333.9)]))])
        with patch.object(renderer, 'SIDE', 128):
            image = textures.render(500, 333, data)
        bog = image.getpixel((32, 32))
        lake = image.getpixel((96, 96))
        self.assertGreater(bog[0] - bog[2], 5, 'A source-tagged bog was painted as blue open water')
        self.assertGreater(bog[1], bog[0], 'Wetland should retain its muted green map fill')
        self.assertGreater(lake[2] - lake[0], 20, 'Correcting wetlands also removed the real lake fill')

    def test_source_map_checksum_and_descriptor_mismatches_are_rejected(self):
        _, data, checksum = renderer.read_map(self.archives, self.descriptor)
        self.assertEqual(data, self.data)
        self.assertEqual(len(checksum), 64)
        self.write_archive(bad_map_checksum=True)
        with self.assertRaisesRegex(ValueError, 'checksum'):
            renderer.read_map(self.archives, self.descriptor)
        self.write_archive()
        metadata = json.loads(self.descriptor.read_text())
        metadata['tileVersion'] = 'different-version'
        self.descriptor.write_text(json.dumps(metadata))
        with self.assertRaisesRegex(ValueError, 'Descriptor mismatch'):
            renderer.read_map(self.archives, self.descriptor)

    def test_source_coordinate_mismatch_is_rejected(self):
        damaged = dict(self.data, coordinateReferenceSystem='EPSG:3857')
        self.write_archive(damaged)
        with self.assertRaisesRegex(ValueError, 'coordinates'):
            renderer.read_map(self.archives, self.descriptor)

    def test_section_resume_and_corrupt_page_repair(self):
        textures = self.textures()
        with patch.object(renderer, 'SIDE', 128):
            record = textures.section(self.descriptor)
            self.assertEqual(len(record['pages']), 21)
            for name, digest in record['pages'].items():
                path = textures.output / name
                self.assertEqual(sha(path.read_bytes()), digest)
                with Image.open(path) as image:
                    self.assertEqual(image.size, (256, 256))
            with patch.object(textures, 'render', side_effect=AssertionError('Unchanged resume rendered again')):
                self.assertEqual(textures.section(self.descriptor), record)
            corrupt = textures.output / key(12, 2000, 1332)
            original = corrupt.read_bytes()
            corrupt.write_bytes(b'incomplete page')
            self.assertEqual(textures.section(self.descriptor), record)
            self.assertEqual(corrupt.read_bytes(), original)
            corrupt.unlink()
            textures.section(self.descriptor)
            self.assertEqual(corrupt.read_bytes(), original)
            metadata = json.loads(self.descriptor.read_text())
            metadata['tileVersion'] = 'changed'
            self.descriptor.write_text(json.dumps(metadata))
            with self.assertRaisesRegex(ValueError, 'Source changed'):
                textures.section(self.descriptor)


if __name__ == '__main__':
    unittest.main()
