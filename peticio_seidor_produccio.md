# Petició a SEIDOR — accés i camps d'usuari a la companyia productiva

**Per a:** carles@seidor.com
**CC:** lbutinya@agrienergia.com
**Assumpte:** GAPI07 (Analitza CM) — autoritzacions de `proceso` i `U_FCCodiKais` a la companyia productiva

*(El text per enviar comença a "Hola Carles". Al final hi ha una nota interna que NO s'envia.)*

---

Hola Carles,

Gràcies per la resposta d'avui sobre GAPI01 i GAPI09. Em queden tres coses de la companyia
**productiva**, i no les puc fer jo perquè no hi tinc accés. Totes tres tenen data: **1 de novembre**.

**1. `U_FCCodiKais` a producció — la important.** Els camps d'usuari són per companyia, i aquest el vaig
crear i omplir a la de **test** (us ho vaig comunicar el 26 d'agost). A la productiva no sé ni si
existeix.

El procés que alimenta Analitza CM emet l'identificador de cada client com
`COALESCE(U_FCCodiKais, CardCode)`: qui ve de KAIS conserva el seu codi de 8 dígits i qui neixi a SAP
porta el seu `CardCode`. **Si a la productiva el camp no hi és o arriba buit, Analitza rep ~4.700
clients com si fossin nous** i perd tot l'històric de vendes associat. Igual amb `OITB` per a les
famílies i amb `OSLP` per als comercials, que aquell ja ve poblat.

Dues preguntes concretes:

- Els camps `OCRD.U_FCCodiKais` i `OITB.U_FCCodiKais` **existeixen a la companyia productiva**?
- **La migració de dades mestres a producció hi portarà el codi de KAIS?** És el moment natural de
  fer-ho, perquè la correspondència la teniu vosaltres a l'origen. Si no entra per aquí, cal decidir
  qui l'omple i com, i això és feina de dies.

**2. Autoritzacions de lectura per a `proceso`.** Avui he provat la connexió contra la productiva i el
`Login` entra correctament, però la primera lectura respon:

```
403  {"code":-3000,"message":"The logged-on user does not have permission to use this object."}
```

Les autoritzacions són per usuari **i per companyia**, i a test les té. Necessito **només lectura** a la
productiva sobre: interlocutors comercials amb les seves adreces, articles, grups d'articles, empleats
de vendes, vies de pagament, i albarans, devolucions, factures i abonaments de client. **Cap permís
d'escriptura**: el procés només llegeix.

⚠️ Si el tipus de llicència de `proceso` no permet aquestes autoritzacions, digue-m'ho i ho replantegem
— és millor saber-ho ara que l'1 de novembre.

Això no és només per al dia del tall: **sense lectura no puc mesurar res** de la productiva, i hi ha
comprovacions que, si surten malament, són setmanes de feina (la cobertura dels codis de KAIS, el volum
de documents que ha de baixar la primera càrrega).

**3. Dues confirmacions curtes.**

- La companyia productiva és **`DB_FARINERA`**? El `Login` hi entra, però ho vull sentir de vosaltres:
  és l'única clau que canvio el dia del tall, i si m'equivoco l'error que dona apunta a la contrasenya.
- A la productiva hi haurà d'anar un parell de retocs que a test he fet jo: esborrar el camp
  `OCRD.U_FCNewCardCode` (va quedar duplicat amb `U_SEICodienllac` i no s'ha omplert mai) i corregir uns
  **67 valors mestres** que porten cometes d'escapament de la migració, perquè una d'elles ens tapava el
  número d'una adreça. **Qui ho fa, si jo no hi entro?**

Gràcies,
Oscar Hijazo
ohijazo@agrienergia.com

---

## Nota interna — NO s'envia

**El que ha destapat això:** no tenir accés a `DB_FARINERA` invalida una pila de passos del runbook que
diuen «ho fa l'Oscar», i la comunicació del 26/08 (*«els creo i els omplo jo»*) només era certa per a
test. Fins avui això no s'havia vist perquè **tot el que s'ha fet s'ha fet a test**.

**L'ordre de prioritat és aquest i no el que semblava.** El 403 bloqueja la mesura, però el que té cua
llarga és `U_FCCodiKais`: si la migració a producció no el porta, omplir 4.700 clients a mà és el camí
crític de tot el projecte, no una tasca de preparació. Per això va de primer al correu, tot i que la
troballa d'avui ha estat el 403.

**El que no se li diu:** que la població a test és de 4.689 de 4.691 i que els 13 clients que no quadren
amb el cens d'Analitza estan mesurats **contra test**, o sigui que la xifra de producció pot ser una
altra. Fer-ho servir com a argument ara convidaria a donar el problema per dimensionat quan no ho està.

**Si contesta només el 403** —que és el fàcil i el que sembla urgent— **cal repreguntar el punt 1 sol**.
És el mateix patró del `/100` amb l'Adrià: dins d'una llista, la pregunta cara es queda sense resposta.
