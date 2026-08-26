# Petició de creació d'UDFs a SAP Business One

**Projecte:** GAPI07 — Integració SAP B1 → Analitza CM
**Sol·licitant:** Oscar Hijazo (Agrienergia) — ohijazo@agrienergia.com
**Data:** 26 d'agost de 2026
**Data límit:** **1 de novembre de 2026** (creats *i* poblats)

---

## Què es demana

Tres camps d'usuari nous. Un quart ja existeix i no s'ha de tocar.

| Taula | Nom del camp | Tipus | Mida | Estat |
|---|---|---|---|---|
| `OSLP` — Empleats de vendes | `U_FCCodiKais` | Alfanumèric | — | **Ja existeix i està poblat.** No tocar |
| `OCRD` — Interlocutors comercials | `U_FCCodiKais` | Alfanumèric | 20 | **A crear** |
| `OCRD` — Interlocutors comercials | `U_FCNewCardCode` | Alfanumèric | 15 | **A crear** |
| `OITB` — Grups d'articles | `U_FCCodiKais` | Alfanumèric | 20 | **A crear** |

**A `OITM` (Articles) no cal crear-hi res.** Els `ItemCode` de SAP ja són els mateixos codis que
tenia l'ERP anterior, així que no hi ha res a preservar.

Nota sobre el nom: a la gestió d'UDFs s'introdueix el nom **sense** el prefix `U_`, que SAP hi afegeix
sol. Cal teclejar `FCCodiKais` i `FCNewCardCode`.

---

## Per què

Agrienergia alimenta la plataforma d'anàlisi comercial **Analitza CM** amb una base de dades
intermèdia. Fins ara aquesta base de dades s'omplia des de l'ERP antic (KAIS); a partir del **2 de
novembre de 2026** s'omplirà des de SAP Business One.

El problema: **els codis interns de SAP no són els mateixos que els de KAIS.** Ho hem verificat
consultant SAP per Service Layer:

- **Comercials:** de 48 comparats, només 2 coincideixen.
- **Grups d'articles:** SAP els numera internament (108, 109, 110…), sense relació amb els codis
  antics.
- **Clients:** tampoc coincideixen, i no hem trobat cap camp a SAP que guardi el codi antic de
  manera fiable (`U_SEICodienllac` només està informat en 10 clients de 500 i la numeració no lliga).
- **Articles:** aquests **sí** que es van preservar a la migració.

Si el dia del canvi Analitza rep codis diferents dels que té, no ho interpreta com un canvi de
sistema: ho interpreta com que **tots els clients històrics han desaparegut i n'han aparegut de nous**.
Es perd l'històric comercial, i els comercials i les famílies de producte queden desvinculats de les
seves vendes anteriors.

La solució és guardar el codi antic a SAP i enviar aquest a Analitza. Als empleats de vendes això
**ja existeix** (`OSLP.U_FCCodiKais`, informat en 48 dels 49): es tracta d'estendre a clients i grups
d'articles el mateix criteri que ja es va aplicar allà.

---

## Detall de cada camp

### `OCRD.U_FCCodiKais` — Codi de client de l'ERP anterior

- **Contingut:** el codi que tenia el client a KAIS (8 dígits, per exemple `00001066`).
- **Qui l'omple:** Agrienergia, un sol cop, abans de l'1 de novembre, a partir de la
  correspondència que ens facilita Analitza creuada pel CIF.
- **Manteniment posterior:** cap. Un cop poblat no es torna a tocar.
- **Clients nous:** els donats d'alta a SAP després del canvi el deixen **buit**. És correcte: no han
  existit mai a KAIS i han d'aparèixer com a clients nous.

### `OCRD.U_FCNewCardCode` — Codi del client successor

- **Contingut:** el `CardCode` del client nou, quan un client es desactiva i se n'obre un altre per
  canvi de raó social.
- **Qui l'omple:** Agrienergia, cada vegada que es dona aquest cas.
- **Per defecte:** buit.
- Reprodueix una funcionalitat que l'ERP anterior ja tenia i que Analitza consumeix per no
  comptabilitzar un canvi de raó social com un client perdut més un client guanyat.

### `OITB.U_FCCodiKais` — Codi de grup d'articles de l'ERP anterior

- **Contingut:** el codi antic del grup (6 dígits, per exemple `010001`).
- **Qui l'omple:** Agrienergia, un sol cop, abans de l'1 de novembre. El codi es pot deduir del nom
  del grup, que actualment té el format `010001-BLAT SUPER FORÇA`.

**Consulta per a vosaltres:** ¿es poden crear camps d'usuari sobre `OITB` en aquesta instal·lació?
No ens consta que n'hi hagi cap i no volem donar-ho per fet. Si no és possible, digueu-nos-ho: tenim
una alternativa (llegir el codi del propi nom del grup), menys robusta però viable.

---

## Consideracions

**Convenció de noms.** Fem servir el prefix `U_FC`, que és el que ja porten els camps propis
d'Agrienergia (`U_FCCodiKais`, `U_FCObservacions`, `U_FCVolPotencial`…), per distingir-los dels
`U_SEI` de la implantació.

**Cap camp obligatori ni amb valors per defecte.** Els tres han de poder quedar buits sense bloquejar
l'alta d'un client ni d'un grup d'articles.

**Només lectura des de la nostra banda.** El procés que alimenta Analitza llegeix SAP per Service
Layer amb un usuari de només lectura i **no escriu mai a SAP**. La població d'aquests camps es farà
per la via que ens indiqueu com a correcta.

**La població ha de ser completa.** Si un client que ja existia es queda amb el camp buit, el procés
no pot distingir-lo d'un client nou i Analitza el comptabilitzarà com a tal. No hi ha manera
automàtica de detectar-ho a posteriori, per això la data límit és l'1 de novembre i no el mateix dia
del canvi.

---

## Resum de dates

| Quan | Què |
|---|---|
| Al més aviat possible | Creació dels tres camps |
| Fins al 31 d'octubre | Població de `U_FCCodiKais` a clients i grups d'articles |
| **1 de novembre** | Tot creat i poblat, verificat |
| **2 de novembre** | Es comença a treballar amb SAP; Analitza passa a llegir del nou origen |

---

Qualsevol dubte o si veieu una manera millor de resoldre-ho, digueu-m'ho i ho parlem.

Atentament,
Oscar Hijazo
Agrienergia
ohijazo@agrienergia.com
