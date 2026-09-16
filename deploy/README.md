# Desplegament del Worker a AE01SAPRDP

El Worker corre com a **tasca programada** al servidor d'aplicacions
`AE01SAPRDP` (192.168.11.239, Windows Server), no al servidor de SQL.

**AE01SAPRDP allotja webservices de col·laboradors externs.** Això condiciona com s'hi posen les
credencials: res de variables d'entorn de màquina, que qualsevol procés de la màquina pot llegir.

## Qui fa què (acordat amb Sistemes el 16/09/2026)

La màquina no és nostra i no hi som administradors. El repartiment és aquest, i explica per què
alguns passos d'aquest document ja no els executem nosaltres:

| Sistemes | Nosaltres |
|---|---|
| ~~Crear `C:\Apps\SapB1AnalitzaSync`~~ ✅ feta el 16/09/2026 | Copiar-hi els binaris |
| ~~Crear el compte de servei~~ ✅ `AGRIENERGIA\sapsistemes` | Escriure-hi `appsettings.Production.json` |
| Donar-li *Log on as a batch job* | Provar la cadena de punta a punta |
| Donar accés a la carpeta a `sapsistemes` **i** a `ohijazo`, i RDP a `ohijazo` | |
| **Registrar la tasca** (punt 4), amb admin i amb `sapsistemes` | |

**Registrar la tasca és seu i no es negocia**: `Register-ScheduledTask -User <un altre compte>` demana
drets d'administrador local, i fer-ho nosaltres voldria dir tenir admin en aquella màquina i la
contrasenya de `sapsistemes` a les mans. Qui **crea** la tasca i qui la **executa** són coses
independents — la tasca es guarda el seu principal a dins—, així que no en perdem res.

⚠️ **La carpeta no s'ha de compartir per xarxa.** Ni `\\ae01saprdp\...` ni cap altre recurs: hi ha un
fitxer amb credencials de SAP i de SQL. S'hi entra per RDP i els fitxers s'estiren des de dins.

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

Des d'una sessió de RDP a `AE01SAPRDP`, amb `ohijazo`. **La carpeta ja existeix** (la va crear
Sistemes el 16/09/2026), així que no cal crear-la ni cal PowerShell elevada — només permís de
modificació sobre la carpeta:

```powershell
Copy-Item "\\tomatera\Farinera\ohijazo\GAPI07_Analitza\publish\*" C:\Apps\SapB1AnalitzaSync -Recurse -Force
```

Els 81 MB s'estiren **des de dins de la màquina**: `\\tomatera` és accessible des d'allà i així no
cal compartir la carpeta destí.

La publicació és **autocontinguda**: no cal instal·lar el runtime de .NET 8 al servidor.

Per regenerar-la, des de l'equip de desenvolupament:

```
dotnet publish P:\GAPI07_Analitza\src\SapB1AnalitzaSync.Worker -c Release -r win-x64 --self-contained true -o P:\GAPI07_Analitza\publish
```

## 2. El compte que executa la tasca

És **`AGRIENERGIA\sapsistemes`**, el compte que va donar Sistemes el 16/09/2026. No és el teu, que
era el requisit; sí que sembla que el comparteixen amb altres tasques seves de SAP en aquella
màquina.

Ha de poder:

- Sortir a `192.168.11.238:50000` (Service Layer, HTTPS)
- Sortir a `192.168.11.238:1433` (SQL Server)
- Tenir el dret *Log on as a batch job* a `AE01SAPRDP` — **sense això la tasca es registra igual i
  falla cada nit amb `0x4`**

No li cal ser administrador ni tocar res més de la màquina.

**No s'ha de donar d'alta a SQL Server.** El Worker s'hi connecta amb `gapi07_worker`
(autenticació SQL, dins de l'`appsettings`); el compte de Windows només executa el procés. És una
confusió fàcil i val la pena aturar-la abans que algú creï un login que no cal.

⚠️ Com que el compte és de Sistemes, **si li roten la contrasenya la tasca s'atura silenciosament**:
des de fora només es veurà que Analitza es queda amb les dades d'ahir. Està demanat que ens ho
avisin; si el símptoma apareix sense cap altra explicació, aquesta és la primera hipòtesi.

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

La carpeta ha de quedar llegible **només pel compte de la tasca i pels administradors**. Sistemes la
van crear el 16/09/2026 ja amb aquesta ACL —`sapsistemes`, administradors locals i administrador de
domini—, o sigui que **normalment no cal tancar res**: només verificar-ho.

```powershell
icacls C:\Apps\SapB1AnalitzaSync
```

No hi ha d'aparèixer `Users` ni `Everyone`. Si hi surten (herència de `C:\Apps` que no es veiés des
de la seva banda), cal demanar-los que ho arreglin — `/inheritance:r` demana ser-ne propietari o
administrador:

```powershell
icacls C:\Apps\SapB1AnalitzaSync /inheritance:r
icacls C:\Apps\SapB1AnalitzaSync /grant:r "AGRIENERGIA\sapsistemes:(OI)(CI)(RX)"
icacls C:\Apps\SapB1AnalitzaSync /grant:r "Administrators:(OI)(CI)(F)"
icacls C:\Apps\SapB1AnalitzaSync /grant:r "SYSTEM:(OI)(CI)(F)"
```

## 4. La tasca programada — **la registra Sistemes**

Queda aquí per si l'han de tornar a fer, i perquè les comandes exactes són les que se'ls van passar
a l'annex del correu del 07/09/2026. **No l'executem nosaltres**: demana admin local.

**Es registra l'última**, quan els binaris i l'`appsettings.Production.json` ja hi són. Si es dona
d'alta abans, cada nit a les 02:45 falla amb *file not found* i genera soroll d'alertes en una
màquina que no és nostra. Per això se'ls va demanar que **la creïn desactivada** i l'activin quan
avisem.

```powershell
$acc = "AGRIENERGIA\sapsistemes"
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

## 5. Provar-la

⚠️ **Llançar `SapB1AnalitzaSync.Worker.exe --once` a mà des de la sessió d'`ohijazo` no substitueix
aquesta prova.** Correria amb un altre compte, i el que s'ha de validar és justament que
`sapsistemes` arriba a `AE01SAPSQL` pels dos ports i pot escriure a `sap_raw`. Cal llançar **la
tasca**: o ho fem nosaltres si ens donen permís sobre aquella tasca, o la llancen ells i ens diuen el
`LastTaskResult`.

```powershell
Start-ScheduledTask -TaskName "GAPI07 Refresca sap_raw"
Get-ScheduledTaskInfo -TaskName "GAPI07 Refresca sap_raw" | Format-List TaskName, LastRunTime, LastTaskResult
```

`LastTaskResult` ha de ser `0`. Qualsevol altra cosa vol dir que no ha anat bé:

| Codi | Què vol dir |
|---|---|
| 0 | Correcte |
| 1 | El cicle ha fallat: mira el log de la consola |
| 3 | Falta configuració: l'`appsettings.json` encara té els placeholders |
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

Canviar `CompanyDb` a `DB_FARINERA_PROD` a l'`appsettings.json` del servidor. No cal reiniciar res:
la tasca el rellegeix a cada execució.

I recorda abaixar `cfg.settings.LINES_MIN_RATIO` aquell dia: la SAP productiva arrenca sense
històric d'albarans i el recompte caurà a propòsit, cosa que el check `lines_collapsed` bloquejaria.
