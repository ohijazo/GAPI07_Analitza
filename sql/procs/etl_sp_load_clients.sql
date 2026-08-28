/* =========================================================================
   etl.sp_load_clients   (format KAIS)
   Origen : sap_raw.OCRD + sap_raw.CRD1 (ship-to)
            (mirall de SAP omplert pel Worker via Service Layer)
   Destino: staging.est_clients
   Regles:
     - id_client_location = <codi de client> + '-' + <ShipToCode>  (varchar(13))
       - <codi de client> = etl.vw_client_code = COALESCE(U_FCCodiKais, CardCode)
       - <ShipToCode> = etl.vw_client_ship.ship_no, NO CRD1.LineNum: KAIS
         numerava les adreces seqüencialment per client des de 000 (veure la
         capçalera de la vista)
       - Fila "genèrica" CardCode-000 només si el client NO té cap ship-to a CRD1.
     - active = 1 si validFor='Y' AND (frozenFor IS NULL OR frozenFor='N'), else 0
     - salesmen_id = etl.vw_salesman_code (NO el SlpCode: els codis de comercial
       tampoc es van preservar a la migració)
     - new_code = el codi EMÈS del successor (U_FCNewCardCode passat per la
       mateixa vista), o NULL. Analitza hi concatena '-000' pel seu compte.
     - country_code minúscules; overrides via cfg.country_code_overrides
     - payment_method/holidays/comments NO van a est_clients (KAIS format)

   ATENCIÓ: id_client_location és el contracte amb Analitza (Regla 04). La
   fórmula ha de coincidir EXACTAMENT amb la de sp_load_client_attributes,
   sp_load_invoice_lines i sp_load_receivables. Per això el codi de client surt
   d'una vista i no d'una expressió copiada a cada SP.
   ========================================================================= */
USE IntercanviSAP;
GO

IF OBJECT_ID('etl.sp_load_clients') IS NOT NULL
    DROP PROCEDURE etl.sp_load_clients;
GO

CREATE PROCEDURE etl.sp_load_clients
    @RunId bigint = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @started datetime2(3) = SYSUTCDATETIME();
    DECLARE @rows_in bigint = 0, @rows_out bigint = 0;

    BEGIN TRY
        TRUNCATE TABLE staging.est_clients;

        INSERT INTO staging.est_clients
            (id_client_location, [name], active, [address], city, zip_code,
             country_code, salesmen_id, new_code, phone_number, email)

        /* ---- Fila genèrica per client (CardCode-000) — només si NO té ship-tos ---- */
        SELECT
            LEFT(cc.client_code + '-000', 13)                                       AS id_client_location,
            LEFT(ISNULL(c.CardName, ''), 40)                                        AS [name],
            CASE WHEN c.validFor = 'Y' AND (c.frozenFor = 'N' OR c.frozenFor IS NULL)
                 THEN 1 ELSE 0 END                                                  AS active,
            LEFT(ISNULL(c.[Address], ''), 35)                                       AS [address],
            LEFT(ISNULL(c.City, ''), 35)                                            AS city,
            LEFT(ISNULL(c.ZipCode, ''), 10)                                         AS zip_code,
            LOWER( LEFT( COALESCE( ov.iso2_code, NULLIF(c.Country, ''), 'es' ), 4 ))
                                                                                    AS country_code,
            LEFT(ISNULL(sc.id_salesman, '000'), 3)                                  AS salesmen_id,
            LEFT(succ.client_code, 8)                                               AS new_code,
            LEFT(ISNULL(c.Phone1, ''), 30)                                          AS phone_number,
            LEFT(ISNULL(c.E_Mail, ''), 60)                                          AS email
        FROM   sap_raw.OCRD AS c
        INNER JOIN etl.vw_client_code AS cc
               ON cc.CardCode = c.CardCode
        LEFT JOIN cfg.country_code_overrides AS ov
               ON ov.sap_country_code = c.Country
        LEFT JOIN etl.vw_salesman_code AS sc
               ON sc.SlpCode = c.SlpCode
        LEFT JOIN etl.vw_client_code AS succ
               ON succ.CardCode = NULLIF(LTRIM(RTRIM(c.U_FCNewCardCode)), '')
        WHERE  c.CardType = 'C'
          AND  NOT EXISTS (
                SELECT 1 FROM sap_raw.CRD1 a
                WHERE a.CardCode = c.CardCode AND a.AdresType = 'S'
              )

        UNION ALL

        /* ---- Fila per cada ship-to (CardCode-<LineNum 3-dígits>) ---- */
        SELECT
            LEFT(cc.client_code + '-' + RIGHT('000' + CAST(sh.ship_no AS varchar(10)), 3), 13)
                                                                                    AS id_client_location,
            LEFT(ISNULL(c.CardName, ''), 40)                                        AS [name],
            CASE WHEN c.validFor = 'Y' AND (c.frozenFor = 'N' OR c.frozenFor IS NULL)
                 THEN 1 ELSE 0 END                                                  AS active,
            LEFT(ISNULL(LTRIM(RTRIM(
                   ISNULL(CAST(a.Street   AS varchar(200)), '') + ' ' +
                   ISNULL(CAST(a.StreetNo AS varchar(200)), '') + ' ' +
                   ISNULL(CAST(a.Building AS varchar(200)), ''))), ''), 35)         AS [address],
            LEFT(ISNULL(a.City, ''), 35)                                            AS city,
            LEFT(ISNULL(a.ZipCode, ''), 10)                                         AS zip_code,
            LOWER( LEFT( COALESCE( ov.iso2_code, NULLIF(a.Country, ''), NULLIF(c.Country, ''), 'es' ), 4 ))
                                                                                    AS country_code,
            LEFT(ISNULL(sc.id_salesman, '000'), 3)                                  AS salesmen_id,
            LEFT(succ.client_code, 8)                                               AS new_code,
            LEFT(ISNULL(c.Phone1, ''), 30)                                          AS phone_number,
            LEFT(ISNULL(c.E_Mail, ''), 60)                                          AS email
        FROM   sap_raw.OCRD AS c
        INNER JOIN sap_raw.CRD1 AS a
               ON a.CardCode  = c.CardCode
              AND a.AdresType = 'S'
        INNER JOIN etl.vw_client_ship AS sh
               ON sh.CardCode = a.CardCode AND sh.LineNum = a.LineNum
        INNER JOIN etl.vw_client_code AS cc
               ON cc.CardCode = c.CardCode
        LEFT JOIN cfg.country_code_overrides AS ov
               ON ov.sap_country_code = a.Country
        LEFT JOIN etl.vw_salesman_code AS sc
               ON sc.SlpCode = c.SlpCode
        LEFT JOIN etl.vw_client_code AS succ
               ON succ.CardCode = NULLIF(LTRIM(RTRIM(c.U_FCNewCardCode)), '')
        WHERE  c.CardType = 'C';

        SET @rows_out = @@ROWCOUNT;

        SELECT @rows_in = COUNT_BIG(*) FROM sap_raw.OCRD WHERE CardType = 'C';

        IF @RunId IS NOT NULL
            INSERT [audit].etl_step_log (run_id, step_name, started_at, finished_at, rows_in, rows_out, duration_ms, [status])
            VALUES (@RunId, 'sp_load_clients', @started, SYSUTCDATETIME(), @rows_in, @rows_out,
                    DATEDIFF(MILLISECOND, @started, SYSUTCDATETIME()), 'OK');
    END TRY
    BEGIN CATCH
        DECLARE @err nvarchar(max) = ERROR_MESSAGE();
        IF @RunId IS NOT NULL
            INSERT [audit].etl_step_log (run_id, step_name, started_at, finished_at, rows_in, rows_out, duration_ms, [status], error_message)
            VALUES (@RunId, 'sp_load_clients', @started, SYSUTCDATETIME(), @rows_in, @rows_out,
                    DATEDIFF(MILLISECOND, @started, SYSUTCDATETIME()), 'ERROR', @err);
        THROW;
    END CATCH
END
GO
