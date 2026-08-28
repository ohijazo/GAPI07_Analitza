/* =========================================================================
   etl.sp_load_client_attributes   (format KAIS — WIDE)
   Origen : sap_raw.OCRD + sap_raw.CRD1 + sap_raw.OPYM
            (mirall de SAP omplert pel Worker via Service Layer)
   Destino: staging.est_atributs_client
   ID compat: mateixa fórmula id_client_location que sp_load_clients
              (<codi>-000 genèrica, <codi>-<LineNum> per ship-tos), on el codi
              surt de etl.vw_client_code = COALESCE(U_FCCodiKais, CardCode).
              Les dues han de coincidir EXACTAMENT (Regla 04): per això surten
              de la mateixa vista i no d'una expressió copiada.
   ========================================================================= */
USE IntercanviSAP;
GO

IF OBJECT_ID('etl.sp_load_client_attributes') IS NOT NULL
    DROP PROCEDURE etl.sp_load_client_attributes;
GO

CREATE PROCEDURE etl.sp_load_client_attributes
    @RunId bigint = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @started datetime2(3) = SYSUTCDATETIME();
    DECLARE @rows_in bigint = 0, @rows_out bigint = 0;

    BEGIN TRY
        TRUNCATE TABLE staging.est_atributs_client;

        INSERT INTO staging.est_atributs_client
            (client_locations_id, zone_id, zone_description,
             payment_method, payment_description,
             positioning_bcn_consulting, segmentation_use_1, segmentation_use_2)

        /* Fila genèrica: només si NO té ship-tos. Sense CRD1, no hi ha zona
           → per defecte "SENSE ZONA" via cfg.zone_code_mapping. */
        SELECT
            LEFT(cc.client_code + '-000', 13)                                       AS client_locations_id,
            ISNULL(zm.zone_id, '0000')                                              AS zone_id,
            ISNULL(zm.zone_description, N'SENSE ZONA')                              AS zone_description,
            LEFT(RTRIM(ISNULL(c.PymCode, '')), 3)                                   AS payment_method,
            LEFT(ISNULL(pm.Descript, ''), 35)                                       AS payment_description,
            LEFT(NULLIF(RTRIM(ISNULL(c.U_SEIPOSBC, '')), ''), 250)                  AS positioning_bcn_consulting,
            LEFT(NULLIF(RTRIM(ISNULL(c.U_SEISEGH1, '')), ''), 250)                  AS segmentation_use_1,
            LEFT(NULLIF(RTRIM(ISNULL(c.U_SEISEGH2, '')), ''), 250)                  AS segmentation_use_2
        FROM   sap_raw.OCRD AS c
        INNER JOIN etl.vw_client_code AS cc
               ON cc.CardCode = c.CardCode
        LEFT JOIN sap_raw.OPYM AS pm
               ON pm.PayMethCod = c.PymCode
        LEFT JOIN cfg.zone_code_mapping zm
               ON zm.zone_name = N'SENSE ZONA'
        WHERE  c.CardType = 'C'
          AND  NOT EXISTS (
                SELECT 1 FROM sap_raw.CRD1 a
                WHERE a.CardCode = c.CardCode AND a.AdresType = 'S'
              )

        UNION ALL

        /* Fila per cada ship-to. Zona surt de CRD1.U_SEIZONAC via
           cfg.zone_code_mapping. Casos NULL o buits mapen a "SENSE ZONA". */
        SELECT
            LEFT(cc.client_code + '-' + RIGHT('000' + CAST(sh.ship_no AS varchar(10)), 3), 13)
                                                                                    AS client_locations_id,
            ISNULL(zm.zone_id, '0000')                                              AS zone_id,
            ISNULL(zm.zone_description, N'SENSE ZONA')                              AS zone_description,
            LEFT(RTRIM(ISNULL(c.PymCode, '')), 3)                                   AS payment_method,
            LEFT(ISNULL(pm.Descript, ''), 35)                                       AS payment_description,
            LEFT(NULLIF(RTRIM(ISNULL(c.U_SEIPOSBC, '')), ''), 250)                  AS positioning_bcn_consulting,
            LEFT(NULLIF(RTRIM(ISNULL(c.U_SEISEGH1, '')), ''), 250)                  AS segmentation_use_1,
            LEFT(NULLIF(RTRIM(ISNULL(c.U_SEISEGH2, '')), ''), 250)                  AS segmentation_use_2
        FROM   sap_raw.OCRD AS c
        INNER JOIN sap_raw.CRD1 AS a
               ON a.CardCode  = c.CardCode
              AND a.AdresType = 'S'
        INNER JOIN etl.vw_client_ship AS sh
               ON sh.CardCode = a.CardCode AND sh.LineNum = a.LineNum
        INNER JOIN etl.vw_client_code AS cc
               ON cc.CardCode = c.CardCode
        LEFT JOIN sap_raw.OPYM AS pm
               ON pm.PayMethCod = c.PymCode
        LEFT JOIN cfg.zone_code_mapping zm
               ON zm.zone_name = ISNULL(NULLIF(LTRIM(RTRIM(a.U_SEIZONAC)), ''), N'SENSE ZONA')
        WHERE  c.CardType = 'C';

        SET @rows_out = @@ROWCOUNT;

        SELECT @rows_in = COUNT_BIG(*) FROM sap_raw.OCRD WHERE CardType = 'C';

        IF @RunId IS NOT NULL
            INSERT [audit].etl_step_log (run_id, step_name, started_at, finished_at, rows_in, rows_out, duration_ms, [status])
            VALUES (@RunId, 'sp_load_client_attributes', @started, SYSUTCDATETIME(), @rows_in, @rows_out,
                    DATEDIFF(MILLISECOND, @started, SYSUTCDATETIME()), 'OK');
    END TRY
    BEGIN CATCH
        DECLARE @err nvarchar(max) = ERROR_MESSAGE();
        IF @RunId IS NOT NULL
            INSERT [audit].etl_step_log (run_id, step_name, started_at, finished_at, rows_in, rows_out, duration_ms, [status], error_message)
            VALUES (@RunId, 'sp_load_client_attributes', @started, SYSUTCDATETIME(), @rows_in, @rows_out,
                    DATEDIFF(MILLISECOND, @started, SYSUTCDATETIME()), 'ERROR', @err);
        THROW;
    END CATCH
END
GO
