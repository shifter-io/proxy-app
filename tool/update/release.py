#!/usr/bin/env python3
"""Prepare immutable CDN artifacts and an Ed25519-signed feed, published last.

Uses Python's standard library and OpenSSL 3. No private keys are generated or
uploaded by this command. The output directory is a local CDN staging mirror.
"""
import argparse
import base64
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request


def strict_load(data):
    def pairs(items):
        result = {}
        for k, v in items:
            if k in result:
                raise ValueError('Duplicate JSON field: ' + k)
            result[k] = v
        return result
    return json.loads(data, object_pairs_hook=pairs)


def safe_path(path):
    if not isinstance(path, str) or not re.fullmatch(r'[A-Za-z0-9_-]+(?:[./-][A-Za-z0-9_-]+)*', path) or '..' in path:
        raise ValueError('Unsafe artifact path')
    return path


def sha256(path):
    with Path(path).open('rb') as f:
        digest = hashlib.sha256()
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            digest.update(chunk)
        return digest.hexdigest()


def openssl():
    value = os.environ.get('SHIFTER_OPENSSL', 'openssl')
    version = subprocess.check_output([value, 'version'], text=True)
    if not version.startswith('OpenSSL 3.'):
        raise ValueError('OpenSSL 3 is required; set SHIFTER_OPENSSL to its executable')
    return value


def public_key(private_key):
    der = subprocess.check_output([openssl(), 'pkey', '-in', str(private_key), '-pubout', '-outform', 'DER'], stderr=subprocess.PIPE)
    if len(der) != 44 or der[:12] != bytes.fromhex('302a300506032b6570032100'):
        raise ValueError('The signing key must be Ed25519')
    return der[12:]


def sign(payload, key, key_id, scratch):
    encoded = json.dumps(payload, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()
    with tempfile.TemporaryDirectory(prefix='sign-', dir=scratch) as temporary:
        p = Path(temporary) / 'payload'
        signature = Path(temporary) / 'signature'
        p.write_bytes(encoded)
        subprocess.run([openssl(), 'pkeyutl', '-sign', '-rawin', '-inkey', str(key), '-in', str(p), '-out', str(signature)], check=True, capture_output=True)
        envelope = {'keyId': key_id, 'payloadBase64': base64.b64encode(encoded).decode(), 'signatureBase64': base64.b64encode(signature.read_bytes()).decode()}
    result = json.dumps(envelope, separators=(',', ':')).encode() + b'\n'
    if len(result) > 262144:
        raise ValueError('Signed manifest exceeds 256 KiB')
    return result


def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise ValueError('Refusing symlink destination')
    fd, temporary = tempfile.mkstemp(prefix='.publishing-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as out:
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def validate(payload):
    if payload.get('schemaVersion') != 1 or payload.get('environment') != 'production' or payload.get('channel') != 'stable':
        raise ValueError('Unsupported schema, environment or channel')
    if payload['distribution'] not in ('desktop', 'direct', 'play', 'appStore'):
        raise ValueError('Invalid distribution')
    for dimension in ('distribution', 'platform', 'architecture'):
        safe_path(payload[dimension])
    ids = set()
    for release in payload['releases']:
        if release['releaseId'] in ids:
            raise ValueError('Duplicate release ID')
        ids.add(release['releaseId'])
        if not re.fullmatch(r'(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*)){0,2}' if payload['distribution'] == 'appStore' else r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', release['displayVersion']):
            raise ValueError('Stable semantic version required')
        if type(release['build']) is not int or release['build'] < 1 or type(release['enabled']) is not bool:
            raise ValueError('Invalid build or enabled flag')
        if not 0 <= release['rolloutPercentage'] <= 100 or len(release['notes'].encode()) > 8192:
            raise ValueError('Invalid rollout or release notes')
        if payload['distribution'] in ('desktop', 'direct'):
            artifact = release['artifact']
            safe_path(artifact['relativePath'])
            if not artifact['expectedSigner'] or (payload['distribution'] == 'direct' and not re.fullmatch('[a-f0-9]{64}', artifact['expectedSigner'])):
                raise ValueError('Production signing identity is required')
            if artifact['format'] != ('apk' if payload['distribution'] == 'direct' else 'nupkg'):
                raise ValueError('Wrong artifact format')


def publish(args):
    payload = strict_load(Path(args.template).read_bytes())
    validate(payload)
    key = Path(args.key).resolve(strict=True)
    if os.name != 'nt' and key.stat().st_mode & 0o077:
        raise ValueError('Private key must not be group/world readable (chmod 600)')
    raw_public = public_key(key)
    trusted = strict_load(Path(args.trusted_keys).read_bytes())
    if trusted.get(args.key_id) != base64.b64encode(raw_public).decode():
        raise ValueError('Signing key is not in the production trust-root file')
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    feed = output / payload['distribution'] / payload['platform'] / payload['architecture'] / 'stable.json'
    # Exclusive writer reservation prevents concurrent refreshes reusing a sequence.
    lock = output / '.shifter-publish.lock'
    fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        os.write(fd, json.dumps({'pid': os.getpid(), 'purpose': 'publish signed update feed', 'started': dt.datetime.now(dt.timezone.utc).isoformat()}).encode())
        previous = 0
        if feed.exists():
            envelope = strict_load(feed.read_bytes())
            previous = strict_load(base64.b64decode(envelope['payloadBase64']))['feedSequence']
        if args.sequence <= previous:
            raise ValueError('Feed sequence must increase on publish, refresh, withdrawal and observation updates')
        now = dt.datetime.now(dt.timezone.utc)
        payload.update(feedSequence=args.sequence, generatedAt=now.isoformat(), expiresAt=(now + dt.timedelta(hours=48)).isoformat())
        observations_file = getattr(args, 'observations', None)
        if observations_file:
            observations = strict_load(Path(observations_file).read_bytes())
            for release in payload['releases']:
                if payload['distribution'] == 'appStore':
                    release['store']['observations'] = observations
        sources = dict(item.split('=', 1) for item in args.artifact)
        for release in payload['releases']:
            artifact = release.get('artifact')
            if not artifact:
                continue
            destination = output / safe_path(artifact['relativePath'])
            if output not in destination.resolve().parents:
                raise ValueError('Artifact destination escapes staging root')
            source = Path(sources[release['releaseId']]).resolve(strict=True) if release['releaseId'] in sources else destination
            digest = sha256(source)
            size = source.stat().st_size
            if not 0 < size <= 4 * 1024**3:
                raise ValueError('Artifact size exceeds client limit')
            if destination.exists() and (sha256(destination) != digest or destination.stat().st_size != size):
                raise ValueError('Immutable artifact URL already contains different bytes')
            artifact.update(sha256=digest, byteLength=size)
            if not destination.exists():
                destination.parent.mkdir(parents=True, exist_ok=True)
                # Copy to the same filesystem before publishing its immutable name.
                with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as temp:
                    temporary = Path(temp.name)
                    try:
                        with source.open('rb') as content:
                            shutil.copyfileobj(content, temp)
                        temp.flush(); os.fsync(temp.fileno())
                    except BaseException:
                        temporary.unlink(missing_ok=True)
                        raise
                try:
                    if sha256(temporary) != digest:
                        raise ValueError('Artifact changed while copying')
                    os.replace(temporary, destination)
                finally:
                    temporary.unlink(missing_ok=True)
        scratch = Path(args.scratch).resolve()
        scratch.mkdir(parents=True, exist_ok=True)
        # The caller's CDN sync must preserve this ordering: artifacts, then feed.
        signed = sign(payload, key, args.key_id, scratch)
        atomic_write(feed, signed)
        print(f'Prepared sequence {args.sequence}: {feed}')
    finally:
        os.close(fd)
        lock.unlink()


def observe(args):
    # Explicit mapping: ISO alpha-3 StoreKit value -> Apple lookup alpha-2 value.
    mapping = strict_load(Path(args.storefronts).read_bytes())
    observations = []
    for index, (storefront, country) in enumerate(mapping.items()):
        if not re.fullmatch('[A-Z]{3}', storefront) or not re.fullmatch('[a-z]{2}', country):
            raise ValueError('Storefront mappings must be explicit ISO alpha-3/alpha-2 codes')
        if index:
            time.sleep(6.1)  # <=10 requests per minute
        url = 'https://itunes.apple.com/lookup?' + urllib.parse.urlencode({'id': args.product_id, 'country': country})
        with urllib.request.urlopen(url, timeout=20) as response:
            raw = response.read(262145)
            if len(raw) > 262144:
                raise ValueError('Oversized store response')
        for app in strict_load(raw).get('results', []):
            if str(app.get('trackId')) == args.product_id and app.get('bundleId') == args.application_id:
                observations.append({'storefront': storefront, 'applicationId': args.application_id, 'version': app['version'],
                                     'minimumOs': app.get('minimumOsVersion'), 'observedAt': dt.datetime.now(dt.timezone.utc).isoformat()})
    atomic_write(Path(args.output), json.dumps(observations, indent=2).encode())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    p = commands.add_parser('publish', help='Publish, refresh, withdraw or change rollout using a new sequence')
    for name in ('template', 'key', 'key-id', 'trusted-keys', 'output', 'scratch'):
        p.add_argument('--' + name, required=True)
    p.add_argument('--sequence', type=int, required=True)
    p.add_argument('--observations', help='Fresh observe-ios output to include in the signed feed')
    p.add_argument('--artifact', action='append', default=[], metavar='RELEASE_ID=PATH')
    o = commands.add_parser('observe-ios')
    for name in ('product-id', 'application-id', 'storefronts', 'output'):
        o.add_argument('--' + name, required=True)
    args = parser.parse_args()
    if args.command == 'publish':
        publish(args)
    else:
        observe(args)


if __name__ == '__main__':
    main()
