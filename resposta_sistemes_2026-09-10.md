# Resposta a Sistemes — 10/09/2026

**Assumpte:** RE: Integració Analitza CM amb SAP B1 — confirmo l'1-2, i concreto el 3, el 6 i el 8

*(El text per enviar comença a "Hola". Al final hi ha una nota interna que NO s'envia.)*

---

Hola,

Gràcies, molt ràpid. Repasso els quatre punts; el gruix és el 8, que és on em demaneu detall.

## 1 i 2 — Accés d'Analitza: fet, però amb un matís que és meu

Perfecte, ho passo a Analitza perquè ho provin.

**Un avís perquè no us tornin la pilota a vosaltres:** la part de VPN sí que és igual que sempre, però
**la de SQL no**. El 31 d'agost vaig rotar la contrasenya del seu compte (`analitza_ro`) i li vaig
acotar els permisos: abans veia tota la base de dades i ara només les vuit taules que li toquen. O
sigui que si proven amb la contrasenya que tenien guardada, **els fallarà el login**, i això té tota
la pinta d'un problema de VPN o de firewall sense ser-ho.

La contrasenya nova els la passo jo directament avui. Si us diuen que no entren, pregunteu-los primer
si han fet servir la nova; si amb la nova tampoc entren, llavors sí que és cosa de xarxa i us aviso.

Servidor, port i base de dades no canvien: `AE01SAPSQL:1433`, `IntercanviSAP`.

Amb això el punt 1-2 el dono per tancat per la vostra banda. Gràcies.

## 3 — Backup

D'acord que el backup complet de la màquina és la xarxa de seguretat, i em serveix. El que necessito
són **dues xifres que encara no tinc**:

- **Cada quan es fa la còpia** de `AE01SAPSQL`.
- **Quants dies en guardeu.**

No és per insistir: és que a partir del novembre la base de dades té una taula petita
(`cfg.client_ship_no`) que **no es pot regenerar**. La resta es refà sola cada nit des de SAP; aquesta
no. Amb aquelles dues xifres sé quant podríem perdre en el pitjor cas, i si és acceptable ho deixem
com està i no us demano res més.

Una cosa que sí que proposo, perquè és barata: **un FULL diari d'`IntercanviSAP` dins del mateix SQL
Server**. Recuperar una taula d'un backup de SQL són cinc minuts i no toca res més de la màquina;
fer-ho des de la còpia de la VM vol dir aixecar el servidor sencer en un altre lloc per treure'n una
taula. Ho configuro jo i vosaltres només em dieu **a quina carpeta han d'anar els fitxers** i si
entren al vostre cicle de cintes.

## 6 — Alertes per correu

Gràcies per mirar-ho amb en Cáliz.

Si cal comprar una llicència, endavant, però **em preocupa la data més que el cost**: mentre no hi
hagi bústia, el procés nocturn no té cap manera d'avisar que ha fallat, i el 2 de novembre és d'aquí
a set setmanes. Per no quedar-nos penjats d'una compra:

- **Abans de comprar res, ¿teniu cap relay SMTP intern** que accepti enviaments sense autenticació des
  de la subxarxa de servidors? Si n'hi ha, no cal llicència ni contrasenya enlloc, i és la solució més
  neta de les tres.
- **Si no n'hi ha**, poso provisionalment el meu compte amb una App Password, per tenir alertes des
  del primer dia. Canviar-ho a la bústia de servei quan arribi és un canvi de configuració de cinc
  minuts, no cal aturar res ni tornar a provar res.

O sigui: la llicència no bloqueja res si em dieu que tiri per una de les altres dues mentrestant.

**Si al final compreu la llicència**, l'adreça que proposo és **`sql-alerts@agrienergia.com`**. No la
lligo a aquest projecte a propòsit: el servidor només pot tenir un remitent per a tots els avisos que
enviï, i el dia que hi hagi altres processos nocturns sortiran d'aquí mateix. Als destinataris els
arribarà com a **«SQL Server AE01SAPSQL»**, que és el que interessa saber d'entrada quan et salta un
avís de matinada.

Un detall perquè no compreu el que no toca: **ha de ser una bústia d'usuari amb llicència, no una de
compartida**. Les compartides són gratuïtes però no poden iniciar sessió, i el SQL Server s'ha
d'autenticar amb usuari i contrasenya. Li cal:

| | |
|---|---|
| Bústia | D'usuari, amb llicència (una Business Basic ja val) |
| Configuració | *Authenticated SMTP* habilitat en aquell compte |
| Credencial | Una App Password |

I si em dieu una adreça vostra o una llista de Sistemes, la poso com a **Reply-To**: així, si algú
contesta una alerta, no cau en una bústia que no llegeix ningú.

## 8 — El procés d'`AE01SAPRDP`

Contesto les vostres preguntes en ordre.

**¿És un .exe o un .bat?** Un `.exe`: `SapB1AnalitzaSync.Worker.exe --once`. La publicació és
autocontinguda, així que **no cal instal·lar cap runtime** ni res a la màquina. Són uns 81 MB dins de
`C:\Apps\SapB1AnalitzaSync` i no toca res de fora d'aquella carpeta.

**¿Tasques programades?** Sí, una: diària a les 02:45, triga uns 20 segons. Llegeix de SAP i escriu a
`IntercanviSAP`. No obre cap port ni exposa cap servei.

**¿Accés a la carpeta amb el meu usuari?** Sí, això és una de les dues coses. Però **n'hi ha una
segona que és la important i que potser no vaig explicar prou bé**:

> El compte que **executa** la tasca no hauria de ser el meu.

`ohijazo` és un usuari nominal: si canvio la contrasenya o algun dia no hi sóc, la integració s'atura
sense que ningú sàpiga per què. I com que al costat de l'executable hi ha un fitxer amb credencials de
SAP i de SQL, qui tingui aquell usuari les té. Per això demano **un compte de servei dedicat, no
administrador**, amb el dret ***Log on as a batch job*** a `AE01SAPRDP`. Els permisos d'aquest compte
els seguiu controlant vosaltres; a mi no em cal ser administrador de la màquina.

Queda així:

| Vosaltres | Jo |
|---|---|
| Crear el compte de servei i donar-li *Log on as a batch job* | Copiar els fitxers i escriure-hi la configuració |
| Donar accés a `C:\Apps\SapB1AnalitzaSync` a aquell compte i a `ohijazo` | Tancar els permisos NTFS de la carpeta |
| **Registrar la tasca programada** (comandes exactes a l'annex del correu anterior) | Provar-la i verificar la cadena de punta a punta |

He posat el registre de la tasca a la vostra columna perquè **registrar una tasca que corre amb un
altre compte demana drets d'administrador**, i no crec que valgui la pena donar-me'ls per a això. Són
tres comandes i us les vaig deixar escrites. Si preferiu el contrari i em doneu el permís puntual, ho
faig jo i us ho torno; el que sigui més còmode.

**Ports:** confirmat i no cal que hi feu res. He comprovat que `AE01SAPSQL` és `192.168.11.238`, o
sigui que la sortida de `.239` cap a `.238` pels ports 50000 i 1433 queda dins de la mateixa VLAN,
com dèieu.

## I una de nova, de menys prioritat

Al correu de l'altre dia se'm va quedar fora un tros pel camí —el document se'm va tallar al final,
disculpeu—, així que aquesta pregunta no us va arribar mai:

**`DB_FARINERA_TEST` gairebé no té documents.** Té els clients i els articles de debò, però només 62
línies d'albarà, i inventades. Això vol dir que fins ara estic validant la integració sobre un
decorat: els números quadren entre ells i no proven gran cosa. Si es pogués refrescar amb una còpia de
la productiva, la qualitat de la prova abans del novembre canviaria molt.

**¿Ho hauríeu de fer vosaltres o Seidor?** Si és cosa d'ells ho demano jo i no us hi fico; només
necessito saber a qui li toca.

## Resum del que necessito

| # | Què | De qui |
|---|---|---|
| 3 | Cada quan es copia `AE01SAPSQL` i quants dies es guarda | Sistemes |
| 3 | On deixo els fitxers del FULL diari, si el tiro endavant | Sistemes |
| 6 | ¿Hi ha relay SMTP intern? Si no, tiro pel meu compte provisional | Sistemes / Cáliz |
| 8 | Compte de servei + *Log on as a batch job* + accés a la carpeta | Sistemes |
| 8 | Registre de la tasca programada (o el permís perquè la registri jo) | Sistemes |
| — | Qui refresca `DB_FARINERA_TEST`, vosaltres o Seidor (pregunta nova) | Sistemes |

Del punt 8 és del que depèn tota la resta: fins que no corri en aquella màquina, el job de les 03:00
acaba cada nit amb `ABORTED_STALE_MIRROR` i Analitza no rep dades noves. **Si em dieu una data
orientativa, ja em va bé**; el que no puc és arribar al 2 de novembre sense haver-ho provat mai.

Gràcies!

Salutacions,
Oscar Hijazo
Agrienergia
ohijazo@agrienergia.com

---

> **Nota interna (no enviar).**
>
> - **El punt 1-2 ja no és un blocatge.** Analitza ja té VPN i accés a `AE01SAPSQL:1433`, i les
>   credencials de VPN són les de sempre: no cal que Sistemes ens enviïn cap endpoint. Això
>   desmunta la meitat del Bloc B de `memoria_projecte.md` §9 i la línia de Sistemes de la taula de
>   blocatges del runbook. L'únic que queda per handoff és **passar la contrasenya rotada**.
> - **El matís de les credencials no és cosmètic.** `analitza_ro` es va rotar el 31/08/2026 i el
>   mateix dia va sortir de `db_datareader` (`sql/security/create_analitza_user.sql`). Si Analitza
>   prova amb la contrasenya vella, el símptoma és un login fallit que sembla de xarxa, i el
>   diagnòstic se'n va cap a Sistemes durant dies. Val la pena avisar-los a tots dos alhora.
> - **El punt 3 no està contestat.** Han tornat a respondre el mateix del juny ("fem backup de la
>   VM") sense donar ni freqüència ni retenció, que és exactament el que se'ls demanava. És la
>   segona vegada. Si a la tercera tampoc arriba, val més configurar el FULL diari pel nostre compte
>   i informar-los, que no pas seguir demanant-ho.
> - **El punt 6 pot encallar-se en una compra.** "Ho parlem amb en Cáliz + cal comprar llicència" és
>   la manera com un pendent es converteix en un pendent de sis setmanes. Per això el correu els
>   ofereix dues sortides que no depenen de la compra. Si el 30 de setembre encara no hi ha resposta,
>   muntar l'opció 3 sense esperar-los.
> - **El punt 8: han entès la meitat.** Han entès l'accés per a `ohijazo` i no el compte de servei.
>   Si es deixa passar, la tasca acabarà corrent amb el compte nominal, que és el mateix problema que
>   ja tenim amb `OHijazo` a Service Layer (llicències, Bloc A). No deixar que passi dues vegades.
> - **`AE01SAPSQL` = `192.168.11.238`** comprovat per DNS el 10/09/2026. Ja no cal preguntar-ho.
> - **El .docx que va sortir el 07/09 estava tallat.** Va del final del punt 8 directe a l'annex: hi
>   falten la secció "Una última, de menys prioritat" (el refresc de `DB_FARINERA_TEST`) i tot el
>   comiat amb la signatura. Per això no han contestat aquella pregunta — no els va arribar. La font
>   completa és `correu_sistemes_2026-09-07.md`. **Comprovar la conversió abans d'enviar aquesta**:
>   comptar que hi són l'última secció i la signatura, no només que el fitxer obri.
> - El refresc de `DB_FARINERA_TEST` és el que limita la validació (`gapi07_test_db_sense_documents`):
>   amb 62 línies inventades no es pot comparar res de debò contra `baseline`.
