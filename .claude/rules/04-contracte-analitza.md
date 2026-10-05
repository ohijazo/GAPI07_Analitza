# Regla 04 — El contracte amb Analitza

Analitza CM consulta `IntercanviSAP.dbo.est_*` amb les seves pròpies consultes SQL, escrites contra
el que els donava KAIS. **Les 8 taules `est_*` són un contracte, no un detall d'implementació.**

## Intocable sense acordar-ho amb Analitza

- **Noms de taules i de columnes** de `dbo.est_*`. Estan calcats de KAIS expressament perquè
  Analitza no hagi de canviar cap consulta.
- **`est_clients.id_client_location`** = `<codi de client> + '-' + <número d'adreça de 3 dígits>`. És
  la clau que enllaça clients, línies d'albarà, atributs i cobraments. Si canvia, Analitza perd
  l'històric de tots els clients.

  ⚠️ **El número d'adreça NO és el `CRD1.LineNum` ni la posició de l'adreça dins del client.** Viu
  congelat a `cfg.client_ship_no`, i el valor surt del **prefix `NNN-` del nom de l'adreça de SAP**
  (`CRD1.Address` = `003-SANT QUIRZE-ST. QUIRZE`), que és on la migració KAIS→SAP va deixar el número
  que Analitza té a l'històric. La regla viu en un sol lloc, `etl.vw_client_ship_kais_no`.

  Aquesta línia ha estat **dues vegades falsa**: deia `LPAD(LineNum, 3)` quan ja feia setmanes que era
  el `ship_no` congelat, i el `ship_no` es va congelar el 01/09/2026 amb un `ROW_NUMBER()` per
  `LineNum` que era una **permutació** dels números bons. Es va corregir el 29/09/2026 (804 adreces)
  després que la comparativa d'Analitza ho destapés: 87,6 % → 99,2 % de codis postals quadrant contra
  el seu propi cens. Qualsevol hipòtesi nova sobre aquest número **es mesura contra
  `cfg.analitza_client_export`** amb `sql/verify_ship_no.sql`, mai contra `baseline`.

  El `<codi de client>` **no és el `CardCode` de SAP**: és
  `COALESCE(U_FCCodiKais, CardCode)`, i viu en un sol lloc, `etl.vw_client_code`. Els identificadors
  que Analitza té a l'històric són els de KAIS (8 dígits); qui es doni d'alta a SAP després del tall
  portarà el seu `CardCode` (`C` + 6) i el conservarà. Els dos formats no es poden trepitjar.
  El mateix per als comercials amb `etl.vw_salesman_code`.

  Si en un SP hi veus `RTRIM(CardCode) + '-'` en comptes d'un JOIN a la vista, és una regressió: la
  fórmula estava repetida a vuit llocs i n'hi ha prou que dues còpies divergeixin perquè
  `est_clients` i `est_atributs_client` deixin de lligar.
- **`est_linies_albara.id_invoice_line`** = `offset + DocEntry*100 + LineNum`, amb
  `offset` = `100000000` (albarans), `200000000` (devolucions), `300000000` (abonaments). El rang
  identifica l'origen del document; hi ha codi que en depèn (el mode incremental de
  `sp_load_invoice_lines` en dedueix el `source`).
- **`discount` és un multiplicador**, no un percentatge: `1.00` = sense descompte, `0.90` = 10% de
  descompte. Ho fa així KAIS. La fórmula que ha de quadrar és
  `net_amount = product_price * quantity * discount`. És `decimal(9,6)`: amb dos decimals un
  descompte del 3,33% s'arrodonia a `0,97` i `formula_break` saltava cada nit.

- **✅ L'escala de `product_price` és en EUROS, i això ja està acordat per escrit (05/10/2026).**
  KAIS els guardava en cèntims i les SQL que Analitza executava de debò
  (`docs/sql importació Farinera.sql`) feien `product_price/100` i `product_cost/100` sense dividir
  `net_amount`. **El `/100` el treu ell**: al correu del 05/10/2026 enumera els canvis que ja té
  provats per al dia del tall, i els dos primers són `product_price/100 -> product_price` i
  `product_cost/100 -> product_cost`.

  Es deixa escrit perquè era **l'únic punt del contracte que el dia del tall fallava en silenci**:
  si ell hagués mantingut el `/100`, els preus li quedarien 100× petits, el `net_amount` quadraria
  igual i cap validació nostra ho detectaria. **No multiplicar per 100 al nostre costat**, ni
  "per si de cas": les dues correccions alhora tornarien a desquadrar-ho.

  Del mateix correu: **ell carrega només línies amb `date >= '2026-11-02'`**, així que res del que
  publiquem abans del tall li arriba. I **no diu res del `discount`**, o sigui que manté el seu
  `1 - discount` i la convenció del multiplicador es queda com està (`DISCOUNT_AS_PERCENT = '0'`).
- **Els imports negatius** de devolucions i abonaments porten `quantity` negativa també. La guia
  d'Analitza ho exigeix i `sp_data_quality_checks` ho verifica.

## Formats que exigeix la guia d'Analitza

`docs\Guia de importación de datos Analitza CM v9.pdf` mana. En resum: dates `AAAA-MM-DD`, números
sense separador de milers i amb punt decimal, signe negatiu **davant**, imports sempre sense IVA.
`country_code` en minúscules i ISO 3166-1 de 2 caràcters.

## Un identificador no pot desaparèixer

Si un `id_client_location` que ahir hi era avui no hi és, Analitza no veu un error: veu un client
que ha deixat de comprar. El mateix amb productes, famílies i comercials.

El check `vanished_ids` de `sp_data_quality_checks` ho vigila cada nit comparant `dbo.*` (ahir)
contra `staging.*` (avui). WARN si en són poques, **CRITICAL a partir de `cfg.settings.ID_DROP_MAX`**,
i llavors s'atura el swap.

Si algun dia cal apujar el llindar —un canvi massiu previst, com el cutover— es fa expressament i es
torna a baixar. No s'ha de tocar per fer callar un avís que no s'entén: aquest check existeix
precisament per als casos que no s'entenen.

## Analitza no veu mai dades a mig carregar

L'ETL treballa sempre a `staging.*`, valida, i només si no hi ha cap warning `CRITICAL` fa
`TRUNCATE + INSERT` a `dbo.*` dins d'una sola transacció (`etl.sp_swap_staging_to_prod`). Si les
validacions fallen, `dbo.*` es queda amb les dades del dia anterior i el run marca `BLOCKED`.
**No afegir cap camí d'escriptura a `dbo.est_*` que se salti aquest swap.**

## Camps opcionals vs obligatoris

A la guia d'Analitza, només els camps marcats amb `*` són obligatoris. `product_cost`,
`product_cost_2`, `discount`, `transaction`, `comments`, `holidays_*` són opcionals: si Service
Layer no exposa l'origen d'un d'aquests, es pot deixar buit avisant Analitza. Els obligatoris no.
