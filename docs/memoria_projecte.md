# GAPI07_Analitza — Memòria del projecte

> Visió executiva completa: què és, com funciona, què s'ha decidit i per què, què s'ha
> trobat pel camí i què queda obert.
>
> Última actualització: **25/08/2026**

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

**⚠️ El pas 1 del job falla, i és esperat.** El Worker s'executa amb els user-secrets d'un usuari
concret, que només es carreguen amb `DOTNET_ENVIRONMENT=Development`. El compte de servei de SQL
Agent no els té: surt amb codi 3, el pas 2 no s'executa i `dbo.est_*` es queda amb les dades
anteriors. **Falla de manera segura, però falla cada nit** i envia avís a `AnalitzaOps`.

Per resoldre-ho calen variables d'entorn de màquina per al compte de SQL Agent:
`ServiceLayer__BaseUrl`, `__CompanyDb`, `__UserName`, `__Password`,
`__AllowInvalidCertificates` i `Database__ConnectionString`. Té sentit fer-ho alhora que es crea
l'usuari tècnic dedicat (§9), per no haver de posar-hi dues vegades les credencials.

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

Si l'Adrià ho accepta, la feina és: crear els UDFs a SAP, afegir-los a `sap_raw`, i canviar
`sp_load_salesmen`, `sp_load_product_categories` i `sp_load_clients` perquè els projectin amb la
regla **`id = COALESCE(U_FCCodiKais, <codi SAP>)`**: qui ve de KAIS manté el seu codi, qui és nou
porta el de SAP. Els dos formats no es poden trepitjar (8 dígits vs `C` + 6).

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

**Res d'això no està implementat**: primer cal la confirmació de l'Adrià.

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

**`deploy.sql` NO és idempotent, encara que ho digui.** `01_create_database.sql` comença amb
`DROP TABLE dbo.est_*` — les vuit taules que llegeix Analitza — per tornar-les a crear buides.
Executar `deploy.sql` sencer deixa Analitza sense dades fins a la següent càrrega correcta.

Per això el 25/08 es van desplegar **només els procediments**, un per un, i no amb `deploy.sql`.

Cal decidir què se'n fa: o s'hi posa una guarda que impedeixi executar-lo si `dbo.est_*` té files,
o es treu la paraula "idempotent" del capçal i del README i es documenta com a script de creació
inicial. **Mentre no es faci, no executar `deploy.sql` en un entorn amb dades.**

### Falsa alarma

Els runs de `audit.etl_runs` surten a la 01:00 i el job està programat a les 03:00. No és cap
desajust: `etl_runs.started_at` guarda **UTC** i a l'agost anem a UTC+2.

---

## 9. Què queda obert

### Decisions pendents

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

  Se li proposa normalitzar-ho el dia del tall. **Si accepta, van tres canvis alhora, tots tres o
  cap:**
  1. `sp_load_invoice_lines`: emetre `1 - multiplicador`.
  2. `sp_data_quality_checks`: el check `formula_break` passa a `price × qty × (1 - discount)`.
  3. `.claude/rules/04-contracte-analitza.md` i aquesta memòria, que ara documenten la convenció
     del multiplicador com si fos la bona.

  Si ell no treu el seu `1 - discount` el mateix dia, falla de manera sorollosa: els descomptes
  passarien de `0.00` a `1.00` i els imports sortirien a zero. Val més això que un error silenciós.
- **Refresc de `DB_FARINERA_TEST` des de productiva**, per poder validar de debò.

### Migració

Fases 0 a 4 tancades (§5, §6). Queda:

- **Configurar el Worker per al compte de SQL Agent**, o el job seguirà fallant cada nit (§5).
- **Fase 5**: executar `sql/security/revoke_sap_direct_access.sql`. Fins que no es faci, la
  prohibició de llegir taules internes de SAP és només documental: tècnicament encara es pot.
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

- **Rotar la contrasenya de `sa`**: ha quedat exposada durant la sessió del 25/08/2026
- Login dedicat per a l'ETL i el Worker en comptes de `sa`
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

-- Warnings de qualitat (8 checks)
SELECT severity, check_name, details FROM IntercanviSAP.audit.data_quality_warnings
WHERE run_id = (SELECT MAX(run_id) FROM IntercanviSAP.audit.etl_runs);
```


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
python tools/md2docx.py peticio_udfs_sap.md peticio_udfs_sap.docx
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
└── correu_adria · resposta_adria_1 · peticio_udfs_sap ·
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
