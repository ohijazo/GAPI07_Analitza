# Resposta a l'Adrià (Analitza CM) — IDs verificats, escala del preu i famílies

**Per a:** adria@analitza.com
**CC:** lbutinya@agrienergia.com
**Assumpte:** RE: Analitza CM — nou origen SAP B1

*(El text per enviar comença a "Hola Adrià". Al final hi ha una nota interna que NO s'envia.)*

---

Hola Adrià,

Gràcies per la llista de clients i sobretot per les SQL: han estat molt més útils del que et penses,
i t'explico per què.

## Els IDs: implementat i mesurat

Ja està fet i provat contra dades reals. He agafat la teva exportació i he comparat, un a un, els
`id_client_location` que tens avui amb els que us enviarem:

| | |
|---|---|
| ids que teniu avui | 5.684 |
| **es conserven** (l'històric lliga) | **5.621 (98,9%)** |
| es perdrien | 63 |
| ubicacions noves | 30 |

Dels 63, **18 són de 13 clients que ara mateix no existeixen a la nostra SAP** i els altres 45 són
clients que a SAP tenen menys adreces d'enviament que a KAIS, i perden l'última.

Els 13 clients, per si els reconeixes: FORN DE PA L'ESTANYOL · PAN DE 2AM · EL PASTADOR DE VIC ·
THOMAS SOURDOUGH BAKERY · TASQUE MUÑOZ, SERGI · PA I DOLÇOS VALERO · CASTAÑ IBAÑEZ GLOBAL ·
MOLT OBRADOR DE PA · HUGUET SIURO, MARIA PILAR · KONAMA KARIKARI, LYDIA · LITTLE INDIA FOODS
MARBELLA · AORAA BAKERY · RIGO TRADING.

Ho he mesurat contra el nostre entorn de **test**, que és una còpia i pot anar endarrerida, així que
una part d'aquests casos probablement són només això. Ho tornaré a mesurar contra la productiva.

**Sí, m'has de tornar a passar l'exportació** just abans del tall, com apuntaves. Els clients que
doneu d'alta d'aquí al 2 de novembre no són a la que m'has enviat, i cada un que se'ns escapi us
arribarà com a client nou. Amb la llista nova torno a passar la comparació i et dic exactament quins
queden fora abans que passi, no després.

### Una cosa que ha aparegut pel camí i que val la pena que sàpigues

L'identificador té dues meitats i el camp nou només n'arreglava una. La segona —el número d'adreça—
**tampoc coincidia**.

KAIS numerava les adreces de cada client seqüencialment des de `000`. SAP les numera amb un número
intern seu que comença on li toca: un client que per vosaltres té les adreces `000`, `001`, `002`, a
SAP les té a `000`, `006`, `014`. Comptat, amb el número de SAP només quadraven **283 de 4.689
clients**; renumerant-les com feia KAIS, en quadren **4.647**.

Ja està corregit, i és el que explica que la xifra de dalt sigui 98,9% i no un 6%.

Hi ha un detall que t'afecta i que prefereixo dir-te ara: mentre les adreces només s'afegeixin, tot
és estable. Però si algú **esborra** una adreça d'enviament a SAP, les posteriors d'aquell client es
renumeren, i per vosaltres això són ubicacions que desapareixen i ubicacions noves amb l'històric
buit. Ho detectem l'endemà amb una alarma, però la detectem, no l'evitem.

La solució neta és congelar el número de cada adreça el dia del tall i fer servir la numeració
automàtica només per a les altes noves. **Ho faig si em dius que sí**; és mitja jornada i us protegeix
de per vida. Si em dius que a la pràctica no esborreu adreces, ho deixem com està i vigilem l'alarma.

## Les vostres SQL: hi ha una cosa que hem de tancar sí o sí

Aquí és on m'han servit de debò. Fas això:

```sql
product_price/100 as product_price,
product_cost/100 as product_cost,
net_amount as net_amount,
```

O sigui que **KAIS us guardava els preus en cèntims** i el `net_amount` no. Nosaltres us els
enviarem en euros, que és com els té SAP.

Si no ho toquem, el 2 de novembre els preus us arribaran cent vegades més petits, el `net_amount`
quedarà bé, i **cap validació ho detectarà** —ni les vostres ni les nostres— perquè cada xifra serà
coherent amb ella mateixa. Els marges sortirien absurds i costaria dies veure d'on ve.

**La meva proposta: treu el `/100` de les dues línies el dia del tall.** És el mateix moment en què
traurem el `1 - discount`, que ja havíem acordat. Si prefereixes que us els enviem multiplicats per
100 per no tocar res, també ho faig, però digue-m'ho: l'important és que no arribem al dia 2 sense
haver-ho decidit.

De pas, dues coses més que he vist a les vostres consultes i que et confirmo:

- **Els vostres filtres per codi de client segueixen funcionant.** `NOT LIKE '00321540-%'` i els
  altres quatre (LOGÍSTICA CRISTÓBAL, ESCOLA DE FLEQUERS, DESPESES MÀRQUETING FC, FUNDACIÓ GREMI
  FLEQUERS, CIPFP BENICARLÓ) continuen sent vàlids, perquè us enviem el codi de KAIS.
- **La llista de productes exclosos també.** Els `ItemCode` no canvien.

Us puc aplicar aquests filtres a l'origen si voleu, però **et recomano que els deixeu on són**: si
deixem d'enviar-vos un identificador, per vosaltres és un producte que ha deixat d'existir, i és
justament el que estem intentant evitar. Filtrar a l'arribada és més segur que filtrar a l'origen.

## Famílies

Perfecte, ho fem. Però abans que diguis que sí del tot, vull que sàpigues què canvia exactament,
perquè no és només el codi.

Les vostres 14 famílies actuals (`TRADICIONALS`, `KM0`, `ECOLÒGIQUES`, `GRANEL`, `PIZZA`…) són
**categories comercials**. Les de SAP són **110** i classifiquen la matèria primera: `BLAT SUPER
FORÇA`, `SEGOL PANIFICABLE`, `BLAT MITJA FORÇA`… No és la mateixa classificació amb codis nous, és
una classificació diferent. Qualsevol quadre vostre agrupat per família passarà de 14 grups a 110 i
no s'assemblarà gens.

La classificació comercial també existeix a SAP, en un camp que ja us alimenta l'atribut SUBFAMILIA,
amb valors gairebé iguals als vostres (`ESPECIFICA`, `GRANEL`, `CAN TRULL`, `PIZZA`, `SUBPRODUCTE`,
`ECOLÒGICA`, `ALTRES KM0`…). El problema és que **només 252 dels 2.028 articles el tenen informat**:
la resta es quedarien sense família.

Dues opcions, i és decisió vostra perquè depèn de com mireu les dades:

1. **Famílies = els 110 grups de SAP.** Tots els productes classificats, però el significat canvia.
2. **Famílies = la categoria comercial.** Manteniu el significat, però un 88% dels articles surt
   sense família fins que algú els classifiqui a SAP.

Si trieu la 2, us puc dir exactament quins articles queden sense classificar perquè algú d'aquí ho
completi abans del tall.

## Els atributs de client

Repassant la teva llista de camps del maig, us enviem `ZONA` i, de propina, `payment_method` i
`payment_description`, que no ens havies demanat. Però n'hi ha dos de la teva llista que **no us
arriben com a atributs**: `RAÓ SOCIAL` i `ACTIU`.

Els teniu tots dos a la taula de clients, a `name` i `active`, i em jugo que és d'allà d'on els
llegiu. Confirma-m'ho: si els necessiteu **com a atributs**, són dues columnes més i les afegeixo
sense problema, però prefereixo saber-ho ara que no pas el 2 de novembre.

## `product_cost` i el marge d'octubre

Tens raó i no te'l puc resoldre. El cost congelat al moment de l'albarà no s'exposa per l'API oficial
de SAP, que és per on hi accedim ara. El candidat més proper quadra el 92% dels casos però és un altre
concepte —el preu de compra actual— i aniria derivant sense que ningú se n'adonés. Per això ara us
arriba buit a propòsit: prefereixo que es vegi que hi falta a que sembli que hi és.

Sobre l'octubre, crec que ho has clavat: com que la SAP productiva arrenca sense els albarans
anteriors al 2 de novembre, aquelles línies no us les tornarem a enviar mai, i per tant el cost no
s'arreglarà sol com fa ara amb la finestra de 90 dies.

Entenc que la vostra càrrega **acumula** i no esborra —o sigui que l'històric que ja teniu ingerit no
el perdeu, simplement es queda amb el cost del moment. Confirma-m'ho, perquè si en realitat
substituïu la finestra sencera, això és un problema molt més gros i l'hem de tractar diferent.

Si és com penso, la teva idea és la bona: al desembre, quan els costos d'octubre ja siguin correctes,
fem una càrrega puntual apuntant a la base de dades antiga només d'aquells albarans, i després
tornem a deixar-ho com estava. Ho podem preparar amb temps i fer-ho en una tarda.

## La connexió

- **Servidor**: `AE01SAPSQL`, port 1433. No és la mateixa màquina que l'`Intercanvi` actual, o sigui
  que la teva VPN actual probablement no hi arriba.
- Passo les vostres dues IPs (`88.99.249.95` i `85.85.181.85`) a Sistemes perquè obrin la ruta.
- **La contrasenya te la passo per canal a part quan tingui la ruta confirmada.**

## Resum del que necessito de tu

1. **El `/100`: el treus tu el dia del tall, o us enviem els preus × 100?** (aquesta és la urgent)
2. **Famílies**: opció 1 o opció 2?
3. **Congelem el número d'adreça** al tall, o vigilem l'alarma?
4. **La vostra càrrega acumula o substitueix** la finestra de 90 dies?
5. **`RAÓ SOCIAL` i `ACTIU`**: els voleu com a atributs, o ja us van bé a la taula de clients?
6. L'exportació de clients actualitzada, cap a finals d'octubre.

Salutacions,
Oscar Hijazo
Agrienergia
ohijazo@agrienergia.com

---

> **Nota interna (no enviar).**
>
> **ENVIAT el 31/08/2026.** A partir d'aqui el projecte espera cinc respostes: el `/100`,
> families, congelar el numero d'adreca, si la seva carrega acumula o substitueix, i els
> atributs `RAO SOCIAL` / `ACTIU`. La urgent es el `/100`; si no contesta, insistir-hi sol.
>
> **Fet i commitejat el 28/08/2026** (`e29b22c`, `3e6ecb4`):
> - `U_FCCodiKais` / `U_FCNewCardCode` a `sap_raw.OCRD`, `U_FCCodiKais` a `sap_raw.OSLP`.
> - Vistes `etl.vw_client_code`, `etl.vw_client_ship`, `etl.vw_salesman_code`. La fórmula de
>   `id_client_location` estava repetida a vuit llocs; ara té una sola definició.
> - `discount` de `decimal(5,2)` a `decimal(9,6)` + `04_migracions.sql`.
> - La sonda pagina el cens sencer i creua contra `client_locations.csv`.
> - Desplegat a `IntercanviSAP` i validat: 5.621 de 5.684 ids conservats.
>
> **Pendent amb data (1 i 2 de novembre):**
> - **Normalitzar el `discount`** — acordat amb ell, però encara NO implementat, perquè és un canvi
>   coordinat del mateix dia. Calen les tres coses alhora o cap: `sp_load_invoice_lines` emet
>   `1 - multiplicador`; `formula_break` passa a `net_amount = price × qty × (1 - discount)`; i
>   Regla 04 + `memoria_projecte.md`, que documenten el multiplicador com si fos la convenció bona.
>   Si ell no treu el seu `1 - discount` el mateix dia, falla sorollosament (imports a zero), que és
>   el que volem.
> - **Apujar `cfg.settings.ID_DROP_MAX`** (avui 10). El run del 28/08 en va veure desaparèixer 5.655.
>   Tornar-lo a baixar l'endemà.
> - **Abaixar `cfg.settings.LINES_MIN_RATIO`** (avui 0,95): la productiva arrenca sense històric
>   d'albarans i `lines_collapsed` bloquejaria.
> - **Canviar `ServiceLayer:CompanyDb`** a `DB_FARINERA_PROD`.
> - **Repetir la comparació d'ids contra la productiva**, no contra test.
>
> **La pregunta del `/100` no la pot contestar ningú d'aquí.** És l'únic punt del correu que, si es
> queda sense resposta, produeix un error silenciós el dia del tall. Si no contesta, insistir-hi sol.
>
> **Confirmar amb qui munta la SAP productiva** si realment arrencarà sense històric d'albarans. Al
> correu anterior ja se li va dir que sí, i tot el raonament de l'octubre hi penja, però no consta
> que ningú ho hagi verificat.
>
> **Bloqueja l'enviament de credencials**: la contrasenya d'`analitza_ro` continua sent un placeholder
> desconegut. S'ha de rotar. La de `sa` també està exposada.
>
> **`OITB.U_FCCodiKais` ja no cal poblar-lo**: accepta que els ids de família canviïn. Es queda creat
> i buit, sense conseqüències.
>
> **Afegit el 31/08/2026** — la pregunta 5 (`RAÓ SOCIAL` i `ACTIU` com a atributs) surt del repàs
> de la seva llista del 12/05/2025 (`docs/correus_adria_2025-05-12.md`). Si contesta que els vol com
> a atributs són dues columnes noves a `est_atributs_client` i un canvi a
> `sp_load_client_attributes`; si diu que els llegeix de `est_clients`, es tanca el punt i no es toca
> res. El que no volem és descobrir-ho al novembre.
>
> **El discount, preparat però desactivat (31/08/2026).** El canvi de convenció està implementat i
> provat darrere de `cfg.settings.DISCOUNT_AS_PERCENT`, que val `'0'`. El dia del tall és un UPDATE,
> no una edició de SPs amb pressa. Passos i ordre a `docs/runbook_cutover.md`.
