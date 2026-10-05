# Resposta a l'Adrià (Analitza CM) — el `/100` tancat, i el `DESHABILITAT__` no s'ha de tapar

**Per a:** adria@analitza.com
**CC:** lbutinya@agrienergia.com
**Assumpte:** RE: Integració Analitza CM — nou origen SAP B1

*(El text per enviar comença a "Hola Adrià". Al final hi ha una nota interna que NO s'envia.)*

---

Hola Adrià,

Gràcies, i sobretot pel `/100`: amb el teu correu ja el tinc tancat per escrit, que era l'únic punt
que el dia del tall podia fallar sense que cap validació ho veiés. Us els enviem **en euros**, el
`/100` el treus tu, i **nosaltres no multipliquem per 100** — si ho féssim tots dos, tornaria a
desquadrar.

⚠️ **Del `discount` no dius res, i t'ho vull fer confirmar.** Entenc que mantens el teu
`1 - discount` i que seguim enviant-vos el multiplicador de KAIS (`1,00` = sense descompte, `0,90` =
10 % de descompte). Ho tenim preparat per normalitzar-ho el dia que vulguis, però **no ho tocarem si
no m'ho dius**: si el canviéssim nosaltres i tu mantinguessis el `1 - discount`, els imports et
sortirien a zero.

Del filtre `date >= '2026-11-02'`, entesos.

**Les ubicacions:** si encara no heu importat res a producció, el mapatge `id_antic → id_nou` no el
necessiteu i no t'empipo més. El tinc guardat; si mai fa falta, demana-me'l.

**La comparativa es veu millor** on havia de millorar: `address` 1.279 → 651, `zip_code` 673 → 26,
`city` 614 → 48. Els telèfons ja vénen amb aquell format de SAP.

## El `DESHABILITAT__` no és un error

Ho he mirat a SAP i té data: **el 25 de setembre es va anonimitzar la còpia de test** —4.631 clients
tocats, 2.253 amb el prefix i 2.378 amb el correu buidat— perquè de la base de proves no surtin
correus cap a clients de debò. Només afecta el camp del correu.

Dues coses per si us serveixen: **no marca clients inactius** (849 dels 2.305 estan actius), i a **26**
el correu us arriba tallat, perquè el camp té 60 caràcters heretats de KAIS i el prefix se'n menja 14.

**Quan apuntem el procés a la SAP de producció desapareix sol**, així que et demanaria que **no hi
posessis el `REPLACE`**: si algun dia el prefix hi torna a sortir, voldrà dir que algú ha carregat
dades de proves a producció, i això val més veure-ho que tapar-ho.

## Dues coses curtes

**Les claus repetides** no poden passar a la nostra banda: `id_invoice_line` és clau primària, i un
duplicat faria fallar la càrrega en comptes de deixar-te dues files.

**I una pregunta que ve d'aquí**, millor ara que el dia 2: el nostre `id_invoice_line` és
`origen + document × 100 + línia`, el format que us donava KAIS, i això **reserva només dos dígits per
a la línia**. Un document de **100 línies o més** no hi cabria. Al vostre històric n'hi ha? Si em dius
que sí, acordem el format nou abans del tall.

**Els accents:** gràcies per trobar-ho, jo t'havia apuntat cap a la codificació del fitxer i era el
`REPLACE` del `char(160)`. Les cometes que vénen de la nostra banda les farem netejar a SAP igualment.

## Magatzem i previsions (per a en Lluís)

És l'únic que em queda del correu anterior. A SAP el magatzem no és una dada de l'article sinó de **la
línia del document**; avui no us el portem i afegir-lo és una columna nova a `est_linies_albara`, que
és contracte: digue'm nom i format. Compta que la sèrie començaria el 2 de novembre, perquè la SAP de
producció arrenca sense històric documental. I de **previsions** no n'hi ha res a la guia
d'importació: què fa Analitza CM amb una previsió i quines dades demana?

Gràcies,
Oscar Hijazo
ohijazo@agrienergia.com

---

## Nota interna — NO s'envia

**Tanca el `/100`, obert des del 31/08 i tres correus.** Es confirma la lliçó: una pregunta que ningú
més pot contestar es repregunta **sola**; les dues vegades que anava dins d'un correu amb altres temes,
va contestar la resta.

**El que queda d'ell:** magatzem i previsions (no contestat dues vegades), el «sí» del `discount` —que
no bloqueja res, perquè la decisió per defecte és no tocar-lo— i els documents de 100+ línies.

**Fet al nostre costat i ja al repositori:** Regla 04 i runbook §2.4 amb el `/100` acordat i el
`discount` amb decisió per defecte **NO TOCAR RES** (`DISCOUNT_AS_PERCENT` a `'0'`); runbook pas **4b**,
mesurar documents de 100+ línies **contra la productiva** (a test el màxim són 7); i el Worker ja va
amb l'usuari **`proceso`**, verificat amb un `--once` a `AE02SAPRDP`.

**Del `DESHABILITAT__`, el que no se li diu:** que `master_name_artifacts` ja ho comptava des del
29/09 (run 166: 2.338 = 67 d'escapament CSV + 2.271 de prefix de test) i que `baseline` en té 0. El
que importa és operatiu: **que no hi posi el `REPLACE`**.

**I el que s'omet a propòsit:** que els 26 correus tallats són gairebé tots camps amb dues adreces
dins, o sigui que a la productiva el truncat pràcticament desapareix. Posar-hi el matís convidaria a
demanar un canvi d'amplada que no cal.
