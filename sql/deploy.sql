/* =========================================================================
   deploy.sql   -  Orquestrador de desplegament
   -------------------------------------------------------------------------
   Instal.la les vistes, els SP, els seeds i el job en l'ordre correcte sobre una
   BD IntercanviSAP que ja existeix. Idempotent: es pot tornar a executar tantes
   vegades com calgui sense perdre dades.

   NO crida schema\01_create_database.sql. Aquell fitxer fa DROP de les vuit
   dbo.est_* per crear-les buides: es CREACIO INICIAL, s'executa una sola vegada
   i a ma. Mentre va estar aqui, "idempotent" era mentida i executar deploy.sql
   sencer hauria deixat Analitza sense dades. Els canvis d'esquema sobre una BD
   viva van a schema\04_migracions.sql, que si que es crida.

   NO inclou res de sql/migrations/. Aquella carpeta son canvis de DADES sobre
   estat que no es pot regenerar -avui, cfg.client_ship_no-, s'executen a MA una
   sola vegada i mirant la sortida. Posar-los aqui voldria dir que un
   desplegament rutinari pot reassignar ~800 id_client_location sense que ningu
   hagi posat @ForceFullLines=1. La divisio:
       schema/04_migracions.sql  -> ESQUEMA, idempotent i automatic.
       sql/migrations/*.sql      -> DADES, un sol cop, a ma, amb permis explicit.

   NO inclou schema\03_create_baseline.sql: la fotografia de referencia es
   pren UNA sola vegada, a ma, abans del tall a Service Layer. Veure el
   capcal d'aquell fitxer.

   Execucio (sqlcmd):
       sqlcmd -S <servidor> -E -i deploy.sql
   o des de SSMS amb mode SQLCMD activat (Query -> SQLCMD Mode).
   =========================================================================*/

:setvar ROOT "P:\GAPI07_Analitza\sql"

PRINT '==== 1/4  Schema =================================';
:r $(ROOT)\schema\02_create_sap_raw.sql
/* Posa al dia una BD ja desplegada. 01_create_database.sql no hi es a proposit:
   veure el capcal. */
:r $(ROOT)\schema\04_migracions.sql

PRINT '==== 2/4  Stored procedures =====================';
/* Les vistes primer: els SP de sota hi fan JOIN. */
:r $(ROOT)\procs\etl_vw_kais_codes.sql
:r $(ROOT)\procs\etl_sp_assign_client_ship_no.sql
:r $(ROOT)\procs\etl_sp_load_product_categories.sql
:r $(ROOT)\procs\etl_sp_load_salesmen.sql
:r $(ROOT)\procs\etl_sp_load_clients.sql
:r $(ROOT)\procs\etl_sp_load_products.sql
:r $(ROOT)\procs\etl_sp_load_invoice_lines.sql
:r $(ROOT)\procs\etl_sp_load_client_attributes.sql
:r $(ROOT)\procs\etl_sp_load_product_attributes.sql
:r $(ROOT)\procs\etl_sp_load_receivables.sql
:r $(ROOT)\procs\etl_sp_data_quality_checks.sql
:r $(ROOT)\procs\etl_sp_swap_staging_to_prod.sql
:r $(ROOT)\procs\etl_sp_run_all.sql

PRINT '==== 3/4  Seeds (cfg) ===========================';
:r $(ROOT)\cfg\seed_country_code_overrides.sql
:r $(ROOT)\cfg\seed_attribute_mapping.sql
:r $(ROOT)\cfg\seed_zone_code_mapping.sql

PRINT '==== 4/4  Context d execucio i SQL Agent Job ====';
/* Abans del job: el pas corre com a gapi07_etl i sense l'usuari falla. */
:r $(ROOT)\security\create_etl_user.sql
:r $(ROOT)\jobs\sqlagent_analitza_etl_daily.sql

PRINT '==== Deploy complete. ===========================';
PRINT 'Els SP llegeixen sap_raw, que omple el Worker per Service Layer.';
PRINT 'Seguent pas: refrescar el mirall i executar l ETL en mode inspeccio:';
PRINT '    dotnet run --project P:\GAPI07_Analitza\src\SapB1AnalitzaSync.Worker -- --once';
PRINT '    EXEC IntercanviSAP.etl.sp_run_all @SkipSwap=1, @ForceFullLines=1;';
PRINT 'i comprovar audit.etl_runs / audit.data_quality_warnings.';
GO
