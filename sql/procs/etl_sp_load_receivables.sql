/* =========================================================================
   etl.sp_load_receivables   (format KAIS — taula est_cobraments)
   Origen : sap_raw.OINV (factures obertes amb saldo)
            (mirall de SAP omplert pel Worker via Service Layer)
   Destino: staging.est_cobraments  (renombrada des de est_clients_efectes_pendents)
   Mapping KAIS:
     id_client_location_receivable  uniqueidentifier  — derivat de DocEntry
                                    determinísticament (HASHBYTES MD5 → 16 bytes)
     client_locations_id            varchar(13)       etl.vw_client_code + '-' + LEFT(ShipToCode,3)
                                    (= COALESCE(U_FCCodiKais, CardCode); Regla 04)
     net_amount                     decimal(16,6)     DocTotal - PaidToDate
     issue_date                     datetime          DocDate
     due_date                       datetime          DocDueDate
     payment_method                 varchar(3)        LEFT(RTRIM(PeyMethod),3)  (o NULL)
   ========================================================================= */
USE IntercanviSAP;
GO

IF OBJECT_ID('etl.sp_load_receivables') IS NOT NULL
    DROP PROCEDURE etl.sp_load_receivables;
GO

CREATE PROCEDURE etl.sp_load_receivables
    @RunId bigint = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @started datetime2(3) = SYSUTCDATETIME();
    DECLARE @rows_in bigint = 0, @rows_out bigint = 0;

    BEGIN TRY
        TRUNCATE TABLE staging.est_cobraments;

        INSERT INTO staging.est_cobraments
            (id_client_location_receivable, client_locations_id, net_amount,
             issue_date, due_date, payment_method)
        SELECT
            CAST(HASHBYTES('MD5', 'OINV-' + CAST(h.DocEntry AS varchar(20))) AS uniqueidentifier)  AS id_client_location_receivable,
            LEFT(COALESCE(cc.client_code, RTRIM(h.CardCode)) + '-' +
                 RIGHT('000' + CAST(COALESCE(ship.ship_no, 0) AS varchar(10)), 3), 13) AS client_locations_id,
            CAST((h.DocTotal - h.PaidToDate) AS decimal(16,6))                                      AS net_amount,
            CAST(h.DocDate    AS datetime)                                                          AS issue_date,
            CAST(h.DocDueDate AS datetime)                                                          AS due_date,
            LEFT(RTRIM(ISNULL(h.PeyMethod, '')), 3)                                                 AS payment_method
        FROM    sap_raw.OINV h
        /* ship_no, no LineNum: veure la capçalera de etl.vw_client_ship. */
        LEFT JOIN etl.vw_client_ship ship
               ON ship.CardCode  = h.CardCode
              AND ship.[Address] = h.ShipToCode
        /* LEFT, no INNER: una factura d'un CardCode que no sigui al mirall ha
           de seguir sortint amb el codi de SAP, no desaparèixer en silenci. */
        LEFT JOIN etl.vw_client_code AS cc
               ON cc.CardCode = h.CardCode
        WHERE   h.DocStatus = 'O'
          AND   (h.DocTotal - h.PaidToDate) > 0
          AND   h.DocDueDate IS NOT NULL;

        SET @rows_out = @@ROWCOUNT;

        SELECT @rows_in = COUNT_BIG(*) FROM sap_raw.OINV;

        IF @RunId IS NOT NULL
            INSERT [audit].etl_step_log (run_id, step_name, started_at, finished_at, rows_in, rows_out, duration_ms, [status])
            VALUES (@RunId, 'sp_load_receivables', @started, SYSUTCDATETIME(), @rows_in, @rows_out,
                    DATEDIFF(MILLISECOND, @started, SYSUTCDATETIME()), 'OK');
    END TRY
    BEGIN CATCH
        DECLARE @err nvarchar(max) = ERROR_MESSAGE();
        IF @RunId IS NOT NULL
            INSERT [audit].etl_step_log (run_id, step_name, started_at, finished_at, rows_in, rows_out, duration_ms, [status], error_message)
            VALUES (@RunId, 'sp_load_receivables', @started, SYSUTCDATETIME(), @rows_in, @rows_out,
                    DATEDIFF(MILLISECOND, @started, SYSUTCDATETIME()), 'ERROR', @err);
        THROW;
    END CATCH
END
GO
