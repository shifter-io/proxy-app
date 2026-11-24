#!/usr/bin/env node
/**
 * Fills assets/i18n/<locale>.json.
 *
 *   python3 tool/i18n/keys.py > /tmp/keys.txt
 *   ANTHROPIC_API_KEY=... node tool/i18n/translate.mjs /tmp/keys.txt [--all]
 *
 * - Country names come from CLDR (Intl.DisplayNames, by the ISO code in
 *   assets/geo/catalog.json), never from a model.
 * - Other keys are translated by a model that answers per key id (an object,
 *   not a positional list), so one dropped item cannot shift the rest.
 *   Answers that lose a {placeholder}, use a dash, or come back for the wrong
 *   ids are rejected.
 * - tool/i18n/overrides.json (hand-checked wording) is applied last.
 * - Without --all only missing keys are filled; --all redoes every model key.
 * The API key comes only from the environment (an env file, never a shared
 * command line).
 */
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const DIR = resolve(ROOT, 'assets/i18n');
const MODEL = process.env.SHIFTER_I18N_MODEL || 'claude-sonnet-5';
const LOCALES = { es: 'Spanish (Spain)', 'zh-Hans': 'Simplified Chinese', de: 'German', fr: 'French', ja: 'Japanese', ko: 'Korean', 'pt-BR': 'Brazilian Portuguese' };
// Register and formats per language, matching shifter.io.
const NOTES = {
  de: 'Address the user formally with Sie / Ihr / Ihnen, never du / dein / dich (as on shifter.io). Dates: the template "{month} {day}, {year}" becomes "{day}. {month} {year}"; short month names end with a dot where German abbreviates (Dez., Jan.), May stays Mai.',
  es: 'Address the user with tú (as on shifter.io). Dates: "{day} {month} {year}"; month abbreviations in lower case (dic., ene.).',
  fr: 'Address the user with vous. Dates: "{day} {month} {year}"; abbreviated months in lower case (déc., janv.).',
  'pt-BR': 'Address the user with você. Dates: "{day} de {month} de {year}"; abbreviated months in lower case (dez., jan.).',
  ja: 'Dates: "{year}年{month}{day}日" with month names as "12月", "1月".',
  ko: 'Dates: "{year}년 {month} {day}일" with month names as "12월", "1월".',
  'zh-Hans': 'Dates: "{year}年{month}{day}日" with month names as "12月", "1月".',
};
const SYSTEM = `You translate the interface of Shifter's proxy app (desktop and phone).
Rules, all mandatory:
- Keep these exactly as written, in Latin script: Shifter, API, IP, ISP, ASN, GB, TB, HTTP, HTTPS, SOCKS5, TLS, VPN, DNS, UDP, WebRTC, Wi-Fi, iOS, Android, macOS, Windows, Linux, Keychain, Safari, Chrome, Full Geo, Country Geo, Non-Geo.
- Preserve every {placeholder} token exactly, including the braces.
- Preserve numbers, units, punctuation style and line breaks.
- Never use em dashes. Never use emojis.
- Interface style: short, plain, the way a polished app in that language says it. Buttons stay short. Single words are UI labels (buttons, tabs, statuses).
- Quotation marks inside a translation: use the language's own (「」, « », „ “) or escape them, so the output is valid JSON.
- Input is a JSON object of id -> English text. Return only a JSON object with exactly the same ids, each mapped to its translation.`;

const [keysFile, ...flags] = process.argv.slice(2);
if (!keysFile) { console.error('usage: translate.mjs <keys.txt> [--all]'); process.exit(2); }
const all = flags.includes('--all');
const keys = readFileSync(keysFile, 'utf8').split('\n').filter((k) => k.trim());
const apiKey = process.env.ANTHROPIC_API_KEY;
const countries = JSON.parse(readFileSync(resolve(ROOT, 'assets/geo/catalog.json'), 'utf8')).countries;
const countryCode = new Map(countries.map((c) => [c.name, c.code.toUpperCase()]));
const overrides = JSON.parse(readFileSync(resolve(ROOT, 'tool/i18n/overrides.json'), 'utf8'));
const placeholders = (s) => (s.match(/\{[a-zA-Z0-9_]+\}/g) || []).sort().join();

async function askOnce(locale, items) {
  const input = Object.fromEntries(items.map((k, i) => [`k${i}`, k]));
  const res = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-api-key': apiKey, 'anthropic-version': '2023-06-01' },
    body: JSON.stringify({ model: MODEL, max_tokens: 8000, system: `${SYSTEM}\n- ${NOTES[locale]}`, messages: [{ role: 'user', content: `Translate into ${LOCALES[locale]}:\n${JSON.stringify(input, null, 1)}` }] }),
  });
  if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  const text = (await res.json()).content.map((c) => c.text || '').join('');
  const out = JSON.parse(text.slice(text.indexOf('{'), text.lastIndexOf('}') + 1));
  const ids = Object.keys(input);
  if (Object.keys(out).sort().join() !== [...ids].sort().join()) throw new Error('ids differ');
  return items.map((_, i) => out[`k${i}`]);
}

async function ask(locale, items, tries = 3) {
  for (let i = 1; ; i++) {
    try { return await askOnce(locale, items); } catch (e) { if (i >= tries) throw e; console.error(`  ${locale} retry ${i}: ${String(e.message).slice(0, 80)}`); }
  }
}

for (const locale of Object.keys(LOCALES)) {
  const file = resolve(DIR, `${locale}.json`);
  const old = existsSync(file) ? JSON.parse(readFileSync(file, 'utf8')) : {};
  const cat = {};
  const names = new Intl.DisplayNames([locale], { type: 'region' });
  for (const k of keys) if (countryCode.has(k)) cat[k] = names.of(countryCode.get(k));
  const model = keys.filter((k) => !countryCode.has(k) && !(overrides[locale] || {})[k]);
  if (!all) for (const k of model) if (typeof old[k] === 'string') cat[k] = old[k];
  const missing = model.filter((k) => !(k in cat));
  let done = 0;
  if (missing.length && !apiKey) console.error(`${locale}: ${missing.length} missing and no ANTHROPIC_API_KEY`);
  for (let i = 0; apiKey && i < missing.length; i += 30) {
    const batch = missing.slice(i, i + 30);
    const out = await ask(locale, batch);
    batch.forEach((k, j) => {
      const v = out[j];
      if (typeof v !== 'string' || placeholders(v) !== placeholders(k) || /—|–/.test(v)) { console.error(`  ${locale} rejected: ${k}`); return; }
      cat[k] = v; done++;
    });
  }
  Object.assign(cat, Object.fromEntries(Object.entries(overrides[locale] || {}).filter(([k]) => keys.includes(k))));
  const sorted = Object.fromEntries(Object.keys(cat).sort().map((k) => [k, cat[k]]));
  writeFileSync(file, JSON.stringify(sorted, null, 2) + '\n');
  console.log(`${locale}: ${keys.filter((k) => countryCode.has(k)).length} countries from CLDR, ${done} translated, ${keys.length - Object.keys(sorted).length} still missing`);
}
