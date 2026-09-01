/* =========================================================================
   etl.sp_assign_client_ship_no
   Origen : sap_raw.CRD1
   Destino: cfg.client_ship_no   (la taula que congela els numeros d'adreça)

   PER QUE EXISTEIX
   ----------------
   id_client_location te dues meitats: <codi de client> + '-' + <numero
   d'adreça>. La dreta la calculavem al vol amb
       ROW_NUMBER() OVER (PARTITION BY CardCode ORDER BY LineNum) - 1
   perque KAIS numerava les adreces de cada client seqüencialment des de 000 i
   el LineNum de SAP no ho fa (un client pot tenir-les a 000, 006, 014).

   El problema del calcul al vol el va explicar l'Adria el 01/09/2026, i es pitjor
   del que semblava. Si s'esborra una adreça a SAP, totes les posteriors del
   mateix client es renumeren. Per a Analitza aixo no es un forat:

     "quan no s'ens passa una adreça (client_locations), s'esborra de
      l'aplicacio i es com si no existis el client, pero mantenim l'historic
      d'albarans per si ha sigut un error. Amb la qual cosa si mes endavant es
      torna a donar d'alta una altra adreça agafaria tot l'historic."

   O sigui que renumerar no perd l'historial: l'ENGANXA A UNA ALTRA ADREÇA. Un
   client veuria compres que no ha fet mai. I es silencios: totes les xifres
   quadren amb elles mateixes.

   QUE FA
   ------
   Assigna un numero a cada adreça de ship-to que encara no en tingui, i **no
   toca mai** els que ja hi son. Les adreces noves agafen max+1 del seu client,
   de manera que un numero alliberat per un esborrat no es reutilitza mai.

   La primera execucio reprodueix EXACTAMENT la numeracio d'avui: com que la
   taula es buida, tots els clients son nous i es numeren 0,1,2... per LineNum,
   que es el que feia el ROW_NUMBER(). Desplegar-ho no canvia cap
   id_client_location.

   PER QUE LA CLAU ES (CardCode, LineNum) I NO (CardCode, Address)
   --------------------------------------------------------------
   El LineNum de SAP es un numero de fila que NO es renumera quan s'esborra una
   germana -per aixo hi ha forats-, aixi que es estable. El que es movia era el
   nostre ROW_NUMBER().

   Amb (CardCode, Address) hi hauria un forat: esborrar una adreça i crear-ne
   una altra amb el mateix nom reutilitzaria el numero, i l'historic de la
   vella cauria sobre la nova. Que es exactament el que volem evitar.

   Es guarda tambe l'Address del moment de congelar. Si algun dia SAP reutilitza
   un LineNum per a una adreça diferent, el check ship_address_changed ho diu.
   No es pot distingir d'un canvi de nom legitim, aixi que avisa i no bloqueja.

   IDEMPOTENT: nomes fa INSERT del que falta.
   ========================================================================= */
USE IntercanviSAP;
GO

IF OBJECT_ID('etl.sp_assign_client_ship_no') IS NOT NULL
    DROP PROCEDURE etl.sp_assign_client_ship_no;
GO

CREATE PROCEDURE etl.sp_assign_client_ship_no
    @RunId bigint = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @started datetime2(3) = SYSUTCDATETIME();
    DECLARE @rows_in bigint = 0, @rows_out bigint = 0;

    BEGIN TRY
        SELECT @rows_in = COUNT_BIG(*) FROM sap_raw.CRD1 WHERE AdresType = 'S';

        /* ISNULL(max_no, -1) + ROW_NUMBER(): per a un client que no te cap
           numero encara, la primera adreça queda a 0, com feia KAIS. Per a un
           que ja en te, les noves continuen des del seu maxim, mai des del
           recompte: si el 001 es va esborrar, el seguent es el 003 i no el 001. */
        INSERT INTO cfg.client_ship_no (CardCode, LineNum, ship_no, [Address])
        SELECT  a.CardCode,
                a.LineNum,
                ISNULL(m.max_no, -1)
                    + ROW_NUMBER() OVER (PARTITION BY a.CardCode ORDER BY a.LineNum),
                a.[Address]
        FROM    sap_raw.CRD1 AS a
        LEFT JOIN (SELECT CardCode, MAX(ship_no) AS max_no
                   FROM   cfg.client_ship_no
                   GROUP BY CardCode) AS m
               ON m.CardCode = a.CardCode
        WHERE   a.AdresType = 'S'
          AND   NOT EXISTS (SELECT 1 FROM cfg.client_ship_no AS f
                            WHERE f.CardCode = a.CardCode AND f.LineNum = a.LineNum);

        SET @rows_out = @@ROWCOUNT;

        IF @RunId IS NOT NULL
            INSERT [audit].etl_step_log (run_id, step_name, started_at, finished_at, rows_in, rows_out, duration_ms, [status], error_message)
            VALUES (@RunId, 'sp_assign_client_ship_no', @started, SYSUTCDATETIME(), @rows_in, @rows_out,
                    DATEDIFF(MILLISECOND, @started, SYSUTCDATETIME()), 'OK',
                    'adreces noves numerades=' + CAST(@rows_out AS varchar(20)));
    END TRY
    BEGIN CATCH
        DECLARE @err nvarchar(max) = ERROR_MESSAGE();
        IF @RunId IS NOT NULL
            INSERT [audit].etl_step_log (run_id, step_name, started_at, finished_at, rows_in, rows_out, duration_ms, [status], error_message)
            VALUES (@RunId, 'sp_assign_client_ship_no', @started, SYSUTCDATETIME(), @rows_in, @rows_out,
                    DATEDIFF(MILLISECOND, @started, SYSUTCDATETIME()), 'ERROR', @err);
        THROW;
    END CATCH
END
GO
