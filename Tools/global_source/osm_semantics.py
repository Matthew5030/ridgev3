"""Focused OSM-to-Ridge semantic transformation.

This module deliberately contains no styling decisions.  It only maps explicit
OSM evidence to the bounded Ridge v1 vocabulary.  Unrecognised highway values
remain ``unknownPath`` and unrecognised surface/access values remain
``unknown``; callers must never infer more certain values later.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, Iterable, List, Optional, Sequence, Tuple


Position = Tuple[float, float]  # longitude, latitude


@dataclass(frozen=True)
class SourceFeature:
    element_type: str
    element_id: int
    version: int
    tags: Dict[str, str]
    geometry_type: str
    coordinates: object
    part: Optional[str] = None


class MapFeatureTransformer:
    """Pure deterministic transformation into semantic-map schema v1."""

    _MAJOR_ROADS = {
        "motorway", "motorway_link", "trunk", "trunk_link", "primary",
        "primary_link", "secondary", "secondary_link",
    }
    _MINOR_ROADS = {
        "tertiary", "tertiary_link", "unclassified", "residential",
        "living_street", "service", "road",
    }
    _FOOTPATHS = {"footway", "path", "steps", "pedestrian"}
    _BRIDLEWAYS = {"bridleway"}
    _OPEN_NATURAL = {
        "heath", "grassland", "bare_rock", "fell", "moor", "scree",
        "shingle", "sand",
    }
    _OPEN_LANDUSE = {"grass", "meadow", "village_green", "recreation_ground"}

    _SURFACES = {
        "paved": "paved", "paving_stones": "paved", "sett": "paved",
        "asphalt": "asphalt", "chipseal": "asphalt",
        "concrete": "concrete", "concrete:lanes": "concrete",
        "concrete:plates": "concrete", "gravel": "gravel",
        "pebblestone": "gravel", "compacted": "compacted",
        "fine_gravel": "fineGravel", "ground": "ground", "earth": "ground",
        "dirt": "ground", "grass": "grass", "grass_paver": "grass",
        "mud": "mud", "rock": "rock", "stone": "rock",
        "wood": "wood", "woodchips": "wood", "sand": "sand",
    }

    _PUBLIC_DESIGNATIONS = {
        "public_footpath", "public_bridleway", "restricted_byway",
        "byway_open_to_all_traffic",
    }
    _ACCESS_LAND_DESIGNATIONS = {
        "access_land", "common", "registered_common_land", "open_access",
    }

    def transform(self, source: SourceFeature) -> Optional[dict]:
        tags = {str(k): str(v) for k, v in sorted(source.tags.items())}
        kind = self.classify_kind(tags)
        if kind is None or not self._geometry_supported(kind, source.geometry_type):
            return None

        properties = {
            "surface": self.classify_surface(tags),
            "access": self.classify_access(tags),
        }
        if tags.get("name"):
            properties["name"] = tags["name"]
        reference = tags.get("ref") or tags.get("prow_ref")
        if reference:
            properties["reference"] = reference
        elevation = self._parse_elevation(tags.get("ele"))
        if elevation is not None:
            properties["elevationMeters"] = elevation

        suffix = f":{source.part}" if source.part else ""
        return {
            "id": f"osm:{source.element_type}:{source.element_id}{suffix}",
            "kind": kind,
            "source": {
                "provider": "OpenStreetMap",
                "elementType": source.element_type,
                "elementID": source.element_id,
                "version": source.version,
                "tags": tags,
            },
            "geometry": {
                "type": source.geometry_type,
                "coordinates": source.coordinates,
            },
            "properties": properties,
        }

    def classify_kind(self, tags: Dict[str, str]) -> Optional[str]:
        highway = tags.get("highway")
        if highway in self._BRIDLEWAYS:
            return "bridleway"
        if highway == "track":
            return "track"
        if highway in self._FOOTPATHS:
            # An explicit public-bridleway designation is stronger than the
            # generic OSM highway=path representation.
            if tags.get("designation") == "public_bridleway":
                return "bridleway"
            return "footpath"
        if highway in self._MINOR_ROADS:
            return "minorRoad"
        if highway in self._MAJOR_ROADS:
            return "majorRoad"
        if highway:
            return "unknownPath"

        if tags.get("building") and tags.get("building") != "no":
            return "building"
        if tags.get("natural") == "peak":
            return "peak"
        if tags.get("place") in {
            "city", "town", "village", "hamlet", "locality",
            "isolated_dwelling", "suburb", "neighbourhood",
        }:
            return "settlement"
        if tags.get("natural") in {"water", "wetland", "bay"} or tags.get("waterway"):
            return "water"
        if (
            tags.get("natural") == "wood"
            or tags.get("landuse") == "forest"
            or tags.get("landcover") in {"trees", "forest"}
        ):
            return "woodland"
        if tags.get("designation") in self._ACCESS_LAND_DESIGNATIONS:
            return "accessLand"
        if (
            tags.get("natural") in self._OPEN_NATURAL
            or tags.get("landuse") in self._OPEN_LANDUSE
            or tags.get("landcover") in {"grass", "scrub", "bare_rock"}
        ):
            return "openLand"
        if tags.get("boundary"):
            return "boundary"
        return None

    def classify_surface(self, tags: Dict[str, str]) -> str:
        raw = tags.get("surface", "").strip().lower()
        return self._SURFACES.get(raw, "unknown")

    def classify_access(self, tags: Dict[str, str]) -> str:
        foot = tags.get("foot", "").strip().lower()
        access = tags.get("access", "").strip().lower()
        designation = tags.get("designation", "").strip().lower()
        if foot in {"no", "private"}:
            return foot
        if foot == "permissive":
            return "permissive"
        if foot in {"yes", "designated", "official"}:
            return "public"
        if designation in self._PUBLIC_DESIGNATIONS:
            return "public"
        if access in {"no", "private"}:
            return access
        if access == "permissive":
            return "permissive"
        if access in {"yes", "designated", "official"}:
            return "public"
        return "unknown"

    @staticmethod
    def _geometry_supported(kind: str, geometry_type: str) -> bool:
        if kind in {"peak", "settlement"}:
            return geometry_type == "Point"
        if kind in {"footpath", "bridleway", "track", "minorRoad", "majorRoad", "unknownPath", "boundary"}:
            return geometry_type == "LineString"
        return geometry_type in {"LineString", "Polygon"}

    @staticmethod
    def _parse_elevation(value: Optional[str]) -> Optional[float]:
        if not value:
            return None
        cleaned = value.strip().lower().replace("metres", "").replace("meters", "").strip()
        if cleaned.endswith("m"):
            cleaned = cleaned[:-1].strip()
        try:
            return float(cleaned)
        except ValueError:
            return None
