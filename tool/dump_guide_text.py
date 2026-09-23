"""Dump the text of the bundled guide PDF.

The file's fonts carry a ToUnicode CMap that pypdf's own text extraction does
not apply, so the glyph codes are mapped by hand here.
"""

import re
import sys

from pypdf import PdfReader


def cmap_of(font):
    tu = font.get('/ToUnicode')
    if tu is None:
        return {}
    text = tu.get_object().get_data().decode('latin-1')
    table = {}
    for block in re.findall(r'beginbfchar(.*?)endbfchar', text, re.S):
        for src, dst in re.findall(r'<([0-9A-Fa-f]{4})>\s*<([0-9A-Fa-f]{4})>', block):
            table[int(src, 16)] = chr(int(dst, 16))
    for block in re.findall(r'beginbfrange(.*?)endbfrange', text, re.S):
        for lo, hi, base in re.findall(
            r'<([0-9A-Fa-f]{4})>\s*<([0-9A-Fa-f]{4})>\s*<([0-9A-Fa-f]{4})>', block
        ):
            lo, hi, base = int(lo, 16), int(hi, 16), int(base, 16)
            for code in range(lo, hi + 1):
                table[code] = chr(base + code - lo)
    return table


def main(path, destination=None):
    reader = PdfReader(path)
    report = []
    for number, page in enumerate(reader.pages, 1):
        fonts = {
            name: cmap_of(font.get_object())
            for name, font in page['/Resources']['/Font'].items()
        }
        data = reader.pages[number - 1].get_contents().get_data().decode('latin-1')
        report.append(f'===== page {number} =====')
        report.extend(extract(data, fonts))
    text = '\n'.join(report)
    if destination:
        # The Windows console cannot show Cyrillic; write the report instead.
        with open(destination, 'w', encoding='utf-8') as handle:
            handle.write(text + '\n')
    else:
        print(text)


TOKEN = re.compile(
    r'(?P<font>/F\d+)\s+[\d.]+\s+Tf'
    # A new text line starts where the baseline moves: Skia emits Tm, Chrome's
    # PDF writer a Td. A horizontal Td between two glyphs is only a word gap.
    r'|(?P<open>T\*)'
    r'|(?P<move>-?[\d.]+ -?[\d.]+ (?:Tm|Td))'
    r'|(?P<text>\((?:[^()\\]|\\.)*\)|<[0-9A-Fa-f\s]*>)\s+Tj'
    r'|(?P<array>\[(?:[^\[\]]*)\])\s*TJ'
)


def unescape(string):
    out, escaped = [], False
    for char in string[1:-1]:
        if escaped:
            out.append({'n': '\n', 'r': '\r', 't': '\t'}.get(char, char))
            escaped = False
        elif char == '\\':
            escaped = True
        else:
            out.append(char)
    return ''.join(out)


def codes_of(blob, table, out):
    if blob.startswith('<'):
        digits = re.sub(r'[^0-9A-Fa-f]', '', blob)
        for i in range(0, len(digits) - 3, 4):
            out.append(table.get(int(digits[i:i + 4], 16), ''))
    else:
        for char in unescape(blob):
            out.append(table.get(ord(char), ''))


def extract(data, fonts):
    lines, current, out = [], {}, []
    for match in TOKEN.finditer(data):
        if match.group('font'):
            current = fonts.get(match.group('font'), {})
        elif match.group('open') or starts_line(match):
            if out:
                lines.append(''.join(out))
                out = []
        elif match.group('text'):
            codes_of(match.group('text'), current, out)
        elif match.group('array'):
            for piece in re.findall(r'\((?:[^()\\]|\\.)*\)|<[0-9A-Fa-f\s]*>', match.group(0)):
                codes_of(piece, current, out)
    if out:
        lines.append(''.join(out))
    return [line for line in lines if line.strip()]


def starts_line(match):
    if not match.group('move'):
        return False
    first, second, _ = match.group('move').split()
    # A relative Td that keeps the baseline is a word gap, not a new line.
    return second != '0' or match.group('move').endswith('Tm')


if __name__ == '__main__':
    main(*sys.argv[1:])
