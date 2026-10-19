# Resposta a l'Adrià — les dues càrregues, el cost i les devolucions

**Per a:** adria@analitza.com
**Assumpte:** RE: Integració Analitza CM — nou origen SAP B1

*(El text per enviar comença a "Hola Adrià". Al final hi ha una nota interna que NO s'envia.)*

---

Hola Adrià,

Gràcies. Vaig per punts.

## 1. Les dues càrregues: perfecte, amb una precisió a la de SAP

KAIS i immediatament SAP resol el que et preguntava. Només un detall, perquè és del mateix tipus de
problema però pel costat contrari: **la càrrega de SAP que facis just després ha d'anar amb data mínima
el 16 de novembre**, no amb la finestra habitual dels 90 dies. Si la fas al gener amb la finestra, la
data mínima et cauria a mitjan octubre i, si reemplaça a partir d'aquí, **t'esborraria el KAIS de
mitjan octubre al 15 de novembre que acabes de carregar**. Com que la teva SQL de SAP ja filtra
`date >= '2026-11-16'`, no la reposaria ningú.

## 2. El cost: et vaig dir una cosa que no era certa, i és una bona notícia

Al correu anterior et deia que `GrossBuyPrice` és el preu de compra actual de l'article. **Ho he
mesurat i no és així**: el mateix article té valors diferents en albarans diferents (per exemple, un
`33.00` al juny i un `10.03` al setembre), o sigui que **SAP el guarda a cada línia quan es crea el
document**. Ja ve congelat de SAP, i la nostra reconstrucció setmanal no el mou.

Amb això ja no cal el que proposaves de tenir un cost congelat i un altre d'actualitzat: el que us
passaríem és sempre el de la línia. El que **sí** que canvia respecte de KAIS és el significat: és el
preu base que fa servir SAP per calcular el benefici brut de cada línia, i d'on el treu depèn de la
configuració de SAP. A les proves no coincideix sempre amb el cost que rebíeu, i hi ha línies on
val 0.

Comparteixo el teu criteri que val més un 0 que un marge que no és correcte. Ho tanco amb el Lluís, ara
que ja sabem què és el camp, i **et confirmo abans del 16** si l'omplim amb `GrossBuyPrice` o el
deixem a 0.

## 3. Devolucions: sí, hi són

A `est_linies_albara` hi van les **devolucions** i els **abonaments**, a més dels albarans, amb la
`quantity` i el `net_amount` negatius, com demana la guia. L'`id_invoice_line` diu d'on surt cada
línia: `1xxxxxxxx` albarans, `2xxxxxxxx` devolucions, `3xxxxxxxx` abonaments.

Lligat amb això, una pregunta perquè quadri de debò: la teva SQL de línies exclou
`series not in ('06','11','16','27','36','46','18')`. **Què eren aquestes set sèries a KAIS?** A SAP,
a l'entorn de proves, els albarans surten amb sèrie `66`, les devolucions amb `67` i els abonaments
amb `65`, així que ara mateix aquest filtre no exclou res. Si alguna d'aquelles sèries eren documents
que no s'havien de comptar (interns, mostres, el que fos), cal saber-ho per decidir com els
distingim a SAP.

Gràcies,
Oscar Hijazo
ohijazo@agrienergia.com

---

## Nota interna — NO s'envia

**La correcció del punt 2 és mesurada, no una hipòtesi.** El 14/10/2026, amb `--raw` contra
`DB_FARIN_TEST` (99 albarans i 10 devolucions), el `GrossBuyPrice` del mateix article canvia d'un
document a un altre llegit en el mateix moment: el `30350` val `2.0` fins al 09/09 i `0.00007` a
partir de l'11/09; el `33010` val `33.0`, `0.7636` i `10.03`. Si fos el valor actual de l'article,
seria el mateix a totes les línies. És a dir, **està guardat a la línia**. Totes les línies porten
`GrossBase = -1`, que és el codi de l'origen del preu base. Què vol dir aquest `-1` es mira a la
configuració de documents de SAP (origen del preu base del benefici brut), i és el que ha de saber el
Lluís per decidir.

**Conseqüència per a nosaltres: la congelació a `sp_load_invoice_lines` ja no cal.** Si el Lluís diu
que sí, la feina és només `Sync:CostField = "GrossBuyPrice"` a la configuració del Worker, sense
recompilar.

**Els valors de test no serveixen per jutjar si el cost és bo.** `0.00007 €` per a una farina és
absurd. És la companyia de proves, i el valor real només es podrà veure a productiva, a la qual ara no
tenim accés. Això no canvia la conclusió (el camp es guarda a la línia), però sí la decisió del
Lluís: s'ha de mirar a la SAP productiva, des de la finestra de benefici brut d'un albarà real, si els
preus base tenen sentit.

**La pregunta per al Lluís:** «Per al cost de les línies que veu Analitza, SAP ens dona el preu base del
benefici brut de cada línia (el de la finestra de benefici brut de l'albarà), guardat a la línia quan
es crea. No és el cost mitjà que donava KAIS. Prefereixes que Analitza vegi aquest valor, o un 0?»
L'Adrià ja ha dit que val més un 0 que un marge erroni.

**Les sèries s'han comprovat només a test**, on cada tipus de document té una sola sèrie. A
productiva n'hi pot haver més, i una sèrie `306` publicaria `06` i Analitza la descartaria sense que
saltés res. El `series` es calcula com `RIGHT('00' + Series, 2)` a `sp_load_invoice_lines`.

**La PD de les devolucions no s'havia contestat mai**: no surt a cap dels sis correus anteriors.
