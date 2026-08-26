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

   PRECONDICIO: sap_raw ha d'estar fresc. El refresca SapB1AnalitzaSync.Worker,
   que corre al servidor d'aplicacions com a tasca programada, no com a pas
   d'aquest job. Son dos planificadors que no es parlen, aixi que aquest SP
   COMPROVA la frescor del mirall abans de fer res i avorta si es vell.

   Sense aquesta comprovacio, si la tasca del Worker no s'executa, l'ETL
   transformaria el mirall d'ahir i publicaria dades velles com si fossin
   d'avui, sense que saltes res.
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

    /* ---- El mirall es prou fresc? ----
       Es comprova ABANS de tocar staging: si el mirall es vell val mes no
       haver comencat. L'entitat mes endarrerida marca l'edat del conjunt. */
    DECLARE @max_age_h int;
    SELECT @max_age_h = TRY_CAST([value] AS int) FROM cfg.settings WHERE [key] = 'MIRROR_MAX_AGE_HOURS';
    SET @max_age_h = ISNULL(@max_age_h, 6);

    DECLARE @oldest datetime2(0), @age_h int;
    SELECT @oldest = MIN(updated_at) FROM sap_raw.sync_state;

    IF @oldest IS NULL
    BEGIN
        UPDATE [audit].etl_runs
           SET finished_at = SYSUTCDATETIME(), [status] = 'ABORTED_STALE_MIRROR',
               error_message = 'sap_raw.sync_state es buit: el Worker no ha refrescat mai el mirall. No es transforma res.'
         WHERE run_id = @RunId;
        THROW 50101, 'sp_run_all: el mirall sap_raw no s ha refrescat mai. Executeu el Worker.', 1;
    END

    SET @age_h = DATEDIFF(HOUR, @oldest, SYSUTCDATETIME());
    IF @age_h > @max_age_h
    BEGIN
        UPDATE [audit].etl_runs
           SET finished_at = SYSUTCDATETIME(), [status] = 'ABORTED_STALE_MIRROR',
               error_message = 'El mirall sap_raw te ' + CAST(@age_h AS varchar(10)) + ' hores (limit '
                             + CAST(@max_age_h AS varchar(10)) + '). El Worker no ha corregut. dbo.est_* es queda com estava.'
         WHERE run_id = @RunId;
        THROW 50101, 'sp_run_all: el mirall sap_raw es massa vell. Reviseu la tasca del Worker.', 1;
    END

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
