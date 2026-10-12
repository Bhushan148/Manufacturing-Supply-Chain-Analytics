/*==============================================================================
  07_validation.sql  --  VALIDATION (all checks in one file)
  Confirms the warehouse + bi contract are correct and gives the golden totals the
  Power BI DAX measures must reproduce. Run after every ETL. Results: sql\VALIDATION_REPORT.md
  Run: sqlcmd -S localhost -d Manufacturing_DW -E -C -i sql\07_validation.sql
  Sections: 0) Data quality  1) View<->base  2) Independent source path
            3) Golden totals  4) By-slice  5) Date roles
==============================================================================*/

/*==============================================================================
  SECTION 0 -- DATA QUALITY / INTEGRITY  (every Violations value should be 0)
==============================================================================*/

/* 0.1 Row-count reconciliation: mart vs source */
SELECT 'FactSalesOrder' AS Entity, (SELECT COUNT(*) FROM mart.FactSalesOrder) AS DW, (SELECT COUNT(*) FROM Manufacturing_Source.dbo.SalesOrderLine) AS Src
UNION ALL SELECT 'FactPurchaseOrder', (SELECT COUNT(*) FROM mart.FactPurchaseOrder), (SELECT COUNT(*) FROM Manufacturing_Source.dbo.PurchaseOrderLine)
UNION ALL SELECT 'FactShipment', (SELECT COUNT(*) FROM mart.FactShipment), (SELECT COUNT(*) FROM Manufacturing_Source.dbo.ShipmentLine)
UNION ALL SELECT 'DimProduct', (SELECT COUNT(*) FROM mart.DimProduct), (SELECT COUNT(*) FROM Manufacturing_Source.dbo.Product)
UNION ALL SELECT 'DimCustomer', (SELECT COUNT(*) FROM mart.DimCustomer), (SELECT COUNT(*) FROM Manufacturing_Source.dbo.Customer)
UNION ALL SELECT 'DimWarehouse', (SELECT COUNT(*) FROM mart.DimWarehouse), (SELECT COUNT(*) FROM Manufacturing_Source.dbo.Warehouse)
UNION ALL SELECT 'DimCarrier', (SELECT COUNT(*) FROM mart.DimCarrier), (SELECT COUNT(*) FROM Manufacturing_Source.dbo.Carrier)
UNION ALL SELECT 'DimSupplier(current)', (SELECT COUNT(*) FROM mart.DimSupplier WHERE IsCurrent=1), (SELECT COUNT(*) FROM Manufacturing_Source.dbo.Supplier);

/* 0.2 Orphan fact keys */
SELECT 'FactSO orphan ProductKey' AS Chk, COUNT(*) AS Violations FROM mart.FactSalesOrder f LEFT JOIN mart.DimProduct d ON d.ProductKey=f.ProductKey WHERE d.ProductKey IS NULL
UNION ALL SELECT 'FactSO orphan CustomerKey', COUNT(*) FROM mart.FactSalesOrder f LEFT JOIN mart.DimCustomer d ON d.CustomerKey=f.CustomerKey WHERE d.CustomerKey IS NULL
UNION ALL SELECT 'FactPO orphan SupplierKey', COUNT(*) FROM mart.FactPurchaseOrder f LEFT JOIN mart.DimSupplier d ON d.SupplierKey=f.SupplierKey WHERE d.SupplierKey IS NULL
UNION ALL SELECT 'FactShip orphan CarrierKey', COUNT(*) FROM mart.FactShipment f LEFT JOIN mart.DimCarrier d ON d.CarrierKey=f.CarrierKey WHERE d.CarrierKey IS NULL;

/* 0.3 NULL mandatory keys */
SELECT 'FactSO NULL OrderDateKey' AS Chk, COUNT(*) AS Violations FROM mart.FactSalesOrder WHERE OrderDateKey IS NULL
UNION ALL SELECT 'FactPO NULL SupplierKey', COUNT(*) FROM mart.FactPurchaseOrder WHERE SupplierKey IS NULL
UNION ALL SELECT 'FactShip NULL ShipmentDateKey', COUNT(*) FROM mart.FactShipment WHERE ShipmentDateKey IS NULL;

/* 0.4 Grain uniqueness (duplicates) */
SELECT 'Dup SalesOrderLineID' AS Chk, COUNT(*) AS Violations FROM (SELECT SalesOrderLineID FROM mart.FactSalesOrder GROUP BY SalesOrderLineID HAVING COUNT(*)>1) x
UNION ALL SELECT 'Dup PurchaseOrderLineID', COUNT(*) FROM (SELECT PurchaseOrderLineID FROM mart.FactPurchaseOrder GROUP BY PurchaseOrderLineID HAVING COUNT(*)>1) x
UNION ALL SELECT 'Dup ShipmentLineID', COUNT(*) FROM (SELECT ShipmentLineID FROM mart.FactShipment GROUP BY ShipmentLineID HAVING COUNT(*)>1) x
UNION ALL SELECT 'Dup DimSupplier current', COUNT(*) FROM (SELECT SupplierID FROM mart.DimSupplier WHERE IsCurrent=1 GROUP BY SupplierID HAVING COUNT(*)>1) x;

/* 0.5 Arithmetic reconciliation */
SELECT 'FactSO NetLineAmount<>Gross-Disc' AS Chk, COUNT(*) AS Violations FROM mart.FactSalesOrder WHERE NetLineAmount <> GrossLineAmount - DiscountAmount
UNION ALL SELECT 'FactPO Open<>Ordered-Received', COUNT(*) FROM mart.FactPurchaseOrder WHERE OpenQuantity <> OrderedQuantity - ReceivedQuantity;

/* 0.6 ETL batch health (latest batch) */
SELECT 'Latest batch failed steps' AS Chk, COUNT(*) AS Violations FROM etl.BatchAudit WHERE BatchID=(SELECT MAX(BatchID) FROM etl.BatchRun) AND Status<>'Succeeded';
SELECT 'Rejected rows (latest batch)' AS Info, COUNT(*) AS Rows FROM etl.RejectedRows WHERE BatchID=(SELECT MAX(BatchID) FROM etl.BatchRun);
GO

/*==============================================================================
  SECTION 1 -- bi VIEWS <-> mart BASE  (every Diff must be 0)
==============================================================================*/
SELECT 'DimProduct' AS Entity, (SELECT COUNT(*) FROM bi.DimProduct) AS ViewRows, (SELECT COUNT(*) FROM mart.DimProduct) AS BaseRows, (SELECT COUNT(*) FROM bi.DimProduct)-(SELECT COUNT(*) FROM mart.DimProduct) AS Diff
UNION ALL SELECT 'DimSupplier', (SELECT COUNT(*) FROM bi.DimSupplier), (SELECT COUNT(*) FROM mart.DimSupplier), (SELECT COUNT(*) FROM bi.DimSupplier)-(SELECT COUNT(*) FROM mart.DimSupplier)
UNION ALL SELECT 'DimCustomer', (SELECT COUNT(*) FROM bi.DimCustomer), (SELECT COUNT(*) FROM mart.DimCustomer), (SELECT COUNT(*) FROM bi.DimCustomer)-(SELECT COUNT(*) FROM mart.DimCustomer)
UNION ALL SELECT 'DimWarehouse', (SELECT COUNT(*) FROM bi.DimWarehouse), (SELECT COUNT(*) FROM mart.DimWarehouse), (SELECT COUNT(*) FROM bi.DimWarehouse)-(SELECT COUNT(*) FROM mart.DimWarehouse)
UNION ALL SELECT 'DimCarrier', (SELECT COUNT(*) FROM bi.DimCarrier), (SELECT COUNT(*) FROM mart.DimCarrier), (SELECT COUNT(*) FROM bi.DimCarrier)-(SELECT COUNT(*) FROM mart.DimCarrier)
UNION ALL SELECT 'DimDate', (SELECT COUNT(*) FROM bi.DimDate), (SELECT COUNT(*) FROM mart.DimDate), (SELECT COUNT(*) FROM bi.DimDate)-(SELECT COUNT(*) FROM mart.DimDate)
UNION ALL SELECT 'FactSalesOrder', (SELECT COUNT(*) FROM bi.FactSalesOrder), (SELECT COUNT(*) FROM mart.FactSalesOrder), (SELECT COUNT(*) FROM bi.FactSalesOrder)-(SELECT COUNT(*) FROM mart.FactSalesOrder)
UNION ALL SELECT 'FactPurchaseOrder', (SELECT COUNT(*) FROM bi.FactPurchaseOrder), (SELECT COUNT(*) FROM mart.FactPurchaseOrder), (SELECT COUNT(*) FROM bi.FactPurchaseOrder)-(SELECT COUNT(*) FROM mart.FactPurchaseOrder)
UNION ALL SELECT 'FactShipment', (SELECT COUNT(*) FROM bi.FactShipment), (SELECT COUNT(*) FROM mart.FactShipment), (SELECT COUNT(*) FROM bi.FactShipment)-(SELECT COUNT(*) FROM mart.FactShipment)
UNION ALL SELECT 'FactInventorySnapshot', (SELECT COUNT(*) FROM bi.FactInventorySnapshot), (SELECT COUNT(*) FROM mart.FactInventorySnapshot), (SELECT COUNT(*) FROM bi.FactInventorySnapshot)-(SELECT COUNT(*) FROM mart.FactInventorySnapshot);

SELECT 'FactSO NetSales' AS Measure, (SELECT SUM([Net Line Amount]) FROM bi.FactSalesOrder) AS ViaView, (SELECT SUM(NetLineAmount) FROM mart.FactSalesOrder) AS ViaBase, (SELECT SUM([Net Line Amount]) FROM bi.FactSalesOrder)-(SELECT SUM(NetLineAmount) FROM mart.FactSalesOrder) AS Diff
UNION ALL SELECT 'FactPO POValue', (SELECT SUM([Line Amount]) FROM bi.FactPurchaseOrder), (SELECT SUM(LineAmount) FROM mart.FactPurchaseOrder), (SELECT SUM([Line Amount]) FROM bi.FactPurchaseOrder)-(SELECT SUM(LineAmount) FROM mart.FactPurchaseOrder)
UNION ALL SELECT 'FactShip ShippingCost', (SELECT SUM([Shipping Cost]) FROM bi.FactShipment), (SELECT SUM(ShippingCost) FROM mart.FactShipment), (SELECT SUM([Shipping Cost]) FROM bi.FactShipment)-(SELECT SUM(ShippingCost) FROM mart.FactShipment)
UNION ALL SELECT 'FactInv InventoryValue', (SELECT SUM([Inventory Value]) FROM bi.FactInventorySnapshot), (SELECT SUM(InventoryValue) FROM mart.FactInventorySnapshot), (SELECT SUM([Inventory Value]) FROM bi.FactInventorySnapshot)-(SELECT SUM(InventoryValue) FROM mart.FactInventorySnapshot);
GO

/*==============================================================================
  SECTION 2 -- INDEPENDENT SOURCE RECONCILIATION (not circular; Diff must be 0)
==============================================================================*/
SELECT 'NetSales' AS Measure, (SELECT SUM(NetLineAmount) FROM mart.FactSalesOrder) AS DW, (SELECT SUM(NetLineAmount) FROM Manufacturing_Source.dbo.SalesOrderLine) AS Src, (SELECT SUM(NetLineAmount) FROM mart.FactSalesOrder)-(SELECT SUM(NetLineAmount) FROM Manufacturing_Source.dbo.SalesOrderLine) AS Diff
UNION ALL SELECT 'POValue', (SELECT SUM(LineAmount) FROM mart.FactPurchaseOrder), (SELECT SUM(LineAmount) FROM Manufacturing_Source.dbo.PurchaseOrderLine), (SELECT SUM(LineAmount) FROM mart.FactPurchaseOrder)-(SELECT SUM(LineAmount) FROM Manufacturing_Source.dbo.PurchaseOrderLine)
UNION ALL SELECT 'ShippedQty', (SELECT SUM(ShippedQuantity) FROM mart.FactShipment), (SELECT SUM(ShippedQuantity) FROM Manufacturing_Source.dbo.ShipmentLine), (SELECT SUM(ShippedQuantity) FROM mart.FactShipment)-(SELECT SUM(ShippedQuantity) FROM Manufacturing_Source.dbo.ShipmentLine);

SELECT 'SalesOrderLine rows' AS Entity, (SELECT COUNT(*) FROM mart.FactSalesOrder) AS DW, (SELECT COUNT(*) FROM Manufacturing_Source.dbo.SalesOrderLine) AS Src
UNION ALL SELECT 'PurchaseOrderLine rows', (SELECT COUNT(*) FROM mart.FactPurchaseOrder), (SELECT COUNT(*) FROM Manufacturing_Source.dbo.PurchaseOrderLine)
UNION ALL SELECT 'ShipmentLine rows', (SELECT COUNT(*) FROM mart.FactShipment), (SELECT COUNT(*) FROM Manufacturing_Source.dbo.ShipmentLine);

/* On-time recomputed independently from source dates vs DW-derived DeliveryStatus */
SELECT 'Shipment OnTime% (source dates)' AS Metric,
       CAST(100.0*SUM(CASE WHEN ActualDeliveryDate<=PromisedDeliveryDate THEN 1 ELSE 0 END)/NULLIF(SUM(CASE WHEN ActualDeliveryDate IS NOT NULL THEN 1 ELSE 0 END),0) AS DECIMAL(5,1)) AS SourcePct
FROM Manufacturing_Source.dbo.Shipment;
SELECT 'Shipment OnTime% (DW)' AS Metric,
       CAST(100.0*SUM(CASE WHEN [Delivery Status]='On Time' THEN 1 ELSE 0 END)/NULLIF(SUM(CASE WHEN [Delivery Status] IN ('On Time','Late') THEN 1 ELSE 0 END),0) AS DECIMAL(5,1)) AS DWPct
FROM bi.FactShipment;
SELECT 'Supplier OnTime% (source)' AS Metric,
       CAST(100.0*SUM(CASE WHEN gr.last_receipt <= po.PromisedDeliveryDate THEN 1 ELSE 0 END)/NULLIF(COUNT(*),0) AS DECIMAL(5,1)) AS SourcePct
FROM Manufacturing_Source.dbo.PurchaseOrderLine pol
JOIN Manufacturing_Source.dbo.PurchaseOrder po ON po.PurchaseOrderID = pol.PurchaseOrderID
CROSS APPLY (SELECT MAX(CAST(g.ReceiptDateTime AS DATE)) AS last_receipt FROM Manufacturing_Source.dbo.GoodsReceipt g WHERE g.PurchaseOrderLineID = pol.PurchaseOrderLineID) gr
WHERE gr.last_receipt IS NOT NULL;
GO

/*==============================================================================
  SECTION 3 -- GOLDEN KPI TOTALS (expected values for Power BI DAX; no filters)
==============================================================================*/
SELECT 'Net Sales' AS KPI, CAST(SUM([Net Line Amount]) AS DECIMAL(18,2)) AS Expected FROM bi.FactSalesOrder
UNION ALL SELECT 'Gross Sales', CAST(SUM([Gross Line Amount]) AS DECIMAL(18,2)) FROM bi.FactSalesOrder
UNION ALL SELECT 'Discount Amount', CAST(SUM([Discount Amount]) AS DECIMAL(18,2)) FROM bi.FactSalesOrder
UNION ALL SELECT 'Order Quantity', CAST(SUM([Order Quantity]) AS DECIMAL(18,2)) FROM bi.FactSalesOrder
UNION ALL SELECT 'Fulfilled Quantity', CAST(SUM([Fulfilled Quantity]) AS DECIMAL(18,2)) FROM bi.FactSalesOrder
UNION ALL SELECT 'Backorder Quantity', CAST(SUM([Backorder Quantity]) AS DECIMAL(18,2)) FROM bi.FactSalesOrder
UNION ALL SELECT 'Fill Rate %', CAST(100.0*SUM([Fulfilled Quantity])/NULLIF(SUM([Order Quantity]),0) AS DECIMAL(18,2)) FROM bi.FactSalesOrder
UNION ALL SELECT 'Sales Orders', CAST(COUNT(DISTINCT [Sales Order ID]) AS DECIMAL(18,2)) FROM bi.FactSalesOrder
UNION ALL SELECT 'PO Value', CAST(SUM([Line Amount]) AS DECIMAL(18,2)) FROM bi.FactPurchaseOrder
UNION ALL SELECT 'Open PO Value', CAST(SUM([Open Quantity]*[Unit Cost]) AS DECIMAL(18,2)) FROM bi.FactPurchaseOrder
UNION ALL SELECT 'Rejected Quantity', CAST(SUM([Rejected Quantity]) AS DECIMAL(18,2)) FROM bi.FactPurchaseOrder
UNION ALL SELECT 'Supplier On-Time %', CAST(100.0*SUM(CASE WHEN [Delivery Status]='On Time' THEN 1 ELSE 0 END)/NULLIF(SUM(CASE WHEN [Delivery Status] IN ('On Time','Late') THEN 1 ELSE 0 END),0) AS DECIMAL(18,2)) FROM bi.FactPurchaseOrder
UNION ALL SELECT 'Shipping Cost', CAST(SUM([Shipping Cost]) AS DECIMAL(18,2)) FROM bi.FactShipment
UNION ALL SELECT 'Shipped Quantity', CAST(SUM([Shipped Quantity]) AS DECIMAL(18,2)) FROM bi.FactShipment
UNION ALL SELECT 'Delivery On-Time %', CAST(100.0*SUM(CASE WHEN [Delivery Status]='On Time' THEN 1 ELSE 0 END)/NULLIF(SUM(CASE WHEN [Delivery Status] IN ('On Time','Late') THEN 1 ELSE 0 END),0) AS DECIMAL(18,2)) FROM bi.FactShipment
UNION ALL SELECT 'Return %', CAST(100.0*SUM(CAST([Return Flag] AS INT))/NULLIF(COUNT(*),0) AS DECIMAL(18,2)) FROM bi.FactShipment
UNION ALL SELECT 'Inventory Value', CAST(SUM([Inventory Value]) AS DECIMAL(18,2)) FROM bi.FactInventorySnapshot WHERE SnapshotDateKey=(SELECT MAX(SnapshotDateKey) FROM bi.FactInventorySnapshot)
UNION ALL SELECT 'On Hand Quantity', CAST(SUM([On Hand Quantity]) AS DECIMAL(18,2)) FROM bi.FactInventorySnapshot WHERE SnapshotDateKey=(SELECT MAX(SnapshotDateKey) FROM bi.FactInventorySnapshot)
UNION ALL SELECT 'Stockout Bins', CAST(SUM(CASE WHEN [Stock Status]='Stockout' THEN 1 ELSE 0 END) AS DECIMAL(18,2)) FROM bi.FactInventorySnapshot WHERE SnapshotDateKey=(SELECT MAX(SnapshotDateKey) FROM bi.FactInventorySnapshot);
GO

/*==============================================================================
  SECTION 4 -- KPIs BY SLICE (reconcile against Power BI visuals w/ same slicer)
==============================================================================*/
SELECT d.[Year], CAST(SUM(f.[Net Line Amount]) AS DECIMAL(18,2)) AS NetSales,
       CAST(100.0*SUM(f.[Fulfilled Quantity])/NULLIF(SUM(f.[Order Quantity]),0) AS DECIMAL(5,1)) AS FillRatePct
FROM bi.FactSalesOrder f JOIN bi.DimDate d ON d.DateKey=f.OrderDateKey GROUP BY d.[Year] ORDER BY d.[Year];

SELECT c.[Region], CAST(SUM(f.[Net Line Amount]) AS DECIMAL(18,2)) AS NetSales
FROM bi.FactSalesOrder f JOIN bi.DimCustomer c ON c.CustomerKey=f.CustomerKey GROUP BY c.[Region] ORDER BY NetSales DESC;

SELECT p.[Category], CAST(SUM(f.[Net Line Amount]) AS DECIMAL(18,2)) AS NetSales
FROM bi.FactSalesOrder f JOIN bi.DimProduct p ON p.ProductKey=f.ProductKey GROUP BY p.[Category] ORDER BY NetSales DESC;

SELECT s.[Supplier Risk],
       CAST(100.0*SUM(CASE WHEN f.[Delivery Status]='On Time' THEN 1 ELSE 0 END)/NULLIF(SUM(CASE WHEN f.[Delivery Status] IN ('On Time','Late') THEN 1 ELSE 0 END),0) AS DECIMAL(5,1)) AS OnTimePct
FROM bi.FactPurchaseOrder f JOIN bi.DimSupplier s ON s.SupplierKey=f.SupplierKey GROUP BY s.[Supplier Risk] ORDER BY OnTimePct DESC;

SELECT c.[Carrier Name],
       CAST(100.0*SUM(CASE WHEN f.[Delivery Status]='On Time' THEN 1 ELSE 0 END)/NULLIF(SUM(CASE WHEN f.[Delivery Status] IN ('On Time','Late') THEN 1 ELSE 0 END),0) AS DECIMAL(5,1)) AS OnTimePct
FROM bi.FactShipment f JOIN bi.DimCarrier c ON c.CarrierKey=f.CarrierKey GROUP BY c.[Carrier Name] ORDER BY OnTimePct DESC;

SELECT w.[Warehouse Name], CAST(SUM(f.[Inventory Value]) AS DECIMAL(18,2)) AS InventoryValue
FROM bi.FactInventorySnapshot f JOIN bi.DimWarehouse w ON w.WarehouseKey=f.WarehouseKey
WHERE f.SnapshotDateKey=(SELECT MAX(SnapshotDateKey) FROM bi.FactInventorySnapshot) GROUP BY w.[Warehouse Name] ORDER BY InventoryValue DESC;
GO

/*==============================================================================
  SECTION 5 -- DATE ROLE CHECKS (active/inactive relationships; Violations = 0)
==============================================================================*/
SELECT 'SO Requested < Order' AS Chk, COUNT(*) AS Violations
FROM bi.FactSalesOrder f JOIN bi.DimDate o ON o.DateKey=f.OrderDateKey JOIN bi.DimDate r ON r.DateKey=f.RequestedDeliveryDateKey WHERE r.[Date] < o.[Date]
UNION ALL SELECT 'PO Promised < Order', COUNT(*)
FROM bi.FactPurchaseOrder f JOIN bi.DimDate o ON o.DateKey=f.OrderDateKey JOIN bi.DimDate p ON p.DateKey=f.PromisedDeliveryDateKey WHERE p.[Date] < o.[Date]
UNION ALL SELECT 'Shipment Actual < Shipment', COUNT(*)
FROM bi.FactShipment f JOIN bi.DimDate s ON s.DateKey=f.ShipmentDateKey JOIN bi.DimDate a ON a.DateKey=f.ActualDeliveryDateKey WHERE a.[Date] < s.[Date];

SELECT 'Shipments pending (NULL ActualDeliveryDateKey)' AS Metric, COUNT(*) AS Rows FROM bi.FactShipment WHERE ActualDeliveryDateKey IS NULL
UNION ALL SELECT 'PO lines pending (NULL ActualReceiptDateKey)', COUNT(*) FROM bi.FactPurchaseOrder WHERE ActualReceiptDateKey IS NULL;
GO
