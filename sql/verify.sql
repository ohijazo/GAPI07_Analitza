/* =========================================================================
   verify.sql   -  Comprovacions end-to-end post-execucio
   Executar despres de fer:
       EXEC IntercanviSAP.etl.sp_run_all;
   Si tot mostra OK, l'integracio amb Analitza esta llesta per testos.
   =========================================================================*/
USE IntercanviSAP;
GO

PRINT '---- 1. Schema: taules est_* a dbo i staging ----';
SELECT s.name AS schema_name, t.name AS table_name
FROM   sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE  t.name LIKE 'est_%'
ORDER BY t.name, s.name;

PRINT '---- 2. Ultima execucio ETL ----';
SELECT TOP 1 run_id, started_at, finished_at,
       DATEDIFF(SECOND, started_at, finished_at) AS duration_sec,
       [status], error_message
FROM   [audit].etl_runs
ORDER BY run_id DESC;

PRINT '---- 3. Steps de la ultima execucio ----';
SELECT s.step_id, s.step_name, s.[status], s.rows_in, s.rows_out, s.duration_ms,
       LEFT(s.error_message, 200) AS error
FROM   [audit].etl_step_log s
WHERE  s.run_id = (SELECT MAX(run_id) FROM [audit].etl_runs)
ORDER BY s.step_id;

PRINT '---- 4. Warnings de qualitat de l ultima execucio ----';
SELECT severity, check_name, details
FROM   [audit].data_quality_warnings
WHERE  run_id = (SELECT MAX(run_id) FROM [audit].etl_runs);

PRINT '---- 5. Recompte de files per taula dbo.est_* ----';
SELECT 'est_agents'              AS tbl, COUNT(*) AS n FROM dbo.est_agents
UNION ALL SELECT 'est_families_productes', COUNT(*) FROM dbo.est_families_productes
UNION ALL SELECT 'est_clients',             COUNT(*) FROM dbo.est_clients
UNION ALL SELECT 'est_productes',           COUNT(*) FROM dbo.est_productes
UNION ALL SELECT 'est_linies_albara',       COUNT(*) FROM dbo.est_linies_albara
UNION ALL SELECT 'est_atributs_client',     COUNT(*) FROM dbo.est_atributs_client
UNION ALL SELECT 'est_atributs_producte',   COUNT(*) FROM dbo.est_atributs_producte
UNION ALL SELECT 'est_clients_efectes_pendents', COUNT(*) FROM dbo.est_clients_efectes_pendents;

PRINT '---- 6. Formula  net_amount = price*qty*(1-discount)  TOP 100 desviacions ----';
SELECT TOP 100 invoices_id, id_invoice_line, product_price, quantity, discount, net_amount,
       ABS(net_amount - product_price * quantity * (1 - discount)) AS diff
FROM   dbo.est_linies_albara
WHERE  ABS(net_amount - product_price * quantity * (1 - discount)) > 0.01
ORDER BY diff DESC;

PRINT '---- 7. country_code: distribucio ----';
SELECT country_code, COUNT(*) AS n
FROM   dbo.est_clients
GROUP BY country_code
ORDER BY n DESC;

PRINT '---- 8. Distribucio per transaction ----';
SELECT [transaction], COUNT(*) AS lines, SUM(net_amount) AS sum_net
FROM   dbo.est_linies_albara
GROUP BY [transaction];

PRINT '---- 9. SQL Agent Job ----';
SELECT j.name, j.enabled, s.next_run_date, s.next_run_time
FROM   msdb.dbo.sysjobs j
LEFT JOIN msdb.dbo.sysjobschedules s ON s.job_id = j.job_id
WHERE  j.name = 'Analitza_ETL_Daily';
GO
