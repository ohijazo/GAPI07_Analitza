/* =========================================================================
   cleanup_master.sql
   -------------------------------------------------------------------------
   Si el primer deploy va fallar al CREATE DATABASE i va continuar executant-se
   en context master, pot haver creat schemas/taules dins master per error.
   Aquest script elimina nomes el que correspon a la integracio (no toca res
   propi de SQL Server).

   Idempotent. Es pot executar tantes vegades com calgui.
   =========================================================================*/
USE master;
GO

PRINT '--- Inspeccio previa: objectes nostres trobats a master ---';
SELECT s.name AS schema_name, t.name AS table_name
FROM   sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE  s.name IN ('staging','etl','audit','cfg')
    OR t.name LIKE 'est_%';
GO

/* ---------- 1. Taules ---------- */
DROP TABLE IF EXISTS [audit].data_quality_warnings;
DROP TABLE IF EXISTS [audit].etl_step_log;
DROP TABLE IF EXISTS [audit].etl_runs;

DROP TABLE IF EXISTS cfg.settings;
DROP TABLE IF EXISTS cfg.attribute_mapping;
DROP TABLE IF EXISTS cfg.country_code_overrides;

DROP TABLE IF EXISTS staging.est_clients_efectes_pendents;
DROP TABLE IF EXISTS staging.est_atributs_producte;
DROP TABLE IF EXISTS staging.est_atributs_client;
DROP TABLE IF EXISTS staging.est_linies_albara;
DROP TABLE IF EXISTS staging.est_productes;
DROP TABLE IF EXISTS staging.est_clients;
DROP TABLE IF EXISTS staging.est_families_productes;
DROP TABLE IF EXISTS staging.est_agents;

DROP TABLE IF EXISTS dbo.est_clients_efectes_pendents;
DROP TABLE IF EXISTS dbo.est_atributs_producte;
DROP TABLE IF EXISTS dbo.est_atributs_client;
DROP TABLE IF EXISTS dbo.est_linies_albara;
DROP TABLE IF EXISTS dbo.est_productes;
DROP TABLE IF EXISTS dbo.est_clients;
DROP TABLE IF EXISTS dbo.est_families_productes;
DROP TABLE IF EXISTS dbo.est_agents;
GO

/* ---------- 2. Procediments i functions als nostres schemes ---------- */
DECLARE @sql nvarchar(max) = N'';
SELECT @sql = @sql + N'DROP PROCEDURE ' + QUOTENAME(s.name) + N'.' + QUOTENAME(p.name) + N';' + CHAR(13)
FROM   sys.procedures p
JOIN   sys.schemas s ON s.schema_id = p.schema_id
WHERE  s.name IN (N'staging', N'etl', N'audit', N'cfg');

SELECT @sql = @sql + N'DROP FUNCTION ' + QUOTENAME(s.name) + N'.' + QUOTENAME(f.name) + N';' + CHAR(13)
FROM   sys.objects f
JOIN   sys.schemas s ON s.schema_id = f.schema_id
WHERE  s.name IN (N'staging', N'etl', N'audit', N'cfg')
  AND  f.type IN ('FN','IF','TF','FS','FT');

IF LEN(@sql) > 0
BEGIN
    PRINT '--- Eliminant procediments/funcions: ---';
    PRINT @sql;
    EXEC sp_executesql @sql;
END
GO

/* ---------- 3. Schemes (nomes els nostres, mai dbo) ---------- */
IF SCHEMA_ID('staging') IS NOT NULL EXEC ('DROP SCHEMA staging');
IF SCHEMA_ID('etl')     IS NOT NULL EXEC ('DROP SCHEMA etl');
IF SCHEMA_ID('audit')   IS NOT NULL EXEC ('DROP SCHEMA [audit]');
IF SCHEMA_ID('cfg')     IS NOT NULL EXEC ('DROP SCHEMA cfg');
GO

PRINT '--- Master net. Inspeccio final: ---';
SELECT s.name AS schema_name, t.name AS table_name
FROM   sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE  s.name IN ('staging','etl','audit','cfg')
    OR t.name LIKE 'est_%';
GO
