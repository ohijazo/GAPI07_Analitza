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
