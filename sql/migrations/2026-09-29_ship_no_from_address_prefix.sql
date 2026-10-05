/* =========================================================================
   2026-09-29_ship_no_from_address_prefix
   Objecte : cfg.client_ship_no  (la taula que congela el numero d'adreça)

   QUE FA
   ------
   Reassigna el ship_no de cada adreça de ship-to al numero que KAIS li havia
   donat, que viu al PREFIX del nom de l'adreça de SAP:

       CRD1.Address = '003-SANT QUIRZE-ST. QUIRZE'   ->   ship_no = 3

   PER QUE
   -------
   L'01/09/2026 el numero es va congelar amb
       ROW_NUMBER() OVER (PARTITION BY CardCode ORDER BY LineNum)
   perque KAIS numerava seqüencialment des de 000 i el LineNum de SAP no. La
   hipotesi era raonable i encaixava en un 88%, pero no era el numero de KAIS:
   per a un client amb diverses adreces, el ROW_NUMBER les PERMUTA.

       C251271 / LineNum 4   '000-CREATIVE FOODING SL-BARCELONA'   ship_no 0  OK
       C251271 / LineNum 12  '002-CREATIVE FOODING SL-BARCELONA'   ship_no 1  MAL
       C251271 / LineNum 14  '001-CREATIVE FOODING SL-BARCELONA'   ship_no 2  MAL

   Mesurat contra docs\client_locations.csv -l'exportacio que Analitza fa servir
   de debo-, sobre 5.572 adreces de ship-to amb codi postal:

       renumerant 0,1,2...        -> 4.923 zips quadren  (87,6%)
       el prefix NNN- de Address  -> 5.574 zips quadren  (99,2%)

   i, mirant nomes les 804 adreces que van canviar de numero, el zip de KAIS
   quadrava amb el de SAP en 132 i despres en 786. El residu no son errors de
   numeracio: son adreces que a KAIS no tenien codi postal, zeros al davant
   (080057 contra 80057) i una adreça que a SAP ha canviat de ciutat. La
   consulta que ho torna a mesurar es sql\verify_ship_no.sql.

   Per que no es va veure l'01/09: es va validar contra baseline.est_clients,
   que es sortida del pipeline ANTIC ja apuntat a SAP. Comparava SAP amb SAP.
   Ho va destapar la comparativa que l'Adria va enviar el 25/09/2026.

   LA REGLA, I L'EXCEPCIO
   ----------------------
   Cada adreça pren el seu prefix. Si un client te DUES adreces amb el MATEIX
   prefix (la mateixa adreça introduida dues vegades a SAP), aquell client es
   queda ENTER tal com estava: no s'inventa cap desempat. Un numero que no es
   pot justificar contra KAIS es pitjor que no canviar res.

   Amb aixo, a 29/09/2026: 0 col.lisions, 804 files canvien, i nomes 8
   id_client_location desapareixen -la resta son permutacions dins del mateix
   conjunt de numeros d'un client, i una permutacio no fa desapareixer cap
   identificador-. Per aixo NO cal apujar cfg.settings.ID_DROP_MAX: vanished_ids
   ho veura com un WARN de 8 sobre un llindar de 10.

   AIXO NO ES CRIDA DES DE deploy.sql, I ES A PROPOSIT
   ---------------------------------------------------
   schema\04_migracions.sql s'executa a cada desplegament. Si la renumeracio
   fos alla, un deploy rutinari podria reassignar ~800 identificadors sense que
   ningu hagues posat @ForceFullLines=1. S'executa a ma, un sol cop, mirant la
   sortida, i amb un permis explicit a cfg.settings.

   ORDRE OBLIGATORI DESPRES D'EXECUTAR-HO
   --------------------------------------
       EXEC etl.sp_run_all @SkipSwap = 1, @ForceFullLines = 1;   -- inspeccio
       EXEC etl.sp_run_all @ForceFullLines = 1;                  -- publica

   @ForceFullLines=1 NO es opcional: en mode INCREMENTAL sp_load_invoice_lines
   copia de dbo les linies dels documents que no es refresquen, amb el
   client_locations_id d'ahir, i est_linies_albara quedaria amb dues
   convencions barrejades. Va passar el 17/09/2026 i el va caçar
   lines_orphan_client. A diferencia del discount, aqui el codi NO ho detecta
   sol: no hi ha cap SHIP_NO_PUBLISHED.

   ROLLBACK
   --------
   Hi ha copia a cfg.client_ship_no_pre_prefix_fix i el procediment es al final
   d'aquest fitxer. Pero nomes val MENTRE NO S'HAGI PUBLICAT a dbo: un cop
   Analitza ha ingerit els identificadors nous, desfer-ho es un segon canvi
   massiu, no una marxa enrere. El rollback real es no publicar, i per aixo el
   pas d'inspeccio va amb @SkipSwap=1.

   IDEMPOTENT: la primera guarda es cfg.migrations_applied. Tornar a executar el
   fitxer no fa res.
   ========================================================================= */
USE IntercanviSAP;
GO

/* TOT EN UN SOL BATCH a proposit: els RETURN de les guardes han d'aturar el
   fitxer sencer. Amb un GO entremig, el batch seguent s'executaria igualment. */
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @mig varchar(120) = '2026-09-29_ship_no_from_address_prefix';
DECLARE @now datetime2(3) = SYSUTCDATETIME();

/* ---------- GUARDA 1: ja aplicada ---------------------------------------- */
IF EXISTS (SELECT 1 FROM cfg.migrations_applied WHERE migration_name = @mig)
BEGIN
    SELECT resultat = 'JA APLICADA - res a fer',
           m.migration_name, m.applied_at, m.applied_by, m.rows_affected
    FROM   cfg.migrations_applied AS m
    WHERE  m.migration_name = @mig;
    RETURN;
END

/* ---------- GUARDA 2: permis d'un sol us --------------------------------- */
IF ISNULL((SELECT [value] FROM cfg.settings WHERE [key] = 'ALLOW_SHIP_NO_RENUMBER'), '0') <> '1'
BEGIN
    RAISERROR('cfg.settings.ALLOW_SHIP_NO_RENUMBER no val 1. cfg.client_ship_no es estat NO regenerable: llegeix el capcal d aquest fitxer abans de posar-lo.', 16, 1);
    RETURN;
END

/* ---------- GUARDA 3: el mirall ha de ser fresc -------------------------- */
DECLARE @mirror_age_h int =
        (SELECT DATEDIFF(HOUR, MIN(updated_at), SYSUTCDATETIME()) FROM sap_raw.sync_state);
DECLARE @mirror_max_h int =
        TRY_CAST(ISNULL((SELECT [value] FROM cfg.settings WHERE [key] = 'MIRROR_MAX_AGE_HOURS'), '6') AS int);

IF @mirror_age_h IS NULL OR @mirror_age_h > ISNULL(@mirror_max_h, 6)
BEGIN
    RAISERROR('El mirall sap_raw te %d hores (limit %d). Els prefixos es llegeixen de sap_raw.CRD1: executa el Worker primer.', 16, 1, @mirror_age_h, @mirror_max_h);
    RETURN;
END

/* ---------- GUARDA 4: l'espai negatiu ha d'estar lliure ------------------ */
IF EXISTS (SELECT 1 FROM cfg.client_ship_no WHERE ship_no < 0)
BEGIN
    RAISERROR('Hi ha ship_no negatius a cfg.client_ship_no. La permutacio fa servir l espai negatiu: atura-ho i mira-ho.', 16, 1);
    RETURN;
END

/* ---------- GUARDA 5: copia de seguretat dins de la BD ------------------- */
IF OBJECT_ID('cfg.client_ship_no_pre_prefix_fix') IS NULL
    SELECT * INTO cfg.client_ship_no_pre_prefix_fix FROM cfg.client_ship_no;

/* =========================================================================
   CALCUL
   ========================================================================= */
IF OBJECT_ID('tempdb..#ship') IS NOT NULL DROP TABLE #ship;
CREATE TABLE #ship (
    CardCode  nvarchar(15) COLLATE DATABASE_DEFAULT NOT NULL,
    LineNum   int          NOT NULL,
    [Address] nvarchar(50) COLLATE DATABASE_DEFAULT NULL,
    kais_no   int          NULL,
    has_tie   bit          NOT NULL,
    old_no    int          NOT NULL,
    new_no    int          NULL,
    src       varchar(24)  COLLATE DATABASE_DEFAULT NULL,
    PRIMARY KEY (CardCode, LineNum)
);

/* LEFT JOIN a la vista: hi ha files congelades sense adreça a CRD1 avui
   (adreces esborrades a SAP des de l'01/09). Existeixen, RESERVEN el seu
   numero i no s'emeten -vw_client_ship fa INNER JOIN a CRD1-, pero han
   d'entrar aqui o l'assercio de cobertura no quadrara. */
INSERT #ship (CardCode, LineNum, [Address], kais_no, has_tie, old_no)
SELECT  f.CardCode,
        f.LineNum,
        k.[Address],
        k.kais_no,
        ISNULL(k.client_has_tie, 0),
        f.ship_no
FROM    cfg.client_ship_no AS f
LEFT JOIN etl.vw_client_ship_kais_no AS k
       ON k.CardCode = f.CardCode AND k.LineNum = f.LineNum;

/* La regla. Nomes dues branques: el prefix, o quedar-se com estava. */
UPDATE #ship
SET new_no = CASE WHEN kais_no IS NOT NULL AND has_tie = 0 THEN kais_no ELSE old_no END,
    src    = CASE WHEN kais_no IS NOT NULL AND has_tie = 0 THEN 'PREFIX'
                  WHEN has_tie = 1                         THEN 'TIE_EXCLUDED'
                  ELSE 'NO_KAIS_NO' END;

/* =========================================================================
   ASSERCIONS - abans d'escriure res
   ========================================================================= */
IF EXISTS (SELECT 1 FROM #ship WHERE new_no IS NULL)
BEGIN
    RAISERROR('Files sense new_no. No s escriu res.', 16, 1);
    RETURN;
END

IF (SELECT COUNT(*) FROM #ship) <> (SELECT COUNT(*) FROM cfg.client_ship_no)
BEGIN
    RAISERROR('#ship no cobreix totes les files de cfg.client_ship_no. No s escriu res.', 16, 1);
    RETURN;
END

/* Unicitat dins del client. Si aixo salta, s'ATURA i es mira: no s'inventa cap
   rang de sobreeiximent, perque un numero que no es pot justificar contra KAIS
   es pitjor que no canviar res. */
IF EXISTS (SELECT 1 FROM #ship GROUP BY CardCode, new_no HAVING COUNT(*) > 1)
BEGIN
    SELECT problema = 'DOS new_no IGUALS DINS D UN CLIENT',
           s.CardCode, s.LineNum, s.[Address], s.kais_no, s.old_no, s.new_no, s.src
    FROM   #ship AS s
    INNER JOIN (SELECT CardCode, new_no FROM #ship
                GROUP BY CardCode, new_no HAVING COUNT(*) > 1) AS d
            ON d.CardCode = s.CardCode AND d.new_no = s.new_no
    ORDER BY s.CardCode, s.new_no, s.LineNum;
    RAISERROR('Xocaria amb UQ_cfg_client_ship_no. No s escriu res: mira la llista de sobre.', 16, 1);
    RETURN;
END

/* id_client_location es varchar(13) = 9 + 1 + 3, i sp_load_clients fa
   RIGHT('000' + ..., 3). Un numero de 4 xifres es truncaria per l'esquerra i
   COL.LAPSARIA DOS IDENTIFICADORS EN UN, en silenci: exactament el dany que
   aquesta taula existeix per evitar. */
IF EXISTS (SELECT 1 FROM #ship WHERE new_no < 0 OR new_no > 999)
BEGIN
    RAISERROR('new_no fora del rang 0..999. No s escriu res.', 16, 1);
    RETURN;
END

/* =========================================================================
   ESCRIPTURA - permutacio en dues fases

   UQ_cfg_client_ship_no UNIQUE (CardCode, ship_no) fa que C251271 (1->2, 2->1)
   xoqui fila a fila. Un sol UPDATE massiu tampoc no es segur: que SQL Server
   resolgui la permutacio depen del pla d'execucio, no del llenguatge.

   Les dues fases toquen TOTES les files dels clients afectats, no nomes les que
   canvien: si una fila que no canvia es quedes al positiu, una altra hi xocaria
   a la fase B. -1-new_no es injectiu, aixi que la fase A no xoca amb ella
   mateixa.
   ========================================================================= */
IF OBJECT_ID('tempdb..#cli') IS NOT NULL DROP TABLE #cli;
CREATE TABLE #cli (CardCode nvarchar(15) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY);
INSERT #cli (CardCode) SELECT DISTINCT CardCode FROM #ship WHERE new_no <> old_no;

BEGIN TRANSACTION;

    /* FASE A - a l'espai negatiu */
    UPDATE f
    SET    f.ship_no = -1 - s.new_no
    FROM   cfg.client_ship_no AS f
    INNER JOIN #ship AS s ON s.CardCode = f.CardCode AND s.LineNum = f.LineNum
    INNER JOIN #cli  AS c ON c.CardCode = f.CardCode;

    /* FASE B - al valor definitiu */
    UPDATE f
    SET    f.ship_no        = s.new_no,
           f.ship_no_source = s.src,
           f.ship_no_prev   = CASE WHEN s.new_no <> s.old_no THEN s.old_no ELSE f.ship_no_prev END,
           f.renumbered_at  = CASE WHEN s.new_no <> s.old_no THEN @now      ELSE f.renumbered_at END
    FROM   cfg.client_ship_no AS f
    INNER JOIN #ship AS s ON s.CardCode = f.CardCode AND s.LineNum = f.LineNum
    INNER JOIN #cli  AS c ON c.CardCode = f.CardCode;

    IF EXISTS (SELECT 1 FROM cfg.client_ship_no WHERE ship_no < 0)
    BEGIN
        ROLLBACK TRANSACTION;
        RAISERROR('Queden ship_no negatius: la fase B no ha cobert tot. Rollback fet.', 16, 1);
        RETURN;
    END

    /* Rastre, amb els identificadors tal com els veu Analitza. */
    INSERT [audit].client_ship_no_changes
           (migration_name, changed_at, CardCode, LineNum, ship_no_old, ship_no_new,
            [Address], reason, id_old, id_new)
    SELECT  @mig, @now, s.CardCode, s.LineNum, s.old_no, s.new_no,
            s.[Address], s.src,
            LEFT(cc.client_code + '-' + RIGHT('000' + CAST(s.old_no AS varchar(10)), 3), 13),
            LEFT(cc.client_code + '-' + RIGHT('000' + CAST(s.new_no AS varchar(10)), 3), 13)
    FROM    #ship AS s
    LEFT JOIN etl.vw_client_code AS cc ON cc.CardCode = s.CardCode
    WHERE   s.new_no <> s.old_no;

    DECLARE @changed bigint = @@ROWCOUNT;

    /* ship_no_source tambe per a les files que no s'han mogut, o la columna
       tindria dos significats per a NULL. Cap ship_no canvia: cap risc d'UQ. */
    UPDATE f
    SET    f.ship_no_source = s.src
    FROM   cfg.client_ship_no AS f
    INNER JOIN #ship AS s ON s.CardCode = f.CardCode AND s.LineNum = f.LineNum
    WHERE  f.ship_no_source IS NULL;

    /* Arma el check ship_no_prefix_mismatch amb el que queda LEGITIMAMENT
       descuadrat (els clients amb empat de prefix). Es un valor que escriu el
       codi, no una ma: el mateix patro que DISCOUNT_AS_PERCENT_PUBLISHED. */
    UPDATE cfg.settings
    SET    [value] = CAST((SELECT COUNT(*) FROM #ship
                           WHERE kais_no IS NOT NULL AND kais_no <> new_no) AS varchar(10))
    WHERE  [key] = 'SHIP_NO_PREFIX_BASELINE';

    INSERT cfg.migrations_applied (migration_name, rows_affected, notes)
    VALUES (@mig, @changed,
            'ship_no = prefix NNN- de CRD1.Address. Clients amb prefix duplicat exclosos sencers. Copia previa a cfg.client_ship_no_pre_prefix_fix; rollback nomes valid mentre no s hagi publicat a dbo.');

    /* El permis es consumeix: no ha de quedar obert. */
    UPDATE cfg.settings SET [value] = '0' WHERE [key] = 'ALLOW_SHIP_NO_RENUMBER';

COMMIT TRANSACTION;

/* =========================================================================
   INFORMES - no son decoratius. Mirar-los abans de continuar.
   (SELECT i no PRINT: els PRINT no arriben a qui executa aixo per ADO.NET.)
   ========================================================================= */
SELECT informe = '1. Resum per origen del numero',
       src, files = COUNT(*),
       han_canviat = SUM(CASE WHEN new_no <> old_no THEN 1 ELSE 0 END)
FROM   #ship GROUP BY src ORDER BY src;

SELECT informe = '2. Identificadors que apareixen i desapareixen',
       ids_que_desapareixen = (SELECT COUNT(*) FROM
            (SELECT CardCode, old_no FROM #ship EXCEPT SELECT CardCode, new_no FROM #ship) AS x),
       ids_nous             = (SELECT COUNT(*) FROM
            (SELECT CardCode, new_no FROM #ship EXCEPT SELECT CardCode, old_no FROM #ship) AS y),
       llindar_ID_DROP_MAX  = (SELECT [value] FROM cfg.settings WHERE [key] = 'ID_DROP_MAX');

SELECT informe = '3. Clients exclosos per prefix duplicat (es queden com estaven)',
       s.CardCode, s.LineNum, s.[Address], s.kais_no, s.old_no
FROM   #ship AS s WHERE s.src = 'TIE_EXCLUDED' ORDER BY s.CardCode, s.LineNum;

SELECT informe = '4. Adreces sense numero de KAIS (es queden com estaven)',
       s.CardCode, s.LineNum, s.[Address], s.old_no
FROM   #ship AS s WHERE s.src = 'NO_KAIS_NO' ORDER BY s.CardCode, s.LineNum;

SELECT informe = '5. SHIP_NO_PREFIX_BASELINE que ha quedat armat',
       [value] FROM cfg.settings WHERE [key] = 'SHIP_NO_PREFIX_BASELINE';

DROP TABLE #ship;
DROP TABLE #cli;
GO

/* =========================================================================
   ROLLBACK - a ma, i NOMES mentre no s'hagi publicat a dbo.est_*

   Mateixa tecnica de dues fases, pel mateix motiu.

     BEGIN TRANSACTION;
       UPDATE f SET f.ship_no = -1 - b.ship_no
       FROM   cfg.client_ship_no AS f
       INNER JOIN cfg.client_ship_no_pre_prefix_fix AS b
               ON b.CardCode = f.CardCode AND b.LineNum = f.LineNum;

       UPDATE cfg.client_ship_no SET ship_no = -1 - ship_no WHERE ship_no < 0;

       UPDATE cfg.client_ship_no
       SET    ship_no_prev = NULL, renumbered_at = NULL, ship_no_source = NULL;

       DELETE cfg.migrations_applied
       WHERE  migration_name = '2026-09-29_ship_no_from_address_prefix';

       UPDATE cfg.settings SET [value] = '' WHERE [key] = 'SHIP_NO_PREFIX_BASELINE';
     COMMIT TRANSACTION;

     -- i tot seguit, per tornar dbo al que hi havia:
     --   EXEC etl.sp_run_all @ForceFullLines = 1;
   ========================================================================= */
