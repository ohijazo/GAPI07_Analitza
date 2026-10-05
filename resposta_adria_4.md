# Resposta a l'Adrià (Analitza CM) — la comparativa ha trobat un error nostre de debò

**Per a:** adria@analitza.com
**CC:** lbutinya@agrienergia.com
**Assumpte:** RE: Integració Analitza CM — nou origen SAP B1

*(El text per enviar comença a "Hola Adrià". Al final hi ha una nota interna que NO s'envia.)*

---

Hola Adrià,

Gràcies: la comparativa ha trobat **un error nostre que cap validació nostra podia veure**, i era dels
greus. Va primer, i després la resta.

## El número d'adreça estava malament

Al correu anterior et deia que les adreces ja no es renumeraven. Les vam congelar, sí,
**però vam congelar el número equivocat.** Pensàvem que era la posició de l'adreça dins del client, i
el número real de KAIS el porta el **nom** de l'adreça a dins de SAP:

```
CRD1.Address = '003-SANT QUIRZE-ST. QUIRZE'   ->   el teu -003
```

Numerant per posició, un client amb diverses adreces rebia una **permutació** dels números bons: el
nostre `00251271-001` era en realitat la teva `-002`. És el dany que em vas descriure l'1 de setembre
—l'històric d'una adreça sobre una altra— i cap xifra ho delatava.

**Corregit i publicat.** Comprovat contra el fitxer `client_locations` que em vau passar, comparant el
codi postal de cada ubicació:

| Numeració | Codis postals que quadren (de 5.618) |
|---|---|
| La que teníeu fins ara | 4.923 — **87,6 %** |
| La corregida | **5.574 — 99,2 %** |

De les **804 ubicacions que han canviat de número**, el codi postal quadrava en 132 i ara en 786. El
que queda són adreces que a KAIS no tenien codi postal i algun zero al davant.
**Val la pena que tornis a exportar i repeteixis la comparativa.**

## ⚠️ Això et desplaça l'històric de 804 ubicacions

Pel que em vas explicar l'1 de setembre, quan us deixa d'arribar un `client_location` l'esborreu
**però manteniu l'històric d'albarans**. O sigui que per a vosaltres `00251271-001` desapareix i
`00251271-002` neix, i l'històric es queda enganxat al número antic —el que estava malament— mentre el
nou arrenca buit.

**Tinc el mapatge `id_antic → id_nou` de les 804 i te'l passo com et vagi bé.** Digue'm si el
necessiteu o si encara no heu ingerit res d'aquest origen i preferiu deixar-ho córrer.

## La resta del teu document: gairebé tot és dada de SAP

- **Telèfons (4.873).** `972.210.901` → `972210901` ja arriba així de SAP: ho va fer la migració de
  KAIS a SAP, i el truncat de `+35.192.595.9332` també. Nosaltres copiem el camp tal com és.
- **Raons socials (82) i comercials (157).** Canvis reals a SAP. Els 157 que passen de `100` a `041`:
  tots dos comercials existeixen amb el codi de KAIS correcte, i a SAP aquells clients són d'una altra
  persona.
- **Cometes dobles.** Una part és de SAP —la migració hi va deixar valors amb escapament CSV en 3
  clients, 5 adreces, 25 articles i 34 correus— i ho hem d'arreglar allà.
  **Però l'altra part la genera la teva exportació:** 8 de les 10 diferències de `name` a `products`
  són el mateix nom amb cometes duplicades a la banda nova.
- **La teva eina perd la `Á` majúscula.** `RECO DE CAL TOMÁS` ens arriba bé de SAP i està bé a
  `est_clients` —comprovat byte a byte—, però al teu fitxer surt `TOM S`. La base de dades va amb la
  codificació antiga de KAIS i aquell caràcter és el que es perd; la `Ç`, la `Ñ`, la `Í` i la `Ó` les
  llegeix bé. Val la pena mirar-ho: aquestes dues coses tapen diferències de veritat.
- **Nostre, i és amplada heretada de KAIS:** `address` ajunta carrer, número i complement de SAP i es
  talla a 35; `email` es talla a 60 (a la companyia real només afecta 7 casos). Digue'm si et molesta
  i ho escurcem.
- **`01761 ESPECIFICA TURRIS` sense nom** i les **14.991 línies que desapareixen** són de la
  companyia de proves, que no té històric documental. A la real serà un altre número.
- I una del teu costat: a `invoice_lines` hi ha **4 claus repetides** que la teva eina ha deixat fora
  de la comparació. A la nostra no n'hi ha cap.

## Magatzem i previsions (per a en Lluís)

**No, un article no surt d'un sol magatzem.** A SAP el magatzem és una dada de **la línia del
document**, no de l'article; l'article té com a molt un magatzem per defecte, que és una preferència.

**Avui no el portem enlloc** i no el demanem a SAP. Es pot afegir, però vol una columna nova a
`est_linies_albara`, que és contracte: digue'm el nom i el format i ho miro.

⚠️ **Abans de demanar-ho:** la SAP de producció arrenca **sense històric documental** (blueprint
signat, cap. 17.3), així que la sèrie per magatzem començaria el 2 de novembre de 2026 i qualsevol
comparativa amb l'any anterior sortiria buida.

De **previsions** no n'hi ha res al disseny ni a la guia d'importació. Digue'm què fa Analitza CM amb
una previsió i quines dades d'entrada demana.

## El `/100`, que segueix pendent des del 31 d'agost

És **l'únic punt que el dia del tall falla en silenci**: els preus quedarien 100 vegades més petits,
el `net_amount` quedaria bé, i cap validació ho detectaria. Vosaltres dividiu `product_price` i
`product_cost` per 100; nosaltres els enviem **en euros**. Em vas dir que el `/100` el treies tu, i
necessito tenir-ho **confirmat per escrit** amb la data, perquè el canvi s'ha de fer el mateix dia als
dos costats.

Gràcies,
Oscar Hijazo
ohijazo@agrienergia.com

---

## Nota interna — NO s'envia

La comparativa del 25/09 és la **primera validació de debò contra el cens de KAIS** d'aquest projecte,
i ha trobat en una tarda el que quatre setmanes de checks no van veure. `baseline.est_*` **no és
KAIS** i ha enganyat **tres** vegades:

1. Fase 0: 534/534 contra `baseline`, que és SAP comparat amb SAP.
2. 28/08: 99,1 % **per client** — enganyós, perquè la majoria de clients tenen una sola adreça i
   quadren amb qualsevol regla. El dany vivia als que en tenen diverses.
3. 01/09: es va congelar el número, es va donar per resolt i es va escriure a `resposta_adria_3.docx`
   que estava fet.

La referència ara viu a `cfg.analitza_client_export` (`tools\Import-AnalitzaClientExport.ps1`) i la
comprovació és `sql\verify_ship_no.sql`. **Es torna a demanar l'exportació la setmana del 27-31
d'octubre**, que ja és al runbook.

**Fet el 29/09/2026:** `etl.vw_client_ship_kais_no` (la regla en un sol lloc, tolerant la cometa de
l'escapament CSV que amagava 5 adreces); la re-congelació a
`sql\migrations\2026-09-29_ship_no_from_address_prefix.sql`, **fora de `deploy.sql` a propòsit**;
`etl.sp_assign_client_ship_no` amb el prefix per a les altes noves —**requisit de cutover**, perquè a
la productiva hi ha adreces que a test no hi són—; i els checks `ship_no_prefix_mismatch` i
`master_name_artifacts`.

**Run 160 `SUCCESS`:** 804 files renumerades, `vanished_ids` WARN amb 8 (llindar 10,
**no s'ha tocat**), `ship_no_prefix_mismatch` WARN amb 4 = el baseline, `lines_orphan_client` a 0.

Els 3 clients amb dues adreces sota el mateix prefix (`C221503`, `C291071`, `C432068`) s'han deixat
com estaven: és la mateixa adreça introduïda dues vegades i inventar un desempat hauria estat pitjor.

**Si contesta llarg de magatzem i se salta el `/100`, es repregunta sola.** Ja ha passat dues vegades.
