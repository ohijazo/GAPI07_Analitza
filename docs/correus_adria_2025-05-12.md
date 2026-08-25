# Correus d'Adrià Arnau (Analitza CM) — 12/05/2025

> **Per què aquest fitxer existeix.** Els dos correus originals estan a `docs\` en PDF, però
> exportats des d'Outlook amb fonts Type3 sense taula ToUnicode: **no tenen capa de text**, ni es
> poden copiar, ni cercar, ni obrir amb un lector de PDF que en tregui el contingut. El text s'ha
> reconstruït desxifrant la codificació de glifs (25/08/2026).
>
> Fitxers originals:
> - `Re_ Integració Analitza amb SAP_ Oscar Hijazo - Outlook.pdf`
> - `Re_ info_ Oscar Hijazo - Outlook.pdf`
>
> Hi pot haver alguna errada de transcripció puntual. Per a decisions delicades, contrastar amb
> l'Adrià.

---

## Correu 1 — "Integració Analitza amb SAP"

**De:** Adrià Arnau (adria@analitza.com) · **Per a:** Lluís Butinyà ·
**CC:** Olga Girona, Oscar Hijazo · **Data:** dilluns 12/05/2025 10:29
**Adjunt:** Guia de importación de datos Analitza CM v9.pdf

> Bon dia Lluís,
>
> Intento fer un resum de tot perquè ho tinguem escrit a algun lloc i si em deixo res ho comentem
> (adjunto un pdf amb totes les dades que ens podeu passar de referència).
>
> **• Com ens integrem?** Un cop al dia (actualment a les 5am) ens connectem via vpn a una base de
> dades amb un usuari de només lectura on estirem els canvis dels últims dies. Això es pot fer sobre
> les taules originals de sap o sobre unes altres taules/vistes que feu especialment per analitza
> (una opció us dóna més control i l'altra ens dóna més flexibilitat i rapidesa de cares a
> modificacions/afegir dades).
>
> **• Quines dades estem fent servir actualment?** Actualment estem estirant de les següents
> taules/fitxers:
>
> **CLIENTS:** `id_client_location`, `name`, `active`, `address`, `city`, `zip_code`,
> `country_code`, `salesmen_id`, `new_code`, `phone_number`, `email`
>
> **PRODUCTES:** `id_product`, `name`, `product_categories_id`, `active`
>
> **LINIES ALBARÀ:** `id_invoice_line`, `invoices_id`, `date`, `client_locations_id`,
> `products_id`, `product_price`, `product_cost`, `net_amount`, `discount`, `quantity`, `series`,
> `observations`
>
> **FAMILIES:** `id_product_category`, `name`
>
> **COMERCIALS:** `id_salesman`, `name`
>
> **ATRIBUTS DE CLIENT:** `client_locations_id`, `name`, `value` — on tenim els atributs:
> **RAÓ SOCIAL, ZONA, POS. BCN CONSULTING, ACTIU, SEGMENT US FARINA 1, SEGMENT US FARINA 2**
>
> **ATRIBUTS DE PRODUCTE:** `products_id`, `name`, `value` — on tenim els atributs: **SUBFAMILIA**
>
> Aquestes dades les estirem actualment de les taules que va preparar KAIS en el seu dia:
> `est_atributs_client`, `est_clients`, `est_linies_albara`, `est_atributs_producte`,
> `est_families_productes`, `est_productes`, `est_agents`
>
> Sobre aquestes taules, tot i algun filtrat que entenc que devia fer KAIS en el seu moment, també
> vam estar filtrant alguns clients, sèries, productes, etc. (nosaltres fem una sql sobre les dades
> i podem filtrar el que necessiteu) que si voleu ho parlem més endavant quan estiguem afinant la
> facturació.
>
> **•** També necessitaria saber si hi haurà un bolcat de les dades actuals a SAP i si és així de
> quin històric comptarem. I també, si disposarem d'una base de dades de test per tenir-ho tot
> provat.

---

## Correu 2 — "info"

**De:** Adrià Arnau · **Per a:** Oscar Hijazo · **CC:** Lluís Butinyà ·
**Data:** dilluns 12/05/2025 10:22

> Bon dia Oscar,
>
> No sé si el correu que acabo d'enviar t'ha resolt els dubtes.
>
> Però bàsicament se'ns va fer un usuari de vpn i un usuari "analitza" de la db "Intercanvi" que
> ens va muntar KAIS amb unes taules intermitges que ens mantenen actualitzades i nosaltres estirem
> cada dia a les 5am, en una connexió que dura 1 minut.
>
> **\*** Inicialment l'extracció es feia abans de les 5am però vam anar retrassant l'hora perquè
> teníem algun problema de desquadre, no sabem si per culpa de la sincronització de les dades de
> KAIS o d'algun procés intern d'albarans.
>
> Sobre aquestes taules hi ha diferents nivells d'integració:
>
> - si la nomenclatura dels camps i format segueix la nostra guia i les dades estan correctament
>   filtrades, etc. podem fer un "select \*" i importem la informació directament sense tocar.
> - si més o menys segueix la nomenclatura però no està del tot filtrat, fem un sql acabant
>   d'ajustar i filtrar les dades (com en el cas de KAIS; **si vols et puc passar les nostres SQL
>   perquè vegis els filtres que vam aplicar sobre de KAIS**).
> - estirem les dades directament de les taules de sap i treballem conjuntament per mirar la
>   correspondència dels camps i com aplicar tots els filtres necessaris per quadrar-ho tot.
>
> **Quins són els passos a seguir?** Normalment, quan hem donat una volta a les dades i ens teniu
> preparat l'usuari, entrem i fem una extracció. Validem que les dades siguin correctes de format,
> que quadrin facturacions, etc. i ho comparem amb el que tenim ara i amb el que ens digueu que
> hagi de sortir. Si cal, ajustem les dades i repetim el procés fins que tinguem el vostre ok. Tot
> això idealment ho fem sobre la base de dades de test. I només queda esperar al dia i hora que ens
> digueu que feu el canvi per nosaltres fer també el canvi i validar que tot funcioni correctament.
>
> Estem en contacte.
>
> Salutacions,
> Adrià

---

## Què se'n desprèn per al projecte

### 1. Analitza es connecta a les **05:00**, no a les 06:00

El README deia 06:00. El job corre a les 03:00, així que el marge real és de **dues hores**, no
tres. I l'Adrià avisa que ja van haver de **retardar** la seva hora d'extracció per problemes de
desquadre amb la sincronització de KAIS o amb "algun procés intern d'albarans". Val la pena tenir-ho
present quan es mesuri quant triga el cicle del Worker.

### 2. `product_cost` **sí que el fan servir**; `product_cost_2` no

A la seva llista de camps de LINIES ALBARÀ hi ha `product_cost` i **no** hi ha `product_cost_2`.

Això tanca a mitges el forat B2 de la migració: **no podem deixar `product_cost` buit** sense
parlar-ho, perquè el consumeixen. Segueix obert quin valor hi ha de anar, ja que Service Layer no
exposa cap equivalent a `DLN1.StockPrice` (veure `memoria_projecte.md` §6.2). En canvi
`product_cost_2` el podem ignorar tranquil·lament.

### 3. Els filtres de KAIS: **l'Adrià ja es va oferir a passar-los**

"si vols et puc passar les nostres SQL perquè vegis els filtres que vam aplicar sobre de KAIS".

Aquest era un dels pendents del Bloc C. No cal investigar-ho: només cal demanar-ho. L'oferta és de
maig de 2025 i encara no s'ha recollit.

### 4. Els atributs de client: en falten dos i en sobra un

L'Adrià llista sis atributs de client. Contrastat amb el que produeix `sp_load_client_attributes`:

| Atribut que espera Analitza | El produïm? |
|---|---|
| ZONA | ✅ `zone_id` + `zone_description` (de `CRD1.U_SEIZONAC`) |
| POS. BCN CONSULTING | ✅ `positioning_bcn_consulting` (de `OCRD.U_SEIPOSBC`) |
| SEGMENT US FARINA 1 | ✅ `segmentation_use_1` (de `OCRD.U_SEISEGH1`) |
| SEGMENT US FARINA 2 | ✅ `segmentation_use_2` (de `OCRD.U_SEISEGH2`) |
| **RAÓ SOCIAL** | ❌ |
| **ACTIU** | ❌ |
| *(payment_method / payment_description)* | el produïm, però **no és a la seva llista** |

`ACTIU` probablement es cobreix amb `est_clients.active`, i `RAÓ SOCIAL` amb `est_clients.name`,
però com a **atributs** no hi són. Cal confirmar-ho amb l'Adrià: si els fa servir com a atribut,
ens falten dues columnes.

### 5. El seu procés de validació encaixa amb el nostre

Fan extracció, validen formats, comproven que quadrin les facturacions, ho comparen amb el que
tenen ara, i iteren fins a donar l'ok — **idealment sobre una base de dades de test**. Això reforça
la petició de refrescar `DB_FARINERA_TEST` amb dades reals abans del cutover.

### 6. Preguntes seves que segueixen sense resposta des de maig de 2025

- Hi haurà un bolcat de les dades actuals a SAP? De quin històric es comptarà?
- Disposaran d'una base de dades de test?
