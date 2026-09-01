# Correu de l'Adrià Arnau (Analitza CM) — 01/09/2026

> Resposta a `resposta_adria_2.docx`, enviat el 31/08/2026.
>
> Transcrit del PDF d'Outlook (`docs/Re_ Integració Sap i Analitza_ Oscar Hijazo - Outlook.pdf`),
> que porta una font Type3 sense taula `ToUnicode`: la capa de text són índexs de glif i no es pot
> ni llegir ni cercar. Mateix problema que els PDF de maig de 2025. **La transcripció és la font.**

---

Bon dia Oscar,

D'acord m'anoto lo de passar el llistat de clients.

- El tema de les adreces, clar si s'esborren i es renumeren les següents ens afectaria molt ja que
  s'assignarien historials a adreces diferents. Segurament esborreu poques adreces però només
  faltaria que passés un cop amb una adreça antiga perquè afectés a les adreces actuals.

  Nosaltres internament quan no s'ens passa una adreça (client_locations), s'esborra de l'aplicació
  i és com si no existís el client, però mantenim l'històric d'albarans per si ha sigut un error.
  Amb la qual cosa si més endavant es torna a donar d'alta una altra adreça agafaria tot l'històric.
  Si ens poguéssim protegir d'això seria genial, però ja et dic potser a la pràctica no ho feu mai?

- Els /100, prefereixo que ho envieu en euros perquè va ser un bon maldecap en un inici sobretot pel
  tema marges així ja ho deixem com ha d'anar i ens evitem maldecaps futurs. Anoto per canviar-ho.

- Tema filtre de clients, cap problema mantenim el filtre.

- Tema família i subfamilia, actualment això és el que veiem (la fila que no te nom és els que no
  tenen assignació).

  *(dues captures de la seva aplicació — transcrites a sota)*

  Idealment ens hauriem de mirar de moure pels mateixos números, això al final ho acaba decidint el
  departament comercial que és qui fa servir l'aplicació. Nosaltres sempre aconsellem que sobretot
  el tema de famílies sigui suficient generic com perquè si un client canvia de packaging (de 1
  paquet de 1kg a 2 de 500g) o per un producte molt similar que potser no s'ha pogut lliurar perquè
  no hi havia estoc o pel que sigui, no generi una nova família sinó que quedi tot allà mateix i no
  generi més "soroll". Solem aconsellar que les famílies no passin d'unes 25, les subfamilies ja et
  dic que hi ha més marge perquè l'anàlisi és diferent. Potser la més indicada de decidir-ho seria
  l'Olga, l'impacte afecta sobretot a la fitxa de client on s'agrupa per famílies i es mostren
  "alertes", quantes menys famílies queden les alertes més "camuflades", com més famílies més
  soroll... exemple:

  *(captura de l'ANÀLISI DE PRODUCTES, amb les alertes agrupades per família)*

- Atributs de client:

  La raó social es va decidir incorporar a posterior-hi, per no demanar-ho a kais vam implementar la
  solució del sql que extreu la primera part del codi de client (ignora adreça), buscant canvis de
  codi,etc,etc. Si ens la passeu directe a la taula de clients perfecte, igual que el camp actiu que
  es va voler reaprofitar perquè aparegués als filtres.

- Costos i històric, els 90 dies sí que esborra. Bé de fet, "reemplaça" a partir de la data mínima
  que li passem. Com que la base de dades nova la data mínima serà el 2 de novembre mai esborrarà
  res de la base de dades antiga. El problema seria si durant el mateix dia 2 s'inserrissin dades a
  les 2 base de dades, si l'1 de novembre s'insereix a l'antiga i el 2 a la nova no hi haurà
  problemes, si no ha de ser així avisa que revisarem el codi.

  Així que quedaria amb el cost del moment i mirem al desembre de corregir-ho.

- Val, ja em dius pel tema de la connexió que ara per ara és dels punts crítics per veure que tot
  funciona o si hem de fer algun desenvolupamnet de vpn.

- Comentari general: Quan tinguem accés a les dades i puguem executar el validador et comenten si
  veiem alguna cosa extranya. Però ja has vist que sobre les dades nosaltres modifiquem les sql per
  adaptar si hi ha alguna cosa que no acaba de cuadrar, si alguna cosa t'ha de suposar molta feina,
  etc. ho ajustem nosaltres o ho mantenim com està. Per part nostra no hi ha problema.

Salutacions,

Adrià

---

## Les captures: què tenen avui a Analitza

Xifres YTD (1 gen. 2026 – 31 ag. 2026). **La fila sense nom són els articles sense assignació**, i
val el mateix a les dues taules: 195.233 €.

### FAMÍLIA — 12 amb nom + la buida

| Família | YTD |
|---|---|
| TRADICIONALS | 5.520.909 € |
| MOULIN DE COLAGNE | 2.244.114 € |
| ESPECIFICA | 1.373.777 € |
| GRANEL | 994.978 € |
| ALTRES CEREALS | 901.955 € |
| ECOLÒGIQUES | 831.714 € |
| CAN TRULL | 653.963 € |
| INTEGRALS | 463.399 € |
| KM0 | 291.427 € |
| PIZZA | 238.363 € |
| ALTRES ELABORACIONS | 195.182 € |
| PROVES1 | 1.744 € |
| *(sense assignació)* | 195.233 € |

### SUBFAMILIA — 20 amb nom + la buida

| Subfamília | YTD |
|---|---|
| FORÇA | 2.095.173 € |
| MITJA FORÇA | 1.789.015 € |
| PANIFICABLE | 1.636.721 € |
| ESPECIFICA | 1.373.777 € |
| MEULE | 1.005.366 € |
| GRANEL | 994.978 € |
| HAUBANNE | 967.840 € |
| ALTRE CEREAL | 901.955 € |
| ECOLÒGICA | 831.714 € |
| CAN TRULL | 653.963 € |
| INTEGRAL | 343.206 € |
| BIO | 256.506 € |
| PIZZA | 238.363 € |
| ÉS FARINA DE GIRONA | 201.659 € |
| ALTRA ELABORACIÓ | 195.182 € |
| ALTRES INTEGRALS | 120.193 € |
| ALTRES KM0 | 89.768 € |
| ALTRES MC | 14.401 € |
| PROVA1 | 1.744 € |
| ALTRE CEREAL BIO | 0 € |
| *(sense assignació)* | 195.233 € |

La tercera captura és la fitxa **ANÀLISI DE PRODUCTES → PRODUCTES**, amb les files agrupades per
família (`ALTRES CEREALS`, `CAN TRULL`, `ECOLÒGIQUES`, `INTEGRALS`, `SENSE DEFINIR`, `TRADICIONALS`)
i una icona d'alerta per família: *«Producte que hauria d'haver tornat a comprar en els darrers 60
dies»*. És el mecanisme que es dilueix si les famílies es multipliquen.

---

## Estat de les cinc preguntes

| | Pregunta | Resposta |
|---|---|---|
| 1 | El `/100` | ✅ **En euros.** Ho treu ell de les seves SQL. No canvia res del nostre costat |
| 2 | Famílies | ⏳ **Ho decideix l'Olga**, no ell. Recomanació d'Analitza: **no passar de ~25** |
| 3 | Congelar el número d'adreça | ✅ **El vol** — i el motiu és pitjor del que sabíem (veure sota) |
| 4 | Acumula o substitueix | ⚠️ **Substitueix**, des de la data mínima que li enviem (veure sota) |
| 5 | `RAÓ SOCIAL` i `ACTIU` | ✅ **Res a fer.** Els llegeix de `est_clients.name` i `est_clients.active` |

De propina: manté els seus filtres de client, i el cost d'octubre es corregeix al desembre amb una
càrrega puntual, com estava proposat.
