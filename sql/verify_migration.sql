/* =========================================================================
   verify_migration.sql  —  Fase 4: staging.est_*  vs  baseline.est_*

   QUE FA
   ------
   Compara, taula a taula, la sortida del pipeline NOU (Service Layer ->
   sap_raw -> etl.sp_load_*) contra la fotografia del pipeline ANTIC
   (schema baseline, pres amb sql/schema/03_create_baseline.sql).

   EXCEPT en tots dos sentits: detecta files que falten, files que sobren i
   files amb qualsevol valor diferent. Es l'unica prova que ens interessa,
   perque dbo.est_* es tot el que veu Analitza.

   COM EXECUTAR-LO
   ---------------
       1) Worker:  dotnet run --project ...SapB1AnalitzaSync.Worker -- --once
       2) SQL:     EXEC IntercanviSAP.etl.sp_run_all @SkipSwap=1, @ForceFullLines=1;
       3) SQL:     sqlcmd -S AE01SAPSQL -U sa -P <pwd> -i verify_migration.sql

   El pas 2 amb @SkipSwap=1 es important: deixa la sortida a staging sense
   tocar dbo, aixi que es pot comparar sense arriscar el que veu Analitza.

   CRITERI DE TALL
   ---------------
   0 files de diferencia a les 8 taules.
   Qualsevol diferencia a id_client_location o id_invoice_line es BLOQUEJANT:
   son el contracte amb Analitza (Regla 04).
   ========================================================================= */
USE IntercanviSAP;
GO

SET NOCOUNT ON;

IF OBJECT_ID('baseline.snapshot_info') IS NULL
BEGIN
    RAISERROR('No hi ha fotografia baseline. Executa primer sql\schema\03_create_baseline.sql amb l ETL antic viu.', 16, 1);
    RETURN;
END
GO

PRINT '=== Fotografia de referencia ===';
SELECT table_name, row_count, taken_at, source_run_id
FROM   baseline.snapshot_info
ORDER  BY table_name;
GO

/* -------------------------------------------------------------------------
   Recomptes: la primera senyal, i la mes barata.
   ------------------------------------------------------------------------- */
PRINT '';
PRINT '=== Recomptes staging vs baseline ===';

SELECT t.table_name,
       t.baseline_rows,
       t.staging_rows,
       t.staging_rows - t.baseline_rows AS diff
FROM (
    SELECT 'est_agents' AS table_name,
           (SELECT COUNT_BIG(*) FROM baseline.est_agents) AS baseline_rows,
           (SELECT COUNT_BIG(*) FROM staging.est_agents)  AS staging_rows
    UNION ALL SELECT 'est_families_productes',
           (SELECT COUNT_BIG(*) FROM baseline.est_families_productes),
           (SELECT COUNT_BIG(*) FROM staging.est_families_productes)
    UNION ALL SELECT 'est_clients',
           (SELECT COUNT_BIG(*) FROM baseline.est_clients),
           (SELECT COUNT_BIG(*) FROM staging.est_clients)
    UNION ALL SELECT 'est_productes',
           (SELECT COUNT_BIG(*) FROM baseline.est_productes),
           (SELECT COUNT_BIG(*) FROM staging.est_productes)
    UNION ALL SELECT 'est_linies_albara',
           (SELECT COUNT_BIG(*) FROM baseline.est_linies_albara),
           (SELECT COUNT_BIG(*) FROM staging.est_linies_albara)
    UNION ALL SELECT 'est_atributs_client',
           (SELECT COUNT_BIG(*) FROM baseline.est_atributs_client),
           (SELECT COUNT_BIG(*) FROM staging.est_atributs_client)
    UNION ALL SELECT 'est_atributs_producte',
           (SELECT COUNT_BIG(*) FROM baseline.est_atributs_producte),
           (SELECT COUNT_BIG(*) FROM staging.est_atributs_producte)
    UNION ALL SELECT 'est_cobraments',
           (SELECT COUNT_BIG(*) FROM baseline.est_cobraments),
           (SELECT COUNT_BIG(*) FROM staging.est_cobraments)
) t
ORDER BY t.table_name;
GO

/* -------------------------------------------------------------------------
   Diferencies fila a fila.

   El EXCEPT es genera per codi a partir de les columnes reals de cada taula,
   en comptes d'escriure vuit parells de consultes a ma: aixi, si algun dia
   s'afegeix una columna a est_*, la comparacio la cobreix sola i no queda un
   forat silencios. observations es varchar(max) i EXCEPT no admet LOB, per
   aixo es compara pel seu CHECKSUM.
   ------------------------------------------------------------------------- */
PRINT '';
PRINT '=== Diferencies fila a fila (0 = OK) ===';

DECLARE @tbl sysname, @cols nvarchar(max), @sql nvarchar(max);
DECLARE @total_diff bigint = 0, @tbl_diff bigint;

DECLARE tabs CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.tables
    WHERE schema_id = SCHEMA_ID('baseline') AND name LIKE 'est[_]%'
    ORDER BY name;

OPEN tabs;
FETCH NEXT FROM tabs INTO @tbl;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @cols = STRING_AGG(
             CASE WHEN c.max_length = -1 OR t.name IN ('text', 'ntext', 'image')
                  THEN 'CHECKSUM(' + QUOTENAME(c.name) + ') AS ' + QUOTENAME(c.name)
                  ELSE QUOTENAME(c.name) END, ', ')
           WITHIN GROUP (ORDER BY c.column_id)
    FROM   sys.columns c
    JOIN   sys.types   t ON t.user_type_id = c.user_type_id
    WHERE  c.object_id = OBJECT_ID('baseline.' + @tbl);

    /* Dues subconsultes i no un UNION ALL entre dos EXCEPT: a SQL Server,
       EXCEPT i UNION tenen la mateixa precedencia i s avaluen d esquerra a
       dreta, aixi que "A EXCEPT B UNION ALL C EXCEPT D" no vol dir el que
       sembla. Sumant-les per separat no hi ha ambiguitat. */
    SET @sql = N'
        SELECT @d =
            (SELECT COUNT_BIG(*) FROM (
                SELECT ' + @cols + N' FROM staging.'  + QUOTENAME(@tbl) + N'
                EXCEPT
                SELECT ' + @cols + N' FROM baseline.' + QUOTENAME(@tbl) + N') a)
          + (SELECT COUNT_BIG(*) FROM (
                SELECT ' + @cols + N' FROM baseline.' + QUOTENAME(@tbl) + N'
                EXCEPT
                SELECT ' + @cols + N' FROM staging.'  + QUOTENAME(@tbl) + N') b);';

    EXEC sp_executesql @sql, N'@d bigint OUTPUT', @d = @tbl_diff OUTPUT;
    SET @total_diff = @total_diff + ISNULL(@tbl_diff, 0);

    PRINT RIGHT(@tbl + REPLICATE(' ', 30), 30) + ' files diferents: ' + CAST(ISNULL(@tbl_diff, 0) AS varchar(20));

    FETCH NEXT FROM tabs INTO @tbl;
END
CLOSE tabs;
DEALLOCATE tabs;

PRINT '';
IF @total_diff = 0
    PRINT '*** OK: les 8 taules son identiques. La migracio es pot tallar. ***';
ELSE
    PRINT '*** ATENCIO: ' + CAST(@total_diff AS varchar(20)) + ' files difereixen. Mira els detalls a sota abans de tallar. ***';
GO

/* -------------------------------------------------------------------------
   Detall del que mes importa: els dos identificadors que son contracte.
   Si aqui hi ha res, es bloquejant, encara que la resta quadri.
   ------------------------------------------------------------------------- */
PRINT '';
PRINT '=== BLOQUEJANT: id_client_location que apareix o desapareix ===';

SELECT TOP 50 'nomes a staging' AS origen, id_client_location
FROM   staging.est_clients
WHERE  id_client_location NOT IN (SELECT id_client_location FROM baseline.est_clients)
UNION ALL
SELECT TOP 50 'nomes a baseline', id_client_location
FROM   baseline.est_clients
WHERE  id_client_location NOT IN (SELECT id_client_location FROM staging.est_clients);

PRINT '';
PRINT '=== BLOQUEJANT: id_invoice_line que apareix o desapareix ===';

SELECT TOP 50 'nomes a staging' AS origen, id_invoice_line
FROM   staging.est_linies_albara
WHERE  id_invoice_line NOT IN (SELECT id_invoice_line FROM baseline.est_linies_albara)
UNION ALL
SELECT TOP 50 'nomes a baseline', id_invoice_line
FROM   baseline.est_linies_albara
WHERE  id_invoice_line NOT IN (SELECT id_invoice_line FROM staging.est_linies_albara);
GO

/* -------------------------------------------------------------------------
   Si els identificadors quadren pero els imports no, el sospitos numero u es
   el mapatge de preu i cost de linia (Fase 0, forats B2 i PriceField).
   ------------------------------------------------------------------------- */
PRINT '';
PRINT '=== Diferencies d imports a les linies (primeres 50) ===';

SELECT TOP 50
       s.id_invoice_line,
       b.product_price AS price_baseline, s.product_price AS price_staging,
       b.product_cost  AS cost_baseline,  s.product_cost  AS cost_staging,
       b.discount      AS disc_baseline,  s.discount      AS disc_staging,
       b.net_amount    AS net_baseline,   s.net_amount    AS net_staging
FROM   staging.est_linies_albara s
JOIN   baseline.est_linies_albara b ON b.id_invoice_line = s.id_invoice_line
WHERE  ABS(s.product_price - b.product_price) > 0.01
    OR ABS(s.product_cost  - b.product_cost)  > 0.01
    OR ABS(ISNULL(s.net_amount, 0) - ISNULL(b.net_amount, 0)) > 0.01
ORDER BY s.id_invoice_line;
GO
