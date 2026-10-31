#!/usr/bin/env python3
"""Seed a dedicated Simulator with verified, public bundled Snowdon data.

This prepares native UI captures, not a download test. It never touches a physical
device or changes the application binary. Stop Ridge before running it.
"""
import argparse
import datetime
import hashlib
import heapq
import json
import math
import pathlib
import shutil
import uuid

parser = argparse.ArgumentParser()
parser.add_argument("container", type=pathlib.Path)
args = parser.parse_args()
container = args.container.resolve()
assert "/CoreSimulator/Devices/" in str(container), "A Simulator container is required"
assert (container / ".com.apple.mobile_container_manager.metadata.plist").is_file()
repo = pathlib.Path(__file__).resolve().parents[2]
source = repo / "ridge v3/Resources/WorldData.bundle"
world_bytes = (source / "world.json").read_bytes()
world = json.loads(world_bytes)
digest = lambda data: hashlib.sha256(data).hexdigest()
cache = container / "Library/Application Support/WorldCache"
cache.mkdir(parents=True, exist_ok=True)
assets = {}

def remember(asset):
    name = asset.get("file", asset.get("path"))
    data = (source / name).read_bytes()
    assert len(data) == asset["byteCount"] and digest(data) == asset["sha256"], name
    assets[asset["sha256"]] = len(data)
    shutil.copyfile(source / name, cache / asset["sha256"])
    return {"hash": asset["sha256"], "bytes": len(data)}

shared = [remember(world["overview"]), remember(world["graph"])]
receipts = []
for tile in world["tiles"]:
    saved = shared + [remember(tile[key]) for key in ("mesh", "map", "background") if tile.get(key)]
    receipts.append({"bounds": tile["mesh"]["bounds"], "assets": saved})
(cache / "pins.json").write_text(json.dumps(sorted(assets)))
(cache / "offline-coverage.json").write_text(json.dumps(receipts))
root = "https://apple-maps.ridge.invalid/world/"
path = "sources/" + world["id"] + "/world.json"
(cache / (digest((root + path).encode()) + ".index")).write_bytes(world_bytes)
catalog = {"schemaVersion": 1, "revision": "public-bundled-snowdon-screenshot-fixture", "sources": [{
    "id": world["id"], "path": path, "bounds": world["bounds"], "tileCount": len(world["tiles"]),
    "missingTerrain": [], "routing": world["graph"]}]}
(cache / (digest((root + "catalog.json").encode()) + ".catalog")).write_text(json.dumps(catalog))

# A public mapped path from the eastern approach to Crib Goch and Garnedd Ugain.
# Use source graph geometry/heights, never fabricated terrain or private GPS data.
graph = json.loads((source / world["graph"]["file"]).read_text())
nodes = {n["id"]: n for n in graph["nodes"]}
adj = {}
for edge in graph["edges"]:
    # Same explicit-access exclusions as the app; "unknown" is a missing OSM
    # access tag, not an assertion that the path is private or impassable.
    if edge.get("access", "unknown") not in ("", "unknown", "public", "yes", "permissive", "designated", "official"):
        continue
    adj.setdefault(edge["from"], []).append((edge["to"], edge["distance"]))
    if edge.get("bidirectional", True):
        adj.setdefault(edge["to"], []).append((edge["from"], edge["distance"]))

def nearest(lat, lon):
    return min(adj, key=lambda i: (nodes[i]["coordinate"]["latitude"] - lat) ** 2 +
               ((nodes[i]["coordinate"]["longitude"] - lon) * math.cos(math.radians(lat))) ** 2)

def leg(start, end):
    queue, costs, previous = [(0, start)], {start: 0}, {}
    while queue:
        cost, key = heapq.heappop(queue)
        if cost != costs[key]:
            continue
        if key == end:
            break
        for other, distance in adj.get(key, []):
            value = cost + distance
            if value < costs.get(other, math.inf):
                costs[other], previous[other] = value, key
                heapq.heappush(queue, (value, other))
    assert end in costs, "Public example graph points are disconnected"
    result = [end]
    while result[-1] != start:
        result.append(previous[result[-1]])
    return list(reversed(result))

targets = [(53.0770, -4.0360, "Eastern approach"),
           (53.0763169, -4.0545889, "Crib Goch"),
           (53.0747, -4.0675, "Garnedd Ugain")]
ids = [nearest(lat, lon) for lat, lon, _ in targets]
point = lambda i: {k: nodes[i][k] for k in ("coordinate", "elevation")}
legs = [leg(a, b) for a, b in zip(ids, ids[1:])]
stamp = (datetime.datetime(2026, 10, 27, 9, 0, tzinfo=datetime.timezone.utc) -
         datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)).total_seconds()
route_id = "A871FFCE-6200-4FEA-8E78-682A752BC469"
route = {"id": route_id, "name": "Crib Goch ridge · example", "regionID": world["id"],
         "createdAt": stamp, "modifiedAt": stamp,
         "notes": "Public mapped example for exploring the terrain. Check access, weather and route suitability before setting out.",
         "waypoints": [{"id": str(uuid.uuid5(uuid.NAMESPACE_URL, "ridge-store-" + name)),
                        "point": point(key), "name": name} for key, (_, _, name) in zip(ids, targets)],
         "segments": [{"mode": "paths", "points": [point(i) for i in keys]} for keys in legs]}
route_dir = container / "Library/Application Support/Ridge/Routes"
route_dir.mkdir(parents=True, exist_ok=True)
(route_dir / "library.json").write_text(json.dumps({"version": 1, "routes": [route]}))
print(json.dumps({"routeID": route_id, "sourceRevision": world["revision"],
                  "sourceSHA256": digest(world_bytes), "assets": len(assets),
                  "bytes": sum(assets.values()), "routePoints": sum(map(len, legs)),
                  "note": "Simulator fixture only; does not prove Apple delivery."}))
