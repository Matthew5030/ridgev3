# Content-rights review for the Account Holder

Ridge contains third-party map and terrain content. The App Store declaration
must not say it has no third-party content. The proposed answer is **Yes, it
contains third-party content, and I have the necessary rights**, only after the
owner confirms the redistribution terms for the final app and all map packs.
No rights declaration or licence agreement was accepted during this preparation.

This is an evidence checklist, not a new grant of rights or legal clearance.
The source manifests and Settings > Map sources and licences carry credits.
Keep them in the app and the frozen publication.

| Included source | Existing project evidence / terms to check |
|---|---|
| OpenStreetMap walking network/cartography | Source manifest attribution and Settings credits; ODbL 1.0 / produced-work and database redistribution requirements. |
| Welsh Government LiDAR | Source manifest credits; Open Government Licence v3.0 attribution. |
| Copernicus Sentinel-2 ground colouring | Contains modified Copernicus Sentinel data 2025; source-specific Sentinel terms and attribution. |
| Copernicus DEM GLO-30 | Frozen starter credits include the Copernicus WorldDEM-30 / DLR / Airbus attribution and declare the Copernicus DEM Free & Open licence; check its redistribution and derived-product notice requirements. |
| Environment Agency 1 m LIDAR composite DTM | Frozen starter credits retain Environment Agency copyright/database rights 2022 and declare OGL 3.0. |
| Mapzen overview elevations | Tilezen/Joerd upstream attribution lists multiple source datasets and terms; preserve those credits. |
| Natural Earth geographic overview | Public-domain source; retain the existing attribution. |
| Future UK coverage | Review its source manifests separately before enabling additional areas. |

On 31 October all 282 frozen starter manifests were inspected. Their six unique
source credits are recorded in `evidence/offline-starter-source-credits.json`.
This records what the data declares; the owner still needs to confirm the
app's redistribution obligations. Natural Earth and the more detailed overview
elevation credits are also retained in native Settings.

Source references already linked by the project:

- https://www.openstreetmap.org/copyright
- https://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/
- https://github.com/tilezen/joerd/blob/master/docs/attribution.md
- https://www.naturalearthdata.com/about/terms-of-use/
- https://dataspace.copernicus.eu/explore-data/data-collections/sentinel-data/sentinel-2

The owner also needs to confirm the DSA trader information shown for the app and
its first availability territories. UK-only availability is saved for the
proposed first release, remains editable, and is not publicly available. These decisions do not require changing the approved flight path.
