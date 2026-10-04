#!/usr/bin/env python3
"""Incrementally project exact terrain previews onto the offline XYZ overview.

Inputs are read-only. Publish a sparse z11..13 overlay plus updated ancestors;
only a small image LRU is held in memory. A committed index is always published
last, so interruption can leave unused pages but never advertised missing files.
"""
import argparse
import fcntl
import time
import hashlib
import json
import math
import os
import re
import shutil
from collections import OrderedDict
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

SIZE = 256
VERSION = 1
KEY = re.compile(r"z(\d+)-x(\d+)-y(\d+)\.jpg$")


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def atomic_json(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, separators=(",", ":")) + "\n")
    temporary.replace(path)


def key(page):
    z, x, y = page
    return f"z{z}-x{x}-y{y}.jpg"


def parse(name):
    match = KEY.fullmatch(name)
    if not match:
        raise ValueError(f"Unsafe page name: {name}")
    return tuple(map(int, match.groups()))


def xy(lon, lat, z):
    return ((lon + 180) / 360 * 2**z,
            (1 - math.asinh(math.tan(math.radians(max(-85, min(85, lat))))) / math.pi) / 2 * 2**z)


def latitude(world_y):
    return np.degrees(np.arctan(np.sinh(math.pi * (1 - 2 * np.asarray(world_y)))))


def coverage(bounds, z):
    left, top = xy(bounds["minLongitude"], bounds["maxLatitude"], z)
    right, bottom = xy(bounds["maxLongitude"], bounds["minLatitude"], z)
    # A boundary on an exact XYZ edge must not create a one-pixel neighbour.
    return {(z, x, y) for y in range(math.floor(top + 1e-9), math.ceil(bottom - 1e-9))
            for x in range(math.floor(left + 1e-9), math.ceil(right - 1e-9))}


def parents(pages, min_zoom):
    current = set(pages)
    result = set()
    while current and next(iter(current))[0] > min_zoom:
        current = {(z - 1, x // 2, y // 2) for z, x, y in current}
        result.update(current)
    return result


class Images:
    def __init__(self):
        self.cache = OrderedDict()

    def get(self, path):
        path = str(path)
        if path not in self.cache:
            with Image.open(path) as source:
                self.cache[path] = source.convert("RGB")
        self.cache.move_to_end(path)
        while len(self.cache) > 8:
            self.cache.popitem(last=False)
        return self.cache[path]

    def mask(self, preview, size):
        cache_key = "mask:" + preview["sourceManifestSHA256"]
        if cache_key not in self.cache:
            mask = Image.new("L", size, 0)
            draw = ImageDraw.Draw(mask)
            b = preview["bounds"]
            for tile in preview["validTiles"]:
                left = round((tile["minLongitude"] - b["minLongitude"]) / (b["maxLongitude"] - b["minLongitude"]) * size[0])
                right = round((tile["maxLongitude"] - b["minLongitude"]) / (b["maxLongitude"] - b["minLongitude"]) * size[0])
                top = round((b["maxLatitude"] - tile["maxLatitude"]) / (b["maxLatitude"] - b["minLatitude"]) * size[1])
                bottom = round((b["maxLatitude"] - tile["minLatitude"]) / (b["maxLatitude"] - b["minLatitude"]) * size[1])
                draw.rectangle((left, top, right - 1, bottom - 1), fill=255)
            # Erode the union, not every tile: interior terrain stays seamless.
            self.cache[cache_key] = mask.filter(ImageFilter.MinFilter(5))
        self.cache.move_to_end(cache_key)
        while len(self.cache) > 8:
            self.cache.popitem(last=False)
        return self.cache[cache_key]

    def invalidate(self, path):
        self.cache.pop(str(path), None)


def reproject(image, bounds, page, valid_mask=None):
    """Use actual inverse-Mercator latitude, not a linear XYZ latitude shortcut.

    32px mesh cells and 2x supersampling retain crisp lines while downsampling a
    2048px orthographic preview into the 256px geographical tile grid.
    """
    z, x, y = page
    side = SIZE * 2
    n = 2**z
    mesh = []

    def source(px, py):
        lon = (x + px / side) / n * 360 - 180
        lat = float(latitude((y + py / side) / n))
        return ((lon - bounds["minLongitude"]) / (bounds["maxLongitude"] - bounds["minLongitude"]) * image.width,
                (bounds["maxLatitude"] - lat) / (bounds["maxLatitude"] - bounds["minLatitude"]) * image.height)

    for top in range(0, side, 32):
        for left in range(0, side, 32):
            right, bottom = left + 32, top + 32
            quad = source(left, top) + source(left, bottom) + source(right, bottom) + source(right, top)
            mesh.append(((left, top, right, bottom), quad))
    projected = image.transform((side, side), Image.Transform.MESH, mesh, Image.Resampling.BICUBIC)
    # Pixel-centre mask: out-of-preview transform pixels must not darken the
    # existing low-resolution geography around partial coverage.
    lon = ((x + (np.arange(side) + .5) / side) / n * 360 - 180)[None, :]
    lat = latitude((y + (np.arange(side) + .5) / side) / n)[:, None]
    mask = ((lon >= bounds["minLongitude"]) & (lon < bounds["maxLongitude"]) &
            (lat <= bounds["maxLatitude"]) & (lat > bounds["minLatitude"]))
    if valid_mask is not None:
        projected_mask = valid_mask.transform((side, side), Image.Transform.MESH, mesh, Image.Resampling.NEAREST)
        mask &= np.asarray(projected_mask) > 0
    return projected, Image.fromarray(mask.astype(np.uint8) * 255)


class PauseBuild(RuntimeError):
    pass


class Composite:
    def __init__(self, base, catalog, output, world_root, max_zoom=13, reserve_bytes=0, deadline=math.inf):
        self.base, self.catalog_path, self.output = base, catalog, output
        self.max_zoom = max_zoom
        self.reserve_bytes, self.deadline = reserve_bytes, deadline
        self.base_index = json.loads((base / "index.json").read_bytes())
        catalog_bytes = catalog.read_bytes()
        self.catalog = json.loads(catalog_bytes)  # One immutable snapshot per run.
        self.catalog_sha = hashlib.sha256(catalog_bytes).hexdigest()
        self.base_pages = set(self.base_index["tiles"])
        self.min_zoom = self.base_index["minZoom"]
        if max_zoom <= self.base_index["maxZoom"]:
            raise ValueError("Detail zoom must exceed the base pyramid")
        if base.resolve() == output.resolve():
            raise ValueError("The base atlas is read-only; choose a separate output")
        self.output.mkdir(parents=True, exist_ok=True)
        self.checkpoints = output / "checkpoints"
        self.checkpoints.mkdir(exist_ok=True)
        self.images = Images()
        self.identity = dict(version=VERSION, baseIndex=digest(self.base_index), maxZoom=max_zoom)
        old = output / "composite-inputs.json"
        if old.exists() and json.loads(old.read_bytes()) != self.identity:
            raise ValueError("Base/style changed; use a fresh output revision")
        atomic_json(old, self.identity)
        atomic_json(output / "preview-catalog-snapshot.json", self.catalog)
        self.changed = []
        self.preview_by_page = {}
        self.previews = sorted(self.catalog["previews"], key=lambda p: p["id"])
        for preview in self.previews:
            relative = Path(preview["file"])
            if relative.name != str(relative) or relative.is_absolute():
                raise ValueError("Preview filenames must be local flat files")
            image = catalog.parent / relative
            if not image.is_file():
                raise ValueError(f"Missing preview: {image}")
            if hashlib.sha256(image.read_bytes()).hexdigest() != preview["sha256"]:
                raise ValueError(f"Preview hash mismatch: {image}")
            source_path = (world_root / preview["sourcePath"]).resolve()
            if not source_path.is_relative_to(world_root.resolve()):
                raise ValueError("Source manifest is outside world root")
            source_bytes = source_path.read_bytes()
            if hashlib.sha256(source_bytes).hexdigest() != preview["sourceManifestSHA256"]:
                raise ValueError(f"Source manifest hash mismatch: {source_path}")
            source = json.loads(source_bytes)
            preview["validTiles"] = [tile["mesh"]["bounds"] for tile in source["tiles"]]
            for page in coverage(preview["bounds"], max_zoom):
                self.preview_by_page.setdefault(page, []).append(preview)

    def fallback(self, page):
        z, x, y = page
        candidate = page
        while key(candidate) not in self.base_pages:
            cz, cx, cy = candidate
            if cz <= self.min_zoom:
                raise ValueError(f"No base coverage below {key(page)}")
            candidate = cz - 1, cx // 2, cy // 2
        image = self.images.get(self.base / key(candidate))
        factor = 2**(z - candidate[0])
        left, top = x % factor * SIZE / factor, y % factor * SIZE / factor
        return image.transform((SIZE, SIZE), Image.Transform.EXTENT,
                               (left, top, left + SIZE / factor, top + SIZE / factor), Image.Resampling.BICUBIC)

    def fingerprint(self, page):
        checkpoint = self.checkpoints / (key(page) + ".json")
        if checkpoint.exists():
            return json.loads(checkpoint.read_bytes())["fingerprint"]
        return digest(["base", self.identity, key(page)])

    def current(self, page, fingerprint):
        return (self.output / key(page)).exists() and self.fingerprint(page) == fingerprint

    def save(self, page, image, fingerprint):
        if time.monotonic() >= self.deadline:
            raise PauseBuild("paused-time-limit")
        if shutil.disk_usage(self.output).free < self.reserve_bytes:
            raise PauseBuild("paused-low-disk")
        target = self.output / key(page)
        temporary = target.with_suffix(".jpg.tmp")
        image.save(temporary, format="JPEG", quality=91, subsampling=0, optimize=True)
        temporary.replace(target)
        self.images.invalidate(target)
        atomic_json(self.checkpoints / (key(page) + ".json"), dict(fingerprint=fingerprint))
        self.changed.append(key(page))

    def run(self):
        for name in sorted(self.base_pages):
            parse(name)
            target = self.output / name
            if not target.exists():
                try:
                    os.link(self.base / name, target)
                except OSError:
                    shutil.copy2(self.base / name, target)
        high = set(self.preview_by_page)
        old_state = self.output / "composite-state.json"
        previous = set(map(parse, json.loads(old_state.read_bytes())["highPages"])) if old_state.exists() else set()
        removed = previous - high
        for page in removed:
            (self.output / key(page)).unlink(missing_ok=True)
            (self.checkpoints / (key(page) + ".json")).unlink(missing_ok=True)
        for page in sorted(high):
            overlaps = self.preview_by_page[page]
            identity = digest([self.identity, key(page), [(p["id"], p["sha256"], p["sourceManifestSHA256"], p["bounds"]) for p in overlaps]])
            if self.current(page, identity):
                continue
            image = self.fallback(page).resize((SIZE * 2, SIZE * 2), Image.Resampling.BICUBIC)
            for preview in overlaps:
                source = self.images.get(self.catalog_path.parent / preview["file"])
                valid = self.images.mask(preview, source.size)
                projected, mask = reproject(source, preview["bounds"], page, valid)
                image.paste(projected, (0, 0), mask)
            self.save(page, image.resize((SIZE, SIZE), Image.Resampling.LANCZOS), identity)
        ancestors = parents(high | removed, self.min_zoom)
        active = high | parents(high, self.min_zoom)
        for page in sorted(ancestors, reverse=True):
            z, x, y = page
            children = [(z + 1, x * 2 + dx, y * 2 + dy) for dy in range(2) for dx in range(2)]
            identity = digest([self.identity, key(page), [(key(p), self.fingerprint(p) if p in active else "fallback") for p in children]])
            if self.current(page, identity):
                continue
            assembled = Image.new("RGB", (SIZE * 2, SIZE * 2))
            for child in children:
                child_image = self.images.get(self.output / key(child)) if child in active else self.fallback(child)
                assembled.paste(child_image, ((child[1] % 2) * SIZE, (child[2] % 2) * SIZE))
            self.save(page, assembled.resize((SIZE, SIZE), Image.Resampling.LANCZOS), identity)
        # Removed detail pages above base zoom must not remain in the inventory.
        for page in ancestors - active:
            if page[0] > self.base_index["maxZoom"]:
                (self.output / key(page)).unlink(missing_ok=True)
                (self.checkpoints / (key(page) + ".json")).unlink(missing_ok=True)
        inventory = sorted(self.base_pages | {key(p) for p in active})
        index = dict(self.base_index)
        index.update(maxZoom=self.max_zoom if high else self.base_index["maxZoom"], tiles=inventory,
                     detailPreviewCount=len(self.previews), detailPreviewIDs=[p["id"] for p in self.previews],
                     detailStyle=self.catalog.get("style", {}), detailCatalogSHA256=self.catalog_sha)
        atomic_json(self.output / "index.json", index)
        atomic_json(old_state, dict(highPages=sorted(map(key, high))))
        report = dict(previews=len(self.previews), pages=len(inventory), changedPages=self.changed,
                      bytes=sum((self.output / name).stat().st_size for name in inventory),
                      decodedImageCacheLimit=8, maxZoom=index["maxZoom"])
        atomic_json(self.output / "composite-report.json", report)
        print(json.dumps({k: v if k != "changedPages" else len(v) for k, v in report.items()}), flush=True)
        return report


def watch(args):
    deadline = time.monotonic() + args.watch_hours * 3600
    last_hash = None
    status_path = args.output / "composite-status.json"
    def status(state, **extra):
        atomic_json(status_path, dict(state=state, pid=os.getpid(), updatedAt=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), **extra))
    while time.monotonic() < deadline:
        if shutil.disk_usage(args.output).free < args.reserve_gib * 1024**3:
            status("paused-low-disk"); return
        try:
            current_hash = hashlib.sha256(args.catalog.read_bytes()).hexdigest()
            if current_hash != last_hash:
                status("compositing")
                compositor = Composite(args.base, args.catalog, args.output, args.world_root, args.max_zoom,
                                       args.reserve_gib * 1024**3, deadline)
                report = compositor.run()
                last_hash = compositor.catalog_sha
                status("waiting-for-previews", previews=report["previews"], pages=report["pages"], bytes=report["bytes"])
            upstream_path = args.catalog.parent / "status.json"
            upstream = json.loads(upstream_path.read_bytes()) if upstream_path.exists() else {}
            if upstream.get("state") in ("complete", "complete-with-errors", "paused-time-limit", "paused-low-disk", "failed"):
                # A completion may have published another catalog during our build.
                if hashlib.sha256(args.catalog.read_bytes()).hexdigest() != last_hash:
                    continue
                status("complete", upstreamState=upstream["state"]); return
        except PauseBuild as error:
            status(str(error)); return
        except Exception as error:
            status("failed", error=str(error)); raise
        time.sleep(min(args.poll_seconds, max(0, deadline - time.monotonic())))
    status("paused-time-limit")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, required=True)
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--world-root", type=Path, required=True)
    parser.add_argument("--max-zoom", type=int, default=13)
    parser.add_argument("--watch-hours", type=float, default=0)
    parser.add_argument("--poll-seconds", type=float, default=30)
    parser.add_argument("--reserve-gib", type=float, default=35)
    args = parser.parse_args()
    if args.watch_hours < 0 or args.poll_seconds < 1 or args.reserve_gib < 0:
        parser.error("Watch duration/reserve must be non-negative; poll interval must be at least one second")
    args.output.mkdir(parents=True, exist_ok=True)
    with (args.output / ".composite.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if args.watch_hours:
            watch(args)
        else:
            Composite(args.base, args.catalog, args.output, args.world_root, args.max_zoom,
                      args.reserve_gib * 1024**3).run()


if __name__ == "__main__":
    main()
