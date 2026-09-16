# Resposta a Sistemes — 16/09/2026

**Assumpte:** RE: Integració Analitza CM amb SAP B1 — punt 8: la carpeta és a `AE01SAPRDP` i s'ha de crear

*(El text per enviar comença a "Hola". Al final hi ha una nota interna que NO s'envia.)*

---

Hola,

Les dues respostes curtes: **`AE01SAPRDP`**, i **s'ha de crear**, encara no existeix.

Ho desenvolupo una mica per si de cas, que és una carpeta nova en una màquina compartida.

## On va: `AE01SAPRDP` (192.168.11.239)

A `AE01SAPSQL` no hi ha d'anar res de nou. Allà ja hi corre el que ha de córrer —el job
`Analitza_ETL_Daily` de les 03:00, que fa anys que hi és— i a partir del novembre és la màquina més
crítica que tenim: preferiria no afegir-hi binaris d'aplicació.

El que va a `AE01SAPRDP` és **la peça nova**, la que llegeix SAP per l'API i deixa les dades a punt
perquè el job de les 03:00 les transformi. Són dos planificadors encadenats en dues màquines:

| Quan | On | Què |
|---|---|---|
| 02:45 | `AE01SAPRDP` | `SapB1AnalitzaSync.Worker.exe --once`. ~20 segons |
| 03:00 | `AE01SAPSQL` | El job `Analitza_ETL_Daily` de sempre, que llegeix el que ha deixat l'anterior |

Si `AE01SAPRDP` no us va bé, digueu-me quina màquina i la poso allà. L'únic requisit és que arribi a
`AE01SAPSQL` pels ports 50000 i 1433, que segons em vau confirmar queda dins de la mateixa VLAN.

## Si ja està creada: no

No hi ha res instal·lat encara, ni carpeta ni fitxers ni tasca. És el punt 8 sencer, que és
justament el que està esperant.

Per si ho voleu comprovar en un segon:

```powershell
Test-Path C:\Apps\SapB1AnalitzaSync
```

Ha de dir `False`. Si digués `True`, aviseu-me abans de tocar res: voldria dir que hi ha alguna cosa
que no he posat jo.

## Qui la crea

La carpeta buida la creeu vosaltres, perquè va lligada als permisos i els permisos són vostres. El
contingut l'hi poso jo.

```powershell
New-Item -ItemType Directory -Force C:\Apps\SapB1AnalitzaSync
```

I amb això, el repartiment queda així:

| Vosaltres | Jo |
|---|---|
| Crear la carpeta buida | Copiar-hi els fitxers (81 MB de `\\tomatera\Farinera\ohijazo\GAPI07_Analitza\publish`) |
| Crear el compte de servei i donar-li *Log on as a batch job* | Escriure-hi la configuració amb les credencials reals |
| Donar accés a la carpeta al compte de servei **i** a `ohijazo` | Tancar els permisos NTFS de la carpeta |
| Registrar la tasca programada de les 02:45 | Provar-la i verificar la cadena de punta a punta |

**Dues coses que van amb la carpeta i que val la pena no perdre de vista**, perquè són el motiu que
això no sigui només copiar fitxers:

- **Els permisos.** Dins d'aquella carpeta hi haurà un fitxer de configuració amb credencials de SAP
  i de SQL. Ha de quedar llegible només pel compte de la tasca i pels administradors: a
  `icacls C:\Apps\SapB1AnalitzaSync` no hi ha d'aparèixer ni `Users` ni `Everyone`. Ho tanco jo, però
  ho dic aquí perquè és la raó per la qual la configuració va en un fitxer i **no** en variables
  d'entorn de màquina: `AE01SAPRDP` allotja webservices de col·laboradors externs i qualsevol procés
  de la màquina llegiria les variables d'entorn.
- **El compte que executa la tasca no hauria de ser el meu.** Això és el que potser no vaig explicar
  prou bé l'altre dia: `ohijazo` necessita accés a la carpeta per posar-hi els fitxers, però qui
  **corre** la tasca cada nit ha de ser un compte de servei dedicat i no administrador, amb el dret
  *Log on as a batch job*. Si corre amb el meu usuari nominal, el dia que canvio la contrasenya o no
  hi sóc, la integració s'atura sense que ningú sàpiga per què.

Les comandes exactes (còpia, `icacls`, `Register-ScheduledTask` i els codis d'error) van a l'annex
del correu del 7 de setembre. Si voleu que us les torni a enviar, digueu-m'ho.

## El que queda pendent

Per no perdre el fil, del que us vaig enviar el dia 10 continuen oberts:

| # | Què | De qui |
|---|---|---|
| 3 | Cada quan es copia `AE01SAPSQL` i quants dies es guarda | Sistemes |
| 3 | On deixo els fitxers del FULL diari d'`IntercanviSAP`, si el tiro endavant | Sistemes |
| 6 | ¿Hi ha relay SMTP intern? Si no n'hi ha, tiro provisionalment pel meu compte | Sistemes / Cáliz |
| 8 | Compte de servei + *Log on as a batch job* + accés a la carpeta | Sistemes |
| 8 | Registre de la tasca programada (o el permís perquè la registri jo) | Sistemes |
| — | Qui refresca `DB_FARINERA_TEST`, vosaltres o Seidor | Sistemes |

Del 8 depèn la resta: fins que aquella tasca no corri, el job de les 03:00 acaba cada nit sense
publicar res i Analitza es queda amb les dades velles. **Amb una data orientativa ja em va bé**; el
que voldria evitar és arribar al 2 de novembre sense haver-ho provat mai en aquella màquina.

Gràcies!

Salutacions,
Oscar Hijazo
Agrienergia
ohijazo@agrienergia.com

---

> **Nota interna (no enviar).**
>
> - **La pregunta és bon senyal, però revela què han llegit.** Preguntar si la carpeta ja existeix
>   vol dir que estan mirant de fer-ho, i també que l'annex del 07/09 no l'han obert o no l'han
>   relacionat amb el cos del correu (hi diu carpeta destí i origen dels fitxers en una taula). Per
>   això aquí es repeteix el `New-Item` i el repartiment en comptes de remetre'ls a l'annex.
> - **S'aprofita per insistir en el compte de servei, per tercera vegada.** El 07/09 no ho van
>   respondre, el 10/09 van entendre només l'accés per a `ohijazo`. És el mateix error que ja tenim
>   viu amb `OHijazo` a Service Layer (Bloc A de `memoria_projecte.md` §9): un procés desatès corrent
>   amb un usuari nominal. Si a la resposta següent torna a no aparèixer `svc_gapi07` o equivalent,
>   convé demanar-ho com a línia única en un correu a part, no dins d'una llista.
> - **No s'ha canviat res del repartiment respecte del 10/09** a propòsit: si cada correu mou la
>   frontera, es torna a discutir cada vegada. L'única cosa que s'hi afegeix és qui crea la carpeta
>   buida, que abans es donava per sobreentesa dins de "donar-me accés a `C:\Apps\SapB1AnalitzaSync`"
>   — i aquesta pregunta demostra que sobreentès no estava.
> - **El `Test-Path` no és retòric.** `AE01SAPRDP` té webservices de tercers i cap de nosaltres sap
>   què hi ha creat: si algú hi ha deixat una carpeta amb aquest nom, val més saber-ho abans de
>   copiar-hi 81 MB i tancar-hi els permisos NTFS a sobre.
> - **Es manté la llista de pendents idèntica a la del 10/09.** El punt 3 ja va per la segona vegada
>   sense freqüència ni retenció; si a aquesta tercera tampoc arriba, configurar el FULL diari pel
>   nostre compte i informar-los. El punt 6, si el 30/09 no hi ha resposta, muntar l'opció 3 sense
>   esperar-los.
> - Comprovar la conversió a `.docx` abans d'enviar (`python tools\md2docx.py --check`): el correu
>   del 07/09 va sortir tallat pel final i la pregunta del `DB_FARINERA_TEST` no els va arribar mai.
