# Correu per Adrià Arnau (Analitza CM)

**Per a:** adria@analitza.com
**CC (opcional):** lbutinya@agrienergia.com
**Assumpte:** Analitza CM — nou origen SAP B1 llest a test (IntercanviSAP a AE01SAPSQL)

---

Hola Adrià,

Ja tenim llesta la nova BD que substituirà l'actual `Intercanvi`. Aquesta nova BD s'alimenta directament de SAP Business One (entorn de test) i manté els mateixos noms de taules i estructura general que consumiu ara. He intentat que el canvi sigui el més transparent possible, però hi ha una sèrie de diferències inevitables que et detallo a continuació.

## Dades de connexió (entorn de test)

| | |
|---|---|
| **Servidor** | `AE01SAPSQL` (MSSQL, port 1433) |
| **Base de dades** | `IntercanviSAP` |
| **Usuari** | `analitza_ro` |
| **Contrasenya** | *te l'envio per canal segur a part (Signal / Bitwarden Send)* |
| **Permisos** | `db_datareader` només a `IntercanviSAP`. La resta de BD del servidor tenen `DENY CONNECT` explícit per aquest usuari. |
| **Hora d'extracció** | El nostre procés de càrrega acaba a les ~03:30. Podeu mantenir la vostra a les 06:00 sense conflicte. |

## Taules disponibles a `IntercanviSAP.dbo`

Mateixos noms i estructura WIDE que teniu ara:

- `est_agents`
- `est_families_productes`
- `est_clients`
- `est_productes`
- `est_linies_albara`
- `est_atributs_client` (8 columnes fixes: `zone_id, zone_description, payment_method, payment_description, positioning_bcn_consulting, segmentation_use_1, segmentation_use_2`)
- `est_atributs_producte` (3 columnes: `art_codi, subfamily_description, units_description`)
- `est_cobraments`

## Recomptes actuals a test

| Taula | Files SAP test | Referència Intercanvi actual |
|---|---:|---:|
| `est_agents` | 49 | 48 |
| `est_families_productes` | 110 | 2.051 (vegeu diferència 6 més avall) |
| `est_clients` | 5.651 | 5.666 |
| `est_productes` | 2.028 | 2.051 |
| `est_linies_albara` | 59 | 570.383 |
| `est_atributs_client` | 5.651 | 5.666 |
| `est_atributs_producte` | 2.028 | 2.051 |
| `est_cobraments` | 9 | 201.061 |

Els volums petits de línies i cobraments són perquè la BD SAP de test té historial molt limitat (només uns mesos). A la productiva seran ordres de magnitud comparables als de l'`Intercanvi` actual.

## Diferències respecte a l'`Intercanvi` actual (i què implica per vosaltres)

### 1. `id_client_location` — canvia el codi però es manté el format

- **Ara**: `"00001066-000"` (8 dígits + `-` + 3 dígits)
- **Nou**: `"C001024-000"` (7 caràcters alfanumèrics + `-` + 3 dígits)

Els codis interns dels clients a SAP són diferents dels actuals (SAP els va crear amb la seva pròpia numeració). No podem preservar els codis antics tal qual. El **format es manté** (`varchar(13)`), però els valors concrets seran diferents.

La part final de 3 dígits continua identificant una adreça específica del client (000 = adreça per defecte, 001, 002, ... = altres ubicacions). Els números seran diferents dels actuals però la semàntica es manté.

### 2. `est_atributs_client.zone_id` i `zone_description` — resolt, però codis diferents

Hem trobat que la zona ve d'un camp a l'adreça del client. Al nou entorn ja us arriben els mateixos noms de zona que ara (`"GIRONA POBLACIONS"`, `"BARCELONA POBLACIONS"`, `"VALENCIA"`, etc.). Cobertura actual: **79% dels ship-tos** tenen zona assignada. La resta (adreces sense zona a SAP) us arribaran com a `zone_id="0000"` / `zone_description="SENSE ZONA"` — mateixa convenció que ja utilitzeu.

**El `zone_id` numèric no és el mateix que abans**: hem assignat codis seqüencials nostres (0001–0046 per ordre alfabètic, + 0000 = SENSE ZONA) perquè al nostre nou origen només s'emmagatzema el nom de la zona, no un codi numèric. **Si per vosaltres és important preservar els codis històrics (0011=Girona Poblacions, 0025=Barcelona Poblacions, etc.), passeu-nos la llista de zones amb el codi actual i els substituïm al nostre catàleg 1:1**. Amb un únic UPDATE quedaria harmonitzat i els vostres informes veurien els mateixos codis abans i després del cutover.

Si us és igual el codi numèric i preferiu treballar pel `zone_description`, no cal fer res.

### 3. `est_atributs_client.payment_method` — codi diferent, descripció mantinguda

- **Ara**: codi numèric 3 dígits (`"071"`, `"031"`, `"075"`)
- **Nou**: primers 3 caràcters del codi SAP (`"C-T"` per Transferència, `"C-E"` per Efectiu, `"C-R"` per Rebut...)

La **descripció (`payment_description`) es manté** intacta (`"TRANSFERENCIA A 30 DIES..."`, `"REBUT BANCARI A 30 DIES..."`). Si les vostres consultes fan servir la descripció, no cal canviar res. Si feien JOIN o filtres pel `payment_method` literal, s'haurà de reescriure.

### 4. `id_invoice_line` — canvia el codi però es manté el tipus (int)

Continua sent `int`. Nosaltres el generem determinísticament a partir del document original (offset per tipus de document: albarans, retorns, credit memos). Estable entre execucions. **Els nombres seran diferents dels actuals però el tipus i l'ús es mantenen.**

### 5. `invoices_id` — format més simple

- **Ara**: format any+sèrie+número (`"2018370000005"`)
- **Nou**: només el número del document SAP (`"26700001"`)

Mantenim `varchar(13)`. El nou format és més curt però únic dins de SAP.

### 6. `est_families_productes` — normalitzada

A la BD actual aquesta taula té 2.051 files (una per producte, amb valors majoritàriament buits o duplicats — sembla que allà s'hi fica una fila per cada producte).

A la nova, aquesta taula té 110 files (una per grup de productes real). El `JOIN` `est_productes.product_categories_id = est_families_productes.id_product_category` continua funcionant i us dona el nom correcte. **El que canvia és el `COUNT(*)` d'aquesta taula.**

Digues-nos si aquest canvi de normalització us trenca algun informe.

### 7. `est_clients` — sense holidays/comments/payment_method

Aquestes columnes ja no venen a `est_clients`. `payment_method` s'ha desplaçat a `est_atributs_client` (per coherència amb l'esquema WIDE). `holidays_start_date/end_date` i `comments` no existeixen amb equivalència a SAP.

Si aquests camps s'utilitzen al vostre motor, digues-nos-ho i mirem com resoldre-ho.

### 8. `est_atributs_producte.units_description` — mantingut

Continua amb el mateix format (3 caràcters: `"GRA"`, `"UNI"`, `"SAC"`, `"KG"`...). Sense canvis significatius.

### 9. Signes de línies negatives — sense canvis

Retorns i credit memos continuen amb `quantity` i `net_amount` en negatiu. No fem servir cap camp `transaction`.

### 10. Fórmula `net_amount` — sense canvis

Continuem amb la convenció actual: `net_amount = quantity × product_price × discount` on `discount` és un multiplicador (1.00 = sense descompte, 0.90 = 10% de descompte).

## Validacions automàtiques que fem a cada càrrega

- Signes coherents `quantity` ↔ `net_amount`
- Fórmula `net_amount = qty × price × discount` (tolerància 0.01€)
- `country_code` en minúscules
- Integritat referencial (línies apunten a clients/productes existents)
- Detecció de pics anòmals en volum diari

Si algun check "CRITICAL" falla, la publicació dels canvis es cancel·la i les taules mantenen les dades del dia anterior. Mai veureu dades inconsistents parcials.

## Preguntes obertes per la teva banda

### Connexió — VPN i firewall

1. **IP de sortida d'Analitza**: necessitem la IP pública (o rang) des d'on us connectareu per obrir la regla de firewall a `AE01SAPSQL` (port 1433/TCP). Sistemes obre la regla el mateix dia que ens la donis.

2. **VPN**: aprofites la VPN que ja teniu configurada per l'actual `Intercanvi`, o us cal una VPN nova? Si aprofiteu l'actual, cal que confirmis que us dona ruta al servidor `AE01SAPSQL` (segment intern d'Agrienergia). Si no, l'estenem.

### Històric — punt important a coordinar

Sabem que teniu ~570.000 línies d'albarà des de 2018 al vostre origen actual. **A la BD SAP productiva NO hi haurà historial d'albarans anteriors** (només s'hi pujaran les factures obertes / operativa nova). Això vol dir que la nova BD `IntercanviSAP` alimentada des de SAP **només portarà dades des del cutover en endavant**.

L'històric 2018 → cutover queda a la BD actual, que després del canvi a SAP passarà a mode "freeze" (sense noves entrades, però mantinguda com a font de consulta històrica).

Aquestes són les 3 opcions que veiem:

3. **Persistència de l'històric al vostre motor** *(la més neta)*: un cop ingesteu una línia, queda al vostre sistema d'anàlisi i no depeneu de re-llegir cada nit la BD `Intercanvi`?
   - Si sí: perfecte. Nosaltres us donem el delta SAP a partir del cutover i vosaltres conserveu tot el que ja teniu ingestat. Ni cal mantenir res antic viu.
   - Si no: cal que us mantinguem un accés als històrics d'alguna manera (opcions 4 o 5).

4. **Accés perpetu a la BD `Intercanvi` actual (freeze) + `IntercanviSAP` (nova)**: si necessiteu re-llegir l'històric ocasionalment, us funciona operacionalment consultar dues BDs?
   - `Intercanvi` (l'actual, congelada al cutover) → dades històriques 2018 → cutover
   - `IntercanviSAP` (la nova) → dades des del cutover en endavant
   - Les vostres consultes farien `UNION ALL` entre les dues quan necessiteu longitudinal.
   - Nosaltres mantindríem viu l'accés a `Intercanvi` sense alimentar-la (només lectura, congelada).

5. **Migració one-off de l'històric a `IntercanviSAP`**: alternativament podem fer una càrrega única de les 570k línies històriques a la BD nova, sota el mateix esquema, mantenint els `id_client_location` antics. Us arribaria tot per una sola connexió. **Té un cost tècnic per la nostra banda** (script one-off + validació + gestió dels clients que ja no existeixen a SAP), però pot ser més còmode per vosaltres.

Quina opció s'ajusta més al vostre model d'ingesta i anàlisi?

6. **Continuïtat de "mateix client" entre històric i futur**: independentment de l'opció triada, els `id_client_location` canviaran del cutover en endavant (`"00201011-000"` → `"C201128-000"`). Podreu enllaçar el mateix client entre els dos períodes via **NIF/CIF** (que sí és estable), o us cal absolutament el mateix `id_client_location` per fer l'anàlisi longitudinal?

## Pendents per la nostra banda

- Configurar avisos automàtics per email si el procés de càrrega falla (no bloquejant).
- Migrar la connexió de la BD SAP test a la productiva quan toqui (canvi d'un sol paràmetre).
- Setmanes de validació en paral·lel abans del tall definitiu al Novembre 2026.

## Següent pas

Quan vulguis ens posem mitja hora a Teams per repassar-ho, decidir cronograma de validació, i que ens confirmis els punts 1-6. Avisa'm.

Salutacions,
Oscar Hijazo
Agrienergia
ohijazo@agrienergia.com
