/* =========================================================================
   etl.sp_data_quality_checks   (format KAIS)
   Executa assertions sobre staging.* abans del swap.
   Registra warnings a audit.data_quality_warnings.
   @CriticalCount OUTPUT: si >0, l'orquestrador HA D'aturar el swap.

   Adaptats al format KAIS:
     - Fórmula net_amount = price × qty × discount  (discount és multiplicador)
     - country_code varchar(4) minúscules
     - No hi ha camp [transaction]
     - invoices_id sense prefix (només DocNum a varchar(13))
   ========================================================================= */
USE IntercanviSAP;
GO

IF OBJECT_ID('etl.sp_data_quality_checks') IS NOT NULL
    DROP PROCEDURE etl.sp_data_quality_checks;
GO

CREATE PROCEDURE etl.sp_data_quality_checks
    @RunId          bigint = NULL,
    @CriticalCount  int OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @started datetime2(3) = SYSUTCDATETIME();
    SET @CriticalCount = 0;

    DECLARE @rid bigint = ISNULL(@RunId, 0);
    DECLARE @cnt int;

    BEGIN TRY
        /* ----- 1) Línies amb client orfe (CRITICAL) ----- */
        SELECT @cnt = COUNT(*)
        FROM   staging.est_linies_albara l
        WHERE  NOT EXISTS (SELECT 1 FROM staging.est_clients c
                           WHERE c.id_client_location = l.client_locations_id);
        IF @cnt > 0
        BEGIN
            INSERT [audit].data_quality_warnings (run_id, check_name, severity, details)
            VALUES (@rid, 'lines_orphan_client', 'CRITICAL',
                    'Linies amb client_locations_id sense match a est_clients: ' + CAST(@cnt AS varchar(20)));
            SET @CriticalCount = @CriticalCount + 1;
        END

        /* ----- 2) Línies amb producte orfe (CRITICAL) ----- */
        SELECT @cnt = COUNT(*)
        FROM   staging.est_linies_albara l
        WHERE  NOT EXISTS (SELECT 1 FROM staging.est_productes p
                           WHERE p.id_product = l.products_id);
        IF @cnt > 0
        BEGIN
            INSERT [audit].data_quality_warnings (run_id, check_name, severity, details)
            VALUES (@rid, 'lines_orphan_product', 'CRITICAL',
                    'Linies amb products_id sense match a est_productes: ' + CAST(@cnt AS varchar(20)));
            SET @CriticalCount = @CriticalCount + 1;
        END

        /* ----- 3) Clients amb agent orfe (WARN) ----- */
        SELECT @cnt = COUNT(*)
        FROM   staging.est_clients c
        WHERE  NOT EXISTS (SELECT 1 FROM staging.est_agents a
                           WHERE a.id_salesman = c.salesmen_id);
        IF @cnt > 0
            INSERT [audit].data_quality_warnings (run_id, check_name, severity, details)
            VALUES (@rid, 'clients_orphan_salesman', 'WARN',
                    'Clients amb salesmen_id sense agent: ' + CAST(@cnt AS varchar(20)));

        /* ----- 4) country_code mal format (CRITICAL) ----- */
        /* El COLLATE explicit no es decoratiu: la BD es CI_AS, aixi que sense
           ell `country_code <> LOWER(country_code)` es sempre fals i la meitat
           d'aquest check no pot detectar res. Comprovat el 26/08/2026. */
        SELECT @cnt = COUNT(*) FROM staging.est_clients
        WHERE  country_code IS NULL
            OR LEN(country_code) NOT BETWEEN 2 AND 4
            OR country_code COLLATE Latin1_General_CS_AS
               <> LOWER(country_code) COLLATE Latin1_General_CS_AS;
        IF @cnt > 0
        BEGIN
            INSERT [audit].data_quality_warnings (run_id, check_name, severity, details)
            VALUES (@rid, 'country_code_format', 'CRITICAL',
                    'Clients amb country_code no minuscula o mida <2 o >4: ' + CAST(@cnt AS varchar(20)));
            SET @CriticalCount = @CriticalCount + 1;
        END

        /* ----- 5) Signe quantity vs net_amount (CRITICAL) ----- */
        SELECT @cnt = COUNT(*) FROM staging.est_linies_albara
        WHERE  (quantity > 0 AND net_amount < 0)
            OR (quantity < 0 AND net_amount > 0);
        IF @cnt > 0
        BEGIN
            INSERT [audit].data_quality_warnings (run_id, check_name, severity, details)
            VALUES (@rid, 'sign_mismatch', 'CRITICAL',
                    'Linies amb signe quantity != signe net_amount: ' + CAST(@cnt AS varchar(20)));
            SET @CriticalCount = @CriticalCount + 1;
        END

        /* ----- 6) Fórmula del net_amount (WARN) -----

           La fórmula depèn de la convenció del camp discount, que la mana
           cfg.settings.DISCOUNT_AS_PERCENT i que canvia el dia del cutover:

               '0' (avui)  discount és multiplicador  -> net = price * qty * discount
               '1'         discount és percentatge    -> net = price * qty * (1 - discount)

           Aquest check i sp_load_invoice_lines han de llegir el MATEIX setting.
           Si només es canviés l'emissió, aquest check saltaria a cada línia la
           nit del tall i el soroll taparia el que sí que importés. */
        DECLARE @discount_as_percent bit = 0;
        SELECT @discount_as_percent = ISNULL(TRY_CAST([value] AS bit), 0)
        FROM   cfg.settings WHERE [key] = 'DISCOUNT_AS_PERCENT';

        SELECT @cnt = COUNT(*) FROM staging.est_linies_albara
        WHERE  ABS(ISNULL(net_amount, 0)
                   - ISNULL(product_price, 0) * ISNULL(quantity, 0)
                     * CASE WHEN @discount_as_percent = 1 THEN 1 - ISNULL(discount, 0)
                            ELSE ISNULL(discount, 1) END) > 0.01;
        IF @cnt > 0
            INSERT [audit].data_quality_warnings (run_id, check_name, severity, details)
            VALUES (@rid, 'formula_break', 'WARN',
                    'Linies on net_amount != price*qty*'
                    + CASE WHEN @discount_as_percent = 1 THEN '(1-discount)' ELSE 'discount' END
                    + ' per > 1c: ' + CAST(@cnt AS varchar(20)));

        /* ----- 7) Pic anòmal en compte de línies del dia (WARN) ----- */
        DECLARE @today_count int, @avg_count float;
        DECLARE @yday date = DATEADD(DAY, -1, CAST(SYSUTCDATETIME() AS date));
        SELECT @today_count = COUNT(*) FROM staging.est_linies_albara WHERE CAST([date] AS date) = @yday;
        SELECT @avg_count = AVG(CAST(c AS float))
        FROM (
            SELECT CAST([date] AS date) AS d, COUNT(*) AS c
            FROM   staging.est_linies_albara
            WHERE  CAST([date] AS date) BETWEEN DATEADD(DAY,-28,@yday) AND DATEADD(DAY,-1,@yday)
              AND  DATENAME(WEEKDAY, CAST([date] AS date)) = DATENAME(WEEKDAY, @yday)
            GROUP BY CAST([date] AS date)
        ) x;
        IF @avg_count > 0 AND
           (@today_count < @avg_count * 0.5 OR @today_count > @avg_count * 1.5)
            INSERT [audit].data_quality_warnings (run_id, check_name, severity, details)
            VALUES (@rid, 'volume_anomaly', 'WARN',
                    'Recompte linies dia ' + CONVERT(varchar(10),@yday,23)
                    + ' (' + CAST(@today_count AS varchar(20)) + ') fora del +/-50% de la mitjana 4w del mateix dia setmana ('
                    + CAST(@avg_count AS varchar(20)) + ').');

        /* ----- 8) Identificadors que desapareixen d'un dia per l'altre -----

           Els identificadors que enviem a Analitza son un contracte: si un
           id_client_location que ahir hi era avui no hi es, Analitza no veu un
           error sino un client que ha deixat de comprar, i el dona per perdut.
           El mateix amb productes, families i comercials.

           dbo.* te la foto d'ahir i staging.* la d'avui, aixi que la comprovacio
           es un EXCEPT. Cobreix una familia sencera de fallades silencioses: un
           camp que es queda buit a l'origen, un filtre que descarta de mes, un
           mapatge que canvia sense avisar. Cap dels altres checks la detecta,
           perque totes deixen les taules coherents amb elles mateixes.

           Es queda en WARN mentre siguin poques i passa a CRITICAL a partir del
           llindar cfg.settings.ID_DROP_MAX. El llindar existeix perque hi ha
           desaparicions legitimes (un client esborrat a SAP), i perque el dia
           del cutover pot caldre apujar-lo expressament. -----*/
        DECLARE @drop_max int;
        SELECT @drop_max = TRY_CAST([value] AS int) FROM cfg.settings WHERE [key] = 'ID_DROP_MAX';
        SET @drop_max = ISNULL(@drop_max, 10);

        IF OBJECT_ID('tempdb..#vanished') IS NOT NULL DROP TABLE #vanished;
        CREATE TABLE #vanished (
            entity varchar(30)  COLLATE DATABASE_DEFAULT NOT NULL,
            id     nvarchar(260) COLLATE DATABASE_DEFAULT NOT NULL
        );

        INSERT #vanished (entity, id)
        SELECT 'est_clients', id_client_location FROM dbo.est_clients
        EXCEPT
        SELECT 'est_clients', id_client_location FROM staging.est_clients;

        INSERT #vanished (entity, id)
        SELECT 'est_productes', id_product FROM dbo.est_productes
        EXCEPT
        SELECT 'est_productes', id_product FROM staging.est_productes;

        INSERT #vanished (entity, id)
        SELECT 'est_agents', id_salesman FROM dbo.est_agents
        EXCEPT
        SELECT 'est_agents', id_salesman FROM staging.est_agents;

        INSERT #vanished (entity, id)
        SELECT 'est_families_productes', id_product_category FROM dbo.est_families_productes
        EXCEPT
        SELECT 'est_families_productes', id_product_category FROM staging.est_families_productes;

        SELECT @cnt = COUNT(*) FROM #vanished;

        IF @cnt > 0
        BEGIN
            DECLARE @vanished_detail nvarchar(max);

            /* Resum per entitat, i uns quants exemples: sense els identificadors
               concrets, el warning obliga a reconstruir la consulta a ma. */
            SELECT @vanished_detail = STRING_AGG(x.txt, '; ') WITHIN GROUP (ORDER BY x.entity)
            FROM (
                SELECT entity, entity + '=' + CAST(COUNT(*) AS varchar(20)) AS txt
                FROM   #vanished GROUP BY entity
            ) x;

            SELECT @vanished_detail = @vanished_detail + '. Exemples: '
                 + STRING_AGG(CAST(y.id AS nvarchar(260)), ', ')
            FROM (SELECT TOP 10 id FROM #vanished ORDER BY entity, id) y;

            IF @cnt > @drop_max
            BEGIN
                INSERT [audit].data_quality_warnings (run_id, check_name, severity, details)
                VALUES (@rid, 'vanished_ids', 'CRITICAL',
                        'Han desaparegut ' + CAST(@cnt AS varchar(20)) + ' identificadors respecte d ahir (llindar '
                        + CAST(@drop_max AS varchar(20)) + '): ' + @vanished_detail);
                SET @CriticalCount = @CriticalCount + 1;
            END
            ELSE
                INSERT [audit].data_quality_warnings (run_id, check_name, severity, details)
                VALUES (@rid, 'vanished_ids', 'WARN',
                        'Han desaparegut ' + CAST(@cnt AS varchar(20)) + ' identificadors respecte d ahir: ' + @vanished_detail);
        END

        /* ----- 9) Terra minim de files a les taules de moviment -----

           El 25/08/2026 sp_load_invoice_lines va carregar 0 linies tenint-ne 57
           al mirall, i els vuit checks anteriors van donar 0 critics: amb la
           taula buida no hi ha orfes, la formula no es pot trencar, els signes
           quadren, i el check de volum calcula la mitjana sobre la MATEIXA
           taula buida, treu NULL i se salta tot sol. El swap hauria publicat la
           taula buida i Analitza s'hauria quedat sense albarans.

           El check 8 (vanished_ids) no ho cobreix: mira clients, productes,
           families i comercials, que son mestres, no moviments.

           Les linies d'albara son historic acumulat: el recompte no ha de
           baixar mai de manera significativa. Els cobraments si que fluctuen
           (una factura es cobra i desapareix), aixi que d'aquells nomes es
           vigila que no quedin a zero de cop.

           dbo.* te la foto d'ahir. Si esta buida, es la primera carrega i no hi
           ha res a comparar. -----*/
        DECLARE @min_ratio decimal(5,3);
        SELECT @min_ratio = TRY_CAST([value] AS decimal(5,3)) FROM cfg.settings WHERE [key] = 'LINES_MIN_RATIO';
        SET @min_ratio = ISNULL(@min_ratio, 0.95);

        DECLARE @lines_before bigint, @lines_now bigint, @recv_before bigint, @recv_now bigint;
        SELECT @lines_before = COUNT_BIG(*) FROM dbo.est_linies_albara;
        SELECT @lines_now    = COUNT_BIG(*) FROM staging.est_linies_albara;
        SELECT @recv_before  = COUNT_BIG(*) FROM dbo.est_cobraments;
        SELECT @recv_now     = COUNT_BIG(*) FROM staging.est_cobraments;

        IF @lines_before > 0 AND @lines_now = 0
        BEGIN
            INSERT [audit].data_quality_warnings (run_id, check_name, severity, details)
            VALUES (@rid, 'lines_empty', 'CRITICAL',
                    'staging.est_linies_albara ha quedat BUIDA i ahir tenia '
                    + CAST(@lines_before AS varchar(20)) + ' files. Swap avortat.');
            SET @CriticalCount = @CriticalCount + 1;
        END
        ELSE IF @lines_before > 0 AND @lines_now < CAST(@lines_before * @min_ratio AS bigint)
        BEGIN
            INSERT [audit].data_quality_warnings (run_id, check_name, severity, details)
            VALUES (@rid, 'lines_collapsed', 'CRITICAL',
                    'staging.est_linies_albara ha passat de ' + CAST(@lines_before AS varchar(20))
                    + ' a ' + CAST(@lines_now AS varchar(20)) + ' files, per sota del '
                    + CAST(CAST(@min_ratio * 100 AS int) AS varchar(10)) + '% d ahir. '
                    + 'Les linies son historic acumulat i no haurien de minvar. Swap avortat.');
            SET @CriticalCount = @CriticalCount + 1;
        END

        IF @recv_before > 0 AND @recv_now = 0
        BEGIN
            INSERT [audit].data_quality_warnings (run_id, check_name, severity, details)
            VALUES (@rid, 'receivables_empty', 'CRITICAL',
                    'staging.est_cobraments ha quedat BUIDA i ahir tenia '
                    + CAST(@recv_before AS varchar(20)) + ' files. Swap avortat.');
            SET @CriticalCount = @CriticalCount + 1;
        END

        /* ----- 10) La data mes antiga no pot retrocedir -----

           Aixo no protegeix les NOSTRES dades, protegeix les d'Analitza, i cal
           saber com carreguen per entendre'l.

           La seva SQL (docs/sql importacio Farinera.sql) filtra
               DATEDIFF(DAY, date, GETDATE()) <= 90
           i despres, segons el correu de l'Adria de l'01/09/2026, la seva
           carrega **reemplaça** el seu historic a partir de la data MINIMA de
           tot el que els arriba. O sigui que la data mes antiga que publiquem
           es, literalment, el punt a partir del qual ells esborren.

           Mentre no es mogui cap enrere, no passa res: cada nit reemplacen el
           mateix tram i el tornen a omplir. El dany es exactament que
           RETROCEDEIXI. Si un dia publiquem una linia datada abans del que
           publicavem ahir, ells esborren des d'aquella data i hi posen a sobre
           nomes el que els hem enviat: el que tinguessin entremig i no els
           tornem a enviar, el perden.

           Dues maneres que passi, i cap es rebuscada:
             - la SAP productiva arrenca amb albarans anteriors al tall;
             - algu posta un albara amb data endarrerida despres del tall, que
               es operativa normal d'un ERP. El mode incremental el recull per
               UpdateDate i el publica amb el seu DocDate, que es antic.

           Es CRITICAL i atura el swap. Cap dels altres nou checks mira dates:
           una linia antiga no es orfe, no trenca la formula, no canvia el signe
           i no fa minvar el recompte.

           Per que no hi ha cap data configurada: no cal. La referencia es el que
           vam publicar ahir (dbo), com a vanished_ids. Aixi no depen que ningu
           reculli un pas del runbook el dia del tall, i el mateix dia del tall
           la data minima salta cap ENDAVANT -de l'historic de KAIS al 2 de
           novembre-, que es un moviment permes.

           HISTORY_FLOOR_ENFORCE existeix per a l'unic cas legitim: un backfill
           volgut d'historic mes antic. Es posa a '0', es fa, i es torna a '1'. -----*/
        DECLARE @enforce_floor bit = 1;
        SELECT @enforce_floor = ISNULL(TRY_CAST([value] AS bit), 1)
        FROM   cfg.settings WHERE [key] = 'HISTORY_FLOOR_ENFORCE';

        DECLARE @min_before datetime, @min_now datetime;
        SELECT @min_before = MIN([date]) FROM dbo.est_linies_albara;
        SELECT @min_now    = MIN([date]) FROM staging.est_linies_albara;

        IF @enforce_floor = 1 AND @min_before IS NOT NULL AND @min_now IS NOT NULL
           AND @min_now < @min_before
        BEGIN
            DECLARE @floor_detail nvarchar(max) =
                'La data mes antiga ha passat de ' + CONVERT(varchar(10), @min_before, 23)
                + ' a ' + CONVERT(varchar(10), @min_now, 23)
                + '. Analitza reemplaça el seu historic a partir de la data minima que li enviem, '
                + 'aixi que publicar aixo els esborraria el que tinguin entre les dues dates. Swap avortat. '
                + 'Linies afectades: ';
            SELECT TOP 10 @floor_detail = @floor_detail
                   + CAST(id_invoice_line AS varchar(20)) + '=' + CONVERT(varchar(10), [date], 23) + ' '
            FROM   staging.est_linies_albara
            WHERE  [date] < @min_before
            ORDER BY [date];

            INSERT [audit].data_quality_warnings (run_id, check_name, severity, details)
            VALUES (@rid, 'history_floor', 'CRITICAL', @floor_detail);
            SET @CriticalCount = @CriticalCount + 1;
        END

        /* ----- 11) Adreces de ship-to sense numero congelat (CRITICAL) -----

           etl.vw_client_ship fa INNER JOIN amb cfg.client_ship_no, aixi que una
           adreça sense numero no surt de la vista i el seu client_location no
           arriba a Analitza. Que desaparegui es preferible a inventar-li un
           numero, pero s'ha de veure: normalment vol dir que
           sp_assign_client_ship_no no ha corregut. -----*/
        SELECT @cnt = COUNT(*)
        FROM   sap_raw.CRD1 AS a
        WHERE  a.AdresType = 'S'
          AND  NOT EXISTS (SELECT 1 FROM cfg.client_ship_no AS f
                           WHERE f.CardCode = a.CardCode AND f.LineNum = a.LineNum);
        IF @cnt > 0
        BEGIN
            INSERT [audit].data_quality_warnings (run_id, check_name, severity, details)
            VALUES (@rid, 'ship_no_missing', 'CRITICAL',
                    'Adreces de ship-to a sap_raw.CRD1 sense numero a cfg.client_ship_no: '
                    + CAST(@cnt AS varchar(20))
                    + '. No surten de etl.vw_client_ship i els seus client_locations no arribarien a '
                    + 'Analitza. Ha corregut etl.sp_assign_client_ship_no? Swap avortat.');
            SET @CriticalCount = @CriticalCount + 1;
        END

        /* ----- 12) El nom de l'adreça ha canviat sota un numero congelat (WARN) -----

           El numero es congela per (CardCode, LineNum). Si SAP reutilitzes un
           LineNum per a una adreça DIFERENT, l'historic de la vella cauria sobre
           la nova, que es exactament el que aquesta taula evita. No es pot
           distingir d'un canvi de nom legitim -corregir una falta-, aixi que
           avisa i no bloqueja: qui ho miri ho sabra. -----*/
        SELECT @cnt = COUNT(*)
        FROM   cfg.client_ship_no AS f
        INNER JOIN sap_raw.CRD1 AS a
               ON a.CardCode = f.CardCode AND a.LineNum = f.LineNum AND a.AdresType = 'S'
        WHERE  ISNULL(f.[Address], '') <> ISNULL(a.[Address], '');
        IF @cnt > 0
        BEGIN
            DECLARE @addr_detail nvarchar(max) =
                'Adreces on el nom ha canviat sense canviar de numero: ' + CAST(@cnt AS varchar(20))
                + '. Si es un canvi de nom, correcte; si SAP ha reutilitzat el LineNum per a una '
                + 'adreça diferent, l historic d albarans cauria sobre la nova. ';
            SELECT TOP 10 @addr_detail = @addr_detail
                   + f.CardCode + '/' + CAST(f.ship_no AS varchar(10)) + ': '''
                   + ISNULL(f.[Address], '') + ''' -> ''' + ISNULL(a.[Address], '') + ''' '
            FROM   cfg.client_ship_no AS f
            INNER JOIN sap_raw.CRD1 AS a
                   ON a.CardCode = f.CardCode AND a.LineNum = f.LineNum AND a.AdresType = 'S'
            WHERE  ISNULL(f.[Address], '') <> ISNULL(a.[Address], '')
            ORDER BY f.CardCode, f.ship_no;

            INSERT [audit].data_quality_warnings (run_id, check_name, severity, details)
            VALUES (@rid, 'ship_address_changed', 'WARN', @addr_detail);
        END

        /* ----- 13) Enllaç de successor que no apunta a ningu (WARN) -----

           U_SEICodienllac guarda el codi del client que aquest ve a substituir,
           i etl.vw_client_successor inverteix la relacio per emetre el new_code.
           Un valor que no resol a cap client no dona un error: dona un new_code
           NULL, i llavors Analitza compta el canvi de rao social com un client
           perdut mes un de guanyat, que es precisament el que el camp evita.

           A test resolen 160 de 160. Qualsevol xifra diferent de zero vol dir
           que algu ha escrit a ma un codi que no existeix, o que la
           normalitzacio del capçal de la vista s'ha quedat curta. -----*/
        SELECT @cnt = COUNT(*)
        FROM   sap_raw.OCRD AS s
        WHERE  NULLIF(LTRIM(RTRIM(s.U_SEICodienllac)), '') IS NOT NULL
          AND  NOT EXISTS (SELECT 1
                           FROM   sap_raw.OCRD AS p
                           INNER JOIN etl.vw_client_code AS pcc ON pcc.CardCode = p.CardCode
                           WHERE  p.CardCode <> s.CardCode
                             AND  (CASE WHEN LEN(LTRIM(RTRIM(s.U_SEICodienllac))) <= 8
                                        THEN RIGHT('00000000' + LTRIM(RTRIM(s.U_SEICodienllac)), 8)
                                        ELSE LTRIM(RTRIM(s.U_SEICodienllac)) END = pcc.client_code
                                   OR 'C' + LTRIM(RTRIM(s.U_SEICodienllac)) = RTRIM(p.CardCode)));
        IF @cnt > 0
        BEGIN
            DECLARE @succ_detail nvarchar(max) =
                'Clients amb U_SEICodienllac que no apunta a cap client de SAP: ' + CAST(@cnt AS varchar(20))
                + '. Cadascun deixa el seu predecessor sense new_code i Analitza el comptara com un client nou. ';
            SELECT TOP 10 @succ_detail = @succ_detail
                   + RTRIM(s.CardCode) + ' -> ''' + LTRIM(RTRIM(s.U_SEICodienllac)) + ''' '
            FROM   sap_raw.OCRD AS s
            WHERE  NULLIF(LTRIM(RTRIM(s.U_SEICodienllac)), '') IS NOT NULL
              AND  NOT EXISTS (SELECT 1
                               FROM   sap_raw.OCRD AS p
                               INNER JOIN etl.vw_client_code AS pcc ON pcc.CardCode = p.CardCode
                               WHERE  p.CardCode <> s.CardCode
                                 AND  (CASE WHEN LEN(LTRIM(RTRIM(s.U_SEICodienllac))) <= 8
                                            THEN RIGHT('00000000' + LTRIM(RTRIM(s.U_SEICodienllac)), 8)
                                            ELSE LTRIM(RTRIM(s.U_SEICodienllac)) END = pcc.client_code
                                       OR 'C' + LTRIM(RTRIM(s.U_SEICodienllac)) = RTRIM(p.CardCode)))
            ORDER BY s.CardCode;

            INSERT [audit].data_quality_warnings (run_id, check_name, severity, details)
            VALUES (@rid, 'new_code_unresolved', 'WARN', @succ_detail);
        END

        /* ----- 14) Un predecessor amb mes d'un successor (WARN) -----

           etl.vw_client_successor en tria un de sol amb TOP 1, perque si no
           multiplicaria files a staging.est_clients i hi hauria
           id_client_location duplicats. Pero el que descarta no es soroll: son
           dos clients que diuen substituir el mateix. Qui ho miri ha de decidir
           quin val; mentrestant s'emet el viu, i entre dos de vius el CardCode
           mes alt. A test n'hi ha 1 (C211608 <- C211534, C301563). -----*/
        SELECT @cnt = COUNT(*) FROM (
            SELECT pcc.client_code
            FROM   sap_raw.OCRD AS s
            INNER JOIN sap_raw.OCRD AS p ON p.CardCode <> s.CardCode
            INNER JOIN etl.vw_client_code AS pcc ON pcc.CardCode = p.CardCode
            WHERE  NULLIF(LTRIM(RTRIM(s.U_SEICodienllac)), '') IS NOT NULL
              AND  (CASE WHEN LEN(LTRIM(RTRIM(s.U_SEICodienllac))) <= 8
                         THEN RIGHT('00000000' + LTRIM(RTRIM(s.U_SEICodienllac)), 8)
                         ELSE LTRIM(RTRIM(s.U_SEICodienllac)) END = pcc.client_code
                    OR 'C' + LTRIM(RTRIM(s.U_SEICodienllac)) = RTRIM(p.CardCode))
            GROUP BY pcc.client_code
            HAVING COUNT(DISTINCT s.CardCode) > 1
        ) AS dups;
        IF @cnt > 0
        BEGIN
            INSERT [audit].data_quality_warnings (run_id, check_name, severity, details)
            VALUES (@rid, 'new_code_ambiguous', 'WARN',
                    'Clients apuntats com a predecessor per mes d un successor: ' + CAST(@cnt AS varchar(20))
                    + '. La vista n emet un de sol; la resta no arriben a Analitza.');
        END

        IF @RunId IS NOT NULL
            INSERT [audit].etl_step_log (run_id, step_name, started_at, finished_at, duration_ms, [status], error_message)
            VALUES (@RunId, 'sp_data_quality_checks', @started, SYSUTCDATETIME(),
                    DATEDIFF(MILLISECOND, @started, SYSUTCDATETIME()), 'OK',
                    'critical=' + CAST(@CriticalCount AS varchar(10)));
    END TRY
    BEGIN CATCH
        DECLARE @err nvarchar(max) = ERROR_MESSAGE();
        IF @RunId IS NOT NULL
            INSERT [audit].etl_step_log (run_id, step_name, started_at, finished_at, duration_ms, [status], error_message)
            VALUES (@RunId, 'sp_data_quality_checks', @started, SYSUTCDATETIME(),
                    DATEDIFF(MILLISECOND, @started, SYSUTCDATETIME()), 'ERROR', @err);
        THROW;
    END CATCH
END
GO
