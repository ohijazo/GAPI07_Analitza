# Regla 03 — Secrets i configuració

## Secrets

- ❌ **Mai** un secret real a `appsettings.json`, al codi, als scripts SQL ni a un commit.
- ✅ A `appsettings.json` hi van **només placeholders** de la forma `<from-secrets-manager>`,
  `<sap-host>`, `<sql-host>`. Si hi veus un valor que sembla real, és un bug.
- ✅ **DEV**: `dotnet user-secrets` (viuen a `%APPDATA%\Microsoft\UserSecrets`, fora del repo).
- ✅ **PRD**: variables d'entorn de màquina del compte de servei.

`.gitignore` ja bloqueja `**/secrets.json`, `.env` i els fitxers de cookies de SL. Abans de
commitejar res que faci olor de config, comprova que segueix cobert.

## L'usuari de SAP és tècnic i de només lectura

Ni `manager` ni cap usuari nominal. Un usuari dedicat, amb permisos mínims, i que es pugui
identificar als logs d'auditoria de SAP. El mateix criteri per l'usuari SQL que escriu a
`sap_raw`: no és `sa`, és un usuari propi amb permisos només sobre `IntercanviSAP`.

## `IOptions<T>` bindeja llistes **afegint**, no substituint

Si una col·lecció d'opcions ve preinicialitzada amb defaults a la classe **i** `appsettings.json`
en porta N, el resultat és la suma. Inicialitzar les col·leccions **buides** a la classe i deixar
els defaults només a `appsettings.json`.

## Els user-secrets només es carreguen a `Development`

Executar sempre amb `$env:DOTNET_ENVIRONMENT='Development'` o el binding retornarà nulls i
placeholders, i perdràs temps depurant un "bug" que és d'entorn.

## On apunta la companyia de SAP

Fins a la migració ho deia `cfg.settings.SBO_DB` dins de la BD. Ara ho diu
**`ServiceLayer:CompanyDb`** a la configuració del Worker. El cutover a productiva (Novembre 2026)
és un canvi de configuració del Worker, **no** un `UPDATE` a `cfg.settings`.
