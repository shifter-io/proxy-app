#!/usr/bin/env node
/**
 * Second opinion on the catalogs: a model reads each English key next to its
 * translation and lists pairs whose meaning differs (shifted rows, wrong
 * word, missing part). Country names come from CLDR and are skipped.
 *
 *   python3 tool/i18n/keys.py > /tmp/keys.txt
 *   ANTHROPIC_API_KEY=... node tool/i18n/audit.mjs /tmp/keys.txt
 *
 * Fix what it flags in tool/i18n/overrides.json and run translate.mjs again.
 */
import { readFileSync } from 'node:fs';
const keys = readFileSync(process.argv[2], 'utf8').split('\n').filter(Boolean);
const countries = new Set(JSON.parse(readFileSync('assets/geo/catalog.json', 'utf8')).countries.map((c) => c.name));
const model = keys.filter((k) => !countries.has(k));
const LOC = { es: 'Spanish', 'zh-Hans': 'Simplified Chinese', de: 'German', fr: 'French', ja: 'Japanese', ko: 'Korean', 'pt-BR': 'Brazilian Portuguese' };
const SYS = 'You audit app UI translations. For each id you get the English source and the translation. Flag ONLY pairs where the translation means something different from the source (wrong meaning, belongs to another string, missing a part, wrong language). Ignore style preferences and kept brand words. Return only JSON: {"bad": [{"id": "...", "why": "..."}]}.';
for (const [loc, name] of Object.entries(LOC)) {
  const cat = JSON.parse(readFileSync(`assets/i18n/${loc}.json`, 'utf8'));
  const bad = [];
  for (let i = 0; i < model.length; i += 60) {
    const items = Object.fromEntries(model.slice(i, i + 60).map((k, j) => [`k${i + j}`, { en: k, [loc]: cat[k] }]));
    const res = await fetch('https://api.anthropic.com/v1/messages', { method: 'POST', headers: { 'content-type': 'application/json', 'x-api-key': process.env.ANTHROPIC_API_KEY, 'anthropic-version': '2023-06-01' },
      body: JSON.stringify({ model: 'claude-sonnet-5', max_tokens: 4000, system: SYS, messages: [{ role: 'user', content: `${name} translations:\n${JSON.stringify(items, null, 1)}` }] }) });
    const t = (await res.json()).content.map((c) => c.text || '').join('');
    try { for (const b of JSON.parse(t.slice(t.indexOf('{'), t.lastIndexOf('}') + 1)).bad || []) { const k = model[+b.id.slice(1)]; bad.push(`  ${k} => ${cat[k]}  (${b.why})`); } } catch { bad.push('  (unparsable audit batch ' + i + ')'); }
  }
  console.log(`${loc}: ${bad.length} flagged`); if (bad.length) console.log(bad.join('\n'));
}
