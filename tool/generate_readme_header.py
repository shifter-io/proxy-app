"""Build the README banner with the site's Geist font and Shifter logo.

Optional asset-generation dependencies: pip install fonttools
The generated SVG uses outlined text and needs no external fonts or assets.
"""
from pathlib import Path
import re
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.varLib.instancer import instantiateVariableFont

ROOT = Path(__file__).resolve().parents[1]
FONT = ROOT / 'assets/fonts/Geist-Regular.ttf'
fonts = {}

def text(value, x, y, size, color, weight=400):
    if weight not in fonts:
        font = TTFont(ROOT / ('assets/fonts/Geist-SemiBold.ttf' if weight >= 600 else 'assets/fonts/Geist-Medium.ttf' if weight >= 500 else 'assets/fonts/Geist-Regular.ttf'))
        if 'fvar' in font:
            font = instantiateVariableFont(font, {'wght': weight})
        fonts[weight] = font
    font = fonts[weight]
    glyphs = font.getGlyphSet()
    cmap = font.getBestCmap()
    scale = size / font['head'].unitsPerEm
    pen = SVGPathPen(glyphs)
    cursor = x
    for character in value:
        name = cmap[ord(character)]
        glyphs[name].draw(TransformPen(pen, (scale, 0, 0, -scale, cursor, y)))
        cursor += font['hmtx'][name][0] * scale
    return f'<path fill="{color}" d="{pen.getCommands()}"/>'

logo = (ROOT / 'assets/brand/shifter-wordmark.svg').read_text()
logo = re.sub(r'^.*?<svg[^>]*>|</svg>\s*$', '', logo, flags=re.S)
parts = ['''<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="380" viewBox="0 0 1200 380" role="img" aria-labelledby="title desc">
<title id="title">Residential and ISP Proxy App by Shifter</title>
<desc id="desc">Your devices. Your proxy. Your location. Residential and ISP proxy controls for desktop, mobile and tablet.</desc>
<defs><radialGradient id="glow" cx="95%" cy="30%" r="85%"><stop stop-color="#122d53"/><stop offset="1" stop-color="#0b0e17"/></radialGradient><pattern id="grid" width="40" height="40" patternUnits="userSpaceOnUse"><path d="M40 0H0V40" fill="none" stroke="#698ab3" stroke-opacity=".08"/></pattern></defs>
<rect width="1200" height="380" rx="20" fill="url(#glow)"/>
<rect width="1200" height="380" rx="20" fill="url(#grid)"/>
<rect x=".5" y=".5" width="1199" height="379" rx="20" fill="none" stroke="#25354b"/>''']
parts += [text('Proxy App',56,94,38,'#fafafa',650), '<path d="M265 57v41" stroke="#354157"/>', text('by',285,89,23,'#9ba8ba'), f'<g transform="translate(331 49) scale(.38)">{logo}</g>', text('Powered by Shifter',946,85,20,'#9ba8ba')]
parts += [text('Your devices.',56,184,52,'#fafafa',650), text('Your proxy. Your location.',56,249,48,'#579dff',650), text('Residential and ISP proxies across your screens.',56,297,23,'#b0bdce')]
for value, x, color in [('RESIDENTIAL PROXIES',58,'#76b1ff'),('ISP PROXIES',275,'#b0bdce'),('DESKTOP + MOBILE + TABLET',423,'#b0bdce'),('MIT LICENSE',710,'#b0bdce')]:
    parts.append(text(value,x,347,14,color,500))
parts += ['''<rect x="830" y="145" width="314" height="176" rx="16" fill="#0c1524" stroke="#2a405e"/>
<circle cx="853" cy="169" r="4" fill="#58bea2"/>
<path d="M846 190H1128" stroke="#293d55"/>
<rect x="850" y="239" width="274" height="42" rx="8" fill="#142943" stroke="#2a405e"/>
<path d="m1092 254 5 6-5 6m-9-6h14" fill="none" stroke="#76b1ff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>''',text('One app. Every screen.',868,175,16,'#dce7f7'),text('PROXY PLAN',850,222,11,'#91a7c5',500),text('Residential / ISP',866,265,17,'#f4f7fb',500),text('Choose a location. Connect. Browse.',850,304,12,'#91a7c5')]
parts.append('</svg>')
path = ROOT / 'docs/assets/readme-header.svg'
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text('\n'.join(parts) + '\n')
print(f'Generated {path.relative_to(ROOT)}')
