/* =========================================================================
   etl.sp_load_salesmen   (format KAIS)
   Origen : sap_raw.OSLP   (mirall de SAP omplert pel Worker via Service Layer)
   Destino: staging.est_agents
   Mapping:
     id_salesman  <- LPAD(SlpCode, 3)     varchar(3)   -- KAIS: "000", "006", "100"
     name         <- SlpName              varchar(35)
   Nota: SlpCode = -1 ("Sin agente") és preservat (SAP l'usa per fallback).
   Format LPAD amb 3 chars: SlpCode -1 → "-1 " (2 chars + espai) ho convertim
   a "000" per compatibilitat amb KAIS.
   ========================================================================= */
USE IntercanviSAP;
GO

IF OBJECT_ID('etl.sp_load_salesmen') IS NOT NULL
    DROP PROCEDURE etl.sp_load_salesmen;
GO

CREATE PROCEDURE etl.sp_load_salesmen
    @RunId bigint = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @started datetime2(3) = SYSUTCDATETIME();
    DECLARE @rows_in bigint = 0, @rows_out bigint = 0;

    BEGIN TRY
        TRUNCATE TABLE staging.est_agents;

        INSERT INTO staging.est_agents (id_salesman, [name])
        SELECT  CASE WHEN SlpCode < 0 THEN '000'
                     ELSE RIGHT('000' + CAST(SlpCode AS varchar(10)), 3) END,
                LEFT(ISNULL(SlpName, ''), 35)
        FROM    sap_raw.OSLP
        WHERE   SlpCode IS NOT NULL;
        SET @rows_out = @@ROWCOUNT;

        SELECT @rows_in = COUNT_BIG(*) FROM sap_raw.OSLP;

        IF @RunId IS NOT NULL
            INSERT [audit].etl_step_log (run_id, step_name, started_at, finished_at, rows_in, rows_out, duration_ms, [status])
            VALUES (@RunId, 'sp_load_salesmen', @started, SYSUTCDATETIME(), @rows_in, @rows_out,
                    DATEDIFF(MILLISECOND, @started, SYSUTCDATETIME()), 'OK');
    END TRY
    BEGIN CATCH
        DECLARE @err nvarchar(max) = ERROR_MESSAGE();
        IF @RunId IS NOT NULL
            INSERT [audit].etl_step_log (run_id, step_name, started_at, finished_at, rows_in, rows_out, duration_ms, [status], error_message)
            VALUES (@RunId, 'sp_load_salesmen', @started, SYSUTCDATETIME(), @rows_in, @rows_out,
                    DATEDIFF(MILLISECOND, @started, SYSUTCDATETIME()), 'ERROR', @err);
        THROW;
    END CATCH
END
GO
