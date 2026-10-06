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
| **GAPI07_Analitza** (aquest) | ✅ **`proceso`** des del 05/10/2026 | **02:45, ~20 s.** L'únic amb finestra fixa i curta | ✅ **Sí**, a `DisposeAsync` |
| **GAPI03_CRM** | user-secrets | **cada hora** (`IncrementalInterval: 01:00:00`) + reconciliació a les **03:00** | ⚠️ Sí, però **només en aturar el servei** |
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
per projecte:

- **GAPI03 va passar a cada hora el 18/09/2026** (abans, cada 15 minuts). Això el treu de la
  categoria de «sempre en sessió», però **encara no el fa compartible**, per una raó que no es veu
  a la configuració. Veure el quadre de sota.
- **`preparacioComandesVenda` i `ActualitzadorPreus` poden córrer en qualsevol moment**, així que no
  es pot assegurar res: ni entre ells ni respecte del nocturn.

> ### Per què «cada hora» encara no és suficient
>
> A GAPI03 el client de Service Layer és un **`AddSingleton`** dins d'un `while` permanent: viu tota
> la vida del procés i el seu `Logout` no s'executa **fins que s'atura el servei**. La sessió es
> renova sola als 29 minuts.
>
> Amb cicles horaris, això vol dir **mitja hora ocupada i mitja lliure**: es fa login, la sessió mor
> per inactivitat als 30 minuts, i es torna a entrar al cicle següent. És una millora real respecte
> de cada quart d'hora, on no s'alliberava mai.
>
> **Però la finestra ocupada es mou.** El bucle calcula `wait = interval - elapsed` des de
> l'arrencada, no des de l'hora en punt: si el servei es reinicia a les 02:20, els cicles passen a
> ser :20 i la mitja hora ocupada tapa les nostres 02:45. Això és «probable», no «assegurat».
>
> **El que ho faria determinista és petit**: que GAPI03 tanqui sessió **en acabar cada cicle** i no
> només en aturar-se. GAPI07 ho té de franc perquè és un procés `--once` que arrenca, sincronitza i
> mor. Amb aquell canvi, tots dos retindrien la llicència només mentre treballen i **podrien
> compartir compte de debò**: nosaltres a les 02:45 durant 20 s, ells a l'hora en punt, i la
> reconciliació de les 03:00 quinze minuts després que haguem plegat.

O sigui que, **tal com està tot avui**, calen tres o quatre comptes:

| Llicència | Per a qui |
|---|---|
| 1 | **GAPI07** — nocturn, 20 s, allibera en acabar |
| 2 | **GAPI03_CRM** — horari, però reté mitja hora amb finestra que es mou |
| 3 | **preparacioComandesVendaSAP** |
| 4 | **ActualitzadorPreusSap** |

**I es poden baixar a tres amb un canvi de codi petit a GAPI03**: que tanqui sessió en acabar cada
cicle. Llavors GAPI07 i GAPI03 comparteixen el compte nocturn sense que sigui una aposta, i queden
els dos interactius, que sí que són irreductibles perquè poden córrer a qualsevol hora.

**Si només se'n pot aconseguir un**, ha de ser per a GAPI07: és l'únic que corre **desatès i de
nit**. Si falla no hi ha ningú al davant, i el que publica al matí ho llegeix directament Analitza;
els altres tres els fa servir una persona que veuria l'error a la pantalla.

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

## ✅ El primer pas, fet el 05/10/2026: GAPI07 va amb `proceso`

**El salt de zero a un ja està fet, i no ha costat cap llicència.** `proceso` és el compte que el
partner va crear per a processos no concurrents, la contrasenya és la mateixa que la d'`OHijazo` i el
canvi va ser una sola clau als dos llocs del punt 2 de sota.

Verificat pel camí real: `--once` **a `AE02SAPRDP`**, amb la configuració de producció, surt amb `0`,
al log hi diu `usuari=proceso` i les **nou entitats** de `sap_raw.sync_state` queden segellades.

✅ **I el 06/10/2026 en Carles tanca la pregunta de qui més el fa servir: ningú.**

> El GAPI01 (integració amb financials) **no utilitza Service Layer**.
> El GAPI09 (Integració amb CyC) **no s'ha desenvolupat encara**.

O sigui que el compte que es deia «nocturno» perquè el compartien dos processos **avui no el comparteix
ningú**, i GAPI07 el té per ell sol. La pregunta de si les sessions se solapaven queda sense objecte, i
el «probable» passa a «assegurat» sense haver de mesurar res.

⚠️ **Però es tornarà a obrir, i val la pena deixar-ho escrit ara**: GAPI09 **està per fer**. El dia que
es desenvolupi, si li donen aquest mateix compte, la pregunta torna —i la resposta ja la sabem: ha de
fer **`Logout`** en acabar cada cicle i **no pot treballar dins de la finestra de les 02:45**. Si no es
pot assegurar cap de les dues coses, necessita compte propi. Qui ho desenvolupi no ho sabrà si no ho
troba escrit.

⚠️ **I el que NO arregla:** `OHijazo` segueix als altres tres projectes, amb la mateixa contrasenya de
4 caràcters. El dia que canviï o marxi, s'aturen tots tres.

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
| `C:\Apps\SapB1AnalitzaSync\appsettings.Production.json` a `AE02SAPRDP` | `ServiceLayer:UserName` i `:Password` |
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

1. ~~**Quan corren GAPI01 i GAPI09**, que segons el partner ja comparteixen `proceso nocturno`.~~
   ✅ **Contestat el 06/10/2026: cap dels dos el fa servir.** GAPI01 no va per Service Layer i GAPI09
   encara no s'ha desenvolupat. El compte és nostre de fet. ⏳ Es reobre el dia que es faci GAPI09.
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
