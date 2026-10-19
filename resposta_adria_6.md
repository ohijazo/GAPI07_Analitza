# Resposta a l'Adrià — la data es mou al 16 de novembre, i el cost

**Per a:** adria@analitza.com
**Assumpte:** RE: Integració Analitza CM — nou origen SAP B1

*(El text per enviar comença a "Hola Adrià". Al final hi ha una nota interna que NO s'envia.)*

---

Hola Adrià,

Gràcies — amb això el `DESHABILITAT__`, el `discount` i les claus repetides queden tancats. Tres coses.

## 1. El tall es mou del 2 al 16 de novembre

Està previst ara per **dilluns 16 de novembre**. Et toca dues coses: el filtre passa a
**`date >= '2026-11-16'`** i **el swap de les SQL es fa el dia 16**. La nit de relleu segueix sent
diumenge → dilluns (KAIS fins al 15, SAP des del 16), o sigui que no hi ha cap dia amb insercions a
les dues bases, que era el que em preguntaves l'1 de setembre.

## 2. Això salva el setembre; l'octubre i el novembre els has de corregir tu

El 100 % de marge de SET i OCT és el cost a zero, que fins ara s'arreglava sol perquè al canvi de mes
el cost del mes −2 torna a entrar amb els 90 dies. Amb la data nova:

| Mes | El cost li entra a KAIS | Amb el tall el 16/11 |
|---|---|---|
| Setembre 2026 | l'1 de novembre | ✅ **entra sol**, dues setmanes abans del tall |
| Octubre 2026 | l'1 de desembre | ❌ ja no llegireu KAIS |
| 1–15 de novembre | l'1 de gener | ❌ ja no llegireu KAIS |

Del setembre, doncs, només cal que comprovis l'1 o el 2 de novembre que ha entrat amb cost. **Els
altres dos no els salva cap càrrega d'abans del tall**: el dia 15 el seu cost encara no existeix. La
via és la que ja vas proposar l'1 de setembre —corregir-ho amb una càrrega puntual de KAIS, que queda
viu per consulta—, amb dues precisions: **no n'hi ha prou amb el desembre**, perquè l'1–15 de novembre
no tanca fins a l'1 de gener (o dues càrregues, o una de sola al gener amb data mínima l'1 d'octubre);
i ⚠️ **em vas dir que la càrrega «reemplaça a partir de la data mínima»** — si és així, una càrrega amb
data mínima l'1 d'octubre que només porti KAIS **s'enduria el que ja hi haurà de SAP del 16 endavant?**
T'ho deixo com a pregunta perquè és del tipus que no es veu: no quedarien dades dolentes, no quedarien.

## 3. El cost: SAP no té el camp que teníeu

He llegit la llista sencera de camps de preu i cost que Service Layer dona a una línia d'albarà, i **el
cost congelat al moment de l'albarà no hi és**. Mesurats contra el que us enviàvem: `StockInmPrice` 0 %,
`LastBuyInmPrice` sempre zero, `GrossProfitTotalBasePrice` és un total de línia i no un preu unitari, i
**`GrossBuyPrice` el 87 %**. Així que sí, és l'únic candidat real i és el que has vist en altres
clients, però canvia de significat: **és el preu de compra actual de l'article, no el cost del dia de
l'albarà** —per això fa 87 % i no 100 %—, i **ja no s'autocorregeix** al cap de dos mesos. Si l'adoptem,
el congelem nosaltres a la primera càrrega; si no, la nostra reconstrucció setmanal us aniria canviant
els marges històrics sols.

**Com ho fan els clients on l'has vist?** Ho pregunto perquè tu saps què hi fa l'anàlisi de marges amb
aquest camp i jo no: donar-vos el preu de compra congelat al primer dia que veiem la línia és millor que
un zero, o és pitjor que un zero perquè sembla un cost i no ho és? Amb el que em diguis ho tanco amb el
Lluís, que és qui mira els marges, i et confirmo què hi posem.

Gràcies,
Oscar Hijazo
ohijazo@agrienergia.com

---

## Nota interna — NO s'envia

**El canvi de data arregla sol el punt que més pressa tenia.** Amb el tall el dia 2, el setembre
depenia d'una càrrega feta el dia abans; amb el 16, el seu mecanisme el corregeix l'1 de novembre i
queden dues setmanes per comprovar-ho.

**L'esborrany anterior deia que «l'última càrrega abans del tall és l'última oportunitat», i no era
exacte ni amb la data vella**: el cost de l'octubre no existeix a KAIS fins a l'1 de desembre, o sigui
que cap càrrega anterior al tall el podia portar. La via sempre va ser la càrrega puntual que ell va
proposar l'1 de setembre; el que la data nova hi afegeix és l'1–15 de novembre, que no tanca fins al
gener.

**La pregunta del `reemplaça` és el punt nou a vigilar.** Si la seva càrrega puntual esborra a partir de
la data mínima i no porta res del 16 de novembre endavant, **ens buida un mes i mig de dades de SAP** i
des d'aquí no ho veuríem: `vanished_ids` compara `dbo` contra `staging`, no el que ells tinguin
carregat. Mateixa família que el `/100`.

**La mesura del cost no és una impressió.** El `$metadata` de `/b1s/v1` no declara el tipus de les
línies —`Document` hi té `Collection(SAPB1.DocumentLine)` i `DocumentLine` no hi és—, així que es va
haver de demanar un albarà de debò amb el mode `--raw`. Amb `--probe`: `StockInmPrice` 0/15,
`LastBuyInmPrice` 0/15, `GrossProfitTotalBasePrice` 2/15 (és `quantitat × GrossBuyPrice`),
`GrossBuyPrice` 13/15. Detall a §6.2 de la memòria.

**Si diuen sí a `GrossBuyPrice`, queda feina nostra**: `Sync:CostField = "GrossBuyPrice"` i congelar-lo
a la primera càrrega a `sp_load_invoice_lines`. Sense la congelació, cada FULL setmanal reescriu la
història amb el preu d'avui i **cap check ho detectaria**.

**Si contesta només la data, repreguntar el cost sol.** El del setembre és d'ell i no ens bloqueja.

**El correu va només a l'Adrià, i això deixa una cosa oberta: la decisió del cost és del Lluís.** Aquí
només se li demana a l'Adrià què en pensa com a proveïdor de l'eina —si un cost que sembla un cost i no
ho és val més que un zero—, i amb la seva resposta s'ha de tancar amb el Lluís abans del tall. Si l'Adrià
triga, **no s'ha d'esperar**: la pregunta del Lluís es pot fer igualment, perquè les dues respostes no
depenen l'una de l'altra i el dia 16 no admet tenir-ho obert.

**Pendent al nostre costat:** el `2 de novembre` surt a una vintena de llocs del repositori
(`docs/runbook_cutover.md` —fins al títol—, `README.md`, `.claude/rules/04`, `docs/memoria_projecte.md`,
`deploy/README.md`) i als correus ja enviats a l'Olga, a Sistemes i al Carles. També mou la data límit
del 27 d'octubre demanada a Seidor per a les autoritzacions a productiva. Res d'això no s'ha tocat.
