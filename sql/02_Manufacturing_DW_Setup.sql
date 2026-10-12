/*
================================================================================
FILE: 02_Manufacturing_DW_Setup.sql
PROJECT: Automotive Components Manufacturing & Supply Chain Analytics
DATABASE: Manufacturing_DW
PURPOSE: Data warehouse structure -- raw / stg / mart / etl schemas

SOURCE OF TRUTH FOR THIS FILE
------------------------------
Column names/types here are derived directly from
Manufacturing_Supply_Chain_DW_BI\sql\01_Manufacturing_Source_Initial_Setup.sql
(the live Manufacturing_Source contract). If that file changes, the raw layer
below must be updated to match, or the raw-load procedures in
03_ETL_StoredProcedures.sql will fail loudly (by design -- see that file).

LAYER NAMING (corrected from the original planning doc's stg/dw/mart/etl)
---------------------------------------------------------------------------
    raw   source-shaped, as-is extract from Manufacturing_Source, tagged with
          BatchID/LoadDateTime. One row per source PK, upserted -- not an
          append-only log. No FKs enforced here on purpose: each raw table
          loads independently, in any order, without fragile load-order
          dependencies between tables.

    stg   cleaned / validated / conformed. Same grain as raw (1:1 with
          source rows), light standardization (trimmed strings, defensive
          NULL handling) plus real data-quality checks (orphan FK checks,
          business-rule reconciliation). Rows that fail validation are
          logged to etl.RejectedRows and excluded -- they do not reach stg.
          Cross-table business calculations (supplier delay days, delivery
          status, inventory value, etc.) are NOT computed here; they belong
          in mart, where the joins that produce them naturally happen.

    mart  final dimensional model. Power BI connects only here. Conformed
          dimensions (mart.Dim*) + fact tables (mart.Fact*) with the
          business calculations from README section 12 baked in at load
          time by 03_ETL_StoredProcedures.sql.

    etl   pipeline control layer, off to the side -- not a data stage.
          etl.LoadControl (per-source-table watermark), etl.BatchRun
          (one row per ETL run), etl.BatchAudit (one row per table per
          run), etl.RejectedRows (rejected-row log).

WHY MANUFACTURING_SOURCE IS NEVER CALLED "raw"
-------------------------------------------------
Manufacturing_Source is a separate live OLTP system that Manufacturing_DW
extracts FROM. It is not a layer inside the warehouse. Both databases live
on the same SQL Server instance, so the raw-load procedures can simply use
three-part names (Manufacturing_Source.dbo.<Table>) -- no linked server
needed.

SCD STRATEGY
------------
mart.DimSupplier is Type 2 (EffectiveStartDateTime/EffectiveEndDateTime/
IsCurrent) because SupplierTier/SupplierStatus/SupplierRisk are the columns
the source's periodic supplier review actually mutates
(generators/incremental_update.py: mutate_supplier_attributes) -- a real
reason to version, not versioning for its own sake. Every other dimension
(Product, Customer, Warehouse, Carrier) is Type 1 (overwrite-in-place):
nothing in this project's source generator produces a business reason to
track their history, so tracking it would be complexity with no payoff.

HINGLISH:
Yeh dusra DDL file hai -- ab tak sirf source (Manufacturing_Source) tha, ab
warehouse (Manufacturing_DW) ban raha hai. Chaar schemas: raw (jaisa-hai-
waisa extract), stg (saaf/validate kiya hua), mart (Power BI ke liye final
star schema), aur etl (control/audit layer, data stage nahi).
================================================================================
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


/*==============================================================================
  STEP 1 - CREATE DATABASE
==============================================================================*/

USE master;
GO

IF DB_ID(N'Manufacturing_DW') IS NULL
BEGIN
    PRINT 'Creating database Manufacturing_DW...';
    CREATE DATABASE Manufacturing_DW;
END
ELSE
BEGIN
    PRINT 'Manufacturing_DW already exists. Database creation skipped.';
END;
GO

USE Manufacturing_DW;
GO


/*==============================================================================
  STEP 2 - SCHEMAS
==============================================================================*/

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'raw')
    EXEC('CREATE SCHEMA raw AUTHORIZATION dbo');
GO
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'stg')
    EXEC('CREATE SCHEMA stg AUTHORIZATION dbo');
GO
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'mart')
    EXEC('CREATE SCHEMA mart AUTHORIZATION dbo');
GO
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'etl')
    EXEC('CREATE SCHEMA etl AUTHORIZATION dbo');
GO


/*==============================================================================
  STEP 3 - ETL CONTROL LAYER
  Created first because the raw/stg load procedures in the next SQL file
  depend on these tables existing.
==============================================================================*/

/*------------------------------------------------------------------------------
  3.1 etl.BatchRun -- one row per end-to-end etl.usp_RunFullETL execution.
------------------------------------------------------------------------------*/
IF OBJECT_ID(N'etl.BatchRun', N'U') IS NULL
BEGIN
    CREATE TABLE etl.BatchRun
    (
        BatchID              BIGINT IDENTITY(1,1) NOT NULL,
        StartDateTime         DATETIME2(0)   NOT NULL CONSTRAINT DF_BatchRun_Start DEFAULT (SYSDATETIME()),
        EndDateTime            DATETIME2(0)   NULL,
        Status                  VARCHAR(20)    NOT NULL CONSTRAINT DF_BatchRun_Status DEFAULT ('Running'),
        TriggeredBy              VARCHAR(80)    NOT NULL CONSTRAINT DF_BatchRun_TriggeredBy DEFAULT (SUSER_SNAME()),
        ErrorMessage              VARCHAR(4000)  NULL,

        CONSTRAINT PK_BatchRun PRIMARY KEY (BatchID),
        CONSTRAINT CK_BatchRun_Status CHECK (Status IN ('Running','Succeeded','Failed'))
    );
    PRINT 'Created etl.BatchRun';
END;
GO

/*------------------------------------------------------------------------------
  3.2 etl.BatchAudit -- one row per (BatchID, LayerName, TableName) load step.
------------------------------------------------------------------------------*/
IF OBJECT_ID(N'etl.BatchAudit', N'U') IS NULL
BEGIN
    CREATE TABLE etl.BatchAudit
    (
        BatchStepID           BIGINT IDENTITY(1,1) NOT NULL,
        BatchID                BIGINT         NOT NULL,
        LayerName               VARCHAR(10)    NOT NULL,
        TableName                VARCHAR(60)    NOT NULL,
        StartDateTime             DATETIME2(0)   NOT NULL CONSTRAINT DF_BatchAudit_Start DEFAULT (SYSDATETIME()),
        EndDateTime                DATETIME2(0)   NULL,
        SourceRowCount              INT            NULL,
        TargetRowCount              INT            NULL,
        RejectedRowCount            INT            NOT NULL CONSTRAINT DF_BatchAudit_Rejected DEFAULT (0),
        Status                      VARCHAR(20)    NOT NULL CONSTRAINT DF_BatchAudit_Status DEFAULT ('Running'),
        ErrorMessage                VARCHAR(4000)  NULL,

        CONSTRAINT PK_BatchAudit PRIMARY KEY (BatchStepID),
        CONSTRAINT FK_BatchAudit_BatchRun FOREIGN KEY (BatchID) REFERENCES etl.BatchRun(BatchID),
        CONSTRAINT CK_BatchAudit_Layer CHECK (LayerName IN ('raw','stg','mart')),
        CONSTRAINT CK_BatchAudit_Status CHECK (Status IN ('Running','Succeeded','Failed'))
    );
    CREATE INDEX IX_BatchAudit_BatchID ON etl.BatchAudit(BatchID);
    PRINT 'Created etl.BatchAudit';
END;
GO

/*------------------------------------------------------------------------------
  3.3 etl.LoadControl -- one row per source table, the incremental watermark.
------------------------------------------------------------------------------*/
IF OBJECT_ID(N'etl.LoadControl', N'U') IS NULL
BEGIN
    CREATE TABLE etl.LoadControl
    (
        TableName                   VARCHAR(60)    NOT NULL,
        LastLoadedModifiedDateTime   DATETIME2(0)   NOT NULL CONSTRAINT DF_LoadControl_Watermark DEFAULT ('1900-01-01'),
        LastBatchID                   BIGINT         NULL,
        UpdatedDateTime                DATETIME2(0)   NOT NULL CONSTRAINT DF_LoadControl_Updated DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_LoadControl PRIMARY KEY (TableName)
    );
    PRINT 'Created etl.LoadControl';
END;
GO

/*------------------------------------------------------------------------------
  3.4 etl.RejectedRows -- one row per rejected source row per load step.
------------------------------------------------------------------------------*/
IF OBJECT_ID(N'etl.RejectedRows', N'U') IS NULL
BEGIN
    CREATE TABLE etl.RejectedRows
    (
        RejectID                 BIGINT IDENTITY(1,1) NOT NULL,
        BatchID                   BIGINT         NOT NULL,
        LayerName                  VARCHAR(10)    NOT NULL,
        TableName                   VARCHAR(60)    NOT NULL,
        SourceKeyValue                VARCHAR(100)   NOT NULL,
        RejectReason                  VARCHAR(500)   NOT NULL,
        RejectedDateTime               DATETIME2(0)   NOT NULL CONSTRAINT DF_RejectedRows_When DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_RejectedRows PRIMARY KEY (RejectID),
        CONSTRAINT FK_RejectedRows_BatchRun FOREIGN KEY (BatchID) REFERENCES etl.BatchRun(BatchID)
    );
    CREATE INDEX IX_RejectedRows_BatchID ON etl.RejectedRows(BatchID);
    PRINT 'Created etl.RejectedRows';
END;
GO


/*==============================================================================
  STEP 4 - RAW LAYER (13 tables, source-shaped, upsert-by-PK)
  Every table adds: BatchID BIGINT (last batch that touched the row) and
  LoadDateTime DATETIME2(0) (when that batch touched it). Source
  CreatedDateTime/ModifiedDateTime are renamed SourceCreatedDateTime /
  SourceModifiedDateTime here to avoid ambiguity with the warehouse's own
  batch timestamps.
==============================================================================*/

IF OBJECT_ID(N'raw.Product', N'U') IS NULL
BEGIN
    CREATE TABLE raw.Product
    (
        ProductID               VARCHAR(20)    NOT NULL,
        SKU                     VARCHAR(30)    NOT NULL,
        ProductName             VARCHAR(150)   NOT NULL,
        Category                VARCHAR(60)    NOT NULL,
        Subcategory              VARCHAR(60)    NOT NULL,
        ProductType               VARCHAR(30)    NOT NULL,
        MakeBuyType                VARCHAR(10)    NOT NULL,
        VehicleSegment              VARCHAR(40)    NOT NULL,
        UnitOfMeasure                 VARCHAR(10)    NOT NULL,
        ABCClass                        CHAR(1)        NOT NULL,
        StandardCost                      DECIMAL(18,2)  NOT NULL,
        ListPrice                           DECIMAL(18,2)  NULL,
        SafetyStockQuantity                    INT            NOT NULL,
        ReorderLevel                             INT            NOT NULL,
        MaximumStockQuantity                       INT            NOT NULL,
        ProductStatus                                VARCHAR(20)    NOT NULL,
        LaunchDate                                     DATE           NULL,
        DiscontinuedDate                                 DATE           NULL,
        ImageURL                                           VARCHAR(500)   NULL,
        ActiveFlag                                           BIT            NOT NULL,
        SourceCreatedDateTime                                  DATETIME2(0)   NOT NULL,
        SourceModifiedDateTime                                   DATETIME2(0)   NOT NULL,
        BatchID                                                    BIGINT         NOT NULL,
        LoadDateTime                                                 DATETIME2(0)   NOT NULL CONSTRAINT DF_rawProduct_Load DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_raw_Product PRIMARY KEY (ProductID)
    );
    PRINT 'Created raw.Product';
END;
GO

IF OBJECT_ID(N'raw.Supplier', N'U') IS NULL
BEGIN
    CREATE TABLE raw.Supplier
    (
        SupplierID              VARCHAR(20)    NOT NULL,
        SupplierName             VARCHAR(150)   NOT NULL,
        SupplierCategory           VARCHAR(50)    NOT NULL,
        SupplierTier                 VARCHAR(30)    NOT NULL,
        SupplierStatus                 VARCHAR(20)    NOT NULL,
        SupplierRisk                     VARCHAR(10)    NOT NULL,
        CriticalSupplierFlag               BIT            NOT NULL,
        StandardLeadTimeDays                 INT            NOT NULL,
        PaymentTermsDays                       INT            NOT NULL,
        Region                                   VARCHAR(30)    NOT NULL,
        Country                                    VARCHAR(60)    NOT NULL,
        StateProvince                                VARCHAR(60)    NOT NULL,
        City                                            VARCHAR(60)    NOT NULL,
        CountryCode                                       CHAR(2)        NOT NULL,
        ActiveFlag                                          BIT            NOT NULL,
        SourceCreatedDateTime                                 DATETIME2(0)   NOT NULL,
        SourceModifiedDateTime                                  DATETIME2(0)   NOT NULL,
        BatchID                                                   BIGINT         NOT NULL,
        LoadDateTime                                                DATETIME2(0)   NOT NULL CONSTRAINT DF_rawSupplier_Load DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_raw_Supplier PRIMARY KEY (SupplierID)
    );
    PRINT 'Created raw.Supplier';
END;
GO

IF OBJECT_ID(N'raw.Customer', N'U') IS NULL
BEGIN
    CREATE TABLE raw.Customer
    (
        CustomerID               VARCHAR(20)    NOT NULL,
        CustomerName               VARCHAR(150)   NOT NULL,
        CustomerType                  VARCHAR(40)    NOT NULL,
        CustomerSegment                 VARCHAR(20)    NOT NULL,
        CreditTermsDays                   INT            NOT NULL,
        Region                              VARCHAR(30)    NOT NULL,
        Country                               VARCHAR(60)    NOT NULL,
        StateProvince                           VARCHAR(60)    NOT NULL,
        City                                       VARCHAR(60)    NOT NULL,
        CountryCode                                  CHAR(2)        NOT NULL,
        ActiveFlag                                     BIT            NOT NULL,
        SourceCreatedDateTime                            DATETIME2(0)   NOT NULL,
        SourceModifiedDateTime                             DATETIME2(0)   NOT NULL,
        BatchID                                              BIGINT         NOT NULL,
        LoadDateTime                                           DATETIME2(0)   NOT NULL CONSTRAINT DF_rawCustomer_Load DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_raw_Customer PRIMARY KEY (CustomerID)
    );
    PRINT 'Created raw.Customer';
END;
GO

IF OBJECT_ID(N'raw.Warehouse', N'U') IS NULL
BEGIN
    CREATE TABLE raw.Warehouse
    (
        WarehouseID              VARCHAR(20)    NOT NULL,
        WarehouseName              VARCHAR(120)   NOT NULL,
        WarehouseType                 VARCHAR(30)    NOT NULL,
        Region                          VARCHAR(30)    NOT NULL,
        Country                           VARCHAR(60)    NOT NULL,
        StateProvince                       VARCHAR(60)    NOT NULL,
        City                                   VARCHAR(60)    NOT NULL,
        CountryCode                              CHAR(2)        NOT NULL,
        CapacityUnits                              INT            NOT NULL,
        ActiveFlag                                   BIT            NOT NULL,
        SourceCreatedDateTime                          DATETIME2(0)   NOT NULL,
        SourceModifiedDateTime                           DATETIME2(0)   NOT NULL,
        BatchID                                            BIGINT         NOT NULL,
        LoadDateTime                                         DATETIME2(0)   NOT NULL CONSTRAINT DF_rawWarehouse_Load DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_raw_Warehouse PRIMARY KEY (WarehouseID)
    );
    PRINT 'Created raw.Warehouse';
END;
GO

IF OBJECT_ID(N'raw.Carrier', N'U') IS NULL
BEGIN
    CREATE TABLE raw.Carrier
    (
        CarrierID                VARCHAR(20)    NOT NULL,
        CarrierName                 VARCHAR(120)   NOT NULL,
        CarrierType                    VARCHAR(20)    NOT NULL,
        ServiceLevel                      VARCHAR(20)    NOT NULL,
        Coverage                             VARCHAR(20)    NOT NULL,
        CarrierRating                           VARCHAR(20)    NOT NULL,
        ContractType                               VARCHAR(30)    NOT NULL,
        PrimaryRegion                                 VARCHAR(30)    NOT NULL,
        ActiveFlag                                      BIT            NOT NULL,
        SourceCreatedDateTime                             DATETIME2(0)   NOT NULL,
        SourceModifiedDateTime                              DATETIME2(0)   NOT NULL,
        BatchID                                               BIGINT         NOT NULL,
        LoadDateTime                                            DATETIME2(0)   NOT NULL CONSTRAINT DF_rawCarrier_Load DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_raw_Carrier PRIMARY KEY (CarrierID)
    );
    PRINT 'Created raw.Carrier';
END;
GO

IF OBJECT_ID(N'raw.PurchaseOrder', N'U') IS NULL
BEGIN
    CREATE TABLE raw.PurchaseOrder
    (
        PurchaseOrderID            VARCHAR(30)    NOT NULL,
        SupplierID                   VARCHAR(20)    NOT NULL,
        DeliveryWarehouseID             VARCHAR(20)    NOT NULL,
        OrderDate                          DATE           NOT NULL,
        RequestedDeliveryDate                 DATE           NOT NULL,
        PromisedDeliveryDate                     DATE           NOT NULL,
        PurchaseType                                VARCHAR(30)    NOT NULL,
        Priority                                       VARCHAR(20)    NOT NULL,
        CurrencyCode                                     CHAR(3)        NOT NULL,
        POStatus                                           VARCHAR(30)    NOT NULL,
        BuyerGroup                                           VARCHAR(40)    NOT NULL,
        SourceCreatedDateTime                                  DATETIME2(0)   NOT NULL,
        SourceModifiedDateTime                                   DATETIME2(0)   NOT NULL,
        BatchID                                                    BIGINT         NOT NULL,
        LoadDateTime                                                 DATETIME2(0)   NOT NULL CONSTRAINT DF_rawPO_Load DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_raw_PurchaseOrder PRIMARY KEY (PurchaseOrderID)
    );
    PRINT 'Created raw.PurchaseOrder';
END;
GO

IF OBJECT_ID(N'raw.PurchaseOrderLine', N'U') IS NULL
BEGIN
    CREATE TABLE raw.PurchaseOrderLine
    (
        PurchaseOrderLineID         VARCHAR(40)    NOT NULL,
        PurchaseOrderID                VARCHAR(30)    NOT NULL,
        ProductID                         VARCHAR(20)    NOT NULL,
        OrderedQuantity                      INT            NOT NULL,
        ReceivedQuantity                        INT            NOT NULL,
        OpenQuantity                               INT            NOT NULL,
        UnitCost                                      DECIMAL(18,2)  NOT NULL,
        LineAmount                                       DECIMAL(18,2)  NOT NULL,
        LineStatus                                          VARCHAR(30)    NOT NULL,
        SourceCreatedDateTime                                 DATETIME2(0)   NOT NULL,
        SourceModifiedDateTime                                  DATETIME2(0)   NOT NULL,
        BatchID                                                   BIGINT         NOT NULL,
        LoadDateTime                                                DATETIME2(0)   NOT NULL CONSTRAINT DF_rawPOL_Load DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_raw_PurchaseOrderLine PRIMARY KEY (PurchaseOrderLineID)
    );
    PRINT 'Created raw.PurchaseOrderLine';
END;
GO

/*------------------------------------------------------------------------------
  raw.GoodsReceipt: source table has no ModifiedDateTime (it is an immutable
  receipt event, never updated after insert) -- watermark uses CreatedDateTime.
------------------------------------------------------------------------------*/
IF OBJECT_ID(N'raw.GoodsReceipt', N'U') IS NULL
BEGIN
    CREATE TABLE raw.GoodsReceipt
    (
        GoodsReceiptID              VARCHAR(30)    NOT NULL,
        PurchaseOrderLineID            VARCHAR(40)    NOT NULL,
        ProductID                         VARCHAR(20)    NOT NULL,
        WarehouseID                          VARCHAR(20)    NOT NULL,
        ReceiptDateTime                         DATETIME2(0)   NOT NULL,
        PhysicalReceivedQuantity                   INT            NOT NULL,
        AcceptedQuantity                              INT            NOT NULL,
        RejectedQuantity                                 INT            NOT NULL,
        ReceiptStatus                                       VARCHAR(40)    NOT NULL,
        ReceiptSource                                          VARCHAR(40)    NOT NULL,
        SourceCreatedDateTime                                    DATETIME2(0)   NOT NULL,
        BatchID                                                    BIGINT         NOT NULL,
        LoadDateTime                                                 DATETIME2(0)   NOT NULL CONSTRAINT DF_rawGR_Load DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_raw_GoodsReceipt PRIMARY KEY (GoodsReceiptID)
    );
    PRINT 'Created raw.GoodsReceipt';
END;
GO

/*------------------------------------------------------------------------------
  raw.InventoryBalance: source table has no CreatedDateTime (current-state
  snapshot only) -- watermark uses ModifiedDateTime as usual.
------------------------------------------------------------------------------*/
IF OBJECT_ID(N'raw.InventoryBalance', N'U') IS NULL
BEGIN
    CREATE TABLE raw.InventoryBalance
    (
        ProductID                VARCHAR(20)    NOT NULL,
        WarehouseID                 VARCHAR(20)    NOT NULL,
        OnHandQuantity                 INT            NOT NULL,
        ReservedQuantity                   INT            NOT NULL,
        AvailableQuantity                     INT            NOT NULL,
        InTransitQuantity                        INT            NOT NULL,
        AverageUnitCost                             DECIMAL(18,2)  NOT NULL,
        LastMovementDateTime                           DATETIME2(0)   NOT NULL,
        SourceModifiedDateTime                            DATETIME2(0)   NOT NULL,
        BatchID                                             BIGINT         NOT NULL,
        LoadDateTime                                          DATETIME2(0)   NOT NULL CONSTRAINT DF_rawInvBal_Load DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_raw_InventoryBalance PRIMARY KEY (ProductID, WarehouseID)
    );
    PRINT 'Created raw.InventoryBalance';
END;
GO

IF OBJECT_ID(N'raw.SalesOrder', N'U') IS NULL
BEGIN
    CREATE TABLE raw.SalesOrder
    (
        SalesOrderID               VARCHAR(30)    NOT NULL,
        CustomerID                    VARCHAR(20)    NOT NULL,
        OrderDate                        DATE           NOT NULL,
        RequestedDeliveryDate                DATE           NOT NULL,
        Priority                                VARCHAR(20)    NOT NULL,
        CurrencyCode                               CHAR(3)        NOT NULL,
        OrderStatus                                   VARCHAR(30)    NOT NULL,
        OrderType                                        VARCHAR(30)    NOT NULL,
        SalesChannel                                        VARCHAR(30)    NOT NULL,
        SourceCreatedDateTime                                 DATETIME2(0)   NOT NULL,
        SourceModifiedDateTime                                  DATETIME2(0)   NOT NULL,
        BatchID                                                   BIGINT         NOT NULL,
        LoadDateTime                                                DATETIME2(0)   NOT NULL CONSTRAINT DF_rawSO_Load DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_raw_SalesOrder PRIMARY KEY (SalesOrderID)
    );
    PRINT 'Created raw.SalesOrder';
END;
GO

IF OBJECT_ID(N'raw.SalesOrderLine', N'U') IS NULL
BEGIN
    CREATE TABLE raw.SalesOrderLine
    (
        SalesOrderLineID            VARCHAR(40)    NOT NULL,
        SalesOrderID                   VARCHAR(30)    NOT NULL,
        ProductID                         VARCHAR(20)    NOT NULL,
        FulfillmentWarehouseID                VARCHAR(20)    NOT NULL,
        PromisedDeliveryDate                     DATE           NOT NULL,
        OrderQuantity                               INT            NOT NULL,
        FulfilledQuantity                              INT            NOT NULL,
        BackorderQuantity                                 INT            NOT NULL,
        UnitPrice                                            DECIMAL(18,2)  NOT NULL,
        GrossLineAmount                                         DECIMAL(18,2)  NOT NULL,
        DiscountAmount                                             DECIMAL(18,2)  NOT NULL,
        NetLineAmount                                                 DECIMAL(18,2)  NOT NULL,
        LineStatus                                                       VARCHAR(30)    NOT NULL,
        SourceCreatedDateTime                                              DATETIME2(0)   NOT NULL,
        SourceModifiedDateTime                                               DATETIME2(0)   NOT NULL,
        BatchID                                                                BIGINT         NOT NULL,
        LoadDateTime                                                             DATETIME2(0)   NOT NULL CONSTRAINT DF_rawSOL_Load DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_raw_SalesOrderLine PRIMARY KEY (SalesOrderLineID)
    );
    PRINT 'Created raw.SalesOrderLine';
END;
GO

IF OBJECT_ID(N'raw.Shipment', N'U') IS NULL
BEGIN
    CREATE TABLE raw.Shipment
    (
        ShipmentID                  VARCHAR(30)    NOT NULL,
        SalesOrderID                   VARCHAR(30)    NOT NULL,
        CarrierID                         VARCHAR(20)    NOT NULL,
        OriginWarehouseID                    VARCHAR(20)    NOT NULL,
        ShipmentDate                            DATE           NOT NULL,
        PromisedDeliveryDate                       DATE           NOT NULL,
        ActualDeliveryDate                            DATE           NULL,
        ShipmentStatus                                   VARCHAR(30)    NOT NULL,
        ShipmentMode                                        VARCHAR(20)    NOT NULL,
        ServiceLevel                                           VARCHAR(20)    NOT NULL,
        DestinationRegion                                         VARCHAR(30)    NOT NULL,
        DestinationCountry                                           VARCHAR(60)    NOT NULL,
        DestinationStateProvince                                        VARCHAR(60)    NOT NULL,
        DestinationCity                                                    VARCHAR(60)    NOT NULL,
        DestinationCountryCode                                                CHAR(2)        NOT NULL,
        ShippingCost                                                             DECIMAL(18,2)  NOT NULL,
        ReturnFlag                                                                  BIT            NOT NULL,
        ReturnReason                                                                   VARCHAR(40)    NOT NULL,
        SourceCreatedDateTime                                                             DATETIME2(0)   NOT NULL,
        SourceModifiedDateTime                                                               DATETIME2(0)   NOT NULL,
        BatchID                                                                                BIGINT         NOT NULL,
        LoadDateTime                                                                              DATETIME2(0)   NOT NULL CONSTRAINT DF_rawShipment_Load DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_raw_Shipment PRIMARY KEY (ShipmentID)
    );
    PRINT 'Created raw.Shipment';
END;
GO

IF OBJECT_ID(N'raw.ShipmentLine', N'U') IS NULL
BEGIN
    CREATE TABLE raw.ShipmentLine
    (
        ShipmentLineID              VARCHAR(40)    NOT NULL,
        ShipmentID                     VARCHAR(30)    NOT NULL,
        SalesOrderLineID                  VARCHAR(40)    NOT NULL,
        ProductID                            VARCHAR(20)    NOT NULL,
        ShippedQuantity                         INT            NOT NULL,
        ReceivedQuantity                           INT            NULL,
        SourceCreatedDateTime                         DATETIME2(0)   NOT NULL,
        SourceModifiedDateTime                           DATETIME2(0)   NOT NULL,
        BatchID                                            BIGINT         NOT NULL,
        LoadDateTime                                         DATETIME2(0)   NOT NULL CONSTRAINT DF_rawShipLine_Load DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_raw_ShipmentLine PRIMARY KEY (ShipmentLineID)
    );
    PRINT 'Created raw.ShipmentLine';
END;
GO


/*==============================================================================
  STEP 5 - STG LAYER (13 tables, same grain as raw, cleaned/validated)
  Structurally identical to raw -- the stg-load procedures are what add the
  value (orphan-FK checks, business-rule reconciliation, trimming). DDL is
  kept lean: PK only, no FKs (a late-arriving parent row must not block an
  otherwise-valid child row from loading; the stg-load procedure's orphan
  check is the real gate, not a DB constraint that would abort the batch).
==============================================================================*/

IF OBJECT_ID(N'stg.Product', N'U') IS NULL
BEGIN
    CREATE TABLE stg.Product
    (
        ProductID VARCHAR(20) NOT NULL, SKU VARCHAR(30) NOT NULL, ProductName VARCHAR(150) NOT NULL,
        Category VARCHAR(60) NOT NULL, Subcategory VARCHAR(60) NOT NULL, ProductType VARCHAR(30) NOT NULL,
        MakeBuyType VARCHAR(10) NOT NULL, VehicleSegment VARCHAR(40) NOT NULL, UnitOfMeasure VARCHAR(10) NOT NULL,
        ABCClass CHAR(1) NOT NULL, StandardCost DECIMAL(18,2) NOT NULL, ListPrice DECIMAL(18,2) NULL,
        SafetyStockQuantity INT NOT NULL, ReorderLevel INT NOT NULL, MaximumStockQuantity INT NOT NULL,
        ProductStatus VARCHAR(20) NOT NULL, LaunchDate DATE NULL, DiscontinuedDate DATE NULL,
        ActiveFlag BIT NOT NULL, SourceCreatedDateTime DATETIME2(0) NOT NULL, SourceModifiedDateTime DATETIME2(0) NOT NULL,
        BatchID BIGINT NOT NULL, LoadDateTime DATETIME2(0) NOT NULL CONSTRAINT DF_stgProduct_Load DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_stg_Product PRIMARY KEY (ProductID)
    );
    PRINT 'Created stg.Product';
END;
GO

IF OBJECT_ID(N'stg.Supplier', N'U') IS NULL
BEGIN
    CREATE TABLE stg.Supplier
    (
        SupplierID VARCHAR(20) NOT NULL, SupplierName VARCHAR(150) NOT NULL, SupplierCategory VARCHAR(50) NOT NULL,
        SupplierTier VARCHAR(30) NOT NULL, SupplierStatus VARCHAR(20) NOT NULL, SupplierRisk VARCHAR(10) NOT NULL,
        CriticalSupplierFlag BIT NOT NULL, StandardLeadTimeDays INT NOT NULL, PaymentTermsDays INT NOT NULL,
        Region VARCHAR(30) NOT NULL, Country VARCHAR(60) NOT NULL, StateProvince VARCHAR(60) NOT NULL,
        City VARCHAR(60) NOT NULL, CountryCode CHAR(2) NOT NULL, ActiveFlag BIT NOT NULL,
        SourceCreatedDateTime DATETIME2(0) NOT NULL, SourceModifiedDateTime DATETIME2(0) NOT NULL,
        BatchID BIGINT NOT NULL, LoadDateTime DATETIME2(0) NOT NULL CONSTRAINT DF_stgSupplier_Load DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_stg_Supplier PRIMARY KEY (SupplierID)
    );
    PRINT 'Created stg.Supplier';
END;
GO

IF OBJECT_ID(N'stg.Customer', N'U') IS NULL
BEGIN
    CREATE TABLE stg.Customer
    (
        CustomerID VARCHAR(20) NOT NULL, CustomerName VARCHAR(150) NOT NULL, CustomerType VARCHAR(40) NOT NULL,
        CustomerSegment VARCHAR(20) NOT NULL, CreditTermsDays INT NOT NULL, Region VARCHAR(30) NOT NULL,
        Country VARCHAR(60) NOT NULL, StateProvince VARCHAR(60) NOT NULL, City VARCHAR(60) NOT NULL,
        CountryCode CHAR(2) NOT NULL, ActiveFlag BIT NOT NULL,
        SourceCreatedDateTime DATETIME2(0) NOT NULL, SourceModifiedDateTime DATETIME2(0) NOT NULL,
        BatchID BIGINT NOT NULL, LoadDateTime DATETIME2(0) NOT NULL CONSTRAINT DF_stgCustomer_Load DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_stg_Customer PRIMARY KEY (CustomerID)
    );
    PRINT 'Created stg.Customer';
END;
GO

IF OBJECT_ID(N'stg.Warehouse', N'U') IS NULL
BEGIN
    CREATE TABLE stg.Warehouse
    (
        WarehouseID VARCHAR(20) NOT NULL, WarehouseName VARCHAR(120) NOT NULL, WarehouseType VARCHAR(30) NOT NULL,
        Region VARCHAR(30) NOT NULL, Country VARCHAR(60) NOT NULL, StateProvince VARCHAR(60) NOT NULL,
        City VARCHAR(60) NOT NULL, CountryCode CHAR(2) NOT NULL, CapacityUnits INT NOT NULL, ActiveFlag BIT NOT NULL,
        SourceCreatedDateTime DATETIME2(0) NOT NULL, SourceModifiedDateTime DATETIME2(0) NOT NULL,
        BatchID BIGINT NOT NULL, LoadDateTime DATETIME2(0) NOT NULL CONSTRAINT DF_stgWarehouse_Load DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_stg_Warehouse PRIMARY KEY (WarehouseID)
    );
    PRINT 'Created stg.Warehouse';
END;
GO

IF OBJECT_ID(N'stg.Carrier', N'U') IS NULL
BEGIN
    CREATE TABLE stg.Carrier
    (
        CarrierID VARCHAR(20) NOT NULL, CarrierName VARCHAR(120) NOT NULL, CarrierType VARCHAR(20) NOT NULL,
        ServiceLevel VARCHAR(20) NOT NULL, Coverage VARCHAR(20) NOT NULL, CarrierRating VARCHAR(20) NOT NULL,
        ContractType VARCHAR(30) NOT NULL, PrimaryRegion VARCHAR(30) NOT NULL, ActiveFlag BIT NOT NULL,
        SourceCreatedDateTime DATETIME2(0) NOT NULL, SourceModifiedDateTime DATETIME2(0) NOT NULL,
        BatchID BIGINT NOT NULL, LoadDateTime DATETIME2(0) NOT NULL CONSTRAINT DF_stgCarrier_Load DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_stg_Carrier PRIMARY KEY (CarrierID)
    );
    PRINT 'Created stg.Carrier';
END;
GO

IF OBJECT_ID(N'stg.PurchaseOrder', N'U') IS NULL
BEGIN
    CREATE TABLE stg.PurchaseOrder
    (
        PurchaseOrderID VARCHAR(30) NOT NULL, SupplierID VARCHAR(20) NOT NULL, DeliveryWarehouseID VARCHAR(20) NOT NULL,
        OrderDate DATE NOT NULL, RequestedDeliveryDate DATE NOT NULL, PromisedDeliveryDate DATE NOT NULL,
        PurchaseType VARCHAR(30) NOT NULL, Priority VARCHAR(20) NOT NULL, CurrencyCode CHAR(3) NOT NULL,
        POStatus VARCHAR(30) NOT NULL, BuyerGroup VARCHAR(40) NOT NULL,
        SourceCreatedDateTime DATETIME2(0) NOT NULL, SourceModifiedDateTime DATETIME2(0) NOT NULL,
        BatchID BIGINT NOT NULL, LoadDateTime DATETIME2(0) NOT NULL CONSTRAINT DF_stgPO_Load DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_stg_PurchaseOrder PRIMARY KEY (PurchaseOrderID)
    );
    PRINT 'Created stg.PurchaseOrder';
END;
GO

IF OBJECT_ID(N'stg.PurchaseOrderLine', N'U') IS NULL
BEGIN
    CREATE TABLE stg.PurchaseOrderLine
    (
        PurchaseOrderLineID VARCHAR(40) NOT NULL, PurchaseOrderID VARCHAR(30) NOT NULL, ProductID VARCHAR(20) NOT NULL,
        OrderedQuantity INT NOT NULL, ReceivedQuantity INT NOT NULL, OpenQuantity INT NOT NULL,
        UnitCost DECIMAL(18,2) NOT NULL, LineAmount DECIMAL(18,2) NOT NULL, LineStatus VARCHAR(30) NOT NULL,
        SourceCreatedDateTime DATETIME2(0) NOT NULL, SourceModifiedDateTime DATETIME2(0) NOT NULL,
        BatchID BIGINT NOT NULL, LoadDateTime DATETIME2(0) NOT NULL CONSTRAINT DF_stgPOL_Load DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_stg_PurchaseOrderLine PRIMARY KEY (PurchaseOrderLineID)
    );
    PRINT 'Created stg.PurchaseOrderLine';
END;
GO

IF OBJECT_ID(N'stg.GoodsReceipt', N'U') IS NULL
BEGIN
    CREATE TABLE stg.GoodsReceipt
    (
        GoodsReceiptID VARCHAR(30) NOT NULL, PurchaseOrderLineID VARCHAR(40) NOT NULL, ProductID VARCHAR(20) NOT NULL,
        WarehouseID VARCHAR(20) NOT NULL, ReceiptDateTime DATETIME2(0) NOT NULL,
        PhysicalReceivedQuantity INT NOT NULL, AcceptedQuantity INT NOT NULL, RejectedQuantity INT NOT NULL,
        ReceiptStatus VARCHAR(40) NOT NULL, ReceiptSource VARCHAR(40) NOT NULL,
        SourceCreatedDateTime DATETIME2(0) NOT NULL,
        BatchID BIGINT NOT NULL, LoadDateTime DATETIME2(0) NOT NULL CONSTRAINT DF_stgGR_Load DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_stg_GoodsReceipt PRIMARY KEY (GoodsReceiptID)
    );
    PRINT 'Created stg.GoodsReceipt';
END;
GO

IF OBJECT_ID(N'stg.InventoryBalance', N'U') IS NULL
BEGIN
    CREATE TABLE stg.InventoryBalance
    (
        ProductID VARCHAR(20) NOT NULL, WarehouseID VARCHAR(20) NOT NULL, OnHandQuantity INT NOT NULL,
        ReservedQuantity INT NOT NULL, AvailableQuantity INT NOT NULL, InTransitQuantity INT NOT NULL,
        AverageUnitCost DECIMAL(18,2) NOT NULL, LastMovementDateTime DATETIME2(0) NOT NULL,
        SourceModifiedDateTime DATETIME2(0) NOT NULL,
        BatchID BIGINT NOT NULL, LoadDateTime DATETIME2(0) NOT NULL CONSTRAINT DF_stgInvBal_Load DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_stg_InventoryBalance PRIMARY KEY (ProductID, WarehouseID)
    );
    PRINT 'Created stg.InventoryBalance';
END;
GO

IF OBJECT_ID(N'stg.SalesOrder', N'U') IS NULL
BEGIN
    CREATE TABLE stg.SalesOrder
    (
        SalesOrderID VARCHAR(30) NOT NULL, CustomerID VARCHAR(20) NOT NULL, OrderDate DATE NOT NULL,
        RequestedDeliveryDate DATE NOT NULL, Priority VARCHAR(20) NOT NULL, CurrencyCode CHAR(3) NOT NULL,
        OrderStatus VARCHAR(30) NOT NULL, OrderType VARCHAR(30) NOT NULL, SalesChannel VARCHAR(30) NOT NULL,
        SourceCreatedDateTime DATETIME2(0) NOT NULL, SourceModifiedDateTime DATETIME2(0) NOT NULL,
        BatchID BIGINT NOT NULL, LoadDateTime DATETIME2(0) NOT NULL CONSTRAINT DF_stgSO_Load DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_stg_SalesOrder PRIMARY KEY (SalesOrderID)
    );
    PRINT 'Created stg.SalesOrder';
END;
GO

IF OBJECT_ID(N'stg.SalesOrderLine', N'U') IS NULL
BEGIN
    CREATE TABLE stg.SalesOrderLine
    (
        SalesOrderLineID VARCHAR(40) NOT NULL, SalesOrderID VARCHAR(30) NOT NULL, ProductID VARCHAR(20) NOT NULL,
        FulfillmentWarehouseID VARCHAR(20) NOT NULL, PromisedDeliveryDate DATE NOT NULL,
        OrderQuantity INT NOT NULL, FulfilledQuantity INT NOT NULL, BackorderQuantity INT NOT NULL,
        UnitPrice DECIMAL(18,2) NOT NULL, GrossLineAmount DECIMAL(18,2) NOT NULL, DiscountAmount DECIMAL(18,2) NOT NULL,
        NetLineAmount DECIMAL(18,2) NOT NULL, LineStatus VARCHAR(30) NOT NULL,
        SourceCreatedDateTime DATETIME2(0) NOT NULL, SourceModifiedDateTime DATETIME2(0) NOT NULL,
        BatchID BIGINT NOT NULL, LoadDateTime DATETIME2(0) NOT NULL CONSTRAINT DF_stgSOL_Load DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_stg_SalesOrderLine PRIMARY KEY (SalesOrderLineID)
    );
    PRINT 'Created stg.SalesOrderLine';
END;
GO

IF OBJECT_ID(N'stg.Shipment', N'U') IS NULL
BEGIN
    CREATE TABLE stg.Shipment
    (
        ShipmentID VARCHAR(30) NOT NULL, SalesOrderID VARCHAR(30) NOT NULL, CarrierID VARCHAR(20) NOT NULL,
        OriginWarehouseID VARCHAR(20) NOT NULL, ShipmentDate DATE NOT NULL, PromisedDeliveryDate DATE NOT NULL,
        ActualDeliveryDate DATE NULL, ShipmentStatus VARCHAR(30) NOT NULL, ShipmentMode VARCHAR(20) NOT NULL,
        ServiceLevel VARCHAR(20) NOT NULL, DestinationRegion VARCHAR(30) NOT NULL, DestinationCountry VARCHAR(60) NOT NULL,
        DestinationStateProvince VARCHAR(60) NOT NULL, DestinationCity VARCHAR(60) NOT NULL,
        DestinationCountryCode CHAR(2) NOT NULL, ShippingCost DECIMAL(18,2) NOT NULL,
        ReturnFlag BIT NOT NULL, ReturnReason VARCHAR(40) NOT NULL,
        SourceCreatedDateTime DATETIME2(0) NOT NULL, SourceModifiedDateTime DATETIME2(0) NOT NULL,
        BatchID BIGINT NOT NULL, LoadDateTime DATETIME2(0) NOT NULL CONSTRAINT DF_stgShipment_Load DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_stg_Shipment PRIMARY KEY (ShipmentID)
    );
    PRINT 'Created stg.Shipment';
END;
GO

IF OBJECT_ID(N'stg.ShipmentLine', N'U') IS NULL
BEGIN
    CREATE TABLE stg.ShipmentLine
    (
        ShipmentLineID VARCHAR(40) NOT NULL, ShipmentID VARCHAR(30) NOT NULL, SalesOrderLineID VARCHAR(40) NOT NULL,
        ProductID VARCHAR(20) NOT NULL, ShippedQuantity INT NOT NULL, ReceivedQuantity INT NULL,
        SourceCreatedDateTime DATETIME2(0) NOT NULL, SourceModifiedDateTime DATETIME2(0) NOT NULL,
        BatchID BIGINT NOT NULL, LoadDateTime DATETIME2(0) NOT NULL CONSTRAINT DF_stgShipLine_Load DEFAULT (SYSDATETIME()),
        CONSTRAINT PK_stg_ShipmentLine PRIMARY KEY (ShipmentLineID)
    );
    PRINT 'Created stg.ShipmentLine';
END;
GO


/*==============================================================================
  STEP 6 - MART LAYER: DIMENSIONS
==============================================================================*/

/*------------------------------------------------------------------------------
  6.1 mart.DimDate -- populated in Step 8 below, 2021-01-01 through 2027-12-31.
------------------------------------------------------------------------------*/
IF OBJECT_ID(N'mart.DimDate', N'U') IS NULL
BEGIN
    CREATE TABLE mart.DimDate
    (
        DateKey             INT            NOT NULL,
        FullDate              DATE           NOT NULL,
        DayOfWeekNumber          TINYINT        NOT NULL,
        DayName                    VARCHAR(10)    NOT NULL,
        DayOfMonth                   TINYINT        NOT NULL,
        DayOfYear                       SMALLINT       NOT NULL,
        WeekOfYear                         TINYINT        NOT NULL,
        MonthNumber                           TINYINT        NOT NULL,
        MonthName                                VARCHAR(10)    NOT NULL,
        YearMonth                                   CHAR(7)        NOT NULL,
        Quarter                                        TINYINT        NOT NULL,
        QuarterName                                       CHAR(2)        NOT NULL,
        Year                                                  SMALLINT       NOT NULL,
        IsWeekend                                              BIT            NOT NULL,
        IsMonthEnd                                                BIT            NOT NULL,
        IsQuarterEnd                                                 BIT            NOT NULL,
        IsYearEnd                                                       BIT            NOT NULL,

        CONSTRAINT PK_DimDate PRIMARY KEY (DateKey),
        CONSTRAINT UQ_DimDate_FullDate UNIQUE (FullDate)
    );
    PRINT 'Created mart.DimDate';
END;
GO

/*------------------------------------------------------------------------------
  6.2 mart.DimProduct -- Type 1 (overwrite in place).
------------------------------------------------------------------------------*/
IF OBJECT_ID(N'mart.DimProduct', N'U') IS NULL
BEGIN
    CREATE TABLE mart.DimProduct
    (
        ProductKey            INT IDENTITY(1,1) NOT NULL,
        ProductID               VARCHAR(20)    NOT NULL,
        SKU                        VARCHAR(30)    NOT NULL,
        ProductName                  VARCHAR(150)   NOT NULL,
        Category                        VARCHAR(60)    NOT NULL,
        Subcategory                        VARCHAR(60)    NOT NULL,
        ProductType                           VARCHAR(30)    NOT NULL,
        MakeBuyType                              VARCHAR(10)    NOT NULL,
        VehicleSegment                              VARCHAR(40)    NOT NULL,
        UnitOfMeasure                                  VARCHAR(10)    NOT NULL,
        ABCClass                                          CHAR(1)        NOT NULL,
        StandardCost                                         DECIMAL(18,2)  NOT NULL,
        ListPrice                                               DECIMAL(18,2)  NULL,
        SafetyStockQuantity                                        INT            NOT NULL,
        ReorderLevel                                                  INT            NOT NULL,
        MaximumStockQuantity                                             INT            NOT NULL,
        ProductStatus                                                       VARCHAR(20)    NOT NULL,
        LaunchDate                                                             DATE           NULL,
        DiscontinuedDate                                                          DATE           NULL,
        ActiveFlag                                                                   BIT            NOT NULL,
        SourceModifiedDateTime                                                          DATETIME2(0)   NOT NULL,
        DWCreatedDateTime                                                                  DATETIME2(0)   NOT NULL CONSTRAINT DF_DimProduct_Created DEFAULT (SYSDATETIME()),
        DWModifiedDateTime                                                                    DATETIME2(0)   NOT NULL CONSTRAINT DF_DimProduct_Modified DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_DimProduct PRIMARY KEY (ProductKey),
        CONSTRAINT UQ_DimProduct_ProductID UNIQUE (ProductID)
    );
    PRINT 'Created mart.DimProduct';
END;
GO

/*------------------------------------------------------------------------------
  6.3 mart.DimSupplier -- Type 2 on SupplierTier / SupplierStatus / SupplierRisk.
  A filtered unique index guarantees exactly one IsCurrent=1 row per SupplierID.
------------------------------------------------------------------------------*/
IF OBJECT_ID(N'mart.DimSupplier', N'U') IS NULL
BEGIN
    CREATE TABLE mart.DimSupplier
    (
        SupplierKey             INT IDENTITY(1,1) NOT NULL,
        SupplierID                 VARCHAR(20)    NOT NULL,
        SupplierName                  VARCHAR(150)   NOT NULL,
        SupplierCategory                 VARCHAR(50)    NOT NULL,
        SupplierTier                        VARCHAR(30)    NOT NULL,
        SupplierStatus                         VARCHAR(20)    NOT NULL,
        SupplierRisk                              VARCHAR(10)    NOT NULL,
        CriticalSupplierFlag                         BIT            NOT NULL,
        StandardLeadTimeDays                            INT            NOT NULL,
        PaymentTermsDays                                   INT            NOT NULL,
        Region                                                VARCHAR(30)    NOT NULL,
        Country                                                 VARCHAR(60)    NOT NULL,
        StateProvince                                              VARCHAR(60)    NOT NULL,
        City                                                          VARCHAR(60)    NOT NULL,
        CountryCode                                                      CHAR(2)        NOT NULL,
        ActiveFlag                                                          BIT            NOT NULL,
        EffectiveStartDateTime                                                 DATETIME2(0)   NOT NULL,
        EffectiveEndDateTime                                                      DATETIME2(0)   NULL,
        IsCurrent                                                                    BIT            NOT NULL,
        SourceModifiedDateTime                                                          DATETIME2(0)   NOT NULL,
        DWCreatedDateTime                                                                  DATETIME2(0)   NOT NULL CONSTRAINT DF_DimSupplier_Created DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_DimSupplier PRIMARY KEY (SupplierKey)
    );
    PRINT 'Created mart.DimSupplier';
END;
GO

/* Filtered/plain indexes pulled out of the CREATE TABLE block above and made
   independently idempotent -- CREATE INDEX needs its own idempotency check
   since the table-creation IF guard above only fires once, ever. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'mart.DimSupplier') AND name = N'UQ_DimSupplier_CurrentRow')
    CREATE UNIQUE INDEX UQ_DimSupplier_CurrentRow ON mart.DimSupplier(SupplierID) WHERE IsCurrent = 1;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'mart.DimSupplier') AND name = N'IX_DimSupplier_SupplierID')
    CREATE INDEX IX_DimSupplier_SupplierID ON mart.DimSupplier(SupplierID);
GO

/*------------------------------------------------------------------------------
  6.4 mart.DimCustomer -- Type 1.
------------------------------------------------------------------------------*/
IF OBJECT_ID(N'mart.DimCustomer', N'U') IS NULL
BEGIN
    CREATE TABLE mart.DimCustomer
    (
        CustomerKey            INT IDENTITY(1,1) NOT NULL,
        CustomerID                VARCHAR(20)    NOT NULL,
        CustomerName                  VARCHAR(150)   NOT NULL,
        CustomerType                     VARCHAR(40)    NOT NULL,
        CustomerSegment                     VARCHAR(20)    NOT NULL,
        CreditTermsDays                        INT            NOT NULL,
        Region                                    VARCHAR(30)    NOT NULL,
        Country                                     VARCHAR(60)    NOT NULL,
        StateProvince                                  VARCHAR(60)    NOT NULL,
        City                                              VARCHAR(60)    NOT NULL,
        CountryCode                                          CHAR(2)        NOT NULL,
        ActiveFlag                                              BIT            NOT NULL,
        SourceModifiedDateTime                                     DATETIME2(0)   NOT NULL,
        DWCreatedDateTime                                             DATETIME2(0)   NOT NULL CONSTRAINT DF_DimCustomer_Created DEFAULT (SYSDATETIME()),
        DWModifiedDateTime                                               DATETIME2(0)   NOT NULL CONSTRAINT DF_DimCustomer_Modified DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_DimCustomer PRIMARY KEY (CustomerKey),
        CONSTRAINT UQ_DimCustomer_CustomerID UNIQUE (CustomerID)
    );
    PRINT 'Created mart.DimCustomer';
END;
GO

/*------------------------------------------------------------------------------
  6.5 mart.DimWarehouse -- Type 1.
------------------------------------------------------------------------------*/
IF OBJECT_ID(N'mart.DimWarehouse', N'U') IS NULL
BEGIN
    CREATE TABLE mart.DimWarehouse
    (
        WarehouseKey           INT IDENTITY(1,1) NOT NULL,
        WarehouseID                VARCHAR(20)    NOT NULL,
        WarehouseName                  VARCHAR(120)   NOT NULL,
        WarehouseType                      VARCHAR(30)    NOT NULL,
        Region                                VARCHAR(30)    NOT NULL,
        Country                                 VARCHAR(60)    NOT NULL,
        StateProvince                              VARCHAR(60)    NOT NULL,
        City                                          VARCHAR(60)    NOT NULL,
        CountryCode                                     CHAR(2)        NOT NULL,
        CapacityUnits                                      INT            NOT NULL,
        ActiveFlag                                            BIT            NOT NULL,
        SourceModifiedDateTime                                   DATETIME2(0)   NOT NULL,
        DWCreatedDateTime                                           DATETIME2(0)   NOT NULL CONSTRAINT DF_DimWarehouse_Created DEFAULT (SYSDATETIME()),
        DWModifiedDateTime                                             DATETIME2(0)   NOT NULL CONSTRAINT DF_DimWarehouse_Modified DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_DimWarehouse PRIMARY KEY (WarehouseKey),
        CONSTRAINT UQ_DimWarehouse_WarehouseID UNIQUE (WarehouseID)
    );
    PRINT 'Created mart.DimWarehouse';
END;
GO

/*------------------------------------------------------------------------------
  6.6 mart.DimCarrier -- Type 1.
------------------------------------------------------------------------------*/
IF OBJECT_ID(N'mart.DimCarrier', N'U') IS NULL
BEGIN
    CREATE TABLE mart.DimCarrier
    (
        CarrierKey             INT IDENTITY(1,1) NOT NULL,
        CarrierID                 VARCHAR(20)    NOT NULL,
        CarrierName                   VARCHAR(120)   NOT NULL,
        CarrierType                       VARCHAR(20)    NOT NULL,
        ServiceLevel                          VARCHAR(20)    NOT NULL,
        Coverage                                 VARCHAR(20)    NOT NULL,
        CarrierRating                                VARCHAR(20)    NOT NULL,
        ContractType                                    VARCHAR(30)    NOT NULL,
        PrimaryRegion                                      VARCHAR(30)    NOT NULL,
        ActiveFlag                                            BIT            NOT NULL,
        SourceModifiedDateTime                                   DATETIME2(0)   NOT NULL,
        DWCreatedDateTime                                           DATETIME2(0)   NOT NULL CONSTRAINT DF_DimCarrier_Created DEFAULT (SYSDATETIME()),
        DWModifiedDateTime                                             DATETIME2(0)   NOT NULL CONSTRAINT DF_DimCarrier_Modified DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_DimCarrier PRIMARY KEY (CarrierKey),
        CONSTRAINT UQ_DimCarrier_CarrierID UNIQUE (CarrierID)
    );
    PRINT 'Created mart.DimCarrier';
END;
GO


/*==============================================================================
  STEP 7 - MART LAYER: FACTS
  Dimension -> Fact relationships only; no fact-to-fact relationships.
==============================================================================*/

/*------------------------------------------------------------------------------
  7.1 mart.FactPurchaseOrder -- grain: one row per PurchaseOrderLine.
------------------------------------------------------------------------------*/
IF OBJECT_ID(N'mart.FactPurchaseOrder', N'U') IS NULL
BEGIN
    CREATE TABLE mart.FactPurchaseOrder
    (
        PurchaseOrderLineKey     BIGINT IDENTITY(1,1) NOT NULL,
        PurchaseOrderID             VARCHAR(30)    NOT NULL,
        PurchaseOrderLineID            VARCHAR(40)    NOT NULL,
        OrderDateKey                      INT            NOT NULL,
        RequestedDeliveryDateKey             INT            NOT NULL,
        PromisedDeliveryDateKey                 INT            NOT NULL,
        ActualReceiptDateKey                       INT            NULL,
        SupplierKey                                   INT            NOT NULL,
        ProductKey                                       INT            NOT NULL,
        WarehouseKey                                        INT            NOT NULL,
        PurchaseType                                           VARCHAR(30)    NOT NULL,
        Priority                                                  VARCHAR(20)    NOT NULL,
        POStatus                                                     VARCHAR(30)    NOT NULL,
        BuyerGroup                                                      VARCHAR(40)    NOT NULL,
        LineStatus                                                         VARCHAR(30)    NOT NULL,
        OrderedQuantity                                                       INT            NOT NULL,
        ReceivedQuantity                                                         INT            NOT NULL,
        OpenQuantity                                                                INT            NOT NULL,
        AcceptedQuantity                                                               INT            NOT NULL,
        RejectedQuantity                                                                  INT            NOT NULL,
        UnitCost                                                                             DECIMAL(18,2)  NOT NULL,
        LineAmount                                                                              DECIMAL(18,2)  NOT NULL,
        SupplierDelayDays                                                                          INT            NULL,
        DeliveryStatus                                                                                VARCHAR(20)    NOT NULL,
        BatchID                                                                                          BIGINT         NOT NULL,
        LoadDateTime                                                                                        DATETIME2(0)   NOT NULL CONSTRAINT DF_FactPO_Load DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_FactPurchaseOrder PRIMARY KEY (PurchaseOrderLineKey),
        CONSTRAINT UQ_FactPurchaseOrder_Line UNIQUE (PurchaseOrderLineID),
        CONSTRAINT FK_FactPO_OrderDate FOREIGN KEY (OrderDateKey) REFERENCES mart.DimDate(DateKey),
        CONSTRAINT FK_FactPO_RequestedDate FOREIGN KEY (RequestedDeliveryDateKey) REFERENCES mart.DimDate(DateKey),
        CONSTRAINT FK_FactPO_PromisedDate FOREIGN KEY (PromisedDeliveryDateKey) REFERENCES mart.DimDate(DateKey),
        CONSTRAINT FK_FactPO_ActualReceiptDate FOREIGN KEY (ActualReceiptDateKey) REFERENCES mart.DimDate(DateKey),
        CONSTRAINT FK_FactPO_Supplier FOREIGN KEY (SupplierKey) REFERENCES mart.DimSupplier(SupplierKey),
        CONSTRAINT FK_FactPO_Product FOREIGN KEY (ProductKey) REFERENCES mart.DimProduct(ProductKey),
        CONSTRAINT FK_FactPO_Warehouse FOREIGN KEY (WarehouseKey) REFERENCES mart.DimWarehouse(WarehouseKey)
    );
    CREATE INDEX IX_FactPO_OrderDateKey ON mart.FactPurchaseOrder(OrderDateKey);
    CREATE INDEX IX_FactPO_SupplierKey ON mart.FactPurchaseOrder(SupplierKey);
    CREATE INDEX IX_FactPO_ProductKey ON mart.FactPurchaseOrder(ProductKey);
    PRINT 'Created mart.FactPurchaseOrder';
END;
GO

/*------------------------------------------------------------------------------
  7.2 mart.FactSalesOrder -- grain: one row per SalesOrderLine.
------------------------------------------------------------------------------*/
IF OBJECT_ID(N'mart.FactSalesOrder', N'U') IS NULL
BEGIN
    CREATE TABLE mart.FactSalesOrder
    (
        SalesOrderLineKey        BIGINT IDENTITY(1,1) NOT NULL,
        SalesOrderID                 VARCHAR(30)    NOT NULL,
        SalesOrderLineID                VARCHAR(40)    NOT NULL,
        OrderDateKey                       INT            NOT NULL,
        RequestedDeliveryDateKey              INT            NOT NULL,
        PromisedDeliveryDateKey                  INT            NOT NULL,
        CustomerKey                                 INT            NOT NULL,
        ProductKey                                     INT            NOT NULL,
        WarehouseKey                                      INT            NOT NULL,
        Priority                                             VARCHAR(20)    NOT NULL,
        OrderStatus                                             VARCHAR(30)    NOT NULL,
        OrderType                                                  VARCHAR(30)    NOT NULL,
        SalesChannel                                                  VARCHAR(30)    NOT NULL,
        LineStatus                                                       VARCHAR(30)    NOT NULL,
        OrderQuantity                                                       INT            NOT NULL,
        FulfilledQuantity                                                      INT            NOT NULL,
        BackorderQuantity                                                         INT            NOT NULL,
        UnitPrice                                                                    DECIMAL(18,2)  NOT NULL,
        GrossLineAmount                                                                 DECIMAL(18,2)  NOT NULL,
        DiscountAmount                                                                     DECIMAL(18,2)  NOT NULL,
        NetLineAmount                                                                         DECIMAL(18,2)  NOT NULL,
        FillRatePercent                                                                          DECIMAL(5,2)   NOT NULL,
        BatchID                                                                                     BIGINT         NOT NULL,
        LoadDateTime                                                                                   DATETIME2(0)   NOT NULL CONSTRAINT DF_FactSO_Load DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_FactSalesOrder PRIMARY KEY (SalesOrderLineKey),
        CONSTRAINT UQ_FactSalesOrder_Line UNIQUE (SalesOrderLineID),
        CONSTRAINT FK_FactSO_OrderDate FOREIGN KEY (OrderDateKey) REFERENCES mart.DimDate(DateKey),
        CONSTRAINT FK_FactSO_RequestedDate FOREIGN KEY (RequestedDeliveryDateKey) REFERENCES mart.DimDate(DateKey),
        CONSTRAINT FK_FactSO_PromisedDate FOREIGN KEY (PromisedDeliveryDateKey) REFERENCES mart.DimDate(DateKey),
        CONSTRAINT FK_FactSO_Customer FOREIGN KEY (CustomerKey) REFERENCES mart.DimCustomer(CustomerKey),
        CONSTRAINT FK_FactSO_Product FOREIGN KEY (ProductKey) REFERENCES mart.DimProduct(ProductKey),
        CONSTRAINT FK_FactSO_Warehouse FOREIGN KEY (WarehouseKey) REFERENCES mart.DimWarehouse(WarehouseKey)
    );
    CREATE INDEX IX_FactSO_OrderDateKey ON mart.FactSalesOrder(OrderDateKey);
    CREATE INDEX IX_FactSO_CustomerKey ON mart.FactSalesOrder(CustomerKey);
    CREATE INDEX IX_FactSO_ProductKey ON mart.FactSalesOrder(ProductKey);
    PRINT 'Created mart.FactSalesOrder';
END;
GO

/*------------------------------------------------------------------------------
  7.3 mart.FactInventorySnapshot -- grain: SnapshotDateKey x Product x Warehouse.
  Periodic snapshot fact -- new rows appended each ETL run, not upserted.
------------------------------------------------------------------------------*/
IF OBJECT_ID(N'mart.FactInventorySnapshot', N'U') IS NULL
BEGIN
    CREATE TABLE mart.FactInventorySnapshot
    (
        InventorySnapshotKey     BIGINT IDENTITY(1,1) NOT NULL,
        SnapshotDateKey              INT            NOT NULL,
        ProductKey                      INT            NOT NULL,
        WarehouseKey                       INT            NOT NULL,
        OnHandQuantity                        INT            NOT NULL,
        ReservedQuantity                         INT            NOT NULL,
        AvailableQuantity                           INT            NOT NULL,
        InTransitQuantity                              INT            NOT NULL,
        AverageUnitCost                                   DECIMAL(18,2)  NOT NULL,
        InventoryValue                                       DECIMAL(18,2)  NOT NULL,
        DaysSinceLastMovement                                   INT            NOT NULL,
        MovementClass                                              VARCHAR(20)    NOT NULL,
        StockStatus                                                   VARCHAR(20)    NOT NULL,
        LastMovementDateTime                                             DATETIME2(0)   NOT NULL,
        BatchID                                                             BIGINT         NOT NULL,
        LoadDateTime                                                           DATETIME2(0)   NOT NULL CONSTRAINT DF_FactInvSnap_Load DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_FactInventorySnapshot PRIMARY KEY (InventorySnapshotKey),
        CONSTRAINT UQ_FactInventorySnapshot_Grain UNIQUE (SnapshotDateKey, ProductKey, WarehouseKey),
        CONSTRAINT FK_FactInvSnap_SnapshotDate FOREIGN KEY (SnapshotDateKey) REFERENCES mart.DimDate(DateKey),
        CONSTRAINT FK_FactInvSnap_Product FOREIGN KEY (ProductKey) REFERENCES mart.DimProduct(ProductKey),
        CONSTRAINT FK_FactInvSnap_Warehouse FOREIGN KEY (WarehouseKey) REFERENCES mart.DimWarehouse(WarehouseKey)
    );
    CREATE INDEX IX_FactInvSnap_SnapshotDateKey ON mart.FactInventorySnapshot(SnapshotDateKey);
    PRINT 'Created mart.FactInventorySnapshot';
END;
GO

/*------------------------------------------------------------------------------
  7.4 mart.FactShipment -- grain: one row per ShipmentLine.
------------------------------------------------------------------------------*/
IF OBJECT_ID(N'mart.FactShipment', N'U') IS NULL
BEGIN
    CREATE TABLE mart.FactShipment
    (
        ShipmentLineKey          BIGINT IDENTITY(1,1) NOT NULL,
        ShipmentID                   VARCHAR(30)    NOT NULL,
        ShipmentLineID                  VARCHAR(40)    NOT NULL,
        SalesOrderID                       VARCHAR(30)    NOT NULL,
        SalesOrderLineID                      VARCHAR(40)    NOT NULL,
        ShipmentDateKey                          INT            NOT NULL,
        PromisedDeliveryDateKey                     INT            NOT NULL,
        ActualDeliveryDateKey                          INT            NULL,
        CarrierKey                                        INT            NOT NULL,
        WarehouseKey                                         INT            NOT NULL,
        CustomerKey                                             INT            NOT NULL,
        ProductKey                                                 INT            NOT NULL,
        ShipmentStatus                                                VARCHAR(30)    NOT NULL,
        ShipmentMode                                                     VARCHAR(20)    NOT NULL,
        ServiceLevel                                                        VARCHAR(20)    NOT NULL,
        DestinationRegion                                                      VARCHAR(30)    NOT NULL,
        DestinationCountry                                                        VARCHAR(60)    NOT NULL,
        DestinationStateProvince                                                     VARCHAR(60)    NOT NULL,
        DestinationCity                                                                 VARCHAR(60)    NOT NULL,
        ShippedQuantity                                                                    INT            NOT NULL,
        ReceivedQuantity                                                                      INT            NULL,
        ShippingCost                                                                             DECIMAL(18,2)  NOT NULL,
        ReturnFlag                                                                                  BIT            NOT NULL,
        ReturnReason                                                                                   VARCHAR(40)    NOT NULL,
        DeliveryDelayDays                                                                                 INT            NULL,
        DeliveryStatus                                                                                       VARCHAR(20)    NOT NULL,
        BatchID                                                                                                 BIGINT         NOT NULL,
        LoadDateTime                                                                                               DATETIME2(0)   NOT NULL CONSTRAINT DF_FactShipment_Load DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_FactShipment PRIMARY KEY (ShipmentLineKey),
        CONSTRAINT UQ_FactShipment_Line UNIQUE (ShipmentLineID),
        CONSTRAINT FK_FactShipment_ShipmentDate FOREIGN KEY (ShipmentDateKey) REFERENCES mart.DimDate(DateKey),
        CONSTRAINT FK_FactShipment_PromisedDate FOREIGN KEY (PromisedDeliveryDateKey) REFERENCES mart.DimDate(DateKey),
        CONSTRAINT FK_FactShipment_ActualDate FOREIGN KEY (ActualDeliveryDateKey) REFERENCES mart.DimDate(DateKey),
        CONSTRAINT FK_FactShipment_Carrier FOREIGN KEY (CarrierKey) REFERENCES mart.DimCarrier(CarrierKey),
        CONSTRAINT FK_FactShipment_Warehouse FOREIGN KEY (WarehouseKey) REFERENCES mart.DimWarehouse(WarehouseKey),
        CONSTRAINT FK_FactShipment_Customer FOREIGN KEY (CustomerKey) REFERENCES mart.DimCustomer(CustomerKey),
        CONSTRAINT FK_FactShipment_Product FOREIGN KEY (ProductKey) REFERENCES mart.DimProduct(ProductKey)
    );
    CREATE INDEX IX_FactShipment_ShipmentDateKey ON mart.FactShipment(ShipmentDateKey);
    CREATE INDEX IX_FactShipment_CarrierKey ON mart.FactShipment(CarrierKey);
    PRINT 'Created mart.FactShipment';
END;
GO


/*==============================================================================
  STEP 8 - POPULATE mart.DimDate (2021-01-01 through 2027-12-31)
  Covers the simulator's HISTORY_START (2021-01-01) through several years of
  future promised/requested delivery dates.
==============================================================================*/

IF NOT EXISTS (SELECT 1 FROM mart.DimDate)
BEGIN
    DECLARE @StartDate DATE = '2021-01-01';
    DECLARE @EndDate   DATE = '2027-12-31';

    ;WITH DateSeq AS
    (
        SELECT @StartDate AS FullDate
        UNION ALL
        SELECT DATEADD(DAY, 1, FullDate)
        FROM DateSeq
        WHERE FullDate < @EndDate
    )
    INSERT INTO mart.DimDate
    (
        DateKey, FullDate, DayOfWeekNumber, DayName, DayOfMonth, DayOfYear, WeekOfYear,
        MonthNumber, MonthName, YearMonth, Quarter, QuarterName, Year,
        IsWeekend, IsMonthEnd, IsQuarterEnd, IsYearEnd
    )
    SELECT
        CAST(FORMAT(FullDate, 'yyyyMMdd') AS INT)                          AS DateKey,
        FullDate,
        DATEPART(WEEKDAY, FullDate)                                        AS DayOfWeekNumber,
        DATENAME(WEEKDAY, FullDate)                                        AS DayName,
        DATEPART(DAY, FullDate)                                            AS DayOfMonth,
        DATEPART(DAYOFYEAR, FullDate)                                      AS DayOfYear,
        DATEPART(WEEK, FullDate)                                           AS WeekOfYear,
        DATEPART(MONTH, FullDate)                                          AS MonthNumber,
        DATENAME(MONTH, FullDate)                                          AS MonthName,
        FORMAT(FullDate, 'yyyy-MM')                                        AS YearMonth,
        DATEPART(QUARTER, FullDate)                                        AS Quarter,
        'Q' + CAST(DATEPART(QUARTER, FullDate) AS CHAR(1))                 AS QuarterName,
        DATEPART(YEAR, FullDate)                                           AS Year,
        CASE WHEN DATEPART(WEEKDAY, FullDate) IN (1,7) THEN 1 ELSE 0 END   AS IsWeekend,
        CASE WHEN EOMONTH(FullDate) = FullDate THEN 1 ELSE 0 END           AS IsMonthEnd,
        CASE WHEN EOMONTH(FullDate) = FullDate
                  AND DATEPART(MONTH, FullDate) IN (3,6,9,12) THEN 1 ELSE 0 END AS IsQuarterEnd,
        CASE WHEN FullDate = DATEFROMPARTS(DATEPART(YEAR, FullDate), 12, 31) THEN 1 ELSE 0 END AS IsYearEnd
    FROM DateSeq
    OPTION (MAXRECURSION 3000);

    PRINT 'Populated mart.DimDate (' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' rows)';
END
ELSE
BEGIN
    PRINT 'mart.DimDate already populated. Skipped.';
END;
GO


/*==============================================================================
  STEP 9 - SEED etl.LoadControl (13 source tables, initial watermark 1900-01-01)
==============================================================================*/

INSERT INTO etl.LoadControl (TableName)
SELECT v.TableName
FROM (VALUES
    ('Product'),('Supplier'),('Customer'),('Warehouse'),('Carrier'),
    ('PurchaseOrder'),('PurchaseOrderLine'),('GoodsReceipt'),
    ('InventoryBalance'),
    ('SalesOrder'),('SalesOrderLine'),
    ('Shipment'),('ShipmentLine')
) AS v(TableName)
WHERE NOT EXISTS (SELECT 1 FROM etl.LoadControl lc WHERE lc.TableName = v.TableName);
GO


/*==============================================================================
  STEP 10 - VALIDATION QUERIES
==============================================================================*/

PRINT '==============================================================';
PRINT 'Manufacturing_DW setup validation';
PRINT '==============================================================';

SELECT DB_NAME() AS CurrentDatabase;
GO

SELECT s.name AS SchemaName, COUNT(*) AS TableCount
FROM sys.tables t
INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
WHERE s.name IN ('raw','stg','mart','etl')
GROUP BY s.name
ORDER BY s.name;
GO

SELECT s.name AS SchemaName, t.name AS TableName
FROM sys.tables t
INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
WHERE s.name IN ('raw','stg','mart','etl')
ORDER BY s.name, t.name;
GO

SELECT COUNT(*) AS DimDateRowCount FROM mart.DimDate;
GO

SELECT COUNT(*) AS LoadControlRowCount FROM etl.LoadControl;
GO


/*==============================================================================
  EXPECTED STRUCTURE AFTER SUCCESS
==============================================================================

Manufacturing_DW
|
+-- raw     13 tables (Product .. ShipmentLine, source-shaped, upsert)
+-- stg     13 tables (same grain, cleaned/validated)
+-- mart    6 dimensions (DimDate, DimProduct, DimSupplier[SCD2], DimCustomer,
|                          DimWarehouse, DimCarrier)
|           4 facts (FactPurchaseOrder, FactSalesOrder, FactInventorySnapshot,
|                     FactShipment)
+-- etl     4 control tables (BatchRun, BatchAudit, LoadControl, RejectedRows)

mart.DimDate: 2557 rows (2021-01-01 .. 2027-12-31)
etl.LoadControl: 13 rows, all watermarked at 1900-01-01 (first ETL run will
                 pull full history for every source table)

NEXT STEP
---------
Run 03_ETL_StoredProcedures.sql to build the etl.usp_Load_* procedures and
the etl.usp_RunFullETL orchestrator, then execute a full ETL cycle.

FINAL RULE
----------
Power BI connects ONLY to Manufacturing_DW.mart. Nothing upstream of mart is
ever queried directly by a report.
================================================================================
*/
