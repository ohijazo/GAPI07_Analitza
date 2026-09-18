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
| **GAPI07_Analitza** (aquest) | `OHijazo` | **02:45, ~20 s.** L'únic amb finestra fixa i curta | ✅ **Sí**, a `DisposeAsync` |
| **GAPI03_CRM** | user-secrets | **cada 15 min**, tot el dia, + reconciliació a les **03:00** | ❓ |
| **preparacioComandesVendaSAP** | `OHijazo` | **en qualsevol moment** | ❓ |
| **ActualitzadorPreusSap** | `OHijazo` | **en qualsevol moment** | ✅ Sí, i amb test que ho vigila |

**Quatre processos, tots sobre el mateix usuari nominal.**

Fora de l'inventari:

- **VBA TRANSPORTISTES** (`ActualitzarSAP_SL.bas`): d'un sol ús, per a una migració de dades. Corre a
  mà des d'Excel i amb les credencials de qui l'executa. No necessita compte de servei.
- **`GAP001`** (`P:\SAP\GAP001_scripts`): no és projecte de l'Oscar, queda descartat. Val la pena
  saber que **sondeja cada 120 segons** amb `OHijazo`: mentre corri, aquell usuari està permanentment
  en sessió i no pot compartir llicència amb res.

## La conclusió que en surt: quatre, no dos

L'excepció d'en Carles demana **poder assegurar** que dos processos no coincideixen. Mirat projecte
per projecte, **gairebé cap parella ho compleix**:

- **GAPI03 no és nocturn**: sincronitza **cada 15 minuts** tot el dia. Com `GAP001`, està
  permanentment en sessió i **no pot compartir amb ningú per definició**. La seva reconciliació de les
  03:00 cau a quinze minuts de la nostra, que és justament on es trobarien si ho intentéssim.
- **`preparacioComandesVenda` i `ActualitzadorPreus` poden córrer en qualsevol moment**, així que no
  es pot assegurar res: ni entre ells ni respecte del nocturn.

O sigui que el repartiment honest és **un usuari per procés**, que era la recomanació del partner des
del principi:

| Llicència | Per a qui |
|---|---|
| 1 | **GAPI07** — nocturn, 20 s, amb Logout |
| 2 | **GAPI03_CRM** — permanent, cada 15 min |
| 3 | **preparacioComandesVendaSAP** |
| 4 | **ActualitzadorPreusSap** |

**Si només se'n poden aconseguir menys**, la parella menys dolenta és **GAPI07 + ActualitzadorPreus**:
el segon allibera la sessió de seguida i a les 02:45 no l'està fent servir ningú. És l'única
combinació on la no-coincidència és gairebé una certesa en comptes d'una esperança.

**Però el salt que importa no és de dos a quatre, és de zero a un.** Avui tot corre amb `OHijazo`, un
usuari **nominal d'una persona**: el dia que canviï de contrasenya o no hi sigui, s'aturen quatre
processos alhora i ningú relacionarà les coses. Qualsevol compte indirecte dedicat ja és una millora
estricta, i GAPI07 és el que primer l'hauria de rebre: és l'únic que corre desatès de nit.

**El salt que importa no és d'un a dos, és de zero a un.** Avui tot corre amb `OHijazo`, un usuari
**nominal d'una persona**: el dia que canviï de contrasenya o no hi sigui, s'aturen cinc processos
alhora i ningú sabrà per què. Qualsevol compte indirecte dedicat ja és una millora estricta.

⚠️ **No n'hi ha prou amb no solapar-se: cal marge.** Dos `Login` del mateix usuari amb pocs segons de
diferència poden fallar amb `Invalid login credential` per *throttling* del pool de sessions (Regla
02). Si es comparteix compte, separar els processos mitja hora, no un minut.

## El pla: treure `OHijazo` de tot arreu

L'objectiu no és optimitzar llicències, és **que cap procés desatès corri amb l'usuari d'una
persona**. Quan hi hagi el compte o comptes nous:

**0. Demanar-ne quatre, i si no pot ser, un per a GAPI07.** És l'únic que corre **desatès i de nit**:
si falla, no hi ha ningú al davant, i el que es publica al matí ho llegeix Analitza. Els altres tres
els fa servir una persona que veurà l'error a la pantalla.

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
