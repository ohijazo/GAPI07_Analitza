# Desplegament del Worker a AE02SAPRDP

El Worker corre com a **tasca programada** al servidor d'aplicacions
`AE02SAPRDP` (192.168.11.136, Windows Server), no al servidor de SQL.

**Aquesta màquina allotja webservices de col·laboradors externs.** Això condiciona com s'hi posen
les credencials: res de variables d'entorn de màquina, que qualsevol procés de la màquina pot
llegir.

## 🔴 Estat a 25/09/2026: el cicle nocturn NO corre

**El Worker ha canviat de `AE01SAPRDP` (192.168.11.239) a `AE02SAPRDP` (192.168.11.136)**, i
`sap_raw` no es refresca sol des de la nit del **21 al 22/09/2026**. Tres nits seguides
d'`ABORTED_STALE_MIRROR` (runs 149, 151 i 152; l'última amb 48 hores de mirall) i tres correus
d'alerta a les 03:00.

**Això no és una avaria de l'ETL.** És la guarda de frescor de `sp_run_all` fent la seva feina:
`dbo.est_*` es queda amb dades bones d'un altre dia en comptes de publicar-ne de mig carregades.
**No s'ha d'apujar `MIRROR_MAX_AGE_HOURS` per fer callar l'avís.**

L'estat de les dues màquines està **sense comprovar**: totes dues responen (`.239` i `.136`, ports
445 i 3389), però `C$` està denegat des de fora —i és així a propòsit— i cap d'elles es pot
inspeccionar sense entrar-hi per RDP.

⚠️ **El parany que sobreviu a qualsevol causa:** si l'`appsettings.Production.json` es copia de la
màquina vella a la nova, hi va `CompanyDb: DB_FARINERA_TEST`, que està **OFFLINE des del 22/09**
(la companyia de test ara és `DB_FARIN_TEST`). El `Login` respon `Invalid login credential`, que
apunta a la contrasenya i no ho és. La guarda d'arrencada de `Program.cs` només detecta buit o
placeholder, **no** una companyia existent però equivocada.

### Què comprovar, i amb què

Llança **`deploy\Check-WorkerHost.ps1`** per RDP a **les dues** màquines. No escriu res, no toca SAP,
no imprimeix cap contrasenya i funciona amb un compte normal:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Apps\SapB1AnalitzaSync\Check-WorkerHost.ps1
```

Comprova els binaris, el `CompanyDb`, l'ACL, la tasca i el seu `LastTaskResult`, la sortida cap a
`192.168.11.238` pels ports 50000 i 1433, i el dret *Log on as a batch job*. A `AE01SAPRDP` et dirà
si la tasca vella hi segueix registrada.

**Les quatre coses que un canvi de màquina trenca i que no deixen rastre enlloc**, per ordre de
probabilitat:

1. **El dret *Log on as a batch job*.** A `AE01SAPRDP` estava concedit per **directiva local, no per
   GPO**: en una màquina nova no hi és. La tasca es registra igual i falla cada nit amb `0x4`.
2. **La sortida cap a `192.168.11.238`, ports 50000 i 1433.** El camí verificat ho era des de
   `.239`; des de `.136` **no l'ha comprovat ningú**.
3. **L'`appsettings.Production.json`, que s'ha de recrear a mà.** Els binaris poden viatjar, la
   configuració no: ni per Teams, ni per correu, ni per cap recurs compartit.
4. **La tasca vella de `AE01SAPRDP`**, si encara hi és: o es desactiva, o les dues màquines es
   trepitgen.

✅ **De SQL Server no s'ha de tocar res.** `gapi07_worker` és un login SQL i no està lligat a cap
host; les mencions a `AE01SAPRDP` de `sql/security/*` són comentaris. Comprovat el 24/09/2026.

## El que es va aprendre a AE01SAPRDP, i que segueix valent

Res d'això caduca amb el canvi de màquina; és el que s'ha de tornar a fer bé a la nova.

Les dues proves no valen igual: `--once` llançat a mà amb `ohijazo` diu que els binaris i la
configuració són bons, però **no diu res del compte que correrà de nit**. La que compta és **la
tasca**, llançada pel seu principal, verificada contra `sync_state`.

⚠️ El dret *Log on as a batch job* de `sapsistema` estava per **directiva local**, no per GPO. Si un
refresc de polítiques el tomba, no peta res: la tasca deixa de córrer, el job de les 03:00 avorta
amb `ABORTED_STALE_MIRROR` i Analitza es queda amb les dades d'ahir. Es veu a `audit.etl_runs`; la
resposta és avisar Sistemes, **no** apujar `MIRROR_MAX_AGE_HOURS`.

<details>
<summary>Estat anterior: en producció a AE01SAPRDP del 16/09 al 21/09/2026</summary>

El Worker va córrer a `AE01SAPRDP` per la tasca **`GAPI07 Refresca sap_raw`** (arrel, diària
**02:45**, `AGRIENERGIA\sapsistema`). Provat el 16/09 a les 15:20:48: `LastTaskResult = 0` **i** les
nou entitats de `sap_raw.sync_state` segellades a la mateixa hora. La nit del 16 al 17 va córrer
sola a les 02:45:02, i l'últim cicle nocturn bo va ser el run 147, el 22/09 a les 03:00.

</details>

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

## Qui fa què

La màquina no és nostra i no hi som administradors. El repartiment és el que es va acordar amb
Sistemes el 16/09/2026, i **a `AE02SAPRDP` s'ha de tornar a fer sencer**: res del que es va tancar a
la màquina vella viatja amb els binaris.

| Sistemes | Nosaltres |
|---|---|
| Crear `C:\Apps\SapB1AnalitzaSync` amb l'ACL correcta | Copiar-hi els binaris |
| Confirmar el compte de servei (`AGRIENERGIA\sapsistema`) | Escriure-hi `appsettings.Production.json` **a mà** |
| Donar accés a la carpeta i RDP a `ohijazo` | Provar la cadena amb la tasca, un cop registrada |
| Donar a `sapsistema` *Log on as a batch job* **en aquesta màquina** | |
| **Registrar la tasca** (punt 4), amb admin i amb `sapsistema` | |
| **Desactivar la tasca vella de `AE01SAPRDP`**, si encara hi és | |

⚠️ **La sortida cap a `192.168.11.238` pels ports 50000 i 1433 està sense comprovar des de
`192.168.11.136`.** El que es va verificar el 16/09/2026 amb `Test-NetConnection` va ser el camí des
de `192.168.11.239`, i és per això que la regla de firewall demanada el 07/09 no va caldre. **Aquell
resultat no es pot heretar**: si a la màquina nova la sortida no està oberta, el Worker falla cada
nit i el símptoma des de SQL és, un cop més, només que el mirall es fa vell. Ho comprova el punt 6
de `Check-WorkerHost.ps1`.

**Registrar la tasca és seu i no es negocia**: `Register-ScheduledTask -User <un altre compte>` demana
drets d'administrador local, i fer-ho nosaltres voldria dir tenir admin en aquella màquina i la
contrasenya de `sapsistema` a les mans. Qui **crea** la tasca i qui la **executa** són coses
independents — la tasca es guarda el seu principal a dins—, així que no en perdem res.

⚠️ **La carpeta no s'ha de compartir per xarxa.** Ni `\\ae02saprdp\...` ni cap altre recurs: hi ha un
fitxer amb credencials de SAP i de SQL. S'hi entra per RDP i els fitxers s'estiren des de dins.

---

## Per què no és un pas del job de SQL Agent

SQL Agent no pot llançar un procés en una altra màquina. Són dos planificadors que no es parlen: la
tasca a `AE02SAPRDP` a les **02:45** i el job a `AE01SAPSQL` a les **03:00**.

La garantia que l'ETL no transformi un mirall vell **no la dona l'ordre dels passos**, la dona la
guarda de frescor de `sp_run_all`: si `sap_raw.sync_state` té més de
`cfg.settings.MIRROR_MAX_AGE_HOURS` hores (6 per defecte), avorta amb `ABORTED_STALE_MIRROR` i
`dbo.est_*` es queda com estava.

No és teòric: el 26/08/2026, la primera vegada que es va provar, va detectar que el mirall tenia 24
hores i que les transformacions d'aquell matí anaven sobre dades del dia anterior.

---

## 1. Copiar els binaris

Des d'una sessió de RDP a `AE02SAPRDP`, amb `ohijazo`. **Comprova primer que la carpeta hi és i que
hi pots escriure**: a `AE01SAPRDP` la va crear Sistemes amb l'ACL bona, i a la màquina nova això
s'ha de tornar a demanar. Si hi és, no cal PowerShell elevada — només permís de modificació sobre
la carpeta:

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
- Tenir el dret *Log on as a batch job* a `AE02SAPRDP` — **sense això la tasca es registra igual i
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

**No l'escriguis a mà: fes-ho amb `Set-ProductionConfig.ps1`**, que es llança des de la màquina i
demana les contrasenyes interactivament, així no viatgen per cap canal.

```powershell
# Crear-lo de zero (demana les dues contrasenyes)
\\tomatera\Farinera\ohijazo\GAPI07_Analitza\deploy\Set-ProductionConfig.ps1 -SqlServer 192.168.11.238

# Només canviar la companyia, sense tocar les contrasenyes (p. ex. al cutover)
\\tomatera\Farinera\ohijazo\GAPI07_Analitza\deploy\Set-ProductionConfig.ps1 -FixCompanyDb DB_FARINERA_PROD
```

Fa tres coses que fer-ho a mà no fa: construeix la cadena de SQL amb `SqlConnectionStringBuilder`
—concatenar-la la trenca si la contrasenya porta `;` o `=`, i el símptoma és un `Login failed`
idèntic al d'una credencial dolenta—, **obre una connexió de debò a SQL abans d'escriure el fitxer**,
i fa còpia de seguretat de l'anterior. Es passa la **IP** i no `AE01SAPSQL` per no dependre de la
resolució de noms des d'aquella màquina, que és una cosa més que no s'ha comprovat.

El contingut que en surt, per si algun dia l'has de llegir:

```json
{
  "ServiceLayer": {
    "BaseUrl": "https://192.168.11.238:50000/b1s/v1/",
    "CompanyDb": "DB_FARIN_TEST",
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

### On mirar quan una nit falli: el log del Worker

Des del 06/10/2026 el Worker escriu **`C:\Apps\SapB1AnalitzaSync\logs\worker-AAAAMMDD.log`**: un
fitxer per dia, **30 dies** de retenció, segells en **UTC** i **UTF-8 amb BOM** perquè el
`Get-Content` de PowerShell 5.1 i el Notepad del servidor no el llegeixin com a ANSI. Es configura a
la secció `FileLog` (`Enabled`, `Directory`, `RetentionDays`).

Abans d'això la tasca de les 02:45 llençava la sortida i no quedava rastre de res — ni de **quin
usuari de Service Layer** s'havia fet servir.

```powershell
# L'ultima execucio, des de l'equip local
Invoke-Command -ComputerName AE02SAPRDP -ScriptBlock {
  Get-Content (Get-ChildItem 'C:\Apps\SapB1AnalitzaSync\logs\*.log' |
               Sort-Object LastWriteTime | Select-Object -Last 1).FullName -Tail 30
}
```

⚠️ **Si el fitxer no hi és, no vol dir que el Worker no hagi corregut.** El log **mai** fa petar el
cicle: si la carpeta no fos escrivible pel compte de la tasca, es queixa una vegada per la consola
—que ningú no veu— i continua refrescant el mirall. La vigilància bona segueix sent
`sap_raw.sync_state` i `audit.etl_runs`; el log serveix per saber **per què**, no per saber **si**.

### Canviar UNA clau sense RDP i sense tocar les contrasenyes

**`AE02SAPRDP` accepta WinRM per a `ohijazo`** (comprovat el 05/10/2026: `Test-WSMan` i
`Invoke-Command` funcionen; `AE01SAPRDP` denega tots dos). Per a un canvi d'un sol valor —l'usuari de
Service Layer, la companyia— això evita la sessió de RDP i, el que importa més, **evita haver de
tornar a teclejar cap contrasenya**: es reescriu només la clau i la resta del fitxer queda igual.

```powershell
# Llegir l'estat sense imprimir cap credencial
Invoke-Command -ComputerName AE02SAPRDP -ScriptBlock {
  $c = [System.IO.File]::ReadAllText('C:\Apps\SapB1AnalitzaSync\appsettings.Production.json')
  [pscustomobject]@{
    UserName  = ([regex]::Match($c,'"UserName"\s*:\s*"([^"]*)"')).Groups[1].Value
    CompanyDb = ([regex]::Match($c,'"CompanyDb"\s*:\s*"([^"]*)"')).Groups[1].Value
  }
}

# Canviar NOMES l'usuari de Service Layer
Invoke-Command -ComputerName AE02SAPRDP -ScriptBlock {
  $f = 'C:\Apps\SapB1AnalitzaSync\appsettings.Production.json'
  Copy-Item $f "$f.bak-<data>" -Force
  $n = [regex]::Replace([System.IO.File]::ReadAllText($f), '("UserName"\s*:\s*")[^"]*(")', '${1}proceso${2}')
  [System.IO.File]::WriteAllText($f, $n, (New-Object System.Text.UTF8Encoding($false)))
}
```

`UTF8Encoding($false)` és per no deixar-hi un BOM que no hi era. Tres coses obligatòries després:

1. **Validar que segueix sent JSON** (`ConvertFrom-Json`) i mirar que la mida no hagi ballat.
2. **Executar `--once` a la màquina** i comprovar que al log hi surt l'`usuari=` nou **i** que
   `sap_raw.sync_state` queda segellat a l'hora d'ara. El codi de sortida `0` sol no demostra res.
3. **Esborrar la còpia de seguretat**, que porta les credencials en clar.

⚠️ **No fer-ho entre les 02:45 i les 03:00**: el Worker podria agafar la configuració a mitges.

⚠️ **Si en aquella màquina hi has de llançar `--probe`, afegeix-hi també el bloc `Sync`.** El valor
que hereta de l'`appsettings.json` base és `P:\GAPI07_Analitza\docs\client_locations.csv`, i `P:` és
una unitat mapada de l'equip de l'Oscar: a `AE02SAPRDP` no existeix. La sonda **no peta** quan no
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
- `ABORTED_STALE_MIRROR` — la tasca de `AE02SAPRDP` no ha corregut. Mira-la abans de res, amb
  `Check-WorkerHost.ps1`.
- `BLOCKED` — la tasca sí que ha corregut, però els checks de qualitat han trobat alguna cosa i el
  swap s'ha avortat. Mira `audit.data_quality_warnings`.

---

## Al cutover (2 de novembre)

Canviar `CompanyDb` a `DB_FARINERA_PROD` a l'`appsettings.Production.json` del servidor. No cal
reiniciar res: la tasca el rellegeix a cada execució.

⚠️ **I buidar el checkpoint i les taules de documents del mirall**, que no és opcional:
`sap_raw.sync_state` no guarda de quina companyia ve cada cursor, i `sap_raw` arribaria al dia del
tall ple de dades de test. Els passos són al runbook, secció 2.1.

I recorda abaixar `cfg.settings.LINES_MIN_RATIO` aquell dia: la SAP productiva arrenca sense
històric d'albarans i el recompte caurà a propòsit, cosa que el check `lines_collapsed` bloquejaria.
