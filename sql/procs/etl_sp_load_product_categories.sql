/* =========================================================================
   etl.sp_load_product_categories   (format KAIS)
   Origen : sap_raw.OITB   (mirall de SAP omplert pel Worker via Service Layer)
   Destino: staging.est_families_productes
   Mapping:
     id_product_category  <- ItmsGrpCod                 varchar(250)
     name                 <- ItmsGrpNam                 varchar(250)
   Nota: KAIS a la BD Intercanvi té 2.051 files (una per producte, valors
   duplicats i majoritàriament buits). Nosaltres carreguem la forma
   normalitzada (una fila per família) — Analitza pot fer JOIN amb
   est_productes.product_categories_id per obtenir el nom.
   ========================================================================= */
USE IntercanviSAP;
GO

IF OBJECT_ID('etl.sp_load_product_categories') IS NOT NULL
    DROP PROCEDURE etl.sp_load_product_categories;
GO

CREATE PROCEDURE etl.sp_load_product_categories
    @RunId bigint = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @started datetime2(3) = SYSUTCDATETIME();
    DECLARE @rows_in bigint = 0, @rows_out bigint = 0;

    BEGIN TRY
        TRUNCATE TABLE staging.est_families_productes;

        INSERT INTO staging.est_families_productes (id_product_category, [name])
        SELECT  LEFT(CAST(ItmsGrpCod AS varchar(250)), 250),
                LEFT(ISNULL(ItmsGrpNam, ''), 250)
        FROM    sap_raw.OITB
        WHERE   ItmsGrpCod IS NOT NULL;
        SET @rows_out = @@ROWCOUNT;

        SELECT @rows_in = COUNT_BIG(*) FROM sap_raw.OITB;

        IF @RunId IS NOT NULL
            INSERT [audit].etl_step_log (run_id, step_name, started_at, finished_at, rows_in, rows_out, duration_ms, [status])
            VALUES (@RunId, 'sp_load_product_categories', @started, SYSUTCDATETIME(), @rows_in, @rows_out,
                    DATEDIFF(MILLISECOND, @started, SYSUTCDATETIME()), 'OK');
    END TRY
    BEGIN CATCH
        DECLARE @err nvarchar(max) = ERROR_MESSAGE();
        IF @RunId IS NOT NULL
            INSERT [audit].etl_step_log (run_id, step_name, started_at, finished_at, rows_in, rows_out, duration_ms, [status], error_message)
            VALUES (@RunId, 'sp_load_product_categories', @started, SYSUTCDATETIME(), @rows_in, @rows_out,
                    DATEDIFF(MILLISECOND, @started, SYSUTCDATETIME()), 'ERROR', @err);
        THROW;
    END CATCH
END
GO
