# Petició a Sistemes — GAPI07, les tres coses que ens falten

> ⚠️ **Superat pel 07/09/2026.** El correu que s'envia és
> **`correu_sistemes_2026-09-07.md`**, escrit com a continuació del fil del 15/06/2026 i punt per
> punt sobre la seva resposta. D'aquest document **només s'adjunta l'annex** (el detall tècnic de la
> instal·lació). La carta de dalt es conserva pel raonament del repartiment vosaltres/jo, que el
> correu nou reutilitza.
>
> El punt 2 d'aquesta carta **estava mal plantejat** i es corregeix més avall: Analitza entra per
> VPN, no cal obrir 1433 a cap IP pública.

**Projecte:** GAPI07 — Integració SAP B1 → Analitza CM
**Sol·licitant:** Oscar Hijazo — ohijazo@agrienergia.com
**Data límit:** ha d'estar operatiu i **provat** força abans del **2 de novembre de 2026**, que és el
dia del canvi a SAP.

---

Hola,

Continuo el fil del 15 de juny. Aleshores vau contestar set punts i en van quedar dos pendents
d'informació meva: l'accés d'Analitza i el compte de correu per a les alertes. Ja tinc el primer, i
afegeixo la tercera peça que ens falta per poder provar tot el circuit.

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

  *Confirmeu-me* que `AE01SAPSQL` és `192.168.11.238`, que és on respon el Service Layer, per no
  demanar-vos una regla cap a la màquina equivocada. (El `192.168.254.x` del vostre correu del juny
  és el rang de clients de la VPN, no aquesta màquina.)

**Sé que a `AE01SAPRDP` hi ha webservices de col·laboradors externs.** Per això la configuració no va
a variables d'entorn de màquina —qualsevol procés de la màquina les llegiria— sinó a un fitxer al
costat de l'executable, amb els permisos NTFS tancats al compte de la tasca. El detall exacte, a
l'annex.

## 2. Accés d'Analitza a `AE01SAPSQL`

Aquesta és la que us devia des del juny. **No és obrir cap port cap a fora**: el 15/06 ja em vau dir
que Analitza entra per VPN i que només ho havia de dir perquè li habilitéssiu l'accés. Doncs ho dic.

| | |
|---|---|
| **Com hi entren** | Per VPN, com ja feien amb KAIS. Un cop dins cauen al rang `192.168.254.x` |
| **Origen cap al concentrador** | `88.99.249.95` i `85.85.181.85` (Analitza CM) |
| **Destinació** | `AE01SAPSQL`, port **1433/TCP** |
| **Usuari** | `analitza_ro`, SQL auth. Ja creat, només lectura, i amb `DENY CONNECT` a les bases de dades de SAP |
| **Quan** | Es connecten un minut al dia, cap a les 05:00 |

El que necessito de vosaltres és **habilitar-los l'accés i passar-me l'endpoint i les credencials de
VPN** per fer-los-hi arribar (la contrasenya de SQL la passo jo per un canal a part).

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

# Annex tècnic — mogut

El detall de la instal·lació (carpeta, `icacls`, `Register-ScheduledTask` i la taula de codis
d'error) viu ara a **`correu_sistemes_2026-09-07.md`**, que és el document que s'envia, per no
mantenir-ne dues còpies. Si s'ha de tocar, es toca allà.
