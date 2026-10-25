#!/usr/bin/env python3
import hashlib
import json
import tempfile
from argparse import Namespace
import unittest
from pathlib import Path
import numpy as np
from PIL import Image
from composite_previews import Composite, Images, coverage, key, latitude, reproject, watch


class CompositeTests(unittest.TestCase):
    def test_reprojection_uses_inverse_mercator(self):
        page = (5, 15, 6)
        north, south = float(latitude(6 / 32)), float(latitude(7 / 32))
        bounds = dict(minLongitude=-11.25, maxLongitude=0, minLatitude=south, maxLatitude=north)
        gradient = np.repeat(np.linspace(0, 255, 1024, dtype=np.uint8)[:, None, None], 1024, axis=1)
        image = Image.fromarray(np.repeat(gradient, 3, axis=2))
        result, mask = reproject(image, bounds, page)
        for y in [64, 256, 448]:
            actual_lat = float(latitude((6 + (y + .5) / 512) / 32))
            expected = (north - actual_lat) / (north - south) * 255
            self.assertLess(abs(np.asarray(result)[y, 256, 0] - expected), 2)
        self.assertEqual(np.asarray(mask).min(), 255)
        self.assertEqual(coverage(bounds, 5), {page})

    def test_sparse_mask_resume_change_and_removal(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            base, previews, world, output = [root / p for p in ("base", "previews", "world", "output")]
            for folder in (base, previews, world): folder.mkdir()
            Image.new("RGB", (256, 256), (50, 90, 130)).save(base / "z5-x15-y10.jpg", quality=100)
            base_bytes = (base / "z5-x15-y10.jpg").read_bytes()
            (base / "index.json").write_text(json.dumps(dict(schemaVersion=1, minZoom=5, maxZoom=5, tileSize=256, tiles=["z5-x15-y10.jpg"])))
            north, south = float(latitude(20 / 64)), float(latitude(21 / 64))
            bounds = dict(minLongitude=-5.625, maxLongitude=0, minLatitude=south, maxLatitude=north)
            valid = dict(bounds); valid["minLatitude"] = (north + south) / 2
            manifest = world / "world.json"
            manifest.write_text(json.dumps(dict(tiles=[dict(mesh=dict(bounds=valid))])))
            image = Image.new("RGB", (512, 512), (255, 255, 255))
            image.paste((190, 40, 30), (0, 0, 512, 256))
            image.save(previews / "preview.jpg", quality=95)
            item = dict(id="test", file="preview.jpg", bounds=bounds, sourcePath="world.json",
                        sourceManifestSHA256=hashlib.sha256(manifest.read_bytes()).hexdigest(),
                        sha256=hashlib.sha256((previews / "preview.jpg").read_bytes()).hexdigest())
            catalog = previews / "catalog.json"
            catalog.write_text(json.dumps(dict(previews=[item])))
            report = Composite(base, catalog, output, world, 7).run()
            self.assertGreater(len(report["changedPages"]), 0)
            top = np.asarray(Image.open(output / "z7-x62-y40.jpg"))
            bottom = np.asarray(Image.open(output / "z7-x62-y41.jpg"))
            self.assertGreater(top[64, 64, 0], 150)
            self.assertLess(bottom.max(), 220, "JPEG matte in holes must never replace the base")
            first = (output / "z7-x62-y40.jpg").read_bytes()
            self.assertEqual(Composite(base, catalog, output, world, 7).run()["changedPages"], [])
            image.paste((20, 180, 30), (0, 0, 512, 256)); image.save(previews / "preview.jpg", quality=95)
            item["sha256"] = hashlib.sha256((previews / "preview.jpg").read_bytes()).hexdigest()
            catalog.write_text(json.dumps(dict(previews=[item])))
            changed = Composite(base, catalog, output, world, 7).run()
            self.assertGreater(len(changed["changedPages"]), 0)
            self.assertNotEqual((output / "z7-x62-y40.jpg").read_bytes(), first)
            catalog.write_text(json.dumps(dict(previews=[])))
            empty = Composite(base, catalog, output, world, 7).run()
            self.assertEqual(empty["pages"], 1)
            self.assertFalse((output / "z7-x62-y40.jpg").exists())
            self.assertEqual((base / "z5-x15-y10.jpg").read_bytes(), base_bytes, "Base is immutable")
            args = Namespace(base=base, catalog=catalog, output=output, world_root=world, max_zoom=7,
                             watch_hours=1, reserve_gib=0, poll_seconds=1)
            (previews / "status.json").write_text(json.dumps(dict(state="complete")))
            watch(args)
            self.assertEqual(json.loads((output / "composite-status.json").read_bytes())["state"], "complete")
            args.reserve_gib = 1_000_000
            watch(args)
            self.assertEqual(json.loads((output / "composite-status.json").read_bytes())["state"], "paused-low-disk")
            args.reserve_gib = 0; args.watch_hours = 0
            watch(args)
            self.assertEqual(json.loads((output / "composite-status.json").read_bytes())["state"], "paused-time-limit")

    def test_image_cache_is_bounded(self):
        with tempfile.TemporaryDirectory() as temporary:
            cache = Images()
            for i in range(12):
                path = Path(temporary) / f"{i}.jpg"
                Image.new("RGB", (8, 8)).save(path)
                cache.get(path)
                self.assertLessEqual(len(cache.cache), 8)


if __name__ == "__main__": unittest.main()
