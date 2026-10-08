# GAPI07_Analitza — Memòria del projecte

> Visió executiva completa: què és, com funciona, què s'ha decidit i per què, què s'ha
> trobat pel camí i què queda obert.
>
> Última actualització: **05/10/2026**

---

## 1. Què és i per què existeix

Analitza CM és la plataforma d'anàlisi comercial que fa servir Agrienergia (Farinera Corominas).
Fins ara s'alimentava de **KAIS**, l'ERP antic. Amb la migració a **SAP Business One**, KAIS deixa
de ser la font de veritat i Analitza es queda sense dades.

Aquest projecte substitueix aquell origen: extreu de SAP B1, transforma al format que KAIS
proporcionava, i publica una base de dades intermèdia de només lectura que Analitza consulta amb
**les mateixes consultes SQL que ja tenia**. Analitza no ha de canviar res.

**Cutover a productiva: 2 de novembre de 2026.** És un **tall sec**: aquell dia es comença a
treballar amb SAP i a KAIS ja no hi entren dades. No hi haurà cap període amb els dos ERPs rebent
les mateixes operacions, així que **una comparació KAIS contra SAP no serà possible mai**, ni abans
ni després. Tot el que es pugui validar abans, s'ha de validar sobre estructura i mestres.

### La restricció que ho condiciona tot

Les 8 taules `est_*` conserven els noms, columnes i semàntica de KAIS, incloses les seves rareses
(el `discount` com a multiplicador, els identificadors derivats, els imports negatius amb quantitat
negativa). No és nostàlgia: és el que evita que Analitza hagi de reescriure el seu model.

---

## 2. Arquitectura

```
SAP B1 Service Layer  (HTTPS 50000, usuari tècnic només lectura)
        │  OData v3 — Prefer: odata.maxpagesize, paginació per odata.nextLink
        ▼
SapB1AnalitzaSync.Worker  (.NET 8)
        │  SqlBulkCopy dins de transacció
        ▼
IntercanviSAP.sap_raw.*     mirall fidel de SAP, forma nativa
        │  etl.sp_load_*  (T-SQL estàtic)
        ▼
IntercanviSAP.staging.est_*
        │  etl.sp_data_quality_checks  →  etl.sp_swap_staging_to_prod
        ▼
IntercanviSAP.dbo.est_*  →  Analitza CM (usuari analitza_ro, via VPN)
```

Cada nit a les **03:00** el job `Analitza_ETL_Daily` executa dos passos: primer el Worker refresca
el mirall, després `etl.sp_run_all` transforma. Analitza es connecta **a les 05:00**, en una
connexió d'un minut (confirmat per l'Adrià, `docs/correus_adria_2025-05-12.md`). El marge real és
de dues hores, no tres.

### Per què hi ha un mirall `sap_raw`

És el nucli del disseny i val la pena entendre'l.

L'ETL original llegia SAP amb `SELECT ... FROM DB_FARINERA_TEST.dbo.OCRD JOIN CRD1 ...`, un
cross-DB directe a taules internes. Funcionava, però no està suportat per SAP (veure §3.1). El
canvi obvi hauria estat reescriure tota la transformació a .NET consumint Service Layer.

No es va fer així. El Worker **només extreu**; escriu una còpia fidel de SAP a `sap_raw`, amb els
noms i la forma natius (`OCRD.CardCode`, `validFor = 'Y'`, `CardType = 'C'`). Els stored procedures
de transformació —que és on viu tota la lògica delicada i ja validada— **no van canviar de lògica**:
només van canviar el prefix del `FROM`.

Això compra tres coses:

1. **La transformació es pot demostrar idèntica.** La sortida nova es compara fila a fila contra
   una fotografia de la sortida antiga. Si quadra, quadra de debò.
2. **El FULL RELOAD setmanal de línies passa a ser local.** Abans havia de rellegir SAP; ara llegeix
   `sap_raw`, que ja tenim aquí.
3. **Els SPs es van simplificar sols.** Sense el nom de BD variable no calia SQL dinàmic: els 8 SPs
   van passar de `sp_executesql` amb apòstrofs doblats a T-SQL estàtic i llegible.

El preu és duplicar dades de SAP al nostre servidor. A canvi del que compra, surt a compte.

### Traducció d'enums

El mirall guarda la forma de SAP, no la de Service Layer. La conversió viu en un sol lloc
(`SapEnums`) i té tests:

| Service Layer | `sap_raw` |
|---|---|
| `Valid: "tYES"` / `"tNO"` | `validFor = 'Y'` / `'N'` |
| `Frozen: "tYES"` / `"tNO"` | `frozenFor = 'Y'` / `'N'` |
| `CardType: "cCustomer"` | `CardType = 'C'` |
| `AddressType: "bo_ShipTo"` | `AdresType = 'S'` |
| `DocumentStatus: "bost_Open"` | `DocStatus = 'O'` |
| `LineType: "dlt_Comment"` | `LineType = 'T'` |

Si això es trenca, els SPs **no peten**: simplement deixen de trobar files i carreguen taules
buides. Per això té tests propis.

### Mapatge d'entitats

| Taula SAP | Entitat Service Layer | Mode de sincronització |
|---|---|---|
| `OCRD` + `CRD1` | `BusinessPartners` (amb `BPAddresses` inclòs) | Cens complet cada nit |
| `OITM` | `Items` | Cens complet |
| `OITB` | `ItemGroups` (`Number`, `GroupName`) | Cens complet |
| `OSLP` | `SalesPersons` (`SalesEmployeeCode`, `SalesEmployeeName`) | Cens complet |
| `OPYM` | **`WizardPaymentMethods`** (`PaymentMethodCode`, `Description`) | Cens complet |
| `ODLN`/`DLN1` | `DeliveryNotes` | Incremental per `UpdateDate` |
| `ORDN`/`RDN1` | `Returns` | Incremental |
| `ORIN`/`RIN1` | `CreditNotes` | Incremental |
| `OINV` | `Invoices` | Incremental |

Les quatre entitats de document són el mateix `EntityType` (`SAPB1.Document`) a Service Layer.

Els mestres van sencers cada nit perquè són petits (5.651 clients, 2.028 articles) i així es replica
exactament el `TRUNCATE + INSERT` que ja feia l'ETL, sense haver de detectar esborrats mai. La
complexitat incremental es paga només on cal: als documents, que són l'històric.

---

## 3. Decisions preses

### 3.1 Abandonar el SQL directe contra SAP

**Decisió:** cap consulta de GAPI07 llegeix taules internes de SAP. Només Service Layer.

**Per què**, els set motius que ja van fer descartar el direct-SQL a `GAPI03_CRM` el 21/08/2026:

1. No està suportat per SAP. Si s'obre una incidència i el partner detecta accés directe a taules,
   poden negar suport per aquell cas.
2. Contracte inestable entre Feature Packages. SAP pot afegir columnes, canviar tipus o deprecar
   camps en qualsevol FP. Service Layer exposa `$metadata`, que SAP es compromet a mantenir.
3. Bypass de la lògica de negoci: el SELECT directe ignora permisos, camps calculats i seguretat
   per rol.
4. Llicenciament indirecte. SAP considera l'accés directe a la base com a accés indirecte; en una
   auditoria de llicències això surt car.
5. Auditoria. Les crides a SL queden als logs de SAP. Un cross-DB SELECT no deixa cap traça.
6. Portabilitat. Si Agrienergia migra a HANA o a SAP B1 Cloud, l'accés directe desapareix.
7. Complexitat dels joins. Reproduir a mà `OCRD` + `CRD1` és fràgil.

**Quan:** ara, en dev. Fer-ho amb productiva viva costa molt més, i el cutover és justament el
moment on aquests riscos es materialitzen.

### 3.2 Eliminar el camí antic, no mantenir-lo en paral·lel

**Decisió (25/08/2026):** el SQL directe s'esborra. Fora `@SBOdb`, fora `sp_executesql`, fora
`cfg.settings.SBO_DB`.

**Per què:** un camí de tornada que existeix s'acaba fent servir. La xarxa de seguretat no és
mantenir el codi antic viu, sinó una **fotografia congelada** de la seva sortida (schema
`baseline`) contra la qual comparar.

**Conseqüència operativa:** el cutover a productiva ja no és un `UPDATE cfg.settings`. Ara és
canviar `ServiceLayer:CompanyDb` a la configuració del Worker.

`cfg.settings.SBO_DB` es va esborrar de la base de dades viva el 26/08/2026. Fins llavors hi seguia
—el script de schema no s'executa mai perquè fa `DROP TABLE dbo.est_*`— i era un parany: el dia del
cutover algú l'hauria vist amb `DB_FARINERA_TEST`, l'hauria canviat a `DB_FARINERA_PROD` pensant que
era l'interruptor, i no hauria passat res.

### 3.3 Validar contra `baseline`, no contra SAP

La fidelitat del mirall **no** es demostra comparant `sap_raw` contra les taules de SAP —això
requeriria justament l'accés que estem eliminant. Es demostra comparant la sortida final
(`staging.est_*`) contra `baseline.est_*`. Si les 8 taules quadren, el mirall és fidel per
construcció.

Efecte lateral útil: la mateixa fotografia serveix de referència per a la sonda de Fase 0, perquè
`baseline.est_clients` **ja conté** `id_client_location = CardCode-LineNum` i
`baseline.est_linies_albara` ja conté els preus i costos calculats.

### 3.4 Solució .NET pròpia, copiant el que ja funciona

Codi nou a `P:\GAPI07_Analitza\src\`, independent de GAPI03, però portant-ne el client de Service
Layer, el constructor de queries OData i el patró d'escriptura massiva. Uns 500 línies duplicades a
canvi de no acoblar dos projectes amb cicles de vida diferents.

---

## 4. El contracte amb Analitza

Això és el que no es pot trencar. Està recollit a `.claude/rules/04-contracte-analitza.md`.

- **`est_clients.id_client_location`** = `CardCode + '-' + LPAD(LineNum, 3)`. Enllaça clients,
  línies, atributs i cobraments. Si canvia, Analitza perd l'històric de tots els clients.
- **`est_linies_albara.id_invoice_line`** = `offset + DocEntry*100 + LineNum`, amb offset
  `100000000` (albarans), `200000000` (devolucions), `300000000` (abonaments). El rang identifica
  l'origen, i hi ha codi que en depèn: el mode incremental de `sp_load_invoice_lines` dedueix el
  `source` fent `(id % 100000000) / 100`.
- **`discount` és un multiplicador**, no un percentatge. `1.00` = sense descompte, `0.90` = 10% de
  descompte. La fórmula que ha de quadrar és `net_amount = product_price * quantity * discount`.
- **Devolucions i abonaments** porten `quantity` i `net_amount` negatius tots dos.
- **Formats** segons `docs\Guia de importación de datos Analitza CM v9.pdf`: dates `AAAA-MM-DD`,
  punt decimal, signe negatiu davant, imports sense IVA, `country_code` ISO 3166-1 en minúscules.
- **Camps opcionals**: a la guia d'Analitza només els marcats amb `*` són obligatoris.
  `product_cost`, `product_cost_2`, `discount`, `comments` i `holidays_*` no ho són. Això importa
  per al forat obert de §6.2.

---

## 5. Estat actual

### Desplegat i corrent (a 26/08/2026)

| Peça | Estat |
|---|---|
| BD `IntercanviSAP`, 8 taules `est_*` a `dbo` i `staging` | des del principi |
| Schema `sap_raw` (14 taules) | ✅ desplegat 24/08 |
| Schema `baseline` amb la fotografia del run 91 | ✅ pres 24/08 |
| Els 11 stored procedures, ja llegint `sap_raw` | ✅ desplegats 25/08 |
| Job `Analitza_ETL_Daily`, **2 passos** (Worker + ETL), 03:00 | ✅ desplegat 25/08 |
| Check `vanished_ids` | ✅ desplegat 26/08 |
| Login `analitza_ro`, només lectura, amb `DENY CONNECT` a `DB_FARINERA_TEST` i `SBO-COMMON` | des del principi |

**El Worker corre a `AE02SAPRDP`, no al servidor de SQL.** El job de SQL Agent apuntava a
`P:\GAPI07_Analitza\...`, i `P:` és una unitat de xarxa mapada a una carpeta personal: SQL Agent
corre com a `SYSTEM`, no la veu, i el pas fallava amb *"The process could not be created"*.

Es va decidir posar-lo al servidor d'aplicacions en comptes d'arreglar la ruta al servidor de SQL:
`AE01SAPSQL` ja fa de base de dades, de SAP i de Service Layer, i a partir del cutover és la màquina
més crítica. Procediment complet a `deploy/README.md`.

**Conseqüència de disseny:** SQL Agent no pot llançar un procés en una altra màquina, així que el
job torna a tenir **un sol pas** i són dos planificadors independents — la tasca a les 02:45 i el
job a les 03:00. La garantia que no es transformi un mirall vell ja no la dona l'ordre dels passos,
sinó la **guarda de frescor** de `sp_run_all`: si `sap_raw.sync_state` té més de
`cfg.settings.MIRROR_MAX_AGE_HOURS` hores (6), avorta amb `ABORTED_STALE_MIRROR`.

La guarda va caçar alguna cosa real la primera vegada que es va provar (26/08/2026): el mirall tenia
**24 hores** i les verificacions d'aquell matí anaven sobre dades del dia anterior. A test no es
notava perquè no havia canviat res.

🔴 **Desplegat i corrent del 16/09 al 21/09/2026 a `AE01SAPRDP`; des del 22/09 el servidor és
`AE02SAPRDP` (192.168.11.136) i el cicle nocturn NO corre.** El Worker ha d'anar a
`C:\Apps\SapB1AnalitzaSync` de la màquina nova, amb la tasca **`GAPI07 Refresca sap_raw`** cada dia
a les **02:45** amb `AGRIENERGIA\sapsistema`. Estat i passos a la secció 9, *El Worker canvia de
servidor*, i a `deploy/README.md`.

✅ **I el 17/09/2026 el pipeline va publicar per primera vegada des del 24/08** — run **139**,
`SUCCESS`. Veure *La primera publicació* més avall: va costar dos runs fallits, i cap dels dos era
una avaria.

✅ **La nit del 17 al 18/09/2026, el primer cicle complet desatès**: run **143**, `SUCCESS` en 11
segons, cap `CRITICAL`, ningú al davant. Worker a les 02:45, ETL a les 03:00, swap fet. Amb això la
cadena queda demostrada de punta a punta i el que queda del projecte és el cutover.

> El run 143 va treure un WARN nou, `volume_anomaly`: *cap línia d'albarà el 17/09*. **A
> `DB_FARINERA_TEST` això és normal** —aquella companyia té 62 línies inventades i qualsevol dia
> sense moviments el dispara—, i a productiva sí que voldrà dir alguna cosa. No s'ha de tocar el
> check per fer-lo callar a test.

**Provat pel camí real, no per l'aproximat.** La prova del migdia (`--once` a mà, 19 s, `OITM` 2.028
/ `OITB` 110 / `OSLP` 49, les xifres del run 91) corria amb `ohijazo` i **no demostrava res sobre el
compte de la tasca**. La prova bona és la de les **15:20:48**: Sistemes van llançar la tasca, va
tornar `LastTaskResult = 0`, i `sap_raw.sync_state` va quedar amb **les nou entitats** segellades a
les 13:21 UTC. Codi de sortida **i** dada escrita.

Es va demanar a Sistemes el 07/09/2026 i es va fer tot **el 16/09 per Teams**, en una tarda, després
que tres correus no ho haguessin mogut. La cronologia és a §9, *El fil amb Sistemes*; el procediment
i els errors que ja han passat, a `deploy/README.md`.

⚠️ **El dret *Log on as a batch job* de `sapsistema` està posat per directiva local, no per GPO.**
Sistemes ho van decidir així i han dit que si desapareix ja faran la GPO de domini. El que s'ha de
saber és **com es veurà si passa**: no petarà res de visible: la tasca deixarà de córrer, el mirall
es farà vell, el job de les 03:00 avortarà amb `ABORTED_STALE_MIRROR` i Analitza es quedarà congelada
amb les dades del dia abans. Es detecta a `audit.etl_runs` l'endemà al matí, i el que s'ha de fer
llavors és avisar-los, **no** apujar `MIRROR_MAX_AGE_HOURS`.

**Quatre comptes diferents, i els crea gent diferent:**

| Compte | Per a què | Qui |
|---|---|---|
| Windows (`AGRIENERGIA\sapsistema`) | Executar la tasca a `AE02SAPRDP`. El compte existeix des del 16/09/2026, però **a la màquina nova li cal el dret *Log on as a batch job*, que no s'hereta**. El nom `svc_gapi07` que surt als correus del 07 i 10/09 era la nostra proposta, no el compte real | Sistemes |
| SAP Service Layer (`GAPI07_RO`) | Llegir SAP. Ara va amb `OHijazo`, nominal | Oscar |
| SQL Server (`gapi07_worker`) | Escriure a `sap_raw`. En local encara va amb `sa` | Oscar — `sql/security/Create-WorkerUser.ps1` |
| SQL Server (`gapi07_etl`) | Context del pas del job. **Sense login**: no s'hi connecta ningú, només s'impersona | Oscar — `sql/security/create_etl_user.sql`, 31/08/2026 |

Per al de SAP hi ha guia a `docs/usuari_tecnic_sap.md`, amb un avís que pot bloquejar: **un usuari
de SAP consumeix llicència**. Si no n'hi ha cap de lliure, no es pot crear i cal decidir-ho amb el
partner. Per al de SQL hi ha un llançador que demana la contrasenya interactivament i no l'escriu
enlloc.

**`AE02SAPRDP` allotja webservices de col·laboradors externs.** Per això la configuració no va a
variables d'entorn de màquina —qualsevol procés de la màquina les llegiria— sinó a un
`appsettings.Production.json` al costat de l'executable, amb els permisos NTFS tancats al compte de
la tasca.

L'última execució verda del pipeline **antic** va ser el run 91 (24/08/2026), que és la que va
generar la fotografia `baseline`.

### Xifres reals a test (run 91)

| Taula | Files |
|---|---|
| est_clients | 5.651 |
| est_atributs_client | 5.651 |
| est_productes / est_atributs_producte | 2.028 |
| est_families_productes | 110 |
| est_agents | 49 |
| **est_linies_albara** | **62** |
| est_cobraments | 16 |

### ⚠️ `DB_FARINERA_TEST` gairebé no té documents

62 línies d'albarà repartides en 47 documents (57 albarans, 2 devolucions, 3 abonaments), entre el
18/05/2026 i el 21/08/2026. Mirant-ne el contingut són dades escrites a mà: dos articles repetits
(`30350`, `30640`), preus rodons, **tots els descomptes a 1,00**.

Té tres conseqüències que no es poden ignorar:

1. La validació de Fase 4 serà **sòlida per a clients, productes i atributs** (5.651 i 2.028 files)
   i **simbòlica per a línies d'albarà**.
2. La part més delicada de tot l'ETL —la fórmula `(1 - disc_línia) × (1 - disc_capçalera)` amb el
   seu fallback per `DiscSum`— **no queda exercitada en absolut**.
3. **El temps del backfill inicial no es pot mesurar a test.** 47 documents per OData és
   instantani; l'històric real de la farinera no. I aquesta és la xifra que decideix si el cicle
   cap entre les 03:00 i les 05:00.

Si Sistemes pot refrescar el test amb una còpia de productiva, la qualitat de la validació canvia
d'ordre de magnitud.

### Migració a Service Layer

| Fase | Estat |
|---|---|
| 0a — Fotografia `baseline` | ✅ Presa 24/08/2026, lligada al run 91 |
| 0b — Sonda `--probe` | ✅ Executada, veure §6 |
| 1 — Schema `sap_raw` | ✅ Escrit i desplegat (14 taules, buides) |
| 2 — Worker .NET 8 | ✅ Compila amb 0 warnings, 23 tests verds |
| 3 — Els 8 SPs repuntats | ✅ Escrits, **no desplegats encara** |
| 4 — Validació contra `baseline` | ✅ 25/08/2026: **7 de 8 taules idèntiques** |
| 5 — Tall i neteja | ⏳ Falta revocar l'accés directe a `DB_FARINERA_TEST` |

### Resultat de la Fase 4 (25/08/2026)

Mirall omplert en **19 segons**, els 11 SPs desplegats, `sp_run_all @SkipSwap=1 @ForceFullLines=1`
en 0,6 s amb 0 warnings, i `verify_migration.sql`:

| Taula | Files diferents |
|---|---|
| est_agents · est_clients · est_productes · est_families_productes · est_atributs_client · est_atributs_producte · est_cobraments | **0** |
| est_linies_albara | 124 (= les 62 línies, comptades en tots dos sentits) |

Les 124 files difereixen **només** a `product_cost`: `product_price`, `discount` i `net_amount`
quadren al cèntim. Les dues seccions bloquejants —`id_client_location` i `id_invoice_line` que
apareixen o desapareixen— surten **buides**: el contracte amb Analitza es manté intacte.

La causa és el forat B2 (§6.2): `Sync:CostField` val `StockInmPrice`, que a totes les línies és 0.

**Bug trobat per aquesta validació, i és el motiu pel qual es fa.** A la primera passada
`sp_load_invoice_lines` va carregar **0 línies** tenint-ne 57 al mirall. `SapEnums.LineType`
traduïa una línia normal a NULL, i el filtre dels SPs és `LineType <> 'T'`: `NULL <> 'T'` no és
cert sinó desconegut, així que descartava tot. A SAP una línia normal és cadena buida, no NULL.

El greu no és el bug, és que **hauria passat desapercebut**: els checks de qualitat van donar 0
crítics, perquè amb la taula buida no hi ha orfes i el check de volum anòmal tampoc salta.
Corregit, amb test de regressió. Regla que se'n deriva: *un camp que s'utilitza dins d'un predicat
no pot tenir NULL com a valor per defecte.*

Els SPs nous no s'han desplegat deliberadament: amb el mirall buit deixarien el job en `BLOCKED`
cada nit.

---

## 6. Resultats de la sonda de Fase 0

Executada el 25/08/2026 contra `DB_FARINERA_TEST` via
`https://192.168.11.238:50000/b1s/v1/`.

### 6.1 B1 — `BPAddress.RowNum` és `CRD1.LineNum` — ✅ TANCAT

**534 adreces ship-to comprovades, 534 coincidents (100,0%)** contra `baseline.est_clients`.

`RowNum` es pot fer servir com a `LineNum`. **Els `id_client_location` no canvien** i no cal la
taula de mapatge `crd1_linenum_map` que s'havia previst com a pla B.

Era el risc més gros de tota la migració: si hagués fallat, Analitza hauria perdut l'històric de
tots els clients.

### 6.2 B2 — Quin camp fa de `DLN1.StockPrice` — ⚠️ OBERT

52 línies comparades:

| Candidat | Coincidència |
|---|---|
| `product_cost == StockInmPrice` | 0/52 (0,0%) |
| `product_cost == GrossBuyPrice` | 48/52 (92,3%) |

Les 4 que discrepen:

| id_invoice_line | cost a `baseline` | `GrossBuyPrice` | article |
|---|---|---|---|
| 100002400 | 32,6761 | 33,0000 | 33010 |
| 100003000 | 0,3243 | 0,3400 | 30150 |
| 100004400 | 0,2632 | 0,2826 | 30370 |
| 100004402 | 5,0000 | 10,0000 | 01010 |

No hi ha ràtio constant entre les dues columnes. La lectura és que **`DLN1.StockPrice` és el cost
mitjà en el moment de l'albarà, congelat a la línia**, mentre que `GrossBuyPrice` és el preu de
compra actual de l'article. Coincideixen el 92% del temps només perquè la majoria d'articles no
han mogut el cost des de l'albarà.

Són **conceptes diferents**, no el mateix camp amb un altre nom. Service Layer no exposa cap
propietat equivalent a `StockPrice`.

#### ✅ I el 08/10/2026 això deixa de ser una impressió: s'ha llegit la llista sencera

La conclusió de dalt sortia d'haver provat **dos** candidats que algú va triar, no d'haver mirat què
dona SL. Es va mirar, i va caldre arribar-hi per dos camins perquè **el `$metadata` de `/b1s/v1` no
declara el tipus de les línies**: `Document` hi té `DocumentLines Collection(SAPB1.DocumentLine)`, però
`DocumentLine` **no és enlloc** del document, ni com a `EntityType` ni com a `ComplexType`. La manera
d'esbrinar-ho és **demanar un albarà de debò** (mode `--raw`, afegit aquell dia).

Els camps de preu/cost que SL dona a una línia de document són, sencers:

`GrossBuyPrice` · `GrossPrice` · `GrossProfitTotalBasePrice` · `LastBuyInmPrice` · `Price` ·
`PriceAfterVAT` · `StockInmPrice` · `UnitPrice` (més `CostingCode*`, que són dimensions d'anàlisi, i
`StockDistributesum*`, que són repartiments de despeses)

**`StockPrice` no hi és.** I els dos candidats que mai s'havien provat, mesurats amb `--probe`:

| Candidat | Coincidència amb `baseline.product_cost` |
|---|---|
| `StockInmPrice` | 0/15 |
| **`LastBuyInmPrice`** | **0/15** — sempre val 0 |
| **`GrossProfitTotalBasePrice`** | **2/15** — i no és un preu unitari: a `id=100004402` val `20,00` amb cost `5,00` i `GrossBuyPrice` `10,00`, o sigui **`quantitat × GrossBuyPrice`**, un total de línia |
| `GrossBuyPrice` | 13/15 (86,7 %) |

(15 línies i no 52 perquè la sonda mira tres mesos enrere i els documents de test són de maig a agost.
Les dues que fallen són les de sempre, `100004400` i `100004402`.)

**Conclusió, ara defensable:** l'opció real és `GrossBuyPrice` o res. I `GrossBuyPrice` **no és el cost
del moment de l'albarà**: és el preu de compra **actual** de l'article. Si s'adopta, s'ha de **congelar
a la primera càrrega**, perquè la reconstrucció completa setmanal el tornaria a escriure amb el preu
d'avui i els marges històrics anirien derivant en silenci.

> La resta de camins possibles —el cost mitjà de l'article a `Items`, o per magatzem a
> `ItemWarehouseInfoCollection`— tenen **el mateix problema conceptual**: són el valor d'avui, no el del
> dia de l'albarà. No s'han mesurat perquè no canviarien la decisió.

**`product_cost` SÍ que el consumeix Analitza.** Ho diu el correu de l'Adrià del 12/05/2025
(`docs/correus_adria_2025-05-12.md`): a la seva llista de camps de LINIES ALBARÀ hi ha
`product_cost`. Així que l'opció de deixar-lo buit queda descartada sense parlar-ho amb ells, encara
que la seva guia el marqui com a opcional.

En canvi **`product_cost_2` no és a la seva llista**: aquest sí que el podem ignorar.

**Recomanació:** no substituir-ho silenciosament per `GrossBuyPrice`. Alimenta anàlisi de marges;
un cost que va derivant no es detectaria mai i corrompria les seves conclusions. Les opcions:

1. **Acordar amb l'Adrià una definició de cost obtenible per Service Layer** i documentar-la com un
   canvi de semàntica respecte del que rebien de KAIS.
2. Acceptar `GrossBuyPrice` com a aproximació, **dient-ho per escrit** perquè ells sàpiguen què
   estan mirant.
3. Deixar-lo buit — només si ells confirmen que ja no el fan servir.

### 6.3 `PriceBefDi` és `UnitPrice` o `Price` — ⚠️ NO CONCLOENT

| Candidat | Coincidència |
|---|---|
| `product_price == UnitPrice` | 52/52 (100,0%) |
| `product_price == Price` | 52/52 (100,0%) |
| línies on `UnitPrice != Price` | **0/52 (0,0%)** |

Els dos donen 100%, i això **no vol dir que l'haguem encertat**: vol dir que com que cap línia de
la mostra porta descompte, `UnitPrice` i `Price` valen exactament el mateix i la mostra no els sap
distingir.

De moment es queda el default `UnitPrice`, que és el que diu la documentació de la DI API
(`UnitPrice` ↔ `PriceBefDi`, `Price` ↔ preu ja descomptat). Però **no està provat**.

Per què importa: si s'encerta al revés, el `net_amount` surt malament i el check `formula_break`
**no ho detecta**, perquè el resultat queda coherent amb ell mateix. Un error silenciós en els
imports que veu Analitza.

Cal una mostra amb descomptes de línia —dades reals— per tancar-ho.

### 6.4 Continuitat d'IDs de KAIS a SAP — parcialment TRENCADA

Analitza construeix el seu històric sobre els IDs que li arribaven de KAIS. Al cutover passen a ser
els de SAP; si no coincideixen, l'històric deixa de lligar. Mesurat amb la sonda el 25/08/2026:

| Dimensió | Es manté? | Dades |
|---|---|---|
| **Comercials** | ❌ **No** | 48 de 49 tenen `SalesPerson.U_FCCodiKais` informat, i **només 2 de 48** coincideixen amb el `id_salesman` que emet l'ETL. Ex.: SlpCode 2 → `'002'`, però a KAIS era `'006'` |
| **Famílies** | ❌ **No** | `ItmsGrpCod` és una seqüència interna de SAP (108, 109, 110...). Però **110 de 110** noms de grup tenen format `<codi>-<descripció>`: `109 = "010001-BLAT SUPER FORÇA"` |
| **Productes** | ✔️ **Sí** | Confirmat per l'Oscar (25/08/2026): a la migració es van preservar. Els `ItemCode` tenen format llegat (`00010`, `00020`, `00340`) |
| **Clients** | ❌ **No, i sense pont** | `BusinessPartner.U_SEICodienllac` només està informat en **10 de 500**, i la numeració no lliga amb el `CardCode` (`C201128` ↔ `201011`). **Correcció del 10/09/2026: aquesta lectura era equivocada** — el camp no és cap pont al codi de KAIS, és l'enllaç al client predecessor, i per això només l'omplen els qui n'han substituït un altre. Veure §6.4b |
| **Línies d'albarà** | — | Derivats de document + línia. L'Adrià ja va dir que no li preocupen |

**Conseqüències:**

**Proposta enviada a l'Adrià** (`resposta_adria_1.md`): en comptes de resoldre cada dimensió d'una
manera diferent, **un camp `U_FCCodiKais` a cada mestre de SAP** que guardi el codi antic, i emetre
sempre aquest cap a Analitza.

| Mestre | Camp | Estat |
|---|---|---|
| `OSLP` | `U_FCCodiKais` | ja existeix i està poblat (48 de 49) |
| `OCRD` | `U_FCCodiKais` + `U_FCNewCardCode` | a crear |
| `OITB` | `U_FCCodiKais` | a crear |
| `OITM` | — | no cal: el `ItemCode` de SAP ja és el de KAIS |

Per què un camp i no retallar el codi del nom del grup, que a les famílies també funcionaria: n'hi
hauria prou que algú reanomenés un grup perquè es trenqués en silenci. Un camp propi no es trenca.

Els UDFs **els crea i els omple l'Oscar** (26/08/2026); als consultors de SAP només se'ls comunica,
per `comunicacio_udfs_sap.docx`.

**Estat a 26/08/2026:** els tres camps ja estan **creats** a SAP i, després de reiniciar el Service
Layer, són **llegibles** des del pipeline. Encara no s'ha poblat cap: `U_FCCodiKais` va a 0/500 als
clients i 0/110 a les famílies. La sonda `--probe` ara reporta aquesta cobertura a cada execució,
que és el que cal vigilar fins a l'1 de novembre. Si l'Adrià accepta la proposta, la feina és: crear els UDFs a SAP,
afegir-los a `sap_raw`, i canviar
`sp_load_salesmen`, `sp_load_product_categories` i `sp_load_clients` perquè els projectin amb la
regla **`id = COALESCE(U_FCCodiKais, <codi SAP>)`**: qui ve de KAIS manté el seu codi, qui és nou
porta el de SAP. Els dos formats no es poden trepitjar (8 dígits vs `C` + 6).

**Estat a 28\08\2026 — `OCRD.U_FCCodiKais` poblat.** Mesurat amb `--probe` contra `DB_FARINERA_TEST`:

| Mestre | Cobertura | Pendent |
|---|---|---|
| `OCRD` (clients) | **4.689 de 4.691** | `01` (*test1*) i `C001024` (*MASTER FURROW, S.L. DIRECCIO*) |
| `OSLP` (comercials) | 48 de 49 | el que falta és `SlpCode = -1`, el pseudo-comercial "cap"; l'ETL ja el mapeja a `'000'` |
| `OITB` (famílies) | **0 de 110** | tot |
| `OCRD.U_FCNewCardCode` | 0 | correcte: només s'omple als canvis de raó social |

El format confirma la regla que als 500 primers no es veia: `C001025 ↔ '00001025'`, o sigui
`CardCode = 'C' + els 6 últims dígits del codi de KAIS`. Però **no s'ha de derivar per fórmula**,
sinó llegir el camp: és exactament el que es va donar per bo el 11\08 i era fals.

Dues coses que aquesta mesura va destapar de la sonda mateixa, i que s'han corregit:

- La cobertura de clients es calculava sobre **la primera pàgina** (500 de 4.691) i es presentava
  sense dir-ho. Un `99,6%` sobre una mostra no diu res del cens; ara `--probe` pagina el
  `BusinessPartners` sencer i llista els `CardCode` que queden buits.
- `4689/4691` s'imprimia com a **`100,0%`**. Amb un decimal, dos clients desapareixen de l'informe i
  qui el llegeix dóna la població per tancada. Ara, mentre en falti un, s'escriu `<100,0%`.

La llista de pendents **no es pot filtrar pels clients actius**: `sp_load_clients` emet tots els
`cCustomer`, i als de baixa només els canvia el flag `active`. Un client donat de baixa sense codi
també arriba a Analitza, i també hi arriba com a client nou.

**Encaix contra el cens de KAIS (28\08\2026).** «Quants camps estan plens» no és la pregunta: un
`U_FCCodiKais` ple amb un codi que no és de KAIS compta com a ple i trenca l'històric igual, i dos
clients de SAP amb el mateix codi fusionarien dos clients d'Analitza en un. La referència **no pot
ser `baseline.est_clients`**: a l'entorn de test la fotografia es va prendre amb el pipeline antic ja
apuntat a SAP, i per tant ja porta `CardCode`s (`C001025-000`). L'únic cens de KAIS que existeix és
l'exportació que ens passa Analitza. La sonda la llegeix de `Sync:KaisClientExportPath`
(`docs/client_locations.csv`).

Contra l'exportació del 27\08\2026 (4.702 clients):

| | |
|---|---|
| codis de KAIS amb client a SAP | **4.689 de 4.702** |
| codis a `U_FCCodiKais` que no són de cap KAIS | **0** — la població és neta, cap codi inventat |
| codis de KAIS duplicats a SAP | **0** — cap fusió de dos clients en un |
| clients d'Analitza que es perdrien | **13**, 12 d'ells actius |

Els 13: `00241441` FORN DE PA L'ESTANYOL · `00251299` PAN DE 2AM · `00271547` EL PASTADOR DE VIC ·
`00281362` THOMAS SOURDOUGH BAKERY · `00301196` TASQUE MUÑOZ, SERGI · `00321868` PA I DOLÇOS VALERO ·
`00321869` CASTAÑ IBAÑEZ GLOBAL · `00321870` MOLT OBRADOR DE PA · `00321871` HUGUET SIURO ·
`00331163` KONAMA KARIKARI · `00432081` LITTLE INDIA FOODS MARBELLA (amb 6 ship-to) ·
`00432082` AORAA BAKERY · `00440004` RIGO TRADING (inactiu).

**Avís sobre aquesta xifra:** està mesurada contra `DB_FARINERA_TEST`. Part dels 13 poden existir a
la productiva i ser només un desfasament de la còpia de test. S'ha de tornar a mesurar contra
`DB_FARINERA_PROD` abans de donar cap d'aquests casos per bo.

### 6.4b `U_SEICodienllac` no era el que ens pensàvem (10/09/2026)

El 25/08 la sonda va mirar `OCRD.U_SEICodienllac` buscant-hi el codi de KAIS, va veure 10 clients de
500 informats i una numeració que no lligava, i el va **descartar com a pont**. Aquella conclusió va
quedar escrita a la taula de §6.4, a `comunicacio_udfs_sap.md` i a la mateixa sonda, que fins ara
l'etiquetava «camp descartat com a pont». Sobre aquesta base es va crear `OCRD.U_FCNewCardCode` per
guardar el client successor en un canvi de raó social.

**El camp ja feia exactament això.** `U_FCNewCardCode` el duplicava i s'ha retirat.

La mesura, ampliant `--probe` sobre el cens sencer de `DB_FARINERA_TEST`:

| | |
|---|---|
| Clients amb `U_SEICodienllac` informat | 160 de 4.691 (3,4%) |
| Resolen amb el valor tal qual | **0** |
| Resolen contra `U_FCCodiKais` omplint zeros fins a 8 | **160** |
| Resolen contra `CardCode` posant-hi la `C` al davant | 159 |
| Apunten al propi client | 0 |
| De client viu a client de baixa | **108** |
| De client de baixa a client viu | 2 |
| Predecessors amb més d'un successor | 1 (`C211608` ← `C211534`, `C301563`) |
| Cadenes (A substitueix B, que substituïa C) | 20 |

Dues coses que canvien la implementació:

1. **El valor no ve tal com està a l'altra banda.** Hi falten els zeros de l'esquerra i la `C`. Amb
   una comparació directa el JOIN no lliga cap fila, `new_code` surt NULL per a tothom i cap
   validació ho detecta. És el mode de fallada de sempre (§8).
2. **El camp apunta ENRERE.** Guarda el predecessor, no el successor, i `new_code` demana el codi
   nou. Emetre'l tal qual lligaria l'històric al revés i Analitza acumularia les vendes al registre
   mort. Per això `etl.vw_client_successor` **inverteix** la relació, i com que la inversió no és
   1:1 tria un sol successor amb `TOP 1` (el viu; entre dos de vius, el `CardCode` més alt) i avisa
   amb el check `new_code_ambiguous`.

La lliçó no és sobre aquest camp: és que **es va mesurar la cobertura d'un camp sense saber què hi
havia d'haver dins**. Un 3% és una xifra dolenta si el camp ha de portar el codi antic de tothom, i
és exactament la xifra correcta si el que porta és qui substitueix qui. La cobertura sola no
respon res.

Resultat: `new_code` passa de 0 a 168 files a `staging.est_clients`, i `id_client_location` no es
mou (les mateixes 5.647 diferències contra `baseline` que abans del canvi).

### 6.5 El número d'adreça tampoc era el de KAIS (28\08\2026)

> ⚠️ **SUPERAT EL 29/09/2026 — veure §6.5b.** La conclusió d'aquesta secció
> (renumerar 0,1,2… per `LineNum`) era la SEGONA hipòtesi de tres, i també era falsa. El número
> de KAIS viu al prefix `NNN-` del nom de l'adreça de SAP. Es deixa sencera perquè la seqüència
> dels tres errors és el que impedeix tornar-hi.

`id_client_location` té dues meitats i el `U_FCCodiKais` només arregla l'esquerra. En comparar la
sortida sencera contra l'exportació d'Analitza va sortir que **la dreta també estava trencada**:

| | clients que quadren |
|---|---|
| `CRD1.LineNum` (el que hi havia) | **283 de 4.689** (6%) |
| renumerant 0,1,2… per client | **4.647 de 4.689** (99,1%) |

KAIS numerava les adreces de cada client **seqüencialment des de 000**. El `LineNum` de SAP és un
número de fila intern i comença on li toca: `00251182` té les adreces a `000, 006, 014`, i a Analitza
són `000, 001, 002`.

**Per què no es va veure a la Fase 0.** La sonda va donar 534/534 coincidències, però contra
`baseline.est_clients`, que a l'entorn de test ja és sortida del pipeline apuntat a SAP. Comparava
SAP amb SAP: el que demostrava és que `BPAddress.RowNum == CRD1.LineNum`, no que cap dels dos fos el
número que Analitza té a l'històric. És **el mateix error** que prendre `baseline` com a cens de
KAIS, i les dues vegades el símptoma va ser un 100% tranquil·litzador. El veredicte B1 de la sonda
ara ho diu explícitament.

Resolt amb `etl.vw_client_ship` (`ROW_NUMBER() OVER (PARTITION BY CardCode ORDER BY LineNum) - 1`).

**El que costava, i com s'ha tancat (01/09/2026).** Amb el número calculat al vol, esborrar una
adreça renumerava totes les posteriors del mateix client. L'Adrià va explicar que al seu costat això
no deixa un forat: quan deixa d'arribar-los un `client_location` l'esborren de l'aplicació **però
mantenen l'històric d'albarans**, i si més endavant neix una adreça amb aquell número, se l'emporta
tot. O sigui que renumerar **enganxa l'històric d'una adreça a una altra** — un client veuria compres
que no ha fet — i totes les xifres quadren amb elles mateixes.

Ara el número viu a **`cfg.client_ship_no`**, que l'assigna `etl.sp_assign_client_ship_no` una sola
vegada i no el torna a tocar. Les adreces noves agafen `max+1` del seu client, així que un número
alliberat per un esborrat **no es reutilitza mai**.

La clau és `(CardCode, LineNum)` i no `(CardCode, Address)`: el `LineNum` de SAP no es renumera quan
s'esborra una germana —per això hi ha forats—, mentre que amb el nom de l'adreça, esborrar-ne una i
crear-ne una altra amb el mateix nom reutilitzaria el número, que és justament el que s'evita.

Provat: la primera execució reprodueix **exactament** els 5.651 identificadors d'avui (0 desapareguts,
0 nous), esborrar l'adreça del mig deixa la següent al seu número, i una alta nova agafa el següent
lliure i no el buit.

⚠️ **`cfg.client_ship_no` no és una taula derivada**: és estat que no es pot regenerar. Si es perd,
tots els números es recalculen. Ha d'entrar al backup i no l'ha de truncar ningú.

### 6.5b El número d'adreça, tercera iteració: era al nom de l'adreça de SAP (29\09\2026)

⚠️ **El que diu la secció 6.5 està superat, i val la pena llegir les dues seguides**: és la tercera
vegada que aquest número es dona per resolt, i cada vegada la mesura semblava tancar el tema.

La comparativa que l'Adrià va enviar el **25/09/2026** (`comparativa farinera 25-09-26.txt`) marcava
5.088 de 5.651 `client_locations` com a modificats. Ell ho atribuïa a una neteja de dades, i la major
part ho era. Però a sota hi havia **804 ubicacions apuntant a l'adreça equivocada**.

**El número de KAIS viu al PREFIX del nom de l'adreça de SAP**, `CRD1.Address`, on el va deixar la
migració KAIS→SAP amb el format `NNN-<nom del client>-<abreviatura de ciutat>`:

```
C251271 / LineNum 4    '000-CREATIVE FOODING SL-BARCELONA'   ship_no congelat 0   OK
C251271 / LineNum 12   '002-CREATIVE FOODING SL-BARCELONA'   ship_no congelat 1   MAL
C251271 / LineNum 14   '001-CREATIVE FOODING SL-BARCELONA'   ship_no congelat 2   MAL
```

Renumerar 0,1,2… per `LineNum` no era un desplaçament: era una **permutació**. Per a Analitza això no
és un forat, és l'històric d'una adreça sobre una altra — exactament el dany que `cfg.client_ship_no`
existeix per evitar.

#### Els tres mesuraments, i per què cada un va enganyar

| Quan | Contra què | Resultat | Per què era fals |
|---|---|---|---|
| Fase 0 | `baseline.est_clients` | 534/534 (100%) | `baseline` és sortida del pipeline antic ja apuntat a SAP: comparava SAP amb SAP |
| 28/08 | l'exportació d'Analitza, **per client** | 4.647/4.689 (99,1%) | Es mesurava per CLIENT, i la majoria en tenen **una sola adreça**: quadren amb qualsevol regla |
| 29/09 | l'exportació d'Analitza, **per adreça** | 4.923/5.618 (87,6%) | — aquest és el bo |

Amb el prefix: **5.574 de 5.618 (99,2%)**. I mirant només les 804 que van canviar de número, el codi
postal de KAIS quadrava amb el de SAP en **132** i després en **786**. El residu són adreces que a
KAIS no tenien codi postal, zeros al davant (`080057` contra `80057`) i una adreça que a SAP ha
canviat de ciutat.

**La lliçó no és «`baseline` enganya» —això ja ho sabíem— sinó que el 99,1% del 28/08 era el mateix
error amb una cara nova: un percentatge alt sobre el denominador equivocat.** El dany vivia només als
clients amb diverses adreces, i mesurant per client quedaven diluïts fins a desaparèixer.

#### Què es va fer

| | |
|---|---|
| `etl.vw_client_ship_kais_no` | La regla del prefix en un sol lloc, com `vw_client_code`. Tolera la cometa inicial de l'escapament CSV de SAP, que amagava **5** adreces del patró |
| `sql\migrations\2026-09-29_ship_no_from_address_prefix.sql` | La re-congelació. **Fora de `deploy.sql` a propòsit** |
| `etl.sp_assign_client_ship_no` | Les adreces noves prenen el prefix si el número és lliure; si no, `MAX+1` |
| Checks 15 i 16 | `ship_no_prefix_mismatch` i `master_name_artifacts` |
| `tools\Import-AnalitzaClientExport.ps1` + `cfg.analitza_client_export` | El cens de KAIS dins de la BD, i `sql\verify_ship_no.sql` per repetir la mesura |

**La regla, i la seva excepció:** cada adreça pren el seu prefix; si un client té dues adreces amb el
**mateix** prefix (la mateixa adreça introduïda dues vegades a SAP), aquell client es queda **enter**
com estava. Són tres: `C221503`, `C291071` i `C432068`. No s'inventa cap desempat, perquè un número
que no es pot justificar contra KAIS és pitjor que no canviar res. Amb això, **0 col·lisions**.

#### Per què va ser barat, i per què no ho hauria estat al novembre

**Només 8 `id_client_location` desapareixen** de 804 files canviades: gairebé tot són permutacions
dins del mateix conjunt de números d'un client, i una permutació no fa desaparèixer cap identificador.
O sigui que `vanished_ids` ho va veure com un **WARN de 8 sobre un llindar de 10** i
**`ID_DROP_MAX` no es va tocar**.

El corol·lari incòmode: **el que es movia era el contingut de 804 ubicacions, no la seva existència**,
i això cap check nostre no ho pot veure. Per això la verificació ha de ser contra el cens d'Analitza.

⚠️ **I per què no es podia ajornar:** `cfg.client_ship_no` és **la mateixa taula per a test i per a
productiva** —el cutover és un canvi de `ServiceLayer:CompanyDb`, no una BD nova—. Els números
corregits el 29/09 són literalment els que farà servir la productiva el 2 de novembre. I sense el
canvi a `sp_assign_client_ship_no`, les adreces que a test no hi són i a la productiva sí (§6.6: 45
dels 63 locations perduts) haurien arribat el dia 2 com a adreces noves, amb un `MAX+1` inventat.

**Run 160, `SUCCESS`**: 804 files renumerades, `vanished_ids` WARN amb 8, `ship_no_prefix_mismatch`
WARN amb 4 = el `SHIP_NO_PREFIX_BASELINE` que la migració va armar, i `lines_orphan_client` a **0**
—el gate real, i va caldre `@ForceFullLines=1` als dos runs—.

⏳ **Queda una conseqüència que decideix Analitza.** Pel que l'Adrià va explicar l'01/09, quan els
deixa d'arribar un `client_location` l'esborren però **mantenen l'històric d'albarans**. O sigui que la
renumeració li deixa l'històric enganxat al número antic i el nou buit: **li desplaça l'històric de
804 ubicacions**. El mapatge `id_antic → id_nou` és a `audit.client_ship_no_changes` amb els ids ja
construïts, i `resposta_adria_4.docx` li ho ofereix. Si ja havia ingerit dades d'aquest origen, el
necessita; si no, no.

### 6.6 Resultat de la implementació del COALESCE (28\08\2026)

Desplegat a `IntercanviSAP` i executat `sp_run_all @SkipSwap=1, @ForceFullLines=1`. Comparant
`staging.est_clients` amb els 5.684 `id_client_location` de l'exportació d'Analitza:

| | |
|---|---|
| es conserven — l'històric lliga | **5.621 de 5.684 (98,9%)** |
| es perdrien | 63 |
| ubicacions noves | 30 |

Abans del canvi de numeració n'hi havia **973** de coincidents.

Dels 63: **18** són dels 13 clients que no existeixen a SAP (§6.4), i els **45** restants són clients
que a SAP tenen menys adreces de ship-to que a KAIS i perden la cua (gairebé tots, una sola adreça).
No és un error de fórmula, és desfasament de dades entre els dos sistemes — i mesurat contra
`DB_FARINERA_TEST`, o sigui que una part pot ser només que la còpia de test va endarrerida.

L'únic warning CRITICAL que queda és `vanished_ids`, i és correcte que salti: els identificadors
canvien en massa, que és precisament el que aquest check vigila. Al cutover cal apujar
`cfg.settings.ID_DROP_MAX` expressament i tornar-lo a baixar l'endemà (Regla 04).

**El `new_code` canvia de semàntica.** L'esborrany del 25/08 proposava
`new_code = COALESCE(U_FCNewCardCode, U_FCKaisCode)`. **Era erroni**: tenia sentit quan
l'identificador era el codi de SAP i el `new_code` feia de pont cap a KAIS, però si el codi de KAIS
*és* l'identificador, posar-lo també al `new_code` diu que el client ha canviat de codi a si mateix.
`new_code` ha de portar només l'identificador del successor, i NULL la resta del temps. Cau també la
idea de la columna `kais_code` separada.

**Risc que introdueix el COALESCE.** És de la mateixa família que el bug del `LineType` (§Fase 4): si
un client que ja existia es queda amb `U_FCCodiKais` buit, el COALESCE cau al CardCode de SAP i
Analitza el veu com un client nou. En silenci, i el dia del tall, que és quan menys es mira. La
població del camp ha de ser **completa i verificada** abans de l'1 de novembre.

Aquest risc el cobreix el check **`vanished_ids`**, implementat el 26/08/2026: avisa quan un
identificador que ahir hi era avui no hi és. Protegeix el contracte cada nit sense dependre que
ningú se'n recordi.

**El camp ja es pobla, però encara no el llegeix ningú.** A 28\08\2026 `U_FCCodiKais` no existeix ni
a `sap_raw` ni a cap SP: el Worker només el demana des de la sonda. Mentre l'emissió no s'implementi,
la població del camp no canvia res del que veu Analitza. Falta: afegir les columnes a `sap_raw.OCRD`,
`sap_raw.OITB` i `sap_raw.OSLP`, que el Worker les escrigui, i el `COALESCE` a `sp_load_clients`,
`sp_load_client_attributes` (que ha de fer servir la **mateixa** fórmula d'`id_client_location`),
`sp_load_salesmen` i `sp_load_product_categories`. Continua pendent de la confirmació de l'Adrià.

### 6.5 Volum

62 línies, 47 documents, 18/05/2026 – 21/08/2026. No serveix per dimensionar el backfill.

---

## 7. Gotchas de Service Layer

Recollits a `.claude/rules/02-service-layer-odata.md`. Cadascun ve d'un bug real.

### Heretats de GAPI03_CRM

- **`$top` és un cap TOTAL, no una mida de pàgina.** Limita els registres sumant totes les pàgines
  del `odata.nextLink`. A GAPI03 una reconciliació amb `$top=500` sobre 857 clients en va desactivar
  357 cada dia en silenci. Aquí **no s'emet mai**; hi ha test de regressió.
- **`Prefer: odata.maxpagesize` és obligatori.** Sense la capçalera SL retorna 20 registres per
  pàgina. A GAPI03 l'impacte mesurat va ser de 8×.
- **`$filter` buit retorna HTTP 400.** Si no hi ha cursor, no s'emet la clau.
- **SL 10.0 FP 2602 rebutja els literals `Edm.Time` a `$filter`.** El cursor només pot filtrar per
  `UpdateDate`; es compensa amb overlap d'un dia i escriptura idempotent. `UpdateTime` sí que val a
  `$orderby`.
- **El cos del Login és case-sensitive**: `CompanyDB` / `UserName` / `Password` exactes. La política
  web per defecte de .NET 8 els passaria a camelCase i el login retorna codi 206.
- **Dos logins del mateix usuari en pocs segons** poden fallar amb `Invalid login credential.` És
  throttling del pool de sessions, no credencials dolentes.

### Trobat en aquest projecte (26/08/2026)

- **Un UDF nou no apareix a Service Layer fins que es reinicia el servei.** SL es cacheja les
  metadades de la companyia: el camp existeix a SAP i es veu a la interfície, però al `$select`
  respon `400 — Property 'U_FCCodiKais' of 'BusinessPartner' is invalid`.

  Vol dir que **crear els UDFs i endollar-hi el pipeline no es pot fer seguit**: cal la finestra de
  reinici entremig. La sonda ho detecta i ho diu en comptes de petar.

### Trobat en aquest projecte (25/08/2026)

- **`BPAddresses` i `DocumentLines` NO s'`$expand`en.** A Service Layer v1 són col·leccions de
  **tipus complex**, no propietats de navegació. Expandir-les respon:

  ```json
  {"error":{"code":201,"message":{"value":
    "Cannot expand invalid navigation property 'BPAddresses' for entity type 'BusinessPartner'"}}}
  ```

  Vénen incloses en el cos de l'entitat i n'hi ha prou de nomenar-les al `$select`. Hi ha test de
  regressió que falla si es torna a emetre `$expand`.

- **El projecte apunta a `/b1s/v1`, no `/b1s/v2`.** v1 és OData v3 i v2 és OData v4, amb sintaxi de
  literals diferent al `$filter` (`datetime'...'` vs data nua). El codi emet literals v3. Si algun
  dia es puja a v2, s'ha de tocar `ODataQueryBuilder`.

---

## 8. Bugs trobats i corregits

| Què | On | Estat |
|---|---|---|
| Contrasenya de `sa` hardcodejada com a valor per defecte d'un paràmetre | `deploy_via_powershell.ps1:7` | ✅ Ara per `$env:SQLPASS` o autenticació integrada. **Anava a entrar al primer commit del repo** |
| `duration_ms` negatiu a `audit.etl_step_log` (−142, −133) | Els 10 SPs | ✅ `@started` era `datetime2(0)`, que arrodoneix al segon més proper i podia quedar després de l'instant real d'inici. Ara `datetime2(3)` |
| El README declarava 10.342 client_locations i 3.253 atributs | `README.md` | ✅ Són 5.651 i 5.651 |
| `deploy_via_powershell.ps1` no incloïa `02_create_sap_raw.sql` ni `seed_zone_code_mapping.sql` | ídem | ✅ |
| Precedència d'`EXCEPT`/`UNION ALL` mal parentitzada a la comparació de Fase 4 | `verify_migration.sql` | ✅ Detectat abans d'executar-lo; `A EXCEPT B UNION ALL C EXCEPT D` no vol dir el que sembla |
| El `.docx` enviat a Sistemes el 07/09/2026 no deia el mateix que el seu `.md` | `correu_sistemes_2026-09-07.docx` | ⚠️ **El fitxer enviat es queda com està: és el que van rebre.** Veure sota |

**Un Word que no diu el mateix que el seu markdown (10/09/2026).** El correu a Sistemes es va
convertir a `.docx` a mig editar el markdown i no es va tornar a generar. Tots dos fitxers van
entrar al mateix commit, i el que va sortir per correu **no portava l'última secció ni el comiat**,
i li faltava mitja frase al segon paràgraf. Sistemes van contestar el 10/09 els quatre punts que
els van arribar; la pregunta que faltava —qui ha de refrescar `DB_FARINERA_TEST`— es va donar per
ignorada quan mai no la van rebre.

No va ser un bug de `tools/md2docx.py`: amb el markdown final el conversor treu el text sencer. El
forat era que **ningú comparava el Word amb el seu origen**, i un document incomplet s'obre bé i fa
patxoca. Dues coses al conversor:

- Grava i **torna a llegir** el `.docx` per verificar bloc a bloc que hi ha tot el que hi havia al
  markdown. Si no quadra, surt amb error.
- Cada `.docx` porta gravat un **segell** del tros de markdown d'on va sortir, i
  `python tools/md2docx.py --check` diu quins s'han quedat enrere. Aquesta és la que hauria
  detectat el cas del 07/09, perquè allà el problema no era la conversió sinó que no es va tornar a
  convertir.

El `.docx` del 07/09 **no s'ha regenerat a propòsit**: és el registre del que Sistemes van rebre, i
la seva resposta només s'entén contra aquell text.

### Paranys que continuen al codi

**El parany del `deploy.sql` — tancat el 31/08/2026.** `01_create_database.sql` comença amb
`DROP TABLE dbo.est_*` — les vuit taules que llegeix Analitza — i `deploy.sql` es declarava
idempotent. Executar-lo sencer deixava Analitza sense dades fins a la següent càrrega correcta; per
això el 25/08 es van desplegar **només els procediments**, un per un.

S'han fet les dues coses alhora:

- **Guarda a `01_create_database.sql`**: si `dbo.est_*` té files, l'script avorta amb un missatge que
  diu què fer. L'escapatòria és `cfg.settings.ALLOW_DESTRUCTIVE_SCHEMA = '1'`, que el propi script
  torna a `'0'` just després dels DROP — el permís és d'un sol ús. Va a `cfg.settings` i no a una
  variable de `sqlcmd` perquè ha de valer igual des de SSMS, des del script de PowerShell i des del
  que sigui d'aquí a un any. El recompte surt de `sys.partitions`: en una instal·lació nova les
  taules encara no existeixen i un `SELECT COUNT(*)` no compilaria.
- **`01` ja no el crida `deploy.sql`.** És creació inicial i s'executa una sola vegada, a mà. Per
  posar al dia una BD desplegada hi ha `04_migracions.sql`, que sí que es crida. Amb `01` fora,
  `deploy.sql` és idempotent de debò.

Provat contra `IntercanviSAP` amb les 15.595 files a dins: avorta amb el permís a `'0'`, deixa passar
amb `'1'`, i el consum el torna a `'0'`. Cap taula va perdre files.

**Els dos camins de desplegament havien divergit (31/08/2026).** `deploy_via_powershell.ps1` és el
que es fa servir de debò —no hi ha `sqlcmd` en aquesta màquina— i la seva llista de fitxers no
coincidia amb la de `sql/deploy.sql`. Li faltaven `04_migracions.sql` (el `discount` es quedava a
`decimal(5,2)` i `formula_break` hauria saltat cada nit), `etl_vw_kais_codes.sql` —les tres vistes,
sense les quals els **cinc** SP que hi fan JOIN ni tan sols es creen— i el job de SQL Agent.

No és teòric: qui munti la productiva al novembre farà servir aquell fitxer. Sincronitzades, i amb un
avís al capçal de tots dos que han de coincidir.

### Falsa alarma

Els runs de `audit.etl_runs` surten a la 01:00 i el job està programat a les 03:00. No és cap
desajust: `etl_runs.started_at` guarda **UTC** i a l'agost anem a UTC+2.

---

## 9. Què queda obert

### ✅ La validació d'Analitza troba el número d'adreça equivocat (25-29/09/2026)

L'Adrià va enviar `comparativa farinera 25-09-26.txt`, la **primera validació de debò contra el cens
de KAIS** d'aquest projecte, i en una tarda va destapar el que quatre setmanes de checks no havien
vist: **804 ubicacions apuntaven a l'adreça equivocada**. El detall tècnic i els tres mesuraments són
a §6.5b; aquí el que en queda obert.

**Corregit i publicat el 29/09/2026** (run 160 `SUCCESS`). ✅ **`resposta_adria_4.docx` enviat l'01/10/2026.**

### ✅ L'Adrià contesta el 05/10/2026, i tanca tres dels quatre punts

> ✅ **`resposta_adria_5.docx` enviat el mateix 05/10/2026.** Hi espera **cinc** coses, i la primera és
> la que pot espatllar el dia del tall: **el `product_cost`** (tres sortides, la tria és seva), **que
> no hi posi un `REPLACE` del `DESHABILITAT__`**, el «sí» del **`discount`**, si tenen **documents de
> 100+ línies**, i **magatzem i previsions**, que ja fa dos correus que no contesta.
>
> El correu va amb **tres punts numerats i prou** a propòsit: les dues vegades que el `/100` va anar
> dins d'una llista de cinc preguntes, va contestar la resta i es va saltar aquella.

| Punt | Com queda |
|---|---|
| 1. El mapatge `id_antic → id_nou` | ✅ **No el necessita, i per un motiu que val més que el mapatge**: encara **no ha carregat res a producció**. Va refinant les SQL i el dia del tall «farem un swap amb la nova configuració/sql's i a partir de llavors es començarà a importar a producció». La hipòtesi de l'01/10 era bona |
| 2. Repetir la comparativa | ✅ **Feta** (`comparativa farinera 05-10-26.txt`). Les xifres, més avall |
| 3. **El `/100`** | ✅ **TANCAT, i amb el codi al davant.** Veure sota |
| 4. Magatzem i previsions (per a en Lluís) | ⏳ **No el contesta.** És l'únic que queda obert d'aquest correu |

**El `/100` era l'únic punt del contracte que el dia del tall fallava en silenci**, i portava obert des
del 31/08/2026 i tres correus. Els canvis que ja té provats i que posarà a producció el dia del tall:

```sql
-- a invoice_lines
product_price/100 -> product_price
product_cost/100  -> product_cost
AND date >= '2026-11-02'
```

Tres conseqüències, i la tercera no l'havíem previst:

1. **Els preus van en euros tal com els emetem, i nosaltres no hem de fer res.** Important: **no
   multiplicar per 100 "per si de cas"** — les dues correccions alhora tornarien a desquadrar-ho.
2. **Del `discount` no diu res**, així que manté el seu `1 - discount` i la convenció del
   multiplicador es queda. `DISCOUNT_AS_PERCENT` **no es toca** el dia del tall (§Decisions pendents).
3. **Filtra `date >= '2026-11-02'`**: no ingerirà cap línia anterior al tall. Encaixa amb el blueprint
   17.3 (no es migra històric documental), però vol dir que **el que publiquem abans del dia 2 li és
   invisible**, i que el `product_cost` d'octubre deixa de ser un problema d'ell.

**El que ell arregla al seu costat** (i que ja no és feina nostra): l'escapament CSV de les cometes
—amb un `CASE` que les treu a `client_locations.name`/`address`, `client_location_attributes` i
`products.name`—, i **el misteri dels accents**. No era que llegís CP850 com havíem suposat: era un
`REPLACE(char(160))` seu, heretat de l'intercanvi antic, que s'enduia la `Á` de `RECO DE CAL TOMÁS`.
L'ha tret de totes les SQL. La nostra lectura d'això era equivocada i val la pena no repetir-la.

> **Les tres claus duplicades que reporta són del seu fitxer de KAIS, no nostres.** `1609777`,
> `1609882` i `1612956` són ids de 7 dígits; els nostres són `offset + DocEntry*100 + LineNum`. I al
> nostre costat un duplicat **no pot arribar-hi en silenci**: `est_linies_albara` té
> `PRIMARY KEY CLUSTERED (id_invoice_line)` a `dbo` i a `staging`, o sigui que petaria la càrrega.
> Però això descobreix un sostre — veure *El sostre de `LineNum`*, més avall.

⏳ **Netejar a SAP els valors mestres amb escapament CSV de la migració**: 3 `CardName`, 5
`CRD1.Address`, 25 `ItemName` i 34 `E_Mail`. No trenca res, però una d'aquelles cometes **tapava el
prefix de cinc adreces** i per això ara hi ha el check `master_name_artifacts`. El dia que algú els
corregeixi, `ship_address_changed` avisarà per les 5 adreces i serà correcte.

#### La comparativa del 05/10: la correcció es veu, i el que la tapa

Columnes modificades a `client_locations`, 25/09 → 05/10 (5.651 registres nostres contra els 5.703 seus):

| Columna | 25/09 | 05/10 |
|---|---|---|
| `address` | 1.279 | **651** |
| `zip_code` | 673 | **26** |
| `city` | 614 | **48** |
| `country_code` | 59 | **1** |
| `email` | 54 | **3.004** |
| `phone_number` | 4.873 | 4.879 |
| `name` · `salesmen_id` · `new_code` | 82 · 157 · 20 | 77 · 157 · 20 |

Registres eliminats 78 → 75, nous 30 → 23. **Les quatre columnes d'adreça s'han ensorrat**, que és
exactament on havia de notar-se la re-congelació del `ship_no`. El total de modificats, en canvi, puja
(5.088 → 5.249): la previsió de «l'ordre de 4.300» que es va escriure l'01/10 era optimista, i el que
se l'emporta és la columna `email`, que no té res a veure amb aquesta feina. Els `phone_number` són
format (`972.210.901` → `972210901`) i ja hi eren.

### L'scrubbing de la companyia de test, i per què no s'ha de tapar (05/10/2026)

La pregunta que l'Adrià fa al correu del 05/10 és per què 3.000 correus li arriben com a
`DESHABILITAT__lbutinya@agrienergia.com`, i si ha de fer un `REPLACE`. **La resposta és que no**, i
`sap_raw.OCRD.UpdateDate` permet datar-ho sense preguntar-ho a ningú:

| | |
|---|---|
| Una sola operació del **25/09/2026** va tocar | **4.631 dels 4.691 clients** |
| … amb `DESHABILITAT__` al davant del correu | **2.253** |
| … amb el correu buidat | **2.378** |
| Camps afectats | **només `E_Mail`**: `CardName`, `CRD1.Address` i `ItemName` en tenen 0 |
| `dbo.est_clients` / `staging.est_clients` | **3.021** ubicacions (quadra amb els seus 3.002) |
| `baseline.est_clients` | **0** — el 24/08, a l'`DB_FARINERA_TEST` vella, no hi era |

És l'**scrubbing de correus de la companyia de test**, entrat amb la preparació de `DB_FARIN_TEST`, i
**desapareix sol quan `CompanyDb` apunti a la productiva**. El check `master_name_artifacts` ja el
separa dels artefactes d'escapament CSV precisament per això: al run 166 són **2.338 = 67 CSV + 2.271
prefix de test**, i els 67 són els del pendent de dalt (34 `E_Mail` + 25 `ItemName` + 5 `Address` + 3
`CardName`).

**Dues coses que contesten la seva pregunta amb dades:**

- **No són només clients inactius.** Dels 2.305 clients amb el prefix, **849 estan actius**
  (`validFor='Y'`) i 1.456 congelats. Qui ho interpretés com una marca de baixa s'equivocaria.
- **A 26 clients el correu publicat surt tallat.** `sp_load_clients` emet `LEFT(E_Mail, 60)` i el
  prefix menja 14 caràcters:

  ```
  SAP:      DESHABILITAT__"farnau@vicensbatllori.com; montse@vicensbatllori.com        "
  publicat: DESHABILITAT__"farnau@vicensbatllori.com; montse@vicensbatll
  ```

⚠️ **I per què no se li ha de deixar posar el `REPLACE`:** el prefix a la productiva voldria dir que
**algú hi ha carregat dades de test**, que és una de les coses més greus que poden passar aquell dia.
Un `REPLACE` al seu costat taparia justament aquell senyal. És el mateix criteri que amb
`volume_anomaly`: no es fa callar un check perquè a test molesti.

### El sostre de `LineNum` (05/10/2026)

Les claus duplicades del correu de l'Adrià no són nostres, però fan mirar una cosa que no s'havia
mirat mai: `id_invoice_line = offset + DocEntry*100 + LineNum` **només reserva dos dígits per al
`LineNum`**. Un document de **100 línies o més** col·lisiona amb el `DocEntry` següent.

El mode de fallada és el bo —hi ha `PRIMARY KEY CLUSTERED (id_invoice_line)` a `dbo` i a `staging`, o
sigui que la càrrega peta i no publica duplicats—, però aquella nit Analitza es queda amb les dades
d'ahir, i la fórmula **és contracte**: no es pot canviar sense parlar-ho amb ells.

A test no es pot mesurar: màxim **7 línies** per albarà, 3 per devolució i 4 per abonament. I la
productiva arrenca sense històric documental, així que el risc viu als documents que es facin **a
partir del dia 2**. La consulta és al runbook, pas 4b de la setmana del 27 al 31 d'octubre.

⚠️ **Del document de l'Adrià, dues coses que són de la seva banda i li hem dit:** la seva exportació
genera cometes duplicades que no són a la BD (8 de les 10 diferències de `name` a `products`), i
**perd la `Á` majúscula** en llegir CP850 —`RECO DE CAL TOMÁS` arriba bé i al seu fitxer surt `TOM S`—.
Les dues tapaven diferències de veritat.


### ✅ El pipeline ja no corre amb l'usuari d'una persona (05/10/2026)

**El Worker va amb `proceso`**, el compte que el partner va crear per a processos no concurrents
(§Llicenciament, i `docs/llicencies_service_layer.md`). La contrasenya és la mateixa que la d'`OHijazo`,
així que el canvi és **una sola clau** a dos llocs i no s'ha hagut de comprar cap llicència:

| On | Fet |
|---|---|
| user-secrets de l'equip de desenvolupament | `dotnet user-secrets set "ServiceLayer:UserName" "proceso"` |
| `C:\Apps\SapB1AnalitzaSync\appsettings.Production.json` a `AE02SAPRDP` | el valor de `ServiceLayer:UserName`, deixant la resta del fitxer byte a byte igual (581 → 581 bytes) |

**Verificat pel camí real, no pel que s'hi assembla** (la lliçó del 16/09): `--once` llançat **a la
màquina de producció**, amb la seva configuració, surt amb `0`, al log hi diu
`Login a Service Layer ... (CompanyDB=DB_FARIN_TEST, usuari=proceso)` i `sap_raw.sync_state` queda
segellat amb les **nou entitats** a les 13:40 UTC. Codi de sortida **i** dada escrita.

> **`AE02SAPRDP` accepta WinRM per a `ohijazo`**, i això estalvia molta feina: el fitxer de
> configuració —que no és al repositori i no el toca cap desplegament— es pot editar des de l'equip
> local amb `Invoke-Command`, **sense passar per RDP i sense tocar la contrasenya**, canviant només la
> clau que calgui. `AE01SAPRDP` **no**: denega WinRM i `schtasks` (comprovat el 05/10/2026), i per això
> la neteja de la màquina vella segueix pendent.

✅ **I el 06/10/2026 en Carles tanca la pregunta de qui més fa servir el compte: ningú.** GAPI01
(financials) **no va per Service Layer** i GAPI09 (CyC) **encara no s'ha desenvolupat**. El compte que
es deia «nocturno» perquè el compartien dos processos **el té GAPI07 per ell sol**, i el «probable»
passa a «assegurat» sense haver de mesurar res.

⚠️ **Es reobrirà, i per això queda escrit:** el dia que es desenvolupi **GAPI09**, si li donen aquest
mateix compte, la pregunta torna. La resposta ja la sabem: ha de fer **`Logout`** en acabar cada cicle
i **no pot treballar dins de la finestra de les 02:45**; si no es pot assegurar cap de les dues coses,
necessita compte propi. Està a `docs/llicencies_service_layer.md`, que és on ho buscarà qui ho faci.

⏳ **El que queda d'això** és treure `OHijazo` dels altres tres projectes de `P:`.

### Llicenciament de SAP — obert, i més gran del que sembla

> ✅ **La part que bloquejava GAPI07 està resolta des del 05/10/2026**: el pipeline va amb `proceso` i
> no ha calgut cap llicència nova. El que segueix obert és la pregunta gran, la del consum indirecte
> d'Analitza CM, i treure `OHijazo` dels altres tres projectes.

**27/08/2026.** Per crear un usuari tècnic de Service Layer cal una llicència, i a
*Gestió → Llicència → Administració de llicències* **no n'hi ha cap de lliure**:

| Tipus | Disponibles |
|---|---|
| Professional User · Limited Financials · Limited Logistics | 0 |
| **Indirect Access User** · B1iINDIRECT MSS | 0 |
| Components (`B1i`, `SDK Tools`, `AddOns`, `Workflow`) | ~99.975 |

O sigui que `GAPI07_RO` **no es pot crear** i el pipeline segueix amb `OHijazo`, un usuari nominal
(veure §Decisions pendents).

**Dues preguntes per al partner, i la segona és la important:**

1. Quina llicència necessita un compte que només llegeix per Service Layer? *Indirect Access User*
   sembla la figura pensada per a això, però no està confirmat. A la llista d'usuaris hi ha un
   usuari `B1i` i la llicència de component `B1i` té capacitat de sobres: val la pena mirar què és
   abans de comprar res.
2. **Com es llicencia el consum de dades de SAP des d'Analitza CM?** El licenciament indirecte de
   SAP no va del compte tècnic, va de qui acaba consumint les dades. Aquest projecte porta clients,
   articles, albarans i cobraments cap a una plataforma externa on hi entren diverses persones
   d'Agrienergia. Segons com ho miri SAP, aquests usuaris poden comptar.

La segona pregunta **no la genera el Worker, la genera el projecte sencer**, i existia abans de la
migració a Service Layer. Anar per l'API oficial *mitiga* el risc —era un dels set motius de §3.1—
però no l'elimina. Val més tenir-ho contestat per escrit ara que descobrir-ho en una auditoria, i
falten dos mesos per a productiva.

### La primera publicació (17/09/2026)

El run **139** és el primer swap des del **24/08/2026**. `dbo.est_*` portava 24 dies congelat al run
91 perquè el job avortava cada nit amb `ABORTED_STALE_MIRROR`, i quan el Worker va començar a córrer
de debò van sortir dos `CRITICAL` alhora. **Cap dels dos era una avaria**, i val la pena distingir-los
perquè es van arreglar de maneres diferents.

**Run 136 — la primera execució automàtica, `FAILED`:**

| Check | Què passava |
|---|---|
| `vanished_ids`, **5.655 ids** | `dbo` portava CardCodes des del 24/08; `staging` porta codis de KAIS des que es va implementar el `COALESCE` el 28/08. El canvi d'identificadors havia de creuar aquesta porta algun dia |
| `lines_orphan_client`, **50 línies** | En mode INCREMENTAL, `sp_load_invoice_lines` **copia de `dbo`** les línies dels documents que no es refresquen. Aquelles portaven els codis vells: la taula quedava amb **dues convencions barrejades** |

El primer es resol obrint `ID_DROP_MAX` expressament un cop. **El segon no**: es resol amb
`@ForceFullLines=1`, que reconstrueix totes les línies amb els codis nous. Comprovat en mode
inspecció abans de publicar: les òrfenes passen de 50 a **0**.

> **Tocar la fórmula dels identificadors obliga a un FULL de línies.** És el mateix parany que el
> `discount` —una taula amb dues convencions, cada meitat coherent amb ella mateixa— però allà el codi
> ho detecta sol amb `DISCOUNT_AS_PERCENT_PUBLISHED` i **aquí no hi ha res equivalent**. Qui ho va
> caçar va ser `lines_orphan_client`, que existeix precisament per això. Si algun dia es toca
> `etl.vw_client_code`, això torna a passar.

**Run 139 — publicat**, amb el llindar obert, `@ForceFullLines=1` i el flag de famílies activat alhora
(les dues coses necessitaven la mateixa porta oberta). El llindar es va tornar a tancar **a la mateixa
sessió**, dins d'un `finally`: no depèn que ningú se'n recordi.

| | |
|---|---|
| Clients | **5.651**, dels quals **5.650 amb el codi de KAIS conservat** i 1 amb CardCode |
| Famílies | **14** |
| Línies | **124**, amb `net_amount = price × qty × discount` quadrant a **totes** |
| Amb quantitat negativa | 32 — devolucions i abonaments, com exigeix la guia |
| Rang de dates | 18/05/2026 → 16/09/2026 |
| Guardes | `ID_DROP_MAX`=10, `HISTORY_FLOOR_ENFORCE`=1, `LINES_MIN_RATIO`=0.95, `MIRROR_MAX_AGE_HOURS`=6 |

Els dos WARN que queden són coneguts i benignes: un client apuntat com a predecessor per dos
successors, i una adreça que ha canviat de nom sense canviar de número.

### El backup ja hi era (18/09/2026)

El punt 3 —freqüència i retenció— portava **tres correus sense resposta**. No calia esperar-la:
`msdb.dbo.backupset` ho diu tot menys una cosa.

**`IntercanviSAP` es copia dues vegades al dia, per dues vies independents:**

| Quan | Què | On |
|---|---|---|
| **22:00** | FULL del maintenance plan | `I:\MaintenancePlan\IntercanviSAP\IntercanviSAP_backup_<data>.bak` |
| **~23:42** | Snapshot **VSS**, o sigui el backup de la VM | dispositiu amb nom de GUID |

Les segones es reconeixen perquè el `physical_device_name` és un `{GUID}` en comptes d'un camí: és la
signatura d'una còpia feta pel *writer* de VSS. Encaixa amb el que Sistemes ja havien dit al juny,
que amb el backup complet de la VM n'hi havia prou.

Totes les BD de la instància hi entren —les de SAP, `SBO-COMMON`, `crm_sync_db_dev` de GAPI03 i la
nostra—, i l'historial de `backupset` arriba **93 dies enrere** (17/06/2026). `IntercanviSAP` està en
**`SIMPLE`**, coherent amb no fer còpies de log.

**El que no es pot veure des de SQL és quants dies sobreviuen els fitxers a `I:\`.** L'historial de
`msdb` i la retenció del disc són coses diferents. És l'única part del punt 3 que encara s'ha de
preguntar, i ara és una pregunta d'una línia.

⚠️ **I un matís que convé no repetir malament.** S'ha dit uns quants cops que «la BD es regenera cada
nit des de SAP, així que el backup és poc crític». **Des de l'01/09/2026 ja no és del tot cert**:
`cfg.client_ship_no` **no es pot regenerar** —fixa la meitat dreta de `id_client_location`— i només
viu aquí. El FULL de les 22:00 la cobreix, i l'exposició màxima és d'un dia, però la frase «es
regenera sola» ja no descriu tota la base de dades.

> **De passada**: el 15/09/2026 va aparèixer una `DB_FARINERA_TEST2` a les còpies, de 790 MB. No és
> nostra i ningú ens havia dit res. ✅ **Contestat el 22/09/2026**: era la preparació de
> `DB_FARIN_TEST`, la companyia de test nova. La hipòtesi era bona i la via —mirar `backupset` en
> comptes de preguntar— va tornar a funcionar, però el que faltava (que la BD canviava de nom) no
> es podia deduir de les còpies. Veure §5, *La companyia de test canvia de nom*.

### La companyia de test canvia de nom (22/09/2026)

Per correu: la BD de test passa a ser **`DB_FARIN_TEST`**, restaurada a partir de
`DB_FARINERA_TEST` i amb les mateixes dades. La vella es donarà de baixa (data no dita).

El canvi funcional és una clau, `ServiceLayer:CompanyDb`, i ni un SP ni una vista ni un test la
coneixen. Però **tres coses no es veien des del correu**:

1. **Un forat de la Regla 01.** `ohijazo_sql`, `gapi07_worker` i `analitza_ro` tenien `DENY CONNECT`
   sobre `DB_FARINERA_TEST` i **cap denegació sobre la companyia nova**. La llista de BD de SAP
   estava escrita a mà a quatre scripts; ara viu en una variable a dalt de cada fitxer i els blocs
   van guardats amb `DB_ID(...) IS NOT NULL`, perquè segueixin sent idempotents el dia de la baixa.

2. **El mirall no sap de quina companyia ve.** `sap_raw.sync_state` té com a clau només l'entitat.
   Canviar de companyia deixa els cursors vius i el Worker continua en incremental. L'única guarda
   que hi ha és de **frescor** (`ABORTED_STALE_MIRROR`), no de procedència: un mirall fresc de la
   companyia equivocada hi passa sense immutar-se. Per això el primer cicle es va fer amb el
   checkpoint buidat.

3. **Al cutover això mateix és molt pitjor, i el runbook no ho deia.** Aquí no fa mal perquè la
   còpia és la mateixa; contra `DB_FARINERA_PROD` no ho serà. Afegit el pas **2.1b** al runbook:
   `DELETE FROM sap_raw.sync_state` **i** `TRUNCATE` de les sis taules de documents, perquè
   `ReplaceDocumentsAsync` només esborra els `DocEntry` del lot que baixa i productiva no tornarà
   mai els de test.

**Dos bugs latents trobats pel camí**, tots dos del mateix tipus que ja té secció pròpia (§8):

- **`Create-AdminUser.ps1` donava un verd fals sobre la Regla 01.** La comprovació de «pot entrar a
  la BD de SAP?» construïa la connexió amb `$connStr`, una variable que **no s'assigna enlloc de
  l'script**: la connexió es feia amb una cadena buida, petava sempre, requeia al `catch` i escrivia
  `no (correcte)` tant si el `DENY` hi era com si no. Ara va per `New-SqlConn`, amb la credencial de
  debò, i comprova totes les BD de la llista. El mateix `$connStr` s'oferia a escriure als
  user-secrets del Worker.
- **`create_worker_user.sql` encara feia `DENY CONNECT` a `master`.** És exactament el que va
  costar la tarda del 16/09/2026 (error 916, vint dies latent). `Create-WorkerUser.ps1` ja ho havia
  corregit i el `.sql` germà s'hi havia quedat enrere: qui executés el `.sql` en comptes del `.ps1`
  tornava a plantar el parany. Ara el `.sql` fa `DROP USER` a `master`, com el `.ps1`.

**I dues coses que només es van veure mirant `sys.databases`, no al correu:**

- **`DB_FARINERA_TEST` ja estava OFFLINE** el mateix 22/09, a les poques hores de crear-se
  `DB_FARIN_TEST` (11:18). O sigui que la baixa no és una cosa que passarà: ja ha passat. Això va
  obligar a afinar la guarda dels scripts: **`DB_ID()` retorna un id per a una base de dades
  OFFLINE**, així que `IF DB_ID(@db) IS NULL` no la salta i el `USE` peta igualment. La comprovació
  bona és `sys.databases.state_desc = 'ONLINE'`.
- ⚠️ **Hi ha una `DB_FARINERA` sense sufix, ONLINE des del 13/03/2026, i no hi ha cap
  `DB_FARINERA_PROD`.** Tota la documentació d'aquest projecte —runbook inclòs— dona per fet que la
  companyia productiva es dirà `DB_FARINERA_PROD`. **Al servidor no existeix cap BD amb aquest nom.**
  Si la productiva és `DB_FARINERA`, el pas 2.1 del runbook posaria un nom que no existeix i el
  Worker petaria amb `Invalid login credential` el dia del tall. S'ha afegit `DB_FARINERA` a les
  llistes de `DENY CONNECT` (hi va pel mateix motiu que la resta), però **quin és el nom de la
  companyia productiva s'ha de confirmar, no deduir del nom del fitxer**.

**Feina que no és nostra però que se'n deriva**: `P:\preparacioComandesVendaSAP\.env` porta
`SAP_SL_COMPANY=DB_FARINERA_TEST` i `SAP_SQL_DATABASE=DB_FARINERA_TEST`. És l'altre projecte, el
que **sí que escriu a SAP**, i el dia que donin de baixa la BD vella s'aturarà. Avisat.

### 🔴 El Worker canvia de servidor i el cicle nocturn s'atura (22–25/09/2026)

**`sap_raw` no es refresca sol des de la nit del 21 al 22/09.** Tres nits seguides de correu d'alerta
a les 03:00:

| Run | Quan (UTC) | Estat |
|---|---|---|
| 147 | 22/09 01:00 | `SUCCESS` — **l'últim cicle nocturn bo** |
| 148 | 22/09 12:26 | `SUCCESS_NOSWAP` — `--once` + `@SkipSwap=1` a mà |
| 149 | 23/09 01:00 | `ABORTED_STALE_MIRROR` — mirall de 13 h |
| 150 | 23/09 06:10 | `SUCCESS` — `--once` a mà des de l'equip local |
| 151 | 24/09 01:00 | `ABORTED_STALE_MIRROR` — mirall de 19 h |
| 152 | 25/09 01:00 | `ABORTED_STALE_MIRROR` — mirall de 48 h |

Els `SUCCESS` del mig són execucions manuals, no la tasca. `sap_raw.sync_state` porta les nou
entitats segellades el **23/09 a les 06:09 UTC** i no s'ha mogut des de llavors.

**No és una avaria de l'ETL**, i val la pena dir-ho perquè el correu del SQL Agent diu `STATUS:
Failed` i convida a pensar-ho: és la guarda `MIRROR_MAX_AGE_HOURS` avortant abans de tocar
`staging`, i per això `DURATION` són 0 segons. `dbo.est_*` es queda amb dades bones del 23/09 en
comptes de publicar-ne de mig carregades. **No s'ha d'apujar el llindar per fer callar l'avís.**

**La causa: el Worker ha canviat de màquina.** De `AE01SAPRDP` (192.168.11.239) a **`AE02SAPRDP`
(192.168.11.136)**, verificat per DNS el 24/09. Totes dues responen a 445 i 3389; `C$` està denegat
des de fora a totes dues —i és així a propòsit—, o sigui que **l'estat de la instal·lació no es pot
veure sense entrar-hi per RDP**.

⚠️ **Dos canvis la mateixa setmana, i des de SQL no es distingeixen.** El canvi de servidor i el
canvi de nom de la companyia (secció anterior) tenen exactament el mateix símptoma: el mirall es fa
vell. Sigui quin sigui el que ho hagi provocat, **el segon és una mina que queda armada**: si
l'`appsettings.Production.json` es copia de la màquina vella a la nova, arrossega
`CompanyDb: DB_FARINERA_TEST`, que està OFFLINE, i el `Login` respon `Invalid login credential` —un
missatge que apunta a la contrasenya—. La guarda d'arrencada de `Program.cs` només detecta buit o
placeholder, **no** una companyia existent però equivocada.

**El que un canvi de màquina trenca i que no deixa rastre enlloc**, per ordre de probabilitat:

1. **El dret *Log on as a batch job***. A `AE01SAPRDP` estava concedit per **directiva local, no per
   GPO**: en una màquina nova no hi és. La tasca es registra igual i falla cada nit amb `0x4`.
2. **La sortida cap a `192.168.11.238`, ports 50000 i 1433.** El `Test-NetConnection` del 16/09 es va
   fer des de `.239`. Des de `.136` **no ho ha comprovat ningú**, i aquell resultat no s'hereta.
3. **L'`appsettings.Production.json`**, que s'ha de recrear **a mà**: els binaris poden viatjar, la
   configuració no.
4. **La tasca vella de `AE01SAPRDP`**, si encara hi és: o es desactiva, o les dues màquines es
   trepitgen.

✅ **De SQL Server no s'ha de tocar res.** `gapi07_worker` és un login SQL i no està lligat a cap
host; les mencions a `AE01SAPRDP` de `sql/security/*` són comentaris. Comprovat el 24/09/2026.

**S'ha escrit `deploy\Check-WorkerHost.ps1`** perquè això no torni a ser una tarda de conjectures:
es llança per RDP a la màquina i contesta els set punts d'un sol tret —binaris, `CompanyDb`, ACL,
tasca i `LastTaskResult`, sortida cap a `.238`, i el dret de batch—. No escriu res, no toca SAP i no
imprimeix cap contrasenya; el que necessita administrador surt com a `NO COMPROVABLE` en comptes de
petar.

**La lliçó, que és la de sempre en aquest projecte i ara amb una variant nova:** editar
`deploy/README.md` **documenta** un canvi, no el desplega. El fitxer que decideix què passa cada nit
—`C:\Apps\SapB1AnalitzaSync\appsettings.Production.json`— **no és al repositori i no el toca cap
desplegament nostre**. Quan el 22/09 la companyia va canviar de nom es van actualitzar els documents
i el codi, i la única còpia que importava es va quedar com estava.

#### Com va quedar (25/09/2026, matí)

**Eren dues causes, no una, i totes dues confirmades.** L'`appsettings.Production.json` de
`AE01SAPRDP` deia `CompanyDb: DB_FARINERA_TEST`: encara que el servidor no hagués canviat, aquella
màquina hauria fallat cada nit des del 22/09 igualment.

L'estat real de `AE02SAPRDP`, mesurat amb `Check-WorkerHost.ps1`, era **millor del que es temia**:
carpeta i ACL ja fetes per Sistemes, i **la sortida cap a `192.168.11.238` pels ports 50000 i 1433
ja oberta** —el risc número 2 de la llista, tancat sense demanar res—. El que faltava eren els
binaris i la configuració, que són nostres.

| Fet el 25/09 | |
|---|---|
| `publish` refet | Build Release 0 warnings, 28/28 tests. El del 16/09 **no portava** la guarda d'arrencada que cobreix `CompanyDb` |
| Binaris copiats | 253 fitxers, self-contained `win-x64`: la màquina nova no necessita cap runtime |
| Configuració | `Set-ProductionConfig.ps1`, escrita **a la màquina**, amb `DB_FARIN_TEST` |
| Prova de SQL | `gapi07_worker` connecta des de `.136` — credencial i port 1433, verificats alhora |
| `--once` | 20 s, nou entitats, mirall segellat a les 07:07 UTC |
| Run 153 | `SUCCESS`, swap fet. 5.651 clients, 2.029 productes, **134 línies** (eren 124), 13 famílies |

Els tres WARN del run 153: `volume_anomaly` (el de sempre a test, 0 línies un dia), `new_code_ambiguous`
(anterior) i `ship_address_changed` —`C301017/35`, un punt final afegit al nom—. Aquest últim és
justament el check funcionant: distingeix un canvi de nom d'una reutilització de `LineNum`, i et dona
les dues cadenes per decidir-ho.

⚠️ **La contrasenya de Service Layer d'`OHijazo` és `1234`**, la mateixa a
`P:\preparacioComandesVendaSAP\.env`. És un usuari nominal amb permisos amplis i SL escolta a
`192.168.11.238:50000`. No bloqueja res, però és més gros que el problema que es va venir a resoldre.
Va amb el pla de treure `OHijazo` de tot arreu quan es reparteixin les llicències.

**Pendent, i és l'únic que decideix si el cicle nocturn torna a córrer:** confirmar amb Sistemes que
la tasca de les 02:45 existeix i està activada a `AE02SAPRDP`, i que `sapsistema` hi té *Log on as a
batch job*. El `schtasks` respon `Acceso denegado` i no *no s'ha trobat*, cosa que apunta que la
tasca ja hi és. Text llest a `peticio_sistemes_ae02saprdp.md`. (De `AE01SAPRDP` no s'ha de netejar
res: la màquina desapareix — veure més avall.)

#### ✅ Resolt el 28/09/2026: la tasca hi era, i estava DESACTIVADA

Tres nits més d'alerta —runs 154 (18 h), 155 (42 h) i 156 (66 h), tots `ABORTED_STALE_MIRROR`—
comptades des del `--once` manual del 25/09. `sap_raw.sync_state` no es va moure del **25/09 07:07
UTC**: la tasca no havia corregut ni una sola vegada.

**I no calia Sistemes per saber-ho.** El `schtasks /query /s AE02SAPRDP` que el 25/09 responia
`Acceso denegado` ara contesta, i diu exactament què passa:

```
Estado:                      Deshabilitado
Hora próxima ejecución:      N/A
Último tiempo de ejecución:  30/11/1999 0:00:00
Último resultado:            267011           (0x41303 = mai s'ha executat)
Tarea que se ejecutará:      C:\Apps\SapB1AnalitzaSync\SapB1AnalitzaSync.Worker.exe --once
Ejecutar como usuario:       sapsistema
Tipo / hora:                 Diariamente, 2:45:00
```

Tot ben configurat —ruta, argument, compte, hora, i creada el 16/09— i **mai arrencada**: es va
demanar expressament que la registressin **desactivada** perquè no fallés abans que hi hagués els
fitxers (secció *L'ordre importa: la tasca es registra l'última*), i el 25/09, en acabar el
desplegament, **no la va activar ningú**. La petició que quedava per enviar preguntava si existia i
si estava activada; la resposta era *sí* i *no*.

`schtasks /change /enable` + `/run` des de l'equip local: la tasca va córrer a les **11:36:44** amb
`LastTaskResult = 0` i les nou entitats de `sync_state` resegellades a les **09:37 UTC**
(`deliverynotes` va passar de 10 files a 18 — el mirall es movia de debò, no és només un codi de
sortida).

**El cicle nocturn del 29/09 va córrer sol, i és la prova que compta:**

| | |
|---|---|
| Tasca a `AE02SAPRDP` | 29/09 **02:45:01**, `LastTaskResult = 0`, pròxima execució 30/09 02:45 |
| `sap_raw.sync_state` | nou entitats a **00:45 UTC** (mirall de 15 minuts a l'hora del check) |
| Run 157 | **`SUCCESS` en 11 segons**, swap fet |
| Warnings | tres, tots `WARN`: `volume_anomaly`, `ship_address_changed`, `new_code_ambiguous` |
| Correu de les 03:00 | cap |

✅ **I això contesta la pregunta 2 de la petició sense haver-la de fer:** si a `sapsistema` li faltés
*Log on as a batch job* en aquesta màquina, la tasca hauria tornat `0x4` en comptes de `0`. El dret
hi és.

**La lliçó, i és una variant nova de la de sempre:** el 25/09 es va donar per fet que el que faltava
era informació que només tenia Sistemes, i el que faltava era **un canvi d'estat que no havia fet
ningú perquè cadascú es pensava que el faria l'altre**. Es va demanar la tasca desactivada per una
raó bona, i «activar-la» no era un pas de cap llista. Quan un pas del desplegament consisteix a
*desfer* una precaució, ha de sortir escrit al costat de la precaució.

I la segona: **el `Acceso denegado` del 25/09 no volia dir «no ho puc saber mai»**. Val la pena
reintentar una comprovació de només lectura abans de convertir-la en una pregunta a algú altre.

**I el règim estable, que és el que faltava per poder dir que corre sol:** del **30/09 al 06/10/2026**,
set nits seguides a la 01:00 UTC —runs **161 a 167**— totes `SUCCESS` en 11-12 segons, amb el mirall
segellat a les 00:45 i cap correu d'alerta.

El **run 167 és el primer cicle nocturn complet amb l'usuari `proceso`**: tasca a les 02:45 amb
`LastTaskResult = 0` i `Estado: Listo`, mirall amb les nou entitats a les 00:45 UTC, ETL `SUCCESS` en 11
s, i els cinc WARN coneguts i benignes (`master_name_artifacts` 2.338, `ship_no_prefix_mismatch` 4 = el
baseline esperat, `ship_address_changed` 1, `new_code_ambiguous` 1 i `volume_anomaly` per 0 línies el
diumenge 05/10, que a test és el de sempre).

### 🔴 `proceso` NO té permisos a la companyia productiva (06/10/2026)

**Trobat quatre setmanes abans del tall, i si s'hagués trobat el dia 2 el cutover hauria fallat.**

> ⚠️ **Però que quedi clar què es va a buscar a producció, perquè és fàcil de confondre i ja s'ha
> hagut d'aclarir:** **a producció no hi ha res a *provar*.** Tota la validació del projecte es fa
> contra la companyia de test i està feta. El que només existeix a l'altra banda són dues coses d'una
> altra naturalesa: una **precondició de dades que no és nostra** (que `U_FCCodiKais` hi sigui i estigui
> poblat — veure la secció següent) i un **permís**, que per definició no es pot comprovar a test.
> La **mesura** de la cobertura i del volum segueix programada per a la setmana del 27-31 d'octubre; les
> autoritzacions es demanen ara perquè tenen cua, no perquè calgui connectar-hi aquesta setmana.

Es va llançar la sonda contra la companyia productiva —lectura pura, no escriu enlloc— amb una sola
variable d'entorn i sense tocar cap fitxer:

```powershell
$env:DOTNET_ENVIRONMENT='Development'
$env:ServiceLayer__CompanyDb='DB_FARINERA'
dotnet run -- --probe
```

Dues coses, i la segona atura el projecte fins que es resolgui:

1. ✅ **El `Login` entra.** `DB_FARINERA` existeix, és ONLINE i **`proceso` hi és un usuari vàlid**.
   Això és la millor pista que tenim del nom de la companyia productiva, que el runbook donava per fet
   com a `DB_FARINERA_PROD` —un nom que **no existeix**.
2. 🔴 **La primera lectura respon `403`:**

   ```json
   {"error":{"code":-3000,"message":{"value":"The logged-on user does not have permission to use this object."}}}
   ```

   `proceso` **no té autorització sobre `BusinessPartners` a la companyia productiva**. La sonda avorta
   a la primera entitat, així que **de les altres vuit no se'n sap res encara**.

**Per què no s'havia vist abans:** les autoritzacions de SAP B1 són **per usuari i per companyia**.
`proceso` llegeix `DB_FARIN_TEST` sense problemes des del 05/10, i d'això no se'n deriva absolutament
res sobre la productiva. És una variant nova del patró de sempre d'aquest projecte —*funciona a test,
per tant funcionarà a producció*— i aquesta tenia data: el 2 de novembre, amb el `Login` entrant i les
lectures morint, el missatge hauria apuntat a tot arreu menys al lloc correcte.

**Què cal demanar**, i és una feina de dins de SAP (*Administració → Inicialització del sistema →
Autoritzacions → Autoritzacions generals*), amb permís **només de lectura** per a `proceso` a la
companyia productiva sobre les nou entitats de l'abast:

`BusinessPartners` (amb `BPAddresses`) · `Items` · `ItemGroups` · `SalesPersons` ·
`WizardPaymentMethods` · `DeliveryNotes` · `Returns` · `CreditNotes` · `Invoices`

⚠️ **I el que pot convertir això en una compra de llicència:** si `proceso` és d'un tipus de llicència
limitat, pot ser que no se li puguin donar aquestes autoritzacions per molt que es vulgui. Si surt
així, torna la conversa de §*Llicenciament de SAP* amb el partner.

**La verificació és tornar a llançar exactament la mateixa sonda**: anirà entitat per entitat i
s'aturarà a la primera que encara falti. No es dona per bo fins que arribi al final i tregui les
xifres.

### 🔴 I a la companyia productiva no hi tenim accés (06/10/2026)

Dit el mateix dia, i **invalida una pila de passos d'aquest document i del runbook**: tot el que hi diu
«ho fa l'Oscar» dins de SAP **només val per a la companyia de test**. A `DB_FARINERA` no hi entra.

Això no s'havia vist abans perquè **tot el que s'ha fet s'ha fet a test**, i la comunicació als
consultors del 26/08/2026 (*«els creo i els omplo jo»*) només era certa allà.

**El que ho fa greu no és el 403, és això:** els **camps d'usuari de SAP B1 són per companyia**.
`OCRD.U_FCCodiKais` i `OITB.U_FCCodiKais` es van crear el 26/08 a `DB_FARINERA_TEST` —d'on ve la
restauració de `DB_FARIN_TEST`— i **de la productiva no se sap ni si existeixen**. Si el dia 2 el camp
no hi és o arriba buit, `COALESCE(U_FCCodiKais, CardCode)` cau al codi de SAP i **Analitza rep ~4.700
clients com si fossin nous**, amb la qual cosa perd l'històric de tots. És el risc que §6.6 ja
anomenava i que fins avui es donava per cobert perquè a test el camp està poblat a 4.689 de 4.691.

El moment natural d'omplir-lo és **la migració de dades mestres a producció**, perquè la
correspondència la té qui la fa. Si no entra per aquí, omplir 4.700 clients passa a ser **el camí
crític del projecte**, no una tasca de preparació.

**Sense amo a producció, a 06/10/2026:**

| Feina | On consta |
|---|---|
| Autoritzacions de lectura per a `proceso` | §anterior |
| Que `U_FCCodiKais` existeixi **i estigui poblat** a `OCRD` i `OITB` | §6.4, §6.6, runbook pas 3 |
| Esborrar `OCRD.U_FCNewCardCode` + reiniciar Service Layer | runbook pas 4 |
| Netejar els 67 valors mestres amb escapament CSV | §9 |
| Comprovar `01761 ESPECIFICA TURRIS` | §9 |

Demanat a SEIDOR el 06/10/2026 amb `peticio_seidor_produccio.docx`, posant `U_FCCodiKais` **de primer**
i el 403 de segon: el 403 bloqueja la mesura, però el que té cua llarga és el camp.

### ✅ El Worker escriu el seu propi log (06/10/2026)

El run 167 va destapar un buit: **de quin usuari havia fet servir la tasca no en quedava rastre
enlloc.** El Worker escrivia només per consola i la tasca de les 02:45 no redirigeix la sortida, així
que es perdia. L'única evidència era indirecta —el fitxer de configuració el nomenava— i el dia que el
cicle fallés de nit no hi hauria hagut res a mirar més que `audit.etl_runs` i `sync_state`.

Redirigir la sortida voldria tocar la definició de la tasca, que és d'un administrador d'una màquina
que no és nostra. Així que ho fa el Worker: **`logs\worker-AAAAMMDD.log` al costat de l'executable**, un
fitxer per dia i **30 dies de retenció** (`FileLog` a la configuració). Desplegat i verificat el mateix
dia:

```
2026-10-06 06:45:27Z INF ServiceLayerClient Login a Service Layer https://192.168.11.238:50000/b1s/v1/ (CompanyDB=DB_FARIN_TEST, usuari=proceso)
```

Quatre decisions que no són evidents, i el perquè:

| | |
|---|---|
| **No pot fer petar el Worker** | Si la carpeta no fos escrivible pel compte de la tasca, el cicle ha de seguir refrescant el mirall igualment. Tot va dins d'un `try`; si falla, ho diu **una** vegada per consola i es calla. Un log que trenca la feina és pitjor que no tenir-ne |
| **UTF-8 amb BOM** | Sense BOM, PowerShell 5.1 i el Notepad del servidor llegeixen el fitxer com a ANSI i `reemplaçament` surt `reemplaÃ§ament`. És la mateixa mossegada que la Regla 05 als `.ps1`, i aquest log existeix **per llegir-lo en aquella màquina** |
| **Segell en UTC** | Perquè es pugui comparar amb `sap_raw.sync_state.updated_at`, que també és UTC, sense convertir res |
| **La retenció no esborra res que no haguem escrit** | Només fitxers que casen amb `worker-AAAAMMDD.log`, i `RetentionDays <= 0` **no esborra res** en comptes d'esborrar-ho tot: un zero per badada no ha de buidar una carpeta d'una màquina compartida |

La política de noms, format i retenció viu a `SapB1AnalitzaSync.Shared/Logging/FileLogPolicy.cs` perquè
és lògica pura i té tests (Regla 05): **45 tests, eren 28**. I `sapsistema` té `FullControl` heretat
sobre `logs\`, comprovat, o sigui que el cicle de les 02:45 hi pot escriure.

### ✅ `AE01SAPRDP` no s'ha de netejar: desapareix (05/10/2026)

Va estar escrit dues setmanes com a pendent —desactivar-hi la tasca vella i esborrar
l'`appsettings.Production.json`—, i **la resposta és que la màquina es dona de baixa i tot passa a
`AE02SAPRDP`**. No hi ha res a fer-hi.

Val la pena saber per què no urgia, perquè el raonament es repetirà: **la tasca vella hi segueix
fallant cada nit i no pot espatllar res.** L'`appsettings.Production.json` d'allà diu
`CompanyDb: DB_FARINERA_TEST`, que està OFFLINE, així que el `Login` peta i el procés **no arriba a
escriure al mirall**. Les dues màquines no es trepitgen: una de les dues no funciona.

⚠️ **L'únic que en queda és la credencial, i no és menor:** aquell fitxer porta la contrasenya
d'`OHijazo`, que **és la mateixa que la de `proceso`** —el compte que ara fa anar el pipeline—, o
sigui que és viva. Quan la màquina es retiri, que el disc no acabi en una còpia de la VM; i si hi
acaba, rotar-la (i llavors toca tocar els dos llocs de §*El pipeline ja no corre amb l'usuari d'una
persona* i el `.env` de `preparacioComandesVendaSAP`).

> **De passada, una cosa comprovada el 05/10/2026 que convé no oblidar:** `.239` deixa passar el
> `Test-WSMan` però denega l'`Invoke-Command` i el `schtasks /query /s` a `ohijazo`
> (*Acceso denegado*), al contrari que `.136`, on tots dos funcionen. Si algun dia s'hagués hagut de
> tocar aquella màquina, hauria estat per RDP o per Sistemes.

### Les famílies: el problema dels 782 articles no existia (16/09/2026)

Durant setmanes això va anar plantejat com una decisió comercial amb un projecte de classificació al
darrere: **o 110 famílies (els grups d'article de SAP), o les 12 comercials amb 782 dels 980 articles
actius sense classificar.** Es va arribar a escriure un correu a l'Olga perquè triés.

**La premissa era falsa, i es va veure mesurant-ho.** Contra l'històric de vendes de KAIS
(`bi_estadili`, 12 mesos, aplicant-hi **les mateixes set sèries que exclou Analitza**, perquè si no la
xifra no és comparable):

| | |
|---|---|
| Facturació considerada | 22.262.329 € |
| **Passa per articles que SAP ja té classificats** | **98,53%** |
| Articles sense família **amb vendes** | **28** de 782 |
| Dels quals fan el 90% d'aquest import | **7** |

Els altres 754 són recanvis, EPI's, palets, lubricants i material de fàbrica: **es compren i no es
venen**, i per això Seidor només va classificar els 198 que formen el catàleg comercial de veritat. El
1,47% que queda fora és el mateix ordre de magnitud que el calaix «sense assignació» que Analitza **ja
té avui** (195.233 € de gener a agost). O sigui que mantenir les 12 famílies no empitjora res: li
reprodueix la situació actual.

La feina real són **vuit articles**, i la proposta surt de la subfamília que KAIS ja els assigna:

| Article | Família |
|---|---|
| `30182` (B4) FARINA Nº1E — 111.790 € | FORÇA |
| `01761` ESPECIFICA TURRIS — 62.675 € | MITJA FORÇA |
| `30151` (B4) FARINA Nº1 — 54.276 € | FORÇA |
| `34561` MIE CREME — 27.244 € | HAUBANNE |
| `30751` (B4) FARINA SEGOL — 11.055 € | ALTRES CEREALS |
| `30131` (B4) FARINA CROISSANT — 4.672 € | CAN TRULL |
| `50150` / `50550` FARINA ECOLOGICA — 1.362 € | ECOLÒGICA |

La resta de la llista són palets, sacs, serveis de transport i residus, que **han de continuar sense
família**: no són producte i avui ja cauen al mateix calaix.

#### Fet el 17/09/2026 — i la font bona era SAP, no KAIS

**Set dels vuit classificats** (run 140, `SUCCESS`), i el `KM 0` amb espai corregit: les famílies
passen de 14 a **13** i la facturació sense classificar de 326.702 € (1,47%) a **~116.000 € (0,52%)**.

⚠️ **La proposta inicial era dolenta en quatre dels vuit.** Sortia de traduir les subfamílies de KAIS
(`FORÇA FC`, `HAUBANNE`) com si fossin famílies, i **a SAP són subfamílies**: posar-les hauria creat
tres famílies noves a l'aplicació de l'Olga. Ho va destapar l'Oscar en veure que el camp de família
és una llista desplegable i que `FORÇA` no hi sortia.

**La resposta la donava SAP mateix**, amb els 198 articles que ja tenien els dos camps: els `(B4)`
són variants d'articles que ja existeixen i n'hereten la família.

| Article | Ve de | Família |
|---|---|---|
| `30182`, `30151`, `30131` | `30180`, `30150`, `30130` | TRADICIONALS |
| `30751` | `30750` FARINA SEGOL | ALTRES CEREALS |
| `34561` MIE CREME (PLASTICO) | `30780` MIE CREME | MOULIN DE COLAGNE |
| `50150`, `50550` | — (per subfamília ECOLÒGICA) | ECOLÒGIQUES |

**Queda `01761 ESPECIFICA TURRIS`** (62.675 €), i és genuïnament ambigu. ⏳ **Preguntat a comercial el
17/09/2026.**

Es va mirar de resoldre per la unitat de venda i **la regla no es sosté**:

| A SAP són… | Unitat a KAIS |
|---|---|
| `GRANEL` | `GRA` — 13 de 13 |
| `ESPECIFICA` | `S25` — 10, **però 2 en `GRA`** |

Els dos contraexemples (`01451 ESPECIFICA FORÇA RIUS`, `01601 ESPECIFICA PANIFICABLE RIUS`) tenen
**exactament la mateixa forma** que el TURRIS: «ESPECIFICA \<client\>», a granel. Entre articles
comparables, 13 van a `GRANEL` i 2 a `ESPECIFICA`: és una majoria, no un criteri. I la subfamília de
KAIS (`MITJA FORÇA FC`) apuntaria a una **tercera** resposta, `TRADICIONALS`.

Que el `01761` és granel sí que està establert: unitat `GRA` i **148.520 kg en 6 línies en un mes a
0,42 €/kg**. Cisternes, no sacs.

La pregunta que se'n va fer, i que val més que la resposta: *de les farines específiques servides a
granel, unes van a GRANEL i d'altres a ESPECIFICA — **quin és el criteri**?* Amb el criteri, els
articles que vagin sortint es classifiquen sols.

⚠️ **I una cosa a part:** a `DB_FARINERA_TEST` aquest article és una **closca buida** —sense nom, sense
unitat de venda, al grup 108 amb *TAXA GENERALITAT* i *Aigua Test*— mentre que a KAIS està complet i
actiu. **Mirar com està a `DB_FARINERA_PROD` abans del tall**: si allà també li falta el nom, el
problema no és la família sinó l'article.

La lliçó, que és la mateixa de tot el projecte: **la taxonomia de KAIS i la de SAP tenen els mateixos
noms en nivells diferents.** Qualsevol mapatge entre les dues s'ha de comprovar contra les dades de
SAP que ja estan classificades, no contra els noms.

#### KAIS no és la font, i omplir-ho des d'allà seria pitjor

Es va explorar KAIS (`vkais\kais`, BD `GWSV_AGRI`) buscant-hi la classificació. **No hi és.**
`ARTICLES.fam_codi` són famílies **internes de gestió** —PRODUCTE ACABAT, MANTENIMENT, SERVEIS,
CONSUMIBLES, RESIDUS, FERRETERIA GENERAL—, 37 en ús i cap article buit. El literal `MOULIN` no surt
enlloc de la base de dades. Les 12 famílies d'Analitza són **seves**, no una cosa que KAIS els enviés.

`SUBFAMI` sí que porta el vocabulari (`FORÇA FC`, `INTEGRAL FC`, `PEDRA MC`… on `MC` és Moulin de
Colagne) i està poblada als 2.055 articles, amb un encaix per `ItemCode` del **99,7%** contra SAP. Però
poblar `U_SEIFamCialCat` des d'allà **injectaria cinquanta famílies de ferreteria** a l'anàlisi
comercial de l'Olga. Serveix per proposar la família dels vuit articles; no per a un ompliment massiu.

#### L'estat del codi

`sap_raw.OITM.U_SEIFamCialCat` **es demanava al `$select` des del commit `70eabcb` i la sonda
l'ensenyava, però no s'escrivia enlloc**: ni `MirrorTables` el portava ni la taula tenia la columna. Es
baixava de SAP i es llençava, i per això cap consulta contra el mirall el trobava.

Desplegat el 16/09/2026: columna al mirall, `MirrorTables` que l'escriu, i els dos SPs darrere de
**`cfg.settings.FAMILY_FROM_COMMERCIAL`** (`'0'` = els 110 grups d'avui, `'1'` = les comercials).
Validat que amb el flag a `'0'` la sortida és **idèntica** a `dbo`: 0 diferències a
`est_families_productes` i a `est_productes`.

Amb el flag a `'1'`, mesurat sobre el mirall real, sortirien **14 famílies**: les 12 de l'Adrià, més
`SUBPRODUCTE` (que ell ja sabia que no té) i **`KM 0` amb un espai**, que és el duplicat conegut de
`KM0` i té un sol article, inactiu. Corregir aquell nom a SAP les deixa en 13.

⚠️ **Activar el flag fa desaparèixer 110 identificadors de cop.** `vanished_ids` saltarà com a
`CRITICAL` i aturarà el swap, que és el comportament correcte. Cal apujar `ID_DROP_MAX` aquell dia i
**tornar-lo a baixar l'endemà**, igual que al cutover. Es fa de dia i mirant-ho, no en un run desatès.

### Decisions pendents

**Correu enviat a l'Adrià el 31/08/2026** (`resposta_adria_2.md` / `.docx`). Hi van cinc preguntes, i
tres bloquegen feina nostra amb data 1 de novembre:

1. ~~**El `/100`**~~ ✅ **TANCAT el 05/10/2026**: el treu ell, els preus van en euros i a nosaltres no
   ens toca res. Va costar tres correus (31/08, 16/09, 01/10) i la lliçó és la que ja deia la nota del
   16/09: **repreguntar-ho sol**, perquè contestava de tot menys d'això. Veure §9.
2. ~~**Famílies**~~ ✅ **Resolt el 16/09/2026 amb xifres, no amb una decisió.** Veure *Les famílies:
   el problema dels 782 articles no existia*, més avall.
3. **Congelar el número d'adreça** al tall, o confiar en l'alarma `vanished_ids` (§6.5).
4. **Si la seva càrrega acumula o substitueix** la finestra de 90 dies. Si substitueix, el problema
   del cost d'octubre és molt més gros del que ell descriu.
5. **`RAÓ SOCIAL` i `ACTIU` com a atributs**: si els vol, són dues columnes noves a
   `est_atributs_client` i un canvi a `sp_load_client_attributes`.


- ~~**Usuari tècnic de SAP.**~~ ✅ **Resolt el 05/10/2026**: el pipeline i la sonda van amb
  **`proceso`**, el compte compartit del partner, i no s'ha hagut de comprar cap llicència. El motiu
  pel qual això era urgent es manté per als altres tres projectes de `P:`, que segueixen amb
  `OHijazo`: els logs d'auditoria de SAP atribueixen les lectures a una persona, i el dia que canviï
  la contrasenya o marxi, s'aturen tots alhora.
- **`product_cost`**: acordar amb l'Adrià quina definició de cost hi posem (§6.2). De moment surt
  **0 a propòsit** (`Sync:CostField = "none"`), perquè es vegi que no el tenim.

  ⚠️ **Ara que el `/100` està tancat, aquest és el forat gros que queda del contracte.** Mesurat el
  05/10/2026: `dbo.est_linies_albara` té **231 línies i 231 amb `product_cost = 0`**. I el seu correu
  del 05/10 demostra que **segueix consumint la columna** —entre els canvis que farà hi ha
  `product_cost/100`—, o sigui que el dia 2 veuria **cost zero i marges a zero**, amb cada xifra
  coherent amb ella mateixa i cap check capaç de veure-ho: la **mateixa família de fallada que el
  `/100`**. Preguntat a `resposta_adria_5` amb les tres sortides de §6.2 (acceptar `GrossBuyPrice`
  sabent què és, acordar una altra definició, o confirmar que ja no el fan servir).
- **Normalitzar el `discount`.** L'Adrià ens diu (26/08/2026) que la convenció de KAIS també estava
  malament: segons la seva guia, `discount` és el **percentatge** (0.25 = 25%) i la fórmula és
  `net_amount = price × qty × (1 - discount)`. KAIS els enviava el multiplicador, i ho tapen amb un
  `1 - discount` al seu costat. Nosaltres hem replicat la convenció de KAIS.

  Se li proposa normalitzar-ho el dia del tall. Si ell no treu el seu `1 - discount` el mateix dia,
  falla de manera sorollosa: els imports sortirien a zero. Val més això que un error silenciós.

  **Implementat el 31/08/2026, però desactivat.** El canvi és `cfg.settings.DISCOUNT_AS_PERCENT`
  (`'0'` = multiplicador, el d'avui). El dia del tall és un `UPDATE`, no editar SPs amb pressa. El
  llegeixen `sp_load_invoice_lines` i el check `formula_break`, que han de veure el mateix valor.
  Falta encara el punt 3: `.claude/rules/04-contracte-analitza.md` i aquesta memòria documenten la
  convenció del multiplicador com si fos l'única, i això es toca el dia 2, no ara.

  **El forat que va aparèixer provant-ho, i que és el de sempre.** La conversió és un sol `UPDATE` al
  final de `sp_load_invoice_lines`, i el mode incremental copia de `dbo` les línies dels documents
  que no es refresquen. El dia del canvi aquelles línies porten la convenció d'**ahir**: la taula
  hauria sortit mig en multiplicador i mig en percentatge, cada meitat coherent amb el seu
  `net_amount`, i **cap dels nou checks ho hauria vist**. La cinquena de la mateixa família que
  `LineType`, `product_cost` i el `/100`.

  Resolt sense dependre que ningú se'n recordi: `sp_swap_staging_to_prod` deixa escrit a
  `cfg.settings.DISCOUNT_AS_PERCENT_PUBLISHED` amb quina convenció va publicar `dbo` —dins de la
  mateixa transacció del swap, perquè si el swap es desfà la marca es desfaci amb ell— i
  `sp_load_invoice_lines` força FULL mentre no coincideixi amb la d'ara. FULL ja no és car des que
  l'origen és local.

  Provat el 31/08/2026 als quatre casos: amb el flag a 0 i a 1, `net_amount`, `product_price` i
  `quantity` són idèntics i només canvia el `discount`; `formula_break` calla en tots dos;
  l'incremental el dia del canvi es converteix en FULL tot sol; i l'incremental en règim estable no
  dona la volta dues vegades. Els passos del dia són a **`docs/runbook_cutover.md`**.
- **Refresc de `DB_FARINERA_TEST` des de productiva**, per poder validar de debò.

### La productiva arrenca sense històric d'albarans — TANCAT l'01/09/2026

Va estar setmanes com a suposició de la qual penjava tot el raonament del cost d'octubre. Ho respon
el **blueprint signat** (`BluPrint_GAPs\Blueprint Estandar - Coromina v14 revisat_signat.pdf`),
capítol 17.3:

> «La migración a SAP Business One se centrará en trasladar únicamente los datos necesarios para
> garantizar la continuidad operativa [...] a partir de la fecha de corte. **No se migrará el
> histórico documental.**»

No es migren albarans (ni de compra ni de venda), ni comandes, ni factures, ni moviments històrics
d'stock o comptabilitat. Sí que es migren:

- **Mestres**: clients, proveïdors, articles i famílies, condicions comercials, adreces, contactes.
- **Stock inicial** a la data de tall, valorat i amb detall de lot.
- **Factures pendents de cobrament**, com a **factures de servei** sense efecte fiscal, amb el
  número, data, import, venciment i client originals de KAIS.

Tres conseqüències per a nosaltres:

1. **`LINES_MIN_RATIO` s'ha d'abaixar el dia 2.** Deixa de ser una precaució.
2. **La data mínima serà el 2 de novembre**, com suposava l'Adrià, així que la seva càrrega no
   esborrarà res de l'històric de KAIS. El risc que queda són els albarans amb data endarrerida
   posats després del tall, que és el que cobreix el check `history_floor`.
3. **`est_cobraments` no quedarà buida el dia 2**: les factures de servei són `OINV` obertes i
   `sp_load_receivables` les recull. Sense això, el deute dels clients hauria semblat desaparèixer.

I dos fets operatius: els albarans pendents de facturar **es facturen tots a KAIS abans del tall**
perquè l'stock quedi quadrat, i **KAIS es manté viu com a plataforma de consulta** — que és el que
fa possible la càrrega puntual del desembre per corregir el cost d'octubre.

### La secció GAPI07 del blueprint no és el contracte

La definició que hi ha a les pàgines 194-195 (`clients.csv` i `invoice_lines.csv`, amb la nota dels
«5 a 10 anys d'històric») és el **format d'alta genèric d'Analitza**, enganxat al document. No
descriu aquesta integració: el contracte real són les vuit `est_*` en format KAIS, que és el que
evita que Analitza hagi de reescriure cap consulta.

**No s'ha de fer servir com a referència ni per validar l'abast.** Si hi apareix una discrepància
—camps que no hi surten, un històric que no es pot complir— no és un problema a resoldre.

El que sí que val del blueprint és el capítol 17, de dalt.

- **Configurar el Worker per al compte de SQL Agent**, o el job seguirà fallant cada nit (§5).
- **Fase 5 — replantejada el 26/08 i tancada a mitges el 31/08.** Els usuaris de
  `DB_FARINERA_TEST` són tots de SAP (`B1_*`, `SAPB1_*`, `LOG_*`), més `analitza_ro` —que ja té
  `DENY CONNECT`— i `NT AUTHORITY\SYSTEM`. **`sa` no hi surt com a usuari** perquè és sysadmin, i a
  un sysadmin no se li pot denegar res. O sigui que "revocar l'accés" no és una qüestió de permisos
  sinó de **sota quin compte corre l'ETL**.

  1. **El job de SQL Agent — fet el 31/08/2026.** Estava en propietat de `sa` i el seu pas no tenia
     context d'usuari: `EXEC etl.sp_run_all` corria com a **sysadmin**. Ara el pas porta
     `@database_user_name = 'gapi07_etl'`, un usuari **sense login**
     (`sql/security/create_etl_user.sql`) amb permisos només dins d'`IntercanviSAP`. Que no tingui
     login és el que importa: no serveix per connectar-se de fora i **no té àmbit fora de la seva
     BD**, així que cap base de dades de SAP li és accessible i això no depèn de cap `DENY` que algú
     pugui desfer.

     Verificat executant l'ETL sencer impersonant-lo —els nou passos OK i els mateixos recomptes que
     amb `sa`— i el swap dins d'una transacció que es va desfer. Després, el job de debò:
     *«Executed as user: gapi07_etl»*.

  2. **El Worker amb `gapi07_worker`** (creat el 27/08, `GRANT` només sobre `sap_raw` i `DENY`
     explícit a `dbo`, `staging` i `audit`) — **pendent**. Al servidor això és el
     `appsettings.Production.json` que farà Sistemes; en local encara va amb `sa`. Compte: `--probe`
     llegeix `baseline.est_*` / `dbo.est_*` per tenir referència, i `gapi07_worker` no hi arriba. La
     sonda és una eina de diagnòstic local, no part del camí desplegat, però si algun dia es vol
     executar amb el compte del Worker caldrà decidir-ho expressament.

  `sql/security/revoke_sap_direct_access.sql` ja advertia d'això a la secció 2.
- Resoldre l'única diferència que queda contra `baseline`: `product_cost` (§6.2).

### Del projecte, anteriors a la migració

**Bloc A — Sistemes:** desplegament del Worker a `AE01SAPRDP` (~~compte de servei~~ ✅ i ~~carpeta~~ ✅
el 16/09/2026; queden **l'accés d'`ohijazo` a la màquina** i la tasca de les 02:45); freqüència i
retenció del backup d'`AE01SAPSQL`; compte SMTP per a Database Mail. ~~Accés d'Analitza a
`AE01SAPSQL`~~ ✅ concedit el 10/09/2026. Són feina d'infraestructura, no de SAP.

> ⚠️ **No és obrir el port 1433 a les IP públiques d'Analitza.** Ho vam entendre malament durant
> mesos. La resposta de Sistemes del **15/06/2026** ho diu: *«Perquè Analitza pugui accedir el
> servidor de SAPSQL per VPN només m'ho heu de dir i li habilito l'accés»*, i *«si accedeixen des de
> la VPN el rang serà 192.168.254.x»*. O sigui:
>
> - **`192.168.254.x` és el pool de clients de la VPN**, no l'adreça d'`AE01SAPSQL` (que és
>   `192.168.11.238`, on respon Service Layer). La "contradicció d'IPs" que arrossegàvem no existia.
> - Analitza **entra per VPN**, com ja feia amb KAIS. `88.99.249.95` i `85.85.181.85` són el seu
>   origen cap al concentrador, no una IP que hagi d'arribar a 1433 des de fora. **No cal cap regla
>   de firewall cap a internet.**
> - El que falta no és una obertura, és **activar-los l'accés i fer-los arribar l'endpoint i les
>   credencials de VPN** — i això ja ens el van concedir el 15/06. Si torna a encallar-se, és el que
>   s'ha de citar.
>
> La petició de `192.168.11.239` cap a `192.168.11.238` (ports 50000 i 1433) **sí** que és una regla
> de firewall, però és la del Worker, no la d'Analitza. No barrejar-les.

#### El fil amb Sistemes (07/09 → 16/09/2026)

> **A 16/09/2026 el punt 8 ha deixat de ser un mur.** Hi ha carpeta, hi ha compte de servei
> (`sapsistema`) i hi ha acord de qui registra la tasca. Falta que `ohijazo` pugui entrar a la
> màquina. Tot això va passar **per Teams la tarda del 16**, després d'enviar el correu del matí.

| Data | Qui | Què |
|---|---|---|
| 15/06/2026 | Sistemes | Contesten set punts. Concedeixen l'accés d'Analitza («només m'ho heu de dir»). En queden dos pendents **d'informació nostra** |
| 07/09/2026 | Nosaltres | `correu_sistemes_2026-09-07.md`: es reprèn el fil i s'afegeix el punt 8 (`AE01SAPRDP`). **El `.docx` va sortir tallat** |
| 10/09/2026 | Sistemes | Habiliten l'accés d'Analitza. Del 3 repeteixen el del juny; del 6 diuen que ho parlen amb en Cáliz; del 8 entenen només l'accés per a `ohijazo` |
| 10/09/2026 | Nosaltres | `resposta_sistemes_2026-09-10.md`: es concreta el 3, el 6 i el 8, i es torna a fer la pregunta del refresc de `DB_FARINERA_TEST`, que mai no els va arribar |
| 16/09/2026 | Sistemes | Del punt 8: *«aquesta carpeta `C:\Apps\SapB1AnalitzaSync` és a `AE01SAPRDP` o `AE01SAPSQL`? la tinc de crear o ja està creada?»* |
| 16/09/2026 | Nosaltres | `resposta_sistemes_2026-09-16.md`: `AE01SAPRDP`, i s'ha de crear |
| 16/09/2026 | Nosaltres | **Per Teams**, versió curta del mateix correu: on va, qui crea la carpeta, els permisos, i que qui executa la tasca no ha de ser `ohijazo` |
| 16/09/2026 | Sistemes | *«amb l'usuari d'execució de la tasca, has de poder-la crear? o la vols crear amb el teu usuari i que l'executi l'altre usuari?»* |
| 16/09/2026 | Nosaltres | Cap de les dues: **que la registrin ells**. Veure *Qui registra la tasca* |
| 16/09/2026 | Sistemes | *«ok, si la creo jo ja ho tinc fet. La crearé amb admin i l'encarregat d'executar serà l'altre usuari, que es diu `sapsistema`»* |
| 16/09/2026 | Sistemes | Carpeta creada. *«té permís aquest usuari, els administradors locals i l'administrador de domini»* |
| 16/09/2026 | Nosaltres | L'ACL és la correcta, però `ohijazo` no hi és: cal permís de modificació **i** poder entrar a la màquina |
| 16/09/2026 | Sistemes | *«s'ha de poder veure aquesta carpeta? des de qualsevol pc? si fas `\\ae01saprdp\` ho has de poder veure?»* |
| 16/09/2026 | Nosaltres | **No**, cap recurs compartit. El que cal és RDP + NTFS |
| 16/09/2026 | Sistemes | Concedeixen RDP i `(F)` sobre la carpeta |
| 16/09/2026 | Nosaltres | **Worker desplegat i `--once` verd en 19 s.** Queda que registrin la tasca |
| 16/09/2026 | Sistemes | *«l'he fet com a tasca local, i ja porta un parell de dies configurada»* — es referien al **dret**, no a la tasca: a `AE01SAPRDP` no hi havia cap tasca nostra |
| 16/09/2026 | Nosaltres | Ho comprovem i els ho diem sense donar-hi voltes: de 156 tasques, 155 de Windows i una de l'Adobe |
| 16/09/2026 | Sistemes | Registren `GAPI07 Refresca sap_raw` i la llancen: **`LastTaskResult = 0`** |
| 16/09/2026 | Nosaltres | Verificat contra `sync_state`: les nou entitats segellades a l'hora de la tasca. **Punt 8 tancat** |

##### El desplegament, i les tres hores que va costar

Un cop dins de la màquina, la còpia i la configuració van ser deu minuts. La resta va ser SQL Server,
i les tres coses que ho van entretenir val la pena tenir-les localitzades:

1. **El login del Worker no s'havia pogut connectar mai** (error 916). Detall a
   `deploy/README.md` i al commit del dia. Vint dies latent perquè ningú l'havia fet servir.
2. **Una hipòtesi meva dolenta**: vaig apostar per `DEFAULT_DATABASE = master` i ja era
   `IntercanviSAP`. La causa era el `DENY CONNECT`, que havia deixat per després per no tocar
   `master`. Va costar una volta.
3. **`sa` semblava rotada i no ho estava.** La primera prova interpolava la contrasenya dins de la
   cadena de connexió; amb `SqlCredential` va entrar a la primera. Va fer perdre una estona
   plantejant-se demanar-la a Sistemes.

I dues coses que **no** van ser problema, però que ho semblaven: la sortida als ports 50000 i 1433 ja
funcionava (la regla de firewall del 07/09 no calia), i un parell de fallades van ser text enganxat
malament a la consola, no errors reals. En una sessió de RDP els blocs llargs de PowerShell es
trenquen: enganxar poques línies i curtes.

**La resposta del matí, per no tornar-la a buscar:** la carpeta va a **`AE01SAPRDP`**
(192.168.11.239). A `AE01SAPSQL` no hi va res de nou —ja hi corre el job de les 03:00 i a partir del
cutover és la màquina més crítica que tenim— i la carpeta buida la creen ells, perquè va lligada als
permisos, que són seus. El contingut l'hi posem nosaltres. **La van crear el mateix dia.**

**Que ho preguntin vol dir que l'annex del 07/09 no l'han relacionat amb el cos del correu**: la
carpeta destí i l'origen dels fitxers hi consten en una taula. Per això la resposta del 16/09
repeteix el `New-Item` i el repartiment en comptes de remetre-los-hi. El repartiment **no s'ha mogut**
respecte del 10/09, a propòsit: si cada correu canvia la frontera, es torna a discutir cada vegada.
L'única cosa que s'hi ha afegit és qui crea la carpeta buida, que anava sobreentesa dins de «donar-me
accés a `C:\Apps\SapB1AnalitzaSync`» — i la pregunta demostra que sobreentesa no estava.

✅ **El compte de servei existeix i es diu `sapsistema`** (16/09/2026). Portava tres intents: el
07/09 no el van contestar, el 10/09 van entendre només l'accés per a `ohijazo`, i el correu del
16/09 tampoc l'esmentava. El que el va desencallar no va ser insistir-hi, sinó **el paràgraf que
explicava la conseqüència**: que si la tasca corre amb un usuari nominal, el dia que canviï la
contrasenya o no hi sigui, la integració s'atura sense que ningú sàpiga per què. Val la pena
recordar-ho per a la resta de peticions obertes: el «per què» els mou més que el «què».

`svc_gapi07` era **la nostra proposta de nom**, no un compte real, i als correus del 07 i del 10/09
hi surt com si ho fos. El compte real és `sapsistema`, i és seu.

✅ **`sapsistema` és dedicat, no compartit, i no és administrador.** Comprovat el 16/09/2026 des de
la màquina amb `net user sapsistema /domain`: nom complet *SAP Sistema*, contrasenya posada el
**15/09** —o sigui creat expressament per a això el dia abans de contestar—, *«Última sesión
iniciada: Nunca»*, cap grup local i com a global només *Usuarios del dominio*. Tres suposicions
nostres desmentides d'un cop, totes tres cap al bo.

I una quarta cosa que treu feina: **la contrasenya no caduca**. El risc que quedava —que un dia
caduqués i la integració s'aturés sense senyal— no existeix. Queda només que algú la roti a mà, i
està demanat que ens ho avisin.

⚠️ **El compte es diu `sapsistema`, no `sapsistemes`.** Per Teams el van escriure amb essa i així va
entrar a la documentació durant unes hores. `sapsistemes` **no existeix al domini**. És el tipus
d'error que no es veu: si la tasca es registra amb un nom i la carpeta n'autoritza un altre, cada nit
a les 02:45 hi ha *Access Denied*, el job de les 03:00 avorta amb `ABORTED_STALE_MIRROR` —que és el
comportament correcte per un motiu equivocat— i res del que es miri assenyala una lletra.

⚠️ **Si el dret *Log on as a batch job* el gestiona una GPO, s'ha de posar allà.** Registrar la tasca
normalment el concedeix sol a la màquina, però una directiva de domini que defineixi aquell dret el
torna a treure al següent refresc i **la tasca comença a fallar dies després del desplegament**, quan
ningú relaciona ja les dues coses.

##### Qui registra la tasca, i per què ells

La pregunta del 16/09 —*«has de poder-la crear amb l'usuari d'execució, o crear-la tu i que
l'executi l'altre?»*— parteix d'una premissa falsa que convé tenir clara:

> **Qui crea la tasca i qui l'executa són coses independents.** La tasca guarda el seu *principal* a
> dins; un cop registrada, qui la va donar d'alta és irrellevant.

Així que l'única decisió real és qui la dona d'alta, i les dues opcions no són simètriques:

| | Què cal | Conseqüència |
|---|---|---|
| **La registren ells** ✅ | Res de nou: teclegen la contrasenya de `sapsistema` al `Register-ScheduledTask` | La contrasenya no surt mai de Sistemes |
| La registrem nosaltres | **Admin local a `AE01SAPRDP`** + que ens passin la contrasenya de `sapsistema` | Les dues coses que portem tres correus dient que no volem |

`Register-ScheduledTask -User <un altre compte> -Password ...` **demana drets d'administrador**. Fer-ho
nosaltres significaria tenir admin en una màquina amb webservices de tercers i el secret del compte
de servei a les mans — el mateix patró que ja tenim mal resolt amb `OHijazo` a Service Layer.

Acordat el 16/09: **la registren ells, amb admin, i corre amb `sapsistema`**.

##### La carpeta: l'ACL és correcta, i no es comparteix

`C:\Apps\SapB1AnalitzaSync` existeix des del 16/09/2026, amb permís per a **`sapsistema`, els
administradors locals i l'administrador de domini**. Ni `Users` ni `Everyone`: és exactament l'ACL
que volíem, així que **l'`icacls` de tancament que teníem previst ja no cal**. Val la pena
verificar-ho igualment en entrar-hi, per si hi ha herència de `C:\Apps` que no es vegi a la seva
llista.

Hi falta `ohijazo`, i això és el que bloqueja ara: sense permís de modificació no s'hi poden copiar
els fitxers ni escriure-hi la configuració.

⚠️ **La carpeta no s'ha de compartir.** Van preguntar si havia de ser visible des de
`\\ae01saprdp\`. **No**, i el motiu és el mateix pel qual la configuració no va a variables d'entorn
de màquina: a dins hi haurà un fitxer amb credencials de SAP i de SQL, en un servidor que allotja
webservices de col·laboradors externs. El que cal no és veure la carpeta des de fora, és **entrar a
la màquina** (RDP) amb `ohijazo` i estirar els fitxers des de `\\tomatera\...` des de dins.

Corol·lari que convé dir abans que el proposin ells: **els binaris sí que els poden copiar ells, però
la configuració no.** `appsettings.Production.json` porta credencials i s'ha d'escriure a la màquina;
no viatja per Teams, ni per correu, ni per cap carpeta compartida.

##### L'ordre importa: la tasca es registra l'última

Primer la carpeta i el compte, després els fitxers i la configuració, i **llavors** la tasca. Si es
registra abans, cada nit a les 02:45 falla amb *file not found* i genera soroll d'alertes per no res
en una màquina que no és nostra. Demanat que **la creïn desactivada** i que l'activin quan avisem —
que és també el moment de llançar-la un cop a mà, l'única manera de comprovar que `sapsistema`
arriba a `AE01SAPSQL` i pot escriure a `sap_raw`.

Executar `SapB1AnalitzaSync.Worker.exe --once` a mà des de la sessió d'`ohijazo` **no substitueix
aquesta prova**: correria amb un altre compte i no validaria justament el que s'ha de validar.

La part de SQL no canvia i val la pena no confondre-la: el Worker es connecta amb `gapi07_worker`
(**autenticació SQL**, a l'`appsettings`), no amb el compte de Windows. `sapsistema` no s'ha de
donar d'alta enlloc de SQL Server; només executa el procés.

**El que continua obert amb ells:**

| # | Què | Estat |
|---|---|---|
| 3 | ~~Freqüència del backup, i on van els fitxers~~ | ✅ **Mirat el 18/09/2026 a `msdb.dbo.backupset`**, no preguntat. Veure *El backup ja hi era* |
| 3 | **Quants dies sobreviuen els `.bak` a `I:\`** | Obert, i és l'únic que queda. La freqüència es veu a l'historial; la retenció dels fitxers, no |
| 6 | ~~Compte SMTP per a Database Mail~~ | ✅ **17/09/2026**: van crear `sql-alerts@agrienergia.com`, que era **l'opció 1** de les tres —un mailbox institucional, no el compte de ningú. Configurat i provat el mateix dia |
| 8 | ~~Compte de servei~~ | ✅ **16/09/2026**: `AGRIENERGIA\sapsistema` |
| 8 | ~~Crear `C:\Apps\SapB1AnalitzaSync`~~ | ✅ **16/09/2026**, amb l'ACL correcta |
| 8 | ~~Accés d'`ohijazo` a `AE01SAPRDP`~~ | ✅ **16/09/2026**: RDP concedit (primer intent: `0x3`/`0x9`, que és *no autoritzat per a inici de sessió remot*, no xarxa) i `(OI)(CI)(F)` sobre la carpeta |
| 8 | ~~Sortida de `.239` cap a `.238`, ports 50000 i 1433~~ | ✅ **Ja hi passava.** Comprovat des de la màquina amb `Test-NetConnection`: no calia cap regla de firewall |
| 8 | ~~¿`sapsistema` és admin i es comparteix?~~ | ✅ **No a totes dues.** Compte dedicat, creat el 15/09, sense grups locals i amb contrasenya que no caduca |
| 8 | ~~*Log on as a batch job* per a `sapsistema`~~ | ✅ **16/09/2026**, per **directiva local**. Si algun dia una GPO el tomba, el símptoma són dades congelades, no un error |
| 8 | ~~Registre de la tasca de les 02:45~~ | ✅ **16/09/2026**: `GAPI07 Refresca sap_raw`, arrel, diària 02:45, `sapsistema` |
| 8 | ~~Provar-la~~ | ✅ **16/09/2026 15:20:48**, `LastTaskResult = 0` i `sync_state` refrescat |
| — | Qui refresca `DB_FARINERA_TEST`, ells o Seidor | Obert. La pregunta és del 07/09 però no els va arribar fins al 10/09 |

**Bloc B — Handoff.** ✅ Contrasenya d'`analitza_ro` rotada el 31/08/2026 i el compte acotat al
contracte. ✅ Correu enviat el 31/08/2026 (`resposta_adria_2.docx`). ✅ **Sistemes van habilitar
l'accés el 10/09/2026**: Analitza ja entra per VPN a `AE01SAPSQL:1433`, i no calia enviar-los cap
endpoint perquè les credencials de VPN són les que ja tenien.

✅ **Contrasenya passada el 16/09/2026** per un canal a part, i **l'endpoint el 17/09**
(`192.168.11.238:1433`, BD `IntercanviSAP`), que és el que ell va demanar tot seguit: tenia
credencial i no sabia on connectar-se.

Va costar de maig a setembre i el que el va resoldre no va ser una obertura de firewall —que mai no
va caldre— sinó demanar l'activació i adonar-se que entraven per VPN.

⏳ **Però el Bloc B no es pot donar per tancat fins que l'Adrià confirmi que ha connectat.** El 16/09
es va donar per fet i faltava l'endpoint. La lliçó és la mateixa de tota la setmana: **fins que algú
no recorre el camí sencer, això està fet sobre el paper**. Si li falla, el primer a mirar no és la
credencial sinó si la VPN encamina cap a `192.168.11.x` — els clients de VPN surten per
`192.168.254.x`, i que els habilitessin l'accés no vol dir que la ruta hi sigui.

> ⚠️ Sistemes ho van comunicar com «les credencials i l'url són les mateixes, no ha canviat res».
> Per la VPN és cert; **pel login de SQL no**. La contrasenya d'`analitza_ro` es va rotar el
> 31/08/2026 i el mateix dia el compte va sortir de `db_datareader`. Si l'Adrià prova amb la que
> tenia guardada, el símptoma és un login fallit que sembla un problema de xarxa, i el diagnòstic
> se'n va cap a Sistemes durant dies. Avisar-los tots dos alhora.

> ✅ **`resposta_adria_3.docx` enviat el 16/09/2026**, després de setze dies escrit sense sortir.
> Porta l'avís que `IntercanviSAP` apunta a la SAP de proves i que no s'hi ha de carregar res cap a
> producció —just el dia que `dbo.est_*` va començar a refrescar-se de debò—, l'avís que la
> contrasenya d'`analitza_ro` va canviar el 31/08, la decisió de mantenir les seves 12 famílies amb
> els números al davant, i una sola pregunta de tornada: **el «confirmat» per escrit del `/100`**.
>
> ✅ **Contrasenya passada el mateix dia.** D'ell només queda **el «confirmat» per escrit del `/100`**.
> Si contesta llarg sobre famílies i se'l salta, repreguntar-ho sol: és l'únic punt del projecte que
> falla en silenci.

**Bloc C — Pendent amb l'Adrià.** Revisat contra els seus correus del 12/05/2025
(`docs/correus_adria_2025-05-12.md`), tres dels pendents ja tenen resposta o camí:

- **Els filtres de KAIS**: no cal investigar-los. L'Adrià **ja es va oferir a passar les seves SQL**
  ("si vols et puc passar les nostres SQL perquè vegis els filtres que vam aplicar sobre de KAIS").
  L'oferta és de maig de 2025 i encara no s'ha recollit. Només cal demanar-ho.
- **`ZONA`** ja el produïm (`zone_id` / `zone_description`, de `CRD1.U_SEIZONAC`).
- **`RAÓ SOCIAL` i `ACTIU`** segueixen sense produir-se com a atributs. Probablement es cobreixen
  amb `est_clients.name` i `est_clients.active`, però com a **atributs** no hi són. Cal confirmar
  amb ell si els fa servir: si sí, falten dues columnes a `est_atributs_client`.
- De propina: produïm `payment_method` i `payment_description`, que **no són a la seva llista**
  d'atributs. No fa mal, però ningú els mira.

Segueix obert: implementar `new_code` amb els UDFs `U_FCKaisCode` / `U_FCNewCardCode` a `OCRD`
(proposta enviada a `resposta_adria_1.md`). El correu de l'Adrià confirma que `new_code` és un dels
camps que consumeixen.

**Preguntes seves sense resposta des de maig de 2025:** hi haurà bolcat de les dades actuals a SAP i
de quin històric es comptarà? Disposaran d'una base de dades de test?

> Nota per quan es faci: al `$metadata` de SAP ja existeix un `U_FCCodiKais`, però penjat de
> **`SalesPerson`**, no de `BusinessPartner`. Val la pena mirar-ho abans de demanar un UDF nou.
> I la convenció de la casa és el prefix `U_FC` (els UDFs existents fan servir `U_SEI`, del
> partner Seidor).

**Bloc E — Cutover, 2 de novembre de 2026.** Tall sec: KAIS deixa de rebre dades el mateix dia que
SAP arrenca.

> Els passos concrets del dia, amb ordre, comprovacions i rollback, són a
> **`docs/runbook_cutover.md`** (escrit el 31/08/2026). Fins llavors estaven escampats entre aquesta
> memòria, la Regla 04 i la nota interna de dos correus, i són cinc canvis coordinats del mateix dia.


- **Data límit 1 de novembre**, no el dia 2: els UDFs amb els codis de KAIS han d'estar creats i
  **poblats** abans. Si el dia 2 s'envien els codis de SAP, Analitza els ingereix com a clients nous
  i desfer-ho després surt molt més car que fer-ho bé d'entrada. Això converteix la creació dels
  UDFs en feina amb data.
- El dia 2: canviar `ServiceLayer:CompanyDb` a `DB_FARINERA_PROD` i, si l'Adrià ho accepta,
  normalitzar el `discount` de manera coordinada.
- Els primers dies: revisar amb ell que les xifres siguin coherents. No es podran comparar amb
  KAIS; es comparen contra el negoci.
- `est_linies_albara` arrencarà gairebé buida i anirà creixent: a la SAP productiva no hi haurà
  albarans anteriors al tall.

### Higiene

- **`analitza_ro` veia molt més que el contracte — tancat el 31/08/2026.** Era `db_datareader` de
  tota la BD, i comprovat en viu podia llegir `sap_raw.OCRD`, `sap_raw.DLN1`, `staging.*`, `audit.*`
  i `cfg.settings`. La Regla 01 diu que Analitza «no veu SAP mai» i la Regla 04 diu que el contracte
  són les vuit `dbo.est_*`; amb `db_datareader` veia una còpia literal de les taules internes de SAP,
  cosa que a més empitjora la pregunta oberta del **licenciament indirecte** (§9), que no va del
  compte tècnic sinó de qui consumeix les dades.

  Ara: `GRANT SELECT ON SCHEMA::dbo` —`dbo` conté exactament les vuit `est_*` i res més— i `DENY
  SELECT` explícit a `sap_raw`, `staging`, `audit`, `cfg` i `etl`. Verificat amb `EXECUTE AS`: llegeix
  `dbo.est_*` i no llegeix cap de les altres.

- **Contrasenya d'`analitza_ro` rotada el 31/08/2026** amb
  `sql/security/Rotate-AnalitzaPassword.ps1`, que la demana interactivament, no l'escriu enlloc, i
  **es connecta amb la nova** per comprovar que llegeix `dbo.est_*` i que `sap_raw` li és denegat
  abans de donar-la per bona. Deixa de bloquejar el handoff; ara depèn que Sistemes els habiliti
  l'accés per VPN (Bloc A).

  Rotar un login és una operació de **servidor** i `ohijazo_sql` no hi arriba a propòsit: cal
  `-AdminUser sa`. No se li ha d'afegir `ALTER ANY LOGIN` per estalviar-s'ho — amb aquest permís es
  pot canviar la contrasenya de qualsevol login, `sa` inclòs, i el compte acotat deixaria de
  ser-ho.
- **Rotar la contrasenya de `sa`**: ha quedat exposada durant la sessió del 25/08/2026. Decidit el
  31/08 **no rotar-la encara**: aquest servidor allotja SAP B1 i no es pot verificar qui més la fa
  servir. L'ordre és **deixar de necessitar-la primer**, i llavors rotar-la amb Sistemes al davant
  deixa de ser un risc per a nosaltres. On era:

  | On | Estat |
  |---|---|
  | El job de SQL Agent | ✅ ara corre com a `gapi07_etl` |
  | El Worker desplegat a `AE01SAPRDP` | anirà amb `gapi07_worker` a `appsettings.Production.json` |
  | Desplegaments, sonda i user-secrets locals | ✅ **fet el 31/08/2026**: login nominal `ohijazo_sql`
    (`sql/security/Create-AdminUser.ps1`) |

  `ohijazo_sql` té `db_owner` **només** a `IntercanviSAP`, `SQLAgentOperatorRole` a `msdb` i
  `DENY CONNECT` a `DB_FARINERA_TEST` i `SBO-COMMON`. Verificat: `IS_SRVROLEMEMBER('sysadmin') = 0`
  i **cap rol de servidor**. El `SQLAgentOperatorRole` hi és perquè `sqlagent_analitza_etl_daily.sql`
  fa `sp_add_job`: sense això el desplegament falla a mitges i algú tornaria a agafar `sa`, que és
  exactament el camí de tornada que es vol tancar.

  Provat d'extrem a extrem amb la credencial nova: `--once` refresca el mirall, i `sp_run_all` fa
  els nou passos i s'atura al `vanished_ids` de sempre. Els user-secrets ja no contenen `sa` i les
  sis claus hi són senceres.

  **El que queda de `sa`**: `appsettings.Production.json` a `AE01SAPRDP`, que encara no existeix, i
  allà hi ha d'anar `gapi07_worker`. A partir d'aquí, rotar `sa` és una conversa amb Sistemes i ja
  no ens afecta.

  És **nominal** i no tècnic perquè el fa servir una persona, no un procés: a l'auditoria hi ha de
  constar qui va fer la feina manual. Els comptes tècnics (`gapi07_worker`, `gapi07_etl`) són per al
  que corre sol.
- ~~Primer commit del repo~~ ✅ fet el 25/08 (`ef846fa`)

---

## 10. Operativa

### Refrescar el mirall i executar l'ETL a mà

```powershell
$env:DOTNET_ENVIRONMENT='Development'
dotnet run --project P:\GAPI07_Analitza\src\SapB1AnalitzaSync.Worker -- --once
```
```sql
EXEC IntercanviSAP.etl.sp_run_all @SkipSwap=1, @ForceFullLines=1;   -- mode inspecció
EXEC IntercanviSAP.etl.sp_run_all;                                   -- de debò
```

### Provar Service Layer sense tocar cap BD

```powershell
dotnet run --project P:\GAPI07_Analitza\src\SapB1AnalitzaSync.Worker -- --probe
```

### Recarregar l'històric

```powershell
dotnet run --project P:\GAPI07_Analitza\src\SapB1AnalitzaSync.Worker -- --backfill --from 2020-01-01
```

### Provar que l'alerta per correu funciona

**Un correu enviat amb `sp_send_dbmail` no demostra res sobre el job**: aquell no passa pel SQL
Agent, i el job sí. Es pot tenir el test a la bústia i no rebre res la nit que falli de debò.

La manera de provar-ho sense moure cap dada: posar el llindar de frescor a 0 i llançar el job. Aquell
camí de `sp_run_all` fa `THROW` **abans de tocar `staging`**, així que només deixa un run
`ABORTED_STALE_MIRROR` a l'historial.

```sql
UPDATE IntercanviSAP.cfg.settings SET [value]='0' WHERE [key]='MIRROR_MAX_AGE_HOURS';
EXEC msdb.dbo.sp_start_job @job_name = N'Analitza_ETL_Daily';
-- esperar que acabi, mirar la bustia, i tot seguit:
UPDATE IntercanviSAP.cfg.settings SET [value]='6' WHERE [key]='MIRROR_MAX_AGE_HOURS';
```

Ha d'arribar un correu del SQL Agent amb `STATUS: Failed`. Fet el **17/09/2026** (run 141) i va
arribar. **El run 141 és aquesta prova, no una avaria** — si es mira l'historial i es veu un
`ABORTED_STALE_MIRROR` aquell matí, és això.

Val la pena repetir-ho després de qualsevol canvi al SQL Agent, al mailbox o a la contrasenya: és
l'única comprovació que recorre el camí sencer.

### Diagnòstic

```sql
-- Estat de les últimes càrregues
SELECT TOP 5 run_id, started_at, finished_at, status, error_message
FROM IntercanviSAP.audit.etl_runs ORDER BY run_id DESC;

-- El mirall és fresc?  Mirar això PRIMER si algun recompte sorprèn
SELECT entity, last_update_date, last_full_at, last_rows, updated_at
FROM IntercanviSAP.sap_raw.sync_state ORDER BY entity;

-- Detall dels passos
SELECT step_name, status, rows_in, rows_out, duration_ms, LEFT(error_message,200) AS err
FROM IntercanviSAP.audit.etl_step_log
WHERE run_id = (SELECT MAX(run_id) FROM IntercanviSAP.audit.etl_runs) ORDER BY step_id;

-- Warnings de qualitat (9 checks)
SELECT severity, check_name, details FROM IntercanviSAP.audit.data_quality_warnings
WHERE run_id = (SELECT MAX(run_id) FROM IntercanviSAP.audit.etl_runs);
```


### El terra mínim de files (afegit 26/08/2026)

El 25/08 `sp_load_invoice_lines` va carregar 0 línies tenint-ne 57 al mirall, i **els vuit checks
van donar 0 crítics**: amb la taula buida no hi ha orfes, la fórmula no es pot trencar, els signes
quadren, i el check de volum calcula la mitjana sobre la mateixa taula buida, treu NULL i se salta
tot sol. El swap hauria publicat la taula buida.

Aleshores es va corregir el `LineType`, que n'era **una** causa. El forat seguia obert: qualsevol
altra cosa que buidés les línies hauria passat igual. I `vanished_ids` no ho cobreix, perquè mira
mestres, no moviments.

- `lines_empty` — CRITICAL si `staging.est_linies_albara` queda buida i ahir no ho estava.
- `lines_collapsed` — CRITICAL si baixa per sota de `cfg.settings.LINES_MIN_RATIO` (0.95 per
  defecte) respecte d'ahir. Les línies són històric acumulat: el recompte no hauria de minvar.
- `receivables_empty` — CRITICAL si `est_cobraments` queda buida. Aquí només es vigila el zero,
  perquè els cobraments sí que fluctuen: una factura es cobra i desapareix.

**Al cutover caldrà abaixar `LINES_MIN_RATIO`**: la SAP productiva arrenca sense històric
d'albarans, així que el recompte caurà a propòsit.

Provat el 26/08 als quatre casos: dades correctes no salta; taula buida dona `lines_empty`; 52 de
62 files (84%) dona `lines_collapsed`; i restaurat torna a estar net.

### El check `vanished_ids` (afegit 26/08/2026)

Els identificadors que enviem a Analitza són un contracte. Si un `id_client_location` que ahir hi
era avui no hi és, Analitza no veu un error: veu un client que ha deixat de comprar, i el dona per
perdut. El mateix amb productes, famílies i comercials.

`dbo.*` té la foto d'ahir i `staging.*` la d'avui, així que la comprovació és un `EXCEPT`. Cobreix
una família sencera de fallades silencioses —un camp que es queda buit a l'origen, un filtre que
descarta de més, un mapatge que canvia sense avisar— que **cap dels altres set checks detecta**,
perquè totes deixen les taules coherents amb elles mateixes. El bug del `LineType` n'era una.

WARN mentre siguin poques; **CRITICAL a partir de `cfg.settings.ID_DROP_MAX`** (per defecte 10), i
llavors atura el swap. El llindar existeix perquè hi ha desaparicions legítimes, i perquè el dia
del cutover pot caldre apujar-lo expressament.

Provat el 26/08/2026 als tres casos: sense diferències no salta; amb 4 identificadors esborrats dona
WARN sense bloquejar; amb el llindar a 2 dona CRITICAL i retorna `critical=1`, que és el que fa que
`sp_run_all` avorti el swap.

Estats de `etl_runs`: `SUCCESS` · `SUCCESS_NOSWAP` (cridat amb `@SkipSwap=1`) · `BLOCKED` (warnings
CRITICAL, swap avortat, `dbo.*` es queda amb les dades d'ahir) · `FAILED`.

### Desplegar

```powershell
$env:SQLPASS = '...'
P:\GAPI07_Analitza\deploy_via_powershell.ps1     # sqlcmd no està instal.lat en aquest sistema
```

Idempotent. **No** inclou `03_create_baseline.sql`, que es pren una sola vegada i a mà.

### Regenerar el .docx d'un document

Per a un document normal, sense retallar:

```
python tools/md2docx.py comunicacio_udfs_sap.md comunicacio_udfs_sap.docx
```

### Regenerar el .docx d'un correu

Els correus viuen en parella `.md` (font, amb la nota interna al final) i `.docx` (el que s'envia,
només el cos). Per no desincronitzar-los:

```
python tools/md2docx.py resposta_adria_1.md resposta_adria_1.docx ^
    --from "Hola Adrià," --to "ohijazo@agrienergia.com"
```

`--from` i `--to` retallen el cos, així que **la capçalera de destinataris i la nota interna no hi
entren mai**. Si el `.docx` està obert al Word, la regeneració falla amb `PermissionError` i el fitxer es
queda enrere en silenci: tancar-lo abans.

### Afegir un UDF nou com a atribut

Ara són quatre llocs, i si se'n salta un el camp arriba buit sense error:

1. `ODataQueryBuilder.PartnerFields` o `ItemFields` — si no és al `$select`, SL no el retorna
2. La taula corresponent de `sql/schema/02_create_sap_raw.sql`
3. El DTO a `Dtos.cs` i el `DataTable` a `MirrorTables.cs`
4. El SP que el projecta (`etl_sp_load_client_attributes.sql` o `etl_sp_load_product_attributes.sql`)

---

## 11. Estructura del codi

```
P:\GAPI07_Analitza├── CLAUDE.md + .claude
ules\      Regles del projecte (5)
├── docs│   ├── memoria_projecte.md         Aquest fitxer
│   ├── runbook_cutover.md          Els passos de l'1 i el 2 de novembre
│   ├── correus_adria_2025-05-12.md Els correus de l'Adrià, transcrits dels PDF
│   ├── Guia de importación de datos Analitza CM v9.pdf
│   └── Integracio_GAPI07.pdf
├── tools│   └── md2docx.py                  Genera el .docx d'un correu des del .md
├── src│   ├── SapB1AnalitzaSync.Shared\   Opcions, ODataQueryBuilder, SapEnums, DTOs
│   ├── SapB1AnalitzaSync.Worker\   ServiceLayerClient, MirrorSyncService,
│   │                               MirrorRepository, MirrorTables, ProbeService
│   └── tests\                      xUnit — 27 tests
├── sql│   ├── schema\  01_create_database · 02_create_sap_raw · 03_create_baseline
│   ├── procs\   11 stored procedures
│   ├── cfg\     seeds de país, zona i atributs
│   ├── security\ create_analitza_user · revoke_sap_direct_access
│   ├── jobs\    sqlagent_analitza_etl_daily
│   └── verify.sql · verify_migration.sql · deploy.sql · cleanup_master.sql
└── correu_adria · resposta_adria_1 · comunicacio_udfs_sap ·
    draft_resposta_sistemes                                   (.md i .docx)
```

**Els correus van en parella `.md` + `.docx`.** El `.md` és la font i porta una nota interna al
final que **no s'envia**; el `.docx` el genera `tools/md2docx.py` agafant només el cos. Veure §10.

---

## 12. Contactes i referències

| Qui | Rol | Contacte |
|---|---|---|
| Adrià Arnau | CTO Analitza CM | adria@analitza.com — 680 73 43 72 |
| Lluís Butinya | Director Compres/Admin Agrienergia | lbutinya@agrienergia.com — 972 583 363 |
| Sistemes Agrienergia | Servidors, VM, xarxa, firewall, SMTP | canal intern |
| Oscar Hijazo | SAP (UDFs i configuració), `IntercanviSAP`, l'ETL i el Worker | ohijazo@agrienergia.com |

- `P:\GAPI03_CRM` — l'altra integració SAP. D'allà venen el client de Service Layer i els gotchas
  d'OData. El seu `reference\sap_b1_metadata.xml` és el bolcat de `$metadata` de la instal·lació
  d'Agrienergia: serveix per comprovar si una propietat existeix sense haver de cridar SAP.
- `docs\correus_adria_2025-05-12.md` — els dos correus de l'Adrià transcrits. Els PDF originals
  són exports d'Outlook amb fonts Type3 sense capa de text: no es poden llegir ni cercar
- `P:\preparacioComandesVendaSAP\.env` — d'on surten les credencials de Service Layer i de SQL
- Pla de treball de la migració:
  `C:\Users\ohijazo.AGRIENERGIA\.claude\plans\revisa-com-est-aquest-precious-conway.md`
