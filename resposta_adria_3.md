# Resposta a l'Adrià (Analitza CM) — adreces fetes, un avís sobre la data mínima, i xifres per a l'Olga

**Per a:** adria@analitza.com
**CC:** lbutinya@agrienergia.com
**Assumpte:** RE: Integració Analitza CM — nou origen SAP B1

*(El text per enviar comença a "Hola Adrià". Al final hi ha una nota interna que NO s'envia.)*

---

Hola Adrià,

Gràcies, amb la teva resposta he pogut tancar tres coses i n'he trobat una que val la pena que
miris.

## Fet: les adreces ja no es renumeren

El que expliques canvia la gravetat del problema i per això l'he fet de seguida. Jo pensava que
renumerar deixava un forat a l'històric; pel que dius, el que fa és **enganxar l'històric d'una
adreça a una altra**. Un client vostre veuria compres que no ha fet mai, i no hi hauria cap xifra
descarrejada que ho delatés.

Ja està implementat i provat. El número de cada adreça queda fixat el primer dia i **no es torna a
calcular**; les altes noves agafen el següent número lliure del client, i **un número alliberat per
un esborrat no es reutilitza mai**. O sigui que el cas que et preocupa —que una adreça nova hereti
l'històric d'una de morta— ja no pot passar per aquesta via.

Ho he comprovat amb els vostres propis identificadors: la primera execució reprodueix exactament els
5.651 que teniu avui, cap desapareix i cap en neix. Després, esborrant l'adreça del mig d'un client,
la següent es queda al seu número en comptes de pujar al de la germana esborrada.

Per la teva pregunta de si esborrem adreces sovint: no ho sé del cert, i és justament per això.
Preferia no dependre de si passa poc.

## Fet, i sense feina: els altres tres punts

- **Els preus en euros.** Perfecte, els enviem en euros. Nosaltres no hem de canviar res; només cal
  que el `/100` marxi del teu costat el mateix dia 2.
- **`RAÓ SOCIAL` i `ACTIU`.** Els tens a `est_clients.name` i `est_clients.active`, ja poblats. No
  toco res.
- **Els filtres de client.** Es queden on són.

## L'avís: la data mínima

Aquesta és la que et volia comentar. Dius que la vostra càrrega reemplaça a partir de la data mínima
que us passem, i que com que serà el 2 de novembre no esborrareu mai res de l'antiga. **Mentre la
data mínima no es mogui cap enrere, d'acord.** El que em preocupa és què passa si es mou.

Mirant la vostra SQL, filtreu els últims 90 dies:

```sql
and DATEDIFF(DAY, date, GETDATE()) <= 90
```

Si un dia us arriba una línia datada abans del 2 de novembre però dins d'aquesta finestra, la data
mínima retrocedeix, i llavors reemplaceu des d'aquella data amb només el que us hem enviat
nosaltres. **El tram de KAIS que hi hagi entremig el perdríeu.**

Hi ha dues maneres que passi, i cap és rebuscada:

1. Que la nostra SAP productiva arrenqui amb albarans anteriors al tall. Ho estic verificant, però
   encara no en tinc confirmació.
2. Que algú posti un albarà **amb data endarrerida** després del tall: entrar el dia 10 de novembre
   un albarà datat el 20 d'octubre. Això és operativa normal d'un ERP i passarà tard o d'hora.

Ho he tapat pel nostre costat: si un dia la data més antiga que publicaríem és anterior a la del dia
abans, la càrrega s'atura i no us arriba res, en comptes de publicar-la i que la ingeriu. Preferim
quedar-nos amb les dades d'ahir un dia que fer-vos perdre històric.

**El que et demano:** que hi afegiu un sòcol al vostre costat mentre duri la transició, alguna cosa
com `AND date >= '2026-11-02'`. Amb això el problema desapareix del tot, encara que a nosaltres se'ns
escapi alguna cosa. A partir del febrer ja no cal, perquè tot el que caigui dins dels 90 dies serà
posterior al tall.

I sí, et confirmo el que preguntaves: **el tall és sec**. L'1 de novembre s'insereix a l'antiga i el
2 a la nova, i no hi ha cap dia amb els dos sistemes rebent les mateixes operacions.

## Famílies: hi havia una tercera opció, i ara tinc xifres

Repassant-ho amb les teves captures he vist que et vaig plantejar malament la tria. El camp que ja us
alimenta la SUBFAMILIA és `U_SEISubFamCialCat`, i els seus valors quadren amb la vostra llista de
subfamílies. Però **al costat n'hi ha un altre, `U_SEIFamCialCat`, que és el nivell FAMÍLIA**, i no
l'estàvem mirant.

Els seus valors són, literalment, les vostres 12 famílies: TRADICIONALS, MOULIN DE COLAGNE,
ESPECIFICA, GRANEL, ALTRES CEREALS, ECOLÒGIQUES, CAN TRULL, INTEGRALS, KM0, PIZZA, ALTRES
ELABORACIONS i PROVES1. Més SUBPRODUCTE, que vosaltres no teniu.

O sigui que les opcions reals són:

| | Famílies | Cobertura |
|---|---|---|
| **A. Els grups d'article de SAP** | 110 | tots els articles classificats |
| **B. La família comercial de SAP** | 12, les vostres | **782 de 980 articles actius sense família** |

L'opció A va en contra del que em recomanes: 110 famílies són moltes més de les ~25 que dius, i les
alertes de la fitxa de client quedarien diluïdes. L'opció B manté el significat i els noms, però ara
mateix vuit de cada deu articles actius cauria a la fila sense assignació —la que avui us val 195.233 €.

Hi ha un camí C: **triar B i que algú d'aquí classifiqui els articles que falten a SAP abans del 2 de
novembre.** Us puc passar la llista exacta d'articles actius sense família perquè es reparteixi.

Ho passo a l'Olga, com dius. Digue'm si prefereixes que li escrigui jo amb aquestes xifres al davant
o si ho porteu vosaltres.

De propina, una cosa petita: a SAP conviuen `KM0` i `KM 0` —amb un espai— com si fossin dues famílies
diferents. La segona té un sol article. Ho corregim aquí abans del tall.

## El cost i la connexió

- **El cost d'octubre**: d'acord, queda amb el cost del moment i al desembre fem la càrrega puntual
  des de la base de dades antiga. Ho preparo amb temps.
- **La connexió**: hi estic al damunt. És el punt que ens bloqueja a tots dos i us el confirmo tan
  bon punt tingui la ruta.

Salutacions,
Oscar Hijazo
Agrienergia
ohijazo@agrienergia.com

---

> **Nota interna (no enviar).**
>
> **Fet i commitejat l'01/09/2026:**
> - `cfg.client_ship_no` + `etl.sp_assign_client_ship_no`; `etl.vw_client_ship` passa a llegir el
>   número en comptes de calcular-lo. Provat: 0 ids canvien en desplegar-ho.
> - Check `history_floor` (CRITICAL, atura el swap) i els checks `ship_no_missing` i
>   `ship_address_changed`.
> - `U_SEIFamCialCat` afegit al `$select` i a la sonda, amb cobertura sobre el cens i sobre els
>   actius.
>
> **El que depèn de tercers i no s'ha mogut:** desplegar el Worker i obrir la ruta (Sistemes), la
> llicència de l'usuari tècnic de SAP, i si la productiva arrenca amb històric d'albarans
> (consultors). Aquest últim ara té dues conseqüències, no una: el cost d'octubre **i** la data
> mínima. Si arrenca amb històric, la seva càrrega li esborra el tram corresponent de KAIS.
>
> **Els 782 articles actius sense família** són una feina de classificació que no és nostra, i té
> data. Si l'Olga tria l'opció B sense que això es faci, el dia 2 vuit de cada deu articles li surten
> sense família i el problema es veurà a la seva aplicació, no a la nostra.
>
> **Pendent de decidir amb l'Olga**, no amb l'Adrià. Val la pena escriure-li directament amb la taula
> de dalt: la pregunta «110 o 12» sense la xifra de cobertura al costat no es pot contestar bé.
>
> **`cfg.client_ship_no` ha d'entrar al backup.** No es pot regenerar.
