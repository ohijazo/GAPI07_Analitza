/* =========================================================================
   deploy.sql   -  Orquestrador de desplegament
   -------------------------------------------------------------------------
   Crea la BD IntercanviSAP, instal.la tots els SP i seeds en l'ordre correcte.
   Idempotent: es pot tornar a executar.

   NO inclou schema\03_create_baseline.sql: la fotografia de referencia es
   pren UNA sola vegada, a ma, abans del tall a Service Layer. Veure el
   capcal d'aquell fitxer.

   Execucio (sqlcmd):
       sqlcmd -S <servidor> -E -i deploy.sql
   o des de SSMS amb mode SQLCMD activat (Query -> SQLCMD Mode).
   =========================================================================*/

:setvar ROOT "P:\GAPI07_Analitza\sql"

PRINT '==== 1/4  Schema =================================';
:r $(ROOT)\schema\01_create_database.sql
:r $(ROOT)\schema\02_create_sap_raw.sql

PRINT '==== 2/4  Stored procedures =====================';
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

PRINT '==== 4/4  SQL Agent Job =========================';
:r $(ROOT)\jobs\sqlagent_analitza_etl_daily.sql

PRINT '==== Deploy complete. ===========================';
PRINT 'Els SP llegeixen sap_raw, que omple el Worker per Service Layer.';
PRINT 'Seguent pas: refrescar el mirall i executar l ETL en mode inspeccio:';
PRINT '    dotnet run --project P:\GAPI07_Analitza\src\SapB1AnalitzaSync.Worker -- --once';
PRINT '    EXEC IntercanviSAP.etl.sp_run_all @SkipSwap=1, @ForceFullLines=1;';
PRINT 'i comprovar audit.etl_runs / audit.data_quality_warnings.';
GO
