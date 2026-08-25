# Regla 05 — Build, tests i estil

## Build i tests

- `dotnet build P:\GAPI07_Analitza\src\SapB1AnalitzaSync.sln -c Release` ha de sortir amb
  **0 errors i 0 warnings**.
- `dotnet test P:\GAPI07_Analitza\src\tests\SapB1AnalitzaSync.Tests` ha de passar.
- **Obligatori** executar els tests abans i després de tocar `ODataQueryBuilder` o la traducció
  d'enums: contenen regressions de bugs històrics, en especial l'absència de `$top` a les consultes
  de cens (Regla 02).
- Lògica pura nova → test nou.

## Estil C#

- PascalCase per a tipus i membres; camelCase per a locals.
- Comentaris **només quan el PER QUÈ no és obvi**. Els gotchas de la Regla 02 són bons candidats;
  un `// incrementa i` no.
- El codi nou s'ha de llegir com el que l'envolta: mateixes convencions, mateixa densitat de
  comentaris.

## Estil T-SQL

- Els SPs de `sql/procs/` són **SQL estàtic**. Des de la migració a Service Layer ja no hi ha
  `sp_executesql` ni `QUOTENAME(@SBOdb)`: si en veus, és una regressió de la Regla 01.
- Res de `WITH (NOLOCK)`: `sap_raw` és una BD nostra, no la BD viva de SAP.
- Tot script de `sql/` ha de ser **idempotent** — `deploy.sql` s'executa tantes vegades com calgui.
- Capçalera de comentari a dalt de cada SP amb origen, destí i regles de transformació, com ja fan
  els existents.

## Scripts PowerShell

- Compatibles amb **PowerShell 5.1**, i **en ASCII** (5.1 s'ennuega amb els accents i produeix
  mojibake).
- Les credencials es demanen interactivament (`Read-Host -AsSecureString`), mai com a paràmetre
  amb default ni hardcodejades.
