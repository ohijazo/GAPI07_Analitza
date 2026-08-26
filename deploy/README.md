# Desplegament del Worker a AE01SAPRDP

El Worker corre com a **tasca programada** al servidor d'aplicacions
`AE01SAPRDP` (192.168.11.239, Windows Server), no al servidor de SQL.

**AE01SAPRDP allotja webservices de col·laboradors externs.** Això condiciona com s'hi posen les
credencials: res de variables d'entorn de màquina, que qualsevol procés de la màquina pot llegir.

---

## Per què no és un pas del job de SQL Agent

SQL Agent no pot llançar un procés en una altra màquina. Són dos planificadors que no es parlen: la
tasca a `AE01SAPRDP` a les **02:45** i el job a `AE01SAPSQL` a les **03:00**.

La garantia que l'ETL no transformi un mirall vell **no la dona l'ordre dels passos**, la dona la
guarda de frescor de `sp_run_all`: si `sap_raw.sync_state` té més de
`cfg.settings.MIRROR_MAX_AGE_HOURS` hores (6 per defecte), avorta amb `ABORTED_STALE_MIRROR` i
`dbo.est_*` es queda com estava.

No és teòric: el 26/08/2026, la primera vegada que es va provar, va detectar que el mirall tenia 24
hores i que les transformacions d'aquell matí anaven sobre dades del dia anterior.

---

## 1. Copiar els binaris

Des de `AE01SAPRDP`, en PowerShell **elevada**:

```powershell
New-Item -ItemType Directory -Force C:\Apps\SapB1AnalitzaSync
Copy-Item "\\tomatera\Farinera\ohijazo\GAPI07_Analitza\publish\*" C:\Apps\SapB1AnalitzaSync -Recurse -Force
```

La publicació és **autocontinguda**: no cal instal·lar el runtime de .NET 8 al servidor.

Per regenerar-la, des de l'equip de desenvolupament:

```
dotnet publish P:\GAPI07_Analitza\src\SapB1AnalitzaSync.Worker -c Release -r win-x64 --self-contained true -o P:\GAPI07_Analitza\publish
```

## 2. El compte que executa la tasca

Cal un compte dedicat, no el teu. Ha de poder:

- Sortir a `192.168.11.238:50000` (Service Layer, HTTPS)
- Sortir a `192.168.11.238:1433` (SQL Server) i **escriure a `IntercanviSAP.sap_raw`**
- Tenir el dret *Log on as a batch job* a `AE01SAPRDP`

No li cal ser administrador ni tocar res més de la màquina.

## 3. La configuració, i per què no va a variables d'entorn

En una màquina compartida amb serveis de tercers, una variable d'entorn de màquina és llegible per
qualsevol procés. Per això la configuració va en un fitxer al costat de l'executable, protegit per
permisos NTFS.

Crea `C:\Apps\SapB1AnalitzaSync\appsettings.Production.json`:

```json
{
  "ServiceLayer": {
    "BaseUrl": "https://192.168.11.238:50000/b1s/v1/",
    "CompanyDb": "DB_FARINERA_TEST",
    "UserName": "<usuari tecnic de SAP, nomes lectura>",
    "Password": "<...>",
    "AllowInvalidCertificates": true
  },
  "Database": {
    "ConnectionString": "Server=AE01SAPSQL;Database=IntercanviSAP;User Id=<usuari>;Password=<...>;Encrypt=False;TrustServerCertificate=True"
  }
}
```

`AllowInvalidCertificates` a `true` perquè el certificat del Service Layer és autofirmat. Si algun
dia se'n posa un de vàlid, cal treure-ho.

I tanca la carpeta: **només el compte de la tasca i els administradors**.

```powershell
icacls C:\Apps\SapB1AnalitzaSync /inheritance:r
icacls C:\Apps\SapB1AnalitzaSync /grant:r "DOMINI\compte-tasca:(OI)(CI)(RX)"
icacls C:\Apps\SapB1AnalitzaSync /grant:r "Administrators:(OI)(CI)(F)"
icacls C:\Apps\SapB1AnalitzaSync /grant:r "SYSTEM:(OI)(CI)(F)"
```

Comprova-ho després amb `icacls C:\Apps\SapB1AnalitzaSync`: no hi ha d'aparèixer `Users` ni
`Everyone`.

## 4. La tasca programada

```powershell
$acc = "DOMINI\compte-tasca"
$act = New-ScheduledTaskAction -Execute "C:\Apps\SapB1AnalitzaSync\SapB1AnalitzaSync.Worker.exe" `
                               -Argument "--once" `
                               -WorkingDirectory "C:\Apps\SapB1AnalitzaSync"
$trg = New-ScheduledTaskTrigger -Daily -At 02:45
$set = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
                                    -StartWhenAvailable -DontStopOnIdleEnd
Register-ScheduledTask -TaskName "GAPI07 Refresca sap_raw" `
    -Action $act -Trigger $trg -Settings $set `
    -User $acc -Password (Read-Host "Password de $acc" -AsSecureString | ConvertFrom-SecureString -AsPlainText) `
    -RunLevel Limited
```

L'entorn ha de ser `Production` perquè agafi l'`appsettings.Production.json`. Es fa amb una variable
d'entorn **d'usuari** del compte de la tasca:

```powershell
[Environment]::SetEnvironmentVariable("DOTNET_ENVIRONMENT", "Production", "User")
```

(executat en una sessió d'aquell compte), o afegint-ho a l'script d'arrencada. Si no es fa, el
Worker arrenca sense configuració i surt amb codi 3.

## 5. Provar-la

```powershell
Start-ScheduledTask -TaskName "GAPI07 Refresca sap_raw"
Get-ScheduledTaskInfo -TaskName "GAPI07 Refresca sap_raw" | Format-List TaskName, LastRunTime, LastTaskResult
```

`LastTaskResult` ha de ser `0`. Qualsevol altra cosa vol dir que no ha anat bé:

| Codi | Què vol dir |
|---|---|
| 0 | Correcte |
| 1 | El cicle ha fallat: mira el log de la consola |
| 3 | Falta configuració (`BaseUrl` buit o amb `<placeholder>`) |
| 2147942401 | No troba l'executable, o el compte no hi té permisos |

I des de SQL Server, la comprovació que de veritat importa:

```sql
SELECT entity, updated_at, DATEDIFF(HOUR, updated_at, SYSUTCDATETIME()) AS hores
FROM   IntercanviSAP.sap_raw.sync_state ORDER BY updated_at;
```

Si `hores` és 0, la tasca ha corregut i el job de les 03:00 podrà transformar.

## 6. Comprovació de conjunt

L'endemà al matí:

```sql
SELECT TOP 3 run_id, started_at, [status], LEFT(ISNULL(error_message,''),90) AS err
FROM   IntercanviSAP.audit.etl_runs ORDER BY run_id DESC;
```

- `SUCCESS` — tot ha anat bé.
- `ABORTED_STALE_MIRROR` — la tasca de `AE01SAPRDP` no ha corregut. Mira-la abans de res.
- `BLOCKED` — la tasca sí que ha corregut, però els checks de qualitat han trobat alguna cosa i el
  swap s'ha avortat. Mira `audit.data_quality_warnings`.

---

## Al cutover (2 de novembre)

Canviar `CompanyDb` a `DB_FARINERA_PROD` a l'`appsettings.Production.json` i reiniciar res: la tasca
el rellegeix a cada execució.

I recorda abaixar `cfg.settings.LINES_MIN_RATIO` aquell dia: la SAP productiva arrenca sense
històric d'albarans i el recompte caurà a propòsit, cosa que el check `lines_collapsed` bloquejaria.
