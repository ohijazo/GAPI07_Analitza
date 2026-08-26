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

**El que sí que necessitem de tu** és la correspondència per poder omplir el camp dels clients:
passa'ns la llista dels vostres codis de client amb el nom. El CIF el tenim a SAP i creuem
nosaltres. Sense això hauríem d'anar només per nom, que és on surten els casos dubtosos.

I una cosa que t'agrairé confirmar: **envia'm quatre dels vostres codis de família**. Els que tenim
tenen pinta de ser els vostres, però prefereixo comprovar-ho que no pas suposar-ho.

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

## Com farem el tall

M'ho preguntaves i és just concretar-ho:

1. **Setmanes de validació en paral·lel.** Seguiu carregant de l'`Intercanvi` actual per a producció
   i alhora us connecteu a `IntercanviSAP` per contrastar. Comparem recomptes, facturacions i marges
   fins que quadri.
2. Del nostre costat ja ho fem amb el mateix criteri: cada càrrega es compara contra una fotografia
   de la sortida antiga, taula per taula i fila per fila. Ara mateix set de les vuit taules surten
   idèntiques.
3. **El dia del tall** només canviem un paràmetre per apuntar a la SAP productiva. Si normalitzem el
   `discount`, és el mateix dia i coordinat.
4. Si algun check crític falla, la publicació s'avorta i les taules es queden amb les dades del dia
   anterior. Mai veureu dades a mitges.

**Un avís sobre l'històric d'albarans**: a la SAP productiva no hi haurà els albarans anteriors al
cutover, així que `IntercanviSAP` només portarà dades a partir d'aquell dia. Com que em dius que
conserveu l'històric al vostre motor, encaixa. Però vol dir que el primer dia veureu la taula de
línies gairebé buida i anirà creixent — que no us espanti.

## Un tema menor

Feu servir `product_cost`. El que us arribava de KAIS és el cost de l'article **congelat al moment de
l'albarà**, i pel canal per on ara llegim SAP aquest valor no s'exposa. El candidat més proper quadra
el 92% dels casos, però és un altre concepte —el preu de compra actual de l'article— i aniria
derivant sense que ningú se n'adonés. De moment us arribarà a zero, a propòsit, perquè es vegi. En
parlem cinc minuts i acordem què hi posem.

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
> - Detecció de successor per `FederalTaxID` a `sp_load_clients`, com a xarxa perquè
>   `U_FCNewCardCode` no depengui només que algú se'n recordi d'omplir-lo.
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
> **Correcció al correu anterior**: se li va dir que podia mantenir la seva extracció a les 06:00,
> però al seu correu del 12/05/2025 diu que la fan a les **05:00**. El nostre procés acaba molt
> abans, així que no hi ha conflicte, però la xifra era equivocada.
>
> **Bloqueja l'enviament**: la contrasenya d'`analitza_ro` encara és un placeholder desconegut. S'ha
> de rotar abans de poder-li passar res per canal segur.
