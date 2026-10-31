#!/usr/bin/env python3
"""Verify the processed Apple publication against every local native archive.

Checks exact Apple version IDs, iOS availability, native upload state, file name,
size and Apple's transport MD5, plus the original local SHA256. Does not mutate
Apple resources or print credentials.
"""
import argparse, hashlib, json, os, subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--publication', type=Path, required=True)
    parser.add_argument('--app-id', required=True)
    parser.add_argument('--key-id', default=os.environ.get('ASC_KEY_ID'))
    parser.add_argument('--issuer-id', default=os.environ.get('ASC_ISSUER_ID'))
    args = parser.parse_args()
    if not args.app_id.isdigit() or not args.key_id or not args.issuer_id:
        parser.error('Missing Apple app/key/issuer identifiers')
    root = args.publication.resolve(strict=True)
    state = json.loads((root / 'packaged.json').read_text())
    ready = json.loads((root / 'uploaded.json').read_text())
    if set(state) != set(ready):
        raise ValueError('The publication is not fully processed')
    for key, item in state.items():
        if ready[key]['sha256'] != item['sha256'] or ready[key]['appID'] != args.app_id:
            raise ValueError('Mismatched local upload receipt: ' + key)
    ids = [ready[k]['assetPackVersionID'] for k in sorted(state)]
    env = dict(os.environ, ASC_KEY_ID=args.key_id, ASC_ISSUER_ID=args.issuer_id)
    result = subprocess.run(['node',str(Path(__file__).with_name('apple_asset_status.mjs')),
                             args.app_id,json.dumps(ids),'files'],env=env,capture_output=True,text=True,check=True)
    remote = json.loads(result.stdout)
    (root / 'remote-verification-details.json').write_text(json.dumps(remote,indent=2)+'\n')
    assets = {a['attributes']['assetPackIdentifier']:a for a in remote['assets']['data']}
    versions = {v['id']:v for v in remote['versions']}
    files = {f['id']:f for f in remote['files']}
    current = {v['id']:v for v in remote['assets'].get('included',[])}
    if set(assets) != set(state):
        raise ValueError('Apple and the planned pack identifiers differ')
    verified = []
    for key, item in state.items():
        asset = assets[key]
        version_id = ready[key]['assetPackVersionID']
        beta = asset['relationships']['internalBetaVersion']['data']
        if asset['attributes']['archived'] or beta is None or beta['id'] != version_id:
            raise ValueError('The expected pack version is not available internally: ' + key)
        if 'IOS' not in current[version_id]['attributes']['platforms']:
            raise ValueError('Pack is unavailable on iOS: ' + key)
        version = versions[version_id]
        file_id = version['relationships']['assetFile']['data']['id']
        uploaded = files[file_id]['attributes']
        if version['attributes']['state'] != 'COMPLETE' or uploaded['assetDeliveryState']['state'] != 'COMPLETE':
            raise ValueError('Apple processing is incomplete: ' + key)
        if uploaded['fileName'] != key+'.aar' or uploaded['fileSize'] != item['bytes']:
            raise ValueError('Apple file identity or size differs: ' + key)
        sha, md5 = hashlib.sha256(), hashlib.md5()
        archive = root / 'archives' / (key+'.aar')
        with archive.open('rb') as stream:
            for block in iter(lambda:stream.read(1024*1024),b''):
                sha.update(block);md5.update(block)
        if archive.stat().st_size != item['bytes'] or sha.hexdigest() != item['sha256'] or md5.hexdigest().upper() != uploaded['sourceFileChecksum'].upper():
            raise ValueError('Remote checksum differs: ' + key)
        verified.append({'id':key,'versionID':version_id,'sha256':sha.hexdigest(),'appleMD5':md5.hexdigest(),'bytes':item['bytes']})
    proof = {'appID':args.app_id,'status':'VERIFIED_READY_FOR_INTERNAL_TESTING','packs':len(verified),
             'bytes':sum(x['bytes'] for x in verified),'checks':'exact version, iOS, completed processing, size, local SHA256, Apple transport MD5',
             'verified':verified}
    (root / 'remote-verification.json').write_text(json.dumps(proof,indent=2)+'\n')
    print(json.dumps({k:v for k,v in proof.items() if k!='verified'},indent=2))


if __name__ == '__main__':
    main()
