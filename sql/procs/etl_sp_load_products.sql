/* =========================================================================
   etl.sp_load_products   (format KAIS)
   Origen : sap_raw.OITM   (mirall de SAP omplert pel Worker via Service Layer)
   Destino: staging.est_productes
   Mapping:
     id_product            <- ItemCode                  varchar(16)
     name                  <- ItemName                  varchar(90)
     product_categories_id <- ItmsGrpCod                varchar(250) — KAIS ho fa
                              gran, respectem per idempotència
     active                <- validFor='Y' AND frozenFor<>'Y'   bit
   Filtro: cap (per conservar històric — productes despublicats també).
   NO inclou available_from_date / available_to_date (KAIS no els té).
   ========================================================================= */
USE IntercanviSAP;
GO

IF OBJECT_ID('etl.sp_load_products') IS NOT NULL
    DROP PROCEDURE etl.sp_load_products;
GO

CREATE PROCEDURE etl.sp_load_products
    @RunId bigint = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @started datetime2(3) = SYSUTCDATETIME();
    DECLARE @rows_in bigint = 0, @rows_out bigint = 0;

    BEGIN TRY
        TRUNCATE TABLE staging.est_productes;

        INSERT INTO staging.est_productes
            (id_product, [name], product_categories_id, active)
        SELECT  LEFT(ItemCode, 16),
                LEFT(ISNULL(ItemName, ''), 90),
                LEFT(CAST(ItmsGrpCod AS varchar(250)), 250),
                CASE WHEN validFor = 'Y' AND (frozenFor = 'N' OR frozenFor IS NULL)
                     THEN CAST(1 AS bit) ELSE CAST(0 AS bit) END
        FROM    sap_raw.OITM
        WHERE   ItemCode IS NOT NULL;
        SET @rows_out = @@ROWCOUNT;

        SELECT @rows_in = COUNT_BIG(*) FROM sap_raw.OITM;

        IF @RunId IS NOT NULL
            INSERT [audit].etl_step_log (run_id, step_name, started_at, finished_at, rows_in, rows_out, duration_ms, [status])
            VALUES (@RunId, 'sp_load_products', @started, SYSUTCDATETIME(), @rows_in, @rows_out,
                    DATEDIFF(MILLISECOND, @started, SYSUTCDATETIME()), 'OK');
    END TRY
    BEGIN CATCH
        DECLARE @err nvarchar(max) = ERROR_MESSAGE();
        IF @RunId IS NOT NULL
            INSERT [audit].etl_step_log (run_id, step_name, started_at, finished_at, rows_in, rows_out, duration_ms, [status], error_message)
            VALUES (@RunId, 'sp_load_products', @started, SYSUTCDATETIME(), @rows_in, @rows_out,
                    DATEDIFF(MILLISECOND, @started, SYSUTCDATETIME()), 'ERROR', @err);
        THROW;
    END CATCH
END
GO
