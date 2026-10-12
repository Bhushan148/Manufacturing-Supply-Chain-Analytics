/*
================================================================================
FILE: 01_Manufacturing_Source_Initial_Setup.sql
PROJECT: Automotive Components Manufacturing & Supply Chain Analytics
DATABASE: Manufacturing_Source
PURPOSE: Initial operational source database setup

SOURCE OF TRUTH FOR THIS FILE
------------------------------
This DDL is generated to match, column-for-column, what the Python simulator
actually produces and what loaders/sql_loader.py's EXPECTED_COLUMNS checks at
load time (main_initial_load.py / main_incremental_update.py both call
validate_schema() first and refuse to load on any mismatch). If you change a
column here, update EXPECTED_COLUMNS too, or the load will stop with a clear
"missing/extra columns" error rather than silently succeeding.

Also see: docs/FINAL_SOURCE_STRUCTURE.md in the Python project.

SINGLE dbo SCHEMA (NOT split by business area)
-------------------------------------------------
An earlier version of this file grouped tables into master / procurement /
inventory / sales / logistics schemas. For this project's current scope that
was dropped in favor of a single flat dbo schema -- 13 tables doesn't need the
extra navigation/permission layering schemas exist for, and it keeps the DDL
simpler to maintain. The Python loader (loaders/sql_loader.py) still uses
schema-prefixed logical names like "master.Product" internally as plain
Python dict keys and CSV filename prefixes (build_initial_dataset(), the
EXPECTED_COLUMNS dict, CSV file names) -- that naming is unrelated to SQL
Server schemas now; only the trailing table name (e.g. "Product") is used to
build the actual dbo.Product SQL object name.

WHAT THIS FILE CREATES
-----------------------
Database:
    Manufacturing_Source

Tables (13, all in dbo):
    dbo.Product
    dbo.Supplier
    dbo.Customer
    dbo.Warehouse
    dbo.Carrier

    dbo.PurchaseOrder
    dbo.PurchaseOrderLine
    dbo.GoodsReceipt

    dbo.InventoryBalance

    dbo.SalesOrder
    dbo.SalesOrderLine

    dbo.Shipment
    dbo.ShipmentLine

IMPORTANT PROJECT RULE
------------------------
Python writes ONLY to Manufacturing_Source. It does not write directly to a
data warehouse. Later flow:

    Python -> Manufacturing_Source -> SQL Server ETL -> Manufacturing_DW.stg
           -> Manufacturing_DW.dw -> Manufacturing_DW.mart -> Power BI

HINGLISH:
Pehle source database ka contract freeze kar rahe hain, exactly wahi jo Python
generate karta hai -- na kam column, na extra column. Sab tables ek hi dbo
schema mein hain (abhi ke liye multiple schema ki zaroorat nahi). Baad mein
DW/mart layer alag se, SQL ETL se banega.
================================================================================
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO


/*==============================================================================
  STEP 1 - CREATE DATABASE
==============================================================================*/

USE master;
GO

IF DB_ID(N'Manufacturing_Source') IS NULL
BEGIN
    PRINT 'Creating database Manufacturing_Source...';
    CREATE DATABASE Manufacturing_Source;
END
ELSE
BEGIN
    PRINT 'Manufacturing_Source already exists. Database creation skipped.';
END;
GO


/*==============================================================================
  STEP 2 - MASTER TABLES
==============================================================================*/

USE Manufacturing_Source;
GO


/*------------------------------------------------------------------------------
  2.1 dbo.Product
  Grain: one row per Product / SKU
  NOTE: Category has 10 values, Subcategory has 58 values that are each valid
  only under a specific Category (see reference/product_catalog.py). That
  relationship can't be expressed with a simple CHECK constraint without a
  lookup table, so it is deliberately left to the Python generator's own
  validation (utils/validation.py) rather than duplicated and risking drift.
------------------------------------------------------------------------------*/

IF OBJECT_ID(N'dbo.Product', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Product
    (
        ProductID                  VARCHAR(20)    NOT NULL,
        SKU                        VARCHAR(30)    NOT NULL,
        ProductName                VARCHAR(150)   NOT NULL,
        Category                   VARCHAR(60)    NOT NULL,
        Subcategory                VARCHAR(60)    NOT NULL,
        ProductType                VARCHAR(30)    NOT NULL,
        MakeBuyType                VARCHAR(10)    NOT NULL,
        VehicleSegment             VARCHAR(40)    NOT NULL,
        UnitOfMeasure              VARCHAR(10)    NOT NULL,
        ABCClass                   CHAR(1)        NOT NULL,
        StandardCost               DECIMAL(18,2)  NOT NULL,
        ListPrice                  DECIMAL(18,2)  NULL,
        SafetyStockQuantity        INT            NOT NULL CONSTRAINT DF_Product_SafetyStock DEFAULT (0),
        ReorderLevel               INT            NOT NULL CONSTRAINT DF_Product_ReorderLevel DEFAULT (0),
        MaximumStockQuantity       INT            NOT NULL CONSTRAINT DF_Product_MaxStock DEFAULT (0),
        ProductStatus              VARCHAR(20)    NOT NULL,
        LaunchDate                 DATE           NULL,
        DiscontinuedDate           DATE           NULL,
        ImageURL                   VARCHAR(500)   NULL,
        ActiveFlag                 BIT            NOT NULL CONSTRAINT DF_Product_ActiveFlag DEFAULT (1),
        CreatedDateTime            DATETIME2(0)   NOT NULL CONSTRAINT DF_Product_Created DEFAULT (SYSDATETIME()),
        ModifiedDateTime           DATETIME2(0)   NOT NULL CONSTRAINT DF_Product_Modified DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_Product PRIMARY KEY (ProductID),
        CONSTRAINT UQ_Product_SKU UNIQUE (SKU),

        CONSTRAINT CK_Product_ProductType
            CHECK (ProductType IN ('Finished Good','Component','Raw Material','Packaging Material')),

        CONSTRAINT CK_Product_MakeBuyType
            CHECK (MakeBuyType IN ('Make','Buy')),

        CONSTRAINT CK_Product_ABCClass
            CHECK (ABCClass IN ('A','B','C')),

        CONSTRAINT CK_Product_ProductStatus
            CHECK (ProductStatus IN ('New','Active','Phase Out','Discontinued')),

        CONSTRAINT CK_Product_VehicleSegment
            CHECK (VehicleSegment IN
            ('Passenger Vehicle','Commercial Vehicle','Two Wheeler',
             'Off-Highway','Multi-Segment','Not Applicable')),

        CONSTRAINT CK_Product_UnitOfMeasure
            CHECK (UnitOfMeasure IN ('EA','SET','KG','MTR','LTR','BOX')),

        CONSTRAINT CK_Product_StandardCost CHECK (StandardCost >= 0),
        CONSTRAINT CK_Product_ListPrice CHECK (ListPrice IS NULL OR ListPrice >= 0),
        CONSTRAINT CK_Product_SafetyStock CHECK (SafetyStockQuantity >= 0),
        CONSTRAINT CK_Product_Reorder CHECK (ReorderLevel >= SafetyStockQuantity),
        CONSTRAINT CK_Product_MaxStock CHECK (MaximumStockQuantity > ReorderLevel),

        CONSTRAINT CK_Product_DiscontinuedDate
            CHECK (DiscontinuedDate IS NULL OR LaunchDate IS NULL OR DiscontinuedDate >= LaunchDate)
    );

    PRINT 'Created dbo.Product';
END;
GO


/*------------------------------------------------------------------------------
  2.2 dbo.Supplier
  Grain: one row per supplier
  NOTE: Tier/Status/Risk are exactly the three columns the incremental script
  occasionally re-scores after a periodic review (generators/incremental_update.py:
  mutate_supplier_attributes). The source table only ever holds the CURRENT
  value -- no history column here on purpose. SCD2 versioning of these changes
  belongs in the future Manufacturing_DW layer, not in this source table.
------------------------------------------------------------------------------*/

IF OBJECT_ID(N'dbo.Supplier', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Supplier
    (
        SupplierID                 VARCHAR(20)    NOT NULL,
        SupplierName               VARCHAR(150)   NOT NULL,
        SupplierCategory           VARCHAR(50)    NOT NULL,
        SupplierTier               VARCHAR(30)    NOT NULL,
        SupplierStatus             VARCHAR(20)    NOT NULL,
        SupplierRisk               VARCHAR(10)    NOT NULL,
        CriticalSupplierFlag       BIT            NOT NULL CONSTRAINT DF_Supplier_CriticalFlag DEFAULT (0),
        StandardLeadTimeDays       INT            NOT NULL,
        PaymentTermsDays           INT            NOT NULL,
        Region                     VARCHAR(30)    NOT NULL,
        Country                    VARCHAR(60)    NOT NULL,
        StateProvince              VARCHAR(60)    NOT NULL,
        City                       VARCHAR(60)    NOT NULL,
        CountryCode                CHAR(2)        NOT NULL,
        ActiveFlag                 BIT            NOT NULL CONSTRAINT DF_Supplier_ActiveFlag DEFAULT (1),
        CreatedDateTime            DATETIME2(0)   NOT NULL CONSTRAINT DF_Supplier_Created DEFAULT (SYSDATETIME()),
        ModifiedDateTime           DATETIME2(0)   NOT NULL CONSTRAINT DF_Supplier_Modified DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_Supplier PRIMARY KEY (SupplierID),

        CONSTRAINT CK_Supplier_Category
            CHECK (SupplierCategory IN
            ('Raw Material','Machined Component','Cast Component','Forged Component',
             'Electrical Component','Electronic Component','Rubber & Polymer',
             'Bearings & Seals','Packaging','Other Component')),

        CONSTRAINT CK_Supplier_Tier
            CHECK (SupplierTier IN ('Strategic','Tier 1','Tier 2','Standard')),

        CONSTRAINT CK_Supplier_Status
            CHECK (SupplierStatus IN ('Preferred','Approved','Conditional')),

        CONSTRAINT CK_Supplier_Risk
            CHECK (SupplierRisk IN ('Low','Medium','High')),

        CONSTRAINT CK_Supplier_Region
            CHECK (Region IN ('North America','Europe','Asia Pacific','Middle East')),

        CONSTRAINT CK_Supplier_LeadTime CHECK (StandardLeadTimeDays >= 0),
        CONSTRAINT CK_Supplier_PaymentTerms CHECK (PaymentTermsDays >= 0)
    );

    PRINT 'Created dbo.Supplier';
END;
GO


/*------------------------------------------------------------------------------
  2.3 dbo.Customer
  Grain: one row per customer / business account
------------------------------------------------------------------------------*/

IF OBJECT_ID(N'dbo.Customer', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Customer
    (
        CustomerID                 VARCHAR(20)    NOT NULL,
        CustomerName               VARCHAR(150)   NOT NULL,
        CustomerType                VARCHAR(40)    NOT NULL,
        CustomerSegment             VARCHAR(20)    NOT NULL,
        CreditTermsDays             INT            NOT NULL,
        Region                      VARCHAR(30)    NOT NULL,
        Country                     VARCHAR(60)    NOT NULL,
        StateProvince               VARCHAR(60)    NOT NULL,
        City                        VARCHAR(60)    NOT NULL,
        CountryCode                 CHAR(2)        NOT NULL,
        ActiveFlag                  BIT            NOT NULL CONSTRAINT DF_Customer_ActiveFlag DEFAULT (1),
        CreatedDateTime             DATETIME2(0)   NOT NULL CONSTRAINT DF_Customer_Created DEFAULT (SYSDATETIME()),
        ModifiedDateTime            DATETIME2(0)   NOT NULL CONSTRAINT DF_Customer_Modified DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_Customer PRIMARY KEY (CustomerID),

        CONSTRAINT CK_Customer_Type
            CHECK (CustomerType IN
            ('OEM','Tier-1 Manufacturer','Distributor','Aftermarket Distributor','Export Customer')),

        CONSTRAINT CK_Customer_Segment
            CHECK (CustomerSegment IN ('Strategic','Key','Standard')),

        CONSTRAINT CK_Customer_Region
            CHECK (Region IN ('North America','Europe','Asia Pacific','Middle East')),

        CONSTRAINT CK_Customer_CreditTerms CHECK (CreditTermsDays >= 0)
    );

    PRINT 'Created dbo.Customer';
END;
GO


/*------------------------------------------------------------------------------
  2.4 dbo.Warehouse
  Grain: one row per warehouse / distribution location
------------------------------------------------------------------------------*/

IF OBJECT_ID(N'dbo.Warehouse', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Warehouse
    (
        WarehouseID                VARCHAR(20)    NOT NULL,
        WarehouseName               VARCHAR(120)   NOT NULL,
        WarehouseType                VARCHAR(30)    NOT NULL,
        Region                       VARCHAR(30)    NOT NULL,
        Country                      VARCHAR(60)    NOT NULL,
        StateProvince                VARCHAR(60)    NOT NULL,
        City                         VARCHAR(60)    NOT NULL,
        CountryCode                  CHAR(2)        NOT NULL,
        CapacityUnits                INT            NOT NULL,
        ActiveFlag                   BIT            NOT NULL CONSTRAINT DF_Warehouse_ActiveFlag DEFAULT (1),
        CreatedDateTime               DATETIME2(0)   NOT NULL CONSTRAINT DF_Warehouse_Created DEFAULT (SYSDATETIME()),
        ModifiedDateTime              DATETIME2(0)   NOT NULL CONSTRAINT DF_Warehouse_Modified DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_Warehouse PRIMARY KEY (WarehouseID),

        CONSTRAINT CK_Warehouse_Type
            CHECK (WarehouseType IN
            ('Raw Material Warehouse','Finished Goods Warehouse','Distribution Center','Central Warehouse')),

        CONSTRAINT CK_Warehouse_Region
            CHECK (Region IN ('North America','Europe','Asia Pacific','Middle East')),

        CONSTRAINT CK_Warehouse_Capacity CHECK (CapacityUnits >= 0)
    );

    PRINT 'Created dbo.Warehouse';
END;
GO


/*------------------------------------------------------------------------------
  2.5 dbo.Carrier
  Grain: one row per logistics carrier
------------------------------------------------------------------------------*/

IF OBJECT_ID(N'dbo.Carrier', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Carrier
    (
        CarrierID                  VARCHAR(20)    NOT NULL,
        CarrierName                 VARCHAR(120)   NOT NULL,
        CarrierType                  VARCHAR(20)    NOT NULL,
        ServiceLevel                 VARCHAR(20)    NOT NULL,
        Coverage                     VARCHAR(20)    NOT NULL,
        CarrierRating                 VARCHAR(20)    NOT NULL,
        ContractType                  VARCHAR(30)    NOT NULL,
        PrimaryRegion                 VARCHAR(30)    NOT NULL,
        ActiveFlag                   BIT            NOT NULL CONSTRAINT DF_Carrier_ActiveFlag DEFAULT (1),
        CreatedDateTime               DATETIME2(0)   NOT NULL CONSTRAINT DF_Carrier_Created DEFAULT (SYSDATETIME()),
        ModifiedDateTime              DATETIME2(0)   NOT NULL CONSTRAINT DF_Carrier_Modified DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_Carrier PRIMARY KEY (CarrierID),

        CONSTRAINT CK_Carrier_Type
            CHECK (CarrierType IN ('Road','Rail','Air','Ocean','Multi-Modal')),

        CONSTRAINT CK_Carrier_ServiceLevel
            CHECK (ServiceLevel IN ('Economy','Standard','Express','Dedicated')),

        CONSTRAINT CK_Carrier_Coverage
            CHECK (Coverage IN ('Regional','National','International','Global')),

        CONSTRAINT CK_Carrier_Rating
            CHECK (CarrierRating IN ('Preferred','Approved','Backup')),

        CONSTRAINT CK_Carrier_ContractType
            CHECK (ContractType IN ('Annual Contract','Multi-Year Contract','Spot','Dedicated')),

        CONSTRAINT CK_Carrier_PrimaryRegion
            CHECK (PrimaryRegion IN ('North America','Europe','Asia Pacific','Middle East','Global'))
    );

    PRINT 'Created dbo.Carrier';
END;
GO


/*==============================================================================
  STEP 3 - PROCUREMENT TABLES
==============================================================================*/


/*------------------------------------------------------------------------------
  3.1 dbo.PurchaseOrder
  Grain: one purchase-order header
------------------------------------------------------------------------------*/

IF OBJECT_ID(N'dbo.PurchaseOrder', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.PurchaseOrder
    (
        PurchaseOrderID              VARCHAR(30)    NOT NULL,
        SupplierID                   VARCHAR(20)    NOT NULL,
        DeliveryWarehouseID          VARCHAR(20)    NOT NULL,
        OrderDate                    DATE           NOT NULL,
        RequestedDeliveryDate        DATE           NOT NULL,
        PromisedDeliveryDate         DATE           NOT NULL,
        PurchaseType                  VARCHAR(30)    NOT NULL,
        Priority                      VARCHAR(20)    NOT NULL,
        CurrencyCode                  CHAR(3)        NOT NULL CONSTRAINT DF_PO_Currency DEFAULT ('USD'),
        POStatus                      VARCHAR(30)    NOT NULL,
        BuyerGroup                    VARCHAR(40)    NOT NULL,
        CreatedDateTime                DATETIME2(0)   NOT NULL CONSTRAINT DF_PO_Created DEFAULT (SYSDATETIME()),
        ModifiedDateTime               DATETIME2(0)   NOT NULL CONSTRAINT DF_PO_Modified DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_PurchaseOrder PRIMARY KEY (PurchaseOrderID),

        CONSTRAINT FK_PO_Supplier FOREIGN KEY (SupplierID) REFERENCES dbo.Supplier(SupplierID),
        CONSTRAINT FK_PO_Warehouse FOREIGN KEY (DeliveryWarehouseID) REFERENCES dbo.Warehouse(WarehouseID),

        CONSTRAINT CK_PO_PurchaseType
            CHECK (PurchaseType IN ('Regular','Contract','Urgent','Spot Purchase')),

        CONSTRAINT CK_PO_BuyerGroup
            CHECK (BuyerGroup IN
            ('Raw Materials','Mechanical Components','Electrical & Electronics',
             'Bearings & Seals','Packaging','General Procurement')),

        CONSTRAINT CK_PO_Priority CHECK (Priority IN ('Standard','High','Urgent')),

        CONSTRAINT CK_PO_Status
            CHECK (POStatus IN ('Open','Partially Received','Received','Cancelled')),

        CONSTRAINT CK_PO_CurrencyCode CHECK (CurrencyCode = 'USD'),
        CONSTRAINT CK_PO_RequestedDate CHECK (RequestedDeliveryDate >= OrderDate)
    );

    PRINT 'Created dbo.PurchaseOrder';
END;
GO


/*------------------------------------------------------------------------------
  3.2 dbo.PurchaseOrderLine
  Grain: one Product / Material line per Purchase Order
  Invariant enforced by Python and mirrored here: OpenQuantity = OrderedQuantity
  - ReceivedQuantity, where ReceivedQuantity is the ACCEPTED-TO-DATE cumulative
  total at the line level (distinct from GoodsReceipt.PhysicalReceivedQuantity
  below, which is a per-event, pre-inspection physical quantity).
------------------------------------------------------------------------------*/

IF OBJECT_ID(N'dbo.PurchaseOrderLine', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.PurchaseOrderLine
    (
        PurchaseOrderLineID          VARCHAR(40)    NOT NULL,
        PurchaseOrderID               VARCHAR(30)    NOT NULL,
        ProductID                     VARCHAR(20)    NOT NULL,
        OrderedQuantity                INT            NOT NULL,
        ReceivedQuantity               INT            NOT NULL CONSTRAINT DF_POL_Received DEFAULT (0),
        OpenQuantity                   INT            NOT NULL,
        UnitCost                       DECIMAL(18,2)  NOT NULL,
        LineAmount                     DECIMAL(18,2)  NOT NULL,
        LineStatus                     VARCHAR(30)    NOT NULL,
        CreatedDateTime                 DATETIME2(0)   NOT NULL CONSTRAINT DF_POL_Created DEFAULT (SYSDATETIME()),
        ModifiedDateTime                DATETIME2(0)   NOT NULL CONSTRAINT DF_POL_Modified DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_PurchaseOrderLine PRIMARY KEY (PurchaseOrderLineID),

        CONSTRAINT FK_POL_PurchaseOrder FOREIGN KEY (PurchaseOrderID) REFERENCES dbo.PurchaseOrder(PurchaseOrderID),
        CONSTRAINT FK_POL_Product FOREIGN KEY (ProductID) REFERENCES dbo.Product(ProductID),

        CONSTRAINT CK_POL_OrderedQty CHECK (OrderedQuantity > 0),
        CONSTRAINT CK_POL_ReceivedQty CHECK (ReceivedQuantity >= 0 AND ReceivedQuantity <= OrderedQuantity),
        CONSTRAINT CK_POL_OpenQty CHECK (OpenQuantity = OrderedQuantity - ReceivedQuantity),
        CONSTRAINT CK_POL_UnitCost CHECK (UnitCost >= 0),
        CONSTRAINT CK_POL_LineAmount CHECK (LineAmount >= 0),

        CONSTRAINT CK_POL_LineStatus
            CHECK (LineStatus IN ('Open','Partially Received','Received','Cancelled'))
    );

    PRINT 'Created dbo.PurchaseOrderLine';
END;
GO


/*------------------------------------------------------------------------------
  3.3 dbo.GoodsReceipt
  Grain: one receipt event against one Purchase Order Line
  PhysicalReceivedQuantity = physical quantity delivered in THIS event, before
  inspection -- NOT the same value as PurchaseOrderLine.ReceivedQuantity above.
------------------------------------------------------------------------------*/

IF OBJECT_ID(N'dbo.GoodsReceipt', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.GoodsReceipt
    (
        GoodsReceiptID                VARCHAR(30)    NOT NULL,
        PurchaseOrderLineID           VARCHAR(40)    NOT NULL,
        ProductID                     VARCHAR(20)    NOT NULL,
        WarehouseID                   VARCHAR(20)    NOT NULL,
        ReceiptDateTime                DATETIME2(0)   NOT NULL,
        PhysicalReceivedQuantity       INT            NOT NULL,
        AcceptedQuantity                INT            NOT NULL,
        RejectedQuantity                INT            NOT NULL,
        ReceiptStatus                  VARCHAR(40)    NOT NULL,
        ReceiptSource                  VARCHAR(40)    NOT NULL CONSTRAINT DF_GR_Source DEFAULT ('Supplier Delivery'),
        CreatedDateTime                 DATETIME2(0)   NOT NULL CONSTRAINT DF_GR_Created DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_GoodsReceipt PRIMARY KEY (GoodsReceiptID),

        CONSTRAINT FK_GR_PurchaseOrderLine FOREIGN KEY (PurchaseOrderLineID) REFERENCES dbo.PurchaseOrderLine(PurchaseOrderLineID),
        CONSTRAINT FK_GR_Product FOREIGN KEY (ProductID) REFERENCES dbo.Product(ProductID),
        CONSTRAINT FK_GR_Warehouse FOREIGN KEY (WarehouseID) REFERENCES dbo.Warehouse(WarehouseID),

        CONSTRAINT CK_GR_PhysicalReceivedQty CHECK (PhysicalReceivedQuantity >= 0),
        CONSTRAINT CK_GR_AcceptedQty CHECK (AcceptedQuantity >= 0),
        CONSTRAINT CK_GR_RejectedQty CHECK (RejectedQuantity >= 0),

        CONSTRAINT CK_GR_QuantityBalance
            CHECK (AcceptedQuantity + RejectedQuantity = PhysicalReceivedQuantity),

        CONSTRAINT CK_GR_Status
            CHECK (ReceiptStatus IN ('Accepted','Accepted with Rejection','Rejected'))
    );

    PRINT 'Created dbo.GoodsReceipt';
END;
GO


/*==============================================================================
  STEP 4 - INVENTORY TABLE
==============================================================================*/


/*------------------------------------------------------------------------------
  4.1 dbo.InventoryBalance
  Grain: current Product x Warehouse snapshot (not every product is stocked at
  every warehouse -- this is intentionally a sparse table, not a full cross-join).
  Invariant: AvailableQuantity = OnHandQuantity - ReservedQuantity, floored at 0.
------------------------------------------------------------------------------*/

IF OBJECT_ID(N'dbo.InventoryBalance', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.InventoryBalance
    (
        ProductID                    VARCHAR(20)    NOT NULL,
        WarehouseID                   VARCHAR(20)    NOT NULL,
        OnHandQuantity                 INT            NOT NULL CONSTRAINT DF_InvBal_OnHand DEFAULT (0),
        ReservedQuantity                INT            NOT NULL CONSTRAINT DF_InvBal_Reserved DEFAULT (0),
        AvailableQuantity                INT            NOT NULL CONSTRAINT DF_InvBal_Available DEFAULT (0),
        InTransitQuantity                INT            NOT NULL CONSTRAINT DF_InvBal_InTransit DEFAULT (0),
        AverageUnitCost                  DECIMAL(18,2)  NOT NULL,
        LastMovementDateTime             DATETIME2(0)   NOT NULL,
        ModifiedDateTime                 DATETIME2(0)   NOT NULL CONSTRAINT DF_InvBal_Modified DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_InventoryBalance PRIMARY KEY (ProductID, WarehouseID),

        CONSTRAINT FK_InvBal_Product FOREIGN KEY (ProductID) REFERENCES dbo.Product(ProductID),
        CONSTRAINT FK_InvBal_Warehouse FOREIGN KEY (WarehouseID) REFERENCES dbo.Warehouse(WarehouseID),

        CONSTRAINT CK_InvBal_OnHand CHECK (OnHandQuantity >= 0),
        CONSTRAINT CK_InvBal_Reserved CHECK (ReservedQuantity >= 0),
        CONSTRAINT CK_InvBal_Available CHECK (AvailableQuantity >= 0),
        CONSTRAINT CK_InvBal_InTransit CHECK (InTransitQuantity >= 0),
        CONSTRAINT CK_InvBal_AvgCost CHECK (AverageUnitCost >= 0),
        CONSTRAINT CK_InvBal_AvailableFormula
            CHECK (AvailableQuantity = CASE WHEN OnHandQuantity - ReservedQuantity < 0 THEN 0 ELSE OnHandQuantity - ReservedQuantity END)
    );

    PRINT 'Created dbo.InventoryBalance';
END;
GO


/*==============================================================================
  STEP 5 - SALES TABLES
==============================================================================*/


/*------------------------------------------------------------------------------
  5.1 dbo.SalesOrder
  Grain: one Customer Sales Order header
  NOTE: SalesChannel is a plain descriptive string here (not a dimension-table
  FK) -- it is fully determined by CustomerType (see
  reference/business_rules.py: SALES_CHANNEL_BY_CUSTOMER_TYPE), so a separate
  SalesChannel table would just be a 1:1 lookup with no independent grain.
------------------------------------------------------------------------------*/

IF OBJECT_ID(N'dbo.SalesOrder', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.SalesOrder
    (
        SalesOrderID                  VARCHAR(30)    NOT NULL,
        CustomerID                    VARCHAR(20)    NOT NULL,
        OrderDate                     DATE           NOT NULL,
        RequestedDeliveryDate         DATE           NOT NULL,
        Priority                       VARCHAR(20)    NOT NULL,
        CurrencyCode                   CHAR(3)        NOT NULL CONSTRAINT DF_SO_Currency DEFAULT ('USD'),
        OrderStatus                    VARCHAR(30)    NOT NULL,
        OrderType                      VARCHAR(30)    NOT NULL,
        SalesChannel                   VARCHAR(30)    NOT NULL,
        CreatedDateTime                 DATETIME2(0)   NOT NULL CONSTRAINT DF_SO_Created DEFAULT (SYSDATETIME()),
        ModifiedDateTime                DATETIME2(0)   NOT NULL CONSTRAINT DF_SO_Modified DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_SalesOrder PRIMARY KEY (SalesOrderID),

        CONSTRAINT FK_SalesOrder_Customer FOREIGN KEY (CustomerID) REFERENCES dbo.Customer(CustomerID),

        CONSTRAINT CK_SalesOrder_Priority CHECK (Priority IN ('Standard','High','Urgent')),

        CONSTRAINT CK_SalesOrder_Status
            CHECK (OrderStatus IN ('Open','Partially Fulfilled','Fulfilled','Backordered','Cancelled')),

        CONSTRAINT CK_SalesOrder_OrderType
            CHECK (OrderType IN ('Standard Order','Rush Order','Contract Order','Replacement Order')),

        CONSTRAINT CK_SalesOrder_Channel
            CHECK (SalesChannel IN ('OEM Direct','Tier-1 Direct','Distributor','Aftermarket','Export')),

        CONSTRAINT CK_SalesOrder_CurrencyCode CHECK (CurrencyCode = 'USD'),
        CONSTRAINT CK_SalesOrder_RequestedDate CHECK (RequestedDeliveryDate >= OrderDate)
    );

    PRINT 'Created dbo.SalesOrder';
END;
GO


/*------------------------------------------------------------------------------
  5.2 dbo.SalesOrderLine
  Grain: one Product line per Sales Order
------------------------------------------------------------------------------*/

IF OBJECT_ID(N'dbo.SalesOrderLine', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.SalesOrderLine
    (
        SalesOrderLineID              VARCHAR(40)    NOT NULL,
        SalesOrderID                  VARCHAR(30)    NOT NULL,
        ProductID                     VARCHAR(20)    NOT NULL,
        FulfillmentWarehouseID         VARCHAR(20)    NOT NULL,
        PromisedDeliveryDate           DATE           NOT NULL,
        OrderQuantity                  INT            NOT NULL,
        FulfilledQuantity               INT            NOT NULL CONSTRAINT DF_SOL_Fulfilled DEFAULT (0),
        BackorderQuantity               INT            NOT NULL CONSTRAINT DF_SOL_Backorder DEFAULT (0),
        UnitPrice                       DECIMAL(18,2)  NOT NULL,
        GrossLineAmount                  DECIMAL(18,2)  NOT NULL,
        DiscountAmount                   DECIMAL(18,2)  NOT NULL CONSTRAINT DF_SOL_Discount DEFAULT (0),
        NetLineAmount                    DECIMAL(18,2)  NOT NULL,
        LineStatus                       VARCHAR(30)    NOT NULL,
        CreatedDateTime                   DATETIME2(0)   NOT NULL CONSTRAINT DF_SOL_Created DEFAULT (SYSDATETIME()),
        ModifiedDateTime                  DATETIME2(0)   NOT NULL CONSTRAINT DF_SOL_Modified DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_SalesOrderLine PRIMARY KEY (SalesOrderLineID),

        CONSTRAINT FK_SOL_SalesOrder FOREIGN KEY (SalesOrderID) REFERENCES dbo.SalesOrder(SalesOrderID),
        CONSTRAINT FK_SOL_Product FOREIGN KEY (ProductID) REFERENCES dbo.Product(ProductID),
        CONSTRAINT FK_SOL_Warehouse FOREIGN KEY (FulfillmentWarehouseID) REFERENCES dbo.Warehouse(WarehouseID),

        CONSTRAINT CK_SOL_OrderQty CHECK (OrderQuantity > 0),
        CONSTRAINT CK_SOL_FulfilledQty CHECK (FulfilledQuantity >= 0 AND FulfilledQuantity <= OrderQuantity),
        CONSTRAINT CK_SOL_BackorderQty CHECK (BackorderQuantity >= 0 AND BackorderQuantity <= OrderQuantity),
        CONSTRAINT CK_SOL_UnitPrice CHECK (UnitPrice >= 0),
        CONSTRAINT CK_SOL_GrossAmount CHECK (GrossLineAmount >= 0),
        CONSTRAINT CK_SOL_Discount CHECK (DiscountAmount >= 0),
        CONSTRAINT CK_SOL_NetAmount CHECK (NetLineAmount >= 0),

        CONSTRAINT CK_SOL_LineStatus
            CHECK (LineStatus IN ('Open','Partially Fulfilled','Fulfilled','Backordered','Cancelled'))
    );

    PRINT 'Created dbo.SalesOrderLine';
END;
GO


/*==============================================================================
  STEP 6 - LOGISTICS TABLES
==============================================================================*/


/*------------------------------------------------------------------------------
  6.1 dbo.Shipment
  Grain: one Shipment header
------------------------------------------------------------------------------*/

IF OBJECT_ID(N'dbo.Shipment', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Shipment
    (
        ShipmentID                     VARCHAR(30)    NOT NULL,
        SalesOrderID                   VARCHAR(30)    NOT NULL,
        CarrierID                      VARCHAR(20)    NOT NULL,
        OriginWarehouseID               VARCHAR(20)    NOT NULL,
        ShipmentDate                    DATE           NOT NULL,
        PromisedDeliveryDate             DATE           NOT NULL,
        ActualDeliveryDate               DATE           NULL,
        ShipmentStatus                   VARCHAR(30)    NOT NULL,
        ShipmentMode                     VARCHAR(20)    NOT NULL,
        ServiceLevel                     VARCHAR(20)    NOT NULL,
        DestinationRegion                 VARCHAR(30)    NOT NULL,
        DestinationCountry                VARCHAR(60)    NOT NULL,
        DestinationStateProvince           VARCHAR(60)    NOT NULL,
        DestinationCity                    VARCHAR(60)    NOT NULL,
        DestinationCountryCode             CHAR(2)        NOT NULL,
        ShippingCost                       DECIMAL(18,2)  NOT NULL,
        ReturnFlag                         BIT            NOT NULL CONSTRAINT DF_Shipment_ReturnFlag DEFAULT (0),
        ReturnReason                       VARCHAR(40)    NOT NULL CONSTRAINT DF_Shipment_ReturnReason DEFAULT ('Not Applicable'),
        CreatedDateTime                     DATETIME2(0)   NOT NULL CONSTRAINT DF_Shipment_Created DEFAULT (SYSDATETIME()),
        ModifiedDateTime                    DATETIME2(0)   NOT NULL CONSTRAINT DF_Shipment_Modified DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_Shipment PRIMARY KEY (ShipmentID),

        CONSTRAINT FK_Shipment_SalesOrder FOREIGN KEY (SalesOrderID) REFERENCES dbo.SalesOrder(SalesOrderID),
        CONSTRAINT FK_Shipment_Carrier FOREIGN KEY (CarrierID) REFERENCES dbo.Carrier(CarrierID),
        CONSTRAINT FK_Shipment_Warehouse FOREIGN KEY (OriginWarehouseID) REFERENCES dbo.Warehouse(WarehouseID),

        CONSTRAINT CK_Shipment_Status
            CHECK (ShipmentStatus IN
            ('Ready to Ship','Dispatched','In Transit','Delivered','Delayed','Cancelled','Returned')),

        CONSTRAINT CK_Shipment_Mode
            CHECK (ShipmentMode IN ('Road','Rail','Air','Ocean','Multi-Modal')),

        CONSTRAINT CK_Shipment_ServiceLevel
            CHECK (ServiceLevel IN ('Economy','Standard','Express','Dedicated')),

        CONSTRAINT CK_Shipment_DestinationRegion
            CHECK (DestinationRegion IN ('North America','Europe','Asia Pacific','Middle East')),

        CONSTRAINT CK_Shipment_ReturnReason
            CHECK (ReturnReason IN
            ('Not Applicable','Damaged','Wrong Product','Quantity Mismatch',
             'Customer Rejected','Delivery Failure','Documentation Issue')),

        CONSTRAINT CK_Shipment_ShippingCost CHECK (ShippingCost >= 0),
        CONSTRAINT CK_Shipment_PromisedDate CHECK (PromisedDeliveryDate >= ShipmentDate),
        CONSTRAINT CK_Shipment_ActualDate CHECK (ActualDeliveryDate IS NULL OR ActualDeliveryDate >= ShipmentDate)
    );

    PRINT 'Created dbo.Shipment';
END;
GO


/*------------------------------------------------------------------------------
  6.2 dbo.ShipmentLine
  Grain: one Product line per Shipment
  ReceivedQuantity is NULL until the parent shipment is Delivered/Returned --
  it records what the customer received, a different concept again from
  PurchaseOrderLine.ReceivedQuantity and GoodsReceipt.PhysicalReceivedQuantity.
------------------------------------------------------------------------------*/

IF OBJECT_ID(N'dbo.ShipmentLine', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.ShipmentLine
    (
        ShipmentLineID                 VARCHAR(40)    NOT NULL,
        ShipmentID                     VARCHAR(30)    NOT NULL,
        SalesOrderLineID                VARCHAR(40)    NOT NULL,
        ProductID                       VARCHAR(20)    NOT NULL,
        ShippedQuantity                  INT            NOT NULL,
        ReceivedQuantity                  INT            NULL,
        CreatedDateTime                   DATETIME2(0)   NOT NULL CONSTRAINT DF_ShipmentLine_Created DEFAULT (SYSDATETIME()),
        ModifiedDateTime                  DATETIME2(0)   NOT NULL CONSTRAINT DF_ShipmentLine_Modified DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_ShipmentLine PRIMARY KEY (ShipmentLineID),

        CONSTRAINT FK_ShipmentLine_Shipment FOREIGN KEY (ShipmentID) REFERENCES dbo.Shipment(ShipmentID),
        CONSTRAINT FK_ShipmentLine_SalesOrderLine FOREIGN KEY (SalesOrderLineID) REFERENCES dbo.SalesOrderLine(SalesOrderLineID),
        CONSTRAINT FK_ShipmentLine_Product FOREIGN KEY (ProductID) REFERENCES dbo.Product(ProductID),

        CONSTRAINT CK_ShipmentLine_ShippedQty CHECK (ShippedQuantity >= 0),
        CONSTRAINT CK_ShipmentLine_ReceivedQty CHECK (ReceivedQuantity IS NULL OR ReceivedQuantity >= 0)
    );

    PRINT 'Created dbo.ShipmentLine';
END;
GO


/*==============================================================================
  STEP 7 - SOURCE INDEXES
  Helps common joins and the ModifiedDateTime-based incremental reads that
  main_incremental_update.py and a future ETL step will both rely on.
==============================================================================*/

USE Manufacturing_Source;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.Product') AND name = N'IX_Product_Category_Subcategory')
    CREATE INDEX IX_Product_Category_Subcategory ON dbo.Product(Category, Subcategory);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.Supplier') AND name = N'IX_Supplier_ModifiedDateTime')
    CREATE INDEX IX_Supplier_ModifiedDateTime ON dbo.Supplier(ModifiedDateTime) INCLUDE (SupplierTier, SupplierStatus, SupplierRisk);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.Customer') AND name = N'IX_Customer_Region')
    CREATE INDEX IX_Customer_Region ON dbo.Customer(Region, Country);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.PurchaseOrder') AND name = N'IX_PurchaseOrder_ModifiedDateTime')
    CREATE INDEX IX_PurchaseOrder_ModifiedDateTime ON dbo.PurchaseOrder(ModifiedDateTime) INCLUDE (OrderDate, SupplierID, POStatus);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.PurchaseOrderLine') AND name = N'IX_PurchaseOrderLine_ModifiedDateTime')
    CREATE INDEX IX_PurchaseOrderLine_ModifiedDateTime ON dbo.PurchaseOrderLine(ModifiedDateTime) INCLUDE (PurchaseOrderID, ProductID);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.GoodsReceipt') AND name = N'IX_GoodsReceipt_POL_ReceiptDate')
    CREATE INDEX IX_GoodsReceipt_POL_ReceiptDate ON dbo.GoodsReceipt(PurchaseOrderLineID, ReceiptDateTime);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.InventoryBalance') AND name = N'IX_InventoryBalance_Warehouse')
    CREATE INDEX IX_InventoryBalance_Warehouse ON dbo.InventoryBalance(WarehouseID, ProductID);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.SalesOrder') AND name = N'IX_SalesOrder_ModifiedDateTime')
    CREATE INDEX IX_SalesOrder_ModifiedDateTime ON dbo.SalesOrder(ModifiedDateTime) INCLUDE (OrderDate, CustomerID, OrderStatus);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.SalesOrderLine') AND name = N'IX_SalesOrderLine_ModifiedDateTime')
    CREATE INDEX IX_SalesOrderLine_ModifiedDateTime ON dbo.SalesOrderLine(ModifiedDateTime) INCLUDE (SalesOrderID, ProductID, FulfillmentWarehouseID);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.Shipment') AND name = N'IX_Shipment_ModifiedDateTime')
    CREATE INDEX IX_Shipment_ModifiedDateTime ON dbo.Shipment(ModifiedDateTime) INCLUDE (ShipmentDate, SalesOrderID, CarrierID, ShipmentStatus);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.ShipmentLine') AND name = N'IX_ShipmentLine_Shipment')
    CREATE INDEX IX_ShipmentLine_Shipment ON dbo.ShipmentLine(ShipmentID);
GO

/*
HINGLISH:
Indexes isliye rakhe hain taaki ModifiedDateTime-based incremental reads aur
common FK joins unnecessarily full table scan na karein.
*/


/*==============================================================================
  STEP 8 - VALIDATION QUERIES
==============================================================================*/

USE Manufacturing_Source;
GO

PRINT '==============================================================';
PRINT 'Manufacturing_Source setup validation';
PRINT '==============================================================';

-- 1. Confirm database
SELECT DB_NAME() AS CurrentDatabase;
GO

-- 2. Confirm all 13 source tables live in dbo
SELECT s.name AS SchemaName, t.name AS TableName
FROM sys.tables t
INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
WHERE s.name = 'dbo'
ORDER BY t.name;
GO

-- 3. Expected source table count = 13
SELECT COUNT(*) AS SourceTableCount
FROM sys.tables t
INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
WHERE s.name = 'dbo';
GO

-- 4. Confirm foreign keys
SELECT
    fk.name AS ForeignKeyName,
    OBJECT_NAME(fk.parent_object_id) AS ChildTable,
    OBJECT_NAME(fk.referenced_object_id) AS ParentTable
FROM sys.foreign_keys fk
WHERE OBJECT_SCHEMA_NAME(fk.parent_object_id) = 'dbo'
ORDER BY ChildTable, ForeignKeyName;
GO


/*==============================================================================
  EXPECTED STRUCTURE AFTER SUCCESS
==============================================================================

Manufacturing_Source (all objects in dbo)
|
+-- Product
+-- Supplier
+-- Customer
+-- Warehouse
+-- Carrier
+-- PurchaseOrder
+-- PurchaseOrderLine
+-- GoodsReceipt
+-- InventoryBalance
+-- SalesOrder
+-- SalesOrderLine
+-- Shipment
+-- ShipmentLine


NEXT STEP
---------
Once this script has run successfully (13 tables, 0 unexpected extras), load
data from the Python project:

    cd "D:\11_SQL\Manufacturing_Supply_Chain_Source"
    pip install pyodbc
    python main_initial_load.py --target sql --clear-sql

main_initial_load.py runs its own column-level schema check (validate_schema()
in loaders/sql_loader.py) before writing a single row, and refuses to load if
anything here drifts from EXPECTED_COLUMNS -- so a mismatch fails loudly
instead of silently loading wrong data. After the initial load, recurring
updates come from:

    python main_incremental_update.py

FINAL RULE
----------
Python -> Manufacturing_Source only. Do not create DW/mart objects here.

HINGLISH:
Python source system simulate karega; DW cleaning/transformation baad mein
alag SQL Server ETL se hoga. Yeh separation interview mein explain karna easy
hoga.
================================================================================
*/
