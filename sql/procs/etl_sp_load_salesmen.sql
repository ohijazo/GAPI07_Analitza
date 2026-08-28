/* =========================================================================
   etl.sp_load_salesmen   (format KAIS)
   Origen : sap_raw.OSLP   (mirall de SAP omplert pel Worker via Service Layer)
   Destino: staging.est_agents
   Mapping:
     id_salesman  <- etl.vw_salesman_code  varchar(3)   -- KAIS: "000", "006", "100"
     name         <- SlpName               varchar(35)
   Nota: SlpCode = -1 ("Sin agente") és preservat (SAP l'usa per fallback).

   ATENCIÓ: l'id NO és el SlpCode. Els codis de comercial NO es van preservar a
   la migració a SAP (SlpCode 2 era '006' a KAIS), i Analitza té l'històric
   penjat dels de KAIS. La regla és COALESCE(U_FCCodiKais, LPAD(SlpCode,3)) i
   viu a etl.vw_salesman_code, que és el mateix que fa servir sp_load_clients
   per omplir est_clients.salesmen_id: si les dues divergeixen, els clients
   apunten a comercials que no existeixen (Regla 04).
   ========================================================================= */
USE IntercanviSAP;
GO

IF OBJECT_ID('etl.sp_load_salesmen') IS NOT NULL
    DROP PROCEDURE etl.sp_load_salesmen;
GO

CREATE PROCEDURE etl.sp_load_salesmen
    @RunId bigint = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @started datetime2(3) = SYSUTCDATETIME();
    DECLARE @rows_in bigint = 0, @rows_out bigint = 0;

    BEGIN TRY
        TRUNCATE TABLE staging.est_agents;

        /* Dos SlpCode poden acabar al mateix id_salesman: el -1 ("sense agent")
           mapeja a '000' i a SAP hi pot haver un comercial amb U_FCCodiKais
           '000'. est_agents té clau primària per id_salesman, així que cal
           agrupar-hi; sense això l'INSERT peta i el run queda BLOCKED. */
        INSERT INTO staging.est_agents (id_salesman, [name])
        SELECT  sc.id_salesman,
                LEFT(ISNULL(MIN(s.SlpName), ''), 35)
        FROM    sap_raw.OSLP AS s
        INNER JOIN etl.vw_salesman_code AS sc
                ON sc.SlpCode = s.SlpCode
        WHERE   s.SlpCode IS NOT NULL
        GROUP BY sc.id_salesman;
        SET @rows_out = @@ROWCOUNT;

        SELECT @rows_in = COUNT_BIG(*) FROM sap_raw.OSLP;

        IF @RunId IS NOT NULL
            INSERT [audit].etl_step_log (run_id, step_name, started_at, finished_at, rows_in, rows_out, duration_ms, [status])
            VALUES (@RunId, 'sp_load_salesmen', @started, SYSUTCDATETIME(), @rows_in, @rows_out,
                    DATEDIFF(MILLISECOND, @started, SYSUTCDATETIME()), 'OK');
    END TRY
    BEGIN CATCH
        DECLARE @err nvarchar(max) = ERROR_MESSAGE();
        IF @RunId IS NOT NULL
            INSERT [audit].etl_step_log (run_id, step_name, started_at, finished_at, rows_in, rows_out, duration_ms, [status], error_message)
            VALUES (@RunId, 'sp_load_salesmen', @started, SYSUTCDATETIME(), @rows_in, @rows_out,
                    DATEDIFF(MILLISECOND, @started, SYSUTCDATETIME()), 'ERROR', @err);
        THROW;
    END CATCH
END
GO
