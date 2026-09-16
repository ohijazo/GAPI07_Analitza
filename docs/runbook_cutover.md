# Runbook del cutover — 1 i 2 de novembre de 2026

> Document operatiu. Els **perquès** viuen a `docs/memoria_projecte.md` i a `.claude/rules/`;
> aquí només hi ha què s'ha de fer, en quin ordre, com es comprova i com es desfà.
>
> Última actualització: **16/09/2026**

## El que fa aquest dia diferent

El cutover és un **tall sec**: el 2 de novembre KAIS deixa de rebre dades i SAP comença. No hi
haurà cap període amb els dos ERPs vius, així que **una comparació KAIS contra SAP no serà possible
mai** — ni abans ni després. El que no es validi abans, no es validarà.

Hi ha cinc canvis que s'han de fer el mateix dia i que fins ara vivien escampats entre la memòria,
la Regla 04 i la nota interna de dos correus. Són aquests, i cap és opcional.

## Encara no es pot tancar aquest runbook

| Depèn de | Què falta |
|---|---|
| **Adrià (Analitza)** | Les respostes del correu enviat el **31/08/2026** (`resposta_adria_2.docx`). Sense la del `/100`, el pas 2.4 no es pot escriure |
| **Sistemes** | Worker desplegat a `AE01SAPRDP`. ~~Compte de servei~~ ✅ `AGRIENERGIA\sapsistema` i ~~carpeta~~ ✅ el **16/09/2026**. Queden: **accés d'`ohijazo` a la màquina** (RDP + NTFS), *Log on as a batch job* per a `sapsistema`, i registrar la tasca de les 02:45 (la fan ells). ~~Accés d'Analitza~~ ✅ **concedit el 10/09/2026** — ja tenen VPN i `AE01SAPSQL:1433`, i les credencials de VPN són les de sempre |
| **Llicències** | Usuari tècnic `GAPI07_RO`. Ara el pipeline va amb `OHijazo`, nominal |
| ~~Consultors de SAP~~ | ✅ **Resolt l'01/09/2026**: el blueprint signat (cap. 17.3) diu que **no es migra l'històric documental**. Veure sota |
| **Nosaltres** | **Passar la contrasenya d'`analitza_ro` a l'Adrià.** Ja no depèn de ningú: Sistemes els van habilitar l'accés el 10/09/2026. Compte, que ells creuen que "no ha canviat res" — la contrasenya sí que va canviar el 31/08 i els permisos es van acotar el mateix dia |

---

## Setmana del 27 al 31 d'octubre — preparació

Res d'això toca producció. És el que fa que el dia 2 no hi hagi sorpreses.

1. **Demanar a l'Adrià l'exportació de clients actualitzada.** La que tenim és del 27/08/2026 i no
   porta les altes fetes des de llavors. Cada client que se'ns escapi li arriba com a client nou.
   Deixar-la a `docs/client_locations.csv`, que és d'on la llegeix `Sync:KaisClientExportPath`.

2. **Repetir la comparació d'ids contra `DB_FARINERA_PROD`, no contra test.** Les xifres que tenim
   —5.621 de 5.684 conservats, 13 clients sense codi— estan mesurades contra `DB_FARINERA_TEST`, que
   és una còpia i va endarrerida. Part dels 13 poden existir a la productiva.

   ```powershell
   $env:DOTNET_ENVIRONMENT='Development'
   dotnet run --project P:\GAPI07_Analitza\src\SapB1AnalitzaSync.Worker -- --probe
   ```

3. **Poblar els `U_FCCodiKais` que faltin a `OCRD`.** Aquest és el punt amb data: un client existent
   que es quedi amb el camp buit cau al `CardCode` de SAP i **Analitza el veu com un client nou**, en
   silenci i el dia que menys es mira. La sonda llista els que queden buits; no es poden filtrar pels
   actius, perquè `sp_load_clients` emet tots els `cCustomer` i un client de baixa també hi arriba.

   `OITB.U_FCCodiKais` (famílies) **no cal poblar-lo**: l'Adrià accepta que els ids de família
   canviïn. Es queda creat i buit.

4. **Esborrar `OCRD.U_FCNewCardCode` de SAP i reiniciar el Service Layer.** El camp duplicava
   `U_SEICodienllac`, de la implantació, que ja portava l'enllaç entre un client i el que substitueix
   (veure `docs/memoria_projecte.md` §6.4b). Mai s'ha omplert, així que esborrar-lo no perd res.

   **L'ordre no és intercanviable:** primer el codi desplegat (ja fet el 10/09/2026 a test — el
   `$select` de `BusinessPartners` ja no el nomena), després l'esborrat a SAP, i tot seguit el
   reinici dels quatre serveis `b1s5000x` i el controlador amb PowerShell elevada. Si s'esborra amb
   el codi antic desplegat, la baixada diària de clients peta sencera: SL manté les metadades
   cacheades i la consulta arriba a SQL amb una columna que ja no existeix.

   A productiva això encara no s'ha fet.

5. **Passar la contrasenya d'`analitza_ro` a Analitza** per un canal a part, un cop Sistemes els
   hagi habilitat la VPN. Ja està rotada (31/08/2026) i apuntada al gestor. L'endpoint i les
   credencials de VPN els dona Sistemes, no nosaltres.

   El compte només veu `dbo.est_*` (tancat el mateix dia: abans era `db_datareader` de tota la BD i
   arribava al mirall `sap_raw`). Si algun dia cal afegir-hi una taula, va a
   `sql/security/create_analitza_user.sql`, no a un rol ampli. Si cal tornar-la a rotar, cal
   `-AdminUser sa`: és una operació de servidor i `ohijazo_sql` no hi arriba a propòsit.

---

## 1 de novembre — el dia abans

> **És l'1, no el 2.** Si el dia del tall s'envien codis de SAP en comptes dels de KAIS, Analitza els
> ingereix com a clients nous, i desfer-ho després surt molt més car que fer-ho bé d'entrada.

- [ ] Última passada de `--probe` contra productiva: **cap client sense `U_FCCodiKais`**.
- [ ] `dotnet build src\SapB1AnalitzaSync.sln -c Release` amb 0 warnings i els tests en verd.
- [ ] Confirmar per escrit amb l'Adrià **què fa ell el dia 2**: el `/100` i el `1 - discount`.
      Si no ha contestat, aquí és on s'atura i s'hi insisteix; és l'únic punt que produeix un error
      silenciós.
- [ ] Deixar apuntada la sortida de l'últim run bo, per tenir contra què comparar l'endemà.
- [ ] **Comprovar que `cfg.client_ship_no` està poblada** i que `ship_no_missing` no salta. És la
      taula que fixa la meitat dreta de `id_client_location`, i **no es pot regenerar**: si es perd,
      tots els números es recalculen i Analitza veu desaparèixer ubicacions i néixer-ne de noves amb
      l'històric d'una altra. Ha d'entrar al backup.

---

## 2 de novembre — el tall

L'ordre importa. Els passos 2.1 a 2.4 es fan **abans** de la primera execució amb dades de
productiva, no després.

### 2.1 Apuntar el Worker a la companyia productiva

A `appsettings.Production.json` del servidor, al costat de l'executable —no a variables d'entorn de
màquina, perquè `AE01SAPRDP` allotja webservices de tercers que les llegirien:

```
ServiceLayer:CompanyDb  ->  DB_FARINERA_PROD
```

**No** és un `UPDATE` a `cfg.settings`. `SBO_DB` es va esborrar de la base de dades el 26/08/2026
precisament perquè ningú el canviés pensant que era l'interruptor.

### 2.2 Apujar `ID_DROP_MAX`

```sql
UPDATE IntercanviSAP.cfg.settings SET [value] = '999999' WHERE [key] = 'ID_DROP_MAX';   -- avui: 10
```

El check `vanished_ids` compara els identificadors d'ahir amb els d'avui i bloqueja el swap a partir
d'aquest llindar. El dia del tall canvien en massa i **és correcte que salti**: per això s'apuja
expressament, no perquè el check molesti.

### 2.3 Abaixar `LINES_MIN_RATIO`

```sql
UPDATE IntercanviSAP.cfg.settings SET [value] = '0.00' WHERE [key] = 'LINES_MIN_RATIO';  -- avui: 0.95
```

La SAP productiva arrenca **sense albarans anteriors al tall**, així que `est_linies_albara` cau a
gairebé zero i `lines_collapsed` bloquejaria el swap. **Aquest pas és obligatori, no una precaució**:
confirmat l'01/09/2026 contra el blueprint signat, capítol 17.3, *«No se migrará el histórico
documental»*.

El que sí que es migra: mestres, **stock inicial** valorat i amb lots, i les **factures pendents de
cobrament** com a factures de servei sense efecte fiscal, amb el número, la data, l'import i el
venciment originals de KAIS. Aquelles són `OINV` obertes i entraran a `est_cobraments` amb data
anterior al tall, que és el que evita que el deute dels clients sembli haver desaparegut el dia 2.

Dos fets operatius que se'n deriven i que val la pena tenir presents:

- **Els albarans pendents de facturar es puntegen i es facturen tots a KAIS abans del tall**, perquè
  l'stock quedi quadrat a l'entorn antic. O sigui que no arriben albarans a mig facturar a SAP.
- **KAIS es manté viu com a plataforma de consulta.** És el que fa possible la càrrega puntual del
  desembre per corregir el cost d'octubre: la base de dades antiga hi serà.

### 2.4 El `discount` i el `/100` — el canvi coordinat

**Aquests dos només es toquen si l'Adrià els fa el mateix dia al seu costat.** Si no ha contestat,
no es toca res: la convenció actual funciona i es pot canviar més endavant amb calma.

```sql
-- Nomes si Analitza treu el seu "1 - discount" avui
UPDATE IntercanviSAP.cfg.settings SET [value] = '1' WHERE [key] = 'DISCOUNT_AS_PERCENT';
```

El llegeixen `sp_load_invoice_lines` i el check `formula_break`, i tots dos veuen el mateix valor: no
cal editar cap SP. Si ell no treu el seu `1 - discount`, els imports li surten a zero — fallada
sorollosa, que és exactament el que volem.

Hi ha un segon setting, `DISCOUNT_AS_PERCENT_PUBLISHED`, que **no s'ha de tocar a mà**: l'escriu el
swap i diu amb quina convenció va quedar `dbo`. Mentre no coincideixi amb l'altre,
`sp_load_invoice_lines` força un FULL en comptes de copiar de `dbo` línies de la convenció d'ahir. És
el que evita que el dia del canvi la taula surti mig en multiplicador i mig en percentatge, que és
una barreja que **cap check detectaria**. Al log del pas hi surt com a
`mode=FULL (forcat: canvi de convencio del discount)`.

Provat el 31/08/2026 als quatre casos: flag a 0 i a 1 donen el mateix `net_amount`, `product_price` i
`quantity` i només canvia el `discount`; `formula_break` calla en tots dos; l'incremental el dia del
canvi es converteix en FULL tot sol; i l'incremental en règim estable no dona la volta dues vegades.

El `/100` és la meitat que **no** està al nostre costat: KAIS li guardava els preus en cèntims i les
seves SQL fan `product_price/100` i `product_cost/100` sense dividir `net_amount`. Nosaltres emetem
euros. Si ell no treu el `/100`, els preus li queden 100× petits, el `net_amount` queda bé i **cap
validació ho detecta**. Si prefereix que els hi enviem multiplicats per 100, això sí que és feina
nostra i s'ha de fer abans, no aquell dia.

Un cop fets 2.1–2.4, actualitzar `.claude/rules/04-contracte-analitza.md` i
`docs/memoria_projecte.md`, que documenten la convenció del multiplicador com si fos l'única.

### 2.5 Executar i mirar-s'ho

```powershell
$env:DOTNET_ENVIRONMENT='Development'
dotnet run --project P:\GAPI07_Analitza\src\SapB1AnalitzaSync.Worker -- --once
```
```sql
-- Primer en mode inspeccio: deixa les dades a staging i NO fa swap
EXEC IntercanviSAP.etl.sp_run_all @SkipSwap=1, @ForceFullLines=1;
```

Abans de publicar res:

```sql
SELECT TOP 5 run_id, started_at, finished_at, status, error_message
FROM IntercanviSAP.audit.etl_runs ORDER BY run_id DESC;

SELECT severity, check_name, details FROM IntercanviSAP.audit.data_quality_warnings
WHERE run_id = (SELECT MAX(run_id) FROM IntercanviSAP.audit.etl_runs);

-- El mirall es fresc? Mirar aixo PRIMER si algun recompte sorpren
SELECT entity, last_update_date, last_full_at, last_rows, updated_at
FROM IntercanviSAP.sap_raw.sync_state ORDER BY entity;

-- Els ids son de KAIS i no CardCodes de SAP?
SELECT TOP 20 id_client_location FROM IntercanviSAP.staging.est_clients ORDER BY id_client_location;
```

El que ha de sortir: `id_client_location` de 8 dígits (`00251182-000`) per als clients que venien de
KAIS, i `C` + 6 només per als donats d'alta a SAP després del tall. Si en surten molts amb `C`, el
`U_FCCodiKais` no s'ha poblat i **cal aturar-se aquí**, no publicar.

Quan quadri:

```sql
EXEC IntercanviSAP.etl.sp_run_all;   -- de debo, amb swap
```

---

## 3 de novembre — el pas que s'oblida

```sql
UPDATE IntercanviSAP.cfg.settings SET [value] = '10' WHERE [key] = 'ID_DROP_MAX';
```

`ID_DROP_MAX` es torna a baixar l'endemà. El llindar existeix precisament per als canvis que no
s'entenen; deixar-lo obert vol dir quedar-se sense l'alarma per sempre.

`LINES_MIN_RATIO` es torna a pujar a `0.95` quan `est_linies_albara` hagi tornat a créixer prou —
uns dies més tard, no l'endemà, perquè les línies s'acumulen a poc a poc a partir de zero.

---

## Els primers dies

- Revisar amb l'Adrià que les xifres siguin coherents. **No es podran comparar amb KAIS**: es
  comparen contra el negoci.
- `est_linies_albara` arrencarà gairebé buida i anirà creixent. És l'esperat.
- Vigilar `vanished_ids` cada matí: és el check que cobreix la família de fallades que cap altre veu.

---

## Si alguna cosa va malament

**El disseny ja protegeix el cas normal.** L'ETL treballa sempre a `staging.*`, valida, i només fa
`TRUNCATE + INSERT` a `dbo.*` dins d'una sola transacció si no hi ha cap warning `CRITICAL`. Si les
validacions fallen, el run marca `BLOCKED` i **`dbo.est_*` es queda amb les dades del dia anterior**.
Analitza no veu mai dades a mig carregar.

| Símptoma | Què vol dir | Què fer |
|---|---|---|
| `ABORTED_STALE_MIRROR` | `sap_raw` té més de `MIRROR_MAX_AGE_HOURS` (6). El Worker no ha corregut | Executar el Worker a mà i repetir. **No** apujar el llindar |
| `BLOCKED` | Hi ha warnings `CRITICAL`; `dbo.*` intacte | Mirar `data_quality_warnings` i entendre'ls **abans** de tocar cap llindar |
| Els preus surten 100× petits | El `/100` no s'ha resolt | Cap validació ho detecta: es veu comparant una línia contra SAP a mà |
| Els imports surten a zero | `DISCOUNT_AS_PERCENT='1'` i Analitza no ha tret el seu `1 - discount` | Tornar el setting a `'0'` i re-executar. És reversible |
| Molts ids amb `C` + 6 | `U_FCCodiKais` mal poblat | **Aturar-se i no publicar.** Un cop ingerit, desfer-ho és molt més car |

**El rollback real és no publicar.** Un cop Analitza ha ingerit codis nous, ja no hi ha marxa enrere
per la nostra banda: per a ells són clients nous amb l'històric buit. Per això el pas 2.5 es fa amb
`@SkipSwap=1` primer.

---

## Contactes

| Qui | Rol | Contacte |
|---|---|---|
| Adrià Arnau | CTO Analitza CM | adria@analitza.com — 680 73 43 72 |
| Lluís Butinya | Director Compres/Admin | lbutinya@agrienergia.com — 972 583 363 |
| Sistemes | Servidors, xarxa, firewall | canal intern |
