/* =========================================================================
   etl.sp_swap_staging_to_prod   (format KAIS)
   Swap atòmic: per a cada taula est_*, TRUNCATE + INSERT en una sola
   transacció. Analitza mai no veu dades parcials.
   ========================================================================= */
USE IntercanviSAP;
GO

IF OBJECT_ID('etl.sp_swap_staging_to_prod') IS NOT NULL
    DROP PROCEDURE etl.sp_swap_staging_to_prod;
GO

CREATE PROCEDURE etl.sp_swap_staging_to_prod
    @RunId bigint = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @started datetime2(3) = SYSUTCDATETIME();
    DECLARE @rows bigint = 0;

    BEGIN TRY
        BEGIN TRANSACTION;

            TRUNCATE TABLE dbo.est_agents;
            INSERT INTO dbo.est_agents (id_salesman, [name])
            SELECT id_salesman, [name] FROM staging.est_agents;

            TRUNCATE TABLE dbo.est_families_productes;
            INSERT INTO dbo.est_families_productes (id_product_category, [name])
            SELECT id_product_category, [name] FROM staging.est_families_productes;

            TRUNCATE TABLE dbo.est_productes;
            INSERT INTO dbo.est_productes
                (id_product, [name], product_categories_id, active)
            SELECT id_product, [name], product_categories_id, active
            FROM   staging.est_productes;

            TRUNCATE TABLE dbo.est_clients;
            INSERT INTO dbo.est_clients
                (id_client_location, [name], active, [address], city, zip_code,
                 country_code, salesmen_id, new_code, phone_number, email)
            SELECT id_client_location, [name], active, [address], city, zip_code,
                   country_code, salesmen_id, new_code, phone_number, email
            FROM   staging.est_clients;

            TRUNCATE TABLE dbo.est_linies_albara;
            INSERT INTO dbo.est_linies_albara
                (id_invoice_line, invoices_id, [date], client_locations_id, products_id,
                 product_price, product_cost, product_cost_2, net_amount, discount,
                 quantity, series, observations)
            SELECT id_invoice_line, invoices_id, [date], client_locations_id, products_id,
                   product_price, product_cost, product_cost_2, net_amount, discount,
                   quantity, series, observations
            FROM   staging.est_linies_albara;
            SET @rows = @rows + @@ROWCOUNT;

            TRUNCATE TABLE dbo.est_atributs_client;
            INSERT INTO dbo.est_atributs_client
                (client_locations_id, zone_id, zone_description,
                 payment_method, payment_description,
                 positioning_bcn_consulting, segmentation_use_1, segmentation_use_2)
            SELECT client_locations_id, zone_id, zone_description,
                   payment_method, payment_description,
                   positioning_bcn_consulting, segmentation_use_1, segmentation_use_2
            FROM   staging.est_atributs_client;

            TRUNCATE TABLE dbo.est_atributs_producte;
            INSERT INTO dbo.est_atributs_producte
                (art_codi, subfamily_description, units_description)
            SELECT art_codi, subfamily_description, units_description
            FROM   staging.est_atributs_producte;

            TRUNCATE TABLE dbo.est_cobraments;
            INSERT INTO dbo.est_cobraments
                (id_client_location_receivable, client_locations_id, net_amount,
                 issue_date, due_date, payment_method)
            SELECT id_client_location_receivable, client_locations_id, net_amount,
                   issue_date, due_date, payment_method
            FROM   staging.est_cobraments;

        COMMIT TRANSACTION;

        IF @RunId IS NOT NULL
            INSERT [audit].etl_step_log (run_id, step_name, started_at, finished_at, rows_out, duration_ms, [status])
            VALUES (@RunId, 'sp_swap_staging_to_prod', @started, SYSUTCDATETIME(), @rows,
                    DATEDIFF(MILLISECOND, @started, SYSUTCDATETIME()), 'OK');
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        DECLARE @err nvarchar(max) = ERROR_MESSAGE();
        IF @RunId IS NOT NULL
            INSERT [audit].etl_step_log (run_id, step_name, started_at, finished_at, duration_ms, [status], error_message)
            VALUES (@RunId, 'sp_swap_staging_to_prod', @started, SYSUTCDATETIME(),
                    DATEDIFF(MILLISECOND, @started, SYSUTCDATETIME()), 'ERROR', @err);
        THROW;
    END CATCH
END
GO
