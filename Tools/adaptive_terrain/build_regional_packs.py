#!/usr/bin/env python3
"""Group audited UK storage sections into stable geographic download regions.

This writes a publication plan, not a claim that textures/routes are complete.
Existing immutable geometry is referenced; no LiDAR or textures are rebuilt.
"""
import argparse
import json
import math
from pathlib import Path

REGIONS = [
    ("northern-isles", "Northern Isles", 59.7, -1.9),
    ("north-west-scotland", "North West Scotland", 58.0, -5.7),
    ("north-east-scotland", "North East Scotland", 57.5, -3.1),
    ("central-highlands", "Central Highlands", 56.8, -4.2),
    ("argyll-western-isles", "Argyll & the western islands", 56.2, -6.0),
    ("central-scotland", "Central Scotland", 55.95, -3.9),
    ("southern-scotland", "Southern Scotland", 55.15, -3.6),
    ("northern-ireland", "Northern Ireland", 54.7, -6.8),
    ("north-east-england", "North East England", 55.0, -1.9),
    ("cumbria", "Cumbria & the Lake District", 54.55, -3.0),
    ("dales-north-pennines", "Dales & North Pennines", 54.1, -2.05),
    ("north-east-yorkshire", "North & East Yorkshire", 54.0, -0.8),
    ("peak-district-midlands", "Peak District & the Midlands", 52.85, -1.55),
    ("north-wales", "North Wales", 53.05, -3.85),
    ("mid-south-wales", "Mid & South Wales", 51.95, -4.05),
    ("east-anglia", "East Anglia", 52.4, 0.85),
    ("marches-cotswolds", "Welsh borders & Cotswolds", 52.0, -2.35),
    ("south-east", "South East England", 51.15, 0.25),
    ("central-south", "Hampshire, Dorset & Somerset", 51.0, -2.3),
    ("devon-cornwall", "Devon & Cornwall", 50.6, -4.5),
]


def distance(latitude, longitude, region):
    lat, lon = region[2:]
    return (latitude - lat) ** 2 + ((longitude - lon) * math.cos(math.radians((latitude + lat) / 2))) ** 2


def build(root):
    detail = json.loads((root / "uk-adaptive-0p5-v3/catalog.json").read_text())
    background = json.loads((root / "uk-coarse-background-v2/background.json").read_text())
    assert detail["buildComplete"], "Only use the completed audited terrain build"
    fine = {part["id"]: part for part in detail["partitions"]}
    regions = {r[0]: dict(id=r[0], name=r[1], cells=[], terrainBytes=0,
                         detailedSections=0, mapPackReady=False) for r in REGIONS}
    for part in sorted(background["partitions"], key=lambda p: p["id"]):
        b = part["bounds"]
        seed = min(REGIONS, key=lambda r: distance((b["minLatitude"] + b["maxLatitude"]) / 2,
                                                 (b["minLongitude"] + b["maxLongitude"]) / 2, r))
        region = regions[seed[0]]
        cell = dict(id=part["id"], bounds=b, background=dict(path="uk-coarse-background-v2/" + part["path"],
                    byteCount=part["byteCount"], sha256=part["sha256"]))
        region["terrainBytes"] += part["byteCount"]
        if part["id"] in fine:
            f = fine[part["id"]]
            cell["detail"] = dict(path="uk-adaptive-0p5-v3/" + f["path"], byteCount=f["byteCount"],
                                  sha256=f["sha256"], meshBytes=f["meshBytes"])
            region["terrainBytes"] += f["byteCount"] + f["meshBytes"]
            region["detailedSections"] += 1
        region["cells"].append(cell)
    assert all(r["cells"] for r in regions.values())
    assert sum(len(r["cells"]) for r in regions.values()) == len(background["partitions"])
    assert sum(r["detailedSections"] for r in regions.values()) == len(fine)
    return dict(schemaVersion=1, status="publication-plan", regions=list(regions.values()),
                description="20 geographic groups of existing storage sections. Each section belongs to one group. "
                            "Names describe approximate coverage, not administrative boundaries. Terrain sizes exclude maps and paths. "
                            "Detailed survey gaps retain coarse background; complete app packs require separate map/path publication.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = build(args.root)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, separators=(",", ":")) + "\n")
    for region in result["regions"]:
        print(f'{region["name"]}: {len(region["cells"])} sections; {region["terrainBytes"] / 1e6:.1f} MB terrain + index; maps/paths pending')
