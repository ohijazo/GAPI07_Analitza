# Resposta a l'Adrià (Analitza CM) — el `/100` tancat, i el `DESHABILITAT__` no s'ha de tapar

**Per a:** adria@analitza.com
**CC:** lbutinya@agrienergia.com
**Assumpte:** RE: Integració Analitza CM — nou origen SAP B1

*(El text per enviar comença a "Hola Adrià". Al final hi ha una nota interna que NO s'envia.)*

---

Hola Adrià,

Gràcies, i especialment pel `/100`: amb el teu correu ja el tinc **tancat per escrit**, que era l'únic
punt de tot el projecte que el dia del tall podia fallar sense que cap validació ho veiés.

## El `/100`: entesos, i no toquem res

Queda així, i ho deixo escrit perquè el dia 2 no s'hagi de recordar de memòria:

| | |
|---|---|
| `product_price` i `product_cost` | **Us els enviem en euros**, com fins ara |
| El `/100` | **El treus tu**, amb el canvi que ja tens provat |
| Nosaltres | **No multipliquem per 100.** Si ho féssim tots dos alhora, tornaria a desquadrar |

⚠️ **Una cosa que no esmentes i que et vull fer confirmar: el `discount`.** Al teu llistat de canvis no
hi surt, i per tant entenc que **mantens el teu `1 - discount`** i nosaltres seguim enviant-vos el
multiplicador de KAIS (`1,00` = sense descompte, `0,90` = 10 % de descompte). Nosaltres ho tenim
preparat per normalitzar-ho el dia que vulguis, però **no ho tocarem si no m'ho dius**: si el canviéssim
nosaltres i tu mantinguessis el `1 - discount`, els imports et sortirien a zero.

I del filtre `date >= '2026-11-02'`: entesos. Vol dir que tot el que publiquem abans del tall us és
invisible, cosa que em va bé —la SAP de producció arrenca sense històric documental—, i també que el
cost d'octubre deixa de ser un problema.

## Les ubicacions: perfecte, i gràcies per dir-ho

Si encara no heu importat res a producció i el dia del canvi feu el swap amb les SQL noves, **el
mapatge `id_antic → id_nou` no el necessiteu** i ja no t'empipo més amb això. El tinc guardat de totes
maneres: si en algun moment us fa falta, demana-me'l i te'l passo.

## La comparativa nova: la correcció es veu

Comparant les teves dues comparatives, les columnes d'adreça s'han ensorrat, que és exactament on
havia de notar-se:

| Columna | 25 de setembre | 5 d'octubre |
|---|---|---|
| `address` | 1.279 | **651** |
| `zip_code` | 673 | **26** |
| `city` | 614 | **48** |
| `country_code` | 59 | **1** |

Els telèfons (4.879) són format que ja ve així de SAP, i la resta —raons socials, comercials— són
canvis reals de dada.

## El `DESHABILITAT__`: no és un error, i val més no fer el `REPLACE`

Això té explicació i **data exacta**. Ho he mirat a SAP: **el 25 de setembre es va fer una operació
sobre 4.631 dels 4.691 clients de la companyia de proves**, que a 2.253 els va posar
`DESHABILITAT__` davant del correu i a 2.378 els el va buidar. És l'**anonimització de la còpia de
test**, perquè de la base de proves no surtin correus cap a clients de debò. Només afecta el camp del
correu electrònic: ni els noms, ni les adreces, ni els articles.

**Dues coses per si us serveixen:**

- **No marca clients inactius.** Dels 2.305 clients amb el prefix, **849 estan actius**. Si ho
  interpretéssiu com una marca de baixa, us equivocaria.
- **A 26 clients el correu us arriba tallat**, perquè el camp té 60 caràcters d'amplada (heretada de
  KAIS) i el prefix se'n menja 14.

**Quan apuntem el procés a la SAP de producció, això desapareix sol: allà els correus són els de
debò.** Per això et demanaria que **no hi posessis un `REPLACE`**: si algun dia el prefix torna a
aparèixer, voldrà dir que algú ha carregat dades de proves al sistema de producció, i això val més
veure-ho que tapar-ho. És el mateix criteri pel qual mantenim les nostres alarmes encara que a test
siguin molestes.

## Les claus repetides

Les tres de `1609777`, `1609882` i `1612956` són del fitxer que t'arriba ara de KAIS, i a la nostra
banda **no poden passar**: `id_invoice_line` és clau primària a la nostra base de dades, així que un
duplicat faria fallar la càrrega en comptes de deixar-te dues files. Tal com dius, amb el nou origen
no hauries de tornar-ne a veure.

**Una pregunta que ve d'aquí, i val més fer-la ara que el dia 2.** El nostre `id_invoice_line` es
construeix com `origen + número de document × 100 + número de línia`, que és el format que us donava
KAIS. Això **reserva només dos dígits per a la línia**: un albarà o una factura de **100 línies o més**
no hi cabria. Al vostre històric de KAIS, hi ha documents tan llargs? Si em dius que sí, ho canviem
abans del tall i acordem el format nou; si no, ho deixem com està i ho vigilem.

## Els accents i les cometes

Gràcies per trobar-ho: jo t'havia apuntat cap a la codificació del fitxer i **era el `REPLACE` del
`char(160)`**. Me'l quedo apuntat. Les cometes de l'escapament que vénen de la nostra banda —3 noms de
client, 5 adreces, 25 articles i 34 correus— les farem netejar a SAP igualment, perquè una d'aquelles
cometes ens tapava el número d'una adreça.

## Magatzem i previsions (per a en Lluís)

D'això no em dius res i és l'únic que em queda del correu anterior. Recordo les dues preguntes:

- **El magatzem**: a SAP no és una dada de l'article sinó de **la línia del document**. Avui no us el
  portem. Es pot afegir, però és una columna nova a `est_linies_albara`, que és contracte: digue'm el
  nom i el format. ⚠️ I compta que la sèrie començaria el 2 de novembre de 2026, perquè la SAP de
  producció arrenca sense històric documental.
- **Les previsions**: no n'hi ha res a la guia d'importació. Què fa Analitza CM amb una previsió i
  quines dades d'entrada demana?

Gràcies,
Oscar Hijazo
ohijazo@agrienergia.com

---

## Nota interna — NO s'envia

**Tanca el punt que portava obert des del 31/08 i tres correus.** La lliçó ja escrita es confirma: una
pregunta que ningú més pot contestar es repregunta **sola**. Les dues vegades que anava dins d'un correu
amb altres temes, va contestar la resta.

**El que queda d'ell:** magatzem i previsions (punt 4, no contestat dues vegades), el «sí» explícit del
`discount` —que no bloqueja res, perquè la decisió per defecte és no tocar-lo— i la resposta sobre
documents de 100+ línies.

**El que s'ha fet al nostre costat aquesta sessió** i que ja és al repositori:

- `.claude/rules/04` i `docs/runbook_cutover.md` §2.4: el `/100` passa de forat obert a acordat, i el
  `discount` té com a **decisió per defecte NO TOCAR RES**. `DISCOUNT_AS_PERCENT` es queda a `'0'`.
- Runbook, pas **4b** de la setmana del 27-31 d'octubre: mesurar documents de 100+ línies **contra la
  productiva**. A test el màxim són 7 línies, així que d'aquí no se'n pot dir res.
- El Worker ja va amb l'usuari **`proceso`** en comptes d'`OHijazo`, als user-secrets i a
  `AE02SAPRDP`. Verificat amb un `--once` a la màquina: `usuari=proceso` al log i `sync_state`
  segellat amb les nou entitats.

**Del `DESHABILITAT__`, el que no se li diu**: que el check `master_name_artifacts` ja el comptava des
del 29/09 (run 166: 2.338 = 67 d'escapament CSV + 2.271 de prefix de test) i que `baseline` en té 0.
La resposta que importa és operativa: **que no hi posi el `REPLACE`**, perquè taparia el senyal de
«dades de test a producció», que és dels pitjors escenaris del dia 2.

**El que no s'ha dit a propòsit:** que els 26 correus tallats són gairebé tots camps amb dues adreces
dins i cometes d'escapament, o sigui que a la productiva el truncat pràcticament desapareix. Dir-li
l'amplada de 60 ja és prou; posar-hi matisos convidaria a demanar-ne un canvi que no cal.
