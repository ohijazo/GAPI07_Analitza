/* =========================================================================
   etl.sp_assign_client_ship_no
   Origen : sap_raw.CRD1, etl.vw_client_ship_kais_no
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

   ⚠️ EL 29/09/2026 ES VA VEURE QUE EL NUMERO CONGELAT ERA EL MALAMENT
   ------------------------------------------------------------------
   Aquest capcal deia:

     "La primera execucio reprodueix EXACTAMENT la numeracio d'avui: com que la
      taula es buida, tots els clients son nous i es numeren 0,1,2... per
      LineNum, que es el que feia el ROW_NUMBER(). Desplegar-ho no canvia cap
      id_client_location."

   Era cert i era el bug. Congelar va aturar la renumeracio, pero va congelar un
   numero que NO era el de KAIS. El de KAIS viu al PREFIX del nom de l'adreça de
   SAP, que hi va escriure la migracio KAIS->SAP:

       C251271 / LineNum 4   '000-CREATIVE FOODING SL-BARCELONA'
       C251271 / LineNum 12  '002-CREATIVE FOODING SL-BARCELONA'
       C251271 / LineNum 14  '001-CREATIVE FOODING SL-BARCELONA'

   El ROW_NUMBER li donava 0,1,2 per LineNum: una PERMUTACIO dels numeros bons.
   Mesurat contra l'exportacio d'Analitza (5.572 adreces amb codi postal):
   88,3% amb el ROW_NUMBER, 99,9% amb el prefix. El detall i els tres
   mesuraments son al capcal de etl.vw_client_ship_kais_no.

   La taula es va re-congelar amb
   sql\migrations\2026-09-29_ship_no_from_address_prefix.sql, i aquest
   procediment fa servir la MATEIXA regla per a les adreces noves.

   QUE FA
   ------
   Assigna un numero a cada adreça de ship-to que encara no en tingui, i **no
   toca mai** els que ja hi son.

     1) El prefix de KAIS, si el nom de l'adreça en porta i aquell numero esta
        lliure dins del client                                      -> 'PREFIX'
     2) Si no, max+1 del seu client, com sempre                   -> 'MAXPLUS1'

   ⚠️ La primera execucio despres de la migracio ha de numerar **0 adreces**. Es
   la prova barata que la migracio i aquest procediment fan servir la mateixa
   regla: si en numera alguna, o la migracio s'ha deixat una fila, o el patro no
   es el mateix.

   PER QUE LA CLAU SEGUEIX SENT (CardCode, LineNum) I NO (CardCode, Address)
   ------------------------------------------------------------------------
   El LineNum de SAP es un numero de fila que NO es renumera quan s'esborra una
   germana -per aixo hi ha forats-, aixi que es estable. El que es movia era el
   nostre ROW_NUMBER().

   Amb (CardCode, Address) hi hauria un forat: esborrar una adreça i crear-ne
   una altra amb el mateix nom reutilitzaria el numero, i l'historic de la
   vella cauria sobre la nova. Que es exactament el que volem evitar.

   ⚠️ Llegir el prefix NO contradiu res d'aixo, i convé dir-ho perque el proper
   lector no ho prengui per una regressio: el prefix es l'ORIGEN DEL VALOR, no
   la clau. La clau segueix sent el LineNum, aixi que esborrar una adreça i
   crear-ne una altra amb el mateix nom segueix donant una fila NOVA; i si aquell
   nom porta un prefix que ja esta ocupat, el NOT EXISTS el rebutja i cau a
   max+1. Com que la taula nomes s'hi AFEGEIX, "ocupat" inclou els numeros de les
   adreces esborrades a SAP: el cami del prefix tampoc no pot ressuscitar un
   numero alliberat.

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
    DECLARE @rows_in bigint = 0, @rows_out bigint = 0, @by_prefix bigint = 0;

    BEGIN TRY
        SELECT @rows_in = COUNT_BIG(*) FROM sap_raw.CRD1 WHERE AdresType = 'S';

        /* Les adreces que encara no tenen numero, amb el seu prefix de KAIS. */
        IF OBJECT_ID('tempdb..#nova') IS NOT NULL DROP TABLE #nova;
        CREATE TABLE #nova (
            CardCode   nvarchar(15) COLLATE DATABASE_DEFAULT NOT NULL,
            LineNum    int          NOT NULL,
            [Address]  nvarchar(50) COLLATE DATABASE_DEFAULT NULL,
            kais_no    int          NULL,
            use_prefix bit          NOT NULL,
            PRIMARY KEY (CardCode, LineNum)
        );

        INSERT #nova (CardCode, LineNum, [Address], kais_no, use_prefix)
        SELECT  k.CardCode,
                k.LineNum,
                k.[Address],
                k.kais_no,
                use_prefix =
                    CASE WHEN k.kais_no IS NOT NULL
                          /* lliure dins del client. cfg.client_ship_no nomes
                             s'hi afegeix, aixi que aixo cobreix tambe els
                             numeros de les adreces ja esborrades a SAP. */
                          AND NOT EXISTS (SELECT 1 FROM cfg.client_ship_no AS o
                                          WHERE o.CardCode = k.CardCode
                                            AND o.ship_no  = k.kais_no)
                          /* i cap altra adreça nova del mateix lot el reclama
                             abans: guanya el LineNum mes baix. */
                          AND NOT EXISTS (SELECT 1 FROM etl.vw_client_ship_kais_no AS o2
                                          WHERE o2.CardCode = k.CardCode
                                            AND o2.kais_no  = k.kais_no
                                            AND o2.LineNum  < k.LineNum
                                            AND NOT EXISTS (SELECT 1 FROM cfg.client_ship_no AS f2
                                                            WHERE f2.CardCode = o2.CardCode
                                                              AND f2.LineNum  = o2.LineNum))
                         THEN 1 ELSE 0 END
        FROM    etl.vw_client_ship_kais_no AS k
        WHERE   NOT EXISTS (SELECT 1 FROM cfg.client_ship_no AS f
                            WHERE f.CardCode = k.CardCode AND f.LineNum = k.LineNum);

        /* Sostre del max+1. Ha de superar tambe els prefixos que es reclamen en
           aquest mateix lot, o un max+1 hi cauria a sobre. */
        IF OBJECT_ID('tempdb..#base') IS NOT NULL DROP TABLE #base;
        CREATE TABLE #base (CardCode nvarchar(15) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY, base_no int NOT NULL);

        INSERT #base (CardCode, base_no)
        SELECT CardCode, MAX(no)
        FROM ( SELECT CardCode, ship_no AS no FROM cfg.client_ship_no
               UNION ALL
               SELECT CardCode, kais_no      FROM #nova WHERE use_prefix = 1 ) AS z
        GROUP BY CardCode;

        /* Dues branques i no un CASE dins d'un sol SELECT: el ROW_NUMBER() del
           max+1 s'ha de comptar NOMES sobre les files de max+1, o deixaria
           forats a la numeracio. */
        INSERT INTO cfg.client_ship_no (CardCode, LineNum, ship_no, [Address], ship_no_source)
        SELECT  n.CardCode, n.LineNum, n.kais_no, n.[Address], 'PREFIX'
        FROM    #nova AS n
        WHERE   n.use_prefix = 1
        UNION ALL
        SELECT  n.CardCode, n.LineNum,
                ISNULL(b.base_no, -1)
                    + ROW_NUMBER() OVER (PARTITION BY n.CardCode ORDER BY n.LineNum),
                n.[Address], 'MAXPLUS1'
        FROM    #nova AS n
        LEFT JOIN #base AS b ON b.CardCode = n.CardCode
        WHERE   n.use_prefix = 0;

        SET @rows_out = @@ROWCOUNT;
        SELECT @by_prefix = COUNT_BIG(*) FROM #nova WHERE use_prefix = 1;

        DROP TABLE #nova;
        DROP TABLE #base;

        IF @RunId IS NOT NULL
            INSERT [audit].etl_step_log (run_id, step_name, started_at, finished_at, rows_in, rows_out, duration_ms, [status], error_message)
            VALUES (@RunId, 'sp_assign_client_ship_no', @started, SYSUTCDATETIME(), @rows_in, @rows_out,
                    DATEDIFF(MILLISECOND, @started, SYSUTCDATETIME()), 'OK',
                    'adreces noves numerades=' + CAST(@rows_out AS varchar(20))
                    + ' (amb numero de KAIS=' + CAST(@by_prefix AS varchar(20))
                    + ', amb max+1=' + CAST(@rows_out - @by_prefix AS varchar(20)) + ')');
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
