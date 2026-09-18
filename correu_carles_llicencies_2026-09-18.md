# Correu a en Carles (SEIDOR) — usuaris de Service Layer i licenciament indirecte

**Per a:** Carles (SEIDOR)
**CC:** lbutinya@agrienergia.com
**Assumpte:** RE: Usuaris de Service Layer — inventari dels processos i petició d'usuaris indirectes

*(El text per enviar comença a "Hola Carles". Al final hi ha una nota interna que NO s'envia.)*

---

Hola Carles,

Gràcies per la resposta, em va molt bé el criteri. He anat a mirar-m'ho projecte per projecte abans
de demanar-te res, i te'n passo el resultat.

## El que hi ha avui

Quatre processos connecten al Service Layer, i **tots quatre ho fan amb el meu usuari `OHijazo`**:

| Procés | Quan es connecta |
|---|---|
| **GAPI07** — Analitza CM | Cada nit a les **02:45**, durant uns 20 segons |
| **GAPI03** — CRM | **Cada 15 minuts**, tot el dia, més una reconciliació a les 03:00 |
| **Preparació de comandes de venda** | En qualsevol moment de la jornada |
| **Actualitzador de preus/tarifes** | En qualsevol moment de la jornada |

(Hi ha una macro d'Excel per a transportistes que també hi entra, però és d'un sol ús per a una
migració i va amb les credencials de qui l'executa: aquella no compta.)

## Per què crec que no puc aprofitar gaire l'excepció

Aplicant el teu criteri —que es pugui **assegurar** que no coincideixen— em surt que gairebé cap
parella el compleix:

- **GAPI03 no és un procés nocturn**: es connecta cada quart d'hora durant tot el dia, així que està
  pràcticament sempre en sessió i no pot compartir amb res.
- **Els dos interactius** poden executar-se a qualsevol hora, o sigui que no puc assegurar res, ni
  entre ells ni respecte del nocturn.

I hi ha un detall que em fa ser més prudent del que seria: si no vaig errat, **cada `Login` manté la
llicència ocupada els 30 minuts del `SessionTimeout` tret que el procés faci `Logout`**. Si és així,
el que compta no és l'estona que treballa un procés sinó l'estona que té la sessió oberta, i llavors
«no coincidir» és bastant més estret del que sembla. **Confirma-m'ho si pots**, perquè si m'equivoco
en això, el càlcul canvia.

## El que et demano

**Comencem pel que no costa res: GAPI07 amb `proceso nocturno`.**

És el procés que millor hi encaixa de tots quatre: finestra fixa de matinada, vint segons de feina i
tanca sessió en acabar. Si `proceso nocturno` està lliure a les 02:45, és una llicència que ens
estalviem.

**Per poder-ho assegurar només necessito una cosa: a quina hora corren GAPI01 i GAPI09.** Amb això et
confirmo que no ens trepitgem i, si cal, moc la nostra tasca — canviar-li l'hora em costa un minut i
no depèn de ningú. Demanaria **mitja hora de separació** i no cinc minuts, perquè el Service Layer no
porta bé dos `Login` del mateix usuari amb poca diferència.

**Per als altres tres, el panorama és pitjor i sí que et demanaria usuaris propis:**

| Procés | Per què no pot compartir |
|---|---|
| **GAPI03** | Cada quart d'hora, tot el dia. Pràcticament sempre en sessió |
| **Preparació de comandes** | A qualsevol hora, sense finestra previsible |
| **Actualitzador de preus** | Igual |

Si s'han de prioritzar, **el primer seria GAPI03**, que és el que està connectat permanentment i el
que ara mateix fa més difícil garantir res a la resta.

**Un detall sobre el compte de GAPI07**, tant si és `proceso nocturno` com si n'és un de nou: només
necessita **lectura**. No escriu mai a SAP, i les entitats són aquestes nou: `BusinessPartners`,
`Items`, `ItemGroups`, `SalesPersons`, `WizardPaymentMethods`, `DeliveryNotes`, `Returns`,
`CreditNotes` i `Invoices`. Si el compte no té permís d'escriptura, la restricció la garanteix el
propi SAP i no la meva bona fe.

## I una segona pregunta, d'una altra mena

Aquesta em preocupa més que els comptes tècnics, i preferiria tenir-la contestada **abans** de posar
GAPI07 en producció el **2 de novembre**.

**Com es llicencia el consum de dades de SAP des de l'Analitza CM?**

GAPI07 hi porta cada nit clients, articles, línies d'albarà i cobraments, i a l'Analitza hi entren
diverses persones d'Agrienergia a consultar-los. Entenc que el licenciament indirecte va de **qui
acaba consumint la informació**, no de quants processos tècnics es connecten, i que fer-ho per l'API
oficial hi ajuda però no ho resol per si sol.

No és una pregunta retòrica: si això demana llicències addicionals, prefereixo saber-ho ara i
pressupostar-ho, que no pas descobrir-ho en una revisió.

Gràcies,
Oscar Hijazo
Agrienergia
ohijazo@agrienergia.com

---

> **Nota interna (no enviar).**
>
> **L'objectiu real no és optimitzar llicències, és treure `OHijazo` de tot arreu.** Avui quatre
> processos depenen de la contrasenya d'una persona: el dia que canviï o no hi sigui, s'aturen tots
> quatre i ningú relacionarà les coses. Per això la petició està ordenada per prioritat i no com un
> tot-o-res: qualsevol compte dedicat ja és una millora estricta.
>
> **S'obre per `proceso nocturno` a propòsit**, i no per demanar quatre usuaris. GAPI07 és el que
> millor hi encaixa —finestra fixa, vint segons, amb `Logout`— i si hi cap, és una llicència que no
> es compra. També fa la petició més fàcil de dir que sí: comença per allò que no li costa res i
> demostra que s'ha mirat d'estalviar abans de demanar.
>
> **L'única condició és saber quan corren GAPI01 i GAPI09.** Si no ho diu, això no es pot tancar:
> «no coincidim» ha de ser una comprovació, no una esperança. Moure la nostra tasca de les 02:45 és
> gratis i no depèn de ningú, o sigui que la flexibilitat la posem nosaltres.
>
> **La pregunta del `SessionTimeout` es fa com a pregunta i no com a afirmació** a propòsit. Surt de
> `P:\ActualitzadorPreusSap\docs\acces_i_llicencies.md`, on està documentat i verificat, però si
> resulta que els processos amb `Logout` alliberen de seguida —que és el que fem nosaltres— l'excepció
> és més ampla del que dic i potser en tenim prou amb dos comptes. Val més que ho confirmi ell.
>
> **El que NO s'hi diu, i és deliberat:** que `GAP001` també corre amb `OHijazo` sondejant cada dos
> minuts. No és projecte nostre i posar-ho al correu convertiria la petició en una auditoria d'altri.
> Si en Carles pregunta per què n'hi ha tants, llavors sí.
>
> **Tampoc s'hi diu** que `P:\SAP\GAP001_scripts\gap001_config.json` porta la contrasenya de SL i un
> `client_secret` d'Azure AD en clar. Això va per un altre canal i a qui porti aquell projecte: el
> secret s'ha de considerar compromès i rotar.
>
> **La segona pregunta ja es va identificar el 27/08/2026** i no s'havia arribat a fer. És la que en
> una auditoria surt cara, i la que no pot quedar sense resposta escrita abans del cutover.
