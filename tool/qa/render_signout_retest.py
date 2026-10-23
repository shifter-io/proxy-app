"""Portable HTML evidence for the sign-out fix retest. Reads no credentials."""
import base64
import html
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'qa-results' / 'signout-retest'
accounts = json.loads((OUT / 'results.json').read_text())
assert len(accounts) == 10 and all(a.get('passed') and not a.get('layoutErrors') for a in accounts)
assert '+70: All tests passed!' in (OUT / 'tests.log').read_text()
assert 'All tests passed!' in (OUT / 'macos.log').read_text()
assert 'No issues found!' in (OUT / 'analyze.log').read_text()
images = {name: 'data:image/png;base64,' + base64.b64encode((OUT / name).read_bytes()).decode()
          for a in accounts for name in a['screens']}
rows = ''.join(f"<tr><td>{html.escape(a['account'])}</td><td>{a['memberships']}</td><td>{a['usable']}</td><td>{'Available' if a['gateSettingsAvailable'] else 'Missing'}</td><td>Passed</td></tr>" for a in accounts)
cleanup = html.escape((OUT / 'cleanup.txt').read_text())
doc = '''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Shifter · Sign-out fixes verified</title>
<style>body{background:#0d1422;color:#edf2fa;font:16px/1.6 system-ui;margin:0}main{max-width:1100px;margin:auto;padding:36px 24px}h1{font-size:34px;line-height:1.2}h2{margin-top:36px}p,li{color:#bac8dc}article{background:#152235;border:1px solid #2e4d66;border-radius:12px;padding:20px;margin:14px 0}strong,.pass{color:#8ee7b6}table{border-collapse:collapse;width:100%}th,td{padding:12px;text-align:left;border-bottom:1px solid #2a3b51}select{background:#182b44;color:white;padding:10px;border:1px solid #425f81;border-radius:6px;margin:8px 12px 20px 0}img{display:block;margin:auto;max-width:100%;max-height:850px;border:1px solid #304763;border-radius:8px}.table{overflow:auto}</style>
<main><p class="pass">LOCAL RETEST · REAL ACCOUNTS · 11 OCTOBER 2026</p><h1>Both sign-out fixes verified</h1>
<article><strong>Fixed: sign-out during the desktop screen transition</strong><p>The outgoing dashboard and sidebar now tolerate cleared membership data. The real-account reproduction and native Mac smoke test pass without the previous null-assertion or overflow errors.</p></article>
<article><strong>Fixed: inactive accounts could not sign out</strong><p>NO_PLANS, RES_INACTIVE and NON_GEO_PENDING can open Settings from the membership screen, confirm Sign out, and return to login. This also works in the BOTH_ACTIVE plan chooser.</p></article>
<h2>Executed checks</h2><ul><li>20 real-account UI sign-out flows: RES_PAID, NO_PLANS, RES_INACTIVE, NON_GEO_PENDING and BOTH_ACTIVE at 320×568, 393×852, 820×1180 and 1440×900. Each used actual Settings, sign-out confirmation, transition frames, and login assertions; session removal was checked in the isolated test store.</li><li>All 10 supplied accounts authenticated and rendered at all four sizes: 40 screens without layout errors. Settings is available for every account.</li><li>40 existing API/controller/proxy regression tests passed. These use synthetic fixtures and remain separate from real-account acceptance evidence.</li><li>The native Mac test passed all 10 account states, paid Residential and ISP connect/disconnect, independent native URLSession routing, return to direct IP, and exact restoration of the original system-proxy configuration.</li><li>Flutter static analysis: no issues found.</li></ul>
<h2>Account results</h2><div class="table"><table><thead><tr><th>Account</th><th>Supported plans</th><th>Usable</th><th>Settings</th><th>Layouts</th></tr></thead><tbody>ROWS</tbody></table></div>
<p>ISP_INACTIVE still contains one usable expiring plan alongside a suspended plan. Its fixture name does not represent a fully inactive backend state.</p>
<h2>Current screenshot evidence</h2><select id="account"></select><select id="size"><option value="small-phone">Small phone</option><option value="phone" selected>Phone</option><option value="tablet">Tablet</option><option value="desktop">Desktop</option></select><img id="shot" alt="Retested account screen">
<h2>Scope</h2><p>The phone/tablet sizes above are widget renderings. Native Android and iOS were not rerun in this focused fix retest. Their previous results remain historical evidence; physical iOS connection acceptance and separate Android browser routing remain pending. This pass did not change customer plans, revoke keys, or exercise payment/exhaustion corner cases.</p>
<h2>Cleanup</h2><p>CLEANUP</p>
<script>const images=IMAGES;const names=NAMES;const a=document.querySelector('#account'),s=document.querySelector('#size'),i=document.querySelector('#shot');for(const n of names){const o=document.createElement('option');o.value=n;o.textContent=n;a.append(o)}function show(){i.src=images[a.value+'_'+s.value+'.png'];i.alt=a.value+' '+s.value}a.onchange=s.onchange=show;show();</script></main></html>'''
doc = doc.replace('ROWS', rows).replace('CLEANUP', cleanup).replace('IMAGES', json.dumps(images)).replace('NAMES', json.dumps([a['account'] for a in accounts]))
(OUT / 'report.html').write_text(doc)
print('Self-contained retest report generated with 40 embedded screenshots.')
