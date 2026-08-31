# GAPI07_Analitza — Memòria del projecte

> Visió executiva completa: què és, com funciona, què s'ha decidit i per què, què s'ha
> trobat pel camí i què queda obert.
>
> Última actualització: **31/08/2026**

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

**El Worker corre a `AE01SAPRDP`, no al servidor de SQL.** El job de SQL Agent apuntava a
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

**Bloquejat**: no tenim accés a `AE01SAPRDP`. El desplegament el fa Sistemes, amb la petició de
`peticio_sistemes_worker.docx`. Fins llavors el job de les 03:00 avortarà amb
`ABORTED_STALE_MIRROR`, que és el comportament correcte: no publica res.

**Quatre comptes diferents, i els crea gent diferent:**

| Compte | Per a què | Qui |
|---|---|---|
| Windows (`AGRIENERGIA\svc_gapi07`) | Executar la tasca a `AE01SAPRDP` | Sistemes |
| SAP Service Layer (`GAPI07_RO`) | Llegir SAP. Ara va amb `OHijazo`, nominal | Oscar |
| SQL Server (`gapi07_worker`) | Escriure a `sap_raw`. En local encara va amb `sa` | Oscar — `sql/security/Create-WorkerUser.ps1` |
| SQL Server (`gapi07_etl`) | Context del pas del job. **Sense login**: no s'hi connecta ningú, només s'impersona | Oscar — `sql/security/create_etl_user.sql`, 31/08/2026 |

Per al de SAP hi ha guia a `docs/usuari_tecnic_sap.md`, amb un avís que pot bloquejar: **un usuari
de SAP consumeix llicència**. Si no n'hi ha cap de lliure, no es pot crear i cal decidir-ho amb el
partner. Per al de SQL hi ha un llançador que demana la contrasenya interactivament i no l'escriu
enlloc.

**`AE01SAPRDP` allotja webservices de col·laboradors externs.** Per això la configuració no va a
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
| **Clients** | ❌ **No, i sense pont** | `BusinessPartner.U_SEICodienllac` només està informat en **10 de 500**, i la numeració no lliga amb el `CardCode` (`C201128` ↔ `201011`) |
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

### 6.5 El número d'adreça tampoc era el de KAIS (28\08\2026)

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

**El que costa:** si algú esborra una adreça de ship-to a SAP, totes les posteriors del mateix client
es renumeren, i per a Analitza això són ubicacions que desapareixen i ubicacions noves amb l'històric
buit. `vanished_ids` ho detecta l'endemà, però ho detecta, no ho evita. La solució estable és
congelar el número per (client, adreça) en una taula al tall i fer servir la seqüència només per a
les adreces noves. **Pendent de decidir**; mentrestant això és correcte per al 99,1% i el que hi
havia ho era per al 6%.

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

### Llicenciament de SAP — obert, i més gran del que sembla

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

### Decisions pendents

**Correu enviat a l'Adrià el 31/08/2026** (`resposta_adria_2.md` / `.docx`). Hi van cinc preguntes, i
tres bloquegen feina nostra amb data 1 de novembre:

1. **El `/100`** — la urgent. Les seves SQL divideixen `product_price` i `product_cost` per 100 però
   no `net_amount`. O el treu ell el dia del tall, o els hi enviem multiplicats per 100, però s'ha de
   decidir: sense resposta és un error silenciós el dia 2. Si no contesta, insistir-hi sol.
2. **Famílies**: els 110 grups de SAP (canvia la taxonomia) o la categoria comercial (la conserva,
   però 1.776 de 2.028 articles no la tenen informada).
3. **Congelar el número d'adreça** al tall, o confiar en l'alarma `vanished_ids` (§6.5).
4. **Si la seva càrrega acumula o substitueix** la finestra de 90 dies. Si substitueix, el problema
   del cost d'octubre és molt més gros del que ell descriu.
5. **`RAÓ SOCIAL` i `ACTIU` com a atributs**: si els vol, són dues columnes noves a
   `est_atributs_client` i un canvi a `sp_load_client_attributes`.


- **Usuari tècnic de SAP.** Ara la sonda va amb `OHijazo`, un usuari **nominal**, amb contrasenya
  de 4 caràcters. Per a la sonda és acceptable (només llegeix), però per al job nocturn no: els
  logs d'auditoria de SAP atribuirien les lectures de l'ETL a una persona, i el dia que aquesta
  persona canviï la contrasenya o marxi, l'ETL peta. Cal crear un usuari tècnic dedicat de només
  lectura.
- **`product_cost`**: acordar amb l'Adrià quina definició de cost hi posem (§6.2). De moment surt
  **0 a propòsit** (`Sync:CostField = "none"`), perquè es vegi que no el tenim.
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

### Migració

Fases 0 a 4 tancades (§5, §6). Queda:

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

**Bloc A — Sistemes:** compte SMTP per a Database Mail; obrir el port 1433 per a la IP d'Analitza.
Són feina d'infraestructura, no de SAP.

**Bloc B — Handoff:** rotar la contrasenya d'`analitza_ro` (ara és un placeholder desconegut);
enviar el correu a l'Adrià (`correu_adria.md`); confirmar que la seva VPN arriba a `AE01SAPSQL`.

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

- **Rotar la contrasenya d'`analitza_ro`**, que és un placeholder desconegut i bloqueja el handoff.
  Hi ha `sql/security/Rotate-AnalitzaPassword.ps1`, que la demana interactivament, no l'escriu
  enlloc, i **es connecta amb la nova per comprovar que funciona** abans de donar-la per bona.
- **Rotar la contrasenya de `sa`**: ha quedat exposada durant la sessió del 25/08/2026. Decidit el
  31/08 **no rotar-la encara**: aquest servidor allotja SAP B1 i no es pot verificar qui més la fa
  servir. Primer treure-la del nostre camí —el job ja no hi va— i després rotar-la amb Sistemes al
  davant.
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
