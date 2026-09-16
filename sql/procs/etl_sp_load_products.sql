/* =========================================================================
   etl.sp_load_products   (format KAIS)
   Origen : sap_raw.OITM   (mirall de SAP omplert pel Worker via Service Layer)
   Destino: staging.est_productes
   Mapping:
     id_product            <- ItemCode                  varchar(16)
     name                  <- ItemName                  varchar(90)
     product_categories_id <- ItmsGrpCod o U_SEIFamCialCat, segons el flag de
                              sota                      varchar(250) — KAIS ho
                              fa gran, respectem per idempotència
     active                <- validFor='Y' AND frozenFor<>'Y'   bit
   Filtro: cap (per conservar històric — productes despublicats també).
   NO inclou available_from_date / available_to_date (KAIS no els té).

   QUINA TAXONOMIA VA A ANALITZA
   -----------------------------
   cfg.settings.FAMILY_FROM_COMMERCIAL: '0' = els 110 grups d'article de SAP
   (el que hi ha avui), '1' = la família comercial U_SEIFamCialCat, que són
   les 12 que Analitza ja ensenya.

   Mesurat el 16/09/2026 contra l'històric de vendes de KAIS (bi_estadili,
   12 mesos, amb les mateixes sèries excloses que aplica Analitza): el
   **98,53%** dels 22,26 M€ facturats passa pels 198 articles que SAP ja té
   classificats. Els 782 "sense família" són recanvis, EPI's, palets i material
   de fàbrica: només 28 han facturat res i 7 en fan el 90%.

   Els articles sense família comercial surten amb product_categories_id = ''.
   És a propòsit: cauen al mateix calaix de "sense assignació" que Analitza ja
   té avui, que li val ~1,5% de la facturació. NO s'emet cap fila a
   est_families_productes per a la cadena buida.

   ⚠️ Canviar el flag fa desaparèixer 110 id_product_category de cop i
   `vanished_ids` saltarà com a CRITICAL. És correcte: és un canvi massiu
   previst, de la mateixa categoria que el cutover, i s'ha de fer
   expressament apujant el llindar i tornant-lo a baixar l'endemà.
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

    /* Quina taxonomia va a Analitza. Veure el capçal. */
    DECLARE @family_commercial bit = 0;
    SELECT @family_commercial = ISNULL(TRY_CAST([value] AS bit), 0)
    FROM   cfg.settings WHERE [key] = 'FAMILY_FROM_COMMERCIAL';

    BEGIN TRY
        TRUNCATE TABLE staging.est_productes;

        INSERT INTO staging.est_productes
            (id_product, [name], product_categories_id, active)
        SELECT  LEFT(ItemCode, 16),
                LEFT(ISNULL(ItemName, ''), 90),
                CASE WHEN @family_commercial = 1
                     THEN LEFT(ISNULL(RTRIM(LTRIM(U_SEIFamCialCat)), ''), 250)
                     ELSE LEFT(CAST(ItmsGrpCod AS varchar(250)), 250)
                END,
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
