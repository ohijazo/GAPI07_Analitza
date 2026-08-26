# Resposta a l'Adrià (Analitza CM) — IDs, discount i connexió

**Per a:** adria@analitza.com
**CC:** lbutinya@agrienergia.com
**Assumpte:** RE: Analitza CM — nou origen SAP B1 llest a test (IntercanviSAP a AE01SAPSQL)

*(El text per enviar comença a "Hola Adrià". Al final hi ha una nota interna que NO s'envia.)*

---

Hola Adrià,

Gràcies per la resposta, i sobretot pel punt dels IDs: hi tens raó i hem estat mirant-ho a fons.
Tinc bones notícies.

## Els IDs: no cal que toqueu res

Hem consultat SAP i és cert que una part dels codis canvien. Però no cal que ho resolgueu vosaltres,
ho resolem a l'origen: **crearem un camp a cada mestre de SAP que guardi el codi que teníeu a KAIS**,
i us enviarem sempre aquest, no el de SAP.

Als comercials **això ja existeix**: SAP guarda el codi KAIS de cada un i 48 dels 49 el tenen
informat. No és cap invent, és estendre a la resta el que algú ja va fer bé al seu dia.

| El que et preocupava | Com queda |
|---|---|
| Canviar els permisos de tots els usuaris pels comercials nous | **No cal.** Els `id_salesman` seran els d'ara |
| Productes i famílies que apareguin com a "deixats de comprar" | **No passarà.** Els codis de producte ja es van preservar a la migració, i els de família us els enviarem com els teniu |
| Perdre els historials de client, clients nous i antics morint | **Evitat.** Els `id_client_location` seran els d'ara |

O sigui que les dues opcions que plantejaves —el fitxer de `new_code` i l'script que us modifiqui la
base de dades— **no fan falta cap de les dues.**

### I els clients nous?

La regla és: **si té codi de KAIS, us enviem el de KAIS; si no en té, el de SAP.**

Un client donat d'alta a SAP després del tall no ha existit mai a KAIS, així que us arribarà amb el
seu codi de SAP (`C001024-000`) i el conservarà per sempre. Per vosaltres és el comportament correcte:
és un client nou de debò i ha d'aparèixer com a tal.

Això vol dir que a la llista hi conviuran els dos formats —`00001066-000` dels que venen de KAIS i
`C001024-000` dels nous—, però no es poden trepitjar: els vostres són vuit dígits i els de SAP són
una `C` i sis. Cap dels dos deixa de ser únic ni canvia mai.

El mateix criteri per als comercials i les famílies.

### El `new_code`

Amb això, el `new_code` queda més net del que et vaig plantejar. Ja no fa de pont cap a KAIS —el
pont és el propi identificador—, així que **només portarà l'identificador del successor** quan un
client canviï de raó social: es desactiva un, se n'obre un altre, i el registre vell us diu quin és
el nou. Igual que ara. La resta del temps anirà buit.

Ho omplim nosaltres a cada canvi. I com que això depèn que algú se'n recordi, hi afegim una xarxa:
si detectem un client nou amb el mateix NIF que un de desactivat, us l'enllacem igualment.

### El que necessito de tu

La correspondència per poder omplir el camp dels clients: **passa'm la llista dels vostres codis de
client amb el nom**. El CIF el tenim a SAP i creuem nosaltres. Sense això hauríem d'anar només per
nom, que és on surten els casos dubtosos.

I **envia'm quatre dels vostres codis de família**, per confirmar que els que tenim són els vostres.
Prefereixo comprovar-ho que no pas suposar-ho.

## El `discount` (el teu punt 10)

Aquí m'has fet un favor. Efectivament, segons la vostra guia `discount` és el **percentatge** de
descompte (0.25 = 25%) i la fórmula és `net_amount = price × qty × (1 - discount)`. El que us
arribava de KAIS era el multiplicador, i nosaltres ho hem replicat tal qual per no trencar-vos res.

**Proposo normalitzar-ho**, i fer-ho el dia del cutover:

- Nosaltres passem a enviar-vos el descompte de debò: `0.00` quan no n'hi ha, `0.10` per un 10%.
- Vosaltres traieu el `1 - discount` el mateix dia.

És l'únic moment en què surt gratis: ja reanalitzareu tot amb la nomenclatura nova, i l'històric que
teniu ingerit ja el vau corregir a l'entrada, o sigui que no s'ha de tocar. Si ho deixem per després,
ens quedem un arreglo permanent que d'aquí tres anys ningú recordarà per què hi és.

Si prefereixes mantenir el fix, també va bé: digue-m'ho i ho deixem com està. El que no voldria és
canviar-ho sense que estigui coordinat al dia.

## La connexió

Anem a això, que és el que et desbloqueja per començar a mirar dades.

- **Servidor**: `AE01SAPSQL`, port 1433. **No** és la mateixa màquina que l'`Intercanvi` actual.
- **IP i contrasenya**: te les passo per canal segur a part.
- **Usuari**: `analitza_ro`, `db_datareader` només a `IntercanviSAP`.
- **VPN**: si reaprofites l'actual, cal comprovar que et doni ruta a aquest servidor, que és en un
  altre segment intern. Digue'm des de quina IP sortiu i ho validem; si no hi arriba, l'estenem.

## Què podràs validar ara, i què no

Aquí he de ser clar amb tu, perquè si no perdràs el temps.

**Ara pots validar l'estructura i els mestres.** `IntercanviSAP` s'alimenta de l'entorn de **test**
de SAP, i els mestres sí que són dades de debò: 5.651 ubicacions de client, 2.028 productes, 110
famílies i 49 comercials. Val la pena que t'hi connectis i comprovis que les teves SQL corren, que
els formats et van bé i, sobretot, que els codis lliguen amb els que tens.

**Ara NO pots validar xifres.** L'entorn de test de SAP gairebé no té albarans: seixanta-dues línies,
i escrites a mà per anar provant. Comparar facturació o marges contra el que et dona KAIS no et dirà
res, perquè no són els mateixos fets: KAIS té l'operativa real i SAP test no té operativa.

**Les xifres es validaran a partir del tall.** El **2 de novembre** comencem a treballar amb SAP i a
KAIS ja no hi entraran dades: no hi haurà cap període amb els dos sistemes rebent les mateixes
operacions. Això vol dir que una comparació KAIS contra SAP no arribarà a ser possible mai, ni abans
ni després. A partir del 2 de novembre validarem contra el negoci: el que digui SAP i el que
esperem que surti.

**I una cosa important si connectes abans**: connecta't a mirar, però **no enganxis encara la teva
ingesta de producció**. Com que `invoice_lines` la carregueu de forma incremental, aquestes 62
línies de prova se us quedarien a dins barrejades amb l'històric bo.

Una precisió perquè no et pensis que tens més garanties de les que et puc donar: pel nostre costat
comparem cada càrrega contra una fotografia de la sortida anterior, i ara mateix set de les vuit
taules surten idèntiques. Això valida **la nostra manera nova de llegir SAP contra la nostra manera
antiga de llegir SAP**. És una comprovació de la canonada, no una equivalència entre KAIS i SAP:
aquesta no la pot demostrar ningú fins que SAP tingui operativa real.

## Com farem el tall

1. **D'aquí al 2 de novembre**: tu valides estructura i mestres amb l'entorn de test, i tanquem la
   correspondència de codis.

   Aquesta part té data límit de debò. Els camps amb els codis de KAIS han d'estar creats i omplerts
   **abans** del 2 de novembre, no el mateix dia: si el primer dia us enviem els codis de SAP,
   vosaltres els ingeriu com a clients nous i desfer-ho després costa molt més que fer-ho bé
   d'entrada. Per això et demano la llista de codis com abans millor.

2. **El 2 de novembre** canviem un paràmetre per apuntar a la SAP productiva. Si normalitzem el
   `discount`, és el mateix dia i coordinat: tu treus el `1 - discount` i nosaltres comencem a
   enviar-te el percentatge de debò.
3. **Els primers dies** mirem junts que les xifres que van sortint siguin coherents. Aquí sí que et
   demanaré que hi posis ull.
4. Si algun check crític falla, la publicació s'avorta i les taules es queden amb les dades del dia
   anterior. Mai veureu dades a mitges.

**Un avís sobre l'històric d'albarans**: a la SAP productiva no hi haurà els albarans anteriors al 2
de novembre, així que `IntercanviSAP` només portarà dades a partir d'aquell dia. Com que em dius que
conserveu l'històric al vostre motor, encaixa. Però vol dir que el primer dia veureu la taula de
línies gairebé buida i anirà creixent — que no us espanti.

## Un tema menor

Feu servir `product_cost`. El que us arribava de KAIS és el cost de l'article **congelat al moment de
l'albarà**, i per aquesta via no el tenim: llegim SAP per la seva API oficial en comptes d'anar
directament a les taules, i aquest camp concret no s'hi exposa. El candidat més proper quadra el 92%
dels casos, però és un altre concepte —el preu de compra actual de l'article— i aniria derivant
sense que ningú se n'adonés. De moment us arribarà a zero, a propòsit, perquè es vegi. En parlem
cinc minuts i acordem què hi posem.

*(De `product_cost_2` no en dius res, així que entenem que no el feu servir.)*

## Resum del que necessito

1. La llista dels vostres codis de client amb el nom, per creuar amb el CIF de SAP
2. Quatre dels vostres codis de família, per confirmar
3. Normalitzem el `discount` al cutover, o mantens el fix?
4. Des de quina IP sortiu, per validar la ruta de la VPN

I si encara tens a mà les vostres SQL amb els filtres que apliqueu sobre KAIS —me'n vas parlar al
maig—, ara m'anirien molt bé: així us ho enviem ja net des de l'origen.

Salutacions,
Oscar Hijazo
Agrienergia
ohijazo@agrienergia.com

---

> **Nota interna (no enviar).** Fusiona la resposta pendent sobre IDs amb la resposta de l'Adrià del
> 26/08/2026, per no enviar dos correus que s'encavalquen.
>
> **Feina que se'n deriva:**
> - Crear `U_FCCodiKais` a `OCRD` i `OITB`, i `U_FCNewCardCode` a `OCRD`. A `OSLP` ja hi és i està
>   poblat (48 de 49). A `OITM` no cal: els `ItemCode` ja són els de KAIS.
> - Afegir-los a `sap_raw` i projectar-los a `sp_load_salesmen`, `sp_load_product_categories` i
>   `sp_load_clients`.
> - Regla d'emissió, la mateixa als tres mestres:
>   `id = COALESCE(U_FCCodiKais, <codi SAP>)`. Els codis de KAIS són 8 dígits i els CardCode són
>   `C` + 6, així que no es poden trepitjar.
> - **Correcció respecte de l'esborrany anterior**: es proposava
>   `new_code = COALESCE(U_FCNewCardCode, U_FCKaisCode)`. Això era erroni. Tenia sentit quan
>   l'identificador era el codi de SAP i el `new_code` feia de pont cap a KAIS; si el codi de KAIS
>   **és** l'identificador, posar-lo també al `new_code` diria que el client ha canviat de codi a
>   si mateix. `new_code` ha de portar només l'identificador del successor, passat per la mateixa
>   regla del COALESCE, i NULL la resta del temps. Cau també la idea de la columna `kais_code`
>   separada: ja no fa falta.
> - Detecció de successor per `FederalTaxID` a `sp_load_clients`, com a xarxa perquè
>   `U_FCNewCardCode` no depengui només que algú se'n recordi d'omplir-lo.
>
> **Risc nou que introdueix el COALESCE, i és de la família del bug del `LineType`:** si un client
> que ja existia es queda amb `U_FCCodiKais` buit, el COALESCE cau al CardCode de SAP i Analitza el
> veu com un client nou. En silenci, i just el dia del tall, que és quan menys es mira. La població
> del camp ha de ser completa i verificada abans de l'1 de novembre, no "gairebé completa".
>
> **Check de qualitat que ho cobriria, i que val la pena tant si s'accepta la proposta com si no:**
> avisar quan un `id_client_location` que ahir hi era avui desapareix. `dbo.est_clients` té la foto
> d'ahir, o sigui que és un `EXCEPT` contra `staging`. Protegeix el contracte cada nit i no depèn de
> recordar-se de res. Ara mateix no existeix cap check d'aquest tipus.
>
> **Si accepta normalitzar el `discount`**, cal canviar tres coses alhora, i totes tres o cap:
> - `sp_load_invoice_lines`: emetre `1 - multiplicador` en comptes del multiplicador.
> - `sp_data_quality_checks`: el check `formula_break` passa a
>   `net_amount = price × qty × (1 - discount)`.
> - `.claude/rules/04-contracte-analitza.md` i `docs/memoria_projecte.md`, que ara documenten la
>   convenció del multiplicador com si fos la bona.
>
> Si ell no treu el seu `1 - discount` el mateix dia, falla de manera sorollosa: els descomptes
> passarien de `0.00` a `1.00` i els imports sortirien a zero. Val més això que un error silenciós.
>
> **Tanca dos temes oberts**: els codis de zona i de forma de pagament poden canviar sense problema
> ("tot es reanalitzarà"), o sigui que l'harmonització de `zone_id` que se li havia ofert no cal fer-la.
>
> **Sobre les "setmanes de validació en paral·lel"** que se li van prometre al primer correu: no es
> poden fer. Ell llegeix KAIS, nosaltres llegim SAP test, i SAP test no té operativa (62 línies
> d'albarà, escrites a mà). I el tall del **2 de novembre de 2026 és sec**: KAIS deixa de rebre dades
> el mateix dia que SAP arrenca, o sigui que no hi haurà mai un període amb els dos sistemes rebent
> les mateixes operacions. Una comparació KAIS contra SAP no serà possible ni abans ni després.
>
> **Data límit real per als UDFs: 1 de novembre.** No és "al cutover". Si el dia 2 s'envien els codis
> de SAP en comptes dels de KAIS, Analitza els ingereix com a clients nous i desfer-ho després és
> molt més car. Això mou la creació i la població dels camps a feina amb data, no a feina pendent.
>
> **Correcció al correu anterior**: se li va dir que podia mantenir la seva extracció a les 06:00,
> però al seu correu del 12/05/2025 diu que la fan a les **05:00**. El nostre procés acaba molt
> abans, així que no hi ha conflicte, però la xifra era equivocada.
>
> **Bloqueja l'enviament**: la contrasenya d'`analitza_ro` encara és un placeholder desconegut. S'ha
> de rotar abans de poder-li passar res per canal segur.
