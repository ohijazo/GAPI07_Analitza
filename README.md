# GAPI07_Analitza — Integració SAP B1 → Analitza CM

Aquest projecte substitueix l'origen de dades d'Analitza CM: en comptes de tirar de KAIS,
ara alimenta les seves taules `est_*` directament des de SAP Business One.

**Estat actual:** ✅ Desplegat i funcionant a **test**. Cutover a productiva el **2 de novembre de 2026**
(tall sec: KAIS deixa de rebre dades el mateix dia que SAP arrenca).

**Canvi en curs:** l'ETL ha deixat de llegir les taules internes de SAP per SQL directe i ara les
llegeix per **Service Layer**, com fa `GAPI03_CRM`. Veure [§7](#7-migració-a-service-layer-estat).

---

## Índex ràpid

- [1. Com funciona (esquema)](#1-com-funciona-esquema)
- [2. Estructura del projecte](#2-estructura-del-projecte)
- [3. Què està fet i què queda](#3-què-està-fet-i-què-queda)
- [4. Operativa diària (com fer coses)](#4-operativa-diària-com-fer-coses)
- [5. Contactes](#5-contactes)
- [6. Documentació de referència](#6-documentació-de-referència)
- [7. Migració a Service Layer (estat)](#7-migració-a-service-layer-estat)

---

## 1. Com funciona (esquema)

```
                       ┌────────────────────────────┐
                       │   SAP Business One          │
                       │   Service Layer (HTTPS)     │
                       │   usuari tècnic RO          │
                       └──────────────┬──────────────┘
                                      │
                                      │  Cada nit a les 03:00, pas 1 del job
                                      │  SapB1AnalitzaSync.Worker --once
                                      ▼
                       ┌────────────────────────────┐
                       │   IntercanviSAP             │  ← BD intermèdia
                       │   (AE01SAPSQL)              │     que hem creat
                       │                             │
                       │   sap_raw.*   ← mirall SAP  │
                       │      │                      │
                       │      │ pas 2: etl.sp_run_all│
                       │      ▼                      │
                       │   staging.est_*  ─────────┐ │
                       │      │                    │ │
                       │      │ swap atòmic        │ │
                       │      ▼                    │ │
                       │   dbo.est_*  ←── QA OK ──┘ │
                       └──────────────┬──────────────┘
                                      │
                                      │  Analitza es connecta a les 05:00
                                      │  via VPN amb usuari "analitza_ro"
                                      │  (només lectura a IntercanviSAP)
                                      ▼
                       ┌────────────────────────────┐
                       │   Analitza CM               │
                       │   (plataforma d'anàlisi)    │
                       └────────────────────────────┘
```

**Idea clau:** SAP no s'exposa mai directament a Analitza. Nosaltres extraïem, validem, i publiquem
una BD read-only pensada per ells. Les 8 taules `est_*` mantenen exactament els mateixos noms i
estructura que KAIS els proporcionava, així que Analitza no ha de canviar les seves consultes SQL.

**Per què un mirall `sap_raw`?** Perquè cap consulta nostra toqui taules internes de SAP, però la
lògica de transformació validada (fórmula del descompte, derivació d'IDs, fallback de ship-to)
segueixi sent el mateix T-SQL de sempre. El Worker només extreu; els SPs només transformen.

**Per què staging + swap?** Perquè Analitza no vegi mai dades a mig carregar. L'ETL treballa a
`staging.*`, valida (fórmules, orfes, formats), i només si tot passa, fa `TRUNCATE + INSERT` a
`dbo.*` dins una transacció.

---

## 2. Estructura del projecte

```
P:\GAPI07_Analitza\
│
├── README.md                          ← Aquest fitxer
├── CLAUDE.md                          ← Regles del projecte (.claude/rules/)
│
├── docs\                              ← Documentació externa
│   ├── Guia de importación de datos Analitza CM v9.pdf
│   ├── Integracio_GAPI07.pdf
│   └── Re_ Integració Analitza amb SAP_ Oscar Hijazo - Outlook.pdf
│
├── src\                               ← Worker .NET 8 (SAP → sap_raw)
│   ├── SapB1AnalitzaSync.sln
│   ├── SapB1AnalitzaSync.Shared\      ← Opcions, ODataQueryBuilder, SapEnums
│   ├── SapB1AnalitzaSync.Worker\      ← Client de Service Layer i sincronització
│   └── tests\SapB1AnalitzaSync.Tests\ ← xUnit
│
├── sql\                               ← TOT el codi ETL (SQL Server)
│   ├── deploy.sql                     ← Orquestrador de desplegament
│   ├── verify.sql                     ← Sanity check post-execució
│   ├── verify_migration.sql           ← staging vs baseline (Fase 4)
│   ├── cleanup_master.sql             ← Neteja completa (perillós)
│   │
│   ├── schema\
│   │   ├── 01_create_database.sql     ← IntercanviSAP + schemas + taules est_*
│   │   ├── 02_create_sap_raw.sql      ← Mirall de SAP que omple el Worker
│   │   └── 03_create_baseline.sql     ← Fotografia de referència (un sol cop)
│   │
│   ├── procs\                         ← 11 stored procedures ETL
│   │   ├── etl_sp_run_all.sql         ← Orquestrador (el que crida el job)
│   │   ├── etl_sp_load_clients.sql
│   │   ├── etl_sp_load_invoice_lines.sql
│   │   ├── etl_sp_load_products.sql
│   │   ├── etl_sp_load_product_categories.sql
│   │   ├── etl_sp_load_salesmen.sql
│   │   ├── etl_sp_load_client_attributes.sql
│   │   ├── etl_sp_load_product_attributes.sql
│   │   ├── etl_sp_load_receivables.sql
│   │   ├── etl_sp_data_quality_checks.sql  ← 9 validacions abans del swap
│   │   └── etl_sp_swap_staging_to_prod.sql ← Swap atòmic staging→dbo
│   │
│   ├── cfg\                           ← Seeds de configuració
│   │   ├── seed_attribute_mapping.sql       ← UDFs → nom Analitza
│   │   ├── seed_country_code_overrides.sql  ← ex: 'ESPAÑA' → 'es'
│   │   └── seed_zone_code_mapping.sql
│   │
│   ├── security\
│   │   ├── create_analitza_user.sql   ← Login analitza_ro
│   │   └── configure_database_mail.sql ← Notificacions SMTP (pendent)
│   │
│   └── jobs\
│       └── sqlagent_analitza_etl_daily.sql  ← Job SQL Agent 03:00 (2 passos)
│
├── handoff_analitza.docx              ← Document original per Adrià
├── correu_adria.md                    ← Correu adaptat llest per enviar
├── resposta_adria_1.md                ← Resposta sobre IDs i new_code
└── draft_resposta_sistemes.md         ← Correu a Sistemes (VPN, firewall, backup, SMTP)
```

---

## 3. Què està fet i què queda

### ✅ Fet i funcionant

- BD `IntercanviSAP` desplegada a `AE01SAPSQL`
- 8 taules `est_*` a `dbo` i `staging`
- 11 stored procedures ETL compilats
- Job `Analitza_ETL_Daily` corrent cada dia a les 03:00
- Login `analitza_ro` creat amb permisos només-lectura a `IntercanviSAP`
- Dades a test (run 91, 24/08/2026): 5.651 client_locations, 2.028 productes,
  5.651 atributs client, 110 famílies, 49 agents
- ⚠️ **`DB_FARIN_TEST` gairebé no té documents**: 62 línies d'albarà (47 documents,
  maig–agost 2026) i 16 efectes pendents. La lògica de documents està poc exercitada a test;
  el volum real només es veurà a productiva
- 4 UDFs mappejats: `POS. BCN CONSULTING`, `SEGMENT US FARINA 1`, `SEGMENT US FARINA 2`, `SUBFAMILIA`

### 🔄 Pendent (per fases)

**Bloc A — Sistemes (infraestructura)**
- [x] ✅ **Worker desplegat a `AE02SAPRDP`** (192.168.11.136) el 25/09/2026, i **el cicle nocturn
      torna a córrer sol des del 29/09**: la tasca de les 02:45 hi era des del 16/09 però estava
      **desactivada** i no havia corregut mai. Sis nits seguides desateses del 30/09 al 05/10 (runs
      161-166, `SUCCESS` en ~11 s). Diagnòstic de la màquina amb `deploy\Check-WorkerHost.ps1`; els
      passos, a `deploy/README.md`
- [ ] **Netejar `AE01SAPRDP`**: desactivar-hi la tasca vella i esborrar l'`appsettings.Production.json`,
      que té credencials i ja no fa cap feina. **No es pot des de l'equip local**: `.239` denega WinRM
      i `schtasks` (05/10/2026), així que va per RDP o per Sistemes
- [ ] Rebre resposta sobre el compte SMTP per a Database Mail
- [ ] Passar-los la IP d'Analitza perquè obrin el firewall al port 1433, quan l'Adrià la doni

**Bloc A bis — Usuaris dedicats** *(feina meva, no de Sistemes)*
- [ ] Usuari tècnic de SAP de només lectura per a Service Layer (ara va amb `OHijazo`)
- [ ] Login `gapi07_worker` a SQL Server (ara va amb `sa`) — script a
      `sql/security/create_worker_user.sql`
- [ ] Rotar la contrasenya de `sa` i la d'`analitza_ro`

**Bloc B — Handoff Analitza** *(correu llest a `correu_adria.md`)*
- [ ] Rotar contrasenya de `analitza_ro` (ara és placeholder desconegut)
- [ ] Enviar correu a Adrià (contrasenya per canal segur separat)
- [ ] Esperar confirmació que la seva VPN arriba a `AE01SAPSQL`

**Bloc C — Pendent de resposta d'Adrià** *(resposta llesta a `resposta_adria_1.md`)*
- [ ] **Continuïtat d'IDs**: comercials i famílies **no** conserven els codis de KAIS; clients
      tampoc i no hi ha pont a SAP. Els productes sí. Detall a `docs\memoria_projecte.md` §6.4
- [ ] Confirmar que pot rebre el codi KAIS com a `id_salesman` (SAP el guarda a `U_FCCodiKais`)
- [ ] Confirmar que els seus codis de família són el prefix del nom del grup (`010001-BLAT...`)
- [x] Crear `U_FCCodiKais` a `OCRD` i `OITB` (26/08/2026). El `U_FCNewCardCode` que es va crear el
      mateix dia s'ha retirat: duplicava `U_SEICodienllac`, que ja portava la implantació
- [ ] Acordar què hi posem a `product_cost` (SAP no exposa l'equivalent de KAIS)
- [ ] Recollir el **llistat de filtres que aplicava KAIS** — ja se'n va oferir el 12/05/2025
- [ ] Aclarir si **RAÓ SOCIAL** i **ACTIU** els vol com a atributs (**ZONA** ja el produïm)
- [x] Implementar `new_code` (10/09/2026): surt de `etl.vw_client_successor`, que **inverteix**
      `OCRD.U_SEICodienllac` — aquell camp guarda el predecessor, no el successor

**Bloc D — Migració a Service Layer** → veure [§7](#7-migració-a-service-layer-estat)

**Bloc E — Cutover, 2 de novembre de 2026**
- [ ] **Data límit 1 de novembre**: UDFs amb els codis de KAIS creats i **poblats**. Si el dia 2
      s'envien els codis de SAP, Analitza els ingereix com a clients nous
- [ ] Validació d'estructura i mestres amb l'Adrià (les xifres no es podran comparar amb KAIS)
- [ ] Canviar `ServiceLayer:CompanyDb` a `DB_FARINERA_PROD` a la config del Worker
- [ ] Verificar primera execució productiva

---

## 4. Operativa diària (com fer coses)

Les comandes SQL van contra `AE01SAPSQL` (credencials a `P:\preparacioComandesVendaSAP\.env`).
Les del Worker, des de `P:\GAPI07_Analitza\src\SapB1AnalitzaSync.Worker`.

### Veure l'estat de l'última càrrega

```sql
USE IntercanviSAP;
SELECT TOP 5 run_id, started_at, finished_at, status, error_message
FROM audit.etl_runs ORDER BY run_id DESC;
```

Estats possibles:
- `SUCCESS` — tot OK, swap fet
- `SUCCESS_NOSWAP` — OK però es va cridar amb `@SkipSwap=1` (mode inspecció)
- `BLOCKED` — hi ha warnings CRITICAL, swap avortat, `dbo.*` es queda amb dades del dia anterior
- `FAILED` — error inesperat

Si els recomptes sorprenen, mira **primer** si el mirall és fresc:

```sql
SELECT entity, last_update_date, last_full_at, last_rows, updated_at
FROM   IntercanviSAP.sap_raw.sync_state ORDER BY entity;
```

### Veure detall dels passos

```sql
SELECT step_name, status, rows_in, rows_out, duration_ms, LEFT(error_message,200) AS err
FROM audit.etl_step_log
WHERE run_id = (SELECT MAX(run_id) FROM audit.etl_runs)
ORDER BY step_id;
```

### Veure warnings de qualitat

```sql
SELECT severity, check_name, details
FROM audit.data_quality_warnings
WHERE run_id = (SELECT MAX(run_id) FROM audit.etl_runs);
```

Els checks són 9: orfes de client/producte, agent orfe, format `country_code`, signes coherents,
fórmula `net_amount`, volum anòmal, **identificadors que desapareixen** (`vanished_ids`) i **terra
mínim de files a les taules de moviment** (`lines_empty` / `lines_collapsed` / `receivables_empty`).

### Forçar una càrrega manual ara

Són dos passos, i **en aquest ordre**: primer el mirall, després la transformació.

```powershell
$env:DOTNET_ENVIRONMENT='Development'
dotnet run --project P:\GAPI07_Analitza\src\SapB1AnalitzaSync.Worker -- --once
```

```sql
EXEC IntercanviSAP.etl.sp_run_all;
-- o en mode inspecció (deixa dades a staging, no fa swap):
EXEC IntercanviSAP.etl.sp_run_all @SkipSwap=1, @ForceFullLines=1;
```

### Provar Service Layer sense tocar res

```powershell
$env:DOTNET_ENVIRONMENT='Development'
dotnet run --project P:\GAPI07_Analitza\src\SapB1AnalitzaSync.Worker -- --probe
```

No escriu a cap BD: llegeix una mostra de SAP i la contrasta amb `baseline.est_*`.

### Recarregar l'històric de documents

```powershell
dotnet run --project P:\GAPI07_Analitza\src\SapB1AnalitzaSync.Worker -- --backfill --from 2020-01-01
```

### Sanity check complet

```
sqlcmd -S AE01SAPSQL -U sa -P <password> -i "P:\GAPI07_Analitza\sql\verify.sql"
```

### Re-desplegar tots els SP (canvi de lògica)

En aquesta màquina **no hi ha `sqlcmd`**, així que el camí real és el script de PowerShell:

```
$env:SQLPASS = '...'
P:\GAPI07_Analitza\deploy_via_powershell.ps1
```

`sql\deploy.sql` fa exactament el mateix per a qui sí que tingui `sqlcmd` o SSMS en mode SQLCMD.
**Les dues llistes de fitxers han de coincidir**; el 31/08/2026 havien divergit i la de PowerShell
—la que es fa servir— es deixava les vistes `etl_vw_kais_codes`, sense les quals cinc dels SP ni tan
sols es creen.

Tots dos són idempotents i es poden executar tantes vegades com calgui.

**Cap dels dos crida `sql\schema\01_create_database.sql`**, i és expressament: aquell script fa
`DROP TABLE` de les vuit `dbo.est_*`, o sigui que deixaria Analitza sense dades fins a la següent
càrrega correcta. És **creació inicial**, s'executa una sola vegada i a mà, i té una guarda que
avorta si les taules ja tenen files. Per posar al dia una BD ja desplegada hi ha
`sql\schema\04_migracions.sql`, que fa els mateixos canvis en forma d'`ALTER` guardat.

### Afegir un nou UDF com a atribut

Ara són **dos** llocs: el Worker l'ha de baixar de SAP, i el SP l'ha de projectar.

1. Afegeix el nom del UDF a `PartnerFields` o `ItemFields` a
   `src\SapB1AnalitzaSync.Shared\ServiceLayer\ODataQueryBuilder.cs`. Si no és al `$select`,
   Service Layer no el retorna.
2. Afegeix la columna a la taula corresponent de `sql\schema\02_create_sap_raw.sql`, al DTO de
   `src\SapB1AnalitzaSync.Shared\ServiceLayer\Dtos.cs` i al `DataTable` de
   `src\SapB1AnalitzaSync.Worker\Services\MirrorTables.cs`.
3. Projecta'l al SP que toqui (`etl_sp_load_client_attributes.sql` o
   `etl_sp_load_product_attributes.sql`).
4. Re-desplega el SQL i torna a compilar el Worker.

### Canviar a la BD productiva de SAP (cutover)

Ja **no** és un `UPDATE` a `cfg.settings`: la companyia de SAP la marca el Worker.

```powershell
# DEV — des de src\SapB1AnalitzaSync.Worker
dotnet user-secrets set "ServiceLayer:CompanyDb" "DB_FARINERA_PROD"
```

**PRD**: a `C:\Apps\SapB1AnalitzaSync\appsettings.Production.json` d'`AE02SAPRDP`, el fitxer del
costat de l'executable. **No** a una variable d'entorn: aquella màquina allotja webservices de
tercers que la podrien llegir, i a més les variables d'entorn guanyen sobre els JSON, així que
posar-la-hi deixaria l'`appsettings.Production.json` dient una cosa i el procés fent-ne una altra.
Detall a `deploy/README.md`, secció 3. El Worker tampoc corre sota SQL Agent: corre com a tasca
programada de les 02:45 amb `sapsistema`, i qui corre sota SQL Agent és `etl.sp_run_all`.

Després, verificar abans de deixar-ho córrer:

```sql
EXEC IntercanviSAP.etl.sp_run_all @SkipSwap=1, @ForceFullLines=1;
-- Si quadra:
EXEC IntercanviSAP.etl.sp_run_all @ForceFullLines=1;
```

---

## 5. Contactes

| Qui | Rol | Contacte |
|---|---|---|
| **Adrià Arnau** | CTO Analitza CM | adria@analitza.com — 680 73 43 72 |
| **Lluís Butinya** | Director Compres/Admin Agrienergia | lbutinya@agrienergia.com — 972 583 363 |
| **Sistemes Agrienergia** | Servidors, VM, xarxa, firewall, SMTP | (canal intern) |
| **Oscar Hijazo** | SAP (UDFs i configuració), `IntercanviSAP`, l'ETL i el Worker | ohijazo@agrienergia.com |

---

## 6. Documentació de referència

- **`docs\Guia de importación de datos Analitza CM v9.pdf`** — Requisits oficials d'Analitza (estructura de camps, formats, fórmules)
- **`docs\Integracio_GAPI07.pdf`** — Blueprint intern d'aquesta integració
- **`docs\Re_ Integració Analitza amb SAP_ Oscar Hijazo - Outlook.pdf`** — Fil de correus amb Adrià explicant com funciona el seu sistema
- **`CLAUDE.md`** i **`.claude\rules\`** — Regles del projecte: accés a SAP, gotchas de Service Layer, secrets, contracte amb Analitza
- **`P:\GAPI03_CRM`** — L'altra integració SAP. D'allà venen el client de Service Layer i els gotchas d'OData.
- **`handoff_analitza.docx`**, **`correu_adria.md`**, **`resposta_adria_1.md`**, **`draft_resposta_sistemes.md`**

---

## 7. Migració a Service Layer (estat)

**Per què:** l'accés directe a taules internes de SAP no està suportat per SAP, és fràgil davant
d'upgrades i FPs, exposa a risc de llicenciament indirecte, fa bypass dels permisos i de la lògica
de negoci, no deixa rastre a l'auditoria de SAP i no és portable a HANA ni a cloud. `GAPI03_CRM` va
decidir el mateix el 21/08/2026. El cutover a productiva és el moment on aquests riscos es
materialitzen, i és molt més barat migrar ara, en dev.

| Fase | Estat |
|---|---|
| 0 — Fotografia `baseline` i sonda `--probe` | ✅ Fetes el 24–25/08/2026 |
| 1 — Schema `sap_raw` | ✅ Desplegat (14 taules, buides) |
| 2 — Worker .NET 8 | ✅ `src\` — 0 warnings, 23 tests verds |
| 3 — SPs repuntats a `sap_raw` | ✅ Escrits; **no desplegats** fins que el mirall tingui dades |
| 4 — Validació `staging` vs `baseline` | ⏳ `sql/verify_migration.sql` |
| 5 — Tall i neteja | ⏳ Falta revocar el permís de lectura sobre `DB_FARIN_TEST` |

**Resultats de la sonda:**

- ✅ **`BPAddress.RowNum` és `CRD1.LineNum`** — 534/534 adreces ship-to (100%). Els
  `id_client_location` no canvien i no cal taula de mapatge. Era el risc més gros.
- ⚠️ **`DLN1.StockPrice` no té equivalent a Service Layer.** `GrossBuyPrice` coincideix el 92,3%
  però és un concepte diferent (preu de compra actual vs cost congelat a l'albarà). Cal preguntar
  a l'Adrià si fan servir `product_cost` abans de decidir.
- ⚠️ **`PriceBefDi` = `UnitPrice` o `Price`: no concloent.** Els dos donen 100% perquè cap línia
  de la mostra porta descompte. Si s'encerta al revés, el `net_amount` surt malament i cap check
  ho detecta.

Detall complet a **`docs\memoria_projecte.md`**.

**Pla de treball complet:**
`C:\Users\ohijazo.AGRIENERGIA\.claude\plans\revisa-com-est-aquest-precious-conway.md`
