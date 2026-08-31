/* =========================================================================
   etl.sp_load_invoice_lines   (format KAIS)   -- SP CLAU
   Origen : sap_raw.{ODLN/DLN1, ORDN/RDN1, ORIN/RIN1}
            (mirall de SAP omplert pel Worker via Service Layer)
   Destino: staging.est_linies_albara

   Regles KAIS:
     - id_invoice_line = int. Determinista per DocEntry+LineNum+source:
         DLN: 100_000_000 + DocEntry*100 + LineNum
         RDN: 200_000_000 + DocEntry*100 + LineNum
         RIN: 300_000_000 + DocEntry*100 + LineNum
       (DocEntry màx ~10⁷, LineNum màx <100 → int fits, ids únics)
     - invoices_id = LEFT(DocNum, 13)  (varchar(13), sense prefix)
     - date        = datetime (KAIS usa datetime, no date)
     - client_locations_id = etl.vw_client_code + '-' + LEFT(ShipToCode, 3)
       (= COALESCE(U_FCCodiKais, CardCode): els ids que veu Analitza són els de
       KAIS, no els CardCode de SAP — Regla 04. Mateixa vista que sp_load_clients)
     - **discount = multiplicador** (1.00 = no desc, 0.90 = 10% desc)
       Fórmula: (1 - disc_line) * (1 - disc_header)
       decimal(9,6): amb decimal(5,2) un 3,33% quedava 0,97 i el check
       formula_break saltava contra un net_amount de precisió completa

       Aquesta convenció la va heretar KAIS i **està previst canviar-la el dia
       del cutover**: la guia d'Analitza diu que discount és el percentatge
       (0.25 = 25%) i ells ho tapen amb un "1 - discount" a les seves SQL. El
       canvi el mana cfg.settings.DISCOUNT_AS_PERCENT i està desactivat ('0').
       Veure "LA CONVENCIÓ DEL DISCOUNT" més avall i docs/runbook_cutover.md.
     - net_amount = quantity * product_price * discount
     - signe negatiu per Returns (RDN) i Credit Memos (RIN)
     - series = últims 2 dígits del codi de sèrie SAP (varchar(2))
     - observations = h.Comments  (varchar(max) — equivalent modern de text)
   Filtres:
     - LineType <> 'T' (comentaris fora)
     - ItemCode NOT NULL

   LA CONVENCIÓ DEL DISCOUNT
   -------------------------
   cfg.settings.DISCOUNT_AS_PERCENT: '0' = multiplicador (el que hi ha avui),
   '1' = percentatge (el que demana la guia d'Analitza). Es toca **un sol dia**,
   el del cutover, i coordinadament amb ells: si Analitza no treu el seu
   "1 - discount" el mateix dia, els imports li surten a zero. És una fallada
   sorollosa a propòsit, molt millor que una de silenciosa.

   La conversió NO va a les tres branques del UNION ALL. Estaria repetida tres
   vegades i és exactament el patró que la Regla 04 avisa de no repetir. Va a
   dos punts, tots dos aquí:

     1. La còpia dbo → staging del mode incremental **desfà** la conversió, de
        manera que a mig SP tot staging és uniformement un multiplicador. Sense
        això, les línies que vénen de dbo ja portarien el percentatge i el pas 2
        els donaria la volta dues vegades: net_amount i discount quedarien
        incoherents entre elles i el formula_break saltaria només per aquestes.
     2. Un sol UPDATE al final, quan la taula ja és completa.

   El pas 1 només és correcte si dbo ja està en la convenció d'ara, i **el dia
   que es canvia no ho està**: dbo porta la d'ahir. Si es deixés així, les
   línies velles sortirien en multiplicador i les noves en percentatge, dins la
   mateixa taula i sense que cap check ho veiés — la fallada d'aquesta casa.
   Per això sp_swap_staging_to_prod deixa escrit a
   cfg.settings.DISCOUNT_AS_PERCENT_PUBLISHED amb quina convenció va publicar, i
   aquí es força FULL quan no coincideix amb la d'ara. El mode FULL ignora dbo,
   i des que l'origen és local ja no és car. No depèn que ningú se'n recordi.

   MODE FULL vs INCREMENTAL
   ------------------------
   Es conserva tal com era abans de la migració. Ara que l'origen és local
   (sap_raw), el mode FULL ja no és car; l'INCREMENTAL es manté perquè fa de
   xarxa de seguretat: preserva des de dbo les línies dels documents que no
   es refresquen, de manera que un forat al mirall no esborra històric.
   ========================================================================= */
USE IntercanviSAP;
GO

IF OBJECT_ID('etl.sp_load_invoice_lines') IS NOT NULL
    DROP PROCEDURE etl.sp_load_invoice_lines;
GO

CREATE PROCEDURE etl.sp_load_invoice_lines
    @RunId     bigint = NULL,
    @ForceFull bit    = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @started datetime2(3) = SYSUTCDATETIME();
    DECLARE @rows_in bigint = 0, @rows_out bigint = 0;

    /* Mode FULL vs INCREMENTAL */
    DECLARE @full_weekday int = 7, @window_days int = 7;
    SELECT @full_weekday = TRY_CAST([value] AS int) FROM cfg.settings WHERE [key] = 'FULL_RELOAD_WEEKDAY';
    SELECT @window_days  = TRY_CAST([value] AS int) FROM cfg.settings WHERE [key] = 'INCREMENTAL_WINDOW_DAYS';

    /* Convenció del discount cap a Analitza, i amb quina es va publicar dbo.
       Veure el capçal. */
    DECLARE @discount_as_percent bit = 0, @discount_published bit = 0;
    SELECT @discount_as_percent = ISNULL(TRY_CAST([value] AS bit), 0)
    FROM   cfg.settings WHERE [key] = 'DISCOUNT_AS_PERCENT';
    SELECT @discount_published  = ISNULL(TRY_CAST([value] AS bit), 0)
    FROM   cfg.settings WHERE [key] = 'DISCOUNT_AS_PERCENT_PUBLISHED';

    DECLARE @today  date = CAST(SYSUTCDATETIME() AS date);
    DECLARE @cutoff date = DATEADD(DAY, -ISNULL(@window_days, 7), @today);
    DECLARE @dow_iso int = ((DATEPART(WEEKDAY, @today) + @@DATEFIRST + 5) % 7) + 1;

    DECLARE @full_mode bit = 0;
    IF @ForceFull = 1                                    SET @full_mode = 1;
    IF @dow_iso = ISNULL(@full_weekday, 7)               SET @full_mode = 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.est_linies_albara)  SET @full_mode = 1;
    /* dbo esta en una convencio de discount diferent de la d'ara: no s'hi pot
       copiar res a sobre. Passa un sol dia, el del canvi. Veure el capcal. */
    IF @discount_as_percent <> @discount_published       SET @full_mode = 1;

    BEGIN TRY
        TRUNCATE TABLE staging.est_linies_albara;

        /* --------- INCREMENTAL: copiar des de dbo els docs no refrescats --------- */
        IF @full_mode = 0
        BEGIN
            IF OBJECT_ID('tempdb..#refresh_docs') IS NOT NULL DROP TABLE #refresh_docs;
            CREATE TABLE #refresh_docs (
                source    char(3) COLLATE DATABASE_DEFAULT NOT NULL,
                doc_entry int NOT NULL,
                PRIMARY KEY (source, doc_entry)
            );

            INSERT INTO #refresh_docs (source, doc_entry)
            SELECT 'DLN', h.DocEntry FROM sap_raw.ODLN h WHERE h.DocDate >= @cutoff OR h.UpdateDate >= @cutoff
            UNION
            SELECT 'RDN', h.DocEntry FROM sap_raw.ORDN h WHERE h.DocDate >= @cutoff OR h.UpdateDate >= @cutoff
            UNION
            SELECT 'RIN', h.DocEntry FROM sap_raw.ORIN h WHERE h.DocDate >= @cutoff OR h.UpdateDate >= @cutoff;

            /* Copiem de dbo→staging tot allò que NO refrescarem. La regla d'identificació
               del source es fa via ranges de id_invoice_line: 1e8=DLN, 2e8=RDN, 3e8=RIN */
            INSERT INTO staging.est_linies_albara
                (id_invoice_line, invoices_id, [date], client_locations_id, products_id,
                 product_price, product_cost, product_cost_2, net_amount, discount,
                 quantity, series, observations)
            SELECT l.id_invoice_line, l.invoices_id, l.[date], l.client_locations_id, l.products_id,
                   l.product_price, l.product_cost, l.product_cost_2, l.net_amount,
                   /* Aquestes línies vénen de dbo, o sigui en la convenció que
                      ja s'ha publicat. Es normalitzen a multiplicador perquè
                      l'UPDATE del final les tracti igual que les del mirall. */
                   CAST(CASE WHEN @discount_as_percent = 1 THEN 1 - l.discount
                             ELSE l.discount END AS decimal(9,6)),
                   l.quantity, l.series, l.observations
            FROM   dbo.est_linies_albara l
            WHERE  NOT EXISTS (
                SELECT 1 FROM #refresh_docs r
                WHERE  r.doc_entry = (l.id_invoice_line % 100000000) / 100
                  AND  r.source =
                        CASE WHEN l.id_invoice_line BETWEEN 100000000 AND 199999999 THEN 'DLN'
                             WHEN l.id_invoice_line BETWEEN 200000000 AND 299999999 THEN 'RDN'
                             WHEN l.id_invoice_line BETWEEN 300000000 AND 399999999 THEN 'RIN'
                             ELSE 'XXX' END
            );
        END

        /* --------- Càrrega des del mirall ---------
           Els tres orígens són la mateixa forma (a Service Layer són la mateixa
           entitat, SAPB1.Document), així que van en un sol INSERT amb UNION ALL.
           L'única cosa que canvia és l'offset de l'id, el signe i el parell de taules.

           La finestra incremental s'expressa amb el predicat
               (@full_mode = 1 OR DocDate >= @cutoff OR UpdateDate >= @cutoff)
           en comptes de concatenar SQL. OPTION (RECOMPILE) al final perquè el
           pla no es quedi cachejat amb el mode equivocat. */

        INSERT INTO staging.est_linies_albara
            (id_invoice_line, invoices_id, [date], client_locations_id, products_id,
             product_price, product_cost, product_cost_2, net_amount, discount,
             quantity, series, observations)

        /* ---- DLN (Delivery Notes) ---- */
        SELECT
            CAST(100000000 + l.DocEntry * 100 + l.LineNum AS int)                          AS id_invoice_line,
            LEFT(CAST(h.DocNum AS varchar(13)), 13)                                        AS invoices_id,
            CAST(h.DocDate AS datetime)                                                    AS [date],
            LEFT(COALESCE(cc.client_code, RTRIM(h.CardCode)) + '-' +
                 RIGHT('000' + CAST(COALESCE(ship.ship_no, 0) AS varchar(10)), 3), 13)   AS client_locations_id,
            LEFT(l.ItemCode, 16)                                                           AS products_id,
            CAST(ISNULL(l.PriceBefDi, 0) AS decimal(16,6))                                 AS product_price,
            CAST(ISNULL(l.StockPrice, 0) AS decimal(16,6))                                 AS product_cost,
            CAST(ISNULL(l.StockPrice, 0) AS decimal(16,6))                                 AS product_cost_2,
            CAST(
                l.Quantity * ISNULL(l.PriceBefDi, 0)
                      * (1 - ISNULL(l.DiscPrcnt, 0) / 100.0)
                      * (1 - CASE WHEN ISNULL(h.DiscPrcnt, 0) > 0 THEN h.DiscPrcnt / 100.0
                                  WHEN ISNULL(h.DiscSum, 0)   > 0
                                       AND (h.DocTotal - h.VatSum + h.DiscSum) > 0
                                       THEN h.DiscSum / (h.DocTotal - h.VatSum + h.DiscSum)
                                  ELSE 0 END)
                AS numeric(38, 6))                                                         AS net_amount,
            CAST(
                (1 - ISNULL(l.DiscPrcnt, 0) / 100.0) *
                (1 - CASE WHEN ISNULL(h.DiscPrcnt, 0) > 0 THEN h.DiscPrcnt / 100.0
                          WHEN ISNULL(h.DiscSum, 0)   > 0
                               AND (h.DocTotal - h.VatSum + h.DiscSum) > 0
                               THEN h.DiscSum / (h.DocTotal - h.VatSum + h.DiscSum)
                          ELSE 0 END)
                AS decimal(9, 6))                                                          AS discount,
            CAST(l.Quantity AS decimal(11, 3))                                              AS quantity,
            RIGHT('00' + CAST(ISNULL(h.Series, 0) AS varchar(10)), 2)                      AS series,
            CAST(ISNULL(h.Comments, '') AS varchar(max))                                   AS observations
        FROM   sap_raw.ODLN h
        INNER JOIN sap_raw.DLN1 l ON l.DocEntry = h.DocEntry
        /* ship_no, no LineNum: la meitat dreta de id_client_location és el
           número seqüencial d'adreça que feia servir KAIS. Si el ShipToCode del
           document no lliga amb cap adreça, cau a 0, que és la primera del
           client (o la fila genèrica si no en té cap). */
        LEFT JOIN etl.vw_client_ship ship
               ON ship.CardCode  = h.CardCode
              AND ship.[Address] = h.ShipToCode
        /* LEFT, no INNER: un document d'un CardCode que no sigui al mirall
           (no és cCustomer, o encara no s'ha sincronitzat) ha de seguir sortint
           amb el codi de SAP, no desaparèixer en silenci. */
        LEFT JOIN etl.vw_client_code AS cc
               ON cc.CardCode = h.CardCode
        WHERE  l.LineType <> 'T'
          AND  l.ItemCode IS NOT NULL
          AND  (@full_mode = 1 OR h.DocDate >= @cutoff OR h.UpdateDate >= @cutoff)

        UNION ALL

        /* ---- RDN (Returns) — signe negatiu ---- */
        SELECT
            CAST(200000000 + l.DocEntry * 100 + l.LineNum AS int),
            LEFT(CAST(h.DocNum AS varchar(13)), 13),
            CAST(h.DocDate AS datetime),
            LEFT(COALESCE(cc.client_code, RTRIM(h.CardCode)) + '-' +
                 RIGHT('000' + CAST(COALESCE(ship.ship_no, 0) AS varchar(10)), 3), 13),
            LEFT(l.ItemCode, 16),
            CAST(ISNULL(l.PriceBefDi, 0) AS decimal(16,6)),
            CAST(ISNULL(l.StockPrice, 0) AS decimal(16,6)),
            CAST(ISNULL(l.StockPrice, 0) AS decimal(16,6)),
            CAST(
                -1 * l.Quantity * ISNULL(l.PriceBefDi, 0)
                       * (1 - ISNULL(l.DiscPrcnt, 0) / 100.0)
                       * (1 - CASE WHEN ISNULL(h.DiscPrcnt, 0) > 0 THEN h.DiscPrcnt / 100.0
                                   WHEN ISNULL(h.DiscSum, 0)   > 0
                                        AND (h.DocTotal - h.VatSum + h.DiscSum) > 0
                                        THEN h.DiscSum / (h.DocTotal - h.VatSum + h.DiscSum)
                                   ELSE 0 END)
                AS numeric(38, 6)),
            CAST(
                (1 - ISNULL(l.DiscPrcnt, 0) / 100.0) *
                (1 - CASE WHEN ISNULL(h.DiscPrcnt, 0) > 0 THEN h.DiscPrcnt / 100.0
                          WHEN ISNULL(h.DiscSum, 0)   > 0
                               AND (h.DocTotal - h.VatSum + h.DiscSum) > 0
                               THEN h.DiscSum / (h.DocTotal - h.VatSum + h.DiscSum)
                          ELSE 0 END)
                AS decimal(9, 6)),
            CAST(-1 * l.Quantity AS decimal(11, 3)),
            RIGHT('00' + CAST(ISNULL(h.Series, 0) AS varchar(10)), 2),
            CAST(ISNULL(h.Comments, '') AS varchar(max))
        FROM   sap_raw.ORDN h
        INNER JOIN sap_raw.RDN1 l ON l.DocEntry = h.DocEntry
        /* ship_no, no LineNum: la meitat dreta de id_client_location és el
           número seqüencial d'adreça que feia servir KAIS. Si el ShipToCode del
           document no lliga amb cap adreça, cau a 0, que és la primera del
           client (o la fila genèrica si no en té cap). */
        LEFT JOIN etl.vw_client_ship ship
               ON ship.CardCode  = h.CardCode
              AND ship.[Address] = h.ShipToCode
        /* LEFT, no INNER: un document d'un CardCode que no sigui al mirall
           (no és cCustomer, o encara no s'ha sincronitzat) ha de seguir sortint
           amb el codi de SAP, no desaparèixer en silenci. */
        LEFT JOIN etl.vw_client_code AS cc
               ON cc.CardCode = h.CardCode
        WHERE  l.LineType <> 'T'
          AND  l.ItemCode IS NOT NULL
          AND  (@full_mode = 1 OR h.DocDate >= @cutoff OR h.UpdateDate >= @cutoff)

        UNION ALL

        /* ---- RIN (Credit Memos) — signe negatiu ---- */
        SELECT
            CAST(300000000 + l.DocEntry * 100 + l.LineNum AS int),
            LEFT(CAST(h.DocNum AS varchar(13)), 13),
            CAST(h.DocDate AS datetime),
            LEFT(COALESCE(cc.client_code, RTRIM(h.CardCode)) + '-' +
                 RIGHT('000' + CAST(COALESCE(ship.ship_no, 0) AS varchar(10)), 3), 13),
            LEFT(l.ItemCode, 16),
            CAST(ISNULL(l.PriceBefDi, 0) AS decimal(16,6)),
            CAST(ISNULL(l.StockPrice, 0) AS decimal(16,6)),
            CAST(ISNULL(l.StockPrice, 0) AS decimal(16,6)),
            CAST(
                -1 * l.Quantity * ISNULL(l.PriceBefDi, 0)
                       * (1 - ISNULL(l.DiscPrcnt, 0) / 100.0)
                       * (1 - CASE WHEN ISNULL(h.DiscPrcnt, 0) > 0 THEN h.DiscPrcnt / 100.0
                                   WHEN ISNULL(h.DiscSum, 0)   > 0
                                        AND (h.DocTotal - h.VatSum + h.DiscSum) > 0
                                        THEN h.DiscSum / (h.DocTotal - h.VatSum + h.DiscSum)
                                   ELSE 0 END)
                AS numeric(38, 6)),
            CAST(
                (1 - ISNULL(l.DiscPrcnt, 0) / 100.0) *
                (1 - CASE WHEN ISNULL(h.DiscPrcnt, 0) > 0 THEN h.DiscPrcnt / 100.0
                          WHEN ISNULL(h.DiscSum, 0)   > 0
                               AND (h.DocTotal - h.VatSum + h.DiscSum) > 0
                               THEN h.DiscSum / (h.DocTotal - h.VatSum + h.DiscSum)
                          ELSE 0 END)
                AS decimal(9, 6)),
            CAST(-1 * l.Quantity AS decimal(11, 3)),
            RIGHT('00' + CAST(ISNULL(h.Series, 0) AS varchar(10)), 2),
            CAST(ISNULL(h.Comments, '') AS varchar(max))
        FROM   sap_raw.ORIN h
        INNER JOIN sap_raw.RIN1 l ON l.DocEntry = h.DocEntry
        /* ship_no, no LineNum: la meitat dreta de id_client_location és el
           número seqüencial d'adreça que feia servir KAIS. Si el ShipToCode del
           document no lliga amb cap adreça, cau a 0, que és la primera del
           client (o la fila genèrica si no en té cap). */
        LEFT JOIN etl.vw_client_ship ship
               ON ship.CardCode  = h.CardCode
              AND ship.[Address] = h.ShipToCode
        /* LEFT, no INNER: un document d'un CardCode que no sigui al mirall
           (no és cCustomer, o encara no s'ha sincronitzat) ha de seguir sortint
           amb el codi de SAP, no desaparèixer en silenci. */
        LEFT JOIN etl.vw_client_code AS cc
               ON cc.CardCode = h.CardCode
        WHERE  l.LineType <> 'T'
          AND  l.ItemCode IS NOT NULL
          AND  (@full_mode = 1 OR h.DocDate >= @cutoff OR h.UpdateDate >= @cutoff)
        OPTION (RECOMPILE);

        SET @rows_out = @@ROWCOUNT;

        /* Convenció del discount: un sol punt, amb la taula ja completa i tota
           en multiplicador. @rows_out ja està capturat, així que aquest UPDATE
           no el trepitja. */
        IF @discount_as_percent = 1
            UPDATE staging.est_linies_albara
            SET    discount = CAST(1 - discount AS decimal(9,6));

        /* rows_in = total línies al mirall (per audit) */
        SELECT @rows_in =
              (SELECT COUNT_BIG(*) FROM sap_raw.DLN1 WHERE LineType <> 'T' AND ItemCode IS NOT NULL)
            + (SELECT COUNT_BIG(*) FROM sap_raw.RDN1 WHERE LineType <> 'T' AND ItemCode IS NOT NULL)
            + (SELECT COUNT_BIG(*) FROM sap_raw.RIN1 WHERE LineType <> 'T' AND ItemCode IS NOT NULL);

        IF @RunId IS NOT NULL
            INSERT [audit].etl_step_log (run_id, step_name, started_at, finished_at, rows_in, rows_out, duration_ms, [status], error_message)
            VALUES (@RunId, 'sp_load_invoice_lines', @started, SYSUTCDATETIME(), @rows_in, @rows_out,
                    DATEDIFF(MILLISECOND, @started, SYSUTCDATETIME()), 'OK',
                    CASE WHEN @full_mode = 1
                              THEN 'mode=FULL'
                                   + CASE WHEN @discount_as_percent <> @discount_published
                                          THEN ' (forcat: canvi de convencio del discount)' ELSE '' END
                              ELSE 'mode=INCREMENTAL window_days=' + CAST(@window_days AS varchar(10)) END);
    END TRY
    BEGIN CATCH
        DECLARE @err nvarchar(max) = ERROR_MESSAGE();
        IF @RunId IS NOT NULL
            INSERT [audit].etl_step_log (run_id, step_name, started_at, finished_at, rows_in, rows_out, duration_ms, [status], error_message)
            VALUES (@RunId, 'sp_load_invoice_lines', @started, SYSUTCDATETIME(), @rows_in, @rows_out,
                    DATEDIFF(MILLISECOND, @started, SYSUTCDATETIME()), 'ERROR', @err);
        THROW;
    END CATCH
END
GO
