# Regla 01 — Accés a SAP Business One

**Prioritat: màxima. Aquestes prohibicions no es negocien ni es relaxen "només per provar".**

## Prohibit

- ❌ **Llegir taules internes de SAP** (`OCRD`, `CRD1`, `OITM`, `ODLN`, `DLN1`, `OINV`, …) encara
  que la instància SQL sigui accessible i la consulta sigui trivial. Això inclou el cross-DB
  `SELECT ... FROM DB_FARINERA_TEST.dbo.X`, que és exactament el que aquest projecte ha migrat.
- ❌ **Escriure a SAP** per qualsevol via (Service Layer, DI API, SQL directe). GAPI07 és
  estrictament de lectura.
- ❌ **Lliurar credencials de SAP** a Analitza ni a cap tercer. Analitza entra amb `analitza_ro`
  a `IntercanviSAP` i no veu SAP mai.

## Permès

- ✅ Únicament **SAP B1 Service Layer** amb l'**usuari tècnic de només lectura**.
- ✅ Les entitats de l'abast actual: `BusinessPartners` (amb `BPAddresses`), `Items`, `ItemGroups`,
  `SalesPersons`, `WizardPaymentMethods`, `DeliveryNotes`, `Returns`, `CreditNotes`, `Invoices`.

## Per què

L'accés directe a taules no està suportat per SAP, és fràgil davant d'upgrades i FPs, exposa a
**risc de llicenciament indirecte**, fa bypass dels permisos i de la lògica de negoci de SAP, no
deixa cap rastre a l'auditoria de SAP i no és portable a HANA ni a cloud.

## Com aplicar-ho

- Si una necessitat funcional sembla requerir una taula interna, **para i pregunta**. No hi ha
  excepció "temporal": el que entra com a workaround s'hi queda.
- Els SPs de `sql/procs/` llegeixen **`sap_raw.*`**, mai `<SBO_DB>.dbo.*`. Si en un SP hi apareix
  `QUOTENAME(@SBOdb)`, és un bug de regressió.
- Afegir una entitat nova a l'abast requereix decisió explícita, no n'hi ha prou que Service Layer
  l'exposi.
- **No hi ha excepció per validar.** La fidelitat del mirall no es demostra comparant-lo contra les
  taules de SAP, sinó comparant la sortida final (`staging.est_*`) contra `baseline.est_*`, la
  fotografia de `dbo.est_*` presa amb el pipeline antic just abans del tall. Si les 8 taules
  quadren, el mirall és fidel per construcció.
