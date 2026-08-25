/* =========================================================================
   etl.sp_load_product_attributes   (format KAIS — WIDE, 3 columnes fixes)
   Origen : sap_raw.OITM   (mirall de SAP omplert pel Worker via Service Layer)
   Destino: staging.est_atributs_producte
   Mapping (fixed, no fa servir cfg.attribute_mapping):
     art_codi              <- OITM.ItemCode              varchar(16)
     subfamily_description <- OITM.U_SEISubFamCialCat    varchar(250)
     units_description     <- OITM.SalUnitMsr            varchar(3)  (KAIS: "GRA", "SAC", "UNI", "KG"...)
   Una fila per ItemCode (KAIS també).
   ========================================================================= */
USE IntercanviSAP;
GO

IF OBJECT_ID('etl.sp_load_product_attributes') IS NOT NULL
    DROP PROCEDURE etl.sp_load_product_attributes;
GO

CREATE PROCEDURE etl.sp_load_product_attributes
    @RunId bigint = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @started datetime2(3) = SYSUTCDATETIME();
    DECLARE @rows_in bigint = 0, @rows_out bigint = 0;

    BEGIN TRY
        TRUNCATE TABLE staging.est_atributs_producte;

        INSERT INTO staging.est_atributs_producte
            (art_codi, subfamily_description, units_description)
        SELECT  LEFT(p.ItemCode, 16),
                LEFT(ISNULL(RTRIM(p.U_SEISubFamCialCat), ''), 250),
                LEFT(ISNULL(RTRIM(p.SalUnitMsr), ''), 3)
        FROM    sap_raw.OITM p
        WHERE   p.ItemCode IS NOT NULL;
        SET @rows_out = @@ROWCOUNT;

        SELECT @rows_in = COUNT_BIG(*) FROM sap_raw.OITM;

        IF @RunId IS NOT NULL
            INSERT [audit].etl_step_log (run_id, step_name, started_at, finished_at, rows_in, rows_out, duration_ms, [status])
            VALUES (@RunId, 'sp_load_product_attributes', @started, SYSUTCDATETIME(), @rows_in, @rows_out,
                    DATEDIFF(MILLISECOND, @started, SYSUTCDATETIME()), 'OK');
    END TRY
    BEGIN CATCH
        DECLARE @err nvarchar(max) = ERROR_MESSAGE();
        IF @RunId IS NOT NULL
            INSERT [audit].etl_step_log (run_id, step_name, started_at, finished_at, rows_in, rows_out, duration_ms, [status], error_message)
            VALUES (@RunId, 'sp_load_product_attributes', @started, SYSUTCDATETIME(), @rows_in, @rows_out,
                    DATEDIFF(MILLISECOND, @started, SYSUTCDATETIME()), 'ERROR', @err);
        THROW;
    END CATCH
END
GO
