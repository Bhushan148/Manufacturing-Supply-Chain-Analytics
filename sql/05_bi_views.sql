/*==============================================================================
  05_bi_views.sql  --  BI CONSUMPTION LAYER (schema: bi)
------------------------------------------------------------------------------
  Purpose: a thin, business-facing CONTRACT on top of mart.* that Power BI,
  validation, and ad-hoc analysis all consume. Each view:
    - keeps surrogate + natural KEYS (needed for model relationships / joins)
    - RENAMES columns to friendly business names
    - HIDES technical/audit columns (BatchID, LoadDateTime, DW and Source stamps)
    - is kept THIN and FOLDABLE (projection + alias only -- no re-transformation;
      all shaping logic already lives in stg -> mart)

  Decouples physical mart tables from consumers: the mart can change underneath
  without touching reports/validation, and different consumers can get their own
  tailored views without exposing or altering the mart.

  Idempotent: CREATE OR ALTER VIEW. Safe to re-run.
  Note: created under QUOTED_IDENTIFIER ON (required because mart.DimSupplier
  carries a filtered index).
==============================================================================*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF SCHEMA_ID(N'bi') IS NULL
    EXEC(N'CREATE SCHEMA bi AUTHORIZATION dbo');
GO

/*------------------------------------------------------------------------------ DIMENSIONS */

CREATE OR ALTER VIEW bi.DimDate AS
SELECT
    DateKey,
    FullDate              AS [Date],
    DayOfWeekNumber       AS [Day Of Week Number],
    DayName               AS [Day Name],
    DayOfMonth            AS [Day Of Month],
    DayOfYear             AS [Day Of Year],
    WeekOfYear            AS [Week Of Year],
    MonthNumber           AS [Month Number],
    MonthName             AS [Month Name],
    YearMonth             AS [Year-Month],
    Quarter               AS [Quarter Number],
    QuarterName           AS [Quarter],
    Year                  AS [Year],
    IsWeekend             AS [Is Weekend],
    IsMonthEnd            AS [Is Month End],
    IsQuarterEnd          AS [Is Quarter End],
    IsYearEnd             AS [Is Year End]
FROM mart.DimDate;
GO

CREATE OR ALTER VIEW bi.DimProduct AS
SELECT
    ProductKey,
    ProductID             AS [Product ID],
    SKU                   AS [SKU],
    ProductName           AS [Product Name],
    Category              AS [Category],
    Subcategory           AS [Subcategory],
    ProductType           AS [Product Type],
    MakeBuyType           AS [Make/Buy],
    VehicleSegment        AS [Vehicle Segment],
    UnitOfMeasure         AS [Unit Of Measure],
    ABCClass              AS [ABC Class],
    StandardCost          AS [Standard Cost],
    ListPrice             AS [List Price],
    SafetyStockQuantity   AS [Safety Stock Quantity],
    ReorderLevel          AS [Reorder Level],
    MaximumStockQuantity  AS [Maximum Stock Quantity],
    ProductStatus         AS [Product Status],
    LaunchDate            AS [Launch Date],
    DiscontinuedDate      AS [Discontinued Date],
    ActiveFlag            AS [Active Flag]
FROM mart.DimProduct;
GO

/* SCD2: all versions exposed with Is Current flag; model relates on SupplierKey. */
CREATE OR ALTER VIEW bi.DimSupplier AS
SELECT
    SupplierKey,
    SupplierID            AS [Supplier ID],
    SupplierName          AS [Supplier Name],
    SupplierCategory      AS [Supplier Category],
    SupplierTier          AS [Supplier Tier],
    SupplierStatus        AS [Supplier Status],
    SupplierRisk          AS [Supplier Risk],
    CriticalSupplierFlag  AS [Critical Supplier Flag],
    StandardLeadTimeDays  AS [Standard Lead Time Days],
    PaymentTermsDays      AS [Payment Terms Days],
    Region                AS [Region],
    Country               AS [Country],
    StateProvince         AS [State/Province],
    City                  AS [City],
    CountryCode           AS [Country Code],
    ActiveFlag            AS [Active Flag],
    EffectiveStartDateTime AS [Effective Start],
    EffectiveEndDateTime   AS [Effective End],
    IsCurrent             AS [Is Current]
FROM mart.DimSupplier;
GO

CREATE OR ALTER VIEW bi.DimCustomer AS
SELECT
    CustomerKey,
    CustomerID            AS [Customer ID],
    CustomerName          AS [Customer Name],
    CustomerType          AS [Customer Type],
    CustomerSegment       AS [Customer Segment],
    CreditTermsDays       AS [Credit Terms Days],
    Region                AS [Region],
    Country               AS [Country],
    StateProvince         AS [State/Province],
    City                  AS [City],
    CountryCode           AS [Country Code],
    ActiveFlag            AS [Active Flag]
FROM mart.DimCustomer;
GO

CREATE OR ALTER VIEW bi.DimWarehouse AS
SELECT
    WarehouseKey,
    WarehouseID           AS [Warehouse ID],
    WarehouseName         AS [Warehouse Name],
    WarehouseType         AS [Warehouse Type],
    Region                AS [Region],
    Country               AS [Country],
    StateProvince         AS [State/Province],
    City                  AS [City],
    CountryCode           AS [Country Code],
    CapacityUnits         AS [Capacity Units],
    ActiveFlag            AS [Active Flag]
FROM mart.DimWarehouse;
GO

CREATE OR ALTER VIEW bi.DimCarrier AS
SELECT
    CarrierKey,
    CarrierID             AS [Carrier ID],
    CarrierName           AS [Carrier Name],
    CarrierType           AS [Carrier Type],
    ServiceLevel          AS [Service Level],
    Coverage              AS [Coverage],
    CarrierRating         AS [Carrier Rating],
    ContractType          AS [Contract Type],
    PrimaryRegion         AS [Primary Region],
    ActiveFlag            AS [Active Flag]
FROM mart.DimCarrier;
GO

/*------------------------------------------------------------------------------ FACTS */

CREATE OR ALTER VIEW bi.FactSalesOrder AS
SELECT
    SalesOrderID          AS [Sales Order ID],
    SalesOrderLineID      AS [Sales Order Line ID],
    OrderDateKey,
    RequestedDeliveryDateKey,
    PromisedDeliveryDateKey,
    CustomerKey,
    ProductKey,
    WarehouseKey,
    Priority              AS [Priority],
    OrderStatus           AS [Order Status],
    OrderType             AS [Order Type],
    SalesChannel          AS [Sales Channel],
    LineStatus            AS [Line Status],
    OrderQuantity         AS [Order Quantity],
    FulfilledQuantity     AS [Fulfilled Quantity],
    BackorderQuantity     AS [Backorder Quantity],
    UnitPrice             AS [Unit Price],
    GrossLineAmount       AS [Gross Line Amount],
    DiscountAmount        AS [Discount Amount],
    NetLineAmount         AS [Net Line Amount],
    FillRatePercent       AS [Fill Rate Percent]
FROM mart.FactSalesOrder;
GO

CREATE OR ALTER VIEW bi.FactPurchaseOrder AS
SELECT
    PurchaseOrderID       AS [Purchase Order ID],
    PurchaseOrderLineID   AS [Purchase Order Line ID],
    OrderDateKey,
    RequestedDeliveryDateKey,
    PromisedDeliveryDateKey,
    ActualReceiptDateKey,
    SupplierKey,
    ProductKey,
    WarehouseKey,
    PurchaseType          AS [Purchase Type],
    Priority              AS [Priority],
    POStatus              AS [PO Status],
    BuyerGroup            AS [Buyer Group],
    LineStatus            AS [Line Status],
    DeliveryStatus        AS [Delivery Status],
    OrderedQuantity       AS [Ordered Quantity],
    ReceivedQuantity      AS [Received Quantity],
    OpenQuantity          AS [Open Quantity],
    AcceptedQuantity      AS [Accepted Quantity],
    RejectedQuantity      AS [Rejected Quantity],
    UnitCost              AS [Unit Cost],
    LineAmount            AS [Line Amount],
    SupplierDelayDays     AS [Supplier Delay Days]
FROM mart.FactPurchaseOrder;
GO

CREATE OR ALTER VIEW bi.FactShipment AS
SELECT
    ShipmentID            AS [Shipment ID],
    ShipmentLineID        AS [Shipment Line ID],
    SalesOrderID          AS [Sales Order ID],
    SalesOrderLineID      AS [Sales Order Line ID],
    ShipmentDateKey,
    PromisedDeliveryDateKey,
    ActualDeliveryDateKey,
    CarrierKey,
    WarehouseKey,
    CustomerKey,
    ProductKey,
    ShipmentStatus        AS [Shipment Status],
    ShipmentMode          AS [Shipment Mode],
    ServiceLevel          AS [Service Level],
    DestinationRegion     AS [Destination Region],
    DestinationCountry    AS [Destination Country],
    DestinationStateProvince AS [Destination State/Province],
    DestinationCity       AS [Destination City],
    ReturnFlag            AS [Return Flag],
    ReturnReason          AS [Return Reason],
    DeliveryStatus        AS [Delivery Status],
    ShippedQuantity       AS [Shipped Quantity],
    ReceivedQuantity      AS [Received Quantity],
    ShippingCost          AS [Shipping Cost],
    DeliveryDelayDays     AS [Delivery Delay Days]
FROM mart.FactShipment;
GO

CREATE OR ALTER VIEW bi.FactInventorySnapshot AS
SELECT
    SnapshotDateKey,
    ProductKey,
    WarehouseKey,
    OnHandQuantity        AS [On Hand Quantity],
    ReservedQuantity      AS [Reserved Quantity],
    AvailableQuantity     AS [Available Quantity],
    InTransitQuantity     AS [In Transit Quantity],
    AverageUnitCost       AS [Average Unit Cost],
    InventoryValue        AS [Inventory Value],
    DaysSinceLastMovement AS [Days Since Last Movement],
    MovementClass         AS [Movement Class],
    StockStatus           AS [Stock Status],
    LastMovementDateTime  AS [Last Movement DateTime]
FROM mart.FactInventorySnapshot;
GO

PRINT 'Created/updated 10 bi.* views (6 dims + 4 facts).';
GO
