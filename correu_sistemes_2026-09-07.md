# Correu a Sistemes — 07/09/2026, continuació del fil del 15/06/2026

**Per a:** Sistemes
**Assumpte:** RE: Integració Analitza CM amb SAP B1 — reprenc els punts pendents i n'afegeixo un de nou

*(El text per enviar comença a "Hola". Al final hi ha una nota interna que NO s'envia.)*

---

Hola,

Reprenc el fil de juny. Des de llavors han passat dues coses: la integració ha canviat de disseny
—per exigència de SAP, i a millor— i la data de posada en marxa, el **2 de novembre**, ja la tenim a
vuit setmanes.

**El que ha canviat.** Al juny les dades es llegien de les taules de SAP directament per SQL. Això
SAP no ho suporta i ens exposava a un problema de llicenciament, així que ara es llegeixen per l'API
oficial (Service Layer). Per a vosaltres això té una sola conseqüència, però és la que motiva la
petició nova: hi ha un procés petit que ha de córrer en algun lloc, i aquest lloc **no pot ser el
servidor de SAP**. És el punt 8.

Repasso els vostres set punts amb el que ha canviat. **El que us demano és el 1-2, el 3, el 6 i el
8**; el 4, 5 i 7 són informatius.

Us agrairia que, encara que no ho pugueu fer tot ara, em digueu **qui ho porta i amb quina data**.
A partir d'aquí he de planificar amb Analitza, i el 2 de novembre no admet una primera prova.

## 1 i 2 — VPN i port 1433 per a Analitza

Aquí només cal que ho activeu: em vau dir *"només m'ho heu de dir i li habilito l'accés"*. **Us ho
dic: activeu-lo.**

Ja tinc el que us faltava per la meva banda. Les seves IP de sortida són **88.99.249.95** i
**85.85.181.85**, i entenc de la vostra resposta que, com que entren per VPN, un cop dins cauen al
rang `192.168.254.x` i des d'allà arriben a `AE01SAPSQL:1433`. Si és així, no cal obrir res cap a
fora.

| | |
|---|---|
| **Qui** | Analitza CM |
| **On** | `AE01SAPSQL`, base de dades `IntercanviSAP`, port 1433 |
| **Quan** | Un minut al dia, cap a les 05:00 |
| **Amb quin usuari** | `analitza_ro`, login SQL. Ja creat |

El compte només veu **vuit taules** d'aquesta base de dades intermèdia nostra; té `DENY CONNECT` a
les bases de dades de SAP i no hi arriba de cap manera. La contrasenya la passo jo directament a
Analitza per un canal a part.

**El que necessito de vosaltres:** que m'envieu l'endpoint de VPN i les credencials que els he de
fer arribar, o que els les feu arribar vosaltres i m'ho digueu.

Per què insisteixo amb això primer: el seu director tècnic m'ha escrit que **per a ells és el punt
crític**. Fins que no s'hi connectin no poden comprovar que les dades els arriben bé, i això s'ha
d'haver provat *abans* del novembre.

## 3 — Backup de `IntercanviSAP`

Aquí he de rectificar el que us vaig dir al juny. Us deia que una pèrdua puntual no era greu perquè
tot es regenera cada nit des de SAP. **Ha deixat de ser cert per a una taula.**

Per no trencar l'històric d'Analitza, la base de dades guarda ara una taula petita
(`cfg.client_ship_no`) amb la numeració de les adreces de cada client. Es fixa el primer dia i **no
es pot tornar a calcular**: si es perd, Analitza veu desaparèixer ubicacions de clients i néixer-ne
de noves, i enganxa l'històric de compres d'una adreça a una altra. És el tipus d'error que no fa
saltar cap alarma i que es descobreix mesos després.

Dues coses, doncs:

- **Sí a l'oferta del pla de backup intern.** Un FULL diari d'`IntercanviSAP` n'hi ha prou. Si voleu
  que el configuri jo i vosaltres només reviseu on van els fitxers, també em va bé.
- **Confirmeu-me cada quan es fa la còpia de la màquina virtual i quants dies en guardeu**, per saber
  quant podríem perdre en el pitjor cas.

## 4 — Finestres de manteniment (informatiu, però ha canviat)

Segueix vigent i **ara són dos planificadors en dues màquines**:

| Quan | On | Què |
|---|---|---|
| 02:45 | `AE01SAPRDP` | El procés nou que llegeix SAP. ~20 segons |
| 03:00 | `AE01SAPSQL` | El job `Analitza_ETL_Daily` de sempre |

La finestra a evitar passa a ser **de 02:45 a 04:30 a totes dues màquines**.

## 5 — Monitoratge (informatiu)

La consulta és la mateixa que us vaig passar. Dos matisos:

- A part de `SUCCESS`, l'estat pot ser `BLOCKED` (les validacions han trobat alguna cosa) o
  `ABORTED_STALE_MIRROR` (les dades de SAP no s'han refrescat). Tots dos volen dir que **no s'ha
  publicat res** i que Analitza es queda amb les dades d'ahir, que és el comportament correcte.
- **Fins que el punt 8 no estigui fet, el job acaba cada nit amb `ABORTED_STALE_MIRROR`.** Si ho
  veieu, no és una avaria: és que la peça que llegeix SAP encara no està instal·lada enlloc.

## 6 — Correu d'alertes: responc la vostra pregunta

Preguntàveu amb quin compte ho volia fer i si es podia fer amb un *secret id*. **No es pot.** El
Database Mail del SQL Server és un component antic i només parla **SMTP AUTH bàsica** (usuari i
contrasenya). No suporta OAuth, ni client secret, ni certificat. No és una preferència meva, és
l'únic que sap fer.

Per ordre de preferència:

1. **Un mailbox de servei**, tipus `sql-alerts@agrienergia.com`, amb *Authenticated SMTP* habilitat i
   una App Password. Les alertes surten d'una adreça institucional i el dia que jo no hi sigui segueix
   funcionant. Si això necessita l'aprovació d'algú, digueu-m'ho i la demano jo.
2. **Un relay SMTP intern** que accepti enviaments sense autenticació des de la subxarxa de
   servidors, si en teniu. Encara més net: cap contrasenya enlloc.
3. **Provisionalment, el meu compte** amb una App Password. Es pot canviar més endavant sense aturar
   res, però preferiria no començar així.

Té conseqüència pràctica avui: el procés nocturn falla cada nit —correctament, perquè encara no està
desplegat— i **l'avís tampoc surt**. Si algun dia falla de veritat, no se n'assabentarà ningú.

## 7 — Pas a productiva (informatiu, i ha canviat)

Al juny us deia que seria un `UPDATE` a la base de dades intermèdia. Amb el disseny nou **ja no ho
és**: és un canvi al fitxer de configuració del procés del punt 8, a `AE01SAPRDP`. Un motiu més per
tenir-hi accés abans i no el mateix dia del canvi.

## 8 — NOU: accés a `AE01SAPRDP` per instal·lar-hi un procés programat

Aquesta és la petició nova, i és la que surt del canvi de disseny.

`AE01SAPRDP` (192.168.11.239). Un executable que corre **un cop al dia a les 02:45**, triga uns vint
segons, llegeix de SAP i escriu a `IntercanviSAP`. No exposa cap servei ni obre cap port.

**El que us demano és el compte i l'accés, no que ho instal·leu vosaltres.** No és copiar quatre
fitxers: cal escriure-hi la configuració amb credencials reals, comprovar que des d'aquella màquina
s'arriba a SAP i a SQL, i executar-lo un cop per veure que la cadena funciona. Fet per correu, cada
detall és una anada i tornada; fet per mi amb accés, és una tarda.

| Vosaltres | Jo |
|---|---|
| Crear el compte de servei i donar-li *Log on as a batch job* | Instal·lar-hi els fitxers i configurar-lo |
| Obrir la sortida als dos ports de sota | Registrar la tasca programada i provar-la |
| Donar-me accés a `C:\Apps\SapB1AnalitzaSync` | Els permisos dins de SQL Server |

**No cal que em feu administrador de la màquina**, i entenc que és millor que no. Amb accés a aquella
carpeta i poder-hi executar la tasca n'hi ha prou; el compte i els seus permisos els seguiu
controlant vosaltres.

El compte ha de ser **dedicat i no administrador**, i li cal:

- El dret ***Log on as a batch job*** a `AE01SAPRDP`.
- Sortida des de `192.168.11.239` cap a `AE01SAPSQL`, **ports 50000/TCP** (l'API de SAP, HTTPS) i
  **1433/TCP** (SQL Server). Confirmeu-me que `AE01SAPSQL` és `192.168.11.238`, que és on respon
  l'API, per no demanar-vos una regla cap a la màquina equivocada.

**Sé que a `AE01SAPRDP` hi ha webservices de col·laboradors externs.** Per això la configuració no va
a variables d'entorn de màquina —qualsevol procés de la màquina les llegiria— sinó a un fitxer al
costat de l'executable, amb els permisos NTFS tancats al compte de la tasca. El detall exacte va a
l'annex adjunt.

**Si `AE01SAPRDP` no us va bé**, digueu-me on i ho poso allà: l'únic requisit és que la màquina
arribi a SAP i a SQL per aquests dos ports. També podria anar al mateix `AE01SAPSQL`, però preferiria
no afegir-hi binaris d'aplicació, que a partir del novembre és la màquina més crítica que tenim. I si
preferiu instal·lar-lo vosaltres, l'annex porta les comandes exactes i no cal que em doneu accés.

Per si serveix per valorar el risc en una màquina compartida, aquest procés: no obre cap port ni
exposa cap servei; **no escriu mai a SAP** (llegeix amb un usuari de només lectura); no toca res fora
de `C:\Apps\SapB1AnalitzaSync`; no necessita instal·lar cap runtime; i si falla, falla sol i les
dades es queden com estaven.

## Una última, de menys prioritat

`DB_FARINERA_TEST` gairebé no té documents, i això limita el que podem validar abans del novembre. Si
es pogués refrescar amb una còpia de la productiva, la qualitat de la validació canviaria molt.
**Sabeu qui ho hauria de fer, vosaltres o Seidor?** Si és cosa d'ells, ho demano jo i no us hi fico.

Gràcies per endavant.

Salutacions,
Oscar Hijazo
Agrienergia
ohijazo@agrienergia.com

---

# Annex — el detall tècnic del punt 8

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

---

> **Nota interna (no enviar).**
>
> - **Un sol document, sense adjunts.** L'annex del punt 8 va dins d'aquest mateix fitxer, i és
>   l'única còpia que en queda: `peticio_sistemes_worker.md` ja només hi apunta. **No adjuntar
>   `peticio_sistemes_worker.docx`**: la seva carta va quedar superada el 07/09 i el seu punt 2
>   contradiu aquest correu (parlava d'obrir 1433 a les IP públiques).
> - La seva resposta del 15/06 **desmunta la pregunta de les IPs** que hi havia a l'esborrany
>   anterior: `192.168.254.x` és el rang de clients de la VPN, no l'adreça d'`AE01SAPSQL`. Per tant
>   **no cal obrir 1433 cap a internet** per a `88.99.249.95` / `85.85.181.85`: entren per VPN. Cal
>   corregir-ho a `docs/memoria_projecte.md` (§9, Bloc A), a `peticio_sistemes_worker.md` i a
>   `docs/runbook_cutover.md`, que parlen d'"obrir ruta a les IPs d'Analitza".
> - El punt 1 **ja el van concedir el 15/06** ("només m'ho heu de dir i li habilito l'accés"). Si
>   torna a quedar aturat, això és el que s'ha de citar en escalar-ho.
> - El punt 6 fa tres mesos que espera **una resposta meva**, no d'ells. Si es tornen a endarrerir,
>   convé recordar que la pilota estava aquí.
> - El punt 3 rectifica el que se'ls va dir al juny: `cfg.client_ship_no` no es pot regenerar
>   (01/09/2026, arran de la resposta de l'Adrià sobre les adreces).
