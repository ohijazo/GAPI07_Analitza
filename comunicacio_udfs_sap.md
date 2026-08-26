# Nous camps d'usuari a SAP Business One — comunicació

**Projecte:** GAPI07 — Integració SAP B1 → Analitza CM
**De:** Oscar Hijazo (Agrienergia) — ohijazo@agrienergia.com
**Data:** 26 d'agost de 2026
**Quan:** creats i poblats abans de l'**1 de novembre de 2026**

Us informo que crearé tres camps d'usuari a SAP. **Els creo i els omplo jo**; no us demano feina.
Us ho comunico perquè afecta l'esquema d'un sistema que doneu suport, i perquè al final hi ha una
pregunta on el vostre criteri em pot estalviar temps.

---

## Els camps

| Taula | Nom del camp | Tipus | Mida | Estat |
|---|---|---|---|---|
| `OSLP` — Empleats de vendes | `U_FCCodiKais` | Alfanumèric | — | **Ja existeix i està poblat.** No el toco |
| `OCRD` — Interlocutors comercials | `U_FCCodiKais` | Alfanumèric | 20 | El crearé |
| `OCRD` — Interlocutors comercials | `U_FCNewCardCode` | Alfanumèric | 15 | El crearé |
| `OITB` — Grups d'articles | `U_FCCodiKais` | Alfanumèric | 20 | El crearé |

A `OITM` (Articles) no cal res: els `ItemCode` de SAP ja són els mateixos codis que tenia l'ERP
anterior.

Cap dels tres serà obligatori ni tindrà valor per defecte: han de poder quedar buits sense bloquejar
l'alta d'un client ni d'un grup d'articles.

---

## Per què

Agrienergia alimenta la plataforma d'anàlisi comercial **Analitza CM** amb una base de dades
intermèdia. Fins ara s'omplia des de l'ERP antic (KAIS); a partir del **2 de novembre** s'omplirà des
de SAP Business One.

El problema és que **els codis interns de SAP no són els mateixos que els de KAIS**. Ho hem verificat
consultant SAP per Service Layer:

- **Comercials:** de 48 comparats, només 2 coincideixen.
- **Grups d'articles:** SAP els numera internament (108, 109, 110…), sense relació amb els antics.
- **Clients:** tampoc coincideixen, i no hi ha cap camp que guardi el codi antic de manera fiable
  (`U_SEICodienllac` només està informat en 10 clients de 500 i la numeració no lliga).
- **Articles:** aquests **sí** que es van preservar a la migració.

Si el dia del canvi Analitza rep codis diferents dels que té, no ho interpreta com un canvi de
sistema: ho interpreta com que **tots els clients històrics han desaparegut i n'han aparegut de
nous**. Es perd l'històric comercial, i els comercials i les famílies queden desvinculats de les
seves vendes anteriors.

La solució és guardar el codi antic a SAP i enviar aquest a Analitza. Als empleats de vendes **ja
existeix** (`OSLP.U_FCCodiKais`, informat en 48 dels 49): es tracta d'estendre a clients i grups
d'articles el mateix criteri que ja es va aplicar allà.

---

## Contingut i manteniment

**`OCRD.U_FCCodiKais`** — el codi que tenia el client a KAIS (8 dígits, p. ex. `00001066`). L'omplo
un sol cop abans de l'1 de novembre, a partir de la correspondència que ens facilita Analitza
creuada pel CIF. Un cop poblat no es torna a tocar. Els clients donats d'alta després del canvi el
deixen buit: no han existit mai a KAIS i han d'aparèixer com a nous.

**`OCRD.U_FCNewCardCode`** — el `CardCode` del client successor, quan es desactiva un client i se
n'obre un altre per canvi de raó social. L'omplo cada vegada que passa. Per defecte, buit. Reprodueix
una funcionalitat que l'ERP anterior ja tenia i que Analitza consumeix per no comptabilitzar un canvi
de raó social com un client perdut més un de guanyat.

**`OITB.U_FCCodiKais`** — el codi antic del grup (6 dígits, p. ex. `010001`). L'omplo un sol cop; el
codi es pot deduir del nom del grup, que ara té el format `010001-BLAT SUPER FORÇA`.

---

## Dues coses on em podeu ajudar

**1. ¿Es poden crear camps d'usuari sobre `OITB` en aquesta instal·lació?** No em consta que n'hi
hagi cap i no ho vull donar per fet. Si no és possible, digueu-m'ho: tinc una alternativa —llegir el
codi del propi nom del grup— menys robusta però viable.

**2. ¿Quina finestra em recomaneu per crear-los?** Entenc que afegir camps pot requerir que no hi
hagi ningú connectat. Digueu-me com ho feu habitualment i ho planifico fora d'hores.

---

## Consideracions

**Convenció de noms.** Faig servir el prefix `U_FC`, que és el que ja porten els camps propis
d'Agrienergia (`U_FCCodiKais`, `U_FCObservacions`, `U_FCVolPotencial`…), per distingir-los dels
`U_SEI` de la implantació.

**Res escriu a SAP de manera automàtica.** El procés que alimenta Analitza llegeix SAP per Service
Layer amb un usuari de només lectura i **no hi escriu mai**. La població d'aquests camps la faig jo,
per la via que em digueu que és la correcta.

**La població ha de ser completa.** Si un client que ja existia es queda amb el camp buit, el procés
no el pot distingir d'un client nou i Analitza el comptabilitzarà com a tal. No hi ha manera
automàtica de detectar-ho a posteriori: per això la data és l'1 de novembre i no el mateix dia del
canvi.

---

## Dates

| Quan | Què |
|---|---|
| Setembre | Creació dels tres camps, en la finestra que em digueu |
| Octubre | Població de `U_FCCodiKais` a clients i grups d'articles |
| **1 de novembre** | Tot creat i poblat, verificat |
| **2 de novembre** | Es comença a treballar amb SAP; Analitza passa a llegir del nou origen |

---

Si veieu algun inconvenient o una manera millor de resoldre-ho, digueu-m'ho abans de setembre i ho
parlem.

Atentament,
Oscar Hijazo
Agrienergia
ohijazo@agrienergia.com
