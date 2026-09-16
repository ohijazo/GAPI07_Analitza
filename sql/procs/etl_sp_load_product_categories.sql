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

   QUINA TAXONOMIA VA A ANALITZA
   -----------------------------
   cfg.settings.FAMILY_FROM_COMMERCIAL: '0' = els 110 grups d'article d'OITB
   (el que hi ha avui), '1' = la família comercial OITM.U_SEIFamCialCat, que
   són les ~12 que Analitza ja ensenya i que Analitza recomana no passar de 25.

   Amb el flag a '1' l'identificador **és el nom de la família**: no hi ha cap
   codi darrere a SAP, el camp és de text lliure. Que l'id canviï ja està
   acceptat per l'Adrià. La contrapartida és que reanomenar una família a SAP
   la farà desaparèixer i néixer de nou als ulls d'Analitza.

   Es descarta la cadena buida: els articles sense família comercial (recanvis,
   EPI's, palets) surten amb product_categories_id = '' i cauen al calaix de
   "sense assignació" que Analitza ja té avui. Emetre-hi una fila seria
   inventar-se una família que no existeix.

   ⚠️ Canviar el flag fa desaparèixer 110 identificadors de cop i
   `vanished_ids` saltarà com a CRITICAL. Veure el capçal de sp_load_products.
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

    /* Quina taxonomia va a Analitza. Veure el capçal. */
    DECLARE @family_commercial bit = 0;
    SELECT @family_commercial = ISNULL(TRY_CAST([value] AS bit), 0)
    FROM   cfg.settings WHERE [key] = 'FAMILY_FROM_COMMERCIAL';

    BEGIN TRY
        TRUNCATE TABLE staging.est_families_productes;

        IF @family_commercial = 1
        BEGIN
            INSERT INTO staging.est_families_productes (id_product_category, [name])
            SELECT  DISTINCT LEFT(RTRIM(LTRIM(U_SEIFamCialCat)), 250),
                             LEFT(RTRIM(LTRIM(U_SEIFamCialCat)), 250)
            FROM    sap_raw.OITM
            WHERE   NULLIF(RTRIM(LTRIM(U_SEIFamCialCat)), '') IS NOT NULL;
            SET @rows_out = @@ROWCOUNT;

            SELECT @rows_in = COUNT_BIG(*) FROM sap_raw.OITM;
        END
        ELSE
        BEGIN
            INSERT INTO staging.est_families_productes (id_product_category, [name])
            SELECT  LEFT(CAST(ItmsGrpCod AS varchar(250)), 250),
                    LEFT(ISNULL(ItmsGrpNam, ''), 250)
            FROM    sap_raw.OITB
            WHERE   ItmsGrpCod IS NOT NULL;
            SET @rows_out = @@ROWCOUNT;

            SELECT @rows_in = COUNT_BIG(*) FROM sap_raw.OITB;
        END

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
