# Crear l'usuari tècnic de SAP per a Service Layer

El Worker llegeix SAP per Service Layer. Ara ho fa amb **`OHijazo`**, un usuari nominal amb
contrasenya de quatre caràcters. Cal substituir-lo abans que això corri desatès en una màquina
compartida.

## Per què no pot quedar-se com està

- **Auditoria.** Les crides a Service Layer queden als logs de SAP amb el nom de l'usuari. Amb
  `OHijazo`, les lectures nocturnes de l'ETL apareixen com si les fes una persona a les tres de la
  matinada. Si mai cal investigar un accés a dades, no hi ha manera de distingir què va fer el
  procés i què va fer la persona.
- **Continuïtat.** El dia que aquesta persona canviï la contrasenya —o marxi— l'ETL deixa de
  funcionar sense que ningú ho relacioni.
- **Privilegis.** Un usuari nominal té les autoritzacions de la persona. El Worker només ha de
  llegir cinc entitats.
- **On acabarà la contrasenya.** En un fitxer de configuració a `AE01SAPRDP`, que allotja
  webservices de tercers. Val més que sigui la d'un compte que només pot llegir.

## Què crear

A SAP Business One: **Gestió → Inicialització sistema → Autoritzacions → Usuaris**

| Camp | Valor proposat |
|---|---|
| Codi d'usuari | `GAPI07_RO` |
| Nom | `GAPI07 Analitza (només lectura)` |
| Correu | el teu, per si SAP envia avisos |
| Contrasenya | llarga, i al gestor de contrasenyes |
| Superusuari | **No** |

## Autoritzacions

Només lectura, i només del que el Worker consulta:

| Entitat de Service Layer | Taula | Per a què |
|---|---|---|
| `BusinessPartners` (amb `BPAddresses`) | `OCRD` + `CRD1` | Clients i les seves adreces |
| `Items` | `OITM` | Articles |
| `ItemGroups` | `OITB` | Famílies |
| `SalesPersons` | `OSLP` | Comercials |
| `WizardPaymentMethods` | `OPYM` | Formes de pagament |
| `DeliveryNotes`, `Returns`, `CreditNotes` | `ODLN`, `ORDN`, `ORIN` + línies | Albarans, devolucions, abonaments |
| `Invoices` | `OINV` | Factures, per als efectes pendents |

A la finestra d'autoritzacions, tot el que sigui **Sense autorització** excepte aquests, que van a
**Només lectura**. Cap permís d'escriptura enlloc: el Worker no escriu mai a SAP, i si algun dia
algú ho intentés, val més que peti.

També ha de poder llegir els UDFs `U_FCCodiKais`, `U_FCNewCardCode`, `U_SEIPOSBC`, `U_SEISEGH1`,
`U_SEISEGH2`, `U_SEIZONAC` i `U_SEISubFamCialCat`. Normalment van amb l'autorització de la taula,
però si la instal·lació té autoritzacions per camp, cal repassar-ho.

## ⚠️ Comprova la llicència abans de res

**Un usuari de SAP Business One consumeix llicència.** Abans de crear-lo, mira quantes en tens
lliures: si no n'hi ha, no podràs crear l'usuari i tot això s'atura.

**Gestió → Llicència → Administració de llicències**

Segons el tipus de llicència que assignis, potser n'hi ha prou amb una de limitada —el Worker només
llegeix— però això depèn del contracte. Si vas just, val la pena preguntar-ho al partner: sol haver-hi
figures pensades per a accessos d'integració que no consumeixen una llicència de nom complet.

Si resulta que no hi ha llicència disponible i no se'n pot comprar cap abans del novembre, digue-ho:
es pot seguir amb `OHijazo` deixant-ho documentat com a decisió conscient, però llavors la
contrasenya s'ha de canviar per una de llarga i no s'ha de tocar mai més.

## Un cop creat

1. Prova'l sense tocar res, canviant l'usuari als user-secrets del Worker:

   ```
   cd P:\GAPI07_Analitza\src\SapB1AnalitzaSync.Worker
   dotnet user-secrets set "ServiceLayer:UserName" "GAPI07_RO"
   dotnet user-secrets set "ServiceLayer:Password" "..."
   $env:DOTNET_ENVIRONMENT='Development'
   dotnet run -- --probe
   ```

   La sonda ha de passar sencera. Si alguna entitat falla amb 401 o amb un error d'autorització, hi
   falta un permís de lectura.

2. Aquesta contrasenya és la que anirà a l'`appsettings.json` de `AE01SAPRDP`. Al gestor.

3. Actualitza també `P:\preparacioComandesVendaSAP\.env` si vols que aquell projecte deixi
   d'anar amb `OHijazo` — **però compte, aquell sí que escriu a SAP** i necessita permisos que
   aquest usuari no ha de tenir. Són usuaris diferents amb necessitats diferents; no els comparteixis.
