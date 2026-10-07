#!/bin/sh
# Live end to end on a phone against the real Shifter (integration_test/live_connect_test.dart).
# The API key comes from this Mac's Keychain, never from the repo:
#   security add-generic-password -U -a shifter-test -s shifter-api-key -w '<key>'
#   tool/e2e/live_test.sh [-d <device id>]
set -e
cd "$(dirname "$0")/../.."
key=$(security find-generic-password -a shifter-test -s shifter-api-key -w)
exec flutter test integration_test/live_connect_test.dart "$@" --dart-define=SHIFTER_TEST_KEY="$key"
