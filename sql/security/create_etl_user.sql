/* =========================================================================
   create_etl_user.sql  -  Context d'execucio de l'ETL nocturn

   PER QUE
   -------
   El job Analitza_ETL_Daily es propietat de `sa` i el seu pas no tenia
   context d'usuari, o sigui que `EXEC etl.sp_run_all` corria com a
   **sysadmin**. Mesurat el 31/08/2026.

   Aixo es el que quedava obert de la "Fase 5". La conclusio del 26/08/2026 ja
   deia que revocar l'acces directe a SAP no es una questio de permisos sino de
   sota quin compte corre l'ETL: cap procediment fa referencia a SAP -el codi
   ja no pot- pero el compte si que podria. Mentre el job vagi amb sysadmin, la
   Regla 01 es una convencio d'equip i no una barrera tecnica.

   QUE ES
   ------
   Un usuari **sense login** (`WITHOUT LOGIN`): no es pot fer servir per
   connectar-se de fora, nomes existeix per impersonar-lo. El pas del job
   l'agafa amb @database_user_name i tot el que faci sp_run_all queda dins
   d'IntercanviSAP. Cap altra base de dades del servidor -SAP inclosa- li es
   accessible, i aixo no depen de cap DENY que algu pugui desfer: un usuari
   sense login no te ambit fora de la seva BD.

   QUE POT FER
   -----------
   Exactament el que necessita sp_run_all i res mes:

     etl      EXECUTE + SELECT  els procediments i les vistes de codis KAIS
     sap_raw  SELECT            llegir el mirall
     staging  tot + ALTER       hi escriu; ALTER perque TRUNCATE ho demana
     dbo      SELECT, INSERT,   el swap (TRUNCATE + INSERT), la copia
              DELETE, ALTER     incremental i el check vanished_ids
     audit    SELECT, INSERT,   el registre d'execucions i els warnings
              UPDATE
     cfg      SELECT, INSERT,   llegeix els llindars; el swap hi escriu
              UPDATE            DISCOUNT_AS_PERCENT_PUBLISHED

   No es una llista curta, perque l'ETL toca gairebe tota la base de dades per
   disseny. El que compra no es "menys permisos dins d'IntercanviSAP", es
   **cap permis fora**.

   IDEMPOTENT: es pot executar tantes vegades com calgui.
   ========================================================================= */
USE IntercanviSAP;
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'gapi07_etl')
BEGIN
    CREATE USER gapi07_etl WITHOUT LOGIN;
    PRINT 'Usuari gapi07_etl creat (sense login).';
END
ELSE
    PRINT 'L usuari gapi07_etl ja existia.';
GO

GRANT EXECUTE, SELECT                         ON SCHEMA::etl     TO gapi07_etl;
GRANT SELECT                                  ON SCHEMA::sap_raw TO gapi07_etl;
GRANT SELECT, INSERT, UPDATE, DELETE, ALTER   ON SCHEMA::staging TO gapi07_etl;
GRANT SELECT, INSERT, DELETE, ALTER           ON SCHEMA::dbo     TO gapi07_etl;
GRANT SELECT, INSERT, UPDATE                  ON SCHEMA::[audit] TO gapi07_etl;
GRANT SELECT, INSERT, UPDATE                  ON SCHEMA::cfg     TO gapi07_etl;
GO

/* UPDATE sobre dbo no hi es: el swap fa TRUNCATE + INSERT, mai UPDATE. Si
   algun dia cal, s'afegeix aqui i es documenta per que. */

/* -------------------------------------------------------------------------
   Verificacio. No mirar els GRANT: executar l'ETL de debo impersonant-lo.
   @SkipSwap=0 a proposit no; aixo es una comprovacio, no una carrega.
   ------------------------------------------------------------------------- */
PRINT '--- Permisos de gapi07_etl ---';
SELECT  pe.state_desc, pe.permission_name, SCHEMA_NAME(pe.major_id) AS esquema
FROM    sys.database_permissions pe
JOIN    sys.database_principals pr ON pr.principal_id = pe.grantee_principal_id
WHERE   pr.name = N'gapi07_etl' AND pe.class = 3
ORDER BY esquema, pe.permission_name;
GO

/* Comprovacio manual, quan el mirall sigui fresc:

       EXECUTE AS USER = N'gapi07_etl';
       EXEC etl.sp_run_all @SkipSwap = 1, @ForceFullLines = 1;
       REVERT;

   Ha de fer exactament el mateix que fa amb sa. Si peta per permisos, el que
   falta va a la llista de dalt, no s'afegeix el compte a db_owner.
   ------------------------------------------------------------------------- */
