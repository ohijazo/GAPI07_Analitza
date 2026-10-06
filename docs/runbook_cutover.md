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
| ⚠️ **Adrià (Analitza)** — el `product_cost` | **El forat gros que queda, ara que el `/100` està tancat.** Emetem **0 a propòsit** (`Sync:CostField = "none"`) perquè Service Layer no exposa res equivalent a `DLN1.StockPrice`, i el 05/10/2026 està mesurat: **231 de 231 línies a zero**. El seu correu del mateix dia demostra que **segueix consumint la columna** (`product_cost/100` és un dels canvis que farà), així que el dia 2 veuria **marges a zero** sense que res ho delati. Preguntat a `resposta_adria_5` amb tres sortides: acceptar `GrossBuyPrice` sabent què és, acordar una altra definició, o confirmar que ja no el fan servir. **Qualsevol de les tres val; arribar al dia 2 sense resposta, no** |
| ~~**Adrià (Analitza)** — el `/100`~~ | ✅ **Tancat el 05/10/2026, per escrit i amb el codi al davant.** Enumera els canvis que ja té provats per al dia del tall i els dos primers són `product_price/100 -> product_price` i `product_cost/100 -> product_cost`. **Nosaltres no hem de fer res**: els preus van en euros tal com surten. Del mateix correu: carrega només `date >= '2026-11-02'`, i **del `discount` no diu res**, o sigui que manté el seu `1 - discount` |
| ~~**Nosaltres — handoff**~~ | ✅ **Tancat el 16/09/2026**: contrasenya d'`analitza_ro` passada per un canal a part. Analitza té ruta, credencial i dades |
| **Nosaltres — abans del tall** | Activar `cfg.settings.FAMILY_FROM_COMMERCIAL` a `'1'` (les 12 famílies en comptes dels 110 grups). Codi desplegat i validat el 16/09/2026; el flag és a `'0'`. **Fa desaparèixer 110 identificadors alhora**, així que vol `ID_DROP_MAX` apujat aquell dia i baixat l'endemà. I omplir la família dels **vuit articles** de `docs/memoria_projecte.md` |
| **Sistemes** | ✅ **El cicle nocturn torna a córrer sol des del 29/09/2026** a `AE02SAPRDP` (192.168.11.136): la tasca hi era des del 16/09 però **estava desactivada**. Sis nits seguides desateses del 30/09 al 05/10 (runs 161-166, tots `SUCCESS` en ~11 s). Carpeta, ACL, sortida cap a `192.168.11.238:50000` i `:1433` i el dret *Log on as a batch job* ja hi eren. ~~`AE01SAPRDP`~~ ✅ **No cal netejar-la: la màquina desapareix i tot passa a `AE02SAPRDP`** (05/10/2026). La tasca vella hi segueix fallant cada nit —l'`appsettings.Production.json` d'allà diu `DB_FARINERA_TEST`, que està OFFLINE—, i això no pot espatllar el mirall: no arriba a escriure res. ⚠️ **L'únic que queda és la credencial**: aquell fitxer porta la contrasenya d'`OHijazo`, que **és la mateixa que la de `proceso`** i per tant encara és viva. Que el disc no acabi en una còpia de la VM, o rotar-la. ~~Accés d'Analitza~~ ✅ **10/09/2026** |
| ~~**Llicències** — usuari del pipeline~~ | ✅ **Resolt el 05/10/2026 sense comprar cap llicència**: el pipeline va amb **`proceso`**, el compte compartit que el partner va crear per a processos no concurrents. `GAPI07_RO` ja no cal. Canviat als user-secrets i a `appsettings.Production.json` d'`AE02SAPRDP`, i verificat pel camí real (login `usuari=proceso` i mirall segellat). ✅ **I el 06/10/2026 en Carles confirma que ningú més el fa servir**: GAPI01 no va per Service Layer i GAPI09 encara no s'ha desenvolupat. El compte és de GAPI07 de fet. ⏳ Es reobre el dia que es faci GAPI09: llavors ha de fer `Logout` i no treballar dins de la finestra de les 02:45, o necessita compte propi |
| ~~Consultors de SAP~~ | ✅ **Resolt l'01/09/2026**: el blueprint signat (cap. 17.3) diu que **no es migra l'històric documental**. Veure sota |
| **Nosaltres** | **Passar la contrasenya d'`analitza_ro` a l'Adrià.** Ja no depèn de ningú: Sistemes els van habilitar l'accés el 10/09/2026. Compte, que ells creuen que "no ha canviat res" — la contrasenya sí que va canviar el 31/08 i els permisos es van acotar el mateix dia |

---

## ~~Pas solt — activar les 12 famílies~~ ✅ FET el 17/09/2026

**Run 139, `SUCCESS`.** Es va fer alhora que la publicació de la continuïtat d'identificadors, perquè
les dues necessitaven el mateix llindar obert. Resultat a `dbo`: **5.650 dels 5.651 clients amb el
codi de KAIS conservat**, 14 famílies, 124 línies amb la fórmula quadrant a totes, i les guardes
tornades al seu lloc a la mateixa sessió.

⚠️ **Va costar dos runs fallits i val la pena saber per què.** El run 136 (la primera execució
automàtica, la nit del 16 al 17) va acabar `FAILED` amb dos `CRITICAL`:

- **`vanished_ids`, 5.655 identificadors.** No era un error: `dbo` portava CardCodes des del 24/08 i
  `staging` portava codis de KAIS des que es va implementar el `COALESCE` el 28/08. Aquell canvi havia
  de creuar aquesta porta algun dia.
- **`lines_orphan_client`, 50 línies.** Aquest sí que era un problema real: en mode INCREMENTAL,
  `sp_load_invoice_lines` **copia de `dbo`** les línies dels documents que no es refresquen, i
  aquelles portaven els codis de client vells. La taula quedava amb dues convencions barrejades.

**Tocar la fórmula dels identificadors obliga a `@ForceFullLines=1`.** És el mateix parany que el
`discount`, però allà el codi ho detecta sol amb `DISCOUNT_AS_PERCENT_PUBLISHED` i aquí no hi ha res
equivalent: qui ho va caçar va ser `lines_orphan_client`, que per això existeix.

**Queda pendent, i és cosmètic:** a SAP hi ha un article de baixa amb la família `KM 0` amb un espai,
duplicant `KM0`. Surt com una catorzena família amb un sol producte. Corregir-ho a SAP les deixa en 13.

<details>
<summary>El procediment que es va seguir, per si cal repetir-lo</summary>

No és del dia del tall: es pot fer qualsevol dia **de dia i mirant-ho**.

**0. Abans de res, que el run de la nit fos verd.** Si no ho era, això s'atura aquí.

```sql
SELECT TOP 3 run_id, started_at, finished_at, status, error_message
FROM   IntercanviSAP.audit.etl_runs ORDER BY run_id DESC;

SELECT check_name, severity, details
FROM   IntercanviSAP.audit.data_quality_warnings
WHERE  run_id = (SELECT MAX(run_id) FROM IntercanviSAP.audit.etl_runs);
```

**1. Opcional, però val la pena: arreglar `KM 0` a SAP.** Hi ha un article —de baixa— amb la família
`KM 0` amb un espai, duplicant `KM0`. Corregit, les famílies queden en 13 en comptes de 14.

**2. Apujar el llindar i activar el flag.** Les 110 famílies velles desapareixen de cop i
`vanished_ids` ho ha de veure: per això s'apuja expressament, no perquè el check molesti.

```sql
UPDATE IntercanviSAP.cfg.settings SET [value] = '999999' WHERE [key] = 'ID_DROP_MAX';  -- avui: 10
UPDATE IntercanviSAP.cfg.settings SET [value] = '1' WHERE [key] = 'FAMILY_FROM_COMMERCIAL';
```

**3. Executar en mode inspecció primer**, sense publicar res:

```sql
EXEC IntercanviSAP.etl.sp_run_all @SkipSwap=1;
```

I mirar `staging` abans de deixar-ho passar a `dbo`:

```sql
SELECT id_product_category, [name] FROM IntercanviSAP.staging.est_families_productes
ORDER BY id_product_category;

SELECT COUNT(*) AS productes,
       SUM(CASE WHEN product_categories_id = '' THEN 1 ELSE 0 END) AS sense_familia
FROM   IntercanviSAP.staging.est_productes;

SELECT (SELECT COUNT(*) FROM IntercanviSAP.staging.est_linies_albara) AS linies_staging,
       (SELECT COUNT(*) FROM IntercanviSAP.dbo.est_linies_albara)     AS linies_dbo;
```

El que ha de sortir: **13-14 famílies** amb noms reconeixibles, uns 1.776 productes sense família
—recanvis i consumibles, és correcte—, i les **línies d'albarà iguals a les de `dbo`**: aquest canvi
no les ha de tocar. Si les línies es mouen, aturar-se.

**4. Publicar**, si el pas 3 quadra:

```sql
EXEC IntercanviSAP.etl.sp_run_all;
```

**5. ⚠️ Tornar a baixar `ID_DROP_MAX` de seguida, la mateixa sessió.**

```sql
UPDATE IntercanviSAP.cfg.settings SET [value] = '10' WHERE [key] = 'ID_DROP_MAX';
```

Es pot fer immediatament: un cop `dbo` porta les famílies noves, la nit següent `staging` i `dbo`
coincideixen i el check ja no salta. **No deixar-ho per demà** — mentre el llindar estigui alt, la
protecció contra un canvi massiu d'identificadors està desactivada per a tot, no només per a això.

**6. Avisar l'Adrià** que el canvi ja és a la base de dades, perquè els ids de família que veurà són
nous. Ho té acceptat i el correu del 16/09 l'hi anuncia, però la data li serveix.

</details>

---

## Setmana del 27 al 31 d'octubre — preparació

Res d'això toca producció. És el que fa que el dia 2 no hi hagi sorpreses.

1. **Demanar a l'Adrià l'exportació de clients actualitzada.** La que tenim és del 27/08/2026 i no
   porta les altes fetes des de llavors. Cada client que se'ns escapi li arriba com a client nou.
   Deixar-la a `docs/client_locations.csv`, que és d'on la llegeix `Sync:KaisClientExportPath`.

2. **Repetir la comparació d'ids contra `DB_FARINERA_PROD`, no contra test.** Les xifres que tenim
   —5.621 de 5.684 conservats, 13 clients sense codi— estan mesurades contra la companyia de test
   (`DB_FARINERA_TEST` aleshores, `DB_FARIN_TEST` des del 22/09/2026: és una restauració de la
   mateixa), que és una còpia i va endarrerida. Part dels 13 poden existir a la productiva.

   ```powershell
   $env:DOTNET_ENVIRONMENT='Development'
   dotnet run --project P:\GAPI07_Analitza\src\SapB1AnalitzaSync.Worker -- --probe
   ```

2b. **Comprovar `01761 ESPECIFICA TURRIS` a la productiva.** A `DB_FARIN_TEST` és una closca buida
   —sense nom ni unitat de venda, al grup dels articles de prova— mentre que a KAIS està complet i ha
   facturat 62.675 € en dotze mesos. Si a `DB_FARINERA_PROD` també li falta el nom, el problema no és
   la família: és l'article. I si està bé, posar-li la família que hagi dit comercial.

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

4b. **Comprovar si a la productiva hi ha documents de 100 línies o més.** `id_invoice_line` és
   `offset + DocEntry*100 + LineNum`, o sigui que **només hi caben dos dígits de `LineNum`**: un
   document amb 100 línies col·lisiona amb el `DocEntry` següent i la càrrega peta amb violació de
   PK (`PK_staging_est_linies_albara`). És la fallada bona —sorollosa—, però aquella nit Analitza es
   queda amb les dades d'ahir, i la fórmula és **contracte**: no es pot canviar sola, s'ha de parlar
   amb l'Adrià. A `DB_FARIN_TEST` no es pot mesurar (màxim **7 línies** per albarà, 47 documents de
   joguina), i la productiva arrenca sense històric documental (blueprint 17.3), així que el risc
   real són els documents que es facin **a partir del dia 2**.

   ```sql
   SELECT TOP 5 DocEntry, COUNT(*) AS linies, MAX(LineNum) AS max_linenum
   FROM   sap_raw.DLN1 GROUP BY DocEntry HAVING COUNT(*) >= 90 ORDER BY COUNT(*) DESC;
   ```

   Si surt alguna cosa, repetir-ho amb `RDN1` i `RIN1`. Mirat el 05/10/2026 a test: 7, 3 i 4.

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
- [ ] **Comprovar que `ship_no_prefix_mismatch` val exactament `cfg.settings.SHIP_NO_PREFIX_BASELINE`**
      (a 29/09/2026: `4`). Si és més alt, algú ha tocat `cfg.client_ship_no` o l'ha restaurada d'un
      backup anterior al 29/09 — i llavors 804 ubicacions tornen a apuntar a l'adreça equivocada
      sense que `ship_no_missing` ni `vanished_ids` ho diguin. Veure `docs/memoria_projecte.md` §6.5b.
- [ ] **Tornar a demanar l'exportació de `client_locations` a l'Adrià** i carregar-la amb
      `tools\Import-AnalitzaClientExport.ps1`. És l'única referència vàlida per comprovar els
      identificadors: `baseline` compara SAP amb SAP i ja ha donat un fals 100% tres vegades. La
      comprovació és `sql\verify_ship_no.sql`, i l'ha de fer **contra la productiva**.

---

## 2 de novembre — el tall

L'ordre importa. Els passos 2.1 a 2.4 es fan **abans** de la primera execució amb dades de
productiva, no després.

### 2.1 Apuntar el Worker a la companyia productiva

A `appsettings.Production.json` del servidor, al costat de l'executable —no a variables d'entorn de
màquina, perquè `AE02SAPRDP` allotja webservices de tercers que les llegirien:

```
ServiceLayer:CompanyDb  ->  DB_FARINERA_PROD
```

⚠️ **`DB_FARINERA_PROD` és un nom que aquest runbook dona per fet, i no està confirmat.** El
22/09/2026, a `AE01SAPSQL` hi havia `DB_FARIN_TEST` (test), `SBO-COMMON`, `DB_FARINERA_TEST`
(OFFLINE) i **`DB_FARINERA`** — cap `DB_FARINERA_PROD`. Si la companyia productiva és `DB_FARINERA`,
posar-hi el nom d'aquest quadre fa que el Worker peti amb `Invalid login credential`, un missatge
que apunta a la contrasenya i no al nom. **Confirmar-ho amb els consultors abans del tall**, i
comprovar-ho amb `--probe` des d'`AE02SAPRDP`, que hi entra i no fa cap escriptura.

**No** és un `UPDATE` a `cfg.settings`. `SBO_DB` es va esborrar de la base de dades el 26/08/2026
precisament perquè ningú el canviés pensant que era l'interruptor.

### 2.1b-bis El número d'adreça de les altes noves es resol sol

`cfg.client_ship_no` és **la mateixa taula per a test i per a productiva**: canviar `CompanyDb` no la
toca, i no s'ha de buidar (veure 2.1b). Des del 29/09/2026 el número surt del prefix `NNN-` del nom de
l'adreça de SAP, i `etl.sp_assign_client_ship_no` aplica la mateixa regla a les adreces noves.

**Conseqüència per al dia 2:** les adreces que a la companyia de test no hi són i a la productiva sí
—§6.6 de la memòria: 45 dels 63 locations perduts— arribaran com a adreces noves i **agafaran el seu
número de KAIS automàticament**, no un `MAX+1` inventat. Això no vol cap pas manual, però sí una
comprovació: després del primer run contra la productiva, mirar
`SELECT ship_no_source, COUNT(*) FROM cfg.client_ship_no GROUP BY ship_no_source` i veure que les
altes noves han anat a `PREFIX` i no a `MAXPLUS1`. Si van a `MAXPLUS1` en massa, la productiva no porta
el prefix al nom de l'adreça i **cal parar**: seria el mateix error de l'01/09 amb una altra cara.

### 2.1b Buidar el mirall — obligatori, i no és evident

Canviar `CompanyDb` **no reinicia res**. `sap_raw.sync_state` té com a clau només l'entitat: no
guarda de quina companyia ve cada cursor, i tampoc ho guarda cap taula mirall ni `audit.etl_runs`.
Sense aquest pas, el primer cicle contra la productiva arrenca amb els cursors de test i el mirall
ple de dades de test.

```sql
-- El cursor. Sense això, els documents es demanen des de l'últim UpdateDate vist
-- a test, i tot el que la productiva tingui anterior a aquella data no es baixa mai.
DELETE FROM IntercanviSAP.sap_raw.sync_state;

-- Les taules de documents. El Worker només esborra els DocEntry del lot que
-- baixa, i DB_FARINERA_PROD no retornarà mai els DocEntry de test: les 47
-- capçaleres i 62 línies inventades es quedarien barrejades amb les de
-- productiva i arribarien a Analitza.
TRUNCATE TABLE IntercanviSAP.sap_raw.DLN1;  TRUNCATE TABLE IntercanviSAP.sap_raw.ODLN;
TRUNCATE TABLE IntercanviSAP.sap_raw.RDN1;  TRUNCATE TABLE IntercanviSAP.sap_raw.ORDN;
TRUNCATE TABLE IntercanviSAP.sap_raw.RIN1;  TRUNCATE TABLE IntercanviSAP.sap_raw.ORIN;
TRUNCATE TABLE IntercanviSAP.sap_raw.OINV;
```

Els mestres (`OCRD`, `CRD1`, `OITM`, `OITB`, `OSLP`, `OPYM`) **no** s'han de tocar: el Worker ja els
fa `TRUNCATE` + càrrega sencera a cada cicle.

⚠️ **`cfg.client_ship_no` no s'ha de buidar mai**, ni aquí ni enlloc: congela el número d'adreça de
cada client i **no es pot regenerar**. Si es perd, Analitza enganxa l'històric d'albarans d'una
adreça a una altra.

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

### 2.4 El `discount` — i el `/100`, que ja està resolt

⚠️ **Llegeix això abans de tocar el flag: des del 05/10/2026 la resposta per defecte és NO TOCAR RES.**
L'Adrià ha enumerat per escrit els canvis que farà el dia del tall i **el `discount` no hi és**: manté
el seu `1 - discount`, o sigui que la convenció del multiplicador es queda. `DISCOUNT_AS_PERCENT` es
queda a `'0'`.

El bloc de sota es conserva perquè el dia que es normalitzi —amb calma, no el dia del tall— el
mecanisme és aquest i està provat.

**El `/100` ja no és un canvi coordinat: el treu ell i a nosaltres no ens toca res.** Els preus van
en euros tal com els emetem. **No multiplicar per 100 "per si de cas"**: les dues correccions alhora
tornarien a desquadrar-ho.

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

Del `/100` només queda la vigilància: KAIS li guardava els preus en cèntims i les seves SQL feien
`product_price/100` i `product_cost/100` sense dividir `net_amount`. **El 05/10/2026 confirma que el
treu**, i nosaltres emetem euros. Però si el dia 2 se li oblidés, els preus li quedarien 100× petits,
el `net_amount` quadraria igual i **cap validació nostra ho detectaria**: no es veu des d'aquí, es veu
mirant una línia de la seva banda. Val la pena preguntar-l'hi el dia 3.

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
