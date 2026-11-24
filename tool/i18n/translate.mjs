#!/usr/bin/env node
/**
 * Fills assets/i18n/<locale>.json with every missing key.
 *
 *   python3 tool/i18n/keys.py > /tmp/keys.txt
 *   ANTHROPIC_API_KEY=... node tool/i18n/translate.mjs /tmp/keys.txt [--seed <dir>]
 *
 * The API key comes only from the environment (an env file, never a command
 * line you share). --seed <dir> first copies exact matches from another
 * catalog set with the same layout (the website's src/i18n), so shared
 * strings such as country names read the same as on shifter.io.
 * Idempotent: keys already in a catalog are kept.
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
- Interface style: short, plain, the way a polished app in that language says it. Buttons stay short.
- Country names: the usual name in that language.
- Quotation marks inside a translation: use the language's own (「」, « », „ “) or escape them, so the output is valid JSON.
- Return only a JSON array of translations, same order and length as the input.`;

const [keysFile, ...rest] = process.argv.slice(2);
if (!keysFile) { console.error('usage: translate.mjs <keys.txt> [--seed <dir>]'); process.exit(2); }
const seedDir = rest[0] === '--seed' ? rest[1] : null;
const keys = readFileSync(keysFile, 'utf8').split('\n').filter((k) => k.trim());
const apiKey = process.env.ANTHROPIC_API_KEY;

async function ask(locale, items, tries = 3) {
  for (let i = 1; ; i++) {
    try { return await askOnce(locale, items); } catch (e) { if (i >= tries) throw e; console.error(`  ${locale} retry ${i}: ${String(e.message).slice(0, 80)}`); }
  }
}

async function askOnce(locale, items) {
  const res = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-api-key': apiKey, 'anthropic-version': '2023-06-01' },
    body: JSON.stringify({ model: MODEL, max_tokens: 8000, system: `${SYSTEM}\n- ${NOTES[locale]}`, messages: [{ role: 'user', content: `Translate into ${LOCALES[locale]}:\n${JSON.stringify(items)}` }] }),
  });
  if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  const text = (await res.json()).content.map((c) => c.text || '').join('');
  const out = JSON.parse(text.slice(text.indexOf('['), text.lastIndexOf(']') + 1));
  if (out.length !== items.length) throw new Error(`got ${out.length} for ${items.length}`);
  return out;
}

const placeholders = (s) => (s.match(/\{[a-zA-Z0-9_]+\}/g) || []).sort().join();

for (const locale of Object.keys(LOCALES)) {
  const file = resolve(DIR, `${locale}.json`);
  const cat = existsSync(file) ? JSON.parse(readFileSync(file, 'utf8')) : {};
  let seeded = 0;
  if (seedDir && existsSync(resolve(seedDir, `${locale}.json`))) {
    const seed = JSON.parse(readFileSync(resolve(seedDir, `${locale}.json`), 'utf8'));
    for (const k of keys) if (!(k in cat) && typeof seed[k] === 'string' && placeholders(seed[k]) === placeholders(k)) { cat[k] = seed[k]; seeded++; }
  }
  const missing = keys.filter((k) => !(k in cat));
  let done = 0;
  if (missing.length && !apiKey) { console.error(`${locale}: ${missing.length} missing and no ANTHROPIC_API_KEY`); }
  for (let i = 0; apiKey && i < missing.length; i += 40) {
    const batch = missing.slice(i, i + 40);
    const out = await ask(locale, batch);
    batch.forEach((k, j) => {
      if (placeholders(out[j]) !== placeholders(k) || /—|–/.test(out[j])) { console.error(`  ${locale} skipped: ${k}`); return; }
      cat[k] = out[j]; done++;
    });
  }
  const sorted = Object.fromEntries(Object.keys(cat).sort().map((k) => [k, cat[k]]));
  writeFileSync(file, JSON.stringify(sorted, null, 2) + '\n');
  console.log(`${locale}: ${seeded} from seed, ${done} translated, ${missing.length - done} still missing`);
}
