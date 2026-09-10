/* =========================================================================
   sap_raw.*  —  Mirall local de SAP Business One

   D'ON VE
   -------
   L'omple SapB1AnalitzaSync.Worker (.NET 8) llegint SAP per Service Layer.
   Cap procés de GAPI07 llegeix taules internes de SAP (Regla 01).

   PER QUÈ ES DIU COM LES TAULES DE SAP
   ------------------------------------
   Les taules i columnes conserven els noms natius de SAP (OCRD.CardCode,
   OITM.ItmsGrpCod, DLN1.PriceBefDi...) i la FORMA nativa: 'Y'/'N' en comptes
   de 'tYES'/'tNO', 'C' en comptes de 'cCustomer'. Així els SPs de l'ETL,
   que ja estaven escrits i validats contra aquesta forma, no s'han
   d'assabentar que l'origen ha canviat: només canvia el prefix del FROM.
   La traducció d'enums de Service Layer viu al Worker (SapEnums) i té tests.

   ABAST
   -----
   NOMÉS les columnes que consumeixen els etl.sp_load_*, més UpdateDate /
   UpdateTime / CancelStatus als documents, que fan falta per al control
   incremental. Això no és una còpia de SAP: és la superfície mínima.

   IDEMPOTENT: es pot executar tantes vegades com calgui.
   ========================================================================= */
USE IntercanviSAP;
GO

IF SCHEMA_ID('sap_raw') IS NULL EXEC ('CREATE SCHEMA sap_raw');
GO

/* =========================================================================
   Mestres — el Worker els refresca SENCERS cada nit (cens + swap atòmic).
   Són prou petits perquè no calgui lògica incremental ni detecció d'esborrats.
   ========================================================================= */

/* OCRD — Business Partners.  SL: BusinessPartners
   El Worker només baixa CardType = 'cCustomer' -> CardType = 'C'. */
IF OBJECT_ID('sap_raw.OCRD') IS NULL
CREATE TABLE sap_raw.OCRD (
    CardCode    nvarchar(15)  NOT NULL,
    CardName    nvarchar(100) NULL,
    CardType    char(1)       NULL,      -- SL BoCardTypes: cCustomer -> 'C'
    validFor    char(1)       NULL,      -- SL Valid:  tYES/tNO -> 'Y'/'N'
    frozenFor   char(1)       NULL,      -- SL Frozen: tYES/tNO -> 'Y'/'N'
    [Address]   nvarchar(100) NULL,
    City        nvarchar(100) NULL,
    ZipCode     nvarchar(20)  NULL,
    Country     nvarchar(3)   NULL,
    SlpCode     smallint      NULL,      -- SL SalesPersonCode; -1 = "sense agent"
    PymCode     nvarchar(15)  NULL,      -- SL PeymentMethodCode (sic, així ho escriu SAP)
    Phone1      nvarchar(20)  NULL,
    E_Mail      nvarchar(100) NULL,
    U_SEIPOSBC  nvarchar(254) NULL,      -- POS. BCN CONSULTING
    U_SEISEGH1  nvarchar(254) NULL,      -- SEGMENT US FARINA 1
    U_SEISEGH2  nvarchar(254) NULL,      -- SEGMENT US FARINA 2
    UpdateDate  datetime      NULL,
    _synced_at  datetime2(3)  NOT NULL CONSTRAINT DF_sap_raw_OCRD_synced DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_sap_raw_OCRD PRIMARY KEY CLUSTERED (CardCode)
);
GO

/* Els UDFs de continuitat amb KAIS es van crear a SAP el 26/08/2026, despres
   que aquest DDL ja estigues desplegat. El CREATE TABLE de dalt no s'executa
   sobre una BD que ja te la taula, aixi que les columnes noves han d'entrar
   per ALTER i cadascuna amb la seva guarda. */
IF COL_LENGTH('sap_raw.OCRD', 'U_FCCodiKais') IS NULL
    ALTER TABLE sap_raw.OCRD ADD U_FCCodiKais nvarchar(50) NULL;   -- codi del client a KAIS
GO
/* El successor per canvi de rao social NO surt d'un camp del projecte: surt de
   U_SEICodienllac, que ja portava la implantacio i que feia exactament aixo. El
   U_FCNewCardCode que es va crear el 26/08/2026 el duplicava; s'ha borrat de SAP
   i la columna se'n va a 04_migracions.sql. */
IF COL_LENGTH('sap_raw.OCRD', 'U_SEICodienllac') IS NULL
    ALTER TABLE sap_raw.OCRD ADD U_SEICodienllac nvarchar(50) NULL; -- enllac al client successor
GO

/* CRD1 — adreces del BP.  SL: BusinessPartners?$expand=BPAddresses
   LineNum ve de BPAddress.RowNum. ATENCIÓ: id_client_location = CardCode-LineNum
   és el contracte amb Analitza (Regla 04); la Fase 0 verifica que RowNum i
   LineNum són el mateix número. */
IF OBJECT_ID('sap_raw.CRD1') IS NULL
CREATE TABLE sap_raw.CRD1 (
    CardCode    nvarchar(15)  NOT NULL,
    LineNum     int           NOT NULL,  -- SL BPAddress.RowNum
    [Address]   nvarchar(50)  NULL,      -- SL AddressName; hi lliga Document.ShipToCode
    Street      nvarchar(100) NULL,
    StreetNo    nvarchar(100) NULL,
    Building    nvarchar(100) NULL,      -- SL BuildingFloorRoom (no hi ha "Building" a SL)
    City        nvarchar(100) NULL,
    ZipCode     nvarchar(20)  NULL,
    Country     nvarchar(3)   NULL,
    AdresType   char(1)       NULL,      -- SL BoAddressType: bo_ShipTo -> 'S', bo_BillTo -> 'B'
    U_SEIZONAC  nvarchar(254) NULL,      -- ZONA (lliga amb cfg.zone_code_mapping)
    _synced_at  datetime2(3)  NOT NULL CONSTRAINT DF_sap_raw_CRD1_synced DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_sap_raw_CRD1 PRIMARY KEY CLUSTERED (CardCode, LineNum)
);
GO

/* Els SPs filtren CRD1 per AdresType='S' i fan servir Address per lligar
   amb el ShipToCode del document. */
IF OBJECT_ID('sap_raw.CRD1') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE object_id = OBJECT_ID('sap_raw.CRD1') AND name = 'IX_sap_raw_CRD1_shipto')
    CREATE NONCLUSTERED INDEX IX_sap_raw_CRD1_shipto
        ON sap_raw.CRD1 (CardCode, AdresType, [Address]) INCLUDE (LineNum);
GO

/* OITM — articles.  SL: Items */
IF OBJECT_ID('sap_raw.OITM') IS NULL
CREATE TABLE sap_raw.OITM (
    ItemCode            nvarchar(50)  NOT NULL,
    ItemName            nvarchar(100) NULL,
    ItmsGrpCod          smallint      NULL,   -- SL ItemsGroupCode
    validFor            char(1)       NULL,
    frozenFor           char(1)       NULL,
    SalUnitMsr          nvarchar(100) NULL,   -- SL SalesUnit ("GRA", "SAC", "UNI", "KG"...)
    U_SEISubFamCialCat  nvarchar(254) NULL,   -- SUBFAMILIA
    UpdateDate          datetime      NULL,
    _synced_at          datetime2(3)  NOT NULL CONSTRAINT DF_sap_raw_OITM_synced DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_sap_raw_OITM PRIMARY KEY CLUSTERED (ItemCode)
);
GO

/* OITB — famílies d'articles.  SL: ItemGroups (Number, GroupName) */
IF OBJECT_ID('sap_raw.OITB') IS NULL
CREATE TABLE sap_raw.OITB (
    ItmsGrpCod  smallint      NOT NULL,
    ItmsGrpNam  nvarchar(100) NULL,
    _synced_at  datetime2(3)  NOT NULL CONSTRAINT DF_sap_raw_OITB_synced DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_sap_raw_OITB PRIMARY KEY CLUSTERED (ItmsGrpCod)
);
GO

/* OSLP — agents comercials.  SL: SalesPersons (SalesEmployeeCode, SalesEmployeeName)
   SlpCode = -1 és "Sense agent" i SAP l'usa com a fallback: es preserva. */
IF OBJECT_ID('sap_raw.OSLP') IS NULL
CREATE TABLE sap_raw.OSLP (
    SlpCode     smallint      NOT NULL,
    SlpName     nvarchar(100) NULL,
    _synced_at  datetime2(3)  NOT NULL CONSTRAINT DF_sap_raw_OSLP_synced DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_sap_raw_OSLP PRIMARY KEY CLUSTERED (SlpCode)
);
GO

/* A OSLP el camp ja existia a SAP abans que el projecte comences (48 de 49
   comercials el porten informat); el que faltava era baixar-lo al mirall. */
IF COL_LENGTH('sap_raw.OSLP', 'U_FCCodiKais') IS NULL
    ALTER TABLE sap_raw.OSLP ADD U_FCCodiKais nvarchar(50) NULL;   -- codi del comercial a KAIS
GO

/* OPYM — formes de pagament.  SL: WizardPaymentMethods (PaymentMethodCode, Description) */
IF OBJECT_ID('sap_raw.OPYM') IS NULL
CREATE TABLE sap_raw.OPYM (
    PayMethCod  nvarchar(15)  NOT NULL,
    Descript    nvarchar(100) NULL,
    _synced_at  datetime2(3)  NOT NULL CONSTRAINT DF_sap_raw_OPYM_synced DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_sap_raw_OPYM PRIMARY KEY CLUSTERED (PayMethCod)
);
GO

/* =========================================================================
   Documents — el Worker els sincronitza INCREMENTALMENT per UpdateDate,
   amb overlap d'un dia i MERGE per DocEntry (Regla 02). El backfill de
   l'històric es fa un sol cop amb --backfill.

   Les tres capçaleres de venda (ODLN/ORDN/ORIN) tenen forma idèntica perquè
   a Service Layer són la mateixa entitat: SAPB1.Document. Per això es creen
   des d'una plantilla en comptes de repetir el DDL tres vegades.
   ========================================================================= */
DECLARE @hdr nvarchar(max) = N'
CREATE TABLE sap_raw.$T$ (
    DocEntry     int           NOT NULL,
    DocNum       int           NULL,
    DocDate      datetime      NULL,
    CardCode     nvarchar(15)  NULL,
    ShipToCode   nvarchar(50)  NULL,   -- lliga amb CRD1.Address
    DiscPrcnt    numeric(19,6) NULL,   -- SL DiscountPercent (descompte de capçalera, %)
    DiscSum      numeric(19,6) NULL,   -- SL TotalDiscount (descompte de capçalera, import)
    DocTotal     numeric(19,6) NULL,
    VatSum       numeric(19,6) NULL,
    Series       int           NULL,
    Comments     nvarchar(max) NULL,
    CancelStatus nvarchar(30)  NULL,   -- per no comptar documents cancel-lats
    UpdateDate   datetime      NULL,
    UpdateTime   time(0)       NULL,
    _synced_at   datetime2(3)  NOT NULL CONSTRAINT DF_sap_raw_$T$_synced DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_sap_raw_$T$ PRIMARY KEY CLUSTERED (DocEntry)
);
CREATE NONCLUSTERED INDEX IX_sap_raw_$T$_upd     ON sap_raw.$T$ (UpdateDate);
CREATE NONCLUSTERED INDEX IX_sap_raw_$T$_docdate ON sap_raw.$T$ (DocDate);';

DECLARE @lin nvarchar(max) = N'
CREATE TABLE sap_raw.$T$ (
    DocEntry    int           NOT NULL,
    LineNum     int           NOT NULL,
    ItemCode    nvarchar(50)  NULL,
    Quantity    numeric(19,6) NULL,
    PriceBefDi  numeric(19,6) NULL,   -- SL UnitPrice: preu unitari ABANS de descompte
    StockPrice  numeric(19,6) NULL,   -- cost de la linia; veure Fase 0 (B2) pel mapatge SL
    DiscPrcnt   numeric(19,6) NULL,   -- SL DiscountPercent de la linia (%)
    LineType    char(1)       NULL,   -- SL BoDocLineType: dlt_Comment -> T (els SPs el filtren)
    _synced_at  datetime2(3)  NOT NULL CONSTRAINT DF_sap_raw_$T$_synced DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_sap_raw_$T$ PRIMARY KEY CLUSTERED (DocEntry, LineNum)
);
CREATE NONCLUSTERED INDEX IX_sap_raw_$T$_item ON sap_raw.$T$ (ItemCode);';

DECLARE @t sysname, @kind char(1), @sql nvarchar(max);

DECLARE tabs CURSOR LOCAL FAST_FORWARD FOR
    SELECT 'ODLN', 'H' UNION ALL SELECT 'ORDN', 'H' UNION ALL SELECT 'ORIN', 'H'
    UNION ALL
    SELECT 'DLN1', 'L' UNION ALL SELECT 'RDN1', 'L' UNION ALL SELECT 'RIN1', 'L';

OPEN tabs;
FETCH NEXT FROM tabs INTO @t, @kind;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF OBJECT_ID('sap_raw.' + @t) IS NULL
    BEGIN
        SET @sql = REPLACE(CASE WHEN @kind = 'H' THEN @hdr ELSE @lin END, '$T$', @t);
        EXEC sp_executesql @sql;
        PRINT 'creada sap_raw.' + @t;
    END
    FETCH NEXT FROM tabs INTO @t, @kind;
END
CLOSE tabs;
DEALLOCATE tabs;
GO

/* OINV — factures de client, per als efectes pendents (est_cobraments).
   Forma diferent de les altres capçaleres: aquí interessen el saldo i el
   venciment, no els descomptes. */
IF OBJECT_ID('sap_raw.OINV') IS NULL
BEGIN
    CREATE TABLE sap_raw.OINV (
        DocEntry     int           NOT NULL,
        DocNum       int           NULL,
        DocDate      datetime      NULL,
        DocDueDate   datetime      NULL,
        CardCode     nvarchar(15)  NULL,
        ShipToCode   nvarchar(50)  NULL,
        DocTotal     numeric(19,6) NULL,
        PaidToDate   numeric(19,6) NULL,
        DocStatus    char(1)       NULL,   -- SL DocumentStatus: bost_Open -> 'O', bost_Close -> 'C'
        PeyMethod    nvarchar(15)  NULL,   -- SL PaymentMethod
        CancelStatus nvarchar(30)  NULL,
        UpdateDate   datetime      NULL,
        UpdateTime   time(0)       NULL,
        _synced_at   datetime2(3)  NOT NULL CONSTRAINT DF_sap_raw_OINV_synced DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_sap_raw_OINV PRIMARY KEY CLUSTERED (DocEntry)
    );
    CREATE NONCLUSTERED INDEX IX_sap_raw_OINV_upd  ON sap_raw.OINV (UpdateDate);
    CREATE NONCLUSTERED INDEX IX_sap_raw_OINV_open ON sap_raw.OINV (DocStatus)
        INCLUDE (CardCode, DocTotal, PaidToDate, DocDueDate);
END
GO

/* =========================================================================
   Estat de sincronització — el checkpoint del Worker.
   Una fila per entitat de Service Layer.
   ========================================================================= */
IF OBJECT_ID('sap_raw.sync_state') IS NULL
CREATE TABLE sap_raw.sync_state (
    entity            varchar(40)  NOT NULL,
    last_update_date  datetime     NULL,      -- cursor: fins on hem llegit per UpdateDate
    last_key          nvarchar(50) NULL,      -- desempat dins del mateix dia
    last_full_at      datetime2(0) NULL,      -- últim cens complet (mestres)
    last_rows         bigint       NULL,
    updated_at        datetime2(0) NOT NULL CONSTRAINT DF_sap_raw_sync_state_upd DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_sap_raw_sync_state PRIMARY KEY CLUSTERED (entity)
);
GO

/* Resum del que hi ha */
SELECT  t.name AS table_name,
        SUM(CASE WHEN p.index_id IN (0, 1) THEN p.[rows] ELSE 0 END) AS [rows]
FROM    sys.tables t
JOIN    sys.partitions p ON p.object_id = t.object_id
WHERE   t.schema_id = SCHEMA_ID('sap_raw')
GROUP BY t.name
ORDER BY t.name;
GO
