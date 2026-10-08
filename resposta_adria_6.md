# Resposta a l'Adrià i en Lluís — el cost, i dos mesos que es queden congelats

**Per a:** adria@analitza.com
**CC:** lbutinya@agrienergia.com
**Assumpte:** RE: Integració Analitza CM — nou origen SAP B1

*(El text per enviar comença a "Hola Adrià". Al final hi ha una nota interna que NO s'envia.)*

---

Hola Adrià, hola Lluís,

Gràcies — amb això el `DESHABILITAT__`, el `discount` i les claus repetides queden tancats. Del
`product_cost` et contesto avall, però abans una cosa que surt del teu propi correu i que té data.

## El setembre i l'octubre es quedaran al 100 % de marge per sempre

Al teu quadre de marges, **SET i OCT de 2026 surten al 100 %**: és el cost a zero que descrius. Fins ara
això s'arreglava sol, perquè cada dia carregueu 90 dies i al canvi de mes el cost del mes -2 es
recalcula i torna a entrar.

**Això s'acaba el 2 de novembre.** La vostra càrrega nova filtra `date >= '2026-11-02'`, així que a
partir del tall no tornareu a llegir cap línia anterior i **la correcció del setembre i de l'octubre no
arribarà mai**. Pel vostre propi mecanisme, el setembre no es recalcula fins a l'1 de novembre —un dia
abans— i l'octubre no ho faria fins al desembre, que ja no existirà per a vosaltres.

O sigui que **l'última càrrega des de KAIS abans del tall és l'última oportunitat** de deixar aquells
dos mesos bé. Si no, el quadre de marges queda amb dos mesos al 100 % de manera permanent i d'aquí a
sis mesos ningú recordarà per què.

## El cost: he mirat tot el que dona SAP, i no hi ha el camp que teníeu

He llegit la llista sencera de camps de preu i cost que Service Layer dona a una línia d'albarà. **El
cost congelat al moment de l'albarà —el que us arribava de KAIS— no hi és.** Dels quatre candidats,
mesurats contra les dades que us enviàvem abans:

| Camp | Quadra amb el cost que teníeu |
|---|---|
| `StockInmPrice` | 0 % |
| `LastBuyInmPrice` | 0 % — sempre val zero |
| `GrossProfitTotalBasePrice` | és un **total de línia**, no un preu unitari |
| **`GrossBuyPrice`** (preu de compra) | **87 %** |

Així que sí, `GrossBuyPrice` és l'únic candidat real, i és el que has vist en altres clients. **Però
porta un canvi de significat que heu de saber abans de decidir:**

- **No és el cost del dia de l'albarà, és el preu de compra actual de l'article.** Per això quadra el
  87 % i no el 100 %: coincideix amb els articles que no han mogut el preu des de l'albarà.
- **No s'autocorregeix al cap de dos mesos.** No arriba tard: arriba sempre d'avui. El comportament
  que coneixeu desapareix, posem el que posem.
- Si l'adoptem, el **congelem nosaltres a la primera càrrega** de cada línia. Si no, la nostra
  reconstrucció setmanal el reescriuria amb el preu d'aquell dia i els vostres marges històrics anirien
  canviant sols.

**Lluís, la pregunta és teva i és una sola:** et serveix «el preu de compra de l'article el dia que
l'albarà entra al sistema», sabent que no és exactament el cost d'abans? Si et serveix, ho munto i
queda congelat. Si no, el deixem a zero i no ensenyem un marge que no és.

Gràcies,
Oscar Hijazo
ohijazo@agrienergia.com

---

## Nota interna — NO s'envia

**El del setembre i l'octubre no ho havia vist ell**, i surt de creuar dues coses del seu propi correu:
el `date >= '2026-11-02'` que ens va dir el 05/10 i el mecanisme d'autocorrecció que ens explica avui.
Té tres setmanes de marge i **no depèn de nosaltres**: la càrrega és seva i la font és KAIS.

**La mesura del cost ja no és una impressió.** El `$metadata` de `/b1s/v1` **no declara el tipus de les
línies** —`Document` hi té `Collection(SAPB1.DocumentLine)` i `DocumentLine` no hi és—, així que es va
haver de demanar un albarà de debò amb el mode `--raw` nou. Els quatre candidats mesurats amb `--probe`:
`StockInmPrice` 0/15, `LastBuyInmPrice` 0/15, `GrossProfitTotalBasePrice` 2/15 (és `quantitat ×
GrossBuyPrice`), `GrossBuyPrice` 13/15. Detall a §6.2 de la memòria.

**Si diuen que sí a `GrossBuyPrice`, queda feina nostra**: `Sync:CostField = "GrossBuyPrice"` i
**congelar-lo a la primera càrrega** a `sp_load_invoice_lines`. Sense la congelació, cada FULL setmanal
reescriu la història amb el preu d'avui i **cap check ho detectaria** — és la mateixa família que el
`/100` i que el `discount`.

**Si contesten només el primer punt**, repreguntar el cost sol. I a l'inrevés: el del setembre i
l'octubre és d'ells i no ens bloqueja; no s'hi ha d'insistir més d'un cop.
