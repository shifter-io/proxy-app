#!/bin/sh
# Live tests use a local Keychain entry. Never publish their compiled artifacts.
# Add the key through Keychain Access as service shifter-api-key, account shifter-test.
set -eu
cd "$(dirname "$0")/../.."
# Keep the key out of process arguments and remove the private input file on exit.
python3 - "$@" <<'PY'
import json
import os
import subprocess
import sys
import tempfile

key = subprocess.check_output([
    'security', 'find-generic-password', '-a', 'shifter-test',
    '-s', 'shifter-api-key', '-w',
], text=True).strip()
with tempfile.TemporaryDirectory(prefix='shifter-live-test-') as folder:
    path = os.path.join(folder, 'defines.json')
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump({'SHIFTER_TEST_KEY': key}, stream)
    result = subprocess.run([
        'flutter', 'test', 'integration_test/live_connect_test.dart',
        *sys.argv[1:], '--dart-define-from-file=' + path,
    ])
    sys.exit(result.returncode)
PY
