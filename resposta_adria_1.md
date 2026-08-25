# Resposta al correu d'Adrià (Analitza CM) sobre canvis d'IDs

**Per a:** adria@analitza.com
**CC:** lbutinya@agrienergia.com
**Assumpte:** RE: Analitza CM — nou origen SAP B1 llest a test (IntercanviSAP a AE01SAPSQL)

*(El text per enviar comença a "Hola Adrià". Al final hi ha una nota interna que NO s'envia.)*

---

Hola Adrià,

Gràcies per posar-ho sobre la taula: has encertat de ple. Hem consultat SAP i **una part dels codis
sí que canvien**.

| Dimensió | El codi de SAP és el de KAIS? |
|---|---|
| Comercials | **No** — de 48, només 2 coincideixen |
| Famílies | **No** — SAP els numera per dins (108, 109, 110...) |
| Productes | **Sí** — es van preservar a la migració (`00010`, `00020`, `00340`...) |
| Clients | **No** |
| Línies d'albarà | D'acord amb tu: són derivats, no hi ha res a preservar |

## La proposta: que SAP guardi el codi de KAIS

En comptes d'anar apedaçant cada cas, et proposem la mateixa solució per a tot: **crear un camp a
cada mestre de SAP que guardi el codi que teníeu a KAIS**, i que nosaltres us enviem sempre aquest,
no el de SAP.

Als comercials **això ja existeix**: SAP guarda el codi KAIS de cada un, i 48 dels 49 el tenen
informat. O sigui que no és cap invent — és estendre a la resta el que algú ja va fer bé al seu dia.

| Mestre | Camp | Estat |
|---|---|---|
| Comercials | `U_FCCodiKais` | ja existeix i està poblat |
| Clients | `U_FCCodiKais` | a crear i poblar al cutover |
| Famílies | `U_FCCodiKais` | a crear i poblar al cutover |
| Productes | — | no cal: el codi de SAP ja és el de KAIS |

**Per què així i no d'una altra manera.** A les famílies, per exemple, el codi antic es podria
endevinar perquè està dins del nom del grup (`010001-BLAT SUPER FORÇA`). Podríem retallar-lo
d'allà, però n'hi hauria prou que algú reanomenés un grup perquè es trenqués sense que ningú se
n'adonés. Un camp propi no es trenca.

**Què vol dir per a tu:** els ids que rebeu segueixen sent els d'avui. El pla que comentaves
—històric de la vostra base de dades i, a partir d'una data, tirar de la nova— **et segueix
funcionant tal qual**, sense que hàgiu de tocar res.

## Clients: un camp més

Als clients, a banda del codi KAIS, ens falta el que ja teniu avui: quan es desactiva un client i
se n'obre un de nou per canvi de raó social, saber quin és el successor. Proposem un segon camp,
`U_FCNewCardCode`, que omplim nosaltres a cada canvi.

Com que això depèn que algú se'n recordi, hi afegiríem una xarxa: quan detectem un client nou amb
el mateix NIF que un de desactivat, us l'enllacem igualment encara que el camp estigui buit.

Us ho enviaríem com a `new_code = COALESCE(U_FCNewCardCode, U_FCKaisCode)`, al mateix camp que ja
consumiu — o en dues columnes separades, si ho prefereixes tenir diferenciat.

Vam mirar si SAP ja guardava el codi de client antic en algun lloc: hi ha un camp que en algun cas
el porta, però només l'hem trobat informat en 10 clients de 500 i la numeració no lliga. No serveix.

## Què necessito de tu

1. **Et sembla bé l'enfocament** del camp amb el codi KAIS a cada mestre?
2. **Famílies**: envia'm quatre dels vostres codis, per confirmar que són els que pensem
3. **Clients**: teniu la llista de codis KAIS amb el nom del client? Per poblar el camp nou ens
   estalviaria molts casos dubtosos

Amb l'1 ja puc crear els camps i deixar-ho preparat.

## Tres temes menors, per quan tanquem això

- **`product_cost`**: el que us arribava de KAIS és el cost congelat al moment de l'albarà, i pel
  canal per on ara llegim SAP aquest valor no s'exposa. El més proper quadra el 92% dels cops, però
  és un altre concepte i aniria derivant. En parlem cinc minuts i acordem què hi posem.
- **Filtres**: al maig em vas oferir passar-nos les vostres SQL amb els filtres que apliqueu sobre
  KAIS. Ara ens anirien molt bé: així us ho enviem ja net des d'origen.
- **Atributs de client**: dels sis que llistaves, us en generem quatre. Falten **RAÓ SOCIAL** i
  **ACTIU** — els feu servir com a atribut, o en teniu prou amb el `name` i l'`active` de la taula
  de clients?

Si tens un moment aquesta setmana ho parlem per telèfon i anem més ràpid.

Salutacions,
Oscar Hijazo
Agrienergia
ohijazo@agrienergia.com

---

> **Nota interna (no enviar).** Substitueix l'esborrany del 11/08/2026, que responia de memòria.
> El 25/08/2026 es va consultar SAP per Service Layer i es va contrastar cada afirmació. Els
> números surten de la sonda (`dotnet run -- --probe`) contra `DB_FARINERA_TEST`; detall a
> `docs/memoria_projecte.md` §6.4.
>
> Correccions respecte de l'esborrany anterior:
> - **Comercials i famílies**: deia que "en principi es van preservar". **És fals** — 2 de 48 als
>   comercials, i les famílies porten numeració interna de SAP.
> - **Clients**: donava per bona la regla `CardCode = "C" + 6 últims dígits del codi KAIS`. Les
>   dades no la sostenen.
> - **Comercials**: `SalesPerson.U_FCCodiKais` ja existeix i està poblat (48 de 49).
> - **Productes**: confirmat per l'Oscar (25/08/2026) que els `ItemCode` de SAP són els de KAIS.
>   No cal ni UDF ni exercici de verificació amb Analitza.
>
> Feina que se'n deriva si ho accepta: crear `U_FCCodiKais` a `OCRD` i `OITB` (i a `OITM` si cal),
> més `U_FCNewCardCode` a `OCRD`; afegir-los al mirall `sap_raw`; i canviar `sp_load_salesmen`,
> `sp_load_product_categories` i `sp_load_clients` perquè els projectin. Res d'això no està fet.
>
> El `U_FCNewCardCode` s'omple a mà a cada canvi de raó social, i ho fa la mateixa persona que
> manté tot això. És un punt únic de fallada: si un dia no s'omple, Analitza comptabilitza un
> client perdut i un de guanyat sense que salti cap alarma. Per això al correu s'hi afegeix la
> detecció per NIF, que no depèn de ningú. Queda per implementar a `sp_load_clients`:
> si un CardCode inactiu i un d'actiu comparteixen `FederalTaxID`, enllaçar-los.
