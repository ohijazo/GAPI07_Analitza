# Regla 02 — Service Layer i construcció de queries OData

Gotchas **confirmats en producció** contra SAP B1 10.0 FP 2602, heretats de GAPI03_CRM
(`P:\GAPI03_CRM\.claude\rules\02-service-layer-odata.md`). Cadascun va costar una sessió de
depuració. No reintroduir-los.

## `$top` és un cap TOTAL, no una mida de pàgina

**La regla més important d'aquest fitxer.**

A OData, `$top=N` limita els registres retornats **sumant totes les pàgines** del
`odata.nextLink`, no per pàgina.

Bug real que va provocar a GAPI03: la reconciliació demanava `$top=500`, hi havia 857 clients
actius, SL en retornava 500 → els 357 restants s'interpretaven com a "ja no existeixen a SAP" i
**es desactivaven silenciosament cada dia**.

- ❌ **Mai emetre `$top` en una consulta destinada a cobrir l'univers sencer d'una entitat**
  (cens complet / snapshot FULL / reconciliació).
- ✅ Paginar amb `Prefer: odata.maxpagesize=N` i seguir `odata.nextLink` fins a esgotar-lo.
- Hi ha test de regressió a `src/tests/SapB1AnalitzaSync.Tests` que falla si es reintrodueix.

## La capçalera `Prefer: odata.maxpagesize=<N>` és obligatòria

El default de `b1s.conf` són 20 registres per pàgina. Sense aquesta capçalera SL **ignora `$top`**
i en retorna 20. A GAPI03 l'impacte mesurat va ser de 8× (1.453 items en ~76 s → 1.821 en ~9 s).

## `$filter` buit retorna 400

Emetre `$filter=` sense contingut trenca la petició. Guardar-ho sempre:

```csharp
if (filter.Length > 0) { /* emetre $filter */ }
```

## SL 10.0 FP 2602 no accepta literals `Edm.Time` a `$filter`

`time'PT..'` respon `Property 'time' of '<entity>' is invalid`.

- Filtrar només per `Edm.DateTime` (`UpdateDate`), **sense** clàusula d'`UpdateTime`.
- Compensar amb **overlap d'un dia** al checkpoint; el MERGE és idempotent i cobreix el solapament.
- `UpdateTime` **sí** funciona a `$orderby`.

## Login: JSON case-sensitive

`PostAsJsonAsync` a .NET 8 aplica `JsonSerializerDefaults.Web` (camelCase). SL espera
`CompanyDB` / `UserName` / `Password` exactes. Passar `JsonSerializerOptions` **sense**
`PropertyNamingPolicy`, o rebràs:

```json
{"error":{"code":206,"message":"Invalid login credential."}}
```

## Altres

- `DateTime.MinValue.AddMinutes(-1)` **desborda**. Per a l'expiració de sessió, comparar sempre
  `if (_sessionExpiresAtUtc > DateTime.UtcNow.AddMinutes(1))`.
- Dos `Login` del mateix usuari en pocs segons poden fallar amb `Invalid login credential.` — és
  throttling del pool de sessions. Espaiar logins o reutilitzar la cookie.
- El cursor compost `(UpdateDate, key)` sense `UpdateTime` pot saltar registres quan l'ordre real
  és `(UpdateDate, UpdateTime, key)`. Pàgines grans ho minimitzen i l'overlap d'un dia els recupera
  al cicle següent.

## Traducció d'enums

El mirall `sap_raw` guarda la **forma nativa de SAP**, no la de Service Layer, perquè els SPs de
l'ETL no s'hagin d'assabentar d'on venen les dades:

| Service Layer | `sap_raw` |
|---|---|
| `Valid: "tYES"` / `"tNO"` | `validFor = 'Y'` / `'N'` |
| `Frozen: "tYES"` / `"tNO"` | `frozenFor = 'Y'` / `'N'` |
| `CardType: "cCustomer"` | `CardType = 'C'` |
| `AddressType: "bo_ShipTo"` | `AdresType = 'S'` |
| `DocumentStatus: "bost_Open"` | `DocStatus = 'O'` |
| `LineType: "dlt_Comment"` | `LineType = 'T'` |

La traducció viu en un sol lloc (`SapEnums`) i té tests. Si algun cop cal afegir-n'hi una, va allà.
