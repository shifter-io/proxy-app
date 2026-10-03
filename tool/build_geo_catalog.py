#!/usr/bin/env python3
"""Builds assets/geo/catalog.json: the residential targeting catalog (countries,
states, cities and ISPs) shown in the location picker.

Source: authorized-local-catalog config/weights.json
  locations[country][region][city][member][ASN][provider] = live IP count

Only NAMES leave this script, never counts. Counts are used to drop any
country, state, city or ISP with fewer than MIN_IPS IPs, and to ORDER the
states, cities and ISPs inside a country by live IPs (most first), so the best
targets are on top. Countries stay alphabetical.

ISP names come from RIPE's public AS names list (weights.json only has AS numbers).

Usage:
  # Obtain an authorized weights.json export locally; never commit raw input.
  curl -o /tmp/asn.txt https://ftp.ripe.net/ripe/asnames/asn.txt
  python3 tool/build_geo_catalog.py /tmp/weights.json /tmp/asn.txt
"""
import json
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

MIN_IPS = 25
OUT = Path(__file__).resolve().parent.parent / 'assets' / 'geo' / 'catalog.json'


def total(node):
    if isinstance(node, (int, float)):
        return node
    return sum(total(v) for v in node.values())


def add_asns(acc, members):
    for asns in members.values():
        for asn, providers in asns.items():
            acc[asn] += total(providers)


def kept_asns(counts):
    return {a: n for a, n in counts.items() if n >= MIN_IPS and re.fullmatch(r'AS\d+', a)}


def asn_names(path):
    """'7922 COMCAST-7922 - Comcast Cable Communications, LLC, US' -> 'Comcast Cable Communications, LLC'"""
    names = {}
    for line in Path(path).read_text(encoding='utf-8', errors='replace').splitlines():
        num, _, rest = line.partition(' ')
        if not num.isdigit():
            continue
        rest = re.sub(r',\s*[A-Z]{2}$', '', rest.strip())
        handle, sep, org = rest.partition(' - ')
        name = (org if sep else handle).strip()
        # Some registry entries are only an ID or a street address; prefer the handle then.
        if not re.search(r'[A-Za-z]{3}', name) or re.match(r'^\d', name):
            name = handle.strip() if re.search(r'[A-Za-z]{3}', handle) else f'AS{num}'
        names[int(num)] = name
    return names


def country_names(codes):
    script = (
        "const d=new Intl.DisplayNames(['en'],{type:'region'});"
        "const out={};for(const c of JSON.parse(process.argv[1])){try{out[c]=d.of(c)}catch(e){out[c]=c}}"
        "console.log(JSON.stringify(out))"
    )
    return json.loads(subprocess.check_output(['node', '-e', script, json.dumps(codes)]))


def main(weights_path, asn_path):
    weights = json.loads(Path(weights_path).read_text())
    names = asn_names(asn_path)
    countries = {}
    used_asns = set()

    for cc, regions in weights['locations'].items():
        if not re.fullmatch(r'[A-Z]{2}', cc) or total(regions) < MIN_IPS:
            continue
        country_asns = defaultdict(int)
        out_regions = {}
        for region, cities in regions.items():
            region_asns = defaultdict(int)
            out_cities = {}
            for city, members in cities.items():
                city_asns = defaultdict(int)
                add_asns(city_asns, members)
                for a, n in city_asns.items():
                    region_asns[a] += n
                city_total = total(members)
                if city != '-' and city_total >= MIN_IPS:
                    out_cities[city] = (city_total, kept_asns(city_asns))
            for a, n in region_asns.items():
                country_asns[a] += n
            region_total = total(cities)
            if region != '-' and region_total >= MIN_IPS:
                out_regions[region] = (region_total, kept_asns(region_asns), out_cities)
        countries[cc.lower()] = (kept_asns(country_asns), out_regions)

    for isps, regions in countries.values():
        used_asns.update(isps)
        for _, r_isps, cities in regions.values():
            used_asns.update(r_isps)
            for _, c_isps in cities.values():
                used_asns.update(c_isps)

    cnames = country_names([c.upper() for c in countries])
    isp_names = {a: names.get(int(a[2:]), a) for a in used_asns}

    def ranked(items):
        """(name, count) pairs -> names, most IPs first, ties A-Z."""
        return [k for k, _ in sorted(items, key=lambda kv: (-kv[1], str(kv[0]).lower()))]

    def isps_ranked(counts):
        return [int(a[2:]) for a in ranked((a, n) for a, n in counts.items())]

    def build_country(cc, isps, regions):
        region_names = ranked((rn, r[0]) for rn, r in regions.items())
        out_regions = []
        city_rank = []  # every city in the country, most IPs first: [regionIndex, cityIndex]
        for ri, rn in enumerate(region_names):
            _, r_isps, cities = regions[rn]
            city_names = ranked((cn, c[0]) for cn, c in cities.items())
            out_regions.append({
                'name': rn,
                'isps': isps_ranked(r_isps),
                'cities': [{'name': cn, 'isps': isps_ranked(cities[cn][1])} for cn in city_names],
            })
            city_rank += [((ri, ci), cities[cn][0], cn) for ci, cn in enumerate(city_names)]
        city_rank.sort(key=lambda t: (-t[1], t[2].lower()))
        return {
            'code': cc,
            'name': cnames[cc.upper()],
            'isps': isps_ranked(isps),
            'regions': out_regions,
            'cityRank': [list(pos) for pos, _, _ in city_rank],
        }

    catalog = {
        'source': 'authorized weights.json (names only, min %d IPs, ordered by live IPs)' % MIN_IPS,
        'countries': [build_country(cc, *c) for cc, c in sorted(countries.items(), key=lambda kv: cnames[kv[0].upper()])],
        'isps': {str(int(a[2:])): n for a, n in sorted(isp_names.items(), key=lambda kv: int(kv[0][2:]))},
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(catalog, ensure_ascii=False, separators=(',', ':')))
    regions = sum(len(c['regions']) for c in catalog['countries'])
    cities = sum(len(r['cities']) for c in catalog['countries'] for r in c['regions'])
    print(f'{len(catalog["countries"])} countries, {regions} states, {cities} cities, {len(isp_names)} ISPs -> {OUT} ({OUT.stat().st_size // 1024} KB)')


if __name__ == '__main__':
    main(*sys.argv[1:3])
