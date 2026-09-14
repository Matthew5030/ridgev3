"""Read original RME1 chunks, optionally from an existing concatenated package."""
import atexit
import json
import os
from pathlib import Path


class MeshReader:
    def __init__(self, root, chunks, package=None):
        self.root = Path(root)
        self.fd = None
        self.offsets = {}
        if package is None:
            return
        package = Path(package)
        index = json.loads((package/'manifest.json').read_text())
        if index.get('storage') != 'concatenated-rme1':
            raise ValueError('Expected an existing concatenated RME1 package')
        records = {c['id']: c for c in index['chunks']}
        size = (package/'terrain.rmeshpack').stat().st_size
        for chunk in chunks:
            record = records[chunk['id']]
            if record['path'] != 'terrain.rmeshpack' or any(record[k] != chunk[k] for k in ['sha256','compactBytes','bounds']):
                raise ValueError('Packaged chunk does not match private source manifest')
            offset = record['byteOffset']
            if not isinstance(offset, int) or offset < 0 or offset + chunk['compactBytes'] > size:
                raise ValueError('Invalid packaged chunk range')
            self.offsets[chunk['id']] = offset
        self.fd = os.open(package/'terrain.rmeshpack', os.O_RDONLY)
        atexit.register(self.close)

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None

    def read(self, chunk):
        if self.fd is None:
            return (self.root/chunk['path']).read_bytes()
        # pread permits bounded parallel validation without a shared seek cursor.
        size = chunk['compactBytes']
        data = os.pread(self.fd, size, self.offsets[chunk['id']])
        if len(data) != size:
            raise ValueError('Truncated packaged chunk')
        return data
