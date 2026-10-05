/* =========================================================================
   verify_ship_no.sql  -  el numero d'adreça que emetem es el de KAIS?

   LA REFERENCIA ES cfg.analitza_client_export, i nomes aquella.
   -------------------------------------------------------------
   Es el cens que Analitza fa servir de debo, carregat amb
   tools\Import-AnalitzaClientExport.ps1 des del CSV que ens passen.

   NO baseline.est_* : es sortida del pipeline ANTIC ja apuntat a SAP, o sigui
   que compara SAP amb SAP i dona un fals 100%. Ha enganyat tres vegades, i
   l'ultima va fer dir a Analitza que un problema estava resolt quan no ho
   estava (veure el capcal de etl.vw_client_ship_kais_no).

   NO dbo.est_* : es la nostra propia sortida d'ahir. Mateix mode de fallada.

   COM ES LLEGEIX
   --------------
   El denominador es FIX -les adreces de ship-to del mirall- perque l'abans i el
   despres siguin comparables. Si el denominador es mogues amb la numeracio, el
   percentatge no voldria dir res.

   Criteri (mesurat el 29/09/2026, companyia DB_FARIN_TEST, 5.618 adreces de
   ship-to amb codi postal a SAP):
       amb el ROW_NUMBER del 01/09   ->  4.923 zips quadren  (87,6%)
       amb el prefix NNN- de Address ->  5.574 zips quadren  (99,2%)

   El residu no son errors de numeracio: son adreces que a KAIS no tenien codi
   postal, zeros al davant (080057 contra 80057) i una adreça que a SAP ha
   canviat de ciutat. El report 3b ho separa.

   ⚠️ Si id_trobat puja pero zip_quadra no, la numeracio nova ha caigut damunt de
   files que existeixen PERO SON UNA ALTRA ADREÇA. Es el resultat alarmant, i un
   percentatge sol no el distingeix: per aixo les dues xifres van juntes.

   ⚠️ NO es compara `address`. El nostre es Street + StreetNo + Building tallat a
   35 i el d'Analitza ve de KAIS: no quadraran mai i no vol dir res. Qui el
   compari veura un desastre inexistent.
   ========================================================================= */
USE IntercanviSAP;
GO

IF OBJECT_ID('cfg.analitza_client_export') IS NULL
BEGIN
    RAISERROR('cfg.analitza_client_export no existeix. Carrega-la amb tools\Import-AnalitzaClientExport.ps1 abans de comparar res.', 16, 1);
    RETURN;
END
GO

/* ---------- 1) La taula congelada contra el cens, sense passar per l'ETL ----
   El gate mes barat: es pot mirar just despres de renumerar i abans de tocar
   staging. Si aqui no s'arriba al ~99,9%, no s'ha de continuar. --------------*/
WITH sap AS (
    SELECT  id = LEFT(cc.client_code + '-' + RIGHT('000' + CAST(f.ship_no AS varchar(10)), 3), 13),
            a.ZipCode,
            a.City
    FROM    cfg.client_ship_no AS f
    INNER JOIN sap_raw.CRD1 AS a
            ON a.CardCode = f.CardCode AND a.LineNum = f.LineNum AND a.AdresType = 'S'
    INNER JOIN etl.vw_client_code AS cc
            ON cc.CardCode = f.CardCode
)
SELECT  comprovacio = '1. cfg.client_ship_no contra el cens de KAIS',
        adreces_sap = COUNT(*),
        id_trobat   = SUM(CASE WHEN x.id_client_location IS NOT NULL THEN 1 ELSE 0 END),
        zip_quadra  = SUM(CASE WHEN x.id_client_location IS NOT NULL
                                AND LTRIM(RTRIM(ISNULL(x.zip_code, ''))) = LTRIM(RTRIM(ISNULL(s.ZipCode, '')))
                               THEN 1 ELSE 0 END),
        city_quadra = SUM(CASE WHEN x.id_client_location IS NOT NULL
                                AND LTRIM(RTRIM(ISNULL(x.city, ''))) = LTRIM(RTRIM(ISNULL(s.City, '')))
                               THEN 1 ELSE 0 END)
FROM    sap AS s
LEFT JOIN cfg.analitza_client_export AS x
       ON x.id_client_location = s.id;
GO

/* ---------- 2) El mateix sobre el que es publicara de debo ------------------
   Inclou vw_client_code, la fila generica -000 dels clients sense ship-to i el
   LEFT(...,13). Es fa contra staging despres d'un
   EXEC etl.sp_run_all @SkipSwap = 1, @ForceFullLines = 1. -------------------*/
SELECT  comprovacio = '2. staging.est_clients contra el cens de KAIS',
        files       = COUNT(*),
        id_trobat   = SUM(CASE WHEN x.id_client_location IS NOT NULL THEN 1 ELSE 0 END),
        zip_quadra  = SUM(CASE WHEN x.id_client_location IS NOT NULL
                                AND LTRIM(RTRIM(ISNULL(x.zip_code, ''))) = LTRIM(RTRIM(ISNULL(s.zip_code, '')))
                               THEN 1 ELSE 0 END)
FROM    staging.est_clients AS s
LEFT JOIN cfg.analitza_client_export AS x
       ON x.id_client_location = s.id_client_location;
GO

/* ---------- 3) Abans i despres, sobre la MATEIXA base --------------------
   La comparacio honesta: el mateix calcul amb la numeracio vella
   (cfg.client_ship_no_pre_prefix_fix, la copia que va fer la migracio) i amb la
   nova. Denominador identic, i nomes les adreces on les dues bandes tenen codi
   postal, que es l'unica comparacio que vol dir alguna cosa.

   Mesurat el 29/09/2026: 4.923 -> 5.574 de 5.618. ------------------------- */
WITH live AS (
    SELECT  f.CardCode, f.LineNum, f.ship_no AS nou,
            b.ship_no AS vell, a.ZipCode, cc.client_code
    FROM    cfg.client_ship_no AS f
    INNER JOIN cfg.client_ship_no_pre_prefix_fix AS b
            ON b.CardCode = f.CardCode AND b.LineNum = f.LineNum
    INNER JOIN sap_raw.CRD1 AS a
            ON a.CardCode = f.CardCode AND a.LineNum = f.LineNum AND a.AdresType = 'S'
    INNER JOIN etl.vw_client_code AS cc ON cc.CardCode = f.CardCode
), cmp AS (
    SELECT  l.ZipCode,
            zip_vell = xv.zip_code,
            zip_nou  = xn.zip_code
    FROM    live AS l
    LEFT JOIN cfg.analitza_client_export AS xv
           ON xv.id_client_location = LEFT(l.client_code + '-' + RIGHT('000' + CAST(l.vell AS varchar(10)), 3), 13)
    LEFT JOIN cfg.analitza_client_export AS xn
           ON xn.id_client_location = LEFT(l.client_code + '-' + RIGHT('000' + CAST(l.nou  AS varchar(10)), 3), 13)
    WHERE   NULLIF(LTRIM(RTRIM(l.ZipCode)), '') IS NOT NULL
)
SELECT  comprovacio = '3. Abans i despres, mateixa base',
        comparables = COUNT(*),
        zip_quadrava_abans = SUM(CASE WHEN LTRIM(RTRIM(ISNULL(zip_vell, ''))) = LTRIM(RTRIM(ZipCode)) THEN 1 ELSE 0 END),
        zip_quadra_ara     = SUM(CASE WHEN LTRIM(RTRIM(ISNULL(zip_nou,  ''))) = LTRIM(RTRIM(ZipCode)) THEN 1 ELSE 0 END)
FROM    cmp;
GO

/* ---------- 3b) Les 804 renumerades, una per una -------------------------- */
SELECT  comprovacio = '3b. Les renumerades: el zip de KAIS quadra amb el de SAP?',
        ch.reason,
        total          = COUNT(*),
        quadrava_abans = SUM(CASE WHEN LTRIM(RTRIM(ISNULL(xo.zip_code, ''))) = LTRIM(RTRIM(ISNULL(a.ZipCode, ''))) THEN 1 ELSE 0 END),
        quadra_ara     = SUM(CASE WHEN LTRIM(RTRIM(ISNULL(xn.zip_code, ''))) = LTRIM(RTRIM(ISNULL(a.ZipCode, ''))) THEN 1 ELSE 0 END)
FROM    [audit].client_ship_no_changes AS ch
INNER JOIN sap_raw.CRD1 AS a
        ON a.CardCode = ch.CardCode AND a.LineNum = ch.LineNum AND a.AdresType = 'S'
LEFT JOIN cfg.analitza_client_export AS xo ON xo.id_client_location = ch.id_old
LEFT JOIN cfg.analitza_client_export AS xn ON xn.id_client_location = ch.id_new
GROUP BY ch.reason;
GO

/* ---------- 4) Els tres casos documentats, a ma -----------------------------
   00000000-003 -> AV.VALENCIA,520 / ST. QUIRZE / 08192
   00251271-001 -> 08021
   00211116-000 -> VILAMALLA                                                 */
SELECT  comprovacio = '4. Casos documentats',
        s.id_client_location, s.[address], s.city, s.zip_code,
        kais_city = x.city, kais_zip = x.zip_code
FROM    staging.est_clients AS s
LEFT JOIN cfg.analitza_client_export AS x ON x.id_client_location = s.id_client_location
WHERE   s.id_client_location IN ('00000000-003', '00251271-001', '00211116-000')
ORDER BY s.id_client_location;
GO

/* ---------- 5) El mapatge per a Analitza ------------------------------------
   Es el que se li ha d'oferir: quan els deixa d'arribar un client_location
   l'esborren pero MANTENEN l'historic d'albarans, aixi que renumerar els deixa
   l'historic enganxat al numero antic. -------------------------------------*/
SELECT  comprovacio = '5. Mapatge id_antic -> id_nou (mostra)',
        ch.id_old, ch.id_new, ch.[Address], ch.reason
FROM    [audit].client_ship_no_changes AS ch
ORDER BY ch.id_old
OFFSET 0 ROWS FETCH NEXT 20 ROWS ONLY;
GO
