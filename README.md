# Shifter app (Flutter)

Desktop, tablet and mobile version of the Shifter proxy extension
(shifter-io/proxy-extension). The app (`lib/main.dart`) talks to the live
Shifter API and routes this computer through the Shifter gateway; the preview
studio and the tests use mock data (`lib/data/mock_api.dart`).

## How it works

- **API** (`lib/data/http_api.dart`): same endpoints and mapping as the
  extension (`/api/v1/user/me`, `memberships`, `usage`, `proxy-config`). The
  customer signs in with their panel API key, kept in the OS keychain
  (`lib/data/store.dart`). A 401 signs out.
- **Routing** (`lib/proxy/`): a local HTTP proxy on 127.0.0.1 adds the gateway
  login (targeting in the username, like the extension) to every request and
  sends bypassed hosts direct. The OS proxy points at it:
  macOS `networksetup` (tested), Windows WinINet registry, GNOME `gsettings`
  (both written, not yet run on those systems). The user's own proxy settings
  are saved first and put back on disconnect, sign-out, quit, and on the next
  launch after a crash.
- New location, New IP and settings swap the login in the local proxy and
  close tunnels on the old exit, so they apply immediately (no login caching
  workarounds as in the browsers).
- Only apps that follow the system proxy go through Shifter; UDP (WebRTC,
  games) connects directly. It is a system proxy, not a VPN tunnel.
- **Phones and tablets:** connecting needs an OS VPN extension (Android
  `VpnService`, iOS Network Extension) that isn't built yet; the app explains
  this when you tap Connect. Everything else (sign-in, plans, locations) works.
- macOS: the app runs outside the App Sandbox (networksetup is blocked inside
  it), so ship it with Developer ID, not the Mac App Store.

Point a build at another API or IP check:
`--dart-define=SHIFTER_BASE_URL=http://127.0.0.1:18090 --dart-define=SHIFTER_IP_CHECK_URL=http://ip-check.test/json`

## Performance

The local proxy moves bytes with `RawSocket` on its own isolate: each write
goes straight to the OS, and a side stops reading while the other can't take
more, so a tunnel holds at most 64 KB per direction. No timers: idle costs no
CPU. Benchmark (`tool/bench/`, M1 Max under heavy unrelated load), every test
run straight to the gateway and through the proxy:

| Test | Direct | Through local proxy |
|---|---|---|
| Idle | – | 0 ms CPU, 14 MB |
| New HTTPS tunnel + request (median / p99) | 0.58 / 1.29 ms | 0.86 / 1.37 ms |
| Plain HTTP, 100 at a time | 4404 req/s | 3749 req/s, 0 errors |
| One download | 1954 MB/s | 1694 MB/s, 0.5 CPU-s per GB |
| 200 tunnels × 20 MB at once | 2.4 s | 2.9 s, peak 66 MB |
| 50 slow readers (2 MB/s each) | – | peak 66 MB |
| 100 clients reset mid-download | – | proxy unaffected |
| After all of the above | – | 0 CPU idle, no leaked sockets |

A 100 Mbit/s connection costs under 1 % of one core.

```bash
dart compile exe tool/bench/servers.dart -o /tmp/bench_servers
dart compile exe tool/bench/proxy_main.dart -o /tmp/bench_proxy
python3 tool/bench/run.py
```

UI: decorative motion (background halo, button glow, connected rings) runs
on one 30 fps clock and stops while the window isn't active or visible.

## Tests

```bash
flutter test                                    # unit + widget + screen renders
# The real app on this Mac against a stand-in Shifter (switches the macOS proxy
# on, then checks it is restored exactly):
flutter test integration_test/macos_connect_test.dart -d macos \
  --dart-define=SHIFTER_BASE_URL=http://127.0.0.1:18090 \
  --dart-define=SHIFTER_IP_CHECK_URL=http://ip-check.test/json
```

`test/support/fake_shifter.dart` is the stand-in API + login-checking gateway
(Dart port of the extension's `e2e/fake-shifter.mjs`).

## See the UI on this Mac

```bash
# Device preview studio: phones, foldables (Fold cover 280dp → unfolded), tablets, desktop
flutter run -d macos -t lib/main_preview.dart

# The real desktop app (resize the window to see compact → medium → expanded)
flutter run -d macos

# Render every screen on several devices to PNGs (build/screens/)
flutter test test/render_screens_test.dart
```

In the studio: pick a device on the left, switch account scenario (signed out,
all plans, single Residential, Country Geo, Non-Geo, ISP, no plans), toggle
"Start connected", rotate, and Fold/Unfold foldables. The app keeps its state
across device switches, so you can watch a screen reflow live.

Mock API keys work like the extension: any 32+ letter/digit key; the prefix picks
the scenario (`single…`, `country…`, `nongeo…`, `isp…`, `none…`, `invalid…`).

## Layout

| Width      | Layout                                                        |
|------------|---------------------------------------------------------------|
| < 600      | Phone: Home + pushed pages, bottom-sheet plan switcher        |
| 600–1023   | Tablet / unfolded foldable: navigation rail                    |
| ≥ 1024     | Desktop / tablet landscape: sidebar + location picker docked   |

Design tokens (`lib/theme/tokens.dart`) are copied 1:1 from the Shifter Panel /
extension; fonts are Geist + Geist Mono; flags and brand SVGs come from the extension.

## Location catalog

`assets/geo/catalog.json` holds every country, state, city and ISP that customers
can target, regenerated with `tool/build_geo_catalog.py` from the authorized local `weights.json` (see the script header for the commands). It keeps
**names only**, never counts: anything with fewer than 25 IPs is dropped.
Inside a country, states, cities and ISPs are ordered by live IPs (most first)
so the best targets are on top; countries stay A–Z. ISP names come
from RIPE's public AS names list, since weights.json only has AS numbers.

## Notes
- `build/` is a symlink to `~/Library/Caches/shifter_app_build`: macOS code
  signing fails on files inside the iCloud-synced Desktop folder.
