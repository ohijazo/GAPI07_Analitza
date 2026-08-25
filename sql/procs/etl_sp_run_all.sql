/* =========================================================================
   etl.sp_run_all   (orquestrador)
   Crida tots els SP en l'ordre adequat:
       1. categories
       2. agents
       3. clients
       4. products
       5. invoice_lines
       6. client_attributes
       7. product_attributes
       8. receivables (opcional)
       9. data_quality_checks
      10. swap_staging_to_prod  (nomes si critical_count = 0)
   Loga a audit.etl_runs el resultat global.

   PRECONDICIO: sap_raw ha d'estar fresc. El refresca SapB1AnalitzaSync.Worker
   llegint SAP per Service Layer; al job Analitza_ETL_Daily el Worker es el
   pas 1 i aquest SP el pas 2. Si el mirall es vell, aquest SP carregara dades
   velles sense adonar-se'n: mirar sap_raw.sync_state si algun recompte sorpren.
   =========================================================================*/
USE IntercanviSAP;
GO

IF OBJECT_ID('etl.sp_run_all') IS NOT NULL
    DROP PROCEDURE etl.sp_run_all;
GO

CREATE PROCEDURE etl.sp_run_all
    @ForceFullLines bit = 0,
    @SkipSwap       bit = 0   -- util per a tests sense afectar dbo.*
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @RunId bigint;
    INSERT [audit].etl_runs (started_at, [status], triggered_by)
    VALUES (SYSUTCDATETIME(), 'RUNNING', SUSER_SNAME());
    SET @RunId = SCOPE_IDENTITY();

    DECLARE @critical int = 0;

    BEGIN TRY
        EXEC etl.sp_load_product_categories @RunId = @RunId;
        EXEC etl.sp_load_salesmen           @RunId = @RunId;
        EXEC etl.sp_load_clients            @RunId = @RunId;
        EXEC etl.sp_load_products           @RunId = @RunId;
        EXEC etl.sp_load_invoice_lines      @RunId = @RunId, @ForceFull = @ForceFullLines;
        EXEC etl.sp_load_client_attributes  @RunId = @RunId;
        EXEC etl.sp_load_product_attributes @RunId = @RunId;
        EXEC etl.sp_load_receivables        @RunId = @RunId;

        EXEC etl.sp_data_quality_checks     @RunId = @RunId,
                                            @CriticalCount = @critical OUTPUT;

        IF @critical = 0 AND @SkipSwap = 0
        BEGIN
            EXEC etl.sp_swap_staging_to_prod @RunId = @RunId;
            UPDATE [audit].etl_runs
               SET finished_at = SYSUTCDATETIME(),
                   [status]    = 'SUCCESS'
             WHERE run_id = @RunId;
        END
        ELSE IF @critical > 0
        BEGIN
            UPDATE [audit].etl_runs
               SET finished_at   = SYSUTCDATETIME(),
                   [status]      = 'BLOCKED',
                   error_message = 'DataQuality CRITICAL count=' + CAST(@critical AS varchar(10)) + ' - swap NO realitzat. Reviseu audit.data_quality_warnings.'
             WHERE run_id = @RunId;
            THROW 50100, 'sp_run_all: data quality CRITICAL warnings, swap abortat.', 1;
        END
        ELSE
        BEGIN
            UPDATE [audit].etl_runs
               SET finished_at = SYSUTCDATETIME(),
                   [status]    = 'SUCCESS_NOSWAP'
             WHERE run_id = @RunId;
        END
    END TRY
    BEGIN CATCH
        DECLARE @err nvarchar(max) = ERROR_MESSAGE();
        UPDATE [audit].etl_runs
           SET finished_at   = SYSUTCDATETIME(),
               [status]      = 'FAILED',
               error_message = @err
         WHERE run_id = @RunId;
        THROW;
    END CATCH
END
GO
