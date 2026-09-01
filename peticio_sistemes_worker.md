# Petició a Sistemes — GAPI07, les tres coses que ens falten

**Projecte:** GAPI07 — Integració SAP B1 → Analitza CM
**Sol·licitant:** Oscar Hijazo — ohijazo@agrienergia.com
**Data límit:** ha d'estar operatiu i **provat** força abans del **2 de novembre de 2026**, que és el
dia del canvi a SAP.

---

Hola,

Continuo el fil d'agost. Aleshores vau contestar set punts i en van quedar dos pendents d'informació
meva: la IP d'Analitza i el compte de correu per a les alertes. Ja tinc la primera, i afegeixo la
tercera peça que ens falta per poder provar tot el circuit.

Van juntes perquè són el mateix bloc: **sense les tres, la integració no es pot provar d'extrem a
extrem, i el 2 de novembre no admet una primera prova**.

---

## 1. Accés a `AE01SAPRDP` per instal·lar-hi un procés programat

`AE01SAPRDP` (192.168.11.239). Un executable que corre **una vegada al dia a les 02:45**, triga uns
vint segons, llegeix de SAP i escriu a una base de dades. No exposa cap servei ni obre cap port.

**El que us demano és el compte i l'accés, no que ho instal·leu vosaltres.** No és una còpia de
fitxers i llestos: cal escriure-hi un fitxer de configuració amb credencials reals, comprovar que
des d'aquella màquina s'arriba a SAP i a SQL, i executar-lo un cop per veure que la cadena funciona.
Fet per correu, cada detall és una anada i tornada; fet per mi amb accés, és una tarda.

| Vosaltres | Jo |
|---|---|
| Crear el compte de servei i donar-li *Log on as a batch job* | Instal·lar-hi els fitxers i configurar-lo |
| Obrir la sortida als dos ports de sota | Registrar la tasca programada i provar-la |
| Donar-me accés a `C:\Apps\SapB1AnalitzaSync` | Els permisos dins de SQL Server |

**No cal que em feu administrador de la màquina**, i entenc que és millor que no. Amb accés a aquella
carpeta i poder-hi executar la tasca n'hi ha prou. El compte i els seus permisos els seguiu
controlant vosaltres.

**El compte de servei** ha de ser dedicat i **no administrador**. Li cal:

- El dret ***Log on as a batch job*** a `AE01SAPRDP`.
- Sortida de xarxa des de `192.168.11.239` cap a `AE01SAPSQL`, **ports 50000/TCP** (SAP Service
  Layer, HTTPS) i **1433/TCP** (SQL Server).

  *Un aclariment que us demano:* a l'agost us referíeu a `AE01SAPSQL` com a `192.168.254.x`, i el
  Service Layer que fem servir respon a `192.168.11.238`. Confirmeu-me quina és la bona, que no
  vull demanar-vos una regla cap a la màquina equivocada.

**Sé que a `AE01SAPRDP` hi ha webservices de col·laboradors externs.** Per això la configuració no va
a variables d'entorn de màquina —qualsevol procés de la màquina les llegiria— sinó a un fitxer al
costat de l'executable, amb els permisos NTFS tancats al compte de la tasca. El detall exacte, a
l'annex.

## 2. Ruta per a Analitza cap a `AE01SAPSQL`

Aquesta és la que us devia des de l'agost. Ja tinc les IPs:

| | |
|---|---|
| **Origen** | `88.99.249.95` i `85.85.181.85` (Analitza CM) |
| **Destinació** | `AE01SAPSQL`, port **1433/TCP** |
| **Usuari** | `analitza_ro`, SQL auth. Ja creat, només lectura, i amb `DENY CONNECT` a les bases de dades de SAP |
| **Quan** | Es connecten un minut al dia, cap a les 05:00 |

El seu CTO m'ha dit que per a ells **és dels punts crítics**: fins que no s'hi puguin connectar no
poden validar que les dades els arriben bé, i això és el que hauria d'estar provat abans del
novembre, no després.

El compte només veu vuit taules d'una base de dades intermèdia nostra. **No té cap accés a SAP.**

## 3. Un compte SMTP per a les alertes

Ho vam deixar obert a l'agost. Us ho recordo perquè ara ja té conseqüència: el procés nocturn falla
cada nit —correctament, perquè encara no està desplegat— i **la notificació també falla**, o sigui
que si algun dia falla de veritat no se n'assabentarà ningú.

Com us vaig comentar, el Database Mail del SQL Server només suporta **SMTP AUTH bàsica**; no suporta
autenticació moderna. Les opcions eren:

1. **(Preferida)** Un mailbox de servei tipus `sql-alerts@agrienergia.com`, amb SMTP AUTH habilitat i
   una App Password. Les alertes surten d'una adreça institucional i serveixen per a altres serveis
   interns en el futur.
2. Un relay SMTP intern anònim, si en teniu algun que accepti relay des de la subxarxa de servidors.
   Encara més net.
3. Provisionalment, el meu compte amb una App Password, i ho canvio més endavant sense downtime.

Si l'opció 1 necessita aprovació d'algú, digueu-m'ho i la demano jo.

---

## Si alguna cosa no us va bé

- Si `AE01SAPRDP` no és el lloc, digueu-me on i ho poso allà. L'únic requisit és que la màquina
  arribi a SAP i a SQL pels dos ports. També pot anar al mateix `AE01SAPSQL`, encara que preferiria
  no afegir-hi binaris d'aplicació: a partir del novembre és la màquina més crítica que tenim.
- Si preferiu instal·lar-lo vosaltres, l'annex porta les comandes exactes i no cal que em doneu
  accés. Només us demanaria de fer-ho aviat, per tenir marge de provar-ho.

## El que aquest procés NO fa

Per si serveix per valorar el risc a una màquina compartida:

- No obre cap port ni exposa cap servei. Només fa peticions de sortida.
- **No escriu mai a SAP.** Llegeix per Service Layer amb un usuari de només lectura.
- No toca res fora de `C:\Apps\SapB1AnalitzaSync`.
- No cal instal·lar cap runtime: la publicació és autocontinguda.
- Si falla, falla sol. El job de SQL Server ho detecta i deixa les dades com estaven.

Gràcies,

Oscar Hijazo
Agrienergia
ohijazo@agrienergia.com

---

# Annex — el detall tècnic del punt 1

Per si ho voleu fer vosaltres, o per revisar què faré jo.

| | |
|---|---|
| Executable | `SapB1AnalitzaSync.Worker.exe --once` |
| Carpeta destí | `C:\Apps\SapB1AnalitzaSync` |
| Origen dels fitxers | `\\tomatera\Farinera\ohijazo\GAPI07_Analitza\publish` (81 MB) |
| Horari | Diari, 02:45 |
| Durada típica | ~20 segons |
| Runtime | Cap: la publicació és autocontinguda |

## Carpeta i fitxers

```powershell
New-Item -ItemType Directory -Force C:\Apps\SapB1AnalitzaSync
Copy-Item "\\tomatera\Farinera\ohijazo\GAPI07_Analitza\publish\*" C:\Apps\SapB1AnalitzaSync -Recurse -Force
```

## Permisos de la carpeta

És la part que importa: hi haurà un fitxer de configuració amb credencials de SAP i de SQL, i ha de
quedar llegible **només** pel compte de la tasca i pels administradors.

```powershell
icacls C:\Apps\SapB1AnalitzaSync /inheritance:r
icacls C:\Apps\SapB1AnalitzaSync /grant:r "Administrators:(OI)(CI)(F)"
icacls C:\Apps\SapB1AnalitzaSync /grant:r "SYSTEM:(OI)(CI)(F)"
icacls C:\Apps\SapB1AnalitzaSync /grant:r "<compte-de-la-tasca>:(OI)(CI)(RX)"
```

Després, a `icacls C:\Apps\SapB1AnalitzaSync` no hi ha d'aparèixer ni `Users` ni `Everyone`.

## Tasca programada

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

## Comprovació

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

Avisant-me, ho verifico jo des de la base de dades i confirmo que la cadena funciona de punta a punta.
