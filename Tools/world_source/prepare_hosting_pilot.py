#!/usr/bin/env python3
"""Copy only verified, app-readable assets into a small immutable hosting pilot."""
import argparse
import hashlib
import html
import json
from pathlib import Path


def prepare(world, previews, output, ids):
    catalog = json.loads((world / 'catalog.json').read_bytes())
    selected = [item for item in catalog['sources'] if item['id'] in ids]
    if {item['id'] for item in selected} != set(ids):
        raise ValueError('Some requested regions are not published')
    preview_index = {item['id']: item for item in json.loads((previews / 'catalog.json').read_bytes())['previews']}
    output.mkdir(parents=True, exist_ok=True)
    assets = {}

    def copy(source, destination, digest, size=None):
        data = source.read_bytes()
        if hashlib.sha256(data).hexdigest() != digest or (size is not None and len(data) != size):
            raise ValueError('Asset verification failed: ' + str(source))
        target = output / destination
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        assets[destination] = dict(key=destination, sha256=digest, byteCount=len(data))

    for item in selected:
        manifest_path = world / item['path']
        manifest = json.loads(manifest_path.read_bytes())
        folder = manifest_path.parent
        refs = [manifest['overview'], manifest['graph']]
        refs += [ref for tile in manifest['tiles'] for ref in (tile['mesh'], tile['background'], tile['map'])]
        for ref in refs:
            name = ref.get('file', ref.get('path'))
            if not name or Path(name).name != name:
                raise ValueError('Unsafe source filename')
            copy(folder / name, str(Path(item['path']).parent / name), ref['sha256'], ref['byteCount'])
        picture = preview_index[item['id']]
        if picture['sourceManifestSHA256'] != hashlib.sha256(manifest_path.read_bytes()).hexdigest():
            raise ValueError('Preview belongs to another manifest')
        copy(previews / picture['file'], 'previews/' + picture['file'], picture['sha256'], picture['byteCount'])
        copy(manifest_path, item['path'], picture['sourceManifestSHA256'])

    def generated(name, data):
        (output / name).write_bytes(data)
        assets[name] = dict(key=name, sha256=hashlib.sha256(data).hexdigest(), byteCount=len(data))

    generated('catalog.json', json.dumps({**catalog, 'sources': selected}, separators=(',', ':')).encode())
    cards = []
    for item in selected:
        path = html.escape(item['path'], quote=True)
        name = html.escape(item['id'])
        cards.append(f'<article><img src="previews/{name}.jpg" alt="Terrain preview"><h2>{name}</h2><p>{item["tileCount"]} cells · {item["downloadBytes"]/1e6:.1f} MB</p><button data-path="{path}">Copy map address</button><a href="{path}">View manifest</a></article>')
    page = '''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Ridge · Snowdon hosting test</title>
<style>body{font:16px system-ui;background:#f5f4ed;color:#243c34;max-width:1000px;margin:40px auto;padding:20px}main{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:24px}article{background:white;padding:16px;border-radius:12px}img{width:100%;aspect-ratio:1;object-fit:contain}h2{font-size:14px;overflow-wrap:anywhere}button{background:#284f43;color:white;border:0;padding:12px;border-radius:8px;margin-right:10px}a{color:#284f43}</style>
<h1>Snowdon hosting test</h1><p>In Ridge, open Settings → Map source, paste a map address and choose Use this source.</p><p>These four regions open individually. Moving between regions automatically is the next app step.</p><main>''' + ''.join(cards) + '''</main><p id="status" role="status"></p><p>Map attribution is preserved in each region manifest.</p><script>document.querySelectorAll('button').forEach(b=>b.onclick=async()=>{const url=new URL(b.dataset.path,location.href).href;try{await navigator.clipboard.writeText(url);document.getElementById('status').textContent='Map address copied.'}catch{document.getElementById('status').textContent=url}})</script></html>'''
    generated('index.html', page.encode())
    inventory = sorted(assets.values(), key=lambda item: (item['key'].endswith(('world.json', 'catalog.json', 'index.html')), item['key']))
    report = dict(schemaVersion=1, sources=len(selected), tiles=sum(item['tileCount'] for item in selected), byteCount=sum(item['byteCount'] for item in inventory), objects=inventory)
    (output / 'upload-inventory.json').write_text(json.dumps(report, indent=2))
    return report


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--world', type=Path, required=True)
    p.add_argument('--previews', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--source', action='append', required=True)
    a = p.parse_args()
    result = prepare(a.world, a.previews, a.output, a.source)
    print(json.dumps({k: v for k, v in result.items() if k != 'objects'}))
