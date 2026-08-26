# Petició a Sistemes — desplegar un procés programat a AE01SAPRDP

**Projecte:** GAPI07 — Integració SAP B1 → Analitza CM
**Sol·licitant:** Oscar Hijazo — ohijazo@agrienergia.com
**Servidor:** `AE01SAPRDP` (192.168.11.239, Windows Server)
**Quan:** al setembre. Ha d'estar operatiu i provat molt abans del **2 de novembre**.

---

## Què es demana, en curt

Un executable que ha de córrer **una vegada al dia a les 02:45** a `AE01SAPRDP`, com a tasca
programada. Triga uns vint segons. Llegeix de SAP i escriu a una base de dades; no exposa cap
servei, no obre cap port, no interactua amb ningú.

| | |
|---|---|
| Executable | `SapB1AnalitzaSync.Worker.exe --once` |
| Carpeta destí | `C:\Apps\SapB1AnalitzaSync` |
| Origen dels fitxers | `\\tomatera\Farinera\ohijazo\GAPI07_Analitza\publish` (81 MB) |
| Horari | Diari, 02:45 |
| Durada típica | ~20 segons |
| Runtime | Cap. La publicació és autocontinguda, no cal instal·lar .NET |

**Sé que a AE01SAPRDP hi ha webservices de col·laboradors externs**, i per això la petició inclou
tancar els permisos de la carpeta: hi haurà credencials en un fitxer de configuració i no han de ser
llegibles per la resta de processos de la màquina.

---

## Per què allà i no al servidor de SQL

El procés forma part de la càrrega nocturna que alimenta la plataforma d'anàlisi Analitza CM. La
transformació la fa un job de SQL Agent a `AE01SAPSQL` a les 03:00; aquest executable és el pas
previ, que porta les dades de SAP a una base de dades intermèdia.

Podria córrer al mateix `AE01SAPSQL`, però aquell servidor ja fa de base de dades, de SAP i de
Service Layer, i a partir del cutover de novembre serà la màquina més crítica que tenim. Preferim no
afegir-hi binaris d'aplicació.

---

## 1. Compte de servei

Necessitem un compte dedicat per executar la tasca. **No ha de ser administrador.** Li cal:

- El dret ***Log on as a batch job*** a `AE01SAPRDP`
- Sortida de xarxa des de `192.168.11.239` cap a `192.168.11.238`:
  - **port 50000/TCP** (SAP Service Layer, HTTPS)
  - **port 1433/TCP** (SQL Server)

Digueu-me quin compte feu servir i m'encarrego jo dels permisos dins de SQL Server: només ha de poder
escriure a un esquema concret de la base de dades `IntercanviSAP`, res més.

## 2. Carpeta i fitxers

```powershell
New-Item -ItemType Directory -Force C:\Apps\SapB1AnalitzaSync
Copy-Item "\\tomatera\Farinera\ohijazo\GAPI07_Analitza\publish\*" C:\Apps\SapB1AnalitzaSync -Recurse -Force
```

## 3. Permisos de la carpeta

Aquesta part és la que importa, perquè a la carpeta hi haurà un fitxer de configuració amb
credencials de SAP i de SQL. Ha de quedar llegible **només** pel compte de la tasca i pels
administradors:

```powershell
icacls C:\Apps\SapB1AnalitzaSync /inheritance:r
icacls C:\Apps\SapB1AnalitzaSync /grant:r "Administrators:(OI)(CI)(F)"
icacls C:\Apps\SapB1AnalitzaSync /grant:r "SYSTEM:(OI)(CI)(F)"
icacls C:\Apps\SapB1AnalitzaSync /grant:r "<compte-de-la-tasca>:(OI)(CI)(RX)"
```

Després de fer-ho, a `icacls C:\Apps\SapB1AnalitzaSync` no hi ha d'aparèixer ni `Users` ni
`Everyone`.

**Les credencials us les passo jo per canal segur**, o si preferiu me les deixeu posar a mi un cop
tingueu la carpeta feta. Com us vagi millor.

## 4. Tasca programada

```powershell
$acc = "<compte-de-la-tasca>"
$act = New-ScheduledTaskAction -Execute "C:\Apps\SapB1AnalitzaSync\SapB1AnalitzaSync.Worker.exe" `
                               -Argument "--once" `
                               -WorkingDirectory "C:\Apps\SapB1AnalitzaSync"
$trg = New-ScheduledTaskTrigger -Daily -At 02:45
$set = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
                                    -StartWhenAvailable -DontStopOnIdleEnd
Register-ScheduledTask -TaskName "GAPI07 Refresca sap_raw" `
    -Action $act -Trigger $trg -Settings $set -User $acc -RunLevel Limited
```

Ha de córrer **tant si hi ha sessió iniciada com si no**.

## 5. Comprovació

```powershell
Start-ScheduledTask -TaskName "GAPI07 Refresca sap_raw"
Get-ScheduledTaskInfo -TaskName "GAPI07 Refresca sap_raw" | Format-List LastRunTime, LastTaskResult
```

`LastTaskResult` ha de ser `0`. Si surt una altra cosa:

| Codi | Què vol dir |
|---|---|
| 1 | Ha arrencat però ha fallat: sol ser xarxa o credencials |
| 3 | Falta la configuració, encara té els valors de plantilla |
| 2147942401 | No troba l'executable o el compte no hi té permisos |

Avisant-me, ho verifico jo des de la base de dades i confirmo que la cadena funciona de punta a
punta.

---

## Coses que NO fa

Per si serveix per valorar el risc a una màquina compartida:

- No obre cap port ni exposa cap servei. Només fa peticions de sortida.
- **No escriu mai a SAP.** Llegeix per Service Layer amb un usuari de només lectura.
- No toca res fora de `C:\Apps\SapB1AnalitzaSync`.
- No necessita instal·lar runtime ni cap component: la publicació és autocontinguda.
- Si falla, falla sol: el job de SQL Server ho detecta i deixa les dades com estaven.

## Si preferiu una altra ubicació

Si `AE01SAPRDP` no us va bé per política o per càrrega, digueu-m'ho i ho posem on em digueu — l'únic
requisit és que la màquina arribi a `192.168.11.238` pels ports 50000 i 1433. També pot anar al
mateix `AE01SAPSQL` si ho preferiu, encara que no és el que recomanaria.

---

Atentament,
Oscar Hijazo
Agrienergia
ohijazo@agrienergia.com
