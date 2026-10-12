/*
================================================================================
FILE: 03_ETL_StoredProcedures.sql
PROJECT: Automotive Components Manufacturing & Supply Chain Analytics
DATABASE: Manufacturing_DW
PURPOSE: ETL stored procedures -- raw -> stg -> mart, plus the orchestrator.

PREREQUISITE
------------
02_Manufacturing_DW_Setup.sql must have already run successfully (creates
every table these procedures read from or write to).

NAMING CONVENTION
------------------
etl.usp_Load_<layer>_<Table>  -- one verb, one layer, one table.
etl.usp_RunFullETL            -- orchestrator, calls every usp_Load_* in
                                  dependency order inside one etl.BatchRun.

HOW EACH LAYER WORKS
---------------------
raw   MERGE upsert straight from Manufacturing_Source.dbo.<Table>, filtered
      by the etl.LoadControl watermark (ModifiedDateTime, or CreatedDateTime
      for the two tables that have no ModifiedDateTime -- see the DDL
      comments in 02_Manufacturing_DW_Setup.sql). Every touched row is
      tagged with @BatchID. The watermark only advances past rows that were
      actually processed.

stg   Reads only the rows raw just touched (raw.<Table> WHERE BatchID =
      @BatchID) and MERGE-upserts into stg.<Table>. Tables with a business
      reason to validate (an FK to a parent table, or a quantity-reconciliation
      rule) run real checks here: failing rows are logged to
      etl.RejectedRows and excluded, not silently dropped. Tables with
      nothing to validate against (Product, Supplier, Customer, Warehouse,
      Carrier -- no FK dependencies) just get light standardization
      (trimmed strings).

stg   Also reads the FULL raw table each run (not batch-filtered) rather
      than raw.<Table> WHERE BatchID = @BatchID -- an earlier version
      filtered by batch, but that breaks the moment a run is interrupted
      between the raw and stg phases (raw's watermark already advanced, so
      the next run's raw step finds nothing new, but stg never got to
      process what raw already landed). Filtering the stg MERGE's WHEN
      MATCHED branch on SourceModifiedDateTime having changed keeps a
      full-table pass cheap.

mart  Rebuilds from the FULL stg tables each run (not batch-filtered). At
      this project's volume (~110K rows, portfolio scale) a full MERGE
      rebuild runs in well under a second and is far simpler than tracking
      "did this fact's own row change, or did a dimension/parent it depends
      on change" -- that dependency-invalidation logic is real complexity
      that would only pay for itself at a much larger scale than this
      project will ever reach. mart.FactInventorySnapshot is the one
      exception: it is a periodic snapshot fact, so it DELETEs today's
      SnapshotDateKey (making a same-day rerun idempotent) and re-INSERTs,
      rather than MERGE-upserting.

Every procedure writes one etl.BatchAudit row (Running -> Succeeded/Failed)
so a failure is diagnosable from etl.BatchAudit + etl.RejectedRows without
re-running anything.

HINGLISH:
Yeh teesra file hai -- ab actual ETL logic likh rahe hain. Har table ke liye
teen procedures: raw (jaisa-hai load), stg (validate/clean), aur inn dono ke
upar mart (dimensions + facts, business calculations ke saath). Sab kuch
etl.usp_RunFullETL se ek hi call mein chalta hai, dependency order mein.
================================================================================
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

USE Manufacturing_DW;
GO


/*==============================================================================
  STEP 1 - RAW LOAD PROCEDURES (13)
==============================================================================*/

CREATE OR ALTER PROCEDURE etl.usp_Load_raw_Product
    @BatchID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Watermark DATETIME2(0), @SourceCount INT, @TargetCount INT, @BatchStepID BIGINT;
    SELECT @Watermark = LastLoadedModifiedDateTime FROM etl.LoadControl WHERE TableName = 'Product';

    INSERT INTO etl.BatchAudit (BatchID, LayerName, TableName) VALUES (@BatchID, 'raw', 'Product');
    SET @BatchStepID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @SourceCount = COUNT(*) FROM Manufacturing_Source.dbo.Product WHERE ModifiedDateTime > @Watermark;

        MERGE raw.Product AS tgt
        USING (SELECT * FROM Manufacturing_Source.dbo.Product WHERE ModifiedDateTime > @Watermark) AS src
        ON tgt.ProductID = src.ProductID
        WHEN MATCHED THEN UPDATE SET
            SKU = src.SKU, ProductName = src.ProductName, Category = src.Category, Subcategory = src.Subcategory,
            ProductType = src.ProductType, MakeBuyType = src.MakeBuyType, VehicleSegment = src.VehicleSegment,
            UnitOfMeasure = src.UnitOfMeasure, ABCClass = src.ABCClass, StandardCost = src.StandardCost,
            ListPrice = src.ListPrice, SafetyStockQuantity = src.SafetyStockQuantity, ReorderLevel = src.ReorderLevel,
            MaximumStockQuantity = src.MaximumStockQuantity, ProductStatus = src.ProductStatus,
            LaunchDate = src.LaunchDate, DiscontinuedDate = src.DiscontinuedDate, ActiveFlag = src.ActiveFlag,
            SourceCreatedDateTime = src.CreatedDateTime, SourceModifiedDateTime = src.ModifiedDateTime,
            BatchID = @BatchID, LoadDateTime = SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (ProductID, SKU, ProductName, Category, Subcategory, ProductType, MakeBuyType, VehicleSegment,
             UnitOfMeasure, ABCClass, StandardCost, ListPrice, SafetyStockQuantity, ReorderLevel,
             MaximumStockQuantity, ProductStatus, LaunchDate, DiscontinuedDate, ActiveFlag,
             SourceCreatedDateTime, SourceModifiedDateTime, BatchID, LoadDateTime)
        VALUES
            (src.ProductID, src.SKU, src.ProductName, src.Category, src.Subcategory, src.ProductType, src.MakeBuyType,
             src.VehicleSegment, src.UnitOfMeasure, src.ABCClass, src.StandardCost, src.ListPrice,
             src.SafetyStockQuantity, src.ReorderLevel, src.MaximumStockQuantity, src.ProductStatus,
             src.LaunchDate, src.DiscontinuedDate, src.ActiveFlag, src.CreatedDateTime, src.ModifiedDateTime,
             @BatchID, SYSDATETIME());
        SET @TargetCount = @@ROWCOUNT;

        UPDATE etl.LoadControl SET
            LastLoadedModifiedDateTime = ISNULL((SELECT MAX(ModifiedDateTime) FROM Manufacturing_Source.dbo.Product WHERE ModifiedDateTime > @Watermark), LastLoadedModifiedDateTime),
            LastBatchID = @BatchID, UpdatedDateTime = SYSDATETIME()
        WHERE TableName = 'Product';

        UPDATE etl.BatchAudit SET EndDateTime = SYSDATETIME(), SourceRowCount = @SourceCount, TargetRowCount = @TargetCount, Status = 'Succeeded' WHERE BatchStepID = @BatchStepID;
    END TRY
    BEGIN CATCH
        UPDATE etl.BatchAudit SET EndDateTime = SYSDATETIME(), Status = 'Failed', ErrorMessage = ERROR_MESSAGE() WHERE BatchStepID = @BatchStepID;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE etl.usp_Load_raw_Supplier
    @BatchID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Watermark DATETIME2(0), @SourceCount INT, @TargetCount INT, @BatchStepID BIGINT;
    SELECT @Watermark = LastLoadedModifiedDateTime FROM etl.LoadControl WHERE TableName = 'Supplier';

    INSERT INTO etl.BatchAudit (BatchID, LayerName, TableName) VALUES (@BatchID, 'raw', 'Supplier');
    SET @BatchStepID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @SourceCount = COUNT(*) FROM Manufacturing_Source.dbo.Supplier WHERE ModifiedDateTime > @Watermark;

        MERGE raw.Supplier AS tgt
        USING (SELECT * FROM Manufacturing_Source.dbo.Supplier WHERE ModifiedDateTime > @Watermark) AS src
        ON tgt.SupplierID = src.SupplierID
        WHEN MATCHED THEN UPDATE SET
            SupplierName = src.SupplierName, SupplierCategory = src.SupplierCategory, SupplierTier = src.SupplierTier,
            SupplierStatus = src.SupplierStatus, SupplierRisk = src.SupplierRisk, CriticalSupplierFlag = src.CriticalSupplierFlag,
            StandardLeadTimeDays = src.StandardLeadTimeDays, PaymentTermsDays = src.PaymentTermsDays,
            Region = src.Region, Country = src.Country, StateProvince = src.StateProvince, City = src.City,
            CountryCode = src.CountryCode, ActiveFlag = src.ActiveFlag,
            SourceCreatedDateTime = src.CreatedDateTime, SourceModifiedDateTime = src.ModifiedDateTime,
            BatchID = @BatchID, LoadDateTime = SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (SupplierID, SupplierName, SupplierCategory, SupplierTier, SupplierStatus, SupplierRisk,
             CriticalSupplierFlag, StandardLeadTimeDays, PaymentTermsDays, Region, Country, StateProvince, City,
             CountryCode, ActiveFlag, SourceCreatedDateTime, SourceModifiedDateTime, BatchID, LoadDateTime)
        VALUES
            (src.SupplierID, src.SupplierName, src.SupplierCategory, src.SupplierTier, src.SupplierStatus, src.SupplierRisk,
             src.CriticalSupplierFlag, src.StandardLeadTimeDays, src.PaymentTermsDays, src.Region, src.Country,
             src.StateProvince, src.City, src.CountryCode, src.ActiveFlag, src.CreatedDateTime, src.ModifiedDateTime,
             @BatchID, SYSDATETIME());
        SET @TargetCount = @@ROWCOUNT;

        UPDATE etl.LoadControl SET
            LastLoadedModifiedDateTime = ISNULL((SELECT MAX(ModifiedDateTime) FROM Manufacturing_Source.dbo.Supplier WHERE ModifiedDateTime > @Watermark), LastLoadedModifiedDateTime),
            LastBatchID = @BatchID, UpdatedDateTime = SYSDATETIME()
        WHERE TableName = 'Supplier';

        UPDATE etl.BatchAudit SET EndDateTime = SYSDATETIME(), SourceRowCount = @SourceCount, TargetRowCount = @TargetCount, Status = 'Succeeded' WHERE BatchStepID = @BatchStepID;
    END TRY
    BEGIN CATCH
        UPDATE etl.BatchAudit SET EndDateTime = SYSDATETIME(), Status = 'Failed', ErrorMessage = ERROR_MESSAGE() WHERE BatchStepID = @BatchStepID;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE etl.usp_Load_raw_Customer
    @BatchID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Watermark DATETIME2(0), @SourceCount INT, @TargetCount INT, @BatchStepID BIGINT;
    SELECT @Watermark = LastLoadedModifiedDateTime FROM etl.LoadControl WHERE TableName = 'Customer';

    INSERT INTO etl.BatchAudit (BatchID, LayerName, TableName) VALUES (@BatchID, 'raw', 'Customer');
    SET @BatchStepID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @SourceCount = COUNT(*) FROM Manufacturing_Source.dbo.Customer WHERE ModifiedDateTime > @Watermark;

        MERGE raw.Customer AS tgt
        USING (SELECT * FROM Manufacturing_Source.dbo.Customer WHERE ModifiedDateTime > @Watermark) AS src
        ON tgt.CustomerID = src.CustomerID
        WHEN MATCHED THEN UPDATE SET
            CustomerName = src.CustomerName, CustomerType = src.CustomerType, CustomerSegment = src.CustomerSegment,
            CreditTermsDays = src.CreditTermsDays, Region = src.Region, Country = src.Country,
            StateProvince = src.StateProvince, City = src.City, CountryCode = src.CountryCode, ActiveFlag = src.ActiveFlag,
            SourceCreatedDateTime = src.CreatedDateTime, SourceModifiedDateTime = src.ModifiedDateTime,
            BatchID = @BatchID, LoadDateTime = SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (CustomerID, CustomerName, CustomerType, CustomerSegment, CreditTermsDays, Region, Country,
             StateProvince, City, CountryCode, ActiveFlag, SourceCreatedDateTime, SourceModifiedDateTime, BatchID, LoadDateTime)
        VALUES
            (src.CustomerID, src.CustomerName, src.CustomerType, src.CustomerSegment, src.CreditTermsDays, src.Region,
             src.Country, src.StateProvince, src.City, src.CountryCode, src.ActiveFlag, src.CreatedDateTime,
             src.ModifiedDateTime, @BatchID, SYSDATETIME());
        SET @TargetCount = @@ROWCOUNT;

        UPDATE etl.LoadControl SET
            LastLoadedModifiedDateTime = ISNULL((SELECT MAX(ModifiedDateTime) FROM Manufacturing_Source.dbo.Customer WHERE ModifiedDateTime > @Watermark), LastLoadedModifiedDateTime),
            LastBatchID = @BatchID, UpdatedDateTime = SYSDATETIME()
        WHERE TableName = 'Customer';

        UPDATE etl.BatchAudit SET EndDateTime = SYSDATETIME(), SourceRowCount = @SourceCount, TargetRowCount = @TargetCount, Status = 'Succeeded' WHERE BatchStepID = @BatchStepID;
    END TRY
    BEGIN CATCH
        UPDATE etl.BatchAudit SET EndDateTime = SYSDATETIME(), Status = 'Failed', ErrorMessage = ERROR_MESSAGE() WHERE BatchStepID = @BatchStepID;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE etl.usp_Load_raw_Warehouse
    @BatchID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Watermark DATETIME2(0), @SourceCount INT, @TargetCount INT, @BatchStepID BIGINT;
    SELECT @Watermark = LastLoadedModifiedDateTime FROM etl.LoadControl WHERE TableName = 'Warehouse';

    INSERT INTO etl.BatchAudit (BatchID, LayerName, TableName) VALUES (@BatchID, 'raw', 'Warehouse');
    SET @BatchStepID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @SourceCount = COUNT(*) FROM Manufacturing_Source.dbo.Warehouse WHERE ModifiedDateTime > @Watermark;

        MERGE raw.Warehouse AS tgt
        USING (SELECT * FROM Manufacturing_Source.dbo.Warehouse WHERE ModifiedDateTime > @Watermark) AS src
        ON tgt.WarehouseID = src.WarehouseID
        WHEN MATCHED THEN UPDATE SET
            WarehouseName = src.WarehouseName, WarehouseType = src.WarehouseType, Region = src.Region,
            Country = src.Country, StateProvince = src.StateProvince, City = src.City, CountryCode = src.CountryCode,
            CapacityUnits = src.CapacityUnits, ActiveFlag = src.ActiveFlag,
            SourceCreatedDateTime = src.CreatedDateTime, SourceModifiedDateTime = src.ModifiedDateTime,
            BatchID = @BatchID, LoadDateTime = SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (WarehouseID, WarehouseName, WarehouseType, Region, Country, StateProvince, City, CountryCode,
             CapacityUnits, ActiveFlag, SourceCreatedDateTime, SourceModifiedDateTime, BatchID, LoadDateTime)
        VALUES
            (src.WarehouseID, src.WarehouseName, src.WarehouseType, src.Region, src.Country, src.StateProvince,
             src.City, src.CountryCode, src.CapacityUnits, src.ActiveFlag, src.CreatedDateTime, src.ModifiedDateTime,
             @BatchID, SYSDATETIME());
        SET @TargetCount = @@ROWCOUNT;

        UPDATE etl.LoadControl SET
            LastLoadedModifiedDateTime = ISNULL((SELECT MAX(ModifiedDateTime) FROM Manufacturing_Source.dbo.Warehouse WHERE ModifiedDateTime > @Watermark), LastLoadedModifiedDateTime),
            LastBatchID = @BatchID, UpdatedDateTime = SYSDATETIME()
        WHERE TableName = 'Warehouse';

        UPDATE etl.BatchAudit SET EndDateTime = SYSDATETIME(), SourceRowCount = @SourceCount, TargetRowCount = @TargetCount, Status = 'Succeeded' WHERE BatchStepID = @BatchStepID;
    END TRY
    BEGIN CATCH
        UPDATE etl.BatchAudit SET EndDateTime = SYSDATETIME(), Status = 'Failed', ErrorMessage = ERROR_MESSAGE() WHERE BatchStepID = @BatchStepID;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE etl.usp_Load_raw_Carrier
    @BatchID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Watermark DATETIME2(0), @SourceCount INT, @TargetCount INT, @BatchStepID BIGINT;
    SELECT @Watermark = LastLoadedModifiedDateTime FROM etl.LoadControl WHERE TableName = 'Carrier';

    INSERT INTO etl.BatchAudit (BatchID, LayerName, TableName) VALUES (@BatchID, 'raw', 'Carrier');
    SET @BatchStepID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @SourceCount = COUNT(*) FROM Manufacturing_Source.dbo.Carrier WHERE ModifiedDateTime > @Watermark;

        MERGE raw.Carrier AS tgt
        USING (SELECT * FROM Manufacturing_Source.dbo.Carrier WHERE ModifiedDateTime > @Watermark) AS src
        ON tgt.CarrierID = src.CarrierID
        WHEN MATCHED THEN UPDATE SET
            CarrierName = src.CarrierName, CarrierType = src.CarrierType, ServiceLevel = src.ServiceLevel,
            Coverage = src.Coverage, CarrierRating = src.CarrierRating, ContractType = src.ContractType,
            PrimaryRegion = src.PrimaryRegion, ActiveFlag = src.ActiveFlag,
            SourceCreatedDateTime = src.CreatedDateTime, SourceModifiedDateTime = src.ModifiedDateTime,
            BatchID = @BatchID, LoadDateTime = SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (CarrierID, CarrierName, CarrierType, ServiceLevel, Coverage, CarrierRating, ContractType,
             PrimaryRegion, ActiveFlag, SourceCreatedDateTime, SourceModifiedDateTime, BatchID, LoadDateTime)
        VALUES
            (src.CarrierID, src.CarrierName, src.CarrierType, src.ServiceLevel, src.Coverage, src.CarrierRating,
             src.ContractType, src.PrimaryRegion, src.ActiveFlag, src.CreatedDateTime, src.ModifiedDateTime,
             @BatchID, SYSDATETIME());
        SET @TargetCount = @@ROWCOUNT;

        UPDATE etl.LoadControl SET
            LastLoadedModifiedDateTime = ISNULL((SELECT MAX(ModifiedDateTime) FROM Manufacturing_Source.dbo.Carrier WHERE ModifiedDateTime > @Watermark), LastLoadedModifiedDateTime),
            LastBatchID = @BatchID, UpdatedDateTime = SYSDATETIME()
        WHERE TableName = 'Carrier';

        UPDATE etl.BatchAudit SET EndDateTime = SYSDATETIME(), SourceRowCount = @SourceCount, TargetRowCount = @TargetCount, Status = 'Succeeded' WHERE BatchStepID = @BatchStepID;
    END TRY
    BEGIN CATCH
        UPDATE etl.BatchAudit SET EndDateTime = SYSDATETIME(), Status = 'Failed', ErrorMessage = ERROR_MESSAGE() WHERE BatchStepID = @BatchStepID;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE etl.usp_Load_raw_PurchaseOrder
    @BatchID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Watermark DATETIME2(0), @SourceCount INT, @TargetCount INT, @BatchStepID BIGINT;
    SELECT @Watermark = LastLoadedModifiedDateTime FROM etl.LoadControl WHERE TableName = 'PurchaseOrder';

    INSERT INTO etl.BatchAudit (BatchID, LayerName, TableName) VALUES (@BatchID, 'raw', 'PurchaseOrder');
    SET @BatchStepID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @SourceCount = COUNT(*) FROM Manufacturing_Source.dbo.PurchaseOrder WHERE ModifiedDateTime > @Watermark;

        MERGE raw.PurchaseOrder AS tgt
        USING (SELECT * FROM Manufacturing_Source.dbo.PurchaseOrder WHERE ModifiedDateTime > @Watermark) AS src
        ON tgt.PurchaseOrderID = src.PurchaseOrderID
        WHEN MATCHED THEN UPDATE SET
            SupplierID = src.SupplierID, DeliveryWarehouseID = src.DeliveryWarehouseID, OrderDate = src.OrderDate,
            RequestedDeliveryDate = src.RequestedDeliveryDate, PromisedDeliveryDate = src.PromisedDeliveryDate,
            PurchaseType = src.PurchaseType, Priority = src.Priority, CurrencyCode = src.CurrencyCode,
            POStatus = src.POStatus, BuyerGroup = src.BuyerGroup,
            SourceCreatedDateTime = src.CreatedDateTime, SourceModifiedDateTime = src.ModifiedDateTime,
            BatchID = @BatchID, LoadDateTime = SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (PurchaseOrderID, SupplierID, DeliveryWarehouseID, OrderDate, RequestedDeliveryDate, PromisedDeliveryDate,
             PurchaseType, Priority, CurrencyCode, POStatus, BuyerGroup, SourceCreatedDateTime, SourceModifiedDateTime, BatchID, LoadDateTime)
        VALUES
            (src.PurchaseOrderID, src.SupplierID, src.DeliveryWarehouseID, src.OrderDate, src.RequestedDeliveryDate,
             src.PromisedDeliveryDate, src.PurchaseType, src.Priority, src.CurrencyCode, src.POStatus, src.BuyerGroup,
             src.CreatedDateTime, src.ModifiedDateTime, @BatchID, SYSDATETIME());
        SET @TargetCount = @@ROWCOUNT;

        UPDATE etl.LoadControl SET
            LastLoadedModifiedDateTime = ISNULL((SELECT MAX(ModifiedDateTime) FROM Manufacturing_Source.dbo.PurchaseOrder WHERE ModifiedDateTime > @Watermark), LastLoadedModifiedDateTime),
            LastBatchID = @BatchID, UpdatedDateTime = SYSDATETIME()
        WHERE TableName = 'PurchaseOrder';

        UPDATE etl.BatchAudit SET EndDateTime = SYSDATETIME(), SourceRowCount = @SourceCount, TargetRowCount = @TargetCount, Status = 'Succeeded' WHERE BatchStepID = @BatchStepID;
    END TRY
    BEGIN CATCH
        UPDATE etl.BatchAudit SET EndDateTime = SYSDATETIME(), Status = 'Failed', ErrorMessage = ERROR_MESSAGE() WHERE BatchStepID = @BatchStepID;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE etl.usp_Load_raw_PurchaseOrderLine
    @BatchID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Watermark DATETIME2(0), @SourceCount INT, @TargetCount INT, @BatchStepID BIGINT;
    SELECT @Watermark = LastLoadedModifiedDateTime FROM etl.LoadControl WHERE TableName = 'PurchaseOrderLine';

    INSERT INTO etl.BatchAudit (BatchID, LayerName, TableName) VALUES (@BatchID, 'raw', 'PurchaseOrderLine');
    SET @BatchStepID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @SourceCount = COUNT(*) FROM Manufacturing_Source.dbo.PurchaseOrderLine WHERE ModifiedDateTime > @Watermark;

        MERGE raw.PurchaseOrderLine AS tgt
        USING (SELECT * FROM Manufacturing_Source.dbo.PurchaseOrderLine WHERE ModifiedDateTime > @Watermark) AS src
        ON tgt.PurchaseOrderLineID = src.PurchaseOrderLineID
        WHEN MATCHED THEN UPDATE SET
            PurchaseOrderID = src.PurchaseOrderID, ProductID = src.ProductID, OrderedQuantity = src.OrderedQuantity,
            ReceivedQuantity = src.ReceivedQuantity, OpenQuantity = src.OpenQuantity, UnitCost = src.UnitCost,
            LineAmount = src.LineAmount, LineStatus = src.LineStatus,
            SourceCreatedDateTime = src.CreatedDateTime, SourceModifiedDateTime = src.ModifiedDateTime,
            BatchID = @BatchID, LoadDateTime = SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (PurchaseOrderLineID, PurchaseOrderID, ProductID, OrderedQuantity, ReceivedQuantity, OpenQuantity,
             UnitCost, LineAmount, LineStatus, SourceCreatedDateTime, SourceModifiedDateTime, BatchID, LoadDateTime)
        VALUES
            (src.PurchaseOrderLineID, src.PurchaseOrderID, src.ProductID, src.OrderedQuantity, src.ReceivedQuantity,
             src.OpenQuantity, src.UnitCost, src.LineAmount, src.LineStatus, src.CreatedDateTime, src.ModifiedDateTime,
             @BatchID, SYSDATETIME());
        SET @TargetCount = @@ROWCOUNT;

        UPDATE etl.LoadControl SET
            LastLoadedModifiedDateTime = ISNULL((SELECT MAX(ModifiedDateTime) FROM Manufacturing_Source.dbo.PurchaseOrderLine WHERE ModifiedDateTime > @Watermark), LastLoadedModifiedDateTime),
            LastBatchID = @BatchID, UpdatedDateTime = SYSDATETIME()
        WHERE TableName = 'PurchaseOrderLine';

        UPDATE etl.BatchAudit SET EndDateTime = SYSDATETIME(), SourceRowCount = @SourceCount, TargetRowCount = @TargetCount, Status = 'Succeeded' WHERE BatchStepID = @BatchStepID;
    END TRY
    BEGIN CATCH
        UPDATE etl.BatchAudit SET EndDateTime = SYSDATETIME(), Status = 'Failed', ErrorMessage = ERROR_MESSAGE() WHERE BatchStepID = @BatchStepID;
        THROW;
    END CATCH
END;
GO

/* raw.GoodsReceipt: source table has no ModifiedDateTime -- watermark on CreatedDateTime. */
CREATE OR ALTER PROCEDURE etl.usp_Load_raw_GoodsReceipt
    @BatchID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Watermark DATETIME2(0), @SourceCount INT, @TargetCount INT, @BatchStepID BIGINT;
    SELECT @Watermark = LastLoadedModifiedDateTime FROM etl.LoadControl WHERE TableName = 'GoodsReceipt';

    INSERT INTO etl.BatchAudit (BatchID, LayerName, TableName) VALUES (@BatchID, 'raw', 'GoodsReceipt');
    SET @BatchStepID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @SourceCount = COUNT(*) FROM Manufacturing_Source.dbo.GoodsReceipt WHERE CreatedDateTime > @Watermark;

        MERGE raw.GoodsReceipt AS tgt
        USING (SELECT * FROM Manufacturing_Source.dbo.GoodsReceipt WHERE CreatedDateTime > @Watermark) AS src
        ON tgt.GoodsReceiptID = src.GoodsReceiptID
        WHEN MATCHED THEN UPDATE SET
            PurchaseOrderLineID = src.PurchaseOrderLineID, ProductID = src.ProductID, WarehouseID = src.WarehouseID,
            ReceiptDateTime = src.ReceiptDateTime, PhysicalReceivedQuantity = src.PhysicalReceivedQuantity,
            AcceptedQuantity = src.AcceptedQuantity, RejectedQuantity = src.RejectedQuantity,
            ReceiptStatus = src.ReceiptStatus, ReceiptSource = src.ReceiptSource,
            SourceCreatedDateTime = src.CreatedDateTime, BatchID = @BatchID, LoadDateTime = SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (GoodsReceiptID, PurchaseOrderLineID, ProductID, WarehouseID, ReceiptDateTime, PhysicalReceivedQuantity,
             AcceptedQuantity, RejectedQuantity, ReceiptStatus, ReceiptSource, SourceCreatedDateTime, BatchID, LoadDateTime)
        VALUES
            (src.GoodsReceiptID, src.PurchaseOrderLineID, src.ProductID, src.WarehouseID, src.ReceiptDateTime,
             src.PhysicalReceivedQuantity, src.AcceptedQuantity, src.RejectedQuantity, src.ReceiptStatus,
             src.ReceiptSource, src.CreatedDateTime, @BatchID, SYSDATETIME());
        SET @TargetCount = @@ROWCOUNT;

        UPDATE etl.LoadControl SET
            LastLoadedModifiedDateTime = ISNULL((SELECT MAX(CreatedDateTime) FROM Manufacturing_Source.dbo.GoodsReceipt WHERE CreatedDateTime > @Watermark), LastLoadedModifiedDateTime),
            LastBatchID = @BatchID, UpdatedDateTime = SYSDATETIME()
        WHERE TableName = 'GoodsReceipt';

        UPDATE etl.BatchAudit SET EndDateTime = SYSDATETIME(), SourceRowCount = @SourceCount, TargetRowCount = @TargetCount, Status = 'Succeeded' WHERE BatchStepID = @BatchStepID;
    END TRY
    BEGIN CATCH
        UPDATE etl.BatchAudit SET EndDateTime = SYSDATETIME(), Status = 'Failed', ErrorMessage = ERROR_MESSAGE() WHERE BatchStepID = @BatchStepID;
        THROW;
    END CATCH
END;
GO

/* raw.InventoryBalance: source table has no CreatedDateTime -- watermark on ModifiedDateTime as usual. */
CREATE OR ALTER PROCEDURE etl.usp_Load_raw_InventoryBalance
    @BatchID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Watermark DATETIME2(0), @SourceCount INT, @TargetCount INT, @BatchStepID BIGINT;
    SELECT @Watermark = LastLoadedModifiedDateTime FROM etl.LoadControl WHERE TableName = 'InventoryBalance';

    INSERT INTO etl.BatchAudit (BatchID, LayerName, TableName) VALUES (@BatchID, 'raw', 'InventoryBalance');
    SET @BatchStepID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @SourceCount = COUNT(*) FROM Manufacturing_Source.dbo.InventoryBalance WHERE ModifiedDateTime > @Watermark;

        MERGE raw.InventoryBalance AS tgt
        USING (SELECT * FROM Manufacturing_Source.dbo.InventoryBalance WHERE ModifiedDateTime > @Watermark) AS src
        ON tgt.ProductID = src.ProductID AND tgt.WarehouseID = src.WarehouseID
        WHEN MATCHED THEN UPDATE SET
            OnHandQuantity = src.OnHandQuantity, ReservedQuantity = src.ReservedQuantity,
            AvailableQuantity = src.AvailableQuantity, InTransitQuantity = src.InTransitQuantity,
            AverageUnitCost = src.AverageUnitCost, LastMovementDateTime = src.LastMovementDateTime,
            SourceModifiedDateTime = src.ModifiedDateTime, BatchID = @BatchID, LoadDateTime = SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (ProductID, WarehouseID, OnHandQuantity, ReservedQuantity, AvailableQuantity, InTransitQuantity,
             AverageUnitCost, LastMovementDateTime, SourceModifiedDateTime, BatchID, LoadDateTime)
        VALUES
            (src.ProductID, src.WarehouseID, src.OnHandQuantity, src.ReservedQuantity, src.AvailableQuantity,
             src.InTransitQuantity, src.AverageUnitCost, src.LastMovementDateTime, src.ModifiedDateTime,
             @BatchID, SYSDATETIME());
        SET @TargetCount = @@ROWCOUNT;

        UPDATE etl.LoadControl SET
            LastLoadedModifiedDateTime = ISNULL((SELECT MAX(ModifiedDateTime) FROM Manufacturing_Source.dbo.InventoryBalance WHERE ModifiedDateTime > @Watermark), LastLoadedModifiedDateTime),
            LastBatchID = @BatchID, UpdatedDateTime = SYSDATETIME()
        WHERE TableName = 'InventoryBalance';

        UPDATE etl.BatchAudit SET EndDateTime = SYSDATETIME(), SourceRowCount = @SourceCount, TargetRowCount = @TargetCount, Status = 'Succeeded' WHERE BatchStepID = @BatchStepID;
    END TRY
    BEGIN CATCH
        UPDATE etl.BatchAudit SET EndDateTime = SYSDATETIME(), Status = 'Failed', ErrorMessage = ERROR_MESSAGE() WHERE BatchStepID = @BatchStepID;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE etl.usp_Load_raw_SalesOrder
    @BatchID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Watermark DATETIME2(0), @SourceCount INT, @TargetCount INT, @BatchStepID BIGINT;
    SELECT @Watermark = LastLoadedModifiedDateTime FROM etl.LoadControl WHERE TableName = 'SalesOrder';

    INSERT INTO etl.BatchAudit (BatchID, LayerName, TableName) VALUES (@BatchID, 'raw', 'SalesOrder');
    SET @BatchStepID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @SourceCount = COUNT(*) FROM Manufacturing_Source.dbo.SalesOrder WHERE ModifiedDateTime > @Watermark;

        MERGE raw.SalesOrder AS tgt
        USING (SELECT * FROM Manufacturing_Source.dbo.SalesOrder WHERE ModifiedDateTime > @Watermark) AS src
        ON tgt.SalesOrderID = src.SalesOrderID
        WHEN MATCHED THEN UPDATE SET
            CustomerID = src.CustomerID, OrderDate = src.OrderDate, RequestedDeliveryDate = src.RequestedDeliveryDate,
            Priority = src.Priority, CurrencyCode = src.CurrencyCode, OrderStatus = src.OrderStatus,
            OrderType = src.OrderType, SalesChannel = src.SalesChannel,
            SourceCreatedDateTime = src.CreatedDateTime, SourceModifiedDateTime = src.ModifiedDateTime,
            BatchID = @BatchID, LoadDateTime = SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (SalesOrderID, CustomerID, OrderDate, RequestedDeliveryDate, Priority, CurrencyCode, OrderStatus,
             OrderType, SalesChannel, SourceCreatedDateTime, SourceModifiedDateTime, BatchID, LoadDateTime)
        VALUES
            (src.SalesOrderID, src.CustomerID, src.OrderDate, src.RequestedDeliveryDate, src.Priority, src.CurrencyCode,
             src.OrderStatus, src.OrderType, src.SalesChannel, src.CreatedDateTime, src.ModifiedDateTime,
             @BatchID, SYSDATETIME());
        SET @TargetCount = @@ROWCOUNT;

        UPDATE etl.LoadControl SET
            LastLoadedModifiedDateTime = ISNULL((SELECT MAX(ModifiedDateTime) FROM Manufacturing_Source.dbo.SalesOrder WHERE ModifiedDateTime > @Watermark), LastLoadedModifiedDateTime),
            LastBatchID = @BatchID, UpdatedDateTime = SYSDATETIME()
        WHERE TableName = 'SalesOrder';

        UPDATE etl.BatchAudit SET EndDateTime = SYSDATETIME(), SourceRowCount = @SourceCount, TargetRowCount = @TargetCount, Status = 'Succeeded' WHERE BatchStepID = @BatchStepID;
    END TRY
    BEGIN CATCH
        UPDATE etl.BatchAudit SET EndDateTime = SYSDATETIME(), Status = 'Failed', ErrorMessage = ERROR_MESSAGE() WHERE BatchStepID = @BatchStepID;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE etl.usp_Load_raw_SalesOrderLine
    @BatchID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Watermark DATETIME2(0), @SourceCount INT, @TargetCount INT, @BatchStepID BIGINT;
    SELECT @Watermark = LastLoadedModifiedDateTime FROM etl.LoadControl WHERE TableName = 'SalesOrderLine';

    INSERT INTO etl.BatchAudit (BatchID, LayerName, TableName) VALUES (@BatchID, 'raw', 'SalesOrderLine');
    SET @BatchStepID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @SourceCount = COUNT(*) FROM Manufacturing_Source.dbo.SalesOrderLine WHERE ModifiedDateTime > @Watermark;

        MERGE raw.SalesOrderLine AS tgt
        USING (SELECT * FROM Manufacturing_Source.dbo.SalesOrderLine WHERE ModifiedDateTime > @Watermark) AS src
        ON tgt.SalesOrderLineID = src.SalesOrderLineID
        WHEN MATCHED THEN UPDATE SET
            SalesOrderID = src.SalesOrderID, ProductID = src.ProductID, FulfillmentWarehouseID = src.FulfillmentWarehouseID,
            PromisedDeliveryDate = src.PromisedDeliveryDate, OrderQuantity = src.OrderQuantity,
            FulfilledQuantity = src.FulfilledQuantity, BackorderQuantity = src.BackorderQuantity,
            UnitPrice = src.UnitPrice, GrossLineAmount = src.GrossLineAmount, DiscountAmount = src.DiscountAmount,
            NetLineAmount = src.NetLineAmount, LineStatus = src.LineStatus,
            SourceCreatedDateTime = src.CreatedDateTime, SourceModifiedDateTime = src.ModifiedDateTime,
            BatchID = @BatchID, LoadDateTime = SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (SalesOrderLineID, SalesOrderID, ProductID, FulfillmentWarehouseID, PromisedDeliveryDate, OrderQuantity,
             FulfilledQuantity, BackorderQuantity, UnitPrice, GrossLineAmount, DiscountAmount, NetLineAmount,
             LineStatus, SourceCreatedDateTime, SourceModifiedDateTime, BatchID, LoadDateTime)
        VALUES
            (src.SalesOrderLineID, src.SalesOrderID, src.ProductID, src.FulfillmentWarehouseID, src.PromisedDeliveryDate,
             src.OrderQuantity, src.FulfilledQuantity, src.BackorderQuantity, src.UnitPrice, src.GrossLineAmount,
             src.DiscountAmount, src.NetLineAmount, src.LineStatus, src.CreatedDateTime, src.ModifiedDateTime,
             @BatchID, SYSDATETIME());
        SET @TargetCount = @@ROWCOUNT;

        UPDATE etl.LoadControl SET
            LastLoadedModifiedDateTime = ISNULL((SELECT MAX(ModifiedDateTime) FROM Manufacturing_Source.dbo.SalesOrderLine WHERE ModifiedDateTime > @Watermark), LastLoadedModifiedDateTime),
            LastBatchID = @BatchID, UpdatedDateTime = SYSDATETIME()
        WHERE TableName = 'SalesOrderLine';

        UPDATE etl.BatchAudit SET EndDateTime = SYSDATETIME(), SourceRowCount = @SourceCount, TargetRowCount = @TargetCount, Status = 'Succeeded' WHERE BatchStepID = @BatchStepID;
    END TRY
    BEGIN CATCH
        UPDATE etl.BatchAudit SET EndDateTime = SYSDATETIME(), Status = 'Failed', ErrorMessage = ERROR_MESSAGE() WHERE BatchStepID = @BatchStepID;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE etl.usp_Load_raw_Shipment
    @BatchID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Watermark DATETIME2(0), @SourceCount INT, @TargetCount INT, @BatchStepID BIGINT;
    SELECT @Watermark = LastLoadedModifiedDateTime FROM etl.LoadControl WHERE TableName = 'Shipment';

    INSERT INTO etl.BatchAudit (BatchID, LayerName, TableName) VALUES (@BatchID, 'raw', 'Shipment');
    SET @BatchStepID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @SourceCount = COUNT(*) FROM Manufacturing_Source.dbo.Shipment WHERE ModifiedDateTime > @Watermark;

        MERGE raw.Shipment AS tgt
        USING (SELECT * FROM Manufacturing_Source.dbo.Shipment WHERE ModifiedDateTime > @Watermark) AS src
        ON tgt.ShipmentID = src.ShipmentID
        WHEN MATCHED THEN UPDATE SET
            SalesOrderID = src.SalesOrderID, CarrierID = src.CarrierID, OriginWarehouseID = src.OriginWarehouseID,
            ShipmentDate = src.ShipmentDate, PromisedDeliveryDate = src.PromisedDeliveryDate,
            ActualDeliveryDate = src.ActualDeliveryDate, ShipmentStatus = src.ShipmentStatus,
            ShipmentMode = src.ShipmentMode, ServiceLevel = src.ServiceLevel, DestinationRegion = src.DestinationRegion,
            DestinationCountry = src.DestinationCountry, DestinationStateProvince = src.DestinationStateProvince,
            DestinationCity = src.DestinationCity, DestinationCountryCode = src.DestinationCountryCode,
            ShippingCost = src.ShippingCost, ReturnFlag = src.ReturnFlag, ReturnReason = src.ReturnReason,
            SourceCreatedDateTime = src.CreatedDateTime, SourceModifiedDateTime = src.ModifiedDateTime,
            BatchID = @BatchID, LoadDateTime = SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (ShipmentID, SalesOrderID, CarrierID, OriginWarehouseID, ShipmentDate, PromisedDeliveryDate,
             ActualDeliveryDate, ShipmentStatus, ShipmentMode, ServiceLevel, DestinationRegion, DestinationCountry,
             DestinationStateProvince, DestinationCity, DestinationCountryCode, ShippingCost, ReturnFlag, ReturnReason,
             SourceCreatedDateTime, SourceModifiedDateTime, BatchID, LoadDateTime)
        VALUES
            (src.ShipmentID, src.SalesOrderID, src.CarrierID, src.OriginWarehouseID, src.ShipmentDate,
             src.PromisedDeliveryDate, src.ActualDeliveryDate, src.ShipmentStatus, src.ShipmentMode, src.ServiceLevel,
             src.DestinationRegion, src.DestinationCountry, src.DestinationStateProvince, src.DestinationCity,
             src.DestinationCountryCode, src.ShippingCost, src.ReturnFlag, src.ReturnReason, src.CreatedDateTime,
             src.ModifiedDateTime, @BatchID, SYSDATETIME());
        SET @TargetCount = @@ROWCOUNT;

        UPDATE etl.LoadControl SET
            LastLoadedModifiedDateTime = ISNULL((SELECT MAX(ModifiedDateTime) FROM Manufacturing_Source.dbo.Shipment WHERE ModifiedDateTime > @Watermark), LastLoadedModifiedDateTime),
            LastBatchID = @BatchID, UpdatedDateTime = SYSDATETIME()
        WHERE TableName = 'Shipment';

        UPDATE etl.BatchAudit SET EndDateTime = SYSDATETIME(), SourceRowCount = @SourceCount, TargetRowCount = @TargetCount, Status = 'Succeeded' WHERE BatchStepID = @BatchStepID;
    END TRY
    BEGIN CATCH
        UPDATE etl.BatchAudit SET EndDateTime = SYSDATETIME(), Status = 'Failed', ErrorMessage = ERROR_MESSAGE() WHERE BatchStepID = @BatchStepID;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE etl.usp_Load_raw_ShipmentLine
    @BatchID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Watermark DATETIME2(0), @SourceCount INT, @TargetCount INT, @BatchStepID BIGINT;
    SELECT @Watermark = LastLoadedModifiedDateTime FROM etl.LoadControl WHERE TableName = 'ShipmentLine';

    INSERT INTO etl.BatchAudit (BatchID, LayerName, TableName) VALUES (@BatchID, 'raw', 'ShipmentLine');
    SET @BatchStepID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @SourceCount = COUNT(*) FROM Manufacturing_Source.dbo.ShipmentLine WHERE ModifiedDateTime > @Watermark;

        MERGE raw.ShipmentLine AS tgt
        USING (SELECT * FROM Manufacturing_Source.dbo.ShipmentLine WHERE ModifiedDateTime > @Watermark) AS src
        ON tgt.ShipmentLineID = src.ShipmentLineID
        WHEN MATCHED THEN UPDATE SET
            ShipmentID = src.ShipmentID, SalesOrderLineID = src.SalesOrderLineID, ProductID = src.ProductID,
            ShippedQuantity = src.ShippedQuantity, ReceivedQuantity = src.ReceivedQuantity,
            SourceCreatedDateTime = src.CreatedDateTime, SourceModifiedDateTime = src.ModifiedDateTime,
            BatchID = @BatchID, LoadDateTime = SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (ShipmentLineID, ShipmentID, SalesOrderLineID, ProductID, ShippedQuantity, ReceivedQuantity,
             SourceCreatedDateTime, SourceModifiedDateTime, BatchID, LoadDateTime)
        VALUES
            (src.ShipmentLineID, src.ShipmentID, src.SalesOrderLineID, src.ProductID, src.ShippedQuantity,
             src.ReceivedQuantity, src.CreatedDateTime, src.ModifiedDateTime, @BatchID, SYSDATETIME());
        SET @TargetCount = @@ROWCOUNT;

        UPDATE etl.LoadControl SET
            LastLoadedModifiedDateTime = ISNULL((SELECT MAX(ModifiedDateTime) FROM Manufacturing_Source.dbo.ShipmentLine WHERE ModifiedDateTime > @Watermark), LastLoadedModifiedDateTime),
            LastBatchID = @BatchID, UpdatedDateTime = SYSDATETIME()
        WHERE TableName = 'ShipmentLine';

        UPDATE etl.BatchAudit SET EndDateTime = SYSDATETIME(), SourceRowCount = @SourceCount, TargetRowCount = @TargetCount, Status = 'Succeeded' WHERE BatchStepID = @BatchStepID;
    END TRY
    BEGIN CATCH
        UPDATE etl.BatchAudit SET EndDateTime = SYSDATETIME(), Status = 'Failed', ErrorMessage = ERROR_MESSAGE() WHERE BatchStepID = @BatchStepID;
        THROW;
    END CATCH
END;
GO


/*==============================================================================
  STEP 2 - STG LOAD PROCEDURES (13)
  Master tables (Product/Supplier/Customer/Warehouse/Carrier) have no FK
  dependency on anything else, so their stg step is light standardization
  only. The other 8 validate against already-loaded parent stg tables and/or
  reconcile a business-rule invariant, logging failures to
  etl.RejectedRows and excluding them from the MERGE source set.
==============================================================================*/

CREATE OR ALTER PROCEDURE etl.usp_Load_stg_Product
    @BatchID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @SourceCount INT, @TargetCount INT, @BatchStepID BIGINT;
    INSERT INTO etl.BatchAudit (BatchID, LayerName, TableName) VALUES (@BatchID, 'stg', 'Product');
    SET @BatchStepID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @SourceCount = COUNT(*) FROM raw.Product;

        MERGE stg.Product AS tgt
        USING (
            SELECT ProductID, LTRIM(RTRIM(SKU)) AS SKU, LTRIM(RTRIM(ProductName)) AS ProductName, Category, Subcategory,
                   ProductType, MakeBuyType, VehicleSegment, UnitOfMeasure, ABCClass, StandardCost, ListPrice,
                   SafetyStockQuantity, ReorderLevel, MaximumStockQuantity, ProductStatus, LaunchDate,
                   DiscontinuedDate, ActiveFlag, SourceCreatedDateTime, SourceModifiedDateTime
            FROM raw.Product
        ) AS src
        ON tgt.ProductID = src.ProductID
        WHEN MATCHED AND tgt.SourceModifiedDateTime <> src.SourceModifiedDateTime THEN UPDATE SET
            SKU=src.SKU, ProductName=src.ProductName, Category=src.Category, Subcategory=src.Subcategory,
            ProductType=src.ProductType, MakeBuyType=src.MakeBuyType, VehicleSegment=src.VehicleSegment,
            UnitOfMeasure=src.UnitOfMeasure, ABCClass=src.ABCClass, StandardCost=src.StandardCost,
            ListPrice=src.ListPrice, SafetyStockQuantity=src.SafetyStockQuantity, ReorderLevel=src.ReorderLevel,
            MaximumStockQuantity=src.MaximumStockQuantity, ProductStatus=src.ProductStatus, LaunchDate=src.LaunchDate,
            DiscontinuedDate=src.DiscontinuedDate, ActiveFlag=src.ActiveFlag,
            SourceCreatedDateTime=src.SourceCreatedDateTime, SourceModifiedDateTime=src.SourceModifiedDateTime,
            BatchID=@BatchID, LoadDateTime=SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (ProductID, SKU, ProductName, Category, Subcategory, ProductType, MakeBuyType, VehicleSegment,
             UnitOfMeasure, ABCClass, StandardCost, ListPrice, SafetyStockQuantity, ReorderLevel,
             MaximumStockQuantity, ProductStatus, LaunchDate, DiscontinuedDate, ActiveFlag,
             SourceCreatedDateTime, SourceModifiedDateTime, BatchID, LoadDateTime)
        VALUES
            (src.ProductID, src.SKU, src.ProductName, src.Category, src.Subcategory, src.ProductType, src.MakeBuyType,
             src.VehicleSegment, src.UnitOfMeasure, src.ABCClass, src.StandardCost, src.ListPrice,
             src.SafetyStockQuantity, src.ReorderLevel, src.MaximumStockQuantity, src.ProductStatus,
             src.LaunchDate, src.DiscontinuedDate, src.ActiveFlag, src.SourceCreatedDateTime, src.SourceModifiedDateTime,
             @BatchID, SYSDATETIME());
        SET @TargetCount = @@ROWCOUNT;

        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), SourceRowCount=@SourceCount, TargetRowCount=@TargetCount, Status='Succeeded' WHERE BatchStepID=@BatchStepID;
    END TRY
    BEGIN CATCH
        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), Status='Failed', ErrorMessage=ERROR_MESSAGE() WHERE BatchStepID=@BatchStepID;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE etl.usp_Load_stg_Supplier
    @BatchID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @SourceCount INT, @TargetCount INT, @BatchStepID BIGINT;
    INSERT INTO etl.BatchAudit (BatchID, LayerName, TableName) VALUES (@BatchID, 'stg', 'Supplier');
    SET @BatchStepID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @SourceCount = COUNT(*) FROM raw.Supplier;

        MERGE stg.Supplier AS tgt
        USING (
            SELECT SupplierID, LTRIM(RTRIM(SupplierName)) AS SupplierName, SupplierCategory, SupplierTier,
                   SupplierStatus, SupplierRisk, CriticalSupplierFlag, StandardLeadTimeDays, PaymentTermsDays,
                   Region, Country, StateProvince, City, CountryCode, ActiveFlag,
                   SourceCreatedDateTime, SourceModifiedDateTime
            FROM raw.Supplier
        ) AS src
        ON tgt.SupplierID = src.SupplierID
        WHEN MATCHED AND tgt.SourceModifiedDateTime <> src.SourceModifiedDateTime THEN UPDATE SET
            SupplierName=src.SupplierName, SupplierCategory=src.SupplierCategory, SupplierTier=src.SupplierTier,
            SupplierStatus=src.SupplierStatus, SupplierRisk=src.SupplierRisk, CriticalSupplierFlag=src.CriticalSupplierFlag,
            StandardLeadTimeDays=src.StandardLeadTimeDays, PaymentTermsDays=src.PaymentTermsDays, Region=src.Region,
            Country=src.Country, StateProvince=src.StateProvince, City=src.City, CountryCode=src.CountryCode,
            ActiveFlag=src.ActiveFlag, SourceCreatedDateTime=src.SourceCreatedDateTime, SourceModifiedDateTime=src.SourceModifiedDateTime,
            BatchID=@BatchID, LoadDateTime=SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (SupplierID, SupplierName, SupplierCategory, SupplierTier, SupplierStatus, SupplierRisk,
             CriticalSupplierFlag, StandardLeadTimeDays, PaymentTermsDays, Region, Country, StateProvince, City,
             CountryCode, ActiveFlag, SourceCreatedDateTime, SourceModifiedDateTime, BatchID, LoadDateTime)
        VALUES
            (src.SupplierID, src.SupplierName, src.SupplierCategory, src.SupplierTier, src.SupplierStatus, src.SupplierRisk,
             src.CriticalSupplierFlag, src.StandardLeadTimeDays, src.PaymentTermsDays, src.Region, src.Country,
             src.StateProvince, src.City, src.CountryCode, src.ActiveFlag, src.SourceCreatedDateTime,
             src.SourceModifiedDateTime, @BatchID, SYSDATETIME());
        SET @TargetCount = @@ROWCOUNT;

        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), SourceRowCount=@SourceCount, TargetRowCount=@TargetCount, Status='Succeeded' WHERE BatchStepID=@BatchStepID;
    END TRY
    BEGIN CATCH
        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), Status='Failed', ErrorMessage=ERROR_MESSAGE() WHERE BatchStepID=@BatchStepID;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE etl.usp_Load_stg_Customer
    @BatchID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @SourceCount INT, @TargetCount INT, @BatchStepID BIGINT;
    INSERT INTO etl.BatchAudit (BatchID, LayerName, TableName) VALUES (@BatchID, 'stg', 'Customer');
    SET @BatchStepID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @SourceCount = COUNT(*) FROM raw.Customer;

        MERGE stg.Customer AS tgt
        USING (
            SELECT CustomerID, LTRIM(RTRIM(CustomerName)) AS CustomerName, CustomerType, CustomerSegment,
                   CreditTermsDays, Region, Country, StateProvince, City, CountryCode, ActiveFlag,
                   SourceCreatedDateTime, SourceModifiedDateTime
            FROM raw.Customer
        ) AS src
        ON tgt.CustomerID = src.CustomerID
        WHEN MATCHED AND tgt.SourceModifiedDateTime <> src.SourceModifiedDateTime THEN UPDATE SET
            CustomerName=src.CustomerName, CustomerType=src.CustomerType, CustomerSegment=src.CustomerSegment,
            CreditTermsDays=src.CreditTermsDays, Region=src.Region, Country=src.Country, StateProvince=src.StateProvince,
            City=src.City, CountryCode=src.CountryCode, ActiveFlag=src.ActiveFlag,
            SourceCreatedDateTime=src.SourceCreatedDateTime, SourceModifiedDateTime=src.SourceModifiedDateTime,
            BatchID=@BatchID, LoadDateTime=SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (CustomerID, CustomerName, CustomerType, CustomerSegment, CreditTermsDays, Region, Country,
             StateProvince, City, CountryCode, ActiveFlag, SourceCreatedDateTime, SourceModifiedDateTime, BatchID, LoadDateTime)
        VALUES
            (src.CustomerID, src.CustomerName, src.CustomerType, src.CustomerSegment, src.CreditTermsDays, src.Region,
             src.Country, src.StateProvince, src.City, src.CountryCode, src.ActiveFlag, src.SourceCreatedDateTime,
             src.SourceModifiedDateTime, @BatchID, SYSDATETIME());
        SET @TargetCount = @@ROWCOUNT;

        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), SourceRowCount=@SourceCount, TargetRowCount=@TargetCount, Status='Succeeded' WHERE BatchStepID=@BatchStepID;
    END TRY
    BEGIN CATCH
        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), Status='Failed', ErrorMessage=ERROR_MESSAGE() WHERE BatchStepID=@BatchStepID;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE etl.usp_Load_stg_Warehouse
    @BatchID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @SourceCount INT, @TargetCount INT, @BatchStepID BIGINT;
    INSERT INTO etl.BatchAudit (BatchID, LayerName, TableName) VALUES (@BatchID, 'stg', 'Warehouse');
    SET @BatchStepID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @SourceCount = COUNT(*) FROM raw.Warehouse;

        MERGE stg.Warehouse AS tgt
        USING (
            SELECT WarehouseID, LTRIM(RTRIM(WarehouseName)) AS WarehouseName, WarehouseType, Region, Country,
                   StateProvince, City, CountryCode, CapacityUnits, ActiveFlag,
                   SourceCreatedDateTime, SourceModifiedDateTime
            FROM raw.Warehouse
        ) AS src
        ON tgt.WarehouseID = src.WarehouseID
        WHEN MATCHED AND tgt.SourceModifiedDateTime <> src.SourceModifiedDateTime THEN UPDATE SET
            WarehouseName=src.WarehouseName, WarehouseType=src.WarehouseType, Region=src.Region, Country=src.Country,
            StateProvince=src.StateProvince, City=src.City, CountryCode=src.CountryCode, CapacityUnits=src.CapacityUnits,
            ActiveFlag=src.ActiveFlag, SourceCreatedDateTime=src.SourceCreatedDateTime, SourceModifiedDateTime=src.SourceModifiedDateTime,
            BatchID=@BatchID, LoadDateTime=SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (WarehouseID, WarehouseName, WarehouseType, Region, Country, StateProvince, City, CountryCode,
             CapacityUnits, ActiveFlag, SourceCreatedDateTime, SourceModifiedDateTime, BatchID, LoadDateTime)
        VALUES
            (src.WarehouseID, src.WarehouseName, src.WarehouseType, src.Region, src.Country, src.StateProvince,
             src.City, src.CountryCode, src.CapacityUnits, src.ActiveFlag, src.SourceCreatedDateTime,
             src.SourceModifiedDateTime, @BatchID, SYSDATETIME());
        SET @TargetCount = @@ROWCOUNT;

        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), SourceRowCount=@SourceCount, TargetRowCount=@TargetCount, Status='Succeeded' WHERE BatchStepID=@BatchStepID;
    END TRY
    BEGIN CATCH
        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), Status='Failed', ErrorMessage=ERROR_MESSAGE() WHERE BatchStepID=@BatchStepID;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE etl.usp_Load_stg_Carrier
    @BatchID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @SourceCount INT, @TargetCount INT, @BatchStepID BIGINT;
    INSERT INTO etl.BatchAudit (BatchID, LayerName, TableName) VALUES (@BatchID, 'stg', 'Carrier');
    SET @BatchStepID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @SourceCount = COUNT(*) FROM raw.Carrier;

        MERGE stg.Carrier AS tgt
        USING (
            SELECT CarrierID, LTRIM(RTRIM(CarrierName)) AS CarrierName, CarrierType, ServiceLevel, Coverage,
                   CarrierRating, ContractType, PrimaryRegion, ActiveFlag,
                   SourceCreatedDateTime, SourceModifiedDateTime
            FROM raw.Carrier
        ) AS src
        ON tgt.CarrierID = src.CarrierID
        WHEN MATCHED AND tgt.SourceModifiedDateTime <> src.SourceModifiedDateTime THEN UPDATE SET
            CarrierName=src.CarrierName, CarrierType=src.CarrierType, ServiceLevel=src.ServiceLevel, Coverage=src.Coverage,
            CarrierRating=src.CarrierRating, ContractType=src.ContractType, PrimaryRegion=src.PrimaryRegion,
            ActiveFlag=src.ActiveFlag, SourceCreatedDateTime=src.SourceCreatedDateTime, SourceModifiedDateTime=src.SourceModifiedDateTime,
            BatchID=@BatchID, LoadDateTime=SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (CarrierID, CarrierName, CarrierType, ServiceLevel, Coverage, CarrierRating, ContractType,
             PrimaryRegion, ActiveFlag, SourceCreatedDateTime, SourceModifiedDateTime, BatchID, LoadDateTime)
        VALUES
            (src.CarrierID, src.CarrierName, src.CarrierType, src.ServiceLevel, src.Coverage, src.CarrierRating,
             src.ContractType, src.PrimaryRegion, src.ActiveFlag, src.SourceCreatedDateTime, src.SourceModifiedDateTime,
             @BatchID, SYSDATETIME());
        SET @TargetCount = @@ROWCOUNT;

        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), SourceRowCount=@SourceCount, TargetRowCount=@TargetCount, Status='Succeeded' WHERE BatchStepID=@BatchStepID;
    END TRY
    BEGIN CATCH
        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), Status='Failed', ErrorMessage=ERROR_MESSAGE() WHERE BatchStepID=@BatchStepID;
        THROW;
    END CATCH
END;
GO

/* stg.PurchaseOrder: validates SupplierID and DeliveryWarehouseID exist in their stg parent tables. */
CREATE OR ALTER PROCEDURE etl.usp_Load_stg_PurchaseOrder
    @BatchID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @SourceCount INT, @TargetCount INT, @RejectedCount INT, @BatchStepID BIGINT;
    INSERT INTO etl.BatchAudit (BatchID, LayerName, TableName) VALUES (@BatchID, 'stg', 'PurchaseOrder');
    SET @BatchStepID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @SourceCount = COUNT(*) FROM raw.PurchaseOrder;

        INSERT INTO etl.RejectedRows (BatchID, LayerName, TableName, SourceKeyValue, RejectReason)
        SELECT @BatchID, 'stg', 'PurchaseOrder', r.PurchaseOrderID, 'Orphan: SupplierID not found in stg.Supplier'
        FROM raw.PurchaseOrder r
        WHERE NOT EXISTS (SELECT 1 FROM stg.Supplier s WHERE s.SupplierID = r.SupplierID);

        INSERT INTO etl.RejectedRows (BatchID, LayerName, TableName, SourceKeyValue, RejectReason)
        SELECT @BatchID, 'stg', 'PurchaseOrder', r.PurchaseOrderID, 'Orphan: DeliveryWarehouseID not found in stg.Warehouse'
        FROM raw.PurchaseOrder r
        WHERE NOT EXISTS (SELECT 1 FROM stg.Warehouse w WHERE w.WarehouseID = r.DeliveryWarehouseID);

        SET @RejectedCount = (SELECT COUNT(*) FROM etl.RejectedRows WHERE BatchID=@BatchID AND LayerName='stg' AND TableName='PurchaseOrder');

        MERGE stg.PurchaseOrder AS tgt
        USING (
            SELECT r.* FROM raw.PurchaseOrder r
            WHERE EXISTS (SELECT 1 FROM stg.Supplier s WHERE s.SupplierID = r.SupplierID)
              AND EXISTS (SELECT 1 FROM stg.Warehouse w WHERE w.WarehouseID = r.DeliveryWarehouseID)
        ) AS src
        ON tgt.PurchaseOrderID = src.PurchaseOrderID
        WHEN MATCHED AND tgt.SourceModifiedDateTime <> src.SourceModifiedDateTime THEN UPDATE SET
            SupplierID=src.SupplierID, DeliveryWarehouseID=src.DeliveryWarehouseID, OrderDate=src.OrderDate,
            RequestedDeliveryDate=src.RequestedDeliveryDate, PromisedDeliveryDate=src.PromisedDeliveryDate,
            PurchaseType=src.PurchaseType, Priority=src.Priority, CurrencyCode=src.CurrencyCode, POStatus=src.POStatus,
            BuyerGroup=src.BuyerGroup, SourceCreatedDateTime=src.SourceCreatedDateTime, SourceModifiedDateTime=src.SourceModifiedDateTime,
            BatchID=@BatchID, LoadDateTime=SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (PurchaseOrderID, SupplierID, DeliveryWarehouseID, OrderDate, RequestedDeliveryDate, PromisedDeliveryDate,
             PurchaseType, Priority, CurrencyCode, POStatus, BuyerGroup, SourceCreatedDateTime, SourceModifiedDateTime, BatchID, LoadDateTime)
        VALUES
            (src.PurchaseOrderID, src.SupplierID, src.DeliveryWarehouseID, src.OrderDate, src.RequestedDeliveryDate,
             src.PromisedDeliveryDate, src.PurchaseType, src.Priority, src.CurrencyCode, src.POStatus, src.BuyerGroup,
             src.SourceCreatedDateTime, src.SourceModifiedDateTime, @BatchID, SYSDATETIME());
        SET @TargetCount = @@ROWCOUNT;

        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), SourceRowCount=@SourceCount, TargetRowCount=@TargetCount, RejectedRowCount=@RejectedCount, Status='Succeeded' WHERE BatchStepID=@BatchStepID;
    END TRY
    BEGIN CATCH
        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), Status='Failed', ErrorMessage=ERROR_MESSAGE() WHERE BatchStepID=@BatchStepID;
        THROW;
    END CATCH
END;
GO

/* stg.PurchaseOrderLine: validates PurchaseOrderID/ProductID exist, and reconciles OpenQuantity = OrderedQuantity - ReceivedQuantity. */
CREATE OR ALTER PROCEDURE etl.usp_Load_stg_PurchaseOrderLine
    @BatchID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @SourceCount INT, @TargetCount INT, @RejectedCount INT, @BatchStepID BIGINT;
    INSERT INTO etl.BatchAudit (BatchID, LayerName, TableName) VALUES (@BatchID, 'stg', 'PurchaseOrderLine');
    SET @BatchStepID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @SourceCount = COUNT(*) FROM raw.PurchaseOrderLine;

        INSERT INTO etl.RejectedRows (BatchID, LayerName, TableName, SourceKeyValue, RejectReason)
        SELECT @BatchID, 'stg', 'PurchaseOrderLine', r.PurchaseOrderLineID, 'Orphan: PurchaseOrderID not found in stg.PurchaseOrder'
        FROM raw.PurchaseOrderLine r
        WHERE NOT EXISTS (SELECT 1 FROM stg.PurchaseOrder po WHERE po.PurchaseOrderID = r.PurchaseOrderID);

        INSERT INTO etl.RejectedRows (BatchID, LayerName, TableName, SourceKeyValue, RejectReason)
        SELECT @BatchID, 'stg', 'PurchaseOrderLine', r.PurchaseOrderLineID, 'Orphan: ProductID not found in stg.Product'
        FROM raw.PurchaseOrderLine r
        WHERE NOT EXISTS (SELECT 1 FROM stg.Product p WHERE p.ProductID = r.ProductID);

        INSERT INTO etl.RejectedRows (BatchID, LayerName, TableName, SourceKeyValue, RejectReason)
        SELECT @BatchID, 'stg', 'PurchaseOrderLine', r.PurchaseOrderLineID, 'Reconciliation failed: OpenQuantity <> OrderedQuantity - ReceivedQuantity'
        FROM raw.PurchaseOrderLine r
        WHERE r.OpenQuantity <> r.OrderedQuantity - r.ReceivedQuantity;

        SET @RejectedCount = (SELECT COUNT(DISTINCT SourceKeyValue) FROM etl.RejectedRows WHERE BatchID=@BatchID AND LayerName='stg' AND TableName='PurchaseOrderLine');

        MERGE stg.PurchaseOrderLine AS tgt
        USING (
            SELECT r.* FROM raw.PurchaseOrderLine r
            WHERE EXISTS (SELECT 1 FROM stg.PurchaseOrder po WHERE po.PurchaseOrderID = r.PurchaseOrderID)
              AND EXISTS (SELECT 1 FROM stg.Product p WHERE p.ProductID = r.ProductID)
              AND r.OpenQuantity = r.OrderedQuantity - r.ReceivedQuantity
        ) AS src
        ON tgt.PurchaseOrderLineID = src.PurchaseOrderLineID
        WHEN MATCHED AND tgt.SourceModifiedDateTime <> src.SourceModifiedDateTime THEN UPDATE SET
            PurchaseOrderID=src.PurchaseOrderID, ProductID=src.ProductID, OrderedQuantity=src.OrderedQuantity,
            ReceivedQuantity=src.ReceivedQuantity, OpenQuantity=src.OpenQuantity, UnitCost=src.UnitCost,
            LineAmount=src.LineAmount, LineStatus=src.LineStatus,
            SourceCreatedDateTime=src.SourceCreatedDateTime, SourceModifiedDateTime=src.SourceModifiedDateTime,
            BatchID=@BatchID, LoadDateTime=SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (PurchaseOrderLineID, PurchaseOrderID, ProductID, OrderedQuantity, ReceivedQuantity, OpenQuantity,
             UnitCost, LineAmount, LineStatus, SourceCreatedDateTime, SourceModifiedDateTime, BatchID, LoadDateTime)
        VALUES
            (src.PurchaseOrderLineID, src.PurchaseOrderID, src.ProductID, src.OrderedQuantity, src.ReceivedQuantity,
             src.OpenQuantity, src.UnitCost, src.LineAmount, src.LineStatus, src.SourceCreatedDateTime,
             src.SourceModifiedDateTime, @BatchID, SYSDATETIME());
        SET @TargetCount = @@ROWCOUNT;

        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), SourceRowCount=@SourceCount, TargetRowCount=@TargetCount, RejectedRowCount=@RejectedCount, Status='Succeeded' WHERE BatchStepID=@BatchStepID;
    END TRY
    BEGIN CATCH
        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), Status='Failed', ErrorMessage=ERROR_MESSAGE() WHERE BatchStepID=@BatchStepID;
        THROW;
    END CATCH
END;
GO

/* stg.GoodsReceipt: validates PurchaseOrderLineID/ProductID/WarehouseID, reconciles Accepted+Rejected=PhysicalReceived. */
CREATE OR ALTER PROCEDURE etl.usp_Load_stg_GoodsReceipt
    @BatchID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @SourceCount INT, @TargetCount INT, @RejectedCount INT, @BatchStepID BIGINT;
    INSERT INTO etl.BatchAudit (BatchID, LayerName, TableName) VALUES (@BatchID, 'stg', 'GoodsReceipt');
    SET @BatchStepID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @SourceCount = COUNT(*) FROM raw.GoodsReceipt;

        INSERT INTO etl.RejectedRows (BatchID, LayerName, TableName, SourceKeyValue, RejectReason)
        SELECT @BatchID, 'stg', 'GoodsReceipt', r.GoodsReceiptID, 'Orphan: PurchaseOrderLineID not found in stg.PurchaseOrderLine'
        FROM raw.GoodsReceipt r
        WHERE NOT EXISTS (SELECT 1 FROM stg.PurchaseOrderLine pol WHERE pol.PurchaseOrderLineID = r.PurchaseOrderLineID);

        INSERT INTO etl.RejectedRows (BatchID, LayerName, TableName, SourceKeyValue, RejectReason)
        SELECT @BatchID, 'stg', 'GoodsReceipt', r.GoodsReceiptID, 'Orphan: ProductID/WarehouseID not found in stg parents'
        FROM raw.GoodsReceipt r
        WHERE (NOT EXISTS (SELECT 1 FROM stg.Product p WHERE p.ProductID = r.ProductID)
               OR NOT EXISTS (SELECT 1 FROM stg.Warehouse w WHERE w.WarehouseID = r.WarehouseID));

        INSERT INTO etl.RejectedRows (BatchID, LayerName, TableName, SourceKeyValue, RejectReason)
        SELECT @BatchID, 'stg', 'GoodsReceipt', r.GoodsReceiptID, 'Reconciliation failed: AcceptedQuantity + RejectedQuantity <> PhysicalReceivedQuantity'
        FROM raw.GoodsReceipt r
        WHERE r.AcceptedQuantity + r.RejectedQuantity <> r.PhysicalReceivedQuantity;

        SET @RejectedCount = (SELECT COUNT(DISTINCT SourceKeyValue) FROM etl.RejectedRows WHERE BatchID=@BatchID AND LayerName='stg' AND TableName='GoodsReceipt');

        MERGE stg.GoodsReceipt AS tgt
        USING (
            SELECT r.* FROM raw.GoodsReceipt r
            WHERE EXISTS (SELECT 1 FROM stg.PurchaseOrderLine pol WHERE pol.PurchaseOrderLineID = r.PurchaseOrderLineID)
              AND EXISTS (SELECT 1 FROM stg.Product p WHERE p.ProductID = r.ProductID)
              AND EXISTS (SELECT 1 FROM stg.Warehouse w WHERE w.WarehouseID = r.WarehouseID)
              AND r.AcceptedQuantity + r.RejectedQuantity = r.PhysicalReceivedQuantity
        ) AS src
        ON tgt.GoodsReceiptID = src.GoodsReceiptID
        WHEN MATCHED AND tgt.SourceCreatedDateTime <> src.SourceCreatedDateTime THEN UPDATE SET
            PurchaseOrderLineID=src.PurchaseOrderLineID, ProductID=src.ProductID, WarehouseID=src.WarehouseID,
            ReceiptDateTime=src.ReceiptDateTime, PhysicalReceivedQuantity=src.PhysicalReceivedQuantity,
            AcceptedQuantity=src.AcceptedQuantity, RejectedQuantity=src.RejectedQuantity, ReceiptStatus=src.ReceiptStatus,
            ReceiptSource=src.ReceiptSource, SourceCreatedDateTime=src.SourceCreatedDateTime,
            BatchID=@BatchID, LoadDateTime=SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (GoodsReceiptID, PurchaseOrderLineID, ProductID, WarehouseID, ReceiptDateTime, PhysicalReceivedQuantity,
             AcceptedQuantity, RejectedQuantity, ReceiptStatus, ReceiptSource, SourceCreatedDateTime, BatchID, LoadDateTime)
        VALUES
            (src.GoodsReceiptID, src.PurchaseOrderLineID, src.ProductID, src.WarehouseID, src.ReceiptDateTime,
             src.PhysicalReceivedQuantity, src.AcceptedQuantity, src.RejectedQuantity, src.ReceiptStatus,
             src.ReceiptSource, src.SourceCreatedDateTime, @BatchID, SYSDATETIME());
        SET @TargetCount = @@ROWCOUNT;

        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), SourceRowCount=@SourceCount, TargetRowCount=@TargetCount, RejectedRowCount=@RejectedCount, Status='Succeeded' WHERE BatchStepID=@BatchStepID;
    END TRY
    BEGIN CATCH
        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), Status='Failed', ErrorMessage=ERROR_MESSAGE() WHERE BatchStepID=@BatchStepID;
        THROW;
    END CATCH
END;
GO

/* stg.InventoryBalance: validates ProductID/WarehouseID exist in their stg parents. */
CREATE OR ALTER PROCEDURE etl.usp_Load_stg_InventoryBalance
    @BatchID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @SourceCount INT, @TargetCount INT, @RejectedCount INT, @BatchStepID BIGINT;
    INSERT INTO etl.BatchAudit (BatchID, LayerName, TableName) VALUES (@BatchID, 'stg', 'InventoryBalance');
    SET @BatchStepID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @SourceCount = COUNT(*) FROM raw.InventoryBalance;

        INSERT INTO etl.RejectedRows (BatchID, LayerName, TableName, SourceKeyValue, RejectReason)
        SELECT @BatchID, 'stg', 'InventoryBalance', r.ProductID + '|' + r.WarehouseID, 'Orphan: ProductID/WarehouseID not found in stg parents'
        FROM raw.InventoryBalance r
        WHERE (NOT EXISTS (SELECT 1 FROM stg.Product p WHERE p.ProductID = r.ProductID)
               OR NOT EXISTS (SELECT 1 FROM stg.Warehouse w WHERE w.WarehouseID = r.WarehouseID));

        SET @RejectedCount = (SELECT COUNT(*) FROM etl.RejectedRows WHERE BatchID=@BatchID AND LayerName='stg' AND TableName='InventoryBalance');

        MERGE stg.InventoryBalance AS tgt
        USING (
            SELECT r.* FROM raw.InventoryBalance r
            WHERE EXISTS (SELECT 1 FROM stg.Product p WHERE p.ProductID = r.ProductID)
              AND EXISTS (SELECT 1 FROM stg.Warehouse w WHERE w.WarehouseID = r.WarehouseID)
        ) AS src
        ON tgt.ProductID = src.ProductID AND tgt.WarehouseID = src.WarehouseID
        WHEN MATCHED AND tgt.SourceModifiedDateTime <> src.SourceModifiedDateTime THEN UPDATE SET
            OnHandQuantity=src.OnHandQuantity, ReservedQuantity=src.ReservedQuantity, AvailableQuantity=src.AvailableQuantity,
            InTransitQuantity=src.InTransitQuantity, AverageUnitCost=src.AverageUnitCost, LastMovementDateTime=src.LastMovementDateTime,
            SourceModifiedDateTime=src.SourceModifiedDateTime, BatchID=@BatchID, LoadDateTime=SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (ProductID, WarehouseID, OnHandQuantity, ReservedQuantity, AvailableQuantity, InTransitQuantity,
             AverageUnitCost, LastMovementDateTime, SourceModifiedDateTime, BatchID, LoadDateTime)
        VALUES
            (src.ProductID, src.WarehouseID, src.OnHandQuantity, src.ReservedQuantity, src.AvailableQuantity,
             src.InTransitQuantity, src.AverageUnitCost, src.LastMovementDateTime, src.SourceModifiedDateTime,
             @BatchID, SYSDATETIME());
        SET @TargetCount = @@ROWCOUNT;

        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), SourceRowCount=@SourceCount, TargetRowCount=@TargetCount, RejectedRowCount=@RejectedCount, Status='Succeeded' WHERE BatchStepID=@BatchStepID;
    END TRY
    BEGIN CATCH
        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), Status='Failed', ErrorMessage=ERROR_MESSAGE() WHERE BatchStepID=@BatchStepID;
        THROW;
    END CATCH
END;
GO

/* stg.SalesOrder: validates CustomerID exists in stg.Customer. */
CREATE OR ALTER PROCEDURE etl.usp_Load_stg_SalesOrder
    @BatchID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @SourceCount INT, @TargetCount INT, @RejectedCount INT, @BatchStepID BIGINT;
    INSERT INTO etl.BatchAudit (BatchID, LayerName, TableName) VALUES (@BatchID, 'stg', 'SalesOrder');
    SET @BatchStepID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @SourceCount = COUNT(*) FROM raw.SalesOrder;

        INSERT INTO etl.RejectedRows (BatchID, LayerName, TableName, SourceKeyValue, RejectReason)
        SELECT @BatchID, 'stg', 'SalesOrder', r.SalesOrderID, 'Orphan: CustomerID not found in stg.Customer'
        FROM raw.SalesOrder r
        WHERE NOT EXISTS (SELECT 1 FROM stg.Customer c WHERE c.CustomerID = r.CustomerID);

        SET @RejectedCount = (SELECT COUNT(*) FROM etl.RejectedRows WHERE BatchID=@BatchID AND LayerName='stg' AND TableName='SalesOrder');

        MERGE stg.SalesOrder AS tgt
        USING (
            SELECT r.* FROM raw.SalesOrder r
            WHERE EXISTS (SELECT 1 FROM stg.Customer c WHERE c.CustomerID = r.CustomerID)
        ) AS src
        ON tgt.SalesOrderID = src.SalesOrderID
        WHEN MATCHED AND tgt.SourceModifiedDateTime <> src.SourceModifiedDateTime THEN UPDATE SET
            CustomerID=src.CustomerID, OrderDate=src.OrderDate, RequestedDeliveryDate=src.RequestedDeliveryDate,
            Priority=src.Priority, CurrencyCode=src.CurrencyCode, OrderStatus=src.OrderStatus, OrderType=src.OrderType,
            SalesChannel=src.SalesChannel, SourceCreatedDateTime=src.SourceCreatedDateTime, SourceModifiedDateTime=src.SourceModifiedDateTime,
            BatchID=@BatchID, LoadDateTime=SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (SalesOrderID, CustomerID, OrderDate, RequestedDeliveryDate, Priority, CurrencyCode, OrderStatus,
             OrderType, SalesChannel, SourceCreatedDateTime, SourceModifiedDateTime, BatchID, LoadDateTime)
        VALUES
            (src.SalesOrderID, src.CustomerID, src.OrderDate, src.RequestedDeliveryDate, src.Priority, src.CurrencyCode,
             src.OrderStatus, src.OrderType, src.SalesChannel, src.SourceCreatedDateTime, src.SourceModifiedDateTime,
             @BatchID, SYSDATETIME());
        SET @TargetCount = @@ROWCOUNT;

        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), SourceRowCount=@SourceCount, TargetRowCount=@TargetCount, RejectedRowCount=@RejectedCount, Status='Succeeded' WHERE BatchStepID=@BatchStepID;
    END TRY
    BEGIN CATCH
        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), Status='Failed', ErrorMessage=ERROR_MESSAGE() WHERE BatchStepID=@BatchStepID;
        THROW;
    END CATCH
END;
GO

/* stg.SalesOrderLine: validates SalesOrderID/ProductID/FulfillmentWarehouseID, reconciles FulfilledQuantity <= OrderQuantity. */
CREATE OR ALTER PROCEDURE etl.usp_Load_stg_SalesOrderLine
    @BatchID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @SourceCount INT, @TargetCount INT, @RejectedCount INT, @BatchStepID BIGINT;
    INSERT INTO etl.BatchAudit (BatchID, LayerName, TableName) VALUES (@BatchID, 'stg', 'SalesOrderLine');
    SET @BatchStepID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @SourceCount = COUNT(*) FROM raw.SalesOrderLine;

        INSERT INTO etl.RejectedRows (BatchID, LayerName, TableName, SourceKeyValue, RejectReason)
        SELECT @BatchID, 'stg', 'SalesOrderLine', r.SalesOrderLineID, 'Orphan: SalesOrderID/ProductID/FulfillmentWarehouseID not found in stg parents'
        FROM raw.SalesOrderLine r
        WHERE (NOT EXISTS (SELECT 1 FROM stg.SalesOrder so WHERE so.SalesOrderID = r.SalesOrderID)
               OR NOT EXISTS (SELECT 1 FROM stg.Product p WHERE p.ProductID = r.ProductID)
               OR NOT EXISTS (SELECT 1 FROM stg.Warehouse w WHERE w.WarehouseID = r.FulfillmentWarehouseID));

        INSERT INTO etl.RejectedRows (BatchID, LayerName, TableName, SourceKeyValue, RejectReason)
        SELECT @BatchID, 'stg', 'SalesOrderLine', r.SalesOrderLineID, 'Reconciliation failed: FulfilledQuantity > OrderQuantity'
        FROM raw.SalesOrderLine r
        WHERE r.FulfilledQuantity > r.OrderQuantity;

        SET @RejectedCount = (SELECT COUNT(DISTINCT SourceKeyValue) FROM etl.RejectedRows WHERE BatchID=@BatchID AND LayerName='stg' AND TableName='SalesOrderLine');

        MERGE stg.SalesOrderLine AS tgt
        USING (
            SELECT r.* FROM raw.SalesOrderLine r
            WHERE EXISTS (SELECT 1 FROM stg.SalesOrder so WHERE so.SalesOrderID = r.SalesOrderID)
              AND EXISTS (SELECT 1 FROM stg.Product p WHERE p.ProductID = r.ProductID)
              AND EXISTS (SELECT 1 FROM stg.Warehouse w WHERE w.WarehouseID = r.FulfillmentWarehouseID)
              AND r.FulfilledQuantity <= r.OrderQuantity
        ) AS src
        ON tgt.SalesOrderLineID = src.SalesOrderLineID
        WHEN MATCHED AND tgt.SourceModifiedDateTime <> src.SourceModifiedDateTime THEN UPDATE SET
            SalesOrderID=src.SalesOrderID, ProductID=src.ProductID, FulfillmentWarehouseID=src.FulfillmentWarehouseID,
            PromisedDeliveryDate=src.PromisedDeliveryDate, OrderQuantity=src.OrderQuantity, FulfilledQuantity=src.FulfilledQuantity,
            BackorderQuantity=src.BackorderQuantity, UnitPrice=src.UnitPrice, GrossLineAmount=src.GrossLineAmount,
            DiscountAmount=src.DiscountAmount, NetLineAmount=src.NetLineAmount, LineStatus=src.LineStatus,
            SourceCreatedDateTime=src.SourceCreatedDateTime, SourceModifiedDateTime=src.SourceModifiedDateTime,
            BatchID=@BatchID, LoadDateTime=SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (SalesOrderLineID, SalesOrderID, ProductID, FulfillmentWarehouseID, PromisedDeliveryDate, OrderQuantity,
             FulfilledQuantity, BackorderQuantity, UnitPrice, GrossLineAmount, DiscountAmount, NetLineAmount,
             LineStatus, SourceCreatedDateTime, SourceModifiedDateTime, BatchID, LoadDateTime)
        VALUES
            (src.SalesOrderLineID, src.SalesOrderID, src.ProductID, src.FulfillmentWarehouseID, src.PromisedDeliveryDate,
             src.OrderQuantity, src.FulfilledQuantity, src.BackorderQuantity, src.UnitPrice, src.GrossLineAmount,
             src.DiscountAmount, src.NetLineAmount, src.LineStatus, src.SourceCreatedDateTime, src.SourceModifiedDateTime,
             @BatchID, SYSDATETIME());
        SET @TargetCount = @@ROWCOUNT;

        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), SourceRowCount=@SourceCount, TargetRowCount=@TargetCount, RejectedRowCount=@RejectedCount, Status='Succeeded' WHERE BatchStepID=@BatchStepID;
    END TRY
    BEGIN CATCH
        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), Status='Failed', ErrorMessage=ERROR_MESSAGE() WHERE BatchStepID=@BatchStepID;
        THROW;
    END CATCH
END;
GO

/* stg.Shipment: validates SalesOrderID/CarrierID/OriginWarehouseID exist in their stg parents. */
CREATE OR ALTER PROCEDURE etl.usp_Load_stg_Shipment
    @BatchID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @SourceCount INT, @TargetCount INT, @RejectedCount INT, @BatchStepID BIGINT;
    INSERT INTO etl.BatchAudit (BatchID, LayerName, TableName) VALUES (@BatchID, 'stg', 'Shipment');
    SET @BatchStepID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @SourceCount = COUNT(*) FROM raw.Shipment;

        INSERT INTO etl.RejectedRows (BatchID, LayerName, TableName, SourceKeyValue, RejectReason)
        SELECT @BatchID, 'stg', 'Shipment', r.ShipmentID, 'Orphan: SalesOrderID/CarrierID/OriginWarehouseID not found in stg parents'
        FROM raw.Shipment r
        WHERE (NOT EXISTS (SELECT 1 FROM stg.SalesOrder so WHERE so.SalesOrderID = r.SalesOrderID)
               OR NOT EXISTS (SELECT 1 FROM stg.Carrier c WHERE c.CarrierID = r.CarrierID)
               OR NOT EXISTS (SELECT 1 FROM stg.Warehouse w WHERE w.WarehouseID = r.OriginWarehouseID));

        SET @RejectedCount = (SELECT COUNT(*) FROM etl.RejectedRows WHERE BatchID=@BatchID AND LayerName='stg' AND TableName='Shipment');

        MERGE stg.Shipment AS tgt
        USING (
            SELECT r.* FROM raw.Shipment r
            WHERE EXISTS (SELECT 1 FROM stg.SalesOrder so WHERE so.SalesOrderID = r.SalesOrderID)
              AND EXISTS (SELECT 1 FROM stg.Carrier c WHERE c.CarrierID = r.CarrierID)
              AND EXISTS (SELECT 1 FROM stg.Warehouse w WHERE w.WarehouseID = r.OriginWarehouseID)
        ) AS src
        ON tgt.ShipmentID = src.ShipmentID
        WHEN MATCHED AND tgt.SourceModifiedDateTime <> src.SourceModifiedDateTime THEN UPDATE SET
            SalesOrderID=src.SalesOrderID, CarrierID=src.CarrierID, OriginWarehouseID=src.OriginWarehouseID,
            ShipmentDate=src.ShipmentDate, PromisedDeliveryDate=src.PromisedDeliveryDate, ActualDeliveryDate=src.ActualDeliveryDate,
            ShipmentStatus=src.ShipmentStatus, ShipmentMode=src.ShipmentMode, ServiceLevel=src.ServiceLevel,
            DestinationRegion=src.DestinationRegion, DestinationCountry=src.DestinationCountry,
            DestinationStateProvince=src.DestinationStateProvince, DestinationCity=src.DestinationCity,
            DestinationCountryCode=src.DestinationCountryCode, ShippingCost=src.ShippingCost, ReturnFlag=src.ReturnFlag,
            ReturnReason=src.ReturnReason, SourceCreatedDateTime=src.SourceCreatedDateTime, SourceModifiedDateTime=src.SourceModifiedDateTime,
            BatchID=@BatchID, LoadDateTime=SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (ShipmentID, SalesOrderID, CarrierID, OriginWarehouseID, ShipmentDate, PromisedDeliveryDate,
             ActualDeliveryDate, ShipmentStatus, ShipmentMode, ServiceLevel, DestinationRegion, DestinationCountry,
             DestinationStateProvince, DestinationCity, DestinationCountryCode, ShippingCost, ReturnFlag, ReturnReason,
             SourceCreatedDateTime, SourceModifiedDateTime, BatchID, LoadDateTime)
        VALUES
            (src.ShipmentID, src.SalesOrderID, src.CarrierID, src.OriginWarehouseID, src.ShipmentDate,
             src.PromisedDeliveryDate, src.ActualDeliveryDate, src.ShipmentStatus, src.ShipmentMode, src.ServiceLevel,
             src.DestinationRegion, src.DestinationCountry, src.DestinationStateProvince, src.DestinationCity,
             src.DestinationCountryCode, src.ShippingCost, src.ReturnFlag, src.ReturnReason, src.SourceCreatedDateTime,
             src.SourceModifiedDateTime, @BatchID, SYSDATETIME());
        SET @TargetCount = @@ROWCOUNT;

        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), SourceRowCount=@SourceCount, TargetRowCount=@TargetCount, RejectedRowCount=@RejectedCount, Status='Succeeded' WHERE BatchStepID=@BatchStepID;
    END TRY
    BEGIN CATCH
        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), Status='Failed', ErrorMessage=ERROR_MESSAGE() WHERE BatchStepID=@BatchStepID;
        THROW;
    END CATCH
END;
GO

/* stg.ShipmentLine: validates ShipmentID/SalesOrderLineID/ProductID exist in their stg parents. */
CREATE OR ALTER PROCEDURE etl.usp_Load_stg_ShipmentLine
    @BatchID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @SourceCount INT, @TargetCount INT, @RejectedCount INT, @BatchStepID BIGINT;
    INSERT INTO etl.BatchAudit (BatchID, LayerName, TableName) VALUES (@BatchID, 'stg', 'ShipmentLine');
    SET @BatchStepID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @SourceCount = COUNT(*) FROM raw.ShipmentLine;

        INSERT INTO etl.RejectedRows (BatchID, LayerName, TableName, SourceKeyValue, RejectReason)
        SELECT @BatchID, 'stg', 'ShipmentLine', r.ShipmentLineID, 'Orphan: ShipmentID/SalesOrderLineID/ProductID not found in stg parents'
        FROM raw.ShipmentLine r
        WHERE (NOT EXISTS (SELECT 1 FROM stg.Shipment s WHERE s.ShipmentID = r.ShipmentID)
               OR NOT EXISTS (SELECT 1 FROM stg.SalesOrderLine sol WHERE sol.SalesOrderLineID = r.SalesOrderLineID)
               OR NOT EXISTS (SELECT 1 FROM stg.Product p WHERE p.ProductID = r.ProductID));

        SET @RejectedCount = (SELECT COUNT(*) FROM etl.RejectedRows WHERE BatchID=@BatchID AND LayerName='stg' AND TableName='ShipmentLine');

        MERGE stg.ShipmentLine AS tgt
        USING (
            SELECT r.* FROM raw.ShipmentLine r
            WHERE EXISTS (SELECT 1 FROM stg.Shipment s WHERE s.ShipmentID = r.ShipmentID)
              AND EXISTS (SELECT 1 FROM stg.SalesOrderLine sol WHERE sol.SalesOrderLineID = r.SalesOrderLineID)
              AND EXISTS (SELECT 1 FROM stg.Product p WHERE p.ProductID = r.ProductID)
        ) AS src
        ON tgt.ShipmentLineID = src.ShipmentLineID
        WHEN MATCHED AND tgt.SourceModifiedDateTime <> src.SourceModifiedDateTime THEN UPDATE SET
            ShipmentID=src.ShipmentID, SalesOrderLineID=src.SalesOrderLineID, ProductID=src.ProductID,
            ShippedQuantity=src.ShippedQuantity, ReceivedQuantity=src.ReceivedQuantity,
            SourceCreatedDateTime=src.SourceCreatedDateTime, SourceModifiedDateTime=src.SourceModifiedDateTime,
            BatchID=@BatchID, LoadDateTime=SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (ShipmentLineID, ShipmentID, SalesOrderLineID, ProductID, ShippedQuantity, ReceivedQuantity,
             SourceCreatedDateTime, SourceModifiedDateTime, BatchID, LoadDateTime)
        VALUES
            (src.ShipmentLineID, src.ShipmentID, src.SalesOrderLineID, src.ProductID, src.ShippedQuantity,
             src.ReceivedQuantity, src.SourceCreatedDateTime, src.SourceModifiedDateTime, @BatchID, SYSDATETIME());
        SET @TargetCount = @@ROWCOUNT;

        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), SourceRowCount=@SourceCount, TargetRowCount=@TargetCount, RejectedRowCount=@RejectedCount, Status='Succeeded' WHERE BatchStepID=@BatchStepID;
    END TRY
    BEGIN CATCH
        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), Status='Failed', ErrorMessage=ERROR_MESSAGE() WHERE BatchStepID=@BatchStepID;
        THROW;
    END CATCH
END;
GO


/*==============================================================================
  STEP 3 - MART DIMENSION LOAD PROCEDURES (5)
  DimProduct/DimCustomer/DimWarehouse/DimCarrier are Type 1 (overwrite).
  DimSupplier is Type 2 on SupplierTier/SupplierStatus/SupplierRisk only --
  see the DDL comments in 02_Manufacturing_DW_Setup.sql for why those three
  columns specifically. All four read the FULL stg table each run (not
  batch-filtered) -- see the file header comment for why that's the right
  tradeoff at this project's data volume.
==============================================================================*/

CREATE OR ALTER PROCEDURE etl.usp_Load_mart_DimProduct
    @BatchID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @SourceCount INT, @TargetCount INT, @BatchStepID BIGINT;
    INSERT INTO etl.BatchAudit (BatchID, LayerName, TableName) VALUES (@BatchID, 'mart', 'DimProduct');
    SET @BatchStepID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @SourceCount = COUNT(*) FROM stg.Product;

        MERGE mart.DimProduct AS tgt
        USING stg.Product AS src
        ON tgt.ProductID = src.ProductID
        WHEN MATCHED AND tgt.SourceModifiedDateTime <> src.SourceModifiedDateTime THEN UPDATE SET
            SKU=src.SKU, ProductName=src.ProductName, Category=src.Category, Subcategory=src.Subcategory,
            ProductType=src.ProductType, MakeBuyType=src.MakeBuyType, VehicleSegment=src.VehicleSegment,
            UnitOfMeasure=src.UnitOfMeasure, ABCClass=src.ABCClass, StandardCost=src.StandardCost, ListPrice=src.ListPrice,
            SafetyStockQuantity=src.SafetyStockQuantity, ReorderLevel=src.ReorderLevel, MaximumStockQuantity=src.MaximumStockQuantity,
            ProductStatus=src.ProductStatus, LaunchDate=src.LaunchDate, DiscontinuedDate=src.DiscontinuedDate,
            ActiveFlag=src.ActiveFlag, SourceModifiedDateTime=src.SourceModifiedDateTime, DWModifiedDateTime=SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (ProductID, SKU, ProductName, Category, Subcategory, ProductType, MakeBuyType, VehicleSegment,
             UnitOfMeasure, ABCClass, StandardCost, ListPrice, SafetyStockQuantity, ReorderLevel, MaximumStockQuantity,
             ProductStatus, LaunchDate, DiscontinuedDate, ActiveFlag, SourceModifiedDateTime)
        VALUES
            (src.ProductID, src.SKU, src.ProductName, src.Category, src.Subcategory, src.ProductType, src.MakeBuyType,
             src.VehicleSegment, src.UnitOfMeasure, src.ABCClass, src.StandardCost, src.ListPrice,
             src.SafetyStockQuantity, src.ReorderLevel, src.MaximumStockQuantity, src.ProductStatus,
             src.LaunchDate, src.DiscontinuedDate, src.ActiveFlag, src.SourceModifiedDateTime);
        SET @TargetCount = @@ROWCOUNT;

        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), SourceRowCount=@SourceCount, TargetRowCount=@TargetCount, Status='Succeeded' WHERE BatchStepID=@BatchStepID;
    END TRY
    BEGIN CATCH
        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), Status='Failed', ErrorMessage=ERROR_MESSAGE() WHERE BatchStepID=@BatchStepID;
        THROW;
    END CATCH
END;
GO

/* mart.DimSupplier: SCD2 on SupplierTier/SupplierStatus/SupplierRisk -- expire + insert new version
   when a tracked attribute changes; in-place refresh of the current row when only a non-tracked
   attribute (name, address, lead time, etc.) drifts. */
CREATE OR ALTER PROCEDURE etl.usp_Load_mart_DimSupplier
    @BatchID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Now DATETIME2(0) = SYSDATETIME();
    DECLARE @SourceCount INT, @TargetCount INT, @BatchStepID BIGINT;
    INSERT INTO etl.BatchAudit (BatchID, LayerName, TableName) VALUES (@BatchID, 'mart', 'DimSupplier');
    SET @BatchStepID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @SourceCount = COUNT(*) FROM stg.Supplier;

        -- Step 1: expire current rows whose tracked (SCD2) attributes changed
        UPDATE tgt
        SET EffectiveEndDateTime = @Now, IsCurrent = 0
        FROM mart.DimSupplier tgt
        INNER JOIN stg.Supplier src ON src.SupplierID = tgt.SupplierID
        WHERE tgt.IsCurrent = 1
          AND (tgt.SupplierTier <> src.SupplierTier OR tgt.SupplierStatus <> src.SupplierStatus OR tgt.SupplierRisk <> src.SupplierRisk);

        -- Step 2a: suppliers that have NEVER had a DimSupplier row (brand-new to the warehouse,
        -- including every supplier on the very first ETL run) -- effective from the epoch, not
        -- @Now, so historical transactions that predate this ETL run still resolve to this version.
        -- Using @Now here was the bug that made mart.FactPurchaseOrder's date-effective join to
        -- DimSupplier exclude every historical PurchaseOrderLine on the initial load.
        INSERT INTO mart.DimSupplier
            (SupplierID, SupplierName, SupplierCategory, SupplierTier, SupplierStatus, SupplierRisk,
             CriticalSupplierFlag, StandardLeadTimeDays, PaymentTermsDays, Region, Country, StateProvince, City,
             CountryCode, ActiveFlag, EffectiveStartDateTime, EffectiveEndDateTime, IsCurrent, SourceModifiedDateTime, DWCreatedDateTime)
        SELECT
            src.SupplierID, src.SupplierName, src.SupplierCategory, src.SupplierTier, src.SupplierStatus, src.SupplierRisk,
            src.CriticalSupplierFlag, src.StandardLeadTimeDays, src.PaymentTermsDays, src.Region, src.Country,
            src.StateProvince, src.City, src.CountryCode, src.ActiveFlag,
            CAST('1900-01-01' AS DATETIME2(0)), NULL, 1, src.SourceModifiedDateTime, @Now
        FROM stg.Supplier src
        WHERE NOT EXISTS (SELECT 1 FROM mart.DimSupplier d WHERE d.SupplierID = src.SupplierID);
        SET @TargetCount = @@ROWCOUNT;

        -- Step 2b: suppliers that already had history and were just expired in Step 1 -- the new
        -- version genuinely starts now, since that's when the tracked attribute change took effect.
        INSERT INTO mart.DimSupplier
            (SupplierID, SupplierName, SupplierCategory, SupplierTier, SupplierStatus, SupplierRisk,
             CriticalSupplierFlag, StandardLeadTimeDays, PaymentTermsDays, Region, Country, StateProvince, City,
             CountryCode, ActiveFlag, EffectiveStartDateTime, EffectiveEndDateTime, IsCurrent, SourceModifiedDateTime, DWCreatedDateTime)
        SELECT
            src.SupplierID, src.SupplierName, src.SupplierCategory, src.SupplierTier, src.SupplierStatus, src.SupplierRisk,
            src.CriticalSupplierFlag, src.StandardLeadTimeDays, src.PaymentTermsDays, src.Region, src.Country,
            src.StateProvince, src.City, src.CountryCode, src.ActiveFlag, @Now, NULL, 1, src.SourceModifiedDateTime, @Now
        FROM stg.Supplier src
        WHERE EXISTS (SELECT 1 FROM mart.DimSupplier d WHERE d.SupplierID = src.SupplierID)
          AND NOT EXISTS (SELECT 1 FROM mart.DimSupplier d WHERE d.SupplierID = src.SupplierID AND d.IsCurrent = 1);
        SET @TargetCount = @TargetCount + @@ROWCOUNT;

        -- Step 3: in-place refresh of non-tracked attributes on rows that did NOT just get versioned
        UPDATE tgt
        SET SupplierName=src.SupplierName, SupplierCategory=src.SupplierCategory, CriticalSupplierFlag=src.CriticalSupplierFlag,
            StandardLeadTimeDays=src.StandardLeadTimeDays, PaymentTermsDays=src.PaymentTermsDays, Region=src.Region,
            Country=src.Country, StateProvince=src.StateProvince, City=src.City, CountryCode=src.CountryCode,
            ActiveFlag=src.ActiveFlag, SourceModifiedDateTime=src.SourceModifiedDateTime
        FROM mart.DimSupplier tgt
        INNER JOIN stg.Supplier src ON src.SupplierID = tgt.SupplierID
        WHERE tgt.IsCurrent = 1
          AND tgt.SourceModifiedDateTime <> src.SourceModifiedDateTime
          AND tgt.SupplierTier = src.SupplierTier AND tgt.SupplierStatus = src.SupplierStatus AND tgt.SupplierRisk = src.SupplierRisk;

        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), SourceRowCount=@SourceCount, TargetRowCount=@TargetCount, Status='Succeeded' WHERE BatchStepID=@BatchStepID;
    END TRY
    BEGIN CATCH
        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), Status='Failed', ErrorMessage=ERROR_MESSAGE() WHERE BatchStepID=@BatchStepID;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE etl.usp_Load_mart_DimCustomer
    @BatchID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @SourceCount INT, @TargetCount INT, @BatchStepID BIGINT;
    INSERT INTO etl.BatchAudit (BatchID, LayerName, TableName) VALUES (@BatchID, 'mart', 'DimCustomer');
    SET @BatchStepID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @SourceCount = COUNT(*) FROM stg.Customer;

        MERGE mart.DimCustomer AS tgt
        USING stg.Customer AS src
        ON tgt.CustomerID = src.CustomerID
        WHEN MATCHED AND tgt.SourceModifiedDateTime <> src.SourceModifiedDateTime THEN UPDATE SET
            CustomerName=src.CustomerName, CustomerType=src.CustomerType, CustomerSegment=src.CustomerSegment,
            CreditTermsDays=src.CreditTermsDays, Region=src.Region, Country=src.Country, StateProvince=src.StateProvince,
            City=src.City, CountryCode=src.CountryCode, ActiveFlag=src.ActiveFlag,
            SourceModifiedDateTime=src.SourceModifiedDateTime, DWModifiedDateTime=SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (CustomerID, CustomerName, CustomerType, CustomerSegment, CreditTermsDays, Region, Country,
             StateProvince, City, CountryCode, ActiveFlag, SourceModifiedDateTime)
        VALUES
            (src.CustomerID, src.CustomerName, src.CustomerType, src.CustomerSegment, src.CreditTermsDays, src.Region,
             src.Country, src.StateProvince, src.City, src.CountryCode, src.ActiveFlag, src.SourceModifiedDateTime);
        SET @TargetCount = @@ROWCOUNT;

        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), SourceRowCount=@SourceCount, TargetRowCount=@TargetCount, Status='Succeeded' WHERE BatchStepID=@BatchStepID;
    END TRY
    BEGIN CATCH
        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), Status='Failed', ErrorMessage=ERROR_MESSAGE() WHERE BatchStepID=@BatchStepID;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE etl.usp_Load_mart_DimWarehouse
    @BatchID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @SourceCount INT, @TargetCount INT, @BatchStepID BIGINT;
    INSERT INTO etl.BatchAudit (BatchID, LayerName, TableName) VALUES (@BatchID, 'mart', 'DimWarehouse');
    SET @BatchStepID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @SourceCount = COUNT(*) FROM stg.Warehouse;

        MERGE mart.DimWarehouse AS tgt
        USING stg.Warehouse AS src
        ON tgt.WarehouseID = src.WarehouseID
        WHEN MATCHED AND tgt.SourceModifiedDateTime <> src.SourceModifiedDateTime THEN UPDATE SET
            WarehouseName=src.WarehouseName, WarehouseType=src.WarehouseType, Region=src.Region, Country=src.Country,
            StateProvince=src.StateProvince, City=src.City, CountryCode=src.CountryCode, CapacityUnits=src.CapacityUnits,
            ActiveFlag=src.ActiveFlag, SourceModifiedDateTime=src.SourceModifiedDateTime, DWModifiedDateTime=SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (WarehouseID, WarehouseName, WarehouseType, Region, Country, StateProvince, City, CountryCode,
             CapacityUnits, ActiveFlag, SourceModifiedDateTime)
        VALUES
            (src.WarehouseID, src.WarehouseName, src.WarehouseType, src.Region, src.Country, src.StateProvince,
             src.City, src.CountryCode, src.CapacityUnits, src.ActiveFlag, src.SourceModifiedDateTime);
        SET @TargetCount = @@ROWCOUNT;

        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), SourceRowCount=@SourceCount, TargetRowCount=@TargetCount, Status='Succeeded' WHERE BatchStepID=@BatchStepID;
    END TRY
    BEGIN CATCH
        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), Status='Failed', ErrorMessage=ERROR_MESSAGE() WHERE BatchStepID=@BatchStepID;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE etl.usp_Load_mart_DimCarrier
    @BatchID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @SourceCount INT, @TargetCount INT, @BatchStepID BIGINT;
    INSERT INTO etl.BatchAudit (BatchID, LayerName, TableName) VALUES (@BatchID, 'mart', 'DimCarrier');
    SET @BatchStepID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @SourceCount = COUNT(*) FROM stg.Carrier;

        MERGE mart.DimCarrier AS tgt
        USING stg.Carrier AS src
        ON tgt.CarrierID = src.CarrierID
        WHEN MATCHED AND tgt.SourceModifiedDateTime <> src.SourceModifiedDateTime THEN UPDATE SET
            CarrierName=src.CarrierName, CarrierType=src.CarrierType, ServiceLevel=src.ServiceLevel, Coverage=src.Coverage,
            CarrierRating=src.CarrierRating, ContractType=src.ContractType, PrimaryRegion=src.PrimaryRegion,
            ActiveFlag=src.ActiveFlag, SourceModifiedDateTime=src.SourceModifiedDateTime, DWModifiedDateTime=SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (CarrierID, CarrierName, CarrierType, ServiceLevel, Coverage, CarrierRating, ContractType,
             PrimaryRegion, ActiveFlag, SourceModifiedDateTime)
        VALUES
            (src.CarrierID, src.CarrierName, src.CarrierType, src.ServiceLevel, src.Coverage, src.CarrierRating,
             src.ContractType, src.PrimaryRegion, src.ActiveFlag, src.SourceModifiedDateTime);
        SET @TargetCount = @@ROWCOUNT;

        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), SourceRowCount=@SourceCount, TargetRowCount=@TargetCount, Status='Succeeded' WHERE BatchStepID=@BatchStepID;
    END TRY
    BEGIN CATCH
        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), Status='Failed', ErrorMessage=ERROR_MESSAGE() WHERE BatchStepID=@BatchStepID;
        THROW;
    END CATCH
END;
GO


/*==============================================================================
  STEP 4 - MART FACT LOAD PROCEDURES (4)
  FactPurchaseOrder, FactSalesOrder, FactShipment: MERGE upsert against the
  FULL stg tables, resolving every dimension surrogate key via a join in the
  USING subquery (DimSupplier's join is date-effective, matching its SCD2
  design). FactInventorySnapshot is different by design -- a periodic
  snapshot fact -- so it DELETEs today's SnapshotDateKey then re-INSERTs,
  making a same-day rerun idempotent without needing a MERGE at all.
==============================================================================*/

/* mart.FactPurchaseOrder: grain = one row per PurchaseOrderLine. */
CREATE OR ALTER PROCEDURE etl.usp_Load_mart_FactPurchaseOrder
    @BatchID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @SourceCount INT, @TargetCount INT, @BatchStepID BIGINT;
    INSERT INTO etl.BatchAudit (BatchID, LayerName, TableName) VALUES (@BatchID, 'mart', 'FactPurchaseOrder');
    SET @BatchStepID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @SourceCount = COUNT(*) FROM stg.PurchaseOrderLine;

        ;WITH ReceiptAgg AS (
            SELECT PurchaseOrderLineID,
                   MAX(ReceiptDateTime) AS ActualReceiptDateTime,
                   SUM(AcceptedQuantity) AS AcceptedQuantity,
                   SUM(RejectedQuantity) AS RejectedQuantity
            FROM stg.GoodsReceipt
            GROUP BY PurchaseOrderLineID
        )
        MERGE mart.FactPurchaseOrder AS tgt
        USING (
            SELECT
                pol.PurchaseOrderLineID, pol.PurchaseOrderID,
                dOrder.DateKey AS OrderDateKey, dReq.DateKey AS RequestedDeliveryDateKey, dProm.DateKey AS PromisedDeliveryDateKey,
                dRecv.DateKey AS ActualReceiptDateKey,
                sup.SupplierKey, prod.ProductKey, wh.WarehouseKey,
                po.PurchaseType, po.Priority, po.POStatus, po.BuyerGroup, pol.LineStatus,
                pol.OrderedQuantity, pol.ReceivedQuantity, pol.OpenQuantity,
                ISNULL(ra.AcceptedQuantity, 0) AS AcceptedQuantity, ISNULL(ra.RejectedQuantity, 0) AS RejectedQuantity,
                pol.UnitCost, pol.LineAmount,
                CASE WHEN ra.ActualReceiptDateTime IS NULL THEN NULL
                     ELSE DATEDIFF(DAY, po.PromisedDeliveryDate, CAST(ra.ActualReceiptDateTime AS DATE)) END AS SupplierDelayDays,
                CASE WHEN ra.ActualReceiptDateTime IS NULL THEN 'Pending'
                     WHEN CAST(ra.ActualReceiptDateTime AS DATE) <= po.PromisedDeliveryDate THEN 'On Time'
                     ELSE 'Late' END AS DeliveryStatus
            FROM stg.PurchaseOrderLine pol
            INNER JOIN stg.PurchaseOrder po ON po.PurchaseOrderID = pol.PurchaseOrderID
            LEFT JOIN ReceiptAgg ra ON ra.PurchaseOrderLineID = pol.PurchaseOrderLineID
            INNER JOIN mart.DimDate dOrder ON dOrder.FullDate = po.OrderDate
            INNER JOIN mart.DimDate dReq ON dReq.FullDate = po.RequestedDeliveryDate
            INNER JOIN mart.DimDate dProm ON dProm.FullDate = po.PromisedDeliveryDate
            LEFT JOIN mart.DimDate dRecv ON dRecv.FullDate = CAST(ra.ActualReceiptDateTime AS DATE)
            INNER JOIN mart.DimSupplier sup ON sup.SupplierID = po.SupplierID
                AND po.OrderDate >= CAST(sup.EffectiveStartDateTime AS DATE)
                AND (sup.EffectiveEndDateTime IS NULL OR po.OrderDate < CAST(sup.EffectiveEndDateTime AS DATE))
            INNER JOIN mart.DimProduct prod ON prod.ProductID = pol.ProductID
            INNER JOIN mart.DimWarehouse wh ON wh.WarehouseID = po.DeliveryWarehouseID
        ) AS src
        ON tgt.PurchaseOrderLineID = src.PurchaseOrderLineID
        WHEN MATCHED THEN UPDATE SET
            OrderDateKey=src.OrderDateKey, RequestedDeliveryDateKey=src.RequestedDeliveryDateKey,
            PromisedDeliveryDateKey=src.PromisedDeliveryDateKey, ActualReceiptDateKey=src.ActualReceiptDateKey,
            SupplierKey=src.SupplierKey, ProductKey=src.ProductKey, WarehouseKey=src.WarehouseKey,
            PurchaseType=src.PurchaseType, Priority=src.Priority, POStatus=src.POStatus, BuyerGroup=src.BuyerGroup,
            LineStatus=src.LineStatus, OrderedQuantity=src.OrderedQuantity, ReceivedQuantity=src.ReceivedQuantity,
            OpenQuantity=src.OpenQuantity, AcceptedQuantity=src.AcceptedQuantity, RejectedQuantity=src.RejectedQuantity,
            UnitCost=src.UnitCost, LineAmount=src.LineAmount, SupplierDelayDays=src.SupplierDelayDays,
            DeliveryStatus=src.DeliveryStatus, BatchID=@BatchID, LoadDateTime=SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (PurchaseOrderID, PurchaseOrderLineID, OrderDateKey, RequestedDeliveryDateKey, PromisedDeliveryDateKey,
             ActualReceiptDateKey, SupplierKey, ProductKey, WarehouseKey, PurchaseType, Priority, POStatus, BuyerGroup,
             LineStatus, OrderedQuantity, ReceivedQuantity, OpenQuantity, AcceptedQuantity, RejectedQuantity,
             UnitCost, LineAmount, SupplierDelayDays, DeliveryStatus, BatchID, LoadDateTime)
        VALUES
            (src.PurchaseOrderID, src.PurchaseOrderLineID, src.OrderDateKey, src.RequestedDeliveryDateKey, src.PromisedDeliveryDateKey,
             src.ActualReceiptDateKey, src.SupplierKey, src.ProductKey, src.WarehouseKey, src.PurchaseType, src.Priority, src.POStatus, src.BuyerGroup,
             src.LineStatus, src.OrderedQuantity, src.ReceivedQuantity, src.OpenQuantity, src.AcceptedQuantity, src.RejectedQuantity,
             src.UnitCost, src.LineAmount, src.SupplierDelayDays, src.DeliveryStatus, @BatchID, SYSDATETIME());
        SET @TargetCount = @@ROWCOUNT;

        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), SourceRowCount=@SourceCount, TargetRowCount=@TargetCount, Status='Succeeded' WHERE BatchStepID=@BatchStepID;
    END TRY
    BEGIN CATCH
        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), Status='Failed', ErrorMessage=ERROR_MESSAGE() WHERE BatchStepID=@BatchStepID;
        THROW;
    END CATCH
END;
GO

/* mart.FactSalesOrder: grain = one row per SalesOrderLine. */
CREATE OR ALTER PROCEDURE etl.usp_Load_mart_FactSalesOrder
    @BatchID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @SourceCount INT, @TargetCount INT, @BatchStepID BIGINT;
    INSERT INTO etl.BatchAudit (BatchID, LayerName, TableName) VALUES (@BatchID, 'mart', 'FactSalesOrder');
    SET @BatchStepID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @SourceCount = COUNT(*) FROM stg.SalesOrderLine;

        MERGE mart.FactSalesOrder AS tgt
        USING (
            SELECT
                sol.SalesOrderLineID, sol.SalesOrderID,
                dOrder.DateKey AS OrderDateKey, dReq.DateKey AS RequestedDeliveryDateKey, dProm.DateKey AS PromisedDeliveryDateKey,
                cust.CustomerKey, prod.ProductKey, wh.WarehouseKey,
                so.Priority, so.OrderStatus, so.OrderType, so.SalesChannel, sol.LineStatus,
                sol.OrderQuantity, sol.FulfilledQuantity, sol.BackorderQuantity, sol.UnitPrice,
                sol.GrossLineAmount, sol.DiscountAmount, sol.NetLineAmount,
                CAST(CASE WHEN sol.OrderQuantity = 0 THEN 0 ELSE 100.0 * sol.FulfilledQuantity / sol.OrderQuantity END AS DECIMAL(5,2)) AS FillRatePercent
            FROM stg.SalesOrderLine sol
            INNER JOIN stg.SalesOrder so ON so.SalesOrderID = sol.SalesOrderID
            INNER JOIN mart.DimDate dOrder ON dOrder.FullDate = so.OrderDate
            INNER JOIN mart.DimDate dReq ON dReq.FullDate = so.RequestedDeliveryDate
            INNER JOIN mart.DimDate dProm ON dProm.FullDate = sol.PromisedDeliveryDate
            INNER JOIN mart.DimCustomer cust ON cust.CustomerID = so.CustomerID
            INNER JOIN mart.DimProduct prod ON prod.ProductID = sol.ProductID
            INNER JOIN mart.DimWarehouse wh ON wh.WarehouseID = sol.FulfillmentWarehouseID
        ) AS src
        ON tgt.SalesOrderLineID = src.SalesOrderLineID
        WHEN MATCHED THEN UPDATE SET
            OrderDateKey=src.OrderDateKey, RequestedDeliveryDateKey=src.RequestedDeliveryDateKey, PromisedDeliveryDateKey=src.PromisedDeliveryDateKey,
            CustomerKey=src.CustomerKey, ProductKey=src.ProductKey, WarehouseKey=src.WarehouseKey,
            Priority=src.Priority, OrderStatus=src.OrderStatus, OrderType=src.OrderType, SalesChannel=src.SalesChannel,
            LineStatus=src.LineStatus, OrderQuantity=src.OrderQuantity, FulfilledQuantity=src.FulfilledQuantity,
            BackorderQuantity=src.BackorderQuantity, UnitPrice=src.UnitPrice, GrossLineAmount=src.GrossLineAmount,
            DiscountAmount=src.DiscountAmount, NetLineAmount=src.NetLineAmount, FillRatePercent=src.FillRatePercent,
            BatchID=@BatchID, LoadDateTime=SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (SalesOrderID, SalesOrderLineID, OrderDateKey, RequestedDeliveryDateKey, PromisedDeliveryDateKey,
             CustomerKey, ProductKey, WarehouseKey, Priority, OrderStatus, OrderType, SalesChannel, LineStatus,
             OrderQuantity, FulfilledQuantity, BackorderQuantity, UnitPrice, GrossLineAmount, DiscountAmount,
             NetLineAmount, FillRatePercent, BatchID, LoadDateTime)
        VALUES
            (src.SalesOrderID, src.SalesOrderLineID, src.OrderDateKey, src.RequestedDeliveryDateKey, src.PromisedDeliveryDateKey,
             src.CustomerKey, src.ProductKey, src.WarehouseKey, src.Priority, src.OrderStatus, src.OrderType, src.SalesChannel, src.LineStatus,
             src.OrderQuantity, src.FulfilledQuantity, src.BackorderQuantity, src.UnitPrice, src.GrossLineAmount, src.DiscountAmount,
             src.NetLineAmount, src.FillRatePercent, @BatchID, SYSDATETIME());
        SET @TargetCount = @@ROWCOUNT;

        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), SourceRowCount=@SourceCount, TargetRowCount=@TargetCount, Status='Succeeded' WHERE BatchStepID=@BatchStepID;
    END TRY
    BEGIN CATCH
        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), Status='Failed', ErrorMessage=ERROR_MESSAGE() WHERE BatchStepID=@BatchStepID;
        THROW;
    END CATCH
END;
GO

/* mart.FactInventorySnapshot: periodic snapshot fact, grain = SnapshotDateKey x Product x Warehouse.
   DELETE + INSERT for today's SnapshotDateKey rather than MERGE -- see README section 13. */
CREATE OR ALTER PROCEDURE etl.usp_Load_mart_FactInventorySnapshot
    @BatchID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @SnapshotDate DATE = CAST(SYSDATETIME() AS DATE);
    DECLARE @SnapshotDateKey INT = (SELECT DateKey FROM mart.DimDate WHERE FullDate = @SnapshotDate);
    DECLARE @SourceCount INT, @TargetCount INT, @BatchStepID BIGINT;
    INSERT INTO etl.BatchAudit (BatchID, LayerName, TableName) VALUES (@BatchID, 'mart', 'FactInventorySnapshot');
    SET @BatchStepID = SCOPE_IDENTITY();

    BEGIN TRY
        IF @SnapshotDateKey IS NULL
            THROW 51000, 'FactInventorySnapshot: today is outside the mart.DimDate range -- extend DimDate in 02_Manufacturing_DW_Setup.sql.', 1;

        SELECT @SourceCount = COUNT(*) FROM stg.InventoryBalance;

        DELETE FROM mart.FactInventorySnapshot WHERE SnapshotDateKey = @SnapshotDateKey;

        INSERT INTO mart.FactInventorySnapshot
            (SnapshotDateKey, ProductKey, WarehouseKey, OnHandQuantity, ReservedQuantity, AvailableQuantity,
             InTransitQuantity, AverageUnitCost, InventoryValue, DaysSinceLastMovement, MovementClass,
             StockStatus, LastMovementDateTime, BatchID, LoadDateTime)
        SELECT
            @SnapshotDateKey, prod.ProductKey, wh.WarehouseKey,
            ib.OnHandQuantity, ib.ReservedQuantity, ib.AvailableQuantity, ib.InTransitQuantity, ib.AverageUnitCost,
            ib.OnHandQuantity * ib.AverageUnitCost AS InventoryValue,
            DATEDIFF(DAY, ib.LastMovementDateTime, SYSDATETIME()) AS DaysSinceLastMovement,
            CASE WHEN DATEDIFF(DAY, ib.LastMovementDateTime, SYSDATETIME()) <= 30 THEN 'Active'
                 WHEN DATEDIFF(DAY, ib.LastMovementDateTime, SYSDATETIME()) <= 90 THEN 'Slow-Moving'
                 ELSE 'Dead Stock' END AS MovementClass,
            CASE WHEN ib.OnHandQuantity = 0 THEN 'Stockout'
                 WHEN ib.OnHandQuantity < prod.SafetyStockQuantity THEN 'Below Safety Stock'
                 WHEN ib.OnHandQuantity < prod.ReorderLevel THEN 'Below Reorder'
                 WHEN ib.OnHandQuantity > prod.MaximumStockQuantity THEN 'Excess'
                 ELSE 'Normal' END AS StockStatus,
            ib.LastMovementDateTime, @BatchID, SYSDATETIME()
        FROM stg.InventoryBalance ib
        INNER JOIN mart.DimProduct prod ON prod.ProductID = ib.ProductID
        INNER JOIN mart.DimWarehouse wh ON wh.WarehouseID = ib.WarehouseID;
        SET @TargetCount = @@ROWCOUNT;

        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), SourceRowCount=@SourceCount, TargetRowCount=@TargetCount, Status='Succeeded' WHERE BatchStepID=@BatchStepID;
    END TRY
    BEGIN CATCH
        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), Status='Failed', ErrorMessage=ERROR_MESSAGE() WHERE BatchStepID=@BatchStepID;
        THROW;
    END CATCH
END;
GO

/* mart.FactShipment: grain = one row per ShipmentLine. CustomerKey resolved via Shipment -> SalesOrder -> Customer. */
CREATE OR ALTER PROCEDURE etl.usp_Load_mart_FactShipment
    @BatchID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @SourceCount INT, @TargetCount INT, @BatchStepID BIGINT;
    INSERT INTO etl.BatchAudit (BatchID, LayerName, TableName) VALUES (@BatchID, 'mart', 'FactShipment');
    SET @BatchStepID = SCOPE_IDENTITY();

    BEGIN TRY
        SELECT @SourceCount = COUNT(*) FROM stg.ShipmentLine;

        MERGE mart.FactShipment AS tgt
        USING (
            SELECT
                sl.ShipmentLineID, sl.ShipmentID, s.SalesOrderID, sl.SalesOrderLineID,
                dShip.DateKey AS ShipmentDateKey, dProm.DateKey AS PromisedDeliveryDateKey, dAct.DateKey AS ActualDeliveryDateKey,
                car.CarrierKey, wh.WarehouseKey, cust.CustomerKey, prod.ProductKey,
                s.ShipmentStatus, s.ShipmentMode, s.ServiceLevel, s.DestinationRegion, s.DestinationCountry,
                s.DestinationStateProvince, s.DestinationCity,
                sl.ShippedQuantity, sl.ReceivedQuantity, s.ShippingCost, s.ReturnFlag, s.ReturnReason,
                CASE WHEN s.ActualDeliveryDate IS NULL THEN NULL
                     ELSE DATEDIFF(DAY, s.PromisedDeliveryDate, s.ActualDeliveryDate) END AS DeliveryDelayDays,
                CASE WHEN s.ShipmentStatus = 'Cancelled' THEN 'Cancelled'
                     WHEN s.ActualDeliveryDate IS NULL THEN 'Pending'
                     WHEN s.ActualDeliveryDate <= s.PromisedDeliveryDate THEN 'On Time'
                     ELSE 'Late' END AS DeliveryStatus
            FROM stg.ShipmentLine sl
            INNER JOIN stg.Shipment s ON s.ShipmentID = sl.ShipmentID
            INNER JOIN stg.SalesOrder so ON so.SalesOrderID = s.SalesOrderID
            INNER JOIN mart.DimDate dShip ON dShip.FullDate = s.ShipmentDate
            INNER JOIN mart.DimDate dProm ON dProm.FullDate = s.PromisedDeliveryDate
            LEFT JOIN mart.DimDate dAct ON dAct.FullDate = s.ActualDeliveryDate
            INNER JOIN mart.DimCarrier car ON car.CarrierID = s.CarrierID
            INNER JOIN mart.DimWarehouse wh ON wh.WarehouseID = s.OriginWarehouseID
            INNER JOIN mart.DimCustomer cust ON cust.CustomerID = so.CustomerID
            INNER JOIN mart.DimProduct prod ON prod.ProductID = sl.ProductID
        ) AS src
        ON tgt.ShipmentLineID = src.ShipmentLineID
        WHEN MATCHED THEN UPDATE SET
            ShipmentID=src.ShipmentID, SalesOrderID=src.SalesOrderID, SalesOrderLineID=src.SalesOrderLineID,
            ShipmentDateKey=src.ShipmentDateKey, PromisedDeliveryDateKey=src.PromisedDeliveryDateKey, ActualDeliveryDateKey=src.ActualDeliveryDateKey,
            CarrierKey=src.CarrierKey, WarehouseKey=src.WarehouseKey, CustomerKey=src.CustomerKey, ProductKey=src.ProductKey,
            ShipmentStatus=src.ShipmentStatus, ShipmentMode=src.ShipmentMode, ServiceLevel=src.ServiceLevel,
            DestinationRegion=src.DestinationRegion, DestinationCountry=src.DestinationCountry,
            DestinationStateProvince=src.DestinationStateProvince, DestinationCity=src.DestinationCity,
            ShippedQuantity=src.ShippedQuantity, ReceivedQuantity=src.ReceivedQuantity, ShippingCost=src.ShippingCost,
            ReturnFlag=src.ReturnFlag, ReturnReason=src.ReturnReason, DeliveryDelayDays=src.DeliveryDelayDays,
            DeliveryStatus=src.DeliveryStatus, BatchID=@BatchID, LoadDateTime=SYSDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT
            (ShipmentID, ShipmentLineID, SalesOrderID, SalesOrderLineID, ShipmentDateKey, PromisedDeliveryDateKey,
             ActualDeliveryDateKey, CarrierKey, WarehouseKey, CustomerKey, ProductKey, ShipmentStatus, ShipmentMode,
             ServiceLevel, DestinationRegion, DestinationCountry, DestinationStateProvince, DestinationCity,
             ShippedQuantity, ReceivedQuantity, ShippingCost, ReturnFlag, ReturnReason, DeliveryDelayDays,
             DeliveryStatus, BatchID, LoadDateTime)
        VALUES
            (src.ShipmentID, src.ShipmentLineID, src.SalesOrderID, src.SalesOrderLineID, src.ShipmentDateKey, src.PromisedDeliveryDateKey,
             src.ActualDeliveryDateKey, src.CarrierKey, src.WarehouseKey, src.CustomerKey, src.ProductKey, src.ShipmentStatus, src.ShipmentMode,
             src.ServiceLevel, src.DestinationRegion, src.DestinationCountry, src.DestinationStateProvince, src.DestinationCity,
             src.ShippedQuantity, src.ReceivedQuantity, src.ShippingCost, src.ReturnFlag, src.ReturnReason, src.DeliveryDelayDays,
             src.DeliveryStatus, @BatchID, SYSDATETIME());
        SET @TargetCount = @@ROWCOUNT;

        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), SourceRowCount=@SourceCount, TargetRowCount=@TargetCount, Status='Succeeded' WHERE BatchStepID=@BatchStepID;
    END TRY
    BEGIN CATCH
        UPDATE etl.BatchAudit SET EndDateTime=SYSDATETIME(), Status='Failed', ErrorMessage=ERROR_MESSAGE() WHERE BatchStepID=@BatchStepID;
        THROW;
    END CATCH
END;
GO


/*==============================================================================
  STEP 5 - ORCHESTRATOR
  Calls every usp_Load_* in dependency order inside one etl.BatchRun: raw
  (any order, no FK dependencies at that layer), then stg (parents before
  children -- FK validation needs parents loaded first), then mart
  (dimensions before facts).
==============================================================================*/

CREATE OR ALTER PROCEDURE etl.usp_RunFullETL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @BatchID BIGINT;
    INSERT INTO etl.BatchRun DEFAULT VALUES;
    SET @BatchID = SCOPE_IDENTITY();

    BEGIN TRY
        -- raw layer
        EXEC etl.usp_Load_raw_Product @BatchID;
        EXEC etl.usp_Load_raw_Supplier @BatchID;
        EXEC etl.usp_Load_raw_Customer @BatchID;
        EXEC etl.usp_Load_raw_Warehouse @BatchID;
        EXEC etl.usp_Load_raw_Carrier @BatchID;
        EXEC etl.usp_Load_raw_PurchaseOrder @BatchID;
        EXEC etl.usp_Load_raw_PurchaseOrderLine @BatchID;
        EXEC etl.usp_Load_raw_GoodsReceipt @BatchID;
        EXEC etl.usp_Load_raw_InventoryBalance @BatchID;
        EXEC etl.usp_Load_raw_SalesOrder @BatchID;
        EXEC etl.usp_Load_raw_SalesOrderLine @BatchID;
        EXEC etl.usp_Load_raw_Shipment @BatchID;
        EXEC etl.usp_Load_raw_ShipmentLine @BatchID;

        -- stg layer: parents before children
        EXEC etl.usp_Load_stg_Product @BatchID;
        EXEC etl.usp_Load_stg_Supplier @BatchID;
        EXEC etl.usp_Load_stg_Customer @BatchID;
        EXEC etl.usp_Load_stg_Warehouse @BatchID;
        EXEC etl.usp_Load_stg_Carrier @BatchID;
        EXEC etl.usp_Load_stg_PurchaseOrder @BatchID;
        EXEC etl.usp_Load_stg_PurchaseOrderLine @BatchID;
        EXEC etl.usp_Load_stg_GoodsReceipt @BatchID;
        EXEC etl.usp_Load_stg_InventoryBalance @BatchID;
        EXEC etl.usp_Load_stg_SalesOrder @BatchID;
        EXEC etl.usp_Load_stg_SalesOrderLine @BatchID;
        EXEC etl.usp_Load_stg_Shipment @BatchID;
        EXEC etl.usp_Load_stg_ShipmentLine @BatchID;

        -- mart layer: dimensions before facts
        EXEC etl.usp_Load_mart_DimProduct @BatchID;
        EXEC etl.usp_Load_mart_DimSupplier @BatchID;
        EXEC etl.usp_Load_mart_DimCustomer @BatchID;
        EXEC etl.usp_Load_mart_DimWarehouse @BatchID;
        EXEC etl.usp_Load_mart_DimCarrier @BatchID;
        EXEC etl.usp_Load_mart_FactPurchaseOrder @BatchID;
        EXEC etl.usp_Load_mart_FactSalesOrder @BatchID;
        EXEC etl.usp_Load_mart_FactInventorySnapshot @BatchID;
        EXEC etl.usp_Load_mart_FactShipment @BatchID;

        UPDATE etl.BatchRun SET EndDateTime = SYSDATETIME(), Status = 'Succeeded' WHERE BatchID = @BatchID;

        SELECT @BatchID AS BatchID, 'Succeeded' AS Status;
    END TRY
    BEGIN CATCH
        UPDATE etl.BatchRun SET EndDateTime = SYSDATETIME(), Status = 'Failed', ErrorMessage = ERROR_MESSAGE() WHERE BatchID = @BatchID;
        THROW;
    END CATCH
END;
GO


/*==============================================================================
  EXPECTED RESULT AFTER SUCCESS
==============================================================================

36 procedures created in etl:
    13 x usp_Load_raw_*
    13 x usp_Load_stg_*
     5 x usp_Load_mart_Dim*
     4 x usp_Load_mart_Fact*
     1 x usp_RunFullETL (orchestrator)

NEXT STEP
---------
EXEC etl.usp_RunFullETL;
then inspect etl.BatchRun / etl.BatchAudit / etl.RejectedRows and spot-check
row counts in mart.Dim* / mart.Fact* against Manufacturing_Source.

After that, 04_SQL_Agent_Job_Setup.sql wires this into a SQL Server Agent
job so it runs on the same cadence as main_incremental_update.py.
================================================================================
*/

