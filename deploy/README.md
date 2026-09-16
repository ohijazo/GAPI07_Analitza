# Desplegament del Worker a AE01SAPRDP

El Worker corre com a **tasca programada** al servidor d'aplicacions
`AE01SAPRDP` (192.168.11.239, Windows Server), no al servidor de SQL.

**AE01SAPRDP allotja webservices de col·laboradors externs.** Això condiciona com s'hi posen les
credencials: res de variables d'entorn de màquina, que qualsevol procés de la màquina pot llegir.

## Estat: en producció des del 16/09/2026

El Worker corre a `AE01SAPRDP` per la tasca **`GAPI07 Refresca sap_raw`** (arrel, diària **02:45**,
`AGRIENERGIA\sapsistema`). Provat el mateix dia a les 15:20:48: `LastTaskResult = 0` **i** les nou
entitats de `sap_raw.sync_state` segellades a la mateixa hora.

Les dues proves no valen igual, i és la lliçó del dia: `--once` llançat a mà amb `ohijazo` diu que
els binaris i la configuració són bons, però **no diu res del compte que correrà de nit**. La que
compta és la tasca, llançada pel seu principal, verificada contra `sync_state`.

⚠️ El dret *Log on as a batch job* de `sapsistema` està per **directiva local**, no per GPO. Si un
refresc de polítiques el tomba, no petarà res: la tasca deixarà de córrer, el job de les 03:00
avortarà amb `ABORTED_STALE_MIRROR` i Analitza es quedarà amb les dades d'ahir. Es veu a
`audit.etl_runs`; la resposta és avisar Sistemes, **no** apujar `MIRROR_MAX_AGE_HOURS`.

### Com es vigila, si no veiem la tasca

`ohijazo` **no pot llegir la tasca**: la va crear un administrador i el descriptor de seguretat no li
dona accés. `Get-ScheduledTask -TaskName "GAPI07 Refresca sap_raw"` respon *no se encontraron
objetos*, tot i que enumerar-ne 156 sí que pot. O sigui que `LastTaskResult` l'hem de demanar a
Sistemes.

No cal: **es vigila des de la base de dades, que és un senyal millor.** Un `0` només diu que el
procés va acabar; això diu que va escriure:

```sql
SELECT entity, updated_at, DATEDIFF(MINUTE, updated_at, SYSUTCDATETIME()) AS fa_minuts
FROM   IntercanviSAP.sap_raw.sync_state ORDER BY updated_at DESC;
```

Les nou entitats han de portar l'hora de l'última execució. Compte que `updated_at` és **UTC**: la
prova del 16/09 va córrer a les 15:20 locals i hi consta com a 13:21.

## Qui fa què (acordat amb Sistemes el 16/09/2026)

La màquina no és nostra i no hi som administradors. El repartiment és aquest, i explica per què
alguns passos d'aquest document ja no els executem nosaltres:

| Sistemes | Nosaltres |
|---|---|
| ~~Crear `C:\Apps\SapB1AnalitzaSync`~~ ✅ 16/09/2026 | ~~Copiar-hi els binaris~~ ✅ 16/09/2026 |
| ~~Crear el compte de servei~~ ✅ `AGRIENERGIA\sapsistema` | ~~Escriure-hi `appsettings.Production.json`~~ ✅ 16/09/2026 |
| ~~Donar accés a la carpeta i RDP a `ohijazo`~~ ✅ 16/09/2026 | Provar la cadena amb la tasca, un cop registrada |
| Donar a `sapsistema` *Log on as a batch job* | |
| **Registrar la tasca** (punt 4), amb admin i amb `sapsistema` | |

La sortida de `192.168.11.239` cap a `192.168.11.238` pels ports **50000 i 1433 ja funcionava**
—comprovat amb `Test-NetConnection` des de la màquina el 16/09/2026—, o sigui que la regla de
firewall que es va demanar el 07/09 no calia.

**Registrar la tasca és seu i no es negocia**: `Register-ScheduledTask -User <un altre compte>` demana
drets d'administrador local, i fer-ho nosaltres voldria dir tenir admin en aquella màquina i la
contrasenya de `sapsistema` a les mans. Qui **crea** la tasca i qui la **executa** són coses
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

⚠️ **Mira la data del `.exe` abans de copiar-lo.** La carpeta `publish` és una fotografia manual i no
es regenera sola: el 16/09/2026 encara hi havia el binari del 26/08, anterior a la família comercial
i a la inversió del `U_SEICodienllac`. Desplegar-lo no hauria petat — hauria omplert `sap_raw` amb
dades incorrectes, que és pitjor. Compara-la amb l'últim commit que toca `src\`:

```powershell
(Get-Item P:\GAPI07_Analitza\publish\SapB1AnalitzaSync.Worker.exe).LastWriteTime
git -C P:\GAPI07_Analitza log -1 --format=%ci -- src
```

Si el commit és més nou, torna a publicar abans de copiar res.

La publicació és **autocontinguda**: no cal instal·lar el runtime de .NET 8 al servidor.

Per regenerar-la, des de l'equip de desenvolupament:

```
dotnet publish P:\GAPI07_Analitza\src\SapB1AnalitzaSync.Worker -c Release -r win-x64 --self-contained true -o P:\GAPI07_Analitza\publish
```

## 2. El compte que executa la tasca

És **`AGRIENERGIA\sapsistema`** (*SAP Sistema*), i és **dedicat**: `net user sapsistema /domain` el
16/09/2026 el donava amb la contrasenya posada el **15/09** i *«Última sesión iniciada: Nunca»*, o
sigui creat expressament per això. No és administrador —cap grup local, i com a global només
*Usuarios del dominio*— i **la contrasenya no caduca**.

⚠️ Per Teams el van anomenar `sapsistemes`, amb essa. **El compte real és `sapsistema`**, i
`sapsistemes` no existeix al domini. La diferència d'una lletra entre el principal de la tasca i
l'ACL de la carpeta donaria *Access Denied* cada nit a les 02:45 sense que res digués per què.

Ha de poder:

- Sortir a `192.168.11.238:50000` (Service Layer, HTTPS)
- Sortir a `192.168.11.238:1433` (SQL Server)
- Tenir el dret *Log on as a batch job* a `AE01SAPRDP` — **sense això la tasca es registra igual i
  falla cada nit amb `0x4`**

No li cal ser administrador ni tocar res més de la màquina.

**No s'ha de donar d'alta a SQL Server.** El Worker s'hi connecta amb `gapi07_worker`
(autenticació SQL, dins de l'`appsettings`); el compte de Windows només executa el procés. És una
confusió fàcil i val la pena aturar-la abans que algú creï un login que no cal.

⚠️ El compte és de Sistemes i la contrasenya no la tenim. **No caduca**, així que el risc no és que
s'aturi sola; el risc és que algú la roti a mà. Si passés, la tasca deixaria de funcionar i des de
fora només es veuria que Analitza es queda amb les dades d'ahir. Està demanat que ens ho avisin, i si
el símptoma apareix sense cap altra explicació, aquesta és la primera hipòtesi.

⚠️ **Compte amb el dret *Log on as a batch job* si el gestiona una GPO.** Registrar la tasca sol
concedir-lo automàticament a la màquina, però si aquell dret està definit per directiva de domini, el
següent refresc de polítiques el torna a treure i **la tasca comença a fallar dies després**, sense
que hagi canviat res de visible. Si és el cas, ha d'anar a la GPO, no posat a mà en local.

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

⚠️ **Si en aquella màquina hi has de llançar `--probe`, afegeix-hi també el bloc `Sync`.** El valor
que hereta de l'`appsettings.json` base és `P:\GAPI07_Analitza\docs\client_locations.csv`, i `P:` és
una unitat mapada de l'equip de l'Oscar: a `AE01SAPRDP` no existeix. La sonda **no peta** quan no
troba el fitxer, escriu `Encaix amb el cens de KAIS: OMES` i continua — o sigui que la comprovació
més important d'abans del tall (*cap client sense `U_FCCodiKais`*) sortiria verda sense haver
comprovat res. Copia el CSV a la màquina i apunta-l'hi:

```json
  "Sync": { "KaisClientExportPath": "C:\\Apps\\SapB1AnalitzaSync\\client_locations.csv" }
```

Per al cicle nocturn (`--once`) és indiferent: aquest camí només el fa servir la sonda.

La carpeta ha de quedar llegible **només pel compte de la tasca i pels administradors**. Sistemes la
van crear el 16/09/2026 ja amb aquesta ACL —`sapsistema`, administradors locals i administrador de
domini—, o sigui que **normalment no cal tancar res**: només verificar-ho.

```powershell
icacls C:\Apps\SapB1AnalitzaSync
```

No hi ha d'aparèixer `Users` ni `Everyone`. Si hi surten (herència de `C:\Apps` que no es veiés des
de la seva banda), cal demanar-los que ho arreglin — `/inheritance:r` demana ser-ne propietari o
administrador:

```powershell
icacls C:\Apps\SapB1AnalitzaSync /inheritance:r
icacls C:\Apps\SapB1AnalitzaSync /grant:r "AGRIENERGIA\sapsistema:(OI)(CI)(RX)"
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
$acc = "AGRIENERGIA\sapsistema"
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
`sapsistema` arriba a `AE01SAPSQL` pels dos ports i pot escriure a `sap_raw`. Cal llançar **la
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
| 4 | Falta *Log on as a batch job* al compte de la tasca |
| 2147942401 | No troba l'executable, o el compte no hi té permisos |

### Errors de SQL Server que ja han passat

| Error | Símptoma | Causa i solució |
|---|---|---|
| **916** | `The server principal "gapi07_worker" is not able to access the database "master"` | El login té un usuari amb `DENY CONNECT` a `master`. Allà el `DENY` no protegeix res i **impedeix autenticar-se**, encara que la cadena demani `IntercanviSAP`. `DROP USER [gapi07_worker]` a `master`. Passat el 16/09/2026; `Create-WorkerUser.ps1` ja no el posa i el neteja si el troba |
| **18456** | `Login failed for user '<x>'`, **sense** anomenar cap base de dades | Credencial dolenta de debò. Si és 916 en canvi, la contrasenya és correcta i el que falla és el context de BD — no la busquis |

⚠️ Si has de connectar-te per PowerShell, **passa la contrasenya per `SqlCredential`**, no interpolada
a la cadena (`Password=$pwd;…`). Una contrasenya amb `;`, `=` o cometes trenca el parser del client i
el que veus és un `Login failed` que sembla una credencial dolenta sense ser-ho. Els tres scripts de
`sql/security/` ja ho fan així des del 16/09/2026.

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
