/* =========================================================================
   etl.sp_data_quality_checks   (format KAIS)
   Executa assertions sobre staging.* abans del swap.
   Registra warnings a audit.data_quality_warnings.
   @CriticalCount OUTPUT: si >0, l'orquestrador HA D'aturar el swap.

   Adaptats al format KAIS:
     - Fórmula net_amount = price × qty × discount  (discount és multiplicador)
     - country_code varchar(4) minúscules
     - No hi ha camp [transaction]
     - invoices_id sense prefix (només DocNum a varchar(13))
   ========================================================================= */
USE IntercanviSAP;
GO

IF OBJECT_ID('etl.sp_data_quality_checks') IS NOT NULL
    DROP PROCEDURE etl.sp_data_quality_checks;
GO

CREATE PROCEDURE etl.sp_data_quality_checks
    @RunId          bigint = NULL,
    @CriticalCount  int OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @started datetime2(3) = SYSUTCDATETIME();
    SET @CriticalCount = 0;

    DECLARE @rid bigint = ISNULL(@RunId, 0);
    DECLARE @cnt int;

    BEGIN TRY
        /* ----- 1) Línies amb client orfe (CRITICAL) ----- */
        SELECT @cnt = COUNT(*)
        FROM   staging.est_linies_albara l
        WHERE  NOT EXISTS (SELECT 1 FROM staging.est_clients c
                           WHERE c.id_client_location = l.client_locations_id);
        IF @cnt > 0
        BEGIN
            INSERT [audit].data_quality_warnings (run_id, check_name, severity, details)
            VALUES (@rid, 'lines_orphan_client', 'CRITICAL',
                    'Linies amb client_locations_id sense match a est_clients: ' + CAST(@cnt AS varchar(20)));
            SET @CriticalCount = @CriticalCount + 1;
        END

        /* ----- 2) Línies amb producte orfe (CRITICAL) ----- */
        SELECT @cnt = COUNT(*)
        FROM   staging.est_linies_albara l
        WHERE  NOT EXISTS (SELECT 1 FROM staging.est_productes p
                           WHERE p.id_product = l.products_id);
        IF @cnt > 0
        BEGIN
            INSERT [audit].data_quality_warnings (run_id, check_name, severity, details)
            VALUES (@rid, 'lines_orphan_product', 'CRITICAL',
                    'Linies amb products_id sense match a est_productes: ' + CAST(@cnt AS varchar(20)));
            SET @CriticalCount = @CriticalCount + 1;
        END

        /* ----- 3) Clients amb agent orfe (WARN) ----- */
        SELECT @cnt = COUNT(*)
        FROM   staging.est_clients c
        WHERE  NOT EXISTS (SELECT 1 FROM staging.est_agents a
                           WHERE a.id_salesman = c.salesmen_id);
        IF @cnt > 0
            INSERT [audit].data_quality_warnings (run_id, check_name, severity, details)
            VALUES (@rid, 'clients_orphan_salesman', 'WARN',
                    'Clients amb salesmen_id sense agent: ' + CAST(@cnt AS varchar(20)));

        /* ----- 4) country_code mal format (CRITICAL) ----- */
        SELECT @cnt = COUNT(*) FROM staging.est_clients
        WHERE  country_code IS NULL
            OR LEN(country_code) NOT BETWEEN 2 AND 4
            OR country_code <> LOWER(country_code);
        IF @cnt > 0
        BEGIN
            INSERT [audit].data_quality_warnings (run_id, check_name, severity, details)
            VALUES (@rid, 'country_code_format', 'CRITICAL',
                    'Clients amb country_code no minuscula o mida <2 o >4: ' + CAST(@cnt AS varchar(20)));
            SET @CriticalCount = @CriticalCount + 1;
        END

        /* ----- 5) Signe quantity vs net_amount (CRITICAL) ----- */
        SELECT @cnt = COUNT(*) FROM staging.est_linies_albara
        WHERE  (quantity > 0 AND net_amount < 0)
            OR (quantity < 0 AND net_amount > 0);
        IF @cnt > 0
        BEGIN
            INSERT [audit].data_quality_warnings (run_id, check_name, severity, details)
            VALUES (@rid, 'sign_mismatch', 'CRITICAL',
                    'Linies amb signe quantity != signe net_amount: ' + CAST(@cnt AS varchar(20)));
            SET @CriticalCount = @CriticalCount + 1;
        END

        /* ----- 6) Fórmula KAIS: net_amount = price × qty × discount (WARN) ----- */
        SELECT @cnt = COUNT(*) FROM staging.est_linies_albara
        WHERE  ABS(ISNULL(net_amount, 0)
                   - ISNULL(product_price, 0) * ISNULL(quantity, 0) * ISNULL(discount, 1)) > 0.01;
        IF @cnt > 0
            INSERT [audit].data_quality_warnings (run_id, check_name, severity, details)
            VALUES (@rid, 'formula_break', 'WARN',
                    'Linies on net_amount != price*qty*discount per > 1c: ' + CAST(@cnt AS varchar(20)));

        /* ----- 7) Pic anòmal en compte de línies del dia (WARN) ----- */
        DECLARE @today_count int, @avg_count float;
        DECLARE @yday date = DATEADD(DAY, -1, CAST(SYSUTCDATETIME() AS date));
        SELECT @today_count = COUNT(*) FROM staging.est_linies_albara WHERE CAST([date] AS date) = @yday;
        SELECT @avg_count = AVG(CAST(c AS float))
        FROM (
            SELECT CAST([date] AS date) AS d, COUNT(*) AS c
            FROM   staging.est_linies_albara
            WHERE  CAST([date] AS date) BETWEEN DATEADD(DAY,-28,@yday) AND DATEADD(DAY,-1,@yday)
              AND  DATENAME(WEEKDAY, CAST([date] AS date)) = DATENAME(WEEKDAY, @yday)
            GROUP BY CAST([date] AS date)
        ) x;
        IF @avg_count > 0 AND
           (@today_count < @avg_count * 0.5 OR @today_count > @avg_count * 1.5)
            INSERT [audit].data_quality_warnings (run_id, check_name, severity, details)
            VALUES (@rid, 'volume_anomaly', 'WARN',
                    'Recompte linies dia ' + CONVERT(varchar(10),@yday,23)
                    + ' (' + CAST(@today_count AS varchar(20)) + ') fora del +/-50% de la mitjana 4w del mateix dia setmana ('
                    + CAST(@avg_count AS varchar(20)) + ').');

        IF @RunId IS NOT NULL
            INSERT [audit].etl_step_log (run_id, step_name, started_at, finished_at, duration_ms, [status], error_message)
            VALUES (@RunId, 'sp_data_quality_checks', @started, SYSUTCDATETIME(),
                    DATEDIFF(MILLISECOND, @started, SYSUTCDATETIME()), 'OK',
                    'critical=' + CAST(@CriticalCount AS varchar(10)));
    END TRY
    BEGIN CATCH
        DECLARE @err nvarchar(max) = ERROR_MESSAGE();
        IF @RunId IS NOT NULL
            INSERT [audit].etl_step_log (run_id, step_name, started_at, finished_at, duration_ms, [status], error_message)
            VALUES (@RunId, 'sp_data_quality_checks', @started, SYSUTCDATETIME(),
                    DATEDIFF(MILLISECOND, @started, SYSUTCDATETIME()), 'ERROR', @err);
        THROW;
    END CATCH
END
GO
