#!/usr/bin/env python3
"""Render repository documentation to standalone HTML. Requires: pip install Markdown."""
from pathlib import Path
import base64
import html
import re
import markdown

ROOT = Path(__file__).resolve().parents[1]
CSS = '''
*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;background:#0b0e17;color:#dce4ef;font:16px/1.7 system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}main{max-width:1040px;margin:auto;padding:40px 32px 80px}a{color:#76b1ff;text-underline-offset:3px}h1,h2,h3{color:#f4f7fb;line-height:1.25;scroll-margin-top:24px}h1{font-size:clamp(28px,4vw,42px);letter-spacing:-.035em;margin:32px 0 20px}h2{font-size:26px;border-top:1px solid #25354b;padding-top:30px;margin-top:44px}h3{font-size:20px;margin-top:28px}p,li{max-width:90ch}p[align=center]{max-width:none}img{max-width:100%;height:auto}pre{background:#101c2c;border:1px solid #293b53;border-radius:12px;padding:20px;overflow:auto;font-size:13px;line-height:1.6}code{font-family:ui-monospace,SFMono-Regular,Consolas,monospace;font-size:.88em}p code,li code,td code{background:#19263a;padding:2px 5px;border-radius:4px;overflow-wrap:anywhere}.table-wrap{overflow-x:auto;margin:22px 0;border:1px solid #293b53;border-radius:12px}table{width:100%;border-collapse:collapse;font-size:14px}th,td{text-align:left;padding:13px 16px;border-bottom:1px solid #25354b;vertical-align:top;min-width:140px}th{background:#142239;color:#f4f7fb}tr:last-child td{border-bottom:0}strong{color:#f3f6fb}li{margin:5px 0}footer{margin-top:56px;border-top:1px solid #25354b;padding-top:20px;color:#9ba8ba;font-size:13px}blockquote{border-left:3px solid #579dff;margin-left:0;padding-left:20px;color:#b0bdce}@media(max-width:600px){main{padding:20px 18px 48px}pre{padding:14px}th,td{padding:10px}}@media print{body{background:white;color:#222}h1,h2,h3,strong{color:#111}a{color:#154fa5}main{max-width:none;padding:0}pre,th{background:#f4f6f8}footer{display:none}}
'''

def render(source, output, title):
    text = source.read_text()
    body = markdown.markdown(text, extensions=['tables', 'fenced_code', 'toc'])
    def embed_image(match):
        path = (source.parent / match[1]).resolve()
        if not path.is_relative_to(ROOT) or not path.is_file():
            raise ValueError(f'Missing or external image: {match[1]}')
        mime = 'image/svg+xml' if path.suffix == '.svg' else 'image/png'
        return 'src="data:' + mime + ';base64,' + base64.b64encode(path.read_bytes()).decode() + '"'
    body = re.sub(r'src="([^"]+)"', embed_image, body)
    def href(match):
        target=html.unescape(match[1])
        if target.startswith(('#','http:','https:','mailto:','data:')):return match[0]
        if source == ROOT/'README.md' and target.startswith('docs/'):
            target=target[5:]
        elif source == ROOT/'README.md' and target == 'LICENSE':
            target='third-party-notices.html#project-license'
        return 'href="'+html.escape(target,quote=True)+'"'
    body=re.sub(r'href="([^"]+)"',href,body)
    body=body.replace('<table>','<div class="table-wrap"><table>').replace('</table>','</table></div>')
    output.write_text('<!doctype html>\n<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>'+html.escape(title)+'</title><style>'+CSS+'</style></head><body><main>'+body+'<footer>Shifter Proxy App · Standalone documentation · <a href="https://github.com/shifter-io/proxy-app">Repository</a></footer></main></body></html>\n')
    print('Generated',output.relative_to(ROOT))

if __name__=='__main__':
    for source,output,title in [
        ('README.md','docs/readme.html','Shifter Proxy App — Residential & ISP Proxies'),
        ('docs/development.md','docs/development.html','Shifter Proxy App — Development'),
        ('docs/third-party-notices.md','docs/third-party-notices.html','Shifter Proxy App — Third-party Notices'),
    ]:
        render(ROOT/source,ROOT/output,title)
