#!/usr/bin/env python3
"""Every English catalog key the app uses, one per line (stdout).

Keys: the first string literal of each tr('...') / trf('...') call in lib/,
the Android notification strings, the native error messages Android and iOS
send to the app (shown through tr()), and every country name in
assets/geo/catalog.json.  Usage: python3 tool/i18n/keys.py > /tmp/keys.txt
"""
import json, pathlib, re

ROOT = pathlib.Path(__file__).resolve().parents[2]
CALL = re.compile(r"""\btrf?\(\s*(?:'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)")""")
# tr(cond ? 'A' : 'B'): both literals are keys.
TERNARY = re.compile(r"""\btrf?\(\s*[^'"]{1,120}?\?\s*'((?:[^'\\]|\\.)*)'\s*:\s*'((?:[^'\\]|\\.)*)'""", re.S)


def unescape(s):
    return s.replace("\\'", "'").replace('\\"', '"').replace('\\$', '$').replace('\\n', '\n').replace('\\\\', '\\')


def keys():
    out = []
    for p in sorted((ROOT / 'lib').rglob('*.dart')):
        if 'preview' in p.parts:
            continue
        text = p.read_text()
        for m in CALL.finditer(text):
            out.append(unescape(m.group(1) if m.group(1) is not None else m.group(2)))
        for m in TERNARY.finditer(text):
            out += [unescape(m.group(1)), unescape(m.group(2))]
    # Android notification (values/strings.xml) and text shown through tr(variable).
    xml = (ROOT / 'android/app/src/main/res/values/strings.xml').read_text()
    out += [unescape(v) for v in re.findall(r'<string name="[^"]+">(.*?)</string>', xml)]
    native = ROOT / 'tool/i18n/extra_keys.txt'
    out += [l for l in native.read_text().splitlines() if l.strip() and not l.startswith('#')]
    geo = json.loads((ROOT / 'assets/geo/catalog.json').read_text())
    countries = geo.get('countries', geo) if isinstance(geo, dict) else geo
    for c in countries:
        name = c.get('name') if isinstance(c, dict) else None
        if name:
            out.append(name)
    seen, uniq = set(), []
    for k in out:
        if k not in seen:
            seen.add(k)
            uniq.append(k)
    return uniq


if __name__ == '__main__':
    print('\n'.join(keys()))
