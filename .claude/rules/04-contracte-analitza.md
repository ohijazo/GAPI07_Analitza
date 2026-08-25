# Regla 04 — El contracte amb Analitza

Analitza CM consulta `IntercanviSAP.dbo.est_*` amb les seves pròpies consultes SQL, escrites contra
el que els donava KAIS. **Les 8 taules `est_*` són un contracte, no un detall d'implementació.**

## Intocable sense acordar-ho amb Analitza

- **Noms de taules i de columnes** de `dbo.est_*`. Estan calcats de KAIS expressament perquè
  Analitza no hagi de canviar cap consulta.
- **`est_clients.id_client_location`** = `CardCode + '-' + LPAD(LineNum, 3)`. És la clau que enllaça
  clients, línies d'albarà, atributs i cobraments. Si canvia, Analitza perd l'històric de tots els
  clients.
- **`est_linies_albara.id_invoice_line`** = `offset + DocEntry*100 + LineNum`, amb
  `offset` = `100000000` (albarans), `200000000` (devolucions), `300000000` (abonaments). El rang
  identifica l'origen del document; hi ha codi que en depèn (el mode incremental de
  `sp_load_invoice_lines` en dedueix el `source`).
- **`discount` és un multiplicador**, no un percentatge: `1.00` = sense descompte, `0.90` = 10% de
  descompte. Ho fa així KAIS. La fórmula que ha de quadrar és
  `net_amount = product_price * quantity * discount`.
- **Els imports negatius** de devolucions i abonaments porten `quantity` negativa també. La guia
  d'Analitza ho exigeix i `sp_data_quality_checks` ho verifica.

## Formats que exigeix la guia d'Analitza

`docs\Guia de importación de datos Analitza CM v9.pdf` mana. En resum: dates `AAAA-MM-DD`, números
sense separador de milers i amb punt decimal, signe negatiu **davant**, imports sempre sense IVA.
`country_code` en minúscules i ISO 3166-1 de 2 caràcters.

## Analitza no veu mai dades a mig carregar

L'ETL treballa sempre a `staging.*`, valida, i només si no hi ha cap warning `CRITICAL` fa
`TRUNCATE + INSERT` a `dbo.*` dins d'una sola transacció (`etl.sp_swap_staging_to_prod`). Si les
validacions fallen, `dbo.*` es queda amb les dades del dia anterior i el run marca `BLOCKED`.
**No afegir cap camí d'escriptura a `dbo.est_*` que se salti aquest swap.**

## Camps opcionals vs obligatoris

A la guia d'Analitza, només els camps marcats amb `*` són obligatoris. `product_cost`,
`product_cost_2`, `discount`, `transaction`, `comments`, `holidays_*` són opcionals: si Service
Layer no exposa l'origen d'un d'aquests, es pot deixar buit avisant Analitza. Els obligatoris no.
