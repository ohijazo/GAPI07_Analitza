/* =========================================================================
   04_migracions.sql  —  Canvis d'esquema sobre una BD ja desplegada

   PER QUE EXISTEIX AQUEST FITXER
   ------------------------------
   01_create_database.sql fa DROP TABLE de les est_*, o sigui que NO es pot
   tornar a executar sobre la productiva: s'enduria les dades que Analitza
   consulta. Aquí hi van els canvis d'esquema equivalents, en forma d'ALTER
   guardat, perquè una BD existent convergeixi amb el DDL sense perdre res.

   Cada bloc ha de ser IDEMPOTENT i ha de deixar la taula igual que la deixaria
   01_create_database.sql en una instal.lació nova. Si un dia divergeixen, la
   productiva i la de test deixen de ser la mateixa cosa i les validacions no
   volen dir res.

   L'executa deploy.sql just després del schema.
   ========================================================================= */
USE IntercanviSAP;
GO

/* -------------------------------------------------------------------------
   2026-08-28 — discount: decimal(5,2) -> decimal(9,6)

   discount es un multiplicador (1.00 = sense descompte, 0.90 = 10%), i el
   net_amount es calcula a precisio completa. Amb nomes 2 decimals, un
   descompte del 3,33% queda 0,9667 -> 0,97 i la formula
   net_amount = price * qty * discount deixa de quadrar: el check
   formula_break saltaria cada nit. Amb les 62 linies de la BD de test cap
   linia porta descompte i el problema no es veia.

   Ampliar es compatible cap enrere per a qui llegeix: Analitza fa
   "1-discount" i el que rep son mes decimals, no un valor diferent.
   Acordat amb l'Adria el 27/08/2026.
   ------------------------------------------------------------------------- */
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID('dbo.est_linies_albara')
             AND name = 'discount' AND (precision <> 9 OR scale <> 6))
    ALTER TABLE dbo.est_linies_albara ALTER COLUMN discount decimal(9,6) NULL;
GO

IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID('staging.est_linies_albara')
             AND name = 'discount' AND (precision <> 9 OR scale <> 6))
    ALTER TABLE staging.est_linies_albara ALTER COLUMN discount decimal(9,6) NULL;
GO

IF OBJECT_ID('baseline.est_linies_albara') IS NOT NULL
   AND EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('baseline.est_linies_albara')
                 AND name = 'discount' AND (precision <> 9 OR scale <> 6))
    /* La fotografia tambe, o comparar-la amb staging donaria diferencies que
       nomes son d'escala. */
    ALTER TABLE baseline.est_linies_albara ALTER COLUMN discount decimal(9,6) NULL;
GO

/* -------------------------------------------------------------------------
   2026-08-31 - Dos settings nous

   Van tambe a 01_create_database.sql, al bloc de seeds guardats. Aqui hi son
   perque una BD ja desplegada no els te i les dues instal.lacions han de
   quedar iguals: si divergeixen, validar a test deixa de dir res de la
   productiva.
   ------------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM cfg.settings WHERE [key] = 'ALLOW_DESTRUCTIVE_SCHEMA')
    INSERT cfg.settings ([key], [value], description)
    VALUES ('ALLOW_DESTRUCTIVE_SCHEMA', '0', 'Permis d un sol us per deixar que 01_create_database.sql faci DROP de les dbo.est_* quan ja tenen dades. Normalment no cal: per posar al dia una BD desplegada hi ha aquest mateix fitxer. El propi script el torna a 0 despres dels DROP.');
GO

/* La convencio del discount NO es una preferencia nostra: es un canvi
   coordinat amb Analitza i del mateix dia del tall.
     '0' = multiplicador (1,00 = sense descompte)  -> el que feia KAIS
     '1' = percentatge   (0,00 = sense descompte)  -> el que diu la seva guia
   El llegeixen sp_load_invoice_lines i el check formula_break, i han de veure
   el mateix valor. Si es posa a '1' i Analitza no treu el seu "1 - discount"
   el mateix dia, els imports li surten a zero: es una fallada sorollosa a
   proposit. Passos i ordre a docs/runbook_cutover.md. */
IF NOT EXISTS (SELECT 1 FROM cfg.settings WHERE [key] = 'DISCOUNT_AS_PERCENT')
    INSERT cfg.settings ([key], [value], description)
    VALUES ('DISCOUNT_AS_PERCENT', '0', 'Convencio de est_linies_albara.discount. 0 = multiplicador (KAIS, el que hi ha avui); 1 = percentatge (la guia d Analitza). Nomes es toca el dia del cutover i coordinadament amb Analitza: si ells no treuen el seu 1-discount el mateix dia, els imports surten a zero.');
GO

IF NOT EXISTS (SELECT 1 FROM cfg.settings WHERE [key] = 'DISCOUNT_AS_PERCENT_PUBLISHED')
    INSERT cfg.settings ([key], [value], description)
    VALUES ('DISCOUNT_AS_PERCENT_PUBLISHED', '0', 'Amb quina convencio de discount es va publicar dbo.est_linies_albara per ultim cop. L escriu sp_swap_staging_to_prod dins de la transaccio del swap i NO es toca a ma: si no coincideix amb DISCOUNT_AS_PERCENT, sp_load_invoice_lines forca un FULL en comptes de copiar de dbo linies en l altra convencio.');
GO

/* 2026-09-01 - check history_floor. Veure el capcal de sp_data_quality_checks. */
IF NOT EXISTS (SELECT 1 FROM cfg.settings WHERE [key] = 'HISTORY_FLOOR_ENFORCE')
    INSERT cfg.settings ([key], [value], description)
    VALUES ('HISTORY_FLOOR_ENFORCE', '1', 'Atura el swap si la data mes antiga de staging.est_linies_albara es anterior a la de dbo. Analitza reemplaça el seu historic a partir de la data minima que li enviem, aixi que fer-la retrocedir els esborra dades. Nomes es posa a 0 per a un backfill volgut, i es torna a 1 tot seguit.');
GO

/* 2026-09-01 - congelar el numero d'adreça (correu de l'Adria del 01/09). */
/* -------------------------------------------------------------------------
   cfg.client_ship_no - la meitat dreta de id_client_location, congelada

   NO ES UNA TAULA DERIVADA: es estat que no es pot regenerar. Si es perd, tots
   els numeros d'adreça es recalculen i Analitza veu desapareixer ubicacions i
   neixer-ne de noves amb l'historic d'una altra. Ha d'entrar al backup i no
   l'ha de truncar mai ningu.

   L'omple etl.sp_assign_client_ship_no a cada execucio de l'ETL, nomes
   afegint. Veure el capcal d'aquell procediment per al perque.
   ------------------------------------------------------------------------- */
IF OBJECT_ID('cfg.client_ship_no') IS NULL
CREATE TABLE cfg.client_ship_no (
    CardCode   nvarchar(15)  NOT NULL,
    LineNum    int           NOT NULL,
    ship_no    int           NOT NULL,
    [Address]  nvarchar(50)  NULL,
    frozen_at  datetime2(3)  NOT NULL CONSTRAINT DF_cfg_client_ship_no_frozen DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_cfg_client_ship_no PRIMARY KEY CLUSTERED (CardCode, LineNum),
    /* Dues adreces del mateix client no poden compartir numero: si passes,
       dos id_client_location diferents col.lapsarien en un. */
    CONSTRAINT UQ_cfg_client_ship_no UNIQUE (CardCode, ship_no)
);
GO

/* -------------------------------------------------------------------------
   2026-09-10 - sap_raw.OCRD.U_FCNewCardCode: fora

   El UDF OCRD.U_FCNewCardCode es va crear a SAP el 26/08/2026 per guardar el
   client successor en un canvi de rao social. Duplicava U_SEICodienllac, un
   camp que ja portava la implantacio i que feia exactament aixo (apuntant al
   reves: guarda el predecessor). S'ha borrat de SAP, el Worker ja no el demana
   i el new_code surt de etl.vw_client_successor.

   La columna del mirall se'n va aqui i no a 02_create_sap_raw.sql: alla nomes
   hi ha ALTER ... ADD, i una BD ja desplegada la te creada.

   ORDRE: deploy.sql executa aquest fitxer ABANS dels SPs. Entre el DROP i la
   recreacio de sp_load_clients hi ha uns segons en que el SP antic referencia
   una columna que ja no existeix, aixi que no s'ha de desplegar mentre corre
   el job de les 03:00.
   ------------------------------------------------------------------------- */
IF COL_LENGTH('sap_raw.OCRD', 'U_FCNewCardCode') IS NOT NULL
    ALTER TABLE sap_raw.OCRD DROP COLUMN U_FCNewCardCode;
GO

/* -------------------------------------------------------------------------
   2026-09-16 - sap_raw.OITM.U_SEIFamCialCat: hi entra

   El camp de la FAMILIA comercial (les 12 que veu Analitza) ja es demanava al
   $select i la sonda l'ensenyava, pero no s'escrivia enlloc: MirrorTables no
   el portava i la taula del mirall no tenia la columna. O sigui que es baixava
   de SAP i es llencava, i l'ETL no el podia fer servir encara que volgues.

   Mesurat el 16/09/2026 contra KAIS (bi_estadili, ultims 12 mesos, amb les
   mateixes series excloses que aplica Analitza): dels 22,26 MEUR facturats,
   el 98,53% passa pels 198 articles que SAP ja te classificats. Els 782 que
   surten "sense familia" son recanvis, EPI's, palets i material de fabrica
   que no es venen: nomes 28 d'ells han facturat res, i 7 en fan el 90%.

   La columna va aqui i no nomes a 02_create_sap_raw.sql perque alla el CREATE
   no s'executa en una BD ja desplegada.
   ------------------------------------------------------------------------- */
IF COL_LENGTH('sap_raw.OITM', 'U_SEIFamCialCat') IS NULL
    ALTER TABLE sap_raw.OITM ADD U_SEIFamCialCat nvarchar(254) NULL;
GO

/* -------------------------------------------------------------------------
   2026-09-16 - cfg.settings.FAMILY_FROM_COMMERCIAL

   El seed viu a 01_create_database.sql, que no s'executa en una BD ja
   desplegada. Aqui perque hi arribi igualment, amb el mateix valor per
   defecte: '0', o sigui cap canvi de comportament fins que algu el toqui
   expressament.
   ------------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM cfg.settings WHERE [key] = 'FAMILY_FROM_COMMERCIAL')
    INSERT cfg.settings ([key], [value], description)
    VALUES ('FAMILY_FROM_COMMERCIAL', '0', 'Origen de est_families_productes i de est_productes.product_categories_id. 0 = els 110 grups d article d OITB (el que hi ha avui); 1 = la familia comercial OITM.U_SEIFamCialCat, les 12 que Analitza ensenya. Canviar-lo fa desapareixer 110 identificadors alhora, aixi que vol apujar ID_DROP_MAX el mateix dia i tornar-lo a baixar l endema.');
GO

/* -------------------------------------------------------------------------
   2026-09-17 - cfg.settings.RECEIVABLES_IN_USE

   Analitza te est_cobraments a la seva BD pero NO la importa: la van treure fa
   temps perque arrossegava cobraments pendents molt antics i gairebe tots els
   clients hi sortien amb deute. Confirmat per l'Adria el 17/09/2026.

   Mentre no la llegeixin, el check receivables_empty passa de CRITICAL a WARN:
   bloquejar el swap sencer per aquella taula aturaria clients, productes i
   linies d'albara -que si que fan servir- per una que no miren.

   Es torna a '1' el dia que la recuperin.
   ------------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM cfg.settings WHERE [key] = 'RECEIVABLES_IN_USE')
    INSERT cfg.settings ([key], [value], description)
    VALUES ('RECEIVABLES_IN_USE', '0', 'Analitza importa est_cobraments? 0 = no (el check receivables_empty es WARN i no atura el swap); 1 = si (torna a ser CRITICAL). A 0 des del 17/09/2026 per confirmacio de l Adria. Revisar-ho despres del cutover: la SAP productiva nomes porta factures realment pendents, aixi que el motiu pel qual la van desactivar no travessa el tall.');
GO

/* -------------------------------------------------------------------------
   2026-09-29 - el numero d'adreça surt del prefix NNN- de CRD1.Address

   El 01/09/2026 es va congelar el numero d'adreça a cfg.client_ship_no amb
       ROW_NUMBER() OVER (PARTITION BY CardCode ORDER BY LineNum)
   i el 29/09 es va veure que aquell numero NO era el de KAIS. El de KAIS es al
   NOM de l'adreça de SAP ('003-SANT QUIRZE-ST. QUIRZE'), que hi va escriure la
   migracio KAIS->SAP. Mesurat contra l'exportacio d'Analitza, sobre 5.572
   adreces de ship-to amb codi postal:

       renumerant 0,1,2...        -> 4.923 zips quadren  (87,6%)
       el prefix NNN- de Address  -> 5.574 zips quadren  (99,2%)

   i, mirant nomes les 804 adreces que van canviar de numero, el zip de KAIS
   quadrava amb el de SAP en 132 i despres en 786. El residu no son errors de
   numeracio: son adreces que a KAIS no tenien codi postal, zeros al davant
   (080057 contra 80057) i una adreça que a SAP ha canviat de ciutat. La
   consulta que ho torna a mesurar es sql\verify_ship_no.sql.

   Veure el capcal de etl.vw_client_ship_kais_no a procs\etl_vw_kais_codes.sql.

   AQUI NOMES HI HA L'ESQUEMA. El canvi de dades viu a
       sql\migrations\2026-09-29_ship_no_from_address_prefix.sql
   i NO es crida des de deploy.sql, expressament: aquest fitxer s'executa a cada
   desplegament i renumerar reassigna ~800 id_client_location. Un desplegament
   rutinari no ha de poder disparar-ho.

   LA DIVISIO, PER SI TORNA A CALDRE
   ---------------------------------
     schema\04_migracions.sql  -> canvis d'ESQUEMA, idempotents i automatics.
     sql\migrations\*.sql      -> canvis de DADES sobre estat no regenerable.
                                  Un sol cop, a ma, i mirant la sortida.
   ------------------------------------------------------------------------- */
IF COL_LENGTH('cfg.client_ship_no', 'ship_no_prev') IS NULL
    ALTER TABLE cfg.client_ship_no ADD ship_no_prev int NULL;
GO

IF COL_LENGTH('cfg.client_ship_no', 'renumbered_at') IS NULL
    ALTER TABLE cfg.client_ship_no ADD renumbered_at datetime2(3) NULL;
GO

/* D'on surt el numero: PREFIX (el NNN- del nom d'adreça de SAP, el bo),
   ROWNUMBER (el calcul del 01/09, pendent de corregir), MAXPLUS1 (adreça nova
   sense numero de KAIS) o TIE_EXCLUDED (client amb dues adreces sota el mateix
   prefix: es queda com estava a proposit). */
IF COL_LENGTH('cfg.client_ship_no', 'ship_no_source') IS NULL
    ALTER TABLE cfg.client_ship_no ADD ship_no_source varchar(24) NULL;
GO

/* -------------------------------------------------------------------------
   cfg.migrations_applied - registre dels canvis de dades d'un sol us

   Els fitxers de sql\migrations\ s'executen a ma i han de ser idempotents: la
   primera guarda de cadascun es mirar si ja consta aqui. Sense aixo, la
   idempotencia dependria de recordar-ho.
   ------------------------------------------------------------------------- */
IF OBJECT_ID('cfg.migrations_applied') IS NULL
CREATE TABLE cfg.migrations_applied (
    migration_name  varchar(120)  NOT NULL CONSTRAINT PK_cfg_migrations_applied PRIMARY KEY,
    applied_at      datetime2(3)  NOT NULL CONSTRAINT DF_cfg_migr_at DEFAULT SYSUTCDATETIME(),
    applied_by      nvarchar(128) NOT NULL CONSTRAINT DF_cfg_migr_by DEFAULT SUSER_SNAME(),
    rows_affected   bigint        NULL,
    notes           nvarchar(max) NULL
);
GO

/* -------------------------------------------------------------------------
   audit.client_ship_no_changes - quin id_client_location era quin

   No es redundant amb ship_no_prev de la fila. La columna nomes guarda UN
   valor anterior i una segona renumeracio el trepitjaria; i sobretot, aixo es
   d'on surt el mapatge que Analitza necessita.

   PER QUE ANALITZA EL NECESSITA: quan els deixa d'arribar un client_location
   l'esborren de l'aplicacio pero MANTENEN l'historic d'albarans (correu de
   l'Adria, 01/09/2026). O sigui que renumerar no els deixa un forat: els deixa
   l'historic enganxat al numero antic i el numero nou buit. Per aixo id_old i
   id_new es guarden ja construits amb etl.vw_client_code: el que se li passa
   ha de ser exactament el que ell te a la seva BD, sense que ningu hagi de
   tornar a muntar la formula del contracte a ma (Regla 04).
   ------------------------------------------------------------------------- */
IF OBJECT_ID('audit.client_ship_no_changes') IS NULL
CREATE TABLE [audit].client_ship_no_changes (
    change_id       bigint IDENTITY(1,1) CONSTRAINT PK_audit_client_ship_no_changes PRIMARY KEY,
    migration_name  varchar(120)  NOT NULL,
    changed_at      datetime2(3)  NOT NULL CONSTRAINT DF_audit_csnc_at DEFAULT SYSUTCDATETIME(),
    CardCode        nvarchar(15)  NOT NULL,
    LineNum         int           NOT NULL,
    ship_no_old     int           NOT NULL,
    ship_no_new     int           NOT NULL,
    [Address]       nvarchar(50)  NULL,
    reason          varchar(24)   NOT NULL,
    id_old          varchar(13)   NULL,
    id_new          varchar(13)   NULL
);
GO

IF NOT EXISTS (SELECT 1 FROM cfg.settings WHERE [key] = 'ALLOW_SHIP_NO_RENUMBER')
    INSERT cfg.settings ([key], [value], description)
    VALUES ('ALLOW_SHIP_NO_RENUMBER', '0', 'Permis d un sol us perque sql\migrations\2026-09-29_ship_no_from_address_prefix.sql pugui reassignar numeros a cfg.client_ship_no. Aquella taula es estat NO regenerable i reassignar-hi numeros es precisament l operacio que el disseny prohibeix: nomes es fa des d aquell script, un sol cop i mirant la sortida. El propi script el torna a 0.');
GO

IF NOT EXISTS (SELECT 1 FROM cfg.settings WHERE [key] = 'SHIP_NO_PREFIX_BASELINE')
    INSERT cfg.settings ([key], [value], description)
    VALUES ('SHIP_NO_PREFIX_BASELINE', '', 'Quantes adreces queden legitimament amb el prefix NNN- diferent del ship_no congelat (els clients amb dues adreces sota el mateix prefix). L escriu la migracio de re-congelacio, NO es toca a ma: es el mateix patro que DISCOUNT_AS_PERCENT_PUBLISHED. El check ship_no_prefix_mismatch hi compara; buit vol dir que encara no s ha renumerat, i llavors el check nomes avisa.');
GO
