# Eryri download reliability

Selecting a region checks the local section indexes and asset receipts before offering a download. The card shows the remaining transfer and uses “Download remaining terrain” when part of the region is already saved. A completed region reopens from storage. Backgrounding Ridge pauses an active transfer; completed sections and partial archive bytes remain available for continuation.

Returning to Ridge rechecks a paused selection's remaining bytes without starting a transfer. The card explicitly says “Download paused”, with a single “Resume download” action. Resume performs any outstanding check and continues the transfer; cancelling that check prevents a delayed restart. The displayed reduction from a fresh download includes both reused file bytes and skipped transport metadata.

The current Eryri selection has 73 published sections containing 16,199 available tiles. Its section packs total 1,111,456,185 bytes, which exceeds the original region archive limit of 1 GiB. Raising that limit in the catalogue would break older installed clients. Instead, `regionArchiveGroups` adds a list of independently resumable archives that each retain the existing validated format. Older clients ignore this additive field and continue using section packs.

The published Eryri group contains two files, 799,165,914 and 320,763,293 bytes. The 1,119,929,207-byte wire total includes the compressed manifests. Section pack payloads, terrain detail and hashes are unchanged. The renderer reads nested section ranges directly, without extracting another copy of the region.

A fresh save uses the group. An existing partial save checks each chunk: saved sections are reused, sparse gaps use section or asset transfers, and an interrupted bulk file resumes with HTTP Range. Having completed independent section packs prevents choosing a new larger archive just to fetch their missing neighbours. Completed progress shading is retained across sections and chunks while downloading on the native 2D map.

## Publishing

With the download server's dataset root and the app's current download-zone library:

```sh
python3 Tools/world_source/pack_region.py "$DATASET_ROOT" \
  'ridge v3/Resources/uk-download-zones.json' --region park-eryri --split --publish
```

The builder hashes every original pack while copying, checks each archive's size, and publishes the catalogue atomically only after all chunks succeed. It refuses publication if source descriptors changed during the build. Dataset source rollouts invalidate old archive descriptors; rebuild the affected groups after such a rollout.

## Verification

Synthetic publication and corruption tests run without the large terrain dataset:

```sh
python3 -m unittest discover -s Tools/world_source -p 'test_pack_*.py'
```

With the local dataset server on port 8787, `sh Tools/test_world_region_archive.sh` exercises the actual Eryri group, offline rendering, cold model reopening, bounded geographic progress, metadata recovery and Range continuation. The section-pack, region-pack and catalogue suites additionally exercise partial saves and repair. Hardware checks must use the real device's cache and screenshot; installing a build or observing a simulator does not prove device persistence.
