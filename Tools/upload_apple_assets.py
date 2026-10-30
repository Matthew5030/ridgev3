#!/usr/bin/env python3
"""Upload Apple map packs with bounded transfers; verify processing; library last.

The existing Apple key stays in Apple's standard private_keys directory. No key
bytes or JWTs enter arguments, logs, receipts or source. Four transfers can run
while Apple processes earlier packs independently.
"""
import argparse, hashlib, json, os, re, subprocess, time
from concurrent.futures import ThreadPoolExecutor, wait, FIRST_COMPLETED
from pathlib import Path
LIBRARY = 'ridge-map-library'


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def write_json(path, value):
    temporary = path.with_suffix(path.suffix + '.partial')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--publication', type=Path, required=True)
    parser.add_argument('--app-id', required=True)
    parser.add_argument('--key-id', default=os.environ.get('ASC_KEY_ID'))
    parser.add_argument('--issuer-id', default=os.environ.get('ASC_ISSUER_ID'))
    parser.add_argument('--workers', type=int, default=4, choices=range(1, 5))
    args = parser.parse_args()
    if not args.app_id.isdigit() or not args.key_id or not args.issuer_id:
        parser.error('Provide app, key and issuer IDs; never private keys in arguments')
    root = args.publication.resolve(strict=True)
    plan = json.loads((root / 'plan.json').read_text())
    state = json.loads((root / 'packaged.json').read_text())
    if set(state) != set(plan['groups']) or not 1 <= len(state) <= 100:
        raise SystemExit('Publication is incomplete')
    read = lambda name: json.loads((root / name).read_text()) if (root / name).exists() else {}
    ready, transferred = read('uploaded.json'), read('transferred.json')
    library_id = plan.get('libraryPackID', LIBRARY)
    for key, receipt in ready.items():
        transferred.setdefault(key, receipt)
    logs, intents = root / 'upload-logs', root / 'upload-intents'
    logs.mkdir(exist_ok=True, mode=0o700); intents.mkdir(exist_ok=True, mode=0o700)
    env = dict(os.environ, ASC_KEY_ID=args.key_id, ASC_ISSUER_ID=args.issuer_id)
    status_tool = Path(__file__).with_name('apple_asset_status.mjs')

    def matches(receipt, key):
        return receipt.get('appID') == args.app_id and receipt.get('sha256') == state[key]['sha256']

    def uploaded_receipt(key, text):
        version = re.search(r'ASSET PACK VERSION UUID: ([0-9a-f-]+)', text)
        if not version or 'uploaded with 0 errors' not in text or ('= APPLE ID: ' + args.app_id) not in text or ('= ASSET PACK IDENTIFIER: ' + key) not in text:
            return None
        return {'appID':args.app_id, 'sha256':state[key]['sha256'],
                'status':'UPLOADED', 'assetPackVersionID':version.group(1)}

    def upload(key):
        archive = root / 'archives' / (key + '.aar')
        if archive.stat().st_size != state[key]['bytes'] or sha256(archive) != state[key]['sha256']:
            raise ValueError('Archive changed: ' + key)
        if matches(transferred.get(key, {}), key):
            return transferred[key]
        log, intent = logs / (key + '.log'), intents / (key + '.json')
        # Recover a transfer interrupted after Apple accepted it but before the
        # local receipt was written; the durable intent binds it to this hash.
        if intent.exists() and matches(json.loads(intent.read_text()), key) and log.exists():
            receipt = uploaded_receipt(key, log.read_text(errors='replace'))
            if receipt:
                return receipt
        write_json(intent, {'appID':args.app_id, 'sha256':state[key]['sha256']})
        with log.open('w') as stream:
            os.chmod(log, 0o600)
            result = subprocess.run(['xcrun','altool','--upload-asset-pack',str(archive),
                                     '--apple-id',args.app_id,'--api-key',args.key_id,
                                     '--api-issuer',args.issuer_id], stdout=stream, stderr=subprocess.STDOUT)
        receipt = uploaded_receipt(key, log.read_text(errors='replace'))
        if result.returncode or receipt is None:
            raise ValueError('Apple transfer failed for ' + key + '; inspect ' + str(log))
        return receipt

    def transfer(keys):
        pending = iter(k for k in keys if not matches(transferred.get(k, {}), k))
        failures = []
        with ThreadPoolExecutor(max_workers=args.workers) as executor:
            active = {}
            def submit():
                key = next(pending, None)
                if key: active[executor.submit(upload,key)] = key
            for _ in range(args.workers): submit()
            while active:
                done, _ = wait(active, return_when=FIRST_COMPLETED)
                for future in done:
                    key = active.pop(future)
                    try:
                        transferred[key] = future.result()
                        write_json(root / 'transferred.json', transferred)
                        print(json.dumps({'uploaded':key,'transferred':len(transferred),'total':len(state)}),flush=True)
                    except Exception as error: failures.append(str(error))
                if not failures:
                    for _ in range(args.workers - len(active)): submit()
        if failures: raise ValueError('\n'.join(failures))

    def processed(keys):
        started = time.monotonic()
        pending = {k for k in keys if not matches(ready.get(k, {}), k)}
        while pending:
            result = subprocess.run(['node',str(status_tool),args.app_id],env=env,capture_output=True,text=True,check=True)
            snapshot = json.loads(result.stdout)
            write_json(root / 'remote-status.json', snapshot)
            versions = {v['id']:v for v in snapshot['assets'].get('included', [])}
            assets = {a['attributes']['assetPackIdentifier']:a for a in snapshot['assets']['data']}
            for key in list(pending):
                asset = assets.get(key, {})
                beta = asset.get('relationships', {}).get('internalBetaVersion', {}).get('data') or {}
                expected = transferred[key]['assetPackVersionID']
                version = versions.get(beta.get('id'), {})
                if beta.get('id') == expected and not asset['attributes']['archived'] and version.get('attributes', {}).get('state') == 'COMPLETE' and 'IOS' in version['attributes']['platforms']:
                    ready[key] = dict(transferred[key], status='READY_FOR_TESTING', appleAssetID=asset['id'])
                    pending.remove(key)
            write_json(root / 'uploaded.json', ready)
            print(json.dumps({'ready':len(ready),'pendingProcessing':len(pending),'total':len(state)}),flush=True)
            if pending:
                # Inspect unfinished versions to surface Apple's processing
                # errors rather than mistaking a successful transfer for ready.
                ids = [transferred[k]['assetPackVersionID'] for k in pending]
                response = subprocess.run(['node',str(status_tool),args.app_id,json.dumps(ids)],env=env,capture_output=True,text=True,check=True)
                details = json.loads(response.stdout)
                failed = [v for v in details['versions'] if v['attributes']['state'] == 'FAILED']
                if failed:
                    write_json(root / 'processing-failures.json', failed)
                    raise ValueError('Apple rejected an asset pack; inspect processing-failures.json')
                if time.monotonic() - started > 900:
                    raise TimeoutError('Apple processing is still pending; resume this same publication later')
                time.sleep(30)

    preflight = subprocess.run(['node',str(status_tool),args.app_id],env=env,capture_output=True,text=True,check=True)
    active_slots = {a['attributes']['assetPackIdentifier'] for a in json.loads(preflight.stdout)['assets']['data'] if not a['attributes']['archived']}
    if len(active_slots | set(state)) > 100:
        raise ValueError('Planned publication exceeds the live 100 active-pack limit; regroup into existing slots first')
    payloads = sorted(k for k in state if k != library_id)
    transfer(payloads)
    processed(payloads)
    transfer([library_id])
    processed([library_id])
    print(json.dumps({'publicationReady':True,'appID':args.app_id,'packs':len(ready)}),flush=True)


if __name__ == '__main__':
    main()
