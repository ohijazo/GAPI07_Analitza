# Discrepàncies entre KAIS.Intercanvi (actual) i IntercanviSAP (nou)

**Data anàlisi:** 2026-07-31
**Origen dades:** consulta directa a `vkais\kais\Intercanvi` (5.666 clients, 570.383 línies, 5+ anys d'històric) vs `AE01SAPSQL\IntercanviSAP` (10.342 client_locations, 59 línies, test)

## Resum executiu

Els noms de les taules (`est_*`) coincideixen, però **l'estructura interna té 7 discrepàncies estructurals** que trencaran les consultes SQL d'Analitza. Cal resoldre-les **abans** d'enviar el correu a Adrià, o rebrem un rebuig.

## Comparativa detallada

### 1. ⚠️ **CRÍTIC** — Format de `id_client_location`

| KAIS | IntercanviSAP |
|---|---|
| `varchar(13)` — `"00201021-000  "` (codi 8 + `-` + adreça 3) | `nvarchar(60)` — `"C201115-000-NUTREX PINSOS SL-BANYOLES"` |

**Impacte:** Qualsevol JOIN d'Analitza entre `est_clients` i `est_linies_albara` es trencarà (no coincidiran els identificadors). Ha estat una decisió del disseny nou per fer-lo "més llegible", però no és compatible.

### 2. ⚠️ **CRÍTIC** — `est_atributs_client` esquema WIDE vs LONG

| KAIS (WIDE — 1 fila per client) | IntercanviSAP (LONG — 1 fila per atribut) |
|---|---|
| 8 columnes: `client_locations_id, zone_id, zone_description, payment_method, payment_description, positioning_bcn_consulting, segmentation_use_1, segmentation_use_2` | 3 columnes: `client_locations_id, name, value` |
| 5.666 files (una per client) | 3.253 files (N per client segons atributs) |

**Impacte:** Les consultes d'Analitza que llegeixin `zone_id`, `payment_description`, etc. com a columnes fixes trencaran. Amb el format LONG han de fer `WHERE name='ZONE_ID'` — molt diferent.

### 3. ⚠️ **CRÍTIC** — `est_atributs_producte` esquema WIDE vs LONG

| KAIS (WIDE) | IntercanviSAP (LONG) |
|---|---|
| 3 columnes: `art_codi, subfamily_description, units_description` | 3 columnes: `products_id, name, value` |
| Té `units_description` (`"GRA"`, `"SAC 25"`, etc.) | No tenim `units_description` — ni tan sols com a atribut |

### 4. ⚠️ **CRÍTIC** — `est_linies_albara.id_invoice_line` i `invoices_id`

| KAIS | IntercanviSAP |
|---|---|
| `id_invoice_line = int` (`570209`) | `id_invoice_line = nvarchar` (`"DLN-1-0"`) |
| `invoices_id = varchar` (`"2018370000005"` — any+sèrie+num) | `invoices_id = nvarchar` (`"DLN-26700001"` — prefix+num) |

**Impacte:** Prefixos DLN-/RDN-/RIN- afegits a IntercanviSAP no existeixen a KAIS. Trenca casts a int i qualsevol lògica que parsi la data des de `invoices_id`.

### 5. ⚠️ **CRÍTIC** — Nom de taula: `est_cobraments` vs `est_clients_efectes_pendents`

| KAIS | IntercanviSAP |
|---|---|
| Taula: `est_cobraments` (201.061 files) | Taula: `est_clients_efectes_pendents` (9 files) |
| PK: `uniqueidentifier` | PK: `nvarchar` (`"INV-XXXXX"`) |

**Impacte:** Analitza fa `SELECT ... FROM est_cobraments` — trencarà. La nostra és `est_clients_efectes_pendents` (el que diu la guia oficial, però NO el que fa servir Analitza avui).

### 6. ⚠️ **IMPORTANT** — Tipus de `salesmen_id`

| KAIS | IntercanviSAP |
|---|---|
| `varchar` (`"006"`, `"100"`) | `int` (`6`, `100`) |

**Impacte:** JOINs textuals fallaran per tipus incompatible.

### 7. Nota — `est_clients` té camps extra a IntercanviSAP

IntercanviSAP té: `holidays_start_date`, `holidays_end_date`, `comments`, `payment_method` que KAIS no té. Això no trenca res (columnes addicionals), però `payment_method` a KAIS es porta com a columna dins `est_atributs_client`, no dins `est_clients`.

## Els "3 UDFs pendents" — RESOLTS

Analitzant les dades reals de KAIS, veiem que **no són atributs LONG** com havíem assumit:

- **RAÓ SOCIAL** ✅ → no existeix com a atribut. És `est_clients.name` (el mateix camp). Ja el tenim.
- **ZONA** ✅ → és `est_atributs_client.zone_id` + `zone_description` (dues columnes WIDE de KAIS). **Resolt 2026-07-31**: mapejat des de `CRD1.U_SEIZONAC` (UDF "Zona Comercial" a nivell d'adreça) via nova taula `cfg.zone_code_mapping` (47 zones) + `sp_load_client_attributes`. Cobertura 79% dels ship-tos; NULL → "SENSE ZONA" (codi 0000). Codis 0001–0046 assignats alfabèticament; poden substituir-se pels codis KAIS antics si Adrià els envia.
- **ACTIU** ✅ → no existeix com a atribut. És `est_clients.active` (int 0/1). Ja el tenim.

I trobem 2 atributs de KAIS que NO tenim a IntercanviSAP:
- **`payment_method` + `payment_description`** — a SAP ho podem treure de `OCRD.GroupNum` → `OPYM`. Els tenim al camp `payment_method` d'`est_clients` (que KAIS no té allà!). Cal moure'l a l'estructura d'atributs.
- **`units_description`** a productes — a SAP és `OITM.SalUnitMsr` o similar.

## Comptatge real KAIS (per dimensionar cutover)

| Taula | Files a KAIS | Files a IntercanviSAP test |
|---|---:|---:|
| `est_agents` | 48 | 49 |
| `est_families_productes` | 2.051 | 110 (moltes menys!) |
| `est_clients` | 5.666 | 10.342 (2× per multi-adreça) |
| `est_productes` | 2.051 | 2.028 |
| `est_linies_albara` | **570.383** | 59 (test buit) |
| `est_atributs_client` | 5.666 | 3.253 |
| `est_atributs_producte` | 2.051 | 252 |
| `est_cobraments` | 201.061 | 9 |

**Nota `est_families_productes`**: KAIS té 2.051 (una per producte!), IntercanviSAP té 110 (grups reals de SAP `OITB`). Sembla que KAIS **duplica producte→familia 1:1** en comptes de fer una taula normalitzada. Podria ser una convenció d'Analitza. Verificar.

## Opcions de resolució

### Opció A — Refactor de l'ETL per replicar EXACTAMENT l'esquema KAIS
- **Esforç:** 2-3 dies feina (canvis a SPs, tests, re-validació)
- **Pros:** compatibilitat total. Analitza no toca res.
- **Contres:** perdem la millora del format LONG (que és el que la guia oficial d'Analitza recomana).

### Opció B — Vistes de compatibilitat a IntercanviSAP
- Mantenim les taules `dbo.est_*` amb format nou (LONG, id llegibles, prefixos)
- Creem vistes `dbo.v_kais_est_*` que emulin l'esquema WIDE de KAIS
- Analitza consulta les vistes (mateixos noms que abans si les creem com `est_*` a un altre schema)
- **Esforç:** 1 dia feina
- **Pros:** flexibilitat, doble format disponible
- **Contres:** cal mantenir dues abstraccions; algunes conversions (com id format) potser costen

### Opció C — Passar-ho tal com està + Analitza adapta
- Enviem tal qual + advertim de canvis
- Adrià valora si accepta refer les seves SQL
- **Esforç:** 0 (nostre) + N (Analitza)
- **Contres:** possiblement rebutjaran; retard.

## Recomanació

**Opció A** — Adaptar completament l'esquema de sortida al format actual de KAIS. Motius:

1. El compromís del handoff era "mateixos noms i estructura" — la realitat actual no ho compleix.
2. Analitza és el client, i la seva estabilitat operacional té més valor que la puresa del disseny.
3. La millora del format LONG (guia oficial) és irrellevant si trenca l'integració.
4. És un refactor contingut: només afecta els SPs de càrrega, no la infraestructura (staging→swap, QA, job, seguretat continuen).

Si es fa Opció A, cal:

- Canviar `id_client_location` a format `"CardCode-ShipToCode"` sense el nom (8+3+padding igual que KAIS)
- Canviar `salesmen_id` a `varchar(3)`
- Refer `est_atributs_client` a WIDE amb 8 columnes fixes
- Refer `est_atributs_producte` a WIDE amb `art_codi, subfamily_description, units_description`
- Treure prefixos DLN-/RDN-/RIN- de `id_invoice_line` (i canviar a int amb hash o compound key) i `invoices_id` (format any+sèrie+num)
- Renombrar `est_clients_efectes_pendents` → `est_cobraments`, canviar PK a `uniqueidentifier`
- Verificar amb Adrià si `est_families_productes` ha de ser 1:1 producte↔familia

## Impacte al pla actual

- **NO enviar** el correu `correu_adria.md` fins resoldre això.
- **NO rotar** encara la password `analitza_ro` (esperem).
- El deploy actual segueix funcionant (job diari corrent) — no cal aturar-lo. Servirà com a base per validar la nova versió.
- Actualitzar `README.md` i pla amb aquest bloqueig.

## Fitxers a modificar (opció A)

Prioritzats per impacte:

1. `sql/procs/etl_sp_load_clients.sql` — id format, treure holidays/comments extra, moure payment_method a atributs
2. `sql/procs/etl_sp_load_client_attributes.sql` — refer complet en WIDE
3. `sql/procs/etl_sp_load_invoice_lines.sql` — id_invoice_line + invoices_id sense prefixos
4. `sql/procs/etl_sp_load_product_attributes.sql` — refer complet en WIDE amb units
5. `sql/procs/etl_sp_load_salesmen.sql` — salesmen_id varchar
6. `sql/procs/etl_sp_load_receivables.sql` + renaming taula → `est_cobraments`
7. `sql/schema/01_create_database.sql` — actualitzar tots els CREATE TABLE
8. `sql/procs/etl_sp_data_quality_checks.sql` — adaptar checks als nous formats
