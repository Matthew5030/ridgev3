"""Refresh offline settlement labels from the same UK OSM extract as the maps.

Usage: python3 Tools/build_atlas_places.py UK.osm.pbf
Requires osmium-tool. Only named city/town/village nodes are retained; no network
service is needed by the app. OSM attribution is already shown on the atlas.
"""
import argparse
import json
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path


def settlements(path):
    result = []
    for _, node in ET.iterparse(path, events=("end",)):
        if node.tag != "node":
            continue
        tags = {tag.attrib["k"]: tag.attrib["v"] for tag in node.findall("tag")}
        name, kind = tags.get("name", "").strip(), tags.get("place")
        if name and kind in ("city", "town", "village"):
            population = re.sub(r"[,\s]", "", tags.get("population", ""))
            result.append((int(population) if population.isdigit() else 0, dict(
                id="osm:node:" + node.attrib["id"], name=name, kind=kind,
                coordinate=dict(latitude=round(float(node.attrib["lat"]), 7),
                                longitude=round(float(node.attrib["lon"]), 7)))))
        node.clear()
    # Stable priority avoids labels changing order during camera movement.
    result.sort(key=lambda item: (("city", "town", "village").index(item[1]["kind"]),
                                  -item[0], item[1]["name"], item[1]["id"]))
    return [place for _, place in result]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--atlas", type=Path, default=Path(__file__).resolve().parents[1] /
                        "ridge v3/Resources/RidgeData.bundle/atlas.json")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as temp:
        filtered = Path(temp) / "places.osm"
        subprocess.run(["osmium", "tags-filter", "--omit-referenced", str(args.source),
                        "n/place=city,town,village", "-f", "osm", "-o", str(filtered)], check=True)
        places = settlements(filtered)
    if len(places) < 1000:
        raise SystemExit("Expected a complete UK extract; leaving the atlas unchanged.")
    atlas = json.loads(args.atlas.read_text())
    atlas["places"] = places + [p for p in atlas["places"]
                               if p["kind"] not in ("settlement", "city", "town", "village")]
    args.atlas.write_text(json.dumps(atlas, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"Bundled {len(places):,} OSM settlements from {args.source.name}")
