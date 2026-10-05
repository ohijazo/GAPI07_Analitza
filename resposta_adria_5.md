# Resposta a l'Adrià (Analitza CM) — el `/100` tancat, el `product_cost` obert

**Per a:** adria@analitza.com
**CC:** lbutinya@agrienergia.com
**Assumpte:** RE: Integració Analitza CM — nou origen SAP B1

*(El text per enviar comença a "Hola Adrià". Al final hi ha una nota interna que NO s'envia.)*

---

Hola Adrià,

Gràcies, i sobretot pel `/100`: queda tancat. Us els enviem **en euros**, el `/100` el treus tu i
**nosaltres no multipliquem per 100** — si ho féssim tots dos, tornaria a desquadrar. Del filtre
`date >= '2026-11-02'`, entesos. I si encara no heu importat res a producció, **el mapatge de les
ubicacions no us cal** i no t'empipo més: el tinc guardat per si mai el demanes.

Em queden tres coses.

**1. El `product_cost` us arribarà a zero si no ho decidim.** Ho dic perquè al teu canvi hi ha
`product_cost/100`: avui aquella columna va a **0 a totes les línies**, i no és un error de càrrega.
KAIS us donava el cost de l'article **congelat al moment de l'albarà**, i Service Layer —l'API oficial
de SAP, per on hem de passar ara— **no exposa res equivalent**. El més pròxim és el preu de compra
**actual**, que coincidia amb el vostre en un 92 %, però **no és el mateix concepte** i no te'l vull
colar com si ho fos. Tal com està, el dia 2 tindríeu marges a zero i cada xifra semblaria correcta per
separat. Tria tu: **accepteu el preu de compra actual** sabent què és, **em dieu una altra definició**
i miro si la puc obtenir, o **em confirmeu que ja no el feu servir** i el deixem buit. Les tres em van
bé; el que no em va bé és arribar al dia 2 sense haver-ho dit.

**2. El `DESHABILITAT__` no és un error i val més no tapar-lo.** El 25 de setembre es va anonimitzar la
còpia de test —4.631 clients, només el camp del correu— perquè de la base de proves no surtin correus
cap a clients de debò. **Quan apuntem el procés a la SAP de producció desapareix sol.** Per això et
demanaria que **no hi posessis el `REPLACE`**: si algun dia hi torna a sortir, voldrà dir que algú ha
carregat dades de proves a producció, i això val més veure-ho. I no, **no marca clients inactius**: 849
dels 2.305 estan actius.

**3. El `discount`.** Al teu llistat no hi surt, i entenc que mantens el teu `1 - discount` i que
seguim enviant-vos el multiplicador de KAIS. **No ho tocarem si no m'ho dius**: si el canviéssim
nosaltres i tu el mantinguessis, els imports et sortirien a zero.

Dues notes curtes. Les **claus repetides** no poden passar a la nostra banda, perquè `id_invoice_line`
és clau primària: un duplicat faria fallar la càrrega. Però d'aquí surt una pregunta, millor ara que el
dia 2: el nostre `id_invoice_line` és `origen + document × 100 + línia`, el format que us donava KAIS,
i això **reserva només dos dígits per a la línia**. Teniu documents de **100 línies o més**? Si em dius
que sí, acordem el format nou abans del tall.

I dels **accents**, gràcies per trobar-ho: jo t'havia apuntat cap a la codificació del fitxer i era el
`REPLACE` del `char(160)`. Les cometes que vénen de la nostra banda les farem netejar a SAP igualment.

De **magatzem i previsions** per a en Lluís encara no em dius res. A SAP el magatzem no és una dada de
l'article sinó de **la línia del document**: avui no us el portem i afegir-lo és una columna nova, que
és contracte — digue'm nom i format, i compta que la sèrie començaria el 2 de novembre perquè la SAP de
producció arrenca sense històric. I de previsions, què demana Analitza CM com a dades d'entrada?

Gràcies,
Oscar Hijazo
ohijazo@agrienergia.com

---

## Nota interna — NO s'envia

**Tanca el `/100`**, obert des del 31/08 i tres correus. Es confirma la lliçó: una pregunta que ningú
més pot contestar es repregunta **sola**; les dues vegades que anava dins d'un correu amb altres temes,
va contestar la resta. Per això aquest correu té **tres punts numerats i prou**.

**El que queda d'ell:** el `product_cost`, magatzem i previsions (no contestat dues vegades), el «sí»
del `discount` —que no bloqueja res, perquè la decisió per defecte és no tocar-lo— i els documents de
100+ línies.

⚠️ **El `product_cost` és ara el forat gros.** Mesurat el 05/10: `dbo.est_linies_albara` té **231
línies i 231 amb `product_cost = 0`** (`Sync:CostField = "none"`, a propòsit). El seu correu demostra
que **segueix consumint la columna** —n'està canviant l'escala—, així que el dia 2 veuria marges a zero
amb cada xifra coherent amb ella mateixa: mateixa família de fallada que el `/100`. Context a §6.2:
`DLN1.StockPrice` és el cost congelat a la línia, SL no l'exposa, i `GrossBuyPrice` coincidia 48 de 52.
**Entra com a fila pròpia a la taula de dependències del runbook**, que és el que no es va fer amb el
`/100` i per això va viure cinc setmanes dins d'una llista de cinc preguntes.

**Del `DESHABILITAT__`, el que no se li diu:** que `master_name_artifacts` ja ho comptava des del 29/09
(run 166: 2.338 = 67 d'escapament CSV + 2.271 de prefix de test) i que `baseline` en té 0. I **s'omet a
propòsit** que a 26 clients el correu surt tallat per `LEFT(E_Mail, 60)`: són gairebé tots camps amb
dues adreces dins, a la productiva pràcticament desapareix, i dir-ho convidaria a demanar un canvi
d'amplada que no cal.

**Fet al nostre costat i ja al repositori:** Regla 04 i runbook §2.4 amb el `/100` acordat i el
`discount` amb decisió per defecte **NO TOCAR RES**; runbook pas **4b**, mesurar documents de 100+
línies **contra la productiva** (a test el màxim són 7); i el Worker ja va amb l'usuari **`proceso`**,
verificat amb un `--once` a `AE02SAPRDP`.
