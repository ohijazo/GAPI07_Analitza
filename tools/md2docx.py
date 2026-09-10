# Converteix un markdown del projecte a .docx.
# No es un conversor generic: nomes cobreix el que fem servir aqui
# (encapcalaments, taules, llistes, negreta, codi inline i blocs ```).
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
#
# Grava i comprova: torna a llegir el .docx i verifica que hi ha tot el que hi
# havia al markdown. Si no quadra, surt amb error i no deixa un Word incomplet
# amb bona pinta.
#
# I abans d'enviar res:
#
#   md2docx.py --check
#
# que diu quins .docx del repositori s'han quedat enrere del seu .md. Va passar
# amb el correu a Sistemes del 07/09/2026 i no ho va veure ningu; el detall, al
# comentari del mode --check.
import glob, hashlib, io, os, re, sys
from docx import Document
from docx.shared import Pt, RGBColor

def opt(name):
    i = sys.argv.index(name) if name in sys.argv else -1
    return sys.argv[i + 1] if 0 < i < len(sys.argv) - 1 else None

def cut(md, frm, to, fatal=True):
    """El tros del markdown que va al Word."""
    start = 0
    if frm:
        # Ancorat a inici de linia: si no, una marca citada dins d'un altre
        # paragraf (p.ex. la nota d'avis del capcal) es menjaria el tall.
        m = re.search(r'^' + re.escape(frm), md, re.M)
        if not m:
            if not fatal: return None
            sys.exit(f"No s'ha trobat la marca d'inici: {frm}")
        start = m.start()
    end = len(md)
    if to:
        i = md.find(to, start)
        if i < 0:
            if not fatal: return None
            sys.exit(f"No s'ha trobat la marca final: {to}")
        end = i + len(to)
    return md[start:end]

def segell(body, frm, to):
    h = hashlib.sha256(body.encode('utf-8')).hexdigest()[:16]
    return f'md2docx|from={frm or ""}|to={to or ""}|sha={h}'

# --- mode --check: quins .docx s'han quedat enrere del seu .md --------------
#
# La verificacio de sota comprova que la conversio no perdi text, pero NO
# hauria evitat el que va passar amb correu_sistemes_2026-09-07.docx: alla el
# markdown es va seguir editant despres de generar el Word i el conversor no es
# va tornar a executar mai. Per aixo cada .docx porta gravat un segell del tros
# de markdown d'on va sortir, i aixo el compara amb el que hi ha ara.
#
#     python tools/md2docx.py --check
if '--check' in sys.argv:
    arrel = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    problemes = 0
    for docx in sorted(glob.glob(os.path.join(arrel, '*.docx'))):
        md_path = docx[:-5] + '.md'
        nom = os.path.basename(docx)
        if not os.path.exists(md_path):
            continue
        try:
            gravat = Document(docx).core_properties.comments or ''
        except Exception as e:
            print(f'  ?  {nom}: no es pot llegir ({e})'); continue
        if not gravat.startswith('md2docx|'):
            print(f'  ?  {nom}: sense segell (generat abans que existis aquesta comprovacio)')
            continue
        parts = dict(p.split('=', 1) for p in gravat.split('|')[1:])
        body = cut(io.open(md_path, encoding='utf-8').read(),
                   parts.get('from') or None, parts.get('to') or None, fatal=False)
        if body is not None and segell(body, parts.get('from'), parts.get('to')) == gravat:
            print(f'  OK {nom}')
        else:
            print(f'  >> {nom}: NO correspon al .md actual. Torna a generar-lo abans d enviar-lo.')
            problemes += 1
    sys.exit(1 if problemes else 0)

src, dst = sys.argv[1], sys.argv[2]
md = io.open(src, encoding='utf-8').read()

frm, to = opt('--from'), opt('--to')

body = cut(md, frm, to)

doc = Document()
style = doc.styles['Normal']
style.font.name = 'Calibri'
style.font.size = Pt(11)

INLINE = re.compile(r'(\*\*\*.+?\*\*\*|\*\*.+?\*\*|`[^`]+`|\*[^*\s][^*]*\*)')

def add_runs(par, text, bold=False, italic=False):
    """Interpreta **negreta**, *cursiva*, ***totes dues*** i `codi`, amb els
    casos niats (**`codi`**). Es recursiu perque sense recursio els
    delimitadors de dins es queden literals al Word."""
    for part in INLINE.split(text):
        if not part:
            continue
        if part.startswith('***') and part.endswith('***'):
            add_runs(par, part[3:-3], bold=True, italic=True)
        elif part.startswith('**') and part.endswith('**'):
            add_runs(par, part[2:-2], bold=True, italic=italic)
        elif part.startswith('`') and part.endswith('`'):
            r = par.add_run(part[1:-1])
            r.font.name = 'Consolas'
            r.font.size = Pt(10)
            r.font.color.rgb = RGBColor(0x33, 0x33, 0x33)
            r.bold, r.italic = bold, italic
        elif part.startswith('*') and part.endswith('*'):
            add_runs(par, part[1:-1], bold=bold, italic=True)
        else:
            r = par.add_run(part)
            r.bold, r.italic = bold, italic

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

    # La firma s'acaba al primer encapcalament o separador: si no, un annex
    # despres del comiat sortiria linia a linia, sense taules ni titols.
    if in_signature and (line.startswith('#') or line.strip() == '---'):
        in_signature = False

    if line.startswith('Salutacions,') or line.startswith('Atentament,'):
        in_signature = True
    if in_signature:
        close()
        if line.strip():
            blocks.append(('sig', line.strip()))
        i += 1
        continue

    # Els blocs de codi es guarden linia a linia: ajuntar-los com un paragraf
    # normal convertiria unes comandes per copiar en un text illegible.
    if line.startswith('```'):
        close()
        i += 1
        code = []
        while i < len(lines) and not lines[i].startswith('```'):
            code.append(lines[i].rstrip())
            i += 1
        i += 1                      # la marca de tancament
        blocks.append(('code', code))
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
    elif kind == 'code':
        for ln in content:
            p = doc.add_paragraph()
            p.paragraph_format.space_after = Pt(0)
            p.paragraph_format.space_before = Pt(0)
            r = p.add_run(ln if ln.strip() else ' ')
            r.font.name = 'Consolas'
            r.font.size = Pt(9)
            r.font.color.rgb = RGBColor(0x33, 0x33, 0x33)
        doc.add_paragraph()
    elif kind == 'sig':
        p = doc.add_paragraph()
        p.paragraph_format.space_after = Pt(0)
        add_runs(p, content)
    else:
        add_runs(doc.add_paragraph(), content)

# El segell deixa gravat de quin tros de markdown ha sortit el document.
# El llegeix el mode --check per detectar Words que s'han quedat enrere.
doc.core_properties.comments = segell(body, frm, to)
doc.save(dst)

# ---------------------------------------------------------------------------
# Verificacio: el .docx ha de dir el mateix que el .md
#
# PER QUE HI ES
# El correu_sistemes_2026-09-07.docx que es va enviar a Sistemes no portava
# l'ultima seccio ni el comiat, i li faltava mig paragraf al principi. No va ser
# cap bug d'aqui: el Word es va generar a mig editar el markdown i no es va
# tornar a generar. Els dos fitxers van entrar al mateix commit i ningu va
# comparar-los. Sistemes van contestar el que els va arribar, i la pregunta que
# faltava es va donar per ignorada quan mai no la van rebre.
#
# Un conversor que grava i calla no protegeix de res: el fitxer s'obre, te bona
# pinta i li falta un tros. Per aixo torna a llegir el que ha gravat i compara
# bloc per bloc contra l'origen. Si no quadra, surt amb error i NO es pot
# enviar sense adonar-se'n.
# ---------------------------------------------------------------------------
def plain(text):
    """El text tal com add_runs l'escriu al Word, sense les marques.

    NO val esborrar els asteriscs i els accents greus a pel: 'COUNT(*)' i
    'est_*' son contingut, no format, i quedarien 'COUNT()' i 'est_'. Ha de
    passar pel mateix parser que escriu el document."""
    out = []
    for part in INLINE.split(text):
        if not part:
            continue
        if part.startswith('***') and part.endswith('***'):
            out.append(plain(part[3:-3]))
        elif part.startswith('**') and part.endswith('**'):
            out.append(plain(part[2:-2]))
        elif part.startswith('`') and part.endswith('`'):
            out.append(part[1:-1])          # el codi va literal, no es reinterpreta
        elif part.startswith('*') and part.endswith('*'):
            out.append(plain(part[1:-1]))
        else:
            out.append(part)
    return ''.join(out).strip()

check = Document(dst)
doc_text = re.sub(r'\s+', ' ', ' '.join(p.text for p in check.paragraphs))
doc_cells = [c.text.strip() for t in check.tables for row in t.rows for c in row.cells]

falta = []
for kind, content in blocks:
    if kind == 'table':
        for row in content:
            for cell in row:
                net = plain(cell)
                if net and net not in doc_cells:
                    falta.append(f'cel.la de taula: {net[:70]}')
    elif kind == 'code':
        for ln in content:
            if ln.strip() and re.sub(r'\s+', ' ', ln.strip()) not in doc_text:
                falta.append(f'linia de codi: {ln.strip()[:70]}')
    else:
        net = re.sub(r'\s+', ' ', plain(content))
        if net and net not in doc_text:
            falta.append(f'{kind}: {net[:70]}')

# Una marca de markdown que sobreviu vol dir que el format no s'ha aplicat i
# que el destinatari veu els asteriscs. Els blocs de codi en queden fora: un
# accent greu al final d'una linia de PowerShell es continuacio de linia, no
# markdown.
codi = {re.sub(r'\s+', ' ', l.strip()) for k, c in blocks if k == 'code' for l in c}
fora_de_codi = ' '.join(t for p in check.paragraphs
                        if (t := re.sub(r'\s+', ' ', p.text.strip())) and t not in codi)
restes = sorted({m for m in ('**', '`')
                 if m in fora_de_codi or any(m in c for c in doc_cells)})

if falta or restes:
    print(f'{dst}: EL DOCUMENT NO QUADRA AMB {src}', file=sys.stderr)
    for f in falta[:15]:
        print(f'   FALTA  {f}', file=sys.stderr)
    if len(falta) > 15:
        print(f'   ... i {len(falta) - 15} mes', file=sys.stderr)
    for r in restes:
        print(f'   MARCA DE MARKDOWN SENSE CONVERTIR: {r}', file=sys.stderr)
    sys.exit(1)

print(f'{dst}  ({len(doc.paragraphs)} paragrafs, {len(doc.tables)} taules)')
print(f'   verificat: {len(blocks)} blocs del markdown, tots al document')
