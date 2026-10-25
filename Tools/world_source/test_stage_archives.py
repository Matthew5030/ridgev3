#!/usr/bin/env python3
"""Exercise publication, resume repair and input safeguards using tiny fixtures."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('stage_archives.py')


class StageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root / 'source'
        self.output = self.root / 'cache'
        self.directory = self.source / 'tiles/10/500/333'
        self.directory.mkdir(parents=True)
        self.payload = b'checksum-bound fixture' * 100
        self.archive = self.directory / 'v1.ridgetile'
        self.archive.write_bytes(self.payload)
        self.descriptor = self.directory / 'descriptor.json'
        self.metadata = dict(tileID='z10-x500-y333', archiveURL='/tiles/10/500/333/v1.ridgetile',
                             archiveSizeBytes=len(self.payload), archiveSHA256=hashlib.sha256(self.payload).hexdigest())
        self.descriptor.write_text(json.dumps(self.metadata))

    def tearDown(self):
        self.temp.cleanup()

    def run_stage(self, *extra):
        subprocess.run([sys.executable, str(SCRIPT), '--source', str(self.source),
                        '--output', str(self.output), '--minimum-output-free-gib', '0',
                        '--minimum-local-free-gib', '0', *extra], check=True, capture_output=True)
        return json.loads((self.output / 'status.json').read_text())

    def test_publish_resume_repairs_same_size_corruption(self):
        self.assertTrue(self.run_stage()['complete'])
        output = self.output / 'tiles/10/500/333/v1.ridgetile'
        output.write_bytes(b'x' * len(self.payload))
        self.assertTrue(self.run_stage()['complete'])
        self.assertEqual(output.read_bytes(), self.payload)
        self.assertEqual(self.archive.read_bytes(), self.payload)

    def test_corrupt_source_never_publishes_descriptor(self):
        self.archive.write_bytes(b'x' * len(self.payload))
        state = self.run_stage()
        self.assertFalse(state['complete'])
        self.assertEqual(state['tiles']['z10-x500-y333']['status'], 'failed')
        self.assertFalse((self.output / 'tiles/10/500/333/descriptor.json').exists())

    def test_path_escape_is_rejected(self):
        self.metadata['archiveURL'] = '/../outside.ridgetile'
        self.descriptor.write_text(json.dumps(self.metadata))
        state = self.run_stage()
        self.assertEqual(state['tiles']['z10-x500-y333']['reason'], 'Unsafe archive path')

    def test_space_reserve_is_explicitly_blocked(self):
        state = self.run_stage('--minimum-local-free-gib', '1000000000')
        self.assertFalse(state['complete'])
        self.assertFalse(state['running'])
        self.assertEqual(state['tiles']['z10-x500-y333']['status'], 'blocked')

    def test_verified_fallback_is_accepted(self):
        fallback = self.root / 'fallback'
        target = fallback / 'tiles/10/500/333/v1.ridgetile'
        target.parent.mkdir(parents=True)
        target.write_bytes(self.payload)
        self.archive.write_bytes(b'corrupt')
        state = self.run_stage('--fallback', str(fallback))
        self.assertTrue(state['complete'])
        self.assertEqual(state['tiles']['z10-x500-y333']['input'], str(target))


if __name__ == '__main__':
    unittest.main()
