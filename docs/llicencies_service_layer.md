# Qui es connecta a Service Layer, i quantes llicències calen

Inventari fet el **18/09/2026** escombrant `P:` sencera. Va de tots els projectes, no només de
GAPI07, perquè la pregunta de les llicències no es pot contestar mirant-ne un de sol.

## La regla, segons el partner

En Carles (SEIDOR), el 18/09/2026:

> La recomanació és utilitzar **un usuari per cada procés**. No obstant, si hi ha dos processos que
> podem assegurar que **no s'executen de forma concurrent**, poden utilitzar una mateixa llicència.
> Per aquest motiu es va crear l'usuari «proceso nocturno».

## ⚠️ La unitat no és el temps d'execució, és el temps de sessió

Això canvia el càlcul i és el que fa que l'excepció sigui més estreta del que sembla.

**Cada `POST /Login` ocupa la llicència 30 minuts** (`SessionTimeout`), tret que el procés faci
`POST /Logout` en acabar. Un procés que treballa 20 segons i no tanca sessió **reté la llicència
mitja hora igualment**. Documentat i verificat a `P:\ActualitzadorPreusSap\docs\acces_i_llicencies.md`.

Per tant, «no s'executen alhora» s'ha de llegir com **«les seves sessions no se solapen»**, i la
pregunta a fer a cada projecte no és quan corre sinó **si fa Logout**.

## L'inventari

| Projecte | Usuari de SL avui | Quan corre | Fa `Logout`? |
|---|---|---|---|
| **GAPI07_Analitza** (aquest) | `OHijazo` | 02:45, ~20 s | ✅ **Sí**, a `DisposeAsync` |
| **GAPI03_CRM** | user-secrets (`<technical-user>` a l'appsettings) | per confirmar | ❓ |
| **preparacioComandesVendaSAP** | `OHijazo` | interactiu, horari laboral | ❓ |
| **ActualitzadorPreusSap** | `OHijazo` | interactiu + fil de fons | ✅ Sí, i amb test que ho vigila |
| **VBA TRANSPORTISTES** (`ActualitzarSAP_SL.bas`) | llegeix `SAP_SL_USER` | manual, des d'Excel | ❓ |

**Quatre o cinc processos, tots sobre el mateix usuari nominal.**

> **`GAP001` queda fora d'aquest inventari** (18/09/2026): no és un projecte de l'Oscar. Val la pena
> saber que existeix i que sondeja **cada 120 segons** amb `OHijazo`: mentre corri, aquell usuari està
> permanentment en sessió i **no pot compartir llicència amb res**. Si algun dia es posa en producció,
> el repartiment de sota s'ha de refer i li cal un usuari propi per definició.

## La conclusió que en surt

Tret de `GAP001`, **cap dels processos que porto és permanent**: o són nocturns i puntuals, o són
interactius d'horari laboral. Això fa que l'excepció d'en Carles sigui aplicable de debò, i el
repartiment mínim queda en **dos** usuaris indirectes:

| Llicència | Per a qui | Per què |
|---|---|---|
| 1 — **nocturna** | **GAPI07** + GAPI03, si també és nocturn | Puntuals, amb Logout, separats mitja hora |
| 2 — **interactiva** | `preparacioComandesVenda` + `ActualitzadorPreus` + el VBA | Horari laboral, i es trepitgen entre ells però no amb els nocturns |

Dos usuaris indirectes en comptes d'un. Si es vol la recomanació del partner —un per procés— en calen
quatre o cinc.

**El salt que importa no és d'un a dos, és de zero a un.** Avui tot corre amb `OHijazo`, un usuari
**nominal d'una persona**: el dia que canviï de contrasenya o no hi sigui, s'aturen cinc processos
alhora i ningú sabrà per què. Qualsevol compte indirecte dedicat ja és una millora estricta.

⚠️ **No n'hi ha prou amb no solapar-se: cal marge.** Dos `Login` del mateix usuari amb pocs segons de
diferència poden fallar amb `Invalid login credential` per *throttling* del pool de sessions (Regla
02). Si es comparteix compte, separar els processos mitja hora, no un minut.

## El pla: treure `OHijazo` de tot arreu

L'objectiu no és optimitzar llicències, és **que cap procés desatès corri amb l'usuari d'una
persona**. Quan hi hagi el compte o comptes nous:

**1. Demanar-los amb els permisos justos.** GAPI07 **només llegeix**, i les entitats són poques:
`BusinessPartners`, `Items`, `ItemGroups`, `SalesPersons`, `WizardPaymentMethods`, `DeliveryNotes`,
`Returns`, `CreditNotes`, `Invoices`. Un compte sense permís d'escriptura tanca la Regla 01 per
construcció, no per confiança. Els altres projectes sí que escriuen i necessiten més.

**2. El canvi a GAPI07 és de dues línies i no toca codi:**

| On | Què |
|---|---|
| `C:\Apps\SapB1AnalitzaSync\appsettings.Production.json` a `AE01SAPRDP` | `ServiceLayer:UserName` i `:Password` |
| Els user-secrets de l'equip de desenvolupament | Els mateixos dos |

**3. Verificar-ho pel camí real**, no pel que s'hi assembla:

```powershell
cd C:\Apps\SapB1AnalitzaSync
.\SapB1AnalitzaSync.Worker.exe --once
```

Al log hi ha de sortir el nom nou a `usuari=`, i `sap_raw.sync_state` ha de quedar segellat a
l'hora d'ara. Que el `--once` acabi en `0` no n'hi ha prou: cal veure la dada escrita.

**4. Repetir-ho als altres quatre projectes**, i deixar `OHijazo` sense cap procés al darrere.

⚠️ **Compte el dia del canvi**: si es fa entre les 02:45 i les 03:00, el Worker pot agafar la
configuració a mitges. Fer-ho de dia, i llançar l'`--once` a mà tot seguit.

## El que s'ha de confirmar

1. **Quan corren GAPI01 i GAPI09**, que segons el partner ja comparteixen `proceso nocturno`.
2. **Si `GAP001`, `GAPI03`, `preparacioComandesVenda` i el VBA fan `Logout`.** Si no en fan, retenen
   mitja hora cadascun i el repartiment de dalt no aguanta.
3. **El consum indirecte d'Analitza CM**, que és una pregunta d'una altra mena i més cara: el
   licenciament indirecte va de **qui consumeix les dades**, no de quants processos s'hi connecten.
   Veure `docs/memoria_projecte.md`, secció de llicenciament.

## ⚠️ Trobat de passada, i s'ha de corregir

`P:\SAP\GAP001_scripts\gap001_config.json` porta **en clar**:

- La contrasenya de Service Layer d'`OHijazo`.
- Un **`client_secret` d'OAuth2** d'una aplicació d'Azure AD, per a l'enviament de correu.

Tots dos en un fitxer d'una unitat de xarxa compartida. **El `client_secret` s'ha de rotar** al
portal d'Azure, perquè s'ha de considerar compromès. I aquell fitxer hauria de seguir la Regla 03
com la resta: res de credencials al disc, ni a `P:`.
