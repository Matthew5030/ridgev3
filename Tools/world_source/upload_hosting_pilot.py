#!/usr/bin/env python3
"""Upload a verified pilot to R2, then read back every uploaded object.

Uses Wrangler's existing OAuth session locally; never emits credential values.
Run `wrangler whoami` first to refresh its session. Python 3.11+.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
from pathlib import Path
import time
import tomllib
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlparse
from urllib.request import Request, urlopen


def run(root, account, bucket, prefix, auth_file, workers, public_origin=None):
    if not prefix.endswith('/') or '..' in prefix.split('/'):
        raise ValueError('Use a versioned prefix ending with /')
    if public_origin:
        origin = urlparse(public_origin)
        if origin.scheme != 'https' or not origin.hostname or origin.username or origin.password or origin.path not in ('', '/') or origin.query or origin.fragment:
            raise ValueError('Public origin must be an HTTPS origin')
    inventory = json.loads((root / 'upload-inventory.json').read_text())['objects']
    if not inventory:
        raise ValueError('Empty upload inventory')
    for item in inventory:
        path = (root / item['key']).resolve()
        if not path.is_relative_to(root.resolve()):
            raise ValueError('Unsafe inventory path')
        data = path.read_bytes()
        if len(data) != item['byteCount'] or hashlib.sha256(data).hexdigest() != item['sha256']:
            raise ValueError('Local asset changed: ' + item['key'])
    auth = tomllib.loads(auth_file.read_text())
    token = auth.get('oauth_token') or auth.get('api_token')
    if not token:
        raise ValueError('No Wrangler session found; run wrangler login')
    endpoint = f'https://api.cloudflare.com/client/v4/accounts/{quote(account,safe="")}/r2/buckets/{quote(bucket,safe="")}/objects/'
    progress_file = root / ('upload-progress-' + bucket + '.json')
    complete = {}
    if progress_file.exists():
        saved = json.loads(progress_file.read_text())
        if saved.get('account') == account and saved.get('prefix') == prefix:
            complete = saved.get('complete', {})

    def request(method, key, data=None, content_type='application/octet-stream'):
        headers = {'Authorization': 'Bearer ' + token, 'Content-Type': content_type, 'cf-r2-data-catalog-check': 'true'}
        if data is not None:
            headers['Cache-Control'] = 'public, max-age=31536000, immutable'
        public_read = method == 'GET' and public_origin
        target = public_origin.rstrip('/') + '/' if public_read else endpoint
        if public_read:
            headers = {'User-Agent': 'RidgeHostingVerifier/1.0'}  # No account token on a public host.
        for attempt in range(8):
            try:
                with urlopen(Request(target + quote(prefix + key, safe='/'), data=data, headers=headers, method=method), timeout=60) as response:
                    return response.read()
            except HTTPError as error:
                status = error.code
                if method == 'GET' and status == 404:
                    return None
                if status == 429 or status >= 500:
                    time.sleep(min(30, 2 ** attempt))
                    continue
                # The response can contain account diagnostics. Emit only status/key.
                raise RuntimeError(f'R2 {method} failed ({status}): {key}') from None
            except (URLError, TimeoutError):
                time.sleep(min(30, 2 ** attempt))
        raise RuntimeError('R2 retries exhausted: ' + key)

    def upload(item):
        key = item['key']
        data = (root / key).read_bytes()
        returned = request('GET', key)
        if returned is None:
            mime = 'application/json' if key.endswith('.json') else 'image/jpeg' if key.endswith('.jpg') else 'text/html; charset=utf-8' if key.endswith('.html') else 'application/octet-stream'
            request('PUT', key, data, mime)
            returned = request('GET', key)
        # Never overwrite different bytes under an already-published version.
        if returned is None:
            raise ValueError('Uploaded object is missing: ' + key)
        if len(returned) != item['byteCount'] or hashlib.sha256(returned).hexdigest() != item['sha256']:
            raise ValueError('Remote verification failed: ' + key)
        return item

    # Publish region manifests after their assets, and the catalogue/page last.
    def stage(item):
        if item['key'].endswith(('catalog.json', 'index.html')):
            return 2
        return 1 if item['key'].endswith('world.json') else 0
    total = 0
    for stage_number in range(3):
        batch = [item for item in inventory if stage(item) == stage_number]
        with ThreadPoolExecutor(max_workers=workers) as pool:
            futures = [pool.submit(upload, item) for item in batch]
            for future in as_completed(futures):
                try:
                    item = future.result()
                except BaseException:
                    for pending in futures:
                        pending.cancel()
                    raise
                complete[item['key']] = item['sha256']
                total += 1
                if total % 100 == 0 or total == len(inventory):
                    temporary = progress_file.with_suffix('.tmp')
                    temporary.write_text(json.dumps({'account':account,'prefix':prefix,'complete':complete}))
                    temporary.replace(progress_file)
                    print(f'Uploaded and verified {total}/{len(inventory)} objects', flush=True)
    print(json.dumps({'verifiedObjects':total, 'verifiedBytes':sum(i['byteCount'] for i in inventory),'bucket':bucket,'prefix':prefix}))


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--root',type=Path,required=True)
    p.add_argument('--account',required=True)
    p.add_argument('--bucket',required=True)
    p.add_argument('--prefix',required=True)
    p.add_argument('--auth-file',type=Path,default=Path.home()/'Library/Preferences/.wrangler/config/default.toml')
    p.add_argument('--workers',type=int,default=4,choices=range(1,9))
    p.add_argument('--public-origin',help='Read back via this public HTTPS origin; writes still use the authenticated API')
    a = p.parse_args()
    run(a.root,a.account,a.bucket,a.prefix,a.auth_file,a.workers,a.public_origin)
