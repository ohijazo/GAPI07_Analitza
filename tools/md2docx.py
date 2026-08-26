# Converteix un markdown del projecte a .docx.
# No es un conversor generic: nomes cobreix el que fem servir aqui
# (encapcalaments, taules, llistes, negreta i codi inline).
#
#   md2docx.py <font.md> <sortida.docx> [--from "<marca>"] [--to "<marca>"]
#
# Per als correus cal retallar: el .md porta la capcalera de destinataris i una
# nota interna al final que NO ha de sortir mai al Word. Exemple:
#
#   md2docx.py resposta_adria_1.md resposta_adria_1.docx \
#       --from "Hola Adria," --to "ohijazo@agrienergia.com"
#
# Per a un document normal no cal retallar res i s'omet.
import io, re, sys
from docx import Document
from docx.shared import Pt, RGBColor

src, dst = sys.argv[1], sys.argv[2]
md = io.open(src, encoding='utf-8').read()

def opt(name):
    i = sys.argv.index(name) if name in sys.argv else -1
    return sys.argv[i + 1] if 0 < i < len(sys.argv) - 1 else None

frm, to = opt('--from'), opt('--to')

start = 0
if frm:
    # Ancorat a inici de linia: si no, una marca citada dins d'un altre
    # paragraf (p.ex. la nota d'avis del capcal) es menjaria el tall.
    m = re.search(r'^' + re.escape(frm), md, re.M)
    if not m:
        sys.exit(f"No s'ha trobat la marca d'inici: {frm}")
    start = m.start()

end = len(md)
if to:
    i = md.find(to, start)
    if i < 0:
        sys.exit(f"No s'ha trobat la marca final: {to}")
    end = i + len(to)

body = md[start:end]

doc = Document()
style = doc.styles['Normal']
style.font.name = 'Calibri'
style.font.size = Pt(11)

def add_runs(par, text, bold=False):
    """Interpreta **negreta** i `codi`, inclos el cas niat **`codi`**."""
    for part in re.split(r'(\*\*[^*]+\*\*|`[^`]+`)', text):
        if not part:
            continue
        if part.startswith('**') and part.endswith('**'):
            add_runs(par, part[2:-2], bold=True)
        elif part.startswith('`') and part.endswith('`'):
            r = par.add_run(part[1:-1])
            r.font.name = 'Consolas'
            r.font.size = Pt(10)
            r.font.color.rgb = RGBColor(0x33, 0x33, 0x33)
            r.bold = bold
        else:
            par.add_run(part).bold = bold

def flush_table(rows):
    header, body_rows = rows[0], rows[1:]
    t = doc.add_table(rows=1, cols=len(header))
    t.style = 'Light Grid Accent 1'
    for i, cell in enumerate(header):
        p = t.rows[0].cells[i].paragraphs[0]
        add_runs(p, cell)
        for r in p.runs:
            r.bold = True
    for row in body_rows:
        cells = t.add_row().cells
        for i, cell in enumerate(row[:len(header)]):
            add_runs(cells[i].paragraphs[0], cell)
    doc.add_paragraph()

lines = body.split('\n')

# Al .md els paragrafs i els punts de llista van tallats a 100 columnes. Cal
# tornar a ajuntar cada bloc abans de convertir-lo, o un punt de llista de dues
# linies acaba sent un punt i un paragraf solt.
blocks = []          # (tipus, text)
buf, kind = [], None

def close():
    global buf, kind
    if buf:
        blocks.append((kind, ' '.join(buf).strip()))
    buf, kind = [], None

i = 0
in_signature = False
while i < len(lines):
    line = lines[i].rstrip()

    if line.startswith('Salutacions,') or line.startswith('Atentament,'):
        in_signature = True
    if in_signature:
        close()
        if line.strip():
            blocks.append(('sig', line.strip()))
        i += 1
        continue

    if line.startswith('|') and i + 1 < len(lines) and re.match(r'^\|[\s:-]+\|', lines[i + 1]):
        close()
        rows = []
        while i < len(lines) and lines[i].startswith('|'):
            if not re.match(r'^\|[\s:-]+\|', lines[i]):
                rows.append([c.strip() for c in lines[i].strip().strip('|').split('|')])
            i += 1
        blocks.append(('table', rows))
        continue

    if line.startswith('# ') and not line.startswith('## '):
        close(); blocks.append(('h1', line[2:]))
    elif line.startswith('### '):
        close(); blocks.append(('h3', line[4:]))
    elif line.startswith('## '):
        close(); blocks.append(('h2', line[3:]))
    elif re.match(r'^[-*]\s+', line):
        close(); kind = 'bullet'; buf = [re.sub(r'^[-*]\s+', '', line)]
    elif re.match(r'^\d+\.\s+', line):
        close(); kind = 'number'; buf = [re.sub(r'^\d+\.\s+', '', line)]
    elif line.strip() in ('', '---'):
        close()
    else:
        if kind is None:
            kind = 'para'
        buf.append(line.strip())
    i += 1
close()

for kind, content in blocks:
    if kind == 'table':
        flush_table(content)
    elif kind == 'h1':
        add_runs(doc.add_heading(level=1), content)
    elif kind == 'h2':
        add_runs(doc.add_heading(level=2), content)
    elif kind == 'h3':
        add_runs(doc.add_heading(level=3), content)
    elif kind == 'bullet':
        add_runs(doc.add_paragraph(style='List Bullet'), content)
    elif kind == 'number':
        add_runs(doc.add_paragraph(style='List Number'), content)
    elif kind == 'sig':
        p = doc.add_paragraph()
        p.paragraph_format.space_after = Pt(0)
        add_runs(p, content)
    else:
        add_runs(doc.add_paragraph(), content)

doc.save(dst)
print(f'{dst}  ({len(doc.paragraphs)} paragrafs, {len(doc.tables)} taules)')
