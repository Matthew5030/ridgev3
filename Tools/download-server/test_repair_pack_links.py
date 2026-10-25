import importlib.util, json, tempfile, unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('repair', Path(__file__).with_name('repair_pack_links.py'))
repair = importlib.util.module_from_spec(spec); spec.loader.exec_module(repair)

class PackRepairTests(unittest.TestCase):
    def fixture(self, root):
        section = root / 'sources/world-test'; section.mkdir(parents=True)
        payload = b'cached terrain' * 200
        import hashlib
        asset = dict(file='overview-32m.json', byteCount=len(payload), sha256=hashlib.sha256(payload).hexdigest())
        (section / asset['file']).write_bytes(payload)
        (section / 'world.json').write_text(json.dumps(dict(id='world-test', overview=asset, graph=asset, tiles=[])))
        region = dict(id='world-test', path='sources/world-test/world.json')
        region['pack'] = repair.build(root, region)
        return section, region

    def test_self_link_rebuilt_without_catalog_change(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); section, region = self.fixture(root)
            pack = section / region['pack']['file']; original = pack.read_bytes()
            pack.unlink(); pack.symlink_to(pack)
            result = repair.restore(root, region, root / 'recovered')
            self.assertEqual(result['state'], 'restored')
            self.assertEqual(pack.read_bytes(), original)
            self.assertNotEqual(pack.readlink(), pack)

    def test_hash_mismatch_never_published(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); section, region = self.fixture(root)
            pack = section / region['pack']['file']; pack.unlink(); pack.symlink_to(pack)
            region['pack']['sha256'] = '0' * 64
            with self.assertRaisesRegex(ValueError, 'differs from catalog'):
                repair.restore(root, region, root / 'recovered')
            self.assertEqual(pack.readlink(), pack)

if __name__ == '__main__': unittest.main()
