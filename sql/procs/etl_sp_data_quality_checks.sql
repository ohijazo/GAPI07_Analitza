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
        /* El COLLATE explicit no es decoratiu: la BD es CI_AS, aixi que sense
           ell `country_code <> LOWER(country_code)` es sempre fals i la meitat
           d'aquest check no pot detectar res. Comprovat el 26/08/2026. */
        SELECT @cnt = COUNT(*) FROM staging.est_clients
        WHERE  country_code IS NULL
            OR LEN(country_code) NOT BETWEEN 2 AND 4
            OR country_code COLLATE Latin1_General_CS_AS
               <> LOWER(country_code) COLLATE Latin1_General_CS_AS;
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

        /* ----- 8) Identificadors que desapareixen d'un dia per l'altre -----

           Els identificadors que enviem a Analitza son un contracte: si un
           id_client_location que ahir hi era avui no hi es, Analitza no veu un
           error sino un client que ha deixat de comprar, i el dona per perdut.
           El mateix amb productes, families i comercials.

           dbo.* te la foto d'ahir i staging.* la d'avui, aixi que la comprovacio
           es un EXCEPT. Cobreix una familia sencera de fallades silencioses: un
           camp que es queda buit a l'origen, un filtre que descarta de mes, un
           mapatge que canvia sense avisar. Cap dels altres checks la detecta,
           perque totes deixen les taules coherents amb elles mateixes.

           Es queda en WARN mentre siguin poques i passa a CRITICAL a partir del
           llindar cfg.settings.ID_DROP_MAX. El llindar existeix perque hi ha
           desaparicions legitimes (un client esborrat a SAP), i perque el dia
           del cutover pot caldre apujar-lo expressament. -----*/
        DECLARE @drop_max int;
        SELECT @drop_max = TRY_CAST([value] AS int) FROM cfg.settings WHERE [key] = 'ID_DROP_MAX';
        SET @drop_max = ISNULL(@drop_max, 10);

        IF OBJECT_ID('tempdb..#vanished') IS NOT NULL DROP TABLE #vanished;
        CREATE TABLE #vanished (
            entity varchar(30)  COLLATE DATABASE_DEFAULT NOT NULL,
            id     nvarchar(260) COLLATE DATABASE_DEFAULT NOT NULL
        );

        INSERT #vanished (entity, id)
        SELECT 'est_clients', id_client_location FROM dbo.est_clients
        EXCEPT
        SELECT 'est_clients', id_client_location FROM staging.est_clients;

        INSERT #vanished (entity, id)
        SELECT 'est_productes', id_product FROM dbo.est_productes
        EXCEPT
        SELECT 'est_productes', id_product FROM staging.est_productes;

        INSERT #vanished (entity, id)
        SELECT 'est_agents', id_salesman FROM dbo.est_agents
        EXCEPT
        SELECT 'est_agents', id_salesman FROM staging.est_agents;

        INSERT #vanished (entity, id)
        SELECT 'est_families_productes', id_product_category FROM dbo.est_families_productes
        EXCEPT
        SELECT 'est_families_productes', id_product_category FROM staging.est_families_productes;

        SELECT @cnt = COUNT(*) FROM #vanished;

        IF @cnt > 0
        BEGIN
            DECLARE @vanished_detail nvarchar(max);

            /* Resum per entitat, i uns quants exemples: sense els identificadors
               concrets, el warning obliga a reconstruir la consulta a ma. */
            SELECT @vanished_detail = STRING_AGG(x.txt, '; ') WITHIN GROUP (ORDER BY x.entity)
            FROM (
                SELECT entity, entity + '=' + CAST(COUNT(*) AS varchar(20)) AS txt
                FROM   #vanished GROUP BY entity
            ) x;

            SELECT @vanished_detail = @vanished_detail + '. Exemples: '
                 + STRING_AGG(CAST(y.id AS nvarchar(260)), ', ')
            FROM (SELECT TOP 10 id FROM #vanished ORDER BY entity, id) y;

            IF @cnt > @drop_max
            BEGIN
                INSERT [audit].data_quality_warnings (run_id, check_name, severity, details)
                VALUES (@rid, 'vanished_ids', 'CRITICAL',
                        'Han desaparegut ' + CAST(@cnt AS varchar(20)) + ' identificadors respecte d ahir (llindar '
                        + CAST(@drop_max AS varchar(20)) + '): ' + @vanished_detail);
                SET @CriticalCount = @CriticalCount + 1;
            END
            ELSE
                INSERT [audit].data_quality_warnings (run_id, check_name, severity, details)
                VALUES (@rid, 'vanished_ids', 'WARN',
                        'Han desaparegut ' + CAST(@cnt AS varchar(20)) + ' identificadors respecte d ahir: ' + @vanished_detail);
        END

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
