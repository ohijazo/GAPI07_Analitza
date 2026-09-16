/* =========================================================================
   IntercanviSAP - Database, schemas, tables and indexes
   ---------------------------------------------------------------------------
   BD intermèdia que serveix les dades a Analitza CM en substitució del
   "Intercanvi" que manté KAIS. Estructura est_* **idèntica al format actual
   de KAIS** (WIDE per atributs, id_client_location curt, sense prefixos a
   línies, discount com a multiplicador, etc.). Alimentada des de SAP B1.

   Patró: doble schema staging -> dbo per swap atòmic.
     - staging.est_* : escriptura de l'ETL
     - dbo.est_*     : lo que llegeix Analitza (TRUNCATE+INSERT en transacció)

   Schemas addicionals:
     - etl   : stored procedures
     - audit : log d'execucions i warnings
     - cfg   : configuració (attribute_mapping, country_code_overrides, settings)

   ATENCIO: aquest script NO es idempotent. Fa DROP TABLE de les vuit est_*
   per tornar-les a crear buides, o sigui que sobre una BD amb dades deixa
   Analitza sense res fins a la seguent carrega correcta. Es un script de
   CREACIO INICIAL i s'executa una sola vegada.

   Per posar al dia una BD ja desplegada, l'script es schema/04_migracions.sql,
   que fa el mateix canvi en forma d'ALTER guardat i sense perdre files. Per
   aixo deploy.sql ja no crida aquest fitxer.

   Hi ha una guarda mes avall que avorta si dbo.est_* te files. audit/cfg i els
   schemas no es toquen.
   ========================================================================= */

USE master;
GO

/* SAP B1 (DB_FARINERA_TEST) ve instal.lat amb SQL_Latin1_General_CP850_CI_AS.
   Mantenim la mateixa collation per evitar conflictes en JOINs cross-DB. */
IF DB_ID('IntercanviSAP') IS NULL
BEGIN
    CREATE DATABASE IntercanviSAP COLLATE SQL_Latin1_General_CP850_CI_AS;
    ALTER DATABASE IntercanviSAP SET RECOVERY SIMPLE;
    ALTER DATABASE IntercanviSAP SET READ_COMMITTED_SNAPSHOT ON;
END
GO

USE IntercanviSAP;
GO

IF DB_NAME() <> N'IntercanviSAP'
    THROW 50000, 'El script ha de córrer dins IntercanviSAP.', 1;
GO

/* ---------- schemas ---------- */
IF SCHEMA_ID('staging') IS NULL EXEC ('CREATE SCHEMA staging');
IF SCHEMA_ID('etl')     IS NULL EXEC ('CREATE SCHEMA etl');
IF SCHEMA_ID('audit')   IS NULL EXEC ('CREATE SCHEMA [audit]');
IF SCHEMA_ID('cfg')     IS NULL EXEC ('CREATE SCHEMA cfg');
GO

/* ---------- GUARDA: no esborrar les taules que llegeix Analitza ----------

   El bloc de sota fa DROP de les vuit dbo.est_*. Sobre la BD desplegada aixo
   deixa Analitza sense dades fins a la seguent carrega correcta, i el 25/08/2026
   va obligar a desplegar els procediments un per un a ma per no disparar-ho.

   La guarda mira si hi ha files i, si n'hi ha, atura l'script. L'escapatoria va a
   cfg.settings i no a una variable de sqlcmd ni a una taula temporal: aixo
   s'executa des de SSMS, des de deploy_via_powershell.ps1 i potser d'aqui a un
   any des d'una altra cosa, i el permis ha de valer igual als tres casos i
   quedar escrit alla on qualsevol el pot veure. El mateix script el torna a '0'
   just despres dels DROP: es d'un sol us.

   El recompte surt de sys.partitions i no d'un SELECT COUNT(*) perque en una
   instal.lacio nova les taules encara no existeixen i el batch no compilaria
   (la resolucio diferida de noms nomes va dins de procediments). Que sigui
   aproximat no importa: la pregunta es "hi ha dades o no".
   ------------------------------------------------------------------------- */
DECLARE @est_rows bigint = 0, @allow nvarchar(400) = N'0';

SELECT @est_rows = ISNULL(SUM(p.rows), 0)
FROM   sys.partitions p
JOIN   sys.objects   o ON o.object_id = p.object_id
JOIN   sys.schemas   sc ON sc.schema_id = o.schema_id
WHERE  p.index_id IN (0, 1)
  AND  o.type = 'U'
  AND  sc.name = 'dbo'
  AND  o.name LIKE 'est[_]%';

IF OBJECT_ID('cfg.settings') IS NOT NULL
    SELECT @allow = [value] FROM cfg.settings WHERE [key] = 'ALLOW_DESTRUCTIVE_SCHEMA';

IF @est_rows > 0 AND ISNULL(@allow, N'0') <> N'1'
BEGIN
    DECLARE @msg nvarchar(2000) =
        N'01_create_database.sql avortat: dbo.est_* te ' + CAST(@est_rows AS nvarchar(20))
        + N' files i aquest script les esborraria. Analitza es quedaria sense dades.'
        + CHAR(13) + CHAR(10)
        + N'Per posar al dia una BD ja desplegada, executa schema/04_migracions.sql.'
        + CHAR(13) + CHAR(10)
        + N'Si de debo vols recrear-les buides: UPDATE cfg.settings SET [value]=''1'' '
        + N'WHERE [key]=''ALLOW_DESTRUCTIVE_SCHEMA''; i torna a executar. El permis '
        + N'es consumeix tot sol.';
    THROW 50001, @msg, 1;
END
GO

/* ---------- DROP taules est_* antigues (format LONG) ---------- */
/* Fem drop per tornar-les a crear amb l'esquema WIDE compatible amb KAIS.
   L'ordre no importa (no hi ha FKs entre elles). */
IF OBJECT_ID('dbo.est_agents')                       IS NOT NULL DROP TABLE dbo.est_agents;
IF OBJECT_ID('staging.est_agents')                   IS NOT NULL DROP TABLE staging.est_agents;
IF OBJECT_ID('dbo.est_families_productes')           IS NOT NULL DROP TABLE dbo.est_families_productes;
IF OBJECT_ID('staging.est_families_productes')       IS NOT NULL DROP TABLE staging.est_families_productes;
IF OBJECT_ID('dbo.est_clients')                      IS NOT NULL DROP TABLE dbo.est_clients;
IF OBJECT_ID('staging.est_clients')                  IS NOT NULL DROP TABLE staging.est_clients;
IF OBJECT_ID('dbo.est_productes')                    IS NOT NULL DROP TABLE dbo.est_productes;
IF OBJECT_ID('staging.est_productes')                IS NOT NULL DROP TABLE staging.est_productes;
IF OBJECT_ID('dbo.est_linies_albara')                IS NOT NULL DROP TABLE dbo.est_linies_albara;
IF OBJECT_ID('staging.est_linies_albara')            IS NOT NULL DROP TABLE staging.est_linies_albara;
IF OBJECT_ID('dbo.est_atributs_client')              IS NOT NULL DROP TABLE dbo.est_atributs_client;
IF OBJECT_ID('staging.est_atributs_client')          IS NOT NULL DROP TABLE staging.est_atributs_client;
IF OBJECT_ID('dbo.est_atributs_producte')            IS NOT NULL DROP TABLE dbo.est_atributs_producte;
IF OBJECT_ID('staging.est_atributs_producte')        IS NOT NULL DROP TABLE staging.est_atributs_producte;
IF OBJECT_ID('dbo.est_clients_efectes_pendents')     IS NOT NULL DROP TABLE dbo.est_clients_efectes_pendents;
IF OBJECT_ID('staging.est_clients_efectes_pendents') IS NOT NULL DROP TABLE staging.est_clients_efectes_pendents;
IF OBJECT_ID('dbo.est_cobraments')                   IS NOT NULL DROP TABLE dbo.est_cobraments;
IF OBJECT_ID('staging.est_cobraments')               IS NOT NULL DROP TABLE staging.est_cobraments;
GO

/* El permis destructiu es d'un sol us: consumir-lo aqui, just despres dels
   DROP, i no al final de l'script. Si alguna cosa peta mes avall, la BD no es
   queda amb la guarda desarmada esperant el proxim que executi el fitxer. */
IF OBJECT_ID('cfg.settings') IS NOT NULL
    UPDATE cfg.settings SET [value] = N'0' WHERE [key] = N'ALLOW_DESTRUCTIVE_SCHEMA';
GO

/* =========================================================================
   est_agents  (OSLP -> agents)
   Format KAIS: id_salesman varchar(3), name varchar(35)
   ========================================================================= */
CREATE TABLE dbo.est_agents (
    id_salesman  varchar(3)  NOT NULL,
    [name]       varchar(35) NOT NULL,
    CONSTRAINT PK_est_agents PRIMARY KEY CLUSTERED (id_salesman)
);
CREATE TABLE staging.est_agents (
    id_salesman  varchar(3)  NOT NULL,
    [name]       varchar(35) NOT NULL,
    CONSTRAINT PK_staging_est_agents PRIMARY KEY CLUSTERED (id_salesman)
);
GO

/* =========================================================================
   est_families_productes (OITB -> famílies de producte)
   Format KAIS: id_product_category varchar(250), name varchar(250)
   KAIS emplena una fila per producte (2.051 files, 15 famílies úniques).
   Nosaltres carregarem la forma normalitzada (una fila per família) i deixem
   que Analitza faci DISTINCT o JOIN — no té sentit duplicar. Si Analitza
   requereix explícitament la duplicació 1:1, canviar sp_load_product_categories.
   ========================================================================= */
CREATE TABLE dbo.est_families_productes (
    id_product_category varchar(250) NOT NULL,
    [name]              varchar(250) NOT NULL,
    CONSTRAINT PK_est_families_productes PRIMARY KEY CLUSTERED (id_product_category)
);
CREATE TABLE staging.est_families_productes (
    id_product_category varchar(250) NOT NULL,
    [name]              varchar(250) NOT NULL,
    CONSTRAINT PK_staging_est_families_productes PRIMARY KEY CLUSTERED (id_product_category)
);
GO

/* =========================================================================
   est_clients  (OCRD + CRD1 + OCRY)
   Format KAIS: WIDE, sense holidays/comments/payment_method (aquests van a
   est_atributs_client). id_client_location = varchar(13) format
   "<CardCode 8>-<ShipTo 3>" (KAIS format).
   ========================================================================= */
CREATE TABLE dbo.est_clients (
    id_client_location varchar(13) NOT NULL,
    [name]             varchar(40) NOT NULL,
    active             int         NOT NULL,     -- 0 / 1
    [address]          varchar(35) NOT NULL,
    city               varchar(35) NOT NULL,
    zip_code           varchar(10) NOT NULL,
    country_code       varchar(4)  NULL,
    salesmen_id        varchar(3)  NOT NULL,
    new_code           varchar(8)  NULL,
    phone_number       varchar(30) NOT NULL,
    email              varchar(60) NOT NULL,
    CONSTRAINT PK_est_clients PRIMARY KEY CLUSTERED (id_client_location)
);
CREATE TABLE staging.est_clients (
    id_client_location varchar(13) NOT NULL,
    [name]             varchar(40) NOT NULL,
    active             int         NOT NULL,
    [address]          varchar(35) NOT NULL,
    city               varchar(35) NOT NULL,
    zip_code           varchar(10) NOT NULL,
    country_code       varchar(4)  NULL,
    salesmen_id        varchar(3)  NOT NULL,
    new_code           varchar(8)  NULL,
    phone_number       varchar(30) NOT NULL,
    email              varchar(60) NOT NULL,
    CONSTRAINT PK_staging_est_clients PRIMARY KEY CLUSTERED (id_client_location)
);
GO

/* =========================================================================
   est_productes (OITM)
   Format KAIS: id_product varchar(16), name varchar(90),
                product_categories_id varchar(250), active bit
   No inclou dates disponibilitat (KAIS no en té).
   ========================================================================= */
CREATE TABLE dbo.est_productes (
    id_product            varchar(16)  NOT NULL,
    [name]                varchar(90)  NOT NULL,
    product_categories_id varchar(250) NOT NULL,
    active                bit          NULL,
    CONSTRAINT PK_est_productes PRIMARY KEY CLUSTERED (id_product)
);
CREATE TABLE staging.est_productes (
    id_product            varchar(16)  NOT NULL,
    [name]                varchar(90)  NOT NULL,
    product_categories_id varchar(250) NOT NULL,
    active                bit          NULL,
    CONSTRAINT PK_staging_est_productes PRIMARY KEY CLUSTERED (id_product)
);
GO

/* =========================================================================
   est_linies_albara (ODLN/DLN1 + ORDN/RDN1 + ORIN/RIN1)
   Format KAIS:
     - id_invoice_line: int (contador seqüencial nostre, no ve de SAP)
     - invoices_id: varchar(13) — el DocNum de SAP com a text ("26700001")
     - date: datetime
     - client_locations_id: varchar(13)
     - products_id: varchar(16)
     - decimals amb precisió KAIS
     - **discount és un multiplicador**: 1.00 = no descompte, 0.90 = 10% desc.
       Fórmula: net_amount = quantity * product_price * discount
       decimal(9,6), no decimal(5,2): amb 2 decimals un 3,33% de descompte
       s'arrodoneix a 0,97 i la fórmula deixa de quadrar contra un net_amount
       calculat a precisió completa. Amb les 62 línies de test cap en porta i
       no es notava; amb descomptes reals el check formula_break saltaria cada
       nit. Acordat amb Analitza el 27/08/2026.
     - series varchar(2) (codi de sèrie SAP)
     - observations text (obsolet però compatible)
   No hi ha camp 'transaction' — retorns/abonaments es representen amb
   signe negatiu a quantity/net_amount.
   ========================================================================= */
CREATE TABLE dbo.est_linies_albara (
    id_invoice_line     int           NOT NULL,
    invoices_id         varchar(13)   NOT NULL,
    [date]              datetime      NOT NULL,
    client_locations_id varchar(13)   NOT NULL,
    products_id         varchar(16)   NOT NULL,
    product_price       decimal(16,6) NOT NULL,
    product_cost        decimal(16,6) NOT NULL,
    product_cost_2      decimal(16,6) NOT NULL,
    net_amount          numeric(38,6) NULL,
    discount            decimal(9,6)  NULL,       -- 1.00 = 0% desc, 0.90 = 10% desc
    quantity            decimal(11,3) NOT NULL,
    series              varchar(2)    NOT NULL,
    observations        varchar(max)  NOT NULL,   -- KAIS usa 'text' obsolet; varchar(max) equivalent modern
    CONSTRAINT PK_est_linies_albara PRIMARY KEY CLUSTERED (id_invoice_line)
);
CREATE TABLE staging.est_linies_albara (
    id_invoice_line     int           NOT NULL,
    invoices_id         varchar(13)   NOT NULL,
    [date]              datetime      NOT NULL,
    client_locations_id varchar(13)   NOT NULL,
    products_id         varchar(16)   NOT NULL,
    product_price       decimal(16,6) NOT NULL,
    product_cost        decimal(16,6) NOT NULL,
    product_cost_2      decimal(16,6) NOT NULL,
    net_amount          numeric(38,6) NULL,
    discount            decimal(9,6)  NULL,
    quantity            decimal(11,3) NOT NULL,
    series              varchar(2)    NOT NULL,
    observations        varchar(max)  NOT NULL,
    CONSTRAINT PK_staging_est_linies_albara PRIMARY KEY CLUSTERED (id_invoice_line)
);
GO

/* Índexs de performance (KAIS no en té, però ajuden a Analitza) */
CREATE NONCLUSTERED INDEX IX_est_linies_albara_client_date
    ON dbo.est_linies_albara (client_locations_id, [date])
    INCLUDE (products_id, net_amount, quantity);
CREATE NONCLUSTERED INDEX IX_est_linies_albara_product_date
    ON dbo.est_linies_albara (products_id, [date])
    INCLUDE (client_locations_id, net_amount, quantity);
CREATE NONCLUSTERED INDEX IX_est_linies_albara_invoice
    ON dbo.est_linies_albara (invoices_id);
CREATE NONCLUSTERED INDEX IX_est_linies_albara_date
    ON dbo.est_linies_albara ([date]);
GO

/* =========================================================================
   est_atributs_client (WIDE — format KAIS)
   Una fila per client_locations_id amb 8 columnes fixes.
   ========================================================================= */
CREATE TABLE dbo.est_atributs_client (
    client_locations_id        varchar(13)  NOT NULL,
    zone_id                    varchar(4)   NOT NULL,
    zone_description           varchar(30)  NOT NULL,
    payment_method             varchar(3)   NOT NULL,
    payment_description        varchar(35)  NOT NULL,
    positioning_bcn_consulting varchar(250) NULL,
    segmentation_use_1         varchar(250) NULL,
    segmentation_use_2         varchar(250) NULL,
    CONSTRAINT PK_est_atributs_client PRIMARY KEY CLUSTERED (client_locations_id)
);
CREATE TABLE staging.est_atributs_client (
    client_locations_id        varchar(13)  NOT NULL,
    zone_id                    varchar(4)   NOT NULL,
    zone_description           varchar(30)  NOT NULL,
    payment_method             varchar(3)   NOT NULL,
    payment_description        varchar(35)  NOT NULL,
    positioning_bcn_consulting varchar(250) NULL,
    segmentation_use_1         varchar(250) NULL,
    segmentation_use_2         varchar(250) NULL,
    CONSTRAINT PK_staging_est_atributs_client PRIMARY KEY CLUSTERED (client_locations_id)
);
GO

/* =========================================================================
   est_atributs_producte (WIDE — format KAIS)
   Una fila per producte (art_codi) amb 3 columnes fixes.
   ========================================================================= */
CREATE TABLE dbo.est_atributs_producte (
    art_codi              varchar(16)  NOT NULL,
    subfamily_description varchar(250) NOT NULL,
    units_description     varchar(3)   NOT NULL,
    CONSTRAINT PK_est_atributs_producte PRIMARY KEY CLUSTERED (art_codi)
);
CREATE TABLE staging.est_atributs_producte (
    art_codi              varchar(16)  NOT NULL,
    subfamily_description varchar(250) NOT NULL,
    units_description     varchar(3)   NOT NULL,
    CONSTRAINT PK_staging_est_atributs_producte PRIMARY KEY CLUSTERED (art_codi)
);
GO

/* =========================================================================
   est_cobraments  (renombrat de est_clients_efectes_pendents — format KAIS)
   Efectes pendents de cobrament (OINV no liquidada, ORCT parcial).
   PK uniqueidentifier (KAIS genera GUIDs; nosaltres podem generar-los
   estables amb HASHBYTES sobre DocEntry+InstlmntID per idempotència).
   ========================================================================= */
CREATE TABLE dbo.est_cobraments (
    id_client_location_receivable uniqueidentifier NOT NULL,
    client_locations_id           varchar(13)      NOT NULL,
    net_amount                    decimal(16,6)    NOT NULL,
    issue_date                    datetime         NOT NULL,
    due_date                      datetime         NOT NULL,
    payment_method                varchar(3)       NULL,
    CONSTRAINT PK_est_cobraments PRIMARY KEY CLUSTERED (id_client_location_receivable)
);
CREATE TABLE staging.est_cobraments (
    id_client_location_receivable uniqueidentifier NOT NULL,
    client_locations_id           varchar(13)      NOT NULL,
    net_amount                    decimal(16,6)    NOT NULL,
    issue_date                    datetime         NOT NULL,
    due_date                      datetime         NOT NULL,
    payment_method                varchar(3)       NULL,
    CONSTRAINT PK_staging_est_cobraments PRIMARY KEY CLUSTERED (id_client_location_receivable)
);
GO

/* =========================================================================
   audit.*  -  traçabilitat d'ETL
   ========================================================================= */
IF OBJECT_ID('audit.etl_runs') IS NULL
CREATE TABLE [audit].etl_runs (
    run_id        bigint        IDENTITY(1,1) PRIMARY KEY,
    started_at    datetime2(0)  NOT NULL CONSTRAINT DF_etl_runs_started DEFAULT SYSUTCDATETIME(),
    finished_at   datetime2(0)  NULL,
    [status]      varchar(20)   NOT NULL CONSTRAINT DF_etl_runs_status DEFAULT 'RUNNING',
    error_message nvarchar(max) NULL,
    triggered_by  nvarchar(100) NULL
);
GO

IF OBJECT_ID('audit.etl_step_log') IS NULL
CREATE TABLE [audit].etl_step_log (
    step_id     bigint        IDENTITY(1,1) PRIMARY KEY,
    run_id      bigint        NOT NULL,
    step_name   nvarchar(100) NOT NULL,
    started_at  datetime2(0)  NOT NULL,
    finished_at datetime2(0)  NULL,
    rows_in     bigint        NULL,
    rows_out    bigint        NULL,
    duration_ms int           NULL,
    [status]    varchar(20)   NULL,
    error_message nvarchar(max) NULL
);
GO

IF OBJECT_ID('audit.data_quality_warnings') IS NULL
CREATE TABLE [audit].data_quality_warnings (
    warning_id  bigint        IDENTITY(1,1) PRIMARY KEY,
    run_id      bigint        NOT NULL,
    check_name  nvarchar(100) NOT NULL,
    severity    varchar(10)   NOT NULL,
    details     nvarchar(max) NULL,
    created_at  datetime2(0)  NOT NULL CONSTRAINT DF_dqw_created DEFAULT SYSUTCDATETIME()
);
GO

/* =========================================================================
   cfg.*  -  configuració
   ========================================================================= */
IF OBJECT_ID('cfg.country_code_overrides') IS NULL
CREATE TABLE cfg.country_code_overrides (
    sap_country_code nvarchar(10) NOT NULL PRIMARY KEY,
    iso2_code        char(2)      NOT NULL
);
GO

/* Mapping zona SAP (CRD1.U_SEIZONAC = nom text) -> zone_id numèric estable
   que Analitza consumeix. Poblat via seed_zone_code_mapping.sql.
   Els codis inicials són seqüencials 0001-0047 per ordre alfabètic; poden
   substituir-se pels codis KAIS antics (0011=Girona Poblacions...) quan
   Adrià els proporcioni per preservar continuïtat visual. */
IF OBJECT_ID('cfg.zone_code_mapping') IS NULL
CREATE TABLE cfg.zone_code_mapping (
    zone_name        nvarchar(200) NOT NULL PRIMARY KEY,
    zone_id          varchar(4)    NOT NULL,
    zone_description nvarchar(30)  NOT NULL
);
GO

/* attribute_mapping ja no és útil en aquesta nova versió WIDE — el mapping
   entre UDF SAP i columna KAIS està hardcoded als SPs. Mantenim la taula
   per si en el futur volem parametritzar attributs addicionals opcionals. */
IF OBJECT_ID('cfg.attribute_mapping') IS NULL
CREATE TABLE cfg.attribute_mapping (
    target_table   varchar(20)   NOT NULL,
    udf_column     sysname       NOT NULL,
    attribute_name nvarchar(100) NOT NULL,
    is_active      bit           NOT NULL CONSTRAINT DF_attr_map_active DEFAULT 1,
    CONSTRAINT PK_attribute_mapping PRIMARY KEY (target_table, udf_column)
);
GO

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

IF OBJECT_ID('cfg.settings') IS NULL
CREATE TABLE cfg.settings (
    [key]        nvarchar(100) NOT NULL PRIMARY KEY,
    [value]      nvarchar(400) NOT NULL,
    description  nvarchar(400) NULL
);
GO

/* SBO_DB ja no existeix: des de la migracio a Service Layer, qui apunta a la
   companyia de SAP es ServiceLayer:CompanyDb a la configuracio del Worker.
   S'esborra aqui perque ningu el canvii pensant que encara fa alguna cosa
   (el cutover a PRD de Novembre 2026 es un canvi de config del Worker). */
DELETE FROM cfg.settings WHERE [key] = 'SBO_DB';

IF NOT EXISTS (SELECT 1 FROM cfg.settings WHERE [key] = 'INCREMENTAL_WINDOW_DAYS')
    INSERT cfg.settings ([key], [value], description)
    VALUES ('INCREMENTAL_WINDOW_DAYS', '7', 'Finestra (dies) que re-extreu sp_load_invoice_lines en mode incremental.');

IF NOT EXISTS (SELECT 1 FROM cfg.settings WHERE [key] = 'MIRROR_MAX_AGE_HOURS')
    INSERT cfg.settings ([key], [value], description)
    VALUES ('MIRROR_MAX_AGE_HOURS', '6', 'Antiguitat maxima, en hores, de sap_raw.sync_state perque sp_run_all accepti transformar. El Worker corre com a tasca programada en una altra maquina; sense aquesta guarda, si no s executa, l ETL publicaria el mirall d ahir com si fos d avui.');

IF NOT EXISTS (SELECT 1 FROM cfg.settings WHERE [key] = 'LINES_MIN_RATIO')
    INSERT cfg.settings ([key], [value], description)
    VALUES ('LINES_MIN_RATIO', '0.95', 'Proporcio minima de files que ha de tenir staging.est_linies_albara respecte de dbo abans que el check lines_collapsed aturi el swap. Les linies son historic acumulat i no haurien de minvar. Abaixar-lo expressament nomes si hi ha un canvi previst (p.ex. el cutover, quan SAP productiva arrenca sense historic).');

IF NOT EXISTS (SELECT 1 FROM cfg.settings WHERE [key] = 'ID_DROP_MAX')
    INSERT cfg.settings ([key], [value], description)
    VALUES ('ID_DROP_MAX', '10', 'Identificadors que poden desapareixer d un dia per l altre abans que el check vanished_ids passi de WARN a CRITICAL i aturi el swap. Apujar-lo expressament nomes si hi ha un canvi massiu previst (p.ex. el cutover).');

IF NOT EXISTS (SELECT 1 FROM cfg.settings WHERE [key] = 'ALLOW_DESTRUCTIVE_SCHEMA')
    INSERT cfg.settings ([key], [value], description)
    VALUES ('ALLOW_DESTRUCTIVE_SCHEMA', '0', 'Permis d un sol us per deixar que 01_create_database.sql faci DROP de les dbo.est_* quan ja tenen dades. Normalment no cal: per posar al dia una BD desplegada hi ha schema/04_migracions.sql. El propi script el torna a 0 despres dels DROP.');

/* Convencio del camp discount cap a Analitza. Aixo NO es una preferencia: es
   un canvi coordinat amb ells i del mateix dia del tall.
     '0' = multiplicador (1,00 = sense descompte)  -> el que feia KAIS
     '1' = percentatge   (0,00 = sense descompte)  -> el que diu la seva guia
   Si es posa a '1' i Analitza no treu el seu "1 - discount" el mateix dia, els
   imports els surten a zero. Es una fallada sorollosa a proposit. Veure
   docs/runbook_cutover.md. */
IF NOT EXISTS (SELECT 1 FROM cfg.settings WHERE [key] = 'DISCOUNT_AS_PERCENT')
    INSERT cfg.settings ([key], [value], description)
    VALUES ('DISCOUNT_AS_PERCENT', '0', 'Convencio de est_linies_albara.discount. 0 = multiplicador (KAIS, el que hi ha avui); 1 = percentatge (la guia d Analitza). Nomes es toca el dia del cutover i coordinadament amb Analitza: si ells no treuen el seu 1-discount el mateix dia, els imports surten a zero.');

IF NOT EXISTS (SELECT 1 FROM cfg.settings WHERE [key] = 'DISCOUNT_AS_PERCENT_PUBLISHED')
    INSERT cfg.settings ([key], [value], description)
    VALUES ('DISCOUNT_AS_PERCENT_PUBLISHED', '0', 'Amb quina convencio de discount es va publicar dbo.est_linies_albara per ultim cop. L escriu sp_swap_staging_to_prod dins de la transaccio del swap i NO es toca a ma: si no coincideix amb DISCOUNT_AS_PERCENT, sp_load_invoice_lines forca un FULL en comptes de copiar de dbo linies en l altra convencio.');

/* Quina taxonomia de families va a Analitza.
     '0' = els 110 grups d article de SAP (OITB)        -> el que hi ha avui
     '1' = la familia comercial (OITM.U_SEIFamCialCat)  -> les ~12 que ells ja
           ensenyen, i Analitza recomana no passar de 25
   Mesurat el 16/09/2026 contra l historic de vendes de KAIS: el 98,53% de la
   facturacio passa pels 198 articles que SAP ja te classificats. Els 782
   "sense familia" son recanvis i consumibles que no es venen.
   Posar-lo a '1' fa desapareixer 110 identificadors de cop: vanished_ids
   saltara com a CRITICAL i s ha d apujar ID_DROP_MAX aquell dia. */
IF NOT EXISTS (SELECT 1 FROM cfg.settings WHERE [key] = 'FAMILY_FROM_COMMERCIAL')
    INSERT cfg.settings ([key], [value], description)
    VALUES ('FAMILY_FROM_COMMERCIAL', '0', 'Origen de est_families_productes i de est_productes.product_categories_id. 0 = els 110 grups d article d OITB (el que hi ha avui); 1 = la familia comercial OITM.U_SEIFamCialCat, les 12 que Analitza ensenya. Canviar-lo fa desapareixer 110 identificadors alhora, aixi que vol apujar ID_DROP_MAX el mateix dia i tornar-lo a baixar l endema.');

IF NOT EXISTS (SELECT 1 FROM cfg.settings WHERE [key] = 'HISTORY_FLOOR_ENFORCE')
    INSERT cfg.settings ([key], [value], description)
    VALUES ('HISTORY_FLOOR_ENFORCE', '1', 'Atura el swap si la data mes antiga de staging.est_linies_albara es anterior a la de dbo. Analitza reemplaça el seu historic a partir de la data minima que li enviem, aixi que fer-la retrocedir els esborra dades. Nomes es posa a 0 per a un backfill volgut, i es torna a 1 tot seguit.');

IF NOT EXISTS (SELECT 1 FROM cfg.settings WHERE [key] = 'FULL_RELOAD_WEEKDAY')
    INSERT cfg.settings ([key], [value], description)
    VALUES ('FULL_RELOAD_WEEKDAY', '7', 'Dia de la setmana (1=dilluns..7=diumenge) en que sp_load_invoice_lines fa full reload.');
GO

PRINT 'IntercanviSAP: schemas i taules recreades (format KAIS).';
GO
