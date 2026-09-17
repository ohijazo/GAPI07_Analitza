# Resposta a l'Adrià (Analitza CM) — la connexió ja està oberta, adreces fetes, i xifres per a l'Olga

**Per a:** adria@analitza.com
**CC:** lbutinya@agrienergia.com
**Assumpte:** RE: Integració Analitza CM — nou origen SAP B1

*(El text per enviar comença a "Hola Adrià". Al final hi ha una nota interna que NO s'envia.)*

---

Hola Adrià,

Gràcies per la teva resposta. He pogut tancar tres coses, n'he trobat una que val la pena que
miris, i sobretot: **ja tens accés**.

## La connexió ja està oberta — i dues coses abans que la facis servir

Sistemes us van habilitar l'accés el **10 de setembre**. Entreu per VPN, igual que fèieu amb KAIS, i
d'allà a `AE01SAPSQL`, port 1433, base de dades `IntercanviSAP`. Les credencials de la VPN i l'URL
són les que ja teniu: aquí no ha canviat res.

⚠️ **No carreguis res cap a producció encara.** Això apunta a la nostra SAP de **proves**, i a partir
d'aquesta setmana les taules es refresquen cada nit: hi veuràs dades que semblen bones i no ho són.
Són de l'entorn de test i et durien clients i imports que no existeixen — i amb codis que no són
tots els de KAIS, o sigui que te'ls ingeriria com a **clients nous**. Per validar la connexió i el
format, tot el que vulguis. El pas a la companyia real el faig jo el **2 de novembre** i t'aviso el
mateix dia.

⚠️ **I el compte de SQL ha canviat.** El 31 d'agost vaig rotar la contrasenya d'`analitza_ro` i vaig
acotar-li els permisos: ara és `SELECT` només sobre les vuit taules `est_*` (abans veia més coses de
les que li tocaven). Si ho proves amb la que tenies guardada, el que veuràs és un error de login que
**sembla un problema de xarxa**, i el diagnòstic se'n va cap a Sistemes durant dies. La contrasenya
nova **te la passo per un canal a part**, no per correu.

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

1. Que la nostra SAP productiva arrenqui amb albarans anteriors al tall. **Aquesta te la puc
   descartar**: ho diu el blueprint signat del projecte. No es migra històric documental —ni
   albarans, ni comandes, ni factures— i els albarans pendents de facturar es tanquen tots al
   sistema antic abans del tall.
2. Que algú posti un albarà **amb data endarrerida** després del tall: entrar el dia 10 de novembre
   un albarà datat el 20 d'octubre. Això és operativa normal d'un ERP i passarà tard o d'hora.
   Aquesta és la que queda oberta.

Ho he tapat pel nostre costat: si un dia la data més antiga que publicaríem és anterior a la del dia
abans, la càrrega s'atura i no us arriba res, en comptes de publicar-la i que la ingeriu. Preferim
quedar-nos amb les dades d'ahir un dia que fer-vos perdre històric.

**El que et demano:** que hi afegiu un sòcol al vostre costat mentre duri la transició, alguna cosa
com `AND date >= '2026-11-02'`. Amb això el problema desapareix del tot, encara que a nosaltres se'ns
escapi alguna cosa. A partir del febrer ja no cal, perquè tot el que caigui dins dels 90 dies serà
posterior al tall.

I sí, et confirmo el que preguntaves: **el tall és sec**. L'1 de novembre s'insereix a l'antiga i el
2 a la nova, i no hi ha cap dia amb els dos sistemes rebent les mateixes operacions.

## El dia 2: què fa cadascú

Com que ja tenim data i falten set setmanes, m'agradaria deixar per escrit qui toca què aquell dia.
Són dues coses i només una demana feina:

| | Qui | Què |
|---|---|---|
| **El `/100`** | Tu | Treure `product_price/100` i `product_cost/100` de la teva SQL. Nosaltres enviem euros des del primer dia |
| **El `discount`** | Ningú | **Es queda com està.** Seguiu fent `1-discount` i no toqueu res |

El del `discount` el dic expressament perquè no es toqui: vaig estar a punt de canviar-vos la
convenció i, mirant la vostra SQL, la que hi ha ara ja és la bona. Millor no moure el que funciona el
mateix dia que movem tota la resta.

El del `/100` és l'únic punt de tot el projecte que, si se'ns escapa, **no dona cap error**: els preus
et quedarien 100 vegades més petits, el `net_amount` seguiria quadrant, i ni les teves validacions ni
les meves ho veurien. Per això t'ho demano per escrit encara que ja m'ho hagis dit: amb un "confirmat"
en tinc prou.

## Famílies: mantenim les vostres 12, i ja no cal decidir res

Aquesta era la pregunta oberta i **ha quedat resolta amb números**, així que te l'explico i no te la
trasllado.

Et vaig plantejar malament la tria. El camp que us alimenta la SUBFAMILIA és `U_SEISubFamCialCat`,
però al costat n'hi ha un altre, **`U_SEIFamCialCat`, que és el nivell FAMÍLIA**, i no l'estàvem
mirant. Els seus valors són, literalment, les vostres 12.

El que em preocupava és que aquell camp només està informat en 198 dels 980 articles actius: semblava
que **8 de cada 10 productes** us caurien a la fila «sense assignació». Ho he mesurat abans de
moure'm, contra l'històric de vendes dels últims dotze mesos i aplicant-hi les mateixes set sèries
que exclou la vostra SQL:

| | |
|---|---|
| Facturació considerada | 22.262.329 € |
| **Passa per articles que ja tenen família** | **98,53%** |
| Articles sense família **que hagin facturat res** | **28**, no 782 |

Els altres 754 són recanvis, palets, equips de protecció, lubricants i material de fàbrica: **es
compren i no es venen**, i per això ningú els va classificar mai. El 1,47% que queda fora és el mateix
ordre de magnitud que la fila «sense assignació» que **ja teniu avui** (195.233 € de gener a agost).
O sigui que mantenir les 12 no us empitjora res: us reprodueix la situació actual.

Així que fem això, sense donar-hi més voltes:

- **Us enviem la família comercial**, no els 110 grups d'article de SAP.
- **Els identificadors de família passen a ser el nom** (`TRADICIONALS`, `GRANEL`…), perquè a SAP
  aquest camp no té cap codi al darrere. Ja em vas dir que et va bé que els ids de família canviïn.
- **Vuit articles** —farines amb família evident, com `(B4) FARINA Nº1E` o `ESPECIFICA TURRIS`— els
  omplim aquí abans del tall. És tota la feina de classificació que hi havia.
- **Res per a l'Olga**: no cal que decideixi res ni que ningú classifiqui 782 articles. Si ho vols
  comentar amb ella igualment, endavant, però jo no l'hi he portat.

Dues coses perquè no et sorprenguin el dia 2:

- Us apareixerà una família **`SUBPRODUCTE`** que vosaltres no teniu. És real, són 4 articles.
- I una **`PROVES1`**, que ja teniu, amb 3 articles. Si la vols fora, digue-m'ho i la trec.

De propina, una cosa petita que ja he comprovat: a SAP conviuen `KM0` i `KM 0` —amb un espai— com si
fossin dues famílies. La segona té un sol article i està de baixa. Ho corregeixo aquí abans del tall.

## Una pregunta petita

**Feu servir `est_cobraments`?** Us l'omplim cada nit, però no surt ni a les SQL que em vas passar ni
a la teva llista de camps del maig. Ho pregunto perquè
pel nostre costat hi ha una alarma que atura la publicació sencera si aquella taula queda buida, i si
resulta que no la mireu, estaríem bloquejant les dades que sí que useu per una que no. Si no la
feu servir, li baixo la severitat.

Relacionat: el deute pendent dels vostres clients **sí que us arribarà** el dia 2. A SAP les factures
pendents es migren com a factures de servei amb el número i la data originals de KAIS, i nosaltres
les recollim. Sense això, el dia 2 el deute hauria semblat esfumar-se.

## El cost

**El cost d'octubre**: d'acord, queda amb el cost del moment i al desembre fem la càrrega puntual des
de la base de dades antiga. Ho preparo amb temps.

Salutacions,
Oscar Hijazo
Agrienergia
ohijazo@agrienergia.com

---

> **Nota interna (no enviar).**
>
> **Actualitzat el 16/09/2026.** L'esborrany era de l'01/09 i es va quedar quinze dies sense enviar.
> El que ha canviat des de llavors:
>
> - **La connexió ja no bloqueja**: Sistemes van habilitar l'accés d'Analitza el 10/09/2026. Entren
>   per VPN, com sempre. La secció que deia "hi estic al damunt" ja no té sentit.
> - **Cal avisar de la rotació d'`analitza_ro`.** Sistemes els ho van comunicar com «les credencials
>   i l'url són les mateixes, no ha canviat res»: per la VPN és cert, pel login de SQL **no**. La
>   contrasenya va canviar el 31/08 i els permisos es van acotar el mateix dia. Si no s'avisa, el
>   símptoma és un login fallit que sembla xarxa i el diagnòstic se'n va cap a Sistemes.
> - **S'hi afegeix l'avís de no carregar dades de test a producció.** Apunta a `DB_FARINERA_TEST` i
>   els ids que en surten no són tots els de KAIS. Si els ingereixen, els entren com a clients nous.
> - **La secció del dia 2** és nova. El `discount` es queda com està —`1-discount` a la seva SQL
>   confirma que la convenció actual ja és la bona—, i del `/100` es demana confirmació per escrit
>   perquè el runbook l'exigeix i és l'únic punt que falla en silenci.
> - **Les famílies ja no són una pregunta.** Mesurat el 16/09 contra `bi_estadili` de KAIS: el 98,53%
>   de la facturació passa pels 198 articles classificats, i dels 782 només 28 han facturat res. Es
>   comunica la decisió en comptes de demanar-la. `correu_olga_families.md` queda **SUPERAT — NO
>   ENVIAR**, i a l'Olga no se li escriu: no ha de decidir res.
> ✅ **ENVIAT el 16/09/2026**, el mateix dia que `dbo.est_*` va començar a refrescar-se amb dades de
> `DB_FARINERA_TEST`. Abans es quedava congelat al run 91 del 24/08 perquè el job avortava amb
> `ABORTED_STALE_MIRROR`, així que la finestra en què l'Adrià podia ingerir dades de proves sense
> saber-ho va durar hores, no dies. Tenia accés per VPN des del 10/09.
>
> ✅ **Contrasenya d'`analitza_ro` passada el mateix dia** per un canal a part. Amb això el handoff
> queda tancat: té ruta, credencial i dades. D'ell només falta el «confirmat» del `/100`.
> - El codi de les famílies **ja està desplegat i validat** darrere de `cfg.settings.FAMILY_FROM_COMMERCIAL`,
>   que és a `'0'`. Activar-lo fa desaparèixer 110 identificadors i vol `ID_DROP_MAX` apujat aquell
>   dia. O sigui que el que es promet en aquest correu està fet, no previst.
>
> ✅ **Fet:** la contrasenya d'`analitza_ro` es va passar el 16/09/2026 per un canal que no és el
> correu.
>
> **Fet i commitejat l'01/09/2026:**
> - `cfg.client_ship_no` + `etl.sp_assign_client_ship_no`; `etl.vw_client_ship` passa a llegir el
>   número en comptes de calcular-lo. Provat: 0 ids canvien en desplegar-ho.
> - Check `history_floor` (CRITICAL, atura el swap) i els checks `ship_no_missing` i
>   `ship_address_changed`.
> - `U_SEIFamCialCat` afegit al `$select` i a la sonda, amb cobertura sobre el cens i sobre els
>   actius.
>
> **La productiva arrenca sense històric d'albarans: TANCAT l'01/09/2026** contra el blueprint
> signat, cap. 17.3. Amb això, `LINES_MIN_RATIO` s'ha d'abaixar el dia 2 obligatòriament, la data
> mínima serà el 2 de novembre, i `est_cobraments` no quedarà buida perquè les factures de servei
> són `OINV` obertes.
>
> **El que depèn de tercers:** ~~desplegar el Worker~~ ✅ fet el 16/09/2026; queda que Sistemes
> registrin la tasca de les 02:45. I la llicència de l'usuari tècnic de SAP, que no s'ha mogut.
>
> **Els 782 articles actius sense família** són una feina de classificació que no és nostra, i té
> data. Si l'Olga tria l'opció B sense que això es faci, el dia 2 vuit de cada deu articles li surten
> sense família i el problema es veurà a la seva aplicació, no a la nostra.
>
> **`cfg.client_ship_no` ha d'entrar al backup.** No es pot regenerar.
