import json
from pathlib import Path
import tempfile
import unittest
from audit_coverage import evidence, inspect_partition, inspect_world
from terrain_coverage import missing_terrain


class CoverageAuditTests(unittest.TestCase):
    def test_absent_inputs_are_not_called_survey_rejection(self):
        self.assertEqual(evidence({'chunkCount':0},[]),['no_prepared_manifest'])
        flags=evidence({'chunkCount':0},[{'sourceName':'Welsh Government 1 m LiDAR DTM'}])
        self.assertIn('welsh_only_empty_input_review_source_choice',flags)
        self.assertNotIn('outside_recorded_ea_survey_footprint',flags)

    def test_rejected_and_suppressed_fallback_evidence_stays_separate(self):
        flags=evidence({'chunkCount':5,'rejectedWithoutFallback':10,'suppressedFallbackCandidates':2},[{'sourceName':'EA'}])
        self.assertEqual(flags,['outside_recorded_ea_survey_footprint','fallback_excluded_by_seam_policy'])

    def test_changed_or_missing_input_is_not_trusted_for_classification(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'manifest.json'
            p.write_text(json.dumps({'parents':[],'source':{'name':'EA'}}))
            row=dict(id='a',bounds={},chunkCount=0,sourceManifests=[dict(path=str(p),sha256='wrong')])
            r=inspect_partition(row)
            self.assertEqual(r['flags'],['source_evidence_unverified'])
            self.assertEqual(r['problems'][0]['problem'],'manifest_hash_changed')
            p.unlink();self.assertEqual(inspect_partition(row)['problems'][0]['problem'],'manifest_missing')

    def test_publication_detects_bad_masks_and_missing_or_truncated_packs(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)
            manifest=dict(id='a',columns=2,rows=1,bounds=dict(minLongitude=0,maxLongitude=2,minLatitude=0,maxLatitude=1),tiles=[dict(column=0,row=0)])
            (root/'world.json').write_text(json.dumps(manifest));(root/'section.ridgepack').write_bytes(b'1234')
            entry=dict(id='a',path='world.json',tileCount=1,missingTerrain=missing_terrain(manifest),pack=dict(file='section.ridgepack',byteCount=4))
            self.assertEqual(inspect_world((root,entry))['problems'],[])
            entry['missingTerrain']=[]
            (root/'section.ridgepack').write_bytes(b'1')
            self.assertEqual(inspect_world((root,entry))['problems'],['coverage_mask_mismatch','section_pack_size_mismatch'])
            (root/'section.ridgepack').unlink()
            self.assertIn('section_pack_missing_on_disk',inspect_world((root,entry))['problems'])

if __name__=='__main__':unittest.main()
