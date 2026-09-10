# GAPI07_Analitza — Integració SAP B1 → Analitza CM

Substitueix KAIS com a origen de dades d'Analitza CM. Un Worker .NET 8 llegeix SAP Business One
per **Service Layer** i escriu un mirall a `IntercanviSAP.sap_raw`; uns stored procedures T-SQL
transformen aquest mirall al format KAIS a `staging.est_*`, i després d'un bloc de validacions
es fa un swap atòmic a `dbo.est_*`, que és l'únic que veu Analitza.

Cutover a productiva previst pel **Novembre 2026**.

## Regles del projecte

@.claude/rules/01-acces-sap.md
@.claude/rules/02-service-layer-odata.md
@.claude/rules/03-secrets-i-configuracio.md
@.claude/rules/04-contracte-analitza.md
@.claude/rules/05-build-tests-i-estil.md

## Comandes habituals

```powershell
# Worker (sempre amb entorn Development perquè carreguin els user-secrets)
cd P:\GAPI07_Analitza\src\SapB1AnalitzaSync.Worker
$env:DOTNET_ENVIRONMENT='Development'
dotnet run -- --probe                # sonda de Service Layer, NO toca cap BD
dotnet run -- --once                 # un cicle complet: refresca sap_raw i surt

# Build i tests
dotnet build P:\GAPI07_Analitza\src\SapB1AnalitzaSync.sln -c Release   # 0 warnings
dotnet test  P:\GAPI07_Analitza\src\tests\SapB1AnalitzaSync.Tests
```

```powershell
# Correus i documents: markdown -> Word. El --from/--to retalla la capcalera i
# la nota interna, que no han de sortir mai al fitxer que s'envia.
python tools\md2docx.py resposta_sistemes_2026-09-10.md resposta_sistemes_2026-09-10.docx `
    --from "Hola," --to "ohijazo@agrienergia.com"

# Abans d'enviar res: quins .docx s'han quedat enrere del seu .md
python tools\md2docx.py --check
```

```sql
-- Executar l'ETL a mà (mode inspecció: deixa dades a staging, no fa swap)
EXEC IntercanviSAP.etl.sp_run_all @SkipSwap=1, @ForceFullLines=1;

-- Estat de les últimes càrregues
SELECT TOP 5 run_id, started_at, finished_at, status, error_message
FROM IntercanviSAP.audit.etl_runs ORDER BY run_id DESC;
```

## Estructura

| Ruta | Contingut |
|---|---|
| `src/SapB1AnalitzaSync.Worker/` | Worker .NET 8: Service Layer → `sap_raw` |
| `src/SapB1AnalitzaSync.Shared/` | Contractes, opcions, `ODataQueryBuilder` |
| `src/tests/SapB1AnalitzaSync.Tests/` | xUnit — lògica pura |
| `sql/schema/` | DDL de `IntercanviSAP` (`est_*`) i de `sap_raw` |
| `sql/procs/` | Els 11 stored procedures de l'ETL |
| `sql/cfg/` | Seeds de configuració (mapatges de país, zona, atributs) |
| `sql/jobs/` | Job de SQL Agent de les 03:00 |
| `docs/` | Documentació externa (guia d'Analitza, blueprint, correus) |
