> # ⛔ SUPERAT — NO ENVIAR (16/09/2026)
>
> Aquest correu li demana a l'Olga que triï entre tres opcions i que organitzi la classificació de
> 782 articles. **Les dues coses han quedat sense sentit**: mesurat contra l'històric de vendes de
> KAIS, el **98,53%** de la facturació passa pels articles que SAP ja té classificats, i dels 782
> només **28 han facturat res** — la resta són recanvis, EPI's i palets que no es venen. La feina
> real són **vuit articles**, i la proposta de família per a cadascun ja està calculada.
>
> Enviar-lo tal com està la faria decidir una cosa que els números ja han decidit, i li obriria un
> projecte que no existeix.
>
> El detall i les xifres, a `docs/memoria_projecte.md`, *Les famílies: el problema dels 782 articles
> no existia*. Si algun dia cal escriure-li, ha de ser per confirmar vuit línies, no per triar.
>
> Es conserva perquè la taula de facturació per família i el raonament de les tres opcions segueixen
> sent bons; el que ha canviat és la pregunta.

---

# Correu a l'Olga — les famílies de producte a Analitza a partir del 2 de novembre

**Per a:** Olga
**CC:** lbutinya@agrienergia.com · (Adrià Arnau, Analitza CM, si es vol que hi sigui)
**Assumpte:** Analitza: com s'agruparan els productes per famílies a partir del 2 de novembre — cal una decisió comercial

*(El text per enviar comença a "Hola Olga". Al final hi ha una nota interna que NO s'envia.)*

---

Hola Olga,

El 2 de novembre l'Analitza deixarà de rebre les dades del KAIS i les rebrà de la SAP. Per a tu no
hauria de canviar res: l'aplicació és la mateixa i els clients i els productes també. Però hi ha una
cosa que no puc decidir jo i que sí que et canviaria el dia a dia, i és **com s'agrupen els productes
per famílies**.

L'Adrià, d'Analitza, em diu que això ho ha de decidir el departament comercial, que és qui fa servir
l'aplicació, i em recomana parlar-ho amb tu.

## Per què importa

A la fitxa de client, l'anàlisi de productes s'agrupa per família i cada família porta les alertes
del tipus *«producte que hauria d'haver tornat a comprar en els darrers 60 dies»*. Com més famílies
hi ha, més diluïdes queden aquestes alertes. Analitza recomana **no passar de ~25 famílies**. Avui
en teniu **12**:

| Família | Facturació gen–ago 2026 |
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

Les **subfamílies** (20: FORÇA, MITJA FORÇA, PANIFICABLE, MEULE…) no estan en discussió: aquestes
surten d'un camp de la SAP que ja està informat i es mantenen igual.

## La decisió

| | Què li enviaríem a Analitza | Conseqüència |
|---|---|---|
| **A** | Els **110 grups d'article** de la SAP | Tots els productes queden classificats, però passeu de 12 famílies a 110 i **perdeu la comparació amb els anys anteriors**: són agrupacions diferents, amb noms diferents |
| **B** | La **família comercial** de la SAP: són literalment aquestes 12 | Es manté tot com ara… **però ara mateix el camp només està omplert en 198 dels 980 productes actius** |
| **C** | La B, **omplint abans el camp** dels productes que falten | És la bona. Demana feina abans del 2 de novembre |

L'opció A la desaconsello: 110 famílies és molt per sobre del que recomana Analitza i us trencaria
l'històric de tota l'anàlisi per famílies.

L'opció B tal com està avui vol dir que el 2 de novembre **8 de cada 10 productes actius et
sortirien a la fila «sense assignació»**, que avui val amb prou feines l'1,4% de la facturació. No
seria un error de l'aplicació, seria que la informació no hi és.

## El que en surt: una feina, i probablement no és tanta

Aquesta classificació **ja existeix al KAIS** —per això avui gairebé no teniu productes sense
família—, i a la SAP el camp hi és però s'ha quedat buit en la majoria d'articles. O sigui que no
caldria decidir de nou la família de cada producte: es tractaria de **traslladar-hi el que ja
teníeu**. Si em confirmeu que la classificació del KAIS és la bona, miro si es pot fer d'una
tacada en comptes d'article per article, i llavors la feina vostra es redueix a revisar-ho.

Us puc passar la llista exacta dels **782 productes actius sense família** perquè es reparteixi.

Dues coses petites que arreglo jo un cop em digueu:

- A la SAP conviuen `KM0` i `KM 0` —amb un espai enmig— com si fossin dues famílies diferents. La
  segona té un sol article.
- Hi ha una família `SUBPRODUCTE` a la SAP que a l'Analitza no existeix, i una `PROVES1` que sembla
  de proves. Digueu-me si les voleu, si les fusiono o si les deixo fora.

## El que et demano

1. **Quina de les tres opcions** (jo recomano la C).
2. Si és la C, **qui ho porta pel vostre costat** i si em confirmeu que la classificació del KAIS
   és la que val.

**La data límit real és l'1 de novembre**, però no és una feina d'un dia i el novembre ja hi haurà
prou coses obertes. Amb una resposta aquest setembre anem bé; si arriba al final, l'opció C deixa
de ser possible i ens quedem amb la B tal com estigui el camp aquell dia.

Si ho prefereixes ho veiem en deu minuts amb l'aplicació al davant, que amb les pantalles a la vista
es decideix millor que per correu.

Gràcies,

Salutacions,
Oscar Hijazo
Agrienergia
ohijazo@agrienergia.com

---

> **Nota interna (no enviar).**
>
> - Xifres mesurades contra `DB_FARINERA_TEST` (01/09/2026): `OITM.U_SEIFamCialCat` té 14 valors
>   distints —les 12 de l'Adrià, més `SUBPRODUCTE` i `KM 0` amb espai—; sense classificar **1.776 de
>   2.028** al cens sencer i **782 de 980** entre els actius. La xifra que decideix és la dels
>   actius: el cens porta anys d'articles de baixa que no arriben a Analitza.
> - És una còpia de productiva i va endarrerida: abans de donar la xifra per bona el novembre, cal
>   repetir-ho amb `--probe` contra `DB_FARINERA_PROD`.
> - **No està mesurat quin pes en facturació tenen els 782.** Per compte és 8 de cada 10; per euros
>   pot ser molt menys. Si l'Olga ho pregunta, es pot calcular creuant amb les línies d'albarà.
> - La subfamília surt de `U_SEISubFamCialCat`, que és el que ja llegim avui i quadra amb les seves
>   20 subfamílies. No es toca.
> - L'afirmació «la classificació ja existeix al KAIS» és una **inferència**: a Analitza només
>   195.233 € cauen a la fila buida, o sigui que al KAIS hi és. No està verificat contra el KAIS.
>   Per això al correu va com a pregunta, no com a fet.
> - Si `resposta_adria_3.docx` encara no ha sortit, cal treure'n la frase que li pregunta a l'Adrià
>   si escrivim nosaltres a l'Olga o ho porta ell: si aquest correu s'envia, ja està decidit.
