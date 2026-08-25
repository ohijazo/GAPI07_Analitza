/* =========================================================================
   baseline.*  —  Fotografia de referència per a la migració a Service Layer

   PER QUÈ EXISTEIX
   ----------------
   La migració elimina el SQL directe contra SAP. Per demostrar que el nou
   pipeline (Service Layer -> sap_raw -> etl.sp_load_* -> staging) produeix
   EXACTAMENT el mateix que el pipeline antic (cross-DB -> etl.sp_load_* ->
   staging), congelem aquí la sortida de l'ETL antic i comparem contra ella.

   Aquesta fotografia és tambe la referència de la Fase 0: baseline.est_clients
   ja conté id_client_location = "<CardCode>-<LineNum 3 dígits>", i
   baseline.est_linies_albara ja conté product_price / product_cost / discount
   calculats. Per validar el mapatge SAP <-> Service Layer no cal, doncs,
   tornar a llegir cap taula interna de SAP (Regla 01).

   QUAN EXECUTAR-LO
   ----------------
   UN SOL COP, amb l'ETL antic encara viu i l'última execució en SUCCESS.
   Comprova-ho abans:
       SELECT TOP 1 run_id, status, finished_at
       FROM audit.etl_runs ORDER BY run_id DESC;   -- ha de dir SUCCESS

   És deliberadament NO idempotent en el sentit habitual: si les taules ja
   existeixen, NO les toca. Refer la fotografia requereix @Force = 1, que
   n'esborra la versió anterior. No ho facis un cop començada la validació.

   QUAN ESBORRAR-LO
   ----------------
   Després del cutover a productiva (Novembre 2026):  DROP SCHEMA baseline.
   ========================================================================= */
USE IntercanviSAP;
GO

DECLARE @Force bit = 0;   /* posa 1 NOMÉS si vols descartar la fotografia anterior */

IF SCHEMA_ID('baseline') IS NULL EXEC ('CREATE SCHEMA baseline');

IF @Force = 1
BEGIN
    PRINT '*** @Force = 1: esborrant la fotografia anterior ***';
    IF OBJECT_ID('baseline.est_agents')             IS NOT NULL DROP TABLE baseline.est_agents;
    IF OBJECT_ID('baseline.est_families_productes') IS NOT NULL DROP TABLE baseline.est_families_productes;
    IF OBJECT_ID('baseline.est_clients')            IS NOT NULL DROP TABLE baseline.est_clients;
    IF OBJECT_ID('baseline.est_productes')          IS NOT NULL DROP TABLE baseline.est_productes;
    IF OBJECT_ID('baseline.est_linies_albara')      IS NOT NULL DROP TABLE baseline.est_linies_albara;
    IF OBJECT_ID('baseline.est_atributs_client')    IS NOT NULL DROP TABLE baseline.est_atributs_client;
    IF OBJECT_ID('baseline.est_atributs_producte')  IS NOT NULL DROP TABLE baseline.est_atributs_producte;
    IF OBJECT_ID('baseline.est_cobraments')         IS NOT NULL DROP TABLE baseline.est_cobraments;
    IF OBJECT_ID('baseline.snapshot_info')          IS NOT NULL DROP TABLE baseline.snapshot_info;
END
GO

/* SELECT ... INTO copia estructura i dades. No copia PKs ni índexs: per a
   comparacions amb EXCEPT no calen, i afegir-los només alentiria la còpia. */

IF OBJECT_ID('baseline.est_agents') IS NULL
    SELECT * INTO baseline.est_agents             FROM dbo.est_agents;

IF OBJECT_ID('baseline.est_families_productes') IS NULL
    SELECT * INTO baseline.est_families_productes FROM dbo.est_families_productes;

IF OBJECT_ID('baseline.est_clients') IS NULL
    SELECT * INTO baseline.est_clients            FROM dbo.est_clients;

IF OBJECT_ID('baseline.est_productes') IS NULL
    SELECT * INTO baseline.est_productes          FROM dbo.est_productes;

IF OBJECT_ID('baseline.est_linies_albara') IS NULL
    SELECT * INTO baseline.est_linies_albara      FROM dbo.est_linies_albara;

IF OBJECT_ID('baseline.est_atributs_client') IS NULL
    SELECT * INTO baseline.est_atributs_client    FROM dbo.est_atributs_client;

IF OBJECT_ID('baseline.est_atributs_producte') IS NULL
    SELECT * INTO baseline.est_atributs_producte  FROM dbo.est_atributs_producte;

IF OBJECT_ID('baseline.est_cobraments') IS NULL
    SELECT * INTO baseline.est_cobraments         FROM dbo.est_cobraments;
GO

/* Índex a est_linies_albara: la sonda de Fase 0 hi busca per id_invoice_line
   i la comparació de Fase 4 hi fa EXCEPT sobre centenars de milers de files. */
IF OBJECT_ID('baseline.est_linies_albara') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE object_id = OBJECT_ID('baseline.est_linies_albara')
                     AND name = 'IX_baseline_linies_id')
    CREATE CLUSTERED INDEX IX_baseline_linies_id
        ON baseline.est_linies_albara (id_invoice_line);
GO

/* -------------------------------------------------------------------------
   Metadades de la fotografia: quan es va prendre, de quin run i amb quantes
   files. Sense això, d'aquí sis mesos ningú sabrà contra què s'està comparant.
   ------------------------------------------------------------------------- */
IF OBJECT_ID('baseline.snapshot_info') IS NULL
BEGIN
    CREATE TABLE baseline.snapshot_info (
        taken_at        datetime2(0) NOT NULL,
        taken_by        sysname      NOT NULL,
        source_run_id   bigint       NULL,
        source_run_at   datetime2(0) NULL,
        table_name      sysname      NOT NULL,
        row_count       bigint       NOT NULL,
        CONSTRAINT PK_baseline_snapshot_info PRIMARY KEY CLUSTERED (table_name)
    );

    DECLARE @run_id bigint, @run_at datetime2(0);
    SELECT TOP 1 @run_id = run_id, @run_at = finished_at
    FROM   [audit].etl_runs
    WHERE  [status] = 'SUCCESS'
    ORDER  BY run_id DESC;

    INSERT baseline.snapshot_info (taken_at, taken_by, source_run_id, source_run_at, table_name, row_count)
    SELECT SYSUTCDATETIME(), SUSER_SNAME(), @run_id, @run_at, t.table_name, t.row_count
    FROM (
        SELECT 'est_agents'             AS table_name, COUNT_BIG(*) AS row_count FROM baseline.est_agents
        UNION ALL SELECT 'est_families_productes', COUNT_BIG(*) FROM baseline.est_families_productes
        UNION ALL SELECT 'est_clients',            COUNT_BIG(*) FROM baseline.est_clients
        UNION ALL SELECT 'est_productes',          COUNT_BIG(*) FROM baseline.est_productes
        UNION ALL SELECT 'est_linies_albara',      COUNT_BIG(*) FROM baseline.est_linies_albara
        UNION ALL SELECT 'est_atributs_client',    COUNT_BIG(*) FROM baseline.est_atributs_client
        UNION ALL SELECT 'est_atributs_producte',  COUNT_BIG(*) FROM baseline.est_atributs_producte
        UNION ALL SELECT 'est_cobraments',         COUNT_BIG(*) FROM baseline.est_cobraments
    ) t;
END
GO

/* Resum per pantalla */
SELECT table_name, row_count, taken_at, source_run_id, source_run_at
FROM   baseline.snapshot_info
ORDER  BY table_name;
GO

/* Avís si alguna taula ha quedat buida: seria una fotografia inútil com a
   referència, i vol dir que l'ETL antic no havia carregat correctament. */
IF EXISTS (SELECT 1 FROM baseline.snapshot_info WHERE row_count = 0)
    RAISERROR('ATENCIO: hi ha taules a baseline amb 0 files. Revisa audit.etl_runs abans de fer servir aquesta fotografia com a referencia.', 16, 1);
GO
