#!/usr/bin/env python3
"""Exercise publication that happens during the preview worker's final pass."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


class PreviewCompletionTests(unittest.TestCase):
    def test_final_pass_reloads_catalog_after_upstream_finishes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            world, output = root / 'world', root / 'previews'
            world.mkdir()
            sources = [dict(id='world-' + name, path='sources/world-' + name + '/world.json', bounds={}) for name in ('a', 'b')]
            for item in sources:
                manifest = world / item['path']
                manifest.parent.mkdir(parents=True)
                manifest.write_text(json.dumps(dict(id=item['id'])))
            (world / 'catalog.json').write_text(json.dumps(dict(sources=sources[:1])))
            (world / 'supervisor.json').write_text(json.dumps(dict(state='finished')))
            renderer = root / 'renderer'
            renderer.write_text('#!' + sys.executable + '\n' + """
import json, sys
from pathlib import Path
source = Path(sys.argv[1])
ident = json.loads((source / 'world.json').read_text())['id']
Path(sys.argv[2]).write_bytes(b'x' * 1200)
""" + f"Path({str(world / 'catalog.json')!r}).write_text({json.dumps(dict(sources=sources))!r})\n" + "print(json.dumps(dict(sourceID=ident, height=2048, width=2048)))\n")
            renderer.chmod(0o755)
            subprocess.run([sys.executable, str(Path(__file__).with_name('batch_previews.py')), '--world-root', str(world), '--output', str(output), '--renderer', str(renderer), '--hours', '0', '--reserve-gib', '0'], check=True, timeout=10, capture_output=True)
            published = json.loads((output / 'catalog.json').read_text())['previews']
            self.assertEqual({item['id'] for item in published}, {'world-a', 'world-b'})
            self.assertEqual(json.loads((output / 'status.json').read_text())['state'], 'complete')


if __name__ == '__main__':
    unittest.main()
