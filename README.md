# Shifter app (Flutter)

Desktop, tablet and mobile version of the Shifter proxy extension
(shifter-io/proxy-extension). **UI phase:** every screen runs on mock data
(`lib/data/mock_api.dart`); no traffic is routed yet.

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
- External links show a snackbar for now (needs `url_launcher`).
